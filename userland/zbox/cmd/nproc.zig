const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: nproc [OPTION]...
    \\Print the number of processing units available to the current process,
    \\which may be less than the number of online processors
    \\
    \\      --all      print the number of installed processors
    \\      --ignore=N  if possible, exclude N processing units
    \\
;

pub fn onlineCpus() u64 {
    var set: [128]u8 = undefined;
    @memset(&set, 0);
    const rc = std.os.linux.syscall3(.sched_getaffinity, 0, set.len, @intFromPtr(&set));
    if (std.posix.errno(rc) == .SUCCESS) {
        var n: u64 = 0;
        for (set[0..@min(rc, set.len)]) |b| n += @popCount(b);
        if (n > 0) return n;
    }
    return allCpus();
}

pub fn allCpus() u64 {
    var buf: [64]u8 = undefined;
    if (c.readSmall("/sys/devices/system/cpu/present", &buf)) |s| {
        // e.g. "0-3" or "0"
        const t = mem.trim(u8, s, " \n");
        var total: u64 = 0;
        var it = mem.splitScalar(u8, t, ',');
        while (it.next()) |r| {
            if (mem.indexOfScalar(u8, r, '-')) |d| {
                const a = c.parseUint(r[0..d]) orelse continue;
                const b = c.parseUint(r[d + 1 ..]) orelse continue;
                total += b - a + 1;
            } else if (c.parseUint(r) != null) total += 1;
        }
        if (total > 0) return total;
    }
    var big: [65536]u8 = undefined;
    if (c.readSmall("/proc/stat", &big)) |s| {
        var n: u64 = 0;
        var lines = mem.splitScalar(u8, s, '\n');
        while (lines.next()) |l| {
            if (l.len > 3 and mem.startsWith(u8, l, "cpu") and std.ascii.isDigit(l[3])) n += 1;
        }
        if (n > 0) return n;
    }
    return 1;
}

pub fn main(args: c.Args) !u8 {
    var all = false;
    var ignore: u64 = 0;
    var p = c.Parser.init(args, &.{ .{ "all", 0 }, .{ "ignore", 0 } });
    while (p.next()) |o| switch (o) {
        .long => |n| {
            if (c.eql(n, "all")) all = true else if (c.eql(n, "ignore")) {
                const a = p.arg();
                ignore = c.parseUint(a) orelse c.fatal("invalid number: {f}", .{c.q(a)});
            } else p.bad(o);
        },
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    var n = if (all) allCpus() else onlineCpus();
    n = if (ignore >= n) 1 else n - ignore;
    try c.out.print("{d}\n", .{n});
    return 0;
}
