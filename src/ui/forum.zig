//! Fóruns (e canais de mídia): a lista de posts no lugar da conversa, com
//! busca local e ordenação; o painel com as threads de um canal de texto (a
//! mesma lista, num popup); "Criar thread" e "Novo post".
//!
//! A lista é virtual (só as linhas à vista são desenhadas) e o recorte filtrado
//! só é refeito quando as threads, a busca ou a ordem mudam. As páginas vêm sob
//! demanda: ao abrir, e a próxima quando o fim da lista aparece.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const threads = @import("comp_threads.zig");
const sigil = @import("comp_chat.zig").sigil;
const sq = @import("../core/search_query.zig");
const store_mod = @import("../core/store.zig");
const types = @import("../core/types.zig");
const ChannelState = store_mod.ChannelState;
const Id = types.Id;

const alloc = std.heap.c_allocator;

const View = struct {
    parent: Id = 0,
    query: [96]u8 = @splat(0),
    by_creation: bool = false,
    archived: bool = false,
    /// O que aparece, já filtrado e na ordem. Só muda quando `key` muda.
    ids: std.ArrayList(Id) = .empty,
    key: u64 = 0,
    /// Trocou de canal, de aba, de ordem ou a busca: a rolagem volta ao topo.
    reset_scroll: bool = false,
    filter_key: u64 = 0,
};

var page_view: View = .{};
var panel_view: View = .{};
/// O QA pede para ir ao fim da lista (a página seguinte vem daí).
pub var qa_scroll_end = false;

/// O que muda a lista, para a varredura "clicar em tudo" do QA.
pub fn qaState() u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_]*const View{ &page_view, &panel_view }) |v| {
        h.update(&.{ @intFromBool(v.by_creation), @intFromBool(v.archived) });
        h.update(std.mem.sliceAsBytes(v.ids.items));
    }
    return h.final();
}

/// O que a lista mostra: a do painel ou a da página (o QA confere).
pub fn visible(in_panel: bool) []const Id {
    return if (in_panel) panel_view.ids.items else page_view.ids.items;
}

fn queryOf(v: *const View) []const u8 {
    return std.mem.sliceTo(&v.query, 0);
}

fn rebuild(ctx: *d.Ctx, v: *View) void {
    var h = std.hash.Wyhash.init(0x51);
    h.update(std.mem.asBytes(&v.parent));
    h.update(std.mem.asBytes(&ctx.store.threads_rev));
    h.update(queryOf(v));
    h.update(&.{ @intFromBool(v.by_creation), @intFromBool(v.archived) });
    const key = h.final() | 1;
    if (key == v.key) return;
    v.key = key;
    var fh = std.hash.Wyhash.init(0x52);
    fh.update(queryOf(v));
    fh.update(&.{ @intFromBool(v.by_creation), @intFromBool(v.archived) });
    const filter_key = fh.final();
    if (filter_key != v.filter_key) {
        v.filter_key = filter_key;
        v.reset_scroll = true;
    }
    v.ids.clearRetainingCapacity();
    const Row = struct { key: i128, id: Id };
    var tmp: std.ArrayList(Row) = .empty;
    defer tmp.deinit(alloc);
    const q = std.mem.trim(u8, queryOf(v), " ");
    for (ctx.store.threadsOf(v.parent)) |id| {
        const cs = ctx.store.channel(id) orelse continue;
        const t = cs.info.thread orelse continue;
        if (t.archived != v.archived) continue;
        if (q.len > 0 and !sq.containsFold(cs.info.name, q) and !sq.containsFold(cs.preview, q)) continue;
        // Arquivadas: a arquivada por último primeiro, como o Discord pagina.
        const k: i128 = if (v.by_creation) id else if (v.archived and t.archive_ts != 0) t.archive_ts else store_mod.Store.threadActivity(&cs.info);
        tmp.append(alloc, .{ .key = k, .id = id }) catch return;
    }
    @import("../core/sort.zig").stable(Row, tmp.items, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.key > b.key;
        }
    }.lt);
    v.ids.ensureTotalCapacity(alloc, tmp.items.len) catch return;
    for (tmp.items) |x| v.ids.appendAssumeCapacity(x.id);
}

// --- A página do fórum ----------------------------------------------------------

