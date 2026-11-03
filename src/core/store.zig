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

/// Lista de membros de um servidor, no formato do Discord: posições fixas
/// (a faixa 0..99 que pedimos), com cabeçalhos de grupo no meio.
pub const MemberList = struct {
    list_id: u64 = 0,
    online: u32 = 0,
    total: u32 = 0,
    items: std.ArrayList(types.MemberItem) = .empty,
    /// Já chegou o primeiro SYNC (antes disso, "carregando").
    synced: bool = false,
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
    /// Da nossa conta (Configurações → Minha conta).
    me_username: ?[]const u8 = null,
    me_email: ?[]const u8 = null,
    users: std.AutoHashMapUnmanaged(Id, types.User) = .empty,
    guilds: std.ArrayList(types.Guild) = .empty,
    channels: std.AutoHashMapUnmanaged(Id, *ChannelState) = .empty,
    /// Canais de cada servidor, na ordem de exibição (categorias incluídas).
    guild_channels: std.AutoHashMapUnmanaged(Id, std.ArrayList(Id)) = .empty,
    /// Cargos de todos os servidores (o ID do cargo é único no Discord).
    roles: std.AutoHashMapUnmanaged(Id, types.Role) = .empty,
    member_lists: std.AutoHashMapUnmanaged(Id, MemberList) = .empty,
    /// (servidor, usuário) -> cor do nome e cargos.
    members: std.AutoHashMapUnmanaged([2]Id, types.MemberInfo) = .empty,
    relationships: std.AutoHashMapUnmanaged(Id, types.Relationship) = .empty,

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
            freeChannelInfo(&cs.*.info);
            s.gpa.destroy(cs.*);
        }
        s.channels.deinit(s.gpa);
        var ri = s.roles.valueIterator();
        while (ri.next()) |r| ev_alloc.free(r.name);
        s.roles.deinit(s.gpa);
        var mi = s.member_lists.valueIterator();
        while (mi.next()) |ml| ml.items.deinit(s.gpa);
        s.member_lists.deinit(s.gpa);
        s.members.deinit(s.gpa);
        s.relationships.deinit(s.gpa);
        var gc = s.guild_channels.valueIterator();
        while (gc.next()) |l| l.deinit(s.gpa);
        s.guild_channels.deinit(s.gpa);
        for (s.guilds.items) |g| freeGuildInfo(g);
        s.guilds.deinit(s.gpa);
        var ui = s.users.valueIterator();
        while (ui.next()) |u| freeUser(u.*);
        s.users.deinit(s.gpa);
        if (s.me_username) |x| ev_alloc.free(x);
        if (s.me_email) |x| ev_alloc.free(x);
    }

    fn freeUser(u: types.User) void {
        ev_alloc.free(u.name);
        if (u.activity) |a| ev_alloc.free(a);
        if (u.avatar) |a| ev_alloc.free(a);
    }

    fn freeGuildInfo(g: types.Guild) void {
        ev_alloc.free(g.name);
        ev_alloc.free(g.acronym);
        if (g.icon) |i| ev_alloc.free(i);
    }

    fn freeChannelInfo(ch: *const types.Channel) void {
        ev_alloc.free(ch.name);
        ev_alloc.free(ch.topic);
        if (ch.recipients.len > 0) ev_alloc.free(ch.recipients);
        if (ch.icon) |i| ev_alloc.free(i);
    }

    /// Troca o avatar guardado se o novo for diferente (fica com `fresh`
    /// ou o libera).
    fn takeAvatar(old: *types.User, fresh: ?[]const u8) void {
        const f = fresh orelse return;
        if (old.avatar) |a| {
            if (std.mem.eql(u8, a, f)) return ev_alloc.free(f);
            ev_alloc.free(a);
        }
        old.avatar = f;
    }

    fn freeMessage(s: *Store, m: *StoredMessage) void {
        ev_alloc.free(m.msg.content);
        types.freeAttachments(ev_alloc, m.msg.attachments);
        s.gpa.free(m.spans);
    }

    /// READY pode chegar mais de uma vez (sessão nova depois de uma queda).
    /// Funde por ID em vez de duplicar servidores, canais e usuários.
    fn mergeUser(s: *Store, u: types.User) !void {
        if (s.users.getPtr(u.id)) |old| {
            ev_alloc.free(u.name);
            if (u.activity) |a| ev_alloc.free(a);
            takeAvatar(old, u.avatar);
            if (old.status == .offline and u.status != .offline) old.status = u.status;
            return;
        }
        try s.users.put(s.gpa, u.id, u);
    }

    /// Substitui um usuário existente (nome/atividade novos), preservando o
    /// status e a atividade que o evento de update não carrega.
    fn putUser(s: *Store, u: types.User) !void {
        if (s.users.getPtr(u.id)) |old| {
            const old_status = old.status;
            const old_activity = old.activity;
            const old_avatar = old.avatar;
            ev_alloc.free(old.name);
            old.* = u;
            old.avatar = old_avatar;
            takeAvatar(old, u.avatar);
            if (u.status == .offline) old.status = old_status;
            if (u.activity == null) {
                old.activity = old_activity;
            } else if (old_activity) |a| {
                ev_alloc.free(a);
            }
            return;
        }
        try s.users.put(s.gpa, u.id, u);
    }

    fn mergeGuild(s: *Store, g: types.Guild) !void {
        for (s.guilds.items) |*old| {
            if (old.id != g.id) continue;
            ev_alloc.free(old.name);
            ev_alloc.free(old.acronym);
            if (old.icon) |i| ev_alloc.free(i);
            old.name = g.name;
            old.acronym = g.acronym;
            old.color = g.color;
            old.icon = g.icon;
            return;
        }
        try s.guilds.append(s.gpa, g);
    }

    fn mergeChannel(s: *Store, ch: types.Channel) !void {
        if (s.channels.get(ch.id)) |cs| {
            const unread = cs.info.unread or ch.unread;
            freeChannelInfo(&cs.info);
            cs.info = ch;
            cs.info.unread = unread;
        } else {
            const cs = try s.gpa.create(ChannelState);
            cs.* = .{ .info = ch };
            try s.channels.put(s.gpa, ch.id, cs);
        }
        const gop = try s.guild_channels.getOrPut(s.gpa, ch.guild);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (std.mem.indexOfScalar(Id, gop.value_ptr.items, ch.id) == null) {
            try gop.value_ptr.append(s.gpa, ch.id);
        }
    }

    fn removeChannel(s: *Store, id: Id) void {
        const kv = s.channels.fetchRemove(id) orelse return;
        const cs = kv.value;
        for (cs.messages.items) |*m| s.freeMessage(m);
        cs.messages.deinit(s.gpa);
        cs.typing.deinit(s.gpa);
        cs.voice_members.deinit(s.gpa);
        freeChannelInfo(&cs.info);
        s.gpa.destroy(cs);
        var it = s.guild_channels.valueIterator();
        while (it.next()) |list| {
            if (std.mem.indexOfScalar(Id, list.items, id)) |i| _ = list.orderedRemove(i);
        }
    }

    fn removeGuild(s: *Store, id: Id) void {
        if (s.guild_channels.fetchRemove(id)) |kv| {
            var list = kv.value;
            for (list.items) |ch| s.removeChannel(ch);
            list.deinit(s.gpa);
        }
        for (s.guilds.items, 0..) |g, i| {
            if (g.id != id) continue;
            freeGuildInfo(g);
            _ = s.guilds.orderedRemove(i);
            if (s.member_lists.fetchRemove(id)) |kv| {
                var ml = kv.value;
                ml.items.deinit(s.gpa);
            }
            return;
        }
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
                if (r.username) |x| {
                    if (s.me_username) |old| ev_alloc.free(old);
                    s.me_username = x;
                }
                if (r.email) |x| {
                    if (s.me_email) |old| ev_alloc.free(old);
                    s.me_email = x;
                }
                for (r.users) |u| try s.mergeUser(u);
                for (r.guilds) |g| try s.mergeGuild(g);
                for (r.channels) |ch| try s.mergeChannel(ch);
                // READY é o retrato atual da conta: refaz os estados de voz
                // em vez de empilhar em cima do que sobrou da sessão anterior.
                var vit = s.channels.valueIterator();
                while (vit.next()) |cs| cs.*.voice_members.clearRetainingCapacity();
                for (r.voice) |pair| {
                    if (s.channel(pair[0])) |cs| {
                        if (std.mem.indexOfScalar(Id, cs.voice_members.items, pair[1]) == null) {
                            try cs.voice_members.append(s.gpa, pair[1]);
                        }
                    }
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
                    for (h.messages) |m| {
                        ev_alloc.free(m.content);
                        types.freeAttachments(ev_alloc, m.attachments);
                    }
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
            .presence_update => |p| {
                if (s.users.getPtr(p.user)) |u| {
                    u.status = p.status;
                    if (p.activity) |a| {
                        if (u.activity) |old| ev_alloc.free(old);
                        u.activity = if (a.len == 0) null else a;
                    }
                } else if (p.activity) |a| {
                    // Usuário desconhecido: o texto veio alocado, não vaza.
                    if (a.len > 0) ev_alloc.free(@constCast(a));
                }
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
                if (s.users.getPtr(u.id)) |old| {
                    ev_alloc.free(u.name);
                    if (u.activity) |a| ev_alloc.free(a);
                    takeAvatar(old, u.avatar);
                    return;
                }
                try s.users.put(s.gpa, u.id, u);
            },
            .user_update => |u| try s.putUser(u),
            .guild_create => |gc| {
                defer {
                    ev_alloc.free(gc.channels);
                    ev_alloc.free(gc.voice);
                }
                try s.mergeGuild(gc.guild);
                for (gc.channels) |ch| try s.mergeChannel(ch);
                for (gc.channels) |ch| {
                    if (s.channel(ch.id)) |cs| cs.voice_members.clearRetainingCapacity();
                }
                for (gc.voice) |pair| {
                    if (s.channel(pair[0])) |cs| {
                        if (std.mem.indexOfScalar(Id, cs.voice_members.items, pair[1]) == null) {
                            try cs.voice_members.append(s.gpa, pair[1]);
                        }
                    }
                }
            },
            .guild_delete => |id| s.removeGuild(id),
            .channel_upsert => |ch| try s.mergeChannel(ch),
            .channel_delete => |id| s.removeChannel(id),
            .read => |id| s.markRead(id),
            .reaction_clear => |rc| {
                const cs = s.channel(rc.channel) orelse return;
                const m = s.find(cs, rc.id) orelse return;
                if (rc.emoji) |e| {
                    for (m.reactions[0..m.n_reactions], 0..) |*r, i| {
                        if (!std.mem.eql(u8, r.text(), e.text())) continue;
                        std.mem.copyForwards(types.Reaction, m.reactions[i .. m.n_reactions - 1], m.reactions[i + 1 .. m.n_reactions]);
                        m.n_reactions -= 1;
                        break;
                    }
                } else {
                    m.n_reactions = 0;
                }
                m.layout_w = -1;
                cs.version +%= 1;
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
            .roles => |rs| {
                defer ev_alloc.free(rs.roles);
                for (rs.roles) |r| {
                    const gop = try s.roles.getOrPut(s.gpa, r.id);
                    if (gop.found_existing) ev_alloc.free(gop.value_ptr.name);
                    gop.value_ptr.* = r;
                }
            },
            .member_list => |ml| {
                defer {
                    for (ml.ops) |op| if (op.items.len > 0) ev_alloc.free(op.items);
                    ev_alloc.free(ml.ops);
                    if (ml.counts.len > 0) ev_alloc.free(ml.counts);
                }
                try s.applyMemberList(ml.guild, ml.list_id, ml.online, ml.total, ml.ops);
                // Quantos em cada grupo (os cabeçalhos "CARGO — N").
                if (s.member_lists.getPtr(ml.guild)) |list| for (list.items.items) |*it| if (it.* == .group) {
                    for (ml.counts) |gc| if (gc[0] == it.group.id) {
                        it.group.count = @intCast(@min(gc[1], std.math.maxInt(u32)));
                    };
                };
            },
            .member_info => |mi| try s.members.put(s.gpa, .{ mi.guild, mi.user }, mi.info),
            .relationship => |r| {
                if (r.kind == .none) {
                    _ = s.relationships.remove(r.user);
                } else try s.relationships.put(s.gpa, r.user, r.kind);
            },
        }
    }

    fn applyMemberList(s: *Store, guild_id: Id, list_id: u64, online: u32, total: u32, ops: []const types.MemberOp) !void {
        const gop = try s.member_lists.getOrPut(s.gpa, guild_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const ml = gop.value_ptr;
        // Lista de outro canal: só um SYNC novo vale (o resto é de antes).
        if (ml.list_id != list_id) {
            var has_sync = false;
            for (ops) |op| if (op.kind == .sync) {
                has_sync = true;
            };
            if (!has_sync and ml.synced) return;
            ml.items.clearRetainingCapacity();
            ml.list_id = list_id;
        }
        ml.online = online;
        ml.total = total;
        const items = &ml.items;
        for (ops) |op| switch (op.kind) {
            .sync => {
                const end: usize = @as(usize, op.index) + op.items.len;
                if (items.items.len < end) try items.appendNTimes(s.gpa, .none, end - items.items.len);
                @memcpy(items.items[op.index..end], op.items);
                ml.synced = true;
            },
            .invalidate => {
                const end = @min(items.items.len, @as(usize, op.end) + 1);
                if (op.index < end) @memset(items.items[op.index..end], .none);
            },
            .insert => if (op.items.len > 0) {
                if (op.index >= items.items.len) {
                    try items.appendNTimes(s.gpa, .none, op.index - items.items.len);
                    try items.append(s.gpa, op.items[0]);
                } else try items.insert(s.gpa, op.index, op.items[0]);
            },
            .update => if (op.items.len > 0 and op.index < items.items.len) {
                items.items[op.index] = op.items[0];
            },
            .delete => if (op.index < items.items.len) {
                _ = items.orderedRemove(op.index);
            },
        };
        // Guarda cor e cargos de quem apareceu (nome nas mensagens, perfil).
        for (items.items) |it| if (it == .member)
            try s.members.put(s.gpa, .{ guild_id, it.member.user }, it.member.info);
    }

    pub fn memberList(s: *const Store, guild_id: Id) ?*MemberList {
        return s.member_lists.getPtr(guild_id);
    }

    /// Cor do nome de alguém num servidor (0 = sem cor de cargo).
    pub fn nameColor(s: *const Store, guild_id: Id, user_id: Id) u32 {
        return if (s.memberInfo(guild_id, user_id)) |m| m.color else 0;
    }

    pub fn memberInfo(s: *const Store, guild_id: Id, user_id: Id) ?types.MemberInfo {
        if (guild_id == 0) return null;
        return s.members.get(.{ guild_id, user_id });
    }

    pub fn relationship(s: *const Store, user_id: Id) types.Relationship {
        return s.relationships.get(user_id) orelse .none;
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
            types.freeAttachments(ev_alloc, m.attachments);
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
                var msg = m;
                // Sem anexos na confirmação (demonstração): fica com os locais.
                if (msg.attachments.len == 0) {
                    msg.attachments = sm.msg.attachments;
                    sm.msg.attachments = &.{};
                }
                s.freeMessage(sm);
                sm.* = .{ .msg = msg, .spans = spans };
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
    /// `attachments` passa a pertencer ao Store (alocado com o c_allocator).
    pub fn addPending(s: *Store, channel_id: Id, content: []const u8, nonce: u64, reply_to: Id, now_ms: i64, attachments: []const types.Attachment) !void {
        const cs = s.channel(channel_id) orelse return types.freeAttachments(ev_alloc, attachments);
        const owned = try ev_alloc.dupe(u8, content);
        // As fatias dos trechos apontam para `owned`, que vira o conteúdo.
        try cs.messages.append(s.gpa, .{
            .msg = .{ .id = 0, .channel = channel_id, .author = s.me, .timestamp = @divTrunc(now_ms, 1000), .content = owned, .nonce = nonce, .reply_to = reply_to, .attachments = attachments },
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

test "READY repetido funde estado e CHANNEL/GUILD_DELETE limpam" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();

    const us1 = try c_alloc.alloc(types.User, 1);
    us1[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const g1 = try c_alloc.alloc(types.Guild, 1);
    g1[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "g"), .acronym = try c_alloc.dupe(u8, "G") };
    const c1 = try c_alloc.alloc(types.Channel, 1);
    c1[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = us1, .guilds = g1, .channels = c1, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{
        .id = 100,
        .channel = 10,
        .author = 2,
        .timestamp = 0,
        .content = try c_alloc.dupe(u8, "oi"),
    } }, 0);

    // Uma segunda sessão manda o mesmo servidor/canal + um canal novo.
    const us2 = try c_alloc.alloc(types.User, 1);
    us2[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    const g2 = try c_alloc.alloc(types.Guild, 1);
    g2[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "g"), .acronym = try c_alloc.dupe(u8, "G") };
    const c2 = try c_alloc.alloc(types.Channel, 2);
    c2[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    c2[1] = .{ .id = 11, .guild = 5, .name = try c_alloc.dupe(u8, "novo"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = us2, .guilds = g2, .channels = c2, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    try std.testing.expectEqual(@as(usize, 1), s.guilds.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.channelsOf(5).len);
    try std.testing.expectEqual(@as(usize, 1), s.channel(10).?.messages.items.len);

    try s.apply(.{ .channel_delete = 11 }, 0);
    try std.testing.expect(s.channel(11) == null);
    try std.testing.expectEqual(@as(usize, 1), s.channelsOf(5).len);

    try s.apply(.{ .guild_delete = 5 }, 0);
    try std.testing.expect(s.channel(10) == null);
    try std.testing.expectEqual(@as(usize, 0), s.guilds.items.len);
}

test "presença, atividade e troca de nome não vazam" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();

    const us = try c_alloc.alloc(types.User, 1);
    us[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "eu") };
    try s.apply(.{ .ready = .{
        .me = 1,
        .users = us,
        .guilds = try c_alloc.alloc(types.Guild, 0),
        .channels = try c_alloc.alloc(types.Channel, 0),
        .voice = try c_alloc.alloc([2]Id, 0),
    } }, 0);

    try s.apply(.{ .presence_update = .{
        .user = 1,
        .status = .online,
        .activity = try c_alloc.dupe(u8, "Jogando X"),
    } }, 0);
    try std.testing.expectEqualStrings("Jogando X", s.user(1).?.activity.?);

    try s.apply(.{ .presence_update = .{ .user = 1, .status = .idle, .activity = "" } }, 0);
    try std.testing.expect(s.user(1).?.activity == null);

    try s.apply(.{ .user_update = .{
        .id = 1,
        .name = try c_alloc.dupe(u8, "novo"),
        .role = 2,
        .status = .offline,
    } }, 0);
    try std.testing.expectEqualStrings("novo", s.user(1).?.name);
    try std.testing.expectEqual(types.Status.idle, s.user(1).?.status);
}

test "mensagem pendente é confirmada pelo nonce" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "g"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = try c_alloc.alloc(types.User, 0), .guilds = try c_alloc.alloc(types.Guild, 0), .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    try s.addPending(10, "olá", 77, 0, 0, &.{});
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
