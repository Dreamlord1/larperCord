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
const gw = @import("net/fake_gateway.zig");
const Queue = @import("net/queue.zig").Queue;
const themes = @import("theme/manager.zig");
const layout = @import("theme/layout.zig");
const fonts_mod = @import("ui/fonts.zig");
const State = @import("ui/state.zig").State;
const d = @import("ui/draw.zig");
const anim = @import("ui/anim.zig");
const root = @import("ui/root.zig");
const widgets = @import("ui/widgets.zig");
const settings_state = @import("ui/settings_state.zig");
const kdl = @import("theme/kdl.zig");

pub const Options = struct {
    theme: ?[]const u8 = null,
    shot: ?[*:0]const u8 = null,
    live: bool = true,
    stats: bool = false,
    settings: bool = false,
};

var wake_type_global: u32 = 0;

fn wakeTheme() void {
    platform.Window.wake(wake_type_global, .theme);
}

pub const App = struct {
    gpa: std.mem.Allocator,
    win: platform.Window,
    store: Store,
    st: State,
    themes: themes.Manager,
    fonts: fonts_mod.Fonts,
    events: Queue(ev.Event),
    gateway: Gateway,
    actions: std.ArrayList(ev.Action) = .empty,
    placed: std.ArrayList(layout.Placed) = .empty,
    stats: d.Stats = .{},
    opts: Options,
    io: *c.ImGuiIO,
    timer: c.SDL_TimerID = 0,
    started_ns: u64,
    layout_key: u32 = 0,

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
            .gateway = undefined,
            .opts = opts,
            .io = io,
            .started_ns = started,
        };

        // Configurações salvas (ignoradas nos prints, para serem reprodutíveis).
        var saved_theme: ?[]const u8 = null;
        var settings_arena = std.heap.ArenaAllocator.init(gpa);
        defer settings_arena.deinit();
        if (opts.shot == null) saved_theme = loadSettings(&app.st.settings, settings_arena.allocator());
        app.st.settings.open = opts.settings;
        const name = opts.theme orelse saved_theme orelse "classico";
        const want = app.themes.indexOf(name) orelse 0;
        if (!app.themes.load(want)) {
            std.log.err("{s}", .{app.themes.last_error orelse "tema inválido"});
            if (!app.themes.load(0)) return error.NoTheme;
        }
        app.applyThemeStyle();
        app.themes.watch(wakeTheme);

        app.gateway = .{
            .commands = try Queue(ev.Command).init(gpa),
            .sink = .{ .ctx = app, .push = pushEvent },
            .live = opts.live,
            .rng = std.Random.DefaultPrng.init(@truncate(started)),
        };
        try app.gateway.start();

        // Relógio e RAM da barra de status: um tique a cada 2 s.
        app.timer = c.SDL_AddTimer(2000, tick, app);
        app.stats.ram_kb = platform.selfPssKb();
        return app;
    }

    pub fn destroy(app: *App) void {
        _ = c.SDL_RemoveTimer(app.timer);
        app.gateway.stop();
        app.gateway.commands.deinit();
        app.events.deinit();
        app.store.deinit();
        app.themes.deinit();
        c.cImGui_ImplSDLRenderer3_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();
        c.ImGui_DestroyContext(null);
        app.win.deinit();
        app.gpa.destroy(app);
    }

    fn pushEvent(ctx: *anyopaque, e: ev.Event) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.events.push(e);
        platform.Window.wake(app.win.wake_type, .gateway);
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
    fn loadSettings(s: *settings_state.Settings, arena: std.mem.Allocator) ?[]const u8 {
        var buf: [512]u8 = undefined;
        const path = settingsPath(&buf) orelse return null;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
        defer c.SDL_free(data);
        const src = arena.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
        const nodes = kdl.parse(arena, src, null) catch return null;
        for (nodes) |*n| if (std.mem.eql(u8, n.name, "settings")) {
            settings_state.apply(s, n);
            return n.str("theme");
        };
        return null;
    }

    fn saveSettings(app: *App) void {
        if (app.opts.shot != null) return;
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
        _ = c.SDL_SaveFile(path.ptr, out.items.ptr, out.items.len);
    }

    fn uiFamily(app: *App, name: []const u8) *fonts_mod.Family {
        return app.fonts.family(name) catch app.fonts.family("Inter") catch app.fonts.families.items[0];
    }

    fn setTheme(app: *App, i: usize) void {
        if (app.themes.load(i)) {
            app.applyThemeStyle();
            app.st.showToast(now(), false, "tema: {s}", .{app.themes.name()});
            app.saveSettings();
        } else app.st.showToast(now(), true, "{s}", .{app.themes.last_error orelse "erro no tema"});
    }

    // --- Ações da interface ------------------------------------------------

    fn openChannel(app: *App, id: types.Id, new_tab: bool) void {
        const cs = app.store.channel(id) orelse return;
        if (cs.info.kind != .text) return;
        app.st.guild = cs.info.guild;
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
            app.gateway.commands.push(.{ .fetch_history = cs.info.id });
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
        app.store.addPending(ch, out.items, app.st.nonce, reply_to, now()) catch return;
        app.st.scrollOf(ch).stick_bottom = true;
        const copy = std.heap.c_allocator.dupe(u8, out.items) catch return;
        app.gateway.commands.push(.{ .send_message = .{ .channel = ch, .content = copy, .nonce = app.st.nonce, .reply_to = reply_to } });
    }

    fn firstTextChannel(app: *App, guild: types.Id) ?types.Id {
        for (app.store.channelsOf(guild)) |id| {
            if (app.store.channel(id)) |cs| if (cs.info.kind == .text) return id;
        }
        return null;
    }

    fn handle(app: *App, a: ev.Action) void {
        const st = &app.st;
        switch (a) {
            .select_guild => |g| {
                st.guild = g;
                const ch = st.last_channel.get(g) orelse app.firstTextChannel(g) orelse return;
                app.openChannel(ch, false);
            },
            .select_channel => |ch| app.openChannel(ch, app.io.*.KeyCtrl),
            .focus_tab => |i| if (i < st.tabs.items.len) {
                st.tab = i;
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
                app.gateway.commands.push(.{ .edit_message = .{ .channel = ch, .id = id, .content = copy } });
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
                app.store.apply(.{ .message_delete = .{ .channel = ch, .id = id } }, now()) catch {};
                app.gateway.commands.push(.{ .delete_message = .{ .channel = ch, .id = id } });
                st.showToast(now(), false, "mensagem excluída", .{});
            },
            .react => |r| {
                const f = app.store.findAny(r.id) orelse return;
                var mine = false;
                for (f.m.reactionSlice()) |*x| if (std.mem.eql(u8, x.text(), r.emoji.text())) {
                    mine = x.me;
                };
                app.store.react(f.m, r.emoji.text(), true, !mine);
                app.gateway.commands.push(.{ .react = .{ .channel = f.cs.info.id, .id = r.id, .emoji = r.emoji, .add = !mine } });
            },
            .open_dm => |user| {
                for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (cs.info.recipient == user) {
                    return app.openChannel(id, false);
                };
                st.showToast(now(), false, "ainda não existe uma DM com essa pessoa", .{});
            },
            .send_dm => |dm| {
                defer app.gpa.free(dm.text);
                app.handle(.{ .open_dm = dm.user });
                const ch = st.activeChannel() orelse return;
                if (app.store.channel(ch)) |cs| if (cs.info.recipient == dm.user) app.sendTo(ch, dm.text, 0);
            },
            .copy => |text| {
                defer app.gpa.free(text);
                const z = app.gpa.dupeSentinel(u8, text, 0) catch return;
                defer app.gpa.free(z);
                _ = c.SDL_SetClipboardText(z.ptr);
                st.showToast(now(), false, "copiado ✓", .{});
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
            .toggle_voice => |ch| {
                st.voice = if (st.voice == ch) null else ch;
                app.gateway.commands.push(.{ .join_voice = st.voice });
            },
            .leave_voice => {
                st.voice = null;
                app.gateway.commands.push(.{ .join_voice = null });
            },
            .toggle_mute => st.muted = !st.muted,
            .toggle_deafen => st.deafened = !st.deafened,
            .toggle_category => |id| {
                if (st.collapsed.contains(id)) _ = st.collapsed.remove(id) else st.collapsed.put(app.gpa, id, {}) catch {};
            },
            .set_theme => |i| app.setTheme(i),
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
        }
    }

    // --- Laço ----------------------------------------------------------------

    fn drainEvents(app: *App) void {
        var batch: std.ArrayList(ev.Event) = .empty;
        defer batch.deinit(app.gpa);
        app.events.drain(&batch);
        const was_ready = app.store.ready;
        for (batch.items) |e| app.store.apply(e, now()) catch {};
        if (!was_ready and app.store.ready) app.onReady();
        // Marca como lido o que chega no canal aberto.
        if (app.st.activeChannel()) |ch| app.store.markRead(ch);
    }

    fn onReady(app: *App) void {
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
    fn scene(app: *App) void {
        const which = std.mem.span(c.SDL_getenv("LARPER_SCENE") orelse return);
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
            const t = "isso aqui tá **muito** bom 😍";
            @memcpy(app.st.input[0..t.len], t);
            app.st.input_sync = true;
        } else if (std.mem.eql(u8, which, "select")) {
            app.st.selection = .{ .channel = ch, .a_id = prev.msg.id, .a_off = 3, .b_id = last.msg.id, .b_off = @intCast(@min(last.msg.content.len, 12)) };
        } else if (std.mem.eql(u8, which, "dm")) {
            app.handle(.{ .select_guild = 0 });
        }
    }

    pub fn run(app: *App) void {
        var pending: u32 = 3;
        var running = true;
        var last = c.SDL_GetTicksNS();
        var frames: u32 = 0;
        var settled_frames: u32 = 0;
        var first_frame_logged = false;

        while (running) {
            var e: c.SDL_Event = undefined;
            const busy = pending > 0 or anim.active or app.opts.shot != null;
            var got = if (busy) c.SDL_PollEvent(&e) else c.SDL_WaitEvent(&e);
            while (got) {
                if (e.type == app.win.wake_type) {
                    switch (@as(platform.Wake, @enumFromInt(e.user.code))) {
                        .gateway => app.drainEvents(),
                        .theme => if (app.themes.reload()) {
                            app.applyThemeStyle();
                            app.st.showToast(now(), false, "tema recarregado: {s}", .{app.themes.name()});
                        } else app.st.showToast(now(), true, "{s}", .{app.themes.last_error orelse "erro no tema"}),
                        .tick => {},
                    }
                } else {
                    _ = c.cImGui_ImplSDL3_ProcessEvent(&e);
                    if (e.type == c.SDL_EVENT_QUIT or e.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED) running = false;
                }
                pending = 3;
                got = c.SDL_PollEvent(&e);
            }
            if (app.store.expireTyping(now())) pending = 2;

            const t0 = c.SDL_GetTicksNS();
            anim.dt = std.math.clamp(@as(f32, @floatFromInt(t0 - last)) / 1e9, 0.001, 1.0 / 30.0);
            last = t0;
            anim.active = false;

            c.cImGui_ImplSDLRenderer3_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            // Configurações que valem para o quadro inteiro.
            const set = &app.st.settings;
            d.text_scale = set.font_scale;
            anim.instant = set.reduce_motion;
            widgets.hour12 = !set.clock_24h;
            const key = set.layoutKey();
            if (key != app.layout_key) {
                app.layout_key = key;
                app.st.theme_gen +%= 1;
            }

            if (app.opts.shot != null and settled_frames >= 3) app.scene();
            c.ImGui_NewFrame();
            if (app.store.ready) {
                const th = app.themes.theme_();
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
                    .win = undefined,
                };
                root.frame(&ctx, &app.placed, app.themes.previews.items);
            }
            c.ImGui_Render();

            const r = app.win.renderer;
            _ = c.SDL_SetRenderScale(r, app.io.*.DisplayFramebufferScale.x, app.io.*.DisplayFramebufferScale.y);
            const bg = app.themes.theme_().c(.bg);
            _ = c.SDL_SetRenderDrawColorFloat(r, bg.r * bg.a, bg.g * bg.a, bg.b * bg.a, bg.a);
            _ = c.SDL_RenderClear(r);
            c.cImGui_ImplSDLRenderer3_RenderDrawData(c.ImGui_GetDrawData(), r);
            app.stats.frame_us = @intCast((c.SDL_GetTicksNS() - t0) / 1000);

            // Ações acumuladas no quadro.
            for (app.actions.items) |a| app.handle(a);
            if (app.actions.items.len > 0) pending = 3;
            app.actions.clearRetainingCapacity();

            frames += 1;
            if (app.opts.stats and !first_frame_logged and app.store.ready) {
                first_frame_logged = true;
                std.log.info("primeiro quadro em {d} ms", .{(c.SDL_GetTicksNS() - app.started_ns) / 1_000_000});
            }
            if (app.opts.shot) |path| {
                const ready = app.store.ready and if (app.st.activeChannel()) |ch| (app.store.channel(ch).?.history == .loaded) else false;
                settled_frames = if (ready) settled_frames + 1 else 0;
                if (settled_frames == 12 or c.SDL_GetTicksNS() - app.started_ns > 6 * std.time.ns_per_s) {
                    if (!app.win.screenshot(path)) std.log.err("não consegui salvar {s}", .{path});
                    running = false;
                }
            }
            _ = c.SDL_RenderPresent(r);
            if (pending > 0) pending -= 1;
        }
    }
};
