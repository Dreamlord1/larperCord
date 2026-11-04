//! Primitivas visuais opcionais dos temas, já lidas do KDL: preenchimentos
//! (gradiente, padrão, grão, vinheta), estilos v2 (borda por lado, em gradiente,
//! sombra interna, fundo no hover) e tipografia de display no `label` (tracking,
//! runs, sombra, contorno, gradiente). Quem desenha é `ui/fx.zig`.
//!
//! Tudo aqui é opcional e fica atrás de um ponteiro nulo: tema que não usa não
//! paga nada no quadro. As cores são expressões guardadas (`color.Expr`), para
//! seguirem os tokens do momento.
const std = @import("std");
const kdl = @import("kdl.zig");
const color = @import("color.zig");
pub const Expr = color.Expr;

pub const Gradient = struct {
    /// 2 ou 3 paradas.
    stops: [3]*const Expr,
    n: u8,
    /// Graus: 0 = da esquerda para a direita, 90 = de cima para baixo.
    angle: f32,
};

pub const PatternKind = enum { dots, lines, grid, diagonal };

/// Quais cantos o preenchimento arredonda (`corners=left`): uma janela feita de
/// dois painéis lado a lado, um com os cantos da esquerda, outro com os da direita.
pub const Corners = enum { all, left, right, top, bottom };

pub const Pattern = struct {
    kind: PatternKind,
    color: *const Expr,
    /// Distância entre as repetições, em pixels.
    size: f32,
    /// Espessura do traço (ou raio do ponto).
    width: f32,
};

/// O que um estilo ou um nó pode ter além de fundo chapado.
pub const Box = struct {
    gradient: ?Gradient = null,
    pattern: ?Pattern = null,
    grain: ?*const Expr = null,
    vignette: ?*const Expr = null,
    /// Onde a vinheta começa (0 = no centro, 1 = só nos cantos).
    vignette_size: f32 = 0.55,
    inner_shadow: ?*const Expr = null,
    inner_shadow_size: f32 = 14,
    hover_bg: ?*const Expr = null,
    corners: Corners = .all,
    /// Sombra macia e oca: não escurece o que está embaixo de um painel translúcido.
    drop_shadow: ?*const Expr = null,
    drop_shadow_size: f32 = 32,
    drop_shadow_y: f32 = 10,
    /// Borda inteira, só nos nós (nos estilos é o `border` de sempre).
    border: ?*const Expr = null,
    border_width: f32 = 1,
    border_gradient: ?Gradient = null,
    /// Topo, direita, base e esquerda.
    sides: [4]?*const Expr = @splat(null),
    side_widths: [4]f32 = @splat(1),

    /// Algo que vai embaixo do conteúdo do fundo (o resto é acabamento).
    pub fn hasFill(b: *const Box) bool {
        return b.gradient != null or b.pattern != null or b.grain != null or b.vignette != null or b.hover_bg != null;
    }
};

/// Mesmos pesos de `ui/fonts.zig` (o tema não depende da interface).
pub const Weight = enum(u3) { regular, medium, semibold, bold, italic };

pub const Span = struct {
    text: []const u8,
    text_en: []const u8 = "",
    /// null = herda do `label`.
    font: ?[]const u8 = null,
    weight: ?Weight = null,
    size: ?f32 = null,
    color: ?*const Expr = null,
    tracking: ?f32 = null,
};

pub const TextFx = struct {
    spans: []const Span,
    font: ?[]const u8 = null,
    weight: Weight = .semibold,
    size: f32 = 14,
    color: ?*const Expr = null,
    tracking: f32 = 0,
    shadow: ?*const Expr = null,
    shadow_x: f32 = 0,
    shadow_y: f32 = 1,
    shadow_blur: f32 = 0,
    outline: ?*const Expr = null,
    outline_width: f32 = 1,
    gradient: ?Gradient = null,
};

pub const NamedColor = struct { key: []const u8, expr: *const Expr };

