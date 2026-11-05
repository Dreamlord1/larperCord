//! Cartões de embed (bots, prévias de links, vídeos do YouTube…): barra de
//! cor à esquerda, autor, título, descrição em markdown, campos, imagem,
//! miniatura e rodapé. Mede e desenha com a mesma função (dl = null mede).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const rich = @import("rich.zig");
const att = @import("attachments.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const StoredMessage = @import("../core/store.zig").StoredMessage;
const md = @import("../core/markdown.zig");
const video = @import("video.zig");
const w_ui = @import("widgets.zig");
const links = @import("../core/links.zig");
const links_ui = @import("links.zig");

const max_w: f32 = 520;
const gap: f32 = 6;
const pad: f32 = 12;
const thumb_s: f32 = 80;
/// Num cartão mais estreito que isto (um painel apertado da tela dividida), a
/// miniatura sairia comendo o texto, que viraria uma coluna de uma letra.
const thumb_min_w: f32 = 240;

/// Seleção de texto passando pelos cartões. Para ela a mensagem é um texto
/// só: o conteúdo e depois cada texto dos cartões, um atrás do outro
/// (`eachText` diz a ordem; `off` é onde o próximo começa).
pub const Sel = struct {
    from: u32 = 1,
    to: u32 = 0,
    probe: ?*rich.Probe = null,
    off: u32 = 0,

    /// A parte selecionada de um texto com `len` bytes, relativa a ele.
    fn range(s: *const Sel, len: usize) ?[2]u32 {
        const n: u32 = @intCast(len);
        if (s.from >= s.to or s.to <= s.off or s.from >= s.off + n) return null;
        return .{ s.from -| s.off, @min(s.to - s.off, n) };
    }
};

/// Chama `v.text(texto, trechos, início)` para cada texto dos cartões, na ordem
/// em que `card` os desenha. `trechos` é null onde não há markdown.
fn eachText(m: *const StoredMessage, v: anytype) void {
    var off: u32 = @intCast(m.msg.content.len + 1);
    var k: usize = 0;
    const Walk = struct {
        fn one(visitor: anytype, o: *u32, t: []const u8, spans: ?[]const md.Span) void {
            if (t.len == 0) return;
            visitor.text(t, spans, o.*);
            o.* += @intCast(t.len + 1);
        }
    };
    for (m.msg.embeds) |*e| {
        const span = struct {
            fn at(list: []const []const md.Span, i: usize) ?[]const md.Span {
                return if (i < list.len) list[i] else null;
            }
        }.at;
        Walk.one(v, &off, e.provider, null);
        Walk.one(v, &off, e.author, null);
        Walk.one(v, &off, e.title, null);
        Walk.one(v, &off, e.description, span(m.embed_spans, k));
        k += 1;
        for (e.fields) |f| {
            Walk.one(v, &off, f.name, null);
            Walk.one(v, &off, f.value, span(m.embed_spans, k));
            k += 1;
        }
        for (e.blocks) |*b| {
            if (b.kind == .text) Walk.one(v, &off, b.text, span(m.embed_spans, k));
            k += 1;
        }
        Walk.one(v, &off, e.footer, null);
    }
}

/// Tamanho do texto corrido da mensagem (o conteúdo mais os cartões).
pub fn textLen(m: *const StoredMessage) u32 {
    var v: struct {
        end: u32,
        fn text(s: *@This(), t: []const u8, _: ?[]const md.Span, off: u32) void {
            s.end = off + @as(u32, @intCast(t.len));
        }
    } = .{ .end = @intCast(m.msg.content.len) };
    eachText(m, &v);
    return v.end;
}

/// A palavra em volta de `off`, no texto (conteúdo ou cartão) em que ele cai.
pub fn wordAt(m: *const StoredMessage, off: u32) [2]u32 {
    var v: struct {
        off: u32,
        s: []const u8,
        base: u32 = 0,
        fn text(self: *@This(), t: []const u8, _: ?[]const md.Span, start: u32) void {
            if (self.off >= start and self.off <= start + t.len) {
                self.s = t;
                self.base = start;
            }
        }
    } = .{ .off = off, .s = m.msg.content };
    eachText(m, &v);
    var a: usize = @min(off -| v.base, v.s.len);
    var b: usize = a;
    while (a > 0 and v.s[a - 1] != ' ' and v.s[a - 1] != '\n') a -= 1;
    while (b < v.s.len and v.s[b] != ' ' and v.s[b] != '\n') b += 1;
    return .{ v.base + @as(u32, @intCast(a)), v.base + @as(u32, @intCast(b)) };
}

/// Junta em `out` o que está entre `from` e `to`. Dos cartões vem o texto como
/// aparece na tela (sem as marcas do markdown nem o endereço dos links).
pub fn appendText(ctx: *d.Ctx, out: *std.ArrayList(u8), m: *const StoredMessage, from: u32, to: u32) void {
    const gpa = ctx.st.gpa;
    const s = m.msg.content;
    const a = @min(from, s.len);
    const b = @min(to, s.len);
    if (b > a) out.appendSlice(gpa, s[a..b]) catch {};
    var v: struct {
        ctx: *d.Ctx,
        out: *std.ArrayList(u8),
        from: u32,
        to: u32,
        any: bool,
        fn text(self: *@This(), t: []const u8, spans: ?[]const md.Span, off: u32) void {
            const sel: Sel = .{ .from = self.from, .to = self.to, .off = off };
            const r = sel.range(t.len) orelse return;
            const g = self.ctx.st.gpa;
            if (self.any) self.out.append(g, '\n') catch {};
            self.any = true;
            const list = spans orelse {
                self.out.appendSlice(g, t[r[0]..r[1]]) catch {};
                return;
            };
            var buf: [96]u8 = undefined;
            for (list) |*sp| {
                const p0: u32 = @intCast(@intFromPtr(sp.text.ptr) - @intFromPtr(t.ptr));
                const p1 = p0 + @as(u32, @intCast(sp.text.len));
                if (p1 <= r[0] or p0 >= r[1]) continue;
                if (sp.mention != .none or sp.emoji != 0 or sp.flags.bullet) {
                    self.out.appendSlice(g, rich.label(self.ctx.store, sp, &buf)) catch {};
                    if (sp.flags.bullet) self.out.append(g, ' ') catch {};
                } else self.out.appendSlice(g, t[@max(p0, r[0])..@min(p1, r[1])]) catch {};
                if (sp.flags.block) self.out.append(g, '\n') catch {};
            }
        }
    } = .{ .ctx = ctx, .out = out, .from = from, .to = to, .any = b > a };
    eachText(m, &v);
}

/// Altura de todos os embeds da mensagem (com o espaço acima), desenhando
/// se `dl` não for null.
pub fn block(ctx: *d.Ctx, dl: ?*c.ImDrawList, m: *const StoredMessage, x: f32, y_in: f32, avail: f32, alpha: f32, sel_in: Sel) f32 {
    const invites = hasInvite(m);
    if (m.msg.embeds.len == 0 and !invites) return 0;
    var y = y_in;
    var k: usize = 0;
    var sel = sel_in;
    sel.off = @intCast(m.msg.content.len + 1);
    for (m.msg.embeds, 0..) |*e, i| {
        y += gap;
        const n_spans = 1 + e.fields.len + e.blocks.len;
        const spans = m.embed_spans[@min(m.embed_spans.len, k)..@min(m.embed_spans.len, k + n_spans)];
        k += n_spans;
        const w = @min(avail, max_w);
        const h = cardHeight(ctx, e, spans, w, dl != null);
        if (dl) |l| {
            _ = card(ctx, l, e, spans, x, y, w, alpha, h, m.msg.id, &sel);
            qa.mark(.{ .x = x, .y = y, .w = w, .h = h }, "embed:{d}:{d}", .{ m.msg.id, i });
        }
        y += h;
    }
    if (invites) {
        var shown: usize = 0;
        for (m.spans) |*sp| {
            if (!isInviteSpan(sp)) continue;
            if (shown == max_invites) break;
            shown += 1;
            y += gap;
            if (dl) |l| inviteCard(ctx, l, sp.target(), x, y, @min(avail, invite_w), alpha, m.msg.id ^ shown);
            y += invite_h;
        }
    }
    return y - y_in;
}

// --- Cartão de convite ----------------------------------------------------------
// Mostra o servidor e abre no navegador. Não entra pelo app: POST de convite
// por conta de usuário dispara captcha e arrisca a conta.

pub const invite_w: f32 = 432;
/// A faixa do topo (banner do servidor) e a parte de baixo. A altura não muda
/// quando o convite chega, para a conversa não pular.
const invite_strip: f32 = 56;
const invite_h: f32 = 84 + invite_strip;
const max_invites = 3;

fn isInviteSpan(sp: *const md.Span) bool {
    return sp.flags.link and !sp.flags.spoiler and links.parseInvite(sp.target()) != null;
}

pub fn hasInvite(m: *const StoredMessage) bool {
    for (m.spans) |*sp| if (sp.flags.link and isInviteSpan(sp)) return true;
    return false;
}

/// Imagem cobrindo o retângulo sem distorcer (corta o que sobra).
pub fn imageCover(dl: *c.ImDrawList, t: anytype, r: d.Rect, alpha: f32, radius: f32, flags: c_int) void {
    const tw: f32 = @floatFromInt(@max(t.w, 1));
    const th: f32 = @floatFromInt(@max(t.h, 1));
    const k = @max(r.w / tw, r.h / th);
    const u = r.w / (tw * k);
    const uv = r.h / (th * k);
    c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0.5 - u / 2, 0.5 - uv / 2), d.v(0.5 + u / 2, 0.5 + uv / 2), d.Rgba.white.col(alpha), radius, flags);
}