/// No lugar da conversa. `region` é o nome da região de rolagem (um por painel).
pub fn page(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState, region: [*:0]const u8) void {
    const v = &page_view;
    if (v.parent != cs.info.id) {
        v.* = .{ .ids = v.ids };
        v.parent = cs.info.id;
        v.key = 0;
        v.reset_scroll = true;
    }
    cs.seen_ms = ctx.now_ms;
    const fam = ctx.familyFor(n);
    const can_post = ctx.store.canPost(&cs.info);
    const bar_h: f32 = 52;
    const bar: d.Rect = .{ .x = r.x + 16, .y = r.y + 10, .w = r.w - 32, .h = bar_h - 14 };
    toolbar(ctx, ctx.dl, fam, v, cs, bar, can_post);
    d.line(ctx.dl, r.x, r.y + bar_h, r.right(), r.y + bar_h, ctx.col(.border), 1);
    const body: d.Rect = .{ .x = r.x, .y = r.y + bar_h + 1, .w = r.w, .h = r.h - bar_h - 1 };
    list(ctx, fam, v, cs, body, region, false);
}

fn toolbar(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, v: *View, cs: *ChannelState, bar: d.Rect, can_post: bool) void {
    var right = bar.right();
    if (can_post) {
        const lbl = i18n.tr("Novo post", "New Post");
        const bw = d.width(fam.get(.semibold), 13.5, lbl) + 28;
        const br: d.Rect = .{ .x = right - bw, .y = bar.y, .w = bw, .h = bar.h };
        qa.mark(br, "forum-new", .{});
        if (primary(ctx, dl, fam, 41, br, lbl, true)) openNewPost(ctx, cs.info.id);
        right -= bw + 10;
    }
    // Ordem: atividade (a última mensagem) ou criação.
    const sort_lbl = if (v.by_creation) i18n.tr("Mais novos", "Newest") else i18n.tr("Atividade", "Activity");
    const sw = d.width(fam.get(.medium), 13, sort_lbl) + 34;
    const sr: d.Rect = .{ .x = right - sw, .y = bar.y, .w = sw, .h = bar.h };
    const sh = d.hit(ctx, 42, sr);
    qa.mark(sr, "forum-sort", .{});
    if (sh.clicked) v.by_creation = !v.by_creation;
    d.rect(dl, sr, if (sh.hovered) ctx.col(.hover) else ctx.col(.elevated).alpha(0.6), @max(ctx.th.radius, 2));
    d.text(dl, fam.get(.medium), 13, sr.x + 10, d.centerY(sr, 13), ctx.col(.muted), sort_lbl);
    icons.chevron(dl, sr.right() - 13, sr.y + sr.h / 2, ctx.col(.faint).u(), 1);
    d.tip(ctx, sr, i18n.tr("Ordenar por atividade ou por criação", "Sort by activity or creation"), sh.hovered);
    right = sr.x - 10;
    right = tabs(ctx, dl, fam, v, bar, right, null);
    searchBox(ctx, dl, fam, v, .{ .x = bar.x, .y = bar.y, .w = @max(right - bar.x, 60), .h = bar.h }, "##forum-q");
}

/// Ativas / Arquivadas. `panel`: no painel, a aba fica no próprio popup.
fn tabs(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, v: *View, bar: d.Rect, right_in: f32, panel_of: ?Id) f32 {
    var right = right_in;
    // Posts num fórum, threads num canal de texto (o painel).
    const names = if (panel_of == null)
        [_][]const u8{ i18n.tr("Arquivados", "Archived"), i18n.tr("Ativos", "Active") }
    else
        [_][]const u8{ i18n.tr("Arquivadas", "Archived"), i18n.tr("Ativas", "Active") };
    const keys = [_][]const u8{ "archived", "active" };
    for (names, 0..) |name, i| {
        const on = (i == 0) == v.archived;
        const tw = d.width(fam.get(.semibold), 13, name) + 20;
        const tr: d.Rect = .{ .x = right - tw, .y = bar.y, .w = tw, .h = bar.h };
        const hb = d.hit(ctx, 50 + i, tr);
        qa.mark(tr, "forum-tab:{s}", .{keys[i]});
        if (hb.clicked and !on) {
            v.archived = i == 0;
            if (panel_of) |p| ctx.st.popup = .{ .threads = .{ .parent = p, .archived = i == 0 } };
        }
        if (on) d.rect(dl, tr, ctx.col(.selected), @max(ctx.th.radius, 2)) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), @max(ctx.th.radius, 2));
        d.text(dl, fam.get(.semibold), 13, tr.x + 10, d.centerY(tr, 13), if (on) ctx.col(.text) else ctx.col(.muted), name);
        right -= tw + 2;
    }
    return right - 8;
}

