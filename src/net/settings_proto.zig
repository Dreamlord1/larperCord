//! Pastas e ordem dos servidores a partir do READY (sem dependências, testado
//! no `zig build test`). Contas de usuário recebem `user_settings_proto`: o
//! protobuf `PreloadedUserSettings` em base64 (discord-protos). Só lemos o
//! campo 14, `guild_folders`:
//!
//!   GuildFolders { repeated GuildFolder folders = 1; repeated fixed64 guild_positions = 2; }
//!   GuildFolder  { repeated fixed64 guild_ids = 1; Int64Value id = 2;
//!                  StringValue name = 3; UInt64Value color = 4; }
//!
//! (os "wrappers" do google.protobuf são mensagens com o valor no campo 1).
//! Algumas contas ainda recebem a forma antiga em JSON,
//! `user_settings.guild_folders`; `fromJson` lê essa.
const std = @import("std");
const jsonx = @import("jsonx.zig");

pub const Error = error{
    /// A mensagem acaba no meio de um campo.
    Truncated,
    /// Tipo de fio inválido, varint longo demais, campo 0 etc.
    Malformed,
    InvalidBase64,
    OutOfMemory,
};

/// Uma entrada da barra de servidores. `id == 0` (sem id) é como o Discord
/// guarda um servidor solto, fora de pasta: normalmente com um servidor só.
pub const Folder = struct {
    id: u64,
    /// Vazio = sem nome (o cliente oficial mostra os nomes dos servidores).
    name: []const u8,
    /// 0xRRGGBB; 0 = sem cor.
    color: u32,
    guilds: []const u64,

    /// Servidores soltos: desenhar cada um como ícone normal, sem pasta.
    pub fn isLoose(f: Folder) bool {
        return f.id == 0;
    }
};

/// Toda a memória vem do alocador passado; liberar com `deinit`.
pub const Layout = struct {
    /// Na ordem de exibição. Servidores que não aparecem aqui (entrou há pouco)
    /// o cliente oficial põe no topo.
    folders: []Folder,
    /// Ordem antiga (`guild_positions`); costuma vir vazia hoje em dia.
    positions: []u64,

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        freeFolders(gpa, self.folders);
        gpa.free(self.folders);
        gpa.free(self.positions);
    }
};

fn freeFolders(gpa: std.mem.Allocator, folders: []const Folder) void {
    for (folders) |f| {
        gpa.free(f.name);
        gpa.free(f.guilds);
    }
}

/// `user_settings_proto` do READY (base64, com ou sem `=` no fim).
pub fn fromProtoBase64(gpa: std.mem.Allocator, b64: []const u8) Error!Layout {
    const src = std.mem.trim(u8, b64, " \t\r\n");
    const dec = if (std.mem.endsWith(u8, src, "=")) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
    const n = dec.calcSizeForSlice(src) catch return error.InvalidBase64;
    const buf = try gpa.alloc(u8, n);
    defer gpa.free(buf);
    dec.decode(buf, src) catch return error.InvalidBase64;
    return fromProto(gpa, buf);
}

/// Bytes de `PreloadedUserSettings` já decodificados.
pub fn fromProto(gpa: std.mem.Allocator, bytes: []const u8) Error!Layout {
    var b: Builder = .{};
    errdefer b.deinit(gpa);
    var r: Reader = .{ .buf = bytes };
    while (!r.done()) {
        const k = try r.key();
        if (k.field == 14 and k.wire == 2) {
            try readGuildFolders(gpa, &b, try r.bytes());
        } else try r.skip(k.wire);
    }
    return b.finish(gpa);
}

