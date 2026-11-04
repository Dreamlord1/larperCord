//! Componentes do topo do chat: `header` e `tabs`.
//! (mensagens e caixa de texto ficam em comp_messages.zig)
//!
//! header:   variant = discord | minimal | tty
//! tabs:     variant = pills | underline | tty
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

// --- header -----------------------------------------------------------------

pub fn header(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    if (ctx.st.friends) return @import("comp_friends.zig").header(ctx, n, r);
    const fam = ctx.familyFor(n);
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const ch = &cs.info;
    const variant = d.pstr(n, "variant", "discord");
    const dl = ctx.dl;

    if (std.mem.eql(u8, variant, "tty")) {
        var buf: [160]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "─ {s}{s} ─ {s} ", .{ sigil(ch), ch.name, ch.topic }) catch ch.name;
        const fs = ctx.th.font_size - 1;
        const tw = d.textClipped(dl, fam.get(.bold), fs, r.x + 6, d.centerY(r, fs), ctx.col(.accent), t, r.w - 12);
        const ly = r.y + r.h / 2;
        d.line(dl, r.x + 6 + tw + 4, ly, r.right() - 6, ly, ctx.col(.border), 1);
        return;
    }
    if (std.mem.eql(u8, variant, "minimal")) {
        const g = ctx.store.guild(ch.guild);
        var buf: [128]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s}", .{ch.name}) catch "";
        d.text(dl, fam.get(.bold), 22, r.x + 4, r.y + r.h / 2 - 22, ctx.col(.text), t);
        const sub = if (ch.guild == 0) i18n.tr("mensagem direta", "direct message") else std.fmt.bufPrint(&buf, "{s}  ·  {s}", .{ if (g) |x| x.name else "", ch.topic }) catch "";
        _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 4, r.y + r.h / 2 + 5, ctx.col(.faint), sub, r.w - 8);
        return;
    }

    d.text(dl, fam.get(.medium), 22, r.x + 17, d.centerY(r, 22), ctx.col(.faint), sigil(ch));
    d.text(dl, fam.get(.semibold), 16, r.x + 42, d.centerY(r, 16), ctx.col(.text), ch.name);
    const name_w = d.width(fam.get(.semibold), 16, ch.name);
    const search_w: f32 = 180;
    const sx = r.right() - 16 - search_w;
    const tx = r.x + 42 + name_w + 14;
    if (ch.topic.len > 0 and sx - tx > 120) {
        d.rect(dl, .{ .x = tx, .y = r.y + r.h / 2 - 10, .w = 1, .h = 20 }, ctx.col(.border).mix(ctx.col(.text), 0.05), 0);
        _ = d.textClipped(dl, fam.get(.regular), 14, tx + 14, d.centerY(r, 14), ctx.col(.muted), ch.topic, sx - tx - 106);
    }
    const sr: d.Rect = .{ .x = sx, .y = r.y + r.h / 2 - 13, .w = search_w, .h = 26 };
    const sh = d.hit(ctx, 1, sr);
    qa.mark(sr, "header-search", .{});
    if (sh.clicked) ctx.act(.open_palette);
    d.tip(ctx, sr, i18n.tr("Buscar canais, servidores e ações", "Search channels, servers and actions"), sh.hovered);
    const sk = anim.to(anim.id("search", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
    d.rect(dl, sr, ctx.col(.rail).mix(ctx.col(.sidebar), 0.3 + 0.3 * sk), ctx.th.radius);
    d.text(dl, fam.get(.regular), 14, sr.x + 9, d.centerY(sr, 14), ctx.col(.faint).mix(ctx.col(.muted), sk), i18n.tr("Buscar  Ctrl+K", "Search  Ctrl+K"));
    icons.search(dl, sr.right() - 15, sr.y + 13, ctx.col(.faint).mix(ctx.col(.muted), sk).u());
    // Busca nas mensagens (local, também offline): Ctrl+F.
    const fr: d.Rect = .{ .x = sx - 76, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
    const fh = d.hit(ctx, 3, fr);
    qa.mark(fr, "header-find", .{});
    if (fh.clicked) @import("search.zig").start();
    icons.search(dl, fr.x + 14, fr.y + 14, (if (fh.hovered) ctx.col(.text) else ctx.col(.muted)).u());
    d.tip(ctx, fr, i18n.tr("Buscar mensagens (Ctrl+F)", "Search messages (Ctrl+F)"), fh.hovered);
    const mr: d.Rect = .{ .x = sx - 40, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
    const mh = d.hit(ctx, 2, mr);
    qa.mark(mr, "header-members", .{});
    if (mh.clicked) ctx.st.settings.show_member_list = !ctx.st.settings.show_member_list;
    icons.members(dl, mr.x + 14, mr.y + 14, (if (ctx.st.settings.show_member_list or mh.hovered) ctx.col(.text) else ctx.col(.muted)).u());
    d.tip(ctx, mr, if (ctx.st.settings.show_member_list) i18n.tr("Esconder membros", "Hide Member List") else i18n.tr("Mostrar membros", "Show Member List"), mh.hovered);
    if (d.pflag(n, "divider", true)) d.line(dl, r.x, r.bottom() - 0.5, r.right(), r.bottom() - 0.5, ctx.col(.border), 1);
}

// --- tabs -------------------------------------------------------------------

pub fn tabs(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "pills");
    const tty = std.mem.eql(u8, variant, "tty");
    const underline = std.mem.eql(u8, variant, "underline");
    const dl = ctx.dl;
    const fs: f32 = if (tty) ctx.th.font_size - 1 else 14;
    var x = r.x + (if (tty) @as(f32, 4) else 8);
    var buf: [96]u8 = undefined;

    for (ctx.st.tabs.items, 0..) |id, i| {
        const cs = ctx.store.channel(id) orelse continue;
        const g = ctx.store.guild(cs.info.guild);
        const active = i == ctx.st.tab;
        const lbl = if (tty)
            std.fmt.bufPrint(&buf, " {d}:{s}{s} ", .{ i + 1, sigil(&cs.info), cs.info.name }) catch continue
        else
            std.fmt.bufPrint(&buf, "{s}{s}", .{ sigil(&cs.info), cs.info.name }) catch continue;
        const font = fam.get(if (active) .semibold else .medium);
        const tw = d.width(font, fs, lbl);
        const acr = if (g) |x_| x_.acronym else "DM";
        const acr_w = if (tty) 0 else d.width(fam.get(.bold), 10, acr) + 10;
        const tab_w = if (tty) tw else tw + acr_w + 40;
        if (x + tab_w > r.right() - 40) break;
        const h: f32 = if (tty) r.h else r.h - 10;
        const tr: d.Rect = .{ .x = x, .y = r.y + (r.h - h) / 2, .w = tab_w, .h = h };
        const hb = d.hit(ctx, i, tr);
        qa.mark(tr, "tab:{d}", .{i});
        if (hb.clicked) ctx.act(.{ .focus_tab = i });
        if (hb.middle) ctx.act(.{ .close_tab = i });
        const k = anim.to(anim.id("tab", id), if (active) 1 else if (hb.hovered) 0.4 else 0, 20);

        if (tty) {
            if (active) d.rect(dl, tr, ctx.col(.accent), 0) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), 0);
            d.text(dl, font, fs, x, d.centerY(tr, fs), if (active) ctx.col(.accent_text) else if (cs.info.unread) ctx.col(.text) else ctx.col(.muted), lbl);
            x += tab_w + 2;
            continue;
        }
        if (underline) {
            d.rect(dl, tr, ctx.col(.hover).alpha(k * 0.6), ctx.th.radius);
            if (k > 0.5) d.rect(dl, .{ .x = tr.x + 10, .y = r.bottom() - 2, .w = tr.w - 20, .h = 2 }, ctx.col(.accent).alpha((k - 0.5) * 2), 1);
        } else {
            d.rect(dl, tr, ctx.col(.selected).alpha(k), tr.h / 2);
            if (active) d.border(dl, tr, ctx.col(.accent).alpha(0.45), tr.h / 2, 1);
        }
        // Sigla do servidor + nome do canal.
        const ar: d.Rect = .{ .x = tr.x + 8, .y = tr.y + tr.h / 2 - 9, .w = acr_w, .h = 18 };
        d.rect(dl, ar, (if (g) |gg| ctx.th.role(gg.color) else ctx.col(.accent)).alpha(0.75), 5);
        d.text(dl, fam.get(.bold), 10, ar.x + 5, d.centerY(ar, 10), d.Rgba.white, acr);
        const tc = if (active) ctx.col(.text) else if (cs.info.unread) ctx.col(.text).mix(ctx.col(.muted), 0.2) else ctx.col(.muted);
        d.text(dl, font, fs, ar.right() + 6, d.centerY(tr, fs), tc, lbl);
        // Fechar.
        if (ctx.st.tabs.items.len > 1 and (hb.hovered or active)) {
            const cx = tr.right() - 14;
            const cy = tr.y + tr.h / 2;
            const cr: d.Rect = .{ .x = cx - 8, .y = cy - 8, .w = 16, .h = 16 };
            const over = ctx.hovering(cr);
            if (over) d.circle(dl, cx, cy, 8, ctx.col(.hover).mix(ctx.col(.text), 0.1));
            const xc = if (over) ctx.col(.text) else ctx.col(.faint);
            d.line(dl, cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5, xc, 1.5);
            d.line(dl, cx + 3.5, cy - 3.5, cx - 3.5, cy + 3.5, xc, 1.5);
            if (over and c.ImGui_IsMouseClicked(0)) ctx.act(.{ .close_tab = i });
        }
        x += tab_w + 6;
    }
    // Nova aba (abre a paleta).
    const pr: d.Rect = .{ .x = x, .y = r.y + r.h / 2 - 12, .w = 24, .h = 24 };
    const ph = d.hit(ctx, 999, pr);
    qa.mark(pr, "tab-plus", .{});
    if (ph.clicked) ctx.act(.open_palette);
    d.tip(ctx, pr, i18n.tr("Abrir canal em nova aba", "Open channel in a new tab"), ph.hovered);
    const pk = anim.to(anim.id("tab-plus", @intFromPtr(n)), if (ph.hovered) 1 else 0, 20);
    if (tty) {
        d.text(dl, fam.get(.bold), fs, pr.x + 4, d.centerY(pr, fs), ctx.col(.muted).mix(ctx.col(.text), pk), "+");
    } else {
        d.circle(dl, pr.x + 12, pr.y + 12, 12, ctx.col(.hover).alpha(pk * 2));
        icons.plus(dl, pr.x + 12, pr.y + 12, 5, ctx.col(.muted).mix(ctx.col(.text), pk).u());
    }
}

pub fn sigil(ch: *const types.Channel) []const u8 {
    return if (ch.guild == 0) "@" else "#";
}
