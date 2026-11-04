//! Popups: menus de contexto (botão direito), cartão de perfil e seletor de
//! emoji. Um "fundo" invisível cobre a janela: clicar fora fecha o popup sem
//! clicar no que está embaixo.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const state = @import("state.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");
const Id = types.Id;
const rich = @import("rich.zig");
const att = @import("attachments.zig");
const profile = @import("profile.zig");
const icons = @import("icons.zig");
const saved_ui = @import("saved.zig");
const mosaic = @import("mosaic.zig");
const guild_color = @import("guild_color.zig");
const accounts_menu = @import("accounts_menu.zig");

pub const emojis = [_][]const u8{
    "😂", "😭", "💀", "🔥", "❤️", "👍", "👎", "👀", "🎉", "😍", "🙏", "😎",
    "🤔", "😅", "🥲", "😤", "😴", "🤯", "🫠", "🥺", "😈", "🤡", "👻", "🐧",
    "☕", "🍕", "🎮", "💻", "⚡", "✨", "🌸", "🌙", "🚀", "🦀", "🦎", "🐸",
    "✅", "❌", "⭐", "💯", "📌", "🔔", "🎵", "📷", "🧠", "💤", "🫡", "🤝",
};

const quick = [_][]const u8{ "👍", "😂", "😭", "🔥" };


