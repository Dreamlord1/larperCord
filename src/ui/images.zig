//! Imagens dos anexos: uma thread baixa e decodifica (stb_image), a thread
//! principal só cria a textura. Pede ao proxy de mídia do Discord a imagem
//! já no tamanho em que vai aparecer (menos rede e menos memória), guarda as
//! texturas num cache com limite e solta o que não é visto há um tempo.
//!
//! Só baixa de domínios do Discord: um link qualquer na conversa não faz o
//! app se conectar a outro servidor (o que vazaria o seu IP).
const std = @import("std");
const c = @import("c");
const Queue = @import("../net/queue.zig").Queue;
const platform = @import("../platform/window.zig");
const media_url = @import("../net/media_url.zig");
const allowedHost = media_url.allowedHost;
const proxiedUrl = media_url.proxiedUrl;

const alloc = std.heap.c_allocator;

/// Limite de memória das texturas e tempo até soltar uma imagem fora da tela.
const budget_bytes: usize = 96 * 1024 * 1024;
const idle_ms: i64 = 120_000;
/// Maior arquivo que a gente baixa (o Discord aceita até 10 MB sem Nitro).
const max_download: usize = 32 * 1024 * 1024;

pub const Tex = struct {
    ref: c.ImTextureRef,
    w: u16,
    h: u16,
};

pub const Lookup = union(enum) { loading, ready: Tex, failed };

const State = enum { loading, ready, failed };

const Entry = struct {
    state: State = .loading,
    tex: ?*c.SDL_Texture = null,
    w: u16 = 0,
    h: u16 = 0,
    bytes: usize = 0,
    used_ms: i64 = 0,
};

const Job = struct {
    key: []u8,
    url: []u8,
    max_w: u16,
    max_h: u16,
};

const Result = struct {
    key: []u8,
    pixels: ?[*]u8 = null,
    w: u16 = 0,
    h: u16 = 0,
};