fn searchBox(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, v: *View, r: d.Rect, id: [*:0]const u8) void {
    d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.surface), 0.35), @max(ctx.th.radius, 2));
    icons.search(dl, r.x + 15, r.y + r.h / 2, ctx.col(.faint).u());
    qa.mark(r, "forum-search", .{});
    c.ImGui_PushFontFloat(fam.get(.regular), 14);
    c.ImGui_SetCursorScreenPos(d.v(r.x + 26, r.y + (r.h - 22) / 2));
    c.ImGui_SetNextItemWidth(r.w - 30);
    _ = c.ImGui_InputTextWithHint(id, i18n.trZ("Buscar nesta lista…", "Search this list…").ptr, &v.query, v.query.len, 0);
    c.ImGui_PopFont();
}

const row_h: f32 = 92;
const row_gap: f32 = 6;

/// A lista rolável, com os estados de carregando, vazio e erro.
fn list(ctx: *d.Ctx, fam: *d.Family, v: *View, cs: *ChannelState, r: d.Rect, region: [*:0]const u8, in_panel: bool) void {
    rebuild(ctx, v);
    const pg = if (v.archived) &cs.archived_page else &cs.active_page;
    if (pg.state == .none) ctx.act(.{ .fetch_threads = .{ .channel = cs.info.id, .archived = v.archived } });
    const dl = d.beginRegion(ctx, region, r, c.ImGuiWindowFlags_NoScrollbar);
    if (in_panel) popup.track(dl);
    if (v.reset_scroll) {
        c.ImGui_SetScrollY(0);
        v.reset_scroll = false;
    }
    if (qa_scroll_end) {
        c.ImGui_SetScrollY(c.ImGui_GetScrollMaxY());
        qa_scroll_end = false;
    }
    const o = c.ImGui_GetCursorScreenPos();
    const step = row_h + row_gap;
    const pad: f32 = 10;
    const n = v.ids.items.len;
    const x = r.x + 14;
    const rw = r.w - 28;
    if (n == 0) {
        emptyState(ctx, dl, fam, v, cs, pg, r);
        d.endRegion(ctx, r.y + r.h - 1, r.x);
        return;
    }
    // Só o que está à vista.
    const first: usize = @intFromFloat(@max(0, (r.y - (o.y + pad)) / step));
    var i = first;
    while (i < n) : (i += 1) {
        const y = o.y + pad + @as(f32, @floatFromInt(i)) * step;
        if (y > r.bottom()) break;
        const pcs = ctx.store.channel(v.ids.items[i]) orelse continue;
        postRow(ctx, dl, fam, pcs, &cs.info, .{ .x = x, .y = y, .w = rw, .h = row_h }, in_panel);
    }
    // O fim da lista: a próxima página, ou um botão se há uma busca (senão
    // uma busca sem resultado baixaria o fórum inteiro).
    const tail_y = o.y + pad + @as(f32, @floatFromInt(n)) * step;
    var tail_h: f32 = 12;
    if (pg.state == .loading) {
        w.typingDots(dl, r.x + r.w / 2 - 7, tail_y + 14, ctx.col(.muted), ctx.now_ms);
        tail_h = 36;
    } else if (pg.state == .loaded and pg.more) {
        if (queryOf(v).len == 0) {
            if (tail_y < r.bottom() + 200) ctx.act(.{ .fetch_threads = .{ .channel = cs.info.id, .archived = v.archived } });
            tail_h = 36;
        } else {
            const lbl = i18n.tr("Buscar em mais posts", "Search more posts");
            const bw = inbox.buttonWidth(ctx, lbl);
            const br: d.Rect = .{ .x = r.x + (r.w - bw) / 2, .y = tail_y + 4, .w = bw, .h = 28 };
            qa.mark(br, "forum-more", .{});
            if (inbox.button(ctx, dl, 60, br, lbl, false)) ctx.act(.{ .fetch_threads = .{ .channel = cs.info.id, .archived = v.archived } });
            tail_h = 44;
        }
    }
    d.endRegion(ctx, tail_y + tail_h, r.x);
}

