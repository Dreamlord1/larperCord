//! Caixa de entrada: junta, de todos os servidores, as DMs não lidas e as
//! menções a nós ainda não lidas, agrupadas por canal; e a lista de menções
//! recentes (as que o Discord guarda, mais as que chegaram depois).
//! Só lê o Store; o desenho fica em ui/inbox.zig.
const std = @import("std");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const StoredMessage = store_mod.StoredMessage;
const ChannelState = store_mod.ChannelState;
const Filtros = @import("filtros.zig").Filtros;
const Id = types.Id;

pub const max_groups = 48;
/// Prévias por canal (as mais recentes).
pub const per_group = 3;
/// Quantas mensagens do fim de cada canal olhar procurando as não lidas.
const scan_limit = 300;

/// Um canal na aba "Não lidas". `channel` 0 = um servidor que o Discord diz
/// ter menções, sem nenhuma carregada (a linha só leva ao servidor).
pub const Group = struct {
    channel: Id,
    guild: Id,
    /// Mensagens da prévia por ID, a mais antiga primeiro.
    msgs: [per_group]Id = @splat(0),
    n: u8 = 0,
    /// Quantas não lidas (DM) ou menções (servidor) ao todo.
    total: u32 = 0,
    /// A mais recente (para ordenar a lista).
    latest: Id = 0,

    pub fn ids(g: *const Group) []const Id {
        return g.msgs[0..g.n];
    }
};

pub const Model = struct {
    groups: [max_groups]Group = undefined,
    n: usize = 0,
    sig: u64 = 0,
    built: bool = false,

    pub fn slice(m: *const Model) []const Group {
        return m.groups[0..m.n];
    }
};

/// A mensagem fala com a gente: <@nós>, um cargo nosso, @everyone ou @here.
pub fn mentionsMe(store: *const Store, guild: Id, m: *const StoredMessage) bool {
    for (m.spans) |sp| switch (sp.mention) {
        .user => |u| if (u == store.me) return true,
        .role => |r| if (store.hasRole(guild, r)) return true,
        else => {},
    };
    if (m.msg.mention_everyone) return true;
    // "@everyone" escrito por quem não tem permissão não chama ninguém; a
    // demonstração não tem esse dado do servidor.
    if (!store.demo) return false;
    const t = m.msg.content;
    return std.mem.indexOf(u8, t, "@everyone") != null or std.mem.indexOf(u8, t, "@here") != null;
}

/// `mentionsMe` com cache na mensagem: só olha de novo quando o texto ou os
/// nossos cargos mudam.
pub fn mentionsMeCached(store: *const Store, guild: Id, m: *StoredMessage) bool {
    const key = (store.me_rev *% 2654435761 ^ @as(u32, @truncate(@intFromPtr(m.msg.content.ptr) ^ m.msg.content.len))) | 1;
    if (m.mm_key == key) return m.mm;
    m.mm_key = key;
    m.mm = mentionsMe(store, guild, m);
    return m.mm;
}

/// Junta as não lidas de um canal, da mais nova para trás. Para no marcador
/// de leitura ou na nossa última mensagem (responder é ter lido); canal
/// nunca lido nesta sessão não tem marcador e vale só a segunda regra.
fn collect(store: *const Store, cs: *ChannelState, only_mentions: bool, g: *Group) void {
    const items = cs.messages.items;
    var tmp: [per_group]Id = undefined;
    var k: usize = 0;
    var i = items.len;
    var scanned: usize = 0;
    while (i > 0 and scanned < scan_limit) : (scanned += 1) {
        i -= 1;
        const m = &items[i];
        if (m.pending or m.msg.id == 0) continue;
        if (cs.read_id != 0 and m.msg.id <= cs.read_id) break;
        if (m.msg.author == store.me) break;
        if (m.msg.system != .none or m.deleted) continue;
        if (only_mentions and !mentionsMeCached(store, cs.info.guild, m)) continue;
        g.total += 1;
        if (g.latest == 0) g.latest = m.msg.id;
        if (k < per_group) {
            tmp[k] = m.msg.id;
            k += 1;
        }
    }
    for (0..k) |x| g.msgs[x] = tmp[k - 1 - x];
    g.n = @intCast(k);
}

