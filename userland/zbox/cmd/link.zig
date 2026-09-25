const c = @import("../common.zig");

pub const help =
    \\Usage: link FILE1 FILE2
    \\Call the link function to create a link named FILE2 to an existing FILE1.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    var ops: [2][]const u8 = undefined;
    var n: usize = 0;
    while (p.next()) |o| switch (o) {
        .pos => |a| {
            if (n == 2) c.usageErr("extra operand {f}", .{c.q(a)});
            ops[n] = a;
            n += 1;
        },
        else => p.bad(o),
    };
    if (n == 0) c.missingOperand();
    if (n == 1) c.usageErr("missing operand after {f}", .{c.q(ops[0])});
    c.sys.link(ops[0], ops[1]) catch |e| c.fatal("cannot create link {f} to {f}: {s}", .{ c.q(ops[1]), c.q(ops[0]), c.strerror(e) });
    return 0;
}
