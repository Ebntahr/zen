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
    /// URLs that must answer before the service starts (`wait=<url>`).
    waits: []const []const u8 = &.{},
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

/// Hosted on Linux: the display and input come from vncd (browser/VNC).
const default_hosted_services =
    \\# name          restart  [wait=<url>...] path [args...]
    \\vncd            always   /System/Library/Servers/vncd
    \\launchd         always   /System/Library/Servers/launchd
    \\windowserver    always   wait=display:0 /System/Library/Servers/windowserver
    \\loginwindow     always   wait=window:clipboard /System/Library/CoreServices/loginwindow
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
        if (zen.io.open(url, .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            zen.io.close(fd);
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

fn loadServices(hosted: bool) !void {
    const conf = if (hosted) "/etc/zen/services.hosted.conf" else "/etc/zen/services.conf";
    const text = std.fs.cwd().readFileAlloc(gpa, conf, 64 * 1024) catch try gpa.dupe(u8, if (hosted) default_hosted_services else default_services);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        const restart = it.next() orelse continue;
        var waits: std.ArrayList([]const u8) = .empty;
        var path = it.next() orelse continue;
        while (std.mem.startsWith(u8, path, "wait=")) {
            try waits.append(gpa, path["wait=".len..]);
            path = it.next() orelse break;
        }
        if (std.mem.startsWith(u8, path, "wait=")) continue;
        var args: std.ArrayList([]const u8) = .empty;
        while (it.next()) |a| try args.append(gpa, a);
        try services.append(gpa, .{
            .name = name,
            .restart = std.mem.eql(u8, restart, "always"),
            .waits = try waits.toOwnedSlice(gpa),
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
    for (s.waits) |url| {
        if (!waitForScheme(url, 15000)) log("{s}: {s} did not appear; starting anyway", .{ s.name, url });
    }
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
        _ = zen.sys.reap(@intCast(pid), true);
        return;
    }
}

// ---------------------------------------------------------------------------
// Hosted on Linux (zen-hosted / Docker)
// ---------------------------------------------------------------------------

var hosted_signal = std.atomic.Value(u8).init(0);

fn onSignal(sig: i32) callconv(.c) void {
    hosted_signal.store(@intCast(sig), .release);
}

/// Apply /etc/zen/manifest.txt (mode, owner) when running as root.
fn applyManifest() void {
    if (std.os.linux.geteuid() != 0) return;
    const text = std.fs.cwd().readFileAlloc(gpa, "/etc/zen/manifest.txt", 256 * 1024) catch return;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const path = it.next() orelse continue;
        const mode = std.fmt.parseInt(u32, it.next() orelse continue, 8) catch continue;
        const uid = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const gid = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const z = gpa.dupeZ(u8, path) catch continue;
        defer gpa.free(z);
        const linux = std.os.linux;
        const fdcwd: usize = @bitCast(@as(isize, linux.AT.FDCWD));
        _ = linux.syscall5(.fchownat, fdcwd, @intFromPtr(z.ptr), uid, gid, linux.AT.SYMLINK_NOFOLLOW);
        _ = linux.syscall4(.fchmodat, fdcwd, @intFromPtr(z.ptr), mode, 0);
    }
}

fn hostedSetup() void {
    const dir = zen.hosted.dir().?;
    std.fs.cwd().makePath(dir) catch {};
    var buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}/init.pid", .{dir})) |p| {
        var pid_buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "";
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = text }) catch {};
    } else |_| {}
    applyManifest();
    const act = posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}

fn stopServices() void {
    for (services.items) |*s| if (s.pid != 0) posix.kill(@intCast(s.pid), posix.SIG.TERM) catch {};
    std.Thread.sleep(700 * std.time.ns_per_ms);
    for (services.items) |*s| if (s.pid != 0) posix.kill(@intCast(s.pid), posix.SIG.KILL) catch {};
    // Reap everything (apps started by launchd are reparented to us).
    while (zen.sys.reap(-1, false) != null) {}
    for (services.items) |*s| s.pid = 0;
}

fn hostedLoop() noreturn {
    while (true) {
        switch (hosted_signal.swap(0, .acq_rel)) {
            0 => {},
            posix.SIG.HUP => {
                log("restarting", .{});
                stopServices();
                for (services.items) |*s| {
                    s.starts = 0;
                    s.restart = true;
                    startService(s);
                }
            },
            else => {
                log("shutting down", .{});
                stopServices();
                std.process.exit(0);
            },
        }
        const r = zen.sys.reap(-1, false) orelse {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        const pid = r.pid;
        for (services.items) |*s| {
            if (s.pid != pid) continue;
            log("{s} (pid {d}) exited with status {d}", .{ s.name, pid, r.status });
            s.pid = 0;
            if (s.restart) startService(s);
        }
    }
}

pub fn main() !void {
    zen.sys.setName("init");
    if (zen.sys.isHosted()) {
        log("Zen OS {s} \"{s}\" starting (hosted)", .{ abi.os_version, abi.os_codename });
        hostedSetup();
        posix.chdir("/") catch {};
        for ([_][]const u8{ "/tmp", "/var/run", "/var/log", "/var/cache/zen" }) |d| std.fs.cwd().makePath(d) catch {};
        try loadServices(true);
        for (services.items) |*s| startService(s);
        hostedLoop();
    }
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

    try loadServices(false);
    for (services.items) |*s| startService(s);

    while (true) {
        const r = zen.sys.reap(-1, true) orelse {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        const pid = r.pid;
        for (services.items) |*s| {
            if (s.pid != pid) continue;
            log("{s} (pid {d}) exited with status {d}", .{ s.name, pid, r.status });
            s.pid = 0;
            if (s.restart) startService(s);
        }
    }
}
