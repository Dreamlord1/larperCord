//! Threads na interface: as linhas abaixo do canal pai na lista de canais e o
//! cartão "N mensagens · última há X" na mensagem que abriu uma thread.
//!
//! A lista de canais é virtual: por canal, uma busca no índice do pai
//! (`Store.threadIndex`, refeito só quando algo muda) e um teto de linhas.
//! Nada aqui olha as threads dos outros servidores.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const channels = @import("comp_channels.zig");
const types = @import("../core/types.zig");
const store_mod = @import("../core/store.zig");
const StoredMessage = store_mod.StoredMessage;
const Id = types.Id;

pub const Style = enum { discord, tree, pills };

/// Canal pai da thread aberta (0 = a conversa aberta não é uma thread).
pub fn openParent(ctx: *const d.Ctx) Id {
    const cs = ctx.store.channel(ctx.st.activeChannel() orelse return 0) orelse return 0;
    return if (cs.info.thread != null) cs.info.parent orelse 0 else 0;
}

fn hitId(id: Id, salt: u64) usize {
    return @truncate((id *% 0x9E3779B97F4A7C15) ^ salt);
}

/// As threads abaixo de um canal. `only_open`: a categoria está recolhida (só
/// a thread aberta continua à vista). Devolve o `y` depois delas.
pub fn rows(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, style: Style, parent: *const types.Channel, r: d.Rect, y_in: f32, top: f32, bottom: f32, only_open: bool, open_parent: Id) f32 {
    if (parent.kind != .text and parent.kind != .forum) return y_in;
    const idx = ctx.store.threadIndex(parent.id) orelse return y_in;
    const active = ctx.st.activeChannel() orelse 0;
    // Aberta mas fora do recorte (arquivada, ou além do teto): fica à vista.
    const extra: Id = if (open_parent == parent.id and std.mem.indexOfScalar(Id, idx.shown[0..idx.n_shown], active) == null) active else 0;
    if (idx.n_shown == 0 and extra == 0) return y_in;
    var y = y_in;
    const hide = only_open or ctx.st.collapsed.contains(parent.id);
    if (!only_open and idx.n_shown > 0) y = toggleRow(ctx, dl, fam, style, parent, idx, r, y, top, bottom);
    for (idx.shown[0..idx.n_shown]) |id| {
        if (hide and id != active) continue;
        y = threadRow(ctx, dl, fam, style, id, r, y, top, bottom);
    }
    if (extra != 0) y = threadRow(ctx, dl, fam, style, extra, r, y, top, bottom);
    if (!hide and idx.more > 0) y = moreRow(ctx, dl, fam, style, parent, idx, r, y, top, bottom);
    return y;
}

fn rowH(style: Style) f32 {
    return switch (style) {
        .discord => 28,
        .tree => 22,
        .pills => 32,
    };
}