fn emptyState(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, v: *const View, cs: *const ChannelState, pg: *const store_mod.ThreadPage, r: d.Rect) void {
    const cx = r.x + r.w / 2;
    const y = r.y + @min(r.h * 0.3, 120);
    if (pg.state == .loading or pg.state == .none) {
        w.typingDots(dl, cx - 7, y, ctx.col(.muted), ctx.now_ms);
        return;
    }
    const font = fam.get(.medium);
    const centered = struct {
        fn f(l: *c.ImDrawList, fnt: *c.ImFont, size: f32, mid: f32, yy: f32, col: d.Rgba, t: []const u8) void {
            d.text(l, fnt, size, mid - d.width(fnt, size, t) / 2, yy, col, t);
        }
    }.f;
    if (pg.state == .failed) {
        centered(dl, font, 15, cx, y, ctx.col(.muted), i18n.tr("Não deu para carregar a lista.", "Couldn't load the list."));
        const lbl = i18n.tr("Tentar de novo", "Try again");
        const bw = inbox.buttonWidth(ctx, lbl);
        const br: d.Rect = .{ .x = cx - bw / 2, .y = y + 30, .w = bw, .h = 28 };
        qa.mark(br, "forum-retry", .{});
        if (inbox.button(ctx, dl, 61, br, lbl, false)) ctx.act(.{ .fetch_threads = .{ .channel = cs.info.id, .archived = v.archived } });
        return;
    }
    const forum = cs.info.kind == .forum;
    const t = if (queryOf(v).len > 0)
        i18n.tr("Nada encontrado.", "Nothing found.")
    else if (v.archived)
        (if (forum) i18n.tr("Nenhum post arquivado.", "No archived posts.") else i18n.tr("Nenhuma thread arquivada.", "No archived threads."))
    else if (forum)
        i18n.tr("Nenhum post ainda.", "No posts yet.")
    else
        i18n.tr("Nenhuma thread ativa.", "No active threads.");
    centered(dl, font, 15, cx, y, ctx.col(.muted), t);
    qa.mark(.{ .x = r.x, .y = y, .w = r.w, .h = 20 }, "forum-empty", .{});
}

/// Uma linha: título e data; autor e prévia; tags e atividade.
fn postRow(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, cs: *const ChannelState, parent: *const types.Channel, rr: d.Rect, in_panel: bool) void {
    const ch = &cs.info;
    const t = ch.thread orelse return;
    const hb = d.hit(ctx, @truncate(ch.id *% 0x9E3779B97F4A7C15), rr);
    qa.mark(rr, "post:{d}", .{ch.id});
    if (hb.clicked or hb.middle) {
        if (in_panel) popup.close(ctx);
        ctx.act(.{ .select_channel = ch.id });
    }
    if (hb.right) ctx.popup(.{ .menu = .{ .kind = .channel, .id = ch.id, .x = ctx.mouse.x, .y = ctx.mouse.y } });
    const radius = @max(ctx.th.radius, 2);
    d.rect(dl, rr, if (hb.hovered) ctx.col(.hover).mix(ctx.col(.elevated), 0.5) else ctx.col(.elevated).alpha(0.75), radius);
    if (ctx.st.activeChannel() == ch.id) d.border(dl, rr, ctx.col(.accent).alpha(0.6), radius, 1);

    const left = rr.x + 14;
    const inner_r = rr.right() - 14;
    var buf: [96]u8 = undefined;

    // Título e data de criação.
    const created = @divTrunc(types.snowflakeTime(ch.id), 1000);
    const date = w.stamp(&buf, created, @divTrunc(ctx.now_ms, 1000));
    const date_w = d.width(fam.get(.regular), 12, date);
    d.text(dl, fam.get(.regular), 12, inner_r - date_w, rr.y + 12, ctx.col(.faint), date);
    var tx = left;
    if (ch.unread) {
        d.circle(dl, tx + 4, rr.y + 20, 4, ctx.col(.accent));
        tx += 14;
    }
    if (t.locked) {
        icons.lock(dl, tx + 6, rr.y + 18, ctx.col(.faint).u());
        tx += 18;
    }
    _ = d.textClipped(dl, fam.get(if (ch.unread) .bold else .semibold), 15, tx, rr.y + 9, ctx.col(.text), ch.name, inner_r - date_w - 12 - tx);

    // Autor e prévia.
    const author = if (cs.preview_author != 0) cs.preview_author else t.owner;
    const y2 = rr.y + 34;
    w.avatar(ctx, dl, left + 9, y2 + 9, 18, author, .circle, null, 1);
    const name = if (ctx.store.user(author)) |u| u.name else "?";
    const nx = left + 24;
    const nw = d.textClipped(dl, fam.get(.semibold), 13, nx, y2 + 1, w.nameColor(ctx, ch.guild, author), name, 150);
    if (cs.preview.len > 0) {
        var pb: [200]u8 = undefined;
        const flat = flatten(&pb, cs.preview);
        _ = d.textClipped(dl, fam.get(.regular), 13, nx + nw + 8, y2 + 1, ctx.col(.muted), flat, inner_r - (nx + nw + 8));
    }

    // Tags e atividade.
    const y3 = rr.y + 62;
    var ab: [96]u8 = undefined;
    const act = threads.activityLine(ctx, &ab, ch);
    const act_w = d.width(fam.get(.regular), 12, act);
    d.text(dl, fam.get(.regular), 12, inner_r - act_w, y3 + 3, ctx.col(.muted), act);
    icons.thread(dl, inner_r - act_w - 14, y3 + 10, ctx.col(.faint).u());
    var cx = left;
    const limit = inner_r - act_w - 28;
    for (t.tags) |tag_id| {
        for (parent.tags) |tag| if (tag.id == tag_id) {
            cx = chip(ctx, dl, fam, cx, y3, tag, limit);
            break;
        };
    }
    if (t.joined) cx = plainChip(ctx, dl, fam, cx, y3, i18n.tr("Participando", "Joined"), limit, ctx.col(.accent));
    if (t.archived) cx = plainChip(ctx, dl, fam, cx, y3, if (t.locked) i18n.tr("Trancado", "Locked") else i18n.tr("Arquivado", "Archived"), limit, ctx.col(.faint));
}

