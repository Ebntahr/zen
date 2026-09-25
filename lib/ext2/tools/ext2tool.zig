//! ext2tool: create and manipulate ext2 disk images on the host.
//!
//! Timestamps come from $SOURCE_DATE_EPOCH when set (reproducible images),
//! otherwise from the host clock.
const std = @import("std");
const builtin = @import("builtin");
const ext2 = @import("ext2");
const host = @import("ext2_host");

const Fs = ext2.Fs;
const Ino = ext2.Ino;
const ROOT = ext2.ROOT_INO;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: ext2tool <command> [args]
    \\
    \\  mkfs <img> <size-MiB> [label] [-b 1024|2048|4096] [-I 128|256]
    \\       [-N inodes] [-i bytes-per-inode] [-m reserved%] [--seed N]
    \\  ls [-l] <img> <path>
    \\  cat <img> <path>
    \\  put [--owner uid:gid] <img> <hostfile> <path> [mode]
    \\  get <img> <path> <hostfile>
    \\  mkdir [-p] <img> <path> [mode]
    \\  rm [-r] <img> <path>
    \\  mv <img> <old-path> <new-path>
    \\  ln [-s] <img> <target> <link-path>
    \\  chmod <img> <mode> <path>
    \\  chown <img> <uid>[:<gid>] <path>
    \\  stat <img> <path>
    \\  df <img>
    \\  fsck <img>                         (built-in consistency check)
    \\  import <img> <host-dir> <fs-path> [--owner uid:gid] [--manifest file]
    \\
    \\Manifest lines: "<path> <octal-mode|-> <uid|-> <gid|->" ('#' comments);
    \\relative paths are relative to <fs-path>.
    \\
;

var fixed_time: ?i64 = null;

fn clock() i64 {
    return fixed_time orelse std.time.timestamp();
}

var stdout_buf: [64 * 1024]u8 = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var out: *std.Io.Writer = undefined;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    out.flush() catch {};
    std.debug.print("ext2tool: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Set once an image is mounted, to explain NoSpace errors.
var current_fs: ?*Fs = null;

fn failErr(what: []const u8, path: []const u8, err: anyerror) noreturn {
    if (err == error.NoSpace) {
        if (current_fs) |fs| {
            const s = fs.statfs();
            if (s.free_inodes == 0) fail("{s}: {s}: out of inodes ({d} total; use mkfs -N or -i)", .{ what, path, s.total_inodes });
            fail("{s}: {s}: out of space ({d} blocks free)", .{ what, path, s.free_blocks });
        }
    }
    fail("{s}: {s}: {s}", .{ what, path, @errorName(err) });
}

const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    fn has(self: *const Args, f: []const u8) bool {
        return self.flags.contains(f);
    }
    fn get(self: *const Args, f: []const u8) ?[]const u8 {
        return if (self.flags.get(f)) |v| v else null;
    }
};

/// Split argv into positional args and flags. `valued` lists flags that take
/// a value.
fn parseArgs(a: Allocator, argv: []const []const u8, valued: []const []const u8) !Args {
    var r: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        if (s.len > 1 and s[0] == '-' and !std.ascii.isDigit(s[1])) {
            var takes = false;
            for (valued) |v| {
                if (std.mem.eql(u8, v, s)) takes = true;
            }
            if (takes) {
                if (i + 1 >= argv.len) fail("option {s} needs a value", .{s});
                try r.flags.put(a, s, argv[i + 1]);
                i += 1;
            } else {
                try r.flags.put(a, s, null);
            }
        } else try r.pos.append(a, s);
    }
    return r;
}

fn need(args: *const Args, n: usize, max: usize) void {
    if (args.pos.items.len < n or args.pos.items.len > max) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
}

fn parseOctal(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 8) catch fail("bad mode '{s}'", .{s});
}

fn parseU32(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch fail("bad number '{s}'", .{s});
}

const Owner = struct { uid: u32, gid: u32 };

