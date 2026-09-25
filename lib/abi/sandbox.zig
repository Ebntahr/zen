//! App Sandbox profiles.
//!
//! Every app launched from an `.app` bundle that carries the
//! `com.zen.security.app-sandbox` entitlement runs inside a container, in
//! the spirit of the macOS App Sandbox. `launchd` turns the bundle's
//! entitlements into a binary profile and asks the kernel to apply it when
//! spawning the process. The kernel then checks every URL the process (and
//! its children) opens against the profile. Profiles can only ever become
//! stricter: a sandboxed process can not spawn a less restricted child.
//!
//! Binary layout (little endian):
//!   header  : magic u32 "ZSBX", version u16, flags u16,
//!             n_schemes u16, n_rules u16, container_len u16, reserved u16
//!   schemes : n_schemes × { len u8, name[len] }         whole-scheme grants
//!   rules   : n_rules × { access u8, reserved u8, len u16, url[len] }
//!   container: container_len bytes, a `file:` path granted read/write/exec
//!
//! A rule URL is `scheme:path-prefix`; it matches the exact path and
//! anything below it (component-wise), e.g. `file:/usr` matches
//! `file:/usr/bin/ls` but not `file:/usr2`.

const std = @import("std");

pub const MAGIC: u32 = 0x5842535A; // "ZSBX"
pub const VERSION: u16 = 1;

pub const READ: u8 = 1;
pub const WRITE: u8 = 2;
pub const EXEC: u8 = 4;
pub const ALL: u8 = READ | WRITE | EXEC;

/// Profile flags.
pub const FLAG_ALLOW_SPAWN: u16 = 1 << 0;
pub const FLAG_ALLOW_NETWORK: u16 = 1 << 1;
/// Log denials to the kernel log (always on in practice).
pub const FLAG_LOG_DENIALS: u16 = 1 << 2;

pub const Error = error{ InvalidProfile, TooLarge, OutOfMemory };

const HEADER_LEN = 16;

