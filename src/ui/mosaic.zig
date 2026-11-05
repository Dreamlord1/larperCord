//! Tela dividida ("mosaico"): 2 ou 3 conversas lado a lado, como num
//! gerenciador de janelas. Cada painel desenha o histórico do seu canal com
//! a rolagem dele (comp_messages.history). O painel focado é sempre o da aba
//! ativa: a caixa de texto, o cabeçalho e a lista de membros seguem ele sem
//! saber do mosaico. "Abrir ao lado" no menu do canal cria um painel; o X
//! no título fecha; clicar num painel lateral foca ele.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const msgs = @import("comp_messages.zig");
const layout = @import("../theme/layout.zig");
const resize = @import("resize.zig");
const S = @import("settings_state.zig");
const sigil = @import("comp_chat.zig").sigil;
const Id = @import("../core/types.zig").Id;

pub const max = 3;
const bar_h: f32 = 30;
const gap: f32 = 1;

pub const Panes = struct {
    ids: [max]Id = @splat(0),
    /// Quantos painéis; menos de 2 = desligado.
    count: u8 = 0,
    focus: u8 = 0,

    pub fn indexOf(p: *const Panes, id: Id) ?usize {
        return std.mem.indexOfScalar(Id, p.ids[0..p.count], id);
    }

    fn remove(p: *Panes, i: usize) void {
        std.mem.copyForwards(Id, p.ids[i .. p.count - 1], p.ids[i + 1 .. p.count]);
        p.count -= 1;
        if (p.focus > i or p.focus >= p.count) p.focus -|= 1;
    }
};

pub var panes: Panes = .{};

pub fn on() bool {
    return panes.count >= 2;
}

/// "Abrir ao lado" faz sentido: canal de texto que ainda não está na tela.
pub fn canOpenBeside(ctx: *const d.Ctx, id: Id) bool {
    const cs = ctx.store.channel(id) orelse return false;
    const active = ctx.st.activeChannel() orelse return false;
    return cs.info.kind == .text and id != active and panes.indexOf(id) == null;
}

/// Abre o canal num painel novo ao lado do atual (e foca ele). Com os três
/// painéis ocupados, troca o último que não é o focado.
pub fn openBeside(ctx: *d.Ctx, id: Id) void {
    const active = ctx.st.activeChannel() orelse return;
    if (id == active) return;
    if (panes.count == 0) panes = .{ .ids = .{ active, 0, 0 }, .count = 1 };
    if (panes.indexOf(id)) |j| return focusPane(ctx, j);
    const slot: usize = if (panes.count < max) blk: {
        panes.count += 1;
        break :blk panes.count - 1;
    } else if (panes.focus == max - 1) max - 2 else max - 1;
    panes.ids[slot] = id;
    focusPane(ctx, slot);
}

/// Fecha o painel `i`. Sobrando um só, a tela volta a ser uma conversa.
pub fn close(ctx: *d.Ctx, i: usize) void {
    if (i >= panes.count) return;
    const was_focus = i == panes.focus;
    panes.remove(i);
    if (panes.count < 2) {
        const keep = panes.ids[0];
        panes = .{};
        if (ctx.st.activeChannel() != keep) focusChannel(ctx, keep);
        return;
    }
    if (was_focus) focusPane(ctx, panes.focus);
}

fn focusPane(ctx: *d.Ctx, i: usize) void {
    panes.focus = @intCast(i);
    focusChannel(ctx, panes.ids[i]);
}

/// Torna o canal a aba ativa (abrindo uma aba se ele não tiver).
fn focusChannel(ctx: *d.Ctx, id: Id) void {
    const st = ctx.st;
    if (std.mem.indexOfScalar(Id, st.tabs.items, id)) |k| return ctx.act(.{ .focus_tab = k });
    st.tabs.append(st.gpa, id) catch return;
    ctx.act(.{ .focus_tab = st.tabs.items.len - 1 });
}

/// O painel focado acompanha a aba ativa: trocar de canal pela lista troca
/// o conteúdo dele; ir para um canal que já está noutro painel move o foco.
fn sync(ctx: *d.Ctx) void {
    // Canal que sumiu (CHANNEL_DELETE, saiu do servidor): o painel fecha.
    var i: usize = 0;
    while (i < panes.count) {
        if (ctx.store.channel(panes.ids[i]) != null) i += 1 else panes.remove(i);
    }
    if (panes.count < 2) {
        panes = .{};
        return;
    }
    const active = ctx.st.activeChannel() orelse return;
    if (panes.indexOf(active)) |j| panes.focus = @intCast(j) else panes.ids[panes.focus] = active;
}

const regions = [max][*:0]const u8{ "##messages", "##messages1", "##messages2" };

