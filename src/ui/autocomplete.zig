//! Autocompletar da caixa de texto: `@` (pessoas, cargos, @everyone), `#`
//! (canais), `:ab` (emojis) e `/` (comandos dos plugins). A lista aparece
//! acima da caixa; setas e Tab/Enter escolhem, Esc fecha, o mouse também vale.
//!
//! A busca roda só quando o trecho digitado muda; parada, a lista só desenha
//! o que já achou. Com a caixa sem `@ # : /` por perto, o custo é comparar o
//! cursor e o tamanho do texto, uma vez por quadro em que a caixa tem foco.
//!
//! O que se escolhe entra na caixa com o nome (`@Ana Maria`) e vira a menção de
//! verdade só na hora de enviar (`Token`, core/mentions.zig).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const emoji_data = @import("emoji_data.zig");
const emoji_img = @import("emoji_img.zig");
const engine = @import("../plugins/engine.zig");
const types = @import("../core/types.zig");
const mentions = @import("../core/mentions.zig");
const State = @import("state.zig").State;
const Id = types.Id;

const Kind = enum { user, role, everyone, here, channel, voice, emoji, custom, command };

const Item = struct {
    kind: Kind,
    id: Id = 0,
    animated: bool = false,
    locked: bool = false,
    /// Índice em `emoji_data` (kind == .emoji).
    uni: u16 = 0,
    color: u32 = 0,
    score: i32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    hint_buf: [48]u8 = undefined,
    hint_len: u8 = 0,

    fn name(it: *const Item) []const u8 {
        return it.name_buf[0..it.name_len];
    }
    fn hint(it: *const Item) []const u8 {
        return it.hint_buf[0..it.hint_len];
    }
    fn setName(it: *Item, s: []const u8) void {
        const t = d.utf8Prefix(s, it.name_buf.len);
        @memcpy(it.name_buf[0..t.len], t);
        it.name_len = @intCast(t.len);
    }
    fn setHint(it: *Item, s: []const u8) void {
        const t = d.utf8Prefix(s, it.hint_buf.len);
        @memcpy(it.hint_buf[0..t.len], t);
        it.hint_len = @intCast(t.len);
    }
};

const max_items = 24;
const visible_rows = 8;
const row_h: f32 = 36;
const head_h: f32 = 26;

var items: [max_items]Item = undefined;
var n_items: usize = 0;
var sel: usize = 0;
var top: usize = 0;
var is_open = false;
/// Só com a caixa de texto no quadro anterior (um clique tira o foco dela).
var seen = false;
var list_rect: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var anchor: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Onde o cursor está na caixa (bytes), visto pelo callback do campo.
pub var cursor: usize = 0;
/// Cursor pedido para quando o texto for recarregado (`input_sync`).
pub var pending_cursor: ?usize = null;

// O que já foi visto: sem mudança, não faz nada.
var last_cursor: usize = 0;
var last_len: usize = std.math.maxInt(usize);
var trig_at: usize = 0;
var trig_char: u8 = 0;
var last_query: [64]u8 = undefined;
var last_query_len: usize = 0;
var last_trig: u8 = 0;
var last_trig_at: usize = 0;
/// Esc (ou uma escolha) neste `@`: não reabre até ele sumir.
var dismissed_at: ?usize = null;
/// Quantas buscas já rodaram (o QA confere que parado não busca nada).
pub var searches: u32 = 0;

// --- O que foi escolhido, para virar a menção de verdade ao enviar ------------

const Slot = struct {
    shown: [136]u8 = undefined,
    shown_len: u8 = 0,
    repl: [48]u8 = undefined,
    repl_len: u8 = 0,
};
var slots: [16]Slot = undefined;
var n_slots: usize = 0;
var slots_channel: Id = 0;
var tokens_out: [16]mentions.Token = undefined;

