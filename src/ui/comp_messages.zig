//! `messages` e `composer`.
//!
//! messages: variant = cozy | irc | bubbles
//!           avatar = circle | squircle | square | none, avatar-size = 40
//!           spacing = espaço entre grupos (16), font-size
//! composer: variant = box | pill | prompt, typing = mostra "digitando…" (#true)
//!
//! Mensagens: barra de ações ao passar o mouse, botão direito, respostas,
//! reações, "(editado)", seleção de texto com o mouse e Ctrl+C.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const rich = @import("rich.zig");
const icons = @import("icons.zig");
const popup = @import("popup.zig");
const sigil = @import("comp_chat.zig").sigil;
const store_mod = @import("../core/store.zig");
const types = @import("../core/types.zig");
const Id = types.Id;
const StoredMessage = store_mod.StoredMessage;

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
const flag_reply: u8 = 4;

const reply_h: f32 = 22;
const react_h: f32 = 30;

var flash_id: Id = 0;
var flash_until: i64 = 0;

fn geometry(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) Geo {
    const variant = std.meta.stringToEnum(Variant, d.pstr(n, "variant", "cozy")) orelse .cozy;
    const fam = ctx.familyFor(n);
    const size = d.pnum(n, "font-size", ctx.th.font_size);
    const avatar_s = d.pstr(n, "avatar", "circle");
    const set = &ctx.st.settings;
    var av: f32 = if (std.mem.eql(u8, avatar_s, "none") or !set.show_avatars) 0 else d.pnum(n, "avatar-size", if (variant == .bubbles) 30 else 40);
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

fn editedW(g: Geo) f32 {
    return d.width(g.fam.get(.regular), 11, "(editado)") + 6;
}

fn measure(ctx: *d.Ctx, g: Geo, m: *StoredMessage, flags: u8) f32 {
    const key: u32 = @as(u32, @intFromEnum(g.variant)) | (@as(u32, ctx.st.theme_gen) << 2) | (@as(u32, flags) << 10);
    if (m.layout_w == g.wrap and m.layout_variant == key) return m.height;
    const self = m.msg.author == ctx.store.me;
    const t = rich.layout(null, ctx.store, ctx.th, m.spans, 0, 0, g.wrap, textOpts(ctx, g, self and g.variant == .bubbles), ctx.mouse);
    var text_h = t.h;
    if (m.msg.edited and t.last_x + editedW(g) > g.wrap) text_h += g.line_h;
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    const reply = flags & flag_reply != 0;
    const reacts: f32 = if (m.n_reactions > 0) react_h else 0;
    var h: f32 = 0;
    switch (g.variant) {
        .cozy => {
            if (day) h += 46;
            if (group) {
                h += g.spacing + (if (reply) reply_h else 0);
                const body = g.line_h + text_h + reacts;
                h += @max(body, g.avatar);
            } else h += 1 + text_h + reacts;
            h += 1;
        },
        .irc => {
            if (day) h += g.line_h + 10;
            if (group) h += 4;
            if (reply) h += g.line_h;
            h += text_h + (if (reacts > 0) @as(f32, 26) else 0);
        },
        .bubbles => {
            if (day) h += 46;
            h += if (group) g.spacing + (if (self) @as(f32, 0) else 18) else 3;
            h += (if (reply) reply_h + 4 else 0) + text_h + 14 + reacts;
        },
    }
    m.layout_w = g.wrap;
    m.layout_variant = key;
    m.height = h;
    m.natural_w = @max(t.w, if (m.msg.edited) t.last_x + editedW(g) else 0);
    if (reply and g.variant == .bubbles) m.natural_w = @max(m.natural_w, 180);
    return h;
}

/// Faixa da seleção dentro de uma mensagem.
const SelRange = struct { first: usize, o0: u32, last: usize, o1: u32 };

fn selectionRange(ctx: *d.Ctx, cs: *store_mod.ChannelState) ?SelRange {
    const sel = &ctx.st.selection;
    if (sel.channel != cs.info.id or sel.empty()) return null;
    var ia: ?usize = null;
    var ib: ?usize = null;
    for (cs.messages.items, 0..) |m, i| {
        if (m.msg.id == sel.a_id) ia = i;
        if (m.msg.id == sel.b_id) ib = i;
    }
    var r: SelRange = .{ .first = ia orelse return null, .o0 = sel.a_off, .last = ib orelse return null, .o1 = sel.b_off };
    if (r.first > r.last or (r.first == r.last and r.o0 > r.o1)) {
        std.mem.swap(usize, &r.first, &r.last);
        std.mem.swap(u32, &r.o0, &r.o1);
    }
    return r;
}

pub fn messages(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const g = geometry(ctx, n, r);
    ctx.hot = false;

    if (cs.history != .loaded) return skeleton(ctx, g, r);

    const msgs = cs.messages.items;
    const st = ctx.st;
    st.offsets.resize(st.gpa, msgs.len) catch return;
    st.groups.resize(st.gpa, msgs.len) catch return;
    var total: f32 = 8;
    for (msgs, 0..) |*m, i| {
        var flags: u8 = 0;
        if (m.msg.reply_to != 0) flags |= flag_reply | flag_group;
        if (i == 0) {
            flags |= flag_group | flag_day;
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
    // Pulo para uma mensagem (clique numa resposta).
    if (st.jump != 0) {
        for (msgs, 0..) |m, i| if (m.msg.id == st.jump) {
            sc.target = std.math.clamp(st.offsets.items[i] - r.h / 3, 0, max_scroll);
            sc.stick_bottom = false;
            flash_id = st.jump;
            flash_until = ctx.now_ms + 1600;
            break;
        };
        st.jump = 0;
    }
    const hovered = ctx.hovering(r) and ctx.st.popup == .none;
    if (sc.pos < 0 or sc.stick_bottom) {
        sc.target = max_scroll;
        if (sc.pos < 0) sc.pos = max_scroll;
    }
    if (hovered and ctx.io.*.MouseWheel != 0) {
        sc.target -= ctx.io.*.MouseWheel * 120;
        sc.stick_bottom = false;
    }
    sc.target = std.math.clamp(sc.target, 0, max_scroll);
    if (sc.target >= max_scroll - 1) sc.stick_bottom = true;
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
    var lo: usize = 0;
    var hi: usize = msgs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (st.offsets.items[mid] + msgs[mid].height < s) lo = mid + 1 else hi = mid;
    }

    const sel = selectionRange(ctx, cs);
    var probe: rich.Probe = .{ .x = ctx.mouse.x, .y = ctx.mouse.y };
    var probe_idx: ?usize = null;
    var i = lo;
    while (i < msgs.len) : (i += 1) {
        const oy = st.offsets.items[i];
        if (oy > s + r.h) break;
        const y = base + oy;
        const under = hovered and ctx.mouse.y >= y and ctx.mouse.y < y + msgs[i].height;
        if (under) probe_idx = i;
        var from: u32 = 1;
        var to: u32 = 0;
        if (sel) |sr| if (i >= sr.first and i <= sr.last) {
            from = if (i == sr.first) sr.o0 else 0;
            to = if (i == sr.last) sr.o1 else @intCast(msgs[i].msg.content.len);
        };
        drawMessage(ctx, dl, g, &msgs[i], st.groups.items[i], r, y, under, from, to, if (under) &probe else null);
    }

    // Seleção de texto e botão direito.
    if (probe_idx) |pi| {
        const m = &msgs[pi];
        const off = probe.out orelse (if (ctx.mouse.x < r.x + g.content_x) @as(u32, 0) else @as(u32, @intCast(m.msg.content.len)));
        if (!ctx.hot) {
            if (probe.out != null) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_TextInput);
            if (c.ImGui_IsMouseClicked(0)) {
                st.selection = .{ .channel = ch_id, .a_id = m.msg.id, .a_off = off, .b_id = m.msg.id, .b_off = off, .dragging = true };
                if (c.ImGui_IsMouseDoubleClicked(0)) selectWord(st, m, off);
            }
            if (c.ImGui_IsMouseClicked(1)) ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        }
        if (st.selection.dragging and c.ImGui_IsMouseDown(0) and !c.ImGui_IsMouseDoubleClicked(0)) {
            st.selection.b_id = m.msg.id;
            st.selection.b_off = off;
        }
    }
    if (st.selection.dragging and !c.ImGui_IsMouseDown(0)) st.selection.dragging = false;
    if (!st.selection.empty() and ctx.io.*.KeyCtrl and c.ImGui_IsKeyPressed(c.ImGuiKey_C) and !ctx.io.*.WantTextInput) {
        if (popup.selectionText(ctx)) |txt| ctx.act(.{ .copy = txt });
    }
    c.ImGui_EndChild();

    // Voltar para o fim.
    if (!sc.stick_bottom) {
        const br: d.Rect = .{ .x = r.right() - 52, .y = r.bottom() - 52, .w = 36, .h = 36 };
        const hb = d.hit(ctx, 77, br);
        d.shadow(ctx.fg, br, 18, 8, ctx.col(.shadow));
        d.circle(ctx.fg, br.x + 18, br.y + 18, 18, if (hb.hovered) ctx.col(.accent) else ctx.col(.elevated));
        icons.chevron(ctx.fg, br.x + 18, br.y + 19, (if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text)).u(), 1);
        if (hb.clicked) {
            sc.stick_bottom = true;
            sc.target = max_scroll;
        }
    }
}

