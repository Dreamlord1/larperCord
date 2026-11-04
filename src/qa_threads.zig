//! QA de threads e fóruns (entra na bateria geral do qa_runner.zig).
//! Os dados vêm da demonstração (net/fake_gateway.zig): as threads do #zig e
//! do segundo servidor, e os fóruns. O que viria do Discord entra pela mesma
//! fila que a rede usa.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const forum = @import("ui/forum.zig");
const mosaic = @import("ui/mosaic.zig");
const search = @import("ui/search.zig");
const msg_cache = @import("net/msg_cache.zig");
const platform = @import("platform/window.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn clickD(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn rclickD(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn mk(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

// "Faculdade 2026" e "Lo-fi & café" na demonstração.
const guild0: Id = 505000;
const zig: Id = 505010;
const geral1: Id = 507005;
const bugs1: Id = 507012;
const forum0: Id = 505031;
const media0: Id = 505032;
const media1: Id = 507032;

// --- As threads da demonstração -----------------------------------------------

var t_free: Id = 0; // aberta de mensagem, com gente dentro, estamos nela
var t_migra: Id = 0; // aberta de mensagem, ninguém na lista, não lida
var t_bench: Id = 0; // solta
var t_geral1: Id = 0; // no segundo servidor, sem permissão de responder
var t_bugs1: Id = 0; // pai trancado

fn byCount(app: *App, parent: Id, count: u32) Id {
    for (app.store.threadsOf(parent)) |id| {
        const cs = app.store.channel(id) orelse continue;
        if ((cs.info.thread orelse continue).message_count == count) return id;
    }
    return 0;
}
fn remember(app: *App) void {
    t_free = byCount(app, zig, 7);
    t_migra = byCount(app, zig, 12);
    t_bench = byCount(app, zig, 4);
    t_geral1 = byCount(app, geral1, 5);
    t_bugs1 = byCount(app, bugs1, 2);
}
fn info(app: *App, id: Id) ?types.ThreadInfo {
    const cs = app.store.channel(id) orelse return null;
    return cs.info.thread;
}
fn activeIs(app: *App, id: Id) bool {
    return id != 0 and app.st.activeChannel() == id and !app.st.friends;
}
fn loaded(app: *App, id: Id) bool {
    const cs = app.store.channel(id) orelse return false;
    return cs.history == .loaded;
}

fn tRowFree(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{t_free});
}
fn tRowMigra(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{t_migra});
}
fn tRowBench(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{t_bench});
}
fn tRowGeral1(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{t_geral1});
}
fn tRowBugs1(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{t_bugs1});
}
fn tCardFree(_: *App, b: []u8) []const u8 {
    return mk(b, "thread-card:{d}", .{t_free});
}

fn listed(app: *App) bool {
    const idx = app.store.threadIndex(zig) orelse return false;
    if (idx.n_shown != 3) return false;
    // Fora da lista de canais: quem varre os canais não paga por elas.
    for (app.store.channelsOf(guild0)) |id| if (id == t_free or id == t_migra) return false;
    var b: [40]u8 = undefined;
    return t_free != 0 and qa.find(mk(&b, "channel:{d}", .{t_free})) != null and qa.find("thread-toggle:505010") != null;
}
fn unreadMarked(app: *App) bool {
    const cs = app.store.channel(t_migra) orelse return false;
    return cs.info.unread and app.store.threadIndex(zig).?.unread;
}
fn jumpStarter(app: *App) void {
    app.st.jump = t_free;
}
fn cardShown(_: *App) bool {
    var b: [48]u8 = undefined;
    return qa.find(mk(&b, "thread-card:{d}", .{t_free})) != null;
}
fn starterLinked(app: *App) bool {
    const cs = app.store.channel(zig) orelse return false;
    const m = app.store.find(cs, t_free) orelse return false;
    return m.msg.thread == t_free;
}
fn freeOpen(app: *App) bool {
    return activeIs(app, t_free) and loaded(app, t_free) and qa.find("header-parent") != null;
}
fn freeHasConversation(app: *App) bool {
    const cs = app.store.channel(t_free) orelse return false;
    // A mensagem que abriu e as respostas; o histórico tem começo.
    return cs.messages.items.len == 8 and cs.older == .done and qa.find("composer") != null;
}

// --- Conversa normal ------------------------------------------------------------

const draft_text = "rascunho dentro da thread";

