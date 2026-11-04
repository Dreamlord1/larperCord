//! Conexão real com o Discord: gateway (WebSocket) + REST, numa thread.
//! Implementa a mesma interface do gateway falso: recebe `Command` e entrega
//! `Event` no `Sink`, então o resto do app não sabe a diferença.
//!
//! sufixo 00 00 FF FF, RESUME, IDENTIFY de cliente web e os mesmos cabeçalhos.
//!
//! Cuidados:
//!  - o token nunca vai para log, erro ou arquivo; é zerado ao sair;
//!  - sessão com RESUME (op 6): uma queda de rede não perde o estado nem as
//!    mensagens que chegaram durante a reconexão, como no cliente oficial;
//!  - gateway comprimido com zlib-stream, também como o cliente oficial;
//!  - uma requisição REST por vez, respeitando os cabeçalhos de rate limit;
//!  - reconexão com espera crescente; erros de autenticação não reconectam.
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Queue = @import("queue.zig").Queue;
const Sink = @import("fake_gateway.zig").Sink;
const nowMs = @import("fake_gateway.zig").nowMs;
const j = @import("jsonx.zig");
const i18n = @import("../ui/i18n.zig");
const media_url = @import("media_url.zig");
const proxy = @import("proxy.zig");
const settings_proto = @import("settings_proto.zig");
const voice_mod = @import("voice.zig");
const thread_json = @import("thread_json.zig");
const Id = types.Id;
const Value = std.json.Value;

const alloc = std.heap.c_allocator;
const api = "https://discord.com/api/v10";
const gateway_host = "wss://gateway.discord.gg";
/// Query do gateway: JSON + compressão zlib-stream (a mesma do cliente oficial).
const gateway_query = "v=10&encoding=json&compress=zlib-stream";
/// confundido com spam. Os valores abaixo são os mesmos que ele usa.
const web_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.87 Safari/537.36";
const identity_props =
    \\{"os":"Windows","browser":"Chrome","device":"","system_locale":"en-US","has_client_mods":false,"browser_user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.87 Safari/537.36","browser_version":"67.0.3396.87","os_version":"10","referrer":"","referring_domain":"","referrer_current":"","referring_domain_current":"","release_channel":"stable","client_build_number":363557,"client_event_source":null}
;
const client_state_json =
    \\{"guild_hashes":{},"highest_last_message_id":"0","read_state_version":0,"user_guild_settings_version":-1,"user_settings_version":-1}
;

