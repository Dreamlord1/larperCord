const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const text = @import("text.zig");
const ui = @import("ui.zig");

fn setupStyle() void {
    const style = c.ImGui_GetStyle();
    const th = &theme.t;
    style.*.WindowPadding = .{ .x = 0, .y = 0 };
    style.*.WindowBorderSize = 0;
    style.*.ChildBorderSize = 0;
    style.*.FrameBorderSize = 0;
    style.*.FramePadding = .{ .x = 0, .y = 4 };
    style.*.ItemSpacing = .{ .x = 0, .y = 0 };
    style.*.ScrollbarSize = 8;
    style.*.ScrollbarRounding = 4;
    style.*.FontSizeBase = text.body_size;

    const col = &style.*.Colors;
    for (col) |*cc| cc.* = .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    col[c.ImGuiCol_Text] = th.text.vec4(1);
    col[c.ImGuiCol_TextDisabled] = th.faint.vec4(1);
    col[c.ImGuiCol_TextSelectedBg] = th.accent.vec4(0.35);
    col[c.ImGuiCol_InputTextCursor] = th.text.vec4(1);
    col[c.ImGuiCol_ScrollbarGrab] = th.guilds.vec4(0.9);
    col[c.ImGuiCol_ScrollbarGrabHovered] = th.guilds.mix(th.text, 0.1).vec4(1);
    col[c.ImGuiCol_ScrollbarGrabActive] = th.guilds.mix(th.text, 0.2).vec4(1);
    col[c.ImGuiCol_PopupBg] = th.tooltip.vec4(1);
}

/// Em máquinas só com GPU NVIDIA, o glvnd carrega também o EGL do Mesa (e o
/// LLVM junto, ~23 MB) sem necessidade. Restringe ao EGL da NVIDIA nesse caso.
fn preferNvidiaEgl() void {
    const vendor_file = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json";
    if (c.SDL_getenv("__EGL_VENDOR_LIBRARY_FILENAMES") != null) return;
    if (c.SDL_getenv("LARPER_EGL_ALL") != null) return;
    if (!c.SDL_GetPathInfo(vendor_file, null)) return;

    var found = false;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "/sys/class/drm/card{d}/device/vendor", .{i}, 0) catch return;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
        defer c.SDL_free(data);
        const s = std.mem.trim(u8, @as([*]const u8, @ptrCast(data))[0..size], " \n");
        if (!std.mem.eql(u8, s, "0x10de")) return; // tem outra GPU: deixa o glvnd escolher
        found = true;
    }
    if (found) _ = c.SDL_setenv_unsafe("__EGL_VENDOR_LIBRARY_FILENAMES", vendor_file, 0);
}

pub fn main() !void {
    preferNvidiaEgl();
    _ = c.SDL_SetAppMetadata("larperCord", "0.1.0", "dev.larpercord");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("larperCord", 1280, 800, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse
        return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    // LARPER_RENDERER escolhe o backend do SDL (opengl, vulkan, gpu...).
    const want = c.SDL_getenv("LARPER_RENDERER");
    const renderer = c.SDL_CreateRenderer(window, want) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderVSync(renderer, 1);
    std.log.info("renderer: {s}", .{std.mem.span(c.SDL_GetRendererName(renderer))});

    _ = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(null);
    const io = c.ImGui_GetIO();
    io.*.IniFilename = null;
    io.*.ConfigInputTextCursorBlink = false; // sem piscar = sem redesenho parado

    theme.load();
    try text.load(io.*.Fonts);
    io.*.FontDefault = text.fonts.regular;
    setupStyle();

    _ = c.cImGui_ImplSDL3_InitForSDLRenderer(window, renderer);
    defer c.cImGui_ImplSDL3_Shutdown();
    _ = c.cImGui_ImplSDLRenderer3_Init(renderer);
    defer c.cImGui_ImplSDLRenderer3_Shutdown();

    // LARPER_SHOT=arquivo.png salva um print depois de alguns quadros e sai.
    const shot_path = c.SDL_getenv("LARPER_SHOT");
    var frames: u32 = 0;
    const stats = c.SDL_getenv("LARPER_STATS") != null;

    var state: ui.State = .{};
    var pending: u32 = 3;
    var last = c.SDL_GetTicksNS();
    var running = true;

    while (running) {
        // Dorme até chegar um evento, a não ser que algo esteja animando.
        var ev: c.SDL_Event = undefined;
        var got = if (pending > 0 or anim.active) c.SDL_PollEvent(&ev) else c.SDL_WaitEvent(&ev);
        while (got) {
            _ = c.cImGui_ImplSDL3_ProcessEvent(&ev);
            switch (ev.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
                else => {},
            }
            pending = 3;
            got = c.SDL_PollEvent(&ev);
        }

        const now = c.SDL_GetTicksNS();
        anim.dt = std.math.clamp(@as(f32, @floatFromInt(now - last)) / 1e9, 0.001, 1.0 / 30.0);
        last = now;
        anim.active = false;

        c.cImGui_ImplSDLRenderer3_NewFrame();
        c.cImGui_ImplSDL3_NewFrame();
        c.ImGui_NewFrame();
        ui.frame(&state);
        c.ImGui_Render();

        _ = c.SDL_SetRenderScale(renderer, io.*.DisplayFramebufferScale.x, io.*.DisplayFramebufferScale.y);
        const bg = theme.t.chat;
        _ = c.SDL_SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, 1);
        _ = c.SDL_RenderClear(renderer);
        c.cImGui_ImplSDLRenderer3_RenderDrawData(c.ImGui_GetDrawData(), renderer);

        frames += 1;
        if (stats and frames < 20) pending = 2;
        if (stats and frames == 20) {
            const tex = io.*.Fonts.*.TexData;
            std.log.info("atlas: {d}x{d} ({d} KB)", .{ tex.*.Width, tex.*.Height, @divTrunc(tex.*.Width * tex.*.Height * tex.*.BytesPerPixel, 1024) });
            if (c.SDL_getenv("LARPER_TRIM") != null) _ = c.malloc_trim(0);
        }
        if (shot_path != null) {
            pending = 2;
            if (frames == 8) {
                if (c.SDL_RenderReadPixels(renderer, null)) |surface| {
                    _ = c.SDL_SavePNG(surface, shot_path);
                    c.SDL_DestroySurface(surface);
                }
                running = false;
            }
        }
        _ = c.SDL_RenderPresent(renderer);

        if (pending > 0) pending -= 1;
    }
}
