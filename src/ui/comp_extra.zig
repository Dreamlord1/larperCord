//! Componentes "de assinatura" dos temas.
//!
//! logo:   variant = ascii | wordmark      (logo do app)
//! topbar: barra superior com voltar/avançar entre abas, busca e ajuda
//! crt:    efeito de monitor antigo (linhas de varredura + vinheta), por cima de tudo
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");

const ascii_logo = [_][]const u8{
    "┬  ┌─┐┬─┐┌─┐┌─┐┬─┐┌─┐┌─┐┬─┐┌┬┐",
    "│  ├─┤├┬┘├─┘├┤ ├┬┘│  │ │├┬┘ ││",
    "┴─┘┴ ┴┴└─┴  └─┘┴└─└─┘└─┘┴└──┴┘",
};

pub fn logo(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const dl = ctx.dl;
    if (d.is(n, "variant", "ascii", "wordmark")) {
        const fam = ctx.mono;
        const fs = d.pnum(n, "size", 13);
        const lh = fs * 1.05;
        const w = d.width(fam.get(.regular), fs, ascii_logo[0]);
        const x = r.x + @max(8, (r.w - w) / 2);
        var y = r.y + (r.h - lh * 3) / 2 - 4;
        for (ascii_logo) |ln| {
            d.text(dl, fam.get(.regular), fs, x, y, ctx.col(.accent), ln);
            y += lh;
        }
        const sub = i18n.tr("cliente leve · zig", "lightweight client · zig");
        const sw = d.width(fam.get(.regular), fs - 2, sub);
        d.text(dl, fam.get(.regular), fs - 2, r.x + (r.w - sw) / 2, y + 2, ctx.col(.faint), sub);
        return;
    }
    // Wordmark: balão + nome.
    const fam = ctx.familyFor(n);
    const fs = d.pnum(n, "size", 17);
    const cy = r.y + r.h / 2;
    const bx = r.x + 16;
    d.rect(dl, .{ .x = bx, .y = cy - 9, .w = 22, .h = 16 }, ctx.col(.accent), 7);
    c.ImDrawList_AddTriangleFilled(dl, d.v(bx + 4, cy + 5), d.v(bx + 10, cy + 5), d.v(bx + 2, cy + 11), ctx.col(.accent).u());
    for ([_]f32{ -5, 0, 5 }) |dx| d.circle(dl, bx + 11 + dx, cy - 1, 1.8, ctx.col(.accent_text));
    d.text(dl, fam.get(.bold), fs, bx + 32, d.centerY(r, fs), ctx.col(.text), "larperCord");
}

pub fn topbar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const dl = ctx.dl;
    const fam = ctx.familyFor(n);
    const st = ctx.st;
    // Voltar / avançar entre as abas abertas.
    const nav = [_]struct { glyph: []const u8, delta: i32, tip: []const u8, tip_en: []const u8 }{
        .{ .glyph = "←", .delta = -1, .tip = "Aba anterior  (Ctrl+Shift+Tab)", .tip_en = "Previous tab  (Ctrl+Shift+Tab)" },
        .{ .glyph = "→", .delta = 1, .tip = "Próxima aba  (Ctrl+Tab)", .tip_en = "Next tab  (Ctrl+Tab)" },
    };
    var x = r.x + 12;
    for (nav, 0..) |b, i| {
        const br: d.Rect = .{ .x = x, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
        const hb = d.hit(ctx, i, br);
        if (hb.clicked) ctx.act(.{ .next_tab = b.delta });
        if (hb.hovered) d.rect(dl, br, ctx.col(.hover), 5);
        const gw = d.width(fam.get(.bold), 16, b.glyph);
        d.text(dl, fam.get(.bold), 16, br.x + 13 - gw / 2, d.centerY(br, 16), if (hb.hovered) ctx.col(.text) else ctx.col(.muted), b.glyph);
        d.tip(ctx, br, i18n.tr(b.tip, b.tip_en), hb.hovered);
        x += 30;
    }
    // Busca no meio (abre a paleta).
    const sw = @min(560, r.w * 0.5);
    const sr: d.Rect = .{ .x = r.x + (r.w - sw) / 2, .y = r.y + r.h / 2 - 14, .w = sw, .h = 28 };
    const sh = d.hit(ctx, 10, sr);
    if (sh.clicked) ctx.act(.open_palette);
    const k = anim.to(anim.id("topsearch", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
    d.rect(dl, sr, ctx.col(.text).alpha(0.12 + 0.06 * k), 7);
    d.border(dl, sr, ctx.col(.text).alpha(0.15 + 0.15 * k), 7, 1);
    icons.search(dl, sr.x + 16, sr.y + 14, ctx.col(.muted).u());
    var buf: [96]u8 = undefined;
    const g = ctx.store.guild(st.guild);
    const label0 = if (g) |x_|
        i18n.fmt(&buf, "Buscar em {s}", "Search {s}", .{x_.name})
    else
        i18n.tr("Buscar em mensagens diretas", "Search Direct Messages");
    const label = if (label0.len == 0) i18n.tr("Buscar", "Search") else label0;
    _ = d.textClipped(dl, fam.get(.medium), 13, sr.x + 30, d.centerY(sr, 13), ctx.col(.muted), label, sr.w - 100);
    const kw = d.width(fam.get(.semibold), 11, "Ctrl K");
    d.text(dl, fam.get(.semibold), 11, sr.right() - kw - 12, d.centerY(sr, 11), ctx.col(.faint), "Ctrl K");
    // Ajuda (abre os atalhos).
    const hr: d.Rect = .{ .x = r.right() - 40, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
    const hh = d.hit(ctx, 11, hr);
    if (hh.clicked) {
        st.settings.page = .atalhos;
        ctx.act(.open_settings);
    }
    c.ImDrawList_AddCircleEx(dl, d.v(hr.x + 13, hr.y + 13), 9, (if (hh.hovered) ctx.col(.text) else ctx.col(.muted)).u(), 0, 1.6, 0);
    const qw = d.width(fam.get(.bold), 12, "?");
    d.text(dl, fam.get(.bold), 12, hr.x + 13 - qw / 2, d.centerY(hr, 12), if (hh.hovered) ctx.col(.text) else ctx.col(.muted), "?");
    d.tip(ctx, hr, i18n.tr("Atalhos de teclado", "Keybinds"), hh.hovered);
}

/// Linhas de varredura e cantos escurecidos, desenhados por cima de tudo.
pub fn crt(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fg = ctx.fg;
    const gap = d.pnum(n, "spacing", 3);
    const strength = d.pnum(n, "strength", 0.08);
    var y = r.y;
    const lc = d.Rgba.black.alpha(strength);
    while (y < r.bottom()) : (y += gap) d.line(fg, r.x, y, r.right(), y, lc, 1);
    // Vinheta: as bordas mais escuras, como um tubo de imagem.
    const vw = @min(r.w, r.h) * 0.18;
    const edge = d.Rgba.black.col(0.32);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.y), d.v(r.x + vw, r.bottom()), edge, 0, 0, edge);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.right() - vw, r.y), d.v(r.right(), r.bottom()), 0, edge, edge, 0);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.y), d.v(r.right(), r.y + vw), edge, edge, 0, 0);
    c.ImDrawList_AddRectFilledMultiColor(fg, d.v(r.x, r.bottom() - vw), d.v(r.right(), r.bottom()), 0, 0, edge, edge);
}
