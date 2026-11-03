//! Modelo de dados, espelhando o do Discord (IDs são snowflakes de 64 bits).
const std = @import("std");

pub const Id = u64;

pub const Status = enum { online, idle, dnd, offline };

pub const ChannelKind = enum { text, voice, category };

pub const User = struct {
    id: Id,
    name: []const u8,
    /// Índice da cor do cargo (o tema decide a cor de cada índice).
    role: u8 = 0,
    status: Status = .offline,
    activity: ?[]const u8 = null,
    /// Hash do avatar no CDN do Discord (null = sem foto).
    /// Na demonstração: "demo:av:N" (gerado, não baixa nada).
    avatar: ?[]const u8 = null,
    /// Decoração do avatar (o "asset" da loja; animada em APNG).
    decoration: ?[]const u8 = null,
};

/// Perfil completo, buscado quando o cartão de alguém abre
/// (GET /users/{id}/profile). Textos alocados; vazio = não tem.
pub const Profile = struct {
    banner: []const u8 = "",
    /// Cor do banner quando não há imagem (0xRRGGBB, 0 = sem).
    accent: u32 = 0,
    bio: []const u8 = "",
    pronouns: []const u8 = "",
};

/// Pasta de servidores da barra lateral (como no cliente oficial).
/// `id` 0 = servidor solto (não é pasta de verdade, tem um servidor só).
pub const GuildFolder = struct {
    id: u64,
    name: []const u8,
    color: u32,
    guilds: []const Id,
};

/// Permissões do Discord que o cliente usa.
pub const perm = struct {
    pub const administrator: u64 = 1 << 3;
    pub const manage_messages: u64 = 1 << 13;
    pub const manage_roles: u64 = 1 << 28;
};

/// Cargo de um servidor. `color` é 0xRRGGBB (0 = sem cor).
pub const Role = struct {
    id: Id,
    guild: Id,
    name: []const u8,
    color: u32 = 0,
    position: i32 = 0,
    permissions: u64 = 0,
    /// Cargo de bot/integração: ninguém dá ou tira à mão.
    managed: bool = false,
};

/// O que a pessoa é da gente (os números são os do Discord).
pub const Relationship = enum(u8) { none = 0, friend = 1, blocked = 2, incoming = 3, outgoing = 4 };

/// Grupos fixos da lista de membros; os outros grupos são cargos (pelo ID).
pub const group_online: Id = 1;
pub const group_offline: Id = 2;

/// O que sabemos de alguém num servidor: cor do nome e cargos (do mais
/// alto para o mais baixo, até 6).
pub const MemberInfo = struct {
    color: u32 = 0,
    roles: [6]Id = @splat(0),
    n_roles: u8 = 0,

    pub fn roleSlice(m: *const MemberInfo) []const Id {
        return m.roles[0..m.n_roles];
    }
};

/// Uma linha da lista de membros, na ordem em que o Discord manda
/// (GUILD_MEMBER_LIST_UPDATE): cabeçalho de grupo ou membro.
pub const MemberItem = union(enum) {
    none,
    group: struct { id: Id, count: u32 },
    member: struct { user: Id, info: MemberInfo = .{} },
};

pub const MemberOp = struct {
    kind: enum { sync, insert, update, delete, invalidate },
    /// SYNC/INVALIDATE: faixa [index, end]; INSERT/UPDATE/DELETE: a posição.
    index: u32,
    end: u32 = 0,
    /// Alocado com o c_allocator (vazio em DELETE/INVALIDATE).
    items: []const MemberItem = &.{},
};

pub const Guild = struct {
    id: Id,
    name: []const u8,
    /// Texto do ícone quando não há imagem ("LC", "☕"...).
    acronym: []const u8,
    color: u8 = 0,
    unread: bool = false,
    mentions: u16 = 0,
    /// Hash do ícone no CDN (null = mostra a sigla).
    icon: ?[]const u8 = null,
    /// Dono do servidor (tem todas as permissões).
    owner: Id = 0,
};

pub const Channel = struct {
    id: Id,
    guild: Id,
    parent: ?Id = null,
    kind: ChannelKind = .text,
    name: []const u8,
    topic: []const u8 = "",
    position: u16 = 0,
    unread: bool = false,
    /// Em DMs (guild = 0): a outra pessoa da conversa.
    recipient: Id = 0,
    /// Grupo (DM com várias pessoas): todos os participantes menos a gente.
    /// Vazio numa DM comum. Alocado com o c_allocator.
    recipients: []const Id = &.{},
    /// Ícone do grupo (hash no CDN).
    icon: ?[]const u8 = null,
    /// DM em grupo (tipo 3 do Discord), mesmo que só reste uma pessoa.
    group: bool = false,
};

