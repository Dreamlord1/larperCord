//! Estado do cliente: tudo que veio do Discord, indexado por ID.
//! A interface só lê daqui; quem escreve é `apply` (eventos da rede) e
//! `addPending` (mensagem que acabamos de enviar).
//!
//! Cada canal guarda no máximo `max_messages`; as mais antigas são liberadas.
const std = @import("std");
const types = @import("types.zig");
const markdown = @import("markdown.zig");
const Event = @import("event.zig").Event;
const Id = types.Id;

/// Strings que chegam em eventos são alocadas com o c_allocator (podem vir
/// de outra thread) e liberadas com ele também.
const ev_alloc = std.heap.c_allocator;

pub const StoredMessage = struct {
    msg: types.Message,
    spans: []const markdown.Span,
    pending: bool = false,
    /// Cache de layout (preenchido pela interface).
    layout_w: f32 = -1,
    layout_variant: u32 = 0xffff_ffff,
    height: f32 = 0,
    /// Largura da linha mais longa (usada pelas bolhas).
    natural_w: f32 = 0,
    reactions: [8]types.Reaction = @splat(.{}),
    n_reactions: u8 = 0,

    pub fn reactionSlice(m: *const StoredMessage) []const types.Reaction {
        return m.reactions[0..m.n_reactions];
    }
};

pub const History = enum { none, loading, loaded };

pub const Typing = struct { user: Id, until_ms: i64 };

