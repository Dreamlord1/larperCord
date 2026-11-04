//! Ajudantes para ler o JSON do Discord (std.json.Value) e montar respostas.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

pub fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| std.math.lossyCast(i64, f),
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Snowflakes vêm como string ("1234…").
pub fn id(v: ?Value) ?u64 {
    const s = str(v) orelse return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

pub fn array(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return switch (x) {
        .array => |a| a.items,
        else => &.{},
    };
}

pub fn isNull(v: ?Value) bool {
    const x = v orelse return true;
    return x == .null;
}

/// "2026-11-02T23:41:12.345000+00:00" -> segundos desde 1970 (UTC).
pub fn isoTime(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const p = struct {
        fn n(t: []const u8) i64 {
            return std.fmt.parseInt(i64, t, 10) catch 0;
        }
    }.n;
    var y = p(s[0..4]);
    const m = p(s[5..7]);
    const d = p(s[8..10]);
    const secs = p(s[11..13]) * 3600 + p(s[14..16]) * 60 + p(s[17..19]);
    // Dias desde 1970 (algoritmo "days from civil").
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    var t = (era * 146097 + doe - 719468) * 86400 + secs;
    // Fuso no fim ("+00:00"); o Discord sempre manda UTC, mas por garantia:
    if (s.len >= 25) {
        const tz = s[s.len - 6 ..];
        if ((tz[0] == '+' or tz[0] == '-') and tz[3] == ':') {
            const off = p(tz[1..3]) * 3600 + p(tz[4..6]) * 60;
            t += if (tz[0] == '+') -off else off;
        }
    }
    return t;
}

/// Escreve `s` como string JSON (com aspas).
pub fn writeString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...0x1f => try out.print(gpa, "\\u{x:0>4}", .{ch}),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

/// Fim de um emoji personalizado que começa em `s[i]` (`<:nome:123>` ou
/// `<a:nome:123>`): o índice do '>' e onde o nome está. Só nomes e números
/// válidos: `Vec<a::B>` é texto.
fn customEmoji(s: []const u8, i: usize) ?struct { name: []const u8, close: usize } {
    var k = i + 1;
    if (k < s.len and s[k] == 'a') k += 1;
    if (k >= s.len or s[k] != ':') return null;
    k += 1;
    const start = k;
    while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_')) k += 1;
    if (k == start or k >= s.len or s[k] != ':') return null;
    const name = s[start..k];
    k += 1;
    const digits = k;
    while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
    if (k == digits or k >= s.len or s[k] != '>') return null;
    return .{ .name = name, .close = k };
}

/// Emoji personalizado `<:nome:123>` / `<a:nome:123>` vira `:nome:`.
pub fn simplifyContent(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') if (customEmoji(s, i)) |e| {
            out.appendAssumeCapacity(':');
            out.appendSliceAssumeCapacity(e.name);
            out.appendAssumeCapacity(':');
            i = e.close + 1;
            continue;
        };
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Codifica um emoji para a URL de reações (percent-encoding dos bytes).
pub fn urlEncode(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) break;
            _ = std.fmt.bufPrint(buf[n..], "%{X:0>2}", .{ch}) catch break;
            n += 3;
        }
    }
    return buf[0..n];
}

/// O emoji como vai no caminho das reações: `nome:id` (personalizado) ou o
/// emoji Unicode codificado. Sobra `buf` de 128 bytes para qualquer um.
pub fn reactionKey(buf: []u8, text: []const u8, custom: u64) []const u8 {
    if (custom != 0) {
        var enc: [96]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ urlEncode(&enc, text), custom }) catch "";
    }
    return urlEncode(buf, text);
}

/// Sigla de um servidor sem ícone: primeira letra de até 3 palavras.
pub fn acronym(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, name, " -_");
    var count: usize = 0;
    while (it.next()) |word| {
        if (count >= 3) break;
        const n = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
        try out.appendSlice(gpa, word[0..@min(n, word.len)]);
        count += 1;
    }
    if (out.items.len == 0) try out.append(gpa, '?');
    return out.toOwnedSlice(gpa);
}

test "horário ISO 8601" {
    try std.testing.expectEqual(@as(i64, 0), isoTime("1970-01-01T00:00:00+00:00"));
    try std.testing.expectEqual(@as(i64, 1793661672), isoTime("2026-11-02T23:21:12.345000+00:00"));
    try std.testing.expectEqual(@as(i64, 1793661672), isoTime("2026-11-02T20:21:12.000000-03:00"));
}

test "conteúdo, strings e URLs" {
    const a = std.testing.allocator;
    const s = try simplifyContent(a, "oi <:pepe:123> e <a:dance:456>!");
    defer a.free(s);
    try std.testing.expectEqualStrings("oi :pepe: e :dance:!", s);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeString(&out, a, "a\"b\\c\nd");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", out.items);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("%F0%9F%91%8D", urlEncode(&buf, "👍"));

    const ac = try acronym(a, "Zig Brasil");
    defer a.free(ac);
    try std.testing.expectEqualStrings("ZB", ac);
}

test "emoji no caminho das reações" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("pepe_ok:123", reactionKey(&b, "pepe_ok", 123));
    try std.testing.expectEqualStrings("%F0%9F%91%8D", reactionKey(&b, "👍", 0));
    // A bandeira de tags (28 bytes) cabe inteira.
    try std.testing.expectEqual(@as(usize, 84), reactionKey(&b, "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", 0).len);
}

test "emoji personalizado: só o formato de verdade" {
    const a = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "Vec<a::B> e Vec<a:b>", "Vec<a::B> e Vec<a:b>" },
        .{ "<:x:12> <a:y_1:34>", ":x: :y_1:" },
        .{ "<:semfim:12", "<:semfim:12" },
        .{ "<:x:>", "<:x:>" },
        .{ "<", "<" },
    }) |t| {
        const s = try simplifyContent(a, t[0]);
        defer a.free(s);
        try std.testing.expectEqualStrings(t[1], s);
    }
}

test "número fora do alcance não derruba" {
    try std.testing.expectEqual(std.math.maxInt(i64), int(.{ .float = 1e30 }).?);
    try std.testing.expectEqual(std.math.minInt(i64), int(.{ .float = -1e30 }).?);
}
