//! Code signing for application bundles (Ed25519 over SHA-256 hashes).
//!
//! `Contents/CodeSignature` is a text file:
//!
//!     zen-codesign 1
//!     identity com.zen.TextEdit
//!     file Contents/Bin/TextEdit 9f86d0…
//!     file Contents/Info.conf 2c26b4…
//!     signer <hex public key>
//!     signature <hex signature over every line above>
//!
//! Every regular file inside the bundle (except the signature itself) is
//! listed in sorted order, so adding, removing or modifying any file
//! breaks the signature. Launch-time verification recomputes the manifest
//! and requires the signer to be in the trusted key list.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_file = "Contents/CodeSignature";

pub const Error = error{ Unsigned, Tampered, UntrustedSigner, BadSignature, Malformed };

pub const Verified = struct {
    /// Bundle identity recorded in the signature (caller frees).
    identity: []u8,
    /// Index of the trusted key that signed the bundle.
    key_index: usize,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Build the manifest (everything before the signer line) for a bundle.
pub fn manifest(allocator: std.mem.Allocator, bundle: std.fs.Dir, identity: []const u8) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var walker = try bundle.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.path, signature_file)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "zen-codesign 1\nidentity {s}\n", .{identity});
    var buf: [64 * 1024]u8 = undefined;
    for (names.items) |name| {
        var h = Sha256.init(.{});
        const stat = try bundle.statFile(name);
        if (stat.kind == .sym_link) {
            var lbuf: [std.fs.max_path_bytes]u8 = undefined;
            h.update("symlink:");
            h.update(try bundle.readLink(name, &lbuf));
        } else {
            const f = try bundle.openFile(name, .{});
            defer f.close();
            while (true) {
                const n = try f.read(&buf);
                if (n == 0) break;
                h.update(buf[0..n]);
            }
        }
        const digest = h.finalResult();
        try out.print(allocator, "file {s} {x}\n", .{ name, digest });
    }
    return out.toOwnedSlice(allocator);
}

/// Sign a bundle in place.
pub fn sign(allocator: std.mem.Allocator, bundle: std.fs.Dir, identity: []const u8, key: Ed25519.KeyPair) !void {
    const m = try manifest(allocator, bundle, identity);
    defer allocator.free(m);
    const sig = try key.sign(m, null);
    const text = try std.fmt.allocPrint(allocator, "{s}signer {x}\nsignature {x}\n", .{ m, key.public_key.toBytes(), sig.toBytes() });
    defer allocator.free(text);
    try bundle.writeFile(.{ .sub_path = signature_file, .data = text });
}

fn hexField(line: []const u8, prefix: []const u8, comptime n: usize) ?[n]u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const hex = std.mem.trim(u8, line[prefix.len..], " \r");
    var out: [n]u8 = undefined;
    const got = std.fmt.hexToBytes(&out, hex) catch return null;
    if (got.len != n) return null;
    return out;
}

/// Verify a bundle against a list of trusted public keys.
pub fn verify(allocator: std.mem.Allocator, bundle: std.fs.Dir, trusted: []const Ed25519.PublicKey) !Verified {
    const text = bundle.readFileAlloc(allocator, signature_file, 16 << 20) catch |err| switch (err) {
        error.FileNotFound => return error.Unsigned,
        else => return err,
    };
    defer allocator.free(text);

    const signer_pos = std.mem.indexOf(u8, text, "\nsigner ") orelse return error.Malformed;
    const signed_part = text[0 .. signer_pos + 1];
    var lines = std.mem.splitScalar(u8, text[signer_pos + 1 ..], '\n');
    const signer = hexField(lines.next() orelse return error.Malformed, "signer ", 32) orelse return error.Malformed;
    const sig_bytes = hexField(lines.next() orelse return error.Malformed, "signature ", 64) orelse return error.Malformed;

    const pk = Ed25519.PublicKey.fromBytes(signer) catch return error.Malformed;
    const key_index = for (trusted, 0..) |t, i| {
        if (std.mem.eql(u8, &t.toBytes(), &signer)) break i;
    } else return error.UntrustedSigner;
    Ed25519.Signature.fromBytes(sig_bytes).verify(signed_part, pk) catch return error.BadSignature;

    // The signed manifest must match the bundle's current contents.
    var ident_it = std.mem.splitScalar(u8, signed_part, '\n');
    _ = ident_it.next();
    const ident_line = ident_it.next() orelse return error.Malformed;
    if (!std.mem.startsWith(u8, ident_line, "identity ")) return error.Malformed;
    const identity = ident_line["identity ".len..];
    const current = try manifest(allocator, bundle, identity);
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, signed_part)) return error.Tampered;
    return .{ .identity = try allocator.dupe(u8, identity), .key_index = key_index };
}

/// Parse a hex-encoded public key file ("<64 hex chars>\n").
pub fn parsePublicKey(text: []const u8) !Ed25519.PublicKey {
    var bytes: [32]u8 = undefined;
    const got = try std.fmt.hexToBytes(&bytes, std.mem.trim(u8, text, " \r\n\t"));
    if (got.len != 32) return error.Malformed;
    return Ed25519.PublicKey.fromBytes(bytes);
}

test "sign and verify" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("App.app/Contents/Bin");
    try tmp.dir.writeFile(.{ .sub_path = "App.app/Contents/Bin/App", .data = "\x7fELF fake" });
    try tmp.dir.writeFile(.{ .sub_path = "App.app/Contents/Info.conf", .data = "id = com.test.App\n" });
    var bundle = try tmp.dir.openDir("App.app", .{ .iterate = true });
    defer bundle.close();

    const kp = Ed25519.KeyPair.generate();
    try sign(a, bundle, "com.test.App", kp);

    const v = try verify(a, bundle, &.{kp.public_key});
    defer a.free(v.identity);
    try std.testing.expectEqualStrings("com.test.App", v.identity);

    const other = Ed25519.KeyPair.generate();
    try std.testing.expectError(error.UntrustedSigner, verify(a, bundle, &.{other.public_key}));

    try bundle.writeFile(.{ .sub_path = "Contents/Bin/App", .data = "\x7fELF evil" });
    try std.testing.expectError(error.Tampered, verify(a, bundle, &.{kp.public_key}));
}
