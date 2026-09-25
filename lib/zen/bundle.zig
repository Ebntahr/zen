//! Application bundles (`Name.app`) and their entitlements.
//!
//!   Name.app/Contents/Info.conf          key = value metadata
//!   Name.app/Contents/Entitlements.conf  one entitlement per line
//!   Name.app/Contents/Bin/<executable>
//!   Name.app/Contents/Resources/...
//!   Name.app/Contents/CodeSignature      written by `codesign`
//!
//! Info.conf keys: id, name, version, executable, icon, category,
//! copyright, description.

const std = @import("std");
const abi = @import("abi");
const sandbox = abi.sandbox;

pub const Info = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "1.0",
    executable: []const u8 = "",
    icon: []const u8 = "",
    category: []const u8 = "",
    copyright: []const u8 = "",
    description: []const u8 = "",
};

pub const Ent = struct {
    pub const app_sandbox = "com.zen.security.app-sandbox";
    pub const network_client = "com.zen.security.network.client";
    pub const allow_spawn = "com.zen.security.cs.allow-spawn";
    pub const user_selected_rw = "com.zen.security.files.user-selected.read-write";
    pub const user_selected_ro = "com.zen.security.files.user-selected.read-only";
    pub const documents_rw = "com.zen.security.files.documents.read-write";
    pub const documents_ro = "com.zen.security.files.documents.read-only";
    pub const downloads_rw = "com.zen.security.files.downloads.read-write";
    pub const pictures_rw = "com.zen.security.files.pictures.read-write";
    pub const music_rw = "com.zen.security.files.music.read-write";
    pub const movies_rw = "com.zen.security.files.movies.read-write";
    /// Unsandboxed system apps (Terminal, Finder, Settings) that manage the
    /// machine; only honoured for platform-signed bundles.
    pub const system_admin = "com.zen.private.system-admin";
};

/// Human-readable descriptions for Settings › Privacy & Security.
pub fn describe(ent: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ Ent.app_sandbox, "Runs in an App Sandbox container" },
        .{ Ent.network_client, "Outgoing network connections" },
        .{ Ent.allow_spawn, "Can launch helper processes" },
        .{ Ent.user_selected_rw, "Files you choose (read & write)" },
        .{ Ent.user_selected_ro, "Files you choose (read only)" },
        .{ Ent.documents_rw, "Documents folder (read & write)" },
        .{ Ent.documents_ro, "Documents folder (read only)" },
        .{ Ent.downloads_rw, "Downloads folder" },
        .{ Ent.pictures_rw, "Pictures folder" },
        .{ Ent.music_rw, "Music folder" },
        .{ Ent.movies_rw, "Movies folder" },
        .{ Ent.system_admin, "Full system access (platform app)" },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], ent)) return e[1];
    return ent;
}

pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    info: Info,
    entitlements: []const []const u8,

    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
    }

    pub fn has(self: *const Bundle, ent: []const u8) bool {
        for (self.entitlements) |e| if (std.mem.eql(u8, e, ent)) return true;
        return false;
    }

    pub fn sandboxed(self: *const Bundle) bool {
        return self.has(Ent.app_sandbox);
    }

    /// Absolute path of the main executable.
    pub fn executablePath(self: *const Bundle, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.path, "Contents", "Bin", self.info.executable });
    }

    /// Data container of this app for a user's home directory.
    pub fn containerPath(self: *const Bundle, allocator: std.mem.Allocator, home: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ home, "Library", "Containers", self.info.id, "Data" });
    }

    /// Build the kernel sandbox profile for this app and user.
    pub fn sandboxProfile(self: *const Bundle, allocator: std.mem.Allocator, home: []const u8) ![]u8 {
        var b = sandbox.Builder.init(allocator);
        defer b.deinit();
        for ([_][]const u8{ "window", "rand", "null", "zero" }) |s| try b.allowScheme(s);
        if (self.has(Ent.network_client)) {
            b.flags |= sandbox.FLAG_ALLOW_NETWORK;
            for ([_][]const u8{ "tcp", "udp", "dns" }) |s| try b.allowScheme(s);
        }
        if (self.has(Ent.allow_spawn)) b.flags |= sandbox.FLAG_ALLOW_SPAWN;

        // System files needed by every program.
        for ([_][]const u8{ "file:/System", "file:/usr", "file:/bin", "file:/lib" }) |p| try b.allow(p, sandbox.READ | sandbox.EXEC);
        for ([_][]const u8{ "file:/etc/passwd", "file:/etc/group", "file:/etc/hosts", "file:/etc/resolv.conf", "file:/etc/localtime", "file:/etc/zen-release", "file:/etc/hostname" }) |p| try b.allow(p, sandbox.READ);
        try b.allow("sys:proc/self", sandbox.READ);
        try b.allow("sys:uname", sandbox.READ);
        try b.allow("sys:hostname", sandbox.READ);

        // The app's own bundle.
        const own = try std.fmt.allocPrint(allocator, "file:{s}", .{self.path});
        defer allocator.free(own);
        try b.allow(own, sandbox.READ | sandbox.EXEC);

        // User folders granted by entitlements.
        const folders = [_]struct { []const u8, []const u8, u8 }{
            .{ Ent.documents_rw, "Documents", sandbox.READ | sandbox.WRITE },
            .{ Ent.documents_ro, "Documents", sandbox.READ },
            .{ Ent.downloads_rw, "Downloads", sandbox.READ | sandbox.WRITE },
            .{ Ent.pictures_rw, "Pictures", sandbox.READ | sandbox.WRITE },
            .{ Ent.music_rw, "Music", sandbox.READ | sandbox.WRITE },
            .{ Ent.movies_rw, "Movies", sandbox.READ | sandbox.WRITE },
        };
        for (folders) |f| {
            if (!self.has(f[0])) continue;
            const url = try std.fmt.allocPrint(allocator, "file:{s}/{s}", .{ home, f[1] });
            defer allocator.free(url);
            try b.allow(url, f[2]);
        }

        const container = try self.containerPath(allocator, home);
        defer allocator.free(container);
        try b.setContainer(container);
        return b.encode(allocator);
    }
};

