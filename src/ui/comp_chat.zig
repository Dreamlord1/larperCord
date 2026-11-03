//! Componentes do chat: `header`, `tabs`, `messages` e `composer`.
//!
//! header:   variant = discord | minimal | tty
//! tabs:     variant = pills | underline | tty
//! messages: variant = cozy | irc | bubbles
//!           avatar = circle | squircle | square | none, avatar-size = 40
//!           spacing = espaço entre grupos (16)
//! composer: variant = box | pill | prompt, typing = mostra "digitando…" (#true)
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const rich = @import("rich.zig");
const icons = @import("icons.zig");
const store_mod = @import("../core/store.zig");
const types = @import("../core/types.zig");
const Id = types.Id;

// --- header -----------------------------------------------------------------

pub fn header(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const ch = &cs.info;
    const variant = d.pstr(n, "variant", "discord");
    const dl = ctx.dl;

    if (std.mem.eql(u8, variant, "tty")) {
        var buf: [160]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "─ #{s} ─ {s} ", .{ ch.name, ch.topic }) catch ch.name;
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
        const sub = std.fmt.bufPrint(&buf, "{s}  ·  {s}", .{ if (g) |x| x.name else "", ch.topic }) catch "";
        _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 4, r.y + r.h / 2 + 5, ctx.col(.faint), sub, r.w - 8);
        return;
    }

    d.text(dl, fam.get(.medium), 22, r.x + 17, d.centerY(r, 22), ctx.col(.faint), "#");
    d.text(dl, fam.get(.semibold), 16, r.x + 42, d.centerY(r, 16), ctx.col(.text), ch.name);
    const name_w = d.width(fam.get(.semibold), 16, ch.name);
    const search_w: f32 = 180;
    const sx = r.right() - 16 - search_w;
    const tx = r.x + 42 + name_w + 14;
    if (ch.topic.len > 0 and sx - tx > 80) {
        d.rect(dl, .{ .x = tx, .y = r.y + r.h / 2 - 10, .w = 1, .h = 20 }, ctx.col(.border).mix(ctx.col(.text), 0.05), 0);
        _ = d.textClipped(dl, fam.get(.regular), 14, tx + 14, d.centerY(r, 14), ctx.col(.muted), ch.topic, sx - tx - 70);
    }
    const sr: d.Rect = .{ .x = sx, .y = r.y + r.h / 2 - 13, .w = search_w, .h = 26 };
    const sh = d.hit(ctx, 1, sr);
    if (sh.clicked) ctx.act(.open_palette);
    const sk = anim.to(anim.id("search", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
    d.rect(dl, sr, ctx.col(.rail).mix(ctx.col(.sidebar), 0.3 + 0.3 * sk), ctx.th.radius);
    d.text(dl, fam.get(.regular), 14, sr.x + 9, d.centerY(sr, 14), ctx.col(.faint).mix(ctx.col(.muted), sk), "Buscar  Ctrl+K");
    icons.search(dl, sr.right() - 15, sr.y + 13, ctx.col(.faint).mix(ctx.col(.muted), sk).u());
    icons.members(dl, sx - 26, r.y + r.h / 2, ctx.col(.muted).u());
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
            std.fmt.bufPrint(&buf, " {d}:#{s} ", .{ i + 1, cs.info.name }) catch continue
        else
            std.fmt.bufPrint(&buf, "#{s}", .{cs.info.name}) catch continue;
        const font = fam.get(if (active) .semibold else .medium);
        const tw = d.width(font, fs, lbl);
        const acr = if (g) |x_| x_.acronym else "";
        const acr_w = if (tty) 0 else d.width(fam.get(.bold), 10, acr) + 10;
        const tab_w = if (tty) tw else tw + acr_w + 40;
        if (x + tab_w > r.right() - 40) break;
        const h: f32 = if (tty) r.h else r.h - 10;
        const tr: d.Rect = .{ .x = x, .y = r.y + (r.h - h) / 2, .w = tab_w, .h = h };
        const hb = d.hit(ctx, i, tr);
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
        if (g) |gg| d.rect(dl, ar, ctx.th.role(gg.color).alpha(0.75), 5);
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
    if (ph.clicked) ctx.act(.open_palette);
    const pk = anim.to(anim.id("tab-plus", @intFromPtr(n)), if (ph.hovered) 1 else 0, 20);
    if (tty) {
        d.text(dl, fam.get(.bold), fs, pr.x + 4, d.centerY(pr, fs), ctx.col(.muted).mix(ctx.col(.text), pk), "+");
    } else {
        d.circle(dl, pr.x + 12, pr.y + 12, 12, ctx.col(.hover).alpha(pk * 2));
        icons.plus(dl, pr.x + 12, pr.y + 12, 5, ctx.col(.muted).mix(ctx.col(.text), pk).u());
    }
}

// --- messages ---------------------------------------------------------------

const Variant = enum(u2) { cozy, irc, bubbles };

const Geo = struct {
    variant: Variant,
    fam: *d.Family,
    size: f32,
    line_h: f32,
    avatar: f32,
    shape: w.Shape,
    spacing: f32,
    content_x: f32,
    wrap: f32,
    prefix_w: f32 = 0,
    bubble_max: f32 = 0,
};

const flag_group: u8 = 1;
const flag_day: u8 = 2;

fn geometry(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) Geo {
    const variant = std.meta.stringToEnum(Variant, d.pstr(n, "variant", "cozy")) orelse .cozy;
    const fam = ctx.familyFor(n);
    const size = d.pnum(n, "font-size", ctx.th.font_size);
    const avatar_s = d.pstr(n, "avatar", "circle");
    const no_avatar = std.mem.eql(u8, avatar_s, "none");
    const set = &ctx.st.settings;
    var av: f32 = if (no_avatar or !set.show_avatars) 0 else d.pnum(n, "avatar-size", if (variant == .bubbles) 30 else 40);
    if (set.compact) av = @round(av * 0.6);
    var g: Geo = .{
        .variant = variant,
        .fam = fam,
        .size = size,
        .line_h = @round(size * 1.375),
        .avatar = av,
        .shape = w.shapeOf(avatar_s),
        .spacing = d.pnum(n, "spacing", 16) * (if (set.compact) @as(f32, 0.35) else 1),
        .content_x = 0,
        .wrap = 0,
    };
    switch (variant) {
        .cozy => {
            g.content_x = 16 + (if (av > 0) av + 16 else 0);
            g.wrap = r.w - g.content_x - 40;
        },
        .irc => {
            g.prefix_w = d.width(fam.get(.regular), size, "[00:00] ") + d.width(fam.get(.bold), size, "thiaguinho") + d.width(fam.get(.regular), size, " │ ");
            g.content_x = 10 + g.prefix_w;
            g.wrap = r.w - g.content_x - 20;
            g.line_h = @round(size * 1.3);
        },
        .bubbles => {
            g.bubble_max = @min(r.w * 0.66, 600);
            g.wrap = g.bubble_max - 28;
            g.content_x = 0;
        },
    }
    return g;
}

fn textOpts(ctx: *const d.Ctx, g: Geo, self_bubble: bool) rich.Opts {
    return .{
        .family = g.fam,
        .size = g.size,
        .line_h = g.line_h,
        .color = if (self_bubble) ctx.col(.bubble_self_text) else ctx.col(.text).mix(ctx.col(.muted), 0.12),
        .on_accent = self_bubble,
        .reveal_spoilers = ctx.st.settings.show_spoilers,
        .underline_links = ctx.st.settings.underline_links,
    };
}

fn measure(ctx: *d.Ctx, g: Geo, m: *store_mod.StoredMessage, flags: u8) f32 {
    const key: u32 = @as(u32, @intFromEnum(g.variant)) | (@as(u32, ctx.st.theme_gen) << 2) | (@as(u32, flags) << 10);
    if (m.layout_w == g.wrap and m.layout_variant == key) return m.height;
    const self = m.msg.author == ctx.store.me;
    const t = rich.layout(null, ctx.store, ctx.th, m.spans, 0, 0, g.wrap, textOpts(ctx, g, self and g.variant == .bubbles), ctx.mouse);
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    var h: f32 = 0;
    switch (g.variant) {
        .cozy => {
            if (day) h += 46;
            h += if (group) g.spacing + g.line_h else 1;
            h += t.h + 1;
            if (group and g.avatar > g.line_h + t.h) h = h - (g.line_h + t.h) + g.avatar;
        },
        .irc => {
            if (day) h += g.line_h + 10;
            if (group) h += 4;
            h += t.h;
        },
        .bubbles => {
            if (day) h += 46;
            h += if (group) g.spacing + (if (self) @as(f32, 0) else 18) else 3;
            h += t.h + 14;
        },
    }
    m.layout_w = g.wrap;
    m.layout_variant = key;
    m.height = h;
    m.natural_w = t.w;
    return h;
}

pub fn messages(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const g = geometry(ctx, n, r);

    if (cs.history != .loaded) return skeleton(ctx, g, r);

    // Grupos e quebras de dia, depois alturas e posições.
    const msgs = cs.messages.items;
    const st = ctx.st;
    st.offsets.resize(st.gpa, msgs.len) catch return;
    st.groups.resize(st.gpa, msgs.len) catch return;
    var total: f32 = 8;
    for (msgs, 0..) |*m, i| {
        var flags: u8 = 0;
        if (i == 0) {
            flags = flag_group | flag_day;
        } else {
            const prev = &msgs[i - 1].msg;
            if (w.localTime(prev.timestamp).day_index != w.localTime(m.msg.timestamp).day_index) flags |= flag_day | flag_group;
            if (prev.author != m.msg.author or m.msg.timestamp - prev.timestamp > 420) flags |= flag_group;
        }
        st.groups.items[i] = flags;
        st.offsets.items[i] = total;
        total += measure(ctx, g, m, flags);
    }
    total += 16;

    const sc = st.scrollOf(ch_id);
    const max_scroll = @max(0, total - r.h);
    const hovered = ctx.hovering(r);
    if (sc.pos < 0 or sc.stick_bottom) {
        sc.target = max_scroll;
        if (sc.pos < 0) sc.pos = max_scroll;
    }
    if (hovered and ctx.io.*.MouseWheel != 0) sc.target -= ctx.io.*.MouseWheel * 120;
    sc.target = std.math.clamp(sc.target, 0, max_scroll);
    sc.stick_bottom = sc.target >= max_scroll - 1;
    sc.pos = anim.step(sc.pos, sc.target, 18);

    c.ImGui_SetNextWindowScroll(d.v(-1, sc.pos));
    const dl = d.beginRegion(ctx, "##messages", r, c.ImGuiWindowFlags_NoScrollWithMouse);
    const s = c.ImGui_GetScrollY();
    if (@abs(s - sc.pos) > 1 and c.ImGui_IsMouseDown(0) and ctx.mouse.x >= r.right() - 14) {
        sc.pos = s;
        sc.target = s;
        sc.stick_bottom = s >= max_scroll - 1;
    }
    c.ImGui_Dummy(d.v(r.w - 12, total));

    const base = r.y - s + @max(0, r.h - total);
    // Busca binária pelo primeiro visível.
    var lo: usize = 0;
    var hi: usize = msgs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (st.offsets.items[mid] + msgs[mid].height < s) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i < msgs.len) : (i += 1) {
        const oy = st.offsets.items[i];
        if (oy > s + r.h) break;
        drawMessage(ctx, dl, g, &msgs[i], st.groups.items[i], r, base + oy, hovered);
    }
    c.ImGui_EndChild();

    // Voltar para o fim.
    if (!sc.stick_bottom) {
        const br: d.Rect = .{ .x = r.right() - 52, .y = r.bottom() - 52, .w = 36, .h = 36 };
        const hb = d.hit(ctx, 77, br);
        d.shadow(ctx.fg, br, 18, 8, ctx.col(.shadow));
        d.circle(ctx.fg, br.x + 18, br.y + 18, 18, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated));
        const ink = if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text);
        icons.chevron(ctx.fg, br.x + 18, br.y + 19, ink.u(), 1);
        if (hb.clicked) {
            sc.stick_bottom = true;
            sc.target = max_scroll;
        }
    }
}

