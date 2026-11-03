//! Paleta de comandos (Ctrl+K): canais de todos os servidores, servidores,
//! temas e ações, com busca aproximada. Funciona igual em qualquer tema.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const fuzzy = @import("fuzzy.zig");
const icons = @import("icons.zig");
const state = @import("state.zig");
const i18n = @import("i18n.zig");

fn rebuild(ctx: *d.Ctx) void {
    const p = &ctx.st.palette;
    _ = p.arena.reset(.retain_capacity);
    const a = p.arena.allocator();
    p.items.clearRetainingCapacity();
    const q = std.mem.sliceTo(&p.query, 0);
    const gpa = ctx.st.gpa;

    const add = struct {
        fn f(pal: *state.Palette, alloc: std.mem.Allocator, query: []const u8, item: state.PaletteItem) void {
            var it = item;
            it.score = fuzzy.score(query, item.label) orelse return;
            pal.items.append(alloc, it) catch {};
        }
    }.f;

    for (ctx.store.guilds.items) |g| {
        for (ctx.store.channelsOf(g.id)) |id| {
            const cs = ctx.store.channel(id) orelse continue;
            if (cs.info.kind == .category) continue;
            const prefix = if (cs.info.kind == .voice) "🔊 " else "# ";
            const label = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, cs.info.name }) catch continue;
            add(p, gpa, q, .{ .label = label, .hint = g.name, .kind = .channel, .id = id });
        }
        const label = std.fmt.allocPrint(a, "{s}", .{g.name}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = i18n.tr("servidor", "server"), .kind = .guild, .id = g.id });
    }
    for (ctx.theme_names, 0..) |name, i| {
        const label = i18n.allocPrint(a, "tema: {s}", "theme: {s}", .{name}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = if (i == ctx.theme_index) i18n.tr("atual", "current") else i18n.tr("aparência", "appearance"), .kind = .theme, .index = i });
    }
    const actions = [_]struct { label: []const u8, label_en: []const u8, index: usize }{
        .{ .label = "Mutar / desmutar microfone", .label_en = "Mute / unmute microphone", .index = 0 },
        .{ .label = "Ensurdecer / ouvir", .label_en = "Deafen / undeafen", .index = 1 },
        .{ .label = "Sair da call", .label_en = "Leave call", .index = 2 },
        .{ .label = "Próximo tema", .label_en = "Next theme", .index = 3 },
        .{ .label = "Configurações", .label_en = "Settings", .index = 4 },
        .{ .label = "Aparência e temas", .label_en = "Appearance & themes", .index = 5 },
    };
    for (actions) |ac| add(p, gpa, q, .{ .label = i18n.tr(ac.label, ac.label_en), .hint = i18n.tr("ação", "action"), .kind = .action, .index = ac.index });

    std.mem.sort(state.PaletteItem, p.items.items, {}, struct {
        fn lt(_: void, x: state.PaletteItem, y: state.PaletteItem) bool {
            return x.score > y.score;
        }
    }.lt);
    if (p.selected >= p.items.items.len) p.selected = 0;
}

fn choose(ctx: *d.Ctx, item: state.PaletteItem) void {
    switch (item.kind) {
        .channel => {
            const cs = ctx.store.channel(item.id) orelse return;
            if (cs.info.kind == .voice) ctx.act(.{ .toggle_voice = item.id }) else ctx.act(.{ .select_channel = item.id });
        },
        .guild => ctx.act(.{ .select_guild = item.id }),
        .theme => ctx.act(.{ .set_theme = item.index }),
        .action => ctx.act(switch (item.index) {
            0 => .toggle_mute,
            1 => .toggle_deafen,
            2 => .leave_voice,
            3 => .{ .next_theme = 1 },
            else => .open_settings,
        }),
    }
    ctx.act(.close_palette);
}

