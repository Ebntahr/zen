//! Shared helpers for zbox commands: argument parsing (GNU style), buffered
//! output, GNU-style diagnostics, thin Linux syscall wrappers with precise
//! errno reporting, human readable sizes, mode strings, user/group lookup,
//! time zone handling and strftime, line reading, fnmatch and process helpers.
const std = @import("std");
const builtin = @import("builtin");
pub const linux = std.os.linux;
pub const posix = std.posix;
pub const mem = std.mem;

pub const Args = []const [:0]const u8;

pub const gpa: mem.Allocator = std.heap.smp_allocator;

/// Name of the running applet (used as message prefix).
pub var prog: []const u8 = "zbox";
/// Help text of the running applet (printed on --help).
pub var help_text: []const u8 = "";
/// Exit status used for usage errors (GNU: 1 for most tools, 2 for ls/grep/...).
pub var usage_status: u8 = 1;

pub const version = "0.1.0";

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

var out_buf: [16384]u8 = undefined;
var out_fw: std.fs.File.Writer = undefined;
pub var out: *std.Io.Writer = undefined;
var io_ready = false;

pub fn initIo() void {
    out_fw = std.fs.File.stdout().writerStreaming(&out_buf);
    out = &out_fw.interface;
    io_ready = true;
}

/// Flush stdout; on failure report a GNU style write error and exit(1).
pub fn flush() void {
    if (!io_ready) return;
    out.flush() catch {
        const e: anyerror = if (out_fw.err) |x| x else error.WriteFailed;
        out.end = 0;
        if (e == error.BrokenPipe) std.process.exit(1);
        writeErrRaw("write error: ");
        writeErrRaw(strerror(e));
        writeErrRaw("\n");
        std.process.exit(1);
    };
}

pub fn exit(code: u8) noreturn {
    flush();
    std.process.exit(code);
}

/// Handle an error returned from `out` writes (error.WriteFailed).
pub fn writeFailed() noreturn {
    flush();
    std.process.exit(1);
}

fn writeErrRaw(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(2, s[off..].ptr, s.len - off);
        if (posix.errno(rc) != .SUCCESS) {
            if (posix.errno(rc) == .INTR) continue;
            return;
        }
        off += rc;
    }
    _ = &off;
}

fn writeErrWithProg(s: []const u8) void {
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ prog, ": ", s }) |part| {
        const k = @min(part.len, buf.len - n);
        @memcpy(buf[n..][0..k], part[0..k]);
        n += k;
    }
    writeErrRaw(buf[0..n]);
}

/// Print "prog: <msg>\n" to stderr.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    flush();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(prog) catch {};
    w.writeAll(": ") catch {};
    w.print(fmt, args) catch {};
    if (w.end >= buf.len) w.end = buf.len - 1;
    w.writeByte('\n') catch {};
    writeErrRaw(w.buffered());
}

/// Print raw text to stderr (no prefix).
pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    flush();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    writeErrRaw(w.buffered());
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    exit(1);
}

pub fn fatalCode(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    exit(code);
}

/// diffutils style: prefix the "Try ..." line with the program name.
pub var try_with_prog = false;

pub fn tryHelp() void {
    if (try_with_prog) {
        eprint("{s}: Try '{s} --help' for more information.\n", .{ prog, prog });
    } else eprint("Try '{s} --help' for more information.\n", .{prog});
}

pub fn usageErr(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    tryHelp();
    exit(usage_status);
}

pub fn missingOperand() noreturn {
    usageErr("missing operand", .{});
}

pub fn printHelp() noreturn {
    out.writeAll(help_text) catch {};
    exit(0);
}

pub fn printVersion() noreturn {
    out.print("{s} (zbox) {s}\n", .{ prog, version }) catch {};
    exit(0);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const SysError = error{
    NOENT, ACCES,    PERM,  EXIST, NOTDIR, ISDIR, NOTEMPTY, INVAL,  NOSPC,  ROFS,
    LOOP,  NAMETOOLONG, XDEV, BUSY, NOMEM, BADF, IO,       NOSYS,  NXIO,   NODEV,
    SRCH,  CHILD,    AGAIN, INTR,  PIPE,  MFILE, NFILE,    FBIG,   TXTBSY, OPNOTSUPP,
    NOTTY, SPIPE,    RANGE, NOEXEC, TOOBIG, FAULT, DQUOT,  MLINK,  NOTSUP_OTHER,
};

pub fn mapErrno(e: linux.E) SysError {
    return switch (e) {
        .NOENT => error.NOENT,
        .ACCES => error.ACCES,
        .PERM => error.PERM,
        .EXIST => error.EXIST,
        .NOTDIR => error.NOTDIR,
        .ISDIR => error.ISDIR,
        .NOTEMPTY => error.NOTEMPTY,
        .INVAL => error.INVAL,
        .NOSPC => error.NOSPC,
        .ROFS => error.ROFS,
        .LOOP => error.LOOP,
        .NAMETOOLONG => error.NAMETOOLONG,
        .XDEV => error.XDEV,
        .BUSY => error.BUSY,
        .NOMEM => error.NOMEM,
        .BADF => error.BADF,
        .IO => error.IO,
        .NOSYS => error.NOSYS,
        .NXIO => error.NXIO,
        .NODEV => error.NODEV,
        .SRCH => error.SRCH,
        .CHILD => error.CHILD,
        .AGAIN => error.AGAIN,
        .INTR => error.INTR,
        .PIPE => error.PIPE,
        .MFILE => error.MFILE,
        .NFILE => error.NFILE,
        .FBIG => error.FBIG,
        .TXTBSY => error.TXTBSY,
        .OPNOTSUPP => error.OPNOTSUPP,
        .NOTTY => error.NOTTY,
        .SPIPE => error.SPIPE,
        .RANGE => error.RANGE,
        .NOEXEC => error.NOEXEC,
        .@"2BIG" => error.TOOBIG,
        .FAULT => error.FAULT,
        .DQUOT => error.DQUOT,
        .MLINK => error.MLINK,
        else => error.NOTSUP_OTHER,
    };
}

/// GNU strerror() texts for our error names (and some std errors).
pub fn strerror(e: anyerror) []const u8 {
    return switch (e) {
        error.NOENT, error.FileNotFound => "No such file or directory",
        error.ACCES, error.AccessDenied => "Permission denied",
        error.PERM, error.PermissionDenied => "Operation not permitted",
        error.EXIST, error.PathAlreadyExists => "File exists",
        error.NOTDIR, error.NotDir => "Not a directory",
        error.ISDIR, error.IsDir => "Is a directory",
        error.NOTEMPTY, error.DirNotEmpty => "Directory not empty",
        error.INVAL => "Invalid argument",
        error.NOSPC, error.NoSpaceLeft => "No space left on device",
        error.ROFS, error.ReadOnlyFileSystem => "Read-only file system",
        error.LOOP, error.SymLinkLoop => "Too many levels of symbolic links",
        error.NAMETOOLONG, error.NameTooLong => "File name too long",
        error.XDEV => "Invalid cross-device link",
        error.BUSY => "Device or resource busy",
        error.NOMEM, error.OutOfMemory => "Cannot allocate memory",
        error.BADF => "Bad file descriptor",
        error.IO, error.InputOutput => "Input/output error",
        error.NOSYS => "Function not implemented",
        error.NXIO => "No such device or address",
        error.NODEV => "No such device",
        error.SRCH => "No such process",
        error.CHILD => "No child processes",
        error.AGAIN => "Resource temporarily unavailable",
        error.INTR => "Interrupted system call",
        error.PIPE, error.BrokenPipe => "Broken pipe",
        error.MFILE => "Too many open files",
        error.NFILE => "Too many open files in system",
        error.FBIG, error.FileTooBig => "File too large",
        error.TXTBSY => "Text file busy",
        error.OPNOTSUPP => "Operation not supported",
        error.NOTTY => "Inappropriate ioctl for device",
        error.SPIPE => "Illegal seek",
        error.RANGE => "Numerical result out of range",
        error.NOEXEC => "Exec format error",
        error.TOOBIG => "Argument list too long",
        error.FAULT => "Bad address",
        error.DQUOT => "Disk quota exceeded",
        error.MLINK => "Too many links",
        else => @errorName(e),
    };
}

fn check(rc: usize) SysError!usize {
    const e = posix.errno(rc);
    if (e == .SUCCESS) return rc;
    return mapErrno(e);
}

// ---------------------------------------------------------------------------
// Syscall wrappers
// ---------------------------------------------------------------------------

pub const AT_FDCWD: i32 = linux.AT.FDCWD;
pub const PATH_MAX = 4096;

pub fn toZ(buf: []u8, s: []const u8) SysError![*:0]const u8 {
    if (s.len >= buf.len) return error.NAMETOOLONG;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

pub const O = linux.O;
pub const O_RDONLY: O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
pub const O_WRONLY: O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
pub const O_RDWR: O = .{ .ACCMODE = .RDWR, .CLOEXEC = true };

pub const sys = struct {
    pub fn openat(dirfd: i32, path: []const u8, flags: O, mode: u32) SysError!i32 {
        var b: [PATH_MAX]u8 = undefined;
        const p = try toZ(&b, path);
        while (true) {
            const rc = linux.openat(dirfd, p, flags, mode);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return mapErrno(e);
            return @intCast(rc);
        }
    }
    pub fn open(path: []const u8, flags: O, mode: u32) SysError!i32 {
        return openat(AT_FDCWD, path, flags, mode);
    }
    pub fn close(fd: i32) void {
        _ = linux.close(fd);
    }
    pub fn read(fd: i32, buf: []u8) SysError!usize {
        while (true) {
            const rc = linux.read(fd, buf.ptr, buf.len);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return mapErrno(e);
            return rc;
        }
    }
    /// Read until buf is full or EOF.
    pub fn readFull(fd: i32, buf: []u8) SysError!usize {
        var n: usize = 0;
        while (n < buf.len) {
            const k = try read(fd, buf[n..]);
            if (k == 0) break;
            n += k;
        }
        return n;
    }
    pub fn pread(fd: i32, buf: []u8, off: u64) SysError!usize {
        while (true) {
            const rc = linux.pread(fd, buf.ptr, buf.len, @bitCast(off));
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return mapErrno(e);
            return rc;
        }
    }
    pub fn write(fd: i32, buf: []const u8) SysError!usize {
        while (true) {
            const rc = linux.write(fd, buf.ptr, buf.len);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return mapErrno(e);
            return rc;
        }
    }
    pub fn writeAll(fd: i32, buf: []const u8) SysError!void {
        var off: usize = 0;
        while (off < buf.len) off += try write(fd, buf[off..]);
    }
    pub fn lseek(fd: i32, off: i64, whence: u32) SysError!u64 {
        const rc = linux.lseek(fd, off, whence);
        _ = try check(rc);
        return rc;
    }
    pub fn fstatat(dirfd: i32, path: []const u8, nofollow: bool) SysError!Stat {
        var b: [PATH_MAX]u8 = undefined;
        const p = try toZ(&b, path);
        return fstatatZ(dirfd, p, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0);
    }
    pub fn fstatatZ(dirfd: i32, p: [*:0]const u8, flags: u32) SysError!Stat {
        var st: linux.Stat = mem.zeroes(linux.Stat);
        const rc = linux.fstatat(dirfd, p, &st, flags);
        const e = posix.errno(rc);
        if (e == .SUCCESS) return Stat.fromLinux(st);
        if (e != .NOSYS) return mapErrno(e);
        // Fallback: statx
        var sx: linux.Statx = mem.zeroes(linux.Statx);
        _ = try check(linux.statx(dirfd, p, flags, linux.STATX_BASIC_STATS, &sx));
        return Stat.fromStatx(sx);
    }
    pub fn stat(path: []const u8) SysError!Stat {
        return fstatat(AT_FDCWD, path, false);
    }
    pub fn lstat(path: []const u8) SysError!Stat {
        return fstatat(AT_FDCWD, path, true);
    }
    pub fn fstat(fd: i32) SysError!Stat {
        return fstatatZ(fd, "", linux.AT.EMPTY_PATH);
    }
    pub fn mkdir(path: []const u8, mode: u32) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.mkdirat(AT_FDCWD, try toZ(&b, path), mode));
    }
    pub fn rmdir(path: []const u8) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.unlinkat(AT_FDCWD, try toZ(&b, path), linux.AT.REMOVEDIR));
    }
    pub fn unlink(path: []const u8) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.unlinkat(AT_FDCWD, try toZ(&b, path), 0));
    }
    pub fn rename(old: []const u8, new: []const u8) SysError!void {
        var b1: [PATH_MAX]u8 = undefined;
        var b2: [PATH_MAX]u8 = undefined;
        _ = try check(linux.renameat(AT_FDCWD, try toZ(&b1, old), AT_FDCWD, try toZ(&b2, new)));
    }
    pub fn symlink(target: []const u8, path: []const u8) SysError!void {
        var b1: [PATH_MAX]u8 = undefined;
        var b2: [PATH_MAX]u8 = undefined;
        _ = try check(linux.symlinkat(try toZ(&b1, target), AT_FDCWD, try toZ(&b2, path)));
    }
    pub fn link(old: []const u8, new: []const u8) SysError!void {
        var b1: [PATH_MAX]u8 = undefined;
        var b2: [PATH_MAX]u8 = undefined;
        _ = try check(linux.linkat(AT_FDCWD, try toZ(&b1, old), AT_FDCWD, try toZ(&b2, new), 0));
    }
    pub fn readlink(path: []const u8, buf: []u8) SysError![]u8 {
        var b: [PATH_MAX]u8 = undefined;
        const n = try check(linux.readlinkat(AT_FDCWD, try toZ(&b, path), buf.ptr, buf.len));
        return buf[0..n];
    }
    pub fn chmod(path: []const u8, mode: u32) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.fchmodat(AT_FDCWD, try toZ(&b, path), mode, 0));
    }
    pub fn fchmod(fd: i32, mode: u32) SysError!void {
        _ = try check(linux.fchmod(fd, mode));
    }
    pub fn chown(path: []const u8, uid: ?u32, gid: ?u32, nofollow: bool) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        const u: u32 = uid orelse std.math.maxInt(u32);
        const g: u32 = gid orelse std.math.maxInt(u32);
        _ = try check(linux.syscall5(.fchownat, @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(try toZ(&b, path)), u, g, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0));
    }
    pub fn fchown(fd: i32, uid: u32, gid: u32) SysError!void {
        _ = try check(linux.fchown(fd, uid, gid));
    }
    /// times: null = now. Use UTIME_OMIT / UTIME_NOW in nsec as needed.
    pub fn utimens(path: []const u8, times: ?*const [2]linux.timespec, nofollow: bool) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.utimensat(AT_FDCWD, try toZ(&b, path), times, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0));
    }
    pub fn futimens(fd: i32, times: ?*const [2]linux.timespec) SysError!void {
        _ = try check(linux.utimensat(fd, null, times, 0));
    }
    pub fn ftruncate(fd: i32, len: u64) SysError!void {
        _ = try check(linux.ftruncate(fd, @bitCast(len)));
    }
    pub fn access(path: []const u8, mode: u32) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.faccessat(AT_FDCWD, try toZ(&b, path), mode, 0));
    }
    pub fn getcwd(buf: []u8) SysError![]u8 {
        const rc = try check(linux.getcwd(buf.ptr, buf.len));
        _ = rc;
        return mem.sliceTo(buf, 0);
    }
    pub fn chdir(path: []const u8) SysError!void {
        var b: [PATH_MAX]u8 = undefined;
        _ = try check(linux.chdir(try toZ(&b, path)));
    }
    pub fn ioctl(fd: i32, req: u32, arg: usize) SysError!usize {
        return check(linux.ioctl(fd, req, arg));
    }
    pub fn dup2(old: i32, new: i32) SysError!void {
        _ = try check(linux.dup3(old, new, 0));
    }
    pub fn pipe() SysError![2]i32 {
        var fds: [2]i32 = undefined;
        _ = try check(linux.pipe2(&fds, .{}));
        return fds;
    }
    pub fn kill(pid: i32, sig: u32) SysError!void {
        _ = try check(linux.kill(pid, @intCast(sig)));
    }
    pub fn fork() SysError!i32 {
        const rc = try check(linux.fork());
        return @intCast(@as(isize, @bitCast(rc)));
    }
    pub fn wait(pid: i32, flags: u32) SysError!struct { pid: i32, status: u32 } {
        var status: u32 = 0;
        while (true) {
            const rc = linux.wait4(pid, &status, flags, null);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return mapErrno(e);
            return .{ .pid = @intCast(@as(isize, @bitCast(rc))), .status = status };
        }
    }
    pub fn nanosleep(ns: u64) void {
        var req: linux.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
        var rem: linux.timespec = undefined;
        while (true) {
            const rc = linux.nanosleep(&req, &rem);
            if (posix.errno(rc) == .INTR) {
                req = rem;
                continue;
            }
            break;
        }
    }
    pub fn umask(mask: u32) u32 {
        return @truncate(linux.syscall1(.umask, mask));
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
    pub fn getegid() u32 {
        return linux.getegid();
    }
    pub fn getgroups(buf: []u32) SysError![]u32 {
        const n = try check(linux.getgroups(buf.len, if (buf.len > 0) &buf[0] else null));
        return buf[0..n];
    }
    pub fn getpid() i32 {
        return linux.getpid();
    }
    pub fn fsync(fd: i32) SysError!void {
        _ = try check(linux.fsync(fd));
    }
};