fn skeleton(ctx: *d.Ctx, g: Geo, r: d.Rect) void {
    anim.active = true;
    const phase = @as(f32, @floatFromInt(@mod(ctx.now_ms, 1400))) / 1400.0;
    var y = r.bottom() - 40;
    var k: usize = 0;
    while (y > r.y + 20) : (k += 1) {
        const pulse = 0.05 + 0.04 * @sin((phase + @as(f32, @floatFromInt(k)) * 0.12) * std.math.tau);
        const col = ctx.col(.text).alpha(pulse);
        const wfrac = 0.35 + @as(f32, @floatFromInt((k * 37) % 50)) / 100.0;
        const x0 = r.x + (if (g.variant == .bubbles) @as(f32, 20) else 16);
        if (g.avatar > 0 and g.variant == .cozy) d.circle(ctx.dl, x0 + g.avatar / 2, y - 6, g.avatar / 2, col);
        const tx = x0 + (if (g.variant == .cozy and g.avatar > 0) g.avatar + 16 else 0);
        d.rect(ctx.dl, .{ .x = tx, .y = y - 18, .w = 90, .h = 10 }, col, 5);
        d.rect(ctx.dl, .{ .x = tx, .y = y - 2, .w = (r.w - tx + r.x - 60) * wfrac, .h = 10 }, col, 5);
        y -= 62;
    }
}

