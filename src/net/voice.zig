//! Voz de verdade: gateway de voz (v9), UDP, Opus, DAVE (E2EE) e SDL3.
//!
//! Tudo roda numa thread própria, criada só quando alguém entra numa call.
//! Fora de uma call este módulo não consome CPU: o app nem inicializa o áudio.
//!
//! documentação do Discord:
//!   - WebSocket v9 com heartbeat;
//!   - IP discovery (pacote de 74 bytes) e Select Protocol;
//!   - RTP com aead_xchacha20_poly1305_rtpsize;
//!   - Opus 48 kHz estéreo, 20 ms por pacote;
//!   - DAVE/MLS via libdave para as chamadas de hoje em dia.
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Sink = @import("fake_gateway.zig").Sink;
const i18n = @import("../ui/i18n.zig");
const j = @import("jsonx.zig");

const Id = types.Id;
const alloc = std.heap.c_allocator;
const nowMs = @import("fake_gateway.zig").nowMs;

/// Mutex simples: as seções críticas aqui são só copiar alguns KB de PCM.
const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(m: *Mutex) void {
        while (!m.state.tryLock()) std.Thread.yield() catch {};
    }

    fn unlock(m: *Mutex) void {
        m.state.unlock();
    }
};

const opus_rate = 48000;
const frame_ms = 20;
const frame_samples = opus_rate * frame_ms / 1000; // 960
const channels = 2;
const frame_bytes = frame_samples * channels * @sizeOf(i16); // 3840
const sample_rate = opus_rate;