/// Forma antiga: o array `user_settings.guild_folders` já parseado, com
/// `{ "guild_ids": ["123", …], "id": 456|null, "name": "x"|null, "color": 123|null }`.
/// O JSON não traz `guild_positions`, então `positions` sai vazio.
pub fn fromJson(gpa: std.mem.Allocator, folders: std.json.Value) Error!Layout {
    var b: Builder = .{};
    errdefer b.deinit(gpa);
    for (jsonx.array(folders)) |f| {
        var guilds: std.ArrayList(u64) = .empty;
        defer guilds.deinit(gpa);
        for (jsonx.array(jsonx.get(f, "guild_ids"))) |g| {
            const gid = jsonx.id(g) orelse if (jsonx.int(g)) |i| std.math.cast(u64, i) else null;
            try guilds.append(gpa, gid orelse continue);
        }
        const fid = jsonx.int(jsonx.get(f, "id")) orelse 0;
        const color = jsonx.int(jsonx.get(f, "color")) orelse 0;
        try b.addFolder(gpa, .{
            .id = @bitCast(fid),
            .name = jsonx.str(jsonx.get(f, "name")) orelse "",
            .color = if (color > 0) @truncate(@as(u64, @intCast(color))) else 0,
            .guilds = guilds.items,
        });
    }
    return b.finish(gpa);
}

// ---------------------------------------------------------------------------

const Builder = struct {
    folders: std.ArrayList(Folder) = .empty,
    positions: std.ArrayList(u64) = .empty,

    /// Copia nome e servidores (podem apontar para o buffer de entrada).
    fn addFolder(b: *Builder, gpa: std.mem.Allocator, f: Folder) !void {
        try b.folders.ensureUnusedCapacity(gpa, 1);
        const name = try gpa.dupe(u8, f.name);
        errdefer gpa.free(name);
        const guilds = try gpa.dupe(u64, f.guilds);
        b.folders.appendAssumeCapacity(.{ .id = f.id, .name = name, .color = f.color, .guilds = guilds });
    }

    fn finish(b: *Builder, gpa: std.mem.Allocator) !Layout {
        const folders = try b.folders.toOwnedSlice(gpa);
        errdefer {
            freeFolders(gpa, folders);
            gpa.free(folders);
        }
        return .{ .folders = folders, .positions = try b.positions.toOwnedSlice(gpa) };
    }

    fn deinit(b: *Builder, gpa: std.mem.Allocator) void {
        freeFolders(gpa, b.folders.items);
        b.folders.deinit(gpa);
        b.positions.deinit(gpa);
    }
};

fn readGuildFolders(gpa: std.mem.Allocator, b: *Builder, msg: []const u8) Error!void {
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        switch (k.field) {
            1 => if (k.wire == 2) try readFolder(gpa, b, try r.bytes()) else try r.skip(k.wire),
            2 => if (!try r.repeatedFixed64(gpa, k.wire, &b.positions)) try r.skip(k.wire),
            else => try r.skip(k.wire),
        }
    }
}

fn readFolder(gpa: std.mem.Allocator, b: *Builder, msg: []const u8) Error!void {
    var guilds: std.ArrayList(u64) = .empty;
    defer guilds.deinit(gpa);
    var f: Folder = .{ .id = 0, .name = "", .color = 0, .guilds = &.{} };
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        switch (k.field) {
            1 => if (!try r.repeatedFixed64(gpa, k.wire, &guilds)) try r.skip(k.wire),
            2, 3, 4 => if (k.wire == 2) {
                const w = try readWrapper(try r.bytes());
                switch (k.field) {
                    2 => f.id = w.int,
                    3 => f.name = w.bytes,
                    else => f.color = @truncate(w.int),
                }
            } else try r.skip(k.wire),
            else => try r.skip(k.wire),
        }
    }
    f.guilds = guilds.items;
    try b.addFolder(gpa, f);
}

/// Int64Value/UInt64Value (campo 1 varint) ou StringValue (campo 1 bytes).
const Wrapper = struct { int: u64 = 0, bytes: []const u8 = "" };

fn readWrapper(msg: []const u8) Error!Wrapper {
    var out: Wrapper = .{};
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        if (k.field == 1 and k.wire == 0) {
            out.int = try r.varint();
        } else if (k.field == 1 and k.wire == 2) {
            out.bytes = try r.bytes();
        } else try r.skip(k.wire);
    }
    return out;
}

