//! PNG animado (APNG), sem dependências (testado no `zig build test`).
//! Cada quadro vira um PNG comum (IHDR com o tamanho do quadro, os chunks
//! antes do IDAT, os dados do quadro como IDAT e IEND) que quem chama
//! decodifica; aqui só se monta o quadro e se compõe na tela cheia
//! (posição, descarte e mistura do fcTL).
const std = @import("std");

const signature = "\x89PNG\r\n\x1a\n";

const Chunk = struct {
    kind: [4]u8,
    body: []const u8,
    /// Começo do chunk (o campo de tamanho) e o fim (depois do CRC).
    start: usize,
    end: usize,

    fn is(ch: Chunk, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &ch.kind, kind);
    }
};

fn chunkAt(data: []const u8, pos: usize) ?Chunk {
    if (pos + 12 > data.len) return null;
    const len = std.mem.readInt(u32, data[pos..][0..4], .big);
    if (len > 0x7fff_ffff or data.len - pos - 12 < len) return null;
    return .{
        .kind = data[pos + 4 ..][0..4].*,
        .body = data[pos + 8 ..][0..len],
        .start = pos,
        .end = pos + 12 + len,
    };
}

/// É PNG e tem acTL antes do primeiro IDAT (senão é uma imagem só).
pub fn isAnimated(data: []const u8) bool {
    if (!std.mem.startsWith(u8, data, signature)) return false;
    var pos: usize = signature.len;
    while (chunkAt(data, pos)) |ch| : (pos = ch.end) {
        if (ch.is("acTL")) return true;
        if (ch.is("IDAT") or ch.is("IEND")) return false;
    }
    return false;
}

/// Um quadro: o retângulo dentro da tela cheia e o que fazer com ele.
pub const FrameCtl = struct {
    w: u32,
    h: u32,
    x: u32,
    y: u32,
    delay_ms: u32,
    /// 0 nada, 1 limpa o retângulo, 2 volta ao que era antes do quadro.
    dispose: u8,
    /// 0 substitui, 1 por cima (alpha).
    blend: u8,
};

pub const Error = error{ Invalid, TooBig, Decode, OutOfMemory };

/// Percorre os quadros, montando cada um como um PNG avulso.
pub const Frames = struct {
    data: []const u8,
    w: u32,
    h: u32,
    ihdr: [13]u8,
    /// Chunks entre o IHDR e o primeiro IDAT (PLTE, tRNS, gAMA...).
    pre_start: usize,
    pre_end: usize,
    pos: usize,

    pub fn init(data: []const u8) Error!Frames {
        if (!std.mem.startsWith(u8, data, signature)) return error.Invalid;
        const ihdr = chunkAt(data, signature.len) orelse return error.Invalid;
        if (!ihdr.is("IHDR") or ihdr.body.len != 13) return error.Invalid;
        var pos = ihdr.end;
        while (chunkAt(data, pos)) |ch| : (pos = ch.end) {
            if (ch.is("IDAT")) break;
            if (ch.is("IEND")) return error.Invalid;
        } else return error.Invalid;
        const w = std.mem.readInt(u32, ihdr.body[0..4], .big);
        const h = std.mem.readInt(u32, ihdr.body[4..8], .big);
        if (w == 0 or h == 0) return error.Invalid;
        return .{ .data = data, .w = w, .h = h, .ihdr = ihdr.body[0..13].*, .pre_start = ihdr.end, .pre_end = pos, .pos = ihdr.end };
    }

    /// O próximo quadro, já como PNG em `out` (que é esvaziado antes).
    /// null quando acabou.
    pub fn next(it: *Frames, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Error!?FrameCtl {
        // Acha o fcTL (os IDAT da imagem padrão que não faz parte da
        // animação ficam para trás).
        const fc_chunk = while (chunkAt(it.data, it.pos)) |ch| {
            it.pos = ch.end;
            if (ch.is("fcTL")) break ch;
            if (ch.is("IEND")) return null;
        } else return null;
        const fc = try parseFcTL(fc_chunk.body, it.w, it.h);

        out.clearRetainingCapacity();
        try out.appendSlice(gpa, signature);
        var ihdr = it.ihdr;
        std.mem.writeInt(u32, ihdr[0..4], fc.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], fc.h, .big);
        try writeChunk(gpa, out, "IHDR", &ihdr);
        var p = it.pre_start;
        while (p < it.pre_end) {
            const ch = chunkAt(it.data, p).?;
            p = ch.end;
            if (ch.is("acTL") or ch.is("fcTL")) continue;
            try out.appendSlice(gpa, it.data[ch.start..ch.end]);
        }
        // Dados do quadro até o próximo fcTL (ou o fim).
        var parts: usize = 0;
        while (chunkAt(it.data, it.pos)) |ch| {
            if (ch.is("fcTL") or ch.is("IEND")) break;
            it.pos = ch.end;
            if (ch.is("IDAT")) {
                try writeChunk(gpa, out, "IDAT", ch.body);
                parts += 1;
            } else if (ch.is("fdAT")) {
                // fdAT = número de sequência (4 bytes) + o mesmo que um IDAT.
                if (ch.body.len < 4) return error.Invalid;
                try writeChunk(gpa, out, "IDAT", ch.body[4..]);
                parts += 1;
            }
        }
        if (parts == 0) return error.Invalid;
        try writeChunk(gpa, out, "IEND", "");
        return fc;
    }
};

