const std = @import("std");
const c = @import("../common.zig");
const cp = @import("cp.zig");
const rm = @import("rm.zig");
const mem = std.mem;

pub const help =
    \\Usage: mv [OPTION]... [-T] SOURCE DEST
    \\  or:  mv [OPTION]... SOURCE... DIRECTORY
    \\  or:  mv [OPTION]... -t DIRECTORY SOURCE...
    \\Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.
    \\
    \\  -f, --force                  do not prompt before overwriting
    \\  -i, --interactive            prompt before overwrite
    \\  -n, --no-clobber             do not overwrite an existing file
    \\  -t, --target-directory=DIRECTORY  move all SOURCE arguments into DIRECTORY
    \\  -T, --no-target-directory    treat DEST as a normal file
    \\  -u, --update                 move only when the SOURCE file is newer
    \\                                 than the destination file or when the
    \\                                 destination file is missing
    \\  -v, --verbose                explain what is being done
    \\
;

var force = false;
var interactive = false;
var no_clobber = false;
var update = false;
var verbose = false;

fn removeTree(path: []const u8) bool {
    const st = c.sys.lstat(path) catch return false;
    if (st.isDir()) {
        const names = c.readDirNames(path) catch return false;
        defer c.freeNames(names);
        for (names) |n| {
            const full = c.join(path, n);
            defer c.gpa.free(full);
            _ = removeTree(full);
        }
        c.sys.rmdir(path) catch return false;
        return true;
    }
    c.sys.unlink(path) catch return false;
    return true;
}

fn move(src: []const u8, dst: []const u8) bool {
    const st = c.sys.lstat(src) catch |e| {
        c.warn("cannot stat {f}: {s}", .{ c.q(src), c.strerror(e) });
        return false;
    };
    if (c.sys.lstat(dst)) |ds| {
        if (ds.ino == st.ino and ds.dev == st.dev) {
            c.warn("{f} and {f} are the same file", .{ c.q(src), c.q(dst) });
            return false;
        }
        if (ds.isDir() and !st.isDir()) {
            c.warn("cannot overwrite directory {f} with non-directory", .{c.q(dst)});
            return false;
        }
        if (!ds.isDir() and st.isDir()) {
            c.warn("cannot overwrite non-directory {f} with directory {f}", .{ c.q(dst), c.q(src) });
            return false;
        }
        if (no_clobber) return true;
        if (update and c.Ts.cmp(st.mtime, ds.mtime) != .gt) return true;
        if (interactive) {
            c.eprint("{s}: overwrite {f}? ", .{ c.prog, c.q(dst) });
            if (!c.yesno()) return true;
        } else if (!force and c.isatty(0) and !ds.isLnk()) {
            if (c.sys.access(dst, 2)) {} else |_| {
                c.eprint("{s}: replace {f}, overriding mode {o:0>4} ({s})? ", .{ c.prog, c.q(dst), ds.mode & 0o7777, c.modeString(ds.mode)[1..] });
                if (!c.yesno()) return true;
            }
        }
    } else |_| {}
    if (st.isDir()) {
        // moving a directory into itself?
        const rs = c.canonicalize(src, .all_exist, true) catch null;
        const rd = c.canonicalize(dst, .none_exist, true) catch null;
        if (rs != null and rd != null and rd.?.len > rs.?.len and mem.startsWith(u8, rd.?, rs.?) and rd.?[rs.?.len] == '/') {
            c.warn("cannot move {f} to a subdirectory of itself, {f}", .{ c.q(src), c.q(dst) });
            return false;
        }
    }
    c.sys.rename(src, dst) catch |e| {
        if (e != error.XDEV) {
            c.warn("cannot move {f} to {f}: {s}", .{ c.q(src), c.q(dst), c.strerror(e) });
            return false;
        }
        // cross-device: copy then remove
        cp.o = .{ .recursive = true, .deref = .never, .preserve_mode = true, .preserve_owner = true, .preserve_time = true, .force = true, .is_mv = true };
        if (c.sys.lstat(dst)) |ds| {
            if (ds.isDir()) _ = removeTree(dst);
        } else |_| {}
        if (!cp.copy(src, dst, true, 0)) return false;
        if (!removeTree(src)) {
            c.warn("cannot remove {f}", .{c.q(src)});
            return false;
        }
    };
    if (verbose) c.out.print("renamed {f} -> {f}\n", .{ c.q(src), c.q(dst) }) catch {};
    return true;
}

pub fn main(args: c.Args) !u8 {
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "force", 'f' },            .{ "interactive", 'i' }, .{ "no-clobber", 'n' },  .{ "target-directory", 't' },
        .{ "no-target-directory", 'T' }, .{ "update", 'u' },   .{ "verbose", 'v' },     .{ "backup", 'b' },
        .{ "strip-trailing-slashes", 0 },
    });
    while (p.next()) |opt| switch (opt) {
        .short => |ch| switch (ch) {
            'f' => {
                force = true;
                interactive = false;
                no_clobber = false;
            },
            'i' => {
                interactive = true;
                force = false;
                no_clobber = false;
            },
            'n' => {
                no_clobber = true;
                interactive = false;
                force = false;
            },
            't' => target_dir = p.arg(),
            'T' => no_target = true,
            'u' => update = true,
            'v' => verbose = true,
            'b' => {},
            else => p.bad(opt),
        },
        .long => |n| {
            if (!c.eql(n, "strip-trailing-slashes")) p.bad(opt);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    return cp.runCopyLike(files.items, target_dir, no_target, move);
}
