//! O áudio da voz fora do protocolo: o que a interface escolhe (dispositivos,
//! volumes, limiar, aperte para falar), o microfone e a saída abertos pelo
//! nome e trocados sem derrubar nada, e uma thread curta para o que precisa de
//! som fora da call (medidor e teste do microfone, com a página aberta, e os
//! bipes). A interface nunca toca no áudio do SDL: abrir um dispositivo pode
//! levar centenas de milissegundos.
//!
//! Como em net/voice.zig: o microfone é um stream lido a cada 20 ms e a saída
//! é um dispositivo lógico onde cada som liga o seu stream. O SDL mistura.
//! A call e o medidor abrem cada um o seu microfone (o SDL deixa), então
//! testar não encosta no que está indo para a call.
const std = @import("std");
const c = @import("c");
const voz = @import("../core/voz.zig");
const ruido = @import("../core/ruido.zig");
const S = @import("../ui/settings_state.zig");

const Atomic = std.atomic.Value;
const bytes_per_ms = voz.rate * voz.channels * @sizeOf(i16) / 1000;
const frame_bytes = voz.frame_len * @sizeOf(i16);

pub const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_S16, .channels = voz.channels, .freq = voz.rate };

const nowMs = @import("fake_gateway.zig").nowMs;

// --- Subsistema de áudio ----------------------------------------------------

/// No QA e nos prints: driver mudo (não abre o microfone de ninguém).
pub var force_dummy = false;
var init_lock: c.SDL_SpinLock = 0;

/// SDL_InitSubSystem não pode rodar em duas threads ao mesmo tempo, e aqui
/// a call, o medidor e o vídeo abrem o áudio cada um por sua conta.
pub fn acquire() bool {
    c.SDL_LockSpinlock(&init_lock);
    defer c.SDL_UnlockSpinlock(&init_lock);
    if (force_dummy) _ = c.SDL_SetHint(c.SDL_HINT_AUDIO_DRIVER, "dummy");
    return c.SDL_InitSubSystem(c.SDL_INIT_AUDIO);
}

pub fn release() void {
    c.SDL_LockSpinlock(&init_lock);
    defer c.SDL_UnlockSpinlock(&init_lock);
    c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
}

// --- O que a interface escolheu ---------------------------------------------

pub const Shared = struct {
    in_gain: Atomic(f32) = .init(1),
    out_gain: Atomic(f32) = .init(1),
    threshold_db: Atomic(f32) = .init(-48.8),
    auto: Atomic(bool) = .init(false),
    highpass: Atomic(bool) = .init(true),
    gate: Atomic(bool) = .init(false),
    denoise: Atomic(ruido.Mode) = .init(ruido.Mode.default),
    sounds: Atomic(bool) = .init(true),
    ptt: Atomic(bool) = .init(false),
    /// A tecla do aperte para falar está apertada (eventos do SDL, janela em foco).
    ptt_down: Atomic(bool) = .init(false),
    binding: Atomic(u32) = .init(0),
    /// Imposto pelo servidor (VOICE_STATE_UPDATE).
    server_mute: Atomic(bool) = .init(false),
    server_deaf: Atomic(bool) = .init(false),
    /// Sobe quando o microfone ou a saída escolhidos mudam.
    devices_gen: Atomic(u32) = .init(1),

    // A página Voz aberta e o que ela mostra.
    page_open: Atomic(bool) = .init(false),
    test_on: Atomic(bool) = .init(false),
    level_db: Atomic(f32) = .init(voz.db_silence),
    shown_threshold_db: Atomic(f32) = .init(-48.8),
    mic_failed: Atomic(bool) = .init(false),
    /// O microfone escolhido sumiu: o medidor está no padrão do sistema.
    mic_fallback: Atomic(bool) = .init(false),
    out_fallback: Atomic(bool) = .init(false),
    list_gen: Atomic(u32) = .init(0),

    // Contadores e injeção para o QA (nada disso muda o som de verdade).
    qa_tone: Atomic(f32) = .init(0),
    /// Ruído branco no lugar do microfone (amplitude, de 0 a 1).
    qa_noise: Atomic(f32) = .init(0),
    /// O nível do que o teste do microfone devolveu por último.
    loop_db: Atomic(f32) = .init(voz.db_silence),
    qa_fail_mic: Atomic(bool) = .init(false),
    sounds_played: Atomic(u32) = .init(0),
    loop_frames: Atomic(u32) = .init(0),
    mic_opens: Atomic(u32) = .init(0),
    out_opens: Atomic(u32) = .init(0),

    pub fn captureCfg(s: *const Shared) voz.Cfg {
        return .{
            .gain = s.in_gain.load(.monotonic),
            .threshold_db = s.threshold_db.load(.monotonic),
            .auto = s.auto.load(.monotonic),
            .highpass = s.highpass.load(.monotonic),
            .gate = s.gate.load(.monotonic),
            .denoise = s.denoise.load(.monotonic),
        };
    }
};

