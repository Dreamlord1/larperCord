//! Supressão de ruído do microfone. O caminho de captura (core/voz.zig) fala só
//! com `Supressor`, e `Supressor` só com a interface `Engine`: taxa, tamanho do
//! quadro e processar. Um motor novo é um `Engine` e uma linha em `Mode`.
//!
//! O microfone entrega 20 ms em estéreo; os motores trabalham em mono, com
//! float na escala de i16. Nada aloca por quadro: o estado nasce uma vez, na
//! thread que lê o microfone, e só enquanto a opção está ligada. O RNNoise
//! devolve o som 20 ms depois (960 amostras: a janela e um quadro guardado).
const std = @import("std");
const voz = @import("voz.zig");

/// O que um motor de supressão precisa oferecer.
pub const Engine = struct {
    /// Taxa de amostragem que ele exige (hoje, a do microfone: ver o teste).
    rate: u32,
    /// Amostras mono por quadro (precisa dividir o quadro do microfone).
    frame: usize,
    create: *const fn () ?*anyopaque,
    destroy: *const fn (*anyopaque) void,
    /// `out` e `in` têm `frame` amostras. Devolve a probabilidade de voz deste
    /// quadro (0..1), para quem souber dar uma.
    process: *const fn (state: *anyopaque, out: [*]f32, in: [*]const f32) ?f32,
};

/// O que está salvo em settings.kdl (`voice_denoise`), pelo número.
pub const Mode = enum(u8) {
    off = 0,
    rnnoise = 1,

    pub const default: Mode = .rnnoise;

    /// Número desconhecido (um arquivo de outra versão): o padrão.
    pub fn fromByte(v: u8) Mode {
        return std.enums.fromInt(Mode, v) orelse default;
    }

    fn engine(m: Mode) ?*const Engine {
        return switch (m) {
            .off => null,
            .rnnoise => &rnnoise_engine,
        };
    }
};

// --- RNNoise (third_party/rnnoise) ------------------------------------------

const DenoiseState = opaque {};
extern fn rnnoise_get_size() c_int;
extern fn rnnoise_get_frame_size() c_int;
extern fn rnnoise_init(st: *DenoiseState, model: ?*anyopaque) c_int;
extern fn rnnoise_destroy(st: *DenoiseState) void;
extern fn rnnoise_process_frame(st: *DenoiseState, out: [*]f32, in: [*]const f32) f32;

const rnnoise_engine: Engine = .{
    .rate = 48000,
    .frame = 480,
    .create = rnnoiseCreate,
    .destroy = rnnoiseDestroy,
    .process = rnnoiseProcess,
};

/// Como rnnoise_create, mas sem seguir em frente se o malloc falhar.
fn rnnoiseCreate() ?*anyopaque {
    const mem = std.c.malloc(@intCast(rnnoise_get_size())) orelse return null;
    if (rnnoise_init(@ptrCast(mem), null) != 0) {
        std.c.free(mem);
        return null;
    }
    return mem;
}

fn rnnoiseDestroy(st: *anyopaque) void {
    rnnoise_destroy(@ptrCast(st));
}

fn rnnoiseProcess(st: *anyopaque, out: [*]f32, in: [*]const f32) ?f32 {
    return rnnoise_process_frame(@ptrCast(st), out, in);
}

// --- Conversão --------------------------------------------------------------

/// Estéreo intercalado em mono, na escala de i16.
pub fn toMono(pcm: []const i16, mono: []f32) void {
    for (mono, 0..) |*m, i| {
        const l: f32 = @floatFromInt(pcm[i * voz.channels]);
        const r: f32 = @floatFromInt(pcm[i * voz.channels + 1]);
        m.* = (l + r) / 2;
    }
}

pub fn toI16(v: f32) i16 {
    // NaN vira silêncio em vez de comportamento indefinido no @intFromFloat.
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@round(std.math.clamp(v, -32768, 32767)));
}

