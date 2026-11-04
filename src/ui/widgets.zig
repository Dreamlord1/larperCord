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

/// Onde fica cada imagem no CDN do Discord. Na demonstração o "hash" já é
/// a URL (demo:…), gerada pelo cache sem rede.
pub const Cdn = enum { avatar, guild, group };

pub fn cdnUrl(buf: []u8, kind: Cdn, id: types.Id, hash: []const u8) []const u8 {
    if (std.mem.startsWith(u8, hash, "demo:")) return hash;
    const dir = switch (kind) {
        .avatar => "avatars",
        .guild => "icons",
        .group => "channel-icons",
    };
    // PNG mesmo para os animados (a_…): o primeiro quadro basta aqui.
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/{s}/{d}/{s}.png?size=128", .{ dir, id, hash }) catch "";
}

/// Banner (ou splash) de um servidor.
pub fn bannerUrl(buf: []u8, guild: types.Id, hash: []const u8, splash: bool) []const u8 {
    if (std.mem.startsWith(u8, hash, "demo:")) return hash;
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/{s}/{d}/{s}.png?size=600", .{ if (splash) "splashes" else "banners", guild, hash }) catch "";
}

/// Desenha uma imagem do cache recortada com cantos arredondados.
/// Retorna false enquanto ela não chegou (quem chama desenha o substituto).
pub var no_pics = false;
pub var square_pics = false;

pub fn picture(ctx: *d.Ctx, dl: *c.ImDrawList, url: []const u8, r: d.Rect, radius: f32, alpha: f32) bool {
    if (url.len == 0) return false;
    if (no_pics) return false;
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    switch (ctx.images.getStill(url, r.w * scale, r.h * scale)) {
        .ready => |t| {
            if (square_pics) c.ImDrawList_AddImageEx(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha)) else c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), radius, 0);
            return true;
        },
        else => return false,
    }
}

/// Cor do nome de alguém: a do cargo no servidor (como no Discord), a do
/// tema na demonstração, ou a do texto quando não tem cargo com cor.
pub fn nameColor(ctx: *const d.Ctx, guild: types.Id, user_id: types.Id) d.Rgba {
    if (!ctx.st.settings.role_colors) return ctx.col(.text);
    const rgb = ctx.store.nameColor(guild, user_id);
    if (rgb != 0) return d.Rgba.hex(rgb).mix(ctx.col(.text), 0.12);
    if (ctx.store.demo) if (ctx.store.user(user_id)) |u| return ctx.th.role(u.role).mix(ctx.col(.text), 0.2);
    return ctx.col(.text);
}

