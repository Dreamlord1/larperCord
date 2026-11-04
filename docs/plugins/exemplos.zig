//! Os plugins de exemplo, embutidos no executável: o botão "Instalar exemplos"
//! (Configurações → Plugins) copia para a pasta de plugins, e os testes carregam.
pub const Exemplo = struct { name: []const u8, source: []const u8 };

pub const list = [_]Exemplo{
    .{ .name = "alerta.lua", .source = @embedFile("alerta.lua") },
    .{ .name = "calc.lua", .source = @embedFile("calc.lua") },
    .{ .name = "dado.lua", .source = @embedFile("dado.lua") },
    .{ .name = "relogio.lua", .source = @embedFile("relogio.lua") },
    .{ .name = "resumo.lua", .source = @embedFile("resumo.lua") },
    .{ .name = "shrug.lua", .source = @embedFile("shrug.lua") },
    .{ .name = "zoeira.lua", .source = @embedFile("zoeira.lua") },
};
