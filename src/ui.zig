//! A interface: barra de servidores, canais, chat e membros.
//! Tudo é desenhado à mão no ImDrawList; o ImGui cuida de input, rolagem e
//! da caixa de texto.
const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const text = @import("text.zig");
const icons = @import("icons.zig");
const fake = @import("fake.zig");

const gpa = std.heap.c_allocator;
const Rgb = theme.Rgb;

const guild_w: f32 = 72;
const sidebar_w: f32 = 240;
const members_w: f32 = 248;
const header_h: f32 = 48;
const user_panel_h: f32 = 52;
const voice_panel_h: f32 = 56;

/// Data "de hoje" do protótipo: 02/11/2026 (dias desde 1970-01-01).
const today_epoch_day: i64 = 20759;

fn v(x: f32, y: f32) c.ImVec2 {
    return .{ .x = x, .y = y };
}

fn rect(dl: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, col: u32, rounding: f32) void {
    c.ImDrawList_AddRectFilledEx(dl, v(x0, y0), v(x1, y1), col, rounding, 0);
}

fn inside(p: c.ImVec2, x: f32, y: f32, w: f32, h: f32) bool {
    return p.x >= x and p.x < x + w and p.y >= y and p.y < y + h;
}

const ChannelData = struct {
    msgs: std.ArrayList(fake.Message),
    heights: std.ArrayList(f32) = .empty,
    offsets: std.ArrayList(f32) = .empty,
    total: f32 = 0,
    layout_w: f32 = -1,
    /// Negativo = ainda não posicionado (começa no fim).
    scroll: f32 = -1,
    target: f32 = 0,
    stick_bottom: bool = true,
};

pub const State = struct {
    guild: usize = 0,
    channel: usize = 2,
    voice: ?usize = null,
    muted: bool = false,
    deafened: bool = false,
    collapsed: [fake.categories.len]bool = @splat(false),
    input: [1024]u8 = @splat(0),
    focus_input: bool = true,
    data: std.AutoHashMapUnmanaged(u32, *ChannelData) = .empty,
};

fn channelData(st: *State) *ChannelData {
    const key: u32 = @intCast(st.guild * 64 + st.channel);
    if (st.data.get(key)) |d| return d;
    const d = gpa.create(ChannelData) catch @panic("OOM");
    d.* = .{ .msgs = fake.genMessages(gpa, key *% 7919 +% 1, 1000) catch @panic("OOM") };
    st.data.put(gpa, key, d) catch @panic("OOM");
    return d;
}

const Hit = struct { hovered: bool, clicked: bool, held: bool };

/// Área clicável invisível; o desenho fica por conta de quem chama.
fn hit(id: [*:0]const u8, n: usize, x: f32, y: f32, w: f32, h: f32) Hit {
    c.ImGui_SetCursorScreenPos(v(x, y));
    c.ImGui_PushIDInt(@intCast(n));
    const clicked = c.ImGui_InvisibleButton(id, v(@max(w, 1), @max(h, 1)), 0);
    const hovered = c.ImGui_IsItemHovered(0);
    const held = c.ImGui_IsItemActive();
    c.ImGui_PopID();
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .hovered = hovered, .clicked = clicked, .held = held };
}

fn beginRegion(id: [*:0]const u8, x: f32, y: f32, w: f32, h: f32, flags: c_int) *c.ImDrawList {
    c.ImGui_SetCursorScreenPos(v(x, y));
    _ = c.ImGui_BeginChild(id, v(w, h), 0, c.ImGuiWindowFlags_NoBackground | flags);
    return c.ImGui_GetWindowDrawList();
}

/// Sombra suave embaixo de cabeçalhos.
fn shadowBelow(dl: *c.ImDrawList, x0: f32, x1: f32, y: f32) void {
    rect(dl, x0, y, x1, y + 1, Rgb.hex(0).col(0.28), 0);
    c.ImDrawList_AddRectFilledMultiColor(dl, v(x0, y + 1), v(x1, y + 6), Rgb.hex(0).col(0.16), Rgb.hex(0).col(0.16), 0, 0);
}

/// Copia `s` em maiúsculas para `buf` (ASCII + acentos latinos comuns).
fn upper(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = s[i];
        if (ch >= 'a' and ch <= 'z') {
            buf[i] = ch - 32;
        } else if (ch == 0xC3 and i + 1 < n and s[i + 1] >= 0xA0 and s[i + 1] <= 0xBE and s[i + 1] != 0xB7) {
            buf[i] = ch;
            buf[i + 1] = s[i + 1] - 0x20;
            i += 1;
        } else buf[i] = ch;
    }
    return buf[0..n];
}

fn firstGlyph(s: []const u8) []const u8 {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return s[0..@min(len, s.len)];
}

