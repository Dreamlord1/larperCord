//! Cores e o mini-avaliador de expressões de cor dos temas:
//!
//!     "#df68ad"  "#df68ad80"  "#fff"  "wal:4"  "@surface"
//!     "mix(wal:0, black, 0.38)"  "alpha(@accent, 0.2)"
//!     "lighten(@bg, 0.1)"  "darken(@bg, 0.2)"  white  black  transparent
const std = @import("std");

pub const Rgba = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const black: Rgba = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Rgba = .{ .r = 1, .g = 1, .b = 1 };
    pub const transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn hex(v: u32) Rgba {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
        };
    }

    pub fn mix(a: Rgba, b: Rgba, k: f32) Rgba {
        return .{
            .r = a.r + (b.r - a.r) * k,
            .g = a.g + (b.g - a.g) * k,
            .b = a.b + (b.b - a.b) * k,
            .a = a.a + (b.a - a.a) * k,
        };
    }

    pub fn alpha(c: Rgba, k: f32) Rgba {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * k };
    }

    pub fn luma(c: Rgba) f32 {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    /// Cor empacotada como IM_COL32 (ABGR), com alpha extra opcional.
    pub fn col(c: Rgba, extra_alpha: f32) u32 {
        const q = struct {
            fn f(x: f32) u32 {
                return @intFromFloat(std.math.clamp(x, 0, 1) * 255.0 + 0.5);
            }
        }.f;
        return (q(c.a * extra_alpha) << 24) | (q(c.b) << 16) | (q(c.g) << 8) | q(c.r);
    }

    pub fn u(c: Rgba) u32 {
        return c.col(1);
    }
};

pub const Resolver = struct {
    palette: *const [16]Rgba,
    ctx: *const anyopaque,
    lookup: *const fn (ctx: *const anyopaque, name: []const u8) ?Rgba,
};

pub const Error = error{InvalidColor};

pub fn eval(src: []const u8, r: Resolver) Error!Rgba {
    var p: Parser = .{ .s = src, .r = r };
    const v = try p.expr();
    p.skip();
    if (p.i != p.s.len) return error.InvalidColor;
    return v;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    r: Resolver,
    /// `mix(mix(mix(…` num tema não pode estourar a pilha.
    depth: u8 = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn word(p: *Parser) []const u8 {
        const start = p.i;
        while (p.i < p.s.len) : (p.i += 1) {
            const ch = p.s[p.i];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '@' or ch == '#' or ch == '.')) break;
        }
        return p.s[start..p.i];
    }

    fn expect(p: *Parser, ch: u8) Error!void {
        p.skip();
        if (p.i >= p.s.len or p.s[p.i] != ch) return error.InvalidColor;
        p.i += 1;
    }

    fn number(p: *Parser) Error!f32 {
        p.skip();
        const w = p.word();
        return std.fmt.parseFloat(f32, w) catch error.InvalidColor;
    }

    fn expr(p: *Parser) Error!Rgba {
        if (p.depth >= 16) return error.InvalidColor;
        p.depth += 1;
        defer p.depth -= 1;
        p.skip();
        const w = p.word();
        if (w.len == 0) return error.InvalidColor;
        p.skip();
        if (p.i < p.s.len and p.s[p.i] == '(') {
            p.i += 1;
            const a = try p.expr();
            if (std.mem.eql(u8, w, "mix")) {
                try p.expect(',');
                const b = try p.expr();
                try p.expect(',');
                const k = try p.number();
                try p.expect(')');
                return a.mix(b, k);
            }
            try p.expect(',');
            const k = try p.number();
            try p.expect(')');
            if (std.mem.eql(u8, w, "alpha")) return a.alpha(k);
            if (std.mem.eql(u8, w, "lighten")) return a.mix(Rgba.white.alpha(a.a), k);
            if (std.mem.eql(u8, w, "darken")) return a.mix(Rgba.black.alpha(a.a), k);
            return error.InvalidColor;
        }
        return p.atom(w);
    }

    fn atom(p: *Parser, w: []const u8) Error!Rgba {
        if (w[0] == '#') return parseHex(w[1..]);
        if (w[0] == '@') return p.r.lookup(p.r.ctx, w[1..]) orelse error.InvalidColor;
        if (std.mem.startsWith(u8, w, "wal:")) {
            const idx = std.fmt.parseInt(usize, w[4..], 10) catch return error.InvalidColor;
            if (idx >= 16) return error.InvalidColor;
            return p.r.palette[idx];
        }
        if (std.mem.eql(u8, w, "black")) return Rgba.black;
        if (std.mem.eql(u8, w, "white")) return Rgba.white;
        if (std.mem.eql(u8, w, "transparent")) return Rgba.transparent;
        return error.InvalidColor;
    }
};

pub fn parseHex(h: []const u8) Error!Rgba {
    const v = std.fmt.parseInt(u32, h, 16) catch return error.InvalidColor;
    return switch (h.len) {
        3 => Rgba.hex(((v >> 8 & 0xf) * 0x110000) | ((v >> 4 & 0xf) * 0x1100) | ((v & 0xf) * 0x11)),
        4 => blk: {
            var c = Rgba.hex(((v >> 12 & 0xf) * 0x110000) | ((v >> 8 & 0xf) * 0x1100) | ((v >> 4 & 0xf) * 0x11));
            c.a = @as(f32, @floatFromInt((v & 0xf) * 0x11)) / 255.0;
            break :blk c;
        },
        6 => Rgba.hex(v),
        8 => blk: {
            var c = Rgba.hex(v >> 8);
            c.a = @as(f32, @floatFromInt(v & 0xff)) / 255.0;
            break :blk c;
        },
        else => error.InvalidColor,
    };
}

test "expressões de cor" {
    var pal: [16]Rgba = undefined;
    for (&pal, 0..) |*c, i| c.* = Rgba.hex(@intCast(i * 0x101010));
    const Ctx = struct {
        fn look(_: *const anyopaque, name: []const u8) ?Rgba {
            return if (std.mem.eql(u8, name, "bg")) Rgba.hex(0x202020) else null;
        }
    };
    const r: Resolver = .{ .palette = &pal, .ctx = &pal, .lookup = Ctx.look };
    const red = try eval("#ff0000", r);
    try std.testing.expectEqual(@as(f32, 1), red.r);
    const half = try eval("mix(black, white, 0.5)", r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half.g, 0.001);
    const a = try eval("alpha(@bg, 0.25)", r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), a.a, 0.001);
    const w = try eval("wal:2", r);
    try std.testing.expectEqual(pal[2].r, w.r);
    const short = try eval("#fff8", r);
    try std.testing.expect(short.a < 1);
    const nested = try eval(" mix( darken(@bg, 0.5) , wal:15, 0.1 ) ", r);
    try std.testing.expect(nested.r > 0);
    try std.testing.expectError(error.InvalidColor, eval("mix(black, 0.5)", r));
}

test "mix aninhado demais é erro" {
    var buf: [40_000]u8 = undefined;
    for (0..buf.len / 4) |i| @memcpy(buf[i * 4..][0..4], "mix(");
    var pal: [16]Rgba = @splat(Rgba.black);
    const r: Resolver = .{ .palette = &pal, .ctx = &pal, .lookup = struct {
        fn f(_: *const anyopaque, _: []const u8) ?Rgba {
            return null;
        }
    }.f };
    try std.testing.expectError(error.InvalidColor, eval(&buf, r));
}
