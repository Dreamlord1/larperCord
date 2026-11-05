//! Layout e desenho dos trechos de uma mensagem (já interpretados pelo
//! `core/markdown`). Quebra por palavra; código, menções, links e emoji
//! personalizado não quebram.
const std = @import("std");
const c = @import("c");
const md = @import("../core/markdown.zig");
const Store = @import("../core/store.zig").Store;
const d = @import("draw.zig");
const i18n = @import("i18n.zig");
const qa = @import("qa.zig");
const syntax = @import("syntax.zig");
const emoji_img = @import("emoji_img.zig");

/// Contexto do quadro (o app marca): é ele que dá acesso às imagens dos emojis,
/// em qualquer lugar onde tenha texto (mensagem, embed, bio).
pub var frame_ctx: ?*d.Ctx = null;
/// Emoji personalizado vira imagem? No modo economia e sem fotos é o texto
/// `:nome:`, sem rede (mudar isto invalida as medidas: `Settings.layoutKey`).
pub var emoji_images = true;

/// Mensagem só de emoji, como no Discord: imagem de 48 e glifo proporcional.
const jumbo_box: f32 = 48;
const jumbo_font: f32 = 40;
const jumbo_line: f32 = 52;

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
    /// Lado do quadrado do emoji personalizado (o `layout` calcula).
    emoji_box: f32 = 0,
    /// Bloco de código com mais de uma linha: número desta linha e a largura
    /// da coluna dos números (o `layout` calcula).
    code_line: u32 = 0,
    code_gutter: f32 = 0,
};

/// Tamanho de um trecho em relação ao texto normal (títulos e `-#`).
fn scaleOf(sp: *const md.Span) f32 {
    if (sp.flags.sub) return 0.84;
    return switch (sp.flags.head) {
        1 => 1.6,
        2 => 1.35,
        3 => 1.2,
        else => 1,
    };
}

/// Altura da linha que começa neste trecho.
fn lineHeight(o: Opts, sp: *const md.Span) f32 {
    if (sp.flags.sub) return o.line_h * 0.92;
    return if (sp.flags.head != 0) o.line_h * scaleOf(sp) * 1.1 else o.line_h;
}

/// Recuo da linha: citação (a barra) e itens de lista.
fn indentOf(o: Opts, sp: *const md.Span) f32 {
    var n: f32 = 0;
    if (sp.flags.quote) n += o.size * 1.0;
    if (sp.flags.list) n += o.size * 1.3;
    if (sp.flags.nested) n += o.size * 1.3;
    return n;
}

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
            // Inteiro (o endereço não quebra); link com texto quebra como texto.
            if (sp.flags.bullet or sp.flags.code or (sp.flags.link and sp.url.len == 0) or sp.mention != .none or sp.emoji != 0) {
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
    if (f.bold or f.head != 0) return o.family.get(.bold);
    if (f.italic) return o.family.get(.italic);
    return o.family.get(.regular);
}

pub fn label(store: *const Store, sp: *const md.Span, buf: []u8) []const u8 {
    if (sp.flags.bullet) return "•";
    if (sp.emoji != 0) return std.fmt.bufPrint(buf, ":{s}:", .{sp.emojiName()}) catch sp.text;
    return switch (sp.mention) {
        .none => sp.text,
        .user => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.user(id)) |u| u.name else i18n.tr("desconhecido", "unknown-user")}) catch sp.text,
        .channel => |id| std.fmt.bufPrint(buf, "#{s}", .{if (store.channel(id)) |ch| ch.info.name else i18n.tr("canal", "unknown")}) catch sp.text,
        .role => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.roles.get(id)) |r| r.name else i18n.tr("cargo", "unknown-role")}) catch sp.text,
        .stamp => |v| stampText(buf, v),
    };
}

