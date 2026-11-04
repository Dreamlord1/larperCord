//! Lógica da voz que não depende de SDL, de rede nem de janela: nível do
//! microfone, limiar de detecção (fixo ou aprendido), aperte para falar,
//! filtros de captura, escolha de dispositivo pelo nome, qualidade da call e
//! os bipes. A thread de voz (net/voice.zig) e o teste de microfone
//! (net/voz_audio.zig) usam as mesmas funções, testadas aqui.
const std = @import("std");

pub const rate = 48000;
pub const frame_ms = 20;
pub const frame_samples = rate * frame_ms / 1000; // 960 por canal
pub const channels = 2;
/// Amostras de um quadro de 20 ms (intercaladas, os dois canais).
pub const frame_len = frame_samples * channels;

// --- Nível -----------------------------------------------------------------

pub const db_min: f32 = -80;
pub const db_silence: f32 = -100;

pub fn rmsOf(pcm: []const i16) f32 {
    if (pcm.len == 0) return 0;
    var sum: u64 = 0;
    for (pcm) |s| sum += @intCast(@as(i32, s) * @as(i32, s));
    return @floatCast(std.math.sqrt(@as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(pcm.len))));
}

/// RMS (de i16) em dB relativos ao fundo de escala.
pub fn dbOf(rms: f32) f32 {
    if (rms < 0.5) return db_silence;
    return 20 * std.math.log10(rms / 32768);
}

/// Posição de um nível numa barra (0 = -80 dB, 1 = 0 dB).
pub fn dbToPos(db: f32) f32 {
    return std.math.clamp((db - db_min) / -db_min, 0, 1);
}

pub fn posToDb(pos: f32) f32 {
    return db_min + std.math.clamp(pos, 0, 1) * -db_min;
}

/// Sensibilidade salva (0..100, a posição na barra) em dB. O padrão é o
/// limiar antigo, fixo em RMS 120.
pub const default_sens: u8 = 39;

pub fn sensToDb(sens: u8) f32 {
    return posToDb(@as(f32, @floatFromInt(@min(sens, 100))) / 100);
}

pub fn dbToSens(db: f32) u8 {
    return @intFromFloat(std.math.round(dbToPos(db) * 100));
}

/// Volume de entrada: multiplica e satura (não dá a volta no i16).
pub fn applyGain(pcm: []i16, gain: f32) void {
    if (gain == 1) return;
    for (pcm) |*s| {
        const v = @as(f32, @floatFromInt(s.*)) * gain;
        s.* = @intFromFloat(std.math.clamp(v, -32768, 32767));
    }
}

// --- Filtros ---------------------------------------------------------------

/// Passa-altas de 2ª ordem (Butterworth, 90 Hz): tira ronco, vento e o zumbido
/// da rede elétrica sem mexer na voz. Um estado por canal.
pub const HighPass = struct {
    z1: [channels]f32 = @splat(0),
    z2: [channels]f32 = @splat(0),

    const fc = 90.0;
    const w0 = 2.0 * std.math.pi * fc / @as(comptime_float, rate);
    const q = std.math.sqrt1_2;

    fn coeffs() [5]f32 {
        const cs = @cos(@as(f64, w0));
        const alpha = @sin(@as(f64, w0)) / (2.0 * q);
        const a0 = 1.0 + alpha;
        const b0 = (1.0 + cs) / 2.0 / a0;
        return .{
            @floatCast(b0),
            @floatCast(-(1.0 + cs) / a0),
            @floatCast(b0),
            @floatCast(-2.0 * cs / a0),
            @floatCast((1.0 - alpha) / a0),
        };
    }

    pub fn process(h: *HighPass, pcm: []i16) void {
        const k = coeffs();
        var i: usize = 0;
        while (i < pcm.len) : (i += 1) {
            const ch = i % channels;
            const x: f32 = @floatFromInt(pcm[i]);
            const y = k[0] * x + h.z1[ch];
            h.z1[ch] = k[1] * x - k[3] * y + h.z2[ch];
            h.z2[ch] = k[2] * x - k[4] * y;
            // Silêncio longo: sem números subnormais (que custam caro).
            if (@abs(h.z1[ch]) < 1e-12) h.z1[ch] = 0;
            if (@abs(h.z2[ch]) < 1e-12) h.z2[ch] = 0;
            pcm[i] = @intFromFloat(std.math.clamp(y, -32768, 32767));
        }
    }
};

