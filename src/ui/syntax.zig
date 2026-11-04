//! Realce de sintaxe leve dos blocos de código (```zig, ```py…): palavras-
//! chave, tipos, strings, números e comentários. Uma linha por vez, sem
//! alocar; o que atravessa linhas (comentário /* */, string """ do Python)
//! passa de uma linha para a outra no `State`.
const std = @import("std");
const Lang = @import("../core/markdown.zig").Lang;

pub const Kind = enum { plain, keyword, type, string, number, comment, add, del };

/// O que continua aberto no fim da linha.
pub const State = enum(u8) { normal, block_comment, lua_comment, triple_dq, triple_sq };

pub const Token = struct { text: []const u8, kind: Kind };

const Set = std.StaticStringMap(void);

fn set(comptime words: []const []const u8) Set {
    @setEvalBranchQuota(20000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    return Set.initComptime(kvs);
}

const kw_zig = set(&.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "struct", "enum", "union", "error", "comptime", "inline", "export", "extern", "test", "unreachable", "null", "undefined", "true", "false", "packed", "align", "noreturn", "async", "await", "suspend", "resume", "threadlocal", "usingnamespace", "callconv", "opaque", "anytype", "volatile", "allowzero", "linksection", "noalias", "nosuspend", "asm" });
const ty_zig = set(&.{ "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f80", "f128", "bool", "void", "type", "anyerror", "anyopaque", "comptime_int", "comptime_float", "c_int", "c_uint", "c_long", "c_char" });
const kw_c = set(&.{ "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "using", "try", "catch", "throw", "nullptr", "true", "false", "NULL", "constexpr", "noexcept", "operator", "friend", "static_cast", "reinterpret_cast", "dynamic_cast", "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#else", "#pragma" });
const ty_c = set(&.{ "int", "char", "short", "long", "float", "double", "void", "unsigned", "signed", "bool", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "uintptr_t", "auto", "std", "string", "vector" });
const kw_js = set(&.{ "var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "null", "undefined", "true", "false", "void", "static", "get", "set", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "declare", "namespace", "keyof", "satisfies" });
const ty_js = set(&.{ "string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol" });
const kw_py = set(&.{ "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "async", "await", "None", "True", "False", "match", "case" });
const ty_py = set(&.{ "int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "self", "cls", "print", "len", "range" });
const kw_rust = set(&.{ "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "async", "await", "dyn", "macro_rules" });
const ty_rust = set(&.{ "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Some", "None", "Ok", "Err" });
const kw_go = set(&.{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota" });
const ty_go = set(&.{ "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "float32", "float64", "string", "bool", "byte", "rune", "error", "any", "make", "len", "append", "new", "panic" });
const kw_sh = set(&.{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "local", "export", "readonly", "set", "unset", "source", "alias", "echo", "cd", "sudo", "true", "false" });
const kw_json = set(&.{ "true", "false", "null" });
const kw_lua = set(&.{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "self" });
const ty_lua = set(&.{ "print", "pairs", "ipairs", "require", "table", "string", "math", "type", "tostring", "tonumber" });
const kw_java = set(&.{ "abstract", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "new", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "throws", "try", "while", "null", "true", "false", "fun", "val", "var", "when", "object", "override", "data", "is", "in" });
const ty_java = set(&.{ "int", "long", "short", "byte", "char", "float", "double", "boolean", "void", "String", "Int", "Long", "Boolean", "Unit", "Any" });
const kw_cs = set(&.{ "abstract", "as", "async", "await", "base", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "event", "explicit", "finally", "for", "foreach", "if", "in", "interface", "internal", "is", "lock", "namespace", "new", "null", "operator", "out", "override", "private", "protected", "public", "readonly", "ref", "return", "sealed", "static", "struct", "switch", "this", "throw", "true", "false", "try", "using", "var", "virtual", "while", "get", "set" });
const ty_cs = set(&.{ "int", "long", "short", "byte", "char", "float", "double", "decimal", "bool", "void", "string", "object", "dynamic" });

const empty = set(&.{});

fn keywords(l: Lang) Set {
    return switch (l) {
        .zig => kw_zig,
        .c => kw_c,
        .js => kw_js,
        .py => kw_py,
        .rust => kw_rust,
        .go => kw_go,
        .sh => kw_sh,
        .json => kw_json,
        .lua => kw_lua,
        .java => kw_java,
        .cs => kw_cs,
        .none, .diff => empty,
    };
}

fn types(l: Lang) Set {
    return switch (l) {
        .zig => ty_zig,
        .c => ty_c,
        .js => ty_js,
        .py => ty_py,
        .rust => ty_rust,
        .go => ty_go,
        .lua => ty_lua,
        .java => ty_java,
        .cs => ty_cs,
        else => empty,
    };
}

fn lineComment(l: Lang) []const u8 {
    return switch (l) {
        .py, .sh => "#",
        .lua => "--",
        .none, .diff => "",
        else => "//",
    };
}

fn blockComments(l: Lang) bool {
    return switch (l) {
        .c, .js, .rust, .go, .java, .cs, .json => true,
        else => false,
    };
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Tokens de uma linha. `state` vem da linha anterior e sai para a próxima.
pub const Lexer = struct {
    lang: Lang,
    line: []const u8,
    state: *State,
    i: usize = 0,

    pub fn init(lang: Lang, line: []const u8, state: *State) Lexer {
        return .{ .lang = lang, .line = line, .state = state };
    }

    fn tok(lx: *Lexer, start: usize, kind: Kind) Token {
        return .{ .text = lx.line[start..lx.i], .kind = kind };
    }

    /// Vai até `close` (inclusive) ou até o fim da linha, que deixa `open` aberto.
    fn until(lx: *Lexer, start: usize, close: []const u8, open: State, kind: Kind) Token {
        if (std.mem.indexOfPos(u8, lx.line, lx.i, close)) |e| {
            lx.i = e + close.len;
            lx.state.* = .normal;
        } else {
            lx.i = lx.line.len;
            lx.state.* = open;
        }
        return lx.tok(start, kind);
    }

    pub fn next(lx: *Lexer) ?Token {
        const s = lx.line;
        if (lx.i >= s.len) return null;
        const start = lx.i;
        // Continua o que ficou aberto na linha de cima.
        switch (lx.state.*) {
            .block_comment => return lx.until(start, "*/", .block_comment, .comment),
            .lua_comment => return lx.until(start, "]]", .lua_comment, .comment),
            .triple_dq => return lx.until(start, "\"\"\"", .triple_dq, .string),
            .triple_sq => return lx.until(start, "'''", .triple_sq, .string),
            .normal => {},
        }
        const rest = s[lx.i..];
        if (lx.lang == .diff) {
            lx.i = s.len;
            const kind: Kind = if (rest[0] == '+') .add else if (rest[0] == '-') .del else if (std.mem.startsWith(u8, rest, "@@")) .keyword else .plain;
            return lx.tok(start, kind);
        }
        if (lx.lang == .lua and std.mem.startsWith(u8, rest, "--[[")) {
            lx.i += 4;
            return lx.until(start, "]]", .lua_comment, .comment);
        }
        const lc = lineComment(lx.lang);
        if (lc.len > 0 and std.mem.startsWith(u8, rest, lc)) {
            // `#include` no C e `$#` no shell não são comentário.
            const sh_var = lx.lang == .sh and start > 0 and s[start - 1] == '$';
            if (!sh_var) {
                lx.i = s.len;
                return lx.tok(start, .comment);
            }
        }
        if (blockComments(lx.lang) and std.mem.startsWith(u8, rest, "/*")) {
            lx.i += 2;
            return lx.until(start, "*/", .block_comment, .comment);
        }
        if (lx.lang == .py and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
            lx.i += 3;
            return if (rest[0] == '"') lx.until(start, "\"\"\"", .triple_dq, .string) else lx.until(start, "'''", .triple_sq, .string);
        }
        // String multilinha do Zig: \\ até o fim da linha.
        if (lx.lang == .zig and std.mem.startsWith(u8, rest, "\\\\")) {
            lx.i = s.len;
            return lx.tok(start, .string);
        }
        const ch = rest[0];
        const quote = ch == '"' or (ch == '\'' and lx.lang != .json) or (ch == '`' and (lx.lang == .js or lx.lang == .go or lx.lang == .sh));
        // Em Rust/Zig o ' só é caractere quando fecha logo ('a', '\n'); senão é tempo de vida.
        const char_lit = ch != '\'' or !(lx.lang == .rust or lx.lang == .zig) or
            (rest.len >= 3 and (rest[2] == '\'' or (rest[1] == '\\' and rest.len >= 4)));
        if (quote and char_lit) {
            lx.i += 1;
            while (lx.i < s.len) : (lx.i += 1) {
                if (s[lx.i] == '\\' and ch != '`') {
                    lx.i += 1;
                    continue;
                }
                if (s[lx.i] == ch) {
                    lx.i += 1;
                    break;
                }
            }
            lx.i = @min(lx.i, s.len);
            return lx.tok(start, .string);
        }
        if (std.ascii.isDigit(ch) and (start == 0 or !isIdent(s[start - 1]))) {
            while (lx.i < s.len and (isIdent(s[lx.i]) or s[lx.i] == '.')) lx.i += 1;
            return lx.tok(start, .number);
        }
        // Builtins do Zig (@import), variáveis do shell ($HOME) e #include.
        const sigil = (ch == '@' and lx.lang == .zig) or (ch == '$' and lx.lang == .sh) or (ch == '#' and lx.lang == .c);
        if (isIdent(ch) or (sigil and rest.len > 1 and (isIdent(rest[1]) or rest[1] == '{'))) {
            lx.i += 1;
            while (lx.i < s.len and (isIdent(s[lx.i]) or (ch == '$' and (s[lx.i] == '{' or s[lx.i] == '}')))) lx.i += 1;
            const word = s[start..lx.i];
            if (keywords(lx.lang).has(word)) return lx.tok(start, .keyword);
            if (sigil and ch != '#') return lx.tok(start, .type);
            if (types(lx.lang).has(word)) return lx.tok(start, .type);
            // Nome com maiúscula costuma ser tipo (menos em shell e JSON).
            const caps = std.ascii.isUpper(ch) and word.len > 1 and lx.lang != .sh and lx.lang != .json;
            return lx.tok(start, if (caps) .type else .plain);
        }
        // Pontuação e espaços: junta até o próximo começo de token. Um caractere
        // acentuado vai inteiro: cada byte sozinho viraria "�" na tela.
        lx.i += 1;
        if (ch >= 0x80) while (lx.i < s.len and (s[lx.i] & 0xC0) == 0x80) {
            lx.i += 1;
        };
        while (lx.i < s.len) : (lx.i += 1) {
            const x = s[lx.i];
            if (isIdent(x) or x == '"' or x == '\'' or x == '`' or x == '/' or x == '#' or x == '-' or x == '@' or x == '$' or x >= 0x80) break;
        }
        return lx.tok(start, .plain);
    }
};

/// Para os testes: os tipos dos tokens que não são só pontuação.
fn kinds(lang: Lang, line: []const u8, state: *State, out: []Kind) usize {
    var lx = Lexer.init(lang, line, state);
    var n: usize = 0;
    while (lx.next()) |t| {
        if (t.kind == .plain and std.mem.trim(u8, t.text, " \t(){};,.=:+-*/<>!&|").len == 0) continue;
        out[n] = t.kind;
        n += 1;
    }
    return n;
}

test "realce: zig" {
    var st: State = .normal;
    var lx = Lexer.init(.zig, "const x: u8 = @intCast(42); // oi", &st);
    try std.testing.expectEqual(Kind.keyword, lx.next().?.kind);
    var seen_num = false;
    var seen_cmt = false;
    var seen_builtin = false;
    while (lx.next()) |t| {
        if (t.kind == .number) seen_num = std.mem.eql(u8, t.text, "42");
        if (t.kind == .comment) seen_cmt = std.mem.eql(u8, t.text, "// oi");
        if (t.kind == .type and std.mem.eql(u8, t.text, "@intCast")) seen_builtin = true;
    }
    try std.testing.expect(seen_num and seen_cmt and seen_builtin);
}

test "realce: comentário e string atravessam linhas" {
    var k: [16]Kind = undefined;
    var st: State = .normal;
    _ = kinds(.c, "int a; /* começa", &st, &k);
    try std.testing.expectEqual(State.block_comment, st);
    const n = kinds(.c, "ainda */ return 1;", &st, &k);
    try std.testing.expectEqual(State.normal, st);
    try std.testing.expectEqualSlices(Kind, &.{ .comment, .keyword, .number }, k[0..n]);
    var st2: State = .normal;
    _ = kinds(.py, "s = \"\"\"doc", &st2, &k);
    try std.testing.expectEqual(State.triple_dq, st2);
    const m = kinds(.py, "fim\"\"\" + 'x'", &st2, &k);
    try std.testing.expectEqual(State.normal, st2);
    try std.testing.expectEqualSlices(Kind, &.{ .string, .string }, k[0..m]);
}

test "realce: lifetime do rust não vira string, char vira" {
    var st: State = .normal;
    var lx = Lexer.init(.rust, "fn f<'a>(c: char) { let x = 'z'; }", &st);
    var strings: usize = 0;
    while (lx.next()) |t| if (t.kind == .string) {
        strings += 1;
        try std.testing.expectEqualStrings("'z'", t.text);
    };
    try std.testing.expectEqual(@as(usize, 1), strings);
}

test "realce: shell, json e diff" {
    var st: State = .normal;
    var lx = Lexer.init(.sh, "echo $HOME # casa", &st);
    try std.testing.expectEqual(Kind.keyword, lx.next().?.kind);
    _ = lx.next();
    try std.testing.expectEqual(Kind.type, lx.next().?.kind);
    _ = lx.next();
    try std.testing.expectEqual(Kind.comment, lx.next().?.kind);
    var lj = Lexer.init(.json, "{\"a\": true, \"b\": 1.5}", &st);
    var k: [8]Kind = undefined;
    var n: usize = 0;
    while (lj.next()) |t| if (t.kind != .plain) {
        k[n] = t.kind;
        n += 1;
    };
    try std.testing.expectEqualSlices(Kind, &.{ .string, .keyword, .string, .number }, k[0..n]);
    var ld = Lexer.init(.diff, "+linha nova", &st);
    try std.testing.expectEqual(Kind.add, ld.next().?.kind);
}

test "realce: acento fora de string não é partido em bytes" {
    var st: State = .normal;
    var lx = Lexer.init(.sh, "echo olá ção", &st);
    while (lx.next()) |t| try std.testing.expect(std.unicode.utf8ValidateSlice(t.text));
}
