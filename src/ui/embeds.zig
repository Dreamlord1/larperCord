//! Cartões de embed (bots, prévias de links, vídeos do YouTube…): barra de
//! cor à esquerda, autor, título, descrição em markdown, campos, imagem,
//! miniatura e rodapé. Mede e desenha com a mesma função (dl = null mede).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const rich = @import("rich.zig");
const att = @import("attachments.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;
const md = @import("../core/markdown.zig");
const video = @import("video.zig");

const max_w: f32 = 520;
const gap: f32 = 6;
const pad: f32 = 12;
const thumb_s: f32 = 80;

/// Altura de todos os embeds da mensagem (com o espaço acima), desenhando
/// se `dl` não for null.
pub fn block(ctx: *d.Ctx, dl: ?*c.ImDrawList, m: *const StoredMessage, x: f32, y_in: f32, avail: f32, alpha: f32) f32 {
    if (m.msg.embeds.len == 0) return 0;
    var y = y_in;
    var k: usize = 0;
    for (m.msg.embeds, 0..) |*e, i| {
        y += gap;
        const spans = m.embed_spans[k..@min(m.embed_spans.len, k + 1 + e.fields.len)];
        k += 1 + e.fields.len;
        const w = @min(avail, max_w);
        const h = card(ctx, null, e, spans, x, y, w, alpha, 0, 0);
        if (dl) |l| {
            _ = card(ctx, l, e, spans, x, y, w, alpha, h, m.msg.id);
            qa.mark(.{ .x = x, .y = y, .w = w, .h = h }, "embed:{d}:{d}", .{ m.msg.id, i });
        }
        y += h;
    }
    return y - y_in;
}

fn opts(ctx: *const d.Ctx, size: f32) rich.Opts {
    return .{
        .family = ctx.ui,
        .size = size,
        .line_h = size * 1.42,
        .color = ctx.col(.text).mix(ctx.col(.muted), 0.15),
        .reveal_spoilers = ctx.st.settings.show_spoilers,
        .underline_links = ctx.st.settings.underline_links,
    };
}

/// Um cartão. Medindo (dl = null) devolve a altura; desenhando, `h` é a
/// altura medida antes (para o fundo ir por baixo do resto).
fn card(ctx: *d.Ctx, dl: ?*c.ImDrawList, e: *const types.Embed, spans: []const []const md.Span, x: f32, y0: f32, w: f32, alpha: f32, h: f32, msg_id: types.Id) f32 {
    const fam = ctx.ui;
    if (dl) |l| {
        const r: d.Rect = .{ .x = x, .y = y0, .w = w, .h = h };
        d.rect(l, r, ctx.col(.elevated).mix(ctx.col(.rail), 0.35).alpha(alpha), 6);
        const bar = if (e.has_color and e.color != 0) d.Rgba.hex(e.color) else ctx.col(.border).mix(ctx.col(.text), 0.15);
        d.rectFlags(l, .{ .x = x, .y = y0, .w = 4, .h = h }, bar.alpha(alpha), 6, c.ImDrawFlags_RoundCornersLeft);
    }
    const has_thumb = e.thumb.len > 0 and e.image.len == 0;
    const ix = x + 4 + pad;
    const tw = w - 4 - pad * 2 - (if (has_thumb) thumb_s + pad else 0);
    var y = y0 + 10;

    if (e.provider.len > 0) {
        if (dl) |l| _ = d.textClipped(l, fam.get(.regular), 12, ix, y, ctx.col(.muted).alpha(alpha), e.provider, tw);
        y += 18;
    }
    if (e.author.len > 0) {
        if (dl) |l| _ = d.textClipped(l, fam.get(.semibold), 13.5, ix, y, ctx.col(.text).alpha(alpha), e.author, tw);
        y += 20;
    }
    if (e.title.len > 0) {
        const linked = e.url.len > 0;
        if (dl) |l| {
            const tr: d.Rect = .{ .x = ix, .y = y, .w = @min(tw, d.width(fam.get(.semibold), 15, e.title)), .h = 20 };
            const col = if (linked) ctx.col(.link) else ctx.col(.text);
            _ = d.textClipped(l, fam.get(.semibold), 15, ix, y, col.alpha(alpha), e.title, tw);
            if (linked) {
                const hb = d.hit(ctx, @truncate(@intFromPtr(e)), tr);
                if (hb.hovered) d.line(l, tr.x, tr.bottom() - 1, tr.right(), tr.bottom() - 1, col.alpha(0.6), 1);
                if (hb.clicked) att.openUrl(e.url);
            }
        }
        y += 24;
    }
    var si: usize = 0;
    if (spans.len > 0) {
        if (e.description.len > 0) {
            const t = rich.layout(dl, ctx.store, ctx.th, spans[0], ix, y, tw, opts(ctx, 14), ctx.mouse);
            y += t.h + 4;
        }
        si = 1;
    }
    for (e.fields) |f| {
        if (dl) |l| _ = d.textClipped(l, fam.get(.bold), 13, ix, y, ctx.col(.text).alpha(alpha), f.name, tw);
        y += 19;
        if (si < spans.len) {
            const t = rich.layout(dl, ctx.store, ctx.th, spans[si], ix, y, tw, opts(ctx, 13.5), ctx.mouse);
            y += t.h + 6;
        }
        si += 1;
    }
    if (e.image.len > 0) {
        y += 4;
        const iw: f32 = @floatFromInt(e.image_w);
        const ih: f32 = @floatFromInt(e.image_h);
        const s = @min(1.0, @min((w - 4 - pad * 2) / iw, 300 / ih));
        const r: d.Rect = .{ .x = ix, .y = y, .w = @max(40, @round(iw * s)), .h = @max(30, @round(ih * s)) };
        if (dl) |l| image(ctx, l, e, r, alpha, msg_id);
        y += r.h + 4;
    }
    if (e.footer.len > 0) {
        y += 2;
        if (dl) |l| _ = d.textClipped(l, fam.get(.regular), 12, ix, y, ctx.col(.muted).alpha(alpha), e.footer, w - 4 - pad * 2);
        y += 18;
    }
    if (has_thumb) {
        const tr: d.Rect = .{ .x = x + w - pad - thumb_s, .y = y0 + pad, .w = thumb_s, .h = thumb_s };
        if (dl) |l| {
            const scale = ctx.io.*.DisplayFramebufferScale.x;
            switch (ctx.images.get(e.thumb, tr.w * scale, tr.h * scale)) {
                .ready => |t| {
                    // Cabe no quadrado sem distorcer.
                    const k = @min(tr.w / @as(f32, @floatFromInt(t.w)), tr.h / @as(f32, @floatFromInt(t.h)));
                    const dw = @as(f32, @floatFromInt(t.w)) * k;
                    const dh = @as(f32, @floatFromInt(t.h)) * k;
                    c.ImDrawList_AddImageRounded(l, t.ref, d.v(tr.right() - dw, tr.y), d.v(tr.right(), tr.y + dh), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), 4, 0);
                },
                else => d.rect(l, tr, ctx.col(.text).alpha(0.05 * alpha), 4),
            }
        }
        y = @max(y, y0 + pad + thumb_s);
    }
    return y + 10 - y0;
}

