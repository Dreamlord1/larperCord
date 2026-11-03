//! O app: liga janela, Store, gateway, temas e interface, e roda o laço.
//! O laço dorme em `SDL_WaitEvent` e só acorda com input, rede, mudança de
//! tema ou o tique do relógio/RAM; parado, a CPU fica em 0%.
const std = @import("std");
const c = @import("c");
const platform = @import("platform/window.zig");
const Store = @import("core/store.zig").Store;
const ev = @import("core/event.zig");
const types = @import("core/types.zig");
const Gateway = @import("net/fake_gateway.zig").Gateway;
const discord = @import("net/discord.zig");
const gw = @import("net/fake_gateway.zig");
const Queue = @import("net/queue.zig").Queue;
const themes = @import("theme/manager.zig");
const layout = @import("theme/layout.zig");
const fonts_mod = @import("ui/fonts.zig");
const State = @import("ui/state.zig").State;
const d = @import("ui/draw.zig");
const anim = @import("ui/anim.zig");
const root = @import("ui/root.zig");
const login_mod = @import("ui/login.zig");
const qa_mod = @import("ui/qa.zig");
const images = @import("ui/images.zig");
const i18n = @import("ui/i18n.zig");
const widgets = @import("ui/widgets.zig");
const settings_state = @import("ui/settings_state.zig");
const kdl = @import("theme/kdl.zig");

pub const Options = struct {
    theme: ?[]const u8 = null,
    shot: ?[*:0]const u8 = null,
    live: bool = true,
    /// Força claro/escuro (ignora as configurações).
    mode: ?@import("theme/theme.zig").Mode = null,
    /// Força o modo demonstração mesmo com token.
    demo: bool = false,
    stats: bool = false,
    settings: bool = false,
    /// Roda o robô de QA (ver qa_runner.zig).
    qa: bool = false,
    /// Mostra a tela de login sem usar o token salvo.
    login: bool = false,
    /// Força o idioma (ignora as configurações).
    lang: ?@import("ui/i18n.zig").Lang = null,
};

var wake_type_global: u32 = 0;

fn wakeTheme() void {
    platform.Window.wake(wake_type_global, .theme);
}

/// `none`: ainda na tela de login, sem conexão nenhuma.
const Net = union(enum) { none, fake: Gateway, real: discord.Gateway };

