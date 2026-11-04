//! Paleta de comandos (Ctrl+K ou Ctrl+Shift+P): canais de todos os
//! servidores, mensagens diretas, servidores, temas, ações (status, marcar
//! como lido, claro/escuro…), páginas das configurações e as opções
//! liga/desliga, com busca aproximada. Funciona igual em qualquer tema.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const fuzzy = @import("fuzzy.zig");
const icons = @import("icons.zig");
const state = @import("state.zig");
const i18n = @import("i18n.zig");
const settings = @import("settings.zig");
const S = @import("settings_state.zig");
const types = @import("../core/types.zig");

/// Ctrl+Shift+P: as ações vêm antes dos canais com a busca vazia.
pub var commands_first = false;

/// Ação da paleta: rótulo nos dois idiomas e o que fazer (sempre pelas
/// ações do app, `ctx.act`, ou pelo mesmo estado que o botão da tela muda).
const Command = struct { pt: []const u8, en: []const u8, run: *const fn (*d.Ctx) void };

fn status(comptime s: types.Status) *const fn (*d.Ctx) void {
    return struct {
        fn f(ctx: *d.Ctx) void {
            ctx.act(.{ .set_status = s });
        }
    }.f;
}

fn colorMode(comptime m: u8) *const fn (*d.Ctx) void {
    return struct {
        fn f(ctx: *d.Ctx) void {
            ctx.act(.{ .set_setting = .{ .index = S.fieldIndex("color_mode"), .value = m } });
        }
    }.f;
}

fn simple(comptime a: @import("../core/event.zig").Action) *const fn (*d.Ctx) void {
    return struct {
        fn f(ctx: *d.Ctx) void {
            ctx.act(a);
        }
    }.f;
}

const commands = [_]Command{
    .{ .pt = "Configurações", .en = "Settings", .run = simple(.open_settings) },
    .{ .pt = "Caixa de entrada (menções e não lidas)", .en = "Inbox (mentions and unreads)", .run = simple(.toggle_inbox) },
    .{ .pt = "Mensagens salvas", .en = "Saved messages", .run = simple(.toggle_saved) },
    .{ .pt = "Status: Online", .en = "Status: Online", .run = status(.online) },
    .{ .pt = "Status: Ausente", .en = "Status: Idle", .run = status(.idle) },
    .{ .pt = "Status: Não perturbe", .en = "Status: Do Not Disturb", .run = status(.dnd) },
    .{ .pt = "Status: Invisível", .en = "Status: Invisible", .run = status(.offline) },
    .{ .pt = "Marcar canal como lido", .en = "Mark channel as read", .run = struct {
        fn f(ctx: *d.Ctx) void {
            if (ctx.st.activeChannel()) |id| ctx.act(.{ .mark_read = id });
        }
    }.f },
    .{ .pt = "Marcar servidor como lido", .en = "Mark server as read", .run = struct {
        fn f(ctx: *d.Ctx) void {
            if (ctx.st.guild != 0) ctx.act(.{ .mark_read = ctx.st.guild });
        }
    }.f },
    .{ .pt = "Marcar tudo como lido", .en = "Mark everything as read", .run = struct {
        fn f(ctx: *d.Ctx) void {
            for (ctx.store.guilds.items) |g| ctx.act(.{ .mark_read = g.id });
            for (ctx.store.channelsOf(0)) |id| ctx.act(.{ .mark_read = id });
        }
    }.f },
    .{ .pt = "Próximo tema", .en = "Next theme", .run = simple(.{ .next_theme = 1 }) },
    .{ .pt = "Tema anterior", .en = "Previous theme", .run = simple(.{ .next_theme = -1 }) },
    .{ .pt = "Modo escuro", .en = "Dark mode", .run = colorMode(0) },
    .{ .pt = "Modo claro", .en = "Light mode", .run = colorMode(1) },
    .{ .pt = "Claro/escuro: seguir o sistema", .en = "Light/dark: follow system", .run = colorMode(2) },
    .{ .pt = "Mensagens diretas", .en = "Direct messages", .run = simple(.{ .select_guild = 0 }) },
    .{ .pt = "Amigos", .en = "Friends", .run = simple(.open_friends) },
    .{ .pt = "Próxima aba", .en = "Next tab", .run = simple(.{ .next_tab = 1 }) },
    .{ .pt = "Aba anterior", .en = "Previous tab", .run = simple(.{ .next_tab = -1 }) },
    .{ .pt = "Fechar aba", .en = "Close tab", .run = struct {
        fn f(ctx: *d.Ctx) void {
            ctx.act(.{ .close_tab = ctx.st.tab });
        }
    }.f },
    .{ .pt = "Ir para o fim da conversa", .en = "Jump to present", .run = struct {
        fn f(ctx: *d.Ctx) void {
            if (ctx.st.activeChannel()) |id| ctx.act(.{ .jump_present = id });
        }
    }.f },
    .{ .pt = "Mensagens fixadas", .en = "Pinned messages", .run = struct {
        fn f(ctx: *d.Ctx) void {
            if (ctx.st.activeChannel()) |id| ctx.act(.{ .open_pins = id });
        }
    }.f },
    .{ .pt = "Anexar arquivo", .en = "Attach file", .run = simple(.pick_files) },
    .{ .pt = "Mutar / desmutar microfone", .en = "Mute / unmute microphone", .run = simple(.toggle_mute) },
    .{ .pt = "Ensurdecer / ouvir", .en = "Deafen / undeafen", .run = simple(.toggle_deafen) },
    .{ .pt = "Sair da call", .en = "Leave call", .run = simple(.leave_voice) },
};

