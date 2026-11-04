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
    _pad: u1 = 0,
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
};

pub fn parse(gpa: std.mem.Allocator, s: []const u8) ![]Span {
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

test "spoiler e riscado" {
    const a = std.testing.allocator;
    const spans = try parse(a, "||segredo|| ~~não~~");
    defer a.free(spans);
    try std.testing.expect(spans[0].flags.spoiler);
    try std.testing.expect(spans[2].flags.strike);
}