/// DM marcada como não lida à mão (ou sem nada depois do marcador): mostra
/// a última mensagem da outra pessoa, para ter alguma prévia.
fn lastFromOthers(store: *const Store, cs: *const ChannelState, g: *Group) void {
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.id == 0 or m.msg.author == store.me or m.msg.system != .none) continue;
        g.msgs[0] = m.msg.id;
        g.n = 1;
        g.total = 1;
        g.latest = m.msg.id;
        return;
    }
}

/// Monta a aba "Não lidas". Canais silenciados ficam de fora. Quantas menções
/// cada canal tem vem de `counts`: as do Discord podem nem estar carregadas.
pub fn build(store: *const Store, muted: *const std.AutoHashMapUnmanaged(Id, void), counts: ?*const Filtros, out: *Model) void {
    out.n = 0;
    out.built = true;
    var it = store.channels.valueIterator();
    while (it.next()) |p| {
        const cs = p.*;
        if (cs.info.kind != .text or !cs.info.unread or muted.contains(cs.info.id)) continue;
        if (out.n == max_groups) break;
        var g: Group = .{ .channel = cs.info.id, .guild = cs.info.guild };
        const dm = cs.info.guild == 0;
        collect(store, cs, !dm, &g);
        if (dm and g.n == 0) lastFromOthers(store, cs, &g);
        if (counts) |f| g.total = @max(g.total, f.count(cs.info.id));
        if (!dm and g.total == 0) continue;
        if (g.latest == 0) g.latest = cs.info.last_message;
        out.groups[out.n] = g;
        out.n += 1;
    }
    // Servidores com menções contadas pelo Discord e nenhum canal na lista.
    for (store.guilds.items) |gd| {
        if (gd.mentions == 0 or out.n == max_groups) continue;
        const listed = for (out.groups[0..out.n]) |g| {
            if (g.guild == gd.id) break true;
        } else false;
        if (listed) continue;
        out.groups[out.n] = .{ .channel = 0, .guild = gd.id, .total = gd.mentions };
        out.n += 1;
    }
    std.mem.sort(Group, out.groups[0..out.n], {}, struct {
        fn lt(_: void, a: Group, b: Group) bool {
            if (a.latest != b.latest) return a.latest > b.latest;
            return a.channel > b.channel;
        }
    }.lt);
}

/// Muda quando algo que a caixa de entrada mostra pode ter mudado
/// (`Store.rev`, mais quantos canais estão silenciados): de graça a cada quadro.
pub fn signature(store: *const Store, muted_count: u32) u64 {
    return @as(u64, store.rev) << 32 | muted_count;
}

/// Canais da caixa de entrada que ainda não têm histórico (para a prévia):
/// DMs não lidas e os canais não lidos com menções (ou de servidores que o
/// Discord diz terem menções). Já ficam como "carregando"; quem chama pede o
/// histórico.
pub fn prefetch(store: *Store, muted: *const std.AutoHashMapUnmanaged(Id, void), counts: ?*const Filtros, out: []Id) []Id {
    var n: usize = 0;
    var it = store.channels.valueIterator();
    while (it.next()) |p| {
        const cs = p.*;
        if (n == out.len) break;
        if (cs.info.kind != .text or !cs.info.unread or cs.history != .none or muted.contains(cs.info.id)) continue;
        if (cs.info.guild != 0) {
            const g = store.guild(cs.info.guild) orelse continue;
            const here: u16 = if (counts) |f| f.count(cs.info.id) else 0;
            if (here == 0 and (counts != null or g.mentions == 0)) continue;
        }
        cs.history = .loading;
        out[n] = cs.info.id;
        n += 1;
    }
    return out[0..n];
}

// --- Aba "Menções" ------------------------------------------------------------

pub const max_mentions = 64;
pub const max_mention_groups = 32;
/// Mostradas por canal na aba "Menções" (as outras viram "+N").
pub const per_mention_group = 6;

pub const MentionGroup = struct {
    channel: Id,
    guild: Id,
    msgs: [per_mention_group]Id = @splat(0),
    n: u8 = 0,
    total: u32 = 0,

    pub fn ids(g: *const MentionGroup) []const Id {
        return g.msgs[0..g.n];
    }
};

pub const Mentions = struct {
    groups: [max_mention_groups]MentionGroup = undefined,
    n: usize = 0,
    sig: u64 = 0,
    built: bool = false,

    pub fn slice(m: *const Mentions) []const MentionGroup {
        return m.groups[0..m.n];
    }
};

const Ref = struct { channel: Id, guild: Id, id: Id };