fn selectWord(st: anytype, m: *const StoredMessage, off: u32) void {
    const s = m.msg.content;
    var a: usize = @min(off, s.len);
    var b: usize = a;
    while (a > 0 and s[a - 1] != ' ' and s[a - 1] != '\n') a -= 1;
    while (b < s.len and s[b] != ' ' and s[b] != '\n') b += 1;
    st.selection.a_off = @intCast(a);
    st.selection.b_off = @intCast(b);
    st.selection.dragging = false;
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

fn snippet(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n >= buf.len) break;
        buf[n] = if (ch == '\n') ' ' else ch;
        n += 1;
    }
    // Não termina no meio de um caractere UTF-8.
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return buf[0..n];
}

/// Linha "↱ @fulano  texto da mensagem original" (clicável).
fn replyLine(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *const StoredMessage, x: f32, y: f32, max_w: f32, spine_x: ?f32, on_accent: bool) void {
    var buf: [160]u8 = undefined;
    const fam = g.fam;
    const found = ctx.store.findAny(m.msg.reply_to);
    const rr: d.Rect = .{ .x = x, .y = y, .w = max_w, .h = reply_h };
    const hb = d.hit(ctx, @truncate(m.msg.id ^ 0x5151), rr);
    if (hb.clicked) if (found != null) ctx.act(.{ .jump_to = m.msg.reply_to });
    if (spine_x) |sx| {
        // A "curvinha" ligando o avatar à mensagem respondida.
        c.ImDrawList_PathClear(dl);
        c.ImDrawList_PathLineTo(dl, d.v(sx, y + reply_h));
        c.ImDrawList_PathLineTo(dl, d.v(sx, y + 14));
        c.ImDrawList_PathArcTo(dl, d.v(sx + 6, y + 14), 6, std.math.pi, std.math.pi * 1.5, 0);
        c.ImDrawList_PathLineTo(dl, d.v(x - 4, y + 8));
        c.ImDrawList_PathStroke(dl, ctx.col(.faint).alpha(0.6).u(), 2, 0);
    }
    const muted = if (on_accent) ctx.col(.bubble_self_text).alpha(0.75) else ctx.col(.muted);
    if (found) |f| {
        const u = ctx.store.user(f.m.msg.author);
        var xx = x;
        if (g.avatar > 0) {
            w.avatar(ctx, dl, xx + 8, y + 9, 16, f.m.msg.author, .circle, null, 1);
            xx += 20;
        }
        const name = if (u) |uu| uu.name else "?";
        const nc = if (on_accent) ctx.col(.bubble_self_text) else ctx.th.role(if (u) |uu| uu.role else 0).mix(ctx.col(.text), 0.2);
        const nm = std.fmt.bufPrint(buf[0..40], "@{s}", .{name}) catch name;
        d.text(dl, fam.get(.semibold), 13, xx, y + 1, nc, nm);
        xx += d.width(fam.get(.semibold), 13, nm) + 6;
        _ = d.textClipped(dl, fam.get(.regular), 13, xx, y + 1, if (hb.hovered) ctx.col(.text) else muted, snippet(buf[40..], f.m.msg.content), max_w - (xx - x));
    } else {
        d.text(dl, fam.get(.italic), 13, x, y + 1, muted, "mensagem original não carregada");
    }
}

