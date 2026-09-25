const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: date [OPTION]... [+FORMAT]
    \\  or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]
    \\Display date and time in the given FORMAT.
    \\With -s, or with [MMDDhhmm[[CC]YY][.ss]], set the date and time.
    \\
    \\  -d, --date=STRING          display time described by STRING, not 'now'
    \\  -I[FMT], --iso-8601[=FMT]  output date/time in ISO 8601 format.
    \\                               FMT='date' for date only (the default),
    \\                               'hours', 'minutes', 'seconds', or 'ns'
    \\  -R, --rfc-email            output date and time in RFC 5322 format.
    \\      --rfc-3339=FMT         output date/time in RFC 3339 format.
    \\                               FMT='date', 'seconds', or 'ns'
    \\  -r, --reference=FILE       display the last modification time of FILE
    \\  -s, --set=STRING           set time described by STRING
    \\  -u, --utc, --universal     print or set Coordinated Universal Time (UTC)
    \\
    \\FORMAT controls the output.  Interpreted sequences are:
    \\  %%  a literal %          %a  abbreviated weekday    %A  full weekday name
    \\  %b  abbreviated month    %B  full month name        %c  date and time
    \\  %C  century              %d  day of month (01)      %D  %m/%d/%y
    \\  %e  day of month ( 1)    %F  %Y-%m-%d               %g/%G ISO year
    \\  %H  hour (00..23)        %I  hour (01..12)          %j  day of year
    \\  %k  hour ( 0..23)        %l  hour ( 1..12)          %m  month (01..12)
    \\  %M  minute (00..59)      %n  a newline              %N  nanoseconds
    \\  %p  AM or PM             %P  am or pm               %r  12-hour time
    \\  %R  %H:%M                %s  seconds since Epoch    %S  second (00..60)
    \\  %t  a tab                %T  %H:%M:%S               %u  day of week (1..7)
    \\  %U  week of year (Sun)   %V  ISO week number        %w  day of week (0..6)
    \\  %W  week of year (Mon)   %x  date                   %X  time
    \\  %y  last two digits of year                          %Y  year
    \\  %z  +hhmm numeric time zone  %:z  +hh:mm             %Z  time zone abbreviation
    \\
    \\By default, date pads numeric fields with zeroes.  Flags: - (no pad),
    \\_ (pad with spaces), 0 (pad with zeros), ^ (upper case).
    \\
;

fn parseSetStamp(s: []const u8, base: i64, utc: bool) ?i64 {
    // MMDDhhmm[[CC]YY][.ss]
    var main_part = s;
    var secs: u8 = 0;
    if (mem.indexOfScalar(u8, s, '.')) |dot| {
        main_part = s[0..dot];
        secs = @intCast(c.parseUint(s[dot + 1 ..]) orelse return null);
    }
    for (main_part) |ch| if (!std.ascii.isDigit(ch)) return null;
    if (main_part.len != 8 and main_part.len != 10 and main_part.len != 12) return null;
    var tm = if (utc) c.gmtime(base) else c.localtime(base);
    tm.mon = @intCast((c.parseUint(main_part[0..2]) orelse return null) - 1);
    tm.mday = @intCast(c.parseUint(main_part[2..4]) orelse return null);
    tm.hour = @intCast(c.parseUint(main_part[4..6]) orelse return null);
    tm.min = @intCast(c.parseUint(main_part[6..8]) orelse return null);
    tm.sec = secs;
    if (main_part.len == 10) {
        const yy = c.parseUint(main_part[8..10]).?;
        tm.year = if (yy < 69) 2000 + @as(i64, @intCast(yy)) else 1900 + @as(i64, @intCast(yy));
    } else if (main_part.len == 12) tm.year = @intCast(c.parseUint(main_part[8..12]).?);
    return if (utc) c.timegm(tm) else c.mktime(tm);
}