pub fn addToken(shown: []const u8, repl: []const u8) void {
    if (shown.len > slots[0].shown.len or repl.len > slots[0].repl.len) return;
    if (n_slots == slots.len) {
        std.mem.copyForwards(Slot, slots[0 .. slots.len - 1], slots[1..]);
        n_slots -= 1;
    }
    const s = &slots[n_slots];
    @memcpy(s.shown[0..shown.len], shown);
    @memcpy(s.repl[0..repl.len], repl);
    s.shown_len = @intCast(shown.len);
    s.repl_len = @intCast(repl.len);
    n_slots += 1;
}

/// As escolhas feitas nesta mensagem (válidas até a próxima chamada).
pub fn tokens() []const mentions.Token {
    for (slots[0..n_slots], 0..) |*s, i| tokens_out[i] = .{ .shown = s.shown[0..s.shown_len], .repl = s.repl[0..s.repl_len] };
    return tokens_out[0..n_slots];
}

pub fn clearTokens() void {
    n_slots = 0;
}

// --- Teclado ------------------------------------------------------------------

pub const Key = enum { up, down, tab, shift_tab, enter, escape };
var key_queue: [8]Key = undefined;
var n_keys: usize = 0;

/// Com a lista aberta, estas teclas são dela e o campo de texto nem vê:
/// o app chama isto antes de entregar a tecla ao ImGui.
pub fn takeKey(k: Key) bool {
    if (!is_open) return false;
    if (n_keys < key_queue.len) {
        key_queue[n_keys] = k;
        n_keys += 1;
    }
    return true;
}

pub fn takeSdlKey(key: u32, mod: u32) bool {
    if (!is_open) return false;
    if (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT) != 0) return false;
    const shift = mod & c.SDL_KMOD_SHIFT != 0;
    return switch (key) {
        c.SDLK_UP => !shift and takeKey(.up),
        c.SDLK_DOWN => !shift and takeKey(.down),
        c.SDLK_TAB => takeKey(if (shift) .shift_tab else .tab),
        // Shift+Enter continua abrindo uma linha nova.
        c.SDLK_RETURN, c.SDLK_KP_ENTER => !shift and takeKey(.enter),
        c.SDLK_ESCAPE => takeKey(.escape),
        else => false,
    };
}

/// O mesmo para o robô de QA, que manda as teclas direto ao ImGui.
pub fn takeImGuiKey(key: c_int, shift: bool, ctrl: bool) bool {
    if (!is_open or ctrl) return false;
    return switch (key) {
        c.ImGuiKey_UpArrow => !shift and takeKey(.up),
        c.ImGuiKey_DownArrow => !shift and takeKey(.down),
        c.ImGuiKey_Tab => takeKey(if (shift) .shift_tab else .tab),
        c.ImGuiKey_Enter, c.ImGuiKey_KeypadEnter => !shift and takeKey(.enter),
        c.ImGuiKey_Escape => takeKey(.escape),
        else => false,
    };
}

pub fn open() bool {
    return is_open;
}

/// O mouse está sobre a lista (a conversa embaixo não rola nem seleciona).
pub fn over(ctx: *const d.Ctx) bool {
    return is_open and list_rect.contains(ctx.mouse.x, ctx.mouse.y);
}

pub fn count() usize {
    return if (is_open) n_items else 0;
}

pub fn selected() usize {
    return sel;
}

fn close() void {
    is_open = false;
    n_items = 0;
    n_keys = 0;
    list_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

// --- Busca --------------------------------------------------------------------

fn add(it: Item) void {
    // Já está? Fica a melhor nota.
    for (items[0..n_items]) |*x| if (x.kind == it.kind and x.id == it.id and x.uni == it.uni) {
        if (x.score >= it.score) return;
        x.* = it;
        resort();
        return;
    };
    if (n_items == items.len) {
        if (items[n_items - 1].score >= it.score) return;
        n_items -= 1;
    }
    var k = n_items;
    while (k > 0 and items[k - 1].score < it.score) : (k -= 1) items[k] = items[k - 1];
    items[k] = it;
    n_items += 1;
}

fn resort() void {
    @import("../core/sort.zig").stable(Item, items[0..n_items], {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return a.score > b.score;
        }
    }.lt);
}

