//! Lê o CHANGELOG, que é escrito à mão num formato pequeno:
//!   `## versão`, `**seção**` numa linha só, `- item` e parágrafos soltos.
//! O título do arquivo (`# …`) não entra: a página já tem o dela.
const std = @import("std");

pub const Item = struct { text: []const u8, bullet: bool };
/// `title` vazio: o que vem antes da primeira seção de uma versão.
pub const Section = struct { title: []const u8, items: []const Item };
pub const Version = struct { name: []const u8, sections: []const Section };

/// As versões na ordem do arquivo. Os textos apontam para `text`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ![]const Version {
    var versions: std.ArrayList(Version) = .empty;
    var sections: std.ArrayList(Section) = .empty;
    var items: std.ArrayList(Item) = .empty;
    var name: ?[]const u8 = null;
    var title: []const u8 = "";

    const Build = struct {
        fn closeSection(sec: *std.ArrayList(Section), its: *std.ArrayList(Item), a: std.mem.Allocator, t: []const u8) !void {
            if (t.len == 0 and its.items.len == 0) return;
            try sec.append(a, .{ .title = t, .items = try its.toOwnedSlice(a) });
        }
    };

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            if (name) |n| {
                try Build.closeSection(&sections, &items, gpa, title);
                try versions.append(gpa, .{ .name = n, .sections = try sections.toOwnedSlice(gpa) });
            }
            name = std.mem.trim(u8, line[3..], " ");
            title = "";
            continue;
        }
        // Antes da primeira versão só tem o título do arquivo.
        if (name == null) continue;
        if (line.len > 4 and std.mem.startsWith(u8, line, "**") and std.mem.endsWith(u8, line, "**") and std.mem.indexOf(u8, line[2 .. line.len - 2], "**") == null) {
            try Build.closeSection(&sections, &items, gpa, title);
            title = line[2 .. line.len - 2];
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            try items.append(gpa, .{ .text = line[2..], .bullet = true });
        } else {
            try items.append(gpa, .{ .text = line, .bullet = false });
        }
    }
    if (name) |n| {
        try Build.closeSection(&sections, &items, gpa, title);
        try versions.append(gpa, .{ .name = n, .sections = try sections.toOwnedSlice(gpa) });
    }
    return versions.toOwnedSlice(gpa);
}

test "versões, seções, itens e parágrafos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(),
        \\# What changed in each version
        \\
        \\## 0.5.0
        \\
        \\**Windows**
        \\- Runs on Windows.
        \\- Tokens **stay** safe.
        \\
        \\**Updates**
        \\- One button.
        \\
        \\## 0.4.0
        \\
        \\First public version: real connection.
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("0.5.0", list[0].name);
    try std.testing.expectEqual(@as(usize, 2), list[0].sections.len);
    try std.testing.expectEqualStrings("Windows", list[0].sections[0].title);
    try std.testing.expectEqual(@as(usize, 2), list[0].sections[0].items.len);
    try std.testing.expect(list[0].sections[0].items[1].bullet);
    try std.testing.expectEqualStrings("Tokens **stay** safe.", list[0].sections[0].items[1].text);
    try std.testing.expectEqualStrings("Updates", list[0].sections[1].title);
    // Versão só com um parágrafo: uma seção sem título.
    try std.testing.expectEqual(@as(usize, 1), list[1].sections.len);
    try std.testing.expectEqualStrings("", list[1].sections[0].title);
    try std.testing.expect(!list[1].sections[0].items[0].bullet);
}

test "negrito no meio de uma linha não abre seção" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), "## 1.0\n**a** e **b**\n");
    try std.testing.expectEqual(@as(usize, 1), list[0].sections.len);
    try std.testing.expectEqualStrings("", list[0].sections[0].title);
    try std.testing.expectEqualStrings("**a** e **b**", list[0].sections[0].items[0].text);
}

test "arquivo vazio ou sem versões" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), "# título\ntexto solto\n")).len);
}
