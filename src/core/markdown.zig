//! Markdown do Discord -> trechos com estilo. Roda uma única vez, quando a
//! mensagem chega; a interface só faz layout e desenha os trechos.
const std = @import("std");
const Id = @import("types.zig").Id;

pub const Flags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    spoiler: bool = false,
    code: bool = false,
    link: bool = false,
    /// Bloco de código (```): cada linha do texto é uma linha na tela.
    block: bool = false,
    /// A mensagem é só emoji: todos os trechos dela ficam grandes (como no Discord).
    jumbo: bool = false,
};

pub const Mention = union(enum) {
    none,
    user: Id,
    channel: Id,
    role: Id,
};

/// Linguagem de um bloco de código (pela etiqueta: ```zig), para o realce.
pub const Lang = enum(u8) {
    none,
    zig,
    c,
    js,
    py,
    rust,
    go,
    sh,
    json,
    lua,
    java,
    cs,
    diff,

    const tags = std.StaticStringMap(Lang).initComptime(.{
        .{ "zig", .zig }, .{ "c", .c },           .{ "h", .c },        .{ "cpp", .c },       .{ "c++", .c },
        .{ "cc", .c },    .{ "hpp", .c },         .{ "cxx", .c },      .{ "js", .js },       .{ "javascript", .js },
        .{ "ts", .js },   .{ "typescript", .js }, .{ "jsx", .js },     .{ "tsx", .js },      .{ "mjs", .js },
        .{ "py", .py },   .{ "python", .py },     .{ "python3", .py }, .{ "rs", .rust },     .{ "rust", .rust },
        .{ "go", .go },   .{ "golang", .go },     .{ "sh", .sh },      .{ "bash", .sh },     .{ "shell", .sh },
        .{ "zsh", .sh },  .{ "fish", .sh },       .{ "console", .sh }, .{ "json", .json },   .{ "jsonc", .json },
        .{ "lua", .lua }, .{ "luau", .lua },      .{ "java", .java },  .{ "kotlin", .java }, .{ "kt", .java },
        .{ "cs", .cs },   .{ "csharp", .cs },     .{ "diff", .diff },  .{ "patch", .diff },
    });

    pub fn fromTag(tag: []const u8) Lang {
        var buf: [16]u8 = undefined;
        if (tag.len == 0 or tag.len > buf.len) return .none;
        return tags.get(std.ascii.lowerString(&buf, tag)) orelse .none;
    }
};

pub const Span = struct {
    /// Fatia do conteúdo original (não é copiada).
    text: []const u8,
    flags: Flags = .{},
    /// Só nos blocos de código.
    lang: Lang = .none,
    mention: Mention = .none,
    /// Emoji personalizado (0 = não é). `text` é `:nome:` ou `<a:nome:id>`.
    emoji: Id = 0,
    emoji_anim: bool = false,

    /// O nome do emoji personalizado deste trecho.
    pub fn emojiName(sp: *const Span) []const u8 {
        const t = sp.text;
        if (t.len > 0 and t[0] == ':') return std.mem.trim(u8, t, ":");
        if (customEmojiAt(t, 0)) |e| return e.name;
        return t;
    }
};

pub const CustomEmoji = struct { name: []const u8, id: Id, animated: bool, len: usize };

/// `<:nome:123>` ou `<a:nome:123>` em s[i..], ou null.
pub fn customEmojiAt(s: []const u8, i: usize) ?CustomEmoji {
    if (i >= s.len or s[i] != '<') return null;
    var k = i + 1;
    const animated = k < s.len and s[k] == 'a';
    if (animated) k += 1;
    if (k >= s.len or s[k] != ':') return null;
    k += 1;
    const start = k;
    while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_')) k += 1;
    if (k == start or k >= s.len or s[k] != ':') return null;
    const name = s[start..k];
    k += 1;
    const digits = k;
    while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
    if (k == digits or k >= s.len or s[k] != '>') return null;
    const id = std.fmt.parseInt(Id, s[digits..k], 10) catch return null;
    return .{ .name = name, .id = id, .animated = animated, .len = k + 1 - i };
}

/// Onde cada emoji do texto do Discord (`raw`) foi parar no texto que aparece
/// (`content`, com `:nome:`). Os dois andam juntos: entre os emoji são iguais.
const EmojiRef = struct { at: usize, len: usize, id: Id, animated: bool };