/// Nota de um nome: 0 = não casa. Busca vazia casa com tudo.
fn nameScore(name: []const u8, q: []const u8) i32 {
    if (q.len == 0) return 1;
    return emoji_data.matchName(name, q);
}

fn addUser(ctx: *d.Ctx, uid: Id, q: []const u8, bonus: i32) void {
    const u = ctx.store.user(uid) orelse return;
    if (uid == ctx.store.me and q.len == 0) return;
    const sc = nameScore(u.name, q);
    if (sc == 0) return;
    var it: Item = .{ .kind = .user, .id = uid, .score = sc + bonus };
    it.setName(u.name);
    add(it);
}

fn searchUsers(ctx: *d.Ctx, ch: *const types.Channel, cs_msgs: anytype, q: []const u8) void {
    // Quem falou há pouco vem primeiro.
    var seen_msgs: usize = 0;
    var i = cs_msgs.len;
    while (i > 0 and seen_msgs < 50) {
        i -= 1;
        seen_msgs += 1;
        addUser(ctx, cs_msgs[i].msg.author, q, 40);
    }
    const st_store = ctx.store;
    if (ch.guild == 0) {
        if (ch.recipient != 0) addUser(ctx, ch.recipient, q, 60);
        for (ch.recipients) |uid| addUser(ctx, uid, q, 60);
        return;
    }
    // A lista de membros à vista e todo mundo que já vimos neste servidor.
    if (st_store.memberList(ch.guild)) |ml| for (ml.items.items) |entry| {
        if (entry == .member) addUser(ctx, entry.member.user, q, 20);
    };
    if (q.len > 0) {
        var it = st_store.members.keyIterator();
        while (it.next()) |k| if (k.*[0] == ch.guild) addUser(ctx, k.*[1], q, 10);
    }
    const perms = st_store.channelPermissions(ch);
    const can_all = perms & types.perm.mention_everyone != 0;
    var ri = st_store.roles.valueIterator();
    while (ri.next()) |r| {
        if (r.guild != ch.guild or r.id == ch.guild or !(r.mentionable or can_all)) continue;
        const sc = nameScore(r.name, q);
        if (sc == 0) continue;
        var it: Item = .{ .kind = .role, .id = r.id, .color = r.color, .score = sc };
        it.setName(r.name);
        it.setHint(i18n.tr("cargo", "role"));
        add(it);
    }
    if (can_all) {
        for ([_]struct { k: Kind, n: []const u8, pt: []const u8, en: []const u8 }{
            .{ .k = .everyone, .n = "everyone", .pt = "avisa todo mundo no canal", .en = "notify everyone in this channel" },
            .{ .k = .here, .n = "here", .pt = "avisa quem está online", .en = "notify everyone online" },
        }) |e| {
            const sc = nameScore(e.n, q);
            if (sc == 0) continue;
            var it: Item = .{ .kind = e.k, .score = sc };
            it.setName(e.n);
            it.setHint(i18n.tr(e.pt, e.en));
            add(it);
        }
    }
}

fn searchChannels(ctx: *d.Ctx, ch: *const types.Channel, q: []const u8) void {
    if (ch.guild == 0) return;
    for (ctx.store.channelsOf(ch.guild)) |id| {
        const cs = ctx.store.channel(id) orelse continue;
        if (cs.info.kind == .category or !ctx.store.canAccess(&cs.info)) continue;
        const sc = nameScore(cs.info.name, q);
        if (sc == 0) continue;
        var it: Item = .{ .kind = if (cs.info.kind == .voice) .voice else .channel, .id = id, .score = sc + (if (id == ch.id) @as(i32, -2) else 0) };
        it.setName(cs.info.name);
        if (cs.info.parent) |p| if (ctx.store.channel(p)) |parent| it.setHint(parent.info.name);
        add(it);
    }
}

