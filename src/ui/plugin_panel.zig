//! O painel lateral dos plugins: fica encaixado de um lado da janela (o layout do
//! tema encolhe para dar lugar), com largura ajustável, e desenha a árvore que o
//! plugin publicou (plugins/panel.zig). Só lê dados: nenhuma chamada a Lua aqui,
//! e parado não pede quadro nenhum. Clicar manda um evento para a thread dos
//! plugins, e a árvore nova chega quando ela chegar.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const inbox = @import("inbox.zig");
const anim = @import("anim.zig");
const dropdown = @import("dropdown.zig");
const icons = @import("icons.zig");
const engine = @import("../plugins/engine.zig");
const panel = engine.panel;

const Node = panel.Node;
const Tree = panel.Tree;

const min_w: f32 = 240;
const header_h: f32 = 44;
const pad: f32 = 14;
const grip: f32 = 5;
const input_cap = 512;
/// Janela apertada: o painel flutua em vez de empurrar a conversa para nada.
const min_layout_w: f32 = 600;

const Input = struct {
    id: u64 = 0,
    buf: [input_cap]u8 = @splat(0),
    /// O que foi avisado por último (`on_change` só sai quando muda).
    sent: [input_cap]u8 = @splat(0),
    /// A última árvore vista (o valor dela vale, menos enquanto se digita).
    tree: u32 = 0,
    active: bool = false,
    used: bool = false,
};

/// Poucos campos existem ao mesmo tempo: uma tabela pequena basta.
var inputs: [24]Input = @splat(.{});
var refocus: u64 = 0;
var dragging = false;
var overlay_now = false;

fn inputFor(id: u64) *Input {
    for (&inputs) |*i| if (i.used and i.id == id) return i;
    for (&inputs) |*i| if (!i.used) {
        i.* = .{ .used = true, .id = id };
        return i;
    };
    // Cheio: o mais antigo cede o lugar.
    const i = &inputs[@intCast(id % inputs.len)];
    i.* = .{ .used = true, .id = id };
    return i;
}

fn hash2(a: []const u8, b: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(a);
    h.update(&.{0});
    h.update(b);
    return h.final();
}

fn current() ?*engine.Engine {
    return engine.current;
}

/// Para o QA: o que muda quando o painel muda.
pub fn qaState() u64 {
    const e = current() orelse return 0;
    return @as(u64, e.panel_gen) +% @as(u64, @intFromBool(e.panel_left)) *% 1000003 +% @as(u64, @intFromFloat(e.panel_w));
}

/// Abre ou fecha o painel do plugin (botão do cabeçalho, paleta, configurações).
pub fn toggle(p: *engine.Plugin) void {
    const e = p.engine;
    e.openPanel(if (e.panel_open == p) null else p);
}

/// O botão do cabeçalho: abre o último ou o primeiro com painel.
pub fn toggleAny() void {
    const e = current() orelse return;
    if (e.panel_open != null) return e.openPanel(null);
    // Quem tem novidade vem primeiro.
    if (e.n_badges > 0) for (e.list.items) |p| if (p.tree) |t| {
        if (t.badge.len > 0) return e.openPanel(p);
    };
    for (e.list.items) |p| if (p.tree != null) return e.openPanel(p);
}

pub fn available() bool {
    const e = current() orelse return false;
    return e.panelCount() > 0;
}

/// Janela estreita: o painel está por cima do tema, não ao lado.
pub fn floating() bool {
    return overlay_now;
}

fn width(e: *const engine.Engine, win: d.Rect) f32 {
    return std.math.clamp(e.panel_w, min_w, @max(min_w, win.w * 0.6));
}

/// O que sobra para o layout do tema. Sem painel aberto, a janela inteira.
pub fn reserve(win: d.Rect) d.Rect {
    const e = current() orelse return win;
    const showing = if (e.panel_open) |p| p.tree != null else false;
    if (!showing) {
        overlay_now = false;
        return win;
    }
    const pw = width(e, win);
    overlay_now = win.w - pw < min_layout_w;
    if (overlay_now) return win;
    var r = win;
    r.w -= pw;
    if (e.panel_left) r.x += pw;
    return r;
}

