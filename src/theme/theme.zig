//! Um tema carregado de um arquivo KDL: paleta, tokens de cor, fontes,
//! estilos nomeados e a árvore de layout. Ver `themes/README.md`.
const std = @import("std");
const kdl = @import("kdl.zig");
const color = @import("color.zig");
pub const Rgba = color.Rgba;

pub const Token = enum {
    bg,
    rail,
    sidebar,
    surface,
    elevated,
    overlay,
    text,
    muted,
    faint,
    accent,
    accent_text,
    border,
    hover,
    selected,
    online,
    idle,
    dnd,
    danger,
    mention,
    link,
    code_bg,
    bubble_self,
    bubble_self_text,
    bubble_other,
    shadow,
};

pub const Style = struct {
    bg: ?Rgba = null,
    radius: f32 = 0,
    border: ?Rgba = null,
    border_width: f32 = 1,
    /// Tamanho da sombra (0 = sem sombra).
    shadow: f32 = 0,
    /// Cor da borda quando o mouse está em cima (efeito de "foco").
    glow: ?Rgba = null,
};

/// Cor sobrescrita num pedaço do layout (`c-text="#fff"` num nó).
pub const Override = struct { tok: Token, color: Rgba };

pub const Theme = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "sem nome",
    description: []const u8 = "",
    author: []const u8 = "",
    /// Tipo de miniatura nas configurações (classic, glass, terminal, bubbles, zen).
    preview: []const u8 = "classic",
    colors: std.EnumArray(Token, Rgba),
    roles: [8]Rgba,
    font_ui: [:0]const u8 = "Inter",
    font_mono: [:0]const u8 = "JetBrains Mono",
    font_size: f32 = 16,
    radius: f32 = 6,
    /// Fundo da janela tem transparência (o compositor pode aplicar blur).
    transparent: bool = false,
    styles: std.StringHashMapUnmanaged(Style) = .empty,
    layout: ?*const kdl.Node = null,
    /// Sobrescritas efetivas de cada nó (já incluindo as dos pais).
    node_colors: std.AutoHashMapUnmanaged(*const kdl.Node, []const Override) = .empty,

    pub fn deinit(t: *Theme) void {
        t.arena.deinit();
    }

    pub fn c(t: *const Theme, tok: Token) Rgba {
        return t.colors.get(tok);
    }

    pub fn style(t: *const Theme, name: ?[]const u8) ?Style {
        const n = name orelse return null;
        return t.styles.get(n);
    }

    pub fn role(t: *const Theme, i: u8) Rgba {
        return t.roles[i % t.roles.len];
    }
};

pub const fallback_palette = [16]u32{
    0x15161b, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xd7dae0,
    0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xf0f2f5,
};

pub const LoadError = error{ SyntaxError, OutOfMemory, InvalidTheme };

pub const Diagnostic = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8 = "",
};

