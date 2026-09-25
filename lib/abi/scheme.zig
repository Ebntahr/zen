//! The scheme protocol: how the kernel talks to user-space scheme servers.
//!
//! In Zen *everything is a URL*. A path such as `file:/etc/passwd`,
//! `pty:3` or `window:new?w=640&h=480` names a resource provided by the
//! scheme before the colon. Plain POSIX paths are mapped onto URLs by the
//! kernel namespace (`/etc/passwd` → `file:/etc/passwd`, `/dev/null` →
//! `null:`, `/proc/1/status` → `sys:proc/1/status`).
//!
//! A user-space server registers a scheme with `zen_scheme_register` and
//! receives a file descriptor. It `read()`s requests from it and `write()`s
//! responses back. Every request is a fixed `Request` header optionally
//! followed by `len` payload bytes; every response is a fixed `Response`
//! header followed by `len` data bytes. Servers may answer requests out of
//! order and at any later time (e.g. a blocking `read` on a pty).

const std = @import("std");

pub const MAX_PAYLOAD: usize = 64 * 1024;
/// Recommended size of a server's receive buffer.
pub const RECV_BUFFER: usize = @sizeOf(Request) + MAX_PAYLOAD;

pub const Op = enum(u32) {
    // --- handle creation -------------------------------------------------
    /// payload = path inside the scheme; flags = O_* (Linux values);
    /// arg0 = creation mode. result = new server handle.
    open = 1,
    /// Duplicate `handle`, optionally opening a sub-resource named by the
    /// payload (e.g. the slave side of a pty). result = new handle.
    dup = 2,

    // --- handle operations -----------------------------------------------
    /// Fire-and-forget; the response (if any) is ignored.
    close = 3,
    /// len = maximum bytes; arg0 = offset, arg1 = 1 for positioned reads.
    /// Response data = bytes read, result = count (0 = EOF).
    read = 4,
    /// payload = data; arg0 = offset, arg1 = 1 for positioned writes.
    /// result = bytes written.
    write = 5,
    /// arg0 = offset (two's complement), arg1 = whence. result = new offset.
    seek = 6,
    /// Response data = `Stat`.
    fstat = 7,
    fsync = 8,
    /// arg0 = new size.
    ftruncate = 9,
    /// len = buffer size. Response data = packed `linux_dirent64` records,
    /// result = byte count (0 = end of directory).
    getdents = 10,
    /// Map part of the resource: arg0 = offset, arg1 = length,
    /// flags = PROT_* bits. result = page-aligned virtual address *in the
    /// server* whose pages the kernel shares with the client.
    fmap = 11,
    /// Notification that the client unmapped arg0..arg0+arg1.
    funmap = 12,
    /// Readiness query for poll(): arg0 = requested POLL* events.
    /// Reply when at least one is ready; result = ready events.
    fevent = 13,
    /// The kernel no longer needs request arg0 (client interrupted or
    /// poll finished). The server should drop it without replying.
    cancel = 14,
    /// arg0 = ioctl request number, payload = input bytes,
    /// arg1 = maximum output bytes. Response data = output bytes.
    ioctl = 15,
    /// Response data = canonical URL path of the handle (without scheme).
    fpath = 16,
    /// arg0 = mode.
    fchmod = 17,
    /// arg0 = uid, arg1 = gid (0xFFFFFFFF = unchanged).
    fchown = 18,
    /// payload = two `Timespec` (atime, mtime).
    futimens = 19,
    /// Response data = `Statfs`.
    fstatfs = 20,

    // --- path operations (payload = path) --------------------------------
    stat = 32,
    lstat = 33,
    /// arg0 = mode.
    mkdir = 34,
    unlink = 35,
    rmdir = 36,
    /// payload = "old\x00new".
    rename = 37,
    /// payload = "target\x00linkpath".
    symlink = 38,
    /// len = max bytes. Response data = link target.
    readlink = 39,
    /// payload = "existing\x00newpath".
    link = 40,
    /// arg0 = mode.
    chmod = 41,
    /// arg0 = uid, arg1 = gid. flags bit 0 = do not follow symlinks.
    chown = 42,
    /// payload = two `Timespec` then path. flags bit 0 = no-follow.
    utimens = 43,
    /// Response data = `Statfs`.
    statfs = 44,
    /// arg0 = F_OK/R_OK/W_OK/X_OK mask.
    access = 45,
    /// arg0 = mode, arg1 = device number.
    mknod = 46,
    _,
};

/// Request header, kernel → server.
pub const Request = extern struct {
    /// Unique id to echo back in the response. Never 0.
    id: u64,
    op: Op,
    flags: u32,
    /// Identity of the calling process (effective ids).
    pid: u32,
    uid: u32,
    gid: u32,
    /// Bit 0: caller is sandboxed.
    caller_flags: u32,
    handle: u64,
    arg0: u64,
    arg1: u64,
    arg2: u64,
    /// Number of payload bytes following this header (or requested size
    /// for read-like operations whose payload is empty).
    len: u64,
};

