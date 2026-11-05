//! Janela, renderizador e o mecanismo de "acordar" o laço principal.
//! É a única parte que conhece o SDL e o backend gráfico; um backend por
//! software (wl_shm, sem GPU) entraria aqui sem mexer no resto.
const std = @import("std");
const sys = @import("sys.zig");
const c = @import("c");

pub const Wake = enum(i32) {
    gateway = 1,
    theme = 2,
    tick = 3,
    media = 4,
    token = 5,
    /// Abrir a janela: menu da bandeja ou um segundo larperCord.
    show = 6,
    /// Sair de verdade: menu da bandeja.
    quit = 7,
    /// A thread dos plugins tem pedidos para a interface.
    plugins = 8,
};

pub const Window = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    wake_type: u32,

    pub fn init(title: [*:0]const u8, w: c_int, h: c_int) !Window {
        preferNvidiaEgl();
        // Fechar a janela é o app quem decide (ficar na bandeja ou sair). Sem
        // isto o SDL ainda manda um QUIT junto, e QUIT aqui é sempre sair.
        _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
        _ = c.SDL_SetAppMetadata("larperCord", (@import("build_options").version ++ "\x00").ptr, "dev.larpercord");
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        var flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_TRANSPARENT;
        // LARPER_HIDDEN=1: janela escondida (medir desempenho com a GPU de verdade).
        if (c.SDL_getenv("LARPER_HIDDEN") != null) flags |= c.SDL_WINDOW_HIDDEN;
        const window = c.SDL_CreateWindow(title, w, h, flags) orelse return error.SdlWindow;
        if (decodeIcon(icon_64)) |icon| {
            _ = c.SDL_SetWindowIcon(window, icon);
            c.SDL_DestroySurface(icon);
        }
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

/// Ícones embutidos (tools/gen_icons.py).
pub const icon_64 = @embedFile("icon_64");
pub const icon_32 = @embedFile("icon_32");

/// PNG embutido para uma superfície do SDL (quem chama destrói).
pub fn decodeIcon(png: []const u8) ?*c.SDL_Surface {
    var iw: c_int = 0;
    var ih: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &iw, &ih, &comp, 4) orelse return null;
    defer c.stbi_image_free(px);
    const borrowed = c.SDL_CreateSurfaceFrom(iw, ih, c.SDL_PIXELFORMAT_RGBA32, px, iw * 4) orelse return null;
    defer c.SDL_DestroySurface(borrowed);
    return c.SDL_DuplicateSurface(borrowed);
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

/// Memória proporcional (PSS) do próprio processo, em KB.
pub fn selfPssKb() u32 {
    if (sys.windows) return sys.privateKb();
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