pub var sh: Shared = .{};

var names_lock: c.SDL_SpinLock = 0;
var mic_name: S.Text = .{};
var out_name: S.Text = .{};
/// Cópias da interface (só para saber se mudou, sem trancar a cada quadro).
var ui_mic: S.Text = .{};
var ui_out: S.Text = .{};
var ui_binding: S.Text = .{};

fn chosenName(recording: bool) S.Text {
    c.SDL_LockSpinlock(&names_lock);
    defer c.SDL_UnlockSpinlock(&names_lock);
    return if (recording) mic_name else out_name;
}

/// As configurações valendo para o áudio (a cada quadro, como o proxy: só
/// guarda números; as threads leem quando precisam).
pub fn apply(set: *const S.Settings) void {
    sh.in_gain.store(@as(f32, @floatFromInt(@min(set.voice_in_gain, 200))) / 100, .monotonic);
    sh.out_gain.store(@as(f32, @floatFromInt(@min(set.voice_out_gain, 200))) / 100, .monotonic);
    sh.threshold_db.store(voz.sensToDb(set.voice_sens), .monotonic);
    sh.auto.store(set.voice_auto, .monotonic);
    sh.highpass.store(set.voice_highpass, .monotonic);
    sh.gate.store(set.voice_gate, .monotonic);
    sh.denoise.store(ruido.Mode.fromByte(set.voice_denoise), .monotonic);
    sh.sounds.store(set.voice_sounds, .monotonic);
    if (set.voice_ptt != sh.ptt.load(.monotonic)) {
        sh.ptt.store(set.voice_ptt, .monotonic);
        sh.ptt_down.store(false, .monotonic);
    }
    if (!std.mem.eql(u8, set.voice_key.slice(), ui_binding.slice())) {
        ui_binding = set.voice_key;
        sh.binding.store(voz.Binding.parse(set.voice_key.slice()).encode(), .monotonic);
        sh.ptt_down.store(false, .monotonic);
    }
    const mic_changed = !std.mem.eql(u8, set.voice_mic.slice(), ui_mic.slice());
    const out_changed = !std.mem.eql(u8, set.voice_out.slice(), ui_out.slice());
    if (mic_changed or out_changed) {
        ui_mic = set.voice_mic;
        ui_out = set.voice_out;
        c.SDL_LockSpinlock(&names_lock);
        mic_name = ui_mic;
        out_name = ui_out;
        c.SDL_UnlockSpinlock(&names_lock);
        _ = sh.devices_gen.fetchAdd(1, .release);
    }
}

// --- Atalho -----------------------------------------------------------------

var capturing = false;
var captured: ?voz.Binding = null;

pub fn startCapture() void {
    capturing = true;
    captured = null;
}

pub fn cancelCapture() void {
    capturing = false;
}

pub fn isCapturing() bool {
    return capturing;
}

/// O atalho escolhido em `startCapture`, uma vez.
pub fn takeCaptured() ?voz.Binding {
    const b = captured;
    captured = null;
    return b;
}

