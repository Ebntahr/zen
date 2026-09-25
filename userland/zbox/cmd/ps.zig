const std = @import("std");
const c = @import("../common.zig");
const pr = @import("../procfs.zig");
const mem = std.mem;

pub const help =
    \\Usage: ps [options]
    \\Report a snapshot of the current processes.
    \\
    \\ Basic options:
    \\  -A, -e               all processes
    \\  a                    all with tty, including other users
    \\  x                    processes without controlling ttys
    \\  -p, p, --pid <PID>   process id list
    \\  -u, U, --user <UID>  effective user id or name
    \\
    \\ Output formats:
    \\  -f                   full-format
    \\  -F                   extra full
    \\  -l                   long format
    \\  u                    user-oriented format (use "ps aux")
    \\  -o, o, --format <format>
    \\                       user-defined format: pid,ppid,user,uid,comm,args,
    \\                       stat,tty,time,etime,rss,vsz,%cpu,%mem,nice,start
    \\  --no-headers         do not print header line
    \\
;

const Col = enum { pid, ppid, user, uid, comm, args, stat, tty, time, etime, rss, vsz, pcpu, pmem, nice, start, stime, c_, flags, pri, addr, sz, wchan, state1 };

var hz: f64 = 100;
var uptime: f64 = 0;
var mem_total_kb: u64 = 0;
var boot_time: i64 = 0;
var page_kb: u64 = 4;

fn colHeader(col: Col) []const u8 {
    return switch (col) {
        .pid => "PID",
        .ppid => "PPID",
        .user => "USER",
        .uid => "UID",
        .comm => "COMMAND",
        .args => "COMMAND",
        .stat => "STAT",
        .tty => "TTY",
        .time => "TIME",
        .etime => "ELAPSED",
        .rss => "RSS",
        .vsz => "VSZ",
        .pcpu => "%CPU",
        .pmem => "%MEM",
        .nice => "NI",
        .start => "START",
        .stime => "STIME",
        .c_ => "C",
        .flags => "F",
        .pri => "PRI",
        .addr => "ADDR",
        .sz => "SZ",
        .wchan => "WCHAN",
        .state1 => "S",
    };
}

var pid_width: usize = 5;

fn colWidth(col: Col, bsd: bool) usize {
    return switch (col) {
        .pid, .ppid => pid_width,
        .user => 8,
        .uid => 5,
        .comm, .args => 0,
        .stat => 4,
        .state1, .flags, .addr => 1,
        .tty => 8,
        .time => if (bsd) 6 else 8,
        .etime => 11,
        .rss, .sz => 5,
        .vsz => 6,
        .pcpu, .pmem => 4,
        .nice, .pri => 3,
        .start, .stime => 5,
        .c_ => 2,
        .wchan => 6,
    };
}

fn parseCol(name: []const u8) ?Col {
    const map = [_]struct { []const u8, Col }{
        .{ "pid", .pid },     .{ "ppid", .ppid },   .{ "user", .user },   .{ "euser", .user },  .{ "uname", .user },
        .{ "uid", .uid },     .{ "euid", .uid },    .{ "comm", .comm },   .{ "ucmd", .comm },   .{ "args", .args },
        .{ "cmd", .args },    .{ "command", .args }, .{ "stat", .stat },  .{ "s", .state1 },    .{ "state", .state1 },
        .{ "tty", .tty },     .{ "tname", .tty },   .{ "tt", .tty },      .{ "time", .time },   .{ "cputime", .time },
        .{ "etime", .etime }, .{ "rss", .rss },     .{ "rssize", .rss },  .{ "vsz", .vsz },     .{ "vsize", .vsz },
        .{ "%cpu", .pcpu },   .{ "pcpu", .pcpu },   .{ "%mem", .pmem },   .{ "pmem", .pmem },   .{ "nice", .nice },
        .{ "ni", .nice },     .{ "start", .start }, .{ "stime", .stime }, .{ "c", .c_ },
        .{ "f", .flags },     .{ "flags", .flags }, .{ "pri", .pri },     .{ "addr", .addr },   .{ "sz", .sz },
        .{ "wchan", .wchan },
    };
    for (map) |m| if (c.eql(m[0], name)) return m[1];
    return null;
}

