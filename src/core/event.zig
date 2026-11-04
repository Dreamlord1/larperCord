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
    /// `raw`: o texto como o Discord guarda, quando difere de `content`
    /// (emoji personalizado); passa a pertencer ao Store.
    message_update: struct { channel: Id, id: Id, content: ?[]const u8, raw: ?[]const u8 = null, embeds: ?[]types.Embed = null, attachments: ?[]types.Attachment = null, local: bool = false },
    /// O Discord não aceitou (ou não recebeu) uma mensagem nossa.
    send_failed: struct { channel: Id, nonce: u64 },
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
    /// `activities`: null mantém as anteriores, vazio limpa (o Store assume).
    presence_update: struct { user: Id, status: types.Status, activity: ?[]const u8 = null, activities: ?[]types.Activity = null },
    voice_state: struct { channel: ?Id, user: Id },
    /// Estado da nossa conexão de voz (a barra "Voz conectada").
    voice_status: struct { status: VoiceStatus, channel: Id = 0 },
    /// Alguém começou/parou de falar na call (o anel verde).
    voice_speaking: struct { user: Id, speaking: bool },
    latency: u32,
    /// Cargos de um servidor (nomes alocados), para os grupos da lista de membros.
    roles: struct { guild: Id, roles: []types.Role },
    /// GUILD_MEMBER_LIST_UPDATE: a lista de membros do servidor como o
    /// Discord monta (online por cargo, depois offline). `list_id` muda
    /// quando a lista é de outro canal (permissões diferentes).
    /// `counts`: (grupo, quantos) de todos os grupos, que o Discord manda à parte.
    member_list: struct { guild: Id, list_id: u64, online: u32, total: u32, ops: []types.MemberOp, counts: []const [2]u64 = &.{} },
    /// Cargo apagado / alguém saiu do servidor (GUILD_ROLE_DELETE, GUILD_MEMBER_REMOVE).
    role_delete: Id,
    member_remove: struct { guild: Id, user: Id },
    /// Todos os nossos cargos num servidor (o `member_info` guarda só os 6
    /// mais altos; as exceções dos canais podem citar qualquer um).
    my_roles: struct { guild: Id, roles: []Id },
    /// Cargos e cor do nome de alguém num servidor.
    member_info: struct { guild: Id, user: Id, info: types.MemberInfo },
    /// Ordem dos servidores e pastas (READY / mudança nas configurações).
    guild_folders: []types.GuildFolder,
    /// Perfil completo de alguém (o Store assume os textos).
    profile: struct { user: Id, profile: types.Profile },
    /// Amizade/pedido/bloqueio (`none` = deixou de existir).
    relationship: struct { user: Id, kind: types.Relationship, since_ms: i64 = 0 },
    /// Nota que só a gente vê sobre alguém (texto alocado; vazio = sem).
    note: struct { user: Id, text: []const u8 },
    /// Ícone de uma aplicação (jogo), para a atividade sem imagem.
    app_icon: struct { app: Id, icon: []const u8 },
    /// Menções recentes (GET /users/@me/mentions), para a caixa de entrada.
    recent_mentions: []types.Message,
    /// THREAD_LIST_SYNC: todas as threads ativas de `parents` (null = do
    /// servidor inteiro). A que não veio foi arquivada ou sumiu para nós.
    /// `joined`: em quais delas estamos.
    thread_list_sync: struct { guild: Id, parents: ?[]Id = null, threads: []types.Channel, joined: []Id = &.{} },
    /// Uma página de threads de um canal, sob demanda (fórum ou arquivadas).
    /// `failed`: não veio; nada do que já há na lista se perde.
    threads_page: struct { channel: Id, archived: bool, threads: []types.Channel = &.{}, previews: []types.ThreadPreview = &.{}, joined: []Id = &.{}, more: bool = false, failed: bool = false },
    /// Entramos ou saímos de uma thread (THREAD_MEMBER_UPDATE, ou o REST confirmou).
    thread_joined: struct { thread: Id, joined: bool },
    /// Quem está numa thread. `replace`: `added` é a lista inteira.
    thread_members: struct { thread: Id, replace: bool = false, count: ?u32 = null, added: []Id = &.{}, removed: []Id = &.{} },
    /// A thread que acabamos de criar existe: abre ela.
    thread_open: Id,
};

pub const Connection = enum { connecting, ready, reconnecting, failed, offline };

