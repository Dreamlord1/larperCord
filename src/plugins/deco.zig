//! Decoração de mensagens pelos plugins: selo, linha de nota embaixo e recolher
//! com "mostrar". Tudo aqui é dado, na thread da interface: regras (palavra ou
//! pessoa) e entradas por mensagem. O desenho consulta este índice; o Lua nunca
//! é chamado por mensagem nem por quadro, e o texto só é examinado uma vez (o
//! resultado fica em `StoredMessage`, como os alertas de core/filtros.zig).
const std = @import("std");
const filtros = @import("../core/filtros.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;

pub const max_per_run = 4096;
pub const max_rules = 256;
const max_parts = 3;
const max_runs = 16;
const no_rule: u16 = std.math.maxInt(u16);

pub const Part = struct {
    badge: []const u8 = "",
    note: []const u8 = "",
    /// Qual plugin pôs, e a mensagem (0 = regra): o "×" da nota usa os dois.
    run: u32 = 0,
    id: u64 = 0,
    /// Em vermelho: um aviso, não só uma anotação.
    danger: bool = false,
};

pub const View = struct {
    parts: [max_parts]Part = undefined,
    n: u8 = 0,
    collapse: bool = false,
    label: []const u8 = "",

    pub fn slice(v: *const View) []const Part {
        return v.parts[0..v.n];
    }
};

const Key = struct { id: u64, run: u32 };

const Entry = struct {
    badge: []u8,
    note: []u8,
    label: []u8,
    collapse: bool,
    ver: u32,
    danger: bool = false,
};

pub const Rule = struct {
    run: u32 = 0,
    /// Já em minúsculas (core/filtros.zig); vazio = regra por pessoa.
    word: []u8 = "",
    user: u64 = 0,
    badge: []u8 = "",
    note: []u8 = "",
    label: []u8 = "",
    collapse: bool = false,

    pub fn free(r: *const Rule, gpa: std.mem.Allocator) void {
        gpa.free(r.word);
        gpa.free(r.badge);
        gpa.free(r.note);
        gpa.free(r.label);
    }
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    rules: std.ArrayList(Rule) = .empty,
    /// Plugins com entradas agora (a consulta por mensagem só olha estes).
    runs: [max_runs]u32 = undefined,
    counts: [max_runs]u32 = undefined,
    n_runs: u8 = 0,
    rules_gen: u32 = 1,
    next_ver: u32 = 1,
    /// Muda quando algo pode mudar a altura de mensagens que a consulta já não
    /// vê mais (regras novas, plugin desligado): entra na chave do layout.
    layout_gen: u8 = 0,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ix: *Index) void {
        var it = ix.entries.valueIterator();
        while (it.next()) |e| freeEntry(ix.gpa, e);
        ix.entries.deinit(ix.gpa);
        for (ix.rules.items) |*r| r.free(ix.gpa);
        ix.rules.deinit(ix.gpa);
    }

    fn freeEntry(gpa: std.mem.Allocator, e: *const Entry) void {
        gpa.free(e.badge);
        gpa.free(e.note);
        gpa.free(e.label);
    }

    /// Sem nada para decorar: quem desenha nem pergunta por mensagem.
    pub fn active(ix: *const Index) bool {
        return ix.n_runs > 0 or ix.rules.items.len > 0;
    }

    fn runIndex(ix: *const Index, run: u32) ?usize {
        for (ix.runs[0..ix.n_runs], 0..) |r, i| if (r == run) return i;
        return null;
    }

    /// Troca a decoração da mensagem por este plugin. Os textos passam a ser do
    /// índice. false = sem lugar (o plugin passou do teto).
    pub fn set(ix: *Index, run: u32, id: u64, badge: []u8, note: []u8, label: []u8, collapse: bool, danger: bool) bool {
        const gpa = ix.gpa;
        const key: Key = .{ .id = id, .run = run };
        const slot = ix.runIndex(run) orelse blk: {
            if (ix.n_runs == max_runs) return ix.reject(badge, note, label);
            ix.runs[ix.n_runs] = run;
            ix.counts[ix.n_runs] = 0;
            ix.n_runs += 1;
            break :blk ix.n_runs - 1;
        };
        const gop = ix.entries.getOrPut(gpa, key) catch return ix.reject(badge, note, label);
        if (gop.found_existing) {
            freeEntry(gpa, gop.value_ptr);
        } else {
            if (ix.counts[slot] >= max_per_run) {
                _ = ix.entries.remove(key);
                return ix.reject(badge, note, label);
            }
            ix.counts[slot] += 1;
        }
        gop.value_ptr.* = .{ .badge = badge, .note = note, .label = label, .collapse = collapse, .ver = ix.next_ver, .danger = danger };
        ix.next_ver +%= 1;
        return true;
    }

    fn reject(ix: *const Index, badge: []u8, note: []u8, label: []u8) bool {
        ix.gpa.free(badge);
        ix.gpa.free(note);
        ix.gpa.free(label);
        return false;
    }

    /// Tira o que o plugin pôs nesta mensagem.
    pub fn remove(ix: *Index, run: u32, id: u64) void {
        const kv = ix.entries.fetchRemove(.{ .id = id, .run = run }) orelse return;
        freeEntry(ix.gpa, &kv.value);
        const slot = ix.runIndex(run) orelse return;
        ix.counts[slot] -|= 1;
        if (ix.counts[slot] == 0) ix.dropRun(slot);
    }

    /// A mensagem foi apagada: o texto traduzido ou anotado vai junto.
    pub fn removeMessage(ix: *Index, id: u64) void {
        var i: usize = ix.n_runs;
        while (i > 0) {
            i -= 1;
            ix.remove(ix.runs[i], id);
        }
    }

    fn dropRun(ix: *Index, slot: usize) void {
        ix.runs[slot] = ix.runs[ix.n_runs - 1];
        ix.counts[slot] = ix.counts[ix.n_runs - 1];
        ix.n_runs -= 1;
        ix.layout_gen +%= 1;
    }

    /// Troca todas as regras do plugin (assume `list` e os textos).
    pub fn setRules(ix: *Index, run: u32, list: []Rule) void {
        ix.dropRules(run);
        for (list) |r| {
            if (ix.rules.items.len >= max_rules) {
                r.free(ix.gpa);
                continue;
            }
            var own = r;
            own.run = run;
            ix.rules.append(ix.gpa, own) catch r.free(ix.gpa);
        }
        ix.gpa.free(list);
        ix.rulesChanged();
    }

    fn dropRules(ix: *Index, run: u32) void {
        var i: usize = 0;
        while (i < ix.rules.items.len) {
            if (ix.rules.items[i].run == run) {
                ix.rules.items[i].free(ix.gpa);
                _ = ix.rules.orderedRemove(i);
            } else i += 1;
        }
    }

    fn rulesChanged(ix: *Index) void {
        ix.rules_gen +%= 1;
        if (ix.rules_gen == 0) ix.rules_gen = 1;
        ix.layout_gen +%= 1;
    }

    /// O plugin parou: some tudo o que era dele.
    pub fn clearRun(ix: *Index, run: u32) void {
        const had_rules = for (ix.rules.items) |r| {
            if (r.run == run) break true;
        } else false;
        if (had_rules) {
            ix.dropRules(run);
            ix.rulesChanged();
        }
        const slot = ix.runIndex(run) orelse return;
        var it = ix.entries.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.run != run) continue;
            freeEntry(ix.gpa, kv.value_ptr);
            ix.entries.removeByPtr(kv.key_ptr);
        }
        ix.dropRun(slot);
    }

    fn ruleFor(ix: *const Index, m: *StoredMessage, me: u64) ?*const Rule {
        if (ix.rules.items.len == 0 or m.msg.id == 0 or m.msg.author == me or m.msg.system != .none) return null;
        const key = ix.rules_gen *% 2654435761 ^ @as(u32, @truncate(@intFromPtr(m.msg.content.ptr) ^ m.msg.content.len ^ m.msg.author));
        if (m.dc_key != key) {
            m.dc_key = key;
            m.dc_rule = scanRules(ix, m);
        }
        return if (m.dc_rule == no_rule) null else &ix.rules.items[m.dc_rule];
    }

    fn scanRules(ix: *const Index, m: *const StoredMessage) u16 {
        var buf: [4096]u8 = undefined;
        var folded: ?[]const u8 = null;
        for (ix.rules.items, 0..) |*r, i| {
            if (r.user != 0) {
                if (r.user == m.msg.author) return @intCast(i);
                continue;
            }
            if (r.word.len == 0) continue;
            const hay = folded orelse filtros.fold(&buf, m.msg.content);
            folded = hay;
            if (filtros.hasWord(hay, r.word)) return @intCast(i);
        }
        return no_rule;
    }

    /// A mensagem fica recolhida por algum plugin? (O "mostrar" é de quem chama.)
    pub fn collapses(ix: *const Index, m: *StoredMessage, me: u64) bool {
        if (ix.ruleFor(m, me)) |r| if (r.collapse) return true;
        for (ix.runs[0..ix.n_runs]) |run| {
            const e = ix.entries.getPtr(.{ .id = m.msg.id, .run = run }) orelse continue;
            if (e.collapse) return true;
        }
        return false;
    }

    /// O que desenhar nesta mensagem. Também confere se mudou desde a última
    /// medida: mudou, a altura guardada não vale mais.
    pub fn view(ix: *const Index, m: *StoredMessage, me: u64) View {
        var v: View = .{};
        var sig: u32 = 0;
        if (ix.ruleFor(m, me)) |r| {
            sig +%= ix.rules_gen;
            v.collapse = r.collapse;
            v.label = r.label;
            if (r.badge.len > 0 or r.note.len > 0) {
                v.parts[0] = .{ .badge = r.badge, .note = r.note, .run = r.run };
                v.n = 1;
            }
        }
        for (ix.runs[0..ix.n_runs]) |run| {
            const e = ix.entries.getPtr(.{ .id = m.msg.id, .run = run }) orelse continue;
            sig +%= e.ver;
            if (e.collapse) v.collapse = true;
            if (e.label.len > 0) v.label = e.label;
            if ((e.badge.len > 0 or e.note.len > 0) and v.n < max_parts) {
                v.parts[v.n] = .{ .badge = e.badge, .note = e.note, .run = run, .id = m.msg.id, .danger = e.danger };
                v.n += 1;
            }
        }
        if (sig != m.dc_ver) {
            m.dc_ver = sig;
            m.layout_w = -1;
        }
        return v;
    }
};