fn inviteCard(ctx: *d.Ctx, dl: *c.ImDrawList, url: []const u8, x: f32, y_top: f32, wd: f32, alpha: f32, hit_id: u64) void {
    const fam = ctx.ui;
    const code = links.parseInvite(url) orelse return;
    const inv = ctx.store.invites.get(code);
    if (inv == null) ctx.act(.{ .want_invite = links.InviteCode.init(code) });
    const r: d.Rect = .{ .x = x, .y = y_top, .w = wd, .h = invite_h };
    qa.mark(r, "invite:{s}", .{code});
    d.rect(dl, r, ctx.col(.elevated).mix(ctx.col(.rail), 0.35).alpha(alpha), 6);
    const strip: d.Rect = .{ .x = x, .y = y_top, .w = wd, .h = invite_strip };
    var strip_drawn = false;
    if (inv) |i| if (i.banner) |hash| {
        var ub: [160]u8 = undefined;
        const scale = ctx.io.*.DisplayFramebufferScale.x;
        if (!w_ui.no_pics) switch (ctx.images.getStill(w_ui.bannerUrl(&ub, i.guild, hash, i.splash), strip.w * scale, strip.h * scale)) {
            .ready => |t| {
                imageCover(dl, t, strip, alpha, 6, c.ImDrawFlags_RoundCornersTop);
                strip_drawn = true;
                qa.mark(strip, "invite-banner:{s}", .{code});
            },
            else => {},
        };
    };
    if (!strip_drawn) d.rectFlags(dl, strip, ctx.col(.accent).mix(ctx.col(.elevated), 0.72).alpha(alpha), 6, c.ImDrawFlags_RoundCornersTop);
    d.border(dl, r, ctx.col(.border).alpha(alpha), 6, 1);
    const y = y_top + invite_strip;
    d.text(dl, fam.get(.bold), 10.5, x + 12, y + 8, ctx.col(.muted).alpha(alpha), i18n.tr("CONVITE PARA UM SERVIDOR", "SERVER INVITE"));

    // Ícone: a imagem, ou a primeira letra.
    const ir: d.Rect = .{ .x = x + 12, .y = y + 28, .w = 44, .h = 44 };
    const state = if (inv) |i| i.state else .loading;
    const ok = state == .ok;
    var icon_drawn = false;
    if (ok) if (inv.?.icon) |hash| {
        var ub: [160]u8 = undefined;
        icon_drawn = w_ui.picture(ctx, dl, w_ui.cdnUrl(&ub, .guild, inv.?.guild, hash), ir, 12, alpha);
    };
    if (!icon_drawn) {
        d.rect(dl, ir, ctx.col(.accent).alpha(0.75 * alpha), 12);
        const g = if (ok and inv.?.name.len > 0) d.firstGlyph(inv.?.name) else "?";
        const gw = d.width(fam.get(.bold), 18, g);
        d.text(dl, fam.get(.bold), 18, ir.x + (ir.w - gw) / 2, d.centerY(ir, 18), d.Rgba.white.alpha(alpha), g);
    }

    // Botões à direita: abrir no navegador e, se já estamos nele, ir para lá.
    const browser = i18n.tr("Abrir no navegador", "Open in browser");
    const bf = fam.get(.semibold);
    const bh: f32 = 28;
    const narrow = wd < 360;
    const bw = d.width(bf, 13, browser) + 20;
    const member = ok and inv.?.guild != 0 and ctx.store.guild(inv.?.guild) != null;
    const go = i18n.tr("Ir para o servidor", "Go to server");
    var rx = r.right() - 10;
    const br: d.Rect = .{ .x = rx - bw, .y = if (narrow or member) y + 8 else y + 42, .w = bw, .h = bh };
    rx = br.x;
    const hb = d.hit(ctx, @truncate(hit_id *% 31 +% 1), br);
    qa.mark(br, "invite-open:{s}", .{code});
    d.rect(dl, br, (if (hb.hovered) ctx.col(.accent) else ctx.col(.hover)).alpha(alpha), bh / 2);
    d.text(dl, bf, 13, br.x + 10, d.centerY(br, 13), (if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text)).alpha(alpha), browser);
    if (hb.clicked) att.openUrl(url);
    if (member) {
        const gr: d.Rect = .{ .x = r.right() - 10 - bw, .y = y + 44, .w = bw, .h = bh };
        const gh = d.hit(ctx, @truncate(hit_id *% 31 +% 2), gr);
        qa.mark(gr, "invite-go:{s}", .{code});
        d.rect(dl, gr, ctx.col(.accent).alpha(alpha), bh / 2);
        const gt = d.width(bf, 13, go);
        d.text(dl, bf, 13, gr.x + (bw - gt) / 2, d.centerY(gr, 13), ctx.col(.accent_text).alpha(alpha), go);
        if (gh.clicked) ctx.act(.{ .select_guild = inv.?.guild });
    }

    // Nome e membros.
    const tx = ir.right() + 12;
    const room = rx - tx - 8;
    switch (state) {
        .loading => d.text(dl, fam.get(.regular), 13, tx, y + 40, ctx.col(.muted).alpha(alpha), i18n.tr("carregando…", "loading…")),
        .invalid => d.text(dl, fam.get(.semibold), 13.5, tx, y + 40, ctx.col(.danger).alpha(alpha), i18n.tr("Convite inválido ou expirado", "Invalid or expired invite")),
        .failed => d.text(dl, fam.get(.regular), 13, tx, y + 40, ctx.col(.muted).alpha(alpha), i18n.tr("não consegui carregar o convite", "couldn't load the invite")),
        .ok => {
            _ = d.textClipped(dl, fam.get(.bold), 15, tx, y + 30, ctx.col(.text).alpha(alpha), inv.?.name, room);
            var cb: [64]u8 = undefined;
            var cx = tx;
            if (inv.?.online > 0) {
                d.circle(dl, cx + 4, y + 60, 4, ctx.col(.online).alpha(alpha));
                const t = i18n.fmt(&cb, "{d} online", "{d} online", .{inv.?.online});
                d.text(dl, fam.get(.regular), 12.5, cx + 12, y + 52, ctx.col(.muted).alpha(alpha), t);
                cx += 12 + d.width(fam.get(.regular), 12.5, t) + 10;
            }
            if (inv.?.members > 0) {
                d.circle(dl, cx + 4, y + 60, 4, ctx.col(.faint).alpha(alpha));
                const t = i18n.fmt(&cb, "{d} membros", "{d} members", .{inv.?.members});
                _ = d.textClipped(dl, fam.get(.regular), 12.5, cx + 12, y + 52, ctx.col(.muted).alpha(alpha), t, @max(0, rx - cx - 20));
            }
        },
    }
}

