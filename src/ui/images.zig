//! Imagens dos anexos: threads de mídia baixam e decodificam (stb_image para
//! PNG/JPEG/GIF/BMP, libwebp para WebP, APNG em apng.zig), a thread
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
const apng = @import("apng.zig");

const alloc = std.heap.c_allocator;

/// Limite de memória das texturas e tempo até soltar uma imagem fora da tela.
const budget_bytes: usize = 64 * 1024 * 1024;
const idle_ms: i64 = 60_000;
/// Maior arquivo que a gente baixa (o Discord aceita até 10 MB sem Nitro).
const max_download: usize = 32 * 1024 * 1024;
/// Limite de uma animação (GIF, WebP, APNG) já reduzida: passando disso,
/// pula quadros (o tempo total continua o mesmo, só fica menos fluido).
const max_gif_bytes: usize = 32 * 1024 * 1024;
const max_gif_frames: usize = 300;
/// 4 baixando, mas só 2 decodificando ao mesmo tempo (é o pico de memória e
/// de CPU: cada animação passa por quadros em tamanho cheio).
const workers = 4;
var decode_slots: ?*c.SDL_Semaphore = null;

pub const Tex = struct {
    ref: c.ImTextureRef,
    w: u16,
    h: u16,
    /// Tem mais de um quadro (GIF, WebP ou PNG animado).
    animated: bool = false,
};

pub const Lookup = union(enum) { loading, ready: Tex, failed };

const State = enum { loading, ready, failed };

const Frame = struct {
    tex: *c.SDL_Texture,
    /// Fim deste quadro, em ms desde o começo da animação.
    end_ms: u32,
};

const Entry = struct {
    state: State = .loading,
    frames: []Frame = &.{},
    w: u16 = 0,
    h: u16 = 0,
    bytes: usize = 0,
    used_ms: i64 = 0,

    fn free(e: *Entry) void {
        for (e.frames) |f| c.SDL_DestroyTexture(f.tex);
        if (e.frames.len > 0) alloc.free(e.frames);
        e.frames = &.{};
    }

    fn total(e: *const Entry) u32 {
        return if (e.frames.len == 0) 0 else e.frames[e.frames.len - 1].end_ms;
    }
};

const Job = struct {
    key: []u8,
    url: []u8,
    max_w: u16,
    max_h: u16,
};

/// Quadros decodificados (RGBA, w×h cada), no c_allocator.
const Pixels = struct {
    frames: []PixFrame = &.{},
    w: u16 = 0,
    h: u16 = 0,

    fn deinit(p: Pixels) void {
        for (p.frames) |f| alloc.free(f.data);
        if (p.frames.len > 0) alloc.free(p.frames);
    }

    /// Uma imagem só.
    fn single(data: []u8, w: usize, h: usize) Pixels {
        const fr = alloc.alloc(PixFrame, 1) catch {
            alloc.free(data);
            return .{};
        };
        fr[0] = .{ .data = data, .delay_ms = 0 };
        return .{ .frames = fr, .w = @intCast(w), .h = @intCast(h) };
    }
};

const PixFrame = struct { data: []u8, delay_ms: u32 };

const Result = struct {
    key: []u8,
    px: Pixels = .{},
};

