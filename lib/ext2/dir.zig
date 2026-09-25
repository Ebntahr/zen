//! Linear directory block manipulation (pure functions on block buffers).
//!
//! An ext2 directory block is a chain of variable-length records
//! `{ inode u32, rec_len u16, name_len u8, file_type u8, name[] }` that
//! exactly tiles the block. Without the `filetype` feature `name_len` is a
//! 16-bit field and there is no file type byte.
const std = @import("std");
const format = @import("format.zig");
const get16 = format.get16;
const get32 = format.get32;
const put16 = format.put16;
const put32 = format.put32;

pub const Entry = struct {
    off: u32,
    inode: u32,
    rec_len: u32,
    name_len: u32,
    file_type: u8,
    name: []const u8,
};

/// Minimal record length for a name of `name_len` bytes.
pub fn recLen(name_len: usize) u32 {
    return @intCast((8 + name_len + 3) & ~@as(usize, 3));
}

fn decodeRecLen(raw: u16, bs: u32) u32 {
    if (bs < 65536) return raw;
    if (raw == 0 or raw == 65535) return 65536;
    return (@as(u32, raw) & 65532) | ((@as(u32, raw) & 3) << 16);
}

fn encodeRecLen(len: u32, bs: u32) u16 {
    if (bs < 65536) return @intCast(len);
    if (len == 65536) return 65535;
    return @intCast((len & 65532) | ((len >> 16) & 3));
}

/// Parse and validate the record at `off`.
pub fn parse(block: []const u8, off: u32, has_ft: bool) error{Corrupt}!Entry {
    const bs: u32 = @intCast(block.len);
    if (off % 4 != 0 or @as(u64, off) + 8 > bs) return error.Corrupt;
    const rec_len = decodeRecLen(get16(block, off + 4), bs);
    var name_len: u32 = undefined;
    var ft: u8 = 0;
    if (has_ft) {
        name_len = block[off + 6];
        ft = block[off + 7];
    } else {
        name_len = get16(block, off + 6);
    }
    if (rec_len < 8 or rec_len % 4 != 0 or @as(u64, off) + rec_len > bs) return error.Corrupt;
    const inode = get32(block, off);
    if (inode != 0 and (name_len == 0 or 8 + name_len > rec_len)) return error.Corrupt;
    const nl = if (8 + name_len > rec_len) 0 else name_len;
    return .{
        .off = off,
        .inode = inode,
        .rec_len = rec_len,
        .name_len = nl,
        .file_type = ft,
        .name = block[off + 8 ..][0..nl],
    };
}

/// Write a record at `off` (padding bytes up to the minimal record length
/// are zeroed).
pub fn put(block: []u8, off: u32, inode: u32, rec_len: u32, name: []const u8, ft: u8, has_ft: bool) void {
    const bs: u32 = @intCast(block.len);
    put32(block, off, inode);
    put16(block, off + 4, encodeRecLen(rec_len, bs));
    if (has_ft) {
        block[off + 6] = @intCast(name.len);
        block[off + 7] = ft;
    } else {
        put16(block, off + 6, @intCast(name.len));
    }
    @memcpy(block[off + 8 ..][0..name.len], name);
    const end = off + recLen(name.len);
    @memset(block[off + 8 + name.len .. end], 0);
}

pub fn setRecLen(block: []u8, off: u32, rec_len: u32) void {
    put16(block, off + 4, encodeRecLen(rec_len, @intCast(block.len)));
}

pub fn setInode(block: []u8, off: u32, inode: u32, ft: u8, has_ft: bool) void {
    put32(block, off, inode);
    if (has_ft) block[off + 7] = ft;
}

/// A block holding a single empty record spanning the whole block.
pub fn initEmpty(block: []u8) void {
    @memset(block, 0);
    put32(block, 0, 0);
    setRecLen(block, 0, @intCast(block.len));
}