pub const Voice = struct {
    sink: Sink,
    guild: Id = 0,
    channel: Id = 0,
    user: Id = 0,
    endpoint: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    token: [256]u8 = @splat(0),
    token_len: usize = 0,
    session: [128]u8 = @splat(0),
    session_len: usize = 0,
    muted: std.atomic.Value(bool) = .init(false),
    deafened: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,
    volume_mutex: Mutex = .{},
    volumes: std.AutoHashMapUnmanaged(Id, f32) = .empty,

    pub fn init(sink: Sink, guild: Id, channel: Id, user: Id, endpoint: []const u8, token: []const u8, session: []const u8, mute: bool, deaf: bool) Voice {
        var v: Voice = .{ .sink = sink, .guild = guild, .channel = channel, .user = user };
        v.endpoint_len = @min(endpoint.len, v.endpoint.len - 1);
        @memcpy(v.endpoint[0..v.endpoint_len], endpoint[0..v.endpoint_len]);
        v.token_len = @min(token.len, v.token.len - 1);
        @memcpy(v.token[0..v.token_len], token[0..v.token_len]);
        v.session_len = @min(session.len, v.session.len - 1);
        @memcpy(v.session[0..v.session_len], session[0..v.session_len]);
        v.muted = .init(mute);
        v.deafened = .init(deaf);
        return v;
    }

    pub fn start(v: *Voice) !void {
        v.thread = c.SDL_CreateThread(threadMain, "voice", v) orelse return error.SdlThread;
    }

    pub fn stop(v: *Voice) void {
        v.stopping.store(true, .release);
        if (v.thread) |t| {
            c.SDL_WaitThread(t, null);
            v.thread = null;
        }
    }

    pub fn deinit(v: *Voice) void {
        std.crypto.secureZero(u8, &v.token);
        std.crypto.secureZero(u8, &v.session);
        v.volumes.deinit(alloc);
    }

    pub fn setFlags(v: *Voice, mute: bool, deaf: bool) void {
        v.muted.store(mute, .release);
        v.deafened.store(deaf, .release);
    }

    pub fn setVolume(v: *Voice, user: Id, gain: f32) void {
        v.volume_mutex.lock();
        defer v.volume_mutex.unlock();
        v.volumes.put(alloc, user, std.math.clamp(gain, 0, 2)) catch {};
    }

    fn volumeOf(v: *Voice, user: Id) f32 {
        v.volume_mutex.lock();
        defer v.volume_mutex.unlock();
        return v.volumes.get(user) orelse 1;
    }

    fn emit(v: *Voice, e: ev.Event) void {
        v.sink.push(v.sink.ctx, e);
    }

    fn status(v: *Voice, st: ev.VoiceStatus) void {
        v.emit(.{ .voice_status = .{ .status = st, .channel = v.channel } });
    }

    fn notice(v: *Voice, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        const s = i18n.allocPrint(alloc, pt, en, args) catch return;
        v.emit(.{ .notice = s });
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const v: *Voice = @ptrCast(@alignCast(data.?));
        v.status(.connecting);
        var worker = Worker{ .v = v };
        worker.run();
        v.status(.disconnected);
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Estado da conexão (só existe na thread de voz)
// ---------------------------------------------------------------------------

const Worker = struct {
    v: *Voice,
    ws: ?*c.CURL = null,
    ws_sock: c.curl_socket_t = -1,
    udp: c_int = -1,
    server: std.posix.sockaddr.in = undefined,
    ssrc: u32 = 0,
    secret: [32]u8 = @splat(0),
    mode_xchacha: bool = true,
    seq: u32 = 0,
    rtp_seq: u16 = 0,
    rtp_ts: u32 = 0,
    nonce: u32 = 0,
    hb_interval: i64 = 13750,
    next_hb: i64 = 0,
    next_frame: i64 = 0,
    next_keepalive: i64 = 0,
    last_seq: i64 = 0,
    connected: bool = false,
    speaking_sent: bool = false,
    speaking_now: bool = false,
    audio_on: bool = false,
    dave: ?Dave = null,
    encoder: ?*c.OpusEncoder = null,
    mic: Mic = .{},
    mixer: Mixer = .{},
    capture: ?*c.SDL_AudioStream = null,
    playback: ?*c.SDL_AudioStream = null,
    ws_in: std.ArrayList(u8) = .empty,
    in_buf: [65536]u8 = undefined,
    url_buf: [320]u8 = undefined,
    play_buf: [frame_samples * channels]i16 = undefined,
    play_len: usize = 0,
    play_pos: usize = 0,

    fn run(w: *Worker) void {
        defer w.cleanup();
        const url = w.buildUrl() orelse {
            w.v.notice("endereço de voz inválido", "invalid voice endpoint", .{});
            return;
        };
        if (!w.connectWs(url)) return;
        if (!w.initAudio()) {
            // Sem microfone/placa ainda dá para ouvir? SDL falhou: segue sem
            // áudio local em vez de derrubar a chamada.
            std.log.warn("voz: sem dispositivo de áudio", .{});
        }
        w.next_hb = nowMs() + 13750;
        w.loop();
    }

    fn buildUrl(w: *Worker) ?[:0]u8 {
        var ep: []const u8 = w.v.endpoint[0..w.v.endpoint_len];
        if (std.mem.startsWith(u8, ep, "wss://")) ep = ep[6..];
        if (std.mem.startsWith(u8, ep, "https://")) ep = ep[8..];
        if (ep.len == 0) return null;
        return std.fmt.bufPrintSentinel(&w.url_buf, "wss://{s}/?v=9", .{ep}, 0) catch null;
    }

    fn connectWs(w: *Worker, url: [:0]const u8) bool {
        const h = c.curl_easy_init() orelse return false;
        w.ws = h;
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 4000));
        _ = c.curl_easy_setopt(h, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_1_1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, @as([*c]const u8, @ptrCast("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.87 Safari/537.36")));

        const rc = c.curl_easy_perform(h);
        if (rc != c.CURLE_OK) {
            std.log.warn("voz: curl {d}: {s} ({s})", .{ rc, c.curl_easy_strerror(rc), url });
            w.v.notice("não consegui abrir a conexão de voz ({s})", "couldn't open the voice connection ({s})", .{c.curl_easy_strerror(rc)});
            return false;
        }
        var sock: c.curl_socket_t = -1;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        if (sock < 0) return false;
        w.ws_sock = sock;
        return true;
    }

    fn cleanup(w: *Worker) void {
        if (w.capture) |s| c.SDL_DestroyAudioStream(s);
        if (w.playback) |s| c.SDL_DestroyAudioStream(s);
        if (w.audio_on) c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        w.mixer.deinit();
        if (w.encoder) |e| c.opus_encoder_destroy(e);
        if (w.dave) |*d| d.deinit();
        if (w.udp >= 0) _ = c.close(w.udp);
        if (w.ws) |h| c.curl_easy_cleanup(h);
        std.crypto.secureZero(u8, &w.secret);
        w.ws_in.deinit(alloc);
        w.mic.deinit();
    }

    fn loop(w: *Worker) void {
        w.next_frame = nowMs();
        w.next_keepalive = nowMs() + 10000;
        while (!w.v.stopping.load(.acquire)) {
            const now = nowMs();
            const wait: c_int = @intCast(std.math.clamp(@min(w.next_hb - now, w.next_frame - now), 0, 50));
            w.waitSockets(wait);
            w.readWs();
            w.readUdp();
            w.tick(nowMs());
        }
    }

    fn waitSockets(w: *Worker, timeout_ms: c_int) void {
        var fds: [2]c.struct_pollfd = undefined;
        var n: usize = 0;
        if (w.ws_sock >= 0) {
            fds[n] = .{ .fd = @intCast(w.ws_sock), .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (w.udp >= 0) {
            fds[n] = .{ .fd = w.udp, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (n == 0) {
            c.SDL_Delay(@intCast(timeout_ms));
            return;
        }
        _ = c.poll(&fds, @intCast(n), timeout_ms);
    }

    fn tick(w: *Worker, now: i64) void {
        if (now >= w.next_hb) {
            w.heartbeat();
            w.next_hb = now + w.hb_interval;
        }
        if (w.connected and now >= w.next_keepalive) {
            const keep = [_]u8{ 0x13, 0x37 };
            _ = c.sendto(w.udp, &keep, keep.len, 0, @ptrCast(&w.server), @sizeOf(std.posix.sockaddr.in));
            w.next_keepalive = now + 10000;
        }
        if (w.connected and now >= w.next_frame) {
            w.sendFrame();
            w.next_frame += 20;
            if (w.next_frame < now - 100) w.next_frame = now + 20; // não acumula atraso
        }
    }

    // --- WebSocket ---------------------------------------------------------

    fn sendText(w: *Worker, text: []const u8) bool {
        const h = w.ws orelse return false;
        var off: usize = 0;
        var first = true;
        while (off < text.len) {
            var sent: usize = 0;
            const flags: c_uint = if (first) c.CURLWS_TEXT else c.CURLWS_CONT;
            const rc = c.curl_ws_send(h, text.ptr + off, text.len - off, &sent, 0, flags);
            if (rc == c.CURLE_AGAIN) {
                w.waitSockets(20);
                continue;
            }
            if (rc != c.CURLE_OK) {
                std.log.warn("voz: ws send rc={d} sent={d}/{d}", .{ rc, sent, text.len - off });
                return false;
            }
            if (sent == 0) return false;
            off += sent;
            first = false;
        }
        return true;
    }

    fn sendBinary(w: *Worker, opcode: u8, payload: []const u8) bool {
        const h = w.ws orelse return false;
        var buf: [32768]u8 = undefined;
        const n = @min(payload.len, buf.len - 1);
        buf[0] = opcode;
        @memcpy(buf[1..][0..n], payload[0..n]);
        var off: usize = 0;
        var first = true;
        while (off < n + 1) {
            var sent: usize = 0;
            const flags: c_uint = if (first) c.CURLWS_BINARY else c.CURLWS_CONT;
            const rc = c.curl_ws_send(h, buf[off..].ptr, n + 1 - off, &sent, 0, flags);
            if (rc == c.CURLE_AGAIN) {
                w.waitSockets(20);
                continue;
            }
            if (rc != c.CURLE_OK or sent == 0) return false;
            off += sent;
            first = false;
        }
        return true;
    }

    fn heartbeat(w: *Worker) void {
        std.log.debug("voz: heartbeat seq_ack={d}", .{w.last_seq});
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":3,\"d\":{{\"t\":{d},\"seq_ack\":{d}}}}}", .{ nowMs(), w.last_seq }) catch return;
        _ = w.sendText(p);
    }

    fn identify(w: *Worker) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.print(alloc, "{{\"op\":0,\"d\":{{\"server_id\":\"{d}\",\"user_id\":\"{d}\",\"session_id\":", .{ w.v.guild, w.v.user }) catch return;
        j.writeString(&out, alloc, w.v.session[0..w.v.session_len]) catch return;
        out.appendSlice(alloc, ",\"token\":") catch return;
        j.writeString(&out, alloc, w.v.token[0..w.v.token_len]) catch return;
        out.print(alloc, ",\"video\":false,\"max_dave_protocol_version\":{d}}}}}", .{c.daveMaxSupportedProtocolVersion()}) catch return;
        std.log.debug("voz: identify {d} bytes", .{out.items.len});
        _ = w.sendText(out.items);
    }

    fn readWs(w: *Worker) void {
        const h = w.ws orelse return;
        while (true) {
            var got: usize = 0;
            var meta: [*c]const c.struct_curl_ws_frame = null;
            const rc = c.curl_ws_recv(h, &w.in_buf, w.in_buf.len, &got, &meta);
            if (rc == c.CURLE_AGAIN) return;
            if (rc != c.CURLE_OK or meta == null) return;
            const flags = meta.*.flags;
            if (flags & c.CURLWS_CLOSE != 0) {
                const code: u16 = if (got >= 2) (@as(u16, w.in_buf[0]) << 8) | w.in_buf[1] else 0;
                const reason = if (got > 2) w.in_buf[2..got] else "";
                std.log.warn("voz: fechou {d}: {s}", .{ code, reason });
                w.onClose(code);
                return;
            }
            if (flags & (c.CURLWS_PING | c.CURLWS_PONG) != 0) continue;
            if (got > 0) w.ws_in.appendSlice(alloc, w.in_buf[0..got]) catch return;
            if (meta.*.bytesleft != 0) continue;
            const bytes = w.ws_in.items;
            if (bytes.len == 0) continue;
            if (flags & c.CURLWS_TEXT != 0) {
                w.onText(bytes);
            } else if (flags & c.CURLWS_BINARY != 0) {
                w.onBinary(bytes);
            }
            w.ws_in.clearRetainingCapacity();
        }
    }

    fn onClose(w: *Worker, code: u16) void {
        w.connected = false;
        if (w.v.stopping.load(.acquire)) return;
        switch (code) {
            4004 => w.v.notice("o Discord recusou a sessão de voz (4004).", "Discord refused the voice session (4004).", .{}),
            4006, 4009 => w.v.notice("a sessão de voz expirou; entre de novo.", "voice session expired; join again.", .{}),
            4014 => {},
            4017 => w.v.notice("o Discord exigiu E2EE (DAVE) e a negociação falhou.", "Discord requires E2EE (DAVE) and negotiation failed.", .{}),
            else => w.v.notice("a call caiu (código {d}).", "the call dropped (code {d}).", .{code}),
        }
    }

    fn onText(w: *Worker, text: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return;
        if (j.int(j.get(root, "seq"))) |s| w.last_seq = s;
        const op = j.int(j.get(root, "op")) orelse return;
        const d = j.get(root, "d") orelse std.json.Value{ .null = {} };
        std.log.debug("voz: op {d} recebido", .{op});
        switch (op) {
            8 => {
                w.hb_interval = j.int(j.get(d, "heartbeat_interval")) orelse 13750;
                w.next_hb = nowMs() + w.hb_interval;
                w.identify();
            },
            2 => w.onReady(d),
            4 => w.onSession(d),
            5 => w.onSpeaking(d),
            11 => {
                for (j.array(j.get(d, "user_ids"))) |u| {
                    if (j.id(u)) |uid| {
                        if (w.dave) |*dave| dave.addUser(uid);
                    }
                }
            },
            13 => {
                if (j.id(j.get(d, "user_id"))) |uid| {
                    w.mixer.removeUser(uid);
                    if (w.dave) |*dave| dave.removeUser(uid);
                }
            },
            14 => {
                if (j.id(j.get(d, "user_id"))) |uid| {
                    const ssrc: u32 = @intCast(std.math.clamp(j.int(j.get(d, "audio_ssrc")) orelse 0, 0, std.math.maxInt(u32)));
                    if (ssrc != 0) w.mixer.map(ssrc, uid);
                    if (w.dave) |*dave| dave.addUser(uid);
                }
            },
            21 => {
                if (w.dave) |*dave| {
                    const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                    dave.prepareTransition(ver);
                    const tid = j.int(j.get(d, "transition_id")) orelse 0;
                    w.sendReady(tid);
                }
            },
            22 => {
                if (w.dave) |*dave| {
                    const tid = j.int(j.get(d, "transition_id")) orelse 0;
                    dave.executeTransition(tid);
                }
            },
            24 => {
                const epoch = j.int(j.get(d, "epoch")) orelse 0;
                const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                if (epoch == 1) {
                    if (w.dave == null) w.initDave(ver);
                    if (w.dave) |*dave| {
                        dave.reinit(ver);
                        w.sendKeyPackage();
                    }
                }
            },
            else => {},
        }
    }

    fn sendReady(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":23,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn onBinary(w: *Worker, data: []const u8) void {
        if (data.len < 3) return;
        const opcode = data[2];
        const payload = data[3..];
        const dave = if (w.dave) |*d| d else return;
        switch (opcode) {
            25 => dave.setExternalSender(payload),
            27 => {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(alloc);
                dave.proposals(payload, &out);
                if (out.items.len > 0) _ = w.sendBinary(28, out.items);
            },
            29 => {
                if (payload.len < 2) return;
                const tid = std.mem.readInt(u16, payload[0..2], .big);
                const res = dave.commit(tid, payload[2..]);
                if (res == null) return;
                if (res.?) {
                    w.sendReady(tid);
                    if (dave.enabled) dave.setLocalSsrc(w.ssrc);
                } else {
                    w.sendInvalid(tid);
                    w.sendKeyPackage();
                }
            },
            30 => {
                if (payload.len < 2) return;
                const tid = std.mem.readInt(u16, payload[0..2], .big);
                if (dave.welcome(tid, payload[2..])) {
                    w.sendReady(tid);
                    if (dave.enabled) dave.setLocalSsrc(w.ssrc);
                } else {
                    w.sendInvalid(tid);
                    w.sendKeyPackage();
                }
            },
            31 => {
                // O gateway recusou nosso commit/welcome: recomeça o MLS.
                dave.reinit(dave.version);
                w.sendKeyPackage();
            },
            else => {},
        }
    }

    fn sendInvalid(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":31,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn parseIp4(ip: []const u8, port: u16) !std.posix.sockaddr.in {
        var z: [64]u8 = @splat(0);
        if (ip.len == 0 or ip.len >= z.len) return error.InvalidAddress;
        @memcpy(z[0..ip.len], ip);
        var sa: std.posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
        if (c.inet_pton(c.AF_INET, &z, &sa.addr) != 1) return error.InvalidAddress;
        return sa;
    }

    fn onReady(w: *Worker, d: std.json.Value) void {
        const ip = j.str(j.get(d, "ip")) orelse return;
        const port: u16 = @intCast(std.math.clamp(j.int(j.get(d, "port")) orelse 0, 0, 65535));
        w.ssrc = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        if (port == 0) return;
        w.server = parseIp4(ip, port) catch {
            w.v.notice("endereço UDP de voz inválido", "invalid voice UDP address", .{});
            return;
        };
        const fd = c.socket(c.AF_INET, c.SOCK_DGRAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            return;
        }
        w.udp = fd;
        const local: std.posix.sockaddr.in = .{ .port = 0, .addr = 0 };
        if (c.bind(w.udp, @ptrCast(&local), @sizeOf(std.posix.sockaddr.in)) != 0) {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            return;
        }
        // IP discovery: o pedido tem 74 bytes (cabeçalho de 4 + ssrc + 66).
        var pkt: [74]u8 = @splat(0);
        std.mem.writeInt(u16, pkt[0..2], 1, .big);
        std.mem.writeInt(u16, pkt[2..4], 70, .big);
        std.mem.writeInt(u32, pkt[4..8], w.ssrc, .big);
        for (0..5) |_| {
            _ = c.sendto(w.udp, &pkt, pkt.len, 0, @ptrCast(&w.server), @sizeOf(std.posix.sockaddr.in));
            const deadline = nowMs() + 1000;
            while (nowMs() < deadline and !w.v.stopping.load(.acquire)) {
                w.waitSockets(100);
                var from: c.struct_sockaddr = undefined;
                var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr);
                var resp: [256]u8 = undefined;
                const nr = c.recvfrom(w.udp, &resp, resp.len, c.MSG_DONTWAIT, @ptrCast(&from), &from_len);
                if (nr < 0) continue;
                const n: usize = @intCast(nr);
                if (n < 74) continue;
                if (std.mem.readInt(u16, resp[0..2], .big) != 2) continue;
                var ip_buf: [64]u8 = undefined;
                const iplen = std.mem.indexOfScalar(u8, resp[8..72], 0) orelse 64;
                @memcpy(ip_buf[0..iplen], resp[8..][0..iplen]);
                const ext_port = std.mem.readInt(u16, resp[72..74], .big);
                std.log.debug("voz: discovery {s}:{d}", .{ ip_buf[0..iplen], ext_port });
                w.selectProtocol(ip_buf[0..iplen], ext_port);
                return;
            }
        }
        w.v.notice("a call não respondeu ao UDP (firewall/NAT?)", "the call didn't answer on UDP (firewall/NAT?)", .{});
    }

    fn selectProtocol(w: *Worker, ip: []const u8, port: u16) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        out.appendSlice(alloc, "{\"op\":1,\"d\":{\"address\":") catch return;
        j.writeString(&out, alloc, ip) catch return;
        out.print(alloc, ",\"port\":{d},\"protocol\":\"udp\",\"mode\":\"aead_xchacha20_poly1305_rtpsize\",\"data\":{{\"address\":", .{port}) catch return;
        j.writeString(&out, alloc, ip) catch return;
        out.print(alloc, ",\"port\":{d},\"mode\":\"aead_xchacha20_poly1305_rtpsize\"", .{port}) catch return;
        out.appendSlice(alloc, "}}}") catch return;
        std.log.debug("voz: select protocol {s}", .{out.items});
        _ = w.sendText(out.items);
    }

    fn onSession(w: *Worker, d: std.json.Value) void {
        const mode = j.str(j.get(d, "mode")) orelse "";
        w.mode_xchacha = std.mem.eql(u8, mode, "aead_xchacha20_poly1305_rtpsize");
        if (!w.mode_xchacha) {
            w.v.notice("modo de criptografia de voz não suportado ({s})", "unsupported voice encryption mode ({s})", .{mode});
            return;
        }
        const keys = j.array(j.get(d, "secret_key"));
        if (keys.len != 32) return;
        for (keys, 0..) |kv, i| {
            const n = j.int(kv) orelse return;
            w.secret[i] = @intCast(std.math.clamp(n, 0, 255));
        }
        const dave_ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "dave_protocol_version")) orelse 0, 0, 1));
        if (dave_ver > 0) {
            w.initDave(dave_ver);
            w.sendKeyPackage();
        }
        // Avisa uma vez que estamos falando (o gateway espera esse opcode).
        var b: [96]u8 = undefined;
        const sp = std.fmt.bufPrint(&b, "{{\"op\":5,\"d\":{{\"speaking\":1,\"delay\":0,\"ssrc\":{d}}}}}", .{w.ssrc}) catch return;
        _ = w.sendText(sp);
        w.speaking_sent = true;
        // Um pacote de silêncio para o servidor abrir o caminho de mídia.
        w.sendRtp(&.{ 0xF8, 0xFF, 0xFE });
        w.connected = true;
        w.v.status(.connected);
    }

    fn onSpeaking(w: *Worker, d: std.json.Value) void {
        const uid = j.id(j.get(d, "user_id")) orelse return;
        const ssrc: u32 = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        const speaking = (j.int(j.get(d, "speaking")) orelse 0) != 0;
        if (ssrc != 0) w.mixer.map(ssrc, uid);
        if (w.dave) |*dave| {
            dave.addUser(uid);
            if (ssrc != 0) dave.setSsrcUser(ssrc, uid);
        }
        w.v.emit(.{ .voice_speaking = .{ .user = uid, .speaking = speaking } });
    }

    // --- DAVE --------------------------------------------------------------

    fn initDave(w: *Worker, version: u16) void {
        var d = Dave.init(w.v.channel, w.v.user, version) orelse {
            std.log.warn("voz: DAVE indisponível", .{});
            return;
        };
        d.addUser(w.v.user);
        d.setLocalSsrc(w.ssrc);
        w.dave = d;
        std.log.debug("voz: DAVE v{d} iniciado", .{version});
        if (w.encoder != null) {
            // O codec do nosso SSRC é Opus; o SSRC só é conhecido no Ready.
        }
    }

    fn sendKeyPackage(w: *Worker) void {
        const dave = if (w.dave) |*d| d else return;
        var kp: [4096]u8 = undefined;
        const n = dave.keyPackage(&kp);
        if (n > 0) {
            std.log.debug("voz: DAVE key package {d} bytes", .{n});
            _ = w.sendBinary(26, kp[0..n]);
        }
    }

    // --- UDP / mídia -------------------------------------------------------

    fn readUdp(w: *Worker) void {
        if (w.udp < 0) return;
        while (true) {
            var from: c.struct_sockaddr = undefined;
            var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr);
            var buf: [2048]u8 = undefined;
            const nr = c.recvfrom(w.udp, &buf, buf.len, c.MSG_DONTWAIT, @ptrCast(&from), &from_len);
            if (nr < 0) return;
            const n: usize = @intCast(nr);
            if (n == 0) return;
            w.onRtp(buf[0..n]);
        }
    }

    fn sendFrame(w: *Worker) void {
        const muted = w.v.muted.load(.acquire) or w.v.deafened.load(.acquire);
        var pcm: [frame_samples * channels]i16 = undefined;
        const got = w.mic.take(&pcm);
        if (got == null) @memset(&pcm, 0);
        var peak: i32 = 0;
        for (pcm) |s| {
            const v: i32 = s;
            peak = @max(peak, if (v < 0) -v else v);
        }
        const speaking = !muted and peak > 220;
        const enc = w.encoder orelse return;
        var packet: [4000]u8 = undefined;
        const len = c.opus_encode(enc, &pcm, frame_samples, &packet, packet.len);
        if (len <= 0) return;
        var payload: []const u8 = packet[0..@intCast(len)];
        var dave_buf: [4096]u8 = undefined;
        if (w.dave) |*dave| {
            if (dave.enabled) {
                const n = dave.encrypt(w.ssrc, payload, &dave_buf);
                if (n > 0) payload = dave_buf[0..n] else return;
            }
        }
        w.sendRtp(payload);
        if (speaking != w.speaking_now) {
            w.speaking_now = speaking;
            w.setSpeaking(speaking);
        }
    }

    fn setSpeaking(w: *Worker, on: bool) void {
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":5,\"d\":{{\"speaking\":{d},\"delay\":0,\"ssrc\":{d}}}}}", .{ @intFromBool(on), w.ssrc }) catch return;
        _ = w.sendText(p);
        w.v.emit(.{ .voice_speaking = .{ .user = w.v.user, .speaking = on } });
    }

    fn sendRtp(w: *Worker, payload: []const u8) void {
        if (w.udp < 0 or payload.len == 0) return;
        var buf: [12 + 4096 + 16 + 4]u8 = undefined;
        const off = 12;
        if (payload.len + off + 16 + 4 > buf.len) return;
        buf[0] = 0x80;
        buf[1] = 0x78;
        std.mem.writeInt(u16, buf[2..4], w.rtp_seq, .big);
        std.mem.writeInt(u32, buf[4..8], w.rtp_ts, .big);
        std.mem.writeInt(u32, buf[8..12], w.ssrc, .big);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .little);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[off..][0..payload.len], &tag, payload, buf[0..off], nonce, w.secret);
        @memcpy(buf[off + payload.len ..][0..16], &tag);
        std.mem.writeInt(u32, buf[off + payload.len + 16 ..][0..4], w.nonce, .little);
        const total = off + payload.len + 16 + 4;
        _ = c.sendto(w.udp, buf[0..total].ptr, total, 0, @ptrCast(&w.server), @sizeOf(std.posix.sockaddr.in));
        w.rtp_seq +%= 1;
        w.rtp_ts +%= frame_samples;
    }

    fn onRtp(w: *Worker, buf: []const u8) void {
        if (buf.len < 12 + 16 + 4) return;
        if ((buf[0] >> 6) != 2) return;
        if ((buf[1] & 0x7f) != 120) return; // só Opus
        const ssrc = std.mem.readInt(u32, buf[8..12], .big);
        if (ssrc == w.ssrc) return;
        var off: usize = 12 + @as(usize, buf[0] & 0x0f) * 4;
        if (off > buf.len) return;
        if (buf[0] & 0x10 != 0) {
            if (off + 4 > buf.len) return;
            const words = std.mem.readInt(u16, buf[off + 2 ..][0..2], .big);
            off += 4 + @as(usize, words) * 4;
            if (off > buf.len) return;
        }
        if (buf.len < off + 16 + 4) return;
        const cipher = buf[off .. buf.len - 20];
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[buf.len - 20 ..][0..16]);
        const nonce_suffix = std.mem.readInt(u32, buf[buf.len - 4 ..][0..4], .little);
        var nonce: [24]u8 = @splat(0);
        std.mem.writeInt(u32, nonce[0..4], nonce_suffix, .little);
        var plain: [4096]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.decrypt(plain[0..cipher.len], cipher, tag, buf[0..off], nonce, w.secret) catch return;
        var frame: []const u8 = plain[0..cipher.len];
        if (w.dave) |*dave| {
            const silence = [_]u8{ 0xF8, 0xFF, 0xFE };
            if (!dave.enabled) {
                // Durante o handshake do MLS a mídia ainda não é E2EE; não
                // tenta tocar lixo (o silêncio do SFU passa).
                if (!std.mem.eql(u8, frame, &silence)) return;
            } else if (!std.mem.eql(u8, frame, &silence)) {
                var dave_out: [4096]u8 = undefined;
                const n = dave.decrypt(ssrc, frame, &dave_out) orelse return;
                frame = dave_out[0..n];
            }
        } else {
            if (w.v.stopping.load(.acquire)) return;
        }
        // Opus -> PCM e mistura.
        const src = w.mixer.source(ssrc) orelse w.mixer.add(ssrc, 0);
        if (src == null) return;
        const dec = src.?.dec orelse return;
        var pcm: [5760 * channels]i16 = undefined;
        const n = c.opus_decode(dec, frame.ptr, @intCast(frame.len), &pcm, 5760, 0);
        if (n <= 0) return;
        w.mixer.push(src.?, pcm[0 .. @as(usize, @intCast(n)) * channels]);
    }

    // --- Áudio ------------------------------------------------------------

    fn initAudio(w: *Worker) bool {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return false;
        w.audio_on = true;
        w.mixer.v = w.v;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_S16, .channels = channels, .freq = sample_rate };
        w.playback = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, playbackCb, w);
        if (w.playback) |s| _ = c.SDL_ResumeAudioStreamDevice(s);
        w.capture = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &spec, captureCb, &w.mic);
        if (w.capture) |s| _ = c.SDL_ResumeAudioStreamDevice(s);
        var err: c_int = 0;
        w.encoder = c.opus_encoder_create(opus_rate, channels, c.OPUS_APPLICATION_VOIP, &err);
        if (err == c.OPUS_OK) {
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, 64000));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 5));
        } else w.encoder = null;
        return w.playback != null or w.capture != null;
    }

    fn playbackCb(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, _: c_int) callconv(.c) void {
        const w: *Worker = @ptrCast(@alignCast(userdata.?));
        if (additional <= 0) return;
        const bytes = @min(@as(usize, @intCast(additional)), 16384);
        const frames = @min(bytes / (channels * @sizeOf(i16)), 2048);
        if (frames == 0) return;
        var out: [4096]i16 = undefined;
        var done: usize = 0;
        const deaf = w.v.deafened.load(.acquire);
        while (done < frames) {
            if (w.play_pos >= w.play_len) {
                w.mixer.render(w.play_buf[0..], deaf);
                w.play_len = w.play_buf.len;
                w.play_pos = 0;
            }
            const avail = (w.play_len - w.play_pos) / channels;
            const take = @min(frames - done, avail);
            if (take == 0) break;
            @memcpy(out[done * channels ..][0 .. take * channels], w.play_buf[w.play_pos..][0 .. take * channels]);
            w.play_pos += take * channels;
            done += take;
        }
        if (done > 0 and stream != null) _ = c.SDL_PutAudioStreamData(stream, &out, @intCast(done * channels * @sizeOf(i16)));
    }

    fn captureCb(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, total_amount: c_int) callconv(.c) void {
        const mic: *Mic = @ptrCast(@alignCast(userdata.?));
        var buf: [8192]u8 = undefined;
        var left: usize = @min(@as(usize, @intCast(@max(additional, 0))), 16384);
        if (left == 0) left = @min(@as(usize, @intCast(@max(total_amount, 0))), 16384);
        while (left > 0) {
            const want = @min(left, buf.len);
            var got: c_int = 0;
            if (stream) |s| got = c.SDL_GetAudioStreamData(s, &buf, @intCast(want));
            if (got <= 0) break;
            mic.push(std.mem.bytesAsSlice(i16, buf[0..@intCast(got)]));
            left -= @intCast(got);
        }
    }
};

