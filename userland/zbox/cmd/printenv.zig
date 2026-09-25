const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: printenv [OPTION]... [VARIABLE]...
    \\Print the values of the specified environment VARIABLE(s).
    \\If no VARIABLE is specified, print name and value pairs for them all.
    \\
    \\  -0, --null     end each output line with NUL, not newline
    \\
;

pub fn main(args: c.Args) !u8 {
    var eol: u8 = '\n';
    var names: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "null", '0' }});
    c.usage_status = 2;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            '0' => eol = 0,
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    if (names.items.len == 0) {
        for (std.os.environ) |e| try c.out.print("{s}{c}", .{ mem.span(e), eol });
        return 0;
    }
    var status: u8 = 0;
    for (names.items) |n| {
        if (mem.indexOfScalar(u8, n, '=') != null) {
            status = 1;
            continue;
        }
        if (c.getenv(n)) |v| try c.out.print("{s}{c}", .{ v, eol }) else status = 1;
    }
    return status;
}