fn emojiRefs(gpa: std.mem.Allocator, content: []const u8, raw: []const u8) ![]EmojiRef {
    var out: std.ArrayList(EmojiRef) = .empty;
    errdefer out.deinit(gpa);
    var ri: usize = 0;
    var ci: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, ri, '<')) |lt| {
        const e = customEmojiAt(raw, lt) orelse {
            ri = lt + 1;
            continue;
        };
        const name_len = e.name.len + 2;
        var at = ci + (lt - ri);
        const matches = at + name_len <= content.len and content[at] == ':' and content[at + name_len - 1] == ':' and std.mem.eql(u8, content[at + 1 .. at + name_len - 1], e.name);
        if (!matches) {
            // Algo além dos emoji mudou (mensagem de sistema, figurinha…): procura.
            var nb: [64]u8 = undefined;
            const want = std.fmt.bufPrint(&nb, ":{s}:", .{e.name}) catch break;
            at = std.mem.indexOfPos(u8, content, ci, want) orelse break;
        }
        try out.append(gpa, .{ .at = at, .len = name_len, .id = e.id, .animated = e.animated });
        ci = at + name_len;
        ri = lt + e.len;
    }
    return out.toOwnedSlice(gpa);
}

/// É um emoji por si só (não um complemento como o seletor de variação)?
fn emojiBase(cp: u21) bool {
    return switch (cp) {
        0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x2194...0x2199, 0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA, 0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE, 0x2600...0x27BF, 0x2934, 0x2935, 0x2B05...0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D, 0x3297, 0x3299, 0x1F000...0x1F3FA, 0x1F400...0x1FAFF => true,
        else => false,
    };
}

/// Quantos emoji o texto tem, se ele for só emoji e espaços; senão null.
fn unicodeEmojiCount(s: []const u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    var joined = false;
    var flag_half = false;
    while (i < s.len) {
        const ch = s[i];
        if (ch == ' ' or ch == '\n' or ch == '\t') {
            i += 1;
            continue;
        }
        // Texto comum: desiste logo no primeiro caractere (o caso de quase tudo).
        const len = std.unicode.utf8ByteSequenceLength(ch) catch return null;
        if (i + len > s.len) return null;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return null;
        i += len;
        switch (cp) {
            '0'...'9', '#', '*' => {
                // Só como tecla: 1️⃣ (o dígito, FE0F, 20E3).
                if (!std.mem.startsWith(u8, s[i..], "\u{FE0F}\u{20E3}")) return null;
                i += 6;
                n += 1;
            },
            0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F => {},
            0x200D => joined = true,
            0x1F1E6...0x1F1FF => {
                // Bandeira: duas letras contam como um emoji.
                if (!flag_half) n += 1;
                flag_half = !flag_half;
            },
            else => {
                if (!emojiBase(cp)) return null;
                if (!joined) n += 1;
                joined = false;
            },
        }
    }
    return n;
}

/// Mensagem só de emoji (até 30, como no Discord): tudo fica grande.
fn markJumbo(spans: []Span) void {
    var n: usize = 0;
    for (spans) |sp| {
        if (sp.flags.code or sp.flags.link or sp.flags.spoiler or sp.mention != .none) return;
        if (sp.emoji != 0) {
            n += 1;
        } else {
            n += unicodeEmojiCount(sp.text) orelse return;
        }
    }
    if (n == 0 or n > 30) return;
    for (spans) |*sp| sp.flags.jumbo = true;
}

pub fn parse(gpa: std.mem.Allocator, s: []const u8) ![]Span {
    return parseRaw(gpa, s, "");
}

