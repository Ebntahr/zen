const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: strings [option(s)] [file(s)]
    \\ Display printable strings in [file(s)] (stdin by default)
    \\  -a - --all                Scan the entire file (default)
    \\  -f --print-file-name      Print the name of the file before each string
    \\  -n --bytes=<number>       Locate & print any sequence of at least <number>
    \\  -<number>                   displayable characters.  (The default is 4).
    \\  -t --radix={o,d,x}        Print the location of the string in base 8, 10 or 16
    \\  -o                        An alias for --radix=o
    \\  -s --output-separator=<string> String used to separate strings in output.
    \\
;

pub fn main(args_in: c.Args) !u8 {
    var args = args_in;
    var min: usize = 4;
    var radix: u8 = 0;
    var print_name = false;
    var osep: []const u8 = "\n";
    var list: std.ArrayList([:0]const u8) = .empty;
    for (args) |a| {
        if (a.len > 1 and a[0] == '-' and std.ascii.isDigit(a[1])) {
            try list.append(c.gpa, try std.fmt.allocPrintSentinel(c.gpa, "-n{s}", .{a[1..]}, 0));
        } else try list.append(c.gpa, a);
    }
    args = list.items;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "all", 'a' }, .{ "print-file-name", 'f' }, .{ "bytes", 'n' }, .{ "radix", 't' }, .{ "output-separator", 's' },
        .{ "encoding", 'e' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {},
            'f' => print_name = true,
            'n' => min = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid minimum string length", .{})),
            't' => {
                const r = p.arg();
                if (r.len != 1 or (r[0] != 'o' and r[0] != 'd' and r[0] != 'x')) c.fatal("invalid radix", .{});
                radix = r[0];
            },
            'o' => radix = 'o',
            's' => osep = p.arg(),
            'e' => _ = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (min == 0) c.fatal("invalid minimum string length 0", .{});
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var status: u8 = 0;
    const w = c.out;
    var cur: std.ArrayList(u8) = .empty;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var buf: [65536]u8 = undefined;
        var off: u64 = 0;
        var start: u64 = 0;
        cur.clearRetainingCapacity();
        while (true) {
            const n = try c.sys.read(fd, &buf);
            const done = n == 0;
            var i: usize = 0;
            while (i < n or (done and i == 0)) : (i += 1) {
                const printable = !done and ((buf[i] >= 0x20 and buf[i] < 0x7f) or buf[i] == '\t');
                if (printable) {
                    if (cur.items.len == 0) start = off + i;
                    try cur.append(c.gpa, buf[i]);
                } else {
                    if (cur.items.len >= min) {
                        if (print_name) try w.print("{s}: ", .{f});
                        switch (radix) {
                            'o' => try w.print("{o:>7} ", .{start}),
                            'd' => try w.print("{d:>7} ", .{start}),
                            'x' => try w.print("{x:>7} ", .{start}),
                            else => {},
                        }
                        try w.writeAll(cur.items);
                        try w.writeAll(osep);
                    }
                    cur.clearRetainingCapacity();
                }
                if (done) break;
            }
            if (done) break;
            off += n;
        }
    }
    return status;
}