/// Leitor de protobuf: nunca passa do fim do buffer.
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn done(r: *const Reader) bool {
        return r.pos >= r.buf.len;
    }

    fn varint(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var i: u7 = 0;
        while (i < 10) : (i += 1) {
            if (r.pos >= r.buf.len) return error.Truncated;
            const ch = r.buf[r.pos];
            r.pos += 1;
            v |= @as(u64, ch & 0x7f) << @intCast(7 * i);
            if (ch & 0x80 == 0) return v;
        }
        return error.Malformed;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.Truncated;
        const s = r.buf[r.pos..][0..n];
        r.pos += n;
        return s;
    }

    fn fixed64(r: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }

    fn bytes(r: *Reader) Error![]const u8 {
        const n = try r.varint();
        if (n > r.buf.len - r.pos) return error.Truncated;
        return r.take(@intCast(n));
    }

    fn key(r: *Reader) Error!struct { field: u64, wire: u3 } {
        const k = try r.varint();
        const field = k >> 3;
        if (field == 0) return error.Malformed;
        return .{ .field = field, .wire = @truncate(k) };
    }

    /// Pula um campo desconhecido. Grupos (3/4) são obsoletos: erro.
    fn skip(r: *Reader, wire: u3) Error!void {
        switch (wire) {
            0 => _ = try r.varint(),
            1 => _ = try r.take(8),
            2 => _ = try r.bytes(),
            5 => _ = try r.take(4),
            else => return error.Malformed,
        }
    }

    /// `repeated fixed64`, empacotado (tipo 2) ou não (tipo 1). Devolve false
    /// se o tipo de fio não é nenhum dos dois (aí quem chama pula o campo).
    fn repeatedFixed64(r: *Reader, gpa: std.mem.Allocator, wire: u3, out: *std.ArrayList(u64)) Error!bool {
        switch (wire) {
            1 => try out.append(gpa, try r.fixed64()),
            2 => {
                const data = try r.bytes();
                if (data.len % 8 != 0) return error.Malformed;
                try out.ensureUnusedCapacity(gpa, data.len / 8);
                var i: usize = 0;
                while (i < data.len) : (i += 8)
                    out.appendAssumeCapacity(std.mem.readInt(u64, data[i..][0..8], .little));
            },
            else => return false,
        }
        return true;
    }
};

// ---------------------------------------------------------------------------

/// Codificador mínimo, só para montar mensagens nos testes.
const TestEnc = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn deinit(e: *TestEnc) void {
        e.out.deinit(e.gpa);
    }
    fn varint(e: *TestEnc, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try e.out.append(e.gpa, @as(u8, @truncate(x)) | 0x80);
        try e.out.append(e.gpa, @truncate(x));
    }
    fn key(e: *TestEnc, field: u64, wire: u3) !void {
        try e.varint(field << 3 | wire);
    }
    fn fieldVarint(e: *TestEnc, field: u64, v: u64) !void {
        try e.key(field, 0);
        try e.varint(v);
    }
    fn fieldFixed64(e: *TestEnc, field: u64, v: u64) !void {
        try e.key(field, 1);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try e.out.appendSlice(e.gpa, &b);
    }
    fn fieldFixed32(e: *TestEnc, field: u64, v: u32) !void {
        try e.key(field, 5);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try e.out.appendSlice(e.gpa, &b);
    }
    fn fieldBytes(e: *TestEnc, field: u64, data: []const u8) !void {
        try e.key(field, 2);
        try e.varint(data.len);
        try e.out.appendSlice(e.gpa, data);
    }
    fn fieldPacked64(e: *TestEnc, field: u64, vals: []const u64) !void {
        try e.key(field, 2);
        try e.varint(vals.len * 8);
        for (vals) |v| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            try e.out.appendSlice(e.gpa, &b);
        }
    }
    /// Wrapper do google.protobuf com um varint no campo 1.
    fn fieldWrapInt(e: *TestEnc, field: u64, v: u64) !void {
        var w: TestEnc = .{ .gpa = e.gpa };
        defer w.deinit();
        try w.fieldVarint(1, v);
        try e.fieldBytes(field, w.out.items);
    }
    fn fieldWrapStr(e: *TestEnc, field: u64, s: []const u8) !void {
        var w: TestEnc = .{ .gpa = e.gpa };
        defer w.deinit();
        try w.fieldBytes(1, s);
        try e.fieldBytes(field, w.out.items);
    }
};

