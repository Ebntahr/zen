//! Host tool: sign and verify Zen application bundles.
//!
//!   codesign keygen <secret-key-file> <public-key-file>
//!   codesign sign <secret-key-file> <bundle.app> [identity]
//!   codesign verify <public-key-file> <bundle.app>
//!
//! Key files hold hex text. The secret key file contains the 32-byte seed.

const std = @import("std");
const zen = @import("zen");
const Ed25519 = std.crypto.sign.Ed25519;

fn usage() noreturn {
    std.debug.print(
        \\usage: codesign keygen <secret-key> <public-key>
        \\       codesign sign <secret-key> <bundle.app> [identity]
        \\       codesign verify <public-key> <bundle.app>
        \\
    , .{});
    std.process.exit(2);
}

fn loadKey(a: std.mem.Allocator, path: []const u8) !Ed25519.KeyPair {
    const text = try std.fs.cwd().readFileAlloc(a, path, 4096);
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, std.mem.trim(u8, text, " \r\n\t"));
    return Ed25519.KeyPair.generateDeterministic(seed);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) usage();
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "keygen")) {
        if (args.len != 4) usage();
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        const kp = try Ed25519.KeyPair.generateDeterministic(seed);
        const sk = try std.fmt.allocPrint(a, "{x}\n", .{seed});
        const pk = try std.fmt.allocPrint(a, "{x}\n", .{kp.public_key.toBytes()});
        const f = try std.fs.cwd().createFile(args[2], .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(sk);
        try std.fs.cwd().writeFile(.{ .sub_path = args[3], .data = pk });
        return;
    }
    if (std.mem.eql(u8, cmd, "sign")) {
        if (args.len < 4) usage();
        const kp = try loadKey(a, args[2]);
        var dir = try std.fs.cwd().openDir(args[3], .{ .iterate = true });
        defer dir.close();
        const identity = if (args.len > 4) args[4] else blk: {
            var b = try zen.bundle.load(a, args[3]);
            break :blk try a.dupe(u8, b.info.id);
        };
        try zen.codesign.sign(a, dir, identity, kp);
        return;
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        if (args.len != 4) usage();
        const pk = try zen.codesign.parsePublicKey(try std.fs.cwd().readFileAlloc(a, args[2], 4096));
        var dir = try std.fs.cwd().openDir(args[3], .{ .iterate = true });
        defer dir.close();
        const v = zen.codesign.verify(a, dir, &.{pk}) catch |err| {
            std.debug.print("{s}: {s}\n", .{ args[3], @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("{s}: valid signature, identity {s}\n", .{ args[3], v.identity });
        return;
    }
    usage();
}
