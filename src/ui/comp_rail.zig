//! `guild-bar`: a barra de servidores.
//!   orientation = vertical | horizontal   (padrão: pelo formato do espaço)
//!   shape       = circle | squircle | square | text
//!   size        = tamanho do ícone (48)
//!   labels      = mostra o nome ao lado do ícone (horizontal)
//!   home        = mostra o logo no começo (#true)
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");

pub fn draw(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const horizontal = if (n.str("orientation")) |o| std.mem.eql(u8, o, "horizontal") else r.w > r.h;
    const shape_s = d.pstr(n, "shape", "circle");
    if (std.mem.eql(u8, shape_s, "text")) return textTabs(ctx, n, r);
    if (horizontal) horizontalBar(ctx, n, r, w.shapeOf(shape_s)) else verticalBar(ctx, n, r, w.shapeOf(shape_s));
}

fn verticalBar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, shape: w.Shape) void {
    const size = d.pnum(n, "size", 48);
    const step = size + 8;
    const dl = d.beginRegion(ctx, "##guilds", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 12;
    const cx = r.x + r.w / 2;

    if (d.pflag(n, "home", true)) {
        icon(ctx, dl, null, cx, y, size, shape, .left, r);
        y += step;
        d.rect(dl, .{ .x = cx - size * 0.25, .y = y - 4, .w = size * 0.5, .h = 2 }, ctx.col(.text).alpha(0.08), 1);
        y += 6;
    }
    for (ctx.store.guilds.items, 0..) |*g, i| {
        icon(ctx, dl, .{ .g = g, .i = i }, cx, y, size, shape, .left, r);
        y += step;
    }
    d.endRegion(ctx, y, r.x);
}

fn horizontalBar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, shape: w.Shape) void {
    const size = @min(d.pnum(n, "size", 36), r.h - 8);
    const labels = d.pflag(n, "labels", false);
    const dl = ctx.dl;
    var x = r.x + 10;
    const cy = r.y + r.h / 2;
    const font = ctx.ui.get(.semibold);

    if (d.pflag(n, "home", true)) {
        icon(ctx, dl, null, x + size / 2, cy - size / 2, size, shape, .bottom, r);
        x += size + 12;
    }
    for (ctx.store.guilds.items, 0..) |*g, i| {
        if (!labels) {
            if (x + size > r.right()) break;
            icon(ctx, dl, .{ .g = g, .i = i }, x + size / 2, cy - size / 2, size, shape, .bottom, r);
            x += size + 10;
            continue;
        }
        // Pílula com ícone + nome.
        const fs: f32 = 14;
        const tw = d.width(font, fs, g.name);
        const pw = size + 10 + tw + 16;
        if (x + pw > r.right()) break;
        const pr: d.Rect = .{ .x = x, .y = cy - size / 2 - 3, .w = pw, .h = size + 6 };
        const hb = d.hit(ctx, 1000 + i, pr);
        if (hb.clicked) ctx.act(.{ .select_guild = g.id });
        const sel = ctx.st.guild == g.id;
        const k = anim.to(anim.id("hpill", i), if (sel) 1 else if (hb.hovered) 0.45 else 0, 18);
        d.rect(dl, pr, ctx.col(.accent).alpha(0.16 * k), pr.h / 2);
        if (sel) d.border(dl, pr, ctx.col(.accent).alpha(0.5), pr.h / 2, 1.5);
        glyph(ctx, dl, g, x + 3 + size / 2, cy, size, shape, sel or hb.hovered);
        const tc = if (sel) ctx.col(.text) else ctx.col(.muted).mix(ctx.col(.text), k);
        d.text(dl, font, fs, x + size + 12, d.centerY(pr, fs), tc, g.name);
        if (g.mentions > 0) badge(ctx, dl, pr.right() - 2, pr.y + 2, g.mentions);
        x += pw + 8;
    }
}

const Indicator = enum { left, bottom };

const GuildRef = struct { g: *types.Guild, i: usize };

fn glyph(ctx: *d.Ctx, dl: *c.ImDrawList, g: *const types.Guild, cx: f32, cy: f32, size: f32, shape: w.Shape, active: bool) void {
    const color = ctx.th.role(g.color);
    const ir: d.Rect = .{ .x = cx - size / 2, .y = cy - size / 2, .w = size, .h = size };
    d.rect(dl, ir, if (active) color else color.mix(ctx.col(.elevated), 0.55), w.shapeRadius(shape, size));
    const fs = size * (if (g.acronym.len >= 3) @as(f32, 0.3) else 0.36);
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, fs, g.acronym);
    d.text(dl, font, fs, cx - tw / 2, cy - fs * 0.62, d.Rgba.white.alpha(0.95), g.acronym);
}