pub const Cache = struct {
    renderer: *c.SDL_Renderer,
    wake_type: u32,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    jobs: Queue(Job),
    results: Queue(Result),
    /// Downloads em paralelo: com uma só, os avatares de uma lista de
    /// membros enfileiram e os ícones dos servidores demoram a aparecer.
    threads: [workers]?*c.SDL_Thread = @splat(null),
    stopping: std.atomic.Value(bool) = .init(false),
    bytes: usize = 0,
    now_ms: i64 = 0,
    /// Quando o próximo quadro de um GIF na tela vence (o laço do app acorda
    /// nessa hora em vez de redesenhar sem parar). Zerado a cada quadro.
    next_frame_ms: i64 = std.math.maxInt(i64),
    evicted_ms: i64 = 0,

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
        if (curl_mutex == null) curl_mutex = c.SDL_CreateMutex() orelse return error.SdlMutex;
        if (decode_slots == null) decode_slots = c.SDL_CreateSemaphore(2) orelse return error.SdlSemaphore;
        for (&cache.threads) |*t| t.* = c.SDL_CreateThread(worker, "media", cache) orelse return error.SdlThread;
    }

    pub fn deinit(cache: *Cache) void {
        cache.stopping.store(true, .release);
        cache.jobs.wakeAll();
        for (cache.threads) |th| if (th) |t| c.SDL_WaitThread(t, null);
        if (curl_inited) {
            c.curl_global_cleanup();
            curl_inited = false;
        }
        for (cache.jobs.items.items) |jb| freeJob(jb);
        _ = cache.pump();
        var it = cache.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.free();
            alloc.free(e.key_ptr.*);
        }
        cache.map.deinit(alloc);
        cache.jobs.deinit();
        cache.results.deinit();
    }

    /// A imagem de `url` cabendo em max_w×max_h. Pede se ainda não pediu.
    /// GIFs tocam sozinhos; `getStill` mostra o primeiro quadro.
    pub fn get(cache: *Cache, url: []const u8, max_w: f32, max_h: f32) Lookup {
        return cache.getEx(url, max_w, max_h, true);
    }

    pub fn getStill(cache: *Cache, url: []const u8, max_w: f32, max_h: f32) Lookup {
        return cache.getEx(url, max_w, max_h, false);
    }

    pub fn getEx(cache: *Cache, url: []const u8, max_w: f32, max_h: f32, play: bool) Lookup {
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
                .ready => .{ .ready = .{ .ref = .{ ._TexData = null, ._TexID = @intFromPtr(cache.frameOf(e, play)) }, .w = e.w, .h = e.h, .animated = e.frames.len > 1 } },
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

    /// O quadro de agora (todos os GIFs andam no mesmo relógio) e quando
    /// o próximo vence.
    fn frameOf(cache: *Cache, e: *const Entry, play: bool) *c.SDL_Texture {
        if (e.frames.len == 1 or !play) return e.frames[0].tex;
        const total = e.total();
        const t: u32 = @intCast(@mod(cache.now_ms, @as(i64, total)));
        for (e.frames) |f| if (t < f.end_ms) {
            cache.next_frame_ms = @min(cache.next_frame_ms, cache.now_ms + (f.end_ms - t));
            return f.tex;
        };
        return e.frames[0].tex;
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
            defer {
                alloc.free(r.key);
                r.px.deinit();
            }
            const e = cache.map.getPtr(r.key) orelse continue;
            if (r.px.frames.len == 0) {
                e.state = .failed;
                continue;
            }
            const frames = alloc.alloc(Frame, r.px.frames.len) catch {
                e.state = .failed;
                continue;
            };
            var n: usize = 0;
            var end: u32 = 0;
            for (r.px.frames) |pf| {
                const tex = c.SDL_CreateTexture(cache.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, r.px.w, r.px.h) orelse break;
                _ = c.SDL_UpdateTexture(tex, null, pf.data.ptr, @as(c_int, r.px.w) * 4);
                _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
                _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
                end += @max(pf.delay_ms, 1);
                frames[n] = .{ .tex = tex, .end_ms = end };
                n += 1;
            }
            if (n == 0) {
                alloc.free(frames);
                e.state = .failed;
                continue;
            }
            const bytes = @as(usize, r.px.w) * r.px.h * 4 * n;
            e.* = .{ .state = .ready, .frames = alloc.realloc(frames, n) catch frames[0..n], .w = r.px.w, .h = r.px.h, .bytes = bytes, .used_ms = cache.now_ms };
            cache.bytes += bytes;
        }
        // A varredura do cache não precisa ser a cada quadro.
        if (batch.items.len > 0 or cache.now_ms - cache.evicted_ms > 500) {
            cache.evicted_ms = cache.now_ms;
            cache.evict();
        }
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
            var kv = cache.map.fetchRemove(k).?;
            kv.value.free();
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
        // Mídia nunca disputa a CPU com a interface.
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        while (!cache.stopping.load(.acquire)) {
            // O pedido mais novo primeiro: é o que está na tela agora.
            const jb = cache.jobs.waitPop(1000) orelse continue;
            defer freeJob(jb);
            const res = load(&curl, jb, &cache.stopping);
            const key = alloc.dupe(u8, jb.key) catch {
                res.deinit();
                continue;
            };
            cache.results.push(.{ .key = key, .px = res });
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

fn load(curl: *?*c.CURL, jb: Job, stop: *std.atomic.Value(bool)) Pixels {
    if (std.mem.startsWith(u8, jb.url, "demo:")) return demo(jb);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    if (std.mem.startsWith(u8, jb.url, "file://")) {
        var pbuf: [1024]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{jb.url[7..]}, 0) catch return .{};
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse {
            logFail(jb.url, "não abriu o arquivo", .{});
            return .{};
        };
        defer c.SDL_free(data);
        if (size > max_download) {
            logFail(jb.url, "grande demais ({d} bytes)", .{size});
            return .{};
        }
        bytes.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return .{};
    } else if (std.mem.startsWith(u8, jb.url, media_url.tenor_page)) {
        // GIF antigo do Tenor: a página diz o endereço novo do vídeo, e dele
        // sai o WebP animado (só com Configurações → Privacidade → GIFs ligado).
        var page: std.ArrayList(u8) = .empty;
        defer page.deinit(alloc);
        var pj = jb;
        pj.url = @constCast(jb.url[media_url.tenor_page.len..]);
        if (!download(curl, pj, &page, stop)) return .{};
        var ub: [512]u8 = undefined;
        const video = media_url.tenorVideoFromPage(page.items) orelse {
            logFail(pj.url, "página do Tenor sem og:video", .{});
            return .{};
        };
        pj.url = @constCast(media_url.gifFromVideo(&ub, video) orelse return .{});
        if (!download(curl, pj, &bytes, stop)) return .{};
    } else {
        if (!download(curl, jb, &bytes, stop)) return .{};
    }
    // Vaga de decodificação (no máximo 2 ao mesmo tempo).
    c.SDL_WaitSemaphore(decode_slots);
    const px = decode(bytes.items, jb.max_w, jb.max_h);
    c.SDL_SignalSemaphore(decode_slots);
    if (px.frames.len == 0) logFail(jb.url, "não decodificou ({d} bytes, começa com {x})", .{ bytes.items.len, bytes.items[0..@min(4, bytes.items.len)] });
    return px;
}

/// Com LARPER_DEBUG_MEDIA, diz no log por que uma imagem falhou. Só host e
/// caminho: a query das URLs do Discord leva assinaturas.
fn logFail(url: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (c.SDL_getenv("LARPER_DEBUG_MEDIA") == null) return;
    std.log.info("mídia {s}: " ++ fmt, .{media_url.logPart(url)} ++ args);
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

/// O libcurl só é iniciado quando a primeira imagem de verdade é pedida
/// (a demonstração não usa rede). Várias threads chegam aqui ao mesmo tempo.
var curl_mutex: ?*c.SDL_Mutex = null;
var curl_inited = false;

fn curlGlobalInit() void {
    c.SDL_LockMutex(curl_mutex);
    defer c.SDL_UnlockMutex(curl_mutex);
    if (curl_inited) return;
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    curl_inited = true;
}

fn download(curl: *?*c.CURL, jb: Job, out: *std.ArrayList(u8), stop: *std.atomic.Value(bool)) bool {
    if (!allowedHost(jb.url)) {
        logFail(jb.url, "domínio não permitido", .{});
        return false;
    }
    if (curl.* == null) {
        curlGlobalInit();
        curl.* = c.curl_easy_init();
    }
    const h = curl.* orelse return false;
    var ubuf: [2048]u8 = undefined;
    const url = proxiedUrl(&ubuf, jb.url, jb.max_w, jb.max_h) orelse return false;
    // Redirecionamentos seguidos à mão: cada destino passa pelo allowedHost
    // (o curl seguiria qualquer um e o app se conectaria a outro servidor).
    var cur: [2048]u8 = undefined;
    var cur_url: [:0]const u8 = url;
    var hops: u8 = 0;
    while (true) : (hops += 1) {
        var sink: Sink = .{ .list = out };
        c.curl_easy_reset(h);
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, cur_url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, "Mozilla/5.0 (X11; Linux x86_64) larperCord/0.1");
        _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &sink);
        _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, 25));
        _ = c.curl_easy_setopt(h, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https");
        _ = c.curl_easy_setopt(h, c.CURLOPT_ACCEPT_ENCODING, "");
        // Fechar o app interrompe o download na hora.
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, abortCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFODATA, stop);
        const rc = c.curl_easy_perform(h);
        if (rc != c.CURLE_OK) {
            if (sink.too_big) {
                logFail(jb.url, "grande demais (mais de {d} MB)", .{max_download / (1024 * 1024)});
            } else if (!stop.load(.acquire)) logFail(jb.url, "erro do curl: {s}", .{std.mem.span(c.curl_easy_strerror(rc))});
            return false;
        }
        var status: c_long = 0;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
        if (status >= 300 and status < 400) {
            var loc: [*c]u8 = null;
            _ = c.curl_easy_getinfo(h, c.CURLINFO_REDIRECT_URL, &loc);
            if (loc == null or hops >= 3) {
                logFail(jb.url, "redirecionamento sem destino ou demais", .{});
                return false;
            }
            const next = std.mem.span(loc);
            if (!allowedHost(next)) {
                logFail(jb.url, "redirecionou para um domínio não permitido", .{});
                return false;
            }
            cur_url = std.fmt.bufPrintSentinel(&cur, "{s}", .{next}, 0) catch return false;
            out.clearRetainingCapacity();
            continue;
        }
        if (status != 200) {
            logFail(jb.url, "HTTP {d}", .{status});
            return false;
        }
        break;
    }
    if (out.items.len == 0) {
        logFail(jb.url, "resposta vazia", .{});
        return false;
    }
    return true;
}

