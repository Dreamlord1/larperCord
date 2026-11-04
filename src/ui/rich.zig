//! Layout e desenho dos trechos de uma mensagem (já interpretados pelo
//! `core/markdown`). Quebra por palavra; código, menções e links não quebram.
const std = @import("std");
const c = @import("c");
const md = @import("../core/markdown.zig");
const Store = @import("../core/store.zig").Store;
const d = @import("draw.zig");
const i18n = @import("i18n.zig");
const qa = @import("qa.zig");
const syntax = @import("syntax.zig");

pub const Opts = struct {
    family: *d.Family,
    size: f32,
    line_h: f32,
    color: d.Rgba,
    /// Cor dos destaques quando o fundo é colorido (bolhas).
    on_accent: bool = false,
    reveal_spoilers: bool = false,
    underline_links: bool = true,
    /// Para seleção: início do conteúdo (os trechos são fatias dele).
    base: ?[*]const u8 = null,
    sel_from: u32 = 1,
    sel_to: u32 = 0,
    probe: ?*Probe = null,
    /// Com o contexto, os blocos de código ganham o botão "Copiar".
    ctx: ?*d.Ctx = null,
    /// Mensagem dona do texto (só para a marcação do QA).
    msg_id: u64 = 0,
};

/// Pergunta "qual byte do texto está sob este ponto?".
pub const Probe = struct {
    x: f32,
    y: f32,
    out: ?u32 = null,
};

pub const Measure = struct { h: f32, w: f32, last_x: f32 };

const Word = struct {
    text: []const u8,
    span: *const md.Span,
    space_after: bool,
    /// Quebras de linha (\n) antes desta palavra.
    breaks: u8 = 0,
};

/// Itera palavras dentro dos trechos, contando as quebras de linha entre elas.
const Words = struct {
    spans: []const md.Span,
    si: usize = 0,
    pos: usize = 0,
    breaks: u8 = 0,

    fn take(it: *Words, w: Word) Word {
        var out = w;
        out.breaks = it.breaks;
        it.breaks = 0;
        return out;
    }

    fn next(it: *Words) ?Word {
        while (it.si < it.spans.len) {
            const sp = &it.spans[it.si];
            const s = sp.text;
            if (sp.flags.block) {
                // Uma linha do bloco por vez, sempre numa linha nova.
                if (it.pos >= s.len) {
                    it.si += 1;
                    it.pos = 0;
                    it.breaks = 1;
                    continue;
                }
                if (it.breaks == 0) it.breaks = 1;
                const start = it.pos;
                const nl = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
                it.pos = nl + 1;
                return it.take(.{ .text = s[start..nl], .span = sp, .space_after = false });
            }
            if (sp.flags.code or sp.flags.link or sp.mention != .none) {
                if (it.pos > 0) {
                    it.si += 1;
                    it.pos = 0;
                    continue;
                }
                it.pos = s.len;
                const space = it.si + 1 < it.spans.len and it.spans[it.si + 1].text.len > 0 and it.spans[it.si + 1].text[0] == ' ';
                return it.take(.{ .text = s, .span = sp, .space_after = space });
            }
            while (it.pos < s.len and (s[it.pos] == ' ' or s[it.pos] == '\n')) {
                if (s[it.pos] == '\n') it.breaks +|= 1;
                it.pos += 1;
            }
            if (it.pos >= s.len) {
                it.si += 1;
                it.pos = 0;
                continue;
            }
            const start = it.pos;
            while (it.pos < s.len and s[it.pos] != ' ' and s[it.pos] != '\n') it.pos += 1;
            const space = (it.pos < s.len and s[it.pos] == ' ') or (it.pos >= s.len and it.si + 1 < it.spans.len and it.spans[it.si + 1].text.len > 0 and it.spans[it.si + 1].text[0] == ' ');
            return it.take(.{ .text = s[start..it.pos], .span = sp, .space_after = space });
        }
        return null;
    }
};

fn fontFor(o: Opts, sp: *const md.Span) *c.ImFont {
    const f = sp.flags;
    if (f.code) return o.family.get(.medium);
    if (sp.mention != .none) return o.family.get(.semibold);
    if (f.bold) return o.family.get(.bold);
    if (f.italic) return o.family.get(.italic);
    return o.family.get(.regular);
}