/// Altura medida por embed: desenhar não precisa fazer o layout duas vezes
/// por quadro. Quem erra a chave só mede de novo.
const HeightSlot = struct { key: u64 = 0, h: f32 = 0 };
var height_cache: [64]HeightSlot = @splat(.{});

fn cardHeight(ctx: *d.Ctx, e: *const types.Embed, spans: []const []const md.Span, w: f32, use_cache: bool) f32 {
    var none: Sel = .{};
    if (!use_cache) return card(ctx, null, e, spans, 0, 0, w, 1, 0, 0, &none);
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&@intFromPtr(e)));
    hash.update(std.mem.asBytes(&w));
    hash.update(std.mem.asBytes(&d.text_scale));
    hash.update(std.mem.asBytes(&ctx.st.theme_gen));
    const key = hash.final() | 1;
    const slot = &height_cache[key % height_cache.len];
    if (slot.key == key) return slot.h;
    slot.* = .{ .key = key, .h = card(ctx, null, e, spans, 0, 0, w, 1, 0, 0, &none) };
    return slot.h;
}

fn opts(ctx: *d.Ctx, size: f32) rich.Opts {
    return .{
        .ctx = ctx,
        .family = ctx.ui,
        .size = size,
        .line_h = size * 1.42,
        .color = ctx.col(.text).mix(ctx.col(.muted), 0.15),
        .reveal_spoilers = ctx.st.settings.show_spoilers,
        .underline_links = ctx.st.settings.underline_links,
    };
}