// ---------------------------------------------------------------------------
// Mic e mistura
// ---------------------------------------------------------------------------

const Mic = struct {
    mutex: Mutex = .{},
    pcm: std.ArrayList(i16) = .empty,

    fn deinit(m: *Mic) void {
        m.pcm.deinit(alloc);
    }

    fn push(m: *Mic, samples: []align(1) const i16) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        // 200 ms de folga: se a thread atrasar, o áudio antigo é descartado.
        const max = frame_samples * channels * 10;
        if (m.pcm.items.len + samples.len > max) {
            const drop = m.pcm.items.len + samples.len - max;
            const aligned = @min(drop, m.pcm.items.len);
            std.mem.copyForwards(i16, m.pcm.items[0 .. m.pcm.items.len - aligned], m.pcm.items[aligned..]);
            m.pcm.items.len -= aligned;
        }
        for (samples) |x| m.pcm.append(alloc, x) catch {};
    }

    /// Copia um quadro inteiro; se ainda não chegou, não come nada.
    fn take(m: *Mic, out: []i16) ?usize {
        m.mutex.lock();
        defer m.mutex.unlock();
        if (m.pcm.items.len < out.len) return null;
        @memcpy(out, m.pcm.items[0..out.len]);
        std.mem.copyForwards(i16, m.pcm.items[0 .. m.pcm.items.len - out.len], m.pcm.items[out.len..]);
        m.pcm.items.len -= out.len;
        return out.len;
    }
};