fn parseOwner(s: []const u8) struct { uid: ?u32, gid: ?u32 } {
    if (std.mem.indexOfScalar(u8, s, ':')) |c| {
        return .{
            .uid = if (c == 0) null else parseU32(s[0..c]),
            .gid = if (c + 1 == s.len) null else parseU32(s[c + 1 ..]),
        };
    }
    return .{ .uid = parseU32(s), .gid = null };
}

const Image = struct {
    dev: host.FileDevice,
    fs: *Fs,

    fn open(a: Allocator, path: []const u8, read_only: bool) *Image {
        const img = a.create(Image) catch fail("out of memory", .{});
        img.dev = host.FileDevice.open(path, read_only) catch |e| failErr("open", path, e);
        img.fs = Fs.mount(a, img.dev.device(), .{
            .read_only = read_only,
            .now = clock,
            .cache_blocks = 16384,
            .inode_cache = 4096,
        }) catch |e| failErr("mount", path, e);
        current_fs = img.fs;
        return img;
    }

    fn close(self: *Image) void {
        current_fs = null;
        self.fs.unmount() catch |e| failErr("unmount", "image", e);
        self.dev.close();
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    out = &stdout_writer.interface;

    if (std.process.getEnvVarOwned(arena, "SOURCE_DATE_EPOCH")) |v| {
        fixed_time = std.fmt.parseInt(i64, v, 10) catch null;
    } else |_| {}

    const argv = try std.process.argsAlloc(arena);
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const cmd = argv[1];
    const rest: []const []const u8 = @ptrCast(argv[2..]);
    const eql = std.mem.eql;

    if (eql(u8, cmd, "mkfs")) {
        try cmdMkfs(gpa, arena, rest);
    } else if (eql(u8, cmd, "ls")) {
        try cmdLs(gpa, arena, rest);
    } else if (eql(u8, cmd, "cat")) {
        try cmdCat(gpa, arena, rest);
    } else if (eql(u8, cmd, "put")) {
        try cmdPut(gpa, arena, rest);
    } else if (eql(u8, cmd, "get")) {
        try cmdGet(gpa, arena, rest);
    } else if (eql(u8, cmd, "mkdir")) {
        try cmdMkdir(gpa, arena, rest);
    } else if (eql(u8, cmd, "rm")) {
        try cmdRm(gpa, arena, rest);
    } else if (eql(u8, cmd, "mv")) {
        try cmdMv(gpa, arena, rest);
    } else if (eql(u8, cmd, "ln")) {
        try cmdLn(gpa, arena, rest);
    } else if (eql(u8, cmd, "chmod")) {
        try cmdChmod(gpa, arena, rest);
    } else if (eql(u8, cmd, "chown")) {
        try cmdChown(gpa, arena, rest);
    } else if (eql(u8, cmd, "stat")) {
        try cmdStat(gpa, arena, rest);
    } else if (eql(u8, cmd, "df")) {
        try cmdDf(gpa, arena, rest);
    } else if (eql(u8, cmd, "fsck")) {
        try cmdFsck(gpa, arena, rest);
    } else if (eql(u8, cmd, "import")) {
        try cmdImport(gpa, arena, rest);
    } else if (eql(u8, cmd, "help") or eql(u8, cmd, "--help") or eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
    } else {
        std.debug.print("unknown command '{s}'\n{s}", .{ cmd, usage });
        std.process.exit(2);
    }
    try out.flush();
}

// ---------------------------------------------------------------------------

fn cmdMkfs(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{ "-b", "-I", "-N", "-i", "-m", "--seed" });
    need(&args, 2, 3);
    const path = args.pos.items[0];
    const mib = std.fmt.parseInt(u64, args.pos.items[1], 10) catch fail("bad size '{s}'", .{args.pos.items[1]});
    if (mib == 0) fail("size must be > 0", .{});
    const label = if (args.pos.items.len > 2) args.pos.items[2] else "";
    if (label.len > 16) fail("label longer than 16 bytes", .{});
    var opts: ext2.MkfsOptions = .{ .label = label, .device_zeroed = true };
    opts.timestamp = @intCast(@max(clock(), 0));
    if (args.get("-b")) |v| opts.block_size = parseU32(v);
    if (args.get("-I")) |v| opts.inode_size = parseU32(v);
    if (args.get("-N")) |v| opts.inodes_count = parseU32(v);
    if (args.get("-i")) |v| opts.inode_ratio = parseU32(v);
    if (args.get("-m")) |v| opts.reserved_percent = @intCast(@min(parseU32(v), 50));
    // Deterministic default seed so identical inputs give identical images.
    opts.uuid_seed = if (args.get("--seed")) |v|
        std.fmt.parseInt(u64, v, 0) catch fail("bad seed '{s}'", .{v})
    else
        std.hash.Wyhash.hash(mib, label);
    var dev = host.FileDevice.create(path, mib * 1024 * 1024) catch |e| failErr("create", path, e);
    defer dev.close();
    ext2.mkfs(gpa, dev.device(), opts) catch |e| failErr("mkfs", path, e);
}

