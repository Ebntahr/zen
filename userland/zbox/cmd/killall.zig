const std = @import("std");
const c = @import("../common.zig");
const pr = @import("../procfs.zig");
const mem = std.mem;

pub const help =
    \\Usage: killall [OPTION]... [--] NAME...
    \\       killall -l, --list
    \\Send a signal to processes by name.
    \\
    \\  -e, --exact         require exact match for very long names
    \\  -I, --ignore-case   case insensitive process name match
    \\  -i, --interactive   ask for confirmation before killing
    \\  -l, --list          list all known signal names
    \\  -q, --quiet         don't print complaints
    \\  -s, --signal SIGNAL send this signal instead of SIGTERM
    \\  -u, --user USER     kill only process(es) running as USER
    \\  -v, --verbose       report if the signal was successfully sent
    \\  -w, --wait          wait for processes to die
    \\
;

pub fn main(args: c.Args) !u8 {
    var sig: u32 = 15;
    var icase = false;
    var interactive = false;
    var quiet = false;
    var verbose = false;
    var wait = false;
    var user: ?u32 = null;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    // -SIGNAL form first
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 1 and a[0] == '-' and a[1] != '-' and (std.ascii.isUpper(a[1]) or std.ascii.isDigit(a[1]))) {
            if (c.parseSignal(a[1..])) |s| {
                sig = s;
                continue;
            }
        }
        break;
    }
    var rebuilt: std.ArrayList([:0]const u8) = .empty;
    try rebuilt.append(c.gpa, args[0]);
    for (args[i..]) |a| try rebuilt.append(c.gpa, a);
    var p = c.Parser.init(rebuilt.items, &.{
        .{ "exact", 'e' }, .{ "ignore-case", 'I' }, .{ "interactive", 'i' }, .{ "list", 'l' }, .{ "quiet", 'q' },
        .{ "signal", 's' }, .{ "user", 'u' }, .{ "verbose", 'v' }, .{ "wait", 'w' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'e', 'g', 'r' => {},
            'I' => icase = true,
            'i' => interactive = true,
            'l' => {
                const kill = @import("kill.zig");
                const la = [_][:0]const u8{ "kill", "-l" };
                return kill.main(&la);
            },
            'q' => quiet = true,
            's' => {
                const v = p.arg();
                sig = c.parseSignal(v) orelse c.fatal("{s}: unknown signal; killall -l lists signals.", .{v});
            },
            'u' => {
                const v = p.arg();
                user = if (c.userByName(v)) |u| u.uid else c.fatal("Cannot find user {s}", .{v});
            },
            'v' => verbose = true,
            'w' => wait = true,
            else => p.bad(o),
        },
        .pos => |a| try names.append(c.gpa, a),
        else => p.bad(o),
    };
    if (names.items.len == 0) c.usageErr("no process name specified", .{});
    const self = c.sys.getpid();
    var status: u8 = 0;
    var killed: std.ArrayList(i32) = .empty;
    for (names.items) |n| {
        var any = false;
        for (pr.listPids()) |pid| {
            if (pid == self) continue;
            const p2 = pr.read(pid) orelse continue;
            const pn = pr.progName(p2);
            const match = if (icase) (std.ascii.eqlIgnoreCase(p2.comm, n) or std.ascii.eqlIgnoreCase(pn, n)) else (c.eql(p2.comm, n) or c.eql(pn, n));
            if (!match) continue;
            if (user) |u| if (p2.uid != u) continue;
            if (interactive) {
                c.eprint("Kill {s}({d}) ? (y/N) ", .{ p2.comm, pid });
                if (!c.yesno()) continue;
            }
            any = true;
            c.sys.kill(pid, sig) catch |e| {
                if (!quiet) c.warn("{s}({d}): {s}", .{ p2.comm, pid, c.strerror(e) });
                status = 1;
                continue;
            };
            try killed.append(c.gpa, pid);
            if (verbose) {
                var nb: [16]u8 = undefined;
                c.eprint("Killed {s}({d}) with signal {d} ({s})\n", .{ p2.comm, pid, sig, c.signalName(&nb, sig) });
            }
        }
        if (!any) {
            if (!quiet) c.eprint("{s}: no process found\n", .{n});
            status = 1;
        }
    }
    if (wait) {
        for (killed.items) |pid| {
            while (true) {
                c.sys.kill(pid, 0) catch break;
                c.sys.nanosleep(50_000_000);
            }
        }
    }
    return status;
}
