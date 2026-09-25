//! Opening and using URLs ("everything is a URL") from user space.
//!
//! On Zen these are the ordinary system calls: the kernel resolves the URL
//! and forwards the request to the scheme's server. Hosted on Linux (see
//! `hosted.zig`), URLs of hosted schemes go over the server's socket,
//! while `file:`/`null:`/`rand:` and plain paths use the host directly.
//! Code that opens URLs should use these functions instead of `std.posix`.

const std = @import("std");
const hosted = @import("hosted.zig");

const posix = std.posix;
pub const page = std.heap.page_size_min;

pub fn open(path: []const u8, flags: posix.O, mode: posix.mode_t) !posix.fd_t {
    if (hosted.enabled()) {
        if (hosted.splitUrl(path)) |u| {
            if (std.mem.eql(u8, u.scheme, "file")) return posix.open(u.rest, flags, mode);
            if (std.mem.eql(u8, u.scheme, "null")) return posix.open("/dev/null", flags, mode);
            if (std.mem.eql(u8, u.scheme, "rand")) return posix.open("/dev/urandom", flags, mode);
            const raw: u32 = @bitCast(flags);
            return hosted.open(path, raw);
        }
    }
    return posix.open(path, flags, mode);
}

pub fn read(fd: posix.fd_t, buf: []u8) !usize {
    if (hosted.isHandle(fd)) return hosted.read(fd, buf);
    return posix.read(fd, buf);
}

pub fn write(fd: posix.fd_t, data: []const u8) !usize {
    if (hosted.isHandle(fd)) return hosted.write(fd, data);
    return posix.write(fd, data);
}

pub fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = try write(fd, data[off..]);
        if (n == 0) return error.BrokenPipe;
        off += n;
    }
}

pub fn close(fd: posix.fd_t) void {
    if (hosted.isHandle(fd)) return hosted.close(fd);
    posix.close(fd);
}

/// Map `len` bytes of the resource shared (framebuffers, window buffers).
pub fn mmap(fd: posix.fd_t, len: usize, prot: u32, offset: u64) ![]align(page) u8 {
    if (hosted.isHandle(fd)) return hosted.mmap(fd, len, prot, offset);
    return posix.mmap(null, len, prot, .{ .TYPE = .SHARED }, fd, offset);
}

/// poll(2) that also works for hosted URL handles.
pub fn poll(fds: []posix.pollfd, timeout: i32) !usize {
    var buffered = false;
    for (fds) |p| {
        if (p.fd < 0 or p.events & posix.POLL.IN == 0 or !hosted.isHandle(p.fd)) continue;
        if (hosted.hasBuffered(p.fd)) buffered = true else hosted.armRead(p.fd);
    }
    _ = try posix.poll(fds, if (buffered) 0 else timeout);
    var n: usize = 0;
    for (fds) |*p| {
        if (buffered and p.fd >= 0 and p.events & posix.POLL.IN != 0 and hosted.hasBuffered(p.fd)) p.revents |= posix.POLL.IN;
        if (p.revents != 0) n += 1;
    }
    return n;
}

/// Read until end of stream.
pub fn readAll(allocator: std.mem.Allocator, fd: posix.fd_t, max: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (list.items.len < max) {
        const n = try read(fd, &buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..@min(n, max - list.items.len)]);
    }
    return list.toOwnedSlice(allocator);
}

/// Read a whole URL (e.g. `launch:apps`).
pub fn readUrl(allocator: std.mem.Allocator, url: []const u8, max: usize) ![]u8 {
    const fd = try open(url, .{ .ACCMODE = .RDONLY }, 0);
    defer close(fd);
    return readAll(allocator, fd, max);
}

/// Write `msg` to a URL and read the reply into `out` (e.g. `launch:ctl`).
pub fn transact(url: []const u8, msg: []const u8, out: []u8) ![]u8 {
    const fd = try open(url, .{ .ACCMODE = .RDWR }, 0);
    defer close(fd);
    try writeAll(fd, msg);
    var n: usize = 0;
    while (n < out.len) {
        const got = try read(fd, out[n..]);
        if (got == 0) break;
        n += got;
    }
    return out[0..n];
}
