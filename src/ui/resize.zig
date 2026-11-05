//! Alças de arrastar entre os painéis: a lista de canais, a de membros (e o que
//! entra no lugar dela: o perfil da DM, "ativos agora") e os painéis da tela
//! dividida. O cursor muda e a divisa acende ao passar o mouse; duplo clique
//! volta ao padrão. Parado, não pede quadro nenhum: só anima o acender e apagar.
//!
//! Cada alça é uma região própria, a última do `##root`: fica por cima dos
//! painéis (o clique não vai para a linha embaixo) e por baixo das janelas de
//! verdade (configurações, menus, visualizador).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const layout = @import("../theme/layout.zig");
const S = @import("settings_state.zig");
const dropdown = @import("dropdown.zig");
const search = @import("search.zig");
const plugin_panel = @import("plugin_panel.zig");

/// A conversa nunca fica mais estreita que isto por causa de um painel alargado.
pub const min_chat: f32 = 360;
pub const min_pane: f32 = 220;

/// Quanto cada painel muda em relação ao que o tema pede.
const channels_lo: i16 = -80;
const channels_hi: i16 = 240;
const members_lo: i16 = -70;
const members_hi: i16 = 200;

const hit_w: f32 = 8;

pub const Handle = struct {
    /// Região do ImGui; sem o "##" é a marca do QA ("resize:channels").
    name: [:0]const u8,
    x: f32,
    y: f32,
    h: f32,
    value: *i16,
    /// O que vale na tela agora: a janela estreita pode estar segurando menos
    /// do que está guardado, e o arraste começa daqui.
    shown: i16,
    default: i16,
    lo: i16,
    hi: i16,
    /// Quanto o valor anda por pixel arrastado para a direita.
    per_px: f32,
    /// Outro valor que volta ao padrão no duplo clique.
    peer: ?*i16 = null,
    peer_default: i16 = 0,
};

var queue: [5]Handle = undefined;
var queued: usize = 0;
/// As alças do quadro anterior, para quem desenha antes delas saber do mouse.
var last_rects: [5]d.Rect = undefined;
var last_n: usize = 0;

var dragging = false;
var start_mouse: f32 = 0;
var start_value: i16 = 0;
var start_stored: i16 = 0;
var refocus = false;
/// A alça com o mouse em cima (a dica espera um pouco antes de aparecer).
var hover_on: ?*i16 = null;
var hover_since: i64 = 0;
var tip_y: f32 = 0;

pub fn sizes(s: *const S.Settings) [2]layout.Size {
    return .{
        // Arquivo editado à mão: o layout só vê o que a alça deixaria.
        .{ .name = "channel-list", .delta = @floatFromInt(std.math.clamp(s.width_channels, channels_lo, channels_hi)) },
        .{ .name = "member-list", .delta = @floatFromInt(std.math.clamp(s.width_members, members_lo, members_hi)) },
    };
}

/// O mouse está numa alça (ou arrastando uma)? A conversa não começa a selecionar
/// texto nem acende a linha embaixo.
pub fn over(ctx: *const d.Ctx) bool {
    if (dragging) return true;
    for (last_rects[0..last_n]) |r| if (r.contains(ctx.mouse.x, ctx.mouse.y)) return true;
    return false;
}

pub fn add(h: Handle) void {
    if (queued == queue.len) return;
    queue[queued] = h;
    queued += 1;
}

/// As alças dos painéis do layout resolvido; `shown` é o que valeu na tela.
pub fn addPanels(ctx: *d.Ctx, placed: []const layout.Placed, shown: []const layout.Size) void {
    const main = layout.widthOf(placed, "messages") orelse return;
    qa.mark(.{ .x = 0, .y = 0, .w = main, .h = 1 }, "main-area", .{});
    const room = @max(main - min_chat, 0);
    const s = &ctx.st.settings;
    for (placed) |p| {
        const h = p.handle orelse continue;
        const channels = h.size == 0;
        const now: i16 = @intFromFloat(shown[h.size].delta);
        const lo = if (channels) channels_lo else members_lo;
        const hi = if (channels) channels_hi else members_hi;
        add(.{
            .name = if (channels) "##resize:channels" else "##resize:members",
            .x = h.x,
            .y = p.rect.y,
            .h = p.rect.h,
            .value = if (channels) &s.width_channels else &s.width_members,
            .shown = now,
            .default = 0,
            .lo = lo,
            // Só até onde a conversa ainda fica usável.
            .hi = @min(hi, now +| @as(i16, @intFromFloat(room))),
            .per_px = if (h.side == .right) 1 else -1,
        });
    }
}