pub const ChannelState = struct {
    info: types.Channel,
    messages: std.ArrayList(StoredMessage) = .empty,
    history: History = .none,
    typing: std.ArrayList(Typing) = .empty,
    voice_members: std.ArrayList(Id) = .empty,
    /// Muda sempre que a lista de mensagens muda (invalida offsets na UI).
    version: u32 = 0,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    me: Id = 0,
    ready: bool = false,
    max_messages: usize = 400,
    latency_ms: u32 = 0,
    connection: @import("event.zig").Connection = .connecting,
    /// Dados de demonstração (sem conta conectada).
    demo: bool = false,
    users: std.AutoHashMapUnmanaged(Id, types.User) = .empty,
    guilds: std.ArrayList(types.Guild) = .empty,
    channels: std.AutoHashMapUnmanaged(Id, *ChannelState) = .empty,
    /// Canais de cada servidor, na ordem de exibição (categorias incluídas).
    guild_channels: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Store) void {
        var it = s.channels.valueIterator();
        while (it.next()) |cs| {
            for (cs.*.messages.items) |*m| s.freeMessage(m);
            cs.*.messages.deinit(s.gpa);
            cs.*.typing.deinit(s.gpa);
            cs.*.voice_members.deinit(s.gpa);
            ev_alloc.free(cs.*.info.name);
            ev_alloc.free(cs.*.info.topic);
            s.gpa.destroy(cs.*);
        }
        s.channels.deinit(s.gpa);
        var gc = s.guild_channels.valueIterator();
        while (gc.next()) |l| l.deinit(s.gpa);
        s.guild_channels.deinit(s.gpa);
        for (s.guilds.items) |g| {
            ev_alloc.free(g.name);
            ev_alloc.free(g.acronym);
        }
        s.guilds.deinit(s.gpa);
        var ui = s.users.valueIterator();
        while (ui.next()) |u| {
            ev_alloc.free(u.name);
            if (u.activity) |a| ev_alloc.free(a);
        }
        s.users.deinit(s.gpa);
    }

    fn freeMessage(s: *Store, m: *StoredMessage) void {
        ev_alloc.free(m.msg.content);
        s.gpa.free(m.spans);
    }

    pub fn user(s: *const Store, id: Id) ?*const types.User {
        return s.users.getPtr(id);
    }

    pub fn channel(s: *const Store, id: Id) ?*ChannelState {
        return s.channels.get(id);
    }

    pub fn guild(s: *const Store, id: Id) ?*types.Guild {
        for (s.guilds.items) |*g| if (g.id == id) return g;
        return null;
    }

    pub fn channelsOf(s: *const Store, guild_id: Id) []const Id {
        return if (s.guild_channels.get(guild_id)) |l| l.items else &.{};
    }

    /// Aplica um evento vindo da rede. O Store assume as alocações do evento.
    pub fn apply(s: *Store, ev: Event, now_ms: i64) !void {
        switch (ev) {
            .ready => |r| {
                s.me = r.me;
                for (r.users) |u| try s.users.put(s.gpa, u.id, u);
                try s.guilds.appendSlice(s.gpa, r.guilds);
                for (r.channels) |ch| {
                    const cs = try s.gpa.create(ChannelState);
                    cs.* = .{ .info = ch };
                    try s.channels.put(s.gpa, ch.id, cs);
                    const gop = try s.guild_channels.getOrPut(s.gpa, ch.guild);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(s.gpa, ch.id);
                }
                for (r.voice) |pair| {
                    if (s.channel(pair[0])) |cs| try cs.voice_members.append(s.gpa, pair[1]);
                }
                ev_alloc.free(r.users);
                ev_alloc.free(r.guilds);
                ev_alloc.free(r.channels);
                ev_alloc.free(r.voice);
                s.ready = true;
            },
            .message_create => |m| try s.addMessage(m, now_ms),
            .history => |h| {
                defer ev_alloc.free(h.messages);
                const cs = s.channel(h.channel) orelse {
                    for (h.messages) |m| ev_alloc.free(m.content);
                    return;
                };
                // O histórico vem antes do que já temos.
                var fresh: std.ArrayList(StoredMessage) = .empty;
                try fresh.ensureTotalCapacity(s.gpa, h.messages.len + cs.messages.items.len);
                for (h.messages) |m| fresh.appendAssumeCapacity(.{ .msg = m, .spans = try markdown.parse(s.gpa, m.content) });
                fresh.appendSliceAssumeCapacity(cs.messages.items);
                cs.messages.deinit(s.gpa);
                cs.messages = fresh;
                cs.history = .loaded;
                s.trim(cs);
                cs.version +%= 1;
            },
            .typing_start => |t| {
                const cs = s.channel(t.channel) orelse return;
                for (cs.typing.items) |*ty| if (ty.user == t.user) {
                    ty.until_ms = now_ms + 8000;
                    return;
                };
                try cs.typing.append(s.gpa, .{ .user = t.user, .until_ms = now_ms + 8000 });
            },
            .presence_update => |p| if (s.users.getPtr(p.user)) |u| {
                u.status = p.status;
            },
            .voice_state => |v| {
                var it = s.channels.valueIterator();
                while (it.next()) |cs| {
                    const list = &cs.*.voice_members;
                    for (list.items, 0..) |id, i| if (id == v.user) {
                        _ = list.orderedRemove(i);
                        break;
                    };
                }
                if (v.channel) |id| if (s.channel(id)) |cs| try cs.voice_members.append(s.gpa, v.user);
            },
            .latency => |l| s.latency_ms = l,
            .status => |st| s.connection = st,
            .notice => |n| ev_alloc.free(n),
            .reaction_set => |rs| {
                const cs = s.channel(rs.channel) orelse return;
                const m = s.find(cs, rs.id) orelse return;
                for (m.reactions[0..m.n_reactions]) |*r| if (std.mem.eql(u8, r.text(), rs.reaction.text())) {
                    r.* = rs.reaction;
                    m.layout_w = -1;
                    return;
                };
                if (m.n_reactions < m.reactions.len) {
                    m.reactions[m.n_reactions] = rs.reaction;
                    m.n_reactions += 1;
                    m.layout_w = -1;
                }
            },
            .user_upsert => |u| {
                if (s.users.contains(u.id)) {
                    ev_alloc.free(u.name);
                    if (u.activity) |a| ev_alloc.free(a);
                    return;
                }
                try s.users.put(s.gpa, u.id, u);
            },
            .message_update => |up| {
                const cs = s.channel(up.channel) orelse return ev_alloc.free(up.content);
                const m = s.find(cs, up.id) orelse return ev_alloc.free(up.content);
                const spans = markdown.parse(s.gpa, up.content) catch return ev_alloc.free(up.content);
                ev_alloc.free(m.msg.content);
                s.gpa.free(m.spans);
                m.msg.content = up.content;
                m.msg.edited = true;
                m.spans = spans;
                m.layout_w = -1;
                cs.version +%= 1;
            },
            .message_delete => |del| {
                const cs = s.channel(del.channel) orelse return;
                for (cs.messages.items, 0..) |*m, i| if (m.msg.id == del.id) {
                    s.freeMessage(m);
                    _ = cs.messages.orderedRemove(i);
                    cs.version +%= 1;
                    return;
                };
            },
            .reaction => |r| {
                const cs = s.channel(r.channel) orelse return;
                const m = s.find(cs, r.id) orelse return;
                s.react(m, r.emoji.text(), r.user == s.me, r.add);
            },
        }
    }

    pub fn find(s: *const Store, cs: *ChannelState, id: Id) ?*StoredMessage {
        _ = s;
        var i = cs.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (cs.messages.items[i].msg.id == id) return &cs.messages.items[i];
        }
        return null;
    }

    /// Procura uma mensagem em qualquer canal carregado.
    pub fn findAny(s: *const Store, id: Id) ?struct { cs: *ChannelState, m: *StoredMessage } {
        var it = s.channels.valueIterator();
        while (it.next()) |cs| if (s.find(cs.*, id)) |m| return .{ .cs = cs.*, .m = m };
        return null;
    }

    /// Soma ou tira uma reação. `mine` indica se foi a gente.
    pub fn react(s: *Store, m: *StoredMessage, emoji: []const u8, mine: bool, add: bool) void {
        _ = s;
        for (m.reactions[0..m.n_reactions], 0..) |*r, i| if (std.mem.eql(u8, r.text(), emoji)) {
            if (add) {
                if (mine and r.me) return;
                r.count += 1;
                if (mine) r.me = true;
            } else {
                if (mine and !r.me) return;
                r.count -|= 1;
                if (mine) r.me = false;
                if (r.count == 0) {
                    std.mem.copyForwards(types.Reaction, m.reactions[i .. m.n_reactions - 1], m.reactions[i + 1 .. m.n_reactions]);
                    m.n_reactions -= 1;
                }
            }
            m.layout_w = -1;
            return;
        };
        if (!add or m.n_reactions >= m.reactions.len) return;
        var r = types.Reaction.init(emoji);
        r.count = 1;
        r.me = mine;
        m.reactions[m.n_reactions] = r;
        m.n_reactions += 1;
        m.layout_w = -1;
    }

    /// Edição local imediata (o servidor confirma depois).
    pub fn editLocal(s: *Store, channel_id: Id, id: Id, content: []const u8) !void {
        const owned = try ev_alloc.dupe(u8, content);
        try s.apply(.{ .message_update = .{ .channel = channel_id, .id = id, .content = owned } }, 0);
    }

    fn addMessage(s: *Store, m: types.Message, now_ms: i64) !void {
        const cs = s.channel(m.channel) orelse {
            ev_alloc.free(m.content);
            return;
        };
        // Quem mandou parou de digitar.
        for (cs.typing.items, 0..) |ty, i| if (ty.user == m.author) {
            _ = cs.typing.swapRemove(i);
            break;
        };
        _ = now_ms;
        // Confirmação de uma mensagem nossa: troca a cópia pendente.
        if (m.nonce != 0) {
            for (cs.messages.items) |*sm| if (sm.pending and sm.msg.nonce == m.nonce) {
                const spans = try markdown.parse(s.gpa, m.content);
                s.freeMessage(sm);
                sm.* = .{ .msg = m, .spans = spans };
                cs.version +%= 1;
                return;
            };
        }
        try cs.messages.append(s.gpa, .{ .msg = m, .spans = try markdown.parse(s.gpa, m.content) });
        if (m.author != s.me and m.channel != 0) cs.info.unread = true;
        s.trim(cs);
        cs.version +%= 1;
    }

    /// Mostra na hora uma mensagem que acabamos de enviar.
    pub fn addPending(s: *Store, channel_id: Id, content: []const u8, nonce: u64, reply_to: Id, now_ms: i64) !void {
        const cs = s.channel(channel_id) orelse return;
        const owned = try ev_alloc.dupe(u8, content);
        // As fatias dos trechos apontam para `owned`, que vira o conteúdo.
        try cs.messages.append(s.gpa, .{
            .msg = .{ .id = 0, .channel = channel_id, .author = s.me, .timestamp = @divTrunc(now_ms, 1000), .content = owned, .nonce = nonce, .reply_to = reply_to },
            .spans = try markdown.parse(s.gpa, owned),
            .pending = true,
        });
        s.trim(cs);
        cs.version +%= 1;
    }

    fn trim(s: *Store, cs: *ChannelState) void {
        if (cs.messages.items.len <= s.max_messages) return;
        const drop = cs.messages.items.len - s.max_messages;
        for (cs.messages.items[0..drop]) |*m| s.freeMessage(m);
        cs.messages.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    /// Remove indicadores de "digitando" vencidos. Retorna true se mudou algo.
    pub fn expireTyping(s: *Store, now_ms: i64) bool {
        var changed = false;
        var it = s.channels.valueIterator();
        while (it.next()) |cs| {
            var i: usize = 0;
            while (i < cs.*.typing.items.len) {
                if (cs.*.typing.items[i].until_ms <= now_ms) {
                    _ = cs.*.typing.swapRemove(i);
                    changed = true;
                } else i += 1;
            }
        }
        return changed;
    }

    pub fn markRead(s: *Store, channel_id: Id) void {
        if (s.channel(channel_id)) |cs| cs.info.unread = false;
    }
};

