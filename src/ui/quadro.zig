//! Resumo do que um quadro do ImGui vai desenhar (ver core/ritmo.zig).
const std = @import("std");
const c = @import("c");

fn add(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

fn addItems(seed: u64, ptr: anytype, n: c_int) u64 {
    if (n <= 0) return seed;
    return add(seed, std.mem.sliceAsBytes(ptr[0..@intCast(n)]));
}

/// Dois quadros com o mesmo resumo saem iguais na tela, desde que nenhuma textura
/// tenha trocado de conteúdo sem trocar de ID (o vídeo avisa: `video.takeChanged`).
pub fn sum(dd: *const c.ImDrawData, clear: [4]f32) u64 {
    var h = add(0, std.mem.asBytes(&clear));
    h = add(h, std.mem.asBytes(&dd.DisplayPos));
    h = add(h, std.mem.asBytes(&dd.DisplaySize));
    h = add(h, std.mem.asBytes(&dd.FramebufferScale));
    for (0..@intCast(dd.CmdLists.Size)) |i| {
        const cl = dd.CmdLists.Data[i];
        h = addItems(h, cl.*.VtxBuffer.Data, cl.*.VtxBuffer.Size);
        h = addItems(h, cl.*.IdxBuffer.Data, cl.*.IdxBuffer.Size);
        h = addItems(h, cl.*.CmdBuffer.Data, cl.*.CmdBuffer.Size);
    }
    return h;
}

/// O backend só atualiza as texturas ao desenhar: letra nova no atlas não pode esperar.
pub fn texturesDirty(dd: *const c.ImDrawData) bool {
    const list = dd.Textures orelse return false;
    for (0..@intCast(list.*.Size)) |i| {
        if (list.*.Data[i].*.Status != c.ImTextureStatus_OK) return true;
    }
    return false;
}