fn dup(s: []const u8) []u8 {
    return std.testing.allocator.dupe(u8, s) catch unreachable;
}

fn msg(id: u64, author: u64, content: []const u8) StoredMessage {
    return .{ .msg = .{ .id = id, .channel = 1, .author = author, .timestamp = 0, .content = content }, .spans = &.{} };
}

test "decoração por mensagem: selo, nota, recolher e tirar" {
    var ix = Index.init(std.testing.allocator);
    defer ix.deinit();
    var m = msg(10, 2, "oi");
    try std.testing.expect(!ix.active());
    try std.testing.expect(ix.set(5, 10, dup("salvo"), dup(""), dup(""), false, false));
    try std.testing.expect(ix.set(6, 10, dup(""), dup("hi"), dup(""), false, false));
    try std.testing.expect(ix.active());
    var v = ix.view(&m, 1);
    try std.testing.expectEqual(@as(u8, 2), v.n);
    try std.testing.expectEqualStrings("salvo", v.slice()[0].badge);
    try std.testing.expectEqualStrings("hi", v.slice()[1].note);
    try std.testing.expect(!ix.collapses(&m, 1));
    // Medida invalidada só quando muda de verdade.
    m.layout_w = 100;
    _ = ix.view(&m, 1);
    try std.testing.expectEqual(@as(f32, 100), m.layout_w);
    try std.testing.expect(ix.set(5, 10, dup("outro"), dup(""), dup("rótulo"), true, false));
    v = ix.view(&m, 1);
    try std.testing.expectEqual(@as(f32, -1), m.layout_w);
    try std.testing.expect(v.collapse);
    try std.testing.expectEqualStrings("rótulo", v.label);
    ix.remove(6, 10);
    ix.remove(5, 10);
    try std.testing.expect(!ix.active());
    ix.removeMessage(10);
}

