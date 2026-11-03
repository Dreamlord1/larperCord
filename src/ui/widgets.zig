//! Peças pequenas reaproveitadas por vários componentes.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");

pub const Shape = enum { circle, squircle, square };

pub fn shapeOf(s: []const u8) Shape {
    return std.meta.stringToEnum(Shape, s) orelse .circle;
}

pub fn shapeRadius(shape: Shape, size: f32) f32 {
    return switch (shape) {
        .circle => size / 2,
        .squircle => size * 0.32,
        .square => size * 0.12,
    };
}

pub fn statusColor(ctx: *const d.Ctx, s: types.Status) d.Rgba {
    return switch (s) {
        .online => ctx.col(.online),
        .idle => ctx.col(.idle),
        .dnd => ctx.col(.dnd),
        .offline => ctx.col(.faint),
    };
}

/// Avatar: imagem quando houver; por enquanto, a inicial sobre a cor do cargo.
pub fn avatar(ctx: *d.Ctx, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, user_id: types.Id, shape: Shape, ring: ?d.Rgba, alpha: f32) void {
    const u = ctx.store.user(user_id);
    const role: u8 = if (u) |x| x.role else 0;
    const base = ctx.th.role(role);
    const r = size / 2;
    const rr: d.Rect = .{ .x = cx - r, .y = cy - r, .w = size, .h = size };
    d.rect(dl, rr, base.mix(ctx.col(.surface), 0.28).alpha(alpha), shapeRadius(shape, size));

    var up: [8]u8 = undefined;
    const name = if (u) |x| x.name else "?";
    const initial = d.upper(&up, d.firstGlyph(name));
    const fs = size * 0.45;
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, fs, initial);
    d.text(dl, font, fs, cx - tw / 2, cy - fs * 0.6, d.Rgba.white.alpha(0.92 * alpha), initial);

    const ring_col = ring orelse return;
    const status = if (u) |x| x.status else .offline;
    const sr = size * 0.15;
    const sx = cx + r * 0.72;
    const sy = cy + r * 0.72;
    d.circle(dl, sx, sy, sr + @max(2, size * 0.06), ring_col);
    d.circle(dl, sx, sy, sr, statusColor(ctx, status).alpha(alpha));
    switch (status) {
        .idle => d.circle(dl, sx - sr * 0.45, sy - sr * 0.45, sr * 0.62, ring_col),
        .dnd => d.rect(dl, .{ .x = sx - sr * 0.55, .y = sy - sr * 0.17, .w = sr * 1.1, .h = sr * 0.34 }, ring_col, sr * 0.17),
        .offline => d.circle(dl, sx, sy, sr * 0.45, ring_col),
        .online => {},
    }
}

pub fn statusGlyph(s: types.Status) []const u8 {
    return switch (s) {
        .online => "●",
        .idle => "◐",
        .dnd => "⊘",
        .offline => "○",
    };
}

pub const LocalTime = struct { year: i32, month: u8, day: u8, hour: u8, minute: u8, day_index: i64 };

pub fn localTime(unix_s: i64) LocalTime {
    var dt: c.SDL_DateTime = undefined;
    _ = c.SDL_TimeToDateTime(unix_s * 1_000_000_000, &dt, true);
    // Índice do dia no fuso local, para comparar "hoje"/"ontem".
    const offset: i64 = dt.utc_offset;
    return .{
        .year = dt.year,
        .month = @intCast(dt.month),
        .day = @intCast(dt.day),
        .hour = @intCast(dt.hour),
        .minute = @intCast(dt.minute),
        .day_index = @divFloor(unix_s + offset, 86400),
    };
}

pub const months = [_][]const u8{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" };
pub const months_en = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Nome do mês (1..12) no idioma da interface.
pub fn monthName(m: anytype) []const u8 {
    const i: usize = @intCast(m - 1);
    return if (i18n.en()) months_en[i] else months[i];
}

/// Data por extenso: "3 de novembro de 2026" / "November 3, 2026".
/// `month` vai de 1 a 12.
pub fn dateLong(buf: []u8, day: anytype, month: anytype, year: anytype) []const u8 {
    return i18n.fmt(buf, "{d} de {s} de {d}", "{1s} {0d}, {2d}", .{ day, monthName(month), year });
}

/// "Hoje às 14:31", "Ontem às 09:02" ou "31/10/2026 14:31"
/// (em inglês: "Today at 14:31", "Yesterday at 9:02 AM", "10/31/2026 14:31").
pub fn stamp(buf: []u8, ts: i64, now_s: i64) []const u8 {
    const t = localTime(ts);
    const today = localTime(now_s).day_index;
    var cb: [16]u8 = undefined;
    const hm = clock(&cb, ts);
    return switch (today - t.day_index) {
        0 => i18n.fmt(buf, "Hoje às {s}", "Today at {s}", .{hm}),
        1 => i18n.fmt(buf, "Ontem às {s}", "Yesterday at {s}", .{hm}),
        // Em inglês, mês antes do dia (10/31/2026).
        else => i18n.fmt(buf, "{d:0>2}/{d:0>2}/{d} {s}", "{1d:0>2}/{0d:0>2}/{2d} {3s}", .{ t.day, t.month, t.year, hm }),
    };
}

pub var hour12 = false;

pub fn clock(buf: []u8, ts: i64) []const u8 {
    const t = localTime(ts);
    if (hour12) return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ if (t.hour % 12 == 0) 12 else t.hour % 12, t.minute, if (t.hour < 12) "AM" else "PM" }) catch "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ t.hour, t.minute }) catch "";
}

pub fn dayLabel(buf: []u8, ts: i64) []const u8 {
    const t = localTime(ts);
    return dateLong(buf, t.day, t.month, t.year);
}

/// Três pontinhos animados ("digitando…").
pub fn typingDots(dl: *c.ImDrawList, x: f32, cy: f32, color: d.Rgba, now_ms: i64) void {
    anim.active = true; // mantém redesenhando enquanto aparece
    for (0..3) |i| {
        const phase = @as(f32, @floatFromInt(@mod(now_ms, 1200))) / 1200.0 * std.math.tau - @as(f32, @floatFromInt(i)) * 0.9;
        const k = (std.math.sin(phase) + 1) / 2;
        d.circle(dl, x + @as(f32, @floatFromInt(i)) * 7, cy - k * 2.5, 2.4, color.alpha(0.45 + 0.55 * k));
    }
}
