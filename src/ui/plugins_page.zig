//! Configurações → Plugins: um cartão para cada .lua da pasta, com o que está no
//! cabeçalho dele (nome, descrição, versão, o que pede), mesmo desligado, o
//! interruptor, o erro, os hosts a aprovar e o botão do painel.
const std = @import("std");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const inbox = @import("inbox.zig");
const plugin_panel = @import("plugin_panel.zig");
const engine = @import("../plugins/engine.zig");
const exemplos = @import("plugin_examples");
const c = @import("c");

const Plugin = engine.Plugin;

/// Rótulo de cada capacidade, e a explicação que aparece com o mouse em cima.
const Label = struct { cap: engine.Cap, pt: []const u8, en: []const u8, tip_pt: []const u8, tip_en: []const u8, strong: bool = false };
const labels = [_]Label{
    .{ .cap = .messages, .pt = "Lê mensagens", .en = "Reads messages", .tip_pt = "Vê as mensagens que chegam e as carregadas, de qualquer canal", .tip_en = "Sees incoming and loaded messages, in any channel", .strong = true },
    .{ .cap = .send, .pt = "Envia quando você pede", .en = "Sends when you ask", .tip_pt = "Só num comando, atalho, botão ou menu dele; nunca sozinho", .tip_en = "Only from its command, keybind, button or menu; never on its own", .strong = true },
    .{ .cap = .http, .pt = "Internet", .en = "Internet", .tip_pt = "Só HTTPS, só para os hosts abaixo, e depois que você aprovar", .tip_en = "HTTPS only, only to the hosts below, and after you approve", .strong = true },
    .{ .cap = .lsp, .pt = "Propõe um programa", .en = "Proposes a program", .tip_pt = "Só roda se você ligar em Erros no código", .tip_en = "Only runs if you turn it on under Code diagnostics", .strong = true },
    .{ .cap = .composer, .pt = "Escreve na caixa", .en = "Writes in the box", .tip_pt = "Põe texto na caixa de mensagem quando você pede; nunca envia", .tip_en = "Puts text in the message box when you ask; never sends it" },
    .{ .cap = .notify, .pt = "Avisos", .en = "Notifications", .tip_pt = "Avisos na janela e notificações do sistema", .tip_en = "In-app notices and desktop notifications" },
    .{ .cap = .storage, .pt = "Guarda dados", .en = "Stores data", .tip_pt = "Até 1 MB neste computador, separado por conta", .tip_en = "Up to 1 MB on this computer, per account" },
    .{ .cap = .timers, .pt = "Temporizadores", .en = "Timers", .tip_pt = "Roda depois de um tempo, só enquanto estiver ligado", .tip_en = "Runs after a delay, only while it's on" },
    .{ .cap = .panel, .pt = "Painel", .en = "Panel", .tip_pt = "Um painel lateral próprio", .tip_en = "Its own side panel" },
    .{ .cap = .menu, .pt = "Menus", .en = "Menus", .tip_pt = "Entradas no botão direito de mensagens e pessoas", .tip_en = "Entries on the right-click menu of messages and people" },
    .{ .cap = .decorate, .pt = "Marca mensagens", .en = "Decorates messages", .tip_pt = "Selos, notas e recolher, só na sua tela", .tip_en = "Badges, notes and collapsing, only on your screen" },
};

