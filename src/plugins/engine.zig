//! Plugins em Lua 5.4: scripts pequenos em ~/.config/larpercord/plugins/*.lua
//! que reagem a eventos e criam comandos e atalhos, sem recompilar.
//!
//! Cada plugin tem o próprio `lua_State` (um travado ou com erro não mexe
//! nos outros) e roda num sandbox:
//! - só as bibliotecas base, string, table, math e utf8, mais os.time,
//!   os.date e os.clock. Sem io, os.execute, require, load/dofile, debug;
//! - um limite de instruções por chamada (lua_sethook com contagem): um
//!   laço infinito vira erro em vez de congelar a interface, e `pcall` não
//!   consegue engolir esse erro;
//! - um teto de memória por plugin (o alocador recusa passar dele);
//! - toda entrada no Lua passa por um `lua_pcall` (até montar as tabelas),
//!   então nenhum erro derruba o app: vira aviso na interface.
//!
//! Tudo roda na thread da interface. Sem plugins, os ganchos do app só
//! comparam um contador com zero (nada é alocado).
//!
//! Este arquivo não depende de janela: o app entra pelo `Host` (ver
//! host.zig) e os testes usam um `Host` falso.
const std = @import("std");
const lua = @import("lua.zig");

pub const max_plugins = 64;
pub const max_source = 256 * 1024;
const max_commands = 32;
const max_keys = 32;
/// Teto de memória de cada plugin.
const mem_cap = 8 * 1024 * 1024;
/// O gancho do Lua roda a cada tantas instruções.
const hook_every = 1000;
/// Erros seguidos (fora o de travar) antes de o plugin ser parado.
const max_errors = 10;
/// larper.send por comando/atalho.
const max_sends = 5;

/// O plugin aberto na página de configurações e os ganchos do app.
pub var current: ?*Engine = null;
/// Idioma das mensagens de erro (o app troca por `i18n.en`).
pub var lang_en: *const fn () bool = &struct {
    fn f() bool {
        return false;
    }
}.f;

fn tr(pt: []const u8, en: []const u8) []const u8 {
    return if (lang_en()) en else pt;
}

/// Onde a pessoa está (canal e servidor abertos). Textos emprestados.
pub const Where = struct {
    channel: u64 = 0,
    channel_name: []const u8 = "",
    guild: u64 = 0,
    guild_name: []const u8 = "",
};

/// Mensagem que chegou (o evento "message"). Textos emprestados.
pub const Message = struct {
    id: u64 = 0,
    content: []const u8,
    author: u64,
    author_name: []const u8,
    channel: u64,
    channel_name: []const u8,
    guild: u64 = 0,
    guild_name: []const u8 = "",
    mine: bool = false,
};

/// O que o app oferece aos plugins.
pub const Host = struct {
    ctx: *anyopaque,
    /// Aviso na interface (larper.notify).
    notify: *const fn (ctx: *anyopaque, plugin: []const u8, text: []const u8) void,
    /// Manda uma mensagem (channel 0 = o canal aberto). false = canal não existe.
    send: *const fn (ctx: *anyopaque, channel: u64, text: []const u8) bool,
    where: *const fn (ctx: *anyopaque) Where,
    /// "x", "f5", "enter"… para o código da tecla (null = não conhece).
    key: *const fn (name: []const u8) ?i32,
    /// Lê a pasta de novo e chama `load` (botão Recarregar).
    rescan: *const fn (ctx: *anyopaque) void,
    /// Um plugin foi ligado/desligado: salvar a escolha.
    save: *const fn (ctx: *anyopaque) void,
    /// Um plugin deu erro.
    failed: *const fn (ctx: *anyopaque, plugin: []const u8, msg: []const u8) void,
};

/// Um arquivo lido da pasta.
pub const Source = struct { name: []const u8, src: []const u8 };

pub const Keybind = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    key: i32 = 0,
    /// Posição da função em registry.larper.keys.
    slot: u32 = 0,
    label_buf: [40]u8 = undefined,
    label_len: u8 = 0,

    pub fn label(k: *const Keybind) []const u8 {
        return k.label_buf[0..k.label_len];
    }
};

pub const Status = enum { off, running, failed };