const months_pt = [_][]const u8{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" };
const months_en = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const days_pt = [_][]const u8{ "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado" };
const days_en = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// `<t:…>` no fuso de quem lê, nos estilos do Discord.
pub fn stampText(buf: []u8, value: u64) []const u8 {
    const st = md.stampOf(value);
    if (st.style == 'R') return relativeText(buf, st.unix);
    var dt: c.SDL_DateTime = undefined;
    if (!c.SDL_TimeToDateTime(st.unix * 1_000_000_000, &dt, true)) return "?";
    const en = i18n.en();
    const mon = (if (en) months_en else months_pt)[@intCast(std.math.clamp(dt.month, 1, 12) - 1)];
    const wd = (if (en) days_en else days_pt)[@intCast(std.math.clamp(dt.day_of_week, 0, 6))];
    // Sem sinal: com largura, o formato poria um "+" na frente de um número com sinal.
    const hour: u32 = @intCast(dt.hour);
    const minute: u32 = @intCast(dt.minute);
    const second: u32 = @intCast(dt.second);
    const month: u32 = @intCast(dt.month);
    const day: u32 = @intCast(dt.day);
    const year: u32 = @intCast(dt.year);
    const f = std.fmt.bufPrint;
    return switch (st.style) {
        't' => f(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }),
        'T' => f(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }),
        'd' => if (en) f(buf, "{d:0>2}/{d:0>2}/{d}", .{ month, day, year }) else f(buf, "{d:0>2}/{d:0>2}/{d}", .{ day, month, year }),
        'D' => if (en) f(buf, "{s} {d}, {d}", .{ mon, day, year }) else f(buf, "{d} de {s} de {d}", .{ day, mon, year }),
        'F' => if (en) f(buf, "{s}, {s} {d}, {d} {d:0>2}:{d:0>2}", .{ wd, mon, day, year, hour, minute }) else f(buf, "{s}, {d} de {s} de {d} {d:0>2}:{d:0>2}", .{ wd, day, mon, year, hour, minute }),
        else => if (en) f(buf, "{s} {d}, {d} {d:0>2}:{d:0>2}", .{ mon, day, year, hour, minute }) else f(buf, "{d} de {s} de {d} {d:0>2}:{d:0>2}", .{ day, mon, year, hour, minute }),
    } catch "?";
}

/// "em 2 horas", "há 3 dias": refeito a cada desenho, sem nada guardado.
fn relativeText(buf: []u8, unix: i64) []const u8 {
    var ns: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&ns);
    const delta = unix - @divTrunc(ns, 1_000_000_000);
    const secs = @abs(delta);
    const Unit = struct { size: u64, pt: []const u8, pts: []const u8, en: []const u8, ens: []const u8 };
    const units = [_]Unit{
        .{ .size = 365 * 86400, .pt = "ano", .pts = "anos", .en = "year", .ens = "years" },
        .{ .size = 30 * 86400, .pt = "mês", .pts = "meses", .en = "month", .ens = "months" },
        .{ .size = 86400, .pt = "dia", .pts = "dias", .en = "day", .ens = "days" },
        .{ .size = 3600, .pt = "hora", .pts = "horas", .en = "hour", .ens = "hours" },
        .{ .size = 60, .pt = "minuto", .pts = "minutos", .en = "minute", .ens = "minutes" },
        .{ .size = 1, .pt = "segundo", .pts = "segundos", .en = "second", .ens = "seconds" },
    };
    const u = for (units) |x| {
        if (secs >= x.size) break x;
    } else units[units.len - 1];
    const n = secs / u.size;
    const f = std.fmt.bufPrint;
    if (i18n.en()) {
        const name = if (n == 1) u.en else u.ens;
        return (if (delta < 0) f(buf, "{d} {s} ago", .{ n, name }) else f(buf, "in {d} {s}", .{ n, name })) catch "?";
    }
    const name = if (n == 1) u.pt else u.pts;
    return (if (delta < 0) f(buf, "há {d} {s}", .{ n, name }) else f(buf, "em {d} {s}", .{ n, name })) catch "?";
}

/// Largura de uma palavra. Uma enorme ("kkkk…"): se o começo já não cabe na
/// linha, não precisa medir o resto (ela vai em pedaços de qualquer jeito).
fn wordWidth(font: *c.ImFont, size: f32, s: []const u8, wrap: f32) f32 {
    if (s.len > 512) {
        const head = d.width(font, size, d.utf8Prefix(s, 512));
        if (head > wrap) return head;
    }
    return d.width(font, size, s);
}

