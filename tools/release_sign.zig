//! Assinatura das versões publicadas (Ed25519).
//!   zig run tools/release_sign.zig -- keygen <arquivo-da-chave>
//!   zig run tools/release_sign.zig -- sign <arquivo-da-chave> <arquivo>   (escreve <arquivo>.sig)
//! O arquivo da chave fica fora do repositório e só o dono lê. A chave pública
//! impressa pelo keygen vai em src/core/version.zig.
const std = @import("std");
const Ed = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "keygen")) {
        const kp = Ed.KeyPair.generate(io);
        const hex = std.fmt.bytesToHex(kp.secret_key.seed(), .lower);
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = &hex, .flags = .{ .permissions = .fromMode(0o600), .exclusive = true } });
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{x}\n", .{&kp.public_key.toBytes()});
        try std.Io.File.stdout().writeStreamingAll(io, line);
        return;
    }
    if (std.mem.eql(u8, args[1], "sign") and args.len == 4) {
        const hex = try cwd.readFileAlloc(io, args[2], gpa, .limited(256));
        defer gpa.free(hex);
        var seed: [Ed.KeyPair.seed_length]u8 = undefined;
        _ = try std.fmt.hexToBytes(&seed, std.mem.trim(u8, hex, " \r\n"));
        const kp = try Ed.KeyPair.generateDeterministic(seed);
        const data = try cwd.readFileAlloc(io, args[3], gpa, .limited(1 << 20));
        defer gpa.free(data);
        const sig = try kp.sign(data, null);
        const out = try std.fmt.allocPrint(gpa, "{x}\n", .{&sig.toBytes()});
        defer gpa.free(out);
        const name = try std.fmt.allocPrint(gpa, "{s}.sig", .{args[3]});
        defer gpa.free(name);
        try cwd.writeFile(io, .{ .sub_path = name, .data = out });
        return;
    }
    return error.Usage;
}
