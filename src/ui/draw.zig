//! Contexto de desenho passado a todos os componentes, mais as primitivas
//! (retângulos, texto, sombras, áreas clicáveis, propriedades do nó).
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const theme_mod = @import("../theme/theme.zig");
const layout = @import("../theme/layout.zig");
const fonts_mod = @import("fonts.zig");
const anim = @import("anim.zig");
const fx = @import("fx.zig");
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
    /// Alguém desenhou o número desde o último tique (ler o /proc custa).
    ram_seen: bool = false,
    /// A parte da RAM que não é do app, e o que o malloc tem (0 = não se sabe aqui).
    file_kb: u32 = 0,
    heap_used_kb: u32 = 0,
    heap_free_kb: u32 = 0,
    frame_us: u32 = 0,
    frames_built: u64 = 0,
    frames_skipped: u64 = 0,
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
    stats: *Stats,
    images: *@import("images.zig").Cache,
    win: Rect,
    /// Algum elemento clicável está sob o mouse neste quadro.
    hot: bool = false,

    pub fn act(ctx: *Ctx, a: Action) void {
        ctx.actions.append(ctx.st.gpa, a) catch {};
    }

    pub fn col(ctx: *const Ctx, t: Token) Rgba {
        return ctx.th.c(t);
    }

    /// Família pedida pelo nó (`font="mono"`) ou a da interface.
    /// Família pedida pelo nó: `font=mono`, `font=ui` ou o nome de qualquer
    /// fonte instalada (`font="Liberation Serif"`), carregada ao aplicar o tema.
    pub fn familyFor(ctx: *const Ctx, n: *const kdl.Node) *Family {
        const f = n.str("font") orelse return ctx.ui;
        if (std.mem.eql(u8, f, "mono")) return ctx.mono;
        if (std.mem.eql(u8, f, "ui")) return ctx.ui;
        return ctx.fonts.find(f) orelse ctx.ui;
    }

    /// Abre um popup (menu de contexto, perfil, emoji) na posição do mouse.
    pub fn popup(ctx: *Ctx, p: @import("state.zig").Popup) void {
        ctx.st.popup = p;
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
    return if (n.num(key)) |x| @floatCast(std.math.clamp(x, -20_000, 20_000)) else default;
}

/// Tema do quadro atual, para resolver `$opção` nas propriedades.
pub var opt_theme: ?*const theme_mod.Theme = null;

/// Booleano do nó; aceita `"$opção"` (uma opção do tema nas Configurações).
pub fn pflag(n: *const kdl.Node, key: []const u8, default: bool) bool {
    const val = n.prop(key) orelse return default;
    if (val.asString()) |s| if (s.len > 1 and s[0] == '$') {
        // "$!opção" = o contrário da opção.
        const neg = s[1] == '!';
        const t = opt_theme orelse return default;
        const on = t.option(s[if (neg) 2 else 1..]) orelse return default;
        return if (neg) !on else on;
    };
    return val.asBool() orelse default;
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
    if (st.box) |b| fx.dropShadow(ctx, dl, b, r, st.radius);
    if (st.shadow > 0) shadow(dl, r, st.radius, st.shadow, ctx.col(.shadow));
    if (st.bg) |bg| rect(dl, r, bg, st.radius);
    if (st.box) |b| fx.fill(ctx, dl, b, r, st.radius, key);
    if (st.sheen) {
        // Reflexo de vidro: luz no topo que some até o meio do cartão.
        const top: Rect = .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = @min(r.h * 0.45, 140) };
        c.ImDrawList_AddRectFilledMultiColor(dl, v(top.x, top.y + st.radius * 0.5), v(top.right(), top.bottom()), Rgba.white.col(0.07), Rgba.white.col(0.07), 0, 0);
        rectFlags(dl, .{ .x = top.x, .y = top.y, .w = top.w, .h = st.radius * 0.5 + 1 }, Rgba.white.alpha(0.07), st.radius, c.ImDrawFlags_RoundTop);
        line(dl, r.x + st.radius, r.y + 1, r.right() - st.radius, r.y + 1, Rgba.white.alpha(0.22), 1);
    }
    const hov = if (st.glow != null) anim.to(anim.id("style-glow", key), if (ctx.hovering(r)) 1 else 0, 14) else 0;
    if (st.border) |b| {
        const bcol = if (st.glow) |g| b.mix(g, hov) else b;
        border(dl, r, bcol, st.radius, st.border_width);
    } else if (st.glow) |g| if (hov > 0.01) border(dl, r, g.alpha(hov), st.radius, st.border_width);
    if (st.box) |b| fx.edges(ctx, dl, b, r, st.radius);
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

