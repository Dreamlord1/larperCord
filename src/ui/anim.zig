//! Animações por id: cada valor se aproxima do alvo com easing exponencial.
//! `active` indica se algo ainda está se movendo, para o loop continuar
//! desenhando; quando tudo para, o app volta a dormir esperando eventos.
const std = @import("std");

var values: std.AutoHashMapUnmanaged(u32, f32) = .empty;

pub var dt: f32 = 1.0 / 60.0;
pub var active: bool = false;
/// "Reduzir movimento": tudo chega no alvo na hora.
pub var instant: bool = false;

pub fn id(comptime tag: []const u8, n: usize) u32 {
    return @truncate(std.hash.Wyhash.hash(n, tag));
}

/// Aproxima o valor `key` de `target`. `speed` maior = mais rápido.
pub fn to(key: u32, target: f32, speed: f32) f32 {
    const gop = values.getOrPut(std.heap.c_allocator, key) catch return target;
    if (!gop.found_existing) {
        gop.value_ptr.* = target;
        return target;
    }
    gop.value_ptr.* = step(gop.value_ptr.*, target, speed);
    return gop.value_ptr.*;
}

/// Mesmo easing de `to`, para valores guardados fora do mapa.
pub fn step(value: f32, target: f32, speed: f32) f32 {
    if (instant) return target;
    const k = 1.0 - @exp(-speed * dt);
    const v = value + (target - value) * k;
    if (@abs(target - v) < 0.01) return target;
    active = true;
    return v;
}

pub fn lerp(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}