/// Nomes das opções liga/desliga (os mesmos da tela de configurações).
/// Uma opção nova que não esteja aqui aparece pelo nome do campo.
const toggle_names = [_]struct { field: []const u8, pt: []const u8, en: []const u8 }{
    .{ .field = "compact", .pt = "Modo compacto", .en = "Compact mode" },
    .{ .field = "show_avatars", .pt = "Mostrar avatares", .en = "Show avatars" },
    .{ .field = "clock_24h", .pt = "Relógio de 24 horas", .en = "24-hour clock" },
    .{ .field = "status_ring", .pt = "Status em anel", .en = "Status ring" },
    .{ .field = "show_member_list", .pt = "Lista de membros", .en = "Member list" },
    .{ .field = "show_status_bar", .pt = "Barra de status", .en = "Status bar" },
    .{ .field = "reduce_motion", .pt = "Reduzir movimento", .en = "Reduce motion" },
    .{ .field = "role_colors", .pt = "Cores dos cargos", .en = "Role colors" },
    .{ .field = "underline_links", .pt = "Sublinhar links", .en = "Underline links" },
    .{ .field = "autoplay_gifs", .pt = "Reproduzir GIFs automaticamente", .en = "Automatically play GIFs" },
    .{ .field = "show_embeds", .pt = "Mostrar imagens de links", .en = "Show images from links" },
    .{ .field = "show_spoilers", .pt = "Sempre mostrar spoilers", .en = "Always show spoilers" },
    .{ .field = "md_preview", .pt = "Prévia do markdown", .en = "Markdown preview" },
    .{ .field = "open_at_unread", .pt = "Abrir na primeira não lida", .en = "Open at the first unread" },
    .{ .field = "send_typing", .pt = "Enviar indicador de digitação", .en = "Send typing indicator" },
    .{ .field = "message_log", .pt = "Registro de mensagens", .en = "Message log" },
    .{ .field = "gif_hosts", .pt = "Animar GIFs do Tenor e do Giphy", .en = "Animate Tenor and Giphy GIFs" },
    .{ .field = "streamer_mode", .pt = "Modo streamer", .en = "Streamer Mode" },
    .{ .field = "desktop_notifs", .pt = "Notificações na área de trabalho", .en = "Desktop notifications" },
    .{ .field = "taskbar_flash", .pt = "Piscar na barra de tarefas", .en = "Flash taskbar" },
    .{ .field = "vim_keys", .pt = "Navegação estilo vim", .en = "Vim-style navigation" },
    .{ .field = "developer_mode", .pt = "Modo desenvolvedor", .en = "Developer Mode" },
    .{ .field = "hot_reload", .pt = "Recarregar temas ao salvar", .en = "Reload themes on save" },
};

