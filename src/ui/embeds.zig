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
const w_ui = @import("widgets.zig");
const links = @import("../core/links.zig");
const links_ui = @import("links.zig");

const max_w: f32 = 520;
const gap: f32 = 6;
const pad: f32 = 12;
const thumb_s: f32 = 80;

/// Altura de todos os embeds da mensagem (com o espaço acima), desenhando
/// se `dl` não for null.
pub fn block(ctx: *d.Ctx, dl: ?*c.ImDrawList, m: *const StoredMessage, x: f32, y_in: f32, avail: f32, alpha: f32) f32 {
    const invites = hasInvite(m);
    if (m.msg.embeds.len == 0 and !invites) return 0;
    var y = y_in;
    var k: usize = 0;
    for (m.msg.embeds, 0..) |*e, i| {
        y += gap;
        const spans = m.embed_spans[@min(m.embed_spans.len, k)..@min(m.embed_spans.len, k + 1 + e.fields.len)];
        k += 1 + e.fields.len;
        const w = @min(avail, max_w);
        const h = cardHeight(ctx, e, spans, w, dl != null);
        if (dl) |l| {
            _ = card(ctx, l, e, spans, x, y, w, alpha, h, m.msg.id);
            qa.mark(.{ .x = x, .y = y, .w = w, .h = h }, "embed:{d}:{d}", .{ m.msg.id, i });
        }
        y += h;
    }
    if (invites) {
        var shown: usize = 0;
        for (m.spans) |*sp| {
            if (!isInviteSpan(sp)) continue;
            if (shown == max_invites) break;
            shown += 1;
            y += gap;
            if (dl) |l| inviteCard(ctx, l, sp.text, x, y, @min(avail, invite_w), alpha, m.msg.id ^ shown);
            y += invite_h;
        }
    }
    return y - y_in;
}

// --- Cartão de convite ----------------------------------------------------------
// Mostra o servidor e abre no navegador. Não entra pelo app: POST de convite
// por conta de usuário dispara captcha e arrisca a conta.

pub const invite_w: f32 = 432;
const invite_h: f32 = 84;
const max_invites = 3;

fn isInviteSpan(sp: *const md.Span) bool {
    return sp.flags.link and !sp.flags.spoiler and links.parseInvite(sp.text) != null;
}

pub fn hasInvite(m: *const StoredMessage) bool {
    for (m.spans) |*sp| if (sp.flags.link and isInviteSpan(sp)) return true;
    return false;
}

