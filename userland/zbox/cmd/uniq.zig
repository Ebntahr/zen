const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: uniq [OPTION]... [INPUT [OUTPUT]]
    \\Filter adjacent matching lines from INPUT (or standard input),
    \\writing to OUTPUT (or standard output).
    \\
    \\  -c, --count           prefix lines by the number of occurrences
    \\  -d, --repeated        only print duplicate lines, one for each group
    \\  -D                    print all duplicate lines
    \\  -f, --skip-fields=N   avoid comparing the first N fields
    \\  -i, --ignore-case     ignore differences in case when comparing
    \\  -s, --skip-chars=N    avoid comparing the first N characters
    \\  -u, --unique          only print unique lines
    \\  -z, --zero-terminated  line delimiter is NUL, not newline
    \\  -w, --check-chars=N   compare no more than N characters in lines
    \\
;

var skip_fields: u64 = 0;
var skip_chars: u64 = 0;
var check_chars: ?u64 = null;
var icase = false;

fn keyOf(line: []const u8) []const u8 {
    var i: usize = 0;
    var f: u64 = 0;
    while (f < skip_fields) : (f += 1) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        while (i < line.len and !(line[i] == ' ' or line[i] == '\t')) i += 1;
    }
    i = @min(line.len, i + @as(usize, @intCast(@min(skip_chars, line.len))));
    var k = line[i..];
    if (check_chars) |n| if (n < k.len) {
        k = k[0..@intCast(n)];
    };
    return k;
}

fn same(a: []const u8, b: []const u8) bool {
    const ka = keyOf(a);
    const kb = keyOf(b);
    return if (icase) std.ascii.eqlIgnoreCase(ka, kb) else mem.eql(u8, ka, kb);
}

pub fn main(args: c.Args) !u8 {
    var count = false;
    var repeated = false;
    var all_repeated = false;
    var uniq_only = false;
    var delim: u8 = '\n';
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "count", 'c' },         .{ "repeated", 'd' },    .{ "all-repeated", 'D' }, .{ "skip-fields", 'f' },
        .{ "ignore-case", 'i' },   .{ "skip-chars", 's' },  .{ "unique", 'u' },       .{ "zero-terminated", 'z' },
        .{ "check-chars", 'w' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => count = true,
            'd' => repeated = true,
            'D' => all_repeated = true,
            'f' => skip_fields = c.parseUint(p.arg()) orelse c.fatal("invalid number of fields to skip", .{}),
            'i' => icase = true,
            's' => skip_chars = c.parseUint(p.arg()) orelse c.fatal("invalid number of bytes to skip", .{}),
            'u' => uniq_only = true,
            'z' => delim = 0,
            'w' => check_chars = c.parseUint(p.arg()) orelse c.fatal("invalid number of bytes to compare", .{}),
            else => p.bad(o),
        },
        .pos => |a| try ops.append(c.gpa, a),
        else => p.bad(o),
    };
    if (ops.items.len > 2) c.usageErr("extra operand {f}", .{c.q(ops.items[2])});
    if (count and all_repeated) {
        c.warn("printing all duplicated lines and repeat counts is meaningless", .{});
        c.tryHelp();
        c.exit(1);
    }
    const in_name = if (ops.items.len > 0) ops.items[0] else "-";
    const fd = c.openInput(in_name) orelse return 1;
    var w = c.out;
    var ofw: std.fs.File.Writer = undefined;
    var obuf: [16384]u8 = undefined;
    if (ops.items.len == 2 and !c.eql(ops.items[1], "-")) {
        const ofd = c.sys.open(ops.items[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666) catch |e| {
            c.fatal("{s}: {s}", .{ ops.items[1], c.strerror(e) });
        };
        ofw = (std.fs.File{ .handle = ofd }).writerStreaming(&obuf);
        w = &ofw.interface;
    }
    var r = c.LineReader.init(fd);
    r.delim = delim;
    var prev: std.ArrayList(u8) = .empty;
    var have_prev = false;
    var n: u64 = 0;
    var group_printed = false;
    const Emit = struct {
        fn f(wr: *std.Io.Writer, line: []const u8, cnt: u64, d: u8, show_count: bool) !void {
            if (show_count) {
                var b: [24]u8 = undefined;
                try c.padLeft(wr, c.fmtBuf(&b, "{d}", .{cnt}), 7);
                try wr.writeByte(' ');
            }
            try wr.writeAll(line);
            try wr.writeByte(d);
        }
    };
    while (true) {
        const line = (try r.next()) orelse break;
        if (have_prev and same(prev.items, line)) {
            n += 1;
            if (all_repeated) {
                if (!group_printed) {
                    try Emit.f(w, prev.items, 0, delim, false);
                    group_printed = true;
                }
                try Emit.f(w, line, 0, delim, false);
            }
            continue;
        }
        if (have_prev and !all_repeated) {
            if ((n > 1 and !uniq_only) or (n == 1 and !repeated)) {
                if (!(repeated and n == 1) and !(uniq_only and n > 1)) try Emit.f(w, prev.items, n, delim, count);
            }
        }
        prev.clearRetainingCapacity();
        try prev.appendSlice(c.gpa, line);
        have_prev = true;
        n = 1;
        group_printed = false;
    }
    if (have_prev and !all_repeated) {
        if (!(repeated and n == 1) and !(uniq_only and n > 1)) try Emit.f(w, prev.items, n, delim, count);
    }
    try w.flush();
    c.closeInput(fd);
    return 0;
}
