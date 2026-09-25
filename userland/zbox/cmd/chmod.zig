const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: chmod [OPTION]... MODE[,MODE]... FILE...
    \\  or:  chmod [OPTION]... OCTAL-MODE FILE...
    \\  or:  chmod [OPTION]... --reference=RFILE FILE...
    \\Change the mode of each FILE to MODE.
    \\
    \\  -c, --changes          like verbose but report only when a change is made
    \\  -f, --silent, --quiet  suppress most error messages
    \\  -v, --verbose          output a diagnostic for every file processed
    \\      --reference=RFILE  use RFILE's mode instead of specifying MODE values
    \\  -R, --recursive        change files and directories recursively
    \\
    \\Each MODE is of the form '[ugoa]*([-+=]([rwxXst]*|[ugo]))+|[-+=][0-7]+'.
    \\
;

var changes = false;
var quiet = false;
var verbose = false;
var recursive = false;
var ref_mode: ?u32 = null;
var mode_spec: []const u8 = "";
var umask_v: u32 = 0;
var status: u8 = 0;

fn describe(buf: []u8, mode: u32) []const u8 {
    const s = c.modeString(mode);
    return c.fmtBuf(buf, "{o:0>4} ({s})", .{ mode & 0o7777, s[1..] });
}

fn apply(path: []const u8, top: bool) void {
    const st = (if (top) c.sys.stat(path) else c.sys.lstat(path)) catch |e| {
        if (!quiet) c.warn("cannot access {f}: {s}", .{ c.q(path), c.strerror(e) });
        status = 1;
        return;
    };
    if (st.isLnk()) {
        // symlinks encountered during recursion are skipped
        if (verbose) c.out.print("neither symbolic link {f} nor referent has been changed\n", .{c.q(path)}) catch {};
        return;
    }
    const new_mode = ref_mode orelse (c.parseMode(mode_spec, st.mode, st.isDir(), umask_v) orelse {
        c.fatal("invalid mode: {f}", .{c.q(mode_spec)});
    });
    const old = st.mode & 0o7777;
    var ok = true;
    c.sys.chmod(path, new_mode) catch |e| {
        if (!quiet) c.warn("changing permissions of {f}: {s}", .{ c.q(path), c.strerror(e) });
        status = 1;
        ok = false;
    };
    if (ok and (verbose or (changes and old != new_mode))) {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        if (old == new_mode) {
            c.out.print("mode of {f} retained as {s}\n", .{ c.q(path), describe(&b1, st.mode) }) catch {};
        } else {
            c.out.print("mode of {f} changed from {s} to {s}\n", .{ c.q(path), describe(&b1, st.mode), describe(&b2, (st.mode & c.S_IFMT) | new_mode) }) catch {};
        }
    }
    if (recursive and st.isDir()) {
        const names = c.readDirNames(path) catch |e| {
            if (!quiet) c.warn("cannot read directory {f}: {s}", .{ c.q(path), c.strerror(e) });
            status = 1;
            return;
        };
        c.sortStrings(names);
        for (names) |n| apply(c.join(path, n), false);
    }
}

fn isModeArg(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |ch| if (std.mem.indexOfScalar(u8, "rwxXstugoa=+-,0123456789", ch) == null) return false;
    return true;
}

pub fn main(args: c.Args) !u8 {
    var ops: std.ArrayList([]const u8) = .empty;
    // pull out mode-like options such as -w, -x, -rwx
    var filtered: std.ArrayList([:0]const u8) = .empty;
    var early_mode: ?[]const u8 = null;
    for (args, 0..) |a, i| {
        if (i > 0 and early_mode == null and isModeArg(a) and !c.eql(a, "--")) {
            early_mode = a;
            continue;
        }
        try filtered.append(c.gpa, a);
    }
    var p = c.Parser.init(filtered.items, &.{
        .{ "changes", 'c' }, .{ "silent", 'f' }, .{ "quiet", 'f' }, .{ "verbose", 'v' }, .{ "reference", 0 }, .{ "recursive", 'R' },
        .{ "preserve-root", 0 }, .{ "no-preserve-root", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => changes = true,
            'f' => quiet = true,
            'v' => verbose = true,
            'R' => recursive = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "reference")) {
                const r = p.arg();
                const st = c.sys.stat(r) catch |e| c.fatal("failed to get attributes of {f}: {s}", .{ c.q(r), c.strerror(e) });
                ref_mode = st.mode & 0o7777;
            } else if (c.eql(n, "preserve-root") or c.eql(n, "no-preserve-root")) {} else p.bad(o);
        },
        .pos => |a| try ops.append(c.gpa, a),
    };
    umask_v = c.sys.umask(0);
    _ = c.sys.umask(umask_v);
    if (ref_mode == null) {
        if (early_mode) |m| {
            mode_spec = m;
        } else {
            if (ops.items.len == 0) c.missingOperand();
            mode_spec = ops.orderedRemove(0);
        }
        if (c.parseMode(mode_spec, 0, false, umask_v) == null) c.usageErr("invalid mode: {f}", .{c.q(mode_spec)});
    }
    if (ops.items.len == 0) {
        c.usageErr("missing operand after {f}", .{c.q(mode_spec)});
    }
    for (ops.items) |f| apply(f, true);
    return status;
}
