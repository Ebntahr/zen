const c = @import("../common.zig");

pub const help =
    \\Usage: unlink FILE
    \\Call the unlink function to remove the specified FILE.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    var op: ?[]const u8 = null;
    while (p.next()) |o| switch (o) {
        .pos => |a| {
            if (op != null) c.usageErr("extra operand {f}", .{c.q(a)});
            op = a;
        },
        else => p.bad(o),
    };
    const f = op orelse c.missingOperand();
    c.sys.unlink(f) catch |e| c.fatal("cannot unlink {f}: {s}", .{ c.q(f), c.strerror(e) });
    return 0;
}