pub const Ts = struct {
    sec: i64 = 0,
    nsec: i64 = 0,
    pub fn cmp(a: Ts, b: Ts) std.math.Order {
        if (a.sec != b.sec) return std.math.order(a.sec, b.sec);
        return std.math.order(a.nsec, b.nsec);
    }
};

pub fn now() Ts {
    var tp: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &tp);
    return .{ .sec = tp.sec, .nsec = tp.nsec };
}

pub fn monoNs() u64 {
    var tp: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &tp);
    return @as(u64, @intCast(tp.sec)) * 1_000_000_000 + @as(u64, @intCast(tp.nsec));
}

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFBLK: u32 = 0o060000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFIFO: u32 = 0o010000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFSOCK: u32 = 0o140000;

pub const Stat = struct {
    dev: u64 = 0,
    ino: u64 = 0,
    mode: u32 = 0,
    nlink: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 0,
    blocks: i64 = 0,
    atime: Ts = .{},
    mtime: Ts = .{},
    ctime: Ts = .{},

    fn fromLinux(s: linux.Stat) Stat {
        return .{
            .dev = @intCast(s.dev),
            .ino = @intCast(s.ino),
            .mode = @intCast(s.mode),
            .nlink = @intCast(s.nlink),
            .uid = s.uid,
            .gid = s.gid,
            .rdev = @intCast(s.rdev),
            .size = @intCast(s.size),
            .blksize = @intCast(s.blksize),
            .blocks = @intCast(s.blocks),
            .atime = .{ .sec = @intCast(s.atim.sec), .nsec = @intCast(s.atim.nsec) },
            .mtime = .{ .sec = @intCast(s.mtim.sec), .nsec = @intCast(s.mtim.nsec) },
            .ctime = .{ .sec = @intCast(s.ctim.sec), .nsec = @intCast(s.ctim.nsec) },
        };
    }
    fn fromStatx(s: linux.Statx) Stat {
        return .{
            .dev = makedev(s.dev_major, s.dev_minor),
            .ino = s.ino,
            .mode = s.mode,
            .nlink = s.nlink,
            .uid = s.uid,
            .gid = s.gid,
            .rdev = makedev(s.rdev_major, s.rdev_minor),
            .size = @intCast(s.size),
            .blksize = s.blksize,
            .blocks = @intCast(s.blocks),
            .atime = .{ .sec = s.atime.sec, .nsec = s.atime.nsec },
            .mtime = .{ .sec = s.mtime.sec, .nsec = s.mtime.nsec },
            .ctime = .{ .sec = s.ctime.sec, .nsec = s.ctime.nsec },
        };
    }
    pub fn isDir(s: Stat) bool {
        return s.mode & S_IFMT == S_IFDIR;
    }
    pub fn isReg(s: Stat) bool {
        return s.mode & S_IFMT == S_IFREG;
    }
    pub fn isLnk(s: Stat) bool {
        return s.mode & S_IFMT == S_IFLNK;
    }
    pub fn fmt(s: Stat) u32 {
        return s.mode & S_IFMT;
    }
};

pub fn makedev(major: u32, minor: u32) u64 {
    const ma: u64 = major;
    const mi: u64 = minor;
    return ((ma & 0xfffff000) << 32) | ((ma & 0xfff) << 8) | ((mi & 0xffffff00) << 12) | (mi & 0xff);
}
pub fn devMajor(d: u64) u32 {
    return @truncate(((d >> 8) & 0xfff) | ((d >> 32) & ~@as(u64, 0xfff)));
}
pub fn devMinor(d: u64) u32 {
    return @truncate((d & 0xff) | ((d >> 12) & ~@as(u64, 0xff)));
}

// ---------------------------------------------------------------------------
// Directory iteration
// ---------------------------------------------------------------------------

pub const DT_UNKNOWN: u8 = 0;
pub const DT_DIR: u8 = 4;
pub const DT_LNK: u8 = 10;
pub const DT_REG: u8 = 8;

pub const DirEntry = struct { name: []const u8, ino: u64, dtype: u8 };

pub const Dir = struct {
    fd: i32,
    buf: [8192]u8 align(8) = undefined,
    pos: usize = 0,
    len: usize = 0,

    pub fn open(path: []const u8) SysError!*Dir {
        const fd = try sys.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        const d = gpa.create(Dir) catch {
            sys.close(fd);
            return error.NOMEM;
        };
        d.* = .{ .fd = fd };
        return d;
    }
    pub fn close(d: *Dir) void {
        sys.close(d.fd);
        gpa.destroy(d);
    }
    /// Returns next entry, skipping "." and "..".
    pub fn next(d: *Dir) SysError!?DirEntry {
        while (true) {
            if (d.pos >= d.len) {
                const rc = linux.getdents64(d.fd, &d.buf, d.buf.len);
                const n = try check(rc);
                if (n == 0) return null;
                d.len = n;
                d.pos = 0;
            }
            const base = d.pos;
            const ino = mem.readInt(u64, d.buf[base..][0..8], builtin.cpu.arch.endian());
            const reclen = mem.readInt(u16, d.buf[base + 16 ..][0..2], builtin.cpu.arch.endian());
            const dtype = d.buf[base + 18];
            const name = mem.sliceTo(d.buf[base + 19 .. base + reclen], 0);
            d.pos += reclen;
            if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .ino = ino, .dtype = dtype };
        }
    }
};

/// Read all entry names of a directory (excluding . and ..), unsorted.
pub fn readDirNames(path: []const u8) SysError![][]const u8 {
    const d = try Dir.open(path);
    defer d.close();
    var list: std.ArrayList([]const u8) = .empty;
    while (try d.next()) |e| {
        const name = gpa.dupe(u8, e.name) catch return error.NOMEM;
        list.append(gpa, name) catch return error.NOMEM;
    }
    return list.toOwnedSlice(gpa) catch return error.NOMEM;
}