pub const Plugin = struct {
    engine: *Engine,
    name: []u8,
    src: []u8,
    enabled: bool = true,
    L: ?*lua.State = null,
    err_buf: [300]u8 = undefined,
    err_len: u16 = 0,
    /// Bytes que o Lua deste plugin está usando.
    mem: usize = 0,
    steps: u32 = 0,
    timed_out: bool = false,
    /// Chamado por um comando/atalho da própria pessoa (libera larper.send).
    user_call: bool = false,
    sends: u8 = 0,
    errors: u8 = 0,
    n_message: u16 = 0,
    n_ready: u16 = 0,
    commands: std.ArrayList([]u8) = .empty,
    keys: std.ArrayList(Keybind) = .empty,

    pub fn status(p: *const Plugin) Status {
        if (p.L != null) return .running;
        return if (p.enabled) .failed else .off;
    }

    pub fn err(p: *const Plugin) ?[]const u8 {
        return if (p.err_len > 0) p.err_buf[0..p.err_len] else null;
    }

    fn setErr(p: *Plugin, msg: []const u8) void {
        var n = @min(msg.len, p.err_buf.len);
        // Sem cortar um caractere no meio.
        while (n > 0 and n < msg.len and (msg[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(p.err_buf[0..n], msg[0..n]);
        p.err_len = @intCast(n);
    }
};

const Kind = enum { setup, message, ready, command, key };

/// O que o trampolim protegido vai fazer dentro do Lua.
const Call = struct {
    kind: Kind,
    msg: ?*const Message = null,
    name: []const u8 = "",
    args: []const u8 = "",
    slot: u32 = 0,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    host: Host,
    list: std.ArrayList(*Plugin) = .empty,
    /// Nomes desligados pela pessoa (persistidos pelo app).
    disabled: std.StringHashMapUnmanaged(void) = .empty,
    /// Muda a cada carga, troca ou erro (a página e o QA observam).
    generation: u32 = 0,
    /// Somas dos plugins rodando: com zero, os ganchos nem entram.
    n_message: u32 = 0,
    n_ready: u32 = 0,
    n_commands: u32 = 0,
    n_keys: u32 = 0,
    /// O app já recebeu o READY (plugin ligado depois recebe "ready" na hora).
    ready: bool = false,
    /// Instruções por chamada.
    budget: u32 = 5_000_000,
    /// Pasta lida (para a página de configurações).
    dir_buf: [512]u8 = undefined,
    dir_len: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, host: Host) Engine {
        return .{ .gpa = gpa, .host = host };
    }

    pub fn deinit(e: *Engine) void {
        e.clear();
        e.list.deinit(e.gpa);
        var it = e.disabled.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.disabled.deinit(e.gpa);
        if (current == e) current = null;
    }

    pub fn dir(e: *const Engine) []const u8 {
        return e.dir_buf[0..e.dir_len];
    }

    pub fn setDir(e: *Engine, path: []const u8) void {
        const n = @min(path.len, e.dir_buf.len);
        @memcpy(e.dir_buf[0..n], path[0..n]);
        e.dir_len = @intCast(n);
    }

    fn clear(e: *Engine) void {
        for (e.list.items) |p| {
            stop(p);
            e.gpa.free(p.name);
            e.gpa.free(p.src);
            p.commands.deinit(e.gpa);
            p.keys.deinit(e.gpa);
            e.gpa.destroy(p);
        }
        e.list.clearRetainingCapacity();
        e.recount();
    }

    /// Troca todos os plugins pelos arquivos dados (já em ordem).
    /// `app_ready`: o app já está conectado (dispara "ready" nos novos).
    pub fn load(e: *Engine, files: []const Source, app_ready: bool) void {
        e.clear();
        e.ready = app_ready;
        for (files[0..@min(files.len, max_plugins)]) |f| {
            const p = e.gpa.create(Plugin) catch break;
            const name = e.gpa.dupe(u8, f.name) catch {
                e.gpa.destroy(p);
                break;
            };
            const src = e.gpa.dupe(u8, f.src) catch {
                e.gpa.free(name);
                e.gpa.destroy(p);
                break;
            };
            p.* = .{ .engine = e, .name = name, .src = src, .enabled = !e.disabled.contains(f.name) };
            e.list.append(e.gpa, p) catch {
                e.gpa.free(name);
                e.gpa.free(src);
                e.gpa.destroy(p);
                break;
            };
            if (p.enabled) e.start(p);
        }
        e.recount();
        e.generation +%= 1;
        if (app_ready) for (e.list.items) |p| if (p.n_ready > 0) e.invoke(p, .{ .kind = .ready });
        e.recount();
    }

    /// Lê a pasta de novo (botão "Recarregar").
    pub fn reload(e: *Engine) void {
        e.host.rescan(e.host.ctx);
    }

    /// Ao ler as configurações salvas.
    pub fn setDisabledName(e: *Engine, name: []const u8) void {
        if (e.disabled.contains(name)) return;
        const k = e.gpa.dupe(u8, name) catch return;
        e.disabled.put(e.gpa, k, {}) catch e.gpa.free(k);
    }

    pub fn setEnabled(e: *Engine, p: *Plugin, on: bool) void {
        if (p.enabled == on) return;
        p.enabled = on;
        if (on) {
            if (e.disabled.fetchRemove(p.name)) |kv| e.gpa.free(kv.key);
            p.err_len = 0;
            e.start(p);
            e.recount();
            if (e.ready and p.n_ready > 0) e.invoke(p, .{ .kind = .ready });
        } else {
            e.setDisabledName(p.name);
            stop(p);
            p.err_len = 0;
        }
        e.recount();
        e.generation +%= 1;
        e.host.save(e.host.ctx);
    }

    fn recount(e: *Engine) void {
        e.n_message = 0;
        e.n_ready = 0;
        e.n_commands = 0;
        e.n_keys = 0;
        for (e.list.items) |p| if (p.L != null) {
            e.n_message += p.n_message;
            e.n_ready += p.n_ready;
            e.n_commands += @intCast(p.commands.items.len);
            e.n_keys += @intCast(p.keys.items.len);
        };
    }

    // --- Eventos que o app manda ----------------------------------------------

    pub fn onMessage(e: *Engine, m: *const Message) void {
        if (e.n_message == 0) return;
        var i: usize = 0;
        while (i < e.list.items.len) : (i += 1) {
            const p = e.list.items[i];
            if (p.L != null and p.n_message > 0) e.invoke(p, .{ .kind = .message, .msg = m });
        }
        e.recount();
    }

    pub fn fireReady(e: *Engine) void {
        e.ready = true;
        if (e.n_ready == 0) return;
        for (e.list.items) |p| if (p.L != null and p.n_ready > 0) e.invoke(p, .{ .kind = .ready });
        e.recount();
    }

    /// Texto digitado na caixa: "/nome args" de algum plugin? Se sim, roda
    /// e devolve true (não vai para o Discord).
    pub fn command(e: *Engine, text: []const u8) bool {
        if (e.n_commands == 0 or text.len < 2 or text[0] != '/') return false;
        const sp = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
        const name = text[0..sp];
        const args = std.mem.trim(u8, text[sp..], " \t\n");
        for (e.list.items) |p| {
            if (p.L == null) continue;
            for (p.commands.items) |cmd| if (std.mem.eql(u8, cmd, name)) {
                e.invoke(p, .{ .kind = .command, .name = name, .args = args });
                e.recount();
                return true;
            };
        }
        return false;
    }

    /// Roda os atalhos cujas teclas `pressed` diz que foram apertadas.
    pub fn pollKeys(e: *Engine, ctx: *anyopaque, pressed: *const fn (ctx: *anyopaque, k: *const Keybind) bool) void {
        if (e.n_keys == 0) return;
        var i: usize = 0;
        var ran = false;
        while (i < e.list.items.len) : (i += 1) {
            const p = e.list.items[i];
            var k: usize = 0;
            // O plugin pode parar no meio (e perder os atalhos): confere a cada volta.
            while (p.L != null and k < p.keys.items.len) : (k += 1) {
                if (!pressed(ctx, &p.keys.items[k])) continue;
                e.invoke(p, .{ .kind = .key, .slot = p.keys.items[k].slot });
                ran = true;
            }
        }
        if (ran) e.recount();
    }

    // --- Ciclo de vida ----------------------------------------------------------

    fn start(e: *Engine, p: *Plugin) void {
        p.err_len = 0;
        p.errors = 0;
        p.mem = 0;
        const L = lua.lua_newstate(&alloc, p) orelse return e.fail(p, tr("sem memória para o Lua", "out of memory for Lua"));
        _ = lua.lua_atpanic(L, &panic);
        p.L = L;
        lua.lua_sethook(L, &hook, lua.MASKCOUNT, hook_every);
        if (!e.protected(p, .{ .kind = .setup })) return;
        var nbuf: [160]u8 = undefined;
        const chunk = std.fmt.bufPrintSentinel(&nbuf, "@{s}", .{p.name}, 0) catch "@plugin";
        // Só texto: bytecode pré-compilado poderia burlar o sandbox.
        if (lua.luaL_loadbufferx(L, p.src.ptr, p.src.len, chunk.ptr, "t") != lua.OK) {
            const msg = lua.toSlice(L, -1) orelse "?";
            p.setErr(msg);
            stop(p);
            e.generation +%= 1;
            e.host.failed(e.host.ctx, p.name, p.err().?);
            return;
        }
        p.steps = 0;
        p.timed_out = false;
        if (lua.pcall(L, 0, 0) != lua.OK) e.afterError(p);
    }

    fn stop(p: *Plugin) void {
        if (p.L) |L| {
            // __gc não existe aqui (ver lSetmetatable): fechar não roda código do plugin.
            p.steps = 0;
            p.timed_out = false;
            lua.lua_close(L);
        }
        p.L = null;
        for (p.commands.items) |cmd| p.engine.gpa.free(cmd);
        p.commands.clearRetainingCapacity();
        p.keys.clearRetainingCapacity();
        p.n_message = 0;
        p.n_ready = 0;
    }

    fn fail(e: *Engine, p: *Plugin, msg: []const u8) void {
        p.setErr(msg);
        stop(p);
        e.generation +%= 1;
        e.host.failed(e.host.ctx, p.name, p.err().?);
    }

    /// Roda `call` num pcall. false = deu erro (já tratado).
    fn protected(e: *Engine, p: *Plugin, call: Call) bool {
        const L = p.L orelse return false;
        var cl = call;
        p.steps = 0;
        p.timed_out = false;
        p.sends = 0;
        p.user_call = call.kind == .command or call.kind == .key;
        defer p.user_call = false;
        lua.pushcfunction(L, &trampoline);
        lua.lua_pushlightuserdata(L, &cl);
        if (lua.pcall(L, 1, 0) == lua.OK) return true;
        e.afterError(p);
        return false;
    }

    fn invoke(e: *Engine, p: *Plugin, call: Call) void {
        _ = e.protected(p, call);
    }

    /// O erro está no topo da pilha do plugin.
    fn afterError(e: *Engine, p: *Plugin) void {
        const L = p.L.?;
        // Só texto: converter um número aloca, e sem pcall um erro de memória aqui derruba o app.
        const raw = (if (lua.lua_type(L, -1) == lua.TSTRING) lua.toSlice(L, -1) else null) orelse tr("erro sem mensagem", "error without a message");
        var buf: [300]u8 = undefined;
        if (p.timed_out) {
            const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ tr("parado:", "stopped:"), raw }) catch raw;
            return e.fail(p, msg);
        }
        p.errors += 1;
        if (p.errors >= max_errors) {
            const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ tr("parado depois de 10 erros:", "stopped after 10 errors:"), raw }) catch raw;
            return e.fail(p, msg);
        }
        p.setErr(raw);
        lua.pop(L, 1);
        e.generation +%= 1;
        e.host.failed(e.host.ctx, p.name, p.err().?);
    }
};