/// `p` é a página das configurações (settings.zig).
pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const e = engine.current orelse return;
    p.title("Plugins");
    para(p, i18n.tr("Scripts Lua que somam funções ao app, sem recompilar. Cada um roda numa thread só dos plugins: um plugin lento ou travado não segura a interface.", "Lua scripts that add features to the app, no rebuild needed. They run on a thread of their own: a slow or stuck plugin can't hold up the interface."), .muted);
    var buf: [600]u8 = undefined;
    para(p, i18n.fmt(&buf, "Pasta: {s}", "Folder: {s}", .{if (e.dir().len > 0) e.dir() else "—"}), .faint);
    p.y += 6;
    const reload_clicked = p.button(i18n.tr("Recarregar", "Reload"), false);
    if (missingExamples(e) > 0) {
        const lbl = i18n.tr("Instalar os incluídos", "Install bundled plugins");
        const rw = d.width(p.font(.semibold), 14, i18n.tr("Recarregar", "Reload")) + 32;
        const saved_x = p.x;
        p.x += rw + 10;
        const install = p.button(lbl, false);
        p.x = saved_x;
        if (install) {
            installExamples(e);
            return;
        }
    }
    if (reload_clicked) {
        // A lista é refeita: este quadro termina aqui.
        e.reload();
        return;
    }
    p.y += 50;
    if (missingExamples(e) > 0) {
        para(p, i18n.tr("Instalar copia para a pasta os que faltam: favoritos, lembretes, destaques, filtro, trechos, tradução e estatísticas. O que você já tem não é mexido.", "Install copies the missing ones to the folder: bookmarks, reminders, highlights, filter, snippets, translate and stats. What you already have is left alone."), .faint);
        p.y += 4;
    }

    if (e.list.items.len == 0) {
        para(p, i18n.tr("Nenhum plugin encontrado. Ponha arquivos .lua na pasta acima e clique em Recarregar.", "No plugins found. Put .lua files in the folder above and click Reload."), .faint);
        para(p, i18n.tr("Guia da API e exemplos: docs/plugins.md", "API guide and examples: docs/plugins.md"), .faint);
    } else {
        p.heading(i18n.fmt(&buf, "{d} encontrados", "{d} found", .{e.list.items.len}));
        for (e.list.items) |pl| card(p, e, pl);
    }

    p.divider();
    p.heading(i18n.tr("O que um plugin nunca faz", "What a plugin never does"));
    para(p, i18n.tr("Não vê o token nem o e-mail da conta, e não abre arquivos, programas nem conexões por conta própria.", "It doesn't see your token or email, and can't open files, programs or connections on its own."), .faint);
    para(p, i18n.tr("Não escreve na sua conta em segundo plano: enviar uma mensagem só vale direto de um comando, atalho, botão ou menu dele.", "It doesn't write to your account in the background: sending a message only works directly from its command, keybind, button or menu."), .faint);
    para(p, i18n.tr("Limite de instruções e de memória por plugin: quem passar é parado, e o erro aparece aqui.", "Instruction and memory limits per plugin: whoever goes over is stopped, and the error shows up here."), .faint);
    _ = ctx;
}

const Tone = enum { muted, faint };

fn para(p: anytype, text: []const u8, tone: Tone) void {
    const ctx = p.ctx;
    const h = inbox.wrapText(p.dl, p.font(.regular), 13.5, p.x, p.y, p.w, text, 6, if (tone == .muted) ctx.col(.muted) else ctx.col(.faint));
    p.y += h + 8;
}

