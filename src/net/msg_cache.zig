//! Cache de mensagens em disco: as últimas mensagens vistas de cada canal,
//! para a conversa aparecer na hora ao abrir (o histórico de verdade chega
//! depois e substitui) e para a busca local funcionar sem rede.
//!
//! Fica em $XDG_CACHE_HOME/larpercord/messages/<conta>/<canal>.lcm (formato
//! em core/cache_format.zig). Pastas com permissão 700 e arquivos com 600:
//! só o seu usuário lê. Teto de `total_cap` somando tudo (as conversas
//! esquecidas há mais tempo saem primeiro) e de `channel_msgs` por canal.
//!
//! Grava só quando a conversa mudou: ao trocar de canal, uma vez por minuto
//! (no tique do relógio, que já acorda o app), antes de a conversa sair da
//! memória e ao fechar o app. Nada aqui acorda o laço.
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const format = @import("../core/cache_format.zig");
const store_mod = @import("../core/store.zig");
const Store = store_mod.Store;
const ChannelState = store_mod.ChannelState;
const Id = types.Id;

const alloc = std.heap.c_allocator;

pub const total_cap: u64 = 50 * 1024 * 1024;
pub const channel_msgs: usize = 200;
pub const channel_bytes: usize = 1024 * 1024;
const ext = ".lcm";

/// Configurações → Privacidade → "Guardar mensagens no disco".
pub var enabled = true;
/// Desligado de vez (prints da documentação: sempre os mesmos dados).
pub var off = false;

var root_buf: [448]u8 = undefined;
var root_len: usize = 0;
/// Pasta da conta conectada: o ID dela, ou "demo".
var acct_buf: [24]u8 = undefined;
var acct_len: usize = 0;
/// Versão de cada conversa da última vez que foi gravada (ou lida).
var saved: std.AutoHashMapUnmanaged(Id, u32) = .empty;
var total: u64 = 0;
var total_known = false;
/// Conversas que abriram pelo cache (o QA confere).
pub var restored: u32 = 0;

/// `qa`: tudo em qa-out/cache (o QA nunca mexe no cache de verdade).
pub fn init(qa: bool) void {
    const r: []const u8 = if (qa)
        std.fmt.bufPrint(&root_buf, "qa-out/cache", .{}) catch ""
    else if (c.SDL_getenv("XDG_CACHE_HOME")) |x|
        std.fmt.bufPrint(&root_buf, "{s}/larpercord/messages", .{std.mem.span(x)}) catch ""
    else if (c.SDL_getenv("HOME")) |h|
        std.fmt.bufPrint(&root_buf, "{s}/.cache/larpercord/messages", .{std.mem.span(h)}) catch ""
    else
        "";
    root_len = r.len;
}

pub fn deinit() void {
    saved.deinit(alloc);
}

fn root() []const u8 {
    return root_buf[0..root_len];
}

fn usable() bool {
    return enabled and !off and root_len > 0 and acct_len > 0;
}

/// Conta da sessão (0 = demonstração). As conversas ficam separadas por conta.
pub fn setAccount(id: Id) void {
    const s = if (id == 0) std.fmt.bufPrint(&acct_buf, "demo", .{}) catch "" else std.fmt.bufPrint(&acct_buf, "{d}", .{id}) catch "";
    acct_len = s.len;
    saved.clearRetainingCapacity();
}

/// Sem conta: nada é lido nem gravado (a conta aberta está sendo removida).
pub fn detach() void {
    acct_len = 0;
    saved.clearRetainingCapacity();
}

fn channelPath(buf: []u8, ch: Id, suffix: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}/{d}{s}{s}", .{ root(), acct_buf[0..acct_len], ch, ext, suffix }, 0) catch null;
}

/// Cria a pasta da conta (e as de cima). As nossas (…/larpercord,
/// …/messages e a da conta) ficam só para o dono; as que já existiam fora
/// delas (o ~/.cache) não mudam de permissão.
fn ensureDirs() bool {
    var buf: [512]u8 = undefined;
    const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ root(), acct_buf[0..acct_len] }, 0) catch return false;
    var i: usize = 1;
    while (i <= full.len) : (i += 1) {
        if (i < full.len and full[i] != '/') continue;
        const keep = buf[i];
        buf[i] = 0;
        const p: [*:0]const u8 = @ptrCast(&buf);
        _ = c.mkdir(p, 0o700);
        const part = full[0..i];
        const ours = i >= root_len or std.mem.endsWith(u8, part, "/larpercord");
        if (ours) _ = c.chmod(p, 0o700);
        buf[i] = keep;
    }
    var st: c.struct_stat = undefined;
    return c.stat(full.ptr, &st) == 0;
}

