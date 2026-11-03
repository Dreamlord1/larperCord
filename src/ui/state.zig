//! Estado que só a interface usa: o que está selecionado, abas, rolagem,
//! paleta. Os dados em si ficam no Store.
const std = @import("std");
const Id = @import("../core/types.zig").Id;
pub const Settings = @import("settings_state.zig").Settings;

pub const MenuKind = enum { message, user, channel, guild };

pub const Popup = union(enum) {
    none,
    menu: struct { kind: MenuKind, id: Id, x: f32, y: f32 },
    profile: struct { user: Id, x: f32, y: f32 },
    /// `target` = mensagem que vai receber a reação (0 = caixa de texto).
    emoji: struct { target: Id, x: f32, y: f32 },
};

/// Seleção de texto entre mensagens: âncora e cabeça (mensagem + byte).
pub const Selection = struct {
    channel: Id = 0,
    a_id: Id = 0,
    a_off: u32 = 0,
    b_id: Id = 0,
    b_off: u32 = 0,
    dragging: bool = false,

    pub fn empty(s: *const Selection) bool {
        return s.channel == 0 or (s.a_id == s.b_id and s.a_off == s.b_off);
    }
};

pub const Scroll = struct {
    pos: f32 = -1,
    target: f32 = 0,
    stick_bottom: bool = true,
};

pub const Toast = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    until_ms: i64 = 0,
    is_error: bool = false,

    pub fn text(t: *const Toast) []const u8 {
        return t.buf[0..t.len];
    }
};

pub const PaletteItem = struct {
    label: []const u8,
    hint: []const u8 = "",
    kind: enum { channel, guild, theme, action },
    id: Id = 0,
    index: usize = 0,
    score: i32 = 0,
};

pub const Palette = struct {
    open: bool = false,
    query: [128]u8 = @splat(0),
    selected: usize = 0,
    focus: bool = false,
    items: std.ArrayList(PaletteItem) = .empty,
    /// Textos montados para os itens (liberados ao reconstruir a lista).
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
};

pub const State = struct {
    gpa: std.mem.Allocator,
    guild: Id = 0,
    /// Canais abertos em abas; `tab` é a ativa.
    tabs: std.ArrayList(Id) = .empty,
    tab: usize = 0,
    /// Último canal aberto em cada servidor.
    last_channel: std.AutoHashMapUnmanaged(Id, Id) = .empty,
    voice: ?Id = null,
    muted: bool = false,
    deafened: bool = false,
    collapsed: std.AutoHashMapUnmanaged(Id, void) = .empty,
    input: [2000]u8 = @splat(0),
    focus_input: bool = true,
    scroll: std.AutoHashMapUnmanaged(Id, Scroll) = .empty,
    palette: Palette = .{},
    settings: Settings = .{},
    popup: Popup = .none,
    /// Caixa de texto do cartão de perfil ("Mensagem @fulano").
    popup_input: [256]u8 = @splat(0),
    reply_to: Id = 0,
    editing: Id = 0,
    /// O conteúdo de `input` mudou por fora: a caixa de texto deve recarregar.
    input_sync: bool = false,
    edit_last: bool = false,
    selection: Selection = .{},
    jump: Id = 0,
    jump_until_ms: i64 = 0,
    muted_channels: std.AutoHashMapUnmanaged(Id, void) = .empty,
    toast: Toast = .{},
    /// Contador de "geração" do tema (invalida caches de layout).
    theme_gen: u8 = 0,
    nonce: u64 = 1,
    /// Buffers reaproveitados a cada quadro pela lista de mensagens.
    offsets: std.ArrayList(f32) = .empty,
    groups: std.ArrayList(u8) = .empty,

    pub fn activeChannel(s: *const State) ?Id {
        return if (s.tab < s.tabs.items.len) s.tabs.items[s.tab] else null;
    }

    pub fn scrollOf(s: *State, ch: Id) *Scroll {
        const gop = s.scroll.getOrPut(s.gpa, ch) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn showToast(s: *State, now_ms: i64, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&s.toast.buf, fmt, args) catch s.toast.buf[0..0];
        s.toast.len = out.len;
        s.toast.until_ms = now_ms + if (is_error) @as(i64, 6000) else 1800;
        s.toast.is_error = is_error;
    }
};
