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
        g.emit(.{ .ready = try buildReady() });
        g.emit(.{ .status = .ready });
        g.next_live_ms = nowMs() + 6000;
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
                .join_voice => |ch| g.emit(.{ .voice_state = .{ .channel = ch, .user = me_id } }),
            };
            cmds.clearRetainingCapacity();
            try g.tick(nowMs());
        }
    }

    fn nextDeadline(g: *Gateway) i64 {
        var d = @min(g.next_live_ms, g.next_latency_ms);
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
                const msgs = try buildHistory(r.channel, now);
                g.emit(.{ .history = .{ .channel = r.channel, .messages = msgs } });
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

const UserSeed = struct { id: Id, name: []const u8, role: u8, status: types.Status, activity: ?[]const u8 = null, activity_en: ?[]const u8 = null };

const users = [_]UserSeed{
    .{ .id = 1000, .name = "rsha", .role = 0, .status = .online, .activity = "Programando em Zig", .activity_en = "Coding in Zig" },
    .{ .id = 1001, .name = "ana.exe", .role = 1, .status = .online, .activity = "Ouvindo Spotify", .activity_en = "Listening to Spotify" },
    .{ .id = 1002, .name = "brunão", .role = 2, .status = .dnd, .activity = "Jogando Hollow Knight", .activity_en = "Playing Hollow Knight" },
    .{ .id = 1003, .name = "kaique", .role = 3, .status = .online },
    .{ .id = 1004, .name = "lulu", .role = 4, .status = .idle, .activity = "Assistindo YouTube", .activity_en = "Watching YouTube" },
    .{ .id = 1005, .name = "duda", .role = 5, .status = .online, .activity = "No Hyprland 🌸", .activity_en = "On Hyprland 🌸" },
    .{ .id = 1006, .name = "thiaguinho", .role = 6, .status = .idle },
    .{ .id = 1007, .name = "mari", .role = 7, .status = .online, .activity = "Jogando Minecraft", .activity_en = "Playing Minecraft" },
    .{ .id = 1008, .name = "gustavo", .role = 2, .status = .offline },
    .{ .id = 1009, .name = "nanda", .role = 3, .status = .offline },
    .{ .id = 1010, .name = "pedro", .role = 5, .status = .offline },
    .{ .id = 1011, .name = "joão vitor", .role = 1, .status = .offline },
};

const GuildSeed = struct { name: []const u8, acronym: []const u8, color: u8, unread: bool = false, mentions: u16 = 0, name_en: ?[]const u8 = null, acronym_en: ?[]const u8 = null };

const guilds = [_]GuildSeed{
    .{ .name = "larperCord dev", .acronym = "LC", .color = 0, .unread = true, .mentions = 3 },
    .{ .name = "Rice do Hyprland", .acronym = "RH", .color = 4, .unread = true, .name_en = "Hyprland Rice", .acronym_en = "HR" },
    .{ .name = "Zig Brasil", .acronym = "Z", .color = 1, .name_en = "Zig Brazil" },
    .{ .name = "os larpers", .acronym = "ol", .color = 3, .unread = true, .mentions = 12, .name_en = "the larpers", .acronym_en = "tl" },
    .{ .name = "CTF da madrugada", .acronym = "CTF", .color = 6, .name_en = "Late-night CTF" },
    .{ .name = "Faculdade 2026", .acronym = "F26", .color = 2, .unread = true, .name_en = "College 2026", .acronym_en = "C26" },
    .{ .name = "Minecraft SMP", .acronym = "MC", .color = 7 },
    .{ .name = "Lo-fi & café", .acronym = "☕", .color = 5, .name_en = "Lo-fi & coffee" },
    .{ .name = "Arch Linux BR", .acronym = "A", .color = 4 },
    .{ .name = "Memes", .acronym = "😂", .color = 1, .unread = true },
};

const ChannelSeed = struct { name: []const u8, kind: types.ChannelKind = .text, unread: bool = false, topic: []const u8 = "", name_en: ?[]const u8 = null, topic_en: ?[]const u8 = null };

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

fn buildReady() !ev.Ready {
    const us = try alloc.alloc(types.User, users.len);
    for (users, 0..) |u, i| us[i] = .{
        .id = u.id,
        .name = try alloc.dupe(u8, u.name),
        .role = u.role,
        .status = u.status,
        .activity = if (u.activity) |a| try alloc.dupe(u8, pick(a, u.activity_en)) else null,
    };
    const gs = try alloc.alloc(types.Guild, guilds.len);
    for (guilds, 0..) |g, i| gs[i] = .{
        .id = guildId(i),
        .name = try alloc.dupe(u8, pick(g.name, g.name_en)),
        .acronym = try alloc.dupe(u8, pick(g.acronym, g.acronym_en)),
        .color = g.color,
        .unread = g.unread,
        .mentions = g.mentions,
    };
    const chs = try alloc.alloc(types.Channel, guilds.len * channel_tree.len + 6);
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
            .unread = i == 1 or i == 3,
            .recipient = users[i + 1].id,
        };
        n += 1;
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
    return .{ .me = me_id, .users = us, .guilds = gs, .channels = chs, .voice = voice };
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
        if (i == n - 1 or r.uintLessThan(u8, 3) != 0) author = if (dmRecipient(channel)) |u| (if (r.boolean()) u else me_id) else users[r.uintLessThan(usize, 8)].id;
        msgs[i] = .{
            .id = types.makeSnowflake(t * 1000, i),
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
    // Imagens (geradas na hora pelo carregador: "demo:N") e um arquivo.
    const pics = [_]struct { back: usize, text: []const u8, url: []const u8, name: []const u8, w: u16, h: u16, text_en: ?[]const u8 = null, name_en: ?[]const u8 = null }{
        .{ .back = 5, .text = "olha o pôr do sol daqui de casa 🌅", .url = "demo:1", .name = "por-do-sol.png", .w = 900, .h = 560, .text_en = "check out the sunset from my place 🌅", .name_en = "sunset.png" },
        .{ .back = 14, .text = "wallpaper novo, que acharam?", .url = "demo:2", .name = "synthwave.png", .w = 720, .h = 720, .text_en = "new wallpaper, thoughts?" },
        .{ .back = 23, .text = "", .url = "demo:3", .name = "aurora.png", .w = 960, .h = 540 },
        .{ .back = 31, .text = "o relatório que eu falei", .url = "demo:file", .name = "relatorio-de-ram.pdf", .w = 0, .h = 0, .text_en = "the report i mentioned", .name_en = "ram-report.pdf" },
    };
    for (pics) |p| {
        const m = &msgs[n - p.back];
        alloc.free(m.content);
        m.content = try alloc.dupe(u8, pick(p.text, p.text_en));
        m.reply_to = 0;
        const list = try alloc.alloc(types.Attachment, 1);
        list[0] = .{ .url = try alloc.dupe(u8, p.url), .filename = try alloc.dupe(u8, pick(p.name, p.name_en)), .width = p.w, .height = p.h, .size = if (p.w == 0) 482_133 else 0 };
        m.attachments = list;
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
