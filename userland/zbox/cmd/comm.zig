const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: comm [OPTION]... FILE1 FILE2
    \\Compare sorted files FILE1 and FILE2 line by line.
    \\
    \\With no options, produce three-column output.  Column one contains
    \\lines unique to FILE1, column two contains lines unique to FILE2,
    \\and column three contains lines common to both files.
    \\
    \\  -1                      suppress column 1 (lines unique to FILE1)
    \\  -2                      suppress column 2 (lines unique to FILE2)
    \\  -3                      suppress column 3 (lines that appear in both files)
    \\      --check-order       check that the input is correctly sorted
    \\      --nocheck-order     do not check that the input is correctly sorted
    \\      --output-delimiter=STR  separate columns with STR
    \\      --total             output a summary
    \\  -z, --zero-terminated   line delimiter is NUL, not newline
    \\
;

pub fn main(args: c.Args) !u8 {
    var show = [3]bool{ true, true, true };
    var odelim: []const u8 = "\t";
    var eol: u8 = '\n';
    var total = false;
    var check_order = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "check-order", 0 }, .{ "nocheck-order", 0 }, .{ "output-delimiter", 0 }, .{ "total", 0 }, .{ "zero-terminated", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            '1' => show[0] = false,
            '2' => show[1] = false,
            '3' => show[2] = false,
            'z' => eol = 0,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "check-order")) check_order = true else if (c.eql(n, "nocheck-order")) check_order = false else if (c.eql(n, "output-delimiter")) odelim = p.arg() else if (c.eql(n, "total")) total = true else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len < 2) {
        if (files.items.len == 0) c.usageErr("missing operand", .{});
        c.usageErr("missing operand after {f}", .{c.q(files.items[0])});
    }
    if (files.items.len > 2) c.usageErr("extra operand {f}", .{c.q(files.items[2])});
    const d1 = c.readInput(files.items[0]) orelse return 1;
    const d2 = c.readInput(files.items[1]) orelse return 1;
    const a = c.splitLines(d1, eol);
    const b = c.splitLines(d2, eol);
    var i: usize = 0;
    var j: usize = 0;
    const w = c.out;
    var counts = [3]u64{ 0, 0, 0 };
    const Out = struct {
        fn col(wr: *std.Io.Writer, s: [3]bool, k: usize, line: []const u8, od: []const u8, e: u8) !void {
            if (!s[k]) return;
            var n: usize = 0;
            while (n < k) : (n += 1) if (s[n]) try wr.writeAll(od);
            try wr.writeAll(line);
            try wr.writeByte(e);
        }
    };
    var status: u8 = 0;
    var warned = [2]bool{ false, false };
    while (i < a.len or j < b.len) {
        if (check_order or true) {
            if (i > 0 and i < a.len and mem.order(u8, a[i - 1], a[i]) == .gt and !warned[0]) {
                warned[0] = true;
                c.warn("file 1 is not in sorted order", .{});
                status = 1;
                if (check_order) break;
            }
            if (j > 0 and j < b.len and mem.order(u8, b[j - 1], b[j]) == .gt and !warned[1]) {
                warned[1] = true;
                c.warn("file 2 is not in sorted order", .{});
                status = 1;
                if (check_order) break;
            }
        }
        if (j >= b.len or (i < a.len and mem.order(u8, a[i], b[j]) == .lt)) {
            try Out.col(w, show, 0, a[i], odelim, eol);
            counts[0] += 1;
            i += 1;
        } else if (i >= a.len or mem.order(u8, a[i], b[j]) == .gt) {
            try Out.col(w, show, 1, b[j], odelim, eol);
            counts[1] += 1;
            j += 1;
        } else {
            try Out.col(w, show, 2, a[i], odelim, eol);
            counts[2] += 1;
            i += 1;
            j += 1;
        }
    }
    if (total) try w.print("{d}{s}{d}{s}{d}{s}total{c}", .{ counts[0], odelim, counts[1], odelim, counts[2], odelim, eol });
    if (!check_order and (warned[0] or warned[1])) c.warn("input is not in sorted order", .{});
    return status;
}