/// First block of a new directory: "." and "..".
pub fn initDirBlock(block: []u8, self_ino: u32, parent_ino: u32, has_ft: bool) void {
    @memset(block, 0);
    const bs: u32 = @intCast(block.len);
    put(block, 0, self_ino, 12, ".", format.FT_DIR, has_ft);
    put(block, 12, parent_ino, bs - 12, "..", format.FT_DIR, has_ft);
}

/// Insert a new record into the block if there is room, splitting an
/// existing record's slack or reusing an empty record. Returns false when
/// the block is full.
pub fn insert(block: []u8, name: []const u8, inode: u32, ft: u8, has_ft: bool) error{Corrupt}!bool {
    const bs: u32 = @intCast(block.len);
    const need = recLen(name.len);
    var off: u32 = 0;
    while (off < bs) {
        const e = try parse(block, off, has_ft);
        if (e.inode == 0) {
            if (e.rec_len >= need) {
                put(block, off, inode, e.rec_len, name, ft, has_ft);
                return true;
            }
        } else {
            const used = recLen(e.name_len);
            if (e.rec_len >= used + need) {
                const new_off = off + used;
                const new_len = e.rec_len - used;
                setRecLen(block, off, used);
                put(block, new_off, inode, new_len, name, ft, has_ft);
                return true;
            }
        }
        off += e.rec_len;
    }
    return false;
}

/// Remove the record at `off`; `prev_off` is the preceding record in the
/// same block (its rec_len absorbs the freed space) or null if `off` is the
/// first record (which is then just marked unused).
pub fn remove(block: []u8, off: u32, prev_off: ?u32, has_ft: bool) error{Corrupt}!void {
    const e = try parse(block, off, has_ft);
    if (prev_off) |p| {
        const pe = try parse(block, p, has_ft);
        if (p + pe.rec_len != off) return error.Corrupt;
        setRecLen(block, p, pe.rec_len + e.rec_len);
    } else {
        put32(block, off, 0);
    }
}

/// Validate that records tile the block exactly.
pub fn validate(block: []const u8, has_ft: bool) error{Corrupt}!void {
    const bs: u32 = @intCast(block.len);
    var off: u32 = 0;
    while (off < bs) {
        const e = try parse(block, off, has_ft);
        off += e.rec_len;
    }
    if (off != bs) return error.Corrupt;
}

test "dir block insert/remove" {
    var block: [1024]u8 = undefined;
    initDirBlock(&block, 12, 2, true);
    try validate(&block, true);
    try std.testing.expect(try insert(&block, "hello", 13, format.FT_REG_FILE, true));
    try std.testing.expect(try insert(&block, "world.txt", 14, format.FT_REG_FILE, true));
    try validate(&block, true);
    // walk
    var off: u32 = 0;
    var names: [4][]const u8 = undefined;
    var n: usize = 0;
    var prev: ?u32 = null;
    var hello_off: u32 = 0;
    var hello_prev: ?u32 = null;
    while (off < block.len) {
        const e = try parse(&block, off, true);
        names[n] = e.name;
        n += 1;
        if (std.mem.eql(u8, e.name, "hello")) {
            hello_off = off;
            hello_prev = prev;
        }
        prev = off;
        off += e.rec_len;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("world.txt", names[3]);
    try remove(&block, hello_off, hello_prev, true);
    try validate(&block, true);
    // fill the block until it is full
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (true) : (i += 1) {
        const nm = std.fmt.bufPrint(&buf, "file{d}", .{i}) catch unreachable;
        if (!try insert(&block, nm, 100 + i, format.FT_REG_FILE, true)) break;
    }
    try validate(&block, true);
    try std.testing.expect(i > 50);
}

test "empty block reuse" {
    var block: [1024]u8 = undefined;
    initEmpty(&block);
    try validate(&block, false);
    try std.testing.expect(try insert(&block, "a", 20, 0, false));
    const e = try parse(&block, 0, false);
    try std.testing.expectEqual(@as(u32, 20), e.inode);
    try std.testing.expectEqual(@as(u32, 1024), e.rec_len);
    try remove(&block, 0, null, false);
    try std.testing.expectEqual(@as(u32, 0), (try parse(&block, 0, false)).inode);
}
