//! Regras das URLs de mídia (sem dependências, testadas no `zig build test`):
//! de onde o app aceita baixar e como pedir a imagem já reduzida ao proxy.
const std = @import("std");

/// GIFs do Tenor/Giphy: o Discord só manda o vídeo (MP4) pelo proxy dele;
/// o GIF animado vem do site de origem. Configurações → Chat liga/desliga.
pub var allow_gif_hosts: bool = true;

fn hostOf(url: []const u8) []const u8 {
    const rest = url[8..];
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    return rest[0..end];
}

/// Domínios de onde a gente aceita baixar.
pub fn allowedHost(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    const host = hostOf(url);
    if (std.mem.eql(u8, host, "cdn.discordapp.com") or std.mem.eql(u8, host, "media.discordapp.net") or
        std.mem.endsWith(u8, host, ".discordapp.net") or std.mem.endsWith(u8, host, ".discordapp.com")) return true;
    return allow_gif_hosts and isGifHost(host);
}

fn isGifHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "media.tenor.com") or std.mem.eql(u8, host, "i.giphy.com") or
        (std.mem.startsWith(u8, host, "media") and std.mem.endsWith(u8, host, ".giphy.com"));
}

/// O GIF de um embed "gifv" a partir do vídeo dele:
///   media.tenor.com/<id>AAAPo/nome.mp4  -> media.tenor.com/<id>AAAAC/nome.gif
///   media.giphy.com/media/<id>/giphy.mp4 -> .../giphy.gif
pub fn gifFromVideo(buf: []u8, video: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, video, "https://")) return null;
    const q = std.mem.indexOfScalar(u8, video, '?') orelse video.len;
    const path = video[0..q];
    if (!std.ascii.endsWithIgnoreCase(path, ".mp4")) return null;
    const host = hostOf(path);
    if (std.mem.eql(u8, host, "media.tenor.com")) {
        // O código de formato são os 5 últimos caracteres da primeira pasta.
        const start = 8 + host.len + 1;
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse return null;
        if (slash - start < 6) return null;
        const name = path[slash + 1 .. path.len - 4];
        return std.fmt.bufPrint(buf, "https://media.tenor.com/{s}AAAAC/{s}.gif", .{ path[start .. slash - 5], name }) catch null;
    }
    if (isGifHost(host)) return std.fmt.bufPrint(buf, "{s}.gif", .{path[0 .. path.len - 4]}) catch null;
    return null;
}

test "gif do tenor e do giphy a partir do vídeo" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://media.tenor.com/H5y5Fk9VdKcAAAAC/cat-dance.gif", gifFromVideo(&b, "https://media.tenor.com/H5y5Fk9VdKcAAAPo/cat-dance.mp4").?);
    try std.testing.expectEqualStrings("https://media.giphy.com/media/abc/giphy.gif", gifFromVideo(&b, "https://media.giphy.com/media/abc/giphy.mp4").?);
    try std.testing.expect(gifFromVideo(&b, "https://evil.com/x.mp4") == null);
    allow_gif_hosts = false;
    try std.testing.expect(!allowedHost("https://media.tenor.com/x.gif"));
    allow_gif_hosts = true;
    try std.testing.expect(allowedHost("https://media.tenor.com/x.gif"));
    try std.testing.expect(!allowedHost("https://tenor.com.evil.com/x.gif"));
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