pub fn draw(ctx: *d.Ctx) void {
    const e = current() orelse return;
    const p = e.panel_open orelse return;
    const tree = p.tree orelse return;
    const win = ctx.win;
    const pw = width(e, win);
    const r: d.Rect = .{ .x = if (e.panel_left) win.x else win.right() - pw, .y = win.y, .w = pw, .h = win.h };
    qa.mark(r, "pp-panel", .{});
    if (overlay_now) d.shadow(ctx.dl, r, 0, 18, ctx.col(.shadow));

    // Uma janela filha, a última a abrir: fica por cima do que estiver embaixo
    // (no modo flutuante, a conversa) e recebe o mouse antes.
    const saved = ctx.dl;
    defer ctx.dl = saved;
    const dl = d.beginRegion(ctx, "##plugin-panel-frame", r, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_EndChild();
    ctx.dl = dl;
    const bg = ctx.col(.sidebar);
    const surf = d.Rgba{ .r = bg.r, .g = bg.g, .b = bg.b, .a = @max(bg.a, 0.98) };
    d.rect(dl, r, surf, 0);
    const edge_x = if (e.panel_left) r.right() - 1 else r.x;
    d.line(dl, edge_x, r.y, edge_x, r.bottom(), ctx.col(.border), 1);

    header(ctx, dl, e, p, tree, r);
    const top = tabs(ctx, dl, e, p, r);

    // A borda de arrastar fica fora da região com rolagem, que pegaria o mouse.
    const body: d.Rect = .{ .x = if (e.panel_left) r.x else r.x + grip, .y = top, .w = r.w - grip, .h = r.bottom() - top };
    layout(ctx, tree, body.w - 2 * pad - 10);
    const bdl = d.beginRegion(ctx, "##plugin-panel", body, 0);
    ctx.dl = bdl;
    const o = c.ImGui_GetCursorScreenPos();
    drawNodes(ctx, bdl, e, p, tree, tree.first, o.x + pad, o.y + 8, body);
    d.endRegion(ctx, o.y + 8 + tree.height + 16, body.x);
    ctx.dl = dl;

    resizer(ctx, dl, e, r);
}

fn iconButton(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, tip: []const u8) d.Hit {
    const hb = d.hit(ctx, id, r);
    if (hb.hovered) d.rect(dl, r, ctx.col(.hover), 6);
    d.tip(ctx, r, tip, hb.hovered);
    return hb;
}

fn header(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, tree: *Tree, r: d.Rect) void {
    const fam = ctx.ui;
    const bar: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = header_h };
    const title = if (tree.title.len > 0) tree.title else p.title();
    const close: d.Rect = .{ .x = r.right() - 36, .y = r.y + 8, .w = 28, .h = 28 };
    const side: d.Rect = .{ .x = r.right() - 68, .y = r.y + 8, .w = 28, .h = 28 };
    _ = d.textClipped(dl, fam.get(.bold), 15, bar.x + pad, d.centerY(bar, 15), ctx.col(.text), title, side.x - bar.x - pad - 6);

    const sh = iconButton(ctx, dl, 0x9A01, side, if (e.panel_left) i18n.tr("Encaixar à direita", "Dock on the right") else i18n.tr("Encaixar à esquerda", "Dock on the left"));
    qa.mark(side, "pp-side", .{});
    // Um retângulo com a faixa do lado para onde vai.
    const ink = (if (sh.hovered) ctx.col(.text) else ctx.col(.muted));
    const ib: d.Rect = .{ .x = side.x + 7, .y = side.y + 8, .w = 14, .h = 12 };
    d.border(dl, ib, ink, 2, 1.2);
    d.rect(dl, .{ .x = if (e.panel_left) ib.right() - 5 else ib.x, .y = ib.y, .w = 5, .h = ib.h }, ink, 1);
    if (sh.clicked) {
        e.panel_left = !e.panel_left;
        e.panel_gen +%= 1;
        @import("../plugins/host.zig").savePrefs();
    }

    const ch = iconButton(ctx, dl, 0x9A02, close, i18n.tr("Fechar painel", "Close panel"));
    qa.mark(close, "pp-close", .{});
    const cx = close.x + 14;
    const cy = close.y + 14;
    const xc = if (ch.hovered) ctx.col(.text) else ctx.col(.muted);
    d.line(dl, cx - 5, cy - 5, cx + 5, cy + 5, xc, 1.8);
    d.line(dl, cx + 5, cy - 5, cx - 5, cy + 5, xc, 1.8);
    if (ch.clicked) e.openPanel(null);
    d.line(dl, r.x, bar.bottom() - 0.5, r.right(), bar.bottom() - 0.5, ctx.col(.border), 1);
}

