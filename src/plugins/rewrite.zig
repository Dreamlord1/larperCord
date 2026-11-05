//! Regras fixas que um plugin deixa com o app para o texto que a pessoa envia:
//! tirar o rastreio dos links, trocar um endereço, trocar uma palavra. São dados,
//! não código: o Lua não vê o que a pessoa escreve e nada roda na tecla nem na
//! mensagem de ninguém. O app aplica aqui, só na hora de enviar, e sem regra
//! nenhuma nem entra.
const std = @import("std");

pub const max_rules = 256;
/// O que não couber numa mensagem fica como a pessoa escreveu.
pub const max_text = 2000;
pub const max_word = 64;
pub const max_with = 200;

pub const Kind = enum(u8) { strip_param, replace_host, word };

pub const Rule = struct {
    kind: Kind,
    /// strip_param: o nome do parâmetro ("utm_*" = todos com esse começo).
    /// replace_host: o endereço de antes. word: a palavra de antes.
    from: []u8,
    /// replace_host e word: o que entra no lugar.
    /// strip_param: só neste endereço e nos subdomínios dele ("" = em todos).
    to: []u8,
};

pub fn freeList(gpa: std.mem.Allocator, list: []Rule) void {
    for (list) |r| {
        gpa.free(r.from);
        gpa.free(r.to);
    }
    gpa.free(list);
}

pub fn dupRule(gpa: std.mem.Allocator, kind: Kind, from: []const u8, to: []const u8) ?Rule {
    const f = gpa.dupe(u8, from) catch return null;
    const t = gpa.dupe(u8, to) catch {
        gpa.free(f);
        return null;
    };
    return .{ .kind = kind, .from = f, .to = t };
}

/// O nome do parâmetro: letras, números, _, -, . e um * só no fim.
pub fn validParam(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |ch, i| {
        if (ch == '*' and i == name.len - 1 and i > 0) continue;
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    }
    return true;
}

/// Uma palavra só, sem espaço nem o que começa um link ou uma menção.
pub fn validWord(w: []const u8) bool {
    if (w.len == 0 or w.len > max_word) return false;
    for (w) |ch| if (!isWord(ch)) return false;
    return true;
}

/// O que entra no lugar de uma palavra: nunca uma menção nem um link, que a pessoa
/// mandaria sem ter escrito.
pub fn validWith(w: []const u8) bool {
    if (w.len == 0 or w.len > max_with) return false;
    return std.mem.indexOfAny(u8, w, "@<") == null and std.mem.indexOf(u8, w, "://") == null;
}

fn isWord(b: u8) bool {
    return b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b);
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\t' or b == '\r';
}

fn sameOrSub(host: []const u8, base: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, base)) return true;
    return host.len > base.len and host[host.len - base.len - 1] == '.' and std.ascii.endsWithIgnoreCase(host, base);
}

fn paramHit(name: []const u8, pattern: []const u8) bool {
    if (pattern.len > 1 and pattern[pattern.len - 1] == '*') {
        return std.ascii.startsWithIgnoreCase(name, pattern[0 .. pattern.len - 1]);
    }
    return std.ascii.eqlIgnoreCase(name, pattern);
}

fn stripped(pair: []const u8, host: []const u8, rules: []const Rule) bool {
    const name = pair[0 .. std.mem.indexOfScalar(u8, pair, '=') orelse pair.len];
    for (rules) |r| {
        if (r.kind != .strip_param) continue;
        if (r.to.len > 0 and !sameOrSub(host, r.to)) continue;
        if (paramHit(name, r.from)) return true;
    }
    return false;
}

/// Quantos bytes o link que começa em `i` ocupa (0 = não é um link).
fn urlLen(text: []const u8, i: usize) usize {
    const rest = text[i..];
    const scheme: usize = if (std.ascii.startsWithIgnoreCase(rest, "https://")) 8 else if (std.ascii.startsWithIgnoreCase(rest, "http://")) 7 else return 0;
    var end = scheme;
    while (end < rest.len and !isSpace(rest[end]) and rest[end] != '<' and rest[end] != '>' and rest[end] != '"') end += 1;
    // A pontuação logo depois é da frase, não do link.
    while (end > scheme) {
        const last = rest[end - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?'*_~|", last) != null) {
            end -= 1;
        } else if (last == ')') {
            const open = std.mem.count(u8, rest[0..end], "(");
            const close = std.mem.count(u8, rest[0..end], ")");
            if (close <= open) break;
            end -= 1;
        } else break;
    }
    return if (end > scheme) end else 0;
}