/// Tamanho final de uma imagem sw×sh cabendo em max_w×max_h (nunca aumenta).
fn fit(sw: usize, sh: usize, max_w: u16, max_h: u16) [2]usize {
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(sw)), @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(sh))));
    return .{
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sw)) * scale)))),
        @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * scale)))),
    };
}

/// Decodifica e reduz para caber em max_w×max_h. Os pixels voltam no
/// c_allocator (RGBA, 4 bytes por pixel). GIF, WebP e PNG animados viram
/// vários quadros. O formato vem dos primeiros bytes, não da URL.
fn decode(data: []const u8, max_w: u16, max_h: u16) Pixels {
    if (isWebp(data)) return decodeWebp(data, max_w, max_h);
    if (data.len > 6 and std.mem.startsWith(u8, data, "GIF8")) {
        const anim_px = decodeGif(data, max_w, max_h);
        if (anim_px.frames.len > 0) return anim_px;
    }
    if (apng.isAnimated(data)) {
        const anim_px = decodeApng(data, max_w, max_h);
        if (anim_px.frames.len > 0) return anim_px;
    }
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4) orelse return .{};
    defer c.stbi_image_free(px);
    return still(px, w, h, max_w, max_h);
}

/// Uma imagem só (RGBA w×h), copiada e reduzida.
fn still(px: [*]const u8, w: c_int, h: c_int, max_w: u16, max_h: u16) Pixels {
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return .{};
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const dims = fit(sw, sh, max_w, max_h);
    const out = alloc.alloc(u8, dims[0] * dims[1] * 4) catch return .{};
    const src = px[0 .. sw * sh * 4];
    if (dims[0] == sw and dims[1] == sh) {
        @memcpy(out, src);
    } else resize(src, sw, sh, out, dims[0], dims[1]);
    return Pixels.single(out, dims[0], dims[1]);
}

