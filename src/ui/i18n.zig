//! Idioma da interface: português ou inglês.
//!
//! Cada texto leva as duas versões no lugar em que é usado, em vez de um
//! dicionário separado que fica desatualizado:
//!
//!     tr("Entrar", "Sign in")
//!     fmt(&buf, "Respondendo a {s}", "Replying to {s}", .{nome})
//!
//! O idioma é global e a thread de rede também lê (avisos, dados da
//! demonstração): por isso fica num valor atômico.
const std = @import("std");
const c = @import("c");

pub const Lang = enum(u8) { pt, en };

var lang: std.atomic.Value(Lang) = .init(.pt);

pub fn set(l: Lang) void {
    lang.store(l, .release);
}

pub fn en() bool {
    return lang.load(.acquire) == .en;
}

pub fn tr(pt: []const u8, english: []const u8) []const u8 {
    return if (en()) english else pt;
}

pub fn trZ(pt: [:0]const u8, english: [:0]const u8) [:0]const u8 {
    return if (en()) english else pt;
}

/// Sem espaço, corta o texto (nunca no meio de um caractere) em vez de sumir.
pub fn fmt(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    (if (en()) wr.print(english, args) else wr.print(pt, args)) catch {};
    const out = wr.buffered();
    if (out.len < buf.len) return out;
    // Encheu: tira o último caractere se ele ficou pela metade.
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
}

pub fn fmtZ(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) [:0]const u8 {
    return (if (en()) std.fmt.bufPrintSentinel(buf, english, args, 0) else std.fmt.bufPrintSentinel(buf, pt, args, 0)) catch "";
}

pub fn allocPrint(gpa: std.mem.Allocator, comptime pt: []const u8, comptime english: []const u8, args: anytype) ![]u8 {
    return if (en()) std.fmt.allocPrint(gpa, english, args) else std.fmt.allocPrint(gpa, pt, args);
}

/// Idioma do sistema: português se a primeira preferência for "pt",
/// inglês em qualquer outro caso.
pub fn system() Lang {
    var count: c_int = 0;
    const list = c.SDL_GetPreferredLocales(&count) orelse return .en;
    defer c.SDL_free(@ptrCast(list));
    if (count > 0) if (list[0]) |loc| {
        if (loc.*.language) |l| if (std.mem.startsWith(u8, std.mem.span(l), "pt")) return .pt;
    };
    return .en;
}

/// `language` das configurações: 0 = seguir o sistema, 1 = português, 2 = inglês.
pub fn fromSetting(v: u8) Lang {
    return switch (v) {
        1 => .pt,
        2 => .en,
        else => system(),
    };
}
