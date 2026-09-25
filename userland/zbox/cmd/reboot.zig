const std = @import("std");
const c = @import("../common.zig");
const linux = std.os.linux;

pub const help =
    \\Usage: reboot [-f] [-n] [-w] [-d]
    \\Reboot the system.
    \\
    \\  -f, --force     force (default: there is no init to notify)
    \\  -n, --no-sync   don't sync before reboot
    \\  -w, --wtmp-only only write a wtmp record, don't reboot
    \\  -d, --no-wtmp   don't write a wtmp record
    \\
;
pub const help_poweroff =
    \\Usage: poweroff [-f] [-n] [-w]
    \\Power off the system.
    \\
    \\  -f, --force     force
    \\  -n, --no-sync   don't sync before power off
    \\  -w, --wtmp-only don't actually power off
    \\
;
pub const help_halt =
    \\Usage: halt [-f] [-n] [-p] [-w]
    \\Halt the system.
    \\
    \\  -f, --force     force
    \\  -n, --no-sync   don't sync before halting
    \\  -p, --poweroff  power off instead of halting
    \\  -w, --wtmp-only don't actually halt
    \\
;

fn run(args: c.Args, cmd_in: linux.LINUX_REBOOT.CMD) u8 {
    var cmd = cmd_in;
    var no_sync = false;
    var dry = false;
    var p = c.Parser.init(args, &.{
        .{ "force", 'f' }, .{ "no-sync", 'n' }, .{ "wtmp-only", 'w' }, .{ "no-wtmp", 'd' }, .{ "poweroff", 'p' }, .{ "reboot", 0 }, .{ "halt", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'f', 'd', 'i', 'h' => {},
            'n' => no_sync = true,
            'w' => dry = true,
            'p' => cmd = .POWER_OFF,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "reboot")) cmd = .RESTART else if (c.eql(n, "halt")) cmd = .HALT else p.bad(o);
        },
        else => p.bad(o),
    };
    if (dry) return 0;
    c.flush();
    if (!no_sync) linux.sync();
    const rc = linux.reboot(.MAGIC1, .MAGIC2, cmd, null);
    const e = std.posix.errno(rc);
    if (e != .SUCCESS) c.fatal("{s}", .{c.strerror(c.mapErrno(e))});
    return 0;
}

pub fn main(args: c.Args) !u8 {
    return run(args, .RESTART);
}
pub fn mainPoweroff(args: c.Args) !u8 {
    return run(args, .POWER_OFF);
}
pub fn mainHalt(args: c.Args) !u8 {
    return run(args, .HALT);
}
