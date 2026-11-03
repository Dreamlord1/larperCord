//! Tela de configurações (estilo Discord): menu à esquerda, página à direita.
//! Usa as cores e fontes do tema atual, então combina com qualquer tema.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const S = @import("settings_state.zig");
const Preview = @import("../theme/manager.zig").Preview;

const Section = struct { title: []const u8, items: []const struct { page: S.Page, label: []const u8 } };

const sections = [_]Section{
    .{ .title = "CONFIGURAÇÕES DE USUÁRIO", .items = &.{
        .{ .page = .conta, .label = "Minha conta" },
        .{ .page = .perfis, .label = "Perfis" },
        .{ .page = .privacidade, .label = "Privacidade e segurança" },
    } },
    .{ .title = "CONFIGURAÇÕES DO APLICATIVO", .items = &.{
        .{ .page = .aparencia, .label = "Aparência" },
        .{ .page = .acessibilidade, .label = "Acessibilidade" },
        .{ .page = .voz, .label = "Voz e vídeo" },
        .{ .page = .chat, .label = "Chat" },
        .{ .page = .notificacoes, .label = "Notificações" },
        .{ .page = .atalhos, .label = "Atalhos de teclado" },
        .{ .page = .idioma, .label = "Idioma" },
        .{ .page = .avancado, .label = "Avançado" },
    } },
    .{ .title = "LARPERCORD", .items = &.{
        .{ .page = .desempenho, .label = "Desempenho" },
        .{ .page = .sobre, .label = "Sobre" },
    } },
};

