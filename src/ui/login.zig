//! Tela de entrada: a logo se monta, o fundo respira e o cartão pede o token.
//! Também é a tela de abertura enquanto conecta com um token salvo, e some
//! num esmaecimento quando o READY chega.
//!
//! Tudo é desenhado aqui mesmo (sem tema): é a cara do app, igual em todos
//! os temas, só respeitando claro/escuro e "reduzir movimento".
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const logo = @import("logo.zig");
const qa = @import("qa.zig");

const Rgba = d.Rgba;
const Rect = d.Rect;

pub const Phase = enum { hidden, form, connecting, leaving };

pub const Result = enum { submit, demo, cancel };

pub const Login = struct {
    phase: Phase = .hidden,
    /// Relógio da tela (segundos desde que apareceu).
    t: f32 = 0,
    phase_at: f32 = 0,
    token: [256]u8 = @splat(0),
    show: bool = false,
    remember: bool = true,
    help: bool = false,
    err_buf: [200]u8 = undefined,
    err_len: usize = 0,
    err_at: f32 = -10,
    want_focus: bool = true,
    /// Valores suavizados entre quadros.
    look: [2]f32 = .{ 0, 0 },
    card_h: f32 = 0,
    help_k: f32 = 0,
    show_k: f32 = 0,
    remember_k: f32 = 1,
    focus_k: f32 = 0,

    pub fn visible(l: *const Login) bool {
        return l.phase != .hidden;
    }

    pub fn begin(l: *Login, phase: Phase) void {
        l.* = .{ .phase = phase, .remember = l.remember };
    }

    pub fn setPhase(l: *Login, phase: Phase) void {
        l.phase = phase;
        l.phase_at = l.t;
        if (phase == .form) l.want_focus = true;
    }

    /// O Discord recusou (ou a conexão falhou de vez): volta ao formulário.
    pub fn fail(l: *Login, msg: []const u8) void {
        if (l.phase == .hidden) l.t = 10; // veio direto do token salvo: sem a abertura
        l.setPhase(.form);
        const n = @min(msg.len, l.err_buf.len);
        @memcpy(l.err_buf[0..n], msg[0..n]);
        l.err_len = n;
        l.err_at = l.t;
    }

    pub fn tokenText(l: *const Login) []const u8 {
        return std.mem.trim(u8, std.mem.sliceTo(&l.token, 0), " \t\r\n\"");
    }

    pub fn clearToken(l: *Login) void {
        std.crypto.secureZero(u8, &l.token);
    }

    fn err(l: *const Login) []const u8 {
        return l.err_buf[0..l.err_len];
    }
};

pub const Env = struct {
    ui: *d.Family,
    io: *c.ImGuiIO,
    light: bool,
    reduce: bool,
    /// Segundos desde o último quadro (fixo ao gravar a animação).
    dt: f32,
};

// --- Cores ---------------------------------------------------------------------

const Pal = struct {
    bg_top: Rgba,
    bg_bot: Rgba,
    card: Rgba,
    card_border: Rgba,
    field: Rgba,
    text: Rgba,
    muted: Rgba,
    faint: Rgba,
    danger: Rgba,
    star: Rgba,
    aurora: f32,
};

const dark: Pal = .{
    .bg_top = Rgba.hex(0x0B0816),
    .bg_bot = Rgba.hex(0x151030),
    .card = Rgba.hex(0x17122C).alpha(0.82),
    .card_border = Rgba.white.alpha(0.09),
    .field = Rgba.hex(0x0C0919).alpha(0.9),
    .text = Rgba.hex(0xF4F1FF),
    .muted = Rgba.hex(0xA9A1CB),
    .faint = Rgba.hex(0x6F678F),
    .danger = Rgba.hex(0xFF6B85),
    .star = Rgba.hex(0xD9CCFF),
    .aurora = 1,
};

const light: Pal = .{
    .bg_top = Rgba.hex(0xFBFAFF),
    .bg_bot = Rgba.hex(0xEDE8FF),
    .card = Rgba.white.alpha(0.86),
    .card_border = Rgba.hex(0x2A1F55).alpha(0.1),
    .field = Rgba.hex(0xF3F0FC),
    .text = Rgba.hex(0x17112E),
    .muted = Rgba.hex(0x5C5480),
    .faint = Rgba.hex(0x948DB3),
    .danger = Rgba.hex(0xD6264B),
    .star = Rgba.hex(0x7C5CFF),
    .aurora = 0.55,
};

// --- Curvas de animação ------------------------------------------------------

