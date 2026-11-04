//! Gateway falso: roda numa thread e se comporta como o do Discord, emitindo
//! READY, histórico sob demanda, mensagens novas, "digitando", presença e
//! latência. Quando o gateway real existir, ele implementa a mesma interface
//! (recebe `Command`, entrega `Event` no `Sink`) e o resto do app não muda.
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Queue = @import("queue.zig").Queue;
const i18n = @import("../ui/i18n.zig");
const leitura = @import("../core/leitura.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

pub const Sink = struct {
    ctx: *anyopaque,
    push: *const fn (ctx: *anyopaque, event: ev.Event) void,
};

/// O que a demonstração "mandou para o Discord" (o QA confere; não há servidor
/// para perguntar). Lido da thread da interface.
pub const sent = struct {
    const A = std.atomic.Value(u64);
    pub var acks: A = .init(0);
    pub var ack_channel: A = .init(0);
    pub var ack_message: A = .init(0);
    pub var ack_viewed: A = .init(0);
    pub var manual_acks: A = .init(0);
    pub var manual_message: A = .init(0);
    pub var bulks: A = .init(0);
    pub var bulk_len: A = .init(0);
    pub var arounds: A = .init(0);
    pub var pin_ops: A = .init(0);
    pub var pin_fetches: A = .init(0);
    pub var invite_fetches: A = .init(0);
};

pub const Gateway = struct {
    commands: Queue(ev.Command),
    sink: Sink,
    thread: ?*c.SDL_Thread = null,
    live: bool,
    rng: std.Random.DefaultPrng,
    hot_channel: Id = 0,
    last_live: Id = 0,
    next_live_ms: i64 = 0,
    pending_typing: ?struct { channel: Id, user: Id, at_ms: i64 } = null,
    next_latency_ms: i64 = 0,
    nonce_replies: std.ArrayList(struct { at_ms: i64, msg: types.Message }) = .empty,
    history_replies: std.ArrayList(struct { at_ms: i64, channel: Id }) = .empty,
    /// Servidores cujos cargos já foram mandados.
    roles_sent: u64 = 0,
    /// LARPER_FLOOD=N: N trocas de presença por segundo (teste de carga,
    /// como um servidor grande).
    flood_per_s: u32 = 0,
    next_flood_ms: i64 = std.math.maxInt(i64),
    /// Começo da sessão: o histórico de um canal é sempre o mesmo dentro
    /// dela (mesmos IDs, como no Discord), mesmo pedido de novo.
    epoch_ms: i64 = 0,
    /// A mesma fila do gateway de verdade (um ack por canal a cada ~3 s).
    acks: leitura.AckQueue = .{},
    /// Fixadas da demonstração, por canal (preenche ao primeiro uso).
    pins: std.ArrayList(struct { channel: Id, id: Id }) = .empty,
    pins_seeded: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// As menções recentes que foram mostradas: a busca em volta traz as mesmas.
    mention_log: []types.Message = &.{},

    pub fn start(g: *Gateway) !void {
        g.thread = c.SDL_CreateThread(threadMain, "gateway", g) orelse return error.SdlThread;
    }

    pub fn stop(g: *Gateway) void {
        g.commands.push(.shutdown);
        if (g.thread) |t| c.SDL_WaitThread(t, null);
    }

    fn emit(g: *Gateway, e: ev.Event) void {
        g.sink.push(g.sink.ctx, e);
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const g: *Gateway = @ptrCast(@alignCast(data.?));
        g.run() catch |err| std.log.err("gateway: {t}", .{err});
        return 0;
    }

    fn run(g: *Gateway) !void {
        g.epoch_ms = nowMs();
        g.emit(.{ .ready = try buildReady() });
        g.emit(.{ .read_states = .{ .entries = try demoReadStates(g.epoch_ms) } });
        // O @everyone do segundo servidor (que não é nosso): com ele, o #bugs
        // e o AFK de lá aparecem trancados (demoOverwrites).
        {
            const rs = try alloc.alloc(types.Role, 1);
            rs[0] = .{ .id = guildId(1), .guild = guildId(1), .name = try alloc.dupe(u8, "@everyone"), .permissions = types.perm.view_channel | types.perm.send_messages | types.perm.read_history | types.perm.connect };
            g.emit(.{ .roles = .{ .guild = guildId(1), .roles = rs } });
        }
        for (relations, 0..) |rel, i| g.emit(.{ .relationship = .{ .user = rel.user, .kind = rel.kind, .since_ms = nowMs() - @as(i64, @intCast(i + 1)) * 97 * 86_400_000 } });
        try g.demoActivities();
        g.emit(.{ .guild_folders = try demoFolders() });
        g.emit(.{ .status = .ready });
        g.next_live_ms = nowMs() + 6000;
        if (c.SDL_getenv("LARPER_FLOOD")) |f| {
            g.flood_per_s = std.fmt.parseInt(u32, std.mem.span(f), 10) catch 0;
            if (g.flood_per_s > 0) g.next_flood_ms = nowMs() + 500;
        }
        g.next_latency_ms = nowMs() + 1500;

        var cmds: std.ArrayList(ev.Command) = .empty;
        defer cmds.deinit(alloc);
        while (true) {
            const now = nowMs();
            const wait: i32 = @intCast(std.math.clamp(g.nextDeadline() - now, 1, 2000));
            g.commands.waitDrain(&cmds, wait);
            for (cmds.items) |cmd| switch (cmd) {
                .shutdown => return,
                .send_message => |m| {
                    // Os arquivos já aparecem na cópia pendente (o Store
                    // mantém os anexos dela na confirmação).
                    for (m.files) |f| alloc.free(f);
                    if (m.files.len > 0) alloc.free(m.files);
                    // O "servidor" confirma depois de um RTT simulado.
                    try g.nonce_replies.append(alloc, .{ .at_ms = nowMs() + 90, .msg = .{
                        .id = types.makeSnowflake(nowMs(), g.rng.random().int(u22)),
                        .channel = m.channel,
                        .author = me_id,
                        .timestamp = @divTrunc(nowMs(), 1000),
                        .content = m.content,
                        .nonce = m.nonce,
                        .reply_to = m.reply_to,
                    } });
                },
                .edit_message => |m| g.emit(.{ .message_update = .{ .channel = m.channel, .id = m.id, .content = m.content } }),
                .delete_message => |m| g.emit(.{ .message_delete = .{ .channel = m.channel, .id = m.id } }),
                .react => |r| g.emit(.{ .reaction = .{ .channel = r.channel, .id = r.id, .emoji = r.emoji, .user = me_id, .add = r.add } }),
                .fetch_history => |ch| {
                    g.hot_channel = ch;
                    try g.history_replies.append(alloc, .{ .at_ms = nowMs() + 140, .channel = ch });
                },
                .typing => {},
                .fetch_older => |o| {
                    const msgs = try buildOlder(o.channel, o.before);
                    // Duas semanas para trás é o "começo do canal" na demonstração.
                    const more = @divTrunc(nowMs(), 1000) - msgs[0].timestamp < 14 * 86400;
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = msgs, .older = true, .more = more } });
                },
                .subscribe_guild => |sg| try g.memberList(sg.guild),
                .relationship => |r| g.emit(.{ .relationship = .{ .user = r.user, .kind = if (r.accept) .friend else .none } }),
                .fetch_profile => |fp| {
                    const seed = for (users) |x| {
                        if (x.id == fp.user) break x;
                    } else continue;
                    // Servidores em comum: os da demonstração em que a pessoa está.
                    var mg: std.ArrayList(Id) = .empty;
                    for (guilds, 0..) |_, gi| if (fp.user == me_id or (fp.user * 7 + gi) % 5 != 0) try mg.append(alloc, guildId(gi));
                    var mf: std.ArrayList(Id) = .empty;
                    for (relations) |rel| if (rel.kind == .friend and rel.user != fp.user and (rel.user + fp.user) % 3 != 0) try mf.append(alloc, rel.user);
                    const cns = try alloc.alloc(types.Connection, 2);
                    cns[0] = .{ .kind = try alloc.dupe(u8, "github"), .name = try alloc.dupe(u8, seed.name), .url = try std.fmt.allocPrint(alloc, "https://github.com/{s}", .{seed.name}) };
                    cns[1] = .{ .kind = try alloc.dupe(u8, "steam"), .name = try alloc.dupe(u8, seed.name), .url = "" };
                    const nf: u32 = @intCast(mf.items.len);
                    g.emit(.{ .profile = .{ .user = fp.user, .profile = .{
                        .banner = if (fp.user % 2 == 1) try alloc.dupe(u8, "demo:1") else "",
                        .accent = 0x5865F2,
                        .bio = try i18n.allocPrint(alloc, "oi! sou **{s}** 👋\nfalo de zig, rice e café.", "hi! I'm **{s}** 👋\ninto zig, ricing and coffee.", .{seed.name}),
                        .pronouns = try alloc.dupe(u8, if (fp.user % 3 == 0) "ela/dela" else "ele/dele"),
                        .username = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ seed.name, fp.user % 100 }),
                        .guild = fp.guild,
                        .joined_ms = if (fp.guild != 0) nowMs() - @as(i64, @intCast(fp.user % 40 + 3)) * 30 * 86_400_000 else 0,
                        .mutual_guilds = try mg.toOwnedSlice(alloc),
                        .mutual_friends = try mf.toOwnedSlice(alloc),
                        .mutual_friends_count = nf,
                        .connections = cns,
                    } } });
                    if (fp.user == 1001) g.emit(.{ .note = .{ .user = fp.user, .text = try i18n.allocPrint(alloc, "conheci na game jam", "met at the game jam", .{}) } });
                },
                .member_role => {},
                .set_note => |n| alloc.free(n.text),
                .move_member => |mm| g.emit(.{ .voice_state = .{ .channel = mm.channel, .user = mm.user } }),
                .fetch_app => |app| g.emit(.{ .app_icon = .{ .app = app, .icon = "" } }),
                .set_status => |st| g.emit(.{ .presence_update = .{ .user = me_id, .status = st } }),
                .create_dm => |u| {
                    const seed = for (users) |x| {
                        if (x.id == u) break x;
                    } else continue;
                    g.emit(.{ .channel_upsert = .{
                        .id = 900_100 + u,
                        .guild = 0,
                        .name = try alloc.dupe(u8, seed.name),
                        .topic = try alloc.dupe(u8, ""),
                        .recipient = u,
                    } });
                },
                .join_voice => |v| {
                    g.emit(.{ .voice_state = .{ .channel = v.channel, .user = me_id } });
                    g.emit(.{ .voice_status = .{ .status = if (v.channel != null) .connected else .disconnected, .channel = v.channel orelse 0 } });
                },
                .voice_flags, .voice_volume => {},
                .fetch_mentions => {
                    const t = nowMs();
                    if (g.mention_log.len > 0) freeMessages(g.mention_log);
                    g.mention_log = try demoMentions(t);
                    g.emit(.{ .recent_mentions = try demoMentions(t) });
                },
                .ack => |a| {
                    if (!a.manual) {
                        g.acks.push(alloc, .{ .channel = a.channel, .message = a.message, .last_viewed = a.last_viewed });
                        continue;
                    }
                    g.acks.cancel(alloc, a.channel, nowMs());
                    _ = sent.manual_acks.fetchAdd(1, .monotonic);
                    sent.manual_message.store(a.message, .monotonic);
                    g.emit(.{ .read = .{ .channel = a.channel, .message = a.message, .mentions = a.mentions, .manual = true } });
                },
                .ack_bulk => |list| {
                    _ = sent.bulks.fetchAdd(1, .monotonic);
                    sent.bulk_len.store(list.len, .monotonic);
                    for (list) |e| {
                        g.acks.cancel(alloc, e[0], nowMs());
                        g.emit(.{ .read = .{ .channel = e[0], .message = e[1] } });
                    }
                    if (list.len > 0) alloc.free(list);
                },
                .fetch_around => |o| {
                    _ = sent.arounds.fetchAdd(1, .monotonic);
                    const page = try buildAround(o.channel, o.id, g.epoch_ms);
                    g.placeMention(page, o.id);
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = page, .around = true, .more = true } });
                },
                .fetch_newer => |o| {
                    const page = try buildNewer(o.channel, o.after, g.epoch_ms);
                    g.emit(.{ .history = .{ .channel = o.channel, .messages = page.msgs, .newer = true, .more = page.more } });
                },
                .fetch_pins => |channel| {
                    _ = sent.pin_fetches.fetchAdd(1, .monotonic);
                    try g.seedPins(channel);
                    g.emit(.{ .pins = .{ .channel = channel, .messages = try g.buildPins(channel) } });
                },
                .pin => |p| {
                    _ = sent.pin_ops.fetchAdd(1, .monotonic);
                    try g.seedPins(p.channel);
                    for (g.pins.items, 0..) |x, i| if (x.channel == p.channel and x.id == p.id) {
                        _ = g.pins.orderedRemove(i);
                        break;
                    };
                    if (p.add) try g.pins.append(alloc, .{ .channel = p.channel, .id = p.id });
                    g.emit(.{ .message_update = .{ .channel = p.channel, .id = p.id, .content = null, .pinned = p.add } });
                    g.emit(.{ .pins_changed = p.channel });
                },
                .fetch_invite => |code| {
                    _ = sent.invite_fetches.fetchAdd(1, .monotonic);
                    g.emit(.{ .invite = .{ .code = code, .invite = try demoInvite(code.slice()) } });
                },
            };
            cmds.clearRetainingCapacity();
            try g.tick(nowMs());
        }
    }

    /// Jogos da demonstração (com tempo de jogo, para o cartão de perfil).
    fn demoActivities(g: *Gateway) !void {
        const list = [_]struct { user: Id, name: []const u8, details: []const u8, mins: i64 }{
            .{ .user = 1002, .name = "Hollow Knight", .details = "Cidade das Lágrimas", .mins = 68 },
            .{ .user = 1007, .name = "Minecraft", .details = "Survival com a galera", .mins = 23 },
        };
        for (list, 0..) |a, i| {
            const acts = try alloc.alloc(types.Activity, 1);
            acts[0] = .{
                .name = try alloc.dupe(u8, a.name),
                .details = try alloc.dupe(u8, a.details),
                .start_ms = nowMs() - a.mins * 60_000,
                .image = try std.fmt.allocPrint(alloc, "demo:icon:{d}", .{i + 1}),
            };
            const u = for (users) |x| {
                if (x.id == a.user) break x;
            } else continue;
            g.emit(.{ .presence_update = .{ .user = a.user, .status = u.status, .activities = acts } });
        }
    }

    /// Lista de membros de um servidor da demonstração, no formato do
    /// GUILD_MEMBER_LIST_UPDATE: online por cargo em destaque, depois offline.
    fn memberList(g: *Gateway, gid: Id) !void {
        if (gid < guildId(0)) return;
        const gi: usize = @intCast((gid - guildId(0)) / 1000);
        if (gi >= guilds.len) return;
        const role_ids = [_]Id{ gid + 901, gid + 902, gid + 903 };
        if (g.roles_sent & (@as(u64, 1) << @intCast(gi)) == 0) {
            g.roles_sent |= @as(u64, 1) << @intCast(gi);
            const rs = try alloc.alloc(types.Role, demo_roles.len);
            for (demo_roles, 0..) |r, i| rs[i] = .{ .id = role_ids[i], .guild = gid, .name = try alloc.dupe(u8, pick(r.name, r.name_en)), .color = r.color, .position = @intCast(3 - i) };
            g.emit(.{ .roles = .{ .guild = gid, .roles = rs } });
        }
        // Quem está neste servidor e em qual cargo (0 = fundação, 1 = moderação, 2 = membro).
        var rank: [users.len]?u8 = @splat(null);
        for (users, 0..) |u, i| {
            if (u.id != me_id and (u.id * 7 + gi) % 5 == 0) continue;
            rank[i] = if (u.id == 1001 or (u.id == me_id and gi == 0)) 0 else if ((u.id + gi) % 3 == 0) 1 else 2;
        }
        var items: std.ArrayList(types.MemberItem) = .empty;
        defer items.deinit(alloc);
        var online: u32 = 0;
        var total: u32 = 0;
        // Grupos online (cargos 0 e 1 em destaque; o 2 cai em "online").
        for ([_]u8{ 0, 1, 2 }) |want| {
            var count: u32 = 0;
            for (users, 0..) |u, i| if (rank[i] == want and u.status != .offline) {
                count += 1;
            };
            if (count == 0) continue;
            try items.append(alloc, .{ .group = .{ .id = if (want == 2) types.group_online else role_ids[want], .count = count } });
            for (users, 0..) |u, i| if (rank[i] == want and u.status != .offline) {
                try items.append(alloc, .{ .member = .{ .user = u.id, .info = demoInfo(role_ids, want) } });
            };
            online += count;
        }
        var offline: u32 = 0;
        for (users, 0..) |u, i| if (rank[i] != null and u.status == .offline) {
            offline += 1;
        };
        if (offline > 0) {
            try items.append(alloc, .{ .group = .{ .id = types.group_offline, .count = offline } });
            for (users, 0..) |u, i| if (rank[i] != null and u.status == .offline) {
                try items.append(alloc, .{ .member = .{ .user = u.id, .info = demoInfo(role_ids, rank[i].?) } });
            };
        }
        total = online + offline;
        const ops = try alloc.alloc(types.MemberOp, 1);
        ops[0] = .{ .kind = .sync, .index = 0, .end = 99, .items = try alloc.dupe(types.MemberItem, items.items) };
        g.emit(.{ .member_list = .{ .guild = gid, .list_id = gid, .online = online, .total = total, .ops = ops } });
    }

    fn demoInfo(role_ids: [3]Id, rank: u8) types.MemberInfo {
        var info: types.MemberInfo = .{ .color = demo_roles[rank].color };
        // Todo mundo tem "Membros"; quem está acima tem também o próprio cargo.
        if (rank < 2) {
            info.roles[0] = role_ids[rank];
            info.n_roles = 1;
        }
        info.roles[info.n_roles] = role_ids[2];
        info.n_roles += 1;
        return info;
    }

    fn nextDeadline(g: *Gateway) i64 {
        var d = @min(@min(g.next_live_ms, g.next_latency_ms), g.next_flood_ms);
        if (g.pending_typing) |t| d = @min(d, t.at_ms);
        for (g.nonce_replies.items) |r| d = @min(d, r.at_ms);
        for (g.history_replies.items) |r| d = @min(d, r.at_ms);
        return @min(d, g.acks.nextDue());
    }

    /// Os acks que já podem sair, com o eco que o Discord manda de volta.
    fn flushAcks(g: *Gateway, now: i64) void {
        while (g.acks.take(now)) |a| {
            _ = sent.acks.fetchAdd(1, .monotonic);
            sent.ack_channel.store(a.channel, .monotonic);
            sent.ack_message.store(a.message, .monotonic);
            sent.ack_viewed.store(a.last_viewed, .monotonic);
            g.emit(.{ .read = .{ .channel = a.channel, .message = a.message } });
        }
    }

    /// A menção recente (que não existe no histórico inventado) aparece na
    /// página com o texto que a caixa de entrada mostrou.
    fn placeMention(g: *Gateway, page: []types.Message, id: Id) void {
        for (g.mention_log) |ml| {
            if (ml.id != id) continue;
            var at: usize = 0;
            for (page, 0..) |m, i| if (m.id <= id) {
                at = i;
            };
            if (page.len == 0) return;
            const text = alloc.dupe(u8, ml.content) catch return;
            freeOne(page[at]);
            page[at] = .{ .id = id, .channel = ml.channel, .author = ml.author, .timestamp = ml.timestamp, .content = text };
            return;
        }
    }

    /// Duas recentes e uma antiga (fora do que carrega ao abrir).
    fn seedPins(g: *Gateway, channel: Id) !void {
        const gop = try g.pins_seeded.getOrPut(alloc, channel);
        if (gop.found_existing) return;
        const latest = try buildHistory(channel, g.epoch_ms);
        defer freeMessages(latest);
        try g.pins.append(alloc, .{ .channel = channel, .id = oldPinId(channel, g.epoch_ms) });
        for (pinned_backs) |back| try g.pins.append(alloc, .{ .channel = channel, .id = latest[latest.len - back].id });
    }

    /// As fixadas do canal, da última fixada para a primeira, como a API manda.
    fn buildPins(g: *Gateway, channel: Id) ![]types.Message {
        const latest = try buildHistory(channel, g.epoch_ms);
        defer freeMessages(latest);
        var out: std.ArrayList(types.Message) = .empty;
        var i = g.pins.items.len;
        while (i > 0) {
            i -= 1;
            const p = g.pins.items[i];
            if (p.channel != channel) continue;
            const from = for (latest) |m| {
                if (m.id == p.id) break m;
            } else null;
            if (from) |m| {
                try out.append(alloc, .{ .id = m.id, .channel = channel, .author = m.author, .timestamp = m.timestamp, .content = try alloc.dupe(u8, m.content), .pinned = true });
            } else {
                var m = try syntheticAt(channel, p.id, g.epoch_ms);
                m.pinned = true;
                try out.append(alloc, m);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    fn tick(g: *Gateway, now: i64) !void {
        g.flushAcks(now);
        var i: usize = 0;
        while (i < g.nonce_replies.items.len) {
            const r = g.nonce_replies.items[i];
            if (r.at_ms <= now) {
                g.emit(.{ .message_create = r.msg });
                _ = g.nonce_replies.orderedRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < g.history_replies.items.len) {
            const r = g.history_replies.items[i];
            if (r.at_ms <= now) {
                const msgs = try buildHistory(r.channel, g.epoch_ms);
                g.emit(.{ .history = .{ .channel = r.channel, .messages = msgs, .more = msgs.len > 0 } });
                // Algumas reações nas mensagens recentes.
                var prng = std.Random.DefaultPrng.init(r.channel ^ 0xABCD);
                const rr = prng.random();
                var k: usize = 0;
                while (k < 24) : (k += 1) {
                    const mi = msgs.len - 1 - rr.uintLessThan(usize, @min(msgs.len, 60));
                    const emoji = reaction_pool[rr.uintLessThan(usize, reaction_pool.len)];
                    const n = 1 + rr.uintLessThan(usize, 4);
                    for (0..n) |u| g.emit(.{ .reaction = .{ .channel = r.channel, .id = msgs[mi].id, .emoji = types.Reaction.init(emoji), .user = users[1 + (u + mi) % 7].id, .add = true } });
                }
                _ = g.history_replies.orderedRemove(i);
            } else i += 1;
        }
        if (now >= g.next_flood_ms) {
            // Em rajadas de 10 ms, como chegam do gateway de verdade.
            const n = @max(1, g.flood_per_s / 100);
            const r = g.rng.random();
            for (0..n) |_| {
                const who = users[1 + r.uintLessThan(usize, users.len - 1)].id;
                g.emit(.{ .presence_update = .{ .user = who, .status = @enumFromInt(r.uintLessThan(u8, 3)) } });
            }
            g.next_flood_ms = now + 10;
        }
        if (now >= g.next_latency_ms) {
            g.emit(.{ .latency = 38 + g.rng.random().uintLessThan(u32, 24) });
            g.next_latency_ms = now + 20_000;
        }
        if (!g.live) {
            g.next_live_ms = std.math.maxInt(i64) / 2;
            return;
        }
        // Alguém começa a digitar e, pouco depois, manda a mensagem.
        if (g.pending_typing) |t| {
            if (now >= t.at_ms) {
                const r = g.rng.random();
                const id = types.makeSnowflake(now, r.int(u22));
                g.emit(.{ .message_create = .{
                    .id = id,
                    .channel = t.channel,
                    .author = t.user,
                    .timestamp = @divTrunc(now, 1000),
                    .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
                    .reply_to = if (r.uintLessThan(u8, 3) == 0) g.last_live else 0,
                } });
                g.last_live = id;
                g.pending_typing = null;
                g.next_live_ms = now + r.intRangeLessThan(i64, 7000, 16000);
            }
        } else if (now >= g.next_live_ms and g.hot_channel != 0) {
            const r = g.rng.random();
            const user = if (dmRecipient(g.hot_channel)) |u| u else users[1 + r.uintLessThan(usize, 7)].id;
            g.emit(.{ .typing_start = .{ .channel = g.hot_channel, .user = user } });
            g.pending_typing = .{ .channel = g.hot_channel, .user = user, .at_ms = now + r.intRangeLessThan(i64, 2200, 4000) };
            if (r.uintLessThan(u8, 4) == 0) {
                const who = users[1 + r.uintLessThan(usize, users.len - 1)].id;
                const st: types.Status = @enumFromInt(r.uintLessThan(u8, 3));
                g.emit(.{ .presence_update = .{ .user = who, .status = st } });
            }
        }
    }
};

pub fn nowMs() i64 {
    var t: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&t);
    return @divTrunc(t, 1_000_000);
}

// --- Dados de demonstração -------------------------------------------------
//
// Os textos têm versão em inglês ao lado (`*_en`), escolhida na hora em que o
// READY ou o histórico é montado. Nomes, ids, ordem e sorteios são os mesmos
// nos dois idiomas: só muda o texto.

/// O texto no idioma atual: `en` quando existir e a interface estiver em inglês.
fn pick(pt: []const u8, en: ?[]const u8) []const u8 {
    return if (i18n.en()) en orelse pt else pt;
}

const me_id: Id = 1000;

const UserSeed = struct { id: Id, name: []const u8, role: u8, status: types.Status, activity: ?[]const u8 = null, activity_en: ?[]const u8 = null, avatar: bool = false };

const users = [_]UserSeed{
    .{ .id = 1000, .name = "rsha", .role = 0, .status = .online, .activity = "Programando em Zig", .activity_en = "Coding in Zig", .avatar = true },
    .{ .id = 1001, .name = "ana.exe", .role = 1, .status = .online, .activity = "Ouvindo Spotify", .activity_en = "Listening to Spotify", .avatar = true },
    .{ .id = 1002, .name = "brunão", .role = 2, .status = .dnd, .activity = "Jogando Hollow Knight", .activity_en = "Playing Hollow Knight", .avatar = true },
    .{ .id = 1003, .name = "kaique", .role = 3, .status = .online },
    .{ .id = 1004, .name = "lulu", .role = 4, .status = .idle, .activity = "Assistindo YouTube", .activity_en = "Watching YouTube", .avatar = true },
    .{ .id = 1005, .name = "duda", .role = 5, .status = .online, .activity = "No Hyprland 🌸", .activity_en = "On Hyprland 🌸", .avatar = true },
    .{ .id = 1006, .name = "thiaguinho", .role = 6, .status = .idle },
    .{ .id = 1007, .name = "mari", .role = 7, .status = .online, .activity = "Jogando Minecraft", .activity_en = "Playing Minecraft", .avatar = true },
    .{ .id = 1008, .name = "gustavo", .role = 2, .status = .offline },
    .{ .id = 1009, .name = "nanda", .role = 3, .status = .offline, .avatar = true },
    .{ .id = 1010, .name = "pedro", .role = 5, .status = .offline },
    .{ .id = 1011, .name = "joão vitor", .role = 1, .status = .offline },
};

const GuildSeed = struct { name: []const u8, acronym: []const u8, color: u8, name_en: ?[]const u8 = null, acronym_en: ?[]const u8 = null, icon: bool = false };

/// Cargos de cada servidor da demonstração (cor 0 = sem cor).
const demo_roles = [_]struct { name: []const u8, name_en: []const u8, color: u32 }{
    .{ .name = "Fundação", .name_en = "Founders", .color = 0xF0B232 },
    .{ .name = "Moderação", .name_en = "Moderators", .color = 0x3BA55C },
    .{ .name = "Membros", .name_en = "Members", .color = 0 },
};

/// Amigos, pedidos e bloqueados da demonstração.
const relations = [_]struct { user: Id, kind: types.Relationship }{
    .{ .user = 1001, .kind = .friend },
    .{ .user = 1002, .kind = .friend },
    .{ .user = 1003, .kind = .friend },
    .{ .user = 1004, .kind = .friend },
    .{ .user = 1005, .kind = .friend },
    .{ .user = 1007, .kind = .friend },
    .{ .user = 1008, .kind = .friend },
    .{ .user = 1010, .kind = .friend },
    .{ .user = 1009, .kind = .incoming },
    .{ .user = 1006, .kind = .outgoing },
    .{ .user = 1011, .kind = .blocked },
};

/// Grupo da demonstração (canal 900_006): DM com três pessoas.
const group_members = [_]Id{ 1001, 1003, 1005 };
const group_id: Id = 900_006;

const guilds = [_]GuildSeed{
    .{ .name = "larperCord dev", .acronym = "LC", .color = 0 },
    .{ .name = "Rice do Hyprland", .acronym = "RH", .color = 4, .name_en = "Hyprland Rice", .acronym_en = "HR", .icon = true },
    .{ .name = "Zig Brasil", .acronym = "Z", .color = 1, .name_en = "Zig Brazil", .icon = true },
    .{ .name = "os larpers", .acronym = "ol", .color = 3, .name_en = "the larpers", .acronym_en = "tl" },
    .{ .name = "CTF da madrugada", .acronym = "CTF", .color = 6, .name_en = "Late-night CTF", .icon = true },
    .{ .name = "Faculdade 2026", .acronym = "F26", .color = 2, .name_en = "College 2026", .acronym_en = "C26" },
    .{ .name = "Minecraft SMP", .acronym = "MC", .color = 7, .icon = true },
    .{ .name = "Lo-fi & café", .acronym = "☕", .color = 5, .name_en = "Lo-fi & coffee" },
    .{ .name = "Arch Linux BR", .acronym = "A", .color = 4 },
    .{ .name = "Memes", .acronym = "😂", .color = 1 },
};

const ChannelSeed = struct { name: []const u8, kind: types.ChannelKind = .text, topic: []const u8 = "", name_en: ?[]const u8 = null, topic_en: ?[]const u8 = null };

const channel_tree = [_]ChannelSeed{
    .{ .name = "informações", .kind = .category, .name_en = "info" },
    .{ .name = "regras", .topic = "leia antes de postar", .name_en = "rules", .topic_en = "read before posting" },
    .{ .name = "anúncios", .topic = "novidades do servidor", .name_en = "announcements", .topic_en = "server news" },
    .{ .name = "geral", .kind = .category, .name_en = "general" },
    .{ .name = "geral", .topic = "papo livre, sem spam 🙏", .name_en = "general", .topic_en = "free talk, no spam 🙏" },
    .{ .name = "memes", .topic = "só o suprassumo", .topic_en = "only the finest" },
    .{ .name = "setups", .topic = "mostra o rice", .topic_en = "show off your rice" },
    .{ .name = "música", .topic = "o que vocês estão ouvindo?", .name_en = "music", .topic_en = "what are you all listening to?" },
    .{ .name = "projetos", .kind = .category, .name_en = "projects" },
    .{ .name = "zig", .topic = "allocators, comptime e sofrimento", .topic_en = "allocators, comptime and suffering" },
    .{ .name = "interface", .topic = "design do larperCord", .topic_en = "larperCord's design" },
    .{ .name = "bugs", .topic = "reporte com print", .topic_en = "report with a screenshot" },
    .{ .name = "voz", .kind = .category, .name_en = "voice" },
    .{ .name = "Call da madrugada", .kind = .voice, .name_en = "Late-night call" },
    .{ .name = "Jogando", .kind = .voice, .name_en = "Gaming" },
    .{ .name = "AFK", .kind = .voice },
};

const reaction_pool = [_][]const u8{ "😂", "👍", "❤️", "🔥", "💀", "😭", "🎉", "👀" };

/// DMs: canal 900_000 + i conversa com users[i + 1].
pub fn dmId(i: usize) Id {
    return 900_000 + @as(Id, i);
}

pub fn dmRecipient(ch: Id) ?Id {
    if (ch < 900_000 or ch >= 900_000 + 6) return null;
    return users[@intCast(ch - 900_000 + 1)].id;
}

pub fn guildId(i: usize) Id {
    return 500_000 + @as(Id, i) * 1000;
}

pub fn channelId(guild_index: usize, i: usize) Id {
    return guildId(guild_index) + 1 + @as(Id, i);
}

/// No segundo servidor, o #bugs só a moderação vê e no AFK ninguém entra.
fn demoOverwrites(gi: usize, ci: usize) ![]const types.Overwrite {
    if (gi != 1) return &.{};
    const deny: u64 = switch (ci) {
        11 => types.perm.view_channel,
        15 => types.perm.connect,
        else => return &.{},
    };
    const o = try alloc.alloc(types.Overwrite, 1);
    o[0] = .{ .id = guildId(1), .deny = deny };
    return o;
}

/// Pastas da demonstração: soltos, "Programação" e "Jogos".
fn demoFolders() ![]types.GuildFolder {
    const spec = [_]struct { id: u64, name: []const u8, name_en: []const u8, color: u32, guilds: []const usize }{
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{0} },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{1} },
        .{ .id = 77, .name = "Programação", .name_en = "Programming", .color = 0x3BA55C, .guilds = &.{ 2, 8, 4 } },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{5} },
        .{ .id = 78, .name = "Jogos", .name_en = "Games", .color = 0xF0B232, .guilds = &.{ 6, 3 } },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{7} },
        .{ .id = 0, .name = "", .name_en = "", .color = 0, .guilds = &.{9} },
    };
    const out = try alloc.alloc(types.GuildFolder, spec.len);
    for (spec, 0..) |f, i| {
        const ids = try alloc.alloc(Id, f.guilds.len);
        for (f.guilds, 0..) |gi, k| ids[k] = guildId(gi);
        out[i] = .{ .id = f.id, .name = try alloc.dupe(u8, pick(f.name, f.name_en)), .color = f.color, .guilds = ids };
    }
    return out;
}

