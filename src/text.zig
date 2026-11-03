//! Fontes e o renderizador de texto rico das mensagens (palavra por palavra,
//! com quebra de linha e estilos **negrito**, `código` e @menção).
const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");

pub const Fonts = struct {
    regular: *c.ImFont,
    medium: *c.ImFont,
    semibold: *c.ImFont,
    bold: *c.ImFont,
};

pub var fonts: Fonts = undefined;

const inter_path = "/usr/share/fonts/inter/Inter.ttc";
const emoji_path = "/usr/share/fonts/noto/NotoColorEmoji.ttf";
const load_color: c_uint = 1 << 8; // ImGuiFreeTypeLoaderFlags_LoadColor
const load_bitmap: c_uint = 1 << 9; // ImGuiFreeTypeLoaderFlags_Bitmap (emoji em CBDT)

fn defaultConfig() c.ImFontConfig {
    var cfg = std.mem.zeroes(c.ImFontConfig);
    cfg.FontDataOwnedByAtlas = true;
    cfg.ExtraSizeScale = 1.0;
    cfg.GlyphMaxAdvanceX = std.math.floatMax(f32);
    cfg.RasterizerMultiply = 1.0;
    cfg.RasterizerDensity = 1.0;
    return cfg;
}

/// Mapeia o arquivo da fonte na memória (somente leitura). Só as páginas que
/// o FreeType realmente lê ficam residentes, e todas as fontes compartilham
/// o mesmo mapeamento em vez de cada uma carregar uma cópia inteira.
fn mapFile(path: [*:0]const u8) ![]u8 {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return error.FontLoad;
    defer _ = c.close(fd);
    const size = c.lseek(fd, 0, c.SEEK_END);
    if (size <= 0) return error.FontLoad;
    const p = c.mmap(null, @intCast(size), c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.FontLoad;
    return @as([*]u8, @ptrCast(p))[0..@intCast(size)];
}

fn addFont(atlas: *c.ImFontAtlas, data: []u8, cfg: *c.ImFontConfig) ?*c.ImFont {
    cfg.FontDataOwnedByAtlas = false;
    return c.ImFontAtlas_AddFontFromMemoryTTF(atlas, data.ptr, @intCast(data.len), 16, cfg, null);
}

fn addInter(atlas: *c.ImFontAtlas, inter: []u8, emoji: ?[]u8, index: u32) !*c.ImFont {
    var cfg = defaultConfig();
    cfg.FontNo = index;
    cfg.PixelSnapH = true;
    const font = addFont(atlas, inter, &cfg) orelse return error.FontLoad;

    if (emoji) |e| {
        var ecfg = defaultConfig();
        ecfg.MergeMode = true;
        ecfg.FontLoaderFlags = load_color | load_bitmap;
        _ = addFont(atlas, e, &ecfg);
    }
    return font;
}

pub fn load(atlas: *c.ImFontAtlas) !void {
    const inter = try mapFile(inter_path);
    const emoji = mapFile(emoji_path) catch null;
    // Índices dentro do Inter.ttc (fc-query): 0 Regular, 10 Medium, 12 SemiBold, 14 Bold.
    fonts = .{
        .regular = try addInter(atlas, inter, emoji, 0),
        .medium = try addInter(atlas, inter, emoji, 10),
        .semibold = try addInter(atlas, inter, emoji, 12),
        .bold = try addInter(atlas, inter, emoji, 14),
    };
}

pub fn width(font: *c.ImFont, size: f32, s: []const u8) f32 {
    if (s.len == 0) return 0;
    const begin: [*]const u8 = s.ptr;
    return c.ImFont_CalcTextSizeAEx(font, size, std.math.floatMax(f32), 0, begin, begin + s.len, null).x;
}

pub fn draw(dl: *c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, col: u32, s: []const u8) void {
    if (s.len == 0) return;
    const begin: [*]const u8 = s.ptr;
    c.ImDrawList_AddTextImFontPtrEx(dl, font, size, .{ .x = @round(x), .y = @round(y) }, col, begin, begin + s.len, 0, null);
}

/// Desenha texto cortando com "…" se passar de `max_w`.
pub fn drawClipped(dl: *c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, col: u32, s: []const u8, max_w: f32) void {
    if (width(font, size, s) <= max_w) return draw(dl, font, size, x, y, col, s);
    const ell = "…";
    const avail = max_w - width(font, size, ell);
    var end: usize = s.len;
    while (end > 0) {
        end -= 1;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1; // não corta no meio de um caractere UTF-8
        if (width(font, size, s[0..end]) <= avail) break;
    }
    draw(dl, font, size, x, y, col, s[0..end]);
    draw(dl, font, size, x + width(font, size, s[0..end]), y, col, ell);
}

const Style = enum { normal, bold, code, mention };

const Token = struct {
    text: []const u8,
    style: Style,
    space_after: bool,
};

const Tokenizer = struct {
    s: []const u8,
    i: usize = 0,
    bold: bool = false,

    fn next(self: *Tokenizer) ?Token {
        while (self.i < self.s.len) {
            const rest = self.s[self.i..];
            if (std.mem.startsWith(u8, rest, "**")) {
                self.bold = !self.bold;
                self.i += 2;
                continue;
            }
            if (rest[0] == '`') {
                // Código inline: vira um bloco inteiro, sem quebra no meio.
                const close = std.mem.indexOfScalarPos(u8, self.s, self.i + 1, '`') orelse self.s.len;
                const tok = self.s[self.i + 1 .. close];
                self.i = @min(close + 1, self.s.len);
                return .{ .text = tok, .style = .code, .space_after = self.eatSpace() };
            }
            if (rest[0] == ' ') {
                self.i += 1;
                continue;
            }
            const start = self.i;
            while (self.i < self.s.len and self.s[self.i] != ' ' and self.s[self.i] != '`' and
                !std.mem.startsWith(u8, self.s[self.i..], "**")) : (self.i += 1)
            {}
            const tok = self.s[start..self.i];
            const style: Style = if (tok[0] == '@') .mention else if (self.bold) .bold else .normal;
            return .{ .text = tok, .style = style, .space_after = self.eatSpace() };
        }
        return null;
    }

    fn eatSpace(self: *Tokenizer) bool {
        if (self.i < self.s.len and self.s[self.i] == ' ') {
            self.i += 1;
            return true;
        }
        return false;
    }
};

pub const body_size: f32 = 16;
pub const line_height: f32 = 22;

fn fontFor(style: Style) *c.ImFont {
    return switch (style) {
        .normal => fonts.regular,
        .bold => fonts.bold,
        .code => fonts.medium,
        .mention => fonts.semibold,
    };
}

/// Faz o layout do texto de uma mensagem. Se `dl` for nulo só mede.
/// Retorna a altura ocupada.
pub fn rich(dl: ?*c.ImDrawList, s: []const u8, origin_x: f32, origin_y: f32, wrap: f32) f32 {
    const size = body_size;
    const space = width(fonts.regular, size, " ");
    const th = &theme.t;
    var x: f32 = 0;
    var y: f32 = 0;
    var tz: Tokenizer = .{ .s = s };
    while (tz.next()) |tok| {
        const font = fontFor(tok.style);
        const pad: f32 = switch (tok.style) {
            .code => 5,
            .mention => 3,
            else => 0,
        };
        const w = width(font, if (tok.style == .code) size - 2 else size, tok.text) + pad * 2;
        if (x > 0 and x + w > wrap) {
            x = 0;
            y += line_height;
        }
        if (dl) |d| {
            const px = origin_x + x;
            const py = origin_y + y;
            switch (tok.style) {
                .code => {
                    c.ImDrawList_AddRectFilledEx(d, .{ .x = px, .y = py + 1 }, .{ .x = px + w, .y = py + line_height - 1 }, th.tooltip.col(0.55), 5, 0);
                    draw(d, font, size - 2, px + pad, py + 2.5, th.text.mix(th.accent, 0.25).col(1), tok.text);
                },
                .mention => {
                    c.ImDrawList_AddRectFilledEx(d, .{ .x = px, .y = py + 1 }, .{ .x = px + w, .y = py + line_height - 1 }, th.accent.col(0.22), 4, 0);
                    draw(d, font, size, px + pad, py + 2, th.accent.mix(th.text, 0.45).col(1), tok.text);
                },
                .bold => draw(d, font, size, px, py + 2, th.text.col(1), tok.text),
                .normal => draw(d, font, size, px, py + 2, th.text.mix(th.muted, 0.12).col(1), tok.text),
            }
        }
        x += w + (if (tok.space_after) space else 0);
    }
    return y + line_height;
}
