//! QA de palavras de alerta, filtro, ignorados, rascunho por canal, modo
//! foco e modo economia (entra na bateria geral do qa_runner.zig).
//! As mensagens "de outras pessoas" entram pela mesma fila que a rede usa.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const filtros = @import("core/filtros.zig");
const platform = @import("platform/window.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

const geral: Id = 500005;
const memes: Id = 500006;
const setups: Id = 500007;
const musica: Id = 500008;
const guild0: Id = 500000;

fn mk(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

// --- Mensagens chegando ---------------------------------------------------------

var seq: u64 = 0;

/// Põe uma mensagem na fila de eventos, como se viesse do Discord.
fn inject(app: *App, channel: Id, author: Id, text: []const u8, image: ?[]const u8) Id {
    const ca = std.heap.c_allocator;
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x3a000 + seq);
    var atts: []types.Attachment = &.{};
    if (image) |url| {
        atts = ca.alloc(types.Attachment, 1) catch return 0;
        atts[0] = .{ .url = ca.dupe(u8, url) catch return 0, .filename = ca.dupe(u8, "qa-economia.png") catch return 0, .width = 900, .height = 560, .size = 245_760 };
    }
    const content = ca.dupe(u8, text) catch return 0;
    app.events.push(.{ .message_create = .{ .id = id, .channel = channel, .author = author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content, .attachments = atts } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}

fn find(app: *App, id: Id) ?*@import("core/store.zig").StoredMessage {
    const f = app.store.findAny(id) orelse return null;
    return f.m;
}

fn guildMentions(app: *App) u16 {
    return if (app.store.guild(guild0)) |g| g.mentions else 0;
}

// --- Palavras de alerta -----------------------------------------------------------

var notified0: u32 = 0;
var mentions0: u16 = 0;
var alert_id: Id = 0;

fn alertAdded(app: *App) bool {
    const l = app.st.filtros.alert.items;
    return l.len == 1 and std.mem.eql(u8, l[0], "pizza");
}
fn injectAlert(app: *App) void {
    notified0 = app.st.filtros.notified;
    mentions0 = guildMentions(app);
    alert_id = inject(app, memes, 1001, "hoje tem PIZZA? 🍕", null);
    _ = inject(app, memes, 1001, "abriu uma pizzaria nova aqui perto", null);
}
fn alertCounted(app: *App) bool {
    return app.st.filtros.count(memes) == 1 and app.st.filtros.notified == notified0 + 1 and find(app, alert_id) != null;
}
fn guildBumped(app: *App) bool {
    return guildMentions(app) == mentions0 + 1;
}
fn alertCleared(app: *App) bool {
    return app.st.activeChannel() == memes and app.st.filtros.count(memes) == 0 and guildMentions(app) == mentions0;
}
fn alertHighlighted(app: *App) bool {
    const m = find(app, alert_id) orelse return false;
    return app.st.filtros.flags(m) & filtros.bit_alert != 0 and qa.find(mk(&buf1, "msgtext:{d}", .{alert_id})) != null;
}

// --- Ignorar ------------------------------------------------------------------------

var buf1: [64]u8 = undefined;
var hidden_id: Id = 0;

fn tAna(_: *App, b: []u8) []const u8 {
    return mk(b, "user:{d}", .{1001});
}
fn userMenu(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .user and app.st.popup.menu.id == 1001;
}
fn anaIgnored(app: *App) bool {
    return app.st.filtros.isIgnored(1001) and app.st.popup == .none;
}
fn anaCollapsed(_: *App) bool {
    return qa.find(mk(&buf1, "hidden:{d}", .{alert_id})) != null and qa.find(mk(&buf1, "msgtext:{d}", .{alert_id})) == null;
}
fn injectFromIgnored(app: *App) void {
    notified0 = app.st.filtros.notified;
    // Mesmo com a palavra de alerta: quem está ignorado não notifica.
    hidden_id = inject(app, geral, 1001, "pizza pizza pizza", null);
}
fn ignoredSilent(app: *App) bool {
    return find(app, hidden_id) != null and app.st.filtros.count(geral) == 0 and app.st.filtros.notified == notified0;
}
fn tShowAna(_: *App, b: []u8) []const u8 {
    return mk(b, "hidden-show:{d}", .{alert_id});
}
fn anaRevealed(app: *App) bool {
    return app.st.filtros.revealed.contains(alert_id) and qa.find(mk(&buf1, "msgtext:{d}", .{alert_id})) != null;
}
var gen0: u32 = 0;
fn markGen(app: *App) void {
    gen0 = app.st.filtros.gen;
}
/// Mostrar uma, contar menção ou ler um canal não refaz o cache de todas.
fn genKept(app: *App) bool {
    return app.st.filtros.gen == gen0;
}

// --- Filtro ---------------------------------------------------------------------------

var filtered_id: Id = 0;

fn filterAdded(app: *App) bool {
    const l = app.st.filtros.filter.items;
    return l.len == 1 and std.mem.eql(u8, l[0], "brócolis");
}
fn unignoreShown(_: *App) bool {
    return qa.find("unignore:1001") != null;
}
fn anaBack(app: *App) bool {
    return !app.st.filtros.isIgnored(1001) and qa.find("unignore:1001") == null;
}
fn injectFiltered(app: *App) void {
    notified0 = app.st.filtros.notified;
    filtered_id = inject(app, memes, 1002, "eu odeio Brócolis, sério", null);
}
fn filteredCollapsed(app: *App) bool {
    return find(app, filtered_id) != null and qa.find(mk(&buf1, "hidden:{d}", .{filtered_id})) != null;
}

// --- Rascunho --------------------------------------------------------------------------

const draft_text = "rascunho do QA, não enviar ainda";

fn input(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}
fn draftKept(app: *App) bool {
    const d = app.st.drafts.get(memes) orelse return false;
    return app.st.activeChannel() == geral and std.mem.eql(u8, d, draft_text) and input(app).len == 0;
}
fn draftBack(app: *App) bool {
    return app.st.activeChannel() == memes and std.mem.eql(u8, input(app), draft_text);
}
fn draftGone(app: *App) bool {
    const cs = app.store.channel(memes) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return false;
    const last = &items[items.len - 1];
    return app.st.drafts.get(memes) == null and std.mem.eql(u8, last.msg.content, draft_text) and input(app).len == 0;
}

// --- Modo foco ------------------------------------------------------------------------

fn focusMenuOn(app: *App) bool {
    const f = &app.st.filtros;
    const left = f.focusLeftMin(gw.nowMs()) orelse return false;
    return f.focusOn(gw.nowMs()) and left == 15 and qa.find("mode-line") != null;
}
fn injectFocus(app: *App) void {
    if (app.store.channel(setups)) |cs| cs.info.unread = false;
    _ = inject(app, setups, 1003, "alguém viu o novo teclado?", null);
    var b: [64]u8 = undefined;
    _ = inject(app, musica, 1004, mk(&b, "<@{d}> escuta essa", .{app.store.me}), null);
}
fn setupsQuiet(app: *App) bool {
    const cs = app.store.channel(setups) orelse return false;
    return !cs.info.unread and app.st.filtros.focus_quiet.contains(setups) and cs.messages.items.len > 0;
}
fn mentionCounts(app: *App) bool {
    return app.st.filtros.count(musica) == 1;
}
fn focusOff(app: *App) bool {
    const cs = app.store.channel(setups) orelse return false;
    return !app.st.filtros.focusOn(gw.nowMs()) and cs.info.unread and qa.find("mode-line") == null;
}

// --- Modo economia ----------------------------------------------------------------------

var image_id: Id = 0;
const saver_url = "demo:7";

fn saverOn(app: *App) bool {
    return app.st.settings.data_saver and app.images.data_saver;
}
fn saverOff(app: *App) bool {
    return !app.st.settings.data_saver;
}
fn injectImage(app: *App) void {
    image_id = inject(app, memes, 1002, "foto pesada", saver_url);
    app.st.scrollOf(memes).stick_bottom = true;
}
fn inCache(app: *App, url: []const u8) ?bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, url) and e.key_ptr.*[e.key_ptr.len - url.len - 1] == ' ') return e.value_ptr.state == .ready;
    return null;
}
fn imageHeld(app: *App) bool {
    return qa.find(mk(&buf1, "att-blocked:{d}", .{image_id})) != null and inCache(app, saver_url) == null;
}
fn tHeld(_: *App, b: []u8) []const u8 {
    return mk(b, "att-blocked:{d}", .{image_id});
}
fn imageLoaded(app: *App) bool {
    return (inCache(app, saver_url) orelse false) and qa.find(mk(&buf1, "att-blocked:{d}", .{image_id})) == null;
}

