//! Onde ficam as contas guardadas: a lista (core/accounts.zig) em
//! ~/.config/larpercord/accounts e o token de cada uma no chaveiro do
//! sistema, uma entrada por conta:
//!
//!   secret-tool store --label='larperCord (conta ID)' service larpercord-account account ID
//!
//! Sem chaveiro, em ~/.config/larpercord/tokens/ID (pasta 700, arquivo 600),
//! como o token único de antes. A entrada antiga (`service larpercord`,
//! discord.zig) continua valendo para a conta que já estava nela.
//!
//! O serviço tem outro nome de propósito: `secret-tool clear service
//! larpercord` (o "Sair" de antes) casa com qualquer entrada que tenha esse
//! atributo, e apagaria todas as contas de uma vez.
//!
//! O token nunca vai para a linha de comando (vai pela entrada padrão do
//! secret-tool) e o comando só leva o ID, que é um número.
const std = @import("std");
const c = @import("c");
const accounts = @import("../core/accounts.zig");
const discord = @import("discord.zig");
const Id = @import("../core/types.zig").Id;

const alloc = std.heap.c_allocator;

pub var list: accounts.List = .{};
/// QA e prints: nada vai para o disco nem para o chaveiro.
pub var memory_only = false;
/// Conta da sessão aberta agora (0 = nenhuma ainda).
pub var session: Id = 0;

fn configDir(buf: []u8) ?[]const u8 {
    if (c.SDL_getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/larpercord", .{std.mem.span(x)}) catch null;
    const home = c.SDL_getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/larpercord", .{std.mem.span(home)}) catch null;
}

fn listPath(buf: []u8) ?[:0]const u8 {
    var dbuf: [400]u8 = undefined;
    const dir = configDir(&dbuf) orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/accounts", .{dir}, 0) catch null;
}

fn tokenPath(buf: []u8, id: Id) ?[:0]const u8 {
    var dbuf: [400]u8 = undefined;
    const dir = configDir(&dbuf) orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/tokens/{d}", .{ dir, id }, 0) catch null;
}

/// Cria a pasta de `path` (só para o dono).
fn ensureParent(path: [:0]const u8) void {
    var buf: [512]u8 = undefined;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const dir = std.fmt.bufPrintSentinel(&buf, "{s}", .{path[0..slash]}, 0) catch return;
    if (std.mem.lastIndexOfScalar(u8, dir, '/')) |s2| {
        var pbuf: [512]u8 = undefined;
        const parent = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{dir[0..s2]}, 0) catch return;
        _ = c.mkdir(parent.ptr, 0o700);
    }
    _ = c.mkdir(dir.ptr, 0o700);
}

fn writePrivate(path: [:0]const u8, bytes: []const u8) bool {
    ensureParent(path);
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    _ = c.fchmod(fd, 0o600);
    return c.write(fd, bytes.ptr, bytes.len) == @as(isize, @intCast(bytes.len));
}

pub fn load() void {
    if (memory_only) return;
    var buf: [512]u8 = undefined;
    const path = listPath(&buf) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    list = accounts.List.parse(@as([*]const u8, @ptrCast(data))[0..size]);
}

pub fn save() void {
    if (memory_only) return;
    var buf: [512]u8 = undefined;
    const path = listPath(&buf) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    list.write(&out, alloc) catch return;
    _ = writePrivate(path, out.items);
}

fn trimmed(raw: []const u8) ?[:0]u8 {
    const s = std.mem.trim(u8, raw, " \n\r\t");
    if (s.len <= 20) return null;
    return alloc.dupeSentinel(u8, s, 0) catch null;
}

/// Token guardado de uma conta (alocado; quem recebe zera e libera).
pub fn tokenFor(acc: *const accounts.Account) ?[:0]u8 {
    if (memory_only) return null;
    if (acc.legacy) return discord.loadSavedToken();
    var cbuf: [160]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool lookup service larpercord-account account {d} 2>/dev/null", .{acc.id}, 0) catch return null;
    if (c.popen(cmd.ptr, "r")) |f| {
        var buf: [256]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, f);
        _ = c.pclose(f);
        defer std.crypto.secureZero(u8, &buf);
        if (trimmed(buf[0..n])) |t| return t;
    }
    var pbuf: [512]u8 = undefined;
    const path = tokenPath(&pbuf, acc.id) orelse return null;
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0 or st.st_mode & 0o077 != 0) return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer {
        std.crypto.secureZero(u8, @as([*]u8, @ptrCast(data))[0..size]);
        c.SDL_free(data);
    }
    return trimmed(@as([*]const u8, @ptrCast(data))[0..size]);
}

pub const Saved = enum { keyring, file, failed };

/// Guarda o token de uma conta (no chaveiro; sem ele, num arquivo 600).
pub fn storeToken(id: Id, token: []const u8) Saved {
    if (memory_only) return .failed;
    var cbuf: [200]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool store --label='larperCord (conta {d})' service larpercord-account account {d} 2>/dev/null", .{ id, id }, 0) catch return .failed;
    var pbuf: [512]u8 = undefined;
    const path = tokenPath(&pbuf, id);
    if (c.popen(cmd.ptr, "w")) |f| {
        const wrote = c.fwrite(token.ptr, 1, token.len, f);
        if (c.pclose(f) == 0 and wrote == token.len) {
            // Não deixa cópia velha em arquivo.
            if (path) |p| _ = c.unlink(p.ptr);
            return .keyring;
        }
    }
    const p = path orelse return .failed;
    return if (writePrivate(p, token)) .file else .failed;
}

/// Apaga o token de uma conta (do chaveiro e do arquivo).
pub fn forgetToken(acc: *const accounts.Account) void {
    if (memory_only) return;
    if (acc.legacy) return discord.forgetToken();
    var cbuf: [160]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&cbuf, "secret-tool clear service larpercord-account account {d} 2>/dev/null", .{acc.id}, 0)) |cmd| {
        if (c.popen(cmd.ptr, "r")) |f| _ = c.pclose(f);
    } else |_| {}
    var pbuf: [512]u8 = undefined;
    if (tokenPath(&pbuf, acc.id)) |p| _ = c.unlink(p.ptr);
}

/// Token para abrir o app: a conta usada da última vez, depois qualquer
/// outra guardada. `id` recebe de qual conta veio.
pub fn startupToken(id: *Id) ?[:0]u8 {
    if (list.find(list.active)) |a| if (tokenFor(a)) |t| {
        id.* = a.id;
        return t;
    };
    for (list.slice()) |*a| if (a.id != list.active) if (tokenFor(a)) |t| {
        id.* = a.id;
        return t;
    };
    return null;
}
