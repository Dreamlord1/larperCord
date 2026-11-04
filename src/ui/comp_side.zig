//! `member-list` e `status-bar`.
//!
//! member-list: variant = discord | tty
//! status-bar:  variant = pills | tty | plain
//!              items = "conn ping ram frame voice theme keys clock"
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");

pub fn memberList(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    if (ctx.st.friends) return @import("comp_friends.zig").activeNow(ctx, n, r);
    const ch_id = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch_id) orelse return;
    const tty = d.is(n, "variant", "tty", "discord");
    // DM com uma pessoa: o perfil dela, como no Discord.
    if (cs.info.guild == 0 and !cs.info.group) return dmProfile(ctx, n, r, cs.info.recipient, tty);

    const fam = ctx.familyFor(n);
    const dl = d.beginRegion(ctx, "##members", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var rows: Rows = .{ .ctx = ctx, .dl = dl, .fam = fam, .tty = tty, .r = r, .y = o.y + (if (tty) @as(f32, 6) else 20), .guild = cs.info.guild };

    if (cs.info.group) {
        // Grupo: a gente e os participantes, quem está online primeiro.
        var ids: [16]types.Id = undefined;
        var nids: usize = 0;
        ids[0] = ctx.store.me;
        nids = 1;
        for (cs.info.recipients) |uid| if (nids < ids.len and uid != ctx.store.me) {
            ids[nids] = uid;
            nids += 1;
        };
        const Sort = struct {
            ctx: *const d.Ctx,
            fn lt(sx: @This(), a: types.Id, b: types.Id) bool {
                const oa = if (sx.ctx.store.user(a)) |u| u.status != .offline else false;
                const ob = if (sx.ctx.store.user(b)) |u| u.status != .offline else false;
                if (oa != ob) return oa;
                return a < b;
            }
        };
        @import("../core/sort.zig").stable(types.Id, ids[0..nids], Sort{ .ctx = ctx }, Sort.lt);
        var buf: [48]u8 = undefined;
        rows.heading(i18n.fmt(&buf, "MEMBROS — {d}", "MEMBERS — {d}", .{nids}));
        for (ids[0..nids]) |uid| rows.member(uid, false);
        return d.endRegion(ctx, rows.y, r.x);
    }

    // Thread: quem está nela. Sem saber (ou vazia), a lista do canal pai.
    if (cs.info.thread != null) {
        const inside = ctx.store.threadMembers(ch_id);
        if (inside.len > 0) {
            var hb: [48]u8 = undefined;
            rows.heading(i18n.fmt(&hb, "NA THREAD — {d}", "IN THREAD — {d}", .{inside.len}));
            // Quem está online primeiro, sem ordenar a cada quadro.
            for ([_]bool{ true, false }) |want_on| for (inside) |uid| {
                const on = if (ctx.store.user(uid)) |u| u.status != .offline else false;
                if (on == want_on) rows.member(uid, false);
            };
            return d.endRegion(ctx, rows.y, r.x);
        }
    }
    const ml = ctx.store.memberList(cs.info.guild) orelse return loading(&rows);
    if (!ml.synced) return loading(&rows);
    var offline = false;
    var buf: [96]u8 = undefined;
    for (ml.items.items) |it| switch (it) {
        .none => {},
        .group => |gr| {
            offline = gr.id == types.group_offline;
            const name = if (gr.id == types.group_online) "ONLINE" else if (gr.id == types.group_offline) "OFFLINE" else if (ctx.store.roles.get(gr.id)) |role| role.name else "?";
            var up: [64]u8 = undefined;
            rows.heading(std.fmt.bufPrint(&buf, "{s} — {d}", .{ d.upper(&up, name), gr.count }) catch "");
        },
        .member => |m| rows.member(m.user, offline),
    };
    // A lista que o Discord manda para no 100º; o resto fica para quem rola.
    if (ml.total > ml.items.items.len and ml.items.items.len >= 100) {
        rows.y += 4;
        d.text(dl, fam.get(.medium), 12, r.x + 16, rows.y, ctx.col(.faint), i18n.fmt(&buf, "{d} membros no total", "{d} members in total", .{ml.total}));
        rows.y += 24;
    }
    d.endRegion(ctx, rows.y, r.x);
}

