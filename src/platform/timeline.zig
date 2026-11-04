//! Linha do tempo da abertura (`--stats`): quanto tempo depois do início do
//! processo cada fase terminou. Serve para medir na conta de verdade sem
//! adivinhar. Só carimba tempos e tamanhos: nunca token, nome ou conteúdo.
//! Qualquer thread pode marcar; vale a primeira marca de cada fase (uma
//! reconexão não muda o que aconteceu na abertura).
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Phase = enum(u8) {
    main,
    janela,
    imgui,
    lista_temas,
    fontes_base,
    config,
    tema,
    fontes_tema,
    create_fim,
    tela_1,
    token_fim,
    gateway,
    curl,
    websocket,
    hello,
    identify,
    ready_1o_byte,
    ready_ultimo_byte,
    ready_inflate,
    ready_json,
    ready_eventos,
    store,
    conversa_1,
    login_fora,
    historico,

    fn label(p: Phase) []const u8 {
        return switch (p) {
            .main => "main()",
            .janela => "SDL, janela e renderizador",
            .imgui => "ImGui e backends",
            .lista_temas => "lista de temas",
            .fontes_base => "fontes: emoji e símbolos",
            .config => "contas e configurações lidas",
            .tema => "tema interpretado",
            .fontes_tema => "fontes do tema",
            .create_fim => "App.create terminou",
            .tela_1 => "primeira tela na janela",
            .token_fim => "chaveiro respondeu",
            .gateway => "início do gateway",
            .curl => "libcurl e OpenSSL iniciados",
            .websocket => "TLS e WebSocket conectados",
            .hello => "HELLO recebido",
            .identify => "IDENTIFY enviado",
            .ready_1o_byte => "READY: primeiro byte",
            .ready_ultimo_byte => "READY: último byte",
            .ready_inflate => "READY: descomprimido",
            .ready_json => "READY: JSON interpretado",
            .ready_eventos => "READY: eventos montados",
            .store => "Store aplicado",
            .conversa_1 => "primeiro quadro da conversa",
            .login_fora => "login saiu da tela",
            .historico => "histórico da conversa chegou",
        };
    }
};

const n_phases = std.enums.values(Phase).len;

pub var enabled = false;
var stamps: [n_phases]std.atomic.Value(u64) = @splat(.init(0));
var base_ns: u64 = 0;
/// Quanto o processo já tinha rodado ao chegar no main (carregar as bibliotecas).
var before_main_ms: i64 = -1;
var ready_comprimido: std.atomic.Value(u64) = .init(0);
var ready_json_bytes: std.atomic.Value(u64) = .init(0);
var reported = false;

pub fn now() u64 {
    return c.SDL_GetTicksNS();
}

pub fn begin() void {
    enabled = true;
    base_ns = now();
    before_main_ms = processAgeMs();
    mark(.main);
}

pub fn mark(p: Phase) void {
    if (enabled) markAt(p, now());
}

/// Marca com um horário já medido (o READY só é reconhecido depois de lido).
pub fn markAt(p: Phase, t: u64) void {
    if (!enabled) return;
    // +1: zero quer dizer "ainda não aconteceu".
    _ = stamps[@intFromEnum(p)].cmpxchgStrong(0, t -% base_ns +% 1, .acq_rel, .monotonic);
}

pub fn isMarked(p: Phase) bool {
    return stamps[@intFromEnum(p)].load(.acquire) != 0;
}

pub fn readySizes(comprimido: usize, json: usize) void {
    if (!enabled) return;
    _ = ready_comprimido.cmpxchgStrong(0, comprimido, .acq_rel, .monotonic);
    _ = ready_json_bytes.cmpxchgStrong(0, json, .acq_rel, .monotonic);
}

/// Imprime a tabela uma vez, em ordem de tempo.
pub fn report() void {
    if (!enabled or reported) return;
    reported = true;
    const off: f64 = @floatFromInt(@max(before_main_ms, 0));
    std.log.info("linha do tempo da abertura (ms desde o início do processo):", .{});
    if (before_main_ms >= 0) std.log.info("  {d:8.1}  (+{d:7.1})  bibliotecas carregadas (precisão de 10 ms)", .{ off, off });
    var order: [n_phases]u8 = undefined;
    var n: usize = 0;
    for (0..n_phases) |i| if (stamps[i].load(.acquire) != 0) {
        order[n] = @intCast(i);
        n += 1;
    };
    std.sort.insertion(u8, order[0..n], {}, struct {
        fn lt(_: void, a: u8, b: u8) bool {
            return stamps[a].load(.acquire) < stamps[b].load(.acquire);
        }
    }.lt);
    var prev: f64 = 0;
    for (order[0..n]) |i| {
        const ms = @as(f64, @floatFromInt(stamps[i].load(.acquire) - 1)) / 1e6;
        std.log.info("  {d:8.1}  (+{d:7.1})  {s}", .{ ms + off, ms - prev, @as(Phase, @enumFromInt(i)).label() });
        prev = ms;
    }
    const z = ready_comprimido.load(.acquire);
    const js = ready_json_bytes.load(.acquire);
    if (js > 0) std.log.info("  READY: {d:.2} MB comprimido, {d:.2} MB de JSON", .{ @as(f64, @floatFromInt(z)) / 1e6, @as(f64, @floatFromInt(js)) / 1e6 });
}

/// Idade do processo em ms (o relógio do /proc anda de 10 em 10 ms).
fn processAgeMs() i64 {
    if (builtin.os.tag != .linux) return -1;
    const fd = c.open("/proc/self/stat", c.O_RDONLY);
    if (fd < 0) return -1;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const got = c.read(fd, &buf, buf.len);
    if (got <= 0) return -1;
    const s = buf[0..@intCast(got)];
    // O nome do processo pode ter espaços: conta os campos depois do ')'.
    const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return -1;
    var it = std.mem.tokenizeScalar(u8, s[close + 1..], ' ');
    var i: usize = 3;
    while (it.next()) |f| : (i += 1) {
        if (i != 22) continue;
        const ticks = std.fmt.parseInt(i64, f, 10) catch return -1;
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.BOOTTIME, &ts) != 0) return -1;
        return (@as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000)) - ticks * 10;
    }
    return -1;
}