fn drawMessage(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *store_mod.StoredMessage, flags: u8, r: d.Rect, y_in: f32, region_hovered: bool) void {
    var y = y_in;
    var buf: [96]u8 = undefined;
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    const u = ctx.store.user(m.msg.author);
    const name = if (u) |x| x.name else "?";
    const role_col = if (ctx.st.settings.role_colors) ctx.th.role(if (u) |x| x.role else 0).mix(ctx.col(.text), 0.2) else ctx.col(.text);
    const alpha: f32 = if (m.pending) 0.5 else 1;
    const fam = g.fam;
    const self = m.msg.author == ctx.store.me;

    switch (g.variant) {
        .cozy => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
                y += 46;
            }
            const row_h = m.height - (if (day) @as(f32, 46) else 0);
            const hov = region_hovered and ctx.hovering(.{ .x = r.x, .y = y, .w = r.w, .h = row_h });
            if (hov) d.rect(dl, .{ .x = r.x, .y = y, .w = r.w, .h = row_h }, d.Rgba.black.alpha(0.07), 0);
            if (hov and ctx.st.settings.developer_mode) {
                const idt = std.fmt.bufPrint(&buf, "id {d}", .{m.msg.id}) catch "";
                const iw = d.width(fam.get(.regular), 11, idt);
                d.text(dl, fam.get(.regular), 11, r.right() - iw - 14, y + 3, ctx.col(.faint), idt);
            }
            const tx = r.x + g.content_x;
            if (group) {
                y += g.spacing;
                if (g.avatar > 0) w.avatar(ctx, dl, r.x + 16 + g.avatar / 2, y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
                d.text(dl, fam.get(.semibold), g.size, tx, y + (g.line_h - g.size * 1.2) / 2, role_col.alpha(alpha), name);
                const nw = d.width(fam.get(.semibold), g.size, name);
                const st = w.stamp(&buf, m.msg.timestamp, @divTrunc(ctx.now_ms, 1000));
                d.text(dl, fam.get(.medium), 12, tx + nw + 8, y + (g.line_h - 12 * 1.2) / 2 + 1, ctx.col(.faint), st);
                y += g.line_h;
            } else {
                y += 1;
                if (hov and g.avatar > 0) {
                    const st = w.clock(&buf, m.msg.timestamp);
                    const sw = d.width(fam.get(.medium), 11, st);
                    d.text(dl, fam.get(.medium), 11, r.x + 16 + g.avatar / 2 - sw / 2, y + 5, ctx.col(.faint), st);
                }
            }
            var o = textOpts(ctx, g, false);
            o.color = o.color.alpha(alpha);
            _ = rich.layout(dl, ctx.store, ctx.th, m.spans, tx, y, g.wrap, o, ctx.mouse);
        },
        .irc => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + (g.line_h + 10) / 2, m.msg.timestamp, true);
                y += g.line_h + 10;
            }
            if (group) y += 4;
            const row_h = m.height - (if (day) g.line_h + 10 else 0) - (if (group) @as(f32, 4) else 0);
            if (region_hovered and ctx.hovering(.{ .x = r.x, .y = y, .w = r.w, .h = row_h }))
                d.rect(dl, .{ .x = r.x, .y = y, .w = r.w, .h = row_h }, ctx.col(.hover), 0);
            const ty = y + (g.line_h - g.size * 1.2) / 2;
            var x = r.x + 10;
            const ts = std.fmt.bufPrint(&buf, "[{s}] ", .{w.clock(buf[64..], m.msg.timestamp)}) catch "";
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.faint), ts);
            x += d.width(fam.get(.regular), g.size, ts);
            // Nick alinhado à direita, como num cliente de IRC.
            const col_w = g.prefix_w - d.width(fam.get(.regular), g.size, "[00:00] ") - d.width(fam.get(.regular), g.size, " │ ");
            const nw = d.width(fam.get(.bold), g.size, name);
            const nick_col = if (group) role_col else role_col.alpha(0.35);
            _ = d.textClipped(dl, fam.get(.bold), g.size, x + @max(0, col_w - nw), ty, nick_col.alpha(alpha), name, col_w);
            x += col_w;
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.border).mix(ctx.col(.faint), 0.6), " │ ");
            var o = textOpts(ctx, g, false);
            o.color = o.color.alpha(alpha);
            _ = rich.layout(dl, ctx.store, ctx.th, m.spans, r.x + g.content_x, y, g.wrap, o, ctx.mouse);
        },
        .bubbles => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
                y += 46;
            }
            const left_pad: f32 = 20 + (if (g.avatar > 0) g.avatar + 10 else 0);
            if (group) {
                y += g.spacing;
                if (!self) {
                    d.text(dl, fam.get(.semibold), 13, r.x + left_pad + 6, y, role_col, name);
                    y += 18;
                }
            } else y += 3;
            const bw = @min(m.natural_w, g.wrap) + 28;
            const bh = m.height - (y - y_in) - 0;
            const bx = if (self) r.right() - 24 - bw else r.x + left_pad;
            const br: d.Rect = .{ .x = bx, .y = y, .w = bw, .h = bh - 0 };
            const fill = if (self) ctx.col(.bubble_self) else ctx.col(.bubble_other);
            // Cantos: o do lado de quem fala fica menos arredondado no meio do grupo.
            d.rect(dl, br, fill.alpha(alpha), 18);
            if (!group) d.rectFlags(dl, .{ .x = if (self) br.right() - 18 else br.x, .y = br.y, .w = 18, .h = 18 }, fill.alpha(alpha), 5, if (self) c.ImDrawFlags_RoundTopRight else c.ImDrawFlags_RoundTopLeft);
            if (!self and g.avatar > 0 and group)
                w.avatar(ctx, dl, r.x + 20 + g.avatar / 2, br.y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
            var o = textOpts(ctx, g, self);
            o.color = o.color.alpha(alpha);
            _ = rich.layout(dl, ctx.store, ctx.th, m.spans, br.x + 14, br.y + 7, g.wrap, o, ctx.mouse);
            if (ctx.hovering(br)) {
                const st = w.clock(&buf, m.msg.timestamp);
                const sw = d.width(fam.get(.medium), 11, st);
                const sx = if (self) br.x - sw - 8 else br.right() + 8;
                d.text(dl, fam.get(.medium), 11, sx, br.y + br.h / 2 - 7, ctx.col(.faint), st);
            }
        },
    }
}