fn seg(t: f32, a: f32, b: f32) f32 {
    return std.math.clamp((t - a) / (b - a), 0, 1);
}
fn outCubic(x: f32) f32 {
    const u = 1 - x;
    return 1 - u * u * u;
}
fn inOutCubic(x: f32) f32 {
    return if (x < 0.5) 4 * x * x * x else 1 - std.math.pow(f32, -2 * x + 2, 3) / 2;
}
fn outBack(x: f32, s: f32) f32 {
    const u = x - 1;
    return 1 + (s + 1) * u * u * u + s * u * u;
}
fn hash(i: usize, salt: u64) f32 {
    const h = std.hash.Wyhash.hash(salt, std.mem.asBytes(&i));
    return @as(f32, @floatFromInt(h & 0xffff)) / 65535.0;
}

// --- Interação -----------------------------------------------------------------

const Hit = struct { hovered: bool, clicked: bool, held: bool };

fn hit(id: usize, r: Rect) Hit {
    c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
    c.ImGui_PushIDInt(@intCast(id));
    const clicked = c.ImGui_InvisibleButton("##l", d.v(@max(r.w, 1), @max(r.h, 1)), c.ImGuiButtonFlags_MouseButtonLeft);
    const hovered = c.ImGui_IsItemHovered(0);
    const held = c.ImGui_IsItemActive();
    c.ImGui_PopID();
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    return .{ .hovered = hovered, .clicked = clicked, .held = held };
}

// --- Desenho -------------------------------------------------------------------

const Frame = struct {
    l: *Login,
    env: Env,
    dl: *c.ImDrawList,
    win: Rect,
    p: Pal,
    /// Alpha geral (o esmaecimento da saída).
    a: f32,
    mouse: c.ImVec2,

    fn font(f: *const Frame, w: d.Weight) *c.ImFont {
        return f.env.ui.get(w);
    }

    fn text(f: *const Frame, w: d.Weight, size: f32, x: f32, y: f32, col: Rgba, s: []const u8) void {
        d.text(f.dl, f.font(w), size, x, y, col.alpha(f.a), s);
    }

    fn width(f: *const Frame, w: d.Weight, size: f32, s: []const u8) f32 {
        return d.width(f.font(w), size, s);
    }

    fn centered(f: *const Frame, w: d.Weight, size: f32, cx: f32, y: f32, col: Rgba, s: []const u8) void {
        f.text(w, size, cx - f.width(w, size, s) / 2, y, col, s);
    }
};

