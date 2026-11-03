//! Mensagens entre as threads.
//! - `Event`: rede -> app (o que o gateway do Discord manda).
//! - `Command`: app -> rede (o que a gente pede).
//! - `Action`: interface -> app (o que o usuário fez).
//! Strings dentro de `Event` são alocadas com `std.heap.c_allocator` e
//! passam a pertencer ao Store.
const types = @import("types.zig");
const Id = types.Id;

pub const Ready = struct {
    me: Id,
    users: []types.User,
    guilds: []types.Guild,
    channels: []types.Channel,
    /// Pares (canal de voz, usuário).
    voice: []const [2]Id,
    /// Da nossa conta: @usuário e e-mail (alocados; null = não veio).
    username: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const Event = union(enum) {
    ready: Ready,
    message_create: types.Message,
    /// `older`: página antes da mais antiga que já temos (rolou para cima).
    /// `more`: o Discord ainda tem mais antigas.
    history: struct { channel: Id, messages: []types.Message, older: bool = false, more: bool = true },
    typing_start: struct { channel: Id, user: Id },
    /// `content` null = não mudou. `embeds`/`attachments` não nulos trocam os
    /// anteriores (a prévia de um link chega assim, segundos depois).
    /// `local`: edição nossa, aplicada na hora (não vai para o registro).
    message_update: struct { channel: Id, id: Id, content: ?[]const u8, embeds: ?[]types.Embed = null, attachments: ?[]types.Attachment = null, local: bool = false },
    /// `local`: apagada por nós (some de vez, mesmo com o registro ligado).
    message_delete: struct { channel: Id, id: Id, local: bool = false },
    reaction: struct { channel: Id, id: Id, emoji: types.Reaction, user: Id, add: bool },
    /// Usuário visto pela primeira vez (ex.: autor de uma mensagem).
    user_upsert: types.User,
    /// Nome/avatar de um usuário mudou (GUILD_MEMBER_UPDATE, USER_UPDATE).
    user_update: types.User,
    /// Servidor que ficou disponível depois do READY (GUILD_CREATE).
    guild_create: struct { guild: types.Guild, channels: []types.Channel, voice: []const [2]Id },
    guild_delete: Id,
    /// CHANNEL_CREATE / CHANNEL_UPDATE.
    channel_upsert: types.Channel,
    channel_delete: Id,
    /// MESSAGE_ACK: outro dispositivo leu o canal.
    read: Id,
    /// Reações removidas de uma vez (emoji = null limpa todas).
    reaction_clear: struct { channel: Id, id: Id, emoji: ?types.Reaction },
    /// Estado da conexão, para a barra de status.
    status: Connection,
    /// Reação já existente (ao carregar o histórico).
    reaction_set: struct { channel: Id, id: Id, reaction: types.Reaction },
    /// Aviso para mostrar ao usuário (texto alocado).
    notice: []const u8,
    /// `activity` vazio limpa a atividade; null mantém a anterior.
    presence_update: struct { user: Id, status: types.Status, activity: ?[]const u8 = null },
    voice_state: struct { channel: ?Id, user: Id },
    latency: u32,
    /// Cargos de um servidor (nomes alocados), para os grupos da lista de membros.
    roles: struct { guild: Id, roles: []types.Role },
    /// GUILD_MEMBER_LIST_UPDATE: a lista de membros do servidor como o
    /// Discord monta (online por cargo, depois offline). `list_id` muda
    /// quando a lista é de outro canal (permissões diferentes).
    /// `counts`: (grupo, quantos) de todos os grupos, que o Discord manda à parte.
    member_list: struct { guild: Id, list_id: u64, online: u32, total: u32, ops: []types.MemberOp, counts: []const [2]u64 = &.{} },
    /// Cargos e cor do nome de alguém num servidor.
    member_info: struct { guild: Id, user: Id, info: types.MemberInfo },
    /// Ordem dos servidores e pastas (READY / mudança nas configurações).
    guild_folders: []types.GuildFolder,
    /// Perfil completo de alguém (o Store assume os textos).
    profile: struct { user: Id, profile: types.Profile },
    /// Amizade/pedido/bloqueio (`none` = deixou de existir).
    relationship: struct { user: Id, kind: types.Relationship },
};

pub const Connection = enum { connecting, ready, reconnecting, failed, offline };

pub const Command = union(enum) {
    /// `files`: caminhos dos arquivos a enviar (alocados, terminados em 0).
    send_message: struct { channel: Id, content: []const u8, nonce: u64, reply_to: Id = 0, files: []const [:0]const u8 = &.{} },
    edit_message: struct { channel: Id, id: Id, content: []const u8 },
    delete_message: struct { channel: Id, id: Id },
    react: struct { channel: Id, id: Id, emoji: types.Reaction, add: bool },
    fetch_history: Id,
    /// Mais 50 mensagens antes de `before` (rolagem para cima).
    fetch_older: struct { channel: Id, before: Id },
    /// "fulano está digitando" (o Discord limita a um a cada ~8 s).
    typing: Id,
    join_voice: ?Id,
    /// Pede a lista de membros de um servidor, vista do canal aberto (op 14).
    subscribe_guild: struct { guild: Id, channel: Id },
    /// Aceita um pedido de amizade (true) ou remove/recusa/cancela (false).
    relationship: struct { user: Id, accept: bool },
    /// Abre (ou acha) a DM com alguém; chega como CHANNEL_CREATE.
    create_dm: Id,
    /// Perfil completo (banner, bio…) ao abrir o cartão de alguém.
    fetch_profile: struct { user: Id, guild: Id },
    /// Dá (add) ou tira um cargo de alguém.
    member_role: struct { guild: Id, user: Id, role: Id, add: bool },
    shutdown,
};

pub const Action = union(enum) {
    select_guild: Id,
    select_channel: Id,
    close_tab: usize,
    focus_tab: usize,
    next_tab: i32,
    send_message: []const u8,
    toggle_voice: Id,
    leave_voice,
    toggle_mute,
    toggle_deafen,
    typing: Id,
    toggle_category: Id,
    set_theme: usize,
    next_theme: i32,
    open_palette,
    close_palette,
    open_settings,
    close_settings,
    reply: Id,
    edit_message: Id,
    save_edit: []const u8,
    cancel_compose,
    delete_message: Id,
    react: struct { id: Id, emoji: types.Reaction },
    open_dm: Id,
    send_dm: struct { user: Id, text: []const u8 },
    copy: []const u8,
    jump_to: Id,
    mark_read: Id,
    /// Liga/desliga uma opção do tema atual (índice em `Theme.options`).
    set_theme_option: struct { index: usize, value: bool },
    /// "Sair": esquece o token e volta para a tela de login.
    logout,
    /// Abre o seletor de arquivos para anexar.
    pick_files,
    remove_upload: usize,
    /// Ctrl+V com uma imagem na área de transferência.
    paste_image,
    /// Tela de amigos (no lugar da conversa, dentro das mensagens diretas).
    open_friends,
    /// Chegou perto do topo da conversa: busca as mais antigas.
    load_older: Id,
    /// O cartão de perfil abriu: busca o perfil completo (uma vez por pessoa).
    want_profile: Id,
    member_role: struct { guild: Id, user: Id, role: Id, add: bool },
    accept_friend: Id,
    /// Recusa um pedido, cancela o nosso ou desbloqueia.
    remove_relationship: Id,
};
