//! Thin wrappers over the Linux (riscv64 / x86_64) syscall ABI used by zensh.
//! Every function returns `error.Sys` on failure and records the errno in
//! `last_errno`, so callers can produce shell-style error messages.
const std = @import("std");
const linux = std.os.linux;

pub const E = linux.E;
pub const fd_t = i32;
pub const pid_t = i32;
pub const Stat = linux.Stat;
pub const termios = linux.termios;
pub const O = linux.O;
pub const SIG = linux.SIG;

pub const Error = error{Sys};

pub var last_errno: E = .SUCCESS;

inline fn check(rc: usize) Error!usize {
    const e = E.init(rc);
    if (e != .SUCCESS) {
        last_errno = e;
        return error.Sys;
    }
    return rc;
}

pub const PATH_MAX = 4096;

/// Copy `s` into `buf` with a trailing NUL.
pub fn toZ(buf: *[PATH_MAX]u8, s: []const u8) Error![*:0]const u8 {
    if (s.len >= buf.len) {
        last_errno = .NAMETOOLONG;
        return error.Sys;
    }
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}

pub noinline fn open(path: []const u8, flags: O, mode: u32) Error!fd_t {
    var b: [PATH_MAX]u8 = undefined;
    const p = try toZ(&b, path);
    var f = flags;
    f.CLOEXEC = true;
    while (true) {
        const rc = linux.openat(linux.AT.FDCWD, p, f, mode);
        if (E.init(rc) == .INTR) continue;
        return @intCast(try check(rc));
    }
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// read(2); retries on EINTR unless `intr` is set, in which case EINTR is
/// reported as an error.
pub fn readIntr(fd: fd_t, buf: []u8) Error!usize {
    return check(linux.read(fd, buf.ptr, buf.len));
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (E.init(rc) == .INTR) continue;
        return check(rc);
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (E.init(rc) == .INTR) continue;
        const n = try check(rc);
        if (n == 0) return error.Sys;
        off += n;
    }
}

pub fn lseek(fd: fd_t, off: i64, whence: usize) Error!i64 {
    return @bitCast(try check(linux.lseek(fd, off, whence)));
}

pub fn pipe() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

/// dup2 that also works when old == new (clears CLOEXEC in that case).
pub fn dup2(old: fd_t, new: fd_t) Error!void {
    if (old == new) {
        const fl = try check(linux.fcntl(old, linux.F.GETFD, 0));
        _ = try check(linux.fcntl(old, linux.F.SETFD, fl & ~@as(usize, linux.FD_CLOEXEC)));
        return;
    }
    while (true) {
        const rc = linux.dup3(old, new, 0);
        if (E.init(rc) == .INTR or E.init(rc) == .BUSY) continue;
        _ = try check(rc);
        return;
    }
}

/// Duplicate `fd` to a descriptor >= `min` with close-on-exec set.
pub fn dupHigh(fd: fd_t, min: fd_t) Error!fd_t {
    const F_DUPFD_CLOEXEC = 1030;
    const rc = linux.fcntl(fd, F_DUPFD_CLOEXEC, @intCast(min));
    if (E.init(rc) == .INVAL) {
        const nfd: fd_t = @intCast(try check(linux.fcntl(fd, linux.F.DUPFD, @intCast(min))));
        setCloexec(nfd);
        return nfd;
    }
    return @intCast(try check(rc));
}

pub fn isValidFd(fd: fd_t) bool {
    return E.init(linux.fcntl(fd, linux.F.GETFD, 0)) == .SUCCESS;
}

pub fn setCloexec(fd: fd_t) void {
    _ = linux.fcntl(fd, linux.F.SETFD, linux.FD_CLOEXEC);
}

pub fn fork() Error!pid_t {
    return @intCast(try check(linux.fork()));
}

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) E {
    return E.init(linux.execve(path, argv, envp));
}

pub const WaitResult = struct { pid: pid_t, status: u32 };

pub fn wait4(pid: pid_t, flags: u32) Error!WaitResult {
    var status: u32 = 0;
    const rc = try check(linux.wait4(pid, &status, flags, null));
    return .{ .pid = @intCast(rc), .status = status };
}

pub fn exit(status: u8) noreturn {
    linux.exit_group(status);
}

pub fn getpid() pid_t {
    return linux.getpid();
}
pub fn getppid() pid_t {
    return linux.getppid();
}
pub fn getuid() u32 {
    return linux.getuid();
}
pub fn geteuid() u32 {
    return linux.geteuid();
}
pub fn getgid() u32 {
    return linux.getgid();
}

pub fn setpgid(pid: pid_t, pgid: pid_t) Error!void {
    _ = try check(linux.setpgid(pid, pgid));
}

pub fn getpgrp() pid_t {
    const rc = linux.syscall1(.getpgid, 0);
    if (E.init(rc) != .SUCCESS) return linux.getpid();
    return @intCast(rc);
}

