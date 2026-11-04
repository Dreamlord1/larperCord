//! Seletor de emoji: a lista Unicode inteira (ui/emoji_data.zig), recentes,
//! os emojis dos seus servidores e busca. A mesma janela escreve na caixa de
//! texto e reage a uma mensagem.
//!
//! A grade é virtualizada: todas as linhas têm a mesma altura, então a posição
//! de cada célula sai de uma conta. Só o que está à vista é desenhado (e só
//! isso pede imagem ao cache ou glifo à fonte). A busca roda quando o texto muda.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const popup = @import("popup.zig");
const emoji_data = @import("emoji_data.zig");
const emoji_img = @import("emoji_img.zig");
const autocomplete = @import("autocomplete.zig");
const types = @import("../core/types.zig");
const state = @import("state.zig");
const Id = types.Id;

const cols: usize = 9;
const cell: f32 = 38;
const header_h: f32 = 28;
const pad: f32 = 10;
const max_recent = 18;

const Cell = union(enum) {
    uni: u16,
    custom: types.Emoji,
};

const SectionKind = enum { recent, category, guild, results };
const Section = struct {
    kind: SectionKind,
    /// Categoria ou servidor.
    id: Id = 0,
    count: usize,
};

var query: [64]u8 = @splat(0);
var searched: [64]u8 = @splat(0);
var res_custom: [96]Id = undefined;
var n_custom: usize = 0;
var res_uni: [216]u16 = undefined;
var n_uni: usize = 0;
var tab: u8 = 0;
var pending_scroll: ?f32 = null;
/// Clicou numa aba ou categoria: digitar continua indo para a busca.
var want_focus = false;
var hovered: ?Cell = null;

// Emojis Unicode que a fonte sabe desenhar (uma fonte antiga não tem os mais
// novos; sem isso, apareceriam quadradinhos). Calculado na primeira abertura.
var shown: [emoji_data.count]u16 = undefined;
var cat_start: [emoji_data.categories.len + 1]usize = @splat(0);
var filtered = false;

var recent: [max_recent]Cell = undefined;
var n_recent: usize = 0;

fn filterByFont(font: *c.ImFont) void {
    if (filtered) return;
    filtered = true;
    var n: usize = 0;
    for (emoji_data.categories, 0..) |cat, k| {
        cat_start[k] = n;
        for (0..cat.count) |j| {
            const i: u16 = @intCast(cat.first + j);
            if (!inFont(font, emoji_data.glyphOf(i))) continue;
            shown[n] = i;
            n += 1;
        }
    }
    cat_start[emoji_data.categories.len] = n;
}

/// Complementos que a fonte desenha junto ou que a gente tira ao desenhar.
fn invisible(cp: u21) bool {
    return cp == 0xFE0F or cp == 0x200D or cp == 0x20E3 or (cp >= 0xE0020 and cp <= 0xE007F);
}

fn inFont(font: *c.ImFont, glyph: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(glyph).iterator();
    while (it.nextCodepoint()) |cp| {
        if (invisible(cp)) continue;
        if (!c.ImFont_IsGlyphInFont(font, cp)) return false;
    }
    return true;
}

pub const Drawable = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,
    pub fn slice(s: *const Drawable) []const u8 {
        return s.buf[0..s.len];
    }
};

/// O ImGui não junta sequências (família, profissão, bandeira de tags): cada
/// pedaço vira um desenho. Fica o que tem desenho; o que vai para o Discord
/// continua sendo o emoji inteiro.
pub fn drawable(glyph: []const u8) Drawable {
    var out: Drawable = .{};
    var it = std.unicode.Utf8View.initUnchecked(glyph).iterator();
    while (it.nextCodepointSlice()) |sl| {
        const cp = std.unicode.utf8Decode(sl) catch continue;
        if (invisible(cp) and cp != 0x20E3) continue;
        if (out.len + sl.len > out.buf.len) break;
        @memcpy(out.buf[out.len..][0..sl.len], sl);
        out.len += @intCast(sl.len);
    }
    return out;
}

/// Tamanho para caber em `room` (sequências desenhadas lado a lado encolhem).
pub fn fitSize(font: *c.ImFont, s: []const u8, size: f32, room: f32) f32 {
    const tw = d.width(font, size, s);
    return if (tw > room) @max(size * room / tw, 9) else size;
}

/// Quantos emojis Unicode aparecem no seletor (o QA confere).
pub fn shownCount() usize {
    return cat_start[emoji_data.categories.len];
}