/// Acompanha o ruído de fundo: cai rápido quando fica mais silencioso e sobe
/// devagar, então a fala (que tem pausas) quase não o empurra para cima.
pub const NoiseFloor = struct {
    db: f32 = -60,
    frames: u32 = 0,

    /// Nos primeiros 2 s aprende depressa para os dois lados.
    const learn_frames = 100;
    const margin_db: f32 = 14;
    const min_threshold: f32 = -70;
    const max_threshold: f32 = -24;

    pub fn update(n: *NoiseFloor, level_db: f32) void {
        const l = @max(level_db, -90);
        if (n.frames < learn_frames) {
            n.frames += 1;
            n.db += (l - n.db) * 0.1;
        } else if (l < n.db) {
            n.db += (l - n.db) * 0.08;
        } else {
            n.db += @min(l - n.db, 12) * 0.002;
        }
    }

    /// O limiar do modo automático.
    pub fn threshold(n: *const NoiseFloor) f32 {
        return std.math.clamp(n.db + margin_db, min_threshold, max_threshold);
    }
};

/// Porta de ruído: abaixo do ruído de fundo + margem, abaixa o som; abre na
/// hora e fecha com folga, com rampa dentro do quadro para não estalar.
pub const Gate = struct {
    gain: f32 = 1,
    hold: u8 = 0,

    pub const margin_db: f32 = 8;
    const hold_frames = 6; // 120 ms
    const closed_gain: f32 = 0.05;

    pub fn process(g: *Gate, pcm: []i16, level_db: f32, open_db: f32) void {
        if (level_db >= open_db) {
            g.hold = hold_frames;
        } else if (g.hold > 0) g.hold -= 1;
        const target: f32 = if (g.hold > 0) 1 else closed_gain;
        if (target == 1 and g.gain == 1) return;
        const n: f32 = @floatFromInt(@max(pcm.len / channels, 1));
        const step = (target - g.gain) / n;
        var i: usize = 0;
        while (i < pcm.len) : (i += 1) {
            if (i % channels == 0) g.gain += step;
            pcm[i] = @intFromFloat(@as(f32, @floatFromInt(pcm[i])) * std.math.clamp(g.gain, 0, 1));
        }
        g.gain = target;
    }
};

// --- Captura: um quadro por vez --------------------------------------------

pub const Cfg = struct {
    gain: f32 = 1,
    threshold_db: f32 = -48.8,
    auto: bool = false,
    highpass: bool = true,
    gate: bool = false,
};

pub const Result = struct {
    rms: f32,
    /// Nível depois do volume e do passa-altas, antes da porta.
    db: f32,
    /// O limiar em uso (o manual ou o aprendido).
    threshold_db: f32,
    voice: bool,
};

/// Volume -> passa-altas -> nível -> ruído de fundo -> porta. O limiar sai do
/// mesmo nível que a barra mostra: o que aparece na tela é o que decide.
pub const Capture = struct {
    hp: HighPass = .{},
    floor: NoiseFloor = .{},
    gate: Gate = .{},

    pub fn process(cap: *Capture, pcm: []i16, cfg: Cfg) Result {
        applyGain(pcm, cfg.gain);
        if (cfg.highpass) cap.hp.process(pcm);
        const rms = rmsOf(pcm);
        const db = dbOf(rms);
        cap.floor.update(db);
        const th = if (cfg.auto) cap.floor.threshold() else cfg.threshold_db;
        if (cfg.gate) cap.gate.process(pcm, db, cap.floor.db + Gate.margin_db);
        return .{ .rms = rms, .db = db, .threshold_db = th, .voice = db >= th };
    }
};