pub const Cache = struct {
    renderer: *c.SDL_Renderer,
    wake_type: u32,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    jobs: Queue(Job),
    results: Queue(Result),
    thread: ?*c.SDL_Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    bytes: usize = 0,
    now_ms: i64 = 0,

    pub fn init(renderer: *c.SDL_Renderer, wake_type: u32) !Cache {
        return .{
            .renderer = renderer,
            .wake_type = wake_type,
            .jobs = try Queue(Job).init(alloc),
            .results = try Queue(Result).init(alloc),
        };
    }

    /// Começa a thread (depois de o Cache estar no lugar definitivo).
    pub fn start(cache: *Cache) !void {
        cache.thread = c.SDL_CreateThread(worker, "media", cache) orelse return error.SdlThread;
    }

    pub fn deinit(cache: *Cache) void {
        cache.stopping.store(true, .release);
        c.SDL_LockMutex(cache.jobs.mutex);
        c.SDL_SignalCondition(cache.jobs.cond);
        c.SDL_UnlockMutex(cache.jobs.mutex);
        if (cache.thread) |t| c.SDL_WaitThread(t, null);
        for (cache.jobs.items.items) |jb| freeJob(jb);
        _ = cache.pump();
        var it = cache.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.tex) |t| c.SDL_DestroyTexture(t);
            alloc.free(e.key_ptr.*);
        }
        cache.map.deinit(alloc);
        cache.jobs.deinit();
        cache.results.deinit();
    }

    /// A imagem de `url` cabendo em max_w×max_h. Pede se ainda não pediu.
    pub fn get(cache: *Cache, url: []const u8, max_w: f32, max_h: f32) Lookup {
        // Tamanhos arredondados: quem pede 301 ou 330 de largura usa a mesma.
        const bw = bucket(max_w);
        const bh = bucket(max_h);
        var kbuf: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d}x{d} {s}", .{ bw, bh, url }) catch return .failed;
        if (cache.map.getPtr(key)) |e| {
            e.used_ms = cache.now_ms;
            return switch (e.state) {
                .loading => .loading,
                .failed => .failed,
                .ready => .{ .ready = .{ .ref = .{ ._TexData = null, ._TexID = @intFromPtr(e.tex.?) }, .w = e.w, .h = e.h } },
            };
        }
        const owned = alloc.dupe(u8, key) catch return .failed;
        cache.map.put(alloc, owned, .{ .used_ms = cache.now_ms }) catch {
            alloc.free(owned);
            return .failed;
        };
        const job: Job = .{
            .key = alloc.dupe(u8, key) catch return .failed,
            .url = alloc.dupe(u8, url) catch return .failed,
            .max_w = bw,
            .max_h = bh,
        };
        cache.jobs.push(job);
        return .loading;
    }

    /// Alguma imagem ainda está baixando (os prints esperam por isso).
    pub fn busy(cache: *const Cache) bool {
        var it = cache.map.valueIterator();
        while (it.next()) |e| if (e.state == .loading) return true;
        return false;
    }

    /// Thread principal: cria as texturas que chegaram e solta as velhas.
    /// Retorna true se chegou alguma imagem (precisa redesenhar).
    pub fn pump(cache: *Cache) bool {
        var batch: std.ArrayList(Result) = .empty;
        defer batch.deinit(alloc);
        cache.results.drain(&batch);
        for (batch.items) |r| {
            defer alloc.free(r.key);
            const e = cache.map.getPtr(r.key) orelse {
                if (r.pixels) |p| alloc.free(p[0 .. @as(usize, r.w) * r.h * 4]);
                continue;
            };
            const px = r.pixels orelse {
                e.state = .failed;
                continue;
            };
            defer alloc.free(px[0 .. @as(usize, r.w) * r.h * 4]);
            const tex = c.SDL_CreateTexture(cache.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, r.w, r.h) orelse {
                e.state = .failed;
                continue;
            };
            _ = c.SDL_UpdateTexture(tex, null, px, @as(c_int, r.w) * 4);
            _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
            _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
            e.* = .{ .state = .ready, .tex = tex, .w = r.w, .h = r.h, .bytes = @as(usize, r.w) * r.h * 4, .used_ms = cache.now_ms };
            cache.bytes += e.bytes;
        }
        cache.evict();
        return batch.items.len > 0;
    }

    /// Solta o que não aparece há `idle_ms` e, se passar do limite, as menos
    /// usadas recentemente (nunca as que estão na tela agora).
    fn evict(cache: *Cache) void {
        while (true) {
            var oldest: ?[]const u8 = null;
            var oldest_ms: i64 = std.math.maxInt(i64);
            var it = cache.map.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.state == .loading) continue;
                const idle = cache.now_ms - e.value_ptr.used_ms;
                if (idle > idle_ms or (cache.bytes > budget_bytes and idle > 1000)) {
                    if (e.value_ptr.used_ms < oldest_ms) {
                        oldest_ms = e.value_ptr.used_ms;
                        oldest = e.key_ptr.*;
                    }
                }
            }
            const k = oldest orelse return;
            const kv = cache.map.fetchRemove(k).?;
            if (kv.value.tex) |t| c.SDL_DestroyTexture(t);
            cache.bytes -= kv.value.bytes;
            alloc.free(kv.key);
        }
    }

    fn freeJob(jb: Job) void {
        alloc.free(jb.key);
        alloc.free(jb.url);
    }

    // --- Thread de mídia --------------------------------------------------------

    fn worker(data: ?*anyopaque) callconv(.c) c_int {
        const cache: *Cache = @ptrCast(@alignCast(data.?));
        var pending: std.ArrayList(Job) = .empty;
        defer {
            for (pending.items) |jb| freeJob(jb);
            pending.deinit(alloc);
        }
        var fresh: std.ArrayList(Job) = .empty;
        defer fresh.deinit(alloc);
        var curl: ?*c.CURL = null;
        defer if (curl) |h| {
            c.curl_easy_cleanup(h);
            c.curl_global_cleanup();
        };
        while (!cache.stopping.load(.acquire)) {
            cache.jobs.waitDrain(&fresh, if (pending.items.len == 0) 1000 else 0);
            pending.appendSlice(alloc, fresh.items) catch {};
            fresh.clearRetainingCapacity();
            // O pedido mais novo primeiro: é o que está na tela agora.
            const jb = pending.pop() orelse continue;
            defer freeJob(jb);
            const res = load(&curl, jb, &cache.stopping);
            cache.results.push(.{ .key = alloc.dupe(u8, jb.key) catch continue, .pixels = res.pixels, .w = res.w, .h = res.h });
            platform.Window.wake(cache.wake_type, .media);
        }
        return 0;
    }
};

fn bucket(v: f32) u16 {
    const step: f32 = 128;
    const x = @ceil(@max(v, 16) / step) * step;
    return @intFromFloat(@min(x, 4096));
}

const Pixels = struct { pixels: ?[*]u8 = null, w: u16 = 0, h: u16 = 0 };

