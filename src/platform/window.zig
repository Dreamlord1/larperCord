//! Janela, renderizador e o mecanismo de "acordar" o laço principal.
//! É a única parte que conhece o SDL e o backend gráfico; um backend por
//! software (wl_shm, sem GPU) entraria aqui sem mexer no resto.
const std = @import("std");
const c = @import("c");

pub const Wake = enum(i32) { gateway = 1, theme = 2, tick = 3, media = 4 };

pub const Window = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    wake_type: u32,

    pub fn init(title: [*:0]const u8, w: c_int, h: c_int) !Window {
        preferNvidiaEgl();
        _ = c.SDL_SetAppMetadata("larperCord", "0.2.0", "dev.larpercord");
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        var flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_TRANSPARENT;
        // LARPER_HIDDEN=1: janela escondida (medir desempenho com a GPU de verdade).
        if (c.SDL_getenv("LARPER_HIDDEN") != null) flags |= c.SDL_WINDOW_HIDDEN;
        const window = c.SDL_CreateWindow(title, w, h, flags) orelse return error.SdlWindow;
        // LARPER_RENDERER escolhe o backend do SDL (opengl, vulkan, gpu, software).
        const renderer = c.SDL_CreateRenderer(window, c.SDL_getenv("LARPER_RENDERER")) orelse return error.SdlRenderer;
        _ = c.SDL_SetRenderVSync(renderer, 1);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
        const wake_type = c.SDL_RegisterEvents(1);
        return .{ .window = window, .renderer = renderer, .wake_type = wake_type };
    }

    pub fn deinit(win: *Window) void {
        c.SDL_DestroyRenderer(win.renderer);
        c.SDL_DestroyWindow(win.window);
        c.SDL_Quit();
    }

    /// Pode ser chamado de qualquer thread.
    pub fn wake(wake_type: u32, what: Wake) void {
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = wake_type;
        ev.user.code = @intFromEnum(what);
        _ = c.SDL_PushEvent(&ev);
    }

    pub fn screenshot(win: *Window, path: [*:0]const u8) bool {
        const surface = c.SDL_RenderReadPixels(win.renderer, null) orelse return false;
        defer c.SDL_DestroySurface(surface);
        return c.SDL_SavePNG(surface, path);
    }
};

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

/// Memória proporcional (PSS) do próprio processo, em KB.
pub fn selfPssKb() u32 {
    // Arquivos do /proc não informam o tamanho, então lê direto.
    const fd = c.open("/proc/self/smaps_rollup", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const s = buf[0..@intCast(n)];
    const at = std.mem.indexOf(u8, s, "\nPss:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, s[at + 5 ..], " \t");
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u32, num, 10) catch 0;
}
