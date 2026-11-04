//! Threads e fóruns no JSON do Discord (sem rede, para dar para testar).
const std = @import("std");
const types = @import("../core/types.zig");
const j = @import("jsonx.zig");
const Id = types.Id;
const Value = std.json.Value;

const alloc = std.heap.c_allocator;

/// O que só uma thread tem (null nos outros tipos de canal). Sem `member`, não
/// sabemos se estamos nela: THREAD_UPDATE não repete.
pub fn threadInfo(cv: Value, kind_i: i64) ?types.ThreadInfo {
    if (kind_i < 10 or kind_i > 12) return null;
    const flag = struct {
        fn f(v: ?Value, key: []const u8) bool {
            const o = v orelse return false;
            const b = j.get(o, key) orelse return false;
            return b == .bool and b.bool;
        }
    }.f;
    const meta = j.get(cv, "thread_metadata");
    var tags: std.ArrayList(Id) = .empty;
    for (j.array(j.get(cv, "applied_tags"))) |v| if (j.id(v)) |x| tags.append(alloc, x) catch {};
    const member = j.get(cv, "member");
    return .{
        .owner = j.id(j.get(cv, "owner_id")) orelse 0,
        .archived = flag(meta, "archived"),
        .locked = flag(meta, "locked"),
        .private = kind_i == 12,
        .joined = member != null and member.? != .null,
        .joined_known = member != null,
        .message_count = @intCast(std.math.clamp(j.int(j.get(cv, "message_count")) orelse 0, 0, std.math.maxInt(u32))),
        .member_count = @intCast(std.math.clamp(j.int(j.get(cv, "member_count")) orelse 0, 0, std.math.maxInt(u32))),
        .last_message = j.id(j.get(cv, "last_message_id")) orelse 0,
        .archive_ts = if (meta) |m| j.isoTime(j.str(j.get(m, "archive_timestamp")) orelse "") else 0,
        .tags = tags.toOwnedSlice(alloc) catch &.{},
    };
}

/// Tags que um fórum oferece (quem recebe fica com a lista e os textos).
pub fn forumTags(cv: Value) []const types.ForumTag {
    var out: std.ArrayList(types.ForumTag) = .empty;
    for (j.array(j.get(cv, "available_tags"))) |tv| {
        const id = j.id(j.get(tv, "id")) orelse continue;
        const name = alloc.dupe(u8, j.str(j.get(tv, "name")) orelse continue) catch continue;
        const emoji = j.str(j.get(tv, "emoji_name")) orelse "";
        const mod = if (j.get(tv, "moderated")) |m| m == .bool and m.bool else false;
        out.append(alloc, .{ .id = id, .name = name, .emoji = if (emoji.len > 0) alloc.dupe(u8, emoji) catch "" else "", .moderated = mod }) catch alloc.free(name);
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

/// Flag REQUIRE_TAG do canal: post novo precisa de ao menos uma tag.
pub fn requiresTag(cv: Value) bool {
    return (j.int(j.get(cv, "flags")) orelse 0) & (1 << 4) != 0;
}

/// `before` de /threads/archived: o instante em ISO8601.
pub fn isoFromUnix(buf: []u8, secs: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
}

test "thread: o que vem do Discord" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"id":"7","type":11,"owner_id":"3","message_count":4,"member_count":2,"last_message_id":"99","applied_tags":["5","6"],
        \\"thread_metadata":{"archived":true,"locked":true,"archive_timestamp":"2026-11-02T23:21:12.345000+00:00"},"member":{"id":"7"}}
    , .{});
    const t = threadInfo(v, 11).?;
    defer alloc.free(t.tags);
    try std.testing.expect(t.archived and t.locked and t.joined and t.joined_known and !t.private);
    try std.testing.expectEqual(@as(u32, 4), t.message_count);
    try std.testing.expectEqual(@as(Id, 99), t.last_message);
    try std.testing.expectEqual(@as(usize, 2), t.tags.len);
    try std.testing.expectEqual(@as(i64, 1793661672), t.archive_ts);
    const u = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"id\":\"8\",\"type\":12}", .{});
    const t2 = threadInfo(u, 12).?;
    try std.testing.expect(!t2.joined_known and t2.private);
    try std.testing.expect(threadInfo(u, 0) == null);
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-02T23:21:12Z", isoFromUnix(&b, 1793661672));
}

test "fórum: tags oferecidas e tag obrigatória" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"flags":16,"available_tags":[{"id":"1","name":"Bug","emoji_name":"🐛","moderated":true},{"id":"2","name":"Dúvida","emoji_id":"9","emoji_name":null}]}
    , .{});
    const tags = forumTags(v);
    defer {
        for (tags) |t| {
            alloc.free(t.name);
            if (t.emoji.len > 0) alloc.free(t.emoji);
        }
        alloc.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expect(tags[0].moderated and tags[0].emoji.len > 0);
    try std.testing.expectEqualStrings("Dúvida", tags[1].name);
    try std.testing.expect(requiresTag(v));
}