/// Troca `pcm` por `wet`, com a parte de `wet` indo de `from` a `to` ao longo do
/// quadro. Cada canal mistura com o que ele mesmo tinha.
fn blend(pcm: []i16, wet: []const f32, from: f32, to: f32) void {
    const n: f32 = @floatFromInt(wet.len);
    for (wet, 0..) |w, i| {
        const m = from + (to - from) * (@as(f32, @floatFromInt(i)) + 1) / n;
        for (pcm[i * voz.channels..][0..voz.channels]) |*s| {
            const dry: f32 = @floatFromInt(s.*);
            s.* = toI16(dry + (w - dry) * m);
        }
    }
}

// --- O caminho do microfone -------------------------------------------------

/// Estados vivos, nas duas threads que leem microfone (para o QA ver o custo zero).
pub var live: std.atomic.Value(i32) = .init(0);

pub const Out = struct {
    /// Probabilidade de voz, com o motor valendo por inteiro e se ele der uma.
    vad: ?f32 = null,
    /// Este quadro fez a transição com o som cru: o nível de fundo mudou de patamar.
    switched: bool = false,
};

pub const Supressor = struct {
    engine: ?*const Engine = null,
    state: ?*anyopaque = null,
    /// Quanto do motor está valendo (0 = só o som cru, 1 = só o motor).
    mix: f32 = 0,
    /// Quadros ainda sem ouvir o motor, enquanto ele acorda.
    warm: u8 = 0,
    /// O quadro anterior saiu cru. Ligar agora tem que ser sem emenda.
    passing: bool = false,
    zero_run: u32 = 0,

    /// Depois disto (100 ms), o motor já aprendeu o bastante para valer.
    const warm_frames = 5;
    /// Blocos de motor seguidos só de zeros antes de parar de chamá-lo. Até lá a
    /// saída dele some; depois, o filtro interno decairia até números subnormais,
    /// e o RNNoise chega a custar seis vezes mais em silêncio digital.
    const zero_blocks = 8;

    /// O motor em uso; `release` depois. No modo desligado é só um teste de nulo.
    pub fn process(s: *Supressor, pcm: []i16, mode: Mode) Out {
        std.debug.assert(pcm.len == voz.frame_len);
        const want = mode.engine();
        if (s.state == null) {
            const e = want orelse {
                s.passing = true;
                return .{};
            };
            s.state = e.create() orelse {
                s.passing = true;
                return .{};
            };
            _ = live.fetchAdd(1, .monotonic);
            s.engine = e;
            s.zero_run = 0;
            // Vindo do mudo não há som anterior para emendar: já começa valendo
            // (e a primeira saída do motor nasce do zero, sem estalo).
            s.mix = if (s.passing) 0 else 1;
            s.warm = if (s.passing) warm_frames else 0;
        }
        const e = s.engine.?;
        const keep = want == e;

        var mono: [voz.frame_samples]f32 = undefined;
        var wet: [voz.frame_samples]f32 = undefined;
        toMono(pcm, &mono);
        var vad: ?f32 = null;
        var i: usize = 0;
        while (i + e.frame <= voz.frame_samples) : (i += e.frame) {
            if (allZero(mono[i..][0..e.frame])) {
                s.zero_run +|= 1;
                if (s.zero_run > zero_blocks) {
                    @memset(wet[i..][0..e.frame], 0);
                    vad = @max(vad orelse 0, 0);
                    continue;
                }
            } else s.zero_run = 0;
            const p = e.process(s.state.?, wet[i..].ptr, mono[i..].ptr);
            if (p) |v| vad = @max(vad orelse 0, v);
        }

        const from = s.mix;
        const to: f32 = if (keep and s.warm == 0) 1 else 0;
        if (s.warm > 0) s.warm -= 1;
        if (from != 0 or to != 0) blend(pcm, &wet, from, to);
        s.mix = to;
        const out: Out = .{ .vad = if (from == 1 and to == 1) vad else null, .switched = from != to };
        if (!keep) {
            s.release();
            s.passing = true;
        }
        return out;
    }

    /// Solta o estado (mudo, microfone fechado, fim da call). Sem custo até a
    /// próxima vez que o microfone voltar.
    pub fn release(s: *Supressor) void {
        if (s.state) |st| {
            s.engine.?.destroy(st);
            _ = live.fetchSub(1, .monotonic);
        }
        s.* = .{};
    }

    fn allZero(block: []const f32) bool {
        for (block) |v| if (v != 0) return false;
        return true;
    }
};

