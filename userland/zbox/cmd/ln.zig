const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: ln [OPTION]... [-T] TARGET LINK_NAME
    \\  or:  ln [OPTION]... TARGET
    \\  or:  ln [OPTION]... TARGET... DIRECTORY
    \\  or:  ln [OPTION]... -t DIRECTORY TARGET...
    \\Create hard links by default, symbolic links with --symbolic.
    \\
    \\  -f, --force                 remove existing destination files
    \\  -i, --interactive           prompt whether to remove destinations
    \\  -L, --logical               dereference TARGETs that are symbolic links
    \\  -n, --no-dereference        treat LINK_NAME as a normal file if
    \\                                it is a symbolic link to a directory
    \\  -P, --physical              make hard links directly to symbolic links
    \\  -r, --relative              with -s, create links relative to link location
    \\  -s, --symbolic              make symbolic links instead of hard links
    \\  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create
    \\                                the links
    \\  -T, --no-target-directory   treat LINK_NAME as a normal file always
    \\  -v, --verbose               print name of each linked file
    \\
;

var symbolic = false;
var force = false;
var interactive = false;
var verbose = false;
var relative = false;
var logical = false;

fn relPath(target: []const u8, link: []const u8) []const u8 {
    const t = c.canonicalize(target, .none_exist, true) catch return target;
    const ld = c.canonicalize(c.dirname(link), .none_exist, true) catch return target;
    // common prefix by components
    var ti = mem.tokenizeScalar(u8, t, '/');
    var li = mem.tokenizeScalar(u8, ld, '/');
    var tcomps: std.ArrayList([]const u8) = .empty;
    var lcomps: std.ArrayList([]const u8) = .empty;
    while (ti.next()) |x| tcomps.append(c.gpa, x) catch c.oom();
    while (li.next()) |x| lcomps.append(c.gpa, x) catch c.oom();
    var k: usize = 0;
    while (k < tcomps.items.len and k < lcomps.items.len and c.eql(tcomps.items[k], lcomps.items[k])) k += 1;
    var out: std.ArrayList(u8) = .empty;
    var i = k;
    while (i < lcomps.items.len) : (i += 1) {
        if (out.items.len > 0) out.append(c.gpa, '/') catch c.oom();
        out.appendSlice(c.gpa, "..") catch c.oom();
    }
    for (tcomps.items[k..]) |comp| {
        if (out.items.len > 0) out.append(c.gpa, '/') catch c.oom();
        out.appendSlice(c.gpa, comp) catch c.oom();
    }
    if (out.items.len == 0) return ".";
    return out.items;
}

fn makeLink(target: []const u8, link: []const u8) bool {
    if (c.sys.lstat(link)) |ls| {
        if (!symbolic) {
            if (c.sys.stat(target)) |ts| {
                if (ts.ino == ls.ino and ts.dev == ls.dev) {
                    c.warn("{f} and {f} are the same file", .{ c.q(target), c.q(link) });
                    return false;
                }
            } else |_| {}
        }
        if (interactive) {
            c.eprint("{s}: replace {f}? ", .{ c.prog, c.q(link) });
            if (!c.yesno()) return true;
        }
        if (force or interactive) {
            if (ls.isDir()) {
                c.warn("{f}: cannot overwrite directory", .{c.q(link)});
                return false;
            }
            c.sys.unlink(link) catch |e| {
                c.warn("cannot remove {f}: {s}", .{ c.q(link), c.strerror(e) });
                return false;
            };
        }
    } else |_| {}
    const tgt = if (symbolic and relative) relPath(target, link) else target;
    if (symbolic) {
        c.sys.symlink(tgt, link) catch |e| {
            c.warn("failed to create symbolic link {f}: {s}", .{ c.q(link), c.strerror(e) });
            return false;
        };
    } else {
        var real_target = target;
        if (logical) real_target = c.canonicalize(target, .all_exist, true) catch target;
        _ = c.sys.lstat(target) catch |e| {
            c.warn("failed to access {f}: {s}", .{ c.q(target), c.strerror(e) });
            return false;
        };
        c.sys.link(real_target, link) catch |e| {
            switch (e) {
                error.EXIST, error.DQUOT, error.NOSPC, error.ROFS => c.warn("failed to create hard link {f}: {s}", .{ c.q(link), c.strerror(e) }),
                error.MLINK => c.warn("failed to create hard link to {f}: {s}", .{ c.q(target), c.strerror(e) }),
                else => c.warn("failed to create hard link {f} => {f}: {s}", .{ c.q(link), c.q(target), c.strerror(e) }),
            }
            return false;
        };
    }
    if (verbose) {
        if (symbolic) {
            c.out.print("{f} -> {f}\n", .{ c.q(link), c.q(tgt) }) catch {};
        } else c.out.print("{f} => {f}\n", .{ c.q(link), c.q(target) }) catch {};
    }
    return true;
}

pub fn main(args: c.Args) !u8 {
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var no_deref = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "force", 'f' },   .{ "interactive", 'i' }, .{ "logical", 'L' },   .{ "no-dereference", 'n' },
        .{ "physical", 'P' }, .{ "relative", 'r' },   .{ "symbolic", 's' },  .{ "target-directory", 't' },
        .{ "no-target-directory", 'T' }, .{ "verbose", 'v' }, .{ "backup", 'b' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'f' => {
                force = true;
                interactive = false;
            },
            'i' => {
                interactive = true;
                force = false;
            },
            'L' => logical = true,
            'P' => logical = false,
            'n' => no_deref = true,
            'r' => relative = true,
            's' => symbolic = true,
            't' => target_dir = p.arg(),
            'T' => no_target = true,
            'v' => verbose = true,
            'b' => {},
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) c.usageErr("missing file operand", .{});
    var status: u8 = 0;
    var dest_dir: ?[]const u8 = target_dir;
    var targets = files.items;
    if (dest_dir == null) {
        if (files.items.len == 1) {
            dest_dir = ".";
        } else if (!no_target) {
            const last = files.items[files.items.len - 1];
            const st: ?c.Stat = (if (no_deref) c.sys.lstat(last) else c.sys.stat(last)) catch null;
            if (st != null and st.?.isDir()) {
                dest_dir = last;
                targets = files.items[0 .. files.items.len - 1];
            } else if (files.items.len > 2) {
                c.fatal("target {f} is not a directory", .{c.q(last)});
            }
        } else if (files.items.len > 2) c.usageErr("extra operand {f}", .{c.q(files.items[2])});
    }
    if (dest_dir) |dd| {
        for (targets) |t| {
            const link = if (c.eql(dd, ".") and files.items.len == 1) c.basename(t) else c.join(dd, c.basename(t));
            if (!makeLink(t, link)) status = 1;
        }
    } else {
        if (!makeLink(files.items[0], files.items[1])) status = 1;
    }
    return status;
}