/// Mede (dl = null) ou desenha o texto. Retorna altura e maior largura de linha.
pub fn layout(dl: ?*c.ImDrawList, store: *const Store, th_col: anytype, spans: []const md.Span, x0: f32, y0: f32, wrap: f32, o_in: Opts, mouse: c.ImVec2) Measure {
    var o = o_in;
    o.emoji_box = o.line_h;
    if (spans.len > 0 and spans[0].flags.jumbo and jumboShown(spans)) {
        o.size = jumbo_font;
        o.line_h = jumbo_line;
        o.emoji_box = jumbo_box;
    }
    const space_w = d.width(o.family.get(.regular), o.size, " ");
    var x: f32 = 0;
    var y: f32 = 0;
    var max_w: f32 = 0;
    var it: Words = .{ .spans = spans };
    var buf: [96]u8 = undefined;
    var line_start = true;
    // Altura e recuo da linha atual (título é mais alto, citação é recuada).
    var cur_h = o.line_h;
    var indent: f32 = 0;
    // Bloco de código: a linha atual e a coluna dos números.
    var code_line: u32 = 0;
    var gutter: f32 = 0;
    // Realce: o que ficou aberto na linha anterior do bloco (comentário…).
    var syn: syntax.State = .normal;
    // "Copiar" do bloco: desenhado depois da última linha, para ficar por cima.
    var copy: ?struct { sp: *const md.Span, x: f32, y: f32, at_top: bool } = null;
    while (it.next()) |word_in| {
        var word = word_in;
        // Palavra maior que a linha (link, "kkkkk…"): vai em pedaços.
        pieces: while (true) {
            const sp = word.span;
            if (copy) |cp| if (cp.sp != sp) {
                copyButton(o.ctx.?, dl.?, cp.sp, cp.x, cp.y, wrap, cp.at_top, o, mouse);
                copy = null;
            };
            const font = fontFor(o, sp);
            const as_image = sp.emoji != 0 and emoji_images;
            var s = if (sp.flags.bullet or sp.mention != .none or sp.emoji != 0) label(store, sp, &buf) else word.text;
            const scaled = o.size * scaleOf(sp);
            const size = if (sp.flags.code) scaled - 1.5 else scaled;
            const pad: f32 = if (sp.flags.code) 5 else if (sp.mention != .none) 3 else 0;
            // Linha do bloco de código ocupa a largura toda (cortada se passar).
            var w = if (sp.flags.block) wrap else if (as_image) o.emoji_box + 2 else wordWidth(font, size, s, wrap) + pad * 2;
            if (word.breaks > 0 and !(x == 0 and y == 0 and line_start)) {
                // Uma linha nova por \n (linhas em branco contam, até 3).
                x = 0;
                y += cur_h + o.line_h * @as(f32, @floatFromInt(@min(word.breaks, 3) - 1));
                line_start = true;
            } else if (x > indent and x + w > wrap) {
                x = 0;
                y += cur_h;
                line_start = true;
            }
            if (line_start) {
                cur_h = lineHeight(o, sp);
                indent = indentOf(o, sp);
                x = indent;
            }
            var rest: []const u8 = "";
            if (w > wrap - indent and !sp.flags.block and sp.mention == .none and sp.emoji == 0 and word.text.len > 1) {
                var fit = d.fitBytes(font, size, word.text, wrap - indent - pad * 2);
                // Nem um caractere cabe (coluna estreitíssima): anda um assim mesmo.
                if (fit == 0) fit = @min(std.unicode.utf8ByteSequenceLength(word.text[0]) catch 1, word.text.len);
                rest = word.text[fit..];
                word.text = word.text[0..fit];
                if (rest.len > 0) word.space_after = false;
                s = word.text;
                w = d.width(font, size, s) + pad * 2;
            }
            if (dl) |l| {
                const block_top = sp.flags.block and word.text.ptr == sp.text.ptr;
                if (block_top) {
                    syn = .normal;
                    code_line = 0;
                    // Uma linha só não precisa de número.
                    const lines = std.mem.count(u8, sp.text, "\n") + 1;
                    var nb: [12]u8 = undefined;
                    gutter = if (lines > 1) d.width(font, size, std.fmt.bufPrint(&nb, "{d}", .{lines}) catch "") + 10 else 0;
                }
                if (sp.flags.block) code_line += 1;
                var ol = o;
                ol.line_h = cur_h;
                if (sp.flags.block and gutter > 0) {
                    ol.code_line = code_line;
                    ol.code_gutter = gutter;
                }
                if (line_start and sp.flags.quote) d.rect(l, .{ .x = x0, .y = y0 + y, .w = 3, .h = cur_h }, th_col.c(.faint).alpha(o.color.a), 1.5);
                drawWord(l, th_col, sp, font, size, s, x0 + x, y0 + y, w, pad, ol, mouse, &syn);
                // A seleção vem por cima: o fundo do código não pode cobri-la.
                const sel_pad = if (sp.flags.block) pad + 4 + ol.code_gutter else pad;
                if (o.base) |base| select(l, th_col, base, word, sp, font, size, sel_pad, x0 + x, y0 + y, w, space_w, ol, line_start);
                if (block_top and o.ctx != null) copy = .{ .sp = sp, .x = x0 + x, .y = y0 + y, .at_top = y == 0 };
            }
            line_start = false;
            x += w;
            max_w = @max(max_w, x);
            if (rest.len > 0) {
                x = 0;
                y += cur_h;
                line_start = true;
                word = word_in;
                word.text = rest;
                word.breaks = 0;
                continue :pieces;
            }
            if (word.space_after) x += space_w;
            break;
        }
    }
    if (copy) |cp| copyButton(o.ctx.?, dl.?, cp.sp, cp.x, cp.y, wrap, cp.at_top, o, mouse);
    return .{ .h = y + cur_h, .w = max_w, .last_x = x };
}

