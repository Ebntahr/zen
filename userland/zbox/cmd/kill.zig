const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: kill [-s SIGNAL | -SIGNAL] PID...
    \\  or:  kill -l [SIGNAL]...
    \\  or:  kill -t [SIGNAL]...
    \\Send signals to processes, or list signals.
    \\
    \\  -s, --signal=SIGNAL, -SIGNAL
    \\                   specify the name or number of the signal to be sent
    \\  -l, --list       list signal names, or convert signal names to/from numbers
    \\  -L, -t, --table  print a table of signal information
    \\
    \\SIGNAL may be a signal name like 'HUP', or a signal number like '1',
    \\or the exit status of a process terminated by a signal.
    \\PID is an integer; if negative it identifies a process group.
    \\
;

fn listSignals(args: []const []const u8, table: bool) !u8 {
    const w = c.out;
    var nb: [16]u8 = undefined;
    if (args.len == 0) {
        if (table) {
            var col: usize = 0;
            for (1..65) |s| {
                if (s == 32 or s == 33) continue;
                try w.print("{d: >2} {s: <8}", .{ s, c.signalName(&nb, @intCast(s)) });
                col += 1;
                if (col % 7 == 0) try w.writeByte('\n') else try w.writeByte(' ');
            }
            if (col % 7 != 0) try w.writeByte('\n');
            return 0;
        }
        var line_len: usize = 0;
        for (1..32) |s| {
            const n = c.signalName(&nb, @intCast(s));
            if (line_len > 0 and line_len + n.len + 1 > 80) {
                try w.writeByte('\n');
                line_len = 0;
            } else if (line_len > 0) {
                try w.writeByte(' ');
                line_len += 1;
            }
            try w.writeAll(n);
            line_len += n.len;
        }
        try w.writeByte('\n');
        return 0;
    }
    var status: u8 = 0;
    for (args) |a| {
        if (a.len > 0 and std.ascii.isDigit(a[0])) {
            var n = c.parseUint(a) orelse {
                c.warn("{f}: invalid signal", .{c.q(a)});
                status = 1;
                continue;
            };
            if (n > 128) n -= 128;
            if (n == 0 or n > 64) {
                c.warn("{f}: invalid signal", .{c.q(a)});
                status = 1;
                continue;
            }
            try w.print("{s}\n", .{c.signalName(&nb, @intCast(n))});
        } else {
            const s = c.parseSignal(a) orelse {
                c.warn("{f}: invalid signal", .{c.q(a)});
                status = 1;
                continue;
            };
            try w.print("{d}\n", .{s});
        }
    }
    return status;
}

pub fn main(args: c.Args) !u8 {
    var sig: u32 = 15;
    var list = false;
    var table = false;
    var pids: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (c.eql(a, "--")) {
            i += 1;
            break;
        }
        if (c.eql(a, "--help")) c.printHelp();
        if (c.eql(a, "--version")) c.printVersion();
        if (c.eql(a, "-l") or c.eql(a, "--list")) {
            list = true;
            continue;
        }
        if (c.eql(a, "-L") or c.eql(a, "-t") or c.eql(a, "--table")) {
            list = true;
            table = true;
            continue;
        }
        if (c.eql(a, "-s") or c.eql(a, "-n") or c.eql(a, "--signal")) {
            i += 1;
            if (i >= args.len) c.usageErr("option requires an argument -- '{s}'", .{a[1..]});
            sig = c.parseSignal(args[i]) orelse c.fatal("{f}: invalid signal", .{c.q(args[i])});
            continue;
        }
        if (mem.startsWith(u8, a, "--signal=")) {
            sig = c.parseSignal(a[9..]) orelse c.fatal("{f}: invalid signal", .{c.q(a[9..])});
            continue;
        }
        if (a.len > 1 and a[0] == '-' and !list) {
            if (c.parseSignal(a[1..])) |s| {
                sig = s;
                continue;
            }
            if (std.ascii.isDigit(a[1])) break; // negative pid (process group)
            c.fatal("{f}: invalid signal", .{c.q(a[1..])});
        }
        break;
    }
    while (i < args.len) : (i += 1) try pids.append(c.gpa, args[i]);
    if (list) return listSignals(pids.items, table);
    if (pids.items.len == 0) c.usageErr("no process ID specified", .{});
    var status: u8 = 0;
    for (pids.items) |ps| {
        const pid = c.parseInt(ps) orelse {
            c.warn("{f}: invalid process id", .{c.q(ps)});
            status = 1;
            continue;
        };
        c.sys.kill(@intCast(pid), sig) catch |e| {
            c.warn("{s}: {s}", .{ ps, c.strerror(e) });
            status = 1;
        };
    }
    return status;
}