pub fn close(ctx: *d.Ctx) void {
    if (@import("qa.zig").enabled and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[popup] fechou\n", .{});
    ctx.st.popup = .none;
    ctx.st.focus_input = true;
    ctx.st.role_picker = false;
    ctx.st.note_editing = false;
}

/// Popup que estava aberto no quadro anterior. Só damos foco quando ele
/// aparece: focar outra janela a cada quadro cancelaria o clique em andamento
/// (o botão ficava "apertado" mas o clique nunca completava).
var shown_key: u64 = 0;
pub var appearing = false;

fn popupKey(p: state.Popup) u64 {
    return switch (p) {
        .none => 0,
        .menu => |m| 1 +% m.id *% 31 +% @intFromEnum(m.kind),
        .profile => |pr| 2 +% pr.user *% 31,
        .profile_full => |pr| 4 +% pr.user *% 31,
        .emoji => |e| 3 +% e.target *% 31,
        .inbox => 4,
        .saved => 5,
    };
}

/// Janela do ImGui para o popup (recebe o mouse antes do resto).
pub fn beginWindow(id: [*:0]const u8, r: d.Rect) *c.ImDrawList {
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin(id, null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    return c.ImGui_GetWindowDrawList();
}

/// Mantém o retângulo dentro da janela.
pub fn fit(ctx: *const d.Ctx, x: f32, y: f32, wd: f32, h: f32) d.Rect {
    return .{
        .x = std.math.clamp(x, ctx.win.x + 8, ctx.win.right() - wd - 8),
        .y = std.math.clamp(y, ctx.win.y + 8, ctx.win.bottom() - h - 8),
        .w = wd,
        .h = h,
    };
}

pub fn draw(ctx: *d.Ctx) void {
    const k = popupKey(ctx.st.popup);
    appearing = k != shown_key;
    shown_key = k;
    if (ctx.st.popup == .none) return;
    // Fundo que captura cliques fora.
    c.ImGui_SetNextWindowPos(d.v(ctx.win.x, ctx.win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(ctx.win.w, ctx.win.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##popup-backdrop", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove);
    c.ImGui_SetCursorScreenPos(d.v(ctx.win.x, ctx.win.y));
    _ = c.ImGui_InvisibleButton("##bd", d.v(ctx.win.w, ctx.win.h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
    const outside = c.ImGui_IsItemClickedEx(0) or c.ImGui_IsItemClickedEx(1);
    c.ImGui_End();
    if (@import("qa.zig").enabled and c.SDL_getenv("QA_DEBUG") != null and (outside or appearing)) std.debug.print("[popup] appearing={} outside={} mouse={d:.0},{d:.0}\n", .{ appearing, outside, ctx.mouse.x, ctx.mouse.y });
    // Esc com uma anotação aberta só cancela a edição (ui/saved.zig).
    const editing_note = ctx.st.popup == .saved and saved_ui.isEditing();
    if (outside or (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !editing_note)) return close(ctx);

    const saved = ctx.dl;
    defer ctx.dl = saved;
    switch (ctx.st.popup) {
        .menu => |m| menu(ctx, m.kind, m.id, m.x, m.y),
        .profile => |p| profile.card(ctx, p.user, p.x, p.y),
        .profile_full => |p| profile.full(ctx, p.user),
        .emoji => |e| emojiPicker(ctx, e.target, e.x, e.y),
        .inbox => |ib| @import("inbox.zig").draw(ctx, ib.tab),
        .saved => saved_ui.draw(ctx),
        .none => {},
    }
}

// --- Menu de contexto -------------------------------------------------------

/// `label` (português) também é a marca do QA; `en` é o texto em inglês.
const Item = struct { label: []const u8, en: []const u8, id: u8, danger: bool = false, sep: bool = false };

/// Canal de voz em que a pessoa está, se dá para movê-la de lá (é do
/// servidor aberto e temos "Mover membros").
fn movable(ctx: *d.Ctx, uid: Id) ?*const @import("../core/store.zig").ChannelState {
    const ch = ctx.store.voiceChannelOf(uid, ctx.st.guild);
    if (ch == 0) return null;
    const cs = ctx.store.channel(ch) orelse return null;
    if (!ctx.store.can(cs.info.guild, types.perm.move_members)) return null;
    return cs;
}

/// Para onde dá para mover: os outros canais de voz do mesmo servidor.
fn voiceTargets(ctx: *d.Ctx, uid: Id, buf: []Id) []Id {
    const cs = movable(ctx, uid) orelse return buf[0..0];
    var n: usize = 0;
    for (ctx.store.channelsOf(cs.info.guild)) |ch| {
        const other = ctx.store.channel(ch) orelse continue;
        if (other.info.kind != .voice or ch == cs.info.id or n == buf.len) continue;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

fn menu(ctx: *d.Ctx, kind: state.MenuKind, id: Id, x: f32, y: f32) void {
    var items: [24]Item = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: *[24]Item, count: *usize, it: Item) void {
            if (count.* < list.len) {
                list[count.*] = it;
                count.* += 1;
            }
        }
    }.f;
    const dev = ctx.st.settings.developer_mode;
    var own = false;
    switch (kind) {
        .message => {
            const found = ctx.store.findAny(id) orelse return close(ctx);
            own = found.m.msg.author == ctx.store.me and found.m.msg.id != 0;
            add(&items, &n, .{ .label = "Responder", .en = "Reply", .id = 1 });
            if (own) add(&items, &n, .{ .label = "Editar mensagem", .en = "Edit Message", .id = 2 });
            add(&items, &n, .{ .label = "Adicionar reação", .en = "Add Reaction", .id = 3 });
            add(&items, &n, .{ .label = if (ctx.st.selection.empty()) "Copiar texto" else "Copiar seleção", .en = if (ctx.st.selection.empty()) "Copy Text" else "Copy Selection", .id = 4 });
            add(&items, &n, .{ .label = "Copiar link da mensagem", .en = "Copy Message Link", .id = 5 });
            // Salvas: só neste computador (ui/saved.zig).
            if (found.m.msg.id != 0) {
                if (ctx.st.saved.find(id) != null)
                    add(&items, &n, .{ .label = "Remover dos salvos", .en = "Remove from Saved", .id = 10 })
                else
                    add(&items, &n, .{ .label = "Salvar mensagem", .en = "Save Message", .id = 10 });
            }
            add(&items, &n, .{ .label = "Marcar como não lida", .en = "Mark Unread", .id = 7 });
            if (dev) add(&items, &n, .{ .label = "Copiar ID da mensagem", .en = "Copy Message ID", .id = 8 });
            // Dos outros também, para quem pode gerenciar mensagens no servidor.
            const mod = found.m.msg.id != 0 and ctx.store.can(found.cs.info.guild, types.perm.manage_messages);
            if (own or mod) add(&items, &n, .{ .label = "Excluir mensagem", .en = "Delete Message", .id = 9, .danger = true, .sep = true });
        },
        .user => {
            add(&items, &n, .{ .label = "Perfil", .en = "Profile", .id = 20 });
            add(&items, &n, .{ .label = "Mencionar", .en = "Mention", .id = 21 });
            if (id != ctx.store.me) add(&items, &n, .{ .label = "Mensagem", .en = "Message", .id = 22 });
            // Ignorar não bloqueia: as mensagens só ficam recolhidas aqui.
            if (id != ctx.store.me) add(&items, &n, if (ctx.st.filtros.isIgnored(id))
                .{ .label = "Deixar de ignorar", .en = "Unignore", .id = 26 }
            else
                .{ .label = "Ignorar", .en = "Ignore", .id = 26 });
            add(&items, &n, .{ .label = "Copiar nome de usuário", .en = "Copy Username", .id = 24, .sep = true });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do usuário", .en = "Copy User ID", .id = 25 });
            if (movable(ctx, id) != null) {
                var tb: [24]Id = undefined;
                if (voiceTargets(ctx, id, &tb).len > 0) add(&items, &n, .{ .label = "Mover para…", .en = "Move To…", .id = 28, .sep = true });
                add(&items, &n, .{ .label = "Desconectar da call", .en = "Disconnect", .id = 29, .danger = true, .sep = voiceTargets(ctx, id, &tb).len == 0 });
            }
        },
        .channel => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 40 });
            add(&items, &n, .{ .label = "Abrir em nova aba", .en = "Open in New Tab", .id = 41 });
            // Tela dividida: o canal ao lado do que está aberto (até 3).
            if (mosaic.canOpenBeside(ctx, id)) add(&items, &n, .{ .label = "Abrir ao lado", .en = "Open to the Side", .id = 45 });
            add(&items, &n, .{ .label = if (ctx.st.muted_channels.contains(id)) "Reativar notificações" else "Silenciar canal", .en = if (ctx.st.muted_channels.contains(id)) "Unmute Channel" else "Mute Channel", .id = 42 });
            add(&items, &n, .{ .label = "Copiar link", .en = "Copy Link", .id = 43, .sep = true });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do canal", .en = "Copy Channel ID", .id = 44 });
        },
        .status => {
            add(&items, &n, .{ .label = "●  Online", .en = "●  Online", .id = 80 });
            add(&items, &n, .{ .label = "◐  Ausente", .en = "◐  Idle", .id = 81 });
            add(&items, &n, .{ .label = "⊘  Não perturbe", .en = "⊘  Do Not Disturb", .id = 82 });
            add(&items, &n, .{ .label = "○  Invisível", .en = "○  Invisible", .id = 83 });
            if (ctx.st.filtros.focusOn(ctx.now_ms)) {
                add(&items, &n, .{ .label = "Sair do modo foco", .en = "End Focus Mode", .id = 85, .sep = true });
            } else {
                add(&items, &n, .{ .label = "Modo foco: 15 min", .en = "Focus mode: 15 min", .id = 86, .sep = true });
                add(&items, &n, .{ .label = "Modo foco: 30 min", .en = "Focus mode: 30 min", .id = 87 });
                add(&items, &n, .{ .label = "Modo foco: 1 h", .en = "Focus mode: 1 h", .id = 88 });
                add(&items, &n, .{ .label = "Modo foco: até desligar", .en = "Focus mode: until I turn it off", .id = 89 });
            }
            add(&items, &n, if (ctx.st.settings.data_saver)
                .{ .label = "Desligar modo economia", .en = "Turn Off Data Saver", .id = 90 }
            else
                .{ .label = "Ligar modo economia", .en = "Turn On Data Saver", .id = 90 });
            add(&items, &n, .{ .label = "Ver perfil", .en = "View Profile", .id = 84, .sep = true });
        },
        .voice_move => {
            var tb: [20]Id = undefined;
            for (voiceTargets(ctx, id, &tb), 0..) |ch, i| {
                const name = ctx.store.channel(ch).?.info.name;
                add(&items, &n, .{ .label = name, .en = name, .id = @intCast(100 + i) });
            }
            if (n == 0) return close(ctx);
        },
        .guild => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 60 });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do servidor", .en = "Copy Server ID", .id = 63 });
        },
    }

    const row_h: f32 = 32;
    const quick_h: f32 = if (kind == .message) 46 else 0;
    // "Cor do servidor": uma fileira de cores no fim do menu do servidor.
    const colors_h: f32 = if (kind == .guild and ctx.store.guild(id) != null) 62 else 0;
    var seps: f32 = 0;
    for (items[0..n]) |it| {
        if (it.sep) seps += 9;
    }
    const mw: f32 = 220;
    // Menu do usuário: as contas embaixo (o menu cresce para cima).
    const acc_h: f32 = if (kind == .status) accounts_menu.height(ctx) else 0;
    const mh = quick_h + @as(f32, @floatFromInt(n)) * row_h + seps + colors_h + 12 + acc_h;
    const r = fit(ctx, x + 2, y + 2 - acc_h, mw, mh);
    const k = anim.to(anim.id("menu", @intFromEnum(kind)), 1, 30);
    const dl = beginWindow("##menu", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius, 4);
    d.shadow(dl, r, radius, 14, ctx.col(.shadow).alpha(k));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);

    var yy = r.y + 6;
    const fam = ctx.ui;
    if (kind == .message) {
        // Reações rápidas, como no Discord.
        for (quick, 0..) |e, i| {
            const er: d.Rect = .{ .x = r.x + 8 + @as(f32, @floatFromInt(i)) * 42, .y = yy, .w = 38, .h = 36 };
            const hb = d.hit(ctx, 200 + i, er);
            qa.mark(er, "menu-react:{d}", .{i});
            if (hb.hovered) d.circle(dl, er.x + 19, er.y + 18, 18, ctx.col(.hover).mix(ctx.col(.text), 0.06));
            const es: f32 = if (hb.hovered) 23 else 20;
            d.text(dl, fam.get(.regular), es, er.x + 19 - es / 2, er.y + 18 - es * 0.6, d.Rgba.white, e);
            if (hb.clicked) {
                ctx.act(.{ .react = .{ .id = id, .emoji = types.Reaction.init(e) } });
                return close(ctx);
            }
        }
        yy += quick_h;
    }
    for (items[0..n], 0..) |it, i| {
        if (it.sep) {
            d.line(dl, r.x + 10, yy + 4, r.right() - 10, yy + 4, ctx.col(.border), 1);
            yy += 9;
        }
        const ir: d.Rect = .{ .x = r.x + 6, .y = yy, .w = r.w - 12, .h = row_h - 2 };
        const hb = d.hit(ctx, i, ir);
        qa.mark(ir, "menu:{s}", .{it.label});
        const base = if (it.danger) ctx.col(.danger) else ctx.col(.accent);
        if (hb.hovered) d.rect(dl, ir, base, @max(ctx.th.radius - 2, 2));
        const tc = if (hb.hovered) (if (it.danger) d.Rgba.white else ctx.col(.accent_text)) else if (it.danger) ctx.col(.danger) else ctx.col(.text).mix(ctx.col(.muted), 0.15);
        d.text(dl, fam.get(.medium), 14, ir.x + 10, d.centerY(ir, 14), tc, i18n.tr(it.label, it.en));
        if (hb.clicked) return choose(ctx, kind, id, it.id, r);
        yy += row_h;
    }
    if (colors_h > 0) guildColors(ctx, dl, id, r, yy);
    if (kind == .status and accounts_menu.draw(ctx, dl, r, yy)) close(ctx);
}