/// Para cada evento do SDL, antes da interface. true = era a escolha do
/// atalho e a interface não deve ver.
pub fn onSdlEvent(e: *const c.SDL_Event) bool {
    switch (e.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const down = e.type == c.SDL_EVENT_KEY_DOWN;
            if (capturing) {
                if (!down) return true;
                capturing = false;
                if (e.key.scancode != c.SDL_SCANCODE_ESCAPE) captured = .{ .key = @intCast(e.key.scancode) };
                return true;
            }
            if (sh.ptt.load(.monotonic)) setPtt(voz.pttFromEvent(voz.Binding.decode(sh.binding.load(.monotonic)), .{ .key = .{ .code = @intCast(e.key.scancode), .down = down } }));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const down = e.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            if (capturing) {
                // O botão esquerdo é o que clica na interface: não vira atalho.
                if (e.button.button == c.SDL_BUTTON_LEFT) return false;
                if (!down) return true;
                capturing = false;
                captured = .{ .mouse = e.button.button };
                return true;
            }
            if (sh.ptt.load(.monotonic)) setPtt(voz.pttFromEvent(voz.Binding.decode(sh.binding.load(.monotonic)), .{ .mouse = .{ .button = e.button.button, .down = down } }));
        },
        c.SDL_EVENT_WINDOW_FOCUS_LOST => setPtt(voz.pttFromEvent(.none, .focus_lost)),
        else => {},
    }
    return false;
}

fn setPtt(v: ?bool) void {
    if (v) |down| sh.ptt_down.store(down, .monotonic);
}

// --- Dispositivos -----------------------------------------------------------

fn defaultDevice(recording: bool) c.SDL_AudioDeviceID {
    return if (recording) c.SDL_AUDIO_DEVICE_DEFAULT_RECORDING else c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
}

/// O dispositivo com este nome, ou o padrão do sistema se ele não está lá.
fn resolve(recording: bool, name: []const u8) c.SDL_AudioDeviceID {
    if (name.len == 0) return defaultDevice(recording);
    var n: c_int = 0;
    const ids = (if (recording) c.SDL_GetAudioRecordingDevices(&n) else c.SDL_GetAudioPlaybackDevices(&n)) orelse return defaultDevice(recording);
    defer c.SDL_free(ids);
    for (0..@intCast(n)) |i| {
        const dn = c.SDL_GetAudioDeviceName(ids[i]) orelse continue;
        if (voz.sameName(name, std.mem.span(dn))) return ids[i];
    }
    return defaultDevice(recording);
}