pub fn draw(l: *Login, env: Env) ?Result {
    if (l.phase == .hidden) return null;
    l.t += if (env.reduce) 10 else env.dt;
    if (env.reduce and l.phase == .leaving) l.phase_at = l.t - 10;

    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    // Na saída o app já está por baixo: a janela não pode roubar o mouse.
    const pass_through: c_int = if (l.phase == .leaving) c.ImGuiWindowFlags_NoInputs else 0;
    _ = c.ImGui_Begin("##login", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse |
        c.ImGuiWindowFlags_NoNav | pass_through);
    defer c.ImGui_End();

    const leave_k = if (l.phase == .leaving) seg(l.t, l.phase_at, l.phase_at + 0.75) else 0;
    if (l.phase == .leaving and leave_k >= 1) {
        l.phase = .hidden;
        return null;
    }
    var f: Frame = .{
        .l = l,
        .env = env,
        .dl = c.ImGui_GetWindowDrawList(),
        .win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y },
        .p = if (env.light) light else dark,
        .a = 1 - leave_k * leave_k,
        .mouse = env.io.*.MousePos,
    };
    const t = l.t;

    background(&f);

    // Disposição: lado a lado na janela larga, empilhado na estreita.
    const W = f.win.w;
    const H = f.win.h;
    const wide = W >= 940 and H >= 540;
    const card_w: f32 = @min(404, W - 32);
    var logo_size: f32 = undefined;
    var hero_cx: f32 = undefined;
    var hero_cy: f32 = undefined;
    var card_x: f32 = undefined;
    var card_y: f32 = undefined;
    const ch = if (l.card_h > 0) l.card_h else 420;
    if (wide) {
        logo_size = std.math.clamp(H * 0.42, 220, 360);
        hero_cx = f.win.x + W * 0.31;
        hero_cy = f.win.y + H * 0.46 - 40;
        card_x = f.win.x + @max(W * 0.69 - card_w / 2, hero_cx + 230);
        card_y = f.win.y + @max(16, (H - ch) / 2);
    } else {
        // Estreita: logo e nome lado a lado no topo, cartão embaixo.
        logo_size = 84;
        const lock_w = logo_size + 8 + f.width(.bold, 34, "larperCord");
        hero_cx = f.win.x + (W - lock_w) / 2 + logo_size / 2;
        hero_cy = f.win.y + 22 + logo_size * 0.375;
        card_x = f.win.x + (W - card_w) / 2;
        card_y = f.win.y + @max(logo_size * 0.75 + 44, (H - ch) / 2 + 30);
    }

    // --- Logo -------------------------------------------------------------
    var pose: logo.Pose = .{
        .body = outBack(seg(t, 0.12, 0.72), 2.4),
        // Chega de olhos fechados e "acorda" com a cara de deboche.
        .eyes = outBack(seg(t, 0.95, 1.2), 2),
        .smile = outCubic(seg(t, 1.1, 1.4)),
        .star = outBack(seg(t, 0.7, 1.05), 3) * (1 + 0.07 * @sin(t * 3.1)),
        .spin = (1 - outCubic(seg(t, 0.7, 1.2))) * -2.6 + 0.1 * @sin(t * 0.9),
        .alpha = f.a,
    };
    // Piscadas (às vezes duas seguidas).
    if (t > 3) {
        const period: f32 = 3.7;
        const cyc = @floor((t - 3) / period);
        const ph = (t - 3) - cyc * period;
        const blink = struct {
            fn at(x: f32) f32 {
                return if (x >= 0 and x <= 0.16) @sin(std.math.pi * x / 0.16) else 0;
            }
        }.at;
        var b = blink(ph);
        if (@mod(cyc, 3) == 1) b = @max(b, blink(ph - 0.26));
        pose.eyes *= 1 - b;
    }
    // Para onde olha: o mouse; o campo do token enquanto digita; de um lado
    // pro outro enquanto conecta; para baixo quando dá erro.
    const lc = d.v(hero_cx, hero_cy);
    var want: [2]f32 = .{
        std.math.clamp((f.mouse.x - lc.x) / (W * 0.4), -1, 1),
        std.math.clamp((f.mouse.y - lc.y) / (H * 0.4), -1, 1),
    };
    if (f.l.focus_k > 0.5 and l.phase == .form) want = .{ if (wide) 1 else 0, if (wide) 0.3 else 1 };
    if (l.phase == .connecting) want = .{ @sin(t * 2.2), -0.4 };
    if (t - l.err_at < 1.6) want = .{ 0, 1 };
    if (f.mouse.x < -1000) want = .{ 0, 0 };
    l.look[0] = anim.step(l.look[0], want[0], 9);
    l.look[1] = anim.step(l.look[1], want[1], 9);
    pose.look = l.look;
    pose.glow = 0.85 + 0.15 * @sin(t * 2.0);

    var bob = if (t > 1.4) @sin((t - 1.4) * 1.6) * 5 else 0;
    var shake: f32 = 0;
    const since_err = t - l.err_at;
    if (since_err < 0.7) shake = @sin(since_err * 42) * 9 * @exp(-since_err * 5);
    if (l.phase == .connecting) bob += @sin(t * 4) * 2;
    const zoom = 1 + 0.18 * outCubic(leave_k);
    logo.draw(f.dl, hero_cx + shake * 0.6, hero_cy + bob, logo_size * zoom, pose);

    // --- Nome e frase ---------------------------------------------------------
    if (wide) {
        const word_y = hero_cy + logo_size * 0.375 + 14;
        wordmark(&f, hero_cx, word_y, 50);
        const tag_k = outCubic(seg(t, 1.35, 1.8));
        f.centered(.medium, 17, hero_cx, word_y + 50 * 1.25 + (1 - tag_k) * 8, f.p.muted.alpha(tag_k), "o Discord leve, nativo e do seu jeito");
    } else {
        const ww = f.width(.bold, 34, "larperCord");
        wordmark(&f, hero_cx + logo_size / 2 + 10 + ww / 2, hero_cy - 34 * 0.62, 34);
    }

    // --- Cartão ----------------------------------------------------------------
    const card_k = outCubic(seg(t, 1.2, 1.9));
    if (card_k <= 0.001) return null;
    const cr: Rect = .{ .x = card_x + shake, .y = card_y + (1 - card_k) * 28 + leave_k * 24, .w = card_w, .h = ch };
    const ca = card_k * f.a;
    d.shadow(f.dl, cr, 22, 30, Rgba.black.alpha((if (env.light) @as(f32, 0.12) else 0.45) * ca));
    d.rect(f.dl, cr, f.p.card.alpha(ca), 22);
    d.border(f.dl, cr, f.p.card_border.alpha(ca), 22, 1);
    // Fio de luz no topo do cartão.
    {
        const start = f.dl.*.VtxBuffer.Size;
        d.rect(f.dl, .{ .x = cr.x + 40, .y = cr.y, .w = cr.w - 80, .h = 1.5 }, Rgba.white, 1);
        logo.gradient(f.dl, start, d.v(cr.x + 40, cr.y), d.v(cr.right() - 40, cr.y), 0.8 * ca);
    }

    const saved_a = f.a;
    f.a = ca;
    defer f.a = saved_a;
    const inner_x = cr.x + 32;
    const inner_w = cr.w - 64;
    const result: ?Result = switch (l.phase) {
        .form, .leaving => form(&f, inner_x, cr.y + 30, inner_w),
        .connecting => connecting(&f, inner_x, cr.y + 30, inner_w),
        .hidden => null,
    };

    // Rodapé, embaixo do cartão.
    const foot_k = outCubic(seg(t, 1.7, 2.3)) * f.a;
    const foot_y = cr.bottom() + 18;
    const fcx = cr.x + cr.w / 2;
    // Sem espaço embaixo do cartão: o aviso não pode cobrir os botões.
    f.a = if (foot_y + 34 > f.win.bottom()) 0 else foot_k;
    f.centered(.regular, 12, fcx, foot_y, f.p.faint, "cliente não oficial · vai contra os Termos do Discord, use por sua conta e risco");
    f.centered(.regular, 12, fcx, foot_y + 17, f.p.faint, "o token fica neste computador e só é enviado ao próprio Discord");
    return result;
}