fn load(curl: *?*c.CURL, jb: Job, stop: *std.atomic.Value(bool)) Pixels {
    if (std.mem.startsWith(u8, jb.url, "demo:")) return demo(jb);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    if (std.mem.startsWith(u8, jb.url, "file://")) {
        var pbuf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{jb.url[7..]}, 0) catch return .{};
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return .{};
        defer c.SDL_free(data);
        if (size > max_download) return .{};
        bytes.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return .{};
    } else {
        if (!download(curl, jb, &bytes, stop)) return .{};
    }
    return decode(bytes.items, jb.max_w, jb.max_h);
}

const Sink = struct { list: *std.ArrayList(u8), too_big: bool = false };

fn writeCb(ptr: [*]const u8, size: usize, n: usize, ud: *anyopaque) callconv(.c) usize {
    const s: *Sink = @ptrCast(@alignCast(ud));
    const len = size * n;
    if (s.list.items.len + len > max_download) {
        s.too_big = true;
        return 0;
    }
    s.list.appendSlice(alloc, ptr[0..len]) catch return 0;
    return len;
}

fn abortCb(ud: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const stop: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud.?));
    return @intFromBool(stop.load(.acquire));
}

fn download(curl: *?*c.CURL, jb: Job, out: *std.ArrayList(u8), stop: *std.atomic.Value(bool)) bool {
    if (!allowedHost(jb.url)) return false;
    if (curl.* == null) {
        _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        curl.* = c.curl_easy_init();
    }
    const h = curl.* orelse return false;
    var ubuf: [2048]u8 = undefined;
    const url = proxiedUrl(&ubuf, jb.url, jb.max_w, jb.max_h) orelse return false;
    var sink: Sink = .{ .list = out };
    c.curl_easy_reset(h);
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) larperCord/0.1");
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &sink);
    _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, 25));
    _ = c.curl_easy_setopt(h, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_MAXREDIRS, @as(c_long, 3));
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https");
    _ = c.curl_easy_setopt(h, c.CURLOPT_REDIR_PROTOCOLS_STR, "https");
    _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
    // Fechar o app interrompe o download na hora.
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, abortCb);
    _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFODATA, stop);
    if (c.curl_easy_perform(h) != c.CURLE_OK) return false;
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
    return status == 200 and out.items.len > 0;
}

/// Decodifica e reduz para caber em max_w×max_h. Os pixels voltam no
/// c_allocator (RGBA, 4 bytes por pixel).
fn decode(data: []const u8, max_w: u16, max_h: u16) Pixels {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4) orelse return .{};
    defer c.stbi_image_free(px);
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return .{};
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(sw)), @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(sh))));
    const dw: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sw)) * scale))));
    const dh: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * scale))));
    const out = alloc.alloc(u8, dw * dh * 4) catch return .{};
    const src = px[0 .. sw * sh * 4];
    if (dw == sw and dh == sh) {
        @memcpy(out, src);
    } else resize(src, sw, sh, out, dw, dh);
    return .{ .pixels = out.ptr, .w = @intCast(dw), .h = @intCast(dh) };
}

/// Redução por média de área (sem serrilhado), com alpha pré-multiplicado
/// para as bordas transparentes não ficarem escuras.
fn resize(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    for (0..dh) |dy| {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        for (0..dw) |dx| {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            for (y0..y1) |y| {
                const row = src[y * sw * 4 ..];
                for (x0..x1) |x| {
                    const p = row[x * 4 ..][0..4];
                    const a: u32 = p[3];
                    acc[0] += p[0] * a;
                    acc[1] += p[1] * a;
                    acc[2] += p[2] * a;
                    acc[3] += a;
                }
            }
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            const o = dst[(dy * dw + dx) * 4 ..][0..4];
            if (acc[3] == 0) {
                o.* = .{ 0, 0, 0, 0 };
            } else {
                o[0] = @intCast(acc[0] / acc[3]);
                o[1] = @intCast(acc[1] / acc[3]);
                o[2] = @intCast(acc[2] / acc[3]);
                o[3] = @intCast(acc[3] / n);
            }
        }
    }
}

// --- Imagens da demonstração (geradas, para não pesar no executável) -----------

fn demo(jb: Job) Pixels {
    const which = std.fmt.parseInt(u8, jb.url[5..], 10) catch 1;
    const full: [2]f32 = switch (which) {
        2 => .{ 720, 720 },
        3 => .{ 960, 540 },
        else => .{ 900, 560 },
    };
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(jb.max_w)) / full[0], @as(f32, @floatFromInt(jb.max_h)) / full[1]));
    const w: usize = @intFromFloat(@round(full[0] * scale));
    const h: usize = @intFromFloat(@round(full[1] * scale));
    const out = alloc.alloc(u8, w * h * 4) catch return .{};
    for (0..h) |y| for (0..w) |x| {
        const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
        const col = switch (which) {
            2 => synthwave(u, v),
            3 => aurora(u, v, @floatFromInt(x), @floatFromInt(y)),
            else => sunset(u, v),
        };
        const o = out[(y * w + x) * 4 ..][0..4];
        for (0..3) |i| o[i] = @intFromFloat(std.math.clamp(col[i], 0, 1) * 255);
        o[3] = 255;
    };
    return .{ .pixels = out.ptr, .w = @intCast(w), .h = @intCast(h) };
}