/// Carrega um tema. `wal` é a paleta do pywal (se houver); o tema decide se
/// usa (`palette "wal"`) ou define a própria.
pub fn load(gpa: std.mem.Allocator, src: []const u8, wal: ?*const [16]Rgba, diag: ?*Diagnostic) LoadError!Theme {
    var t: Theme = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .colors = undefined,
        .roles = undefined,
    };
    errdefer t.arena.deinit();
    const a = t.arena.allocator();

    // Os nós do KDL apontam para o texto: guarda uma cópia junto do tema.
    const owned_src = try a.dupe(u8, src);
    var kd: kdl.Diagnostic = .{};
    const nodes = kdl.parse(a, owned_src, &kd) catch |err| {
        if (diag) |d| d.* = .{ .line = kd.line, .column = kd.column, .message = kd.message };
        return err;
    };

    // Paleta: do pywal, do próprio tema ou a padrão.
    var pal: [16]Rgba = undefined;
    for (fallback_palette, 0..) |v, i| pal[i] = Rgba.hex(v);
    for (nodes) |*n| {
        if (!std.mem.eql(u8, n.name, "palette")) continue;
        if (n.arg(0)) |v| if (v.asString()) |s| if (std.mem.eql(u8, s, "wal")) {
            if (wal) |w| pal = w.*;
            continue;
        };
        for (n.args, 0..) |v, i| {
            if (i >= 16) break;
            const s = v.asString() orelse continue;
            pal[i] = color.parseHex(std.mem.trimStart(u8, s, "#")) catch return fail(diag, n, "cor inválida na paleta");
        }
    }

    t.colors = defaults(&pal);
    t.roles = .{ pal[4], pal[1], pal[3], pal[5], pal[6], pal[12], pal[9], pal[13] };

    const Look = struct {
        fn f(ctx: *const anyopaque, name: []const u8) ?Rgba {
            const th: *const Theme = @ptrCast(@alignCast(ctx));
            const tok = tokenFromName(name) orelse return null;
            return th.colors.get(tok);
        }
    };
    const resolver: color.Resolver = .{ .palette = &pal, .ctx = &t, .lookup = Look.f };

    for (nodes) |*n| {
        if (std.mem.eql(u8, n.name, "theme")) {
            if (n.arg(0)) |v| if (v.asString()) |s| {
                t.name = s;
            };
            t.description = n.str("description") orelse t.description;
            t.author = n.str("author") orelse t.author;
            t.preview = n.str("preview") orelse t.preview;
        } else if (std.mem.eql(u8, n.name, "colors")) {
            for (n.children) |*ch| {
                const tok = tokenFromName(ch.name) orelse return fail(diag, ch, "token de cor desconhecido");
                const expr = (ch.arg(0) orelse return fail(diag, ch, "faltou a cor")).asString() orelse return fail(diag, ch, "a cor deve ser uma string");
                t.colors.set(tok, color.eval(expr, resolver) catch return fail(diag, ch, "expressão de cor inválida"));
            }
        } else if (std.mem.eql(u8, n.name, "roles")) {
            for (n.args, 0..) |v, i| {
                if (i >= t.roles.len) break;
                const s = v.asString() orelse continue;
                t.roles[i] = color.eval(s, resolver) catch return fail(diag, n, "cor de cargo inválida");
            }
        } else if (std.mem.eql(u8, n.name, "fonts")) {
            if (n.str("ui")) |s| t.font_ui = try a.dupeSentinel(u8, s, 0);
            if (n.str("mono")) |s| t.font_mono = try a.dupeSentinel(u8, s, 0);
            if (n.num("size")) |v| t.font_size = @floatCast(v);
        } else if (std.mem.eql(u8, n.name, "metrics")) {
            if (n.num("radius")) |v| t.radius = @floatCast(v);
        } else if (std.mem.eql(u8, n.name, "window")) {
            if (n.flag("transparent")) |v| t.transparent = v;
        } else if (std.mem.eql(u8, n.name, "styles")) {
            for (n.children) |*ch| {
                const sname = (ch.arg(0) orelse return fail(diag, ch, "estilo sem nome")).asString() orelse return fail(diag, ch, "nome do estilo deve ser string");
                var st: Style = .{};
                if (ch.str("bg")) |e| st.bg = color.eval(e, resolver) catch return fail(diag, ch, "bg inválido");
                if (ch.str("border")) |e| st.border = color.eval(e, resolver) catch return fail(diag, ch, "border inválido");
                if (ch.str("glow")) |e| st.glow = color.eval(e, resolver) catch return fail(diag, ch, "glow inválido");
                if (ch.num("radius")) |v| st.radius = @floatCast(v);
                if (ch.num("border-width")) |v| st.border_width = @floatCast(v);
                if (ch.num("shadow")) |v| st.shadow = @floatCast(v);
                try t.styles.put(a, sname, st);
            }
        } else if (std.mem.eql(u8, n.name, "layout")) {
            t.layout = n;
        }
    }
    if (t.layout == null) return fail(diag, null, "o tema precisa de um nó `layout`");
    try collectOverrides(&t, a, t.layout.?, &.{}, resolver, diag);
    t.transparent = t.transparent or t.colors.get(.bg).a < 0.999;
    return t;
}

/// Percorre o layout juntando `c-<token>=cor`, que valem para o nó e seus filhos.
fn collectOverrides(t: *Theme, a: std.mem.Allocator, n: *const kdl.Node, inherited: []const Override, r: color.Resolver, diag: ?*Diagnostic) LoadError!void {
    var list: std.ArrayList(Override) = .empty;
    try list.appendSlice(a, inherited);
    for (n.props) |p| {
        if (!std.mem.startsWith(u8, p.key, "c-")) continue;
        const tok = tokenFromName(p.key[2..]) orelse return fail(diag, n, "token de cor desconhecido em c-…");
        const expr = p.value.asString() orelse return fail(diag, n, "a cor deve ser uma string");
        const col = color.eval(expr, r) catch return fail(diag, n, "expressão de cor inválida");
        try list.append(a, .{ .tok = tok, .color = col });
    }
    const effective = try list.toOwnedSlice(a);
    if (effective.len > 0) try t.node_colors.put(a, n, effective);
    for (n.children) |*ch| try collectOverrides(t, a, ch, effective, r, diag);
}