pub fn main(args: c.Args) !u8 {
    var utc = false;
    var date_str: ?[]const u8 = null;
    var set_str: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var fmt: ?[]const u8 = null;
    var iso: ?[]const u8 = null;
    var rfc_email = false;
    var rfc3339: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{
        .{ "date", 'd' },  .{ "iso-8601", 'I' }, .{ "rfc-email", 'R' }, .{ "rfc-2822", 'R' }, .{ "rfc-3339", 0 },
        .{ "reference", 'r' }, .{ "set", 's' }, .{ "utc", 'u' }, .{ "universal", 'u' }, .{ "file", 'f' }, .{ "debug", 0 },
    });
    var operand: ?[]const u8 = null;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'd' => date_str = p.arg(),
            'I' => iso = p.optArg() orelse "date",
            'R' => rfc_email = true,
            'r' => ref = p.arg(),
            's' => set_str = p.arg(),
            'u' => utc = true,
            'f' => c.fatal("--file is not supported", .{}),
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "rfc-3339")) rfc3339 = p.arg() else if (c.eql(n, "debug")) {} else p.bad(o);
        },
        .pos => |a| {
            if (a.len > 0 and a[0] == '+') {
                if (fmt != null) c.usageErr("multiple output formats specified", .{});
                fmt = a[1..];
            } else {
                if (operand != null) c.usageErr("extra operand {f}", .{c.q(a)});
                operand = a;
            }
        },
    };
    if (utc) c.force_utc = true;
    var t = c.now();
    if (ref) |r| {
        const st = c.sys.stat(r) catch |e| c.fatal("{s}: {s}", .{ r, c.strerror(e) });
        t = st.mtime;
    }
    if (date_str) |d| {
        t = c.parseDate(d, t.sec, utc) orelse c.fatal("invalid date {f}", .{c.q(d)});
    }
    if (operand) |op| {
        const secs = parseSetStamp(op, t.sec, utc) orelse c.fatal("invalid date {f}", .{c.q(op)});
        set_str = null;
        t = .{ .sec = secs, .nsec = 0 };
        var ts: std.os.linux.timespec = .{ .sec = @intCast(secs), .nsec = 0 };
        if (std.posix.errno(std.os.linux.clock_settime(0, &ts)) != .SUCCESS) c.warn("cannot set date: Operation not permitted", .{});
    }
    if (set_str) |s| {
        t = c.parseDate(s, t.sec, utc) orelse c.fatal("invalid date {f}", .{c.q(s)});
        var ts: std.os.linux.timespec = .{ .sec = @intCast(t.sec), .nsec = @intCast(t.nsec) };
        if (std.posix.errno(std.os.linux.clock_settime(0, &ts)) != .SUCCESS) {
            c.warn("cannot set date: Operation not permitted", .{});
            return 1;
        }
    }
    const tm = if (utc) c.gmtime(t.sec) else c.localtime(t.sec);
    var f: []const u8 = fmt orelse "%a %b %e %H:%M:%S %Z %Y";
    if (iso) |kind| {
        if (c.eql(kind, "date") or kind.len == 0) f = "%Y-%m-%d" else if (c.eql(kind, "hours")) f = "%Y-%m-%dT%H%:z" else if (c.eql(kind, "minutes")) f = "%Y-%m-%dT%H:%M%:z" else if (c.eql(kind, "seconds")) f = "%Y-%m-%dT%H:%M:%S%:z" else if (c.eql(kind, "ns")) f = "%Y-%m-%dT%H:%M:%S,%N%:z" else c.usageErr("invalid argument {f} for '--iso-8601'", .{c.q(kind)});
    }
    if (rfc_email) f = "%a, %d %b %Y %H:%M:%S %z";
    if (rfc3339) |kind| {
        if (c.eql(kind, "date")) f = "%Y-%m-%d" else if (c.eql(kind, "seconds")) f = "%Y-%m-%d %H:%M:%S%:z" else if (c.eql(kind, "ns")) f = "%Y-%m-%d %H:%M:%S.%N%:z" else c.usageErr("invalid argument {f} for '--rfc-3339'", .{c.q(kind)});
    }
    try c.strftime(c.out, f, tm, t.nsec, t.sec);
    try c.out.writeByte('\n');
    return 0;
}
