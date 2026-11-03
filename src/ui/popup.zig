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
const icons = @import("icons.zig");

pub const emojis = [_][]const u8{
    "😂", "😭", "💀", "🔥", "❤️", "👍", "👎", "👀", "🎉", "😍", "🙏", "😎",
    "🤔", "😅", "🥲", "😤", "😴", "🤯", "🫠", "🥺", "😈", "🤡", "👻", "🐧",
    "☕", "🍕", "🎮", "💻", "⚡", "✨", "🌸", "🌙", "🚀", "🦀", "🦎", "🐸",
    "✅", "❌", "⭐", "💯", "📌", "🔔", "🎵", "📷", "🧠", "💤", "🫡", "🤝",
};

const quick = [_][]const u8{ "👍", "😂", "😭", "🔥" };


fn close(ctx: *d.Ctx) void {
    if (@import("qa.zig").enabled and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[popup] fechou\n", .{});
    ctx.st.popup = .none;
    ctx.st.focus_input = true;
    ctx.st.role_picker = false;
}

/// Popup que estava aberto no quadro anterior. Só damos foco quando ele
/// aparece: focar outra janela a cada quadro cancelaria o clique em andamento
/// (o botão ficava "apertado" mas o clique nunca completava).
var shown_key: u64 = 0;
var appearing = false;

fn popupKey(p: state.Popup) u64 {
    return switch (p) {
        .none => 0,
        .menu => |m| 1 +% m.id *% 31 +% @intFromEnum(m.kind),
        .profile => |pr| 2 +% pr.user *% 31,
        .emoji => |e| 3 +% e.target *% 31,
    };
}

/// Janela do ImGui para o popup (recebe o mouse antes do resto).
fn beginWindow(id: [*:0]const u8, r: d.Rect) *c.ImDrawList {
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin(id, null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    return c.ImGui_GetWindowDrawList();
}

/// Mantém o retângulo dentro da janela.
fn fit(ctx: *const d.Ctx, x: f32, y: f32, wd: f32, h: f32) d.Rect {
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
    if (outside or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) return close(ctx);

    const saved = ctx.dl;
    defer ctx.dl = saved;
    switch (ctx.st.popup) {
        .menu => |m| menu(ctx, m.kind, m.id, m.x, m.y),
        .profile => |p| profile(ctx, p.user, p.x, p.y),
        .emoji => |e| emojiPicker(ctx, e.target, e.x, e.y),
        .none => {},
    }
}

// --- Menu de contexto -------------------------------------------------------

/// `label` (português) também é a marca do QA; `en` é o texto em inglês.
const Item = struct { label: []const u8, en: []const u8, id: u8, danger: bool = false, sep: bool = false };

fn menu(ctx: *d.Ctx, kind: state.MenuKind, id: Id, x: f32, y: f32) void {
    var items: [12]Item = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: *[12]Item, count: *usize, it: Item) void {
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
            add(&items, &n, .{ .label = "Copiar nome de usuário", .en = "Copy Username", .id = 24, .sep = true });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do usuário", .en = "Copy User ID", .id = 25 });
        },
        .channel => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 40 });
            add(&items, &n, .{ .label = "Abrir em nova aba", .en = "Open in New Tab", .id = 41 });
            add(&items, &n, .{ .label = if (ctx.st.muted_channels.contains(id)) "Reativar notificações" else "Silenciar canal", .en = if (ctx.st.muted_channels.contains(id)) "Unmute Channel" else "Mute Channel", .id = 42 });
            add(&items, &n, .{ .label = "Copiar link", .en = "Copy Link", .id = 43, .sep = true });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do canal", .en = "Copy Channel ID", .id = 44 });
        },
        .guild => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 60 });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do servidor", .en = "Copy Server ID", .id = 63 });
        },
    }

    const row_h: f32 = 32;
    const quick_h: f32 = if (kind == .message) 46 else 0;
    var seps: f32 = 0;
    for (items[0..n]) |it| {
        if (it.sep) seps += 9;
    }
    const mw: f32 = 220;
    const mh = quick_h + @as(f32, @floatFromInt(n)) * row_h + seps + 12;
    const r = fit(ctx, x + 2, y + 2, mw, mh);
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
    _ = kind;
    const st = ctx.st;
    close(ctx);
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
        9 => ctx.act(.{ .delete_message = id }),
        20 => st.popup = .{ .profile = .{ .user = id, .x = r.x, .y = r.y } },
        21 => if (ctx.store.user(id)) |u| {
            insertText(st, u.name, true);
        },
        22 => ctx.act(.{ .open_dm = id }),
        24 => if (ctx.store.user(id)) |u| copyFmt(ctx, "{s}", .{u.name}),
        40, 60 => ctx.act(.{ .mark_read = id }),
        41 => {
            st.tabs.append(st.gpa, id) catch {};
            ctx.act(.{ .focus_tab = st.tabs.items.len - 1 });
        },
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