fn icon(ctx: *d.Ctx, dl: *c.ImDrawList, ref: ?GuildRef, cx: f32, y: f32, size: f32, shape: w.Shape, ind: Indicator, bar: d.Rect) void {
    const n: usize = if (ref) |gr| gr.i + 1 else 0;
    const ir: d.Rect = .{ .x = cx - size / 2, .y = y, .w = size, .h = size };
    const hb = d.hit(ctx, n, ir);
    const selected = if (ref) |gr| ctx.st.guild == gr.g.id else false;
    const active = selected or hb.hovered;
    if (hb.clicked) if (ref) |gr| ctx.act(.{ .select_guild = gr.g.id }) else ctx.act(.open_palette);

    const base_r = w.shapeRadius(shape, size);
    const radius = anim.to(anim.id("g-rad", n), if (active and shape == .circle) size * 0.31 else base_r, 20);
    const fill = anim.to(anim.id("g-fill", n), if (active) 1 else 0, 20);
    const press = anim.to(anim.id("g-press", n), if (hb.held) 1 else 0, 30) * 1.5;
    const dr = ir.inset(press, press);

    if (ref) |gr| {
        const g = gr.g;
        const color = ctx.th.role(g.color);
        d.rect(dl, dr, ctx.col(.elevated).mix(color.mix(ctx.col(.elevated), 0.15), fill), radius);
        const fs = size * (if (g.acronym.len >= 3) @as(f32, 0.29) else 0.355);
        const font = ctx.ui.get(.semibold);
        const tw = d.width(font, fs, g.acronym);
        d.text(dl, font, fs, cx - tw / 2, y + size / 2 - fs * 0.62, ctx.col(.text).mix(d.Rgba.white, fill), g.acronym);
        if (g.mentions > 0) badge(ctx, dl, ir.right() + 2, ir.bottom() - 16, g.mentions);

        const target: f32 = if (selected) size * 0.83 else if (hb.hovered) size * 0.42 else if (g.unread) 8 else 0;
        const pill = anim.to(anim.id("g-pill", n), target, 18);
        if (pill > 0.5) switch (ind) {
            .left => d.rectFlags(dl, .{ .x = bar.x, .y = y + size / 2 - pill / 2, .w = 4, .h = pill }, ctx.col(.text), 4, c.ImDrawFlags_RoundRight),
            .bottom => d.rectFlags(dl, .{ .x = cx - pill / 2, .y = bar.bottom() - 4, .w = pill, .h = 3 }, ctx.col(.accent), 3, c.ImDrawFlags_RoundTop),
        };
        if (ind == .left) tooltip(ctx, n, ir.right() + 14, y + size / 2, g.name, hb.hovered);
    } else {
        // Logo: balão de conversa.
        const bg = ctx.col(.elevated).mix(ctx.col(.accent), fill);
        d.rect(dl, dr, bg, radius);
        const ink = ctx.col(.accent).mix(ctx.col(.accent_text), fill);
        const s = size / 48;
        const cy = y + size / 2 - 1 * s;
        d.rect(dl, .{ .x = cx - 12 * s, .y = cy - 9 * s, .w = 24 * s, .h = 17 * s }, ink, 8 * s);
        c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 7 * s, cy + 6 * s), d.v(cx - 1 * s, cy + 6 * s), d.v(cx - 9 * s, cy + 13 * s), ink.u());
        for ([_]f32{ -6, 0, 6 }) |dx| d.circle(dl, cx + dx * s, cy - 0.5 * s, 2 * s, bg);
        if (ind == .left) tooltip(ctx, n, ir.right() + 14, y + size / 2, "Paleta de comandos  (Ctrl+K)", hb.hovered);
    }
}

fn badge(ctx: *d.Ctx, dl: *c.ImDrawList, right: f32, top: f32, count: u16) void {
    var buf: [8]u8 = undefined;
    const lbl = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "!";
    const font = ctx.ui.get(.bold);
    const lw = d.width(font, 12, lbl);
    const bw = @max(16, lw + 9);
    d.rect(dl, .{ .x = right - bw - 3, .y = top - 3, .w = bw + 6, .h = 22 }, ctx.col(.rail), 11);
    d.rect(dl, .{ .x = right - bw, .y = top, .w = bw, .h = 16 }, ctx.col(.danger), 8);
    d.text(dl, font, 12, right - bw / 2 - lw / 2, top + 0.5, d.Rgba.white, lbl);
}

pub fn tooltip(ctx: *d.Ctx, n: usize, x: f32, cy: f32, label: []const u8, show: bool) void {
    const k = anim.to(anim.id("tip", n), if (show) 1 else 0, 26);
    if (k < 0.02) return;
    const fg = ctx.fg;
    const fs: f32 = 15;
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, fs, label);
    const ox = x - (1 - k) * 8;
    const r: d.Rect = .{ .x = ox, .y = cy - 17, .w = tw + 24, .h = 34 };
    d.shadow(fg, r, 6, 8, ctx.col(.shadow).alpha(k));
    d.rect(fg, r, ctx.col(.overlay).alpha(k), 6);
    c.ImDrawList_AddTriangleFilled(fg, d.v(ox - 5, cy), d.v(ox + 1, cy - 6), d.v(ox + 1, cy + 6), ctx.col(.overlay).col(k));
    d.text(fg, font, fs, ox + 12, cy - 9.5, ctx.col(.text).alpha(k), label);
}

/// Estilo terminal: `[1:LC] 2:RH 3:Z ...`
fn textTabs(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const font = fam.get(.regular);
    const bold = fam.get(.bold);
    const fs = d.pnum(n, "font-size", ctx.th.font_size - 1);
    var x = r.x + 8;
    var buf: [64]u8 = undefined;
    for (ctx.store.guilds.items, 0..) |*g, i| {
        const sel = ctx.st.guild == g.id;
        const lbl = std.fmt.bufPrint(&buf, " {d}:{s} ", .{ i + 1, g.acronym }) catch continue;
        const tw = d.width(if (sel) bold else font, fs, lbl);
        if (x + tw > r.right() - 4) break;
        const tr: d.Rect = .{ .x = x, .y = r.y + 2, .w = tw, .h = r.h - 4 };
        const hb = d.hit(ctx, 2000 + i, tr);
        if (hb.clicked) ctx.act(.{ .select_guild = g.id });
        if (sel) d.rect(ctx.dl, tr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(ctx.dl, tr, ctx.col(.hover), 0);
        const tc = if (sel) ctx.col(.accent_text) else if (g.mentions > 0) ctx.col(.danger) else if (g.unread) ctx.col(.text) else ctx.col(.muted);
        d.text(ctx.dl, if (sel) bold else font, fs, x, d.centerY(tr, fs), tc, lbl);
        x += tw + 2;
    }
}