/// As menções recentes do Discord mais as que chegaram depois da busca (ou
/// já estavam carregadas e são mais novas que ela), da mais nova para a
/// mais antiga, agrupadas por canal na ordem da mais recente de cada um.
pub fn buildMentions(store: *const Store, out: *Mentions) void {
    out.n = 0;
    out.built = true;
    var refs: [max_mentions]Ref = undefined;
    var nr: usize = 0;
    for (store.recent_mentions.items) |*m| {
        if (nr == refs.len) break;
        const gid = if (store.channel(m.msg.channel)) |cs| cs.info.guild else 0;
        refs[nr] = .{ .channel = m.msg.channel, .guild = gid, .id = m.msg.id };
        nr += 1;
    }
    var it = store.channels.valueIterator();
    while (it.next()) |p| {
        const cs = p.*;
        var i = cs.messages.items.len;
        while (i > 0 and nr < refs.len) {
            i -= 1;
            const m = &cs.messages.items[i];
            if (m.msg.id == 0) continue;
            if (types.snowflakeTime(m.msg.id) <= store.mentions_ms) break;
            if (m.msg.author == store.me or !mentionsMeCached(store, cs.info.guild, m)) continue;
            const dup = for (refs[0..nr]) |r| {
                if (r.id == m.msg.id) break true;
            } else false;
            if (dup) continue;
            refs[nr] = .{ .channel = cs.info.id, .guild = cs.info.guild, .id = m.msg.id };
            nr += 1;
        }
    }
    std.mem.sort(Ref, refs[0..nr], {}, struct {
        fn lt(_: void, a: Ref, b: Ref) bool {
            return a.id > b.id;
        }
    }.lt);
    for (refs[0..nr]) |r| {
        const g = for (out.groups[0..out.n]) |*g| {
            if (g.channel == r.channel) break g;
        } else blk: {
            if (out.n == out.groups.len) break :blk null;
            out.groups[out.n] = .{ .channel = r.channel, .guild = r.guild };
            out.n += 1;
            break :blk &out.groups[out.n - 1];
        };
        const grp = g orelse continue;
        grp.total += 1;
        if (grp.n < per_mention_group) {
            grp.msgs[grp.n] = r.id;
            grp.n += 1;
        }
    }
}

pub fn mentionsSignature(store: *const Store) u64 {
    var h = std.hash.Wyhash.init(store.me);
    h.update(std.mem.asBytes(&store.mentions_ms));
    h.update(std.mem.asBytes(&@as(u32, @intCast(store.recent_mentions.items.len))));
    h.update(std.mem.asBytes(&store.rev));
    return h.final();
}

/// A mensagem, carregada no canal ou guardada entre as menções recentes.
/// `loaded` diz se ela está no canal (dá para rolar até ela).
pub fn lookup(store: *const Store, channel: Id, id: Id) ?struct { m: *const StoredMessage, loaded: bool } {
    if (store.channel(channel)) |cs| if (store.find(cs, id)) |m| return .{ .m = m, .loaded = true };
    for (store.recent_mentions.items) |*m| if (m.msg.id == id) return .{ .m = m, .loaded = false };
    return null;
}

/// Uma linha de prévia: menções viram @nome/#canal, spoilers ficam
/// escondidos, quebras de linha viram espaço. Vazia se não tem texto
/// (só anexo ou embed: quem desenha decide o que mostrar).
pub fn preview(buf: []u8, store: *const Store, m: *const StoredMessage) []const u8 {
    return previewSpans(buf, store, m.spans);
}