/// Prévia em uma linha: as quebras viram espaços.
fn flatten(buf: []u8, s: []const u8) []const u8 {
    const src = d.utf8Prefix(s, buf.len);
    for (src, 0..) |ch, i| buf[i] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
    return buf[0..src.len];
}

fn chip(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, x: f32, y: f32, tag: types.ForumTag, limit: f32) f32 {
    const font = fam.get(.medium);
    const tw = d.width(font, 12, tag.name);
    const ew: f32 = if (tag.emoji.len > 0) 18 else 0;
    const cw = tw + ew + 16;
    if (x + cw > limit) return x;
    const r: d.Rect = .{ .x = x, .y = y, .w = cw, .h = 21 };
    d.rect(dl, r, ctx.col(.selected), if (ctx.th.radius < 2) 0 else r.h / 2);
    if (ew > 0) d.text(dl, ctx.ui.get(.regular), 12, x + 8, d.centerY(r, 12), d.Rgba.white, tag.emoji);
    d.text(dl, font, 12, x + 8 + ew, d.centerY(r, 12), ctx.col(.text).mix(ctx.col(.muted), 0.2), tag.name);
    return x + cw + 5;
}

fn plainChip(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, x: f32, y: f32, label: []const u8, limit: f32, col: d.Rgba) f32 {
    const font = fam.get(.medium);
    const cw = d.width(font, 12, label) + 16;
    if (x + cw > limit) return x;
    const r: d.Rect = .{ .x = x, .y = y, .w = cw, .h = 21 };
    d.border(dl, r, col.alpha(0.7), if (ctx.th.radius < 2) 0 else r.h / 2, 1);
    d.text(dl, font, 12, x + 8, d.centerY(r, 12), col, label);
    return x + cw + 5;
}

/// Botão cheio com a cor de destaque. Apagado (`on` = false) não reage.
fn primary(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, id: usize, r: d.Rect, label: []const u8, on: bool) bool {
    const hb = d.hit(ctx, id, r);
    const base = ctx.col(.accent);
    const radius = @max(ctx.th.radius, 2);
    if (on) {
        d.rect(dl, r, if (hb.hovered) base.mix(d.Rgba.white, 0.12) else base, radius);
    } else d.rect(dl, r, ctx.col(.hover), radius);
    const font = fam.get(.semibold);
    d.text(dl, font, 13.5, r.x + (r.w - d.width(font, 13.5, label)) / 2, d.centerY(r, 13.5), if (on) ctx.col(.accent_text) else ctx.col(.faint), label);
    return on and hb.clicked;
}

