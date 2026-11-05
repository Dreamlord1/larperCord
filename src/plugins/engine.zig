//! Plugins em Lua 5.4: scripts pequenos em ~/.config/larpercord/plugins/*.lua
//! que reagem a eventos e criam comandos, painéis e menus, sem recompilar.
//!
//! Este é o lado da interface. O Lua roda em outra thread (runtime.zig) e as duas
//! só conversam por filas (wire.zig): um plugin nunca segura um quadro, e o que
//! a interface mostra dele (comandos, painel, erro) é uma cópia que ela mesma
//! guarda. Tudo aqui é da thread da interface.
//!
//! Sem plugin ligado, a thread não existe e nenhum `lua_State` é criado; os
//! ganchos do app só comparam um contador com zero.
//!
//! Este arquivo não depende de janela: o app entra pelo `Host` (ver host.zig) e
//! os testes usam um `Host` falso.
const std = @import("std");
const wire = @import("wire.zig");
const runtime = @import("runtime.zig");
const manifest = @import("manifest.zig");
pub const panel = @import("panel.zig");
pub const deco = @import("deco.zig");
const sync = @import("sync.zig");
const kdl = @import("../theme/kdl.zig");

pub const max_plugins = runtime.max_plugins;
pub const max_source = runtime.max_source;
pub const mem_cap = runtime.mem_cap;
pub const Where = wire.Where;
pub const Message = wire.Message;
pub const Host = wire.Host;
pub const Source = wire.Source;
pub const Keybind = wire.Keybind;
pub const LspServer = wire.LspServer;
pub const MenuKind = wire.MenuKind;
pub const MenuEntry = wire.MenuEntry;
pub const MsgList = wire.MsgList;
pub const HttpReq = wire.HttpReq;
pub const HttpRes = wire.HttpRes;
pub const HttpError = wire.HttpError;
pub const Cap = manifest.Cap;
pub const parseKeys = runtime.parseKeys;

/// O plugin aberto na página de configurações e os ganchos do app.
pub var current: ?*Engine = null;

/// Quantos pedidos dos plugins a interface atende de cada vez: uma rajada se
/// espalha por vários acordares em vez de pesar num só.
const drain_budget = 512;
/// Gestos lembrados por plugin (a resposta de um pode chegar depois do próximo).
const token_ring = 4;

pub const Status = enum { off, running, failed, waiting };