// --- Ponte C -> Zig ------------------------------------------------------------

fn plug(L: ?*lua.State) *Plugin {
    var ud: ?*anyopaque = null;
    _ = lua.lua_getallocf(L, &ud);
    return @ptrCast(@alignCast(ud.?));
}

/// Erro de Lua com "arquivo:linha:" na frente. Não volta (longjmp).
fn raise(L: ?*lua.State, msg: []const u8) noreturn {
    lua.luaL_where(L, 1);
    lua.pushSlice(L, msg);
    lua.lua_concat(L, 2);
    _ = lua.lua_error(L);
    unreachable;
}

fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const p: *Plugin = @ptrCast(@alignCast(ud.?));
    // Com ptr nulo, osize diz o tipo do objeto, não o tamanho.
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        std.c.free(ptr);
        p.mem -|= old;
        return null;
    }
    if (nsize > old and p.mem - old + nsize > mem_cap) return null;
    const np = std.c.realloc(ptr, nsize) orelse return null;
    p.mem = p.mem - old + nsize;
    return np;
}

fn panic(L: ?*lua.State) callconv(.c) c_int {
    // Não deveria acontecer: toda entrada no Lua é protegida.
    std.log.err("lua: erro sem proteção: {s}", .{lua.toSlice(L, -1) orelse "?"});
    return 0;
}