test "regras: palavra e pessoa, com cache, sem pegar as nossas" {
    var ix = Index.init(std.testing.allocator);
    defer ix.deinit();
    const list = try std.testing.allocator.alloc(Rule, 2);
    list[0] = .{ .word = dup("spoiler"), .collapse = true, .label = dup("filtro") };
    list[1] = .{ .user = 99, .badge = dup("!") };
    ix.setRules(7, list);
    var a = msg(1, 2, "Isso é SPOILER mesmo");
    var b = msg(2, 99, "oi");
    var c = msg(3, 2, "spoilers não contam");
    var mine = msg(4, 1, "spoiler meu");
    try std.testing.expect(ix.collapses(&a, 1));
    try std.testing.expect(!ix.collapses(&b, 1));
    try std.testing.expectEqualStrings("!", ix.view(&b, 1).slice()[0].badge);
    try std.testing.expect(!ix.collapses(&c, 1));
    try std.testing.expect(!ix.collapses(&mine, 1));
    // Trocou o texto no cache de propósito: sem mudar a chave, não examina de novo.
    const key = a.dc_key;
    try std.testing.expect(ix.collapses(&a, 1));
    try std.testing.expectEqual(key, a.dc_key);
    const gen = ix.layout_gen;
    ix.clearRun(7);
    try std.testing.expect(gen != ix.layout_gen);
    try std.testing.expect(!ix.active());
    try std.testing.expect(!ix.collapses(&a, 1));
}

test "plugin parado leva tudo o que pôs, e há teto por plugin" {
    var ix = Index.init(std.testing.allocator);
    defer ix.deinit();
    var i: u64 = 0;
    while (i < 50) : (i += 1) try std.testing.expect(ix.set(1, i, dup("x"), dup(""), dup(""), false, false));
    try std.testing.expect(ix.set(2, 7, dup("y"), dup(""), dup(""), false, false));
    ix.clearRun(1);
    try std.testing.expectEqual(@as(usize, 1), ix.entries.count());
    var m = msg(7, 2, "");
    try std.testing.expectEqualStrings("y", ix.view(&m, 1).slice()[0].badge);
    ix.counts[0] = max_per_run;
    try std.testing.expect(!ix.set(2, 8, dup("z"), dup(""), dup(""), false, false));
    try std.testing.expect(ix.set(2, 7, dup("w"), dup(""), dup(""), false, false));
}
