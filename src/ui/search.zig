//! Busca local (Ctrl+F ou a lupa do cabeçalho): procura nas mensagens que
//! estão na memória e no cache em disco (net/msg_cache.zig), a cada tecla e
//! sem falar com o Discord, então funciona offline. O texto já vai dobrado
//! (minúsculas, sem acento) uma vez por abertura (memória) ou por versão do
//! arquivo (disco, lido aos poucos, ~2 ms por quadro). Filtros:
//! from:nome, in:canal, has:link, has:imagem, has:arquivo.
//! Clicar num resultado abre a conversa e pula até a mensagem.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");
const sq = @import("../core/search_query.zig");
const msg_cache = @import("../net/msg_cache.zig");
const store_mod = @import("../core/store.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

pub var open = false;
var appearing = false;
var focus = false;
var query: [128]u8 = @splat(0);
var selected: usize = 0;
var first: usize = 0;
/// Muda a cada abertura: o campo do ImGui esquece o texto da vez anterior.
var gen: c_int = 0;

/// Mensagem que só está no disco (canal fora da memória).
/// `hay` e `who` já vêm "dobrados" (minúsculas, sem acento): cada tecla vira
/// só um `indexOf`, rápido mesmo com muitos MB de cache.
const Doc = struct { channel: Id, id: Id, author_name: []const u8, content: []const u8, files: []const u8, hay: []const u8, who: []const u8, image: bool, file: bool };
/// Um arquivo do cache já lido. Fica de uma abertura para a outra e só é
/// lido de novo quando o arquivo muda (data ou tamanho).
const DiskFile = struct {
    stamp: msg_cache.Stamp,
    arena: std.heap.ArenaAllocator,
    docs: []const Doc = &.{},
    bytes: usize = 0,
};
var disk_files: std.AutoHashMapUnmanaged(Id, *DiskFile) = .empty;
var disk_used: usize = 0;
/// Conta do índice (outra conta, outra pasta: começa do zero).
var disk_acct: [24]u8 = undefined;
var disk_acct_len: usize = 0;
/// Canais por conferir nesta abertura, um pouco por quadro.
var todo: std.ArrayList(Id) = .empty;
var todo_i: usize = 0;
pub var scanning = false;
var built = false;
/// Arquivos lidos do disco desde o início (o QA confere que reabrir não relê).
pub var disk_reads: u32 = 0;
/// Teto do que a busca guarda do disco.
const disk_budget: usize = 16 * 1024 * 1024;
/// Tempo de leitura do disco por quadro (a busca segue respondendo).
const step_ns: u64 = 2 * std.time.ns_per_ms;

/// Mensagem da memória já dobrada; `idx` vale enquanto a versão da conversa
/// não mudar.
const MemDoc = struct { idx: u32, hay: []const u8, who: []const u8, image: bool, file: bool };
const MemFold = struct { version: u32, len: usize, arena: std.heap.ArenaAllocator, docs: std.ArrayList(MemDoc) = .empty };
var mem_folds: std.AutoHashMapUnmanaged(Id, *MemFold) = .empty;

pub const Result = struct {
    channel: Id,
    id: Id,
    ts: i64,
    author: []const u8,
    where: []const u8,
    snippet: []const u8,
    /// Trecho que casou com o primeiro termo (bytes dentro de `snippet`).
    hl: [2]u16 = .{ 0, 0 },
    disk: bool = false,
};
var res_arena: std.heap.ArenaAllocator = .init(alloc);
pub var results: std.ArrayList(Result) = .empty;
/// Quantas casaram (antes do corte em `max_results`) e quantas vieram só do disco.
pub var found: usize = 0;
pub var found_disk: usize = 0;
const max_results = 200;

pub fn toggle() void {
    if (open) close() else start();
}

pub fn start() void {
    open = true;
    gen +%= 1;
    appearing = true;
    focus = false;
    @memset(&query, 0);
    selected = 0;
    first = 0;
    built = false;
    scanning = false;
}

/// Fecha. O que veio do disco fica para a próxima vez; o resto sai.
pub fn close() void {
    open = false;
    scanning = false;
    results.clearAndFree(alloc);
    _ = res_arena.reset(.free_all);
    var it = mem_folds.valueIterator();
    while (it.next()) |f| freeMemFold(f.*);
    mem_folds.clearAndFree(alloc);
    todo.clearAndFree(alloc);
    found = 0;
    found_disk = 0;
}

// --- Índice do disco --------------------------------------------------------------

fn dropFile(ch: Id) void {
    const kv = disk_files.fetchRemove(ch) orelse return;
    disk_used -|= kv.value.bytes;
    kv.value.arena.deinit();
    alloc.destroy(kv.value);
}

fn forgetDisk() void {
    var it = disk_files.valueIterator();
    while (it.next()) |f| {
        f.*.arena.deinit();
        alloc.destroy(f.*);
    }
    disk_files.clearRetainingCapacity();
    disk_used = 0;
}

/// Abriu: confere quais arquivos existem; a leitura vai em `stepDisk`.
fn beginDisk() void {
    built = true;
    const acct = msg_cache.account();
    if (!std.mem.eql(u8, acct, disk_acct[0..disk_acct_len])) {
        forgetDisk();
        const n = @min(acct.len, disk_acct.len);
        @memcpy(disk_acct[0..n], acct[0..n]);
        disk_acct_len = n;
    }
    todo.clearRetainingCapacity();
    todo_i = 0;
    msg_cache.listChannels(&todo);
    // Arquivo que sumiu (Apagar cache, teto do cache, cache desligado): sai do índice.
    if (disk_files.count() > 0) {
        var listed: std.AutoHashMapUnmanaged(Id, void) = .empty;
        defer listed.deinit(alloc);
        for (todo.items) |ch| listed.put(alloc, ch, {}) catch {};
        var gone: std.ArrayList(Id) = .empty;
        defer gone.deinit(alloc);
        var it = disk_files.keyIterator();
        while (it.next()) |ch| if (!listed.contains(ch.*)) gone.append(alloc, ch.*) catch {};
        for (gone.items) |ch| dropFile(ch);
    }
    scanning = true;
}

/// Lê arquivos novos ou mudados por até `step_ns`. Retorna se o índice mudou.
fn stepDisk(ctx: *d.Ctx) bool {
    const t0 = c.SDL_GetTicksNS();
    var changed = false;
    while (todo_i < todo.items.len) {
        if (c.SDL_GetTicksNS() - t0 >= step_ns) return changed;
        const ch = todo.items[todo_i];
        todo_i += 1;
        const cs = ctx.store.channel(ch) orelse continue;
        const st = msg_cache.stamp(ch) orelse {
            if (disk_files.contains(ch)) changed = true;
            dropFile(ch);
            continue;
        };
        if (disk_files.get(ch)) |f| {
            if (f.stamp.mtime_ns == st.mtime_ns and f.stamp.size == st.size) continue;
            dropFile(ch);
            changed = true;
        }
        // Na memória: a busca já olha lá (e é a versão mais nova).
        if (cs.history == .loaded or disk_used > disk_budget) continue;
        if (readFile(ctx, ch, st)) changed = true;
    }
    scanning = false;
    return changed;
}

fn readFile(ctx: *d.Ctx, ch: Id, st: msg_cache.Stamp) bool {
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const ta = tmp.allocator();
    const dec = msg_cache.readChannel(ta, ch) orelse return false;
    disk_reads += 1;
    const f = alloc.create(DiskFile) catch return false;
    f.* = .{ .stamp = st, .arena = .init(alloc) };
    const da = f.arena.allocator();
    // Nome de cada autor do arquivo, sem procurar na lista a cada mensagem.
    var names: std.AutoHashMapUnmanaged(Id, []const u8) = .empty;
    for (dec.users) |u| names.put(ta, u.id, u.name) catch {};
    const docs = da.alloc(Doc, dec.entries.len) catch {
        f.arena.deinit();
        alloc.destroy(f);
        return false;
    };
    var n: usize = 0;
    for (dec.entries) |*e| {
        const m = &e.msg;
        var name: []const u8 = names.get(m.author) orelse "?";
        if (ctx.store.user(m.author)) |u| name = u.name;
        var image = false;
        var file = false;
        var files: std.ArrayList(u8) = .empty;
        for (m.attachments) |a| {
            if (a.isImage()) image = true else if (!a.embed) file = true;
            files.appendSlice(da, a.filename) catch {};
            files.append(da, ' ') catch {};
        }
        var fb: [fold_max]u8 = undefined;
        var wb: [64]u8 = undefined;
        docs[n] = .{
            .channel = ch,
            .id = m.id,
            .author_name = da.dupe(u8, name) catch continue,
            .content = da.dupe(u8, m.content) catch continue,
            .files = files.items,
            .hay = da.dupe(u8, foldHay(&fb, m.content, files.items)) catch continue,
            .who = da.dupe(u8, sq.foldInto(&wb, name)) catch continue,
            .image = image,
            .file = file,
        };
        f.bytes += docs[n].content.len * 2 + docs[n].files.len + 96;
        n += 1;
    }
    f.docs = docs[0..n];
    disk_files.put(alloc, ch, f) catch {
        f.arena.deinit();
        alloc.destroy(f);
        return false;
    };
    disk_used += f.bytes;
    return n > 0;
}

// --- Memória, dobrada uma vez por abertura ------------------------------------------

fn freeMemFold(f: *MemFold) void {
    f.arena.deinit();
    alloc.destroy(f);
}

/// As mensagens da conversa já dobradas (refaz só se a conversa mudou).
fn memFold(ctx: *d.Ctx, cs: *const store_mod.ChannelState) ?*const MemFold {
    const gop = mem_folds.getOrPut(alloc, cs.info.id) catch return null;
    if (gop.found_existing) {
        const f = gop.value_ptr.*;
        if (f.version == cs.version and f.len == cs.messages.items.len) return f;
        f.docs = .empty;
        _ = f.arena.reset(.retain_capacity);
    } else {
        const f = alloc.create(MemFold) catch {
            _ = mem_folds.remove(cs.info.id);
            return null;
        };
        f.* = .{ .version = 0, .len = 0, .arena = .init(alloc) };
        gop.value_ptr.* = f;
    }
    const f = gop.value_ptr.*;
    f.version = cs.version;
    f.len = cs.messages.items.len;
    const fa = f.arena.allocator();
    f.docs.ensureTotalCapacity(fa, cs.messages.items.len) catch {};
    var fbuf: [256]u8 = undefined;
    var hay_buf: [fold_max]u8 = undefined;
    var who_buf: [64]u8 = undefined;
    for (cs.messages.items, 0..) |*m, i| {
        if (m.pending or m.msg.id == 0) continue;
        var image = false;
        var file = false;
        var fl: usize = 0;
        for (m.msg.attachments) |a| {
            if (a.isImage()) image = true else if (!a.embed) file = true;
            const n = @min(a.filename.len, fbuf.len - fl);
            @memcpy(fbuf[fl .. fl + n], a.filename[0..n]);
            fl += n;
            if (fl < fbuf.len) {
                fbuf[fl] = ' ';
                fl += 1;
            }
        }
        const hay = fa.dupe(u8, foldHay(&hay_buf, m.msg.content, fbuf[0..fl])) catch continue;
        const who = fa.dupe(u8, sq.foldInto(&who_buf, authorName(ctx, m.msg.author))) catch continue;
        f.docs.append(fa, .{ .idx = @intCast(i), .hay = hay, .who = who, .image = image, .file = file }) catch continue;
    }
    return f;
}

// --- Busca -------------------------------------------------------------------------

const Src = union(enum) { mem: *const store_mod.StoredMessage, disk: *const Doc };
const Hit = struct { id: Id, channel: Id, src: Src };

fn authorName(ctx: *d.Ctx, id: Id) []const u8 {
    return if (ctx.store.user(id)) |u| u.name else "?";
}

const fold_max = 4096;

/// Texto e nomes dos anexos, dobrados, num pedaço só.
fn foldHay(buf: *[fold_max]u8, content: []const u8, files: []const u8) []const u8 {
    const a = sq.foldInto(buf[0 .. fold_max - 260], content);
    buf[a.len] = '\n';
    const b = sq.foldInto(buf[a.len + 1 ..], files);
    return buf[0 .. a.len + 1 + b.len];
}

/// `hay` e `who` já dobrados (os termos da consulta também vêm assim).
fn matches(q: *const sq.Query, hay: []const u8, who: []const u8, image: bool, file: bool) bool {
    if (q.from_len > 0 and std.mem.indexOf(u8, who, q.from()) == null) return false;
    if (q.has_image and !image) return false;
    if (q.has_file and !file) return false;
    if (q.has_link and !sq.hasLink(hay)) return false;
    for (0..q.n_terms) |i| {
        if (std.mem.indexOf(u8, hay, q.term(i)) == null) return false;
    }
    return true;
}

fn channelOk(cs: *const store_mod.ChannelState, q: *const sq.Query) bool {
    if (cs.info.kind != .text) return false;
    return q.in_len == 0 or sq.containsFold(cs.info.name, q.in());
}

/// `keep`: o índice do disco cresceu; a seleção fica onde estava.
fn rebuild(ctx: *d.Ctx, keep: bool) void {
    results.clearRetainingCapacity();
    _ = res_arena.reset(.retain_capacity);
    found = 0;
    found_disk = 0;
    if (!keep) {
        selected = 0;
        first = 0;
    }
    const q = sq.Query.parse(std.mem.sliceTo(&query, 0));
    if (q.empty()) return;
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(alloc);
    var it = ctx.store.channels.valueIterator();
    while (it.next()) |csp| {
        const cs = csp.*;
        if (!channelOk(cs, &q)) continue;
        const f = memFold(ctx, cs) orelse continue;
        for (f.docs.items) |*doc| {
            if (!matches(&q, doc.hay, doc.who, doc.image, doc.file)) continue;
            const m = &cs.messages.items[doc.idx];
            hits.append(alloc, .{ .id = m.msg.id, .channel = cs.info.id, .src = .{ .mem = m } }) catch return;
        }
    }
    var fit = disk_files.iterator();
    while (fit.next()) |e| {
        const cs = ctx.store.channel(e.key_ptr.*) orelse continue;
        // Carregou depois de lido: a memória já respondeu.
        if (cs.history == .loaded or !channelOk(cs, &q)) continue;
        for (e.value_ptr.*.docs) |*doc| {
            if (!matches(&q, doc.hay, doc.who, doc.image, doc.file)) continue;
            hits.append(alloc, .{ .id = doc.id, .channel = doc.channel, .src = .{ .disk = doc } }) catch return;
            found_disk += 1;
        }
    }
    found = hits.items.len;
    // Mais novas primeiro (o ID do Discord cresce com o tempo).
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return a.id > b.id;
        }
    }.lt);
    const ra = res_arena.allocator();
    const term: []const u8 = if (q.n_terms > 0) q.term(0) else "";
    for (hits.items[0..@min(hits.items.len, max_results)]) |h| {
        const cs = ctx.store.channel(h.channel) orelse continue;
        var content: []const u8 = "";
        var author: []const u8 = "";
        var files: []const u8 = "";
        switch (h.src) {
            .mem => |m| {
                content = m.msg.content;
                author = authorName(ctx, m.msg.author);
                for (m.msg.attachments) |att| if (files.len == 0) {
                    files = att.filename;
                };
            },
            .disk => |doc| {
                content = doc.content;
                author = doc.author_name;
                files = doc.files;
            },
        }
        var r: Result = .{
            .channel = h.channel,
            .id = h.id,
            .ts = @divTrunc(types.snowflakeTime(h.id), 1000),
            .author = ra.dupe(u8, author) catch continue,
            .where = whereLabel(ctx, ra, cs) catch continue,
            .snippet = "",
            .disk = h.src == .disk,
        };
        snippet(ctx, ra, &r, content, files, term);
        results.append(alloc, r) catch return;
    }
}