fn resolvePath(fs: *Fs, path: []const u8, follow: bool) Ino {
    return fs.resolve(ROOT, path, follow) catch |e| failErr("lookup", path, e);
}

fn modeString(buf: *[10]u8, mode: u16) []const u8 {
    buf[0] = switch (mode & ext2.S_IFMT) {
        ext2.S_IFDIR => 'd',
        ext2.S_IFLNK => 'l',
        ext2.S_IFCHR => 'c',
        ext2.S_IFBLK => 'b',
        ext2.S_IFIFO => 'p',
        ext2.S_IFSOCK => 's',
        else => '-',
    };
    const rwx = "rwxrwxrwx";
    for (0..9) |k| {
        const bit: u16 = @as(u16, 1) << @intCast(8 - k);
        buf[1 + k] = if (mode & bit != 0) rwx[k] else '-';
    }
    if (mode & 0o4000 != 0) buf[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) buf[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) buf[9] = if (mode & 0o001 != 0) 't' else 'T';
    return buf;
}

fn fmtTime(buf: []u8, t: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(t, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "?";
}

fn printLong(fs: *Fs, ino: Ino, name: []const u8) !void {
    const st = fs.stat(ino) catch |e| failErr("stat", name, e);
    var mb: [10]u8 = undefined;
    var tb: [32]u8 = undefined;
    try out.print("{s} {d:>3} {d:>5} {d:>5} ", .{ modeString(&mb, st.mode), st.nlink, st.uid, st.gid });
    if (st.kind == .char_device or st.kind == .block_device) {
        try out.print("{d:>4},{d:>4} ", .{ st.rdev.major, st.rdev.minor });
    } else {
        try out.print("{d:>9} ", .{st.size});
    }
    try out.print("{s} {s}", .{ fmtTime(&tb, st.mtime), name });
    if (st.kind == .symlink) {
        var lb: [4096]u8 = undefined;
        const target = fs.readlink(ino, &lb) catch |e| failErr("readlink", name, e);
        try out.print(" -> {s}", .{target});
    }
    try out.writeByte('\n');
}

const Ent = struct { name: []const u8, ino: Ino };

fn lessEnt(_: void, a: Ent, b: Ent) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn listDir(fs: *Fs, arena: Allocator, dir: Ino) ![]Ent {
    var list: std.ArrayList(Ent) = .empty;
    var it = try fs.readdir(dir, 0);
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        try list.append(arena, .{ .name = try arena.dupe(u8, e.name), .ino = e.ino });
    }
    std.mem.sort(Ent, list.items, {}, lessEnt);
    return list.items;
}

fn cmdLs(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 1, 2);
    const long = args.has("-l");
    const path = if (args.pos.items.len > 1) args.pos.items[1] else "/";
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const ino = fs.lookupNoFollow(path) catch |e| failErr("ls", path, e);
    const st = fs.stat(ino) catch |e| failErr("stat", path, e);
    const dir = if (st.kind == .symlink and !long) (fs.lookup(path) catch ino) else ino;
    const dst = fs.stat(dir) catch |e| failErr("stat", path, e);
    if (dst.kind != .directory) {
        if (long) try printLong(fs, ino, path) else try out.print("{s}\n", .{path});
        return;
    }
    const ents = listDir(fs, arena, dir) catch |e| failErr("readdir", path, e);
    for (ents) |e| {
        if (long) try printLong(fs, e.ino, e.name) else try out.print("{s}\n", .{e.name});
    }
}