/// Estado de desenho de uma página (posição corrente, largura útil).
const Page = struct {
    ctx: *d.Ctx,
    dl: *c.ImDrawList,
    x: f32,
    y: f32,
    w: f32,
    ids: usize = 0,

    fn id(p: *Page) usize {
        p.ids += 1;
        return p.ids;
    }

    fn font(p: *Page, wt: d.Weight) *c.ImFont {
        return p.ctx.ui.get(wt);
    }

    fn title(p: *Page, t: []const u8) void {
        d.text(p.dl, p.font(.bold), 22, p.x, p.y, p.ctx.col(.text), t);
        p.y += 44;
    }

    fn heading(p: *Page, t: []const u8) void {
        p.y += 8;
        var buf: [96]u8 = undefined;
        d.text(p.dl, p.font(.bold), 12, p.x, p.y, p.ctx.col(.muted), d.upper(&buf, t));
        p.y += 26;
    }

    fn note(p: *Page, t: []const u8) void {
        d.text(p.dl, p.font(.regular), 13.5, p.x, p.y, p.ctx.col(.faint), t);
        p.y += 26;
    }

    fn divider(p: *Page) void {
        p.y += 10;
        d.line(p.dl, p.x, p.y, p.x + p.w, p.y, p.ctx.col(.border).mix(p.ctx.col(.text), 0.03), 1);
        p.y += 20;
    }

    /// Linha com título, descrição e um interruptor à direita.
    fn toggle(p: *Page, label: []const u8, desc: []const u8, value: *bool) void {
        const ctx = p.ctx;
        const row_h: f32 = if (desc.len > 0) 58 else 40;
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = row_h };
        const k_id = p.id();
        const hb = d.hit(ctx, k_id, r);
        qa.mark(r, "toggle:{s}", .{label});
        if (hb.clicked) value.* = !value.*;
        d.text(p.dl, p.font(.medium), 16, r.x, r.y + 4, ctx.col(.text), label);
        if (desc.len > 0) _ = d.textClipped(p.dl, p.font(.regular), 13.5, r.x, r.y + 28, ctx.col(.muted), desc, r.w - 80);
        // Interruptor.
        const sw: d.Rect = .{ .x = r.right() - 44, .y = r.y + 4, .w = 40, .h = 24 };
        const on = anim.to(anim.id("sw", k_id + @as(usize, @intFromEnum(ctx.st.settings.page)) * 1000), if (value.*) 1 else 0, 22);
        d.rect(p.dl, sw, ctx.col(.faint).mix(ctx.col(.accent), on), 12);
        const kx = sw.x + 12 + on * 16;
        d.circle(p.dl, kx, sw.y + 12, 9, d.Rgba.white);
        const ink = ctx.col(.faint).mix(ctx.col(.accent), on);
        if (on > 0.5) {
            d.line(p.dl, kx - 4, sw.y + 12, kx - 1, sw.y + 15, ink, 2);
            d.line(p.dl, kx - 1, sw.y + 15, kx + 4, sw.y + 9, ink, 2);
        } else {
            d.line(p.dl, kx - 3, sw.y + 9, kx + 3, sw.y + 15, ink, 2);
            d.line(p.dl, kx + 3, sw.y + 9, kx - 3, sw.y + 15, ink, 2);
        }
        p.y += row_h;
        d.line(p.dl, r.x, p.y - 8, r.right(), p.y - 8, ctx.col(.border), 1);
        p.y += 6;
    }

    /// Controle deslizante com valor em texto.
    fn slider(p: *Page, label: []const u8, value: *f32, min: f32, max: f32, comptime fmt: []const u8, scale: f32) void {
        const ctx = p.ctx;
        d.text(p.dl, p.font(.medium), 16, p.x, p.y, ctx.col(.text), label);
        p.y += 30;
        const tr: d.Rect = .{ .x = p.x + 6, .y = p.y + 6, .w = p.w - 80, .h = 8 };
        const k = (value.* - min) / (max - min);
        const hr: d.Rect = .{ .x = tr.x - 8, .y = tr.y - 10, .w = tr.w + 16, .h = 28 };
        const hb = d.hit(ctx, p.id(), hr);
        qa.mark(hr, "slider:{s}", .{label});
        if (hb.held) {
            const t = std.math.clamp((ctx.mouse.x - tr.x) / tr.w, 0, 1);
            value.* = min + t * (max - min);
        }
        d.rect(p.dl, tr, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 4);
        d.rect(p.dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, ctx.col(.accent), 4);
        const kx = tr.x + tr.w * k;
        d.shadow(p.dl, .{ .x = kx - 7, .y = tr.y - 7, .w = 14, .h = 22 }, 4, 4, ctx.col(.shadow));
        d.rect(p.dl, .{ .x = kx - 6, .y = tr.y - 8, .w = 12, .h = 24 }, d.Rgba.white, 3);
        var buf: [32]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, .{value.* * scale}) catch "";
        d.text(p.dl, p.font(.semibold), 14, tr.right() + 22, tr.y - 5, ctx.col(.muted), txt);
        p.y += 40;
    }

    /// Escolha entre opções (clique alterna, como um menu compacto).
    fn select(p: *Page, label: []const u8, options: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        d.text(p.dl, p.font(.bold), 12, p.x, p.y, ctx.col(.muted), label);
        p.y += 22;
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 42 };
        const hb = d.hit(ctx, p.id(), r);
        qa.mark(r, "select:{s}", .{label});
        if (hb.clicked) value.* = @intCast((@as(usize, value.*) + 1) % options.len);
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
        d.border(p.dl, r, if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
        d.text(p.dl, p.font(.medium), 15, r.x + 12, d.centerY(r, 15), ctx.col(.text), options[@min(value.*, options.len - 1)]);
        icons.chevron(p.dl, r.right() - 20, r.y + 21, ctx.col(.muted).u(), 1);
        p.y += 54;
    }

    fn radio(p: *Page, options: []const []const u8, descs: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        for (options, 0..) |o, i| {
            const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = if (descs.len > i) @as(f32, 60) else 44 };
            const hb = d.hit(ctx, p.id(), r);
            qa.mark(r, "radio:{s}", .{o});
            if (hb.clicked) value.* = @intCast(i);
            const sel = value.* == i;
            d.rect(p.dl, r, if (sel) ctx.col(.selected) else if (hb.hovered) ctx.col(.hover) else ctx.col(.rail).alpha(0.5), ctx.th.radius);
            const cx = r.x + 22;
            const cy = r.y + 22;
            c.ImDrawList_AddCircleEx(p.dl, d.v(cx, cy), 9, (if (sel) ctx.col(.accent) else ctx.col(.muted)).u(), 0, 2, 0);
            if (sel) d.circle(p.dl, cx, cy, 5, ctx.col(.accent));
            d.text(p.dl, p.font(.medium), 15, r.x + 44, r.y + 12, ctx.col(.text), o);
            if (descs.len > i) d.text(p.dl, p.font(.regular), 13, r.x + 44, r.y + 34, ctx.col(.muted), descs[i]);
            p.y += r.h + 8;
        }
        p.y += 8;
    }

    /// Botões lado a lado, um selecionado (como no Discord).
    fn segmented(p: *Page, options: []const []const u8, value: *u8) void {
        const ctx = p.ctx;
        const gap: f32 = 8;
        const bw = (p.w - gap * @as(f32, @floatFromInt(options.len - 1))) / @as(f32, @floatFromInt(options.len));
        for (options, 0..) |o, i| {
            const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(i)) * (bw + gap), .y = p.y, .w = bw, .h = 44 };
            const hb = d.hit(ctx, p.id(), r);
            qa.mark(r, "seg:{s}", .{o});
            if (hb.clicked) value.* = @intCast(i);
            const sel = value.* == i;
            const k = anim.to(anim.id("seg", i + @as(usize, @intFromPtr(value))), if (sel) 1 else if (hb.hovered) 0.4 else 0, 20);
            d.rect(p.dl, r, ctx.col(.rail).alpha(0.6).mix(ctx.col(.accent).alpha(0.22), k), ctx.th.radius + 2);
            d.border(p.dl, r, if (sel) ctx.col(.accent) else ctx.col(.border), ctx.th.radius + 2, if (sel) 2 else 1);
            const tw = d.width(p.font(.semibold), 15, o);
            d.text(p.dl, p.font(.semibold), 15, r.x + (r.w - tw) / 2, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), o);
        }
        p.y += 60;
    }

    fn button(p: *Page, label: []const u8, danger: bool) bool {
        const ctx = p.ctx;
        const f = p.font(.semibold);
        const tw = d.width(f, 14, label);
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = tw + 32, .h = 36 };
        const hb = d.hit(ctx, p.id(), r);
        qa.mark(r, "button:{s}", .{label});
        const base = if (danger) ctx.col(.danger) else ctx.col(.accent);
        d.rect(p.dl, r, if (hb.hovered) base.mix(d.Rgba.black, 0.12) else base, ctx.th.radius);
        d.text(p.dl, f, 14, r.x + 16, d.centerY(r, 14), if (danger) d.Rgba.white else ctx.col(.accent_text), label);
        return hb.clicked;
    }

    fn keyRow(p: *Page, action: []const u8, keys: []const u8) void {
        const ctx = p.ctx;
        d.text(p.dl, p.font(.medium), 15, p.x, p.y + 8, ctx.col(.text), action);
        var x = p.x + p.w;
        var it = std.mem.splitBackwardsScalar(u8, keys, '+');
        while (it.next()) |k| {
            const kw = d.width(p.font(.semibold), 13, k) + 18;
            x -= kw;
            const kr: d.Rect = .{ .x = x, .y = p.y + 4, .w = kw, .h = 28 };
            d.rect(p.dl, kr, ctx.col(.elevated), 6);
            d.rect(p.dl, .{ .x = kr.x, .y = kr.bottom() - 3, .w = kr.w, .h = 3 }, d.Rgba.black.alpha(0.25), 3);
            d.text(p.dl, p.font(.semibold), 13, kr.x + 9, kr.y + 5, ctx.col(.text), k);
            x -= 6;
        }
        p.y += 44;
    }
};

