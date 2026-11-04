//! Palavras de alerta, filtro de palavras, pessoas ignoradas e modo foco.
//! Tudo local: nada disso vai para o Discord. Fica salvo no settings.kdl,
//! junto das outras configurações (ver `write` e `applyNode`).
//!
//! - Alerta: mensagem nova com a palavra (inteira, sem diferenciar
//!   maiúsculas) conta como menção: destaque, contador e notificação.
//! - Filtro e ignorados: a mensagem fica recolhida numa linha ("mostrar")
//!   e não notifica. Ignorar não bloqueia: a pessoa nem fica sabendo.
//! - Foco: por um tempo, só DMs e menções notificam e marcam não lido; o
//!   que chegou nos outros canais volta a aparecer como não lido no fim.
const std = @import("std");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const kdl = @import("../theme/kdl.zig");
const Id = types.Id;

pub const max_words = 64;
pub const max_word_len = 64;

/// Foco sem prazo ("até desligar").
pub const forever: i64 = std.math.maxInt(i64);

pub const Which = enum { alert, filter };

/// Bits do que uma mensagem contém (cache em `StoredMessage.flt`).
pub const bit_alert: u8 = 1;
pub const bit_filter: u8 = 2;

/// O que fazer com uma mensagem que acabou de chegar.
pub const Verdict = enum {
    /// Ignorada/filtrada: não notifica nem conta.
    hidden,
    /// DM, menção ou palavra de alerta: notifica e conta no canal.
    important,
    normal,
};

