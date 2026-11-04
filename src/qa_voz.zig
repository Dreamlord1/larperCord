//! QA da voz: página de Configurações, medidor, teste do microfone, escolha de
//! dispositivo, detecção de voz, aperte para falar, avisos e sons. Roda com o
//! driver mudo do SDL (`voz_audio.force_dummy`): o "microfone" é silêncio, e
//! `qa_tone` põe um tom no lugar para exercitar o caminho inteiro, inclusive a
//! thread de voz da demonstração. Sem call de verdade: isso aqui cobre a
//! interface e a lógica, não o som nem o Discord.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const voz = @import("core/voz.zig");
const voz_audio = @import("net/voz_audio.zig");
const ev = @import("core/event.zig");
const S = @import("ui/settings_state.zig");
const platform = @import("platform/window.zig");
const Id = @import("core/types.zig").Id;

const sh = &voz_audio.sh;
const me: Id = 1000;
const call: Id = 500014;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 6000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}

// --- Injeção -----------------------------------------------------------------

fn toneOn(_: *App) void {
    sh.qa_tone.store(0.25, .monotonic);
}
fn toneOff(_: *App) void {
    sh.qa_tone.store(0, .monotonic);
}

fn pushKey(scancode: c_uint, down: bool) void {
    var e: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    e.type = if (down) c.SDL_EVENT_KEY_DOWN else c.SDL_EVENT_KEY_UP;
    e.key.scancode = scancode;
    e.key.down = down;
    _ = c.SDL_PushEvent(&e);
}

fn pushButton(button: u8, down: bool) void {
    var e: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    e.type = if (down) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_EVENT_MOUSE_BUTTON_UP;
    e.button.button = button;
    e.button.down = down;
    _ = c.SDL_PushEvent(&e);
}

fn fDown(_: *App) void {
    pushKey(c.SDL_SCANCODE_F, true);
}
fn fUp(_: *App) void {
    pushKey(c.SDL_SCANCODE_F, false);
}
fn gDown(_: *App) void {
    pushKey(c.SDL_SCANCODE_G, true);
    pushKey(c.SDL_SCANCODE_G, false);
}
fn escTap(_: *App) void {
    pushKey(c.SDL_SCANCODE_ESCAPE, true);
    pushKey(c.SDL_SCANCODE_ESCAPE, false);
}
fn x1Tap(_: *App) void {
    pushButton(4, true);
    pushButton(4, false);
}
fn x1Down(_: *App) void {
    pushButton(4, true);
}
fn focusLost(_: *App) void {
    var e: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    _ = c.SDL_PushEvent(&e);
}

