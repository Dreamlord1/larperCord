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
const Id = types.Id;

const alloc = std.heap.c_allocator;

pub const Sink = struct {
    ctx: *anyopaque,
    push: *const fn (ctx: *anyopaque, event: ev.Event) void,
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
    /// Threads e posts da demonstração: o que cada uma tem de conversa.
    threads: std.AutoHashMapUnmanaged(Id, DemoThread) = .empty,

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
        // O @everyone do segundo servidor (que não é nosso): com ele, o #bugs
        // e o AFK de lá aparecem trancados (demoOverwrites).
        {
            const rs = try alloc.alloc(types.Role, 1);
            rs[0] = .{ .id = guildId(1), .guild = guildId(1), .name = try alloc.dupe(u8, "@everyone"), .permissions = types.perm.view_channel | types.perm.send_messages | types.perm.read_history | types.perm.connect };
            g.emit(.{ .roles = .{ .guild = guildId(1), .roles = rs } });
            // Igual no servidor das threads sem permissão: nada de responder
            // nelas nem de criar novas (ver `demoThreads`).
            const rs2 = try alloc.alloc(types.Role, 1);
            rs2[0] = .{ .id = guildId(locked_guild), .guild = guildId(locked_guild), .name = try alloc.dupe(u8, "@everyone"), .permissions = rs[0].permissions };
            g.emit(.{ .roles = .{ .guild = guildId(locked_guild), .roles = rs2 } });
        }
        for (relations, 0..) |rel, i| g.emit(.{ .relationship = .{ .user = rel.user, .kind = rel.kind, .since_ms = nowMs() - @as(i64, @intCast(i + 1)) * 97 * 86_400_000 } });
        try g.demoActivities();
        g.emit(.{ .guild_folders = try demoFolders() });
        try g.demoThreads();
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
                .fetch_threads => |ft| try g.threadsPage(ft.channel, ft.guild, ft.archived, ft.offset),
                .create_thread => |ct| {
                    // Como no Discord: a thread tem o ID da mensagem que a abriu.
                    try g.threads.put(alloc, ct.message, .{ .count = 0, .members = 1 });
                    g.emit(.{ .channel_upsert = .{
                        .id = ct.message,
                        .guild = guildOfChannel(ct.channel),
                        .parent = ct.channel,
                        .name = ct.name,
                        .topic = try alloc.dupe(u8, ""),
                        .thread = .{ .owner = me_id, .joined = true, .joined_known = true, .member_count = 1 },
                    } });
                    g.emit(.{ .thread_open = ct.message });
                },
                .create_post => |cp| {
                    const id = types.makeSnowflake(nowMs(), g.rng.random().int(u22));
                    try g.threads.put(alloc, id, .{ .count = 0, .members = 1 });
                    g.emit(.{ .channel_upsert = .{
                        .id = id,
                        .guild = guildOfChannel(cp.forum),
                        .parent = cp.forum,
                        .name = cp.name,
                        .topic = try alloc.dupe(u8, ""),
                        .thread = .{ .owner = me_id, .joined = true, .joined_known = true, .member_count = 1, .tags = cp.tags },
                    } });
                    g.emit(.{ .message_create = .{ .id = id, .channel = id, .author = me_id, .timestamp = @divTrunc(nowMs(), 1000), .content = cp.content } });
                    g.emit(.{ .thread_open = id });
                },
                .join_thread => |jt| {
                    g.emit(.{ .thread_joined = .{ .thread = jt.thread, .joined = jt.join } });
                    const list = try alloc.alloc(Id, 1);
                    list[0] = me_id;
                    g.emit(.{ .thread_members = if (jt.join) .{ .thread = jt.thread, .added = list } else .{ .thread = jt.thread, .removed = list } });
                },
                .fetch_thread_members => |tid| {
                    const n: usize = if (g.threads.get(tid)) |t| t.members else 0;
                    // Sem ninguém na lista: a interface usa a do canal pai.
                    if (n == 0) continue;
                    const list = try alloc.alloc(Id, n);
                    for (list, 0..) |*u, i| u.* = users[1 + (i + tid % 5) % 7].id;
                    g.emit(.{ .thread_members = .{ .thread = tid, .replace = true, .added = list } });
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
                .fetch_mentions => g.emit(.{ .recent_mentions = try demoMentions(nowMs()) }),
            };
            cmds.clearRetainingCapacity();
            try g.tick(nowMs());
        }
    }

    /// Threads ativas, como o Discord manda ao abrir o servidor: duas abertas
    /// de mensagens do #zig (o cartão aparece nelas) e uma solta; no servidor
    /// sem permissões, uma no #geral (sem poder responder) e uma no #bugs
    /// (trancado, porque o pai é).
    fn demoThreads(g: *Gateway) !void {
        const zig = channelId(thread_guild, 9);
        const msgs = try buildHistory(zig, g.epoch_ms);
        defer freeMessages(msgs);
        const n = msgs.len;
        const specs = [_]struct { id: Id, name: []const u8, en: []const u8, parent: Id, guild: usize, count: u32, members: u8, joined: bool, unread: bool, first: ?*const types.Message = null, secs: i64 = 0 }{
            .{ .id = msgs[n - 8].id, .name = "quem dá free nisso?", .en = "who frees this?", .parent = zig, .guild = thread_guild, .count = 7, .members = 3, .joined = true, .unread = false, .first = &msgs[n - 8] },
            .{ .id = msgs[n - 34].id, .name = "migração para o zig 0.17", .en = "moving to zig 0.17", .parent = zig, .guild = thread_guild, .count = 12, .members = 0, .joined = false, .unread = true, .first = &msgs[n - 34] },
            .{ .id = 0, .name = "benchmarks do cliente", .en = "client benchmarks", .parent = zig, .guild = thread_guild, .count = 4, .members = 2, .joined = false, .unread = false, .secs = 3 * 3600 },
            .{ .id = 0, .name = "dúvida sobre o tema", .en = "question about the theme", .parent = channelId(locked_guild, 4), .guild = locked_guild, .count = 5, .members = 2, .joined = false, .unread = false, .secs = 2 * 3600 },
            .{ .id = 0, .name = "bug secreto", .en = "secret bug", .parent = channelId(locked_guild, 11), .guild = locked_guild, .count = 2, .members = 0, .joined = false, .unread = false, .secs = 5 * 3600 },
        };
        for ([_]usize{ thread_guild, locked_guild }) |gi| {
            var list: std.ArrayList(types.Channel) = .empty;
            var joined: std.ArrayList(Id) = .empty;
            var parents: std.ArrayList(Id) = .empty;
            for (specs, 0..) |t, si| {
                if (t.guild != gi) continue;
                const id = if (t.id != 0) t.id else types.makeSnowflake(g.epoch_ms - t.secs * 1000, 0x2f0000 + si);
                var rec: DemoThread = .{ .count = t.count, .members = t.members };
                if (t.first) |m| {
                    rec.first_author = m.author;
                    rec.first_text = try alloc.dupe(u8, m.content);
                }
                try g.threads.put(alloc, id, rec);
                try list.append(alloc, .{
                    .id = id,
                    .guild = guildId(gi),
                    .parent = t.parent,
                    .name = try alloc.dupe(u8, pick(t.name, t.en)),
                    .topic = try alloc.dupe(u8, ""),
                    .unread = t.unread,
                    .thread = .{ .owner = 1001, .joined = t.joined, .joined_known = true, .message_count = t.count, .member_count = t.members, .last_message = types.makeSnowflake(g.epoch_ms - 240_000 - @as(i64, @intCast(si)) * 700_000, 0x2e0000 + si) },
                });
                if (std.mem.indexOfScalar(Id, parents.items, t.parent) == null) try parents.append(alloc, t.parent);
                if (t.joined) try joined.append(alloc, id);
            }
            g.emit(.{ .thread_list_sync = .{ .guild = guildId(gi), .parents = try parents.toOwnedSlice(alloc), .threads = try list.toOwnedSlice(alloc), .joined = try joined.toOwnedSlice(alloc) } });
        }
    }

    /// Uma página de threads de um canal da demonstração: nos fóruns, os
    /// posts; num canal de texto, só as arquivadas (as ativas vieram no sync).
    fn threadsPage(g: *Gateway, channel: Id, guild: Id, archived: bool, offset: u32) !void {
        const forum = isDemoForum(channel);
        const total: u32 = if (forum) (if (archived) @as(u32, 8) else 60) else if (archived and channel == channelId(thread_guild, 9)) 6 else 0;
        const page: u32 = if (archived) 50 else 25;
        const first = @min(offset, total);
        const last = @min(first + page, total);
        const threads = try alloc.alloc(types.Channel, last - first);
        const previews = try alloc.alloc(types.ThreadPreview, last - first);
        var joined: std.ArrayList(Id) = .empty;
        const tags = demoTags(channel);
        for (first..last) |i| {
            const post = demo_posts[i % demo_posts.len];
            // Um post a cada 7 h para trás; as arquivadas, depois de todas as ativas.
            const age: i64 = @intCast((i + (if (archived) @as(usize, 80) else 0)) * 7 + 1);
            const t_ms = g.epoch_ms - age * 3_600_000;
            const id = types.makeSnowflake(t_ms, 0x100000 + (channel % 512) * 256 + i + (if (archived) @as(usize, 128) else 0));
            const replies: u32 = @intCast((i * 13 + 3) % 40);
            const author = users[1 + (i * 3) % 7].id;
            try g.threads.put(alloc, id, .{ .count = @min(replies, 12), .members = @intCast(i % 4), .first_author = author, .first_text = try alloc.dupe(u8, pick(post.body, post.body_en)) });
            var applied: []Id = &.{};
            if (forum) {
                applied = try alloc.alloc(Id, 1 + i % 2);
                for (applied, 0..) |*a, k| a.* = tags[(i + k) % tags.len];
            }
            const title = pick(post.title, post.title_en);
            threads[i - first] = .{
                .id = id,
                .guild = guild,
                .parent = channel,
                .name = if (i < demo_posts.len) try alloc.dupe(u8, title) else try std.fmt.allocPrint(alloc, "{s} ({d})", .{ title, i / demo_posts.len + 1 }),
                .topic = try alloc.dupe(u8, ""),
                .thread = .{
                    .owner = author,
                    .archived = archived,
                    .locked = archived and i == 2,
                    .joined = !archived and i % 9 == 4,
                    .joined_known = true,
                    .message_count = replies,
                    .member_count = @intCast(i % 4 + 1),
                    .last_message = types.makeSnowflake(t_ms + @as(i64, @intCast((i * 37) % 300)) * 60_000, 0x80000 + i),
                    .archive_ts = if (archived) @divTrunc(t_ms, 1000) else 0,
                    .tags = applied,
                },
            };
            previews[i - first] = .{ .thread = id, .author = author, .text = try alloc.dupe(u8, pick(post.body, post.body_en)) };
            if (!archived and i % 9 == 4) try joined.append(alloc, id);
        }
        g.emit(.{ .threads_page = .{ .channel = channel, .archived = archived, .threads = threads, .previews = previews, .joined = try joined.toOwnedSlice(alloc), .more = last < total } });
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
        return d;
    }

    fn tick(g: *Gateway, now: i64) !void {
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
                // Thread ou post: uma conversa curta, que tem começo.
                if (g.threads.get(r.channel)) |t| {
                    g.emit(.{ .history = .{ .channel = r.channel, .messages = try buildThreadHistory(r.channel, t, g.epoch_ms), .more = false } });
                    _ = g.history_replies.orderedRemove(i);
                    continue;
                }
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

const GuildSeed = struct { name: []const u8, acronym: []const u8, color: u8, unread: bool = false, mentions: u16 = 0, name_en: ?[]const u8 = null, acronym_en: ?[]const u8 = null, icon: bool = false };

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
    .{ .name = "larperCord dev", .acronym = "LC", .color = 0, .unread = true, .mentions = 3 },
    .{ .name = "Rice do Hyprland", .acronym = "RH", .color = 4, .unread = true, .name_en = "Hyprland Rice", .acronym_en = "HR", .icon = true },
    .{ .name = "Zig Brasil", .acronym = "Z", .color = 1, .name_en = "Zig Brazil", .icon = true },
    .{ .name = "os larpers", .acronym = "ol", .color = 3, .unread = true, .mentions = 12, .name_en = "the larpers", .acronym_en = "tl" },
    .{ .name = "CTF da madrugada", .acronym = "CTF", .color = 6, .name_en = "Late-night CTF", .icon = true },
    .{ .name = "Faculdade 2026", .acronym = "F26", .color = 2, .unread = true, .name_en = "College 2026", .acronym_en = "C26" },
    .{ .name = "Minecraft SMP", .acronym = "MC", .color = 7, .icon = true },
    .{ .name = "Lo-fi & café", .acronym = "☕", .color = 5, .name_en = "Lo-fi & coffee" },
    .{ .name = "Arch Linux BR", .acronym = "A", .color = 4 },
    .{ .name = "Memes", .acronym = "😂", .color = 1, .unread = true },
};