fn label(store: *const Store, sp: *const md.Span, buf: []u8) []const u8 {
    return switch (sp.mention) {
        .none => sp.text,
        .user => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.user(id)) |u| u.name else i18n.tr("desconhecido", "unknown-user")}) catch sp.text,
        .channel => |id| std.fmt.bufPrint(buf, "#{s}", .{if (store.channel(id)) |ch| ch.info.name else i18n.tr("canal", "unknown")}) catch sp.text,
        .role => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.roles.get(id)) |r| r.name else i18n.tr("cargo", "unknown-role")}) catch sp.text,
    };
}

/// Mede (dl = null) ou desenha o texto. Retorna altura e maior largura de linha.
pub fn layout(dl: ?*c.ImDrawList, store: *const Store, th_col: anytype, spans: []const md.Span, x0: f32, y0: f32, wrap: f32, o: Opts, mouse: c.ImVec2) Measure {
    const space_w = d.width(o.family.get(.regular), o.size, " ");
    var x: f32 = 0;
    var y: f32 = 0;
    var max_w: f32 = 0;
    var it: Words = .{ .spans = spans };
    var buf: [96]u8 = undefined;
    var line_start = true;
    // Realce: o que ficou aberto na linha anterior do bloco (comentário…).
    var syn: syntax.State = .normal;
    // "Copiar" do bloco: desenhado depois da última linha, para ficar por cima.
    var copy: ?struct { sp: *const md.Span, x: f32, y: f32, at_top: bool } = null;
    while (it.next()) |word| {
        const sp = word.span;
        if (copy) |cp| if (cp.sp != sp) {
            copyButton(o.ctx.?, dl.?, cp.sp, cp.x, cp.y, wrap, cp.at_top, o, mouse);
            copy = null;
        };
        const font = fontFor(o, sp);
        const s = if (sp.mention != .none) label(store, sp, &buf) else word.text;
        const size = if (sp.flags.code) o.size - 1.5 else o.size;
        const pad: f32 = if (sp.flags.code) 5 else if (sp.mention != .none) 3 else 0;
        // Linha do bloco de código ocupa a largura toda (cortada se passar).
        const w = if (sp.flags.block) wrap else d.width(font, size, s) + pad * 2;
        if (word.breaks > 0 and !(x == 0 and y == 0 and line_start)) {
            // Uma linha nova por \n (linhas em branco contam, até 3).
            x = 0;
            y += o.line_h * @as(f32, @floatFromInt(@min(word.breaks, 3)));
            line_start = true;
        } else if (x > 0 and x + w > wrap) {
            x = 0;
            y += o.line_h;
            line_start = true;
        }
        if (dl) |l| {
            const block_top = sp.flags.block and word.text.ptr == sp.text.ptr;
            if (block_top) syn = .normal;
            if (o.base) |base| select(l, th_col, base, word, sp, font, size, pad, x0 + x, y0 + y, w, space_w, o, line_start);
            drawWord(l, th_col, sp, font, size, s, x0 + x, y0 + y, w, pad, o, mouse, &syn);
            if (block_top and o.ctx != null) copy = .{ .sp = sp, .x = x0 + x, .y = y0 + y, .at_top = y == 0 };
        }
        line_start = false;
        x += w;
        max_w = @max(max_w, x);
        if (word.space_after) x += space_w;
    }
    if (copy) |cp| copyButton(o.ctx.?, dl.?, cp.sp, cp.x, cp.y, wrap, cp.at_top, o, mouse);
    return .{ .h = y + o.line_h, .w = max_w, .last_x = x };
}

/// Byte do texto dentro da palavra que fica na coordenada `px`.
fn offsetAt(font: *c.ImFont, size: f32, t: []const u8, px: f32) u32 {
    var i: usize = 0;
    while (i < t.len) {
        const n = std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
        const mid = d.width(font, size, t[0..i]) + d.width(font, size, t[i..@min(t.len, i + n)]) / 2;
        if (px < mid) return @intCast(i);
        i += n;
    }
    return @intCast(t.len);
}

