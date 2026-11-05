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
    /// Painel que a pessoa pode alargar (ver `Options.sizes`).
    handle: ?Handle = null,
};

/// Alça de um painel ajustável: qual deles (índice em `Options.sizes`), de que
/// lado fica o espaço que ele troca com a conversa e o x da divisa (no meio do
/// `gap`, se houver um).
pub const Handle = struct {
    size: u8,
    side: Side,
    x: f32,

    pub const Side = enum { left, right };
};

/// Quanto a pessoa alargou (ou estreitou) um painel, em relação ao que o tema
/// pediu. Vale para o filho de largura fixa de uma `row` que tem o componente
/// `name` dentro: assim a escolha vai junto de um tema para outro.
pub const Size = struct { name: []const u8, delta: f32 };

const Axis = enum { row, column, stack };

fn axisOf(name: []const u8) ?Axis {
    if (std.mem.eql(u8, name, "row")) return .row;
    if (std.mem.eql(u8, name, "column")) return .column;
    if (std.mem.eql(u8, name, "stack")) return .stack;
    return null;
}

fn num(n: *const kdl.Node, key: []const u8) ?f32 {
    // Número de um arquivo do usuário: 1e39 não vira infinito na conta do layout.
    return if (n.num(key)) |v| @floatCast(std.math.clamp(v, -20_000, 20_000)) else null;
}

/// Consulta às opções do tema (`when="crt"`).
pub const Options = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8) ?bool,
    /// Componentes desligados pelo usuário (lista de membros, barra de
    /// status): não ocupam espaço. Coluna que só existia para eles some junto.
    hides: []const []const u8 = &.{},
    /// Painéis com a largura ajustada pela pessoa.
    sizes: []const Size = &.{},

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

/// Largura do componente `name` no layout resolvido (a conversa).
pub fn widthOf(placed: []const Placed, name: []const u8) ?f32 {
    for (placed) |p| if (p.kind == .component and std.mem.eql(u8, p.node.name, name)) return p.rect.w;
    return null;
}

/// Resolve com as larguras da pessoa e garante a conversa: o que ela deu a mais
/// aos painéis volta enquanto `main` tiver menos de `min_main`. O pedido fica
/// guardado (quem chama passa uma cópia em `sizes`, que sai com o que valeu):
/// a janela crescendo de novo, os painéis voltam. O que o tema pediu não muda.
pub fn solveSized(gpa: std.mem.Allocator, root: *const kdl.Node, bounds: Rect, win_w: f32, opts: Options, sizes: []Size, main: []const u8, min_main: f32, out: *std.ArrayList(Placed)) !void {
    var o = opts;
    o.sizes = sizes;
    try solveWith(gpa, root, bounds, win_w, o, out);
    var need = min_main - (widthOf(out.items, main) orelse return);
    if (need <= 0) return;
    // Da direita para a esquerda da lista: os membros cedem antes dos canais.
    var changed = false;
    var i = sizes.len;
    while (i > 0 and need > 0) {
        i -= 1;
        // Painel escondido não devolve nada.
        const shown = for (out.items) |p| {
            if (p.handle) |h| if (h.size == i) break true;
        } else false;
        if (!shown) continue;
        const give = @min(sizes[i].delta, need);
        if (give <= 0) continue;
        sizes[i].delta -= give;
        need -= give;
        changed = true;
    }
    if (changed) try solveWith(gpa, root, bounds, win_w, o, out);
}

/// Larguras da tela dividida: `a` e `b` são as divisas entre os painéis (em
/// milésimos da largura; `b` só vale com três). Ninguém fica menor que `min_w`;
/// sem espaço para isso, os painéis dividem igual. Em pixels inteiros que somam `total`.
pub fn paneWidths(total: f32, count: usize, a: i16, b: i16, min_w: f32) [3]f32 {
    var out: [3]f32 = @splat(0);
    if (count == 0) return out;
    const n: f32 = @floatFromInt(count);
    if (count == 1) {
        out[0] = total;
        return out;
    }
    if (total < min_w * n) {
        const each = @floor(total / n);
        for (out[0..count]) |*w| w.* = each;
        out[count - 1] = total - each * (n - 1);
        return out;
    }
    const ka = @as(f32, @floatFromInt(a)) / 1000;
    const kb = @as(f32, @floatFromInt(b)) / 1000;
    out[0] = @floor(std.math.clamp(total * ka, min_w, total - min_w * (n - 1)));
    if (count == 2) {
        out[1] = total - out[0];
        return out;
    }
    const second = @floor(std.math.clamp(total * kb, out[0] + min_w, total - min_w));
    out[1] = second - out[0];
    out[2] = total - second;
    return out;
}