pub fn previewSpans(buf: []u8, store: *const Store, spans: []const @import("markdown.zig").Span) []const u8 {
    var n: usize = 0;
    var tmp: [96]u8 = undefined;
    for (spans) |sp| {
        const piece: []const u8 = if (sp.flags.spoiler) "▮▮▮" else switch (sp.mention) {
            .none => sp.text,
            .user => |id| std.fmt.bufPrint(&tmp, "@{s}", .{if (store.user(id)) |u| u.name else "?"}) catch "@?",
            .channel => |id| std.fmt.bufPrint(&tmp, "#{s}", .{if (store.channel(id)) |cs| cs.info.name else "?"}) catch "#?",
            .role => |id| std.fmt.bufPrint(&tmp, "@{s}", .{if (store.roles.get(id)) |r| r.name else "?"}) catch "@?",
        };
        for (piece) |ch| {
            if (n == buf.len) return trimUtf8(buf[0..n]);
            const b: u8 = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
            if (b == ' ' and (n == 0 or buf[n - 1] == ' ')) continue;
            buf[n] = b;
            n += 1;
        }
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

/// Corta um caractere UTF-8 que ficou pela metade no fim.
fn trimUtf8(s: []const u8) []const u8 {
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        if (s[i] & 0xC0 == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
        return if (i + need <= s.len) s else s[0..i];
    }
    return s;
}

test "caixa de entrada: DMs não lidas, menções e marcador de leitura" {
    const ca = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try ca.alloc(types.Channel, 3);
    chans[0] = .{ .id = 10, .guild = 5, .name = try ca.dupe(u8, "geral"), .topic = try ca.dupe(u8, ""), .unread = true };
    chans[1] = .{ .id = 20, .guild = 0, .name = try ca.dupe(u8, "ana"), .topic = try ca.dupe(u8, ""), .recipient = 2, .unread = true };
    chans[2] = .{ .id = 30, .guild = 5, .name = try ca.dupe(u8, "memes"), .topic = try ca.dupe(u8, ""), .unread = true };
    const users = try ca.alloc(types.User, 1);
    users[0] = .{ .id = 2, .name = try ca.dupe(u8, "ana") };
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = try ca.alloc(types.Guild, 0), .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    const msg = struct {
        fn f(st: *Store, id: Id, ch: Id, author: Id, text: []const u8) !void {
            try st.apply(.{ .message_create = .{ .id = id, .channel = ch, .author = author, .timestamp = 0, .content = try std.heap.c_allocator.dupe(u8, text) } }, 0);
        }
    }.f;
    try msg(&s, 100, 10, 2, "nada pra você");
    try msg(&s, 101, 10, 2, "<@1> olha isso");
    try msg(&s, 102, 20, 1, "oi ana");
    try msg(&s, 103, 20, 2, "oi!");
    try msg(&s, 104, 20, 2, "tudo bem?");
    try msg(&s, 105, 30, 2, "sem menção");

    var none: std.AutoHashMapUnmanaged(Id, void) = .empty;
    var m: Model = .{};
    build(&s, &none, null, &m);
    // #memes não tem menção: fica de fora.
    try std.testing.expectEqual(@as(usize, 2), m.n);
    // A DM tem a mais recente: vem primeiro, só com o que veio depois da nossa.
    try std.testing.expectEqual(@as(Id, 20), m.groups[0].channel);
    try std.testing.expectEqualSlices(Id, &.{ 103, 104 }, m.groups[0].ids());
    try std.testing.expectEqual(@as(Id, 10), m.groups[1].channel);
    try std.testing.expectEqualSlices(Id, &.{101}, m.groups[1].ids());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("@? olha isso", preview(&buf, &s, s.find(s.channel(10).?, 101).?));

    // Lido: sai da lista; o que chegar depois volta, só o novo.
    const sig = signature(&s, 0);
    s.markRead(20);
    try std.testing.expect(signature(&s, 0) != sig);
    try msg(&s, 106, 20, 2, "e aí?");
    build(&s, &none, null, &m);
    try std.testing.expectEqual(@as(Id, 20), m.groups[0].channel);
    try std.testing.expectEqualSlices(Id, &.{106}, m.groups[0].ids());

    // Silenciado: fica de fora.
    try none.put(std.testing.allocator, 10, {});
    defer none.deinit(std.testing.allocator);
    build(&s, &none, null, &m);
    try std.testing.expectEqual(@as(usize, 1), m.n);
}

test "prévia corta UTF-8 inteiro e esconde spoiler" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const markdown = @import("markdown.zig");
    const text = "segredo: ||o fim|| e açaí";
    const spans = try markdown.parse(std.testing.allocator, text);
    defer std.testing.allocator.free(spans);
    const sm: StoredMessage = .{ .msg = .{ .id = 1, .channel = 1, .author = 2, .timestamp = 0, .content = text }, .spans = spans };
    var buf: [64]u8 = undefined;
    const p = preview(&buf, &s, &sm);
    try std.testing.expect(std.mem.indexOf(u8, p, "o fim") == null);
    try std.testing.expect(std.mem.indexOf(u8, p, "▮▮▮") != null);
    var small: [24]u8 = undefined;
    const cut = preview(&small, &s, &sm);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}