fn inviteCard(ctx: *d.Ctx, dl: *c.ImDrawList, url: []const u8, x: f32, y: f32, wd: f32, alpha: f32, hit_id: u64) void {
    const fam = ctx.ui;
    const code = links.parseInvite(url) orelse return;
    const inv = ctx.store.invites.get(code);
    if (inv == null) ctx.act(.{ .want_invite = links.InviteCode.init(code) });
    const r: d.Rect = .{ .x = x, .y = y, .w = wd, .h = invite_h };
    qa.mark(r, "invite:{s}", .{code});
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.rail), 0.35).alpha(alpha), 6);
    d.border(dl, r, ctx.col(.border).alpha(alpha), 6, 1);
    d.text(dl, fam.get(.bold), 10.5, x + 12, y + 8, ctx.col(.muted).alpha(alpha), i18n.tr("CONVITE PARA UM SERVIDOR", "SERVER INVITE"));

    // Ícone: a imagem, ou a primeira letra.
    const ir: d.Rect = .{ .x = x + 12, .y = y + 28, .w = 44, .h = 44 };
    const state = if (inv) |i| i.state else .loading;
    const ok = state == .ok;
    var icon_drawn = false;
    if (ok) if (inv.?.icon) |hash| {
        var ub: [160]u8 = undefined;
        icon_drawn = w_ui.picture(ctx, dl, w_ui.cdnUrl(&ub, .guild, inv.?.guild, hash), ir, 12, alpha);
    };
    if (!icon_drawn) {
        d.rect(dl, ir, ctx.col(.accent).alpha(0.75 * alpha), 12);
        const g = if (ok and inv.?.name.len > 0) d.firstGlyph(inv.?.name) else "?";
        const gw = d.width(fam.get(.bold), 18, g);
        d.text(dl, fam.get(.bold), 18, ir.x + (ir.w - gw) / 2, d.centerY(ir, 18), d.Rgba.white.alpha(alpha), g);
    }

    // Botões à direita: abrir no navegador e, se já estamos nele, ir para lá.
    const browser = i18n.tr("Abrir no navegador", "Open in browser");
    const bf = fam.get(.semibold);
    const bh: f32 = 28;
    const narrow = wd < 360;
    const bw = d.width(bf, 13, browser) + 20;
    const member = ok and inv.?.guild != 0 and ctx.store.guild(inv.?.guild) != null;
    const go = i18n.tr("Ir para o servidor", "Go to server");
    var rx = r.right() - 10;
    const br: d.Rect = .{ .x = rx - bw, .y = if (narrow or member) y + 8 else y + 42, .w = bw, .h = bh };
    rx = br.x;
    const hb = d.hit(ctx, @truncate(hit_id *% 31 +% 1), br);
    qa.mark(br, "invite-open:{s}", .{code});
    d.rect(dl, br, (if (hb.hovered) ctx.col(.accent) else ctx.col(.hover)).alpha(alpha), bh / 2);
    d.text(dl, bf, 13, br.x + 10, d.centerY(br, 13), (if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text)).alpha(alpha), browser);
    if (hb.clicked) att.openUrl(url);
    if (member) {
        const gr: d.Rect = .{ .x = r.right() - 10 - bw, .y = y + 44, .w = bw, .h = bh };
        const gh = d.hit(ctx, @truncate(hit_id *% 31 +% 2), gr);
        qa.mark(gr, "invite-go:{s}", .{code});
        d.rect(dl, gr, ctx.col(.accent).alpha(alpha), bh / 2);
        const gt = d.width(bf, 13, go);
        d.text(dl, bf, 13, gr.x + (bw - gt) / 2, d.centerY(gr, 13), ctx.col(.accent_text).alpha(alpha), go);
        if (gh.clicked) ctx.act(.{ .select_guild = inv.?.guild });
    }

    // Nome e membros.
    const tx = ir.right() + 12;
    const room = rx - tx - 8;
    switch (state) {
        .loading => d.text(dl, fam.get(.regular), 13, tx, y + 40, ctx.col(.muted).alpha(alpha), i18n.tr("carregando…", "loading…")),
        .invalid => d.text(dl, fam.get(.semibold), 13.5, tx, y + 40, ctx.col(.danger).alpha(alpha), i18n.tr("Convite inválido ou expirado", "Invalid or expired invite")),
        .failed => d.text(dl, fam.get(.regular), 13, tx, y + 40, ctx.col(.muted).alpha(alpha), i18n.tr("não consegui carregar o convite", "couldn't load the invite")),
        .ok => {
            _ = d.textClipped(dl, fam.get(.bold), 15, tx, y + 30, ctx.col(.text).alpha(alpha), inv.?.name, room);
            var cb: [64]u8 = undefined;
            var cx = tx;
            if (inv.?.online > 0) {
                d.circle(dl, cx + 4, y + 60, 4, ctx.col(.online).alpha(alpha));
                const t = i18n.fmt(&cb, "{d} online", "{d} online", .{inv.?.online});
                d.text(dl, fam.get(.regular), 12.5, cx + 12, y + 52, ctx.col(.muted).alpha(alpha), t);
                cx += 12 + d.width(fam.get(.regular), 12.5, t) + 10;
            }
            if (inv.?.members > 0) {
                d.circle(dl, cx + 4, y + 60, 4, ctx.col(.faint).alpha(alpha));
                const t = i18n.fmt(&cb, "{d} membros", "{d} members", .{inv.?.members});
                _ = d.textClipped(dl, fam.get(.regular), 12.5, cx + 12, y + 52, ctx.col(.muted).alpha(alpha), t, @max(0, rx - cx - 20));
            }
        },
    }
}

/// Altura medida por embed: desenhar não precisa fazer o layout duas vezes
/// por quadro. Quem erra a chave só mede de novo.
const HeightSlot = struct { key: u64 = 0, h: f32 = 0 };
var height_cache: [64]HeightSlot = @splat(.{});

fn cardHeight(ctx: *d.Ctx, e: *const types.Embed, spans: []const []const md.Span, w: f32, use_cache: bool) f32 {
    if (!use_cache) return card(ctx, null, e, spans, 0, 0, w, 1, 0, 0);
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&@intFromPtr(e)));
    hash.update(std.mem.asBytes(&w));
    hash.update(std.mem.asBytes(&d.text_scale));
    hash.update(std.mem.asBytes(&ctx.st.theme_gen));
    const key = hash.final() | 1;
    const slot = &height_cache[key % height_cache.len];
    if (slot.key == key) return slot.h;
    slot.* = .{ .key = key, .h = card(ctx, null, e, spans, 0, 0, w, 1, 0, 0) };
    return slot.h;
}

fn opts(ctx: *d.Ctx, size: f32) rich.Opts {
    return .{
        .ctx = ctx,
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
                // Link do Discord no título de um bot abre aqui.
                if (hb.clicked) links_ui.open(ctx, e.url);
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