/// Só emoji, mas personalizado sem imagem vira texto: aí não fica grande.
fn jumboShown(spans: []const md.Span) bool {
    if (emoji_images) return true;
    for (spans) |sp| if (sp.emoji != 0) return false;
    return true;
}

/// Byte do texto dentro da palavra que fica na coordenada `px`.
pub fn offsetAt(font: *c.ImFont, size: f32, t: []const u8, px: f32) u32 {
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
    const atomic = sp.flags.bullet or sp.mention != .none or sp.emoji != 0;
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
    if (sp.emoji != 0 and emoji_images) return drawEmoji(dl, sp, x, y, o, mouse);
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
        const code_x = x + pad + 4 + o.code_gutter;
        if (o.code_line > 0) {
            var nb: [12]u8 = undefined;
            const num = std.fmt.bufPrint(&nb, "{d}", .{o.code_line}) catch "";
            d.text(dl, font, size, code_x - 10 - d.width(font, size, num), ty, if (o.on_accent) o.color.alpha(o.color.a * 0.5) else th.c(.faint), num);
        }
        if (sp.lang == .none) {
            d.text(dl, font, size, code_x, ty, plain, s);
        } else {
            // Um pedaço por token, cada um na cor do seu tipo. Passou da borda:
            // só lê o resto da linha (o realce da próxima depende dele).
            var lx = syntax.Lexer.init(sp.lang, s, syn);
            var tx = code_x;
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
    if (sp.mention == .stamp) {
        d.rect(dl, r, if (o.on_accent) d.Rgba.white.alpha(0.18) else th.c(.code_bg), 4);
        d.text(dl, font, size, x + pad, ty, o.color, s);
        const v = sp.mention.stamp;
        qa.mark(r, "stamp:{d}", .{md.stampOf(v).unix});
        // "em 2 horas": a hora certa fica a um passar de mouse.
        if (o.ctx) |ctx| if (r.contains(mouse.x, mouse.y)) {
            var tb: [96]u8 = undefined;
            d.tip(ctx, r, stampText(&tb, (v >> 8) << 8 | 'F'), true);
        };
        return;
    }
    if (sp.mention != .none) {
        d.rect(dl, r, if (o.on_accent) d.Rgba.white.alpha(0.22) else th.c(.mention).alpha(0.22), 4);
        d.text(dl, font, size, x + pad, ty, if (o.on_accent) o.color else th.c(.mention).mix(th.c(.text), 0.45), s);
        if (o.ctx) |ctx| mentionClick(ctx, sp, r, mouse);
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
            if (c.ImGui_IsMouseReleased(0) and @abs(drag.x) + @abs(drag.y) < 4) {
                // Link do Discord abre aqui dentro; o resto, no navegador.
                if (o.ctx) |ctx| @import("links.zig").open(ctx, sp.target()) else @import("attachments.zig").openUrl(sp.target());
            }
            // Link com texto: o endereço de verdade aparece antes do clique.
            if (sp.url.len > 0) if (o.ctx) |ctx| d.tip(ctx, r, sp.url, true);
        }
        return;
    }
    if (sp.flags.bullet) {
        d.text(dl, font, size, x - size * 0.9, ty, o.color, s);
        return;
    }
    var color = if (sp.flags.bold or sp.flags.head != 0) o.color.mix(th.c(.text), if (o.on_accent) 0 else 0.4) else o.color;
    if (sp.flags.sub) color = if (o.on_accent) color.alpha(color.a * 0.75) else th.c(.muted).alpha(o.color.a);
    d.text(dl, font, size, x, ty, color, s);
    if (sp.flags.strike) d.line(dl, x, ty + size * 0.62, x + w, ty + size * 0.62, color, 1.2);
}