/// Onde ficaria a caixa de texto: "Novo post" num fórum, ou por que não dá
/// para responder numa thread.
pub fn composerBand(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *const ChannelState) void {
    const fam = ctx.familyFor(n);
    const dl = ctx.dl;
    const pill = d.is(n, "variant", "pill", "box");
    const prompt = d.is(n, "variant", "prompt", "box");
    const radius = if (pill) r.h / 2 else ctx.th.radius + 4;
    const fs = ctx.th.font_size;
    if (prompt) d.line(dl, r.x, r.y + 0.5, r.right(), r.y + 0.5, ctx.col(.border), 1);
    if (cs.info.kind == .forum and ctx.store.canPost(&cs.info)) {
        const hb = d.hit(ctx, 62, r);
        qa.mark(r, "forum-band", .{});
        if (hb.clicked) openNewPost(ctx, cs.info.id);
        if (!prompt) d.rect(dl, r, if (hb.hovered) ctx.col(.hover).mix(ctx.col(.elevated), 0.5) else ctx.col(.elevated), radius);
        var buf: [120]u8 = undefined;
        const t = i18n.fmt(&buf, "Novo post em {s}", "New post in {s}", .{cs.info.name});
        var tx = r.x + 44;
        if (prompt) {
            d.text(dl, fam.get(.bold), fs, r.x + 10, d.centerY(r, fs), ctx.col(.accent), "❯");
            tx = r.x + 10 + d.width(fam.get(.bold), fs, "❯ ");
        } else icons.plus(dl, r.x + 24, r.y + r.h / 2, 6, ctx.col(.muted).u());
        d.text(dl, fam.get(.regular), fs, tx, d.centerY(r, fs), if (hb.hovered) ctx.col(.text) else ctx.col(.faint), t);
        return;
    }
    const t = if (cs.info.kind == .forum)
        i18n.tr("Você não pode criar posts neste canal.", "You can't create posts in this channel.")
    else if (cs.info.thread != null and cs.info.thread.?.locked)
        i18n.tr("Esta thread está trancada.", "This thread is locked.")
    else
        i18n.tr("Você não tem permissão para responder nesta thread.", "You don't have permission to reply in this thread.");
    qa.mark(r, "composer-readonly", .{});
    if (!prompt) d.rect(dl, r, ctx.col(.elevated).alpha(0.5), radius);
    if (!prompt) icons.lock(dl, r.x + 24, r.y + r.h / 2 - 2, ctx.col(.faint).u());
    d.text(dl, fam.get(.regular), fs, r.x + (if (prompt) @as(f32, 10) else 44), d.centerY(r, fs), ctx.col(.faint), t);
}

// --- Painel: as threads de um canal de texto --------------------------------------

pub fn panel(ctx: *d.Ctx, parent: Id, archived: bool) void {
    const cs = ctx.store.channel(parent) orelse return popup.close(ctx);
    const v = &panel_view;
    if (v.parent != parent) {
        v.* = .{ .ids = v.ids };
        v.parent = parent;
        v.key = 0;
        v.reset_scroll = true;
    }
    v.archived = archived;
    const r = inbox.panelRect(ctx);
    const dl = popup.beginWindow("##threads", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    icons.thread(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    var buf: [120]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), i18n.fmt(&buf, "Threads de {s}{s}", "Threads in {s}{s}", .{ sigil(&cs.info), cs.info.name }), r.w - 60);
    const bar: d.Rect = .{ .x = r.x + 14, .y = r.y + 50, .w = r.w - 28, .h = 34 };
    const right = tabs(ctx, dl, fam, v, bar, bar.right(), parent);
    searchBox(ctx, dl, fam, v, .{ .x = bar.x, .y = bar.y, .w = @max(right - bar.x, 60), .h = bar.h }, "##threads-q");
    d.line(dl, r.x, bar.bottom() + 8, r.right(), bar.bottom() + 8, ctx.col(.border), 1);
    const y = bar.bottom() + 9;
    list(ctx, fam, v, cs, .{ .x = r.x, .y = y, .w = r.w, .h = r.bottom() - y - 4 }, "##threads-list", true);
}

// --- Criar thread ------------------------------------------------------------------

var name_buf: [101]u8 = @splat(0);

/// Abre o popup com o começo da mensagem como nome (dá para trocar).
pub fn openNewThread(ctx: *d.Ctx, message: Id) void {
    @memset(&name_buf, 0);
    if (ctx.store.findAny(message)) |f| {
        var flat: [100]u8 = undefined;
        const line = std.mem.trim(u8, flatten(&flat, f.m.msg.content), " ");
        const head = d.utf8Prefix(line, 60);
        @memcpy(name_buf[0..head.len], head);
    }
    ctx.st.popup = .{ .new_thread = .{ .message = message } };
}