/// Desenha as linhas da lista de membros uma embaixo da outra.
const Rows = struct {
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    fam: *d.Family,
    tty: bool,
    r: d.Rect,
    y: f32,
    guild: types.Id,
    first: bool = true,

    fn heading(rw: *Rows, label: []const u8) void {
        const ctx = rw.ctx;
        if (!rw.first) rw.y += if (rw.tty) @as(f32, 8) else 14;
        rw.first = false;
        d.text(rw.dl, rw.fam.get(.semibold), if (rw.tty) ctx.th.font_size - 2 else 12, rw.r.x + (if (rw.tty) @as(f32, 10) else 16), rw.y, ctx.col(.faint).mix(ctx.col(.muted), 0.3), label);
        rw.y += if (rw.tty) @as(f32, 20) else 22;
    }

    fn member(rw: *Rows, uid: types.Id, offline_group: bool) void {
        const ctx = rw.ctx;
        const dl = rw.dl;
        const fam = rw.fam;
        const r = rw.r;
        const u = ctx.store.user(uid) orelse return;
        // Fora da tela: só ocupa o espaço (a lista pode ter 100+ pessoas).
        const row_h: f32 = if (rw.tty) 20 else 44;
        if (rw.y + row_h < r.y or rw.y > r.bottom()) {
            rw.y += row_h;
            return;
        }
        const online = !offline_group and u.status != .offline;
        const name_col = w.nameColor(ctx, rw.guild, uid);
        if (rw.tty) {
            const rr: d.Rect = .{ .x = r.x + 4, .y = rw.y, .w = r.w - 8, .h = 20 };
            const hb = d.hit(ctx, @truncate(uid), rr);
            qa.mark(rr, "member:{d}", .{uid});
            memberClick(ctx, hb, uid, rr);
            if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 0);
            const fs = ctx.th.font_size;
            d.text(dl, fam.get(.regular), fs - 1, rr.x + 6, d.centerY(rr, fs - 1), w.statusColor(ctx, if (online) u.status else .offline), w.statusGlyph(if (online) u.status else .offline));
            _ = d.textClipped(dl, fam.get(if (online) .bold else .regular), fs - 1, rr.x + 24, d.centerY(rr, fs - 1), if (online) name_col else ctx.col(.faint), u.name, rr.w - 30);
            rw.y += 20;
            return;
        }
        const rr: d.Rect = .{ .x = r.x + 8, .y = rw.y, .w = r.w - 16, .h = 42 };
        const hb = d.hit(ctx, @truncate(uid), rr);
        qa.mark(rr, "member:{d}", .{uid});
        memberClick(ctx, hb, uid, rr);
        const k = anim.to(anim.id("member", uid), if (hb.hovered) 1 else 0, 24);
        d.rect(dl, rr, ctx.col(.hover).alpha(k * 1.4), ctx.th.radius);
        const alpha: f32 = if (online) 1 else 0.38 + 0.4 * k;
        w.avatar(ctx, dl, rr.x + 24, rr.y + 21, 32, uid, .circle, if (online) ctx.col(.sidebar) else null, alpha);
        if (u.activity != null and online) {
            _ = d.textClipped(dl, fam.get(.medium), 15, rr.x + 48, rr.y + 3, name_col.alpha(alpha), u.name, rr.w - 56);
            _ = d.textClipped(dl, fam.get(.regular), 12, rr.x + 48, rr.y + 22, ctx.col(.muted).alpha(alpha), u.activity.?, rr.w - 56);
        } else {
            _ = d.textClipped(dl, fam.get(.medium), 15, rr.x + 48, d.centerY(rr, 15), name_col.alpha(alpha), u.name, rr.w - 56);
        }
        rw.y += 44;
    }
};

