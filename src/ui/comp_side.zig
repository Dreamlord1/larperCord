//! `member-list` e `status-bar`.
//!
//! member-list: variant = discord | tty
//! status-bar:  variant = pills | tty | plain
//!              items = "conn ping ram frame voice theme keys clock"
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");

pub fn memberList(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const tty = d.is(n, "variant", "tty", "discord");
    const dl = d.beginRegion(ctx, "##members", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + (if (tty) @as(f32, 6) else 20);
    const fs = ctx.th.font_size;

    var online: usize = 0;
    var it = ctx.store.users.valueIterator();
    while (it.next()) |u| {
        if (u.status != .offline) online += 1;
    }
    var buf: [64]u8 = undefined;

    for ([_]bool{ true, false }) |want_online| {
        const count = if (want_online) online else ctx.store.users.count() - online;
        const lbl = std.fmt.bufPrint(&buf, "{s} — {d}", .{ if (want_online) "ONLINE" else "OFFLINE", count }) catch "";
        d.text(dl, fam.get(.semibold), if (tty) fs - 2 else 12, r.x + (if (tty) @as(f32, 10) else 16), y, ctx.col(.faint).mix(ctx.col(.muted), 0.3), lbl);
        y += if (tty) @as(f32, 20) else 22;

        // Ordem estável pelo ID.
        var ids: [64]types.Id = undefined;
        var nids: usize = 0;
        var uit = ctx.store.users.valueIterator();
        while (uit.next()) |u| {
            if ((u.status != .offline) != want_online or nids >= ids.len) continue;
            ids[nids] = u.id;
            nids += 1;
        }
        std.mem.sort(types.Id, ids[0..nids], {}, std.sort.asc(types.Id));

        for (ids[0..nids]) |uid| {
            const u = ctx.store.user(uid).?;
            const name_col = ctx.th.role(u.role).mix(ctx.col(.text), 0.25);
            if (tty) {
                const rr: d.Rect = .{ .x = r.x + 4, .y = y, .w = r.w - 8, .h = 20 };
                const hb = d.hit(ctx, @intCast(uid), rr);
                if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 0);
                d.text(dl, fam.get(.regular), fs - 1, rr.x + 6, d.centerY(rr, fs - 1), w.statusColor(ctx, u.status), w.statusGlyph(u.status));
                _ = d.textClipped(dl, fam.get(if (want_online) .bold else .regular), fs - 1, rr.x + 24, d.centerY(rr, fs - 1), if (want_online) name_col else ctx.col(.faint), u.name, rr.w - 30);
                y += 20;
                continue;
            }
            const rr: d.Rect = .{ .x = r.x + 8, .y = y, .w = r.w - 16, .h = 42 };
            const hb = d.hit(ctx, @intCast(uid), rr);
            const k = anim.to(anim.id("member", uid), if (hb.hovered) 1 else 0, 24);
            d.rect(dl, rr, ctx.col(.hover).alpha(k * 1.4), ctx.th.radius);
            const alpha: f32 = if (want_online) 1 else 0.38 + 0.4 * k;
            w.avatar(ctx, dl, rr.x + 24, rr.y + 21, 32, uid, .circle, if (want_online) ctx.col(.sidebar) else null, alpha);
            if (u.activity != null and want_online) {
                _ = d.textClipped(dl, fam.get(.medium), 15, rr.x + 48, rr.y + 3, name_col.alpha(alpha), u.name, rr.w - 56);
                _ = d.textClipped(dl, fam.get(.regular), 12, rr.x + 48, rr.y + 22, ctx.col(.muted).alpha(alpha), u.activity.?, rr.w - 56);
            } else {
                _ = d.textClipped(dl, fam.get(.medium), 15, rr.x + 48, d.centerY(rr, 15), name_col.alpha(alpha), u.name, rr.w - 56);
            }
            y += 44;
        }
        y += if (tty) @as(f32, 8) else 16;
    }
    d.endRegion(ctx, y, r.x);
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
                color = if (ctx.store.ready) ctx.col(.online) else ctx.col(.idle);
                break :blk if (ctx.store.ready) "● conectado" else "◌ conectando…";
            },
            .ping => std.fmt.bufPrint(b, "⌁ {d} ms", .{ctx.store.latency_ms}) catch "",
            .ram => blk: {
                color = ctx.col(.accent).mix(ctx.col(.text), 0.3);
                break :blk std.fmt.bufPrint(b, "▣ {d}.{d} MB", .{ ctx.stats.ram_kb / 1024, (ctx.stats.ram_kb % 1024) * 10 / 1024 }) catch "";
            },
            .frame => std.fmt.bufPrint(b, "⚡ {d}.{d:0>2} ms/quadro", .{ ctx.stats.frame_us / 1000, (ctx.stats.frame_us % 1000) / 10 }) catch "",
            .voice => blk: {
                const vc = ctx.st.voice orelse continue;
                const cs = ctx.store.channel(vc) orelse continue;
                color = ctx.col(.online);
                break :blk std.fmt.bufPrint(b, "🔊 {s}{s}", .{ cs.info.name, if (ctx.st.muted) " (mudo)" else "" }) catch "";
            },
            .theme => std.fmt.bufPrint(b, "◆ {s}", .{ctx.theme_name}) catch "",
            .keys => "Ctrl+K comandos · F2 tema",
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