/// Read-only view over an encoded profile. Performs no allocation, so the
/// kernel can use it directly on a copied buffer.
pub const Profile = struct {
    bytes: []const u8,
    flags: u16,
    n_schemes: u16,
    n_rules: u16,
    schemes_off: usize,
    rules_off: usize,
    container: []const u8,

    pub fn parse(bytes: []const u8) Error!Profile {
        if (bytes.len < HEADER_LEN) return error.InvalidProfile;
        if (std.mem.readInt(u32, bytes[0..4], .little) != MAGIC) return error.InvalidProfile;
        if (std.mem.readInt(u16, bytes[4..6], .little) != VERSION) return error.InvalidProfile;
        const flags = std.mem.readInt(u16, bytes[6..8], .little);
        const n_schemes = std.mem.readInt(u16, bytes[8..10], .little);
        const n_rules = std.mem.readInt(u16, bytes[10..12], .little);
        const container_len = std.mem.readInt(u16, bytes[12..14], .little);

        var pos: usize = HEADER_LEN;
        const schemes_off = pos;
        var i: usize = 0;
        while (i < n_schemes) : (i += 1) {
            if (pos >= bytes.len) return error.InvalidProfile;
            pos += 1 + bytes[pos];
            if (pos > bytes.len) return error.InvalidProfile;
        }
        const rules_off = pos;
        i = 0;
        while (i < n_rules) : (i += 1) {
            if (pos + 4 > bytes.len) return error.InvalidProfile;
            const len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .little);
            pos += 4 + len;
            if (pos > bytes.len) return error.InvalidProfile;
        }
        if (pos + container_len > bytes.len) return error.InvalidProfile;
        return .{
            .bytes = bytes,
            .flags = flags,
            .n_schemes = n_schemes,
            .n_rules = n_rules,
            .schemes_off = schemes_off,
            .rules_off = rules_off,
            .container = bytes[pos .. pos + container_len],
        };
    }

    pub fn allowsSpawn(self: Profile) bool {
        return self.flags & FLAG_ALLOW_SPAWN != 0;
    }

    pub fn allowsNetwork(self: Profile) bool {
        return self.flags & FLAG_ALLOW_NETWORK != 0;
    }

    pub const SchemeIterator = struct {
        p: *const Profile,
        pos: usize,
        left: usize,
        pub fn next(it: *SchemeIterator) ?[]const u8 {
            if (it.left == 0) return null;
            it.left -= 1;
            const len = it.p.bytes[it.pos];
            const s = it.p.bytes[it.pos + 1 .. it.pos + 1 + len];
            it.pos += 1 + len;
            return s;
        }
    };

    pub fn schemes(self: *const Profile) SchemeIterator {
        return .{ .p = self, .pos = self.schemes_off, .left = self.n_schemes };
    }

    pub const Rule = struct { access: u8, url: []const u8 };

    pub const RuleIterator = struct {
        p: *const Profile,
        pos: usize,
        left: usize,
        pub fn next(it: *RuleIterator) ?Rule {
            if (it.left == 0) return null;
            it.left -= 1;
            const b = it.p.bytes;
            const access = b[it.pos];
            const len = std.mem.readInt(u16, b[it.pos + 2 ..][0..2], .little);
            const url = b[it.pos + 4 .. it.pos + 4 + len];
            it.pos += 4 + len;
            return .{ .access = access, .url = url };
        }
    };

    pub fn rules(self: *const Profile) RuleIterator {
        return .{ .p = self, .pos = self.rules_off, .left = self.n_rules };
    }

    /// Decide whether `scheme:path` may be accessed with `access` bits.
    /// `path` must already be normalized (no `.`/`..` components).
    pub fn check(self: *const Profile, scheme: []const u8, path: []const u8, access: u8) bool {
        var sit = self.schemes();
        while (sit.next()) |s| {
            if (std.mem.eql(u8, s, scheme)) return true;
        }
        if (std.mem.eql(u8, scheme, "file") and self.container.len > 0) {
            if (pathWithin(path, self.container)) return true;
        }
        var rit = self.rules();
        while (rit.next()) |r| {
            if (r.access & access != access) continue;
            const colon = std.mem.indexOfScalar(u8, r.url, ':') orelse continue;
            if (!std.mem.eql(u8, r.url[0..colon], scheme)) continue;
            if (pathWithin(path, r.url[colon + 1 ..])) return true;
        }
        return false;
    }

    /// True if every permission of `child` is also granted by `self`
    /// (used to stop sandboxed processes from escaping via spawn).
    pub fn contains(self: *const Profile, child: *const Profile) bool {
        if (child.flags & ~self.flags & (FLAG_ALLOW_SPAWN | FLAG_ALLOW_NETWORK) != 0) return false;
        var sit = child.schemes();
        while (sit.next()) |s| {
            var mine = self.schemes();
            var found = false;
            while (mine.next()) |m| {
                if (std.mem.eql(u8, m, s)) found = true;
            }
            if (!found) return false;
        }
        var rit = child.rules();
        while (rit.next()) |r| {
            const colon = std.mem.indexOfScalar(u8, r.url, ':') orelse return false;
            if (!self.check(r.url[0..colon], r.url[colon + 1 ..], r.access)) return false;
        }
        if (child.container.len > 0 and !self.check("file", child.container, ALL)) return false;
        return true;
    }
};

/// `path` equals `prefix` or lies below it on a component boundary.
pub fn pathWithin(path: []const u8, prefix: []const u8) bool {
    var pre = prefix;
    while (pre.len > 1 and pre[pre.len - 1] == '/') pre = pre[0 .. pre.len - 1];
    if (pre.len == 0) return true;
    if (std.mem.eql(u8, pre, "/")) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, pre)) return false;
    return path.len == pre.len or path[pre.len] == '/';
}

