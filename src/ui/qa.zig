//! Marcações para os testes de QA: os componentes registram "onde está cada
//! coisa" (ícone de servidor, canal, botão, item de menu…) e o robô de testes
//! clica nesses retângulos com eventos reais de mouse e teclado.
//! Desligado (custo zero) fora do modo `--qa`.
const std = @import("std");
const layout = @import("../theme/layout.zig");

pub var enabled = false;

const Mark = struct { key: [56]u8, len: u8, rect: layout.Rect };

var marks: [1024]Mark = undefined;
var count: usize = 0;
/// Marcações do quadro anterior (o robô lê estas, já completas).
var prev: [1024]Mark = undefined;
var prev_count: usize = 0;

pub fn beginFrame() void {
    if (!enabled) return;
    @memcpy(prev[0..count], marks[0..count]);
    prev_count = count;
    count = 0;
}

pub fn mark(r: layout.Rect, comptime fmt: []const u8, args: anytype) void {
    if (!enabled or count >= marks.len) return;
    var m: Mark = .{ .key = undefined, .len = 0, .rect = r };
    const s = std.fmt.bufPrint(&m.key, fmt, args) catch return;
    m.len = @intCast(s.len);
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

/// Lista as marcações que começam com `prefix` (para depurar um teste).
pub fn dump(prefix: []const u8) void {
    for (prev[0..prev_count]) |m| {
        const k = m.key[0..m.len];
        if (std.mem.startsWith(u8, k, prefix)) std.debug.print("  {s} @ {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{ k, m.rect.x, m.rect.y, m.rect.w, m.rect.h });
    }
}
