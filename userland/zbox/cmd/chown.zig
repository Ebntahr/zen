const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...
    \\  or:  chown [OPTION]... --reference=RFILE FILE...
    \\Change the owner and/or group of each FILE to OWNER and/or GROUP.
    \\With --reference, change the owner and group of each FILE to those of RFILE.
    \\
    \\  -c, --changes          like verbose but report only when a change is made
    \\  -f, --silent, --quiet  suppress most error messages
    \\  -v, --verbose          output a diagnostic for every file processed
    \\  -h, --no-dereference   affect symbolic links instead of any referenced file
    \\      --from=CURRENT_OWNER:CURRENT_GROUP
    \\                         change only if its current owner and/or group match
    \\      --reference=RFILE  use RFILE's owner and group rather than specifying values
    \\  -R, --recursive        operate on files and directories recursively
    \\
;
pub const help_chgrp =
    \\Usage: chgrp [OPTION]... GROUP FILE...
    \\  or:  chgrp [OPTION]... --reference=RFILE FILE...
    \\Change the group of each FILE to GROUP.
    \\
    \\  -c, --changes          like verbose but report only when a change is made
    \\  -f, --silent, --quiet  suppress most error messages
    \\  -v, --verbose          output a diagnostic for every file processed
    \\  -h, --no-dereference   affect symbolic links instead of any referenced file
    \\      --reference=RFILE  use RFILE's group rather than specifying a GROUP value
    \\  -R, --recursive        operate on files and directories recursively
    \\
;

var changes = false;
var quiet = false;
var verbose = false;
var no_deref = false;
var recursive = false;
var new_uid: ?u32 = null;
var new_gid: ?u32 = null;
var from_uid: ?u32 = null;
var from_gid: ?u32 = null;
var is_chgrp = false;
var status: u8 = 0;

fn lookupUser(s: []const u8) u32 {
    if (c.userByName(s)) |u| return u.uid;
    if (c.parseUint(s)) |n| return @intCast(n);
    c.fatal("invalid user: {f}", .{c.q(s)});
}
fn lookupGroup(s: []const u8) u32 {
    if (c.groupByName(s)) |g| return g.gid;
    if (c.parseUint(s)) |n| return @intCast(n);
    c.fatal("invalid group: {f}", .{c.q(s)});
}

fn parseSpec(spec: []const u8, uid: *?u32, gid: *?u32) void {
    var sep = mem.indexOfScalar(u8, spec, ':');
    if (sep == null) {
        // old "user.group" syntax only if user.group isn't a valid user name
        if (mem.indexOfScalar(u8, spec, '.')) |d| {
            if (c.userByName(spec) == null) sep = d;
        }
    }
    if (sep) |s| {
        const u = spec[0..s];
        const g = spec[s + 1 ..];
        if (u.len > 0) uid.* = lookupUser(u);
        if (g.len > 0) {
            gid.* = lookupGroup(g);
        } else if (u.len > 0) {
            // "user:" -> login group
            if (c.userByName(u)) |ue| gid.* = ue.gid else gid.* = uid.*;
        }
    } else if (spec.len > 0) {
        uid.* = lookupUser(spec);
    }
}

fn describe(buf: []u8, uid: ?u32, gid: ?u32) []const u8 {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    if (uid != null and gid != null) return c.fmtBuf(buf, "{s}:{s}", .{ c.userName(&b1, uid.?), c.groupName(&b2, gid.?) });
    if (uid) |u| return c.fmtBuf(buf, "{s}", .{c.userName(&b1, u)});
    if (gid) |g| return c.fmtBuf(buf, "{s}", .{c.groupName(&b2, g)});
    return "";
}

