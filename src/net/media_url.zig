//! Regras das URLs de mídia (sem dependências, testadas no `zig build test`):
//! de onde o app aceita baixar e como pedir a imagem já reduzida ao proxy.
const std = @import("std");

/// GIFs do Tenor/Giphy: o Discord só manda o vídeo (MP4) pelo proxy dele;
/// o GIF animado vem do site de origem. Configurações → Chat liga/desliga.
/// Desligado por padrão: o Discord não tem versão animada dos GIFs do Tenor
/// pelo proxy dele (só a prévia parada), e o app oficial também vai direto
/// no Tenor para animar.
pub var allow_gif_hosts: bool = false;

/// GIF antigo do Tenor (media.tenor.co/videos/…, só existe em MP4): a URL é
/// "tenor-page:<página tenor.com/view/…>"; a página traz o vídeo no formato
/// novo (og:video), que vira o WebP animado.
pub const tenor_page = "tenor-page:";

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
    return std.mem.eql(u8, host, "media.tenor.com") or std.mem.eql(u8, host, "tenor.com") or std.mem.eql(u8, host, "i.giphy.com") or
        (std.mem.startsWith(u8, host, "media") and std.mem.endsWith(u8, host, ".giphy.com"));
}

/// O vídeo (og:video) da página de um GIF do Tenor, ou null.
pub fn tenorVideoFromPage(html: []const u8) ?[]const u8 {
    const key = "property=\"og:video\" content=\"";
    var i = std.mem.indexOf(u8, html, key) orelse return null;
    i += key.len;
    const end = std.mem.indexOfScalarPos(u8, html, i, '"') orelse return null;
    const url = html[i..end];
    return if (std.mem.startsWith(u8, url, "https://media.tenor.com/")) url else null;
}

/// O GIF de um embed "gifv" a partir do vídeo dele:
///   media.tenor.com/<id>AAAPo/nome.mp4  -> media.tenor.com/<id>AAAAx/nome.webp
/// (os 2 últimos caracteres do id dizem o formato: Po = mp4, AC = gif,
/// Ax = webp animado, bem menor que o GIF; tabela em
/// wiki.archiveteam.org/index.php/Tenor)
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
        return std.fmt.bufPrint(buf, "https://media.tenor.com/{s}AAAAx/{s}.webp", .{ path[start .. slash - 5], name }) catch null;
    }
    if (isGifHost(host)) return std.fmt.bufPrint(buf, "{s}.gif", .{path[0 .. path.len - 4]}) catch null;
    return null;
}

test "vídeo do tenor a partir da página" {
    const html = "<meta property=\"og:image\" content=\"https://media.tenor.com/abcAAAAM/x.gif\"><meta property=\"og:video\" content=\"https://media.tenor.com/XhYqu5fu4LgAAAPo/cat.mp4\">";
    try std.testing.expectEqualStrings("https://media.tenor.com/XhYqu5fu4LgAAAPo/cat.mp4", tenorVideoFromPage(html).?);
    try std.testing.expect(tenorVideoFromPage("<html></html>") == null);
    try std.testing.expect(tenorVideoFromPage("<meta property=\"og:video\" content=\"https://evil.com/x.mp4\">") == null);
}

test "gif do tenor e do giphy a partir do vídeo" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://media.tenor.com/H5y5Fk9VdKcAAAAx/cat-dance.webp", gifFromVideo(&b, "https://media.tenor.com/H5y5Fk9VdKcAAAPo/cat-dance.mp4").?);
    try std.testing.expectEqualStrings("https://media.giphy.com/media/abc/giphy.gif", gifFromVideo(&b, "https://media.giphy.com/media/abc/giphy.mp4").?);
    try std.testing.expect(gifFromVideo(&b, "https://evil.com/x.mp4") == null);
    allow_gif_hosts = false;
    try std.testing.expect(!allowedHost("https://media.tenor.com/x.gif"));
    allow_gif_hosts = true;
    try std.testing.expect(allowedHost("https://media.tenor.com/x.gif"));
    try std.testing.expect(!allowedHost("https://tenor.com.evil.com/x.gif"));
}

