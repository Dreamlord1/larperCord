//! Fontes: resolve famílias pelo fontconfig, mapeia cada arquivo uma única
//! vez na memória (compartilhado entre pesos e famílias) e mescla o emoji
//! colorido em todas. Famílias novas podem ser carregadas a qualquer momento
//! (troca de tema), fora do intervalo NewFrame/Render.
const std = @import("std");
const c = @import("c");

pub const Weight = enum(u3) { regular, medium, semibold, bold, italic };

pub const Family = struct {
    name: []const u8,
    faces: [5]*c.ImFont,

    pub fn get(f: *const Family, w: Weight) *c.ImFont {
        return f.faces[@intFromEnum(w)];
    }
};

const load_color: c_uint = 1 << 8; // ImGuiFreeTypeLoaderFlags_LoadColor
const load_bitmap: c_uint = 1 << 9; // ImGuiFreeTypeLoaderFlags_Bitmap (emoji CBDT)

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    atlas: *c.ImFontAtlas,
    families: std.ArrayList(*Family) = .empty,
    maps: std.StringHashMapUnmanaged([]u8) = .empty,
    emoji: ?[]u8 = null,
    /// Fonte reserva para símbolos que a fonte principal não tem (⌁ ▣ ◐ ♪ …).
    symbols: ?struct { data: []u8, index: c_int } = null,

    pub fn init(gpa: std.mem.Allocator, atlas: *c.ImFontAtlas) Fonts {
        var f: Fonts = .{ .gpa = gpa, .atlas = atlas };
        if (resolve("emoji", 80, 0)) |m| {
            defer std.heap.c_allocator.free(m.path);
            f.emoji = f.mapPath(m.path) catch null;
        }
        if (resolve("DejaVu Sans", 80, 0)) |m| {
            defer std.heap.c_allocator.free(m.path);
            if (f.mapPath(m.path)) |data| {
                f.symbols = .{ .data = data, .index = m.index };
            } else |_| {}
        }
        return f;
    }

    /// Família pelo nome ("Inter", "JetBrains Mono"...). Carrega se preciso.
    pub fn family(f: *Fonts, name: []const u8) !*Family {
        for (f.families.items) |fam| if (std.mem.eql(u8, fam.name, name)) return fam;

        const fam = try f.gpa.create(Family);
        fam.name = try f.gpa.dupe(u8, name);
        const specs = [_]struct { w: c_int, slant: c_int }{
            .{ .w = 80, .slant = 0 }, // regular
            .{ .w = 100, .slant = 0 }, // medium
            .{ .w = 180, .slant = 0 }, // semibold
            .{ .w = 200, .slant = 0 }, // bold
            .{ .w = 80, .slant = 100 }, // itálico
        };
        for (specs, 0..) |s, i| {
            const m = resolve(name, s.w, s.slant) orelse return error.FontNotFound;
            defer std.heap.c_allocator.free(m.path);
            const data = try f.mapPath(m.path);
            fam.faces[i] = try f.add(data, m.index);
        }
        try f.families.append(f.gpa, fam);
        return fam;
    }

    fn add(f: *Fonts, data: []u8, index: c_int) !*c.ImFont {
        var cfg = defaultConfig();
        cfg.FontNo = @intCast(index);
        cfg.PixelSnapH = true;
        cfg.FontDataOwnedByAtlas = false;
        if (f.emoji != null) cfg.GlyphExcludeRanges = &emoji_ranges;
        const font = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, data.ptr, @intCast(data.len), 16, &cfg, null) orelse return error.FontLoad;
        if (f.emoji) |e| {
            var ecfg = defaultConfig();
            ecfg.MergeMode = true;
            ecfg.FontLoaderFlags = load_color | load_bitmap;
            ecfg.FontDataOwnedByAtlas = false;
            _ = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, e.ptr, @intCast(e.len), 16, &ecfg, null);
        }
        if (f.symbols) |sym| {
            var scfg = defaultConfig();
            scfg.MergeMode = true;
            scfg.FontNo = @intCast(sym.index);
            scfg.FontDataOwnedByAtlas = false;
            _ = c.ImFontAtlas_AddFontFromMemoryTTF(f.atlas, sym.data.ptr, @intCast(sym.data.len), 16, &scfg, null);
        }
        return font;
    }

    /// Mapeia o arquivo (somente leitura); só as páginas lidas ficam na RAM.
    fn mapPath(f: *Fonts, path: [:0]const u8) ![]u8 {
        if (f.maps.get(path)) |m| return m;
        const fd = c.open(path.ptr, c.O_RDONLY);
        if (fd < 0) return error.FontLoad;
        defer _ = c.close(fd);
        const size = c.lseek(fd, 0, c.SEEK_END);
        if (size <= 0) return error.FontLoad;
        const p = c.mmap(null, @intCast(size), c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.FontLoad;
        const data = @as([*]u8, @ptrCast(p))[0..@intCast(size)];
        try f.maps.put(f.gpa, try f.gpa.dupe(u8, path), data);
        return data;
    }
};

/// Faixas que o emoji colorido deve fornecer mesmo que a fonte do texto tenha
/// uma versão em preto e branco (❤ ☀ ✨ …).
const emoji_ranges = [_]c.ImWchar{ 0x2600, 0x27BF, 0x2B00, 0x2BFF, 0x1F000, 0x1FAFF, 0 };

fn defaultConfig() c.ImFontConfig {
    var cfg = std.mem.zeroes(c.ImFontConfig);
    cfg.FontDataOwnedByAtlas = true;
    cfg.ExtraSizeScale = 1.0;
    cfg.GlyphMaxAdvanceX = std.math.floatMax(f32);
    cfg.RasterizerMultiply = 1.0;
    cfg.RasterizerDensity = 1.0;
    return cfg;
}

const Match = struct { path: [:0]u8, index: c_int };

/// Pergunta ao fontconfig qual arquivo atende família + peso + inclinação.
fn resolve(name: []const u8, weight: c_int, slant: c_int) ?Match {
    var buf: [128]u8 = undefined;
    const zname = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, zname.ptr);
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, weight);
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, slant);
    if (std.mem.eql(u8, name, "emoji")) _ = c.FcPatternAddBool(pat, c.FC_COLOR, c.FcTrue);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);
    var result: c.FcResult = undefined;
    const m = c.FcFontMatch(null, pat, &result) orelse return null;
    defer c.FcPatternDestroy(m);
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(m, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(m, c.FC_INDEX, 0, &index);
    const path = std.heap.c_allocator.dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file))), 0) catch return null;
    return .{ .path = path, .index = index };
}