/// Desenha o fundo da seleção e responde à sonda do mouse.
fn select(dl: *c.ImDrawList, th: anytype, base: [*]const u8, word: Word, sp: *const md.Span, font: *c.ImFont, size: f32, pad: f32, x: f32, y: f32, w: f32, space_w: f32, o: Opts, line_start: bool) void {
    const start: u32 = @intCast(@intFromPtr(word.text.ptr) - @intFromPtr(base));
    const end: u32 = start + @as(u32, @intCast(word.text.len));
    const atomic = sp.mention != .none;
    if (o.sel_from < o.sel_to and start < o.sel_to and end > o.sel_from) {
        var hx0 = x;
        var hx1 = x + w;
        if (!atomic) {
            if (o.sel_from > start) hx0 = x + pad + d.width(font, size, word.text[0 .. o.sel_from - start]);
            if (o.sel_to < end) hx1 = x + pad + d.width(font, size, word.text[0 .. o.sel_to - start]);
        }
        if (word.space_after and o.sel_to > end) hx1 += space_w;
        d.rect(dl, .{ .x = hx0, .y = y, .w = hx1 - hx0, .h = o.line_h }, th.c(.accent).alpha(0.32), 0);
    }
    if (o.probe) |pr| if (pr.y >= y and pr.y < y + o.line_h) {
        if (pr.x >= x) {
            pr.out = if (pr.x >= x + w) end else if (atomic) (if (pr.x < x + w / 2) start else end) else start + offsetAt(font, size, word.text, pr.x - x - pad);
        } else if (line_start) pr.out = start;
    };
}

