//! Mensagens salvas com anotação. Ficam só neste computador (nada vai para o
//! Discord), num JSON por conta no diretório de configuração (quem lê e
//! grava o arquivo é ui/saved.zig). Guardamos uma cópia do que importa
//! (autor, texto, canal, servidor, data, link): a mensagem pode sumir da
//! memória ou do Discord e a salva continua legível.
const std = @import("std");
const types = @import("types.zig");
const markdown = @import("markdown.zig");
const Store = @import("store.zig").Store;
const j = @import("../net/jsonx.zig");
const Id = types.Id;

pub const max_items = 500;
pub const max_note = 1000;

pub const Item = struct {
    id: Id,
    channel: Id,
    /// 0 = mensagem direta.
    guild: Id = 0,
    author: Id,
    /// Segundos desde 1970 (da mensagem e de quando foi salva).
    timestamp: i64,
    saved_at: i64,
    author_name: []const u8,
    channel_name: []const u8,
    guild_name: []const u8,
    content: []const u8,
    link: []const u8,
    note: []const u8,
    /// Markdown do conteúdo, para a prévia (fatias de `content`).
    spans: []const markdown.Span = &.{},

    fn free(it: *const Item, gpa: std.mem.Allocator) void {
        for ([_][]const u8{ it.author_name, it.channel_name, it.guild_name, it.content, it.link, it.note }) |t| gpa.free(t);
        gpa.free(it.spans);
    }
};

pub const AddResult = enum { added, already, missing, full };

pub const List = struct {
    /// A salva mais recente primeiro.
    items: std.ArrayList(Item) = .empty,
    /// Conta dona da lista (cada conta tem o seu arquivo); 0 = nenhuma.
    owner: Id = 0,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.clear(gpa);
        l.items.deinit(gpa);
    }

    pub fn clear(l: *List, gpa: std.mem.Allocator) void {
        for (l.items.items) |*it| it.free(gpa);
        l.items.clearRetainingCapacity();
    }

    pub fn find(l: *const List, id: Id) ?*Item {
        for (l.items.items) |*it| if (it.id == id) return it;
        return null;
    }

    /// Copia a mensagem do Store para a lista.
    pub fn add(l: *List, gpa: std.mem.Allocator, store: *const Store, id: Id, now_s: i64) !AddResult {
        if (l.find(id) != null) return .already;
        if (l.items.items.len >= max_items) return .full;
        const f = store.findAny(id) orelse return .missing;
        if (f.m.msg.id == 0) return .missing;
        const ch = &f.cs.info;
        const g = store.guild(ch.guild);
        var lb: [96]u8 = undefined;
        var gb: [24]u8 = undefined;
        const link = std.fmt.bufPrint(&lb, "https://discord.com/channels/{s}/{d}/{d}", .{ guildPart(&gb, ch.guild), ch.id, id }) catch return .missing;
        try l.insert(gpa, 0, .{
            .id = id,
            .channel = ch.id,
            .guild = ch.guild,
            .author = f.m.msg.author,
            .timestamp = f.m.msg.timestamp,
            .saved_at = now_s,
            .author_name = if (store.user(f.m.msg.author)) |u| u.name else "?",
            .channel_name = ch.name,
            .guild_name = if (g) |x| x.name else "",
            .content = f.m.msg.content,
            .link = link,
            .note = "",
        });
        return .added;
    }

    /// Insere uma cópia de `src` (os textos são duplicados).
    fn insert(l: *List, gpa: std.mem.Allocator, at: usize, src: Item) !void {
        var it = src;
        it.author_name = try gpa.dupe(u8, src.author_name);
        errdefer gpa.free(it.author_name);
        it.channel_name = try gpa.dupe(u8, src.channel_name);
        errdefer gpa.free(it.channel_name);
        it.guild_name = try gpa.dupe(u8, src.guild_name);
        errdefer gpa.free(it.guild_name);
        it.content = try gpa.dupe(u8, src.content);
        errdefer gpa.free(it.content);
        it.link = try gpa.dupe(u8, src.link);
        errdefer gpa.free(it.link);
        it.note = try gpa.dupe(u8, clip(src.note, max_note));
        errdefer gpa.free(it.note);
        it.spans = try markdown.parse(gpa, it.content);
        errdefer gpa.free(it.spans);
        try l.items.insert(gpa, at, it);
    }

    pub fn remove(l: *List, gpa: std.mem.Allocator, id: Id) bool {
        for (l.items.items, 0..) |*it, i| if (it.id == id) {
            it.free(gpa);
            _ = l.items.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// Troca a anotação. Retorna false se a salva não existe ou não mudou.
    pub fn setNote(l: *List, gpa: std.mem.Allocator, id: Id, note: []const u8) !bool {
        const it = l.find(id) orelse return false;
        const t = clip(std.mem.trim(u8, note, " \t\r\n"), max_note);
        if (std.mem.eql(u8, t, it.note)) return false;
        const owned = try gpa.dupe(u8, t);
        gpa.free(it.note);
        it.note = owned;
        return true;
    }

    /// `{"version":1,"saved":[{...}]}`, com os IDs como texto (como o Discord).
    pub fn write(l: *const List, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "{\"version\":1,\"saved\":[");
        for (l.items.items, 0..) |it, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "\n{{\"id\":\"{d}\",\"channel\":\"{d}\",\"guild\":\"{d}\",\"author\":\"{d}\",\"timestamp\":{d},\"saved_at\":{d}", .{ it.id, it.channel, it.guild, it.author, it.timestamp, it.saved_at });
            const fields = [_]struct { []const u8, []const u8 }{
                .{ "author_name", it.author_name },
                .{ "channel_name", it.channel_name },
                .{ "guild_name", it.guild_name },
                .{ "content", it.content },
                .{ "link", it.link },
                .{ "note", it.note },
            };
            for (fields) |f| {
                try out.print(gpa, ",\"{s}\":", .{f[0]});
                try j.writeString(out, gpa, f[1]);
            }
            try out.append(gpa, '}');
        }
        try out.appendSlice(gpa, "\n]}\n");
    }

    /// Lê o arquivo (substitui a lista). Entradas sem ID ou canal são puladas.
    pub fn read(l: *List, gpa: std.mem.Allocator, text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
        l.clear(gpa);
        for (j.array(j.get(root, "saved"))) |v| {
            if (l.items.items.len >= max_items) break;
            const id = j.id(j.get(v, "id")) orelse continue;
            const ch = j.id(j.get(v, "channel")) orelse continue;
            if (l.find(id) != null) continue;
            const guild = j.id(j.get(v, "guild")) orelse 0;
            var lb: [96]u8 = undefined;
            var gb: [24]u8 = undefined;
            const link = j.str(j.get(v, "link")) orelse
                (std.fmt.bufPrint(&lb, "https://discord.com/channels/{s}/{d}/{d}", .{ guildPart(&gb, guild), ch, id }) catch "");
            try l.insert(gpa, l.items.items.len, .{
                .id = id,
                .channel = ch,
                .guild = guild,
                .author = j.id(j.get(v, "author")) orelse 0,
                .timestamp = j.int(j.get(v, "timestamp")) orelse 0,
                .saved_at = j.int(j.get(v, "saved_at")) orelse 0,
                .author_name = j.str(j.get(v, "author_name")) orelse "?",
                .channel_name = j.str(j.get(v, "channel_name")) orelse "?",
                .guild_name = j.str(j.get(v, "guild_name")) orelse "",
                .content = j.str(j.get(v, "content")) orelse "",
                .link = link,
                .note = j.str(j.get(v, "note")) orelse "",
            });
        }
    }
};