fn cmdCat(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 2, 2);
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const path = args.pos.items[1];
    const ino = resolvePath(img.fs, path, true);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var off: u64 = 0;
    while (true) {
        const n = img.fs.read(ino, off, buf) catch |e| failErr("read", path, e);
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
        off += n;
    }
}

/// Copy a host file into an (existing, regular) inode, replacing its data.
fn copyIn(fs: *Fs, ino: Ino, file: std.fs.File, buf: []u8, name: []const u8) !void {
    fs.truncate(ino, 0) catch |e| failErr("truncate", name, e);
    var off: u64 = 0;
    while (true) {
        const n = file.read(buf) catch |e| failErr("read host file", name, e);
        if (n == 0) break;
        const w = fs.write(ino, off, buf[0..n]) catch |e| failErr("write", name, e);
        if (w != n) failErr("write", name, error.NoSpace);
        off += n;
    }
}

/// Create or replace a regular file `name` in `dir`.
fn createOrReplace(fs: *Fs, dir: Ino, name: []const u8, mode: u16, uid: u32, gid: u32) Ino {
    if (fs.lookupChild(dir, name)) |existing| {
        const st = fs.stat(existing) catch |e| failErr("stat", name, e);
        if (st.kind == .regular and st.nlink == 1) {
            fs.chmod(existing, mode) catch |e| failErr("chmod", name, e);
            fs.chown(existing, uid, gid) catch |e| failErr("chown", name, e);
            return existing;
        }
        if (st.kind == .directory) failErr("create", name, error.IsDir);
        fs.unlink(dir, name) catch |e| failErr("unlink", name, e);
    } else |err| switch (err) {
        error.NotFound => {},
        else => failErr("lookup", name, err),
    }
    return fs.create(dir, name, mode, uid, gid) catch |e| failErr("create", name, e);
}

fn cmdPut(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{"--owner"});
    need(&args, 3, 4);
    const hostpath = args.pos.items[1];
    var path = args.pos.items[2];
    const file = std.fs.cwd().openFile(hostpath, .{}) catch |e| failErr("open", hostpath, e);
    defer file.close();
    const hst = file.stat() catch |e| failErr("stat", hostpath, e);
    const mode: u16 = if (args.pos.items.len > 3) parseOctal(args.pos.items[3]) else @intCast(hst.mode & 0o7777);
    var uid: u32 = 0;
    var gid: u32 = 0;
    if (args.get("--owner")) |o| {
        const ow = parseOwner(o);
        uid = ow.uid orelse 0;
        gid = ow.gid orelse 0;
    }
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    // Putting onto an existing directory places the file inside it.
    if (fs.lookup(path)) |ino| {
        if ((fs.stat(ino) catch |e| failErr("stat", path, e)).kind == .directory)
            path = try std.fs.path.join(arena, &.{ path, std.fs.path.basename(hostpath) });
    } else |_| {}
    const pn = fs.resolveParent(ROOT, path) catch |e| failErr("put", path, e);
    const ino = createOrReplace(fs, pn.dir, pn.name, mode, uid, gid);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    try copyIn(fs, ino, file, buf, path);
}

fn cmdGet(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 3, 3);
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const path = args.pos.items[1];
    const hostpath = args.pos.items[2];
    const ino = resolvePath(img.fs, path, true);
    const st = img.fs.stat(ino) catch |e| failErr("stat", path, e);
    if (st.kind != .regular) failErr("get", path, error.InvalidArgument);
    const file = std.fs.cwd().createFile(hostpath, .{ .mode = st.mode & 0o777 }) catch |e| failErr("create", hostpath, e);
    defer file.close();
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var off: u64 = 0;
    while (true) {
        const n = img.fs.read(ino, off, buf) catch |e| failErr("read", path, e);
        if (n == 0) break;
        file.writeAll(buf[0..n]) catch |e| failErr("write", hostpath, e);
        off += n;
    }
}