/// `raw`: o texto como o Discord guarda, quando difere de `s` (`Message.raw`):
/// é de lá que vêm os IDs dos emoji personalizados que aparecem como `:nome:`.
pub fn parseRaw(gpa: std.mem.Allocator, s: []const u8, raw: []const u8) ![]Span {
    const refs = if (raw.len > 0) try emojiRefs(gpa, s, raw) else &[_]EmojiRef{};
    defer if (raw.len > 0) gpa.free(refs);
    var next_ref: usize = 0;
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    var flags: Flags = .{};
    var run_start: usize = 0;
    var i: usize = 0;

    const Flush = struct {
        fn run(list: *std.ArrayList(Span), a: std.mem.Allocator, src: []const u8, from: usize, to: usize, f: Flags) !void {
            if (to > from) try list.append(a, .{ .text = src[from..to], .flags = f });
        }
    };

    while (i < s.len) {
        const rest = s[i..];
        // Emoji personalizado (o que ficou em bloco de código passa direto).
        while (next_ref < refs.len and refs[next_ref].at < i) next_ref += 1;
        if (next_ref < refs.len and refs[next_ref].at == i) {
            const e = refs[next_ref];
            try Flush.run(&out, gpa, s, run_start, i, flags);
            try out.append(gpa, .{ .text = s[i .. i + e.len], .flags = flags, .emoji = e.id, .emoji_anim = e.animated });
            i += e.len;
            run_start = i;
            continue;
        }
        // Bloco de código: ```linguagem\n…```. A linguagem não aparece.
        if (std.mem.startsWith(u8, rest, "```")) {
            if (std.mem.indexOfPos(u8, s, i + 3, "```")) |close| {
                try Flush.run(&out, gpa, s, run_start, i, flags);
                var start = i + 3;
                var lang: Lang = .none;
                if (std.mem.indexOfScalarPos(u8, s, start, '\n')) |nl| {
                    const tag = s[start..nl];
                    if (nl < close and tag.len <= 16 and std.mem.indexOfScalar(u8, tag, ' ') == null) {
                        lang = Lang.fromTag(tag);
                        start = nl + 1;
                    }
                }
                var end = close;
                if (end > start and s[end - 1] == '\n') end -= 1;
                if (end > start) try out.append(gpa, .{ .text = s[start..end], .flags = .{ .code = true, .block = true }, .lang = lang });
                i = close + 3;
                // A quebra logo depois do ``` não vira linha em branco.
                if (i < s.len and s[i] == '\n') i += 1;
                run_start = i;
                continue;
            }
        }
        // Código inline: nada dentro dele é interpretado.
        if (rest[0] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |close| {
                try Flush.run(&out, gpa, s, run_start, i, flags);
                var f = flags;
                f.code = true;
                if (close > i + 1) try out.append(gpa, .{ .text = s[i + 1 .. close], .flags = f });
                i = close + 1;
                run_start = i;
                continue;
            }
        }
        // O mesmo emoji escrito direto no texto (embed, bio, mensagem pendente).
        if (rest[0] == '<') if (customEmojiAt(s, i)) |e| {
            try Flush.run(&out, gpa, s, run_start, i, flags);
            try out.append(gpa, .{ .text = s[i .. i + e.len], .flags = flags, .emoji = e.id, .emoji_anim = e.animated });
            i += e.len;
            run_start = i;
            continue;
        };
        // Menções: <@123>, <@!123>, <@&123> (cargo), <#123>.
        if (rest[0] == '<' and rest.len > 3 and (rest[1] == '@' or rest[1] == '#')) {
            if (std.mem.indexOfScalar(u8, rest, '>')) |close| {
                const is_channel = rest[1] == '#';
                var digits = rest[2..close];
                if (digits.len > 0 and digits[0] == '!') digits = digits[1..];
                const is_role = digits.len > 0 and digits[0] == '&';
                if (is_role) digits = digits[1..];
                if (std.fmt.parseInt(Id, digits, 10)) |id| {
                    try Flush.run(&out, gpa, s, run_start, i, flags);
                    try out.append(gpa, .{
                        .text = rest[0 .. close + 1],
                        .flags = flags,
                        .mention = if (is_channel) .{ .channel = id } else if (is_role) .{ .role = id } else .{ .user = id },
                    });
                    i += close + 1;
                    run_start = i;
                    continue;
                } else |_| {}
            }
        }
        // Links.
        if (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://")) {
            var end = i;
            while (end < s.len and s[end] != ' ' and s[end] != '\n') end += 1;
            try Flush.run(&out, gpa, s, run_start, i, flags);
            var f = flags;
            f.link = true;
            try out.append(gpa, .{ .text = s[i..end], .flags = f });
            i = end;
            run_start = i;
            continue;
        }
        // Marcadores de estilo.
        const marker: ?struct { len: usize, which: enum { bold, italic, strike, spoiler } } =
            if (std.mem.startsWith(u8, rest, "**")) .{ .len = 2, .which = .bold } else if (std.mem.startsWith(u8, rest, "~~")) .{ .len = 2, .which = .strike } else if (std.mem.startsWith(u8, rest, "||")) .{ .len = 2, .which = .spoiler } else if ((rest[0] == '*' or rest[0] == '_') and italicBoundary(s, i)) .{ .len = 1, .which = .italic } else null;

        if (marker) |m| {
            try Flush.run(&out, gpa, s, run_start, i, flags);
            switch (m.which) {
                .bold => flags.bold = !flags.bold,
                .italic => flags.italic = !flags.italic,
                .strike => flags.strike = !flags.strike,
                .spoiler => flags.spoiler = !flags.spoiler,
            }
            i += m.len;
            run_start = i;
            continue;
        }
        i += 1;
    }
    try Flush.run(&out, gpa, s, run_start, s.len, flags);
    markJumbo(out.items);
    return out.toOwnedSlice(gpa);
}

/// `_` e `*` só contam como itálico na borda de uma palavra, para não
/// quebrar coisas como snake_case.
fn italicBoundary(s: []const u8, i: usize) bool {
    const before = if (i == 0) ' ' else s[i - 1];
    const after = if (i + 1 < s.len) s[i + 1] else ' ';
    const word = struct {
        fn f(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
        }
    }.f;
    return !(word(before) and word(after));
}