const Source = struct {
    ssrc: u32,
    user: Id = 0,
    dec: ?*c.OpusDecoder = null,
    pcm: std.ArrayList(i16) = .empty,
    started: bool = false,
    last_ms: i64 = 0,

    fn deinit(s: *Source) void {
        if (s.dec) |d| c.opus_decoder_destroy(d);
        s.pcm.deinit(alloc);
    }
};

const Mixer = struct {
    v: ?*Voice = null,
    mutex: Mutex = .{},
    sources: [32]?*Source = @splat(null),
    n: usize = 0,

    fn deinit(m: *Mixer) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        for (m.sources[0..m.n]) |s| {
            if (s) |src| {
                src.deinit();
                alloc.destroy(src);
            }
        }
        m.n = 0;
    }

    fn source(m: *Mixer, ssrc: u32) ?*Source {
        m.mutex.lock();
        defer m.mutex.unlock();
        for (m.sources[0..m.n]) |s| {
            if (s) |src| {
                if (src.ssrc == ssrc) return src;
            }
        }
        return null;
    }

    fn add(m: *Mixer, ssrc: u32, user: Id) ?*Source {
        m.mutex.lock();
        defer m.mutex.unlock();
        for (m.sources[0..m.n]) |s| {
            if (s) |src| {
                if (src.ssrc == ssrc) {
                    if (user != 0) src.user = user;
                    return src;
                }
            }
        }
        if (m.n >= m.sources.len) return null;
        const src = alloc.create(Source) catch return null;
        var err: c_int = 0;
        src.* = .{ .ssrc = ssrc, .user = user, .dec = c.opus_decoder_create(opus_rate, channels, &err) };
        if (err != c.OPUS_OK) {
            src.deinit();
            alloc.destroy(src);
            return null;
        }
        m.sources[m.n] = src;
        m.n += 1;
        return src;
    }

    fn map(m: *Mixer, ssrc: u32, user: Id) void {
        _ = m.add(ssrc, user);
    }

    fn removeUser(m: *Mixer, user: Id) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        for (m.sources[0..m.n]) |*slot| {
            if (slot.*) |src| {
                if (src.user == user) {
                    src.deinit();
                    alloc.destroy(src);
                    slot.* = null;
                }
            }
        }
        var w: usize = 0;
        for (m.sources[0..m.n]) |s| {
            if (s != null) {
                m.sources[w] = s;
                w += 1;
            }
        }
        m.n = w;
    }

    fn push(m: *Mixer, src: *Source, samples: []const i16) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        const max = frame_samples * channels * 6;
        if (src.pcm.items.len + samples.len > max) {
            const drop = src.pcm.items.len + samples.len - max;
            const aligned = @min(drop, src.pcm.items.len);
            std.mem.copyForwards(i16, src.pcm.items[0 .. src.pcm.items.len - aligned], src.pcm.items[aligned..]);
            src.pcm.items.len -= aligned;
        }
        src.pcm.appendSlice(alloc, samples) catch {};
        src.last_ms = nowMs();
    }

    fn render(m: *Mixer, out: []i16, deaf: bool) void {
        @memset(out, 0);
        if (deaf) return;
        m.mutex.lock();
        defer m.mutex.unlock();
        const frames = out.len / channels;
        for (m.sources[0..m.n]) |s| {
            if (s) |src| {
                var gain: f32 = 1;
                if (m.v) |v| gain = v.volumeOf(src.user);
                if (gain <= 0.001) continue;
                const avail = src.pcm.items.len / channels;
                if (!src.started) {
                    if (avail < 2) continue;
                    src.started = true;
                }
                const take = @min(frames, avail);
                if (take == 0) continue;
                for (0..take * channels) |i| {
                    const mixed = @as(i32, out[i]) + @as(i32, @intFromFloat(@as(f32, @floatFromInt(src.pcm.items[i])) * gain));
                    out[i] = @intCast(std.math.clamp(mixed, -32768, 32767));
                }
                if (take > 0) {
                    std.mem.copyForwards(i16, src.pcm.items[0 .. src.pcm.items.len - take * channels], src.pcm.items[take * channels ..]);
                    src.pcm.items.len -= take * channels;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// DAVE (libdave, C API)
// ---------------------------------------------------------------------------

const Dave = struct {
    session: c.DAVESessionHandle = null,
    encryptor: c.DAVEEncryptorHandle = null,
    version: u16 = 0,
    group: Id,
    me: Id,
    enabled: bool = false,
    pending_version: u16 = 0,
    ready: bool = false,
    users: std.AutoHashMapUnmanaged(Id, void) = .empty,
    ssrc_users: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    decryptors: std.AutoHashMapUnmanaged(u32, c.DAVEDecryptorHandle) = .empty,
    local_ssrc: u32 = 0,

    fn init(group: Id, me: Id, version: u16) ?Dave {
        var d: Dave = .{ .group = group, .me = me, .version = version, .pending_version = version };
        d.session = c.daveSessionCreate(null, "", mlsFailure, null);
        if (d.session == null) return null;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{me}, 0) catch return null;
        c.daveSessionInit(d.session, version, group, self.ptr);
        d.encryptor = c.daveEncryptorCreate();
        if (d.encryptor == null) return null;
        c.daveEncryptorAssignSsrcToCodec(d.encryptor, d.local_ssrc, c.DAVE_CODEC_OPUS);
        d.users.put(alloc, me, {}) catch {};
        return d;
    }

    fn deinit(d: *Dave) void {
        var it = d.decryptors.valueIterator();
        while (it.next()) |h| if (h.* != null) c.daveDecryptorDestroy(h.*);
        d.decryptors.deinit(alloc);
        if (d.encryptor != null) c.daveEncryptorDestroy(d.encryptor);
        if (d.session != null) c.daveSessionDestroy(d.session);
        d.users.deinit(alloc);
        d.ssrc_users.deinit(alloc);
    }

    fn mlsFailure(source: [*c]const u8, reason: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.warn("DAVE: {s} {s}", .{ std.mem.span(source), std.mem.span(reason) });
    }

    fn addUser(d: *Dave, user: Id) void {
        d.users.put(alloc, user, {}) catch {};
    }

    fn removeUser(d: *Dave, user: Id) void {
        _ = d.users.remove(user);
        var ssrcs: [64]u32 = undefined;
        var n: usize = 0;
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == user and n < ssrcs.len) {
                ssrcs[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (ssrcs[0..n]) |ssrc| {
            _ = d.ssrc_users.remove(ssrc);
            if (d.decryptors.fetchRemove(ssrc)) |x| if (x.value != null) c.daveDecryptorDestroy(x.value);
        }
    }

    fn setSsrcUser(d: *Dave, ssrc: u32, user: Id) void {
        d.ssrc_users.put(alloc, ssrc, user) catch {};
        d.ensureDecryptor(ssrc, user);
    }

    fn keyPackage(d: *Dave, out: []u8) usize {
        var p: [*c]u8 = null;
        var n: usize = 0;
        c.daveSessionGetMarshalledKeyPackage(d.session, &p, &n);
        if (p == null or n == 0) return 0;
        const len = @min(n, out.len);
        @memcpy(out[0..len], p[0..len]);
        c.daveFree(p);
        return len;
    }

    fn reinit(d: *Dave, version: u16) void {
        d.version = version;
        d.pending_version = version;
        d.enabled = false;
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        c.daveSessionInit(d.session, version, d.group, self.ptr);
        d.users.put(alloc, d.me, {}) catch {};
    }

    fn setExternalSender(d: *Dave, data: []const u8) void {
        c.daveSessionSetExternalSender(d.session, data.ptr, data.len);
    }

    fn proposals(d: *Dave, data: []const u8, out: *std.ArrayList(u8)) void {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        var n: usize = 0;
        var it = d.users.keyIterator();
        while (it.next()) |u| {
            if (n == ids.len) break;
            const s = std.fmt.bufPrintSentinel(&ids[n], "{d}", .{u.*}, 0) catch continue;
            ptrs[n] = s.ptr;
            n += 1;
        }
        var p: [*c]u8 = null;
        var len: usize = 0;
        c.daveSessionProcessProposals(d.session, data.ptr, data.len, &ptrs, n, &p, &len);
        if (p != null and len > 0) {
            out.appendSlice(alloc, p[0..len]) catch {};
            c.daveFree(p);
        }
    }

    fn commit(d: *Dave, tid: i64, data: []const u8) ?bool {
        const res = c.daveSessionProcessCommit(d.session, data.ptr, data.len);
        if (res == null) return false;
        const failed = c.daveCommitResultIsFailed(res);
        const ignored = c.daveCommitResultIsIgnored(res);
        c.daveCommitResultDestroy(res);
        if (ignored) return null;
        if (failed) return false;
        // O commit pode ter mudado os membros; ainda usamos os usuários que o
        // gateway anunciou (Clients Connect/Session Update).
        d.ready = true;
        if (tid == 0) d.complete();
        return true;
    }

    fn welcome(d: *Dave, tid: i64, data: []const u8) bool {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        var n: usize = 0;
        var it = d.users.keyIterator();
        while (it.next()) |u| {
            if (n == ids.len) break;
            const s = std.fmt.bufPrintSentinel(&ids[n], "{d}", .{u.*}, 0) catch continue;
            ptrs[n] = s.ptr;
            n += 1;
        }
        const res = c.daveSessionProcessWelcome(d.session, data.ptr, data.len, &ptrs, n);
        if (res == null) return false;
        c.daveWelcomeResultDestroy(res);
        d.ready = true;
        if (tid == 0) d.complete();
        return true;
    }

    fn prepareTransition(d: *Dave, version: u16) void {
        d.pending_version = version;
        if (version == 0) d.enabled = false;
    }

    fn executeTransition(d: *Dave, tid: i64) void {
        _ = tid;
        if (d.pending_version == 0) {
            d.enabled = false;
            return;
        }
        if (d.ready) d.complete();
    }

    fn complete(d: *Dave) void {
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        const self_ratchet = c.daveSessionGetKeyRatchet(d.session, self.ptr);
        if (self_ratchet != null) {
            c.daveEncryptorSetKeyRatchet(d.encryptor, self_ratchet);
            c.daveEncryptorAssignSsrcToCodec(d.encryptor, d.local_ssrc, c.DAVE_CODEC_OPUS);
            c.daveKeyRatchetDestroy(self_ratchet);
        }
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| d.setRatchet(kv.key_ptr.*, kv.value_ptr.*);
        d.enabled = c.daveEncryptorHasKeyRatchet(d.encryptor);
    }

    fn ensureDecryptor(d: *Dave, ssrc: u32, user: Id) void {
        if (d.decryptors.get(ssrc)) |_| {
            d.setRatchet(ssrc, user);
            return;
        }
        const dec = c.daveDecryptorCreate();
        if (dec == null) return;
        d.decryptors.put(alloc, ssrc, dec) catch {
            c.daveDecryptorDestroy(dec);
            return;
        };
        d.setRatchet(ssrc, user);
    }

    fn setRatchet(d: *Dave, ssrc: u32, user: Id) void {
        const dec = d.decryptors.get(ssrc) orelse return;
        var idbuf: [24]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{user}, 0) catch return;
        const r = c.daveSessionGetKeyRatchet(d.session, s.ptr);
        if (r == null) return;
        c.daveDecryptorTransitionToKeyRatchet(dec, r);
        c.daveKeyRatchetDestroy(r);
    }

    fn encrypt(d: *Dave, ssrc: u32, frame: []const u8, out: []u8) usize {
        const cap = c.daveEncryptorGetMaxCiphertextByteSize(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, frame.len);
        if (cap > out.len) return 0;
        var written: usize = 0;
        const rc = c.daveEncryptorEncrypt(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, ssrc, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS) return 0;
        return written;
    }

    fn decrypt(d: *Dave, ssrc: u32, frame: []const u8, out: []u8) ?usize {
        const dec = d.decryptors.get(ssrc) orelse return null;
        const cap = c.daveDecryptorGetMaxPlaintextByteSize(dec, c.DAVE_MEDIA_TYPE_AUDIO, frame.len);
        if (cap > out.len) return null;
        var written: usize = 0;
        const rc = c.daveDecryptorDecrypt(dec, c.DAVE_MEDIA_TYPE_AUDIO, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_DECRYPTOR_RESULT_CODE_SUCCESS) return null;
        return written;
    }

    fn setLocalSsrc(d: *Dave, ssrc: u32) void {
        d.local_ssrc = ssrc;
        if (d.encryptor != null) c.daveEncryptorAssignSsrcToCodec(d.encryptor, ssrc, c.DAVE_CODEC_OPUS);
    }
};
