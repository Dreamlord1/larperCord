//! Robô de QA (`larpercord --qa`): roda fora da tela, com os dados de
//! demonstração, e usa o app como uma pessoa usaria, com eventos reais de
//! mouse e teclado no ImGui, clicando nos elementos marcados pelos
//! componentes (ui/qa.zig). Depois de cada ação confere o estado, salva
//! prints em qa-out/ e no fim imprime o relatório.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const Id = types.Id;

const Key = []const u8;

/// Onde agir: uma marcação (com deslocamento opcional) ou uma marcação
/// calculada na hora (depende de IDs que só existem durante o teste).
pub const Target = union(enum) {
    mark: Key,
    dyn: *const fn (app: *App, buf: []u8) []const u8,
    /// Ponto dentro da marcação: frações da largura/altura.
    at: struct { key: Key, fx: f32, fy: f32 },
    dyn_at: struct { f: *const fn (app: *App, buf: []u8) []const u8, fx: f32, fy: f32 },
};

pub const Op = union(enum) {
    section: []const u8,
    click: Target,
    rclick: Target,
    mclick: Target,
    ctrl_click: Target,
    dclick: Target,
    hover: Target,
    drag: struct { from: Target, to: Target },
    key: struct { key: c_int, ctrl: bool = false, shift: bool = false, alt: bool = false },
    text: []const u8,
    wait: u32,
    expect: struct { name: []const u8, check: *const fn (app: *App) bool, timeout_ms: u32 = 2500 },
    shot: []const u8,
    resize: [2]c_int,
    run: *const fn (app: *App) void,
    /// Clica em todo elemento da tela cujo nome começa com um dos prefixos
    /// e confere que cada clique muda alguma coisa (botão morto = falha).
    sweep: []const []const u8,
};

// --- Ajudantes para os cenários ---------------------------------------------

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: Key) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}

fn active(app: *App) ?*@import("core/store.zig").ChannelState {
    const id = app.st.activeChannel() orelse return null;
    return app.store.channel(id);
}

fn lastMsg(app: *App, back: usize) ?*@import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    const n = cs.messages.items.len;
    if (back >= n) return null;
    return &cs.messages.items[n - 1 - back];
}

/// Mensagem mais recente de outra pessoa (para responder, perfil…).
fn lastOther(app: *App) ?*@import("core/store.zig").StoredMessage {
    const cs = active(app) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author != app.store.me and m.msg.reply_to == 0) return m;
    }
    return null;
}

var saved_id: Id = 0;
var saved_count: usize = 0;
var saved_theme: usize = 0;
var saved_tab: usize = 0;

fn ch(i: usize) Id {
    return gw.channelId(0, i);
}

fn markFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

// Alvos dinâmicos.
fn tReplyLast(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    saved_id = m.msg.id;
    return markFmt(b, "tb:{d}:3", .{m.msg.id});
}
fn tHoverOther(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
}
fn tHoverMine(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 0) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
}
fn tThumbMine(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 0) orelse return "";
    saved_id = m.msg.id;
    return markFmt(b, "tb:{d}:0", .{m.msg.id});
}
fn tChipMine(_: *App, b: []u8) []const u8 {
    return markFmt(b, "chip:{d}:0", .{saved_id});
}
fn tUserOther(app: *App, b: []u8) []const u8 {
    const m = lastOther(app) orelse return "";
    saved_id = m.msg.author;
    return markFmt(b, "user:{d}", .{m.msg.author});
}
/// As duas últimas mensagens com texto (sem anexo/embed), contando do fim:
/// (mais antiga, mais nova). O arraste vai em cima do texto desenhado
/// (marcação msgtext:), então serve para qualquer tema.
fn plainPair(app: *App) ?[2]usize {
    var found: [2]usize = undefined;
    var n: usize = 0;
    var back: usize = 0;
    while (back < 8 and n < 2) : (back += 1) {
        const m = lastMsg(app, back) orelse return null;
        if (m.msg.attachments.len > 0 or m.msg.embeds.len > 0 or m.msg.system != .none or m.msg.content.len < 6) continue;
        if (qa.find(std.fmt.bufPrint(&pair_buf, "msgtext:{d}", .{m.msg.id}) catch continue) == null) continue;
        found[n] = back;
        n += 1;
    }
    return if (n == 2) .{ found[1], found[0] } else null;
}
var pair_buf: [64]u8 = undefined;
fn tSelFrom(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, (plainPair(app) orelse return "")[0]) orelse return "";
    return markFmt(b, "msgtext:{d}", .{m.msg.id});
}
fn tSelTo(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, (plainPair(app) orelse return "")[1]) orelse return "";
    return markFmt(b, "msgtext:{d}", .{m.msg.id});
}

// Verificações.
fn ready(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.store.ready and cs.history == .loaded;
}
fn threeTabs(app: *App) bool {
    return app.st.tabs.items.len == 3 and app.st.activeChannel() == ch(4);
}
fn onMemes(app: *App) bool {
    return app.st.activeChannel() == ch(5);
}
fn newTab(app: *App) bool {
    return app.st.tabs.items.len == 4 and app.st.activeChannel() == ch(6);
}
fn tabClosed(app: *App) bool {
    return app.st.tabs.items.len == 3;
}
fn catCollapsed(app: *App) bool {
    return app.st.collapsed.contains(ch(3));
}
fn catOpen(app: *App) bool {
    return !app.st.collapsed.contains(ch(3));
}
fn onGuild1(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.st.guild == gw.guildId(1) and cs.info.guild == gw.guildId(1);
}
fn friendsOpen(app: *App) bool {
    return app.st.guild == 0 and app.st.friends and qa.find("friend:1001") != null;
}
fn pendingTab(app: *App) bool {
    return app.st.friends_tab == 2 and qa.find("friend-accept:1009") != null;
}
fn accepted(app: *App) bool {
    return app.store.relationship(1009) == .friend;
}
fn cancelled(app: *App) bool {
    return app.store.relationship(1006) == .none;
}
fn dmWithAna(app: *App) bool {
    const cs = active(app) orelse return false;
    return !app.st.friends and cs.info.guild == 0 and !cs.info.group and cs.info.recipient == 1001;
}
fn newDm(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.guild == 0 and cs.info.recipient == 1008 and qa.find("dm-profile") != null;
}
fn groupOpen(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.group and qa.find("member:1003") != null and qa.find("member:1005") != null and qa.find("member:1002") == null;
}
/// Lista do servidor 0: Fundação com ana.exe, e quem não está no servidor fica de fora.
fn guildMembers(app: *App) bool {
    const ml = app.store.memberList(gw.guildId(0)) orelse return false;
    if (!ml.synced) return false;
    var role_group = false;
    for (ml.items.items) |it| if (it == .group and it.group.id == gw.guildId(0) + 901) {
        role_group = true;
    };
    return role_group and qa.find("member:1001") != null;
}
/// Servidores diferentes, listas diferentes.
fn otherGuildMembers(app: *App) bool {
    const a = app.store.memberList(gw.guildId(0)) orelse return false;
    const b = app.store.memberList(gw.guildId(1)) orelse return false;
    if (!b.synced) return false;
    // Alguém está numa lista e não na outra.
    for (a.items.items) |x| if (x == .member) {
        const found = for (b.items.items) |y| {
            if (y == .member and y.member.user == x.member.user) break true;
        } else false;
        if (!found) return true;
    };
    return false;
}
fn avatarsLoaded(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, " demo:av:") != null and e.value_ptr.state == .ready) return true;
    return false;
}
fn iconsLoaded(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, " demo:icon:") != null and e.value_ptr.state == .ready) return true;
    return false;
}
fn gifAnimated(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, " demo:gif") and e.value_ptr.state == .ready and e.value_ptr.frames.len > 1) return true;
    return false;
}
fn openFirstDm(app: *App) void {
    app.actions.append(app.gpa, .{ .select_channel = gw.dmId(0) }) catch {};
}
fn statusMenu(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .status;
}
fn meDnd(app: *App) bool {
    return app.store.user(app.store.me).?.status == .dnd and app.st.settings.my_status == 2;
}
fn meOnline(app: *App) bool {
    return app.store.user(app.store.me).?.status == .online and app.st.settings.my_status == 0;
}
fn panelOnScreen(app: *App) bool {
    const r = qa.find("me") orelse return false;
    return r.bottom() <= app.io.*.DisplaySize.y and qa.find("hangup") != null;
}
fn jumpToZigLink(app: *App) void {
    const cs = active(app) orelse return;
    for (cs.messages.items) |m| if (std.mem.eql(u8, m.msg.content, "https://ziglang.org")) {
        app.st.jump = m.msg.id;
    };
}
fn linkOpened(_: *App) bool {
    const att = @import("ui/attachments.zig");
    return std.mem.eql(u8, att.last_opened[0..att.last_opened_len], "https://ziglang.org");
}
fn jumpBottomShown(_: *App) bool {
    return qa.find("jump-bottom") != null;
}
fn atBottom(app: *App) bool {
    const cs = active(app) orelse return false;
    _ = cs;
    return app.st.scrollOf(app.st.activeChannel().?).stick_bottom and qa.find("jump-bottom") == null;
}
fn skipExtraThemes(app: *App) void {
    const n = app.themes.entries.items.len;
    if (n > 7) for (0..n - 7) |_| app.actions.append(app.gpa, .{ .next_theme = 1 }) catch {};
}
fn toClassico(app: *App) void {
    for (app.themes.names.items, 0..) |nm, i| if (std.mem.eql(u8, nm, "classico")) {
        app.actions.append(app.gpa, .{ .set_theme = i }) catch {};
    };
}
fn scrollBottom(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
fn jumpToGif(app: *App) void {
    const f = findAttachment(app, "demo:gif") orelse return;
    app.st.jump = f.id;
}
fn onDms(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.st.guild == 0 and cs.info.guild == 0;
}
fn onGuild0(app: *App) bool {
    return app.st.guild == gw.guildId(0);
}
fn sentConfirmed(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, "teste do QA 🎉 **negrito**");
}
fn replyArmed(app: *App) bool {
    return app.st.reply_to != 0 and app.st.reply_to == saved_id;
}
fn replySent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.reply_to == saved_id and !m.pending and app.st.reply_to == 0;
}
fn editing(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return app.st.editing == m.msg.id and std.mem.startsWith(u8, std.mem.sliceTo(&app.st.input, 0), "respondendo");
}
fn edited(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.edited and std.mem.eql(u8, m.msg.content, "editado pelo QA") and app.st.editing == 0;
}
fn reacted(app: *App) bool {
    const found = app.store.findAny(saved_id) orelse return false;
    for (found.m.reactionSlice()) |r| if (std.mem.eql(u8, r.text(), "👍") and r.me) return true;
    return false;
}
fn unreacted(app: *App) bool {
    const found = app.store.findAny(saved_id) orelse return false;
    for (found.m.reactionSlice()) |r| if (std.mem.eql(u8, r.text(), "👍") and r.me) return false;
    return true;
}
fn menuOpen(app: *App) bool {
    return app.st.popup == .menu;
}
fn rememberCount(app: *App) void {
    const cs = active(app) orelse return;
    saved_count = cs.messages.items.len;
    if (lastMsg(app, 0)) |m| saved_id = m.msg.id;
}
fn deleted(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.messages.items.len == saved_count - 1 and app.store.findAny(saved_id) == null;
}
// Imagens.
fn findAttachment(app: *App, url: []const u8) ?struct { id: Id, i: usize } {
    const cs = active(app) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (std.mem.eql(u8, a.url, url)) return .{ .id = m.msg.id, .i = i };
    }
    return null;
}
fn tDemoImage(app: *App, b: []u8) []const u8 {
    const f = findAttachment(app, "demo:1") orelse return "";
    return markFmt(b, "att:{d}:{d}", .{ f.id, f.i });
}
fn tDemoFile(app: *App, b: []u8) []const u8 {
    const f = findAttachment(app, "demo:file") orelse return "";
    return markFmt(b, "att:{d}:{d}", .{ f.id, f.i });
}
fn jumpToFile(app: *App) void {
    const f = findAttachment(app, "demo:file") orelse return;
    app.st.jump = f.id;
}
fn demoImageReady(app: *App) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, " demo:1") and e.value_ptr.state == .ready) return true;
    return false;
}
fn noImageLoading(app: *App) bool {
    return !app.images.busy();
}
fn viewerOpen(app: *App) bool {
    return app.st.viewer != null and qa.find("viewer") != null;
}
fn viewerClosed(app: *App) bool {
    return app.st.viewer == null;
}
fn toastDemoFile(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "arquivo") != null;
}
/// Gera um PNG de teste (um degradê) e põe na bandeja, como um arrastar e soltar.
fn attachQaImage(app: *App) void {
    const surf = c.SDL_CreateSurface(160, 100, c.SDL_PIXELFORMAT_RGBA32) orelse return;
    defer c.SDL_DestroySurface(surf);
    const px: [*]u8 = @ptrCast(surf.*.pixels.?);
    const pitch: usize = @intCast(surf.*.pitch);
    for (0..100) |y| for (0..160) |x| {
        const o = px[y * pitch + x * 4 ..][0..4];
        o.* = .{ @intCast(x * 255 / 160), @intCast(y * 255 / 100), 200, 255 };
    };
    _ = c.SDL_SavePNG(surf, "qa-out/anexo-qa.png");
    var buf: [1024]u8 = undefined;
    const cwd = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(cwd);
    const path = std.fmt.bufPrint(&buf, "{s}qa-out/anexo-qa.png", .{std.mem.span(cwd)}) catch return;
    app.attachFile(path);
}
fn oneUpload(app: *App) bool {
    return app.st.uploads.items.len == 1 and app.st.uploads.items[0].width == 160 and qa.find("upload:0") != null;
}
fn noUploads(app: *App) bool {
    return app.st.uploads.items.len == 0;
}
fn sentWithImage(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return !m.pending and std.mem.eql(u8, m.msg.content, "olha essa imagem") and m.msg.attachments.len == 1 and
        m.msg.attachments[0].width == 160 and std.mem.startsWith(u8, m.msg.attachments[0].url, "file://");
}
fn sentImageOnly(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return !m.pending and m.msg.content.len == 0 and m.msg.attachments.len == 1;
}

