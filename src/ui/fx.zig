//! Desenho das primitivas novas dos temas (lidas em `theme/fx.zig`): gradiente,
//! padrão, grão, vinheta, sombra interna, borda por lado ou em gradiente e fundo
//! no hover. As texturas pequenas ficam numa tabela: geradas uma vez, repetidas
//! pela GPU e tingidas pela cor do vértice, então custam um quad por quadro e
//! nenhum cálculo de ruído. Tema que não usa nada não chega a entrar aqui.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const tfx = @import("../theme/fx.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const procgen = @import("procgen.zig");

const Rect = d.Rect;
const Rgba = d.Rgba;

// --- Texturas -------------------------------------------------------------

const Entry = struct {
    key: u64,
    tex: *c.SDL_Texture,
    last: u32,
};

var table: [24]Entry = undefined;
var count: usize = 0;
var frame_no: u32 = 0;

/// Quantas texturas já foram geradas (o QA confere que não é uma por quadro).
pub var generated: u32 = 0;
/// Quantas vezes um fundo em movimento pediu redesenho (o QA confere que um
/// tema parado nunca pede).
pub var motion_wakes: u32 = 0;
/// Texturas vivas agora.
pub var live_entries: usize = 0;
/// Intervalo do último redesenho pedido por um fundo em movimento.
pub var last_period_ms: i64 = 0;
/// Maior `hover-bg` aceso no quadro anterior (para o QA).
pub var hover_seen: f32 = 0;
var hover_now: f32 = 0;

/// Solta o que não foi usado nos últimos quadros (trocou de tema, opção
/// desligada). O quadro anterior já foi para a tela, então é seguro.
pub fn beginFrame() void {
    hover_seen = hover_now;
    hover_now = 0;
    live_entries = count;
    if (count == 0) return;
    frame_no +%= 1;
    var i: usize = 0;
    while (i < count) {
        if (frame_no -% table[i].last > 2) {
            c.SDL_DestroyTexture(table[i].tex);
            count -= 1;
            table[i] = table[count];
        } else i += 1;
    }
}

pub fn refOf(tex: *c.SDL_Texture) c.ImTextureRef {
    return .{ ._TexData = null, ._TexID = @intFromPtr(tex) };
}

fn find(key: u64) ?*c.SDL_Texture {
    for (table[0..count]) |*e| if (e.key == key) {
        e.last = frame_no;
        return e.tex;
    };
    return null;
}

/// Já existe essa textura? (Sem gerar: quem redimensiona espera a janela parar.)
pub fn has(spec: procgen.Spec) ?*c.SDL_Texture {
    return find(spec.key());
}

/// A textura da receita, gerando na primeira vez.
pub fn texture(ctx: *const d.Ctx, spec: procgen.Spec) ?*c.SDL_Texture {
    const key = spec.key();
    if (find(key)) |t| return t;
    const sz = spec.size();
    if (sz[0] == 0 or sz[1] == 0) return null;
    const gpa = std.heap.c_allocator;
    const px = gpa.alloc(u8, sz[0] * sz[1] * 4) catch return null;
    defer gpa.free(px);
    procgen.render(spec, px, gpa) catch return null;
    const tex = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(sz[0]), @intCast(sz[1])) orelse return null;
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_UpdateTexture(tex, null, px.ptr, @intCast(sz[0] * 4));
    generated +%= 1;
    if (count == table.len) {
        // Cheia: sai a usada há mais tempo (nunca a deste quadro, que já está
        // nos comandos de desenho).
        var old: ?usize = null;
        for (table, 0..) |e, i| {
            if (e.last == frame_no) continue;
            if (old == null or e.last < table[old.?].last) old = i;
        }
        const i = old orelse {
            c.SDL_DestroyTexture(tex);
            return null;
        };
        c.SDL_DestroyTexture(table[i].tex);
        table[i] = .{ .key = key, .tex = tex, .last = frame_no };
    } else {
        table[count] = .{ .key = key, .tex = tex, .last = frame_no };
        count += 1;
    }
    return tex;
}

/// O renderizador repete textura de lado qualquer? Se não, só potência de 2.
fn wrapsAnySize(ctx: *const d.Ctx) bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    const props = c.SDL_GetRendererProperties(ctx.images.renderer);
    const ok = c.SDL_GetBooleanProperty(props, c.SDL_PROP_RENDERER_TEXTURE_WRAPPING_BOOLEAN, false);
    S.known = ok;
    return ok;
}