fn hook(L: ?*lua.State, _: ?*lua.Debug) callconv(.c) void {
    const p = plug(L);
    p.steps +|= hook_every;
    if (p.timed_out or p.steps > p.engine.budget) {
        // Continua valendo até a chamada acabar: o erro sai de qualquer pcall.
        p.timed_out = true;
        lua.luaL_where(L, 0);
        lua.pushSlice(L, tr("passou do limite de instruções (laço infinito?)", "went over the instruction limit (infinite loop?)"));
        lua.lua_concat(L, 2);
        _ = lua.lua_error(L);
    }
}

/// Primeira função de toda chamada: já dentro do pcall, então até faltar
/// memória montando uma tabela vira um erro normal.
fn trampoline(L: ?*lua.State) callconv(.c) c_int {
    const call: *const Call = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    if (call.kind == .setup) {
        setup(L);
        return 0;
    }
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper"); // 2
    switch (call.kind) {
        .setup => unreachable,
        .message, .ready => {
            _ = lua.lua_getfield(L, 2, if (call.kind == .message) "message" else "ready"); // 3
            if (call.msg) |m| pushMessage(L, m) else lua.lua_pushnil(L); // 4
            const n: lua.Integer = @intCast(lua.lua_rawlen(L, 3));
            var i: lua.Integer = 1;
            while (i <= n) : (i += 1) {
                _ = lua.lua_rawgeti(L, 3, i);
                if (call.kind == .message) {
                    lua.lua_pushvalue(L, 4);
                    lua.call(L, 1, 0);
                } else lua.call(L, 0, 0);
            }
        },
        .command => {
            _ = lua.lua_getfield(L, 2, "commands");
            lua.pushSlice(L, call.name);
            _ = lua.lua_rawget(L, -2);
            lua.pushSlice(L, call.args);
            lua.call(L, 1, 0);
        },
        .key => {
            _ = lua.lua_getfield(L, 2, "keys");
            _ = lua.lua_rawgeti(L, -1, call.slot);
            lua.call(L, 0, 0);
        },
    }
    return 0;
}

fn pushId(L: ?*lua.State, id: u64) void {
    var b: [24]u8 = undefined;
    lua.pushSlice(L, std.fmt.bufPrint(&b, "{d}", .{id}) catch "0");
}

/// {id="123", name="geral"}
fn pushRef(L: ?*lua.State, id: u64, name: []const u8) void {
    lua.lua_createtable(L, 0, 2);
    pushId(L, id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, name);
    lua.lua_setfield(L, -2, "name");
}

fn pushMessage(L: ?*lua.State, m: *const Message) void {
    lua.lua_createtable(L, 0, 7);
    pushId(L, m.id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, m.content);
    lua.lua_setfield(L, -2, "content");
    pushRef(L, m.author, m.author_name);
    lua.lua_setfield(L, -2, "author");
    pushRef(L, m.channel, m.channel_name);
    lua.lua_setfield(L, -2, "channel");
    if (m.guild != 0) {
        pushRef(L, m.guild, m.guild_name);
        lua.lua_setfield(L, -2, "guild");
    }
    lua.lua_pushboolean(L, @intFromBool(m.mine));
    lua.lua_setfield(L, -2, "mine");
}

/// Abre só o que o sandbox permite e cria a tabela `larper`.
fn setup(L: ?*lua.State) void {
    lua.pushcfunction(L, &lua.luaopen_base);
    lua.call(L, 0, 1);
    lua.pop(L, 1);
    const libs = [_]struct { name: [*:0]const u8, open: lua.CFunction }{
        .{ .name = "string", .open = &lua.luaopen_string },
        .{ .name = "table", .open = &lua.luaopen_table },
        .{ .name = "math", .open = &lua.luaopen_math },
        .{ .name = "utf8", .open = &lua.luaopen_utf8 },
    };
    for (libs) |lib| {
        lua.pushcfunction(L, lib.open);
        lua.call(L, 0, 1);
        lua.lua_setglobal(L, lib.name);
    }
    // string.dump gera bytecode (que nem dá para carregar aqui, mas fora).
    _ = lua.lua_getglobal(L, "string");
    lua.lua_pushnil(L);
    lua.lua_setfield(L, -2, "dump");
    lua.pop(L, 1);
    // os: só o relógio.
    lua.pushcfunction(L, &lua.luaopen_os);
    lua.call(L, 0, 1);
    lua.newtable(L);
    for ([_][*:0]const u8{ "time", "date", "clock", "difftime" }) |f| {
        _ = lua.lua_getfield(L, -2, f);
        lua.lua_setfield(L, -2, f);
    }
    lua.lua_setglobal(L, "os");
    lua.pop(L, 1);
    // Fora da base: ler/rodar arquivos e código, e desligar o coletor.
    for ([_][*:0]const u8{ "dofile", "loadfile", "load", "collectgarbage" }) |f| {
        lua.lua_pushnil(L);
        lua.lua_setglobal(L, f);
    }
    const base = [_]struct { name: [*:0]const u8, f: lua.CFunction }{
        .{ .name = "print", .f = &lPrint },
        .{ .name = "pcall", .f = &lPcall },
        .{ .name = "xpcall", .f = &lXpcall },
        .{ .name = "setmetatable", .f = &lSetmetatable },
    };
    for (base) |b| {
        lua.pushcfunction(L, b.f);
        lua.lua_setglobal(L, b.name);
    }
    const api = [_]struct { name: [*:0]const u8, f: lua.CFunction }{
        .{ .name = "on", .f = &lOn },
        .{ .name = "command", .f = &lCommand },
        .{ .name = "keybind", .f = &lKeybind },
        .{ .name = "notify", .f = &lNotify },
        .{ .name = "send", .f = &lSend },
        .{ .name = "channel", .f = &lChannel },
        .{ .name = "guild", .f = &lGuild },
    };
    lua.lua_createtable(L, 0, api.len);
    for (api) |a| {
        lua.pushcfunction(L, a.f);
        lua.lua_setfield(L, -2, a.name);
    }
    lua.lua_setglobal(L, "larper");
    // As funções registradas ficam no registro, longe do script.
    lua.lua_createtable(L, 0, 4);
    for ([_][*:0]const u8{ "message", "ready", "commands", "keys" }) |k| {
        lua.newtable(L);
        lua.lua_setfield(L, -2, k);
    }
    lua.lua_setfield(L, lua.REGISTRYINDEX, "larper");
}