/// O microfone: um stream lido a cada 20 ms. Abre pelo nome salvo, confere de
/// vez em quando se o dispositivo continua lá (e se a escolha mudou) e reabre
/// sem que quem lê perceba mais do que um quadro faltando.
pub const Mic = struct {
    stream: ?*c.SDL_AudioStream = null,
    target: c.SDL_AudioDeviceID = 0,
    gen: u32 = 0,
    paused: bool = false,
    /// Aberto, mas nada chega há um tempo (dispositivo morto, sem permissão).
    no_data: bool = false,
    last_data_ms: i64 = 0,
    next_check_ms: i64 = 0,
    phase: f32 = 0,
    noise_seed: u32 = 12345,

    const check_ms = 1000;
    const no_data_ms = 3000;

    pub fn open(m: *Mic, now: i64) void {
        m.close();
        m.gen = sh.devices_gen.load(.acquire);
        const name = chosenName(true);
        m.target = resolve(true, name.slice());
        if (!sh.qa_fail_mic.load(.monotonic)) {
            m.stream = c.SDL_OpenAudioDeviceStream(m.target, &spec, null, null);
            if (m.stream == null and m.target != defaultDevice(true)) {
                m.target = defaultDevice(true);
                m.stream = c.SDL_OpenAudioDeviceStream(m.target, &spec, null, null);
            }
        }
        _ = sh.mic_opens.fetchAdd(1, .monotonic);
        if (m.stream) |s| if (!m.paused) {
            _ = c.SDL_ResumeAudioStreamDevice(s);
        } else {
            _ = c.SDL_PauseAudioStreamDevice(s);
        };
        m.last_data_ms = now;
        m.next_check_ms = now + check_ms;
    }

    pub fn close(m: *Mic) void {
        if (m.stream) |s| c.SDL_DestroyAudioStream(s);
        m.stream = null;
    }

    pub fn isFallback(m: *const Mic) bool {
        const name = chosenName(true);
        return name.len > 0 and m.target == defaultDevice(true);
    }

    pub fn failed(m: *const Mic) bool {
        return m.stream == null or m.no_data;
    }

    pub fn setPaused(m: *Mic, on: bool) void {
        if (m.paused == on) return;
        m.paused = on;
        const s = m.stream orelse return;
        if (on) {
            _ = c.SDL_PauseAudioStreamDevice(s);
        } else {
            _ = c.SDL_ClearAudioStream(s);
            _ = c.SDL_ResumeAudioStreamDevice(s);
            m.last_data_ms = nowMs();
        }
    }

    /// Troca de dispositivo, dispositivo que sumiu ou voltou, microfone mudo.
    pub fn check(m: *Mic, now: i64) void {
        const gen = sh.devices_gen.load(.acquire);
        if (gen == m.gen and now < m.next_check_ms) return;
        m.next_check_ms = now + check_ms;
        if (sh.qa_fail_mic.load(.monotonic)) {
            m.close();
            return;
        }
        const name = chosenName(true);
        const want = resolve(true, name.slice());
        if (gen != m.gen or want != m.target or m.stream == null) return m.open(now);
        if (m.paused) return;
        const s = m.stream orelse return;
        if (c.SDL_GetAudioStreamAvailable(s) >= frame_bytes) m.last_data_ms = now;
        if (now - m.last_data_ms > no_data_ms) {
            m.no_data = true;
            m.open(now);
        }
    }

    /// Um quadro de 20 ms. Se acumulou atraso, joga fora o mais antigo.
    pub fn read(m: *Mic, out: *[voz.frame_len]i16) bool {
        const s = m.stream orelse return false;
        var avail = c.SDL_GetAudioStreamAvailable(s);
        var scratch: [frame_bytes]u8 = undefined;
        while (avail > frame_bytes * 4) {
            _ = c.SDL_GetAudioStreamData(s, &scratch, frame_bytes);
            avail -= frame_bytes;
        }
        if (avail < frame_bytes) return false;
        if (c.SDL_GetAudioStreamData(s, out, frame_bytes) != frame_bytes) return false;
        m.no_data = false;
        m.last_data_ms = nowMs();
        const amp = sh.qa_tone.load(.monotonic);
        if (amp > 0) {
            var i: usize = 0;
            while (i < out.len) : (i += 2) {
                const v: i16 = @intFromFloat(@sin(m.phase) * amp * 32767);
                out[i] = v;
                out[i + 1] = v;
                m.phase = @mod(m.phase + 2 * std.math.pi * 440.0 / @as(f32, voz.rate), 2 * std.math.pi);
            }
        }
        const noise = sh.qa_noise.load(.monotonic);
        if (noise > 0) {
            var i: usize = 0;
            while (i < out.len) : (i += 2) {
                m.noise_seed = m.noise_seed *% 1664525 +% 1013904223;
                const u = @as(f32, @floatFromInt(m.noise_seed >> 8)) / (1 << 24);
                const v: i16 = @intFromFloat((u * 2 - 1) * noise * 32767);
                out[i] = v;
                out[i + 1] = v;
            }
        }
        return true;
    }
};