/// O componente `name` (visível) está dentro deste nó?
fn holds(n: *const kdl.Node, name: []const u8, env: Env) bool {
    if (axisOf(n.name) == null) return std.mem.eql(u8, n.name, name);
    for (n.children) |*ch| if (visible(ch, env) and holds(ch, name, env)) return true;
    return false;
}

/// Qual painel ajustável é este filho de uma `row` (só os de largura fixa).
fn sizeIndex(ch: *const kdl.Node, env: Env) ?u8 {
    const o = env.opts orelse return null;
    if (o.sizes.len == 0 or num(ch, "width") == null) return null;
    for (o.sizes, 0..) |sz, i| if (holds(ch, sz.name, env)) return @intCast(i);
    return null;
}

fn sizeDelta(ch: *const kdl.Node, env: Env) f32 {
    const i = sizeIndex(ch, env) orelse return 0;
    return env.opts.?.sizes[i].delta;
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
    // Só numa `row` a pessoa muda a largura; e o painel precisa de um vizinho
    // flexível de quem tirar o espaço.
    var first_flex: ?usize = null;
    var last_flex: ?usize = null;
    for (n.children, 0..) |*ch, i| {
        if (!visible(ch, env)) continue;
        count += 1;
        if (num(ch, size_key)) |s| {
            fixed += @max(s + (if (axis == .row) sizeDelta(ch, env) else 0), 0);
        } else {
            weights += num(ch, "flex") orelse 1;
            if (first_flex == null) first_flex = i;
            last_flex = i;
        }
    }
    if (count == 0) return;
    const gaps = gap * @as(f32, @floatFromInt(count - 1));
    const free = @max(0, main_total - fixed - gaps);

    var cursor = if (axis == .row) inner.x else inner.y;
    for (n.children, 0..) |*ch, i| {
        if (!visible(ch, env)) continue;
        const delta = if (axis == .row) sizeDelta(ch, env) else 0;
        const size = if (num(ch, size_key)) |s| @max(s + delta, 0) else free * (num(ch, "flex") orelse 1) / @max(weights, 0.0001);
        const r: Rect = if (axis == .row)
            .{ .x = cursor, .y = inner.y, .w = size, .h = inner.h }
        else
            .{ .x = inner.x, .y = cursor, .w = inner.w, .h = size };
        const at = out.items.len;
        try place(gpa, ch, r, env, out, depth + 1);
        if (axis == .row) if (sizeIndex(ch, env)) |si| if (first_flex != null) {
            const after = last_flex.? > i;
            out.items[at].handle = .{
                .size = si,
                .side = if (after) .right else .left,
                .x = if (after) r.right() + gap / 2 else r.x - gap / 2,
            };
        };
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

const Noop = struct {
    fn get(_: *const anyopaque, _: []const u8) ?bool {
        return false;
    }
};

fn sizedNodes(arena: std.mem.Allocator) ![]const kdl.Node {
    return kdl.parse(arena,
        \\layout {
        \\  row gap=10 {
        \\    guild-bar width=70
        \\    column width=240 { channel-list; user-panel height=50 }
        \\    column flex=1 { messages }
        \\    member-list width=200 hide-below=1000
        \\  }
        \\}
    , null);
}

test "a pessoa alarga os painéis, com a alça do lado da conversa" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try sizedNodes(arena.allocator());
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const sizes = [_]Size{ .{ .name = "channel-list", .delta = 60 }, .{ .name = "member-list", .delta = -40 } };
    try solveWith(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 1200, .h = 800 }, 1200, .{ .ctx = &out, .get = Noop.get, .sizes = &sizes }, &out);
    var channels: ?Placed = null;
    var members: ?Placed = null;
    for (out.items) |p| if (p.handle) |h| {
        if (h.size == 0) channels = p else members = p;
    };
    // A coluna inteira alarga (com o painel do usuário junto).
    try std.testing.expectEqual(@as(f32, 300), channels.?.rect.w);
    try std.testing.expectEqual(Handle.Side.right, channels.?.handle.?.side);
    try std.testing.expectEqual(@as(f32, 385), channels.?.handle.?.x); // 80 + 300 + gap/2
    try std.testing.expectEqual(@as(f32, 160), members.?.rect.w);
    try std.testing.expectEqual(Handle.Side.left, members.?.handle.?.side);
    try std.testing.expectEqual(@as(f32, 1035), members.?.handle.?.x);
    // A conversa fica com o que sobrou.
    try std.testing.expectEqual(@as(f32, 1200 - 70 - 300 - 160 - 30), widthOf(out.items, "messages").?);
}

