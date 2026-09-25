const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: pwd [OPTION]...
    \\Print the full filename of the current working directory.
    \\
    \\  -L, --logical   use PWD from environment, even if it contains symlinks
    \\  -P, --physical  avoid all symlinks (default)
    \\
;

pub fn main(args: c.Args) !u8 {
    var logical = false;
    var p = c.Parser.init(args, &.{ .{ "logical", 'L' }, .{ "physical", 'P' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'L' => logical = true,
            'P' => logical = false,
            else => p.bad(o),
        },
        .pos => c.warn("ignoring non-option arguments", .{}),
        else => p.bad(o),
    };
    var buf: [c.PATH_MAX]u8 = undefined;
    const cwd = c.sys.getcwd(&buf) catch |e| c.fatal("error retrieving current directory: {s}", .{c.strerror(e)});
    if (logical) {
        if (c.getenv("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/' and std.mem.indexOf(u8, pwd, "/.") == null) {
                const a = c.sys.stat(pwd) catch null;
                const b = c.sys.stat(".") catch null;
                if (a != null and b != null and a.?.ino == b.?.ino and a.?.dev == b.?.dev) {
                    try c.out.print("{s}\n", .{pwd});
                    return 0;
                }
            }
        }
    }
    try c.out.print("{s}\n", .{cwd});
    return 0;
}