/// Incrementally builds an encoded profile.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    flags: u16 = FLAG_LOG_DENIALS,
    schemes: std.ArrayList([]const u8) = .empty,
    rules: std.ArrayList(Profile.Rule) = .empty,
    container: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.schemes.items) |s| self.allocator.free(s);
        for (self.rules.items) |r| self.allocator.free(r.url);
        self.schemes.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        if (self.container.len > 0) self.allocator.free(self.container);
    }

    pub fn allowScheme(self: *Builder, name: []const u8) Error!void {
        if (name.len > 255) return error.TooLarge;
        try self.schemes.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    pub fn allow(self: *Builder, url: []const u8, access: u8) Error!void {
        if (url.len > 0xffff) return error.TooLarge;
        try self.rules.append(self.allocator, .{ .access = access, .url = try self.allocator.dupe(u8, url) });
    }

    pub fn setContainer(self: *Builder, path: []const u8) Error!void {
        if (self.container.len > 0) self.allocator.free(self.container);
        self.container = try self.allocator.dupe(u8, path);
    }

    pub fn encode(self: *const Builder, allocator: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var hdr: [HEADER_LEN]u8 = [_]u8{0} ** HEADER_LEN;
        std.mem.writeInt(u32, hdr[0..4], MAGIC, .little);
        std.mem.writeInt(u16, hdr[4..6], VERSION, .little);
        std.mem.writeInt(u16, hdr[6..8], self.flags, .little);
        std.mem.writeInt(u16, hdr[8..10], @intCast(self.schemes.items.len), .little);
        std.mem.writeInt(u16, hdr[10..12], @intCast(self.rules.items.len), .little);
        std.mem.writeInt(u16, hdr[12..14], @intCast(self.container.len), .little);
        try out.appendSlice(allocator, &hdr);
        for (self.schemes.items) |s| {
            try out.append(allocator, @intCast(s.len));
            try out.appendSlice(allocator, s);
        }
        for (self.rules.items) |r| {
            var rh: [4]u8 = .{ r.access, 0, 0, 0 };
            std.mem.writeInt(u16, rh[2..4], @intCast(r.url.len), .little);
            try out.appendSlice(allocator, &rh);
            try out.appendSlice(allocator, r.url);
        }
        try out.appendSlice(allocator, self.container);
        return out.toOwnedSlice(allocator);
    }
};

test "profile encode/parse/check" {
    const a = std.testing.allocator;
    var b = Builder.init(a);
    defer b.deinit();
    try b.allowScheme("window");
    try b.allowScheme("rand");
    try b.allow("file:/usr", READ | EXEC);
    try b.allow("sys:proc/self", READ);
    try b.setContainer("/Users/zen/Library/Containers/com.zen.TextEdit/Data");
    const bytes = try b.encode(a);
    defer a.free(bytes);

    const p = try Profile.parse(bytes);
    try std.testing.expect(p.check("window", "new", WRITE));
    try std.testing.expect(p.check("file", "/usr/lib/libc.a", READ));
    try std.testing.expect(!p.check("file", "/usr/lib/libc.a", WRITE));
    try std.testing.expect(!p.check("file", "/usr2/x", READ));
    try std.testing.expect(!p.check("file", "/Users/zen/.ssh/id_ed25519", READ));
    try std.testing.expect(p.check("file", "/Users/zen/Library/Containers/com.zen.TextEdit/Data/Documents/a.txt", WRITE));
    try std.testing.expect(!p.check("display", "0", READ));
    try std.testing.expect(p.check("sys", "proc/self/status", READ));
    try std.testing.expect(!p.check("sys", "proc/1/status", READ));
    try std.testing.expect(p.contains(&p));

    var b2 = Builder.init(a);
    defer b2.deinit();
    try b2.allowScheme("display");
    const bytes2 = try b2.encode(a);
    defer a.free(bytes2);
    const p2 = try Profile.parse(bytes2);
    try std.testing.expect(!p.contains(&p2));
}

test "pathWithin" {
    try std.testing.expect(pathWithin("/a/b", "/a"));
    try std.testing.expect(pathWithin("/a", "/a/"));
    try std.testing.expect(!pathWithin("/ab", "/a"));
    try std.testing.expect(pathWithin("/anything", "/"));
}
