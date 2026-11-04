//! Ordenação estável sem cópia por tipo. `std.mem.sort` gera dezenas de KB para
//! cada par (tipo, comparação), e o programa tinha mais de 40 cópias (450 KB,
//! 9% do código), nenhuma delas em caminho quente. Aqui só o comparador é
//! gerado por tipo: o resto é uma função só, que move bytes.
const std = @import("std");

/// Mesma assinatura e mesma garantia (estável) de `std.mem.sort`.
pub fn stable(comptime T: type, items: []T, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
    const Ctx = @TypeOf(context);
    const W = struct {
        fn less(ctx: *const anyopaque, a: *const anyopaque, b: *const anyopaque) bool {
            const cp: *const Ctx = @ptrCast(@alignCast(ctx));
            const pa: *align(1) const T = @ptrCast(a);
            const pb: *align(1) const T = @ptrCast(b);
            return lessThan(cp.*, pa.*, pb.*);
        }
    };
    var held = context;
    if (@sizeOf(T) == 0) return;
    erased(@ptrCast(items.ptr), items.len, @sizeOf(T), @ptrCast(&held), W.less);
}

const Less = *const fn (*const anyopaque, *const anyopaque, *const anyopaque) bool;
const stack_bytes = 2048;
const first_run = 6;

noinline fn erased(base: [*]u8, n: usize, size: usize, ctx: *const anyopaque, less: Less) void {
    if (n < 2) return;
    var stack: [stack_bytes]u8 align(16) = undefined;
    var heap: []u8 = &.{};
    defer if (heap.len > 0) std.heap.c_allocator.free(heap);
    const need = (n + 1) * size;
    const tmp: [*]u8 = if (need <= stack.len) &stack else blk: {
        heap = std.heap.c_allocator.alloc(u8, need) catch return swapInsertion(base, n, size, ctx, less);
        break :blk heap.ptr;
    };
    // Pedaços pequenos por inserção (a última posição de `tmp` guarda o da vez).
    const pivot = tmp + n * size;
    var lo: usize = 0;
    while (lo < n) : (lo += first_run) insertion(base, lo, @min(lo + first_run, n), size, ctx, less, pivot);
    // Depois junta de dois em dois, alternando entre `base` e `tmp`.
    var src = base;
    var dst = tmp;
    var width: usize = first_run;
    while (width < n) : (width *= 2) {
        var start: usize = 0;
        while (start < n) : (start += 2 * width) {
            const mid = @min(start + width, n);
            merge(src, dst, start, mid, @min(start + 2 * width, n), size, ctx, less);
        }
        std.mem.swap([*]u8, &src, &dst);
    }
    if (src != base) @memcpy(base[0 .. n * size], src[0 .. n * size]);
}

fn insertion(base: [*]u8, lo: usize, hi: usize, size: usize, ctx: *const anyopaque, less: Less, pivot: [*]u8) void {
    var i = lo + 1;
    while (i < hi) : (i += 1) {
        if (!less(ctx, base + i * size, base + (i - 1) * size)) continue;
        @memcpy(pivot[0..size], (base + i * size)[0..size]);
        var j = i;
        while (j > lo and less(ctx, pivot, base + (j - 1) * size)) : (j -= 1) {}
        std.mem.copyBackwards(u8, (base + (j + 1) * size)[0 .. (i - j) * size], (base + j * size)[0 .. (i - j) * size]);
        @memcpy((base + j * size)[0..size], pivot[0..size]);
    }
}

fn merge(src: [*]u8, dst: [*]u8, start: usize, mid: usize, end: usize, size: usize, ctx: *const anyopaque, less: Less) void {
    // Os dois lados já estão em ordem: só copia.
    if (mid >= end or !less(ctx, src + mid * size, src + (mid - 1) * size)) {
        @memcpy((dst + start * size)[0 .. (end - start) * size], (src + start * size)[0 .. (end - start) * size]);
        return;
    }
    var a = start;
    var b = mid;
    var out = start;
    while (a < mid and b < end) : (out += 1) {
        // Empate fica com a esquerda: é o que mantém a ordem estável.
        const from = if (less(ctx, src + b * size, src + a * size)) blk: {
            b += 1;
            break :blk b - 1;
        } else blk: {
            a += 1;
            break :blk a - 1;
        };
        @memcpy((dst + out * size)[0..size], (src + from * size)[0..size]);
    }
    if (a < mid) @memcpy((dst + out * size)[0 .. (mid - a) * size], (src + a * size)[0 .. (mid - a) * size]);
    if (b < end) @memcpy((dst + out * size)[0 .. (end - b) * size], (src + b * size)[0 .. (end - b) * size]);
}

/// Sem memória para o buffer: lento, mas ainda em ordem e estável.
fn swapInsertion(base: [*]u8, n: usize, size: usize, ctx: *const anyopaque, less: Less) void {
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and less(ctx, base + j * size, base + (j - 1) * size)) : (j -= 1) {
            const a = (base + j * size)[0..size];
            const b = (base + (j - 1) * size)[0..size];
            for (a, b) |*x, *y| std.mem.swap(u8, x, y);
        }
    }
}

const Par = struct { chave: u16, ordem: u32 };

fn porChave(_: void, a: Par, b: Par) bool {
    return a.chave < b.chave;
}

fn confere(n: usize, faixa: u16, semente: u64) !void {
    const gpa = std.testing.allocator;
    const v = try gpa.alloc(Par, n);
    defer gpa.free(v);
    const w = try gpa.alloc(Par, n);
    defer gpa.free(w);
    var prng = std.Random.DefaultPrng.init(semente);
    for (v, w, 0..) |*x, *y, i| {
        x.* = .{ .chave = prng.random().uintLessThan(u16, faixa), .ordem = @intCast(i) };
        y.* = x.*;
    }
    stable(Par, v, {}, porChave);
    std.mem.sort(Par, w, {}, porChave);
    try std.testing.expectEqualSlices(Par, w, v);
}

test "dá o mesmo resultado de std.mem.sort, com empates em ordem" {
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 7, 12, 13, 50, 100, 257, 1000, 5000 }) |n| {
        try confere(n, 4, n);
        try confere(n, 60000, n + 1);
    }
}

test "contexto e elemento grande" {
    const Grande = struct { k: u32, resto: [40]u8 = @splat(7) };
    const Ctx = struct {
        inv: bool,
        fn lt(ctx: @This(), a: Grande, b: Grande) bool {
            return if (ctx.inv) a.k > b.k else a.k < b.k;
        }
    };
    var v: [300]Grande = undefined;
    for (&v, 0..) |*x, i| x.* = .{ .k = @intCast((i * 37) % 300) };
    stable(Grande, &v, Ctx{ .inv = true }, Ctx.lt);
    for (v, 0..) |x, i| try std.testing.expectEqual(@as(u32, @intCast(299 - i)), x.k);
}
