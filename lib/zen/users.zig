//! User and group database (/etc/passwd, /etc/group, /etc/shadow) and
//! password hashing (Argon2id, PHC string format).
//!
//! All paths are relative to `Db.root` so tools and tests can operate on a
//! staging directory; on Zen the root is "/".

const std = @import("std");

pub const User = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
    /// Full name ("GECOS" field).
    gecos: []const u8,
    home: []const u8,
    shell: []const u8,
};

pub const Group = struct {
    name: []const u8,
    gid: u32,
    /// Comma-separated member list, as stored.
    members: []const u8,

    pub fn hasMember(self: Group, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.members, ',');
        while (it.next()) |m| {
            if (std.mem.eql(u8, std.mem.trim(u8, m, " "), name)) return true;
        }
        return false;
    }
};

/// Groups whose members may use sudo and change system settings.
pub const admin_groups = [_][]const u8{ "admin", "wheel", "sudo" };

/// Argon2id parameters: modest because Zen often runs on emulated CPUs.
pub const hash_params = std.crypto.pwhash.argon2.Params{ .t = 2, .m = 4096, .p = 1 };

pub const Error = error{ NotFound, InvalidEntry, AlreadyExists, PasswordMismatch } || std.mem.Allocator.Error;

fn parseUser(line: []const u8) ?User {
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    _ = it.next() orelse return null; // password placeholder
    const uid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const gid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const gecos = it.next() orelse "";
    const home = it.next() orelse "/";
    const shell = it.next() orelse "/bin/sh";
    if (name.len == 0) return null;
    return .{ .name = name, .uid = uid, .gid = gid, .gecos = gecos, .home = home, .shell = shell };
}

fn parseGroup(line: []const u8) ?Group {
    var it = std.mem.splitScalar(u8, line, ':');
    const name = it.next() orelse return null;
    _ = it.next() orelse return null;
    const gid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const members = it.next() orelse "";
    if (name.len == 0) return null;
    return .{ .name = name, .gid = gid, .members = members };
}

