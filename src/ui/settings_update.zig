//! Configurações → Atualizações: versão, verificar, atualizar, reiniciar; e
//! Configurações → Novidades: o que mudou em cada versão.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const rich = @import("rich.zig");
const md = @import("../core/markdown.zig");
const updater = @import("../net/updater.zig");
const att = @import("attachments.zig");

const changelog_en = @embedFile("changelog_en");
const changelog_pt = @embedFile("changelog_pt");

pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const s = updater.snapshot();
    p.title(i18n.tr("Atualizações", "Updates"));
    var vb: [64]u8 = undefined;
    d.text(p.dl, p.font(.semibold), 16, p.x, p.y, ctx.col(.text), i18n.fmt(&vb, "Versão {s}", "Version {s}", .{updater.current}));
    p.y += 28;
    var mb: [120]u8 = undefined;
    const line: []const u8 = switch (s.phase) {
        .idle => i18n.tr("Ainda não verificou nesta sessão.", "Not checked yet in this session."),
        .checking => i18n.tr("Verificando…", "Checking…"),
        .up_to_date => i18n.tr("Você está na versão mais recente.", "You're on the latest version."),
        .available => i18n.fmt(&mb, "Atualização disponível: {s}", "Update available: {s}", .{s.latest()}),
        .downloading => i18n.fmt(&mb, "Baixando {s}… {d}%", "Downloading {s}… {d}%", .{ s.latest(), s.percent }),
        .ready => i18n.fmt(&mb, "{s} instalada. Reinicie para usar.", "{s} installed. Restart to use it.", .{s.latest()}),
        .failed => switch (s.err) {
            .network, .none => i18n.tr("Sem conexão com o GitHub. Tente de novo mais tarde.", "Couldn't reach GitHub. Try again later."),
            .no_release => i18n.tr("Nenhuma versão publicada ainda.", "No published version yet."),
            .bad_signature => i18n.tr("A assinatura da atualização não confere: nada foi instalado.", "The update's signature doesn't match: nothing was installed."),
            .bad_hash => i18n.tr("Um arquivo baixado não confere: nada foi instalado.", "A downloaded file doesn't match: nothing was installed."),
            .read_only => i18n.tr("Sem permissão para escrever na pasta do programa. Atualize com o script de instalação.", "No permission to write to the app's folder. Update with the install script."),
            .disk => i18n.tr("Não consegui gravar os arquivos da atualização.", "Couldn't write the update files."),
        },
    };
    const good = s.phase == .available or s.phase == .ready;
    d.text(p.dl, p.font(.regular), 14, p.x, p.y, if (s.phase == .failed) ctx.col(.danger) else if (good) ctx.col(.accent) else ctx.col(.muted), line);
    qa.mark(.{ .x = p.x, .y = p.y, .w = 300, .h = 20 }, "update-status:{t}", .{s.phase});
    p.y += 30;
    const working = s.phase == .checking or s.phase == .downloading;
    if (working) @import("anim.zig").every(100);
    if (s.phase == .available) {
        if (p.button(i18n.tr("Baixar e instalar", "Download and install"), false)) updater.install();
    }
    if (s.phase == .ready) {
        if (p.button(i18n.tr("Reiniciar agora", "Restart now"), false)) ctx.act(.restart);
    } else if (!working) {
        if (p.button(i18n.tr("Verificar atualizações", "Check for updates"), false)) updater.check();
    }
    p.toggle(i18n.tr("Verificar ao abrir", "Check when opening"), i18n.tr("Pergunta ao GitHub qual é a última versão ao abrir o app. Nenhum dado da conta vai junto.", "Asks GitHub for the latest version when the app opens. No account data is sent."), &ctx.st.settings.check_updates);
    p.divider();
    p.heading(i18n.tr("Reiniciar", "Restart"));
    p.note(i18n.tr("Fecha e abre o larperCord de novo. Se estiver em uma call, ela cai.", "Closes and reopens larperCord. If you're in a call, you'll leave it."));
    if (p.button(i18n.tr("Reiniciar o larperCord", "Restart larperCord"), false)) ctx.act(.restart);
    p.divider();
    p.note(i18n.tr("Toda atualização é assinada; uma versão sem a assinatura certa não é instalada.", "Every update is signed; a version without the right signature isn't installed."));
    if (p.button(i18n.tr("Ver as versões no GitHub", "See releases on GitHub"), false)) att.openUrl(updater.releases_page);
}

var spans_en: ?[]md.Span = null;
var spans_pt: ?[]md.Span = null;

pub fn changelog(p: anytype) void {
    const ctx = p.ctx;
    p.title(i18n.tr("Novidades", "What's new"));
    const en = i18n.en();
    const slot = if (en) &spans_en else &spans_pt;
    const text: []const u8 = if (en) changelog_en else changelog_pt;
    if (slot.* == null) slot.* = md.parse(std.heap.c_allocator, text) catch null;
    const spans = slot.* orelse return;
    const o: rich.Opts = .{
        .ctx = ctx,
        .family = ctx.ui,
        .size = 14,
        .line_h = 20,
        .color = ctx.col(.text).mix(ctx.col(.muted), 0.15),
        .underline_links = ctx.st.settings.underline_links,
    };
    const t = rich.layout(p.dl, ctx.store, ctx.th, spans, p.x, p.y, p.w, o, ctx.mouse);
    qa.mark(.{ .x = p.x, .y = p.y, .w = p.w, .h = t.h }, "changelog", .{});
    p.y += t.h + 16;
}
