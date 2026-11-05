//! Os plugins incluídos, embutidos no executável: o botão da página de plugins
//! (Configurações → Plugins) copia para a pasta, e os testes carregam.
pub const Exemplo = struct { name: []const u8, source: []const u8 };

pub const list = [_]Exemplo{
    .{ .name = "bookmarks.lua", .source = @embedFile("bookmarks.lua") },
    .{ .name = "filter.lua", .source = @embedFile("filter.lua") },
    .{ .name = "highlights.lua", .source = @embedFile("highlights.lua") },
    .{ .name = "reminders.lua", .source = @embedFile("reminders.lua") },
    .{ .name = "snippets.lua", .source = @embedFile("snippets.lua") },
    .{ .name = "stats.lua", .source = @embedFile("stats.lua") },
    .{ .name = "translate.lua", .source = @embedFile("translate.lua") },
};
