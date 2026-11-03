//! Dados falsos para o protótipo visual (sem rede).
const std = @import("std");

pub const Status = enum { online, idle, dnd, offline };

pub const User = struct {
    name: []const u8,
    role: u8,
    status: Status,
    activity: ?[]const u8 = null,
};

pub const users = [_]User{
    .{ .name = "rsha", .role = 0, .status = .online, .activity = "Programando em Zig" },
    .{ .name = "ana.exe", .role = 1, .status = .online, .activity = "Ouvindo Spotify" },
    .{ .name = "brunão", .role = 2, .status = .dnd, .activity = "Jogando Hollow Knight" },
    .{ .name = "kaique", .role = 3, .status = .online },
    .{ .name = "lulu", .role = 4, .status = .idle, .activity = "Assistindo YouTube" },
    .{ .name = "duda", .role = 5, .status = .online, .activity = "No Hyprland 🌸" },
    .{ .name = "thiaguinho", .role = 6, .status = .idle },
    .{ .name = "mari", .role = 7, .status = .online, .activity = "Jogando Minecraft" },
    .{ .name = "gustavo", .role = 2, .status = .offline },
    .{ .name = "nanda", .role = 3, .status = .offline },
    .{ .name = "pedro", .role = 5, .status = .offline },
    .{ .name = "joão vitor", .role = 1, .status = .offline },
};

pub const Guild = struct {
    name: []const u8,
    initials: []const u8,
    color: u8,
    unread: bool = false,
    mentions: u8 = 0,
};

pub const guilds = [_]Guild{
    .{ .name = "larperCord dev", .initials = "LC", .color = 0, .unread = true, .mentions = 3 },
    .{ .name = "Rice do Hyprland", .initials = "RH", .color = 4, .unread = true },
    .{ .name = "Zig Brasil", .initials = "Z", .color = 1 },
    .{ .name = "os larpers", .initials = "ol", .color = 3, .unread = true, .mentions = 12 },
    .{ .name = "CTF da madrugada", .initials = "CTF", .color = 6 },
    .{ .name = "Faculdade 2026", .initials = "F26", .color = 2, .unread = true },
    .{ .name = "Minecraft SMP", .initials = "MC", .color = 7 },
    .{ .name = "Lo-fi & café", .initials = "☕", .color = 5 },
    .{ .name = "Arch Linux BR", .initials = "A", .color = 4 },
    .{ .name = "Memes", .initials = "😂", .color = 1, .unread = true },
};

pub const ChannelKind = enum { text, voice };

pub const Channel = struct {
    name: []const u8,
    kind: ChannelKind = .text,
    category: u8,
    unread: bool = false,
    topic: []const u8 = "",
};

pub const categories = [_][]const u8{ "informações", "geral", "projetos", "voz" };

pub const channels = [_]Channel{
    .{ .name = "regras", .category = 0, .topic = "leia antes de postar" },
    .{ .name = "anúncios", .category = 0, .unread = true, .topic = "novidades do servidor" },
    .{ .name = "geral", .category = 1, .unread = true, .topic = "papo livre, sem spam 🙏" },
    .{ .name = "memes", .category = 1, .unread = true, .topic = "só o suprassumo" },
    .{ .name = "setups", .category = 1, .topic = "mostra o rice" },
    .{ .name = "música", .category = 1, .topic = "o que vocês estão ouvindo?" },
    .{ .name = "zig", .category = 2, .unread = true, .topic = "allocators, comptime e sofrimento" },
    .{ .name = "interface", .category = 2, .topic = "design do larperCord" },
    .{ .name = "bugs", .category = 2, .topic = "reporte com print" },
    .{ .name = "Call da madrugada", .kind = .voice, .category = 3 },
    .{ .name = "Jogando", .kind = .voice, .category = 3 },
    .{ .name = "AFK", .kind = .voice, .category = 3 },
};

/// Quem está em cada canal de voz (índice do canal -> usuários).
pub fn voiceMembers(channel: usize) []const u8 {
    return switch (channel) {
        9 => &.{ 1, 5, 3 },
        10 => &.{2},
        else => &.{},
    };
}

const phrases = [_][]const u8{
    "bom dia rapaziada ☀️",
    "alguém vai jogar hoje à noite?",
    "kkkkkkkkkkkkk",
    "olha o `ps aux` do vesktop: **1.28 GB** de RAM pra mandar mensagem 💀",
    "@rsha viu isso aqui?",
    "acabei de atualizar pro zig 0.17 e quebrou tudo de novo 🙃",
    "mano o hyprland novo tá muito liso",
    "**finalmente** consegui compilar",
    "alguém tem um wallpaper bom aí? to cansado do meu",
    "isso é muito larper kkkk",
    "vou dormir, amanhã cedo tenho prova 😴",
    "tá, mas e o allocator? quem dá free nisso?",
    "manda o print",
    "que isso, ficou lindo demais 😍",
    "eu acho que o problema é o cache, tenta limpar com `rm -rf ~/.cache/zig` e compila de novo",
    "imagina um cliente de discord que abre em 200ms e gasta 30MB. seria o sonho né",
    "@duda tu usa qual tema no kitty?",
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
    "@kaique bora?",
    "pior que faz sentido",
    "vou testar aqui e já falo",
    "funcionou!!! 🎉",
};

pub const Message = struct {
    author: u8,
    /// Minutos desde o início do histórico.
    minute: u32,
    text: []const u8,
    group_start: bool,
    day_break: bool,
};

pub fn genMessages(gpa: std.mem.Allocator, seed: u64, n: usize) !std.ArrayList(Message) {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var list: std.ArrayList(Message) = try .initCapacity(gpa, n);

    var minute: u32 = 0;
    var author: u8 = 0;
    for (0..n) |i| {
        const gap = if (rnd.uintLessThan(u32, 10) == 0) rnd.intRangeLessThan(u32, 30, 300) else rnd.uintLessThan(u32, 4);
        minute += gap;
        if (i == 0 or rnd.uintLessThan(u32, 3) != 0)
            author = @intCast(rnd.uintLessThan(usize, 8));
        list.appendAssumeCapacity(.{
            .author = author,
            .minute = minute,
            .text = phrases[rnd.uintLessThan(usize, phrases.len)],
            .group_start = false,
            .day_break = false,
        });
    }
    // Termina "agora": ajusta para que a última mensagem seja de hoje às 23:00.
    const end: u32 = 23 * 60;
    const total = minute;
    const days_back = (total + 1440 - end) / 1440;
    const offset = days_back * 1440 + end - total;
    for (list.items) |*m| m.minute += offset;
    regroup(list.items);
    return list;
}

/// Recalcula início de grupos e quebras de dia.
pub fn regroup(msgs: []Message) void {
    for (msgs, 0..) |*m, i| {
        if (i == 0) {
            m.group_start = true;
            m.day_break = true;
            continue;
        }
        const prev = msgs[i - 1];
        m.day_break = prev.minute / 1440 != m.minute / 1440;
        m.group_start = m.day_break or prev.author != m.author or m.minute - prev.minute > 7;
    }
}

/// Índice do dia "hoje" para um histórico (o dia da última mensagem).
pub fn today(msgs: []const Message) u32 {
    if (msgs.len == 0) return 0;
    return msgs[msgs.len - 1].minute / 1440;
}