pub fn freeNames(names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

pub fn sortStrings(list: [][]const u8) void {
    std.sort.heap([]const u8, list, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

// ---------------------------------------------------------------------------
// Argument parsing (GNU getopt_long style)
// ---------------------------------------------------------------------------

/// A long option: name and the equivalent short option (0 = none, returned as .long).
pub const Long = struct { []const u8, u8 };

pub const Opt = union(enum) {
    short: u8,
    long: []const u8,
    pos: [:0]const u8,
};

pub const Parser = struct {
    argv: Args,
    idx: usize = 1,
    sub: usize = 0,
    longs: []const Long = &.{},
    /// Allow options after operands (GNU permutation).
    permute: bool = true,
    /// Treat "-<digit>..." as an operand.
    neg_numbers: bool = false,
    ended: bool = false,
    lval: ?[:0]const u8 = null,
    lval_used: bool = true,
    last_long: ?[]const u8 = null,
    last_short: u8 = 0,
    help: bool = true,

    pub fn init(argv: Args, longs: []const Long) Parser {
        return .{ .argv = argv, .longs = longs };
    }

    pub fn next(p: *Parser) ?Opt {
        if (!p.lval_used) {
            usageErr("option '--{s}' doesn't allow an argument", .{p.last_long.?});
        }
        p.lval = null;
        if (p.sub != 0) {
            const a = p.argv[p.idx];
            if (p.sub < a.len) {
                const ch = a[p.sub];
                p.sub += 1;
                p.last_short = ch;
                p.last_long = null;
                return .{ .short = ch };
            }
            p.sub = 0;
            p.idx += 1;
        }
        if (p.idx >= p.argv.len) return null;
        const a = p.argv[p.idx];
        if (p.ended or a.len < 2 or a[0] != '-' or (p.neg_numbers and (std.ascii.isDigit(a[1]) or a[1] == '.'))) {
            p.idx += 1;
            if (!p.permute) p.ended = true;
            return .{ .pos = a };
        }
        if (a[1] == '-') {
            p.idx += 1;
            if (a.len == 2) {
                p.ended = true;
                return p.next();
            }
            const body = a[2..];
            var name: []const u8 = body;
            if (mem.indexOfScalar(u8, body, '=')) |e| {
                name = body[0..e];
                p.lval = a[2 + e + 1 .. :0];
                p.lval_used = false;
            }
            const res = p.resolveLong(name);
            p.last_long = res.name;
            p.last_short = 0;
            if (p.help and res.short == 0 and mem.eql(u8, res.name, "help")) printHelp();
            if (p.help and res.short == 0 and mem.eql(u8, res.name, "version")) printVersion();
            if (res.short != 0) return .{ .short = res.short };
            return .{ .long = res.name };
        }
        p.sub = 1;
        return p.next();
    }

    fn resolveLong(p: *Parser, name: []const u8) struct { name: []const u8, short: u8 } {
        const builtins = [_]Long{ .{ "help", 0 }, .{ "version", 0 } };
        for (p.longs) |l| if (mem.eql(u8, l[0], name)) return .{ .name = l[0], .short = l[1] };
        for (builtins) |l| if (mem.eql(u8, l[0], name)) return .{ .name = l[0], .short = l[1] };
        var found: ?Long = null;
        var ambiguous = false;
        for (p.longs) |l| {
            if (mem.startsWith(u8, l[0], name)) {
                if (found != null and !(found.?[1] == l[1] and l[1] != 0)) ambiguous = true;
                found = l;
            }
        }
        for (builtins) |l| {
            if (mem.startsWith(u8, l[0], name)) {
                if (found != null) ambiguous = true;
                found = l;
            }
        }
        if (ambiguous) usageErr("option '--{s}' is ambiguous", .{name});
        if (found) |f| return .{ .name = f[0], .short = f[1] };
        return .{ .name = name, .short = 0 };
    }

    /// Mandatory option argument.
    pub fn arg(p: *Parser) [:0]const u8 {
        if (p.lval) |v| {
            p.lval_used = true;
            p.lval = null;
            return v;
        }
        if (p.sub != 0) {
            const a = p.argv[p.idx];
            const s = p.sub;
            p.sub = 0;
            p.idx += 1;
            if (s < a.len) return a[s.. :0];
        }
        if (p.idx >= p.argv.len) {
            if (p.last_long) |l| usageErr("option '--{s}' requires an argument", .{l});
            usageErr("option requires an argument -- '{c}'", .{p.last_short});
        }
        const v = p.argv[p.idx];
        p.idx += 1;
        return v;
    }

    /// Optional option argument (only "--opt=VAL" or "-oVAL").
    pub fn optArg(p: *Parser) ?[:0]const u8 {
        if (p.lval) |v| {
            p.lval_used = true;
            p.lval = null;
            return v;
        }
        if (p.sub != 0) {
            const a = p.argv[p.idx];
            if (p.sub < a.len) {
                const r = a[p.sub.. :0];
                p.sub = 0;
                p.idx += 1;
                return r;
            }
        }
        return null;
    }

    /// Remaining unparsed arguments (after the current position).
    pub fn rest(p: *Parser) Args {
        if (p.sub != 0) {
            p.sub = 0;
            p.idx += 1;
        }
        return p.argv[@min(p.idx, p.argv.len)..];
    }

    pub fn bad(p: *Parser, o: Opt) noreturn {
        _ = p;
        switch (o) {
            .short => |ch| usageErr("invalid option -- '{c}'", .{ch}),
            .long => |name| usageErr("unrecognized option '--{s}'", .{name}),
            .pos => |a| usageErr("extra operand {f}", .{q(a)}),
        }
    }
};

pub fn oom() noreturn {
    fatal("memory exhausted", .{});
}

// ---------------------------------------------------------------------------
// Quoting (GNU quote / quotef)
// ---------------------------------------------------------------------------

pub const Quoted = struct {
    s: []const u8,
    always: bool,
    pub fn format(self: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeQuoted(w, self.s, self.always);
    }
};

/// Always quoted, like GNU quote(): 'name'.
pub fn q(s: []const u8) Quoted {
    return .{ .s = s, .always = true };
}
/// Quoted only if needed, like GNU quotef().
pub fn qf(s: []const u8) Quoted {
    return .{ .s = s, .always = false };
}

fn isShellSafe(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or mem.indexOfScalar(u8, "%+,-./:=@_^", ch) != null or ch >= 0x80;
}

pub fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |ch| if (!isShellSafe(ch)) return true;
    return false;
}

pub fn writeQuoted(w: *std.Io.Writer, s: []const u8, always: bool) std.Io.Writer.Error!void {
    if (!always and !needsQuoting(s)) return w.writeAll(s);
    var has_ctrl = false;
    var has_sq = false;
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) has_ctrl = true;
        if (ch == '\'') has_sq = true;
    }
    if (!has_ctrl) {
        if (has_sq and mem.indexOfAny(u8, s, "\"$`\\!") == null) {
            try w.writeByte('"');
            try w.writeAll(s);
            return w.writeByte('"');
        }
        try w.writeByte('\'');
        for (s) |ch| {
            if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
        }
        return w.writeByte('\'');
    }
    // Control characters: 'abc'$'\n''def'
    var in_q = false;
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) {
            if (in_q) try w.writeByte('\'');
            in_q = false;
            try w.writeAll("$'");
            switch (ch) {
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                '\r' => try w.writeAll("\\r"),
                0x1b => try w.writeAll("\\E"),
                else => try w.print("\\{o:0>3}", .{ch}),
            }
            try w.writeByte('\'');
        } else {
            if (!in_q) try w.writeByte('\'');
            in_q = true;
            if (ch == '\'') try w.writeAll("'\\''") else try w.writeByte(ch);
        }
    }
    if (in_q) try w.writeByte('\'');
}

// ---------------------------------------------------------------------------
// Padding helpers
// ---------------------------------------------------------------------------

pub fn padLeft(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
    try w.writeAll(s);
}
pub fn padRight(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}
pub fn numLen(n: u64) usize {
    var x = n;
    var l: usize = 1;
    while (x >= 10) : (x /= 10) l += 1;
    return l;
}
pub fn padNum(w: *std.Io.Writer, n: u64, width: usize) !void {
    const l = numLen(n);
    if (l < width) try w.splatByteAll(' ', width - l);
    try w.print("{d}", .{n});
}
pub fn fmtBuf(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch buf[0..0];
}
/// Display width of a UTF-8 string (counts code points, not bytes).
pub fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

pub fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}
pub fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    const t = if (s[0] == '+') s[1..] else s;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

/// Parse a size with optional multiplicative suffix (GNU style):
/// b=512, K/KiB=1024, KB=1000, M, MB, G, GB, T, P, E; also k, and dd's c/w.
pub fn parseSize(s_in: []const u8) ?u64 {
    var s = s_in;
    if (s.len == 0) return null;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) {
        // allow bare suffix like "K" meaning 1K
        if (s.len > 0 and std.ascii.isAlphabetic(s[0])) {
            return suffixMult(s);
        }
        return null;
    }
    const n = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    s = s[i..];
    if (s.len == 0) return n;
    const m = suffixMult(s) orelse return null;
    return std.math.mul(u64, n, m) catch null;
}

fn suffixMult(s: []const u8) ?u64 {
    if (s.len == 0) return 1;
    if (s.len == 1) switch (s[0]) {
        'b' => return 512,
        'c' => return 1,
        'w' => return 2,
        else => {},
    };
    const units = "KMGTPEZY";
    const up = std.ascii.toUpper(s[0]);
    const idx = mem.indexOfScalar(u8, units, up) orelse return null;
    if (s[0] == 'k' or s[0] == 'K' or std.ascii.isUpper(s[0])) {} else return null;
    if (idx > 6) return null;
    const rest_s = s[1..];
    var base: u64 = 1024;
    if (rest_s.len == 0 or mem.eql(u8, rest_s, "iB")) {
        base = 1024;
    } else if (mem.eql(u8, rest_s, "B")) {
        base = 1000;
    } else return null;
    var m: u64 = 1;
    var k: usize = 0;
    while (k <= idx) : (k += 1) m = std.math.mul(u64, m, base) catch return null;
    return m;
}

/// GNU human_readable with ceiling rounding, powers of 1024 (or 1000 with si),
/// e.g. 954, 1.0K, 12K, 1.5M.
pub fn humanSize(buf: []u8, n: u64, si: bool) []const u8 {
    const base: u64 = if (si) 1000 else 1024;
    const units = if (si) "kMGTPEZY" else "KMGTPEZY";
    if (n < base) return fmtBuf(buf, "{d}", .{n});
    var div: u128 = base;
    var e: usize = 0;
    while (@as(u128, n) >= div * base and e < 7) {
        div *= base;
        e += 1;
    }
    while (true) {
        const tenths_num: u128 = @as(u128, n) * 10;
        const tenths = (tenths_num + div - 1) / div; // ceil
        if (tenths < 100) {
            return fmtBuf(buf, "{d}.{d}{c}", .{ tenths / 10, tenths % 10, units[e] });
        }
        const whole = (@as(u128, n) + div - 1) / div;
        if (whole >= base and e < 7) {
            div *= base;
            e += 1;
            continue;
        }
        return fmtBuf(buf, "{d}{c}", .{ whole, units[e] });
    }
}

// ---------------------------------------------------------------------------
// Mode strings
// ---------------------------------------------------------------------------

pub fn fileTypeChar(mode: u32) u8 {
    return switch (mode & S_IFMT) {
        S_IFDIR => 'd',
        S_IFCHR => 'c',
        S_IFBLK => 'b',
        S_IFREG => '-',
        S_IFIFO => 'p',
        S_IFLNK => 'l',
        S_IFSOCK => 's',
        else => '?',
    };
}

pub fn modeString(mode: u32) [10]u8 {
    var s: [10]u8 = "----------".*;
    s[0] = fileTypeChar(mode);
    const rwx = "rwx";
    var i: u5 = 0;
    while (i < 9) : (i += 1) {
        if (mode & (@as(u32, 1) << @intCast(8 - i)) != 0) s[1 + i] = rwx[i % 3];
    }
    if (mode & 0o4000 != 0) s[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) s[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) s[9] = if (mode & 0o001 != 0) 't' else 'T';
    return s;
}