/// Texto de uma linha só (título, autor, rodapé…), selecionável.
fn plainText(ctx: *d.Ctx, dl: ?*c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, line: f32, col: d.Rgba, text: []const u8, max: f32, s: *Sel) void {
    if (text.len == 0) return;
    if (dl) |l| {
        if (s.range(text.len)) |r| {
            const x0 = x + d.width(font, size, text[0..r[0]]);
            const x1 = @min(x + d.width(font, size, text[0..r[1]]), x + max);
            if (x1 > x0) d.rect(l, .{ .x = x0, .y = y, .w = x1 - x0, .h = line }, ctx.col(.accent).alpha(0.32), 0);
        }
        if (s.probe) |p| if (p.y >= y and p.y < y + line and p.x >= x and p.x < x + max) {
            p.out = s.off + rich.offsetAt(font, size, text, p.x - x);
        };
        _ = d.textClipped(l, font, size, x, y, col, text, max);
    }
    s.off += @intCast(text.len + 1);
}

/// Texto com markdown, selecionável. Devolve a altura.
fn richText(ctx: *d.Ctx, dl: ?*c.ImDrawList, spans: []const md.Span, text: []const u8, x: f32, y: f32, wrap: f32, size: f32, s: *Sel) f32 {
    if (text.len == 0) return 0;
    defer s.off += @intCast(text.len + 1);
    if (spans.len == 0) return 0;
    var o = opts(ctx, size);
    var inner: rich.Probe = .{ .x = 0, .y = 0 };
    if (dl != null) {
        o.base = text.ptr;
        if (s.range(text.len)) |r| {
            o.sel_from = r[0];
            o.sel_to = r[1];
        }
        if (s.probe) |p| {
            inner = .{ .x = p.x, .y = p.y };
            o.probe = &inner;
        }
    }
    const t = rich.layout(dl, ctx.store, ctx.th, spans, x, y, wrap, o, ctx.mouse);
    if (inner.out) |v| s.probe.?.out = s.off + v;
    return t.h;
}

