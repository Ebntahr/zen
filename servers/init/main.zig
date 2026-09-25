//! init — the first user process (pid 1).
//!
//! Boot sequence:
//!   1. stdio on the kernel console (`debug:`)
//!   2. read `sys:devices`, start drivers from the boot image (`initfs:`)
//!   3. start the ext2 file server on the root disk → `file:` scheme
//!   4. start and supervise services from /etc/zen/services.conf
//!   5. reap orphans forever
//!
//! `sys:devices` lines: `<compatible> <base> <size> <irq> [virtio=<id>]`.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");

const posix = std.posix;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

const Service = struct {
    name: []const u8,
    restart: bool,
    path: []const u8,
    args: []const []const u8,
    pid: u32 = 0,
    starts: u32 = 0,
    last_start_ns: u64 = 0,
};

var services: std.ArrayList(Service) = .empty;

const default_services =
    \\# name          restart  path [args...]
    \\ptyd            always   /System/Library/Servers/ptyd
    \\launchd         always   /System/Library/Servers/launchd
    \\windowserver    always   /System/Library/Servers/windowserver
    \\loginwindow     always   /System/Library/CoreServices/loginwindow
    \\getty           always   /usr/sbin/getty debug:
;

fn log(comptime fmt: []const u8, args: anytype) void {
    zen.sys.logf("init: " ++ fmt, args);
}

fn nowNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const base_env = [_][]const u8{
    "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=/var/root",
    "USER=root",
    "TERM=xterm-256color",
    "LANG=en_US.UTF-8",
};

fn spawnDaemon(path: []const u8, args: []const []const u8) !u32 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, path);
    try argv.appendSlice(gpa, args);
    return zen.sys.spawn(gpa, path, .{
        .argv = argv.items,
        .env = &base_env,
        .cwd = "/",
        .new_session = true,
        .daemon = true,
    });
}

/// Wait until a scheme answers (its server has registered).
fn waitForScheme(url: []const u8, timeout_ms: u64) bool {
    const deadline = nowNs() + timeout_ms * std.time.ns_per_ms;
    while (nowNs() < deadline) {
        if (posix.open(url, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            posix.close(fd);
            return true;
        } else |_| {}
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}

const Dev = struct { compat: []const u8, base: u64, irq: u32, virtio: u32 };

fn readDevices() ![]Dev {
    const text = try std.fs.cwd().readFileAlloc(gpa, "sys:devices", 64 * 1024);
    var list: std.ArrayList(Dev) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const compat = it.next() orelse continue;
        const base = std.fmt.parseInt(u64, it.next() orelse continue, 0) catch continue;
        _ = it.next(); // size
        const irq = std.fmt.parseInt(u32, it.next() orelse continue, 0) catch continue;
        var vid: u32 = 0;
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "virtio=")) vid = std.fmt.parseInt(u32, kv[7..], 10) catch 0;
        }
        try list.append(gpa, .{ .compat = compat, .base = base, .irq = irq, .virtio = vid });
    }
    return list.toOwnedSlice(gpa);
}

fn hex(v: u64) []const u8 {
    return std.fmt.allocPrint(gpa, "0x{x}", .{v}) catch "0";
}

fn dec(v: u32) []const u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{v}) catch "0";
}

fn startDrivers() !void {
    const devs = readDevices() catch |err| {
        log("cannot read sys:devices: {s}", .{@errorName(err)});
        return;
    };
    var disks: u32 = 0;
    var input_args: std.ArrayList([]const u8) = .empty;
    for (devs) |d| {
        switch (d.virtio) {
            2 => {
                const name = if (disks == 0) "disk" else std.fmt.allocPrint(gpa, "disk{d}", .{disks}) catch continue;
                disks += 1;
                _ = spawnDaemon("initfs:/drivers/virtio-blkd", &.{ hex(d.base), dec(d.irq), name }) catch |e| log("virtio-blkd: {s}", .{@errorName(e)});
            },
            16 => _ = spawnDaemon("initfs:/drivers/virtio-gpud", &.{ hex(d.base), dec(d.irq) }) catch |e| log("virtio-gpud: {s}", .{@errorName(e)}),
            18 => {
                try input_args.append(gpa, hex(d.base));
                try input_args.append(gpa, dec(d.irq));
            },
            else => {},
        }
    }
    if (input_args.items.len > 0) {
        _ = spawnDaemon("initfs:/drivers/virtio-inputd", input_args.items) catch |e| log("virtio-inputd: {s}", .{@errorName(e)});
    }
    if (disks == 0) log("warning: no disk found", .{});
}

