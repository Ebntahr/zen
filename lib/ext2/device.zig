//! Block device interface plus an in-memory implementation for tests.
const std = @import("std");

/// Byte-addressed storage the filesystem lives on. Offsets and lengths
/// used by the filesystem are always multiples of 512 bytes (in practice,
/// of the filesystem block size, except for the 1 KiB superblock).
pub const BlockDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{Io};

    pub const VTable = struct {
        /// Fill `buf` with the bytes at `offset`.
        read: *const fn (ptr: *anyopaque, offset: u64, buf: []u8) Error!void,
        /// Store `buf` at `offset`.
        write: *const fn (ptr: *anyopaque, offset: u64, buf: []const u8) Error!void,
        /// Make previous writes durable.
        flush: *const fn (ptr: *anyopaque) Error!void,
        /// Device capacity in bytes.
        size: *const fn (ptr: *anyopaque) u64,
    };

    pub inline fn read(self: BlockDevice, offset: u64, buf: []u8) Error!void {
        return self.vtable.read(self.ptr, offset, buf);
    }
    pub inline fn write(self: BlockDevice, offset: u64, buf: []const u8) Error!void {
        return self.vtable.write(self.ptr, offset, buf);
    }
    pub inline fn flush(self: BlockDevice) Error!void {
        return self.vtable.flush(self.ptr);
    }
    pub inline fn size(self: BlockDevice) u64 {
        return self.vtable.size(self.ptr);
    }
};

/// A RAM-backed block device (unit tests, ramdisks).
pub const MemDevice = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    /// When set, every write fails with error.Io (fault injection).
    fail_writes: bool = false,

    pub fn init(allocator: std.mem.Allocator, size_bytes: usize) error{OutOfMemory}!MemDevice {
        const bytes = try allocator.alloc(u8, size_bytes);
        @memset(bytes, 0);
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn deinit(self: *MemDevice) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn device(self: *MemDevice) BlockDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: BlockDevice.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .flush = flushImpl,
        .size = sizeImpl,
    };

    fn readImpl(ptr: *anyopaque, offset: u64, buf: []u8) BlockDevice.Error!void {
        const self: *MemDevice = @ptrCast(@alignCast(ptr));
        if (offset > self.bytes.len or buf.len > self.bytes.len - offset) return error.Io;
        const off: usize = @intCast(offset);
        @memcpy(buf, self.bytes[off..][0..buf.len]);
        self.reads += 1;
    }

    fn writeImpl(ptr: *anyopaque, offset: u64, buf: []const u8) BlockDevice.Error!void {
        const self: *MemDevice = @ptrCast(@alignCast(ptr));
        if (self.fail_writes) return error.Io;
        if (offset > self.bytes.len or buf.len > self.bytes.len - offset) return error.Io;
        const off: usize = @intCast(offset);
        @memcpy(self.bytes[off..][0..buf.len], buf);
        self.writes += 1;
    }

    fn flushImpl(ptr: *anyopaque) BlockDevice.Error!void {
        const self: *MemDevice = @ptrCast(@alignCast(ptr));
        self.flushes += 1;
    }

    fn sizeImpl(ptr: *anyopaque) u64 {
        const self: *MemDevice = @ptrCast(@alignCast(ptr));
        return self.bytes.len;
    }
};

test "mem device read/write bounds" {
    var md = try MemDevice.init(std.testing.allocator, 8192);
    defer md.deinit();
    const dev = md.device();
    try dev.write(4096, "hello");
    var buf: [5]u8 = undefined;
    try dev.read(4096, &buf);
    try std.testing.expectEqualStrings("hello", &buf);
    try std.testing.expectError(error.Io, dev.read(8190, &buf));
    try std.testing.expectEqual(@as(u64, 8192), dev.size());
}
