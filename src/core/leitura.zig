//! Estado de leitura sincronizado com o Discord: o que o READY diz que já foi
//! lido (`read_state`), a fila de confirmações (ack) e a conta de `last_viewed`.
//! Só dados: quem manda o ack é a thread de rede, por comando.
const std = @import("std");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const filtros_mod = @import("filtros.zig");
const Store = store_mod.Store;
const Filtros = filtros_mod.Filtros;
const Id = types.Id;

/// Início da contagem do Discord (2015-01-01), em ms.
const discord_epoch_ms: i64 = 1420070400000;

/// `last_viewed` do ack: dias desde o começo do Discord, arredondado para cima.
pub fn lastViewed(now_ms: i64) u32 {
    const days = @divFloor(now_ms - discord_epoch_ms + 86_399_999, 86_400_000);
    return @intCast(@max(days, 0));
}

/// A mensagem "anterior" quando a de verdade não está carregada: o Discord
/// aceita qualquer snowflake, e um milissegundo antes vem antes de qualquer
/// mensagem daquele instante (é o que o cliente oficial faz).
pub fn beforeId(id: Id) Id {
    return id -| (@as(Id, 1) << 22);
}

pub const Ack = struct {
    channel: Id,
    message: Id,
    last_viewed: u32 = 0,
};

/// Confirmações de leitura esperando a vez: no máximo uma por canal a cada
/// `min_gap_ms`. A primeira sai na hora; as seguintes se juntam na última.
pub const AckQueue = struct {
    pub const min_gap_ms: i64 = 3000;

    const Slot = struct { channel: Id, message: Id = 0, last_viewed: u32 = 0, sent_ms: i64 = std.math.minInt(i32) };

    slots: std.ArrayList(Slot) = .empty,

    pub fn deinit(q: *AckQueue, gpa: std.mem.Allocator) void {
        q.slots.deinit(gpa);
    }

    pub fn push(q: *AckQueue, gpa: std.mem.Allocator, a: Ack) void {
        for (q.slots.items) |*s| if (s.channel == a.channel) {
            s.message = @max(s.message, a.message);
            s.last_viewed = a.last_viewed;
            return;
        };
        q.slots.append(gpa, .{ .channel = a.channel, .message = a.message, .last_viewed = a.last_viewed }) catch {};
    }

    /// Esquece o que estava esperando no canal (um ack manual vale mais) e
    /// conta como enviado agora, para a próxima não sair colada nele.
    pub fn cancel(q: *AckQueue, gpa: std.mem.Allocator, channel: Id, now_ms: i64) void {
        for (q.slots.items) |*s| if (s.channel == channel) {
            s.message = 0;
            s.sent_ms = now_ms;
            return;
        };
        q.slots.append(gpa, .{ .channel = channel, .sent_ms = now_ms }) catch {};
    }

    /// O próximo ack que já pode sair (e tira da fila).
    pub fn take(q: *AckQueue, now_ms: i64) ?Ack {
        var i: usize = 0;
        while (i < q.slots.items.len) {
            const s = &q.slots.items[i];
            if (now_ms - s.sent_ms < min_gap_ms) {
                i += 1;
                continue;
            }
            // Já passou o intervalo e não tem nada esperando: não precisa mais.
            if (s.message == 0) {
                _ = q.slots.swapRemove(i);
                continue;
            }
            const out: Ack = .{ .channel = s.channel, .message = s.message, .last_viewed = s.last_viewed };
            s.message = 0;
            s.sent_ms = now_ms;
            return out;
        }
        return null;
    }

    /// Tudo o que falta, sem olhar o intervalo (o app está fechando).
    pub fn takeAny(q: *AckQueue) ?Ack {
        for (q.slots.items) |*s| if (s.message != 0) {
            const out: Ack = .{ .channel = s.channel, .message = s.message, .last_viewed = s.last_viewed };
            s.message = 0;
            return out;
        };
        return null;
    }

    /// Quando a thread de rede precisa acordar por causa da fila.
    pub fn nextDue(q: *const AckQueue) i64 {
        var due: i64 = std.math.maxInt(i64);
        for (q.slots.items) |s| due = @min(due, s.sent_ms + min_gap_ms);
        return due;
    }
};