pub const Plugin = struct {
    engine: *Engine,
    name: []u8,
    src: []u8,
    /// Lido do começo do arquivo, sem rodar nada (aponta para `src`).
    man: manifest.Manifest = .{},
    slot: u16 = 0,
    enabled: bool = true,
    /// Identifica esta partida na thread dos plugins (0 = não está rodando).
    /// O que chega de uma partida velha é ignorado.
    run: u32 = 0,
    err_buf: [300]u8 = undefined,
    err_len: u16 = 0,
    n_message: u16 = 0,
    n_ready: u16 = 0,
    n_delete: u16 = 0,
    n_channel: u16 = 0,
    n_lang: u16 = 0,
    commands: std.ArrayList([]u8) = .empty,
    keys: std.ArrayList(Keybind) = .empty,
    lsp: std.ArrayList(LspServer) = .empty,
    menus: std.ArrayList(MenuEntry) = .empty,
    /// O painel que o plugin publicou.
    tree: ?*panel.Tree = null,
    /// Pediu para abrir antes de a árvore chegar.
    want_open: bool = false,
    /// Gestos da pessoa neste plugin: só eles liberam enviar, inserir e pular.
    tokens: [token_ring]u32 = @splat(0),
    token_at: u8 = 0,

    pub fn isRunning(p: *const Plugin) bool {
        return p.run != 0;
    }

    pub fn status(p: *const Plugin) Status {
        if (p.run != 0) return .running;
        if (!p.enabled) return .off;
        return if (p.err_len > 0) .failed else .waiting;
    }

    pub fn err(p: *const Plugin) ?[]const u8 {
        return if (p.err_len > 0) p.err_buf[0..p.err_len] else null;
    }

    /// Bytes de Lua agora.
    pub fn memBytes(p: *const Plugin) usize {
        const w = p.engine.worker orelse return 0;
        return w.mem[p.slot].load(.monotonic);
    }

    pub fn title(p: *const Plugin) []const u8 {
        return p.man.title(runtime.lang_en(), p.name);
    }

    pub fn about(p: *const Plugin) []const u8 {
        return p.man.about(runtime.lang_en());
    }

    fn setErr(p: *Plugin, msg: []const u8) void {
        var n = @min(msg.len, p.err_buf.len);
        // Sem cortar um caractere no meio.
        while (n > 0 and n < msg.len and (msg[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(p.err_buf[0..n], msg[0..n]);
        p.err_len = @intCast(n);
    }

    fn validToken(p: *const Plugin, t: u32) bool {
        if (t == 0) return false;
        for (p.tokens) |k| if (k == t) return true;
        return false;
    }
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    host: Host,
    list: std.ArrayList(*Plugin) = .empty,
    /// Nomes desligados pela pessoa (persistidos pelo app).
    disabled: std.StringHashMapUnmanaged(void) = .empty,
    /// Hosts aprovados: "arquivo.lua\x00host" (persistidos pelo app).
    approvals: std.StringHashMapUnmanaged(void) = .empty,
    /// Muda a cada carga, troca ou erro (a página e o QA observam).
    generation: u32 = 0,
    /// Somas dos plugins rodando: com zero, os ganchos nem entram.
    n_message: u32 = 0,
    n_ready: u32 = 0,
    n_delete: u32 = 0,
    n_channel: u32 = 0,
    n_lang: u32 = 0,
    n_commands: u32 = 0,
    n_keys: u32 = 0,
    n_running: u32 = 0,
    /// O app já recebeu o READY (plugin ligado depois recebe "ready" na hora).
    ready: bool = false,
    /// Plugins só rodam com uma conta aberta: o armazenamento é por conta.
    account: u64 = 0,
    /// Instruções por chamada.
    budget: u32 = 5_000_000,
    /// Pasta lida (para a página de configurações).
    dir_buf: [512]u8 = undefined,
    dir_len: u16 = 0,
    worker: ?*runtime.Worker = null,
    batch: std.ArrayList(wire.Cmd) = .empty,
    batch_at: usize = 0,
    next_run: u32 = 1,
    next_token: u32 = 1,
    next_serial: u32 = 0,
    deco: deco.Index,
    /// Painel lateral: qual está aberto, de que lado e a largura.
    panel_open: ?*Plugin = null,
    panel_left: bool = false,
    panel_w: f32 = 340,
    /// Muda quando uma árvore chega ou o painel troca (a interface e o QA observam).
    panel_gen: u32 = 0,
    /// Abrir este quando a árvore dele chegar (recarregou, ou o app reabriu).
    panel_wanted: [120]u8 = undefined,
    panel_wanted_len: u8 = 0,
    last_channel: u64 = 0,
    last_en: bool = false,

    pub fn init(gpa: std.mem.Allocator, host: Host) Engine {
        return .{ .gpa = gpa, .host = host, .deco = deco.Index.init(gpa) };
    }

    pub fn deinit(e: *Engine) void {
        e.host.http_stop();
        if (e.worker) |w| {
            for (e.list.items) |p| if (p.run != 0) w.push(.{ .stop = p.run });
            w.join(true);
            e.dropBatch();
            w.takeOut(&e.batch);
            e.dropBatch();
            w.destroy();
        }
        e.batch.deinit(e.gpa);
        e.worker = null;
        e.freeViews();
        e.list.deinit(e.gpa);
        var it = e.disabled.keyIterator();
        while (it.next()) |k| e.gpa.free(k.*);
        e.disabled.deinit(e.gpa);
        var ap = e.approvals.keyIterator();
        while (ap.next()) |k| e.gpa.free(k.*);
        e.approvals.deinit(e.gpa);
        e.deco.deinit();
        if (current == e) current = null;
    }

    fn dropBatch(e: *Engine) void {
        for (e.batch.items[e.batch_at..]) |*cmd| runtime.freeCmd(e.gpa, cmd);
        e.batch.clearRetainingCapacity();
        e.batch_at = 0;
    }

    pub fn dir(e: *const Engine) []const u8 {
        return e.dir_buf[0..e.dir_len];
    }

    pub fn setDir(e: *Engine, path: []const u8) void {
        const n = @min(path.len, e.dir_buf.len);
        @memcpy(e.dir_buf[0..n], path[0..n]);
        e.dir_len = @intCast(n);
    }

    /// A thread está de pé? (Sem plugin ligado, não: o QA confere.)
    pub fn threadRunning(e: *const Engine) bool {
        const w = e.worker orelse return false;
        return w.thread != null;
    }

    fn freeViews(e: *Engine) void {
        for (e.list.items) |p| {
            e.forgetRun(p);
            e.gpa.free(p.name);
            e.gpa.free(p.src);
            p.commands.deinit(e.gpa);
            p.keys.deinit(e.gpa);
            p.lsp.deinit(e.gpa);
            p.menus.deinit(e.gpa);
            e.gpa.destroy(p);
        }
        e.list.clearRetainingCapacity();
        e.recount();
    }

    /// Troca todos os plugins pelos arquivos dados (já em ordem).
    /// `app_ready`: o app já está conectado (dispara "ready" nos novos).
    pub fn load(e: *Engine, files: []const Source, app_ready: bool) void {
        e.rememberPanel();
        for (e.list.items) |p| e.stopRun(p);
        e.freeViews();
        e.ready = app_ready;
        for (files[0..@min(files.len, max_plugins)], 0..) |f, i| {
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
            p.* = .{ .engine = e, .name = name, .src = src, .slot = @intCast(i), .enabled = !e.disabled.contains(f.name), .man = manifest.parse(src) };
            e.list.append(e.gpa, p) catch {
                e.gpa.free(name);
                e.gpa.free(src);
                e.gpa.destroy(p);
                break;
            };
            if (p.enabled) e.startRun(p);
        }
        e.settle();
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
        p.err_len = 0;
        if (on) {
            if (e.disabled.fetchRemove(p.name)) |kv| e.gpa.free(kv.key);
            e.startRun(p);
        } else {
            e.setDisabledName(p.name);
            e.stopRun(p);
        }
        e.settle();
        e.host.save(e.host.ctx);
    }

    /// A conta aberta mudou (0 = nenhuma): os plugins rodam de novo, com os dados dela.
    pub fn setAccount(e: *Engine, id: u64) void {
        if (e.account == id) return;
        e.rememberPanel();
        for (e.list.items) |p| e.stopRun(p);
        e.account = id;
        e.ready = false;
        if (id != 0) for (e.list.items) |p| {
            if (p.enabled) e.startRun(p);
        };
        e.settle();
    }

    /// Depois de ligar/desligar: conta de novo e, sem ninguém rodando, a thread sai.
    fn settle(e: *Engine) void {
        e.recount();
        e.generation +%= 1;
        if (e.n_running == 0) if (e.worker) |w| {
            if (w.thread != null) w.retire();
        };
    }

    fn startRun(e: *Engine, p: *Plugin) void {
        if (e.account == 0 or p.run != 0) return;
        const w = e.ensureThread() orelse {
            p.setErr(runtime_tr("não consegui iniciar a thread dos plugins", "couldn't start the plugin thread"));
            return;
        };
        p.err_len = 0;
        const run = e.next_run;
        e.next_run +%= 1;
        if (e.next_run == 0) e.next_run = 1;
        const args = e.gpa.create(wire.StartArgs) catch return;
        const name = e.gpa.dupe(u8, p.name) catch {
            e.gpa.destroy(args);
            return;
        };
        const src = e.gpa.dupe(u8, p.src) catch {
            e.gpa.free(name);
            e.gpa.destroy(args);
            return;
        };
        args.* = .{ .run = run, .slot = p.slot, .account = e.account, .name = name, .src = src, .approved = e.approvedFor(p), .fire_ready = e.ready, .budget = e.budget };
        p.run = run;
        e.publishWhere(w);
        w.push(.{ .start = args });
    }

    fn stopRun(e: *Engine, p: *Plugin) void {
        if (p.run == 0) return;
        if (e.worker) |w| w.push(.{ .stop = p.run });
        e.forgetRun(p);
    }

    /// Tudo o que a interface guardava desta partida some na hora.
    fn forgetRun(e: *Engine, p: *Plugin) void {
        if (p.run != 0) e.deco.clearRun(p.run);
        p.run = 0;
        for (p.commands.items) |s| e.gpa.free(s);
        p.commands.clearRetainingCapacity();
        p.keys.clearRetainingCapacity();
        p.lsp.clearRetainingCapacity();
        for (p.menus.items) |*m| {
            e.gpa.free(m.pt);
            e.gpa.free(m.en);
        }
        p.menus.clearRetainingCapacity();
        p.n_message = 0;
        p.n_ready = 0;
        p.n_delete = 0;
        p.n_channel = 0;
        p.n_lang = 0;
        p.want_open = false;
        if (p.tree) |t| t.destroy();
        p.tree = null;
        if (e.panel_open == p) e.panel_open = null;
        e.panel_gen +%= 1;
    }

    fn ensureThread(e: *Engine) ?*runtime.Worker {
        const w = e.worker orelse blk: {
            const nw = runtime.Worker.create(e.gpa, e.host) catch return null;
            e.worker = nw;
            break :blk nw;
        };
        // Saindo: espera acabar (é rápido), para quem liga de novo ler o que ela gravou.
        if (w.thread != null and w.quit) w.join(false);
        return if (w.start()) w else null;
    }

    fn recount(e: *Engine) void {
        e.n_message = 0;
        e.n_ready = 0;
        e.n_delete = 0;
        e.n_channel = 0;
        e.n_lang = 0;
        e.n_commands = 0;
        e.n_keys = 0;
        e.n_running = 0;
        for (e.list.items) |p| if (p.run != 0) {
            e.n_running += 1;
            e.n_message += p.n_message;
            e.n_ready += p.n_ready;
            e.n_delete += p.n_delete;
            e.n_channel += p.n_channel;
            e.n_lang += p.n_lang;
            e.n_commands += @intCast(p.commands.items.len);
            e.n_keys += @intCast(p.keys.items.len);
        };
    }

    // --- Hosts aprovados ----------------------------------------------------------

    fn approvalKey(buf: []u8, plugin: []const u8, host: []const u8) ?[]const u8 {
        if (plugin.len + host.len + 1 > buf.len) return null;
        return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ plugin, host }) catch null;
    }

    pub fn isApproved(e: *const Engine, plugin: []const u8, host: []const u8) bool {
        var buf: [256]u8 = undefined;
        const k = approvalKey(&buf, plugin, host) orelse return false;
        return e.approvals.contains(k);
    }

    /// Ao ler as configurações salvas.
    pub fn setApprovedName(e: *Engine, plugin: []const u8, host: []const u8) void {
        if (e.isApproved(plugin, host)) return;
        var buf: [256]u8 = undefined;
        const k = approvalKey(&buf, plugin, host) orelse return;
        const own = e.gpa.dupe(u8, k) catch return;
        e.approvals.put(e.gpa, own, {}) catch e.gpa.free(own);
    }

    fn approvedFor(e: *Engine, p: *const Plugin) [][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        for (p.man.hostList()) |h| {
            if (!e.isApproved(p.name, h)) continue;
            const own = e.gpa.dupe(u8, h) catch continue;
            out.append(e.gpa, own) catch e.gpa.free(own);
        }
        return out.toOwnedSlice(e.gpa) catch &.{};
    }

    /// O interruptor da página: vale na hora, e fica salvo.
    pub fn setApproved(e: *Engine, p: *Plugin, host: []const u8, on: bool) void {
        if (on) {
            e.setApprovedName(p.name, host);
        } else {
            var buf: [256]u8 = undefined;
            const k = approvalKey(&buf, p.name, host) orelse return;
            if (e.approvals.fetchRemove(k)) |kv| e.gpa.free(kv.key);
        }
        e.generation +%= 1;
        if (p.run != 0) if (e.worker) |w| w.push(.{ .hosts = .{ .run = p.run, .approved = e.approvedFor(p) } });
        e.host.save(e.host.ctx);
    }

    // --- Eventos que o app manda ----------------------------------------------

    pub fn onMessage(e: *Engine, m: *const Message) void {
        if (e.n_message == 0) return;
        const w = e.worker orelse return;
        const own = wire.OwnedMsg.dup(e.gpa, m) orelse return;
        w.push(.{ .message = own });
    }

    pub fn onDelete(e: *Engine, channel: u64, id: u64) void {
        e.deco.removeMessage(id);
        if (e.n_delete == 0) return;
        if (e.worker) |w| w.push(.{ .delete = .{ .channel = channel, .id = id } });
    }

    pub fn fireReady(e: *Engine) void {
        e.ready = true;
        if (e.n_running == 0) return;
        if (e.worker) |w| w.push(.ready);
    }

    fn publishWhere(e: *Engine, w: *runtime.Worker) void {
        const wh = e.host.where(e.host.ctx);
        w.setWhere(wh);
        e.last_channel = wh.channel;
    }

    /// A cada quadro, com algum plugin rodando: o canal aberto mudou? O idioma?
    pub fn frameTick(e: *Engine, channel_now: u64, en: bool) void {
        if (e.n_running == 0) return;
        const w = e.worker orelse return;
        if (channel_now != e.last_channel) {
            e.publishWhere(w);
            if (e.n_channel > 0) w.push(.channel);
        }
        if (en != e.last_en) {
            e.last_en = en;
            e.generation +%= 1;
            if (e.n_lang > 0) w.push(.lang);
        }
    }

    fn newToken(e: *Engine, p: *Plugin) u32 {
        const t = e.next_token;
        e.next_token +%= 1;
        if (e.next_token == 0) e.next_token = 1;
        p.tokens[p.token_at] = t;
        p.token_at = (p.token_at + 1) % token_ring;
        return t;
    }

    fn gesture(e: *Engine, p: *Plugin, what: wire.Gesture) void {
        const w = e.worker orelse return;
        w.push(.{ .gesture = .{ .run = p.run, .token = e.newToken(p), .what = what } });
    }

    /// Texto digitado na caixa: "/nome args" de algum plugin? Se sim, roda
    /// e devolve true (não vai para o Discord).
    pub fn command(e: *Engine, text: []const u8) bool {
        if (e.n_commands == 0 or text.len < 2 or text[0] != '/') return false;
        const sp = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
        const name = text[0..sp];
        const args = std.mem.trim(u8, text[sp..], " \t\n");
        for (e.list.items) |p| {
            if (p.run == 0) continue;
            for (p.commands.items) |cmd| if (std.mem.eql(u8, cmd, name)) {
                const n = e.gpa.dupe(u8, name) catch return true;
                const a = e.gpa.dupe(u8, args) catch {
                    e.gpa.free(n);
                    return true;
                };
                e.gesture(p, .{ .command = .{ .name = n, .args = a } });
                return true;
            };
        }
        return false;
    }

    /// Roda os atalhos cujas teclas `pressed` diz que foram apertadas.
    pub fn pollKeys(e: *Engine, ctx: *anyopaque, pressed: *const fn (ctx: *anyopaque, k: *const Keybind) bool) void {
        if (e.n_keys == 0) return;
        for (e.list.items) |p| {
            if (p.run == 0) continue;
            for (p.keys.items) |*k| {
                if (pressed(ctx, k)) e.gesture(p, .{ .key = k.slot });
            }
        }
    }

    // --- Menus e painel (a interface chama) -------------------------------------

    /// Clicou numa entrada de menu num mensagem.
    pub fn menuMessage(e: *Engine, p: *Plugin, entry: *const MenuEntry, m: *const Message) void {
        if (p.run == 0) return;
        const own = wire.OwnedMsg.dup(e.gpa, m) orelse return;
        e.gesture(p, .{ .menu_message = .{ .slot = entry.slot, .msg = own } });
    }

    pub fn menuUser(e: *Engine, p: *Plugin, entry: *const MenuEntry, id: u64, name: []const u8) void {
        if (p.run == 0) return;
        const own = e.gpa.dupe(u8, name) catch return;
        e.gesture(p, .{ .menu_user = .{ .slot = entry.slot, .id = id, .name = own } });
    }

    /// Clicou num botão ou item do painel, ou enviou um campo com Enter: é gesto.
    pub fn panelGesture(e: *Engine, p: *Plugin, handle: u32, value: ?[]const u8) void {
        if (p.run == 0 or handle == 0) return;
        const v = if (value) |x| (e.gpa.dupe(u8, x) catch return) else null;
        e.gesture(p, .{ .panel = .{ .handle = handle, .value = v } });
    }

    /// O texto de um campo mudou. Não conta como gesto: digitar não libera enviar.
    pub fn panelChange(e: *Engine, p: *Plugin, handle: u32, value: []const u8) void {
        if (p.run == 0 or handle == 0) return;
        const w = e.worker orelse return;
        const v = e.gpa.dupe(u8, value) catch return;
        w.push(.{ .gesture = .{ .run = p.run, .token = 0, .what = .{ .panel = .{ .handle = handle, .value = v } } } });
    }

    fn rememberPanel(e: *Engine) void {
        const p = e.panel_open orelse return;
        e.wantPanel(p.name);
    }

    fn wantPanel(e: *Engine, name: []const u8) void {
        if (name.len > e.panel_wanted.len) return;
        @memcpy(e.panel_wanted[0..name.len], name);
        e.panel_wanted_len = @intCast(name.len);
    }

    pub fn openPanel(e: *Engine, p: ?*Plugin) void {
        e.panel_wanted_len = 0;
        if (e.panel_open == p) return;
        if (e.worker) |w| {
            if (e.panel_open) |old| if (old.run != 0) w.push(.{ .panel_state = .{ .run = old.run, .open = false } });
            if (p) |now| if (now.run != 0) w.push(.{ .panel_state = .{ .run = now.run, .open = true } });
        }
        e.panel_open = p;
        e.panel_gen +%= 1;
    }

    /// Quantos plugins têm painel publicado.
    pub fn panelCount(e: *const Engine) usize {
        var n: usize = 0;
        for (e.list.items) |p| {
            if (p.tree != null) n += 1;
        }
        return n;
    }

    // --- O que os plugins pediram --------------------------------------------------

    /// Atende os pedidos que chegaram da thread dos plugins. Só na thread da
    /// interface e fora do quadro: troca árvores e listas que o desenho lê.
    pub fn drain(e: *Engine) void {
        const w = e.worker orelse return;
        if (w.thread != null and w.exited.load(.acquire)) w.join(false);
        if (e.batch_at >= e.batch.items.len) {
            e.batch.clearRetainingCapacity();
            e.batch_at = 0;
            w.takeOut(&e.batch);
        }
        const end = @min(e.batch.items.len, e.batch_at + drain_budget);
        for (e.batch.items[e.batch_at..end]) |*cmd| e.apply(cmd);
        e.batch_at = end;
        if (e.batch_at < e.batch.items.len) e.host.wake(e.host.ctx);
    }

    fn byRun(e: *Engine, run: u32) ?*Plugin {
        if (run == 0) return null;
        for (e.list.items) |p| if (p.run == run) return p;
        return null;
    }

    /// Assume `cmd`.
    fn apply(e: *Engine, cmd: *wire.Cmd) void {
        // De uma partida que já acabou: joga fora.
        const p = e.byRun(cmd.run) orelse return runtime.freeCmd(e.gpa, cmd);
        switch (cmd.what) {
            .reg => |reg| {
                e.takeReg(p, reg);
                e.recount();
                e.generation +%= 1;
            },
            .failed => |f| {
                p.setErr(f.msg);
                if (f.stopped) {
                    e.forgetRun(p);
                    e.settle();
                } else e.generation +%= 1;
                e.host.failed(e.host.ctx, p.name, p.err() orelse "");
                e.gpa.free(f.msg);
            },
            .notify => |n| {
                e.host.notify(e.host.ctx, p.title(), n.text, n.desktop);
                e.gpa.free(n.text);
            },
            .send => |s| {
                if (p.validToken(s.token) and !e.host.send(e.host.ctx, s.channel, s.text)) {
                    p.setErr(runtime_tr("larper.send: canal não encontrado", "larper.send: channel not found"));
                    e.generation +%= 1;
                    e.host.failed(e.host.ctx, p.name, p.err() orelse "");
                }
                e.gpa.free(s.text);
            },
            .insert => |s| {
                if (p.validToken(s.token)) e.host.insert(e.host.ctx, s.text);
                e.gpa.free(s.text);
            },
            .jump => |j| if (p.validToken(j.token)) e.host.jump(e.host.ctx, j.channel, j.id),
            .panel_tree => |t| {
                if (p.tree) |old| old.destroy();
                p.tree = t;
                e.next_serial +%= 1;
                t.serial = e.next_serial;
                e.panel_gen +%= 1;
                e.generation +%= 1;
                if (p.want_open or std.mem.eql(u8, e.panel_wanted[0..e.panel_wanted_len], p.name)) {
                    p.want_open = false;
                    e.openPanel(p);
                }
            },
            .panel_show => |s| {
                if (!s.open) {
                    p.want_open = false;
                    if (e.panel_open == p) e.openPanel(null);
                } else if (p.validToken(s.token)) {
                    if (p.tree != null) e.openPanel(p) else p.want_open = true;
                }
            },
            .deco_set => |s| {
                // Sem nada para mostrar nem recolher, é o mesmo que tirar.
                if (s.badge.len == 0 and s.note.len == 0 and !s.collapse) {
                    e.deco.remove(p.run, s.id);
                    e.gpa.free(s.badge);
                    e.gpa.free(s.note);
                    e.gpa.free(s.label);
                } else _ = e.deco.set(p.run, s.id, s.badge, s.note, s.label, s.collapse);
            },
            .deco_remove => |id| e.deco.remove(p.run, id),
            .deco_rules => |list| e.deco.setRules(p.run, list),
            .want_messages => |q| {
                const w = e.worker orelse return;
                const list = e.gpa.create(MsgList) catch return;
                list.* = .{ .gpa = e.gpa };
                e.host.messages(e.host.ctx, q.channel, q.limit, list);
                w.push(.{ .messages = .{ .run = cmd.run, .req = q.req, .list = list } });
            },
        }
    }

    fn takeReg(e: *Engine, p: *Plugin, reg: *wire.Reg) void {
        const a = e.gpa;
        for (p.commands.items) |s| a.free(s);
        p.commands.deinit(a);
        p.commands = .fromOwnedSlice(reg.commands);
        p.keys.deinit(a);
        p.keys = .fromOwnedSlice(reg.keys);
        p.lsp.deinit(a);
        p.lsp = .fromOwnedSlice(reg.lsp);
        for (p.menus.items) |*m| {
            a.free(m.pt);
            a.free(m.en);
        }
        p.menus.deinit(a);
        p.menus = .fromOwnedSlice(reg.menus);
        p.n_message = reg.n_message;
        p.n_ready = reg.n_ready;
        p.n_delete = reg.n_delete;
        p.n_channel = reg.n_channel;
        p.n_lang = reg.n_lang;
        a.destroy(reg);
    }

    // --- plugins.kdl -----------------------------------------------------------------

    /// `plugin "nome.lua" enabled=#false`, `host-ok "nome.lua" "api.exemplo.com"`,
    /// `panel side="left" width=340 open="nome.lua"`.
    pub fn applyPrefNode(e: *Engine, n: *const kdl.Node) void {
        if (std.mem.eql(u8, n.name, "plugin")) {
            const name = (n.arg(0) orelse return).asString() orelse return;
            if (n.flag("enabled") == false) e.setDisabledName(name);
        } else if (std.mem.eql(u8, n.name, "host-ok")) {
            const name = (n.arg(0) orelse return).asString() orelse return;
            const host = (n.arg(1) orelse return).asString() orelse return;
            e.setApprovedName(name, host);
        } else if (std.mem.eql(u8, n.name, "panel")) {
            if (n.str("side")) |s| e.panel_left = std.mem.eql(u8, s, "left");
            if (n.num("width")) |w| e.panel_w = @floatCast(std.math.clamp(w, 240, 900));
            if (n.str("open")) |name| e.wantPanel(name);
        }
    }

    fn kdlSafe(s: []const u8) bool {
        return std.mem.indexOfAny(u8, s, "\"\\\n") == null;
    }

    pub fn writePrefs(e: *const Engine, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "// gerado pelo larperCord: plugins desligados, hosts aprovados e o painel\n");
        var it = e.disabled.keyIterator();
        while (it.next()) |k| {
            // Nomes que o KDL precisaria escapar ficam de fora.
            if (!kdlSafe(k.*)) continue;
            try out.print(gpa, "plugin \"{s}\" enabled=#false\n", .{k.*});
        }
        var ap = e.approvals.keyIterator();
        while (ap.next()) |k| {
            const cut = std.mem.indexOfScalar(u8, k.*, 0) orelse continue;
            if (!kdlSafe(k.*[0..cut]) or !kdlSafe(k.*[cut + 1..])) continue;
            try out.print(gpa, "host-ok \"{s}\" \"{s}\"\n", .{ k.*[0..cut], k.*[cut + 1..] });
        }
        try out.print(gpa, "panel side=\"{s}\" width={d}", .{ if (e.panel_left) "left" else "right", @round(e.panel_w) });
        if (e.panel_open) |p| if (kdlSafe(p.name)) try out.print(gpa, " open=\"{s}\"", .{p.name});
        try out.append(gpa, '\n');
    }

    /// Espera a thread dos plugins terminar tudo o que tem (testes e QA).
    pub fn waitIdle(e: *Engine) void {
        const w = e.worker orelse return;
        var spins: u32 = 0;
        while (spins < 20_000) : (spins += 1) {
            e.drain();
            if (w.idle() and e.batch_at >= e.batch.items.len) return;
            sync.sleepMs(1);
        }
    }
};

