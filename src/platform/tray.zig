//! O ícone na bandeja do sistema, pelo SDL_CreateTray. Só existe com a janela
//! escondida: com ela aberta nada fica carregado nem acordando o app (no Linux,
//! bandeja ativa faz o SDL acordar 20 vezes por segundo para atender o GTK).
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const platform = @import("window.zig");

var tray: ?*c.SDL_Tray = null;
var wake_type: u32 = 0;
/// O QA roda sem bandeja de verdade: aqui ele escolhe se ela "abriu".
pub var fake: ?bool = null;
var fake_on = false;

pub fn active() bool {
    return tray != null or fake_on;
}

fn onOpen(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    platform.Window.wake(wake_type, .show);
}

fn onQuit(_: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    platform.Window.wake(wake_type, .quit);
}

/// Tem bandeja para mostrar o ícone? (No QA, o que ele escolheu.)
pub fn hostAvailable() bool {
    return fake orelse sys.trayHostAvailable();
}

/// Põe o ícone. Falso: não tem como; fechar precisa sair de verdade.
pub fn show(wake: u32, open_label: [*:0]const u8, quit_label: [*:0]const u8) bool {
    if (active()) return true;
    if (fake) |f| {
        fake_on = f;
        return f;
    }
    if (!sys.trayHostAvailable()) {
        std.log.info("bandeja: nenhum painel para mostrar o ícone neste sistema", .{});
        return false;
    }
    wake_type = wake;
    const icon = platform.decodeIcon(platform.icon_32);
    defer if (icon) |i| c.SDL_DestroySurface(i);
    const t = c.SDL_CreateTray(icon, "larperCord") orelse {
        std.log.info("bandeja: SDL_CreateTray falhou: {s}", .{c.SDL_GetError()});
        return false;
    };
    const menu = c.SDL_CreateTrayMenu(t);
    const open_entry = if (menu != null) c.SDL_InsertTrayEntryAt(menu, -1, open_label, c.SDL_TRAYENTRY_BUTTON) else null;
    const quit_entry = if (menu != null) c.SDL_InsertTrayEntryAt(menu, -1, quit_label, c.SDL_TRAYENTRY_BUTTON) else null;
    if (open_entry == null or quit_entry == null) {
        // Um ícone sem menu não teria como voltar.
        std.log.info("bandeja: não deu para montar o menu: {s}", .{c.SDL_GetError()});
        c.SDL_DestroyTray(t);
        return false;
    }
    c.SDL_SetTrayEntryCallback(open_entry, onOpen, null);
    c.SDL_SetTrayEntryCallback(quit_entry, onQuit, null);
    tray = t;
    return true;
}

pub fn hide() void {
    fake_on = false;
    if (tray) |t| c.SDL_DestroyTray(t);
    tray = null;
}

/// Para a página de configurações: a resposta de há pouco (no máximo uma
/// pergunta a cada 5 s, já que a página redesenha o tempo todo).
var host_ms: i64 = -10_000;
var host_ok = true;

pub fn hostSeen(now_ms: i64) bool {
    if (now_ms - host_ms >= 5_000) {
        host_ms = now_ms;
        host_ok = hostAvailable();
    }
    return host_ok;
}