fn mountRoot() bool {
    if (!waitForScheme("disk:", 5000)) {
        log("root disk did not appear", .{});
        return false;
    }
    _ = spawnDaemon("initfs:/servers/fsd", &.{"disk:"}) catch |e| {
        log("fsd: {s}", .{@errorName(e)});
        return false;
    };
    if (!waitForScheme("file:/", 10000)) {
        log("file server did not start", .{});
        return false;
    }
    log("root filesystem mounted", .{});
    return true;
}

fn loadServices() !void {
    const text = std.fs.cwd().readFileAlloc(gpa, "/etc/zen/services.conf", 64 * 1024) catch try gpa.dupe(u8, default_services);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        const restart = it.next() orelse continue;
        const path = it.next() orelse continue;
        var args: std.ArrayList([]const u8) = .empty;
        while (it.next()) |a| try args.append(gpa, a);
        try services.append(gpa, .{
            .name = name,
            .restart = std.mem.eql(u8, restart, "always"),
            .path = path,
            .args = try args.toOwnedSlice(gpa),
        });
    }
}

fn startService(s: *Service) void {
    // Back off services that crash in a loop.
    const now = nowNs();
    if (s.starts > 5 and now - s.last_start_ns < 10 * std.time.ns_per_s) {
        log("{s} is crashing repeatedly; giving up", .{s.name});
        s.restart = false;
        return;
    }
    s.last_start_ns = now;
    s.starts += 1;
    s.pid = spawnDaemon(s.path, s.args) catch |err| {
        log("cannot start {s}: {s}", .{ s.name, @errorName(err) });
        s.pid = 0;
        return;
    };
    log("started {s} (pid {d})", .{ s.name, s.pid });
}

fn emergencyShell() void {
    log("starting emergency shell on the console", .{});
    for ([_][]const u8{ "/bin/zensh", "initfs:/bin/zensh" }) |sh| {
        const pid = zen.sys.spawn(gpa, sh, .{ .argv = &.{ sh, "-i" }, .env = &base_env, .new_session = true }) catch continue;
        _ = posix.waitpid(@intCast(pid), 0);
        return;
    }
}

pub fn main() !void {
    zen.sys.setName("init");
    // stdio on the kernel console
    if (posix.open("debug:", .{ .ACCMODE = .RDWR }, 0)) |fd| {
        for ([_]i32{ 0, 1, 2 }) |t| if (fd != t) {
            posix.dup2(fd, t) catch {};
        };
    } else |_| {}
    log("Zen OS {s} \"{s}\" starting", .{ abi.os_version, abi.os_codename });

    try startDrivers();
    if (!mountRoot()) {
        emergencyShell();
    }
    posix.chdir("/") catch {};

    // Volatile directories.
    for ([_][]const u8{ "/tmp", "/var/run", "/var/log" }) |d| std.fs.cwd().makePath(d) catch {};

    try loadServices();
    for (services.items) |*s| startService(s);

    while (true) {
        const r = posix.waitpid(-1, 0);
        if (r.pid <= 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }
        const pid: u32 = @intCast(r.pid);
        for (services.items) |*s| {
            if (s.pid != pid) continue;
            log("{s} (pid {d}) exited with status {d}", .{ s.name, pid, r.status });
            s.pid = 0;
            if (s.restart) startService(s);
        }
    }
}