// --- Testes -----------------------------------------------------------------

const t_expect = std.testing.expect;
const t_eq = std.testing.expectEqual;

/// Ruído branco uniforme (os dois canais iguais, como um microfone mono).
const Noise = struct {
    seed: u32 = 12345,

    fn fill(n: *Noise, pcm: []i16, amp: f32) void {
        var i: usize = 0;
        while (i < pcm.len) : (i += voz.channels) {
            n.seed = n.seed *% 1664525 +% 1013904223;
            const u = @as(f32, @floatFromInt(n.seed >> 8)) / (1 << 24);
            const v: i16 = @intFromFloat((u * 2 - 1) * amp);
            pcm[i] = v;
            pcm[i + 1] = v;
        }
    }
};

fn sine(pcm: []i16, hz: f32, amp: f32, phase: *f32) void {
    var i: usize = 0;
    while (i < pcm.len) : (i += voz.channels) {
        const v: i16 = @intFromFloat(@sin(phase.*) * amp);
        pcm[i] = v;
        pcm[i + 1] = v;
        phase.* = @mod(phase.* + 2 * std.math.pi * hz / voz.rate, 2 * std.math.pi);
    }
}

test "todo motor cabe no caminho do microfone" {
    for (std.enums.values(Mode)) |m| {
        const e = m.engine() orelse continue;
        try t_eq(@as(u32, voz.rate), e.rate);
        try t_eq(@as(usize, 0), voz.frame_samples % e.frame);
    }
    // Os números do RNNoise são os que a biblioteca diz.
    try t_eq(@as(usize, @intCast(rnnoise_get_frame_size())), rnnoise_engine.frame);
    try t_eq(@as(usize, 2), voz.frame_samples / rnnoise_engine.frame);
}

test "modo salvo: número conhecido, e o padrão para o resto" {
    try t_eq(Mode.off, Mode.fromByte(0));
    try t_eq(Mode.rnnoise, Mode.fromByte(1));
    try t_eq(Mode.default, Mode.fromByte(200));
}

test "conversão: mistura os canais, arredonda e satura" {
    const pcm = [_]i16{ 1000, 3000, -32768, 32767, 7, 7 };
    var mono: [3]f32 = undefined;
    toMono(&pcm, &mono);
    try t_eq(@as(f32, 2000), mono[0]);
    try t_eq(@as(f32, -0.5), mono[1]);
    try t_eq(@as(f32, 7), mono[2]);
    try t_eq(@as(i16, 32767), toI16(50000));
    try t_eq(@as(i16, -32768), toI16(-50000));
    try t_eq(@as(i16, 3), toI16(2.6));
    try t_eq(@as(i16, 0), toI16(std.math.nan(f32)));
}

test "desligado: não mexe no sinal nem cria estado" {
    var s: Supressor = .{};
    var noise: Noise = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    var copy: [voz.frame_len]i16 = undefined;
    // Canais diferentes de propósito: nem a mistura para mono pode acontecer.
    noise.fill(&pcm, 9000);
    for (0..pcm.len / 2) |i| pcm[i * 2 + 1] = -%pcm[i * 2];
    @memcpy(&copy, &pcm);
    const before = live.load(.monotonic);
    for (0..50) |_| {
        const out = s.process(&pcm, .off);
        try t_eq(@as(?f32, null), out.vad);
        try t_expect(!out.switched);
    }
    try std.testing.expectEqualSlices(i16, &copy, &pcm);
    try t_eq(@as(?*anyopaque, null), s.state);
    try t_eq(before, live.load(.monotonic));
}

