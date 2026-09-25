const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: split [OPTION]... [FILE [PREFIX]]
    \\Output pieces of FILE to PREFIXaa, PREFIXab, ...;
    \\default size is 1000 lines, and default PREFIX is 'x'.
    \\
    \\  -a, --suffix-length=N   generate suffixes of length N (default 2)
    \\      --additional-suffix=SUFFIX  append an additional SUFFIX to file names
    \\  -b, --bytes=SIZE        put SIZE bytes per output file
    \\  -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file
    \\  -d                      use numeric suffixes starting at 0, not alphabetic
    \\      --numeric-suffixes[=FROM]  same as -d, but allow setting the start value
    \\  -x                      use hex suffixes starting at 0, not alphabetic
    \\  -l, --lines=NUMBER      put NUMBER lines/records per output file
    \\  -n, --number=CHUNKS     generate CHUNKS output files
    \\  -t, --separator=SEP     use SEP instead of newline as the record separator
    \\      --verbose           print a diagnostic just before each
    \\                            output file is opened
    \\
;

var prefix: []const u8 = "x";
var add_suffix: []const u8 = "";
var suffix_len: usize = 2;
var numeric: u8 = 0; // 0 alpha, 'd' decimal, 'x' hex
var start_num: u64 = 0;
var verbose = false;
var file_index: u64 = 0;
var auto_len = true;

fn nextName() []const u8 {
    const digits: []const u8 = switch (numeric) {
        'd' => "0123456789",
        'x' => "0123456789abcdef",
        else => "abcdefghijklmnopqrstuvwxyz",
    };
    const base: u64 = digits.len;
    var n = file_index + start_num;
    file_index += 1;
    // capacity check
    var cap: u64 = 1;
    var k: usize = 0;
    while (k < suffix_len) : (k += 1) cap = cap *| base;
    if (n >= cap) c.fatal("output file suffixes exhausted", .{});
    var buf = c.gpa.alloc(u8, suffix_len) catch c.oom();
    var i = suffix_len;
    while (i > 0) {
        i -= 1;
        buf[i] = digits[@intCast(n % base)];
        n /= base;
    }
    return mem.concat(c.gpa, u8, &.{ prefix, buf, add_suffix }) catch c.oom();
}

fn openOut() i32 {
    const name = nextName();
    if (verbose) c.out.print("creating file {f}\n", .{c.q(name)}) catch {};
    return c.sys.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666) catch |e| c.fatal("{s}: {s}", .{ name, c.strerror(e) });
}

pub fn main(args: c.Args) !u8 {
    var lines: ?u64 = null;
    var bytes: ?u64 = null;
    var line_bytes: ?u64 = null;
    var chunks: ?u64 = null;
    var sep: u8 = '\n';
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "suffix-length", 'a' }, .{ "additional-suffix", 0 }, .{ "bytes", 'b' }, .{ "line-bytes", 'C' },
        .{ "numeric-suffixes", 0 }, .{ "hex-suffixes", 0 }, .{ "lines", 'l' }, .{ "number", 'n' },
        .{ "separator", 't' }, .{ "verbose", 0 }, .{ "elide-empty-files", 'e' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {
                suffix_len = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid suffix length", .{}));
                auto_len = false;
            },
            'b' => bytes = c.parseSize(p.arg()) orelse c.fatal("invalid number of bytes", .{}),
            'C' => line_bytes = c.parseSize(p.arg()) orelse c.fatal("invalid number of bytes", .{}),
            'd' => numeric = 'd',
            'x' => numeric = 'x',
            'l' => lines = c.parseUint(p.arg()) orelse c.fatal("invalid number of lines", .{}),
            'n' => chunks = c.parseUint(p.arg()) orelse c.fatal("invalid number of chunks", .{}),
            't' => {
                const s = p.arg();
                sep = if (c.eql(s, "\\0")) 0 else if (s.len == 1) s[0] else c.fatal("multi-character separator {f}", .{c.q(s)});
            },
            'e', 'u' => {},
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "additional-suffix")) add_suffix = p.arg() else if (c.eql(n, "numeric-suffixes")) {
                numeric = 'd';
                if (p.optArg()) |v| start_num = c.parseUint(v) orelse 0;
            } else if (c.eql(n, "hex-suffixes")) {
                numeric = 'x';
                if (p.optArg()) |v| start_num = c.parseUint(v) orelse 0;
            } else if (c.eql(n, "verbose")) verbose = true else p.bad(o);
        },
        .pos => |a| try ops.append(c.gpa, a),
    };
    if (ops.items.len > 2) c.usageErr("extra operand {f}", .{c.q(ops.items[2])});
    const in_name = if (ops.items.len > 0) ops.items[0] else "-";
    if (ops.items.len > 1) prefix = ops.items[1];
    const data = c.readInput(in_name) orelse return 1;
    if (chunks) |n| {
        if (n == 0) c.fatal("invalid number of chunks: '0'", .{});
        if (auto_len) {
            var cap: u64 = 1;
            var k: usize = 0;
            while (k < suffix_len) : (k += 1) cap *= if (numeric == 'd') 10 else if (numeric == 'x') 16 else 26;
            while (cap < n) : (suffix_len += 1) cap *= if (numeric == 'd') 10 else if (numeric == 'x') 16 else 26;
        }
        const size = data.len / n;
        const rem = data.len % n;
        var off: usize = 0;
        var k: u64 = 0;
        while (k < n) : (k += 1) {
            const end = off + @as(usize, @intCast(size)) + @as(usize, if (k < rem) 1 else 0);
            const fd = openOut();
            try c.sys.writeAll(fd, data[off..end]);
            c.sys.close(fd);
            off = end;
        }
        return 0;
    }
    if (bytes) |bs| {
        if (bs == 0) c.fatal("invalid number of bytes: '0'", .{});
        var off: usize = 0;
        while (off < data.len) {
            const end = @min(data.len, off + @as(usize, @intCast(bs)));
            const fd = openOut();
            try c.sys.writeAll(fd, data[off..end]);
            c.sys.close(fd);
            off = end;
        }
        return 0;
    }
    if (line_bytes) |lb| {
        var off: usize = 0;
        while (off < data.len) {
            var end = @min(data.len, off + @as(usize, @intCast(lb)));
            if (end < data.len) {
                if (mem.lastIndexOfScalar(u8, data[off..end], sep)) |k| end = off + k + 1;
            }
            const fd = openOut();
            try c.sys.writeAll(fd, data[off..end]);
            c.sys.close(fd);
            off = end;
        }
        return 0;
    }
    const nl = lines orelse 1000;
    if (nl == 0) c.fatal("invalid number of lines: '0'", .{});
    var off: usize = 0;
    while (off < data.len) {
        var end = off;
        var count: u64 = 0;
        while (count < nl and end < data.len) : (count += 1) {
            end = if (mem.indexOfScalarPos(u8, data, end, sep)) |k| k + 1 else data.len;
        }
        const fd = openOut();
        try c.sys.writeAll(fd, data[off..end]);
        c.sys.close(fd);
        off = end;
    }
    return 0;
}