fn toastCopied(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "copiado") != null;
}
fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}
fn hasSelection(app: *App) bool {
    return !app.st.selection.empty();
}
fn profileOpen(app: *App) bool {
    return app.st.popup == .profile;
}
fn dmSent(app: *App) bool {
    const cs = active(app) orelse return false;
    if (cs.info.recipient != saved_id) return false;
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.eql(u8, m.msg.content, "oi do perfil");
}
fn emojiOpen(app: *App) bool {
    return app.st.popup == .emoji;
}
fn emojiInserted(app: *App) bool {
    return std.mem.indexOf(u8, std.mem.sliceTo(&app.st.input, 0), "😂") != null and app.st.popup == .none;
}
fn inputEmpty(app: *App) bool {
    return std.mem.sliceTo(&app.st.input, 0).len == 0;
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
fn onZig(app: *App) bool {
    const cs = active(app) orelse return false;
    return std.mem.eql(u8, cs.info.name, "zig") and !app.st.palette.open;
}
fn fullProfile(app: *App) bool {
    return app.st.popup == .profile_full;
}
fn anyMark(prefix: []const u8) bool {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    return qa.keysWith(&.{prefix}, &keys, &lens) > 0;
}
fn fullFriendsTab(app: *App) bool {
    return fullProfile(app) and app.st.profile_tab == 1 and anyMark("profile-friend:");
}
fn fullGuildsTab(app: *App) bool {
    return fullProfile(app) and app.st.profile_tab == 2 and anyMark("profile-guild:");
}
fn hasActivity(app: *App) bool {
    _ = app;
    return qa.find("profile-activity") != null;
}
fn cardDetails(app: *App) bool {
    _ = app;
    return qa.find("profile-activity") != null and qa.find("profile-joined") != null and qa.find("profile-mutual:1") != null;
}
fn openedGithub(app: *App) bool {
    _ = app;
    const a = @import("ui/attachments.zig");
    return std.mem.startsWith(u8, a.last_opened[0..a.last_opened_len], "https://github.com/");
}
fn profileNoteSaved(app: *App) bool {
    const n = app.store.notes.get(1002) orelse return false;
    return std.mem.eql(u8, n, "jogador de hollow knight") and !app.st.note_editing;
}
fn movedToGaming(app: *App) bool {
    return app.store.voiceChannelOf(1001, app.st.guild) == ch(14);
}
fn disconnected1001(app: *App) bool {
    const cur = app.store.voiceChannelOf(1001, app.st.guild);
    return cur == 0 or app.store.channel(cur).?.info.guild != app.st.guild;
}

fn inVoice(app: *App) bool {
    return app.st.voice == ch(13);
}
fn notInVoice(app: *App) bool {
    return app.st.voice == null;
}
fn muted(app: *App) bool {
    return app.st.muted;
}
fn unmuted(app: *App) bool {
    return !app.st.muted;
}
fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}
fn settingsClosed(app: *App) bool {
    return !app.st.settings.open;
}
fn compactOn(app: *App) bool {
    return app.st.settings.compact;
}
fn compactOff(app: *App) bool {
    return !app.st.settings.compact;
}
fn lightMode(app: *App) bool {
    return app.themes.mode == .light;
}
fn darkMode(app: *App) bool {
    return app.themes.mode == .dark;
}
fn onTerminal(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "terminal");
}
fn crtOff(app: *App) bool {
    return app.themes.theme_().option("crt") == false;
}
fn crtOn(app: *App) bool {
    return app.themes.theme_().option("crt") == true;
}
fn onClassico(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "classico");
}
fn rememberTheme(app: *App) void {
    saved_theme = app.themes.current;
}
fn themeChanged(app: *App) bool {
    return app.themes.current != saved_theme;
}
fn composerVisible(_: *App) bool {
    return qa.find("composer") != null and qa.find("msg-index:0") != null;
}
fn rememberTab(app: *App) void {
    saved_tab = app.st.tab;
}
fn tabMoved(app: *App) bool {
    return app.st.tab != saved_tab;
}
fn tab1(app: *App) bool {
    return app.st.tab == 1;
}
fn noMembers(_: *App) bool {
    return qa.find("member:1001") == null;
}
fn dmProfileShown(_: *App) bool {
    return qa.find("dm-profile") != null;
}
fn hasMembers(_: *App) bool {
    return qa.find("member:1001") != null;
}
fn membersHidden(app: *App) bool {
    return !app.st.settings.show_member_list;
}
fn membersShown(app: *App) bool {
    return app.st.settings.show_member_list;
}
fn longSent(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.content.len > 300 and !m.pending;
}
fn mentionResolved(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return std.mem.indexOf(u8, m.msg.content, "<@1001>") != null;
}
fn popupClosed(app: *App) bool {
    return app.st.popup == .none;
}
// Plugins: os dois exemplos de docs/plugins e três de teste.
const qa_plugins = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "qa.lua", .src =
    \\larper.on("message", function(msg)
    \\  if msg.content == "ping-plugin" then larper.notify("pong-plugin de " .. msg.author.name) end
    \\  if msg.content == "spam-plugin" then larper.send(msg.channel, "spam!") end
    \\end)
    \\larper.keybind("ctrl+shift+y", function() larper.send(nil, "atalho do plugin") end)
    },
    .{ .name = "trava.lua", .src = "larper.command('/trava', function() while true do end end)" },
    .{ .name = "quebrado.lua", .src = "larper.on('message', function( end" },
};

