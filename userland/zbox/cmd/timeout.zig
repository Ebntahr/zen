const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: timeout [OPTION] DURATION COMMAND [ARG]...
    \\Start COMMAND, and kill it if still running after DURATION.
    \\
    \\  --preserve-status
    \\                 exit with the same status as COMMAND, even when the
    \\                   command times out
    \\  --foreground
    \\                 when not running timeout directly from a shell prompt,
    \\                   allow COMMAND to read from the TTY and get TTY signals
    \\  -k, --kill-after=DURATION
    \\                 also send a KILL signal if COMMAND is still running
    \\                   this long after the initial signal was sent
    \\  -s, --signal=SIGNAL
    \\                 specify the signal to be sent on timeout;
    \\                   SIGNAL may be a name like 'HUP' or a number
    \\  -v, --verbose  diagnose to stderr any signal sent upon timeout
    \\
    \\DURATION is a floating point number with an optional suffix:
    \\'s' for seconds (the default), 'm' for minutes, 'h' for hours or 'd' for days.
    \\
    \\Exit status is 124 if the command times out, 125 if timeout itself fails,
    \\126 if COMMAND is found but cannot be invoked, 127 if COMMAND cannot be found,
    \\otherwise the exit status of COMMAND.
    \\
;

pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var num = s;
    var mult: f64 = 1;
    switch (s[s.len - 1]) {
        's' => num = s[0 .. s.len - 1],
        'm' => {
            num = s[0 .. s.len - 1];
            mult = 60;
        },
        'h' => {
            num = s[0 .. s.len - 1];
            mult = 3600;
        },
        'd' => {
            num = s[0 .. s.len - 1];
            mult = 86400;
        },
        else => {},
    }
    const v = std.fmt.parseFloat(f64, num) catch return null;
    if (v < 0 or std.math.isNan(v)) return null;
    const ns = v * mult * 1e9;
    if (ns > 1.8e19) return std.math.maxInt(u64);
    return @intFromFloat(ns);
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 125;
    var sig: u32 = 15;
    var kill_after: ?u64 = null;
    var preserve = false;
    var verbose = false;
    var p = c.Parser.init(args, &.{
        .{ "preserve-status", 0 }, .{ "foreground", 0 }, .{ "kill-after", 'k' }, .{ "signal", 's' }, .{ "verbose", 'v' },
    });
    p.permute = false;
    var dur_s: ?[]const u8 = null;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'k' => {
                const a = p.arg();
                kill_after = parseDuration(a) orelse c.usageErr("invalid time interval {f}", .{c.q(a)});
            },
            's' => {
                const a = p.arg();
                sig = c.parseSignal(a) orelse c.usageErr("{s}: invalid signal", .{a});
            },
            'v' => verbose = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "preserve-status")) preserve = true else if (c.eql(n, "foreground")) {} else p.bad(o);
        },
        .pos => |a| {
            dur_s = a;
            break;
        },
    };
    const ds = dur_s orelse c.usageErr("missing operand", .{});
    const dur = parseDuration(ds) orelse c.usageErr("invalid time interval {f}", .{c.q(ds)});
    const cmd = p.rest();
    if (cmd.len == 0) c.usageErr("missing operand", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    for (cmd) |a| try argv.append(c.gpa, a);
    c.flush();
    const pid = c.sys.fork() catch |e| c.fatalCode(125, "fork system call failed: {s}", .{c.strerror(e)});
    if (pid == 0) {
        const e = c.execvp(argv.items, c.envp());
        c.warn("failed to run command {f}: {s}", .{ c.q(argv.items[0]), c.strerror(e) });
        std.process.exit(if (e == error.NOENT) 127 else 126);
    }
    const start = c.monoNs();
    var timed_out = false;
    var killed_at: u64 = 0;
    while (true) {
        const r = c.sys.wait(pid, 1) catch return 125; // WNOHANG
        if (r.pid == pid) {
            const code = c.statusCode(r.status);
            if (timed_out and !preserve) return if (sig == 9) 137 else 124;
            if (r.status & 0x7f != 0 and timed_out) return 128 + @as(u8, @truncate(r.status & 0x7f));
            return code;
        }
        const elapsed = c.monoNs() - start;
        if (!timed_out and dur != 0 and elapsed >= dur) {
            timed_out = true;
            if (verbose) {
                var b: [16]u8 = undefined;
                c.warn("sending signal {s} to command {f}", .{ c.signalName(&b, sig), c.q(argv.items[0]) });
            }
            c.sys.kill(pid, sig) catch {};
            if (sig != 9 and sig != 18) c.sys.kill(pid, 18) catch {}; // SIGCONT
            killed_at = elapsed;
        }
        if (timed_out and kill_after != null and elapsed - killed_at >= kill_after.?) {
            if (verbose) c.warn("sending signal KILL to command {f}", .{c.q(argv.items[0])});
            c.sys.kill(pid, 9) catch {};
            kill_after = null;
            preserve = false;
        }
        c.sys.nanosleep(if (elapsed < 100_000_000) 1_000_000 else 10_000_000);
    }
}