/// Links de DM usam "@me" no lugar do servidor.
fn guildPart(buf: []u8, guild: Id) []const u8 {
    return if (guild == 0) "@me" else std.fmt.bufPrint(buf, "{d}", .{guild}) catch "@me";
}

/// Corta em `max` bytes sem quebrar um caractere UTF-8.
fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

test "salvas: salvar, anotar, gravar e ler de volta" {
    const ca = std.heap.c_allocator;
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    const chans = try ca.alloc(types.Channel, 2);
    chans[0] = .{ .id = 10, .guild = 5, .name = try ca.dupe(u8, "geral"), .topic = try ca.dupe(u8, "") };
    chans[1] = .{ .id = 20, .guild = 0, .name = try ca.dupe(u8, "ana"), .topic = try ca.dupe(u8, ""), .recipient = 2 };
    const guilds = try ca.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try ca.dupe(u8, "Zig Brasil"), .acronym = try ca.dupe(u8, "Z") };
    const users = try ca.alloc(types.User, 1);
    users[0] = .{ .id = 2, .name = try ca.dupe(u8, "ana") };
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{ .id = 7, .channel = 10, .author = 2, .timestamp = 1700000000, .content = try ca.dupe(u8, "olha \"isso\"\nlinha 2 ✨") } }, 0);
    try s.apply(.{ .message_create = .{ .id = 8, .channel = 20, .author = 2, .timestamp = 1700000100, .content = try ca.dupe(u8, "oi") } }, 0);

    var l: List = .{};
    defer l.deinit(gpa);
    try std.testing.expectEqual(AddResult.added, try l.add(gpa, &s, 7, 1));
    try std.testing.expectEqual(AddResult.already, try l.add(gpa, &s, 7, 1));
    try std.testing.expectEqual(AddResult.added, try l.add(gpa, &s, 8, 2));
    try std.testing.expectEqual(AddResult.missing, try l.add(gpa, &s, 99, 2));
    // A mais recente primeiro.
    try std.testing.expectEqual(@as(Id, 8), l.items.items[0].id);
    try std.testing.expectEqualStrings("https://discord.com/channels/@me/20/8", l.items.items[0].link);
    try std.testing.expectEqualStrings("https://discord.com/channels/5/10/7", l.items.items[1].link);
    try std.testing.expectEqualStrings("Zig Brasil", l.items.items[1].guild_name);
    try std.testing.expect(try l.setNote(gpa, 7, "  lembrar de \"responder\" ✓ "));
    try std.testing.expect(!try l.setNote(gpa, 7, "lembrar de \"responder\" ✓"));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try l.write(gpa, &out);
    var back: List = .{};
    defer back.deinit(gpa);
    try back.read(gpa, out.items);
    try std.testing.expectEqual(@as(usize, 2), back.items.items.len);
    const it = back.find(7).?;
    try std.testing.expectEqualStrings("lembrar de \"responder\" ✓", it.note);
    try std.testing.expectEqualStrings("olha \"isso\"\nlinha 2 ✨", it.content);
    try std.testing.expectEqualStrings("ana", it.author_name);
    try std.testing.expectEqual(@as(i64, 1700000000), it.timestamp);

    try std.testing.expect(back.remove(gpa, 7));
    try std.testing.expect(!back.remove(gpa, 7));
    try std.testing.expectEqual(@as(usize, 1), back.items.items.len);
    // Arquivo estragado não derruba nada.
    if (back.read(gpa, "{ isso não é json")) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqual(@as(usize, 1), back.items.items.len);
}