fn rewriteUrl(gpa: std.mem.Allocator, out: *std.ArrayList(u8), url: []const u8, rules: []const Rule) !void {
    const after_scheme = (std.mem.indexOf(u8, url, "://") orelse return out.appendSlice(gpa, url)) + 3;
    const rest = url[after_scheme..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];
    // Com "usuário@": não é o endereço que parece. Fica como está.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return out.appendSlice(gpa, url);
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..colon];
    var tail = rest[auth_end..];
    var frag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, tail, '#')) |h| {
        frag = tail[h..];
        tail = tail[0..h];
    }
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, tail, '?')) |q| {
        query = tail[q + 1..];
        tail = tail[0..q];
    }

    var new_host = host;
    for (rules) |r| {
        if (r.kind != .replace_host) continue;
        const www = std.ascii.startsWithIgnoreCase(host, "www.") and std.ascii.eqlIgnoreCase(host[4..], r.from);
        if (www or std.ascii.eqlIgnoreCase(host, r.from)) {
            new_host = r.to;
            break;
        }
    }
    try out.appendSlice(gpa, url[0..after_scheme]);
    try out.appendSlice(gpa, new_host);
    try out.appendSlice(gpa, authority[colon..]);
    try out.appendSlice(gpa, tail);
    if (query) |qs| {
        var any = false;
        var scan = std.mem.splitScalar(u8, qs, '&');
        while (scan.next()) |pair| if (pair.len > 0 and stripped(pair, host, rules)) {
            any = true;
        };
        if (!any) {
            try out.append(gpa, '?');
            try out.appendSlice(gpa, qs);
        } else {
            var first = true;
            var it = std.mem.splitScalar(u8, qs, '&');
            while (it.next()) |pair| {
                if (pair.len == 0 or stripped(pair, host, rules)) continue;
                try out.append(gpa, if (first) '?' else '&');
                try out.appendSlice(gpa, pair);
                first = false;
            }
        }
    }
    try out.appendSlice(gpa, frag);
}

fn wordRule(word: []const u8, rules: []const Rule) ?[]const u8 {
    for (rules) |r| {
        if (r.kind == .word and std.ascii.eqlIgnoreCase(word, r.from)) return r.to;
    }
    return null;
}

/// O texto com as regras aplicadas. null = fica como está: nada mudou, ou o
/// resultado ficaria vazio ou maior do que cabe numa mensagem. Bloco de código,
/// menção e emoji passam intactos.
pub fn apply(gpa: std.mem.Allocator, text: []const u8, rules: []const Rule) !?[]u8 {
    if (rules.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "```")) {
            const end = if (std.mem.indexOfPos(u8, text, i + 3, "```")) |e| e + 3 else text.len;
            try out.appendSlice(gpa, text[i..end]);
            i = end;
            continue;
        }
        if (rest[0] == '`') if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
            try out.appendSlice(gpa, text[i .. close + 1]);
            i = close + 1;
            continue;
        };
        // <@123>, <#123>, <:nome:123>, <a:nome:123>, <t:123>: inteiros.
        if (rest[0] == '<' and rest.len > 2 and std.mem.indexOfScalar(u8, "@#:at", rest[1]) != null) {
            if (std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 128)], '>')) |close| {
                try out.appendSlice(gpa, rest[0 .. close + 1]);
                i += close + 1;
                continue;
            }
        }
        const n = urlLen(text, i);
        if (n > 0) {
            try rewriteUrl(gpa, &out, rest[0..n], rules);
            i += n;
            continue;
        }
        if (isWord(rest[0])) {
            var end = i;
            while (end < text.len and isWord(text[end])) end += 1;
            const word = text[i..end];
            // "@nome", "#canal", ":emoji" e o resto de um caminho não são palavras soltas.
            const glued = i > 0 and std.mem.indexOfScalar(u8, "@#:/.-", text[i - 1]) != null;
            try out.appendSlice(gpa, (if (glued) null else wordRule(word, rules)) orelse word);
            i = end;
            continue;
        }
        try out.append(gpa, rest[0]);
        i += 1;
    }
    if (out.items.len == 0 or out.items.len > max_text or std.mem.eql(u8, out.items, text)) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

const T = struct {
    var from_buf: [8][64]u8 = undefined;
    var to_buf: [8][64]u8 = undefined;
    var n: usize = 0;

    fn rule(kind: Kind, from: []const u8, to: []const u8) Rule {
        const i = n;
        n += 1;
        @memcpy(from_buf[i][0..from.len], from);
        @memcpy(to_buf[i][0..to.len], to);
        return .{ .kind = kind, .from = from_buf[i][0..from.len], .to = to_buf[i][0..to.len] };
    }

    fn check(rules: []const Rule, text: []const u8, want: ?[]const u8) !void {
        const got = try apply(std.testing.allocator, text, rules);
        defer if (got) |g| std.testing.allocator.free(g);
        if (want) |w| {
            try std.testing.expectEqualStrings(w, got orelse return error.NadaMudou);
        } else if (got) |g| {
            std.debug.print("mudou: {s}\n", .{g});
            return error.NaoDeviaMudar;
        }
    }
};