fn fail(diag: ?*Diagnostic, n: ?*const kdl.Node, msg: []const u8) LoadError {
    if (diag) |d| d.* = .{ .line = if (n) |x| x.line else 0, .message = msg };
    return error.InvalidTheme;
}

pub fn tokenFromName(name: []const u8) ?Token {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    return std.meta.stringToEnum(Token, buf[0..name.len]);
}

/// Tokens derivados da paleta; o tema sobrescreve o que quiser.
fn defaults(pal: *const [16]Rgba) std.EnumArray(Token, Rgba) {
    const bg = pal[0];
    const fg = pal[15];
    const black = Rgba.black;
    var e = std.EnumArray(Token, Rgba).initUndefined();
    e.set(.bg, bg.mix(fg, 0.035));
    e.set(.rail, bg.mix(black, 0.38));
    e.set(.sidebar, bg.mix(black, 0.18));
    e.set(.surface, bg.mix(fg, 0.035));
    e.set(.elevated, bg.mix(fg, 0.085));
    e.set(.overlay, bg.mix(black, 0.55));
    e.set(.text, fg);
    e.set(.muted, fg.mix(bg, 0.42));
    e.set(.faint, fg.mix(bg, 0.62));
    e.set(.accent, pal[4]);
    e.set(.accent_text, if (pal[4].luma() > 0.6) black else Rgba.white);
    e.set(.border, fg.alpha(0.08));
    e.set(.hover, fg.alpha(0.05));
    e.set(.selected, fg.alpha(0.10));
    e.set(.online, Rgba.hex(0x45b36b));
    e.set(.idle, Rgba.hex(0xe5a83b));
    e.set(.dnd, Rgba.hex(0xe5484d));
    e.set(.danger, Rgba.hex(0xe5484d));
    e.set(.mention, pal[4]);
    e.set(.link, pal[4].mix(fg, 0.25));
    e.set(.code_bg, bg.mix(black, 0.45));
    e.set(.bubble_self, pal[4]);
    e.set(.bubble_self_text, if (pal[4].luma() > 0.6) black else Rgba.white);
    e.set(.bubble_other, bg.mix(fg, 0.1));
    e.set(.shadow, black.alpha(0.35));
    return e;
}

test "carrega tema com tokens, estilos e layout" {
    const src =
        \\theme "teste" description="só um teste"
        \\palette "#000000" "#ff0000"
        \\colors {
        \\    accent "wal:1"
        \\    surface "mix(@accent, black, 0.5)"
        \\}
        \\fonts ui="JetBrains Mono" size=14
        \\styles { style "card" bg="@surface" radius=12 glow="@accent" }
        \\layout { row { messages } }
    ;
    var t = try load(std.testing.allocator, src, null, null);
    defer t.deinit();
    try std.testing.expectEqualStrings("teste", t.name);
    try std.testing.expectEqual(@as(f32, 1), t.c(.accent).r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.surface).r, 0.01);
    try std.testing.expectEqual(@as(f32, 12), t.style("card").?.radius);
    try std.testing.expectEqualStrings("JetBrains Mono", t.font_ui);
    try std.testing.expect(t.layout != null);
}

test "erro de tema aponta a linha" {
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidTheme, load(std.testing.allocator, "colors {\n  nao-existe \"#fff\"\n}\nlayout { messages }", null, &d));
    try std.testing.expectEqual(@as(u32, 2), d.line);
}

test "cores sobrescritas valem para os filhos" {
    var t = try load(std.testing.allocator,
        \\layout { column c-text="#ff0000" { messages; row c-muted="#00ff00" { composer } } }
    , null, null);
    defer t.deinit();
    const col = &t.layout.?.children[0];
    const msgs = &col.children[0];
    const comp = &col.children[1].children[0];
    try std.testing.expectEqual(@as(usize, 1), t.node_colors.get(msgs).?.len);
    try std.testing.expectEqual(@as(usize, 2), t.node_colors.get(comp).?.len);
}
