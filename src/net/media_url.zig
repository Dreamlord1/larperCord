//! Regras das URLs de mídia (sem dependências, testadas no `zig build test`):
//! de onde o app aceita baixar e como pedir a imagem já reduzida ao proxy.
const std = @import("std");

/// Domínios de onde a gente aceita baixar.
pub fn allowedHost(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    const rest = url[8..];
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    const host = rest[0..end];
    return std.mem.eql(u8, host, "cdn.discordapp.com") or std.mem.eql(u8, host, "media.discordapp.net") or
        std.mem.endsWith(u8, host, ".discordapp.net") or std.mem.endsWith(u8, host, ".discordapp.com");
}

/// Pede ao proxy de mídia a imagem já reduzida (`width`/`height`) e em PNG
/// quando o original é WebP (que o stb_image não lê).
pub fn proxiedUrl(buf: []u8, url: []const u8, w: u16, h: u16) ?[:0]const u8 {
    const is_media = std.mem.indexOf(u8, url, "media.discordapp.net/") != null or std.mem.indexOf(u8, url, ".discordapp.net/external/") != null;
    const q = std.mem.indexOfScalar(u8, url, '?');
    const path = url[0 .. q orelse url.len];
    const webp = std.ascii.endsWithIgnoreCase(path, ".webp");
    if (!is_media) return std.fmt.bufPrintSentinel(buf, "{s}", .{url}, 0) catch null;
    const sep: []const u8 = if (q != null) "&" else "?";
    return std.fmt.bufPrintSentinel(buf, "{s}{s}width={d}&height={d}{s}", .{ url, sep, w, h, if (webp) "&format=png" else "" }, 0) catch null;
}

test "url do proxy pede o tamanho e PNG para WebP" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://media.discordapp.net/attachments/1/2/a.png?ex=1&width=256&height=128", proxiedUrl(&b, "https://media.discordapp.net/attachments/1/2/a.png?ex=1", 256, 128).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/a.webp?width=128&height=128&format=png", proxiedUrl(&b, "https://media.discordapp.net/a.webp", 128, 128).?);
    try std.testing.expect(allowedHost("https://cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("https://evil.com/cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("http://cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("https://cdn.discordapp.com.evil.com/x"));
}