fn whereLabel(ctx: *d.Ctx, a: std.mem.Allocator, cs: *const store_mod.ChannelState) ![]const u8 {
    if (cs.info.guild == 0) return if (cs.info.group) a.dupe(u8, cs.info.name) else std.fmt.allocPrint(a, "@{s}", .{cs.info.name});
    const g = ctx.store.guild(cs.info.guild);
    return std.fmt.allocPrint(a, "#{s} · {s}", .{ cs.info.name, if (g) |x| x.name else "" });
}

/// Texto legível de uma linha: menções viram @nome / #canal, quebras viram espaço.
fn clean(ctx: *d.Ctx, out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        if (s[i] == '<' and i + 2 < s.len and (s[i + 1] == '@' or s[i + 1] == '#')) if (std.mem.indexOfScalarPos(u8, s, i, '>')) |end| {
            var body = s[i + 2 .. end];
            if (body.len > 0 and (body[0] == '!' or body[0] == '&')) body = body[1..];
            if (std.fmt.parseInt(Id, body, 10)) |id| {
                const name: ?[]const u8 = if (s[i + 1] == '@') (if (ctx.store.user(id)) |u| u.name else null) else (if (ctx.store.channel(id)) |cs| cs.info.name else null);
                if (name) |nm| {
                    const piece = std.fmt.bufPrint(out[n..], "{c}{s}", .{ s[i + 1], nm }) catch break;
                    n += piece.len;
                    i = end + 1;
                    continue;
                }
            } else |_| {}
        };
        // Um caractere inteiro por vez (o corte nunca parte um UTF-8).
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (n + len > out.len or i + len > s.len) break;
        if (len == 1) {
            out[n] = if (s[i] == '\n' or s[i] == '\r' or s[i] == '\t') ' ' else s[i];
        } else @memcpy(out[n .. n + len], s[i .. i + len]);
        n += len;
        i += len;
    }
    return out[0..n];
}