fn writePlugins(_: *App) void {
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    for ([_][]const u8{ "shrug.lua", "alerta.lua" }) |n| {
        var a: [96]u8 = undefined;
        var b: [96]u8 = undefined;
        const from = std.fmt.bufPrintSentinel(&a, "docs/plugins/{s}", .{n}, 0) catch continue;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{n}, 0) catch continue;
        var size: usize = 0;
        const data = c.SDL_LoadFile(from.ptr, &size) orelse continue;
        defer c.SDL_free(data);
        _ = c.SDL_SaveFile(to.ptr, data, size);
    }
    for (qa_plugins) |p| {
        var b: [96]u8 = undefined;
        const to = std.fmt.bufPrintSentinel(&b, "qa-out/plugins/{s}", .{p.name}, 0) catch continue;
        _ = c.SDL_SaveFile(to.ptr, p.src.ptr, p.src.len);
    }
}
fn plugin(app: *App, name: []const u8) ?*@import("plugins/engine.zig").Plugin {
    for (app.plugins.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}
fn pluginErr(app: *App, name: []const u8, needle: []const u8) bool {
    const p = plugin(app, name) orelse return false;
    return std.mem.indexOf(u8, p.err() orelse return false, needle) != null;
}
fn lastIs(app: *App, text: []const u8) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and std.mem.eql(u8, m.msg.content, text);
}
fn noPlugins(app: *App) bool {
    return app.plugins.list.items.len == 0 and qa.find("button:Recarregar") != null;
}
fn pluginsLoaded(app: *App) bool {
    return app.plugins.list.items.len == 5 and qa.find("toggle:shrug.lua") != null;
}
fn syntaxShown(app: *App) bool {
    const p = plugin(app, "quebrado.lua") orelse return false;
    return p.status() == .failed and qa.find("plugin-error:quebrado.lua") != null;
}
fn shrugSent(app: *App) bool {
    return lastIs(app, "sei lá ¯\\_(ツ)_/¯");
}
fn travaStopped(app: *App) bool {
    const p = plugin(app, "trava.lua") orelse return false;
    return p.status() == .failed and pluginErr(app, "trava.lua", "limite") and !lastIs(app, "/trava");
}
fn keySent(app: *App) bool {
    return lastIs(app, "atalho do plugin");
}
fn pongToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "pong-plugin") != null;
}
fn fakeUrgent(app: *App) void {
    const id = app.st.activeChannel() orelse return;
    @import("plugins/host.zig").onMessage(app, .{ .id = 1, .channel = id, .author = 1001, .timestamp = 0, .content = "isso é URGENTE, gente" });
}
fn alertToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "falou \"urgente\"") != null;
}
fn spamBlocked(app: *App) bool {
    const p = plugin(app, "qa.lua") orelse return false;
    return p.status() == .running and pluginErr(app, "qa.lua", "larper.send") and !lastIs(app, "spam!");
}
fn shrugOff(app: *App) bool {
    const p = plugin(app, "shrug.lua") orelse return false;
    return p.status() == .off;
}
fn shrugOn(app: *App) bool {
    const p = plugin(app, "shrug.lua") orelse return false;
    return p.status() == .running;
}
fn shrugLiteral(app: *App) bool {
    return lastIs(app, "/shrug sei lá");
}

fn toDemoStart(app: *App) void {
    app.st.reply_to = 0;
    app.st.editing = 0;
}

const long_text = "Mensagem longa do QA pra testar a quebra de linha: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. 😂🔥🎉 `código inline` **negrito** *itálico* ~~riscado~~ ||spoiler|| https://ziglang.org fim.";

// --- Caixa de entrada e mensagens salvas ---------------------------------------

const saved_core = @import("core/saved.zig");
const saved_ui = @import("ui/saved.zig");