/// Com mais de um plugin com painel: uma etiqueta para cada, quebrando em linhas.
fn tabs(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, r: d.Rect) f32 {
    var y = r.y + header_h;
    if (e.panelCount() < 2) return y;
    const f = ctx.ui.get(.medium);
    const fs: f32 = 12.5;
    y += 8;
    var x = r.x + pad;
    for (e.list.items, 0..) |other, i| {
        if (other.tree == null) continue;
        const label = other.title();
        const badge = other.tree.?.badge;
        const bw: f32 = if (badge.len > 0) d.width(f, 11, badge) + 12 else 0;
        const tw = d.width(f, fs, label) + 18 + bw;
        if (x + tw > r.right() - pad and x > r.x + pad) {
            x = r.x + pad;
            y += 28;
        }
        const tr: d.Rect = .{ .x = x, .y = y, .w = @min(tw, r.w - 2 * pad), .h = 24 };
        const hb = d.hit(ctx, 0x9B00 + i, tr);
        qa.mark(tr, "pp-tab:{s}", .{other.name});
        const on = other == p;
        d.rect(dl, tr, if (on) ctx.col(.selected) else if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.5), 12);
        if (on) d.border(dl, tr, ctx.col(.accent).alpha(0.7), 12, 1);
        _ = d.textClipped(dl, f, fs, tr.x + 9, d.centerY(tr, fs), if (on) ctx.col(.text) else ctx.col(.muted), label, tr.w - 16 - bw);
        if (badge.len > 0) {
            const br: d.Rect = .{ .x = tr.right() - bw - 3, .y = tr.y + 4, .w = bw, .h = 16 };
            d.rect(dl, br, ctx.col(.danger), 8);
            d.text(dl, f, 11, br.x + 6, d.centerY(br, 11), d.Rgba.white, badge);
            qa.mark(br, "pp-badge:{s}", .{other.name});
        }
        if (hb.clicked) e.openPanel(other);
        x += tr.w + 6;
    }
    y += 32;
    d.line(dl, r.x, y - 0.5, r.right(), y - 0.5, ctx.col(.border), 1);
    return y;
}

fn resizer(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, r: d.Rect) void {
    const x = if (e.panel_left) r.right() - grip else r.x;
    const hr: d.Rect = .{ .x = x, .y = r.y, .w = grip, .h = r.h };
    const hb = d.hit(ctx, 0x9A03, hr);
    qa.mark(hr, "pp-resize", .{});
    if (hb.hovered or hb.held) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeEW);
        const lx = if (e.panel_left) r.right() - 2 else r.x + 1;
        d.line(dl, lx, r.y, lx, r.bottom(), ctx.col(.accent), 2);
    }
    if (hb.held) {
        dragging = true;
        const want = if (e.panel_left) ctx.mouse.x - ctx.win.x else ctx.win.right() - ctx.mouse.x;
        e.panel_w = std.math.clamp(want, min_w, @max(min_w, ctx.win.w * 0.6));
        e.panel_gen +%= 1;
    } else if (dragging) {
        dragging = false;
        @import("../plugins/host.zig").savePrefs();
    }
}