var loading_guild: types.Id = 0;
var loading_since: i64 = 0;

/// Enquanto a lista do Discord não chega: linhas-esqueleto piscando.
fn loading(rw: *Rows) void {
    const ctx = rw.ctx;
    rw.heading(i18n.tr("CARREGANDO MEMBROS…", "LOADING MEMBERS…"));
    const ph = @as(f32, @floatFromInt(@mod(ctx.now_ms, 1600))) / 1600.0;
    for (0..8) |i| {
        const k = 0.5 + 0.5 * @sin((ph - @as(f32, @floatFromInt(i)) * 0.08) * std.math.tau);
        const col = ctx.col(.text).alpha(0.04 + 0.04 * k);
        if (rw.tty) {
            d.rect(rw.dl, .{ .x = rw.r.x + 10, .y = rw.y + 5, .w = rw.r.w * 0.5, .h = 10 }, col, 0);
            rw.y += 20;
            continue;
        }
        d.circle(rw.dl, rw.r.x + 32, rw.y + 21, 16, col);
        d.rect(rw.dl, .{ .x = rw.r.x + 56, .y = rw.y + 15, .w = 60 + @as(f32, @floatFromInt((i * 37) % 70)), .h = 12 }, col, 6);
        rw.y += 44;
    }
    // Sem conexão, ou se o Discord não respondeu, para de animar (a resposta
    // acorda o app quando vier): piscar para sempre gastaria CPU à toa.
    if (ctx.st.guild != loading_guild) {
        loading_guild = ctx.st.guild;
        loading_since = ctx.now_ms;
    }
    if (ctx.store.connection == .ready and ctx.now_ms - loading_since < 8000) anim.every(60);
    d.endRegion(ctx, rw.y, rw.r.x);
}