/// A saída: um dispositivo lógico onde cada stream se liga. O ganho dele é o
/// volume de saída. Trocar abre o novo, passa os streams e só então fecha o
/// velho, então nenhuma pessoa da call precisa reabrir nada.
pub const Output = struct {
    dev: c.SDL_AudioDeviceID = 0,
    target: c.SDL_AudioDeviceID = 0,
    gen: u32 = 0,
    gain: f32 = -1,
    next_check_ms: i64 = 0,

    const check_ms = 1000;

    fn openDevice(o: *Output) c.SDL_AudioDeviceID {
        o.gen = sh.devices_gen.load(.acquire);
        const name = chosenName(false);
        o.target = resolve(false, name.slice());
        var dev = c.SDL_OpenAudioDevice(o.target, &spec);
        if (dev == 0 and o.target != defaultDevice(false)) {
            o.target = defaultDevice(false);
            dev = c.SDL_OpenAudioDevice(o.target, &spec);
        }
        _ = sh.out_opens.fetchAdd(1, .monotonic);
        return dev;
    }

    pub fn open(o: *Output, now: i64) void {
        o.close();
        o.dev = o.openDevice();
        o.gain = -1;
        o.applyGain();
        o.next_check_ms = now + check_ms;
    }

    pub fn close(o: *Output) void {
        if (o.dev != 0) c.SDL_CloseAudioDevice(o.dev);
        o.dev = 0;
    }

    pub fn applyGain(o: *Output) void {
        const g = sh.out_gain.load(.monotonic);
        if (g == o.gain or o.dev == 0) return;
        o.gain = g;
        _ = c.SDL_SetAudioDeviceGain(o.dev, g);
    }

    /// O dispositivo novo, se é hora de trocar. Quem chama passa os streams
    /// para ele (`rebind`) e chama `adopt`.
    pub fn check(o: *Output, now: i64) ?c.SDL_AudioDeviceID {
        const gen = sh.devices_gen.load(.acquire);
        if (gen == o.gen and now < o.next_check_ms) return null;
        o.next_check_ms = now + check_ms;
        const name = chosenName(false);
        const want = resolve(false, name.slice());
        if (gen == o.gen and want == o.target and o.dev != 0) return null;
        const dev = o.openDevice();
        return if (dev != 0) dev else null;
    }

    pub fn rebind(new_dev: c.SDL_AudioDeviceID, stream: *c.SDL_AudioStream) void {
        c.SDL_UnbindAudioStream(stream);
        _ = c.SDL_BindAudioStream(new_dev, stream);
    }

    pub fn adopt(o: *Output, new_dev: c.SDL_AudioDeviceID) void {
        o.close();
        o.dev = new_dev;
        o.gain = -1;
        o.applyGain();
    }
};

// --- Lista de dispositivos (para a página) ----------------------------------

pub const max_devices = 16;

pub const DeviceList = struct {
    n: u8 = 0,
    names: [max_devices]S.Text = @splat(.{}),

    pub fn slice(l: *const DeviceList, i: usize) []const u8 {
        return l.names[i].slice();
    }

    fn eql(a: *const DeviceList, b: *const DeviceList) bool {
        if (a.n != b.n) return false;
        for (0..a.n) |i| if (!std.mem.eql(u8, a.slice(i), b.slice(i))) return false;
        return true;
    }
};

var list_lock: c.SDL_SpinLock = 0;
var list_in: DeviceList = .{};
var list_out: DeviceList = .{};

fn scanDevices(recording: bool, out: *DeviceList) void {
    out.* = .{};
    var n: c_int = 0;
    const ids = (if (recording) c.SDL_GetAudioRecordingDevices(&n) else c.SDL_GetAudioPlaybackDevices(&n)) orelse return;
    defer c.SDL_free(ids);
    for (0..@intCast(n)) |i| {
        if (out.n == max_devices) break;
        const dn = c.SDL_GetAudioDeviceName(ids[i]) orelse continue;
        var buf: [voz.max_name]u8 = undefined;
        out.names[out.n].set(voz.cleanName(&buf, std.mem.span(dn)));
        out.n += 1;
    }
}

fn publishDevices() void {
    const T = struct {
        var a: DeviceList = .{};
        var b: DeviceList = .{};
    };
    scanDevices(true, &T.a);
    scanDevices(false, &T.b);
    c.SDL_LockSpinlock(&list_lock);
    defer c.SDL_UnlockSpinlock(&list_lock);
    if (T.a.eql(&list_in) and T.b.eql(&list_out)) return;
    list_in = T.a;
    list_out = T.b;
    _ = sh.list_gen.fetchAdd(1, .release);
}

/// A lista como a thread de áudio viu por último (a interface guarda uma cópia).
pub fn copyDevices(recording: *DeviceList, playback: *DeviceList) void {
    c.SDL_LockSpinlock(&list_lock);
    defer c.SDL_UnlockSpinlock(&list_lock);
    recording.* = list_in;
    playback.* = list_out;
}

// --- Thread do medidor, do teste e dos bipes --------------------------------

var state_lock: c.SDL_SpinLock = 0;
var running = false;
var pending: [8]voz.Sound = undefined;
var n_pending: usize = 0;
var stop_req: Atomic(bool) = .init(false);
/// Só a thread da interface mexe neste.
var thread: ?*c.SDL_Thread = null;