/// Navegadores tratam atraso < 20 ms de GIF como 100 ms; fazemos igual
/// (no WebP também, que quase sempre vem de um GIF).
fn gifDelay(ms: i64) u32 {
    return if (ms < 20) 100 else @intCast(@min(ms, 60_000));
}

/// Quadros de uma animação (GIF, WebP, APNG), já reduzidos e com limite de
/// memória.
const FrameSink = struct {
    max_w: u16,
    max_h: u16,
    frames: std.ArrayList(PixFrame) = .empty,
    w: usize = 0,
    h: usize = 0,
    /// Guarda 1 de cada `step` quadros (sobe quando passa do limite).
    step: usize = 1,
    seen: usize = 0,

    fn bytes(g: *const FrameSink) usize {
        return g.frames.items.len * g.w * g.h * 4;
    }

    /// Junta os quadros dois a dois (somando o tempo) para caber no limite.
    fn halve(g: *FrameSink) void {
        var i: usize = 0;
        var o: usize = 0;
        while (i < g.frames.items.len) : (i += 2) {
            var f = g.frames.items[i];
            if (i + 1 < g.frames.items.len) {
                f.delay_ms += g.frames.items[i + 1].delay_ms;
                alloc.free(g.frames.items[i + 1].data);
            }
            g.frames.items[o] = f;
            o += 1;
        }
        g.frames.shrinkRetainingCapacity(o);
        g.step *= 2;
    }

    /// Mais um quadro RGBA sw×sh (todos do mesmo tamanho). false = parar.
    fn add(g: *FrameSink, rgba: []const u8, sw: usize, sh: usize, ms: u32) bool {
        defer g.seen += 1;
        if (g.seen % g.step != 0) {
            if (g.frames.items.len > 0) g.frames.items[g.frames.items.len - 1].delay_ms += ms;
            return true;
        }
        const dims = fit(sw, sh, g.max_w, g.max_h);
        g.w = dims[0];
        g.h = dims[1];
        const out = alloc.alloc(u8, dims[0] * dims[1] * 4) catch return false;
        const src = rgba[0 .. sw * sh * 4];
        if (dims[0] == sw and dims[1] == sh) @memcpy(out, src) else resize(src, sw, sh, out, dims[0], dims[1]);
        g.frames.append(alloc, .{ .data = out, .delay_ms = ms }) catch {
            alloc.free(out);
            return false;
        };
        if (g.bytes() > max_gif_bytes or g.frames.items.len > max_gif_frames) g.halve();
        return true;
    }

    fn finish(g: *FrameSink) Pixels {
        if (g.frames.items.len == 0) return .{};
        const frames = g.frames.toOwnedSlice(alloc) catch {
            for (g.frames.items) |f| alloc.free(f.data);
            g.frames.deinit(alloc);
            return .{};
        };
        return .{ .frames = frames, .w = @intCast(g.w), .h = @intCast(g.h) };
    }

    fn gifCb(ud: ?*anyopaque, rgba: [*c]const u8, w: c_int, h: c_int, delay: c_int) callconv(.c) c_int {
        const g: *FrameSink = @ptrCast(@alignCast(ud.?));
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096) return 0;
        const sw: usize = @intCast(w);
        const sh: usize = @intCast(h);
        return @intFromBool(g.add(rgba[0 .. sw * sh * 4], sw, sh, gifDelay(delay)));
    }
};

