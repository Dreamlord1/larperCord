//! `channel-list` e `user-panel`.
//!
//! channel-list:
//!   variant = discord | tree | pills
//!   header  = mostra o nome do servidor no topo (#true)
//! user-panel:
//!   variant = discord | tty
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const Id = types.Id;

const Variant = enum { discord, tree, pills };

pub fn channelList(ctx: *d.Ctx, n: *const kdl.Node, r_in: d.Rect) void {
    const variant = std.meta.stringToEnum(Variant, d.pstr(n, "variant", "discord")) orelse .discord;
    const fam = ctx.familyFor(n);
    var r = r_in;
    if (ctx.st.guild == 0) return dmList(ctx, n, fam, variant, r);
    const g = ctx.store.guild(ctx.st.guild) orelse return;

    const banner = variant == .discord and d.pflag(n, "banner", false);
    if (d.pflag(n, "header", true)) {
        const hh: f32 = if (variant == .tree) 30 else if (banner) 128 else 48;
        const hr: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = hh };
        const hb = d.hit(ctx, 1, hr);
        qa.mark(hr, "guild-header", .{});
        if (hb.right) ctx.popup(.{ .menu = .{ .kind = .guild, .id = g.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        const k = anim.to(anim.id("ghead", @intFromPtr(n)), if (hb.hovered) 1 else 0, 20);
        if (banner) {
            // Banner do servidor: degradê com a cor dele, nome embaixo.
            const col = ctx.th.role(g.color);
            const top = col.mix(ctx.col(.sidebar), 0.25);
            const mid = col.mix(ctx.col(.sidebar), 0.7);
            c.ImDrawList_AddRectFilledMultiColor(ctx.dl, d.v(hr.x, hr.y), d.v(hr.right(), hr.bottom()), top.u(), col.mix(ctx.col(.accent), 0.4).mix(ctx.col(.sidebar), 0.3).u(), ctx.col(.sidebar).u(), mid.mix(ctx.col(.sidebar), 0.6).u());
            // Pontinhos decorativos que dão textura ao banner.
            var py = hr.y + 10;
            while (py < hr.bottom() - 30) : (py += 14) {
                var px = hr.x + 10 + @mod(py, 28) / 2;
                while (px < hr.right()) : (px += 14) d.circle(ctx.dl, px, py, 1.1, d.Rgba.white.alpha(0.08));
            }
            d.rect(ctx.dl, hr, ctx.col(.hover).alpha(k), 0);
            d.text(ctx.dl, fam.get(.bold), 17, r.x + 17, hr.bottom() - 33, d.Rgba.black.alpha(0.35), g.name);
            _ = d.textClipped(ctx.dl, fam.get(.bold), 17, r.x + 16, hr.bottom() - 34, d.Rgba.white, g.name, r.w - 56);
            icons.chevron(ctx.dl, r.right() - 24, hr.bottom() - 24, d.Rgba.white.col(0.9), 1);
        } else switch (variant) {
            .tree => {
                var buf: [96]u8 = undefined;
                const t = std.fmt.bufPrint(&buf, "┌ {s}", .{g.name}) catch g.name;
                _ = d.textClipped(ctx.dl, fam.get(.bold), ctx.th.font_size, r.x + 10, d.centerY(hr, ctx.th.font_size), ctx.col(.accent), t, r.w - 20);
            },
            else => {
                d.rect(ctx.dl, hr, ctx.col(.hover).alpha(k), if (variant == .pills) 10 else 0);
                _ = d.textClipped(ctx.dl, fam.get(.semibold), 16, r.x + 16, d.centerY(hr, 16), ctx.col(.text), g.name, r.w - 56);
                icons.chevron(ctx.dl, r.right() - 24, hr.y + hh / 2, ctx.col(.text).col(0.9), 1);
                if (variant == .discord) d.line(ctx.dl, r.x, hr.bottom() - 0.5, r.right(), hr.bottom() - 0.5, ctx.col(.border), 1);
            },
        }
        r.y += hh;
        r.h -= hh;
    }

    const dl = d.beginRegion(ctx, "##channels", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + (if (variant == .tree) @as(f32, 2) else 8);
    const ids = ctx.store.channelsOf(g.id);
    var collapsed_cat = false;
    var cat_id: Id = 0;
    for (ids, 0..) |id, idx| {
        const cs = ctx.store.channel(id) orelse continue;
        const ch = &cs.info;
        if (ch.kind == .category) {
            cat_id = id;
            collapsed_cat = ctx.st.collapsed.contains(id);
            y = category(ctx, dl, fam, variant, ch, idx, r, y, collapsed_cat);
            continue;
        }
        const selected = ctx.st.activeChannel() == id;
        const in_voice = ctx.st.voice == id;
        if (collapsed_cat and !selected and !in_voice) continue;
        const last = idx + 1 >= ids.len or (ctx.store.channel(ids[idx + 1]) orelse cs).info.kind == .category;
        y = row(ctx, dl, fam, variant, cs, idx, r, y, last);
    }
    d.endRegion(ctx, y + 12, r.x);
}

fn category(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, variant: Variant, ch: *const types.Channel, idx: usize, r: d.Rect, y_in: f32, collapsed: bool) f32 {
    var y = y_in + (if (variant == .tree) @as(f32, 6) else 14);
    const hr: d.Rect = .{ .x = r.x + 4, .y = y, .w = r.w - 8, .h = if (variant == .tree) 22 else 24 };
    const hb = d.hit(ctx, 100 + idx, hr);
    qa.mark(hr, "category:{d}", .{ch.id});
    if (hb.clicked) ctx.act(.{ .toggle_category = ch.id });
    const open = anim.to(anim.id("cat", ch.id), if (collapsed) 0 else 1, 22);
    const col = if (hb.hovered) ctx.col(.text).mix(ctx.col(.muted), 0.2) else ctx.col(.faint).mix(ctx.col(.muted), 0.4);
    switch (variant) {
        .tree => {
            var buf: [96]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{s} {s}", .{ if (collapsed) "▸" else "▾", ch.name }) catch ch.name;
            d.text(dl, fam.get(.bold), ctx.th.font_size - 1, r.x + 10, d.centerY(hr, ctx.th.font_size - 1), col, t);
        },
        .pills => d.text(dl, fam.get(.semibold), 13, r.x + 18, d.centerY(hr, 13), col, ch.name),
        .discord => {
            icons.chevron(dl, r.x + 12, hr.y + 12, col.u(), open);
            var up: [64]u8 = undefined;
            d.text(dl, fam.get(.semibold), 12, r.x + 20, hr.y + 4, col, d.upper(&up, ch.name));
        },
    }
    y += hr.h + 2;
    return y;
}

fn row(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, variant: Variant, cs: anytype, idx: usize, r: d.Rect, y: f32, last: bool) f32 {
    const ch = &cs.info;
    const selected = ch.kind == .text and ctx.st.activeChannel() == ch.id;
    const in_voice = ch.kind == .voice and ctx.st.voice == ch.id;
    const row_h: f32 = switch (variant) {
        .tree => 24,
        .pills => 40,
        .discord => 34,
    };
    const inset: f32 = if (variant == .pills) 10 else 8;
    const rr: d.Rect = .{ .x = r.x + inset, .y = y, .w = r.w - inset * 2, .h = row_h - 2 };
    const hb = d.hit(ctx, 200 + idx, rr);
    qa.mark(rr, "channel:{d}", .{ch.id});
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .channel, .id = ch.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
    if (hb.clicked or hb.middle) switch (ch.kind) {
        .text => ctx.act(.{ .select_channel = ch.id }),
        .voice => ctx.act(.{ .toggle_voice = ch.id }),
        .category => {},
    };

    const k = anim.to(anim.id("chan", ch.id), if (selected) 1 else if (hb.hovered) 0.5 else 0, 24);
    const muted_ch = ctx.st.muted_channels.contains(ch.id);
    const bright = (selected or hb.hovered or ch.unread or in_voice) and !muted_ch;
    const name_col = if (selected) ctx.col(.text) else if (bright) ctx.col(.text).mix(ctx.col(.muted), 0.15) else if (muted_ch) ctx.col(.faint) else ctx.col(.muted);
    const fs = ctx.th.font_size;

    switch (variant) {
        .discord => {
            if (k > 0.01) d.rect(dl, rr, ctx.col(.selected).alpha(k), ctx.th.radius);
            const ic = ctx.col(.faint).mix(ctx.col(.muted), if (bright) 0.5 else 0);
            switch (ch.kind) {
                .voice => icons.speaker(dl, rr.x + 18, rr.y + rr.h / 2, ic.u()),
                else => d.text(dl, fam.get(.medium), 20, rr.x + 10, rr.y + 3.5, ic, "#"),
            }
            const nf = if (ch.unread and !selected) fam.get(.semibold) else fam.get(.medium);
            _ = d.textClipped(dl, nf, fs, rr.x + 34, d.centerY(rr, fs), name_col, ch.name, rr.w - 42);
            if (ch.unread and !selected)
                d.rectFlags(dl, .{ .x = r.x, .y = rr.y + 12, .w = 4, .h = 8 }, ctx.col(.text), 4, c.ImDrawFlags_RoundRight);
        },
        .pills => {
            const pr = rr;
            if (k > 0.01) d.rect(dl, pr, if (selected) ctx.col(.accent) else ctx.col(.hover), pr.h / 2);
            const on = selected;
            const ic_bg = if (on) ctx.col(.accent_text).alpha(0.22) else ctx.col(.elevated);
            d.circle(dl, pr.x + 20, pr.y + pr.h / 2, 13, ic_bg);
            const ink = if (on) ctx.col(.accent_text) else ctx.col(.muted);
            switch (ch.kind) {
                .voice => icons.speaker(dl, pr.x + 21, pr.y + pr.h / 2, ink.u()),
                else => {
                    const hw = d.width(fam.get(.bold), 14, "#");
                    d.text(dl, fam.get(.bold), 14, pr.x + 20 - hw / 2, d.centerY(pr, 14), ink, "#");
                },
            }
            const tc = if (on) ctx.col(.accent_text) else name_col;
            _ = d.textClipped(dl, fam.get(if (ch.unread or on) .semibold else .medium), fs - 1, pr.x + 42, d.centerY(pr, fs - 1), tc, ch.name, pr.w - 60);
            if (ch.unread and !on) d.circle(dl, pr.right() - 14, pr.y + pr.h / 2, 4, ctx.col(.accent));
        },
        .tree => {
            if (selected) d.rect(dl, rr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 0);
            var buf: [96]u8 = undefined;
            const branch = if (last) "└" else "├";
            const sigil = if (ch.kind == .voice) "♪" else "#";
            const t = std.fmt.bufPrint(&buf, "{s} {s} {s}", .{ branch, sigil, ch.name }) catch ch.name;
            const tc = if (selected) ctx.col(.accent_text) else name_col;
            _ = d.textClipped(dl, fam.get(if (ch.unread or selected) .bold else .regular), fs - 1, rr.x + 4, d.centerY(rr, fs - 1), tc, t, rr.w - 24);
            if (ch.unread and !selected) d.text(dl, fam.get(.bold), fs - 1, rr.right() - 14, d.centerY(rr, fs - 1), ctx.col(.accent), "●");
        },
    }

    var y2 = y + row_h;
    if (ch.kind == .voice) {
        for (cs.voice_members.items, 0..) |uid, vi| {
            const u = ctx.store.user(uid) orelse continue;
            const speaking = vi == 1 and !ctx.st.deafened;
            switch (variant) {
                .tree => {
                    var buf: [80]u8 = undefined;
                    const t = std.fmt.bufPrint(&buf, "{s}   {s} {s}", .{ if (last) " " else "│", if (speaking) "◉" else "○", u.name }) catch u.name;
                    d.text(dl, fam.get(.regular), fs - 2, rr.x + 4, y2 + 2, if (speaking) ctx.col(.online) else ctx.col(.muted), t);
                    y2 += 20;
                },
                else => {
                    const ax = rr.x + 40;
                    const acy = y2 + 13;
                    if (speaking) c.ImDrawList_AddCircleEx(dl, d.v(ax, acy), 12.5, ctx.col(.online).u(), 0, 2, 0);
                    w.avatar(ctx, dl, ax, acy, 21, uid, .circle, null, 1);
                    d.text(dl, fam.get(.medium), 14, ax + 18, acy - 9, if (speaking) ctx.col(.text) else ctx.col(.muted), u.name);
                    y2 += 28;
                },
            }
        }
        if (cs.voice_members.items.len > 0) y2 += 4;
    }
    return y2;
}

// --- Painel do usuário ---------------------------------------------------

pub fn userPanel(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const tty = d.is(n, "variant", "tty", "discord");
    var pr = r;
    if (ctx.st.voice) |vc| {
        const vh: f32 = if (tty) 22 else 54;
        voicePanel(ctx, fam, .{ .x = r.x, .y = r.y, .w = r.w, .h = vh }, vc, tty);
        pr.y += vh;
        pr.h -= vh;
    }
    const me = ctx.store.user(ctx.store.me) orelse return;
    if (tty) {
        var buf: [96]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s} {s}", .{ w.statusGlyph(me.status), me.name }) catch "";
        d.text(ctx.dl, fam.get(.bold), ctx.th.font_size - 1, pr.x + 10, d.centerY(pr, ctx.th.font_size - 1), w.statusColor(ctx, me.status), t);
    } else {
        const card: d.Rect = .{ .x = pr.x + 6, .y = pr.y + pr.h / 2 - 18, .w = pr.w - 108, .h = 36 };
        const hb = d.hit(ctx, 1, card);
        qa.mark(card, "me", .{});
        if (hb.clicked) ctx.popup(.{ .profile = .{ .user = me.id, .x = card.x, .y = card.y - 380 } });
        d.rect(ctx.dl, card, ctx.col(.hover).alpha(anim.to(anim.id("me", 0), if (hb.hovered) 1 else 0, 24)), ctx.th.radius);
        w.avatar(ctx, ctx.dl, card.x + 20, card.y + 18, 32, me.id, .circle, ctx.col(.rail), 1);
        _ = d.textClipped(ctx.dl, fam.get(.semibold), 14, card.x + 44, card.y + 2, ctx.col(.text), me.name, card.w - 48);
        _ = d.textClipped(ctx.dl, fam.get(.regular), 12, card.x + 44, card.y + 19, ctx.col(.muted), "Online", card.w - 48);
    }

    // Mudo, ensurdecer, configurações.
    const bs: f32 = if (tty) 22 else 32;
    for (0..3) |i| {
        const bx = pr.right() - 8 - @as(f32, @floatFromInt(3 - i)) * bs;
        const br: d.Rect = .{ .x = bx, .y = pr.y + pr.h / 2 - bs / 2, .w = bs, .h = bs };
        const hb = d.hit(ctx, 10 + i, br);
        qa.mark(br, "user-btn:{d}", .{i});
        d.tip(ctx, br, switch (i) {
            0 => if (ctx.st.muted) i18n.tr("Desmutar", "Unmute") else i18n.tr("Mutar microfone", "Mute"),
            1 => if (ctx.st.deafened) i18n.tr("Voltar a ouvir", "Undeafen") else i18n.tr("Ensurdecer", "Deafen"),
            else => i18n.tr("Configurações  (Ctrl+,)", "User Settings  (Ctrl+,)"),
        }, hb.hovered);
        const active = (i == 0 and ctx.st.muted) or (i == 1 and ctx.st.deafened);
        if (hb.clicked) switch (i) {
            0 => ctx.act(.toggle_mute),
            1 => ctx.act(.toggle_deafen),
            else => ctx.act(.open_settings),
        };
        const k = anim.to(anim.id("ubtn", i), if (hb.hovered) 1 else 0, 24);
        const ink = if (active) ctx.col(.danger) else ctx.col(.muted).mix(ctx.col(.text), k);
        if (tty) {
            const glyph = switch (i) {
                0 => if (ctx.st.muted) "M̶" else "M",
                1 => if (ctx.st.deafened) "F̶" else "F",
                else => "⚙",
            };
            if (hb.hovered) d.rect(ctx.dl, br, ctx.col(.hover), 0);
            const gw = d.width(fam.get(.bold), ctx.th.font_size - 1, glyph);
            d.text(ctx.dl, fam.get(.bold), ctx.th.font_size - 1, br.x + bs / 2 - gw / 2, d.centerY(br, ctx.th.font_size - 1), ink, glyph);
            continue;
        }
        d.rect(ctx.dl, br, ctx.col(.hover).alpha(k * 1.5), ctx.th.radius);
        const cx = br.x + bs / 2;
        const cy = br.y + bs / 2;
        switch (i) {
            0 => icons.mic(ctx.dl, cx, cy, ink.u()),
            1 => icons.headset(ctx.dl, cx, cy, ink.u()),
            else => icons.gear(ctx.dl, cx, cy, ink.u()),
        }
        if (active) d.line(ctx.dl, cx - 9, cy - 9, cx + 9, cy + 9, ctx.col(.danger), 2.2);
    }
}

fn voicePanel(ctx: *d.Ctx, fam: *d.Family, r: d.Rect, vc: Id, tty: bool) void {
    const cs = ctx.store.channel(vc) orelse return;
    const g = ctx.store.guild(cs.info.guild);
    var buf: [128]u8 = undefined;
    if (tty) {
        const t = i18n.fmt(&buf, "♪ {s}  [sair]", "♪ {s}  [leave]", .{cs.info.name});
        d.text(ctx.dl, fam.get(.bold), ctx.th.font_size - 2, r.x + 10, d.centerY(r, ctx.th.font_size - 2), ctx.col(.online), t);
        const hb = d.hit(ctx, 50, r);
        qa.mark(r, "hangup", .{});
        if (hb.clicked) ctx.act(.leave_voice);
        return;
    }
    d.line(ctx.dl, r.x + 8, r.bottom() - 0.5, r.right() - 8, r.bottom() - 0.5, ctx.col(.border), 1);
    d.text(ctx.dl, fam.get(.semibold), 14, r.x + 14, r.y + 9, ctx.col(.online), i18n.tr("Voz conectada", "Voice Connected"));
    const sub = std.fmt.bufPrint(&buf, "{s} / {s}", .{ cs.info.name, if (g) |x| x.name else "" }) catch "";
    _ = d.textClipped(ctx.dl, fam.get(.regular), 13, r.x + 14, r.y + 29, ctx.col(.muted), sub, r.w - 70);
    const br: d.Rect = .{ .x = r.right() - 44, .y = r.y + 11, .w = 32, .h = 32 };
    const hb = d.hit(ctx, 51, br);
    qa.mark(br, "hangup", .{});
    const k = anim.to(anim.id("hangup", 0), if (hb.hovered) 1 else 0, 24);
    d.rect(ctx.dl, br, ctx.col(.hover).alpha(k * 1.5), ctx.th.radius);
    const cx = br.x + 16;
    const cy = br.y + 16;
    const ink = ctx.col(.muted).mix(ctx.col(.danger), k);
    d.line(ctx.dl, cx - 5, cy - 5, cx + 5, cy + 5, ink, 2.2);
    d.line(ctx.dl, cx + 5, cy - 5, cx - 5, cy + 5, ink, 2.2);
    if (hb.clicked) ctx.act(.leave_voice);
}

// --- Mensagens diretas ------------------------------------------------------

fn dmList(ctx: *d.Ctx, n: *const kdl.Node, fam: *d.Family, variant: Variant, r_in: d.Rect) void {
    var r = r_in;
    const tree = variant == .tree;
    const fs = ctx.th.font_size;
    if (d.pflag(n, "header", true)) {
        const hh: f32 = if (tree) 30 else 48;
        const hr: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = hh };
        if (tree) {
            d.text(ctx.dl, fam.get(.bold), fs, r.x + 10, d.centerY(hr, fs), ctx.col(.accent), i18n.tr("┌ mensagens diretas", "┌ direct messages"));
        } else {
            // Caixa "Encontre ou comece uma conversa" (abre a paleta).
            const sr = hr.inset(10, 10);
            const hb = d.hit(ctx, 1, sr);
            qa.mark(sr, "dm-search", .{});
            if (hb.clicked) ctx.act(.open_palette);
            d.rect(ctx.dl, sr, ctx.col(.rail).mix(ctx.col(.sidebar), if (hb.hovered) 0.1 else 0.4), @max(ctx.th.radius - 2, 2));
            d.text(ctx.dl, fam.get(.medium), 13, sr.x + 8, d.centerY(sr, 13), ctx.col(.faint), i18n.tr("Encontre ou comece uma conversa", "Find or start a conversation"));
            if (variant == .discord) d.line(ctx.dl, r.x, hr.bottom() - 0.5, r.right(), hr.bottom() - 0.5, ctx.col(.border), 1);
        }
        r.y += hh;
        r.h -= hh;
    }
    const dl = d.beginRegion(ctx, "##dms", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 10;
    if (!tree) {
        d.text(dl, fam.get(.semibold), 12, r.x + 18, y + 4, ctx.col(.faint).mix(ctx.col(.muted), 0.4), i18n.tr("MENSAGENS DIRETAS", "DIRECT MESSAGES"));
        y += 28;
    }
    for (ctx.store.channelsOf(0), 0..) |id, idx| {
        const cs = ctx.store.channel(id) orelse continue;
        const u = ctx.store.user(cs.info.recipient) orelse continue;
        const selected = ctx.st.activeChannel() == id;
        const row_h: f32 = if (tree) 24 else 44;
        const rr: d.Rect = .{ .x = r.x + 8, .y = y, .w = r.w - 16, .h = row_h - 2 };
        const hb = d.hit(ctx, 300 + idx, rr);
        qa.mark(rr, "channel:{d}", .{id});
        if (hb.clicked or hb.middle) ctx.act(.{ .select_channel = id });
        if (hb.right) ctx.popup(.{ .menu = .{ .kind = .user, .id = u.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        const k = anim.to(anim.id("dm", id), if (selected) 1 else if (hb.hovered) 0.5 else 0, 24);
        const name_col = if (selected or cs.info.unread) ctx.col(.text) else ctx.col(.muted).mix(ctx.col(.text), k * 0.5);
        if (tree) {
            if (selected) d.rect(dl, rr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 0);
            var buf: [80]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{s} {s} @{s}", .{ if (idx + 1 == ctx.store.channelsOf(0).len) "└" else "├", w.statusGlyph(u.status), u.name }) catch u.name;
            d.text(dl, fam.get(if (cs.info.unread) .bold else .regular), fs - 1, rr.x + 4, d.centerY(rr, fs - 1), if (selected) ctx.col(.accent_text) else name_col, t);
        } else {
            const radius = if (variant == .pills) rr.h / 2 else ctx.th.radius;
            if (k > 0.01) d.rect(dl, rr, if (variant == .pills and selected) ctx.col(.accent) else ctx.col(.selected).alpha(k), radius);
            const on = variant == .pills and selected;
            w.avatar(ctx, dl, rr.x + 22, rr.y + rr.h / 2, 32, u.id, .circle, if (on) ctx.col(.accent) else ctx.col(.sidebar), 1);
            const tc = if (on) ctx.col(.accent_text) else name_col;
            if (u.activity) |a| {
                _ = d.textClipped(dl, fam.get(if (cs.info.unread) .semibold else .medium), fs - 1, rr.x + 46, rr.y + 3, tc, u.name, rr.w - 60);
                _ = d.textClipped(dl, fam.get(.regular), 12, rr.x + 46, rr.y + 22, if (on) tc.alpha(0.8) else ctx.col(.faint), a, rr.w - 60);
            } else _ = d.textClipped(dl, fam.get(if (cs.info.unread) .semibold else .medium), fs - 1, rr.x + 46, d.centerY(rr, fs - 1), tc, u.name, rr.w - 60);
            if (cs.info.unread and !selected) d.circle(dl, rr.right() - 12, rr.y + rr.h / 2, 4, ctx.col(.danger));
        }
        y += row_h;
    }
    d.endRegion(ctx, y + 12, r.x);
}
