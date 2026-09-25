const std = @import("std");
const c = @import("../common.zig");
const pr = @import("../procfs.zig");

pub const help =
    \\Usage: free [options]
    \\Display amount of free and used memory in the system.
    \\
    \\  -b, --bytes         show output in bytes
    \\  -k, --kibi          show output in kibibytes
    \\  -m, --mebi          show output in mebibytes
    \\  -g, --gibi          show output in gibibytes
    \\  -h, --human         show human-readable output
    \\      --si            use powers of 1000 not 1024
    \\  -w, --wide          wide output
    \\  -t, --total         show total for RAM + swap
    \\  -s N, --seconds N   repeat printing every N seconds
    \\  -c N, --count N     repeat printing N times, then exit
    \\
;

var unit_shift: u6 = 10; // bytes divisor as power of two (10 = KiB)
var human = false;
var si = false;

fn scale(buf: []u8, kb: u64) []const u8 {
    const bytes = kb * 1024;
    if (!human) {
        if (si) {
            const div: u64 = switch (unit_shift) {
                0 => 1,
                10 => 1000,
                20 => 1000000,
                else => 1000000000,
            };
            return c.fmtBuf(buf, "{d}", .{bytes / div});
        }
        return c.fmtBuf(buf, "{d}", .{bytes >> unit_shift});
    }
    const base: f64 = if (si) 1000 else 1024;
    const units = if (si) [_][]const u8{ "B", "k", "M", "G", "T", "P" } else [_][]const u8{ "B", "Ki", "Mi", "Gi", "Ti", "Pi" };
    if (bytes < 1024) {
        const s = c.fmtBuf(buf, "{d}B", .{bytes});
        if (s.len <= 5) return s;
    }
    var i: usize = 1;
    while (i < units.len) : (i += 1) {
        const v = @as(f64, @floatFromInt(bytes)) / std.math.pow(f64, base, @floatFromInt(i));
        var tmp: [32]u8 = undefined;
        const s1 = c.fmtBuf(&tmp, "{d:.1}{s}", .{ v, units[i] });
        if (s1.len <= 5) return c.fmtBuf(buf, "{s}", .{s1});
        const s2 = c.fmtBuf(&tmp, "{d}{s}", .{ @as(u64, @intFromFloat(v)), units[i] });
        if (s2.len <= 5) return c.fmtBuf(buf, "{s}", .{s2});
    }
    return c.fmtBuf(buf, "{d}", .{bytes});
}

fn row(w: *std.Io.Writer, label: []const u8, vals: []const u64) !void {
    try c.padRight(w, label, 8);
    for (vals) |v| {
        var b: [32]u8 = undefined;
        try w.writeByte(' ');
        try c.padLeft(w, scale(&b, v), 11);
    }
    try w.writeByte('\n');
}

pub fn main(args: c.Args) !u8 {
    var wide = false;
    var total = false;
    var delay: ?u64 = null;
    var count: ?u64 = null;
    var p = c.Parser.init(args, &.{
        .{ "bytes", 'b' }, .{ "kibi", 'k' }, .{ "mebi", 'm' }, .{ "gibi", 'g' }, .{ "human", 'h' }, .{ "si", 0 },
        .{ "wide", 'w' }, .{ "total", 't' }, .{ "seconds", 's' }, .{ "count", 'c' }, .{ "kilo", 0 }, .{ "mega", 0 }, .{ "giga", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => unit_shift = 0,
            'k' => unit_shift = 10,
            'm' => unit_shift = 20,
            'g' => unit_shift = 30,
            'h' => human = true,
            'w' => wide = true,
            't' => total = true,
            'l', 'L', 'v' => {},
            's' => delay = @intFromFloat((std.fmt.parseFloat(f64, p.arg()) catch c.fatal("seconds argument failed", .{})) * 1e9),
            'c' => count = c.parseUint(p.arg()) orelse c.fatal("failed to parse count argument", .{}),
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "si")) si = true else if (c.eql(n, "kilo")) {
                si = true;
                unit_shift = 10;
            } else if (c.eql(n, "mega")) {
                si = true;
                unit_shift = 20;
            } else if (c.eql(n, "giga")) {
                si = true;
                unit_shift = 30;
            } else p.bad(o);
        },
        else => p.bad(o),
    };
    const w = c.out;
    var iter: u64 = 0;
    while (true) : (iter += 1) {
        const m = pr.memInfo() orelse c.fatal("Unable to read /proc/meminfo", .{});
        const cache = m.cached + m.sreclaimable;
        const bc = m.buffers + cache;
        const avail = m.available orelse (m.free + bc);
        // procps-ng 4: used = total - available
        var used: u64 = m.total -| avail;
        if (m.available == null) used = m.total -| m.free -| bc;
        if (wide) {
            try w.writeAll("               total        used        free      shared     buffers       cache   available\n");
            try row(w, "Mem:", &.{ m.total, used, m.free, m.shmem, m.buffers, cache, avail });
        } else {
            try w.writeAll("               total        used        free      shared  buff/cache   available\n");
            try row(w, "Mem:", &.{ m.total, used, m.free, m.shmem, bc, avail });
        }
        try row(w, "Swap:", &.{ m.swap_total, m.swap_total - m.swap_free, m.swap_free });
        if (total) try row(w, "Total:", &.{ m.total + m.swap_total, used + m.swap_total - m.swap_free, m.free + m.swap_free });
        if (delay == null and count == null) break;
        if (count) |cn| if (iter + 1 >= cn) break;
        try w.writeByte('\n');
        c.flush();
        c.sys.nanosleep(delay orelse 1_000_000_000);
    }
    return 0;
}
