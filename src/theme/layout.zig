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
//!   when / unless     só aparece com a opção do tema ligada / desligada
//!                     (`modo-claro` e `modo-escuro` também valem)
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

/// Consulta às opções do tema (`when="crt"`).
pub const Options = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8) ?bool,
    /// Componentes desligados pelo usuário (lista de membros, barra de
    /// status): não ocupam espaço. Coluna que só existia para eles some junto.
    hides: []const []const u8 = &.{},

    fn on(o: ?Options, name: []const u8) bool {
        const x = o orelse return true;
        return x.get(x.ctx, name) orelse false;
    }
};

const Env = struct { win_w: f32, opts: ?Options };

fn visible(n: *const kdl.Node, env: Env) bool {
    if (n.flag("show")) |s| if (!s) return false;
    if (num(n, "hide-below")) |w| if (env.win_w < w) return false;
    if (n.str("when")) |o| if (!Options.on(env.opts, o)) return false;
    if (n.str("unless")) |o| if (env.opts != null and Options.on(env.opts, o)) return false;
    if (env.opts) |o| if (o.hides.len > 0 and onlyHidden(n, o.hides)) return false;
    return true;
}

fn isHiddenName(name: []const u8, hides: []const []const u8) bool {
    for (hides) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

/// O nó é um componente escondido, ou um contêiner em que sobrou só
/// decoração (título, espaço, régua) em volta de um componente escondido.
fn onlyHidden(n: *const kdl.Node, hides: []const []const u8) bool {
    if (axisOf(n.name) == null) return isHiddenName(n.name, hides);
    var found = false;
    for (n.children) |*ch| {
        if (axisOf(ch.name) != null) {
            if (onlyHidden(ch, hides)) {
                found = true;
            } else if (!decorative(ch)) return false;
        } else if (isHiddenName(ch.name, hides)) {
            found = true;
        } else if (!isDecoration(ch.name)) return false;
    }
    return found;
}

/// Componentes que só enfeitam: não seguram uma coluna de pé sozinhos.
const decoration = std.StaticStringMap(void).initComptime(.{
    .{"label"}, .{"spacer"}, .{"shape"}, .{"rule"}, .{"starfield"}, .{"orbit"}, .{"aurora"}, .{"dunes"}, .{"topography"}, .{"radar"},
});

fn isDecoration(name: []const u8) bool {
    return decoration.has(name);
}

/// Contêiner sem nenhum componente de verdade dentro (réguas, títulos).
fn decorative(n: *const kdl.Node) bool {
    for (n.children) |*ch| {
        if (axisOf(ch.name) != null) {
            if (!decorative(ch)) return false;
        } else if (!isDecoration(ch.name)) return false;
    }
    return true;
}

/// Resolve o layout. `out` recebe os nós na ordem de desenho (pais antes).
pub fn solve(gpa: std.mem.Allocator, root: *const kdl.Node, bounds: Rect, win_w: f32, out: *std.ArrayList(Placed)) !void {
    return solveWith(gpa, root, bounds, win_w, null, out);
}

pub fn solveWith(gpa: std.mem.Allocator, root: *const kdl.Node, bounds: Rect, win_w: f32, opts: ?Options, out: *std.ArrayList(Placed)) !void {
    out.clearRetainingCapacity();
    const env: Env = .{ .win_w = win_w, .opts = opts };
    for (root.children) |*ch| {
        if (!visible(ch, env)) continue;
        try place(gpa, ch, bounds, env, out, 0);
        break; // a raiz tem um único filho
    }
}

fn place(gpa: std.mem.Allocator, n: *const kdl.Node, rect_in: Rect, env: Env, out: *std.ArrayList(Placed), depth: u8) !void {
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
        for (n.children) |*ch| if (visible(ch, env)) try place(gpa, ch, inner, env, out, depth + 1);
        return;
    }

    const size_key = if (axis == .row) "width" else "height";
    const main_total = if (axis == .row) inner.w else inner.h;

    var count: usize = 0;
    var fixed: f32 = 0;
    var weights: f32 = 0;
    for (n.children) |*ch| {
        if (!visible(ch, env)) continue;
        count += 1;
        if (num(ch, size_key)) |s| fixed += s else weights += num(ch, "flex") orelse 1;
    }
    if (count == 0) return;
    const gaps = gap * @as(f32, @floatFromInt(count - 1));
    const free = @max(0, main_total - fixed - gaps);

    var cursor = if (axis == .row) inner.x else inner.y;
    for (n.children) |*ch| {
        if (!visible(ch, env)) continue;
        const size = num(ch, size_key) orelse free * (num(ch, "flex") orelse 1) / @max(weights, 0.0001);
        const r: Rect = if (axis == .row)
            .{ .x = cursor, .y = inner.y, .w = size, .h = inner.h }
        else
            .{ .x = inner.x, .y = cursor, .w = inner.w, .h = size };
        try place(gpa, ch, r, env, out, depth + 1);
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

test "when e unless seguem as opções" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), "layout { row { a when=crt; b unless=crt; c } }", null);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const Look = struct {
        fn get(_: *const anyopaque, name: []const u8) ?bool {
            return std.mem.eql(u8, name, "crt");
        }
    };
    try solveWith(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 300, .h = 100 }, 300, .{ .ctx = &out, .get = Look.get }, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len); // row + a + c
    try std.testing.expectEqualStrings("a", out.items[1].node.name);
    try std.testing.expectEqualStrings("c", out.items[2].node.name);
}

test "coluna só com enfeites em volta do que foi escondido some junto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), "layout { row { messages; column width=200 { label text=\"x\"; rule height=3; shape; member-list } } }", null);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const Look = struct {
        fn get(_: *const anyopaque, _: []const u8) ?bool {
            return false;
        }
    };
    const hides = [_][]const u8{"member-list"};
    try solveWith(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 500, .h = 100 }, 500, .{ .ctx = &out, .get = Look.get, .hides = &hides }, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // row + messages
    try std.testing.expectEqual(@as(f32, 500), out.items[1].rect.w);
}