fn background(f: *Frame) void {
    const dl = f.dl;
    const r = f.win;
    const t = f.l.t;
    const intro = outCubic(seg(t, 0, 0.6));
    const a = f.a;
    c.ImDrawList_AddRectFilledMultiColor(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), f.p.bg_top.col(a), f.p.bg_top.col(a), f.p.bg_bot.col(a), f.p.bg_bot.col(a));

    // Aurora: três manchas de luz andando devagar, puxadas pelo mouse.
    const par_x = (f.mouse.x - r.x - r.w / 2) / @max(r.w, 1);
    const par_y = (f.mouse.y - r.y - r.h / 2) / @max(r.h, 1);
    const px = if (f.mouse.x < -1000) 0 else par_x * 30;
    const py = if (f.mouse.x < -1000) 0 else par_y * 30;
    const ak = f.p.aurora * intro * a;
    const big = @max(r.w, r.h);
    logo.glow(dl, r.x + r.w * (0.24 + 0.07 * @sin(t * 0.13)) - px, r.y + r.h * (0.32 + 0.09 * @cos(t * 0.11)) - py, big * 0.48, big * 0.4, logo.violet.alpha(0.34 * ak));
    logo.glow(dl, r.x + r.w * (0.82 + 0.06 * @cos(t * 0.09)) - px * 1.6, r.y + r.h * (0.78 + 0.07 * @sin(t * 0.12)) - py * 1.6, big * 0.42, big * 0.36, logo.pink.alpha(0.24 * ak));
    logo.glow(dl, r.x + r.w * (0.58 + 0.1 * @sin(t * 0.07 + 1)) - px * 0.6, r.y + r.h * (0.1 + 0.05 * @cos(t * 0.15)) - py * 0.6, big * 0.34, big * 0.26, logo.magenta.alpha(0.18 * ak));

    // Constelação: pontos subindo devagar, ligados quando estão perto (e ao
    // mouse) — os "cabos" do nome.
    const n_pts: usize = 64;
    var pts: [n_pts][3]f32 = undefined;
    for (0..n_pts) |i| {
        const vy = 6 + hash(i, 3) * 16;
        const ph = hash(i, 4) * std.math.tau;
        const x = r.x + hash(i, 1) * r.w + @sin(t * 0.25 + ph) * 18 - px * (0.3 + hash(i, 6));
        var y = hash(i, 2) * (r.h + 40) - t * vy;
        y = r.y - 20 + @mod(y, r.h + 40) - py * (0.3 + hash(i, 6));
        const tw = 0.55 + 0.45 * @sin(t * (1 + hash(i, 5) * 2) + ph);
        pts[i] = .{ x, y, tw };
    }
    const link: f32 = 128;
    for (0..n_pts) |i| {
        for (i + 1..n_pts) |j| {
            const dx = pts[i][0] - pts[j][0];
            const dy = pts[i][1] - pts[j][1];
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < link) d.line(dl, pts[i][0], pts[i][1], pts[j][0], pts[j][1], f.p.star.alpha((1 - dist / link) * 0.16 * intro * a), 1);
        }
        const mdx = pts[i][0] - f.mouse.x;
        const mdy = pts[i][1] - f.mouse.y;
        const md = @sqrt(mdx * mdx + mdy * mdy);
        if (md < 170) d.line(dl, pts[i][0], pts[i][1], f.mouse.x, f.mouse.y, f.p.star.alpha((1 - md / 170) * 0.32 * intro * a), 1);
        const size = 1 + hash(i, 7) * 1.6;
        d.circle(dl, pts[i][0], pts[i][1], size, f.p.star.alpha((0.25 + 0.55 * pts[i][2]) * intro * a));
    }

    // Vinheta suave nas bordas (só no escuro).
    if (!f.env.light) {
        const e = Rgba.black.col(0.35 * a);
        const vw = r.h * 0.22;
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(r.x, r.y), d.v(r.right(), r.y + vw), e, e, 0, 0);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(r.x, r.bottom() - vw), d.v(r.right(), r.bottom()), 0, 0, e, e);
    }
}