/// Response header, server → kernel.
pub const Response = extern struct {
    id: u64,
    /// >= 0 on success, otherwise a negated Linux errno value.
    result: i64,
    /// Number of data bytes following this header.
    len: u64,
    reserved: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Request) == 72);
    std.debug.assert(@sizeOf(Response) == 32);
}

/// `struct stat` exactly as the Linux riscv64 (asm-generic) ABI defines it.
pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    mode: u32 = 0,
    nlink: u32 = 1,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u64 = 0,
    __pad1: u64 = 0,
    size: i64 = 0,
    blksize: i32 = 4096,
    __pad2: i32 = 0,
    blocks: i64 = 0,
    atime_sec: i64 = 0,
    atime_nsec: u64 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: u64 = 0,
    ctime_sec: i64 = 0,
    ctime_nsec: u64 = 0,
    __unused4: u32 = 0,
    __unused5: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Stat) == 128);
}

/// `struct statfs` (asm-generic 64-bit layout).
pub const Statfs = extern struct {
    type: i64 = 0,
    bsize: i64 = 4096,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    fsid: [2]i32 = .{ 0, 0 },
    namelen: i64 = 255,
    frsize: i64 = 4096,
    flags: i64 = 0,
    spare: [4]i64 = .{ 0, 0, 0, 0 },
};

pub const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

// File type bits for Stat.mode.
pub const S_IFMT: u32 = 0o170000;
pub const S_IFSOCK: u32 = 0o140000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFBLK: u32 = 0o060000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFIFO: u32 = 0o010000;
pub const S_ISUID: u32 = 0o4000;
pub const S_ISGID: u32 = 0o2000;
pub const S_ISVTX: u32 = 0o1000;

// Directory entry types (linux_dirent64.d_type).
pub const DT_UNKNOWN: u8 = 0;
pub const DT_FIFO: u8 = 1;
pub const DT_CHR: u8 = 2;
pub const DT_DIR: u8 = 4;
pub const DT_BLK: u8 = 6;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;
pub const DT_SOCK: u8 = 12;

// poll events
pub const POLLIN: u32 = 0x001;
pub const POLLPRI: u32 = 0x002;
pub const POLLOUT: u32 = 0x004;
pub const POLLERR: u32 = 0x008;
pub const POLLHUP: u32 = 0x010;
pub const POLLNVAL: u32 = 0x020;

// open flags (Linux riscv64 values)
pub const O_ACCMODE: u32 = 0o3;
pub const O_RDONLY: u32 = 0o0;
pub const O_WRONLY: u32 = 0o1;
pub const O_RDWR: u32 = 0o2;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_NOCTTY: u32 = 0o400;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_NONBLOCK: u32 = 0o4000;
pub const O_DIRECTORY: u32 = 0o200000;
pub const O_NOFOLLOW: u32 = 0o400000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const O_PATH: u32 = 0o10000000;

/// Append one `linux_dirent64` record to `buf` at `pos`.
/// Returns the new position, or null if it does not fit.
pub fn putDirent(buf: []u8, pos: usize, ino: u64, next_off: i64, dtype: u8, name: []const u8) ?usize {
    const reclen = std.mem.alignForward(usize, 19 + name.len + 1, 8);
    if (pos + reclen > buf.len) return null;
    const rec = buf[pos .. pos + reclen];
    @memset(rec, 0);
    std.mem.writeInt(u64, rec[0..8], ino, .little);
    std.mem.writeInt(i64, rec[8..16], next_off, .little);
    std.mem.writeInt(u16, rec[16..18], @intCast(reclen), .little);
    rec[18] = dtype;
    @memcpy(rec[19 .. 19 + name.len], name);
    return pos + reclen;
}

pub const Dirent = struct {
    ino: u64,
    off: i64,
    dtype: u8,
    name: []const u8,
};

/// Iterate over packed `linux_dirent64` records.
pub const DirentIterator = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *DirentIterator) ?Dirent {
        if (self.pos + 19 > self.buf.len) return null;
        const rec = self.buf[self.pos..];
        const reclen = std.mem.readInt(u16, rec[16..18], .little);
        if (reclen < 20 or self.pos + reclen > self.buf.len) return null;
        self.pos += reclen;
        return .{
            .ino = std.mem.readInt(u64, rec[0..8], .little),
            .off = std.mem.readInt(i64, rec[8..16], .little),
            .dtype = rec[18],
            .name = std.mem.sliceTo(rec[19..reclen], 0),
        };
    }
};

test "dirent roundtrip" {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    pos = putDirent(&buf, pos, 2, 1, DT_DIR, ".").?;
    pos = putDirent(&buf, pos, 11, 2, DT_REG, "hello.txt").?;
    var it = DirentIterator{ .buf = buf[0..pos] };
    const a = it.next().?;
    try std.testing.expectEqualStrings(".", a.name);
    const b = it.next().?;
    try std.testing.expectEqualStrings("hello.txt", b.name);
    try std.testing.expectEqual(@as(u64, 11), b.ino);
    try std.testing.expect(it.next() == null);
}