/// O que o READY manda sobre um canal.
fn applyOne(store: *Store, f: *Filtros, gpa: std.mem.Allocator, cs: *store_mod.ChannelState, now_ms: i64) void {
    if (cs.info.kind != .text) return;
    var mentions: u16 = 0;
    var unread = false;
    if (store.read_index.get(cs.info.id)) |e| {
        cs.info.last_message = @max(cs.info.last_message, e.last_message);
        cs.read_id = e.last_read;
        unread = cs.info.last_message > e.last_read;
        mentions = e.mentions;
    } else if (cs.info.guild != 0) {
        // Sem registro: nunca foi aberto. Só conta o que veio depois de entrar
        // no servidor. (Numa DM, sem registro é que não tem nada pendente: o
        // próprio Discord cria o registro ao contar a primeira mensagem.)
        const joined = if (store.guild(cs.info.guild)) |g| g.joined_id else 0;
        unread = joined != 0 and cs.info.last_message > joined;
    }
    // O que não dá para abrir não fica aceso.
    if (!store.canAccess(&cs.info)) {
        unread = false;
        mentions = 0;
    }
    if (store_mod.read_debug and unread) std.log.info("leitura: canal {d} (servidor {d}) acendeu: registro do Discord, lido até {d}, última {d}, menções {d}", .{ cs.info.id, cs.info.guild, cs.read_id, cs.info.last_message, mentions });
    cs.info.unread = unread;
    if (mentions > 0) f.setCount(gpa, store, cs.info.id, mentions);
    // Modo foco: só DMs e menções marcam não lido; o resto volta no fim.
    if (unread and mentions == 0 and cs.info.guild != 0 and f.focusOn(now_ms)) f.quiet(gpa, store, cs.info.id);
}

/// Retrato da conta (READY): refaz não lidos e menções de todos os canais.
/// `store.read_index` já tem os registros.
pub fn applyReady(store: *Store, f: *Filtros, gpa: std.mem.Allocator, now_ms: i64) void {
    f.mentions.clearRetainingCapacity();
    f.focus_quiet.clearRetainingCapacity();
    for (store.guilds.items) |*g| {
        g.mentions = 0;
        g.unread = false;
    }
    var it = store.channels.valueIterator();
    while (it.next()) |p| applyOne(store, f, gpa, p.*, now_ms);
    for (store.guilds.items) |*g| store.refreshGuildUnread(g.id);
    store.rev +%= 1;
}

/// Servidor que chegou depois do READY (GUILD_CREATE).
pub fn applyGuild(store: *Store, f: *Filtros, gpa: std.mem.Allocator, guild: Id, now_ms: i64) void {
    if (store.read_index.count() == 0) return;
    for (store.channelsOf(guild)) |id| {
        const cs = store.channel(id) orelse continue;
        // Só quem ainda não recebeu o registro (o que foi lido nesta sessão fica).
        if (cs.info.unread or cs.read_id != 0 or f.count(id) > 0) continue;
        applyOne(store, f, gpa, cs, now_ms);
    }
    store.refreshGuildUnread(guild);
}

/// Quem o Discord diz estar silenciado (lista de servidores, categorias e
/// canais) entra na lista de silenciados daqui. Servidor e categoria viram
/// os canais deles.
pub fn applyMuted(store: *const Store, muted: *std.AutoHashMapUnmanaged(Id, void), gpa: std.mem.Allocator, ids: []const Id) void {
    for (ids) |id| {
        if (store.guild(id) != null) {
            for (store.channelsOf(id)) |ch| muted.put(gpa, ch, {}) catch {};
            continue;
        }
        const cs = store.channel(id) orelse continue;
        muted.put(gpa, id, {}) catch {};
        if (cs.info.kind != .category) continue;
        for (store.channelsOf(cs.info.guild)) |ch| if (store.channel(ch)) |other| {
            if (other.info.parent == id) muted.put(gpa, ch, {}) catch {};
        };
    }
}

/// Mensagens não lidas de um canal a partir de `after`, do que está carregado.
pub fn countFrom(store: *const Store, cs: *store_mod.ChannelState, after: Id) struct { messages: u16, mentions: u16 } {
    var n: u16 = 0;
    var m: u16 = 0;
    const inbox = @import("inbox.zig");
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const sm = &cs.messages.items[i];
        if (sm.msg.id == 0) continue;
        if (sm.msg.id <= after) break;
        if (sm.msg.author == store.me) continue;
        n +|= 1;
        if (inbox.mentionsMeCached(store, cs.info.guild, sm)) m +|= 1;
    }
    return .{ .messages = n, .mentions = m };
}