fn mix3(a: [3]f32, b: [3]f32, k: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k };
}

fn hash2(x: f32, y: f32) f32 {
    const s = @sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return s - @floor(s);
}

/// Pôr do sol com montanhas em camadas.
fn sunset(u: f32, v: f32) [3]f32 {
    var col = if (v < 0.6) mix3(.{ 0.28, 0.12, 0.45 }, .{ 1.0, 0.45, 0.35 }, v / 0.6) else mix3(.{ 1.0, 0.45, 0.35 }, .{ 1.0, 0.75, 0.45 }, (v - 0.6) / 0.4);
    const dx = (u - 0.5) * 1.6;
    const dy = v - 0.62;
    const r = @sqrt(dx * dx + dy * dy);
    if (r < 0.13) col = mix3(col, .{ 1.0, 0.93, 0.7 }, 1) else col = mix3(col, .{ 1.0, 0.85, 0.6 }, @max(0, 0.35 - r) * 1.2);
    const layers = [_]struct { base: f32, amp: f32, freq: f32, col: [3]f32 }{
        .{ .base = 0.66, .amp = 0.08, .freq = 7, .col = .{ 0.55, 0.22, 0.45 } },
        .{ .base = 0.74, .amp = 0.07, .freq = 11, .col = .{ 0.36, 0.13, 0.36 } },
        .{ .base = 0.84, .amp = 0.05, .freq = 17, .col = .{ 0.18, 0.06, 0.22 } },
    };
    for (layers) |l| {
        const ridge = l.base - l.amp * (@abs(@sin(u * l.freq)) * 0.7 + @abs(@sin(u * l.freq * 2.3 + 1)) * 0.3);
        if (v > ridge) col = l.col;
    }
    return col;
}

/// Grade synthwave com sol listrado.
fn synthwave(u: f32, v: f32) [3]f32 {
    var col = mix3(.{ 0.08, 0.02, 0.18 }, .{ 0.55, 0.1, 0.55 }, v / 0.55);
    const dx = u - 0.5;
    const dy = v - 0.42;
    if (@sqrt(dx * dx + dy * dy) < 0.24 and v < 0.55) {
        const stripe = @mod(v * 40, 2) < (v - 0.25) * 6;
        if (!stripe) col = mix3(.{ 1.0, 0.85, 0.3 }, .{ 1.0, 0.25, 0.6 }, (v - 0.18) / 0.37);
    }
    if (v >= 0.55) {
        const depth = (v - 0.55) / 0.45;
        col = mix3(.{ 0.1, 0.0, 0.18 }, .{ 0.03, 0.0, 0.08 }, depth);
        const z = 1 / (depth + 0.02);
        const gx = @abs(@mod((u - 0.5) * z * 3, 1) - 0.5);
        const gz = @abs(@mod(z * 0.6, 1) - 0.5);
        const line = @max(@as(f32, @floatCast(@max(0, 0.06 - gx * depth * 0.5))) * 16, @max(0, 0.04 - gz) * 25 * depth);
        col = mix3(col, .{ 1.0, 0.25, 0.85 }, std.math.clamp(line, 0, 1));
    }
    return col;
}

/// Aurora sobre céu estrelado.
fn aurora(u: f32, v: f32, x: f32, y: f32) [3]f32 {
    var col = mix3(.{ 0.01, 0.03, 0.08 }, .{ 0.03, 0.1, 0.18 }, v);
    if (hash2(x, y) > 0.9975) col = .{ 0.9, 0.95, 1 };
    for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const center = 0.35 + 0.12 * fi + 0.08 * @sin(u * (5 + fi * 2) + fi);
        const d = @abs(v - center);
        const band = @exp(-d * d * 160) * (0.6 + 0.4 * @sin(u * 30 + fi * 3));
        const tint: [3]f32 = if (i == 1) .{ 0.55, 0.3, 1.0 } else .{ 0.2, 1.0, 0.6 };
        col = mix3(col, tint, std.math.clamp(band * 0.8, 0, 1));
    }
    if (v > 0.86 - 0.03 * @sin(u * 9)) col = .{ 0.01, 0.02, 0.04 };
    return col;
}
