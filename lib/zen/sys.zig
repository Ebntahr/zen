//! Wrappers for Zen-specific system calls.
//!
//! Standard POSIX functionality comes straight from Zig's std (Zen speaks
//! the Linux ABI). On a Linux host these calls fail with ENOSYS, which lets
//! user-space code be unit-tested on a development machine.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const hosted = @import("hosted.zig");
const linux = std.os.linux;
const posix = std.posix;

pub const Error = error{
    PermissionDenied,
    NotFound,
    AlreadyExists,
    InvalidArgument,
    OutOfMemory,
    NotSupported,
    Busy,
    Interrupted,
    WouldBlock,
    BadFd,
    Unexpected,
};

pub fn errnoToError(e: linux.E) Error {
    return switch (e) {
        .PERM, .ACCES => error.PermissionDenied,
        .NOENT, .SRCH, .NODEV, .NXIO => error.NotFound,
        .EXIST => error.AlreadyExists,
        .INVAL, .FAULT, .NAMETOOLONG => error.InvalidArgument,
        .NOMEM, .NOSPC => error.OutOfMemory,
        .NOSYS, .OPNOTSUPP => error.NotSupported,
        .BUSY => error.Busy,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFd,
        else => error.Unexpected,
    };
}

/// Raw system call with up to six arguments (RISC-V: a7 = number).
pub fn syscall6(nr: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    return switch (builtin.cpu.arch) {
        .riscv64 => asm volatile ("ecall"
            : [ret] "={x10}" (-> usize),
            : [nr] "{x17}" (nr),
              [a0] "{x10}" (a0),
              [a1] "{x11}" (a1),
              [a2] "{x12}" (a2),
              [a3] "{x13}" (a3),
              [a4] "{x14}" (a4),
              [a5] "{x15}" (a5),
            : .{ .memory = true }),
        // Zen syscalls do not exist on other hosts.
        else => @bitCast(-@as(isize, @intFromEnum(linux.E.NOSYS))),
    };
}

fn zen(nr: abi.syscall.Zen, a0: usize, a1: usize, a2: usize, a3: usize) usize {
    return syscall6(@intFromEnum(nr), a0, a1, a2, a3, 0, 0);
}

pub fn check(rc: usize) Error!usize {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) {
        return errnoToError(@enumFromInt(@as(u16, @intCast(-signed))));
    }
    return rc;
}

/// True when running on the Zen kernel (uname sysname == "Zen").
pub fn isZen() bool {
    var uts: linux.utsname = undefined;
    if (linux.uname(&uts) != 0) return false;
    return std.mem.eql(u8, std.mem.sliceTo(&uts.sysname, 0), abi.sysname);
}

/// Register a URL scheme; returns the server endpoint fd.
pub fn schemeRegister(name: []const u8) Error!std.posix.fd_t {
    const rc = try check(zen(.scheme_register, @intFromPtr(name.ptr), name.len, 0, 0));
    return @intCast(rc);
}

/// Map device memory into the caller. Requires the hardware privilege.
pub fn physmap(phys: u64, len: usize) Error![*]volatile u8 {
    const rc = try check(zen(.physmap, phys, len, 0, 0));
    return @ptrFromInt(rc);
}

pub const DmaBuffer = struct {
    virt: [*]u8,
    phys: u64,
    len: usize,
};

/// Allocate zeroed, physically contiguous memory for DMA.
pub fn physalloc(len: usize) Error!DmaBuffer {
    var phys: u64 = 0;
    const rc = try check(zen(.physalloc, len, @intFromPtr(&phys), 0, 0));
    return .{ .virt = @ptrFromInt(rc), .phys = phys, .len = len };
}

pub fn virt2phys(addr: usize) Error!u64 {
    return try check(zen(.virt2phys, addr, 0, 0, 0));
}

pub const SpawnOptions = struct {
    argv: []const []const u8,
    env: ?[]const []const u8 = null,
    /// Child fd i = parent fd fds[i] (-1 closes it). Default: 0, 1, 2.
    fds: []const i32 = &.{ 0, 1, 2 },
    cwd: ?[]const u8 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    groups: ?[]const u32 = null,
    sandbox: ?[]const u8 = null,
    new_session: bool = false,
    pgid: ?u32 = null,
    daemon: bool = false,
};