/// Lado do ladrilho para um padrão de `size` pixels.
pub fn tileSide(ctx: *const d.Ctx, size: f32) u16 {
    const s: u16 = @intFromFloat(@round(std.math.clamp(size, 2, 128)));
    return if (wrapsAnySize(ctx)) s else std.math.ceilPowerOfTwoAssert(u16, s);
}

// --- Cor por posição ------------------------------------------------------

/// Paradas prontas de um gradiente. Parada totalmente transparente herda a cor
/// da vizinha: `transparent` no fim não passa por um cinza escuro.
pub const Stops = struct {
    c: [3]Rgba,
    n: u8,
    dx: f32,
    dy: f32,

    pub fn of(ctx: *const d.Ctx, g: tfx.Gradient) Stops {
        const toks = ctx.th.tokenValues();
        var s: Stops = .{ .c = undefined, .n = g.n, .dx = 0, .dy = 0 };
        for (0..3) |i| s.c[i] = g.stops[i].eval(toks);
        const last = g.n - 1;
        if (s.c[0].a < 0.002) s.c[0] = rgbFrom(s.c[1], s.c[0].a);
        if (s.c[last].a < 0.002) s.c[last] = rgbFrom(s.c[last - 1], s.c[last].a);
        if (g.n == 3 and s.c[1].a < 0.002) s.c[1] = rgbFrom(s.c[0], s.c[1].a);
        const rad = std.math.degreesToRadians(g.angle);
        s.dx = @cos(rad);
        s.dy = @sin(rad);
        return s;
    }

    fn at(s: *const Stops, t: f32) Rgba {
        const k = std.math.clamp(t, 0, 1);
        if (s.n == 2) return s.c[0].mix(s.c[1], k);
        return if (k < 0.5) s.c[0].mix(s.c[1], k * 2) else s.c[1].mix(s.c[2], (k - 0.5) * 2);
    }

    /// Pinta os vértices de `start` em diante pela posição dentro de `r`,
    /// mantendo o alfa que eles já tinham (as franjas do antisserrilhado, o
    /// alfa do glifo) multiplicado pelo da parada.
    pub fn shade(s: *const Stops, dl: *c.ImDrawList, start: c_int, r: Rect) void {
        const vb = &dl.*.VtxBuffer;
        if (start >= vb.Size) return;
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        const len = @max(@abs(r.w * s.dx) + @abs(r.h * s.dy), 1);
        for (vb.Data[@intCast(start)..@intCast(vb.Size)]) |*p| {
            const t = 0.5 + ((p.pos.x - cx) * s.dx + (p.pos.y - cy) * s.dy) / len;
            const col = s.at(t);
            const a: f32 = @floatFromInt((p.col >> 24) & 0xff);
            p.col = col.col(a / 255);
        }
    }
};

fn rgbFrom(src: Rgba, a: f32) Rgba {
    return .{ .r = src.r, .g = src.g, .b = src.b, .a = a };
}

fn vtxCount(dl: *c.ImDrawList) c_int {
    return dl.*.VtxBuffer.Size;
}

fn packed8(col: Rgba) u32 {
    return col.u(); // ABGR em memória é RGBA: o mesmo que a textura espera.
}

fn fillGradient(ctx: *const d.Ctx, dl: *c.ImDrawList, g: tfx.Gradient, r: Rect, radius: f32) void {
    const s = Stops.of(ctx, g);
    if (s.n == 2) {
        // Duas paradas: a cor varia linearmente, os vértices já bastam.
        const start = vtxCount(dl);
        c.ImDrawList_AddRectFilledEx(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), 0xffffffff, radius, 0);
        s.shade(dl, start, r);
        return;
    }
    // Três paradas precisam de vértice no meio: uma textura pequena resolve,
    // com canto arredondado e qualquer ângulo. A direção vai em coordenadas da
    // textura, então só uma mudança de proporção refaz (em ângulo reto, nunca).
    const len = @max(@abs(r.w * s.dx) + @abs(r.h * s.dy), 1);
    const ax: i16 = @intFromFloat(@round(r.w * s.dx / len * 64));
    const ay: i16 = @intFromFloat(@round(r.h * s.dy / len * 64));
    const spec: procgen.Spec = .{ .gradient = .{ .c = .{ packed8(s.c[0]), packed8(s.c[1]), packed8(s.c[2]) }, .ax = ax * 16, .ay = ay * 16 } };
    const tex = texture(ctx, spec) orelse return;
    c.ImDrawList_AddImageRounded(dl, refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), 0xffffffff, radius, 0);
}