// --- Recentes -----------------------------------------------------------------

fn loadRecent(st: *const state.State, store: anytype) void {
    n_recent = 0;
    var it = std.mem.tokenizeScalar(u8, st.settings.emoji_recent.slice(), ' ');
    while (it.next()) |tok| {
        if (n_recent == recent.len) break;
        // Personalizado: "nome:id". Unicode: o próprio emoji (acha pelo blob).
        if (std.mem.indexOfScalar(u8, tok, ':')) |colon| {
            const id = std.fmt.parseInt(Id, tok[colon + 1..], 10) catch continue;
            // De um servidor de que saímos (ou de outra conta): fica de fora.
            const e = store.emoji_by_id.get(id) orelse continue;
            recent[n_recent] = .{ .custom = e };
            n_recent += 1;
        } else if (indexOfGlyph(tok)) |u| {
            recent[n_recent] = .{ .uni = u };
            n_recent += 1;
        }
    }
}

fn indexOfGlyph(g: []const u8) ?u16 {
    var i: u16 = 0;
    while (i < emoji_data.count) : (i += 1) {
        if (std.mem.eql(u8, emoji_data.glyphOf(i), g)) return i;
    }
    return null;
}

/// Põe na frente dos recentes (Configurações guarda; o app salva no próximo quadro).
pub fn remember(st: *state.State, is_custom: bool, id: Id, uni: u16, name: []const u8, animated: bool) void {
    _ = animated;
    var nb: [64]u8 = undefined;
    const tok: []const u8 = if (is_custom) std.fmt.bufPrint(&nb, "{s}:{d}", .{ name, id }) catch return else emoji_data.glyphOf(uni);
    var out: [255]u8 = undefined;
    var n: usize = 0;
    @memcpy(out[0..tok.len], tok);
    n = tok.len;
    var kept: usize = 1;
    var it = std.mem.tokenizeScalar(u8, st.settings.emoji_recent.slice(), ' ');
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, tok)) continue;
        if (kept == max_recent or n + 1 + t.len > out.len) break;
        out[n] = ' ';
        @memcpy(out[n + 1 ..][0..t.len], t);
        n += 1 + t.len;
        kept += 1;
    }
    st.settings.emoji_recent.set(out[0..n]);
    st.filtros.save = true;
}

// --- Busca --------------------------------------------------------------------

fn runSearch(ctx: *d.Ctx, guild: Id) void {
    const q = std.mem.sliceTo(&query, 0);
    n_custom = 0;
    n_uni = 0;
    if (q.len == 0) return;
    var fb: [64]u8 = undefined;
    const folded = emoji_data.fold(&fb, q);
    // Personalizados: os do servidor aberto primeiro, depois quem casa melhor.
    const Scored = struct { id: Id, sc: i32 };
    var tmp: [res_custom.len]Scored = undefined;
    var it = ctx.store.emoji_by_id.valueIterator();
    while (it.next()) |e| {
        const m = emoji_data.matchName(e.name, folded);
        if (m == 0) continue;
        const sc = m + (if (e.guild == guild) @as(i32, 200) else 0);
        var k = n_custom;
        if (n_custom == tmp.len) {
            if (tmp[k - 1].sc >= sc) continue;
            k -= 1;
        } else n_custom += 1;
        while (k > 0 and tmp[k - 1].sc < sc) : (k -= 1) tmp[k] = tmp[k - 1];
        tmp[k] = .{ .id = e.id, .sc = sc };
    }
    for (tmp[0..n_custom], 0..) |t, i| res_custom[i] = t.id;
    var hits: [res_uni.len]emoji_data.Hit = undefined;
    for (emoji_data.search(q, &hits)) |h| {
        res_uni[n_uni] = h.index;
        n_uni += 1;
    }
}

// --- Seções -------------------------------------------------------------------

fn rowsOf(n: usize) usize {
    return (n + cols - 1) / cols;
}

fn sectionH(sec: Section) f32 {
    return header_h + @as(f32, @floatFromInt(rowsOf(sec.count))) * cell;
}

fn cellAt(ctx: *const d.Ctx, sec: Section, i: usize) ?Cell {
    switch (sec.kind) {
        .recent => return recent[i],
        .category => return .{ .uni = shown[cat_start[@intCast(sec.id)] + i] },
        .guild => {
            const list = ctx.store.guild_emojis.get(sec.id) orelse return null;
            return if (i < list.len) .{ .custom = list[i] } else null;
        },
        .results => {
            if (i < n_custom) return .{ .custom = ctx.store.emoji_by_id.get(res_custom[i]) orelse return null };
            return .{ .uni = res_uni[i - n_custom] };
        },
    }
}