/// "▾ 3 threads": recolhe as threads deste canal.
fn toggleRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, style: Style, parent: *const types.Channel, idx: *const store_mod.ThreadIndex, r: d.Rect, y: f32, top: f32, bottom: f32) f32 {
    const h: f32 = if (style == .tree) 18 else 20;
    if (y + h < top or y > bottom) return y + h;
    const collapsed = ctx.st.collapsed.contains(parent.id);
    const rr: d.Rect = .{ .x = r.x + 26, .y = y, .w = r.w - 34, .h = h };
    const hb = d.hit(ctx, hitId(parent.id, 0x71), rr);
    qa.mark(rr, "thread-toggle:{d}", .{parent.id});
    if (hb.clicked) ctx.act(.{ .toggle_category = parent.id });
    const col = if (hb.hovered) ctx.col(.text) else ctx.col(.faint).mix(ctx.col(.muted), 0.4);
    const count = @as(u32, idx.n_shown) + idx.more;
    var buf: [48]u8 = undefined;
    const lbl = if (count == 1) i18n.tr("1 thread", "1 thread") else i18n.fmt(&buf, "{d} threads", "{d} threads", .{count});
    const fs: f32 = if (style == .tree) ctx.th.font_size - 2 else 12;
    if (style == .tree) {
        var tb: [64]u8 = undefined;
        d.text(dl, fam.get(.regular), fs, r.x + 12, d.centerY(rr, fs), col, std.fmt.bufPrint(&tb, "│ {s} {s}", .{ if (collapsed) "▸" else "▾", lbl }) catch lbl);
    } else {
        icons.chevron(dl, rr.x + 6, rr.y + h / 2, col.u(), anim.to(anim.id("thread-toggle", parent.id), if (collapsed) 0 else 1, 22));
        d.text(dl, fam.get(.medium), fs, rr.x + 15, d.centerY(rr, fs), col, lbl);
    }
    // Recolhidas e com novidade: o aviso fica aqui.
    if (collapsed and idx.unread) d.circle(dl, rr.right() - 10, rr.y + h / 2, 3.5, ctx.col(.accent));
    d.tip(ctx, rr, if (collapsed) i18n.tr("Mostrar threads", "Show threads") else i18n.tr("Recolher threads", "Collapse threads"), hb.hovered);
    return y + h;
}

fn threadRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, style: Style, id: Id, r: d.Rect, y: f32, top: f32, bottom: f32) f32 {
    const row_h = rowH(style);
    if (y + row_h < top or y > bottom) return y + row_h;
    const cs = ctx.store.channel(id) orelse return y;
    const ch = &cs.info;
    const selected = ctx.st.activeChannel() == id;
    const indent: f32 = switch (style) {
        .discord => 34,
        .tree => 8,
        .pills => 30,
    };
    const rr: d.Rect = .{ .x = r.x + indent, .y = y, .w = r.w - indent - 8, .h = row_h - 2 };
    const hb = d.hit(ctx, hitId(id, 0x72), rr);
    qa.mark(rr, "channel:{d}", .{id});
    if (hb.clicked or hb.middle) ctx.act(.{ .select_channel = id });
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .channel, .id = id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
    const k = anim.to(anim.id("thread", id), if (selected) 1 else if (hb.hovered) 0.5 else 0, 24);
    // O pai trancado tranca a thread: apagada e com cadeado, clicar só avisa.
    const locked = !ctx.store.canAccess(ch);
    if (locked) {
        qa.mark(rr, "locked:{d}", .{id});
        d.tip(ctx, rr, i18n.tr("Você não tem acesso a esta thread", "You don't have access to this thread"), hb.hovered);
    }
    const muted = ctx.st.muted_channels.contains(id) or locked;
    const fs = ctx.th.font_size - 1;
    const pings = if (selected) 0 else ctx.st.filtros.count(id);
    const name_col = if (selected) ctx.col(.text) else if (muted) ctx.col(.faint) else if (hb.hovered or ch.unread) ctx.col(.text).mix(ctx.col(.muted), 0.15) else ctx.col(.muted);
    const font = fam.get(if (ch.unread and !selected) .semibold else .medium);
    switch (style) {
        .discord => {
            // Linha que liga ao pai.
            const sx = r.x + 22;
            const my = rr.y + rr.h / 2;
            d.line(dl, sx, y - 2, sx, my, ctx.col(.border).mix(ctx.col(.muted), 0.25), 1.2);
            d.line(dl, sx, my, rr.x - 2, my, ctx.col(.border).mix(ctx.col(.muted), 0.25), 1.2);
            if (k > 0.01) d.rect(dl, rr, ctx.col(.selected).alpha(k), ctx.th.radius);
            const tx = if (locked) rr.x + 22 else rr.x + 8;
            if (locked) icons.lock(dl, rr.x + 11, rr.y + rr.h / 2 - 2, ctx.col(.faint).u());
            _ = d.textClipped(dl, font, fs, tx, d.centerY(rr, fs), name_col, ch.name, rr.right() - tx - (if (pings > 0) @as(f32, 34) else 8));
            if (ch.unread and !selected) d.rectFlags(dl, .{ .x = r.x, .y = rr.y + 9, .w = 4, .h = 8 }, ctx.col(.text), 4, c.ImDrawFlags_RoundRight);
            if (pings > 0) channels.badgeAt(ctx, dl, fam, rr.right() - 6, rr.y + rr.h / 2, pings);
        },
        .pills => {
            if (k > 0.01) d.rect(dl, rr, if (selected) ctx.col(.accent) else ctx.col(.hover), rr.h / 2);
            const tc = if (selected) ctx.col(.accent_text) else name_col;
            if (locked) icons.lock(dl, rr.x + 14, rr.y + rr.h / 2 - 2, tc.u()) else icons.thread(dl, rr.x + 14, rr.y + rr.h / 2, tc.alpha(0.8).u());
            _ = d.textClipped(dl, font, fs, rr.x + 28, d.centerY(rr, fs), tc, ch.name, rr.w - 44);
            if (pings > 0) {
                channels.badgeAt(ctx, dl, fam, rr.right() - 8, rr.y + rr.h / 2, pings);
            } else if (ch.unread and !selected) d.circle(dl, rr.right() - 12, rr.y + rr.h / 2, 3.5, ctx.col(.accent));
        },
        .tree => {
            if (selected) d.rect(dl, rr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 0);
            var buf: [120]u8 = undefined;
            const t = d.printClip(&buf, "│ └ {s}{s}", .{ if (locked) "× " else "", ch.name });
            const tc = if (selected) ctx.col(.accent_text) else name_col;
            _ = d.textClipped(dl, fam.get(if (ch.unread or selected) .bold else .regular), fs, rr.x + 4, d.centerY(rr, fs), tc, t, rr.w - 24);
            if (pings > 0) {
                var pb: [12]u8 = undefined;
                const pt = std.fmt.bufPrint(&pb, "({d})", .{pings}) catch "";
                d.text(dl, fam.get(.bold), fs, rr.right() - 6 - d.width(fam.get(.bold), fs, pt), d.centerY(rr, fs), ctx.col(.danger), pt);
            } else if (ch.unread and !selected) d.text(dl, fam.get(.bold), fs, rr.right() - 14, d.centerY(rr, fs), ctx.col(.accent), "●");
        },
    }
    return y + row_h;
}