fn drawWord(dl: *c.ImDrawList, th: anytype, sp: *const md.Span, font: *c.ImFont, size: f32, s: []const u8, x: f32, y: f32, w: f32, pad: f32, o: Opts, mouse: c.ImVec2, syn: *syntax.State) void {
    const lh = o.line_h;
    const ty = y + (lh - size * 1.2) / 2;
    const r: d.Rect = .{ .x = x, .y = y + 1, .w = w, .h = lh - 2 };
    if (sp.flags.spoiler and !o.reveal_spoilers and !r.contains(mouse.x, mouse.y)) {
        d.rect(dl, r.inset(-1, 0), th.c(.code_bg).mix(th.c(.text), 0.08), 4);
        return;
    }
    if (sp.flags.block) {
        // Linha fora da área visível (bloco comprido, rolado): não desenha.
        // Acima dela o realce ainda anda (um comentário aberto continua na
        // linha de baixo); abaixo, nada.
        const clip_lo = c.ImDrawList_GetClipRectMin(dl);
        const clip_hi = c.ImDrawList_GetClipRectMax(dl);
        if (y >= clip_hi.y) return;
        if (y + lh <= clip_lo.y) {
            if (sp.lang != .none) {
                var lx = syntax.Lexer.init(sp.lang, s, syn);
                while (lx.next()) |_| {}
            }
            return;
        }
        // Linhas encostadas formam a caixa do bloco.
        d.rect(dl, .{ .x = x, .y = y, .w = w, .h = lh }, if (o.on_accent) d.Rgba.black.alpha(0.18) else th.c(.code_bg), 0);
        c.ImDrawList_PushClipRect(dl, d.v(x, y), d.v(x + w - pad, y + lh), true);
        const plain = if (o.on_accent) o.color else th.c(.text).mix(th.c(.accent), 0.15);
        if (sp.lang == .none) {
            d.text(dl, font, size, x + pad + 4, ty, plain, s);
        } else {
            // Um pedaço por token, cada um na cor do seu tipo. Passou da borda:
            // só lê o resto da linha (o realce da próxima depende dele).
            var lx = syntax.Lexer.init(sp.lang, s, syn);
            var tx = x + pad + 4;
            while (lx.next()) |t| {
                if (tx > x + w) continue;
                d.text(dl, font, size, tx, ty, tokenColor(th, t.kind, plain, o.on_accent), t.text);
                tx += d.width(font, size, t.text);
            }
        }
        c.ImDrawList_PopClipRect(dl);
        return;
    }
    if (sp.flags.code) {
        d.rect(dl, r, if (o.on_accent) d.Rgba.black.alpha(0.18) else th.c(.code_bg), 5);
        d.text(dl, font, size, x + pad, ty, if (o.on_accent) o.color else th.c(.text).mix(th.c(.accent), 0.25), s);
        return;
    }
    if (sp.mention != .none) {
        d.rect(dl, r, if (o.on_accent) d.Rgba.white.alpha(0.22) else th.c(.mention).alpha(0.22), 4);
        d.text(dl, font, size, x + pad, ty, if (o.on_accent) o.color else th.c(.mention).mix(th.c(.text), 0.45), s);
        return;
    }
    if (sp.flags.link) {
        const lc = if (o.on_accent) o.color else th.c(.link);
        d.text(dl, font, size, x, ty, lc, s);
        qa.mark(r, "link:{s}", .{s[0..@min(s.len, 48)]});
        const over = r.contains(mouse.x, mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
        if (o.underline_links or over) d.line(dl, x, ty + size * 1.12, x + w, ty + size * 1.12, lc.alpha(0.5), 1);
        // Clique abre no navegador (soltar sem arrastar, para não brigar com a seleção).
        if (over) {
            c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
            const drag = c.ImGui_GetMouseDragDelta(0, -1);
            if (c.ImGui_IsMouseReleased(0) and @abs(drag.x) + @abs(drag.y) < 4) @import("attachments.zig").openUrl(s);
        }
        return;
    }
    const color = if (sp.flags.bold) o.color.mix(th.c(.text), if (o.on_accent) 0 else 0.4) else o.color;
    d.text(dl, font, size, x, ty, color, s);
    if (sp.flags.strike) d.line(dl, x, ty + size * 0.62, x + w, ty + size * 0.62, color, 1.2);
}

/// Cores do realce, tiradas do tema (funcionam no claro e no escuro).
fn tokenColor(th: anytype, k: syntax.Kind, plain: d.Rgba, on_accent: bool) d.Rgba {
    // Em cima da cor de destaque (bolha própria) só o comentário muda.
    if (on_accent) return if (k == .comment) plain.alpha(plain.a * 0.6) else plain;
    const ink = th.c(.text);
    return switch (k) {
        .plain => plain,
        .keyword => th.c(.accent).mix(ink, 0.2),
        .type => th.c(.link).mix(ink, 0.25),
        .string => th.c(.online).mix(ink, 0.3),
        .number => th.c(.idle).mix(ink, 0.25),
        .comment => th.c(.faint),
        .add => th.c(.online),
        .del => th.c(.danger),
    };
}

/// "Copiar" no canto do bloco de código: aparece com o mouse em cima do
/// bloco e copia o código (sem as crases). Fica embaixo quando o bloco
/// abre a mensagem, para não brigar com a barra de ações.
fn copyButton(ctx: *d.Ctx, dl: *c.ImDrawList, sp: *const md.Span, x: f32, y: f32, wrap: f32, at_top: bool, o: Opts, mouse: c.ImVec2) void {
    const lines: f32 = @floatFromInt(std.mem.count(u8, sp.text, "\n") + 1);
    const block: d.Rect = .{ .x = x, .y = y, .w = wrap, .h = lines * o.line_h };
    const font = o.family.get(.semibold);
    const caption = i18n.tr("Copiar", "Copy");
    const fs: f32 = 12;
    const bh = @min(o.line_h - 2, 20);
    const bw = d.width(font, fs, caption) + 16;
    const by = if (at_top and lines > 1) block.bottom() - bh - 2 else block.y + 1;
    const br: d.Rect = .{ .x = block.right() - bw - 4, .y = by, .w = bw, .h = bh };
    const off = if (o.base) |b| @intFromPtr(sp.text.ptr) -% @intFromPtr(b) else 0;
    qa.mark(br, "code-copy:{d}:{d}", .{ o.msg_id, off });
    const in_window = c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
    if (!in_window or !block.contains(mouse.x, mouse.y) or ctx.st.popup != .none) return;
    const over = br.contains(mouse.x, mouse.y);
    const th = ctx.th;
    d.rect(dl, br, (if (over) th.c(.accent) else th.c(.elevated)).alpha(if (over) 1 else 0.92), 5);
    if (!over) d.border(dl, br, th.c(.border), 5, 1);
    d.text(dl, font, fs, br.x + 8, d.centerY(br, fs), if (over) th.c(.accent_text) else th.c(.muted), caption);
    if (!over) return;
    // A lista de mensagens não começa uma seleção neste clique.
    ctx.hot = true;
    c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    if (c.ImGui_IsMouseClicked(0)) {
        const copy = ctx.st.gpa.dupe(u8, sp.text) catch return;
        ctx.act(.{ .copy = copy });
    }
}