/// Quantos bytes de `s` cabem em `max_w`, sem partir um caractere (busca
/// binária: cortar um texto longo mede umas 8 vezes, não uma por caractere).
pub fn fitBytes(font: *c.ImFont, size: f32, s: []const u8, max_w: f32) usize {
    var lo: usize = 0;
    var hi: usize = s.len;
    // Palavra enorme ("kkkk…" de 4000 bytes): sobe dobrando até passar, para
    // o custo ser o do pedaço que cabe e não o do resto todo, a cada linha.
    var probe: usize = 128;
    while (probe < hi) : (probe *= 2) {
        var at = probe;
        while (at > lo and (s[at] & 0xC0) == 0x80) at -= 1;
        if (at == lo) continue;
        if (width(font, size, s[0..at]) > max_w) {
            hi = at - 1;
            break;
        }
        lo = at;
    }
    while (lo < hi) {
        var mid = lo + (hi - lo + 1) / 2;
        while (mid > lo and mid < s.len and (s[mid] & 0xC0) == 0x80) mid -= 1;
        if (mid == lo) {
            // Só resta um caractere entre lo e hi: vê se ele cabe.
            mid = lo + 1;
            while (mid < s.len and (s[mid] & 0xC0) == 0x80) mid += 1;
            if (mid > hi or width(font, size, s[0..mid]) > max_w) break;
            lo = mid;
            continue;
        }
        if (width(font, size, s[0..mid]) <= max_w) lo = mid else hi = mid - 1;
    }
    return lo;
}

/// O começo de `s` com no máximo `n` bytes, sem partir um caractere no meio.
pub fn utf8Prefix(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var k = n;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return s[0..k];
}