/// "larperCord" letra por letra, subindo; "Cord" no degradê da marca.
fn wordmark(f: *Frame, cx: f32, y: f32, size: f32) void {
    const word = "larperCord";
    const fb = f.font(.bold);
    const total = f.width(.bold, size, word) - size * 0.02 * 9;
    var x = cx - total / 2;
    for (word, 0..) |ch, i| {
        const k = outCubic(seg(f.l.t, 0.9 + @as(f32, @floatFromInt(i)) * 0.045, 1.25 + @as(f32, @floatFromInt(i)) * 0.045));
        const s = word[i .. i + 1];
        const cw = d.width(fb, size, s);
        if (k > 0.001) {
            const col = if (i < 6) f.p.text else Rgba.white;
            const start = f.dl.*.VtxBuffer.Size;
            d.text(f.dl, fb, size, x, y + (1 - k) * 16, col.alpha(k * f.a), s);
            if (i >= 6) logo.gradient(f.dl, start, d.v(cx, y), d.v(cx + total / 2, y + size), k * f.a);
        }
        _ = ch;
        x += cw - size * 0.02;
    }
}

fn form(f: *Frame, x: f32, y0: f32, w: f32) ?Result {
    const l = f.l;
    const dl = f.dl;
    var result: ?Result = null;
    var y = y0;

    f.text(.bold, 26, x, y, f.p.text, "Entrar");
    y += 38;
    f.text(.regular, 14.5, x, y, f.p.muted, "Cole o token da sua conta do Discord pra começar.");
    y += 34;

    // Campo do token.
    f.text(.bold, 11.5, x, y, f.p.muted, "TOKEN");
    y += 20;
    const fr: Rect = .{ .x = x, .y = y, .w = w, .h = 50 };
    qa.mark(fr, "login:token", .{});
    const has_err = l.err_len > 0;
    d.rect(dl, fr, f.p.field.alpha(f.a), 12);
    // Borda: acende no degradê da marca com o foco.
    const border_col = if (has_err) f.p.danger else f.p.card_border.mix(f.p.muted, 0.25);
    d.border(dl, fr, border_col.alpha(f.a * (1 - f.l.focus_k)), 12, 1.2);
    if (l.focus_k > 0.01) {
        const start = dl.*.VtxBuffer.Size;
        d.border(dl, fr, Rgba.white, 12, 1.6);
        logo.gradient(dl, start, d.v(fr.x, fr.y), d.v(fr.right(), fr.bottom()), f.a * l.focus_k);
        logo.glow(dl, fr.x + fr.w / 2, fr.y + fr.h / 2, fr.w * 0.6, fr.h * 1.1, logo.violet.alpha(0.1 * l.focus_k * f.a));
    }
    lockIcon(dl, fr.x + 20, fr.y + fr.h / 2, (if (l.focus_k > 0.5) f.p.text else f.p.faint).alpha(f.a));

    // Botões dentro do campo: colar (vazio) e mostrar/ocultar.
    const eye_r: Rect = .{ .x = fr.right() - 44, .y = fr.y + 7, .w = 36, .h = 36 };
    const empty = l.tokenText().len == 0;
    const paste_w = f.width(.semibold, 12.5, "Colar") + 20;
    const paste_r: Rect = .{ .x = eye_r.x - paste_w - 4, .y = fr.y + 12, .w = paste_w, .h = 26 };

    const tx = fr.x + 40;
    c.ImGui_SetCursorScreenPos(d.v(tx, fr.y + (fr.h - 18) / 2 - 1));
    c.ImGui_PushFontFloat(f.font(.medium), 15.5);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, v4(f.p.text.alpha(f.a)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextDisabled, v4(f.p.faint.alpha(f.a)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextSelectedBg, v4(logo.violet.alpha(0.4)));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_InputTextCursor, v4(logo.magenta));
    c.ImGui_SetNextItemWidth((if (empty) paste_r.x else eye_r.x) - tx - 8);
    if (l.want_focus and l.t > 1.5) {
        c.ImGui_SetKeyboardFocusHere();
        l.want_focus = false;
    }
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | (if (l.show) 0 else c.ImGuiInputTextFlags_Password);
    const enter = c.ImGui_InputTextWithHint("##token", "Cole aqui o seu token", &l.token, l.token.len, flags);
    const focused = c.ImGui_IsItemActive();
    if (c.ImGui_IsItemEdited()) l.err_len = 0;
    c.ImGui_PopStyleColorEx(4);
    c.ImGui_PopFont();
    l.focus_k = anim.step(l.focus_k, if (focused) 1 else 0, 14);
    if (enter) result = .submit;

    if (empty) {
        const hp = hit(30, paste_r);
        qa.mark(paste_r, "login:colar", .{});
        d.rect(dl, paste_r, logo.violet.alpha((if (hp.hovered) @as(f32, 0.3) else 0.18) * f.a), 8);
        f.text(.semibold, 12.5, paste_r.x + 10, d.centerY(paste_r, 12.5), if (f.env.light) logo.violet else Rgba.hex(0xCBB9FF), "Colar");
        if (hp.clicked) paste(l);
    }
    const he = hit(31, eye_r);
    qa.mark(eye_r, "login:mostrar", .{});
    if (he.clicked) l.show = !l.show;
    if (he.hovered) d.rect(dl, eye_r, f.p.text.alpha(0.06 * f.a), 8);
    l.show_k = anim.step(l.show_k, if (l.show) 1 else 0, 18);
    eyeIcon(dl, eye_r.x + 18, eye_r.y + 18, (if (he.hovered) f.p.text else f.p.muted).alpha(f.a), l.show_k);
    y += fr.h;

    // Erro (balança junto com o cartão).
    if (has_err) {
        y += 9;
        d.circle(dl, x + 6, y + 9, 6, f.p.danger.alpha(f.a));
        f.text(.bold, 10, x + 3.5, y + 2.5, Rgba.white, "!");
        _ = d.textClipped(dl, f.font(.medium), 13.5, x + 18, y + 1, f.p.danger.alpha(f.a), l.err(), w - 18);
        y += 20;
    }
    y += 16;

    // Lembrar.
    {
        const row: Rect = .{ .x = x, .y = y, .w = w, .h = 26 };
        const hr = hit(32, row);
        qa.mark(row, "login:lembrar", .{});
        if (hr.clicked) l.remember = !l.remember;
        l.remember_k = anim.step(l.remember_k, if (l.remember) 1 else 0, 20);
        const tr: Rect = .{ .x = x, .y = y + 3, .w = 36, .h = 20 };
        d.rect(dl, tr, f.p.faint.alpha(0.45 * f.a), 10);
        if (l.remember_k > 0.01) {
            const start = dl.*.VtxBuffer.Size;
            d.rect(dl, tr, Rgba.white, 10);
            logo.gradient(dl, start, d.v(tr.x, tr.y), d.v(tr.right(), tr.bottom()), f.a * l.remember_k);
        }
        d.circle(dl, tr.x + 10 + 16 * l.remember_k, tr.y + 10, 7.5, Rgba.white.alpha(f.a));
        f.text(.medium, 14, x + 48, y + 3, f.p.text, "Lembrar neste computador");
        const note = "no chaveiro do sistema";
        f.text(.regular, 12.5, x + 48 + f.width(.medium, 14, "Lembrar neste computador") + 8, y + 4.5, f.p.faint, note);
        y += row.h + 22;
    }

    // Entrar.
    {
        const br: Rect = .{ .x = x, .y = y, .w = w, .h = 50 };
        const hb = hit(33, br);
        qa.mark(br, "login:entrar", .{});
        if (hb.clicked) result = .submit;
        const press: f32 = if (hb.held) 1.5 else 0;
        const lift: f32 = if (hb.hovered and !hb.held) -1 else 0;
        const r: Rect = .{ .x = br.x + press, .y = br.y + press + lift, .w = br.w - press * 2, .h = br.h - press * 2 };
        logo.glow(dl, r.x + r.w / 2, r.y + r.h * 0.8, r.w * 0.55, r.h * 0.9, logo.magenta.alpha((if (hb.hovered) @as(f32, 0.34) else 0.2) * f.a));
        const start = dl.*.VtxBuffer.Size;
        d.rect(dl, r, Rgba.white, 13);
        logo.gradient(dl, start, d.v(r.x, r.y), d.v(r.right(), r.bottom() + 60), f.a);
        if (hb.hovered) d.rect(dl, r, Rgba.white.alpha(0.08 * f.a), 13);
        // Reflexo que atravessa o botão de tempos em tempos.
        const sweep = @mod(l.t - 2.2, 3.4) / 0.9;
        if (sweep >= 0 and sweep <= 1 and !f.env.reduce) {
            c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), true);
            const sx = r.x - 60 + (r.w + 120) * outCubic(sweep);
            c.ImDrawList_AddQuadFilled(dl, d.v(sx, r.y), d.v(sx + 34, r.y), d.v(sx + 10, r.bottom()), d.v(sx - 24, r.bottom()), Rgba.white.col(0.22 * f.a));
            c.ImDrawList_PopClipRect(dl);
        }
        const label = "Entrar";
        const lw = f.width(.bold, 16, label);
        f.text(.bold, 16, r.x + (r.w - lw) / 2 - 10, d.centerY(r, 16), Rgba.white, label);
        // Setinha que anda no hover.
        const ax = r.x + (r.w + lw) / 2 + 2 + (if (hb.hovered) @as(f32, 4) else 0);
        const ay = r.y + r.h / 2;
        d.line(dl, ax, ay, ax + 12, ay, Rgba.white.alpha(f.a), 2);
        d.line(dl, ax + 7, ay - 5, ax + 12.5, ay + 0.5, Rgba.white.alpha(f.a), 2);
        d.line(dl, ax + 7, ay + 5, ax + 12.5, ay - 0.5, Rgba.white.alpha(f.a), 2);
        y += br.h + 18;
    }

    // ou
    {
        const ow = f.width(.semibold, 12, "ou");
        const my = y + 8;
        d.line(dl, x, my, x + w / 2 - ow / 2 - 12, my, f.p.card_border.alpha(f.a * 1.4), 1);
        d.line(dl, x + w / 2 + ow / 2 + 12, my, x + w, my, f.p.card_border.alpha(f.a * 1.4), 1);
        f.centered(.semibold, 12, x + w / 2, y, f.p.faint, "ou");
        y += 30;
    }

    // Demonstração.
    {
        const br: Rect = .{ .x = x, .y = y, .w = w, .h = 44 };
        const hb = hit(34, br);
        qa.mark(br, "login:demo", .{});
        if (hb.clicked) result = .demo;
        d.rect(dl, br, f.p.text.alpha((if (hb.hovered) @as(f32, 0.09) else 0.05) * f.a), 12);
        d.border(dl, br, f.p.card_border.alpha(f.a), 12, 1);
        const label = "Explorar o modo demonstração";
        f.centered(.semibold, 14.5, x + w / 2, d.centerY(br, 14.5), f.p.text, label);
        y += br.h + 18;
    }

    // Ajuda.
    {
        const label = if (l.help) "Esconder a ajuda" else "Onde encontro o meu token?";
        const lw = f.width(.semibold, 13.5, label);
        const lr: Rect = .{ .x = x + (w - lw) / 2 - 6, .y = y - 3, .w = lw + 12, .h = 24 };
        const hh = hit(35, lr);
        qa.mark(lr, "login:ajuda", .{});
        if (hh.clicked) l.help = !l.help;
        const lcol = if (f.env.light) logo.violet else Rgba.hex(0xB69CFF);
        f.centered(.semibold, 13.5, x + w / 2, y, if (hh.hovered) lcol.mix(f.p.text, 0.3) else lcol, label);
        if (hh.hovered) d.line(dl, lr.x + 6, y + 19, lr.right() - 6, y + 19, lcol.alpha(f.a), 1);
        y += 28;
        l.help_k = anim.step(l.help_k, if (l.help) 1 else 0, 14);
        if (l.help_k > 0.01) {
            const steps = [_][]const u8{
                "Abra discord.com/app no navegador e entre na conta.",
                "Aperte F12 e vá na aba Rede (Network).",
                "Troque de canal e clique numa requisição para /api.",
                "Em Cabeçalhos, copie o valor de Authorization.",
            };
            const full_h: f32 = 4 * 26 + 50;
            const hr: Rect = .{ .x = x, .y = y, .w = w, .h = full_h * l.help_k };
            c.ImDrawList_PushClipRect(dl, d.v(hr.x - 2, hr.y), d.v(hr.right() + 2, hr.bottom()), true);
            d.rect(dl, .{ .x = hr.x, .y = hr.y, .w = hr.w, .h = full_h }, logo.violet.alpha(0.08 * f.a), 12);
            var hy = hr.y + 12;
            for (steps, 0..) |s, i| {
                const nc = d.v(hr.x + 22, hy + 9);
                d.circle(dl, nc.x, nc.y, 9, logo.violet.alpha(0.85 * f.a));
                var nb: [2]u8 = undefined;
                const num = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "";
                f.centered(.bold, 11, nc.x, nc.y - 7, Rgba.white, num);
                _ = d.textClipped(dl, f.font(.regular), 13, hr.x + 40, hy, f.p.text.alpha(f.a), s, hr.w - 52);
                hy += 26;
            }
            hy += 4;
            _ = d.textClipped(dl, f.font(.semibold), 12.5, hr.x + 16, hy, f.p.danger.alpha(f.a), "Quem tem o token tem a sua conta. Não mande pra ninguém.", hr.w - 28);
            c.ImDrawList_PopClipRect(dl);
            y += hr.h + 6;
        }
    }

    y += 22;
    l.card_h = y - y0 + 30;
    return result;
}

