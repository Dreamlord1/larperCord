//! Paleta do app. Lê as cores do pywal (~/.cache/wal/colors) e deriva os
//! tons de superfície; sem pywal usa uma paleta padrão.
const std = @import("std");
const c = @import("c");

pub const Rgb = struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn hex(v: u24) Rgb {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        };
    }

    pub fn mix(a: Rgb, b: Rgb, k: f32) Rgb {
        return .{ .r = a.r + (b.r - a.r) * k, .g = a.g + (b.g - a.g) * k, .b = a.b + (b.b - a.b) * k };
    }

    pub fn luma(self: Rgb) f32 {
        return 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
    }

    /// Cor empacotada no formato IM_COL32 (ABGR).
    pub fn col(self: Rgb, alpha: f32) u32 {
        const r: u32 = @intFromFloat(std.math.clamp(self.r, 0, 1) * 255.0 + 0.5);
        const g: u32 = @intFromFloat(std.math.clamp(self.g, 0, 1) * 255.0 + 0.5);
        const b: u32 = @intFromFloat(std.math.clamp(self.b, 0, 1) * 255.0 + 0.5);
        const a: u32 = @intFromFloat(std.math.clamp(alpha, 0, 1) * 255.0 + 0.5);
        return (a << 24) | (b << 16) | (g << 8) | r;
    }

    pub fn vec4(self: Rgb, alpha: f32) c.ImVec4 {
        return .{ .x = self.r, .y = self.g, .z = self.b, .w = alpha };
    }
};

pub const Theme = struct {
    guilds: Rgb,
    sidebar: Rgb,
    panel: Rgb,
    chat: Rgb,
    elevated: Rgb,
    tooltip: Rgb,
    text: Rgb,
    muted: Rgb,
    faint: Rgb,
    accent: Rgb,
    accent_text: Rgb,
    online: Rgb,
    idle: Rgb,
    dnd: Rgb,
    danger: Rgb,
    roles: [8]Rgb,
};

pub var t: Theme = undefined;

const fallback = [16]u24{
    0x15161b, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xd7dae0,
    0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x7aa2f7, 0xc678dd, 0x56b6c2, 0xf0f2f5,
};

pub fn load() void {
    var pal: [16]Rgb = undefined;
    for (fallback, 0..) |v, i| pal[i] = Rgb.hex(v);
    _ = readWal(&pal);

    const bg = pal[0];
    const fg = pal[15];
    const black = Rgb.hex(0x000000);
    const white = Rgb.hex(0xffffff);

    t = .{
        .guilds = bg.mix(black, 0.38),
        .sidebar = bg.mix(black, 0.18),
        .panel = bg.mix(black, 0.28),
        .chat = bg.mix(fg, 0.035),
        .elevated = bg.mix(fg, 0.085),
        .tooltip = bg.mix(black, 0.55),
        .text = fg,
        .muted = fg.mix(bg, 0.42),
        .faint = fg.mix(bg, 0.62),
        .accent = pal[4],
        .accent_text = if (pal[4].luma() > 0.6) black else white,
        .online = Rgb.hex(0x45b36b),
        .idle = Rgb.hex(0xe5a83b),
        .dnd = Rgb.hex(0xe5484d),
        .danger = Rgb.hex(0xe5484d),
        .roles = .{ pal[4], pal[1], pal[3], pal[5], pal[6], pal[12], pal[9], pal[13] },
    };
}

/// Lê as 16 cores do pywal. Retorna false se o arquivo não existir.
fn readWal(pal: *[16]Rgb) bool {
    const home = c.SDL_getenv("HOME");
    if (home == null) return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/.cache/wal/colors", .{std.mem.span(home)}, 0) catch return false;

    var size: usize = 0;
    const data_ptr = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data_ptr);
    const data = @as([*]const u8, @ptrCast(data_ptr))[0..size];

    var it = std.mem.tokenizeAny(u8, data, "\r\n");
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= 16) break;
        const s = std.mem.trim(u8, line, " #");
        const v = std.fmt.parseInt(u24, s, 16) catch return false;
        pal[i] = Rgb.hex(v);
    }
    return i >= 16;
}