fn parseFcTL(b: []const u8, cw: u32, ch: u32) Error!FrameCtl {
    if (b.len < 26) return error.Invalid;
    const w = std.mem.readInt(u32, b[4..8], .big);
    const h = std.mem.readInt(u32, b[8..12], .big);
    const x = std.mem.readInt(u32, b[12..16], .big);
    const y = std.mem.readInt(u32, b[16..20], .big);
    const num = std.mem.readInt(u16, b[20..22], .big);
    const den = std.mem.readInt(u16, b[22..24], .big);
    if (w == 0 or h == 0 or @as(u64, x) + w > cw or @as(u64, y) + h > ch) return error.Invalid;
    if (b[24] > 2 or b[25] > 1) return error.Invalid;
    // Denominador 0 quer dizer centésimos de segundo.
    const d: u32 = if (den == 0) 100 else den;
    return .{ .w = w, .h = h, .x = x, .y = y, .delay_ms = @as(u32, num) * 1000 / d, .dispose = b[24], .blend = b[25] };
}

fn writeChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, crc.final(), .big);
    try out.appendSlice(gpa, &tail);
}

/// Toca a animação: cada quadro é decodificado por `ctx.decode(png, w, h,
/// rgba_out) bool` e a tela cheia composta (RGBA, w×h da imagem) vai para
/// `ctx.emit(rgba, w, h, delay_ms) bool` (false para parar). Memória: a
/// tela, uma cópia para o descarte "anterior" e o quadro decodificado.
/// Retorna quantos quadros saíram.
pub fn play(gpa: std.mem.Allocator, data: []const u8, max_side: u32, ctx: anytype) Error!usize {
    var it = try Frames.init(data);
    if (it.w > max_side or it.h > max_side) return error.TooBig;
    const size = @as(usize, it.w) * it.h * 4;
    const canvas = try gpa.alloc(u8, size);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    const scratch = try gpa.alloc(u8, size);
    defer gpa.free(scratch);
    var prev: ?[]u8 = null;
    defer if (prev) |pv| gpa.free(pv);
    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(gpa);

    var n: usize = 0;
    while (it.next(gpa, &png) catch |err| if (n > 0) null else return err) |fc| {
        // No primeiro quadro, "voltar ao anterior" é limpar.
        const dispose: u8 = if (n == 0 and fc.dispose == 2) 1 else fc.dispose;
        if (dispose == 2) {
            const pv = prev orelse try gpa.alloc(u8, size);
            prev = pv;
            @memcpy(pv, canvas);
        }
        const fr = scratch[0 .. @as(usize, fc.w) * fc.h * 4];
        // Um quadro quebrado no meio encerra a animação ali.
        if (!ctx.decode(png.items, fc.w, fc.h, fr)) {
            if (n == 0) return error.Decode;
            break;
        }
        blit(canvas, it.w, fc, fr);
        n += 1;
        if (!ctx.emit(canvas, it.w, it.h, fc.delay_ms)) break;
        switch (dispose) {
            1 => fill(canvas, it.w, fc),
            2 => @memcpy(canvas, prev.?),
            else => {},
        }
    }
    return n;
}

