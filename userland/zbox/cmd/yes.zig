const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: yes [STRING]...
    \\  or:  yes OPTION
    \\Repeatedly output a line with all specified STRING(s), or 'y'.
    \\
;

pub fn main(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    var words: std.ArrayList([]const u8) = .empty;
    while (p.next()) |o| switch (o) {
        .pos => |a| try words.append(c.gpa, a),
        else => p.bad(o),
    };
    var line: std.ArrayList(u8) = .empty;
    if (words.items.len == 0) try line.appendSlice(c.gpa, "y");
    for (words.items, 0..) |w, i| {
        if (i > 0) try line.append(c.gpa, ' ');
        try line.appendSlice(c.gpa, w);
    }
    try line.append(c.gpa, '\n');
    // Fill a large buffer with repeated lines, then write it forever.
    var buf: std.ArrayList(u8) = .empty;
    while (buf.items.len < 8192) try buf.appendSlice(c.gpa, line.items);
    while (true) {
        c.sys.writeAll(1, buf.items) catch |e| {
            if (e == error.PIPE) return 1;
            c.fatal("standard output: {s}", .{c.strerror(e)});
        };
    }
}