pub const Gateway = struct {
    commands: Queue(ev.Command),
    sink: Sink,
    token: [:0]u8,
    thread: ?*c.SDL_Thread = null,
    ws: ?*c.CURL = null,
    rest: ?*c.CURL = null,
    seq: ?i64 = null,
    hb_interval: i64 = 41250,
    next_hb: i64 = 0,
    hb_sent_at: i64 = 0,
    acked: bool = true,
    me: Id = 0,
    frame: std.ArrayList(u8) = .empty,
    stopping: bool = false,
    /// Pedido de encerrar visto também de dentro de uma transferência do
    /// libcurl (que pode levar até 180 s): o app fecha sem esperar.
    abort: std.atomic.Value(bool) = .init(false),
    /// Call em andamento (dona da thread de voz).
    voice: ?*voice_mod.Voice = null,
    voice_guild: Id = 0,
    voice_channel: Id = 0,
    voice_mute: bool = false,
    voice_deaf: bool = false,
    voice_session: [128]u8 = @splat(0),
    voice_session_len: usize = 0,
    voice_endpoint: [256]u8 = @splat(0),
    voice_endpoint_len: usize = 0,
    voice_token: [256]u8 = @splat(0),
    voice_token_len: usize = 0,
    /// Volume individual por pessoa (0..2), mantido entre calls.
    voice_volumes: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    /// A thread de voz parou com 4014 (movido / servidor trocado): até
    /// quando espera o VOICE_SERVER_UPDATE novo antes de desistir.
    voice_wait_until: i64 = 0,
    /// Status escolhido (também vai no IDENTIFY de uma sessão nova).
    status: types.Status = .online,
    /// Cargo -> cor e posição, para a cor do nome de cada membro.
    role_info: std.AutoHashMapUnmanaged(Id, RoleInfo) = .empty,
    /// Última lista de membros pedida (op 14): repetida depois de um READY.
    sub_guild: Id = 0,
    sub_channel: Id = 0,
    sub_thread: Id = 0,
    /// Sessão do gateway, para o RESUME (op 6).
    session_id: [64]u8 = @splat(0),
    session_len: u8 = 0,
    resume_base: [192]u8 = @splat(0),
    resume_len: u8 = 0,
    /// Descompressão zlib-stream (o gateway manda binário comprimido).
    z: c.z_stream = std.mem.zeroes(c.z_stream),
    z_on: bool = false,
    zout: std.ArrayList(u8) = .empty,
    /// Rate limit do REST, lido dos cabeçalhos X-RateLimit-*.
    rate_until: i64 = 0,
    global_until: i64 = 0,
    /// Comandos que chegaram enquanto o gateway estava reconectando ou
    /// esperando rate limit. São enviados quando a conexão volta.
    pending: std.ArrayList(ev.Command) = .empty,
    /// Comandos que vão pelo próprio gateway (op 3, 4, 14): só valem depois
    /// do READY/RESUMED (antes, o Discord fecha com 4003 e o pedido se perde).
    held: std.ArrayList(ev.Command) = .empty,
    /// O handshake acabou: dá para ler e escrever no WebSocket.
    ws_live: bool = false,
    /// O gateway já respondeu READY ou RESUMED nesta conexão.
    ws_ready: bool = false,
    /// Como a conexão acabou, visto de dentro de uma espera do REST.
    ws_end: ?End = null,
    servicing: bool = false,
    serviced_ms: i64 = 0,
    /// Sem HELLO até aqui: a conexão ficou muda, abre outra.
    hello_until: i64 = 0,
    /// Último bloqueio longo avisado (para não repetir o aviso a cada comando).
    block_noticed: i64 = 0,
    /// Acorda o poll do gateway quando chega comando (leitura, escrita).
    wake_pipe: [2]c_int = .{ -1, -1 },

    pub fn start(g: *Gateway) !void {
        if (c.pipe(&g.wake_pipe) == 0) {
            for (g.wake_pipe) |fd| {
                _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
                _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
            }
        } else g.wake_pipe = .{ -1, -1 };
        g.commands.wake_fd = g.wake_pipe[1];
        g.thread = c.SDL_CreateThread(threadMain, "discord", g) orelse {
            g.closeWakePipe();
            return error.SdlThread;
        };
    }

    fn closeWakePipe(g: *Gateway) void {
        g.commands.wake_fd = -1;
        for (g.wake_pipe) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        g.wake_pipe = .{ -1, -1 };
    }

    pub fn stop(g: *Gateway) void {
        g.abort.store(true, .release);
        g.commands.push(.shutdown);
        if (g.thread) |t| c.SDL_WaitThread(t, null);
        g.closeWakePipe();
        g.stopVoice();
        std.crypto.secureZero(u8, g.token);
        alloc.free(g.token);
        @memset(&g.session_id, 0);
        @memset(&g.resume_base, 0);
        for (g.pending.items) |cmd| g.dropCommand(cmd);
        g.pending.deinit(alloc);
        g.held.deinit(alloc);
        g.frame.deinit(alloc);
        g.zout.deinit(alloc);
        g.role_info.deinit(alloc);
        g.voice_volumes.deinit(alloc);
    }

    const RoleInfo = struct { color: u32, pos: i64 };

    fn canResume(g: *const Gateway) bool {
        return g.session_len > 0 and g.seq != null;
    }

    fn clearSession(g: *Gateway) void {
        g.session_len = 0;
        @memset(&g.session_id, 0);
        g.resume_len = 0;
        @memset(&g.resume_base, 0);
        g.seq = null;
    }

    fn emit(g: *Gateway, e: ev.Event) void {
        g.sink.push(g.sink.ctx, e);
    }

    /// Aviso para a interface, nos dois idiomas.
    fn notice(g: *Gateway, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        const s = i18n.allocPrint(alloc, pt, en, args) catch return;
        g.emit(.{ .notice = s });
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const g: *Gateway = @ptrCast(@alignCast(data.?));
        g.run();
        return 0;
    }

    fn run(g: *Gateway) void {
        g.rest = c.curl_easy_init();
        defer if (g.rest) |h| c.curl_easy_cleanup(h);
        var backoff: u32 = 2000;
        while (!g.stopping) {
            // Com sessão válida o cliente oficial mostra "reconectando", não
            // "conectando": ele está retomando uma sessão, não abrindo outra.
            g.emit(.{ .status = if (g.canResume()) .reconnecting else .connecting });
            const result = g.session();
            g.ws_live = false;
            if (g.ws) |h| {
                c.curl_easy_cleanup(h);
                g.ws = null;
            }
            if (g.stopping) break;
            // A conexão chegou a funcionar: a próxima queda começa do zero.
            const worked = g.ws_ready;
            g.ws_ready = false;
            if (worked) backoff = 2000;
            switch (result) {
                .fatal => {
                    g.emit(.{ .status = .failed });
                    // Não há mais para onde mandar os comandos pendentes.
                    for (g.pending.items) |cmd| g.dropCommand(cmd);
                    g.pending.clearRetainingCapacity();
                    g.held.clearRetainingCapacity();
                    // Fica só atendendo o encerramento.
                    var cmds: std.ArrayList(ev.Command) = .empty;
                    defer cmds.deinit(alloc);
                    while (!g.stopping) {
                        g.commands.waitDrain(&cmds, 1000);
                        for (cmds.items) |cmd| if (cmd == .shutdown) {
                            g.stopping = true;
                        } else g.dropCommand(cmd);
                        cmds.clearRetainingCapacity();
                    }
                    break;
                },
                .retry => {
                    g.emit(.{ .status = .reconnecting });
                    g.sleepServing(backoff);
                    backoff = @min(backoff * 2, 60_000);
                },
                .reconnect => {
                    g.emit(.{ .status = .reconnecting });
                    // Caiu antes de valer: nada de um IDENTIFY por segundo.
                    g.sleepServing(if (worked) 1000 else backoff);
                    if (!worked) backoff = @min(backoff * 2, 60_000);
                },
                .new_session => {
                    // Sessão inválida/expirada: o Discord manda esperar de
                    // 1 a 5 segundos antes de abrir uma nova.
                    g.clearSession();
                    g.emit(.{ .status = .reconnecting });
                    var prng = std.Random.DefaultPrng.init(@bitCast(nowMs()));
                    g.sleepServing(1000 + prng.random().uintLessThan(u32, 4000) + (if (worked) 0 else backoff));
                    if (!worked) backoff = @min(backoff * 2, 60_000);
                },
            }
        }
    }

    /// Monta a URL do gateway com a query que o cliente oficial usa.
    fn gatewayUrl(buf: []u8, base: []const u8) ?[:0]const u8 {
        const b = std.mem.trimEnd(u8, base, "/");
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, b, '?')) |_| "&" else "/?";
        return std.fmt.bufPrintSentinel(buf, "{s}{s}{s}", .{ b, sep, gateway_query }, 0) catch null;
    }

    /// Espera atendendo comandos (para não perder o pedido de encerrar).
    fn sleepServing(g: *Gateway, ms: u32) void {
        const until = nowMs() + ms;
        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        while (!g.stopping and nowMs() < until) {
            g.commands.waitDrain(&cmds, 200);
            for (cmds.items) |cmd| switch (cmd) {
                .shutdown => g.stopping = true,
                else => g.pending.append(alloc, cmd) catch freeCommand(cmd),
            };
            cmds.clearRetainingCapacity();
            // Uma espera de rate limit não pode deixar o gateway surdo.
            g.serviceWs();
        }
    }

    /// Executa o que ficou na fila durante a reconexão/rate limit.
    fn runPending(g: *Gateway) ?End {
        while (g.pending.items.len > 0) {
            const cmd = g.pending.orderedRemove(0);
            if (cmd == .shutdown) {
                g.stopping = true;
                return .reconnect;
            }
            g.execute(cmd);
            if (g.stopping) return .reconnect;
        }
        return null;
    }

    /// Comando que não vai mais ser executado. Quem espera resposta fica sabendo.
    fn dropCommand(g: *Gateway, cmd: ev.Command) void {
        switch (cmd) {
            .send_message => |m| g.emit(.{ .send_failed = .{ .channel = m.channel, .nonce = m.nonce } }),
            .fetch_history => |ch| g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } }),
            .fetch_older => |o| g.emit(.{ .history = .{ .channel = o.channel, .messages = &.{}, .older = true } }),
            .fetch_threads => |ft| g.emit(.{ .threads_page = .{ .channel = ft.channel, .archived = ft.archived, .failed = true } }),
            else => {},
        }
        freeCommand(cmd);
    }

    /// Lê o que chegou no WebSocket e cuida do heartbeat. Também roda de dentro
    /// das esperas do REST (upload, rate limit): o gateway não fica surdo.
    fn serviceWs(g: *Gateway) void {
        if (!g.ws_live or g.servicing or g.ws_end != null) return;
        const h = g.ws orelse return;
        g.servicing = true;
        defer g.servicing = false;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            var got: usize = 0;
            var meta: [*c]const c.struct_curl_ws_frame = null;
            const rc = c.curl_ws_recv(h, &buf, buf.len, &got, &meta);
            if (rc == c.CURLE_AGAIN) break;
            if (rc != c.CURLE_OK) {
                g.ws_end = .retry;
                return;
            }
            if (meta == null) break;
            if (meta.*.flags & c.CURLWS_CLOSE != 0) {
                const code: u16 = if (got >= 2) (@as(u16, buf[0]) << 8) | buf[1] else 0;
                g.ws_end = g.onClose(code);
                return;
            }
            // Ping/pong são tratados pelo libcurl; não são payload do gateway.
            if (meta.*.flags & (c.CURLWS_PING | c.CURLWS_PONG) != 0) continue;
            if (got > 0) g.frame.appendSlice(alloc, buf[0..got]) catch {
                g.ws_end = .retry;
                return;
            };
            if (meta.*.bytesleft == 0 and meta.*.flags & c.CURLWS_CONT == 0) {
                // O Discord fecha cada payload com 00 00 FF FF. Se ainda
                // não veio, guarda o pedaço e espera o resto.
                if (g.inflateFrame()) |e| {
                    g.ws_end = e;
                    return;
                }
            }
        }
        const now = nowMs();
        if (g.next_hb == std.math.maxInt(i64)) {
            if (now >= g.hello_until) g.ws_end = .retry;
        } else if (now >= g.next_hb) {
            if (!g.acked) {
                g.ws_end = .reconnect; // conexão "zumbi"
                return;
            }
            g.heartbeat();
        }
    }

    const End = enum {
        /// Falha passageira (rede, 429...): tenta de novo com espera crescente.
        retry,
        /// O socket caiu: volta já e tenta RESUME.
        reconnect,
        /// Sessão inválida/expirada: espera 1–5 s e faz um IDENTIFY novo.
        new_session,
        /// Token errado ou conexão recusada: não adianta insistir.
        fatal,
    };

    fn session(g: *Gateway) End {
        // A compressão é por conexão: começa um stream zlib novo a cada uma.
        if (g.z_on) {
            _ = c.inflateEnd(&g.z);
            g.z_on = false;
        }
        g.z = std.mem.zeroes(c.z_stream);
        if (c.inflateInit2_(&g.z, c.MAX_WBITS + 32, c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) return .retry;
        g.z_on = true;
        defer {
            _ = c.inflateEnd(&g.z);
            g.z_on = false;
        }

        const h = c.curl_easy_init() orelse return .retry;
        g.ws = h;
        var url_buf: [512]u8 = undefined;
        const base = if (g.resume_len > 0) g.resume_base[0..@as(usize, g.resume_len)] else gateway_host;
        const url = gatewayUrl(&url_buf, base) orelse return .retry;
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, web_user_agent.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 15));
        useProxy(h);
        g.abortable(h);
        if (c.curl_easy_perform(h) != c.CURLE_OK) return .retry;
        var sock: c.curl_socket_t = -1;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        // `seq` e `session_id` sobrevivem à queda: é isso que permite o RESUME.
        g.acked = true;
        g.next_hb = std.math.maxInt(i64);
        g.hello_until = nowMs() + 30_000;
        g.hb_sent_at = 0;
        g.ws_end = null;
        g.ws_live = true;
        g.frame.clearRetainingCapacity();
        g.zout.clearRetainingCapacity();
        g.shrinkBuffers();

        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        while (true) {
            // Primeiro o que ficou esperando a conexão voltar.
            if (g.runPending()) |e| return e;
            // Depois os comandos novos do app (REST).
            g.commands.drain(&cmds);
            for (cmds.items, 0..) |cmd, i| {
                if (cmd == .shutdown) {
                    g.stopping = true;
                    for (cmds.items[i + 1..]) |rest| freeCommand(rest);
                    cmds.clearRetainingCapacity();
                    return .reconnect;
                }
                // Uma espera lá dentro (rate limit) pode ter visto o pedido de parar.
                if (g.stopping) freeCommand(cmd) else g.execute(cmd);
            }
            cmds.clearRetainingCapacity();
            if (g.stopping) return .reconnect;
            g.voiceTick();
            if (g.ws_end) |e| return e;

            // Dorme até chegar algo no socket, um comando ou o próximo
            // heartbeat. Em call, a thread de voz é conferida 20x por segundo.
            const now = nowMs();
            const voice_busy = g.voice != null or g.voice_wait_until != 0;
            const cap: i64 = if (voice_busy or g.wake_pipe[0] < 0) 50 else 1000;
            const due = if (g.next_hb == std.math.maxInt(i64)) g.hello_until else g.next_hb;
            const wait: c_int = @intCast(std.math.clamp(due - now, 0, cap));
            var pfd = [2]c.struct_pollfd{
                .{ .fd = sock, .events = c.POLLIN, .revents = 0 },
                .{ .fd = g.wake_pipe[0], .events = c.POLLIN, .revents = 0 },
            };
            _ = c.poll(&pfd, 2, wait);
            if (pfd[1].revents & c.POLLIN != 0) {
                var junk: [64]u8 = undefined;
                _ = c.read(g.wake_pipe[0], &junk, junk.len);
            }

            g.serviceWs();
            if (g.ws_end) |e| return e;
        }
    }

    /// Depois de um READY grande os buffers ficam com vários MB reservados:
    /// devolve o que passar de 1 MB.
    fn shrinkBuffers(g: *Gateway) void {
        const limit = 1024 * 1024;
        if (g.frame.capacity > limit and g.frame.items.len == 0) g.frame.clearAndFree(alloc);
        if (g.zout.capacity > limit and g.zout.items.len == 0) g.zout.clearAndFree(alloc);
    }

    /// Descomprime uma mensagem inteira do zlib-stream e entrega ao gateway.
    /// usa exatamente esse sufixo para saber quando o pacote está completo.
    fn inflateFrame(g: *Gateway) ?End {
        const buf = g.frame.items;
        if (!g.z_on or buf.len < 4) return null;
        if (!std.mem.eql(u8, buf[buf.len - 4 ..], "\x00\x00\xff\xff")) return null;
        g.zout.clearRetainingCapacity();
        g.z.next_in = buf.ptr;
        g.z.avail_in = @intCast(buf.len);
        var out: [32 * 1024]u8 = undefined;
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            g.z.next_out = @ptrCast(&out);
            g.z.avail_out = @intCast(out.len);
            const rc = c.inflate(&g.z, c.Z_SYNC_FLUSH);
            const produced: usize = out.len - @as(usize, g.z.avail_out);
            if (produced > 0) g.zout.appendSlice(alloc, out[0..produced]) catch return .retry;
            if (rc == c.Z_STREAM_END) {
                _ = c.inflateReset(&g.z);
                break;
            }
            if (rc != c.Z_OK and !(rc == c.Z_BUF_ERROR and produced == 0 and g.z.avail_in == 0)) {
                g.notice("não consegui descomprimir o gateway (zlib {d})", "couldn't decompress the gateway (zlib {d})", .{rc});
                return .retry;
            }
            if (g.z.avail_in == 0 and produced < out.len) break;
        }
        g.frame.clearRetainingCapacity();
        if (g.zout.items.len == 0) return null;
        const end = g.onPayload(g.zout.items);
        g.zout.clearRetainingCapacity();
        g.shrinkBuffers();
        return end;
    }

    fn onClose(g: *Gateway, code: u16) End {
        switch (code) {
            4004 => {
                g.notice("token inválido ou expirado (4004). Atualize o token e reinicie.", "invalid or expired token (4004). Update the token and restart.", .{});
                return .fatal;
            },
            4010...4014 => {
                g.notice("o Discord recusou a conexão (código {d}).", "Discord refused the connection (code {d}).", .{code});
                return .fatal;
            },
            // Sessão caiu de vez: esquece o ID e começa outra.
            4007, 4009 => return .new_session,
            // Rate limit no gateway: espera crescente antes de voltar.
            4008 => return .retry,
            else => return .reconnect,
        }
    }

    fn send(g: *Gateway, payload: []const u8) void {
        const h = g.ws orelse return;
        if (!g.ws_live) return;
        var off: usize = 0;
        var first = true;
        var waited: u8 = 0;
        while (off < payload.len) {
            var sent: usize = 0;
            const flags: c_uint = if (first) c.CURLWS_TEXT else c.CURLWS_CONT;
            const rc = c.curl_ws_send(h, payload.ptr + off, payload.len - off, &sent, 0, flags);
            if (rc == c.CURLE_AGAIN) {
                waited += 1;
                if (waited > 50) break;
                var sock: c.curl_socket_t = -1;
                _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
                var pfd: c.struct_pollfd = .{ .fd = sock, .events = c.POLLOUT, .revents = 0 };
                _ = c.poll(&pfd, 1, 20);
                continue;
            }
            if (rc != c.CURLE_OK or sent == 0) break;
            off += sent;
            first = false;
        }
        // Metade de um quadro não tem conserto: reconecta (o RESUME recupera).
        if (off < payload.len and g.ws_end == null) g.ws_end = .reconnect;
    }

    fn heartbeat(g: *Gateway) void {
        var b: [64]u8 = undefined;
        const p = if (g.seq) |s| std.fmt.bufPrint(&b, "{{\"op\":1,\"d\":{d}}}", .{s}) catch return else "{\"op\":1,\"d\":null}";
        g.send(p);
        g.acked = false;
        g.hb_sent_at = nowMs();
        g.next_hb = g.hb_sent_at + g.hb_interval;
    }

    /// Primeiro heartbeat com atraso aleatório, como manda a documentação.
    fn scheduleHeartbeat(g: *Gateway) void {
        var prng = std.Random.DefaultPrng.init(@bitCast(nowMs()));
        g.next_hb = nowMs() + @as(i64, @intFromFloat(@as(f64, @floatFromInt(g.hb_interval)) * prng.random().float(f64)));
    }

    fn identify(g: *Gateway) void {
        // IDENTIFY abre uma sessão nova: o seq antigo não vale mais.
        g.seq = null;
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.appendSlice(alloc, "{\"op\":2,\"d\":{\"token\":") catch return;
        j.writeString(&out, alloc, g.token) catch return;
        out.print(alloc, ",\"capabilities\":4605,\"properties\":", .{}) catch return;
        out.appendSlice(alloc, identity_props) catch return;
        out.print(alloc, ",\"presence\":{{\"activities\":[],\"status\":\"{s}\",\"afk\":false,\"since\":0}},\"compress\":false,\"client_state\":", .{statusName(g.status)}) catch return;
        out.appendSlice(alloc, client_state_json) catch return;
        out.appendSlice(alloc, "}}") catch return;
        g.send(out.items);
    }

    fn sendResume(g: *Gateway) void {
        if (!g.canResume()) return g.identify();
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.appendSlice(alloc, "{\"op\":6,\"d\":{\"token\":") catch return;
        j.writeString(&out, alloc, g.token) catch return;
        out.appendSlice(alloc, ",\"session_id\":") catch return;
        j.writeString(&out, alloc, g.session_id[0..@as(usize, g.session_len)]) catch return;
        out.print(alloc, ",\"seq\":{d}}}}}", .{g.seq.?}) catch return;
        g.send(out.items);
    }

    fn beginSession(g: *Gateway) void {
        if (g.canResume()) g.sendResume() else g.identify();
    }

    /// `X-Super-Properties` é o base64 das mesmas propriedades do IDENTIFY.
    fn superProperties(buf: []u8) []const u8 {
        return std.base64.standard.Encoder.encode(buf, identity_props);
    }

    /// Trata um payload do gateway. Retorna como encerrar, se for o caso.
    fn onPayload(g: *Gateway, text: []const u8) ?End {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{}) catch return null;
        const op = j.int(j.get(root, "op")) orelse return null;
        switch (op) {
            10 => {
                const d = j.get(root, "d") orelse return null;
                g.hb_interval = j.int(j.get(d, "heartbeat_interval")) orelse 41250;
                g.scheduleHeartbeat();
                // Se já existe sessão, o cliente oficial retoma (RESUME);
                // só abre uma nova quando não há nada para retomar.
                g.beginSession();
            },
            11 => {
                g.acked = true;
                if (g.hb_sent_at > 0) {
                    g.emit(.{ .latency = @intCast(@max(0, nowMs() - g.hb_sent_at)) });
                }
            },
            1 => g.heartbeat(),
            7 => return .reconnect,
            9 => {
                const d = j.get(root, "d");
                const resumable = if (d) |v| switch (v) {
                    .bool => |b| b,
                    else => false,
                } else false;
                if (resumable and g.canResume()) return .reconnect;
                g.clearSession();
                return .new_session;
            },
            0 => {
                if (j.int(j.get(root, "s"))) |s| g.seq = s;
                const t = j.str(j.get(root, "t")) orelse return null;
                const d = j.get(root, "d") orelse return null;
                g.dispatch(t, d, arena.allocator()) catch {};
            },
            else => {},
        }
        return null;
    }

    fn dupe(s: ?[]const u8) []u8 {
        return alloc.dupe(u8, s orelse "") catch @constCast("");
    }

    fn userName(u: Value) []const u8 {
        if (j.str(j.get(u, "global_name"))) |n| if (n.len > 0) return n;
        return j.str(j.get(u, "username")) orelse "?";
    }

    /// Cópia de um texto opcional (null se vier vazio).
    fn optDupe(v: ?[]const u8) ?[]u8 {
        const t = v orelse return null;
        if (t.len == 0) return null;
        return alloc.dupe(u8, t) catch null;
    }

    fn avatarOf(u: Value) ?[]u8 {
        return optDupe(j.str(j.get(u, "avatar")));
    }

    /// Decoração do avatar ("asset" da loja de colecionáveis).
    fn decorationOf(u: Value) ?[]u8 {
        const dd = j.get(u, "avatar_decoration_data") orelse return null;
        return optDupe(j.str(j.get(dd, "asset")));
    }

    /// Dono do servidor (no READY pode vir dentro de `properties`).
    fn ownerOf(v: Value) Id {
        if (j.id(j.get(v, "owner_id"))) |o| return o;
        if (j.get(v, "properties")) |p| return j.id(j.get(p, "owner_id")) orelse 0;
        return 0;
    }

    fn guildIcon(v: Value) ?[]u8 {
        if (j.str(j.get(v, "icon"))) |i| return optDupe(i);
        if (j.get(v, "properties")) |p| return optDupe(j.str(j.get(p, "icon")));
        return null;
    }

    /// Guarda as cores dos cargos e manda os nomes para o Store (grupos da
    /// lista de membros).
    fn ingestRoles(g: *Gateway, gid: Id, list: []const Value) void {
        var out: std.ArrayList(types.Role) = .empty;
        for (list) |rv| {
            const rid = j.id(j.get(rv, "id")) orelse continue;
            const color: u32 = @intCast(std.math.clamp(j.int(j.get(rv, "color")) orelse 0, 0, 0xffffff));
            const pos = j.int(j.get(rv, "position")) orelse 0;
            g.role_info.put(alloc, rid, .{ .color = color, .pos = pos }) catch {};
            const perms = std.fmt.parseInt(u64, j.str(j.get(rv, "permissions")) orelse "0", 10) catch 0;
            const managed = if (j.get(rv, "managed")) |mv| mv == .bool and mv.bool else false;
            out.append(alloc, .{
                .id = rid,
                .guild = gid,
                .name = dupe(j.str(j.get(rv, "name")) orelse "?"),
                .color = color,
                .position = @intCast(std.math.clamp(pos, -1000, 100000)),
                .permissions = perms,
                .managed = managed,
            }) catch {};
        }
        g.emit(.{ .roles = .{ .guild = gid, .roles = out.toOwnedSlice(alloc) catch return } });
    }

    /// Cargos de um membro, do mais alto para o mais baixo, e a cor do
    /// nome (a do cargo mais alto que tem cor).
    fn infoOf(g: *const Gateway, roles: []const Value) types.MemberInfo {
        const R = struct { id: Id, pos: i64, color: u32 };
        var tmp: [32]R = undefined;
        var n: usize = 0;
        for (roles) |rv| {
            if (n == tmp.len) break;
            const rid = j.id(rv) orelse continue;
            const info = g.role_info.get(rid) orelse continue;
            tmp[n] = .{ .id = rid, .pos = info.pos, .color = info.color };
            n += 1;
        }
        std.mem.sort(R, tmp[0..n], {}, struct {
            fn f(_: void, a: R, b: R) bool {
                return a.pos > b.pos;
            }
        }.f);
        var out: types.MemberInfo = .{};
        for (tmp[0..n]) |r| {
            if (out.color == 0 and r.color != 0) out.color = r.color;
            if (out.n_roles < out.roles.len) {
                out.roles[out.n_roles] = r.id;
                out.n_roles += 1;
            }
        }
        return out;
    }

    /// Objeto `member` de uma mensagem/digitando: guarda cor e cargos.
    fn memberColor(g: *Gateway, gid: Id, uid: Id, m: Value) void {
        if (gid == 0 or uid == 0) return;
        if (uid == g.me) {
            var list: std.ArrayList(Id) = .empty;
            for (j.array(j.get(m, "roles"))) |rv| if (j.id(rv)) |rid| list.append(alloc, rid) catch {};
            if (list.toOwnedSlice(alloc)) |roles| g.emit(.{ .my_roles = .{ .guild = gid, .roles = roles } }) else |_| {}
        }
        g.emit(.{ .member_info = .{ .guild = gid, .user = uid, .info = g.infoOf(j.array(j.get(m, "roles"))) } });
    }

    /// Passa as pastas para o Store (só se vieram: uma atualização parcial
    /// sem pastas não apaga as que já temos).
    fn emitFolders(g: *Gateway, layout: settings_proto.Layout) void {
        defer layout.deinit(alloc);
        if (layout.folders.len == 0) return;
        const out = alloc.alloc(types.GuildFolder, layout.folders.len) catch return;
        var n: usize = 0;
        for (layout.folders) |f| {
            const guilds = alloc.dupe(Id, f.guilds) catch continue;
            const name = alloc.dupe(u8, f.name) catch {
                alloc.free(guilds);
                continue;
            };
            out[n] = .{ .id = f.id, .name = name, .color = f.color, .guilds = guilds };
            n += 1;
        }
        g.emit(.{ .guild_folders = out[0..n] });
    }

    /// Grupo da lista de membros: "online", "offline" ou o ID de um cargo.
    fn groupId(s: []const u8) Id {
        if (std.mem.eql(u8, s, "online")) return types.group_online;
        if (std.mem.eql(u8, s, "offline")) return types.group_offline;
        return std.fmt.parseInt(Id, s, 10) catch types.group_online;
    }

    /// Uma linha de GUILD_MEMBER_LIST_UPDATE.
    fn memberItem(g: *Gateway, it: Value) types.MemberItem {
        if (j.get(it, "group")) |gv| {
            const gid = groupId(j.str(j.get(gv, "id")) orelse "");
            return .{ .group = .{ .id = gid, .count = @intCast(std.math.clamp(j.int(j.get(gv, "count")) orelse 0, 0, std.math.maxInt(u32))) } };
        }
        const m = j.get(it, "member") orelse return .none;
        const u = j.get(m, "user") orelse return .none;
        const uid = j.id(j.get(u, "id")) orelse return .none;
        g.upsert(u);
        if (j.get(m, "presence")) |p| g.emit(.{ .presence_update = .{ .user = uid, .status = statusOf(p), .activity = presenceActivity(p), .activities = presenceActivities(p) } });
        return .{ .member = .{ .user = uid, .info = g.infoOf(j.array(j.get(m, "roles"))) } };
    }

    fn onMemberList(g: *Gateway, d: Value) !void {
        const gid = j.id(j.get(d, "guild_id")) orelse return;
        var ops: std.ArrayList(types.MemberOp) = .empty;
        errdefer {
            for (ops.items) |op| if (op.items.len > 0) alloc.free(op.items);
            ops.deinit(alloc);
        }
        for (j.array(j.get(d, "ops"))) |ov| {
            const name = j.str(j.get(ov, "op")) orelse continue;
            const range = j.array(j.get(ov, "range"));
            const r0: u32 = if (range.len > 0) @intCast(std.math.clamp(j.int(range[0]) orelse 0, 0, 100_000)) else 0;
            const r1: u32 = if (range.len > 1) @intCast(std.math.clamp(j.int(range[1]) orelse 0, 0, 100_000)) else r0;
            const index: u32 = @intCast(std.math.clamp(j.int(j.get(ov, "index")) orelse 0, 0, 100_000));
            if (std.mem.eql(u8, name, "SYNC")) {
                const src = j.array(j.get(ov, "items"));
                const items = try alloc.alloc(types.MemberItem, src.len);
                for (src, 0..) |it, i| items[i] = g.memberItem(it);
                try ops.append(alloc, .{ .kind = .sync, .index = r0, .end = r1, .items = items });
            } else if (std.mem.eql(u8, name, "INSERT") or std.mem.eql(u8, name, "UPDATE")) {
                const items = try alloc.alloc(types.MemberItem, 1);
                items[0] = g.memberItem(j.get(ov, "item") orelse .null);
                try ops.append(alloc, .{ .kind = if (name[0] == 'I') .insert else .update, .index = index, .items = items });
            } else if (std.mem.eql(u8, name, "DELETE")) {
                try ops.append(alloc, .{ .kind = .delete, .index = index });
            } else if (std.mem.eql(u8, name, "INVALIDATE")) {
                try ops.append(alloc, .{ .kind = .invalidate, .index = r0, .end = r1 });
            }
        }
        var counts: std.ArrayList([2]u64) = .empty;
        for (j.array(j.get(d, "groups"))) |gv| {
            counts.append(alloc, .{ groupId(j.str(j.get(gv, "id")) orelse ""), @intCast(@max(0, j.int(j.get(gv, "count")) orelse 0)) }) catch {};
        }
        g.emit(.{ .member_list = .{
            .counts = counts.toOwnedSlice(alloc) catch &.{},
            .guild = gid,
            .list_id = std.hash.Wyhash.hash(0, j.str(j.get(d, "id")) orelse ""),
            .online = @intCast(std.math.clamp(j.int(j.get(d, "online_count")) orelse 0, 0, std.math.maxInt(u32))),
            .total = @intCast(std.math.clamp(j.int(j.get(d, "member_count")) orelse 0, 0, std.math.maxInt(u32))),
            .ops = try ops.toOwnedSlice(alloc),
        } });
    }

    /// Pede a lista de membros de um servidor vista de um canal (op 14,
    /// Numa thread, a lista é a do canal pai (`channel`) e `thread` pede também
    /// quem está nela, em THREAD_MEMBER_LIST_UPDATE.
    fn subscribe(g: *Gateway, guild: Id, channel: Id, thread: Id) void {
        if (guild == 0 or channel == 0) return;
        g.sub_guild = guild;
        g.sub_channel = channel;
        g.sub_thread = thread;
        var tb: [32]u8 = undefined;
        const lists = if (thread != 0) std.fmt.bufPrint(&tb, "\"{d}\"", .{thread}) catch "" else "";
        var buf: [360]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"op\":14,\"d\":{{\"guild_id\":\"{d}\",\"typing\":true,\"threads\":true,\"activities\":true,\"members\":[],\"channels\":{{\"{d}\":[[0,99]]}},\"thread_member_lists\":[{s}]}}}}", .{ guild, channel, lists }) catch return;
        g.send(payload);
    }

    /// Nome do status no gateway (offline = invisível para os outros).
    fn statusName(s: types.Status) []const u8 {
        return switch (s) {
            .online => "online",
            .idle => "idle",
            .dnd => "dnd",
            .offline => "invisible",
        };
    }

    /// "since" da relação (ISO) em ms; 0 = não veio.
    fn sinceMs(rv: Value) i64 {
        const t = j.str(j.get(rv, "since")) orelse return 0;
        return j.isoTime(t) * 1000;
    }

    fn relationshipKind(v: ?Value) types.Relationship {
        return switch (j.int(v) orelse 0) {
            1 => .friend,
            2 => .blocked,
            3 => .incoming,
            4 => .outgoing,
            else => .none,
        };
    }

    fn roleFor(uid: Id) u8 {
        return @intCast((uid >> 22) % 8);
    }

    fn dispatch(g: *Gateway, t: []const u8, d: Value, arena: std.mem.Allocator) !void {
        if (std.mem.eql(u8, t, "READY")) return g.onReady(d, arena);
        if (std.mem.eql(u8, t, "RESUMED")) {
            // O gateway reenviou o que perdemos; o estado local continua válido.
            g.gatewayReady();
            g.emit(.{ .status = .ready });
            // Um pedido de lista feito bem na hora da queda se perdeu.
            if (g.sub_guild != 0) g.subscribe(g.sub_guild, g.sub_channel, g.sub_thread);
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_CREATE")) {
            g.upsertUsers(d);
            if (j.get(d, "member")) |m| g.memberColor(j.id(j.get(d, "guild_id")) orelse 0, j.id(j.get(j.get(d, "author") orelse .null, "id")) orelse 0, m);
            g.messageThread(d);
            if (try g.message(d)) |m| g.emit(.{ .message_create = m });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_UPDATE")) {
            // Pode vir só com os embeds (a prévia de um link, segundos depois).
            const ch = j.id(j.get(d, "channel_id")) orelse return;
            const id = j.id(j.get(d, "id")) orelse return;
            const text = j.str(j.get(d, "content"));
            const content: ?[]const u8 = if (text) |t2| try j.simplifyContent(alloc, t2) else null;
            const raw: ?[]const u8 = if (text != null and content.?.len != text.?.len) try alloc.dupe(u8, text.?) else null;
            const has_embeds = j.get(d, "embeds") != null;
            var atts: ?[]types.Attachment = null;
            if (j.get(d, "attachments") != null) {
                atts = try attachmentsOf(d);
            } else if (has_embeds) {
                // Só os embeds de imagem: o Store junta com os anexos que já tinha.
                var list: std.ArrayList(types.Attachment) = .empty;
                try embedAttachments(d, &list);
                atts = try list.toOwnedSlice(alloc);
            }
            g.emit(.{ .message_update = .{
                .channel = ch,
                .id = id,
                .content = content,
                .raw = raw,
                .embeds = if (has_embeds) try embedsOf(d) else null,
                .attachments = atts,
            } });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_DELETE")) {
            g.emit(.{ .message_delete = .{ .channel = j.id(j.get(d, "channel_id")) orelse return, .id = j.id(j.get(d, "id")) orelse return } });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_DELETE_BULK")) {
            const ch = j.id(j.get(d, "channel_id")) orelse return;
            for (j.array(j.get(d, "ids"))) |idv| {
                const id = j.id(idv) orelse continue;
                g.emit(.{ .message_delete = .{ .channel = ch, .id = id } });
            }
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_CREATE")) {
            try g.onGuildCreate(d);
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_DELETE")) {
            // `unavailable`: queda do Discord, não saída. O servidor volta com
            // um GUILD_CREATE, e as mensagens em memória continuam valendo.
            if (j.get(d, "unavailable")) |u| if (u == .bool and u.bool) return;
            if (j.id(j.get(d, "id"))) |id| g.emit(.{ .guild_delete = id });
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_UPDATE")) {
            const gid = j.id(j.get(d, "id")) orelse return;
            const name = guildName(d);
            // Reaproveita o merge do GUILD_CREATE para atualizar o nome.
            if (j.get(d, "roles")) |rl| g.ingestRoles(gid, j.array(rl));
            g.emit(.{ .guild_create = .{
                .guild = .{
                    .id = gid,
                    .name = dupe(name),
                    .acronym = try j.acronym(alloc, name),
                    .color = @intCast((gid >> 22) % 8),
                    .icon = guildIcon(d),
                },
                .channels = try alloc.alloc(types.Channel, 0),
                .voice = try alloc.alloc([2]Id, 0),
            } });
            return;
        }
        if (std.mem.eql(u8, t, "CHANNEL_CREATE") or std.mem.eql(u8, t, "CHANNEL_UPDATE")) {
            if (try g.channelValue(d, 0)) |ch| g.emit(.{ .channel_upsert = ch });
            return;
        }
        if (std.mem.eql(u8, t, "CHANNEL_DELETE") or std.mem.eql(u8, t, "THREAD_DELETE")) {
            if (j.id(j.get(d, "id"))) |id| g.emit(.{ .channel_delete = id });
            return;
        }
        if (std.mem.eql(u8, t, "THREAD_CREATE") or std.mem.eql(u8, t, "THREAD_UPDATE")) {
            if (try g.channelValue(d, 0)) |ch| g.emit(.{ .channel_upsert = ch });
            return;
        }
        if (std.mem.eql(u8, t, "THREAD_LIST_SYNC")) return g.onThreadListSync(d);
        if (std.mem.eql(u8, t, "THREAD_MEMBER_UPDATE")) {
            // É o nosso (o Discord só manda este sobre a própria conta).
            if (j.id(j.get(d, "user_id"))) |uid| if (uid != g.me) return;
            g.emit(.{ .thread_joined = .{ .thread = j.id(j.get(d, "id")) orelse return, .joined = true } });
            return;
        }
        if (std.mem.eql(u8, t, "THREAD_MEMBERS_UPDATE")) return g.onThreadMembersUpdate(d);
        if (std.mem.eql(u8, t, "THREAD_MEMBER_LIST_UPDATE")) {
            const tid = j.id(j.get(d, "thread_id")) orelse return;
            g.ingestPresences(j.array(j.get(d, "presences")));
            return g.emitThreadMembers(tid, j.array(j.get(d, "members")));
        }
        if (std.mem.eql(u8, t, "GUILD_MEMBER_UPDATE") or std.mem.eql(u8, t, "USER_UPDATE")) {
            const u = j.get(d, "user") orelse d;
            const uid = j.id(j.get(u, "id")) orelse return;
            g.emit(.{ .user_update = .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = .offline, .avatar = avatarOf(u), .decoration = decorationOf(u) } });
            if (j.id(j.get(d, "guild_id"))) |gid| g.memberColor(gid, uid, d);
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_ROLE_CREATE") or std.mem.eql(u8, t, "GUILD_ROLE_UPDATE")) {
            const gid = j.id(j.get(d, "guild_id")) orelse return;
            const role = j.get(d, "role") orelse return;
            g.ingestRoles(gid, &.{role});
            return;
        }
        if (std.mem.eql(u8, t, "USER_SETTINGS_PROTO_UPDATE")) {
            // Mudou a pasta/ordem em outro dispositivo (tipo 1 = configurações gerais).
            const st = j.get(d, "settings") orelse return;
            if ((j.int(j.get(st, "type")) orelse 0) != 1) return;
            const b64 = j.str(j.get(st, "proto")) orelse return;
            if (settings_proto.fromProtoBase64(alloc, b64)) |layout| g.emitFolders(layout) else |_| {}
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_ROLE_DELETE")) {
            if (j.id(j.get(d, "role_id"))) |rid| g.emit(.{ .role_delete = rid });
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_MEMBER_REMOVE")) {
            const gid = j.id(j.get(d, "guild_id")) orelse return;
            const u = j.get(d, "user") orelse return;
            g.emit(.{ .member_remove = .{ .guild = gid, .user = j.id(j.get(u, "id")) orelse return } });
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_MEMBER_LIST_UPDATE")) {
            try g.onMemberList(d);
            return;
        }
        if (std.mem.eql(u8, t, "RELATIONSHIP_ADD") or std.mem.eql(u8, t, "RELATIONSHIP_UPDATE")) {
            if (j.get(d, "user")) |u| g.upsert(u);
            const uid = j.id(j.get(d, "id")) orelse return;
            g.emit(.{ .relationship = .{ .user = uid, .kind = relationshipKind(j.get(d, "type")), .since_ms = sinceMs(d) } });
            return;
        }
        if (std.mem.eql(u8, t, "RELATIONSHIP_REMOVE")) {
            const uid = j.id(j.get(d, "id")) orelse return;
            g.emit(.{ .relationship = .{ .user = uid, .kind = .none } });
            return;
        }
        if (std.mem.eql(u8, t, "CHANNEL_RECIPIENT_ADD")) {
            if (j.get(d, "user")) |u| g.upsert(u);
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_ACK")) {
            if (j.id(j.get(d, "channel_id"))) |id| g.emit(.{ .read = id });
            return;
        }
        if (std.mem.eql(u8, t, "VOICE_STATE_UPDATE")) {
            const user = j.id(j.get(d, "user_id")) orelse return;
            const chan = j.id(j.get(d, "channel_id"));
            g.emit(.{ .voice_state = .{ .channel = chan, .user = user } });
            if (user == g.me) {
                if (j.str(j.get(d, "session_id"))) |sid| {
                    // Sessão de voz nova (outro dispositivo, reconexão): a
                    // conexão antiga não vale mais.
                    if (g.voice != null and !std.mem.eql(u8, sid, g.voice_session[0..g.voice_session_len])) g.killVoice();
                    g.voice_session_len = @min(sid.len, g.voice_session.len - 1);
                    @memcpy(g.voice_session[0..g.voice_session_len], sid[0..g.voice_session_len]);
                }
                if (chan) |ch| {
                    // Alguém nos moveu: a conexão segue (o servidor de voz
                    // manda o grupo novo do DAVE) ou cai com 4014 e volta
                    // pelo VOICE_SERVER_UPDATE.
                    if (g.voice) |vc| vc.channel.store(ch, .release);
                    g.voice_channel = ch;
                    if (j.get(d, "self_mute")) |m| g.voice_mute = m == .bool and m.bool;
                    if (j.get(d, "self_deaf")) |m| g.voice_deaf = m == .bool and m.bool;
                    g.tryStartVoice();
                } else {
                    g.stopVoice();
                    g.voice_channel = 0;
                }
            }
            return;
        }
        if (std.mem.eql(u8, t, "VOICE_SERVER_UPDATE")) {
            if (g.voice_channel == 0) return;
            const gid = j.id(j.get(d, "guild_id")) orelse g.voice_guild;
            if (gid == g.voice_guild or g.voice_guild == 0) {
                // Servidor de voz novo (ou nenhum ainda, endpoint null): a
                // conexão atual morre; abre outra quando vier o endereço.
                g.killVoice();
                g.voice_endpoint_len = 0;
                g.voice_wait_until = nowMs() + 8000;
                if (j.str(j.get(d, "endpoint"))) |ep| {
                    g.voice_endpoint_len = @min(ep.len, g.voice_endpoint.len - 1);
                    @memcpy(g.voice_endpoint[0..g.voice_endpoint_len], ep[0..g.voice_endpoint_len]);
                }
                if (j.str(j.get(d, "token"))) |tk| {
                    std.log.debug("voz: server update endpoint={s} token={d}", .{ g.voice_endpoint[0..g.voice_endpoint_len], tk.len });
                    g.voice_token_len = @min(tk.len, g.voice_token.len - 1);
                    @memcpy(g.voice_token[0..g.voice_token_len], tk[0..g.voice_token_len]);
                }
                g.tryStartVoice();
            }
            return;
        }
        if (std.mem.eql(u8, t, "READY_SUPPLEMENTAL")) {
            g.onReadySupplemental(d);
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_MEMBERS_CHUNK")) {
            g.ingestMembers(d);
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_REACTION_REMOVE_ALL")) {
            g.emit(.{ .reaction_clear = .{
                .channel = j.id(j.get(d, "channel_id")) orelse return,
                .id = j.id(j.get(d, "message_id")) orelse return,
                .emoji = null,
            } });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_REACTION_REMOVE_EMOJI")) {
            const emoji = j.get(d, "emoji") orelse return;
            g.emit(.{ .reaction_clear = .{
                .channel = j.id(j.get(d, "channel_id")) orelse return,
                .id = j.id(j.get(d, "message_id")) orelse return,
                .emoji = emojiOf(emoji),
            } });
            return;
        }
        const add = std.mem.eql(u8, t, "MESSAGE_REACTION_ADD");
        if (add or std.mem.eql(u8, t, "MESSAGE_REACTION_REMOVE")) {
            const user = j.id(j.get(d, "user_id")) orelse return;
            // A nossa volta aqui também: o Store ignora o que já aplicou na
            // hora, e o que veio de outro aparelho entra.
            const emoji = j.get(d, "emoji") orelse return;
            g.emit(.{ .reaction = .{
                .channel = j.id(j.get(d, "channel_id")) orelse return,
                .id = j.id(j.get(d, "message_id")) orelse return,
                .emoji = emojiOf(emoji),
                .user = user,
                .add = add,
            } });
            return;
        }
        if (std.mem.eql(u8, t, "TYPING_START")) {
            const user = j.id(j.get(d, "user_id")) orelse return;
            if (user == g.me) return;
            if (j.get(d, "member")) |m| {
                if (j.get(m, "user")) |u| g.upsert(u);
                g.memberColor(j.id(j.get(d, "guild_id")) orelse 0, user, m);
            }
            g.emit(.{ .typing_start = .{ .channel = j.id(j.get(d, "channel_id")) orelse return, .user = user } });
            return;
        }
        if (std.mem.eql(u8, t, "PRESENCE_UPDATE")) {
            const u = j.get(d, "user") orelse return;
            // A presença costuma trazer só o ID: sem nome não há o que atualizar.
            if (j.get(u, "username") != null) g.upsert(u);
            const st = statusOf(d);
            g.emit(.{ .presence_update = .{
                .user = j.id(j.get(u, "id")) orelse return,
                .status = st,
                .activity = presenceActivity(d),
                .activities = presenceActivities(d),
            } });
            return;
        }
    }

    fn statusOf(v: Value) types.Status {
        return std.meta.stringToEnum(types.Status, j.str(j.get(v, "status")) orelse "offline") orelse .offline;
    }

    fn guildName(v: Value) []const u8 {
        if (j.str(j.get(v, "name"))) |n| if (n.len > 0) return n;
        if (j.get(v, "properties")) |p| if (j.str(j.get(p, "name"))) |n| return n;
        return i18n.tr("servidor", "server");
    }

    fn emojiOf(e: Value) types.Reaction {
        const name = j.str(j.get(e, "name")) orelse "?";
        if (j.isNull(j.get(e, "id"))) return types.Reaction.init(name);
        // Emoji personalizado: mostra o nome enquanto não há imagens.
        var b: [16]u8 = undefined;
        var r = types.Reaction.init(std.fmt.bufPrint(&b, ":{s}:", .{name[0..@min(name.len, 12)]}) catch name);
        r.custom = j.id(j.get(e, "id")) orelse 0;
        return r;
    }

    fn upsert(g: *Gateway, u: Value) void {
        const uid = j.id(j.get(u, "id")) orelse return;
        g.emit(.{ .user_upsert = .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = .offline, .avatar = avatarOf(u), .decoration = decorationOf(u) } });
    }

    fn upsertUsers(g: *Gateway, m: Value) void {
        if (j.get(m, "author")) |a| g.upsert(a);
        for (j.array(j.get(m, "mentions"))) |u| g.upsert(u);
    }

    fn presenceStatus(p: Value) types.Status {
        if (j.get(p, "presence")) |inner| return statusOf(inner);
        return statusOf(p);
    }

    /// Monta o texto que a interface mostra ("Jogando …", "Ouvindo …").
    /// Retorna "" quando a pessoa não está fazendo nada (limpa o anterior).
    fn presenceActivity(p: Value) ?[]const u8 {
        const acts = if (j.get(p, "presence")) |inner| j.array(j.get(inner, "activities")) else j.array(j.get(p, "activities"));
        if (acts.len == 0) return "";
        const a = acts[0];
        const kind = j.int(j.get(a, "type")) orelse 0;
        const name = j.str(j.get(a, "name")) orelse "";
        if (kind == 4) {
            // Status personalizado: o texto fica em `state`.
            const state = j.str(j.get(a, "state")) orelse name;
            if (state.len == 0) return "";
            return std.fmt.allocPrint(alloc, "{s}", .{state}) catch null;
        }
        if (name.len == 0) return "";
        const prefix: []const u8 = switch (kind) {
            1 => i18n.tr("Transmitindo ", "Streaming "),
            2 => i18n.tr("Ouvindo ", "Listening to "),
            3 => i18n.tr("Assistindo ", "Watching "),
            5 => i18n.tr("Competindo em ", "Competing in "),
            else => i18n.tr("Jogando ", "Playing "),
        };
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name }) catch null;
    }

    /// As atividades com nome (jogo, música, transmissão…), sem o status
    /// personalizado (esse já vira o texto de `presenceActivity`). Até 3.
    fn presenceActivities(p: Value) ?[]types.Activity {
        const acts = if (j.get(p, "presence")) |inner| j.array(j.get(inner, "activities")) else j.array(j.get(p, "activities"));
        var out: std.ArrayList(types.Activity) = .empty;
        for (acts) |a| {
            const kind = j.int(j.get(a, "type")) orelse 0;
            const name = j.str(j.get(a, "name")) orelse "";
            if (kind == 4 or name.len == 0 or out.items.len == 3) continue;
            const ts = j.get(a, "timestamps");
            const app = j.id(j.get(a, "application_id")) orelse 0;
            var ib: [512]u8 = undefined;
            const img = if (j.get(a, "assets")) |as| activityImage(&ib, app, j.str(j.get(as, "large_image")) orelse "") else "";
            out.append(alloc, .{
                .kind = @intCast(std.math.clamp(kind, 0, 255)),
                .name = dupeOpt(name) catch "",
                .details = dupeOpt(j.str(j.get(a, "details")) orelse "") catch "",
                .state = dupeOpt(j.str(j.get(a, "state")) orelse "") catch "",
                .start_ms = if (ts) |t| j.int(j.get(t, "start")) orelse 0 else 0,
                .end_ms = if (ts) |t| j.int(j.get(t, "end")) orelse 0 else 0,
                .image = dupeOpt(img) catch "",
                .app = app,
            }) catch break;
        }
        return out.toOwnedSlice(alloc) catch null;
    }

    /// Imagem grande da atividade como URL que o cache de imagens aceita:
    /// "mp:external/…" vem pelo proxy de mídia, o número é um asset da
    /// aplicação. Spotify ("spotify:…") e outros de fora ficam sem imagem.
    fn activityImage(buf: []u8, app: Id, key: []const u8) []const u8 {
        if (std.mem.startsWith(u8, key, "mp:")) return std.fmt.bufPrint(buf, "https://media.discordapp.net/{s}", .{key[3..]}) catch "";
        if (key.len == 0 or app == 0) return "";
        for (key) |ch| if (!std.ascii.isDigit(ch)) return "";
        return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/app-assets/{d}/{s}.png", .{ app, key }) catch "";
    }

    /// Presenças podem vir como PresenceUpdate (com `user`) ou como
    /// MergedPresence do READY_SUPPLEMENTAL (com `user_id` e `presence`).
    fn ingestPresences(g: *Gateway, list: []const Value) void {
        for (list) |p| {
            var uid: Id = 0;
            if (j.get(p, "user")) |u| {
                if (j.get(u, "username") != null) g.upsert(u);
                uid = j.id(j.get(u, "id")) orelse 0;
            }
            if (uid == 0) uid = j.id(j.get(p, "user_id")) orelse continue;
            g.emit(.{ .presence_update = .{
                .user = uid,
                .status = presenceStatus(p),
                .activity = presenceActivity(p),
                .activities = presenceActivities(p),
            } });
        }
    }

    fn ingestMembers(g: *Gateway, v: Value) void {
        for (j.array(j.get(v, "members"))) |m| {
            if (j.get(m, "user")) |u| g.upsert(u);
        }
        g.ingestPresences(j.array(j.get(v, "presences")));
    }

    fn onReadySupplemental(g: *Gateway, d: Value) void {
        if (j.get(d, "merged_presences")) |mp| {
            g.ingestPresences(j.array(j.get(mp, "friends")));
            for (j.array(j.get(mp, "guilds"))) |list| g.ingestPresences(j.array(list));
        }
        for (j.array(j.get(d, "guilds"))) |gv| {
            for (j.array(j.get(gv, "voice_states"))) |vs| {
                const ch = j.id(j.get(vs, "channel_id")) orelse continue;
                const uid = j.id(j.get(vs, "user_id")) orelse continue;
                g.emit(.{ .voice_state = .{ .channel = ch, .user = uid } });
            }
        }
    }

    fn channelValue(g: *Gateway, cv: Value, guild_hint: Id) !?types.Channel {
        const cid = j.id(j.get(cv, "id")) orelse return null;
        const kind_i = j.int(j.get(cv, "type")) orelse 0;
        const kind: types.ChannelKind = switch (kind_i) {
            0, 5 => .text,
            1, 3 => .text,
            2, 13 => .voice,
            4 => .category,
            // Thread abre como conversa; o que muda fica em `.thread`.
            10, 11, 12 => .text,
            15, 16 => .forum,
            else => return null,
        };
        var gid = j.id(j.get(cv, "guild_id")) orelse guild_hint;
        if (kind_i == 1 or kind_i == 3) gid = 0;

        var name: []const u8 = j.str(j.get(cv, "name")) orelse "";
        var recipient: Id = 0;
        var recipients: []Id = &.{};
        var names: [96]u8 = undefined;
        if (kind_i == 1 or kind_i == 3) {
            var list: std.ArrayList(Id) = .empty;
            for (j.array(j.get(cv, "recipient_ids"))) |v| if (j.id(v)) |x| list.append(alloc, x) catch {};
            var nn: usize = 0;
            for (j.array(j.get(cv, "recipients"))) |u| {
                g.upsert(u);
                const uid = j.id(j.get(u, "id")) orelse continue;
                if (std.mem.indexOfScalar(Id, list.items, uid) == null) list.append(alloc, uid) catch {};
                // Grupo sem nome: "ana, bruno, kaique", como no Discord.
                const un = userName(u);
                if (nn + un.len + 2 < names.len) {
                    if (nn > 0) {
                        @memcpy(names[nn..][0..2], ", ");
                        nn += 2;
                    }
                    @memcpy(names[nn..][0..un.len], un);
                    nn += un.len;
                }
            }
            if (list.items.len > 0) recipient = list.items[0];
            if (kind_i == 3) recipients = list.toOwnedSlice(alloc) catch &.{} else list.deinit(alloc);
            if (name.len == 0) name = if (nn > 0) names[0..nn] else if (kind_i == 3) i18n.tr("grupo", "group") else "?";
        }
        if (name.len == 0) name = "?";

        const parent = j.id(j.get(cv, "parent_id")) orelse 0;
        const pos: u16 = @intCast(std.math.clamp(j.int(j.get(cv, "position")) orelse 0, 0, 65535));
        return .{
            .id = cid,
            .guild = gid,
            .parent = if (parent == 0) null else parent,
            .kind = kind,
            .name = dupe(name),
            .topic = dupe(j.str(j.get(cv, "topic")) orelse ""),
            .position = pos,
            .recipient = recipient,
            .recipients = recipients,
            .group = kind_i == 3,
            .icon = optDupe(j.str(j.get(cv, "icon"))),
            .overwrites = overwritesOf(cv),
            .thread = thread_json.threadInfo(cv, kind_i),
            .tags = thread_json.forumTags(cv),
            .media = kind_i == 16,
            .require_tag = thread_json.requiresTag(cv),
        };
    }

    /// Mensagem que abriu uma thread traz a thread junto: é assim que o cartão
    /// tem o que mostrar mesmo arquivada, fora da lista das ativas.
    fn messageThread(g: *Gateway, m: Value) void {
        const tv = j.get(m, "thread") orelse return;
        if (g.channelValue(tv, j.id(j.get(m, "guild_id")) orelse 0) catch null) |ch| g.emit(.{ .channel_upsert = ch });
    }

    /// THREAD_LIST_SYNC: as ativas de alguns canais (ou de todos, sem `channel_ids`).
    fn onThreadListSync(g: *Gateway, d: Value) !void {
        const gid = j.id(j.get(d, "guild_id")) orelse return;
        var parents: ?[]Id = null;
        if (j.get(d, "channel_ids")) |ids| {
            var list: std.ArrayList(Id) = .empty;
            for (j.array(ids)) |v| if (j.id(v)) |x| try list.append(alloc, x);
            parents = try list.toOwnedSlice(alloc);
        }
        const threads = try g.threadList(j.array(j.get(d, "threads")), gid);
        g.emit(.{ .thread_list_sync = .{ .guild = gid, .parents = parents, .threads = threads, .joined = memberThreads(j.array(j.get(d, "members"))) } });
        // Dá para mostrar o último autor sem esperar ninguém abrir.
        for (j.array(j.get(d, "most_recent_messages"))) |m| g.upsertUsers(m);
    }

    fn threadList(g: *Gateway, list: []const Value, gid: Id) ![]types.Channel {
        var out: std.ArrayList(types.Channel) = .empty;
        for (list) |tv| if (try g.channelValue(tv, gid)) |ch| try out.append(alloc, ch);
        return out.toOwnedSlice(alloc);
    }

    /// Objetos "thread member" nossos: em quais threads estamos.
    fn memberThreads(list: []const Value) []Id {
        var out: std.ArrayList(Id) = .empty;
        for (list) |mv| if (j.id(j.get(mv, "id"))) |x| out.append(alloc, x) catch {};
        return out.toOwnedSlice(alloc) catch &.{};
    }

    /// Lista inteira de quem está numa thread (THREAD_MEMBER_LIST_UPDATE e o REST).
    fn emitThreadMembers(g: *Gateway, thread: Id, members: []const Value) void {
        var out: std.ArrayList(Id) = .empty;
        for (members) |mv| {
            const uid = g.threadMemberUser(mv) orelse continue;
            out.append(alloc, uid) catch {};
        }
        g.emit(.{ .thread_members = .{ .thread = thread, .replace = true, .added = out.toOwnedSlice(alloc) catch &.{} } });
    }

    /// Quem é um "thread member", guardando o nome e a presença se vieram.
    fn threadMemberUser(g: *Gateway, mv: Value) ?Id {
        const uid = j.id(j.get(mv, "user_id")) orelse return null;
        if (j.get(mv, "member")) |m| if (j.get(m, "user")) |u| g.upsert(u);
        if (j.get(mv, "presence")) |p| g.emit(.{ .presence_update = .{ .user = uid, .status = statusOf(p), .activity = presenceActivity(p), .activities = presenceActivities(p) } });
        return uid;
    }

    fn onThreadMembersUpdate(g: *Gateway, d: Value) !void {
        const tid = j.id(j.get(d, "id")) orelse return;
        var added: std.ArrayList(Id) = .empty;
        for (j.array(j.get(d, "added_members"))) |mv| if (g.threadMemberUser(mv)) |uid| try added.append(alloc, uid);
        var removed: std.ArrayList(Id) = .empty;
        for (j.array(j.get(d, "removed_member_ids"))) |v| if (j.id(v)) |x| try removed.append(alloc, x);
        g.emit(.{ .thread_members = .{
            .thread = tid,
            .count = if (j.int(j.get(d, "member_count"))) |n| @intCast(std.math.clamp(n, 0, std.math.maxInt(u32))) else null,
            .added = try added.toOwnedSlice(alloc),
            .removed = try removed.toOwnedSlice(alloc),
        } });
    }

    /// Resposta com threads (busca do fórum, ativas, arquivadas): vira uma
    /// página. `parent` != 0 filtra (a lista do servidor traz todos os canais).
    fn emitThreadsPage(g: *Gateway, channel: Id, guild: Id, archived: bool, body: []const u8, parent: Id) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{});
        var threads: std.ArrayList(types.Channel) = .empty;
        for (j.array(j.get(root, "threads"))) |tv| {
            if (parent != 0 and j.id(j.get(tv, "parent_id")) != parent) continue;
            if (try g.channelValue(tv, guild)) |ch| try threads.append(alloc, ch);
        }
        var previews: std.ArrayList(types.ThreadPreview) = .empty;
        for (j.array(j.get(root, "first_messages"))) |m| {
            g.upsertUsers(m);
            const author = j.get(m, "author") orelse continue;
            const text = try j.simplifyContent(alloc, j.str(j.get(m, "content")) orelse "");
            try previews.append(alloc, .{ .thread = j.id(j.get(m, "channel_id")) orelse j.id(j.get(m, "id")) orelse 0, .author = j.id(j.get(author, "id")) orelse 0, .text = text });
        }
        const more = if (j.get(root, "has_more")) |v| v == .bool and v.bool else false;
        g.emit(.{ .threads_page = .{
            .channel = channel,
            .archived = archived,
            .threads = try threads.toOwnedSlice(alloc),
            .previews = try previews.toOwnedSlice(alloc),
            .joined = memberThreads(j.array(j.get(root, "members"))),
            .more = more,
        } });
    }

    /// Exceções de permissão de um canal (o Store fica com a lista).
    fn overwritesOf(cv: Value) []const types.Overwrite {
        var ows: std.ArrayList(types.Overwrite) = .empty;
        for (j.array(j.get(cv, "permission_overwrites"))) |ov| {
            const oid = j.id(j.get(ov, "id")) orelse continue;
            ows.append(alloc, .{
                .id = oid,
                .member = (j.int(j.get(ov, "type")) orelse 0) == 1,
                .allow = permBits(j.get(ov, "allow")),
                .deny = permBits(j.get(ov, "deny")),
            }) catch {};
        }
        return ows.toOwnedSlice(alloc) catch &.{};
    }

    /// Permissões vêm como texto ("1024") nas versões novas da API.
    fn permBits(v: ?Value) u64 {
        const x = v orelse return 0;
        return switch (x) {
            .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
            .integer => |n| @bitCast(n),
            else => 0,
        };
    }

    fn onGuildCreate(g: *Gateway, d: Value) !void {
        const gid = j.id(j.get(d, "id")) orelse return;
        if (j.get(d, "unavailable")) |u| {
            if (u == .bool and u.bool) return;
        }
        const name = guildName(d);
        var channels: std.ArrayList(types.Channel) = .empty;
        errdefer {
            for (channels.items) |ch| {
                alloc.free(ch.name);
                alloc.free(ch.topic);
            }
            channels.deinit(alloc);
        }
        try appendChannels(&channels, gid, j.array(j.get(d, "channels")));
        for (j.array(j.get(d, "threads"))) |tv| if (try g.channelValue(tv, gid)) |ch| try channels.append(alloc, ch);
        var voice: std.ArrayList([2]Id) = .empty;
        errdefer voice.deinit(alloc);
        for (j.array(j.get(d, "voice_states"))) |vs| {
            const ch = j.id(j.get(vs, "channel_id")) orelse continue;
            const uid = j.id(j.get(vs, "user_id")) orelse continue;
            try voice.append(alloc, .{ ch, uid });
        }
        g.ingestMembers(d);
        g.ingestRoles(gid, j.array(j.get(d, "roles")));
        g.emit(.{ .guild_create = .{
            .guild = .{
                .id = gid,
                .name = dupe(name),
                .acronym = try j.acronym(alloc, name),
                .color = @intCast((gid >> 22) % 8),
                .icon = guildIcon(d),
                .owner = ownerOf(d),
            },
            .channels = try channels.toOwnedSlice(alloc),
            .voice = try voice.toOwnedSlice(alloc),
        } });
    }

    /// Mensagem da API -> nosso tipo (conteúdo alocado).
    fn message(g: *Gateway, m: Value) !?types.Message {
        const author = j.get(m, "author") orelse return null;
        const msg_id = j.id(j.get(m, "id")) orelse return null;
        const msg_type = j.int(j.get(m, "type")) orelse 0;
        // Primeira linha de uma thread aberta de uma mensagem: vem vazia, com a
        // mensagem original em `referenced_message`. Mostra a original.
        if (msg_type == 21) if (j.get(m, "referenced_message")) |ref| if (ref != .null) {
            g.upsertUsers(ref);
            var out = (try g.message(ref)) orelse return null;
            out.id = msg_id;
            out.channel = j.id(j.get(m, "channel_id")) orelse out.channel;
            out.thread = 0;
            return out;
        };
        const raw_text = j.str(j.get(m, "content")) orelse "";
        var content = try j.simplifyContent(alloc, raw_text);
        errdefer alloc.free(content);
        const raw: []const u8 = if (content.len != raw_text.len) try alloc.dupe(u8, raw_text) else "";
        errdefer alloc.free(raw);
        const atts = try attachmentsOf(m);
        errdefer types.freeAttachments(alloc, atts);
        for (j.array(j.get(m, "sticker_items"))) |s| {
            const more = try i18n.allocPrint(alloc, "{s} [figurinha: {s}]", "{s} [sticker: {s}]", .{ content, j.str(j.get(s, "name")) orelse "?" });
            alloc.free(content);
            content = more;
        }
        const embeds = try embedsOf(m);
        errdefer types.freeEmbeds(alloc, embeds);
        // Mensagens de sistema vêm sem texto: monta o que o Discord mostra.
        const sys = try systemText(m, author);
        if (sys.text) |t| {
            alloc.free(content);
            content = t;
        }
        const nonce: u64 = if (j.get(m, "nonce")) |n| @bitCast(j.int(n) orelse 0) else 0;
        var reply: Id = 0;
        if (j.get(m, "message_reference")) |ref| {
            if (msg_type == 19) reply = j.id(j.get(ref, "message_id")) orelse 0;
        }
        // Quem abriu a thread: o cartão na própria mensagem, ou na linha de
        // sistema "fulano criou uma thread" (que aponta para ela).
        var thread: Id = if (j.get(m, "thread")) |tv| j.id(j.get(tv, "id")) orelse 0 else 0;
        if (msg_type == 18) if (j.get(m, "message_reference")) |ref| {
            thread = j.id(j.get(ref, "channel_id")) orelse thread;
        };
        return .{
            .id = msg_id,
            .channel = j.id(j.get(m, "channel_id")) orelse 0,
            .author = j.id(j.get(author, "id")) orelse 0,
            .timestamp = j.isoTime(j.str(j.get(m, "timestamp")) orelse ""),
            .content = content,
            .raw = raw,
            .nonce = nonce,
            .reply_to = reply,
            .edited = !j.isNull(j.get(m, "edited_timestamp")),
            .attachments = atts,
            .embeds = embeds,
            .system = sys.kind,
            .mention_everyone = if (j.get(m, "mention_everyone")) |me| me == .bool and me.bool else false,
            .mentions_me = for (j.array(j.get(m, "mentions"))) |u| {
                if (j.id(j.get(u, "id")) == g.me) break true;
            } else false,
            .thread = thread,
        };
    }

    /// Texto das mensagens de sistema (tipos do Discord), com os nomes em
    /// negrito: "**ana** adicionou **bruno** ao grupo."
    fn systemText(m: Value, author: Value) !struct { kind: types.SystemKind = .none, text: ?[]u8 = null } {
        const kind = j.int(j.get(m, "type")) orelse 0;
        const who = userName(author);
        const mentions = j.array(j.get(m, "mentions"));
        const other = if (mentions.len > 0) userName(mentions[0]) else "?";
        const same = mentions.len > 0 and j.id(j.get(mentions[0], "id")) == j.id(j.get(author, "id"));
        const content = j.str(j.get(m, "content")) orelse "";
        return switch (kind) {
            1 => .{ .kind = .join, .text = try i18n.allocPrint(alloc, "**{s}** adicionou **{s}** ao grupo.", "**{s}** added **{s}** to the group.", .{ who, other }) },
            2 => if (same or mentions.len == 0)
                .{ .kind = .leave, .text = try i18n.allocPrint(alloc, "**{s}** saiu do grupo.", "**{s}** left the group.", .{who}) }
            else
                .{ .kind = .leave, .text = try i18n.allocPrint(alloc, "**{s}** removeu **{s}** do grupo.", "**{s}** removed **{s}** from the group.", .{ who, other }) },
            3 => .{ .kind = .call, .text = try i18n.allocPrint(alloc, "**{s}** começou uma chamada.", "**{s}** started a call.", .{who}) },
            4 => .{ .kind = .edit, .text = try i18n.allocPrint(alloc, "**{s}** mudou o nome do canal para **{s}**.", "**{s}** changed the channel name to **{s}**.", .{ who, content }) },
            5 => .{ .kind = .edit, .text = try i18n.allocPrint(alloc, "**{s}** mudou o ícone do grupo.", "**{s}** changed the group icon.", .{who}) },
            6 => .{ .kind = .pin, .text = try i18n.allocPrint(alloc, "**{s}** fixou uma mensagem neste canal.", "**{s}** pinned a message to this channel.", .{who}) },
            7 => .{ .kind = .join, .text = try i18n.allocPrint(alloc, "**{s}** entrou no servidor.", "**{s}** joined the server.", .{who}) },
            8 => .{ .kind = .boost, .text = try i18n.allocPrint(alloc, "**{s}** deu um impulso no servidor!", "**{s}** just boosted the server!", .{who}) },
            9, 10, 11 => .{ .kind = .boost, .text = try i18n.allocPrint(alloc, "**{s}** deu um impulso no servidor! Ele chegou ao **nível {d}**!", "**{s}** just boosted the server! It reached **Level {d}**!", .{ who, kind - 8 }) },
            12 => .{ .kind = .other, .text = try i18n.allocPrint(alloc, "**{s}** passou a seguir um canal de anúncios aqui.", "**{s}** followed an announcement channel here.", .{who}) },
            18 => .{ .kind = .other, .text = try i18n.allocPrint(alloc, "**{s}** criou um tópico: **{s}**", "**{s}** started a thread: **{s}**", .{ who, content }) },
            else => .{},
        };
    }

    /// URL de mídia que veio do servidor: `file://` é só para o que a própria
    /// pessoa anexou, nunca para o que vem da rede.
    fn isHttp(u: []const u8) bool {
        return std.mem.startsWith(u8, u, "https://") or std.mem.startsWith(u8, u, "http://");
    }

    /// Anexos e imagens de links (embeds de imagem/GIF) de uma mensagem.
    /// Imagens usam o `proxy_url` (media.discordapp.net), que sabe reduzir.
    fn attachmentsOf(m: Value) ![]types.Attachment {
        var list: std.ArrayList(types.Attachment) = .empty;
        errdefer types.freeAttachments(alloc, list.toOwnedSlice(alloc) catch &.{});
        for (j.array(j.get(m, "attachments"))) |a| {
            if (list.items.len >= 10) break;
            const w = j.int(j.get(a, "width")) orelse 0;
            const h = j.int(j.get(a, "height")) orelse 0;
            const name = j.str(j.get(a, "filename")) orelse i18n.tr("arquivo", "file");
            const ctype = j.str(j.get(a, "content_type")) orelse "";
            const gif = std.mem.eql(u8, ctype, "image/gif") or std.ascii.endsWithIgnoreCase(name, ".gif");
            const video = std.mem.startsWith(u8, ctype, "video/");
            const image = w > 0 and h > 0;
            const cdn = j.str(j.get(a, "url")) orelse continue;
            // Imagem pelo proxy (que reduz); GIF do arquivo original (o proxy
            // pode devolver parado); vídeo: um quadro pelo proxy, e o link.
            const url = if (image and !gif) j.str(j.get(a, "proxy_url")) orelse cdn else cdn;
            if (!isHttp(url)) continue;
            try list.append(alloc, .{
                .url = try alloc.dupe(u8, url),
                .filename = try alloc.dupe(u8, name),
                .width = @intCast(std.math.clamp(w, 0, 65535)),
                .height = @intCast(std.math.clamp(h, 0, 65535)),
                .size = @intCast(std.math.clamp(j.int(j.get(a, "size")) orelse 0, 0, std.math.maxInt(u32))),
                .animated = gif,
                .video = video and image,
                .link = if (video and image) try alloc.dupe(u8, cdn) else "",
            });
        }
        try embedAttachments(m, &list);
        return list.toOwnedSlice(alloc);
    }

    /// Embeds que são só uma imagem ou GIF (link direto, Tenor…) aparecem
    /// como anexo; os outros viram cartão (`embedsOf`).
    fn embedAttachments(m: Value, list: *std.ArrayList(types.Attachment)) !void {
        for (j.array(j.get(m, "embeds"))) |e| {
            if (list.items.len >= 10) break;
            const kind = j.str(j.get(e, "type")) orelse "";
            if (!std.mem.eql(u8, kind, "image") and !std.mem.eql(u8, kind, "gifv")) continue;
            const iv = j.get(e, "image") orelse j.get(e, "thumbnail") orelse continue;
            const url = j.str(j.get(iv, "proxy_url")) orelse continue;
            if (!isHttp(url)) continue;
            const w = j.int(j.get(iv, "width")) orelse 0;
            const h = j.int(j.get(iv, "height")) orelse 0;
            if (w <= 0 or h <= 0) continue;
            // GIF do Tenor/Giphy: o Discord manda MP4; o GIF vem do site deles,
            // com a miniatura do proxy de reserva.
            var gb: [512]u8 = undefined;
            var gif: ?[]const u8 = if (std.mem.eql(u8, kind, "gifv")) if (j.get(e, "video")) |v| media_url.gifFromVideo(&gb, j.str(j.get(v, "url")) orelse "") else null else null;
            // Tenor antigo (media.tenor.co, só MP4): vai pela página do GIF.
            var pb: [600]u8 = undefined;
            if (gif == null and std.mem.eql(u8, kind, "gifv")) if (j.str(j.get(e, "url"))) |page| {
                if (std.mem.startsWith(u8, page, "https://tenor.com/")) gif = std.fmt.bufPrint(&pb, "{s}{s}", .{ media_url.tenor_page, page }) catch null;
            };
            try list.append(alloc, .{
                .url = try alloc.dupe(u8, gif orelse url),
                .filename = try alloc.dupe(u8, j.str(j.get(e, "title")) orelse i18n.tr("imagem", "image")),
                .width = @intCast(@min(w, 65535)),
                .height = @intCast(@min(h, 65535)),
                .animated = std.mem.eql(u8, kind, "gifv"),
                .still = if (gif != null) try alloc.dupe(u8, url) else "",
                .embed = true,
            });
        }
    }

    /// Cartões (embeds de bots e prévias de links).
    fn embedsOf(m: Value) ![]types.Embed {
        var list: std.ArrayList(types.Embed) = .empty;
        errdefer types.freeEmbeds(alloc, list.toOwnedSlice(alloc) catch &.{});
        for (j.array(j.get(m, "embeds"))) |e| {
            if (list.items.len >= 6) break;
            const kind = j.str(j.get(e, "type")) orelse "rich";
            if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "gifv")) continue;
            var out: types.Embed = .{};
            if (j.int(j.get(e, "color"))) |col| {
                out.color = @intCast(std.math.clamp(col, 0, 0xffffff));
                out.has_color = true;
            }
            const sub = struct {
                fn f(v: Value, obj: []const u8, key: []const u8) []const u8 {
                    return if (j.get(v, obj)) |o| j.str(j.get(o, key)) orelse "" else "";
                }
            }.f;
            out.provider = try dupeOpt(sub(e, "provider", "name"));
            out.author = try dupeOpt(sub(e, "author", "name"));
            out.title = try dupeOpt(j.str(j.get(e, "title")) orelse "");
            out.url = try dupeOpt(j.str(j.get(e, "url")) orelse "");
            out.description = try dupeOpt(j.str(j.get(e, "description")) orelse "");
            out.footer = try dupeOpt(sub(e, "footer", "text"));
            var fields: std.ArrayList(types.EmbedField) = .empty;
            for (j.array(j.get(e, "fields"))) |fv| {
                if (fields.items.len >= 25) break;
                try fields.append(alloc, .{ .name = try alloc.dupe(u8, j.str(j.get(fv, "name")) orelse ""), .value = try alloc.dupe(u8, j.str(j.get(fv, "value")) orelse "") });
            }
            out.fields = try fields.toOwnedSlice(alloc);
            // Vídeo (YouTube…): a miniatura grande vira a imagem, com play.
            out.video = j.get(e, "video") != null;
            // Só o arquivo pelo proxy do Discord toca aqui (o do YouTube é uma página).
            if (j.get(e, "video")) |vv| if (j.str(j.get(vv, "proxy_url"))) |pu| {
                if (media_url.discordHost(pu)) out.video_url = try alloc.dupe(u8, pu);
            };
            const big = j.get(e, "image") orelse if (out.video) j.get(e, "thumbnail") else null;
            if (big) |iv| if (j.str(j.get(iv, "proxy_url"))) |u| if (isHttp(u)) {
                out.image = try alloc.dupe(u8, u);
                out.image_w = @intCast(std.math.clamp(j.int(j.get(iv, "width")) orelse 400, 1, 65535));
                out.image_h = @intCast(std.math.clamp(j.int(j.get(iv, "height")) orelse 225, 1, 65535));
            };
            if (!out.video) if (j.get(e, "thumbnail")) |tv| {
                const u = j.str(j.get(tv, "proxy_url")) orelse "";
                out.thumb = try dupeOpt(if (isHttp(u)) u else "");
            };
            const empty = out.title.len == 0 and out.description.len == 0 and out.author.len == 0 and out.fields.len == 0 and out.image.len == 0 and out.thumb.len == 0;
            if (empty) {
                types.freeEmbed(alloc, out);
                continue;
            }
            try list.append(alloc, out);
        }
        return list.toOwnedSlice(alloc);
    }

    /// GET /users/{id}/profile: banner, bio, desde quando está no servidor,
    /// servidores e amigos em comum, contas ligadas e insígnias.
    fn onProfile(g: *Gateway, uid: Id, guild: Id, body: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{}) catch return;
        const u = j.get(v, "user") orelse return;
        const up = j.get(v, "user_profile");
        g.upsert(u);
        for (j.array(j.get(v, "mutual_friends"))) |f| g.upsert(f);
        const bio = (if (up) |p| j.str(j.get(p, "bio")) else null) orelse j.str(j.get(u, "bio")) orelse "";
        var pf: types.Profile = .{
            .banner = dupeOpt(j.str(j.get(u, "banner")) orelse "") catch "",
            .accent = @intCast(std.math.clamp(j.int(j.get(u, "accent_color")) orelse 0, 0, 0xffffff)),
            .bio = dupeOpt(bio) catch "",
            .pronouns = dupeOpt((if (up) |p| j.str(j.get(p, "pronouns")) else null) orelse "") catch "",
            .username = dupeOpt(j.str(j.get(u, "username")) orelse "") catch "",
            .guild = guild,
        };
        if (j.get(v, "guild_member")) |gm| {
            pf.joined_ms = j.isoTime(j.str(j.get(gm, "joined_at")) orelse "") * 1000;
            pf.boost_ms = j.isoTime(j.str(j.get(gm, "premium_since")) orelse "") * 1000;
        }
        var mg: std.ArrayList(Id) = .empty;
        for (j.array(j.get(v, "mutual_guilds"))) |m| if (j.id(j.get(m, "id"))) |id| mg.append(alloc, id) catch {};
        pf.mutual_guilds = mg.toOwnedSlice(alloc) catch &.{};
        var mf: std.ArrayList(Id) = .empty;
        for (j.array(j.get(v, "mutual_friends"))) |f| if (j.id(j.get(f, "id"))) |id| mf.append(alloc, id) catch {};
        pf.mutual_friends = mf.toOwnedSlice(alloc) catch &.{};
        pf.mutual_friends_count = @intCast(std.math.clamp(j.int(j.get(v, "mutual_friends_count")) orelse @as(i64, @intCast(pf.mutual_friends.len)), 0, 1 << 30));
        var cns: std.ArrayList(types.Connection) = .empty;
        for (j.array(j.get(v, "connected_accounts"))) |ca| {
            const kind = j.str(j.get(ca, "type")) orelse continue;
            const name = j.str(j.get(ca, "name")) orelse continue;
            var ub: [256]u8 = undefined;
            cns.append(alloc, .{
                .kind = dupeOpt(kind) catch continue,
                .name = dupeOpt(name) catch continue,
                .url = dupeOpt(connectionUrl(&ub, kind, name, j.str(j.get(ca, "id")) orelse "")) catch "",
            }) catch {};
        }
        pf.connections = cns.toOwnedSlice(alloc) catch &.{};
        var bds: std.ArrayList(types.Badge) = .empty;
        for (j.array(j.get(v, "badges"))) |bv| {
            const icon = j.str(j.get(bv, "icon")) orelse continue;
            bds.append(alloc, .{
                .icon = dupeOpt(icon) catch continue,
                .description = dupeOpt(j.str(j.get(bv, "description")) orelse "") catch "",
            }) catch {};
        }
        pf.badges = bds.toOwnedSlice(alloc) catch &.{};
        g.emit(.{ .profile = .{ .user = uid, .profile = pf } });
    }

    /// Link público da conta ligada (só os serviços com endereço conhecido).
    pub fn connectionUrl(buf: []u8, kind: []const u8, name: []const u8, id: []const u8) []const u8 {
        const safe = struct {
            fn f(t: []const u8) bool {
                if (t.len == 0) return false;
                for (t) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
                return true;
            }
        }.f;
        const eq = std.mem.eql;
        if (eq(u8, kind, "github") and safe(name)) return std.fmt.bufPrint(buf, "https://github.com/{s}", .{name}) catch "";
        if (eq(u8, kind, "twitch") and safe(name)) return std.fmt.bufPrint(buf, "https://twitch.tv/{s}", .{name}) catch "";
        if (eq(u8, kind, "reddit") and safe(name)) return std.fmt.bufPrint(buf, "https://reddit.com/u/{s}", .{name}) catch "";
        if (eq(u8, kind, "twitter") and safe(name)) return std.fmt.bufPrint(buf, "https://x.com/{s}", .{name}) catch "";
        if (eq(u8, kind, "tiktok") and safe(name)) return std.fmt.bufPrint(buf, "https://tiktok.com/@{s}", .{name}) catch "";
        if (eq(u8, kind, "instagram") and safe(name)) return std.fmt.bufPrint(buf, "https://instagram.com/{s}", .{name}) catch "";
        if (eq(u8, kind, "bluesky") and safe(name)) return std.fmt.bufPrint(buf, "https://bsky.app/profile/{s}", .{name}) catch "";
        if (eq(u8, kind, "domain") and safe(name)) return std.fmt.bufPrint(buf, "https://{s}", .{name}) catch "";
        if (eq(u8, kind, "youtube") and safe(id)) return std.fmt.bufPrint(buf, "https://youtube.com/channel/{s}", .{id}) catch "";
        if (eq(u8, kind, "steam") and safe(id)) return std.fmt.bufPrint(buf, "https://steamcommunity.com/profiles/{s}", .{id}) catch "";
        if (eq(u8, kind, "spotify") and safe(id)) return std.fmt.bufPrint(buf, "https://open.spotify.com/user/{s}", .{id}) catch "";
        return "";
    }

    fn dupeOpt(t: []const u8) ![]const u8 {
        return if (t.len == 0) "" else try alloc.dupe(u8, t);
    }

    fn onReady(g: *Gateway, d: Value, arena: std.mem.Allocator) !void {
        _ = arena;
        const me = j.get(d, "user") orelse return;
        g.me = j.id(j.get(me, "id")) orelse return;
        // O pedido de voz pode ter chegado antes do READY; agora o gateway
        // já aceita o op 4. Numa sessão nova a call antiga não vale mais.
        if (g.voice_channel != 0) {
            g.stopVoice();
            g.sendVoiceState(g.voice_channel);
        }
        // Guarda os dados de retomada: a próxima queda de rede usa RESUME.
        // Um READY é sempre sessão nova; não deixa sobrar a anterior.
        g.session_len = 0;
        @memset(&g.session_id, 0);
        g.resume_len = 0;
        @memset(&g.resume_base, 0);
        if (j.str(j.get(d, "session_id"))) |sid| {
            const n: u8 = @intCast(@min(sid.len, g.session_id.len));
            g.session_id = @splat(0);
            @memcpy(g.session_id[0..n], sid[0..n]);
            g.session_len = n;
        }
        if (j.str(j.get(d, "resume_gateway_url"))) |base| {
            const n: u8 = @intCast(@min(base.len, g.resume_base.len));
            g.resume_base = @splat(0);
            @memcpy(g.resume_base[0..n], base[0..n]);
            g.resume_len = n;
        }

        var users: std.ArrayList(types.User) = .empty;
        var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
        defer seen.deinit(alloc);
        const addUser = struct {
            fn f(list: *std.ArrayList(types.User), set: *std.AutoHashMapUnmanaged(Id, void), u: Value, status: types.Status) void {
                const uid = j.id(j.get(u, "id")) orelse return;
                if (set.contains(uid)) return;
                set.put(alloc, uid, {}) catch return;
                list.append(alloc, .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = status, .avatar = avatarOf(u), .decoration = decorationOf(u) }) catch {};
            }
        }.f;
        addUser(&users, &seen, me, .online);
        for (j.array(j.get(d, "users"))) |u| addUser(&users, &seen, u, .offline);
        // Contas de usuário recebem os membros de todos os servidores aqui;
        // é o que abastece a lista de membros (o bot recebe via GUILD_CREATE).
        for (j.array(j.get(d, "merged_members"))) |members| {
            for (j.array(members)) |m| {
                if (j.get(m, "user")) |u| addUser(&users, &seen, u, .offline);
            }
        }

        var guilds: std.ArrayList(types.Guild) = .empty;
        var channels: std.ArrayList(types.Channel) = .empty;
        var voice: std.ArrayList([2]Id) = .empty;
        for (j.array(j.get(d, "guilds"))) |gv| {
            const gid = j.id(j.get(gv, "id")) orelse continue;
            const props = j.get(gv, "properties");
            const name = j.str(j.get(gv, "name")) orelse (if (props) |p| j.str(j.get(p, "name")) else null) orelse i18n.tr("servidor", "server");
            try guilds.append(alloc, .{ .id = gid, .name = dupe(name), .acronym = try j.acronym(alloc, name), .color = @intCast((gid >> 22) % 8), .icon = guildIcon(gv), .owner = ownerOf(gv) });
            g.ingestRoles(gid, j.array(j.get(gv, "roles")));
            try appendChannels(&channels, gid, j.array(j.get(gv, "channels")));
            for (j.array(j.get(gv, "threads"))) |tv| if (try g.channelValue(tv, gid)) |ch| try channels.append(alloc, ch);
            for (j.array(j.get(gv, "voice_states"))) |vs| {
                const ch = j.id(j.get(vs, "channel_id")) orelse continue;
                const uid = j.id(j.get(vs, "user_id")) orelse continue;
                try voice.append(alloc, .{ ch, uid });
            }
        }
        // Os nossos cargos em cada servidor (merged_members vem na mesma ordem
        // dos servidores): é o que decide o que podemos fazer em cada um.
        for (j.array(j.get(d, "merged_members")), 0..) |members, gi| {
            const gv = j.array(j.get(d, "guilds"));
            if (gi >= gv.len) break;
            const gid = j.id(j.get(gv[gi], "id")) orelse continue;
            for (j.array(members)) |m| {
                const uid = j.id(j.get(m, "user_id")) orelse (if (j.get(m, "user")) |u| j.id(j.get(u, "id")) else null) orelse continue;
                if (uid == g.me) g.memberColor(gid, uid, m);
            }
        }
        // DMs e grupos (os participantes vêm em `users`, pelo ID).
        for (j.array(j.get(d, "private_channels")), 0..) |pc, pos| {
            for (j.array(j.get(pc, "recipients"))) |u| addUser(&users, &seen, u, .offline);
            var ch = (try g.channelValue(pc, 0)) orelse continue;
            if (ch.recipient == 0 and !ch.group) {
                alloc.free(ch.name);
                alloc.free(ch.topic);
                continue;
            }
            ch.position = @intCast(@min(pos, 65535));
            // Sem nome e sem `recipients` completos: monta com os nomes conhecidos.
            if (j.str(j.get(pc, "name")) == null or j.str(j.get(pc, "name")).?.len == 0) {
                var nb: std.ArrayList(u8) = .empty;
                const ids: []const Id = if (ch.recipients.len > 0) ch.recipients else &.{ch.recipient};
                for (ids) |rid| for (users.items) |u| if (u.id == rid) {
                    if (nb.items.len > 0) nb.appendSlice(alloc, ", ") catch {};
                    nb.appendSlice(alloc, u.name) catch {};
                    break;
                };
                if (nb.items.len > 0 and nb.items.len < 96) {
                    alloc.free(ch.name);
                    ch.name = nb.toOwnedSlice(alloc) catch dupe("?");
                } else nb.deinit(alloc);
            }
            try channels.append(alloc, ch);
        }
        // DMs mais recentes primeiro (o id da última mensagem cresce com o tempo).
        sortDms(channels.items, j.array(j.get(d, "private_channels")));

        for (j.array(j.get(d, "relationships"))) |rv| {
            if (j.get(rv, "user")) |u| addUser(&users, &seen, u, .offline);
        }
        g.emit(.{ .ready = .{
            .me = g.me,
            .users = try users.toOwnedSlice(alloc),
            .guilds = try guilds.toOwnedSlice(alloc),
            .channels = try channels.toOwnedSlice(alloc),
            .voice = try voice.toOwnedSlice(alloc),
            .username = optDupe(j.str(j.get(me, "username"))),
            .email = optDupe(j.str(j.get(me, "email"))),
        } });
        for (j.array(j.get(d, "relationships"))) |rv| {
            const uid = j.id(j.get(rv, "user_id")) orelse j.id(j.get(rv, "id")) orelse continue;
            g.emit(.{ .relationship = .{ .user = uid, .kind = relationshipKind(j.get(rv, "type")), .since_ms = sinceMs(rv) } });
        }
        // Pastas e ordem dos servidores: protobuf das configurações (contas
        // atuais) ou o JSON antigo.
        if (j.str(j.get(d, "user_settings_proto"))) |b64| {
            if (settings_proto.fromProtoBase64(alloc, b64)) |layout| g.emitFolders(layout) else |_| {}
        } else if (j.get(d, "user_settings")) |us| if (j.get(us, "guild_folders")) |gf| {
            if (settings_proto.fromJson(alloc, gf)) |layout| g.emitFolders(layout) else |_| {}
        };
        g.emit(.{ .status = .ready });
        g.gatewayReady();
        // Sessão nova: a lista de membros que estava aberta precisa ser pedida de novo.
        if (g.sub_guild != 0) g.subscribe(g.sub_guild, g.sub_channel, g.sub_thread);
    }

    /// READY/RESUMED: o que esperava o gateway volta para a fila.
    fn gatewayReady(g: *Gateway) void {
        g.ws_ready = true;
        g.pending.appendSlice(alloc, g.held.items) catch {};
        g.held.clearRetainingCapacity();
    }

    /// Comando que é escrito no WebSocket (não passa pelo REST).
    fn usesGateway(cmd: ev.Command) bool {
        return switch (cmd) {
            .subscribe_guild, .set_status, .join_voice, .voice_flags => true,
            else => false,
        };
    }

    fn sortDms(chs: []types.Channel, pcs: []const Value) void {
        var first_dm: usize = chs.len;
        for (chs, 0..) |ch, i| if (ch.guild == 0) {
            first_dm = i;
            break;
        };
        // Conta de muitas DMs: a última mensagem é lida uma vez por canal,
        // não a cada comparação.
        var last: std.AutoHashMapUnmanaged(Id, u64) = .empty;
        defer last.deinit(alloc);
        last.ensureTotalCapacity(alloc, @intCast(pcs.len)) catch return;
        for (pcs) |pc| if (j.id(j.get(pc, "id"))) |id| {
            last.putAssumeCapacity(id, j.id(j.get(pc, "last_message_id")) orelse 0);
        };
        const Ctx = struct {
            last: *const std.AutoHashMapUnmanaged(Id, u64),
            fn lt(self: @This(), a: types.Channel, b: types.Channel) bool {
                if (a.guild != 0 or b.guild != 0) return false;
                return (self.last.get(a.id) orelse 0) > (self.last.get(b.id) orelse 0);
            }
        };
        std.mem.sort(types.Channel, chs[first_dm..], Ctx{ .last = &last }, Ctx.lt);
    }

    /// Canais de um servidor na ordem do Discord: soltos primeiro, depois
    /// cada categoria com os seus (texto antes de voz).
    fn appendChannels(out: *std.ArrayList(types.Channel), gid: Id, list: []const Value) !void {
        const Ch = struct { id: Id, parent: Id, kind: types.ChannelKind, pos: i64, name: []const u8, topic: []const u8, source: Value };
        var tmp: std.ArrayList(Ch) = .empty;
        defer tmp.deinit(alloc);
        for (list) |cv| {
            const kind: types.ChannelKind = switch (j.int(j.get(cv, "type")) orelse 0) {
                0, 5 => .text,
                2, 13 => .voice,
                4 => .category,
                15, 16 => .forum,
                else => continue,
            };
            try tmp.append(alloc, .{
                .id = j.id(j.get(cv, "id")) orelse continue,
                .parent = j.id(j.get(cv, "parent_id")) orelse 0,
                .kind = kind,
                .pos = j.int(j.get(cv, "position")) orelse 0,
                .name = j.str(j.get(cv, "name")) orelse "?",
                .topic = j.str(j.get(cv, "topic")) orelse "",
                .source = cv,
            });
        }
        const lt = struct {
            fn f(_: void, a: Ch, b: Ch) bool {
                const ka: u8 = if (a.kind == .voice) 1 else 0;
                const kb: u8 = if (b.kind == .voice) 1 else 0;
                if (ka != kb) return ka < kb;
                return if (a.pos != b.pos) a.pos < b.pos else a.id < b.id;
            }
        }.f;
        std.mem.sort(Ch, tmp.items, {}, lt);
        var pos: u16 = 0;
        const push = struct {
            fn f(o: *std.ArrayList(types.Channel), g: Id, ch: Ch, p: *u16) !void {
                try o.append(alloc, .{ .id = ch.id, .guild = g, .parent = if (ch.parent == 0) null else ch.parent, .kind = ch.kind, .name = dupe(ch.name), .topic = dupe(ch.topic), .position = p.*, .overwrites = overwritesOf(ch.source), .tags = thread_json.forumTags(ch.source), .media = (j.int(j.get(ch.source, "type")) orelse 0) == 16, .require_tag = thread_json.requiresTag(ch.source) });
                p.* +%= 1;
            }
        }.f;
        for (tmp.items) |ch| if (ch.kind != .category and ch.parent == 0) try push(out, gid, ch, &pos);
        for (tmp.items) |cat| {
            if (cat.kind != .category) continue;
            try push(out, gid, cat, &pos);
            for (tmp.items) |ch| if (ch.kind != .category and ch.parent == cat.id) try push(out, gid, ch, &pos);
        }
    }

    // --- REST ------------------------------------------------------------------

    const Response = struct { status: c_long, body: std.ArrayList(u8) };

    /// Cabeçalhos de rate limit que o Discord manda em toda resposta.
    const RateInfo = struct {
        remaining: ?u32 = null,
        reset_after_ms: ?u32 = null,
        retry_after_ms: ?u32 = null,
        global: bool = false,
    };

    /// Configurações → Privacidade → Rede com "em tudo": gateway e API
    /// também pelo proxy (o gateway muda na próxima conexão).
    fn useProxy(h: *c.CURL) void {
        var pb: proxy.Buf = undefined;
        if (proxy.forDiscord(&pb)) |p| _ = c.curl_easy_setopt(h, c.CURLOPT_PROXY, p.ptr);
    }

    /// Transferência que para assim que o app pede para encerrar.
    fn abortable(g: *Gateway, h: *c.CURL) void {
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, abortCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFODATA, g);
    }

    fn abortCb(ud: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
        const g: *Gateway = @ptrCast(@alignCast(ud.?));
        if (g.abort.load(.acquire)) return 1;
        // Transferência longa (upload): o WebSocket é outro handle e continua
        // sendo atendido, senão o Discord derruba a sessão por falta de heartbeat.
        const now = nowMs();
        if (now - g.serviced_ms >= 200) {
            g.serviced_ms = now;
            g.serviceWs();
        }
        return 0;
    }

    fn writeCb(ptr: [*c]u8, size: usize, n: usize, user: ?*anyopaque) callconv(.c) usize {
        const body: *std.ArrayList(u8) = @ptrCast(@alignCast(user.?));
        body.appendSlice(alloc, ptr[0 .. size * n]) catch return 0;
        return size * n;
    }

    fn secondsToMs(s: []const u8) ?u32 {
        const f = std.fmt.parseFloat(f64, s) catch return null;
        return floatSecondsToMs(f);
    }

    /// Segundos vindos do servidor: nada de negativo, NaN ou infinito. Um
    /// bloqueio longo (Cloudflare: até horas) vale inteiro.
    fn floatSecondsToMs(f: f64) ?u32 {
        if (!(f >= 0) or f > 86_400) return null;
        return @intFromFloat(f * 1000);
    }

    fn headerCb(ptr: [*c]u8, size: usize, n: usize, user: ?*anyopaque) callconv(.c) usize {
        const total = size * n;
        const rh: *RateInfo = @ptrCast(@alignCast(user.?));
        const line = ptr[0..total];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return total;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \r\n\t ");
        if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) {
            if (std.fmt.parseInt(u32, value, 10)) |v| {
                rh.remaining = v;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset-after")) {
            rh.reset_after_ms = secondsToMs(value);
        } else if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            rh.retry_after_ms = secondsToMs(value);
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-global")) {
            rh.global = std.ascii.eqlIgnoreCase(value, "true");
        }
        return total;
    }

    fn applyRate(g: *Gateway, rh: RateInfo) void {
        if (rh.reset_after_ms) |ms| {
            if (rh.remaining != null and rh.remaining.? == 0) {
                const until = nowMs() + @as(i64, ms) + 100;
                if (rh.global) {
                    g.global_until = @max(g.global_until, until);
                } else {
                    g.rate_until = @max(g.rate_until, until);
                }
            }
        }
    }

    /// Mostra o erro que o Discord mandou ("Missing Access", "Unknown Message"...).
    fn noticeHttp(g: *Gateway, what: []const u8, resp: *const Response) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var detail: []const u8 = "";
        if (resp.body.items.len > 0) {
            if (std.json.parseFromSliceLeaky(Value, arena.allocator(), resp.body.items, .{})) |root| {
                if (j.str(j.get(root, "message"))) |m| detail = m;
            } else |_| {}
        }
        if (detail.len > 0) {
            g.notice("{s}: {s}", "{s}: {s}", .{ what, detail });
        } else {
            g.notice("{s} (HTTP {d})", "{s} (HTTP {d})", .{ what, resp.status });
        }
    }

    fn request(g: *Gateway, method: [:0]const u8, path: []const u8, body: ?[]const u8) ?Response {
        return g.requestEx(method, path, body, null);
    }

    /// `mime`: corpo multipart (envio de arquivos) no lugar do JSON.
    fn requestEx(g: *Gateway, method: [:0]const u8, path: []const u8, body: ?[]const u8, mime: ?*c.curl_mime) ?Response {
        const h = g.rest orelse return null;
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrintSentinel(&url_buf, "{s}{s}", .{ api, path }, 0) catch return null;
        var auth_buf: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_buf);
        const auth = std.fmt.bufPrintSentinel(&auth_buf, "Authorization: {s}", .{g.token}, 0) catch return null;
        var props_buf: [1024]u8 = undefined;
        const props = superProperties(&props_buf);
        var super_buf: [1200]u8 = undefined;
        const super_line = std.fmt.bufPrintSentinel(&super_buf, "X-Super-Properties: {s}", .{props}, 0) catch return null;

        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            // O cliente oficial só dispara a próxima requisição quando o
            // balde do rate limit libera; fazemos o mesmo.
            const now = nowMs();
            const until = @max(g.rate_until, g.global_until);
            if (until > now) {
                // Bloqueio longo: insistir só aumenta a pena. Falha na hora e
                // quem pediu fica sabendo (a fila não trava por minutos).
                if (until - now > long_block_ms) {
                    g.noticeBlocked(until);
                    return null;
                }
                g.sleepServing(@intCast(until - now));
                if (g.stopping) return null;
            }

            var headers: ?*c.struct_curl_slist = null;
            headers = c.curl_slist_append(headers, auth.ptr);
            headers = c.curl_slist_append(headers, super_line.ptr);
            if (mime == null) headers = c.curl_slist_append(headers, "Content-Type: application/json");
            headers = c.curl_slist_append(headers, "Origin: https://discord.com");
            headers = c.curl_slist_append(headers, "Referer: https://discord.com/channels/@me");
            headers = c.curl_slist_append(headers, "Sec-Fetch-Dest: empty");
            headers = c.curl_slist_append(headers, "Sec-Fetch-Mode: cors");
            headers = c.curl_slist_append(headers, "Sec-Fetch-Site: same-origin");
            headers = c.curl_slist_append(headers, "X-Debug-Options: bugReporterEnabled");
            headers = c.curl_slist_append(headers, "X-Discord-Locale: en-US");
            headers = c.curl_slist_append(headers, "Accept-Language: en-US,en;q=0.9");
            defer c.curl_slist_free_all(headers);
            var rate: RateInfo = .{};
            var resp: Response = .{ .status = 0, .body = .empty };
            c.curl_easy_reset(h);
            _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, headers);
            _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, web_user_agent.ptr);
            _ = c.curl_easy_setopt(h, c.CURLOPT_CUSTOMREQUEST, method.ptr);
            useProxy(h);
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &resp.body);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERFUNCTION, headerCb);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERDATA, &rate);
            _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, if (mime != null) 180 else 20));
            _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
            g.abortable(h);
            if (mime) |mp| {
                _ = c.curl_easy_setopt(h, c.CURLOPT_MIMEPOST, mp);
            } else if (body) |b| {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, b.ptr);
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
            } else if (std.mem.eql(u8, method, "PUT") or std.mem.eql(u8, method, "POST")) {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, "");
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
            }
            if (c.curl_easy_perform(h) != c.CURLE_OK) {
                resp.body.deinit(alloc);
                g.notice("sem conexão com a API do Discord", "no connection to the Discord API", .{});
                return null;
            }
            _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &resp.status);
            applyRate(g, rate);
            if (resp.status == 429) {
                // Rate limit: espera o que o Discord pediu e tenta de novo.
                var wait_ms: u32 = rate.retry_after_ms orelse 1000;
                if (std.json.parseFromSlice(Value, alloc, resp.body.items, .{})) |parsed| {
                    defer parsed.deinit();
                    if (j.get(parsed.value, "retry_after")) |ra| switch (ra) {
                        .float => |f| wait_ms = floatSecondsToMs(f) orelse wait_ms,
                        .integer => |i| wait_ms = floatSecondsToMs(@floatFromInt(i)) orelse wait_ms,
                        else => {},
                    };
                    if (j.get(parsed.value, "global")) |gv| {
                        if (gv == .bool and gv.bool) rate.global = true;
                    }
                } else |_| {}
                const retry_at = nowMs() + @as(i64, wait_ms) + 100;
                if (rate.global) {
                    g.global_until = @max(g.global_until, retry_at);
                } else {
                    g.rate_until = @max(g.rate_until, retry_at);
                }
                resp.body.deinit(alloc);
                if (wait_ms > long_block_ms) {
                    g.noticeBlocked(retry_at);
                    return null;
                }
                g.notice("o Discord pediu calma: esperando {d} ms", "Discord asked us to slow down: waiting {d} ms", .{wait_ms});
                g.sleepServing(wait_ms + 100);
                if (g.stopping) return null;
                continue;
            }
            // 5xx passageiro: o cliente oficial tenta de novo só em leituras.
            if (resp.status >= 500 and std.mem.eql(u8, method, "GET") and attempt < 2) {
                resp.body.deinit(alloc);
                g.sleepServing(500 * (@as(u32, attempt) + 1));
                continue;
            }
            return resp;
        }
        return null;
    }

    /// Espera de rate limit a partir da qual o comando falha em vez de esperar.
    const long_block_ms = 30_000;

    fn noticeBlocked(g: *Gateway, until: i64) void {
        if (g.block_noticed == until) return;
        g.block_noticed = until;
        const mins = @max(@divFloor(until - nowMs() + 30_000, 60_000), 1);
        g.notice("o Discord bloqueou os pedidos por {d} min; tentando de novo depois disso", "Discord blocked requests for {d} min; will try again after that", .{mins});
    }

    fn freeCommand(cmd: ev.Command) void {
        switch (cmd) {
            .set_note => |n| alloc.free(n.text),
            .send_message => |m| {
                alloc.free(m.content);
                for (m.files) |f| alloc.free(f);
                if (m.files.len > 0) alloc.free(m.files);
            },
            .edit_message => |m| alloc.free(m.content),
            .create_thread => |m| alloc.free(m.name),
            .create_post => |m| {
                alloc.free(m.name);
                alloc.free(m.content);
                alloc.free(m.tags);
            },
            else => {},
        }
    }

    /// Op 4 do gateway principal: entra/sai do canal de voz.
    fn sendVoiceState(g: *Gateway, channel: ?Id) void {
        var b: [192]u8 = undefined;
        const ch = if (channel) |cid| std.fmt.bufPrint(&b, "\"{d}\"", .{cid}) catch return else "null";
        var out: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&out, "{{\"op\":4,\"d\":{{\"guild_id\":\"{d}\",\"channel_id\":{s},\"self_mute\":{s},\"self_deaf\":{s}}}}}", .{
            g.voice_guild,
            ch,
            if (g.voice_mute) "true" else "false",
            if (g.voice_deaf) "true" else "false",
        }) catch return;
        std.log.debug("voz: op4 canal={s}", .{ch});
        g.send(p);
    }

    /// O gateway de voz só abre quando já temos endpoint, token e session_id.
    fn tryStartVoice(g: *Gateway) void {
        if (g.voice != null or g.voice_channel == 0 or g.me == 0) return;
        if (g.voice_endpoint_len == 0 or g.voice_token_len == 0 or g.voice_session_len == 0) return;
        const vc = alloc.create(voice_mod.Voice) catch return;
        vc.* = voice_mod.Voice.init(
            g.sink,
            g.voice_guild,
            g.voice_channel,
            g.me,
            g.voice_endpoint[0..g.voice_endpoint_len],
            g.voice_token[0..g.voice_token_len],
            g.voice_session[0..g.voice_session_len],
            g.voice_mute,
            g.voice_deaf,
        );
        var it = g.voice_volumes.iterator();
        while (it.next()) |kv| vc.setVolume(kv.key_ptr.*, kv.value_ptr.*);
        vc.start() catch {
            vc.deinit();
            alloc.destroy(vc);
            g.emit(.{ .voice_status = .{ .status = .disconnected, .channel = g.voice_channel } });
            return;
        };
        g.voice = vc;
        g.voice_wait_until = 0;
    }

    /// Para a thread de voz mas guarda o que precisa para abrir de novo.
    fn killVoice(g: *Gateway) void {
        if (g.voice) |vc| {
            vc.stop();
            vc.deinit();
            alloc.destroy(vc);
            g.voice = null;
        }
    }

    /// Recolhe a thread de voz que terminou sozinha. Movido (4014): espera
    /// o servidor novo por alguns segundos; se não vier, tenta de novo com o
    /// que tem e, na falha, avisa que caiu.
    fn voiceTick(g: *Gateway) void {
        if (g.voice) |vc| switch (vc.ended.load(.acquire)) {
            .running => return,
            .moved => {
                g.killVoice();
                if (g.voice_wait_until == 0) g.voice_wait_until = nowMs() + 5000;
            },
            .fatal, .stopped => {
                g.killVoice();
                g.voice_wait_until = 0;
            },
        };
        if (g.voice_wait_until != 0 and nowMs() >= g.voice_wait_until) {
            g.voice_wait_until = 0;
            if (g.voice == null and g.voice_channel != 0) {
                if (g.voice_endpoint_len > 0 and g.voice_token_len > 0) {
                    g.tryStartVoice();
                } else g.emit(.{ .voice_status = .{ .status = .disconnected, .channel = g.voice_channel } });
            }
        }
    }

    fn stopVoice(g: *Gateway) void {
        g.killVoice();
        g.voice_wait_until = 0;
        std.crypto.secureZero(u8, &g.voice_token);
        std.crypto.secureZero(u8, &g.voice_session);
        g.voice_token_len = 0;
        g.voice_session_len = 0;
        g.voice_endpoint_len = 0;
    }

    fn execute(g: *Gateway, cmd: ev.Command) void {
        if (!g.ws_ready and usesGateway(cmd)) {
            g.held.append(alloc, cmd) catch {};
            return;
        }
        defer freeCommand(cmd);
        var path_buf: [256]u8 = undefined;
        switch (cmd) {
            .fetch_history => |ch| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages?limit=50", .{ch}) catch return;
                var resp = g.request("GET", path, null) orelse return g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
                defer resp.body.deinit(alloc);
                if (resp.status != 200) {
                    if (resp.status == 403) {
                        g.notice("sem permissão para ler esse canal", "you don't have permission to read this channel", .{});
                    } else if (resp.status != 404) {
                        g.noticeHttp(i18n.tr("não consegui carregar o histórico", "couldn't load the history"), &resp);
                    }
                    return g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
                }
                g.history(ch, resp.body.items, false) catch g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
            },
            .fetch_older => |o| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages?before={d}&limit=50", .{ o.channel, o.before }) catch return;
                // Falha não é "acabou o histórico": `more` fica ligado (ver Store).
                const none: ev.Event = .{ .history = .{ .channel = o.channel, .messages = &.{}, .older = true } };
                var resp = g.request("GET", path, null) orelse return g.emit(none);
                defer resp.body.deinit(alloc);
                if (resp.status != 200) return g.emit(none);
                g.history(o.channel, resp.body.items, true) catch g.emit(none);
            },
            .send_message => |m| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"content\":") catch return;
                j.writeString(&b, alloc, m.content) catch return;
                b.print(alloc, ",\"nonce\":\"{d}\",\"tts\":false", .{m.nonce}) catch return;
                if (m.reply_to != 0) b.print(alloc, ",\"message_reference\":{{\"message_id\":\"{d}\"}}", .{m.reply_to}) catch return;
                if (m.files.len > 0) {
                    // Como o cliente oficial: payload_json + files[n].
                    b.appendSlice(alloc, ",\"attachments\":[") catch return;
                    for (m.files, 0..) |f, i| {
                        if (i > 0) b.append(alloc, ',') catch return;
                        b.print(alloc, "{{\"id\":{d},\"filename\":", .{i}) catch return;
                        j.writeString(&b, alloc, std.fs.path.basename(f)) catch return;
                        b.append(alloc, '}') catch return;
                    }
                    b.append(alloc, ']') catch return;
                }
                b.append(alloc, '}') catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages", .{m.channel}) catch return;
                var mime: ?*c.curl_mime = null;
                defer if (mime) |mp| c.curl_mime_free(mp);
                if (m.files.len > 0) {
                    mime = c.curl_mime_init(g.rest);
                    const mp = mime orelse return;
                    const pj = c.curl_mime_addpart(mp);
                    _ = c.curl_mime_name(pj, "payload_json");
                    _ = c.curl_mime_data(pj, b.items.ptr, b.items.len);
                    _ = c.curl_mime_type(pj, "application/json");
                    for (m.files, 0..) |f, i| {
                        var nbuf: [32]u8 = undefined;
                        const field = std.fmt.bufPrintSentinel(&nbuf, "files[{d}]", .{i}, 0) catch return;
                        const fp = c.curl_mime_addpart(mp);
                        _ = c.curl_mime_name(fp, field.ptr);
                        _ = c.curl_mime_filedata(fp, f.ptr);
                    }
                }
                const failed: ev.Event = .{ .send_failed = .{ .channel = m.channel, .nonce = m.nonce } };
                var resp = g.requestEx("POST", path, if (mime == null) b.items else null, mime) orelse return g.emit(failed);
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.emit(failed);
                if (resp.status == 413) return g.notice("arquivo grande demais para o Discord (limite de 10 MB sem Nitro)", "file too large for Discord (10 MB limit without Nitro)", .{});
                if (resp.status >= 300) return g.noticeHttp(i18n.tr("não foi possível enviar", "couldn't send"), &resp);
                // A imagem colada era um arquivo temporário nosso: já foi.
                for (m.files) |f| if (types.isPastedFile(f)) {
                    _ = c.unlink(f.ptr);
                };
            },
            .edit_message => |m| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"content\":") catch return;
                j.writeString(&b, alloc, m.content) catch return;
                b.append(alloc, '}') catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}", .{ m.channel, m.id }) catch return;
                var resp = g.request("PATCH", path, b.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não foi possível editar", "couldn't edit"), &resp);
            },
            .delete_message => |m| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}", .{ m.channel, m.id }) catch return;
                var resp = g.request("DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não foi possível apagar", "couldn't delete"), &resp);
            },
            .react => |r| {
                var enc: [64]u8 = undefined;
                // Personalizado: a API pede `nome:id` (quem vale é o ID).
                var name_buf: [48]u8 = undefined;
                const label = std.mem.trim(u8, r.emoji.text(), ":");
                const emoji = if (r.emoji.custom != 0) std.fmt.bufPrint(&name_buf, "{s}:{d}", .{ label, r.emoji.custom }) catch return else r.emoji.text();
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}/reactions/{s}/@me", .{ r.channel, r.id, j.urlEncode(&enc, emoji) }) catch return;
                var resp = g.request(if (r.add) "PUT" else "DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300 and resp.status != 404) g.noticeHttp(i18n.tr("não foi possível reagir", "couldn't react"), &resp);
            },
            .typing => |ch| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/typing", .{ch}) catch return;
                var resp = g.request("POST", path, null) orelse return;
                resp.body.deinit(alloc);
            },
            .subscribe_guild => |sg| {
                if (sg.guild == g.sub_guild and sg.channel == g.sub_channel and sg.thread == g.sub_thread) return;
                g.subscribe(sg.guild, sg.channel, sg.thread);
            },
            .relationship => |r| {
                const path = std.fmt.bufPrint(&path_buf, "/users/@me/relationships/{d}", .{r.user}) catch return;
                var resp = g.request(if (r.accept) "PUT" else "DELETE", path, if (r.accept) "{}" else null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não deu para mudar a amizade", "couldn't update the friendship"), &resp);
            },
            .fetch_profile => |fp| {
                const path = if (fp.guild != 0)
                    std.fmt.bufPrint(&path_buf, "/users/{d}/profile?with_mutual_guilds=true&with_mutual_friends=true&with_mutual_friends_count=true&guild_id={d}", .{ fp.user, fp.guild }) catch return
                else
                    std.fmt.bufPrint(&path_buf, "/users/{d}/profile?with_mutual_guilds=true&with_mutual_friends=true&with_mutual_friends_count=true", .{fp.user}) catch return;
                var resp = g.request("GET", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status == 200) g.onProfile(fp.user, fp.guild, resp.body.items);
                // A nota (404 = não tem). Só a nossa, ninguém mais vê.
                if (fp.user == g.me) return;
                const npath = std.fmt.bufPrint(&path_buf, "/users/@me/notes/{d}", .{fp.user}) catch return;
                var nresp = g.request("GET", npath, null) orelse return;
                defer nresp.body.deinit(alloc);
                if (nresp.status != 200) return;
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const nv = std.json.parseFromSliceLeaky(Value, arena.allocator(), nresp.body.items, .{}) catch return;
                g.emit(.{ .note = .{ .user = fp.user, .text = dupeOpt(j.str(j.get(nv, "note")) orelse "") catch return } });
            },
            .set_note => |n| {
                const path = std.fmt.bufPrint(&path_buf, "/users/@me/notes/{d}", .{n.user}) catch return;
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(alloc);
                out.print(alloc, "{{\"note\":{f}}}", .{std.json.fmt(n.text, .{})}) catch return;
                var resp = g.request("PUT", path, out.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não deu para salvar a nota", "couldn't save the note"), &resp);
            },
            .move_member => |mm| {
                const path = std.fmt.bufPrint(&path_buf, "/guilds/{d}/members/{d}", .{ mm.guild, mm.user }) catch return;
                var b: [64]u8 = undefined;
                const body = if (mm.channel) |ch| std.fmt.bufPrint(&b, "{{\"channel_id\":\"{d}\"}}", .{ch}) catch return else "{\"channel_id\":null}";
                var resp = g.request("PATCH", path, body) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não deu para mover da call", "couldn't move the member"), &resp);
            },
            .fetch_app => |app| {
                const path = std.fmt.bufPrint(&path_buf, "/applications/{d}/rpc", .{app}) catch return;
                var resp = g.request("GET", path, null) orelse return;
                defer resp.body.deinit(alloc);
                var icon: []const u8 = "";
                if (resp.status == 200) {
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    if (std.json.parseFromSliceLeaky(Value, arena.allocator(), resp.body.items, .{})) |v| {
                        icon = dupeOpt(j.str(j.get(v, "icon")) orelse "") catch "";
                    } else |_| {}
                }
                // Vazio também: não pergunta de novo.
                g.emit(.{ .app_icon = .{ .app = app, .icon = icon } });
            },
            .set_status => |st| {
                g.status = st;
                var buf: [128]u8 = undefined;
                const payload = std.fmt.bufPrint(&buf, "{{\"op\":3,\"d\":{{\"status\":\"{s}\",\"since\":0,\"activities\":[],\"afk\":false}}}}", .{statusName(st)}) catch return;
                g.send(payload);
            },
            .member_role => |mr| {
                const path = std.fmt.bufPrint(&path_buf, "/guilds/{d}/members/{d}/roles/{d}", .{ mr.guild, mr.user, mr.role }) catch return;
                var resp = g.request(if (mr.add) "PUT" else "DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp(i18n.tr("não deu para mudar o cargo", "couldn't change the role"), &resp);
            },
            .create_dm => |user| {
                var b: [64]u8 = undefined;
                const body = std.fmt.bufPrint(&b, "{{\"recipients\":[\"{d}\"]}}", .{user}) catch return;
                var resp = g.request("POST", "/users/@me/channels", body) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) return g.noticeHttp(i18n.tr("não deu para abrir a conversa", "couldn't open the conversation"), &resp);
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const v = std.json.parseFromSliceLeaky(Value, arena.allocator(), resp.body.items, .{}) catch return;
                if (g.channelValue(v, 0) catch null) |ch| g.emit(.{ .channel_upsert = ch });
            },
            .fetch_mentions => {
                // Só leitura: as mesmas menções da caixa de entrada do cliente oficial.
                const none: ev.Event = .{ .recent_mentions = &.{} };
                var resp = g.request("GET", "/users/@me/mentions?limit=25", null) orelse return g.emit(none);
                defer resp.body.deinit(alloc);
                if (resp.status != 200) {
                    g.noticeHttp(i18n.tr("não consegui carregar as menções", "couldn't load the mentions"), &resp);
                    return g.emit(none);
                }
                g.mentionList(resp.body.items) catch g.emit(none);
            },
            .fetch_threads => |ft| {
                const failed: ev.Event = .{ .threads_page = .{ .channel = ft.channel, .archived = ft.archived, .failed = true } };
                var path_big: [320]u8 = undefined;
                var iso: [32]u8 = undefined;
                const path = if (ft.archived)
                    (if (ft.before != 0)
                        std.fmt.bufPrint(&path_big, "/channels/{d}/threads/archived/public?limit=50&before={s}", .{ ft.channel, thread_json.isoFromUnix(&iso, ft.before) }) catch return
                    else
                        std.fmt.bufPrint(&path_big, "/channels/{d}/threads/archived/public?limit=50", .{ft.channel}) catch return)
                else
                    std.fmt.bufPrint(&path_big, "/channels/{d}/threads/search?archived=false&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset={d}", .{ ft.channel, ft.offset }) catch return;
                var resp = g.request("GET", path, null) orelse return g.emit(failed);
                defer resp.body.deinit(alloc);
                if (resp.status == 200) return g.emitThreadsPage(ft.channel, ft.guild, ft.archived, resp.body.items, 0) catch g.emit(failed);
                // A busca não respondeu (202 = índice ainda não pronto): as ativas
                // do servidor, filtradas, são o plano B (só tem uma página).
                if (ft.archived or ft.offset != 0) {
                    g.noticeHttp(i18n.tr("não consegui carregar as threads", "couldn't load the threads"), &resp);
                    return g.emit(failed);
                }
                const gpath = std.fmt.bufPrint(&path_big, "/guilds/{d}/threads/active", .{ft.guild}) catch return g.emit(failed);
                var gresp = g.request("GET", gpath, null) orelse return g.emit(failed);
                defer gresp.body.deinit(alloc);
                if (gresp.status != 200) {
                    g.noticeHttp(i18n.tr("não consegui carregar as threads", "couldn't load the threads"), &gresp);
                    return g.emit(failed);
                }
                g.emitThreadsPage(ft.channel, ft.guild, false, gresp.body.items, ft.channel) catch g.emit(failed);
            },
            .create_thread => |ct| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"name\":") catch return;
                j.writeString(&b, alloc, ct.name) catch return;
                b.appendSlice(alloc, ",\"auto_archive_duration\":1440}") catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}/threads", .{ ct.channel, ct.message }) catch return;
                var resp = g.request("POST", path, b.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) return g.noticeHttp(i18n.tr("não deu para criar a thread", "couldn't create the thread"), &resp);
                g.threadCreated(resp.body.items);
            },
            .create_post => |cp| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"name\":") catch return;
                j.writeString(&b, alloc, cp.name) catch return;
                b.appendSlice(alloc, ",\"auto_archive_duration\":4320,\"applied_tags\":[") catch return;
                for (cp.tags, 0..) |tag, i| b.print(alloc, "{s}\"{d}\"", .{ if (i > 0) "," else "", tag }) catch return;
                b.appendSlice(alloc, "],\"message\":{\"content\":") catch return;
                j.writeString(&b, alloc, cp.content) catch return;
                b.appendSlice(alloc, "}}") catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/threads", .{cp.forum}) catch return;
                var resp = g.request("POST", path, b.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) return g.noticeHttp(i18n.tr("não deu para publicar o post", "couldn't publish the post"), &resp);
                g.threadCreated(resp.body.items);
            },
            .join_thread => |jt| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/thread-members/@me", .{jt.thread}) catch return;
                var resp = g.request(if (jt.join) "PUT" else "DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) return g.noticeHttp(if (jt.join) i18n.tr("não deu para entrar na thread", "couldn't join the thread") else i18n.tr("não deu para sair da thread", "couldn't leave the thread"), &resp);
                g.emit(.{ .thread_joined = .{ .thread = jt.thread, .joined = jt.join } });
            },
            .fetch_thread_members => |tid| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/thread-members?with_member=true&limit=100", .{tid}) catch return;
                var resp = g.request("GET", path, null) orelse return;
                defer resp.body.deinit(alloc);
                // Sem resposta, a lista de membros continua sendo a do canal pai.
                if (resp.status != 200) return;
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const v = std.json.parseFromSliceLeaky(Value, arena.allocator(), resp.body.items, .{}) catch return;
                g.emitThreadMembers(tid, j.array(v));
            },
            .join_voice => |v| {
                if (g.voice != null) g.stopVoice();
                g.voice_guild = v.guild;
                g.voice_mute = v.mute;
                g.voice_deaf = v.deaf;
                if (v.channel) |ch| {
                    g.voice_channel = ch;
                    g.voice_session_len = 0;
                    @memset(&g.voice_session, 0);
                    g.voice_endpoint_len = 0;
                    g.voice_token_len = 0;
                    if (g.me != 0) g.sendVoiceState(ch);
                } else {
                    if (g.me != 0) g.sendVoiceState(null);
                    g.stopVoice();
                    g.voice_channel = 0;
                }
            },
            .voice_flags => |f| {
                g.voice_mute = f.mute;
                g.voice_deaf = f.deaf;
                if (g.voice) |vc| vc.setFlags(f.mute, f.deaf);
                if (g.voice_channel != 0) g.sendVoiceState(g.voice_channel);
            },
            .voice_volume => |v| {
                g.voice_volumes.put(alloc, v.user, std.math.clamp(v.volume, 0, 2)) catch {};
                if (g.voice) |vc| vc.setVolume(v.user, v.volume);
            },
            .shutdown => {},
        }
    }

    /// Resposta de "criar thread" ou "novo post": a thread e o pedido de abrir.
    fn threadCreated(g: *Gateway, body: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const v = std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{}) catch return;
        const ch = (g.channelValue(v, 0) catch null) orelse return;
        const id = ch.id;
        g.emit(.{ .channel_upsert = ch });
        g.emit(.{ .thread_open = id });
    }

    /// GET /users/@me/mentions: lista de mensagens (da mais nova para a mais
    /// antiga), cada uma com o `channel_id` de onde veio.
    fn mentionList(g: *Gateway, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{});
        var list: std.ArrayList(types.Message) = .empty;
        for (j.array(root)) |m| {
            g.upsertUsers(m);
            if (try g.message(m)) |msg| try list.append(alloc, msg);
        }
        g.emit(.{ .recent_mentions = try list.toOwnedSlice(alloc) });
    }

    fn history(g: *Gateway, ch: Id, body: []const u8, older: bool) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(Value, arena.allocator(), body, .{});
        const items = j.array(root);
        var list: std.ArrayList(types.Message) = .empty;
        // A API manda do mais novo para o mais antigo.
        var i = items.len;
        while (i > 0) {
            i -= 1;
            g.upsertUsers(items[i]);
            g.messageThread(items[i]);
            if (try g.message(items[i])) |m| try list.append(alloc, m);
        }
        const msgs = try list.toOwnedSlice(alloc);
        // Veio a página cheia: pode ter mais antigas.
        g.emit(.{ .history = .{ .channel = ch, .messages = msgs, .older = older, .more = items.len >= 50 } });
        // Reações já existentes.
        for (items) |m| {
            const mid = j.id(j.get(m, "id")) orelse continue;
            for (j.array(j.get(m, "reactions"))) |rv| {
                var r = emojiOf(j.get(rv, "emoji") orelse continue);
                r.count = @intCast(std.math.clamp(j.int(j.get(rv, "count")) orelse 1, 0, 65535));
                r.me = if (j.get(rv, "me")) |me| me == .bool and me.bool else false;
                g.emit(.{ .reaction_set = .{ .channel = ch, .id = mid, .reaction = r } });
            }
        }
    }
};