// --- Medidas (só quando a árvore ou a largura mudam) ---------------------------------

fn buttonSize(ctx: *d.Ctx, n: *const Node) [2]f32 {
    return .{ @max(d.width(ctx.ui.get(.semibold), 13, n.text) + 22, 40), 28 };
}

fn textFont(ctx: *d.Ctx, n: *const Node) *c.ImFont {
    return ctx.ui.get(if (n.kind == .heading) .bold else .regular);
}

fn textH(ctx: *d.Ctx, n: *const Node, w: f32) f32 {
    const size: f32 = if (n.kind == .heading) 12 else 13.5;
    return inbox.wrapText(null, textFont(ctx, n), size, 0, 0, w, n.text, 40, ctx.col(.text));
}

/// Mede o nó e anota onde ele fica (relativo ao topo do painel). Retorna a altura.
fn measure(ctx: *d.Ctx, t: *Tree, i: u32, x: f32, y: f32, w: f32) f32 {
    const n = &t.nodes.items[i];
    n.x = x;
    n.y = y;
    n.w = w;
    n.h = switch (n.kind) {
        .text => textH(ctx, n, w) + 6,
        .heading => textH(ctx, n, w) + 14,
        .separator => 15,
        .button => 28,
        .input => 34,
        .bar => 28,
        .select => select_label_h + select_box_h + 4,
        .toggle => toggleH(ctx, n, w),
        .option => 0,
        .row => measureRow(ctx, t, n.child, x, y, w),
        .list => measureList(ctx, t, n, x, y, w),
        .item => measureItem(ctx, t, n, x, y, w),
    };
    return n.h;
}

fn measureRow(ctx: *d.Ctx, t: *Tree, first: u32, x: f32, y: f32, w: f32) f32 {
    var cx = x;
    var cy = y;
    var line: f32 = 0;
    var at = first;
    while (at != panel.none) {
        const n = &t.nodes.items[at];
        const sz: [2]f32 = if (n.kind == .button) buttonSize(ctx, n) else .{ w, 0 };
        if (cx + sz[0] > x + w and cx > x) {
            cx = x;
            cy += line + 6;
            line = 0;
        }
        const h = measure(ctx, t, at, cx, cy, @min(sz[0], w));
        line = @max(line, h);
        cx += @min(sz[0], w) + 6;
        at = n.next;
    }
    return cy + line - y + 6;
}

fn measureList(ctx: *d.Ctx, t: *Tree, n: *Node, x: f32, y: f32, w: f32) f32 {
    var at = n.child;
    if (at == panel.none) {
        // Vazia: o texto de "nada aqui".
        return inbox.wrapText(null, ctx.ui.get(.regular), 13, 0, 0, w, n.text, 6, ctx.col(.faint)) + 8;
    }
    var cy = y;
    while (at != panel.none) {
        cy += measure(ctx, t, at, x, cy, w) + 4;
        at = t.nodes.items[at].next;
    }
    return cy - y + 4;
}

fn metaW(ctx: *d.Ctx, n: *const Node) f32 {
    return if (n.meta.len > 0) d.width(ctx.ui.get(.regular), 11.5, n.meta) + 8 else 0;
}

fn measureItem(ctx: *d.Ctx, t: *Tree, n: *Node, x: f32, y: f32, w: f32) f32 {
    const inner = w - 20;
    var h: f32 = 8 + 18;
    if (n.sub.len > 0) h += inbox.wrapText(null, ctx.ui.get(.regular), 12.5, 0, 0, inner, n.sub, 4, ctx.col(.muted)) + 2;
    if (n.child != panel.none) h += measureRow(ctx, t, n.child, x + 10, y + h + 2, inner) + 2;
    return h + 6;
}

