//! Painel de mensagens fixadas de um canal (botão de alfinete no cabeçalho).
//! Clicar leva à mensagem, buscando em volta dela se não estiver carregada.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const types = @import("../core/types.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;
const Id = types.Id;

/// Altura de cada cartão: quem está fora da tela só soma (nada de refazer a
/// prévia de todos a cada quadro).
var heights: [256]f32 = @splat(0);
var heights_w: f32 = 0;
var heights_n: usize = 0;

pub fn draw(ctx: *d.Ctx, channel: Id) void {
    const cs = ctx.store.channel(channel) orelse return popup.close(ctx);
    const r = inbox.panelRect(ctx);
    const dl = popup.beginWindow("##pins", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    qa.mark(r, "pins-panel", .{});
    const fam = ctx.ui;
    const list = ctx.store.pins.getPtr(channel);
    const state = if (list) |l| l.state else .none;
    // A lista ficou velha (alguém fixou, ou foi a gente): busca de novo.
    if (state == .none) ctx.act(.{ .want_pins = channel });

    icons.pin(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    const title = i18n.tr("Mensagens fixadas", "Pinned messages");
    d.text(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), title);
    const tw = d.width(fam.get(.bold), 17, title);
    if (list) |l| if (l.items.items.len > 0) {
        var cb: [32]u8 = undefined;
        d.text(dl, fam.get(.regular), 13, r.x + 44 + tw + 10, r.y + 20, ctx.col(.faint), std.fmt.bufPrint(&cb, "{d}", .{l.items.items.len}) catch "");
    };
    var lb: [160]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 12, r.x + 18, r.y + 46, ctx.col(.faint), inbox.channelLabel(&lb, ctx, channel), r.w - 36);
    d.line(dl, r.x, r.y + 70, r.right(), r.y + 70, ctx.col(.border), 1);

    const body: d.Rect = .{ .x = r.x + 1, .y = r.y + 71, .w = r.w - 2, .h = r.h - 77 };
    const bdl = d.beginRegion(ctx, "##pins-body", body, 0);
    popup.track(bdl);
    ctx.dl = bdl;
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 10;
    const can_pin = ctx.store.channelPermissions(&cs.info) & types.perm.manage_messages != 0;

    switch (state) {
        .none, .loading => {
            w.typingDots(bdl, body.x + body.w / 2 - 7, y + 60, ctx.col(.muted), ctx.now_ms);
            @import("anim.zig").active = true;
            y += 120;
        },
        .failed => y = message(ctx, bdl, body, y, i18n.tr("Não consegui carregar as fixadas.", "Couldn't load the pinned messages."), i18n.tr("Feche e abra de novo para tentar outra vez.", "Close and reopen to try again."), "pins-failed"),
        .loaded => {
            const items = list.?.items.items;
            if (items.len == 0) y = message(ctx, bdl, body, y, i18n.tr("Nada fixado neste canal.", "Nothing pinned in this channel."), i18n.tr("Quem pode gerenciar mensagens fixa pelo menu da mensagem.", "People who can manage messages pin from the message menu."), "pins-empty");
            if (heights_w != body.w or heights_n != items.len) {
                heights = @splat(0);
                heights_w = body.w;
                heights_n = items.len;
            }
            for (items, 0..) |*m, i| {
                const known = if (i < heights.len) heights[i] else 0;
                if (known > 0 and (y + known < body.y - 64 or y > body.bottom() + 64)) {
                    y += known;
                    continue;
                }
                const y1 = card(ctx, bdl, body, y, m, can_pin, channel, cs.info.guild);
                if (i < heights.len) heights[i] = y1 - y;
                y = y1;
            }
        },
    }
    d.endRegion(ctx, y + 6, body.x);
    ctx.dl = dl;
}

