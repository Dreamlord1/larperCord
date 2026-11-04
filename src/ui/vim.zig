//! Navegação estilo vim (Configurações → Atalhos de teclado, desligada por
//! padrão). Com a caixa de texto sem foco:
//!   j/k rola, gg/G vai ao topo/fim, Ctrl+d/u meia página,
//!   J/K próximo/anterior canal, i ou Enter volta para a caixa,
//!   / abre a paleta. Na caixa, Esc sai dela sem desfazer o que foi digitado.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const State = @import("state.zig").State;

/// Altura da lista de mensagens no último quadro (para a meia página).
pub var page_h: f32 = 400;
/// A caixa de texto estava com o foco no último quadro.
pub var composer_active = false;
/// Trocou de canal pelo J/K: o canal novo não puxa o foco para a caixa.
var keep_blur = false;
/// Primeiro `g` do `gg` (ms).
var g_at: i64 = 0;

const line_step: f32 = 64;

/// Esc vai tirar o foco da caixa neste quadro e o texto deve ficar (o
/// ImGui volta ao que tinha quando a caixa ganhou o foco).
pub fn escapeKeepsText(st: *const State) bool {
    return st.settings.vim_keys and composer_active and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape);
}

/// Começo do quadro, antes dos componentes.
pub fn beforeFrame(st: *State) void {
    if (!keep_blur) return;
    keep_blur = false;
    st.focus_input = false;
}

fn pressed(k: c_int) bool {
    return c.ImGui_IsKeyPressed(k);
}

pub fn keys(ctx: *d.Ctx) void {
    const st = ctx.st;
    if (!st.settings.vim_keys) return;
    if (st.palette.open or st.settings.open or st.popup != .none or st.viewer != null) return;
    // Só quando nenhum campo de texto está com o foco.
    const io = ctx.io;
    if (io.*.WantTextInput or c.ImGui_IsAnyItemActive() or io.*.KeyAlt or io.*.KeySuper) return;
    if (io.*.KeyCtrl) {
        if (pressed(c.ImGuiKey_D)) scroll(ctx, page_h / 2);
        if (pressed(c.ImGuiKey_U)) scroll(ctx, -page_h / 2);
        return;
    }
    const shift = io.*.KeyShift;
    if (pressed(c.ImGuiKey_J)) if (shift) nextChannel(ctx, 1) else scroll(ctx, line_step);
    if (pressed(c.ImGuiKey_K)) if (shift) nextChannel(ctx, -1) else scroll(ctx, -line_step);
    if (pressed(c.ImGuiKey_G)) {
        if (shift) {
            edge(ctx, false);
        } else if (ctx.now_ms - g_at < 700) {
            edge(ctx, true);
            g_at = 0;
        } else g_at = ctx.now_ms;
    }
    if (pressed(c.ImGuiKey_I) or (!shift and (pressed(c.ImGuiKey_Enter) or pressed(c.ImGuiKey_KeypadEnter)))) st.focus_input = true;
    if (pressed(c.ImGuiKey_Slash) or pressed(c.ImGuiKey_KeypadDivide)) ctx.act(.open_palette);
}

fn scroll(ctx: *d.Ctx, dy: f32) void {
    const st = ctx.st;
    if (st.friends) return;
    const sc = st.scrollOf(st.activeChannel() orelse return);
    if (sc.pos < 0) return;
    // Colado no fim, o alvo já é o fim; descer não faz nada.
    if (dy > 0 and sc.stick_bottom) return;
    sc.stick_bottom = false;
    sc.target += dy;
}

fn edge(ctx: *d.Ctx, top: bool) void {
    const st = ctx.st;
    if (st.friends) return;
    const sc = st.scrollOf(st.activeChannel() orelse return);
    sc.stick_bottom = !top;
    if (top) sc.target = 0;
}

/// Próximo canal de texto do servidor aberto (dá a volta no fim da lista).
fn nextChannel(ctx: *d.Ctx, delta: i32) void {
    const st = ctx.st;
    const list = ctx.store.channelsOf(st.guild);
    if (list.len == 0) return;
    const cur = st.activeChannel() orelse 0;
    const n: i32 = @intCast(list.len);
    var at: i32 = for (list, 0..) |id, i| {
        if (id == cur) break @intCast(i);
    } else if (delta > 0) -1 else n;
    var tries: i32 = 0;
    while (tries < n) : (tries += 1) {
        at = @mod(at + delta, n);
        const id = list[@intCast(at)];
        const cs = ctx.store.channel(id) orelse continue;
        if (cs.info.kind != .text or id == cur) continue;
        ctx.act(.{ .select_channel = id });
        keep_blur = true;
        return;
    }
}