fn decodeGif(data: []const u8, max_w: u16, max_h: u16) Pixels {
    var sink: FrameSink = .{ .max_w = max_w, .max_h = max_h };
    _ = c.larper_gif_frames(data.ptr, @intCast(data.len), FrameSink.gifCb, &sink);
    return sink.finish();
}

/// "RIFF", tamanho, "WEBP".
fn isWebp(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

/// WebP parado vai direto; o animado passa pelo WebPAnimDecoder, que já
/// compõe cada quadro na tela cheia (os tempos dele são acumulados).
fn decodeWebp(data: []const u8, max_w: u16, max_h: u16) Pixels {
    var feat: c.WebPBitstreamFeatures = undefined;
    if (c.WebPGetFeatures(data.ptr, data.len, &feat) != c.VP8_STATUS_OK) return .{};
    // O tamanho vem no cabeçalho: recusa antes de alocar (mesmo limite do stb).
    if (feat.width <= 0 or feat.height <= 0 or feat.width > 8192 or feat.height > 8192) return .{};
    if (feat.has_animation == 0) {
        var w: c_int = 0;
        var h: c_int = 0;
        const px = c.WebPDecodeRGBA(data.ptr, data.len, &w, &h) orelse return .{};
        defer c.WebPFree(px);
        return still(px, w, h, max_w, max_h);
    }
    var opts: c.WebPAnimDecoderOptions = undefined;
    if (c.WebPAnimDecoderOptionsInit(&opts) == 0) return .{};
    opts.color_mode = c.MODE_RGBA;
    opts.use_threads = 0;
    const wd: c.WebPData = .{ .bytes = data.ptr, .size = data.len };
    const dec = c.WebPAnimDecoderNew(&wd, &opts) orelse return .{};
    defer c.WebPAnimDecoderDelete(dec);
    var info: c.WebPAnimInfo = undefined;
    if (c.WebPAnimDecoderGetInfo(dec, &info) == 0) return .{};
    if (info.canvas_width == 0 or info.canvas_height == 0 or info.canvas_width > 4096 or info.canvas_height > 4096) return .{};
    const cw: usize = info.canvas_width;
    const ch: usize = info.canvas_height;
    var sink: FrameSink = .{ .max_w = max_w, .max_h = max_h };
    var last: c_int = 0;
    while (c.WebPAnimDecoderHasMoreFrames(dec) != 0) {
        var buf: [*c]u8 = null;
        var ts: c_int = 0;
        if (c.WebPAnimDecoderGetNext(dec, &buf, &ts) == 0 or buf == null) break;
        defer last = ts;
        if (!sink.add(buf[0 .. cw * ch * 4], cw, ch, gifDelay(ts - last))) break;
    }
    return sink.finish();
}

/// Cada quadro do APNG chega como um PNG avulso, que o stb_image decodifica.
const ApngCtx = struct {
    sink: *FrameSink,

    pub fn decode(_: *ApngCtx, png: []const u8, w: u32, h: u32, out: []u8) bool {
        var iw: c_int = 0;
        var ih: c_int = 0;
        var comp: c_int = 0;
        const px = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &iw, &ih, &comp, 4) orelse return false;
        defer c.stbi_image_free(px);
        if (iw != w or ih != h) return false;
        @memcpy(out, px[0..out.len]);
        return true;
    }

    pub fn emit(x: *ApngCtx, rgba: []const u8, w: u32, h: u32, delay_ms: u32) bool {
        // O tempo do APNG é fracionário (1/60 s existe de verdade): só
        // ≤ 10 ms vira 100 ms, como nos navegadores.
        return x.sink.add(rgba, w, h, if (delay_ms <= 10) 100 else @min(delay_ms, 60_000));
    }
};