pub fn draw(ctx: *d.Ctx, previews: []const Preview) void {
    const s = &ctx.st.settings;
    const k = anim.to(anim.id("settings", 0), if (s.open) 1 else 0, 18);
    if (k < 0.01) return;
    if (!s.open) {
        // Desaparecendo: só um véu, sem interação.
        d.rect(ctx.fg, ctx.win, ctx.col(.surface).alpha(k), 0);
        return;
    }

    const win = ctx.win;
    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    _ = c.ImGui_Begin("##settings", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_End();
    const dl = c.ImGui_GetWindowDrawList();
    const saved_dl = ctx.dl;
    ctx.dl = dl;
    defer ctx.dl = saved_dl;

    // Entra com um leve zoom, como no Discord.
    const z = 1 - (1 - k) * 0.04;
    const bg = ctx.col(.surface);
    const opaque_bg = d.Rgba{ .r = bg.r, .g = bg.g, .b = bg.b, .a = @max(bg.a, 0.97) };
    d.rect(dl, win, opaque_bg.alpha(k), 0);

    const side_w = @max(220, win.w * 0.3);
    const side: d.Rect = .{ .x = win.x, .y = win.y, .w = side_w, .h = win.h };
    const sb = ctx.col(.sidebar);
    d.rect(dl, side, (d.Rgba{ .r = sb.r, .g = sb.g, .b = sb.b, .a = @max(sb.a, 0.97) }).alpha(k), 0);

    // Menu.
    var y = win.y + 60;
    const mx = side.right() - 210;
    const fam = ctx.ui;
    for (sections, 0..) |sec, si| {
        d.text(dl, fam.get(.bold), 11.5, mx + 10, y, ctx.col(.faint), sec.title);
        y += 24;
        for (sec.items, 0..) |it, ii| {
            const r: d.Rect = .{ .x = mx, .y = y, .w = 192, .h = 32 };
            const hb = d.hit(ctx, 100 + si * 20 + ii, r);
            qa.mark(r, "settings:{s}", .{it.label});
            if (hb.clicked) s.page = it.page;
            const sel = s.page == it.page;
            if (sel) d.rect(dl, r, ctx.col(.selected).mix(ctx.col(.text), 0.04), ctx.th.radius) else if (hb.hovered) d.rect(dl, r, ctx.col(.hover), ctx.th.radius);
            d.text(dl, fam.get(if (sel) .semibold else .medium), 15, r.x + 10, d.centerY(r, 15), if (sel) ctx.col(.text) else ctx.col(.muted), it.label);
            y += 34;
        }
        y += 8;
        d.line(dl, mx + 10, y, mx + 192, y, ctx.col(.border), 1);
        y += 14;
    }
    {
        const r: d.Rect = .{ .x = mx, .y = y, .w = 192, .h = 32 };
        const hb = d.hit(ctx, 99, r);
        qa.mark(r, "settings:Sair", .{});
        if (hb.hovered) d.rect(dl, r, ctx.col(.hover), ctx.th.radius);
        d.text(dl, fam.get(.medium), 15, r.x + 10, d.centerY(r, 15), ctx.col(.danger), "Sair");
        if (hb.clicked) ctx.st.showToast(ctx.now_ms, false, "isso aqui é só um protótipo, você não sai daqui não 😄", .{});
    }

    // Conteúdo com rolagem.
    const content: d.Rect = .{ .x = side.right(), .y = win.y, .w = win.w - side_w, .h = win.h };
    const cw = @min(740, content.w - 120);
    c.ImGui_SetCursorScreenPos(d.v(content.x, content.y));
    _ = c.ImGui_BeginChild("##settings-page", d.v(content.w, content.h), 0, c.ImGuiWindowFlags_NoBackground);
    const cdl = c.ImGui_GetWindowDrawList();
    const o = c.ImGui_GetCursorScreenPos();
    ctx.dl = cdl;
    var p: Page = .{ .ctx = ctx, .dl = cdl, .x = content.x + 40, .y = o.y + 60 + (1 - z) * 200, .w = cw };
    page(&p, previews);
    c.ImGui_SetCursorScreenPos(d.v(content.x, p.y + 60));
    c.ImGui_Dummy(d.v(1, 1));
    c.ImGui_EndChild();
    ctx.dl = dl;

    // Fechar (ESC).
    const cx = @min(content.x + 40 + cw + 60, win.right() - 40);
    const cr: d.Rect = .{ .x = cx - 18, .y = win.y + 60, .w = 36, .h = 36 };
    const hb = d.hit(ctx, 98, cr);
    qa.mark(cr, "settings-close", .{});
    c.ImDrawList_AddCircleEx(dl, d.v(cx, cr.y + 18), 17, (if (hb.hovered) ctx.col(.text) else ctx.col(.muted)).u(), 0, 2, 0);
    const xc = if (hb.hovered) ctx.col(.text) else ctx.col(.muted);
    d.line(dl, cx - 6, cr.y + 12, cx + 6, cr.y + 24, xc, 2);
    d.line(dl, cx + 6, cr.y + 12, cx - 6, cr.y + 24, xc, 2);
    const ew = d.width(fam.get(.bold), 12, "ESC");
    d.text(dl, fam.get(.bold), 12, cx - ew / 2, cr.bottom() + 8, ctx.col(.muted), "ESC");
    if (hb.clicked or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) ctx.act(.close_settings);
}

fn page(p: *Page, previews: []const Preview) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    switch (s.page) {
        .aparencia => {
            p.title("Aparência");
            p.heading("Modo");
            p.segmented(&.{ "Escuro", "Claro", "Seguir o sistema" }, &s.color_mode);
            p.heading("Tema");
            p.note("Cada tema muda o layout inteiro, não só as cores. Todos têm versão clara e escura.");
            themeGrid(p, previews);
            if (ctx.th.options.len > 0) {
                p.divider();
                var hbuf: [96]u8 = undefined;
                p.heading(std.fmt.bufPrint(&hbuf, "Opções do tema {s}", .{ctx.theme_name}) catch "Opções do tema");
                for (ctx.th.options, 0..) |o, i| {
                    const cur = ctx.th.option(o.name) orelse o.default;
                    var v = cur;
                    p.toggle(o.label, o.description, &v);
                    if (v != cur) ctx.act(.{ .set_theme_option = .{ .index = i, .value = v } });
                }
            }
            p.divider();
            p.heading("Escala da fonte");
            p.slider("Tamanho do texto", &s.font_scale, 0.8, 1.3, "{d:.0}%", 100);
            p.heading("Exibição das mensagens");
            p.toggle("Modo compacto", "Menos espaço entre grupos e avatares menores.", &s.compact);
            p.toggle("Mostrar avatares", "Exibe a foto ao lado do nome.", &s.show_avatars);
            p.toggle("Relógio de 24 horas", "Ex.: 21:30 em vez de 9:30 PM.", &s.clock_24h);
            p.heading("Layout");
            p.toggle("Lista de membros", "Mostra quem está no servidor (quando o tema tem uma).", &s.show_member_list);
            p.toggle("Barra de status", "Conexão, ping, RAM e relógio (quando o tema tem uma).", &s.show_status_bar);
        },
        .acessibilidade => {
            p.title("Acessibilidade");
            p.heading("Movimento");
            p.toggle("Reduzir movimento", "Desliga as animações de hover, rolagem e transições.", &s.reduce_motion);
            p.heading("Cores");
            p.slider("Saturação", &s.saturation, 0, 1, "{d:.0}%", 100);
            p.toggle("Cores dos cargos", "Pinta os nomes com a cor do cargo.", &s.role_colors);
            p.toggle("Sublinhar links", "Deixa os links sempre sublinhados.", &s.underline_links);
        },
        .chat => {
            p.title("Chat");
            p.heading("Mídia");
            p.toggle("Reproduzir GIFs automaticamente", "", &s.autoplay_gifs);
            p.toggle("Emojis animados", "", &s.animated_emoji);
            p.toggle("Pré-visualização de links", "", &s.link_previews);
            p.toggle("Mostrar embeds", "", &s.show_embeds);
            p.heading("Conteúdo");
            p.toggle("Sempre mostrar spoilers", "Revela o texto ||escondido|| sem passar o mouse.", &s.show_spoilers);
            p.toggle("Corretor ortográfico", "", &s.spellcheck);
            p.toggle("Enviar indicador de digitação", "Os outros veem quando você está digitando.", &s.send_typing);
        },
        .notificacoes => {
            p.title("Notificações");
            p.toggle("Notificações na área de trabalho", "Via D-Bus, sem o Chromium no meio.", &s.desktop_notifs);
            p.toggle("Contador de não lidas", "Mostra o número de menções no ícone.", &s.unread_badge);
            p.toggle("Piscar na barra de tarefas", "", &s.taskbar_flash);
            p.toggle("Sons", "Som ao receber mensagem e entrar em call.", &s.notif_sounds);
            p.toggle("Só menções", "Ignora mensagens que não citam você.", &s.mention_only);
        },
        .privacidade => {
            p.title("Privacidade e segurança");
            p.heading("Filtro de conteúdo explícito");
            p.radio(&.{ "Me proteja", "Amigos são legais", "Sem filtro" }, &.{ "Analisa mensagens diretas de todo mundo.", "Analisa só quem não é seu amigo.", "Não analisa nada." }, &s.explicit_filter);
            p.heading("Mensagens diretas");
            p.toggle("Permitir DMs de membros dos servidores", "", &s.dms_from_servers);
            p.toggle("Pedidos de mensagem", "Filtra DMs de quem você talvez não conheça.", &s.message_requests);
            p.toggle("Mostrar atividade atual", "\"Jogando…\", \"Ouvindo…\" no seu perfil.", &s.activity_status);
        },
        .voz => {
            p.title("Voz e vídeo");
            p.select("DISPOSITIVO DE ENTRADA", &.{ "Padrão do sistema (PipeWire)", "Microfone USB", "Headset" }, &s.input_device);
            p.select("DISPOSITIVO DE SAÍDA", &.{ "Padrão do sistema (PipeWire)", "Fones de ouvido", "Alto-falantes HDMI" }, &s.output_device);
            p.slider("Volume de entrada", &s.input_volume, 0, 2, "{d:.0}%", 100);
            p.slider("Volume de saída", &s.output_volume, 0, 2, "{d:.0}%", 100);
            p.heading("Modo de entrada");
            var mode: u8 = @intFromBool(s.push_to_talk);
            p.radio(&.{ "Detecção de voz", "Aperte para falar" }, &.{}, &mode);
            s.push_to_talk = mode == 1;
            p.toggle("Sensibilidade automática", "", &s.auto_sensitivity);
            if (!s.auto_sensitivity) p.slider("Sensibilidade", &s.sensitivity, 0, 1, "{d:.0}%", 100);
            p.heading("Processamento");
            p.toggle("Supressão de ruído (RNNoise)", "", &s.noise_suppression);
            p.toggle("Cancelamento de eco", "", &s.echo_cancel);
            p.note("A voz ainda não está conectada neste protótipo.");
        },
        .atalhos => {
            p.title("Atalhos de teclado");
            p.keyRow("Paleta de comandos", "Ctrl+K");
            p.keyRow("Configurações", "Ctrl+,");
            p.keyRow("Próximo tema", "F2");
            p.keyRow("Tema anterior", "Shift+F2");
            p.keyRow("Próxima aba", "Ctrl+Tab");
            p.keyRow("Aba anterior", "Ctrl+Shift+Tab");
            p.keyRow("Ir para a aba N", "Alt+1…9");
            p.keyRow("Fechar aba", "Ctrl+W");
            p.keyRow("Abrir canal em nova aba", "Ctrl+Clique");
            p.keyRow("Fechar aba com o mouse", "Botão do meio");
        },
        .idioma => {
            p.title("Idioma");
            p.radio(&.{ "Português (Brasil)", "English (US)", "Español" }, &.{}, &s.language);
            p.note("Por enquanto a interface está toda em português.");
        },
        .avancado => {
            p.title("Avançado");
            p.toggle("Modo desenvolvedor", "Mostra o ID das mensagens ao passar o mouse.", &s.developer_mode);
            p.toggle("Aceleração por hardware", "Desenha com a GPU (OpenGL). Precisa reiniciar.", &s.hardware_accel);
            p.toggle("Recarregar temas ao salvar", "Vigia themes/ e ~/.config/larpercord/themes com inotify.", &s.hot_reload);
        },
        .conta => account(p),
        .perfis => profile(p),
        .desempenho => performance(p),
        .sobre => about(p),
    }
}

