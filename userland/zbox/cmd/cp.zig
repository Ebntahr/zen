const std = @import("std");
const c = @import("../common.zig");
const linux = std.os.linux;
const mem = std.mem;

pub const help =
    \\Usage: cp [OPTION]... [-T] SOURCE DEST
    \\  or:  cp [OPTION]... SOURCE... DIRECTORY
    \\  or:  cp [OPTION]... -t DIRECTORY SOURCE...
    \\Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.
    \\
    \\  -a, --archive                same as -dR --preserve=all
    \\  -d                           same as --no-dereference --preserve=links
    \\  -f, --force                  if an existing destination file cannot be
    \\                                 opened, remove it and try again
    \\  -i, --interactive            prompt before overwrite
    \\  -H                           follow command-line symbolic links in SOURCE
    \\  -l, --link                   hard link files instead of copying
    \\  -L, --dereference            always follow symbolic links in SOURCE
    \\  -n, --no-clobber             do not overwrite an existing file
    \\  -P, --no-dereference         never follow symbolic links in SOURCE
    \\  -p                           same as --preserve=mode,ownership,timestamps
    \\      --preserve[=ATTR_LIST]   preserve the specified attributes
    \\      --parents                use full source file name under DIRECTORY
    \\  -R, -r, --recursive          copy directories recursively
    \\      --remove-destination     remove each existing destination file before
    \\                                 attempting to open it
    \\  -s, --symbolic-link          make symbolic links instead of copying
    \\  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY
    \\  -T, --no-target-directory    treat DEST as a normal file
    \\  -u, --update                 copy only when the SOURCE file is newer
    \\  -v, --verbose                explain what is being done
    \\  -x, --one-file-system        stay on this file system
    \\
;

pub const Opts = struct {
    recursive: bool = false,
    force: bool = false,
    interactive: bool = false,
    no_clobber: bool = false,
    verbose: bool = false,
    preserve_mode: bool = false,
    preserve_owner: bool = false,
    preserve_time: bool = false,
    deref: enum { always, never, cmdline, default } = .default,
    hardlink: bool = false,
    symlink: bool = false,
    update: bool = false,
    remove_dest: bool = false,
    one_fs: bool = false,
    parents: bool = false,
    /// used by mv: message prefix differs and errors are phrased differently
    is_mv: bool = false,
};

pub var o: Opts = .{};
var into_self = false;
var skip_ino: ?[2]u64 = null;
var status: u8 = 0;

fn fail(comptime fmt: []const u8, args: anytype) bool {
    c.warn(fmt, args);
    status = 1;
    return false;
}

fn preserveAttrs(dst: []const u8, st: c.Stat, is_link: bool) void {
    if (o.preserve_owner) {
        c.sys.chown(dst, st.uid, st.gid, is_link) catch {
            // try group only
            c.sys.chown(dst, null, st.gid, is_link) catch {};
        };
    }
    if (o.preserve_mode and !is_link) {
        c.sys.chmod(dst, st.mode & 0o7777) catch |e| {
            _ = fail("preserving permissions for {f}: {s}", .{ c.q(dst), c.strerror(e) });
        };
    }
    if (o.preserve_time) {
        const times = [2]linux.timespec{
            .{ .sec = @intCast(st.atime.sec), .nsec = @intCast(st.atime.nsec) },
            .{ .sec = @intCast(st.mtime.sec), .nsec = @intCast(st.mtime.nsec) },
        };
        c.sys.utimens(dst, &times, is_link) catch |e| {
            if (!is_link) _ = fail("preserving times for {f}: {s}", .{ c.q(dst), c.strerror(e) });
        };
    }
}