fn runtime_tr(pt: []const u8, en: []const u8) []const u8 {
    return if (runtime.lang_en()) en else pt;
}

// --- Testes ------------------------------------------------------------------

const T = struct {
    var notes: [64][256]u8 = undefined;
    var notes_len: [64]usize = @splat(0);
    var notes_desktop: [64]bool = @splat(false);
    var n_notes: usize = 0;
    var sent: [16][128]u8 = undefined;
    var sent_len: [16]usize = @splat(0);
    var sent_ch: [16]u64 = @splat(0);
    var n_sent: usize = 0;
    var n_failed: usize = 0;
    var inserted: [256]u8 = undefined;
    var inserted_len: usize = 0;
    var jumps: usize = 0;
    var jump_id: u64 = 0;
    var dummy: u8 = 0;
    var loaded: []const Message = &.{};
    // O "disco" do armazenamento, usado pela thread dos plugins.
    var disk_lock: ?sync.Lock = null;
    var disk: [8]struct { name: [32]u8 = undefined, name_len: usize = 0, data: [2 * 1024 * 1024]u8 = undefined, len: usize = 0 } = undefined;
    var disk_n: usize = 0;
    var broken: usize = 0;
    // Pedidos HTTP: o teste responde com `respond`.
    var http_reqs: [8]?*HttpReq = @splat(null);
    var http_n: usize = 0;

    fn lock() *sync.Lock {
        if (disk_lock == null) disk_lock = sync.lockInit();
        return &disk_lock.?;
    }

    fn reset() void {
        n_notes = 0;
        n_sent = 0;
        n_failed = 0;
        inserted_len = 0;
        jumps = 0;
        loaded = &.{};
    }
    fn wipeDisk() void {
        const l = lock();
        l.lock();
        defer l.unlock();
        disk_n = 0;
        broken = 0;
    }
    fn note(i: usize) []const u8 {
        return notes[i][0..notes_len[i]];
    }
    fn notify(_: *anyopaque, _: []const u8, text: []const u8, desktop: bool) void {
        if (n_notes == notes.len) return;
        const k = @min(text.len, 256);
        @memcpy(notes[n_notes][0..k], text[0..k]);
        notes_len[n_notes] = k;
        notes_desktop[n_notes] = desktop;
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
    fn insert(_: *anyopaque, text: []const u8) void {
        const k = @min(text.len, inserted.len - inserted_len);
        @memcpy(inserted[inserted_len..][0..k], text[0..k]);
        inserted_len += k;
    }
    fn jump(_: *anyopaque, _: u64, id: u64) void {
        jumps += 1;
        jump_id = id;
    }
    fn messages(_: *anyopaque, _: u64, limit: u32, out: *MsgList) void {
        for (loaded[0..@min(loaded.len, limit)]) |*m| out.add(m);
    }
    fn readData(_: *anyopaque, gpa: std.mem.Allocator, _: u64, plugin: []const u8) ?[]u8 {
        const l = lock();
        l.lock();
        defer l.unlock();
        for (disk[0..disk_n]) |*d| if (std.mem.eql(u8, d.name[0..d.name_len], plugin)) {
            return gpa.dupe(u8, d.data[0..d.len]) catch null;
        };
        return null;
    }
    fn writeData(_: *anyopaque, _: u64, plugin: []const u8, bytes: []const u8) bool {
        const l = lock();
        l.lock();
        defer l.unlock();
        const slot = for (disk[0..disk_n]) |*d| {
            if (std.mem.eql(u8, d.name[0..d.name_len], plugin)) break d;
        } else blk: {
            const d = &disk[disk_n];
            disk_n += 1;
            @memcpy(d.name[0..plugin.len], plugin);
            d.name_len = plugin.len;
            break :blk d;
        };
        @memcpy(slot.data[0..bytes.len], bytes);
        slot.len = bytes.len;
        return true;
    }
    fn keepBroken(_: *anyopaque, _: u64, _: []const u8) void {
        broken += 1;
    }
    fn httpStart(req: *HttpReq) bool {
        const l = lock();
        l.lock();
        defer l.unlock();
        if (http_n == http_reqs.len) return false;
        http_reqs[http_n] = req;
        http_n += 1;
        return true;
    }
    fn httpStop() void {
        while (http_n > 0) {
            http_n -= 1;
            if (http_reqs[http_n]) |r| r.free();
            http_reqs[http_n] = null;
        }
    }
    fn respond(status: u16, body: []const u8) void {
        const req = blk: {
            const l = lock();
            l.lock();
            defer l.unlock();
            http_n -= 1;
            break :blk http_reqs[http_n].?;
        };
        const res = req.gpa.create(HttpRes) catch unreachable;
        res.* = .{ .run = req.run, .id = req.id, .status = status, .body = req.gpa.dupe(u8, body) catch unreachable };
        req.done(req.done_ctx, res);
        req.free();
    }
    fn engine() Engine {
        reset();
        var e = Engine.init(std.testing.allocator, .{
            .ctx = &dummy,
            .notify = &notify,
            .send = &send,
            .where = &where,
            .key = &key,
            .rescan = &nop,
            .save = &nop,
            .failed = &failed,
            .insert = &insert,
            .jump = &jump,
            .messages = &messages,
            .wake = &nop,
            .read_data = &readData,
            .write_data = &writeData,
            .keep_broken_data = &keepBroken,
            .http_start = &httpStart,
            .http_stop = &httpStop,
        });
        e.account = 1;
        return e;
    }
};

fn testOne(e: *Engine, src: []const u8) *Plugin {
    e.load(&.{.{ .name = "t.lua", .src = src }}, false);
    e.waitIdle();
    return e.list.items[0];
}

fn cmdOk(e: *Engine, text: []const u8) !void {
    try std.testing.expect(e.command(text));
    e.waitIdle();
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

test "plugins: sem plugin ligado não há thread nem estado de Lua" {
    var e = T.engine();
    defer e.deinit();
    e.setDisabledName("a.lua");
    e.load(&.{.{ .name = "a.lua", .src = "-- @name A\nerror('nunca roda')" }}, false);
    e.waitIdle();
    try std.testing.expect(e.worker == null);
    try std.testing.expect(!e.threadRunning());
    const p = e.list.items[0];
    try std.testing.expectEqual(Status.off, p.status());
    // O cabeçalho aparece mesmo assim.
    try std.testing.expectEqualStrings("A", p.title());
    // Ligou: a thread sobe. Desligou o último: ela sai.
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(e.threadRunning() or p.status() == .failed);
    e.setEnabled(p, false);
    var spins: usize = 0;
    while (e.threadRunning() and spins < 5000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expect(!e.threadRunning());
    // E religar depois disso funciona.
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expectEqual(Status.failed, p.status());
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "nunca roda") != null);
}

test "plugins: larper.lsp só guarda a proposta e valida tudo" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\larper.lsp("zig", {"zls"})
        \\larper.lsp("haskell", {"hls", "--lsp"})
        \\larper.lsp("zig", {"/opt/zls", "--x"})
        \\local ruins = {
        \\  function() larper.lsp("Zig", {"a"}) end,
        \\  function() larper.lsp("c#", {"a"}) end,
        \\  function() larper.lsp("a/b", {"a"}) end,
        \\  function() larper.lsp("", {"a"}) end,
        \\  function() larper.lsp("x", {}) end,
        \\  function() larper.lsp("x", {""}) end,
        \\  function() larper.lsp("x", {1}) end,
        \\  function() larper.lsp("x", {"a", {}}) end,
        \\  function() larper.lsp("x", {"a\0b"}) end,
        \\  function() larper.lsp("x", "zls") end,
        \\  function() larper.lsp("x", {string.rep("a", 2000)}) end,
        \\}
        \\for i, f in ipairs(ruins) do assert(not pcall(f), "passou " .. i) end
        \\for i = 1, 6 do larper.lsp("l" .. i, {"p"}) end
        \\assert(not pcall(larper.lsp, "demais", {"p"}))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 8), p.lsp.items.len);
    // Chamar de novo troca a proposta.
    try std.testing.expectEqualStrings("zig", p.lsp.items[0].lang.slice());
    var it = p.lsp.items[0].cmd.iterator();
    try std.testing.expectEqualStrings("/opt/zls", it.next().?);
    try std.testing.expectEqualStrings("--x", it.next().?);
    // Desligado, a proposta some.
    e.setEnabled(p, false);
    try std.testing.expectEqual(@as(usize, 0), p.lsp.items.len);
}

