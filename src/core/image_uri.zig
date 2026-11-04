//! Imagem do disco -> `data:` URI, o formato que a API do Discord pede para
//! ícone e banner de servidor e ícone de grupo.
const std = @import("std");

/// Teto do Discord para ícones e banners.
pub const max_bytes: u64 = 10 * 1024 * 1024;

/// O tipo pela extensão; null = formato que o Discord não aceita aqui.
pub fn mimeOf(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return null;
}

/// Monta o URI a partir dos bytes do arquivo.
pub fn encode(gpa: std.mem.Allocator, mime: []const u8, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const head = "data:";
    const mid = ";base64,";
    const out = try gpa.alloc(u8, head.len + mime.len + mid.len + enc.calcSize(bytes.len));
    var n: usize = 0;
    for ([_][]const u8{ head, mime, mid }) |p| {
        @memcpy(out[n..][0..p.len], p);
        n += p.len;
    }
    _ = enc.encode(out[n..], bytes);
    return out;
}

test "formatos aceitos e o URI" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("image/jpeg", mimeOf("/tmp/Foto.JPG").?);
    try std.testing.expectEqualStrings("image/webp", mimeOf("a.webp").?);
    try std.testing.expect(mimeOf("a.bmp") == null);
    try std.testing.expect(mimeOf("sem-extensao") == null);
    const u = try encode(a, "image/png", "oi");
    defer a.free(u);
    try std.testing.expectEqualStrings("data:image/png;base64,b2k=", u);
}