/// Parse an octal or symbolic mode (chmod syntax) relative to `old`.
/// `is_dir` affects 'X'. Returns null on syntax error.
pub fn parseMode(spec: []const u8, old: u32, is_dir: bool, umask_v: u32) ?u32 {
    if (spec.len > 0 and spec[0] >= '0' and spec[0] <= '7') {
        var v: u32 = 0;
        for (spec) |ch| {
            if (ch < '0' or ch > '7') return null;
            v = v * 8 + (ch - '0');
            if (v > 0o7777) return null;
        }
        // GNU: for directories, octal modes with < 5 digits keep setuid/setgid bits.
        if (is_dir and spec.len < 5) return (v & 0o7777) | (old & 0o6000 & ~(v & 0o6000)) | (v & 0o6000);
        return v;
    }
    var mode = old & 0o7777;
    var it = mem.splitScalar(u8, spec, ',');
    while (it.next()) |clause| {
        var i: usize = 0;
        var who: u32 = 0;
        while (i < clause.len) : (i += 1) {
            switch (clause[i]) {
                'u' => who |= 0o4700,
                'g' => who |= 0o2070,
                'o' => who |= 0o1007,
                'a' => who |= 0o7777,
                else => break,
            }
        }
        const who_given = who != 0;
        if (!who_given) who = 0o7777;
        if (i >= clause.len) return null;
        while (i < clause.len) {
            const op = clause[i];
            if (op != '+' and op != '-' and op != '=') return null;
            i += 1;
            var perm: u32 = 0;
            var copy_from: ?u32 = null;
            while (i < clause.len and clause[i] != '+' and clause[i] != '-' and clause[i] != '=') : (i += 1) {
                switch (clause[i]) {
                    'r' => perm |= 0o444,
                    'w' => perm |= 0o222,
                    'x' => perm |= 0o111,
                    'X' => if (is_dir or (old & 0o111) != 0) {
                        perm |= 0o111;
                    },
                    's' => perm |= 0o6000,
                    't' => perm |= 0o1000,
                    'u' => copy_from = (mode >> 6) & 7,
                    'g' => copy_from = (mode >> 3) & 7,
                    'o' => copy_from = mode & 7,
                    else => return null,
                }
            }
            if (copy_from) |cf| perm |= cf * 0o111;
            var mask = who;
            if (!who_given) {
                // Without who, umask applies (for + and =).
                mask = 0o7777 & ~(umask_v & 0o777);
                if (op == '-') mask = 0o7777 & ~(umask_v & 0o777);
            }
            const eff = perm & mask;
            switch (op) {
                '+' => mode |= eff,
                '-' => mode &= ~eff,
                '=' => {
                    var clear_mask = who & ~@as(u32, 0o6000);
                    if (!who_given) clear_mask = 0o777;
                    // keep setuid/setgid on dirs unless explicitly set
                    if (!is_dir) clear_mask |= who & 0o6000;
                    mode = (mode & ~clear_mask) | eff;
                },
                else => unreachable,
            }
        }
    }
    return mode;
}

// ---------------------------------------------------------------------------
// Users and groups
// ---------------------------------------------------------------------------

pub const User = struct { name: []const u8, uid: u32, gid: u32, gecos: []const u8, home: []const u8, shell: []const u8 };
pub const Group = struct { name: []const u8, gid: u32, members: []const u8 };

var users_loaded = false;
var users: []User = &.{};
var groups_loaded = false;
var groups_list: []Group = &.{};

pub fn readFile(path: []const u8) SysError![]u8 {
    const fd = try sys.open(path, O_RDONLY, 0);
    defer sys.close(fd);
    return readFdAll(fd);
}

pub fn readFdAll(fd: i32) SysError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        list.ensureUnusedCapacity(gpa, 65536) catch return error.NOMEM;
        const dst = list.unusedCapacitySlice();
        const n = try sys.read(fd, dst);
        if (n == 0) break;
        list.items.len += n;
    }
    return list.toOwnedSlice(gpa) catch return error.NOMEM;
}

fn loadUsers() void {
    if (users_loaded) return;
    users_loaded = true;
    const data = readFile("/etc/passwd") catch return;
    var list: std.ArrayList(User) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const uid = parseUint(f.next() orelse continue) orelse continue;
        const gid = parseUint(f.next() orelse continue) orelse continue;
        const gecos = f.next() orelse "";
        const home = f.next() orelse "";
        const shell = f.next() orelse "";
        list.append(gpa, .{ .name = name, .uid = @truncate(uid), .gid = @truncate(gid), .gecos = gecos, .home = home, .shell = shell }) catch return;
    }
    users = list.items;
}

fn loadGroups() void {
    if (groups_loaded) return;
    groups_loaded = true;
    const data = readFile("/etc/group") catch return;
    var list: std.ArrayList(Group) = .empty;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const gid = parseUint(f.next() orelse continue) orelse continue;
        const members = f.next() orelse "";
        list.append(gpa, .{ .name = name, .gid = @truncate(gid), .members = members }) catch return;
    }
    groups_list = list.items;
}

pub fn userByUid(uid: u32) ?User {
    loadUsers();
    for (users) |u| if (u.uid == uid) return u;
    return null;
}
pub fn userByName(name: []const u8) ?User {
    loadUsers();
    for (users) |u| if (mem.eql(u8, u.name, name)) return u;
    return null;
}
pub fn groupByGid(gid: u32) ?Group {
    loadGroups();
    for (groups_list) |g| if (g.gid == gid) return g;
    return null;
}
pub fn groupByName(name: []const u8) ?Group {
    loadGroups();
    for (groups_list) |g| if (mem.eql(u8, g.name, name)) return g;
    return null;
}
pub fn allGroups() []Group {
    loadGroups();
    return groups_list;
}

/// User name or the numeric id as a string (in buf).
pub fn userName(buf: []u8, uid: u32) []const u8 {
    if (userByUid(uid)) |u| return u.name;
    return fmtBuf(buf, "{d}", .{uid});
}
pub fn groupName(buf: []u8, gid: u32) []const u8 {
    if (groupByGid(gid)) |g| return g.name;
    return fmtBuf(buf, "{d}", .{gid});
}

/// Supplementary groups of a user by scanning /etc/group; includes primary gid first.
pub fn userGroupList(name: []const u8, primary: u32) []u32 {
    loadGroups();
    var list: std.ArrayList(u32) = .empty;
    list.append(gpa, primary) catch oom();
    for (groups_list) |g| {
        var it = mem.splitScalar(u8, g.members, ',');
        while (it.next()) |m| {
            if (mem.eql(u8, m, name)) {
                if (mem.indexOfScalar(u32, list.items, g.gid) == null) list.append(gpa, g.gid) catch oom();
                break;
            }
        }
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Time: time zones, broken-down time, strftime
// ---------------------------------------------------------------------------

pub const Tm = struct {
    year: i64 = 1970,
    mon: u8 = 0, // 0-11
    mday: u8 = 1, // 1-31
    hour: u8 = 0,
    min: u8 = 0,
    sec: u8 = 0,
    wday: u8 = 4, // 0 = Sunday
    yday: u16 = 0, // 0-365
    gmtoff: i32 = 0,
    isdst: bool = false,
    zone: []const u8 = "UTC",
};

pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn gmtime(t: i64) Tm {
    const days = @divFloor(t, 86400);
    const secs = t - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    if (m <= 2) y += 1;
    const yday = days - daysFromCivil(y, 1, 1);
    return .{
        .year = y,
        .mon = m - 1,
        .mday = d,
        .hour = @intCast(@divFloor(secs, 3600)),
        .min = @intCast(@mod(@divFloor(secs, 60), 60)),
        .sec = @intCast(@mod(secs, 60)),
        .wday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(yday),
    };
}

pub fn timegm(tm: Tm) i64 {
    // normalise month overflow
    var y = tm.year;
    var mo: i64 = tm.mon;
    y += @divFloor(mo, 12);
    mo = @mod(mo, 12);
    const days = daysFromCivil(y, @intCast(mo + 1), 1) + @as(i64, tm.mday) - 1;
    return days * 86400 + @as(i64, tm.hour) * 3600 + @as(i64, tm.min) * 60 + tm.sec;
}

const TType = struct { off: i32, isdst: bool, abbr: []const u8 };
const Zone = struct {
    trans: []i64 = &.{},
    idx: []u8 = &.{},
    types: []TType = &.{},
    fixed: TType = .{ .off = 0, .isdst = false, .abbr = "UTC" },
};
var zone_loaded = false;
var zone: Zone = .{};
pub var force_utc = false;

fn parseTzString(s: []const u8) ?TType {
    // NAME[+-]hh[:mm[:ss]]... ; DST part ignored
    var i: usize = 0;
    var name: []const u8 = "";
    if (s.len > 0 and s[0] == '<') {
        const e = mem.indexOfScalar(u8, s, '>') orelse return null;
        name = s[1..e];
        i = e + 1;
    } else {
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        name = s[0..i];
    }
    if (name.len < 3) return null;
    var sign: i32 = 1;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s[i] == '-') sign = -1;
        i += 1;
    }
    var parts = [3]i32{ 0, 0, 0 };
    var pi: usize = 0;
    var any = false;
    while (i < s.len and pi < 3) {
        if (std.ascii.isDigit(s[i])) {
            parts[pi] = parts[pi] * 10 + (s[i] - '0');
            any = true;
            i += 1;
        } else if (s[i] == ':') {
            pi += 1;
            i += 1;
        } else break;
    }
    if (!any) return null;
    // POSIX offsets are west-positive
    const off = -sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    return .{ .off = off, .isdst = false, .abbr = name };
}

fn loadTzif(data: []const u8) bool {
    if (data.len < 44 or !mem.eql(u8, data[0..4], "TZif")) return false;
    const be = std.builtin.Endian.big;
    var hdr = data[0..44];
    var v2 = data[4] >= '2';
    var off: usize = 44;
    var tsize: usize = 4;
    const counts = struct {
        fn get(h: []const u8, k: usize) usize {
            return mem.readInt(u32, h[20 + 4 * k ..][0..4], be);
        }
    };
    if (v2) {
        // skip v1 block
        const isut = counts.get(hdr, 0);
        const isstd = counts.get(hdr, 1);
        const leap = counts.get(hdr, 2);
        const timec = counts.get(hdr, 3);
        const typec = counts.get(hdr, 4);
        const charc = counts.get(hdr, 5);
        const skip = timec * 5 + typec * 6 + charc + leap * 8 + isstd + isut;
        if (off + skip + 44 > data.len) {
            v2 = false;
        } else {
            off += skip;
            hdr = data[off..][0..44];
            off += 44;
            tsize = 8;
        }
    }
    const isut = counts.get(hdr, 0);
    const isstd = counts.get(hdr, 1);
    _ = isut;
    _ = isstd;
    const timec = counts.get(hdr, 3);
    const typec = counts.get(hdr, 4);
    const charc = counts.get(hdr, 5);
    if (off + timec * (tsize + 1) + typec * 6 + charc > data.len or typec == 0) return false;
    const trans = gpa.alloc(i64, timec) catch return false;
    for (0..timec) |k| {
        trans[k] = if (tsize == 8)
            mem.readInt(i64, data[off + k * 8 ..][0..8], be)
        else
            mem.readInt(i32, data[off + k * 4 ..][0..4], be);
    }
    off += timec * tsize;
    const idx = gpa.dupe(u8, data[off .. off + timec]) catch return false;
    off += timec;
    const types = gpa.alloc(TType, typec) catch return false;
    const abbr_base = off + typec * 6;
    for (0..typec) |k| {
        const p = data[off + k * 6 ..][0..6];
        const ai: usize = p[5];
        var abbr: []const u8 = "";
        if (abbr_base + ai < data.len) abbr = mem.sliceTo(data[abbr_base + ai .. abbr_base + charc], 0);
        types[k] = .{ .off = mem.readInt(i32, p[0..4], be), .isdst = p[4] != 0, .abbr = abbr };
    }
    zone.trans = trans;
    zone.idx = idx;
    zone.types = types;
    // default type: first non-dst
    zone.fixed = types[0];
    for (types) |t| if (!t.isdst) {
        zone.fixed = t;
        break;
    };
    return true;
}