test "plugins: laço infinito é parado, nem pcall segura, e a interface segue" {
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
    try cmdOk(&e, "/x");
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_commands);
    // Parado, o comando volta a ir como texto.
    try std.testing.expect(!e.command("/x"));
}

test "plugins: chamar um plugin nunca espera o Lua" {
    var e = T.engine();
    defer e.deinit();
    // Bem mais instruções que o normal: um segundo inteiro por comando, se deixar.
    e.budget = 4_000_000_000;
    const p = testOne(&e,
        \\larper.command("/lento", function()
        \\  local t = os.clock()
        \\  while os.clock() - t < 0.3 do end
        \\  larper.notify("acabou")
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    const t0 = sync.nowMs();
    try std.testing.expect(e.command("/lento"));
    e.drain();
    try std.testing.expect(sync.nowMs() - t0 < 100);
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
    e.waitIdle();
    try std.testing.expectEqualStrings("acabou", T.note(0));
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
    e.waitIdle();
    try std.testing.expectEqual(Status.running, q.status());
    try std.testing.expect(std.mem.indexOf(u8, q.err().?, "quebrou") != null);
    try std.testing.expectEqual(@as(usize, 2), T.n_failed); // sintaxe + quebrou
    // Erro toda hora: para depois de 10.
    for (0..9) |_| e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(Status.failed, q.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_message);
}

test "plugins: send só em gesto, nunca em resposta a mensagem, temporizador ou HTTP" {
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
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "larper.send") != null);

    try cmdOk(&e, "/shrug oi");
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
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), T.n_sent);
    try std.testing.expectEqual(@as(u64, 99), T.sent_ch[1]);
}

