//! Wrappers for Zen-specific system calls.
//!
//! Standard POSIX functionality comes straight from Zig's std (Zen speaks
//! the Linux ABI). On a Linux host these calls fail with ENOSYS, which lets
//! user-space code be unit-tested on a development machine.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const linux = std.os.linux;

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
    const rc = try check(zen(.spawn, @intFromPtr(&args), 0, 0, 0));
    return @intCast(rc);
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
    _ = zen(.set_name, @intFromPtr(name.ptr), name.len, 0, 0);
}

pub fn powerOff() Error!void {
    _ = try check(zen(.power, 0, 0, 0, 0));
}

pub fn reboot() Error!void {
    _ = try check(zen(.power, 1, 0, 0, 0));
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