fn themeGrid(p: *Page, previews: []const Preview) void {
    const ctx = p.ctx;
    const cols: usize = if (p.w > 600) 3 else 2;
    const gap: f32 = 14;
    const cw = (p.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const ch: f32 = cw * 0.62 + 48;
    for (previews, 0..) |pv, i| {
        const col = i % cols;
        const row = i / cols;
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(col)) * (cw + gap), .y = p.y + @as(f32, @floatFromInt(row)) * (ch + gap), .w = cw, .h = ch };
        const hb = d.hit(ctx, 500 + i, r);
        qa.mark(r, "theme-card:{s}", .{pv.name});
        if (hb.clicked) ctx.act(.{ .set_theme = i });
        const sel = i == ctx.theme_index;
        const k = anim.to(anim.id("tcard", i), if (sel) 1 else if (hb.hovered) 0.5 else 0, 18);
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 12);
        // Miniatura com as cores do tema.
        const m: d.Rect = .{ .x = r.x + 8, .y = r.y + 8, .w = r.w - 16, .h = r.h - 56 };
        miniature(p.dl, pv, m);
        d.border(p.dl, r, ctx.col(.accent).alpha(0.25 + 0.75 * k), 12, 1 + k * 1.5);
        d.text(p.dl, p.font(.semibold), 15, r.x + 12, r.bottom() - 42, ctx.col(.text), pv.name);
        _ = d.textClipped(p.dl, p.font(.regular), 12, r.x + 12, r.bottom() - 22, ctx.col(.muted), pv.description, r.w - 24);
        if (sel) {
            d.circle(p.dl, r.right() - 18, r.y + 18, 10, ctx.col(.accent));
            d.line(p.dl, r.right() - 22, r.y + 18, r.right() - 19, r.y + 21, ctx.col(.accent_text), 2);
            d.line(p.dl, r.right() - 19, r.y + 21, r.right() - 13, r.y + 14, ctx.col(.accent_text), 2);
        }
    }
    const rows = (previews.len + cols - 1) / cols;
    p.y += @as(f32, @floatFromInt(rows)) * (ch + gap) + 4;
}

