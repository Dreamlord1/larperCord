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
};

pub const Event = union(enum) {
    ready: Ready,
    message_create: types.Message,
    history: struct { channel: Id, messages: []types.Message },
    typing_start: struct { channel: Id, user: Id },
    presence_update: struct { user: Id, status: types.Status },
    voice_state: struct { channel: ?Id, user: Id },
    latency: u32,
};

pub const Command = union(enum) {
    send_message: struct { channel: Id, content: []const u8, nonce: u64 },
    fetch_history: Id,
    join_voice: ?Id,
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
    toggle_category: Id,
    set_theme: usize,
    next_theme: i32,
    open_palette,
    close_palette,
    open_settings,
    close_settings,
};
