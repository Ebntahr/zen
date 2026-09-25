const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: tee [OPTION]... [FILE]...
    \\Copy standard input to each FILE, and also to standard output.
    \\
    \\  -a, --append              append to the given FILEs, do not overwrite
    \\  -i, --ignore-interrupts   ignore interrupt signals
    \\  -p                        operate in a more appropriate MODE with pipes
    \\
;

pub fn main(args: c.Args) !u8 {
    var append = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "append", 'a' }, .{ "ignore-interrupts", 'i' }, .{ "output-error", 0 } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => append = true,
            'i' => c.setSignal(2, null, true),
            'p' => {},
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "output-error")) _ = p.optArg() else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    var status: u8 = 0;
    var fds: std.ArrayList(i32) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    try fds.append(c.gpa, 1);
    try names.append(c.gpa, "standard output");
    for (files.items) |f| {
        if (c.eql(f, "-")) {
            try fds.append(c.gpa, 1);
            try names.append(c.gpa, "standard output");
            continue;
        }
        const fd = c.sys.open(f, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = !append, .APPEND = append, .CLOEXEC = true }, 0o666) catch |e| {
            c.warn("{s}: {s}", .{ f, c.strerror(e) });
            status = 1;
            continue;
        };
        try fds.append(c.gpa, fd);
        try names.append(c.gpa, f);
    }
    var alive = try c.gpa.alloc(bool, fds.items.len);
    @memset(alive, true);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.sys.read(0, &buf) catch |e| {
            c.warn("standard input: {s}", .{c.strerror(e)});
            status = 1;
            break;
        };
        if (n == 0) break;
        for (fds.items, 0..) |fd, i| {
            if (!alive[i]) continue;
            c.sys.writeAll(fd, buf[0..n]) catch |e| {
                if (e == error.PIPE and fd == 1) c.exit(1);
                c.warn("{s}: {s}", .{ names.items[i], c.strerror(e) });
                alive[i] = false;
                status = 1;
            };
        }
    }
    _ = &alive;
    return status;
}
