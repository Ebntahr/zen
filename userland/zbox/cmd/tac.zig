const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: tac [OPTION]... [FILE]...
    \\Write each FILE to standard output, last line first.
    \\
    \\  -b, --before             attach the separator before instead of after
    \\  -s, --separator=STRING   use STRING as the separator instead of newline
    \\
;

pub fn main(args: c.Args) !u8 {
    var before = false;
    var sep: []const u8 = "\n";
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "before", 'b' }, .{ "separator", 's' }, .{ "regex", 'r' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => before = true,
            's' => {
                sep = p.arg();
                if (sep.len == 0) sep = "\x00";
            },
            'r' => {},
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var status: u8 = 0;
    const w = c.out;
    for (files.items) |f| {
        const data = blk: {
            const fd = if (c.eql(f, "-")) @as(i32, 0) else c.sys.open(f, c.O_RDONLY, 0) catch |e| {
                c.warn("failed to open {f} for reading: {s}", .{ c.q(f), c.strerror(e) });
                status = 1;
                continue;
            };
            defer c.closeInput(fd);
            break :blk c.readFdAll(fd) catch |e| {
                c.warn("{f}: read error: {s}", .{ c.qf(f), c.strerror(e) });
                status = 1;
                continue;
            };
        };
        // collect record boundaries
        var recs: std.ArrayList([]const u8) = .empty;
        if (!before) {
            var start: usize = 0;
            while (start < data.len) {
                if (mem.indexOfPos(u8, data, start, sep)) |k| {
                    try recs.append(c.gpa, data[start .. k + sep.len]);
                    start = k + sep.len;
                } else {
                    try recs.append(c.gpa, data[start..]);
                    break;
                }
            }
            var i = recs.items.len;
            while (i > 0) {
                i -= 1;
                const r = recs.items[i];
                try w.writeAll(r);
                // GNU: a final record without separator is output as is
            }
        } else {
            var positions: std.ArrayList(usize) = .empty;
            var k: usize = 0;
            while (mem.indexOfPos(u8, data, k, sep)) |pos| {
                try positions.append(c.gpa, pos);
                k = pos + sep.len;
            }
            var end = data.len;
            var i = positions.items.len;
            while (i > 0) {
                i -= 1;
                try w.writeAll(data[positions.items[i]..end]);
                end = positions.items[i];
            }
            if (end > 0) try w.writeAll(data[0..end]);
        }
    }
    return status;
}
