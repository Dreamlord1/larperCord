//! `guild-bar`: a barra de servidores.
//!   orientation = vertical | horizontal   (padrão: pelo formato do espaço)
//!   shape       = circle | squircle | square | text
//!   size        = tamanho do ícone (48)
//!   labels      = mostra o nome ao lado do ícone (horizontal)
//!   home        = mostra o logo no começo (#true)
//!   icon-style  = fill | soft | outline   (como pintar o ícone do servidor)
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");

pub fn draw(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    icon_style = std.meta.stringToEnum(IconStyle, d.pstr(n, "icon-style", "fill")) orelse .fill;
    const horizontal = if (n.str("orientation")) |o| std.mem.eql(u8, o, "horizontal") else r.w > r.h;
    const shape_s = d.pstr(n, "shape", "circle");
    if (std.mem.eql(u8, shape_s, "text")) return textTabs(ctx, n, r);
    const variant = d.pstr(n, "variant", "bar");
    if (std.mem.eql(u8, variant, "dock")) return dock(ctx, n, r, w.shapeOf(shape_s));
    if (std.mem.eql(u8, variant, "list")) return list(ctx, n, r, w.shapeOf(shape_s));
    if (horizontal) horizontalBar(ctx, n, r, w.shapeOf(shape_s)) else verticalBar(ctx, n, r, w.shapeOf(shape_s));
}

const Store = @import("../core/store.zig").Store;

/// Servidores na ordem da barra, sem pastas (para os formatos que não as mostram).
fn flatOrder(ctx: *d.Ctx, out: []*types.Guild) []*types.Guild {
    var items: [256]Store.RailItem = undefined;
    var n: usize = 0;
    for (ctx.store.railOrder(&items)) |it| switch (it) {
        .guild => |g| if (n < out.len) {
            out[n] = g;
            n += 1;
        },
        .folder => |f| for (f.guilds) |gid| if (ctx.store.guild(gid)) |g| if (n < out.len) {
            out[n] = g;
            n += 1;
        },
    };
    return out[0..n];
}

/// Índice estável de um servidor (para os IDs de animação e clique).
fn indexOf(ctx: *d.Ctx, g: *const types.Guild) usize {
    return (@intFromPtr(g) - @intFromPtr(ctx.store.guilds.items.ptr)) / @sizeOf(types.Guild);
}