/// Desenho em miniatura do layout de cada tema.
fn miniature(dl: *c.ImDrawList, pv: Preview, m: d.Rect) void {
    const radius: f32 = 8;
    d.rect(dl, m, if (pv.transparent) pv.accent.mix(pv.bg, 0.55) else pv.bg, radius);
    const u = m.w / 100;
    const line_col = pv.text.alpha(0.35);
    switch (pv.kind) {
        .classic => {
            d.rectFlags(dl, .{ .x = m.x, .y = m.y, .w = 9 * u, .h = m.h }, pv.rail, radius, c.ImDrawFlags_RoundLeft);
            for (0..4) |i| d.circle(dl, m.x + 4.5 * u, m.y + 7 * u + @as(f32, @floatFromInt(i)) * 9 * u, 3 * u, pv.accent.alpha(if (i == 0) 1 else 0.45));
            d.rect(dl, .{ .x = m.x + 9 * u, .y = m.y, .w = 22 * u, .h = m.h }, pv.sidebar, 0);
            for (0..5) |i| d.rect(dl, .{ .x = m.x + 12 * u, .y = m.y + 6 * u + @as(f32, @floatFromInt(i)) * 6 * u, .w = 15 * u, .h = 2.2 * u }, line_col, u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.circle(dl, m.x + 37 * u, yy, 2.6 * u, pv.accent.alpha(0.6));
                d.rect(dl, .{ .x = m.x + 42 * u, .y = yy - 2 * u, .w = (30 + @as(f32, @floatFromInt((i * 13) % 25))) * u, .h = 2.2 * u }, line_col, u);
            }
        },
        .glass => {
            const g = 2.5 * u;
            const card = pv.surface;
            d.rect(dl, .{ .x = m.x + g, .y = m.y + g, .w = 8 * u, .h = m.h - g * 2 - 7 * u }, card, 3 * u);
            d.rect(dl, .{ .x = m.x + g * 2 + 8 * u, .y = m.y + g, .w = 20 * u, .h = m.h - g * 2 - 7 * u }, card, 3 * u);
            const cx = m.x + g * 3 + 28 * u;
            d.rect(dl, .{ .x = cx, .y = m.y + g, .w = m.right() - cx - g, .h = 6 * u }, card, 3 * u);
            d.rect(dl, .{ .x = cx, .y = m.y + g * 2 + 6 * u, .w = m.right() - cx - g, .h = m.h - g * 4 - 13 * u }, card, 3 * u);
            d.rect(dl, .{ .x = m.x + g, .y = m.bottom() - g - 5 * u, .w = m.w - g * 2, .h = 5 * u }, card, 2.5 * u);
            for (0..4) |i| d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 18 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = (25 + @as(f32, @floatFromInt((i * 11) % 20))) * u, .h = 2 * u }, line_col, u);
        },
        .terminal => {
            d.rect(dl, .{ .x = m.x, .y = m.y, .w = m.w, .h = 5 * u }, pv.elevated, 0);
            d.rect(dl, .{ .x = m.x + 2 * u, .y = m.y + 1 * u, .w = 10 * u, .h = 3 * u }, pv.accent, 0);
            d.border(dl, .{ .x = m.x + 2 * u, .y = m.y + 7 * u, .w = 22 * u, .h = m.h - 18 * u }, pv.text.alpha(0.3), 0, 1);
            d.border(dl, .{ .x = m.x + 26 * u, .y = m.y + 7 * u, .w = m.w - 28 * u, .h = m.h - 18 * u }, pv.accent.alpha(0.8), 0, 1);
            for (0..6) |i| {
                const yy = m.y + 11 * u + @as(f32, @floatFromInt(i)) * 5.5 * u;
                d.rect(dl, .{ .x = m.x + 29 * u, .y = yy, .w = 6 * u, .h = 1.8 * u }, pv.text.alpha(0.3), 0);
                d.rect(dl, .{ .x = m.x + 37 * u, .y = yy, .w = 8 * u, .h = 1.8 * u }, pv.accent.alpha(0.7), 0);
                d.rect(dl, .{ .x = m.x + 47 * u, .y = yy, .w = (20 + @as(f32, @floatFromInt((i * 17) % 30))) * u, .h = 1.8 * u }, pv.text.alpha(0.55), 0);
            }
            d.rect(dl, .{ .x = m.x, .y = m.bottom() - 5 * u, .w = m.w, .h = 5 * u }, pv.elevated, 0);
        },
        .bubbles => {
            d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 3 * u, .w = m.w - 6 * u, .h = 7 * u }, pv.surface, 3.5 * u);
            for (0..4) |i| d.rect(dl, .{ .x = m.x + 5 * u + @as(f32, @floatFromInt(i)) * 14 * u, .y = m.y + 4.5 * u, .w = 12 * u, .h = 4 * u }, if (i == 0) pv.accent.alpha(0.3) else pv.text.alpha(0.08), 2 * u);
            d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 13 * u, .w = 24 * u, .h = m.h - 16 * u }, pv.surface, 4 * u);
            for (0..4) |i| d.rect(dl, .{ .x = m.x + 5 * u, .y = m.y + 16 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = 20 * u, .h = 5 * u }, if (i == 1) pv.accent else pv.text.alpha(0.06), 2.5 * u);
            const cx = m.x + 30 * u;
            d.rect(dl, .{ .x = cx, .y = m.y + 13 * u, .w = m.right() - cx - 3 * u, .h = m.h - 16 * u }, pv.surface, 4 * u);
            d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 18 * u, .w = 28 * u, .h = 6 * u }, pv.elevated, 3 * u);
            d.rect(dl, .{ .x = m.right() - 40 * u, .y = m.y + 27 * u, .w = 32 * u, .h = 6 * u }, pv.bubble, 3 * u);
            d.rect(dl, .{ .x = cx + 4 * u, .y = m.y + 36 * u, .w = 22 * u, .h = 6 * u }, pv.elevated, 3 * u);
        },
        .mirror => {
            d.rectFlags(dl, .{ .x = m.right() - 9 * u, .y = m.y, .w = 9 * u, .h = m.h }, pv.rail, radius, c.ImDrawFlags_RoundRight);
            for (0..4) |i| d.rect(dl, .{ .x = m.right() - 7.5 * u, .y = m.y + 4 * u + @as(f32, @floatFromInt(i)) * 9 * u, .w = 6 * u, .h = 6 * u }, pv.accent.alpha(if (i == 0) 1 else 0.4), u);
            d.rect(dl, .{ .x = m.right() - 31 * u, .y = m.y, .w = 22 * u, .h = m.h }, pv.sidebar, 0);
            d.rect(dl, .{ .x = m.right() - 28 * u, .y = m.y + 4 * u, .w = 15 * u, .h = 2.5 * u }, pv.accent, u);
            for (0..4) |i| d.rect(dl, .{ .x = m.right() - 28 * u, .y = m.y + 12 * u + @as(f32, @floatFromInt(i)) * 6 * u, .w = 14 * u, .h = 2 * u }, line_col, u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.rect(dl, .{ .x = m.x + 5 * u, .y = yy - 2.5 * u, .w = 5 * u, .h = 5 * u }, pv.accent.alpha(0.6), u);
                d.rect(dl, .{ .x = m.x + 13 * u, .y = yy - 1 * u, .w = (28 + @as(f32, @floatFromInt((i * 13) % 22))) * u, .h = 2.2 * u }, line_col, u);
            }
        },
        .office => {
            d.rectFlags(dl, .{ .x = m.x, .y = m.y, .w = 28 * u, .h = m.h }, pv.sidebar, radius, c.ImDrawFlags_RoundLeft);
            for (0..3) |i| {
                const yy = m.y + 5 * u + @as(f32, @floatFromInt(i)) * 6 * u;
                d.rect(dl, .{ .x = m.x + 3 * u, .y = yy, .w = 4 * u, .h = 4 * u }, pv.accent.mix(d.Rgba.white, 0.3), u);
                d.rect(dl, .{ .x = m.x + 9 * u, .y = yy + 1 * u, .w = 14 * u, .h = 2 * u }, d.Rgba.white.alpha(0.6), u);
            }
            for (0..5) |i| d.rect(dl, .{ .x = m.x + 3 * u, .y = m.y + 26 * u + @as(f32, @floatFromInt(i)) * 5.5 * u, .w = 22 * u, .h = 3.5 * u }, if (i == 1) pv.accent else d.Rgba.white.alpha(0.12), u);
            for (0..5) |i| {
                const yy = m.y + 8 * u + @as(f32, @floatFromInt(i)) * 10 * u;
                d.rect(dl, .{ .x = m.x + 32 * u, .y = yy - 2.5 * u, .w = 5 * u, .h = 5 * u }, pv.accent.alpha(0.5), u);
                d.rect(dl, .{ .x = m.x + 40 * u, .y = yy - 1 * u, .w = (28 + @as(f32, @floatFromInt((i * 13) % 22))) * u, .h = 2.2 * u }, pv.text.alpha(0.35), u);
            }
        },
        .zen => {
            const cx = m.x + m.w * 0.22;
            const cw = m.w * 0.56;
            d.rect(dl, .{ .x = cx, .y = m.y + 5 * u, .w = 20 * u, .h = 3 * u }, pv.text.alpha(0.7), u);
            for (0..5) |i| d.rect(dl, .{ .x = cx, .y = m.y + 14 * u + @as(f32, @floatFromInt(i)) * 7 * u, .w = cw * (0.5 + @as(f32, @floatFromInt((i * 7) % 5)) / 10), .h = 2.4 * u }, line_col, u);
            d.rect(dl, .{ .x = cx, .y = m.bottom() - 10 * u, .w = cw, .h = 6 * u }, pv.elevated, 3 * u);
        },
    }
}