/// Tudo o que um nó do layout tem de novo. Só existe para quem usa.
pub const NodeFx = struct {
    /// `bg="alpha(@accent, 0.4)"`: expressão em vez de nome de token.
    bg: ?*const Expr = null,
    box: ?*const Box = null,
    text: ?*const TextFx = null,
    /// Cores dos componentes `shape`, `rule` e dos fundos procedurais.
    colors: []const NamedColor = &.{},

    pub fn color(x: *const NodeFx, key: []const u8) ?*const Expr {
        for (x.colors) |nc| if (std.mem.eql(u8, nc.key, key)) return nc.expr;
        return null;
    }
};

pub const Problem = struct { node: *const kdl.Node, message: []const u8 };
pub const Error = error{ Invalid, OutOfMemory };

/// Contexto de compilação: de onde vêm a paleta e os tokens, e para onde vai o
/// erro (com o nó, para apontar a linha do arquivo).
pub const Cx = struct {
    a: std.mem.Allocator,
    palette: *const [16]color.Rgba,
    tokens: *const fn (name: []const u8) ?u8,
    problem: ?Problem = null,

    fn fail(cx: *Cx, n: *const kdl.Node, msg: []const u8) Error {
        cx.problem = .{ .node = n, .message = msg };
        return error.Invalid;
    }

    pub fn expr(cx: *Cx, n: *const kdl.Node, src: []const u8, msg: []const u8) Error!*const Expr {
        return color.compile(cx.a, src, cx.palette, cx.tokens) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => cx.fail(n, msg),
        };
    }

    fn opt(cx: *Cx, n: *const kdl.Node, key: []const u8, msg: []const u8) Error!?*const Expr {
        const s = n.str(key) orelse return null;
        return try cx.expr(n, s, msg);
    }
};

fn numOr(n: *const kdl.Node, key: []const u8, default: f32) f32 {
    return if (n.num(key)) |v| @floatCast(v) else default;
}

/// Parte uma lista de cores nos espaços de fora dos parênteses:
/// `"mix(@bg, black, 0.2) @surface @bg"` são três.
pub fn splitColors(src: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var depth: usize = 0;
    var start: ?usize = null;
    for (src, 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')' and depth > 0) depth -= 1;
        const sep = depth == 0 and (ch == ' ' or ch == '\t');
        if (sep) {
            if (start) |st| {
                if (n == out.len) return out.len + 1;
                out[n] = src[st..i];
                n += 1;
                start = null;
            }
        } else if (start == null) start = i;
    }
    if (start) |st| {
        if (n == out.len) return out.len + 1;
        out[n] = src[st..];
        n += 1;
    }
    return n;
}

fn parseGradient(cx: *Cx, n: *const kdl.Node, src: []const u8, angle_key: []const u8, default_angle: f32) Error!Gradient {
    var parts: [3][]const u8 = undefined;
    const count = splitColors(src, &parts);
    if (count < 2 or count > 3) return cx.fail(n, "gradiente pede 2 ou 3 cores");
    var g: Gradient = .{ .stops = undefined, .n = @intCast(count), .angle = numOr(n, angle_key, default_angle) };
    for (parts[0..count], 0..) |p, i| g.stops[i] = try cx.expr(n, p, "cor inválida no gradiente");
    if (count == 2) g.stops[2] = g.stops[1];
    return g;
}

const side_keys = [4][]const u8{ "border-top", "border-right", "border-bottom", "border-left" };
const side_width_keys = [4][]const u8{ "border-top-width", "border-right-width", "border-bottom-width", "border-left-width" };

