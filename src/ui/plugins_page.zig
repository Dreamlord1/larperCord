//! Configurações → Plugins: os .lua encontrados na pasta, um interruptor
//! para cada (lembrado em plugins.kdl), "Recarregar" e o erro de cada um.
const std = @import("std");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const engine = @import("../plugins/engine.zig");

/// `p` é a página das configurações (settings.zig).
pub fn draw(p: anytype) void {
    const ctx = p.ctx;
    const e = engine.current orelse return;
    p.title("Plugins");
    p.note(i18n.tr("Scripts Lua que reagem a mensagens e criam comandos (/nome) e atalhos, sem recompilar.", "Lua scripts that react to messages and add commands (/name) and keybinds, no rebuild needed."));
    var buf: [600]u8 = undefined;
    p.note(i18n.fmt(&buf, "Pasta: {s}", "Folder: {s}", .{if (e.dir().len > 0) e.dir() else "—"}));
    if (p.button(i18n.tr("Recarregar", "Reload"), false)) {
        // A lista é refeita: este quadro termina aqui.
        e.reload();
        return;
    }
    p.y += 52;

    if (e.list.items.len == 0) {
        p.note(i18n.tr("Nenhum plugin encontrado. Ponha arquivos .lua na pasta acima e clique em Recarregar.", "No plugins found. Put .lua files in the folder above and click Reload."));
        p.note(i18n.tr("Guia da API e exemplos: docs/plugins.md", "API guide and examples: docs/plugins.md"));
    } else {
        p.heading(i18n.fmt(&buf, "{d} encontrados", "{d} found", .{e.list.items.len}));
        for (e.list.items) |pl| {
            var on = pl.enabled;
            p.toggle(pl.name, summary(&buf, pl), &on);
            if (on != pl.enabled) e.setEnabled(pl, on);
            if (pl.err()) |msg| errorText(p, pl.name, msg);
        }
    }

    p.divider();
    p.heading(i18n.tr("Sandbox", "Sandbox"));
    p.note(i18n.tr("Sem arquivos, programas nem rede: só string, table, math, utf8 e os.time/os.date.", "No files, programs or network: only string, table, math, utf8 and os.time/os.date."));
    p.note(i18n.tr("Um plugin travado é parado pelo limite de instruções; erros aparecem aqui.", "A stuck plugin is stopped by the instruction limit; errors show up here."));
    p.note(i18n.tr("larper.send só manda quando você usa um comando ou atalho do plugin.", "larper.send only sends when you use one of the plugin's commands or keybinds."));
    _ = ctx;
}

/// "ligado · /shrug · Ctrl+Shift+X" (ou desligado/parado).
fn summary(buf: []u8, pl: *const engine.Plugin) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, s: []const u8) void {
            const k = @min(s.len, b.len - at.*);
            @memcpy(b[at.*..][0..k], s[0..k]);
            at.* += k;
        }
    }.f;
    switch (pl.status()) {
        .off => return i18n.tr("desligado", "off"),
        .failed => return i18n.tr("parado por erro", "stopped by an error"),
        .running => put(buf, &n, i18n.tr("ligado", "on")),
    }
    for (pl.commands.items) |cmd| {
        put(buf, &n, " · ");
        put(buf, &n, cmd);
    }
    for (pl.keys.items) |*k| {
        put(buf, &n, " · ");
        put(buf, &n, k.label());
    }
    if (pl.n_message > 0) put(buf, &n, i18n.tr(" · lê mensagens", " · reads messages"));
    var kb: [32]u8 = undefined;
    put(buf, &n, std.fmt.bufPrint(&kb, " · {d} KB", .{pl.mem / 1024}) catch "");
    return buf[0..n];
}

/// O erro em vermelho, quebrado em até 3 linhas.
fn errorText(p: anytype, name: []const u8, msg: []const u8) void {
    const ctx = p.ctx;
    const font = p.font(.regular);
    const fs: f32 = 13;
    const top = p.y - 6;
    var y = top;
    var rest = msg;
    var lines: u8 = 0;
    while (rest.len > 0 and lines < 3) : (lines += 1) {
        // O maior pedaço que cabe, cortado num espaço quando dá.
        var cut = rest.len;
        while (cut > 1 and d.width(font, fs, rest[0..cut]) > p.w) {
            cut = std.mem.lastIndexOfScalar(u8, rest[0 .. cut - 1], ' ') orelse cut - 1;
            while (cut > 0 and cut < rest.len and (rest[cut] & 0xC0) == 0x80) cut -= 1;
        }
        if (cut == 0) cut = rest.len;
        _ = d.textClipped(p.dl, font, fs, p.x, y, ctx.col(.danger), rest[0..cut], p.w);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
        y += 18;
    }
    qa.mark(.{ .x = p.x, .y = top, .w = p.w, .h = y - top }, "plugin-error:{s}", .{name});
    p.y = y + 12;
}