fn account(p: *Page) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    const me = ctx.store.user(ctx.store.me) orelse return;
    p.title("Minha conta");
    const card: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 260 };
    d.rect(p.dl, card, ctx.col(.rail), 10);
    const banner: d.Rect = .{ .x = card.x, .y = card.y, .w = card.w, .h = 100 };
    c.ImDrawList_AddRectFilledMultiColor(p.dl, d.v(banner.x, banner.y), d.v(banner.right(), banner.bottom()), ctx.col(.accent).u(), ctx.th.role(3).u(), ctx.th.role(3).mix(d.Rgba.black, 0.3).u(), ctx.col(.accent).mix(d.Rgba.black, 0.3).u());
    d.rectFlags(p.dl, banner, ctx.col(.rail).alpha(0), 10, 0);
    d.circle(p.dl, card.x + 64, banner.bottom(), 46, ctx.col(.rail));
    w.avatar(ctx, p.dl, card.x + 64, banner.bottom(), 80, me.id, .circle, ctx.col(.rail), 1);
    d.text(p.dl, p.font(.bold), 20, card.x + 120, banner.bottom() + 10, ctx.col(.text), me.name);
    const er: d.Rect = .{ .x = card.x + 16, .y = banner.bottom() + 56, .w = card.w - 32, .h = 88 };
    d.rect(p.dl, er, ctx.col(.sidebar), 8);
    d.text(p.dl, p.font(.bold), 12, er.x + 14, er.y + 12, ctx.col(.muted), "NOME DE USUÁRIO");
    d.text(p.dl, p.font(.medium), 15, er.x + 14, er.y + 28, ctx.col(.text), me.name);
    d.text(p.dl, p.font(.bold), 12, er.x + 14, er.y + 52, ctx.col(.muted), "E-MAIL");
    d.text(p.dl, p.font(.medium), 15, er.x + 14, er.y + 66, ctx.col(.text), if (s.streamer_mode) "••••••••••@••••••.com" else "voce@exemplo.com");
    p.y += card.h + 24;
    p.toggle("Modo streamer", "Esconde informações pessoais na tela.", &s.streamer_mode);
    p.heading("Senha e autenticação");
    _ = p.button("Alterar senha", false);
    p.y += 52;
    p.heading("Sessão");
    p.note(if (ctx.store.demo) "Você está no modo demonstração." else "Sair apaga o token guardado neste computador.");
    if (p.button("Sair", true)) ctx.act(.logout);
    p.y += 52;
    p.heading("Remoção de conta");
    if (p.button("Excluir conta", true)) ctx.st.showToast(ctx.now_ms, false, "calma, ninguém vai excluir nada 😅", .{});
    p.y += 44;
}

