const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: nohup COMMAND [ARG]...
    \\  or:  nohup OPTION
    \\Run COMMAND, ignoring hangup signals.
    \\
    \\If standard input is a terminal, redirect it from an unreadable file.
    \\If standard output is a terminal, append output to 'nohup.out' if possible,
    \\'$HOME/nohup.out' otherwise.
    \\If standard error is a terminal, redirect it to standard output.
    \\
;

pub fn main(args: c.Args) !u8 {
    c.usage_status = 125;
    var p = c.Parser.init(args, &.{});
    p.permute = false;
    var have = false;
    while (p.next()) |o| switch (o) {
        .pos => {
            p.idx -= 1;
            have = true;
            break;
        },
        else => p.bad(o),
    };
    if (!have) c.usageErr("missing operand", .{});
    const cmd = p.rest();
    if (c.isatty(0)) {
        const fd = c.sys.open("/dev/null", c.O_WRONLY, 0) catch -1;
        if (fd >= 0) c.sys.dup2(fd, 0) catch {};
    }
    if (c.isatty(1)) {
        var name: []const u8 = "nohup.out";
        const fd = c.sys.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600) catch blk: {
            const home = c.getenv("HOME") orelse "";
            name = c.join(home, "nohup.out");
            break :blk c.sys.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600) catch |e| {
                c.fatalCode(125, "failed to open {f}: {s}", .{ c.q(name), c.strerror(e) });
            };
        };
        c.sys.dup2(fd, 1) catch {};
        c.eprint("nohup: ignoring input and appending output to {f}\n", .{c.q(name)});
    }
    if (c.isatty(2)) c.sys.dup2(1, 2) catch {};
    c.setSignal(1, null, true);
    var argv: std.ArrayList([]const u8) = .empty;
    for (cmd) |a| try argv.append(c.gpa, a);
    c.flush();
    const e = c.execvp(argv.items, c.envp());
    c.warn("failed to run command {f}: {s}", .{ c.q(argv.items[0]), c.strerror(e) });
    return if (e == error.NOENT) 127 else 126;
}
