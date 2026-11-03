//! Layout e desenho dos trechos de uma mensagem (já interpretados pelo
//! `core/markdown`). Quebra por palavra; código, menções e links não quebram.
const std = @import("std");
const c = @import("c");
const md = @import("../core/markdown.zig");
const Store = @import("../core/store.zig").Store;
const d = @import("draw.zig");

pub const Opts = struct {
    family: *d.Family,
    size: f32,
    line_h: f32,
    color: d.Rgba,
    /// Cor dos destaques quando o fundo é colorido (bolhas).
    on_accent: bool = false,
    reveal_spoilers: bool = false,
    underline_links: bool = true,
};

pub const Measure = struct { h: f32, w: f32 };

const Word = struct {
    text: []const u8,
    span: *const md.Span,
    space_after: bool,
};

/// Itera palavras dentro dos trechos.
const Words = struct {
    spans: []const md.Span,
    si: usize = 0,
    pos: usize = 0,

    fn next(it: *Words) ?Word {
        while (it.si < it.spans.len) {
            const sp = &it.spans[it.si];
            const s = sp.text;
            if (sp.flags.code or sp.flags.link or sp.mention != .none) {
                if (it.pos > 0) {
                    it.si += 1;
                    it.pos = 0;
                    continue;
                }
                it.pos = s.len;
                const space = it.si + 1 < it.spans.len and it.spans[it.si + 1].text.len > 0 and it.spans[it.si + 1].text[0] == ' ';
                return .{ .text = s, .span = sp, .space_after = space };
            }
            while (it.pos < s.len and (s[it.pos] == ' ' or s[it.pos] == '\n')) it.pos += 1;
            if (it.pos >= s.len) {
                it.si += 1;
                it.pos = 0;
                continue;
            }
            const start = it.pos;
            while (it.pos < s.len and s[it.pos] != ' ' and s[it.pos] != '\n') it.pos += 1;
            const space = it.pos < s.len or (it.si + 1 < it.spans.len and it.spans[it.si + 1].text.len > 0 and it.spans[it.si + 1].text[0] == ' ');
            return .{ .text = s[start..it.pos], .span = sp, .space_after = space };
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
        .user => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.user(id)) |u| u.name else "desconhecido"}) catch sp.text,
        .channel => |id| std.fmt.bufPrint(buf, "#{s}", .{if (store.channel(id)) |ch| ch.info.name else "canal"}) catch sp.text,
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
    while (it.next()) |word| {
        const sp = word.span;
        const font = fontFor(o, sp);
        const s = if (sp.mention != .none) label(store, sp, &buf) else word.text;
        const size = if (sp.flags.code) o.size - 1.5 else o.size;
        const pad: f32 = if (sp.flags.code) 5 else if (sp.mention != .none) 3 else 0;
        const w = d.width(font, size, s) + pad * 2;
        if (x > 0 and x + w > wrap) {
            x = 0;
            y += o.line_h;
        }
        if (dl) |l| drawWord(l, th_col, sp, font, size, s, x0 + x, y0 + y, w, pad, o, mouse);
        x += w;
        max_w = @max(max_w, x);
        if (word.space_after) x += space_w;
    }
    return .{ .h = y + o.line_h, .w = max_w };
}

fn drawWord(dl: *c.ImDrawList, th: anytype, sp: *const md.Span, font: *c.ImFont, size: f32, s: []const u8, x: f32, y: f32, w: f32, pad: f32, o: Opts, mouse: c.ImVec2) void {
    const lh = o.line_h;
    const ty = y + (lh - size * 1.2) / 2;
    const r: d.Rect = .{ .x = x, .y = y + 1, .w = w, .h = lh - 2 };
    if (sp.flags.spoiler and !o.reveal_spoilers and !r.contains(mouse.x, mouse.y)) {
        d.rect(dl, r.inset(-1, 0), th.c(.code_bg).mix(th.c(.text), 0.08), 4);
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
        if (o.underline_links or r.contains(mouse.x, mouse.y)) d.line(dl, x, ty + size * 1.12, x + w, ty + size * 1.12, lc.alpha(0.5), 1);
        return;
    }
    const color = if (sp.flags.bold) o.color.mix(th.c(.text), if (o.on_accent) 0 else 0.4) else o.color;
    d.text(dl, font, size, x, ty, color, s);
    if (sp.flags.strike) d.line(dl, x, ty + size * 0.62, x + w, ty + size * 0.62, color, 1.2);
}