fn profile(p: *Page) void {
    const ctx = p.ctx;
    p.title("Perfis");
    p.note("Como os outros veem você.");
    const me = ctx.store.user(ctx.store.me) orelse return;
    const card: d.Rect = .{ .x = p.x, .y = p.y, .w = @min(340, p.w), .h = 300 };
    d.shadow(p.dl, card, 12, 14, ctx.col(.shadow));
    d.rect(p.dl, card, ctx.col(.sidebar), 12);
    c.ImDrawList_AddRectFilledMultiColor(p.dl, d.v(card.x, card.y), d.v(card.right(), card.y + 90), ctx.th.role(1).u(), ctx.col(.accent).u(), ctx.col(.accent).u(), ctx.th.role(1).u());
    w.avatar(ctx, p.dl, card.x + 52, card.y + 92, 72, me.id, .circle, ctx.col(.sidebar), 1);
    d.text(p.dl, p.font(.bold), 20, card.x + 16, card.y + 140, ctx.col(.text), me.name);
    d.text(p.dl, p.font(.regular), 14, card.x + 16, card.y + 166, ctx.col(.muted), me.activity orelse "");
    d.line(p.dl, card.x + 16, card.y + 196, card.right() - 16, card.y + 196, ctx.col(.border), 1);
    d.text(p.dl, p.font(.bold), 12, card.x + 16, card.y + 210, ctx.col(.text), "SOBRE MIM");
    d.text(p.dl, p.font(.regular), 14, card.x + 16, card.y + 230, ctx.col(.muted), "fazendo um discord de 40 MB 🌸");
    p.y += card.h + 20;
}