fn inputText(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}
fn draftKept(app: *App) bool {
    const d = app.st.drafts.get(t_free) orelse return false;
    return activeIs(app, zig) and std.mem.eql(u8, d, draft_text) and inputText(app).len == 0;
}
fn draftBack(app: *App) bool {
    return activeIs(app, t_free) and std.mem.eql(u8, inputText(app), draft_text);
}
fn sentInThread(app: *App) bool {
    const cs = app.store.channel(t_free) orelse return false;
    const last = cs.messages.items[cs.messages.items.len - 1];
    const t = cs.info.thread orelse return false;
    return !last.pending and std.mem.eql(u8, last.msg.content, draft_text) and t.message_count == 8 and app.st.drafts.get(t_free) == null;
}
fn tLastInThread(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(t_free) orelse return "";
    if (cs.messages.items.len == 0) return "";
    return mk(b, "msgtext:{d}", .{cs.messages.items[cs.messages.items.len - 1].msg.id});
}
fn menuOpen(app: *App) bool {
    return app.st.popup == .menu;
}
fn replyArmed(app: *App) bool {
    return app.st.reply_to != 0 and activeIs(app, t_free);
}
fn repliedInThread(app: *App) bool {
    const cs = app.store.channel(t_free) orelse return false;
    const last = cs.messages.items[cs.messages.items.len - 1];
    return !last.pending and last.msg.reply_to != 0 and std.mem.eql(u8, last.msg.content, "resposta na thread");
}

// --- Não lidas, recolher, membros -------------------------------------------------

var seq: u64 = 0;

fn inject(app: *App, channel: Id, author: Id, text: []const u8) Id {
    const ca = std.heap.c_allocator;
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x3b000 + seq);
    const content = ca.dupe(u8, text) catch return 0;
    app.events.push(.{ .message_create = .{ .id = id, .channel = channel, .author = author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}
var bench_count0: u32 = 0;
fn injectBench(app: *App) void {
    bench_count0 = if (info(app, t_bench)) |t| t.message_count else 0;
    _ = inject(app, t_bench, 1003, "novidade na thread dos benchmarks");
}
fn benchUnread(app: *App) bool {
    const cs = app.store.channel(t_bench) orelse return false;
    const t = cs.info.thread orelse return false;
    const idx = app.store.threadIndex(zig) orelse return false;
    // Subiu para o topo do recorte, mais recente primeiro.
    return cs.info.unread and t.message_count == bench_count0 + 1 and idx.shown[0] == t_bench;
}
fn benchRead(app: *App) bool {
    const cs = app.store.channel(t_bench) orelse return false;
    return activeIs(app, t_bench) and !cs.info.unread;
}
fn collapsed(app: *App) bool {
    var b: [48]u8 = undefined;
    // A aberta continua à vista; a outra some.
    return app.st.collapsed.contains(zig) and qa.find(mk(&b, "channel:{d}", .{t_migra})) == null and qa.find(mk(&b, "channel:{d}", .{t_bench})) != null;
}
fn expanded(app: *App) bool {
    var b: [48]u8 = undefined;
    return !app.st.collapsed.contains(zig) and qa.find(mk(&b, "channel:{d}", .{t_migra})) != null;
}
fn threadMemberList(app: *App) bool {
    const list = app.store.threadMembers(t_free);
    if (list.len != 3) return false;
    var b: [32]u8 = undefined;
    return qa.find(mk(&b, "member:{d}", .{list[0]})) != null;
}
/// Ninguém na lista da thread: a do canal pai fica (1001 está no servidor).
fn parentMemberList(app: *App) bool {
    return app.store.threadMembers(t_migra).len == 0 and activeIs(app, t_migra) and qa.find("member:1001") != null;
}

// --- Menu da thread ---------------------------------------------------------------

fn joined(app: *App) bool {
    return if (info(app, t_migra)) |t| t.joined else false;
}
fn left(app: *App) bool {
    return if (info(app, t_migra)) |t| !t.joined else false;
}
fn panelArchived(app: *App) bool {
    if (app.st.popup != .threads) return false;
    const p = app.st.popup.threads;
    return p.parent == zig and p.archived and forum.visible(true).len == 6;
}
fn panelActive(app: *App) bool {
    if (app.st.popup != .threads) return false;
    const p = app.st.popup.threads;
    return p.parent == zig and !p.archived and forum.visible(true).len == 3;
}
var archived_id: Id = 0;
fn tFirstArchived(app: *App, b: []u8) []const u8 {
    _ = app;
    const ids = forum.visible(true);
    if (ids.len == 0) return "";
    archived_id = ids[0];
    return mk(b, "post:{d}", .{ids[0]});
}
fn archivedOpen(app: *App) bool {
    var b: [48]u8 = undefined;
    // Fora do recorte das ativas, mas aberta: a linha aparece mesmo assim.
    return activeIs(app, archived_id) and app.st.popup == .none and (info(app, archived_id) orelse return false).archived and qa.find(mk(&b, "channel:{d}", .{archived_id})) != null;
}

// --- Criar thread -----------------------------------------------------------------

var made_from: Id = 0;
fn tPlainMessage(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(zig) orelse return "";
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.thread != 0 or m.msg.content.len < 3 or m.msg.attachments.len > 0 or m.msg.embeds.len > 0 or m.msg.id == 0) continue;
        var kb: [40]u8 = undefined;
        if (qa.find(mk(&kb, "msgtext:{d}", .{m.msg.id})) == null) continue;
        made_from = m.msg.id;
        return mk(b, "msgtext:{d}", .{m.msg.id});
    }
    return "";
}
fn newThreadPopup(app: *App) bool {
    return app.st.popup == .new_thread and app.st.popup.new_thread.message == made_from;
}
fn threadCreated(app: *App) bool {
    const t = info(app, made_from) orelse return false;
    return activeIs(app, made_from) and t.joined and app.st.popup == .none;
}
fn cardOnOrigin(app: *App) bool {
    const cs = app.store.channel(zig) orelse return false;
    const m = app.store.find(cs, made_from) orelse return false;
    var b: [48]u8 = undefined;
    return activeIs(app, zig) and m.msg.thread == made_from and qa.find(mk(&b, "thread-card:{d}", .{made_from})) != null;
}
fn scrollEnd(app: *App) void {
    app.st.scrollOf(zig).stick_bottom = true;
}
fn jumpMade(app: *App) void {
    app.st.jump = made_from;
}