fn pushFlags(app: *App, flags: ev.VoiceFlags) void {
    app.events.push(.{ .voice_state = .{ .channel = call, .user = me, .flags = flags } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn resetAll(app: *App) void {
    const set = &app.st.settings;
    set.voice_mic = .{};
    set.voice_out = .{};
    set.voice_in_gain = 100;
    set.voice_out_gain = 100;
    set.voice_sens = voz.default_sens;
    set.voice_auto = false;
    set.voice_ptt = false;
    set.voice_key = .{};
    set.voice_highpass = true;
    set.voice_gate = false;
    set.voice_sounds = true;
    sh.qa_tone.store(0, .monotonic);
    sh.qa_fail_mic.store(false, .monotonic);
    if (app.st.muted) app.handle(.toggle_mute);
    if (app.st.deafened) app.handle(.toggle_deafen);
    if (app.st.muted) app.handle(.toggle_mute);
}

// --- Página ------------------------------------------------------------------

fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}
fn settingsClosed(app: *App) bool {
    return !app.st.settings.open;
}
fn pageOpen(app: *App) bool {
    return app.st.settings.page == .voz and sh.page_open.load(.acquire);
}
fn pageMarks(_: *App) bool {
    // O tamanho da fila da saída é zero até o teste: a página não abre som à toa.
    return qa.find("voz-mic") != null and qa.find("voz-out") != null and qa.find("voz-vol:10") != null and qa.find("voz-sens") != null and qa.find("button:Testar microfone") != null;
}
var dev_in: voz_audio.DeviceList = .{};
var dev_out: voz_audio.DeviceList = .{};
fn devicesListed(_: *App) bool {
    voz_audio.copyDevices(&dev_in, &dev_out);
    return dev_in.n > 0 and dev_out.n > 0;
}
fn meterQuiet(_: *App) bool {
    // O driver mudo entrega silêncio: o microfone abriu e não há som.
    return !sh.mic_failed.load(.monotonic) and sh.level_db.load(.monotonic) < -60;
}
fn meterLoud(_: *App) bool {
    // 0,25 do fundo de escala em RMS: cerca de -15 dB.
    return sh.level_db.load(.monotonic) > -20;
}

var loop0: u32 = 0;
fn markLoop(_: *App) void {
    loop0 = sh.loop_frames.load(.monotonic);
}
fn testRuns(_: *App) bool {
    return sh.test_on.load(.acquire) and sh.loop_frames.load(.monotonic) > loop0 + 10;
}
fn testStopped(_: *App) bool {
    return !sh.test_on.load(.acquire) and qa.find("button:Testar microfone") != null;
}
fn testStoppedKeepsCounter(_: *App) bool {
    // O medidor continua, mas nada mais volta para a saída.
    const a = sh.loop_frames.load(.monotonic);
    c.SDL_Delay(120);
    return a == sh.loop_frames.load(.monotonic);
}
fn leftPage(_: *App) bool {
    return !sh.page_open.load(.acquire) and !sh.test_on.load(.acquire);
}
fn levelReset(_: *App) bool {
    return sh.level_db.load(.monotonic) <= voz.db_silence;
}

// --- Dispositivos ------------------------------------------------------------

var opens0: u32 = 0;
fn markOpens(_: *App) void {
    opens0 = sh.mic_opens.load(.monotonic);
}
fn micReopened(_: *App) bool {
    return sh.mic_opens.load(.monotonic) > opens0;
}
fn micOptions(_: *App) bool {
    return qa.find("voz-mic-opt:0") != null and qa.find("voz-mic-opt:1") != null;
}
fn micNamed(app: *App) bool {
    return app.st.settings.voice_mic.slice().len > 0 and std.mem.eql(u8, app.st.settings.voice_mic.slice(), dev_in.slice(0));
}
fn micDefault(app: *App) bool {
    return app.st.settings.voice_mic.slice().len == 0;
}
fn outOptions(_: *App) bool {
    return qa.find("voz-out-opt:1") != null;
}
fn outNamed(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.voice_out.slice(), dev_out.slice(0));
}
fn outDefault(app: *App) bool {
    return app.st.settings.voice_out.slice().len == 0;
}
fn setGoneMic(app: *App) void {
    app.st.settings.voice_mic.set("Placa que sumiu");
    app.st.settings.voice_out.set("Caixa que sumiu");
}
fn goneFallsBack(_: *App) bool {
    return qa.find("voz-mic-sumiu") != null and qa.find("voz-out-sumiu") != null and !sh.mic_failed.load(.monotonic);
}
fn clearMic(app: *App) void {
    app.st.settings.voice_mic = .{};
    app.st.settings.voice_out = .{};
}
fn noFallback(_: *App) bool {
    return qa.find("voz-mic-sumiu") == null and qa.find("voz-out-sumiu") == null;
}

// --- Volume e sensibilidade --------------------------------------------------

fn lowGain(app: *App) void {
    app.st.settings.voice_in_gain = 10;
}
fn levelDropped(_: *App) bool {
    // 20 dB abaixo do tom sozinho (-15 dB), e o medidor cai devagar.
    return sh.level_db.load(.monotonic) < -30;
}
fn gainCentered(app: *App) bool {
    const g = app.st.settings.voice_in_gain;
    return g >= 95 and g <= 105 and sh.in_gain.load(.monotonic) > 0.9;
}
fn outGainCentered(app: *App) bool {
    const g = app.st.settings.voice_out_gain;
    return g >= 95 and g <= 105;
}
fn setLowOut(app: *App) void {
    app.st.settings.voice_out_gain = 20;
}
fn sensCentered(app: *App) bool {
    const v = app.st.settings.voice_sens;
    return v >= 48 and v <= 52 and @abs(sh.threshold_db.load(.monotonic) - -40) < 2;
}
fn autoOn(app: *App) bool {
    return app.st.settings.voice_auto and sh.auto.load(.monotonic);
}
fn autoLearns(_: *App) bool {
    // Silêncio digital leva o aprendido ao mínimo; o tom constante o traz para perto.
    return sh.shown_threshold_db.load(.monotonic) > -35;
}
fn autoOff(app: *App) bool {
    return !app.st.settings.voice_auto;
}
fn pinSens(app: *App) void {
    app.st.settings.voice_sens = 77;
}
fn sensHeldInAuto(app: *App) bool {
    return app.st.settings.voice_sens == 77;
}

// --- Aperte para falar -------------------------------------------------------

fn pttOn(app: *App) bool {
    return app.st.settings.voice_ptt and sh.ptt.load(.monotonic) and qa.find("voz-atalho") != null;
}
fn capturing(_: *App) bool {
    return voz_audio.isCapturing();
}
fn notCapturing(_: *App) bool {
    return !voz_audio.isCapturing();
}
fn keyF(app: *App) bool {
    return !voz_audio.isCapturing() and std.mem.eql(u8, app.st.settings.voice_key.slice(), "k:9") and voz.Binding.decode(sh.binding.load(.monotonic)) == .key;
}
fn keepF(app: *App) bool {
    return !voz_audio.isCapturing() and std.mem.eql(u8, app.st.settings.voice_key.slice(), "k:9") and app.st.settings.open;
}
fn keyMouse(app: *App) bool {
    return !voz_audio.isCapturing() and std.mem.eql(u8, app.st.settings.voice_key.slice(), "m:4");
}
fn pttOff(app: *App) bool {
    return !app.st.settings.voice_ptt and qa.find("toggle:Sensibilidade automática") != null;
}
fn highpassOff(_: *App) bool {
    return !sh.highpass.load(.monotonic);
}
fn highpassOn(_: *App) bool {
    return sh.highpass.load(.monotonic);
}
fn gateOn(_: *App) bool {
    return sh.gate.load(.monotonic);
}
fn gateOff(_: *App) bool {
    return !sh.gate.load(.monotonic);
}
fn soundsOff(_: *App) bool {
    return !sh.sounds.load(.monotonic);
}
fn soundsOn(_: *App) bool {
    return sh.sounds.load(.monotonic);
}

// --- Na call -----------------------------------------------------------------

var sounds0: u32 = 0;
fn markSounds(_: *App) void {
    sounds0 = sh.sounds_played.load(.monotonic);
}
fn soundPlayed(_: *App) bool {
    return sh.sounds_played.load(.monotonic) > sounds0;
}
fn noNewSound(_: *App) bool {
    c.SDL_Delay(60);
    return sh.sounds_played.load(.monotonic) == sounds0;
}
fn join(app: *App) void {
    app.handle(.{ .toggle_voice = call });
}
fn inCall(app: *App) bool {
    return app.st.voice == call and app.st.voice_status == .connected;
}
fn notInCall(app: *App) bool {
    return app.st.voice == null;
}
fn pingShown(app: *App) bool {
    return app.st.voice_ping_ms > 0 and qa.find("voice-ping") != null;
}
/// A linha da pessoa está desenhada? (janela pequena: a lista rola)
fn rowOnScreen(key: []const u8) bool {
    return qa.find(key) != null;
}
fn flagsShown(app: *App) bool {
    // 1003 está mudo pelo servidor na demonstração (a 1001 a bateria geral move).
    if (!app.store.voiceFlags(1003).serverMuted()) return false;
    return !rowOnScreen("voice-member:500014:1003") or qa.find("voice-flagged:1003") != null;
}
fn transmitting(app: *App) bool {
    if (qa.find("voice-transmitting") == null or !app.store.isSpeaking(me, gw.nowMs())) return false;
    // O anel também aparece para si mesmo, com a linha à vista.
    return !rowOnScreen("voice-member:500014:1000") or qa.find("voice-speaking:1000") != null;
}
fn notTransmitting(app: *App) bool {
    return qa.find("voice-transmitting") == null and qa.find("voice-speaking:1000") == null and !app.store.isSpeaking(me, gw.nowMs());
}
fn setPtt(app: *App) void {
    app.st.settings.voice_ptt = true;
    app.st.settings.voice_key.set("k:9");
}
fn setPttMouse(app: *App) void {
    app.st.settings.voice_ptt = true;
    app.st.settings.voice_key.set("m:4");
}
fn clearPtt(app: *App) void {
    app.st.settings.voice_ptt = false;
}
fn failMic(_: *App) void {
    sh.qa_fail_mic.store(true, .monotonic);
}
fn healMic(_: *App) void {
    sh.qa_fail_mic.store(false, .monotonic);
}
fn micWarned(app: *App) bool {
    return app.st.voice_mic_failed and qa.find("voice-warning") != null;
}
fn micHealed(app: *App) bool {
    return !app.st.voice_mic_failed and qa.find("voice-warning") == null;
}
fn serverMute(app: *App) void {
    pushFlags(app, .{ .mute = true });
}
fn serverDeaf(app: *App) void {
    pushFlags(app, .{ .deaf = true });
}
fn serverClear(app: *App) void {
    pushFlags(app, .{});
}
fn serverMutedShown(_: *App) bool {
    return sh.server_mute.load(.acquire) and qa.find("user-forced:0") != null and qa.find("voice-warning") != null;
}
fn serverDeafShown(_: *App) bool {
    return sh.server_deaf.load(.acquire) and qa.find("user-forced:1") != null and qa.find("voice-warning") != null;
}
fn serverCleared(_: *App) bool {
    return !sh.server_mute.load(.acquire) and !sh.server_deaf.load(.acquire) and qa.find("user-forced:0") == null;
}
fn voicePage(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .voz;
}

var out0: u32 = 0;
fn switchDevices(app: *App) void {
    opens0 = sh.mic_opens.load(.monotonic);
    out0 = sh.out_opens.load(.monotonic);
    app.st.settings.voice_mic.set(dev_in.slice(0));
    app.st.settings.voice_out.set(dev_out.slice(0));
}
fn switchedLive(app: *App) bool {
    return sh.mic_opens.load(.monotonic) > opens0 and sh.out_opens.load(.monotonic) > out0 and app.st.voice_status == .connected and app.st.voice == call;
}
fn gain30(app: *App) void {
    app.st.settings.voice_in_gain = 100;
    app.st.settings.voice_sens = 100;
}
fn belowThreshold(_: *App) bool {
    return qa.find("voice-transmitting") == null;
}
fn sensBack(app: *App) void {
    app.st.settings.voice_sens = voz.default_sens;
}

pub const ops = [_]Op{
    s("voz: página"),
    run(resetAll),
    click("user-btn:2"),
    expect("abrir as configurações", settingsOpen),
    click("settings:Voz"),
    expect("a página de voz abre e liga o medidor", pageOpen),
    expect("tudo da página aparece", pageMarks),
    .{ .expect = .{ .name = "a lista de dispositivos chega da thread de áudio", .check = devicesListed, .timeout_ms = 3000 } },
    expectLong("microfone abre no driver mudo e o medidor mostra silêncio", meterQuiet),
    shot("voz-pagina"),

    s("voz: medidor e teste"),
    run(toneOn),
    expect("o medidor sobe com som no microfone", meterLoud),
    shot("voz-medidor"),
    run(markLoop),
    click("button:Testar microfone"),
    expect("Testar microfone toca de volta", testRuns),
    shot("voz-teste"),
    click("button:Parar teste"),
    expect("Parar teste desliga", testStopped),
    expect("parado, nada mais volta para a saída", testStoppedKeepsCounter),
    click("button:Testar microfone"),
    click("settings:Chat"),
    expect("sair da página desliga o teste e o medidor", leftPage),
    expect("o medidor zera fora da página", levelReset),
    click("settings:Voz"),
    expect("voltar à página liga o medidor de novo", pageOpen),
    expect("o medidor volta a subir", meterLoud),

    s("voz: dispositivos"),
    click("voz-mic"),
    expect("a lista de microfones abre com o padrão do sistema", micOptions),
    shot("voz-dispositivos"),
    run(markOpens),
    click("voz-mic-opt:1"),
    expect("escolher um microfone salva o nome", micNamed),
    expect("escolher um microfone reabre na hora", micReopened),
    click("voz-mic"),
    click("voz-mic-opt:0"),
    expect("voltar ao padrão do sistema", micDefault),
    click("voz-out"),
    expect("a lista de saídas abre", outOptions),
    click("voz-out-opt:1"),
    expect("escolher uma saída salva o nome", outNamed),
    click("voz-out"),
    click("voz-out-opt:0"),
    expect("saída de volta ao padrão", outDefault),
    run(setGoneMic),
    .{ .expect = .{ .name = "microfone salvo que sumiu: avisa e usa o padrão", .check = goneFallsBack, .timeout_ms = 3000 } },
    shot("voz-sumiu"),
    run(clearMic),
    expect("sem escolha, sem aviso", noFallback),

    s("voz: volume e sensibilidade"),
    run(lowGain),
    expect("o volume de entrada muda o nível medido", levelDropped),
    click("voz-vol:10"),
    expect("o controle de entrada responde ao mouse", gainCentered),
    run(setLowOut),
    click("voz-vol:11"),
    expect("o controle de saída responde ao mouse", outGainCentered),
    click("voz-sens"),
    expect("arrastar a marca muda o limiar da detecção", sensCentered),
    run(pinSens),
    click("toggle:Sensibilidade automática"),
    expect("modo automático liga", autoOn),
    expectLong("no automático o limiar acompanha o ruído (aqui, o tom constante)", autoLearns),
    click("voz-sens"),
    expect("no automático a barra não muda o limiar", sensHeldInAuto),
    shot("voz-automatico"),
    click("toggle:Sensibilidade automática"),
    expect("modo automático desliga", autoOff),
    run(sensBack),

    s("voz: aperte para falar"),
    click("voz-modo:1"),
    expect("o modo aperte para falar mostra o atalho", pttOn),
    click("voz-atalho"),
    expect("clicar no atalho espera uma tecla", capturing),
    shot("voz-atalho-esperando"),
    run(fDown),
    run(fUp),
    expect("a tecla apertada vira o atalho", keyF),
    shot("voz-atalho"),
    click("voz-atalho"),
    expect("trocar de novo espera outra tecla", capturing),
    run(escTap),
    expect("Esc cancela sem mudar nem fechar a tela", keepF),
    click("voz-atalho"),
    click("voz-atalho"),
    expect("clicar de novo cancela", notCapturing),
    click("voz-atalho"),
    run(x1Tap),
    expect("botão do mouse também serve", keyMouse),
    click("voz-modo:0"),
    expect("volta para a detecção de voz", pttOff),

    s("voz: filtros e sons"),
    click("toggle:Tirar ronco (passa-altas)"),
    expect("desliga o passa-altas", highpassOff),
    click("toggle:Tirar ronco (passa-altas)"),
    expect("liga o passa-altas", highpassOn),
    click("toggle:Porta de ruído"),
    expect("liga a porta de ruído", gateOn),
    click("toggle:Porta de ruído"),
    expect("desliga a porta de ruído", gateOff),
    click("toggle:Sons da call"),
    expect("desliga os sons", soundsOff),
    click("toggle:Sons da call"),
    expect("liga os sons", soundsOn),
    run(toneOff),
    click("settings-close"),
    expect("fechar as configurações", settingsClosed),
    expect("fechar desliga o medidor", leftPage),

    s("voz: na call"),
    run(markSounds),
    run(join),
    expect("entrar na call", inCall),
    expect("som de entrar", soundPlayed),
    expect("ping da call no painel", pingShown),
    expect("mudo e surdo dos outros na lista", flagsShown),
    expect("calado não transmite", notTransmitting),
    shot("voz-call"),
    run(toneOn),
    expect("falando: o anel aparece para si mesmo e o painel diz transmitindo", transmitting),
    shot("voz-transmitindo"),
    .{ .wait = 4500 },
    expect("fala longa: o anel não apaga sozinho", transmitting),
    run(toneOff),
    expect("parou de falar: o anel apaga", notTransmitting),
    run(toneOn),
    expect("falando de novo", transmitting),
    run(markSounds),
    click("user-btn:0"),
    expect("mudo não transmite", notTransmitting),
    expect("som de mutar", soundPlayed),
    run(markSounds),
    click("user-btn:0"),
    expect("desmutar volta a transmitir", transmitting),
    expect("som de desmutar", soundPlayed),
    run(gain30),
    expect("com o limiar acima do nível, não transmite", belowThreshold),
    run(sensBack),
    expect("limiar normal: transmite", transmitting),

    s("voz: aperte para falar na call"),
    run(setPtt),
    expect("sem a tecla não transmite, mesmo com som", notTransmitting),
    shot("voz-ptt"),
    run(fDown),
    expect("a tecla apertada transmite", transmitting),
    run(fUp),
    expect("soltar para de transmitir", notTransmitting),
    run(fDown),
    expect("apertada de novo", transmitting),
    run(focusLost),
    expect("perder o foco solta a tecla", notTransmitting),
    run(fUp),
    run(gDown),
    .{ .wait = 80 },
    expect("outra tecla não transmite", notTransmitting),
    run(setPttMouse),
    run(x1Down),
    expect("botão do mouse como atalho transmite", transmitting),
    run(focusLost),
    expect("sem foco, o botão também solta", notTransmitting),
    run(clearPtt),

    s("voz: avisos"),
    run(failMic),
    expect("microfone que não abre: aviso claro no painel", micWarned),
    shot("voz-sem-microfone"),
    expect("sem microfone não transmite", notTransmitting),
    run(healMic),
    expectLong("microfone volta sozinho e o aviso some", micHealed),
    expect("transmite de novo", transmitting),
    run(serverMute),
    expect("mudo pelo servidor: ícone e aviso", serverMutedShown),
    expect("mudo pelo servidor não transmite", notTransmitting),
    shot("voz-mudo-servidor"),
    run(serverDeaf),
    expect("surdo pelo servidor: ícone e aviso", serverDeafShown),
    expect("surdo pelo servidor não transmite", notTransmitting),
    run(serverClear),
    expect("o servidor libera: some o aviso", serverCleared),
    expect("liberado, transmite de novo", transmitting),

    s("voz: trocar em plena call"),
    run(switchDevices),
    expect("troca microfone e saída sem cair da call", switchedLive),
    expect("depois da troca continua transmitindo", transmitting),
    run(toneOff),
    run(clearMic),
    click("voice-line"),
    expect("a linha do painel abre a página de voz", voicePage),
    click("settings-close"),
    expect("fecha", settingsClosed),
    run(markSounds),
    click("hangup"),
    expect("sair da call", notInCall),
    expect("som de sair", soundPlayed),

    s("voz: sons desligados"),
    click("user-btn:2"),
    click("settings:Voz"),
    click("toggle:Sons da call"),
    expect("sons desligados", soundsOff),
    click("settings-close"),
    run(markSounds),
    run(join),
    expect("entra na call", inCall),
    click("user-btn:0"),
    click("user-btn:0"),
    click("hangup"),
    expect("sai da call", notInCall),
    expect("sem nenhum som", noNewSound),
    run(resetAll),
    .{ .wait = 50 },
};