/// Anexo de uma mensagem. `url` pode ser https:// (CDN do Discord),
/// file:// (arquivo nosso ainda subindo) ou demo:N (imagem da demonstração).
pub const Attachment = struct {
    url: []const u8,
    filename: []const u8,
    /// Tamanho da imagem (0 = não é imagem). Vem junto com a mensagem, então
    /// dá pra reservar o espaço antes de a imagem chegar.
    width: u16 = 0,
    height: u16 = 0,
    size: u32 = 0,
    animated: bool = false,
    /// Prévia parada (GIF do Tenor/Giphy: `url` é o GIF no site deles,
    /// `still` é a miniatura pelo proxy do Discord). Vazio = não tem.
    still: []const u8 = "",
    /// Veio de um link (embed), não foi anexado: some com
    /// Configurações → Chat → Mostrar imagens de links desligado.
    embed: bool = false,
    /// Vídeo: `url` é a prévia (um quadro, pelo proxy) e `link` o vídeo,
    /// que abre no navegador.
    video: bool = false,
    link: []const u8 = "",

    pub fn isImage(a: *const Attachment) bool {
        return a.width > 0 and a.height > 0;
    }
};

/// Libera os anexos (alocados com `gpa`, como o resto da mensagem).
pub fn freeAttachments(gpa: std.mem.Allocator, list: []const Attachment) void {
    for (list) |a| freeAttachment(gpa, a);
    if (list.len > 0) gpa.free(list);
}

/// Só os textos de um anexo (a lista em que ele está não).
pub fn freeAttachment(gpa: std.mem.Allocator, a: Attachment) void {
    gpa.free(a.url);
    gpa.free(a.filename);
    if (a.still.len > 0) gpa.free(a.still);
    if (a.link.len > 0) gpa.free(a.link);
}

/// Cartão de link/bot (embed "rich", "article", "link", "video"…).
/// Textos alocados com o mesmo alocador da mensagem; vazio = não tem.
pub const Embed = struct {
    /// 0xRRGGBB; `has_color` diz se veio cor (preto também é cor).
    color: u32 = 0,
    has_color: bool = false,
    provider: []const u8 = "",
    author: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
    footer: []const u8 = "",
    fields: []const EmbedField = &.{},
    /// Imagem grande (ou a prévia do vídeo) e a miniatura do canto.
    image: []const u8 = "",
    image_w: u16 = 0,
    image_h: u16 = 0,
    thumb: []const u8 = "",
    /// Tem vídeo (YouTube…): a imagem ganha um botão de play que abre `url`.
    video: bool = false,
};

pub const EmbedField = struct { name: []const u8, value: []const u8 };

pub fn freeEmbeds(gpa: std.mem.Allocator, list: []const Embed) void {
    for (list) |e| freeEmbed(gpa, e);
    if (list.len > 0) gpa.free(list);
}

/// Só os textos de um embed (a lista em que ele está não).
pub fn freeEmbed(gpa: std.mem.Allocator, e: Embed) void {
    for ([_][]const u8{ e.provider, e.author, e.title, e.url, e.description, e.footer, e.image, e.thumb }) |t| if (t.len > 0) gpa.free(t);
    for (e.fields) |f| {
        gpa.free(f.name);
        gpa.free(f.value);
    }
    if (e.fields.len > 0) gpa.free(e.fields);
}

pub const Message = struct {
    id: Id,
    channel: Id,
    author: Id,
    /// Segundos desde 1970 (UTC).
    timestamp: i64,
    content: []const u8,
    /// Identificador local de uma mensagem enviada por nós, para casar a
    /// confirmação do servidor com a cópia "pendente" já exibida.
    nonce: u64 = 0,
    /// Mensagem que esta responde (0 = nenhuma).
    reply_to: Id = 0,
    edited: bool = false,
    attachments: []const Attachment = &.{},
    embeds: []const Embed = &.{},
    /// Mensagem de sistema (entrou, saiu, chamada, fixou…): `content` já
    /// vem com o texto pronto e a interface desenha como uma linha cinza.
    system: SystemKind = .none,
};

pub const SystemKind = enum(u8) { none, join, leave, call, pin, edit, boost, other };

/// Uma reação: o emoji (UTF-8, até 15 bytes), quantas pessoas e se inclui a gente.
pub const Reaction = struct {
    emoji: [16]u8 = @splat(0),
    len: u8 = 0,
    count: u16 = 0,
    me: bool = false,

    pub fn text(r: *const Reaction) []const u8 {
        return r.emoji[0..r.len];
    }

    pub fn init(e: []const u8) Reaction {
        var r: Reaction = .{};
        const n = @min(e.len, 15);
        @memcpy(r.emoji[0..n], e[0..n]);
        r.len = @intCast(n);
        return r;
    }
};

/// Timestamp embutido num snowflake do Discord (ms desde 2015-01-01).
pub fn snowflakeTime(id: Id) i64 {
    return @intCast((id >> 22) + 1420070400000);
}

pub fn makeSnowflake(ms: i64, seq: u64) Id {
    const since: u64 = @intCast(ms - 1420070400000);
    return (since << 22) | (seq & 0x3fffff);
}

test "snowflake ida e volta" {
    const ms: i64 = 1_793_000_000_123;
    try std.testing.expectEqual(ms, snowflakeTime(makeSnowflake(ms, 7)));
}