/// Cobertura de um spoiler: some com o mouse em cima (como o texto).
fn spoilerCover(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, radius: f32, alpha: f32) void {
    if (ctx.st.settings.show_spoilers or r.contains(ctx.mouse.x, ctx.mouse.y)) return;
    d.rect(dl, r, ctx.col(.code_bg).mix(ctx.col(.text), 0.08).alpha(alpha), radius);
    const f = ctx.ui.get(.bold);
    const t = "SPOILER";
    if (r.h > 24) d.text(dl, f, 12, r.x + (r.w - d.width(f, 12, t)) / 2, d.centerY(r, 12), ctx.col(.text).alpha(alpha), t);
}

/// Miniatura ao lado de um texto; o clique abre em tamanho grande.
fn blockThumb(ctx: *d.Ctx, dl: *c.ImDrawList, it: *const types.EmbedMedia, tr: d.Rect, alpha: f32) void {
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    const hb = d.hit(ctx, @truncate(@intFromPtr(it)), tr);
    qa.mark(tr, "embed-thumb", .{});
    switch (ctx.images.get(it.url, tr.w * scale, tr.h * scale)) {
        .ready => |t| imageCover(dl, t, tr, alpha, 6, 0),
        else => d.rect(dl, tr, ctx.col(.text).alpha(0.05 * alpha), 6),
    }
    if (it.spoiler) spoilerCover(ctx, dl, tr, 6, alpha);
    if (hb.clicked) att.openImage(ctx, it.url, it.label, it.w, it.h);
}

/// Grade de imagens: uma sozinha mantém a proporção; várias ficam em células.
fn gallery(ctx: *d.Ctx, dl: ?*c.ImDrawList, b: *const types.EmbedBlock, x: f32, y: f32, w: f32, alpha: f32, msg_id: types.Id) f32 {
    const n = b.media.len;
    const cell_gap: f32 = 4;
    if (n == 1) {
        const it = &b.media[0];
        const iw: f32 = @floatFromInt(@max(it.w, 1));
        const ih: f32 = @floatFromInt(@max(it.h, 1));
        const k = @min(1.0, @min(w / iw, 300 / ih));
        const r: d.Rect = .{ .x = x, .y = y, .w = if (it.w == 0) w else @max(40, @round(iw * k)), .h = if (it.h == 0) 200 else @max(30, @round(ih * k)) };
        if (dl) |l| mediaCell(ctx, l, it, r, alpha, msg_id);
        return r.h;
    }
    const cols: usize = if (n == 2 or n == 4) 2 else 3;
    const rows = (n + cols - 1) / cols;
    const fc: f32 = @floatFromInt(cols);
    const cw = (w - cell_gap * (fc - 1)) / fc;
    const ch = @round(cw * 0.66);
    if (dl) |l| for (b.media, 0..) |*it, i| {
        const cx: f32 = @floatFromInt(i % cols);
        const cy: f32 = @floatFromInt(i / cols);
        mediaCell(ctx, l, it, .{ .x = x + cx * (cw + cell_gap), .y = y + cy * (ch + cell_gap), .w = cw, .h = ch }, alpha, msg_id);
    };
    const fr: f32 = @floatFromInt(rows);
    return fr * ch + (fr - 1) * cell_gap;
}