fn connecting(f: *Frame, x: f32, y0: f32, w: f32) ?Result {
    const l = f.l;
    const dl = f.dl;
    const t = l.t;
    var result: ?Result = null;
    var y = y0 + 8;
    // Anel girando no degradê da marca.
    const cx = x + w / 2;
    const cy = y + 34;
    const rot = t * 5.2;
    const sweep = 1.7 + 0.9 * @sin(t * 2.6);
    c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 26, f.p.text.alpha(0.08 * f.a).u(), 48, 5, 0);
    const start = dl.*.VtxBuffer.Size;
    c.ImDrawList_PathArcTo(dl, d.v(cx, cy), 26, rot, rot + sweep, 40);
    c.ImDrawList_PathStroke(dl, Rgba.white.u(), 5, 0);
    logo.gradient(dl, start, d.v(cx - 26, cy - 26), d.v(cx + 26, cy + 26), f.a);
    d.circle(dl, cx + @cos(rot + sweep) * 26, cy + @sin(rot + sweep) * 26, 2.5, Rgba.white.alpha(f.a));
    y += 86;

    const dots = @as(usize, @intFromFloat(@mod(t * 2.5, 4)));
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Conectando ao Discord{s}", .{"..."[0..dots]}) catch "";
    f.text(.bold, 20, cx - f.width(.bold, 20, "Conectando ao Discord...") / 2, y, f.p.text, title);
    y += 32;
    const tips = [_][]const u8{
        "Abrindo a conexão com o gateway",
        "Carregando servidores e mensagens diretas",
        "Arrumando os seus canais",
    };
    const since = t - l.phase_at;
    const tip = tips[@min(tips.len - 1, @as(usize, @intFromFloat(since / 1.6)))];
    f.centered(.regular, 14, cx, y, f.p.muted, tip);
    y += 34;

    // Demorando: oferece as saídas.
    if (since > 7) {
        const k = outCubic(seg(since, 7, 7.5));
        const sa = f.a;
        f.a *= k;
        defer f.a = sa;
        f.centered(.regular, 13, cx, y, f.p.faint, "Está demorando mais que o normal. Confira a internet.");
        y += 30;
        const bw = (w - 12) / 2;
        const r1: Rect = .{ .x = x, .y = y, .w = bw, .h = 40 };
        const r2: Rect = .{ .x = x + bw + 12, .y = y, .w = bw, .h = 40 };
        for ([_]Rect{ r1, r2 }, 0..) |r, i| {
            const hb = hit(40 + i, r);
            qa.mark(r, "login:{s}", .{if (i == 0) "outro" else "demo"});
            d.rect(dl, r, f.p.text.alpha((if (hb.hovered) @as(f32, 0.1) else 0.05) * f.a), 11);
            d.border(dl, r, f.p.card_border.alpha(f.a), 11, 1);
            f.centered(.semibold, 13.5, r.x + r.w / 2, d.centerY(r, 13.5), f.p.text, if (i == 0) "Usar outro token" else "Modo demonstração");
            if (hb.clicked) result = if (i == 0) .cancel else .demo;
        }
        y += 52;
    }
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) result = .cancel;
    y += 8;
    l.card_h = y - y0 + 30;
    return result;
}