test "plugins: um gesto não vale para o que vem depois dele" {
    var e = T.engine();
    defer e.deinit();
    T.wipeDisk();
    const p = testOne(&e,
        \\-- @name G
        \\-- @capabilities send, timers, composer, panel, messages, menu
        \\larper.command("/depois", function()
        \\  larper.after(0.01, function() larper.send(nil, "do temporizador") end)
        \\end)
        \\larper.command("/ins", function() larper.insert("texto") end)
        \\larper.command("/pula", function() larper.jump("5", "6") end)
        \\larper.command("/varias", function() for i = 1, 6 do larper.send(nil, "x" .. i) end end)
        \\larper.command("/erro", function() pcall(larper.after, "x", 1); larper.after(0, function() larper.insert("não") end) end)
        \\larper.on("message", function() larper.jump("1", "2") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/depois");
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "larper.send") != null);
    try cmdOk(&e, "/ins");
    try std.testing.expectEqualStrings("texto", T.inserted[0..T.inserted_len]);
    try cmdOk(&e, "/pula");
    try std.testing.expectEqual(@as(usize, 1), T.jumps);
    try std.testing.expectEqual(@as(u64, 6), T.jump_id);
    // No máximo 5 por gesto.
    try cmdOk(&e, "/varias");
    try std.testing.expectEqual(@as(usize, 5), T.n_sent);
    // Dentro de um temporizador, nem inserir.
    T.inserted_len = 0;
    try cmdOk(&e, "/erro");
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.inserted_len);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "larper.insert") != null);
    const m: Message = .{ .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.onMessage(&m);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.jumps);
}

test "plugins: capacidade que o cabeçalho não pede dá erro que explica" {
    var e = T.engine();
    defer e.deinit();
    const a = testOne(&e, "larper.storage.set('x', 1)");
    try std.testing.expect(std.mem.indexOf(u8, a.err().?, "@capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.err().?, "storage") != null);
    const b = testOne(&e, "-- @name B\nlarper.send(nil, 'x')");
    try std.testing.expect(std.mem.indexOf(u8, b.err().?, "send") != null);
    // Cabeçalho com problema: nem liga, e o erro diz o que é.
    const c = testOne(&e, "-- @name C\n-- @capabilities http\n-- @hosts discord.com\nlarper.notify('nunca')");
    try std.testing.expectEqual(Status.failed, c.status());
    try std.testing.expect(std.mem.indexOf(u8, c.err().?, "Discord") != null);
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
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
    try std.testing.expect(p.memBytes() < mem_cap);
}

test "plugins: desligar, religar e ready" {
    var e = T.engine();
    defer e.deinit();
    e.load(&.{
        .{ .name = "a.lua", .src = "larper.on('ready', function() larper.notify('pronto a') end)" },
        .{ .name = "b.lua", .src = "larper.command('/b', function() larper.notify('b') end)" },
    }, true);
    e.waitIdle();
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
    e.waitIdle();
    try std.testing.expectEqual(Status.off, e.list.items[1].status());
    e.setEnabled(e.list.items[1], true);
    e.waitIdle();
    try cmdOk(&e, "/b");
    try std.testing.expectEqualStrings("b", T.note(T.n_notes - 1));
}

test "plugins: nada trava dentro de C (__gc, string.rep, padrões, table)" {
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
    );
    try std.testing.expectEqualStrings("1", T.note(0));
    try std.testing.expectEqualStrings("false", T.note(1));
    try std.testing.expectEqualStrings("false", T.note(2));
    try std.testing.expectEqualStrings("0", T.note(3));
    try std.testing.expectEqualStrings("false", T.note(4));
    T.reset();
    _ = testOne(&e,
        \\larper.notify(tostring(pcall(table.move, {}, 1, 1000000000000000, 2)))
        \\local big = setmetatable({}, {__len = function() return 1000000000000000 end})
        \\larper.notify(tostring(pcall(table.insert, big, 1, "x")))
        \\larper.notify(tostring(pcall(table.remove, big, 1)))
    );
    for (0..3) |i| try std.testing.expectEqualStrings("false", T.note(i));
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

test "plugins: arquivos antigos, sem cabeçalho, continuam funcionando" {
    const antigo = struct {
        const calc = @embedFile("testdata/calc.lua");
        const zoeira = @embedFile("testdata/zoeira.lua");
        const dado = @embedFile("testdata/dado.lua");
        const relogio = @embedFile("testdata/relogio.lua");
        const resumo = @embedFile("testdata/resumo.lua");
        const shrug = @embedFile("testdata/shrug.lua");
        const alerta = @embedFile("testdata/alerta.lua");
    };
    for ([_][]const u8{ antigo.calc, antigo.zoeira, antigo.dado, antigo.relogio, antigo.resumo, antigo.shrug, antigo.alerta }) |src| {
        var e = T.engine();
        defer e.deinit();
        const p = testOne(&e, src);
        if (p.err()) |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.ExemploQuebrado;
        }
        try std.testing.expectEqual(Status.running, p.status());
        try std.testing.expect(p.man.legacy);
    }
    const Caso = struct { src: []const u8, cmd: []const u8, enviado: ?[]const u8 = null, aviso: ?[]const u8 = null };
    const casos = [_]Caso{
        .{ .src = antigo.calc, .cmd = "/conta (1 + 2) ^ 3", .enviado = "`(1 + 2) ^ 3 = 27`" },
        .{ .src = antigo.calc, .cmd = "/calc 10 / 4", .aviso = "10 / 4 = 2.5" },
        .{ .src = antigo.calc, .cmd = "/calc sqrt(16) + 2 * -3", .aviso = "sqrt(16) + 2 * -3 = -2" },
        .{ .src = antigo.calc, .cmd = "/calc 1 / 0", .aviso = "Conta inválida: divisão por zero" },
        .{ .src = antigo.calc, .cmd = "/calc (2", .aviso = "Conta inválida: faltou fechar o parêntese" },
        .{ .src = antigo.zoeira, .cmd = "/mock isso aqui", .enviado = "iSsO aQuI" },
        .{ .src = antigo.zoeira, .cmd = "/palmas isso sim", .enviado = "isso 👏 sim" },
        .{ .src = antigo.zoeira, .cmd = "/contrario açaí", .enviado = "íaça" },
        .{ .src = antigo.zoeira, .cmd = "/vapor ab", .enviado = "ａｂ" },
        .{ .src = antigo.zoeira, .cmd = "/spoiler o fim", .enviado = "||o fim||" },
        .{ .src = antigo.zoeira, .cmd = "/mock", .aviso = "Use assim: /mock isso aqui" },
        .{ .src = antigo.dado, .cmd = "/dado 0d6", .aviso = "Use assim: /dado 2d20+3 (até 50 dados de até 1000 lados)" },
        .{ .src = antigo.dado, .cmd = "/dado banana", .aviso = "Use assim: /dado 2d20+3 (até 50 dados de até 1000 lados)" },
        .{ .src = antigo.dado, .cmd = "/escolhe só uma", .aviso = "Use assim: /escolhe pizza, sushi, lasanha" },
        .{ .src = antigo.relogio, .cmd = "/hora marte", .aviso = "Não conheço \"marte\". Acrescente no começo de relogio.lua" },
        .{ .src = antigo.relogio, .cmd = "/cronometro", .aviso = "⏱ Cronômetro valendo" },
        .{ .src = antigo.resumo, .cmd = "/resumo", .aviso = "Nenhuma mensagem nova desde que o app abriu" },
    };
    for (casos) |caso| {
        var e = T.engine();
        defer e.deinit();
        _ = testOne(&e, caso.src);
        try cmdOk(&e, caso.cmd);
        if (caso.enviado) |t| {
            try std.testing.expectEqual(@as(usize, 1), T.n_sent);
            try std.testing.expectEqualStrings(t, T.sent[0][0..T.sent_len[0]]);
        }
        if (caso.aviso) |t| {
            try std.testing.expectEqual(@as(usize, 1), T.n_notes);
            try std.testing.expectEqualStrings(t, T.note(0));
        }
        try std.testing.expectEqual(@as(usize, 0), T.n_failed);
    }
}

test "plugins: temporizadores acabam com o plugin" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name T
        \\-- @capabilities timers, notify
        \\local n = 0
        \\larper.after(0.01, function() larper.notify("depois") end)
        \\local cancelado = larper.after(0.01, function() larper.notify("cancelado") end)
        \\larper.cancel(cancelado)
        \\larper.command("/longe", function() larper.after(0.05, function() larper.notify("não deveria") end) end)
        \\assert(not pcall(larper.every, 0.1, function() end))
        \\assert(not pcall(larper.after, "x", function() end))
    );
    try std.testing.expectEqual(Status.running, p.status());
    sync.sleepMs(40);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqualStrings("depois", T.note(0));
    try cmdOk(&e, "/longe");
    e.setEnabled(p, false);
    sync.sleepMs(90);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
}