/// `bufPrint` que, sem espaço, corta o texto (nunca no meio de um caractere)
/// em vez de não mostrar nada.
pub fn printClip(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    wr.print(fmt, args) catch {};
    const out = wr.buffered();
    if (out.len < buf.len) return out;
    // Encheu: tira o último caractere se ele ficou pela metade.
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
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
    const end = fitBytes(font, size, s, avail);
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
    const n = utf8Prefix(s, buf.len).len;
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

/// Dica que aparece ao passar o mouse num botão de ícone.
pub fn tip(ctx: *Ctx, r: Rect, label: []const u8, hovered: bool) void {
    const key = @as(usize, @intFromFloat(@abs(r.x) * 7 + @abs(r.y) * 13));
    const k = anim.to(anim.id("tip-btn", key), if (hovered) 1 else 0, 18);
    if (k < 0.05) return;
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 13;
    const tw = width(font, fs, label);
    var tr: Rect = .{ .x = r.x + r.w / 2 - tw / 2 - 10, .y = r.y - 34 + (1 - k) * 4, .w = tw + 20, .h = 26 };
    if (tr.y < ctx.win.y + 4) tr.y = r.bottom() + 8;
    tr.x = std.math.clamp(tr.x, ctx.win.x + 4, ctx.win.right() - tr.w - 4);
    shadow(ctx.fg, tr, 6, 6, ctx.col(.shadow).alpha(k));
    rect(ctx.fg, tr, ctx.col(.overlay).alpha(k), 6);
    border(ctx.fg, tr, ctx.col(.border).alpha(k), 6, 1);
    text(ctx.fg, font, fs, tr.x + 10, centerY(tr, fs), ctx.col(.text).alpha(k), label);
}

// --- Interação --------------------------------------------------------------

pub const Hit = struct { hovered: bool, clicked: bool, held: bool, middle: bool, right: bool, ctrl: bool };

/// Área clicável invisível. `id` precisa ser único dentro do componente.
pub fn hit(ctx: *Ctx, id: usize, r: Rect) Hit {
    return hitEx(ctx, id, r, false);
}

/// Como `hit`, para algo que fica *embaixo* de outro elemento clicável (a
/// linha de citação, sob a barra de ações): o de cima ganha o clique.
/// (Não usamos isso em todo botão porque quebra o Ctrl+clique do ImGui.)
pub fn hitUnder(ctx: *Ctx, id: usize, r: Rect) Hit {
    return hitEx(ctx, id, r, true);
}

fn hitEx(ctx: *Ctx, id: usize, r: Rect, under: bool) Hit {
    c.ImGui_SetCursorScreenPos(v(r.x, r.y));
    c.ImGui_PushIDInt(@truncate(@as(i64, @bitCast(id))));
    if (under) c.ImGui_SetNextItemAllowOverlap();
    const clicked = c.ImGui_InvisibleButton("##h", v(@max(r.w, 1), @max(r.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonMiddle | c.ImGuiButtonFlags_MouseButtonRight);
    const hovered = c.ImGui_IsItemHovered(0);
    const held = c.ImGui_IsItemActive() and c.ImGui_IsMouseDown(0);
    const middle = c.ImGui_IsItemClickedEx(c.ImGuiMouseButton_Middle);
    const right = c.ImGui_IsItemClickedEx(c.ImGuiMouseButton_Right);
    // O botão do ImGui dispara ao soltar, com qualquer botão do mouse; o direito e o
    // do meio já tiveram a ação deles ao apertar.
    const other_up = c.ImGui_IsMouseReleased(c.ImGuiMouseButton_Right) or c.ImGui_IsMouseReleased(c.ImGuiMouseButton_Middle);
    c.ImGui_PopID();
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    if (hovered) ctx.hot = true;
    return .{ .hovered = hovered, .clicked = clicked and !middle and !right and !other_up, .held = held, .middle = middle, .right = right, .ctrl = ctx.io.*.KeyCtrl };
}

/// Clique direto pelo mouse, para o que fica por cima de uma região com
/// rolagem (a janela filha do ImGui pegaria o clique de um `hit`).
pub fn hitRaw(ctx: *Ctx, r: Rect) Hit {
    // Só se a janela onde se desenha (ou uma filha dela) é a que está sob o
    // mouse: nada de clicar através das configurações ou de um menu.
    const over = r.contains(ctx.mouse.x, ctx.mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
    if (over) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
        ctx.hot = true;
    }
    return .{ .hovered = over, .clicked = over and c.ImGui_IsMouseClicked(0), .held = over and c.ImGui_IsMouseDown(0), .middle = over and c.ImGui_IsMouseClicked(2), .right = over and c.ImGui_IsMouseClicked(1), .ctrl = ctx.io.*.KeyCtrl };
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

/// Anima o que já foi desenhado em `dl` desde o vértice `start`: escala a
/// partir de `origin`, desloca `dy` na vertical e multiplica a opacidade.
/// Barato (só mexe nos vértices do quadro) e vale para qualquer coisa
/// desenhada ali, inclusive os campos de texto do ImGui.
pub fn transformVerts(dl: *c.ImDrawList, start: c_int, origin: c.ImVec2, scale: f32, dy: f32, alpha: f32) void {
    const vb = &dl.*.VtxBuffer;
    if (start >= vb.Size) return;
    const a_mul = std.math.clamp(alpha, 0, 1);
    for (vb.Data[@intCast(start)..@intCast(vb.Size)]) |*p| {
        p.pos.x = origin.x + (p.pos.x - origin.x) * scale;
        p.pos.y = origin.y + (p.pos.y - origin.y) * scale + dy;
        const a: f32 = @floatFromInt((p.col >> 24) & 0xff);
        p.col = (p.col & 0x00ff_ffff) | (@as(u32, @intFromFloat(a * a_mul)) << 24);
    }
}

/// Curva de saída suave (rápido no começo, assenta no fim).
pub fn easeOut(t: f32) f32 {
    const u = 1 - std.math.clamp(t, 0, 1);
    return 1 - u * u * u;
}