fn snippet(ctx: *d.Ctx, a: std.mem.Allocator, r: *Result, content: []const u8, files: []const u8, term: []const u8) void {
    var buf: [800]u8 = undefined;
    var text = clean(ctx, &buf, content);
    if (text.len == 0) text = if (files.len > 0) std.fmt.bufPrint(&buf, "📎 {s}", .{files}) catch "" else "";
    var hl: [2]usize = .{ 0, 0 };
    if (term.len > 0) if (sq.findFold(text, term)) |m| {
        hl = m;
    };
    // Janela em volta do que casou.
    var from: usize = if (hl[0] > 50) hl[0] - 50 else 0;
    while (from > 0 and (text[from] & 0xC0) == 0x80) from -= 1;
    var end = @min(text.len, from + 180);
    while (end < text.len and end > from and (text[end] & 0xC0) == 0x80) end -= 1;
    const lead: []const u8 = if (from > 0) "…" else "";
    const out = std.fmt.allocPrint(a, "{s}{s}", .{ lead, text[from..end] }) catch return;
    r.snippet = out;
    if (hl[1] > hl[0] and hl[1] <= end) {
        r.hl = .{ @intCast(hl[0] - from + lead.len), @intCast(hl[1] - from + lead.len) };
    }
}

// --- Desenho ------------------------------------------------------------------------