/// mkdir -p; returns the inode of the final directory.
fn mkdirP(fs: *Fs, path: []const u8, mode: u16, uid: u32, gid: u32) Ino {
    var cur: Ino = ROOT;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (fs.resolve(cur, comp, true)) |next| {
            const st = fs.stat(next) catch |e| failErr("stat", path, e);
            if (st.kind != .directory) failErr("mkdir", path, error.NotDir);
            cur = next;
        } else |err| switch (err) {
            error.NotFound => cur = fs.mkdir(cur, comp, mode, uid, gid) catch |e| failErr("mkdir", path, e),
            else => failErr("mkdir", path, err),
        }
    }
    return cur;
}

fn cmdMkdir(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 2, 3);
    const mode: u16 = if (args.pos.items.len > 2) parseOctal(args.pos.items[2]) else 0o755;
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const path = args.pos.items[1];
    if (args.has("-p")) {
        _ = mkdirP(img.fs, path, mode, 0, 0);
    } else {
        const pn = img.fs.resolveParent(ROOT, path) catch |e| failErr("mkdir", path, e);
        _ = img.fs.mkdir(pn.dir, pn.name, mode, 0, 0) catch |e| failErr("mkdir", path, e);
    }
}

fn removeTree(fs: *Fs, arena: Allocator, parent: Ino, name: []const u8) !void {
    const ino = fs.lookupChild(parent, name) catch |e| failErr("rm", name, e);
    const st = fs.stat(ino) catch |e| failErr("stat", name, e);
    if (st.kind == .directory) {
        const ents = listDir(fs, arena, ino) catch |e| failErr("readdir", name, e);
        for (ents) |e| try removeTree(fs, arena, ino, e.name);
        fs.rmdir(parent, name) catch |e| failErr("rmdir", name, e);
    } else {
        fs.unlink(parent, name) catch |e| failErr("unlink", name, e);
    }
}

fn cmdRm(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 2, 2);
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const path = args.pos.items[1];
    const pn = fs.resolveParent(ROOT, path) catch |e| failErr("rm", path, e);
    if (args.has("-r") or args.has("-rf") or args.has("-R")) {
        try removeTree(fs, arena, pn.dir, pn.name);
    } else {
        const ino = fs.lookupChild(pn.dir, pn.name) catch |e| failErr("rm", path, e);
        const st = fs.stat(ino) catch |e| failErr("rm", path, e);
        if (st.kind == .directory) {
            fs.rmdir(pn.dir, pn.name) catch |e| failErr("rm", path, e);
        } else {
            fs.unlink(pn.dir, pn.name) catch |e| failErr("rm", path, e);
        }
    }
}

fn cmdMv(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 3, 3);
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const src = args.pos.items[1];
    var dst = args.pos.items[2];
    const sp = fs.resolveParent(ROOT, src) catch |e| failErr("mv", src, e);
    if (fs.lookup(dst)) |ino| {
        const st = fs.stat(ino) catch |e| failErr("stat", dst, e);
        if (st.kind == .directory) dst = try std.fs.path.join(arena, &.{ dst, sp.name });
    } else |_| {}
    const dp = fs.resolveParent(ROOT, dst) catch |e| failErr("mv", dst, e);
    fs.rename(sp.dir, sp.name, dp.dir, dp.name) catch |e| failErr("mv", src, e);
}

fn cmdLn(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 3, 3);
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const target = args.pos.items[1];
    const linkpath = args.pos.items[2];
    const pn = fs.resolveParent(ROOT, linkpath) catch |e| failErr("ln", linkpath, e);
    if (args.has("-s")) {
        _ = fs.symlink(pn.dir, pn.name, target, 0, 0) catch |e| failErr("ln -s", linkpath, e);
    } else {
        const ino = fs.lookupNoFollow(target) catch |e| failErr("ln", target, e);
        fs.link(ino, pn.dir, pn.name) catch |e| failErr("ln", linkpath, e);
    }
}

fn cmdChmod(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 3, 3);
    const mode = parseOctal(args.pos.items[1]);
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const path = args.pos.items[2];
    const ino = resolvePath(img.fs, path, true);
    img.fs.chmod(ino, mode) catch |e| failErr("chmod", path, e);
}

