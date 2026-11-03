//! Contexto de desenho passado a todos os componentes, mais as primitivas
//! (retângulos, texto, sombras, áreas clicáveis, propriedades do nó).
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const theme_mod = @import("../theme/theme.zig");
const layout = @import("../theme/layout.zig");
const fonts_mod = @import("fonts.zig");
const anim = @import("anim.zig");
const Store = @import("../core/store.zig").Store;
const Action = @import("../core/event.zig").Action;
const State = @import("state.zig").State;

pub const Rgba = theme_mod.Rgba;
pub const Rect = layout.Rect;
pub const Token = theme_mod.Token;
pub const Weight = fonts_mod.Weight;
pub const Family = fonts_mod.Family;

pub const Stats = struct {
    ram_kb: u32 = 0,
    frame_us: u32 = 0,
    theme_count: usize = 0,
};

pub const Ctx = struct {
    th: *const theme_mod.Theme,
    theme_name: []const u8,
    theme_names: []const []const u8,
    theme_index: usize,
    store: *Store,
    st: *State,
    fonts: *fonts_mod.Fonts,
    ui: *Family,
    mono: *Family,
    dl: *c.ImDrawList,
    fg: *c.ImDrawList,
    io: *c.ImGuiIO,
    mouse: c.ImVec2,
    now_ms: i64,
    actions: *std.ArrayList(Action),
    stats: *const Stats,
    win: Rect,

    pub fn act(ctx: *Ctx, a: Action) void {
        ctx.actions.append(ctx.st.gpa, a) catch {};
    }

    pub fn col(ctx: *const Ctx, t: Token) Rgba {
        return ctx.th.c(t);
    }

    /// Família pedida pelo nó (`font="mono"`) ou a da interface.
    pub fn familyFor(ctx: *const Ctx, n: *const kdl.Node) *Family {
        if (n.str("font")) |f| if (std.mem.eql(u8, f, "mono")) return ctx.mono;
        return ctx.ui;
    }

    pub fn hovering(ctx: *const Ctx, r: Rect) bool {
        return r.contains(ctx.mouse.x, ctx.mouse.y);
    }
};

// --- Propriedades dos nós -------------------------------------------------

pub fn pstr(n: *const kdl.Node, key: []const u8, default: []const u8) []const u8 {
    return n.str(key) orelse default;
}

pub fn pnum(n: *const kdl.Node, key: []const u8, default: f32) f32 {
    return if (n.num(key)) |x| @floatCast(x) else default;
}

pub fn pflag(n: *const kdl.Node, key: []const u8, default: bool) bool {
    return n.flag(key) orelse default;
}

pub fn is(n: *const kdl.Node, key: []const u8, value: []const u8, default: []const u8) bool {
    return std.mem.eql(u8, pstr(n, key, default), value);
}

// --- Primitivas -----------------------------------------------------------

pub fn v(x: f32, y: f32) c.ImVec2 {
    return .{ .x = x, .y = y };
}

pub fn rect(dl: *c.ImDrawList, r: Rect, color: Rgba, rounding: f32) void {
    if (color.a <= 0.001) return;
    c.ImDrawList_AddRectFilledEx(dl, v(r.x, r.y), v(r.x + r.w, r.y + r.h), color.u(), rounding, 0);
}

pub fn rectFlags(dl: *c.ImDrawList, r: Rect, color: Rgba, rounding: f32, flags: c_int) void {
    if (color.a <= 0.001) return;
    c.ImDrawList_AddRectFilledEx(dl, v(r.x, r.y), v(r.x + r.w, r.y + r.h), color.u(), rounding, flags);
}

pub fn border(dl: *c.ImDrawList, r: Rect, color: Rgba, rounding: f32, thickness: f32) void {
    if (color.a <= 0.001) return;
    const h = thickness / 2;
    c.ImDrawList_AddRectEx(dl, v(r.x + h, r.y + h), v(r.x + r.w - h, r.y + r.h - h), color.u(), rounding, thickness, 0);
}

pub fn line(dl: *c.ImDrawList, x1: f32, y1: f32, x2: f32, y2: f32, color: Rgba, thickness: f32) void {
    c.ImDrawList_AddLineEx(dl, v(x1, y1), v(x2, y2), color.u(), thickness, 0);
}

pub fn circle(dl: *c.ImDrawList, cx: f32, cy: f32, r: f32, color: Rgba) void {
    c.ImDrawList_AddCircleFilled(dl, v(cx, cy), r, color.u(), 0);
}

/// Sombra suave aproximada por camadas de retângulos arredondados.
pub fn shadow(dl: *c.ImDrawList, r: Rect, rounding: f32, size: f32, color: Rgba) void {
    if (size <= 0) return;
    const steps: usize = 6;
    for (0..steps) |i| {
        const k = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));
        const grow = size * k;
        const a = color.a * (1 - k) * (1 - k) * 0.5;
        const sr: Rect = .{ .x = r.x - grow, .y = r.y - grow + size * 0.35, .w = r.w + grow * 2, .h = r.h + grow * 2 };
        rect(dl, sr, color.alpha(a / @max(color.a, 0.001)), rounding + grow);
    }
}