fn card(p: anytype, e: *engine.Engine, pl: *Plugin) void {
    const ctx = p.ctx;
    const dl = p.dl;
    const pad: f32 = 14;
    const x = p.x + pad;
    const w = p.w - 2 * pad;
    const top = p.y;
    var y = top + 12;

    c.ImDrawList_ChannelsSplit(dl, 2);
    c.ImDrawList_ChannelsSetCurrent(dl, 1);

    // Linha de cima: bolinha do estado, nome, versão e o interruptor.
    const st = pl.status();
    const dot = switch (st) {
        .running => ctx.col(.online),
        .failed => ctx.col(.danger),
        .waiting => ctx.col(.idle),
        .off => ctx.col(.faint),
    };
    d.circle(dl, x + 5, y + 10, 4.5, dot);
    const title_f = p.font(.semibold);
    const sw_x = x + w - 40;
    const title = pl.title();
    const title_room = sw_x - (x + 18) - 12;
    const shown_w = d.textClipped(dl, title_f, 16, x + 18, y, ctx.col(.text), title, title_room);
    if (pl.man.version.len > 0) {
        var vb: [32]u8 = undefined;
        const v = std.fmt.bufPrint(&vb, "v{s}", .{pl.man.version}) catch "";
        _ = d.textClipped(dl, p.font(.regular), 12, x + 18 + shown_w + 8, y + 4, ctx.col(.faint), v, title_room - shown_w - 8);
    }
    switchButton(p, e, pl, sw_x, y);
    y += 24;

    // Arquivo e estado.
    var sb: [320]u8 = undefined;
    const state_text = stateLine(&sb, pl);
    _ = d.textClipped(dl, p.font(.regular), 12.5, x + 18, y, ctx.col(.faint), state_text, sw_x - x - 30);
    y += 22;

    // Descrição.
    const about = pl.about();
    if (about.len > 0) {
        y += inbox.wrapText(dl, p.font(.regular), 13.5, x, y, w, about, 6, ctx.col(.muted)) + 8;
    } else if (pl.man.legacy) {
        y += inbox.wrapText(dl, p.font(.regular), 13.5, x, y, w, i18n.tr("Arquivo sem cabeçalho: funciona com a API antiga (mensagens, comandos, envio e avisos). Para usar painéis, menus e o resto, veja docs/plugins.md.", "File without a manifest: it works with the old API (messages, commands, sending and notices). To use panels, menus and the rest, see docs/plugins.md."), 4, ctx.col(.muted)) + 8;
    }

    // O que pede.
    y = chips(p, pl, x, y, w);

    // Comandos e atalhos, se está rodando.
    if (pl.isRunning() and (pl.commands.items.len > 0 or pl.keys.items.len > 0)) {
        var cb: [320]u8 = undefined;
        const line = commandsLine(&cb, pl);
        y += inbox.wrapText(dl, p.font(.medium), 12.5, x, y, w, line, 3, ctx.col(.muted).mix(ctx.col(.text), 0.2)) + 8;
    }

    // Hosts: a aprovação é por plugin e por host.
    for (pl.man.hostList(), 0..) |h, i| y = hostRow(p, e, pl, h, i, x, y, w);

    // Painel.
    if (pl.tree != null) {
        const lbl = if (e.panel_open == pl) i18n.tr("Fechar painel", "Close panel") else i18n.tr("Abrir painel", "Open panel");
        const r: d.Rect = .{ .x = x, .y = y, .w = inbox.buttonWidth(ctx, lbl), .h = 28 };
        qa.mark(r, "plugin-open:{s}", .{pl.name});
        if (inbox.button(ctx, dl, 0xC8000 + @as(usize, pl.slot) * 16, r, lbl, false)) {
            const was_open = e.panel_open == pl;
            plugin_panel.toggle(pl);
            // Para ver o painel, as configurações saem da frente.
            if (!was_open) ctx.act(.close_settings);
        }
        y += 36;
    }

    // Erro.
    if (pl.err()) |msg| {
        y = errorText(p, pl.name, msg, x, y, w);
    } else {
        // Cabeçalho com problema: diz antes de a pessoa tentar ligar.
        var mb: [300]u8 = undefined;
        if (pl.man.problemText(&mb, i18n.en())) |msg| y = errorText(p, pl.name, msg, x, y, w);
    }

    // O fundo do cartão, agora que se sabe a altura.
    const box: d.Rect = .{ .x = p.x, .y = top, .w = p.w, .h = y + 4 - top };
    c.ImDrawList_ChannelsSetCurrent(dl, 0);
    const rad = @max(ctx.th.radius, 6);
    d.rect(dl, box, ctx.col(.rail).mix(ctx.col(.elevated), 0.35).alpha(if (st == .off) 0.45 else 0.8), rad);
    d.border(dl, box, if (st == .failed) ctx.col(.danger).alpha(0.7) else ctx.col(.border), rad, 1);
    c.ImDrawList_ChannelsMerge(dl);
    qa.mark(box, "plugin-card:{s}", .{pl.name});
    p.y = box.bottom() + 10;
}

