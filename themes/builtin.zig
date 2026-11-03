//! Temas embutidos no executável (os mesmos arquivos desta pasta).
pub const Builtin = struct { name: []const u8, source: []const u8 };

pub const list = [_]Builtin{
    .{ .name = "classico", .source = @embedFile("classico.kdl") },
    .{ .name = "vidro", .source = @embedFile("vidro.kdl") },
    .{ .name = "terminal", .source = @embedFile("terminal.kdl") },
    .{ .name = "bolhas", .source = @embedFile("bolhas.kdl") },
    .{ .name = "zen", .source = @embedFile("zen.kdl") },
    .{ .name = "neon", .source = @embedFile("neon.kdl") },
    .{ .name = "papel", .source = @embedFile("papel.kdl") },
    .{ .name = "gameboy", .source = @embedFile("gameboy.kdl") },
    .{ .name = "escritorio", .source = @embedFile("escritorio.kdl") },
};
