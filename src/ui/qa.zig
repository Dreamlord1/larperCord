//! Marcações para os testes de QA: os componentes registram "onde está cada
//! coisa" (ícone de servidor, canal, botão, item de menu…) e o robô de testes
//! clica nesses retângulos com eventos reais de mouse e teclado.
//! Desligado (custo zero) fora do modo `--qa`.
const std = @import("std");
const layout = @import("../theme/layout.zig");

pub var enabled = false;

const Mark = struct { key: [56]u8, len: u8, rect: layout.Rect };

// Com a tela dividida, até três conversas marcam ao mesmo tempo.
var marks: [2048]Mark = undefined;
var count: usize = 0;
/// Marcações do quadro anterior (o robô lê estas, já completas).
var prev: [2048]Mark = undefined;
var prev_count: usize = 0;

pub fn beginFrame() void {
    if (!enabled) return;
    @memcpy(prev[0..count], marks[0..count]);
    prev_count = count;
    count = 0;
}

/// Prefixo das marcações desenhadas agora ("pane1/" num painel lateral da
/// tela dividida): o mesmo elemento em duas conversas não se confunde.
var scope_buf: [12]u8 = undefined;
var scope_len: usize = 0;

pub fn setScope(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    scope_len = if (std.fmt.bufPrint(&scope_buf, fmt, args)) |t| t.len else |_| 0;
}

pub fn mark(r: layout.Rect, comptime fmt: []const u8, args: anytype) void {
    if (!enabled or count >= marks.len) return;
    var m: Mark = .{ .key = undefined, .len = 0, .rect = r };
    @memcpy(m.key[0..scope_len], scope_buf[0..scope_len]);
    const s = std.fmt.bufPrint(m.key[scope_len..], fmt, args) catch return;
    m.len = @intCast(scope_len + s.len);
    marks[count] = m;
    count += 1;
}

pub fn find(key: []const u8) ?layout.Rect {
    // A última marcação com o nome vence (o que foi desenhado por cima).
    var i = prev_count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, prev[i].key[0..prev[i].len], key)) return prev[i].rect;
    }
    return null;
}

/// A primeira marcação com o nome (quando dois elementos têm o mesmo
/// nome e se quer o de cima da página).
pub fn findFirst(key: []const u8) ?layout.Rect {
    for (prev[0..prev_count]) |m| {
        if (std.mem.eql(u8, m.key[0..m.len], key)) return m.rect;
    }
    return null;
}

/// Nomes das marcações do quadro anterior que começam com algum dos
/// prefixos (para a varredura "clicar em tudo").
pub fn keysWith(prefixes: []const []const u8, out: [][56]u8, lens: []u8) usize {
    var n: usize = 0;
    for (prev[0..prev_count]) |m| {
        const k = m.key[0..m.len];
        const want = for (prefixes) |p| {
            if (std.mem.startsWith(u8, k, p)) break true;
        } else false;
        // Nunca clica em "Sair" (encerraria a sessão no meio do roteiro).
        const exit = std.mem.indexOf(u8, k, "Sair") != null or std.mem.indexOf(u8, k, "Log Out") != null;
        if (!want or exit or n == out.len) continue;
        const dup = for (out[0..n], lens[0..n]) |o, l| {
            if (std.mem.eql(u8, o[0..l], k)) break true;
        } else false;
        if (dup) continue;
        out[n] = m.key;
        lens[n] = m.len;
        n += 1;
    }
    return n;
}

/// Lista as marcações que começam com `prefix` (para depurar um teste).
pub fn dump(prefix: []const u8) void {
    for (prev[0..prev_count]) |m| {
        const k = m.key[0..m.len];
        if (std.mem.startsWith(u8, k, prefix)) std.debug.print("  {s} @ {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{ k, m.rect.x, m.rect.y, m.rect.w, m.rect.h });
    }
}
