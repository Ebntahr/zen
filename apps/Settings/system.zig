//! System information and actions for Settings: small file reads, the
//! `window:control` and `launch:ctl` services, statfs, directory sizes and
//! running privileged helpers (`sudo -S …`, `passwd --stdin`).
//!
//! Everything degrades gracefully on a development host where the Zen URLs
//! do not exist: readers return null and callers show fallbacks.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const zio = @import("zen").io;

/// Read a small file (or URL) into `buf`; null when it cannot be read.
pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = zio.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer zio.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = zio.read(fd, buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

/// Read a whole file (or URL). Caller frees.
pub fn readAll(allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const fd = zio.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer zio.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (list.items.len < max) {
        const got = zio.read(fd, &buf) catch break;
        if (got == 0) break;
        list.appendSlice(allocator, buf[0..got]) catch break;
    }
    return list.toOwnedSlice(allocator) catch null;
}

pub fn exists(path: []const u8) bool {
    posix.access(path, posix.F_OK) catch return false;
    return true;
}

/// Copy `s` into `buf` (truncating) and return the copy.
pub fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Host information
// ---------------------------------------------------------------------------

/// Computer name from /etc/hostname (or `sys:hostname`, or uname).
pub fn hostname(buf: []u8) []const u8 {
    var tmp: [256]u8 = undefined;
    for ([_][]const u8{ "/etc/hostname", "sys:hostname" }) |p| {
        if (readSmall(p, &tmp)) |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len > 0) return copyInto(buf, t);
        }
    }
    var uts: linux.utsname = undefined;
    if (linux.uname(&uts) == 0) {
        const n = std.mem.sliceTo(&uts.nodename, 0);
        if (n.len > 0) return copyInto(buf, n);
    }
    return copyInto(buf, "zen-os");
}

/// Total memory in bytes from /proc/meminfo (or `sys:meminfo`).
pub fn memTotal() ?u64 {
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ "/proc/meminfo", "sys:meminfo" }) |p| {
        const s = readSmall(p, &buf) orelse continue;
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
            var it = std.mem.tokenizeAny(u8, line["MemTotal:".len..], " \t");
            const v = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
            const unit = it.next() orelse "kB";
            return if (std.ascii.eqlIgnoreCase(unit, "kB")) v * 1024 else v;
        }
    }
    return null;
}

/// Kernel name/release from uname.
pub fn kernelRelease(buf: []u8) ?[]const u8 {
    var uts: linux.utsname = undefined;
    if (linux.uname(&uts) != 0) return null;
    const sys = std.mem.sliceTo(&uts.sysname, 0);
    const rel = std.mem.sliceTo(&uts.release, 0);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ sys, rel }) catch null;
}

pub fn isZen() bool {
    var uts: linux.utsname = undefined;
    if (linux.uname(&uts) != 0) return false;
    return std.mem.eql(u8, std.mem.sliceTo(&uts.sysname, 0), "Zen");
}

pub const FsStats = struct { total: u64, free: u64 };

/// Capacity of the file system holding `path` (statfs).
pub fn statfs(path: [*:0]const u8) ?FsStats {
    // struct statfs on 64-bit Linux: type, bsize, blocks, bfree, bavail, files,
    // ffree, fsid, namelen, frsize, flags, spare[4] — all 8-byte words.
    var st: [16]u64 = [_]u64{0} ** 16;
    const rc = linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&st));
    const signed: isize = @bitCast(rc);
    if (signed < 0) return null;
    const bsize = if (st[9] != 0) st[9] else st[1];
    if (bsize == 0 or st[2] == 0) return null;
    return .{ .total = st[2] * bsize, .free = st[4] * bsize };
}

/// A stable, random-looking serial number derived from /etc/machine-id (or
/// a fixed seed on machines without one).
pub fn serialNumber(buf: *[12]u8) []const u8 {
    var tmp: [128]u8 = undefined;
    const seed = if (readSmall("/etc/machine-id", &tmp)) |s| std.mem.trim(u8, s, " \r\n") else "zen-riscv64-golden-gate";
    var h = std.hash.Wyhash.hash(0x5E71A1, seed);
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
    buf[0] = 'Z';
    buf[1] = 'N';
    for (buf[2..]) |*c| {
        c.* = alphabet[@intCast(h % alphabet.len)];
        h /= alphabet.len;
        if (h == 0) h = std.hash.Wyhash.hash(7, seed);
    }
    return buf[0..];
}

/// Human-readable byte size ("512 MB", "7.8 GB").
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var i: usize = 0;
    // Decimal units, like macOS.
    while (v >= 1000 and i + 1 < units.len) : (i += 1) v /= 1000;
    if (i == 0) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
    if (v >= 100 or v == @round(v)) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[i] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "";
}

/// Memory size in binary units, rounded like "About This Mac" ("2 GB").
pub fn formatMemory(buf: []u8, bytes: u64) []const u8 {
    const gib: f64 = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (gib >= 1) {
        const r = @round(gib * 2) / 2;
        if (r == @round(r)) return std.fmt.bufPrint(buf, "{d:.0} GB", .{r}) catch "";
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{r}) catch "";
    }
    const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.0} MB", .{@round(mib)}) catch "";
}

