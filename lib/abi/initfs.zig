//! The boot archive (`initfs:` scheme), loaded by the bootloader as an
//! initrd and served read-only by the kernel. It contains init, the
//! drivers and the file server needed to mount the root disk.
//!
//! Layout (little endian, all offsets from the start of the archive):
//!   Header  { magic "ZINITFS1", count u32, reserved u32 }
//!   Entry[count] { offset u64, size u64, mode u32, name_len u16, reserved u16, name[name_len] (padded to 8) }
//!   file data (each file 8-byte aligned)
//! Names are paths without a leading slash ("drivers/virtio-blkd").

const std = @import("std");

pub const MAGIC = "ZINITFS1";

pub const Header = extern struct {
    magic: [8]u8,
    count: u32,
    reserved: u32 = 0,
};

pub const EntryHeader = extern struct {
    offset: u64,
    size: u64,
    mode: u32,
    name_len: u16,
    reserved: u16 = 0,
};

pub const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8,
};

pub const Iterator = struct {
    archive: []const u8,
    left: u32,
    pos: usize,

    pub fn init(archive: []const u8) error{InvalidArchive}!Iterator {
        if (archive.len < @sizeOf(Header)) return error.InvalidArchive;
        if (!std.mem.eql(u8, archive[0..8], MAGIC)) return error.InvalidArchive;
        const count = std.mem.readInt(u32, archive[8..12], .little);
        return .{ .archive = archive, .left = count, .pos = @sizeOf(Header) };
    }

    pub fn next(self: *Iterator) ?Entry {
        if (self.left == 0) return null;
        const a = self.archive;
        if (self.pos + @sizeOf(EntryHeader) > a.len) return null;
        const offset = std.mem.readInt(u64, a[self.pos..][0..8], .little);
        const size = std.mem.readInt(u64, a[self.pos + 8 ..][0..8], .little);
        const mode = std.mem.readInt(u32, a[self.pos + 16 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, a[self.pos + 20 ..][0..2], .little);
        const name_start = self.pos + @sizeOf(EntryHeader);
        if (name_start + name_len > a.len or offset + size > a.len) return null;
        self.pos = std.mem.alignForward(usize, name_start + name_len, 8);
        self.left -= 1;
        return .{ .name = a[name_start .. name_start + name_len], .mode = mode, .data = a[offset .. offset + size] };
    }
};

/// Find a file by path (leading '/' ignored).
pub fn find(archive: []const u8, path: []const u8) ?Entry {
    const want = std.mem.trimLeft(u8, path, "/");
    var it = Iterator.init(archive) catch return null;
    while (it.next()) |e| if (std.mem.eql(u8, e.name, want)) return e;
    return null;
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.files.deinit(self.allocator);
    }

    /// `name` and `data` must outlive `encode`.
    pub fn add(self: *Builder, name: []const u8, mode: u32, data: []const u8) !void {
        try self.files.append(self.allocator, .{ .name = std.mem.trimLeft(u8, name, "/"), .mode = mode, .data = data });
    }

    pub fn encode(self: *const Builder) ![]u8 {
        var table_len: usize = @sizeOf(Header);
        for (self.files.items) |f| table_len = std.mem.alignForward(usize, table_len + @sizeOf(EntryHeader) + f.name.len, 8);
        var total = table_len;
        for (self.files.items) |f| total = std.mem.alignForward(usize, total + f.data.len, 8);

        const out = try self.allocator.alloc(u8, total);
        @memset(out, 0);
        @memcpy(out[0..8], MAGIC);
        std.mem.writeInt(u32, out[8..12], @intCast(self.files.items.len), .little);
        var pos: usize = @sizeOf(Header);
        var data_pos = table_len;
        for (self.files.items) |f| {
            std.mem.writeInt(u64, out[pos..][0..8], data_pos, .little);
            std.mem.writeInt(u64, out[pos + 8 ..][0..8], f.data.len, .little);
            std.mem.writeInt(u32, out[pos + 16 ..][0..4], f.mode, .little);
            std.mem.writeInt(u16, out[pos + 20 ..][0..2], @intCast(f.name.len), .little);
            @memcpy(out[pos + @sizeOf(EntryHeader) ..][0..f.name.len], f.name);
            pos = std.mem.alignForward(usize, pos + @sizeOf(EntryHeader) + f.name.len, 8);
            @memcpy(out[data_pos..][0..f.data.len], f.data);
            data_pos = std.mem.alignForward(usize, data_pos + f.data.len, 8);
        }
        return out;
    }
};

test "initfs roundtrip" {
    const a = std.testing.allocator;
    var b = Builder.init(a);
    defer b.deinit();
    try b.add("/sbin/init", 0o755, "ELF...init");
    try b.add("drivers/virtio-blkd", 0o755, "blk");
    const img = try b.encode();
    defer a.free(img);
    const e = find(img, "/drivers/virtio-blkd").?;
    try std.testing.expectEqualStrings("blk", e.data);
    try std.testing.expectEqual(@as(u32, 0o755), e.mode);
    try std.testing.expectEqualStrings("ELF...init", find(img, "sbin/init").?.data);
    try std.testing.expect(find(img, "nope") == null);
}