const ChannelSeed = struct { name: []const u8, kind: types.ChannelKind = .text, unread: bool = false, topic: []const u8 = "", name_en: ?[]const u8 = null, topic_en: ?[]const u8 = null };

/// O que o gateway falso sabe de uma thread para montar a conversa dela.
const DemoThread = struct {
    count: u32,
    /// Quantas pessoas estão nela (0 = a lista de membros cai na do pai).
    members: u8,
    /// A primeira mensagem: a que abriu a thread, ou o texto do post.
    first_author: Id = 0,
    first_text: []const u8 = "",
};

/// Fórum e canal de mídia entram na categoria "geral", depois do #música, com
/// IDs novos fora da faixa do `channel_tree`: nenhum canal antigo muda de ID.
pub fn forumId(guild_index: usize) Id {
    return channelId(guild_index, 30);
}
pub fn mediaId(guild_index: usize) Id {
    return channelId(guild_index, 31);
}
/// Threads e fóruns ficam em servidores próprios ("Faculdade 2026" e "Lo-fi &
/// café"): os dois primeiros seguem iguais, sem linhas a mais na lista.
pub const thread_guild = 5;
/// Aqui só vale o @everyone: as threads herdam a falta de permissão.
pub const locked_guild = 7;

fn isDemoForum(ch: Id) bool {
    return ch == forumId(thread_guild) or ch == mediaId(thread_guild) or ch == mediaId(locked_guild);
}