test "RNNoise: ruído branco perde energia e não parece voz" {
    var s: Supressor = .{};
    defer s.release();
    var noise: Noise = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    var in_sum: f64 = 0;
    var out_sum: f64 = 0;
    for (0..150) |frame| {
        noise.fill(&pcm, 3000);
        const in_rms = voz.rmsOf(&pcm);
        const out = s.process(&pcm, .rnnoise);
        try t_eq(pcm[0], pcm[1]);
        if (frame < 50) continue;
        in_sum += in_rms * in_rms;
        const r = voz.rmsOf(&pcm);
        out_sum += r * r;
        try t_expect(out.vad.? < 0.5);
    }
    // Mais de 20 dB a menos (na prática, bem mais).
    try t_expect(out_sum * 100 < in_sum);
}

test "ligar e desligar com som passando: sem estalo, e o estado some" {
    var s: Supressor = .{};
    var ph: f32 = 0;
    var pcm: [voz.frame_len]i16 = undefined;
    var last: i32 = 0;
    var first = true;
    var worst: i32 = 0;
    const before = live.load(.monotonic);
    var switches: u32 = 0;
    for (0..240) |frame| {
        // Desligado, ligado, desligado, ligado.
        const mode: Mode = if (frame / 60 % 2 == 0) .off else .rnnoise;
        sine(&pcm, 200, 4000, &ph);
        if (s.process(&pcm, mode).switched) switches += 1;
        var i: usize = 0;
        while (i < pcm.len) : (i += voz.channels) {
            if (!first) worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, pcm[i]) - last))));
            first = false;
            last = pcm[i];
        }
    }
    // O seno sozinho anda até 105 por amostra. Trocar sem transição, com a saída
    // do RNNoise 20 ms atrasada, pularia milhares.
    try t_expect(worst < 300);
    try t_eq(@as(u32, 3), switches);
    s.release();
    try t_eq(before, live.load(.monotonic));
}

test "vindo do mudo o motor já vale; mudo solta o estado" {
    var s: Supressor = .{};
    var noise: Noise = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    const before = live.load(.monotonic);
    noise.fill(&pcm, 3000);
    const first = s.process(&pcm, .rnnoise);
    try t_expect(!first.switched);
    try t_eq(@as(f32, 1), s.mix);
    try t_eq(before + 1, live.load(.monotonic));
    s.release();
    try t_eq(before, live.load(.monotonic));
    // Soltar duas vezes não faz mal.
    s.release();
    try t_eq(before, live.load(.monotonic));
}

test "silêncio digital para de chamar o motor, continua silêncio e volta sem susto" {
    var s: Supressor = .{};
    defer s.release();
    var noise: Noise = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    for (0..20) |_| {
        noise.fill(&pcm, 3000);
        _ = s.process(&pcm, .rnnoise);
    }
    var tail_peak: i32 = 0;
    for (0..200) |frame| {
        @memset(&pcm, 0);
        _ = s.process(&pcm, .rnnoise);
        if (frame >= 10) for (pcm) |v| {
            tail_peak = @max(tail_peak, @as(i32, @intCast(@abs(@as(i32, v)))));
        };
    }
    try t_eq(@as(i32, 0), tail_peak);
    try t_expect(s.zero_run > Supressor.zero_blocks);
    // O som volta: sem estourar e o motor segue funcionando.
    for (0..100) |_| {
        noise.fill(&pcm, 3000);
        _ = s.process(&pcm, .rnnoise);
    }
    try t_eq(@as(u32, 0), s.zero_run);
    try t_expect(voz.rmsOf(&pcm) < 300);
}