/// Fileira "Cor do servidor": a primeira bolinha volta para a cor de sempre,
/// as outras são a paleta de destaque das configurações.
fn guildColors(ctx: *d.Ctx, dl: *c.ImDrawList, guild: Id, r: d.Rect, y: f32) void {
    const palette = &@import("../app.zig").App.accents;
    const fam = ctx.ui;
    d.line(dl, r.x + 10, y + 4, r.right() - 10, y + 4, ctx.col(.border), 1);
    d.text(dl, fam.get(.semibold), 12, r.x + 16, y + 12, ctx.col(.muted), i18n.tr("Cor do servidor", "Server Color"));
    const cur = guild_color.get(guild);
    const step = (r.w - 24) / @as(f32, @floatFromInt(palette.len + 1));
    for (0..palette.len + 1) |i| {
        const cx = r.x + 12 + step * (@as(f32, @floatFromInt(i)) + 0.5);
        const cy = y + 44;
        const sr: d.Rect = .{ .x = cx - step / 2, .y = cy - 11, .w = step, .h = 22 };
        const hb = d.hit(ctx, 300 + i, sr);
        qa.mark(sr, "guild-color:{d}", .{i});
        const sel = if (i == 0) cur == null else cur == palette[i - 1];
        if (sel or hb.hovered) c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 10.5, (if (sel) ctx.col(.text) else ctx.col(.muted)).u(), 0, 1.5, 0);
        if (i == 0) {
            // Sem cor própria: anel com um risco.
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 7, ctx.col(.faint).u(), 0, 1.5, 0);
            d.line(dl, cx - 4.5, cy + 4.5, cx + 4.5, cy - 4.5, ctx.col(.faint), 1.5);
            d.tip(ctx, sr, i18n.tr("Cor de sempre", "Default color"), hb.hovered);
        } else d.circle(dl, cx, cy, 7.5, d.Rgba.hex(palette[i - 1]));
        if (hb.clicked) {
            ctx.act(.{ .set_guild_color = .{ .guild = guild, .rgb = if (i == 0) null else palette[i - 1] } });
            return close(ctx);
        }
    }
}

