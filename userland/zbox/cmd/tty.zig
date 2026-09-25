const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: tty [OPTION]...
    \\Print the file name of the terminal connected to standard input.
    \\
    \\  -s, --silent, --quiet   print nothing, only return an exit status
    \\
;

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    var silent = false;
    var p = c.Parser.init(args, &.{ .{ "silent", 's' }, .{ "quiet", 's' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            's' => silent = true,
            else => p.bad(o),
        },
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    if (!c.isatty(0)) {
        if (!silent) try c.out.writeAll("not a tty\n");
        return 1;
    }
    if (silent) return 0;
    var buf: [c.PATH_MAX]u8 = undefined;
    const name = c.sys.readlink("/proc/self/fd/0", &buf) catch "/dev/tty";
    try c.out.print("{s}\n", .{name});
    return 0;
}