fn message(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y: f32, t1: []const u8, t2: []const u8, mark: []const u8) f32 {
    const fam = ctx.ui;
    const w1 = d.width(fam.get(.bold), 16, t1);
    const w2 = d.width(fam.get(.regular), 13.5, t2);
    d.text(dl, fam.get(.bold), 16, body.x + (body.w - w1) / 2, y + 70, ctx.col(.text), t1);
    d.text(dl, fam.get(.regular), 13.5, body.x + @max(12, (body.w - w2) / 2), y + 96, ctx.col(.muted), t2);
    qa.mark(.{ .x = body.x, .y = y + 70, .w = body.w, .h = 44 }, "{s}", .{mark});
    return y + 140;
}

/// Um cartão: avatar, nome, data e o começo do texto. Clicar vai até a mensagem.
fn card(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32, m: *const StoredMessage, can_pin: bool, channel: Id, guild: Id) f32 {
    const fam = ctx.ui;
    const x = body.x + 12;
    const wd = body.w - 24;
    const inner = x + 12;
    const tx = inner + 34;
    const tw = wd - 24 - 34 - (if (can_pin) @as(f32, 30) else 0);
    var pb: [600]u8 = undefined;
    const text = inbox.previewText(ctx, &pb, m);
    const text_h = inbox.wrapText(null, fam.get(.regular), 14, tx, 0, tw, text, 4, ctx.col(.text));
    const h = 36 + text_h + 10;
    const r: d.Rect = .{ .x = x, .y = y0, .w = wd, .h = h };
    // Por baixo do X de desafixar: quem está em cima ganha o clique.
    const hb = d.hitUnder(ctx, @truncate(m.msg.id), r);
    qa.mark(r, "pin-open:{d}", .{m.msg.id});
    if (hb.hovered) d.rect(dl, r, ctx.col(.hover), @max(ctx.th.radius, 6));
    d.border(dl, r, ctx.col(.border), @max(ctx.th.radius, 6), 1);
    w.avatar(ctx, dl, inner + 13, y0 + 22, 26, m.msg.author, .circle, null, 1);
    const name = if (ctx.store.user(m.msg.author)) |u| u.name else "?";
    const nw = d.textClipped(dl, fam.get(.semibold), 14, tx, y0 + 9, w.nameColor(ctx, guild, m.msg.author), name, tw * 0.6);
    var tb: [48]u8 = undefined;
    d.text(dl, fam.get(.regular), 11.5, tx + nw + 8, y0 + 11.5, ctx.col(.faint), w.stamp(&tb, m.msg.timestamp, @divTrunc(ctx.now_ms, 1000)));
    _ = inbox.wrapText(dl, fam.get(.regular), 14, tx, y0 + 30, tw, text, 4, ctx.col(.text).mix(ctx.col(.muted), 0.15));
    if (can_pin) {
        const xr: d.Rect = .{ .x = r.right() - 32, .y = y0 + 6, .w = 26, .h = 26 };
        const xh = d.hit(ctx, @truncate(m.msg.id ^ 0x71A), xr);
        qa.mark(xr, "pin-remove:{d}", .{m.msg.id});
        if (xh.hovered) d.circle(dl, xr.x + 13, xr.y + 13, 13, ctx.col(.danger));
        const ic = if (xh.hovered) d.Rgba.white else ctx.col(.muted);
        d.line(dl, xr.x + 8.5, xr.y + 8.5, xr.x + 17.5, xr.y + 17.5, ic, 1.8);
        d.line(dl, xr.x + 17.5, xr.y + 8.5, xr.x + 8.5, xr.y + 17.5, ic, 1.8);
        d.tip(ctx, xr, i18n.tr("Desafixar", "Unpin"), xh.hovered);
        if (xh.clicked) ctx.act(.{ .pin_message = .{ .channel = channel, .id = m.msg.id, .add = false } });
    }
    if (hb.clicked) inbox.openMessage(ctx, channel, m.msg.id);
    return y0 + h + 8;
}
