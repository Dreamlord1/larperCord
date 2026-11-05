//! QA dos plugins (entra na bateria geral do qa_runner.zig): os plugins incluídos,
//! usados como uma pessoa usa, com o painel, os menus e as notas de verdade. O
//! HTTP fala com um servidor de mentira aqui mesmo (127.0.0.1), que também conta
//! o que recebeu: nada sai para a internet e nada fala com o Discord.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const types = @import("core/types.zig");
const gw = @import("net/fake_gateway.zig");
const sys = @import("platform/sys.zig");
const platform = @import("platform/window.zig");
const engine = @import("plugins/engine.zig");
const host = @import("plugins/host.zig");
const http_curl = @import("plugins/http_curl.zig");
const exemplos = @import("plugin_examples");
const Id = types.Id;
const Plugin = engine.Plugin;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn rdyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}
// A resposta passa pela outra thread: em máquina ocupada, leva o tempo que levar.
/// Botão direito no texto da mensagem: no meio da linha pode estar a barra de ações.
const rmsg: Op = .{ .rclick = .{ .dyn_at = .{ .f = tMsgText, .fx = 0.25, .fy = 0.5 } } };
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 8000 } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 12000 } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const geral: Id = 500005;
const memes: Id = 500006;

fn plugin(app: *App, name: []const u8) ?*Plugin {
    for (app.plugins.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn toastHas(app: *App, needle: []const u8) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), needle) != null;
}

fn inputText(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}

fn openIs(app: *App, name: []const u8) bool {
    const p = app.plugins.panel_open orelse return false;
    return std.mem.eql(u8, p.name, name);
}

/// A primeira marcação com o prefixo, pronta para clicar.
fn firstMark(prefix: []const u8, buf: []u8) []const u8 {
    var keys: [16][56]u8 = undefined;
    var lens: [16]u8 = undefined;
    const n = qa.keysWith(&.{prefix}, &keys, &lens);
    if (n == 0) return prefix;
    const k = keys[0][0..lens[0]];
    @memcpy(buf[0..k.len], k);
    return buf[0..k.len];
}

fn anyMark(prefix: []const u8) bool {
    var keys: [2][56]u8 = undefined;
    var lens: [2]u8 = undefined;
    return qa.keysWith(&.{prefix}, &keys, &lens) > 0;
}

// --- Arquivos ---------------------------------------------------------------------

pub fn wipeDataPub(app: *App) void {
    wipeData(app);
}

/// Sem as sobras de outra rodada: nem plugins, nem os dados deles.
fn wipeData(app: *App) void {
    var pb: [96]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&pb, "qa-out/plugin-data/{d}", .{app.store.me}, 0) catch return;
    var count: c_int = 0;
    if (c.SDL_GlobDirectory(dir.ptr, "*", 0, &count)) |names| {
        defer c.SDL_free(@ptrCast(names));
        for (0..@intCast(count)) |i| {
            var fb: [160]u8 = undefined;
            const f = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ dir, std.mem.span(names[i] orelse continue) }, 0) catch continue;
            _ = c.SDL_RemovePath(f.ptr);
        }
    }
}

fn writeBundled(_: *App) void {
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    for (exemplos.list) |ex| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{ex.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, ex.source.ptr, ex.source.len);
    }
}

pub fn removeAllPlugins(_: *App) void {
    var count: c_int = 0;
    if (c.SDL_GlobDirectory("qa-out/plugins", "*.lua", 0, &count)) |names| {
        defer c.SDL_free(@ptrCast(names));
        for (0..@intCast(count)) |i| {
            var fb: [160]u8 = undefined;
            const f = std.fmt.bufPrintSentinel(&fb, "qa-out/plugins/{s}", .{std.mem.span(names[i] orelse continue)}, 0) catch continue;
            _ = c.SDL_RemovePath(f.ptr);
        }
    }
}

// --- O servidor de mentira ----------------------------------------------------------

var srv_started = false;
var srv_sock: sys.Socket = sys.no_socket;
var srv_lock: ?*c.SDL_Mutex = null;
var srv_count: u32 = 0;
var srv_last: [4096]u8 = undefined;
var srv_last_len: usize = 0;
/// Algum pedido trouxe algo que nunca deveria sair.
var srv_leak = false;

const translated_body = "{\"responseData\":{\"translatedText\":\"texto traduzido pelo servidor\",\"match\":1},\"responseStatus\":200}";

fn startServer(_: *App) void {
    if (!http_curl.qa_builds or srv_started) return;
    var port: u16 = 0;
    srv_sock = sys.tcpListenLocal(&port) orelse return;
    srv_lock = c.SDL_CreateMutex();
    const t = c.SDL_CreateThread(serverMain, "qa-http", null) orelse return;
    c.SDL_DetachThread(t);
    srv_started = true;
    const b = std.fmt.bufPrint(&http_curl.qa_base, "http://127.0.0.1:{d}", .{port}) catch return;
    http_curl.qa_base_len = b.len;
}

fn serverMain(_: ?*anyopaque) callconv(.c) c_int {
    while (true) {
        const client = sys.tcpAccept(srv_sock) orelse return 0;
        defer sys.closeSocket(client);
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const got = sys.tcpRecv(client, buf[n..], 1000);
            if (got.len == 0) break;
            n += got.len;
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |head_end| {
                // Com corpo: espera ele chegar também.
                const need = contentLength(buf[0..head_end]);
                if (n >= head_end + 4 + need) break;
            }
        }
        const req = buf[0..n];
        c.SDL_LockMutex(srv_lock);
        srv_count += 1;
        srv_last_len = @min(req.len, srv_last.len);
        @memcpy(srv_last[0..srv_last_len], req[0..srv_last_len]);
        for ([_][]const u8{ "authorization:", "cookie:", "x-super-properties:", "x-discord", "x-fingerprint:" }) |bad| {
            if (std.ascii.findIgnoreCase(req, bad) != null) srv_leak = true;
        }
        c.SDL_UnlockMutex(srv_lock);
        reply(client, req);
    }
}