test "silenciados do Discord: servidor e categoria viram os canais" {
    const ca = std.heap.c_allocator;
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    const guilds = try ca.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try ca.dupe(u8, "g"), .acronym = try ca.dupe(u8, "G") };
    const chans = try ca.alloc(types.Channel, 3);
    chans[0] = .{ .id = 10, .guild = 5, .name = try ca.dupe(u8, "a"), .topic = try ca.dupe(u8, "") };
    chans[1] = .{ .id = 11, .guild = 6, .kind = .category, .name = try ca.dupe(u8, "cat"), .topic = try ca.dupe(u8, "") };
    chans[2] = .{ .id = 12, .guild = 6, .parent = 11, .name = try ca.dupe(u8, "b"), .topic = try ca.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try ca.alloc(types.User, 0), .guilds = guilds, .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    var muted: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer muted.deinit(gpa);
    s.muted = &muted;
    applyMuted(&s, &muted, gpa, &.{ 5, 11, 999 });
    try std.testing.expect(muted.contains(10));
    try std.testing.expect(muted.contains(12));
    // Silenciado não acende o servidor.
    try s.apply(.{ .message_create = .{ .id = 100, .channel = 10, .author = 2, .timestamp = 0, .content = try ca.dupe(u8, "oi") } }, 0);
    try std.testing.expect(s.channel(10).?.info.unread);
    try std.testing.expect(!s.guild(5).?.unread);
}

test "last_viewed conta dias desde 2015 para cima" {
    try std.testing.expectEqual(@as(u32, 0), lastViewed(discord_epoch_ms));
    try std.testing.expectEqual(@as(u32, 1), lastViewed(discord_epoch_ms + 1));
    try std.testing.expectEqual(@as(u32, 1), lastViewed(discord_epoch_ms + 86_400_000));
    try std.testing.expectEqual(@as(u32, 2), lastViewed(discord_epoch_ms + 86_400_001));
}

test "fila de ack: no máximo um por canal a cada 3 s, agrupando" {
    const gpa = std.testing.allocator;
    var q: AckQueue = .{};
    defer q.deinit(gpa);
    q.push(gpa, .{ .channel = 1, .message = 10 });
    // A primeira sai na hora.
    try std.testing.expectEqual(@as(Id, 10), q.take(1000).?.message);
    try std.testing.expect(q.take(1000) == null);
    // Chegam mais duas: esperam e saem juntas na última.
    q.push(gpa, .{ .channel = 1, .message = 11 });
    q.push(gpa, .{ .channel = 1, .message = 12 });
    try std.testing.expect(q.take(2000) == null);
    try std.testing.expectEqual(@as(i64, 4000), q.nextDue());
    try std.testing.expectEqual(@as(Id, 12), q.take(4000).?.message);
    // Outro canal não espera.
    q.push(gpa, .{ .channel = 2, .message = 20 });
    try std.testing.expectEqual(@as(Id, 20), q.take(4000).?.message);
    // Sem nada esperando, o registro some depois do intervalo.
    try std.testing.expect(q.take(9000) == null);
    try std.testing.expectEqual(@as(usize, 0), q.slots.items.len);
    try std.testing.expectEqual(std.math.maxInt(i64), q.nextDue());
    // Ack manual cancela o que esperava e segura o próximo.
    q.push(gpa, .{ .channel = 3, .message = 30 });
    q.cancel(gpa, 3, 10_000);
    try std.testing.expect(q.take(10_000) == null);
    q.push(gpa, .{ .channel = 3, .message = 31 });
    try std.testing.expect(q.take(12_000) == null);
    try std.testing.expectEqual(@as(Id, 31), q.take(13_000).?.message);
    // Fechando: sai sem esperar.
    q.push(gpa, .{ .channel = 3, .message = 32 });
    try std.testing.expectEqual(@as(Id, 32), q.takeAny().?.message);
    try std.testing.expect(q.takeAny() == null);
}

