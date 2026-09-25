const std = @import("std");
const c = @import("../common.zig");
const pr = @import("../procfs.zig");
const mem = std.mem;

pub const help =
    \\Usage: pidof [options] [program [...]]
    \\Find the process ID of a running program.
    \\
    \\  -s             return one PID only
    \\  -x             also find shells running the named scripts
    \\  -o <PID>       omit processes with PID
    \\  -S <sep>       use custom separator between PIDs
    \\  -q             quiet mode, only set the exit code
    \\
;

pub fn main(args: c.Args) !u8 {
    var single = false;
    var quiet = false;
    var sep: []const u8 = " ";
    var omit: std.ArrayList(i32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "single-shot", 's' }, .{ "quiet", 'q' }, .{ "omit-pid", 'o' }, .{ "separator", 'S' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            's' => single = true,
            'q' => quiet = true,
            'x', 'c', 'n', 'w' => {},
            'o' => {
                const v = p.arg();
                var it = mem.tokenizeScalar(u8, v, ',');
                while (it.next()) |x| {
                    if (c.eql(x, "%PPID")) {
                        try omit.append(c.gpa, std.os.linux.getppid());
                    } else try omit.append(c.gpa, std.fmt.parseInt(i32, x, 10) catch continue);
                }
            },
            'S' => sep = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    const self = c.sys.getpid();
    var found = false;
    var first = true;
    for (names.items) |n| {
        const pids = pr.findByName(c.basename(n), false);
        var k = pids.len;
        while (k > 0) {
            k -= 1;
            const pid = pids[k];
            if (pid == self or mem.indexOfScalar(i32, omit.items, pid) != null) continue;
            found = true;
            if (!quiet) {
                if (!first) try c.out.writeAll(sep);
                try c.out.print("{d}", .{pid});
            }
            first = false;
            if (single) break;
        }
    }
    if (found and !quiet) try c.out.writeByte('\n');
    return if (found) 0 else 1;
}