/// O que não coube no teto: abre o painel com todas as threads do canal.
fn moreRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, style: Style, parent: *const types.Channel, idx: *const store_mod.ThreadIndex, r: d.Rect, y: f32, top: f32, bottom: f32) f32 {
    const h: f32 = if (style == .tree) 18 else 22;
    if (y + h < top or y > bottom) return y + h;
    const rr: d.Rect = .{ .x = r.x + 34, .y = y, .w = r.w - 42, .h = h };
    const hb = d.hit(ctx, hitId(parent.id, 0x73), rr);
    qa.mark(rr, "thread-more:{d}", .{parent.id});
    if (hb.clicked) ctx.popup(.{ .threads = .{ .parent = parent.id } });
    var buf: [48]u8 = undefined;
    const lbl = i18n.fmt(&buf, "mais {d}…", "{d} more…", .{idx.more});
    d.text(dl, fam.get(.medium), 12, rr.x + 8, d.centerY(rr, 12), if (hb.hovered) ctx.col(.text) else ctx.col(.faint), lbl);
    return y + h;
}

// --- Cartão na mensagem ------------------------------------------------------

pub const card_w: f32 = 360;
const card_h: f32 = 58;
const card_gap: f32 = 6;

/// Thread desta mensagem, se ela ainda existe aqui.
fn threadOf(ctx: *const d.Ctx, m: *const StoredMessage) ?*store_mod.ChannelState {
    if (m.msg.thread == 0) return null;
    const cs = ctx.store.channel(m.msg.thread) orelse return null;
    return if (cs.info.thread != null) cs else null;
}

