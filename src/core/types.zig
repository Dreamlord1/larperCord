//! Modelo de dados, espelhando o do Discord (IDs são snowflakes de 64 bits).
const std = @import("std");

pub const Id = u64;

pub const Status = enum { online, idle, dnd, offline };

pub const ChannelKind = enum { text, voice, category };

pub const User = struct {
    id: Id,
    name: []const u8,
    /// Índice da cor do cargo (o tema decide a cor de cada índice).
    role: u8 = 0,
    status: Status = .offline,
    activity: ?[]const u8 = null,
};

pub const Guild = struct {
    id: Id,
    name: []const u8,
    /// Texto do ícone quando não há imagem ("LC", "☕"...).
    acronym: []const u8,
    color: u8 = 0,
    unread: bool = false,
    mentions: u16 = 0,
};

pub const Channel = struct {
    id: Id,
    guild: Id,
    parent: ?Id = null,
    kind: ChannelKind = .text,
    name: []const u8,
    topic: []const u8 = "",
    position: u16 = 0,
    unread: bool = false,
    /// Em DMs (guild = 0): a outra pessoa da conversa.
    recipient: Id = 0,
};

pub const Message = struct {
    id: Id,
    channel: Id,
    author: Id,
    /// Segundos desde 1970 (UTC).
    timestamp: i64,
    content: []const u8,
    /// Identificador local de uma mensagem enviada por nós, para casar a
    /// confirmação do servidor com a cópia "pendente" já exibida.
    nonce: u64 = 0,
    /// Mensagem que esta responde (0 = nenhuma).
    reply_to: Id = 0,
    edited: bool = false,
};

/// Uma reação: o emoji (UTF-8, até 15 bytes), quantas pessoas e se inclui a gente.
pub const Reaction = struct {
    emoji: [16]u8 = @splat(0),
    len: u8 = 0,
    count: u16 = 0,
    me: bool = false,

    pub fn text(r: *const Reaction) []const u8 {
        return r.emoji[0..r.len];
    }

    pub fn init(e: []const u8) Reaction {
        var r: Reaction = .{};
        const n = @min(e.len, 15);
        @memcpy(r.emoji[0..n], e[0..n]);
        r.len = @intCast(n);
        return r;
    }
};

/// Timestamp embutido num snowflake do Discord (ms desde 2015-01-01).
pub fn snowflakeTime(id: Id) i64 {
    return @intCast((id >> 22) + 1420070400000);
}

pub fn makeSnowflake(ms: i64, seq: u64) Id {
    const since: u64 = @intCast(ms - 1420070400000);
    return (since << 22) | (seq & 0x3fffff);
}

test "snowflake ida e volta" {
    const ms: i64 = 1_793_000_000_123;
    try std.testing.expectEqual(ms, snowflakeTime(makeSnowflake(ms, 7)));
}
