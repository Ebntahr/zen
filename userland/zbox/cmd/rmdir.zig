const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: rmdir [OPTION]... DIRECTORY...
    \\Remove the DIRECTORY(ies), if they are empty.
    \\
    \\      --ignore-fail-on-non-empty
    \\                    ignore each failure to remove a non-empty directory
    \\  -p, --parents     remove DIRECTORY and its ancestors
    \\  -v, --verbose     output a diagnostic for every directory processed
    \\
;

pub fn main(args: c.Args) !u8 {
    var parents = false;
    var ignore_ne = false;
    var verbose = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "ignore-fail-on-non-empty", 0 }, .{ "parents", 'p' }, .{ "verbose", 'v' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'p' => parents = true,
            'v' => verbose = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "ignore-fail-on-non-empty")) ignore_ne = true else p.bad(o);
        },
        .pos => |a| try dirs.append(c.gpa, a),
    };
    if (dirs.items.len == 0) c.missingOperand();
    var status: u8 = 0;
    for (dirs.items) |d_in| {
        var d: []const u8 = d_in;
        while (true) {
            if (verbose) try c.out.print("rmdir: removing directory, {f}\n", .{c.q(d)});
            c.sys.rmdir(d) catch |e| {
                if (!(ignore_ne and (e == error.NOTEMPTY or e == error.EXIST))) {
                    c.warn("failed to remove {f}: {s}", .{ c.q(d), c.strerror(e) });
                    status = 1;
                }
                break;
            };
            if (!parents) break;
            var s = d;
            while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
            const slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse break;
            var parent = s[0..slash];
            while (parent.len > 0 and parent[parent.len - 1] == '/') parent = parent[0 .. parent.len - 1];
            if (parent.len == 0) break;
            d = parent;
        }
    }
    return status;
}