// --- Ícones ----------------------------------------------------------------------

fn lockIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: Rgba) void {
    d.rect(dl, .{ .x = cx - 7, .y = cy - 2, .w = 14, .h = 11 }, col, 3);
    c.ImDrawList_PathArcTo(dl, d.v(cx, cy - 3), 4.5, std.math.pi, std.math.tau, 12);
    c.ImDrawList_PathStroke(dl, col.u(), 2, 0);
    d.line(dl, cx - 4.5, cy - 3.5, cx - 4.5, cy - 1, col, 2);
    d.line(dl, cx + 4.5, cy - 3.5, cx + 4.5, cy - 1, col, 2);
}

/// Olho para mostrar/ocultar. `open` 0 = riscado.
fn eyeIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: Rgba, open: f32) void {
    c.ImDrawList_PathLineTo(dl, d.v(cx - 9, cy));
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, d.v(cx, cy - 9), d.v(cx + 9, cy), 0);
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, d.v(cx, cy + 9), d.v(cx - 9, cy), 0);
    c.ImDrawList_PathStroke(dl, col.u(), 1.8, 0);
    d.circle(dl, cx, cy, 2.6, col);
    const k = 1 - open;
    if (k > 0.01) d.line(dl, cx - 7, cy - 7, cx - 7 + 14 * k, cy - 7 + 14 * k, col, 1.8);
}

fn v4(x: Rgba) c.ImVec4 {
    return .{ .x = x.r, .y = x.g, .z = x.b, .w = x.a };
}

/// "Colar": copia a área de transferência para o campo.
fn paste(l: *Login) void {
    const clip = c.SDL_GetClipboardText() orelse return;
    defer c.SDL_free(clip);
    const s = std.mem.trim(u8, std.mem.span(clip), " \t\r\n\"");
    const n = @min(s.len, l.token.len - 1);
    @memcpy(l.token[0..n], s[0..n]);
    l.token[n] = 0;
    l.err_len = 0;
    l.want_focus = true;
}