fn statusColor(s: fake.Status) Rgb {
    const th = &theme.t;
    return switch (s) {
        .online => th.online,
        .idle => th.idle,
        .dnd => th.dnd,
        .offline => th.faint,
    };
}

fn avatar(dl: *c.ImDrawList, cx: f32, cy: f32, r: f32, user_idx: usize, ring: Rgb, show_status: bool, alpha: f32) void {
    const th = &theme.t;
    const u = fake.users[user_idx];
    const base = th.roles[u.role % th.roles.len];
    c.ImDrawList_AddCircleFilled(dl, v(cx, cy), r, base.mix(th.chat, 0.3).col(alpha), 0);

    var up: [8]u8 = undefined;
    const initial = upper(&up, firstGlyph(u.name));
    const fs = r * 0.9;
    const tw = text.width(text.fonts.semibold, fs, initial);
    text.draw(dl, text.fonts.semibold, fs, cx - tw / 2, cy - fs * 0.6, Rgb.hex(0xffffff).col(0.92 * alpha), initial);

    if (!show_status) return;
    const sr = r * 0.3;
    const sx = cx + r * 0.7;
    const sy = cy + r * 0.7;
    const sc = statusColor(u.status);
    c.ImDrawList_AddCircleFilled(dl, v(sx, sy), sr + @max(2, r * 0.12), ring.col(1), 0);
    c.ImDrawList_AddCircleFilled(dl, v(sx, sy), sr, sc.col(alpha), 0);
    switch (u.status) {
        .idle => c.ImDrawList_AddCircleFilled(dl, v(sx - sr * 0.45, sy - sr * 0.45), sr * 0.62, ring.col(1), 0),
        .dnd => rect(dl, sx - sr * 0.55, sy - sr * 0.17, sx + sr * 0.55, sy + sr * 0.17, ring.col(1), sr * 0.17),
        .offline => c.ImDrawList_AddCircleFilled(dl, v(sx, sy), sr * 0.45, ring.col(1), 0),
        .online => {},
    }
}

// ---------------------------------------------------------------------------