fn buildReady() !ev.Ready {
    const us = try alloc.alloc(types.User, users.len);
    for (users, 0..) |u, i| us[i] = .{
        .id = u.id,
        .name = try alloc.dupe(u8, u.name),
        .role = u.role,
        .status = u.status,
        .activity = if (u.activity) |a| try alloc.dupe(u8, pick(a, u.activity_en)) else null,
        .avatar = if (u.avatar) try std.fmt.allocPrint(alloc, "demo:av:{d}", .{u.id}) else null,
    };
    const gs = try alloc.alloc(types.Guild, guilds.len);
    for (guilds, 0..) |g, i| gs[i] = .{
        .id = guildId(i),
        .name = try alloc.dupe(u8, pick(g.name, g.name_en)),
        .acronym = try alloc.dupe(u8, pick(g.acronym, g.acronym_en)),
        .color = g.color,
        .icon = if (g.icon) try std.fmt.allocPrint(alloc, "demo:icon:{d}", .{i}) else null,
        // O primeiro servidor é nosso (dá para mexer em cargos e mensagens).
        .owner = if (i == 0) me_id else 1001,
    };
    const chs = try alloc.alloc(types.Channel, guilds.len * channel_tree.len + 7);
    var n: usize = 0;
    for (0..guilds.len) |gi| {
        var parent: ?Id = null;
        for (channel_tree, 0..) |ch, ci| {
            const id = channelId(gi, ci);
            if (ch.kind == .category) parent = id;
            chs[n] = .{
                .id = id,
                .guild = guildId(gi),
                .parent = if (ch.kind == .category) null else parent,
                .kind = ch.kind,
                .name = try alloc.dupe(u8, pick(ch.name, ch.name_en)),
                .topic = try alloc.dupe(u8, pick(ch.topic, ch.topic_en)),
                .position = @intCast(ci),
                .overwrites = try demoOverwrites(gi, ci),
            };
            n += 1;
        }
    }
    for (0..6) |i| {
        chs[n] = .{
            .id = dmId(i),
            .guild = 0,
            .name = try alloc.dupe(u8, users[i + 1].name),
            .topic = try alloc.dupe(u8, ""),
            .position = @intCast(i),
            .recipient = users[i + 1].id,
        };
        n += 1;
        // O grupo entra em terceiro na lista de DMs.
        if (i == 1) {
            chs[n] = .{
                .id = group_id,
                .guild = 0,
                .name = try alloc.dupe(u8, pick("rolê de sexta", "friday hangout")),
                .topic = try alloc.dupe(u8, ""),
                .position = 2,
                .recipient = group_members[0],
                .recipients = try alloc.dupe(Id, &group_members),
                .group = true,
            };
            n += 1;
        }
    }
    const voice = try alloc.alloc([2]Id, 4 * guilds.len);
    var vn: usize = 0;
    for (0..guilds.len) |gi| {
        const call = channelId(gi, 13);
        for ([_]Id{ 1001, 1005, 1003 }) |u| {
            voice[vn] = .{ call, u };
            vn += 1;
        }
        voice[vn] = .{ channelId(gi, 14), 1002 };
        vn += 1;
    }
    return .{ .me = me_id, .users = us, .guilds = gs, .channels = chs, .voice = voice, .username = try alloc.dupe(u8, "rsha") };
}

