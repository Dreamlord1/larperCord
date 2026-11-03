//! Conexão real com o Discord: gateway (WebSocket) + REST, numa thread.
//! Implementa a mesma interface do gateway falso: recebe `Command` e entrega
//! `Event` no `Sink`, então o resto do app não sabe a diferença.
//!
//! Cuidados:
//!  - o token nunca vai para log, erro ou arquivo; é zerado ao sair;
//!  - uma requisição REST por vez, respeitando `retry_after` quando vier 429;
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
const gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json";
const user_agent = "larperCord/0.3 (https://github.com/RshaCuDeVidro/larperCord)";

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

    pub fn start(g: *Gateway) !void {
        g.thread = c.SDL_CreateThread(threadMain, "discord", g) orelse return error.SdlThread;
    }

    pub fn stop(g: *Gateway) void {
        g.commands.push(.shutdown);
        if (g.thread) |t| c.SDL_WaitThread(t, null);
        std.crypto.secureZero(u8, g.token);
        alloc.free(g.token);
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
            g.emit(.{ .status = .connecting });
            const result = g.session();
            if (g.ws) |h| {
                c.curl_easy_cleanup(h);
                g.ws = null;
            }
            if (g.stopping) break;
            switch (result) {
                .fatal => {
                    g.emit(.{ .status = .failed });
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
            }
        }
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
                else => freeCommand(cmd),
            };
            cmds.clearRetainingCapacity();
        }
    }

    const End = enum { retry, reconnect, fatal };

    fn session(g: *Gateway) End {
        const h = c.curl_easy_init() orelse return .retry;
        g.ws = h;
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, gateway_url);
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, user_agent);
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 15));
        if (c.curl_easy_perform(h) != c.CURLE_OK) return .retry;
        var sock: c.curl_socket_t = -1;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        g.seq = null;
        g.acked = true;
        g.next_hb = std.math.maxInt(i64);
        g.frame.clearRetainingCapacity();

        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            // Comandos do app (REST).
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
                g.frame.appendSlice(alloc, buf[0..got]) catch return .retry;
                if (meta.*.bytesleft == 0 and meta.*.flags & c.CURLWS_CONT == 0) {
                    const end = g.onPayload(g.frame.items);
                    g.frame.clearRetainingCapacity();
                    if (end) |e| return e;
                }
            }

            if (nowMs() >= g.next_hb) {
                if (!g.acked) return .reconnect; // conexão "zumbi"
                g.heartbeat();
            }
        }
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
            else => return .retry,
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

    fn identify(g: *Gateway) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        out.appendSlice(alloc, "{\"op\":2,\"d\":{\"token\":") catch return;
        j.writeString(&out, alloc, g.token) catch return;
        out.appendSlice(alloc, ",\"capabilities\":0,\"compress\":false,\"properties\":{\"os\":\"linux\",\"browser\":\"larperCord\",\"device\":\"larperCord\"},\"presence\":{\"status\":\"online\",\"since\":0,\"activities\":[],\"afk\":false}}}") catch return;
        g.send(out.items);
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
                // Primeiro heartbeat com atraso aleatório, como manda a documentação.
                var prng = std.Random.DefaultPrng.init(@bitCast(nowMs()));
                g.next_hb = nowMs() + @as(i64, @intFromFloat(@as(f64, @floatFromInt(g.hb_interval)) * prng.random().float(f64)));
                g.identify();
            },
            11 => {
                g.acked = true;
                g.emit(.{ .latency = @intCast(@max(0, nowMs() - g.hb_sent_at)) });
            },
            1 => g.heartbeat(),
            7 => return .reconnect,
            9 => {
                g.sleepServing(2000);
                return .reconnect;
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
            const st = std.meta.stringToEnum(types.Status, j.str(j.get(d, "status")) orelse "offline") orelse .offline;
            g.emit(.{ .presence_update = .{ .user = j.id(j.get(u, "id")) orelse return, .status = st } });
            return;
        }
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

    fn writeCb(ptr: [*c]u8, size: usize, n: usize, user: ?*anyopaque) callconv(.c) usize {
        const body: *std.ArrayList(u8) = @ptrCast(@alignCast(user.?));
        body.appendSlice(alloc, ptr[0 .. size * n]) catch return 0;
        return size * n;
    }

    fn request(g: *Gateway, method: [:0]const u8, path: []const u8, body: ?[]const u8) ?Response {
        const h = g.rest orelse return null;
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrintSentinel(&url_buf, "{s}{s}", .{ api, path }, 0) catch return null;
        var auth_buf: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_buf);
        const auth = std.fmt.bufPrintSentinel(&auth_buf, "Authorization: {s}", .{g.token}, 0) catch return null;

        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            var headers: ?*c.struct_curl_slist = null;
            headers = c.curl_slist_append(headers, auth.ptr);
            headers = c.curl_slist_append(headers, "Content-Type: application/json");
            defer c.curl_slist_free_all(headers);
            var resp: Response = .{ .status = 0, .body = .empty };
            c.curl_easy_reset(h);
            _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
            _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, headers);
            _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, user_agent);
            _ = c.curl_easy_setopt(h, c.CURLOPT_CUSTOMREQUEST, method.ptr);
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
            _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &resp.body);
            _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, 20));
            _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
            if (body) |b| {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, b.ptr);
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
            } else if (std.mem.eql(u8, method, "PUT")) {
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, "");
                _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
            }
            if (c.curl_easy_perform(h) != c.CURLE_OK) {
                resp.body.deinit(alloc);
                g.notice("sem conexão com a API do Discord", .{});
                return null;
            }
            _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &resp.status);
            if (resp.status != 429) return resp;
            // Rate limit: espera o que o Discord pediu e tenta de novo.
            var wait_ms: u32 = 1000;
            if (std.json.parseFromSlice(Value, alloc, resp.body.items, .{})) |parsed| {
                defer parsed.deinit();
                if (j.get(parsed.value, "retry_after")) |ra| switch (ra) {
                    .float => |f| wait_ms = @intFromFloat(@min(f, 30) * 1000),
                    .integer => |i| wait_ms = @intCast(@min(i, 30) * 1000),
                    else => {},
                };
            } else |_| {}
            resp.body.deinit(alloc);
            g.notice("o Discord pediu calma: esperando {d} ms", .{wait_ms});
            g.sleepServing(wait_ms + 100);
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
                    if (resp.status == 403) g.notice("sem permissão para ler esse canal", .{});
                    return g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
                }
                g.history(ch, resp.body.items) catch g.emit(.{ .history = .{ .channel = ch, .messages = &.{} } });
            },
            .send_message => |m| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"content\":") catch return;
                j.writeString(&b, alloc, m.content) catch return;
                b.print(alloc, ",\"nonce\":\"{d}\"", .{m.nonce}) catch return;
                if (m.reply_to != 0) b.print(alloc, ",\"message_reference\":{{\"message_id\":\"{d}\"}}", .{m.reply_to}) catch return;
                b.append(alloc, '}') catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages", .{m.channel}) catch return;
                var resp = g.request("POST", path, b.items) orelse return;
                defer resp.body.deinit(alloc);
                if (resp.status >= 300) g.notice("não foi possível enviar (HTTP {d})", .{resp.status});
            },
            .edit_message => |m| {
                var b: std.ArrayList(u8) = .empty;
                defer b.deinit(alloc);
                b.appendSlice(alloc, "{\"content\":") catch return;
                j.writeString(&b, alloc, m.content) catch return;
                b.append(alloc, '}') catch return;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}", .{ m.channel, m.id }) catch return;
                var resp = g.request("PATCH", path, b.items) orelse return;
                resp.body.deinit(alloc);
            },
            .delete_message => |m| {
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}", .{ m.channel, m.id }) catch return;
                var resp = g.request("DELETE", path, null) orelse return;
                resp.body.deinit(alloc);
            },
            .react => |r| {
                var enc: [64]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "/channels/{d}/messages/{d}/reactions/{s}/@me", .{ r.channel, r.id, j.urlEncode(&enc, r.emoji.text()) }) catch return;
                var resp = g.request(if (r.add) "PUT" else "DELETE", path, null) orelse return;
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
