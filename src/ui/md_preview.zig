//! Prévia do markdown acima da caixa de texto: enquanto se digita algo com
//! formatação (**negrito**, `código`, ||spoiler||, ~~riscado~~…), mostra
//! como a mensagem vai ficar, com o mesmo layout das mensagens (rich.zig).
//! O texto só é interpretado de novo quando muda. Liga/desliga em
//! Configurações → Chat.
const std = @import("std");
const c = @import("c");
const md = @import("../core/markdown.zig");
const d = @import("draw.zig");
const rich = @import("rich.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const State = @import("state.zig").State;

/// Cópia do texto interpretado (os trechos apontam para cá, não para a
/// caixa, que o ImGui reescreve a cada tecla).
var text: [@typeInfo(@FieldType(State, "input")).array.len]u8 = undefined;
var text_len: usize = 0;
var spans: []md.Span = &.{};
var styled = false;
/// Espaço ocupado da última vez que foi desenhada: a lista de mensagens
/// encolhe por ele, como faz com a bandeja de arquivos.
var space: f32 = 0;

const max_lines = 8;

fn sync(st: *const State) void {
    const cur = std.mem.sliceTo(&st.input, 0);
    if (cur.len == text_len and std.mem.eql(u8, cur, text[0..text_len])) return;
    @memcpy(text[0..cur.len], cur);
    text_len = cur.len;
    if (spans.len > 0) std.heap.c_allocator.free(spans);
    spans = md.parse(std.heap.c_allocator, text[0..text_len]) catch &.{};
    // Link sozinho não conta: aparece igual ao que se digitou.
    styled = for (spans) |sp| {
        var f = sp.flags;
        f.link = false;
        if (@as(u8, @bitCast(f)) != 0 or sp.mention != .none) break true;
    } else false;
}

/// A prévia aparece neste quadro?
pub fn visible(st: *const State) bool {
    if (!st.settings.md_preview or st.friends) return false;
    sync(st);
    return styled;
}

/// Altura que a lista de mensagens cede para a prévia (0 = sem prévia).
pub fn height(st: *const State) f32 {
    return if (visible(st)) space else 0;
}

/// Desenha a prévia com a base em `bottom` (acima da caixa, da barra de
/// resposta e da bandeja). `gap` é o espaço livre que fica embaixo dela.
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, x: f32, bottom: f32, w: f32, gap: f32) void {
    if (!visible(ctx.st)) {
        space = 0;
        return;
    }
    const size = ctx.th.font_size;
    const o: rich.Opts = .{
        .family = fam,
        .size = size,
        .line_h = @round(size * 1.375 * d.text_scale),
        .color = ctx.col(.text).mix(ctx.col(.muted), 0.12),
        .reveal_spoilers = ctx.st.settings.show_spoilers,
        .underline_links = ctx.st.settings.underline_links,
    };
    const pad: f32 = 12;
    const head: f32 = 20;
    const wrap = @max(40, w - pad * 2);
    const m = rich.layout(null, ctx.store, ctx.th, spans, 0, 0, wrap, o, ctx.mouse);
    const text_h = @min(m.h, o.line_h * max_lines);
    const h = head + text_h + pad;
    space = h + gap;
    const r: d.Rect = .{ .x = x, .y = bottom - h, .w = w, .h = h };
    qa.mark(r, "md-preview", .{});
    const radius = @max(ctx.th.radius + 4, 4);
    d.shadow(dl, r, radius, 8, ctx.col(.shadow).alpha(0.5));
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.surface), 0.35), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
    d.rect(dl, .{ .x = r.x, .y = r.y + 8, .w = 3, .h = r.h - 16 }, ctx.col(.accent).alpha(0.7), 2);
    var buf: [32]u8 = undefined;
    d.text(dl, fam.get(.bold), 10.5, r.x + pad, r.y + 6, ctx.col(.faint), d.upper(&buf, i18n.tr("Prévia", "Preview")));
    c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y + head - 2), d.v(r.right(), r.y + head + text_h), true);
    _ = rich.layout(dl, ctx.store, ctx.th, spans, r.x + pad, r.y + head, wrap, o, ctx.mouse);
    c.ImDrawList_PopClipRect(dl);
}