/// Quantas não lidas cada canal tem ao abrir a demonstração (0 = nenhuma).
fn demoUnread(channel: Id) usize {
    return switch (channel) {
        channelId(0, 2) => 2,
        channelId(0, 4) => 3,
        channelId(0, 5) => 4,
        channelId(0, 9) => 2,
        // Mais do que cabe na tela: abre na primeira não lida.
        channelId(0, 10) => 60,
        channelId(1, 4) => 5,
        channelId(3, 4) => 6,
        channelId(5, 4) => 40,
        channelId(9, 4) => 2,
        dmId(1) => 2,
        dmId(3) => 1,
        group_id => 3,
        else => 0,
    };
}

/// `read_state` da demonstração: o mesmo formato do READY de verdade. O
/// histórico é sempre o mesmo dentro da sessão, então dá para apontar para uma
/// mensagem dele e contar as menções de verdade.
fn demoReadStates(epoch_ms: i64) ![]types.ReadEntry {
    const list = [_]Id{ channelId(0, 2), channelId(0, 4), channelId(0, 5), channelId(0, 9), channelId(0, 10), channelId(1, 4), channelId(3, 4), channelId(5, 4), channelId(9, 4), dmId(1), dmId(3), group_id };
    const out = try alloc.alloc(types.ReadEntry, list.len);
    for (list, 0..) |ch, i| {
        const msgs = try buildHistory(ch, epoch_ms);
        defer freeMessages(msgs);
        const k = demoUnread(ch);
        var mentions: u16 = 0;
        for (msgs[msgs.len - k..]) |m| {
            const dm = ch >= 900_000;
            if (dm or std.mem.indexOf(u8, m.content, "<@1000>") != null or std.mem.indexOf(u8, m.content, "@everyone") != null) mentions += 1;
        }
        out[i] = .{ .channel = ch, .last_read = msgs[msgs.len - k - 1].id, .mentions = mentions, .last_message = msgs[msgs.len - 1].id };
    }
    return out;
}