fn sectionTitle(ctx: *const d.Ctx, sec: Section) []const u8 {
    return switch (sec.kind) {
        .recent => i18n.tr("RECENTES", "RECENT"),
        .category => blk: {
            const cat = emoji_data.categories[@intCast(sec.id)];
            break :blk i18n.tr(cat.name, cat.name_en);
        },
        .guild => if (ctx.store.guild(sec.id)) |g| g.name else "?",
        .results => i18n.tr("RESULTADOS", "RESULTS"),
    };
}

/// A conversa em que o emoji vai ser usado: o servidor da mensagem que recebe a
/// reação, ou o do canal aberto.
fn contextGuild(ctx: *d.Ctx, target: Id) Id {
    if (target != 0) {
        const f = ctx.store.findAny(target) orelse return 0;
        return f.cs.info.guild;
    }
    const ch = ctx.st.activeChannel() orelse return 0;
    const cs = ctx.store.channel(ch) orelse return 0;
    return cs.info.guild;
}

fn pick(ctx: *d.Ctx, cl: Cell, target: Id, guild: Id) void {
    const st = ctx.st;
    switch (cl) {
        .uni => |u| {
            const glyph = emoji_data.glyphOf(u);
            remember(st, false, 0, u, "", false);
            if (target == 0) {
                autocomplete.insertAtCursor(st, glyph);
            } else ctx.act(.{ .react = .{ .id = target, .emoji = types.Reaction.init(glyph) } });
        },
        .custom => |*e| {
            switch (ctx.store.emojiUse(e, guild)) {
                .ok => {},
                .needs_nitro => return st.showToast(ctx.now_ms, true, "este emoji precisa de Nitro: é animado ou de outro servidor", "this emoji requires Nitro: it's animated or from another server", .{}),
                .unavailable => return st.showToast(ctx.now_ms, true, "este emoji está indisponível no servidor dele", "this emoji is unavailable in its server", .{}),
            }
            remember(st, true, e.id, 0, e.name, e.animated);
            if (target == 0) {
                var sb: [40]u8 = undefined;
                var rb: [64]u8 = undefined;
                const shown_txt = std.fmt.bufPrint(&sb, ":{s}:", .{e.name}) catch return;
                const repl = std.fmt.bufPrint(&rb, "<{s}:{s}:{d}>", .{ if (e.animated) "a" else "", e.name, e.id }) catch return;
                autocomplete.addToken(shown_txt, repl);
                autocomplete.insertAtCursor(st, shown_txt);
            } else ctx.act(.{ .react = .{ .id = target, .emoji = types.Reaction.initCustom(e.name, e.id, e.animated) } });
        },
    }
    popup.close(ctx);
}

// --- Desenho ------------------------------------------------------------------