fn searchEmoji(ctx: *d.Ctx, ch: *const types.Channel, q: []const u8) void {
    var fb: [64]u8 = undefined;
    const folded = emoji_data.fold(&fb, q);
    var gi = ctx.store.guild_emojis.iterator();
    while (gi.next()) |entry| for (entry.value_ptr.*) |*e| {
        const sc = nameScore(e.name, folded);
        if (sc == 0) continue;
        const use = ctx.store.emojiUse(e, ch.guild);
        var it: Item = .{ .kind = .custom, .id = e.id, .animated = e.animated, .locked = use != .ok };
        // O do próprio servidor primeiro; o que não dá para usar por último.
        it.score = sc + (if (e.guild == ch.guild) @as(i32, 100) else 0) - (if (it.locked) @as(i32, 400) else 0);
        it.setName(e.name);
        if (it.locked) {
            it.setHint(if (use == .unavailable) i18n.tr("indisponível neste servidor", "unavailable in this server") else i18n.tr("precisa de Nitro", "requires Nitro"));
        } else if (ctx.store.guild(entry.key_ptr.*)) |g| it.setHint(g.name);
        add(it);
    };
    var hits: [max_items]emoji_data.Hit = undefined;
    for (emoji_data.search(q, &hits)) |h| {
        const e = emoji_data.get(h.index);
        var it: Item = .{ .kind = .emoji, .uni = h.index, .score = h.score };
        it.setName(e.code);
        add(it);
    }
}

fn searchCommands(q: []const u8) void {
    const e = engine.current orelse return;
    for (e.list.items) |p| {
        if (p.L == null) continue;
        for (p.commands.items) |cmd| {
            const bare = if (cmd.len > 0 and cmd[0] == '/') cmd[1..] else cmd;
            const sc = nameScore(bare, q);
            if (sc == 0) continue;
            var it: Item = .{ .kind = .command, .score = sc, .uni = @truncate(std.hash.Wyhash.hash(0, cmd)) };
            it.setName(cmd);
            it.setHint(p.name);
            add(it);
        }
    }
}

fn runSearch(ctx: *d.Ctx, ch_id: Id, q: []const u8, ch: u8) void {
    n_items = 0;
    const cs = ctx.store.channel(ch_id) orelse return;
    switch (ch) {
        '@' => searchUsers(ctx, &cs.info, cs.messages.items, q),
        '#' => searchChannels(ctx, &cs.info, q),
        ':' => searchEmoji(ctx, &cs.info, q),
        '/' => searchCommands(q),
        else => {},
    }
}

// --- A cada quadro ----------------------------------------------------------------

/// Chamado pela caixa de texto logo depois do campo. `box`: onde fica a lista
/// (a base dela encosta em box.y).
pub fn update(ctx: *d.Ctx, ch_id: Id, active: bool, box: d.Rect) void {
    seen = true;
    anchor = box;
    if (ch_id != slots_channel) {
        slots_channel = ch_id;
        clearTokens();
        dismissed_at = null;
        close();
    }
    // Clicar na lista tira o foco do campo: ela tem que sobreviver a esse quadro.
    const clicking = is_open and c.ImGui_IsMouseDown(0) and list_rect.contains(ctx.mouse.x, ctx.mouse.y);
    if (!active and !clicking and pending_cursor == null) {
        if (is_open) close();
        last_len = std.math.maxInt(usize);
        return;
    }
    const st = ctx.st;
    const text = std.mem.sliceTo(&st.input, 0);
    if (active) {
        const cur = @min(cursor, text.len);
        if (cur != last_cursor or text.len != last_len) {
            last_cursor = cur;
            last_len = text.len;
            refresh(ctx, ch_id, text, cur);
        }
    }
    processKeys(ctx);
}