fn daySeparator(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, r: d.Rect, mid: f32, ts: i64, tty: bool) void {
    var buf: [64]u8 = undefined;
    const lbl = w.dayLabel(&buf, ts);
    const font = fam.get(.semibold);
    const fs: f32 = if (tty) ctx.th.font_size - 2 else 12;
    const lw = d.width(font, fs, lbl);
    const lx = if (tty) r.x + 40 else r.x + r.w / 2 - lw / 2;
    const lc = ctx.col(.border).mix(ctx.col(.text), 0.04);
    d.line(dl, r.x + 16, mid, lx - 10, mid, lc, 1);
    d.line(dl, lx + lw + 10, mid, r.right() - 16, mid, lc, 1);
    d.text(dl, font, fs, lx, mid - fs * 0.6, ctx.col(.faint), lbl);
}

// --- composer ---------------------------------------------------------------

pub fn composer(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "box");
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const dl = ctx.dl;
    const prompt = std.mem.eql(u8, variant, "prompt");
    const pill = std.mem.eql(u8, variant, "pill");

    if (d.pflag(n, "typing", true) and cs.typing.items.len > 0) {
        const u = ctx.store.user(cs.typing.items[0].user);
        var buf: [96]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s} está digitando", .{if (u) |x| x.name else "alguém"}) catch "";
        const ty = r.y - 19;
        const tx = r.x + (if (prompt) @as(f32, 10) else 6);
        w.typingDots(dl, tx + 4, ty + 8, ctx.col(.muted), ctx.now_ms);
        d.text(dl, fam.get(.semibold), 13, tx + 24, ty, ctx.col(.muted), t);
    }

    var input_x: f32 = r.x + 48;
    var input_r = r.right() - 96;
    if (prompt) {
        d.line(dl, r.x, r.y + 0.5, r.right(), r.y + 0.5, ctx.col(.border), 1);
        const me = ctx.store.user(ctx.store.me);
        var buf: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}@#{s} ❯ ", .{ if (me) |x| x.name else "eu", cs.info.name }) catch "❯ ";
        const fs = ctx.th.font_size;
        d.text(dl, fam.get(.bold), fs, r.x + 10, d.centerY(r, fs), ctx.col(.accent), p);
        input_x = r.x + 10 + d.width(fam.get(.bold), fs, p);
        input_r = r.right() - 10;
    } else {
        const radius = if (pill) r.h / 2 else ctx.th.radius + 4;
        d.rect(dl, r, ctx.col(.elevated), radius);
        // Anexar.
        const ar: d.Rect = .{ .x = r.x + 10, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const ah = d.hit(ctx, 1, ar);
        const ak = anim.to(anim.id("attach", @intFromPtr(n)), if (ah.hovered) 1 else 0, 24);
        d.circle(dl, ar.x + 14, ar.y + 14, 11.5, ctx.col(.muted).mix(ctx.col(.text), ak));
        icons.plus(dl, ar.x + 14, ar.y + 14, 5.5, ctx.col(.elevated).u());
        // Emoji.
        const ex = r.right() - (if (pill) @as(f32, 84) else 40);
        const er: d.Rect = .{ .x = ex, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const eh = d.hit(ctx, 2, er);
        const ek = anim.to(anim.id("emoji", @intFromPtr(n)), if (eh.hovered) 1 else 0, 20);
        const es: f32 = 20 + 2 * ek;
        d.text(dl, fam.get(.regular), es, ex + 14 - es / 2, r.y + r.h / 2 - es * 0.6, d.Rgba.white.alpha(0.55 + 0.45 * ek), "😊");
        if (pill) {
            // Botão de enviar.
            const sr: d.Rect = .{ .x = r.right() - 44, .y = r.y + r.h / 2 - 17, .w = 34, .h = 34 };
            const sh = d.hit(ctx, 3, sr);
            const sk = anim.to(anim.id("send", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
            d.circle(dl, sr.x + 17, sr.y + 17, 17, ctx.col(.accent).mix(d.Rgba.white, sk * 0.12));
            const ink = ctx.col(.accent_text).u();
            c.ImDrawList_AddTriangleFilled(dl, d.v(sr.x + 11, sr.y + 10), d.v(sr.x + 25, sr.y + 17), d.v(sr.x + 11, sr.y + 24), ink);
            if (sh.clicked) send(ctx);
            input_r = ex - 8;
        } else {
            input_r = ex - 8;
        }
    }

    const fs = ctx.th.font_size;
    const frame_h = fs + 8;
    c.ImGui_PushFontFloat(fam.get(.regular), fs);
    c.ImGui_SetCursorScreenPos(d.v(input_x, r.y + (r.h - frame_h) / 2));
    c.ImGui_SetNextItemWidth(@max(40, input_r - input_x));
    if (ctx.st.focus_input and !ctx.st.palette.open) {
        c.ImGui_SetKeyboardFocusHere();
        ctx.st.focus_input = false;
    }
    var hint_buf: [96]u8 = undefined;
    const hint = std.fmt.bufPrintSentinel(&hint_buf, "{s}{s}", .{ if (prompt) "" else "Conversar em #", if (prompt) "" else cs.info.name }, 0) catch "";
    if (c.ImGui_InputTextWithHint("##composer", hint.ptr, &ctx.st.input, ctx.st.input.len, c.ImGuiInputTextFlags_EnterReturnsTrue)) {
        send(ctx);
    }
    c.ImGui_PopFont();
}

fn send(ctx: *d.Ctx) void {
    const len = std.mem.indexOfScalar(u8, &ctx.st.input, 0) orelse ctx.st.input.len;
    const s = std.mem.trim(u8, ctx.st.input[0..len], " \t");
    if (s.len > 0) {
        const owned = ctx.st.gpa.dupe(u8, s) catch return;
        ctx.act(.{ .send_message = owned });
    }
    @memset(&ctx.st.input, 0);
    ctx.st.focus_input = true;
}