/// Desenha o quadro na tela, substituindo ou por cima (alpha não
/// pré-multiplicado, como sai do PNG).
fn blit(canvas: []u8, cw: u32, fc: FrameCtl, src: []const u8) void {
    const row = @as(usize, fc.w) * 4;
    for (0..fc.h) |y| {
        const d = canvas[((fc.y + y) * cw + fc.x) * 4 ..][0..row];
        const s = src[y * row ..][0..row];
        if (fc.blend == 0) {
            @memcpy(d, s);
            continue;
        }
        var i: usize = 0;
        while (i < row) : (i += 4) {
            const sa: u32 = s[i + 3];
            if (sa == 0) continue;
            if (sa == 255) {
                @memcpy(d[i..][0..4], s[i..][0..4]);
                continue;
            }
            const da: u32 = d[i + 3];
            // Alpha final vezes 255.
            const oa = sa * 255 + da * (255 - sa);
            for (0..3) |k| d[i + k] = @intCast((@as(u32, s[i + k]) * sa * 255 + @as(u32, d[i + k]) * da * (255 - sa) + oa / 2) / oa);
            d[i + 3] = @intCast((oa + 127) / 255);
        }
    }
}

/// Limpa o retângulo do quadro (transparente).
fn fill(canvas: []u8, cw: u32, fc: FrameCtl) void {
    const row = @as(usize, fc.w) * 4;
    for (0..fc.h) |y| @memset(canvas[((fc.y + y) * cw + fc.x) * 4 ..][0..row], 0);
}

// --- Testes ---------------------------------------------------------------------

const testing = std.testing;

/// zlib com blocos "stored" (sem compressão): dá para montar à mão.
fn zlibStored(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x78, 0x01 });
    std.debug.assert(raw.len <= 0xffff);
    const len: u16 = @intCast(raw.len);
    try out.append(gpa, 0x01);
    try out.appendSlice(gpa, &.{ @truncate(len), @truncate(len >> 8), @truncate(~len), @truncate(~len >> 8) });
    try out.appendSlice(gpa, raw);
    var a: [4]u8 = undefined;
    std.mem.writeInt(u32, &a, std.hash.Adler32.hash(raw), .big);
    try out.appendSlice(gpa, &a);
    return out.toOwnedSlice(gpa);
}

/// Linhas RGBA com filtro 0, comprimidas, de um retângulo de uma cor só.
fn solid(gpa: std.mem.Allocator, w: u32, h: u32, rgba: [4]u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..h) |_| {
        try raw.append(gpa, 0);
        for (0..w) |_| try raw.appendSlice(gpa, &rgba);
    }
    return zlibStored(gpa, raw.items);
}

const TestFrame = struct { w: u32, h: u32, x: u32, y: u32, dispose: u8, blend: u8, color: [4]u8, delay: [2]u16 = .{ 1, 10 } };

/// APNG 4×4 RGBA. `default_in_anim`: o primeiro fcTL vem antes do IDAT.
fn buildApng(gpa: std.mem.Allocator, frames: []const TestFrame, default_in_anim: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, signature);
    try writeChunk(gpa, &out, "IHDR", &.{ 0, 0, 0, 4, 0, 0, 0, 4, 8, 6, 0, 0, 0 });
    var actl: [8]u8 = undefined;
    std.mem.writeInt(u32, actl[0..4], @intCast(frames.len), .big);
    std.mem.writeInt(u32, actl[4..8], 0, .big);
    try writeChunk(gpa, &out, "acTL", &actl);
    try writeChunk(gpa, &out, "gAMA", &.{ 0, 0, 0xb1, 0x8f });
    var seq: u32 = 0;
    if (!default_in_anim) {
        const z = try solid(gpa, 4, 4, .{ 9, 9, 9, 255 });
        defer gpa.free(z);
        try writeChunk(gpa, &out, "IDAT", z);
    }
    for (frames, 0..) |f, i| {
        var fc: [26]u8 = undefined;
        std.mem.writeInt(u32, fc[0..4], seq, .big);
        seq += 1;
        std.mem.writeInt(u32, fc[4..8], f.w, .big);
        std.mem.writeInt(u32, fc[8..12], f.h, .big);
        std.mem.writeInt(u32, fc[12..16], f.x, .big);
        std.mem.writeInt(u32, fc[16..20], f.y, .big);
        std.mem.writeInt(u16, fc[20..22], f.delay[0], .big);
        std.mem.writeInt(u16, fc[22..24], f.delay[1], .big);
        fc[24] = f.dispose;
        fc[25] = f.blend;
        try writeChunk(gpa, &out, "fcTL", &fc);
        const z = try solid(gpa, f.w, f.h, f.color);
        defer gpa.free(z);
        if (i == 0 and default_in_anim) {
            // Dividido em dois IDAT, como os encoders costumam fazer.
            try writeChunk(gpa, &out, "IDAT", z[0 .. z.len / 2]);
            try writeChunk(gpa, &out, "IDAT", z[z.len / 2 ..]);
        } else {
            const body = try gpa.alloc(u8, z.len + 4);
            defer gpa.free(body);
            std.mem.writeInt(u32, body[0..4], seq, .big);
            seq += 1;
            @memcpy(body[4..], z);
            try writeChunk(gpa, &out, "fdAT", body);
        }
    }
    try writeChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