pub fn cardHeight(ctx: *const d.Ctx, m: *const StoredMessage) f32 {
    return if (threadOf(ctx, m) != null) card_h + card_gap else 0;
}

/// "há 5 min" / "5 min ago", a partir de um horário em segundos.
pub fn ago(buf: []u8, ts: i64, now_s: i64) []const u8 {
    const dt = @max(now_s - ts, 0);
    if (dt < 60) return i18n.tr("agora", "just now");
    if (dt < 3600) return i18n.fmt(buf, "há {d} min", "{d} min ago", .{@divTrunc(dt, 60)});
    if (dt < 86400) return i18n.fmt(buf, "há {d} h", "{d} h ago", .{@divTrunc(dt, 3600)});
    if (dt < 30 * 86400) return i18n.fmt(buf, "há {d} d", "{d} d ago", .{@divTrunc(dt, 86400)});
    return i18n.fmt(buf, "há {d} meses", "{d} months ago", .{@max(@divTrunc(dt, 30 * 86400), 1)});
}

/// "N mensagens · última há X".
pub fn activityLine(ctx: *const d.Ctx, buf: []u8, ch: *const types.Channel) []const u8 {
    const t = ch.thread orelse return "";
    var ab: [32]u8 = undefined;
    const when = ago(&ab, @divTrunc(types.snowflakeTime(store_mod.Store.threadActivity(ch)), 1000), @divTrunc(ctx.now_ms, 1000));
    if (t.message_count == 0) return i18n.fmt(buf, "Nenhuma mensagem · criada {s}", "No messages · created {s}", .{when});
    if (t.message_count == 1) return i18n.fmt(buf, "1 mensagem · última {s}", "1 message · last {s}", .{when});
    return i18n.fmt(buf, "{d} mensagens · última {s}", "{d} messages · last {s}", .{ t.message_count, when });
}

/// Desenha o cartão (clicar abre a thread) e devolve a altura com o espaço acima.
pub fn card(ctx: *d.Ctx, dl: *c.ImDrawList, m: *const StoredMessage, x: f32, y: f32, avail: f32) f32 {
    const cs = threadOf(ctx, m) orelse return 0;
    const ch = &cs.info;
    const rr: d.Rect = .{ .x = x, .y = y + card_gap, .w = @min(avail, card_w), .h = card_h };
    const hb = d.hitUnder(ctx, hitId(ch.id, 0x74), rr);
    qa.mark(rr, "thread-card:{d}", .{ch.id});
    if (hb.clicked) ctx.act(.{ .select_channel = ch.id });
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .channel, .id = ch.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
    const radius = @max(ctx.th.radius, 2);
    d.rect(dl, rr, if (hb.hovered) ctx.col(.hover).mix(ctx.col(.elevated), 0.4) else ctx.col(.elevated), radius);
    d.border(dl, rr, ctx.col(.border), radius, 1);
    icons.thread(dl, rr.x + 22, rr.y + rr.h / 2, ctx.col(.muted).u());
    const fam = ctx.ui;
    const dot: f32 = if (ch.unread) 18 else 0;
    _ = d.textClipped(dl, fam.get(.semibold), 14, rr.x + 42, rr.y + 10, ctx.col(.text), ch.name, rr.w - 54 - dot);
    var buf: [96]u8 = undefined;
    const info = activityLine(ctx, &buf, ch);
    _ = d.textClipped(dl, fam.get(.regular), 12.5, rr.x + 42, rr.y + 31, ctx.col(.muted), info, rr.w - 54);
    if (ch.unread) d.circle(dl, rr.right() - 14, rr.y + 19, 4, ctx.col(.accent));
    return card_h + card_gap;
}