/// Loaded copy of the database. Strings point into the owned file buffers.
pub const Db = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    passwd_data: []u8,
    group_data: []u8,
    users: std.ArrayList(User) = .empty,
    groups: std.ArrayList(Group) = .empty,

    pub fn load(allocator: std.mem.Allocator, root: []const u8) !Db {
        var db = Db{
            .allocator = allocator,
            .root = root,
            .passwd_data = try readFile(allocator, root, "etc/passwd"),
            .group_data = try readFile(allocator, root, "etc/group"),
        };
        errdefer db.deinit();
        var lines = std.mem.splitScalar(u8, db.passwd_data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            if (parseUser(l)) |u| try db.users.append(allocator, u);
        }
        lines = std.mem.splitScalar(u8, db.group_data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            if (parseGroup(l)) |g| try db.groups.append(allocator, g);
        }
        return db;
    }

    pub fn deinit(self: *Db) void {
        self.users.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.allocator.free(self.passwd_data);
        self.allocator.free(self.group_data);
    }

    pub fn userByName(self: *const Db, name: []const u8) ?User {
        for (self.users.items) |u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }

    pub fn userById(self: *const Db, uid: u32) ?User {
        for (self.users.items) |u| if (u.uid == uid) return u;
        return null;
    }

    pub fn groupByName(self: *const Db, name: []const u8) ?Group {
        for (self.groups.items) |g| if (std.mem.eql(u8, g.name, name)) return g;
        return null;
    }

    pub fn groupById(self: *const Db, gid: u32) ?Group {
        for (self.groups.items) |g| if (g.gid == gid) return g;
        return null;
    }

    /// Primary plus supplementary group ids of a user.
    pub fn groupsOf(self: *const Db, allocator: std.mem.Allocator, user: User) ![]u32 {
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);
        try list.append(allocator, user.gid);
        for (self.groups.items) |g| {
            if (g.gid != user.gid and g.hasMember(user.name)) try list.append(allocator, g.gid);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn isAdmin(self: *const Db, user: User) bool {
        if (user.uid == 0) return true;
        for (admin_groups) |name| {
            if (self.groupByName(name)) |g| {
                if (g.gid == user.gid or g.hasMember(user.name)) return true;
            }
        }
        return false;
    }

    /// Regular (human) accounts, uid >= 500, for the login window.
    pub fn humanUsers(self: *const Db, allocator: std.mem.Allocator) ![]User {
        var list: std.ArrayList(User) = .empty;
        for (self.users.items) |u| {
            if (u.uid >= 500 and u.uid < 60000) try list.append(allocator, u);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn nextUid(self: *const Db) u32 {
        var uid: u32 = 501;
        for (self.users.items) |u| {
            if (u.uid >= uid and u.uid < 60000) uid = u.uid + 1;
        }
        return uid;
    }

    /// Verify a password against /etc/shadow.
    pub fn checkPassword(self: *const Db, name: []const u8, password: []const u8) !bool {
        const hash = try shadowHash(self.allocator, self.root, name) orelse return false;
        defer self.allocator.free(hash);
        return verifyPassword(self.allocator, hash, password);
    }

    /// Replace a user's password hash in /etc/shadow.
    pub fn setPassword(self: *const Db, name: []const u8, password: []const u8) !void {
        const hash = try hashPassword(self.allocator, password);
        defer self.allocator.free(hash);
        try updateShadow(self.allocator, self.root, name, hash);
    }

    pub const NewUser = struct {
        name: []const u8,
        full_name: []const u8,
        password: []const u8,
        admin: bool = false,
        shell: []const u8 = "/bin/zensh",
        home_base: []const u8 = "/Users",
    };

    /// Append passwd/group/shadow entries for a new account (the caller
    /// creates the home directory). Returns the new uid.
    pub fn addUser(self: *const Db, u: NewUser) !u32 {
        if (!validName(u.name)) return error.InvalidEntry;
        if (self.userByName(u.name) != null or self.groupByName(u.name) != null) return error.AlreadyExists;
        const uid = self.nextUid();
        const a = self.allocator;
        const pw_line = try std.fmt.allocPrint(a, "{s}:x:{d}:{d}:{s}:{s}/{s}:{s}\n", .{ u.name, uid, uid, u.full_name, u.home_base, u.name, u.shell });
        defer a.free(pw_line);
        try appendFile(a, self.root, "etc/passwd", pw_line);
        const gr_line = try std.fmt.allocPrint(a, "{s}:x:{d}:\n", .{ u.name, uid });
        defer a.free(gr_line);
        try appendFile(a, self.root, "etc/group", gr_line);
        const hash = try hashPassword(a, u.password);
        defer a.free(hash);
        const sh_line = try std.fmt.allocPrint(a, "{s}:{s}:19000:0:99999:7:::\n", .{ u.name, hash });
        defer a.free(sh_line);
        try appendFile(a, self.root, "etc/shadow", sh_line);
        if (u.admin) try addToGroup(a, self.root, "admin", u.name);
        return uid;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!std.ascii.isLower(name[0]) and name[0] != '_') return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn joinRoot(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ if (root.len == 0) "/" else root, rel });
}

fn readFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    const path = try joinRoot(allocator, root, rel);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 4 << 20) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, ""),
        else => err,
    };
}

fn writeFileAtomic(allocator: std.mem.Allocator, root: []const u8, rel: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    const path = try joinRoot(allocator, root, rel);
    defer allocator.free(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .mode = mode, .truncate = true });
        defer f.close();
        try f.writeAll(data);
        f.sync() catch {};
    }
    try std.fs.cwd().rename(tmp, path);
}

fn appendFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8, line: []const u8) !void {
    const old = try readFile(allocator, root, rel);
    defer allocator.free(old);
    const needs_nl = old.len > 0 and old[old.len - 1] != '\n';
    const data = try std.mem.concat(allocator, u8, &.{ old, if (needs_nl) "\n" else "", line });
    defer allocator.free(data);
    const mode: std.fs.File.Mode = if (std.mem.endsWith(u8, rel, "shadow")) 0o600 else 0o644;
    try writeFileAtomic(allocator, root, rel, data, mode);
}

fn addToGroup(allocator: std.mem.Allocator, root: []const u8, group: []const u8, user: []const u8) !void {
    const old = try readFile(allocator, root, "etc/group");
    defer allocator.free(old);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, old, '\n');
    var found = false;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        if (parseGroup(l)) |g| {
            if (std.mem.eql(u8, g.name, group)) {
                found = true;
                if (!g.hasMember(user)) {
                    try out.appendSlice(allocator, l);
                    if (g.members.len > 0) try out.append(allocator, ',');
                    try out.appendSlice(allocator, user);
                    try out.append(allocator, '\n');
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, l);
        try out.append(allocator, '\n');
    }
    if (!found) return error.NotFound;
    try writeFileAtomic(allocator, root, "etc/group", out.items, 0o644);
}