fn cmdChown(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 3, 3);
    const ow = parseOwner(args.pos.items[1]);
    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const path = args.pos.items[2];
    const ino = resolvePath(img.fs, path, false);
    img.fs.chown(ino, ow.uid, ow.gid) catch |e| failErr("chown", path, e);
}

fn cmdStat(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 2, 2);
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const path = args.pos.items[1];
    const ino = resolvePath(fs, path, false);
    const st = fs.stat(ino) catch |e| failErr("stat", path, e);
    var mb: [10]u8 = undefined;
    var tb: [32]u8 = undefined;
    try out.print("  File: {s}\n", .{path});
    try out.print("  Type: {s}\n", .{@tagName(st.kind)});
    try out.print("  Size: {d}  Blocks: {d}  IO Block: {d}\n", .{ st.size, st.blocks, st.blksize });
    try out.print(" Inode: {d}  Links: {d}", .{ st.ino, st.nlink });
    if (st.kind == .char_device or st.kind == .block_device)
        try out.print("  Device: {d},{d}", .{ st.rdev.major, st.rdev.minor });
    try out.writeByte('\n');
    try out.print("  Mode: ({o:0>4}/{s})  Uid: {d}  Gid: {d}\n", .{ st.mode & 0o7777, modeString(&mb, st.mode), st.uid, st.gid });
    try out.print("Access: {s}\n", .{fmtTime(&tb, st.atime)});
    try out.print("Modify: {s}\n", .{fmtTime(&tb, st.mtime)});
    try out.print("Change: {s}\n", .{fmtTime(&tb, st.ctime)});
    if (st.kind == .symlink) {
        var lb: [4096]u8 = undefined;
        try out.print("  Link: {s}\n", .{fs.readlink(ino, &lb) catch |e| failErr("readlink", path, e)});
    }
}

fn cmdDf(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 1, 1);
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const s = img.fs.statfs();
    const label = std.mem.sliceTo(&s.label, 0);
    const u = s.uuid;
    try out.print("label:        {s}\n", .{label});
    try out.print("uuid:         {x}-{x}-{x}-{x}-{x}\n", .{ u[0..4], u[4..6], u[6..8], u[8..10], u[10..16] });
    try out.print("block size:   {d}\n", .{s.block_size});
    try out.print("blocks:       {d} total, {d} used, {d} free, {d} available\n", .{ s.total_blocks, s.total_blocks - s.free_blocks, s.free_blocks, s.avail_blocks });
    try out.print("inodes:       {d} total, {d} used, {d} free\n", .{ s.total_inodes, s.total_inodes - s.free_inodes, s.free_inodes });
    try out.print("size:         {d} KiB, {d} KiB free\n", .{ s.total_blocks * s.block_size / 1024, s.free_blocks * s.block_size / 1024 });
    try out.print("name max:     {d}\n", .{s.name_max});
}