fn contentLength(head: []const u8) usize {
    const at = std.ascii.findIgnoreCase(head, "content-length:") orelse return 0;
    const rest = head[at + "content-length:".len..];
    const end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
    return std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " "), 10) catch 0;
}

fn reply(client: sys.Socket, req: []const u8) void {
    var head: [256]u8 = undefined;
    if (std.mem.startsWith(u8, req, "GET /get")) {
        sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{translated_body.len}) catch return);
        sys.tcpSend(client, translated_body);
    } else if (std.mem.startsWith(u8, req, "GET /big")) {
        // Mais que o limite, sem avisar o tamanho.
        sys.tcpSend(client, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
        var chunk: [65536]u8 = undefined;
        @memset(&chunk, 'x');
        for (0..32) |_| sys.tcpSend(client, &chunk);
    } else if (std.mem.startsWith(u8, req, "GET /redir")) {
        sys.tcpSend(client, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/segredo\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else if (std.mem.startsWith(u8, req, "POST /echo")) {
        const at = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const body = req[at + 4..];
        sys.tcpSend(client, std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return);
        sys.tcpSend(client, body);
    } else {
        sys.tcpSend(client, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
}

fn serverCount() u32 {
    c.SDL_LockMutex(srv_lock);
    defer c.SDL_UnlockMutex(srv_lock);
    return srv_count;
}

fn serverLastHas(needle: []const u8) bool {
    c.SDL_LockMutex(srv_lock);
    defer c.SDL_UnlockMutex(srv_lock);
    return std.mem.indexOf(u8, srv_last[0..srv_last_len], needle) != null;
}

// --- Mensagens "de outras pessoas" -----------------------------------------------------

var seq: u64 = 0;

fn inject(app: *App, channel: Id, author: Id, text: []const u8) Id {
    const ca = std.heap.c_allocator;
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x7a000 + seq);
    const content = ca.dupe(u8, text) catch return 0;
    app.events.push(.{ .message_create = .{ .id = id, .channel = channel, .author = author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}

fn deleteMsg(app: *App, channel: Id, id: Id) void {
    app.events.push(.{ .message_delete = .{ .channel = channel, .id = id } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

/// Mensagem usada nos menus: uma recente de outra pessoa, no canal aberto.
var msg_id: Id = 0;
var msg_author: Id = 0;

fn pickOther(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        // Só texto: em cima de um link, o botão direito é do link.
        if (m.msg.author == app.store.me or m.msg.id == 0 or m.msg.system != .none or m.msg.content.len == 0 or std.mem.indexOf(u8, m.msg.content, "://") != null) continue;
        // E à vista, longe do cabeçalho e da caixa de texto.
        const r = qa.find(mark(&mbuf, "msgtext:{d}", m.msg.id)) orelse continue;
        if (r.y < 120 or r.bottom() > app.io.*.DisplaySize.y - 120) continue;
        msg_id = m.msg.id;
        msg_author = m.msg.author;
        return;
    }
}

var mbuf: [64]u8 = undefined;

fn mark(buf: []u8, comptime fmt: []const u8, id: Id) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{id}) catch "";
}

fn tMsgText(_: *App, buf: []u8) []const u8 {
    return mark(buf, "msgtext:{d}", msg_id);
}

fn tUser(_: *App, buf: []u8) []const u8 {
    return mark(buf, "user:{d}", msg_author);
}

// --- Thread e página ----------------------------------------------------------------

fn threadUp(app: *App) bool {
    return app.plugins.threadRunning() and plugin(app, "bookmarks.lua") != null;
}

fn bundledRunning(app: *App) bool {
    for (exemplos.list) |ex| {
        const p = plugin(app, ex.name) orelse return false;
        if (p.status() != .running) return false;
    }
    return true;
}

fn cardsShow(_: *App) bool {
    return qa.find("plugin-card:bookmarks.lua") != null and qa.find("plugin-chip:bookmarks.lua:menu") != null and
        qa.find("plugin-open:bookmarks.lua") != null and qa.find("plugin-chip:shrug.lua:legado") != null;
}

fn hostCardShows(_: *App) bool {
    return qa.find("plugin-chip:translate.lua:http") != null and qa.find("host:translate.lua:api.mymemory.translated.net") != null;
}

// --- Favoritos ------------------------------------------------------------------------

fn toGeral(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = geral, .id = 0 } });
}

fn toMemes(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = memes, .id = 0 } });
}

fn bookmarkBadge(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-badge:{d}", msg_id)) != null;
}

fn noBadge(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-badge:{d}", msg_id)) == null;
}

fn panelFavoritos(app: *App) bool {
    return openIs(app, "bookmarks.lua") and qa.find("pp-panel") != null;
}
fn panelFavoritosSemConfig(app: *App) bool {
    return panelFavoritos(app) and !app.st.settings.open;
}

fn tItem(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-item:{d}", msg_id);
}

fn itemThere(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", msg_id)) != null;
}

fn itemGone(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", msg_id)) == null and qa.find("pp-panel") != null;
}

fn onMemes(app: *App) bool {
    return app.st.activeChannel() == memes;
}

fn jumpedBack(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", msg_id)) != null;
}