test "plugins: larper.every repete até cancelar" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 5_000_000;
    const p = testOne(&e,
        \\-- @capabilities timers, notify
        \\larper.command("/n", function(a) larper.notify(a) end)
        \\local n = 0
        \\local id
        \\id = larper.every(1, function()
        \\  n = n + 1
        \\  larper.notify("tique")
        \\  larper.cancel(id)
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    var spins: usize = 0;
    while (T.n_notes == 0 and spins < 3000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expectEqualStrings("tique", T.note(0));
}

test "plugins: armazenamento persiste entre partidas e tem teto" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const src =
        \\-- @name S
        \\-- @capabilities storage, notify
        \\larper.command("/grava", function()
        \\  larper.storage.set("n", 42)
        \\  larper.storage.set("txt", "olá \"mundo\"\n")
        \\  larper.storage.set("lista", {1, 2, {a = "b"}})
        \\  larper.storage.set("apaga", true)
        \\  larper.storage.delete("apaga")
        \\end)
        \\larper.command("/le", function()
        \\  local s = larper.storage
        \\  local l = s.get("lista")
        \\  larper.notify(tostring(s.get("n")) .. "|" .. tostring(s.get("txt")) .. "|" .. l[3].a .. "|" .. tostring(s.get("apaga")) .. "|" .. #s.keys())
        \\end)
        \\larper.command("/copia", function()
        \\  local l = larper.storage.get("lista")
        \\  l[1] = 99
        \\  larper.notify(tostring(larper.storage.get("lista")[1]))
        \\end)
        \\larper.command("/grande", function()
        \\  local bloco = string.rep("x", 400 * 1024)
        \\  larper.storage.set("a", bloco)
        \\  larper.storage.set("b", bloco)
        \\  local ok, err = pcall(larper.storage.set, "c", bloco)
        \\  larper.notify(tostring(ok) .. " " .. tostring(err):sub(1, 30))
        \\  -- Trocar por algo menor cabe, e o que não deu certo não mudou nada.
        \\  larper.storage.set("a", "pouco")
        \\  larper.storage.set("c", bloco)
        \\  larper.storage.delete("b")
        \\  larper.storage.delete("c")
        \\  larper.notify(#larper.storage.get("a") .. "")
        \\end)
        \\larper.command("/ruim", function()
        \\  larper.notify(tostring(pcall(larper.storage.set, "f", function() end)))
        \\  local ciclo = {}
        \\  ciclo.eu = ciclo
        \\  larper.notify(tostring(pcall(larper.storage.set, "c", ciclo)))
        \\  larper.notify(tostring(pcall(larper.storage.set, "", 1)))
        \\end)
    ;
    const p = testOne(&e, src);
    try cmdOk(&e, "/grava");
    try cmdOk(&e, "/le");
    try std.testing.expectEqualStrings("42|olá \"mundo\"\n|b|nil|3", T.note(0));
    try cmdOk(&e, "/copia");
    try std.testing.expectEqualStrings("1", T.note(1));
    try cmdOk(&e, "/ruim");
    for (2..5) |i| try std.testing.expectEqualStrings("false", T.note(i));
    // Desligar grava; a próxima partida lê do "disco".
    e.setEnabled(p, false);
    e.waitIdle();
    T.reset();
    e.setEnabled(p, true);
    e.waitIdle();
    try cmdOk(&e, "/le");
    try std.testing.expectEqualStrings("42|olá \"mundo\"\n|b|nil|3", T.note(0));
    T.reset();
    try cmdOk(&e, "/grande");
    try std.testing.expect(std.mem.startsWith(u8, T.note(0), "false"));
    try std.testing.expectEqualStrings("5", T.note(1));
    try std.testing.expectEqual(Status.running, p.status());
}

test "plugins: arquivo de dados ilegível fica guardado e o plugin começa do zero" {
    T.wipeDisk();
    _ = T.writeData(&T.dummy, 1, "t.lua", "{isso não é json");
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities storage, notify
        \\larper.notify(tostring(larper.storage.get("x")))
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 1), T.broken);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, ".bad") != null);
    try std.testing.expectEqualStrings("nil", T.note(0));
}

test "plugins: larper.json vai e volta" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities notify
        \\local j = larper.json
        \\assert(j.encode({1, 2, 3}) == "[1,2,3]")
        \\assert(j.encode({a = "x\n"}) == '{"a":"x\\n"}')
        \\assert(j.encode("ã") == '"ã"')
        \\assert(j.encode(true) == "true")
        \\local v = j.decode('{"a": [1, 2.5, {"b": "c\\u00e3\\ud83d\\ude00"}], "n": null, "t": true}')
        \\assert(v.a[1] == 1 and v.a[2] == 2.5 and v.a[3].b == "cã😀" and v.n == nil and v.t == true)
        \\assert(j.decode("[1,") == nil)
        \\local _, err = j.decode("{")
        \\assert(err == "invalid json")
        \\assert(j.decode(string.rep("[", 100) .. string.rep("]", 100)) == nil)
        \\assert(not pcall(j.encode, {1, 2, x = 3}))
        \\assert(not pcall(j.encode, 0/0))
        \\assert(not pcall(j.encode, print))
        \\assert(larper.urlencode("a b&c/ç") == "a%20b%26c%2F%C3%A7")
        \\larper.notify("ok")
    );
    if (p.err()) |msg| std.debug.print("{s}\n", .{msg});
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqualStrings("ok", T.note(0));
}

test "plugins: larper.tr segue o idioma" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities notify
        \\larper.command("/fala", function() larper.notify(larper.lang() .. " " .. larper.tr("oi", "hi")) end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/fala");
    try std.testing.expectEqualStrings("pt oi", T.note(0));
    const S = struct {
        fn en() bool {
            return true;
        }
    };
    const saved = runtime.lang_en;
    runtime.lang_en = &S.en;
    defer runtime.lang_en = saved;
    try cmdOk(&e, "/fala");
    try std.testing.expectEqualStrings("en hi", T.note(1));
}

test "plugins: painel chega pronto e os botões voltam ao Lua" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name Painel
        \\-- @capabilities panel, notify, send
        \\local cliques = 0
        \\local function desenha()
        \\  larper.panel.set({
        \\    title = "T" .. cliques,
        \\    {type = "heading", text = "H"},
        \\    {type = "text", text = "texto", style = "muted"},
        \\    {type = "input", key = "campo", placeholder = "dica", value = "v",
        \\      on_change = function(v) larper.notify("mudou " .. v) end,
        \\      on_submit = function(v) larper.send(nil, "enviei " .. v) end},
        \\    {type = "row",
        \\      {type = "button", label = "A", on_click = function() cliques = cliques + 1; desenha() end},
        \\      {type = "button", label = "B", style = "danger", on_click = function() larper.panel.close() end},
        \\    },
        \\    {type = "bar", label = "ana", value = 3, max = 10, text = "3"},
        \\    {type = "separator"},
        \\    {type = "list", empty = "nada", items = {
        \\      {title = "item", subtitle = "sub", meta = "m", on_click = function() larper.notify("item") end,
        \\        actions = {{label = "x", on_click = function() larper.notify("ação") end}}},
        \\    }},
        \\  })
        \\end
        \\desenha()
        \\larper.command("/abre", function() desenha(); larper.panel.open() end)
        \\larper.command("/ruim", function()
        \\  larper.notify(tostring(pcall(larper.panel.set, {{type = "foguete"}})))
        \\  larper.notify(tostring(pcall(larper.panel.set, {{type = "input"}})))
        \\  larper.notify(tostring(pcall(larper.panel.set, {"texto"})))
        \\end)
        \\larper.on("ready", function() pcall(larper.panel.open) end)
    );
    if (p.err()) |msg| std.debug.print("{s}\n", .{msg});
    try std.testing.expectEqual(Status.running, p.status());
    const t = p.tree orelse return error.SemArvore;
    try std.testing.expectEqualStrings("T0", t.title);
    const n = t.nodes.items;
    try std.testing.expectEqual(panel.Kind.heading, n[t.first].kind);
    const Find = struct {
        fn by(tree: *panel.Tree, kind: panel.Kind, text: []const u8) *panel.Node {
            for (tree.nodes.items) |*x| if (x.kind == kind and std.mem.eql(u8, x.text, text)) return x;
            unreachable;
        }
    };
    const a = Find.by(t, .button, "A");
    try std.testing.expect(a.click != 0);
    try std.testing.expectEqual(panel.Style.danger, Find.by(t, .button, "B").style);
    try std.testing.expectEqualStrings("sub", Find.by(t, .item, "item").sub);
    try std.testing.expectEqual(panel.Kind.button, n[Find.by(t, .item, "item").child].kind);
    const click_item = Find.by(t, .item, "item").click;
    const click_action = Find.by(t, .button, "x").click;
    // Sem pedir, o painel não abre (nem no "ready", que não é gesto).
    e.fireReady();
    e.waitIdle();
    try std.testing.expect(e.panel_open == null);
    try cmdOk(&e, "/abre");
    try std.testing.expect(e.panel_open == p);
    // A árvore anterior morreu; a função de agora roda.
    const t2 = p.tree.?;
    e.panelGesture(p, click_item, null);
    e.panelGesture(p, click_action, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("item", T.note(0));
    try std.testing.expectEqualStrings("ação", T.note(1));
    // O campo: digitar não é gesto; Enter é.
    var inp: *panel.Node = undefined;
    for (t2.nodes.items) |*x| if (x.kind == .input) {
        inp = x;
    };
    try std.testing.expectEqualStrings("v", inp.meta);
    e.panelChange(p, inp.change, "ab");
    e.waitIdle();
    try std.testing.expectEqualStrings("mudou ab", T.note(2));
    e.panelGesture(p, inp.submit, "tudo");
    e.waitIdle();
    try std.testing.expectEqualStrings("enviei tudo", T.sent[0][0..T.sent_len[0]]);
    // Um clique em "A" republica: a função de quem clicou ainda valia.
    const tb = Find.by(t2, .button, "A").click;
    e.panelGesture(p, tb, null);
    e.waitIdle();
    try std.testing.expectEqualStrings("T1", p.tree.?.title);
    // Fechar é da interface e do plugin.
    e.panelGesture(p, Find.by(p.tree.?, .button, "B").click, null);
    e.waitIdle();
    try std.testing.expect(e.panel_open == null);
    T.reset();
    try cmdOk(&e, "/ruim");
    for (0..3) |i| try std.testing.expectEqualStrings("false", T.note(i));
    // Desligou: o painel some.
    e.setEnabled(p, false);
    try std.testing.expect(p.tree == null);
}

