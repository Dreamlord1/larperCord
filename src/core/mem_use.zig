//! Quanto os dados da conta ocupam, para a página de Desempenho. É uma estimativa:
//! soma os textos e as listas, sem contar o que o alocador gasta em volta de cada um.
const std = @import("std");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Id = types.Id;

pub const MemUse = struct {
    messages: usize = 0,
    n_messages: usize = 0,
    /// Pessoas, membros e o que se sabe delas.
    people: usize = 0,
    n_people: usize = 0,
    /// Servidores, canais, cargos e emojis.
    places: usize = 0,
    n_guilds: usize = 0,
    n_channels: usize = 0,
};

/// Soma o que `v` aponta (o próprio `v` já está na conta de quem o guarda).
fn deep(v: anytype) usize {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return 0;
            var n = v.len * @sizeOf(p.child);
            if (comptime hasSlices(p.child)) for (v) |x| {
                n += deep(x);
            };
            return n;
        },
        .optional => return if (v) |x| deep(x) else 0,
        .@"struct" => |s| {
            var n: usize = 0;
            inline for (s.field_names) |name| n += deep(@field(v, name));
            return n;
        },
        else => return 0,
    }
}

fn hasSlices(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        .optional => |o| hasSlices(o.child),
        .@"struct" => |s| for (s.field_types) |f| {
            if (hasSlices(f)) break true;
        } else false,
        else => false,
    };
}

fn mapBytes(m: anytype, comptime K: type, comptime V: type) usize {
    return m.capacity() * (@sizeOf(K) + @sizeOf(V) + 1);
}

/// Varre a conta inteira: a página pede de vez em quando, nunca a cada quadro.
pub fn of(s: *const Store) MemUse {
    const Span = @import("markdown.zig").Span;
    var u: MemUse = .{};

    var it = s.channels.valueIterator();
    while (it.next()) |p| {
        const cs = p.*;
        u.n_channels += 1;
        u.places += @sizeOf(store_mod.ChannelState) + deep(cs.info);
        u.messages += cs.messages.capacity * @sizeOf(store_mod.StoredMessage);
        u.n_messages += cs.messages.items.len;
        for (cs.messages.items) |*m| {
            u.messages += deep(m.msg);
            // Os textos das partes são fatias do conteúdo, que já foi contado.
            u.messages += m.spans.len * @sizeOf(Span);
            u.messages += m.embed_spans.len * @sizeOf([]const Span);
            for (m.embed_spans) |sp| u.messages += sp.len * @sizeOf(Span);
            if (m.original) |o| u.messages += o.len;
        }
    }
    u.places += mapBytes(s.channels, Id, *store_mod.ChannelState);
    u.places += s.guilds.capacity * @sizeOf(types.Guild);
    u.n_guilds = s.guilds.items.len;
    for (s.guilds.items) |g| u.places += deep(g);
    u.places += mapBytes(s.roles, Id, types.Role);
    var roles = s.roles.valueIterator();
    while (roles.next()) |r| u.places += deep(r.*);
    u.places += mapBytes(s.emoji_by_id, Id, types.Emoji);
    var emojis = s.guild_emojis.valueIterator();
    while (emojis.next()) |list| u.places += deep(list.*);

    u.n_people = s.users.count();
    u.people += mapBytes(s.users, Id, types.User);
    var users = s.users.valueIterator();
    while (users.next()) |x| u.people += deep(x.*);
    u.people += mapBytes(s.members, [2]Id, types.MemberInfo);
    var lists = s.member_lists.valueIterator();
    while (lists.next()) |l| u.people += l.items.capacity * @sizeOf(types.MemberItem);
    var acts = s.activities.valueIterator();
    while (acts.next()) |a| u.people += deep(a.*);
    var profiles = s.profiles.valueIterator();
    while (profiles.next()) |x| u.people += deep(x.*);
    var notes = s.notes.valueIterator();
    while (notes.next()) |n| u.people += n.len;
    return u;
}

test "conta as mensagens, as pessoas e os canais" {
    const c_alloc = std.heap.c_allocator;
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), of(&s).n_messages);

    const users = try c_alloc.alloc(types.User, 1);
    users[0] = .{ .id = 1, .name = try c_alloc.dupe(u8, "alguem") };
    const guilds = try c_alloc.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try c_alloc.dupe(u8, "servidor"), .acronym = try c_alloc.dupe(u8, "S") };
    const chans = try c_alloc.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = try c_alloc.dupe(u8, "") };
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = try c_alloc.alloc([2]Id, 0) } }, 0);

    const before = of(&s);
    try std.testing.expectEqual(@as(usize, 1), before.n_people);
    try std.testing.expectEqual(@as(usize, 1), before.n_guilds);
    try std.testing.expectEqual(@as(usize, 1), before.n_channels);
    try std.testing.expect(before.people >= "alguem".len);
    try std.testing.expect(before.places >= "servidor".len + "geral".len);

    const texto: [4000]u8 = @splat('x');
    try s.apply(.{ .message_create = .{ .id = 100, .channel = 10, .author = 1, .timestamp = 0, .content = try c_alloc.dupe(u8, &texto) } }, 0);
    const after = of(&s);
    try std.testing.expectEqual(@as(usize, 1), after.n_messages);
    try std.testing.expect(after.messages >= before.messages + texto.len);
}