/// Lê as primitivas de caixa de um estilo ou nó. null = não usa nenhuma.
/// `is_style`: em estilos, `border` continua sendo o campo de sempre.
pub fn parseBox(cx: *Cx, n: *const kdl.Node, is_style: bool) Error!?*const Box {
    var b: Box = .{};
    var used = false;
    if (n.str("gradient")) |s| {
        b.gradient = try parseGradient(cx, n, s, "gradient-angle", 90);
        used = true;
    }
    if (n.str("pattern")) |s| {
        const kind = std.meta.stringToEnum(PatternKind, s) orelse return cx.fail(n, "pattern: dots, lines, grid ou diagonal");
        const col = n.str("pattern-color") orelse return cx.fail(n, "pattern precisa de pattern-color");
        b.pattern = .{
            .kind = kind,
            .color = try cx.expr(n, col, "pattern-color inválida"),
            .size = std.math.clamp(numOr(n, "pattern-size", 16), 2, 128),
            .width = std.math.clamp(numOr(n, "pattern-width", 1), 0.5, 32),
        };
        used = true;
    }
    if (try cx.opt(n, "grain", "grain inválido")) |e| {
        b.grain = e;
        used = true;
    }
    if (try cx.opt(n, "vignette", "vignette inválida")) |e| {
        b.vignette = e;
        b.vignette_size = std.math.clamp(numOr(n, "vignette-size", b.vignette_size), 0, 0.95);
        used = true;
    }
    if (try cx.opt(n, "inner-shadow", "inner-shadow inválida")) |e| {
        b.inner_shadow = e;
        b.inner_shadow_size = numOr(n, "inner-shadow-size", b.inner_shadow_size);
        used = true;
    }
    if (try cx.opt(n, "drop-shadow", "drop-shadow inválida")) |e| {
        b.drop_shadow = e;
        b.drop_shadow_size = @max(numOr(n, "drop-shadow-size", b.drop_shadow_size), 1);
        b.drop_shadow_y = numOr(n, "drop-shadow-y", b.drop_shadow_y);
        used = true;
    }
    if (try cx.opt(n, "hover-bg", "hover-bg inválido")) |e| {
        b.hover_bg = e;
        used = true;
    }
    if (n.str("border-gradient")) |s| {
        b.border_gradient = try parseGradient(cx, n, s, "border-gradient-angle", 90);
        b.border_width = numOr(n, "border-width", b.border_width);
        used = true;
    }
    if (!is_style) if (try cx.opt(n, "border", "border inválida")) |e| {
        b.border = e;
        b.border_width = numOr(n, "border-width", b.border_width);
        used = true;
    };
    for (side_keys, side_width_keys, 0..) |k, wk, i| if (try cx.opt(n, k, "borda de lado inválida")) |e| {
        b.sides[i] = e;
        b.side_widths[i] = numOr(n, wk, numOr(n, "border-width", 1));
        used = true;
    };
    if (!used) return null;
    if (n.str("corners")) |s| b.corners = std.meta.stringToEnum(Corners, s) orelse return cx.fail(n, "corners: all, left, right, top ou bottom");
    const out = try cx.a.create(Box);
    out.* = b;
    return out;
}

fn parseWeight(cx: *Cx, n: *const kdl.Node) Error!?Weight {
    const s = n.str("weight") orelse return null;
    return std.meta.stringToEnum(Weight, s) orelse cx.fail(n, "weight: regular, medium, semibold, bold ou italic");
}

/// Só as propriedades novas (ou os runs) levam um `label` para o caminho novo:
/// o `label` simples continua no desenho de sempre.
fn labelWantsFx(n: *const kdl.Node) bool {
    if (n.child("span") != null) return true;
    const keys = [_][]const u8{ "tracking", "shadow", "outline", "text-gradient", "text-en" };
    for (keys) |k| if (n.prop(k) != null) return true;
    return false;
}