pub fn draw(ctx: *d.Ctx) void {
    const p = &ctx.st.palette;
    const k = anim.to(anim.id("palette", 0), if (p.open) 1 else 0, 22);
    if (k < 0.01) return;
    const fg = ctx.fg;
    const win = ctx.win;
    d.rect(fg, win, d.Rgba.black.alpha(0.45 * k), 0);

    const pw = @min(620, win.w - 40);
    const ph: f32 = 420;
    const box: d.Rect = .{ .x = win.x + (win.w - pw) / 2, .y = win.y + win.h * 0.16 - (1 - k) * 12, .w = pw, .h = ph };
    const radius = @max(ctx.th.radius + 6, 4);
    d.shadow(fg, box, radius, 24, ctx.col(.shadow).alpha(k));
    d.rect(fg, box, ctx.col(.overlay).mix(ctx.col(.elevated), 0.35).alpha(k), radius);
    d.border(fg, box, ctx.col(.border).alpha(k), radius, 1);
    if (!p.open) return;

    // Campo de busca numa janela própria do ImGui, para receber o teclado.
    const font = ctx.ui.get(.regular);
    const fs: f32 = 17;
    icons.search(fg, box.x + 24, box.y + 28, ctx.col(.muted).u());
    c.ImGui_SetNextWindowPos(d.v(box.x + 42, box.y + 14), 0);
    c.ImGui_SetNextWindowSize(d.v(box.w - 60, 32), 0);
    c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##palette", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove);
    c.ImGui_PushFontFloat(font, fs);
    if (!p.focus) {
        c.ImGui_SetKeyboardFocusHere();
        p.focus = true;
        rebuild(ctx);
    }
    c.ImGui_SetNextItemWidth(box.w - 60);
    if (c.ImGui_InputTextWithHint("##q", i18n.trZ("Ir para canal, servidor, tema ou ação…", "Go to a channel, server, theme or action…").ptr, &p.query, p.query.len, 0)) {
        p.selected = 0;
        rebuild(ctx);
    }
    c.ImGui_PopFont();
    c.ImGui_End();
    d.line(fg, box.x, box.y + 58, box.right(), box.y + 58, ctx.col(.border), 1);

    const n = p.items.items.len;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_DownArrow) and n > 0) p.selected = (p.selected + 1) % n;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow) and n > 0) p.selected = (p.selected + n - 1) % n;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) ctx.act(.close_palette);
    if ((c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter)) and n > 0) choose(ctx, p.items.items[p.selected]);

    // Lista (mostra só a janela de itens perto da seleção).
    const row_h: f32 = 38;
    const visible: usize = @intFromFloat((ph - 70) / row_h);
    const first = if (p.selected >= visible) p.selected + 1 - visible else 0;
    var y = box.y + 64;
    const bold = ctx.ui.get(.medium);
    for (p.items.items[first..@min(n, first + visible)], first..) |item, i| {
        const rr: d.Rect = .{ .x = box.x + 8, .y = y, .w = box.w - 16, .h = row_h - 2 };
        @import("qa.zig").mark(rr, "palette-item:{d}", .{i});
        const sel = i == p.selected;
        if (ctx.hovering(rr)) {
            if (c.ImGui_IsMouseClicked(0)) choose(ctx, item);
            if (ctx.io.*.MouseDelta.x != 0 or ctx.io.*.MouseDelta.y != 0) p.selected = i;
        }
        if (sel) d.rect(fg, rr, ctx.col(.accent).alpha(0.2), ctx.th.radius + 2);
        if (sel) d.rect(fg, .{ .x = rr.x, .y = rr.y + 8, .w = 3, .h = rr.h - 16 }, ctx.col(.accent), 2);
        _ = d.textClipped(fg, bold, 15, rr.x + 16, d.centerY(rr, 15), if (sel) ctx.col(.text) else ctx.col(.text).mix(ctx.col(.muted), 0.3), item.label, rr.w - 180);
        const hw = d.width(font, 13, item.hint);
        _ = d.textClipped(fg, font, 13, rr.right() - 14 - @min(hw, 150), d.centerY(rr, 13), ctx.col(.faint), item.hint, 150);
        y += row_h;
    }
    if (n == 0) d.text(fg, font, 15, box.x + 24, box.y + 80, ctx.col(.faint), i18n.tr("Nada encontrado.", "Nothing found."));
}