/// Decide se o quadro vai para a call.
pub const Talk = struct {
    last_voice_ms: i64 = -1_000_000,
    last_key_ms: i64 = -1_000_000,

    /// Depois do último quadro com voz (para não cortar o fim das palavras).
    pub const voice_tail_ms = 400;
    /// Pequena folga ao soltar a tecla.
    pub const ptt_tail_ms = 200;

    pub const In = struct {
        voice: bool = false,
        ptt: bool = false,
        key: bool = false,
        /// Mudo, surdo, imposto pelo servidor ou sem microfone.
        blocked: bool = false,
    };

    pub fn update(t: *Talk, now: i64, in: In) bool {
        if (in.blocked) {
            t.* = .{};
            return false;
        }
        if (in.ptt) {
            if (in.key) t.last_key_ms = now;
            return now - t.last_key_ms < ptt_tail_ms;
        }
        if (in.voice) t.last_voice_ms = now;
        return now - t.last_voice_ms < voice_tail_ms;
    }
};

// --- Atalho do aperte para falar -------------------------------------------

/// Tecla (scancode do SDL) ou botão do mouse. Guardado como "k:44" ou "m:4".
pub const Binding = union(enum) {
    none,
    key: u16,
    mouse: u8,

    pub fn parse(s: []const u8) Binding {
        if (s.len < 3 or s[1] != ':') return .none;
        const n = std.fmt.parseInt(u16, s[2..], 10) catch return .none;
        return switch (s[0]) {
            'k' => if (n > 0 and n < 512) .{ .key = n } else .none,
            'm' => if (n > 0 and n < 32) .{ .mouse = @intCast(n) } else .none,
            else => .none,
        };
    }

    pub fn format(b: Binding, buf: []u8) []const u8 {
        return switch (b) {
            .none => "",
            .key => |k| std.fmt.bufPrint(buf, "k:{d}", .{k}) catch "",
            .mouse => |m| std.fmt.bufPrint(buf, "m:{d}", .{m}) catch "",
        };
    }

    /// Em um número só, para passar entre threads.
    pub fn encode(b: Binding) u32 {
        return switch (b) {
            .none => 0,
            .key => |k| (1 << 16) | @as(u32, k),
            .mouse => |m| (2 << 16) | @as(u32, m),
        };
    }

    pub fn decode(v: u32) Binding {
        return switch (v >> 16) {
            1 => .{ .key = @truncate(v) },
            2 => .{ .mouse = @truncate(v) },
            else => .none,
        };
    }
};

/// O estado da tecla depois de um evento: null = o evento não é da tecla.
pub fn pttFromEvent(b: Binding, ev: union(enum) { key: struct { code: u16, down: bool }, mouse: struct { button: u8, down: bool }, focus_lost }) ?bool {
    return switch (ev) {
        // Sem foco o SDL não vê mais a tecla: melhor parar de transmitir.
        .focus_lost => false,
        .key => |k| if (b == .key and b.key == k.code) k.down else null,
        .mouse => |m| if (b == .mouse and b.mouse == m.button) m.down else null,
    };
}

// --- Dispositivos ----------------------------------------------------------

pub const max_name = 255;