const select_label_h: f32 = 19;
const select_box_h: f32 = 34;
const select_max_w: f32 = 340;
const select_row_h: f32 = 32;

fn toggleH(ctx: *d.Ctx, n: *const Node, w: f32) f32 {
    if (n.sub.len == 0) return 28;
    return 22 + inbox.wrapText(null, ctx.ui.get(.regular), 12.5, 0, 0, w - 52, n.sub, 4, ctx.col(.muted)) + 4;
}

fn layout(ctx: *d.Ctx, t: *Tree, w: f32) void {
    const key = @as(u32, ctx.st.theme_gen) ^ @as(u32, @intFromFloat(d.text_scale * 100)) << 8;
    if (t.layout_w == w and t.layout_key == key) return;
    t.layout_w = w;
    t.layout_key = key;
    var y: f32 = 0;
    var at = t.first;
    while (at != panel.none) {
        y += measure(ctx, t, at, 0, y, w) + 8;
        at = t.nodes.items[at].next;
    }
    t.height = y;
}

// --- Desenho ------------------------------------------------------------------------

/// As opções do cartão na página de plugins. Devolve a altura.
pub fn embedded(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *Tree, x: f32, y: f32, w: f32) f32 {
    layout(ctx, t, w);
    // São poucos nós: sem cortar o que está fora da tela, a rolagem da página nem conta.
    drawNodes(ctx, dl, e, p, t, t.first, x, y, .{ .x = 0, .y = -1e7, .w = 1e7, .h = 2e7 });
    return t.height;
}

fn drawNodes(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *Tree, first: u32, ox: f32, oy: f32, clip: d.Rect) void {
    var at = first;
    while (at != panel.none) {
        const n = &t.nodes.items[at];
        // Longe da tela não desenha (uma lista pode ter centenas de itens).
        const sy = oy + n.y;
        if (sy + n.h >= clip.y - 40 and sy <= clip.bottom() + 40) drawNode(ctx, dl, e, p, t, at, n, ox, oy, clip);
        at = n.next;
    }
}

fn styleColor(ctx: *d.Ctx, s: panel.Style) d.Rgba {
    return switch (s) {
        .normal => ctx.col(.text),
        .muted => ctx.col(.muted),
        .accent => ctx.col(.accent),
        .danger => ctx.col(.danger),
    };
}

fn drawNode(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *Tree, at: u32, n: *Node, ox: f32, oy: f32, clip: d.Rect) void {
    const r: d.Rect = .{ .x = ox + n.x, .y = oy + n.y, .w = n.w, .h = n.h };
    switch (n.kind) {
        .text => {
            _ = inbox.wrapText(dl, textFont(ctx, n), 13.5, r.x, r.y, r.w, n.text, 40, styleColor(ctx, n.style));
            if (n.key.len > 0) qa.mark(r, "pp-text:{s}", .{n.key});
        },
        .heading => {
            var buf: [96]u8 = undefined;
            _ = inbox.wrapText(dl, textFont(ctx, n), 12, r.x, r.y + 6, r.w, d.upper(&buf, n.text), 3, ctx.col(.muted));
        },
        .separator => d.line(dl, r.x, r.y + 7, r.right(), r.y + 7, ctx.col(.border), 1),
        .button => drawButton(ctx, dl, e, p, t, at, n, r),
        .input => drawInput(ctx, dl, e, p, t, n, r),
        .bar => drawBar(ctx, dl, n, r),
        .select => drawSelect(ctx, dl, e, p, t, at, n, r),
        .toggle => drawToggle(ctx, dl, e, p, t, at, n, r),
        .option => {},
        .row => drawNodes(ctx, dl, e, p, t, n.child, ox, oy, clip),
        .list => {
            if (n.child == panel.none) {
                _ = inbox.wrapText(dl, ctx.ui.get(.regular), 13, r.x, r.y, r.w, n.text, 6, ctx.col(.faint));
            } else drawNodes(ctx, dl, e, p, t, n.child, ox, oy, clip);
        },
        .item => drawItem(ctx, dl, e, p, t, at, n, r, ox, oy, clip),
    }
}

