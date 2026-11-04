//! Links do Discord dentro do texto: mensagem/canal (abrem aqui) e convite
//! (cartão com "Abrir no navegador"; entrar pelo app arrisca a conta).
const std = @import("std");
const Id = @import("types.zig").Id;

pub const MessageLink = struct {
    /// 0 = "@me" (mensagem direta).
    guild: Id,
    channel: Id,
    /// 0 = link do canal, sem mensagem.
    message: Id = 0,
};

/// Código de convite em tamanho fixo (vai em ação, comando e evento sem alocar).
pub const InviteCode = struct {
    buf: [31]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) InviteCode {
        var c: InviteCode = .{};
        const n = @min(s.len, c.buf.len);
        @memcpy(c.buf[0..n], s[0..n]);
        c.len = @intCast(n);
        return c;
    }

    pub fn slice(c: *const InviteCode) []const u8 {
        return c.buf[0..c.len];
    }
};

/// O caminho depois de `https://host/`, se o host é um dos nossos.
fn pathOf(url: []const u8, hosts: []const []const u8) ?[]const u8 {
    var rest = url;
    if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
        rest = rest[8..];
    } else if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
        rest = rest[7..];
    } else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    for (hosts) |h| if (std.ascii.eqlIgnoreCase(host, h)) {
        var path = rest[slash + 1..];
        // Sem query, âncora nem a barra do fim.
        if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
        return std.mem.trimEnd(u8, path, "/");
    };
    return null;
}

const site_hosts = [_][]const u8{
    "discord.com",     "www.discord.com",     "ptb.discord.com",     "canary.discord.com",
    "discordapp.com",  "www.discordapp.com",  "ptb.discordapp.com",  "canary.discordapp.com",
};

fn snowflake(s: []const u8) ?Id {
    if (s.len == 0 or s.len > 20) return null;
    const v = std.fmt.parseInt(Id, s, 10) catch return null;
    return if (v == 0) null else v;
}

/// `discord.com/channels/G/C` ou `.../G/C/M` (G pode ser `@me`).
pub fn parseMessage(url: []const u8) ?MessageLink {
    const path = pathOf(url, &site_hosts) orelse return null;
    var it = std.mem.splitScalar(u8, path, '/');
    if (!std.mem.eql(u8, it.next() orelse return null, "channels")) return null;
    const gs = it.next() orelse return null;
    const guild: Id = if (std.mem.eql(u8, gs, "@me")) 0 else snowflake(gs) orelse return null;
    const channel = snowflake(it.next() orelse return null) orelse return null;
    const msg = it.next();
    if (it.next() != null) return null;
    return .{ .guild = guild, .channel = channel, .message = if (msg) |m| snowflake(m) orelse return null else 0 };
}

/// `discord.gg/x`, `discord.com/invite/x` (e ptb., canary.). O código devolvido
/// é uma fatia de `url`.
pub fn parseInvite(url: []const u8) ?[]const u8 {
    const code = blk: {
        if (pathOf(url, &.{ "discord.gg", "www.discord.gg" })) |p| break :blk p;
        const p = pathOf(url, &site_hosts) orelse return null;
        if (!std.mem.startsWith(u8, p, "invite/")) return null;
        break :blk p[7..];
    };
    if (code.len == 0 or code.len > 31) return null;
    for (code) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return null;
    return code;
}

test "links de mensagem e de canal, com os subdomínios" {
    const a = parseMessage("https://discord.com/channels/123/456/789").?;
    try std.testing.expectEqual(@as(Id, 123), a.guild);
    try std.testing.expectEqual(@as(Id, 456), a.channel);
    try std.testing.expectEqual(@as(Id, 789), a.message);
    const b = parseMessage("https://ptb.discord.com/channels/123/456").?;
    try std.testing.expectEqual(@as(Id, 0), b.message);
    try std.testing.expect(parseMessage("https://canary.discord.com/channels/1/2/3/") != null);
    try std.testing.expect(parseMessage("https://discordapp.com/channels/1/2?x=1") != null);
    const dm = parseMessage("https://discord.com/channels/@me/55/66").?;
    try std.testing.expectEqual(@as(Id, 0), dm.guild);
    try std.testing.expectEqual(@as(Id, 55), dm.channel);
    // Não são nossos: vão para o navegador.
    try std.testing.expect(parseMessage("https://discord.com/channels/123") == null);
    try std.testing.expect(parseMessage("https://discord.com/channels/1/2/3/4") == null);
    try std.testing.expect(parseMessage("https://discord.com/channels/1/abc") == null);
    try std.testing.expect(parseMessage("https://discord.com.evil.io/channels/1/2") == null);
    try std.testing.expect(parseMessage("https://evil.io/discord.com/channels/1/2") == null);
    try std.testing.expect(parseMessage("https://discord.com/store") == null);
    try std.testing.expect(parseMessage("discord.com/channels/1/2") == null);
}

test "links de convite" {
    try std.testing.expectEqualStrings("abc-9", parseInvite("https://discord.gg/abc-9").?);
    try std.testing.expectEqualStrings("abc", parseInvite("https://discord.gg/abc?event=1").?);
    try std.testing.expectEqualStrings("abc", parseInvite("https://discord.com/invite/abc/").?);
    try std.testing.expectEqualStrings("abc", parseInvite("https://canary.discord.com/invite/abc").?);
    try std.testing.expect(parseInvite("https://discord.gg/") == null);
    try std.testing.expect(parseInvite("https://discord.gg/a/b") == null);
    try std.testing.expect(parseInvite("https://discord.gg.evil.io/abc") == null);
    try std.testing.expect(parseInvite("https://discord.com/channels/1/2") == null);
    const code = InviteCode.init("abc");
    try std.testing.expectEqualStrings("abc", code.slice());
}