/// Return the stored hash for `name` (caller frees) or null.
pub fn shadowHash(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !?[]u8 {
    const data = try readFile(allocator, root, "etc/shadow");
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        var it = std.mem.splitScalar(u8, l, ':');
        const n = it.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        const h = it.next() orelse return null;
        return try allocator.dupe(u8, h);
    }
    return null;
}

fn updateShadow(allocator: std.mem.Allocator, root: []const u8, name: []const u8, hash: []const u8) !void {
    const data = try readFile(allocator, root, "etc/shadow");
    defer allocator.free(data);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var found = false;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.mem.eql(u8, l[0..colon], name)) {
            found = true;
            var rest = l[colon + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |c2| rest = rest[c2..] else rest = "";
            try out.appendSlice(allocator, name);
            try out.append(allocator, ':');
            try out.appendSlice(allocator, hash);
            try out.appendSlice(allocator, rest);
        } else {
            try out.appendSlice(allocator, l);
        }
        try out.append(allocator, '\n');
    }
    if (!found) {
        try out.appendSlice(allocator, name);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, hash);
        try out.appendSlice(allocator, ":19000:0:99999:7:::\n");
    }
    try writeFileAtomic(allocator, root, "etc/shadow", out.items, 0o600);
}

/// Hash a password with Argon2id; returns a PHC string (caller frees).
pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [128]u8 = undefined;
    const s = try std.crypto.pwhash.argon2.strHash(password, .{
        .allocator = allocator,
        .params = hash_params,
        .mode = .argon2id,
    }, &buf);
    return allocator.dupe(u8, s);
}

/// Constant-time verification of a password against a stored hash.
/// Locked accounts ("!" or "*" prefix) and empty hashes never verify.
pub fn verifyPassword(allocator: std.mem.Allocator, stored: []const u8, password: []const u8) bool {
    if (stored.len == 0 or stored[0] == '!' or stored[0] == '*') return false;
    if (std.mem.startsWith(u8, stored, "$argon2")) {
        std.crypto.pwhash.argon2.strVerify(stored, password, .{ .allocator = allocator }) catch return false;
        return true;
    }
    if (std.mem.startsWith(u8, stored, "$2")) {
        std.crypto.pwhash.bcrypt.strVerify(stored, password, .{ .silently_truncate_password = false }) catch return false;
        return true;
    }
    return false;
}

test "parse and query" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("etc");
    try tmp.dir.writeFile(.{ .sub_path = "etc/passwd", .data = "root:x:0:0:System Administrator:/var/root:/bin/zensh\nzen:x:501:501:Zen User:/Users/zen:/bin/zensh\n" });
    try tmp.dir.writeFile(.{ .sub_path = "etc/group", .data = "wheel:x:0:root\nadmin:x:80:zen\nzen:x:501:\n" });
    try tmp.dir.writeFile(.{ .sub_path = "etc/shadow", .data = "root:!:19000::::::\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var db = try Db.load(a, root);
    defer db.deinit();
    const zen = db.userByName("zen").?;
    try std.testing.expectEqual(@as(u32, 501), zen.uid);
    try std.testing.expect(db.isAdmin(zen));
    const gs = try db.groupsOf(a, zen);
    defer a.free(gs);
    try std.testing.expectEqualSlices(u32, &.{ 501, 80 }, gs);
    try std.testing.expect(!try db.checkPassword("root", "anything"));

    try db.setPassword("zen", "secret");
    try std.testing.expect(try db.checkPassword("zen", "secret"));
    try std.testing.expect(!try db.checkPassword("zen", "wrong"));

    const uid = try db.addUser(.{ .name = "alice", .full_name = "Alice", .password = "pw", .admin = false });
    try std.testing.expectEqual(@as(u32, 502), uid);
    var db2 = try Db.load(a, root);
    defer db2.deinit();
    try std.testing.expect(db2.userByName("alice") != null);
    try std.testing.expect(try db2.checkPassword("alice", "pw"));
    try std.testing.expect(!db2.isAdmin(db2.userByName("alice").?));
}

test "valid names" {
    try std.testing.expect(validName("zen"));
    try std.testing.expect(!validName("Zen"));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName(""));
}
