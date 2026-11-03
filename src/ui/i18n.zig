//! Idioma da interface: português ou inglês.
//!
//! Cada texto leva as duas versões no lugar em que é usado, em vez de um
//! dicionário separado que fica desatualizado:
//!
//!     tr("Entrar", "Sign in")
//!     fmt(&buf, "Respondendo a {s}", "Replying to {s}", .{nome})
//!
//! `lang` é global (lida também pela thread de rede, só para os avisos).
const std = @import("std");
const c = @import("c");

pub const Lang = enum(u8) { pt, en };

pub var lang: Lang = .pt;

pub fn en() bool {
    return lang == .en;
}

pub fn tr(pt: []const u8, english: []const u8) []const u8 {
    return if (lang == .en) english else pt;
}

pub fn trZ(pt: [:0]const u8, english: [:0]const u8) [:0]const u8 {
    return if (lang == .en) english else pt;
}

pub fn fmt(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) []const u8 {
    return (if (lang == .en) std.fmt.bufPrint(buf, english, args) else std.fmt.bufPrint(buf, pt, args)) catch buf[0..0];
}

pub fn fmtZ(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) [:0]const u8 {
    return (if (lang == .en) std.fmt.bufPrintSentinel(buf, english, args, 0) else std.fmt.bufPrintSentinel(buf, pt, args, 0)) catch "";
}

pub fn allocPrint(gpa: std.mem.Allocator, comptime pt: []const u8, comptime english: []const u8, args: anytype) ![]u8 {
    return if (lang == .en) std.fmt.allocPrint(gpa, english, args) else std.fmt.allocPrint(gpa, pt, args);
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
