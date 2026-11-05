//! A árvore que um plugin publica para o painel lateral: só dados, sem nada de
//! Lua. A thread dos plugins monta e entrega pronta; a interface troca o
//! ponteiro e desenha (ui/plugin_panel.zig), sem nunca chamar o plugin por quadro.
const std = @import("std");

pub const Kind = enum(u8) { text, heading, separator, row, button, input, list, item, bar, select, option, toggle };
pub const Style = enum(u8) { normal, muted, accent, danger };

pub const none: u32 = std.math.maxInt(u32);

pub const max_nodes = 4000;
pub const max_bytes = 1024 * 1024;
pub const max_text = 8 * 1024;

pub const Node = struct {
    kind: Kind,
    style: Style = .normal,
    next: u32 = none,
    child: u32 = none,
    /// Texto, rótulo do botão, da lista de opções ou da opção, ou título do item.
    text: []const u8 = "",
    /// Dica do campo de texto ou do interruptor, ou subtítulo do item.
    sub: []const u8 = "",
    /// Valor inicial do campo, o texto à direita do item e da barra, ou o valor da
    /// lista de opções e de cada opção.
    meta: []const u8 = "",
    /// Nome estável (campos de texto e QA).
    key: []const u8 = "",
    /// Funções do plugin (0 = nenhuma).
    click: u32 = 0,
    change: u32 = 0,
    submit: u32 = 0,
    /// A barra, ou o interruptor (0 ou 1).
    value: f32 = 0,
    max: f32 = 0,
    /// Campo de texto que se esvazia ao enviar.
    clear: bool = false,
    // Medidas (só a interface mexe, refeitas quando a largura muda).
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    first: u32 = none,
    title: []const u8 = "",
    /// Número curto na etiqueta e no botão do painel ("" = nenhum).
    badge: []const u8 = "",
    /// As opções do cartão na página de plugins, não o painel lateral.
    settings: bool = false,
    bytes: usize = 0,
    /// Número desta árvore (a interface dá ao receber).
    serial: u32 = 0,
    // Medidas (só a interface mexe).
    layout_w: f32 = -1,
    layout_key: u32 = 0,
    height: f32 = 0,

    pub fn create(gpa: std.mem.Allocator) !*Tree {
        const t = try gpa.create(Tree);
        t.* = .{ .arena = .init(gpa), .gpa = gpa };
        return t;
    }

    pub fn destroy(t: *Tree) void {
        const gpa = t.gpa;
        t.nodes.deinit(gpa);
        t.arena.deinit();
        gpa.destroy(t);
    }

    pub fn text(t: *Tree, s: []const u8) ![]const u8 {
        if (s.len == 0) return "";
        var n = @min(s.len, max_text);
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
        if (t.bytes + n > max_bytes) return error.TooBig;
        t.bytes += n;
        return t.arena.allocator().dupe(u8, s[0..n]);
    }

    pub fn add(t: *Tree, n: Node) !u32 {
        if (t.nodes.items.len >= max_nodes) return error.TooBig;
        try t.nodes.append(t.gpa, n);
        return @intCast(t.nodes.items.len - 1);
    }
};

test "árvore: montar e limites" {
    const gpa = std.testing.allocator;
    const t = try Tree.create(gpa);
    defer t.destroy();
    const a = try t.add(.{ .kind = .text, .text = try t.text("oi") });
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqualStrings("oi", t.nodes.items[0].text);
    // Corta textos enormes sem partir um caractere.
    var big: [max_text + 10]u8 = undefined;
    @memset(&big, 'x');
    @memcpy(big[max_text - 1 .. max_text + 1], "ã");
    const cut = try t.text(&big);
    try std.testing.expectEqual(@as(usize, max_text - 1), cut.len);
    t.nodes.items.len = max_nodes;
    defer t.nodes.items.len = 1;
    try std.testing.expectError(error.TooBig, t.add(.{ .kind = .text }));
}