// --- Funções do Lua ----------------------------------------------------------

/// setmetatable sem `__gc`: o finalizador roda com o gancho de instruções
/// desligado, então um `while true do end` nele travaria o app para sempre.
/// O Lua só registra finalizador nesta chamada; criar o campo depois não vale.
fn lSetmetatable(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, lua.TTABLE);
    const kind = lua.lua_type(L, 2);
    if (kind != lua.TNIL and kind != lua.TTABLE) raise(L, tr("setmetatable: a metatabela precisa ser uma tabela ou nil", "setmetatable: the metatable must be a table or nil"));
    if (kind == lua.TTABLE) {
        _ = lua.lua_pushstring(L, "__gc");
        const has_gc = lua.lua_rawget(L, 2) != lua.TNIL;
        lua.pop(L, 1);
        if (has_gc) raise(L, tr("setmetatable: __gc não é permitido em plugins", "setmetatable: __gc isn't allowed in plugins"));
    }
    if (lua.lua_getmetatable(L, 1) != 0) {
        _ = lua.lua_pushstring(L, "__metatable");
        const protected_mt = lua.lua_rawget(L, -2) != lua.TNIL;
        lua.pop(L, 2);
        if (protected_mt) raise(L, tr("setmetatable: metatabela protegida", "setmetatable: protected metatable"));
    }
    lua.lua_settop(L, 2);
    _ = lua.lua_setmetatable(L, 1);
    return 1;
}

fn lPrint(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    const top = lua.lua_gettop(L);
    var i: c_int = 1;
    while (i <= top) : (i += 1) {
        var len: usize = 0;
        const s = lua.luaL_tolstring(L, i, &len);
        if (i > 1 and n < buf.len) {
            buf[n] = '\t';
            n += 1;
        }
        const k = @min(len, buf.len - n);
        @memcpy(buf[n..][0..k], s[0..k]);
        n += k;
        lua.pop(L, 1);
    }
    std.log.info("[{s}] {s}", .{ p.name, buf[0..n] });
    return 0;
}

/// pcall que não segura o erro de "travou": esse sempre sai até o app.
fn lPcall(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checkany(L, 1);
    const rc = lua.lua_pcallk(L, lua.lua_gettop(L) - 1, lua.MULTRET, 0, 0, null);
    if (plug(L).timed_out) return lua.lua_error(L);
    if (rc == lua.OK) {
        lua.lua_pushboolean(L, 1);
        lua.insert(L, 1);
        return lua.lua_gettop(L);
    }
    lua.lua_pushboolean(L, 0);
    lua.insert(L, -2);
    return 2;
}

fn lXpcall(L: ?*lua.State) callconv(.c) c_int {
    const n = lua.lua_gettop(L);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    // [f, msgh, args…] -> [f, msgh, true, f, args…]
    lua.lua_pushboolean(L, 1);
    lua.lua_pushvalue(L, 1);
    lua.lua_rotate(L, 3, 2);
    const rc = lua.lua_pcallk(L, n - 2, lua.MULTRET, 2, 0, null);
    if (plug(L).timed_out) return lua.lua_error(L);
    if (rc == lua.OK) return lua.lua_gettop(L) - 2;
    lua.lua_pushboolean(L, 0);
    lua.lua_pushvalue(L, -2);
    return 2;
}

fn registryList(L: ?*lua.State, field: [*:0]const u8) void {
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    _ = lua.lua_getfield(L, -1, field);
}

/// larper.on("message" | "ready", fn)
fn lOn(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const event = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const is_msg = std.mem.eql(u8, event, "message");
    if (!is_msg and !std.mem.eql(u8, event, "ready"))
        raise(L, tr("larper.on: evento desconhecido (use \"message\" ou \"ready\")", "larper.on: unknown event (use \"message\" or \"ready\")"));
    if ((if (is_msg) p.n_message else p.n_ready) >= 64) raise(L, tr("larper.on: funções demais para esse evento", "larper.on: too many functions for that event"));
    registryList(L, if (is_msg) "message" else "ready");
    const n = lua.lua_rawlen(L, -1);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawseti(L, -2, @intCast(n + 1));
    if (is_msg) p.n_message += 1 else p.n_ready += 1;
    return 0;
}

