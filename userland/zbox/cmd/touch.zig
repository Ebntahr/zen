const std = @import("std");
const c = @import("../common.zig");
const linux = std.os.linux;

pub const help =
    \\Usage: touch [OPTION]... FILE...
    \\Update the access and modification times of each FILE to the current time.
    \\
    \\A FILE argument that does not exist is created empty, unless -c or -h
    \\is supplied.
    \\
    \\  -a                     change only the access time
    \\  -c, --no-create        do not create any files
    \\  -d, --date=STRING      parse STRING and use it instead of current time
    \\  -h, --no-dereference   affect each symbolic link instead of any referenced file
    \\  -m                     change only the modification time
    \\  -r, --reference=FILE   use this file's times instead of current time
    \\  -t [[CC]YY]MMDDhhmm[.ss]  use specified time instead of current time
    \\      --time=WORD        change the specified time: access (-a) or modify (-m)
    \\
;

fn parseStamp(s: []const u8) ?c.Ts {
    var main_part = s;
    var secs: u8 = 0;
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        main_part = s[0..dot];
        const ss = s[dot + 1 ..];
        if (ss.len != 2) return null;
        secs = @intCast(c.parseUint(ss) orelse return null);
    }
    for (main_part) |ch| if (!std.ascii.isDigit(ch)) return null;
    const nowt = c.localtime(c.now().sec);
    var tm = nowt;
    var rest = main_part;
    switch (main_part.len) {
        8 => {},
        10 => {
            const yy = c.parseUint(rest[0..2]).?;
            tm.year = if (yy < 69) 2000 + @as(i64, @intCast(yy)) else 1900 + @as(i64, @intCast(yy));
            rest = rest[2..];
        },
        12 => {
            tm.year = @intCast(c.parseUint(rest[0..4]).?);
            rest = rest[4..];
        },
        else => return null,
    }
    const mo = c.parseUint(rest[0..2]).?;
    const d = c.parseUint(rest[2..4]).?;
    const h = c.parseUint(rest[4..6]).?;
    const mi = c.parseUint(rest[6..8]).?;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or secs > 60) return null;
    tm.mon = @intCast(mo - 1);
    tm.mday = @intCast(d);
    tm.hour = @intCast(h);
    tm.min = @intCast(mi);
    tm.sec = secs;
    return .{ .sec = c.mktime(tm), .nsec = 0 };
}

pub fn main(args: c.Args) !u8 {
    var only_a = false;
    var only_m = false;
    var no_create = false;
    var no_deref = false;
    var when: ?[2]c.Ts = null;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "no-create", 'c' }, .{ "date", 'd' }, .{ "no-dereference", 'h' }, .{ "reference", 'r' }, .{ "time", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => only_a = true,
            'm' => only_m = true,
            'c' => no_create = true,
            'h' => no_deref = true,
            'f' => {},
            'd' => {
                const s = p.arg();
                const t = c.parseDate(s, c.now().sec, false) orelse c.fatal("invalid date format {f}", .{c.q(s)});
                when = .{ t, t };
            },
            't' => {
                const s = p.arg();
                const t = parseStamp(s) orelse c.fatal("invalid date format {f}", .{c.q(s)});
                when = .{ t, t };
            },
            'r' => {
                const r = p.arg();
                const st = c.sys.stat(r) catch |e| c.fatal("failed to get attributes of {f}: {s}", .{ c.q(r), c.strerror(e) });
                when = .{ st.atime, st.mtime };
            },
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "time")) {
                const v = p.arg();
                if (c.eql(v, "access") or c.eql(v, "atime") or c.eql(v, "use")) only_a = true else if (c.eql(v, "modify") or c.eql(v, "mtime")) only_m = true else c.usageErr("invalid argument {f} for '--time'", .{c.q(v)});
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len == 0) c.usageErr("missing file operand", .{});
    const UTIME_NOW: isize = (1 << 30) - 1;
    const UTIME_OMIT: isize = (1 << 30) - 2;
    var times: [2]linux.timespec = undefined;
    if (when) |t| {
        times[0] = .{ .sec = @intCast(t[0].sec), .nsec = @intCast(t[0].nsec) };
        times[1] = .{ .sec = @intCast(t[1].sec), .nsec = @intCast(t[1].nsec) };
    } else {
        times[0] = .{ .sec = 0, .nsec = UTIME_NOW };
        times[1] = .{ .sec = 0, .nsec = UTIME_NOW };
    }
    if (only_a and !only_m) times[1].nsec = UTIME_OMIT;
    if (only_m and !only_a) times[0].nsec = UTIME_OMIT;
    var status: u8 = 0;
    for (files.items) |f| {
        if (c.eql(f, "-")) {
            c.sys.futimens(1, &times) catch |e| {
                c.warn("setting times of 'standard output': {s}", .{c.strerror(e)});
                status = 1;
            };
            continue;
        }
        c.sys.utimens(f, &times, no_deref) catch |e| {
            if (e == error.NOENT and !no_create and !no_deref) {
                const fd = c.sys.open(f, .{ .ACCMODE = .WRONLY, .CREAT = true, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0o666) catch |e2| {
                    c.warn("cannot touch {f}: {s}", .{ c.q(f), c.strerror(e2) });
                    status = 1;
                    continue;
                };
                defer c.sys.close(fd);
                if (when != null or only_a or only_m) c.sys.futimens(fd, &times) catch {};
                continue;
            }
            if (e == error.NOENT and (no_create or no_deref)) continue;
            c.warn("setting times of {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
        };
    }
    return status;
}