// --- Para a varredura da página -----------------------------------------------------------

pub fn ignoreOne(app: *App) void {
    app.st.filtros.setIgnored(app.gpa, 1005, true);
    _ = app.st.filtros.addWord(app.gpa, .alert, "deploy");
}
pub fn focusReset(app: *App) void {
    if (app.st.filtros.focus_until != 0) app.st.filtros.endFocus(&app.store);
}

fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}
fn settingsClosed(app: *App) bool {
    return !app.st.settings.open;
}
fn statusMenu(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .status;
}

pub const ops = [_]Op{
    s("palavras de alerta"),
    click("guild:500000"),
    click("channel:500006"),
    click("user-btn:2"),
    expect("engrenagem abre as configurações", settingsOpen),
    click("settings:Alertas e filtros"),
    .{ .shot = "40-alertas-vazio" },
    click("word-input:alerta"),
    .{ .text = "  Pizza " },
    key(c.ImGuiKey_Enter),
    expect("palavra de alerta entra na lista (minúsculas, sem espaços)", alertAdded),
    click("settings-close"),
    expect("fecha as configurações", settingsClosed),
    click("channel:500005"),
    .{ .run = injectAlert },
    expect("mensagem com a palavra conta como menção e notifica", alertCounted),
    expect("\"pizzaria\" não conta (só a palavra inteira)", alertCounted),
    expect("o servidor ganha a menção na barra", guildBumped),
    .{ .shot = "41-alerta-contador" },
    click("channel:500006"),
    expect("abrir o canal zera o contador (e o do servidor)", alertCleared),
    expect("a mensagem com a palavra fica destacada", alertHighlighted),

    s("ignorar sem bloquear"),
    // A conversa acabou de abrir e ainda está rolando até o fim.
    .{ .wait = 400 },
    .{ .rclick = .{ .dyn = tAna } },
    expect("botão direito no nome abre o menu da pessoa", userMenu),
    click("menu:Ignorar"),
    expect("Ignorar pelo menu", anaIgnored),
    expect("as mensagens de quem foi ignorado ficam recolhidas", anaCollapsed),
    .{ .shot = "42-ignorado" },
    .{ .run = injectFromIgnored },
    expect("quem foi ignorado não notifica nem conta", ignoredSilent),
    .{ .run = markGen },
    .{ .click = .{ .dyn = tShowAna } },
    expect("\"mostrar\" revela a mensagem recolhida", anaRevealed),
    expect("\"mostrar\" não refaz o cache das palavras de todas as mensagens", genKept),

    s("filtro de palavras"),
    click("user-btn:2"),
    click("settings:Alertas e filtros"),
    click("word-input:filtro"),
    .{ .text = "BRÓCOLIS" },
    click("button:Adicionar filtro"),
    expect("palavra do filtro entra na lista (acento maiúsculo vira minúsculo)", filterAdded),
    expect("quem foi ignorado aparece na página", unignoreShown),
    .{ .shot = "43-alertas-pagina" },
    click("unignore:1001"),
    expect("Deixar de ignorar pela página", anaBack),
    click("settings-close"),
    .{ .run = injectFiltered },
    expect("mensagem com palavra do filtro fica recolhida", filteredCollapsed),
    .{ .shot = "44-filtrada" },

    s("rascunho por canal"),
    click("composer"),
    .{ .text = draft_text },
    click("channel:500005"),
    expect("trocar de canal guarda o rascunho e esvazia a caixa", draftKept),
    click("channel:500006"),
    expect("voltar ao canal traz o rascunho", draftBack),
    click("composer"),
    key(c.ImGuiKey_End),
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "enviar apaga o rascunho", .check = draftGone, .timeout_ms = 3000 } },

    s("modo foco"),
    click("me"),
    expect("menu do status", statusMenu),
    click("menu:Modo foco: 15 min"),
    expect("modo foco liga pelo menu do status e aparece no painel", focusMenuOn),
    .{ .shot = "45-foco" },
    .{ .run = injectFocus },
    expect("no foco, mensagem comum não marca o canal como não lido", setupsQuiet),
    expect("no foco, menção continua contando", mentionCounts),
    click("me"),
    click("menu:Sair do modo foco"),
    expect("sair do foco devolve o não lido do que chegou", focusOff),

    s("modo economia"),
    click("me"),
    click("menu:Ligar modo economia"),
    expect("modo economia liga pelo menu do status", saverOn),
    .{ .run = injectImage },
    .{ .wait = 300 },
    expect("no modo economia a imagem espera um clique (sem baixar)", imageHeld),
    .{ .shot = "46-economia" },
    .{ .click = .{ .dyn = tHeld } },
    .{ .expect = .{ .name = "clicar no lugar da imagem baixa ela", .check = imageLoaded, .timeout_ms = 4000 } },
    click("me"),
    click("menu:Desligar modo economia"),
    expect("desliga o modo economia", saverOff),
};