fn parseConf(allocator: std.mem.Allocator, data: []const u8) !Info {
    var info = Info{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = try allocator.dupe(u8, std.mem.trim(u8, line[eq + 1 ..], " \t\""));
        inline for (std.meta.fields(Info)) |f| {
            if (std.mem.eql(u8, key, f.name)) @field(info, f.name) = val;
        }
    }
    return info;
}

/// Load a bundle's Info.conf and Entitlements.conf.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Bundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const bundle_path = try a.dupe(u8, std.mem.trimRight(u8, path, "/"));

    const info_path = try std.fs.path.join(a, &.{ bundle_path, "Contents", "Info.conf" });
    const info_data = try std.fs.cwd().readFileAlloc(a, info_path, 64 * 1024);
    var info = try parseConf(a, info_data);
    if (info.name.len == 0) {
        const base = std.fs.path.basename(bundle_path);
        info.name = if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base;
    }
    if (info.executable.len == 0) info.executable = info.name;
    if (info.id.len == 0) info.id = try std.fmt.allocPrint(a, "local.{s}", .{info.name});

    var ents: std.ArrayList([]const u8) = .empty;
    const ent_path = try std.fs.path.join(a, &.{ bundle_path, "Contents", "Entitlements.conf" });
    if (std.fs.cwd().readFileAlloc(a, ent_path, 64 * 1024)) |ent_data| {
        var lines = std.mem.splitScalar(u8, ent_data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try ents.append(a, line);
        }
    } else |_| {}

    return .{ .arena = arena, .path = bundle_path, .info = info, .entitlements = try ents.toOwnedSlice(a) };
}

test "bundle and profile" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("TextEdit.app/Contents/Bin");
    try tmp.dir.writeFile(.{ .sub_path = "TextEdit.app/Contents/Info.conf", .data = "id = com.zen.TextEdit\nname = TextEdit\nexecutable = TextEdit\nversion = 1.2\n" });
    try tmp.dir.writeFile(.{ .sub_path = "TextEdit.app/Contents/Entitlements.conf", .data = "com.zen.security.app-sandbox\ncom.zen.security.files.documents.read-write\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "TextEdit.app" });
    defer a.free(path);

    var b = try load(a, path);
    defer b.deinit();
    try std.testing.expectEqualStrings("com.zen.TextEdit", b.info.id);
    try std.testing.expect(b.sandboxed());

    const bytes = try b.sandboxProfile(a, "/Users/zen");
    defer a.free(bytes);
    const p = try sandbox.Profile.parse(bytes);
    try std.testing.expect(p.check("file", "/Users/zen/Documents/notes.txt", sandbox.WRITE));
    try std.testing.expect(!p.check("file", "/Users/zen/Desktop/secret.txt", sandbox.READ));
    try std.testing.expect(p.check("file", "/Users/zen/Library/Containers/com.zen.TextEdit/Data/Library/prefs", sandbox.WRITE));
    try std.testing.expect(p.check("file", "/usr/bin/ls", sandbox.EXEC));
    try std.testing.expect(!p.check("file", "/usr/bin/ls", sandbox.WRITE));
    try std.testing.expect(!p.check("display", "0", sandbox.READ));
    try std.testing.expect(!p.allowsNetwork());
}