fn reactions(ctx: *d.Ctx, dl: *c.ImDrawList, m: *StoredMessage, x: f32, y: f32, show_add: bool, right_to_left: bool, right: f32) void {
    var buf: [24]u8 = undefined;
    const fam = ctx.ui;
    var xx = x;
    var widths: [9]f32 = undefined;
    var total: f32 = 0;
    for (m.reactionSlice(), 0..) |*rc, i| {
        const cnt = std.fmt.bufPrint(&buf, "{d}", .{rc.count}) catch "";
        widths[i] = 22 + d.width(fam.get(.semibold), 13, cnt) + 18;
        total += widths[i] + 4;
    }
    if (right_to_left) xx = right - total - (if (show_add) @as(f32, 36) else 0);
    for (m.reactionSlice(), 0..) |*rc, i| {
        const cnt = std.fmt.bufPrint(&buf, "{d}", .{rc.count}) catch "";
        const cr: d.Rect = .{ .x = xx, .y = y + 3, .w = widths[i], .h = 24 };
        const hb = d.hit(ctx, @truncate((m.msg.id *% 31) +% i), cr);
        if (hb.clicked) ctx.act(.{ .react = .{ .id = m.msg.id, .emoji = rc.* } });
        const bg = if (rc.me) ctx.col(.accent).alpha(0.2) else ctx.col(.elevated);
        d.rect(dl, cr, if (hb.hovered) bg.mix(ctx.col(.text), 0.06) else bg, 8);
        if (rc.me or hb.hovered) d.border(dl, cr, if (rc.me) ctx.col(.accent) else ctx.col(.border).mix(ctx.col(.text), 0.1), 8, 1);
        d.text(dl, fam.get(.regular), 15, cr.x + 6, cr.y + 2, d.Rgba.white, rc.text());
        d.text(dl, fam.get(.semibold), 13, cr.x + 28, d.centerY(cr, 13), if (rc.me) ctx.col(.accent).mix(ctx.col(.text), 0.3) else ctx.col(.muted), cnt);
        xx += cr.w + 4;
    }
    if (show_add) {
        const ar: d.Rect = .{ .x = xx, .y = y + 3, .w = 32, .h = 24 };
        const hb = d.hit(ctx, @truncate(m.msg.id ^ 0xadd), ar);
        d.rect(dl, ar, ctx.col(.elevated).alpha(if (hb.hovered) 1 else 0.6), 8);
        icons.plus(dl, ar.x + 16, ar.y + 12, 4.5, ctx.col(.muted).u());
        if (hb.clicked) ctx.popup(.{ .emoji = .{ .target = m.msg.id, .x = ar.x + 200, .y = ar.y } });
    }
}

