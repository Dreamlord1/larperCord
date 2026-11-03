//! Tela de amigos (Mensagens diretas → Amigos): ocupa o lugar do `header`,
//! das `messages` e da `member-list` enquanto está aberta.
//!   Online · Todos · Pendentes · Bloqueados
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

const Tab = enum(u8) { online, all, pending, blocked };

fn tabLabel(t: Tab) []const u8 {
    return switch (t) {
        .online => "Online",
        .all => i18n.tr("Todos", "All"),
        .pending => i18n.tr("Pendentes", "Pending"),
        .blocked => i18n.tr("Bloqueados", "Blocked"),
    };
}

fn wanted(t: Tab, kind: types.Relationship, status: types.Status) bool {
    return switch (t) {
        .online => kind == .friend and status != .offline,
        .all => kind == .friend,
        .pending => kind == .incoming or kind == .outgoing,
        .blocked => kind == .blocked,
    };
}

/// Quem aparece na aba, em ordem alfabética (pedidos recebidos primeiro).
fn collect(ctx: *const d.Ctx, t: Tab, out: []Id) []Id {
    var n: usize = 0;
    var it = ctx.store.relationships.iterator();
    while (it.next()) |e| {
        if (n == out.len) break;
        const u = ctx.store.user(e.key_ptr.*) orelse continue;
        if (!wanted(t, e.value_ptr.*, u.status)) continue;
        out[n] = u.id;
        n += 1;
    }
    const Sort = struct {
        ctx: *const d.Ctx,
        fn lt(s: @This(), a: Id, b: Id) bool {
            const ka = s.ctx.store.relationship(a) == .incoming;
            const kb = s.ctx.store.relationship(b) == .incoming;
            if (ka != kb) return ka;
            const na = s.ctx.store.user(a).?.name;
            const nb = s.ctx.store.user(b).?.name;
            return std.ascii.lessThanIgnoreCase(na, nb);
        }
    };
    std.mem.sort(Id, out[0..n], Sort{ .ctx = ctx }, Sort.lt);
    return out[0..n];
}

fn incomingCount(ctx: *const d.Ctx) usize {
    var n: usize = 0;
    var it = ctx.store.relationships.valueIterator();
    while (it.next()) |k| {
        if (k.* == .incoming) n += 1;
    }
    return n;
}

// --- Topo --------------------------------------------------------------------

