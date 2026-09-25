const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: hexdump [options] <file>...
    \\Display file contents in hexadecimal, decimal, octal, or ascii.
    \\
    \\  -b              one-byte octal display
    \\  -c              one-byte character display
    \\  -C              canonical hex+ASCII display
    \\  -d              two-byte decimal display
    \\  -o              two-byte octal display
    \\  -x              two-byte hexadecimal display (default)
    \\  -n <length>     interpret only length bytes of input
    \\  -s <offset>     skip offset bytes from the beginning
    \\  -v              display without squeezing similar lines
    \\
;

const Fmt = enum { hex2, canon, oct1, char1, dec2, oct2 };

fn readAllInputs(files: []const []const u8, skip: u64, limit: ?u64) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    for (files) |f| {
        const d = c.readInput(f) orelse c.exit(1);
        try data.appendSlice(c.gpa, d);
    }
    var s = data.items;
    const sk: usize = @intCast(@min(skip, s.len));
    s = s[sk..];
    if (limit) |l| if (l < s.len) {
        s = s[0..@intCast(l)];
    };
    return s;
}

fn charRep(buf: []u8, b: u8) []const u8 {
    return switch (b) {
        0 => "  \\0",
        7 => "  \\a",
        8 => "  \\b",
        9 => "  \\t",
        10 => "  \\n",
        11 => "  \\v",
        12 => "  \\f",
        13 => "  \\r",
        else => if (b >= 0x20 and b < 0x7f) c.fmtBuf(buf, "   {c}", .{b}) else c.fmtBuf(buf, " {o:0>3}", .{b}),
    };
}

pub fn main(args: c.Args) !u8 {
    var fmts: std.ArrayList(Fmt) = .empty;
    var skip: u64 = 0;
    var limit: ?u64 = null;
    var verbose = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "canonical", 'C' }, .{ "length", 'n' }, .{ "skip", 's' }, .{ "no-squeezing", 'v' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => try fmts.append(c.gpa, .oct1),
            'c' => try fmts.append(c.gpa, .char1),
            'C' => try fmts.append(c.gpa, .canon),
            'd' => try fmts.append(c.gpa, .dec2),
            'o' => try fmts.append(c.gpa, .oct2),
            'x' => try fmts.append(c.gpa, .hex2),
            'n' => limit = c.parseSize(p.arg()) orelse c.fatal("invalid length", .{}),
            's' => skip = c.parseSize(p.arg()) orelse c.fatal("invalid offset", .{}),
            'v' => verbose = true,
            'e', 'f' => c.fatal("format strings are not supported", .{}),
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    if (fmts.items.len == 0) try fmts.append(c.gpa, .hex2);
    const data = try readAllInputs(files.items, skip, limit);
    const w = c.out;
    const canon = fmts.items.len == 1 and fmts.items[0] == .canon;
    var off: usize = 0;
    var prev: ?[]const u8 = null;
    var starred = false;
    while (off < data.len) : (off += 16) {
        const line = data[off..@min(off + 16, data.len)];
        if (!verbose and prev != null and line.len == 16 and mem.eql(u8, prev.?, line)) {
            if (!starred) try w.writeAll("*\n");
            starred = true;
            continue;
        }
        starred = false;
        prev = line;
        const base = skip + off;
        for (fmts.items) |f| {
            switch (f) {
                .canon => {
                    try w.print("{x:0>8}  ", .{base});
                    for (0..16) |i| {
                        if (i < line.len) try w.print("{x:0>2} ", .{line[i]}) else try w.writeAll("   ");
                        if (i == 7) try w.writeByte(' ');
                    }
                    try w.writeAll(" |");
                    for (line) |b| try w.writeByte(if (b >= 0x20 and b < 0x7f) b else '.');
                    try w.writeAll("|\n");
                },
                .hex2, .dec2, .oct2 => {
                    try w.print("{x:0>7}", .{base});
                    var i: usize = 0;
                    while (i < line.len) : (i += 2) {
                        const v: u16 = @as(u16, line[i]) | (if (i + 1 < line.len) @as(u16, line[i + 1]) << 8 else 0);
                        switch (f) {
                            .hex2 => try w.print(" {x:0>4}", .{v}),
                            .dec2 => try w.print("   {d:0>5}", .{v}),
                            else => try w.print("  {o:0>6}", .{v}),
                        }
                    }
                    try w.writeByte('\n');
                },
                .oct1 => {
                    try w.print("{x:0>7}", .{base});
                    for (line) |b| try w.print(" {o:0>3}", .{b});
                    try w.writeByte('\n');
                },
                .char1 => {
                    try w.print("{x:0>7}", .{base});
                    for (line) |b| {
                        var cb: [8]u8 = undefined;
                        try w.writeAll(charRep(&cb, b));
                    }
                    try w.writeByte('\n');
                },
            }
        }
    }
    if (data.len > 0 or true) {
        if (canon) try w.print("{x:0>8}\n", .{skip + data.len}) else try w.print("{x:0>7}\n", .{skip + data.len});
    }
    return 0;
}