fn copyData(src: []const u8, dst: []const u8, st: c.Stat, dst_exists: bool) bool {
    const in = c.sys.open(src, c.O_RDONLY, 0) catch |e| return fail("cannot open {f} for reading: {s}", .{ c.q(src), c.strerror(e) });
    defer c.sys.close(in);
    const mode = st.mode & 0o777;
    var out = c.sys.open(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode) catch |e| blk: {
        if (o.force and dst_exists) {
            c.sys.unlink(dst) catch {};
            break :blk c.sys.open(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode) catch |e2| {
                return fail("cannot create regular file {f}: {s}", .{ c.q(dst), c.strerror(e2) });
            };
        }
        if (dst_exists) return fail("cannot open {f} for writing: {s}", .{ c.q(dst), c.strerror(e) });
        return fail("cannot create regular file {f}: {s}", .{ c.q(dst), c.strerror(e) });
    };
    defer c.sys.close(out);
    var buf: [131072]u8 = undefined;
    while (true) {
        const n = c.sys.read(in, &buf) catch |e| return fail("error reading {f}: {s}", .{ c.q(src), c.strerror(e) });
        if (n == 0) break;
        c.sys.writeAll(out, buf[0..n]) catch |e| return fail("error writing {f}: {s}", .{ c.q(dst), c.strerror(e) });
    }
    out = out;
    return true;
}

fn isSubdir(src: []const u8, dst: []const u8) bool {
    const rs = c.canonicalize(src, .all_exist, true) catch return false;
    const rd = c.canonicalize(dst, .none_exist, true) catch return false;
    if (rd.len <= rs.len) return mem.eql(u8, rd, rs);
    return mem.startsWith(u8, rd, rs) and (rd[rs.len] == '/' or c.eql(rs, "/"));
}

/// Copy src to dst (dst is the final path). top = command-line argument.
pub fn copy(src: []const u8, dst: []const u8, top: bool, root_dev: u64) bool {
    const follow = switch (o.deref) {
        .always => true,
        .never => false,
        .cmdline => top,
        .default => !o.recursive,
    };
    const st = (if (follow) c.sys.stat(src) else c.sys.lstat(src)) catch |e| {
        return fail("cannot stat {f}: {s}", .{ c.q(src), c.strerror(e) });
    };
    const dst_st: ?c.Stat = c.sys.lstat(dst) catch null;
    if (dst_st) |ds| {
        const real_ds = if (ds.isLnk()) (c.sys.stat(dst) catch ds) else ds;
        if (real_ds.ino == st.ino and real_ds.dev == st.dev and !o.symlink and !(o.hardlink and !st.isDir())) {
            return fail("{f} and {f} are the same file", .{ c.q(src), c.q(dst) });
        }
        if (!st.isDir()) {
            if (real_ds.isDir()) return fail("cannot overwrite directory {f} with non-directory", .{c.q(dst)});
            if (o.no_clobber) return true;
            if (o.update and c.Ts.cmp(st.mtime, real_ds.mtime) != .gt) return true;
            if (o.interactive) {
                c.eprint("{s}: overwrite {f}? ", .{ c.prog, c.q(dst) });
                if (!c.yesno()) return true;
            }
            if (o.remove_dest or o.symlink or o.hardlink or st.isLnk()) c.sys.unlink(dst) catch {};
        } else if (!real_ds.isDir()) {
            return fail("cannot overwrite non-directory {f} with directory {f}", .{ c.q(dst), c.q(src) });
        }
    }
    if (st.isDir()) {
        if (!o.recursive and !o.is_mv) {
            c.warn("-r not specified; omitting directory {f}", .{c.q(src)});
            status = 1;
            return false;
        }
        if (top and isSubdir(src, dst)) {
            _ = fail("cannot copy a directory, {f}, into itself, {f}", .{ c.q(src), c.q(dst) });
            into_self = true;
        }
        if (skip_ino) |si| if (st.ino == si[0] and st.dev == si[1]) return true;
        if (o.one_fs and root_dev != 0 and st.dev != root_dev) return true;
        var created = false;
        if (dst_st == null) {
            c.sys.mkdir(dst, (st.mode & 0o777) | 0o700) catch |e| return fail("cannot create directory {f}: {s}", .{ c.q(dst), c.strerror(e) });
            created = true;
            if (top and into_self) if (c.sys.stat(dst)) |ds| {
                skip_ino = .{ ds.ino, ds.dev };
            } else |_| {};
        }
        if (o.verbose and !o.is_mv) c.out.print("{f} -> {f}\n", .{ c.q(src), c.q(dst) }) catch {};
        const names = c.readDirNames(src) catch |e| return fail("cannot access {f}: {s}", .{ c.q(src), c.strerror(e) });
        defer c.freeNames(names);
        c.sortStrings(names);
        var ok = true;
        for (names) |n| {
            const s2 = c.join(src, n);
            defer c.gpa.free(s2);
            const d2 = c.join(dst, n);
            defer c.gpa.free(d2);
            if (!copy(s2, d2, false, if (root_dev == 0) st.dev else root_dev)) ok = false;
        }
        if (o.preserve_mode or o.preserve_owner or o.preserve_time) {
            preserveAttrs(dst, st, false);
        } else if (created) {
            const um = c.sys.umask(0);
            _ = c.sys.umask(um);
            c.sys.chmod(dst, st.mode & 0o777 & ~um) catch {};
        }
        if (top and into_self) {
            into_self = false;
            skip_ino = null;
            return false;
        }
        return ok;
    }
    if (o.symlink) {
        c.sys.symlink(src, dst) catch |e| return fail("cannot create symbolic link {f}: {s}", .{ c.q(dst), c.strerror(e) });
    } else if (o.hardlink) {
        c.sys.link(src, dst) catch |e| return fail("cannot create hard link {f} to {f}: {s}", .{ c.q(dst), c.q(src), c.strerror(e) });
    } else switch (st.mode & c.S_IFMT) {
        c.S_IFLNK => {
            var lb: [c.PATH_MAX]u8 = undefined;
            const target = c.sys.readlink(src, &lb) catch |e| return fail("cannot read symbolic link {f}: {s}", .{ c.q(src), c.strerror(e) });
            c.sys.symlink(target, dst) catch |e| return fail("cannot create symbolic link {f}: {s}", .{ c.q(dst), c.strerror(e) });
            if (o.preserve_owner or o.preserve_time) preserveAttrs(dst, st, true);
            if (o.verbose and !o.is_mv) c.out.print("{f} -> {f}\n", .{ c.q(src), c.q(dst) }) catch {};
            return true;
        },
        c.S_IFREG => {
            if (!copyData(src, dst, st, dst_st != null)) return false;
        },
        else => {
            if (o.recursive or o.is_mv) {
                var b: [c.PATH_MAX]u8 = undefined;
                const pz = c.toZ(&b, dst) catch return fail("cannot create {f}: File name too long", .{c.q(dst)});
                const rc = linux.mknodat(c.AT_FDCWD, pz, st.mode, @truncate(st.rdev));
                if (std.posix.errno(rc) != .SUCCESS) {
                    return fail("cannot create special file {f}: {s}", .{ c.q(dst), c.strerror(c.mapErrno(std.posix.errno(rc))) });
                }
            } else if (!copyData(src, dst, st, dst_st != null)) return false;
        },
    }
    if (o.verbose and !o.is_mv) c.out.print("{f} -> {f}\n", .{ c.q(src), c.q(dst) }) catch {};
    if (!o.symlink and !o.hardlink) preserveAttrs(dst, st, false);
    return true;
}

