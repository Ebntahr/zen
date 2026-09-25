const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: dirname [OPTION] NAME...
    \\Output each NAME with its last non-slash component and trailing slashes
    \\removed; if NAME contains no /'s, output '.' (meaning the current directory).
    \\
    \\  -z, --zero     end each output line with NUL, not newline
    \\
;

pub fn main(args: c.Args) !u8 {
    var eol: u8 = '\n';
    var names: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "zero", 'z' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'z' => eol = 0,
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    if (names.items.len == 0) c.missingOperand();
    for (names.items) |n| try c.out.print("{s}{c}", .{ c.dirname(n), eol });
    return 0;
}
