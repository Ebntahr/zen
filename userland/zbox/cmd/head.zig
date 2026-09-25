const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: head [OPTION]... [FILE]...
    \\Print the first 10 lines of each FILE to standard output.
    \\With more than one FILE, precede each with a header giving the file name.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -c, --bytes=[-]NUM       print the first NUM bytes of each file;
    \\                             with the leading '-', print all but the last
    \\                             NUM bytes of each file
    \\  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;
    \\                             with the leading '-', print all but the last
    \\                             NUM lines of each file
    \\  -q, --quiet, --silent    never print headers giving file names
    \\  -v, --verbose            always print headers giving file names
    \\  -z, --zero-terminated    line delimiter is NUL, not newline
    \\
    \\NUM may have a multiplier suffix: b 512, kB 1000, K 1024, MB 1000*1000,
    \\M 1024*1024, GB, G, T, P, E.
    \\
;

const Spec = struct { n: u64, all_but: bool };

fn parseNum(s: []const u8, what: []const u8) Spec {
    var t = s;
    var all_but = false;
    if (t.len > 0 and t[0] == '-') {
        all_but = true;
        t = t[1..];
    } else if (t.len > 0 and t[0] == '+') t = t[1..];
    const n = c.parseSize(t) orelse c.fatal("invalid number of {s}: {f}", .{ what, c.q(s) });
    return .{ .n = n, .all_but = all_but };
}

fn writeOut(data: []const u8) !void {
    try c.out.writeAll(data);
}

fn headLines(fd: i32, sp: Spec, delim: u8) !void {
    if (!sp.all_but) {
        if (sp.n == 0) return;
        var left = sp.n;
        var buf: [65536]u8 = undefined;
        while (left > 0) {
            const n = try c.sys.read(fd, &buf);
            if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                if (mem.indexOfScalarPos(u8, buf[0..n], i, delim)) |k| {
                    left -= 1;
                    i = k + 1;
                    if (left == 0) break;
                } else {
                    i = n;
                }
            }
            try writeOut(buf[0..i]);
            if (left > 0 and i < n) try writeOut(buf[i..n]);
            if (left == 0) {
                // seek back unread data for regular files (like GNU)
                if (i < n) _ = c.sys.lseek(fd, -@as(i64, @intCast(n - i)), 1) catch {};
                break;
            }
        }
        return;
    }
    // all but last N lines
    const data = try c.readFdAll(fd);
    defer c.gpa.free(data);
    var total: u64 = @intCast(mem.count(u8, data, &[1]u8{delim}));
    if (data.len > 0 and data[data.len - 1] != delim) total += 1;
    if (total <= sp.n) return;
    var keep = total - sp.n;
    var pos: usize = 0;
    while (keep > 0) : (keep -= 1) {
        pos = if (mem.indexOfScalarPos(u8, data, pos, delim)) |k| k + 1 else data.len;
    }
    try writeOut(data[0..pos]);
}

fn headBytes(fd: i32, sp: Spec) !void {
    if (!sp.all_but) {
        var left = sp.n;
        var buf: [65536]u8 = undefined;
        while (left > 0) {
            const want: usize = @intCast(@min(left, buf.len));
            const n = try c.sys.read(fd, buf[0..want]);
            if (n == 0) break;
            try writeOut(buf[0..n]);
            left -= n;
        }
        return;
    }
    const data = try c.readFdAll(fd);
    defer c.gpa.free(data);
    const keep = if (sp.n >= data.len) 0 else data.len - @as(usize, @intCast(sp.n));
    try writeOut(data[0..keep]);
}

pub fn main(args_in: c.Args) !u8 {
    // Obsolete syntax: head -NUM
    var args = args_in;
    var lines: Spec = .{ .n = 10, .all_but = false };
    var bytes: ?Spec = null;
    if (args.len > 1 and args[1].len > 1 and args[1][0] == '-' and std.ascii.isDigit(args[1][1])) {
        const a = args[1][1..];
        var k: usize = 0;
        while (k < a.len and std.ascii.isDigit(a[k])) k += 1;
        const n = c.parseUint(a[0..k]) orelse 10;
        var is_bytes = false;
        for (a[k..]) |ch| switch (ch) {
            'c' => is_bytes = true,
            'l' => {},
            'b', 'k', 'm' => {},
            else => {},
        };
        if (is_bytes) bytes = .{ .n = n, .all_but = false } else lines = .{ .n = n, .all_but = false };
        const na = try c.gpa.alloc([:0]const u8, args.len - 1);
        na[0] = args[0];
        @memcpy(na[1..], args[2..]);
        args = na;
    }
    var verbose: ?bool = null;
    var delim: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "bytes", 'c' }, .{ "lines", 'n' }, .{ "quiet", 'q' }, .{ "silent", 'q' },
        .{ "verbose", 'v' }, .{ "zero-terminated", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => bytes = parseNum(p.arg(), "bytes"),
            'n' => {
                lines = parseNum(p.arg(), "lines");
                bytes = null;
            },
            'q' => verbose = false,
            'v' => verbose = true,
            'z' => delim = 0,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    const show = verbose orelse (files.items.len > 1);
    var status: u8 = 0;
    for (files.items, 0..) |f, idx| {
        const fd = c.openInput(f) orelse {
            if (mem.eql(u8, f, f)) {}
            c.flush();
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        if (show) {
            if (idx > 0) try c.out.writeByte('\n');
            try c.out.print("==> {s} <==\n", .{if (c.eql(f, "-")) "standard input" else f});
        }
        const r = if (bytes) |b| headBytes(fd, b) else headLines(fd, lines, delim);
        r catch |e| {
            if (e == error.WriteFailed) return e;
            c.warn("error reading {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
        };
    }
    return status;
}
