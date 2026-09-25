const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: basename NAME [SUFFIX]
    \\  or:  basename OPTION... NAME...
    \\Print NAME with any leading directory components removed.
    \\If specified, also remove a trailing SUFFIX.
    \\
    \\  -a, --multiple       support multiple arguments and treat each as a NAME
    \\  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a
    \\  -z, --zero           end each output line with NUL, not newline
    \\
;

fn strip(name: []const u8, suffix: ?[]const u8) []const u8 {
    const b = c.basename(name);
    if (suffix) |s| {
        if (s.len > 0 and b.len > s.len and std.mem.endsWith(u8, b, s)) return b[0 .. b.len - s.len];
    }
    return b;
}

pub fn main(args: c.Args) !u8 {
    var multiple = false;
    var suffix: ?[]const u8 = null;
    var eol: u8 = '\n';
    var names: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "multiple", 'a' }, .{ "suffix", 's' }, .{ "zero", 'z' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => multiple = true,
            's' => {
                suffix = p.arg();
                multiple = true;
            },
            'z' => eol = 0,
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    if (names.items.len == 0) c.missingOperand();
    if (!multiple) {
        if (names.items.len > 2) c.usageErr("extra operand {f}", .{c.q(names.items[2])});
        const s = if (names.items.len == 2) names.items[1] else null;
        try c.out.print("{s}{c}", .{ strip(names.items[0], s), eol });
        return 0;
    }
    for (names.items) |n| try c.out.print("{s}{c}", .{ strip(n, suffix), eol });
    return 0;
}
