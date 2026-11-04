//! O JSON do Discord para o estado de leitura: `read_state` e
//! `user_guild_settings` do READY (com ou sem o formato versionado `{entries}`),
//! o `joined_at` e o MESSAGE_ACK. Separado do gateway para dar para testar sem
//! conexão, com o formato que o Discord manda.
const std = @import("std");
const types = @import("../core/types.zig");
const j = @import("jsonx.zig");
const Value = std.json.Value;
const Id = types.Id;

/// `last_message_id` às vezes vem como o número 0 em vez de string.
fn idOr0(v: ?Value) Id {
    return j.id(v) orelse 0;
}

/// Registros de leitura dos canais (tipo 0: os outros são de outras coisas,
/// como eventos do servidor). A lista é alocada com `gpa`.
pub fn entries(gpa: std.mem.Allocator, rs: Value) ![]types.ReadEntry {
    var list: std.ArrayList(types.ReadEntry) = .empty;
    errdefer list.deinit(gpa);
    const items = if (rs == .array) j.array(rs) else j.array(j.get(rs, "entries"));
    try list.ensureTotalCapacity(gpa, items.len);
    for (items) |e| {
        if ((j.int(j.get(e, "read_state_type")) orelse 0) != 0) continue;
        list.appendAssumeCapacity(.{
            .channel = j.id(j.get(e, "id")) orelse continue,
            .last_read = idOr0(j.get(e, "last_message_id")),
            .mentions = @intCast(std.math.clamp(j.int(j.get(e, "mention_count")) orelse 0, 0, 65535)),
        });
    }
    return list.toOwnedSlice(gpa);
}

/// Silenciado agora: `muted`, e o prazo (se tem) ainda não venceu.
fn isMuted(v: Value, now_ms: i64) bool {
    const m = j.get(v, "muted") orelse return false;
    if (m != .bool or !m.bool) return false;
    const cfg = j.get(v, "mute_config") orelse return true;
    const end = j.str(j.get(cfg, "end_time")) orelse return true;
    return j.isoTime(end) * 1000 > now_ms;
}

/// Servidores e canais (ou categorias) silenciados no Discord.
pub fn muted(gpa: std.mem.Allocator, ugs: Value, now_ms: i64) ![]Id {
    var out: std.ArrayList(Id) = .empty;
    errdefer out.deinit(gpa);
    for (if (ugs == .array) j.array(ugs) else j.array(j.get(ugs, "entries"))) |e| {
        // Sem `guild_id` são as mensagens diretas, sem um canal para silenciar.
        if (isMuted(e, now_ms)) if (j.id(j.get(e, "guild_id"))) |gid| try out.append(gpa, gid);
        for (j.array(j.get(e, "channel_overrides"))) |o| {
            if (isMuted(o, now_ms)) if (j.id(j.get(o, "channel_id"))) |ch| try out.append(gpa, ch);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Quando entramos no servidor, como snowflake (0 = não veio).
pub fn joinedId(v: Value) Id {
    const t = j.str(j.get(v, "joined_at")) orelse return 0;
    const secs = j.isoTime(t);
    return if (secs > 0) types.makeSnowflake(secs * 1000, 0) else 0;
}

pub const Ack = struct { channel: Id, message: Id, mentions: ?u16, manual: bool };

/// MESSAGE_ACK. `message_id` pode faltar (lido até o fim); `manual` só existe
/// em "marcar como não lida".
pub fn ack(d: Value) ?Ack {
    return .{
        .channel = j.id(j.get(d, "channel_id")) orelse return null,
        .message = idOr0(j.get(d, "message_id")),
        .mentions = if (j.int(j.get(d, "mention_count"))) |n| @intCast(std.math.clamp(n, 0, 65535)) else null,
        .manual = if (j.get(d, "manual")) |m| m == .bool and m.bool else false,
    };
}

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "read_state versionado, formato antigo, tipos e números" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const list = try entries(ar, try parse(ar,
        \\{"version":12,"partial":false,"entries":[
        \\ {"id":"10","last_message_id":"100","mention_count":3,"last_pin_timestamp":null,"last_viewed":4000,"flags":0},
        \\ {"id":"11","last_message_id":0,"read_state_type":0},
        \\ {"id":"12","last_acked_id":"5","read_state_type":1,"badge_count":2},
        \\ {"last_message_id":"9"}
        \\]}
    ));
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(Id, 10), list[0].channel);
    try std.testing.expectEqual(@as(Id, 100), list[0].last_read);
    try std.testing.expectEqual(@as(u16, 3), list[0].mentions);
    try std.testing.expectEqual(@as(Id, 0), list[1].last_read);
    const old = try entries(ar, try parse(ar,
        \\[{"id":"7","last_message_id":"8","mention_count":1}]
    ));
    try std.testing.expectEqual(@as(Id, 7), old[0].channel);
}

test "silenciados: servidor, canal e prazo vencido" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const list = try muted(ar, try parse(ar,
        \\{"version":3,"partial":false,"entries":[
        \\ {"guild_id":"1","muted":true,"mute_config":null,"channel_overrides":[]},
        \\ {"guild_id":"2","muted":true,"mute_config":{"end_time":"2020-01-01T00:00:00+00:00","selected_time_window":3600}},
        \\ {"guild_id":"3","muted":false,"channel_overrides":[{"channel_id":"30","muted":true,"mute_config":null},{"channel_id":"31","muted":false}]},
        \\ {"guild_id":null,"muted":true,"channel_overrides":[{"channel_id":"40","muted":true}]}
        \\]}
    ), 1_700_000_000_000);
    try std.testing.expectEqualSlices(Id, &.{ 1, 30, 40 }, list);
}

test "joined_at e MESSAGE_ACK" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const id = joinedId(try parse(ar,
        \\{"joined_at":"2020-01-01T00:00:00.000000+00:00"}
    ));
    try std.testing.expectEqual(@as(i64, 1577836800000), types.snowflakeTime(id));
    try std.testing.expectEqual(@as(Id, 0), joinedId(try parse(ar, "{}")));
    const m = ack(try parse(ar,
        \\{"channel_id":"5","message_id":"6","version":9,"manual":true,"mention_count":2}
    )).?;
    try std.testing.expectEqual(@as(Id, 6), m.message);
    try std.testing.expect(m.manual);
    try std.testing.expectEqual(@as(?u16, 2), m.mentions);
    const n = ack(try parse(ar,
        \\{"channel_id":"5","message_id":"6","version":9}
    )).?;
    try std.testing.expect(!n.manual);
    try std.testing.expectEqual(@as(?u16, null), n.mentions);
    try std.testing.expect(ack(try parse(ar, "{}")) == null);
}