pub const App = struct {
    gpa: std.mem.Allocator,
    win: platform.Window,
    store: Store,
    st: State,
    themes: themes.Manager,
    fonts: fonts_mod.Fonts,
    events: Queue(ev.Event),
    net: Net,
    actions: std.ArrayList(ev.Action) = .empty,
    placed: std.ArrayList(layout.Placed) = .empty,
    stats: d.Stats = .{},
    opts: Options,
    io: *c.ImGuiIO,
    timer: c.SDL_TimerID = 0,
    started_ns: u64,
    layout_key: u32 = 0,
    login: login_mod.Login = .{},
    images: images.Cache = undefined,
    /// Arquivos escolhidos no seletor (o SDL pode responder de outra thread).
    picked: Queue([:0]u8) = undefined,
    /// Já tem um aviso da rede na fila do SDL: os próximos eventos só entram
    /// na fila de eventos, sem acordar a janela de novo.
    gw_signaled: std.atomic.Value(bool) = .init(false),
    /// Perfis já pedidos nesta sessão (um pedido por pessoa).
    asked_profiles: std.AutoHashMapUnmanaged(types.Id, void) = .empty,
    /// Cópia do tema com a cor de destaque e os cantos das configurações.
    th_custom: @import("theme/theme.zig").Theme = undefined,
    /// notify-send em andamento (recolhidos quando terminam).
    notifiers: std.ArrayList(*c.SDL_Process) = .empty,
    paste_n: u32 = 0,
    curl_on: bool = false,
    /// Guardar o token quando o Discord aceitar (o "Lembrar" do login).
    save_token: bool = false,
    /// Último aviso da rede (vira a mensagem de erro do login).
    last_notice: [200]u8 = undefined,
    last_notice_len: usize = 0,

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*App {
        const started = c.SDL_GetTicksNS();
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);

        app.win = try platform.Window.init("larperCord", 1280, 800);
        wake_type_global = app.win.wake_type;

        _ = c.ImGui_CreateContext(null);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.ConfigInputTextCursorBlink = false; // sem piscar = sem redesenho parado
        _ = c.cImGui_ImplSDL3_InitForSDLRenderer(app.win.window, app.win.renderer);
        _ = c.cImGui_ImplSDLRenderer3_Init(app.win.renderer);

        app.* = .{
            .gpa = gpa,
            .win = app.win,
            .store = Store.init(gpa),
            .st = .{ .gpa = gpa },
            .themes = try themes.Manager.init(gpa),
            .fonts = fonts_mod.Fonts.init(gpa, io.*.Fonts),
            .events = try Queue(ev.Event).init(gpa),
            .net = undefined,
            .opts = opts,
            .io = io,
            .started_ns = started,
        };

        // Configurações salvas (ignoradas nos prints, para serem reprodutíveis).
        var saved_theme: ?[]const u8 = null;
        var settings_arena = std.heap.ArenaAllocator.init(gpa);
        defer settings_arena.deinit();
        if (opts.shot == null and !opts.qa) saved_theme = app.loadSettings(settings_arena.allocator());
        app.themes.mode = app.wantedMode();
        // Já aqui: os dados da demonstração saem no idioma da interface.
        i18n.lang = if (opts.qa) .pt else opts.lang orelse i18n.fromSetting(app.st.settings.language);
        app.st.settings.open = opts.settings;
        const name = opts.theme orelse saved_theme orelse "classico";
        const want = app.themes.indexOf(name) orelse 0;
        if (!app.themes.load(want)) {
            std.log.err("{s}", .{app.themes.last_error orelse "tema inválido"});
            if (!app.themes.load(0)) return error.NoTheme;
        }
        app.applyThemeStyle();
        app.themes.watch(wakeTheme);

        // Com token salvo: conecta direto (a tela de abertura aparece enquanto
        // isso). Sem token: a tela de login. Prints e QA usam a demonstração.
        app.net = .none;
        const qa_login = opts.qa and if (c.SDL_getenv("QA_SUITE")) |q| std.mem.eql(u8, std.mem.span(q), "login") else false;
        if (opts.login or qa_login) {
            app.login.begin(.form);
        } else if (opts.demo or opts.qa or (opts.shot != null and c.SDL_getenv("LARPER_SHOT_REAL") == null)) {
            // (LARPER_SHOT_REAL=1: print com a conta de verdade, para depurar.)
            try app.startDemo();
        } else if (discord.loadToken()) |t| {
            try app.startReal(t);
            app.login.begin(.connecting);
        } else app.login.begin(.form);

        // Relógio e RAM da barra de status: um tique a cada 2 s.
        app.timer = c.SDL_AddTimer(2000, tick, app);
        app.stats.ram_kb = platform.selfPssKb();
        app.images = try images.Cache.init(app.win.renderer, app.win.wake_type);
        try app.images.start();
        app.picked = try Queue([:0]u8).init(std.heap.c_allocator);
        return app;
    }

    pub fn destroy(app: *App) void {
        _ = c.SDL_RemoveTimer(app.timer);
        app.asked_profiles.deinit(app.gpa);
        for (app.notifiers.items) |p| c.SDL_DestroyProcess(p);
        app.notifiers.deinit(app.gpa);
        app.stopNet();
        if (app.curl_on) c.curl_global_cleanup();
        app.login.clearToken();
        app.events.deinit();
        app.clearUploads();
        app.picked.deinit();
        app.images.deinit();
        app.store.deinit();
        app.themes.deinit();
        c.cImGui_ImplSDLRenderer3_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();
        c.ImGui_DestroyContext(null);
        app.win.deinit();
        app.gpa.destroy(app);
    }

    fn cmd(app: *App, command: ev.Command) void {
        switch (app.net) {
            .none => {},
            .fake => |*g| g.commands.push(command),
            .real => |*g| g.commands.push(command),
        }
    }

    /// Conecta na conta de verdade. O gateway passa a ser dono do token.
    fn startReal(app: *App, token: [:0]u8) !void {
        // Só inicia o libcurl/OpenSSL quando vai usar (~5 MB a menos no modo demonstração).
        if (!app.curl_on) _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        app.curl_on = true;
        app.store.demo = false;
        app.net = .{ .real = .{
            .commands = try Queue(ev.Command).init(app.gpa),
            .sink = .{ .ctx = app, .push = pushEvent },
            .token = token,
        } };
        try app.net.real.start();
    }

    fn startDemo(app: *App) !void {
        app.store.demo = true;
        app.net = .{ .fake = .{
            .commands = try Queue(ev.Command).init(app.gpa),
            .sink = .{ .ctx = app, .push = pushEvent },
            .live = app.opts.live,
            .rng = std.Random.DefaultPrng.init(@truncate(app.started_ns)),
        } };
        try app.net.fake.start();
    }

    fn stopNet(app: *App) void {
        switch (app.net) {
            .none => {},
            .fake => |*g| {
                g.stop();
                g.commands.deinit();
            },
            .real => |*g| {
                g.stop();
                g.commands.deinit();
            },
        }
        app.net = .none;
        // Eventos que ainda estavam na fila são da conexão que acabou.
        var stale: std.ArrayList(ev.Event) = .empty;
        defer stale.deinit(app.gpa);
        app.events.drain(&stale);
        for (stale.items) |e| app.store.apply(e, now()) catch {};
    }

    // --- Anexos ----------------------------------------------------------------

    /// Limite do Discord para quem não tem Nitro.
    const max_upload: u64 = 10 * 1024 * 1024;

    fn clearUploads(app: *App) void {
        for (app.st.uploads.items) |u| std.heap.c_allocator.free(u.path);
        app.st.uploads.clearRetainingCapacity();
    }

    /// Coloca um arquivo na bandeja da próxima mensagem.
    pub fn attachFile(app: *App, path: []const u8) void {
        const st = &app.st;
        if (st.uploads.items.len >= 10) return st.showToast(now(), true, "no máximo 10 arquivos por mensagem", "at most 10 files per message", .{});
        const z = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return;
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(z.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) {
            std.heap.c_allocator.free(z);
            return st.showToast(now(), true, "não consegui abrir esse arquivo", "couldn't open that file", .{});
        }
        if (info.size > max_upload) {
            std.heap.c_allocator.free(z);
            return st.showToast(now(), true, "arquivo maior que 10 MB (limite do Discord sem Nitro)", "file larger than 10 MB (Discord's limit without Nitro)", .{});
        }
        var up: @import("ui/state.zig").Upload = .{ .path = z, .size = info.size };
        // Imagem? Lê só as dimensões (para reservar o espaço na conversa).
        var size: usize = 0;
        if (c.SDL_LoadFile(z.ptr, &size)) |data| {
            defer c.SDL_free(data);
            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            if (c.stbi_info_from_memory(@ptrCast(data), @intCast(size), &w, &h, &comp) != 0 and w > 0 and h > 0) {
                up.width = @intCast(@min(w, 65535));
                up.height = @intCast(@min(h, 65535));
            }
        }
        st.uploads.append(app.gpa, up) catch std.heap.c_allocator.free(z);
        st.focus_input = true;
    }

    fn pickedCb(data: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(data.?));
        if (list == null) return;
        var i: usize = 0;
        while (list[i] != null) : (i += 1) {
            const z = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(list[i]), 0) catch continue;
            app.picked.push(z);
        }
        platform.Window.wake(app.win.wake_type, .media);
    }

    fn pickFiles(app: *App) void {
        if (app.opts.qa) return;
        c.SDL_ShowOpenFileDialog(pickedCb, app, app.win.window, null, 0, null, true);
    }

    /// Imagem colada: vai para um arquivo temporário e entra na bandeja.
    fn pasteImage(app: *App) void {
        var size: usize = 0;
        const data = c.SDL_GetClipboardData("image/png", &size) orelse return;
        defer c.SDL_free(data);
        const dir: []const u8 = if (c.SDL_getenv("XDG_RUNTIME_DIR")) |x| std.mem.span(x) else "/tmp";
        var pbuf: [512]u8 = undefined;
        app.paste_n += 1;
        // O nome do arquivo aparece na bandeja e vai junto para o Discord.
        const path = i18n.fmtZ(&pbuf, "{s}/larpercord-colado-{d}-{d}.png", "{s}/larpercord-pasted-{d}-{d}.png", .{ dir, c.getpid(), app.paste_n });
        if (path.len == 0) return;
        if (!c.SDL_SaveFile(path.ptr, data, size)) return app.st.showToast(now(), true, "não consegui colar a imagem", "couldn't paste the image", .{});
        app.attachFile(path);
    }

    /// Volta ao estado de antes do login: sem conta, sem abas, sem nada.
    fn resetSession(app: *App) void {
        app.asked_profiles.clearRetainingCapacity();
        app.clearUploads();
        app.st.viewer = null;
        app.store.deinit();
        app.store = Store.init(app.gpa);
        const st = &app.st;
        st.tabs.clearRetainingCapacity();
        st.tab = 0;
        st.guild = 0;
        st.last_channel.clearRetainingCapacity();
        st.collapsed.clearRetainingCapacity();
        st.scroll.clearRetainingCapacity();
        st.voice = null;
        st.popup = .none;
        st.palette.open = false;
        st.settings.open = false;
        st.reply_to = 0;
        st.editing = 0;
        st.selection = .{};
        @memset(&st.input, 0);
        st.input_sync = true;
    }

    /// O que a tela de login pediu.
    fn loginResult(app: *App, r: login_mod.Result) void {
        const lg = &app.login;
        switch (r) {
            .submit => {
                const t = lg.tokenText();
                if (t.len == 0) return lg.fail(i18n.tr("Cole o token no campo acima.", "Paste the token in the field above."));
                if (t.len < 50 or std.mem.indexOfAny(u8, t, " \t") != null)
                    return lg.fail(i18n.tr("Isso não parece um token do Discord.", "That doesn't look like a Discord token."));
                if (app.opts.qa) {
                    // O QA nunca fala com o Discord: simula a recusa.
                    lg.clearToken();
                    return lg.fail(i18n.tr("O Discord recusou esse token (teste).", "Discord rejected that token (test)."));
                }
                const owned = std.heap.c_allocator.dupeSentinel(u8, t, 0) catch return lg.fail(i18n.tr("Sem memória.", "Out of memory."));
                lg.clearToken();
                app.resetSession();
                app.save_token = lg.remember;
                app.last_notice_len = 0;
                app.startReal(owned) catch return lg.fail(i18n.tr("Não consegui iniciar a conexão.", "Couldn't start the connection."));
                lg.setPhase(.connecting);
            },
            .demo => {
                lg.clearToken();
                app.stopNet();
                app.resetSession();
                app.startDemo() catch return;
                lg.setPhase(.connecting);
            },
            .cancel => {
                app.stopNet();
                app.resetSession();
                lg.setPhase(.form);
            },
        }
    }

    fn pushEvent(ctx: *anyopaque, e: ev.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.events.push(e);
        if (!app.gw_signaled.swap(true, .acq_rel)) platform.Window.wake(app.win.wake_type, .gateway);
    }

    fn tick(data: ?*anyopaque, _: c.SDL_TimerID, interval: u32) callconv(.c) u32 {
        const app: *App = @ptrCast(@alignCast(data.?));
        const kb = platform.selfPssKb();
        const prev = @atomicLoad(u32, &app.stats.ram_kb, .monotonic);
        const S = struct {
            var last_minute: i64 = 0;
        };
        const minute = @divTrunc(gw.nowMs(), 60_000);
        const new_minute = minute != S.last_minute;
        S.last_minute = minute;
        if (kb / 100 != prev / 100 or new_minute) {
            @atomicStore(u32, &app.stats.ram_kb, kb, .monotonic);
            platform.Window.wake(app.win.wake_type, .tick);
        }
        return interval;
    }

    fn now() i64 {
        return gw.nowMs();
    }

    /// Ajustes do ImGui que dependem do tema.
    fn applyThemeStyle(app: *App) void {
        const th = app.themes.theme_();
        const style = c.ImGui_GetStyle();
        style.*.WindowPadding = .{ .x = 0, .y = 0 };
        style.*.WindowBorderSize = 0;
        style.*.ChildBorderSize = 0;
        style.*.FrameBorderSize = 0;
        style.*.FramePadding = .{ .x = 0, .y = 4 };
        style.*.ItemSpacing = .{ .x = 0, .y = 0 };
        style.*.ScrollbarSize = 6;
        style.*.ScrollbarRounding = 3;
        style.*.FontSizeBase = th.font_size;
        const col = &style.*.Colors;
        for (col) |*cc| cc.* = .{ .x = 0, .y = 0, .z = 0, .w = 0 };
        const v4 = struct {
            fn f(x: d.Rgba) c.ImVec4 {
                return .{ .x = x.r, .y = x.g, .z = x.b, .w = x.a };
            }
        }.f;
        col[c.ImGuiCol_Text] = v4(th.c(.text));
        col[c.ImGuiCol_TextDisabled] = v4(th.c(.faint));
        col[c.ImGuiCol_TextSelectedBg] = v4(th.c(.accent).alpha(0.35));
        col[c.ImGuiCol_InputTextCursor] = v4(th.c(.accent).mix(th.c(.text), 0.5));
        col[c.ImGuiCol_ScrollbarGrab] = v4(th.c(.text).alpha(0.12));
        col[c.ImGuiCol_ScrollbarGrabHovered] = v4(th.c(.text).alpha(0.2));
        col[c.ImGuiCol_ScrollbarGrabActive] = v4(th.c(.text).alpha(0.3));

        // Fontes do tema (carregadas sob demanda e reaproveitadas).
        _ = app.fonts.family(th.font_ui) catch app.fonts.family("Inter") catch {};
        _ = app.fonts.family(th.font_mono) catch app.fonts.family("monospace") catch {};
        // Fontes pedidas por componentes (`font="Liberation Serif"`).
        if (th.layout) |lay| app.loadNodeFonts(lay);
        // O fontconfig guarda o cache de todas as fontes do sistema (~MBs);
        // ele se reinicia sozinho se outro tema pedir uma família nova.
        c.FcFini();
        _ = c.malloc_trim(0);
        app.st.theme_gen +%= 1;
    }

    fn settingsPath(buf: []u8) ?[:0]const u8 {
        if (c.SDL_getenv("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrintSentinel(buf, "{s}/larpercord/settings.kdl", .{std.mem.span(x)}, 0) catch null;
        const home = c.SDL_getenv("HOME") orelse return null;
        return std.fmt.bufPrintSentinel(buf, "{s}/.config/larpercord/settings.kdl", .{std.mem.span(home)}, 0) catch null;
    }

    /// Lê ~/.config/larpercord/settings.kdl. Retorna o tema salvo, se houver.
    /// Modo de cor pedido nas configurações (resolvendo "seguir o sistema").
    fn wantedMode(app: *const App) @import("theme/theme.zig").Mode {
        if (app.opts.mode) |m| return m;
        return switch (app.st.settings.color_mode) {
            1 => .light,
            2 => if (c.SDL_GetSystemTheme() == c.SDL_SYSTEM_THEME_LIGHT) .light else .dark,
            else => .dark,
        };
    }

    fn loadSettings(app: *App, arena: std.mem.Allocator) ?[]const u8 {
        const s = &app.st.settings;
        var buf: [512]u8 = undefined;
        const path = settingsPath(&buf) orelse return null;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
        defer c.SDL_free(data);
        const src = arena.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
        const nodes = kdl.parse(arena, src, null) catch return null;
        var theme_name: ?[]const u8 = null;
        for (nodes) |*n| {
            if (std.mem.eql(u8, n.name, "settings")) {
                settings_state.apply(s, n);
                theme_name = n.str("theme");
            } else if (std.mem.eql(u8, n.name, "theme-options")) {
                // `theme-options "terminal" crt=#false ascii=#true`
                const name = (n.arg(0) orelse continue).asString() orelse continue;
                for (n.props) |p| if (p.value.asBool()) |v| app.themes.choose(name, p.key, v);
            }
        }
        return theme_name;
    }

    fn saveSettings(app: *App) void {
        if (app.opts.shot != null or app.opts.qa) return;
        var buf: [512]u8 = undefined;
        const path = settingsPath(&buf) orelse return;
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            var dbuf: [512]u8 = undefined;
            const dir = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{path[0..slash]}, 0) catch return;
            _ = c.SDL_CreateDirectory(dir.ptr);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(app.gpa);
        settings_state.write(&app.st.settings, app.themes.name(), &out, app.gpa) catch return;
        var it = app.themes.choices.iterator();
        while (it.next()) |e| {
            out.print(app.gpa, "theme-options \"{s}\"", .{e.key_ptr.*}) catch return;
            var oit = e.value_ptr.iterator();
            while (oit.next()) |o| out.print(app.gpa, " {s}={s}", .{ o.key_ptr.*, if (o.value_ptr.*) "#true" else "#false" }) catch return;
            out.append(app.gpa, '\n') catch return;
        }
        _ = c.SDL_SaveFile(path.ptr, out.items.ptr, out.items.len);
    }

    fn loadNodeFonts(app: *App, n: *const kdl.Node) void {
        if (n.str("font")) |f| {
            if (!std.mem.eql(u8, f, "mono") and !std.mem.eql(u8, f, "ui")) _ = app.fonts.family(f) catch {};
        }
        for (n.children) |*ch| app.loadNodeFonts(ch);
    }

    fn uiFamily(app: *App, name: []const u8) *fonts_mod.Family {
        return app.fonts.family(name) catch app.fonts.family("Inter") catch app.fonts.families.items[0];
    }

    fn setTheme(app: *App, i: usize) void {
        if (app.themes.load(i)) {
            app.applyThemeStyle();
            app.st.showToast(now(), false, "tema: {s}", "theme: {s}", .{app.themes.name()});
            app.saveSettings();
        } else app.st.showToast(now(), true, "{s}", "{s}", .{app.themes.last_error orelse i18n.tr("erro no tema", "theme error")});
    }

    // --- Ações da interface ------------------------------------------------

    fn openChannel(app: *App, id: types.Id, new_tab: bool) void {
        const cs = app.store.channel(id) orelse return;
        if (cs.info.kind != .text) return;
        app.st.guild = cs.info.guild;
        app.st.friends = false;
        // Lista de membros do servidor, vista deste canal.
        if (cs.info.guild != 0) app.cmd(.{ .subscribe_guild = .{ .guild = cs.info.guild, .channel = id } });
        app.st.last_channel.put(app.gpa, cs.info.guild, id) catch {};
        for (app.st.tabs.items, 0..) |t, i| if (t == id) {
            app.st.tab = i;
            return app.afterOpen(cs);
        };
        if (new_tab or app.st.tabs.items.len == 0) {
            app.st.tabs.append(app.gpa, id) catch return;
            app.st.tab = app.st.tabs.items.len - 1;
        } else app.st.tabs.items[app.st.tab] = id;
        app.afterOpen(cs);
    }

    fn afterOpen(app: *App, cs: anytype) void {
        app.store.markRead(cs.info.id);
        app.st.focus_input = true;
        if (cs.history == .none) {
            cs.history = .loading;
            app.cmd(.{ .fetch_history = cs.info.id });
        }
    }

    /// Envia uma mensagem: aparece na hora como "pendente" e vai pra rede.
    /// "@fulano" vira a menção de verdade (<@id>) quando o nome existe.
    fn sendTo(app: *App, ch: types.Id, text: []const u8, reply_to: types.Id) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(app.gpa);
        var words = std.mem.splitScalar(u8, text, ' ');
        var first = true;
        while (words.next()) |word| {
            if (!first) out.append(app.gpa, ' ') catch return;
            first = false;
            if (word.len > 1 and word[0] == '@') {
                var it = app.store.users.valueIterator();
                const found = while (it.next()) |u| {
                    if (std.mem.eql(u8, u.name, word[1..])) break u.id;
                } else null;
                if (found) |id| {
                    out.print(app.gpa, "<@{d}>", .{id}) catch return;
                    continue;
                }
            }
            out.appendSlice(app.gpa, word) catch return;
        }
        app.st.nonce += 1;
        // Os arquivos da bandeja vão junto: aparecem na hora na cópia pendente.
        const ca = std.heap.c_allocator;
        const ups = app.st.uploads.items;
        var atts: []types.Attachment = &.{};
        var files: [][:0]const u8 = &.{};
        if (ups.len > 0) {
            atts = ca.alloc(types.Attachment, ups.len) catch return;
            files = ca.alloc([:0]const u8, ups.len) catch return;
            for (ups, 0..) |u, i| {
                atts[i] = .{
                    .url = std.fmt.allocPrint(ca, "file://{s}", .{u.path}) catch return,
                    .filename = ca.dupe(u8, u.name()) catch return,
                    .width = u.width,
                    .height = u.height,
                    .size = @intCast(@min(u.size, std.math.maxInt(u32))),
                };
                files[i] = u.path;
            }
            // Os caminhos passam para o comando; a bandeja esvazia.
            app.st.uploads.clearRetainingCapacity();
        }
        app.store.addPending(ch, out.items, app.st.nonce, reply_to, now(), atts) catch return;
        app.st.scrollOf(ch).stick_bottom = true;
        const copy = ca.dupe(u8, out.items) catch return;
        app.cmd(.{ .send_message = .{ .channel = ch, .content = copy, .nonce = app.st.nonce, .reply_to = reply_to, .files = files } });
    }

    fn firstTextChannel(app: *App, guild: types.Id) ?types.Id {
        for (app.store.channelsOf(guild)) |id| {
            if (app.store.channel(id)) |cs| if (cs.info.kind == .text) return id;
        }
        return null;
    }

    fn handle(app: *App, a: ev.Action) void {
        const st = &app.st;
        if (app.opts.qa and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[ação] {t}\n", .{a});
        switch (a) {
            .select_guild => |g| {
                st.guild = g;
                // Mensagens diretas sem conversa aberta: começa pelos amigos.
                const ch = st.last_channel.get(g) orelse app.firstTextChannel(g) orelse return app.handle(.open_friends);
                if (g == 0 and st.last_channel.get(0) == null) return app.handle(.open_friends);
                app.openChannel(ch, false);
            },
            .want_profile => |user| {
                if (app.asked_profiles.contains(user)) return;
                app.asked_profiles.put(app.gpa, user, {}) catch return;
                app.cmd(.{ .fetch_profile = .{ .user = user, .guild = st.guild } });
            },
            .member_role => |mr| {
                app.store.memberRoleLocal(mr.guild, mr.user, mr.role, mr.add) catch return;
                app.cmd(.{ .member_role = .{ .guild = mr.guild, .user = mr.user, .role = mr.role, .add = mr.add } });
            },
            .load_older => |id| {
                const cs = app.store.channel(id) orelse return;
                if (cs.older != .idle or cs.history != .loaded) return;
                // A mais antiga que já veio do servidor (a pendente não tem ID).
                const before = for (cs.messages.items) |m| {
                    if (m.msg.id != 0) break m.msg.id;
                } else return;
                cs.older = .loading;
                app.cmd(.{ .fetch_older = .{ .channel = id, .before = before } });
            },
            .open_friends => {
                st.guild = 0;
                st.friends = true;
            },
            .accept_friend => |u| app.cmd(.{ .relationship = .{ .user = u, .accept = true } }),
            .remove_relationship => |u| app.cmd(.{ .relationship = .{ .user = u, .accept = false } }),
            .select_channel => |ch| {
                if (app.opts.qa and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[ação] select_channel ctrl={}\n", .{app.io.*.KeyCtrl});
                app.openChannel(ch, app.io.*.KeyCtrl);
            },
            .focus_tab => |i| if (i < st.tabs.items.len) {
                st.tab = i;
                st.friends = false;
                if (app.store.channel(st.tabs.items[i])) |cs| {
                    st.guild = cs.info.guild;
                    app.afterOpen(cs);
                }
            },
            .next_tab => |delta| if (st.tabs.items.len > 0) {
                const n: i32 = @intCast(st.tabs.items.len);
                app.handle(.{ .focus_tab = @intCast(@mod(@as(i32, @intCast(st.tab)) + delta, n)) });
            },
            .close_tab => |i| if (st.tabs.items.len > 1 and i < st.tabs.items.len) {
                _ = st.tabs.orderedRemove(i);
                if (st.tab >= st.tabs.items.len) st.tab = st.tabs.items.len - 1;
                app.handle(.{ .focus_tab = st.tab });
            },
            .send_message => |text| {
                defer app.gpa.free(text);
                const ch = st.activeChannel() orelse return;
                app.sendTo(ch, text, st.reply_to);
                st.reply_to = 0;
            },
            .reply => |id| {
                st.reply_to = id;
                if (st.editing != 0) {
                    st.editing = 0;
                    @memset(&st.input, 0);
                    st.input_sync = true;
                }
                st.focus_input = true;
            },
            .edit_message => |id| {
                const f = app.store.findAny(id) orelse return;
                const n = @min(f.m.msg.content.len, st.input.len - 1);
                @memcpy(st.input[0..n], f.m.msg.content[0..n]);
                st.input[n] = 0;
                st.editing = id;
                st.reply_to = 0;
                st.input_sync = true;
                st.focus_input = true;
            },
            .save_edit => |text| {
                defer app.gpa.free(text);
                const id = st.editing;
                st.editing = 0;
                const f = app.store.findAny(id) orelse return;
                const ch = f.cs.info.id;
                if (std.mem.eql(u8, f.m.msg.content, text)) return;
                app.store.editLocal(ch, id, text) catch return;
                const copy = std.heap.c_allocator.dupe(u8, text) catch return;
                app.cmd(.{ .edit_message = .{ .channel = ch, .id = id, .content = copy } });
            },
            .cancel_compose => {
                if (st.editing != 0) {
                    @memset(&st.input, 0);
                    st.input_sync = true;
                }
                st.editing = 0;
                st.reply_to = 0;
            },
            .delete_message => |id| {
                const f = app.store.findAny(id) orelse return;
                const ch = f.cs.info.id;
                app.store.apply(.{ .message_delete = .{ .channel = ch, .id = id, .local = true } }, now()) catch {};
                app.cmd(.{ .delete_message = .{ .channel = ch, .id = id } });
                st.showToast(now(), false, "mensagem excluída", "message deleted", .{});
            },
            .react => |r| {
                const f = app.store.findAny(r.id) orelse return;
                var mine = false;
                for (f.m.reactionSlice()) |*x| if (std.mem.eql(u8, x.text(), r.emoji.text())) {
                    mine = x.me;
                };
                app.store.react(f.m, r.emoji.text(), true, !mine);
                app.cmd(.{ .react = .{ .channel = f.cs.info.id, .id = r.id, .emoji = r.emoji, .add = !mine } });
            },
            .open_dm => |user| {
                for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (!cs.info.group and cs.info.recipient == user) {
                    return app.openChannel(id, false);
                };
                // Ainda não tem conversa: pede ao Discord e abre quando chegar.
                st.pending_dm = user;
                app.cmd(.{ .create_dm = user });
            },
            .send_dm => |dm| {
                defer app.gpa.free(dm.text);
                app.handle(.{ .open_dm = dm.user });
                const ch = st.activeChannel() orelse return;
                if (app.store.channel(ch)) |cs| if (!cs.info.group and cs.info.recipient == dm.user) return app.sendTo(ch, dm.text, 0);
                if (st.pending_dm == dm.user) st.showToast(now(), false, "abrindo a conversa… mande de novo quando ela abrir", "opening the conversation… send it again once it opens", .{});
            },
            .copy => |text| {
                defer app.gpa.free(text);
                const z = app.gpa.dupeSentinel(u8, text, 0) catch return;
                defer app.gpa.free(z);
                _ = c.SDL_SetClipboardText(z.ptr);
                st.showToast(now(), false, "copiado ✓", "copied ✓", .{});
            },
            .jump_to => |id| st.jump = id,
            .mark_read => |id| {
                if (app.store.channel(id)) |cs| {
                    cs.info.unread = false;
                } else if (app.store.guild(id)) |g| {
                    g.unread = false;
                    g.mentions = 0;
                    for (app.store.channelsOf(id)) |ch| app.store.markRead(ch);
                }
            },
            .typing => |id| {
                if (!st.settings.send_typing or app.store.demo) return;
                const now_ms = now();
                if (now_ms - st.typing_sent_ms < 8000) return;
                st.typing_sent_ms = now_ms;
                app.cmd(.{ .typing = id });
            },
            .toggle_voice => |ch| {
                st.voice = if (st.voice == ch) null else ch;
                app.cmd(.{ .join_voice = st.voice });
            },
            .leave_voice => {
                st.voice = null;
                app.cmd(.{ .join_voice = null });
            },
            .toggle_mute => st.muted = !st.muted,
            .toggle_deafen => st.deafened = !st.deafened,
            .toggle_category => |id| {
                if (st.collapsed.contains(id)) _ = st.collapsed.remove(id) else st.collapsed.put(app.gpa, id, {}) catch {};
            },
            .set_theme => |i| app.setTheme(i),
            .set_theme_option => |o| {
                const th = app.themes.theme_();
                if (o.index >= th.options.len) return;
                // O nome vive na arena do tema, que vai ser trocado ao recarregar.
                var buf: [64]u8 = undefined;
                const name = buf[0..@min(buf.len, th.options[o.index].name.len)];
                @memcpy(name, th.options[o.index].name[0..name.len]);
                if (app.themes.setOption(name, o.value)) app.applyThemeStyle();
                app.saveSettings();
            },
            .next_theme => |delta| {
                const n: i32 = @intCast(app.themes.entries.items.len);
                app.setTheme(@intCast(@mod(@as(i32, @intCast(app.themes.current)) + delta, n)));
            },
            .open_palette => {
                st.palette.open = true;
                st.palette.focus = false;
                @memset(&st.palette.query, 0);
                st.palette.selected = 0;
            },
            .close_palette => {
                st.palette.open = false;
                st.focus_input = true;
            },
            .open_settings => {
                st.palette.open = false;
                st.settings.open = true;
            },
            .close_settings => {
                st.settings.open = false;
                st.focus_input = true;
                app.saveSettings();
            },
            .pick_files => app.pickFiles(),
            .remove_upload => |i| if (i < st.uploads.items.len) {
                std.heap.c_allocator.free(st.uploads.items[i].path);
                _ = st.uploads.orderedRemove(i);
            },
            .paste_image => app.pasteImage(),
            .logout => {
                app.saveSettings();
                if (!app.opts.qa) discord.forgetToken();
                app.stopNet();
                app.resetSession();
                app.login.begin(.form);
                app.login.t = 10; // sem a abertura de novo
            },
        }
    }

    // --- Laço ----------------------------------------------------------------

    fn drainEvents(app: *App) void {
        var batch: std.ArrayList(ev.Event) = .empty;
        defer batch.deinit(app.gpa);
        app.events.drain(&batch);
        const was_ready = app.store.ready;
        var failed = false;
        for (batch.items) |e| {
            if (e == .notice) {
                app.st.showToast(now(), true, "{s}", "{s}", .{e.notice});
                const n = @min(e.notice.len, app.last_notice.len);
                @memcpy(app.last_notice[0..n], e.notice[0..n]);
                app.last_notice_len = n;
            }
            if (e == .status and e.status == .failed) failed = true;
            if (e == .message_create and app.store.ready) app.notify(e.message_create);
            if (app.opts.stats) switch (e) {
                .status => |st| std.log.info("conexão: {t}", .{st}),
                .notice => |n| std.log.info("aviso: {s}", .{n}),
                .latency => |l| std.log.info("ping: {d} ms", .{l}),
                .ready => |r| std.log.info("READY: {d} servidores, {d} canais, {d} usuários", .{ r.guilds.len, r.channels.len, r.users.len }),
                else => {},
            };
            app.store.apply(e, now()) catch {};
        }
        if (!was_ready and app.store.ready) {
            app.onReady();
            if (app.login.phase == .connecting) app.login.setPhase(.leaving);
            // O Discord aceitou: agora sim guarda o token, se pediram.
            if (app.save_token and app.net == .real) {
                app.save_token = false;
                switch (discord.saveToken(app.net.real.token)) {
                    .keyring => app.st.showToast(now(), false, "token guardado no chaveiro do sistema", "token saved to the system keyring", .{}),
                    .file => app.st.showToast(now(), false, "token guardado em ~/.config/larpercord/token", "token saved to ~/.config/larpercord/token", .{}),
                    .failed => app.st.showToast(now(), true, "não consegui guardar o token", "couldn't save the token", .{}),
                }
            }
        }
        if (failed and app.net == .real and !app.store.ready) {
            // Token recusado (ou erro fatal) antes de entrar: volta ao login.
            app.stopNet();
            app.resetSession();
            app.login.fail(if (app.last_notice_len > 0) app.last_notice[0..app.last_notice_len] else i18n.tr("Não deu pra entrar com esse token.", "Couldn't sign in with that token."));
            return;
        }
        // GUILD_DELETE/CHANNEL_DELETE: não deixa a interface apontando para
        // um servidor ou aba que o Discord acabou de tirar.
        if (app.st.guild != 0 and app.store.guild(app.st.guild) == null) app.st.guild = 0;
        var i: usize = 0;
        while (i < app.st.tabs.items.len) {
            if (app.store.channel(app.st.tabs.items[i]) != null) {
                i += 1;
                continue;
            }
            _ = app.st.tabs.orderedRemove(i);
            if (i < app.st.tab) app.st.tab -= 1;
        }
        if (app.st.tabs.items.len == 0) {
            app.st.tab = 0;
        } else if (app.st.tab >= app.st.tabs.items.len) {
            app.st.tab = app.st.tabs.items.len - 1;
        }
        // A DM que pedimos chegou: abre.
        if (app.st.pending_dm != 0) {
            for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (!cs.info.group and cs.info.recipient == app.st.pending_dm) {
                app.st.pending_dm = 0;
                app.openChannel(id, false);
                break;
            };
        }
        // Marca como lido o que chega no canal aberto.
        if (app.st.activeChannel()) |ch| app.store.markRead(ch);
    }

    /// DM ou menção chegando sem a pessoa olhando: a janela pisca na barra
    /// de tarefas e sai uma notificação do sistema (notify-send).
    fn notify(app: *App, m: types.Message) void {
        if (app.opts.qa or app.store.demo or m.author == app.store.me) return;
        const set = &app.st.settings;
        const cs = app.store.channel(m.channel) orelse return;
        if (app.st.muted_channels.contains(m.channel)) return;
        if (cs.info.guild != 0 and !mentionsMe(m.content, app.store.me)) return;
        const focused = (c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_INPUT_FOCUS) != 0;
        if (focused and app.st.activeChannel() == m.channel) return;
        if (set.taskbar_flash and !focused) _ = c.SDL_FlashWindow(app.win.window, c.SDL_FLASH_UNTIL_FOCUSED);
        if (!set.desktop_notifs or focused or app.notifiers.items.len >= 8) return;

        const who = if (app.store.user(m.author)) |u| u.name else "?";
        var tb: [160]u8 = undefined;
        const title = if (cs.info.guild == 0 and !cs.info.group)
            std.fmt.bufPrintSentinel(&tb, "{s}", .{who}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&tb, "{s} ({s}{s})", .{ who, if (cs.info.guild == 0) "" else "#", cs.info.name }, 0) catch return;
        // Texto curto, cortado sem quebrar um caractere no meio.
        var body_src: []const u8 = m.content;
        if (body_src.len == 0 and m.attachments.len > 0) body_src = i18n.tr("[anexo]", "[attachment]");
        var cut = @min(body_src.len, 200);
        while (cut > 0 and cut < body_src.len and (body_src[cut] & 0xC0) == 0x80) cut -= 1;
        var bb: [208]u8 = undefined;
        const body = std.fmt.bufPrintSentinel(&bb, "{s}{s}", .{ body_src[0..cut], if (cut < body_src.len) "…" else "" }, 0) catch return;
        var args = [_:null]?[*:0]const u8{ "notify-send", "--app-name=larperCord", "--", title.ptr, body.ptr };
        const proc = c.SDL_CreateProcess(@ptrCast(&args), false) orelse return;
        app.notifiers.append(app.gpa, proc) catch c.SDL_DestroyProcess(proc);
    }

    fn mentionsMe(content: []const u8, me: types.Id) bool {
        var b: [32]u8 = undefined;
        const a = std.fmt.bufPrint(&b, "<@{d}>", .{me}) catch return false;
        if (std.mem.indexOf(u8, content, a) != null) return true;
        const n = std.fmt.bufPrint(&b, "<@!{d}>", .{me}) catch return false;
        return std.mem.indexOf(u8, content, n) != null or std.mem.indexOf(u8, content, "@everyone") != null or std.mem.indexOf(u8, content, "@here") != null;
    }

    /// Recolhe os notify-send que já terminaram (sem deixar processo zumbi).
    fn reapNotifiers(app: *App) void {
        var i: usize = 0;
        while (i < app.notifiers.items.len) {
            const p = app.notifiers.items[i];
            if (c.SDL_WaitProcess(p, false, null)) {
                c.SDL_DestroyProcess(p);
                _ = app.notifiers.swapRemove(i);
            } else i += 1;
        }
    }

    /// Paleta de destaque das configurações (índice 1..8).
    pub const accents = [_]u32{ 0x5865F2, 0x3BA55C, 0xF0B232, 0xED4245, 0xEB459E, 0x9B59B6, 0x1ABC9C, 0xE67E22 };

    /// O tema do quadro: o atual, ou uma cópia com a cor de destaque e os
    /// cantos escolhidos nas configurações (vale para todos os temas).
    fn customTheme(app: *App) *const @import("theme/theme.zig").Theme {
        const base = app.themes.theme_();
        const set = &app.st.settings;
        if (set.accent == 0 and set.corners == 0) return base;
        app.th_custom = base.*;
        if (set.accent > 0 and set.accent <= accents.len) {
            const col = d.Rgba.hex(accents[set.accent - 1]);
            app.th_custom.colors.set(.accent, col);
            // Texto em cima do destaque: preto ou branco, o que contrastar mais.
            const lum = 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
            app.th_custom.colors.set(.accent_text, if (lum > 0.6) d.Rgba.black else d.Rgba.white);
        }
        switch (set.corners) {
            1 => app.th_custom.radius = 0,
            2 => app.th_custom.radius = 6,
            3 => app.th_custom.radius = 12,
            else => {},
        }
        return &app.th_custom;
    }

    fn onReady(app: *App) void {
        if (!app.store.demo) {
            // Conta real: começa pelas DMs (ou pelo primeiro servidor).
            const g0: types.Id = if (app.store.channelsOf(0).len > 0) 0 else if (app.store.guilds.items.len > 0) app.store.guilds.items[0].id else 0;
            app.handle(.{ .select_guild = g0 });
            return;
        }
        const g0 = app.store.guilds.items[0].id;
        app.st.guild = g0;
        // Algumas abas abertas para mostrar o recurso.
        for ([_]usize{ 4, 9, 5 }) |ci| app.openChannel(gw.channelId(0, ci), true);
        app.handle(.{ .focus_tab = 0 });
        const call = gw.channelId(0, 13);
        _ = call;
    }

    /// Monta uma cena para prints de documentação (LARPER_SCENE=…): abre
    /// popups e posiciona o mouse, já que o print não tem ninguém clicando.
    fn scene(app: *App, settled: bool) void {
        const which = std.mem.span(c.SDL_getenv("LARPER_SCENE") orelse return);
        // "firstdm": abre a primeira DM (mede a área de mensagens diretas).
        if (std.mem.eql(u8, which, "firstdm")) {
            const F = struct {
                var done = false;
            };
            if (!F.done and app.store.channelsOf(0).len > 0) {
                F.done = true;
                app.openChannel(app.store.channelsOf(0)[0], false);
            }
            return;
        }
        // "guild": abre o primeiro servidor (testa histórico e lista de membros).
        if (std.mem.eql(u8, which, "guild")) {
            const G = struct {
                var done = false;
            };
            if (!G.done and app.store.guilds.items.len > 0) {
                G.done = true;
                app.handle(.{ .select_guild = app.store.guilds.items[0].id });
            }
            return;
        }
        // As outras cenas esperam a conversa carregar.
        if (!settled) return;
        const ch = app.st.activeChannel() orelse return;
        const cs = app.store.channel(ch) orelse return;
        const items = cs.messages.items;
        if (items.len < 4) return;
        const last = &items[items.len - 1];
        const prev = &items[items.len - 3];
        const S = struct {
            var done = false;
        };
        if (std.mem.eql(u8, which, "hover")) c.ImGuiIO_AddMousePosEvent(app.io, 700, 690);
        if (S.done) return;
        S.done = true;
        if (std.mem.eql(u8, which, "menu")) {
            app.st.popup = .{ .menu = .{ .kind = .message, .id = prev.msg.id, .x = 620, .y = 330 } };
        } else if (std.mem.eql(u8, which, "profile")) {
            app.st.popup = .{ .profile = .{ .user = 1001, .x = 700, .y = 200 } };
        } else if (std.mem.eql(u8, which, "emoji")) {
            app.st.popup = .{ .emoji = .{ .target = 0, .x = 1000, .y = 730 } };
        } else if (std.mem.eql(u8, which, "reply")) {
            app.handle(.{ .reply = prev.msg.id });
            const t = i18n.tr("isso aqui tá **muito** bom 😍", "this is **really** good 😍");
            @memcpy(app.st.input[0..t.len], t);
            app.st.input_sync = true;
        } else if (std.mem.eql(u8, which, "select")) {
            app.st.selection = .{ .channel = ch, .a_id = prev.msg.id, .a_off = 3, .b_id = last.msg.id, .b_off = @intCast(@min(last.msg.content.len, 12)) };
        } else if (std.mem.eql(u8, which, "opcoes")) {
            app.st.settings.open = true;
            app.st.settings.page = .aparencia;
            c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -6);
            c.ImGuiIO_AddMousePosEvent(app.io, 900, 400);
        } else if (std.mem.eql(u8, which, "dm")) {
            app.handle(.{ .select_guild = 0 });
        }
    }

    var prof_frame: u64 = 0;
    var prof_render: u64 = 0;
    var prof_gpu: u64 = 0;
    var prof_cmds: u64 = 0;
    var prof_texs: u64 = 0;
    var prof_vtx: u64 = 0;

    pub fn run(app: *App) bool {
        var runner: @import("qa_runner.zig").Runner = .{};
        @import("ui/root.zig").profile = app.opts.stats;
        widgets.no_pics = c.SDL_getenv("LARPER_NO_PICS") != null;
        widgets.square_pics = c.SDL_getenv("LARPER_SQUARE") != null;
        if (app.opts.qa) {
            @import("ui/qa.zig").enabled = true;
            _ = c.SDL_CreateDirectory("qa-out");
        }
        var pending: u32 = 3;
        var running = true;
        var last = c.SDL_GetTicksNS();
        var frames: u32 = 0;
        var settled_frames: u32 = 0;
        var first_frame_logged = false;
        var login_result: ?login_mod.Result = null;
        var lang_setting: i16 = -1;
        // LARPER_BENCH=1: redesenha sem parar (medir o custo de um quadro parado).
        const bench = c.SDL_getenv("LARPER_BENCH") != null;
        // O que chega da rede (presença, digitando, lista de membros) redesenha
        // no máximo a cada `bg_frame_ms`; mouse e teclado redesenham na hora.
        const bg_frame_ms: i64 = 50;
        var bg_dirty = false;
        var last_frame_ms: i64 = 0;
        var was_active = false;
        // LARPER_RECORD=pasta: salva cada quadro da tela de login (a 30 qps fixos)
        // para montar o vídeo/GIF da documentação.
        const record_dir: ?[*:0]const u8 = c.SDL_getenv("LARPER_RECORD");
        var record_n: u32 = 0;

        while (running) {
            var e: c.SDL_Event = undefined;
            const busy = pending > 0 or anim.active or app.opts.shot != null or app.opts.qa or bench or
                (app.login.visible() and !app.st.settings.reduce_motion);
            // Dorme até o próximo quadro de um GIF, de uma animação lenta ou
            // do redesenho adiado da rede (o que vier primeiro).
            var due = @min(app.images.next_frame_ms, anim.next_wake_ms);
            if (bg_dirty) due = @min(due, last_frame_ms + bg_frame_ms);
            const wait = due -| now();
            var got = if (busy or wait <= 0)
                c.SDL_PollEvent(&e)
            else if (due != std.math.maxInt(i64))
                c.SDL_WaitEventTimeout(&e, @intCast(@min(wait, 1000)))
            else
                c.SDL_WaitEvent(&e);
            var input = false;
            while (got) {
                if (e.type == app.win.wake_type) {
                    switch (@as(platform.Wake, @enumFromInt(e.user.code))) {
                        .gateway => {
                            app.gw_signaled.store(false, .release);
                            app.drainEvents();
                            bg_dirty = true;
                        },
                        .theme => if (!app.st.settings.hot_reload) {} else if (app.themes.reload()) {
                            app.applyThemeStyle();
                            app.st.showToast(now(), false, "tema recarregado: {s}", "theme reloaded: {s}", .{app.themes.name()});
                        } else app.st.showToast(now(), true, "{s}", "{s}", .{app.themes.last_error orelse i18n.tr("erro no tema", "theme error")}),
                        .tick => pending = @max(pending, 1),
                        .media => bg_dirty = true,
                    }
                } else {
                    input = true;
                    _ = c.cImGui_ImplSDL3_ProcessEvent(&e);
                    if (e.type == c.SDL_EVENT_QUIT or e.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
                        running = false;
                        // Some da tela na hora; o resto do encerramento é por trás.
                        _ = c.SDL_HideWindow(app.win.window);
                    }
                    // Arquivo arrastado para a janela: vai para a bandeja.
                    if (e.type == c.SDL_EVENT_DROP_FILE and app.store.ready and app.st.activeChannel() != null)
                        if (e.drop.data) |p| app.attachFile(std.mem.span(p));
                }
                got = c.SDL_PollEvent(&e);
            }
            if (input) pending = 3;
            if (app.store.expireTyping(now())) pending = 2;
            if (app.notifiers.items.len > 0) app.reapNotifiers();

            app.images.now_ms = now();
            if (app.images.pump()) bg_dirty = true;
            {
                var picked: std.ArrayList([:0]u8) = .empty;
                defer picked.deinit(std.heap.c_allocator);
                app.picked.drain(&picked);
                for (picked.items) |p| {
                    defer std.heap.c_allocator.free(p);
                    if (app.store.ready) app.attachFile(p);
                }
                if (picked.items.len > 0) pending = 3;
            }
            // Só coisa da rede e o último quadro foi agora há pouco: espera.
            const now_ms = now();
            if (bg_dirty and pending == 0 and !was_active and app.opts.shot == null and !app.opts.qa and
                !app.login.visible() and now_ms - last_frame_ms < bg_frame_ms and now_ms < @min(app.images.next_frame_ms, anim.next_wake_ms)) continue;
            bg_dirty = false;
            last_frame_ms = now_ms;
            anim.now_ms = now_ms;
            anim.next_wake_ms = std.math.maxInt(i64);
            app.images.next_frame_ms = std.math.maxInt(i64);
            const t0 = c.SDL_GetTicksNS();
            anim.dt = std.math.clamp(@as(f32, @floatFromInt(t0 - last)) / 1e9, 0.001, 1.0 / 30.0);
            last = t0;
            anim.active = false;

            c.cImGui_ImplSDLRenderer3_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            // Configurações que valem para o quadro inteiro.
            const set = &app.st.settings;
            // Claro/escuro (inclusive quando o sistema troca, no modo "seguir").
            const mode = app.wantedMode();
            if (mode != app.themes.mode) {
                if (app.themes.setMode(mode)) app.applyThemeStyle();
            }
            d.text_scale = set.font_scale;
            // Idioma: o QA roda sempre em português (as marcações usam os rótulos).
            if (set.language != lang_setting) {
                lang_setting = set.language;
                i18n.lang = if (app.opts.qa) .pt else app.opts.lang orelse i18n.fromSetting(set.language);
                app.st.theme_gen +%= 1;
            }
            anim.instant = set.reduce_motion;
            @import("net/media_url.zig").allow_gif_hosts = set.gif_hosts;
            @import("ui/attachments.zig").hide_embeds = !set.show_embeds;
            app.store.keep_log = set.message_log;
            widgets.hour12 = !set.clock_24h;
            const key = set.layoutKey();
            if (key != app.layout_key) {
                app.layout_key = key;
                app.st.theme_gen +%= 1;
            }

            if (app.store.ready and (app.opts.stats or app.opts.shot != null)) app.scene(settled_frames >= 3);
            c.ImGui_NewFrame();
            qa_mod.beginFrame();
            if (app.store.ready) {
                const th = app.customTheme();
                var ctx: d.Ctx = .{
                    .th = th,
                    .theme_name = app.themes.name(),
                    .theme_names = app.themes.names.items,
                    .theme_index = app.themes.current,
                    .store = &app.store,
                    .st = &app.st,
                    .fonts = &app.fonts,
                    .ui = app.uiFamily(th.font_ui),
                    .mono = app.uiFamily(th.font_mono),
                    .dl = undefined,
                    .fg = undefined,
                    .io = app.io,
                    .mouse = app.io.*.MousePos,
                    .now_ms = now(),
                    .actions = &app.actions,
                    .stats = &app.stats,
                    .images = &app.images,
                    .win = undefined,
                };
                const tf = c.SDL_GetTicksNS();
                root.frame(&ctx, &app.placed, app.themes.previews.items);
                if (app.opts.stats) prof_frame += (c.SDL_GetTicksNS() - tf) / 1000;
            }
            if (app.login.visible()) {
                const th = app.themes.theme_();
                const result = login_mod.draw(&app.login, .{
                    .ui = app.uiFamily("Inter"),
                    .io = app.io,
                    .light = app.themes.mode == .light,
                    .reduce = set.reduce_motion,
                    .dt = if (record_dir != null) 1.0 / 30.0 else anim.dt,
                });
                _ = th;
                if (result) |r| login_result = r;
            }
            const tr0 = c.SDL_GetTicksNS();
            c.ImGui_Render();
            if (app.opts.stats) prof_render += (c.SDL_GetTicksNS() - tr0) / 1000;

            const r = app.win.renderer;
            _ = c.SDL_SetRenderScale(r, app.io.*.DisplayFramebufferScale.x, app.io.*.DisplayFramebufferScale.y);
            const bg = app.themes.theme_().c(.bg);
            _ = c.SDL_SetRenderDrawColorFloat(r, bg.r * bg.a, bg.g * bg.a, bg.b * bg.a, bg.a);
            _ = c.SDL_RenderClear(r);
            if (app.opts.stats) {
                const dd = c.ImGui_GetDrawData();
                var cmds: u64 = 0;
                var texs: u64 = 0;
                var vtx: u64 = 0;
                for (0..@intCast(dd.*.CmdLists.Size)) |li| {
                    const cl = dd.*.CmdLists.Data[li];
                    vtx += @intCast(cl.*.VtxBuffer.Size);
                    var prev_tex: u64 = 0;
                    for (0..@intCast(cl.*.CmdBuffer.Size)) |ci| {
                        const id = cl.*.CmdBuffer.Data[ci].TexRef._TexID;
                        cmds += 1;
                        if (id != prev_tex) texs += 1;
                        prev_tex = id;
                    }
                }
                prof_cmds += cmds;
                prof_texs += texs;
                prof_vtx += vtx;
            }
            const tg0 = c.SDL_GetTicksNS();
            c.cImGui_ImplSDLRenderer3_RenderDrawData(c.ImGui_GetDrawData(), r);
            if (app.opts.stats) prof_gpu += (c.SDL_GetTicksNS() - tg0) / 1000;
            app.stats.frame_us = @intCast((c.SDL_GetTicksNS() - t0) / 1000);

            if (login_result) |lr| {
                login_result = null;
                app.loginResult(lr);
                pending = 3;
            }
            // Ações acumuladas no quadro.
            for (app.actions.items) |a| app.handle(a);
            if (app.actions.items.len > 0) pending = 3;
            app.actions.clearRetainingCapacity();

            frames += 1;
            // --stats: quadros desenhados e custo médio/máximo a cada 2 s.
            if (app.opts.stats) {
                const S = struct {
                    var since: u64 = 0;
                    var n: u32 = 0;
                    var sum: u64 = 0;
                    var max: u32 = 0;
                };
                S.n += 1;
                S.sum += app.stats.frame_us;
                S.max = @max(S.max, app.stats.frame_us);
                const t = c.SDL_GetTicksNS();
                if (S.since == 0) S.since = t;
                if (t - S.since >= 2_000_000_000) {
                    std.log.info("{d} quadros em 2 s, média {d} µs, pior {d} µs", .{ S.n, S.sum / S.n, S.max });
                    std.log.info("   root.frame {d} µs, ImGui_Render {d} µs, RenderDrawData {d} µs (por quadro)", .{ prof_frame / S.n, prof_render / S.n, prof_gpu / S.n });
                    std.log.info("   {d} comandos, {d} trocas de textura, {d} vértices (por quadro)", .{ prof_cmds / S.n, prof_texs / S.n, prof_vtx / S.n });
                    prof_cmds = 0;
                    prof_texs = 0;
                    prof_vtx = 0;
                    prof_frame = 0;
                    prof_render = 0;
                    prof_gpu = 0;
                    const rt = @import("ui/root.zig");
                    for (rt.prof_names[0..rt.prof_n], rt.prof_us[0..rt.prof_n]) |nm, us| if (us / S.n > 200) std.log.info("   {s}: {d} µs/quadro", .{ nm, us / S.n });
                    @memset(&rt.prof_us, 0);
                    S.since = t;
                    S.n = 0;
                    S.sum = 0;
                    S.max = 0;
                }
            }
            if (app.opts.stats and !first_frame_logged and app.store.ready) {
                first_frame_logged = true;
                std.log.info("primeiro quadro em {d} ms", .{(c.SDL_GetTicksNS() - app.started_ns) / 1_000_000});
            }
            if (record_dir) |dir| if (app.login.visible()) {
                var pbuf: [512]u8 = undefined;
                const p = std.fmt.bufPrintSentinel(&pbuf, "{s}/{d:0>4}.png", .{ std.mem.span(dir), record_n }, 0) catch unreachable;
                _ = app.win.screenshot(p.ptr);
                record_n += 1;
                const max: u32 = if (c.SDL_getenv("LARPER_RECORD_FRAMES")) |n| std.fmt.parseInt(u32, std.mem.span(n), 10) catch 150 else 150;
                if (record_n >= max) running = false;
            };
            if (app.opts.shot) |path| if (app.login.visible() and !app.store.ready) {
                // Print da tela de login: espera a animação de entrada.
                if (app.login.t > 2.6) {
                    if (!app.win.screenshot(path)) std.log.err("não consegui salvar {s}", .{path});
                    running = false;
                }
            } else {
                const ready = app.store.ready and !app.images.busy() and if (app.st.activeChannel()) |ch| (app.store.channel(ch).?.history == .loaded) else false;
                settled_frames = if (ready) settled_frames + 1 else 0;
                // Conta real: a rede pode demorar mais que a demonstração.
                const limit: u64 = if (app.store.demo) 6 else 20;
                if (settled_frames == 12 or c.SDL_GetTicksNS() - app.started_ns > limit * std.time.ns_per_s) {
                    if (!app.win.screenshot(path)) std.log.err("não consegui salvar {s}", .{path});
                    running = false;
                }
            };
            if (app.opts.qa and (app.store.ready or app.login.visible()) and !runner.tick(app)) running = false;
            _ = c.SDL_RenderPresent(r);
            if (pending > 0) pending -= 1;
            was_active = anim.active;
        }
        return runner.fail == 0;
    }
};