fn validCommand(name: []const u8) bool {
    if (name.len < 2 or name.len > 32 or name[0] != '/') return false;
    for (name[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

/// larper.command("/nome", fn(args))
fn lCommand(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const name = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    if (!validCommand(name)) raise(L, tr("larper.command: o nome é \"/\" seguido de letras, números, _ ou - (até 32)", "larper.command: the name is \"/\" followed by letters, digits, _ or - (up to 32)"));
    const known = for (p.commands.items) |cmd| {
        if (std.mem.eql(u8, cmd, name)) break true;
    } else false;
    if (!known and p.commands.items.len >= max_commands) raise(L, tr("larper.command: comandos demais", "larper.command: too many commands"));
    registryList(L, "commands");
    lua.lua_pushvalue(L, 1);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawset(L, -3);
    if (!known) {
        const own = p.engine.gpa.dupe(u8, name) catch raise(L, "sem memória");
        p.commands.append(p.engine.gpa, own) catch {
            p.engine.gpa.free(own);
            raise(L, "sem memória");
        };
    }
    return 0;
}

/// "ctrl+shift+x" -> Keybind (sem a tecla resolvida). null = inválido.
pub fn parseKeys(spec: []const u8, key_name: *[16]u8, key_len: *usize) ?Keybind {
    var kb: Keybind = .{};
    var have_key = false;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0 or part.len > key_name.len) return null;
        var low: [16]u8 = undefined;
        for (part, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        const w = low[0..part.len];
        if (std.mem.eql(u8, w, "ctrl") or std.mem.eql(u8, w, "control")) {
            kb.ctrl = true;
        } else if (std.mem.eql(u8, w, "shift")) {
            kb.shift = true;
        } else if (std.mem.eql(u8, w, "alt")) {
            kb.alt = true;
        } else if (std.mem.eql(u8, w, "super") or std.mem.eql(u8, w, "meta") or std.mem.eql(u8, w, "win") or std.mem.eql(u8, w, "cmd")) {
            kb.super = true;
        } else {
            if (have_key) return null;
            have_key = true;
            @memcpy(key_name[0..w.len], w);
            key_len.* = w.len;
        }
    }
    if (!have_key) return null;
    // Sem Ctrl/Alt/Super, uma letra dispararia enquanto se digita: só F1–F24.
    const name = key_name[0..key_len.*];
    const fkey = name.len >= 2 and name[0] == 'f' and std.ascii.isDigit(name[1]);
    if (!kb.ctrl and !kb.alt and !kb.super and !fkey) return null;
    // Ctrl+V e cia. acontecem o tempo todo digitando: um atalho aí seria um
    // "a pessoa pediu" que ela nunca pediu (e libera larper.send).
    if (kb.ctrl and !kb.shift and !kb.alt and !kb.super and name.len == 1 and std.mem.indexOfScalar(u8, "acvxyz", name[0]) != null) return null;
    var n: usize = 0;
    for ([_]struct { on: bool, s: []const u8 }{
        .{ .on = kb.ctrl, .s = "Ctrl+" },
        .{ .on = kb.alt, .s = "Alt+" },
        .{ .on = kb.shift, .s = "Shift+" },
        .{ .on = kb.super, .s = "Super+" },
    }) |m| if (m.on) {
        @memcpy(kb.label_buf[n..][0..m.s.len], m.s);
        n += m.s.len;
    };
    for (name, 0..) |ch, i| {
        kb.label_buf[n] = if (i == 0 or fkey) std.ascii.toUpper(ch) else ch;
        n += 1;
    }
    kb.label_len = @intCast(n);
    return kb;
}

/// larper.keybind("ctrl+shift+x", fn)
fn lKeybind(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const spec = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    var name: [16]u8 = undefined;
    var len: usize = 0;
    var kb = parseKeys(spec, &name, &len) orelse
        raise(L, tr("larper.keybind: use algo como \"ctrl+shift+x\" (letras e números pedem Ctrl, Alt ou Super; F1–F24 podem ir sozinhas)", "larper.keybind: use something like \"ctrl+shift+x\" (letters and digits need Ctrl, Alt or Super; F1–F24 can go alone)"));
    kb.key = p.engine.host.key(name[0..len]) orelse raise(L, tr("larper.keybind: tecla desconhecida", "larper.keybind: unknown key"));
    if (p.keys.items.len >= max_keys) raise(L, tr("larper.keybind: atalhos demais", "larper.keybind: too many keybinds"));
    registryList(L, "keys");
    const n = lua.lua_rawlen(L, -1);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawseti(L, -2, @intCast(n + 1));
    kb.slot = @intCast(n + 1);
    p.keys.append(p.engine.gpa, kb) catch raise(L, "sem memória");
    return 0;
}

/// larper.notify(texto)
fn lNotify(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const text = lua.checkSlice(L, 1);
    p.engine.host.notify(p.engine.host.ctx, p.name, text);
    return 0;
}

fn parseId(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch null;
}

/// O canal de larper.send: nil (o aberto), "123", 123 ou {id="123"}.
fn channelArg(L: ?*lua.State, idx: c_int) ?u64 {
    switch (lua.lua_type(L, idx)) {
        lua.TNIL => return 0,
        lua.TSTRING => return parseId(lua.toSlice(L, idx).?),
        lua.TNUMBER => {
            var ok: c_int = 0;
            const v = lua.lua_tointegerx(L, idx, &ok);
            return if (ok != 0 and v > 0) @intCast(v) else null;
        },
        lua.TTABLE => {
            _ = lua.lua_getfield(L, idx, "id");
            defer lua.pop(L, 1);
            return if (lua.lua_type(L, -1) == lua.TSTRING) parseId(lua.toSlice(L, -1).?) else null;
        },
        else => return null,
    }
}

/// larper.send(canal, texto): só dentro de um comando ou atalho da pessoa.
fn lSend(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    if (!p.user_call) raise(L, tr("larper.send só funciona dentro de larper.command ou larper.keybind (nunca em resposta automática)", "larper.send only works inside larper.command or larper.keybind (never as an automatic reply)"));
    const ch = channelArg(L, 1) orelse raise(L, tr("larper.send: canal inválido", "larper.send: invalid channel"));
    const text = lua.checkSlice(L, 2);
    if (text.len == 0 or text.len > 2000) raise(L, tr("larper.send: o texto precisa ter de 1 a 2000 bytes", "larper.send: the text must be 1 to 2000 bytes"));
    if (p.sends >= max_sends) raise(L, tr("larper.send: no máximo 5 mensagens por comando", "larper.send: at most 5 messages per command"));
    if (!p.engine.host.send(p.engine.host.ctx, ch, text)) raise(L, tr("larper.send: canal não encontrado", "larper.send: channel not found"));
    p.sends += 1;
    return 0;
}

/// larper.channel() -> {id, name} ou nil
fn lChannel(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const w = p.engine.host.where(p.engine.host.ctx);
    if (w.channel == 0) lua.lua_pushnil(L) else pushRef(L, w.channel, w.channel_name);
    return 1;
}

/// larper.guild() -> {id, name} ou nil (mensagens diretas)
fn lGuild(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const w = p.engine.host.where(p.engine.host.ctx);
    if (w.guild == 0) lua.lua_pushnil(L) else pushRef(L, w.guild, w.guild_name);
    return 1;
}

// --- Testes ------------------------------------------------------------------

const T = struct {
    var notes: [8][128]u8 = undefined;
    var notes_len: [8]usize = @splat(0);
    var n_notes: usize = 0;
    var sent: [8][128]u8 = undefined;
    var sent_len: [8]usize = @splat(0);
    var sent_ch: [8]u64 = @splat(0);
    var n_sent: usize = 0;
    var n_failed: usize = 0;
    var dummy: u8 = 0;

    fn reset() void {
        n_notes = 0;
        n_sent = 0;
        n_failed = 0;
    }
    fn note(i: usize) []const u8 {
        return notes[i][0..notes_len[i]];
    }
    fn notify(_: *anyopaque, _: []const u8, text: []const u8) void {
        if (n_notes == notes.len) return;
        const k = @min(text.len, 128);
        @memcpy(notes[n_notes][0..k], text[0..k]);
        notes_len[n_notes] = k;
        n_notes += 1;
    }
    fn send(_: *anyopaque, ch: u64, text: []const u8) bool {
        if (n_sent == sent.len) return false;
        const k = @min(text.len, 128);
        @memcpy(sent[n_sent][0..k], text[0..k]);
        sent_len[n_sent] = k;
        sent_ch[n_sent] = if (ch == 0) 42 else ch;
        n_sent += 1;
        return true;
    }
    fn where(_: *anyopaque) Where {
        return .{ .channel = 42, .channel_name = "geral", .guild = 7, .guild_name = "Servidor" };
    }
    fn key(name: []const u8) ?i32 {
        if (name.len == 1 and std.ascii.isAlphabetic(name[0])) return name[0];
        if (std.mem.eql(u8, name, "f5")) return 500;
        return null;
    }
    fn nop(_: *anyopaque) void {}
    fn failed(_: *anyopaque, _: []const u8, _: []const u8) void {
        n_failed += 1;
    }
    fn engine() Engine {
        reset();
        return Engine.init(std.testing.allocator, .{
            .ctx = &dummy,
            .notify = &notify,
            .send = &send,
            .where = &where,
            .key = &key,
            .rescan = &nop,
            .save = &nop,
            .failed = &failed,
        });
    }
};

fn testOne(e: *Engine, src: []const u8) *Plugin {
    e.load(&.{.{ .name = "t.lua", .src = src }}, false);
    return e.list.items[0];
}

test "plugins: sandbox só com as bibliotecas permitidas" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\local fora = { io, require, load, loadfile, dofile, debug, package, coroutine,
        \\  collectgarbage, string.dump, os.execute, os.getenv, os.remove, os.exit }
        \\for i = 1, 14 do assert(fora[i] == nil, "vazou " .. i) end
        \\assert(type(os.time()) == "number" and type(os.date("%Y")) == "string")
        \\assert(string.upper("a") == "A" and math.max(1, 2) == 2 and utf8.char(227) == "ã")
        \\assert(table.concat({ "a", "b" }, ",") == "a,b" and ("x"):rep(3) == "xxx")
        \\larper.notify("ok")
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqualStrings("ok", T.note(0));
}

test "plugins: laço infinito é parado, nem pcall segura" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 200_000;
    const p = testOne(&e, "while true do end");
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "limite") != null);

    const q = testOne(&e,
        \\larper.command("/x", function()
        \\  while true do pcall(function() while true do end end) end
        \\end)
    );
    try std.testing.expectEqual(Status.running, q.status());
    try std.testing.expect(e.command("/x"));
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_commands);
    // Parado, o comando volta a ir como texto.
    try std.testing.expect(!e.command("/x"));
}