/// O nome como dá para salvar no KDL das configurações (sem aspas, barras e
/// controle; ui/settings_state.zig não escreve esses).
pub fn cleanName(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20) continue;
        if (n == buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

/// `saved` (já limpo) é este dispositivo?
pub fn sameName(saved: []const u8, device: []const u8) bool {
    var buf: [max_name]u8 = undefined;
    return std.mem.eql(u8, saved, cleanName(&buf, device));
}

/// Qual dispositivo usar: null = o padrão do sistema (nada escolhido, ou o
/// escolhido sumiu; o nome continua salvo, e volta quando ele voltar).
pub fn pickDevice(saved: []const u8, names: []const []const u8) ?usize {
    if (saved.len == 0) return null;
    for (names, 0..) |n, i| if (sameName(saved, n)) return i;
    return null;
}

// --- Qualidade da call -----------------------------------------------------

pub const Quality = enum { unknown, good, fair, bad };

/// Pelo ping do gateway de voz (0 = ainda não mediu).
pub fn qualityOf(ping_ms: u32) Quality {
    if (ping_ms == 0) return .unknown;
    if (ping_ms < 120) return .good;
    if (ping_ms < 250) return .fair;
    return .bad;
}

// --- Bipes -----------------------------------------------------------------

pub const Sound = enum { join, leave, mute, unmute };

const Note = struct { hz: f32, at_ms: u32, ms: u32 };

fn notesOf(s: Sound) []const Note {
    return switch (s) {
        .join => &.{ .{ .hz = 523.25, .at_ms = 0, .ms = 110 }, .{ .hz = 783.99, .at_ms = 90, .ms = 170 } },
        .leave => &.{ .{ .hz = 783.99, .at_ms = 0, .ms = 110 }, .{ .hz = 523.25, .at_ms = 90, .ms = 170 } },
        .mute => &.{.{ .hz = 392.0, .at_ms = 0, .ms = 90 }},
        .unmute => &.{.{ .hz = 659.25, .at_ms = 0, .ms = 90 }},
    };
}

/// Amostras (intercaladas) de um bipe.
pub fn soundLen(s: Sound) usize {
    var end: u32 = 0;
    for (notesOf(s)) |n| end = @max(end, n.at_ms + n.ms);
    return @as(usize, end) * rate / 1000 * channels;
}

/// O maior dos bipes cabe aqui.
pub const max_sound_len = 260 * rate / 1000 * channels;

/// Seno com um pouco da segunda harmônica, ataque curto e queda suave.
pub fn synth(s: Sound, out: []i16) []i16 {
    const len = @min(soundLen(s), out.len);
    @memset(out[0..len], 0);
    for (notesOf(s)) |n| {
        const start = @as(usize, n.at_ms) * rate / 1000;
        const count = @as(usize, n.ms) * rate / 1000;
        for (0..count) |i| {
            const pos = (start + i) * channels;
            if (pos + 1 >= len) break;
            const t = @as(f32, @floatFromInt(i)) / rate;
            const prog = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const attack = @min(t / 0.006, 1);
            const decay = (1 - prog) * (1 - prog);
            const wave = @sin(2 * std.math.pi * n.hz * t) + 0.25 * @sin(4 * std.math.pi * n.hz * t);
            const v = wave * attack * decay * 5200;
            const mixed = @as(f32, @floatFromInt(out[pos])) + v;
            const sample: i16 = @intFromFloat(std.math.clamp(mixed, -32768, 32767));
            out[pos] = sample;
            out[pos + 1] = sample;
        }
    }
    return out[0..len];
}

// --- Testes ----------------------------------------------------------------

const t_expect = std.testing.expect;
const t_eq = std.testing.expectEqual;

/// Um quadro de seno (`amp` em i16), dos dois canais.
fn tone(pcm: []i16, hz: f32, amp: f32, phase: *f32) void {
    var i: usize = 0;
    while (i < pcm.len) : (i += 2) {
        const v: i16 = @intFromFloat(@sin(phase.*) * amp);
        pcm[i] = v;
        pcm[i + 1] = v;
        phase.* += 2 * std.math.pi * hz / rate;
    }
}

test "nível: o limiar antigo (RMS 120) é o padrão" {
    try std.testing.expectApproxEqAbs(@as(f32, -48.7), dbOf(120), 0.1);
    try std.testing.expectApproxEqAbs(dbOf(120), sensToDb(default_sens), 0.5);
    try t_eq(db_silence, dbOf(0));
    try t_eq(@as(f32, 0), dbToPos(-120));
    try t_eq(@as(f32, 1), dbToPos(3));
    try t_eq(@as(u8, 50), dbToSens(sensToDb(50)));
    try t_eq(@as(f32, 0), rmsOf(&.{}));
    try std.testing.expectApproxEqAbs(@as(f32, 100), rmsOf(&.{ 100, -100, 100, -100 }), 0.01);
}

test "volume satura em vez de dar a volta" {
    var pcm = [_]i16{ 30000, -30000, 100, 0 };
    applyGain(&pcm, 2);
    try t_eq(@as(i16, 32767), pcm[0]);
    try t_eq(@as(i16, -32768), pcm[1]);
    try t_eq(@as(i16, 200), pcm[2]);
    applyGain(&pcm, 0);
    try t_eq(@as(i16, 0), pcm[0]);
}

test "passa-altas tira ronco e deixa a voz" {
    var low: HighPass = .{};
    var high: HighPass = .{};
    var ph: f32 = 0;
    var ph2: f32 = 0;
    var pcm: [frame_len]i16 = undefined;
    var low_rms: f32 = 0;
    var high_rms: f32 = 0;
    // Passa alguns quadros antes de medir (o filtro assenta).
    for (0..20) |_| {
        tone(&pcm, 30, 8000, &ph);
        low.process(&pcm);
        low_rms = rmsOf(&pcm);
        tone(&pcm, 1000, 8000, &ph2);
        high.process(&pcm);
        high_rms = rmsOf(&pcm);
    }
    const in_rms = 8000.0 * std.math.sqrt1_2;
    // 30 Hz: 2ª ordem a 90 Hz, cerca de -19 dB.
    try t_expect(low_rms < in_rms * 0.2);
    // 1 kHz passa praticamente igual.
    try std.testing.expectApproxEqRel(@as(f32, in_rms), high_rms, 0.03);
    // Silêncio continua silêncio (sem estado perdido).
    var quiet: HighPass = .{};
    var zero: [frame_len]i16 = @splat(0);
    quiet.process(&zero);
    try t_eq(@as(f32, 0), rmsOf(&zero));
}

test "ruído de fundo: aprende, não confunde fala com ruído, acompanha mudança" {
    var n: NoiseFloor = .{};
    for (0..150) |_| n.update(-55);
    try std.testing.expectApproxEqAbs(@as(f32, -55), n.db, 1);
    try std.testing.expectApproxEqAbs(@as(f32, -41), n.threshold(), 1);
    // Fala com pausas: 1,5 s de voz, 0,3 s de ruído, por 18 s.
    for (0..10) |_| {
        for (0..75) |_| n.update(-20);
        for (0..15) |_| n.update(-55);
    }
    try t_expect(n.threshold() < -36);
    // O ambiente ficou mais barulhento: em 10 s o limiar passa do ruído novo.
    for (0..500) |_| n.update(-44);
    try t_expect(n.threshold() > -44);
    // Mais silencioso: cai logo.
    for (0..50) |_| n.update(-70);
    try t_expect(n.db < -65);
    // Silêncio digital não leva o limiar para baixo de tudo.
    for (0..500) |_| n.update(db_silence);
    try t_eq(NoiseFloor.min_threshold, n.threshold());
}

test "porta de ruído fecha no ruído, abre na voz, com folga" {
    var g: Gate = .{};
    var ph: f32 = 0;
    var pcm: [frame_len]i16 = undefined;
    // Aberta com voz: não mexe.
    tone(&pcm, 500, 8000, &ph);
    const before = rmsOf(&pcm);
    g.process(&pcm, -20, -40);
    try t_eq(before, rmsOf(&pcm));
    // A folga segura as primeiras palavras caladas.
    for (0..Gate.hold_frames - 1) |_| {
        tone(&pcm, 500, 800, &ph);
        const b = rmsOf(&pcm);
        g.process(&pcm, -60, -40);
        try t_eq(b, rmsOf(&pcm));
    }
    // Depois fecha (com rampa) e fica baixo.
    tone(&pcm, 500, 800, &ph);
    g.process(&pcm, -60, -40);
    tone(&pcm, 500, 800, &ph);
    const b2 = rmsOf(&pcm);
    g.process(&pcm, -60, -40);
    try t_expect(rmsOf(&pcm) < b2 * 0.1);
    // Voz de novo: abre.
    tone(&pcm, 500, 8000, &ph);
    g.process(&pcm, -20, -40);
    tone(&pcm, 500, 8000, &ph);
    const b3 = rmsOf(&pcm);
    g.process(&pcm, -20, -40);
    try t_eq(b3, rmsOf(&pcm));
}

test "captura: limiar manual, automático e volume de entrada" {
    var cap: Capture = .{};
    var ph: f32 = 0;
    var pcm: [frame_len]i16 = undefined;
    // Manual: decide pelo limiar pedido.
    tone(&pcm, 1000, 2000, &ph);
    var r = cap.process(&pcm, .{ .threshold_db = -40 });
    try t_expect(r.voice);
    try std.testing.expectApproxEqAbs(@as(f32, -27.3), r.db, 1);
    tone(&pcm, 1000, 2000, &ph);
    r = cap.process(&pcm, .{ .threshold_db = -20 });
    try t_expect(!r.voice);
    try t_eq(@as(f32, -20), r.threshold_db);
    // Volume dobrado sobe 6 dB.
    tone(&pcm, 1000, 2000, &ph);
    r = cap.process(&pcm, .{ .threshold_db = -40, .gain = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, -21.3), r.db, 1);
    // Automático: o ruído constante não conta como voz, a voz conta.
    var auto: Capture = .{};
    for (0..200) |_| {
        tone(&pcm, 1000, 60, &ph);
        r = auto.process(&pcm, .{ .auto = true });
    }
    try t_expect(!r.voice);
    tone(&pcm, 1000, 4000, &ph);
    r = auto.process(&pcm, .{ .auto = true });
    try t_expect(r.voice);
}

test "detecção de voz: rabo de 400 ms" {
    var t: Talk = .{};
    try t_expect(!t.update(1000, .{}));
    try t_expect(t.update(1020, .{ .voice = true }));
    try t_expect(t.update(1040, .{}));
    try t_expect(t.update(1419, .{}));
    try t_expect(!t.update(1420, .{}));
    // Mudo corta na hora e esquece o rabo.
    try t_expect(t.update(2000, .{ .voice = true }));
    try t_expect(!t.update(2020, .{ .voice = true, .blocked = true }));
    try t_expect(!t.update(2040, .{}));
}

test "aperte para falar: tecla manda, voz não; folga ao soltar" {
    var t: Talk = .{};
    try t_expect(!t.update(1000, .{ .ptt = true, .voice = true }));
    try t_expect(t.update(1020, .{ .ptt = true, .key = true }));
    try t_expect(t.update(1040, .{ .ptt = true, .key = true }));
    try t_expect(t.update(1239, .{ .ptt = true }));
    try t_expect(!t.update(1240, .{ .ptt = true }));
    // Bloqueado (mudo pelo servidor) não transmite nem com a tecla.
    try t_expect(!t.update(1300, .{ .ptt = true, .key = true, .blocked = true }));
}

test "atalho: vai e volta como texto e como número" {
    var buf: [16]u8 = undefined;
    for ([_]Binding{ .{ .key = 44 }, .{ .key = 511 }, .{ .mouse = 4 } }) |b| {
        const s = b.format(&buf);
        try t_eq(b, Binding.parse(s));
        try t_eq(b, Binding.decode(b.encode()));
    }
    try t_eq(Binding.none, Binding.parse(""));
    try t_eq(Binding.none, Binding.parse("k:0"));
    try t_eq(Binding.none, Binding.parse("k:9999"));
    try t_eq(Binding.none, Binding.parse("m:99"));
    try t_eq(Binding.none, Binding.parse("x:4"));
    try t_eq(Binding.none, Binding.parse("k:abc"));
    try t_eq(Binding.none, Binding.decode(0));
    const none: Binding = .none;
    try t_eq(@as(usize, 0), none.format(&buf).len);
}

test "atalho: só a tecla certa muda o estado; perder o foco solta" {
    const b: Binding = .{ .key = 44 };
    try t_eq(@as(?bool, true), pttFromEvent(b, .{ .key = .{ .code = 44, .down = true } }));
    try t_eq(@as(?bool, false), pttFromEvent(b, .{ .key = .{ .code = 44, .down = false } }));
    try t_eq(@as(?bool, null), pttFromEvent(b, .{ .key = .{ .code = 45, .down = true } }));
    try t_eq(@as(?bool, null), pttFromEvent(b, .{ .mouse = .{ .button = 4, .down = true } }));
    try t_eq(@as(?bool, false), pttFromEvent(b, .focus_lost));
    const m: Binding = .{ .mouse = 4 };
    try t_eq(@as(?bool, true), pttFromEvent(m, .{ .mouse = .{ .button = 4, .down = true } }));
    try t_eq(@as(?bool, null), pttFromEvent(m, .{ .mouse = .{ .button = 5, .down = true } }));
    try t_eq(@as(?bool, null), pttFromEvent(.none, .{ .key = .{ .code = 44, .down = true } }));
}

test "dispositivo salvo: acha pelo nome, volta ao padrão se sumiu" {
    const names = [_][]const u8{ "USB Mic", "Headset \"Pro\"", "Webcam" };
    try t_eq(@as(?usize, null), pickDevice("", &names));
    try t_eq(@as(?usize, 0), pickDevice("USB Mic", &names));
    try t_eq(@as(?usize, 2), pickDevice("Webcam", &names));
    // Sumiu: padrão do sistema.
    try t_eq(@as(?usize, null), pickDevice("Placa antiga", &names));
    // Nome com aspas: salvo sem elas, continua batendo.
    var buf: [max_name]u8 = undefined;
    try t_eq(@as(?usize, 1), pickDevice(cleanName(&buf, "Headset \"Pro\""), &names));
    try std.testing.expectEqualStrings("Headset Pro", cleanName(&buf, "Head\\set \"Pro\"\n"));
    // Nome enorme: corta igual nos dois lados.
    const long: [400]u8 = @splat('x');
    const saved = cleanName(&buf, &long);
    try t_eq(@as(usize, max_name), saved.len);
    try t_expect(sameName(saved, &long));
}

test "qualidade pelo ping" {
    try t_eq(Quality.unknown, qualityOf(0));
    try t_eq(Quality.good, qualityOf(40));
    try t_eq(Quality.fair, qualityOf(180));
    try t_eq(Quality.bad, qualityOf(600));
}

test "bipes: curtos, sem estourar, sem estalo no fim, diferentes entre si" {
    var buf: [max_sound_len]i16 = undefined;
    var rms: [4]f32 = undefined;
    for (std.enums.values(Sound), 0..) |snd, i| {
        const len = soundLen(snd);
        try t_expect(len > 0 and len <= max_sound_len);
        const pcm = synth(snd, &buf);
        try t_eq(len, pcm.len);
        rms[i] = rmsOf(pcm);
        try t_expect(rms[i] > 300);
        var peak: i32 = 0;
        for (pcm) |x| peak = @max(peak, @as(i32, @intCast(@abs(x))));
        // Bem abaixo do fundo de escala, para não assustar ninguém.
        try t_expect(peak < 16000);
        // Termina perto de zero.
        try t_expect(@abs(@as(i32, pcm[pcm.len - 2])) < 200);
    }
    // Entrar e sair têm as mesmas notas na ordem inversa; mudar e desmutar, não.
    const a = synth(.join, &buf)[0..4000];
    var first: [4000]i16 = undefined;
    @memcpy(&first, a);
    try t_expect(!std.mem.eql(i16, &first, synth(.leave, &buf)[0..4000]));
    try t_expect(soundLen(.mute) < soundLen(.join));
}