fn tRemove(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-btn:rm{d}", msg_id);
}

fn layoutMoved(_: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    // Encaixado: a caixa de mensagem não fica embaixo do painel.
    return comp.right() <= pn.x + 1 or comp.x >= pn.right() - 1;
}

fn dockedLeft(app: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    return app.plugins.panel_left and pn.x < 1 and comp.x >= pn.right() - 1;
}

fn dockedRight(app: *App) bool {
    const pn = qa.find("pp-panel") orelse return false;
    const comp = qa.find("composer") orelse return false;
    return !app.plugins.panel_left and comp.right() <= pn.x + 1;
}

var width0: f32 = 0;
fn rememberWidth(app: *App) void {
    width0 = app.plugins.panel_w;
}
fn widthChanged(app: *App) bool {
    return @abs(app.plugins.panel_w - width0) > 40;
}

fn openFavoritos(app: *App) void {
    app.plugins.openPanel(plugin(app, "bookmarks.lua"));
}

fn panelClosed(app: *App) bool {
    return app.plugins.panel_open == null and qa.find("pp-panel") == null;
}

// --- Lembretes -------------------------------------------------------------------------

var desktop0: u32 = 0;
fn rememberDesktop(_: *App) void {
    desktop0 = host.qa_desktop;
}
fn reminderSet(app: *App) bool {
    return toastHas(app, "Vou lembrar");
}
fn reminderFired(_: *App) bool {
    return host.qa_desktop > desktop0 and std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "teste do lembrete") != null;
}
fn panelLembretes(app: *App) bool {
    return openIs(app, "reminders.lua") and qa.find("pp-btn:in1h") != null;
}
fn tReminderItem(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-item:r", buf);
}
fn hasReminder(_: *App) bool {
    return anyMark("pp-item:r");
}
fn noReminder(_: *App) bool {
    return !anyMark("pp-item:r") and qa.find("pp-panel") != null;
}
fn tReminderCancel(_: *App, buf: []u8) []const u8 {
    return firstMark("pp-btn:cancel", buf);
}
fn restartAll(app: *App) void {
    const me = app.plugins.account;
    app.plugins.setAccount(0);
    app.plugins.setAccount(me);
}
fn firedOldShown(_: *App) bool {
    return anyMark("pp-item:old");
}
fn reminderJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", msg_id)) != null;
}
fn timeRefused(app: *App) bool {
    return toastHas(app, "Não entendi esse tempo");
}
fn pendingGone(_: *App) bool {
    return qa.find("pp-btn:in1h") == null and !anyMark("pp-item:r");
}
fn panelLembretesAberto(app: *App) bool {
    return openIs(app, "reminders.lua") and qa.find("pp-panel") != null;
}

// --- Destaques ---------------------------------------------------------------------------

var hit_id: Id = 0;
fn sendUrgent(app: *App) void {
    hit_id = inject(app, geral, 1001, "isso é URGENTE, pessoal");
}
fn highlightToast(app: *App) bool {
    return toastHas(app, "★ urgente");
}
fn hitInPanel(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", hit_id)) != null;
}
fn hitBadge(app: *App) bool {
    // Pelo índice: depois de um pulo, a mensagem nova pode estar fora da tela.
    const f = app.store.findAny(hit_id) orelse return false;
    const v = app.plugins.deco.view(f.m, app.store.me);
    return v.n > 0 and std.mem.indexOf(u8, v.slice()[0].badge, "urgente") != null;
}
fn tHit(_: *App, buf: []u8) []const u8 {
    return mark(buf, "pp-item:{d}", hit_id);
}
fn hitJumped(app: *App) bool {
    return app.st.activeChannel() == geral and qa.find(mark(&mbuf, "msg:{d}", hit_id)) != null;
}
fn deleteHit(app: *App) void {
    deleteMsg(app, geral, hit_id);
}
fn hitGone(_: *App) bool {
    return qa.find(mark(&mbuf, "pp-item:{d}", hit_id)) == null;
}
fn hitDiskClean(app: *App) bool {
    // No disco nunca fica o texto de ninguém.
    var pb: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "qa-out/plugin-data/{d}/highlights.lua.json", .{app.store.me}, 0) catch return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    const text = @as([*]const u8, @ptrCast(data))[0..size];
    return std.mem.indexOf(u8, text, "pessoal") == null and std.mem.indexOf(u8, text, "urgente") != null;
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
fn panelDestaques(app: *App) bool {
    return openIs(app, "highlights.lua");
}
fn wordThere(_: *App) bool {
    return qa.find("pp-item:w1") != null;
}
fn noWord(_: *App) bool {
    return qa.find("pp-item:w1") == null;
}

// --- Filtro ----------------------------------------------------------------------------

var filtered_id: Id = 0;
var other_id: Id = 0;
fn sendSpoiler(app: *App) void {
    filtered_id = inject(app, geral, 1001, "olha um spoiler aqui");
    other_id = inject(app, geral, 1001, "mensagem que passa");
}
fn isCollapsed(app: *App, id: Id) bool {
    const f = app.store.findAny(id) orelse return false;
    return app.plugins.deco.collapses(f.m, app.store.me) and !app.st.filtros.revealed.contains(id);
}
fn stickBottom(app: *App) void {
    app.st.scrollOf(geral).stick_bottom = true;
}
fn collapsed(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", filtered_id)) != null and qa.find(mark(&mbuf, "msgtext:{d}", other_id)) != null;
}
fn tShow(_: *App, buf: []u8) []const u8 {
    return mark(buf, "hidden-show:{d}", filtered_id);
}
fn shown(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", filtered_id)) == null and qa.find(mark(&mbuf, "msgtext:{d}", filtered_id)) != null;
}
fn panelFiltro(app: *App) bool {
    return openIs(app, "filter.lua");
}
fn userCollapsed(app: *App) bool {
    return isCollapsed(app, other_id);
}
fn userBack(app: *App) bool {
    return !isCollapsed(app, other_id);
}
fn pausedLabel(_: *App) bool {
    return qa.find("pp-btn:pause") != null;
}
fn pickUserMessage(app: *App) void {
    msg_id = other_id;
    msg_author = if (app.store.findAny(other_id)) |f| f.m.msg.author else 0;
}
fn hasUserRow(_: *App) bool {
    return qa.find("pp-item:u1") != null;
}

