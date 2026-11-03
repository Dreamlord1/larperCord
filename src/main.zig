const std = @import("std");
const builtin_themes = @import("builtin_themes");
const App = @import("app.zig").App;
const Options = @import("app.zig").Options;

const usage =
    \\larperCord — cliente de Discord nativo e leve
    \\
    \\uso: larpercord [opções]
    \\  --theme NOME      começa com esse tema (classico, vidro, terminal, bolhas, zen…)
    \\  --list-themes     lista os temas embutidos
    \\  --settings        abre já nas configurações
    \\  --shot ARQ.png    salva um print quando a tela estabilizar e sai
    \\  --mode MODO       claro ou escuro (ignora as configurações)
    \\  --qa              roda o teste automático da interface (prints em qa-out/)
    \\  --demo            usa os dados de demonstração mesmo com token
    \\  --no-live         desliga as mensagens automáticas do modo demonstração
    \\  --stats           mostra tempo até o primeiro quadro
    \\
    \\atalhos: Ctrl+K paleta · Ctrl+, configurações · F2 próximo tema
    \\         Ctrl+Tab abas · Alt+1..9 · Ctrl+W fecha aba
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var opts: Options = .{};
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--theme")) {
            opts.theme = it.next() orelse return fail("--theme precisa de um nome");
        } else if (std.mem.eql(u8, arg, "--shot")) {
            opts.shot = (it.next() orelse return fail("--shot precisa de um arquivo")).ptr;
            opts.live = false;
        } else if (std.mem.eql(u8, arg, "--no-live")) {
            opts.live = false;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const m = it.next() orelse return fail("--mode precisa de claro ou escuro");
            opts.mode = if (std.mem.eql(u8, m, "claro") or std.mem.eql(u8, m, "light")) .light else .dark;
        } else if (std.mem.eql(u8, arg, "--qa")) {
            opts.qa = true;
            opts.live = false;
            if (@import("c").SDL_getenv("SDL_VIDEO_DRIVER") == null) _ = @import("c").SDL_setenv_unsafe("SDL_VIDEO_DRIVER", "offscreen", 1);
        } else if (std.mem.eql(u8, arg, "--demo")) {
            opts.demo = true;
        } else if (std.mem.eql(u8, arg, "--settings")) {
            opts.settings = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            opts.stats = true;
        } else if (std.mem.eql(u8, arg, "--list-themes")) {
            for (builtin_themes.list) |t| std.debug.print("{s}\n", .{t.name});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else return fail("opção desconhecida (veja --help)");
    }

    const app = try App.create(std.heap.c_allocator, opts);
    defer app.destroy();
    const ok = app.run();
    if (!ok) std.process.exit(1);
}

fn fail(msg: []const u8) error{InvalidArgs} {
    std.debug.print("larpercord: {s}\n", .{msg});
    return error.InvalidArgs;
}