fn nodeId(p: *const engine.Plugin, t: *const Tree, at: u32) usize {
    return @as(usize, p.slot) * 100_000 + at + 0xA0000 + (if (t.settings) @as(usize, 50_000) else 0);
}

fn drawSelect(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *Tree, at: u32, n: *Node, r: d.Rect) void {
    const rad = @max(ctx.th.radius, 4);
    _ = d.textClipped(dl, ctx.ui.get(.semibold), 12.5, r.x, r.y, ctx.col(.muted), n.text, r.w);
    const box: d.Rect = .{ .x = r.x, .y = r.y + select_label_h, .w = @min(r.w, select_max_w), .h = select_box_h };
    const id = nodeId(p, t, at);
    const hb = d.hit(ctx, id, box);
    qa.mark(box, "pp-select:{s}", .{n.key});
    const key = id + 0x5E00000;
    if (hb.clicked) dropdown.toggle(key);
    const opened = dropdown.isOpen(key);
    d.rect(dl, box, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), rad);
    d.border(dl, box, if (hb.hovered or opened) ctx.col(.accent).alpha(0.6) else ctx.col(.border), rad, 1);
    // O rótulo da escolhida, e quantas são.
    var shown: []const u8 = n.meta;
    var rows: usize = 0;
    var sel_at: usize = 0;
    var o = n.child;
    while (o != panel.none) : (o = t.nodes.items[o].next) {
        const opt = &t.nodes.items[o];
        if (std.mem.eql(u8, opt.meta, n.meta)) {
            shown = opt.text;
            sel_at = rows;
        }
        rows += 1;
    }
    const f = ctx.ui.get(.medium);
    _ = d.textClipped(dl, f, 13.5, box.x + 10, d.centerY(box, 13.5), ctx.col(.text), shown, box.w - 34);
    icons.chevron(dl, box.right() - 17, box.y + select_box_h / 2, ctx.col(.muted).u(), if (opened) 0 else 1);
    const total = select_row_h * @as(f32, @floatFromInt(rows));
    const scroll = select_row_h * @as(f32, @floatFromInt(sel_at));
    if (dropdown.beginAt(ctx, key, box, box.w, total, scroll)) |dd_c| {
        var dd = dd_c;
        defer dd.end();
        o = n.child;
        while (o != panel.none) : (o = t.nodes.items[o].next) {
            const opt = &t.nodes.items[o];
            const sel = std.mem.eql(u8, opt.meta, n.meta);
            const ro = dd.row(select_row_h, sel);
            qa.mark(ro.rect, "pp-opt:{s}:{s}", .{ n.key, opt.meta });
            _ = d.textClipped(dd.dl, ctx.ui.get(if (sel) .semibold else .regular), 13.5, ro.rect.x + 8, d.centerY(ro.rect, 13.5), if (sel) ctx.col(.text) else ctx.col(.muted), opt.text, ro.rect.w - 14);
            if (ro.hit.clicked) {
                // Mostra na hora; o plugin guarda e, se quiser, publica de novo.
                n.meta = opt.meta;
                e.generation +%= 1;
                e.panelGesture(p, n.change, opt.meta);
                dropdown.close();
            }
        }
    }
}

