const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: which [-a] args
    \\Locate a command in PATH.
    \\
    \\  -a      print all matching pathnames of each argument
    \\
;

fn isExec(path: []const u8) bool {
    const st = c.sys.stat(path) catch return false;
    if (!st.isReg()) return false;
    c.sys.access(path, 1) catch return false;
    return true;
}

pub fn main(args: c.Args) !u8 {
    var all = false;
    var names: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "all", 'a' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => all = true,
            's' => {},
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    if (names.items.len == 0) return 1;
    var status: u8 = 0;
    const path = c.getenv("PATH") orelse "/bin:/usr/bin";
    for (names.items) |n| {
        var found = false;
        if (mem.indexOfScalar(u8, n, '/') != null) {
            if (isExec(n)) {
                try c.out.print("{s}\n", .{n});
                found = true;
            }
        } else {
            var it = mem.splitScalar(u8, path, ':');
            while (it.next()) |dir| {
                const d = if (dir.len == 0) "." else dir;
                const full = c.join(d, n);
                if (isExec(full)) {
                    try c.out.print("{s}\n", .{full});
                    found = true;
                    if (!all) break;
                }
            }
        }
        if (!found) status = 1;
    }
    return status;
}
