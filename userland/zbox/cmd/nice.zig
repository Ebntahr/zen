const std = @import("std");
const c = @import("../common.zig");
const linux = std.os.linux;

pub const help =
    \\Usage: nice [OPTION] [COMMAND [ARG]...]
    \\Run COMMAND with an adjusted niceness, which affects process scheduling.
    \\With no COMMAND, print the current niceness.  Niceness values range from
    \\-20 (most favorable to the process) to 19 (least favorable to the process).
    \\
    \\  -n, --adjustment=N   add integer N to the niceness (default 10)
    \\
;

fn getNice() i32 {
    const rc = linux.syscall2(.getpriority, 0, 0);
    if (std.posix.errno(rc) != .SUCCESS) return 0;
    return 20 - @as(i32, @intCast(rc));
}

pub fn main(args_in: c.Args) !u8 {
    c.usage_status = 125;
    var args = args_in;
    var adj: i64 = 10;
    // obsolete -N / --N
    if (args.len > 1 and args[1].len > 1 and args[1][0] == '-' and (std.ascii.isDigit(args[1][1]) or (args[1][1] == '-' and args[1].len > 2 and std.ascii.isDigit(args[1][2])))) {
        adj = c.parseInt(args[1][1..]) orelse 10;
        const na = try c.gpa.alloc([:0]const u8, args.len - 1);
        na[0] = args[0];
        @memcpy(na[1..], args[2..]);
        args = na;
    }
    var p = c.Parser.init(args, &.{.{ "adjustment", 'n' }});
    p.permute = false;
    p.neg_numbers = false;
    var have_cmd = false;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'n' => {
                const a = p.arg();
                adj = c.parseInt(a) orelse c.usageErr("invalid adjustment {f}", .{c.q(a)});
            },
            else => p.bad(o),
        },
        .pos => {
            p.idx -= 1;
            have_cmd = true;
            break;
        },
        else => p.bad(o),
    };
    if (!have_cmd) {
        try c.out.print("{d}\n", .{getNice()});
        return 0;
    }
    const cmd = p.rest();
    const target = std.math.clamp(@as(i64, getNice()) + adj, -20, 19);
    const rc = linux.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, target)));
    if (std.posix.errno(rc) != .SUCCESS) c.warn("cannot set niceness: {s}", .{c.strerror(c.mapErrno(std.posix.errno(rc)))});
    var argv: std.ArrayList([]const u8) = .empty;
    for (cmd) |a| try argv.append(c.gpa, a);
    c.flush();
    const e = c.execvp(argv.items, c.envp());
    c.warn("{f}: {s}", .{ c.q(argv.items[0]), c.strerror(e) });
    return if (e == error.NOENT) 127 else 126;
}