// --- Trechos ----------------------------------------------------------------------------

fn panelTrechos(app: *App) bool {
    return openIs(app, "snippets.lua");
}
fn snippetSaved(_: *App) bool {
    return qa.find("pp-item:ola") != null;
}
fn snippetGone(_: *App) bool {
    return qa.find("pp-item:ola") == null;
}
fn snippetEnterSaved(_: *App) bool {
    return qa.find("pp-item:enter") != null;
}
fn snippetDraftFromMessage(app: *App) bool {
    return panelTrechos(app) and qa.find("pp-input:text") != null;
}
fn snippetFromMessageSaved(_: *App) bool {
    return qa.find("pp-item:da-mensagem") != null;
}
fn inserted(app: *App) bool {
    return std.mem.indexOf(u8, inputText(app), "olá, tudo bem?") != null;
}
fn notSent(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return true;
    return !std.mem.eql(u8, items[items.len - 1].msg.content, "olá, tudo bem?");
}
fn insertedAndNotSent(app: *App) bool {
    return inserted(app) and notSent(app);
}
fn inputEmpty(app: *App) bool {
    return inputText(app).len == 0;
}

// --- Tradução ---------------------------------------------------------------------------

const translate_host = "host:translate.lua:api.mymemory.translated.net";
var count0: u32 = 0;
fn rememberCount(_: *App) void {
    count0 = serverCount();
}
fn asksApproval(app: *App) bool {
    return toastHas(app, "Aprove");
}
fn nothingSent(_: *App) bool {
    return serverCount() == count0;
}
fn approved(app: *App) bool {
    return app.plugins.isApproved("translate.lua", "api.mymemory.translated.net");
}
fn notApproved(app: *App) bool {
    return !approved(app);
}
fn noteShows(app: *App) bool {
    const v = viewOf(app) orelse return false;
    for (v.slice()) |*part| {
        if (std.mem.indexOf(u8, part.note, "texto traduzido pelo servidor") != null) return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) != null;
    }
    return false;
}
fn viewOf(app: *App) ?engine.deco.View {
    const f = app.store.findAny(msg_id) orelse return null;
    return app.plugins.deco.view(f.m, app.store.me);
}
fn requestClean() bool {
    return !srv_leak;
}
fn requestOk(_: *App) bool {
    return requestClean() and serverLastHas("GET /get?q=") and serverLastHas("langpair=Autodetect%7Cpt") and !serverLastHas("Cookie") and !serverLastHas("Authorization");
}
fn tClose(_: *App, buf: []u8) []const u8 {
    return mark(buf, "deco-close:{d}", msg_id);
}
fn noteGone(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) == null;
}

// --- Estatísticas ------------------------------------------------------------------------

fn panelStats(app: *App) bool {
    return openIs(app, "stats.lua") and qa.find("pp-bar:top1") != null and qa.find("pp-text:total") != null;
}

// --- Limites do HTTP, com o curl de verdade ---------------------------------------------

