const c = @import("../common.zig");
const who = @import("who.zig");

pub const help =
    \\Usage: logname [OPTION]
    \\Print the user's login name.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    const name = who.loginName() orelse c.fatal("no login name", .{});
    try c.out.print("{s}\n", .{name});
    return 0;
}
