//! Valores das configurações. Todas têm efeito de verdade (o que ainda não
//! existe, como a voz, não aparece aqui até existir).
//! São salvos em ~/.config/larpercord/settings.kdl.
const std = @import("std");

pub const Page = enum {
    conta,
    privacidade,
    aparencia,
    acessibilidade,
    chat,
    notificacoes,
    atalhos,
    idioma,
    avancado,
    desempenho,
    sobre,
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

    // Privacidade
    send_typing: bool = true,
    /// Mensagens apagadas ficam na tela (marcadas) e as editadas guardam o
    /// texto original. Só neste computador.
    message_log: bool = false,
    /// GIFs do Tenor/Giphy direto do site deles (eles veem o IP).
    gif_hosts: bool = false,
    /// Esconde o e-mail e o @usuário na conta.
    streamer_mode: bool = false,

    /// Nosso status: 0 online, 1 ausente, 2 não perturbe, 3 invisível.
    /// Reaplicado ao conectar.
    my_status: u8 = 0,

    // Notificações (DMs e menções)
    desktop_notifs: bool = true,
    taskbar_flash: bool = true,

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
        return h;
    }
};

pub const Field = struct { name: []const u8, kind: enum { boolean, float, byte }, offset: usize };

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
                if (ftype != bool and ftype != f32 and ftype != u8) @compileError("configuração com tipo não suportado: " ++ fname);
                out[n] = .{
                    .name = fname,
                    .kind = if (ftype == bool) .boolean else if (ftype == f32) .float else .byte,
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

/// Serializa em KDL: `settings theme="vidro" compact=#true font_scale=1.1 …`
pub fn write(s: *const Settings, theme_name: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try out.print(gpa, "// gerado pelo larperCord\nsettings theme=\"{s}\"", .{theme_name});
    const base: [*]const u8 = @ptrCast(s);
    for (fields()) |f| {
        switch (f.kind) {
            .boolean => try out.print(gpa, " {s}={s}", .{ f.name, if (@as(*const bool, @ptrCast(base + f.offset)).*) "#true" else "#false" }),
            .float => try out.print(gpa, " {s}={d:.3}", .{ f.name, @as(*const f32, @ptrCast(@alignCast(base + f.offset))).* }),
            .byte => try out.print(gpa, " {s}={d}", .{ f.name, (base + f.offset)[0] }),
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
                @as(*f32, @ptrCast(@alignCast(base + f.offset))).* = @floatCast(v);
            },
            .byte => if (node.num(f.name)) |v| {
                (base + f.offset)[0] = @intFromFloat(std.math.clamp(v, 0, 255));
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
    try std.testing.expectEqualStrings("vidro", nodes[0].str("theme").?);
}
