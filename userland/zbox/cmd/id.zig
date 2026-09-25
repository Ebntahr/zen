const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: id [OPTION]... [USER]...
    \\Print user and group information for each specified USER,
    \\or (when USER omitted) for the current process.
    \\
    \\  -a             ignore, for compatibility with other versions
    \\  -g, --group    print only the effective group ID
    \\  -G, --groups   print all group IDs
    \\  -n, --name     print a name instead of a number, for -ugG
    \\  -r, --real     print the real ID instead of the effective ID, with -ugG
    \\  -u, --user     print only the effective user ID
    \\  -z, --zero     delimit entries with NUL characters, not whitespace;
    \\
;

pub fn currentGroups() []u32 {
    var buf: [256]u32 = undefined;
    const g = c.sys.getgroups(&buf) catch &[_]u32{};
    var list: std.ArrayList(u32) = .empty;
    const egid = c.sys.getegid();
    list.append(c.gpa, egid) catch c.oom();
    for (g) |x| if (mem.indexOfScalar(u32, list.items, x) == null) list.append(c.gpa, x) catch c.oom();
    return list.items;
}

pub fn main(args: c.Args) !u8 {
    var only_u = false;
    var only_g = false;
    var only_G = false;
    var name = false;
    var real = false;
    var zero = false;
    var users: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "group", 'g' }, .{ "groups", 'G' }, .{ "name", 'n' }, .{ "real", 'r' }, .{ "user", 'u' }, .{ "zero", 'z' }, .{ "context", 'Z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {},
            'g' => only_g = true,
            'G' => only_G = true,
            'n' => name = true,
            'r' => real = true,
            'u' => only_u = true,
            'z' => zero = true,
            'Z' => c.fatal("--context (-Z) works only on an SELinux-enabled kernel", .{}),
            else => p.bad(o),
        },
        .pos => |a| try users.append(c.gpa, a),
        else => p.bad(o),
    };
    const nsel = @as(u8, @intFromBool(only_u)) + @intFromBool(only_g) + @intFromBool(only_G);
    if (nsel > 1) c.usageErr("cannot print \"only\" of more than one choice", .{});
    if (nsel == 0 and (name or real)) c.usageErr("cannot print only names or real IDs in default format", .{});
    if (zero and nsel == 0) c.usageErr("option --zero not permitted in default format", .{});
    if (users.items.len == 0) try users.append(c.gpa, "");
    const w = c.out;
    var status: u8 = 0;
    for (users.items) |uname| {
        var ruid: u32 = undefined;
        var euid: u32 = undefined;
        var rgid: u32 = undefined;
        var egid: u32 = undefined;
        var groups: []u32 = undefined;
        if (uname.len == 0) {
            ruid = c.sys.getuid();
            euid = c.sys.geteuid();
            rgid = c.sys.getgid();
            egid = c.sys.getegid();
            groups = currentGroups();
        } else {
            const u = c.userByName(uname) orelse blk: {
                if (c.parseUint(uname)) |n| if (c.userByUid(@intCast(n))) |x| break :blk x;
                c.warn("{f}: no such user", .{c.q(uname)});
                status = 1;
                continue;
            };
            ruid = u.uid;
            euid = u.uid;
            rgid = u.gid;
            egid = u.gid;
            groups = c.userGroupList(u.name, u.gid);
        }
        var nb: [64]u8 = undefined;
        const sep: u8 = if (zero) 0 else ' ';
        const eol: u8 = if (zero) 0 else '\n';
        if (only_u) {
            const id = if (real) ruid else euid;
            if (name) try w.writeAll(c.userName(&nb, id)) else try w.print("{d}", .{id});
            try w.writeByte(eol);
            continue;
        }
        if (only_g) {
            const id = if (real) rgid else egid;
            if (name) try w.writeAll(c.groupName(&nb, id)) else try w.print("{d}", .{id});
            try w.writeByte(eol);
            continue;
        }
        if (only_G) {
            for (groups, 0..) |g, i| {
                if (i > 0) try w.writeByte(sep);
                if (name) try w.writeAll(c.groupName(&nb, g)) else try w.print("{d}", .{g});
            }
            try w.writeByte(eol);
            continue;
        }
        try w.print("uid={d}", .{ruid});
        if (c.userByUid(ruid)) |u| try w.print("({s})", .{u.name});
        try w.print(" gid={d}", .{rgid});
        if (c.groupByGid(rgid)) |g| try w.print("({s})", .{g.name});
        if (euid != ruid) {
            try w.print(" euid={d}", .{euid});
            if (c.userByUid(euid)) |u| try w.print("({s})", .{u.name});
        }
        if (egid != rgid) {
            try w.print(" egid={d}", .{egid});
            if (c.groupByGid(egid)) |g| try w.print("({s})", .{g.name});
        }
        try w.writeAll(" groups=");
        for (groups, 0..) |g, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{g});
            if (c.groupByGid(g)) |ge| try w.print("({s})", .{ge.name});
        }
        try w.writeByte('\n');
    }
    return status;
}