/// `PreloadedUserSettings` de exemplo; `range` recebe onde fica o campo 14.
fn testSettings(a: std.mem.Allocator, range: *[2]usize) ![]u8 {
    // Pasta de verdade: id, nome, cor e 3 servidores empacotados.
    var f1: TestEnc = .{ .gpa = a };
    defer f1.deinit();
    try f1.fieldPacked64(1, &.{ 111, 222, 333 });
    try f1.fieldWrapInt(2, 4567);
    try f1.fieldWrapStr(3, "Jogos");
    try f1.fieldWrapInt(4, 0xFF00AA);
    try f1.fieldFixed64(9, 0xdead); // desconhecido

    // Servidor solto: sem id, guild_ids sem empacotar.
    var f2: TestEnc = .{ .gpa = a };
    defer f2.deinit();
    try f2.fieldFixed64(1, 999);

    // Pasta sem nome nem cor, guild_ids misturando as duas formas.
    var f3: TestEnc = .{ .gpa = a };
    defer f3.deinit();
    try f3.fieldFixed64(1, 10);
    try f3.fieldPacked64(1, &.{ 20, 30 });
    try f3.fieldWrapInt(2, 8);

    var gf: TestEnc = .{ .gpa = a };
    defer gf.deinit();
    try gf.fieldBytes(1, f1.out.items);
    try gf.fieldFixed32(7, 1234); // desconhecido no meio
    try gf.fieldBytes(1, f2.out.items);
    try gf.fieldBytes(1, f3.out.items);
    try gf.fieldPacked64(2, &.{ 999, 111 });
    try gf.fieldFixed64(2, 222);

    // Antes do 14: mensagem aninhada (versions), varint, fixed32 e campo de número alto.
    var nested: TestEnc = .{ .gpa = a };
    defer nested.deinit();
    try nested.fieldVarint(1, 300);
    try nested.fieldBytes(3, "\x08\x01");
    var top: TestEnc = .{ .gpa = a };
    errdefer top.deinit();
    try top.fieldBytes(1, nested.out.items);
    try top.fieldVarint(8, std.math.maxInt(u64));
    try top.fieldFixed32(5, 0xcafebabe);
    try top.fieldVarint(5000, 1);
    range[0] = top.out.items.len;
    try top.fieldBytes(14, gf.out.items);
    range[1] = top.out.items.len;
    // Depois do 14: outra mensagem aninhada, fixed64 e fixed32.
    try top.fieldBytes(15, nested.out.items);
    try top.fieldFixed64(3, 42);
    try top.fieldFixed32(27, 7);
    return top.out.toOwnedSlice(a);
}

fn expectSample(l: Layout) !void {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), l.folders.len);
    const f = l.folders[0];
    try t.expectEqual(@as(u64, 4567), f.id);
    try t.expectEqualStrings("Jogos", f.name);
    try t.expectEqual(@as(u32, 0xFF00AA), f.color);
    try t.expectEqualSlices(u64, &.{ 111, 222, 333 }, f.guilds);
    try t.expect(!f.isLoose());

    const s = l.folders[1];
    try t.expect(s.isLoose());
    try t.expectEqualStrings("", s.name);
    try t.expectEqual(@as(u32, 0), s.color);
    try t.expectEqualSlices(u64, &.{999}, s.guilds);

    try t.expectEqual(@as(u64, 8), l.folders[2].id);
    try t.expectEqualSlices(u64, &.{ 10, 20, 30 }, l.folders[2].guilds);
    try t.expectEqualSlices(u64, &.{ 999, 111, 222 }, l.positions);
}

