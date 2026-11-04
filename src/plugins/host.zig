//! O lado do app dos plugins (ver engine.zig): lê a pasta, guarda quem está
//! desligado, traduz teclas e entrega eventos, avisos e mensagens.
//! A pasta é ~/.config/larpercord/plugins (ou $XDG_CONFIG_HOME/larpercord/plugins);
//! a escolha de ligado/desligado fica em ~/.config/larpercord/plugins.kdl.
//! No QA a pasta é qa-out/plugins e nada é salvo.
const std = @import("std");
const c = @import("c");
const App = @import("../app.zig").App;
const engine = @import("engine.zig");
const types = @import("../core/types.zig");
const kdl = @import("../theme/kdl.zig");
const i18n = @import("../ui/i18n.zig");
const nowMs = @import("../net/fake_gateway.zig").nowMs;

pub const Engine = engine.Engine;

pub fn init(app: *App) void {
    app.plugins = Engine.init(app.gpa, .{
        .ctx = app,
        .notify = &notify,
        .send = &send,
        .where = &where,
        .key = &keyCode,
        .rescan = &rescan,
        .save = &save,
        .failed = &failed,
    });
    engine.current = &app.plugins;
    engine.lang_en = &i18n.en;
    // Prints da documentação: sempre iguais, sem os plugins de quem roda.
    if (app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    if (dirPath(app, &buf)) |d| app.plugins.setDir(d);
    // No QA a pasta começa vazia e o roteiro usa o botão Recarregar.
    if (app.opts.qa) return;
    loadPrefs(app);
    rescan(app);
}

fn configPath(buf: []u8, comptime tail: []const u8) ?[:0]const u8 {
    if (c.SDL_getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrintSentinel(buf, "{s}/larpercord/" ++ tail, .{std.mem.span(x)}, 0) catch null;
    const home = c.SDL_getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/larpercord/" ++ tail, .{std.mem.span(home)}, 0) catch null;
}

fn dirPath(app: *const App, buf: []u8) ?[:0]const u8 {
    if (app.opts.qa) return std.fmt.bufPrintSentinel(buf, "qa-out/plugins", .{}, 0) catch null;
    return configPath(buf, "plugins");
}

/// Lê os *.lua da pasta (em ordem alfabética) e recarrega todos.
fn rescan(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const e = &app.plugins;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(engine.Source) = .empty;
    var dbuf: [512]u8 = undefined;
    if (dirPath(app, &dbuf)) |dir| {
        var count: c_int = 0;
        if (c.SDL_GlobDirectory(dir.ptr, "*.lua", 0, &count)) |names| {
            defer c.SDL_free(@ptrCast(names));
            var list: std.ArrayList([]const u8) = .empty;
            for (0..@intCast(count)) |i| {
                const n = std.mem.span(names[i] orelse continue);
                // Só arquivos diretos da pasta (o glob não desce, mas confere).
                if (std.mem.indexOfScalar(u8, n, '/') != null or n.len > 120) continue;
                list.append(a, a.dupe(u8, n) catch continue) catch continue;
            }
            std.mem.sort([]const u8, list.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (list.items[0..@min(list.items.len, engine.max_plugins)]) |n| {
                var pbuf: [700]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, n }, 0) catch continue;
                var info: c.SDL_PathInfo = undefined;
                if (!c.SDL_GetPathInfo(path.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) continue;
                // Grande demais: entra na lista vazio (e dá erro de "arquivo grande").
                var src: []const u8 = "error('arquivo maior que 256 KB')";
                if (info.size <= engine.max_source) {
                    var size: usize = 0;
                    const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
                    defer c.SDL_free(data);
                    src = a.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch continue;
                }
                files.append(a, .{ .name = n, .src = src }) catch continue;
            }
        }
    }
    e.load(files.items, app.store.ready);
}

fn prefsPath(buf: []u8) ?[:0]const u8 {
    return configPath(buf, "plugins.kdl");
}

/// `plugin "nome.lua" enabled=#false`
fn loadPrefs(app: *App) void {
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const src = arena.allocator().dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return;
    const nodes = kdl.parse(arena.allocator(), src, null) catch return;
    for (nodes) |*n| {
        if (!std.mem.eql(u8, n.name, "plugin")) continue;
        const name = (n.arg(0) orelse continue).asString() orelse continue;
        if (n.flag("enabled") == false) app.plugins.setDisabledName(name);
    }
}

fn save(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.opts.qa or app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        var dbuf: [512]u8 = undefined;
        const d = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{path[0..slash]}, 0) catch return;
        _ = c.SDL_CreateDirectory(d.ptr);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    out.appendSlice(app.gpa, "// gerado pelo larperCord: plugins desligados\n") catch return;
    var it = app.plugins.disabled.keyIterator();
    while (it.next()) |k| {
        // Nomes que o KDL precisaria escapar ficam de fora.
        if (std.mem.indexOfAny(u8, k.*, "\"\\\n") != null) continue;
        out.print(app.gpa, "plugin \"{s}\" enabled=#false\n", .{k.*}) catch return;
    }
    _ = c.SDL_SaveFile(path.ptr, out.items.ptr, out.items.len);
}

// --- Host -------------------------------------------------------------------

fn notify(ctx: *anyopaque, plugin: []const u8, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), false, "{s}", "{s}", .{text});
    // Janela fora de foco: também uma notificação do sistema.
    const focused = (c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_INPUT_FOCUS) != 0;
    if (app.opts.qa or focused or !app.st.settings.desktop_notifs or app.notifiers.items.len >= 8) return;
    var tb: [160]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&tb, "larperCord · {s}", .{plugin}, 0) catch return;
    var cut = @min(text.len, 200);
    while (cut > 0 and cut < text.len and (text[cut] & 0xC0) == 0x80) cut -= 1;
    var bb: [208]u8 = undefined;
    const body = std.fmt.bufPrintSentinel(&bb, "{s}", .{text[0..cut]}, 0) catch return;
    var args = [_:null]?[*:0]const u8{ "notify-send", "--app-name=larperCord", "--", title.ptr, body.ptr };
    const proc = c.SDL_CreateProcess(@ptrCast(&args), false) orelse return;
    app.notifiers.append(app.gpa, proc) catch c.SDL_DestroyProcess(proc);
}

