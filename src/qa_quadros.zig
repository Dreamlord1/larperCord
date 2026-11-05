//! QA do que evita trabalho: quadro igual ao anterior não precisaria ir para a tela
//! (aqui ele vai sempre, porque o QA lê os pixels: as contas dizem o que seria pulado)
//! e as imagens saem da memória com a janela escondida. O pulo de verdade é conferido
//! com a janela real em tools/qa_quadros.sh.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const App = @import("app.zig").App;
const Op = @import("qa_runner.zig").Op;
const janela = @import("core/janela.zig");
const settings = @import("ui/settings.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}

// --- Quadros iguais --------------------------------------------------------------

var built_mark: u64 = 0;
var same_mark: u64 = 0;

fn markFrames(app: *App) void {
    built_mark = app.gate.built;
    same_mark = app.gate.same;
}

/// Dez quadros seguidos iguais: uma animação que ainda termina não atrapalha.
fn framesSettled(app: *App) bool {
    if (app.gate.built - built_mark < 10) return false;
    if (app.gate.same - same_mark == app.gate.built - built_mark) return true;
    markFrames(app);
    return false;
}

fn framesChanged(app: *App) bool {
    return (app.gate.built - built_mark) > (app.gate.same - same_mark);
}

// --- Imagens com a janela escondida ----------------------------------------------

var big_before: usize = 0;
var animated_before: usize = 0;
var small_before: usize = 0;
var big_after: usize = 0;
var animated_after: usize = 0;
var small_after: usize = 0;
var bytes_before: usize = 0;
var bytes_after: usize = 0;

const Count = struct { big: usize = 0, animated: usize = 0, small: usize = 0 };

fn count(app: *App) Count {
    var n: Count = .{};
    var it = app.images.map.valueIterator();
    while (it.next()) |e| {
        if (e.state != .ready) continue;
        if (e.frames.len > 1) {
            n.animated += 1;
        } else if (e.bytes > janela.hidden_keep_bytes) {
            n.big += 1;
        } else n.small += 1;
    }
    return n;
}

fn releaseNow(app: *App) void {
    const before = count(app);
    big_before = before.big;
    animated_before = before.animated;
    small_before = before.small;
    bytes_before = app.images.bytes;
    _ = app.images.releaseHidden();
    const after = count(app);
    big_after = after.big;
    animated_after = after.animated;
    small_after = after.small;
    bytes_after = app.images.bytes;
}

fn hadSomethingToRelease(_: *App) bool {
    return big_before > 0 and small_before > 0;
}

fn bigGone(_: *App) bool {
    return big_after == 0 and animated_after == 0 and bytes_after < bytes_before;
}

fn smallKept(_: *App) bool {
    return small_after > 0;
}

fn bigBack(app: *App) bool {
    return count(app).big > 0;
}

// --- Página de Desempenho --------------------------------------------------------

fn clearSelection(app: *App) void {
    app.st.selection = .{};
}

fn scrollbarSelectsNothing(app: *App) bool {
    return app.st.selection.empty() and !app.st.selection.dragging;
}

fn memoryShown(app: *App) bool {
    if (settings.mem_use.n_channels == 0 or settings.mem_use.n_people == 0 or settings.mem_use.places == 0) return false;
    if (app.stats.frames_built == 0) return false;
    // Só a glibc informa o heap, e só o Linux separa o que vem de arquivos.
    if (builtin.os.tag == .linux) return @atomicLoad(u32, &app.stats.heap_used_kb, .monotonic) > 0 and @atomicLoad(u32, &app.stats.file_kb, .monotonic) > 0;
    return true;
}

pub const ops = [_]Op{
    s("quadro igual não precisa ir para a tela"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    .{ .wait = 300 },
    click("settings:Sobre"),
    .{ .run = markFrames },
    // (Às vezes algo ainda anima por alguns segundos: em 4 s, falhava 1 vez em 3.)
    .{ .expect = .{ .name = "página parada, os quadros saem todos iguais", .check = framesSettled, .timeout_ms = 15000 } },
    .{ .run = markFrames },
    .{ .hover = .{ .mark = "settings:Chat" } },
    .{ .expect = .{ .name = "o destaque do mouse muda o quadro", .check = framesChanged, .timeout_ms = 2000 } },
    .{ .run = markFrames },
    .{ .expect = .{ .name = "o mouse parou, volta a sair igual", .check = framesSettled, .timeout_ms = 15000 } },

    s("página de desempenho mostra a memória por partes"),
    click("settings:Desempenho"),
    .{ .expect = .{ .name = "imagens, conta, heap e driver aparecem", .check = memoryShown, .timeout_ms = 6000 } },
    .{ .shot = "74-desempenho-memoria" },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    .{ .wait = 350 },

    s("arrastar a barra de rolagem não seleciona texto"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .wait = 800 },
    .{ .run = clearSelection },
    .{ .drag = .{ .from = .{ .mark = "msg-scrollbar" }, .to = .{ .mark = "msg-scrollbar-top" } } },
    expect("subir a barra deixa as mensagens sem seleção", scrollbarSelectsNothing),

    s("janela escondida solta as imagens"),
    click("guild:500000"),
    click("channel:500005"),
    .{ .wait = 800 },
    .{ .run = releaseNow },
    expect("havia imagem grande e pequena na tela", hadSomethingToRelease),
    expect("grande e animada saem da memória", bigGone),
    expect("avatar e ícone na tela ficam", smallKept),
    .{ .expect = .{ .name = "ao voltar, a imagem grande carrega de novo", .check = bigBack, .timeout_ms = 5000 } },
};