fn refresh(ctx: *d.Ctx, ch_id: Id, text: []const u8, cur: usize) void {
    const found = mentions.findTrigger(text, cur);
    const t = found orelse {
        dismissed_at = null;
        if (is_open) close();
        last_trig = 0;
        return;
    };
    if (mentions.insideCode(text, cur)) {
        if (is_open) close();
        last_trig = 0;
        return;
    }
    if (dismissed_at) |at| {
        if (at == t.at) {
            if (is_open) close();
            return;
        }
        dismissed_at = null;
    }
    const q = text[t.at + 1 .. cur];
    // `:` só abre com 2 letras; nomes curtos demais pegariam qualquer ":)".
    if ((t.ch == ':' and q.len < 2) or q.len > last_query.len) {
        if (is_open) close();
        last_trig = 0;
        return;
    }
    trig_at = t.at;
    trig_char = t.ch;
    // Mesmo trecho: nada a buscar (o cursor pode ter voltado a ele).
    if (t.ch == last_trig and t.at == last_trig_at and q.len == last_query_len and std.mem.eql(u8, q, last_query[0..last_query_len])) return;
    last_trig = t.ch;
    last_trig_at = t.at;
    @memcpy(last_query[0..q.len], q);
    last_query_len = q.len;
    searches +%= 1;
    runSearch(ctx, ch_id, q, t.ch);
    sel = 0;
    top = 0;
    is_open = n_items > 0;
}

fn processKeys(ctx: *d.Ctx) void {
    defer n_keys = 0;
    if (!is_open) return;
    for (key_queue[0..n_keys]) |k| {
        switch (k) {
            .up => sel = if (sel == 0) n_items - 1 else sel - 1,
            .down => sel = if (sel + 1 >= n_items) 0 else sel + 1,
            .shift_tab => sel = if (sel == 0) n_items - 1 else sel - 1,
            .escape => {
                dismissed_at = trig_at;
                last_trig = 0;
                close();
                return;
            },
            .tab, .enter => {
                choose(ctx, sel);
                return;
            },
        }
    }
    if (sel < top) top = sel;
    if (sel >= top + visible_rows) top = sel + 1 - visible_rows;
}

// --- Escolher -----------------------------------------------------------------

/// Troca input[from..to] por `ins`; o cursor vai para o fim do que entrou.
fn replaceRange(st: *State, from: usize, to: usize, ins: []const u8) bool {
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    if (from > to or to > len or len - (to - from) + ins.len >= st.input.len) return false;
    const tail_len = len - to;
    const new_tail = from + ins.len;
    if (new_tail < to) {
        std.mem.copyForwards(u8, st.input[new_tail .. new_tail + tail_len], st.input[to .. to + tail_len]);
    } else if (new_tail > to) {
        std.mem.copyBackwards(u8, st.input[new_tail .. new_tail + tail_len], st.input[to .. to + tail_len]);
    }
    @memcpy(st.input[from .. from + ins.len], ins);
    @memset(st.input[new_tail + tail_len..], 0);
    pending_cursor = new_tail;
    cursor = new_tail;
    st.input_sync = true;
    st.focus_input = true;
    return true;
}

/// Põe texto onde o cursor estava (o emoji do seletor). Sem cursor válido, no fim.
pub fn insertAtCursor(st: *State, ins: []const u8) void {
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    var at = @min(cursor, len);
    while (at > 0 and at < len and (st.input[at] & 0xC0) == 0x80) at -= 1;
    if (!replaceRange(st, at, at, ins)) {
        st.focus_input = true;
    }
}