fn loadZone() void {
    if (zone_loaded) return;
    zone_loaded = true;
    if (force_utc) return;
    if (posix.getenv("TZ")) |tz_raw| {
        var tz = tz_raw;
        if (tz.len == 0) return;
        if (tz[0] == ':') tz = tz[1..];
        if (parseTzString(tz)) |t| {
            zone.fixed = t;
            // If there is no DST rule, we're done; else also try zoneinfo file.
            if (mem.indexOfScalar(u8, tz, ',') == null and !std.ascii.isAlphabetic(tz[tz.len - 1])) return;
        }
        var pbuf: [512]u8 = undefined;
        const path = if (tz.len > 0 and tz[0] == '/') tz else fmtBuf(&pbuf, "/usr/share/zoneinfo/{s}", .{tz});
        if (readFile(path)) |data| {
            _ = loadTzif(data);
        } else |_| {}
        return;
    }
    if (readFile("/etc/localtime")) |data| {
        _ = loadTzif(data);
    } else |_| {}
}

fn zoneAt(t: i64) TType {
    loadZone();
    if (force_utc) return .{ .off = 0, .isdst = false, .abbr = "UTC" };
    if (zone.types.len == 0) return zone.fixed;
    if (zone.trans.len == 0 or t < zone.trans[0]) return zone.fixed;
    // binary search last transition <= t
    var lo: usize = 0;
    var hi: usize = zone.trans.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (zone.trans[mid] <= t) lo = mid else hi = mid;
    }
    const ti = zone.idx[lo];
    if (ti < zone.types.len) return zone.types[ti];
    return zone.fixed;
}

pub fn localtime(t: i64) Tm {
    const z = zoneAt(t);
    var tm = gmtime(t + z.off);
    tm.gmtoff = z.off;
    tm.isdst = z.isdst;
    tm.zone = z.abbr;
    return tm;
}

/// Convert local broken-down time to epoch seconds.
pub fn mktime(tm: Tm) i64 {
    const g = timegm(tm);
    var t = g - zoneAt(g).off;
    t = g - zoneAt(t).off;
    return t;
}

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
pub const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn isoWeeksInYear(y: i64) i64 {
    const p = struct {
        fn f(x: i64) i64 {
            return @mod(x + @divFloor(x, 4) - @divFloor(x, 100) + @divFloor(x, 400), 7);
        }
    }.f;
    return if (p(y) == 4 or p(y - 1) == 3) 53 else 52;
}

fn isoWeek(tm: Tm) struct { year: i64, week: u32 } {
    const wd: i64 = if (tm.wday == 0) 7 else tm.wday; // 1..7 Mon..Sun
    var week = @divFloor(@as(i64, tm.yday) + 1 - wd + 10, 7);
    var year = tm.year;
    if (week < 1) {
        year -= 1;
        week = isoWeeksInYear(year);
    } else if (week > isoWeeksInYear(year)) {
        year += 1;
        week = 1;
    }
    return .{ .year = year, .week = @intCast(week) };
}

/// strftime with GNU extensions (flags - _ 0 ^ #, width, %N, %:z, %s).
pub fn strftime(w: *std.Io.Writer, fmt: []const u8, tm: Tm, nsec: i64, epoch: i64) !void {
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const ch = fmt[i];
        if (ch != '%' or i + 1 >= fmt.len) {
            try w.writeByte(ch);
            continue;
        }
        i += 1;
        var pad: u8 = 0; // 0 = default
        var upper = false;
        while (i < fmt.len and mem.indexOfScalar(u8, "-_0^#", fmt[i]) != null) : (i += 1) {
            switch (fmt[i]) {
                '^' => upper = true,
                '#' => upper = true,
                else => pad = fmt[i],
            }
        }
        var width: ?usize = null;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            width = (width orelse 0) * 10 + (fmt[i] - '0');
        }
        var colons: usize = 0;
        while (i < fmt.len and fmt[i] == ':') : (i += 1) colons += 1;
        if (i >= fmt.len) {
            try w.writeByte('%');
            break;
        }
        const conv = fmt[i];
        var nb: [64]u8 = undefined;
        const Num = struct {
            fn emit(wr: *std.Io.Writer, v: i64, defw: usize, defpad: u8, p: u8, wd: ?usize) !void {
                const padc: u8 = if (p == 0) defpad else p;
                const width_ = wd orelse defw;
                var b: [32]u8 = undefined;
                const neg = v < 0;
                const digits = fmtBuf(&b, "{d}", .{@abs(v)});
                const len = digits.len + @intFromBool(neg);
                if (padc == '-') {
                    if (neg) try wr.writeByte('-');
                    return wr.writeAll(digits);
                }
                if (padc == '_' or padc == ' ') {
                    if (len < width_) try wr.splatByteAll(' ', width_ - len);
                    if (neg) try wr.writeByte('-');
                    return wr.writeAll(digits);
                }
                if (neg) try wr.writeByte('-');
                if (len < width_) try wr.splatByteAll('0', width_ - len);
                try wr.writeAll(digits);
            }
        };
        var str: ?[]const u8 = null;
        switch (conv) {
            '%' => str = "%",
            'n' => str = "\n",
            't' => str = "\t",
            'a' => str = day_names[tm.wday][0..3],
            'A' => str = day_names[tm.wday],
            'b', 'h' => str = month_names[tm.mon][0..3],
            'B' => str = month_names[tm.mon],
            'p' => str = if (tm.hour < 12) "AM" else "PM",
            'P' => str = if (tm.hour < 12) "am" else "pm",
            'Z' => str = tm.zone,
            'c' => {
                try strftime(w, "%a %b %e %H:%M:%S %Y", tm, nsec, epoch);
                continue;
            },
            'D', 'x' => {
                try strftime(w, "%m/%d/%y", tm, nsec, epoch);
                continue;
            },
            'F' => {
                try strftime(w, "%Y-%m-%d", tm, nsec, epoch);
                continue;
            },
            'T', 'X' => {
                try strftime(w, "%H:%M:%S", tm, nsec, epoch);
                continue;
            },
            'R' => {
                try strftime(w, "%H:%M", tm, nsec, epoch);
                continue;
            },
            'r' => {
                try strftime(w, "%I:%M:%S %p", tm, nsec, epoch);
                continue;
            },
            'd' => try Num.emit(w, tm.mday, 2, '0', pad, width),
            'e' => try Num.emit(w, tm.mday, 2, '_', pad, width),
            'H' => try Num.emit(w, tm.hour, 2, '0', pad, width),
            'k' => try Num.emit(w, tm.hour, 2, '_', pad, width),
            'I' => try Num.emit(w, if (tm.hour % 12 == 0) 12 else tm.hour % 12, 2, '0', pad, width),
            'l' => try Num.emit(w, if (tm.hour % 12 == 0) 12 else tm.hour % 12, 2, '_', pad, width),
            'j' => try Num.emit(w, @as(i64, tm.yday) + 1, 3, '0', pad, width),
            'm' => try Num.emit(w, @as(i64, tm.mon) + 1, 2, '0', pad, width),
            'M' => try Num.emit(w, tm.min, 2, '0', pad, width),
            'S' => try Num.emit(w, tm.sec, 2, '0', pad, width),
            'y' => try Num.emit(w, @mod(tm.year, 100), 2, '0', pad, width),
            'Y' => try Num.emit(w, tm.year, 1, '0', pad, width),
            'C' => try Num.emit(w, @divFloor(tm.year, 100), 2, '0', pad, width),
            'u' => try Num.emit(w, if (tm.wday == 0) 7 else tm.wday, 1, '0', pad, width),
            'w' => try Num.emit(w, tm.wday, 1, '0', pad, width),
            's' => try Num.emit(w, epoch, 1, '0', pad, width),
            'U' => try Num.emit(w, @divFloor(@as(i64, tm.yday) + 7 - tm.wday, 7), 2, '0', pad, width),
            'W' => try Num.emit(w, @divFloor(@as(i64, tm.yday) + 7 - @mod(@as(i64, tm.wday) + 6, 7), 7), 2, '0', pad, width),
            'V' => try Num.emit(w, isoWeek(tm).week, 2, '0', pad, width),
            'G' => try Num.emit(w, isoWeek(tm).year, 1, '0', pad, width),
            'g' => try Num.emit(w, @mod(isoWeek(tm).year, 100), 2, '0', pad, width),
            'N' => {
                const digits = fmtBuf(&nb, "{d:0>9}", .{@as(u64, @intCast(@max(nsec, 0)))});
                const wd = @min(width orelse 9, 9);
                try w.writeAll(digits[0..wd]);
            },
            'z' => {
                const off = tm.gmtoff;
                const sign: u8 = if (off < 0) '-' else '+';
                const a: u32 = @intCast(@abs(off));
                switch (colons) {
                    0 => try w.print("{c}{d:0>2}{d:0>2}", .{ sign, a / 3600, (a / 60) % 60 }),
                    1 => try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, a / 3600, (a / 60) % 60 }),
                    else => try w.print("{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, a / 3600, (a / 60) % 60, a % 60 }),
                }
            },
            else => {
                try w.writeByte('%');
                try w.writeByte(conv);
            },
        }
        if (str) |s| {
            if (width) |wd| if (s.len < wd) try w.splatByteAll(if (pad == '0') '0' else ' ', wd - s.len);
            if (upper) {
                for (s) |c2| try w.writeByte(std.ascii.toUpper(c2));
            } else try w.writeAll(s);
        }
    }
}