fn image(ctx: *d.Ctx, dl: *c.ImDrawList, e: *const types.Embed, r: d.Rect, alpha: f32, msg_id: types.Id) void {
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    // Vídeo de um link direto (pelo proxy do Discord): toca no lugar da imagem.
    const vkey = video.keyOf(msg_id, 0x100 + std.hash.Wyhash.hash(0, e.video_url));
    if (e.video_url.len > 0 and video.isActive(vkey)) {
        const pv = ctx.images.get(e.image, r.w * scale, r.h * scale);
        video.draw(ctx, dl, r, alpha, msg_id, if (pv == .ready) pv.ready else null);
        return;
    }
    const hb = d.hit(ctx, @truncate(@intFromPtr(e) +% 1), r);
    const look = ctx.images.get(e.image, r.w * scale, r.h * scale);
    // Modo economia: o clique baixa a imagem.
    if (look == .failed and ctx.images.blocked(e.image)) {
        att.savedPlaceholder(ctx, dl, r, 0, alpha);
        if (hb.clicked) ctx.images.allow(e.image);
        return;
    }
    switch (look) {
        .ready => |t| c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), 6, 0),
        .loading => d.rect(dl, r, ctx.col(.text).alpha(0.05 * alpha), 6),
        .failed => d.rect(dl, r, ctx.col(.text).alpha(0.03 * alpha), 6),
    }
    if (e.video and e.video_url.len > 0) {
        att.playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
        d.tip(ctx, r, if (video.canPlay(e.video_url, 0)) i18n.tr("Tocar o vídeo", "Play video") else i18n.tr("Abrir o vídeo no navegador", "Open video in browser"), hb.hovered);
        if (hb.clicked) video.click(ctx, vkey, e.video_url, if (e.url.len > 0) e.url else e.video_url, r, 0);
    } else if (e.video) {
        att.playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
        d.tip(ctx, r, i18n.tr("Abrir o vídeo no navegador", "Open video in browser"), hb.hovered);
        if (hb.clicked and e.url.len > 0) att.openUrl(e.url);
    } else if (hb.clicked) att.openImage(ctx, e.image, e.title, e.image_w, e.image_h);
    if (hb.hovered) d.rect(dl, r, d.Rgba.white.alpha(0.05), 6);
}