/// Sobe a thread, se ela não estiver de pé (só a thread da interface chama).
fn ensureThread() void {
    c.SDL_LockSpinlock(&state_lock);
    const start = !running;
    if (start) running = true;
    c.SDL_UnlockSpinlock(&state_lock);
    if (!start) return;
    // A anterior já avisou que acabou: esperar por ela não trava a interface.
    if (thread) |t| c.SDL_WaitThread(t, null);
    thread = c.SDL_CreateThread(helperMain, "voz-audio", null);
    if (thread == null) {
        c.SDL_LockSpinlock(&state_lock);
        running = false;
        n_pending = 0;
        c.SDL_UnlockSpinlock(&state_lock);
    }
}

/// A página Voz abriu ou fechou (a cada quadro: só age quando muda).
pub fn setPageOpen(open: bool) void {
    if (open == sh.page_open.load(.monotonic)) return;
    sh.page_open.store(open, .release);
    if (open) {
        sh.mic_failed.store(false, .monotonic);
        ensureThread();
    } else {
        sh.test_on.store(false, .release);
        capturing = false;
    }
}

/// Toca um bipe, se estiverem ligados. Não bloqueia: a thread abre o áudio.
pub fn play(sound: voz.Sound) void {
    if (!sh.sounds.load(.monotonic)) return;
    c.SDL_LockSpinlock(&state_lock);
    if (n_pending < pending.len) {
        pending[n_pending] = sound;
        n_pending += 1;
    }
    c.SDL_UnlockSpinlock(&state_lock);
    ensureThread();
}

/// Ao fechar o app, antes do SDL_Quit.
pub fn shutdown() void {
    stop_req.store(true, .release);
    if (thread) |t| c.SDL_WaitThread(t, null);
    thread = null;
}