pub fn header(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const dl = ctx.dl;
    const tty = d.is(n, "variant", "tty", "discord");
    const fs: f32 = if (tty) ctx.th.font_size - 1 else 15;
    var x = r.x + 16;
    if (tty) {
        d.text(dl, fam.get(.bold), fs, r.x + 6, d.centerY(r, fs), ctx.col(.accent), i18n.tr("─ amigos ─", "─ friends ─"));
        x = r.x + 6 + d.width(fam.get(.bold), fs, i18n.tr("─ amigos ─", "─ friends ─")) + 12;
    } else {
        icons.members(dl, x + 10, r.y + r.h / 2, ctx.col(.muted).u());
        d.text(dl, fam.get(.semibold), 16, x + 26, d.centerY(r, 16), ctx.col(.text), i18n.tr("Amigos", "Friends"));
        x += 26 + d.width(fam.get(.semibold), 16, i18n.tr("Amigos", "Friends")) + 16;
        d.rect(dl, .{ .x = x, .y = r.y + r.h / 2 - 10, .w = 1, .h = 20 }, ctx.col(.border).mix(ctx.col(.text), 0.05), 0);
        x += 14;
    }
    const pending = incomingCount(ctx);
    for ([_]Tab{ .online, .all, .pending, .blocked }) |t| {
        const sel = ctx.st.friends_tab == @intFromEnum(t);
        var lb: [48]u8 = undefined;
        const label = if (tty) std.fmt.bufPrint(&lb, "[{s}]", .{tabLabel(t)}) catch "" else tabLabel(t);
        const font = fam.get(if (sel) .semibold else .medium);
        const tw = d.width(font, fs, label);
        const extra: f32 = if (t == .pending and pending > 0) 24 else 0;
        const tr: d.Rect = .{ .x = x, .y = r.y + r.h / 2 - 14, .w = tw + 20 + extra, .h = 28 };
        if (tr.right() > r.right() - 8) break;
        const hb = d.hit(ctx, 40 + @as(usize, @intFromEnum(t)), tr);
        qa.mark(tr, "friends-tab:{s}", .{@tagName(t)});
        if (hb.clicked) ctx.st.friends_tab = @intFromEnum(t);
        const k = anim.to(anim.id("ftab", @intFromEnum(t)), if (sel) 1 else if (hb.hovered) 0.5 else 0, 22);
        if (tty) {
            if (sel) d.rect(dl, tr, ctx.col(.accent), 0);
        } else if (k > 0.01) d.rect(dl, tr, ctx.col(.selected).alpha(k), ctx.th.radius);
        const ink = if (tty and sel) ctx.col(.accent_text) else if (sel) ctx.col(.text) else ctx.col(.muted).mix(ctx.col(.text), k);
        d.text(dl, font, fs, tr.x + 10, d.centerY(tr, fs), ink, label);
        if (extra > 0) {
            var b: [8]u8 = undefined;
            const ct = std.fmt.bufPrint(&b, "{d}", .{pending}) catch "";
            const cw = d.width(fam.get(.bold), 11, ct);
            const br: d.Rect = .{ .x = tr.x + 14 + tw, .y = tr.y + 5, .w = @max(18, cw + 10), .h = 18 };
            d.rect(dl, br, ctx.col(.danger), 9);
            d.text(dl, fam.get(.bold), 11, br.x + (br.w - cw) / 2, d.centerY(br, 11), d.Rgba.white, ct);
        }
        x = tr.right() + 6;
    }
    if (d.pflag(n, "divider", true) and !tty) d.line(dl, r.x, r.bottom() - 0.5, r.right(), r.bottom() - 0.5, ctx.col(.border), 1);
}

// --- Lista -------------------------------------------------------------------

