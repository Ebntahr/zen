const c = @import("../common.zig");
const uname = @import("uname.zig");

pub const help =
    \\Usage: arch [OPTION]...
    \\Print machine architecture.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    try c.out.print("{s}\n", .{uname.field(&uname.utsname().machine)});
    return 0;
}