fn guildOfChannel(ch: Id) Id {
    return guildId(@intCast((ch - guildId(0)) / 1000));
}

const demo_tags = [_]struct { name: []const u8, en: []const u8, emoji: []const u8 = "" }{
    .{ .name = "Dúvida", .en = "Question", .emoji = "❓" },
    .{ .name = "Tema", .en = "Theme", .emoji = "🎨" },
    .{ .name = "Bug", .en = "Bug", .emoji = "🐛" },
    .{ .name = "Resolvido", .en = "Solved", .emoji = "✅" },
};

fn demoTags(forum: Id) [demo_tags.len]Id {
    var out: [demo_tags.len]Id = undefined;
    for (&out, 0..) |*t, i| t.* = forum * 10 + i;
    return out;
}

fn demoForumTags(forum: Id) ![]const types.ForumTag {
    const list = try alloc.alloc(types.ForumTag, demo_tags.len);
    const ids = demoTags(forum);
    for (demo_tags, 0..) |t, i| list[i] = .{ .id = ids[i], .name = try alloc.dupe(u8, pick(t.name, t.en)), .emoji = try alloc.dupe(u8, t.emoji) };
    return list;
}

const demo_posts = [_]struct { title: []const u8, title_en: []const u8, body: []const u8, body_en: []const u8 }{
    .{ .title = "Como trocar a fonte só das mensagens?", .title_en = "How do I change the font only for messages?", .body = "Queria usar uma fonte monoespaçada na conversa e deixar o resto como está. Dá para fazer pelo tema?", .body_en = "I'd like a monospaced font in the chat and leave the rest alone. Can a theme do that?" },
    .{ .title = "Tema escuro com fundo de estrelas", .title_en = "Dark theme with a starry background", .body = "Fiz um tema com o starfield e cores frias. Segue o arquivo, aceito sugestões de contraste.", .body_en = "Made a theme with the starfield and cold colors. File attached, contrast suggestions welcome." },
    .{ .title = "A barra lateral some ao redimensionar", .title_en = "The sidebar disappears when resizing", .body = "Em janelas muito estreitas a lista de canais desaparece e não volta. Alguém mais vê isso?", .body_en = "In very narrow windows the channel list vanishes and doesn't come back. Anyone else?" },
    .{ .title = "Plugin de lembretes em Lua", .title_en = "Reminder plugin in Lua", .body = "Escrevi um /lembrar que manda uma mensagem depois de um tempo. Está no meu repositório.", .body_en = "Wrote a /remind that sends a message after a while. It's in my repo." },
    .{ .title = "Qual o menor uso de memória que vocês já viram?", .title_en = "What's the lowest memory usage you've seen?", .body = "Aqui fica em 41 MB parado. Curioso para saber o de vocês, com qual driver e quantos servidores.", .body_en = "Mine idles at 41 MB. Curious about yours, with which driver and how many servers." },
    .{ .title = "Atalho para responder à última mensagem", .title_en = "Shortcut to reply to the last message", .body = "Existe? Procurei nas configurações e só achei o de editar.", .body_en = "Is there one? I looked in the settings and only found the edit one." },
    .{ .title = "Guia: montando um tema do zero", .title_en = "Guide: building a theme from scratch", .body = "Passo a passo do layout em KDL até as cores, com os erros mais comuns no caminho.", .body_en = "Step by step from the KDL layout to the colors, with the usual mistakes along the way." },
    .{ .title = "Voz cortando no Wayland", .title_en = "Voice cutting out on Wayland", .body = "O microfone corta a cada poucos segundos no Hyprland. No X11 não acontece.", .body_en = "The mic cuts out every few seconds on Hyprland. It doesn't happen on X11." },
};

