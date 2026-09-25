const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: rm [OPTION]... [FILE]...
    \\Remove (unlink) the FILE(s).
    \\
    \\  -f, --force           ignore nonexistent files and arguments, never prompt
    \\  -i                    prompt before every removal
    \\  -I                    prompt once before removing more than three files, or
    \\                          when removing recursively
    \\  -r, -R, --recursive   remove directories and their contents recursively
    \\  -d, --dir             remove empty directories
    \\  -v, --verbose         explain what is being done
    \\      --no-preserve-root  do not treat '/' specially
    \\      --preserve-root   do not remove '/' (default)
    \\      --one-file-system  stay on the file system of each argument
    \\
;

var force = false;
var interactive = false;
var recursive = false;
var dir_ok = false;
var verbose = false;
var preserve_root = true;
var one_fs = false;
var stdin_tty = false;

fn typeName(st: c.Stat) []const u8 {
    return switch (st.mode & c.S_IFMT) {
        c.S_IFDIR => "directory",
        c.S_IFLNK => "symbolic link",
        c.S_IFIFO => "fifo",
        c.S_IFSOCK => "socket",
        c.S_IFCHR => "character special file",
        c.S_IFBLK => "block special file",
        else => if (st.size == 0) "regular empty file" else "regular file",
    };
}

fn prompt(comptime fmt: []const u8, args: anytype) bool {
    c.eprint("{s}: ", .{c.prog});
    c.eprint(fmt, args);
    return c.yesno();
}

fn writeProtected(path: []const u8, st: c.Stat) bool {
    if (st.isLnk()) return false;
    c.sys.access(path, 2) catch return true;
    return false;
}

fn removeOne(path: []const u8, root_dev: u64) bool {
    const st = c.sys.lstat(path) catch |e| {
        if (force and e == error.NOENT) return true;
        c.warn("cannot remove {f}: {s}", .{ c.q(path), c.strerror(e) });
        return false;
    };
    if (st.isDir()) {
        if (!recursive) {
            if (dir_ok) {
                if (interactive and !prompt("remove directory {f}? ", .{c.q(path)})) return true;
                c.sys.rmdir(path) catch |e| {
                    c.warn("cannot remove {f}: {s}", .{ c.q(path), c.strerror(e) });
                    return false;
                };
                if (verbose) c.out.print("removed directory {f}\n", .{c.q(path)}) catch {};
                return true;
            }
            c.warn("cannot remove {f}: Is a directory", .{c.q(path)});
            return false;
        }
        if (one_fs and root_dev != 0 and st.dev != root_dev) {
            c.warn("skipping {f}, since it's on a different device", .{c.q(path)});
            return false;
        }
        const names = c.readDirNames(path) catch |e| {
            // maybe it's empty & unreadable: try rmdir anyway
            if (c.sys.rmdir(path)) {
                if (verbose) c.out.print("removed directory {f}\n", .{c.q(path)}) catch {};
                return true;
            } else |_| {}
            c.warn("cannot remove {f}: {s}", .{ c.q(path), c.strerror(e) });
            return false;
        };
        defer c.freeNames(names);
        if (interactive and names.len > 0 and !prompt("descend into directory {f}? ", .{c.q(path)})) return true;
        var ok = true;
        for (names) |n| {
            const full = c.join(path, n);
            defer c.gpa.free(full);
            if (!removeOne(full, root_dev)) ok = false;
        }
        if (!ok) return false;
        if (interactive and !prompt("remove directory {f}? ", .{c.q(path)})) return true;
        c.sys.rmdir(path) catch |e| {
            c.warn("cannot remove {f}: {s}", .{ c.q(path), c.strerror(e) });
            return false;
        };
        if (verbose) c.out.print("removed directory {f}\n", .{c.q(path)}) catch {};
        return true;
    }
    if (interactive) {
        if (!prompt("remove {s} {f}? ", .{ typeName(st), c.q(path) })) return true;
    } else if (!force and stdin_tty and writeProtected(path, st)) {
        if (!prompt("remove write-protected {s} {f}? ", .{ typeName(st), c.q(path) })) return true;
    }
    c.sys.unlink(path) catch |e| {
        c.warn("cannot remove {f}: {s}", .{ c.q(path), c.strerror(e) });
        return false;
    };
    if (verbose) c.out.print("removed {f}\n", .{c.q(path)}) catch {};
    return true;
}

pub fn main(args: c.Args) !u8 {
    var once = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "force", 'f' },           .{ "interactive", 0 }, .{ "recursive", 'r' }, .{ "dir", 'd' },
        .{ "verbose", 'v' },         .{ "no-preserve-root", 0 }, .{ "preserve-root", 0 },
        .{ "one-file-system", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'f' => {
                force = true;
                interactive = false;
                once = false;
            },
            'i' => {
                interactive = true;
                force = false;
            },
            'I' => {
                once = true;
                interactive = false;
                force = false;
            },
            'r', 'R' => recursive = true,
            'd' => dir_ok = true,
            'v' => verbose = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "interactive")) {
                const v = p.optArg() orelse "always";
                if (c.eql(v, "never") or c.eql(v, "no") or c.eql(v, "none")) {
                    interactive = false;
                } else if (c.eql(v, "once")) once = true else interactive = true;
            } else if (c.eql(n, "no-preserve-root")) preserve_root = false else if (c.eql(n, "preserve-root")) preserve_root = true else if (c.eql(n, "one-file-system")) one_fs = true else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len == 0) {
        if (force) return 0;
        c.missingOperand();
    }
    stdin_tty = c.isatty(0);
    if (once and (recursive or files.items.len > 3)) {
        const ok = if (recursive)
            prompt("remove {d} argument{s} recursively? ", .{ files.items.len, if (files.items.len == 1) "" else "s" })
        else
            prompt("remove {d} arguments? ", .{files.items.len});
        if (!ok) return 0;
    }
    var status: u8 = 0;
    for (files.items) |f| {
        const base = c.basename(f);
        if (recursive and (c.eql(base, ".") or c.eql(base, ".."))) {
            c.warn("refusing to remove '.' or '..' directory: skipping {f}", .{c.q(f)});
            status = 1;
            continue;
        }
        if (recursive and preserve_root) {
            if (c.canonicalize(f, .all_exist, true)) |rp| {
                if (c.eql(rp, "/")) {
                    c.warn("it is dangerous to operate recursively on {f}", .{c.q(f)});
                    c.warn("use --no-preserve-root to override this failsafe", .{});
                    status = 1;
                    continue;
                }
            } else |_| {}
        }
        var root_dev: u64 = 0;
        if (one_fs) if (c.sys.lstat(f)) |st| {
            root_dev = st.dev;
        } else |_| {};
        if (!removeOne(f, root_dev)) status = 1;
    }
    return status;
}