fn copyFmt(ctx: *d.Ctx, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(ctx.st.gpa, fmt, args) catch return;
    ctx.act(.{ .copy = s });
}

/// Links de DM usam "@me" no lugar do servidor.
fn guildPart(buf: []u8, guild: Id) []const u8 {
    return if (guild == 0) "@me" else std.fmt.bufPrint(buf, "{d}", .{guild}) catch "@me";
}

fn choose(ctx: *d.Ctx, kind: state.MenuKind, id: Id, item: u8, r: d.Rect) void {
    const st = ctx.st;
    close(ctx);
    if (kind == .voice_move and item >= 100) {
        var tb: [20]Id = undefined;
        const list = voiceTargets(ctx, id, &tb);
        const cs = movable(ctx, id) orelse return;
        if (item - 100 < list.len) ctx.act(.{ .move_member = .{ .guild = cs.info.guild, .user = id, .channel = list[item - 100] } });
        return;
    }
    switch (item) {
        1 => ctx.act(.{ .reply = id }),
        2 => ctx.act(.{ .edit_message = id }),
        3 => st.popup = .{ .emoji = .{ .target = id, .x = r.x, .y = r.y } },
        4 => if (!st.selection.empty()) {
            if (selectionText(ctx)) |s| ctx.act(.{ .copy = s });
        } else if (ctx.store.findAny(id)) |f| copyFmt(ctx, "{s}", .{f.m.msg.content}),
        5 => if (ctx.store.findAny(id)) |f| {
            var gb: [24]u8 = undefined;
            copyFmt(ctx, "https://discord.com/channels/{s}/{d}/{d}", .{ guildPart(&gb, f.cs.info.guild), f.cs.info.id, id });
        },
        7 => if (ctx.store.findAny(id)) |f| {
            f.cs.info.unread = true;
        },
        8, 25, 44, 63 => copyFmt(ctx, "{d}", .{id}),
        10 => ctx.act(if (st.saved.find(id) != null) .{ .unsave_message = id } else .{ .save_message = id }),
        80, 81, 82, 83 => ctx.act(.{ .set_status = @enumFromInt(item - 80) }),
        84 => st.popup = .{ .profile = .{ .user = id, .x = r.x, .y = r.y - 200 } },
        85 => {
            st.filtros.endFocus(ctx.store);
            st.showToast(ctx.now_ms, false, "modo foco desligado", "focus mode off", .{});
        },
        86, 87, 88, 89 => {
            st.filtros.startFocus(ctx.now_ms, ([_]u32{ 15, 30, 60, 0 })[item - 86]);
            st.showToast(ctx.now_ms, false, "modo foco: só DMs e menções notificam", "focus mode: only DMs and mentions notify", .{});
        },
        90 => {
            st.settings.data_saver = !st.settings.data_saver;
            st.filtros.save = true;
            if (st.settings.data_saver)
                st.showToast(ctx.now_ms, false, "modo economia: imagens só ao clicar", "data saver: images load on click", .{})
            else
                st.showToast(ctx.now_ms, false, "modo economia desligado", "data saver off", .{});
        },
        26 => {
            const on = !st.filtros.isIgnored(id);
            st.filtros.setIgnored(st.gpa, id, on);
            const name = if (ctx.store.user(id)) |u| u.name else "?";
            if (on)
                st.showToast(ctx.now_ms, false, "{s} ignorado: as mensagens ficam recolhidas", "ignoring {s}: their messages are collapsed", .{name})
            else
                st.showToast(ctx.now_ms, false, "{s} não é mais ignorado", "no longer ignoring {s}", .{name});
        },
        9 => ctx.act(.{ .delete_message = id }),
        20 => st.popup = .{ .profile = .{ .user = id, .x = r.x, .y = r.y } },
        21 => if (ctx.store.user(id)) |u| {
            insertText(st, u.name, true);
        },
        22 => ctx.act(.{ .open_dm = id }),
        24 => if (ctx.store.user(id)) |u| copyFmt(ctx, "{s}", .{u.name}),
        28 => st.popup = .{ .menu = .{ .kind = .voice_move, .id = id, .x = r.x + r.w - 8, .y = r.y + r.h - 70 } },
        29 => if (movable(ctx, id)) |cs| ctx.act(.{ .move_member = .{ .guild = cs.info.guild, .user = id, .channel = null } }),
        40, 60 => ctx.act(.{ .mark_read = id }),
        41 => {
            st.tabs.append(st.gpa, id) catch {};
            ctx.act(.{ .focus_tab = st.tabs.items.len - 1 });
        },
        45 => mosaic.openBeside(ctx, id),
        42 => if (st.muted_channels.contains(id)) {
            _ = st.muted_channels.remove(id);
        } else st.muted_channels.put(st.gpa, id, {}) catch {},
        43 => if (ctx.store.channel(id)) |cs| {
            var gb: [24]u8 = undefined;
            copyFmt(ctx, "https://discord.com/channels/{s}/{d}", .{ guildPart(&gb, cs.info.guild), id });
        },
        else => {},
    }
}