fn performance(p: *Page) void {
    const ctx = p.ctx;
    p.title("Desempenho");
    p.note("Números ao vivo deste processo.");
    var buf: [96]u8 = undefined;
    const stats = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "RAM (PSS)", .value = std.fmt.bufPrint(buf[0..32], "{d}.{d} MB", .{ ctx.stats.ram_kb / 1024, (ctx.stats.ram_kb % 1024) * 10 / 1024 }) catch "" },
        .{ .label = "Tempo de CPU por quadro", .value = std.fmt.bufPrint(buf[32..64], "{d}.{d:0>2} ms", .{ ctx.stats.frame_us / 1000, (ctx.stats.frame_us % 1000) / 10 }) catch "" },
        .{ .label = "CPU parado", .value = "0% (dorme esperando eventos)" },
        .{ .label = "Mensagens por canal", .value = std.fmt.bufPrint(buf[64..96], "até {d} na memória", .{ctx.store.max_messages}) catch "" },
    };
    for (stats) |st| {
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 56 };
        d.rect(p.dl, r, ctx.col(.rail).alpha(0.6), ctx.th.radius + 2);
        d.text(p.dl, p.font(.medium), 15, r.x + 16, d.centerY(r, 15), ctx.col(.muted), st.label);
        const vw = d.width(p.font(.bold), 18, st.value);
        d.text(p.dl, p.font(.bold), 18, r.right() - 16 - vw, d.centerY(r, 18), ctx.col(.accent).mix(ctx.col(.text), 0.3), st.value);
        p.y += 64;
    }
    p.heading("Comparação (medido no mesmo PC)");
    bar(p, "Vesktop (Electron)", 1279, 1279);
    bar(p, "larperCord", @as(f32, @floatFromInt(ctx.stats.ram_kb)) / 1024, 1279);
}

fn bar(p: *Page, label: []const u8, mb: f32, max: f32) void {
    const ctx = p.ctx;
    d.text(p.dl, p.font(.medium), 14, p.x, p.y, ctx.col(.text), label);
    var buf: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d:.0} MB", .{mb}) catch "";
    const tw = d.width(p.font(.semibold), 14, t);
    d.text(p.dl, p.font(.semibold), 14, p.x + p.w - tw, p.y, ctx.col(.muted), t);
    p.y += 24;
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 12 };
    d.rect(p.dl, r, ctx.col(.rail), 6);
    d.rect(p.dl, .{ .x = r.x, .y = r.y, .w = @max(12, r.w * mb / max), .h = r.h }, if (mb > max * 0.5) ctx.col(.danger) else ctx.col(.online), 6);
    p.y += 30;
}

fn about(p: *Page) void {
    const ctx = p.ctx;
    p.title("Sobre");
    d.text(p.dl, p.font(.bold), 28, p.x, p.y, ctx.col(.accent), "larperCord");
    p.y += 40;
    p.note("Cliente de Discord nativo: Zig + SDL3 + Dear ImGui + FreeType.");
    p.note("Temas em KDL que reorganizam a interface inteira, recarregados ao salvar.");
    p.note("Versão 0.2.0 · protótipo (ainda sem conexão com o Discord).");
    p.divider();
    p.heading("Feito com");
    for ([_][]const u8{ "Zig 0.17", "SDL 3.4", "Dear ImGui 1.93 (dear_bindings)", "FreeType + fontconfig", "Inter, JetBrains Mono, Noto Color Emoji" }) |t| p.note(t);
}