fn toggleName(field: []const u8) ?[]const u8 {
    inline for (toggle_names) |t| {
        // Erro de compilação se o campo sumir das configurações.
        _ = comptime S.fieldIndex(t.field);
        if (std.mem.eql(u8, t.field, field)) return i18n.tr(t.pt, t.en);
    }
    return null;
}

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
            // Ctrl+Shift+P com a busca vazia: ações e opções primeiro.
            if (commands_first and query.len == 0 and (item.kind == .action or item.kind == .setting or item.kind == .page)) it.score += 1;
            pal.items.append(alloc, it) catch {};
        }
    }.f;

    for (ctx.store.guilds.items) |g| {
        for (ctx.store.channelsOf(g.id)) |id| {
            const cs = ctx.store.channel(id) orelse continue;
            if (cs.info.kind == .category) continue;
            const prefix = if (cs.info.kind == .voice) "🔊 " else "# ";
            const label = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, cs.info.name }) catch continue;
            // Cópia: a paleta fica aberta e o nome do servidor pode mudar (READY).
            add(p, gpa, q, .{ .label = label, .hint = a.dupe(u8, g.name) catch continue, .kind = .channel, .id = id });
            // As threads ativas, que não estão na lista do servidor.
            for (ctx.store.threadsOf(id)) |tid| {
                const ts = ctx.store.channel(tid) orelse continue;
                if (ts.info.thread == null or ts.info.thread.?.archived) continue;
                const tl = std.fmt.allocPrint(a, "↳ {s}", .{ts.info.name}) catch continue;
                const hint = std.fmt.allocPrint(a, "{s} · {s}", .{ g.name, cs.info.name }) catch continue;
                add(p, gpa, q, .{ .label = tl, .hint = hint, .kind = .channel, .id = tid });
            }
        }
        const label = std.fmt.allocPrint(a, "{s}", .{g.name}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = i18n.tr("servidor", "server"), .kind = .guild, .id = g.id });
    }
    // Mensagens diretas e grupos.
    for (ctx.store.channelsOf(0)) |id| {
        const cs = ctx.store.channel(id) orelse continue;
        if (cs.info.kind != .text) continue;
        const label = std.fmt.allocPrint(a, "@ {s}", .{cs.info.name}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = if (cs.info.group) i18n.tr("grupo", "group") else i18n.tr("mensagem direta", "direct message"), .kind = .channel, .id = id });
    }
    for (ctx.theme_names, 0..) |name, i| {
        const label = i18n.allocPrint(a, "tema: {s}", "theme: {s}", .{name}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = if (i == ctx.theme_index) i18n.tr("atual", "current") else i18n.tr("aparência", "appearance"), .kind = .theme, .index = i });
    }
    for (commands, 0..) |cmd, i| add(p, gpa, q, .{ .label = i18n.tr(cmd.pt, cmd.en), .hint = i18n.tr("ação", "action"), .kind = .action, .index = i });
    // Páginas das configurações.
    for (settings.sections) |sec| for (sec.items) |it| {
        const label = i18n.allocPrint(a, "Configurações: {s}", "Settings: {s}", .{i18n.tr(it.label, it.label_en)}) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = i18n.tr("configurações", "settings"), .kind = .page, .index = @intFromEnum(it.page) });
    };
    // Opções liga/desliga: o rótulo diz o que vai acontecer.
    for (S.fields(), 0..) |f, i| {
        if (f.kind != .boolean) continue;
        const on = (S.getByte(&ctx.st.settings, i) orelse continue) != 0;
        const name = toggleName(f.name) orelse f.name;
        const label = (if (on) i18n.allocPrint(a, "Desligar: {s}", "Turn off: {s}", .{name}) else i18n.allocPrint(a, "Ligar: {s}", "Turn on: {s}", .{name})) catch continue;
        add(p, gpa, q, .{ .label = label, .hint = if (on) i18n.tr("ligado agora", "on now") else i18n.tr("desligado agora", "off now"), .kind = .setting, .index = i });
    }

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
        .action => if (item.index < commands.len) commands[item.index].run(ctx),
        .page => {
            // Abrir as configurações já fecha a paleta.
            ctx.st.settings.page = @enumFromInt(item.index);
            return ctx.act(.open_settings);
        },
        .setting => if (S.getByte(&ctx.st.settings, item.index)) |cur| {
            const on = cur == 0;
            ctx.act(.{ .set_setting = .{ .index = item.index, .value = @intFromBool(on) } });
            const name = toggleName(S.fields()[item.index].name) orelse S.fields()[item.index].name;
            if (on) ctx.st.showToast(ctx.now_ms, false, "{s}: ligado", "{s}: on", .{name}) else ctx.st.showToast(ctx.now_ms, false, "{s}: desligado", "{s}: off", .{name});
        },
    }
    ctx.act(.close_palette);
}

pub fn draw(ctx: *d.Ctx) void {
    const p = &ctx.st.palette;
    if (!p.open) commands_first = false;
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
    if (c.ImGui_InputTextWithHint("##q", i18n.trZ("Ir para canal, servidor, DM, tema, ação ou opção…", "Go to a channel, server, DM, theme, action or option…").ptr, &p.query, p.query.len, 0)) {
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