// --- Abas, mosaico, cache, busca, paleta --------------------------------------------

fn paneWithThread(app: *App) bool {
    _ = app;
    return mosaic.on() and mosaic.panes.indexOf(t_migra) != null;
}
fn paneClosed(_: *App) bool {
    return !mosaic.on();
}
fn tabOpened(app: *App) bool {
    return std.mem.indexOfScalar(Id, app.st.tabs.items, t_migra) != null and activeIs(app, t_migra);
}
var word_id: Id = 0;
fn injectWord(app: *App) void {
    word_id = inject(app, t_free, 1002, "palavra zebrafina só nesta thread");
}
fn cacheHasThread(app: *App) bool {
    msg_cache.flushDirty(&app.store);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const dec = msg_cache.readChannel(arena.allocator(), t_free) orelse return false;
    return dec.entries.len > 0;
}
fn searchFound(_: *App) bool {
    for (search.results.items) |r| if (r.channel == t_free) return true;
    return false;
}
fn searchOpened(app: *App) bool {
    return activeIs(app, t_free) and !search.open;
}
fn paletteHasThread(app: *App) bool {
    if (!app.st.palette.open) return false;
    for (app.st.palette.items.items) |it| if (it.kind == .channel and it.id == t_bench) return true;
    return false;
}
fn paletteOpened(app: *App) bool {
    return activeIs(app, t_bench) and !app.st.palette.open;
}

// --- Vindo do Discord -----------------------------------------------------------------