test "pastas e servidores soltos do protobuf, pulando campos desconhecidos" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const l = try fromProto(a, bytes);
    defer l.deinit(a);
    try expectSample(l);

    // Sem o campo 14: tudo vazio.
    const empty = try fromProto(a, "");
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.folders.len);
    try std.testing.expectEqual(@as(usize, 0), empty.positions.len);
}

test "entrada truncada ou malformada dá erro" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    // Cortar em qualquer ponto: nunca lê fora nem vaza; dentro do campo 14 é erro.
    for (0..bytes.len) |n| {
        if (fromProto(a, bytes[0..n])) |l| {
            l.deinit(a);
            try std.testing.expect(n <= range[0] or n >= range[1]);
        } else |err| try std.testing.expectEqual(error.Truncated, err);
    }
    // Varint com mais de 10 bytes.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"));
    // Tipo de fio 3 (grupo) e campo 0.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x0b"));
    try std.testing.expectError(error.Malformed, fromProto(a, "\x00\x00"));
    // guild_ids empacotado com tamanho que não é múltiplo de 8.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x72\x0b\x0a\x09\x0a\x07\x01\x02\x03\x04\x05\x06\x07"));
    // Comprimento maior que o resto da mensagem.
    try std.testing.expectError(error.Truncated, fromProto(a, "\x72\xff\xff\xff\xff\x0f\x00"));
}

fn parseAndFree(a: std.mem.Allocator, bytes: []const u8) !void {
    const l = try fromProto(a, bytes);
    l.deinit(a);
}

test "sem vazamento quando falta memória" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, parseAndFree, .{bytes});
}

test "base64 do user_settings_proto" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(b64);
    _ = enc.encode(b64, bytes);

    const l = try fromProtoBase64(a, b64);
    defer l.deinit(a);
    try expectSample(l);

    // Sem o `=` do fim também serve.
    const unpadded = std.mem.trimEnd(u8, b64, "=");
    const l2 = try fromProtoBase64(a, unpadded);
    defer l2.deinit(a);
    try expectSample(l2);

    try std.testing.expectError(error.InvalidBase64, fromProtoBase64(a, "não é base64!"));
}

test "forma antiga em JSON (user_settings.guild_folders)" {
    const a = std.testing.allocator;
    const text =
        \\[
        \\  {"guild_ids": ["111", "222", "333"], "id": 4567, "name": "Jogos", "color": 16711850},
        \\  {"guild_ids": ["999"], "id": null, "name": null, "color": null},
        \\  {"guild_ids": ["10", "lixo", 20], "id": "8"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const l = try fromJson(a, parsed.value);
    defer l.deinit(a);

    try std.testing.expectEqual(@as(usize, 3), l.folders.len);
    try std.testing.expectEqual(@as(u64, 4567), l.folders[0].id);
    try std.testing.expectEqualStrings("Jogos", l.folders[0].name);
    try std.testing.expectEqual(@as(u32, 0xFF00AA), l.folders[0].color);
    try std.testing.expectEqualSlices(u64, &.{ 111, 222, 333 }, l.folders[0].guilds);
    try std.testing.expect(l.folders[1].isLoose());
    try std.testing.expectEqualStrings("", l.folders[1].name);
    try std.testing.expectEqualSlices(u64, &.{999}, l.folders[1].guilds);
    try std.testing.expectEqual(@as(u64, 8), l.folders[2].id);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, l.folders[2].guilds);
    try std.testing.expectEqual(@as(usize, 0), l.positions.len);

    // Algo que não é array: lista vazia, sem erro.
    const none = try fromJson(a, .null);
    defer none.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), none.folders.len);
}
