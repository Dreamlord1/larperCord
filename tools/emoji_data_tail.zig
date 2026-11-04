pub const Entry = struct {
    glyph: []const u8,
    /// O nome de digitar (`:nome:`).
    code: []const u8,
    en: []const u8,
    pt: []const u8,
};

pub fn get(i: usize) Entry {
    const line = blob[offsets[i] .. offsets[i + 1] - 1];
    var it = std.mem.splitScalar(u8, line, '|');
    const glyph = it.next() orelse "";
    const code = it.next() orelse "";
    const en = it.next() orelse "";
    const pt = it.next() orelse "";
    return .{ .glyph = glyph, .code = code, .en = en, .pt = pt };
}

/// Só o emoji da linha i (o desenho da grade não precisa do resto).
pub fn glyphOf(i: usize) []const u8 {
    const line = blob[offsets[i]..offsets[i + 1]];
    return line[0 .. std.mem.indexOfScalar(u8, line, '|') orelse 0];
}

/// Categoria em que está o emoji i.
pub fn categoryOf(i: usize) usize {
    for (categories, 0..) |cat, k| {
        if (i < @as(usize, cat.first) + cat.count) return k;
    }
    return categories.len - 1;
}

/// O emoji com este nome exato (`:joy:` digitado à mão). Varre a tabela: é
/// só na hora de enviar.
pub fn byCode(code: []const u8) ?u16 {
    if (code.len == 0) return null;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const line = blob[offsets[i]..offsets[i + 1]];
        const bar = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const rest = line[bar + 1..];
        if (rest.len > code.len and rest[code.len] == '|' and std.mem.eql(u8, rest[0..code.len], code)) return i;
    }
    return null;
}

/// Minúsculas e sem acento, como as palavras da tabela. `buf` tem que caber
/// `q` (o resultado nunca é maior).
pub fn fold(buf: []u8, q: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < q.len and n < buf.len) {
        const ch = q[i];
        if (ch == 0xC3 and i + 1 < q.len) {
            const up = q[i + 1] | 0x20;
            buf[n] = switch (up) {
                0xA0...0xA5 => 'a',
                0xA7 => 'c',
                0xA8...0xAB => 'e',
                0xAC...0xAF => 'i',
                0xB1 => 'n',
                0xB2...0xB6 => 'o',
                0xB9...0xBC => 'u',
                else => '?',
            };
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = std.ascii.toLower(ch);
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn wordStart(hay: []const u8, at: usize) bool {
    return at == 0 or !std.ascii.isAlphanumeric(hay[at - 1]);
}

/// Quanto o texto casa com a busca (já com `fold`): 0 = não casa.
/// Vale para o nome de um emoji personalizado também.
pub fn matchName(name: []const u8, q: []const u8) i32 {
    if (name.len < q.len) return 0;
    if (std.ascii.eqlIgnoreCase(name, q)) return 1000;
    if (std.ascii.startsWithIgnoreCase(name, q)) return 800 - @as(i32, @intCast(@min(name.len, 60)));
    const at = std.ascii.findIgnoreCase(name, q) orelse return 0;
    return (if (wordStart(name, at)) @as(i32, 500) else 300) - @as(i32, @intCast(@min(name.len, 60)));
}

fn score(e: Entry, q: []const u8) i32 {
    const s = matchName(e.code, q);
    if (s != 0) return s;
    // Palavras: as duas línguas valem o mesmo; começo de palavra vale mais.
    var best: i32 = 0;
    for ([_][]const u8{ e.en, e.pt }) |hay| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, hay, from, q)) |at| {
            if (wordStart(hay, at)) {
                best = @max(best, 200);
                break;
            }
            best = @max(best, 60);
            from = at + 1;
        }
    }
    return best;
}

pub const Hit = struct { index: u16, score: i32 };

/// Os melhores resultados para `query`, do melhor para o pior. Roda só quando
/// o texto da busca muda.
pub fn search(query: []const u8, out: []Hit) []Hit {
    var qb: [64]u8 = undefined;
    const q = fold(&qb, query);
    if (q.len == 0 or out.len == 0) return out[0..0];
    var n: usize = 0;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const sc = score(get(i), q);
        if (sc == 0) continue;
        // Inserção ordenada: empate fica na ordem do Unicode.
        var k = n;
        if (n == out.len) {
            if (sc <= out[n - 1].score) continue;
            k = n - 1;
        } else n += 1;
        while (k > 0 and out[k - 1].score < sc) : (k -= 1) out[k] = out[k - 1];
        out[k] = .{ .index = i, .score = sc };
    }
    return out[0..n];
}

test "tabela de emoji" {
    try std.testing.expectEqual(@as(usize, count + 1), offsets.len);
    try std.testing.expectEqualStrings("😀", glyphOf(0));
    const joy = byCode("joy").?;
    try std.testing.expectEqualStrings("😂", get(joy).glyph);
    try std.testing.expect(byCode("nao_existe_isso") == null);
    var hits: [16]Hit = undefined;
    const r = search("joy", &hits);
    try std.testing.expect(r.len > 0);
    try std.testing.expectEqualStrings("😂", get(r[0].index).glyph);
    // Em português, com ou sem acento.
    const r2 = search("coração", &hits);
    try std.testing.expect(r2.len > 0);
    try std.testing.expect(search("zzzqqq", &hits).len == 0);
    try std.testing.expect(categoryOf(0) == 0);
    // Tudo tem nome e nenhum nome se repete à toa.
    for (0..count) |i| try std.testing.expect(get(i).code.len > 0);
}