/// Procura o token, nesta ordem:
///   1. variável LARPER_TOKEN
///   2. chaveiro do sistema: `secret-tool lookup service larpercord`
///   3. ~/.config/larpercord/token (precisa ter permissão 600)
/// Retorna null se não houver (o app usa o modo demonstração).
pub fn loadToken() ?[:0]u8 {
    return envToken() orelse loadSavedToken();
}

/// Só a variável LARPER_TOKEN (nunca é guardada em lugar nenhum).
pub fn envToken() ?[:0]u8 {
    const t = c.SDL_getenv("LARPER_TOKEN") orelse return null;
    const s = std.mem.trim(u8, std.mem.span(t), " \n\r\t");
    return if (s.len > 20) alloc.dupeSentinel(u8, s, 0) catch null else null;
}

/// Só o token guardado na entrada antiga (chaveiro, depois o arquivo).
pub fn loadSavedToken() ?[:0]u8 {
    if (c.popen("secret-tool lookup service larpercord 2>/dev/null", "r")) |f| {
        var buf: [256]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, f);
        _ = c.pclose(f);
        defer std.crypto.secureZero(u8, &buf);
        const s = std.mem.trim(u8, buf[0..n], " \n\r\t");
        if (s.len > 20) return alloc.dupeSentinel(u8, s, 0) catch null;
    }
    const home = c.SDL_getenv("HOME") orelse return null;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/.config/larpercord/token", .{std.mem.span(home)}, 0) catch return null;
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return null;
    if (st.st_mode & 0o077 != 0) {
        std.log.warn("~/.config/larpercord/token está legível por outros usuários; rode: chmod 600 ~/.config/larpercord/token", .{});
        return null;
    }
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer {
        std.crypto.secureZero(u8, @as([*]u8, @ptrCast(data))[0..size]);
        c.SDL_free(data);
    }
    const s = std.mem.trim(u8, @as([*]const u8, @ptrCast(data))[0..size], " \n\r\t");
    if (s.len <= 20) return null;
    return alloc.dupeSentinel(u8, s, 0) catch null;
}