/// Pasta: fechada mostra os ícones em miniatura; aberta, os servidores
/// embaixo dela numa faixa com a cor da pasta.
fn folder(ctx: *d.Ctx, dl: *c.ImDrawList, f: *const types.GuildFolder, cx: f32, y_in: f32, size: f32, shape: w.Shape, bar: d.Rect, step: f32) f32 {
    var y = y_in;
    const open = ctx.st.open_folders.contains(f.id);
    const ir: d.Rect = .{ .x = cx - size / 2, .y = y, .w = size, .h = size };
    const hb = d.hit(ctx, @truncate(f.id *% 7 +% 5000), ir);
    qa.mark(ir, "folder:{d}", .{f.id});
    if (hb.clicked) {
        if (open) _ = ctx.st.open_folders.remove(f.id) else ctx.st.open_folders.put(ctx.st.gpa, f.id, {}) catch {};
    }
    const fcol = if (f.color != 0) d.Rgba.hex(f.color) else ctx.col(.accent);
    const radius = w.shapeRadius(shape, size);
    var mentions: u32 = 0;
    var unread = false;
    var selected = false;
    for (f.guilds) |gid| if (ctx.store.guild(gid)) |g| {
        mentions += g.mentions;
        unread = unread or g.unread;
        selected = selected or ctx.st.guild == g.id;
    };
    const k = anim.to(anim.id("folder", @truncate(f.id)), if (open) 1 else 0, 18);
    if (open or k > 0.01) {
        // Faixa atrás dos servidores da pasta aberta.
        var count: f32 = 0;
        for (f.guilds) |gid| {
            if (ctx.store.guild(gid) != null) count += 1;
        }
        const band: d.Rect = .{ .x = ir.x - 4, .y = ir.y - 4, .w = size + 8, .h = size + 8 + count * step * k };
        d.rect(dl, band, fcol.alpha(0.16 * k), radius + 4);
    }
    if (open) {
        d.rect(dl, ir, fcol.alpha(if (hb.hovered) 0.4 else 0.28), radius);
        folderGlyph(dl, cx, y + size / 2, size * 0.42, fcol.mix(d.Rgba.white, 0.2));
    } else {
        d.rect(dl, ir, fcol.alpha(if (hb.hovered) 0.32 else 0.2), radius);
        // Até 4 ícones pequenos, 2×2.
        const ms = size * 0.36;
        const off = ms / 2 + 2;
        for (f.guilds[0..@min(f.guilds.len, 4)], 0..) |gid, i| {
            const g = ctx.store.guild(gid) orelse continue;
            const mx = cx + (if (i % 2 == 0) -off else off);
            const my = y + size / 2 + (if (i / 2 == 0) -off else off);
            glyph(ctx, dl, g, mx, my, ms, shape, false);
        }
        if (mentions > 0) badge(ctx, dl, ir.right() + 2, ir.bottom() - 16, @intCast(@min(mentions, 999)));
    }
    const pill: f32 = if (selected and !open) size * 0.83 else if (hb.hovered) size * 0.42 else if (unread and !open) 8 else 0;
    const pk = anim.to(anim.id("f-pill", @truncate(f.id)), pill, 18);
    if (pk > 0.5) d.rectFlags(dl, .{ .x = bar.x, .y = y + size / 2 - pk / 2, .w = 4, .h = pk }, ctx.col(.text), 4, c.ImDrawFlags_RoundRight);
    tooltip(ctx, @truncate(f.id *% 13 +% 7000), ir.right() + 14, y + size / 2, if (f.name.len > 0) f.name else i18n.tr("Pasta", "Folder"), hb.hovered);
    y += step;
    if (open) for (f.guilds) |gid| if (ctx.store.guild(gid)) |g| {
        icon(ctx, dl, .{ .g = g, .i = indexOf(ctx, g) }, cx, y, size, shape, .left, bar);
        y += step;
    };
    return y;
}

fn folderGlyph(dl: *c.ImDrawList, cx: f32, cy: f32, s: f32, col: d.Rgba) void {
    d.rect(dl, .{ .x = cx - s, .y = cy - s * 0.55, .w = s * 0.9, .h = s * 0.4 }, col, s * 0.15);
    d.rect(dl, .{ .x = cx - s, .y = cy - s * 0.35, .w = s * 2, .h = s * 1.2 }, col, s * 0.2);
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
    var items: [256]Store.RailItem = undefined;
    for (ctx.store.railOrder(&items)) |it| switch (it) {
        .guild => |g| {
            icon(ctx, dl, .{ .g = g, .i = indexOf(ctx, g) }, cx, y, size, shape, .left, r);
            y += step;
        },
        .folder => |f| y = folder(ctx, dl, f, cx, y, size, shape, r, step),
    };
    d.endRegion(ctx, y, r.x);
}

