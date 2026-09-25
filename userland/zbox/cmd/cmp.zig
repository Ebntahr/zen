const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: cmp [OPTION]... FILE1 [FILE2 [SKIP1 [SKIP2]]]
    \\Compare two files byte by byte.
    \\
    \\  -b, --print-bytes          print differing bytes
    \\  -i, --ignore-initial=SKIP         skip first SKIP bytes of both inputs
    \\  -l, --verbose              output byte numbers and differing byte values
    \\  -n, --bytes=LIMIT          compare at most LIMIT bytes
    \\  -s, --quiet, --silent      suppress all normal output
    \\
    \\Exit status is 0 if inputs are the same, 1 if different, 2 if trouble.
    \\
;

fn printable(buf: []u8, b: u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var ch = b;
    if (ch >= 128) {
        w.writeAll("M-") catch {};
        ch -= 128;
    }
    if (ch < 32) {
        w.print("^{c}", .{ch + 64}) catch {};
    } else if (ch == 127) {
        w.writeAll("^?") catch {};
    } else w.writeByte(ch) catch {};
    return w.buffered();
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    var print_bytes = false;
    var verbose = false;
    var silent = false;
    var skip1: u64 = 0;
    var skip2: u64 = 0;
    var limit: ?u64 = null;
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "print-bytes", 'b' }, .{ "ignore-initial", 'i' }, .{ "verbose", 'l' }, .{ "bytes", 'n' }, .{ "quiet", 's' }, .{ "silent", 's' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => print_bytes = true,
            'i' => {
                const a = p.arg();
                if (std.mem.indexOfScalar(u8, a, ':')) |k| {
                    skip1 = c.parseSize(a[0..k]) orelse c.fatalCode(2, "invalid --ignore-initial value {f}", .{c.q(a)});
                    skip2 = c.parseSize(a[k + 1 ..]) orelse c.fatalCode(2, "invalid --ignore-initial value {f}", .{c.q(a)});
                } else {
                    skip1 = c.parseSize(a) orelse c.fatalCode(2, "invalid --ignore-initial value {f}", .{c.q(a)});
                    skip2 = skip1;
                }
            },
            'l' => verbose = true,
            'n' => limit = c.parseSize(p.arg()) orelse c.fatalCode(2, "invalid --bytes value", .{}),
            's' => silent = true,
            else => p.bad(o),
        },
        .pos => |a| try ops.append(c.gpa, a),
        else => p.bad(o),
    };
    if (ops.items.len == 0) c.usageErr("missing operand after 'cmp'", .{});
    if (ops.items.len > 4) c.usageErr("extra operand {f}", .{c.q(ops.items[4])});
    const f1 = ops.items[0];
    const f2 = if (ops.items.len > 1) ops.items[1] else "-";
    if (ops.items.len > 2) skip1 = c.parseSize(ops.items[2]) orelse c.fatalCode(2, "invalid --ignore-initial value {f}", .{c.q(ops.items[2])});
    if (ops.items.len > 3) skip2 = c.parseSize(ops.items[3]) orelse c.fatalCode(2, "invalid --ignore-initial value {f}", .{c.q(ops.items[3])});
    const d1_all = blk: {
        const fd = c.openInput(f1) orelse c.exit(2);
        defer c.closeInput(fd);
        break :blk c.readFdAll(fd) catch |e| c.fatalCode(2, "{s}: {s}", .{ f1, c.strerror(e) });
    };
    const d2_all = blk: {
        const fd = c.openInput(f2) orelse c.exit(2);
        defer c.closeInput(fd);
        break :blk c.readFdAll(fd) catch |e| c.fatalCode(2, "{s}: {s}", .{ f2, c.strerror(e) });
    };
    var d1 = d1_all[@min(skip1, d1_all.len)..];
    var d2 = d2_all[@min(skip2, d2_all.len)..];
    if (limit) |l| {
        if (l < d1.len) d1 = d1[0..@intCast(l)];
        if (l < d2.len) d2 = d2[0..@intCast(l)];
    }
    const n = @min(d1.len, d2.len);
    var line: u64 = 1;
    var differ = false;
    const w = c.out;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (d1[i] != d2[i]) {
            differ = true;
            if (silent) return 1;
            if (verbose) {
                if (print_bytes) {
                    var b1: [8]u8 = undefined;
                    var b2: [8]u8 = undefined;
                    try w.print("{d} {o: >3} {s: <4} {o: >3} {s}\n", .{ i + 1, d1[i], printable(&b1, d1[i]), d2[i], printable(&b2, d2[i]) });
                } else try w.print("{d} {o: >3} {o: >3}\n", .{ i + 1, d1[i], d2[i] });
                continue;
            }
            if (print_bytes) {
                var b1: [8]u8 = undefined;
                var b2: [8]u8 = undefined;
                try w.print("{s} {s} differ: byte {d}, line {d} is {o: >3} {s} {o: >3} {s}\n", .{ f1, f2, i + 1, line, d1[i], printable(&b1, d1[i]), d2[i], printable(&b2, d2[i]) });
            } else try w.print("{s} {s} differ: char {d}, line {d}\n", .{ f1, f2, i + 1, line });
            return 1;
        }
        if (d1[i] == '\n') line += 1;
    }
    if (d1.len != d2.len) {
        if (!silent) {
            const shorter = if (d1.len < d2.len) f1 else f2;
            c.flush();
            if (n == 0) {
                c.eprint("cmp: EOF on {s} which is empty\n", .{shorter});
            } else {
                c.eprint("cmp: EOF on {s} after byte {d}, line {d}\n", .{ shorter, n, if (n > 0 and (if (d1.len < d2.len) d1 else d2)[n - 1] == '\n') line - 1 else line });
            }
        }
        return 1;
    }
    return if (differ) 1 else 0;
}