/// Cartão de convite da demonstração (sem conta, sem entrar em nada).
fn demoInvite(code: []const u8) !types.Invite {
    if (std.mem.eql(u8, code, "larper")) return .{ .state = .ok, .guild = guildId(0), .name = try alloc.dupe(u8, pick(guilds[0].name, guilds[0].name_en)), .members = 12, .online = 7 };
    if (std.mem.eql(u8, code, "zigbr")) return .{ .state = .ok, .guild = 777_000, .name = try alloc.dupe(u8, "Zig Brasil (oficial)"), .icon = try alloc.dupe(u8, "demo:icon:2"), .members = 4312, .online = 389 };
    return .{ .state = .invalid };
}

fn freeMessages(msgs: []types.Message) void {
    for (msgs) |m| freeOne(m);
    alloc.free(msgs);
}

fn freeOne(m: types.Message) void {
    alloc.free(m.content);
    types.freeAttachments(alloc, m.attachments);
    types.freeEmbeds(alloc, m.embeds);
}

/// Copia a fatia `lo..hi` e libera o resto.
fn keepRange(msgs: []types.Message, lo: usize, hi: usize) ![]types.Message {
    const out = try alloc.alloc(types.Message, hi - lo);
    @memcpy(out, msgs[lo..hi]);
    for (msgs[0..lo]) |m| freeOne(m);
    for (msgs[hi..]) |m| freeOne(m);
    alloc.free(msgs);
    return out;
}

