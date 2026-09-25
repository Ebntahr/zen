const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: column [options] [<file>...]
    \\Columnate lists.
    \\
    \\  -t, --table                      create a table
    \\  -s, --separator <string>         possible table delimiters
    \\  -o, --output-separator <string>  columns separator for table output (default "  ")
    \\  -c, --output-width <width>       width of output in number of characters
    \\  -x, --fillrows                   fill rows before columns
    \\  -R, --table-right <columns>      right align text in these columns
    \\  -N, --table-columns <names>      comma separated columns names (header)
    \\
;

pub fn main(args: c.Args) !u8 {
    var table = false;
    var seps: []const u8 = " \t";
    var osep: []const u8 = "  ";
    var width: ?usize = null;
    var fillrows = false;
    var right_cols: []const u8 = "";
    var header: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "table", 't' },        .{ "separator", 's' },    .{ "output-separator", 'o' },
        .{ "output-width", 'c' }, .{ "fillrows", 'x' },     .{ "table-right", 'R' },
        .{ "table-columns", 'N' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            't' => table = true,
            's' => seps = p.arg(),
            'o' => osep = p.arg(),
            'c' => width = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid columns argument", .{})),
            'x' => fillrows = true,
            'R' => right_cols = p.arg(),
            'N' => header = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var lines: std.ArrayList([]const u8) = .empty;
    var status: u8 = 0;
    for (files.items) |f| {
        const data = c.readInput(f) orelse {
            status = 1;
            continue;
        };
        for (c.splitLines(data, '\n')) |l| {
            if (mem.trim(u8, l, " \t").len == 0) continue; // column ignores empty lines
            try lines.append(c.gpa, l);
        }
    }
    const w = c.out;
    if (table) {
        var rows: std.ArrayList([][]const u8) = .empty;
        if (header) |h| {
            var cells: std.ArrayList([]const u8) = .empty;
            var it = mem.splitScalar(u8, h, ',');
            while (it.next()) |x| try cells.append(c.gpa, x);
            try rows.append(c.gpa, cells.items);
        }
        var maxcols: usize = 0;
        for (lines.items) |l| {
            var cells: std.ArrayList([]const u8) = .empty;
            var it = mem.tokenizeAny(u8, l, seps);
            while (it.next()) |x| try cells.append(c.gpa, x);
            try rows.append(c.gpa, cells.items);
        }
        for (rows.items) |r| maxcols = @max(maxcols, r.len);
        var widths = try c.gpa.alloc(usize, maxcols);
        @memset(widths, 0);
        for (rows.items) |r| for (r, 0..) |cell, i| {
            widths[i] = @max(widths[i], c.displayWidth(cell));
        };
        var right = try c.gpa.alloc(bool, maxcols);
        @memset(right, false);
        var it = mem.tokenizeScalar(u8, right_cols, ',');
        while (it.next()) |x| if (c.parseUint(x)) |n| if (n >= 1 and n <= maxcols) {
            right[@intCast(n - 1)] = true;
        };
        for (rows.items) |r| {
            for (r, 0..) |cell, i| {
                const last = i + 1 == r.len;
                const pad = widths[i] - c.displayWidth(cell);
                if (right[i]) try w.splatByteAll(' ', pad);
                try w.writeAll(cell);
                if (!last) {
                    if (!right[i]) try w.splatByteAll(' ', pad);
                    try w.writeAll(osep);
                }
            }
            try w.writeByte('\n');
        }
        return status;
    }
    if (lines.items.len == 0) return status;
    const termw = width orelse c.termWidth();
    var maxlen: usize = 0;
    for (lines.items) |l| maxlen = @max(maxlen, c.displayWidth(l));
    maxlen = (maxlen + 8) & ~@as(usize, 7);
    var numcols = termw / maxlen;
    if (numcols == 0) numcols = 1;
    const n = lines.items.len;
    if (fillrows) {
        var chcnt: usize = 0;
        var col: usize = 0;
        for (lines.items) |l| {
            try w.writeAll(l);
            chcnt += c.displayWidth(l);
            col += 1;
            if (col == numcols) {
                try w.writeByte('\n');
                col = 0;
                chcnt = 0;
                continue;
            }
            const endcol = col * maxlen;
            while (true) {
                const cnt = (chcnt + 8) & ~@as(usize, 7);
                if (cnt > endcol) break;
                try w.writeByte('\t');
                chcnt = cnt;
            }
        }
        if (col != 0) try w.writeByte('\n');
        return status;
    }
    var numrows = n / numcols;
    if (n % numcols != 0) numrows += 1;
    var row: usize = 0;
    while (row < numrows) : (row += 1) {
        var endcol = maxlen;
        var base = row;
        var chcnt: usize = 0;
        var col: usize = 0;
        while (col < numcols) : (col += 1) {
            try w.writeAll(lines.items[base]);
            chcnt += c.displayWidth(lines.items[base]);
            base += numrows;
            if (base >= n) break;
            while (true) {
                const cnt = (chcnt + 8) & ~@as(usize, 7);
                if (cnt > endcol) break;
                try w.writeByte('\t');
                chcnt = cnt;
            }
            endcol += maxlen;
        }
        try w.writeByte('\n');
    }
    return status;
}