pub const VoiceStatus = enum { disconnected, connecting, connected };

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
    /// Entrar (channel != null) ou sair da call.
    join_voice: struct { guild: Id, channel: ?Id, mute: bool = false, deaf: bool = false },
    /// Mudou mudo/ensurdecer com a call já conectada.
    voice_flags: struct { mute: bool, deaf: bool },
    /// Volume individual de quem está falando (0..2).
    voice_volume: struct { user: Id, volume: f32 },
    /// Pede a lista de membros de um servidor, vista do canal aberto (op 14).
    /// `channel` é sempre um canal de verdade (o pai, se for thread); `thread`
    /// pede também a lista de quem está nela.
    subscribe_guild: struct { guild: Id, channel: Id, thread: Id = 0 },
    /// Aceita um pedido de amizade (true) ou remove/recusa/cancela (false).
    relationship: struct { user: Id, accept: bool },
    /// Abre (ou acha) a DM com alguém; chega como CHANNEL_CREATE.
    create_dm: Id,
    /// Perfil completo (banner, bio…) ao abrir o cartão de alguém.
    fetch_profile: struct { user: Id, guild: Id },
    /// Dá (add) ou tira um cargo de alguém.
    member_role: struct { guild: Id, user: Id, role: Id, add: bool },
    /// Nosso status (offline = invisível), pelo gateway (op 3).
    set_status: types.Status,
    /// Guarda a nota sobre alguém (PUT /users/@me/notes/{id}).
    set_note: struct { user: Id, text: []const u8 },
    /// Ícone de uma aplicação (GET /applications/{id}/rpc).
    fetch_app: Id,
    /// Move alguém para outro canal de voz (null = desconecta da call).
    move_member: struct { guild: Id, user: Id, channel: ?Id },
    /// As 25 menções mais recentes (só leitura), chegam como `recent_mentions`.
    fetch_mentions,
    /// Uma página de threads de um canal. Ativas: por `offset`; arquivadas:
    /// as de antes de `before` (s; 0 = as mais recentes).
    fetch_threads: struct { channel: Id, guild: Id, archived: bool, offset: u32 = 0, before: i64 = 0 },
    /// Thread a partir de uma mensagem (nome alocado).
    create_thread: struct { channel: Id, message: Id, name: []const u8 },
    /// Post novo num fórum (textos e tags alocados).
    create_post: struct { forum: Id, name: []const u8, content: []const u8, tags: []const Id },
    /// Entrar (true) ou sair de uma thread.
    join_thread: struct { thread: Id, join: bool },
    /// Quem está na thread, pelo REST (a lista do op 14 pode não vir).
    fetch_thread_members: Id,
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
    /// Volume individual de alguém na call (0 = mudo, 1 = normal, 2 = dobro).
    set_voice_volume: struct { user: Id, volume: f32 },
    /// Abre/fecha o mixer de voz (a lista de quem está na call com volumes).
    toggle_voice_mixer,
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
    /// Cor personalizada do tema atual/modo atual; rgba null limpa.
    set_theme_color: struct { slot: u8, rgba: ?u32 },
    /// Esquece todas as cores personalizadas do tema atual.
    reset_theme_colors,
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
    /// A conversa não carregou: pede de novo.
    retry_history: Id,
    /// Mensagem que não foi: manda de novo ou joga fora.
    resend_message: struct { channel: Id, nonce: u64 },
    discard_message: struct { channel: Id, nonce: u64 },
    /// O cartão de perfil abriu: busca o perfil completo (uma vez por pessoa).
    want_profile: Id,
    /// Online, ausente, não perturbe ou invisível (offline).
    set_status: types.Status,
    member_role: struct { guild: Id, user: Id, role: Id, add: bool },
    /// Muda uma configuração (índice em settings_state.fields(); booleano
    /// 0/1 ou byte) e salva. Usado pela paleta de comandos.
    set_setting: struct { index: usize, value: u8 },
    accept_friend: Id,
    /// Recusa um pedido, cancela o nosso ou desbloqueia.
    remove_relationship: Id,
    /// Perfil grande (o cartão com abas); `tab`: 0 atividade, 1 amigos, 2 servidores.
    open_full_profile: struct { user: Id, tab: u8 = 0 },
    set_note: struct { user: Id, text: []const u8 },
    /// Atividade sem imagem: busca o ícone do jogo (uma vez por aplicação).
    want_app_icon: Id,
    move_member: struct { guild: Id, user: Id, channel: ?Id },
    /// Abre/fecha a caixa de entrada (Ctrl+I) e as mensagens salvas.
    toggle_inbox,
    toggle_saved,
    /// Busca (de novo) as menções recentes da aba "Menções".
    fetch_mentions,
    /// Mensagens salvas: só locais (nada vai para o Discord).
    save_message: Id,
    unsave_message: Id,
    /// Troca a anotação (texto alocado com o gpa da interface).
    saved_note: struct { id: Id, text: []const u8 },
    /// "Cor do servidor": destaque enquanto o servidor está aberto; null limpa.
    set_guild_color: struct { guild: Id, rgb: ?u32 },
    /// Várias contas: troca (desconecta e entra na outra), volta à tela de
    /// login sem esquecer as guardadas, esquece uma conta.
    switch_account: Id,
    add_account,
    remove_account: Id,
    /// Configurações → Privacidade → Apagar cache.
    clear_cache,
    /// Textos alocados com o gpa da interface.
    create_thread: struct { message: Id, name: []const u8 },
    create_post: struct { forum: Id, name: []const u8, content: []const u8, tags: []const Id },
    join_thread: struct { thread: Id, join: bool },
    /// A primeira página (se ainda não veio ou falhou) ou a próxima.
    fetch_threads: struct { channel: Id, archived: bool },
};