/// As mensagens fixadas que ficam dentro do histórico (contando do fim).
const pinned_backs = [_]usize{ 120, 40 };

/// A fixada antiga: 40 dias antes do começo da sessão, longe do que carrega.
pub fn oldPinId(channel: Id, epoch_ms: i64) Id {
    return types.makeSnowflake(epoch_ms - 40 * 86_400_000, demoSeq(channel, 1000));
}

/// Uma mensagem fora do histórico, sempre a mesma para o mesmo ID.
fn syntheticAt(channel: Id, id: Id, epoch_ms: i64) !types.Message {
    var prng = std.Random.DefaultPrng.init(channel ^ id);
    const r = prng.random();
    const text = if (id == oldPinId(channel, epoch_ms)) pick("regra de ouro: sem spam e sem pedir cargo 🙏", "golden rule: no spam and no asking for roles 🙏") else phrase(r.uintLessThan(usize, phrases.len));
    return .{
        .id = id,
        .channel = channel,
        .author = if (dmRecipient(channel)) |u| u else users[1 + r.uintLessThan(usize, 7)].id,
        .timestamp = @divTrunc(types.snowflakeTime(id), 1000),
        .content = try alloc.dupe(u8, text),
    };
}

/// GET messages?around=: 25 de cada lado da mensagem. Dentro do histórico,
/// o próprio; antes dele, uma conversa inventada (sempre a mesma).
fn buildAround(channel: Id, id: Id, epoch_ms: i64) ![]types.Message {
    const latest = try buildHistory(channel, epoch_ms);
    if (id >= latest[0].id) {
        var at: usize = 0;
        for (latest, 0..) |m, i| if (m.id <= id) {
            at = i;
        };
        return keepRange(latest, at -| 25, @min(at + 25, latest.len));
    }
    defer freeMessages(latest);
    const oldest_s = @divTrunc(types.snowflakeTime(latest[0].id), 1000);
    const t0 = @divTrunc(types.snowflakeTime(id), 1000);
    var out: std.ArrayList(types.Message) = .empty;
    for (0..50) |i| {
        const off = (@as(i64, @intCast(i)) - 25) * 90;
        if (t0 + off >= oldest_s) break;
        const mid = if (i == 25) id else types.makeSnowflake((t0 + off) * 1000, demoSeq(channel, i));
        try out.append(alloc, try syntheticAt(channel, mid, epoch_ms));
    }
    return out.toOwnedSlice(alloc);
}