/// Decodificador de teste: confere que o PNG montado é válido (assinatura,
/// CRCs, IHDR do tamanho do quadro, zlib inteiro) e tira as linhas (filtro 0).
fn testDecode(png: []const u8, w: u32, h: u32, out: []u8) !void {
    const gpa = testing.allocator;
    try testing.expect(std.mem.startsWith(u8, png, signature));
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var pos: usize = signature.len;
    var kinds: std.ArrayList(u8) = .empty;
    defer kinds.deinit(gpa);
    var ended = false;
    while (chunkAt(png, pos)) |ch| : (pos = ch.end) {
        var crc = std.hash.Crc32.init();
        crc.update(&ch.kind);
        crc.update(ch.body);
        try testing.expectEqual(crc.final(), std.mem.readInt(u32, png[ch.end - 4 ..][0..4], .big));
        try testing.expect(!ch.is("acTL") and !ch.is("fcTL") and !ch.is("fdAT"));
        try kinds.appendSlice(gpa, &ch.kind);
        if (ch.is("IHDR")) {
            try testing.expectEqual(w, std.mem.readInt(u32, ch.body[0..4], .big));
            try testing.expectEqual(h, std.mem.readInt(u32, ch.body[4..8], .big));
        }
        if (ch.is("IDAT")) try idat.appendSlice(gpa, ch.body);
        if (ch.is("IEND")) ended = true;
    }
    try testing.expect(ended and pos == png.len);
    try testing.expect(std.mem.startsWith(u8, kinds.items, "IHDRgAMAIDAT"));
    var in: std.Io.Reader = .fixed(idat.items);
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    const raw = try dec.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    const row = w * 4;
    try testing.expectEqual(@as(usize, h * (row + 1)), raw.len);
    for (0..h) |y| {
        try testing.expectEqual(@as(u8, 0), raw[y * (row + 1)]);
        @memcpy(out[y * row ..][0..row], raw[y * (row + 1) + 1 ..][0..row]);
    }
}

const TestCtx = struct {
    frames: std.ArrayList([]u8) = .empty,
    delays: std.ArrayList(u32) = .empty,
    bad: bool = false,

    fn deinit(t: *TestCtx) void {
        for (t.frames.items) |f| testing.allocator.free(f);
        t.frames.deinit(testing.allocator);
        t.delays.deinit(testing.allocator);
    }

    pub fn decode(t: *TestCtx, png: []const u8, w: u32, h: u32, out: []u8) bool {
        testDecode(png, w, h, out) catch {
            t.bad = true;
            return false;
        };
        return true;
    }

    pub fn emit(t: *TestCtx, rgba: []const u8, w: u32, h: u32, delay_ms: u32) bool {
        std.debug.assert(w == 4 and h == 4);
        const copy = testing.allocator.dupe(u8, rgba) catch return false;
        t.frames.append(testing.allocator, copy) catch {
            testing.allocator.free(copy);
            return false;
        };
        t.delays.append(testing.allocator, delay_ms) catch return false;
        return true;
    }

    fn px(t: *const TestCtx, frame: usize, x: usize, y: usize) [4]u8 {
        return t.frames.items[frame][(y * 4 + x) * 4 ..][0..4].*;
    }
};