/// Apparent size of a directory tree (bytes). Stops after `budget` entries
/// so a huge tree cannot freeze the UI.
pub fn dirSize(path: []const u8, budget: *usize) u64 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    return dirSizeIn(dir, budget, 0);
}

fn dirSizeIn(dir: std.fs.Dir, budget: *usize, depth: u32) u64 {
    if (depth > 24) return 0;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (budget.* == 0) return total;
        budget.* -= 1;
        switch (e.kind) {
            .file => {
                const st = dir.statFile(e.name) catch continue;
                total += st.size;
            },
            .directory => {
                var sub = dir.openDir(e.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                total += dirSizeIn(sub, budget, depth + 1);
            },
            else => {},
        }
    }
    return total;
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

/// Send one text command to the window server (`window:control`).
pub fn control(cmd: []const u8) bool {
    const fd = zio.open("window:control", .{ .ACCMODE = .WRONLY }, 0) catch return false;
    defer zio.close(fd);
    _ = zio.write(fd, cmd) catch return false;
    return true;
}

pub fn controlf(comptime fmt: []const u8, args: anytype) bool {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return false;
    return control(s);
}

/// Write a command to `launch:ctl` and read the reply line into `reply`.
pub fn launchCtl(cmd: []const u8, reply: []u8) ?[]const u8 {
    const fd = zio.open("launch:ctl", .{ .ACCMODE = .RDWR }, 0) catch return null;
    defer zio.close(fd);
    _ = zio.write(fd, cmd) catch return null;
    var n: usize = 0;
    while (n < reply.len) {
        const got = zio.read(fd, reply[n..]) catch break;
        if (got == 0) break;
        n += got;
        if (std.mem.indexOfScalar(u8, reply[0..n], '\n') != null) break;
    }
    return std.mem.trim(u8, reply[0..n], " \r\n");
}

// ---------------------------------------------------------------------------
// Running helpers
// ---------------------------------------------------------------------------

pub const RunResult = struct {
    /// Exit status (0 = success); 255 when the program could not be started,
    /// 254 when it was killed by a signal.
    code: u8,
    /// First line of standard error (trimmed), if any.
    message: []const u8,
};

/// Run `argv` with `input` on its standard input and wait for it. Standard
/// error is captured into `err_buf` (only the first line is returned).
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, input: []const u8, err_buf: []u8) RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |e| return .{ .code = 255, .message = @errorName(e) };
    if (child.stdin) |stdin| {
        stdin.writeAll(input) catch {};
        stdin.close();
        child.stdin = null;
    }
    var n: usize = 0;
    if (child.stderr) |stderr| {
        while (n < err_buf.len) {
            const got = stderr.read(err_buf[n..]) catch break;
            if (got == 0) break;
            n += got;
        }
        // Drain the rest so the child never blocks on a full pipe.
        var sink: [256]u8 = undefined;
        while (true) {
            const got = stderr.read(&sink) catch break;
            if (got == 0) break;
        }
    }
    const term = child.wait() catch |e| return .{ .code = 255, .message = @errorName(e) };
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 254,
    };
    var msg = std.mem.trim(u8, err_buf[0..n], " \r\n");
    // Report the last meaningful line (earlier ones are prompts / retries).
    if (std.mem.lastIndexOfScalar(u8, msg, '\n')) |nl| msg = std.mem.trim(u8, msg[nl + 1 ..], " \r\n");
    return .{ .code = code, .message = msg };
}

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

pub const Clock = struct {
    year: u16,
    month: u8,
    day: u8,
    weekday: u8,
    hour: u8,
    minute: u8,
};

pub fn now(offset_min: i32) ?Clock {
    const ts = posix.clock_gettime(.REALTIME) catch return null;
    const secs_i: i64 = ts.sec + @as(i64, offset_min) * 60;
    const secs: u64 = @intCast(@max(secs_i, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = @intFromEnum(md.month),
        .day = md.day_index + 1,
        .weekday = @intCast((day.day + 4) % 7), // 1970-01-01 was a Thursday; 0 = Sunday
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
    };
}

pub const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
pub const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// "14:05" or "2:05 PM".
pub fn formatTime(buf: []u8, c: Clock, h24: bool) []const u8 {
    if (h24) return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ c.hour, c.minute }) catch "";
    const h12 = if (c.hour % 12 == 0) 12 else c.hour % 12;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, c.minute, if (c.hour < 12) "AM" else "PM" }) catch "";
}

test "format helpers" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("7.8 GB", formatBytes(&b, 7_800_000_000));
    try std.testing.expectEqualStrings("512 MB", formatBytes(&b, 512_000_000));
    try std.testing.expectEqualStrings("2 GB", formatMemory(&b, 2 * 1024 * 1024 * 1024));
    const c = Clock{ .year = 2026, .month = 1, .day = 1, .weekday = 4, .hour = 14, .minute = 5 };
    try std.testing.expectEqualStrings("2:05 PM", formatTime(&b, c, false));
    try std.testing.expectEqualStrings("14:05", formatTime(&b, c, true));
    var s: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), serialNumber(&s).len);
}
