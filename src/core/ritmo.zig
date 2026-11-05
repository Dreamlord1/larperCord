//! Quando um quadro é feito e quando ele chega à tela. Mandar o desenho para a GPU
//! é a maior parte do custo de um quadro, e quase sempre ele sai igual ao anterior:
//! o mouse passou por cima de nada, chegou a presença de alguém fora da tela.

/// Decide se o quadro pronto vai para a tela: igual ao anterior, não vai.
pub const Gate = struct {
    last: u64 = 0,
    /// Próximos quadros que vão de qualquer jeito.
    force: u8 = 2,
    /// Quadros feitos, os iguais ao anterior e os que não foram desenhados.
    built: u64 = 0,
    same: u64 = 0,
    skipped: u64 = 0,

    /// A tela precisa do próximo quadro mesmo que ele saia igual: janela que
    /// voltou ou mudou de tamanho, textura trocada sem mudar o desenho.
    pub fn redraw(g: *Gate) void {
        g.force = @max(g.force, 2);
    }

    /// `sum` resume o quadro; `always` é quem precisa dele desenhado (prints, QA).
    pub fn check(g: *Gate, sum: u64, always: bool) bool {
        g.built +%= 1;
        const same = sum == g.last;
        g.last = sum;
        if (same) g.same +%= 1;
        if (g.force > 0) {
            g.force -= 1;
            return true;
        }
        if (always or !same) return true;
        g.skipped +%= 1;
        return false;
    }
};

/// Mouse andando sem botão apertado: passar por cima das coisas não precisa de um
/// quadro por evento. O cursor é do sistema e anda sozinho; só o destaque do que
/// está embaixo dele espera, no máximo `interval_ms`.
pub const MousePace = struct {
    moved: bool = false,
    /// Quadros depois que parou: o que reage ao mouse às vezes só aparece no quadro
    /// seguinte, e sem outro evento ninguém pediria esse quadro.
    settle: u8 = 0,

    pub const interval_ms: i64 = 33;
    const settle_frames = 2;

    pub fn motion(m: *MousePace) void {
        m.moved = true;
        m.settle = settle_frames;
    }

    pub fn wanted(m: *const MousePace) bool {
        return m.moved or m.settle > 0;
    }

    /// Saiu um quadro, por qualquer motivo: ele já viu o mouse onde está.
    pub fn frame(m: *MousePace) void {
        if (m.moved) {
            m.moved = false;
        } else if (m.settle > 0) m.settle -= 1;
    }
};

const std = @import("std");

test "quadro igual ao anterior não vai para a tela" {
    var g: Gate = .{};
    // Os primeiros vão sempre.
    try std.testing.expect(g.check(1, false));
    try std.testing.expect(g.check(1, false));
    try std.testing.expect(!g.check(1, false));
    try std.testing.expect(g.check(2, false));
    try std.testing.expect(!g.check(2, false));
    try std.testing.expectEqual(@as(u64, 5), g.built);
    try std.testing.expectEqual(@as(u64, 3), g.same);
    try std.testing.expectEqual(@as(u64, 2), g.skipped);
}

test "quem precisa do quadro desenhado recebe mesmo igual" {
    var g: Gate = .{ .force = 0, .last = 7 };
    try std.testing.expect(g.check(7, true));
    try std.testing.expectEqual(@as(u64, 1), g.same);
    try std.testing.expectEqual(@as(u64, 0), g.skipped);
    g.redraw();
    try std.testing.expect(g.check(7, false));
    try std.testing.expect(g.check(7, false));
    try std.testing.expect(!g.check(7, false));
}

test "depois que o mouse para ainda saem os quadros de assentar" {
    var m: MousePace = .{};
    try std.testing.expect(!m.wanted());
    m.motion();
    m.frame();
    try std.testing.expect(!m.moved);
    try std.testing.expect(m.wanted());
    m.frame();
    try std.testing.expect(m.wanted());
    m.frame();
    try std.testing.expect(!m.wanted());
}

test "mouse andando de novo recomeça os quadros de assentar" {
    var m: MousePace = .{};
    m.motion();
    m.frame();
    m.frame();
    m.motion();
    try std.testing.expect(m.moved);
    try std.testing.expectEqual(@as(u8, 2), m.settle);
}
