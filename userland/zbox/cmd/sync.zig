const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: sync [OPTION] [FILE]...
    \\Synchronize cached writes to persistent storage
    \\
    \\If one or more files are specified, sync only them,
    \\or their containing file systems.
    \\
    \\  -d, --data             sync only file data, no unneeded metadata
    \\  -f, --file-system      sync the file systems that contain the files
    \\
;

pub fn main(args: c.Args) !u8 {
    var data_only = false;
    var fs = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "data", 'd' }, .{ "file-system", 'f' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'd' => data_only = true,
            'f' => fs = true,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) {
        std.os.linux.sync();
        return 0;
    }
    var status: u8 = 0;
    for (files.items) |f| {
        const fd = c.sys.open(f, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| {
            c.warn("error opening {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
            continue;
        };
        defer c.sys.close(fd);
        const rc = if (fs) std.os.linux.syscall1(.syncfs, @bitCast(@as(isize, fd))) else if (data_only) std.os.linux.fdatasync(fd) else std.os.linux.fsync(fd);
        if (std.posix.errno(rc) != .SUCCESS) {
            c.warn("error syncing {f}: {s}", .{ c.q(f), c.strerror(c.mapErrno(std.posix.errno(rc))) });
            status = 1;
        }
    }
    return status;
}