fn tokenFilePath(buf: []u8) ?[:0]const u8 {
    const home = c.SDL_getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/larpercord/token", .{std.mem.span(home)}, 0) catch null;
}

/// Guarda o token para os próximos inícios: no chaveiro do sistema
/// (`secret-tool`, pela entrada padrão, então ele não aparece no `ps`) ou,
/// sem chaveiro, em ~/.config/larpercord/token com permissão 600.
/// Retorna onde guardou.
pub fn saveToken(token: []const u8) enum { keyring, file, failed } {
    if (c.popen("secret-tool store --label=larperCord service larpercord 2>/dev/null", "w")) |f| {
        const wrote = c.fwrite(token.ptr, 1, token.len, f);
        if (c.pclose(f) == 0 and wrote == token.len) {
            // Não deixa uma cópia velha no arquivo.
            var pbuf: [512]u8 = undefined;
            if (tokenFilePath(&pbuf)) |p| _ = c.unlink(p.ptr);
            return .keyring;
        }
    }
    var pbuf: [512]u8 = undefined;
    const path = tokenFilePath(&pbuf) orelse return .failed;
    return if (@import("../platform/fsutil.zig").writePrivate(path, token)) .file else .failed;
}

/// "Sair": apaga o token do chaveiro e do arquivo.
pub fn forgetToken() void {
    if (c.popen("secret-tool clear service larpercord 2>/dev/null", "r")) |f| _ = c.pclose(f);
    var pbuf: [512]u8 = undefined;
    if (tokenFilePath(&pbuf)) |p| _ = c.unlink(p.ptr);
}