fn choose(ctx: *d.Ctx, index: usize) void {
    if (index >= n_items) return;
    const it = &items[index];
    const st = ctx.st;
    if (it.locked) {
        st.showToast(ctx.now_ms, true, "este emoji {s}", "this emoji {s}", .{it.hint()});
        return;
    }
    var buf: [160]u8 = undefined;
    var rb: [48]u8 = undefined;
    const name = it.name();
    const shown: []const u8 = switch (it.kind) {
        .user, .role, .everyone, .here => std.fmt.bufPrint(&buf, "@{s}", .{name}) catch return,
        .channel, .voice => std.fmt.bufPrint(&buf, "#{s}", .{name}) catch return,
        .custom => std.fmt.bufPrint(&buf, ":{s}:", .{name}) catch return,
        .emoji => emoji_data.glyphOf(it.uni),
        .command => name,
    };
    const repl: ?[]const u8 = switch (it.kind) {
        .user => std.fmt.bufPrint(&rb, "<@{d}>", .{it.id}) catch null,
        .role => std.fmt.bufPrint(&rb, "<@&{d}>", .{it.id}) catch null,
        .channel, .voice => std.fmt.bufPrint(&rb, "<#{d}>", .{it.id}) catch null,
        .custom => std.fmt.bufPrint(&rb, "<{s}:{s}:{d}>", .{ if (it.animated) "a" else "", name, it.id }) catch null,
        else => null,
    };
    if (it.kind == .custom or it.kind == .emoji) @import("emoji_picker.zig").remember(st, it.kind == .custom, it.id, it.uni, name, it.animated);
    var ins_buf: [168]u8 = undefined;
    const ins = std.fmt.bufPrint(&ins_buf, "{s} ", .{shown}) catch return;
    const to = @min(cursor, std.mem.sliceTo(&st.input, 0).len);
    if (!replaceRange(st, trig_at, to, ins)) return;
    if (repl) |r| addToken(shown, r);
    // O que acabou de entrar não reabre a lista.
    dismissed_at = trig_at;
    last_trig = 0;
    close();
}

// --- Desenho ------------------------------------------------------------------

fn title() []const u8 {
    return switch (trig_char) {
        '@' => i18n.tr("PESSOAS E CARGOS", "PEOPLE AND ROLES"),
        '#' => i18n.tr("CANAIS", "CHANNELS"),
        ':' => i18n.tr("EMOJIS", "EMOJI"),
        else => i18n.tr("COMANDOS DOS PLUGINS", "PLUGIN COMMANDS"),
    };
}