fn mediaCell(ctx: *d.Ctx, dl: *c.ImDrawList, it: *const types.EmbedMedia, r: d.Rect, alpha: f32, msg_id: types.Id) void {
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    const vkey = video.keyOf(msg_id, 0x200 + std.hash.Wyhash.hash(0, it.url));
    if (it.video and video.isActive(vkey)) {
        const pv = ctx.images.get(it.url, r.w * scale, r.h * scale);
        video.draw(ctx, dl, r, alpha, msg_id, if (pv == .ready) pv.ready else null);
        return;
    }
    const hb = d.hit(ctx, @truncate(@intFromPtr(it)), r);
    qa.mark(r, "embed-media", .{});
    const play = ctx.st.settings.autoplay_gifs or hb.hovered;
    const look = ctx.images.getEx(it.url, r.w * scale, r.h * scale, play);
    const held_back = look == .failed and ctx.images.blocked(it.url);
    if (held_back) {
        att.savedPlaceholder(ctx, dl, r, it.size, alpha);
    } else switch (look) {
        .ready => |t| imageCover(dl, t, r, alpha, 6, 0),
        .loading => d.rect(dl, r, ctx.col(.text).alpha(0.05 * alpha), 6),
        .failed => d.rect(dl, r, ctx.col(.text).alpha(0.03 * alpha), 6),
    }
    if (it.video) att.playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
    if (hb.hovered) d.rect(dl, r, d.Rgba.white.alpha(0.05), 6);
    if (it.spoiler) spoilerCover(ctx, dl, r, 6, alpha);
    if (hb.clicked) {
        if (held_back) {
            ctx.images.allow(it.url);
        } else if (it.video and it.link.len > 0) {
            video.click(ctx, vkey, it.link, it.link, r, it.size);
        } else att.openImage(ctx, it.url, it.label, it.w, it.h);
    }
}

/// Linha de um arquivo: nome e tamanho; o clique abre no navegador.
fn fileRow(ctx: *d.Ctx, dl: ?*c.ImDrawList, it: *const types.EmbedMedia, x: f32, y: f32, w: f32, alpha: f32) f32 {
    const h: f32 = 44;
    const l = dl orelse return h;
    const r: d.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    const hb = d.hit(ctx, @truncate(@intFromPtr(it)), r);
    qa.mark(r, "embed-file", .{});
    d.rect(l, r, (if (hb.hovered) ctx.col(.hover) else ctx.col(.text).alpha(0.04)).alpha(alpha), 6);
    d.border(l, r, ctx.col(.border).alpha(alpha), 6, 1);
    _ = d.textClipped(l, ctx.ui.get(.semibold), 13.5, x + 12, y + 6, ctx.col(.link).alpha(alpha), it.label, w - 24);
    var sb: [32]u8 = undefined;
    d.text(l, ctx.ui.get(.regular), 12, x + 12, y + 25, ctx.col(.muted).alpha(alpha), att.formatSize(&sb, it.size));
    if (it.spoiler) spoilerCover(ctx, l, r, 6, alpha);
    if (hb.clicked and it.link.len > 0) att.openUrl(it.link);
    return h;
}

/// Botões de link de um bot (os outros pedem uma interação, que não fazemos).
fn buttons(ctx: *d.Ctx, dl: ?*c.ImDrawList, b: *const types.EmbedBlock, x: f32, y: f32, w: f32, alpha: f32) f32 {
    const f = ctx.ui.get(.semibold);
    const bh: f32 = 30;
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (b.media) |*it| {
        const bw = @min(d.width(f, 13, it.label) + 24, w);
        if (cx > 0 and cx + bw > w) {
            cx = 0;
            cy += bh + 6;
        }
        if (dl) |l| {
            const r: d.Rect = .{ .x = x + cx, .y = y + cy, .w = bw, .h = bh };
            const hb = d.hit(ctx, @truncate(@intFromPtr(it)), r);
            qa.mark(r, "embed-button", .{});
            d.rect(l, r, (if (hb.hovered) ctx.col(.hover) else ctx.col(.text).alpha(0.08)).alpha(alpha), 6);
            _ = d.textClipped(l, f, 13, r.x + 12, d.centerY(r, 13), ctx.col(.text).alpha(alpha), it.label, bw - 24);
            d.tip(ctx, r, it.link, hb.hovered);
            if (hb.clicked) links_ui.open(ctx, it.link);
        }
        cx += bw + 6;
    }
    return cy + bh;
}