fn testThread(parent: Id, id: Id, archived: bool) types.Channel {
    const ca = std.heap.c_allocator;
    return .{ .id = id, .guild = guild0, .parent = parent, .name = ca.dupe(u8, "vinda do gateway") catch "", .topic = ca.dupe(u8, "") catch "", .thread = .{ .archived = archived, .last_message = id } };
}
var ev_thread: Id = 0;
fn pushCreate(app: *App) void {
    ev_thread = types.makeSnowflake(gw.nowMs(), 0x3c001);
    app.events.push(.{ .channel_upsert = testThread(zig, ev_thread, false) });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn evCreated(app: *App) bool {
    const idx = app.store.threadIndex(zig) orelse return false;
    return idx.shown[0] == ev_thread;
}
fn pushArchive(app: *App) void {
    app.events.push(.{ .channel_upsert = testThread(zig, ev_thread, true) });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn evArchived(app: *App) bool {
    const idx = app.store.threadIndex(zig) orelse return false;
    return std.mem.indexOfScalar(Id, idx.shown[0..idx.n_shown], ev_thread) == null and app.store.channel(ev_thread) != null;
}
fn pushSync(app: *App) void {
    const ca = std.heap.c_allocator;
    const parents = ca.alloc(Id, 1) catch return;
    parents[0] = zig;
    // As ativas do #zig mais a que tinha sido arquivada, que volta.
    const keep = app.store.threadsOf(zig);
    const all = ca.alloc(types.Channel, keep.len) catch return;
    var n: usize = 0;
    for (keep) |id| {
        const cs = app.store.channel(id) orelse continue;
        const t = cs.info.thread orelse continue;
        if (t.archived and id != ev_thread) continue;
        all[n] = .{ .id = id, .guild = guild0, .parent = zig, .name = ca.dupe(u8, cs.info.name) catch "", .topic = ca.dupe(u8, "") catch "", .thread = .{ .joined = t.joined, .joined_known = true, .message_count = t.message_count, .last_message = t.last_message } };
        n += 1;
    }
    app.events.push(.{ .thread_list_sync = .{ .guild = guild0, .parents = parents, .threads = all[0..n] } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn evSynced(app: *App) bool {
    return if (info(app, ev_thread)) |t| !t.archived else false;
}
fn deleteAsked(app: *App) bool {
    return app.st.popup == .menu and qa.find("menu:Cancelar") != null and app.store.channel(ev_thread) != null;
}
fn evStillThere(app: *App) bool {
    return app.st.popup == .none and app.store.channel(ev_thread) != null;
}
fn tConfirmDelete(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(ev_thread) orelse return "";
    return mk(b, "menu:Excluir «{s}» para sempre", .{cs.info.name});
}
fn bannerShown(_: *App) bool {
    return qa.find("guild-banner") != null;
}
var extra: [5]Id = @splat(0);
fn pushMany(app: *App) void {
    for (&extra, 0..) |*id, i| {
        id.* = types.makeSnowflake(gw.nowMs(), 0x3c100 + i);
        app.events.push(.{ .channel_upsert = testThread(zig, id.*, false) });
    }
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn pastCap(app: *App) bool {
    const idx = app.store.threadIndex(zig) orelse return false;
    return idx.n_shown == @import("core/store.zig").thread_rows_cap and idx.more > 0 and qa.find("thread-more:505010") != null;
}
fn panelShowsAll(app: *App) bool {
    return app.st.popup == .threads and forum.visible(true).len == @as(usize, @intCast(app.store.threadIndex(zig).?.n_shown)) + app.store.threadIndex(zig).?.more;
}
fn dropMany(app: *App) void {
    for (extra) |id| app.events.push(.{ .channel_delete = id });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn backToThree(app: *App) bool {
    const idx = app.store.threadIndex(zig) orelse return false;
    return idx.more == 0;
}
fn tRowEv(_: *App, b: []u8) []const u8 {
    return mk(b, "channel:{d}", .{ev_thread});
}
fn evOpen(app: *App) bool {
    return activeIs(app, ev_thread);
}
fn evGone(app: *App) bool {
    return app.store.channel(ev_thread) == null and std.mem.indexOfScalar(Id, app.st.tabs.items, ev_thread) == null;
}

// --- Permissões ---------------------------------------------------------------------

fn readonlyThread(app: *App) bool {
    return activeIs(app, t_geral1) and qa.find("composer-readonly") != null and qa.find("composer") == null;
}
fn tMsgInGeral1(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(geral1) orelse return "";
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        var kb: [40]u8 = undefined;
        const k = mk(&kb, "msgtext:{d}", .{cs.messages.items[i].msg.id});
        if (qa.find(k) != null) return mk(b, "{s}", .{k});
    }
    return "";
}
fn noCreateThread(app: *App) bool {
    return app.st.popup == .menu and qa.find("menu:Criar thread") == null and qa.find("menu:Responder") != null;
}
fn geral1Open(app: *App) bool {
    return activeIs(app, geral1) and loaded(app, geral1);
}
fn lockedRow(_: *App) bool {
    var b: [48]u8 = undefined;
    return qa.find(mk(&b, "locked:{d}", .{t_bugs1})) != null;
}
fn lockedDidNotOpen(app: *App) bool {
    return !activeIs(app, t_bugs1) and app.st.toast.is_error;
}

// --- Fórum --------------------------------------------------------------------------

fn tabForum(app: *App) ?*@import("core/store.zig").ChannelState {
    return app.store.channel(forum0);
}
fn forumOpen(app: *App) bool {
    const cs = tabForum(app) orelse return false;
    return activeIs(app, forum0) and cs.active_page.state == .loaded and cs.active_page.offset == 25 and forum.visible(false).len == 25;
}
fn forumNoComposer(_: *App) bool {
    return qa.find("composer") == null and qa.find("forum-new") != null and qa.find("forum-band") != null;
}
fn noHistoryAsked(app: *App) bool {
    const cs = tabForum(app) orelse return false;
    return cs.history == .none;
}
fn postsDrawn(_: *App) bool {
    const ids = forum.visible(false);
    if (ids.len == 0) return false;
    var b: [40]u8 = undefined;
    return qa.find(mk(&b, "post:{d}", .{ids[0]})) != null;
}
fn hasPreviewAndTags(app: *App) bool {
    const cs = app.store.channel(forum.visible(false)[0]) orelse return false;
    return cs.preview.len > 0 and cs.preview_author != 0 and cs.info.thread.?.tags.len > 0;
}
fn orderedByActivity(app: *App) bool {
    var prev: Id = std.math.maxInt(Id);
    for (forum.visible(false)) |id| {
        const cs = app.store.channel(id) orelse return false;
        const k = @import("core/store.zig").Store.threadActivity(&cs.info);
        if (k > prev) return false;
        prev = k;
    }
    return true;
}
fn orderedByCreation(_: *App) bool {
    var prev: Id = std.math.maxInt(Id);
    for (forum.visible(false)) |id| {
        if (id > prev) return false;
        prev = id;
    }
    return true;
}
fn goEnd(_: *App) void {
    forum.qa_scroll_end = true;
}
fn secondPage(app: *App) bool {
    const cs = tabForum(app) orelse return false;
    return cs.active_page.offset >= 50 and forum.visible(false).len >= 50;
}
fn allPages(app: *App) bool {
    const cs = tabForum(app) orelse return false;
    return !cs.active_page.more and cs.active_page.offset == 60;
}
fn filtered(app: *App) bool {
    const ids = forum.visible(false);
    if (ids.len == 0 or ids.len > 12) return false;
    for (ids) |id| {
        const cs = app.store.channel(id) orelse return false;
        if (std.mem.indexOf(u8, cs.info.name, "Voz") == null and std.mem.indexOf(u8, cs.preview, "voz") == null) return false;
    }
    return true;
}
fn unfiltered(_: *App) bool {
    return forum.visible(false).len >= 50;
}
fn archivedTab(app: *App) bool {
    const ids = forum.visible(false);
    if (ids.len != 8) return false;
    for (ids) |id| if (!(info(app, id) orelse return false).archived) return false;
    return true;
}
var post_id: Id = 0;
fn tFirstPost(_: *App, b: []u8) []const u8 {
    const ids = forum.visible(false);
    if (ids.len == 0) return "";
    post_id = ids[0];
    return mk(b, "post:{d}", .{ids[0]});
}
fn postOpen(app: *App) bool {
    if (!activeIs(app, post_id) or !loaded(app, post_id)) return false;
    const cs = app.store.channel(post_id) orelse return false;
    // A primeira mensagem é o post: sem cartão dela mesma, com a caixa de texto.
    var b: [48]u8 = undefined;
    return cs.messages.items.len > 0 and cs.messages.items[0].msg.id == post_id and qa.find(mk(&b, "thread-card:{d}", .{post_id})) == null and qa.find("composer") != null;
}
fn backOnForum(app: *App) bool {
    return activeIs(app, forum0) and qa.find("forum-new") != null;
}
fn postPopup(app: *App) bool {
    return app.st.popup == .new_post and app.st.popup.new_post.forum == forum0;
}
var posts_before: usize = 0;
fn rememberPosts(app: *App) void {
    posts_before = app.store.threadsOf(forum0).len;
}
fn postPublished(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const t = cs.info.thread orelse return false;
    return cs.info.parent == forum0 and std.mem.eql(u8, cs.info.name, "Meu primeiro post") and t.tags.len == 1 and t.joined and
        std.mem.eql(u8, cs.preview, "Texto do post") and app.store.threadsOf(forum0).len == posts_before + 1 and app.st.popup == .none;
}
fn postOnTop(app: *App) bool {
    const ids = forum.visible(false);
    if (!activeIs(app, forum0) or ids.len == 0) return false;
    const cs = app.store.channel(ids[0]) orelse return false;
    return std.mem.eql(u8, cs.info.name, "Meu primeiro post");
}
fn popupClosed(app: *App) bool {
    return app.st.popup == .none;
}
fn mediaOpen(app: *App) bool {
    const cs = app.store.channel(media0) orelse return false;
    return activeIs(app, media0) and cs.info.media and cs.active_page.state == .loaded;
}
fn cannotPost(app: *App) bool {
    return activeIs(app, media1) and qa.find("forum-new") == null and qa.find("forum-band") == null and qa.find("composer-readonly") != null;
}
pub const ops = [_]Op{
    s("threads: lista de canais"),
    click("guild:505000"),
    click("channel:505010"),
    .{ .expect = .{ .name = "#zig carrega", .check = zigLoaded, .timeout_ms = 3000 } },
    .{ .run = remember },
    expect("as ativas aparecem abaixo do canal pai", listed),
    expect("não lida marcada na thread e no recorte", unreadMarked),
    .{ .shot = "60-threads-lista" },

    s("threads: cartão na mensagem"),
    expect("mensagem que abriu a thread sabe qual é", starterLinked),
    .{ .run = jumpStarter },
    .{ .expect = .{ .name = "o cartão aparece na mensagem", .check = cardShown, .timeout_ms = 3000 } },
    .{ .wait = 200 },
    .{ .shot = "61-threads-cartao" },
    clickD(tCardFree),
    .{ .expect = .{ .name = "clicar no cartão abre a thread", .check = freeOpen, .timeout_ms = 3000 } },
    expect("a thread é uma conversa normal, com começo", freeHasConversation),
    .{ .shot = "62-thread-aberta" },

    s("threads: caixa de texto"),
    click("composer"),
    .{ .text = draft_text },
    click("channel:505010"),
    expect("trocar de canal guarda o rascunho da thread", draftKept),
    clickD(tRowFree),
    expect("voltar à thread traz o rascunho", draftBack),
    click("composer"),
    key(c.ImGuiKey_End),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "enviar na thread conta e apaga o rascunho", .check = sentInThread, .timeout_ms = 3000 } },
    rclickD(tLastInThread),
    expect("menu da mensagem na thread", menuOpen),
    click("menu:Responder"),
    expect("responder dentro da thread", replyArmed),
    click("composer"),
    .{ .text = "resposta na thread" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "a resposta vai com a referência", .check = repliedInThread, .timeout_ms = 3000 } },

    s("threads: não lidas e recolher"),
    .{ .run = injectBench },
    expect("mensagem em outra thread marca não lida e sobe na lista", benchUnread),
    clickD(tRowBench),
    .{ .expect = .{ .name = "abrir marca como lida", .check = benchRead, .timeout_ms = 3000 } },
    click("thread-toggle:505010"),
    expect("recolher esconde as outras e deixa a aberta", collapsed),
    .{ .shot = "63-threads-recolhidas" },
    click("thread-toggle:505010"),
    expect("expandir mostra de novo", expanded),

    s("threads: lista de membros"),
    clickD(tRowFree),
    .{ .expect = .{ .name = "a lista mostra quem está na thread", .check = threadMemberList, .timeout_ms = 3000 } },
    .{ .wait = 100 },
    .{ .shot = "64-thread-membros" },
    clickD(tRowMigra),
    .{ .expect = .{ .name = "sem ninguém listado, fica a lista do canal pai", .check = parentMemberList, .timeout_ms = 3000 } },

    s("threads: menu"),
    rclickD(tRowMigra),
    expect("menu da thread", menuOpen),
    .{ .shot = "65-thread-menu" },
    click("menu:Entrar na thread"),
    expect("entrar na thread", joined),
    rclickD(tRowMigra),
    click("menu:Sair da thread"),
    expect("sair da thread", left),
    rclickD(tRowMigra),
    click("menu:Threads arquivadas"),
    .{ .expect = .{ .name = "arquivadas vêm sob demanda", .check = panelArchived, .timeout_ms = 3000 } },
    .{ .wait = 200 },
    .{ .shot = "66-threads-arquivadas" },
    click("forum-tab:active"),
    expect("o painel mostra as ativas do canal", panelActive),
    click("forum-tab:archived"),
    expect("volta às arquivadas", panelArchived),
    clickD(tFirstArchived),
    .{ .expect = .{ .name = "abrir uma arquivada fecha o painel e a mostra na lista", .check = archivedOpen, .timeout_ms = 3000 } },

    s("threads: criar a partir de uma mensagem"),
    click("channel:505010"),
    .{ .run = scrollEnd },
    .{ .wait = 300 },
    rclickD(tPlainMessage),
    expect("menu da mensagem", menuOpen),
    click("menu:Criar thread"),
    expect("o popup abre com o nome sugerido", newThreadPopup),
    .{ .wait = 200 },
    .{ .shot = "67-criar-thread" },
    click("thread-create"),
    .{ .expect = .{ .name = "a thread nasce, abre e estamos nela", .check = threadCreated, .timeout_ms = 3000 } },
    click("channel:505010"),
    .{ .run = jumpMade },
    .{ .expect = .{ .name = "a mensagem de origem ganha o cartão", .check = cardOnOrigin, .timeout_ms = 3000 } },

    s("threads: abas, tela dividida, cache e busca"),
    rclickD(tRowMigra),
    click("menu:Abrir ao lado"),
    .{ .expect = .{ .name = "thread abre ao lado", .check = paneWithThread, .timeout_ms = 2000 } },
    .{ .wait = 300 },
    .{ .shot = "68-thread-mosaico" },
    click("pane-close:1"),
    expect("fecha o painel", paneClosed),
    rclickD(tRowMigra),
    click("menu:Abrir em nova aba"),
    expect("thread abre em nova aba", tabOpened),
    clickD(tRowFree),
    .{ .run = injectWord },
    .{ .wait = 150 },
    .{ .expect = .{ .name = "a thread vai para o cache em disco", .check = cacheHasThread, .timeout_ms = 2000 } },
    .{ .key = .{ .key = c.ImGuiKey_F, .ctrl = true } },
    .{ .text = "zebrafina" },
    .{ .expect = .{ .name = "a busca acha mensagem de thread", .check = searchFound, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "o resultado abre a thread", .check = searchOpened, .timeout_ms = 2000 } },
    .{ .key = .{ .key = c.ImGuiKey_K, .ctrl = true } },
    .{ .text = "benchmarks" },
    .{ .expect = .{ .name = "a paleta acha a thread", .check = paletteHasThread, .timeout_ms = 2000 } },
    key(c.ImGuiKey_Enter),
    expect("a paleta abre a thread", paletteOpened),

    s("threads: eventos do gateway"),
    .{ .run = pushCreate },
    expect("THREAD_CREATE entra no topo da lista do pai", evCreated),
    .{ .run = pushArchive },
    expect("THREAD_UPDATE arquivando tira da lista e não apaga", evArchived),
    .{ .run = pushSync },
    expect("THREAD_LIST_SYNC traz de volta", evSynced),
    .{ .wait = 100 },
    clickD(tRowEv),
    expect("abre a que veio do gateway", evOpen),
    rclickD(tRowEv),
    click("menu:Excluir thread…"),
    expect("excluir pede confirmação e ainda não apagou", deleteAsked),
    click("menu:Cancelar"),
    expect("cancelar não apaga", evStillThere),
    rclickD(tRowEv),
    click("menu:Excluir thread…"),
    clickD(tConfirmDelete),
    .{ .expect = .{ .name = "excluir apaga a thread e fecha a aba", .check = evGone, .timeout_ms = 3000 } },
    // A categoria de cima recolhida: abre espaço para as linhas novas.
    click("category:505004"),
    .{ .run = pushMany },
    expect("passou do teto: a lista mostra algumas e \"mais N\"", pastCap),
    click("thread-more:505010"),
    .{ .expect = .{ .name = "\"mais N\" abre o painel com todas", .check = panelShowsAll, .timeout_ms = 3000 } },
    key(c.ImGuiKey_Escape),
    .{ .run = dropMany },
    expect("apagadas, a lista volta", backToThree),
    click("category:505004"),

    s("banner do servidor"),
    click("guild:501000"),
    .{ .expect = .{ .name = "servidor com banner mostra a imagem no topo", .check = bannerShown, .timeout_ms = 3000 } },
    .{ .shot = "68b-banner" },

    s("threads: permissões herdadas do pai"),
    click("guild:507000"),
    click("channel:507005"),
    .{ .expect = .{ .name = "#geral do segundo servidor carrega", .check = geral1Open, .timeout_ms = 3000 } },
    .{ .wait = 200 },
    rclickD(tMsgInGeral1),
    expect("sem create_public_threads: nada de \"Criar thread\"", noCreateThread),
    key(c.ImGuiKey_Escape),
    clickD(tRowGeral1),
    .{ .expect = .{ .name = "sem send_messages_in_threads: a caixa vira aviso", .check = readonlyThread, .timeout_ms = 3000 } },
    .{ .wait = 150 },
    .{ .shot = "69-thread-sem-permissao" },
    expect("pai trancado: a thread tem cadeado", lockedRow),
    clickD(tRowBugs1),
    expect("clicar só avisa, não abre", lockedDidNotOpen),

    s("fórum: lista de posts"),
    click("guild:505000"),
    click("channel:505031"),
    .{ .expect = .{ .name = "abrir o fórum busca a primeira página", .check = forumOpen, .timeout_ms = 3000 } },
    expect("no lugar da conversa e da caixa: a lista e \"Novo post\"", forumNoComposer),
    expect("fórum não pede histórico de mensagens", noHistoryAsked),
    expect("os posts estão na tela", postsDrawn),
    expect("cada post tem prévia, autor e tags", hasPreviewAndTags),
    expect("ordem por atividade", orderedByActivity),
    .{ .wait = 200 },
    .{ .shot = "70-forum" },
    click("forum-sort"),
    expect("ordem por criação", orderedByCreation),
    click("forum-sort"),
    expect("volta à atividade", orderedByActivity),
    .{ .run = goEnd },
    .{ .expect = .{ .name = "chegar ao fim busca a página seguinte", .check = secondPage, .timeout_ms = 3000 } },
    .{ .run = goEnd },
    .{ .expect = .{ .name = "até acabar", .check = allPages, .timeout_ms = 3000 } },
    click("forum-search"),
    .{ .text = "voz" },
    expect("a busca filtra aqui mesmo, por título e prévia", filtered),
    .{ .wait = 150 },
    .{ .shot = "71-forum-busca" },
    click("forum-search"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    expect("limpar a busca traz tudo de volta", unfiltered),
    click("forum-tab:archived"),
    .{ .expect = .{ .name = "aba dos arquivados, sob demanda", .check = archivedTab, .timeout_ms = 3000 } },
    .{ .wait = 150 },
    .{ .shot = "72-forum-arquivados" },
    click("forum-tab:active"),
    expect("volta aos ativos", unfiltered),

    s("fórum: abrir um post"),
    clickD(tFirstPost),
    .{ .expect = .{ .name = "o post abre como thread", .check = postOpen, .timeout_ms = 3000 } },
    .{ .shot = "73-post-aberto" },
    click("header-parent"),
    expect("o cabeçalho volta para o fórum", backOnForum),

    s("fórum: novo post"),
    .{ .run = rememberPosts },
    click("forum-new"),
    expect("\"Novo post\" abre o formulário", postPopup),
    click("post-submit"),
    expect("sem título e texto, publicar não faz nada", postPopup),
    click("post-title"),
    .{ .text = "Meu primeiro post" },
    click("post-tag:1"),
    click("post-body"),
    .{ .text = "Texto do post" },
    .{ .wait = 100 },
    .{ .shot = "74-novo-post" },
    click("post-submit"),
    .{ .expect = .{ .name = "publicar cria e abre o post, com a tag e a prévia", .check = postPublished, .timeout_ms = 3000 } },
    click("header-parent"),
    expect("o post novo aparece em cima na lista", postOnTop),
    click("forum-band"),
    expect("a faixa de baixo também abre o formulário", postPopup),
    click("post-cancel"),
    expect("cancelar fecha", popupClosed),

    s("fórum: canal de mídia e permissões"),
    click("channel:505032"),
    .{ .expect = .{ .name = "canal de mídia abre a lista", .check = mediaOpen, .timeout_ms = 3000 } },
    click("guild:507000"),
    click("channel:507032"),
    .{ .expect = .{ .name = "sem send_messages: sem \"Novo post\"", .check = cannotPost, .timeout_ms = 3000 } },
    .{ .wait = 150 },
    .{ .shot = "75-forum-sem-permissao" },

    s("clicar em tudo: threads e fórum"),
    click("guild:505000"),
    click("channel:505031"),
    .{ .wait = 200 },
    .{ .sweep = &.{ "forum-sort", "forum-tab:", "forum-new", "forum-band", "post:" } },
    key(c.ImGuiKey_Escape),
    .{ .run = themeZig },
    .{ .wait = 200 },
    .{ .sweep = &.{"thread-toggle:"} },
    click("guild:500000"),
    click("channel:500005"),
};

/// Para a bateria de cada tema: fórum e thread na tela, com print.
fn act(app: *App, id: Id) void {
    app.actions.append(app.gpa, .{ .select_channel = id }) catch {};
    platform.Window.wake(app.win.wake_type, .gateway);
}
var theme_back: Id = 0;
fn themeForum(app: *App) void {
    theme_back = app.st.activeChannel() orelse 0;
    act(app, forum0);
}
fn themeForumOpen(app: *App) bool {
    return forumOpen(app) and qa.find("forum-new") != null;
}
fn themePost(app: *App) void {
    const ids = forum.visible(false);
    if (ids.len > 0) act(app, ids[0]);
}
fn themePostOpen(app: *App) bool {
    const cs = app.store.channel(app.st.activeChannel() orelse return false) orelse return false;
    return cs.info.thread != null and cs.history == .loaded;
}
fn themeZig(app: *App) void {
    act(app, zig);
}
fn themeZigOpen(app: *App) bool {
    remember(app);
    return zigLoaded(app);
}
fn themeJump(app: *App) void {
    app.st.jump = byCount(app, zig, 7);
}
fn themeCard(app: *App) bool {
    var b: [48]u8 = undefined;
    return qa.find(mk(&b, "thread-card:{d}", .{byCount(app, zig, 7)})) != null;
}
fn themeBack(app: *App) void {
    act(app, theme_back);
}
fn themeBackOpen(app: *App) bool {
    return activeIs(app, theme_back);
}

pub const ops_theme = [_]Op{
    s("threads e fórum neste tema"),
    .{ .run = themeForum },
    .{ .expect = .{ .name = "o fórum abre neste tema", .check = themeForumOpen, .timeout_ms = 3000 } },
    .{ .wait = 150 },
    .{ .shot = "tema-forum" },
    .{ .run = themePost },
    .{ .expect = .{ .name = "o post abre como conversa", .check = themePostOpen, .timeout_ms = 3000 } },
    .{ .run = themeZig },
    .{ .expect = .{ .name = "canal com threads", .check = themeZigOpen, .timeout_ms = 3000 } },
    .{ .run = themeJump },
    .{ .expect = .{ .name = "o cartão aparece neste tema", .check = themeCard, .timeout_ms = 3000 } },
    .{ .wait = 150 },
    .{ .shot = "tema-threads" },
    .{ .run = themeBack },
    expect("volta para onde estava", themeBackOpen),
};

fn zigLoaded(app: *App) bool {
    // O cache do disco aparece antes: o que vale é o histórico que chega por cima.
    return activeIs(app, zig) and loaded(app, zig) and !app.store.channel(zig).?.cached;
}
