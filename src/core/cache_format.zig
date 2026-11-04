//! Formato do cache de mensagens em disco: um arquivo por canal, binário
//! simples e little-endian, sem dependência nenhuma.
//!
//!   "LCM1"                       assinatura e versão
//!   u64 canal
//!   u32 usuários; cada um: u64 id, str nome, str avatar
//!   u32 mensagens; cada uma:
//!     u64 id, u64 autor, i64 timestamp, u64 reply_to, u8 flags, u8 sistema
//!     str conteúdo
//!     u8 anexos; cada um: str url, str nome, u16 largura, u16 altura,
//!        u32 tamanho, u8 flags, str prévia, str link
//!     u8 reações; cada uma: u8 tamanho, bytes do emoji, u16 quantas, u8 nossa
//!   str = u32 tamanho + bytes
//!
//! A leitura confere cada tamanho contra o que sobrou do arquivo: um arquivo
//! truncado ou estragado vira "sem cache", nunca uma leitura fora do lugar.
//! Embeds (cartões de link) não entram: chegam de novo com o histórico.
const std = @import("std");
const types = @import("types.zig");
const Id = types.Id;

/// LCM2: texto do Discord (`raw`) e emoji personalizado nas reações. Um arquivo
/// antigo é só ignorado (a conversa vem da rede e ele é regravado).
pub const magic = "LCM2";

/// Tetos da leitura (bem acima do que o Discord manda).
const max_str: u32 = 1 << 20;
const max_count: u32 = 100_000;

pub const User = struct { id: Id, name: []const u8, avatar: []const u8 = "" };

pub const Entry = struct {
    msg: types.Message,
    reactions: [8]types.Reaction = @splat(.{}),
    n_reactions: u8 = 0,
};

pub const Decoded = struct {
    channel: Id,
    users: []User,
    entries: []Entry,
};

const msg_edited: u8 = 1;
const att_animated: u8 = 1;
const att_embed: u8 = 2;
const att_video: u8 = 4;

// --- Escrita ------------------------------------------------------------------

/// Monta o arquivo aos poucos: cabeçalho, usuários, mensagens.
pub const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn int(w: Writer, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.out.appendSlice(w.gpa, &b);
    }

    fn str(w: Writer, s: []const u8) !void {
        const n: u32 = @intCast(@min(s.len, max_str));
        try w.int(u32, n);
        try w.out.appendSlice(w.gpa, s[0..n]);
    }

    pub fn begin(w: Writer, channel: Id, n_users: u32) !void {
        try w.out.appendSlice(w.gpa, magic);
        try w.int(u64, channel);
        try w.int(u32, n_users);
    }

    pub fn user(w: Writer, u: User) !void {
        try w.int(u64, u.id);
        try w.str(u.name);
        try w.str(u.avatar);
    }

    pub fn beginMessages(w: Writer, n: u32) !void {
        try w.int(u32, n);
    }

    pub fn message(w: Writer, m: *const types.Message, reactions: []const types.Reaction) !void {
        try w.int(u64, m.id);
        try w.int(u64, m.author);
        try w.int(i64, m.timestamp);
        try w.int(u64, m.reply_to);
        try w.out.append(w.gpa, if (m.edited) msg_edited else 0);
        try w.out.append(w.gpa, @intFromEnum(m.system));
        try w.str(m.content);
        try w.str(m.raw);
        const atts = m.attachments[0..@min(m.attachments.len, 255)];
        try w.out.append(w.gpa, @intCast(atts.len));
        for (atts) |a| {
            try w.str(a.url);
            try w.str(a.filename);
            try w.int(u16, a.width);
            try w.int(u16, a.height);
            try w.int(u32, a.size);
            var f: u8 = 0;
            if (a.animated) f |= att_animated;
            if (a.embed) f |= att_embed;
            if (a.video) f |= att_video;
            try w.out.append(w.gpa, f);
            try w.str(a.still);
            try w.str(a.link);
        }
        const rs = reactions[0..@min(reactions.len, 8)];
        try w.out.append(w.gpa, @intCast(rs.len));
        for (rs) |r| {
            try w.out.append(w.gpa, r.len);
            try w.out.appendSlice(w.gpa, r.text());
            try w.int(u16, r.count);
            try w.out.append(w.gpa, @as(u8, @intFromBool(r.me)) | (@as(u8, @intFromBool(r.animated)) << 1));
            try w.int(u64, r.custom);
        }
    }
};