/// Barra flutuante com reações rápidas, responder, editar e "mais".
fn toolbar(ctx: *d.Ctx, dl: *c.ImDrawList, m: *const StoredMessage, right: f32, top: f32) void {
    const own = m.msg.author == ctx.store.me and m.msg.id != 0;
    const items = [_]struct { glyph: []const u8, emoji: bool, show: bool }{
        .{ .glyph = "👍", .emoji = true, .show = true },
        .{ .glyph = "😂", .emoji = true, .show = true },
        .{ .glyph = "🔥", .emoji = true, .show = true },
        .{ .glyph = "↩", .emoji = false, .show = true },
        .{ .glyph = "✎", .emoji = false, .show = own },
        .{ .glyph = "⋯", .emoji = false, .show = true },
    };
    var count: f32 = 0;
    for (items) |it| {
        if (it.show) count += 1;
    }
    const bw: f32 = 32;
    const tr: d.Rect = .{ .x = right - count * bw - 8, .y = top, .w = count * bw + 8, .h = 36 };
    d.shadow(dl, tr, 8, 8, ctx.col(.shadow).alpha(0.6));
    d.rect(dl, tr, ctx.col(.overlay), @max(ctx.th.radius, 4));
    d.border(dl, tr, ctx.col(.border), @max(ctx.th.radius, 4), 1);
    var x = tr.x + 4;
    for (items, 0..) |it, i| {
        if (!it.show) continue;
        const br: d.Rect = .{ .x = x, .y = tr.y + 2, .w = bw, .h = 32 };
        const hb = d.hit(ctx, @truncate((m.msg.id *% 7) +% i + 900), br);
        if (hb.hovered) d.rect(dl, br, ctx.col(.hover).mix(ctx.col(.text), 0.05), 5);
        const fs: f32 = if (it.emoji) 18 else 17;
        const font = ctx.ui.get(if (it.emoji) .regular else .bold);
        const gw = d.width(font, fs, it.glyph);
        d.text(dl, font, fs, br.x + bw / 2 - gw / 2, d.centerY(br, fs), if (it.emoji) d.Rgba.white else (if (hb.hovered) ctx.col(.text) else ctx.col(.muted)), it.glyph);
        if (hb.clicked) switch (i) {
            0, 1, 2 => ctx.act(.{ .react = .{ .id = m.msg.id, .emoji = types.Reaction.init(it.glyph) } }),
            3 => ctx.act(.{ .reply = m.msg.id }),
            4 => ctx.act(.{ .edit_message = m.msg.id }),
            else => ctx.popup(.{ .menu = .{ .kind = .message, .id = m.msg.id, .x = br.x, .y = br.bottom() } }),
        };
        x += bw;
    }
}

