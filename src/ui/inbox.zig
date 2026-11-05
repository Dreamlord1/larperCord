//! Caixa de entrada (Ctrl+I ou o botão do cabeçalho): as DMs e menções não
//! lidas de todos os servidores, agrupadas por canal, com prévia; clicar
//! abre o canal e rola até a mensagem (se ela estiver carregada). A aba
//! "Menções" mostra as recentes que o Discord guarda, mesmo as já lidas.
//! É um popup: clicar fora ou Esc fecha. O modelo vem de core/inbox.zig e só
//! é refeito quando algo que ele mostra muda.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const core = @import("../core/inbox.zig");
const types = @import("../core/types.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;
const Id = types.Id;

var model: core.Model = .{};
var mentions: core.Mentions = .{};
/// Quantas vezes a aba "Não lidas" foi refeita (o QA confere que parada não refaz).
pub var rebuilds: u32 = 0;

fn refresh(ctx: *d.Ctx) void {
    const sig = core.signature(ctx.store, ctx.st.muted_channels.count());
    if (model.built and sig == model.sig) return;
    core.build(ctx.store, &ctx.st.muted_channels, &ctx.st.filtros, &model);
    model.sig = sig;
    rebuilds += 1;
}

/// Quantos canais/servidores estão na aba "Não lidas" (o número do botão).
pub fn unreadCount(ctx: *d.Ctx) usize {
    refresh(ctx);
    return model.n;
}

// --- Peças compartilhadas com as mensagens salvas --------------------------

/// O painel fica no canto de cima à direita, abaixo do cabeçalho.
pub fn panelRect(ctx: *const d.Ctx) d.Rect {
    const wd = @min(520, ctx.win.w - 24);
    const h = @min(660, ctx.win.h - 72);
    return .{ .x = @max(ctx.win.x + 12, ctx.win.right() - wd - 16), .y = ctx.win.y + 56, .w = wd, .h = h };
}

pub fn panelFrame(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect) void {
    const radius = @max(ctx.th.radius + 2, 6);
    d.shadow(dl, r, radius, 18, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
}

/// Botão de texto em pílula. `r` já vem com o tamanho de `buttonWidth`.
pub fn button(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, label: []const u8, danger: bool) bool {
    const hb = d.hit(ctx, id, r);
    const base = if (danger) ctx.col(.danger) else ctx.col(.accent);
    d.rect(dl, r, if (hb.hovered) base else ctx.col(.hover), r.h / 2);
    const tc = if (hb.hovered) (if (danger) d.Rgba.white else ctx.col(.accent_text)) else if (danger) ctx.col(.danger) else ctx.col(.text);
    d.text(dl, ctx.ui.get(.semibold), 13, r.x + 12, d.centerY(r, 13), tc, label);
    return hb.clicked;
}

pub fn buttonWidth(ctx: *const d.Ctx, label: []const u8) f32 {
    return d.width(ctx.ui.get(.semibold), 13, label) + 24;
}

/// Texto quebrado por palavra em até `max_lines` linhas (a última corta com
/// "…"). Com `dl` null só mede. Retorna a altura usada.
pub fn wrapText(dl: ?*c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, max_w: f32, text: []const u8, max_lines: usize, color: d.Rgba) f32 {
    const lh = size * d.text_scale * 1.38;
    const space = d.width(font, size, " ");
    var lines: usize = 0;
    var start: ?usize = null;
    var end: usize = 0;
    var cur: f32 = 0;
    var it = std.mem.tokenizeAny(u8, text, " \n");
    while (it.next()) |word| {
        const off = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
        const ww = d.width(font, size, word);
        if (start == null) {
            start = off;
            end = off + word.len;
            cur = ww;
            continue;
        }
        if (cur + space + ww <= max_w) {
            end = off + word.len;
            cur += space + ww;
            continue;
        }
        // Última linha permitida: o resto vai nela, cortado.
        if (lines + 1 == max_lines) {
            if (dl) |l| _ = d.textClipped(l, font, size, x, y + @as(f32, @floatFromInt(lines)) * lh, color, text[start.?..], max_w);
            return @as(f32, @floatFromInt(lines + 1)) * lh;
        }
        if (dl) |l| _ = d.textClipped(l, font, size, x, y + @as(f32, @floatFromInt(lines)) * lh, color, text[start.?..end], max_w);
        lines += 1;
        start = off;
        end = off + word.len;
        cur = ww;
    }
    if (start) |s| {
        if (dl) |l| _ = d.textClipped(l, font, size, x, y + @as(f32, @floatFromInt(lines)) * lh, color, text[s..end], max_w);
        lines += 1;
    }
    return @as(f32, @floatFromInt(lines)) * lh;
}

/// Prévia de uma mensagem: o texto (menções resolvidas) ou o que ela tem.
pub fn previewText(ctx: *const d.Ctx, buf: []u8, m: *const StoredMessage) []const u8 {
    const t = core.preview(buf, ctx.store, m);
    if (t.len > 0) return t;
    if (m.msg.attachments.len > 0) return i18n.fmt(buf, "📎 {s}", "📎 {s}", .{m.msg.attachments[0].filename});
    if (m.msg.embeds.len > 0 and m.msg.embeds[0].title.len > 0) return i18n.fmt(buf, "🔗 {s}", "🔗 {s}", .{m.msg.embeds[0].title});
    // Bot só com componentes: o primeiro texto, sem as marcas.
    var k: usize = 0;
    for (m.msg.embeds) |*e| {
        k += 1 + e.fields.len;
        for (e.blocks) |*b| {
            if (b.kind == .text and k < m.embed_spans.len) {
                const first = core.previewSpans(buf, ctx.store, m.embed_spans[k]);
                if (first.len > 0) return first;
            }
            k += 1;
        }
    }
    return i18n.tr("(sem texto)", "(no text)");
}

/// "#canal · Servidor", "@pessoa" ou o nome do grupo.
pub fn channelLabel(buf: []u8, ctx: *const d.Ctx, channel: Id) []const u8 {
    const cs = ctx.store.channel(channel) orelse return i18n.tr("canal desconhecido", "unknown channel");
    if (cs.info.guild == 0) return std.fmt.bufPrint(buf, "{s}{s}", .{ if (cs.info.group) "" else "@", cs.info.name }) catch cs.info.name;
    const g = ctx.store.guild(cs.info.guild);
    return std.fmt.bufPrint(buf, "#{s}  ·  {s}", .{ cs.info.name, if (g) |x| x.name else "" }) catch cs.info.name;
}

/// Abre o canal e vai até a mensagem (se ela não estiver carregada, a lista
/// busca em volta dela).
pub fn openMessage(ctx: *d.Ctx, channel: Id, id: Id) void {
    popup.close(ctx);
    const cs = ctx.store.channel(channel) orelse
        return ctx.st.showToast(ctx.now_ms, true, "esse canal não está disponível nesta conta", "that channel isn't available on this account", .{});
    if (cs.info.kind != .text) return;
    ctx.act(.{ .open_message = .{ .channel = channel, .id = id } });
}

fn empty(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y: f32, title: []const u8, sub: []const u8) f32 {
    const fam = ctx.ui;
    const cy = y + 70;
    const tw = d.width(fam.get(.bold), 16, title);
    d.text(dl, fam.get(.bold), 16, body.x + (body.w - tw) / 2, cy, ctx.col(.text), title);
    const sw = d.width(fam.get(.regular), 13.5, sub);
    d.text(dl, fam.get(.regular), 13.5, body.x + @max(12, (body.w - sw) / 2), cy + 26, ctx.col(.muted), sub);
    qa.mark(.{ .x = body.x, .y = cy, .w = body.w, .h = 44 }, "inbox-empty", .{});
    return cy + 60;
}

/// Uma mensagem da lista: avatar, nome, hora e a prévia numa linha.
fn messageRow(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, hit_id: usize, m: *const StoredMessage, guild: Id, mention: bool) bool {
    const hb = d.hit(ctx, hit_id, r);
    if (hb.hovered) d.rect(dl, r, ctx.col(.hover), @max(ctx.th.radius - 2, 3));
    if (mention) d.rect(dl, .{ .x = r.x, .y = r.y + 6, .w = 2, .h = r.h - 12 }, ctx.col(.mention), 1);
    const fam = ctx.ui;
    w.avatar(ctx, dl, r.x + 22, r.y + r.h / 2, 28, m.msg.author, .circle, null, 1);
    const name = if (ctx.store.user(m.msg.author)) |u| u.name else "?";
    const nx = r.x + 44;
    const nw = d.textClipped(dl, fam.get(.semibold), 14, nx, r.y + 5, w.nameColor(ctx, guild, m.msg.author), name, r.w * 0.5);
    var tb: [48]u8 = undefined;
    d.text(dl, fam.get(.regular), 11.5, nx + nw + 8, r.y + 7.5, ctx.col(.faint), w.stamp(&tb, m.msg.timestamp, @divTrunc(ctx.now_ms, 1000)));
    var pb: [240]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 13.5, nx, r.y + 24, ctx.col(.text).mix(ctx.col(.muted), 0.25), previewText(ctx, &pb, m), r.right() - nx - 10);
    return hb.clicked;
}

/// Cabeçalho de um grupo: o canal (clicar abre) e, à direita, um ✓ para
/// marcar como lido (`read` = false na aba de menções).
fn groupHeader(ctx: *d.Ctx, dl: *c.ImDrawList, x: f32, y: f32, wd: f32, channel: Id, count_text: []const u8, read: bool) void {
    const fam = ctx.ui;
    const hr: d.Rect = .{ .x = x, .y = y, .w = wd - (if (read) @as(f32, 34) else 0), .h = 28 };
    const hb = d.hit(ctx, @truncate(channel *% 7 +% 1), hr);
    qa.mark(hr, "inbox-open:{d}", .{channel});
    if (hb.hovered) d.rect(dl, hr, ctx.col(.hover).alpha(0.6), @max(ctx.th.radius - 2, 3));
    var lb: [160]u8 = undefined;
    const label = channelLabel(&lb, ctx, channel);
    const cw = d.width(fam.get(.regular), 12, count_text);
    _ = d.textClipped(dl, fam.get(.bold), 13, x + 8, d.centerY(hr, 13), if (hb.hovered) ctx.col(.text) else ctx.col(.muted), label, hr.w - cw - 28);
    d.text(dl, fam.get(.regular), 12, hr.right() - cw - 8, d.centerY(hr, 12), ctx.col(.faint), count_text);
    if (hb.clicked) openMessage(ctx, channel, 0);
    if (read) {
        const rr: d.Rect = .{ .x = x + wd - 30, .y = y + 1, .w = 26, .h = 26 };
        const rh = d.hit(ctx, @truncate(channel *% 7 +% 2), rr);
        qa.mark(rr, "inbox-read:{d}", .{channel});
        if (rh.hovered) d.circle(dl, rr.x + 13, rr.y + 13, 13, ctx.col(.accent));
        const ic = if (rh.hovered) ctx.col(.accent_text) else ctx.col(.muted);
        d.line(dl, rr.x + 7.5, rr.y + 13.5, rr.x + 11.5, rr.y + 17.5, ic, 2);
        d.line(dl, rr.x + 11.5, rr.y + 17.5, rr.x + 18.5, rr.y + 9.5, ic, 2);
        d.tip(ctx, rr, i18n.tr("Marcar como lido", "Mark as read"), rh.hovered);
        if (rh.clicked) ctx.act(.{ .mark_read = channel });
    }
}

// --- Abas ----------------------------------------------------------------------

fn unreadList(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32) f32 {
    if (model.n == 0) return empty(ctx, dl, body, y0, i18n.tr("Tudo em dia!", "All caught up!"), i18n.tr("Nenhuma DM ou menção não lida.", "No unread DMs or mentions."));
    const fam = ctx.ui;
    const x = body.x + 10;
    const wd = body.w - 20;
    var y = y0;
    for (model.slice()) |*g| {
        var cb: [48]u8 = undefined;
        if (g.channel == 0) {
            // Menções que o Discord contou num servidor, sem nada carregado.
            const gd = ctx.store.guild(g.guild) orelse continue;
            const rr: d.Rect = .{ .x = x, .y = y, .w = wd - 34, .h = 40 };
            const hb = d.hit(ctx, @truncate(g.guild *% 7 +% 3), rr);
            qa.mark(rr, "inbox-guild:{d}", .{g.guild});
            if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), @max(ctx.th.radius - 2, 3));
            const ir: d.Rect = .{ .x = rr.x + 8, .y = rr.y + 6, .w = 28, .h = 28 };
            d.rect(dl, ir, ctx.th.role(gd.color).alpha(0.85), 14);
            const aw = d.width(fam.get(.bold), 11, gd.acronym);
            _ = d.textClipped(dl, fam.get(.bold), 11, ir.x + @max(2, (ir.w - aw) / 2), d.centerY(ir, 11), d.Rgba.white, gd.acronym, ir.w - 4);
            const t = i18n.fmt(&cb, "{d} menções em {s}", "{d} mentions in {s}", .{ g.total, gd.name });
            _ = d.textClipped(dl, fam.get(.semibold), 14, ir.right() + 10, rr.y + 4, ctx.col(.text), t, rr.right() - ir.right() - 16);
            d.text(dl, fam.get(.regular), 12, ir.right() + 10, rr.y + 22, ctx.col(.faint), i18n.tr("ainda não carregadas: clique para abrir o servidor", "not loaded yet: click to open the server"));
            if (hb.clicked) {
                popup.close(ctx);
                ctx.act(.{ .select_guild = g.guild });
            }
            const kr: d.Rect = .{ .x = x + wd - 30, .y = y + 7, .w = 26, .h = 26 };
            const kh = d.hit(ctx, @truncate(g.guild *% 7 +% 4), kr);
            qa.mark(kr, "inbox-read:{d}", .{g.guild});
            if (kh.hovered) d.circle(dl, kr.x + 13, kr.y + 13, 13, ctx.col(.accent));
            const ic = if (kh.hovered) ctx.col(.accent_text) else ctx.col(.muted);
            d.line(dl, kr.x + 7.5, kr.y + 13.5, kr.x + 11.5, kr.y + 17.5, ic, 2);
            d.line(dl, kr.x + 11.5, kr.y + 17.5, kr.x + 18.5, kr.y + 9.5, ic, 2);
            d.tip(ctx, kr, i18n.tr("Marcar servidor como lido", "Mark server as read"), kh.hovered);
            if (kh.clicked) ctx.act(.{ .mark_read = g.guild });
            y += 48;
            continue;
        }
        const cs = ctx.store.channel(g.channel) orelse continue;
        const dm = cs.info.guild == 0;
        const ct = if (g.total == 0) "" else if (dm)
            (if (g.total == 1) i18n.tr("1 não lida", "1 unread") else i18n.fmt(&cb, "{d} não lidas", "{d} unread", .{g.total}))
        else if (g.total == 1) i18n.tr("1 menção", "1 mention") else i18n.fmt(&cb, "{d} menções", "{d} mentions", .{g.total});
        groupHeader(ctx, dl, x, y, wd, g.channel, ct, true);
        y += 30;
        for (g.ids()) |id| {
            const m = ctx.store.find(cs, id) orelse continue;
            const rr: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 46 };
            qa.mark(rr, "inbox-msg:{d}", .{id});
            if (messageRow(ctx, dl, rr, @truncate(id), m, cs.info.guild, !dm)) openMessage(ctx, g.channel, id);
            y += 48;
        }
        if (g.n == 0) {
            const t = if (cs.history == .loading) i18n.tr("carregando…", "loading…") else i18n.tr("sem prévia: clique no canal para abrir", "no preview: click the channel to open it");
            d.text(dl, fam.get(.regular), 13, x + 44, y + 2, ctx.col(.faint), t);
            y += 24;
        }
        y += 10;
    }
    return y;
}