test "estilos, código, menção e link" {
    const a = std.testing.allocator;
    const spans = try parse(a, "oi **negrito** e `a **b**` <@42> veja https://ziglang.org snake_case");
    defer a.free(spans);
    try std.testing.expectEqualStrings("oi ", spans[0].text);
    try std.testing.expect(spans[1].flags.bold);
    try std.testing.expectEqualStrings("negrito", spans[1].text);
    try std.testing.expect(spans[3].flags.code);
    try std.testing.expectEqualStrings("a **b**", spans[3].text);
    try std.testing.expectEqual(@as(Id, 42), spans[5].mention.user);
    try std.testing.expect(spans[7].flags.link);
    try std.testing.expectEqualStrings(" snake_case", spans[8].text);
}

test "bloco de código e menção a cargo" {
    const a = std.testing.allocator;
    const spans = try parse(a, "regras:\n```md\n# um\n# dois\n```\n<@&7> **ok**");
    defer a.free(spans);
    try std.testing.expectEqualStrings("regras:\n", spans[0].text);
    try std.testing.expect(spans[1].flags.block);
    try std.testing.expectEqualStrings("# um\n# dois", spans[1].text);
    try std.testing.expectEqual(Lang.none, spans[1].lang);
    try std.testing.expectEqual(@as(Id, 7), spans[2].mention.role);
}

test "etiqueta do bloco de código vira a linguagem" {
    const a = std.testing.allocator;
    const spans = try parse(a, "```Zig\nconst x = 1;\n```\n```ts\nlet y\n```");
    defer a.free(spans);
    try std.testing.expectEqual(Lang.zig, spans[0].lang);
    try std.testing.expectEqualStrings("const x = 1;", spans[0].text);
    try std.testing.expectEqual(Lang.js, spans[1].lang);
    try std.testing.expectEqual(Lang.none, Lang.fromTag("brainfuck"));
}

test "emoji personalizado: direto no texto e pelo texto do Discord" {
    const a = std.testing.allocator;
    const direct = try parse(a, "oi <:pepe:12> e <a:dança:9> <a:dance:34>!");
    defer a.free(direct);
    try std.testing.expectEqual(@as(Id, 12), direct[1].emoji);
    try std.testing.expectEqualStrings("pepe", direct[1].emojiName());
    try std.testing.expect(!direct[1].emoji_anim);
    // Nome com acento não é emoji de verdade.
    try std.testing.expectEqualStrings(" e <a:dança:9> ", direct[2].text);
    try std.testing.expectEqual(@as(Id, 34), direct[3].emoji);
    try std.testing.expect(direct[3].emoji_anim);
    try std.testing.expect(!direct[0].flags.jumbo);

    const raw = try parseRaw(a, ":x: viu :pepe: `:pepe:` :pepe:", "<:x:1> viu <:pepe:2> `<:pepe:3>` <a:pepe:4>");
    defer a.free(raw);
    try std.testing.expectEqual(@as(Id, 1), raw[0].emoji);
    try std.testing.expectEqualStrings(":x:", raw[0].text);
    try std.testing.expectEqualStrings("x", raw[0].emojiName());
    try std.testing.expectEqual(@as(Id, 2), raw[2].emoji);
    // Dentro do código continua texto; o ID certo vai para o emoji de fora.
    try std.testing.expect(raw[4].flags.code);
    try std.testing.expectEqual(@as(Id, 4), raw[6].emoji);
    try std.testing.expect(raw[6].emoji_anim);
}

test "mensagem só de emoji fica grande" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "🔥", "🔥 😂\n❤️", "<:a:1> <a:b:2>", "1️⃣ 🇧🇷", "👩‍💻", "😂<:a:1>" }) |t| {
        const sp = try parse(a, t);
        defer a.free(sp);
        try std.testing.expect(sp[0].flags.jumbo);
    }
    for ([_][]const u8{ "oi 🔥", "1", "`🔥`", "||🔥||", "<@1> 🔥", "→", "1️⃣ a", "<:a:1> b" }) |t| {
        const sp = try parse(a, t);
        defer a.free(sp);
        try std.testing.expect(!sp[0].flags.jumbo);
    }
    // Mais de 30: tamanho normal.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    for (0..31) |_| try many.appendSlice(a, "🔥");
    const sp = try parse(a, many.items);
    defer a.free(sp);
    try std.testing.expect(!sp[0].flags.jumbo);
}

test "spoiler e riscado" {
    const a = std.testing.allocator;
    const spans = try parse(a, "||segredo|| ~~não~~");
    defer a.free(spans);
    try std.testing.expect(spans[0].flags.spoiler);
    try std.testing.expect(spans[2].flags.strike);
}
