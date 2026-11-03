//! Motor de layout: transforma a árvore `layout` do tema em retângulos.
//!
//! Contêineres: `row`, `column`, `stack`. Qualquer outro nome é um
//! componente. Propriedades:
//!   width / height    tamanho fixo no eixo do pai
//!   flex              peso do espaço que sobra (padrão 1 sem tamanho fixo)
//!   gap, padding, padding-x, padding-y
//!   max-width         limita a largura e centraliza (bom pra layouts "zen")
//!   hide-below        some quando a janela é mais estreita que isso
//!   style             estilo nomeado desenhado atrás do nó
const std = @import("std");
const kdl = @import("kdl.zig");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn inset(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
    }

    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

pub const Kind = enum { container, component };

pub const Placed = struct {
    node: *const kdl.Node,
    rect: Rect,
    kind: Kind,
    depth: u8,
};

const Axis = enum { row, column, stack };

fn axisOf(name: []const u8) ?Axis {
    if (std.mem.eql(u8, name, "row")) return .row;
    if (std.mem.eql(u8, name, "column")) return .column;
    if (std.mem.eql(u8, name, "stack")) return .stack;
    return null;
}

fn num(n: *const kdl.Node, key: []const u8) ?f32 {
    return if (n.num(key)) |v| @floatCast(v) else null;
}

fn visible(n: *const kdl.Node, win_w: f32) bool {
    if (n.flag("show")) |s| if (!s) return false;
    if (num(n, "hide-below")) |w| if (win_w < w) return false;
    return true;
}

/// Resolve o layout. `out` recebe os nós na ordem de desenho (pais antes).
pub fn solve(gpa: std.mem.Allocator, root: *const kdl.Node, bounds: Rect, win_w: f32, out: *std.ArrayList(Placed)) !void {
    out.clearRetainingCapacity();
    for (root.children) |*ch| {
        if (!visible(ch, win_w)) continue;
        try place(gpa, ch, bounds, win_w, out, 0);
        break; // a raiz tem um único filho
    }
}

fn place(gpa: std.mem.Allocator, n: *const kdl.Node, rect_in: Rect, win_w: f32, out: *std.ArrayList(Placed), depth: u8) !void {
    var rect = rect_in;
    if (num(n, "max-width")) |mw| if (rect.w > mw) {
        rect.x += (rect.w - mw) / 2;
        rect.w = mw;
    };
    const axis = axisOf(n.name) orelse {
        try out.append(gpa, .{ .node = n, .rect = rect, .kind = .component, .depth = depth });
        return;
    };
    try out.append(gpa, .{ .node = n, .rect = rect, .kind = .container, .depth = depth });

    const pad = num(n, "padding") orelse 0;
    const inner = rect.inset(num(n, "padding-x") orelse pad, num(n, "padding-y") orelse pad);
    const gap = num(n, "gap") orelse 0;

    if (axis == .stack) {
        for (n.children) |*ch| if (visible(ch, win_w)) try place(gpa, ch, inner, win_w, out, depth + 1);
        return;
    }

    const size_key = if (axis == .row) "width" else "height";
    const main_total = if (axis == .row) inner.w else inner.h;

    var count: usize = 0;
    var fixed: f32 = 0;
    var weights: f32 = 0;
    for (n.children) |*ch| {
        if (!visible(ch, win_w)) continue;
        count += 1;
        if (num(ch, size_key)) |s| fixed += s else weights += num(ch, "flex") orelse 1;
    }
    if (count == 0) return;
    const gaps = gap * @as(f32, @floatFromInt(count - 1));
    const free = @max(0, main_total - fixed - gaps);

    var cursor = if (axis == .row) inner.x else inner.y;
    for (n.children) |*ch| {
        if (!visible(ch, win_w)) continue;
        const size = num(ch, size_key) orelse free * (num(ch, "flex") orelse 1) / @max(weights, 0.0001);
        const r: Rect = if (axis == .row)
            .{ .x = cursor, .y = inner.y, .w = size, .h = inner.h }
        else
            .{ .x = inner.x, .y = cursor, .w = inner.w, .h = size };
        try place(gpa, ch, r, win_w, out, depth + 1);
        cursor += size + gap;
    }
}

test "row com fixo + flex, gap e hide-below" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(),
        \\layout {
        \\  row gap=10 padding=10 {
        \\    a width=100
        \\    b flex=2
        \\    c flex=1
        \\    d width=50 hide-below=2000
        \\  }
        \\}
    , null);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    try solve(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 440, .h = 100 }, 440, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // row + a, b, c
    try std.testing.expectEqual(@as(f32, 10), out.items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 100), out.items[1].rect.w);
    // livre = 420 - 100 - 2*10 = 300 -> b=200, c=100
    try std.testing.expectEqual(@as(f32, 200), out.items[2].rect.w);
    try std.testing.expectEqual(@as(f32, 120), out.items[2].rect.x);
    try std.testing.expectEqual(@as(f32, 100), out.items[3].rect.w);
    try std.testing.expectEqual(@as(f32, 80), out.items[3].rect.h);
}

test "max-width centraliza" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), "layout { column max-width=600 { m } }", null);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    try solve(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 1000, .h = 500 }, 1000, &out);
    try std.testing.expectEqual(@as(f32, 200), out.items[0].rect.x);
    try std.testing.expectEqual(@as(f32, 600), out.items[1].rect.w);
}
