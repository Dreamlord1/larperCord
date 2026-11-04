//! Parser de um subconjunto de KDL (https://kdl.dev), usado pelos temas.
//!
//!     node "arg" 12 key=value flag=#true {
//!         child; outro "x"
//!     }
//!
//! Suporta strings com escapes, identificadores soltos, números, booleanos
//! (`true`/`#true`), `null`, comentários `//`, `/* */` e `/-` (comenta o
//! próximo nó). Tudo é alocado na arena recebida.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    null,

    pub fn asString(v: Value) ?[]const u8 {
        return if (v == .string) v.string else null;
    }

    pub fn asNumber(v: Value) ?f64 {
        return if (v == .number) v.number else null;
    }

    pub fn asBool(v: Value) ?bool {
        return switch (v) {
            .boolean => |b| b,
            .number => |n| n != 0,
            else => null,
        };
    }
};

pub const Prop = struct {
    key: []const u8,
    value: Value,
};

pub const Node = struct {
    name: []const u8,
    args: []const Value = &.{},
    props: []const Prop = &.{},
    children: []const Node = &.{},
    line: u32 = 0,

    pub fn prop(n: *const Node, key: []const u8) ?Value {
        // A última ocorrência vence, como no KDL.
        var i = n.props.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, n.props[i].key, key)) return n.props[i].value;
        }
        return null;
    }

    pub fn arg(n: *const Node, i: usize) ?Value {
        return if (i < n.args.len) n.args[i] else null;
    }

    pub fn str(n: *const Node, key: []const u8) ?[]const u8 {
        return if (n.prop(key)) |v| v.asString() else null;
    }

    pub fn num(n: *const Node, key: []const u8) ?f64 {
        return if (n.prop(key)) |v| v.asNumber() else null;
    }

    pub fn flag(n: *const Node, key: []const u8) ?bool {
        return if (n.prop(key)) |v| v.asBool() else null;
    }

    pub fn child(n: *const Node, name: []const u8) ?*const Node {
        for (n.children) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

pub const Diagnostic = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8 = "",
};

pub const Error = error{ SyntaxError, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: ?*Diagnostic) Error![]const Node {
    var p: Parser = .{ .src = src, .arena = arena, .diag = diag };
    const nodes = try p.nodeList(false);
    return nodes;
}

