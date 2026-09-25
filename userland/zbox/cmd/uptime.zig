const std = @import("std");
const c = @import("../common.zig");
const pr = @import("../procfs.zig");
const who = @import("who.zig");
const mem = std.mem;

pub const help =
    \\Usage: uptime [options]
    \\Tell how long the system has been running.
    \\
    \\  -p, --pretty   show uptime in pretty format
    \\  -s, --since    system up since
    \\
;

pub fn main(args: c.Args) !u8 {
    var pretty = false;
    var since = false;
    var p = c.Parser.init(args, &.{ .{ "pretty", 'p' }, .{ "since", 's' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'p' => pretty = true,
            's' => since = true,
            else => p.bad(o),
        },
        else => p.bad(o),
    };
    const up = pr.uptimeSecs();
    const secs: u64 = @intFromFloat(up);
    const w = c.out;
    const nowt = c.now().sec;
    if (since) {
        const t = nowt - @as(i64, @intCast(secs));
        try c.strftime(w, "%Y-%m-%d %H:%M:%S\n", c.localtime(t), 0, t);
        return 0;
    }
    const days = secs / 86400;
    const hours = (secs / 3600) % 24;
    const mins = (secs / 60) % 60;
    if (pretty) {
        try w.writeAll("up ");
        var first = true;
        const parts = [_]struct { u64, []const u8 }{ .{ secs / (86400 * 7), "week" }, .{ days % 7, "day" }, .{ hours, "hour" }, .{ mins, "minute" } };
        for (parts) |pt| {
            if (pt[0] == 0) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{d} {s}{s}", .{ pt[0], pt[1], if (pt[0] == 1) "" else "s" });
        }
        if (first) try w.writeAll("0 minutes");
        try w.writeByte('\n');
        return 0;
    }
    try c.strftime(w, " %H:%M:%S up ", c.localtime(nowt), 0, nowt);
    if (days > 0) try w.print("{d} day{s}, ", .{ days, if (days == 1) "" else "s" });
    if (hours > 0) try w.print("{d: >2}:{d:0>2}, ", .{ hours, mins }) else try w.print("{d} min, ", .{mins});
    const nusers = who.countUsers();
    try w.print(" {d} user{s},  load average: ", .{ nusers, if (nusers > 1) "s" else "" });
    var buf: [256]u8 = undefined;
    if (c.readSmall("/proc/loadavg", &buf)) |la| {
        var it = mem.tokenizeAny(u8, la, " \n");
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            const f = it.next() orelse "0.00";
            if (k > 0) try w.writeAll(", ");
            try w.writeAll(f);
        }
    } else try w.writeAll("0.00, 0.00, 0.00");
    try w.writeByte('\n');
    return 0;
}
