//! Valores das configurações. Todas têm efeito de verdade (o que ainda não
//! existe, como a voz, não aparece aqui até existir).
//! São salvos em ~/.config/larpercord/settings.kdl.
const std = @import("std");

pub const Page = enum {
    conta,
    privacidade,
    filtros,
    aparencia,
    acessibilidade,
    chat,
    notificacoes,
    atalhos,
    idioma,
    avancado,
    desempenho,
    plugins,
    sobre,
};

/// Texto curto salvo nas configurações (o proxy). Tamanho fixo: as
/// configurações são copiadas e comparadas byte a byte.
pub const Text = struct {
    len: u8 = 0,
    buf: [255]u8 = @splat(0),

    pub fn slice(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn set(t: *Text, s: []const u8) void {
        const n = @min(s.len, t.buf.len);
        t.* = .{};
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = @intCast(n);
    }
};

pub const Settings = struct {
    open: bool = false,
    page: Page = .aparencia,

    // Aparência / acessibilidade
    font_scale: f32 = 1.0,
    compact: bool = false,
    show_avatars: bool = true,
    reduce_motion: bool = false,
    clock_24h: bool = true,
    show_member_list: bool = true,
    show_status_bar: bool = true,
    underline_links: bool = true,
    role_colors: bool = true,
    /// Status como um anel em volta da foto (em vez da bolinha).
    status_ring: bool = false,
    /// Cor de destaque: 0 = a do tema, 1..8 = as da paleta.
    accent: u8 = 0,
    /// Cantos: 0 = os do tema, 1 = retos, 2 = suaves, 3 = redondos.
    corners: u8 = 0,

    // Chat
    show_spoilers: bool = false,
    autoplay_gifs: bool = true,
    /// Imagens e GIFs que vêm de links (embeds).
    show_embeds: bool = true,
    /// Modo economia: imagens, avatares e anexos só baixam ao clicar.
    data_saver: bool = false,
    /// Prévia do markdown acima da caixa de texto, quando tem formatação.
    md_preview: bool = true,
    /// Canal com não lidas abre na primeira delas, como no Discord (senão, no fim).
    open_at_unread: bool = true,

    // Privacidade
    send_typing: bool = true,
    /// Mensagens apagadas ficam na tela (marcadas) e as editadas guardam o
    /// texto original. Só neste computador.
    message_log: bool = false,
    /// GIFs do Tenor/Giphy direto do site deles (eles veem o IP).
    gif_hosts: bool = false,
    /// Esconde o e-mail e o @usuário na conta.
    streamer_mode: bool = false,
    /// Proxy (socks5h://127.0.0.1:9050…): vazio = conexão direta. Só a mídia
    /// de fora passa por ele, ou tudo com `proxy_all` (net/proxy.zig).
    proxy: Text = .{},
    proxy_all: bool = false,
    /// Emojis usados há pouco, do mais novo para o mais velho (ui/emoji_picker.zig).
    emoji_recent: Text = .{},
    /// Últimas mensagens de cada canal em disco (abrir na hora, busca offline).
    message_cache: bool = true,

    /// Nosso status: 0 online, 1 ausente, 2 não perturbe, 3 invisível.
    /// Reaplicado ao conectar.
    my_status: u8 = 0,

    // Notificações (DMs e menções)
    desktop_notifs: bool = true,
    taskbar_flash: bool = true,

    // Atalhos
    /// Navegação estilo vim com a caixa de texto sem foco (ui/vim.zig).
    vim_keys: bool = false,

    // Avançado
    developer_mode: bool = false,
    hot_reload: bool = true,
    /// 0 = seguir o sistema, 1 = português, 2 = inglês.
    language: u8 = 0,
    /// 0 = escuro, 1 = claro, 2 = seguir o sistema.
    color_mode: u8 = 0,

    /// Muda quando algo que afeta o layout das mensagens muda.
    pub fn layoutKey(s: *const Settings) u32 {
        var h: u32 = @intFromFloat(s.font_scale * 100);
        h = h *% 31 +% @intFromBool(s.compact);
        h = h *% 31 +% @intFromBool(s.show_avatars);
        h = h *% 31 +% @intFromBool(s.show_embeds);
        // No modo economia, emoji personalizado vira `:nome:` (ui/rich.zig).
        h = h *% 31 +% @intFromBool(s.data_saver);
        return h;
    }
};

pub const Field = struct { name: []const u8, kind: enum { boolean, float, byte, text }, offset: usize };

/// Campos persistidos (todos menos `open` e `page`).
pub fn fields() []const Field {
    const S = struct {
        const list = blk: {
            const info = @typeInfo(Settings).@"struct";
            var out: [info.field_names.len]Field = undefined;
            var n: usize = 0;
            for (info.field_names, info.field_types) |fname, ftype| {
                if (std.mem.eql(u8, fname, "open") or std.mem.eql(u8, fname, "page")) continue;
                // Só estes três tipos são salvos byte a byte; outro tipo aqui
                // corromperia o arquivo (ou a memória) ao ler.
                if (ftype != bool and ftype != f32 and ftype != u8 and ftype != Text) @compileError("configuração com tipo não suportado: " ++ fname);
                out[n] = .{
                    .name = fname,
                    .kind = if (ftype == bool) .boolean else if (ftype == f32) .float else if (ftype == Text) .text else .byte,
                    .offset = @offsetOf(Settings, fname),
                };
                n += 1;
            }
            const final = out[0..n].*;
            break :blk final;
        };
    };
    return &S.list;
}

/// Lê um campo booleano ou de um byte pelo índice em `fields()` (para a
/// paleta de comandos). Número quebrado não tem como ler assim: null.
pub fn getByte(s: *const Settings, index: usize) ?u8 {
    const fs = fields();
    if (index >= fs.len or fs[index].kind == .float or fs[index].kind == .text) return null;
    return (@as([*]const u8, @ptrCast(s)) + fs[index].offset)[0];
}

/// Muda um campo booleano (0/1) ou de um byte pelo índice em `fields()`.
pub fn setByte(s: *Settings, index: usize, value: u8) bool {
    const fs = fields();
    if (index >= fs.len) return false;
    const p = @as([*]u8, @ptrCast(s)) + fs[index].offset;
    switch (fs[index].kind) {
        .boolean => @as(*bool, @ptrCast(p)).* = value != 0,
        .byte => p[0] = value,
        .float, .text => return false,
    }
    return true;
}

/// Índice do campo em `fields()` (para tabelas montadas em tempo de compilação).
pub fn fieldIndex(comptime name: []const u8) usize {
    if (!@hasField(Settings, name)) @compileError("configuração inexistente: " ++ name);
    @setEvalBranchQuota(20_000);
    for (fields(), 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    unreachable;
}

/// Serializa em KDL: `settings theme="vidro" compact=#true font_scale=1.1 …`
pub fn write(s: *const Settings, theme_name: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try out.print(gpa, "// gerado pelo larperCord\nsettings theme=\"{s}\"", .{theme_name});
    const base: [*]const u8 = @ptrCast(s);
    for (fields()) |f| {
        switch (f.kind) {
            .boolean => try out.print(gpa, " {s}={s}", .{ f.name, if (@as(*const bool, @ptrCast(base + f.offset)).*) "#true" else "#false" }),
            .float => try out.print(gpa, " {s}={d:.3}", .{ f.name, @as(*const f32, @ptrCast(@alignCast(base + f.offset))).* }),
            .byte => try out.print(gpa, " {s}={d}", .{ f.name, (base + f.offset)[0] }),
            .text => {
                // Aspas e barras não passam na validação; se aparecerem, somem.
                try out.print(gpa, " {s}=\"", .{f.name});
                for (@as(*const Text, @ptrCast(@alignCast(base + f.offset))).slice()) |ch| {
                    if (ch != '"' and ch != '\\' and ch >= 0x20) try out.append(gpa, ch);
                }
                try out.append(gpa, '"');
            },
        }
    }
    try out.append(gpa, '\n');
}

pub fn apply(s: *Settings, node: anytype) void {
    const base: [*]u8 = @ptrCast(s);
    for (fields()) |f| {
        switch (f.kind) {
            .boolean => if (node.flag(f.name)) |v| {
                @as(*bool, @ptrCast(base + f.offset)).* = v;
            },
            .float => if (node.num(f.name)) |v| {
                @as(*f32, @ptrCast(@alignCast(base + f.offset))).* = @floatCast(std.math.clamp(v, 0.5, 3));
            },
            .byte => if (node.num(f.name)) |v| {
                (base + f.offset)[0] = @intFromFloat(std.math.clamp(v, 0, 255));
            },
            .text => if (node.str(f.name)) |v| {
                @as(*Text, @ptrCast(@alignCast(base + f.offset))).set(v);
            },
        }
    }
}

test "configurações vão e voltam pelo KDL" {
    const kdl = @import("../theme/kdl.zig");
    var s: Settings = .{};
    s.compact = true;
    s.font_scale = 1.2;
    s.language = 2;
    s.proxy.set("socks5h://127.0.0.1:9050");
    s.emoji_recent.set("😀 ❤️ pepe:12");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&s, "vidro", &out, std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Settings = .{};
    apply(&back, &nodes[0]);
    try std.testing.expect(back.compact);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), back.font_scale, 0.001);
    try std.testing.expectEqual(@as(u8, 2), back.language);
    try std.testing.expectEqualStrings("socks5h://127.0.0.1:9050", back.proxy.slice());
    try std.testing.expectEqualStrings("😀 ❤️ pepe:12", back.emoji_recent.slice());
    try std.testing.expectEqualStrings("vidro", nodes[0].str("theme").?);
}

test "campos pelo índice (paleta de comandos)" {
    var s: Settings = .{};
    const i = fieldIndex("compact");
    try std.testing.expectEqual(@as(?u8, 0), getByte(&s, i));
    try std.testing.expect(setByte(&s, i, 1));
    try std.testing.expect(s.compact);
    try std.testing.expect(setByte(&s, fieldIndex("color_mode"), 2));
    try std.testing.expectEqual(@as(u8, 2), s.color_mode);
    try std.testing.expect(!setByte(&s, fieldIndex("font_scale"), 1));
    try std.testing.expect(!s.vim_keys and s.md_preview);
}