// --- Perfil -----------------------------------------------------------------

fn bannerUrl(buf: []u8, uid: Id, hash: []const u8) []const u8 {
    if (std.mem.startsWith(u8, hash, "demo:")) return hash;
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/banners/{d}/{s}.png?size=600", .{ uid, hash }) catch "";
}

fn profile(ctx: *d.Ctx, uid: Id, x: f32, y: f32) void {
    const u = ctx.store.user(uid) orelse return close(ctx);
    ctx.act(.{ .want_profile = uid });
    const pf = ctx.store.profiles.get(uid);
    const fam = ctx.ui;
    const width: f32 = 340;
    const inner_w = width - 24;
    const banner_h: f32 = if (pf != null and pf.?.banner.len > 0) 120 else 92;

    // Cargos no servidor aberto e quais dá para mexer.
    const gid = ctx.st.guild;
    const info = ctx.store.memberInfo(gid, uid);
    const manage = ctx.store.can(gid, types.perm.manage_roles);
    const top = ctx.store.topRolePosition(gid);
    var rbuf: [6]Id = undefined;
    var nroles: usize = 0;
    if (info) |mi| for (mi.roleSlice()) |rid| if (ctx.store.roles.get(rid) != null) {
        rbuf[nroles] = rid;
        nroles += 1;
    };
    std.mem.sort(Id, rbuf[0..nroles], ctx, struct {
        fn f(cx: *d.Ctx, a: Id, b: Id) bool {
            return cx.store.roles.get(a).?.position > cx.store.roles.get(b).?.position;
        }
    }.f);
    var cands: [24]Id = undefined;
    var ncand: usize = 0;
    if (manage) {
        var it = ctx.store.roles.valueIterator();
        while (it.next()) |rl| {
            if (rl.guild != gid or rl.id == gid or rl.managed or rl.position >= top or ncand == cands.len) continue;
            if (std.mem.indexOfScalar(Id, rbuf[0..nroles], rl.id) != null) continue;
            cands[ncand] = rl.id;
            ncand += 1;
        }
        std.mem.sort(Id, cands[0..ncand], ctx, struct {
            fn f(cx: *d.Ctx, a: Id, b: Id) bool {
                return cx.store.roles.get(a).?.position > cx.store.roles.get(b).?.position;
            }
        }.f);
    }

    // Altura: mede antes de abrir a janela.
    const bio_spans = ctx.store.bios.get(uid) orelse &.{};
    const bio_opts: rich.Opts = .{ .family = fam, .size = 13.5, .line_h = 19, .color = ctx.col(.text).mix(ctx.col(.muted), 0.1), .underline_links = ctx.st.settings.underline_links };
    const bio_h = if (pf != null and pf.?.bio.len > 0) rich.layout(null, ctx.store, ctx.th, bio_spans, 0, 0, inner_w - 24, bio_opts, ctx.mouse).h + 26 else 0;
    var roles_rows: f32 = 0;
    if (nroles > 0 or (manage and ncand > 0)) {
        var rx: f32 = 0;
        roles_rows = 1;
        for (rbuf[0..nroles]) |rid| {
            const cw = d.width(fam.get(.medium), 12, ctx.store.roles.get(rid).?.name) + 40;
            if (rx + cw > inner_w - 24) {
                rx = 0;
                roles_rows += 1;
            }
            rx += cw + 6;
        }
    }
    const picker_h: f32 = if (ctx.st.role_picker and manage) @as(f32, @floatFromInt(@min(ncand, 8))) * 26 + 8 else 0;
    var inner_h: f32 = 12 + bio_h + 46 + (if (u.activity != null) @as(f32, 46) else 0);
    if (roles_rows > 0) inner_h += 20 + roles_rows * 26 + picker_h;
    const has_pron = pf != null and pf.?.pronouns.len > 0;
    const total_h = banner_h + 56 + 28 + (if (has_pron) @as(f32, 20) else 0) + 26 + inner_h + 12 + (if (uid != ctx.store.me) @as(f32, 52) else 8);

    const r = fit(ctx, x + 6, y - 40, width, total_h);
    const dl = beginWindow("##profile", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    const radius = @max(ctx.th.radius + 4, 6);
    d.shadow(dl, r, radius, 20, ctx.col(.shadow));
    d.rect(dl, r, ctx.col(.overlay), radius);

    // Banner: a imagem da pessoa, a cor de destaque dela, ou a do cargo.
    const br: d.Rect = .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = banner_h };
    var drew_banner = false;
    if (pf) |p| if (p.banner.len > 0) {
        var ub: [192]u8 = undefined;
        const url = bannerUrl(&ub, uid, p.banner);
        const scale = ctx.io.*.DisplayFramebufferScale.x;
        switch (ctx.images.get(url, br.w * scale, br.w * scale)) {
            .ready => |t| {
                // Cobre a faixa cortando o excesso (sem distorcer).
                const iw: f32 = @floatFromInt(t.w);
                const ih: f32 = @floatFromInt(t.h);
                const want = br.h / br.w;
                const vh = @min(1.0, want * iw / ih);
                const v0 = (1 - vh) / 2;
                c.ImDrawList_AddImageRounded(dl, t.ref, d.v(br.x, br.y), d.v(br.right(), br.bottom()), d.v(0, v0), d.v(1, v0 + vh), d.Rgba.white.col(1), radius, c.ImDrawFlags_RoundCornersTop);
                drew_banner = true;
                const hb = d.hit(ctx, 901, br);
                qa.mark(br, "profile-banner", .{});
                if (hb.clicked) {
                    var zb: [192]u8 = undefined;
                    att.openImage(ctx, bannerUrl(&zb, uid, p.banner), i18n.tr("banner", "banner"), @intCast(t.w * 2), @intCast(t.h * 2));
                }
            },
            else => {},
        }
    };
    if (!drew_banner) {
        const accent = if (pf) |p| p.accent else 0;
        const base = if (accent != 0) d.Rgba.hex(accent) else ctx.th.role(u.role);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(br.x, br.y), d.v(br.right(), br.bottom()), base.u(), base.mix(ctx.col(.accent), if (accent != 0) 0.15 else 0.6).u(), base.mix(ctx.col(.overlay), 0.3).u(), base.mix(ctx.col(.overlay), 0.3).u());
    }
    d.border(dl, r, ctx.col(.border), radius, 1);

    // Avatar (clicável: abre grande).
    const acy = r.y + banner_h + 4;
    d.circle(dl, r.x + 56, acy, 46, ctx.col(.overlay));
    w.avatar(ctx, dl, r.x + 56, acy, 80, uid, .circle, ctx.col(.overlay), 1);
    {
        const ar: d.Rect = .{ .x = r.x + 16, .y = acy - 40, .w = 80, .h = 80 };
        const hb = d.hit(ctx, 902, ar);
        qa.mark(ar, "profile-avatar", .{});
        d.tip(ctx, ar, i18n.tr("Ver foto", "View picture"), hb.hovered and u.avatar != null);
        if (hb.clicked) if (u.avatar) |h| {
            var zb: [192]u8 = undefined;
            const big = if (std.mem.startsWith(u8, h, "demo:")) h else std.fmt.bufPrint(&zb, "https://cdn.discordapp.com/avatars/{d}/{s}.png?size=1024", .{ uid, h }) catch "";
            att.openImage(ctx, big, u.name, 1024, 1024);
        };
    }

    var yy = acy + 52;
    d.text(dl, fam.get(.bold), 20, r.x + 16, yy, ctx.col(.text), u.name);
    yy += 28;
    if (has_pron) {
        _ = d.textClipped(dl, fam.get(.regular), 13, r.x + 16, yy, ctx.col(.muted), pf.?.pronouns, r.w - 32);
        yy += 20;
    }
    var buf: [64]u8 = undefined;
    const status = switch (u.status) {
        .online => "Online",
        .idle => i18n.tr("Ausente", "Idle"),
        .dnd => i18n.tr("Não perturbe", "Do Not Disturb"),
        .offline => "Offline",
    };
    d.circle(dl, r.x + 21, yy + 9, 5, w.statusColor(ctx, u.status));
    d.text(dl, fam.get(.medium), 14, r.x + 32, yy, ctx.col(.muted), status);
    yy += 26;
    const inner: d.Rect = .{ .x = r.x + 12, .y = yy, .w = inner_w, .h = inner_h };
    d.rect(dl, inner, ctx.col(.rail).alpha(0.7), @max(ctx.th.radius, 4));
    var iy = inner.y + 12;
    if (bio_h > 0) {
        d.text(dl, fam.get(.bold), 11.5, inner.x + 12, iy, ctx.col(.muted), i18n.tr("SOBRE MIM", "ABOUT ME"));
        iy += 18;
        const t = rich.layout(dl, ctx.store, ctx.th, bio_spans, inner.x + 12, iy, inner.w - 24, bio_opts, ctx.mouse);
        iy += t.h + 8;
    }
    if (u.activity) |a| {
        d.text(dl, fam.get(.bold), 11.5, inner.x + 12, iy, ctx.col(.muted), i18n.tr("ATIVIDADE", "ACTIVITY"));
        iy += 18;
        _ = d.textClipped(dl, fam.get(.medium), 14, inner.x + 12, iy, ctx.col(.text), a, inner.w - 24);
        iy += 28;
    }
    d.text(dl, fam.get(.bold), 11.5, inner.x + 12, iy, ctx.col(.muted), i18n.tr("NO DISCORD DESDE", "MEMBER SINCE"));
    iy += 18;
    d.text(dl, fam.get(.regular), 14, inner.x + 12, iy, ctx.col(.text), w.since(&buf, uid));
    iy += 28;

    // Cargos: × tira (com permissão), + abre a lista para dar um.
    if (roles_rows > 0) {
        d.text(dl, fam.get(.bold), 11.5, inner.x + 12, iy, ctx.col(.muted), i18n.tr("CARGOS", "ROLES"));
        iy += 20;
        var rx = inner.x + 12;
        for (rbuf[0..nroles], 0..) |rid, ri| {
            const rl = ctx.store.roles.get(rid).?;
            const tw = d.width(fam.get(.medium), 12, rl.name);
            const cw = tw + 40;
            if (rx + cw > inner.right() - 12) {
                rx = inner.x + 12;
                iy += 26;
            }
            const cr: d.Rect = .{ .x = rx, .y = iy, .w = cw, .h = 22 };
            const editable = manage and !rl.managed and rl.position < top;
            const hb = d.hit(ctx, 910 + ri, cr);
            qa.mark(cr, "role:{d}", .{rid});
            d.rect(dl, cr, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered and editable) 0.05 else 0), 5);
            const dot = if (rl.color != 0) d.Rgba.hex(rl.color) else ctx.col(.faint);
            if (hb.hovered and editable) {
                // O pontinho vira um × para tirar o cargo.
                d.line(dl, cr.x + 7, cr.y + 8, cr.x + 13, cr.y + 14, dot, 1.6);
                d.line(dl, cr.x + 13, cr.y + 8, cr.x + 7, cr.y + 14, dot, 1.6);
                d.tip(ctx, cr, i18n.tr("Tirar cargo", "Remove role"), true);
            } else d.circle(dl, cr.x + 10, cr.y + 11, 4, dot);
            _ = d.textClipped(dl, fam.get(.medium), 12, cr.x + 18, d.centerY(cr, 12), ctx.col(.text), rl.name, inner.w - 40);
            if (hb.clicked and editable) ctx.act(.{ .member_role = .{ .guild = gid, .user = uid, .role = rid, .add = false } });
            rx += cw + 6;
        }
        if (manage and ncand > 0) {
            if (rx + 26 > inner.right() - 12) {
                rx = inner.x + 12;
                iy += 26;
            }
            const pr: d.Rect = .{ .x = rx, .y = iy, .w = 26, .h = 22 };
            const hb = d.hit(ctx, 909, pr);
            qa.mark(pr, "role-add", .{});
            d.rect(dl, pr, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) 0.06 else 0), 5);
            icons.plus(dl, pr.x + 13, pr.y + 11, 4.5, ctx.col(.muted).u());
            d.tip(ctx, pr, i18n.tr("Dar cargo", "Add role"), hb.hovered);
            if (hb.clicked) ctx.st.role_picker = !ctx.st.role_picker;
        }
        iy += 26;
        if (ctx.st.role_picker and manage) {
            iy += 4;
            for (cands[0..@min(ncand, 8)], 0..) |rid, ci| {
                const rl = ctx.store.roles.get(rid).?;
                const rr: d.Rect = .{ .x = inner.x + 8, .y = iy, .w = inner.w - 16, .h = 24 };
                const hb = d.hit(ctx, 940 + ci, rr);
                qa.mark(rr, "role-pick:{d}", .{rid});
                if (hb.hovered) d.rect(dl, rr, ctx.col(.hover), 4);
                d.circle(dl, rr.x + 12, rr.y + 12, 4, if (rl.color != 0) d.Rgba.hex(rl.color) else ctx.col(.faint));
                _ = d.textClipped(dl, fam.get(.medium), 13, rr.x + 24, d.centerY(rr, 13), ctx.col(.text), rl.name, rr.w - 30);
                if (hb.clicked) {
                    ctx.act(.{ .member_role = .{ .guild = gid, .user = uid, .role = rid, .add = true } });
                    ctx.st.role_picker = false;
                }
                iy += 26;
            }
        }
    }

    // "Mensagem @fulano"
    if (uid != ctx.store.me) {
        const ir: d.Rect = .{ .x = r.x + 12, .y = r.bottom() - 50, .w = r.w - 24, .h = 38 };
        d.rect(dl, ir, ctx.col(.elevated), @max(ctx.th.radius, 4));
        c.ImGui_PushFontFloat(fam.get(.regular), 14);
        c.ImGui_SetCursorScreenPos(d.v(ir.x + 10, ir.y + 9));
        c.ImGui_SetNextItemWidth(ir.w - 20);
        var hint: [80]u8 = undefined;
        const h = i18n.fmtZ(&hint, "Mensagem @{s}", "Message @{s}", .{u.name});
        if (appearing) c.ImGui_SetKeyboardFocusHere();
        if (c.ImGui_InputTextWithHint("##pmsg", h.ptr, &ctx.st.popup_input, ctx.st.popup_input.len, c.ImGuiInputTextFlags_EnterReturnsTrue)) {
            const t = std.mem.sliceTo(&ctx.st.popup_input, 0);
            if (t.len > 0) {
                if (ctx.st.gpa.dupe(u8, t)) |owned| ctx.act(.{ .send_dm = .{ .user = uid, .text = owned } }) else |_| {}
            }
            @memset(&ctx.st.popup_input, 0);
            close(ctx);
        }
        c.ImGui_PopFont();
    }
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