/// Pede ao proxy de mídia a imagem já reduzida (`width`/`height`). WebP
/// vem como WebP mesmo: o cache de imagens decodifica (inclusive animado).
pub fn proxiedUrl(buf: []u8, url: []const u8, w: u16, h: u16) ?[:0]const u8 {
    const is_media = std.mem.indexOf(u8, url, "media.discordapp.net/") != null or std.mem.indexOf(u8, url, ".discordapp.net/external/") != null;
    if (!is_media) return std.fmt.bufPrintSentinel(buf, "{s}", .{url}, 0) catch null;
    const q = std.mem.indexOfScalar(u8, url, '?');
    const sep: []const u8 = if (q != null) "&" else "?";
    // Vídeo: o proxy devolve um quadro (a prévia) em WebP.
    const path = url[0 .. q orelse url.len];
    const video = std.ascii.endsWithIgnoreCase(path, ".mp4") or std.ascii.endsWithIgnoreCase(path, ".webm") or std.ascii.endsWithIgnoreCase(path, ".mov");
    // WebP/GIF: sem `animated=true` o proxy devolve só o primeiro quadro
    // (é assim que os GIFs do Klipy animam sem sair do Discord).
    const anim = std.ascii.endsWithIgnoreCase(path, ".webp") or std.ascii.endsWithIgnoreCase(path, ".gif");
    return std.fmt.bufPrintSentinel(buf, "{s}{s}{s}{s}width={d}&height={d}", .{ url, sep, if (video) "format=webp&" else "", if (anim) "animated=true&" else "", w, h }, 0) catch null;
}

test "url do proxy pede o tamanho e mantém o WebP" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://media.discordapp.net/attachments/1/2/a.png?ex=1&width=256&height=128", proxiedUrl(&b, "https://media.discordapp.net/attachments/1/2/a.png?ex=1", 256, 128).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/a.webp?width=128&height=128", proxiedUrl(&b, "https://media.discordapp.net/a.webp", 128, 128).?);
    try std.testing.expectEqualStrings("https://images-ext-1.discordapp.net/external/x/https/static.klipy.com/a.webp?animated=true&width=232&height=240", proxiedUrl(&b, "https://images-ext-1.discordapp.net/external/x/https/static.klipy.com/a.webp", 232, 240).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/stickers/1.webp?size=160&width=128&height=128", proxiedUrl(&b, "https://media.discordapp.net/stickers/1.webp?size=160", 128, 128).?);
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/avatar-decoration-presets/a.png?size=160&passthrough=true", proxiedUrl(&b, "https://cdn.discordapp.com/avatar-decoration-presets/a.png?size=160&passthrough=true", 128, 128).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/attachments/1/2/v.mp4?ex=1&format=webp&width=320&height=180", proxiedUrl(&b, "https://media.discordapp.net/attachments/1/2/v.mp4?ex=1", 320, 180).?);
    try std.testing.expect(allowedHost("https://cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("https://evil.com/cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("http://cdn.discordapp.com/x"));
    try std.testing.expect(!allowedHost("https://cdn.discordapp.com.evil.com/x"));
}

/// Só host + caminho, sem a query (que leva assinaturas) — para logs.
pub fn logPart(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const end = std.mem.indexOfAny(u8, url[start..], "?#") orelse url.len - start;
    return url[start .. start + end];
}

test "url no log fica sem a query" {
    try std.testing.expectEqualStrings("cdn.discordapp.com/attachments/1/2/a.png", logPart("https://cdn.discordapp.com/attachments/1/2/a.png?ex=1&hm=abc"));
    try std.testing.expectEqualStrings("media.discordapp.net/a.webp", logPart("https://media.discordapp.net/a.webp#x"));
    try std.testing.expectEqualStrings("/tmp/a.png", logPart("file:///tmp/a.png"));
}
