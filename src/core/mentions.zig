//! Texto da caixa -> texto do Discord, na hora de enviar: `@Nome com Espaço`
//! vira `<@id>`, `#canal` vira `<#id>` e `:nome:` vira o emoji.
//!
//! O que foi escolhido na lista do autocompletar chega como `Token` (o ID
//! exato, mesmo com dois "Ana" no servidor). O que foi digitado à mão ou veio
//! de um rascunho é procurado pelo nome: o nome mais longo que casa vence.
//! Código (`…`, ```…```), links e o que já é `<…>` ficam como estão.
const std = @import("std");
const types = @import("types.zig");
const store_mod = @import("store.zig");
const emoji_data = @import("../ui/emoji_data.zig");
const Store = store_mod.Store;
const Id = types.Id;

pub const Token = struct { shown: []const u8, repl: []const u8 };

fn nameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// `@`, `#` e `:` só contam no começo de uma palavra (e-mail, âncora de link
/// e "12:30:45" não são menção).
fn boundary(s: []const u8, i: usize) bool {
    if (i == 0) return true;
    const p = s[i - 1];
    return !nameChar(p) and p != '/' and p != '<' and p != '&' and p != '@';
}

fn after(s: []const u8, i: usize) bool {
    return i >= s.len or !nameChar(s[i]);
}

/// `<@1>`, `<#1>`, `<:a:1>`, `<https://…>`: inteiro, sem espaço por dentro.
fn angleEnd(s: []const u8, i: usize) ?usize {
    if (i + 2 >= s.len) return null;
    const n = s[i + 1];
    if (n != '@' and n != '#' and n != ':' and n != 'a' and n != 'h') return null;
    var k = i + 1;
    while (k < s.len and k - i < 512) : (k += 1) {
        if (s[k] == '>') return k + 1;
        if (s[k] == ' ' or s[k] == '\n') return null;
    }
    return null;
}

const Found = struct { id: Id, len: usize };

fn findUser(store: *const Store, guild: Id, rest: []const u8) ?Found {
    var best: ?struct { id: Id, len: usize, member: bool } = null;
    var it = store.users.valueIterator();
    while (it.next()) |u| {
        const n = u.name;
        if (n.len == 0 or n.len > rest.len or !std.ascii.startsWithIgnoreCase(rest, n) or !after(rest, n.len)) continue;
        const member = guild != 0 and store.members.contains(.{ guild, u.id });
        if (best) |b| if (b.len > n.len or (b.len == n.len and (b.member or !member))) continue;
        best = .{ .id = u.id, .len = n.len, .member = member };
    }
    return if (best) |b| .{ .id = b.id, .len = b.len } else null;
}

fn findChannel(store: *const Store, guild: Id, rest: []const u8) ?Found {
    if (guild == 0) return null;
    var best: ?Found = null;
    for (store.channelsOf(guild)) |id| {
        const cs = store.channel(id) orelse continue;
        if (cs.info.kind == .category) continue;
        const n = cs.info.name;
        if (n.len == 0 or n.len > rest.len or !std.ascii.startsWithIgnoreCase(rest, n)) continue;
        if (n.len < rest.len and (nameChar(rest[n.len]) or rest[n.len] == '-')) continue;
        if (best == null or best.?.len < n.len) best = .{ .id = id, .len = n.len };
    }
    return best;
}

/// O emoji personalizado `name` que a conta pode usar numa conversa de `guild`.
pub fn usableEmoji(store: *const Store, guild: Id, name: []const u8) ?types.Emoji {
    if (store.guild_emojis.get(guild)) |list| for (list) |*e| {
        if (std.mem.eql(u8, e.name, name) and store.emojiUse(e, guild) == .ok) return e.*;
    };
    if (store.premium_type == 0) return null;
    var it = store.emoji_by_id.valueIterator();
    while (it.next()) |e| if (std.mem.eql(u8, e.name, name) and e.available) return e.*;
    return null;
}