pub fn main(args: c.Args) !u8 {
    var target_dir: ?[]const u8 = null;
    var no_target = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "archive", 'a' },       .{ "force", 'f' },            .{ "interactive", 'i' }, .{ "link", 'l' },
        .{ "dereference", 'L' },   .{ "no-clobber", 'n' },       .{ "no-dereference", 'P' }, .{ "preserve", 0 },
        .{ "no-preserve", 0 },     .{ "parents", 0 },            .{ "recursive", 'R' },   .{ "remove-destination", 0 },
        .{ "symbolic-link", 's' }, .{ "target-directory", 't' }, .{ "no-target-directory", 'T' },
        .{ "update", 'u' },        .{ "verbose", 'v' },          .{ "one-file-system", 'x' }, .{ "backup", 'b' },
        .{ "sparse", 0 },          .{ "reflink", 0 },
    });
    while (p.next()) |opt| switch (opt) {
        .short => |ch| switch (ch) {
            'a' => {
                o.recursive = true;
                o.deref = .never;
                o.preserve_mode = true;
                o.preserve_owner = true;
                o.preserve_time = true;
            },
            'd' => o.deref = .never,
            'f' => o.force = true,
            'i' => {
                o.interactive = true;
                o.no_clobber = false;
            },
            'H' => o.deref = .cmdline,
            'l' => o.hardlink = true,
            'L' => o.deref = .always,
            'n' => {
                o.no_clobber = true;
                o.interactive = false;
            },
            'P' => o.deref = .never,
            'p' => {
                o.preserve_mode = true;
                o.preserve_owner = true;
                o.preserve_time = true;
            },
            'r', 'R' => o.recursive = true,
            's' => o.symlink = true,
            't' => target_dir = p.arg(),
            'T' => no_target = true,
            'u' => o.update = true,
            'v' => o.verbose = true,
            'x' => o.one_fs = true,
            'b' => {},
            else => p.bad(opt),
        },
        .long => |n| {
            if (c.eql(n, "preserve")) {
                const v = p.optArg() orelse "mode,ownership,timestamps";
                var it = mem.splitScalar(u8, v, ',');
                while (it.next()) |a| {
                    if (c.eql(a, "mode")) o.preserve_mode = true else if (c.eql(a, "ownership")) o.preserve_owner = true else if (c.eql(a, "timestamps")) o.preserve_time = true else if (c.eql(a, "all")) {
                        o.preserve_mode = true;
                        o.preserve_owner = true;
                        o.preserve_time = true;
                    }
                }
            } else if (c.eql(n, "no-preserve")) {
                const v = p.arg();
                var it = mem.splitScalar(u8, v, ',');
                while (it.next()) |a| {
                    if (c.eql(a, "mode")) o.preserve_mode = false else if (c.eql(a, "ownership")) o.preserve_owner = false else if (c.eql(a, "timestamps")) o.preserve_time = false else if (c.eql(a, "all")) {
                        o.preserve_mode = false;
                        o.preserve_owner = false;
                        o.preserve_time = false;
                    }
                }
            } else if (c.eql(n, "parents")) o.parents = true else if (c.eql(n, "remove-destination")) o.remove_dest = true else if (c.eql(n, "sparse") or c.eql(n, "reflink")) {
                _ = p.optArg();
            } else p.bad(opt);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    return runCopyLike(files.items, target_dir, no_target, copyTop);
}

fn copyTop(src: []const u8, dst: []const u8) bool {
    return copy(src, dst, true, 0);
}

/// Shared operand handling for cp and mv.
pub fn runCopyLike(files_in: []const []const u8, target_dir: ?[]const u8, no_target: bool, op: *const fn ([]const u8, []const u8) bool) u8 {
    var files = files_in;
    if (files.len == 0) c.usageErr("missing file operand", .{});
    var dest_dir: ?[]const u8 = target_dir;
    if (dest_dir) |td| {
        const st = c.sys.stat(td) catch |e| c.fatal("target directory {f}: {s}", .{ c.q(td), c.strerror(e) });
        if (!st.isDir()) c.fatal("target {f} is not a directory", .{c.q(td)});
    } else {
        if (files.len == 1) c.usageErr("missing destination file operand after {f}", .{c.q(files[0])});
        const last = files[files.len - 1];
        if (no_target) {
            if (files.len > 2) c.usageErr("extra operand {f}", .{c.q(files[2])});
        } else {
            const st: ?c.Stat = c.sys.stat(last) catch null;
            if (st != null and st.?.isDir()) {
                dest_dir = last;
                files = files[0 .. files.len - 1];
            } else if (files.len > 2) {
                c.fatal("target {f} is not a directory", .{c.q(last)});
            }
        }
    }
    if (dest_dir) |dd| {
        for (files) |f| {
            var name: []const u8 = c.basename(f);
            if (o.parents) name = mem.trimLeft(u8, f, "/");
            if (o.parents) {
                // create intermediate dirs
                const dpath = c.dirname(name);
                if (!c.eql(dpath, ".")) {
                    var it = mem.tokenizeScalar(u8, dpath, '/');
                    var cur: []const u8 = dd;
                    while (it.next()) |comp| {
                        cur = c.join(cur, comp);
                        c.sys.mkdir(cur, 0o755) catch {};
                    }
                }
            }
            const dst = c.join(dd, name);
            if (!op(f, dst)) status = 1;
        }
    } else {
        if (!op(files[0], files[1])) status = 1;
    }
    return status;
}
