//! Lista (ou painelzinho) que flutua sobre a tela sem empurrar nada: abre colada
//! na caixa que a chamou, vira para cima se não couber embaixo, limita a altura e
//! rola por dentro. Clicar fora ou Esc fecha, sem clicar no que está embaixo.
//!
//! Pode ser chamada de dentro de uma região com rolagem (a página de
//! configurações, um popup): é uma janela do ImGui por cima de tudo, que cobre a
//! tela inteira só para pegar o clique de fora.
//!
//!     if (hb.clicked) dropdown.toggle(chave);
//!     if (dropdown.begin(ctx, chave, caixa, largura, altura_do_conteudo)) |*dd| {
//!         defer dd.end();
//!         ...
//!     }
//!
//! Só uma aberta por vez. Quem não chama `begin` num quadro (trocou de página,
//! fechou o popup) a fecha sem precisar avisar.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const janela = @import("../core/janela.zig");

var open_key: usize = 0;
/// Acabou de abrir: ainda não passou por `begin`.
var fresh = false;
var seen_frame: c_int = -10;
var esc_frame: c_int = -10;
var open_ms: i64 = 0;

const max_h: f32 = 340;
const pad: f32 = 4;

pub fn toggle(key: usize) void {
    if (isOpen(key)) return close();
    open_key = key;
    fresh = true;
}

pub fn close() void {
    open_key = 0;
    fresh = false;
}

pub fn isOpen(key: usize) bool {
    expire();
    return open_key == key;
}

pub fn anyOpen() bool {
    expire();
    return open_key != 0;
}

fn expire() void {
    if (open_key != 0 and !fresh and seen_frame < c.ImGui_GetFrameCount() - 1) close();
}

/// Este Esc é da lista: quem também escuta Esc (a página, o popup) deixa passar.
/// Vale do quadro antes até o quadro em que ela fechou.
pub fn ownsEsc() bool {
    return anyOpen() or esc_frame == c.ImGui_GetFrameCount();
}

pub const Row = struct { rect: d.Rect, hit: d.Hit };

pub const Panel = struct {
    ctx: *d.Ctx,
    /// Onde desenhar o conteúdo (já com a rolagem).
    dl: *c.ImDrawList,
    x: f32,
    y: f32,
    w: f32,
    root: *c.ImDrawList,
    rect: d.Rect,
    up: bool,
    root_start: c_int,
    next_id: usize = 0,

    /// Próxima linha, com o fundo de selecionada ou sob o mouse já desenhado.
    pub fn row(p: *Panel, h: f32, selected: bool) Row {
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = h };
        p.next_id += 1;
        const hb = d.hit(p.ctx, 0xDD000 + p.next_id, r);
        const radius = @max(p.ctx.th.radius - 2, 2);
        if (selected) d.rect(p.dl, r, p.ctx.col(.selected), radius) else if (hb.hovered) d.rect(p.dl, r, p.ctx.col(.hover), radius);
        p.y += h;
        return .{ .rect = r, .hit = hb };
    }

    pub fn end(p: *Panel) void {
        // -1: o fim do conteúdo ocupa 1 px, e 1 px a mais já faria aparecer a barra.
        d.endRegion(p.ctx, p.y + pad - 1, p.x);
        // Entrada rápida, deslizando a partir da caixa.
        if (!anim.instant) {
            const k = d.easeOut(@as(f32, @floatFromInt(p.ctx.now_ms - open_ms)) / 110);
            if (k < 1) {
                anim.active = true;
                const origin = d.v(p.rect.x + p.rect.w / 2, if (p.up) p.rect.bottom() else p.rect.y);
                const dy = (if (p.up) @as(f32, 6) else -6) * (1 - k);
                d.transformVerts(p.root, p.root_start, origin, 1, dy, k);
                d.transformVerts(p.dl, 0, origin, 1, dy, k);
            }
        }
        c.ImGui_End();
    }
};

pub fn begin(ctx: *d.Ctx, key: usize, anchor: d.Rect, w: f32, content_h: f32) ?Panel {
    return beginAt(ctx, key, anchor, w, content_h, 0);
}

/// `scroll_to`: altura dentro do conteúdo a mostrar ao abrir (o item escolhido).
pub fn beginAt(ctx: *d.Ctx, key: usize, anchor: d.Rect, w: f32, content_h: f32, scroll_to: f32) ?Panel {
    if (!isOpen(key)) return null;
    const frame = c.ImGui_GetFrameCount();
    const appearing = fresh;
    if (appearing) open_ms = ctx.now_ms;
    fresh = false;
    seen_frame = frame;

    const want = @min(content_h + pad * 2, @min(max_h, ctx.win.h * 0.7));
    const r = janela.place(anchor, w, want, ctx.win);
    qa.mark(r, "dropdown", .{});

    c.ImGui_SetNextWindowPos(d.v(ctx.win.x, ctx.win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(ctx.win.w, ctx.win.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##dropdown", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    const root = c.ImGui_GetWindowDrawList();
    const root_start = root.*.VtxBuffer.Size;

    // O clique que abriu não fecha: ele foi no quadro anterior ao aparecer.
    const clicked = c.ImGui_IsMouseClicked(0) or c.ImGui_IsMouseClicked(1) or c.ImGui_IsMouseClicked(2);
    if (!appearing and clicked and !r.contains(ctx.mouse.x, ctx.mouse.y)) close();
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        esc_frame = frame;
        close();
    }

    const bg = ctx.col(.elevated);
    d.shadow(root, r, ctx.th.radius, 14, ctx.col(.shadow));
    d.rect(root, r, .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = @max(bg.a, 0.98) }, ctx.th.radius);
    d.border(root, r, ctx.col(.border), ctx.th.radius, 1);

    const dl = d.beginRegion(ctx, "##dropdown-list", r, 0);
    // Sem isto reabriria na rolagem da última vez (a janela é a mesma).
    if (appearing) c.ImGui_SetScrollY(@max(scroll_to - r.h / 2, 0));
    const o = c.ImGui_GetCursorScreenPos();
    // A barra de rolagem é fina (6 px) e fica por cima da folga da direita.
    const scrolls = content_h + pad * 2 > r.h;
    return .{
        .ctx = ctx,
        .dl = dl,
        .x = r.x + pad,
        .y = o.y + pad,
        .w = r.w - pad * 2 - (if (scrolls) @as(f32, 6) else 0),
        .root = root,
        .rect = r,
        .up = r.y < anchor.y,
        .root_start = root_start,
    };
}