/// `color_is_expr`: `color="alpha(@accent, 0.5)"`, que o caminho antigo não entende.
pub fn parseText(cx: *Cx, n: *const kdl.Node, color_is_expr: bool) Error!?*const TextFx {
    if (!labelWantsFx(n) and !color_is_expr) return null;
    var t: TextFx = .{ .spans = &.{} };
    t.font = n.str("font");
    t.weight = (try parseWeight(cx, n)) orelse .semibold;
    t.size = numOr(n, "size", 14);
    t.tracking = numOr(n, "tracking", 0);
    t.color = try cx.opt(n, "color", "color inválida");
    t.shadow = try cx.opt(n, "shadow", "shadow inválida");
    t.shadow_x = numOr(n, "shadow-x", 0);
    t.shadow_y = numOr(n, "shadow-y", if (n.num("shadow-blur") != null) 0 else 1);
    t.shadow_blur = numOr(n, "shadow-blur", 0);
    t.outline = try cx.opt(n, "outline", "outline inválido");
    t.outline_width = numOr(n, "outline-width", 1);
    if (n.str("text-gradient")) |s| t.gradient = try parseGradient(cx, n, s, "text-gradient-angle", 0);

    var count: usize = 0;
    for (n.children) |*ch| {
        if (std.mem.eql(u8, ch.name, "span")) count += 1;
    }
    if (count == 0) {
        const one = try cx.a.alloc(Span, 1);
        one[0] = .{ .text = n.str("text") orelse "", .text_en = n.str("text-en") orelse "" };
        t.spans = one;
    } else {
        const spans = try cx.a.alloc(Span, count);
        var i: usize = 0;
        for (n.children) |*ch| {
            if (!std.mem.eql(u8, ch.name, "span")) continue;
            const txt = if (ch.arg(0)) |v| v.asString() else ch.str("text");
            spans[i] = .{
                .text = txt orelse return cx.fail(ch, "span sem texto"),
                .text_en = ch.str("en") orelse ch.str("text-en") orelse "",
                .font = ch.str("font"),
                .weight = try parseWeight(cx, ch),
                .size = if (ch.num("size")) |v| @floatCast(v) else null,
                .color = try cx.opt(ch, "color", "cor inválida no span"),
                .tracking = if (ch.num("tracking")) |v| @floatCast(v) else null,
            };
            i += 1;
        }
        t.spans = spans;
    }
    const out = try cx.a.create(TextFx);
    out.* = t;
    return out;
}

/// Componentes que guardam cores (o resto das propriedades é lido ao desenhar).
const painted = std.StaticStringMap(void).initComptime(.{
    .{"shape"}, .{"rule"}, .{"starfield"}, .{"orbit"}, .{"aurora"}, .{"dunes"}, .{"topography"}, .{"radar"}, .{"window-controls"},
});
const color_keys = [_][]const u8{ "color", "color2", "color3", "fill", "dot", "ornament-color" };

/// Lê o que um nó do layout tem de novo. null = nada (o caso de quase todos).
pub fn parseNode(cx: *Cx, n: *const kdl.Node, bg_is_token: bool) Error!?*const NodeFx {
    var x: NodeFx = .{};
    var used = false;
    if (n.str("bg")) |s| if (!bg_is_token) {
        x.bg = try cx.expr(n, s, "bg inválido");
        used = true;
    };
    if (try parseBox(cx, n, false)) |b| {
        x.box = b;
        used = true;
    }
    if (std.mem.eql(u8, n.name, "label")) {
        const col_expr = if (n.str("color")) |s| cx.tokens(s) == null else false;
        if (try parseText(cx, n, col_expr)) |t| {
            x.text = t;
            used = true;
        }
    } else if (painted.has(n.name)) {
        var list: std.ArrayList(NamedColor) = .empty;
        for (color_keys) |k| if (try cx.opt(n, k, "cor inválida")) |e| try list.append(cx.a, .{ .key = k, .expr = e });
        x.colors = try list.toOwnedSlice(cx.a);
        used = used or x.colors.len > 0;
    }
    if (!used) return null;
    const out = try cx.a.create(NodeFx);
    out.* = x;
    return out;
}

// --- Testes ---------------------------------------------------------------