/// GET messages?after=: voltando para o presente, até encostar no histórico.
fn buildNewer(channel: Id, after: Id, epoch_ms: i64) !struct { msgs: []types.Message, more: bool } {
    const latest = try buildHistory(channel, epoch_ms);
    if (after >= latest[0].id) {
        var from = latest.len;
        for (latest, 0..) |m, i| if (m.id > after) {
            from = i;
            break;
        };
        const end = @min(from + 50, latest.len);
        const more = end < latest.len;
        return .{ .msgs = try keepRange(latest, from, end), .more = more };
    }
    const oldest_s = @divTrunc(types.snowflakeTime(latest[0].id), 1000);
    const t0 = @divTrunc(types.snowflakeTime(after), 1000);
    var out: std.ArrayList(types.Message) = .empty;
    // Uma mensagem por hora: de um mês para cá, em algumas páginas.
    for (1..51) |i| {
        const t = t0 + @as(i64, @intCast(i)) * 3600;
        if (t >= oldest_s) break;
        try out.append(alloc, try syntheticAt(channel, types.makeSnowflake(t * 1000, demoSeq(channel, i)), epoch_ms));
    }
    // Encostou: daqui em diante é o histórico.
    if (out.items.len == 0) {
        out.deinit(alloc);
        return .{ .msgs = try keepRange(latest, 0, 50), .more = true };
    }
    freeMessages(latest);
    return .{ .msgs = try out.toOwnedSlice(alloc), .more = true };
}

/// Menções recentes da demonstração (o que o GET /users/@me/mentions
/// devolveria): de horas a dias atrás, em vários servidores e no grupo.
fn demoMentions(now_ms: i64) ![]types.Message {
    const spec = [_]struct { ch: Id, author: Id, hours: i64, pt: []const u8, en: []const u8 }{
        .{ .ch = channelId(3, 4), .author = 1001, .hours = 2, .pt = "<@1000> bora jogar hoje à noite?", .en = "<@1000> gaming tonight?" },
        .{ .ch = channelId(3, 5), .author = 1002, .hours = 5, .pt = "<@1000> olha isso kkkkkk", .en = "<@1000> look at this lmao" },
        .{ .ch = group_id, .author = 1003, .hours = 9, .pt = "<@1000> sexta tá de pé?", .en = "<@1000> still on for friday?" },
        .{ .ch = channelId(5, 4), .author = 1007, .hours = 26, .pt = "<@1000> tu fez o trabalho de cálculo? manda a **questão 3**", .en = "<@1000> did you do the calculus homework? send **question 3**" },
        .{ .ch = channelId(0, 9), .author = 1003, .hours = 49, .pt = "<@1000> o allocator tava vazando mesmo, valeu 🙏", .en = "<@1000> the allocator really was leaking, thanks 🙏" },
        .{ .ch = channelId(2, 4), .author = 1005, .hours = 73, .pt = "@everyone live de zig hoje às 20h", .en = "@everyone zig stream today at 8pm" },
        .{ .ch = channelId(0, 4), .author = 1004, .hours = 120, .pt = "<@1000> e o tema novo, sai quando?", .en = "<@1000> so when's the new theme coming out?" },
    };
    const out = try alloc.alloc(types.Message, spec.len);
    for (spec, 0..) |m, i| {
        const t = now_ms - m.hours * 3_600_000;
        out[i] = .{
            .id = types.makeSnowflake(t, 0x3f0000 + i),
            .channel = m.ch,
            .author = m.author,
            .timestamp = @divTrunc(t, 1000),
            .content = try alloc.dupe(u8, pick(m.pt, m.en)),
        };
    }
    return out;
}

