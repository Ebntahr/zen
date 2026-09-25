//! Memory that a scheme server shares with its clients through `fmap`
//! (window buffers, framebuffers).
//!
//! On Zen the kernel shares the server's pages directly, so this is plain
//! anonymous memory. Hosted, the memory is a memfd so that `zen.hosted`
//! can pass it to the client process.

const std = @import("std");
const hosted = @import("hosted.zig");

const posix = std.posix;
const page = std.heap.page_size_min;

const Region = struct { base: usize, len: usize, fd: posix.fd_t };

var regions: std.ArrayList(Region) = .empty;
const alloc = std.heap.page_allocator;

/// Allocate `len` bytes (rounded up to pages) of zeroed shareable memory.
pub fn allocate(len: usize) ![]align(page) u8 {
    const bytes = std.mem.alignForward(usize, @max(len, 1), page);
    if (!hosted.enabled()) {
        return posix.mmap(null, bytes, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .POPULATE = true }, -1, 0);
    }
    const fd = try posix.memfd_create("zen-shm", std.os.linux.MFD.CLOEXEC);
    errdefer posix.close(fd);
    try posix.ftruncate(fd, bytes);
    const mem = try posix.mmap(null, bytes, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    errdefer posix.munmap(mem);
    try regions.append(alloc, .{ .base = @intFromPtr(mem.ptr), .len = bytes, .fd = fd });
    return mem;
}

pub fn free(mem: []align(page) u8) void {
    if (mem.len == 0) return;
    const bytes = std.mem.alignForward(usize, mem.len, page);
    const base = @intFromPtr(mem.ptr);
    for (regions.items, 0..) |r, i| {
        if (r.base == base) {
            posix.close(r.fd);
            _ = regions.swapRemove(i);
            break;
        }
    }
    posix.munmap(mem.ptr[0..bytes]);
}

pub const Found = struct { fd: posix.fd_t, offset: u64 };

/// The memfd and offset backing `addr` (hosted only).
pub fn lookup(addr: usize) ?Found {
    for (regions.items) |r| {
        if (addr >= r.base and addr < r.base + r.len) return .{ .fd = r.fd, .offset = addr - r.base };
    }
    return null;
}
