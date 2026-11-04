//! Temas embutidos no executável (os mesmos arquivos desta pasta).
pub const Builtin = struct { name: []const u8, source: []const u8 };

pub const list = [_]Builtin{
    .{ .name = "classico", .source = @embedFile("classico.kdl") },
    .{ .name = "vidro", .source = @embedFile("vidro.kdl") },
    .{ .name = "terminal", .source = @embedFile("terminal.kdl") },
    .{ .name = "subsolo", .source = @embedFile("subsolo.kdl") },
    .{ .name = "orbital", .source = @embedFile("orbital.kdl") },
    .{ .name = "editorial", .source = @embedFile("editorial.kdl") },
    .{ .name = "bolhas", .source = @embedFile("bolhas.kdl") },
    .{ .name = "zen", .source = @embedFile("zen.kdl") },
    .{ .name = "papel", .source = @embedFile("papel.kdl") },
    .{ .name = "escritorio", .source = @embedFile("escritorio.kdl") },
    .{ .name = "cupertino", .source = @embedFile("cupertino.kdl") },
};