/// Coloca texto na caixa de mensagem (no fim), como uma menção ou um emoji.
pub fn insertText(st: *state.State, text: []const u8, mention: bool) void {
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    var out = st.input[len..];
    var n: usize = 0;
    if (len > 0 and st.input[len - 1] != ' ' and mention) {
        if (out.len > 1) {
            out[0] = ' ';
            n = 1;
        }
    }
    const piece = if (mention) "@" else "";
    for ([_][]const u8{ piece, text, if (mention) " " else "" }) |part| {
        const k = @min(part.len, out.len - n - 1);
        @memcpy(out[n .. n + k], part[0..k]);
        n += k;
    }
    out[n] = 0;
    st.input_sync = true;
    st.focus_input = true;
}

/// Texto da seleção atual (alocado; quem recebe libera).
pub fn selectionText(ctx: *d.Ctx) ?[]u8 {
    const sel = &ctx.st.selection;
    const cs = ctx.store.channel(sel.channel) orelse return null;
    var ia: ?usize = null;
    var ib: ?usize = null;
    for (cs.messages.items, 0..) |m, i| {
        if (m.msg.id == sel.a_id) ia = i;
        if (m.msg.id == sel.b_id) ib = i;
    }
    var first = ia orelse return null;
    var last = ib orelse return null;
    var o0 = sel.a_off;
    var o1 = sel.b_off;
    if (first > last or (first == last and o0 > o1)) {
        std.mem.swap(usize, &first, &last);
        std.mem.swap(u32, &o0, &o1);
    }
    var out: std.ArrayList(u8) = .empty;
    for (cs.messages.items[first .. last + 1], first..) |m, i| {
        const s = m.msg.content;
        const from = if (i == first) @min(o0, s.len) else 0;
        const to = if (i == last) @min(o1, s.len) else s.len;
        if (i != first) out.append(ctx.st.gpa, '\n') catch {};
        if (to > from) out.appendSlice(ctx.st.gpa, s[from..to]) catch {};
    }
    return out.toOwnedSlice(ctx.st.gpa) catch null;
}