test "janela estreita: o que foi alargado volta, sem mexer no que o tema pediu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try sizedNodes(arena.allocator());
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const opts: Options = .{ .ctx = &out, .get = Noop.get };

    // Sobra 1000-70-400-200-30 = 300; a conversa pede 360: os membros (sem
    // nada a mais) não têm o que dar, e os canais devolvem 60.
    var sizes = [_]Size{ .{ .name = "channel-list", .delta = 160 }, .{ .name = "member-list", .delta = 0 } };
    try solveSized(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 1000, .h = 800 }, 1000, opts, &sizes, "messages", 360, &out);
    try std.testing.expectEqual(@as(f32, 100), sizes[0].delta);
    try std.testing.expectEqual(@as(f32, 360), widthOf(out.items, "messages").?);

    // Os membros, com largura a mais, cedem primeiro.
    sizes = .{ .{ .name = "channel-list", .delta = 100 }, .{ .name = "member-list", .delta = 100 } };
    try solveSized(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 1000, .h = 800 }, 1000, opts, &sizes, "messages", 360, &out);
    try std.testing.expectEqual(@as(f32, 100), sizes[0].delta);
    try std.testing.expectEqual(@as(f32, 0), sizes[1].delta);
    try std.testing.expectEqual(@as(f32, 360), widthOf(out.items, "messages").?);

    // Sem membros na tela (hide-below): eles não devolvem o que não ocupam.
    sizes = .{ .{ .name = "channel-list", .delta = 200 }, .{ .name = "member-list", .delta = 100 } };
    try solveSized(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 800, .h = 800 }, 800, opts, &sizes, "messages", 360, &out);
    try std.testing.expectEqual(@as(f32, 100), sizes[1].delta);
    try std.testing.expectEqual(@as(f32, 110), sizes[0].delta);
    try std.testing.expectEqual(@as(f32, 360), widthOf(out.items, "messages").?);

    // Sobrando pouco mesmo sem nada a mais: fica como o tema pediu, sem encolher.
    sizes = .{ .{ .name = "channel-list", .delta = 0 }, .{ .name = "member-list", .delta = -20 } };
    try solveSized(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 500, .h = 800 }, 500, opts, &sizes, "messages", 360, &out);
    try std.testing.expectEqual(@as(f32, 0), sizes[0].delta);
    try std.testing.expectEqual(@as(f32, 170), widthOf(out.items, "messages").?);
}

test "layout sem painel ajustável não ganha alça" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Sem vizinho flexível, e num tema só de conversa.
    const nodes = try kdl.parse(arena.allocator(), "layout { row { column width=200 { channel-list }; member-list width=200 } }", null);
    var out: std.ArrayList(Placed) = .empty;
    defer out.deinit(std.testing.allocator);
    const sizes = [_]Size{ .{ .name = "channel-list", .delta = 50 }, .{ .name = "member-list", .delta = 0 } };
    try solveWith(std.testing.allocator, &nodes[0], .{ .x = 0, .y = 0, .w = 600, .h = 100 }, 600, .{ .ctx = &out, .get = Noop.get, .sizes = &sizes }, &out);
    for (out.items) |p| try std.testing.expect(p.handle == null);
}

test "tela dividida: divisas, mínimo de cada painel e janela sem espaço" {
    const eq = std.testing.expectEqual;
    // Dois painéis meio a meio somam o total.
    var ws = paneWidths(1000, 2, 500, 0, 200);
    try eq(@as(f32, 500), ws[0]);
    try eq(@as(f32, 500), ws[1]);
    ws = paneWidths(1000, 2, 700, 0, 200);
    try eq(@as(f32, 700), ws[0]);
    try eq(@as(f32, 300), ws[1]);
    // Passou do mínimo: para nele.
    ws = paneWidths(1000, 2, 950, 0, 200);
    try eq(@as(f32, 800), ws[0]);
    try eq(@as(f32, 200), ws[1]);
    ws = paneWidths(1000, 2, 10, 0, 200);
    try eq(@as(f32, 200), ws[0]);
    // Três: cada divisa mexe só nos dois vizinhos dela.
    ws = paneWidths(1200, 3, 600, 800, 200);
    try eq(@as(f32, 720), ws[0]);
    try eq(@as(f32, 240), ws[1]);
    try eq(@as(f32, 240), ws[2]);
    // Divisas trocadas ou coladas (arquivo editado à mão): o do meio não some.
    ws = paneWidths(1200, 3, 600, 300, 200);
    try eq(@as(f32, 720), ws[0]);
    try eq(@as(f32, 200), ws[1]);
    try eq(@as(f32, 280), ws[2]);
    // Janela sem espaço para o mínimo: todos iguais, e ainda somam o total.
    ws = paneWidths(301, 2, 900, 0, 200);
    try eq(@as(f32, 150), ws[0]);
    try eq(@as(f32, 151), ws[1]);
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