/// Avatar: a foto da pessoa; sem foto (ou enquanto baixa), a inicial
/// sobre a cor do cargo.
pub fn avatar(ctx: *d.Ctx, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, user_id: types.Id, shape: Shape, ring: ?d.Rgba, alpha: f32) void {
    const u = ctx.store.user(user_id);
    const role: u8 = if (u) |x| x.role else 0;
    const base = ctx.th.role(role);
    const r = size / 2;
    const rr: d.Rect = .{ .x = cx - r, .y = cy - r, .w = size, .h = size };
    var ub: [160]u8 = undefined;
    const url = if (u) |x| if (x.avatar) |h| cdnUrl(&ub, .avatar, x.id, h) else "" else "";
    if (!picture(ctx, dl, url, rr, shapeRadius(shape, size), alpha)) {
        d.rect(dl, rr, base.mix(ctx.col(.surface), 0.28).alpha(alpha), shapeRadius(shape, size));
        var up: [8]u8 = undefined;
        const name = if (u) |x| x.name else "?";
        const initial = d.upper(&up, d.firstGlyph(name));
        const fs = size * 0.45;
        const font = ctx.ui.get(.semibold);
        const tw = d.width(font, fs, initial);
        d.text(dl, font, fs, cx - tw / 2, cy - fs * 0.6, d.Rgba.white.alpha(0.92 * alpha), initial);
    }

    // Decoração (moldura da loja do Discord): anima só nos avatares grandes.
    if (size >= 30) if (u) |x| if (x.decoration) |asset| {
        var db: [192]u8 = undefined;
        const big = size >= 64;
        const deco_url = std.fmt.bufPrint(&db, "https://cdn.discordapp.com/avatar-decoration-presets/{s}.png?size={d}&passthrough={s}", .{ asset, @as(u32, if (big) 160 else 96), if (big) "true" else "false" }) catch "";
        const ds = size * 1.2;
        const dr: d.Rect = .{ .x = cx - ds / 2, .y = cy - ds / 2, .w = ds, .h = ds };
        const scale = ctx.io.*.DisplayFramebufferScale.x;
        if (!no_pics) switch (ctx.images.getEx(deco_url, ds * scale, ds * scale, big)) {
            .ready => |t| c.ImDrawList_AddImageEx(dl, t.ref, d.v(dr.x, dr.y), d.v(dr.right(), dr.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha)),
            else => {},
        };
    };

    const ring_col = ring orelse return;
    const status = if (u) |x| x.status else .offline;
    // Configurações → Aparência: status como anel em volta da foto.
    if (ctx.st.settings.status_ring) {
        const t = @max(2, size * 0.07);
        const out = rr.inset(-t * 0.5 - 1, -t * 0.5 - 1);
        const col = if (status == .offline) ctx.col(.faint).alpha(0.6 * alpha) else statusColor(ctx, status).alpha(alpha);
        c.ImDrawList_AddRectEx(dl, d.v(out.x, out.y), d.v(out.right(), out.bottom()), col.u(), shapeRadius(shape, out.w), t, 0);
        return;
    }
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

/// Data completa, para a dica do horário: "terça-feira, 4 de novembro de 2026
/// às 14:32" / "Tuesday, November 4, 2026 at 14:32".
pub fn fullDate(buf: []u8, ts: i64) []const u8 {
    const t = localTime(ts);
    const days = [_][]const u8{ "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado" };
    const days_en = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    // 1º de janeiro de 1970 foi uma quinta.
    const wd: usize = @intCast(@mod(t.day_index + 4, 7));
    var cb: [16]u8 = undefined;
    var db: [64]u8 = undefined;
    const hm = clock(&cb, ts);
    const date = dateLong(&db, t.day, t.month, t.year);
    return i18n.fmt(buf, "{s}, {s} às {s}", "{s}, {s} at {s}", .{ if (i18n.en()) days_en[wd] else days[wd], date, hm });
}

pub var hour12 = false;

pub fn clock(buf: []u8, ts: i64) []const u8 {
    const t = localTime(ts);
    if (hour12) return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ if (t.hour % 12 == 0) 12 else t.hour % 12, t.minute, if (t.hour < 12) "AM" else "PM" }) catch "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ t.hour, t.minute }) catch "";
}

/// Quando a conta foi criada (está no próprio ID), por extenso.
/// Contas da demonstração têm IDs pequenos: aí mostra uma data fixa.
pub fn since(buf: []u8, id: types.Id) []const u8 {
    const ms = types.snowflakeTime(id);
    const secs = if (id < 1 << 32) 1_600_000_000 + @as(i64, @intCast(id % 1000)) * 86400 * 30 else @divTrunc(ms, 1000);
    const t = localTime(secs);
    return dateLong(buf, t.day, t.month, t.year);
}

pub fn dayLabel(buf: []u8, ts: i64) []const u8 {
    const t = localTime(ts);
    return dateLong(buf, t.day, t.month, t.year);
}

/// Três pontinhos animados ("digitando…").
pub fn typingDots(dl: *c.ImDrawList, x: f32, cy: f32, color: d.Rgba, now_ms: i64) void {
    anim.every(80); // ~12 quadros por segundo bastam para os pontinhos
    for (0..3) |i| {
        const phase = @as(f32, @floatFromInt(@mod(now_ms, 1200))) / 1200.0 * std.math.tau - @as(f32, @floatFromInt(i)) * 0.9;
        const k = (std.math.sin(phase) + 1) / 2;
        d.circle(dl, x + @as(f32, @floatFromInt(i)) * 7, cy - k * 2.5, 2.4, color.alpha(0.45 + 0.55 * k));
    }
}