fn mentionList(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32) f32 {
    const store = ctx.store;
    if (store.mentions_state == .none) ctx.act(.fetch_mentions);
    if (store.mentions_state != .loaded) return empty(ctx, dl, body, y0, i18n.tr("Carregando menções…", "Loading mentions…"), i18n.tr("As mais recentes, de todos os servidores.", "The most recent ones, from every server."));
    const sig = core.mentionsSignature(store);
    if (!mentions.built or sig != mentions.sig) {
        core.buildMentions(store, &mentions);
        mentions.sig = sig;
    }
    if (mentions.n == 0) return empty(ctx, dl, body, y0, i18n.tr("Nenhuma menção recente.", "No recent mentions."), i18n.tr("Quando alguém te mencionar, aparece aqui.", "When someone mentions you, it shows up here."));
    const x = body.x + 10;
    const wd = body.w - 20;
    var y = y0;
    for (mentions.slice()) |*g| {
        var cb: [32]u8 = undefined;
        const more = if (g.total > g.n) i18n.fmt(&cb, "+{d}", "+{d}", .{g.total - g.n}) else "";
        groupHeader(ctx, dl, x, y, wd, g.channel, more, false);
        y += 30;
        for (g.ids()) |id| {
            const found = core.lookup(store, g.channel, id) orelse continue;
            const rr: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 46 };
            qa.mark(rr, "inbox-mention:{d}", .{id});
            if (messageRow(ctx, dl, rr, @truncate(id), found.m, g.guild, true)) openMessage(ctx, g.channel, id);
            y += 48;
        }
        y += 10;
    }
    return y;
}