test "plugins: erro de sintaxe e erro em tempo de execução" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "larper.on('message', function( end");
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.startsWith(u8, p.err().?, "t.lua:1:"));

    const q = testOne(&e, "larper.on('message', function(m) error('quebrou') end)");
    const m: Message = .{ .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onMessage(&m);
    try std.testing.expectEqual(Status.running, q.status());
    try std.testing.expect(std.mem.indexOf(u8, q.err().?, "quebrou") != null);
    try std.testing.expectEqual(@as(usize, 2), T.n_failed); // sintaxe + quebrou
    // Erro toda hora: para depois de 10.
    for (0..9) |_| e.onMessage(&m);
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_message);
}

test "plugins: send só em comando/atalho, nunca em resposta a mensagem" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\larper.on("message", function(msg)
        \\  if msg.content:find("bom dia") then larper.send(msg.channel, "bom dia, " .. msg.author.name) end
        \\end)
        \\larper.command("/shrug", function(args)
        \\  larper.send(larper.channel(), (args ~= "" and args .. " " or "") .. "¯\\_(ツ)_/¯")
        \\end)
        \\larper.keybind("Ctrl+Shift+X", function() larper.send("99", "atalho") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(u32, 1), e.n_keys);
    try std.testing.expectEqualStrings("Ctrl+Shift+X", p.keys.items[0].label());

    const m: Message = .{ .content = "bom dia!", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral", .guild = 7, .guild_name = "S" };
    e.onMessage(&m);
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "larper.send") != null);

    try std.testing.expect(e.command("/shrug oi"));
    try std.testing.expect(!e.command("/outro"));
    try std.testing.expect(!e.command("shrug"));
    try std.testing.expectEqual(@as(usize, 1), T.n_sent);
    try std.testing.expectEqualStrings("oi ¯\\_(ツ)_/¯", T.sent[0][0..T.sent_len[0]]);
    try std.testing.expectEqual(@as(u64, 42), T.sent_ch[0]);

    const P = struct {
        fn all(_: *anyopaque, _: *const Keybind) bool {
            return true;
        }
    };
    e.pollKeys(&T.dummy, &P.all);
    try std.testing.expectEqual(@as(usize, 2), T.n_sent);
    try std.testing.expectEqual(@as(u64, 99), T.sent_ch[1]);
}