fn inboxOpen(app: *App) bool {
    return app.st.popup == .inbox and qa.find("inbox-tab:unread") != null;
}
fn firstMark(prefix: []const u8, b: []u8) []const u8 {
    var keys: [1][56]u8 = undefined;
    var lens: [1]u8 = undefined;
    if (qa.keysWith(&.{prefix}, &keys, &lens) == 0) return "";
    const k = keys[0][0..lens[0]];
    @memcpy(b[0..k.len], k);
    return b[0..k.len];
}
fn idOf(name: []const u8) Id {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return 0;
    return std.fmt.parseInt(Id, name[colon + 1 ..], 10) catch 0;
}
fn inboxHasPreview(_: *App) bool {
    var b: [64]u8 = undefined;
    return firstMark("inbox-msg:", &b).len > 0;
}
/// A menção no fim do #anúncios do primeiro servidor (demonstração).
fn announcement(app: *App) ?Id {
    const cs = app.store.channel(ch(2)) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author == 1001 and std.mem.indexOf(u8, m.msg.content, "<@1000>") != null) return m.msg.id;
    }
    return null;
}
fn inboxHasAnnouncement(app: *App) bool {
    const id = announcement(app) orelse return false;
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, "inbox-msg:{d}", .{id})) != null and qa.find(markFmt(&b, "inbox-open:{d}", .{ch(2)})) != null;
}
fn tInboxAnnouncement(app: *App, b: []u8) []const u8 {
    const id = announcement(app) orelse return "";
    return markFmt(b, "inbox-msg:{d}", .{id});
}
fn noOldToast(app: *App) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), "carregada") == null;
}
fn jumpedToMention(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.id == ch(2) and cs.history == .loaded and app.st.popup == .none and app.st.jump == 0 and !cs.info.unread and noOldToast(app);
}
fn announcementGone(_: *App) bool {
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, "inbox-open:{d}", .{ch(2)})) == null and qa.find("inbox-tab:unread") != null;
}
fn tInboxReadFirst(_: *App, b: []u8) []const u8 {
    const k = firstMark("inbox-read:", b);
    saved_id = idOf(k);
    return k;
}
fn firstGroupRead(app: *App) bool {
    if (app.store.channel(saved_id)) |cs| return !cs.info.unread;
    if (app.store.guild(saved_id)) |g| return g.mentions == 0;
    return false;
}
fn inboxEmpty(app: *App) bool {
    if (qa.find("inbox-empty") == null or app.st.popup != .inbox) return false;
    var it = app.store.channels.valueIterator();
    while (it.next()) |cs| if (cs.*.info.guild == 0 and cs.*.info.unread) return false;
    for (app.store.guilds.items) |g| if (g.mentions > 0) return false;
    return true;
}
fn mentionsShown(app: *App) bool {
    var b: [64]u8 = undefined;
    return app.store.mentions_state == .loaded and app.store.recent_mentions.items.len > 0 and firstMark("inbox-mention:", &b).len > 0;
}
fn tFirstMention(_: *App, b: []u8) []const u8 {
    const k = firstMark("inbox-mention:", b);
    saved_id = idOf(k);
    return k;
}
fn oldMentionOpened(app: *App) bool {
    const cs = active(app) orelse return false;
    const want = for (app.store.recent_mentions.items) |m| {
        if (m.msg.id == saved_id) break m.msg.channel;
    } else return false;
    return cs.info.id == want and cs.history == .loaded and app.st.popup == .none and app.st.jump == 0 and !noOldToast(app);
}
fn rememberOther(app: *App) void {
    if (lastOther(app)) |m| saved_id = m.msg.id;
}
fn tHoverSaved(_: *App, b: []u8) []const u8 {
    return markFmt(b, "msg:{d}", .{saved_id});
}
fn oneSaved(app: *App) bool {
    return app.st.saved.items.items.len == 1 and app.st.saved.find(saved_id) != null;
}
fn noneSaved(app: *App) bool {
    return app.st.saved.items.items.len == 0;
}
fn savedOpen(app: *App) bool {
    var b: [64]u8 = undefined;
    return app.st.popup == .saved and qa.find(markFmt(&b, "saved-open:{d}", .{saved_id})) != null;
}
fn tSavedNote(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-note:{d}", .{saved_id});
}
fn tSavedOpen(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-open:{d}", .{saved_id});
}
fn tSavedRemove(_: *App, b: []u8) []const u8 {
    return markFmt(b, "saved-remove:{d}", .{saved_id});
}
fn noteEditing(app: *App) bool {
    return saved_ui.isEditing() and app.st.popup == .saved and qa.find("saved-note-input") != null;
}
fn noteCancelled(app: *App) bool {
    const it = app.st.saved.find(saved_id) orelse return false;
    return !saved_ui.isEditing() and app.st.popup == .saved and std.mem.eql(u8, it.note, qa_note);
}
/// O que está gravado no arquivo de salvas da conta (qa-out/).
fn savedOnDisk(app: *App) ?saved_core.List {
    var buf: [256]u8 = undefined;
    const p = saved_ui.filePath(&buf, app.store.me) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var l: saved_core.List = .{};
    l.read(app.gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
    return l;
}
const qa_note = "lembrar de responder";
fn noteSaved(app: *App) bool {
    const it = app.st.saved.find(saved_id) orelse return false;
    if (saved_ui.isEditing() or !std.mem.eql(u8, it.note, qa_note)) return false;
    var disk = savedOnDisk(app) orelse return false;
    defer disk.deinit(app.gpa);
    const f = disk.find(saved_id) orelse return false;
    return std.mem.eql(u8, f.note, qa_note) and f.channel == ch(4) and f.content.len > 0;
}
fn jumpedToSaved(app: *App) bool {
    const cs = active(app) orelse return false;
    return cs.info.id == ch(4) and app.st.popup == .none and app.st.jump == 0 and noOldToast(app);
}
fn savedEmptyOnDisk(app: *App) bool {
    if (app.st.saved.items.items.len != 0 or qa.find("saved-empty") == null) return false;
    var disk = savedOnDisk(app) orelse return false;
    defer disk.deinit(app.gpa);
    return disk.items.items.len == 0;
}

const ops = [_]Op{
    s("início"),
    expect("app conecta e carrega o histórico", ready),
    expect("abre com 3 abas e #geral ativo", threeTabs),
    .{ .shot = "01-inicio" },

    s("navegação"),
    click("channel:500006"),
    expect("clicar num canal abre ele na aba", onMemes),
    .{ .ctrl_click = .{ .mark = "channel:500007" } },
    expect("Ctrl+clique abre o canal numa aba nova", newTab),
    ctrl(c.ImGuiKey_W),
    expect("Ctrl+W fecha a aba", tabClosed),
    click("category:500004"),
    expect("clicar na categoria recolhe", catCollapsed),
    click("category:500004"),
    expect("clicar de novo expande", catOpen),
    click("guild:501000"),
    expect("clicar no servidor abre um canal dele", onGuild1),
    click("guild:0"),
    expect("o botão inicial abre os amigos", friendsOpen),
    .{ .shot = "02-dms" },
    click("guild:500000"),
    expect("volta para o primeiro servidor", onGuild0),
    .{ .run = rememberTab },
    ctrl(c.ImGuiKey_Tab),
    expect("Ctrl+Tab troca de aba", tabMoved),
    .{ .key = .{ .key = c.ImGuiKey_2, .alt = true } },
    expect("Alt+2 vai para a segunda aba", tab1),
    .{ .key = .{ .key = c.ImGuiKey_1, .alt = true } },
    click("channel:500005"),

    s("enviar mensagens"),
    click("composer"),
    .{ .text = "teste do QA 🎉 **negrito**" },
    key(c.ImGuiKey_Enter),
    expect("enviar com Enter (e o servidor confirma)", sentConfirmed),
    .{ .text = "oi @ana.exe tudo bem?" },
    key(c.ImGuiKey_Enter),
    expect("@nome vira menção de verdade", mentionResolved),
    .{ .text = long_text },
    key(c.ImGuiKey_Enter),
    expect("mensagem longa com markdown e emoji", longSent),
    .{ .shot = "03-enviadas" },

    s("responder"),
    .{ .hover = .{ .dyn = tHoverOther } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tReplyLast } },
    expect("botão responder da barra de ações", replyArmed),
    .{ .shot = "04-respondendo" },
    .{ .text = "respondendo pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("a resposta sai ligada à original", replySent),

    s("editar"),
    click("composer"),
    key(c.ImGuiKey_UpArrow),
    expect("seta pra cima edita a última mensagem", editing),
    ctrl(c.ImGuiKey_A),
    .{ .text = "editado pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("salvar a edição marca (editado)", edited),

    s("reações"),
    .{ .hover = .{ .dyn = tHoverMine } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tThumbMine } },
    expect("👍 pela barra de ações", reacted),
    .{ .click = .{ .dyn = tChipMine } },
    expect("clicar na reação tira ela", unreacted),

    s("menu do botão direito"),
    .{ .run = rememberCount },
    .{ .rclick = .{ .dyn = tHoverMine } },
    expect("botão direito abre o menu da mensagem", menuOpen),
    .{ .shot = "05-menu" },
    click("menu:Excluir mensagem"),
    expect("excluir pelo menu", deleted),
    .{ .run = clearToast },
    .{ .rclick = .{ .dyn = tHoverOther } },
    click("menu:Copiar texto"),
    expect("copiar texto pelo menu", toastCopied),

    s("seleção de texto"),
    .{ .run = clearToast },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tSelFrom, .fx = 0.12, .fy = 0.8 } }, .to = .{ .dyn_at = .{ .f = tSelTo, .fx = 0.3, .fy = 0.8 } } } },
    expect("arrastar seleciona texto entre mensagens", hasSelection),
    .{ .shot = "06-selecao" },
    ctrl(c.ImGuiKey_C),
    expect("Ctrl+C copia a seleção", toastCopied),
    key(c.ImGuiKey_Escape),

    s("perfil e DM"),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
    .{ .shot = "07-perfil" },
    .{ .wait = 100 },
    .{ .text = "oi do perfil" },
    key(c.ImGuiKey_Enter),
    expect("\"Mensagem @fulano\" manda DM", dmSent),
    click("guild:500000"),

    s("perfil completo"),
    click("guild:500000"),
    click("member:1002"),
    expect("o cartão mostra o jogo, quando entrou no servidor e o que há em comum", cardDetails),
    click("profile-mutual:1"),
    expect("amigos em comum abre o perfil grande na aba certa", fullFriendsTab),
    .{ .shot = "07b-perfil-amigos" },
    click("profile-tab:2"),
    expect("aba de servidores em comum", fullGuildsTab),
    click("profile-tab:0"),
    expect("aba de atividade mostra o jogo", hasActivity),
    .{ .shot = "07c-perfil-grande" },
    click("profile-conn:github"),
    expect("conta ligada abre o link", openedGithub),
    click("profile-note"),
    .{ .text = "jogador de hollow knight" },
    key(c.ImGuiKey_Enter),
    expect("a nota fica guardada", profileNoteSaved),
    click("profile-full-close"),
    expect("o X fecha o perfil grande", popupClosed),

    s("emoji"),
    click("composer-emoji"),
    expect("botão de emoji abre o seletor", emojiOpen),
    .{ .shot = "08-emoji" },
    click("emoji:0"),
    expect("escolher um emoji coloca na caixa", emojiInserted),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    expect("apagar o texto da caixa", inputEmpty),

    s("paleta"),
    ctrl(c.ImGuiKey_K),
    expect("Ctrl+K abre a paleta", paletteOpen),
    .{ .text = "zig" },
    .{ .shot = "09-paleta" },
    key(c.ImGuiKey_Enter),
    expect("Enter na paleta abre o canal", onZig),

    s("voz e botões"),
    click("channel:500014"),
    expect("clicar num canal de voz entra na call", inVoice),
    expect("em call, o painel do usuário continua na tela", panelOnScreen),
    click("voice-member:500014:1001"),
    expect("clicar em quem está na call abre o perfil", profileOpen),
    key(c.ImGuiKey_Escape),
    .{ .rclick = .{ .mark = "voice-member:500014:1001" } },
    click("menu:Mover para…"),
    click("menu:Jogando"),
    expect("botão direito → Mover para… muda a pessoa de call", movedToGaming),
    .{ .rclick = .{ .mark = "member:1001" } },
    click("menu:Desconectar da call"),
    expect("Desconectar da call tira a pessoa da call", disconnected1001),
    click("hangup"),
    expect("desligar sai da call", notInVoice),
    click("me"),
    expect("clicar no próprio nome abre o menu de status", statusMenu),
    click("menu:⊘  Não perturbe"),
    expect("escolher Não perturbe", meDnd),
    click("me"),
    click("menu:●  Online"),
    expect("voltar para Online", meOnline),
    click("user-btn:0"),
    expect("botão de mutar", muted),
    click("user-btn:0"),
    expect("botão de desmutar", unmuted),
    click("header-members"),
    expect("botão de membros esconde a lista", membersHidden),
    expect("a lista some da tela", noMembers),
    click("header-members"),
    expect("e mostra de novo", membersShown),

    s("configurações"),
    click("user-btn:2"),
    expect("engrenagem abre as configurações", settingsOpen),
    click("settings:Minha conta"),
    .{ .shot = "10-conta" },
    click("settings:Privacidade"),
    .{ .shot = "11-voz" },
    click("settings:Atalhos de teclado"),
    click("settings:Desempenho"),
    .{ .shot = "12-desempenho" },
    click("settings:Aparência"),
    click("seg:Claro"),
    expect("Aparência → Claro", lightMode),
    .{ .shot = "13-claro" },
    click("seg:Escuro"),
    expect("Aparência → Escuro", darkMode),
    click("toggle:Modo compacto"),
    expect("liga o modo compacto", compactOn),
    click("toggle:Modo compacto"),
    expect("desliga o modo compacto", compactOff),
    click("theme-card:terminal"),
    expect("clicar na miniatura troca o tema", onTerminal),
    click("toggle:Efeito CRT"),
    expect("opção do tema: desliga o CRT", crtOff),
    click("toggle:Efeito CRT"),
    expect("opção do tema: liga o CRT", crtOn),
    click("theme-card:classico"),
    expect("volta pro classico", onClassico),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as configurações", settingsClosed),

    s("todos os temas"),
    .{ .run = rememberTheme },
    key(c.ImGuiKey_F2),
    expect("F2 troca de tema", themeChanged),
    .{ .shot = "20-tema-2" },
    expect("tema 2 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "21-tema-3" },
    expect("tema 3 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "22-tema-4" },
    expect("tema 4 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "23-tema-5" },
    expect("tema 5 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "24-tema-6" },
    expect("tema 6 mostra conversa e caixa de texto", composerVisible),
    key(c.ImGuiKey_F2),
    .{ .shot = "25-tema-7" },
    expect("tema 7 mostra conversa e caixa de texto", composerVisible),
    // Os temas além dos 7 de sempre (quem cria um tema novo não precisa
    // mexer aqui): pula até o último e confere a volta ao primeiro.
    .{ .run = skipExtraThemes },
    .{ .wait = 200 },
    key(c.ImGuiKey_F2),
    expect("depois do último volta ao primeiro", onClassico),

    s("imagens e anexos"),
    .{ .hover = .{ .dyn = tDemoImage } },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "imagem da conversa carrega", .check = demoImageReady, .timeout_ms = 4000 } },
    .{ .shot = "26-imagem" },
    .{ .click = .{ .dyn = tDemoImage } },
    expect("clicar na imagem abre em tela cheia", viewerOpen),
    .{ .wait = 300 },
    .{ .expect = .{ .name = "tela cheia carrega a imagem grande", .check = noImageLoading, .timeout_ms = 4000 } },
    .{ .shot = "27-imagem-tela-cheia" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a tela cheia", viewerClosed),
    .{ .click = .{ .dyn = tDemoImage } },
    expect("abrir de novo", viewerOpen),
    click("viewer:fechar"),
    expect("o X fecha a tela cheia", viewerClosed),
    .{ .run = clearToast },
    .{ .run = jumpToFile },
    .{ .wait = 500 },
    .{ .click = .{ .dyn = tDemoFile } },
    expect("clicar no arquivo responde", toastDemoFile),
    .{ .run = attachQaImage },
    expect("arquivo entra na bandeja", oneUpload),
    .{ .wait = 200 },
    .{ .shot = "28-bandeja" },
    click("upload-remove:0"),
    expect("tirar o arquivo da bandeja", noUploads),
    .{ .run = attachQaImage },
    click("composer"),
    .{ .text = "olha essa imagem" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "mensagem com imagem enviada", .check = sentWithImage, .timeout_ms = 3000 } },
    expect("bandeja esvazia depois de enviar", noUploads),
    .{ .expect = .{ .name = "imagem enviada aparece", .check = noImageLoading, .timeout_ms = 4000 } },
    .{ .shot = "29-imagem-enviada" },
    .{ .run = attachQaImage },
    click("composer"),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "só a imagem, sem texto", .check = sentImageOnly, .timeout_ms = 3000 } },

    s("amigos, grupos e membros"),
    expect("fotos de perfil carregam", avatarsLoaded),
    expect("ícones dos servidores carregam", iconsLoaded),
    expect("lista de membros vem do servidor, por cargo", guildMembers),
    .{ .shot = "31-membros" },
    click("guild:501000"),
    .{ .expect = .{ .name = "outro servidor, outra lista de membros", .check = otherGuildMembers, .timeout_ms = 3000 } },
    click("guild:500000"),
    .{ .run = jumpToGif },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "GIF animado tem vários quadros", .check = gifAnimated, .timeout_ms = 4000 } },
    .{ .shot = "32-gif" },
    .{ .run = scrollBottom },
    click("guild:0"),
    click("friends"),
    expect("Mensagens diretas → Amigos", friendsOpen),
    .{ .shot = "33-amigos" },
    click("friends-tab:pending"),
    expect("aba Pendentes mostra o pedido", pendingTab),
    click("friend-accept:1009"),
    expect("aceitar o pedido de amizade", accepted),
    click("friend-remove:1006"),
    expect("cancelar o pedido enviado", cancelled),
    click("friends-tab:all"),
    click("friend-message:1001"),
    expect("Mensagem abre a DM existente", dmWithAna),
    expect("DM mostra o perfil no lugar dos membros", dmProfileShown),
    click("channel:900006"),
    expect("grupo lista só os participantes", groupOpen),
    .{ .shot = "34-grupo" },
    click("friends"),
    click("friends-tab:all"),
    click("friend-message:1008"),
    .{ .expect = .{ .name = "amigo sem DM: cria a conversa e abre", .check = newDm, .timeout_ms = 3000 } },
    click("guild:500000"),

    s("links e rolagem"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = jumpToZigLink },
    .{ .wait = 400 },
    click("link:https://ziglang.org"),
    expect("clicar num link abre o navegador", linkOpened),
    expect("ver mensagens antigas mostra o botão de ir ao fim", jumpBottomShown),
    click("jump-bottom"),
    expect("o botão de ir ao fim volta para a última mensagem", atBottom),

    s("plugins"),
    .{ .run = writePlugins },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("sem plugins carregados, a página diz como começar", noPlugins),
    click("button:Recarregar"),
    expect("Recarregar lê os .lua da pasta", pluginsLoaded),
    expect("erro de sintaxe aparece na página", syntaxShown),
    .{ .shot = "35-plugins" },
    key(c.ImGuiKey_Escape),
    expect("fecha as configurações", settingsClosed),
    click("composer"),
    .{ .text = "/shrug sei lá" },
    key(c.ImGuiKey_Enter),
    expect("/shrug (docs/plugins/shrug.lua) manda o texto com ¯\\_(ツ)_/¯", shrugSent),
    click("composer"),
    .{ .text = "/trava" },
    key(c.ImGuiKey_Enter),
    expect("plugin em laço infinito é parado pelo limite de instruções", travaStopped),
    .{ .key = .{ .key = c.ImGuiKey_Y, .ctrl = true, .shift = true } },
    expect("atalho Ctrl+Shift+Y do plugin manda mensagem", keySent),
    click("composer"),
    .{ .text = "ping-plugin" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "evento message chega ao plugin e larper.notify avisa", .check = pongToast, .timeout_ms = 3000 } },
    .{ .run = clearToast },
    .{ .run = fakeUrgent },
    expect("alerta.lua (docs/plugins) avisa a palavra de outra pessoa", alertToast),
    click("composer"),
    .{ .text = "spam-plugin" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "larper.send em resposta a mensagem é bloqueado", .check = spamBlocked, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("toggle:shrug.lua"),
    expect("desligar um plugin", shrugOff),
    key(c.ImGuiKey_Escape),
    click("composer"),
    .{ .text = "/shrug sei lá" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "desligado, /shrug vai como texto normal", .check = shrugLiteral, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    click("toggle:shrug.lua"),
    expect("religar o plugin", shrugOn),
    .{ .sweep = &.{ "toggle:", "button:" } },
    key(c.ImGuiKey_Escape),

} ++ @import("qa_alertas.zig").ops ++ [_]Op{
    s("caixa de entrada"),
    click("guild:500000"),
    click("channel:500005"),
    click("header-inbox"),
    expect("o botão do cabeçalho abre a caixa de entrada", inboxOpen),
    .{ .expect = .{ .name = "DMs e menções não lidas aparecem com prévia", .check = inboxHasPreview, .timeout_ms = 3000 } },
    .{ .expect = .{ .name = "a menção no #anúncios (nunca aberto) está na lista", .check = inboxHasAnnouncement, .timeout_ms = 3000 } },
    .{ .shot = "40-caixa-de-entrada" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tInboxAnnouncement } },
    .{ .expect = .{ .name = "clicar na menção abre o canal e rola até ela", .check = jumpedToMention, .timeout_ms = 3000 } },
    ctrl(c.ImGuiKey_I),
    expect("Ctrl+I abre a caixa de entrada", inboxOpen),
    expect("o canal lido sai da lista", announcementGone),
    .{ .click = .{ .dyn = tInboxReadFirst } },
    expect("✓ marca um canal como lido", firstGroupRead),
    click("inbox-readall"),
    expect("marcar tudo como lido esvazia a caixa", inboxEmpty),
    .{ .shot = "41-caixa-vazia" },
    click("inbox-tab:mentions"),
    .{ .expect = .{ .name = "aba Menções traz as menções recentes", .check = mentionsShown, .timeout_ms = 3000 } },
    .{ .shot = "42-mencoes" },
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tFirstMention } },
    .{ .expect = .{ .name = "menção antiga abre o canal e avisa que não está carregada", .check = oldMentionOpened, .timeout_ms = 3000 } },

    s("mensagens salvas"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .run = rememberOther },
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Salvar mensagem"),
    expect("salvar pelo menu do botão direito", oneSaved),
    .{ .key = .{ .key = c.ImGuiKey_S, .ctrl = true, .shift = true } },
    expect("Ctrl+Shift+S abre as salvas", savedOpen),
    .{ .shot = "43-salvas" },
    .{ .click = .{ .dyn = tSavedNote } },
    expect("clicar em \"Adicionar anotação\" abre a edição", noteEditing),
    .{ .text = qa_note },
    key(c.ImGuiKey_Enter),
    expect("Enter salva a anotação (e ela vai para o arquivo)", noteSaved),
    .{ .shot = "44-salvas-anotacao" },
    .{ .click = .{ .dyn = tSavedNote } },
    expect("editar a anotação de novo", noteEditing),
    .{ .text = " (rascunho)" },
    key(c.ImGuiKey_Escape),
    expect("Esc cancela a edição sem fechar a tela", noteCancelled),
    .{ .run = clearToast },
    .{ .click = .{ .dyn = tSavedOpen } },
    expect("Ir para a mensagem abre o canal nela", jumpedToSaved),
    click("header-saved"),
    expect("o botão do cabeçalho abre as salvas", savedOpen),
    .{ .click = .{ .dyn = tSavedRemove } },
    expect("Remover tira das salvas e do arquivo", savedEmptyOnDisk),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as salvas", popupClosed),
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Salvar mensagem"),
    expect("salvar de novo", oneSaved),
    .{ .rclick = .{ .dyn = tHoverSaved } },
    click("menu:Remover dos salvos"),
    expect("o menu de uma salva oferece remover", noneSaved),

    s("clicar em tudo: servidor"),
    .{ .run = toClassico },
    .{ .wait = 200 },
    click("guild:500000"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "guild:", "folder:", "category:", "channel:", "member:", "voice-member:", "user-btn:", "header-search", "header-members", "header-inbox", "header-saved", "tab:", "tab-plus", "status-theme", "chip:", "chip-add:", "att:", "me", "composer-emoji", "guild-header" } },
    s("clicar em tudo: caixa de entrada"),
    ctrl(c.ImGuiKey_I),
    .{ .wait = 200 },
    .{ .sweep = &.{"inbox-tab:"} },
    key(c.ImGuiKey_Escape),
    s("clicar em tudo: mensagens diretas"),
    click("guild:0"),
    click("friends"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "friends", "friends-tab:", "friend-", "channel:", "dm-search", "active:" } },
    s("clicar em tudo: perfil"),
    click("guild:500000"),
    click("member:1001"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "role:", "role-add", "profile-avatar", "profile-banner", "profile-name", "profile-full", "profile-mutual:" } },
    key(c.ImGuiKey_Escape),
    s("clicar em tudo: perfil grande"),
    click("member:1002"),
    click("profile-full"),
    .{ .wait = 300 },
    .{ .sweep = &.{ "profile-tab:", "profile-conn:", "profile-note", "profile-btn:", "profile-full-close", "profile-avatar", "profile-banner" } },
    click("profile-tab:1"),
    .{ .sweep = &.{"profile-friend:"} },
    click("profile-tab:2"),
    .{ .sweep = &.{"profile-guild:"} },
    key(c.ImGuiKey_Escape),
    s("clicar em tudo: configurações"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Aparência"),
    .{ .sweep = &.{ "toggle:", "seg:", "accent:", "theme-card:" } },
    click("settings:Acessibilidade"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Chat"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Notificações"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Privacidade"),
    .{ .sweep = &.{"toggle:"} },
    click("settings:Avançado"),
    .{ .sweep = &.{"toggle:"} },
    .{ .run = @import("qa_alertas.zig").ignoreOne },
    click("settings:Alertas e filtros"),
    .{ .sweep = &.{ "word-remove:", "unignore:", "seg:", "button:" } },
    .{ .run = @import("qa_alertas.zig").focusReset },
    click("settings:Idioma"),
    .{ .sweep = &.{"radio:"} },
    .{ .sweep = &.{"settings:"} },
    .{ .sweep = &.{"settings-close"} },

    s("janela pequena"),
    .{ .resize = .{ 820, 560 } },
    .{ .wait = 150 },
    expect("janela estreita esconde a lista de membros", noMembers),
    expect("janela estreita ainda mostra a caixa de texto", composerVisible),
    .{ .shot = "30-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 150 },
    expect("janela grande volta a lista de membros", hasMembers),
};

/// Cenários curtos para isolar um problema: QA_SCENE=ctrl|nome|card
const ops_ctrl = [_]Op{
    expect("pronto", ready),
    click("channel:500007"),
    expect("clique simples em #setups", struct {
        fn f(app: *App) bool {
            return app.st.activeChannel() == ch(6);
        }
    }.f),
    click("channel:500005"),
    .{ .ctrl_click = .{ .mark = "channel:500008" } },
    expect("Ctrl+clique em #música abre aba nova", struct {
        fn f(app: *App) bool {
            return app.st.tabs.items.len == 4 and app.st.activeChannel() == ch(7);
        }
    }.f),
};
const ops_nome = [_]Op{
    expect("pronto", ready),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
};

const ops_config = [_]Op{
    expect("pronto", ready),
    click("user-btn:2"),
    expect("abre", settingsOpen),
    click("settings:Aparência"),
    .{ .wait = 300 },
    .{ .shot = "dbg-1" },
    click("toggle:Modo compacto"),
    .{ .wait = 300 },
    .{ .shot = "dbg-2" },
    expect("compacto ligado", compactOn),
};

// --- Bateria por tema (roda em todos os temas, claro e escuro) ---------------

var opt_i: usize = 0;
var opt_before = false;

fn optReset(_: *App) void {
    opt_i = 0;
}
fn optNext(app: *App) void {
    opt_i += 1;
    const th = app.themes.theme_();
    if (opt_i <= th.options.len) opt_before = th.option(th.options[opt_i - 1].name) orelse false;
}
/// Vazio quando o tema tem menos opções: o robô pula o passo.
fn tOpt(app: *App, b: []u8) []const u8 {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return "";
    // As opções do tema vêm antes dos interruptores do app na página (e um
    // tema pode ter uma opção com o mesmo nome de um deles).
    return markFmt(b, "first:toggle:{s}", .{th.options[opt_i - 1].label});
}
fn optFlipped(app: *App) bool {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return true;
    return (th.option(th.options[opt_i - 1].name) orelse false) != opt_before;
}
fn optRestored(app: *App) bool {
    const th = app.themes.theme_();
    if (opt_i == 0 or opt_i > th.options.len) return true;
    return (th.option(th.options[opt_i - 1].name) orelse false) == opt_before;
}
fn sentHere(app: *App) bool {
    const m = lastMsg(app, 0) orelse return false;
    return m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, "oi deste tema");
}
fn tChipSaved(_: *App, b: []u8) []const u8 {
    return markFmt(b, "chip:{d}:0", .{saved_id});
}

const opt_steps = [_]Op{
    .{ .run = optNext },
    .{ .click = .{ .dyn = tOpt } },
    expect("opção do tema liga/desliga", optFlipped),
    .{ .click = .{ .dyn = tOpt } },
    expect("opção do tema volta", optRestored),
};

const ops_theme = [_]Op{
    s("tema"),
    expect("carrega e mostra a conversa", ready),
    expect("caixa de texto e mensagens na tela", composerVisible),
    .{ .shot = "tema" },
    click("composer"),
    .{ .text = "oi deste tema" },
    key(c.ImGuiKey_Enter),
    expect("enviar mensagem", sentHere),
    .{ .hover = .{ .dyn = tHoverOther } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tReplyLast } },
    expect("responder pela barra de ações", replyArmed),
    .{ .text = "respondendo pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("resposta enviada", replySent),
    click("composer"),
    key(c.ImGuiKey_UpArrow),
    expect("seta pra cima edita", editing),
    ctrl(c.ImGuiKey_A),
    .{ .text = "editado pelo QA" },
    key(c.ImGuiKey_Enter),
    expect("edição salva", edited),
    .{ .hover = .{ .dyn = tHoverMine } },
    .{ .wait = 150 },
    .{ .click = .{ .dyn = tThumbMine } },
    expect("reagir pela barra de ações", reacted),
    .{ .shot = "tema-reacao" },
    .{ .click = .{ .dyn = tChipSaved } },
    expect("tirar a reação", unreacted),
    .{ .run = rememberCount },
    .{ .rclick = .{ .dyn = tHoverMine } },
    expect("menu do botão direito", menuOpen),
    .{ .shot = "tema-menu" },
    click("menu:Excluir mensagem"),
    expect("excluir pelo menu", deleted),
    .{ .run = clearToast },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tSelFrom, .fx = 0.2, .fy = 0.5 } }, .to = .{ .dyn_at = .{ .f = tSelTo, .fx = 0.7, .fy = 0.5 } } } },
    expect("selecionar texto", hasSelection),
    ctrl(c.ImGuiKey_C),
    expect("copiar a seleção", toastCopied),
    key(c.ImGuiKey_Escape),
    .{ .click = .{ .dyn = tUserOther } },
    expect("clicar no nome abre o perfil", profileOpen),
    .{ .shot = "tema-perfil" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o perfil", popupClosed),
    click("composer-emoji"),
    expect("seletor de emoji", emojiOpen),
    click("emoji:0"),
    expect("emoji na caixa de texto", emojiInserted),
    click("composer"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    click("guild:0"),
    expect("mensagens diretas começam pelos amigos", friendsOpen),
    .{ .shot = "tema-amigos" },
    // No zen não tem lista de canais: a DM abre direto.
    .{ .run = openFirstDm },
    expect("chegar nas mensagens diretas", onDms),
    .{ .shot = "tema-dms" },
    click("guild:500000"),
    ctrl(c.ImGuiKey_K),
    expect("paleta", paletteOpen),
    .{ .text = "zig" },
    key(c.ImGuiKey_Enter),
    expect("paleta abre o canal", onZig),
    ctrl(c.ImGuiKey_I),
    expect("Ctrl+I abre a caixa de entrada", inboxOpen),
    .{ .shot = "tema-caixa" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha a caixa de entrada", popupClosed),
    ctrl(c.ImGuiKey_Comma),
    expect("Ctrl+, abre as configurações", settingsOpen),
    click("settings:Aparência"),
    .{ .run = optReset },
} ++ opt_steps ++ opt_steps ++ opt_steps ++ opt_steps ++ [_]Op{
    .{ .shot = "tema-config" },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha as configurações", settingsClosed),
    .{ .resize = .{ 860, 600 } },
    .{ .wait = 200 },
    expect("janela pequena: ainda dá pra usar", composerVisible),
    .{ .shot = "tema-pequena" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 200 },
};

// --- Tela de login -------------------------------------------------------------

fn loginForm(app: *App) bool {
    return app.login.phase == .form and qa.find("login:token") != null;
}
fn loginErr(app: *App) bool {
    return app.login.phase == .form and app.login.err_len > 0;
}
fn loginRefused(app: *App) bool {
    const e = app.login.err_buf[0..app.login.err_len];
    return std.mem.indexOf(u8, e, "recusou") != null and app.login.tokenText().len == 0;
}
fn loginShown(app: *App) bool {
    return app.login.show;
}
fn loginHidden(app: *App) bool {
    return !app.login.show;
}
fn loginNoRemember(app: *App) bool {
    return !app.login.remember;
}
fn loginRemember(app: *App) bool {
    return app.login.remember;
}
fn loginHelp(app: *App) bool {
    return app.login.help and app.login.help_k > 0.98;
}
fn loginNoHelp(app: *App) bool {
    return !app.login.help;
}
fn loginGone(app: *App) bool {
    return app.store.ready and !app.login.visible() and app.store.demo;
}
fn loginBack(app: *App) bool {
    return loginForm(app) and !app.store.ready and app.net == .none;
}

const ops_login = [_]Op{
    s("login"),
    .{ .wait = 2200 },
    expect("a tela de login aparece depois da abertura", loginForm),
    .{ .shot = "login" },
    click("login:token"),
    .{ .text = "curto" },
    key(c.ImGuiKey_Enter),
    expect("token curto mostra erro", loginErr),
    .{ .wait = 120 },
    .{ .shot = "login-erro" },
    click("login:mostrar"),
    expect("mostrar o token", loginShown),
    click("login:mostrar"),
    expect("ocultar o token", loginHidden),
    click("login:token"),
    ctrl(c.ImGuiKey_A),
    key(c.ImGuiKey_Backspace),
    .{ .text = "XTIzNDU2Nzg5MDEyMzQ1Njc4.Gqa000.token-de-teste-que-nao-existe-aaaaaaaaaaaa" },
    click("login:entrar"),
    expect("token recusado: erro e campo limpo", loginRefused),
    click("login:lembrar"),
    expect("desligar o lembrar", loginNoRemember),
    click("login:lembrar"),
    expect("religar o lembrar", loginRemember),
    click("login:ajuda"),
    expect("abrir a ajuda do token", loginHelp),
    .{ .shot = "login-ajuda" },
    click("login:ajuda"),
    expect("fechar a ajuda", loginNoHelp),
    .{ .resize = .{ 760, 640 } },
    .{ .wait = 300 },
    expect("janela estreita: o campo continua lá", loginForm),
    .{ .shot = "login-estreita" },
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 200 },
    click("login:demo"),
    .{ .expect = .{ .name = "modo demonstração entra no app", .check = loginGone, .timeout_ms = 5000 } },
    .{ .shot = "login-entrou" },
    ctrl(c.ImGuiKey_Comma),
    expect("abrir as configurações", settingsOpen),
    click("settings:Minha conta"),
    click("button:Sair"),
    expect("sair volta para o login", loginBack),
    .{ .wait = 300 },
    .{ .shot = "login-saiu" },
    click("login:demo"),
    .{ .expect = .{ .name = "entrar de novo depois de sair", .check = loginGone, .timeout_ms = 5000 } },
};

fn script() []const Op {
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "tema")) return &ops_theme;
    if (c.SDL_getenv("QA_SUITE")) |suite| if (std.mem.eql(u8, std.mem.span(suite), "login")) return &ops_login;
    const scene = std.mem.span(c.SDL_getenv("QA_SCENE") orelse return &ops);
    if (std.mem.eql(u8, scene, "ctrl")) return &ops_ctrl;
    if (std.mem.eql(u8, scene, "nome")) return &ops_nome;
    if (std.mem.eql(u8, scene, "config")) return &ops_config;
    return &ops;
}

