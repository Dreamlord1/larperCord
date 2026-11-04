//! Cor de destaque por servidor ("Cor do servidor" no menu do servidor):
//! vale enquanto o servidor está aberto, por cima da cor de destaque das
//! configurações e das cores personalizadas do tema. Salva em settings.kdl:
//!
//!     guild-color "123456789012345678" color="#eb459e"
//!
//! (o ID vai como texto: um número no KDL viraria f64 e perderia dígitos.)
const std = @import("std");
const theme = @import("../theme/theme.zig");
const custom = @import("../theme/custom.zig");
const Rgba = @import("../theme/color.zig").Rgba;
const Id = @import("../core/types.zig").Id;

/// Servidor → cor (0xRRGGBB).
pub const Map = std.AutoHashMapUnmanaged(Id, u32);

pub var colors: Map = .empty;
/// Cor aplicada às cores do ImGui no último quadro (para reaplicar só quando muda).
var applied: ?u32 = null;

pub fn get(guild: Id) ?u32 {
    if (guild == 0) return null;
    return colors.get(guild);
}

/// `rgb` null volta para a cor de sempre.
pub fn set(guild: Id, rgb: ?u32) void {
    if (guild == 0) return;
    if (rgb) |v| colors.put(std.heap.c_allocator, guild, v) catch {} else _ = colors.remove(guild);
}

/// Pinta o destaque (e o texto em cima dele, preto ou branco pelo contraste).
pub fn apply(t: *theme.Theme, rgb: u32) void {
    const col = Rgba.hex(rgb);
    t.colors.set(.accent, col);
    t.colors.set(.accent_text, if (col.luma() > 0.6) Rgba.black else Rgba.white);
}

/// A cor efetiva mudou desde o último quadro (trocou de servidor ou de cor)?
pub fn changed(guild: Id) bool {
    const now = get(guild);
    if (now == applied) return false;
    applied = now;
    return true;
}

pub fn write(map: *const Map, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var it = map.iterator();
    while (it.next()) |e| try out.print(gpa, "guild-color \"{d}\" color=\"#{x:0>6}\"\n", .{ e.key_ptr.*, e.value_ptr.* });
}

/// Lê um nó `guild-color` do settings.kdl (outros nós são ignorados).
pub fn load(map: *Map, gpa: std.mem.Allocator, node: anytype) void {
    if (!std.mem.eql(u8, node.name, "guild-color")) return;
    const id_s = (node.arg(0) orelse return).asString() orelse return;
    const id = std.fmt.parseInt(Id, id_s, 10) catch return;
    if (id == 0) return;
    const v = custom.parseHex(node.str("color") orelse return) orelse return;
    map.put(gpa, id, v >> 8) catch {};
}

test "cor do servidor vai e volta pelo KDL (sem perder dígitos do ID)" {
    const kdl = @import("../theme/kdl.zig");
    const gpa = std.testing.allocator;
    var m: Map = .empty;
    defer m.deinit(gpa);
    try m.put(gpa, 1234567890123456789, 0xEB459E);
    try m.put(gpa, 42, 0x1ABC9C);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(&m, &out, gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Map = .empty;
    defer back.deinit(gpa);
    for (nodes) |*n| load(&back, gpa, n);
    try std.testing.expectEqual(@as(u32, 2), back.count());
    try std.testing.expectEqual(@as(?u32, 0xEB459E), back.get(1234567890123456789));
    try std.testing.expectEqual(@as(?u32, 0x1ABC9C), back.get(42));

    // Texto em cima do destaque: preto num destaque claro, branco num escuro.
    var t: theme.Theme = undefined;
    apply(&t, 0xF0B232);
    try std.testing.expectEqual(Rgba.black, t.colors.get(.accent_text));
    apply(&t, 0x5865F2);
    try std.testing.expectEqual(Rgba.white, t.colors.get(.accent_text));
}
