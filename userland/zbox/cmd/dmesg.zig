const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;
const linux = std.os.linux;

pub const help =
    \\Usage: dmesg [options]
    \\Display or control the kernel ring buffer.
    \\
    \\  -C, --clear            clear the kernel ring buffer
    \\  -c, --read-clear       read and clear all messages
    \\  -r, --raw              print the raw message buffer
    \\  -t, --notime           don't show any timestamp with messages
    \\  -w, --follow           wait for new messages
    \\  -n, --console-level N  set level of messages printed to console
    \\
    \\Reads the Zen kernel log from sys:log, falling back to /dev/kmsg and
    \\the syslog(2) interface.
    \\
;

var notime = false;
var raw = false;

fn stripPrio(line: []const u8) []const u8 {
    if (raw) return line;
    if (line.len > 2 and line[0] == '<') {
        if (mem.indexOfScalar(u8, line[0..@min(line.len, 6)], '>')) |e| return line[e + 1 ..];
    }
    return line;
}

fn printKmsgRecord(w: *std.Io.Writer, rec: []const u8) !void {
    // "prio,seq,ts_usec,flags[,...];message\n"
    const semi = mem.indexOfScalar(u8, rec, ';') orelse return;
    var fields = mem.splitScalar(u8, rec[0..semi], ',');
    const prio = fields.next() orelse "6";
    _ = fields.next();
    const ts = c.parseUint(fields.next() orelse "0") orelse 0;
    var msg = rec[semi + 1 ..];
    if (mem.indexOfScalar(u8, msg, '\n')) |nl| msg = msg[0..nl];
    if (raw) try w.print("<{s}>", .{prio});
    if (!notime) try w.print("[{d: >5}.{d:0>6}] ", .{ ts / 1_000_000, ts % 1_000_000 });
    try w.print("{s}\n", .{msg});
}

pub fn main(args: c.Args) !u8 {
    var clear = false;
    var read_clear = false;
    var follow = false;
    var level: ?u64 = null;
    var p = c.Parser.init(args, &.{
        .{ "clear", 'C' }, .{ "read-clear", 'c' }, .{ "raw", 'r' }, .{ "notime", 't' }, .{ "follow", 'w' }, .{ "console-level", 'n' },
        .{ "human", 'H' }, .{ "ctime", 'T' }, .{ "color", 'L' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'C' => clear = true,
            'c' => read_clear = true,
            'r' => raw = true,
            't' => notime = true,
            'w' => follow = true,
            'n' => level = c.parseUint(p.arg()) orelse c.fatal("invalid level", .{}),
            'H', 'T', 'L', 'x', 'k' => {},
            else => p.bad(o),
        },
        else => p.bad(o),
    };
    if (level) |l| {
        const rc = linux.syscall3(.syslog, 8, 0, l);
        if (std.posix.errno(rc) != .SUCCESS) c.fatal("klogctl failed: {s}", .{c.strerror(c.mapErrno(std.posix.errno(rc)))});
        return 0;
    }
    if (clear) {
        const rc = linux.syscall3(.syslog, 5, 0, 0);
        if (std.posix.errno(rc) != .SUCCESS) c.fatal("klogctl failed: {s}", .{c.strerror(c.mapErrno(std.posix.errno(rc)))});
        return 0;
    }
    const w = c.out;
    // 1. Zen kernel log scheme
    if (c.sys.open("sys:log", c.O_RDONLY, 0)) |fd| {
        defer c.sys.close(fd);
        var r = c.LineReader.init(fd);
        while (true) {
            const line = (r.next() catch break) orelse break;
            try w.print("{s}\n", .{stripPrio(line)});
        }
        if (!follow) return 0;
        while (true) {
            c.flush();
            c.sys.nanosleep(500_000_000);
            while (true) {
                const line = (r.next() catch break) orelse break;
                try w.print("{s}\n", .{stripPrio(line)});
            }
            r.eof = false;
        }
    } else |_| {}
    // 2. /dev/kmsg
    if (c.sys.open("/dev/kmsg", .{ .ACCMODE = .RDONLY, .NONBLOCK = !follow, .CLOEXEC = true }, 0)) |fd| {
        defer c.sys.close(fd);
        var buf: [8192]u8 = undefined;
        var got_any = false;
        while (true) {
            const n = c.sys.read(fd, &buf) catch |e| {
                if (e == error.PIPE) continue;
                if (e == error.AGAIN) break;
                if (!got_any) break;
                return 0;
            };
            if (n == 0) break;
            got_any = true;
            try printKmsgRecord(w, buf[0..n]);
            if (follow) c.flush();
        }
        if (got_any or follow) {
            if (read_clear) _ = linux.syscall3(.syslog, 5, 0, 0);
            return 0;
        }
    } else |_| {}
    // 3. syslog(2)
    const size_rc = linux.syscall3(.syslog, 10, 0, 0);
    var size: usize = 1 << 17;
    if (std.posix.errno(size_rc) == .SUCCESS and size_rc > 0) size = size_rc;
    const buf = try c.gpa.alloc(u8, size);
    const rc = linux.syscall3(.syslog, if (read_clear) 4 else 3, @intFromPtr(buf.ptr), size);
    const e = std.posix.errno(rc);
    if (e != .SUCCESS) c.fatal("read kernel buffer failed: {s}", .{c.strerror(c.mapErrno(e))});
    var it = mem.splitScalar(u8, buf[0..rc], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var l = stripPrio(line);
        if (notime and l.len > 0 and l[0] == '[') {
            if (mem.indexOfScalar(u8, l, ']')) |k| l = mem.trimLeft(u8, l[k + 1 ..], " ");
        }
        try w.print("{s}\n", .{l});
    }
    return 0;
}
