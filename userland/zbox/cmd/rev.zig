const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: rev [options] [file ...]
    \\Reverse lines characterwise.
    \\
    \\  -0, --zero     zero termination, use NUL as line delimiter
    \\
;

pub fn main(args: c.Args) !u8 {
    var delim: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "zero", '0' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            '0' => delim = 0,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var status: u8 = 0;
    var tmp: std.ArrayList(u8) = .empty;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var r = c.LineReader.init(fd);
        defer r.deinit();
        r.delim = delim;
        while (try r.next()) |line| {
            tmp.clearRetainingCapacity();
            // reverse by UTF-8 code points
            var i: usize = line.len;
            while (i > 0) {
                var s = i - 1;
                while (s > 0 and line[s] & 0xC0 == 0x80 and i - s < 4) s -= 1;
                if (line[s] & 0xC0 == 0x80 or (std.unicode.utf8ByteSequenceLength(line[s]) catch 1) != i - s) s = i - 1;
                try tmp.appendSlice(c.gpa, line[s..i]);
                i = s;
            }
            try c.out.writeAll(tmp.items);
            if (r.had_delim) try c.out.writeByte(delim);
        }
    }
    return status;
}