const Helper = struct {
    mic: Mic = .{},
    out: Output = .{},
    cap: voz.Capture = .{},
    loop: ?*c.SDL_AudioStream = null,
    sfx: ?*c.SDL_AudioStream = null,
    /// Até quando os bipes já postos ainda estão tocando.
    sfx_until_ms: i64 = 0,
    next_scan_ms: i64 = 0,
    mic_open: bool = false,
    shown_db: f32 = voz.db_silence,
    audio_ok: bool = false,

    fn closeAll(h: *Helper) void {
        h.mic.close();
        h.cap.release();
        h.mic_open = false;
        if (h.loop) |s| c.SDL_DestroyAudioStream(s);
        h.loop = null;
        if (h.sfx) |s| c.SDL_DestroyAudioStream(s);
        h.sfx = null;
        h.out.close();
    }

    fn ensureOut(h: *Helper, now: i64) bool {
        if (h.out.dev == 0) h.out.open(now);
        return h.out.dev != 0;
    }

    fn newStream(h: *Helper, now: i64) ?*c.SDL_AudioStream {
        if (!h.ensureOut(now)) return null;
        const s = c.SDL_CreateAudioStream(&spec, &spec) orelse return null;
        _ = c.SDL_BindAudioStream(h.out.dev, s);
        return s;
    }

    fn stepPage(h: *Helper, now: i64) void {
        if (!sh.page_open.load(.acquire)) {
            if (h.mic_open) {
                h.mic.close();
                h.mic_open = false;
                h.cap.release();
                h.cap = .{};
                h.shown_db = voz.db_silence;
                sh.level_db.store(voz.db_silence, .monotonic);
            }
            if (h.loop) |s| c.SDL_DestroyAudioStream(s);
            h.loop = null;
            return;
        }
        if (now >= h.next_scan_ms) {
            h.next_scan_ms = now + 1000;
            publishDevices();
            // A saída só abre para tocar algo; o aviso de "sumiu" vale antes disso.
            const out = chosenName(false);
            sh.out_fallback.store(out.len > 0 and resolve(false, out.slice()) == defaultDevice(false), .monotonic);
        }
        if (!h.mic_open) {
            h.mic.open(now);
            h.mic_open = true;
        } else h.mic.check(now);
        sh.mic_failed.store(h.mic.failed(), .monotonic);
        sh.mic_fallback.store(h.mic.isFallback(), .monotonic);
        const testing = sh.test_on.load(.acquire);
        if (testing and h.loop == null) h.loop = h.newStream(now);
        if (!testing) if (h.loop) |s| {
            c.SDL_DestroyAudioStream(s);
            h.loop = null;
        };
        var pcm: [voz.frame_len]i16 = undefined;
        var last_db: ?f32 = null;
        while (h.mic.read(&pcm)) {
            const res = h.cap.process(&pcm, sh.captureCfg());
            last_db = res.db;
            sh.shown_threshold_db.store(res.threshold_db, .monotonic);
            if (h.loop) |s| {
                // Fila grande (a saída engasgou): recomeça no presente.
                if (c.SDL_GetAudioStreamQueued(s) > 200 * bytes_per_ms) _ = c.SDL_ClearAudioStream(s);
                _ = c.SDL_PutAudioStreamData(s, &pcm, frame_bytes);
                _ = sh.loop_frames.fetchAdd(1, .monotonic);
                sh.loop_db.store(voz.dbOf(voz.rmsOf(&pcm)), .monotonic);
            }
        }
        // Sobe na hora e cai devagar: dá para ler a barra.
        if (last_db) |db| {
            h.shown_db = @max(db, h.shown_db - 1.5);
            sh.level_db.store(h.shown_db, .monotonic);
        }
    }

    fn stepSounds(h: *Helper, now: i64) void {
        var list: [pending.len]voz.Sound = undefined;
        c.SDL_LockSpinlock(&state_lock);
        const n = n_pending;
        @memcpy(list[0..n], pending[0..n]);
        n_pending = 0;
        c.SDL_UnlockSpinlock(&state_lock);
        for (list[0..n]) |sound| {
            if (h.sfx == null) h.sfx = h.newStream(now);
            const s = h.sfx orelse break;
            var pcm: [voz.max_sound_len]i16 = undefined;
            const data = voz.synth(sound, &pcm);
            _ = c.SDL_PutAudioStreamData(s, data.ptr, @intCast(data.len * @sizeOf(i16)));
            _ = sh.sounds_played.fetchAdd(1, .monotonic);
        }
        if (h.sfx) |s| {
            if (n > 0) h.sfx_until_ms = now + @divTrunc(c.SDL_GetAudioStreamQueued(s), bytes_per_ms) + 300;
            if (now >= h.sfx_until_ms) {
                c.SDL_DestroyAudioStream(s);
                h.sfx = null;
            }
        }
    }

    fn stepOutput(h: *Helper, now: i64) void {
        if (h.out.dev == 0) return;
        if (h.loop == null and h.sfx == null) {
            h.out.close();
            return;
        }
        h.out.applyGain();
        if (h.out.check(now)) |dev| {
            if (h.loop) |s| Output.rebind(dev, s);
            if (h.sfx) |s| Output.rebind(dev, s);
            h.out.adopt(dev);
        }
    }

    fn hasWork(h: *const Helper) bool {
        return sh.page_open.load(.acquire) or h.sfx != null or n_pending > 0;
    }
};

fn helperMain(_: ?*anyopaque) callconv(.c) c_int {
    var h: Helper = .{};
    while (true) {
        h.audio_ok = acquire();
        const no_audio = !h.audio_ok;
        if (no_audio) sh.mic_failed.store(true, .monotonic);
        while (!stop_req.load(.acquire)) {
            const now = nowMs();
            if (h.audio_ok) {
                h.stepPage(now);
                h.stepSounds(now);
                h.stepOutput(now);
            }
            c.SDL_LockSpinlock(&state_lock);
            const work = h.hasWork();
            c.SDL_UnlockSpinlock(&state_lock);
            if (!work or !h.audio_ok) break;
            c.SDL_Delay(10);
        }
        h.closeAll();
        if (h.audio_ok) release();
        h.audio_ok = false;
        c.SDL_LockSpinlock(&state_lock);
        const again = !stop_req.load(.acquire) and h.hasWork();
        // Sem áudio de jeito nenhum: não fica tentando a 100 Hz; o próximo
        // pedido (abrir a página, um bipe) tenta de novo.
        if (!again or no_audio) {
            n_pending = 0;
            running = false;
            c.SDL_UnlockSpinlock(&state_lock);
            return 0;
        }
        c.SDL_UnlockSpinlock(&state_lock);
    }
}