// --- Leitura ------------------------------------------------------------------

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn need(r: *Reader, n: usize) ![]const u8 {
        if (n > r.b.len - r.i) return error.Corrupt;
        const s = r.b[r.i .. r.i + n];
        r.i += n;
        return s;
    }

    fn int(r: *Reader, comptime T: type) !T {
        const s = try r.need(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn byte(r: *Reader) !u8 {
        return (try r.need(1))[0];
    }

    fn count(r: *Reader) !u32 {
        const n = try r.int(u32);
        if (n > max_count) return error.Corrupt;
        return n;
    }

    /// Texto copiado para `a` (o arquivo lido é liberado depois).
    fn str(r: *Reader, a: std.mem.Allocator) ![]const u8 {
        const n = try r.int(u32);
        if (n > max_str) return error.Corrupt;
        return try a.dupe(u8, try r.need(n));
    }
};

/// Lê um arquivo inteiro. Tudo sai alocado em `arena` (quem chama copia o
/// que for guardar e libera a arena de uma vez).
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !Decoded {
    var r: Reader = .{ .b = bytes };
    if (!std.mem.eql(u8, try r.need(4), magic)) return error.Corrupt;
    const channel = try r.int(u64);
    const n_users = try r.count();
    const users = try arena.alloc(User, n_users);
    for (users) |*u| u.* = .{ .id = try r.int(u64), .name = try r.str(arena), .avatar = try r.str(arena) };
    const n_msgs = try r.count();
    const entries = try arena.alloc(Entry, n_msgs);
    for (entries) |*e| {
        e.* = .{ .msg = .{ .id = 0, .channel = channel, .author = 0, .timestamp = 0, .content = "" } };
        const m = &e.msg;
        m.id = try r.int(u64);
        m.author = try r.int(u64);
        m.timestamp = try r.int(i64);
        m.reply_to = try r.int(u64);
        m.edited = (try r.byte()) & msg_edited != 0;
        const sys = try r.byte();
        m.system = if (sys <= @intFromEnum(types.SystemKind.other)) @enumFromInt(sys) else .other;
        m.content = try r.str(arena);
        m.raw = try r.str(arena);
        const n_att = try r.byte();
        if (n_att > 0) {
            const atts = try arena.alloc(types.Attachment, n_att);
            for (atts) |*a| {
                a.* = .{ .url = try r.str(arena), .filename = try r.str(arena) };
                a.width = try r.int(u16);
                a.height = try r.int(u16);
                a.size = try r.int(u32);
                const f = try r.byte();
                a.animated = f & att_animated != 0;
                a.embed = f & att_embed != 0;
                a.video = f & att_video != 0;
                a.still = try r.str(arena);
                a.link = try r.str(arena);
            }
            m.attachments = atts;
        }
        const n_r = try r.byte();
        if (n_r > 8) return error.Corrupt;
        for (0..n_r) |k| {
            const len = try r.byte();
            if (len > @sizeOf(@FieldType(types.Reaction, "emoji"))) return error.Corrupt;
            var re = types.Reaction.init(try r.need(len));
            re.count = try r.int(u16);
            const rf = try r.byte();
            re.me = rf & 1 != 0;
            re.animated = rf & 2 != 0;
            re.custom = try r.int(u64);
            e.reactions[k] = re;
        }
        e.n_reactions = n_r;
    }
    if (r.i != bytes.len) return error.Corrupt;
    return .{ .channel = channel, .users = users, .entries = entries };
}

test "cache de mensagens vai e volta pelo formato" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const w: Writer = .{ .out = &out, .gpa = gpa };
    try w.begin(77, 1);
    try w.user(.{ .id = 5, .name = "ana.exe", .avatar = "abc" });
    try w.beginMessages(2);
    const att = [_]types.Attachment{.{ .url = "https://cdn/x.png", .filename = "x.png", .width = 10, .height = 20, .size = 99, .embed = true }};
    const m1: types.Message = .{ .id = 100, .channel = 77, .author = 5, .timestamp = 1700000000, .content = "oi **tudo** bem?", .edited = true, .attachments = &att };
    var r = types.Reaction.init("👍");
    r.count = 3;
    r.me = true;
    try w.message(&m1, &.{r});
    const m2: types.Message = .{ .id = 101, .channel = 77, .author = 6, .timestamp = 1700000060, .content = "", .reply_to = 100, .system = .join };
    try w.message(&m2, &.{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const dec = try decode(arena.allocator(), out.items);
    try std.testing.expectEqual(@as(Id, 77), dec.channel);
    try std.testing.expectEqualStrings("ana.exe", dec.users[0].name);
    try std.testing.expectEqual(@as(usize, 2), dec.entries.len);
    const e1 = dec.entries[0];
    try std.testing.expectEqualStrings("oi **tudo** bem?", e1.msg.content);
    try std.testing.expect(e1.msg.edited);
    try std.testing.expectEqualStrings("x.png", e1.msg.attachments[0].filename);
    try std.testing.expect(e1.msg.attachments[0].embed);
    try std.testing.expectEqual(@as(u16, 20), e1.msg.attachments[0].height);
    try std.testing.expectEqual(@as(u8, 1), e1.n_reactions);
    try std.testing.expectEqualStrings("👍", e1.reactions[0].text());
    try std.testing.expect(e1.reactions[0].me);
    try std.testing.expectEqual(types.SystemKind.join, dec.entries[1].msg.system);
    try std.testing.expectEqual(@as(Id, 100), dec.entries[1].msg.reply_to);
}

test "arquivo de cache estragado não passa da leitura" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const w: Writer = .{ .out = &out, .gpa = gpa };
    try w.begin(1, 0);
    try w.beginMessages(1);
    try w.message(&.{ .id = 1, .channel = 1, .author = 2, .timestamp = 0, .content = "uma mensagem qualquer" }, &.{});
    // Cortado em qualquer ponto: erro, nunca leitura fora do arquivo.
    for (0..out.items.len) |n| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try std.testing.expectError(error.Corrupt, decode(arena.allocator(), out.items[0..n]));
    }
    // Tamanho absurdo no meio.
    var bad = try gpa.dupe(u8, out.items);
    defer gpa.free(bad);
    std.mem.writeInt(u32, bad[16..20], 0xFFFF_FFF0, .little);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.Corrupt, decode(arena.allocator(), bad));
}