/// Monta o texto para o Discord (alocado com `gpa`). `tokens`: o que foi
/// escolhido na lista, do mais antigo para o mais novo.
pub fn expand(gpa: std.mem.Allocator, store: *const Store, guild: Id, text: []const u8, tokens: []const Token) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len + 16);
    // Dois "@Ana" escolhidos da lista (pessoas diferentes): cada um vale uma vez.
    var used: u64 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "```")) {
            const end = if (std.mem.indexOfPos(u8, text, i + 3, "```")) |e| e + 3 else text.len;
            try out.appendSlice(gpa, text[i..end]);
            i = end;
            continue;
        }
        if (ch == '`') {
            const end = if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |e| e + 1 else text.len;
            try out.appendSlice(gpa, text[i..end]);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://")) {
            const end = std.mem.indexOfAnyPos(u8, text, i, " \n") orelse text.len;
            try out.appendSlice(gpa, text[i..end]);
            i = end;
            continue;
        }
        if (ch == '<') if (angleEnd(text, i)) |end| {
            try out.appendSlice(gpa, text[i..end]);
            i = end;
            continue;
        };
        if ((ch == '@' or ch == '#' or ch == ':') and boundary(text, i)) {
            // O que veio da lista, o mais longo primeiro.
            var pick: ?usize = null;
            for (tokens, 0..) |t, k| {
                if (k < 64 and used & (@as(u64, 1) << @intCast(k)) != 0) continue;
                if (!std.mem.startsWith(u8, rest, t.shown)) continue;
                if (ch != ':' and !after(rest, t.shown.len)) continue;
                if (pick == null or tokens[pick.?].shown.len < t.shown.len) pick = k;
            }
            if (pick) |k| {
                if (k < 64) used |= @as(u64, 1) << @intCast(k);
                try out.appendSlice(gpa, tokens[k].repl);
                i += tokens[k].shown.len;
                continue;
            }
            switch (ch) {
                '@' => if (!std.mem.startsWith(u8, rest, "@everyone") and !std.mem.startsWith(u8, rest, "@here")) {
                    if (findUser(store, guild, rest[1..])) |u| {
                        try out.print(gpa, "<@{d}>", .{u.id});
                        i += 1 + u.len;
                        continue;
                    }
                },
                '#' => if (findChannel(store, guild, rest[1..])) |f| {
                    try out.print(gpa, "<#{d}>", .{f.id});
                    i += 1 + f.len;
                    continue;
                },
                else => {
                    var k: usize = 1;
                    while (k < rest.len and k <= 40 and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '_' or rest[k] == '+' or rest[k] == '-')) k += 1;
                    if (k > 1 and k < rest.len and rest[k] == ':') {
                        const name = rest[1..k];
                        if (usableEmoji(store, guild, name)) |e| {
                            try out.print(gpa, "<{s}:{s}:{d}>", .{ if (e.animated) "a" else "", e.name, e.id });
                            i += k + 1;
                            continue;
                        }
                        if (emoji_data.byCode(name)) |u| {
                            try out.appendSlice(gpa, emoji_data.glyphOf(u));
                            i += k + 1;
                            continue;
                        }
                    }
                },
            }
        }
        try out.append(gpa, ch);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// --- Autocompletar: em que trecho o cursor está ---------------------------------

pub const Trigger = struct { at: usize, ch: u8 };

fn wordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// Procura para trás, a partir do cursor, o `@`, `#`, `:` ou `/` em cujo trecho
/// o cursor está. Pessoas e canais podem ter espaço no nome (até dois).
pub fn findTrigger(text: []const u8, cur: usize) ?Trigger {
    var i = cur;
    var spaces: usize = 0;
    while (i > 0 and cur - i <= 48) {
        i -= 1;
        const ch = text[i];
        switch (ch) {
            '\n' => return null,
            ' ' => {
                spaces += 1;
                if (spaces > 2) return null;
            },
            '@', '#' => {
                if (i > 0 and (wordChar(text[i - 1]) or text[i - 1] == '<' or text[i - 1] == '/')) return null;
                return .{ .at = i, .ch = ch };
            },
            ':' => {
                if (spaces > 0) continue;
                if (i > 0 and (wordChar(text[i - 1]) or text[i - 1] == '<')) return null;
                return .{ .at = i, .ch = ch };
            },
            '/' => {
                if (i == 0 and spaces == 0) return .{ .at = 0, .ch = '/' };
                if (spaces == 0) return null;
            },
            else => {},
        }
    }
    return null;
}

/// O cursor está dentro de código (`…`)? Lá nada é menção.
pub fn insideCode(text: []const u8, cur: usize) bool {
    return std.mem.count(u8, text[0..cur], "`") % 2 == 1;
}

const c_alloc = std.heap.c_allocator;

fn testStore() !Store {
    var s = Store.init(std.testing.allocator);
    errdefer s.deinit();
    s.me = 1;
    for ([_]struct { id: Id, name: []const u8 }{ .{ .id = 10, .name = "Ana" }, .{ .id = 11, .name = "Ana Maria" }, .{ .id = 12, .name = "bruno" } }) |u|
        try s.apply(.{ .user_upsert = .{ .id = u.id, .name = try c_alloc.dupe(u8, u.name) } }, 0);
    try s.apply(.{ .channel_upsert = .{ .id = 50, .guild = 5, .name = try c_alloc.dupe(u8, "geral"), .topic = "" } }, 0);
    try s.apply(.{ .channel_upsert = .{ .id = 51, .guild = 5, .name = try c_alloc.dupe(u8, "geral-dev"), .topic = "" } }, 0);
    const list = try c_alloc.alloc(types.Emoji, 2);
    list[0] = .{ .id = 70, .name = try c_alloc.dupe(u8, "pepe") };
    list[1] = .{ .id = 71, .name = try c_alloc.dupe(u8, "festa"), .animated = true };
    try s.apply(.{ .guild_emojis = .{ .guild = 5, .emojis = list } }, 0);
    return s;
}