test "limite de mensagens por canal libera as antigas" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    s.max_messages = 3;

    const users = try c_alloc.alloc(types.User, 1);
    users[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const guilds = try c_alloc.alloc(types.Guild, 0);
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    const voice = try c_alloc.alloc([2]Id, 0);
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = voice } }, 0);

    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const content = try c_alloc.dupe(u8, "oi");
        try s.apply(.{ .message_create = .{ .id = 100 + i, .channel = 10, .author = 2, .timestamp = 0, .content = content } }, 0);
    }
    const cs = s.channel(10).?;
    try std.testing.expectEqual(@as(usize, 3), cs.messages.items.len);
    try std.testing.expectEqual(@as(Id, 102), cs.messages.items[0].msg.id);
}

test "mensagem pendente é confirmada pelo nonce" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    try s.addPending(10, "olá", 77, 0, 0);
    try std.testing.expect(s.channel(10).?.messages.items[0].pending);
    try s.apply(.{ .message_create = .{ .id = 5, .channel = 10, .author = 1, .timestamp = 0, .content = try c_alloc.dupe(u8, "olá"), .nonce = 77 } }, 0);
    const cs = s.channel(10).?;
    try std.testing.expectEqual(@as(usize, 1), cs.messages.items.len);
    try std.testing.expect(!cs.messages.items[0].pending);
}

test "reações, edição e exclusão" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{ .id = 7, .channel = 10, .author = 2, .timestamp = 0, .content = try c_alloc.dupe(u8, "oi") } }, 0);

    const r = types.Reaction.init("👍");
    try s.apply(.{ .reaction = .{ .channel = 10, .id = 7, .emoji = r, .user = 2, .add = true } }, 0);
    try s.apply(.{ .reaction = .{ .channel = 10, .id = 7, .emoji = r, .user = 1, .add = true } }, 0);
    const m = s.find(s.channel(10).?, 7).?;
    try std.testing.expectEqual(@as(u16, 2), m.reactions[0].count);
    try std.testing.expect(m.reactions[0].me);

    try s.editLocal(10, 7, "editado **agora**");
    try std.testing.expect(m.msg.edited);
    try std.testing.expectEqualStrings("editado **agora**", m.msg.content);

    try s.apply(.{ .message_delete = .{ .channel = 10, .id = 7 } }, 0);
    try std.testing.expectEqual(@as(usize, 0), s.channel(10).?.messages.items.len);
}