test "plugins: menus e decoração, com o plugin parado levando tudo" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name M
        \\-- @capabilities menu, decorate, notify
        \\larper.menu("message", {pt = "Marcar", en = "Mark"}, function(m)
        \\  larper.decorate(m, {badge = "ok", note = m.content})
        \\  larper.notify(m.author.name .. ":" .. m.id)
        \\end)
        \\larper.menu("user", "Pessoa", function(u) larper.notify(u.id .. "=" .. u.name) end)
        \\larper.command("/regras", function()
        \\  larper.rules({ {word = "SPOILER", collapse = true, label = "fora"}, {user = "9", badge = "!"} })
        \\end)
        \\larper.command("/tira", function() larper.undecorate("10") end)
        \\larper.command("/ruim", function()
        \\  larper.notify(tostring(pcall(larper.menu, "canal", "x", print)))
        \\  larper.notify(tostring(pcall(larper.decorate, "", {})))
        \\  larper.notify(tostring(pcall(larper.rules, {"nada"})))
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try std.testing.expectEqual(@as(usize, 2), p.menus.items.len);
    try std.testing.expectEqualStrings("Marcar", p.menus.items[0].pt);
    try std.testing.expectEqualStrings("Mark", p.menus.items[0].en);
    const m: Message = .{ .id = 10, .content = "oi", .author = 1, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m);
    e.waitIdle();
    try std.testing.expectEqualStrings("ana:10", T.note(0));
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 10, .channel = 42, .author = 2, .timestamp = 0, .content = "oi" }, .spans = &.{} };
    try std.testing.expect(e.deco.active());
    var v = e.deco.view(&sm, 1);
    try std.testing.expectEqualStrings("ok", v.slice()[0].badge);
    try std.testing.expectEqualStrings("oi", v.slice()[0].note);
    e.menuUser(p, &p.menus.items[1], 77, "bia");
    e.waitIdle();
    try std.testing.expectEqualStrings("77=bia", T.note(1));
    try cmdOk(&e, "/tira");
    try std.testing.expect(!e.deco.active());
    try cmdOk(&e, "/regras");
    var sp: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 11, .channel = 42, .author = 2, .timestamp = 0, .content = "um spoiler aqui" }, .spans = &.{} };
    try std.testing.expect(e.deco.collapses(&sp, 1));
    try cmdOk(&e, "/ruim");
    for (2..5) |i| try std.testing.expectEqualStrings("false", T.note(i));
    e.setEnabled(p, false);
    try std.testing.expect(!e.deco.active());
    try std.testing.expect(!e.deco.collapses(&sp, 1));
}

test "plugins: apagar uma mensagem leva a nota junto e avisa quem pediu" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities decorate, messages, notify
        \\larper.command("/d", function() larper.decorate("10", {note = "texto"}) end)
        \\larper.on("delete", function(d) larper.notify("apagou " .. d.id .. " em " .. d.channel) end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/d");
    try std.testing.expect(e.deco.active());
    e.onDelete(42, 10);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    try std.testing.expectEqualStrings("apagou 10 em 42", T.note(0));
}

test "plugins: mensagens carregadas chegam numa cópia" {
    var e = T.engine();
    defer e.deinit();
    const list = [_]Message{
        .{ .id = 1, .content = "um", .author = 5, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 100 },
        .{ .id = 2, .content = "dois", .author = 6, .author_name = "bia", .channel = 42, .channel_name = "geral", .timestamp = 200, .attachments = 1 },
    };
    T.loaded = &list;
    const p = testOne(&e,
        \\-- @capabilities messages, notify
        \\larper.command("/le", function()
        \\  local ok = larper.messages({limit = 10}, function(l)
        \\    larper.notify(#l .. " " .. l[1].content .. " " .. l[2].author.name .. " " .. l[2].time .. " " .. l[2].attachments)
        \\  end)
        \\  larper.notify(tostring(ok))
        \\end)
        \\larper.command("/seguido", function()
        \\  larper.notify(tostring(larper.messages(function() end)))
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    try cmdOk(&e, "/le");
    e.waitIdle();
    try std.testing.expectEqualStrings("true", T.note(0));
    try std.testing.expectEqualStrings("2 um bia 200 1", T.note(1));
    // Pedir de novo logo em seguida não vai.
    try cmdOk(&e, "/seguido");
    try std.testing.expectEqualStrings("false", T.note(2));
}

test "plugins: HTTP só com host declarado e aprovado, e sem cabeçalhos da conta" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @name H
        \\-- @capabilities http, notify, send
        \\-- @hosts api.exemplo.com
        \\local function resposta(r)
        \\  larper.notify(tostring(r.ok) .. "|" .. tostring(r.status) .. "|" .. tostring(r.error) .. "|" .. r.body)
        \\  if r.ok and r.body == "manda" then larper.send(nil, "automático") end
        \\end
        \\larper.command("/get", function() larper.http.get("https://api.exemplo.com/x?q=1", resposta) end)
        \\larper.command("/post", function()
        \\  larper.http.post("https://api.exemplo.com/y", {body = "corpo", headers = {
        \\    ["Content-Type"] = "text/plain", Cookie = "a=b", Authorization = "x",
        \\    ["X-Super-Properties"] = "z", Accept = "a\r\nCookie: b"}}, resposta)
        \\end)
        \\larper.command("/fora", function()
        \\  larper.notify(tostring(pcall(larper.http.get, "https://outro.com/", resposta)))
        \\  larper.notify(tostring(pcall(larper.http.get, "http://api.exemplo.com/", resposta)))
        \\  larper.notify(tostring(pcall(larper.http.get, "https://u:s@api.exemplo.com/", resposta)))
        \\  larper.notify(tostring(pcall(larper.http.get, "https://api.exemplo.com:8443/", resposta)))
        \\  larper.notify(larper.http.allowed("api.exemplo.com") and "sim" or "não")
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    // Sem aprovação nada sai, e o plugin fica sabendo (sem morrer por isso).
    try cmdOk(&e, "/get");
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expectEqualStrings("false|0|not_approved|", T.note(0));
    T.reset();
    try cmdOk(&e, "/fora");
    for (0..4) |i| try std.testing.expectEqualStrings("false", T.note(i));
    try std.testing.expectEqualStrings("não", T.note(4));
    T.reset();
    e.setApproved(p, "api.exemplo.com", true);
    try std.testing.expect(e.isApproved("t.lua", "api.exemplo.com"));
    try cmdOk(&e, "/get");
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    try std.testing.expectEqualStrings("https://api.exemplo.com/x?q=1", T.http_reqs[0].?.url);
    try std.testing.expect(!T.http_reqs[0].?.post);
    // A resposta chega fora de um gesto: mandar mensagem não vale.
    T.respond(200, "manda");
    e.waitIdle();
    try std.testing.expectEqualStrings("true|200|nil|manda", T.note(0));
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
    try std.testing.expect(std.mem.indexOf(u8, p.err().?, "larper.send") != null);
    // Só os cabeçalhos da lista, e sem quebra de linha.
    try cmdOk(&e, "/post");
    const req = T.http_reqs[0].?;
    try std.testing.expect(req.post);
    try std.testing.expectEqualStrings("corpo", req.body);
    try std.testing.expectEqual(@as(usize, 1), req.headers.len);
    try std.testing.expectEqualStrings("Content-Type: text/plain", req.headers[0]);
    T.respond(500, "");
    e.waitIdle();
    // Tirou a aprovação: vale para o próximo pedido.
    T.reset();
    e.setApproved(p, "api.exemplo.com", false);
    e.waitIdle();
    try cmdOk(&e, "/get");
    try std.testing.expectEqualStrings("false|0|not_approved|", T.note(0));
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
}

test "plugins: HTTP tem limite por plugin" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\-- @capabilities http, notify
        \\-- @hosts api.exemplo.com
        \\larper.command("/rajada", function()
        \\  for i = 1, 5 do
        \\    larper.http.get("https://api.exemplo.com/" .. i, function(r)
        \\      if r.error then larper.notify(r.error) end
        \\    end)
        \\  end
        \\end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    e.setApproved(p, "api.exemplo.com", true);
    e.waitIdle();
    try cmdOk(&e, "/rajada");
    // Três no ar; os outros dois recusados na hora.
    try std.testing.expectEqual(@as(usize, 3), T.http_n);
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    try std.testing.expectEqualStrings("rate_limited", T.note(0));
    T.respond(200, "");
    T.respond(200, "");
    T.respond(200, "");
    e.waitIdle();
}

test "plugins: um plugin parado não atrapalha o outro" {
    var e = T.engine();
    defer e.deinit();
    e.budget = 200_000;
    e.load(&.{
        .{ .name = "a.lua", .src = "larper.command('/a', function() while true do end end)" },
        .{ .name = "b.lua", .src = "larper.command('/b', function() larper.notify('b vivo') end)" },
    }, false);
    e.waitIdle();
    try cmdOk(&e, "/a");
    try std.testing.expectEqual(Status.failed, e.list.items[0].status());
    try cmdOk(&e, "/b");
    try std.testing.expectEqualStrings("b vivo", T.note(0));
}

test "plugins: uma rajada de mensagens não cresce sem limite" {
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e,
        \\larper.on("message", function(m) end)
        \\larper.command("/fim", function() larper.notify("vivo") end)
    );
    try std.testing.expectEqual(Status.running, p.status());
    const m: Message = .{ .content = "x", .author = 1, .author_name = "a", .channel = 42, .channel_name = "g" };
    for (0..10_000) |_| e.onMessage(&m);
    e.waitIdle();
    try cmdOk(&e, "/fim");
    try std.testing.expectEqualStrings("vivo", T.note(0));
}

test "plugins: trocar de conta reinicia, cada um com os seus dados" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, "-- @capabilities notify\nlarper.notify('subiu')\nlarper.command('/x', function() end)");
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
    e.setAccount(0);
    try std.testing.expectEqual(Status.waiting, p.status());
    try std.testing.expectEqual(@as(u32, 0), e.n_commands);
    e.setAccount(2);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    try std.testing.expectEqual(@as(u32, 1), e.n_commands);
}

test "plugins: escolhas vão e voltam pelo plugins.kdl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    {
        var e = T.engine();
        defer e.deinit();
        e.setDisabledName("velho.lua");
        const p = testOne(&e, "-- @capabilities panel, http\n-- @hosts api.exemplo.com\nlarper.panel.set({})");
        e.setApproved(p, "api.exemplo.com", true);
        e.panel_left = true;
        e.panel_w = 412;
        e.openPanel(p);
        try e.writePrefs(std.testing.allocator, &out);
    }
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var e = T.engine();
    defer e.deinit();
    for (nodes) |*n| e.applyPrefNode(n);
    try std.testing.expect(e.disabled.contains("velho.lua"));
    try std.testing.expect(e.isApproved("t.lua", "api.exemplo.com"));
    try std.testing.expect(!e.isApproved("t.lua", "outro.com"));
    try std.testing.expect(e.panel_left);
    try std.testing.expectEqual(@as(f32, 412), e.panel_w);
    // O painel que estava aberto volta sozinho quando o plugin publica.
    const p = testOne(&e, "-- @capabilities panel\nlarper.panel.set({})");
    try std.testing.expect(e.panel_open == p);
}