fn switchButton(p: anytype, e: *engine.Engine, pl: *Plugin, x: f32, y: f32) void {
    const ctx = p.ctx;
    const dl = p.dl;
    const sw: d.Rect = .{ .x = x, .y = y, .w = 40, .h = 24 };
    const id = 0xC0000 + @as(usize, pl.slot) * 16;
    const hb = d.hit(ctx, id, sw);
    qa.mark(sw, "toggle:{s}", .{pl.name});
    const on = anim.to(anim.id("plugin-sw", id), if (pl.enabled) 1 else 0, 22);
    d.rect(dl, sw, ctx.col(.faint).mix(ctx.col(.accent), on), 12);
    const kx = sw.x + 12 + on * 16;
    d.circle(dl, kx, sw.y + 12, 9, d.Rgba.white);
    const ink = ctx.col(.faint).mix(ctx.col(.accent), on);
    if (on > 0.5) {
        d.line(dl, kx - 4, sw.y + 12, kx - 1, sw.y + 15, ink, 2);
        d.line(dl, kx - 1, sw.y + 15, kx + 4, sw.y + 9, ink, 2);
    } else {
        d.line(dl, kx - 3, sw.y + 9, kx + 3, sw.y + 15, ink, 2);
        d.line(dl, kx + 3, sw.y + 9, kx - 3, sw.y + 15, ink, 2);
    }
    d.tip(ctx, sw, if (pl.enabled) i18n.tr("Desligar", "Turn off") else i18n.tr("Ligar", "Turn on"), hb.hovered);
    if (hb.clicked) e.setEnabled(pl, !pl.enabled);
}

fn chips(p: anytype, pl: *const Plugin, x: f32, y_in: f32, w: f32) f32 {
    const ctx = p.ctx;
    const dl = p.dl;
    const f = p.font(.medium);
    const fs: f32 = 12;
    var cx = x;
    var y = y_in;
    var any = false;
    const line_h: f32 = 26;
    if (pl.man.legacy) {
        const lbl = i18n.tr("API antiga", "Old API");
        const cw = d.width(f, fs, lbl) + 16;
        const r: d.Rect = .{ .x = cx, .y = y, .w = cw, .h = 22 };
        d.border(dl, r, ctx.col(.border), 11, 1);
        d.text(dl, f, fs, r.x + 8, d.centerY(r, fs), ctx.col(.muted), lbl);
        d.tip(ctx, r, i18n.tr("Lê mensagens, envia quando você pede, dá avisos e propõe programas", "Reads messages, sends when you ask, shows notices and proposes programs"), ctx.hovering(r));
        qa.mark(r, "plugin-chip:{s}:legado", .{pl.name});
        cx += cw + 6;
        any = true;
    }
    for (labels) |l| {
        if (pl.man.legacy or !pl.man.has(l.cap)) continue;
        const lbl = i18n.tr(l.pt, l.en);
        const cw = d.width(f, fs, lbl) + 16;
        if (cx + cw > x + w and cx > x) {
            cx = x;
            y += line_h;
        }
        const r: d.Rect = .{ .x = cx, .y = y, .w = cw, .h = 22 };
        // Sem clique: um retângulo de dica.
        const over = ctx.hovering(r);
        d.rect(dl, r, if (l.strong) ctx.col(.accent).alpha(if (over) 0.3 else 0.18) else ctx.col(.hover).alpha(if (over) 1 else 0.6), 11);
        d.text(dl, f, fs, r.x + 8, d.centerY(r, fs), ctx.col(.text).mix(ctx.col(.muted), 0.15), lbl);
        d.tip(ctx, r, i18n.tr(l.tip_pt, l.tip_en), over);
        qa.mark(r, "plugin-chip:{s}:{t}", .{ pl.name, l.cap });
        cx += cw + 6;
        any = true;
    }
    return if (any) y + line_h + 2 else y;
}

fn hostRow(p: anytype, e: *engine.Engine, pl: *Plugin, host: []const u8, i: usize, x: f32, y: f32, w: f32) f32 {
    const ctx = p.ctx;
    const dl = p.dl;
    const ok = e.isApproved(pl.name, host);
    const row: d.Rect = .{ .x = x, .y = y, .w = w, .h = 44 };
    d.rect(dl, row, ctx.col(.elevated).alpha(0.7), 6);
    const sw: d.Rect = .{ .x = row.right() - 50, .y = row.y + 10, .w = 40, .h = 24 };
    _ = d.textClipped(dl, p.font(.semibold), 13, row.x + 10, row.y + 6, ctx.col(.text), host, row.w - 70);
    const hint = if (ok) i18n.tr("Aprovado: o plugin pode falar com este endereço", "Approved: the plugin can talk to this address") else i18n.tr("Não aprovado: nada sai enquanto estiver desligado", "Not approved: nothing goes out while this is off");
    _ = d.textClipped(dl, p.font(.regular), 12, row.x + 10, row.y + 24, if (ok) ctx.col(.online) else ctx.col(.faint), hint, row.w - 70);
    const id = 0xC4000 + @as(usize, pl.slot) * 16 + i;
    const hb = d.hit(ctx, id, sw);
    qa.mark(sw, "host:{s}:{s}", .{ pl.name, host });
    const on = anim.to(anim.id("plugin-host", id), if (ok) 1 else 0, 22);
    d.rect(dl, sw, ctx.col(.faint).mix(ctx.col(.accent), on), 12);
    d.circle(dl, sw.x + 12 + on * 16, sw.y + 12, 9, d.Rgba.white);
    d.tip(ctx, sw, if (ok) i18n.tr("Tirar a aprovação", "Remove approval") else i18n.tr("Aprovar este host", "Approve this host"), hb.hovered);
    if (hb.clicked) e.setApproved(pl, host, !ok);
    return y + row.h + 8;
}