/// Os blocos de um cartão de componentes. Devolve a altura.
fn blocks(ctx: *d.Ctx, dl: ?*c.ImDrawList, e: *const types.Embed, spans: []const []const md.Span, x: f32, y0: f32, w: f32, alpha: f32, msg_id: types.Id, sel: *Sel) f32 {
    var y = y0;
    const first = 1 + e.fields.len;
    for (e.blocks, 0..) |*b, i| {
        if (i > 0 and b.kind != .separator and e.blocks[i - 1].kind != .separator) y += 8;
        switch (b.kind) {
            .text => {
                const thumb = b.media.len > 0 and w >= thumb_min_w;
                const tw = if (thumb) w - thumb_s - pad else w;
                const sp: []const md.Span = if (first + i < spans.len) spans[first + i] else &.{};
                const th = richText(ctx, dl, sp, b.text, x, y, tw, 14, sel);
                if (thumb) if (dl) |l| blockThumb(ctx, l, &b.media[0], .{ .x = x + w - thumb_s, .y = y, .w = thumb_s, .h = thumb_s }, alpha);
                y += if (thumb) @max(th, thumb_s) else th;
            },
            .separator => {
                const space: f32 = if (b.large) 16 else 8;
                y += space;
                if (b.divider) if (dl) |l| d.line(l, x, y, x + w, y, ctx.col(.border).alpha(alpha), 1);
                y += space;
            },
            .gallery => y += gallery(ctx, dl, b, x, y, w, alpha, msg_id),
            .file => for (b.media) |*it| {
                y += fileRow(ctx, dl, it, x, y, w, alpha);
            },
            .buttons => y += buttons(ctx, dl, b, x, y, w, alpha),
        }
    }
    return y - y0;
}

/// Um cartão. Medindo (dl = null) devolve a altura; desenhando, `h` é a
/// altura medida antes (para o fundo ir por baixo do resto).
fn card(ctx: *d.Ctx, dl: ?*c.ImDrawList, e: *const types.Embed, spans: []const []const md.Span, x: f32, y0: f32, w: f32, alpha: f32, h: f32, msg_id: types.Id, sel: *Sel) f32 {
    const fam = ctx.ui;
    // Componentes soltos: só os blocos, sem fundo.
    if (e.bare) return blocks(ctx, dl, e, spans, x, y0, w, alpha, msg_id, sel);
    if (dl) |l| {
        const r: d.Rect = .{ .x = x, .y = y0, .w = w, .h = h };
        d.rect(l, r, ctx.col(.elevated).mix(ctx.col(.rail), 0.35).alpha(alpha), 6);
        const bar = if (e.has_color and e.color != 0) d.Rgba.hex(e.color) else ctx.col(.border).mix(ctx.col(.text), 0.15);
        d.rectFlags(l, .{ .x = x, .y = y0, .w = 4, .h = h }, bar.alpha(alpha), 6, c.ImDrawFlags_RoundCornersLeft);
    }
    const has_thumb = e.thumb.len > 0 and e.image.len == 0 and w >= thumb_min_w;
    const ix = x + 4 + pad;
    const tw = w - 4 - pad * 2 - (if (has_thumb) thumb_s + pad else 0);
    var y = y0 + 10;

    if (e.provider.len > 0) {
        plainText(ctx, dl, fam.get(.regular), 12, ix, y, 18, ctx.col(.muted).alpha(alpha), e.provider, tw, sel);
        y += 18;
    }
    if (e.author.len > 0) {
        plainText(ctx, dl, fam.get(.semibold), 13.5, ix, y, 20, ctx.col(.text).alpha(alpha), e.author, tw, sel);
        y += 20;
    }
    if (e.title.len > 0) {
        const linked = e.url.len > 0;
        const col = if (linked) ctx.col(.link) else ctx.col(.text);
        plainText(ctx, dl, fam.get(.semibold), 15, ix, y, 22, col.alpha(alpha), e.title, tw, sel);
        if (dl) |l| if (linked) {
            const tr: d.Rect = .{ .x = ix, .y = y, .w = @min(tw, d.width(fam.get(.semibold), 15, e.title)), .h = 20 };
            const over = tr.contains(ctx.mouse.x, ctx.mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
            if (over) {
                d.line(l, tr.x, tr.bottom() - 1, tr.right(), tr.bottom() - 1, col.alpha(0.6), 1);
                c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
                // Soltar sem arrastar: arrastar é selecionar o título.
                // Link do Discord no título de um bot abre aqui.
                const drag = c.ImGui_GetMouseDragDelta(0, -1);
                if (c.ImGui_IsMouseReleased(0) and @abs(drag.x) + @abs(drag.y) < 4) links_ui.open(ctx, e.url);
            }
        };
        y += 24;
    }
    if (e.description.len > 0) {
        const th = richText(ctx, dl, if (spans.len > 0) spans[0] else &.{}, e.description, ix, y, tw, 14, sel);
        if (th > 0) y += th + 4;
    }
    for (e.fields, 0..) |f, si| {
        plainText(ctx, dl, fam.get(.bold), 13, ix, y, 19, ctx.col(.text).alpha(alpha), f.name, tw, sel);
        y += 19;
        const th = richText(ctx, dl, if (si + 1 < spans.len) spans[si + 1] else &.{}, f.value, ix, y, tw, 13.5, sel);
        if (th > 0) y += th + 6;
    }
    if (e.blocks.len > 0) y += blocks(ctx, dl, e, spans, ix, y, w - 4 - pad * 2, alpha, msg_id, sel);
    if (e.image.len > 0) {
        y += 4;
        const iw: f32 = @floatFromInt(e.image_w);
        const ih: f32 = @floatFromInt(e.image_h);
        const s = @min(1.0, @min((w - 4 - pad * 2) / iw, 300 / ih));
        const r: d.Rect = .{ .x = ix, .y = y, .w = @max(40, @round(iw * s)), .h = @max(30, @round(ih * s)) };
        if (dl) |l| image(ctx, l, e, r, alpha, msg_id);
        y += r.h + 4;
    }
    if (e.footer.len > 0) {
        y += 2;
        plainText(ctx, dl, fam.get(.regular), 12, ix, y, 18, ctx.col(.muted).alpha(alpha), e.footer, w - 4 - pad * 2, sel);
        y += 18;
    }
    if (has_thumb) {
        const tr: d.Rect = .{ .x = x + w - pad - thumb_s, .y = y0 + pad, .w = thumb_s, .h = thumb_s };
        if (dl) |l| {
            const scale = ctx.io.*.DisplayFramebufferScale.x;
            switch (ctx.images.get(e.thumb, tr.w * scale, tr.h * scale)) {
                .ready => |t| {
                    // Cabe no quadrado sem distorcer.
                    const k = @min(tr.w / @as(f32, @floatFromInt(t.w)), tr.h / @as(f32, @floatFromInt(t.h)));
                    const dw = @as(f32, @floatFromInt(t.w)) * k;
                    const dh = @as(f32, @floatFromInt(t.h)) * k;
                    c.ImDrawList_AddImageRounded(l, t.ref, d.v(tr.right() - dw, tr.y), d.v(tr.right(), tr.y + dh), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), 4, 0);
                },
                else => d.rect(l, tr, ctx.col(.text).alpha(0.05 * alpha), 4),
            }
        }
        y = @max(y, y0 + pad + thumb_s);
    }
    if (e.spoiler) if (dl) |l| spoilerCover(ctx, l, .{ .x = x, .y = y0, .w = w, .h = h }, 6, alpha);
    return y + 10 - y0;
}