/// Desenhada no fim do quadro principal, por cima da conversa.
pub fn draw(ctx: *d.Ctx) void {
    if (!seen and is_open) close();
    seen = false;
    if (!is_open or n_items == 0) return;
    const shown = @min(n_items, visible_rows);
    const h = head_h + @as(f32, @floatFromInt(shown)) * row_h + 8;
    const r: d.Rect = .{ .x = anchor.x, .y = anchor.y - h - 6, .w = anchor.w, .h = h };
    list_rect = r;
    // Uma região filha: recebe o mouse antes da conversa e não tira o foco do campo.
    const pad: f32 = 14;
    const outer = r.inset(-pad, -pad);
    c.ImGui_SetCursorScreenPos(d.v(outer.x, outer.y));
    _ = c.ImGui_BeginChild("##autocomplete", d.v(outer.w, outer.h), 0, c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    defer c.ImGui_EndChild();
    const dl = c.ImGui_GetWindowDrawList();
    const radius = @max(ctx.th.radius + 2, 6);
    d.shadow(dl, r, radius, 12, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
    qa.mark(r, "autocomplete", .{});
    d.text(dl, ctx.ui.get(.bold), 11, r.x + 14, r.y + 8, ctx.col(.muted), title());
    const hovered_list = r.contains(ctx.mouse.x, ctx.mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
    if (hovered_list and ctx.io.*.MouseWheel != 0 and n_items > visible_rows) {
        const delta: i32 = if (ctx.io.*.MouseWheel > 0) -1 else 1;
        const max_top: i32 = @intCast(n_items - visible_rows);
        top = @intCast(std.math.clamp(@as(i32, @intCast(top)) + delta, 0, max_top));
    }
    const moved = ctx.io.*.MouseDelta.x != 0 or ctx.io.*.MouseDelta.y != 0;
    var y = r.y + head_h;
    for (top..top + shown) |i| {
        const it = &items[i];
        const row: d.Rect = .{ .x = r.x + 6, .y = y, .w = r.w - 12, .h = row_h - 2 };
        const over_row = hovered_list and row.contains(ctx.mouse.x, ctx.mouse.y);
        qa.mark(row, "ac:{d}", .{i});
        if (over_row) {
            c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
            ctx.hot = true;
            if (moved) sel = i;
        }
        if (i == sel) d.rect(dl, row, ctx.col(.hover).mix(ctx.col(.text), 0.05), @max(ctx.th.radius - 2, 3));
        drawRow(ctx, dl, it, row);
        // Na descida do botão: o campo perde o foco neste mesmo quadro.
        if (over_row and c.ImGui_IsMouseClicked(0)) {
            sel = i;
            choose(ctx, i);
            break;
        }
        y += row_h;
    }
}

fn drawRow(ctx: *d.Ctx, dl: *c.ImDrawList, it: *const Item, row: d.Rect) void {
    const cy = row.y + row.h / 2;
    const ix = row.x + 22;
    const fam = ctx.ui;
    const alpha: f32 = if (it.locked) 0.45 else 1;
    switch (it.kind) {
        .user => w.avatar(ctx, dl, ix, cy, 24, it.id, .circle, null, 1),
        .role, .everyone, .here => {
            const col = if (it.color != 0) d.Rgba.hex(it.color) else ctx.col(.muted);
            const tw = d.width(fam.get(.bold), 17, "@");
            d.text(dl, fam.get(.bold), 17, ix - tw / 2, cy - 17 * 0.6, col, "@");
        },
        .channel => {
            const tw = d.width(fam.get(.bold), 17, "#");
            d.text(dl, fam.get(.bold), 17, ix - tw / 2, cy - 17 * 0.6, ctx.col(.muted), "#");
        },
        .voice => icons.speaker(dl, ix, cy, ctx.col(.muted).u()),
        .command => {
            const tw = d.width(fam.get(.bold), 17, "/");
            d.text(dl, fam.get(.bold), 17, ix - tw / 2, cy - 17 * 0.6, ctx.col(.accent), "/");
        },
        .emoji => {
            const glyph = @import("emoji_picker.zig").drawable(emoji_data.glyphOf(it.uni));
            const es = @import("emoji_picker.zig").fitSize(fam.get(.regular), glyph.slice(), 22, 28);
            const tw = d.width(fam.get(.regular), es, glyph.slice());
            d.text(dl, fam.get(.regular), es, ix - tw / 2, cy - es * 0.6, d.Rgba.white, glyph.slice());
        },
        .custom => {
            const box: d.Rect = .{ .x = ix - 12, .y = cy - 12, .w = 24, .h = 24 };
            if (emoji_img.enabled(ctx)) {
                emoji_img.draw(ctx, dl, it.id, it.animated, box, alpha, false, false);
            } else d.rect(dl, box, ctx.col(.text).alpha(0.08), 4);
        },
    }
    const tx = row.x + 44;
    var nb: [80]u8 = undefined;
    const label: []const u8 = switch (it.kind) {
        .emoji, .custom => std.fmt.bufPrint(&nb, ":{s}:", .{it.name()}) catch it.name(),
        else => it.name(),
    };
    const hint = it.hint();
    const hw = if (hint.len > 0) d.width(fam.get(.regular), 12, hint) else 0;
    const tc = (if (it.kind == .user) w.nameColor(ctx, ctx.st.guild, it.id) else ctx.col(.text)).alpha(alpha);
    _ = d.textClipped(dl, fam.get(.semibold), 14, tx, d.centerY(row, 14), tc, label, row.w - 56 - hw);
    if (hint.len > 0) d.text(dl, fam.get(.regular), 12, row.right() - hw - 10, d.centerY(row, 12), ctx.col(.faint), hint);
    if (it.locked) icons.lock(dl, row.right() - hw - 26, cy - 2, ctx.col(.faint).u());
}