fn decodeApng(data: []const u8, max_w: u16, max_h: u16) Pixels {
    var sink: FrameSink = .{ .max_w = max_w, .max_h = max_h };
    var ctx: ApngCtx = .{ .sink = &sink };
    _ = apng.play(alloc, data, 4096, &ctx) catch {};
    return sink.finish();
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
    const spec = jb.url[5..];
    if (std.mem.startsWith(u8, spec, "av:")) return demoAvatar(std.fmt.parseInt(u64, spec[3..], 10) catch 0, jb, false);
    if (std.mem.startsWith(u8, spec, "icon:")) return demoAvatar(std.fmt.parseInt(u64, spec[5..], 10) catch 0, jb, true);
    if (std.mem.eql(u8, spec, "gif")) return demoGif(jb);
    const which = std.fmt.parseInt(u8, spec, 10) catch 1;
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
    return Pixels.single(out, w, h);
}

fn hsv(h: f32, sat: f32, v: f32) [3]f32 {
    const k = [3]f32{ 5, 3, 1 };
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const t = @mod(k[i] + h * 6, 6);
        out[i] = v - v * sat * std.math.clamp(@min(t, 4 - t), 0, 1);
    }
    return out;
}

fn put(o: []u8, col: [3]f32) void {
    for (0..3) |i| o[i] = @intFromFloat(std.math.clamp(col[i], 0, 1) * 255);
    o[3] = 255;
}

