const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage:
    \\       xxd [options] [infile [outfile]]
    \\    or
    \\       xxd -r [-s [-]offset] [-c cols] [-ps] [infile [outfile]]
    \\Options:
    \\    -b          binary digit dump. Default hex.
    \\    -c cols     format <cols> octets per line. Default 16 (-i: 12, -ps: 30).
    \\    -g bytes    number of octets per group in normal output. Default 2.
    \\    -i          output in C include file style.
    \\    -l len      stop after <len> octets.
    \\    -n name     set the variable name used in C include output (-i).
    \\    -p          output in postscript plain hexdump style.
    \\    -r          reverse operation: convert (or patch) hexdump into binary.
    \\    -s [+][-]seek  start at <seek> bytes abs. (or rel.) infile offset.
    \\    -u          use upper case hex letters.
    \\
;

fn hexVal(ch: u8) ?u8 {
    return std.fmt.charToDigit(ch, 16) catch null;
}

fn reverse(data: []const u8, plain: bool, out_fd: i32) !void {
    var outbuf: std.ArrayList(u8) = .empty;
    if (plain) {
        var hi: ?u8 = null;
        for (data) |ch| {
            const v = hexVal(ch) orelse continue;
            if (hi) |h| {
                try outbuf.append(c.gpa, h * 16 + v);
                hi = null;
            } else hi = v;
        }
    } else {
        var lines = mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const off = std.fmt.parseInt(usize, mem.trim(u8, line[0..colon], " "), 16) catch continue;
            if (outbuf.items.len < off) try outbuf.appendNTimes(c.gpa, 0, off - outbuf.items.len);
            outbuf.shrinkRetainingCapacity(off);
            var rest = line[colon + 1 ..];
            // hex area ends at two consecutive spaces
            if (mem.indexOf(u8, rest, "  ")) |e| rest = rest[0..e];
            var hi: ?u8 = null;
            for (rest) |ch| {
                if (ch == ' ') {
                    hi = null;
                    continue;
                }
                const v = hexVal(ch) orelse break;
                if (hi) |h| {
                    try outbuf.append(c.gpa, h * 16 + v);
                    hi = null;
                } else hi = v;
            }
        }
    }
    try c.sys.writeAll(out_fd, outbuf.items);
}

pub fn main(args: c.Args) !u8 {
    var bits = false;
    var cols: ?usize = null;
    var group: ?usize = null;
    var include = false;
    var limit: ?usize = null;
    var name: ?[]const u8 = null;
    var plain = false;
    var rev = false;
    var seek: usize = 0;
    var upper = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "bits", 'b' }, .{ "cols", 'c' }, .{ "groupsize", 'g' }, .{ "include", 'i' }, .{ "len", 'l' }, .{ "name", 'n' },
        .{ "ps", 'p' }, .{ "postscript", 'p' }, .{ "plain", 'p' }, .{ "revert", 'r' }, .{ "seek", 's' }, .{ "uppercase", 'u' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => bits = true,
            'c' => cols = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid number of columns", .{})),
            'g' => group = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid group size", .{})),
            'i' => include = true,
            'l' => limit = @intCast(c.parseSize(p.arg()) orelse c.fatal("invalid length", .{})),
            'n' => name = p.arg(),
            'p' => plain = true,
            'r' => rev = true,
            's' => {
                var a: []const u8 = p.arg();
                if (a.len > 0 and a[0] == '+') a = a[1..];
                seek = @intCast(if (mem.startsWith(u8, a, "0x")) std.fmt.parseInt(u64, a[2..], 16) catch 0 else c.parseSize(a) orelse c.fatal("invalid seek", .{}));
            },
            'u' => upper = true,
            'a', 'E', 'd' => {},
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    const infile = if (files.items.len > 0) files.items[0] else "-";
    var out_fd: i32 = 1;
    if (files.items.len > 1) {
        out_fd = c.sys.open(files.items[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !rev, .CLOEXEC = true }, 0o666) catch |e| c.fatal("{s}: {s}", .{ files.items[1], c.strerror(e) });
    }
    const all = c.readInput(infile) orelse return 2;
    if (rev) {
        c.flush();
        try reverse(all, plain, out_fd);
        return 0;
    }
    var data = all[@min(seek, all.len)..];
    if (limit) |l| if (l < data.len) {
        data = data[0..l];
    };
    var aw: std.Io.Writer.Allocating = .init(c.gpa);
    const w = &aw.writer;
    const hexfmt = struct {
        fn f(wr: *std.Io.Writer, b: u8, up: bool) !void {
            if (up) try wr.print("{X:0>2}", .{b}) else try wr.print("{x:0>2}", .{b});
        }
    }.f;
    if (include) {
        var var_name: std.ArrayList(u8) = .empty;
        const src = name orelse (if (c.eql(infile, "-")) "" else infile);
        for (src) |ch| try var_name.append(c.gpa, if (std.ascii.isAlphanumeric(ch)) ch else '_');
        if (var_name.items.len > 0 and std.ascii.isDigit(var_name.items[0])) try var_name.insert(c.gpa, 0, '_');
        const per = cols orelse 12;
        if (var_name.items.len > 0) try w.print("unsigned char {s}[] = {{\n", .{var_name.items});
        var i: usize = 0;
        while (i < data.len) : (i += per) {
            try w.writeAll(" ");
            const end = @min(i + per, data.len);
            for (data[i..end], i..) |b, k| {
                try w.writeAll(if (upper) " 0X" else " 0x");
                try hexfmt(w, b, upper);
                if (k + 1 < data.len) try w.writeByte(',');
            }
            try w.writeByte('\n');
        }
        if (var_name.items.len > 0) try w.print("}};\nunsigned int {s}_len = {d};\n", .{ var_name.items, data.len });
    } else if (plain) {
        const per = cols orelse 30;
        var i: usize = 0;
        while (i < data.len) : (i += per) {
            for (data[i..@min(i + per, data.len)]) |b| try hexfmt(w, b, upper);
            try w.writeByte('\n');
        }
    } else {
        const per = cols orelse 16;
        const grp = group orelse (if (bits) @as(usize, 1) else 2);
        const byte_w: usize = if (bits) 8 else 2;
        const hex_width = per * byte_w + (if (grp == 0) 0 else (per + grp - 1) / grp);
        var i: usize = 0;
        while (i < data.len) : (i += per) {
            const line = data[i..@min(i + per, data.len)];
            try w.print("{x:0>8}: ", .{seek + i});
            var col: usize = 0;
            for (line, 0..) |b, k| {
                if (bits) {
                    var bit: u4 = 8;
                    while (bit > 0) {
                        bit -= 1;
                        try w.writeByte(if ((b >> @intCast(bit)) & 1 == 1) '1' else '0');
                    }
                } else try hexfmt(w, b, upper);
                col += byte_w;
                if (grp != 0 and (k + 1) % grp == 0) {
                    try w.writeByte(' ');
                    col += 1;
                }
            }
            while (col < hex_width) : (col += 1) try w.writeByte(' ');
            try w.writeByte(' ');
            for (line) |b| try w.writeByte(if (b >= 0x20 and b < 0x7f) b else '.');
            try w.writeByte('\n');
        }
    }
    if (out_fd == 1) {
        try c.out.writeAll(aw.written());
    } else try c.sys.writeAll(out_fd, aw.written());
    return 0;
}
