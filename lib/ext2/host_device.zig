//! Host file-backed BlockDevice for tools and tests (uses std.fs; never
//! linked into the OS file server).
const std = @import("std");
const ext2 = @import("ext2");
const BlockDevice = ext2.BlockDevice;

pub const FileDevice = struct {
    file: std.fs.File,
    size_bytes: u64,
    /// fsync on flush (off by default: images are built, then copied).
    durable: bool = false,
    read_only: bool = false,

    /// Open an existing image.
    pub fn open(path: []const u8, read_only: bool) !FileDevice {
        const file = try std.fs.cwd().openFile(path, .{ .mode = if (read_only) .read_only else .read_write });
        errdefer file.close();
        const size = try file.getEndPos();
        return .{ .file = file, .size_bytes = size, .read_only = read_only };
    }

    /// Create (or truncate) an image of `size_bytes`. The file is sparse,
    /// so it reads as zeros.
    pub fn create(path: []const u8, size_bytes: u64) !FileDevice {
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        errdefer file.close();
        try file.setEndPos(size_bytes);
        return .{ .file = file, .size_bytes = size_bytes };
    }

    pub fn close(self: *FileDevice) void {
        self.file.close();
        self.* = undefined;
    }

    pub fn device(self: *FileDevice) BlockDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: BlockDevice.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .flush = flushImpl,
        .size = sizeImpl,
    };

    fn readImpl(ptr: *anyopaque, offset: u64, buf: []u8) BlockDevice.Error!void {
        const self: *FileDevice = @ptrCast(@alignCast(ptr));
        if (offset > self.size_bytes or buf.len > self.size_bytes - offset) return error.Io;
        const n = self.file.preadAll(buf, offset) catch return error.Io;
        if (n < buf.len) @memset(buf[n..], 0);
    }

    fn writeImpl(ptr: *anyopaque, offset: u64, buf: []const u8) BlockDevice.Error!void {
        const self: *FileDevice = @ptrCast(@alignCast(ptr));
        if (self.read_only) return error.Io;
        if (offset > self.size_bytes or buf.len > self.size_bytes - offset) return error.Io;
        self.file.pwriteAll(buf, offset) catch return error.Io;
    }

    fn flushImpl(ptr: *anyopaque) BlockDevice.Error!void {
        const self: *FileDevice = @ptrCast(@alignCast(ptr));
        if (self.durable and !self.read_only) self.file.sync() catch return error.Io;
    }

    fn sizeImpl(ptr: *anyopaque) u64 {
        const self: *FileDevice = @ptrCast(@alignCast(ptr));
        return self.size_bytes;
    }
};