/// Avatar (ou ícone de servidor) da demonstração: degradê com uma forma,
/// diferente para cada semente.
fn demoAvatar(seed: u64, jb: Job, icon: bool) Pixels {
    const size: usize = @min(@min(jb.max_w, jb.max_h), 128);
    const out = alloc.alloc(u8, size * size * 4) catch return .{};
    var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15 +% @intFromBool(icon));
    const r = prng.random();
    const h0 = r.float(f32);
    const h1 = h0 + 0.12 + r.float(f32) * 0.25;
    // Ícone de servidor nunca é o rostinho.
    const kind = if (icon) 1 + r.uintLessThan(u8, 2) else r.uintLessThan(u8, 3);
    const fs: f32 = @floatFromInt(size);
    for (0..size) |y| for (0..size) |x| {
        const u = @as(f32, @floatFromInt(x)) / fs;
        const v = @as(f32, @floatFromInt(y)) / fs;
        var col = mix3(hsv(h0, 0.55, 0.95), hsv(h1, 0.75, 0.55), (u + v) / 2);
        const dx = u - 0.5;
        const dy = v - 0.5;
        switch (kind) {
            // Rosto simples: cabeça e ombros.
            0 => {
                const head = (dx * dx + (dy + 0.08) * (dy + 0.08)) < 0.035;
                const body = ((dx * dx) / 0.09 + ((v - 0.95) * (v - 0.95)) / 0.06) < 1;
                if (head or body) col = mix3(col, .{ 1, 1, 1 }, 0.82);
            },
            // Anéis.
            1 => {
                const d = @sqrt(dx * dx + dy * dy);
                if (@mod(d * 9, 1) < 0.35) col = mix3(col, hsv(h1 + 0.4, 0.4, 1), 0.5);
            },
            // Losango.
            else => if (@abs(dx) + @abs(dy) < 0.3) {
                col = mix3(col, .{ 1, 1, 1 }, 0.75);
            },
        }
        put(out[(y * size + x) * 4 ..][0..4], col);
    };
    return Pixels.single(out, size, size);
}

/// GIF da demonstração: uma bolinha dando a volta, 24 quadros.
fn demoGif(jb: Job) Pixels {
    const n = 24;
    const dims = fit(480, 270, jb.max_w, jb.max_h);
    const w = dims[0];
    const h = dims[1];
    const frames = alloc.alloc(PixFrame, n) catch return .{};
    for (0..n) |f| {
        const out = alloc.alloc(u8, w * h * 4) catch {
            for (frames[0..f]) |fr| alloc.free(fr.data);
            alloc.free(frames);
            return .{};
        };
        const t = @as(f32, @floatFromInt(f)) / n * std.math.tau;
        for (0..h) |y| for (0..w) |x| {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
            var col = mix3(.{ 0.12, 0.05, 0.25 }, .{ 0.02, 0.15, 0.3 }, v);
            for (0..5) |i| {
                const ph = t - @as(f32, @floatFromInt(i)) * 0.35;
                const bx = 0.5 + 0.28 * @cos(ph);
                const by = 0.5 + 0.36 * @sin(ph);
                const dx = (u - bx) * 1.78;
                const dy = v - by;
                const glow = @exp(-(dx * dx + dy * dy) * 260) * (1 - @as(f32, @floatFromInt(i)) * 0.18);
                col = mix3(col, hsv(0.78 + 0.05 * @as(f32, @floatFromInt(i)), 0.6, 1), std.math.clamp(glow, 0, 1));
            }
            put(out[(y * w + x) * 4 ..][0..4], col);
        };
        frames[f] = .{ .data = out, .delay_ms = 50 };
    }
    return .{ .frames = frames, .w = @intCast(w), .h = @intCast(h) };
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
