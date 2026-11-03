//! Busca aproximada da paleta de comandos: as letras da busca precisam
//! aparecer em ordem; início de palavra e letras seguidas valem mais.
const std = @import("std");

pub fn score(query: []const u8, target: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var s: i32 = 0;
    var ti: usize = 0;
    var streak: i32 = 0;
    for (query) |qc| {
        const q = std.ascii.toLower(qc);
        if (q == ' ') continue;
        var found = false;
        while (ti < target.len) : (ti += 1) {
            const t = std.ascii.toLower(target[ti]);
            if (t == q) {
                const boundary = ti == 0 or !std.ascii.isAlphanumeric(target[ti - 1]);
                s += 10 + (if (boundary) @as(i32, 8) else 0) + streak * 5;
                streak += 1;
                ti += 1;
                found = true;
                break;
            }
            streak = 0;
        }
        if (!found) return null;
    }
    // Alvos mais curtos ganham por pouco.
    return s - @as(i32, @intCast(@min(target.len, 60)));
}

test "busca aproximada" {
    try std.testing.expect(score("gr", "# geral") != null);
    try std.testing.expect(score("xyz", "# geral") == null);
    try std.testing.expect(score("zig", "# zig — Zig Brasil").? > score("zig", "Faculdade: zoeira inteligente geral").?);
    try std.testing.expect(score("", "qualquer").? == 0);
}
