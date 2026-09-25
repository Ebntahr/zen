const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: tail [OPTION]... [FILE]...
    \\Print the last 10 lines of each FILE to standard output.
    \\With more than one FILE, precede each with a header giving the file name.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to
    \\                             output starting with byte NUM of each file
    \\  -f, --follow[={name|descriptor}]
    \\                           output appended data as the file grows
    \\  -F                       same as --follow=name --retry
    \\  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
    \\                             or use -n +NUM to skip NUM-1 lines at the start
    \\      --pid=PID            with -f, terminate after process ID, PID dies
    \\  -q, --quiet, --silent    never output headers giving file names
    \\      --retry              keep trying to open a file if it is inaccessible
    \\  -s, --sleep-interval=N   with -f, sleep for approximately N seconds
    \\                             (default 1.0) between iterations
    \\  -v, --verbose            always output headers giving file names
    \\  -z, --zero-terminated    line delimiter is NUL, not newline
    \\
;

var delim: u8 = '\n';
var last_header: ?usize = null;
var show_headers = false;

const Follow = struct {
    name: []const u8,
    fd: i32,
    pos: u64,
    ino: u64,
    dev: u64,
    idx: usize,
    alive: bool,
    regular: bool,
};

fn header(names: []const []const u8, idx: usize, first: bool) !void {
    if (!show_headers) return;
    if (last_header != null and last_header.? == idx) return;
    if (!first) try c.out.writeByte('\n');
    const n = names[idx];
    try c.out.print("==> {s} <==\n", .{if (c.eql(n, "-")) "standard input" else n});
    last_header = idx;
}

fn copyRange(fd: i32, from: u64, to: u64) !void {
    var buf: [65536]u8 = undefined;
    var off = from;
    while (off < to) {
        const want: usize = @intCast(@min(to - off, buf.len));
        const n = try c.sys.pread(fd, buf[0..want], off);
        if (n == 0) break;
        try c.out.writeAll(buf[0..n]);
        off += n;
    }
}

fn lastLinesStart(data: []const u8, n: u64) usize {
    if (n == 0) return data.len;
    var i = data.len;
    if (i > 0 and data[i - 1] == delim) i -= 1;
    var count: u64 = 0;
    while (i > 0) {
        i -= 1;
        if (data[i] == delim) {
            count += 1;
            if (count == n) return i + 1;
        }
    }
    return 0;
}

fn skipLinesStart(data: []const u8, n: u64) usize {
    // output starting with line n (1-based)
    var i: usize = 0;
    var line: u64 = 1;
    while (line < n and i < data.len) {
        const k = mem.indexOfScalarPos(u8, data, i, delim) orelse return data.len;
        i = k + 1;
        line += 1;
    }
    return i;
}

/// Output the tail of fd; returns the end offset for following.
fn tailFd(fd: i32, lines: bool, n: u64, from_start: bool) !u64 {
    const st = c.sys.fstat(fd) catch null;
    const seekable = st != null and st.?.isReg() and (c.sys.lseek(fd, 0, 1) catch null) != null;
    if (seekable and !from_start) {
        const size: u64 = @intCast(st.?.size);
        if (!lines) {
            const start = if (n >= size) 0 else size - n;
            try copyRange(fd, start, size);
            return size;
        }
        // scan backwards in blocks
        var pos = size;
        var count: u64 = 0;
        var start: u64 = 0;
        var buf: [8192]u8 = undefined;
        var first_block = true;
        outer: while (pos > 0 and n > 0) {
            const blk: usize = @intCast(@min(pos, buf.len));
            pos -= blk;
            const got = try c.sys.pread(fd, buf[0..blk], pos);
            var i = got;
            if (first_block and i > 0 and buf[i - 1] == delim) i -= 1;
            first_block = false;
            while (i > 0) {
                i -= 1;
                if (buf[i] == delim) {
                    count += 1;
                    if (count == n) {
                        start = pos + i + 1;
                        break :outer;
                    }
                }
            }
        }
        if (n == 0) start = size;
        try copyRange(fd, start, size);
        return size;
    }
    const data = try c.readFdAll(fd);
    defer c.gpa.free(data);
    var start: usize = 0;
    if (from_start) {
        start = if (lines) skipLinesStart(data, n) else @intCast(@min(data.len, if (n == 0) 0 else n - 1));
    } else {
        start = if (lines) lastLinesStart(data, n) else if (n >= data.len) 0 else data.len - @as(usize, @intCast(n));
    }
    try c.out.writeAll(data[start..]);
    return data.len;
}

fn parseNum(s: []const u8, what: []const u8, from_start: *bool) u64 {
    var t = s;
    from_start.* = false;
    if (t.len > 0 and t[0] == '+') {
        from_start.* = true;
        t = t[1..];
    } else if (t.len > 0 and t[0] == '-') t = t[1..];
    return c.parseSize(t) orelse c.fatal("invalid number of {s}: {f}", .{ what, c.q(s) });
}