fn choose(ctx: *d.Ctx, r: Result) void {
    ctx.act(.{ .select_channel = r.channel });
    ctx.act(.{ .jump_to = r.id });
    close();
}

fn beginWindow(id: [*:0]const u8, r: d.Rect) *c.ImDrawList {
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin(id, null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    return c.ImGui_GetWindowDrawList();
}

pub fn draw(ctx: *d.Ctx) void {
    if (!open) return;
    const k = anim.to(anim.id("msg-search", 0), 1, 22);
    // Outra camada por cima (paleta, configurações): a busca dá lugar.
    if (ctx.st.palette.open or ctx.st.settings.open) return close();
    if (!built) {
        beginDisk();
        rebuild(ctx, false);
    }
    if (scanning) {
        if (stepDisk(ctx)) rebuild(ctx, true);
        // Continua no próximo quadro sem esperar evento.
        anim.at(ctx.now_ms);
    }
    const win = ctx.win;
    // Fundo que pega o clique fora da caixa (fecha a busca).
    const bdl = beginWindow("##search-backdrop", win);
    d.rect(bdl, win, d.Rgba.black.alpha(0.45 * k), 0);
    c.ImGui_SetCursorScreenPos(d.v(win.x, win.y));
    _ = c.ImGui_InvisibleButton("##sbd", d.v(win.w, win.h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
    const outside = c.ImGui_IsItemClickedEx(0) or c.ImGui_IsItemClickedEx(1);
    c.ImGui_End();
    if (outside) return close();

    const bw = @min(720, win.w - 40);
    const bh = @min(560, win.h - 60);
    const box: d.Rect = .{ .x = win.x + (win.w - bw) / 2, .y = win.y + @max(20, win.h * 0.1) - (1 - k) * 12, .w = bw, .h = bh };
    const dl = beginWindow("##search", box);
    defer c.ImGui_End();
    appearing = false;
    const saved_dl = ctx.dl;
    ctx.dl = dl;
    defer ctx.dl = saved_dl;
    const radius = @max(ctx.th.radius + 6, 4);
    d.shadow(dl, box, radius, 24, ctx.col(.shadow).alpha(k));
    d.rect(dl, box, ctx.col(.overlay).mix(ctx.col(.elevated), 0.35), radius);
    d.border(dl, box, ctx.col(.border), radius, 1);

    // Campo de busca.
    const font = ctx.ui.get(.regular);
    const fs: f32 = 17;
    icons.search(dl, box.x + 24, box.y + 28, ctx.col(.muted).u());
    const ir: d.Rect = .{ .x = box.x + 42, .y = box.y + 14, .w = box.w - 60, .h = 30 };
    qa.mark(ir, "search-input", .{});
    c.ImGui_SetCursorScreenPos(d.v(ir.x, ir.y));
    c.ImGui_PushFontFloat(font, fs);
    if (!focus) {
        c.ImGui_SetKeyboardFocusHere();
        focus = true;
    }
    c.ImGui_SetNextItemWidth(ir.w);
    c.ImGui_PushIDInt(gen);
    defer c.ImGui_PopID();
    if (c.ImGui_InputTextWithHint("##sq", i18n.trZ("Buscar mensagens…  from:nome  in:canal  has:link", "Search messages…  from:name  in:channel  has:link").ptr, &query, query.len, 0)) rebuild(ctx, false);
    c.ImGui_PopFont();
    d.line(dl, box.x, box.y + 58, box.right(), box.y + 58, ctx.col(.border), 1);

    const n = results.items.len;
    // O índice do disco cresceu e a lista encolheu por baixo da seleção.
    if (selected >= n) selected = 0;
    const row_h: f32 = 54;
    const list_top = box.y + 64;
    const foot_h: f32 = 40;
    const visible: usize = @max(1, @as(usize, @intFromFloat((box.bottom() - foot_h - list_top) / row_h)));
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_DownArrow) and n > 0) selected = (selected + 1) % n;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow) and n > 0) selected = (selected + n - 1) % n;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) return close();
    if ((c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter)) and n > 0) return choose(ctx, results.items[selected]);
    // Roda do mouse anda na lista; as setas trazem a seleção para a tela.
    const list_r: d.Rect = .{ .x = box.x, .y = list_top, .w = box.w, .h = @as(f32, @floatFromInt(visible)) * row_h };
    if (ctx.hovering(list_r) and ctx.io.*.MouseWheel != 0 and n > visible) {
        const step: i32 = if (ctx.io.*.MouseWheel > 0) -3 else 3;
        first = @intCast(std.math.clamp(@as(i32, @intCast(first)) + step, 0, @as(i32, @intCast(n - visible))));
    }
    if (selected < first) first = selected;
    if (selected >= first + visible) first = selected + 1 - visible;
    if (n > visible) first = @min(first, n - visible) else first = 0;

    const bold = ctx.ui.get(.semibold);
    const now_s = @divTrunc(ctx.now_ms, 1000);
    var y = list_top;
    for (results.items[first..@min(n, first + visible)], first..) |r, i| {
        const rr: d.Rect = .{ .x = box.x + 8, .y = y, .w = box.w - 16, .h = row_h - 4 };
        const hb = d.hit(ctx, 0x5e00 + i, rr);
        qa.mark(rr, "search-result:{d}", .{i});
        if (hb.hovered and (ctx.io.*.MouseDelta.x != 0 or ctx.io.*.MouseDelta.y != 0)) selected = i;
        if (hb.clicked) return choose(ctx, r);
        const sel = i == selected;
        if (sel) d.rect(dl, rr, ctx.col(.accent).alpha(0.16), ctx.th.radius + 2);
        if (sel) d.rect(dl, .{ .x = rr.x, .y = rr.y + 8, .w = 3, .h = rr.h - 16 }, ctx.col(.accent), 2);
        // Linha 1: autor · onde                                  quando
        var tb: [48]u8 = undefined;
        const when = w.stamp(&tb, r.ts, now_s);
        const ww = d.width(font, 12, when);
        const aw = d.textClipped(dl, bold, 14, rr.x + 14, rr.y + 6, ctx.col(.text), r.author, 220);
        var tag_w: f32 = 0;
        if (r.disk) {
            // Veio do disco (a conversa não está na memória agora).
            const tag = i18n.tr("cache", "cache");
            tag_w = d.width(font, 11, tag) + 12;
            const tr: d.Rect = .{ .x = rr.right() - 14 - ww - 10 - tag_w, .y = rr.y + 6, .w = tag_w, .h = 17 };
            d.rect(dl, tr, ctx.col(.faint).alpha(0.18), 4);
            d.text(dl, font, 11, tr.x + 6, d.centerY(tr, 11), ctx.col(.muted), tag);
            tag_w += 10;
        }
        _ = d.textClipped(dl, font, 13, rr.x + 14 + aw + 8, rr.y + 7, ctx.col(.faint), r.where, @max(0, rr.w - aw - ww - tag_w - 50));
        d.text(dl, font, 12, rr.right() - 14 - ww, rr.y + 8, ctx.col(.faint), when);
        // Linha 2: o trecho, com o que casou em destaque.
        snippetLine(ctx, dl, font, rr.x + 14, rr.y + 28, rr.w - 28, r);
        y += row_h;
    }
    if (n == 0) {
        const empty = std.mem.sliceTo(&query, 0).len == 0;
        var yy = list_top + 16;
        if (empty) {
            d.text(dl, bold, 15, box.x + 24, yy, ctx.col(.text), i18n.tr("Busca nas mensagens deste computador", "Search the messages on this computer"));
            yy += 30;
            const tips = [_][2][]const u8{
                .{ "from:ana", i18n.tr("mensagens de quem tem \"ana\" no nome", "messages from someone with \"ana\" in their name") },
                .{ "in:geral", i18n.tr("só nos canais com \"geral\" no nome", "only in channels with \"geral\" in the name") },
                .{ "has:link", i18n.tr("com link", "with a link") },
                .{ "has:imagem", i18n.tr("com imagem", "with an image") },
                .{ "has:arquivo", i18n.tr("com arquivo anexado", "with an attached file") },
            };
            for (tips) |t| {
                d.text(dl, ctx.mono.get(.regular), 13.5, box.x + 32, yy, ctx.col(.accent).mix(ctx.col(.text), 0.3), t[0]);
                d.text(dl, font, 13.5, box.x + 160, yy, ctx.col(.muted), t[1]);
                yy += 26;
            }
            yy += 8;
            _ = d.textClipped(dl, font, 13, box.x + 24, yy, ctx.col(.faint), i18n.tr("Procura no que está aberto e no cache em disco, sem internet. Mensagens que nunca passaram pela tela não aparecem.", "Looks through what's open and the on-disk cache, no internet needed. Messages that never reached the screen won't show up."), box.w - 48);
        } else d.text(dl, font, 15, box.x + 24, yy, ctx.col(.faint), i18n.tr("Nada encontrado.", "Nothing found."));
    }
    // Rodapé: quantas e de onde.
    const fy = box.bottom() - foot_h;
    d.line(dl, box.x, fy, box.right(), fy, ctx.col(.border), 1);
    var cb: [160]u8 = undefined;
    const count = if (found > n)
        i18n.fmt(&cb, "{d} resultados (mostrando os {d} mais novos) · {d} do cache em disco", "{d} results (showing the newest {d}) · {d} from the disk cache", .{ found, n, found_disk })
    else
        i18n.fmt(&cb, "{d} resultados · {d} do cache em disco", "{d} results · {d} from the disk cache", .{ found, found_disk });
    if (std.mem.sliceTo(&query, 0).len > 0) d.text(dl, font, 12.5, box.x + 18, d.centerY(.{ .x = 0, .y = fy, .w = 0, .h = foot_h }, 12.5), ctx.col(.faint), count);
    const keys = i18n.tr("↑↓ escolher · Enter abrir · Esc fechar", "↑↓ pick · Enter open · Esc close");
    const kw = d.width(font, 12.5, keys);
    d.text(dl, font, 12.5, box.right() - 18 - kw, d.centerY(.{ .x = 0, .y = fy, .w = 0, .h = foot_h }, 12.5), ctx.col(.faint), keys);
}

