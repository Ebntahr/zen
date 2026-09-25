const c = @import("../common.zig");

pub const help =
    \\Usage: whoami [OPTION]...
    \\Print the user name associated with the current effective user ID.
    \\Same as id -un.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    const uid = c.sys.geteuid();
    const u = c.userByUid(uid) orelse c.fatal("cannot find name for user ID {d}", .{uid});
    try c.out.print("{s}\n", .{u.name});
    return 0;
}