/// Parte baixa do ID: o canal entra junto, senão a mensagem N de canais
/// diferentes teria o mesmo ID (o horário de partida é o mesmo).
fn demoSeq(channel: Id, i: usize) u64 {
    return ((channel % 4096) << 10) | (i & 0x3ff);
}

/// 50 mensagens antes de `before` (rolou para cima na demonstração).
fn buildOlder(channel: Id, before: Id) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(channel ^ before);
    const r = prng.random();
    const n: usize = 50;
    const msgs = try alloc.alloc(types.Message, n);
    var t: i64 = @divTrunc(types.snowflakeTime(before), 1000) - 300;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const author = if (dmRecipient(channel)) |u| (if (r.boolean()) u else me_id) else users[r.uintLessThan(usize, 8)].id;
        msgs[i] = .{
            .id = types.makeSnowflake(t * 1000, demoSeq(channel, i)),
            .channel = channel,
            .author = author,
            .timestamp = t,
            .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
        };
        t -= if (r.uintLessThan(u8, 6) == 0) r.intRangeLessThan(i64, 3600, 40000) else r.intRangeLessThan(i64, 20, 600);
    }
    return msgs;
}

fn buildHistory(channel: Id, now_ms: i64) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(channel *% 0x9E3779B97F4A7C15);
    const r = prng.random();
    const n: usize = 300;
    const msgs = try alloc.alloc(types.Message, n);
    // Gera de trás para frente a partir de "agora".
    var t: i64 = @divTrunc(now_ms, 1000) - 60 * 3;
    var author: Id = users[1].id;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (i == n - 1 or r.uintLessThan(u8, 3) != 0) author = if (dmRecipient(channel)) |u| (if (r.boolean()) u else me_id) else if (channel == group_id) (if (r.uintLessThan(u8, 4) == 0) me_id else group_members[r.uintLessThan(usize, group_members.len)]) else users[r.uintLessThan(usize, 8)].id;
        msgs[i] = .{
            .id = types.makeSnowflake(t * 1000, demoSeq(channel, i)),
            .channel = channel,
            .author = author,
            .timestamp = t,
            .content = try alloc.dupe(u8, phrase(r.uintLessThan(usize, phrases.len))),
            .edited = r.uintLessThan(u8, 25) == 0,
        };
        const gap: i64 = if (r.uintLessThan(u8, 10) == 0) r.intRangeLessThan(i64, 1800, 14000) else r.intRangeLessThan(i64, 5, 240);
        t -= gap;
    }
    // Algumas respostas a mensagens um pouco anteriores.
    for (msgs, 0..) |*m, j| {
        if (j > 3 and r.uintLessThan(u8, 9) == 0) m.reply_to = msgs[j - 1 - r.uintLessThan(usize, 3)].id;
    }
    // #anúncios do primeiro servidor termina com uma menção a nós, de outra
    // pessoa: a caixa de entrada da demonstração tem uma menção não lida.
    if (channel == channelId(0, 2)) {
        alloc.free(msgs[n - 2].content);
        msgs[n - 2].content = try alloc.dupe(u8, pick("<@1000> dá uma olhada no anúncio novo quando puder 🙏", "<@1000> take a look at the new announcement when you can 🙏"));
        msgs[n - 2].author = 1001;
        msgs[n - 2].reply_to = 0;
        msgs[n - 1].author = 1002;
    }
    // Quem ainda não foi lido não é nosso (falar é ter lido).
    const unread_k = demoUnread(channel);
    for (msgs[n - unread_k..]) |*m| if (m.author == me_id) {
        m.author = dmRecipient(channel) orelse if (channel == group_id) group_members[0] else 1001;
    };
    // Duas fixadas dentro do histórico (a antiga fica fora: seedPins).
    for (pinned_backs) |back| msgs[n - back].pinned = true;
    // Imagens (geradas na hora pelo carregador: "demo:N") e um arquivo.
    const pics = [_]struct { back: usize, text: []const u8, url: []const u8, name: []const u8, w: u16, h: u16, text_en: ?[]const u8 = null, name_en: ?[]const u8 = null }{
        .{ .back = 5, .text = "olha o pôr do sol daqui de casa 🌅", .url = "demo:1", .name = "por-do-sol.png", .w = 900, .h = 560, .text_en = "check out the sunset from my place 🌅", .name_en = "sunset.png" },
        .{ .back = 14, .text = "wallpaper novo, que acharam?", .url = "demo:2", .name = "synthwave.png", .w = 720, .h = 720, .text_en = "new wallpaper, thoughts?" },
        .{ .back = 23, .text = "", .url = "demo:3", .name = "aurora.png", .w = 960, .h = 540 },
        .{ .back = 31, .text = "o relatório que eu falei", .url = "demo:file", .name = "relatorio-de-ram.pdf", .w = 0, .h = 0, .text_en = "the report i mentioned", .name_en = "ram-report.pdf" },
        // Um GIF de link (como os do Tenor): animado e marcado como embed.
        .{ .back = 9, .text = "https://tenor.com/view/larper-loading", .url = "demo:gif", .name = "loading.gif", .w = 480, .h = 270 },
    };
    for (pics) |p| {
        const m = &msgs[n - p.back];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick(p.text, p.text_en));
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        const gif = std.mem.eql(u8, p.url, "demo:gif");
        list[0] = .{ .url = try alloc.dupe(u8, p.url), .filename = try alloc.dupe(u8, pick(p.name, p.name_en)), .width = p.w, .height = p.h, .size = if (p.w == 0) 482_133 else 0, .animated = gif, .embed = gif };
        m.attachments = list;
    }
    // Um vídeo anexado (toca aqui com o FFmpeg do sistema; a prévia é um
    // quadro qualquer) e um GIF que só existe em MP4, como os antigos do
    // Tenor (anima pelo FFmpeg; sem ele, fica a prévia parada).
    {
        const m = &msgs[n - 12];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick("gravei a tela rapidinho", "quick screen recording"));
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, "demo:3"), .filename = try alloc.dupe(u8, "gravacao.mp4"), .width = 426, .height = 240, .size = 48_435, .video = true, .link = try alloc.dupe(u8, "demo:video") };
        m.attachments = list;
    }
    {
        const m = &msgs[n - 20];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "https://tenor.com/view/larper-antigo");
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, "demo:mp4"), .filename = try alloc.dupe(u8, "antigo.gif"), .width = 426, .height = 240, .animated = true, .still = try alloc.dupe(u8, "demo:2"), .embed = true };
        m.attachments = list;
    }
    // Embeds: prévia de link, cartão de bot com campos e um vídeo.
    {
        const m = &msgs[n - 3];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "https://ziglang.org");
        m.reply_to = 0;
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .provider = try alloc.dupe(u8, "ziglang.org"),
            .title = try alloc.dupe(u8, "Zig Programming Language"),
            .url = try alloc.dupe(u8, "https://ziglang.org"),
            .description = try alloc.dupe(u8, pick("Zig é uma linguagem de uso geral para software **robusto**, **ótimo** e **reutilizável**.", "Zig is a general-purpose language for **robust**, **optimal** and **reusable** software.")),
            .color = 0xF7A41D,
            .has_color = true,
            .thumb = try alloc.dupe(u8, "demo:icon:2"),
        };
        m.embeds = e;
    }
    {
        const m = &msgs[n - 18];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, "");
        m.reply_to = 0;
        const fields = try alloc.alloc(types.EmbedField, 2);
        fields[0] = .{ .name = try alloc.dupe(u8, pick("Membros", "Members")), .value = try alloc.dupe(u8, "**12** (7 online)") };
        fields[1] = .{ .name = try alloc.dupe(u8, pick("Ping", "Ping")), .value = try alloc.dupe(u8, "`42 ms`") };
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .author = try alloc.dupe(u8, "larperBot"),
            .title = try alloc.dupe(u8, pick("Status do servidor", "Server status")),
            .description = try alloc.dupe(u8, pick("Tudo funcionando. Use `/ajuda` para ver os comandos.", "All systems go. Use `/help` to see the commands.")),
            .fields = fields,
            .footer = try alloc.dupe(u8, pick("atualizado agora", "updated just now")),
            .color = 0x5865F2,
            .has_color = true,
        };
        m.embeds = e;
    }
    {
        const m = &msgs[n - 27];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick("esse vídeo explica tudo", "this video explains everything"));
        m.reply_to = 0;
        const e = try alloc.alloc(types.Embed, 1);
        e[0] = .{
            .provider = try alloc.dupe(u8, "YouTube"),
            .author = try alloc.dupe(u8, "Zig SHOWTIME"),
            .title = try alloc.dupe(u8, pick("Comptime sem medo", "Comptime without fear")),
            .url = try alloc.dupe(u8, "https://www.youtube.com/"),
            .image = try alloc.dupe(u8, "demo:3"),
            .image_w = 960,
            .image_h = 540,
            .video = true,
            .color = 0xFF0000,
            .has_color = true,
        };
        m.embeds = e;
    }
    // #interface: links do Discord, convites e menções clicáveis.
    if (channel == channelId(0, 10)) {
        const set = struct {
            fn f(m: *types.Message, text: []const u8) !void {
                alloc.free(m.content);
                m.content = text;
                m.reply_to = 0;
            }
        }.f;
        try set(&msgs[n - 1], try i18n.allocPrint(alloc, "entra lá: https://discord.gg/larper", "join us: https://discord.gg/larper", .{}));
        try set(&msgs[n - 2], try i18n.allocPrint(alloc, "o pessoal do zig também: https://discord.gg/zigbr", "the zig folks too: https://discord.gg/zigbr", .{}));
        try set(&msgs[n - 4], try i18n.allocPrint(alloc, "a regra fixada é esta: https://discord.com/channels/{d}/{d}/{d}", "the pinned rule is this one: https://discord.com/channels/{d}/{d}/{d}", .{ guildId(0), channel, oldPinId(channel, now_ms) }));
        try set(&msgs[n - 6], try i18n.allocPrint(alloc, "vejam <#{d}> e falem com <@1001>; o outro canal: https://ptb.discord.com/channels/{d}/{d}", "check <#{d}> and talk to <@1001>; the other channel: https://ptb.discord.com/channels/{d}/{d}", .{ channelId(0, 4), guildId(0), channelId(0, 5) }));
    }
    return msgs;
}