fn drawToggle(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *const Tree, at: u32, n: *Node, r: d.Rect) void {
    const id = nodeId(p, t, at);
    const hb = d.hit(ctx, id, r);
    qa.mark(r, "pp-toggle:{s}", .{n.key});
    const sw: d.Rect = .{ .x = r.right() - 40, .y = r.y + 2, .w = 40, .h = 24 };
    const is_on = n.value > 0.5;
    const on = anim.to(anim.id("plugin-toggle", id), if (is_on) 1 else 0, 22);
    d.rect(dl, sw, ctx.col(.faint).mix(ctx.col(.accent), on), 12);
    d.circle(dl, sw.x + 12 + on * 16, sw.y + 12, 9, d.Rgba.white);
    _ = d.textClipped(dl, ctx.ui.get(.semibold), 13.5, r.x, r.y + 4, ctx.col(.text), n.text, r.w - 52);
    if (n.sub.len > 0) _ = inbox.wrapText(dl, ctx.ui.get(.regular), 12.5, r.x, r.y + 24, r.w - 52, n.sub, 4, ctx.col(.muted));
    if (hb.clicked) {
        n.value = if (is_on) 0 else 1;
        e.panelToggle(p, n.change, !is_on);
    }
}

fn drawButton(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *const Tree, at: u32, n: *const Node, r: d.Rect) void {
    const hb = d.hit(ctx, nodeId(p, t, at), r);
    const key = if (n.key.len > 0) n.key else n.text;
    qa.mark(r, "pp-btn:{s}", .{key});
    const f = ctx.ui.get(.semibold);
    const rad = @max(ctx.th.radius, 5);
    switch (n.style) {
        .accent => d.rect(dl, r, if (hb.hovered) ctx.col(.accent).mix(d.Rgba.black, 0.12) else ctx.col(.accent), rad),
        .danger => {
            if (hb.hovered) d.rect(dl, r, ctx.col(.danger), rad);
            d.border(dl, r, ctx.col(.danger).alpha(0.6), rad, 1);
        },
        else => {
            d.rect(dl, r, if (hb.hovered) ctx.col(.hover).mix(ctx.col(.text), 0.05) else ctx.col(.rail).mix(ctx.col(.elevated), 0.4), rad);
            d.border(dl, r, ctx.col(.border), rad, 1);
        },
    }
    const ink = switch (n.style) {
        .accent => ctx.col(.accent_text),
        .danger => if (hb.hovered) d.Rgba.white else ctx.col(.danger),
        else => ctx.col(.text),
    };
    const tw = d.width(f, 13, n.text);
    _ = d.textClipped(dl, f, 13, r.x + @max(8, (r.w - tw) / 2), d.centerY(r, 13), ink, n.text, r.w - 12);
    if (hb.clicked) e.panelGesture(p, n.click, null);
}

fn drawBar(ctx: *d.Ctx, dl: *c.ImDrawList, n: *const Node, r: d.Rect) void {
    const f = ctx.ui.get(.medium);
    const k: f32 = if (n.max > 0) std.math.clamp(n.value / n.max, 0, 1) else 0;
    const track: d.Rect = .{ .x = r.x, .y = r.y + 19, .w = r.w, .h = 5 };
    const vw = d.width(f, 12, n.meta);
    _ = d.textClipped(dl, f, 12.5, r.x, r.y + 1, ctx.col(.text), n.text, r.w - vw - 8);
    d.text(dl, f, 12, r.right() - vw, r.y + 1, ctx.col(.muted), n.meta);
    d.rect(dl, track, ctx.col(.rail).mix(ctx.col(.text), 0.08), 2.5);
    if (k > 0) d.rect(dl, .{ .x = track.x, .y = track.y, .w = @max(track.w * k, 3), .h = track.h }, styleBar(ctx, n.style), 2.5);
    if (n.key.len > 0) qa.mark(r, "pp-bar:{s}", .{n.key});
}

fn styleBar(ctx: *d.Ctx, s: panel.Style) d.Rgba {
    return if (s == .danger) ctx.col(.danger) else ctx.col(.accent);
}

