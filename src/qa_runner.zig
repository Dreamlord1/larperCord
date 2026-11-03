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
const Target = union(enum) {
    mark: Key,
    dyn: *const fn (app: *App, buf: []u8) []const u8,
    /// Ponto dentro da marcação: frações da largura/altura.
    at: struct { key: Key, fx: f32, fy: f32 },
    dyn_at: struct { f: *const fn (app: *App, buf: []u8) []const u8, fx: f32, fy: f32 },
};

const Op = union(enum) {
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
fn tSelFrom(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 2) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
}
fn tSelTo(app: *App, b: []u8) []const u8 {
    const m = lastMsg(app, 1) orelse return "";
    return markFmt(b, "msg:{d}", .{m.msg.id});
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
fn toDemoStart(app: *App) void {
    app.st.reply_to = 0;
    app.st.editing = 0;
}

const long_text = "Mensagem longa do QA pra testar a quebra de linha: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. 😂🔥🎉 `código inline` **negrito** *itálico* ~~riscado~~ ||spoiler|| https://ziglang.org fim.";

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
    expect("o botão inicial abre as mensagens diretas", onDms),
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
    click("hangup"),
    expect("desligar sai da call", notInVoice),
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
    click("settings:Voz e vídeo"),
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
    return markFmt(b, "toggle:{s}", .{th.options[opt_i - 1].label});
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
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tSelFrom, .fx = 0.5, .fy = 0.8 } }, .to = .{ .dyn_at = .{ .f = tSelTo, .fx = 0.6, .fy = 0.8 } } } },
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
    expect("chegar nas mensagens diretas", onDms),
    .{ .shot = "tema-dms" },
    click("guild:500000"),
    ctrl(c.ImGuiKey_K),
    expect("paleta", paletteOpen),
    .{ .text = "zig" },
    key(c.ImGuiKey_Enter),
    expect("paleta abre o canal", onZig),
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
        const r = qa.find(k_fx.k) orelse return null;
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