/// Spawn a new process from `path` (a path or URL). Returns its pid.
pub fn spawn(allocator: std.mem.Allocator, path: []const u8, opts: SpawnOptions) (Error || std.mem.Allocator.Error)!u32 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try arena.alloc(?[*:0]const u8, opts.argv.len + 1);
    for (opts.argv, 0..) |a, i| argv[i] = try arena.dupeZ(u8, a);
    argv[opts.argv.len] = null;

    const env_src: []const []const u8 = opts.env orelse &.{};
    const envp = try arena.alloc(?[*:0]const u8, env_src.len + 1);
    for (env_src, 0..) |e, i| envp[i] = try arena.dupeZ(u8, e);
    envp[env_src.len] = null;

    var flags: u64 = 0;
    if (opts.new_session) flags |= abi.syscall.SPAWN_SETSID;
    if (opts.pgid != null) flags |= abi.syscall.SPAWN_SETPGID;
    if (opts.groups != null) flags |= abi.syscall.SPAWN_SETGROUPS;
    if (opts.daemon) flags |= abi.syscall.SPAWN_DAEMON;

    const args = abi.syscall.SpawnArgs{
        .path = @intFromPtr(path.ptr),
        .path_len = path.len,
        .argv = @intFromPtr(argv.ptr),
        .envp = @intFromPtr(envp.ptr),
        .fds = @intFromPtr(opts.fds.ptr),
        .nfds = opts.fds.len,
        .cwd = if (opts.cwd) |c| @intFromPtr(c.ptr) else 0,
        .cwd_len = if (opts.cwd) |c| c.len else 0,
        .uid = if (opts.uid) |u| u else -1,
        .gid = if (opts.gid) |g| g else -1,
        .sandbox = if (opts.sandbox) |s| @intFromPtr(s.ptr) else 0,
        .sandbox_len = if (opts.sandbox) |s| s.len else 0,
        .flags = flags,
        .pgid = if (opts.pgid) |p| p else 0,
        .groups = if (opts.groups) |g| @intFromPtr(g.ptr) else 0,
        .ngroups = if (opts.groups) |g| g.len else 0,
    };
    if (!isZen() and hosted.enabled()) return hostedSpawn(arena, path, opts, argv, envp);
    const rc = try check(zen(.spawn, @intFromPtr(&args), 0, 0, 0));
    return @intCast(rc);
}

/// Hosted spawn: fork + execve. Sandboxing is not available on the host;
/// uid/gid changes are applied when the host allows them.
fn hostedSpawn(arena: std.mem.Allocator, path: []const u8, opts: SpawnOptions, argv: []?[*:0]const u8, envp_in: []?[*:0]const u8) (Error || std.mem.Allocator.Error)!u32 {
    const exe_path = if (std.mem.startsWith(u8, path, "file:")) path[5..] else path;
    const exe = try arena.dupeZ(u8, exe_path);
    const cwd = if (opts.cwd) |c| try arena.dupeZ(u8, c) else null;
    // Children must find the hosted sockets: pass on ZEN_HOSTED and the
    // other ZEN_HOSTED_* settings unless the caller set them.
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (envp_in) |e| if (e) |v| try list.append(arena, v);
    for (std.os.environ) |own| {
        const kv = std.mem.span(own);
        if (!std.mem.startsWith(u8, kv, hosted.env_var)) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        var present = false;
        for (list.items) |e| {
            const ev = std.mem.span(e.?);
            if (ev.len > eq and std.mem.eql(u8, ev[0 .. eq + 1], kv[0 .. eq + 1])) present = true;
        }
        if (!present) try list.append(arena, own);
    }
    var has_dir = false;
    for (list.items) |e| {
        if (std.mem.startsWith(u8, std.mem.span(e.?), hosted.env_var ++ "=")) has_dir = true;
    }
    if (!has_dir) try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ hosted.env_var, hosted.dir().? }, 0)).ptr);
    try list.append(arena, null);
    const envp = list.items;
    // Source fds are moved above the target range first so dup2 cannot
    // clobber one that is still needed.
    var fd_map: [16]i32 = undefined;
    const nfds = @min(opts.fds.len, fd_map.len);
    for (opts.fds[0..nfds], 0..) |f, i| fd_map[i] = f;

    const pid = linux.fork();
    switch (linux.E.init(pid)) {
        .SUCCESS => {},
        else => |e| return errnoToError(e),
    }
    if (pid != 0) return @intCast(pid);

    // Child: only raw system calls from here on.
    const high: i32 = 200;
    const F_DUPFD_CLOEXEC = 1030;
    for (fd_map[0..nfds], 0..) |f, i| {
        if (f >= 0) _ = linux.fcntl(f, F_DUPFD_CLOEXEC, @intCast(high + @as(i32, @intCast(i))));
    }
    for (fd_map[0..nfds], 0..) |f, i| {
        const target: i32 = @intCast(i);
        if (f >= 0) {
            _ = linux.dup3(high + target, target, 0);
        } else {
            _ = linux.close(target);
        }
    }
    _ = linux.syscall3(.close_range, @intCast(nfds), std.math.maxInt(u32), 0);
    if (opts.new_session or opts.daemon) _ = linux.setsid();
    if (opts.pgid) |pg| _ = linux.setpgid(0, @intCast(pg));
    if (cwd) |c| _ = linux.chdir(c);
    if (opts.groups) |g| _ = linux.setgroups(g.len, g.ptr);
    if (opts.gid) |g| _ = linux.setgid(g);
    if (opts.uid) |u| _ = linux.setuid(u);
    _ = linux.execve(exe, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
    linux.exit(127);
}