fn fileSize(path: [*:0]const u8) u64 {
    var st: c.struct_stat = undefined;
    if (c.stat(path, &st) != 0) return 0;
    return @intCast(@max(st.st_size, 0));
}

/// Grava inteiro num .tmp e troca de nome: nunca fica um arquivo pela metade.
fn writeFile(path: [:0]const u8, tmp: [:0]const u8, bytes: []const u8) bool {
    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    _ = c.fchmod(fd, 0o600);
    var off_: usize = 0;
    while (off_ < bytes.len) {
        const n = c.write(fd, bytes[off_..].ptr, bytes.len - off_);
        if (n <= 0) {
            _ = c.close(fd);
            _ = c.unlink(tmp.ptr);
            return false;
        }
        off_ += @intCast(n);
    }
    _ = c.close(fd);
    if (c.rename(tmp.ptr, path.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    return true;
}

// --- Leitura: a conversa aparece na hora ------------------------------------------

fn dupeAttachments(list: []const types.Attachment) ![]const types.Attachment {
    if (list.len == 0) return &.{};
    const out = try alloc.alloc(types.Attachment, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |a| types.freeAttachment(alloc, a);
        alloc.free(out);
    }
    for (list) |a| {
        out[n] = .{
            .url = try alloc.dupe(u8, a.url),
            .filename = undefined,
            .width = a.width,
            .height = a.height,
            .size = a.size,
            .animated = a.animated,
            .embed = a.embed,
            .video = a.video,
        };
        out[n].filename = alloc.dupe(u8, a.filename) catch |e| {
            alloc.free(out[n].url);
            return e;
        };
        out[n].still = if (a.still.len > 0) alloc.dupe(u8, a.still) catch "" else "";
        out[n].link = if (a.link.len > 0) alloc.dupe(u8, a.link) catch "" else "";
        n += 1;
    }
    return out;
}

/// Lê o arquivo de um canal (tudo em `arena`). null = não tem ou estragou.
pub fn readChannel(arena: std.mem.Allocator, ch: Id) ?format.Decoded {
    if (!usable()) return null;
    var pbuf: [512]u8 = undefined;
    const path = channelPath(&pbuf, ch, "") orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    const bytes = @as([*]const u8, @ptrCast(data))[0..size];
    const dec = format.decode(arena, bytes) catch {
        // Estragado (gravação interrompida, versão antiga): sai do caminho.
        _ = c.unlink(path.ptr);
        total_known = false;
        return null;
    };
    if (dec.channel != ch) return null;
    return dec;
}

/// Abrindo uma conversa ainda não carregada: mostra o que estava no disco.
pub fn restore(store: *Store, cs: *ChannelState) void {
    if (!usable() or cs.history == .loaded) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const dec = readChannel(arena.allocator(), cs.info.id) orelse return;
    if (dec.entries.len == 0) return;
    // Autores que esta sessão ainda não viu (o nome vem junto no cache).
    for (dec.users) |u| if (store.user(u.id) == null) {
        const name = alloc.dupe(u8, u.name) catch continue;
        const avatar: ?[]const u8 = if (u.avatar.len > 0) alloc.dupe(u8, u.avatar) catch null else null;
        store.apply(.{ .user_upsert = .{ .id = u.id, .name = name, .avatar = avatar } }, 0) catch {};
    };
    const msgs = alloc.alloc(types.Message, dec.entries.len) catch return;
    defer alloc.free(msgs);
    const reacts = alloc.alloc([]const types.Reaction, dec.entries.len) catch return;
    defer alloc.free(reacts);
    var n: usize = 0;
    for (dec.entries) |*e| {
        var m = e.msg;
        m.content = alloc.dupe(u8, e.msg.content) catch continue;
        m.attachments = dupeAttachments(e.msg.attachments) catch {
            alloc.free(m.content);
            continue;
        };
        m.embeds = &.{};
        msgs[n] = m;
        reacts[n] = e.reactions[0..e.n_reactions];
        n += 1;
    }
    store.loadCached(cs, msgs[0..n], reacts[0..n]) catch return;
    saved.put(alloc, cs.info.id, cs.version) catch {};
    restored += 1;
}

// --- Escrita ---------------------------------------------------------------------

fn dirty(cs: *const ChannelState) bool {
    return cs.history == .loaded and (saved.get(cs.info.id) orelse cs.version +% 1) != cs.version;
}

/// Grava as últimas mensagens da conversa (as pendentes e as apagadas, do
/// registro de mensagens, ficam de fora).
pub fn save(store: *Store, cs: *ChannelState) void {
    if (!usable() or cs.history != .loaded) return;
    const items = cs.messages.items;
    var pick: [channel_msgs]u32 = undefined;
    var n: usize = 0;
    var bytes: usize = 0;
    var i = items.len;
    while (i > 0 and n < channel_msgs) {
        i -= 1;
        const m = &items[i];
        if (m.pending or m.msg.id == 0 or m.deleted) continue;
        var est: usize = 48 + m.msg.content.len;
        for (m.msg.attachments) |a| est += 24 + a.url.len + a.filename.len + a.still.len + a.link.len;
        if (n > 0 and bytes + est > channel_bytes) break;
        bytes += est;
        pick[n] = @intCast(i);
        n += 1;
    }
    var pbuf: [512]u8 = undefined;
    var tbuf: [520]u8 = undefined;
    const path = channelPath(&pbuf, cs.info.id, "") orelse return;
    const tmp = channelPath(&tbuf, cs.info.id, ".tmp") orelse return;
    const before = fileSize(path.ptr);
    if (n == 0) {
        // Conversa vazia: nada a guardar (nem o que havia antes).
        if (before > 0 and c.unlink(path.ptr) == 0) total -|= before;
        saved.put(alloc, cs.info.id, cs.version) catch {};
        return;
    }
    // Autores, sem repetir (o nome aparece mesmo sem a sessão conhecer a pessoa).
    var authors: [channel_msgs]Id = undefined;
    var n_auth: usize = 0;
    for (pick[0..n]) |k| {
        const a = items[k].msg.author;
        if (std.mem.indexOfScalar(Id, authors[0..n_auth], a) == null) {
            authors[n_auth] = a;
            n_auth += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.ensureTotalCapacity(alloc, bytes + 64 * n_auth + 64) catch return;
    const w: format.Writer = .{ .out = &out, .gpa = alloc };
    var known: u32 = 0;
    for (authors[0..n_auth]) |a| {
        if (store.user(a) != null) known += 1;
    }
    w.begin(cs.info.id, known) catch return;
    for (authors[0..n_auth]) |a| if (store.user(a)) |u| {
        w.user(.{ .id = a, .name = u.name, .avatar = u.avatar orelse "" }) catch return;
    };
    w.beginMessages(@intCast(n)) catch return;
    // `pick` está do fim para o começo; o arquivo vai na ordem da conversa.
    var k = n;
    while (k > 0) {
        k -= 1;
        const m = &items[pick[k]];
        w.message(&m.msg, m.reactionSlice()) catch return;
    }
    if (!ensureDirs()) return;
    if (!writeFile(path, tmp, out.items)) return;
    saved.put(alloc, cs.info.id, cs.version) catch {};
    if (total_known) total = total - @min(total, before) + out.items.len;
    if (totalBytes() > total_cap) enforceCap();
}

/// Grava o que mudou desde a última vez.
pub fn flushDirty(store: *Store) void {
    if (!usable()) return;
    var it = store.channels.valueIterator();
    while (it.next()) |cs| if (dirty(cs.*)) save(store, cs.*);
}

/// Store.on_evict: a conversa vai sair da memória; o disco fica com ela.
pub fn onEvict(store: *Store, cs: *ChannelState) void {
    if (usable() and dirty(cs)) save(store, cs);
}

// --- Tamanho, teto e limpeza --------------------------------------------------------

const FileInfo = struct { path: [:0]u8, size: u64, mtime: i64 };

/// Passa por todos os arquivos de cache (de todas as contas).
fn walk(cb: anytype) void {
    if (root_len == 0) return;
    var rbuf: [512]u8 = undefined;
    const r = std.fmt.bufPrintSentinel(&rbuf, "{s}", .{root()}, 0) catch return;
    const top = c.opendir(r.ptr) orelse return;
    defer _ = c.closedir(top);
    while (c.readdir(top)) |ent| {
        const sub = std.mem.sliceTo(&ent.*.d_name, 0);
        if (sub.len == 0 or sub[0] == '.') continue;
        var sbuf: [512]u8 = undefined;
        const sp = std.fmt.bufPrintSentinel(&sbuf, "{s}/{s}", .{ root(), sub }, 0) catch continue;
        const dir = c.opendir(sp.ptr) orelse continue;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |fe| {
            const name = std.mem.sliceTo(&fe.*.d_name, 0);
            if (!std.mem.endsWith(u8, name, ext) and !std.mem.endsWith(u8, name, ".tmp")) continue;
            var fbuf: [560]u8 = undefined;
            const fp = std.fmt.bufPrintSentinel(&fbuf, "{s}/{s}", .{ sp, name }, 0) catch continue;
            var st: c.struct_stat = undefined;
            if (c.stat(fp.ptr, &st) != 0) continue;
            cb.file(fp, @intCast(@max(st.st_size, 0)), st.st_mtim.tv_sec);
        }
    }
}

/// Quanto o cache ocupa no disco (todas as contas).
pub fn totalBytes() u64 {
    if (!total_known) {
        const Sum = struct {
            n: u64 = 0,
            fn file(s: *@This(), _: [:0]const u8, size: u64, _: i64) void {
                s.n += size;
            }
        };
        var sum: Sum = .{};
        walk(&sum);
        total = sum.n;
        total_known = true;
    }
    return total;
}

/// Passou do teto: apaga as conversas esquecidas há mais tempo até sobrar folga.
fn enforceCap() void {
    const List = struct {
        items: std.ArrayList(FileInfo) = .empty,
        fn file(l: *@This(), p: [:0]const u8, size: u64, mtime: i64) void {
            const copy = alloc.dupeSentinel(u8, p, 0) catch return;
            l.items.append(alloc, .{ .path = copy, .size = size, .mtime = mtime }) catch alloc.free(copy);
        }
    };
    var l: List = .{};
    defer {
        for (l.items.items) |f| alloc.free(f.path);
        l.items.deinit(alloc);
    }
    walk(&l);
    std.mem.sort(FileInfo, l.items.items, {}, struct {
        fn lt(_: void, a: FileInfo, b: FileInfo) bool {
            return a.mtime < b.mtime;
        }
    }.lt);
    var sum: u64 = 0;
    for (l.items.items) |f| sum += f.size;
    for (l.items.items) |f| {
        if (sum <= total_cap / 10 * 9) break;
        if (c.unlink(f.path.ptr) == 0) sum -= f.size;
    }
    total = sum;
    total_known = true;
    // O que saiu do disco é gravado de novo se a conversa mudar.
    saved.clearRetainingCapacity();
}

fn removeDir(path: [:0]const u8) void {
    const dir = c.opendir(path.ptr) orelse return;
    while (c.readdir(dir)) |fe| {
        const name = std.mem.sliceTo(&fe.*.d_name, 0);
        if (std.mem.endsWith(u8, name, ext) or std.mem.endsWith(u8, name, ".tmp")) {
            var fbuf: [560]u8 = undefined;
            const fp = std.fmt.bufPrintSentinel(&fbuf, "{s}/{s}", .{ path, name }, 0) catch continue;
            _ = c.unlink(fp.ptr);
        }
    }
    _ = c.closedir(dir);
    _ = c.rmdir(path.ptr);
}

/// "Apagar cache": tudo, de todas as contas. O que está na tela agora não é
/// gravado de novo; só o que mudar daqui para a frente (se continuar ligado).
pub fn clearAll(store: *Store) void {
    if (root_len == 0) return;
    var rbuf: [512]u8 = undefined;
    const r = std.fmt.bufPrintSentinel(&rbuf, "{s}", .{root()}, 0) catch return;
    if (c.opendir(r.ptr)) |top| {
        var names: std.ArrayList([:0]u8) = .empty;
        defer {
            for (names.items) |nm| alloc.free(nm);
            names.deinit(alloc);
        }
        while (c.readdir(top)) |ent| {
            const sub = std.mem.sliceTo(&ent.*.d_name, 0);
            if (sub.len == 0 or sub[0] == '.') continue;
            const p = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ root(), sub }, 0) catch continue;
            names.append(alloc, p) catch alloc.free(p);
        }
        _ = c.closedir(top);
        for (names.items) |p| removeDir(p);
    }
    total = 0;
    total_known = true;
    saved.clearRetainingCapacity();
    var it = store.channels.valueIterator();
    while (it.next()) |cs| saved.put(alloc, cs.*.info.id, cs.*.version) catch {};
}

/// Conta removida: o cache dela vai junto.
pub fn removeAccount(id: Id) void {
    if (root_len == 0 or id == 0) return;
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{d}", .{ root(), id }, 0) catch return;
    removeDir(p);
    total_known = false;
}

/// Canais da conta atual que têm cache em disco (para a busca).
pub fn listChannels(out: *std.ArrayList(Id)) void {
    if (!usable()) return;
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ root(), acct_buf[0..acct_len] }, 0) catch return;
    const dir = c.opendir(p.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |fe| {
        const name = std.mem.sliceTo(&fe.*.d_name, 0);
        if (!std.mem.endsWith(u8, name, ext)) continue;
        const id = std.fmt.parseInt(Id, name[0 .. name.len - ext.len], 10) catch continue;
        out.append(alloc, id) catch return;
    }
}

/// "12,3 MB" / "840 KB" (vírgula no português).
pub fn formatSize(buf: []u8, bytes: u64, en: bool) []const u8 {
    const sep: u8 = if (en) '.' else ',';
    if (bytes >= 1024 * 1024) {
        const tenths = bytes * 10 / (1024 * 1024);
        return std.fmt.bufPrint(buf, "{d}{c}{d} MB", .{ tenths / 10, sep, tenths % 10 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} KB", .{(bytes + 1023) / 1024}) catch "";
}