// --- Emoji ------------------------------------------------------------------

fn emojiPicker(ctx: *d.Ctx, target: Id, x: f32, y: f32) void {
    const cols: usize = 8;
    const cell: f32 = 40;
    const rows = (emojis.len + cols - 1) / cols;
    const wd = @as(f32, @floatFromInt(cols)) * cell + 20;
    const h = @as(f32, @floatFromInt(rows)) * cell + 52;
    const r = fit(ctx, x - wd + 40, y - h - 8, wd, h);
    const dl = beginWindow("##emoji", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius + 2, 6);
    d.shadow(dl, r, radius, 16, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);
    d.text(dl, ctx.ui.get(.bold), 12, r.x + 14, r.y + 12, ctx.col(.muted), if (target == 0) i18n.tr("EMOJIS", "EMOJI") else i18n.tr("REAGIR", "REACT"));
    for (emojis, 0..) |e, i| {
        const cx = r.x + 10 + @as(f32, @floatFromInt(i % cols)) * cell;
        const cy = r.y + 38 + @as(f32, @floatFromInt(i / cols)) * cell;
        const er: d.Rect = .{ .x = cx, .y = cy, .w = cell, .h = cell };
        const hb = d.hit(ctx, i, er);
        qa.mark(er, "emoji:{d}", .{i});
        const k = anim.to(anim.id("emo", i), if (hb.hovered) 1 else 0, 30);
        if (k > 0.01) d.rect(dl, er.inset(2, 2), ctx.col(.hover).mix(ctx.col(.text), 0.05).alpha(k), 6);
        const es = 24 + 4 * k;
        d.text(dl, ctx.ui.get(.regular), es, cx + cell / 2 - es / 2, cy + cell / 2 - es * 0.6, d.Rgba.white, e);
        if (hb.clicked) {
            if (target == 0) {
                insertText(ctx.st, e, false);
            } else ctx.act(.{ .react = .{ .id = target, .emoji = types.Reaction.init(e) } });
            return close(ctx);
        }
    }
}