/// Irreversibly apply a sandbox profile to the calling process.
pub fn sandboxApply(profile: []const u8) Error!void {
    _ = try check(zen(.sandbox_apply, @intFromPtr(profile.ptr), profile.len, 0, 0));
}

/// Grant a sandboxed process access to a path (powerbox).
pub fn sandboxGrant(pid: u32, path: []const u8, access: u8) Error!void {
    _ = try check(zen(.sandbox_grant, pid, @intFromPtr(path.ptr), path.len, access));
}

pub fn klog(msg: []const u8) void {
    if (!isZen() and hosted.enabled()) {
        // Hosted: the "kernel log" is the launcher's terminal.
        var iov = [_]posix.iovec_const{ .{ .base = msg.ptr, .len = msg.len }, .{ .base = "\n", .len = 1 } };
        _ = linux.writev(2, &iov, 2);
        return;
    }
    _ = zen(.klog, @intFromPtr(msg.ptr), msg.len, 0, 0);
}

pub fn procInfo(pid: u32) Error!abi.syscall.ProcInfo {
    var info: abi.syscall.ProcInfo = undefined;
    _ = try check(zen(.proc_info, pid, @intFromPtr(&info), 0, 0));
    return info;
}

pub fn procList(out: []u32) Error![]u32 {
    const n = try check(zen(.proc_list, @intFromPtr(out.ptr), out.len, 0, 0));
    return out[0..@min(n, out.len)];
}

pub fn setName(name: []const u8) void {
    if (!isZen()) {
        var buf: [16]u8 = [_]u8{0} ** 16;
        const n = @min(name.len, 15);
        @memcpy(buf[0..n], name[0..n]);
        _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(&buf), 0, 0, 0);
        return;
    }
    _ = zen(.set_name, @intFromPtr(name.ptr), name.len, 0, 0);
}

/// Hosted: signal the hosted init (pid in $ZEN_HOSTED/init.pid).
fn signalHostedInit(sig: u8) Error!void {
    const d = hosted.dir() orelse return error.NotSupported;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/init.pid", .{d}) catch return error.InvalidArgument;
    var buf: [32]u8 = undefined;
    const text = std.fs.cwd().readFile(path, &buf) catch return error.NotFound;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch return error.NotFound;
    posix.kill(pid, sig) catch return error.PermissionDenied;
}

pub fn powerOff() Error!void {
    if (!isZen() and hosted.enabled()) return signalHostedInit(posix.SIG.TERM);
    _ = try check(zen(.power, 0, 0, 0, 0));
}

pub fn reboot() Error!void {
    if (!isZen() and hosted.enabled()) return signalHostedInit(posix.SIG.HUP);
    _ = try check(zen(.power, 1, 0, 0, 0));
}

pub const Reaped = struct { pid: u32, status: u32 };

/// Collect an exited child (`pid` -1 = any). Unlike std.posix.waitpid this
/// treats "no children" (ECHILD) as an ordinary answer: null.
pub fn reap(pid: i32, block: bool) ?Reaped {
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &status, if (block) 0 else linux.W.NOHANG, null);
        switch (linux.E.init(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                return .{ .pid = @intCast(rc), .status = status };
            },
            .INTR => if (!block) return null,
            else => return null,
        }
    }
}

/// True when running hosted on Linux (see hosted.zig).
pub fn isHosted() bool {
    return !isZen() and hosted.enabled();
}

/// Print a formatted line to the kernel log (and serial console).
pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    klog(s);
}

test "zen syscalls fail cleanly on non-Zen hosts" {
    if (builtin.cpu.arch == .riscv64) return error.SkipZigTest;
    try std.testing.expectError(error.NotSupported, schemeRegister("x"));
}

test "hosted spawn runs a host program" {
    if (builtin.os.tag != .linux or isZen()) return error.SkipZigTest;
    std.fs.cwd().access("/bin/sh", .{}) catch return error.SkipZigTest;
    hosted.setDir("/tmp");
    defer hosted.setDir(null);
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    const pid = try spawn(std.testing.allocator, "/bin/sh", .{
        .argv = &.{ "sh", "-c", "echo \"$ZEN_HOSTED:$0\" >&1; exit 3" },
        .fds = &.{ -1, fds[1], 2 },
        .new_session = true,
    });
    posix.close(fds[1]);
    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("/tmp:sh\n", buf[0..n]);
    const r = posix.waitpid(@intCast(pid), 0);
    try std.testing.expectEqual(@as(u32, 3), posix.W.EXITSTATUS(r.status));
}