/// Painel de perfil numa DM com uma pessoa.
fn dmProfile(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, uid: types.Id, tty: bool) void {
    const u = ctx.store.user(uid) orelse return;
    const fam = ctx.familyFor(n);
    qa.mark(r, "dm-profile", .{});
    const dl = d.beginRegion(ctx, "##dm-profile", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var buf: [96]u8 = undefined;
    if (tty) {
        var y = o.y + 6;
        const fs = ctx.th.font_size - 1;
        for ([_][]const u8{
            std.fmt.bufPrint(buf[0..48], "@{s}", .{u.name}) catch "",
            std.fmt.bufPrint(buf[48..], "{s} {s}", .{ w.statusGlyph(u.status), @tagName(u.status) }) catch "",
        }) |t| {
            d.text(dl, fam.get(.bold), fs, r.x + 10, y, ctx.col(.text), t);
            y += 20;
        }
        if (u.activity) |a| _ = d.textClipped(dl, fam.get(.regular), fs, r.x + 10, y, ctx.col(.muted), a, r.w - 20);
        return d.endRegion(ctx, y + 24, r.x);
    }
    // Faixa colorida, avatar grande, nome, status e atividade.
    const band: d.Rect = .{ .x = r.x, .y = o.y, .w = r.w, .h = 110 };
    const col = ctx.th.role(u.role);
    c.ImDrawList_AddRectFilledMultiColor(dl, d.v(band.x, band.y), d.v(band.right(), band.bottom()), col.u(), col.mix(ctx.col(.accent), 0.5).u(), col.mix(ctx.col(.sidebar), 0.4).u(), col.mix(ctx.col(.sidebar), 0.4).u());
    d.circle(dl, r.x + 56, band.bottom(), 46, ctx.col(.sidebar));
    w.avatar(ctx, dl, r.x + 56, band.bottom(), 80, uid, .circle, ctx.col(.sidebar), 1);
    var y = band.bottom() + 54;
    _ = d.textClipped(dl, fam.get(.bold), 20, r.x + 16, y, ctx.col(.text), u.name, r.w - 32);
    y += 30;
    d.circle(dl, r.x + 21, y + 8, 5, w.statusColor(ctx, u.status));
    d.text(dl, fam.get(.medium), 13, r.x + 32, y, ctx.col(.muted), switch (u.status) {
        .online => "Online",
        .idle => i18n.tr("Ausente", "Idle"),
        .dnd => i18n.tr("Não perturbe", "Do Not Disturb"),
        .offline => "Offline",
    });
    y += 30;
    const card: d.Rect = .{ .x = r.x + 12, .y = y, .w = r.w - 24, .h = if (u.activity != null) 124 else 70 };
    d.rect(dl, card, ctx.col(.rail).alpha(0.7), ctx.th.radius + 2);
    var cy = card.y + 12;
    if (u.activity) |a| {
        d.text(dl, fam.get(.bold), 11.5, card.x + 12, cy, ctx.col(.muted), i18n.tr("ATIVIDADE", "ACTIVITY"));
        cy += 18;
        _ = d.textClipped(dl, fam.get(.medium), 14, card.x + 12, cy, ctx.col(.text), a, card.w - 24);
        cy += 34;
    }
    d.text(dl, fam.get(.bold), 11.5, card.x + 12, cy, ctx.col(.muted), i18n.tr("NO DISCORD DESDE", "MEMBER SINCE"));
    cy += 18;
    d.text(dl, fam.get(.regular), 14, card.x + 12, cy, ctx.col(.text), w.since(&buf, uid));
    d.endRegion(ctx, card.bottom() + 20, r.x);
}

fn memberClick(ctx: *d.Ctx, hb: d.Hit, uid: types.Id, rr: d.Rect) void {
    if (hb.clicked) ctx.popup(.{ .profile = .{ .user = uid, .x = rr.x - 330, .y = rr.y } });
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

// --- Barra de status --------------------------------------------------------

const Item = enum { conn, ping, ram, frame, voice, theme, keys, clock, spacer };

pub fn statusBar(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const variant = d.pstr(n, "variant", "pills");
    const tty = std.mem.eql(u8, variant, "tty");
    const pills = std.mem.eql(u8, variant, "pills");
    const items = d.pstr(n, "items", "conn ping ram voice spacer theme keys clock");
    const fs: f32 = if (tty) ctx.th.font_size - 2 else 13;
    const dl = ctx.dl;

    // Primeiro mede, para alinhar o que vem depois do `spacer` à direita.
    var segs: [16]struct { item: Item, text: []const u8, color: d.Rgba, w: f32, bufi: usize } = undefined;
    var bufs: [16][64]u8 = undefined;
    var count: usize = 0;
    var spacer_at: ?usize = null;
    var tok = std.mem.tokenizeScalar(u8, items, ' ');
    while (tok.next()) |name| {
        if (count >= segs.len) break;
        const item = std.meta.stringToEnum(Item, name) orelse continue;
        if (item == .spacer) {
            spacer_at = count;
            continue;
        }
        const b = &bufs[count];
        var color = ctx.col(.muted);
        const text: []const u8 = switch (item) {
            .conn => blk: {
                const conn = ctx.store.connection;
                color = switch (conn) {
                    .ready => ctx.col(.online),
                    .failed, .offline => ctx.col(.danger),
                    else => ctx.col(.idle),
                };
                break :blk switch (conn) {
                    .ready => if (ctx.store.demo) i18n.tr("● demonstração", "● demo") else i18n.tr("● conectado", "● connected"),
                    .connecting => i18n.tr("◌ conectando…", "◌ connecting…"),
                    .reconnecting => i18n.tr("◌ reconectando…", "◌ reconnecting…"),
                    .failed => i18n.tr("✕ falhou", "✕ failed"),
                    .offline => "○ offline",
                };
            },
            .ping => std.fmt.bufPrint(b, "⌁ {d} ms", .{ctx.store.latency_ms}) catch "",
            .ram => blk: {
                color = ctx.col(.accent).mix(ctx.col(.text), 0.3);
                @atomicStore(bool, &ctx.stats.ram_seen, true, .monotonic);
                break :blk std.fmt.bufPrint(b, "▣ {d}.{d} MB", .{ ctx.stats.ram_kb / 1024, (ctx.stats.ram_kb % 1024) * 10 / 1024 }) catch "";
            },
            .frame => i18n.fmt(b, "⚡ {d}.{d:0>2} ms/quadro", "⚡ {d}.{d:0>2} ms/frame", .{ ctx.stats.frame_us / 1000, (ctx.stats.frame_us % 1000) / 10 }),
            .voice => blk: {
                const vc = ctx.st.voice orelse continue;
                const cs = ctx.store.channel(vc) orelse continue;
                color = ctx.col(.online);
                break :blk std.fmt.bufPrint(b, "🔊 {s}{s}", .{ cs.info.name, if (ctx.st.muted) i18n.tr(" (mudo)", " (muted)") else "" }) catch "";
            },
            .theme => std.fmt.bufPrint(b, "◆ {s}", .{ctx.theme_name}) catch "",
            .keys => i18n.tr("Ctrl+K comandos · F2 tema", "Ctrl+K commands · F2 theme"),
            .clock => w.clock(b, @divTrunc(ctx.now_ms, 1000)),
            .spacer => unreachable,
        };
        const font = fam.get(if (item == .conn or item == .theme) .semibold else .medium);
        segs[count] = .{ .item = item, .text = text, .color = color, .w = d.width(font, fs, text), .bufi = count };
        count += 1;
    }

    const pad: f32 = if (pills) 10 else 8;
    const gap: f32 = if (pills) 6 else if (tty) 0 else 14;
    var right_w: f32 = 0;
    if (spacer_at) |sa| for (segs[sa..count]) |s| {
        right_w += s.w + pad * 2 + gap;
    };
    var x = r.x + (if (pills) @as(f32, 6) else 8);
    for (segs[0..count], 0..) |s, i| {
        if (spacer_at) |sa| if (i == sa) {
            x = @max(x, r.right() - right_w - (if (pills) @as(f32, 0) else 4));
        };
        const font = fam.get(if (s.item == .conn or s.item == .theme) .semibold else .medium);
        const sr: d.Rect = .{ .x = x, .y = r.y + (if (pills) @as(f32, 4) else 0), .w = s.w + pad * 2, .h = r.h - (if (pills) @as(f32, 8) else 0) };
        if (s.item == .theme) {
            const hb = d.hit(ctx, i, sr);
            qa.mark(sr, "status-theme", .{});
            if (hb.clicked) ctx.act(.{ .next_theme = 1 });
            if (hb.hovered) d.rect(dl, sr, ctx.col(.hover), if (pills) sr.h / 2 else 0);
        }
        if (pills) {
            d.rect(dl, sr, ctx.col(.text).alpha(0.06), sr.h / 2);
        } else if (tty) {
            // Segmentos estilo tmux: o primeiro e o tema em destaque.
            const hl = s.item == .conn or s.item == .theme;
            if (hl) d.rect(dl, sr, ctx.col(.accent), 0);
            d.text(dl, font, fs, sr.x + pad, d.centerY(sr, fs), if (hl) ctx.col(.accent_text) else s.color, s.text);
            if (!hl and i + 1 < count) d.text(dl, font, fs, sr.right() - 3, d.centerY(sr, fs), ctx.col(.faint), "│");
            x += sr.w + gap;
            continue;
        }
        d.text(dl, font, fs, sr.x + pad, d.centerY(sr, fs), s.color, s.text);
        x += sr.w + gap;
    }
}
