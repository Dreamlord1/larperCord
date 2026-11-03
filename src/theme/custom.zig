//! Cores personalizadas por tema e por modo (escuro/claro).
//! O usuário escolhe qualquer `#RRGGBB` ou `#RRGGBBAA` para os tokens do tema
//! e para os oito cargos; as escolhas ficam em `settings.kdl` e são aplicadas
//! numa cópia do tema, sem tocar no arquivo `.kdl` original.
const std = @import("std");
const theme = @import("theme.zig");
const Rgba = theme.Rgba;

pub const token_count = @typeInfo(theme.Token).@"enum".field_names.len;
pub const role_count = 8;
pub const slot_count = token_count + role_count;

pub const Overrides = struct {
    /// Cores empacotadas como 0xRRGGBBAA; null = usa a cor do tema.
    colors: [token_count]?u32 = @splat(null),
    roles: [role_count]?u32 = @splat(null),

    pub fn any(o: *const Overrides) bool {
        for (o.colors) |c| if (c != null) return true;
        for (o.roles) |c| if (c != null) return true;
        return false;
    }

    pub fn get(o: *const Overrides, slot: usize) ?u32 {
        if (slot < token_count) return o.colors[slot];
        const r = slot - token_count;
        return if (r < role_count) o.roles[r] else null;
    }

    pub fn set(o: *Overrides, slot: usize, value: ?u32) void {
        if (slot < token_count) {
            o.colors[slot] = value;
        } else if (slot - token_count < role_count) {
            o.roles[slot - token_count] = value;
        }
    }
};

pub const ThemeOverrides = struct {
    dark: Overrides = .{},
    light: Overrides = .{},

    pub fn at(o: *ThemeOverrides, mode: theme.Mode) *Overrides {
        return if (mode == .light) &o.light else &o.dark;
    }

    pub fn atConst(o: *const ThemeOverrides, mode: theme.Mode) *const Overrides {
        return if (mode == .light) &o.light else &o.dark;
    }

    pub fn any(o: *const ThemeOverrides) bool {
        return o.dark.any() or o.light.any();
    }
};

const role_names = [role_count][]const u8{
    "role0", "role1", "role2", "role3", "role4", "role5", "role6", "role7",
};

/// Nome do slot usado no `settings.kdl` e na interface.
pub fn slotName(slot: usize) []const u8 {
    if (slot < token_count) return @tagName(@as(theme.Token, @enumFromInt(slot)));
    const r = slot - token_count;
    return if (r < role_count) role_names[r] else "";
}

/// Aceita tanto `accent-text` (KDL) quanto `accent_text` (enum).
pub fn slotFromName(name: []const u8) ?usize {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    const normalized = buf[0..name.len];
    if (std.meta.stringToEnum(theme.Token, normalized)) |tok| return @intFromEnum(tok);
    if (std.mem.startsWith(u8, normalized, "role") and normalized.len > 4) {
        const r = std.fmt.parseInt(usize, normalized[4..], 10) catch return null;
        if (r < role_count) return token_count + r;
    }
    return null;
}

/// `#RRGGBB` ou `#RRGGBBAA` -> 0xRRGGBBAA. Sem `#` também vale.
pub fn parseHex(raw: []const u8) ?u32 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6 and hex.len != 8) return null;
    const v = std.fmt.parseInt(u32, hex, 16) catch return null;
    return if (hex.len == 6) (v << 8) | 0xff else v;
}

pub fn fromPacked(v: u32) Rgba {
    return .{
        .r = @as(f32, @floatFromInt((v >> 24) & 0xff)) / 255.0,
        .g = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        .b = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        .a = @as(f32, @floatFromInt(v & 0xff)) / 255.0,
    };
}

pub fn toPacked(c: Rgba) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255));
    const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255));
    const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255));
    const a: u32 = @intFromFloat(@round(std.math.clamp(c.a, 0, 1) * 255));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

/// `#RRGGBB` quando opaco; `#RRGGBBAA` quando tem transparência.
pub fn formatPacked(buf: []u8, v: u32) []const u8 {
    const a = v & 0xff;
    if (a == 0xff) {
        return std.fmt.bufPrint(buf, "#{x:0>6}", .{v >> 8}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "#{x:0>8}", .{v}) catch buf[0..0];
}

pub fn formatColor(buf: []u8, c: Rgba) []const u8 {
    return formatPacked(buf, toPacked(c));
}

/// Aplica as escolhas numa cópia do tema. Se o accent mudou e o accent-text
/// não foi escolhido, calcula preto/branco para manter o contraste.
pub fn apply(t: *theme.Theme, o: *const Overrides) void {
    const accent_slot = @intFromEnum(theme.Token.accent);
    const accent_text_slot = @intFromEnum(theme.Token.accent_text);
    for (0..token_count) |i| {
        if (o.colors[i]) |v| t.colors.set(@enumFromInt(i), fromPacked(v));
    }
    for (0..role_count) |i| {
        if (o.roles[i]) |v| t.roles[i] = fromPacked(v);
    }
    if (o.colors[accent_slot]) |v| {
        if (o.colors[accent_text_slot] == null) {
            const c = fromPacked(v);
            t.colors.set(.accent_text, if (c.luma() > 0.6) Rgba.black else Rgba.white);
        }
    }
}

test "hex de ida e volta" {
    try std.testing.expectEqual(@as(?u32, 0xff00aaff), parseHex("#ff00aa"));
    try std.testing.expectEqual(@as(?u32, 0x11223344), parseHex("#11223344"));
    try std.testing.expectEqual(@as(?u32, 0xff00aaff), parseHex("ff00aa"));
    try std.testing.expect(parseHex("#12345") == null);
    try std.testing.expect(parseHex("gggggg") == null);

    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("#ff00aa", formatPacked(&b, 0xff00aaff));
    try std.testing.expectEqualStrings("#11223344", formatPacked(&b, 0x11223344));
}

test "slots de token e cargo" {
    try std.testing.expectEqual(@as(?usize, @intFromEnum(theme.Token.accent_text)), slotFromName("accent-text"));
    try std.testing.expectEqual(@as(?usize, @intFromEnum(theme.Token.code_bg)), slotFromName("code_bg"));
    try std.testing.expectEqual(@as(?usize, token_count + 3), slotFromName("role3"));
    try std.testing.expect(slotFromName("role9") == null);
    try std.testing.expect(slotFromName("nope") == null);
    try std.testing.expectEqualStrings("role3", slotName(token_count + 3));
}

test "aplicar overtakes e contraste do accent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try theme.load(std.testing.allocator,
        \\theme "x"
        \\layout { row { label text="x" } }
    , null, null);
    defer t.deinit();

    var o: Overrides = .{};
    o.set(@intFromEnum(theme.Token.accent), 0x00ff00ff);
    o.set(token_count + 1, 0xff0000ff);
    apply(&t, &o);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.c(.accent).r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.c(.accent).g, 0.01);
    // accent verde claro -> texto preto
    try std.testing.expectEqual(Rgba.black, t.c(.accent_text));
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.role(1).r, 0.01);
}