fn apply(path: []const u8, top: bool) void {
    const nofollow = no_deref or (!top and recursive);
    const st = (if (nofollow) c.sys.lstat(path) else c.sys.stat(path)) catch |e| {
        if (!quiet) c.warn("cannot access {f}: {s}", .{ c.q(path), c.strerror(e) });
        status = 1;
        return;
    };
    const match = (from_uid == null or from_uid.? == st.uid) and (from_gid == null or from_gid.? == st.gid);
    if (match) {
        const tu = new_uid orelse st.uid;
        const tg = new_gid orelse st.gid;
        const changed = tu != st.uid or tg != st.gid;
        var ok = true;
        c.sys.chown(path, new_uid, new_gid, nofollow) catch |e| {
            ok = false;
            status = 1;
            if (!quiet) {
                if (is_chgrp) {
                    c.warn("changing group of {f}: {s}", .{ c.q(path), c.strerror(e) });
                } else c.warn("changing ownership of {f}: {s}", .{ c.q(path), c.strerror(e) });
            }
        };
        if (ok and (verbose or (changes and changed))) {
            var b1: [80]u8 = undefined;
            var b2: [80]u8 = undefined;
            const what = if (is_chgrp) "group" else "ownership";
            const old_d = if (is_chgrp) describe(&b1, null, st.gid) else describe(&b1, if (new_uid != null) st.uid else null, if (new_gid != null) st.gid else null);
            const new_d = if (is_chgrp) describe(&b2, null, tg) else describe(&b2, new_uid, new_gid);
            if (changed) {
                c.out.print("changed {s} of {f} from {s} to {s}\n", .{ what, c.q(path), old_d, new_d }) catch {};
            } else {
                c.out.print("{s} of {f} retained as {s}\n", .{ what, c.q(path), new_d }) catch {};
            }
        }
    }
    if (recursive and st.isDir()) {
        const names = c.readDirNames(path) catch |e| {
            if (!quiet) c.warn("cannot read directory {f}: {s}", .{ c.q(path), c.strerror(e) });
            status = 1;
            return;
        };
        defer c.freeNames(names);
        c.sortStrings(names);
        for (names) |n| {
            const full = c.join(path, n);
            defer c.gpa.free(full);
            apply(full, false);
        }
    }
}

fn run(args: c.Args) u8 {
    var ops: std.ArrayList([]const u8) = .empty;
    var have_ref = false;
    var p = c.Parser.init(args, &.{
        .{ "changes", 'c' }, .{ "silent", 'f' },  .{ "quiet", 'f' },     .{ "verbose", 'v' },
        .{ "no-dereference", 'h' }, .{ "dereference", 0 }, .{ "from", 0 }, .{ "reference", 0 },
        .{ "recursive", 'R' }, .{ "preserve-root", 0 }, .{ "no-preserve-root", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => changes = true,
            'f' => quiet = true,
            'v' => verbose = true,
            'h' => no_deref = true,
            'R' => recursive = true,
            'H', 'L', 'P' => {},
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "dereference")) {
                no_deref = false;
            } else if (c.eql(n, "from")) {
                parseSpec(p.arg(), &from_uid, &from_gid);
            } else if (c.eql(n, "reference")) {
                const r = p.arg();
                const st = c.sys.stat(r) catch |e| c.fatal("failed to get attributes of {f}: {s}", .{ c.q(r), c.strerror(e) });
                if (!is_chgrp) new_uid = st.uid;
                new_gid = st.gid;
                have_ref = true;
            } else if (c.eql(n, "preserve-root") or c.eql(n, "no-preserve-root")) {} else p.bad(o);
        },
        .pos => |a| ops.append(c.gpa, a) catch c.oom(),
    };
    if (!have_ref) {
        if (ops.items.len == 0) c.missingOperand();
        const spec = ops.orderedRemove(0);
        if (is_chgrp) {
            new_gid = lookupGroup(spec);
        } else parseSpec(spec, &new_uid, &new_gid);
        if (ops.items.len == 0) c.usageErr("missing operand after {f}", .{c.q(spec)});
    } else if (ops.items.len == 0) c.missingOperand();
    for (ops.items) |f| apply(f, true);
    return status;
}

pub fn main(args: c.Args) !u8 {
    return run(args);
}

pub fn mainChgrp(args: c.Args) !u8 {
    is_chgrp = true;
    return run(args);
}
