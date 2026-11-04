//! Proxy das conexões (Configurações → Privacidade → Rede): http, https,
//! socks5 ou socks5h (socks5h://127.0.0.1:9050 = Tor, com o DNS pelo proxy).
//! Por padrão só a mídia de fora (Tenor, Giphy) passa por ele; com "em
//! tudo", também o Discord (gateway, API, imagens e vídeos).
//! Sem dependências (testado no `zig build test`); quem tem o curl aplica.
const std = @import("std");
const media_url = @import("media_url.zig");

pub const max_len = 255;
pub const Buf = [max_len + 1]u8;

/// A URL é um proxy que a gente aceita? `esquema://[usuário[:senha]@]host[:porta][/]`
pub fn valid(url: []const u8) bool {
    if (url.len == 0 or url.len > max_len) return false;
    const schemes = [_][]const u8{ "http://", "https://", "socks5://", "socks5h://" };
    const rest = for (schemes) |s| {
        if (std.ascii.startsWithIgnoreCase(url, s)) break url[s.len..];
    } else return false;
    var hostport = if (std.mem.endsWith(u8, rest, "/")) rest[0 .. rest.len - 1] else rest;
    if (std.mem.indexOfScalar(u8, hostport, '/') != null) return false;
    // Usuário e senha (o @ é o último: a senha pode ter @ codificado como %40).
    if (std.mem.lastIndexOfScalar(u8, hostport, '@')) |at| {
        for (hostport[0..at]) |ch| if (!userChar(ch)) return false;
        if (at == 0) return false;
        hostport = hostport[at + 1 ..];
    }
    var host = hostport;
    var port: []const u8 = "";
    if (std.mem.startsWith(u8, hostport, "[")) {
        // IPv6: [::1]:1080
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return false;
        host = hostport[1..close];
        if (host.len == 0) return false;
        for (host) |ch| if (!(std.ascii.isHex(ch) or ch == ':' or ch == '.')) return false;
        const after = hostport[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return false;
            port = after[1..];
            if (port.len == 0) return false;
        }
    } else {
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
            host = hostport[0..colon];
            port = hostport[colon + 1 ..];
            if (port.len == 0) return false;
        }
        if (host.len == 0 or host.len > 253) return false;
        for (host) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_')) return false;
        if (host[0] == '.' or host[0] == '-') return false;
    }
    if (port.len > 0) {
        const n = std.fmt.parseInt(u32, port, 10) catch return false;
        if (n == 0 or n > 65535) return false;
    }
    return true;
}

fn userChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~%!$&'()*+,;=:", ch) != null;
}

// O valor em uso: escrito pela interface, lido pelas threads de rede.
var lock_flag: std.atomic.Value(bool) = .init(false);
var cur: Buf = @splat(0);
var cur_len: usize = 0;
var cur_all = false;

fn lock() void {
    while (lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock() void {
    lock_flag.store(false, .release);
}

/// Aplica o que está nas configurações (inválido = sem proxy). Barato se
/// nada mudou (o app chama a cada quadro).
pub fn set(url: []const u8, all: bool) void {
    // Chamado a cada quadro: sem mudança, nem valida.
    if (last_all == all and std.mem.eql(u8, last_raw[0..last_raw_len], url)) return;
    last_all = all;
    last_raw_len = @min(url.len, last_raw.len);
    @memcpy(last_raw[0..last_raw_len], url[0..last_raw_len]);
    const u = if (valid(url)) url else "";
    lock();
    defer unlock();
    if (cur_all == all and std.mem.eql(u8, cur[0..cur_len], u)) return;
    @memcpy(cur[0..u.len], u);
    cur[u.len] = 0;
    cur_len = u.len;
    cur_all = all;
}

var last_raw: [512]u8 = undefined;
var last_raw_len: usize = 0;
var last_all = false;

/// O proxy para baixar `url` (null = conexão direta).
pub fn forUrl(buf: *Buf, url: []const u8) ?[:0]const u8 {
    lock();
    defer unlock();
    if (cur_len == 0) return null;
    if (!cur_all and media_url.discordHost(url)) return null;
    @memcpy(buf[0 .. cur_len + 1], cur[0 .. cur_len + 1]);
    return buf[0..cur_len :0];
}

/// O proxy do gateway e da API do Discord (só com "em tudo").
pub fn forDiscord(buf: *Buf) ?[:0]const u8 {
    lock();
    defer unlock();
    if (cur_len == 0 or !cur_all) return null;
    @memcpy(buf[0 .. cur_len + 1], cur[0 .. cur_len + 1]);
    return buf[0..cur_len :0];
}

test "proxy: urls aceitas e recusadas" {
    for ([_][]const u8{ "socks5h://127.0.0.1:9050", "socks5://localhost:1080", "http://proxy.example.com:3128", "https://p.example.com", "HTTP://10.0.0.1:8080/", "socks5://user:pa%40ss@host:1080", "socks5h://[::1]:9050" }) |u| {
        if (!valid(u)) {
            std.debug.print("deveria aceitar {s}\n", .{u});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "", "127.0.0.1:9050", "ftp://x:21", "socks4://h:1", "socks5h://", "socks5h://:9050", "socks5h://h:0", "socks5h://h:70000", "socks5h://h:", "http://h/path", "http://h\"x", "http://a b", "http://h:80\\", "socks5://@h:1", "socks5h://[]:1", "http://-h" }) |u| {
        if (valid(u)) {
            std.debug.print("deveria recusar {s}\n", .{u});
            return error.TestUnexpectedResult;
        }
    }
}

test "proxy: só a mídia de fora, ou tudo" {
    var b: Buf = undefined;
    set("socks5h://127.0.0.1:9050", false);
    try std.testing.expectEqualStrings("socks5h://127.0.0.1:9050", forUrl(&b, "https://media.tenor.com/x.webp").?);
    try std.testing.expect(forUrl(&b, "https://cdn.discordapp.com/x.png") == null);
    try std.testing.expect(forDiscord(&b) == null);
    set("socks5h://127.0.0.1:9050", true);
    try std.testing.expect(forUrl(&b, "https://cdn.discordapp.com/x.png") != null);
    try std.testing.expect(forDiscord(&b) != null);
    set("lixo", true);
    try std.testing.expect(forUrl(&b, "https://media.tenor.com/x.webp") == null);
    set("", false);
    try std.testing.expect(forDiscord(&b) == null);
}