pub fn draw(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    sync(ctx);
    if (!on()) {
        const ch = ctx.st.activeChannel() orelse return;
        return msgs.history(ctx, n, r, ch, regions[0]);
    }
    const k: f32 = @floatFromInt(panes.count);
    const avail = r.w - gap * (k - 1);
    const s = &ctx.st.settings;
    const widths = layout.paneWidths(avail, panes.count, if (panes.count == 2) s.split_two else s.split_three_a, s.split_three_b, resize.min_pane);
    addHandles(ctx, r, avail, &widths);
    var close_i: ?usize = null;
    var px = r.x;
    for (0..panes.count) |i| {
        const id = panes.ids[i];
        const focused = i == panes.focus;
        const pr: d.Rect = .{ .x = px, .y = r.y, .w = widths[i], .h = r.h };
        px = pr.right() + gap;
        if (i > 0) d.rect(ctx.dl, .{ .x = pr.x - gap, .y = r.y, .w = gap, .h = r.h }, ctx.col(.border), 0);
        qa.mark(pr, "pane:{d}", .{i});
        const cr: d.Rect = .{ .x = pr.right() - 28, .y = pr.y + 4, .w = 22, .h = 22 };
        // Clique (ou botão direito) num painel lateral foca ele antes: a
        // resposta, a edição e a caixa de texto vão para o canal certo.
        if (!focused and ctx.st.popup == .none and ctx.hovering(pr) and !ctx.hovering(cr) and !resize.over(ctx) and
            (c.ImGui_IsMouseClicked(0) or c.ImGui_IsMouseClicked(1)) and
            c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows)) focusPane(ctx, i);
        if (titleBar(ctx, pr, cr, i, id, focused)) close_i = i;
        if (!focused) qa.setScope("pane{d}/", .{i});
        defer qa.setScope("", .{});
        msgs.history(ctx, n, .{ .x = pr.x, .y = pr.y + bar_h, .w = pr.w, .h = pr.h - bar_h }, id, regions[i]);
    }
    if (close_i) |i| close(ctx, i);
}

/// As alças entre os painéis. Sem espaço para o mínimo de cada um, não tem o
/// que ajustar. Cada divisa só empurra os dois painéis vizinhos dela.
fn addHandles(ctx: *d.Ctx, r: d.Rect, avail: f32, widths: *const [3]f32) void {
    const s = &ctx.st.settings;
    if (avail < resize.min_pane * @as(f32, @floatFromInt(panes.count))) return;
    const permille = struct {
        fn f(px: f32, total: f32) i16 {
            return @intFromFloat(@round(px / total * 1000));
        }
    }.f;
    const lo: i16 = @intFromFloat(@ceil(resize.min_pane / avail * 1000));
    const per_px = 1000 / avail;
    const first = permille(widths[0], avail);
    if (panes.count == 2) {
        resize.add(.{ .name = "##resize:pane2", .x = r.x + widths[0] + gap / 2, .y = r.y, .h = r.h, .value = &s.split_two, .shown = first, .default = S.split_two_default, .lo = lo, .hi = 1000 - lo, .per_px = per_px });
        return;
    }
    const second = permille(widths[0] + widths[1], avail);
    resize.add(.{ .name = "##resize:pane3a", .x = r.x + widths[0] + gap / 2, .y = r.y, .h = r.h, .value = &s.split_three_a, .shown = first, .default = S.split_three_a_default, .lo = lo, .hi = second - lo, .per_px = per_px, .peer = &s.split_three_b, .peer_default = S.split_three_b_default });
    resize.add(.{ .name = "##resize:pane3b", .x = r.x + widths[0] + gap + widths[1] + gap / 2, .y = r.y, .h = r.h, .value = &s.split_three_b, .shown = second, .default = S.split_three_b_default, .lo = first + lo, .hi = 1000 - lo, .per_px = per_px, .peer = &s.split_three_a, .peer_default = S.split_three_a_default });
}

/// Título do painel: canal, servidor e o X. Retorna true se pediu para fechar.
fn titleBar(ctx: *d.Ctx, pr: d.Rect, cr: d.Rect, i: usize, id: Id, focused: bool) bool {
    const cs = ctx.store.channel(id) orelse return false;
    const dl = ctx.dl;
    const bar: d.Rect = .{ .x = pr.x, .y = pr.y, .w = pr.w, .h = bar_h };
    d.rect(dl, bar, ctx.col(.sidebar).alpha(if (focused) 0.9 else 0.45), 0);
    if (focused)
        d.rect(dl, .{ .x = bar.x, .y = bar.bottom() - 2, .w = bar.w, .h = 2 }, ctx.col(.accent), 0)
    else
        d.line(dl, bar.x, bar.bottom() - 0.5, bar.right(), bar.bottom() - 0.5, ctx.col(.border), 1);
    // O título do painel lateral é onde o QA clica para focar.
    if (!focused) qa.mark(.{ .x = bar.x, .y = bar.y, .w = bar.w - 34, .h = bar.h }, "pane-focus:{d}", .{i});

    const fam = ctx.ui;
    var buf: [128]u8 = undefined;
    const lbl = std.fmt.bufPrint(&buf, "{s}{s}", .{ sigil(&cs.info), cs.info.name }) catch cs.info.name;
    const room = bar.w - 52;
    const tx = bar.x + 12;
    const nw = d.textClipped(dl, fam.get(.semibold), 14, tx, d.centerY(bar, 14), if (focused) ctx.col(.text) else ctx.col(.muted), lbl, room);
    const g = ctx.store.guild(cs.info.guild);
    if (g != null and room - nw > 40)
        _ = d.textClipped(dl, fam.get(.regular), 12, tx + nw + 8, d.centerY(bar, 12), ctx.col(.faint), g.?.name, room - nw - 8);

    const hb = d.hit(ctx, 7200 + i, cr);
    qa.mark(cr, "pane-close:{d}", .{i});
    const cx = cr.x + 11;
    const cy = cr.y + 11;
    if (hb.hovered) d.circle(dl, cx, cy, 10, ctx.col(.hover).mix(ctx.col(.text), 0.1));
    const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.faint);
    d.line(dl, cx - 4, cy - 4, cx + 4, cy + 4, xc, 1.5);
    d.line(dl, cx + 4, cy - 4, cx - 4, cy + 4, xc, 1.5);
    d.tip(ctx, cr, i18n.tr("Fechar painel", "Close pane"), hb.hovered);
    return hb.clicked;
}