pub fn draw(ctx: *d.Ctx, target: Id, x: f32, y: f32) void {
    const font = ctx.ui.get(.regular);
    filterByFont(font);
    if (popup.appearing) {
        @memset(&query, 0);
        @memset(&searched, 0);
        n_custom = 0;
        n_uni = 0;
        tab = 0;
        pending_scroll = 0;
        loadRecent(ctx.st, ctx.store);
    }
    const guild = contextGuild(ctx, target);
    const wd = @as(f32, @floatFromInt(cols)) * cell + pad * 2 + 12;
    const h = @min(@as(f32, 460), ctx.win.h - 16);
    const r = popup.fit(ctx, x - wd + 40, y - h - 8, wd, h);
    const dl = popup.beginWindow("##emoji", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius + 2, 6);
    d.shadow(dl, r, radius, 16, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
    qa.mark(r, "emoji-picker", .{});

    // Busca.
    const sb: d.Rect = .{ .x = r.x + pad, .y = r.y + pad, .w = r.w - pad * 2, .h = 32 };
    qa.mark(sb, "emoji-search", .{});
    const fs: f32 = 14;
    d.rect(dl, sb, ctx.col(.elevated), @max(ctx.th.radius, 4));
    icons.search(dl, sb.x + 16, sb.y + 16, ctx.col(.faint).u());
    c.ImGui_PushFontFloat(font, fs * d.text_scale);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_FrameBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    c.ImGui_SetCursorScreenPos(d.v(sb.x + 28, sb.y + 5));
    c.ImGui_SetNextItemWidth(sb.w - 34);
    if (popup.appearing or want_focus) c.ImGui_SetKeyboardFocusHere();
    want_focus = false;
    const enter = c.ImGui_InputTextWithHint("##emoji-q", i18n.trZ("Buscar emoji", "Search emoji").ptr, &query, query.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
    c.ImGui_PopStyleColor();
    c.ImGui_PopFont();
    const q = std.mem.sliceTo(&query, 0);
    const q_changed = !std.mem.eql(u8, q, std.mem.sliceTo(&searched, 0));
    if (q_changed) {
        searched = query;
        runSearch(ctx, guild);
        pending_scroll = 0;
    }
    const searching = q.len > 0;

    var ty = sb.bottom() + 8;
    // Abas e título do que vai acontecer.
    if (!searching) {
        var tx = r.x + pad;
        const tabs = [_][]const u8{ i18n.tr("Emojis", "Emoji"), i18n.tr("Servidores", "Servers") };
        for (tabs, 0..) |t, i| {
            const f = ctx.ui.get(.semibold);
            const tw = d.width(f, 13, t) + 20;
            const tr: d.Rect = .{ .x = tx, .y = ty, .w = tw, .h = 26 };
            const hb = d.hit(ctx, 8100 + i, tr);
            qa.mark(tr, "emoji-tab:{d}", .{i});
            const on = tab == i;
            if (on) d.rect(dl, tr, ctx.col(.accent).alpha(0.18), 6) else if (hb.hovered) d.rect(dl, tr, ctx.col(.hover), 6);
            d.text(dl, f, 13, tr.x + 10, d.centerY(tr, 13), if (on) ctx.col(.accent).mix(ctx.col(.text), 0.4) else ctx.col(.muted), t);
            if (hb.clicked and !on) {
                tab = @intCast(i);
                pending_scroll = 0;
                want_focus = true;
            }
            tx += tw + 4;
        }
        const lbl = if (target == 0) i18n.tr("escrever", "write") else i18n.tr("reagir", "react");
        const lw = d.width(ctx.ui.get(.regular), 12, lbl);
        d.text(dl, ctx.ui.get(.regular), 12, r.right() - pad - lw, d.centerY(.{ .x = 0, .y = ty, .w = 0, .h = 26 }, 12), ctx.col(.faint), lbl);
        ty += 30;
    }

    // Seções desta tela.
    var secs: [emoji_data.categories.len + 256]Section = undefined;
    var n_secs: usize = 0;
    if (searching) {
        secs[0] = .{ .kind = .results, .count = n_custom + n_uni };
        n_secs = 1;
    } else if (tab == 0) {
        if (n_recent > 0) {
            secs[0] = .{ .kind = .recent, .count = n_recent };
            n_secs = 1;
        }
        for (emoji_data.categories, 0..) |_, k| {
            const n = cat_start[k + 1] - cat_start[k];
            if (n == 0) continue;
            secs[n_secs] = .{ .kind = .category, .id = k, .count = n };
            n_secs += 1;
        }
    } else {
        // O servidor aberto em cima, depois os outros na ordem da barra.
        if (ctx.store.guild_emojis.get(guild)) |list| {
            secs[0] = .{ .kind = .guild, .id = guild, .count = list.len };
            n_secs = 1;
        }
        for (ctx.store.guilds.items) |g| {
            if (g.id == guild or n_secs == secs.len) continue;
            const list = ctx.store.guild_emojis.get(g.id) orelse continue;
            secs[n_secs] = .{ .kind = .guild, .id = g.id, .count = list.len };
            n_secs += 1;
        }
    }

    // Trilho de categorias: pula direto para uma delas.
    if (!searching and tab == 0) {
        const n_rail = n_secs;
        const step = (r.w - pad * 2) / @as(f32, @floatFromInt(@max(n_rail, 1)));
        var off: f32 = 0;
        for (secs[0..n_secs], 0..) |sec, i| {
            const cr: d.Rect = .{ .x = r.x + pad + step * @as(f32, @floatFromInt(i)), .y = ty, .w = step, .h = 28 };
            const hb = d.hit(ctx, 8200 + i, cr);
            qa.mark(cr, "emoji-cat:{d}", .{i});
            if (hb.hovered) d.rect(dl, cr, ctx.col(.hover), 5);
            if (sec.kind == .recent) {
                // Um reloginho.
                const cx = cr.x + cr.w / 2;
                const cy = cr.y + 14;
                c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 7.5, ctx.col(.muted).u(), 0, 1.5, 0);
                d.line(dl, cx, cy, cx, cy - 4.5, ctx.col(.muted), 1.5);
                d.line(dl, cx, cy, cx + 3.5, cy + 1.5, ctx.col(.muted), 1.5);
            } else {
                const icon = emoji_data.categories[@intCast(sec.id)].icon;
                const tw = d.width(font, 17, icon);
                d.text(dl, font, 17, cr.x + (cr.w - tw) / 2, cr.y + 14 - 17 * 0.6, d.Rgba.white, icon);
            }
            d.tip(ctx, cr, sectionTitle(ctx, sec), hb.hovered);
            if (hb.clicked) {
                pending_scroll = off;
                want_focus = true;
            }
            off += sectionH(sec);
        }
        ty += 32;
    }

    // Enter na busca escolhe o primeiro resultado.
    if (enter and searching and n_custom + n_uni > 0) {
        if (cellAt(ctx, secs[0], 0)) |first| return pick(ctx, first, target, guild);
    }

    const footer_h: f32 = 38;
    const body: d.Rect = .{ .x = r.x + pad, .y = ty, .w = r.w - pad - 2, .h = r.bottom() - footer_h - ty };
    var total: f32 = 4;
    for (secs[0..n_secs]) |sec| total += sectionH(sec);

    if (pending_scroll) |p| {
        c.ImGui_SetNextWindowScroll(d.v(-1, p));
        pending_scroll = null;
    }
    const gdl = d.beginRegion(ctx, "##emoji-grid", body, 0);
    popup.track(gdl);
    c.ImGui_Dummy(d.v(body.w - 14, total));
    const scroll = c.ImGui_GetScrollY();
    hovered = null;
    var oy: f32 = 0;
    for (secs[0..n_secs], 0..) |sec, si| {
        const sh = sectionH(sec);
        defer oy += sh;
        // Fora da tela: passa direto, sem olhar uma célula.
        if (oy + sh < scroll or oy > scroll + body.h) continue;
        const top = body.y - scroll + oy;
        if (oy + header_h >= scroll) {
            var up: [96]u8 = undefined;
            const title = d.upper(&up, sectionTitle(ctx, sec));
            _ = d.textClipped(gdl, ctx.ui.get(.bold), 11, body.x + 2, top + 10, ctx.col(.muted), title, body.w - 20);
        }
        const rows = rowsOf(sec.count);
        const first_row: usize = if (scroll > oy + header_h) @intFromFloat((scroll - oy - header_h) / cell) else 0;
        var row = first_row;
        while (row < rows) : (row += 1) {
            const ry = top + header_h + @as(f32, @floatFromInt(row)) * cell;
            if (ry > body.bottom()) break;
            for (0..cols) |col| {
                const i = row * cols + col;
                if (i >= sec.count) break;
                const cl = cellAt(ctx, sec, i) orelse continue;
                const er: d.Rect = .{ .x = body.x + @as(f32, @floatFromInt(col)) * cell, .y = ry, .w = cell, .h = cell };
                drawCell(ctx, gdl, cl, er, sec, si, i, guild, target);
                if (ctx.st.popup != .emoji) {
                    c.ImGui_EndChild();
                    return;
                }
            }
        }
    }
    if (n_secs == 0 or total <= 4 or (searching and n_custom + n_uni == 0) or (!searching and tab == 1 and n_secs == 0)) {
        const msg = if (searching) i18n.tr("Nada encontrado.", "Nothing found.") else i18n.tr("Nenhum servidor seu tem emojis.", "None of your servers have emoji.");
        const f = ctx.ui.get(.medium);
        const tw = d.width(f, 13, msg);
        d.text(gdl, f, 13, body.x + (body.w - tw) / 2, body.y + 40, ctx.col(.muted), msg);
    }
    c.ImGui_EndChild();

    // Rodapé: o que está sob o mouse.
    const fr: d.Rect = .{ .x = r.x, .y = r.bottom() - footer_h, .w = r.w, .h = footer_h };
    d.line(dl, r.x + 1, fr.y, r.right() - 1, fr.y, ctx.col(.border), 1);
    if (hovered) |cl| footer(ctx, dl, cl, fr, guild) else d.text(dl, ctx.ui.get(.regular), 12, fr.x + 14, d.centerY(fr, 12), ctx.col(.faint), i18n.tr("Passe o mouse para ver o nome", "Hover to see the name"));
}

fn lockedFor(ctx: *const d.Ctx, cl: Cell, guild: Id) bool {
    return switch (cl) {
        .uni => false,
        .custom => |*e| ctx.store.emojiUse(e, guild) != .ok,
    };
}

fn drawCell(ctx: *d.Ctx, dl: *c.ImDrawList, cl: Cell, er: d.Rect, sec: Section, si: usize, i: usize, guild: Id, target: Id) void {
    const hb = d.hit(ctx, si * 4096 + i + 16384, er);
    switch (sec.kind) {
        .recent => qa.mark(er, "emoji-recent:{d}", .{i}),
        else => switch (cl) {
            .uni => |u| qa.mark(er, "emoji:{d}", .{u}),
            .custom => |*e| qa.mark(er, "emoji-custom:{d}", .{e.id}),
        },
    }
    if (hb.hovered) {
        d.rect(dl, er.inset(2, 2), ctx.col(.hover).mix(ctx.col(.text), 0.05), 6);
        hovered = cl;
    }
    const locked = lockedFor(ctx, cl, guild);
    switch (cl) {
        .uni => |u| {
            const font = ctx.ui.get(.regular);
            const g = drawable(emoji_data.glyphOf(u));
            const es = fitSize(font, g.slice(), 24, cell - 6);
            const tw = d.width(font, es, g.slice());
            d.text(dl, font, es, er.x + (cell - tw) / 2, er.y + cell / 2 - es * 0.6, d.Rgba.white, g.slice());
        },
        .custom => |*e| {
            const box = er.inset(5, 5);
            const alpha: f32 = if (locked) 0.4 else 1;
            if (emoji_img.enabled(ctx)) {
                // Parado até passar o mouse: uma tela cheia de animados não
                // acorda o app a cada quadro.
                emoji_img.draw(ctx, dl, e.id, e.animated, box, alpha, hb.hovered, false);
            } else {
                // Modo economia: as iniciais no lugar da imagem (nada de rede).
                d.rect(dl, box, ctx.col(.text).alpha(0.08), 6);
                const f = ctx.ui.get(.semibold);
                const ini = d.utf8Prefix(e.name, 2);
                const tw = d.width(f, 12, ini);
                d.text(dl, f, 12, box.x + (box.w - tw) / 2, d.centerY(box, 12), ctx.col(.muted).alpha(alpha), ini);
            }
            if (locked) icons.lock(dl, er.right() - 9, er.bottom() - 10, ctx.col(.text).u());
        },
    }
    if (hb.clicked) pick(ctx, cl, target, guild);
}

fn footer(ctx: *d.Ctx, dl: *c.ImDrawList, cl: Cell, fr: d.Rect, guild: Id) void {
    const cy = fr.y + fr.h / 2;
    const f = ctx.ui.get(.semibold);
    var nb: [80]u8 = undefined;
    switch (cl) {
        .uni => |u| {
            const font = ctx.ui.get(.regular);
            const g = drawable(emoji_data.glyphOf(u));
            const es = fitSize(font, g.slice(), 20, 28);
            d.text(dl, font, es, fr.x + 14, cy - es * 0.6, d.Rgba.white, g.slice());
            const name = std.fmt.bufPrint(&nb, ":{s}:", .{emoji_data.get(u).code}) catch "";
            _ = d.textClipped(dl, f, 13, fr.x + 46, d.centerY(fr, 13), ctx.col(.text), name, fr.w - 56);
        },
        .custom => |*e| {
            if (emoji_img.enabled(ctx)) emoji_img.draw(ctx, dl, e.id, e.animated, .{ .x = fr.x + 14, .y = cy - 12, .w = 24, .h = 24 }, 1, true, false);
            const name = std.fmt.bufPrint(&nb, ":{s}:", .{e.name}) catch "";
            const hint: []const u8 = switch (ctx.store.emojiUse(e, guild)) {
                .ok => if (ctx.store.guild(e.guild)) |g| g.name else "",
                .needs_nitro => i18n.tr("precisa de Nitro", "requires Nitro"),
                .unavailable => i18n.tr("indisponível", "unavailable"),
            };
            const hw = d.width(ctx.ui.get(.regular), 12, hint);
            _ = d.textClipped(dl, f, 13, fr.x + 46, d.centerY(fr, 13), ctx.col(.text), name, fr.w - 66 - hw);
            d.text(dl, ctx.ui.get(.regular), 12, fr.right() - hw - 12, d.centerY(fr, 12), ctx.col(.faint), hint);
        },
    }
}