// --- Execução ---------------------------------------------------------------

pub const Runner = struct {
    index: usize = 0,
    sub: u32 = 0,
    started_ms: i64 = 0,
    step_ms: i64 = 0,
    pass: usize = 0,
    fail: usize = 0,
    section: []const u8 = "",
    failures: std.ArrayList([]const u8) = .empty,
    mouse: [2]f32 = .{ 640, 400 },
    sweep: Sweep = .{},
    target_pos: [2]f32 = .{ 0, 0 },
    settle: u32 = 0,

    fn now() i64 {
        return gw.nowMs();
    }

    fn resolve(app: *App, t: Target, buf: []u8) ?[2]f32 {
        const k_fx: struct { k: []const u8, fx: f32, fy: f32 } = switch (t) {
            .mark => |k| .{ .k = k, .fx = 0.5, .fy = 0.5 },
            .dyn => |f| .{ .k = f(app, buf), .fx = 0.5, .fy = 0.5 },
            .at => |a| .{ .k = a.key, .fx = a.fx, .fy = a.fy },
            .dyn_at => |a| .{ .k = a.f(app, buf), .fx = a.fx, .fy = a.fy },
        };
        // "first:nome": a primeira com esse nome (dois elementos iguais na página).
        const r = (if (std.mem.startsWith(u8, k_fx.k, "first:")) qa.findFirst(k_fx.k[6..]) else qa.find(k_fx.k)) orelse return null;
        return .{ r.x + r.w * k_fx.fx, r.y + r.h * k_fx.fy };
    }

    /// Se o elemento está fora da janela, rola até ele (como uma pessoa faria).
    fn scrollTo(r: *Runner, app: *App, p: [2]f32) bool {
        const h = app.io.*.DisplaySize.y;
        if (p[1] > 2 and p[1] < h - 2) return false;
        c.ImGuiIO_AddMousePosEvent(app.io, app.io.*.DisplaySize.x * 0.6, h * 0.5);
        c.ImGuiIO_AddMouseWheelEvent(app.io, 0, if (p[1] >= h - 2) -2 else 2);
        r.sub = 0;
        // Espera a rolagem acontecer e as posições serem redesenhadas.
        r.settle = 4;
        return true;
    }

    fn targetName(app: *App, t: Target, buf: []u8) []const u8 {
        return switch (t) {
            .mark => |k| k,
            .dyn => |f| f(app, buf),
            .at => |a| a.key,
            .dyn_at => |a| a.f(app, buf),
        };
    }

    fn record(r: *Runner, ok: bool, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return;
        if (ok) {
            r.pass += 1;
            std.debug.print("  \x1b[32m✓\x1b[0m {s}\n", .{msg});
            std.heap.c_allocator.free(msg);
        } else {
            r.fail += 1;
            std.debug.print("  \x1b[31m✗ {s}\x1b[0m\n", .{msg});
            const full = std.fmt.allocPrint(std.heap.c_allocator, "[{s}] {s}", .{ r.section, msg }) catch return;
            std.heap.c_allocator.free(msg);
            r.failures.append(std.heap.c_allocator, full) catch {};
        }
    }

    /// Estado da varredura "clicar em tudo".
    const Sweep = struct {
        keys: [160][56]u8 = undefined,
        lens: [160]u8 = undefined,
        n: usize = 0,
        i: usize = 0,
        phase: u8 = 0,
        frames: u32 = 0,
        fp: u64 = 0,
        started: bool = false,
        clicked: usize = 0,
        base: Base = undefined,
    };

    /// O que a varredura restaura entre um clique e outro.
    const Base = struct {
        settings: @import("ui/state.zig").Settings,
        popup: @import("ui/state.zig").Popup,
        guild: Id,
        tab: usize,
        tabs_len: usize,
        tab0: Id,
        friends: bool,
        friends_tab: u8,
        theme: usize,
        voice: ?Id,
        muted: bool,
        deafened: bool,
    };

    fn capture(app: *App) Base {
        const st = &app.st;
        return .{
            .settings = st.settings,
            .popup = st.popup,
            .guild = st.guild,
            .tab = st.tab,
            .tabs_len = st.tabs.items.len,
            .tab0 = if (st.tabs.items.len > st.tab) st.tabs.items[st.tab] else 0,
            .friends = st.friends,
            .friends_tab = st.friends_tab,
            .theme = app.themes.current,
            .voice = st.voice,
            .muted = st.muted,
            .deafened = st.deafened,
        };
    }

    fn restore(app: *App, b: Base) void {
        const st = &app.st;
        st.settings = b.settings;
        st.popup = b.popup;
        st.viewer = null;
        st.palette.open = false;
        st.role_picker = false;
        st.selection = .{};
        st.reply_to = 0;
        st.editing = 0;
        st.guild = b.guild;
        if (st.tabs.items.len > b.tabs_len) st.tabs.shrinkRetainingCapacity(b.tabs_len);
        if (b.tab < st.tabs.items.len) {
            st.tabs.items[b.tab] = b.tab0;
            st.tab = b.tab;
        }
        st.friends = b.friends;
        st.friends_tab = b.friends_tab;
        st.voice = b.voice;
        st.muted = b.muted;
        st.deafened = b.deafened;
        st.open_folders.clearRetainingCapacity();
        st.collapsed.clearRetainingCapacity();
        if (app.themes.current != b.theme) app.actions.append(app.gpa, .{ .set_theme = b.theme }) catch {};
        if (st.activeChannel()) |cid| st.scrollOf(cid).stick_bottom = true;
    }

    /// Impressão digital do que um clique pode mudar.
    fn fingerprint(app: *App) u64 {
        const st = &app.st;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&st.settings));
        h.update(std.mem.asBytes(&st.popup));
        h.update(std.mem.asBytes(&st.guild));
        h.update(std.mem.asBytes(&st.tab));
        h.update(std.mem.sliceAsBytes(st.tabs.items));
        h.update(std.mem.asBytes(&st.friends));
        h.update(std.mem.asBytes(&st.friends_tab));
        h.update(&.{ @intFromBool(st.viewer != null), @intFromBool(st.palette.open), @intFromBool(st.role_picker), @intFromBool(st.muted), @intFromBool(st.deafened) });
        h.update(std.mem.asBytes(&st.voice));
        h.update(std.mem.asBytes(&st.reply_to));
        h.update(std.mem.asBytes(&st.editing));
        h.update(std.mem.asBytes(&st.toast.until_ms));
        h.update(std.mem.asBytes(&st.jump));
        h.update(std.mem.asBytes(&app.themes.current));
        h.update(std.mem.asBytes(&app.plugins.generation));
        h.update(std.mem.asBytes(&@as(u32, st.open_folders.count())));
        h.update(std.mem.asBytes(&@as(u32, st.collapsed.count())));
        h.update(std.mem.asBytes(&@as(u32, st.muted_channels.count())));
        h.update(std.mem.asBytes(&@as(u32, app.store.relationships.count())));
        // Alertas, filtro, ignorados e modo foco (core/filtros.zig).
        h.update(std.mem.asBytes(&app.st.filtros.gen));
        // Opções do tema e cargos de quem está com o cartão aberto.
        const th = app.themes.theme_();
        for (th.options) |o| h.update(&.{@intFromBool(th.option(o.name) orelse o.default)});
        if (st.popup == .profile) if (app.store.memberInfo(st.guild, st.popup.profile.user)) |mi| h.update(std.mem.sliceAsBytes(mi.roleSlice()));
        const att_mod = @import("ui/attachments.zig");
        h.update(att_mod.last_opened[0..att_mod.last_opened_len]);
        h.update(&.{ st.profile_tab, @intFromBool(st.note_editing) });
        h.update(std.mem.asBytes(&@as(u32, app.store.notes.count())));
        h.update(std.mem.asBytes(&@as(u32, @intCast(app.actions.items.len))));
        if (st.activeChannel()) |cid| {
            const sc = st.scrollOf(cid);
            h.update(std.mem.asBytes(&sc.stick_bottom));
            if (app.store.channel(cid)) |cs| {
                h.update(std.mem.asBytes(&cs.version));
                h.update(std.mem.asBytes(&cs.info.unread));
                const items = cs.messages.items;
                for (items) |*m| h.update(std.mem.sliceAsBytes(m.reactionSlice()));
            }
        }
        const top = std.mem.sliceTo(&st.input, 0);
        h.update(top);
        return h.final();
    }

    /// Clicar no que já está selecionado (a aba atual, o canal aberto)
    /// não muda nada e está certo.
    fn alreadySelected(app: *App, name: []const u8) bool {
        const st = &app.st;
        const num = struct {
            fn f(k: []const u8, p: []const u8) ?u64 {
                if (!std.mem.startsWith(u8, k, p)) return null;
                return std.fmt.parseInt(u64, k[p.len..], 10) catch null;
            }
        }.f;
        if (num(name, "tab:")) |t| return t == st.tab;
        if (num(name, "channel:")) |cid| return !st.friends and st.activeChannel() == cid;
        if (num(name, "guild:")) |g| return st.guild == g and !st.friends;
        if (std.mem.startsWith(u8, name, "friends-tab:")) return std.mem.eql(u8, name["friends-tab:".len..], @tagName(@as(enum { online, all, pending, blocked }, @enumFromInt(st.friends_tab))));
        if (std.mem.eql(u8, name, "friends")) return st.friends;
        if (num(name, "profile-tab:")) |t| return t == st.profile_tab;
        // Opções de escolha única: clicar na já escolhida não muda nada.
        for ([_][]const u8{ "seg:", "radio:", "accent:", "theme-card:", "settings:", "inbox-tab:" }) |p| if (std.mem.startsWith(u8, name, p)) return true;
        return false;
    }

    fn sweepOp(r: *Runner, app: *App, prefixes: []const []const u8) void {
        var sw = &r.sweep;
        if (!sw.started) {
            sw.* = .{ .started = true, .base = capture(app) };
            sw.n = qa.keysWith(prefixes, &sw.keys, &sw.lens);
            sw.frames = 0;
            return;
        }
        if (sw.i >= sw.n) {
            restore(app, sw.base);
            r.record(sw.clicked > 0, "varredura: {d} elementos clicados", .{sw.clicked});
            sw.started = false;
            return r.next();
        }
        const kname = sw.keys[sw.i][0..sw.lens[sw.i]];
        sw.frames += 1;
        switch (sw.phase) {
            // Volta ao começo e espera as marcações se refazerem.
            0 => {
                restore(app, sw.base);
                sw.phase = 1;
                sw.frames = 0;
            },
            1 => if (sw.frames >= 4) {
                const rect = qa.find(kname) orelse {
                    // Some depois de restaurar (estava em outra tela): pula.
                    sw.i += 1;
                    sw.phase = 0;
                    return;
                };
                const p: [2]f32 = .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
                if (p[1] < 2 or p[1] > app.io.*.DisplaySize.y - 2 or p[0] < 2 or p[0] > app.io.*.DisplaySize.x - 2) {
                    sw.i += 1;
                    sw.phase = 0;
                    return;
                }
                sw.fp = fingerprint(app);
                if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[varredura] {s} em {d:.0},{d:.0}\n", .{ kname, p[0], p[1] });
                r.target_pos = p;
                r.pos(app, p);
                sw.phase = 2;
            },
            2 => {
                c.ImGuiIO_AddMouseButtonEvent(app.io, 0, true);
                sw.phase = 3;
            },
            3 => {
                c.ImGuiIO_AddMouseButtonEvent(app.io, 0, false);
                sw.phase = 4;
                sw.frames = 0;
            },
            4 => if (sw.frames >= 6) {
                const changed = fingerprint(app) != sw.fp;
                sw.clicked += 1;
                if (!changed and !alreadySelected(app, kname)) {
                    r.record(false, "botão sem efeito: {s}", .{kname});
                }
                if (!app.store.ready) r.record(false, "o app saiu da conta ao clicar em {s}", .{kname});
                sw.i += 1;
                sw.phase = 0;
            },
            else => {},
        }
    }

    fn next(r: *Runner) void {
        r.index += 1;
        r.sub = 0;
        r.step_ms = now();
    }

    fn pos(r: *Runner, app: *App, p: [2]f32) void {
        r.mouse = p;
        c.ImGuiIO_AddMousePosEvent(app.io, p[0], p[1]);
    }

    /// Clique em 3 quadros: posiciona, aperta, solta.
    fn clickOp(r: *Runner, app: *App, t: Target, button: c_int, ctrl_held: bool, double: bool) void {
        // Só procura o elemento antes de clicar: depois do clique ele pode
        // sumir de propósito (um menu que fecha, um botão que troca de tela).
        if (r.settle > 0) {
            r.settle -= 1;
            return;
        }
        if (r.sub == 0) {
            var buf: [64]u8 = undefined;
            if (targetName(app, t, &buf).len == 0) return r.next();
            const p = resolve(app, t, &buf) orelse {
                if (now() - r.step_ms > 1500) {
                    r.record(false, "elemento não encontrado: {s}", .{targetName(app, t, &buf)});
                    r.next();
                }
                return;
            };
            if (r.scrollTo(app, p)) {
                if (now() - r.step_ms > 4000) {
                    r.record(false, "não consegui rolar até {s} (y={d:.0})", .{ targetName(app, t, &buf), p[1] });
                    r.next();
                }
                return;
            }
            r.target_pos = p;
            if (c.SDL_getenv("QA_DEBUG") != null) {
                std.debug.print("[clique] {s} em {d:.0},{d:.0}\n", .{ targetName(app, t, &buf), p[0], p[1] });
                const name = targetName(app, t, &buf);
                qa.dump(name[0 .. std.mem.indexOfScalar(u8, name, ':') orelse name.len]);
            }
        }
        switch (r.sub) {
            0 => {
                if (ctrl_held) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, true);
                r.pos(app, r.target_pos);
            },
            1 => c.ImGuiIO_AddMouseButtonEvent(app.io, button, true),
            2 => c.ImGuiIO_AddMouseButtonEvent(app.io, button, false),
            3 => if (double) c.ImGuiIO_AddMouseButtonEvent(app.io, button, true),
            4 => if (double) c.ImGuiIO_AddMouseButtonEvent(app.io, button, false),
            else => {
                if (ctrl_held) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, false);
                return r.next();
            },
        }
        r.sub += 1;
    }

    /// Avança o roteiro um quadro. Retorna false quando terminou.
    pub fn tick(r: *Runner, app: *App) bool {
        if (r.started_ms == 0) {
            r.started_ms = now();
            r.step_ms = now();
            std.debug.print("\nlarperCord — QA automático\n", .{});
        }
        const list = script();
        if (r.index >= list.len) return r.finish();
        switch (list[r.index]) {
            .section => |name| {
                r.section = name;
                std.debug.print("\n\x1b[1m{s}\x1b[0m\n", .{name});
                r.next();
            },
            .click => |t| r.clickOp(app, t, 0, false, false),
            .rclick => |t| r.clickOp(app, t, 1, false, false),
            .mclick => |t| r.clickOp(app, t, 2, false, false),
            .ctrl_click => |t| r.clickOp(app, t, 0, true, false),
            .dclick => |t| r.clickOp(app, t, 0, false, true),
            .hover => |t| {
                var buf: [64]u8 = undefined;
                if (resolve(app, t, &buf)) |p| {
                    r.pos(app, p);
                    r.next();
                } else if (now() - r.step_ms > 1500) {
                    r.record(false, "elemento não encontrado: {s}", .{targetName(app, t, &buf)});
                    r.next();
                }
            },
            .drag => |dg| {
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                const a = resolve(app, dg.from, &b1) orelse {
                    r.record(false, "início do arraste não encontrado", .{});
                    return blk: {
                        r.next();
                        break :blk true;
                    };
                };
                const z = resolve(app, dg.to, &b2) orelse a;
                switch (r.sub) {
                    0 => r.pos(app, a),
                    1 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, true),
                    2, 3, 4, 5 => {
                        const k = @as(f32, @floatFromInt(r.sub - 1)) / 4;
                        r.pos(app, .{ a[0] + (z[0] - a[0]) * k, a[1] + (z[1] - a[1]) * k });
                    },
                    6 => c.ImGuiIO_AddMouseButtonEvent(app.io, 0, false),
                    else => return blk: {
                        r.next();
                        break :blk true;
                    },
                }
                r.sub += 1;
            },
            .key => |k| {
                switch (r.sub) {
                    0 => {
                        if (k.ctrl) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, true);
                        if (k.shift) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Shift, true);
                        if (k.alt) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Alt, true);
                    },
                    1 => c.ImGuiIO_AddKeyEvent(app.io, k.key, true),
                    2 => c.ImGuiIO_AddKeyEvent(app.io, k.key, false),
                    3 => {
                        if (k.ctrl) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Ctrl, false);
                        if (k.shift) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Shift, false);
                        if (k.alt) c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiMod_Alt, false);
                    },
                    else => return blk: {
                        r.next();
                        break :blk true;
                    },
                }
                r.sub += 1;
            },
            .text => |t| {
                var buf: [512]u8 = undefined;
                const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{t}, 0) catch "";
                c.ImGuiIO_AddInputCharactersUTF8(app.io, z.ptr);
                r.next();
            },
            .wait => |ms| if (now() - r.step_ms >= ms) r.next(),
            .expect => |e| {
                if (e.check(app)) {
                    r.record(true, "{s}", .{e.name});
                    r.next();
                } else if (now() - r.step_ms > e.timeout_ms) {
                    r.record(false, "{s}", .{e.name});
                    r.next();
                }
            },
            .shot => |name| {
                // Espera as animações assentarem um pouco antes do print.
                if (now() - r.step_ms < 250) return true;
                var buf: [128]u8 = undefined;
                const prefix = if (c.SDL_getenv("QA_PREFIX")) |px| std.mem.span(px) else "";
                const path = std.fmt.bufPrintSentinel(&buf, "qa-out/{s}{s}.png", .{ prefix, name }, 0) catch return true;
                _ = app.win.screenshot(path.ptr);
                r.next();
            },
            .resize => |sz| {
                _ = c.SDL_SetWindowSize(app.win.window, sz[0], sz[1]);
                r.next();
            },
            .run => |f| {
                f(app);
                r.next();
            },
            .sweep => |prefixes| r.sweepOp(app, prefixes),
        }
        return true;
    }

    fn finish(r: *Runner) bool {
        const secs = @as(f64, @floatFromInt(now() - r.started_ms)) / 1000;
        std.debug.print("\n{d} passaram, {d} falharam ({d:.1} s). Prints em qa-out/\n", .{ r.pass, r.fail, secs });
        if (r.failures.items.len > 0) {
            std.debug.print("\nFalhas:\n", .{});
            for (r.failures.items) |f| std.debug.print("  - {s}\n", .{f});
        }
        return false;
    }
};