fn cmdFsck(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{});
    need(&args, 1, 1);
    const img = Image.open(gpa, args.pos.items[0], true);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const rep = ext2.check(img.fs, gpa, out) catch |e| failErr("fsck", args.pos.items[0], e);
    try out.print("{d} inodes, {d} directories, {d} blocks used, {d} problems\n", .{ rep.inodes_used, rep.directories, rep.blocks_used, rep.problems });
    if (rep.problems != 0) {
        try out.flush();
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// import
// ---------------------------------------------------------------------------

const HostKey = struct { dev: u64, ino: u64 };

const Importer = struct {
    fs: *Fs,
    arena: Allocator,
    buf: []u8,
    owner: ?Owner,
    links: std.AutoHashMapUnmanaged(HostKey, Ino) = .empty,
    files: u64 = 0,
    bytes: u64 = 0,

    fn ownerOf(self: *Importer, st: std.posix.Stat) Owner {
        return self.owner orelse .{ .uid = st.uid, .gid = st.gid };
    }

    /// atime and mtime both come from the host mtime (host atimes change as
    /// we read the files); with SOURCE_DATE_EPOCH they are clamped to it so
    /// images are reproducible.
    fn setTimes(self: *Importer, ino: Ino, st: std.posix.Stat, name: []const u8) void {
        var t: i64 = st.mtim.sec;
        if (fixed_time) |f| t = @min(t, f);
        self.fs.utimes(ino, t, t) catch |e| failErr("utimes", name, e);
    }

    /// Import the contents of host directory `hdir` into fs directory `dir`.
    /// `fresh` means `dir` was just created, so no name can exist in it yet.
    fn importDir(self: *Importer, hdir: std.fs.Dir, dir: Ino, fs_path: []const u8, fresh: bool) !void {
        const fs = self.fs;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.arena);
        var it = hdir.iterate();
        while (it.next() catch |e| failErr("readdir", fs_path, e)) |e| {
            try names.append(self.arena, try self.arena.dupe(u8, e.name));
        }
        std.sort.pdq([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const full = try std.fs.path.join(self.arena, &.{ fs_path, name });
            const st = std.posix.fstatat(hdir.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch |e| failErr("lstat", full, e);
            const ow = self.ownerOf(st);
            const perm: u16 = @intCast(st.mode & 0o7777);
            const kind = st.mode & std.posix.S.IFMT;
            if (kind == std.posix.S.IFDIR) {
                var sub_fresh = true;
                const sub = blk: {
                    if (fresh) break :blk fs.mkdir(dir, name, perm, ow.uid, ow.gid) catch |e| failErr("mkdir", full, e);
                    if (fs.lookupChild(dir, name)) |existing| {
                        const est = fs.stat(existing) catch |e| failErr("stat", full, e);
                        if (est.kind == .directory) {
                            sub_fresh = false;
                            break :blk existing;
                        }
                        fs.unlink(dir, name) catch |e| failErr("unlink", full, e);
                    } else |err| switch (err) {
                        error.NotFound => {},
                        else => failErr("lookup", full, err),
                    }
                    break :blk fs.mkdir(dir, name, perm, ow.uid, ow.gid) catch |e| failErr("mkdir", full, e);
                };
                var hsub = hdir.openDir(name, .{ .iterate = true }) catch |e| failErr("opendir", full, e);
                defer hsub.close();
                try self.importDir(hsub, sub, full, sub_fresh);
                fs.chmod(sub, perm) catch |e| failErr("chmod", full, e);
                fs.chown(sub, ow.uid, ow.gid) catch |e| failErr("chown", full, e);
                self.setTimes(sub, st, full);
                continue;
            }
            // Replace whatever non-directory is in the way.
            if (!fresh) {
                if (fs.lookupChild(dir, name)) |existing| {
                    const est = fs.stat(existing) catch |e| failErr("stat", full, e);
                    if (est.kind == .directory) failErr("import", full, error.IsDir);
                    fs.unlink(dir, name) catch |e| failErr("unlink", full, e);
                } else |err| switch (err) {
                    error.NotFound => {},
                    else => failErr("lookup", full, err),
                }
            }
            const key: HostKey = .{ .dev = st.dev, .ino = st.ino };
            if (kind != std.posix.S.IFDIR and st.nlink > 1) {
                if (self.links.get(key)) |ino| {
                    fs.link(ino, dir, name) catch |e| failErr("link", full, e);
                    continue;
                }
            }
            var ino: Ino = undefined;
            if (kind == std.posix.S.IFREG) {
                ino = fs.create(dir, name, perm, ow.uid, ow.gid) catch |e| failErr("create", full, e);
                const file = hdir.openFile(name, .{}) catch |e| failErr("open", full, e);
                defer file.close();
                try copyIn(fs, ino, file, self.buf, full);
                self.files += 1;
                self.bytes += @intCast(st.size);
            } else if (kind == std.posix.S.IFLNK) {
                var lb: [4096]u8 = undefined;
                const target = hdir.readLink(name, &lb) catch |e| failErr("readlink", full, e);
                ino = fs.symlink(dir, name, target, ow.uid, ow.gid) catch |e| failErr("symlink", full, e);
            } else {
                const rdev: u64 = st.rdev;
                const dev: ext2.Dev = .{
                    .major = @intCast(((rdev >> 8) & 0xfff) | ((rdev >> 32) & 0xfffff000)),
                    .minor = @intCast((rdev & 0xff) | ((rdev >> 12) & 0xffffff00)),
                };
                const mode: u16 = @intCast(st.mode & 0xFFFF);
                ino = fs.mknod(dir, name, mode, dev, ow.uid, ow.gid) catch |e| failErr("mknod", full, e);
            }
            if (kind != std.posix.S.IFLNK) self.setTimes(ino, st, full);
            if (st.nlink > 1) try self.links.put(self.arena, key, ino);
        }
    }
};

fn applyManifest(fs: *Fs, arena: Allocator, manifest: []const u8, base: []const u8) !void {
    const text = std.fs.cwd().readFileAlloc(arena, manifest, 64 << 20) catch |e| failErr("read", manifest, e);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const p = fields.next().?;
        const mode_s = fields.next() orelse fail("{s}:{d}: expected '<path> <mode> <uid> <gid>'", .{ manifest, lineno });
        const uid_s = fields.next() orelse fail("{s}:{d}: missing uid", .{ manifest, lineno });
        const gid_s = fields.next() orelse fail("{s}:{d}: missing gid", .{ manifest, lineno });
        if (fields.next() != null) fail("{s}:{d}: too many fields", .{ manifest, lineno });
        const path = if (p[0] == '/') p else try std.fs.path.join(arena, &.{ base, p });
        const ino = fs.lookupNoFollow(path) catch |e| failErr("manifest", path, e);
        const st = fs.stat(ino) catch |e| failErr("manifest", path, e);
        if (!std.mem.eql(u8, mode_s, "-")) {
            if (st.kind == .symlink) fail("{s}:{d}: cannot chmod symlink {s}", .{ manifest, lineno, path });
            fs.chmod(ino, parseOctal(mode_s)) catch |e| failErr("chmod", path, e);
        }
        const uid: ?u32 = if (std.mem.eql(u8, uid_s, "-")) null else parseU32(uid_s);
        const gid: ?u32 = if (std.mem.eql(u8, gid_s, "-")) null else parseU32(gid_s);
        if (uid != null or gid != null) fs.chown(ino, uid, gid) catch |e| failErr("chown", path, e);
    }
}

fn cmdImport(gpa: Allocator, arena: Allocator, argv: []const []const u8) !void {
    const args = try parseArgs(arena, argv, &.{ "--owner", "--manifest" });
    need(&args, 3, 3);
    const hostdir = args.pos.items[1];
    const fs_path = args.pos.items[2];
    var owner: ?Owner = null;
    if (args.get("--owner")) |o| {
        const ow = parseOwner(o);
        owner = .{ .uid = ow.uid orelse 0, .gid = ow.gid orelse 0 };
    }
    var hdir = std.fs.cwd().openDir(hostdir, .{ .iterate = true }) catch |e| failErr("opendir", hostdir, e);
    defer hdir.close();
    const hst = std.posix.fstat(hdir.fd) catch |e| failErr("stat", hostdir, e);

    const img = Image.open(gpa, args.pos.items[0], false);
    defer {
        img.close();
        gpa.destroy(img);
    }
    const fs = img.fs;
    const buf = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(buf);
    var imp: Importer = .{ .fs = fs, .arena = arena, .buf = buf, .owner = owner };
    const ow = imp.ownerOf(hst);
    const perm: u16 = @intCast(hst.mode & 0o7777);
    const dest = mkdirP(fs, fs_path, perm, ow.uid, ow.gid);
    const base = if (fs_path.len == 0) "/" else fs_path;
    try imp.importDir(hdir, dest, base, false);
    fs.chmod(dest, perm) catch |e| failErr("chmod", base, e);
    fs.chown(dest, ow.uid, ow.gid) catch |e| failErr("chown", base, e);
    imp.setTimes(dest, hst, base);
    if (args.get("--manifest")) |m| try applyManifest(fs, arena, m, base);
}