fn dialogRect(ctx: *const d.Ctx, wd_in: f32, h_in: f32) d.Rect {
    const wd = @min(wd_in, ctx.win.w - 24);
    const h = @min(h_in, ctx.win.h - 24);
    return .{ .x = ctx.win.x + (ctx.win.w - wd) / 2, .y = ctx.win.y + (ctx.win.h - h) / 2, .w = wd, .h = h };
}

fn textInput(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, id: [*:0]const u8, hint: [*:0]const u8, buf: []u8, flags: c_int) bool {
    d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.surface), 0.35), @max(ctx.th.radius, 2));
    c.ImGui_PushFontFloat(ctx.ui.get(.regular), 14);
    c.ImGui_SetCursorScreenPos(d.v(r.x + 8, r.y + (r.h - 22) / 2));
    c.ImGui_SetNextItemWidth(r.w - 16);
    const done = c.ImGui_InputTextWithHint(id, hint, buf.ptr, buf.len, flags);
    c.ImGui_PopFont();
    return done;
}

pub fn newThread(ctx: *d.Ctx, message: Id) void {
    const f = ctx.store.findAny(message) orelse return popup.close(ctx);
    const r = dialogRect(ctx, 460, 182);
    const dl = popup.beginWindow("##new-thread", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    icons.thread(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    d.text(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), i18n.tr("Criar thread", "Create Thread"));
    var pb: [120]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 18, r.y + 46, ctx.col(.muted), i18n.fmt(&pb, "A partir de uma mensagem em {s}{s}", "From a message in {s}{s}", .{ sigil(&f.cs.info), f.cs.info.name }), r.w - 36);
    const ir: d.Rect = .{ .x = r.x + 18, .y = r.y + 72, .w = r.w - 36, .h = 36 };
    qa.mark(ir, "thread-name", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    const enter = textInput(ctx, dl, ir, "##thread-name", i18n.trZ("Nome da thread", "Thread name").ptr, &name_buf, c.ImGuiInputTextFlags_EnterReturnsTrue);
    const name = std.mem.trim(u8, std.mem.sliceTo(&name_buf, 0), " ");
    const lbl = i18n.tr("Criar", "Create");
    const bw = d.width(fam.get(.semibold), 13.5, lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - 50, .w = bw, .h = 34 };
    qa.mark(br, "thread-create", .{});
    const clicked = primary(ctx, dl, fam, 70, br, lbl, name.len > 0);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "thread-cancel", .{});
    if (inbox.button(ctx, dl, 71, cr, cancel, false)) return popup.close(ctx);
    if ((clicked or enter) and name.len > 0) {
        if (ctx.st.gpa.dupe(u8, name)) |owned| ctx.act(.{ .create_thread = .{ .message = message, .name = owned } }) else |_| {}
        popup.close(ctx);
    }
}

// --- Novo post ---------------------------------------------------------------------

var post_title: [101]u8 = @splat(0);
var post_body: [2001]u8 = @splat(0);
var post_tags: [5]Id = @splat(0);
var n_post_tags: usize = 0;

pub fn openNewPost(ctx: *d.Ctx, forum: Id) void {
    @memset(&post_title, 0);
    @memset(&post_body, 0);
    n_post_tags = 0;
    ctx.st.popup = .{ .new_post = .{ .forum = forum } };
}

