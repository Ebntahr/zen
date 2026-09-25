const std = @import("std");
const c = @import("../common.zig");
const cp = @import("cp.zig");
const mem = std.mem;

pub const help =
    \\Usage: install [OPTION]... [-T] SOURCE DEST
    \\  or:  install [OPTION]... SOURCE... DIRECTORY
    \\  or:  install [OPTION]... -t DIRECTORY SOURCE...
    \\  or:  install [OPTION]... -d DIRECTORY...
    \\Copy SOURCE to DEST or multiple SOURCE(s) to the existing DIRECTORY,
    \\while setting permission modes and owner/group.
    \\
    \\  -C, --compare       compare content of source and destination files, and
    \\                        if no change to the destination, do not modify it
    \\  -d, --directory     treat all arguments as directory names; create all
    \\                        components of the specified directories
    \\  -D                  create all leading components of DEST except the last,
    \\                        then copy SOURCE to DEST
    \\  -g, --group=GROUP   set group ownership, instead of process' current group
    \\  -m, --mode=MODE     set permission mode (as in chmod), instead of rwxr-xr-x
    \\  -o, --owner=OWNER   set ownership (super-user only)
    \\  -p, --preserve-timestamps  apply access/modification times of SOURCE files
    \\                        to corresponding destination files
    \\  -s, --strip         (ignored)
    \\  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY
    \\  -T, --no-target-directory  treat DEST as a normal file
    \\  -v, --verbose       print the name of each created file or directory
    \\
;

var mode: u32 = 0o755;
var owner: ?u32 = null;
var group: ?u32 = null;
var verbose = false;
var preserve = false;
var make_leading = false;
var compare = false;

fn mkdirP(path: []const u8, final_mode: u32) bool {
    var i: usize = 0;
    while (true) {
        const next = mem.indexOfScalarPos(u8, path, i + 1, '/');
        const prefix = if (next) |n| path[0..n] else path;
        if (prefix.len > 0) {
            const is_final = next == null;
            if (c.sys.mkdir(prefix, if (is_final) final_mode else 0o755)) {
                if (verbose) c.out.print("install: creating directory {f}\n", .{c.q(prefix)}) catch {};
            } else |e| {
                if (e != error.EXIST) {
                    c.warn("cannot create directory {f}: {s}", .{ c.q(prefix), c.strerror(e) });
                    return false;
                }
            }
        }
        i = next orelse break;
    }
    return true;
}

fn sameContent(a: []const u8, b: []const u8) bool {
    const da = c.readFile(a) catch return false;
    const db = c.readFile(b) catch return false;
    return mem.eql(u8, da, db);
}

fn installFile(src: []const u8, dst: []const u8) bool {
    if (make_leading) {
        const d = c.dirname(dst);
        if (!c.eql(d, ".") and !mkdirP(d, 0o755)) return false;
    }
    if (compare and sameContent(src, dst)) return true;
    c.sys.unlink(dst) catch {};
    cp.o = .{ .preserve_time = preserve, .force = true };
    if (!cp.copy(src, dst, true, 0)) return false;
    c.sys.chmod(dst, mode) catch |e| {
        c.warn("cannot change permissions of {f}: {s}", .{ c.q(dst), c.strerror(e) });
        return false;
    };
    if (owner != null or group != null) c.sys.chown(dst, owner, group, false) catch |e| {
        c.warn("cannot change ownership of {f}: {s}", .{ c.q(dst), c.strerror(e) });
        return false;
    };
    if (verbose) c.out.print("{f} -> {f}\n", .{ c.q(src), c.q(dst) }) catch {};
    return true;
}

pub fn main(args: c.Args) !u8 {
    var dirs_mode = false;
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "compare", 'C' }, .{ "directory", 'd' }, .{ "group", 'g' }, .{ "mode", 'm' }, .{ "owner", 'o' },
        .{ "preserve-timestamps", 'p' }, .{ "strip", 's' }, .{ "target-directory", 't' }, .{ "no-target-directory", 'T' },
        .{ "verbose", 'v' }, .{ "backup", 'b' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'C' => compare = true,
            'd' => dirs_mode = true,
            'D' => make_leading = true,
            'g' => {
                const g = p.arg();
                group = if (c.groupByName(g)) |ge| ge.gid else @intCast(c.parseUint(g) orelse c.fatal("invalid group {f}", .{c.q(g)}));
            },
            'm' => {
                const m = p.arg();
                mode = c.parseMode(m, 0o755, false, 0) orelse c.fatal("invalid mode {f}", .{c.q(m)});
            },
            'o' => {
                const u = p.arg();
                owner = if (c.userByName(u)) |ue| ue.uid else @intCast(c.parseUint(u) orelse c.fatal("invalid user {f}", .{c.q(u)}));
            },
            'p' => preserve = true,
            's', 'b', 'c' => {},
            't' => target_dir = p.arg(),
            'T' => no_target = true,
            'v' => verbose = true,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (dirs_mode) {
        if (files.items.len == 0) c.usageErr("missing file operand", .{});
        var status: u8 = 0;
        for (files.items) |d| {
            if (!mkdirP(d, mode)) status = 1 else {
                c.sys.chmod(d, mode) catch {};
                if (owner != null or group != null) c.sys.chown(d, owner, group, false) catch {};
            }
        }
        return status;
    }
    if (files.items.len == 0) c.usageErr("missing file operand", .{});
    var dest_dir = target_dir;
    var srcs = files.items;
    if (dest_dir == null) {
        if (files.items.len == 1) c.usageErr("missing destination file operand after {f}", .{c.q(files.items[0])});
        const last = files.items[files.items.len - 1];
        const st: ?c.Stat = c.sys.stat(last) catch null;
        if (!no_target and st != null and st.?.isDir()) {
            dest_dir = last;
            srcs = files.items[0 .. files.items.len - 1];
        } else if (files.items.len > 2) {
            c.fatal("target {f} is not a directory", .{c.q(last)});
        }
    } else if (make_leading) {
        if (!mkdirP(dest_dir.?, 0o755)) return 1;
    }
    var status: u8 = 0;
    if (dest_dir) |dd| {
        for (srcs) |s| if (!installFile(s, c.join(dd, c.basename(s)))) {
            status = 1;
        };
    } else if (!installFile(files.items[0], files.items[1])) status = 1;
    return status;
}