fn drawItem(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *Tree, at: u32, n: *const Node, r: d.Rect, ox: f32, oy: f32, clip: d.Rect) void {
    const key = if (n.key.len > 0) n.key else n.text;
    const clickable = n.click != 0;
    // Os botões do item ficam por cima e pegam o clique antes dele.
    const hb = if (clickable) d.hitUnder(ctx, nodeId(p, t, at), r) else d.Hit{ .hovered = false, .clicked = false, .held = false, .middle = false, .right = false, .ctrl = false };
    qa.mark(r, "pp-item:{s}", .{key});
    const rad = @max(ctx.th.radius, 5);
    d.rect(dl, r, if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.35), rad);
    const inner_x = r.x + 10;
    const inner_w = r.w - 20;
    const mw = metaW(ctx, n);
    _ = d.textClipped(dl, ctx.ui.get(.semibold), 13.5, inner_x, r.y + 7, ctx.col(.text), n.text, inner_w - mw);
    if (n.meta.len > 0) {
        const f = ctx.ui.get(.regular);
        d.text(dl, f, 11.5, r.right() - 10 - d.width(f, 11.5, n.meta), r.y + 9, ctx.col(.faint), n.meta);
    }
    if (n.sub.len > 0) _ = inbox.wrapText(dl, ctx.ui.get(.regular), 12.5, inner_x, r.y + 26, inner_w, n.sub, 4, ctx.col(.muted));
    if (n.child != panel.none) drawNodes(ctx, dl, e, p, t, n.child, ox, oy, clip);
    if (hb.clicked) e.panelGesture(p, n.click, null);
}

fn drawInput(ctx: *d.Ctx, dl: *c.ImDrawList, e: *engine.Engine, p: *engine.Plugin, t: *const Tree, n: *const Node, r: d.Rect) void {
    const id = hash2(p.name, n.key) +% @intFromBool(t.settings);
    const in = inputFor(id);
    const label_id = @as(c_int, @truncate(@as(i64, @bitCast(id))));
    const f = ctx.ui.get(.regular);
    const fs: f32 = 13.5;
    const box: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 30 };
    const rad = @max(ctx.th.radius, 4);
    d.rect(dl, box, ctx.col(.elevated), rad);
    qa.mark(box, "pp-input:{s}", .{n.key});
    c.ImGui_PushFontFloat(f, fs);
    defer c.ImGui_PopFont();
    c.ImGui_SetCursorScreenPos(d.v(box.x + 8, box.y + 6));
    c.ImGui_SetNextItemWidth(box.w - 16);
    c.ImGui_PushIDInt(label_id);
    defer c.ImGui_PopID();
    // A árvore manda, menos enquanto a pessoa está digitando nele.
    if (in.tree != t.serial) {
        in.tree = t.serial;
        if (!in.active and !std.mem.eql(u8, std.mem.sliceTo(&in.buf, 0), n.meta)) {
            @memset(&in.buf, 0);
            const k = @min(n.meta.len, in.buf.len - 1);
            @memcpy(in.buf[0..k], n.meta[0..k]);
            @memcpy(&in.sent, &in.buf);
        }
    }
    if (refocus == id) {
        c.ImGui_SetKeyboardFocusHere();
        refocus = 0;
    }
    // A dica fica sem terminador aqui: o texto da árvore não tem zero no fim.
    var hint: [160]u8 = undefined;
    const hz = std.fmt.bufPrintSentinel(&hint, "{s}", .{d.utf8Prefix(n.sub, hint.len - 1)}, 0) catch "";
    const entered = c.ImGui_InputTextWithHint("##in", hz.ptr, &in.buf, in.buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
    in.active = c.ImGui_IsItemActive();
    d.border(dl, box, if (in.active) ctx.col(.accent).alpha(0.8) else ctx.col(.border), rad, 1);
    const text = std.mem.sliceTo(&in.buf, 0);
    if (!std.mem.eql(u8, text, std.mem.sliceTo(&in.sent, 0))) {
        @memcpy(&in.sent, &in.buf);
        e.panelChange(p, n.change, text);
    }
    if (entered and n.submit != 0) {
        e.panelGesture(p, n.submit, text);
        if (n.clear) {
            @memset(&in.buf, 0);
            @memset(&in.sent, 0);
        }
        refocus = id;
    }
}