const max_depth = 64;

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    arena: std.mem.Allocator,
    diag: ?*Diagnostic,
    /// Blocos abertos: um arquivo com `a{a{a{…` não estoura a pilha.
    depth: u16 = 0,

    fn fail(p: *Parser, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = p.line, .column = @intCast(p.i - p.line_start + 1), .message = msg };
        return error.SyntaxError;
    }

    fn peek(p: *Parser) u8 {
        return if (p.i < p.src.len) p.src[p.i] else 0;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    fn advance(p: *Parser) void {
        if (p.i < p.src.len and p.src[p.i] == '\n') {
            p.line += 1;
            p.line_start = p.i + 1;
        }
        p.i += 1;
    }

    /// Pula espaços e comentários. Quebras de linha só se `newlines`.
    fn skipSpace(p: *Parser, newlines: bool) Error!void {
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                p.advance();
            } else if (ch == '\n' and newlines) {
                p.advance();
            } else if (ch == '\\') {
                // Continuação de linha.
                p.advance();
                while (p.peek() == ' ' or p.peek() == '\t' or p.peek() == '\r') p.advance();
                if (p.startsWith("//")) while (p.peek() != '\n' and p.peek() != 0) p.advance();
                if (p.peek() == '\n') p.advance();
            } else if (p.startsWith("//")) {
                while (p.peek() != '\n' and p.peek() != 0) p.advance();
            } else if (p.startsWith("/*")) {
                var depth: usize = 0;
                while (p.i < p.src.len) {
                    if (p.startsWith("/*")) {
                        depth += 1;
                        p.advance();
                        p.advance();
                    } else if (p.startsWith("*/")) {
                        depth -= 1;
                        p.advance();
                        p.advance();
                        if (depth == 0) break;
                    } else p.advance();
                }
                if (depth != 0) return p.fail("comentário /* sem fechar");
            } else break;
        }
    }

    fn nodeList(p: *Parser, in_block: bool) Error![]const Node {
        if (p.depth >= max_depth) return p.fail("blocos aninhados demais");
        p.depth += 1;
        defer p.depth -= 1;
        var list: std.ArrayList(Node) = .empty;
        while (true) {
            try p.skipSpace(true);
            while (p.peek() == ';') {
                p.advance();
                try p.skipSpace(true);
            }
            if (p.i >= p.src.len) {
                if (in_block) return p.fail("faltou fechar '}'");
                break;
            }
            if (p.peek() == '}') {
                if (!in_block) return p.fail("'}' sobrando");
                p.advance();
                break;
            }
            var skip = false;
            if (p.startsWith("/-")) {
                skip = true;
                p.advance();
                p.advance();
                try p.skipSpace(true);
            }
            const n = try p.node();
            if (!skip) try list.append(p.arena, n);
        }
        return list.toOwnedSlice(p.arena);
    }

    fn node(p: *Parser) Error!Node {
        const line = p.line;
        const name = try p.identOrString();
        var args: std.ArrayList(Value) = .empty;
        var props: std.ArrayList(Prop) = .empty;
        var children: []const Node = &.{};

        while (true) {
            try p.skipSpace(false);
            const ch = p.peek();
            if (ch == 0 or ch == '\n' or ch == ';' or ch == '}') break;
            if (ch == '{') {
                p.advance();
                children = try p.nodeList(true);
                break;
            }
            var skip = false;
            if (p.startsWith("/-")) {
                skip = true;
                p.advance();
                p.advance();
                try p.skipSpace(false);
                if (p.peek() == '{') {
                    p.advance();
                    _ = try p.nodeList(true);
                    continue;
                }
            }
            // Propriedade (`chave=valor`) ou argumento.
            const start = p.i;
            if (p.peek() != '"' and !isNumberStart(p)) {
                const key = try p.identOrString();
                if (p.peek() == '=') {
                    p.advance();
                    const v = try p.value();
                    if (!skip) try props.append(p.arena, .{ .key = key, .value = v });
                    continue;
                }
                p.i = start;
            } else if (p.peek() == '"') {
                const key = try p.string();
                if (p.peek() == '=') {
                    p.advance();
                    const v = try p.value();
                    if (!skip) try props.append(p.arena, .{ .key = key, .value = v });
                    continue;
                }
                if (!skip) try args.append(p.arena, .{ .string = key });
                continue;
            }
            const v = try p.value();
            if (!skip) try args.append(p.arena, v);
        }
        return .{
            .name = name,
            .args = try args.toOwnedSlice(p.arena),
            .props = try props.toOwnedSlice(p.arena),
            .children = children,
            .line = line,
        };
    }

    fn isNumberStart(p: *Parser) bool {
        const ch = p.peek();
        if (ch >= '0' and ch <= '9') return true;
        if ((ch == '-' or ch == '+' or ch == '.') and p.i + 1 < p.src.len) {
            const n = p.src[p.i + 1];
            return n >= '0' and n <= '9';
        }
        return false;
    }

    fn value(p: *Parser) Error!Value {
        const ch = p.peek();
        if (ch == '"') return .{ .string = try p.string() };
        if (isNumberStart(p)) return p.number();
        const word = try p.identOrString();
        if (eqlAny(word, &.{ "true", "#true" })) return .{ .boolean = true };
        if (eqlAny(word, &.{ "false", "#false" })) return .{ .boolean = false };
        if (eqlAny(word, &.{ "null", "#null" })) return .null;
        return .{ .string = word };
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
        while (p.i < p.src.len) : (p.i += 1) {
            const ch = p.src[p.i];
            const ok = (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '+' or ch == '_' or ch == 'e' or ch == 'E';
            if (!ok) break;
        }
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (p.src[start..p.i]) |ch| {
            if (ch == '_') continue;
            if (n >= buf.len) return p.fail("número longo demais");
            buf[n] = ch;
            n += 1;
        }
        const v = std.fmt.parseFloat(f64, buf[0..n]) catch return p.fail("número inválido");
        return .{ .number = v };
    }

    fn identOrString(p: *Parser) Error![]const u8 {
        if (p.peek() == '"') return p.string();
        const start = p.i;
        while (p.i < p.src.len) : (p.i += 1) {
            const ch = p.src[p.i];
            const stop = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '=' or ch == ';' or
                ch == '{' or ch == '}' or ch == '"' or ch == '(' or ch == ')' or ch == '\\';
            if (stop) break;
        }
        if (p.i == start) return p.fail("esperava um nome");
        return p.src[start..p.i];
    }

    fn string(p: *Parser) Error![]const u8 {
        p.advance(); // aspas de abertura
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.src.len) return p.fail("string sem fechar");
            const ch = p.src[p.i];
            if (ch == '"') {
                p.advance();
                break;
            }
            if (ch == '\\') {
                p.advance();
                const e = p.peek();
                const r: u8 = switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    else => return p.fail("escape inválido"),
                };
                try out.append(p.arena, r);
                p.advance();
                continue;
            }
            try out.append(p.arena, ch);
            p.advance();
        }
        return out.toOwnedSlice(p.arena);
    }
};

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

test "nós, argumentos, propriedades e filhos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\// comentário
        \\theme "vidro" version=1
        \\layout {
        \\    row gap=10 padding=10.5 {
        \\        guild-bar width=64 style=card; channel-list flex=1
        \\        /- member-list width=200
        \\        messages show-avatars=#false "extra"
        \\    }
        \\}
        \\/* bloco
        \\   /* aninhado */ */
        \\cor "#ff00ff" neg=-2
    ;
    const nodes = try parse(arena.allocator(), src, null);
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("vidro", nodes[0].arg(0).?.string);
    try std.testing.expectEqual(@as(f64, 1), nodes[0].num("version").?);

    const row = nodes[1].children[0];
    try std.testing.expectEqualStrings("row", row.name);
    try std.testing.expectEqual(@as(f64, 10.5), row.num("padding").?);
    try std.testing.expectEqual(@as(usize, 3), row.children.len);
    try std.testing.expectEqualStrings("card", row.children[0].str("style").?);
    try std.testing.expectEqual(false, row.children[2].flag("show-avatars").?);
    try std.testing.expectEqualStrings("extra", row.children[2].arg(0).?.string);
    try std.testing.expectEqual(@as(f64, -2), nodes[2].num("neg").?);
}

test "erro com linha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.SyntaxError, parse(arena.allocator(), "a {\n  b \"sem fim\n", &d));
    try std.testing.expect(d.line >= 2);
}

test "aninhamento absurdo vira erro, não estouro de pilha" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try a.alloc(u8, 200_000);
    for (0..deep.len / 2) |i| {
        deep[i * 2] = 'a';
        deep[i * 2 + 1] = '{';
    }
    try std.testing.expectError(error.SyntaxError, parse(a, deep, null));
}