fn nameHit(ctx: *d.Ctx, uid: Id, r: d.Rect, salt: u64) void {
    const hb = d.hit(ctx, @truncate(uid *% 131 +% salt), r);
    if (hb.clicked) ctx.popup(.{ .profile = .{ .user = uid, .x = r.right() + 4, .y = r.y } });
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

fn drawMessage(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *StoredMessage, flags: u8, r: d.Rect, y_in: f32, under: bool, sel_from: u32, sel_to: u32, probe: ?*rich.Probe) void {
    var y = y_in;
    var buf: [96]u8 = undefined;
    const group = flags & flag_group != 0;
    const day = flags & flag_day != 0;
    const reply = flags & flag_reply != 0;
    const u = ctx.store.user(m.msg.author);
    const name = if (u) |x| x.name else "?";
    const role_col = if (ctx.st.settings.role_colors) ctx.th.role(if (u) |x| x.role else 0).mix(ctx.col(.text), 0.2) else ctx.col(.text);
    const alpha: f32 = if (m.pending) 0.5 else 1;
    const fam = g.fam;
    const self = m.msg.author == ctx.store.me;
    var o = textOpts(ctx, g, self and g.variant == .bubbles);
    o.color = o.color.alpha(alpha);
    o.base = m.msg.content.ptr;
    o.sel_from = sel_from;
    o.sel_to = sel_to;
    o.probe = probe;
    const show_bar = under and ctx.st.popup == .none and !ctx.st.selection.dragging and m.msg.id != 0;

    // Destaque ao pular para esta mensagem.
    const flash = if (m.msg.id == flash_id and ctx.now_ms < flash_until) blk: {
        anim.active = true;
        break :blk @as(f32, @floatFromInt(flash_until - ctx.now_ms)) / 1600.0;
    } else 0;
    // Menção a mim: faixa amarela à esquerda, como no Discord.
    var mentions_me = false;
    for (m.spans) |sp| if (sp.mention == .user and sp.mention.user == ctx.store.me) {
        mentions_me = true;
    };

    switch (g.variant) {
        .cozy => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + 23, m.msg.timestamp, false);
                y += 46;
            }
            const row: d.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = m.height - (if (day) @as(f32, 46) else 0) };
            if (mentions_me) {
                d.rect(dl, row, ctx.col(.idle).alpha(0.08), 0);
                d.rect(dl, .{ .x = r.x, .y = row.y, .w = 2, .h = row.h }, ctx.col(.idle), 0);
            }
            if (under) d.rect(dl, row, d.Rgba.black.alpha(0.07), 0);
            if (flash > 0) d.rect(dl, row, ctx.col(.accent).alpha(0.25 * flash), 0);
            const tx = r.x + g.content_x;
            if (group) {
                y += g.spacing;
                if (reply) {
                    replyLine(ctx, dl, g, m, tx, y, g.wrap, if (g.avatar > 0) r.x + 16 + g.avatar / 2 else null, false);
                    y += reply_h;
                }
                if (g.avatar > 0) {
                    const ar: d.Rect = .{ .x = r.x + 16, .y = y, .w = g.avatar, .h = g.avatar };
                    w.avatar(ctx, dl, ar.x + g.avatar / 2, ar.y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
                    nameHit(ctx, m.msg.author, ar, 1);
                }
                const nw = d.width(fam.get(.semibold), g.size, name);
                const nr: d.Rect = .{ .x = tx, .y = y, .w = nw, .h = g.line_h };
                nameHit(ctx, m.msg.author, nr, 2);
                d.text(dl, fam.get(.semibold), g.size, tx, y + (g.line_h - g.size * 1.2) / 2, role_col.alpha(alpha), name);
                if (ctx.hovering(nr)) d.line(dl, tx, nr.bottom() - 2, tx + nw, nr.bottom() - 2, role_col, 1);
                const stp = w.stamp(&buf, m.msg.timestamp, @divTrunc(ctx.now_ms, 1000));
                d.text(dl, fam.get(.medium), 12, tx + nw + 8, y + (g.line_h - 12 * 1.2) / 2 + 1, ctx.col(.faint), stp);
                y += g.line_h;
            } else {
                y += 1;
                if (under and g.avatar > 0) {
                    const ck = w.clock(&buf, m.msg.timestamp);
                    const sw = d.width(fam.get(.medium), 11, ck);
                    d.text(dl, fam.get(.medium), 11, r.x + 16 + g.avatar / 2 - sw / 2, y + 5, ctx.col(.faint), ck);
                }
            }
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, tx, y, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, tx, y, t);
            if (m.n_reactions > 0) reactions(ctx, dl, m, tx, y + t.h + (if (m.msg.edited and t.last_x + editedW(g) > g.wrap) g.line_h else 0), under, false, 0);
            if (ctx.st.settings.developer_mode and under) {
                const idt = std.fmt.bufPrint(&buf, "id {d}", .{m.msg.id}) catch "";
                const iw = d.width(fam.get(.regular), 11, idt);
                d.text(dl, fam.get(.regular), 11, r.right() - iw - 14, row.bottom() - 16, ctx.col(.faint), idt);
            }
            if (show_bar) toolbar(ctx, dl, m, r.right() - 16, row.y - 16 + (if (group) g.spacing else 0));
        },
        .irc => {
            if (day) {
                daySeparator(ctx, dl, fam, r, y + (g.line_h + 10) / 2, m.msg.timestamp, true);
                y += g.line_h + 10;
            }
            if (group) y += 4;
            const row: d.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = m.height - (y - y_in) };
            if (under) d.rect(dl, row, ctx.col(.hover), 0);
            if (flash > 0) d.rect(dl, row, ctx.col(.accent).alpha(0.25 * flash), 0);
            if (mentions_me) d.rect(dl, .{ .x = r.x, .y = row.y, .w = 2, .h = row.h }, ctx.col(.mention), 0);
            if (reply) {
                const found = ctx.store.findAny(m.msg.reply_to);
                const ru = if (found) |f| ctx.store.user(f.m.msg.author) else null;
                var rb: [160]u8 = undefined;
                const line = std.fmt.bufPrint(&rb, "↳ {s}: {s}", .{ if (ru) |x| x.name else "?", if (found) |f| snippet(rb[100..], f.m.msg.content) else "…" }) catch "";
                const lr: d.Rect = .{ .x = r.x + g.content_x, .y = y, .w = g.wrap, .h = g.line_h };
                const hb = d.hit(ctx, @truncate(m.msg.id ^ 0x5151), lr);
                if (hb.clicked) ctx.act(.{ .jump_to = m.msg.reply_to });
                _ = d.textClipped(dl, fam.get(.regular), g.size - 1, lr.x, d.centerY(lr, g.size - 1), if (hb.hovered) ctx.col(.text) else ctx.col(.faint), line, lr.w);
                y += g.line_h;
            }
            const ty = y + (g.line_h - g.size * 1.2) / 2;
            var x = r.x + 10;
            const ts = std.fmt.bufPrint(&buf, "[{s}] ", .{w.clock(buf[64..], m.msg.timestamp)}) catch "";
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.faint), ts);
            x += d.width(fam.get(.regular), g.size, ts);
            const col_w = g.prefix_w - d.width(fam.get(.regular), g.size, "[00:00] ") - d.width(fam.get(.regular), g.size, " │ ");
            const nw = @min(d.width(fam.get(.bold), g.size, name), col_w);
            const nick_col = if (group) role_col else role_col.alpha(0.35);
            nameHit(ctx, m.msg.author, .{ .x = x + col_w - nw, .y = y, .w = nw, .h = g.line_h }, 3);
            _ = d.textClipped(dl, fam.get(.bold), g.size, x + col_w - nw, ty, nick_col.alpha(alpha), name, col_w);
            x += col_w;
            d.text(dl, fam.get(.regular), g.size, x, ty, ctx.col(.border).mix(ctx.col(.faint), 0.6), " │ ");
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, r.x + g.content_x, y, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, r.x + g.content_x, y, t);
            if (m.n_reactions > 0) reactions(ctx, dl, m, r.x + g.content_x, y + t.h - 2, under, false, 0);
            if (show_bar) toolbar(ctx, dl, m, r.right() - 12, row.y - 2);
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
                    const nw = d.width(fam.get(.semibold), 13, name);
                    nameHit(ctx, m.msg.author, .{ .x = r.x + left_pad + 6, .y = y, .w = nw, .h = 16 }, 4);
                    d.text(dl, fam.get(.semibold), 13, r.x + left_pad + 6, y, role_col, name);
                    y += 18;
                }
            } else y += 3;
            const reacts: f32 = if (m.n_reactions > 0) react_h else 0;
            const bw = @min(m.natural_w, g.wrap) + 28;
            const bh = m.height - (y - y_in) - reacts;
            const bx = if (self) r.right() - 24 - bw else r.x + left_pad;
            const br: d.Rect = .{ .x = bx, .y = y, .w = bw, .h = bh };
            const fill = if (self) ctx.col(.bubble_self) else ctx.col(.bubble_other);
            d.rect(dl, br, fill.alpha(alpha), 18);
            if (!group) d.rectFlags(dl, .{ .x = if (self) br.right() - 18 else br.x, .y = br.y, .w = 18, .h = 18 }, fill.alpha(alpha), 5, if (self) c.ImDrawFlags_RoundTopRight else c.ImDrawFlags_RoundTopLeft);
            if (flash > 0) d.border(dl, br.inset(-3, -3), ctx.col(.accent).alpha(flash), 20, 2);
            if (!self and g.avatar > 0 and group) {
                const ar: d.Rect = .{ .x = r.x + 20, .y = br.y, .w = g.avatar, .h = g.avatar };
                w.avatar(ctx, dl, ar.x + g.avatar / 2, ar.y + g.avatar / 2, g.avatar, m.msg.author, g.shape, null, alpha);
                nameHit(ctx, m.msg.author, ar, 5);
            }
            var ty = br.y + 7;
            if (reply) {
                d.rect(dl, .{ .x = br.x + 10, .y = ty, .w = 3, .h = reply_h - 2 }, if (self) ctx.col(.bubble_self_text).alpha(0.6) else ctx.col(.accent), 2);
                var gg = g;
                gg.avatar = 0;
                replyLine(ctx, dl, gg, m, br.x + 18, ty, bw - 30, null, self);
                ty += reply_h + 4;
            }
            const t = rich.layout(dl, ctx.store, ctx.th, m.spans, br.x + 14, ty, g.wrap, o, ctx.mouse);
            editedMark(ctx, dl, g, m, br.x + 14, ty, t);
            if (m.n_reactions > 0) reactions(ctx, dl, m, br.x, br.bottom(), under, self, br.right());
            if (ctx.hovering(br)) {
                const ck = w.clock(&buf, m.msg.timestamp);
                const sw = d.width(fam.get(.medium), 11, ck);
                const sx = if (self) br.x - sw - 8 else br.right() + 8;
                d.text(dl, fam.get(.medium), 11, sx, br.y + br.h / 2 - 7, ctx.col(.faint), ck);
            }
            if (show_bar) toolbar(ctx, dl, m, if (self) br.x - 50 else @min(br.right() + 180, r.right() - 12), br.y - 12);
        },
    }
}