/// Desenha as alças pedidas neste quadro.
pub fn submit(ctx: *d.Ctx) void {
    defer queued = 0;
    last_n = 0;
    // Vale o que aconteceu neste quadro: a alça pode sumir no meio de um arraste
    // (troca de tema, janela estreita), e aí ninguém veria o botão ser solto.
    dragging = false;
    // Com algo aberto por cima, o clique é de quem está aberto (ou o fecha).
    const st = ctx.st;
    if (st.popup != .none or st.settings.open or st.viewer != null or st.palette.open or search.open or dropdown.anyOpen() or plugin_panel.floating()) return;
    for (queue[0..queued]) |h| one(ctx, h);
}

fn one(ctx: *d.Ctx, h: Handle) void {
    // Quase toda para dentro do painel da direita: na beira esquerda da divisa fica a
    // barra de rolagem do outro painel, e a alça não pode tomar o clique dela.
    const r: d.Rect = .{ .x = @round(h.x) - 1, .y = h.y, .w = hit_w, .h = h.h };
    last_rects[last_n] = r;
    last_n += 1;
    qa.mark(r, "{s}", .{h.name[2..]});
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    _ = c.ImGui_BeginChild(h.name.ptr, d.v(r.w, @max(r.h, 1)), 0, c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    defer c.ImGui_EndChild();
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    _ = c.ImGui_InvisibleButton("##alca", d.v(r.w, @max(r.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft);
    const hovered = c.ImGui_IsItemHovered(0);
    const active = c.ImGui_IsItemActive();
    if (hovered or active) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeEW);
    if (active) dragging = true;

    if (c.ImGui_IsItemActivated()) {
        start_mouse = ctx.mouse.x;
        start_value = h.shown;
        start_stored = h.value.*;
        // Quem estava digitando volta a digitar quando soltar.
        refocus = ctx.io.*.WantTextInput;
    }
    if (hovered and c.ImGui_IsMouseDoubleClicked(0)) {
        h.value.* = h.default;
        if (h.peer) |p| p.* = h.peer_default;
        start_mouse = ctx.mouse.x;
        start_value = h.default;
        // A divisa já volta neste quadro; o que foi guardado é o padrão.
        start_stored = h.default +% 1;
    } else if (active and ctx.mouse.x != start_mouse) {
        const moved = @as(f32, @floatFromInt(start_value)) + (ctx.mouse.x - start_mouse) * h.per_px;
        h.value.* = @intFromFloat(@round(std.math.clamp(moved, @as(f32, @floatFromInt(h.lo)), @as(f32, @floatFromInt(@max(h.lo, h.hi))))));
    }
    if (c.ImGui_IsItemDeactivated()) {
        if (refocus) ctx.st.focus_input = true;
        if (h.value.* != start_stored) ctx.act(.save_settings);
    }

    const k = anim.to(anim.id("resize", std.hash.Wyhash.hash(0, h.name)), if (active) 1 else if (hovered) 0.75 else 0, 22);
    if (k > 0.3) qa.mark(r, "resize-lit:{s}", .{h.name["##resize:".len..]});
    if (k > 0.02) {
        const dl = c.ImGui_GetWindowDrawList();
        const col = ctx.col(.accent).alpha(k);
        d.rect(dl, .{ .x = r.x, .y = r.y, .w = 2, .h = r.h }, col, 0);
        d.rect(dl, .{ .x = r.x, .y = r.y + r.h / 2 - 16, .w = 6, .h = 32 }, col, 3);
    }

    // A dica só aparece depois de um tempo parado: quem veio arrastar não a vê.
    if (hovered and !active) {
        if (hover_on != h.value) {
            hover_on = h.value;
            hover_since = ctx.now_ms;
            tip_y = ctx.mouse.y;
        }
    } else if (hover_on == h.value) hover_on = null;
    const show_tip = hover_on == h.value and ctx.now_ms - hover_since >= 700;
    if (hover_on == h.value and !show_tip) anim.at(hover_since + 700);
    d.tip(ctx, .{ .x = r.x, .y = tip_y, .w = r.w, .h = 16 }, i18n.tr("Arraste para ajustar. Duplo clique volta ao padrão.", "Drag to resize. Double-click to reset."), show_tip);
}