pub fn draw(ctx: *d.Ctx, tab: u8) void {
    const r = panelRect(ctx);
    const dl = popup.beginWindow("##inbox", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    refresh(ctx);

    icons.inbox(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    d.text(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), i18n.tr("Caixa de entrada", "Inbox"));
    if (tab == 0) {
        if (model.n > 0) {
            const lbl = i18n.tr("Marcar tudo como lido", "Mark all as read");
            const bw = buttonWidth(ctx, lbl);
            const br: d.Rect = .{ .x = r.right() - bw - 14, .y = r.y + 13, .w = bw, .h = 28 };
            qa.mark(br, "inbox-readall", .{});
            if (button(ctx, dl, 1, br, lbl, false)) markAll(ctx);
        }
    } else if (ctx.store.mentions_state == .loaded) {
        const lbl = i18n.tr("Atualizar", "Refresh");
        const bw = buttonWidth(ctx, lbl);
        const br: d.Rect = .{ .x = r.right() - bw - 14, .y = r.y + 13, .w = bw, .h = 28 };
        qa.mark(br, "inbox-refresh", .{});
        if (button(ctx, dl, 2, br, lbl, false)) ctx.act(.fetch_mentions);
    }

    // Abas.
    const ty = r.y + 52;
    var tx = r.x + 16;
    const names = [_][]const u8{ i18n.tr("Não lidas", "Unreads"), i18n.tr("Menções", "Mentions") };
    const keys = [_][]const u8{ "unread", "mentions" };
    for (names, 0..) |name, i| {
        var nb: [48]u8 = undefined;
        const lbl = if (i == 0 and model.n > 0) std.fmt.bufPrint(&nb, "{s}  {d}", .{ name, model.n }) catch name else name;
        const sel = tab == i;
        const tw = d.width(fam.get(.semibold), 14, lbl) + 20;
        const tr: d.Rect = .{ .x = tx, .y = ty, .w = tw, .h = 30 };
        const hb = d.hit(ctx, 10 + i, tr);
        qa.mark(tr, "inbox-tab:{s}", .{keys[i]});
        if (sel) d.rect(dl, tr, ctx.col(.selected), @max(ctx.th.radius - 2, 4)) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), @max(ctx.th.radius - 2, 4));
        d.text(dl, fam.get(.semibold), 14, tr.x + 10, d.centerY(tr, 14), if (sel) ctx.col(.text) else ctx.col(.muted), lbl);
        if (hb.clicked and !sel) ctx.st.popup = .{ .inbox = .{ .tab = @intCast(i) } };
        tx += tw + 6;
    }
    d.line(dl, r.x, ty + 38, r.right(), ty + 38, ctx.col(.border), 1);

    const body: d.Rect = .{ .x = r.x + 1, .y = ty + 39, .w = r.w - 2, .h = r.bottom() - ty - 45 };
    const bdl = d.beginRegion(ctx, "##inbox-body", body, 0);
    ctx.dl = bdl;
    const o = c.ImGui_GetCursorScreenPos();
    const end = if (tab == 0) unreadList(ctx, bdl, body, o.y + 8) else mentionList(ctx, bdl, body, o.y + 8);
    d.endRegion(ctx, end + 6, body.x);
    ctx.dl = dl;
}

/// Tudo o que está na aba "Não lidas" vira lido (a mesma ação do menu
/// "Marcar como lido"). O contador de menções que o Discord manda é do
/// servidor inteiro: para ele zerar, o servidor todo vira lido.
fn markAll(ctx: *d.Ctx) void {
    for (model.slice()) |g| {
        ctx.act(.{ .mark_read = if (g.channel != 0) g.channel else g.guild });
        if (g.channel != 0 and g.guild != 0) if (ctx.store.guild(g.guild)) |gd| if (gd.mentions > 0) ctx.act(.{ .mark_read = g.guild });
    }
    ctx.st.showToast(ctx.now_ms, false, "tudo marcado como lido ✓", "all marked as read ✓", .{});
}