fn expectExpand(s: *const Store, guild: Id, input: []const u8, want: []const u8, tokens: []const Token) !void {
    const got = try expand(std.testing.allocator, s, guild, input, tokens);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "menções à prova de nomes com espaço" {
    var s = try testStore();
    defer s.deinit();
    // O nome mais longo vence; o que sobra da frase fica.
    try expectExpand(&s, 5, "oi @Ana Maria tudo bem", "oi <@11> tudo bem", &.{});
    try expectExpand(&s, 5, "@ana e @bruno, oi", "<@10> e <@12>, oi", &.{});
    // Quem não existe, e-mail e @everyone não mudam.
    try expectExpand(&s, 5, "@ninguem a@bruno @everyone @here", "@ninguem a@bruno @everyone @here", &.{});
    // Código e links ficam como estão.
    try expectExpand(&s, 5, "`@bruno` ```@Ana``` https://x.y/#geral", "`@bruno` ```@Ana``` https://x.y/#geral", &.{});
    // Já pronto não muda.
    try expectExpand(&s, 5, "<@12> <#50> <:pepe:70>", "<@12> <#50> <:pepe:70>", &.{});
    // Canal: nome mais longo; em DM não tem canal.
    try expectExpand(&s, 5, "veja #geral-dev e #geral.", "veja <#51> e <#50>.", &.{});
    try expectExpand(&s, 0, "veja #geral", "veja #geral", &.{});
}

test "o que veio da lista vale pelo ID e uma vez só" {
    var s = try testStore();
    defer s.deinit();
    const toks = [_]Token{
        .{ .shown = "@Ana", .repl = "<@99>" },
        .{ .shown = "@Ana", .repl = "<@98>" },
    };
    try expectExpand(&s, 5, "@Ana, @Ana e @Ana", "<@99>, <@98> e <@10>", &toks);
    const em = [_]Token{.{ .shown = ":festa:", .repl = "<a:festa:71>" }};
    try expectExpand(&s, 5, "uhu :festa:", "uhu <a:festa:71>", &em);
}

test "emoji pelo nome na hora de enviar" {
    var s = try testStore();
    defer s.deinit();
    try expectExpand(&s, 5, "oi :pepe: :joy: :nada: 12:30:45", "oi <:pepe:70> 😂 :nada: 12:30:45", &.{});
    // Sem Nitro: animado e de outro servidor não viram emoji.
    try expectExpand(&s, 5, ":festa:", ":festa:", &.{});
    try expectExpand(&s, 6, ":pepe:", ":pepe:", &.{});
    s.premium_type = 2;
    try expectExpand(&s, 5, ":festa:", "<a:festa:71>", &.{});
    try expectExpand(&s, 6, ":pepe:", "<:pepe:70>", &.{});
}

test "gatilhos" {
    const t = struct {
        fn at(s: []const u8) ?u8 {
            return if (findTrigger(s, s.len)) |f| f.ch else null;
        }
    };
    try std.testing.expectEqual(@as(?u8, '@'), t.at("oi @an"));
    try std.testing.expectEqual(@as(?u8, '@'), t.at("oi @ana ma"));
    try std.testing.expectEqual(@as(?u8, null), t.at("oi @ana maria de souza"));
    try std.testing.expectEqual(@as(?u8, null), t.at("a@b"));
    try std.testing.expectEqual(@as(?u8, '#'), t.at("veja #ger"));
    try std.testing.expectEqual(@as(?u8, ':'), t.at("ri :jo"));
    try std.testing.expectEqual(@as(?u8, null), t.at("12:30"));
    try std.testing.expectEqual(@as(?u8, null), t.at("oi :jo ri"));
    try std.testing.expectEqual(@as(?u8, '/'), t.at("/dad"));
    try std.testing.expectEqual(@as(?u8, null), t.at("a /dad"));
    try std.testing.expectEqual(@as(?u8, null), t.at("https://a"));
    try std.testing.expectEqual(@as(?u8, null), t.at("oi\n"));
    try std.testing.expect(insideCode("`@a", 3));
    try std.testing.expect(!insideCode("`a` @b", 6));
}