fn fmtTime(buf: []u8, ticks: u64, bsd: bool) []const u8 {
    const secs = @as(u64, @intFromFloat(@as(f64, @floatFromInt(ticks)) / hz));
    if (bsd) return c.fmtBuf(buf, "{d}:{d:0>2}", .{ secs / 60, secs % 60 });
    const days = secs / 86400;
    const h = (secs / 3600) % 24;
    if (days > 0) return c.fmtBuf(buf, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ days, h, (secs / 60) % 60, secs % 60 });
    return c.fmtBuf(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs / 60) % 60, secs % 60 });
}

fn cellText(buf: []u8, col: Col, p: pr.Proc, bsd: bool) []const u8 {
    var nb: [64]u8 = undefined;
    const elapsed = @max(uptime - @as(f64, @floatFromInt(p.starttime)) / hz, 0.001);
    switch (col) {
        .pid => return c.fmtBuf(buf, "{d}", .{p.pid}),
        .ppid => return c.fmtBuf(buf, "{d}", .{p.ppid}),
        .user => {
            const n = c.userName(&nb, p.uid);
            return c.fmtBuf(buf, "{s}", .{n});
        },
        .uid => return c.fmtBuf(buf, "{d}", .{p.uid}),
        .comm => return c.fmtBuf(buf, "{s}", .{p.comm}),
        .args => {
            if (p.cmdline.len == 0) return c.fmtBuf(buf, "[{s}]", .{p.comm});
            const n = @min(p.cmdline.len, buf.len);
            @memcpy(buf[0..n], p.cmdline[0..n]);
            for (buf[0..n]) |*ch| if (ch.* == 0) {
                ch.* = ' ';
            };
            return buf[0..n];
        },
        .stat => {
            var w: std.Io.Writer = .fixed(buf);
            w.writeByte(p.state) catch {};
            if (bsd) {
                if (p.nice < 0) w.writeByte('<') catch {};
                if (p.nice > 0) w.writeByte('N') catch {};
                if (p.vm_lck_kb > 0) w.writeByte('L') catch {};
                if (p.session == p.pid) w.writeByte('s') catch {};
                if (p.nthreads > 1) w.writeByte('l') catch {};
                if (p.tpgid == p.pgrp and p.tty_nr != 0) w.writeByte('+') catch {};
            }
            return w.buffered();
        },
        .tty => return c.fmtBuf(buf, "{s}", .{pr.ttyName(&nb, p.tty_nr)}),
        .time => return fmtTime(buf, p.utime + p.stime, bsd),
        .etime => {
            const s: u64 = @intFromFloat(elapsed);
            if (s >= 86400) return c.fmtBuf(buf, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 86400, (s / 3600) % 24, (s / 60) % 60, s % 60 });
            if (s >= 3600) return c.fmtBuf(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 });
            return c.fmtBuf(buf, "{d:0>2}:{d:0>2}", .{ s / 60, s % 60 });
        },
        .rss => return c.fmtBuf(buf, "{d}", .{p.vm_rss_kb orelse p.rss_pages * page_kb}),
        .flags => return c.fmtBuf(buf, "{d}", .{(p.flags >> 6) & 7}),
        .pri => return c.fmtBuf(buf, "{d}", .{p.priority + 60}),
        .addr => return "-",
        .sz => return c.fmtBuf(buf, "{d}", .{p.vsize / 4096}),
        .state1 => return c.fmtBuf(buf, "{c}", .{p.state}),
        .wchan => {
            var pb: [64]u8 = undefined;
            var wb: [64]u8 = undefined;
            const wc = c.readSmall(c.fmtBuf(&pb, "/proc/{d}/wchan", .{p.pid}), &wb) orelse "";
            const t = mem.trim(u8, wc, " \n");
            if (t.len == 0 or c.eql(t, "0")) return "-";
            return c.fmtBuf(buf, "{s}", .{t[0..@min(t.len, 6)]});
        },
        .vsz => return c.fmtBuf(buf, "{d}", .{p.vsize / 1024}),
        .pcpu, .c_ => {
            const cpu = @as(f64, @floatFromInt(p.utime + p.stime)) / hz / elapsed * 100;
            if (col == .c_) return c.fmtBuf(buf, "{d}", .{@as(u64, @intFromFloat(cpu))});
            if (cpu >= 99.95) return c.fmtBuf(buf, "{d}", .{@as(u64, @intFromFloat(cpu))});
            return c.fmtBuf(buf, "{d:.1}", .{cpu});
        },
        .pmem => {
            if (mem_total_kb == 0) return "0.0";
            const pm = @as(f64, @floatFromInt(p.rss_pages * page_kb)) * 100 / @as(f64, @floatFromInt(mem_total_kb));
            return c.fmtBuf(buf, "{d:.1}", .{pm});
        },
        .nice => return c.fmtBuf(buf, "{d}", .{p.nice}),
        .start, .stime => {
            const t = boot_time + @as(i64, @intFromFloat(@as(f64, @floatFromInt(p.starttime)) / hz));
            const tm = c.localtime(t);
            const nowt = c.now().sec;
            var w: std.Io.Writer = .fixed(buf);
            if (nowt - t < 86400) {
                c.strftime(&w, "%H:%M", tm, 0, t) catch {};
            } else if (nowt - t < 86400 * 365) {
                c.strftime(&w, "%b%d", tm, 0, t) catch {};
            } else c.strftime(&w, "%Y", tm, 0, t) catch {};
            return w.buffered();
        },
    }
}