test "read_state do READY: não lidos, menções, sem registro, sem acesso e foco" {
    const ca = std.heap.c_allocator;
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    var f: Filtros = .{};
    defer f.deinit(gpa);
    const guilds = try ca.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try ca.dupe(u8, "g"), .acronym = try ca.dupe(u8, "G"), .joined_id = 500, .owner = 1 };
    const chans = try ca.alloc(types.Channel, 5);
    chans[0] = .{ .id = 10, .guild = 5, .name = try ca.dupe(u8, "lido"), .topic = try ca.dupe(u8, ""), .last_message = 100 };
    chans[1] = .{ .id = 11, .guild = 5, .name = try ca.dupe(u8, "novo"), .topic = try ca.dupe(u8, ""), .last_message = 200 };
    chans[2] = .{ .id = 12, .guild = 5, .name = try ca.dupe(u8, "sem-registro-velho"), .topic = try ca.dupe(u8, ""), .last_message = 400 };
    chans[3] = .{ .id = 13, .guild = 5, .name = try ca.dupe(u8, "sem-registro-novo"), .topic = try ca.dupe(u8, ""), .last_message = 600 };
    chans[4] = .{ .id = 20, .guild = 0, .name = try ca.dupe(u8, "dm"), .topic = try ca.dupe(u8, ""), .recipient = 2, .last_message = 700 };
    try s.apply(.{ .ready = .{ .me = 1, .users = try ca.alloc(types.User, 0), .guilds = guilds, .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    const entries = try ca.alloc(types.ReadEntry, 3);
    entries[0] = .{ .channel = 10, .last_read = 100 };
    entries[1] = .{ .channel = 11, .last_read = 150, .mentions = 3 };
    entries[2] = .{ .channel = 20, .last_read = 650, .mentions = 2 };
    try s.apply(.{ .read_states = .{ .entries = entries } }, 0);
    applyReady(&s, &f, gpa, 0);
    try std.testing.expect(!s.channel(10).?.info.unread);
    try std.testing.expect(s.channel(11).?.info.unread);
    try std.testing.expectEqual(@as(Id, 150), s.channel(11).?.read_id);
    try std.testing.expect(!s.channel(12).?.info.unread);
    try std.testing.expect(s.channel(13).?.info.unread);
    try std.testing.expect(s.channel(20).?.info.unread);
    try std.testing.expectEqual(@as(u16, 3), f.count(11));
    try std.testing.expectEqual(@as(u16, 2), f.count(20));
    const g = s.guild(5).?;
    try std.testing.expectEqual(@as(u16, 3), g.mentions);
    try std.testing.expect(g.unread);

    // Ack de outro dispositivo: limpa até onde ele leu.
    try s.apply(.{ .read = .{ .channel = 11, .message = 200 } }, 0);
    f.clear(&s, 11);
    try std.testing.expect(!s.channel(11).?.info.unread);
    try std.testing.expectEqual(@as(u16, 0), g.mentions);
    // Ack antigo (o eco do nosso, atrasado) não desfaz nem volta o marcador.
    try s.apply(.{ .read = .{ .channel = 11, .message = 180 } }, 0);
    try std.testing.expectEqual(@as(Id, 200), s.channel(11).?.read_id);
    // Manual volta e fica não lido; guarda que foi à mão.
    try s.apply(.{ .read = .{ .channel = 11, .message = 180, .manual = true } }, 0);
    try std.testing.expect(s.channel(11).?.info.unread);
    try std.testing.expect(s.channel(11).?.hold_unread);
    s.markRead(11);
    try std.testing.expect(!s.channel(11).?.hold_unread);

    // De novo, com o modo foco ligado: canal sem menção fica quieto.
    f.startFocus(0, 0);
    applyReady(&s, &f, gpa, 10);
    try std.testing.expect(!s.channel(13).?.info.unread);
    try std.testing.expect(f.focus_quiet.contains(13));
    try std.testing.expect(s.channel(20).?.info.unread);
    f.endFocus(&s);
    try std.testing.expect(s.channel(13).?.info.unread);
    try std.testing.expect(s.guild(5).?.unread);
}

test "mensagem nova: marcador do que já tinha sido lido e nossa própria mensagem" {
    const ca = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try ca.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 0, .name = try ca.dupe(u8, "dm"), .topic = try ca.dupe(u8, ""), .recipient = 2, .last_message = 90 };
    try s.apply(.{ .ready = .{ .me = 1, .users = try ca.alloc(types.User, 0), .guilds = try ca.alloc(types.Guild, 0), .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    const cs = s.channel(10).?;
    try s.apply(.{ .message_create = .{ .id = 100, .channel = 10, .author = 2, .timestamp = 0, .content = try ca.dupe(u8, "oi") } }, 0);
    try std.testing.expect(cs.info.unread);
    // Estava lido até a 90.
    try std.testing.expectEqual(@as(Id, 90), cs.read_id);
    try std.testing.expectEqual(@as(Id, 100), cs.info.last_message);
    try s.apply(.{ .message_create = .{ .id = 101, .channel = 10, .author = 2, .timestamp = 0, .content = try ca.dupe(u8, "oi2") } }, 0);
    try std.testing.expectEqual(@as(Id, 90), cs.read_id);
    // Falar é ter lido (o Discord também marca).
    try s.apply(.{ .message_create = .{ .id = 102, .channel = 10, .author = 1, .timestamp = 0, .content = try ca.dupe(u8, "eu") } }, 0);
    try std.testing.expect(!cs.info.unread);
    try std.testing.expectEqual(@as(Id, 102), cs.read_id);
}

test "histórico com lacuna: em volta de uma mensagem, mais novas e volta ao presente" {
    const ca = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try ca.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 0, .name = try ca.dupe(u8, "dm"), .topic = try ca.dupe(u8, ""), .recipient = 2 };
    try s.apply(.{ .ready = .{ .me = 1, .users = try ca.alloc(types.User, 0), .guilds = try ca.alloc(types.Guild, 0), .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    const page = struct {
        fn f(ids: []const Id) ![]types.Message {
            const out = try std.heap.c_allocator.alloc(types.Message, ids.len);
            for (ids, 0..) |id, i| out[i] = .{ .id = id, .channel = 10, .author = 2, .timestamp = 0, .content = try std.heap.c_allocator.dupe(u8, "x") };
            return out;
        }
    }.f;
    const cs = s.channel(10).?;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 900, 901, 902 }) } }, 0);
    try std.testing.expect(!cs.detached);
    try std.testing.expectEqual(@as(Id, 902), cs.info.last_message);
    // Em volta de uma antiga: a lista vira a página, fora do presente.
    cs.around = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 100, 101, 102 }), .around = true } }, 0);
    try std.testing.expect(cs.detached);
    try std.testing.expectEqual(.done, cs.around);
    try std.testing.expectEqual(@as(usize, 3), cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 902), cs.info.last_message);
    // Mensagem ao vivo não entra na lista, mas conta como não lida.
    try s.apply(.{ .message_create = .{ .id = 903, .channel = 10, .author = 2, .timestamp = 0, .content = try ca.dupe(u8, "nova") } }, 0);
    try std.testing.expectEqual(@as(usize, 3), cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 903), cs.info.last_message);
    try std.testing.expect(cs.info.unread);
    // Antigas continuam funcionando em cima da página.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 98, 99 }), .older = true } }, 0);
    try std.testing.expectEqual(@as(Id, 98), cs.messages.items[0].msg.id);
    // Mais novas: entram no fim; página cheia ainda não chega no presente.
    cs.newer = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 103, 104 }), .newer = true } }, 0);
    try std.testing.expect(cs.detached);
    try std.testing.expectEqual(@as(Id, 104), cs.messages.items[cs.messages.items.len - 1].msg.id);
    // Falhou (vazia com `more`): continua fora e espera um pouco.
    cs.newer = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{}), .newer = true } }, 1000);
    try std.testing.expect(cs.detached);
    try std.testing.expectEqual(.idle, cs.newer);
    try std.testing.expectEqual(@as(i64, 6000), cs.newer_retry_ms);
    // Última página: alcançou o presente.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 902, 903 }), .newer = true, .more = false } }, 0);
    try std.testing.expect(!cs.detached);
    // Fora de novo, e "voltar ao presente" troca tudo pela última página.
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 50, 51 }), .around = true } }, 0);
    try std.testing.expect(cs.detached);
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{ 902, 903 }) } }, 0);
    try std.testing.expect(!cs.detached);
    try std.testing.expectEqual(@as(usize, 2), cs.messages.items.len);
    // Falha em volta: fica como estava e avisa.
    cs.around = .loading;
    try s.apply(.{ .history = .{ .channel = 10, .messages = try page(&.{}), .around = true } }, 0);
    try std.testing.expectEqual(.failed, cs.around);
    try std.testing.expectEqual(@as(usize, 2), cs.messages.items.len);
}