test "apng: detecta acTL antes do IDAT" {
    const gpa = testing.allocator;
    const a = try buildApng(gpa, &.{.{ .w = 4, .h = 4, .x = 0, .y = 0, .dispose = 0, .blend = 0, .color = .{ 1, 2, 3, 255 } }}, true);
    defer gpa.free(a);
    try testing.expect(isAnimated(a));
    // PNG comum: sem acTL.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try plain.appendSlice(gpa, signature);
    try writeChunk(gpa, &plain, "IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 });
    try writeChunk(gpa, &plain, "IDAT", "x");
    try writeChunk(gpa, &plain, "IEND", "");
    try testing.expect(!isAnimated(plain.items));
    try testing.expect(!isAnimated("GIF89a"));
    try testing.expect(!isAnimated(a[0..20]));
}

test "apng: cada quadro vira um PNG válido e compõe com descarte e mistura" {
    const gpa = testing.allocator;
    const red = [4]u8{ 255, 0, 0, 255 };
    const blue = [4]u8{ 0, 0, 255, 255 };
    const half_green = [4]u8{ 0, 255, 0, 128 };
    const a = try buildApng(gpa, &.{
        // Fundo vermelho inteiro.
        .{ .w = 4, .h = 4, .x = 0, .y = 0, .dispose = 0, .blend = 0, .color = red, .delay = .{ 1, 0 } },
        // Azul 2×2 em (1,1), depois volta ao anterior.
        .{ .w = 2, .h = 2, .x = 1, .y = 1, .dispose = 2, .blend = 0, .color = blue, .delay = .{ 50, 1000 } },
        // Verde meio transparente por cima em (2,0) 2×1, depois limpa.
        .{ .w = 2, .h = 1, .x = 2, .y = 0, .dispose = 1, .blend = 1, .color = half_green },
        // Só um pixel, para ver o que sobrou.
        .{ .w = 1, .h = 1, .x = 3, .y = 3, .dispose = 0, .blend = 1, .color = blue },
    }, true);
    defer gpa.free(a);

    var ctx: TestCtx = .{};
    defer ctx.deinit();
    const n = try play(gpa, a, 4096, &ctx);
    try testing.expect(!ctx.bad);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u32, &.{ 10, 50, 100, 100 }, ctx.delays.items);
    try testing.expectEqual(red, ctx.px(0, 2, 2));
    try testing.expectEqual(blue, ctx.px(1, 1, 1));
    try testing.expectEqual(blue, ctx.px(1, 2, 2));
    try testing.expectEqual(red, ctx.px(1, 0, 0));
    // Voltou ao anterior: o azul sumiu; verde por cima do vermelho.
    try testing.expectEqual(red, ctx.px(2, 1, 1));
    const mixed = ctx.px(2, 2, 0);
    try testing.expectEqual(@as(u8, 255), mixed[3]);
    try testing.expect(mixed[0] > 120 and mixed[0] < 135 and mixed[1] > 120 and mixed[1] < 135);
    try testing.expectEqual(red, ctx.px(2, 1, 0));
    // O verde foi limpo (transparente) e o pixel azul entrou por cima.
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, ctx.px(3, 2, 0));
    try testing.expectEqual(blue, ctx.px(3, 3, 3));
    try testing.expectEqual(red, ctx.px(3, 0, 3));
}

test "apng: imagem padrão fora da animação é pulada" {
    const gpa = testing.allocator;
    const green = [4]u8{ 0, 200, 0, 255 };
    const a = try buildApng(gpa, &.{
        .{ .w = 4, .h = 4, .x = 0, .y = 0, .dispose = 2, .blend = 1, .color = green },
        .{ .w = 4, .h = 4, .x = 0, .y = 0, .dispose = 0, .blend = 0, .color = .{ 0, 0, 0, 0 } },
    }, false);
    defer gpa.free(a);
    var ctx: TestCtx = .{};
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 2), try play(gpa, a, 4096, &ctx));
    try testing.expectEqual(green, ctx.px(0, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, ctx.px(1, 0, 0));
    // Limite de tamanho.
    try testing.expectError(error.TooBig, play(gpa, a, 2, &ctx));
}

test "apng: quadro fora da tela é inválido" {
    const gpa = testing.allocator;
    const a = try buildApng(gpa, &.{.{ .w = 3, .h = 3, .x = 2, .y = 0, .dispose = 0, .blend = 0, .color = .{ 1, 1, 1, 255 } }}, true);
    defer gpa.free(a);
    var ctx: TestCtx = .{};
    defer ctx.deinit();
    try testing.expectError(error.Invalid, play(gpa, a, 4096, &ctx));
}