fn horizontalBar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, shape: w.Shape) void {
    // Deixa espaço para a barra de rolagem horizontal: uma barra de servidores
    // não pode simplesmente esconder o que passa da largura.
    const size = @min(d.pnum(n, "size", 36), r.h - 12);
    const labels = d.pflag(n, "labels", false);
    const font = ctx.ui.get(.semibold);
    var fb: [256]*types.Guild = undefined;
    const order = flatOrder(ctx, &fb);
    var content_w: f32 = 10;
    if (d.pflag(n, "home", true)) content_w += size + 12;
    for (order) |g| {
        if (!labels) {
            content_w += size + 10;
        } else {
            content_w += size + 10 + d.width(font, 14, g.name) + 16 + 8;
        }
    }
    content_w += 10;

    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_SetNextWindowContentSize(d.v(content_w, 0));
    _ = c.ImGui_BeginChild("##guilds-h", d.v(@max(r.w, 1), @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_HorizontalScrollbar);
    defer c.ImGui_EndChild();
    const dl = c.ImGui_GetWindowDrawList();
    const sx = c.ImGui_GetScrollX();
    var x = r.x + 10 - sx;
    const cy = r.y + (r.h - 6) / 2;

    if (d.pflag(n, "home", true)) {
        icon(ctx, dl, null, x + size / 2, cy - size / 2, size, shape, .bottom, r);
        x += size + 12;
    }
    for (order) |g| {
        const i = indexOf(ctx, g);
        if (!labels) {
            icon(ctx, dl, .{ .g = g, .i = i }, x + size / 2, cy - size / 2, size, shape, .bottom, r);
            x += size + 10;
            continue;
        }
        // Pílula com ícone + nome.
        const fs: f32 = 14;
        const tw = d.width(font, fs, g.name);
        const pw = size + 10 + tw + 16;
        const pr: d.Rect = .{ .x = x, .y = cy - size / 2 - 3, .w = pw, .h = size + 6 };
        const hb = d.hit(ctx, 1000 + i, pr);
        qa.mark(pr, "guild:{d}", .{g.id});
        if (hb.clicked) ctx.act(.{ .select_guild = g.id });
        if (hb.right) ctx.popup(.{ .menu = .{ .kind = .guild, .id = g.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
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
    // Estabelece a largura do conteúdo para o ImGui criar a rolagem.
    c.ImGui_SetCursorScreenPos(d.v(r.x + content_w - sx, r.y + 1));
    c.ImGui_Dummy(d.v(1, @max(1, r.h - 8)));
}

const Indicator = enum { left, bottom };

const GuildRef = struct { g: *types.Guild, i: usize };

pub const IconStyle = enum { fill, soft, outline };

var icon_style: IconStyle = .fill;

/// Ícone do servidor (a imagem dele, se tiver e já tiver chegado).
fn guildPicture(ctx: *d.Ctx, dl: *c.ImDrawList, g: *const types.Guild, r: d.Rect, radius: f32) bool {
    const h = g.icon orelse return false;
    var ub: [160]u8 = undefined;
    return w.picture(ctx, dl, w.cdnUrl(&ub, .guild, g.id, h), r, radius, 1);
}

fn glyph(ctx: *d.Ctx, dl: *c.ImDrawList, g: *const types.Guild, cx: f32, cy: f32, size: f32, shape: w.Shape, active: bool) void {
    const color = ctx.th.role(g.color);
    const ir: d.Rect = .{ .x = cx - size / 2, .y = cy - size / 2, .w = size, .h = size };
    const radius = w.shapeRadius(shape, size);
    if (guildPicture(ctx, dl, g, ir, radius)) {
        if (icon_style == .outline) d.border(dl, ir, color.alpha(if (active) 1 else 0.45), radius, if (active) 2 else 1.2);
        return;
    }
    const fs = size * (if (g.acronym.len >= 3) @as(f32, 0.3) else 0.36);
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, fs, g.acronym);
    const ink = switch (icon_style) {
        .fill => blk: {
            d.rect(dl, ir, if (active) color else color.mix(ctx.col(.elevated), 0.55), radius);
            break :blk d.Rgba.white.alpha(0.95);
        },
        .soft => blk: {
            d.rect(dl, ir, color.alpha(if (active) 0.32 else 0.18), radius);
            break :blk color.mix(ctx.col(.text), if (active) 0.25 else 0.45);
        },
        .outline => blk: {
            d.rect(dl, ir, ctx.col(.elevated), radius);
            d.border(dl, ir, color.alpha(if (active) 1 else 0.45), radius, if (active) 2 else 1.2);
            break :blk if (active) color.mix(ctx.col(.text), 0.2) else ctx.col(.muted);
        },
    };
    d.text(dl, font, fs, cx - tw / 2, cy - fs * 0.62, ink, g.acronym);
}

fn icon(ctx: *d.Ctx, dl: *c.ImDrawList, ref: ?GuildRef, cx: f32, y: f32, size: f32, shape: w.Shape, ind: Indicator, bar: d.Rect) void {
    const n: usize = if (ref) |gr| gr.i + 1 else 0;
    const ir: d.Rect = .{ .x = cx - size / 2, .y = y, .w = size, .h = size };
    const hb = d.hit(ctx, n, ir);
    qa.mark(ir, "guild:{d}", .{if (ref) |gr| gr.g.id else 0});
    const selected = if (ref) |gr| ctx.st.guild == gr.g.id else ctx.st.guild == 0;
    const active = selected or hb.hovered;
    if (hb.clicked) ctx.act(.{ .select_guild = if (ref) |gr| gr.g.id else 0 });
    if (hb.right) if (ref) |gr| ctx.popup(.{ .menu = .{ .kind = .guild, .id = gr.g.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });

    const base_r = w.shapeRadius(shape, size);
    const radius = anim.to(anim.id("g-rad", n), if (active and shape == .circle) size * 0.31 else base_r, 20);
    const fill = anim.to(anim.id("g-fill", n), if (active) 1 else 0, 20);
    const press = anim.to(anim.id("g-press", n), if (hb.held) 1 else 0, 30) * 1.5;
    const dr = ir.inset(press, press);

    if (ref) |gr| {
        const g = gr.g;
        const color = ctx.th.role(g.color);
        const fs = size * (if (g.acronym.len >= 3) @as(f32, 0.29) else 0.355);
        const font = ctx.ui.get(.semibold);
        const tw = d.width(font, fs, g.acronym);
        const pic = guildPicture(ctx, dl, g, dr, radius);
        if (!pic) {
            const ink = switch (icon_style) {
                .fill => blk: {
                    d.rect(dl, dr, ctx.col(.elevated).mix(color.mix(ctx.col(.elevated), 0.15), fill), radius);
                    break :blk ctx.col(.text).mix(d.Rgba.white, fill);
                },
                .soft => blk: {
                    d.rect(dl, dr, ctx.col(.elevated).mix(color.alpha(0.35), fill), radius);
                    break :blk ctx.col(.muted).mix(color.mix(ctx.col(.text), 0.3), fill);
                },
                .outline => blk: {
                    d.rect(dl, dr, ctx.col(.elevated), radius);
                    d.border(dl, dr, ctx.col(.border).mix(color, fill), radius, 1 + fill);
                    break :blk ctx.col(.muted).mix(color.mix(ctx.col(.text), 0.2), fill);
                },
            };
            d.text(dl, font, fs, cx - tw / 2, y + size / 2 - fs * 0.62, ink, g.acronym);
        }
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
        if (selected and ind == .left) d.rectFlags(dl, .{ .x = bar.x, .y = y + size / 2 - size * 0.42, .w = 4, .h = size * 0.83 }, ctx.col(.text), 4, c.ImDrawFlags_RoundRight);
        if (ind == .left) tooltip(ctx, n, ir.right() + 14, y + size / 2, i18n.tr("Mensagens diretas", "Direct Messages"), hb.hovered);
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
    var fb: [256]*types.Guild = undefined;
    const order = flatOrder(ctx, &fb);
    var content_w: f32 = 8;
    content_w += d.width(font, fs, " 0:DM ") + 2;
    for (order, 0..) |g, i| {
        var buf: [64]u8 = undefined;
        const lbl = std.fmt.bufPrint(&buf, " {d}:{s} ", .{ i + 1, g.acronym }) catch continue;
        content_w += d.width(font, fs, lbl) + 2;
    }
    content_w += 8;

    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_SetNextWindowContentSize(d.v(content_w, 0));
    _ = c.ImGui_BeginChild("##guilds-text", d.v(@max(r.w, 1), @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_HorizontalScrollbar);
    defer c.ImGui_EndChild();
    const dl = c.ImGui_GetWindowDrawList();
    const sx = c.ImGui_GetScrollX();
    var x = r.x + 8 - sx;
    var buf: [64]u8 = undefined;
    // Primeiro as mensagens diretas, como a janela 0 do tmux.
    {
        const sel = ctx.st.guild == 0;
        const lbl = " 0:DM ";
        const tw = d.width(if (sel) bold else font, fs, lbl);
        const tr: d.Rect = .{ .x = x, .y = r.y + 2, .w = tw, .h = r.h - 4 };
        const hb = d.hit(ctx, 1999, tr);
        qa.mark(tr, "guild:0", .{});
        if (hb.clicked) ctx.act(.{ .select_guild = 0 });
        if (sel) d.rect(dl, tr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), 0);
        d.text(dl, if (sel) bold else font, fs, x, d.centerY(tr, fs), if (sel) ctx.col(.accent_text) else ctx.col(.text), lbl);
        d.tip(ctx, tr, i18n.tr("Mensagens diretas", "Direct Messages"), hb.hovered);
        x += tw + 2;
    }
    for (order, 0..) |g, i| {
        const sel = ctx.st.guild == g.id;
        const lbl = std.fmt.bufPrint(&buf, " {d}:{s} ", .{ i + 1, g.acronym }) catch continue;
        const tw = d.width(if (sel) bold else font, fs, lbl);
        const tr: d.Rect = .{ .x = x, .y = r.y + 2, .w = tw, .h = r.h - 4 };
        const hb = d.hit(ctx, 2000 + i, tr);
        qa.mark(tr, "guild:{d}", .{g.id});
        if (hb.clicked) ctx.act(.{ .select_guild = g.id });
        if (sel) d.rect(dl, tr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), 0);
        const tc = if (sel) ctx.col(.accent_text) else if (g.mentions > 0) ctx.col(.danger) else if (g.unread) ctx.col(.text) else ctx.col(.muted);
        d.text(dl, if (sel) bold else font, fs, x, d.centerY(tr, fs), tc, lbl);
        x += tw + 2;
    }
    c.ImGui_SetCursorScreenPos(d.v(r.x + content_w - sx, r.y + 1));
    c.ImGui_Dummy(d.v(1, @max(1, r.h - 6)));
}

/// Dock no estilo do macOS: os ícones crescem perto do mouse.
fn dock(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, shape: w.Shape) void {
    const base = @min(d.pnum(n, "size", 40), r.h - 12);
    var fb: [256]*types.Guild = undefined;
    const order = flatOrder(ctx, &fb);
    const count = order.len + 1;
    const gap: f32 = 10;
    const total = @as(f32, @floatFromInt(count)) * (base + gap) + gap;
    const x0 = r.x + (r.w - total) / 2;
    const near = ctx.mouse.y > r.y - 60 and ctx.mouse.y < r.bottom() and ctx.mouse.x > x0 - 40 and ctx.mouse.x < x0 + total + 40;
    // Fundo de vidro do dock.
    const bg: d.Rect = .{ .x = x0, .y = r.bottom() - base - 16, .w = total, .h = base + 14 };
    d.shadow(ctx.dl, bg, 18, 14, ctx.col(.shadow));
    d.rect(ctx.dl, bg, ctx.col(.elevated).alpha(0.85), 18);
    d.border(ctx.dl, bg, ctx.col(.border).mix(ctx.col(.accent), 0.3), 18, 1);

    // Por cima de tudo, menos das configurações (que cobrem a janela).
    const dl = if (ctx.st.settings.open) ctx.dl else ctx.fg;
    var x = x0 + gap;
    for (0..count) |i| {
        const cx = x + base / 2;
        const dist = @abs(ctx.mouse.x - cx);
        const target: f32 = if (near) 1 + 0.65 * @max(0, 1 - dist / 140) else 1;
        const k = anim.to(anim.id("dock", i), target, 22);
        const size = base * k;
        const by = bg.bottom() - 7;
        const ir: d.Rect = .{ .x = cx - size / 2, .y = by - size, .w = size, .h = size };
        const hb = d.hit(ctx, 3000 + i, ir);
        qa.mark(ir, "guild:{d}", .{if (i == 0) @as(types.Id, 0) else order[i - 1].id});
        const g: ?*types.Guild = if (i == 0) null else order[i - 1];
        const gid: types.Id = if (g) |x_| x_.id else 0;
        if (hb.clicked) ctx.act(.{ .select_guild = gid });
        if (hb.right) if (g) |gg| ctx.popup(.{ .menu = .{ .kind = .guild, .id = gg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        if (g) |gg| {
            glyph(ctx, dl, gg, cx, ir.y + size / 2, size, shape, true);
            if (gg.mentions > 0) badge(ctx, dl, ir.right() + 2, ir.y - 2, gg.mentions);
        } else {
            d.rect(dl, ir, ctx.col(.accent), w.shapeRadius(shape, size));
            const t = "DM";
            const fs = size * 0.34;
            const tw = d.width(ctx.ui.get(.bold), fs, t);
            d.text(dl, ctx.ui.get(.bold), fs, cx - tw / 2, ir.y + size / 2 - fs * 0.62, ctx.col(.accent_text), t);
        }
        if (ctx.st.guild == gid) d.circle(dl, cx, bg.bottom() - 3, 2.5, ctx.col(.accent));
        if (hb.hovered) {
            const name = if (g) |gg| gg.name else i18n.tr("Mensagens diretas", "Direct Messages");
            const fs: f32 = 13;
            const tw = d.width(ctx.ui.get(.semibold), fs, name);
            const tr: d.Rect = .{ .x = cx - tw / 2 - 10, .y = ir.y - 34, .w = tw + 20, .h = 26 };
            d.rect(dl, tr, ctx.col(.overlay), 8);
            d.text(dl, ctx.ui.get(.semibold), fs, tr.x + 10, d.centerY(tr, fs), ctx.col(.text), name);
        }
        x += base + gap;
    }
    if (near) anim.active = true;
}

/// Lista vertical com ícone + nome (estilo "workspaces" do Slack).
fn list(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, shape: w.Shape) void {
    const fam = ctx.familyFor(n);
    const size = d.pnum(n, "size", 26);
    const row_h = size + 10;
    const dl = d.beginRegion(ctx, "##guildlist", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 6;
    var fb: [256]*types.Guild = undefined;
    const order = flatOrder(ctx, &fb);
    for (0..order.len + 1) |i| {
        const g: ?*types.Guild = if (i == 0) null else order[i - 1];
        const gid: types.Id = if (g) |x| x.id else 0;
        const rr: d.Rect = .{ .x = r.x + 8, .y = y, .w = r.w - 16, .h = row_h - 2 };
        const hb = d.hit(ctx, 4000 + i, rr);
        qa.mark(rr, "guild:{d}", .{gid});
        if (hb.clicked) ctx.act(.{ .select_guild = gid });
        if (hb.right) if (g) |gg| ctx.popup(.{ .menu = .{ .kind = .guild, .id = gg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        const sel = ctx.st.guild == gid;
        const k = anim.to(anim.id("glist", i), if (sel) 1 else if (hb.hovered) 0.5 else 0, 22);
        if (k > 0.01) d.rect(dl, rr, ctx.col(.selected).alpha(k), ctx.th.radius);
        const cy = rr.y + rr.h / 2;
        if (g) |gg| glyph(ctx, dl, gg, rr.x + 6 + size / 2, cy, size, shape, sel or hb.hovered) else {
            d.rect(dl, .{ .x = rr.x + 6, .y = cy - size / 2, .w = size, .h = size }, ctx.col(.accent), w.shapeRadius(shape, size));
        }
        const name = if (g) |gg| gg.name else i18n.tr("Mensagens diretas", "Direct Messages");
        const unread = if (g) |gg| gg.unread else false;
        _ = d.textClipped(dl, fam.get(if (sel or unread) .semibold else .medium), 14, rr.x + size + 14, d.centerY(rr, 14), if (sel) ctx.col(.text) else ctx.col(.muted), name, rr.w - size - 40);
        if (g) |gg| if (gg.mentions > 0) {
            var buf: [8]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d}", .{gg.mentions}) catch "";
            const tw = d.width(fam.get(.bold), 11, t);
            const br: d.Rect = .{ .x = rr.right() - tw - 16, .y = cy - 9, .w = tw + 10, .h = 18 };
            d.rect(dl, br, ctx.col(.danger), 9);
            d.text(dl, fam.get(.bold), 11, br.x + 5, d.centerY(br, 11), d.Rgba.white, t);
        };
        y += row_h;
    }
    d.endRegion(ctx, y + 6, r.x);
}