/// Ladrilho que se repete preso à janela: `u = x / lado` faz cada pixel da tela
/// cair num pixel da textura, sem borrar, mesmo em retângulo de posição quebrada.
fn tiled(dl: *c.ImDrawList, tex: *c.SDL_Texture, r: Rect, side: f32, col: u32, radius: f32) void {
    c.ImDrawList_AddImageRounded(dl, refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(r.x / side, r.y / side), d.v(r.right() / side, r.bottom() / side), col, radius, 0);
}

fn drawPattern(ctx: *const d.Ctx, dl: *c.ImDrawList, p: tfx.Pattern, r: Rect, radius: f32) void {
    const side = tileSide(ctx, p.size);
    const kind: procgen.PatternKind = @enumFromInt(@intFromEnum(p.kind));
    const spec: procgen.Spec = .{ .pattern = .{ .kind = kind, .size = side, .width_q = @intFromFloat(p.width * 8) } };
    const tex = texture(ctx, spec) orelse return;
    tiled(dl, tex, r, @floatFromInt(side), p.color.eval(ctx.th.tokenValues()).u(), radius);
}

/// Grão: 128×128 de ruído gerado uma vez e repetido.
fn drawGrain(ctx: *const d.Ctx, dl: *c.ImDrawList, col: Rgba, r: Rect, radius: f32) void {
    const tex = texture(ctx, .{ .grain = 0x5eed }) orelse return;
    tiled(dl, tex, r, 128, col.u(), radius);
}

fn drawVignette(ctx: *const d.Ctx, dl: *c.ImDrawList, col: Rgba, size: f32, r: Rect, radius: f32) void {
    const tex = texture(ctx, .{ .vignette = @intFromFloat(size * 100) }) orelse return;
    c.ImDrawList_AddImageRounded(dl, refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), col.u(), radius, 0);
}

/// O que vai sobre o fundo e embaixo do conteúdo.
pub fn fill(ctx: *const d.Ctx, dl: *c.ImDrawList, b: *const tfx.Box, r: Rect, radius: f32, key: usize) void {
    if (r.w <= 0 or r.h <= 0) return;
    const toks = ctx.th.tokenValues();
    if (b.gradient) |g| fillGradient(ctx, dl, g, r, radius);
    if (b.hover_bg) |e| {
        const k = anim.to(anim.id("style-hover", key), if (ctx.hovering(r)) 1 else 0, 14);
        hover_now = @max(hover_now, k);
        if (k > 0.01) d.rect(dl, r, e.eval(toks).alpha(k), radius);
    }
    if (b.pattern) |p| drawPattern(ctx, dl, p, r, radius);
    if (b.grain) |e| drawGrain(ctx, dl, e.eval(toks), r, radius);
    if (b.vignette) |e| drawVignette(ctx, dl, e.eval(toks), b.vignette_size, r, radius);
}

/// Contorno do retângulo arredondado com vértices no meio dos lados: é o que
/// deixa uma borda em gradiente de 3 cores certa nas retas longas.
fn outlinePoints(pts: []c.ImVec2, r: Rect, radius: f32) []c.ImVec2 {
    const rad = std.math.clamp(radius, 0, @min(r.w, r.h) / 2);
    const corner = 6;
    const side = 6;
    var n: usize = 0;
    const corners = [4][3]f32{
        .{ r.right() - rad, r.y + rad, -std.math.pi / 2.0 },
        .{ r.right() - rad, r.bottom() - rad, 0 },
        .{ r.x + rad, r.bottom() - rad, std.math.pi / 2.0 },
        .{ r.x + rad, r.y + rad, std.math.pi },
    };
    for (corners, 0..) |cn, i| {
        const steps: usize = if (rad > 0.5) corner else 0;
        for (0..steps + 1) |k| {
            const ang = cn[2] + (std.math.pi / 2.0) * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(steps, 1)));
            pts[n] = d.v(cn[0] + rad * @cos(ang), cn[1] + rad * @sin(ang));
            n += 1;
        }
        // Pontos no meio do lado até o próximo canto.
        const next = corners[(i + 1) % 4];
        const a = pts[n - 1];
        const next_ang = next[2];
        const bx = next[0] + rad * @cos(next_ang);
        const by = next[1] + rad * @sin(next_ang);
        for (1..side) |k| {
            const t = @as(f32, @floatFromInt(k)) / side;
            pts[n] = d.v(a.x + (bx - a.x) * t, a.y + (by - a.y) * t);
            n += 1;
        }
    }
    return pts[0..n];
}

