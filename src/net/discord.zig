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
    voice_warned: bool = false,
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

    pub fn start(g: *Gateway) !void {
        g.thread = c.SDL_CreateThread(threadMain, "discord", g) orelse return error.SdlThread;
    }

    pub fn stop(g: *Gateway) void {
        g.commands.push(.shutdown);
        if (g.thread) |t| c.SDL_WaitThread(t, null);
        std.crypto.secureZero(u8, g.token);
        alloc.free(g.token);
        @memset(&g.session_id, 0);
        @memset(&g.resume_base, 0);
        for (g.pending.items) |cmd| freeCommand(cmd);
        g.pending.deinit(alloc);
        g.zout.deinit(alloc);
    }

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

    fn notice(g: *Gateway, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
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
            if (g.ws) |h| {
                c.curl_easy_cleanup(h);
                g.ws = null;
            }
            if (g.stopping) break;
            switch (result) {
                .fatal => {
                    g.emit(.{ .status = .failed });
                    // Não há mais para onde mandar os comandos pendentes.
                    for (g.pending.items) |cmd| freeCommand(cmd);
                    g.pending.clearRetainingCapacity();
                    // Fica só atendendo o encerramento.
                    var cmds: std.ArrayList(ev.Command) = .empty;
                    while (!g.stopping) {
                        g.commands.waitDrain(&cmds, 1000);
                        for (cmds.items) |cmd| if (cmd == .shutdown) {
                            g.stopping = true;
                        } else freeCommand(cmd);
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
                    g.sleepServing(1000);
                    backoff = 2000;
                },
                .new_session => {
                    // Sessão inválida/expirada: o Discord manda esperar de
                    // 1 a 5 segundos antes de abrir uma nova.
                    g.clearSession();
                    g.emit(.{ .status = .reconnecting });
                    var prng = std.Random.DefaultPrng.init(@bitCast(nowMs()));
                    g.sleepServing(1000 + prng.random().uintLessThan(u32, 4000));
                    backoff = 2000;
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
            // Uma espera de rate limit não pode deixar o gateway sem
            // heartbeat. Se o ACK anterior ainda não chegou, não manda outro.
            if (g.ws != null and g.acked and g.next_hb != std.math.maxInt(i64) and nowMs() >= g.next_hb) {
                g.heartbeat();
            }
        }
    }

    /// Executa o que ficou na fila durante a reconexão/rate limit.
    fn runPending(g: *Gateway) ?End {
        while (g.pending.items.len > 0) {
            const cmd = g.pending.orderedRemove(0);
            if (cmd == .shutdown) {
                g.stopping = true;
                freeCommand(cmd);
                return .reconnect;
            }
            g.execute(cmd);
            if (g.stopping) return .reconnect;
        }
        return null;
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
        if (c.curl_easy_perform(h) != c.CURLE_OK) return .retry;
        var sock: c.curl_socket_t = -1;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        // `seq` e `session_id` sobrevivem à queda: é isso que permite o RESUME.
        g.acked = true;
        g.next_hb = std.math.maxInt(i64);
        g.hb_sent_at = 0;
        g.frame.clearRetainingCapacity();
        g.zout.clearRetainingCapacity();

        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            // Primeiro o que ficou esperando a conexão voltar.
            if (g.runPending()) |e| return e;
            // Depois os comandos novos do app (REST).
            g.commands.drain(&cmds);
            for (cmds.items) |cmd| {
                if (cmd == .shutdown) {
                    g.stopping = true;
                    return .reconnect;
                }
                g.execute(cmd);
            }
            cmds.clearRetainingCapacity();

            // Espera o socket ou o próximo heartbeat (no máximo 50 ms, para
            // atender os comandos rápido).
            const now = nowMs();
            const wait: c_int = @intCast(std.math.clamp(g.next_hb - now, 0, 50));
            var pfd: c.struct_pollfd = .{ .fd = sock, .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&pfd, 1, wait);

            // Lê tudo que chegou.
            while (true) {
                var got: usize = 0;
                var meta: [*c]const c.struct_curl_ws_frame = null;
                const rc = c.curl_ws_recv(h, &buf, buf.len, &got, &meta);
                if (rc == c.CURLE_AGAIN) break;
                if (rc != c.CURLE_OK) return .retry;
                if (meta == null) break;
                if (meta.*.flags & c.CURLWS_CLOSE != 0) {
                    const code: u16 = if (got >= 2) (@as(u16, buf[0]) << 8) | buf[1] else 0;
                    return g.onClose(code);
                }
                // Ping/pong são tratados pelo libcurl; não são payload do gateway.
                if (meta.*.flags & (c.CURLWS_PING | c.CURLWS_PONG) != 0) continue;
                if (got > 0) g.frame.appendSlice(alloc, buf[0..got]) catch return .retry;
                if (meta.*.bytesleft == 0 and meta.*.flags & c.CURLWS_CONT == 0) {
                    // O Discord fecha cada payload com 00 00 FF FF. Se ainda
                    // não veio, guarda o pedaço e espera o resto.
                    if (g.inflateFrame()) |e| return e;
                }
            }

            if (nowMs() >= g.next_hb) {
                if (!g.acked) return .reconnect; // conexão "zumbi"
                g.heartbeat();
            }
        }
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
                g.notice("não consegui descomprimir o gateway (zlib {d})", .{rc});
                return .retry;
            }
            if (g.z.avail_in == 0 and produced < out.len) break;
        }
        g.frame.clearRetainingCapacity();
        if (g.zout.items.len == 0) return null;
        return g.onPayload(g.zout.items);
    }

    fn onClose(g: *Gateway, code: u16) End {
        switch (code) {
            4004 => {
                g.notice("token inválido ou expirado (4004). Atualize o token e reinicie.", .{});
                return .fatal;
            },
            4010...4014 => {
                g.notice("o Discord recusou a conexão (código {d}).", .{code});
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
        var sent: usize = 0;
        _ = c.curl_ws_send(h, payload.ptr, payload.len, &sent, 0, c.CURLWS_TEXT);
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
        out.appendSlice(alloc, ",\"presence\":{\"activities\":[],\"status\":\"online\",\"afk\":false,\"since\":0},\"compress\":false,\"client_state\":") catch return;
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

    fn roleFor(uid: Id) u8 {
        return @intCast((uid >> 22) % 8);
    }

    fn dispatch(g: *Gateway, t: []const u8, d: Value, arena: std.mem.Allocator) !void {
        if (std.mem.eql(u8, t, "READY")) return g.onReady(d, arena);
        if (std.mem.eql(u8, t, "RESUMED")) {
            // O gateway reenviou o que perdemos; o estado local continua válido.
            g.emit(.{ .status = .ready });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_CREATE")) {
            g.upsertUsers(d);
            if (try g.message(d)) |m| g.emit(.{ .message_create = m });
            return;
        }
        if (std.mem.eql(u8, t, "MESSAGE_UPDATE")) {
            const content = j.str(j.get(d, "content")) orelse return;
            g.emit(.{ .message_update = .{
                .channel = j.id(j.get(d, "channel_id")) orelse return,
                .id = j.id(j.get(d, "id")) orelse return,
                .content = try j.simplifyContent(alloc, content),
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
            if (j.id(j.get(d, "id"))) |id| g.emit(.{ .guild_delete = id });
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_UPDATE")) {
            const gid = j.id(j.get(d, "id")) orelse return;
            const name = guildName(d);
            // Reaproveita o merge do GUILD_CREATE para atualizar o nome.
            g.emit(.{ .guild_create = .{
                .guild = .{
                    .id = gid,
                    .name = dupe(name),
                    .acronym = try j.acronym(alloc, name),
                    .color = @intCast((gid >> 22) % 8),
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
        if (std.mem.eql(u8, t, "CHANNEL_DELETE")) {
            if (j.id(j.get(d, "id"))) |id| g.emit(.{ .channel_delete = id });
            return;
        }
        if (std.mem.eql(u8, t, "GUILD_MEMBER_UPDATE") or std.mem.eql(u8, t, "USER_UPDATE")) {
            const u = j.get(d, "user") orelse d;
            const uid = j.id(j.get(u, "id")) orelse return;
            g.emit(.{ .user_update = .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = .offline } });
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
            g.emit(.{ .voice_state = .{ .channel = j.id(j.get(d, "channel_id")), .user = user } });
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
            if (user == g.me) return; // a nossa já foi aplicada na hora
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
            if (j.get(d, "member")) |m| if (j.get(m, "user")) |u| g.upsert(u);
            g.emit(.{ .typing_start = .{ .channel = j.id(j.get(d, "channel_id")) orelse return, .user = user } });
            return;
        }
        if (std.mem.eql(u8, t, "PRESENCE_UPDATE")) {
            const u = j.get(d, "user") orelse return;
            g.upsert(u);
            const st = statusOf(d);
            g.emit(.{ .presence_update = .{
                .user = j.id(j.get(u, "id")) orelse return,
                .status = st,
                .activity = presenceActivity(d),
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
        return "servidor";
    }

    fn emojiOf(e: Value) types.Reaction {
        const name = j.str(j.get(e, "name")) orelse "?";
        if (j.isNull(j.get(e, "id"))) return types.Reaction.init(name);
        // Emoji personalizado: mostra o nome enquanto não há imagens.
        var b: [16]u8 = undefined;
        return types.Reaction.init(std.fmt.bufPrint(&b, ":{s}:", .{name[0..@min(name.len, 12)]}) catch name);
    }

    fn upsert(g: *Gateway, u: Value) void {
        const uid = j.id(j.get(u, "id")) orelse return;
        g.emit(.{ .user_upsert = .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = .offline } });
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
            1 => "Transmitindo ",
            2 => "Ouvindo ",
            3 => "Assistindo ",
            5 => "Competindo em ",
            else => "Jogando ",
        };
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name }) catch null;
    }

    /// Presenças podem vir como PresenceUpdate (com `user`) ou como
    /// MergedPresence do READY_SUPPLEMENTAL (com `user_id` e `presence`).
    fn ingestPresences(g: *Gateway, list: []const Value) void {
        for (list) |p| {
            var uid: Id = 0;
            if (j.get(p, "user")) |u| {
                g.upsert(u);
                uid = j.id(j.get(u, "id")) orelse 0;
            }
            if (uid == 0) uid = j.id(j.get(p, "user_id")) orelse continue;
            g.emit(.{ .presence_update = .{
                .user = uid,
                .status = presenceStatus(p),
                .activity = presenceActivity(p),
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
            else => return null,
        };
        var gid = j.id(j.get(cv, "guild_id")) orelse guild_hint;
        if (kind_i == 1 or kind_i == 3) gid = 0;

        var name: []const u8 = j.str(j.get(cv, "name")) orelse "";
        var recipient: Id = 0;
        if (kind_i == 1 or kind_i == 3) {
            const ids = j.array(j.get(cv, "recipient_ids"));
            if (ids.len > 0) recipient = j.id(ids[0]) orelse 0;
            for (j.array(j.get(cv, "recipients"))) |u| {
                g.upsert(u);
                if (recipient == 0) recipient = j.id(j.get(u, "id")) orelse 0;
                if (name.len == 0) name = userName(u);
            }
            if (name.len == 0) name = if (kind_i == 3) "grupo" else "?";
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
        var voice: std.ArrayList([2]Id) = .empty;
        errdefer voice.deinit(alloc);
        for (j.array(j.get(d, "voice_states"))) |vs| {
            const ch = j.id(j.get(vs, "channel_id")) orelse continue;
            const uid = j.id(j.get(vs, "user_id")) orelse continue;
            try voice.append(alloc, .{ ch, uid });
        }
        g.ingestMembers(d);
        g.emit(.{ .guild_create = .{
            .guild = .{
                .id = gid,
                .name = dupe(name),
                .acronym = try j.acronym(alloc, name),
                .color = @intCast((gid >> 22) % 8),
            },
            .channels = try channels.toOwnedSlice(alloc),
            .voice = try voice.toOwnedSlice(alloc),
        } });
    }

    /// Mensagem da API -> nosso tipo (conteúdo alocado).
    fn message(g: *Gateway, m: Value) !?types.Message {
        _ = g;
        const author = j.get(m, "author") orelse return null;
        var content = try j.simplifyContent(alloc, j.str(j.get(m, "content")) orelse "");
        // Anexos e figurinhas viram texto até termos imagens.
        for (j.array(j.get(m, "attachments"))) |a| {
            const name = j.str(j.get(a, "filename")) orelse "arquivo";
            const more = try std.fmt.allocPrint(alloc, "{s}{s}📎 `{s}`", .{ content, if (content.len > 0) " " else "", name });
            alloc.free(content);
            content = more;
        }
        for (j.array(j.get(m, "sticker_items"))) |s| {
            const more = try std.fmt.allocPrint(alloc, "{s} [figurinha: {s}]", .{ content, j.str(j.get(s, "name")) orelse "?" });
            alloc.free(content);
            content = more;
        }
        if (content.len == 0 and j.array(j.get(m, "embeds")).len > 0) {
            alloc.free(content);
            content = try alloc.dupe(u8, "*[embed]*");
        }
        const nonce: u64 = if (j.get(m, "nonce")) |n| @bitCast(j.int(n) orelse 0) else 0;
        var reply: Id = 0;
        if (j.get(m, "message_reference")) |ref| {
            if ((j.int(j.get(m, "type")) orelse 0) == 19) reply = j.id(j.get(ref, "message_id")) orelse 0;
        }
        return .{
            .id = j.id(j.get(m, "id")) orelse return null,
            .channel = j.id(j.get(m, "channel_id")) orelse 0,
            .author = j.id(j.get(author, "id")) orelse 0,
            .timestamp = j.isoTime(j.str(j.get(m, "timestamp")) orelse ""),
            .content = content,
            .nonce = nonce,
            .reply_to = reply,
            .edited = !j.isNull(j.get(m, "edited_timestamp")),
        };
    }

    fn onReady(g: *Gateway, d: Value, arena: std.mem.Allocator) !void {
        _ = arena;
        const me = j.get(d, "user") orelse return;
        g.me = j.id(j.get(me, "id")) orelse return;
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
                list.append(alloc, .{ .id = uid, .name = dupe(userName(u)), .role = roleFor(uid), .status = status }) catch {};
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
            const name = j.str(j.get(gv, "name")) orelse (if (props) |p| j.str(j.get(p, "name")) else null) orelse "servidor";
            try guilds.append(alloc, .{ .id = gid, .name = dupe(name), .acronym = try j.acronym(alloc, name), .color = @intCast((gid >> 22) % 8) });
            try appendChannels(&channels, gid, j.array(j.get(gv, "channels")));
            for (j.array(j.get(gv, "voice_states"))) |vs| {
                const ch = j.id(j.get(vs, "channel_id")) orelse continue;
                const uid = j.id(j.get(vs, "user_id")) orelse continue;
                try voice.append(alloc, .{ ch, uid });
            }
        }
        // DMs e grupos.
        for (j.array(j.get(d, "private_channels")), 0..) |pc, pos| {
            const cid = j.id(j.get(pc, "id")) orelse continue;
            const kind = j.int(j.get(pc, "type")) orelse 1;
            var recipient: Id = 0;
            const ids = j.array(j.get(pc, "recipient_ids"));
            if (ids.len > 0) recipient = j.id(ids[0]) orelse 0;
            const recips = j.array(j.get(pc, "recipients"));
            if (recipient == 0 and recips.len > 0) {
                recipient = j.id(j.get(recips[0], "id")) orelse 0;
                for (recips) |u| addUser(&users, &seen, u, .offline);
            }
            if (recipient == 0) continue;
            var name: []const u8 = j.str(j.get(pc, "name")) orelse "";
            if (name.len == 0) {
                for (users.items) |u| if (u.id == recipient) {
                    name = u.name;
                };
            }
            const gname: []const u8 = j.str(j.get(pc, "name")) orelse "";
            if (kind == 3 and gname.len == 0) name = "grupo";
            try channels.append(alloc, .{ .id = cid, .guild = 0, .name = dupe(name), .topic = dupe(""), .position = @intCast(@min(pos, 65535)), .recipient = recipient });
        }
        // DMs mais recentes primeiro (o id da última mensagem cresce com o tempo).
        sortDms(channels.items, j.array(j.get(d, "private_channels")));

        g.emit(.{ .ready = .{
            .me = g.me,
            .users = try users.toOwnedSlice(alloc),
            .guilds = try guilds.toOwnedSlice(alloc),
            .channels = try channels.toOwnedSlice(alloc),
            .voice = try voice.toOwnedSlice(alloc),
        } });
        g.emit(.{ .status = .ready });
    }

    fn sortDms(chs: []types.Channel, pcs: []const Value) void {
        const Ctx = struct {
            pcs: []const Value,
            fn last(self: @This(), id: Id) u64 {
                for (self.pcs) |pc| if (j.id(j.get(pc, "id")) == id) return j.id(j.get(pc, "last_message_id")) orelse 0;
                return 0;
            }
            fn lt(self: @This(), a: types.Channel, b: types.Channel) bool {
                if (a.guild != 0 or b.guild != 0) return false;
                return self.last(a.id) > self.last(b.id);
            }
        };
        var first_dm: usize = chs.len;
        for (chs, 0..) |ch, i| if (ch.guild == 0) {
            first_dm = i;
            break;
        };
        std.mem.sort(types.Channel, chs[first_dm..], Ctx{ .pcs = pcs }, Ctx.lt);
    }

    /// Canais de um servidor na ordem do Discord: soltos primeiro, depois
    /// cada categoria com os seus (texto antes de voz).
    fn appendChannels(out: *std.ArrayList(types.Channel), gid: Id, list: []const Value) !void {
        const Ch = struct { id: Id, parent: Id, kind: types.ChannelKind, pos: i64, name: []const u8, topic: []const u8 };
        var tmp: std.ArrayList(Ch) = .empty;
        defer tmp.deinit(alloc);
        for (list) |cv| {
            const kind: types.ChannelKind = switch (j.int(j.get(cv, "type")) orelse 0) {
                0, 5 => .text,
                2, 13 => .voice,
                4 => .category,
                else => continue,
            };
            try tmp.append(alloc, .{
                .id = j.id(j.get(cv, "id")) orelse continue,
                .parent = j.id(j.get(cv, "parent_id")) orelse 0,
                .kind = kind,
                .pos = j.int(j.get(cv, "position")) orelse 0,
                .name = j.str(j.get(cv, "name")) orelse "?",
                .topic = j.str(j.get(cv, "topic")) orelse "",
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
                try o.append(alloc, .{ .id = ch.id, .guild = g, .parent = if (ch.parent == 0) null else ch.parent, .kind = ch.kind, .name = dupe(ch.name), .topic = dupe(ch.topic), .position = p.* });
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

    fn writeCb(ptr: [*c]u8, size: usize, n: usize, user: ?*anyopaque) callconv(.c) usize {
        const body: *std.ArrayList(u8) = @ptrCast(@alignCast(user.?));
        body.appendSlice(alloc, ptr[0 .. size * n]) catch return 0;
        return size * n;
    }

    fn secondsToMs(s: []const u8) ?u32 {
        const f = std.fmt.parseFloat(f64, s) catch return null;
        if (!(f >= 0) or f > 300) return null;
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
            g.notice("{s}: {s}", .{ what, detail });
        } else {
            g.notice("{s} (HTTP {d})", .{ what, resp.status });
        }
    }

    fn request(g: *Gateway, method: [:0]const u8, path: []const u8, body: ?[]const u8) ?Response {
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
            if (until > now) g.sleepServing(@intCast(@min(until - now, 20_000)));

            var headers: ?*c.struct_curl_slist = null;
            headers = c.curl_slist_append(headers, auth.ptr);
            headers = c.curl_slist_append(headers, super_line.ptr);
            headers = c.curl_slist_append(headers, "Content-Type: application/json");
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
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &resp.body);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERFUNCTION, headerCb);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERDATA, &rate);
            _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, 20));
            _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
            if (body) |b| {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, b.ptr);
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
            } else if (std.mem.eql(u8, method, "PUT") or std.mem.eql(u8, method, "POST")) {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, "");
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
            }
            if (c.curl_easy_perform(h) != c.CURLE_OK) {
                resp.body.deinit(alloc);
                g.notice("sem conexão com a API do Discord", .{});
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
                        .float => |f| wait_ms = @intFromFloat(@min(f, 30) * 1000),
                        .integer => |i| wait_ms = @intCast(@min(i, 30) * 1000),
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
                g.notice("o Discord pediu calma: esperando {d} ms", .{wait_ms});
                g.sleepServing(wait_ms + 100);
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

    fn freeCommand(cmd: ev.Command) void {
        switch (cmd) {
            .send_message => |m| alloc.free(m.content),
            .edit_message => |m| alloc.free(m.content),
            else => {},
        }
    }

    fn execute(g: *Gateway, cmd: ev.Command) void {
        defer freeCommand(cmd);
        var path_buf: [256]u8 = undefined;
        switch (cmd) {
            .fetch_history => |ch| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages?limit=50", .{ch}) catch return;
                var resp = g.request("GET", path, null) orelse return g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
                defer resp.body.deinit(alloc);
                if (resp.status != 200) {
                    if (resp.status == 403) {
                        g.notice("sem permissão para ler esse canal", .{});
                    } else if (resp.status != 404) {
                        g.noticeHttp("não consegui carregar o histórico", &resp);
                    }
                    return g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
                }
                g.history(ch, resp.body.items) catch g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
            },
            .send_message => |m| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"content\":") catch return;
                j.writeString(&b, alloc, m.content) catch return;
                b.print(alloc, ",\"nonce\":\"{d}\",\"tts\":false", .{m.nonce}) catch return;
                if (m.reply_to != 0) b.print(alloc, ",\"message_reference\":{{\"message_id\":\"{d}\"}}", .{m.reply_to}) catch return;
                b.append(alloc, '}') catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages", .{m.channel}) catch return;
                var resp = g.request("POST", path, b.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp("não foi possível enviar", &resp);
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
                if (resp.status >= 300) g.noticeHttp("não foi possível editar", &resp);
            },
            .delete_message => |m| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}", .{ m.channel, m.id }) catch return;
                var resp = g.request("DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.noticeHttp("não foi possível apagar", &resp);
            },
            .react => |r| {
                var enc: [64]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}/reactions/{s}/@me", .{ r.channel, r.id, j.urlEncode(&enc, r.emoji.text()) }) catch return;
                var resp = g.request(if (r.add) "PUT" else "DELETE", path, null) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300 and resp.status != 404) g.noticeHttp("não foi possível reagir", &resp);
            },
            .typing => |ch| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/typing", .{ch}) catch return;
                var resp = g.request("POST", path, null) orelse return;
                resp.body.deinit(alloc);
            },
            .join_voice => if (!g.voice_warned) {
                g.voice_warned = true;
                g.notice("voz ainda não funciona na conexão real", .{});
            },
            .shutdown => {},
        }
    }

    fn history(g: *Gateway, ch: Id, body: []const u8) !void {
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
            if (try g.message(items[i])) |m| try list.append(alloc, m);
        }
        const msgs = try list.toOwnedSlice(alloc);
        g.emit(.{ .history = .{ .channel = ch, .messages = msgs } });
        // Reações já existentes.
        for (items) |m| {
            const mid = j.id(j.get(m, "id")) orelse continue;
            for (j.array(j.get(m, "reactions"))) |rv| {
                var r = emojiOf(j.get(rv, "emoji") orelse continue);
                r.count = @intCast(@min(j.int(j.get(rv, "count")) orelse 1, 65535));
                r.me = (j.get(rv, "me") orelse Value{ .bool = false }) == .bool and (j.get(rv, "me").?).bool;
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
    if (c.SDL_getenv("LARPER_TOKEN")) |t| {
        const s = std.mem.trim(u8, std.mem.span(t), " \n\r\t");
        if (s.len > 20) return alloc.dupeSentinel(u8, s, 0) catch null;
    }
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