const testing = std.testing;

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    pal: [16]color.Rgba = @splat(color.Rgba.black),

    fn tokens(name: []const u8) ?u8 {
        if (std.mem.eql(u8, name, "bg")) return 0;
        if (std.mem.eql(u8, name, "accent")) return 1;
        if (std.mem.eql(u8, name, "text")) return 2;
        return null;
    }
    fn cx(e: *TestEnv) Cx {
        return .{ .a = e.arena.allocator(), .palette = &e.pal, .tokens = tokens };
    }
    fn node(e: *TestEnv, src: []const u8) !*const kdl.Node {
        const nodes = try kdl.parse(e.arena.allocator(), src, null);
        return &nodes[0];
    }
};

test "lista de cores respeita parênteses" {
    var out: [3][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), splitColors("mix(@bg, black, 0.2)  @accent #fff", &out));
    try testing.expectEqualStrings("mix(@bg, black, 0.2)", out[0]);
    try testing.expectEqualStrings("@accent", out[1]);
    try testing.expectEqualStrings("#fff", out[2]);
    try testing.expectEqual(@as(usize, 4), splitColors("a b c d", &out));
}

test "caixa: gradiente, padrão, grão, vinheta e estilos v2" {
    var e: TestEnv = .{ .arena = .init(testing.allocator) };
    defer e.arena.deinit();
    var cx = e.cx();
    const n = try e.node(
        \\style "x" gradient="@bg mix(@bg, @accent, 0.2) @bg" gradient-angle=135 \
        \\  pattern=dots pattern-color="alpha(@text, 0.1)" pattern-size=12 pattern-width=2 \
        \\  grain="alpha(@text, 0.05)" vignette="alpha(black, 0.3)" vignette-size=0.4 \
        \\  inner-shadow="alpha(black, 0.2)" inner-shadow-size=8 hover-bg="@accent" \
        \\  border-top="@accent" border-top-width=2 border-bottom=accent \
        \\  border-gradient="@accent transparent" border-gradient-angle=0 border-width=1.5
    );
    const b = (try parseBox(&cx, n, true)).?;
    try testing.expectEqual(@as(u8, 3), b.gradient.?.n);
    try testing.expectEqual(@as(f32, 135), b.gradient.?.angle);
    try testing.expectEqual(PatternKind.dots, b.pattern.?.kind);
    try testing.expectEqual(@as(f32, 12), b.pattern.?.size);
    try testing.expect(b.grain != null);
    try testing.expectEqual(@as(f32, 0.4), b.vignette_size);
    try testing.expectEqual(@as(f32, 8), b.inner_shadow_size);
    try testing.expect(b.hover_bg != null);
    try testing.expectEqual(@as(f32, 2), b.side_widths[0]);
    try testing.expect(b.sides[1] == null);
    try testing.expect(b.sides[2].?.* == .tok);
    try testing.expectEqual(@as(u8, 2), b.border_gradient.?.n);
    try testing.expectEqual(@as(f32, 1.5), b.border_width);
    try testing.expect(b.hasFill());
    try testing.expectEqual(Corners.all, b.corners);
    try testing.expectEqual(Corners.left, (try parseBox(&cx, try e.node("s grain=\"@bg\" corners=left"), false)).?.corners);
    const ds = (try parseBox(&cx, try e.node("s drop-shadow=\"alpha(black, 0.5)\" drop-shadow-size=40 drop-shadow-y=12"), false)).?;
    try testing.expectEqual(@as(f32, 40), ds.drop_shadow_size);
    try testing.expectEqual(@as(f32, 12), ds.drop_shadow_y);
    var cx_c = e.cx();
    try testing.expectError(error.Invalid, parseBox(&cx_c, try e.node("s grain=\"@bg\" corners=nada"), false));
    // Estilo simples não ganha caixa: fica no desenho de sempre.
    try testing.expect((try parseBox(&cx, try e.node("style \"y\" bg=\"@bg\" radius=4 border=\"@bg\""), true)) == null);
}