pub fn page(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const tab: Tab = @enumFromInt(@min(ctx.st.friends_tab, 3));
    var ids_buf: [512]Id = undefined;
    const ids = collect(ctx, tab, &ids_buf);
    const dl = d.beginRegion(ctx, "##friends", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 18;
    const x = r.x + 24;
    const rw = @min(r.w - 48, 900);

    var hb_buf: [64]u8 = undefined;
    const head = switch (tab) {
        .online => i18n.fmt(&hb_buf, "ONLINE — {d}", "ONLINE — {d}", .{ids.len}),
        .all => i18n.fmt(&hb_buf, "TODOS OS AMIGOS — {d}", "ALL FRIENDS — {d}", .{ids.len}),
        .pending => i18n.fmt(&hb_buf, "PENDENTES — {d}", "PENDING — {d}", .{ids.len}),
        .blocked => i18n.fmt(&hb_buf, "BLOQUEADOS — {d}", "BLOCKED — {d}", .{ids.len}),
    };
    d.text(dl, fam.get(.semibold), 12, x, y, ctx.col(.muted), head);
    y += 28;

    if (ids.len == 0) {
        const msg = switch (tab) {
            .online => i18n.tr("Ninguém online agora.", "No one's around right now."),
            .all => if (ctx.store.relationships.count() == 0) i18n.tr("Sua lista de amigos aparece aqui.", "Your friends list shows up here.") else i18n.tr("Nenhum amigo ainda.", "No friends yet."),
            .pending => i18n.tr("Nenhum pedido de amizade pendente.", "There are no pending friend requests."),
            .blocked => i18n.tr("Você não bloqueou ninguém.", "You haven't blocked anyone."),
        };
        const tw = d.width(fam.get(.medium), 15, msg);
        d.text(dl, fam.get(.medium), 15, r.x + (r.w - tw) / 2, r.y + r.h * 0.38, ctx.col(.faint), msg);
        d.endRegion(ctx, y, r.x);
        return;
    }

    for (ids) |uid| {
        const u = ctx.store.user(uid) orelse continue;
        // Fora da tela: só ocupa o espaço.
        if (y + 62 < r.y or y > r.bottom()) {
            y += 62;
            continue;
        }
        const kind = ctx.store.relationship(uid);
        const rr: d.Rect = .{ .x = x - 10, .y = y, .w = rw + 20, .h = 62 };
        d.line(dl, rr.x + 10, rr.y, rr.right() - 10, rr.y, ctx.col(.border), 1);
        // A linha fica embaixo dos botões: eles ganham o clique.
        const hb = d.hitUnder(ctx, @truncate(uid), rr);
        qa.mark(rr, "friend:{d}", .{uid});
        const k = anim.to(anim.id("friend", uid), if (hb.hovered) 1 else 0, 24);
        if (k > 0.01) d.rect(dl, rr.inset(0, 1), ctx.col(.hover).alpha(k), ctx.th.radius + 2);
        w.avatar(ctx, dl, rr.x + 30, rr.y + 31, 36, uid, .circle, if (k > 0.5) ctx.col(.hover).mix(ctx.col(.surface), 0.5) else ctx.col(.surface), 1);
        d.text(dl, fam.get(.semibold), 15, rr.x + 58, rr.y + 12, ctx.col(.text), u.name);
        var sb: [64]u8 = undefined;
        const sub: []const u8 = switch (kind) {
            .incoming => i18n.tr("Pedido de amizade recebido", "Incoming Friend Request"),
            .outgoing => i18n.tr("Pedido de amizade enviado", "Outgoing Friend Request"),
            .blocked => i18n.tr("Bloqueado", "Blocked"),
            else => u.activity orelse statusText(u.status, &sb),
        };
        _ = d.textClipped(dl, fam.get(.regular), 13, rr.x + 58, rr.y + 33, ctx.col(.muted), sub, rr.w - 200);

        // Botões redondos à direita.
        var bx = rr.right() - 26;
        const Btn = struct { glyph: []const u8, tip: []const u8, act: enum { message, accept, remove }, danger: bool = false, good: bool = false };
        var btns: [2]Btn = undefined;
        var nb: usize = 0;
        switch (kind) {
            .friend => {
                btns[0] = .{ .glyph = "msg", .tip = i18n.tr("Mensagem", "Message"), .act = .message };
                nb = 1;
            },
            .incoming => {
                btns[0] = .{ .glyph = "x", .tip = i18n.tr("Recusar", "Ignore"), .act = .remove, .danger = true };
                btns[1] = .{ .glyph = "ok", .tip = i18n.tr("Aceitar", "Accept"), .act = .accept, .good = true };
                nb = 2;
            },
            .outgoing => {
                btns[0] = .{ .glyph = "x", .tip = i18n.tr("Cancelar pedido", "Cancel"), .act = .remove, .danger = true };
                nb = 1;
            },
            .blocked => {
                btns[0] = .{ .glyph = "x", .tip = i18n.tr("Desbloquear", "Unblock"), .act = .remove };
                nb = 1;
            },
            .none => {},
        }
        var on_button = false;
        for (btns[0..nb], 0..) |b, i| {
            const br: d.Rect = .{ .x = bx - 18, .y = rr.y + 13, .w = 36, .h = 36 };
            const bh = d.hit(ctx, @as(usize, @truncate(uid)) *% 4 +% i +% 1, br);
            qa.mark(br, "friend-{s}:{d}", .{ @tagName(b.act), uid });
            if (bh.hovered) on_button = true;
            d.tip(ctx, br, b.tip, bh.hovered);
            const bg = ctx.col(.rail).mix(ctx.col(.elevated), if (k > 0.5) 0.6 else 0.3);
            d.circle(dl, br.x + 18, br.y + 18, 18, bg);
            const ink = if (bh.hovered and b.danger) ctx.col(.danger) else if (bh.hovered and b.good) ctx.col(.online) else if (bh.hovered) ctx.col(.text) else ctx.col(.muted);
            const cx = br.x + 18;
            const cy = br.y + 18;
            if (std.mem.eql(u8, b.glyph, "x")) {
                d.line(dl, cx - 5, cy - 5, cx + 5, cy + 5, ink, 2);
                d.line(dl, cx + 5, cy - 5, cx - 5, cy + 5, ink, 2);
            } else if (std.mem.eql(u8, b.glyph, "ok")) {
                d.line(dl, cx - 6, cy, cx - 2, cy + 5, ink, 2.2);
                d.line(dl, cx - 2, cy + 5, cx + 6, cy - 5, ink, 2.2);
            } else {
                // Balão de conversa.
                d.rect(dl, .{ .x = cx - 8, .y = cy - 6, .w = 16, .h = 11 }, ink, 4);
                c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5, cy + 4), d.v(cx, cy + 4), d.v(cx - 6, cy + 9), ink.u());
            }
            if (bh.clicked) switch (b.act) {
                .message => ctx.act(.{ .open_dm = uid }),
                .accept => ctx.act(.{ .accept_friend = uid }),
                .remove => ctx.act(.{ .remove_relationship = uid }),
            };
            bx -= 46;
        }
        // Clicar na linha de um amigo abre a conversa.
        if (hb.clicked and !on_button and kind == .friend) ctx.act(.{ .open_dm = uid });
        if (hb.right) ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
        y += 62;
    }
    d.endRegion(ctx, y + 20, r.x);
}