fn editedMark(ctx: *d.Ctx, dl: *c.ImDrawList, g: Geo, m: *const StoredMessage, x: f32, y: f32, t: rich.Measure) void {
    if (!m.msg.edited) return;
    const ew = editedW(g);
    const wraps = t.last_x + ew > g.wrap;
    const ex = if (wraps) x else x + t.last_x + 6;
    const ey = y + t.h - g.line_h + (if (wraps) g.line_h else 0);
    d.text(dl, g.fam.get(.regular), 11, ex, ey + (g.line_h - 13) / 2, ctx.col(.faint), "(editado)");
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

fn inputCallback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const st: *@import("state.zig").State = @ptrCast(@alignCast(data.*.UserData));
    if (st.input_sync) {
        st.input_sync = false;
        c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
        c.ImGuiInputTextCallbackData_InsertChars(data, 0, &st.input, null);
    }
    if (data.*.EventFlag == c.ImGuiInputTextFlags_CallbackHistory and data.*.EventKey == c.ImGuiKey_UpArrow and data.*.BufTextLen == 0)
        st.edit_last = true;
    return 0;
}

pub fn composer(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "box");
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const dl = ctx.dl;
    const st = ctx.st;
    const prompt = std.mem.eql(u8, variant, "prompt");
    const pill = std.mem.eql(u8, variant, "pill");

    // Barra "Respondendo a…" / "Editando…" presa em cima da caixa.
    var top = r.y;
    if (st.reply_to != 0 or st.editing != 0) {
        const bar: d.Rect = .{ .x = r.x + (if (pill) @as(f32, 18) else 0), .y = r.y - 32, .w = r.w - (if (pill) @as(f32, 36) else 0), .h = 34 };
        d.rectFlags(dl, bar, ctx.col(.rail).mix(ctx.col(.elevated), 0.5), @max(ctx.th.radius + 4, 4), c.ImDrawFlags_RoundTop);
        var buf: [128]u8 = undefined;
        const t = if (st.editing != 0)
            "Editando mensagem  ·  Esc cancela  ·  Enter salva"
        else blk: {
            const f = ctx.store.findAny(st.reply_to);
            const u = if (f) |x| ctx.store.user(x.m.msg.author) else null;
            break :blk std.fmt.bufPrint(&buf, "Respondendo a {s}", .{if (u) |x| x.name else "mensagem"}) catch "";
        };
        d.text(dl, fam.get(.medium), 13, bar.x + 14, bar.y + 8, ctx.col(.muted), t);
        const xr: d.Rect = .{ .x = bar.right() - 30, .y = bar.y + 5, .w = 22, .h = 22 };
        const hb = d.hit(ctx, 9, xr);
        const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.faint);
        d.circle(dl, xr.x + 11, xr.y + 11, 9, if (hb.hovered) ctx.col(.hover) else ctx.col(.faint).alpha(0.25));
        d.line(dl, xr.x + 7, xr.y + 7, xr.x + 15, xr.y + 15, xc, 1.6);
        d.line(dl, xr.x + 15, xr.y + 7, xr.x + 7, xr.y + 15, xc, 1.6);
        if (hb.clicked) ctx.act(.cancel_compose);
        top = bar.y;
    }

    if (d.pflag(n, "typing", true) and cs.typing.items.len > 0) {
        const u = ctx.store.user(cs.typing.items[0].user);
        var buf: [96]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s} está digitando", .{if (u) |x| x.name else "alguém"}) catch "";
        const ty = top - 19;
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
        const p = std.fmt.bufPrint(&buf, "{s}@{s}{s} {s} ", .{ if (me) |x| x.name else "eu", sigil(&cs.info), cs.info.name, if (st.editing != 0) "✎" else if (st.reply_to != 0) "↩" else "❯" }) catch "❯ ";
        const fs = ctx.th.font_size;
        d.text(dl, fam.get(.bold), fs, r.x + 10, d.centerY(r, fs), ctx.col(.accent), p);
        input_x = r.x + 10 + d.width(fam.get(.bold), fs, p);
        input_r = r.right() - 44;
        const er: d.Rect = .{ .x = r.right() - 36, .y = r.y + r.h / 2 - 13, .w = 26, .h = 26 };
        const eh = d.hit(ctx, 2, er);
        d.text(dl, fam.get(.regular), 18, er.x + 4, er.y + 2, d.Rgba.white.alpha(if (eh.hovered) 1 else 0.6), "😊");
        if (eh.clicked) ctx.popup(.{ .emoji = .{ .target = 0, .x = er.right(), .y = r.y } });
    } else {
        const radius = if (pill) r.h / 2 else ctx.th.radius + 4;
        const flags: c_int = if (st.reply_to != 0 or st.editing != 0) c.ImDrawFlags_RoundBottom else 0;
        d.rectFlags(dl, r, ctx.col(.elevated), radius, flags);
        const ar: d.Rect = .{ .x = r.x + 10, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const ah = d.hit(ctx, 1, ar);
        const ak = anim.to(anim.id("attach", @intFromPtr(n)), if (ah.hovered) 1 else 0, 24);
        d.circle(dl, ar.x + 14, ar.y + 14, 11.5, ctx.col(.muted).mix(ctx.col(.text), ak));
        icons.plus(dl, ar.x + 14, ar.y + 14, 5.5, ctx.col(.elevated).u());
        if (ah.clicked) st.showToast(ctx.now_ms, false, "anexos chegam junto com a rede", .{});
        const ex = r.right() - (if (pill) @as(f32, 84) else 40);
        const er: d.Rect = .{ .x = ex, .y = r.y + r.h / 2 - 14, .w = 28, .h = 28 };
        const eh = d.hit(ctx, 2, er);
        const ek = anim.to(anim.id("emoji", @intFromPtr(n)), if (eh.hovered) 1 else 0, 20);
        const es: f32 = 20 + 2 * ek;
        d.text(dl, fam.get(.regular), es, ex + 14 - es / 2, r.y + r.h / 2 - es * 0.6, d.Rgba.white.alpha(0.55 + 0.45 * ek), "😊");
        if (eh.clicked) ctx.popup(.{ .emoji = .{ .target = 0, .x = er.right(), .y = r.y } });
        if (pill) {
            const sr: d.Rect = .{ .x = r.right() - 44, .y = r.y + r.h / 2 - 17, .w = 34, .h = 34 };
            const sh = d.hit(ctx, 3, sr);
            const sk = anim.to(anim.id("send", @intFromPtr(n)), if (sh.hovered) 1 else 0, 20);
            d.circle(dl, sr.x + 17, sr.y + 17, 17, ctx.col(.accent).mix(d.Rgba.white, sk * 0.12));
            const ink = ctx.col(.accent_text).u();
            c.ImDrawList_AddTriangleFilled(dl, d.v(sr.x + 11, sr.y + 10), d.v(sr.x + 25, sr.y + 17), d.v(sr.x + 11, sr.y + 24), ink);
            if (sh.clicked) submit(ctx);
        }
        input_r = ex - 8;
    }

    const fs = ctx.th.font_size;
    const frame_h = fs * d.text_scale + 8;
    c.ImGui_PushFontFloat(fam.get(.regular), fs * d.text_scale);
    c.ImGui_SetCursorScreenPos(d.v(input_x, r.y + (r.h - frame_h) / 2));
    c.ImGui_SetNextItemWidth(@max(40, input_r - input_x));
    if (st.focus_input and !st.palette.open and !st.settings.open and st.popup == .none) {
        c.ImGui_SetKeyboardFocusHere();
        st.focus_input = false;
    }
    var hint_buf: [96]u8 = undefined;
    const hint = if (prompt) "" else if (cs.info.guild == 0)
        std.fmt.bufPrintSentinel(&hint_buf, "Conversar com @{s}", .{cs.info.name}, 0) catch ""
    else
        std.fmt.bufPrintSentinel(&hint_buf, "Conversar em #{s}", .{cs.info.name}, 0) catch "";
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_CallbackHistory;
    if (c.ImGui_InputTextWithHintEx("##composer", hint.ptr, &st.input, st.input.len, flags, inputCallback, st)) submit(ctx);
    const active = c.ImGui_IsItemActive();
    c.ImGui_PopFont();
    if (active and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and (st.reply_to != 0 or st.editing != 0)) ctx.act(.cancel_compose);

    if (st.edit_last) {
        st.edit_last = false;
        var i = cs.messages.items.len;
        while (i > 0) {
            i -= 1;
            const m = &cs.messages.items[i];
            if (m.msg.author == ctx.store.me and m.msg.id != 0) {
                ctx.act(.{ .edit_message = m.msg.id });
                break;
            }
        }
    }
}

fn submit(ctx: *d.Ctx) void {
    const st = ctx.st;
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    const s = std.mem.trim(u8, st.input[0..len], " \t");
    if (s.len > 0) {
        const owned = st.gpa.dupe(u8, s) catch return;
        ctx.act(if (st.editing != 0) .{ .save_edit = owned } else .{ .send_message = owned });
    }
    @memset(&st.input, 0);
    st.input_sync = true;
    st.focus_input = true;
}