pub fn frame(st: *State) void {
    const vp = c.ImGui_GetMainViewport();
    const p = vp.*.Pos;
    const w = vp.*.Size.x;
    const h = vp.*.Size.y;
    c.ImGui_SetNextWindowPos(p, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    _ = c.ImGui_Begin("##root", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse);

    const show_members = w >= 1040;
    const chat_x = p.x + guild_w + sidebar_w;
    const chat_r = if (show_members) p.x + w - members_w else p.x + w;

    const dl = c.ImGui_GetWindowDrawList();
    rect(dl, p.x, p.y, p.x + w, p.y + h, theme.t.chat.col(1), 0);

    guildBar(st, p.x, p.y, h);
    sidebar(st, p.x + guild_w, p.y, h);
    chatHeader(st, chat_x, p.y, p.x + w - chat_x, show_members);
    chat(st, chat_x, p.y + header_h, chat_r - chat_x, h - header_h);
    if (show_members) memberList(chat_r, p.y + header_h, h - header_h);

    c.ImGui_End();
}

// --- Servidores -------------------------------------------------------------

fn guildBar(st: *State, x: f32, y: f32, h: f32) void {
    const th = &theme.t;
    const root = c.ImGui_GetWindowDrawList();
    rect(root, x, y, x + guild_w, y + h, th.guilds.col(1), 0);

    const dl = beginRegion("##guilds", x, y, guild_w, h, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var cy = o.y + 12;

    // Logo / início.
    guildIcon(dl, st, null, x, cy);
    cy += 56;
    rect(dl, x + 24, cy - 4, x + 48, cy - 2, th.text.col(0.08), 1);
    cy += 6;

    for (fake.guilds, 0..) |_, i| {
        guildIcon(dl, st, i, x, cy);
        cy += 56;
    }

    c.ImGui_SetCursorScreenPos(v(x, cy));
    c.ImGui_Dummy(v(1, 4));
    c.ImGui_EndChild();
}

fn guildIcon(dl: *c.ImDrawList, st: *State, index: ?usize, x: f32, y: f32) void {
    const th = &theme.t;
    const n = if (index) |i| i + 1 else 0;
    const hb = hit("##guild", n, x + 12, y, 48, 48);
    const selected = if (index) |i| st.guild == i else false;
    const active = selected or hb.hovered;

    if (hb.clicked) if (index) |i| {
        st.guild = i;
        st.focus_input = true;
    };

    // Ícone: círculo que vira "squircle" no hover/seleção.
    const radius = anim.to(anim.id("g-rad", n), if (active) 15 else 24, 20);
    const fill_k = anim.to(anim.id("g-fill", n), if (active) 1 else 0, 20);
    const press = anim.to(anim.id("g-press", n), if (hb.held) 1 else 0, 30);
    const shrink = press * 1.5;
    const x0 = x + 12 + shrink;
    const y0 = y + shrink;
    const x1 = x + 60 - shrink;
    const y1 = y + 48 - shrink;

    if (index) |i| {
        const g = fake.guilds[i];
        const color = th.roles[g.color % th.roles.len];
        const bg = th.elevated.mix(color.mix(th.elevated, 0.15), fill_k);
        rect(dl, x0, y0, x1, y1, bg.col(1), radius);
        const fs: f32 = if (g.initials.len >= 3) 14 else 17;
        const tw = text.width(text.fonts.semibold, fs, g.initials);
        const tc = th.text.mix(Rgb.hex(0xffffff), fill_k);
        text.draw(dl, text.fonts.semibold, fs, x + 36 - tw / 2, y + 24 - fs * 0.62, tc.col(1), g.initials);

        // Badge de menções.
        if (g.mentions > 0) {
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{g.mentions}) catch "!";
            const lw = text.width(text.fonts.bold, 12, label);
            const bw = @max(16, lw + 9);
            const bx1 = x + 62;
            const by1 = y + 50;
            rect(dl, bx1 - bw - 3, by1 - 19, bx1 + 3, by1 + 3, th.guilds.col(1), 11);
            rect(dl, bx1 - bw, by1 - 16, bx1, by1, th.danger.col(1), 8);
            text.draw(dl, text.fonts.bold, 12, bx1 - bw / 2 - lw / 2, by1 - 15, Rgb.hex(0xffffff).col(1), label);
        }

        // Indicador à esquerda (não lido / hover / selecionado).
        const pill_target: f32 = if (selected) 40 else if (hb.hovered) 20 else if (g.unread) 8 else 0;
        const pill = anim.to(anim.id("g-pill", n), pill_target, 18);
        if (pill > 0.5) {
            const cy = y + 24;
            c.ImDrawList_AddRectFilledEx(dl, v(x, cy - pill / 2), v(x + 4, cy + pill / 2), th.text.col(1), 4, c.ImDrawFlags_RoundRight);
        }

        tooltip(n, x + guild_w + 4, y + 24, g.name, hb.hovered);
    } else {
        // Logo do app.
        const bg = th.elevated.mix(th.accent, @max(fill_k, 0.0));
        rect(dl, x0, y0, x1, y1, bg.col(1), radius);
        // Balão de conversa com três pontinhos.
        const tc = th.accent.mix(th.accent_text, fill_k);
        const cx = x + 36;
        const cy = y + 23;
        rect(dl, cx - 12, cy - 9, cx + 12, cy + 8, tc.col(1), 8);
        c.ImDrawList_AddTriangleFilled(dl, v(cx - 7, cy + 6), v(cx - 1, cy + 6), v(cx - 9, cy + 13), tc.col(1));
        for ([_]f32{ -6, 0, 6 }) |dx| c.ImDrawList_AddCircleFilled(dl, v(cx + dx, cy - 0.5), 2, bg.col(1), 0);
        tooltip(n, x + guild_w + 4, y + 24, "Mensagens diretas", hb.hovered);
    }
}

fn tooltip(n: usize, x: f32, cy: f32, label: []const u8, show: bool) void {
    const th = &theme.t;
    const k = anim.to(anim.id("g-tip", n), if (show) 1 else 0, 26);
    if (k < 0.02) return;
    const fg = c.ImGui_GetForegroundDrawList();
    const fs: f32 = 15;
    const tw = text.width(text.fonts.semibold, fs, label);
    const ox = x + (1 - k) * -8;
    const bw = tw + 24;
    const bh: f32 = 34;
    c.ImDrawList_AddRectFilledEx(fg, v(ox + 2, cy - bh / 2 + 3), v(ox + bw + 2, cy + bh / 2 + 3), Rgb.hex(0).col(0.25 * k), 6, 0);
    rect(fg, ox, cy - bh / 2, ox + bw, cy + bh / 2, th.tooltip.col(k), 6);
    c.ImDrawList_AddTriangleFilled(fg, v(ox - 5, cy), v(ox + 1, cy - 6), v(ox + 1, cy + 6), th.tooltip.col(k));
    text.draw(fg, text.fonts.semibold, fs, ox + 12, cy - 9.5, th.text.col(k), label);
}

// --- Canais -------------------------------------------------------------------

fn sidebar(st: *State, x: f32, y: f32, h: f32) void {
    const th = &theme.t;
    const root = c.ImGui_GetWindowDrawList();
    rect(root, x, y, x + sidebar_w, y + h, th.sidebar.col(1), 0);

    // Cabeçalho com o nome do servidor.
    const g = fake.guilds[st.guild];
    const hh = hit("##ghead", 0, x, y, sidebar_w, header_h);
    const hk = anim.to(anim.id("ghead", 0), if (hh.hovered) 1 else 0, 20);
    rect(root, x, y, x + sidebar_w, y + header_h, th.text.col(0.04 * hk), 0);
    text.drawClipped(root, text.fonts.semibold, 16, x + 16, y + 14.5, th.text.col(1), g.name, sidebar_w - 56);
    icons.chevron(root, x + sidebar_w - 24, y + 24, th.text.col(0.9), 1);

    const bottom_h = user_panel_h + (if (st.voice != null) voice_panel_h else 0);
    const list_h = h - header_h - bottom_h;
    const dl = beginRegion("##channels", x, y + header_h, sidebar_w, list_h, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var cy = o.y + 8;

    for (fake.categories, 0..) |cat, ci| {
        cy += 12;
        // Categoria.
        const ch_hit = hit("##cat", ci, x + 4, cy, sidebar_w - 8, 24);
        if (ch_hit.clicked) st.collapsed[ci] = !st.collapsed[ci];
        const open = anim.to(anim.id("cat-open", ci), if (st.collapsed[ci]) 0 else 1, 22);
        const cat_col = if (ch_hit.hovered) th.text.mix(th.muted, 0.2) else th.faint.mix(th.muted, 0.4);
        icons.chevron(dl, x + 12, cy + 12, cat_col.col(1), open);
        var up: [64]u8 = undefined;
        text.draw(dl, text.fonts.semibold, 12, x + 20, cy + 5, cat_col.col(1), upper(&up, cat));
        cy += 26;

        for (fake.channels, 0..) |chan, idx| {
            if (chan.category != ci) continue;
            const selected = chan.kind == .text and st.channel == idx;
            const in_voice = chan.kind == .voice and st.voice == idx;
            if (st.collapsed[ci] and !selected and !in_voice) continue;
            cy = channelRow(dl, st, idx, x, cy);
        }
    }

    c.ImGui_SetCursorScreenPos(v(x, cy));
    c.ImGui_Dummy(v(1, 16));
    c.ImGui_EndChild();

    var py = y + h - bottom_h;
    if (st.voice) |vc| {
        voicePanel(st, x, py, vc);
        py += voice_panel_h;
    }
    userPanel(st, x, py);
}

fn channelRow(dl: *c.ImDrawList, st: *State, idx: usize, x: f32, y: f32) f32 {
    const th = &theme.t;
    const chan = fake.channels[idx];
    const selected = chan.kind == .text and st.channel == idx;
    const row_h: f32 = 34;
    const hb = hit("##chan", idx, x + 8, y, sidebar_w - 16, row_h - 2);

    if (hb.clicked) switch (chan.kind) {
        .text => {
            st.channel = idx;
            st.focus_input = true;
        },
        .voice => st.voice = if (st.voice == idx) null else idx,
    };

    const bg_k = anim.to(anim.id("chan-bg", idx), if (selected) 1 else if (hb.hovered) 0.5 else 0, 24);
    if (bg_k > 0.01) rect(dl, x + 8, y, x + sidebar_w - 8, y + row_h - 2, th.text.col(0.1 * bg_k), 6);

    const bright = selected or hb.hovered or chan.unread;
    const name_col = if (selected) th.text else if (bright) th.text.mix(th.muted, 0.15) else th.muted;
    const icon_col = th.faint.mix(th.muted, if (bright) 0.5 else 0);

    switch (chan.kind) {
        .text => text.draw(dl, text.fonts.medium, 20, x + 18, y + 4.5, icon_col.col(1), "#"),
        .voice => icons.speaker(dl, x + 26, y + 16, icon_col.col(1)),
    }
    const name_font = if (chan.unread and !selected) text.fonts.semibold else text.fonts.medium;
    text.drawClipped(dl, name_font, 16, x + 42, y + 7, name_col.col(1), chan.name, sidebar_w - 70);

    if (chan.unread and !selected)
        c.ImDrawList_AddRectFilledEx(dl, v(x, y + 12), v(x + 4, y + 20), th.text.col(1), 4, c.ImDrawFlags_RoundRight);

    var cy = y + row_h;
    if (chan.kind == .voice) {
        // Quem está na call.
        var people_buf: [8]u8 = undefined;
        var people: std.ArrayList(u8) = .initBuffer(&people_buf);
        if (st.voice == idx) people.appendAssumeCapacity(0);
        for (fake.voiceMembers(idx)) |u| people.appendAssumeCapacity(u);
        for (people.items, 0..) |u, k| {
            const speaking = k == 1 and !st.deafened;
            const ax = x + 50;
            const acy = cy + 14;
            if (speaking) c.ImDrawList_AddCircleEx(dl, v(ax, acy), 13, th.online.col(1), 0, 2, 0);
            avatar(dl, ax, acy, 11, u, th.sidebar, false, 1);
            const nc = if (speaking) th.text else th.muted;
            text.draw(dl, text.fonts.medium, 14, x + 70, cy + 5, nc.col(1), fake.users[u].name);
            cy += 30;
        }
        if (people.items.len > 0) cy += 4;
    }
    return cy;
}

fn voicePanel(st: *State, x: f32, y: f32, vc: usize) void {
    const th = &theme.t;
    const dl = c.ImGui_GetWindowDrawList();
    rect(dl, x, y, x + sidebar_w, y + voice_panel_h, th.panel.col(1), 0);
    rect(dl, x + 8, y + voice_panel_h - 1, x + sidebar_w - 8, y + voice_panel_h, th.text.col(0.06), 0);
    text.draw(dl, text.fonts.semibold, 14, x + 16, y + 10, th.online.col(1), "Voz conectada");
    var buf: [128]u8 = undefined;
    const sub = std.fmt.bufPrint(&buf, "{s} / {s}", .{ fake.channels[vc].name, fake.guilds[st.guild].name }) catch "";
    text.drawClipped(dl, text.fonts.regular, 13, x + 16, y + 30, th.muted.col(1), sub, sidebar_w - 70);

    // Desconectar.
    const bx = x + sidebar_w - 44;
    const hb = hit("##hangup", 0, bx, y + 12, 32, 32);
    const k = anim.to(anim.id("hangup", 0), if (hb.hovered) 1 else 0, 24);
    rect(dl, bx, y + 12, bx + 32, y + 44, th.text.col(0.08 * k), 6);
    const cx = bx + 16;
    const cy = y + 28;
    const col = th.muted.mix(th.danger, k).col(1);
    c.ImDrawList_AddLineEx(dl, v(cx - 5, cy - 5), v(cx + 5, cy + 5), col, 2.2, 0);
    c.ImDrawList_AddLineEx(dl, v(cx + 5, cy - 5), v(cx - 5, cy + 5), col, 2.2, 0);
    if (hb.clicked) st.voice = null;
}

fn userPanel(st: *State, x: f32, y: f32) void {
    const th = &theme.t;
    const dl = c.ImGui_GetWindowDrawList();
    rect(dl, x, y, x + sidebar_w, y + user_panel_h, th.panel.col(1), 0);

    const me = fake.users[0];
    const card = hit("##me", 0, x + 8, y + 8, 120, 36);
    const ck = anim.to(anim.id("me", 0), if (card.hovered) 1 else 0, 24);
    rect(dl, x + 6, y + 8, x + 130, y + 44, th.text.col(0.07 * ck), 6);
    avatar(dl, x + 26, y + 26, 16, 0, th.panel, true, 1);
    text.drawClipped(dl, text.fonts.semibold, 14, x + 50, y + 9.5, th.text.col(1), me.name, 76);
    text.drawClipped(dl, text.fonts.regular, 12, x + 50, y + 27, th.muted.col(1), "Online", 76);

    const btns = [_]struct { id: usize, active: bool }{
        .{ .id = 0, .active = st.muted },
        .{ .id = 1, .active = st.deafened },
        .{ .id = 2, .active = false },
    };
    for (btns, 0..) |b, i| {
        const bx = x + 136 + @as(f32, @floatFromInt(i)) * 32;
        const hb = hit("##ubtn", b.id, bx, y + 10, 32, 32);
        const k = anim.to(anim.id("ubtn", b.id), if (hb.hovered) 1 else 0, 24);
        rect(dl, bx, y + 10, bx + 32, y + 42, th.text.col(0.08 * k), 6);
        const col = (if (b.active) th.danger else th.muted.mix(th.text, k)).col(1);
        const cx = bx + 16;
        const cy = y + 26;
        switch (b.id) {
            0 => icons.mic(dl, cx, cy, col),
            1 => icons.headset(dl, cx, cy, col),
            else => icons.gear(dl, cx, cy, col),
        }
        if (b.active) c.ImDrawList_AddLineEx(dl, v(cx - 9, cy - 9), v(cx + 9, cy + 9), th.danger.col(1), 2.2, 0);
        if (hb.clicked) switch (b.id) {
            0 => st.muted = !st.muted,
            1 => st.deafened = !st.deafened,
            else => {},
        };
    }
}

// --- Chat ---------------------------------------------------------------------

fn chatHeader(st: *State, x: f32, y: f32, w: f32, members_on: bool) void {
    const th = &theme.t;
    const dl = c.ImGui_GetWindowDrawList();
    const chan = fake.channels[st.channel];

    text.draw(dl, text.fonts.medium, 22, x + 17, y + 11, th.faint.col(1), "#");
    text.draw(dl, text.fonts.semibold, 16, x + 42, y + 14, th.text.col(1), chan.name);
    const name_w = text.width(text.fonts.semibold, 16, chan.name);

    const search_w: f32 = 180;
    const sx = x + w - 16 - search_w;
    const tx = x + 42 + name_w + 14;
    if (chan.topic.len > 0 and sx - tx > 80) {
        rect(dl, tx, y + 14, tx + 1, y + 34, th.text.col(0.12), 0);
        text.drawClipped(dl, text.fonts.regular, 14, tx + 14, y + 15, th.muted.col(1), chan.topic, sx - tx - 70);
    }

    // Busca.
    const sh = hit("##search", 0, sx, y + 11, search_w, 26);
    const sk = anim.to(anim.id("search", 0), if (sh.hovered) 1 else 0, 20);
    rect(dl, sx, y + 11, sx + search_w, y + 37, th.guilds.mix(th.sidebar, 0.3 + 0.3 * sk).col(1), 6);
    text.draw(dl, text.fonts.regular, 14, sx + 9, y + 16, th.faint.mix(th.muted, sk).col(1), "Buscar");
    icons.search(dl, sx + search_w - 15, y + 24, th.faint.mix(th.muted, sk).col(1));

    // Membros.
    const mx = sx - 40;
    const mh = hit("##members-btn", 0, mx, y + 10, 28, 28);
    const mcol = if (members_on) th.text else if (mh.hovered) th.text.mix(th.muted, 0.3) else th.muted;
    icons.members(dl, mx + 14, y + 24, mcol.col(1));

    shadowBelow(dl, x, x + w, y + header_h - 1);
}

fn chat(st: *State, x: f32, y: f32, w: f32, h: f32) void {
    const composer_h: f32 = 46;
    const composer_y = y + h - 22 - composer_h;
    messages(st, x, y, w, composer_y - 6 - y);
    composer(st, x + 16, composer_y, w - 32, composer_h);
}

fn messageHeight(m: fake.Message, wrap: f32) f32 {
    var hgt: f32 = 0;
    if (m.day_break) hgt += 46;
    hgt += if (m.group_start) 16 + 22 else 1;
    hgt += text.rich(null, m.text, 0, 0, wrap);
    hgt += 1;
    return hgt;
}

fn relayout(d: *ChannelData, wrap: f32) void {
    d.heights.clearRetainingCapacity();
    d.offsets.clearRetainingCapacity();
    d.heights.ensureTotalCapacity(gpa, d.msgs.items.len) catch @panic("OOM");
    d.offsets.ensureTotalCapacity(gpa, d.msgs.items.len) catch @panic("OOM");
    var off: f32 = 8;
    for (d.msgs.items) |m| {
        const hgt = messageHeight(m, wrap);
        d.offsets.appendAssumeCapacity(off);
        d.heights.appendAssumeCapacity(hgt);
        off += hgt;
    }
    d.total = off + 16;
    d.layout_w = wrap;
}

fn firstVisible(d: *const ChannelData, scroll: f32) usize {
    // Busca binária pelo primeiro item cujo fim passa do topo visível.
    var lo: usize = 0;
    var hi: usize = d.offsets.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (d.offsets.items[mid] + d.heights.items[mid] < scroll) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn messages(st: *State, x: f32, y: f32, w: f32, h: f32) void {
    const d = channelData(st);
    const wrap = w - 72 - 40;
    if (d.layout_w != wrap) relayout(d, wrap);

    const max_scroll = @max(0, d.total - h);
    const io = c.ImGui_GetIO();
    const mouse = io.*.MousePos;
    const hovered = inside(mouse, x, y, w, h) and c.ImGui_IsWindowHovered(c.ImGuiHoveredFlags_ChildWindows);

    if (d.scroll < 0 or d.stick_bottom) {
        d.target = max_scroll;
        if (d.scroll < 0) d.scroll = max_scroll;
    }
    if (hovered and io.*.MouseWheel != 0) d.target -= io.*.MouseWheel * 120;
    d.target = std.math.clamp(d.target, 0, max_scroll);
    d.stick_bottom = d.target >= max_scroll - 1;
    d.scroll = anim.step(d.scroll, d.target, 18);

    c.ImGui_SetNextWindowScroll(v(-1, d.scroll));
    const dl = beginRegion("##messages", x, y, w, h, c.ImGuiWindowFlags_NoScrollWithMouse);
    const s = c.ImGui_GetScrollY();
    if (@abs(s - d.scroll) > 1 and c.ImGui_IsMouseDown(0) and mouse.x >= x + w - 14) {
        // Arrastou a barra de rolagem.
        d.scroll = s;
        d.target = s;
        d.stick_bottom = s >= max_scroll - 1;
    }
    c.ImGui_Dummy(v(w - 12, d.total));

    const base = y - s + @max(0, h - d.total);
    var i = firstVisible(d, s);
    while (i < d.msgs.items.len) : (i += 1) {
        const oy = d.offsets.items[i];
        if (oy > s + h) break;
        drawMessage(dl, d, i, x, base + oy, w, wrap, hovered, mouse);
    }
    c.ImGui_EndChild();
}

const months = [_][]const u8{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" };

const Date = struct { day: u8, month: u8, year: u16 };

fn dateOf(d: *const ChannelData, m: fake.Message) Date {
    const diff: i64 = @as(i64, fake.today(d.msgs.items)) - @as(i64, m.minute / 1440);
    const ed: std.time.epoch.EpochDay = .{ .day = @intCast(today_epoch_day - diff) };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{ .day = @as(u8, md.day_index) + 1, .month = md.month.numeric(), .year = yd.year };
}

fn drawMessage(dl: *c.ImDrawList, d: *const ChannelData, i: usize, x: f32, y: f32, w: f32, wrap: f32, region_hovered: bool, mouse: c.ImVec2) void {
    const th = &theme.t;
    const m = d.msgs.items[i];
    var cy = y;
    var buf: [96]u8 = undefined;

    if (m.day_break) {
        const dt = dateOf(d, m);
        const label = std.fmt.bufPrint(&buf, "{d} de {s} de {d}", .{ dt.day, months[dt.month - 1], dt.year }) catch "";
        const lw = text.width(text.fonts.semibold, 12, label);
        const mid = cy + 24;
        const lx = x + w / 2 - lw / 2;
        rect(dl, x + 16, mid, lx - 10, mid + 1, th.text.col(0.09), 0);
        rect(dl, lx + lw + 10, mid, x + w - 16, mid + 1, th.text.col(0.09), 0);
        text.draw(dl, text.fonts.semibold, 12, lx, mid - 8, th.faint.col(1), label);
        cy += 46;
    }

    const row_h = d.heights.items[i] - (if (m.day_break) @as(f32, 46) else 0);
    const hovered = region_hovered and inside(mouse, x, cy, w, row_h);
    if (hovered) rect(dl, x, cy, x + w, cy + row_h, Rgb.hex(0).col(0.08), 0);

    const hh = (m.minute % 1440) / 60;
    const mm = m.minute % 60;
    const u = fake.users[m.author];

    if (m.group_start) {
        cy += 16;
        avatar(dl, x + 36, cy + 20, 20, m.author, th.chat, false, 1);
        const name_col = th.roles[u.role % th.roles.len].mix(th.text, 0.2);
        text.draw(dl, text.fonts.semibold, 16, x + 72, cy, name_col.col(1), u.name);
        const nw = text.width(text.fonts.semibold, 16, u.name);

        const diff = fake.today(d.msgs.items) - m.minute / 1440;
        const stamp = switch (diff) {
            0 => std.fmt.bufPrint(&buf, "Hoje às {d:0>2}:{d:0>2}", .{ hh, mm }),
            1 => std.fmt.bufPrint(&buf, "Ontem às {d:0>2}:{d:0>2}", .{ hh, mm }),
            else => blk: {
                const dt = dateOf(d, m);
                break :blk std.fmt.bufPrint(&buf, "{d:0>2}/{d:0>2}/{d} {d:0>2}:{d:0>2}", .{ dt.day, dt.month, dt.year, hh, mm });
            },
        } catch "";
        text.draw(dl, text.fonts.medium, 12, x + 72 + nw + 8, cy + 4, th.faint.col(1), stamp);
        cy += 22;
    } else {
        cy += 1;
        if (hovered) {
            const stamp = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch "";
            const sw = text.width(text.fonts.medium, 11, stamp);
            text.draw(dl, text.fonts.medium, 11, x + 36 - sw / 2, cy + 5, th.faint.col(1), stamp);
        }
    }
    _ = text.rich(dl, m.text, x + 72, cy, wrap);
}

fn composer(st: *State, x: f32, y: f32, w: f32, h: f32) void {
    const th = &theme.t;
    const dl = c.ImGui_GetWindowDrawList();
    rect(dl, x, y, x + w, y + h, th.elevated.col(1), 10);

    // Anexar.
    const ph = hit("##attach", 0, x + 10, y + h / 2 - 14, 28, 28);
    const pk = anim.to(anim.id("attach", 0), if (ph.hovered) 1 else 0, 24);
    c.ImDrawList_AddCircleFilled(dl, v(x + 24, y + h / 2), 11.5, th.muted.mix(th.text, pk).col(1), 0);
    icons.plus(dl, x + 24, y + h / 2, 5.5, th.elevated.col(1));

    // Emoji e GIF à direita.
    const ex = x + w - 40;
    const eh = hit("##emoji", 0, ex, y + h / 2 - 14, 28, 28);
    const ek = anim.to(anim.id("emoji", 0), if (eh.hovered) 1 else 0, 20);
    const es: f32 = 20 + 2 * ek;
    text.draw(dl, text.fonts.regular, es, ex + 14 - es / 2, y + h / 2 - es * 0.6, Rgb.hex(0xffffff).col(0.55 + 0.45 * ek), "😊");

    const gx = ex - 44;
    const gh = hit("##gif", 0, gx, y + h / 2 - 12, 34, 24);
    const gcol = th.muted.mix(th.text, if (gh.hovered) @as(f32, 1) else 0);
    c.ImDrawList_AddRectEx(dl, v(gx + 2, y + h / 2 - 8), v(gx + 32, y + h / 2 + 8), gcol.col(1), 4, 1.8, 0);
    const gw = text.width(text.fonts.bold, 11, "GIF");
    text.draw(dl, text.fonts.bold, 11, gx + 17 - gw / 2, y + h / 2 - 7, gcol.col(1), "GIF");

    // Caixa de texto.
    const fs = text.body_size;
    const frame_h = fs + 8;
    c.ImGui_PushFontFloat(text.fonts.regular, fs);
    c.ImGui_SetCursorScreenPos(v(x + 48, y + (h - frame_h) / 2));
    c.ImGui_SetNextItemWidth(gx - (x + 48) - 8);
    if (st.focus_input) {
        c.ImGui_SetKeyboardFocusHere();
        st.focus_input = false;
    }
    var hint_buf: [96]u8 = undefined;
    const hint = std.fmt.bufPrintSentinel(&hint_buf, "Conversar em #{s}", .{fake.channels[st.channel].name}, 0) catch "";
    if (c.ImGui_InputTextWithHint("##composer", hint.ptr, &st.input, st.input.len, c.ImGuiInputTextFlags_EnterReturnsTrue)) {
        send(st);
        st.focus_input = true;
    }
    c.ImGui_PopFont();
}

fn send(st: *State) void {
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    const s = std.mem.trim(u8, st.input[0..len], " \t");
    if (s.len > 0) {
        const d = channelData(st);
        const owned = gpa.dupe(u8, s) catch @panic("OOM");
        const last = d.msgs.items[d.msgs.items.len - 1].minute;
        d.msgs.append(gpa, .{ .author = 0, .minute = last + 1, .text = owned, .group_start = false, .day_break = false }) catch @panic("OOM");
        fake.regroup(d.msgs.items);
        d.layout_w = -1;
        d.stick_bottom = true;
    }
    @memset(&st.input, 0);
}

// --- Membros ------------------------------------------------------------------

fn memberList(x: f32, y: f32, h: f32) void {
    const th = &theme.t;
    const root = c.ImGui_GetWindowDrawList();
    rect(root, x, y, x + members_w, y + h, th.sidebar.col(1), 0);

    const dl = beginRegion("##members", x, y, members_w, h, c.ImGuiWindowFlags_NoScrollbar);
    const o = c.ImGui_GetCursorScreenPos();
    var cy = o.y + 20;

    var online: usize = 0;
    for (fake.users) |u| {
        if (u.status != .offline) online += 1;
    }
    var buf: [48]u8 = undefined;

    for ([_]bool{ true, false }) |want_online| {
        const count = if (want_online) online else fake.users.len - online;
        const label = std.fmt.bufPrint(&buf, "{s} — {d}", .{ if (want_online) "ONLINE" else "OFFLINE", count }) catch "";
        text.draw(dl, text.fonts.semibold, 12, x + 16, cy, th.faint.mix(th.muted, 0.3).col(1), label);
        cy += 22;

        for (fake.users, 0..) |u, i| {
            if ((u.status != .offline) != want_online) continue;
            const hb = hit("##member", i, x + 8, cy, members_w - 16, 42);
            const k = anim.to(anim.id("member", i), if (hb.hovered) 1 else 0, 24);
            rect(dl, x + 8, cy, x + members_w - 8, cy + 42, th.text.col(0.07 * k), 6);
            const alpha: f32 = if (want_online) 1 else 0.38 + 0.4 * k;
            avatar(dl, x + 32, cy + 21, 16, i, th.sidebar, want_online, alpha);
            const name_col = th.roles[u.role % th.roles.len].mix(th.text, 0.25);
            if (u.activity) |act| {
                text.drawClipped(dl, text.fonts.medium, 15, x + 56, cy + 3.5, name_col.col(alpha), u.name, members_w - 72);
                text.drawClipped(dl, text.fonts.regular, 12, x + 56, cy + 22, th.muted.col(alpha), act, members_w - 72);
            } else {
                text.drawClipped(dl, text.fonts.medium, 15, x + 56, cy + 11.5, name_col.col(alpha), u.name, members_w - 72);
            }
            cy += 44;
        }
        cy += 16;
    }

    c.ImGui_SetCursorScreenPos(v(x, cy));
    c.ImGui_Dummy(v(1, 8));
    c.ImGui_EndChild();
}