fn statusText(s: types.Status, buf: []u8) []const u8 {
    _ = buf;
    return switch (s) {
        .online => "Online",
        .idle => i18n.tr("Ausente", "Idle"),
        .dnd => i18n.tr("Não perturbe", "Do Not Disturb"),
        .offline => "Offline",
    };
}

// --- "Ativos agora" (no lugar da lista de membros) -------------------------------

pub fn activeNow(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const fam = ctx.familyFor(n);
    const dl = d.beginRegion(ctx, "##active-now", r, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var y = o.y + 18;
    d.text(dl, fam.get(.bold), 18, r.x + 16, y, ctx.col(.text), i18n.tr("Ativos agora", "Active Now"));
    y += 38;
    var shown: usize = 0;
    var ids_buf: [256]Id = undefined;
    for (collect(ctx, .online, &ids_buf)) |uid| {
        const u = ctx.store.user(uid) orelse continue;
        const act = u.activity orelse continue;
        const card: d.Rect = .{ .x = r.x + 16, .y = y, .w = r.w - 32, .h = 64 };
        const hb = d.hit(ctx, @truncate(uid), card);
        qa.mark(card, "active:{d}", .{uid});
        if (hb.clicked) ctx.popup(.{ .profile = .{ .user = uid, .x = card.x - 330, .y = card.y } });
        d.rect(dl, card, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.5 else 0.2), ctx.th.radius + 2);
        d.border(dl, card, ctx.col(.border), ctx.th.radius + 2, 1);
        w.avatar(ctx, dl, card.x + 26, card.y + 32, 32, uid, .circle, ctx.col(.rail), 1);
        _ = d.textClipped(dl, fam.get(.semibold), 14, card.x + 50, card.y + 13, ctx.col(.text), u.name, card.w - 60);
        _ = d.textClipped(dl, fam.get(.regular), 12, card.x + 50, card.y + 34, ctx.col(.muted), act, card.w - 60);
        y += 72;
        shown += 1;
    }
    if (shown == 0) {
        const t = i18n.tr("Está tudo quieto por aqui…", "It's quiet for now…");
        d.text(dl, fam.get(.semibold), 15, r.x + 16, y, ctx.col(.text), t);
        y += 24;
        // Duas linhas curtas (a coluna é estreita).
        for ([_][]const u8{ i18n.tr("Quando um amigo jogar ou ouvir", "When a friend starts an activity,"), i18n.tr("alguma coisa, aparece aqui.", "it'll show up here.") }) |line| {
            _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 16, y, ctx.col(.muted), line, r.w - 32);
            y += 18;
        }
    }
    d.endRegion(ctx, y + 12, r.x);
}