test "plugins: atalhos inválidos e teto de memória" {
    var name: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(parseKeys("x", &name, &len) == null);
    try std.testing.expect(parseKeys("shift+a", &name, &len) == null);
    try std.testing.expect(parseKeys("ctrl+a+b", &name, &len) == null);
    try std.testing.expect(parseKeys("f5", &name, &len) != null);
    try std.testing.expectEqualStrings("Alt+F5", parseKeys("alt+F5", &name, &len).?.label());

    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\local ok, err = pcall(function()
        \\  local t = {}
        \\  for i = 1, 1e8 do t[i] = ("x"):rep(64) .. i end
        \\end)
        \\larper.notify(tostring(err))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "memory") != null);
    try std.testing.expect(p.mem < mem_cap);
}

test "plugins: desligar, religar e ready" {
    var e = T.engine();
    defer e.deinit();
    e.load(&.{
        .{ .name = "a.lua", .src = "larper.on('ready', function() larper.notify('pronto a') end)" },
        .{ .name = "b.lua", .src = "larper.command('/b', function() larper.notify('b') end)" },
    }, true);
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
    e.setEnabled(e.list.items[1], false);
    try std.testing.expect(e.disabled.contains("b.lua"));
    try std.testing.expect(!e.command("/b"));
    // Recarregar lembra quem está desligado.
    e.load(&.{
        .{ .name = "a.lua", .src = "larper.on('ready', function() larper.notify('pronto a') end)" },
        .{ .name = "b.lua", .src = "larper.command('/b', function() larper.notify('b') end)" },
    }, true);
    try std.testing.expectEqual(Status.off, e.list.items[1].status());
    e.setEnabled(e.list.items[1], true);
    try std.testing.expect(e.command("/b"));
    try std.testing.expectEqualStrings("b", T.note(T.n_notes - 1));
}

test "plugins: nada trava o app dentro de C (__gc, string.rep, padrões, table)" {
    var e = T.engine();
    defer e.deinit();
    // __gc roda com o gancho desligado: nem chega a ser aceito.
    const gc = testOne(&e,
        \\local ok, err = pcall(setmetatable, {}, {__gc = function() while true do end end})
        \\larper.notify(tostring(ok) .. " " .. tostring(err))
    );
    try std.testing.expectEqual(Status.running, gc.status());
    try std.testing.expect(std.mem.startsWith(u8, T.note(0), "false"));
    T.reset();
    _ = testOne(&e,
        \\local t = setmetatable({}, {__index = function() return 1 end})
        \\larper.notify(tostring(t.x))
        \\local p = setmetatable({}, {__metatable = "não"})
        \\larper.notify(tostring(pcall(setmetatable, p, {})))
        \\larper.notify(tostring(pcall(setmetatable, 1, {})))
        \\larper.notify(#string.rep("", 1000000000000000000) .. "")
        \\local s = string.rep("a", 100000)
        \\larper.notify(tostring(pcall(string.find, s, ".-.-.-.-.-.-.-.-b")))
        \\larper.notify(tostring(pcall(table.move, {}, 1, 1000000000000000, 2)))
        \\local big = setmetatable({}, {__len = function() return 1000000000000000 end})
        \\larper.notify(tostring(pcall(table.insert, big, 1, "x")))
        \\larper.notify(tostring(pcall(table.remove, big, 1)))
    );
    try std.testing.expectEqualStrings("1", T.note(0));
    try std.testing.expectEqualStrings("false", T.note(1));
    try std.testing.expectEqualStrings("false", T.note(2));
    try std.testing.expectEqualStrings("0", T.note(3));
    for (4..8) |i| try std.testing.expectEqualStrings("false", T.note(i));
}

test "plugins: erro que não é texto e atalhos do dia a dia" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "error(123)");
    try std.testing.expect(p.err() != null);

    var name: [16]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ "ctrl+v", "ctrl+c", "ctrl+a", "ctrl+x", "ctrl+z", "ctrl+y" }) |k| try std.testing.expect(parseKeys(k, &name, &len) == null);
    try std.testing.expect(parseKeys("ctrl+shift+v", &name, &len) != null);
    try std.testing.expect(parseKeys("alt+v", &name, &len) != null);
}
