//! Monta o quadro: resolve o layout do tema, desenha os estilos dos nós,
//! chama cada componente pelo nome e cuida das sobreposições (paleta, aviso)
//! e dos atalhos de teclado.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const layout = @import("../theme/layout.zig");
const theme_mod = @import("../theme/theme.zig");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const rail = @import("comp_rail.zig");
const channels = @import("comp_channels.zig");
const chat = @import("comp_chat.zig");
const side = @import("comp_side.zig");
const palette = @import("palette.zig");
const settings = @import("settings.zig");
const Preview = @import("../theme/manager.zig").Preview;

const Component = *const fn (*d.Ctx, *const kdl.Node, d.Rect) void;

const registry = std.StaticStringMap(Component).initComptime(.{
    .{ "guild-bar", rail.draw },
    .{ "channel-list", channels.channelList },
    .{ "user-panel", channels.userPanel },
    .{ "header", chat.header },
    .{ "tabs", chat.tabs },
    .{ "messages", chat.messages },
    .{ "composer", chat.composer },
    .{ "member-list", side.memberList },
    .{ "status-bar", side.statusBar },
    .{ "label", label },
    .{ "spacer", spacer },
});

pub fn componentNames() []const []const u8 {
    return registry.keys();
}

fn spacer(_: *d.Ctx, _: *const kdl.Node, _: d.Rect) void {}

/// `label text="larperCord" size=14 weight=bold color=accent align=center`
fn label(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    const t = d.pstr(n, "text", "");
    const fam = ctx.familyFor(n);
    const weight = std.meta.stringToEnum(d.Weight, d.pstr(n, "weight", "semibold")) orelse .semibold;
    const font = fam.get(weight);
    const size = d.pnum(n, "size", 14);
    const color = if (theme_mod.tokenFromName(d.pstr(n, "color", "muted"))) |tok| ctx.col(tok) else ctx.col(.muted);
    const tw = d.width(font, size, t);
    const x = if (d.is(n, "align", "center", "left")) r.x + (r.w - tw) / 2 else if (d.is(n, "align", "right", "left")) r.right() - tw - 10 else r.x + 10;
    d.text(ctx.dl, font, size, x, d.centerY(r, size), color, t);
}

fn hidden(ctx: *d.Ctx, name: []const u8) bool {
    const s = &ctx.st.settings;
    if (!s.show_member_list and std.mem.eql(u8, name, "member-list")) return true;
    if (!s.show_status_bar and std.mem.eql(u8, name, "status-bar")) return true;
    return false;
}

pub fn frame(ctx: *d.Ctx, placed: *std.ArrayList(layout.Placed), previews: []const Preview) void {
    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    _ = c.ImGui_Begin("##root", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    ctx.dl = c.ImGui_GetWindowDrawList();
    ctx.fg = c.ImGui_GetForegroundDrawList();
    ctx.win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y };

    if (ctx.th.layout) |root| {
        layout.solve(ctx.st.gpa, root, ctx.win, ctx.win.w, placed) catch {};
        for (placed.items, 0..) |p, i| {
            // Fundo rápido pelo próprio nó: bg=sidebar radius=12
            if (p.node.str("bg")) |bg| if (theme_mod.tokenFromName(bg)) |tok|
                d.rect(ctx.dl, p.rect, ctx.col(tok), d.pnum(p.node, "radius", 0));
            if (ctx.th.style(p.node.str("style"))) |st| d.drawStyle(ctx, ctx.dl, st, p.rect, i);
            if (p.kind != .component or hidden(ctx, p.node.name)) continue;
            c.ImGui_PushIDPtr(p.node);
            defer c.ImGui_PopID();
            const inner = p.rect.inset(d.pnum(p.node, "inset-x", 0), d.pnum(p.node, "inset-y", 0));
            if (registry.get(p.node.name)) |draw| {
                if (inner.w > 4 and inner.h > 4) draw(ctx, p.node, inner);
            } else unknown(ctx, p);
        }
    }
    c.ImGui_End();

    settings.draw(ctx, previews);
    palette.draw(ctx);
    toast(ctx);
    shortcuts(ctx);
}

fn unknown(ctx: *d.Ctx, p: layout.Placed) void {
    // Ajuda quem está escrevendo um tema: mostra o nome que não existe.
    d.border(ctx.dl, p.rect, ctx.col(.danger), 4, 2);
    var buf: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "componente desconhecido: {s} (linha {d})", .{ p.node.name, p.node.line }) catch "";
    d.text(ctx.dl, ctx.ui.get(.semibold), 13, p.rect.x + 8, p.rect.y + 6, ctx.col(.danger), t);
}

fn toast(ctx: *d.Ctx) void {
    const t = &ctx.st.toast;
    const k = anim.to(anim.id("toast", 0), if (ctx.now_ms < t.until_ms) 1 else 0, 14);
    if (ctx.now_ms < t.until_ms) anim.active = true;
    if (k < 0.01) return;
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 14;
    const tw = d.width(font, fs, t.text());
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - tw - 36) / 2, .y = ctx.win.y + 14 - (1 - k) * 10, .w = tw + 36, .h = 34 };
    d.shadow(ctx.fg, r, 17, 12, ctx.col(.shadow).alpha(k));
    d.rect(ctx.fg, r, (if (t.is_error) ctx.col(.danger) else ctx.col(.overlay)).alpha(k), 17);
    if (!t.is_error) d.border(ctx.fg, r, ctx.col(.accent).alpha(0.6 * k), 17, 1);
    d.text(ctx.fg, font, fs, r.x + 18, d.centerY(r, fs), (if (t.is_error) d.Rgba.white else ctx.col(.text)).alpha(k), t.text());
}

fn shortcuts(ctx: *d.Ctx) void {
    const io = ctx.io;
    const ctrl = io.*.KeyCtrl;
    const shift = io.*.KeyShift;
    if (ctrl and c.ImGui_IsKeyPressed(c.ImGuiKey_Comma)) ctx.act(if (ctx.st.settings.open) .close_settings else .open_settings);
    if (ctrl and c.ImGui_IsKeyPressed(c.ImGuiKey_K)) ctx.act(if (ctx.st.palette.open) .close_palette else .open_palette);
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_F2) or (ctrl and c.ImGui_IsKeyPressed(c.ImGuiKey_T)))
        ctx.act(.{ .next_theme = if (shift) -1 else 1 });
    if (ctrl and c.ImGui_IsKeyPressed(c.ImGuiKey_Tab)) ctx.act(.{ .next_tab = if (shift) -1 else 1 });
    if (ctrl and c.ImGui_IsKeyPressed(c.ImGuiKey_W)) ctx.act(.{ .close_tab = ctx.st.tab });
    if (io.*.KeyAlt) {
        const keys = [_]c_int{ c.ImGuiKey_1, c.ImGuiKey_2, c.ImGuiKey_3, c.ImGuiKey_4, c.ImGuiKey_5, c.ImGuiKey_6, c.ImGuiKey_7, c.ImGuiKey_8, c.ImGuiKey_9 };
        for (keys, 0..) |k, i| if (c.ImGui_IsKeyPressed(k)) ctx.act(.{ .focus_tab = i });
    }
}
