//! Os plugins incluídos, embutidos no executável: o botão da página de plugins
//! (Configurações → Plugins) copia para a pasta, e os testes carregam.
pub const Exemplo = struct { name: []const u8, source: []const u8 };

pub const list = [_]Exemplo{
    .{ .name = "cleanlinks.lua", .source = @embedFile("cleanlinks.lua") },
    .{ .name = "highlights.lua", .source = @embedFile("highlights.lua") },
    .{ .name = "links.lua", .source = @embedFile("links.lua") },
    .{ .name = "reminders.lua", .source = @embedFile("reminders.lua") },
    .{ .name = "snippets.lua", .source = @embedFile("snippets.lua") },
    .{ .name = "timestamps.lua", .source = @embedFile("timestamps.lua") },
    .{ .name = "translate.lua", .source = @embedFile("translate.lua") },
};
