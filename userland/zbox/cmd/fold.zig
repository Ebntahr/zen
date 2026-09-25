const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: fold [OPTION]... [FILE]...
    \\Wrap input lines in each FILE, writing to standard output.
    \\
    \\  -b, --bytes         count bytes rather than columns
    \\  -s, --spaces        break at spaces
    \\  -w, --width=WIDTH   use WIDTH columns instead of 80
    \\
;

var bytes_mode = false;

fn adv(col: usize, ch: u8) usize {
    if (bytes_mode) return col + 1;
    return switch (ch) {
        '\t' => (col / 8 + 1) * 8,
        8 => if (col > 0) col - 1 else 0,
        '\r' => 0,
        else => col + 1,
    };
}

pub fn main(args_in: c.Args) !u8 {
    var args = args_in;
    var width: usize = 80;
    var spaces = false;
    // obsolete -NUM
    var list: std.ArrayList([:0]const u8) = .empty;
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and std.ascii.isDigit(a[1])) {
            try list.append(c.gpa, try std.fmt.allocPrintSentinel(c.gpa, "-w{s}", .{a[1..]}, 0));
        } else try list.append(c.gpa, a);
    }
    args = list.items;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "bytes", 'b' }, .{ "spaces", 's' }, .{ "width", 'w' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => bytes_mode = true,
            's' => spaces = true,
            'w' => {
                const a = p.arg();
                width = @intCast(c.parseUint(a) orelse c.fatal("invalid number of columns: {f}", .{c.q(a)}));
                if (width == 0) c.fatal("invalid number of columns: {f}", .{c.q(a)});
            },
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var status: u8 = 0;
    const w = c.out;
    var buf: std.ArrayList(u8) = .empty;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var r = c.LineReader.init(fd);
        defer r.deinit();
        while (try r.next()) |line| {
            buf.clearRetainingCapacity();
            var col: usize = 0;
            for (line) |ch| {
                var nc = adv(col, ch);
                if (nc > width and buf.items.len > 0 and ch != 8 and ch != '\r') {
                    if (spaces) {
                        // break after last blank
                        var k = buf.items.len;
                        while (k > 0) : (k -= 1) {
                            if (buf.items[k - 1] == ' ' or buf.items[k - 1] == '\t') break;
                        }
                        if (k > 0) {
                            try w.writeAll(buf.items[0..k]);
                            try w.writeByte('\n');
                            const rest = try c.gpa.dupe(u8, buf.items[k..]);
                            defer c.gpa.free(rest);
                            buf.clearRetainingCapacity();
                            try buf.appendSlice(c.gpa, rest);
                            col = 0;
                            for (buf.items) |b| col = adv(col, b);
                            nc = adv(col, ch);
                            if (nc <= width) {
                                try buf.append(c.gpa, ch);
                                col = nc;
                                continue;
                            }
                        }
                    }
                    try w.writeAll(buf.items);
                    try w.writeByte('\n');
                    buf.clearRetainingCapacity();
                    col = 0;
                    nc = adv(0, ch);
                }
                try buf.append(c.gpa, ch);
                col = nc;
            }
            try w.writeAll(buf.items);
            if (r.had_delim) try w.writeByte('\n');
        }
    }
    return status;
}
