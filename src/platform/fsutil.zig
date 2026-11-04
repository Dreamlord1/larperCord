//! Arquivos só do dono: configurações (o proxy pode ter usuário:senha),
//! rascunhos, mensagens salvas, cache de mensagens e tokens. Todos gravam
//! do mesmo jeito: num .tmp com permissão 600, inteiro (write parcial
//! continua de onde parou), `fsync` e depois troca de nome; uma queda no meio
//! nunca deixa o arquivo pela metade nem com a permissão padrão.
const std = @import("std");
const c = @import("c");

/// $XDG_CONFIG_HOME/larpercord/<nome> (ou ~/.config/larpercord/<nome>);
/// `nome` vazio dá a própria pasta.
pub fn configPath(buf: []u8, name: []const u8) ?[:0]const u8 {
    const sep: []const u8 = if (name.len > 0) "/" else "";
    if (c.SDL_getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrintSentinel(buf, "{s}/larpercord{s}{s}", .{ std.mem.span(x), sep, name }, 0) catch null;
    const home = c.SDL_getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/larpercord{s}{s}", .{ std.mem.span(home), sep, name }, 0) catch null;
}

/// Cria a pasta (e as de cima que faltarem) só para o dono. As nossas
/// (…/larpercord e o que fica dentro dela) voltam para 700 mesmo se já
/// existiam; as de fora (o ~/.config, o ~/.cache) não mudam de permissão.
pub fn ensureDir(dir: []const u8) bool {
    var buf: [512]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len) return false;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var ours = false;
    var start: usize = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '/') continue;
        const part = dir[start..i];
        start = i + 1;
        if (std.mem.eql(u8, std.mem.trimStart(u8, part, "/"), "larpercord")) ours = true;
        const keep = buf[i];
        buf[i] = 0;
        const p: [*:0]const u8 = @ptrCast(&buf);
        _ = c.mkdir(p, 0o700);
        if (ours) _ = c.chmod(p, 0o700);
        buf[i] = keep;
    }
    var st: c.struct_stat = undefined;
    return c.stat(@ptrCast(&buf), &st) == 0;
}

/// Grava `bytes` em `path` (só o dono lê), criando a pasta se faltar.
pub fn writePrivate(path: [:0]const u8, bytes: []const u8) bool {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| if (slash > 0) {
        if (!ensureDir(path[0..slash])) return false;
    };
    return replace(path, bytes, true);
}

/// Como `writePrivate`, quando quem chama já sabe que a pasta existe e o
/// conteúdo pode ser refeito (cache): sem esperar o disco confirmar.
pub fn replacePrivate(path: [:0]const u8, bytes: []const u8) bool {
    return replace(path, bytes, false);
}

/// Um arquivo nosso que não deu para ler fica guardado como `<nome>.bad`:
/// o próximo salvamento regravaria por cima o que a pessoa tinha ali.
pub fn keepBroken(path: [:0]const u8) void {
    var buf: [528]u8 = undefined;
    const bad = std.fmt.bufPrintSentinel(&buf, "{s}.bad", .{path}, 0) catch return;
    if (c.rename(path.ptr, bad.ptr) == 0) std.log.warn("{s} estava ilegível; guardei uma cópia em {s}", .{ path, bad });
}

fn replace(path: [:0]const u8, bytes: []const u8, durable: bool) bool {
    var tbuf: [528]u8 = undefined;
    // Com o PID: duas instâncias abertas não escrevem no mesmo temporário.
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.{d}.tmp", .{ path, c.getpid() }, 0) catch return false;
    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    // Um .tmp que sobrou de antes pode ter outra permissão.
    _ = c.fchmod(fd, 0o600);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) {
            _ = c.close(fd);
            _ = c.unlink(tmp.ptr);
            return false;
        }
        off += @intCast(n);
    }
    // Sem isto, uma queda de energia logo depois pode deixar o arquivo vazio.
    if (durable and c.fsync(fd) != 0) {
        _ = c.close(fd);
        _ = c.unlink(tmp.ptr);
        return false;
    }
    if (c.close(fd) != 0 or c.rename(tmp.ptr, path.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    return true;
}