test "caixa: erros apontam o nó" {
    var e: TestEnv = .{ .arena = .init(testing.allocator) };
    defer e.arena.deinit();
    const casos = [_][]const u8{
        "s gradient=\"@bg\"",
        "s gradient=\"@bg @bg @bg @bg\"",
        "s gradient=\"@bg @nada\"",
        "s pattern=estrela pattern-color=\"@bg\"",
        "s pattern=dots",
        "s grain=\"nada\"",
        "s border-left=\"#zz\"",
    };
    for (casos) |src| {
        var cx = e.cx();
        try testing.expectError(error.Invalid, parseBox(&cx, try e.node(src), false));
        try testing.expect(cx.problem != null);
    }
}

test "label: tracking, runs e efeitos; o simples não muda de caminho" {
    var e: TestEnv = .{ .arena = .init(testing.allocator) };
    defer e.arena.deinit();
    var cx = e.cx();
    try testing.expect((try parseNode(&cx, try e.node("label text=\"x\" size=12 color=accent weight=bold"), false)) == null);

    const simple = (try parseNode(&cx, try e.node("label text=\"ORBITAL\" text-en=\"ORBITAL\" tracking=4 size=11 color=\"alpha(@text, 0.8)\""), false)).?;
    try testing.expectEqual(@as(f32, 4), simple.text.?.tracking);
    try testing.expectEqual(@as(usize, 1), simple.text.?.spans.len);
    try testing.expectEqualStrings("ORBITAL", simple.text.?.spans[0].text);

    const n = try e.node(
        \\label size=9 color=text shadow="alpha(black, 0.5)" shadow-blur=3 outline="@bg" outline-width=2 text-gradient="@accent @text" {
        \\    span "01" size=18 weight=bold color=accent font=mono
        \\    span "CANAIS" en="CHANNELS" tracking=3
        \\}
    );
    const t = (try parseNode(&cx, n, false)).?.text.?;
    try testing.expectEqual(@as(usize, 2), t.spans.len);
    try testing.expectEqual(@as(f32, 18), t.spans[0].size.?);
    try testing.expectEqual(Weight.bold, t.spans[0].weight.?);
    try testing.expectEqualStrings("mono", t.spans[0].font.?);
    try testing.expectEqualStrings("CHANNELS", t.spans[1].text_en);
    try testing.expectEqual(@as(f32, 3), t.spans[1].tracking.?);
    try testing.expect(t.spans[1].size == null);
    try testing.expectEqual(@as(f32, 3), t.shadow_blur);
    try testing.expectEqual(@as(f32, 0), t.shadow_y);
    try testing.expectEqual(@as(f32, 2), t.outline_width);
    try testing.expect(t.gradient != null);

    var cx2 = e.cx();
    try testing.expectError(error.Invalid, parseNode(&cx2, try e.node("label { span size=3 }"), false));
    var cx3 = e.cx();
    try testing.expectError(error.Invalid, parseNode(&cx3, try e.node("label tracking=1 weight=gorda"), false));
}

test "nó: bg com expressão e cores dos componentes novos" {
    var e: TestEnv = .{ .arena = .init(testing.allocator) };
    defer e.arena.deinit();
    var cx = e.cx();
    try testing.expect((try parseNode(&cx, try e.node("row bg=accent"), true)) == null);
    const r = (try parseNode(&cx, try e.node("row height=1 bg=\"alpha(@accent, 0.4)\""), false)).?;
    try testing.expect(r.bg != null);
    const s = (try parseNode(&cx, try e.node("shape kind=arc color=accent dot=\"@text\""), false)).?;
    try testing.expect(s.color("color").?.* == .tok);
    try testing.expect(s.color("dot") != null);
    try testing.expect(s.color("fill") == null);
    var cx2 = e.cx();
    try testing.expectError(error.Invalid, parseNode(&cx2, try e.node("rule color=\"nada\""), false));
}
