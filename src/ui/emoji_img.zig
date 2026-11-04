//! Imagem de um emoji personalizado, a mesma em todo lugar (mensagem, reação,
//! seletor, autocompletar). O cache guarda uma textura por emoji, seja qual
//! for o tamanho em que aparece: o CDN manda 48 px e a GPU reduz.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const media_url = @import("../net/media_url.zig");
const widgets = @import("widgets.zig");
const types = @import("../core/types.zig");

/// Tamanho pedido ao cache (o CDN nunca manda mais que `?size=48`).
const request: f32 = 48;

/// No modo economia (e sem fotos) o emoji é o texto `:nome:`: nada de rede.
pub fn enabled(ctx: *const d.Ctx) bool {
    return !ctx.st.settings.data_saver and !widgets.no_pics;
}

pub fn url(ctx: *const d.Ctx, buf: []u8, id: types.Id, animated: bool) []const u8 {
    if (ctx.store.demo) return std.fmt.bufPrint(buf, "demo:emoji:{d}:{d}", .{ id, @intFromBool(animated) }) catch "";
    return media_url.emojiUrl(buf, id, animated);
}

/// Desenha dentro de `r` (quadrado). Enquanto não chega, um lugar reservado
/// do mesmo tamanho: nada na volta se mexe. `hovered` faz o animado andar
/// quando GIFs não tocam sozinhos.
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, id: types.Id, animated: bool, r: d.Rect, alpha: f32, hovered: bool, always_play: bool) void {
    var ub: [128]u8 = undefined;
    const u = url(ctx, &ub, id, animated);
    const play = animated and (hovered or (always_play and ctx.st.settings.autoplay_gifs));
    switch (ctx.images.getEx(u, request, request, play)) {
        .ready => |t| {
            // O emoji pode não ser quadrado: cabe inteiro, centrado.
            const tw: f32 = @floatFromInt(@max(t.w, 1));
            const th: f32 = @floatFromInt(@max(t.h, 1));
            const k = @min(r.w / tw, r.h / th);
            const w = tw * k;
            const h = th * k;
            const x = r.x + (r.w - w) / 2;
            const y = r.y + (r.h - h) / 2;
            c.ImDrawList_AddImageEx(dl, t.ref, d.v(x, y), d.v(x + w, y + h), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha));
        },
        .loading => d.rect(dl, r.inset(1, 1), ctx.col(.text).alpha(0.08 * alpha), 4),
        .failed => d.border(dl, r.inset(2, 2), ctx.col(.faint).alpha(0.6 * alpha), 4, 1),
    }
}