/// Parse a date string (subset of GNU date -d): "@EPOCH", "YYYY-MM-DD[ T]HH:MM[:SS][.frac]",
/// "HH:MM[:SS]", "now", "today", "yesterday", "tomorrow", "N days ago", "+N days"...
pub fn parseDate(s_in: []const u8, base: i64, utc: bool) ?Ts {
    const s = mem.trim(u8, s_in, " \t\n");
    if (s.len > 0 and s[0] == '@') {
        const rest_s = s[1..];
        if (mem.indexOfScalar(u8, rest_s, '.')) |dot| {
            const secs = parseInt(rest_s[0..dot]) orelse return null;
            var frac: i64 = 0;
            var digits: usize = 0;
            for (rest_s[dot + 1 ..]) |ch| {
                if (!std.ascii.isDigit(ch)) return null;
                if (digits < 9) {
                    frac = frac * 10 + (ch - '0');
                    digits += 1;
                }
            }
            while (digits < 9) : (digits += 1) frac *= 10;
            return .{ .sec = secs, .nsec = frac };
        }
        return .{ .sec = parseInt(rest_s) orelse return null };
    }
    const toLocal = struct {
        fn f(t: i64, u: bool) Tm {
            return if (u) gmtime(t) else localtime(t);
        }
        fn back(tm: Tm, u: bool) i64 {
            return if (u) timegm(tm) else mktime(tm);
        }
    };
    var tm = toLocal.f(base, utc);
    var result: i64 = base;
    var nsec: i64 = 0;
    var tokens = mem.tokenizeAny(u8, s, " \t");
    var have_date = false;
    var have_time = false;
    var rel: i64 = 0;
    var pending_num: ?i64 = null;
    var have_tz_utc = utc;
    while (tokens.next()) |tok_raw| {
        var tok = tok_raw;
        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..@min(tok.len, 64)], tok[0..@min(tok.len, 64)]);
        if (mem.eql(u8, lower, "now")) continue;
        if (mem.eql(u8, lower, "today")) continue;
        if (mem.eql(u8, lower, "yesterday")) {
            rel -= 86400;
            continue;
        }
        if (mem.eql(u8, lower, "tomorrow")) {
            rel += 86400;
            continue;
        }
        if (mem.eql(u8, lower, "ago")) {
            rel = -rel;
            continue;
        }
        if (mem.eql(u8, lower, "utc") or mem.eql(u8, lower, "gmt") or mem.eql(u8, lower, "z")) {
            have_tz_utc = true;
            continue;
        }
        const units = [_]struct { []const u8, i64 }{
            .{ "sec", 1 },     .{ "second", 1 }, .{ "min", 60 },       .{ "minute", 60 },
            .{ "hour", 3600 }, .{ "day", 86400 }, .{ "week", 604800 }, .{ "fortnight", 1209600 },
            .{ "month", -1 },  .{ "year", -2 },
        };
        var matched_unit = false;
        for (units) |u| {
            if (mem.eql(u8, lower, u[0]) or (lower.len == u[0].len + 1 and mem.startsWith(u8, lower, u[0]) and lower[lower.len - 1] == 's')) {
                const n = pending_num orelse 1;
                pending_num = null;
                if (u[1] == -1) {
                    tm = toLocal.f(result + rel, have_tz_utc);
                    var mo: i64 = @as(i64, tm.mon) + n;
                    tm.year += @divFloor(mo, 12);
                    mo = @mod(mo, 12);
                    tm.mon = @intCast(mo);
                    result = toLocal.back(tm, have_tz_utc) - rel;
                } else if (u[1] == -2) {
                    tm = toLocal.f(result + rel, have_tz_utc);
                    tm.year += n;
                    result = toLocal.back(tm, have_tz_utc) - rel;
                } else rel += n * u[1];
                matched_unit = true;
                break;
            }
        }
        if (matched_unit) continue;
        if ((tok[0] == '+' or tok[0] == '-') and tok.len > 1 and std.ascii.isDigit(tok[1])) {
            pending_num = parseInt(tok) orelse return null;
            continue;
        }
        // date: YYYY-MM-DD, possibly with T
        if (tok.len >= 8 and std.ascii.isDigit(tok[0]) and mem.indexOfScalar(u8, tok, '-') != null) {
            var date_part = tok;
            var time_part: ?[]const u8 = null;
            if (mem.indexOfScalar(u8, tok, 'T')) |ti| {
                date_part = tok[0..ti];
                time_part = tok[ti + 1 ..];
            }
            var it = mem.splitScalar(u8, date_part, '-');
            const y = parseInt(it.next() orelse return null) orelse return null;
            const mo = parseUint(it.next() orelse return null) orelse return null;
            const d = parseUint(it.next() orelse return null) orelse return null;
            if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
            tm.year = y;
            tm.mon = @intCast(mo - 1);
            tm.mday = @intCast(d);
            tm.hour = 0;
            tm.min = 0;
            tm.sec = 0;
            have_date = true;
            if (time_part) |tp| {
                tok = tp;
            } else continue;
        }
        if (tok.len >= 3 and std.ascii.isDigit(tok[0]) and mem.indexOfScalar(u8, tok, ':') != null) {
            var tpart = tok;
            // strip trailing Z / zone offset
            if (tpart[tpart.len - 1] == 'Z') {
                have_tz_utc = true;
                tpart = tpart[0 .. tpart.len - 1];
            }
            if (mem.indexOfScalar(u8, tpart, '.')) |dot| {
                var frac: i64 = 0;
                var digits: usize = 0;
                for (tpart[dot + 1 ..]) |ch| {
                    if (!std.ascii.isDigit(ch)) break;
                    if (digits < 9) {
                        frac = frac * 10 + (ch - '0');
                        digits += 1;
                    }
                }
                while (digits < 9) : (digits += 1) frac *= 10;
                nsec = frac;
                tpart = tpart[0..dot];
            }
            var it = mem.splitScalar(u8, tpart, ':');
            const h = parseUint(it.next() orelse return null) orelse return null;
            const m = parseUint(it.next() orelse return null) orelse return null;
            const sec = if (it.next()) |x| parseUint(x) orelse return null else 0;
            if (h > 23 or m > 59 or sec > 60) return null;
            tm.hour = @intCast(h);
            tm.min = @intCast(m);
            tm.sec = @intCast(sec);
            have_time = true;
            continue;
        }
        if (std.ascii.isDigit(tok[0])) {
            if (parseInt(tok)) |n| {
                pending_num = n;
                continue;
            }
        }
        // month names: "Jan 5 2020" style
        var found_month = false;
        for (month_names, 0..) |mn, mi| {
            if (lower.len >= 3 and std.ascii.eqlIgnoreCase(lower[0..3], mn[0..3])) {
                tm.mon = @intCast(mi);
                found_month = true;
                have_date = true;
                tm.hour = 0;
                tm.min = 0;
                tm.sec = 0;
                break;
            }
        }
        if (found_month) continue;
        for (day_names) |dn| {
            if (lower.len >= 3 and std.ascii.eqlIgnoreCase(lower[0..3], dn[0..3])) {
                found_month = true;
                break;
            }
        }
        if (found_month) continue;
        return null;
    }
    if (pending_num) |n| {
        // e.g. "Jan 5 2020": treat trailing numbers as day then year
        if (have_date and n > 31) {
            tm.year = n;
        } else if (have_date) {
            tm.mday = @intCast(@max(1, @min(n, 31)));
        } else return null;
    }
    if (have_date or have_time) {
        if (!have_date) {
            tm = blk: {
                var t2 = toLocal.f(base, have_tz_utc);
                t2.hour = tm.hour;
                t2.min = tm.min;
                t2.sec = tm.sec;
                break :blk t2;
            };
        }
        result = toLocal.back(tm, have_tz_utc);
    }
    return .{ .sec = result + rel, .nsec = if (have_time or have_date) nsec else if (rel == 0 and !have_date) 0 else 0 };
}

// ---------------------------------------------------------------------------
// Line reading
// ---------------------------------------------------------------------------

pub const LineReader = struct {
    fd: i32,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    scan: usize = 0,
    eof: bool = false,
    delim: u8 = '\n',
    /// True if the last returned line was terminated by the delimiter.
    had_delim: bool = true,
    is_reg: bool = false,
    /// Name used in diagnostics by nextw().
    name: []const u8 = "-",
    failed: bool = false,

    pub fn init(fd: i32) LineReader {
        const buf = gpa.alloc(u8, 65536) catch oom();
        var r: LineReader = .{ .fd = fd, .buf = buf };
        if (sys.fstat(fd)) |st| {
            r.is_reg = st.isReg();
        } else |_| {}
        return r;
    }
    pub fn deinit(r: *LineReader) void {
        gpa.free(r.buf);
    }

    /// Next line without its delimiter; the slice is valid until the next call.
    pub fn next(r: *LineReader) SysError!?[]u8 {
        while (true) {
            if (mem.indexOfScalarPos(u8, r.buf[0..r.end], r.scan, r.delim)) |i| {
                const line = r.buf[r.start..i];
                r.start = i + 1;
                r.scan = r.start;
                r.had_delim = true;
                return line;
            }
            r.scan = r.end;
            if (r.eof) {
                if (r.start < r.end) {
                    const line = r.buf[r.start..r.end];
                    r.start = r.end;
                    r.scan = r.end;
                    r.had_delim = false;
                    return line;
                }
                return null;
            }
            try r.fill();
        }
    }

    /// Like next(), but reports read errors GNU style ("prog: NAME: error")
    /// and returns null (setting .failed).
    pub fn nextw(r: *LineReader) ?[]u8 {
        return r.next() catch |e| {
            warn("{s}: {s}", .{ if (mem.eql(u8, r.name, "-")) "-" else r.name, strerror(e) });
            r.failed = true;
            return null;
        };
    }

    fn fill(r: *LineReader) SysError!void {
        if (r.start > 0) {
            const n = r.end - r.start;
            mem.copyForwards(u8, r.buf[0..n], r.buf[r.start..r.end]);
            r.end = n;
            r.scan -= r.start;
            r.start = 0;
        }
        if (r.end == r.buf.len) {
            r.buf = gpa.realloc(r.buf, r.buf.len * 2) catch return error.NOMEM;
        }
        if (!r.is_reg) flush();
        const n = try sys.read(r.fd, r.buf[r.end..]);
        if (n == 0) r.eof = true else r.end += n;
    }
};

/// Open an input operand ("-" = stdin). Reports errors GNU style and returns null.
pub fn openInput(path: []const u8) ?i32 {
    if (mem.eql(u8, path, "-")) return 0;
    const fd = sys.open(path, O_RDONLY, 0) catch |e| {
        warn("{f}: {s}", .{ qf(path), strerror(e) });
        return null;
    };
    return fd;
}

pub fn closeInput(fd: i32) void {
    if (fd > 2) sys.close(fd);
}

/// Read whole input operand; null on error (already reported).
pub fn readInput(path: []const u8) ?[]u8 {
    const fd = openInput(path) orelse return null;
    defer closeInput(fd);
    return readFdAll(fd) catch |e| {
        warn("{f}: {s}", .{ qf(path), strerror(e) });
        return null;
    };
}

/// Split data into lines (without terminators). A trailing delimiter does not
/// create an extra empty line.
pub fn splitLines(data: []const u8, delim: u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < data.len) {
        const e = mem.indexOfScalarPos(u8, data, start, delim) orelse data.len;
        list.append(gpa, data[start..e]) catch oom();
        start = e + 1;
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

pub fn basename(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 1 and s[0] == '/') return s;
    if (mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

pub fn dirname(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    const i = mem.lastIndexOfScalar(u8, s, '/') orelse return ".";
    var d = s[0..i];
    while (d.len > 1 and d[d.len - 1] == '/') d = d[0 .. d.len - 1];
    if (d.len == 0) return "/";
    return d;
}

pub fn join(a: []const u8, b: []const u8) []u8 {
    if (a.len == 0) return gpa.dupe(u8, b) catch oom();
    const sep = if (a[a.len - 1] == '/') "" else "/";
    return mem.concat(gpa, u8, &.{ a, sep, b }) catch oom();
}

pub fn dupeZ(s: []const u8) [:0]u8 {
    return gpa.dupeZ(u8, s) catch oom();
}

// ---------------------------------------------------------------------------
// fnmatch
// ---------------------------------------------------------------------------

pub const FnmFlags = struct { icase: bool = false, pathname: bool = false, period: bool = false };

fn lowerIf(ch: u8, ic: bool) u8 {
    return if (ic) std.ascii.toLower(ch) else ch;
}

/// Match a bracket expression starting at p[0] == '['. Returns (matched, length) or null if malformed.
pub fn matchBracket(p: []const u8, ch_in: u8, icase: bool) ?struct { bool, usize } {
    var i: usize = 1;
    var negate = false;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) {
        negate = true;
        i += 1;
    }
    const ch = lowerIf(ch_in, icase);
    var matched = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ matched != negate, i + 1 };
        first = false;
        if (p[i] == '[' and i + 1 < p.len and p[i + 1] == ':') {
            if (mem.indexOfPos(u8, p, i + 2, ":]")) |e| {
                const cls = p[i + 2 .. e];
                if (classMatch(cls, ch_in)) matched = true;
                if (icase and (mem.eql(u8, cls, "upper") or mem.eql(u8, cls, "lower")) and std.ascii.isAlphabetic(ch_in)) matched = true;
                i = e + 2;
                continue;
            }
        }
        var lo = p[i];
        if (lo == '\\' and i + 1 < p.len) {
            i += 1;
            lo = p[i];
        }
        i += 1;
        var hi = lo;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            hi = p[i + 1];
            i += 2;
            if (hi == '\\' and i < p.len) {
                hi = p[i];
                i += 1;
            }
        }
        if (icase) {
            const l = std.ascii.toLower(ch_in);
            const u = std.ascii.toUpper(ch_in);
            if ((l >= lo and l <= hi) or (u >= lo and u <= hi)) matched = true;
        } else if (ch >= lo and ch <= hi) matched = true;
    }
    return null;
}