pub fn newPost(ctx: *d.Ctx, forum: Id) void {
    const cs = ctx.store.channel(forum) orelse return popup.close(ctx);
    const r = dialogRect(ctx, 580, 470);
    const dl = popup.beginWindow("##new-post", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    icons.forum(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    var pb: [120]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), i18n.fmt(&pb, "Novo post em {s}", "New post in {s}", .{cs.info.name}), r.w - 60);
    const ir: d.Rect = .{ .x = r.x + 18, .y = r.y + 52, .w = r.w - 36, .h = 36 };
    qa.mark(ir, "post-title", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    _ = textInput(ctx, dl, ir, "##post-title", i18n.trZ("Título", "Title").ptr, &post_title, 0);

    // Tags: até 5. As moderadas só para quem gerencia threads.
    var y = ir.bottom() + 12;
    const mod = ctx.store.channelPermissions(&cs.info) & types.perm.manage_threads != 0;
    var x = r.x + 18;
    for (cs.info.tags, 0..) |tag, i| {
        if (tag.moderated and !mod) continue;
        const tw = d.width(fam.get(.medium), 12.5, tag.name) + (if (tag.emoji.len > 0) @as(f32, 18) else 0) + 18;
        if (x + tw > r.right() - 18) {
            x = r.x + 18;
            y += 30;
        }
        const tr: d.Rect = .{ .x = x, .y = y, .w = tw, .h = 25 };
        const on = std.mem.indexOfScalar(Id, post_tags[0..n_post_tags], tag.id);
        const hb = d.hit(ctx, 80 + i, tr);
        qa.mark(tr, "post-tag:{d}", .{i});
        if (hb.clicked) {
            if (on) |k| {
                std.mem.copyForwards(Id, post_tags[k .. n_post_tags - 1], post_tags[k + 1 .. n_post_tags]);
                n_post_tags -= 1;
            } else if (n_post_tags < post_tags.len) {
                post_tags[n_post_tags] = tag.id;
                n_post_tags += 1;
            }
        }
        const radius = if (ctx.th.radius < 2) @as(f32, 0) else tr.h / 2;
        if (on != null) d.rect(dl, tr, ctx.col(.accent), radius) else d.rect(dl, tr, if (hb.hovered) ctx.col(.hover) else ctx.col(.selected), radius);
        var tx = tr.x + 9;
        if (tag.emoji.len > 0) {
            d.text(dl, fam.get(.regular), 12.5, tx, d.centerY(tr, 12.5), d.Rgba.white, tag.emoji);
            tx += 18;
        }
        d.text(dl, fam.get(.medium), 12.5, tx, d.centerY(tr, 12.5), if (on != null) ctx.col(.accent_text) else ctx.col(.text).mix(ctx.col(.muted), 0.2), tag.name);
        x += tw + 6;
    }
    if (cs.info.tags.len > 0) y += 37;

    // O texto.
    const br_h: f32 = 34;
    const body: d.Rect = .{ .x = r.x + 18, .y = y, .w = r.w - 36, .h = r.bottom() - y - br_h - 32 };
    d.rect(dl, body, ctx.col(.rail).mix(ctx.col(.surface), 0.35), @max(ctx.th.radius, 2));
    qa.mark(body, "post-body", .{});
    c.ImGui_PushFontFloat(fam.get(.regular), 14);
    c.ImGui_SetCursorScreenPos(d.v(body.x + 6, body.y + 6));
    if (post_body[0] == 0) d.text(dl, fam.get(.regular), 14, body.x + 11, body.y + 9, ctx.col(.faint), i18n.tr("Escreva o post…", "Write your post…"));
    _ = c.ImGui_InputTextMultilineEx("##post-body", &post_body, post_body.len, d.v(body.w - 12, body.h - 12), c.ImGuiInputTextFlags_WordWrap, null, null);
    c.ImGui_PopFont();

    const title = std.mem.trim(u8, std.mem.sliceTo(&post_title, 0), " \t\r\n");
    const text = std.mem.trim(u8, std.mem.sliceTo(&post_body, 0), " \t\r\n");
    const need_tag = cs.info.require_tag and n_post_tags == 0;
    const ok = title.len > 0 and text.len > 0 and !need_tag;
    const lbl = i18n.tr("Publicar", "Post");
    const bw = d.width(fam.get(.semibold), 13.5, lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - br_h - 14, .w = bw, .h = br_h };
    qa.mark(br, "post-submit", .{});
    const clicked = primary(ctx, dl, fam, 72, br, lbl, ok);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "post-cancel", .{});
    if (inbox.button(ctx, dl, 73, cr, cancel, false)) return popup.close(ctx);
    // O botão apagado diz o que falta.
    if (!ok) {
        const why = if (title.len == 0) i18n.tr("Falta o título.", "A title is required.") else if (need_tag) i18n.tr("Escolha ao menos uma tag.", "Pick at least one tag.") else i18n.tr("Falta o texto.", "Text is required.");
        d.text(dl, fam.get(.regular), 12.5, r.x + 18, d.centerY(br, 12.5), ctx.col(.faint), why);
    }
    if (clicked) {
        const gpa = ctx.st.gpa;
        const name = gpa.dupe(u8, title) catch return;
        const content = gpa.dupe(u8, text) catch return gpa.free(name);
        const tags = gpa.dupe(Id, post_tags[0..n_post_tags]) catch {
            gpa.free(name);
            gpa.free(content);
            return;
        };
        ctx.act(.{ .create_post = .{ .forum = forum, .name = name, .content = content, .tags = tags } });
        popup.close(ctx);
    }
}