pub const Filtros = struct {
    /// Palavras já em minúsculas (alocadas com o gpa do estado).
    alert: std.ArrayList([]u8) = .empty,
    filter: std.ArrayList([]u8) = .empty,
    ignored: std.AutoArrayHashMapUnmanaged(Id, void) = .empty,
    /// Mensagens recolhidas que a pessoa pediu para ver.
    revealed: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Menções (e alertas) não lidas por canal.
    mentions: std.AutoHashMapUnmanaged(Id, u16) = .empty,
    /// Modo foco até quando (ms; 0 = desligado, `forever` = até desligar).
    focus_until: i64 = 0,
    /// Canais que teriam ficado "não lidos" durante o foco.
    focus_quiet: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Muda quando as listas ou o foco mudam (invalida o cache `flt` de todas
    /// as mensagens; o QA confere). Contadores e "mostrar" não mexem nele.
    gen: u32 = 1,
    /// Notificações que saíram (o QA confere; o notify-send não roda nele).
    notified: u32 = 0,
    /// Algo persistido mudou: o app salva as configurações.
    save: bool = false,

    pub fn deinit(f: *Filtros, gpa: std.mem.Allocator) void {
        for (f.alert.items) |s| gpa.free(s);
        for (f.filter.items) |s| gpa.free(s);
        f.alert.deinit(gpa);
        f.filter.deinit(gpa);
        f.ignored.deinit(gpa);
        f.revealed.deinit(gpa);
        f.mentions.deinit(gpa);
        f.focus_quiet.deinit(gpa);
    }

    /// Saiu da conta: o que era da sessão vai embora (as listas ficam).
    pub fn resetSession(f: *Filtros) void {
        f.revealed.clearRetainingCapacity();
        f.mentions.clearRetainingCapacity();
        f.focus_quiet.clearRetainingCapacity();
    }

    fn changed(f: *Filtros, persist: bool) void {
        f.gen +%= 1;
        if (f.gen == 0) f.gen = 1;
        if (persist) f.save = true;
    }

    pub fn list(f: *Filtros, which: Which) *std.ArrayList([]u8) {
        return switch (which) {
            .alert => &f.alert,
            .filter => &f.filter,
        };
    }

    pub const AddResult = enum { added, empty, exists, full };

    /// Acrescenta uma palavra ou expressão (espaços nas pontas saem).
    pub fn addWord(f: *Filtros, gpa: std.mem.Allocator, which: Which, text: []const u8) AddResult {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return .empty;
        const l = f.list(which);
        if (l.items.len >= max_words) return .full;
        var buf: [max_word_len]u8 = undefined;
        const folded = fold(&buf, t);
        for (l.items) |s| if (std.mem.eql(u8, s, folded)) return .exists;
        const owned = gpa.dupe(u8, folded) catch return .full;
        l.append(gpa, owned) catch {
            gpa.free(owned);
            return .full;
        };
        f.changed(true);
        return .added;
    }

    pub fn removeWord(f: *Filtros, gpa: std.mem.Allocator, which: Which, i: usize) void {
        const l = f.list(which);
        if (i >= l.items.len) return;
        gpa.free(l.orderedRemove(i));
        f.changed(true);
    }

    pub fn isIgnored(f: *const Filtros, user: Id) bool {
        return f.ignored.count() > 0 and f.ignored.contains(user);
    }

    pub fn setIgnored(f: *Filtros, gpa: std.mem.Allocator, user: Id, on: bool) void {
        if (on) {
            f.ignored.put(gpa, user, {}) catch return;
        } else if (!f.ignored.orderedRemove(user)) return;
        f.changed(true);
    }

    pub fn reveal(f: *Filtros, gpa: std.mem.Allocator, msg: Id) void {
        f.revealed.put(gpa, msg, {}) catch return;
    }

    /// Palavras de alerta/filtro que a mensagem contém (com cache: só
    /// recalcula quando as listas ou o texto mudam).
    pub fn flags(f: *const Filtros, m: *store_mod.StoredMessage) u8 {
        if (f.alert.items.len == 0 and f.filter.items.len == 0) return 0;
        const key = f.gen *% 2654435761 ^ @as(u32, @truncate(@intFromPtr(m.msg.content.ptr) ^ m.msg.content.len));
        if (m.flt_key == key) return m.flt;
        m.flt_key = key;
        m.flt = scan(f, m.msg.content);
        return m.flt;
    }

    fn scan(f: *const Filtros, content: []const u8) u8 {
        if (content.len == 0) return 0;
        var buf: [4096]u8 = undefined;
        const hay = fold(&buf, content);
        var out: u8 = 0;
        if (anyWord(hay, f.alert.items)) out |= bit_alert;
        if (anyWord(hay, f.filter.items)) out |= bit_filter;
        return out;
    }

    /// A mensagem fica recolhida? (ignorado ou filtro, e ainda não mostrada)
    pub fn hides(f: *const Filtros, m: *store_mod.StoredMessage, me: Id) bool {
        if (m.msg.author == me or m.msg.system != .none or m.msg.id == 0) return false;
        if (f.ignored.count() == 0 and f.filter.items.len == 0) return false;
        if (f.revealed.contains(m.msg.id)) return false;
        return f.isIgnored(m.msg.author) or (f.flags(m) & bit_filter != 0);
    }

    /// Mensagem nova chegando: escondida, importante ou normal.
    pub fn judge(f: *const Filtros, author: Id, content: []const u8, dm: bool, mentioned: bool) Verdict {
        if (f.isIgnored(author)) return .hidden;
        if (f.alert.items.len == 0 and f.filter.items.len == 0) return if (dm or mentioned) .important else .normal;
        const b = scan(f, content);
        if (b & bit_filter != 0) return .hidden;
        if (dm or mentioned or b & bit_alert != 0) return .important;
        return .normal;
    }

    // --- Contador de menções -------------------------------------------------

    pub fn count(f: *const Filtros, ch: Id) u16 {
        return f.mentions.get(ch) orelse 0;
    }

    /// Mais uma menção no canal (e no servidor dele, para o ícone da barra).
    pub fn bump(f: *Filtros, gpa: std.mem.Allocator, store: *store_mod.Store, ch: Id) void {
        const gop = f.mentions.getOrPut(gpa, ch) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (store.channel(ch)) |cs| if (cs.info.guild != 0) if (store.guild(cs.info.guild)) |g| {
            g.mentions +|= 1;
        };
    }

    /// Canal lido: zera o contador (e tira a parte dele do servidor).
    pub fn clear(f: *Filtros, store: *store_mod.Store, ch: Id) void {
        _ = f.focus_quiet.remove(ch);
        const kv = f.mentions.fetchRemove(ch) orelse return;
        if (store.channel(ch)) |cs| if (cs.info.guild != 0) if (store.guild(cs.info.guild)) |g| {
            g.mentions -|= kv.value;
        };
    }

    // --- Modo foco -------------------------------------------------------------

    pub fn focusOn(f: *const Filtros, now_ms: i64) bool {
        return f.focus_until != 0 and now_ms < f.focus_until;
    }

    /// Liga por `minutes` (0 = até desligar).
    pub fn startFocus(f: *Filtros, now_ms: i64, minutes: u32) void {
        f.focus_until = if (minutes == 0) forever else now_ms + @as(i64, minutes) * 60_000;
        f.changed(true);
    }

    /// Desliga: o que chegou nos canais "silenciados" volta como não lido.
    pub fn endFocus(f: *Filtros, store: *store_mod.Store) void {
        var it = f.focus_quiet.keyIterator();
        while (it.next()) |ch| if (store.channel(ch.*)) |cs| {
            cs.info.unread = true;
        };
        store.rev +%= 1;
        f.focus_quiet.clearRetainingCapacity();
        f.focus_until = 0;
        f.changed(true);
    }

    /// Minutos que faltam (arredondado para cima); null = até desligar.
    pub fn focusLeftMin(f: *const Filtros, now_ms: i64) ?i64 {
        if (f.focus_until == forever) return null;
        return @divTrunc(@max(0, f.focus_until - now_ms) + 59_999, 60_000);
    }

    /// Mensagem que chegou durante o foco num canal que não importa: não
    /// marca não lido agora (só quando o foco acabar).
    pub fn quiet(f: *Filtros, gpa: std.mem.Allocator, store: *store_mod.Store, ch: Id) void {
        const cs = store.channel(ch) orelse return;
        cs.info.unread = false;
        store.rev +%= 1;
        f.focus_quiet.put(gpa, ch, {}) catch {};
    }

    // --- Arquivo -----------------------------------------------------------------

    /// `alert-words "pizza" "bom dia"`, `filter-words …`, `ignored "123" …`,
    /// `focus until=…` (os IDs vão como texto: não cabem num f64).
    pub fn write(f: *const Filtros, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        for ([_]struct { name: []const u8, l: []const []u8 }{ .{ .name = "alert-words", .l = f.alert.items }, .{ .name = "filter-words", .l = f.filter.items } }) |e| {
            if (e.l.len == 0) continue;
            try out.appendSlice(gpa, e.name);
            for (e.l) |s| {
                try out.append(gpa, ' ');
                try quoted(out, gpa, s);
            }
            try out.append(gpa, '\n');
        }
        if (f.ignored.count() > 0) {
            try out.appendSlice(gpa, "ignored");
            for (f.ignored.keys()) |id| try out.print(gpa, " \"{d}\"", .{id});
            try out.append(gpa, '\n');
        }
        if (f.focus_until != 0) try out.print(gpa, "focus until={d}\n", .{f.focus_until});
    }

    /// Lê um nó do settings.kdl. Retorna false se não é nosso.
    pub fn applyNode(f: *Filtros, gpa: std.mem.Allocator, n: *const kdl.Node, now_ms: i64) bool {
        if (std.mem.eql(u8, n.name, "alert-words") or std.mem.eql(u8, n.name, "filter-words")) {
            const which: Which = if (n.name[0] == 'a') .alert else .filter;
            for (n.args) |a| if (a.asString()) |s| {
                _ = f.addWord(gpa, which, s);
            };
        } else if (std.mem.eql(u8, n.name, "ignored")) {
            for (n.args) |a| if (a.asString()) |s| {
                const id = std.fmt.parseInt(Id, s, 10) catch continue;
                f.setIgnored(gpa, id, true);
            };
        } else if (std.mem.eql(u8, n.name, "focus")) {
            const until = n.num("until") orelse return true;
            // Até desligar vira um número enorme; o resto, se já passou, desliga.
            f.focus_until = if (until >= 9e18) forever else if (until > @as(f64, @floatFromInt(now_ms))) @intFromFloat(until) else 0;
        } else return false;
        f.save = false;
        return true;
    }
};

/// String KDL entre aspas (com os escapes que o parser entende).
pub fn quoted(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

/// Minúsculas (ASCII e as letras acentuadas do Latin-1, que é o que o
/// português usa) sem mudar o tamanho em bytes. Corta em `buf.len` sem
/// partir um caractere no meio.
pub fn fold(buf: []u8, s: []const u8) []u8 {
    var n = @min(s.len, buf.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = s[i];
        buf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        // À..Þ (menos ×) = C3 80..C3 9E → à..þ = C3 A0..C3 BE.
        if (ch == 0xC3 and i + 1 < n) {
            const nx = s[i + 1];
            buf[i + 1] = if (nx >= 0x80 and nx <= 0x9E and nx != 0x97) nx + 0x20 else nx;
            i += 1;
        }
    }
    return buf[0..n];
}

/// Faz parte de uma palavra (letras acentuadas e emoji contam).
fn wordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// `needle` aparece em `hay` como palavra inteira? (os dois já em minúsculas)
pub fn hasWord(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    const edge_a = wordByte(needle[0]);
    const edge_b = wordByte(needle[needle.len - 1]);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |at| {
        const end = at + needle.len;
        const ok_a = !edge_a or at == 0 or !wordByte(hay[at - 1]);
        const ok_b = !edge_b or end == hay.len or !wordByte(hay[end]);
        if (ok_a and ok_b) return true;
        from = at + 1;
    }
    return false;
}

fn anyWord(hay: []const u8, words: []const []u8) bool {
    for (words) |wd| if (hasWord(hay, wd)) return true;
    return false;
}

test "palavra inteira, sem diferenciar maiúsculas nem acentos maiúsculos" {
    var b: [64]u8 = undefined;
    const hay = fold(&b, "Hoje tem PIZZA? Ou BRÓCOLIS, bom dia!");
    try std.testing.expect(hasWord(hay, "pizza"));
    try std.testing.expect(hasWord(hay, "brócolis"));
    try std.testing.expect(hasWord(hay, "bom dia"));
    try std.testing.expect(!hasWord(hay, "pizz"));
    try std.testing.expect(!hasWord(fold(&b, "pizzaria"), "pizza"));
    try std.testing.expect(!hasWord(fold(&b, "épizza"), "pizza"));
    try std.testing.expect(hasWord(fold(&b, "c++ é bom"), "c++"));
}

test "filtros vão e voltam pelo KDL" {
    const gpa = std.testing.allocator;
    var f: Filtros = .{};
    defer f.deinit(gpa);
    try std.testing.expectEqual(Filtros.AddResult.added, f.addWord(gpa, .alert, "  Pizza "));
    try std.testing.expectEqual(Filtros.AddResult.exists, f.addWord(gpa, .alert, "PIZZA"));
    try std.testing.expectEqual(Filtros.AddResult.empty, f.addWord(gpa, .alert, "   "));
    _ = f.addWord(gpa, .filter, "diz \"oi\"");
    f.setIgnored(gpa, 1234567890123456789, true);
    f.startFocus(1000, 0);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try f.write(&out, gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Filtros = .{};
    defer back.deinit(gpa);
    for (nodes) |*n| try std.testing.expect(back.applyNode(gpa, n, 5000));
    try std.testing.expectEqualStrings("pizza", back.alert.items[0]);
    try std.testing.expectEqualStrings("diz \"oi\"", back.filter.items[0]);
    try std.testing.expect(back.isIgnored(1234567890123456789));
    try std.testing.expectEqual(forever, back.focus_until);
    try std.testing.expectEqual(Verdict.important, back.judge(1, "quero PIZZA hoje", false, false));
    try std.testing.expectEqual(Verdict.normal, back.judge(1, "pizzaria", false, false));
    try std.testing.expectEqual(Verdict.hidden, back.judge(1234567890123456789, "oi", true, false));
}