pub fn classMatch(cls: []const u8, ch: u8) bool {
    const a = std.ascii;
    if (mem.eql(u8, cls, "alpha")) return a.isAlphabetic(ch);
    if (mem.eql(u8, cls, "digit")) return a.isDigit(ch);
    if (mem.eql(u8, cls, "alnum")) return a.isAlphanumeric(ch);
    if (mem.eql(u8, cls, "upper")) return a.isUpper(ch);
    if (mem.eql(u8, cls, "lower")) return a.isLower(ch);
    if (mem.eql(u8, cls, "space")) return a.isWhitespace(ch);
    if (mem.eql(u8, cls, "blank")) return ch == ' ' or ch == '\t';
    if (mem.eql(u8, cls, "punct")) return ch > 0x20 and ch < 0x7f and !a.isAlphanumeric(ch);
    if (mem.eql(u8, cls, "print")) return ch >= 0x20 and ch < 0x7f;
    if (mem.eql(u8, cls, "graph")) return ch > 0x20 and ch < 0x7f;
    if (mem.eql(u8, cls, "cntrl")) return ch < 0x20 or ch == 0x7f;
    if (mem.eql(u8, cls, "xdigit")) return a.isHex(ch);
    return false;
}

pub fn fnmatch(pat: []const u8, str: []const u8, flags: FnmFlags) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (p < pat.len) {
            const pc = pat[p];
            switch (pc) {
                '*' => {
                    if (flags.period and s == 0 and s < str.len and str[s] == '.') {} else {
                        star_p = p;
                        star_s = s;
                        p += 1;
                        continue;
                    }
                },
                '?' => {
                    if (s < str.len and !(flags.pathname and str[s] == '/') and !(flags.period and s == 0 and str[s] == '.')) {
                        p += 1;
                        s += 1;
                        continue;
                    }
                },
                '[' => {
                    if (s < str.len and !(flags.pathname and str[s] == '/')) {
                        if (matchBracket(pat[p..], str[s], flags.icase)) |r| {
                            if (r[0]) {
                                p += r[1];
                                s += 1;
                                continue;
                            }
                        } else if (str[s] == '[') {
                            p += 1;
                            s += 1;
                            continue;
                        }
                    }
                },
                '\\' => {
                    if (p + 1 < pat.len) {
                        if (s < str.len and lowerIf(pat[p + 1], flags.icase) == lowerIf(str[s], flags.icase)) {
                            p += 2;
                            s += 1;
                            continue;
                        }
                    } else if (s < str.len and str[s] == '\\') {
                        p += 1;
                        s += 1;
                        continue;
                    }
                },
                else => {
                    if (s < str.len and lowerIf(pc, flags.icase) == lowerIf(str[s], flags.icase)) {
                        p += 1;
                        s += 1;
                        continue;
                    }
                },
            }
        } else if (s == str.len) return true;
        // mismatch: backtrack
        if (star_p) |sp| {
            if (star_s < str.len and !(flags.pathname and str[star_s] == '/')) {
                star_s += 1;
                s = star_s;
                p = sp + 1;
                continue;
            }
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

pub fn isatty(fd: i32) bool {
    var t: linux.termios = undefined;
    return posix.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

pub fn winSize(fd: i32) ?posix.winsize {
    var ws: posix.winsize = undefined;
    if (posix.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS) return null;
    return ws;
}

pub fn termWidth() usize {
    if (winSize(1)) |ws| if (ws.col > 0) return ws.col;
    if (posix.getenv("COLUMNS")) |c| if (parseUint(c)) |n| if (n > 0) return @intCast(n);
    return 80;
}

pub fn tcgetattr(fd: i32) SysError!linux.termios {
    var t: linux.termios = undefined;
    _ = try sys.ioctl(fd, linux.T.CGETS, @intFromPtr(&t));
    return t;
}
pub fn tcsetattr(fd: i32, t: *const linux.termios) SysError!void {
    _ = try sys.ioctl(fd, linux.T.CSETSW, @intFromPtr(t));
}

// ---------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------

pub fn envp() [*:null]const ?[*:0]const u8 {
    return @ptrCast(std.os.environ.ptr);
}

/// Build a null-terminated argv array.
pub fn makeArgv(args: []const []const u8) [*:null]const ?[*:0]const u8 {
    const arr = gpa.allocSentinel(?[*:0]const u8, args.len, null) catch oom();
    for (args, 0..) |a, i| arr[i] = dupeZ(a).ptr;
    return arr.ptr;
}

/// execvp: search PATH; returns the error of the most relevant failure.
pub fn execvp(args: []const []const u8, env: [*:null]const ?[*:0]const u8) SysError {
    const argv = makeArgv(args);
    const name = args[0];
    if (mem.indexOfScalar(u8, name, '/') != null) {
        return mapErrno(posix.errno(linux.execve(argv[0].?, argv, env)));
    }
    const path = posix.getenv("PATH") orelse "/bin:/usr/bin:/sbin:/usr/sbin";
    var it = mem.splitScalar(u8, path, ':');
    var saw_eacces = false;
    var buf: [PATH_MAX]u8 = undefined;
    while (it.next()) |dir| {
        const d = if (dir.len == 0) "." else dir;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ d, name }) catch continue;
        const e = posix.errno(linux.execve(full.ptr, argv, env));
        switch (e) {
            .ACCES => saw_eacces = true,
            .NOENT, .NOTDIR => {},
            .NOEXEC => {
                // try as shell script
                var sargs: std.ArrayList([]const u8) = .empty;
                sargs.append(gpa, "/bin/sh") catch oom();
                sargs.append(gpa, full) catch oom();
                sargs.appendSlice(gpa, args[1..]) catch oom();
                const sargv = makeArgv(sargs.items);
                _ = linux.execve("/bin/sh", sargv, env);
                return error.NOEXEC;
            },
            else => return mapErrno(e),
        }
    }
    return if (saw_eacces) error.ACCES else error.NOENT;
}

/// Exit status like a shell: 128+signal for signaled children.
pub fn statusCode(status: u32) u8 {
    if (status & 0x7f == 0) return @truncate((status >> 8) & 0xff);
    return @truncate(128 + (status & 0x7f));
}

/// Fork, exec (with PATH lookup) and wait. Returns exit code: 126/127 on exec failure.
pub fn runCommand(args: []const []const u8) u8 {
    flush();
    const pid = sys.fork() catch |e| {
        warn("cannot fork: {s}", .{strerror(e)});
        return 126;
    };
    if (pid == 0) {
        const e = execvp(args, envp());
        warn("{f}: {s}", .{ qf(args[0]), strerror(e) });
        std.process.exit(if (e == error.NOENT) 127 else 126);
    }
    const r = sys.wait(pid, 0) catch return 1;
    return statusCode(r.status);
}

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------

pub const signal_names = [_][]const u8{
    "0",    "HUP",  "INT",    "QUIT", "ILL",  "TRAP", "ABRT", "BUS",   "FPE",  "KILL",
    "USR1", "SEGV", "USR2",   "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP",
    "TSTP", "TTIN", "TTOU",   "URG",  "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "POLL",
    "PWR",  "SYS",
};

/// Parse signal name ("KILL", "SIGKILL", "9", "kill").
pub fn parseSignal(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (std.ascii.isDigit(s[0])) {
        const n = parseUint(s) orelse return null;
        if (n > 64) return null;
        return @intCast(n);
    }
    var buf: [32]u8 = undefined;
    if (s.len > buf.len) return null;
    var up = std.ascii.upperString(&buf, s);
    if (mem.startsWith(u8, up, "SIG")) up = up[3..];
    for (signal_names, 0..) |n, i| if (i > 0 and mem.eql(u8, n, up)) return @intCast(i);
    if (mem.eql(u8, up, "IO")) return 29;
    if (mem.eql(u8, up, "IOT")) return 6;
    if (mem.eql(u8, up, "CLD")) return 17;
    if (mem.startsWith(u8, up, "RTMIN")) {
        if (up.len == 5) return 34;
        if (up[5] == '+') if (parseUint(up[6..])) |k| return @intCast(34 + k);
    }
    if (mem.startsWith(u8, up, "RTMAX")) {
        if (up.len == 5) return 64;
        if (up[5] == '-') if (parseUint(up[6..])) |k| return @intCast(64 - k);
    }
    return null;
}

pub fn signalName(buf: []u8, sig: u32) []const u8 {
    if (sig < signal_names.len) return signal_names[sig];
    if (sig >= 34 and sig <= 64) {
        if (sig == 34) return "RTMIN";
        if (sig == 64) return "RTMAX";
        if (sig < 50) return fmtBuf(buf, "RTMIN+{d}", .{sig - 34});
        return fmtBuf(buf, "RTMAX-{d}", .{64 - sig});
    }
    return fmtBuf(buf, "{d}", .{sig});
}