test "plugins: recarregar não fecha o painel, e a lista de hosts vale para o próximo" {
    var e = T.engine();
    defer e.deinit();
    const src = "-- @capabilities panel\nlarper.panel.set({title = 'x'})";
    const p = testOne(&e, src);
    e.openPanel(p);
    const q = testOne(&e, src);
    try std.testing.expect(e.panel_open == q);
}

test "plugins: trocar de idioma redesenha o que o plugin pediu" {
    var e = T.engine();
    defer e.deinit();
    const exemplos = @import("plugin_examples");
    _ = exemplos;
    T.wipeDisk();
    const p = testOne(&e, Bundled.src("bookmarks.lua"));
    try std.testing.expectEqualStrings("Favoritos", p.tree.?.title);
    try std.testing.expectEqualStrings("Favoritos", p.title());
    const S = struct {
        fn en() bool {
            return true;
        }
    };
    const saved = runtime.lang_en;
    runtime.lang_en = &S.en;
    defer runtime.lang_en = saved;
    e.frameTick(42, true);
    e.waitIdle();
    try std.testing.expectEqualStrings("Bookmarks", p.tree.?.title);
    try std.testing.expectEqualStrings("Bookmarks", p.title());
}

const Bundled = struct {
    fn src(name: []const u8) []const u8 {
        const exemplos = @import("plugin_examples");
        for (exemplos.list) |ex| if (std.mem.eql(u8, ex.name, name)) return ex.source;
        unreachable;
    }
};

fn chega(e: *Engine, content: []const u8) void {
    const m: Message = .{ .id = 500 + T.n_notes, .content = content, .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .timestamp = 1000 };
    e.onMessage(&m);
    e.waitIdle();
}

test "plugins incluídos: destaques pega a palavra inteira e não grava o texto de ninguém" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("highlights.lua"));
    try cmdOk(&e, "/highlights Pizza");
    try std.testing.expect(e.panel_open == p);
    chega(&e, "hoje tem pizzaria");
    try std.testing.expectEqual(@as(usize, 0), T.n_notes);
    chega(&e, "quem quer PIZZA, gente?");
    try std.testing.expectEqual(@as(usize, 1), T.n_notes);
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "pizza") != null);
    // O acento também não atrapalha, e "c++" é uma palavra.
    try cmdOk(&e, "/highlights AÇÃO");
    try cmdOk(&e, "/highlights c++");
    chega(&e, "muita ação");
    try std.testing.expectEqual(@as(usize, 2), T.n_notes);
    chega(&e, "programo em c++ hoje");
    try std.testing.expectEqual(@as(usize, 3), T.n_notes);
    // Parou: gravou no disco a palavra e o lugar, nunca o texto.
    e.setEnabled(p, false);
    e.waitIdle();
    const data = T.readData(&T.dummy, std.testing.allocator, 1, "t.lua").?;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "pizza") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "quem quer") == null);
}

test "plugins incluídos: lembretes entendem o tempo e voltam depois de reiniciar" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("reminders.lua"));
    try cmdOk(&e, "/remind depois sem tempo");
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), "/remind 10m") != null);
    try cmdOk(&e, "/remind 1h30m ligar");
    try std.testing.expect(std.mem.indexOf(u8, T.note(1), "Vou lembrar") != null);
    try cmdOk(&e, "/remind 2h 30m com dois pedaços");
    try cmdOk(&e, "/remind 1s logo");
    var spins: usize = 0;
    while (T.n_notes < 5 and spins < 4000) : (spins += 1) {
        e.drain();
        sync.sleepMs(1);
    }
    try std.testing.expect(std.mem.indexOf(u8, T.note(4), "logo") != null);
    // O lembrete pede a notificação do sistema mesmo com a janela em foco.
    try std.testing.expect(T.notes_desktop[4]);
    // Reiniciou: os dois longos continuam, e nenhum temporizador fica de pé à toa.
    e.setEnabled(p, false);
    e.waitIdle();
    e.setEnabled(p, true);
    e.waitIdle();
    var titles: usize = 0;
    for (p.tree.?.nodes.items) |*n| if (n.kind == .item) {
        titles += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), titles);
}

test "plugins incluídos: favoritos sobrevive e não guarda o que foi apagado" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const p = testOne(&e, Bundled.src("bookmarks.lua"));
    const m: Message = .{ .id = 77, .content = "segredo <@123> com <:ok:5>", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral", .guild = 3, .guild_name = "S", .timestamp = 1000 };
    e.menuMessage(p, &p.menus.items[0], &m);
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 77, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try std.testing.expectEqualStrings("🔖", e.deco.view(&sm, 1).slice()[0].badge);
    const hasText = struct {
        fn f(t: *panel.Tree, s: []const u8) bool {
            for (t.nodes.items) |*n| if (std.mem.indexOf(u8, n.sub, s) != null) return true;
            return false;
        }
    }.f;
    try std.testing.expect(hasText(p.tree.?, "segredo @… com :ok:"));
    // Reiniciou: continua lá, com o selo.
    e.setEnabled(p, false);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
    e.setEnabled(p, true);
    e.waitIdle();
    try std.testing.expect(hasText(p.tree.?, "segredo"));
    try std.testing.expect(e.deco.active());
    // Apagaram: some o texto, inclusive do disco.
    e.onDelete(42, 77);
    e.waitIdle();
    try std.testing.expect(!hasText(p.tree.?, "segredo"));
    e.setEnabled(p, false);
    e.waitIdle();
    const data = T.readData(&T.dummy, std.testing.allocator, 1, "t.lua").?;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "segredo") == null);
}

test "plugins incluídos: filtro vira regras, e trechos só põem na caixa" {
    T.wipeDisk();
    var e = T.engine();
    defer e.deinit();
    const f = testOne(&e, Bundled.src("filter.lua"));
    const user_entry = for (f.menus.items) |*m| {
        if (m.kind == .user) break m;
    } else unreachable;
    e.menuUser(f, user_entry, 9, "bia");
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 9, .timestamp = 0, .content = "oi" }, .spans = &.{} };
    try std.testing.expect(e.deco.collapses(&sm, 1));
    // Desligou: as regras saem junto.
    e.setEnabled(f, false);
    try std.testing.expect(!e.deco.collapses(&sm, 1));
    e.setEnabled(f, true);
    e.waitIdle();
    try std.testing.expect(e.deco.collapses(&sm, 1));

    T.wipeDisk();
    const s = testOne(&e, Bundled.src("snippets.lua"));
    try cmdOk(&e, "/snip nada");
    try std.testing.expect(std.mem.indexOf(u8, T.note(T.n_notes - 1), "nada") != null);
    const m: Message = .{ .id = 5, .content = "texto", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(s, &s.menus.items[0], &m);
    e.waitIdle();
    try std.testing.expect(e.panel_open == s);
    try std.testing.expectEqual(@as(usize, 0), T.n_sent);
}

test "plugins incluídos: tradução não sai sem aprovar, e a nota vem da resposta" {
    var e = T.engine();
    defer e.deinit();
    const host_name = "api.mymemory.translated.net";
    e.load(&.{.{ .name = "t.lua", .src = Bundled.src("translate.lua") }}, true);
    e.waitIdle();
    const p = e.list.items[0];
    try std.testing.expect(p.man.declares(host_name));
    const m: Message = .{ .id = 5, .content = "hello <@1> world", .author = 7, .author_name = "ana", .channel = 42, .channel_name = "geral" };
    e.menuMessage(p, &p.menus.items[0], &m);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), T.http_n);
    try std.testing.expect(std.mem.indexOf(u8, T.note(0), host_name) != null);
    e.setApproved(p, host_name, true);
    e.waitIdle();
    e.menuMessage(p, &p.menus.items[0], &m);
    e.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), T.http_n);
    const url = T.http_reqs[0].?.url;
    try std.testing.expect(std.mem.startsWith(u8, url, "https://" ++ host_name ++ "/get?q=hello%20%40%E2%80%A6%20world&langpair="));
    try std.testing.expect(std.mem.endsWith(u8, url, "Autodetect%7Cpt"));
    T.respond(200, "{\"responseData\":{\"translatedText\":\"olá\"},\"responseStatus\":200}");
    e.waitIdle();
    var sm: @import("../core/store.zig").StoredMessage = .{ .msg = .{ .id = 5, .channel = 42, .author = 7, .timestamp = 0, .content = "x" }, .spans = &.{} };
    try std.testing.expect(std.mem.indexOf(u8, e.deco.view(&sm, 1).slice()[0].note, "olá") != null);
    // Clicar de novo tira.
    e.menuMessage(p, &p.menus.items[0], &m);
    e.waitIdle();
    try std.testing.expect(!e.deco.active());
}

test "plugins incluídos: todos ligam, com cabeçalho completo e nos dois idiomas" {
    const exemplos = @import("plugin_examples");
    T.wipeDisk();
    for (exemplos.list) |ex| {
        var e = T.engine();
        defer e.deinit();
        e.load(&.{.{ .name = ex.name, .src = ex.source }}, true);
        e.waitIdle();
        const p = e.list.items[0];
        if (p.err()) |msg| {
            std.debug.print("{s}: {s}\n", .{ ex.name, msg });
            return error.ExemploQuebrado;
        }
        try std.testing.expectEqual(Status.running, p.status());
        try std.testing.expect(!p.man.legacy);
        try std.testing.expect(p.man.name.len > 0 and p.man.name_pt.len > 0);
        try std.testing.expect(p.man.description.len > 0 and p.man.description_pt.len > 0);
        try std.testing.expect(p.man.version.len > 0);
        // Traduzir só aparece no menu; os outros têm painel.
        try std.testing.expect(p.tree != null or std.mem.eql(u8, ex.name, "translate.lua"));
    }
}