const channel_tree = [_]ChannelSeed{
    .{ .name = "informações", .kind = .category, .name_en = "info" },
    .{ .name = "regras", .topic = "leia antes de postar", .name_en = "rules", .topic_en = "read before posting" },
    .{ .name = "anúncios", .unread = true, .topic = "novidades do servidor", .name_en = "announcements", .topic_en = "server news" },
    .{ .name = "geral", .kind = .category, .name_en = "general" },
    .{ .name = "geral", .unread = true, .topic = "papo livre, sem spam 🙏", .name_en = "general", .topic_en = "free talk, no spam 🙏" },
    .{ .name = "memes", .unread = true, .topic = "só o suprassumo", .topic_en = "only the finest" },
    .{ .name = "setups", .topic = "mostra o rice", .topic_en = "show off your rice" },
    .{ .name = "música", .topic = "o que vocês estão ouvindo?", .name_en = "music", .topic_en = "what are you all listening to?" },
    .{ .name = "projetos", .kind = .category, .name_en = "projects" },
    .{ .name = "zig", .unread = true, .topic = "allocators, comptime e sofrimento", .topic_en = "allocators, comptime and suffering" },
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

/// No segundo servidor (e no das threads sem permissão), o #bugs só a
/// moderação vê e no AFK ninguém entra.
fn demoOverwrites(gi: usize, ci: usize) ![]const types.Overwrite {
    if (gi != 1 and gi != locked_guild) return &.{};
    const deny: u64 = switch (ci) {
        11 => types.perm.view_channel,
        15 => types.perm.connect,
        else => return &.{},
    };
    return demoDeny(gi, deny);
}

fn demoDeny(gi: usize, deny: u64) ![]const types.Overwrite {
    const o = try alloc.alloc(types.Overwrite, 1);
    o[0] = .{ .id = guildId(gi), .deny = deny };
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
        .unread = g.unread,
        .mentions = g.mentions,
        .icon = if (g.icon) try std.fmt.allocPrint(alloc, "demo:icon:{d}", .{i}) else null,
        // O primeiro servidor é nosso (dá para mexer em cargos e mensagens).
        .owner = if (i == 0) me_id else 1001,
    };
    const chs = try alloc.alloc(types.Channel, guilds.len * channel_tree.len + 7 + 3);
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
                .unread = ch.unread and gi % 2 == 0,
                .overwrites = try demoOverwrites(gi, ci),
            };
            n += 1;
            // Depois do #música: um fórum e um canal de mídia.
            if (ci == 7 and (gi == thread_guild or gi == locked_guild)) for ([_]Id{ forumId(gi), mediaId(gi) }) |fid| {
                // No servidor sem permissões, só o canal de mídia.
                if (gi == locked_guild and fid == forumId(gi)) continue;
                const media = fid == mediaId(gi);
                chs[n] = .{
                    .id = fid,
                    .guild = guildId(gi),
                    .parent = parent,
                    .kind = .forum,
                    .media = media,
                    .name = try alloc.dupe(u8, if (media) pick("capturas", "screenshots") else pick("ajuda", "help")),
                    .topic = try alloc.dupe(u8, if (media) pick("mostre o seu tema", "show off your theme") else pick("um post por dúvida, com o que você já tentou", "one post per question, with what you've tried")),
                    .position = @intCast(ci),
                    .tags = try demoForumTags(fid),
                    // No canal de mídia de lá ninguém posta.
                    .overwrites = if (gi == locked_guild) try demoDeny(gi, types.perm.send_messages) else &.{},
                };
                n += 1;
            };
        }
    }
    for (0..6) |i| {
        chs[n] = .{
            .id = dmId(i),
            .guild = 0,
            .name = try alloc.dupe(u8, users[i + 1].name),
            .topic = try alloc.dupe(u8, ""),
            .position = @intCast(i),
            .unread = i == 1 or i == 3,
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
                .unread = true,
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

/// Devolve uma lista de mensagens que ninguém assumiu.
fn freeMessages(msgs: []types.Message) void {
    for (msgs) |m| {
        alloc.free(m.content);
        types.freeAttachments(alloc, m.attachments);
        types.freeEmbeds(alloc, m.embeds);
    }
    alloc.free(msgs);
}

/// A conversa de uma thread: a mensagem que a abriu (ou o texto do post, com
/// o ID da própria thread) e respostas de lá até agora.
fn buildThreadHistory(id: Id, t: DemoThread, now_ms: i64) ![]types.Message {
    var prng = std.Random.DefaultPrng.init(id *% 0x9E3779B97F4A7C15);
    const r = prng.random();
    const has_first = t.first_text.len > 0;
    const n: usize = t.count + @intFromBool(has_first);
    const msgs = try alloc.alloc(types.Message, n);
    const start = @divTrunc(types.snowflakeTime(id), 1000);
    const now_s = @divTrunc(now_ms, 1000);
    const step: i64 = @max(@divTrunc(now_s - start, @as(i64, @intCast(n + 1))), 1);
    for (msgs, 0..) |*m, i| {
        const ts = start + step * @as(i64, @intCast(i));
        const first = has_first and i == 0;
        m.* = .{
            .id = if (first) id else types.makeSnowflake((ts + 1) * 1000, demoSeq(id, i)),
            .channel = id,
            .author = if (first) t.first_author else users[r.uintLessThan(usize, 8)].id,
            .timestamp = ts,
            .content = try alloc.dupe(u8, if (first) t.first_text else phrase(r.uintLessThan(usize, phrases.len))),
        };
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