/// Install a signal handler (or SIG_DFL/SIG_IGN via null handler + ignore flag).
pub fn setSignal(sig: u32, handler: ?*const fn (i32) callconv(.c) void, ignore: bool) void {
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = if (ignore) linux.SIG.IGN else if (handler) |h| h else linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(@intCast(sig), &sa, null);
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

pub fn getenv(name: []const u8) ?[]const u8 {
    return posix.getenv(name);
}

/// Read a small file (e.g. from /proc) into buf; returns null on error.
pub fn readSmall(path: []const u8, buf: []u8) ?[]u8 {
    const fd = sys.open(path, O_RDONLY, 0) catch return null;
    defer sys.close(fd);
    const n = sys.readFull(fd, buf) catch return null;
    return buf[0..n];
}

/// Unescape a C-style backslash escape at s[0] == '\\'. Returns (bytes, consumed).
/// Used by echo -e, printf, tr and others.
pub fn unescapeOne(s: []const u8, obuf: []u8, octal_needs_zero: bool) struct { []const u8, usize } {
    if (s.len < 2) return .{ "\\", 1 };
    const ch = s[1];
    const simple: ?u8 = switch (ch) {
        'a' => 7,
        'b' => 8,
        'e', 'E' => 0x1b,
        'f' => 12,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 11,
        '\\' => '\\',
        else => null,
    };
    if (simple) |b| {
        obuf[0] = b;
        return .{ obuf[0..1], 2 };
    }
    if (ch == 'x') {
        var v: u32 = 0;
        var i: usize = 2;
        while (i < s.len and i < 4 and std.ascii.isHex(s[i])) : (i += 1) v = v * 16 + (std.fmt.charToDigit(s[i], 16) catch 0);
        if (i == 2) return .{ s[0..2], 2 };
        obuf[0] = @truncate(v);
        return .{ obuf[0..1], i };
    }
    if (ch >= '0' and ch <= '7') {
        var i: usize = 1;
        var maxd: usize = 3;
        if (octal_needs_zero) {
            if (ch != '0') return .{ s[0..2], 2 };
            i = 2;
        }
        var v: u32 = 0;
        const start = i;
        while (i < s.len and i < start + maxd and s[i] >= '0' and s[i] <= '7') : (i += 1) v = v * 8 + (s[i] - '0');
        maxd = 0;
        obuf[0] = @truncate(v);
        return .{ obuf[0..1], i };
    }
    if (ch == 'u' or ch == 'U') {
        const maxd: usize = if (ch == 'u') 4 else 8;
        var v: u21 = 0;
        var i: usize = 2;
        while (i < s.len and i < 2 + maxd and std.ascii.isHex(s[i])) : (i += 1) v = v *% 16 + @as(u21, @intCast(std.fmt.charToDigit(s[i], 16) catch 0));
        if (i == 2) return .{ s[0..2], 2 };
        const n = std.unicode.utf8Encode(v, obuf) catch 0;
        return .{ obuf[0..n], i };
    }
    return .{ s[0..2], 2 };
}

/// Fill buf with random bytes (getrandom(2), falling back to a time-seeded PRNG).
pub fn randomBytes(buf: []u8) void {
    const rc = linux.getrandom(buf.ptr, buf.len, 0);
    if (posix.errno(rc) == .SUCCESS and rc == buf.len) return;
    var seed: u64 = @bitCast(now().nsec ^ (now().sec << 20));
    seed ^= @as(u64, @intCast(sys.getpid())) << 32;
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}

/// Read a yes/no answer from stdin (after a prompt was printed to stderr).
pub fn yesno() bool {
    flush();
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    // read one line byte-by-byte so we don't consume more input than needed
    while (n < buf.len) {
        var b: [1]u8 = undefined;
        const k = sys.read(0, &b) catch break;
        if (k == 0) break;
        if (b[0] == '\n') break;
        buf[n] = b[0];
        n += 1;
    }
    const ans = mem.trimLeft(u8, buf[0..n], " \t");
    return ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y');
}

pub const CanonMode = enum { all_exist, last_may_miss, none_exist };

/// Length of a Redox/Zen style URL scheme prefix ("sys:", "file:") or 0.
pub fn schemeLen(path: []const u8) usize {
    const colon = mem.indexOfScalar(u8, path, ':') orelse return 0;
    if (colon == 0) return 0;
    if (mem.indexOfScalar(u8, path[0..colon], '/') != null) return 0;
    if (!std.ascii.isAlphabetic(path[0])) return 0;
    for (path[0..colon]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return 0;
    return colon + 1;
}

/// Canonicalize a path resolving ".", ".." and symlinks (like realpath/readlink -f).
/// Scheme URLs such as "sys:proc/1/../2" are only normalized lexically.
pub fn canonicalize(path: []const u8, mode: CanonMode, resolve_links: bool) SysError![]u8 {
    const sl = schemeLen(path);
    if (sl > 0) {
        var res: std.ArrayList(u8) = .empty;
        res.appendSlice(gpa, path[0..sl]) catch return error.NOMEM;
        var it = mem.tokenizeScalar(u8, path[sl..], '/');
        var first = true;
        while (it.next()) |comp| {
            if (mem.eql(u8, comp, ".")) continue;
            if (mem.eql(u8, comp, "..")) {
                if (mem.lastIndexOfScalar(u8, res.items[sl..], '/')) |i| res.shrinkRetainingCapacity(sl + i) else res.shrinkRetainingCapacity(sl);
                first = res.items.len == sl;
                continue;
            }
            if (!first) res.append(gpa, '/') catch return error.NOMEM;
            res.appendSlice(gpa, comp) catch return error.NOMEM;
            first = false;
        }
        if (mode == .all_exist) _ = try sys.stat(res.items);
        return res.items;
    }
    var result: std.ArrayList(u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty; // stack of remaining components (reversed)
    var links: usize = 0;
    var cwdbuf: [PATH_MAX]u8 = undefined;
    const src: []const u8 = path;
    if (src.len == 0) return error.NOENT;
    if (src[0] != '/') {
        const cwd = try sys.getcwd(&cwdbuf);
        result.appendSlice(gpa, cwd) catch return error.NOMEM;
    }
    const pushComps = struct {
        fn f(list: *std.ArrayList([]const u8), s: []const u8) SysError!void {
            // push in reverse so we pop in order
            var comps: std.ArrayList([]const u8) = .empty;
            var it = mem.tokenizeScalar(u8, s, '/');
            while (it.next()) |x| comps.append(gpa, x) catch return error.NOMEM;
            var i = comps.items.len;
            while (i > 0) {
                i -= 1;
                list.append(gpa, comps.items[i]) catch return error.NOMEM;
            }
        }
    }.f;
    try pushComps(&pending, src);
    while (pending.pop()) |comp| {
        if (mem.eql(u8, comp, ".")) continue;
        if (mem.eql(u8, comp, "..")) {
            if (mem.lastIndexOfScalar(u8, result.items, '/')) |i| result.shrinkRetainingCapacity(i) else result.clearRetainingCapacity();
            continue;
        }
        const save_len = result.items.len;
        result.append(gpa, '/') catch return error.NOMEM;
        result.appendSlice(gpa, comp) catch return error.NOMEM;
        const is_last = pending.items.len == 0;
        const st = sys.lstat(result.items) catch |e| {
            if (e == error.NOENT or e == error.NOTDIR) {
                switch (mode) {
                    .none_exist => continue,
                    .last_may_miss => if (is_last and e == error.NOENT) continue,
                    .all_exist => {},
                }
            }
            return e;
        };
        if (st.isLnk() and resolve_links) {
            links += 1;
            if (links > 40) return error.LOOP;
            var lb: [PATH_MAX]u8 = undefined;
            const target = try sys.readlink(result.items, &lb);
            const t = gpa.dupe(u8, target) catch return error.NOMEM;
            if (t.len > 0 and t[0] == '/') {
                result.clearRetainingCapacity();
            } else {
                result.shrinkRetainingCapacity(save_len);
            }
            try pushComps(&pending, t);
            continue;
        }
        if (!is_last and !st.isDir()) {
            if (mode == .none_exist) continue;
            return error.NOTDIR;
        }
    }
    if (result.items.len == 0) result.append(gpa, '/') catch return error.NOMEM;
    return result.items;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "parser: short bundles, values, longs, permutation, --" {
    const argv = [_][:0]const u8{ "ls", "-la", "file1", "-n5", "-w", "80", "--color=always", "--lin", "7", "--", "-x" };
    var p = Parser.init(&argv, &.{ .{ "all", 'a' }, .{ "lines", 'n' }, .{ "color", 0 }, .{ "long", 'l' } });
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(std.testing.allocator);
    var positional: [4][]const u8 = undefined;
    var np: usize = 0;
    var n_val: []const u8 = "";
    var w_val: []const u8 = "";
    var color: []const u8 = "";
    var lines_long: []const u8 = "";
    while (p.next()) |o| switch (o) {
        .short => |ch| {
            try seen.append(std.testing.allocator, ch);
            if (ch == 'n') {
                if (n_val.len == 0) n_val = p.arg() else lines_long = p.arg();
            }
            if (ch == 'w') w_val = p.arg();
        },
        .long => |name| {
            try std.testing.expectEqualStrings("color", name);
            color = p.optArg().?;
        },
        .pos => |a| {
            positional[np] = a;
            np += 1;
        },
    };
    try std.testing.expectEqualStrings("lanwn", seen.items);
    try std.testing.expectEqualStrings("5", n_val);
    try std.testing.expectEqualStrings("80", w_val);
    try std.testing.expectEqualStrings("always", color);
    try std.testing.expectEqualStrings("7", lines_long);
    try std.testing.expectEqual(@as(usize, 2), np);
    try std.testing.expectEqualStrings("file1", positional[0]);
    try std.testing.expectEqualStrings("-x", positional[1]);
}

test "parser: no permutation and negative numbers" {
    const argv = [_][:0]const u8{ "env", "-i", "cmd", "-x" };
    var p = Parser.init(&argv, &.{});
    p.permute = false;
    try std.testing.expectEqual(@as(u8, 'i'), p.next().?.short);
    try std.testing.expectEqualStrings("cmd", p.next().?.pos);
    try std.testing.expectEqualStrings("-x", p.next().?.pos);
    const argv2 = [_][:0]const u8{ "seq", "-5", "-s", ",", "3" };
    var p2 = Parser.init(&argv2, &.{});
    p2.neg_numbers = true;
    try std.testing.expectEqualStrings("-5", p2.next().?.pos);
    try std.testing.expectEqual(@as(u8, 's'), p2.next().?.short);
    try std.testing.expectEqualStrings(",", p2.arg());
    try std.testing.expectEqualStrings("3", p2.next().?.pos);
    try std.testing.expect(p2.next() == null);
}

test "human sizes (GNU ceiling rounding)" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("954", humanSize(&b, 954, false));
    try std.testing.expectEqualStrings("1.0K", humanSize(&b, 1024, false));
    try std.testing.expectEqualStrings("1.5K", humanSize(&b, 1500, false));
    try std.testing.expectEqualStrings("10K", humanSize(&b, 10240, false));
    try std.testing.expectEqualStrings("11K", humanSize(&b, 10241, false));
    try std.testing.expectEqualStrings("1.0M", humanSize(&b, 1023 * 1024 + 1, false));
    try std.testing.expectEqualStrings("1.1k", humanSize(&b, 1001, true));
}

test "mode strings and chmod syntax" {
    try std.testing.expectEqualStrings("drwxr-xr-x", &modeString(S_IFDIR | 0o755));
    try std.testing.expectEqualStrings("-rwsr-sr-t", &modeString(S_IFREG | 0o7755));
    try std.testing.expectEqualStrings("-rwSr--r-T", &modeString(S_IFREG | 0o5644));
    try std.testing.expectEqual(@as(?u32, 0o755), parseMode("755", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o744), parseMode("u+x", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o604), parseMode("g-r", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o444), parseMode("a=r", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o755), parseMode("u=rwx,go=rx", 0, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o755), parseMode("+x", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o1644), parseMode("+t", 0o644, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o664), parseMode("g=u", 0o604, false, 0o022));
    try std.testing.expectEqual(@as(?u32, 0o755), parseMode("a+X", 0o644, true, 0));
    try std.testing.expectEqual(@as(?u32, null), parseMode("z+q", 0o644, false, 0));
}

test "fnmatch" {
    try std.testing.expect(fnmatch("*.txt", "a.txt", .{}));
    try std.testing.expect(!fnmatch("*.txt", "a.txt.bak", .{}));
    try std.testing.expect(fnmatch("a?c", "abc", .{}));
    try std.testing.expect(fnmatch("[a-c]x", "bx", .{}));
    try std.testing.expect(!fnmatch("[!a-c]x", "bx", .{}));
    try std.testing.expect(fnmatch("*.TXT", "b.txt", .{ .icase = true }));
    try std.testing.expect(fnmatch("[[:digit:]]*", "1abc", .{}));
    try std.testing.expect(fnmatch("\\*", "*", .{}));
    try std.testing.expect(fnmatch("*/e/*", "d/e/f", .{}));
    try std.testing.expect(!fnmatch("*", "d/e", .{ .pathname = true }));
    try std.testing.expect(fnmatch("*/e/*", "d/e/f", .{ .pathname = true }));
}

test "dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const tm = gmtime(1700000000);
    try std.testing.expectEqual(@as(i64, 2023), tm.year);
    try std.testing.expectEqual(@as(u8, 10), tm.mon);
    try std.testing.expectEqual(@as(u8, 14), tm.mday);
    try std.testing.expectEqual(@as(u8, 22), tm.hour);
    try std.testing.expectEqual(@as(i64, 1700000000), timegm(tm));
    const neg = gmtime(-86400);
    try std.testing.expectEqual(@as(i64, 1969), neg.year);
    try std.testing.expectEqual(@as(u8, 31), neg.mday);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try strftime(&w, "%Y-%m-%d %H:%M:%S %j %a %b %e|%-d|%_H", tm, 0, 1700000000);
    try std.testing.expectEqualStrings("2023-11-14 22:13:20 318 Tue Nov 14|14|22", w.buffered());
}

test "misc helpers" {
    try std.testing.expectEqualStrings("c", basename("/a/b/c/"));
    try std.testing.expectEqualStrings("/a/b", dirname("/a/b/c"));
    try std.testing.expectEqualStrings(".", dirname("file"));
    try std.testing.expectEqualStrings("/", dirname("/x"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1K"));
    try std.testing.expectEqual(@as(?u64, 1000), parseSize("1KB"));
    try std.testing.expectEqual(@as(?u64, 1536), parseSize("3b"));
    try std.testing.expectEqual(@as(?u64, 2 * 1024 * 1024), parseSize("2M"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("x1"));
    try std.testing.expectEqual(@as(?u32, 9), parseSignal("KILL"));
    try std.testing.expectEqual(@as(?u32, 15), parseSignal("SIGTERM"));
    try std.testing.expectEqual(@as(?u32, 1), parseSignal("hup"));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f} {f} {f} {f}", .{ q("a b"), q("it's"), qf("plain"), qf("sys:proc") });
    try std.testing.expectEqualStrings("'a b' \"it's\" plain sys:proc", w.buffered());
    try std.testing.expectEqual(@as(usize, 4), schemeLen("sys:proc/1"));
    try std.testing.expectEqual(@as(usize, 0), schemeLen("./a:b"));
    try std.testing.expectEqualStrings("sys:proc/2/status", try canonicalize("sys:proc/1/../2/./status", .none_exist, true));
}