/// `@alguém` abre o cartão de perfil; `#canal` abre o canal. O botão direito
/// abre o menu de quem (ou do que) foi mencionado.
fn mentionClick(ctx: *d.Ctx, sp: *const md.Span, r: d.Rect, mouse: c.ImVec2) void {
    switch (sp.mention) {
        .user => |id| qa.mark(r, "mention:{d}", .{id}),
        .channel => |id| qa.mark(r, "mention-channel:{d}", .{id}),
        else => return,
    }
    if (!r.contains(mouse.x, mouse.y) or !c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows) or ctx.st.popup != .none) return;
    // A lista de mensagens não começa uma seleção neste clique.
    ctx.hot = true;
    c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    const left = c.ImGui_IsMouseClicked(0);
    const right = c.ImGui_IsMouseClicked(1);
    if (!left and !right) return;
    switch (sp.mention) {
        .user => |id| if (ctx.store.user(id) != null) {
            ctx.popup(if (left) .{ .profile = .{ .user = id, .x = r.right() + 4, .y = r.y } } else .{ .menu = .{ .kind = .user, .id = id, .x = mouse.x, .y = mouse.y } });
        } else if (left) ctx.st.showToast(ctx.now_ms, false, "não conheço essa pessoa ainda", "that user isn't known yet", .{}),
        .channel => |id| {
            if (ctx.store.channel(id) == null) {
                if (left) ctx.st.showToast(ctx.now_ms, false, "esse canal não está nesta conta", "that channel isn't on this account", .{});
            } else if (left) {
                ctx.act(.{ .select_channel = id });
            } else ctx.popup(.{ .menu = .{ .kind = .channel, .id = id, .x = mouse.x, .y = mouse.y } });
        },
        else => {},
    }
}

/// Emoji personalizado: a imagem num quadrado fixo (mede e desenha igual, com
/// ou sem a imagem carregada). Fora da área visível nem pede ao cache.
fn drawEmoji(dl: *c.ImDrawList, sp: *const md.Span, x: f32, y: f32, o: Opts, mouse: c.ImVec2) void {
    const ctx = frame_ctx orelse return;
    const box = o.emoji_box;
    const r: d.Rect = .{ .x = x + 1, .y = y + (o.line_h - box) / 2, .w = box, .h = box };
    const clip_lo = c.ImDrawList_GetClipRectMin(dl);
    const clip_hi = c.ImDrawList_GetClipRectMax(dl);
    if (r.y >= clip_hi.y or r.bottom() <= clip_lo.y) return;
    qa.mark(r, "emoji-inline:{d}", .{sp.emoji});
    const over = r.contains(mouse.x, mouse.y) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
    emoji_img.draw(ctx, dl, sp.emoji, sp.emoji_anim, r, o.color.a, over, true);
    if (over) {
        var nb: [72]u8 = undefined;
        d.tip(ctx, r, std.fmt.bufPrint(&nb, ":{s}:", .{sp.emojiName()}) catch "", true);
    }
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