fn snippetLine(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, x: f32, y: f32, max_w: f32, r: Result) void {
    const fs: f32 = 13.5;
    const s = r.snippet;
    const col = ctx.col(.text).mix(ctx.col(.muted), 0.35);
    if (r.hl[1] <= r.hl[0] or r.hl[1] > s.len) {
        _ = d.textClipped(dl, font, fs, x, y, col, s, max_w);
        return;
    }
    const a = s[0..r.hl[0]];
    const m = s[r.hl[0]..r.hl[1]];
    const b = s[r.hl[1]..];
    const wa = d.textClipped(dl, font, fs, x, y, col, a, max_w);
    if (wa >= max_w - 4) return;
    const bold = ctx.ui.get(.semibold);
    const wm = d.width(bold, fs, m);
    d.rect(dl, .{ .x = x + wa - 1, .y = y - 1, .w = @min(wm, max_w - wa) + 2, .h = fs * 1.3 }, ctx.col(.accent).alpha(0.22), 3);
    const wm2 = d.textClipped(dl, bold, fs, x + wa, y, ctx.col(.text), m, max_w - wa);
    if (wa + wm2 >= max_w - 4) return;
    _ = d.textClipped(dl, font, fs, x + wa + wm2, y, col, b, max_w - wa - wm2);
}