const qa_http_plugin =
    \\-- @name QA HTTP
    \\-- @capabilities http, notify
    \\-- @hosts qa.exemplo.com
    \\local function mostra(nome)
    \\  return function(r)
    \\    larper.notify(nome .. "|" .. tostring(r.ok) .. "|" .. tostring(r.status) .. "|" .. tostring(r.error) .. "|" .. #r.body)
    \\  end
    \\end
    \\larper.command("/qa-big", function() larper.http.get("https://qa.exemplo.com/big", mostra("big")) end)
    \\larper.command("/qa-redir", function() larper.http.get("https://qa.exemplo.com/redir", mostra("redir")) end)
    \\larper.command("/qa-post", function()
    \\  larper.http.post("https://qa.exemplo.com/echo", { body = "corpo-do-post", headers = { ["Content-Type"] = "text/plain", Cookie = "a=b", Authorization = "c" } }, mostra("post"))
    \\end)
    \\larper.command("/qa-plain", function()
    \\  larper.notify("plain|" .. tostring(pcall(larper.http.get, "http://qa.exemplo.com/x", mostra("x"))))
    \\end)
;

const qa_slow_plugin =
    \\-- @name QA lento
    \\-- @capabilities notify
    \\larper.command("/qa-lento", function()
    \\  -- Mais de um segundo na thread dos plugins, com poucas instruções: o tempo
    \\  -- passa em C. Um laço de Lua contra o relógio estoura o limite de instruções
    \\  -- onde ler o relógio é barato (no Windows).
    \\  local s = string.rep("a", 100000)
    \\  local t = os.time()
    \\  local n = 0
    \\  while os.time() - t < 2 and n < 200 do
    \\    pcall(string.find, s, ".-.-.-b")
    \\    n = n + 1
    \\  end
    \\  larper.notify("lento acabou")
    \\end)
;

fn writeExtra(_: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/qahttp.lua", qa_http_plugin.ptr, qa_http_plugin.len);
    _ = c.SDL_SaveFile("qa-out/plugins/qalento.lua", qa_slow_plugin.ptr, qa_slow_plugin.len);
}
fn removeExtra(_: *App) void {
    _ = c.SDL_RemovePath("qa-out/plugins/qahttp.lua");
    _ = c.SDL_RemovePath("qa-out/plugins/qalento.lua");
}
fn extraLoaded(app: *App) bool {
    const a = plugin(app, "qahttp.lua") orelse return false;
    const b = plugin(app, "qalento.lua") orelse return false;
    return a.status() == .running and b.status() == .running and app.plugins.n_commands > 0;
}
fn bigRefused(app: *App) bool {
    return toastHas(app, "big|false|0|too_big|0");
}
fn redirectNotFollowed(app: *App) bool {
    return toastHas(app, "redir|false|302|");
}
fn postEchoed(app: *App) bool {
    return toastHas(app, "post|true|200|nil|13") and serverLastHas("corpo-do-post") and !serverLastHas("Cookie") and !serverLastHas("Authorization") and !srv_leak;
}
fn plainRefused(app: *App) bool {
    return toastHas(app, "plain|false");
}

var loops0: u32 = 0;
fn loopsNow(app: *App) u32 {
    const w = app.plugins.worker orelse return 0;
    return w.loops.load(.monotonic);
}
fn rememberLoops(app: *App) void {
    loops0 = loopsNow(app);
}
fn loopsSame(app: *App) bool {
    return loopsNow(app) == loops0;
}

var frames_seen: u32 = 0;
var frames_until_done: ?u32 = null;
fn clearFrames(_: *App) void {
    frames_seen = 0;
    frames_until_done = null;
}
/// Cada conferência é um quadro; valem os de antes do Lua acabar. Com o plugin na
/// thread da interface, o aviso já estaria lá na primeira.
fn framesWhileBusy(app: *App) bool {
    frames_seen += 1;
    if (frames_until_done == null and toastHas(app, "lento acabou")) frames_until_done = frames_seen;
    return (frames_until_done orelse 0) >= 2;
}

// --- Roteiros -----------------------------------------------------------------------------

/// Entra depois de "Instalar os incluídos" na bateria geral (configurações abertas).
pub const ops = [_]Op{
    s("plugins: a página"),
    expect("os incluídos estão ligados, numa thread própria", threadUp),
    expect("todos os plugins incluídos rodam sem erro", bundledRunning),
    expect("cartão com o cabeçalho, as permissões e o botão do painel", cardsShow),
    expect("plugin antigo aparece como API antiga", cardsShow),
    .{ .shot = "plugins-pagina" },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },

    s("plugins: favoritos"),
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salvar nos favoritos marca a mensagem", bookmarkBadge),
    .{ .shot = "plugin-selo" },
    click("header-plugins"),
    expect("o botão do cabeçalho abre o painel", panelFavoritos),
    expect("a mensagem salva está no painel", itemThere),
    expect("com o painel aberto a caixa de texto cabe ao lado", layoutMoved),
    .{ .shot = "plugin-favoritos" },
    click("pp-input:search"),
    .{ .text = "nada-disso-existe" },
    expect("a busca filtra o painel", itemGone),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("sem busca, a mensagem volta", itemThere),
    run(toMemes),
    expect("muda de canal", onMemes),
    dyn(tItem),
    expect("clicar no favorito volta para a mensagem", jumpedBack),
    dyn(tRemove),
    expect("remover tira do painel", itemGone),
    expect("e da mensagem", noBadge),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salvar de novo", itemThere),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("o mesmo menu tira quem já está salvo", itemGone),

    s("plugins: painel encaixável"),
    run(rememberWidth),
    .{ .drag = .{ .from = .{ .mark = "pp-resize" }, .to = .{ .at = .{ .key = "pp-panel", .fx = 0.5, .fy = 0.5 } } } },
    expect("arrastar a borda muda a largura", widthChanged),
    click("pp-side"),
    expect("encaixar à esquerda leva o layout junto", dockedLeft),
    .{ .shot = "plugin-esquerda" },
    click("pp-side"),
    expect("e voltar à direita", dockedRight),
    click("pp-close"),
    expect("fechar devolve o espaço", panelClosed),
    .{ .resize = .{ 760, 620 } },
    .{ .wait = 150 },
    run(openFavoritos),
    expect("com a janela estreita, o painel abre por cima", panelFavoritos),
    .{ .shot = "plugin-estreito" },
    click("pp-close"),
    expect("e o botão de fechar responde", panelClosed),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 150 },

    s("plugins: lembretes"),
    run(rememberDesktop),
    click("composer"),
    .{ .text = "/remind 1s teste do lembrete" },
    key(c.ImGuiKey_Enter),
    expect("/remind confirma", reminderSet),
    expectLong("na hora, sai a notificação do sistema", reminderFired),
    run(pickOther),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("lembrar de uma mensagem abre o painel com os tempos", panelLembretes),
    .{ .shot = "plugin-lembrete" },
    click("pp-btn:in1h"),
    expect("escolher o tempo cria o lembrete", hasReminder),
    expect("o que já avisou fica na lista", firedOldShown),
    run(restartAll),
    expect("o painel volta sozinho depois de reiniciar", panelLembretesAberto),
    expect("o lembrete sobrevive a reiniciar", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar tira da lista", noReminder),
    run(pickOther),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in10m"),
    expect("10 min cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in3h"),
    expect("3 h cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:in1d"),
    expect("amanhã cria o lembrete", hasReminder),
    dyn(tReminderItem),
    expect("clicar no lembrete vai até a mensagem", reminderJumped),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-input:custom"),
    .{ .text = "banana" },
    key(c.ImGuiKey_Enter),
    expect("um tempo que não existe é recusado", timeRefused),
    .{ .text = "20m" },
    key(c.ImGuiKey_Enter),
    expect("um tempo escrito cria o lembrete", hasReminder),
    dyn(tReminderCancel),
    expect("cancelar", noReminder),
    rmsg,
    click("menu:Lembrar desta mensagem"),
    expect("o painel pergunta o tempo de novo", panelLembretes),
    click("pp-btn:pending-off"),
    expect("deixar para lá não cria nada", pendingGone),

    s("plugins: destaques"),
    ctrl(c.ImGuiKey_K),
    expect("abre a paleta", paletteOpen),
    .{ .text = "Painel: Destaques" },
    .{ .wait = 80 },
    key(c.ImGuiKey_Enter),
    expect("a paleta abre o painel do plugin", panelDestaques),
    click("pp-input:new"),
    .{ .text = "urgente" },
    key(c.ImGuiKey_Enter),
    expect("acrescentar uma palavra", wordThere),
    run(sendUrgent),
    expect("alguém escreve a palavra: aviso", highlightToast),
    expect("entra no histórico", hitInPanel),
    expect("e a mensagem ganha um selo", hitBadge),
    .{ .shot = "plugin-destaques" },
    .{ .wait = 1800 },
    expect("no disco fica a palavra, nunca o texto de quem escreveu", hitDiskClean),
    run(toMemes),
    expect("muda de canal", onMemes),
    dyn(tHit),
    expect("clicar no histórico volta para a mensagem", hitJumped),
    run(deleteHit),
    expect("apagaram a mensagem: sai do histórico", hitGone),
    run(sendUrgent),
    expect("outra mensagem com a palavra", hitInPanel),
    click("pp-btn:clear"),
    expect("limpar o histórico", hitGone),
    click("pp-btn:rmw1"),
    expect("tirar a palavra", noWord),

    s("plugins: filtro local"),
    click("pp-tab:filter.lua"),
    expect("trocar de painel pela etiqueta", panelFiltro),
    click("pp-input:new"),
    .{ .text = "spoiler" },
    key(c.ImGuiKey_Enter),
    .{ .wait = 100 },
    run(sendSpoiler),
    run(stickBottom),
    expect("a mensagem com a palavra fica recolhida, a outra não", collapsed),
    .{ .shot = "plugin-filtro" },
    dyn(tShow),
    expect("mostrar abre só aquela", shown),
    run(pickUserMessage),
    rmsg,
    click("menu:Recolher desta pessoa"),
    expect("recolher pelo menu da mensagem pega todas da pessoa", userCollapsed),
    expect("a pessoa entra na lista", hasUserRow),
    click("pp-btn:pause"),
    expect("pausar devolve as mensagens", userBack),
    click("pp-btn:pause"),
    expect("retomar recolhe de novo", userCollapsed),
    click("pp-btn:rmu1"),
    expect("tirar a pessoa devolve as mensagens", userBack),
    rdyn(tUser),
    click("menu:Recolher mensagens"),
    expect("o menu da pessoa também recolhe", userCollapsed),
    click("pp-btn:rmu1"),
    expect("e tirar devolve", userBack),
    click("pp-btn:rmw1"),
    .{ .wait = 100 },

    s("plugins: trechos"),
    click("pp-tab:snippets.lua"),
    expect("abre o painel de trechos", panelTrechos),
    click("pp-input:name"),
    .{ .text = "ola" },
    .{ .wait = 60 },
    click("pp-input:text"),
    .{ .text = "olá, tudo bem?" },
    .{ .wait = 60 },
    click("pp-btn:add"),
    expect("guardar um trecho", snippetSaved),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("pp-item:ola"),
    expect("clicar põe na caixa, sem enviar", insertedAndNotSent),
    .{ .shot = "plugin-trechos" },
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("caixa vazia", inputEmpty),
    .{ .text = "/snip ola" },
    key(c.ImGuiKey_Enter),
    expect("/snip põe na caixa, sem enviar", insertedAndNotSent),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("pp-btn:rmola"),
    expect("tirar o trecho", snippetGone),
    click("pp-input:name"),
    .{ .text = "enter" },
    .{ .wait = 60 },
    click("pp-input:text"),
    .{ .text = "pelo enter" },
    .{ .wait = 60 },
    key(c.ImGuiKey_Enter),
    expect("Enter no texto também guarda", snippetEnterSaved),
    click("pp-btn:rmenter"),
    .{ .wait = 100 },
    run(pickOther),
    rmsg,
    click("menu:Guardar como trecho"),
    expect("guardar uma mensagem traz o texto para o campo", snippetDraftFromMessage),
    click("pp-input:name"),
    .{ .text = "da-mensagem" },
    .{ .wait = 60 },
    click("pp-btn:add"),
    expect("e dá para guardar com um nome", snippetFromMessageSaved),
    click("pp-btn:rmda-mensagem"),
    .{ .wait = 100 },

    s("plugins: tradução"),
    run(startServer),
    run(rememberCount),
    run(pickOther),
    rmsg,
    click("menu:Traduzir"),
    expect("sem aprovar o host, pede aprovação", asksApproval),
    expect("e nada sai para a rede", nothingSent),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão mostra o host a aprovar", hostCardShows),
    .{ .shot = "plugin-aprovar" },
    click(translate_host),
    expect("aprovar o host", approved),
    key(c.ImGuiKey_Escape),
    rmsg,
    click("menu:Traduzir"),
    expectLong("a tradução aparece embaixo da mensagem", noteShows),
    .{ .shot = "plugin-traducao" },
    expect("o pedido não leva nada da conta", requestOk),
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click(translate_host),
    expect("tirar a aprovação", notApproved),
    key(c.ImGuiKey_Escape),

    s("plugins: estatísticas"),
    click("composer"),
    .{ .text = "/stats" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("/stats abre o painel com quem mais fala", panelStats),
    .{ .shot = "plugin-estatisticas" },
    .{ .wait = 600 },
    click("pp-btn:refresh"),
    .{ .wait = 150 },
    expect("atualizar mantém os números", panelStats),
    click("pp-close"),
    expect("fecha o painel", panelClosed),

    s("plugins: parado não custa nada"),
    .{ .wait = 2000 },
    run(rememberLoops),
    .{ .wait = 1200 },
    expect("sem nada acontecendo, a thread dos plugins dorme", loopsSame),

    s("plugins: limites do HTTP"),
    run(writeExtra),
    run(reloadNow),
    expectLong("carrega os plugins de teste", extraLoaded),
    run(approveQa),
    .{ .wait = 80 },
    run(clearToast),
    click("composer"),
    .{ .text = "/qa-big" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("resposta maior que o limite é recusada", bigRefused),
    click("composer"),
    .{ .text = "/qa-redir" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("redirecionamento não é seguido", redirectNotFollowed),
    click("composer"),
    .{ .text = "/qa-post" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("POST funciona, sem os cabeçalhos proibidos", postEchoed),
    click("composer"),
    .{ .text = "/qa-plain" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expect("http:// sem TLS é recusado", plainRefused),

    s("plugins: o Lua não segura a interface"),
    run(clearFrames),
    click("composer"),
    .{ .text = "/qa-lento" },
    key(c.ImGuiKey_Enter),
    key(c.ImGuiKey_Enter),
    expectLong("a interface segue desenhando enquanto um plugin trabalha", framesWhileBusy),
    run(removeExtra),
    run(reloadNow),
    .{ .wait = 200 },

    s("plugins: o cartão abre o painel"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("plugin-open:bookmarks.lua"),
    expect("Abrir painel fecha as configurações e mostra o painel", panelFavoritosSemConfig),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("plugin-open:bookmarks.lua"),
    expect("com ele aberto, o mesmo botão fecha", panelClosed),

    s("plugins: varredura da página"),
};

fn reloadNow(app: *App) void {
    app.plugins.reload();
}

fn approveQa(app: *App) void {
    const p = plugin(app, "qahttp.lua") orelse return;
    app.plugins.setApproved(p, "qa.exemplo.com", true);
}

fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}

// --- TLS de verdade (tools/qa_http_tls.sh) -------------------------------------------

fn useTlsServer(app: *App) void {
    if (!http_curl.qa_builds) return;
    const base = std.mem.span(c.SDL_getenv("QA_HTTP_BASE") orelse return);
    @memcpy(http_curl.qa_base[0..base.len], base);
    http_curl.qa_base_len = base.len;
    if (c.SDL_getenv("QA_HTTP_CAINFO")) |ca| {
        const path = std.mem.span(ca);
        @memcpy(http_curl.qa_cainfo[0..path.len], path);
        http_curl.qa_cainfo[path.len] = 0;
        http_curl.qa_cainfo_len = path.len;
    }
    if (plugin(app, "translate.lua")) |p| app.plugins.setApproved(p, "api.mymemory.translated.net", true);
}

fn tlsResult(app: *App) bool {
    const v = viewOf(app) orelse return false;
    const want: []const u8 = if (c.SDL_getenv("QA_HTTP_BAD_CA") != null) "Não consegui traduzir (network)" else "traduzido por HTTPS";
    for (v.slice()) |*part| if (std.mem.indexOf(u8, part.note, want) != null) return true;
    return false;
}

fn tlsLoaded(app: *App) bool {
    const p = plugin(app, "translate.lua") orelse return false;
    return p.isRunning() and p.menus.items.len > 0;
}

pub const ops_tls = [_]Op{
    s("plugins: HTTPS de verdade"),
    run(wipeAll),
    expectLong("os plugins incluídos ligam", tlsLoaded),
    run(useTlsServer),
    .{ .wait = 100 },
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Traduzir"),
    expectLong("o pedido passa pelo TLS e a resposta aparece (ou é recusado sem o certificado)", tlsResult),
};

pub fn endSection(app: *App) void {
    removeAllPlugins(app);
    app.plugins.reload();
    app.plugins.panel_left = false;
    app.plugins.panel_w = 340;
}

pub fn threadGone(app: *App) bool {
    return app.plugins.panel_open == null and !app.plugins.threadRunning();
}

// --- Por tema ---------------------------------------------------------------------------

fn themeCards(_: *App) bool {
    return qa.find("plugin-card:bookmarks.lua") != null and qa.find("plugin-chip:bookmarks.lua:panel") != null and qa.find("toggle:bookmarks.lua") != null;
}

fn themeMenu(_: *App) bool {
    return qa.find("menu:Salvar nos favoritos") != null;
}

fn themeLoaded(app: *App) bool {
    return bundledRunning(app) and app.plugins.panelCount() >= 6;
}

const qa_deco_plugin =
    \\-- @name QA nota
    \\-- @capabilities menu, decorate
    \\larper.menu("message", "QA nota", function(m)
    \\  larper.decorate(m, { badge = "selo", note = "uma nota de plugin comprida o bastante para quebrar a linha e mostrar como ela fica embaixo da mensagem em qualquer tema" })
    \\end)
    \\larper.menu("message", "QA recolhe", function(m)
    \\  larper.decorate(m, { collapse = true, label = "Recolhida pelo plugin de teste" })
    \\end)
;

fn writeDeco(_: *App) void {
    _ = c.SDL_SaveFile("qa-out/plugins/qadeco.lua", qa_deco_plugin.ptr, qa_deco_plugin.len);
}
fn decoNote(_: *App) bool {
    return qa.find(mark(&mbuf, "deco-note:{d}", msg_id)) != null;
}
fn hiddenNow(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", msg_id)) != null;
}
fn tHiddenShow(_: *App, buf: []u8) []const u8 {
    return mark(buf, "hidden-show:{d}", msg_id);
}
fn revealedNow(_: *App) bool {
    return qa.find(mark(&mbuf, "hidden:{d}", msg_id)) == null;
}
fn decoLoaded(app: *App) bool {
    const p = plugin(app, "qadeco.lua") orelse return false;
    return p.isRunning() and p.menus.items.len == 2;
}

fn themeOff(app: *App) bool {
    return app.plugins.list.items.len == 0 and !app.plugins.threadRunning();
}

/// Na bateria de cada tema: os cartões, o painel, o selo e a nota têm que caber e
/// funcionar com qualquer layout.
pub const ops_theme = [_]Op{
    s("plugins neste tema"),
    run(wipeData),
    run(removeAllPlugins),
    run(writeBundled),
    run(reloadNow),
    expectLong("os plugins incluídos ligam", themeLoaded),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("os cartões aparecem", themeCards),
    .{ .shot = "tema-plugins" },
    key(c.ImGuiKey_Escape),
    click("header-plugins"),
    expect("o botão do cabeçalho abre o painel", panelFavoritos),
    expect("o layout do tema dá lugar ao painel", layoutMoved),
    // A conversa ficou mais estreita: espera a rolagem assentar antes de escolher a mensagem.
    .{ .wait = 400 },
    run(pickOther),
    rmsg,
    expect("as entradas dos plugins aparecem no menu", themeMenu),
    click("menu:Salvar nos favoritos"),
    expect("o favorito aparece no painel", itemThere),
    expect("a mensagem ganha o selo", bookmarkBadge),
    .{ .shot = "tema-plugin-painel" },
    click("pp-side"),
    expect("encaixado à esquerda", dockedLeft),
    .{ .shot = "tema-plugin-esquerda" },
    click("pp-side"),
    click("pp-close"),
    expect("fechar devolve o espaço", panelClosed),
    run(writeDeco),
    run(reloadNow),
    expectLong("o plugin de teste liga", decoLoaded),
    run(pickOther),
    rmsg,
    click("menu:QA nota"),
    expect("a nota aparece embaixo da mensagem", decoNote),
    .{ .shot = "tema-plugin-nota" },
    dyn(tClose),
    expect("o × dispensa a nota", noteGone),
    run(pickOther),
    rmsg,
    click("menu:QA recolhe"),
    expect("recolher vira uma linha", hiddenNow),
    .{ .shot = "tema-plugin-recolhida" },
    dyn(tHiddenShow),
    expect("mostrar abre de novo", revealedNow),
    run(removeAllPlugins),
    run(reloadNow),
    expect("sem plugins, a thread sai", themeOff),
};

// --- Reabrir o app ------------------------------------------------------------------------

fn wipeAll(app: *App) void {
    wipeData(app);
    removeAllPlugins(app);
    writeBundled(app);
    app.plugins.reload();
}

fn persistSaved(_: *App) bool {
    return anyMark("pp-item:r");
}

/// Primeira metade: deixa dados e sai (o app grava ao fechar).
pub const ops_persist_a = [_]Op{
    s("plugins: antes de fechar"),
    run(wipeAll),
    expectLong("os plugins incluídos ligam", themeLoaded),
    run(toGeral),
    .{ .wait = 200 },
    run(pickOther),
    rmsg,
    click("menu:Salvar nos favoritos"),
    expect("salva um favorito", bookmarkBadge),
    click("composer"),
    .{ .text = "/remind 3h fica para depois" },
    key(c.ImGuiKey_Enter),
    expect("cria um lembrete longe", reminderSet),
    click("composer"),
    .{ .text = "/remind 2s vence com o app fechado" },
    key(c.ImGuiKey_Enter),
    // O tempo de o comando chegar à thread dos plugins, antes de fechar.
    .{ .wait = 300 },
};

fn reloadSecond(app: *App) void {
    app.plugins.reload();
}

fn bookmarkBack(app: *App) bool {
    const p = plugin(app, "bookmarks.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item) return true;
    return false;
}

fn lateFired(_: *App) bool {
    return std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "vence com o app fechado") != null and
        std.mem.indexOf(u8, host.qa_desktop_text[0..host.qa_desktop_len], "atrasado") != null;
}

fn reminderBack(app: *App) bool {
    const p = plugin(app, "reminders.lua") orelse return false;
    const t = p.tree orelse return false;
    for (t.nodes.items) |*n| if (n.kind == .item and std.mem.indexOf(u8, n.text, "fica para depois") != null) return true;
    return false;
}

/// Segunda metade, noutro processo: o que ficou continua lá.
pub const ops_persist_b = [_]Op{
    s("plugins: depois de reabrir"),
    run(reloadSecond),
    expectLong("os plugins incluídos ligam", themeLoaded),
    expectLong("o favorito continua lá", bookmarkBack),
    expectLong("o lembrete continua lá", reminderBack),
    expectLong("o que venceu com o app fechado avisa ao abrir", lateFired),
};
