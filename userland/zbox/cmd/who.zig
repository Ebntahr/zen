const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: who [OPTION]... [ FILE | ARG1 ARG2 ]
    \\Print information about users who are currently logged in.
    \\
    \\  -a, --all         same as -b -d --login -p -r -t -T -u
    \\  -b, --boot        time of last system boot
    \\  -H, --heading     print line of column headings
    \\  -m                only hostname and user associated with stdin
    \\  -q, --count       all login names and number of users logged on
    \\  -s, --short       print only name, line, and time (default)
    \\
;
pub const help_users =
    \\Usage: users [OPTION]... [FILE]
    \\Output who is currently logged in according to FILE.
    \\If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.
    \\
;

const Entry = struct { user: []const u8, line: []const u8, host: []const u8, time: i64, pid: i32 };

const UTMP_SIZE = 384;

fn readUtmp(path: []const u8) ?[]Entry {
    const data = c.readFile(path) catch return null;
    var list: std.ArrayList(Entry) = .empty;
    var off: usize = 0;
    while (off + UTMP_SIZE <= data.len) : (off += UTMP_SIZE) {
        const r = data[off .. off + UTMP_SIZE];
        const typ = mem.readInt(i16, r[0..2], .little);
        if (typ != 7) continue; // USER_PROCESS
        const pid = mem.readInt(i32, r[4..8], .little);
        const line = mem.sliceTo(r[8..40], 0);
        const user = mem.sliceTo(r[44..76], 0);
        const host = mem.sliceTo(r[76..332], 0);
        const tv = mem.readInt(i32, r[340..344], .little);
        list.append(c.gpa, .{ .user = user, .line = line, .host = host, .time = tv, .pid = pid }) catch c.oom();
    }
    return list.items;
}

fn ttyOfStdin(buf: []u8) ?[]const u8 {
    if (!c.isatty(0)) return null;
    const t = c.sys.readlink("/proc/self/fd/0", buf) catch return null;
    if (mem.startsWith(u8, t, "/dev/")) return t[5..];
    return t;
}

/// Entries from utmp, or a synthesized entry for the current user when there is no utmp.
fn entries() []Entry {
    if (readUtmp("/var/run/utmp") orelse readUtmp("/run/utmp")) |e| return e;
    var list: std.ArrayList(Entry) = .empty;
    const u = c.userByUid(c.sys.getuid()) orelse return list.items;
    var tb: [c.PATH_MAX]u8 = undefined;
    const line = ttyOfStdin(&tb) orelse "console";
    list.append(c.gpa, .{ .user = u.name, .line = c.gpa.dupe(u8, line) catch c.oom(), .host = "", .time = c.now().sec, .pid = c.sys.getpid() }) catch c.oom();
    return list.items;
}

pub fn countUsers() usize {
    if (readUtmp("/var/run/utmp") orelse readUtmp("/run/utmp")) |e| return e.len;
    return 0;
}

pub fn loginName() ?[]const u8 {
    var tb: [c.PATH_MAX]u8 = undefined;
    if (ttyOfStdin(&tb)) |t| {
        if (readUtmp("/var/run/utmp") orelse readUtmp("/run/utmp")) |ents| {
            for (ents) |e| if (c.eql(e.line, t)) return e.user;
        }
    }
    if (c.getenv("LOGNAME")) |l| if (l.len > 0 and readUtmp("/var/run/utmp") == null) return l;
    return null;
}

pub fn mainUsers(args: c.Args) !u8 {
    var file: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .pos => |a| file = a,
        else => p.bad(o),
    };
    const ents = if (file) |f| (readUtmp(f) orelse &[_]Entry{}) else entries();
    var names: std.ArrayList([]const u8) = .empty;
    for (ents) |e| try names.append(c.gpa, e.user);
    c.sortStrings(names.items);
    for (names.items, 0..) |n, i| {
        if (i > 0) try c.out.writeByte(' ');
        try c.out.writeAll(n);
    }
    if (names.items.len > 0) try c.out.writeByte('\n');
    return 0;
}

pub fn main(args: c.Args) !u8 {
    var heading = false;
    var count = false;
    var boot = false;
    var only_me = false;
    var file: ?[]const u8 = null;
    var positional: usize = 0;
    var p = c.Parser.init(args, &.{ .{ "all", 'a' }, .{ "boot", 'b' }, .{ "heading", 'H' }, .{ "count", 'q' }, .{ "short", 's' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {
                boot = true;
                heading = true;
            },
            'b' => boot = true,
            'H' => heading = true,
            'm' => only_me = true,
            'q' => count = true,
            's', 'u', 'T', 'w', 'l', 'p', 'd', 'r', 't' => {},
            else => p.bad(o),
        },
        .pos => |a| {
            positional += 1;
            if (positional == 1) file = a;
        },
        else => p.bad(o),
    };
    if (positional == 2) only_me = true;
    const w = c.out;
    var ents = if (file != null and positional == 1) (readUtmp(file.?) orelse &[_]Entry{}) else entries();
    if (only_me) {
        var tb: [c.PATH_MAX]u8 = undefined;
        const t = ttyOfStdin(&tb) orelse "";
        var filtered: std.ArrayList(Entry) = .empty;
        for (ents) |e| if (c.eql(e.line, t) or t.len == 0) try filtered.append(c.gpa, e);
        ents = filtered.items;
    }
    if (count) {
        for (ents, 0..) |e, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(e.user);
        }
        try w.print("\n# users={d}\n", .{ents.len});
        return 0;
    }
    if (heading) try w.writeAll("NAME     LINE         TIME             COMMENT\n");
    if (boot) {
        const pr = @import("../procfs.zig");
        const bt = c.now().sec - @as(i64, @intFromFloat(pr.uptimeSecs()));
        try w.writeAll("         system boot  ");
        try c.strftime(w, "%Y-%m-%d %H:%M\n", c.localtime(bt), 0, bt);
    }
    for (ents) |e| {
        try c.padRight(w, e.user, 8);
        try w.writeByte(' ');
        try c.padRight(w, e.line, 12);
        try w.writeByte(' ');
        try c.strftime(w, "%Y-%m-%d %H:%M", c.localtime(e.time), 0, e.time);
        if (e.host.len > 0) try w.print(" ({s})", .{e.host});
        try w.writeByte('\n');
    }
    return 0;
}