fn image(ctx: *d.Ctx, dl: *c.ImDrawList, e: *const types.Embed, r: d.Rect, alpha: f32, msg_id: types.Id) void {
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    // Vídeo de um link direto (pelo proxy do Discord): toca no lugar da imagem.
    const vkey = video.keyOf(msg_id, 0x100 + std.hash.Wyhash.hash(0, e.video_url));
    if (e.video_url.len > 0 and video.isActive(vkey)) {
        const pv = ctx.images.get(e.image, r.w * scale, r.h * scale);
        video.draw(ctx, dl, r, alpha, msg_id, if (pv == .ready) pv.ready else null);
        return;
    }
    const hb = d.hit(ctx, @truncate(@intFromPtr(e) +% 1), r);
    const look = ctx.images.get(e.image, r.w * scale, r.h * scale);
    // Modo economia: o clique baixa a imagem.
    if (look == .failed and ctx.images.blocked(e.image)) {
        att.savedPlaceholder(ctx, dl, r, 0, alpha);
        if (hb.clicked) ctx.images.allow(e.image);
        return;
    }
    switch (look) {
        .ready => |t| c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), 6, 0),
        .loading => d.rect(dl, r, ctx.col(.text).alpha(0.05 * alpha), 6),
        .failed => d.rect(dl, r, ctx.col(.text).alpha(0.03 * alpha), 6),
    }
    if (e.video and e.video_url.len > 0) {
        att.playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
        d.tip(ctx, r, if (video.canPlay(e.video_url, 0)) i18n.tr("Tocar o vídeo", "Play video") else i18n.tr("Abrir o vídeo no navegador", "Open video in browser"), hb.hovered);
        if (hb.clicked) video.click(ctx, vkey, e.video_url, if (e.url.len > 0) e.url else e.video_url, r, 0);
    } else if (e.video) {
        att.playIcon(dl, r.x + r.w / 2, r.y + r.h / 2, alpha);
        d.tip(ctx, r, i18n.tr("Abrir o vídeo no navegador", "Open video in browser"), hb.hovered);
        if (hb.clicked and e.url.len > 0) att.openUrl(e.url);
    } else if (hb.clicked) att.openImage(ctx, e.image, e.title, e.image_w, e.image_h);
    if (hb.hovered) d.rect(dl, r, d.Rgba.white.alpha(0.05), 6);
}