fn loaded(e: *const engine.Engine, name: []const u8) bool {
    for (e.list.items) |pl| if (std.mem.eql(u8, pl.name, name)) return true;
    return false;
}

fn missingExamples(e: *const engine.Engine) usize {
    var n: usize = 0;
    for (exemplos.list) |ex| {
        if (!loaded(e, ex.name)) n += 1;
    }
    return n;
}

/// Grava só o que não existe: um plugin que a pessoa editou não é sobrescrito, e
/// os arquivos de versões antigas continuam onde estão.
fn installExamples(e: *engine.Engine) void {
    if (e.dir().len == 0) return;
    var dbuf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{e.dir()}, 0) catch return;
    _ = c.SDL_CreateDirectory(dir.ptr);
    for (exemplos.list) |ex| {
        if (loaded(e, ex.name)) continue;
        var buf: [600]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ e.dir(), ex.name }, 0) catch continue;
        var info: c.SDL_PathInfo = undefined;
        if (c.SDL_GetPathInfo(path.ptr, &info)) continue;
        _ = c.SDL_SaveFile(path.ptr, ex.source.ptr, ex.source.len);
    }
    e.reload();
}

/// "bookmarks.lua · ligado · 120 KB".
fn stateLine(buf: []u8, pl: *const Plugin) []const u8 {
    const state = switch (pl.status()) {
        .off => i18n.tr("desligado", "off"),
        .failed => i18n.tr("parado por erro", "stopped by an error"),
        .waiting => i18n.tr("liga ao entrar na conta", "starts when you log in"),
        .running => i18n.tr("ligado", "on"),
    };
    if (pl.status() == .running) return std.fmt.bufPrint(buf, "{s}  ·  {s}  ·  {d} KB", .{ pl.name, state, pl.memBytes() / 1024 }) catch pl.name;
    return std.fmt.bufPrint(buf, "{s}  ·  {s}", .{ pl.name, state }) catch pl.name;
}

/// "/shrug · Ctrl+Shift+X · LSP zig".
fn commandsLine(buf: []u8, pl: *const Plugin) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, s: []const u8) void {
            const k = @min(s.len, b.len - at.*);
            @memcpy(b[at.*..][0..k], s[0..k]);
            at.* += k;
        }
    }.f;
    for (pl.commands.items) |cmd| {
        if (n > 0) put(buf, &n, "  ·  ");
        put(buf, &n, cmd);
    }
    for (pl.keys.items) |*k| {
        if (n > 0) put(buf, &n, "  ·  ");
        put(buf, &n, k.label());
    }
    for (pl.lsp.items) |*srv| {
        if (n > 0) put(buf, &n, "  ·  ");
        put(buf, &n, "LSP ");
        put(buf, &n, srv.lang.slice());
    }
    return buf[0..n];
}

/// O erro em vermelho, quebrado em até 4 linhas.
fn errorText(p: anytype, name: []const u8, msg: []const u8, x: f32, y: f32, w: f32) f32 {
    const ctx = p.ctx;
    const h = inbox.wrapText(p.dl, p.font(.regular), 13, x, y, w, msg, 4, ctx.col(.danger));
    qa.mark(.{ .x = x, .y = y, .w = w, .h = h }, "plugin-error:{s}", .{name});
    return y + h + 8;
}