pub fn tcgetpgrp(fd: fd_t) Error!pid_t {
    var p: pid_t = 0;
    _ = try check(linux.ioctl(fd, linux.T.IOCGPGRP, @intFromPtr(&p)));
    return p;
}

pub fn tcsetpgrp(fd: fd_t, pgrp: pid_t) Error!void {
    var p: pid_t = pgrp;
    _ = try check(linux.ioctl(fd, linux.T.IOCSPGRP, @intFromPtr(&p)));
}

pub fn tcgetattr(fd: fd_t) Error!termios {
    var t: termios = undefined;
    _ = try check(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t)));
    return t;
}

pub fn tcsetattr(fd: fd_t, t: *const termios) Error!void {
    while (true) {
        const rc = linux.ioctl(fd, linux.T.CSETS, @intFromPtr(t));
        if (E.init(rc) == .INTR) continue;
        _ = try check(rc);
        return;
    }
}

pub fn isatty(fd: fd_t) bool {
    var t: termios = undefined;
    return E.init(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

pub const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

pub fn winsize(fd: fd_t) ?Winsize {
    var ws: Winsize = undefined;
    if (E.init(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS) return null;
    if (ws.col == 0) return null;
    return ws;
}

pub fn kill(pid: pid_t, sig: u32) Error!void {
    _ = try check(linux.kill(pid, @intCast(sig)));
}

pub const Handler = enum { default, ignore, catch_ };

pub var signal_hook: ?*const fn (i32) callconv(.c) void = null;

/// Install a disposition for `sig`. Returns the previous disposition
/// (default/ignore/catch).
pub fn signal(sig: u8, h: Handler, restart: bool) Handler {
    var act: linux.Sigaction = .{
        .handler = .{ .handler = switch (h) {
            .default => linux.SIG.DFL,
            .ignore => linux.SIG.IGN,
            .catch_ => signal_hook,
        } },
        .mask = linux.sigemptyset(),
        .flags = if (restart) linux.SA.RESTART else 0,
    };
    var old: linux.Sigaction = undefined;
    if (E.init(linux.sigaction(sig, &act, &old)) != .SUCCESS) return .default;
    const oh = old.handler.handler;
    if (oh == linux.SIG.DFL) return .default;
    if (oh == linux.SIG.IGN) return .ignore;
    return .catch_;
}

pub fn getSignal(sig: u8) Handler {
    var old: linux.Sigaction = undefined;
    if (E.init(linux.sigaction(sig, null, &old)) != .SUCCESS) return .default;
    const oh = old.handler.handler;
    if (oh == linux.SIG.DFL) return .default;
    if (oh == linux.SIG.IGN) return .ignore;
    return .catch_;
}

pub fn unblockAllSignals() void {
    const set = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &set, null);
}

pub noinline fn chdir(path: []const u8) Error!void {
    var b: [PATH_MAX]u8 = undefined;
    _ = try check(linux.chdir(try toZ(&b, path)));
}

pub fn getcwd(buf: []u8) Error![]u8 {
    const rc = try check(linux.getcwd(buf.ptr, buf.len));
    _ = rc;
    return std.mem.sliceTo(buf, 0);
}

pub noinline fn stat(path: []const u8) Error!Stat {
    var b: [PATH_MAX]u8 = undefined;
    var st: Stat = undefined;
    _ = try check(linux.fstatat(linux.AT.FDCWD, try toZ(&b, path), &st, 0));
    return st;
}

pub noinline fn lstat(path: []const u8) Error!Stat {
    var b: [PATH_MAX]u8 = undefined;
    var st: Stat = undefined;
    _ = try check(linux.fstatat(linux.AT.FDCWD, try toZ(&b, path), &st, linux.AT.SYMLINK_NOFOLLOW));
    return st;
}

pub fn fstat(fd: fd_t) Error!Stat {
    var st: Stat = undefined;
    _ = try check(linux.fstat(fd, &st));
    return st;
}

pub const R_OK = 4;
pub const W_OK = 2;
pub const X_OK = 1;
pub const F_OK = 0;

pub noinline fn access(path: []const u8, mode: u32) bool {
    var b: [PATH_MAX]u8 = undefined;
    const p = toZ(&b, path) catch return false;
    return E.init(linux.faccessat(linux.AT.FDCWD, p, mode, 0)) == .SUCCESS;
}

pub fn umask(mask: u32) u32 {
    return @intCast(linux.syscall1(.umask, mask));
}

pub noinline fn isDir(path: []const u8) bool {
    const st = stat(path) catch return false;
    return (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}

pub fn isReg(st: Stat) bool {
    return (st.mode & linux.S.IFMT) == linux.S.IFREG;
}

pub fn modeType(st: Stat) u32 {
    return st.mode & linux.S.IFMT;
}

pub const S = linux.S;

pub noinline fn exists(path: []const u8) bool {
    _ = lstat(path) catch return false;
    return true;
}

pub noinline fn isExecutableFile(path: []const u8) bool {
    const st = stat(path) catch return false;
    if (!isReg(st)) return false;
    return access(path, X_OK);
}

/// Host name from uname(2), falling back to /etc/hostname and "zen-os".
pub fn hostname(buf: []u8) []const u8 {
    var uts: linux.utsname = undefined;
    if (E.init(linux.uname(&uts)) == .SUCCESS) {
        const n = std.mem.sliceTo(&uts.nodename, 0);
        if (n.len > 0 and n.len <= buf.len and !std.mem.eql(u8, n, "(none)") and !std.mem.eql(u8, n, "localhost")) {
            @memcpy(buf[0..n.len], n);
            return buf[0..n.len];
        }
    }
    // Zen serves the host name as sys:hostname; /etc/hostname elsewhere
    for ([_][]const u8{ "sys:hostname", "/etc/hostname" }) |p| {
        const fd = open(p, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        defer close(fd);
        const n = read(fd, buf) catch 0;
        const t = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (t.len > 0) {
            std.mem.copyForwards(u8, buf, t);
            return buf[0..t.len];
        }
    }
    return "zen-os";
}

pub fn now() linux.timespec {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts;
}

pub fn monotonic() linux.timespec {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

/// Wait until `fd` is readable or `timeout_ms` elapses. Returns true if
/// readable. On failure (e.g. unimplemented) returns true so callers block.
pub fn pollIn(fd: fd_t, timeout_ms: i32) bool {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&fds, 1, timeout_ms);
    if (E.init(rc) != .SUCCESS) return true;
    return rc > 0;
}

pub fn strerror(e: E) []const u8 {
    return switch (e) {
        .PERM => "Operation not permitted",
        .NOENT => "No such file or directory",
        .SRCH => "No such process",
        .INTR => "Interrupted system call",
        .IO => "Input/output error",
        .NXIO => "No such device or address",
        .@"2BIG" => "Argument list too long",
        .NOEXEC => "Exec format error",
        .BADF => "Bad file descriptor",
        .CHILD => "No child processes",
        .AGAIN => "Resource temporarily unavailable",
        .NOMEM => "Cannot allocate memory",
        .ACCES => "Permission denied",
        .FAULT => "Bad address",
        .BUSY => "Device or resource busy",
        .EXIST => "File exists",
        .XDEV => "Invalid cross-device link",
        .NODEV => "No such device",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .INVAL => "Invalid argument",
        .NFILE => "Too many open files in system",
        .MFILE => "Too many open files",
        .NOTTY => "Inappropriate ioctl for device",
        .TXTBSY => "Text file busy",
        .FBIG => "File too large",
        .NOSPC => "No space left on device",
        .SPIPE => "Illegal seek",
        .ROFS => "Read-only file system",
        .MLINK => "Too many links",
        .PIPE => "Broken pipe",
        .NAMETOOLONG => "File name too long",
        .NOSYS => "Function not implemented",
        .NOTEMPTY => "Directory not empty",
        .LOOP => "Too many levels of symbolic links",
        else => "Unknown error",
    };
}

pub fn lastError() []const u8 {
    return strerror(last_errno);
}

// ---------------------------------------------------------------------------
// directory iteration (getdents64 directly; no lseek, which a minimal
// kernel may not support on directories)
// ---------------------------------------------------------------------------

pub const EntryKind = enum { dir, file, link, unknown, other };

pub const DirEntry = struct { name: []const u8, kind: EntryKind };

pub const DirIter = struct {
    fd: fd_t,
    buf: [2048]u8 align(8) = undefined,
    pos: usize = 0,
    end: usize = 0,

    pub fn open(path: []const u8) Error!DirIter {
        const p = if (path.len == 0) "." else path;
        const fd = try open_dir(p);
        return .{ .fd = fd };
    }

    fn open_dir(path: []const u8) Error!fd_t {
        return openFile(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    }

    pub fn close(self: *DirIter) void {
        close_fd(self.fd);
    }

    pub fn next(self: *DirIter) ?DirEntry {
        while (true) {
            if (self.pos >= self.end) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                if (E.init(rc) != .SUCCESS or rc == 0) return null;
                self.pos = 0;
                self.end = rc;
            }
            const base = self.pos;
            const reclen = std.mem.readInt(u16, self.buf[base + 16 ..][0..2], @import("builtin").cpu.arch.endian());
            const dtype = self.buf[base + 18];
            const name_z: [*:0]const u8 = @ptrCast(&self.buf[base + 19]);
            self.pos += reclen;
            if (reclen == 0) {
                self.end = 0;
                return null;
            }
            const name = std.mem.span(name_z);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const kind: EntryKind = switch (dtype) {
                4 => .dir,
                8 => .file,
                10 => .link,
                0 => .unknown,
                else => .other,
            };
            return .{ .name = name, .kind = kind };
        }
    }
};

const openFile = open;

fn close_fd(fd: fd_t) void {
    _ = linux.close(fd);
}