fn send(ctx: *anyopaque, channel: u64, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.store.ready) return false;
    const ch = if (channel != 0) channel else app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    if (cs.info.kind != .text) return false;
    app.sendTo(ch, text, 0);
    return true;
}

fn where(ctx: *anyopaque) engine.Where {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ch = app.st.activeChannel() orelse return .{};
    if (app.st.friends) return .{};
    const cs = app.store.channel(ch) orelse return .{};
    var w: engine.Where = .{ .channel = ch, .channel_name = cs.info.name };
    if (app.store.guild(cs.info.guild)) |g| {
        w.guild = g.id;
        w.guild_name = g.name;
    }
    return w;
}

fn failed(ctx: *anyopaque, plugin: []const u8, msg: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), true, "plugin {s}: {s}", "plugin {s}: {s}", .{ plugin, msg });
    std.log.warn("plugin {s}: {s}", .{ plugin, msg });
}

fn keyCode(name: []const u8) ?i32 {
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 'a' and ch <= 'z') return c.ImGuiKey_A + @as(i32, ch - 'a');
        if (ch >= '0' and ch <= '9') return c.ImGuiKey_0 + @as(i32, ch - '0');
    }
    if (name.len >= 2 and name[0] == 'f') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return c.ImGuiKey_F1 + @as(i32, n - 1);
        return null;
    }
    const named = [_]struct { n: []const u8, k: c_int }{
        .{ .n = "enter", .k = c.ImGuiKey_Enter },    .{ .n = "space", .k = c.ImGuiKey_Space },
        .{ .n = "tab", .k = c.ImGuiKey_Tab },        .{ .n = "backspace", .k = c.ImGuiKey_Backspace },
        .{ .n = "delete", .k = c.ImGuiKey_Delete },  .{ .n = "insert", .k = c.ImGuiKey_Insert },
        .{ .n = "home", .k = c.ImGuiKey_Home },      .{ .n = "end", .k = c.ImGuiKey_End },
        .{ .n = "pageup", .k = c.ImGuiKey_PageUp },  .{ .n = "pagedown", .k = c.ImGuiKey_PageDown },
        .{ .n = "up", .k = c.ImGuiKey_UpArrow },     .{ .n = "down", .k = c.ImGuiKey_DownArrow },
        .{ .n = "left", .k = c.ImGuiKey_LeftArrow }, .{ .n = "right", .k = c.ImGuiKey_RightArrow },
        .{ .n = ",", .k = c.ImGuiKey_Comma },        .{ .n = ".", .k = c.ImGuiKey_Period },
        .{ .n = "/", .k = c.ImGuiKey_Slash },        .{ .n = ";", .k = c.ImGuiKey_Semicolon },
        .{ .n = "-", .k = c.ImGuiKey_Minus },        .{ .n = "=", .k = c.ImGuiKey_Equal },
    };
    for (named) |x| if (std.mem.eql(u8, x.n, name)) return x.k;
    return null;
}

// --- Ganchos chamados pelo app ----------------------------------------------

/// MESSAGE_CREATE (antes de ir para o Store; os textos ainda são da mensagem).
pub fn onMessage(app: *App, m: types.Message) void {
    if (app.plugins.n_message == 0 or m.system != .none) return;
    const cs = app.store.channel(m.channel);
    const guild_id: types.Id = if (cs) |x| x.info.guild else 0;
    const g = if (guild_id != 0) app.store.guild(guild_id) else null;
    const msg: engine.Message = .{
        .id = m.id,
        .content = m.content,
        .author = m.author,
        .author_name = if (app.store.user(m.author)) |u| u.name else "?",
        .channel = m.channel,
        .channel_name = if (cs) |x| x.info.name else "",
        .guild = if (g) |x| x.id else 0,
        .guild_name = if (g) |x| x.name else "",
        .mine = m.author == app.store.me,
    };
    app.plugins.onMessage(&msg);
}

fn pressed(ctx: *anyopaque, k: *const engine.Keybind) bool {
    const io: *c.ImGuiIO = @ptrCast(@alignCast(ctx));
    if (io.*.KeyCtrl != k.ctrl or io.*.KeyShift != k.shift or io.*.KeyAlt != k.alt or io.*.KeySuper != k.super) return false;
    return c.ImGui_IsKeyPressedEx(k.key, false);
}

/// Atalhos dos plugins (no meio do quadro, depois da interface).
pub fn pollKeys(app: *App) void {
    if (app.plugins.n_keys == 0) return;
    const st = &app.st;
    if (st.settings.open or st.palette.open or app.login.visible()) return;
    app.plugins.pollKeys(app.io, &pressed);
}