fn innerShadow(dl: *c.ImDrawList, col: Rgba, size: f32, r: Rect, radius: f32) void {
    // Camadas de contorno, do mais forte (na borda) ao que some lá dentro.
    const steps: usize = 6;
    const th = size / @as(f32, @floatFromInt(steps));
    for (0..steps) |i| {
        const k = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const q = (1 - k) * (1 - k);
        const inset = th * @as(f32, @floatFromInt(i));
        d.border(dl, r.inset(inset, inset), col.alpha(q), @max(0, radius - inset), th);
    }
}

/// O acabamento, por cima do fundo: sombra interna e bordas.
pub fn edges(ctx: *const d.Ctx, dl: *c.ImDrawList, b: *const tfx.Box, r: Rect, radius: f32) void {
    const toks = ctx.th.tokenValues();
    if (b.inner_shadow) |e| innerShadow(dl, e.eval(toks), b.inner_shadow_size, r, radius);
    if (b.border) |e| d.border(dl, r, e.eval(toks), radius, b.border_width);
    if (b.border_gradient) |g| {
        var buf: [64]c.ImVec2 = undefined;
        const h = b.border_width / 2;
        const pts = outlinePoints(&buf, r.inset(h, h), @max(0, radius - h));
        const start = vtxCount(dl);
        c.ImDrawList_AddPolyline(dl, pts.ptr, @intCast(pts.len), 0xffffffff, b.border_width, c.ImDrawFlags_Closed);
        Stops.of(ctx, g).shade(dl, start, r);
    }
    const rad = std.math.clamp(radius, 0, @min(r.w, r.h) / 2);
    if (b.sides[0]) |e| d.rect(dl, .{ .x = r.x + rad, .y = r.y, .w = r.w - rad * 2, .h = b.side_widths[0] }, e.eval(toks), 0);
    if (b.sides[1]) |e| d.rect(dl, .{ .x = r.right() - b.side_widths[1], .y = r.y + rad, .w = b.side_widths[1], .h = r.h - rad * 2 }, e.eval(toks), 0);
    if (b.sides[2]) |e| d.rect(dl, .{ .x = r.x + rad, .y = r.bottom() - b.side_widths[2], .w = r.w - rad * 2, .h = b.side_widths[2] }, e.eval(toks), 0);
    if (b.sides[3]) |e| d.rect(dl, .{ .x = r.x, .y = r.y + rad, .w = b.side_widths[3], .h = r.h - rad * 2 }, e.eval(toks), 0);
}

/// Primitivas no próprio nó do layout.
pub fn node(ctx: *d.Ctx, x: *const tfx.NodeFx, n: *const kdl.Node, r: Rect, key: usize) void {
    const radius = d.pnum(n, "radius", 0);
    if (x.bg) |e| d.rect(ctx.dl, r, e.eval(ctx.th.tokenValues()), radius);
    if (x.box) |b| {
        fill(ctx, ctx.dl, b, r, radius, key);
        edges(ctx, ctx.dl, b, r, radius);
    }
}

/// Cor `key` de um componente, ou o token padrão.
pub fn nodeColor(ctx: *const d.Ctx, n: *const kdl.Node, key: []const u8, default: d.Token) Rgba {
    if (ctx.th.nodeFx(n)) |x| if (x.color(key)) |e| return e.eval(ctx.th.tokenValues());
    return ctx.col(default);
}

pub fn nodeColorOpt(ctx: *const d.Ctx, n: *const kdl.Node, key: []const u8) ?Rgba {
    if (ctx.th.nodeFx(n)) |x| if (x.color(key)) |e| return e.eval(ctx.th.tokenValues());
    return null;
}

/// Fundo com movimento pode pedir redesenho? Só a pedido do tema, nunca com
/// "reduzir movimento", e só com a janela em foco (em segundo plano, dorme).
pub fn motionAllowed(ctx: *const d.Ctx, n: *const kdl.Node) bool {
    if (!d.pflag(n, "motion", false) or anim.instant) return false;
    return ctx.io.*.AppFocusLost == false and windowActive(ctx);
}

fn windowActive(ctx: *const d.Ctx) bool {
    const win = c.SDL_GetRenderWindow(ctx.images.renderer) orelse return true;
    const flags = c.SDL_GetWindowFlags(win);
    return flags & (c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_OCCLUDED) == 0;
}

/// Pede o próximo redesenho do fundo: no máximo 15 por segundo, nunca 60.
pub fn wake(n: *const kdl.Node) void {
    const fps = std.math.clamp(d.pnum(n, "motion-fps", 10), 1, 15);
    last_period_ms = @intFromFloat(1000 / fps);
    anim.every(last_period_ms);
    motion_wakes +%= 1;
}
