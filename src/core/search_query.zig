//! Busca local (Ctrl+F): interpreta a consulta e compara textos.
//!
//!   ziglang from:ana in:geral has:link has:imagem "frase com espaço"
//!
//! Sem diferença de maiúsculas nem de acentos ("nao" acha "não").
const std = @import("std");

pub const max_terms = 8;

pub const Query = struct {
    terms_buf: [max_terms][64]u8 = undefined,
    terms_len: [max_terms]u8 = @splat(0),
    n_terms: usize = 0,
    from_buf: [64]u8 = undefined,
    from_len: u8 = 0,
    in_buf: [64]u8 = undefined,
    in_len: u8 = 0,
    has_link: bool = false,
    has_image: bool = false,
    has_file: bool = false,

    pub fn term(q: *const Query, i: usize) []const u8 {
        return q.terms_buf[i][0..q.terms_len[i]];
    }
    pub fn from(q: *const Query) []const u8 {
        return q.from_buf[0..q.from_len];
    }
    pub fn in(q: *const Query) []const u8 {
        return q.in_buf[0..q.in_len];
    }

    /// Nada para procurar (nem texto nem filtro).
    pub fn empty(q: *const Query) bool {
        return q.n_terms == 0 and q.from_len == 0 and q.in_len == 0 and !q.has_link and !q.has_image and !q.has_file;
    }

    pub fn parse(src: []const u8) Query {
        var q: Query = .{};
        var i: usize = 0;
        while (i < src.len) {
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            if (i >= src.len) break;
            // Palavra (ou "frase entre aspas"), com o prefixo antes dos dois-pontos.
            var key: []const u8 = "";
            const start = i;
            while (i < src.len and src[i] != ' ' and src[i] != ':' and src[i] != '"') i += 1;
            if (i < src.len and src[i] == ':' and i > start) {
                key = src[start..i];
                i += 1;
            } else i = start;
            var val: []const u8 = undefined;
            if (i < src.len and src[i] == '"') {
                const v0 = i + 1;
                i = v0;
                while (i < src.len and src[i] != '"') i += 1;
                val = src[v0..i];
                if (i < src.len) i += 1;
            } else {
                const v0 = i;
                while (i < src.len and src[i] != ' ' and src[i] != '\t') i += 1;
                val = src[v0..i];
            }
            if (eqlFold(key, "from") or eqlFold(key, "de")) {
                q.from_len = @intCast(foldInto(&q.from_buf, val).len);
            } else if (eqlFold(key, "in") or eqlFold(key, "em")) {
                // "in:#geral" também vale.
                q.in_len = @intCast(foldInto(&q.in_buf, std.mem.trimStart(u8, val, "#@")).len);
            } else if (eqlFold(key, "has") or eqlFold(key, "tem")) {
                if (eqlFold(val, "link") or eqlFold(val, "url")) q.has_link = true;
                if (eqlFold(val, "imagem") or eqlFold(val, "image") or eqlFold(val, "img") or eqlFold(val, "foto")) q.has_image = true;
                if (eqlFold(val, "arquivo") or eqlFold(val, "file") or eqlFold(val, "anexo") or eqlFold(val, "attachment")) q.has_file = true;
            } else {
                // Prefixo desconhecido ("http:" de um link colado): é texto.
                const whole = if (key.len > 0) src[start..i] else val;
                if (whole.len == 0 or q.n_terms == max_terms) continue;
                const t = foldInto(&q.terms_buf[q.n_terms], std.mem.trim(u8, whole, "\""));
                if (t.len == 0) continue;
                q.terms_len[q.n_terms] = @intCast(t.len);
                q.n_terms += 1;
            }
        }
        return q;
    }
};

/// Próximo caractere já "dobrado": minúsculo e sem acento (latinos comuns).
/// Outros caracteres UTF-8 passam byte a byte.
fn nextFold(s: []const u8, i: *usize) u8 {
    const b = s[i.*];
    if (b == 0xC3 and i.* + 1 < s.len) {
        const x = s[i.* + 1];
        const folded: u8 = switch (x | 0x20) {
            0xA0...0xA5 => 'a',
            0xA7 => 'c',
            0xA8...0xAB => 'e',
            0xAC...0xAF => 'i',
            0xB1 => 'n',
            0xB2...0xB6 => 'o',
            0xB9...0xBC => 'u',
            0xBD, 0xBF => 'y',
            else => 0,
        };
        if (folded != 0 and x >= 0x80 and x <= 0xBF and x != 0x97 and x != 0xB7 and x != 0x9F) {
            i.* += 2;
            return folded;
        }
    }
    i.* += 1;
    return std.ascii.toLower(b);
}

/// Copia `s` dobrado para `buf` (corta no tamanho do buffer).
pub fn foldInto(buf: []u8, s: []const u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < buf.len) {
        buf[n] = nextFold(s, &i);
        n += 1;
    }
    return buf[0..n];
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Onde `needle` (já dobrado) aparece em `hay`: faixa de bytes em `hay`.
pub fn findFold(hay: []const u8, needle: []const u8) ?[2]usize {
    if (needle.len == 0) return .{ 0, 0 };
    var start: usize = 0;
    while (start < hay.len) {
        var i = start;
        var k: usize = 0;
        while (k < needle.len and i < hay.len) : (k += 1) {
            if (nextFold(hay, &i) != needle[k]) break;
        } else if (k == needle.len) return .{ start, i };
        // Avança um caractere inteiro (não para no meio de um UTF-8).
        start += 1;
        while (start < hay.len and (hay[start] & 0xC0) == 0x80) start += 1;
    }
    return null;
}

pub fn containsFold(hay: []const u8, needle: []const u8) bool {
    return findFold(hay, needle) != null;
}

pub fn hasLink(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "https://") != null or std.mem.indexOf(u8, s, "http://") != null;
}

test "consulta com filtros, aspas e acentos" {
    const q = Query.parse("Não sei from:Ana.exe in:#geral has:link has:imagem \"meio termo\" http://x.y");
    try std.testing.expectEqual(@as(usize, 4), q.n_terms);
    try std.testing.expectEqualStrings("nao", q.term(0));
    try std.testing.expectEqualStrings("sei", q.term(1));
    try std.testing.expectEqualStrings("meio termo", q.term(2));
    try std.testing.expectEqualStrings("http://x.y", q.term(3));
    try std.testing.expectEqualStrings("ana.exe", q.from());
    try std.testing.expectEqualStrings("geral", q.in());
    try std.testing.expect(q.has_link and q.has_image and !q.has_file);
    try std.testing.expect(Query.parse("   ").empty());
}

test "comparação sem maiúsculas nem acentos" {
    try std.testing.expect(containsFold("Eu NÃO acredito", "nao acre"));
    try std.testing.expect(containsFold("Ação", "acao"));
    try std.testing.expect(!containsFold("abc", "abd"));
    const r = findFold("olá Mundo", "mundo").?;
    try std.testing.expectEqual(@as(usize, 5), r[0]);
    try std.testing.expectEqual(@as(usize, 10), r[1]);
    try std.testing.expect(hasLink("veja https://ziglang.org"));
}