test "regras: tira o rastreio e deixa o resto do link" {
    T.n = 0;
    const rules = [_]Rule{
        T.rule(.strip_param, "utm_*", ""),
        T.rule(.strip_param, "fbclid", ""),
        T.rule(.strip_param, "si", "youtu.be"),
    };
    try T.check(&rules, "veja https://a.com/x?utm_source=z&id=1&UTM_medium=y#topo!", "veja https://a.com/x?id=1#topo!");
    try T.check(&rules, "https://a.com/?fbclid=abc", "https://a.com/");
    // Só no endereço pedido, e nos subdomínios dele.
    try T.check(&rules, "https://youtu.be/abc?si=xyz&t=10", "https://youtu.be/abc?t=10");
    try T.check(&rules, "https://www.youtu.be/abc?si=xyz", "https://www.youtu.be/abc");
    try T.check(&rules, "https://outro.com/abc?si=xyz", null);
    // Pontuação e parênteses da frase ficam de fora do link.
    try T.check(&rules, "(https://a.com/x?utm_a=1), fim.", "(https://a.com/x), fim.");
    try T.check(&rules, "[texto](https://a.com/x?utm_a=1)", "[texto](https://a.com/x)");
    try T.check(&rules, "<https://a.com/x?utm_a=1>", "<https://a.com/x>");
    // Parêntese que é do próprio link fica.
    try T.check(&rules, "https://a.com/x_(y)?utm_a=1", "https://a.com/x_(y)");
    // Sem mudança: null, e o link não é refeito.
    try T.check(&rules, "https://a.com/x?a=1&&b=2", null);
    try T.check(&rules, "sem link nenhum", null);
    // Com usuário na frente, o endereço não é o que parece: não mexe.
    try T.check(&rules, "https://a.com@b.com/?utm_a=1", null);
}

test "regras: código e menção passam intactos" {
    T.n = 0;
    const rules = [_]Rule{ T.rule(.strip_param, "utm_*", ""), T.rule(.word, "vc", "você") };
    try T.check(&rules, "`https://a.com/?utm_a=1` vc", "`https://a.com/?utm_a=1` você");
    try T.check(&rules, "```\nvc https://a.com/?utm_a=1\n``` vc", "```\nvc https://a.com/?utm_a=1\n``` você");
    try T.check(&rules, "<@123> <:vc:55> <t:123:R> <#9> vc", "<@123> <:vc:55> <t:123:R> <#9> você");
    try T.check(&rules, "`sem fechar vc", "`sem fechar você");
}

test "regras: palavra inteira e endereço trocado" {
    T.n = 0;
    const rules = [_]Rule{ T.rule(.word, "vc", "você"), T.rule(.replace_host, "old.example.com", "new.example.com") };
    try T.check(&rules, "VC e vcs e ávc", "você e vcs e ávc");
    try T.check(&rules, "@vc #vc :vc a/vc", null);
    try T.check(&rules, "https://old.example.com/a?b=1", "https://new.example.com/a?b=1");
    try T.check(&rules, "https://www.old.example.com:8080/a", "https://new.example.com:8080/a");
    try T.check(&rules, "https://sub.old.example.com/a", null);
    try T.check(&rules, "https://notold.example.com/a", null);
}

test "regras: nunca passa do tamanho de uma mensagem nem esvazia" {
    T.n = 0;
    var long: [1999]u8 = undefined;
    @memset(&long, 'x');
    long[0] = 'v';
    long[1] = 'c';
    long[2] = ' ';
    const rules = [_]Rule{T.rule(.word, "vc", "você aqui e agora")};
    try T.check(&rules, &long, null);
    const none = [_]Rule{};
    try T.check(&none, "vc", null);
    T.n = 0;
    const gone = [_]Rule{T.rule(.word, "vc", "")};
    try T.check(&gone, "vc", null);
}

test "regras: o que vale como nome" {
    try std.testing.expect(validParam("utm_*") and validParam("a.b-c_d") and !validParam("*") and !validParam("a b") and !validParam("a*b") and !validParam(""));
    try std.testing.expect(validWord("você") and validWord("a_1") and !validWord("a b") and !validWord("") and !validWord("a-b"));
    try std.testing.expect(validWith("por exemplo") and !validWith("") and !validWith("@everyone") and !validWith("<@123>") and !validWith("veja https://a.com"));
}