const phrases = [_][]const u8{
    "bom dia rapaziada ☀️",
    "alguém vai jogar hoje à noite?",
    "kkkkkkkkkkkkk",
    "olha o `ps aux` do vesktop: **1.28 GB** de RAM pra mandar mensagem 💀",
    "<@1000> viu isso aqui?",
    "acabei de atualizar pro zig 0.17 e quebrou tudo de novo 🙃",
    "mano o hyprland novo tá *muito* liso",
    "**finalmente** consegui compilar",
    "alguém tem um wallpaper bom aí? to cansado do meu",
    "isso é muito larper kkkk",
    "vou dormir, amanhã cedo tenho prova 😴",
    "tá, mas e o allocator? quem dá `free` nisso?",
    "manda o print",
    "que isso, ficou lindo demais 😍",
    "eu acho que o problema é o cache, tenta limpar com `rm -rf ~/.cache/zig` e compila de novo",
    "imagina um cliente de discord que abre em 200ms e gasta 30MB. seria o sonho né",
    "<@1005> tu usa qual tema no kitty?",
    "brabo",
    "sim",
    "não sei, mas confia",
    "joguei aquele jogo que tu falou, viciei demais. fiquei até 4 da manhã e nem vi o tempo passar, agora tô um zumbi no trabalho 🧟",
    "**urgente**: alguém tem carregador de notebook usb-c aí na sala?",
    "😂😂😂",
    "o segredo é dormir quando nada acontece. cpu em 0% parado é outro nível",
    "ok",
    "eu mudaria o raio das bordas pra uns 8px, fica mais moderno",
    "tô ouvindo lo-fi e programando, vibe perfeita ☕",
    "quem roubou meu energético da geladeira 😤",
    "amanhã tem call?",
    "fiz um script que troca as cores do sistema inteiro com o wallpaper, depois mando o repo",
    "<@1003> bora?",
    "pior que faz sentido",
    "vou testar aqui e já falo",
    "funcionou!!! 🎉",
    "o final da série é ||o cachorro era o vilão o tempo todo|| 😭",
    "~~não~~ sim, eu admito",
    "docs aqui: https://ziglang.org/documentation/master",
    "temas em KDL que mudam o layout inteiro? isso é *outro* nível",
};

/// As mesmas frases em inglês, na mesma ordem (o sorteio é pelo índice).
const phrases_en = [_][]const u8{
    "morning everyone ☀️",
    "anyone gaming tonight?",
    "LMAOOOOOOOOO",
    "look at vesktop's `ps aux`: **1.28 GB** of RAM just to send a message 💀",
    "<@1000> did you see this?",
    "just updated to zig 0.17 and everything broke again 🙃",
    "dude the new hyprland is *so* smooth",
    "**finally** got it to compile",
    "anyone got a good wallpaper? i'm sick of mine",
    "this is so larper lmao",
    "going to bed, got an exam early tomorrow 😴",
    "ok, but what about the allocator? who calls `free` on this?",
    "send a screenshot",
    "whoa, that looks way too good 😍",
    "i think the problem is the cache, try clearing it with `rm -rf ~/.cache/zig` and build again",
    "imagine a discord client that opens in 200ms and uses 30MB. that'd be the dream huh",
    "<@1005> which theme do you use in kitty?",
    "based",
    "yes",
    "no idea, but trust me",
    "played that game you told me about, got completely hooked. stayed up till 4am without noticing, now i'm a zombie at work 🧟",
    "**urgent**: anyone got a usb-c laptop charger in the room?",
    "😂😂😂",
    "the secret is sleeping when nothing's happening. 0% cpu when idle is next level",
    "ok",
    "i'd bump the border radius to like 8px, looks more modern",
    "listening to lo-fi and coding, perfect vibe ☕",
    "who stole my energy drink from the fridge 😤",
    "call tomorrow?",
    "wrote a script that recolors the whole system to match the wallpaper, i'll send the repo later",
    "<@1003> you in?",
    "annoyingly, that makes sense",
    "gonna test it here and get back to you",
    "it works!!! 🎉",
    "the show's ending is ||the dog was the villain the whole time|| 😭",
    "~~no~~ yes, i admit it",
    "docs here: https://ziglang.org/documentation/master",
    "KDL themes that change the whole layout? that's *next* level",
};

comptime {
    std.debug.assert(phrases.len == phrases_en.len);
}

fn phrase(i: usize) []const u8 {
    return if (i18n.en()) phrases_en[i] else phrases[i];
}