fn rightAligned(col: Col) bool {
    return switch (col) {
        .pid, .ppid, .uid, .rss, .vsz, .pcpu, .pmem, .nice, .time, .etime, .c_, .flags, .pri, .sz => true,
        else => false,
    };
}

pub fn main(args: c.Args) !u8 {
    var all = false;
    var bsd_a = false;
    var bsd_x = false;
    var full = false;
    var long = false;
    var user_fmt = false;
    var no_headers = false;
    var custom: std.ArrayList(Col) = .empty;
    var pid_filter: std.ArrayList(i32) = .empty;
    var user_filter: std.ArrayList(u32) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (c.eql(a, "--help")) c.printHelp();
        if (c.eql(a, "--version")) c.printVersion();
        if (c.eql(a, "--no-headers") or c.eql(a, "--no-heading")) {
            no_headers = true;
            continue;
        }
        const takesArg = struct {
            fn f(argv: c.Args, idx: *usize, rest: []const u8) []const u8 {
                if (rest.len > 0) return rest;
                idx.* += 1;
                if (idx.* >= argv.len) c.usageErr("option requires an argument", .{});
                return argv[idx.*];
            }
        }.f;
        var opts: []const u8 = a;
        var dash = false;
        if (mem.startsWith(u8, a, "--")) {
            const eq = mem.indexOfScalar(u8, a, '=');
            const name = a[2..(eq orelse a.len)];
            const val = if (eq) |e| a[e + 1 ..] else "";
            if (c.eql(name, "pid")) {
                const v = takesArg(args, &i, val);
                var it = mem.tokenizeAny(u8, v, ", ");
                while (it.next()) |x| try pid_filter.append(c.gpa, std.fmt.parseInt(i32, x, 10) catch c.usageErr("process ID list syntax error", .{}));
            } else if (c.eql(name, "user")) {
                const v = takesArg(args, &i, val);
                var it = mem.tokenizeAny(u8, v, ", ");
                while (it.next()) |x| try user_filter.append(c.gpa, if (c.userByName(x)) |u| u.uid else @intCast(c.parseUint(x) orelse c.usageErr("user name does not exist", .{})));
            } else if (c.eql(name, "format")) {
                const v = takesArg(args, &i, val);
                var it = mem.tokenizeAny(u8, v, ", ");
                while (it.next()) |x| try custom.append(c.gpa, parseCol(x) orelse c.usageErr("unknown user-defined format specifier \"{s}\"", .{x}));
            } else c.usageErr("unrecognized option '{s}'", .{a});
            continue;
        }
        if (a.len > 0 and a[0] == '-') {
            dash = true;
            opts = a[1..];
        }
        var k: usize = 0;
        while (k < opts.len) : (k += 1) {
            const ch = opts[k];
            switch (ch) {
                'A', 'e' => if (dash) {
                    all = true;
                },
                'a' => if (dash) {
                    all = true;
                } else {
                    bsd_a = true;
                },
                'x' => bsd_x = true,
                'f' => full = true,
                'F' => full = true,
                'l' => long = true,
                'u', 'U' => {
                    if (dash or ch == 'U') {
                        const v = takesArg(args, &i, opts[k + 1 ..]);
                        var it = mem.tokenizeAny(u8, v, ", ");
                        while (it.next()) |x| try user_filter.append(c.gpa, if (c.userByName(x)) |u| u.uid else @intCast(c.parseUint(x) orelse c.usageErr("user name does not exist", .{})));
                        k = opts.len;
                    } else user_fmt = true;
                },
                'p' => {
                    const v = takesArg(args, &i, opts[k + 1 ..]);
                    var it = mem.tokenizeAny(u8, v, ", ");
                    while (it.next()) |x| try pid_filter.append(c.gpa, std.fmt.parseInt(i32, x, 10) catch c.usageErr("process ID list syntax error", .{}));
                    k = opts.len;
                },
                'o' => {
                    const v = takesArg(args, &i, opts[k + 1 ..]);
                    var it = mem.tokenizeAny(u8, v, ", ");
                    while (it.next()) |x| {
                        var nm = x;
                        if (mem.indexOfScalar(u8, x, '=')) |e| nm = x[0..e];
                        try custom.append(c.gpa, parseCol(nm) orelse c.usageErr("unknown user-defined format specifier \"{s}\"", .{x}));
                    }
                    k = opts.len;
                },
                'w', 'H', 'L', 'm', 'j', 'y', 'c', 'h', 'r', 'T', 'v', 'S' => {},
                else => c.usageErr("unsupported option (BSD syntax)", .{}),
            }
        }
    }
    // environment
    var buf: [256]u8 = undefined;
    uptime = pr.uptimeSecs();
    if (pr.memInfo()) |m| mem_total_kb = m.total;
    boot_time = c.now().sec - @as(i64, @intFromFloat(uptime));
    if (c.readSmall("/proc/stat", &buf)) |_| {
        var big: [16384]u8 = undefined;
        if (c.readSmall("/proc/stat", &big)) |s| {
            var lines = mem.splitScalar(u8, s, '\n');
            while (lines.next()) |line| if (mem.startsWith(u8, line, "btime ")) {
                boot_time = c.parseInt(mem.trim(u8, line[6..], " ")) orelse boot_time;
            };
        }
    }
    const bsd = user_fmt or bsd_a or bsd_x;
    var cols: std.ArrayList(Col) = .empty;
    if (custom.items.len > 0) {
        try cols.appendSlice(c.gpa, custom.items);
    } else if (user_fmt) {
        try cols.appendSlice(c.gpa, &.{ .user, .pid, .pcpu, .pmem, .vsz, .rss, .tty, .stat, .start, .time, .args });
    } else if (full and !long) {
        try cols.appendSlice(c.gpa, &.{ .user, .pid, .ppid, .c_, .stime, .tty, .time, .args });
    } else if (long) {
        if (full) {
            try cols.appendSlice(c.gpa, &.{ .flags, .state1, .user, .pid, .ppid, .c_, .pri, .nice, .addr, .sz, .wchan, .stime, .tty, .time, .args });
        } else try cols.appendSlice(c.gpa, &.{ .flags, .state1, .uid, .pid, .ppid, .c_, .pri, .nice, .addr, .sz, .wchan, .tty, .time, .comm });
    } else if (bsd) {
        try cols.appendSlice(c.gpa, &.{ .pid, .tty, .stat, .time, .args });
    } else {
        try cols.appendSlice(c.gpa, &.{ .pid, .tty, .time, .comm });
    }
    // selection
    const my_uid = c.sys.geteuid();
    var my_tty: u32 = 0;
    if (pr.read(c.sys.getpid())) |me| my_tty = me.tty_nr;
    var procs: std.ArrayList(pr.Proc) = .empty;
    for (pr.listPids()) |pid| {
        const p = pr.read(pid) orelse continue;
        var sel = false;
        if (pid_filter.items.len > 0 or user_filter.items.len > 0) {
            if (mem.indexOfScalar(i32, pid_filter.items, pid) != null) sel = true;
            if (mem.indexOfScalar(u32, user_filter.items, p.uid) != null) sel = true;
        } else if (all) {
            sel = true;
        } else if (bsd_a and bsd_x) {
            sel = true;
        } else if (bsd_a) {
            sel = p.tty_nr != 0;
        } else if (bsd_x) {
            sel = p.uid == my_uid;
        } else {
            sel = p.uid == my_uid and p.tty_nr == my_tty;
        }
        if (sel) try procs.append(c.gpa, p);
    }
    // render (procps-style fixed widths with overflow compensation)
    if (c.readSmall("/proc/sys/kernel/pid_max", &buf)) |pm| {
        pid_width = @max(5, mem.trim(u8, pm, " \n").len);
    }
    const ncols = cols.items.len;
    var hdrs = try c.gpa.alloc([]const u8, ncols);
    for (cols.items, 0..) |col, k| {
        var hdr = colHeader(col);
        if (full and col == .user) hdr = "UID";
        if (full and col == .args) hdr = "CMD";
        if (custom.items.len == 0 and !bsd and col == .comm) hdr = "CMD";
        hdrs[k] = hdr;
    }
    const w = c.out;
    const tw: usize = if (c.isatty(1)) c.termWidth() else std.math.maxInt(usize);
    const Emit = struct {
        fn row(wr: *std.Io.Writer, cl: []const Col, vals: []const []const u8, is_bsd: bool, limit: usize) !void {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(c.gpa);
            var correct: usize = 0;
            for (cl, 0..) |col, k| {
                const last = k + 1 == cl.len;
                var v = vals[k];
                const width = colWidth(col, is_bsd);
                if (k > 0) {
                    try line.append(c.gpa, ' ');
                    correct += 1;
                }
                if (col == .user and v.len > width and !c.eql(v, "USER") and !c.eql(v, "UID")) {
                    var tb: [16]u8 = undefined;
                    v = c.fmtBuf(&tb, "{s}+", .{v[0 .. width - 1]});
                    v = try c.gpa.dupe(u8, v);
                }
                const target = correct + width;
                if (rightAligned(col)) {
                    const cur = line.items.len;
                    if (cur + v.len < target) try line.appendNTimes(c.gpa, ' ', target - cur - v.len);
                    try line.appendSlice(c.gpa, v);
                } else {
                    try line.appendSlice(c.gpa, v);
                    if (!last and line.items.len < target) try line.appendNTimes(c.gpa, ' ', target - line.items.len);
                }
                correct = target;
            }
            while (line.items.len > 0 and line.items[line.items.len - 1] == ' ') line.items.len -= 1;
            const out_line = if (line.items.len > limit) line.items[0..limit] else line.items;
            try wr.writeAll(out_line);
            try wr.writeByte('\n');
        }
    };
    if (!no_headers) try Emit.row(w, cols.items, hdrs, bsd, tw);
    for (procs.items) |p| {
        var row = try c.gpa.alloc([]const u8, ncols);
        for (cols.items, 0..) |col, k| {
            var cb: [4096]u8 = undefined;
            row[k] = try c.gpa.dupe(u8, cellText(&cb, col, p, bsd));
        }
        try Emit.row(w, cols.items, row, bsd, tw);
    }
    return if (procs.items.len == 0 and (pid_filter.items.len > 0 or user_filter.items.len > 0)) 1 else 0;
}