pub fn main(args_in: c.Args) !u8 {
    var args = args_in;
    var lines = true;
    var n: u64 = 10;
    var from_start = false;
    var follow = false;
    var follow_name = false;
    var retry = false;
    var verbose: ?bool = null;
    var sleep_ns: u64 = 1_000_000_000;
    var pid: ?i32 = null;
    // obsolete: tail -NUM[lcf] / +NUM[lcf]
    if (args.len > 1 and args[1].len > 1 and (args[1][0] == '-' or args[1][0] == '+') and std.ascii.isDigit(args[1][1])) {
        const a = args[1];
        from_start = a[0] == '+';
        var k: usize = 1;
        while (k < a.len and std.ascii.isDigit(a[k])) k += 1;
        n = c.parseUint(a[1..k]) orelse 10;
        for (a[k..]) |ch| switch (ch) {
            'c' => lines = false,
            'l' => lines = true,
            'f' => follow = true,
            else => c.usageErr("invalid option -- '{c}'", .{ch}),
        };
        const na = try c.gpa.alloc([:0]const u8, args.len - 1);
        na[0] = args[0];
        @memcpy(na[1..], args[2..]);
        args = na;
    }
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "bytes", 'c' },  .{ "follow", 0 }, .{ "lines", 'n' }, .{ "pid", 0 }, .{ "quiet", 'q' },
        .{ "silent", 'q' }, .{ "retry", 0 },  .{ "sleep-interval", 's' }, .{ "verbose", 'v' },
        .{ "zero-terminated", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => {
                lines = false;
                n = parseNum(p.arg(), "bytes", &from_start);
            },
            'n' => {
                lines = true;
                n = parseNum(p.arg(), "lines", &from_start);
            },
            'f' => follow = true,
            'F' => {
                follow = true;
                follow_name = true;
                retry = true;
            },
            'q' => verbose = false,
            'v' => verbose = true,
            's' => {
                const a = p.arg();
                const v = std.fmt.parseFloat(f64, a) catch c.fatal("invalid number of seconds: {f}", .{c.q(a)});
                sleep_ns = @intFromFloat(@max(v, 0) * 1e9);
            },
            'z' => delim = 0,
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "follow")) {
                follow = true;
                if (p.optArg()) |v| follow_name = c.eql(v, "name");
            } else if (c.eql(name, "pid")) {
                const a = p.arg();
                pid = @intCast(c.parseUint(a) orelse c.fatal("invalid PID: {f}", .{c.q(a)}));
            } else if (c.eql(name, "retry")) retry = true else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    show_headers = verbose orelse (files.items.len > 1);
    var status: u8 = 0;
    var follows: std.ArrayList(Follow) = .empty;
    for (files.items, 0..) |f, idx| {
        const fd = c.openInput(f) orelse {
            status = 1;
            if (follow and retry and !c.eql(f, "-")) try follows.append(c.gpa, .{ .name = f, .fd = -1, .pos = 0, .ino = 0, .dev = 0, .idx = idx, .alive = false, .regular = true });
            continue;
        };
        try header(files.items, idx, idx == 0 or last_header == null);
        const end = tailFd(fd, lines, n, from_start) catch |e| blk: {
            if (e == error.WriteFailed) return e;
            c.warn("error reading {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
            break :blk 0;
        };
        const st = c.sys.fstat(fd) catch null;
        if (follow and st != null and (st.?.isReg() or follow_name)) {
            try follows.append(c.gpa, .{ .name = f, .fd = fd, .pos = end, .ino = st.?.ino, .dev = st.?.dev, .idx = idx, .alive = true, .regular = st.?.isReg() });
        } else c.closeInput(fd);
    }
    if (!follow or follows.items.len == 0) return status;
    c.flush();
    var buf: [65536]u8 = undefined;
    while (true) {
        if (pid) |pp| {
            if (c.sys.kill(pp, 0)) {} else |e| {
                if (e == error.SRCH) {
                    c.flush();
                    return status;
                }
            }
        }
        for (follows.items) |*fl| {
            if (follow_name) {
                // reopen if replaced or appeared
                if (c.sys.stat(fl.name)) |st| {
                    if (!fl.alive or st.ino != fl.ino or st.dev != fl.dev) {
                        if (c.sys.open(fl.name, c.O_RDONLY, 0)) |nfd| {
                            if (fl.alive) {
                                c.warn("{f} has been replaced;  following new file", .{c.q(fl.name)});
                                c.sys.close(fl.fd);
                            } else if (fl.fd == -1 or !fl.alive) {
                                if (fl.ino != 0 or fl.fd == -1) c.warn("{f} has appeared;  following new file", .{c.q(fl.name)});
                            }
                            fl.fd = nfd;
                            fl.pos = 0;
                            fl.ino = st.ino;
                            fl.dev = st.dev;
                            fl.alive = true;
                        } else |_| {}
                    }
                } else |_| {
                    if (fl.alive) {
                        c.warn("{f} has become inaccessible: No such file or directory", .{c.q(fl.name)});
                        c.sys.close(fl.fd);
                        fl.alive = false;
                    }
                }
            }
            if (!fl.alive) continue;
            const st = c.sys.fstat(fl.fd) catch continue;
            const size: u64 = @intCast(st.size);
            if (st.isReg() and size < fl.pos) {
                c.warn("{s}: file truncated", .{fl.name});
                fl.pos = 0;
            }
            while (true) {
                const got = c.sys.pread(fl.fd, &buf, fl.pos) catch break;
                if (got == 0) break;
                try header(files.items, fl.idx, false);
                try c.out.writeAll(buf[0..got]);
                fl.pos += got;
            }
        }
        c.flush();
        c.sys.nanosleep(sleep_ns);
    }
}
