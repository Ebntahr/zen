//! Host tool: prepare the staged system root before it is packed into the
//! ext2 disk image.
//!
//!   mkimage --root <dir> --keydir <dir> [--manifest file] [--links file]
//!           [--commands file:target-dir:binary] [--user name:password]...
//!
//! Steps: write /etc/shadow, create symlinks, create manifest directories,
//! generate the platform signing key on first use, sign every .app bundle
//! and install the trusted public key.

const std = @import("std");
const zen = @import("zen");
const Ed25519 = std.crypto.sign.Ed25519;

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const a = arena_state.allocator();

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mkimage: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn rel(p: []const u8) []const u8 {
    return std.mem.trimLeft(u8, p, "/");
}

fn loadOrCreateKey(keydir: []const u8) !Ed25519.KeyPair {
    try std.fs.cwd().makePath(keydir);
    const sk_path = try std.fs.path.join(a, &.{ keydir, "platform.key" });
    var seed: [32]u8 = undefined;
    if (std.fs.cwd().readFileAlloc(a, sk_path, 4096)) |text| {
        _ = try std.fmt.hexToBytes(&seed, std.mem.trim(u8, text, " \r\n\t"));
    } else |_| {
        std.crypto.random.bytes(&seed);
        const f = try std.fs.cwd().createFile(sk_path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(try std.fmt.allocPrint(a, "{x}\n", .{seed}));
        std.debug.print("mkimage: generated platform signing key {s}\n", .{sk_path});
    }
    return Ed25519.KeyPair.generateDeterministic(seed);
}

fn signBundles(root: std.fs.Dir, dir_path: []const u8, key: Ed25519.KeyPair) !usize {
    var dir = root.openDir(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        if (!std.mem.endsWith(u8, e.name, ".app")) {
            n += try signBundles(root, try std.fs.path.join(a, &.{ dir_path, e.name }), key);
            continue;
        }
        const bundle_rel = try std.fs.path.join(a, &.{ dir_path, e.name });
        const real = try root.realpathAlloc(a, bundle_rel);
        var b = try zen.bundle.load(a, real);
        defer b.deinit();
        var bdir = try root.openDir(bundle_rel, .{ .iterate = true });
        defer bdir.close();
        try zen.codesign.sign(a, bdir, b.info.id, key);
        n += 1;
    }
    return n;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(a);
    var root_path: ?[]const u8 = null;
    var keydir: []const u8 = "keys";
    var manifest: ?[]const u8 = null;
    var links: ?[]const u8 = null;
    var users: std.ArrayList([]const u8) = .empty;
    var commands: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const opt = args[i];
        if (i + 1 >= args.len) fatal("missing value for {s}", .{opt});
        i += 1;
        const val = args[i];
        if (std.mem.eql(u8, opt, "--root")) root_path = val else if (std.mem.eql(u8, opt, "--keydir")) keydir = val else if (std.mem.eql(u8, opt, "--manifest")) manifest = val else if (std.mem.eql(u8, opt, "--links")) links = val else if (std.mem.eql(u8, opt, "--user")) try users.append(a, val) else if (std.mem.eql(u8, opt, "--commands")) try commands.append(a, val) else fatal("unknown option {s}", .{opt});
    }
    const rp = root_path orelse fatal("--root is required", .{});
    var root = try std.fs.cwd().makeOpenPath(rp, .{ .iterate = true });
    defer root.close();

    // 1. /etc/shadow
    if (users.items.len > 0) {
        var out: std.ArrayList(u8) = .empty;
        for (users.items) |spec| {
            const colon = std.mem.indexOfScalar(u8, spec, ':') orelse fatal("bad --user {s}", .{spec});
            const pw = spec[colon + 1 ..];
            const hash = if (pw.len == 0) "!" else try zen.users.hashPassword(a, pw);
            try out.print(a, "{s}:{s}:19000:0:99999:7:::\n", .{ spec[0..colon], hash });
        }
        try root.makePath("etc");
        const f = try root.createFile("etc/shadow", .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(out.items);
    }

    // 2. Directories named in the manifest.
    if (manifest) |m| {
        const text = try std.fs.cwd().readFileAlloc(a, m, 1 << 20);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const p = rel(f.next() orelse continue);
            if (p.len == 0) continue;
            root.access(p, .{}) catch {
                // Missing: directories are created, files must exist.
                if (std.mem.indexOfScalar(u8, std.fs.path.basename(p), '.') == null or std.mem.startsWith(u8, std.fs.path.basename(p), ".")) {
                    root.makePath(p) catch {};
                }
            };
        }
    }

    // 3. Multi-call command symlinks: "<list-file>:<dir>:<binary>".
    for (commands.items) |spec| {
        var parts = std.mem.splitScalar(u8, spec, ':');
        const list = parts.next() orelse continue;
        const dir = rel(parts.next() orelse continue);
        const target = parts.next() orelse continue;
        const text = try std.fs.cwd().readFileAlloc(a, list, 1 << 20);
        try root.makePath(dir);
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (words.next()) |cmd| {
            const link = try std.fs.path.join(a, &.{ dir, cmd });
            if (std.mem.eql(u8, std.fs.path.basename(target), cmd)) continue;
            root.access(link, .{}) catch {
                root.symLink(target, link, .{}) catch {};
            };
        }
    }

    // 4. Explicit symlinks: "path target" per line.
    if (links) |l| {
        const text = try std.fs.cwd().readFileAlloc(a, l, 1 << 20);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const p = rel(f.next() orelse continue);
            const target = f.next() orelse continue;
            if (std.fs.path.dirname(p)) |d| try root.makePath(d);
            root.deleteFile(p) catch {};
            root.symLink(target, p, .{}) catch |err| fatal("symlink {s}: {s}", .{ p, @errorName(err) });
        }
    }

    // 5. Code signing.
    const key = try loadOrCreateKey(keydir);
    var signed: usize = 0;
    signed += try signBundles(root, "Applications", key);
    signed += try signBundles(root, "System/Applications", key);
    try root.makePath("System/Library/Security");
    try root.writeFile(.{
        .sub_path = "System/Library/Security/platform.pub",
        .data = try std.fmt.allocPrint(a, "# Zen OS platform signing key\n{x}\n", .{key.public_key.toBytes()}),
    });
    std.debug.print("mkimage: signed {d} app bundles\n", .{signed});
}