/// Desenha um estilo nomeado do tema (fundo, sombra, borda, brilho no hover).
pub fn drawStyle(ctx: *Ctx, dl: *c.ImDrawList, st: theme_mod.Style, r: Rect, key: usize) void {
    if (st.shadow > 0) shadow(dl, r, st.radius, st.shadow, ctx.col(.shadow));
    if (st.bg) |bg| rect(dl, r, bg, st.radius);
    const hov = if (st.glow != null) anim.to(anim.id("style-glow", key), if (ctx.hovering(r)) 1 else 0, 14) else 0;
    if (st.border) |b| {
        const bcol = if (st.glow) |g| b.mix(g, hov) else b;
        border(dl, r, bcol, st.radius, st.border_width);
    } else if (st.glow) |g| if (hov > 0.01) border(dl, r, g.alpha(hov), st.radius, st.border_width);
}

// --- Texto ----------------------------------------------------------------

/// Escala global do texto (configuração "Tamanho do texto").
pub var text_scale: f32 = 1.0;

pub fn width(font: *c.ImFont, size: f32, s: []const u8) f32 {
    if (s.len == 0) return 0;
    const b: [*]const u8 = s.ptr;
    return c.ImFont_CalcTextSizeAEx(font, size * text_scale, std.math.floatMax(f32), 0, b, b + s.len, null).x;
}

pub fn text(dl: *c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, color: Rgba, s: []const u8) void {
    if (s.len == 0 or color.a <= 0.001) return;
    const b: [*]const u8 = s.ptr;
    const sz = size * text_scale;
    // Mantém o texto centrado na linha quando a escala muda.
    const dy = (size - sz) * 0.6;
    c.ImDrawList_AddTextImFontPtrEx(dl, font, sz, v(@round(x), @round(y + dy)), color.u(), b, b + s.len, 0, null);
}

/// Texto que corta com "…" se passar de `max_w`. Retorna a largura usada.
pub fn textClipped(dl: *c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, color: Rgba, s: []const u8, max_w: f32) f32 {
    const full = width(font, size, s);
    if (full <= max_w) {
        text(dl, font, size, x, y, color, s);
        return full;
    }
    const ell = "…";
    const avail = max_w - width(font, size, ell);
    var end: usize = s.len;
    while (end > 0) {
        end -= 1;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
        if (width(font, size, s[0..end]) <= avail) break;
    }
    text(dl, font, size, x, y, color, s[0..end]);
    const w0 = width(font, size, s[0..end]);
    text(dl, font, size, x + w0, y, color, ell);
    return w0 + width(font, size, ell);
}

/// Y para centralizar verticalmente uma linha de texto de tamanho `size`.
pub fn centerY(r: Rect, size: f32) f32 {
    return r.y + (r.h - size * 1.2) / 2;
}

/// Copia `s` em maiúsculas (ASCII + acentos latinos comuns).
pub fn upper(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = s[i];
        if (ch >= 'a' and ch <= 'z') {
            buf[i] = ch - 32;
        } else if (ch == 0xC3 and i + 1 < n and s[i + 1] >= 0xA0 and s[i + 1] <= 0xBE and s[i + 1] != 0xB7) {
            buf[i] = ch;
            buf[i + 1] = s[i + 1] - 0x20;
            i += 1;
        } else buf[i] = ch;
    }
    return buf[0..n];
}

pub fn firstGlyph(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return s[0..@min(len, s.len)];
}

// --- Interação --------------------------------------------------------------

pub const Hit = struct { hovered: bool, clicked: bool, held: bool, middle: bool, ctrl: bool };

/// Área clicável invisível. `id` precisa ser único dentro do componente.
pub fn hit(ctx: *Ctx, id: usize, r: Rect) Hit {
    c.ImGui_SetCursorScreenPos(v(r.x, r.y));
    c.ImGui_PushIDInt(@truncate(@as(i64, @bitCast(id))));
    const clicked = c.ImGui_InvisibleButton("##h", v(@max(r.w, 1), @max(r.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonMiddle);
    const hovered = c.ImGui_IsItemHovered(0);
    const held = c.ImGui_IsItemActive();
    const middle = c.ImGui_IsItemClickedEx(c.ImGuiMouseButton_Middle);
    c.ImGui_PopID();
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .hovered = hovered, .clicked = clicked and !middle, .held = held, .middle = middle, .ctrl = ctx.io.*.KeyCtrl };
}

/// Região com rolagem própria (lista de canais, membros, mensagens).
pub fn beginRegion(ctx: *Ctx, id: [*:0]const u8, r: Rect, flags: c_int) *c.ImDrawList {
    _ = ctx;
    c.ImGui_SetCursorScreenPos(v(r.x, r.y));
    _ = c.ImGui_BeginChild(id, v(@max(r.w, 1), @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground | flags);
    return c.ImGui_GetWindowDrawList();
}

pub fn endRegion(ctx: *Ctx, content_bottom: f32, x: f32) void {
    _ = ctx;
    c.ImGui_SetCursorScreenPos(v(x, content_bottom));
    c.ImGui_Dummy(v(1, 1));
    c.ImGui_EndChild();
}
