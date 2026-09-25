const std = @import("std");
const c = @import("../common.zig");
const timeout = @import("timeout.zig");

pub const help =
    \\Usage: sleep NUMBER[SUFFIX]...
    \\  or:  sleep OPTION
    \\Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),
    \\'m' for minutes, 'h' for hours or 'd' for days.  NUMBER need not be an
    \\integer.  Given two or more arguments, pause for the amount of time
    \\specified by the sum of their values.
    \\
;

pub fn main(args: c.Args) !u8 {
    var total: u64 = 0;
    var any = false;
    var p = c.Parser.init(args, &.{});
    var infinite = false;
    while (p.next()) |o| switch (o) {
        .pos => |a| {
            any = true;
            if (c.eql(a, "inf") or c.eql(a, "infinity")) {
                infinite = true;
                continue;
            }
            const ns = timeout.parseDuration(a) orelse {
                c.warn("invalid time interval {f}", .{c.q(a)});
                c.tryHelp();
                c.exit(1);
            };
            total +|= ns;
        },
        else => p.bad(o),
    };
    if (!any) c.missingOperand();
    if (infinite) while (true) c.sys.nanosleep(std.math.maxInt(u32) * @as(u64, 1_000_000_000));
    c.sys.nanosleep(total);
    return 0;
}
