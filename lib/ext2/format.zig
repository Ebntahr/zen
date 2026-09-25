//! On-disk ext2 format: constants, field offsets and little-endian helpers.
//!
//! Structures are accessed as raw byte buffers with explicit offsets so that
//! fields we do not understand are preserved verbatim when writing back.
const std = @import("std");

pub const SUPERBLOCK_OFFSET: u64 = 1024;
pub const SUPERBLOCK_SIZE: usize = 1024;
pub const MAGIC: u16 = 0xEF53;

pub const BAD_INO: u32 = 1;
pub const ROOT_INO: u32 = 2;
pub const RESIZE_INO: u32 = 7;
pub const JOURNAL_INO: u32 = 8;
pub const GOOD_OLD_FIRST_INO: u32 = 11;
pub const GOOD_OLD_INODE_SIZE: u32 = 128;
pub const GOOD_OLD_REV: u32 = 0;
pub const DYNAMIC_REV: u32 = 1;

pub const N_BLOCKS = 15;
pub const NDIR_BLOCKS = 12;
pub const IND_BLOCK = 12;
pub const DIND_BLOCK = 13;
pub const TIND_BLOCK = 14;

pub const LINK_MAX: u16 = 32000;
pub const NAME_MAX: usize = 255;
pub const PATH_MAX: usize = 4096;
pub const MAX_SYMLINK_HOPS: u32 = 40;
/// Symlink targets shorter than this are stored inside i_block ("fast").
pub const FAST_SYMLINK_MAX: usize = N_BLOCKS * 4 - 1;

/// Size of the extra inode fields written for new inodes when the inode
/// size allows it (matches e2fsprogs: sizeof(ext2_inode_large) - 128).
pub const DEFAULT_EXTRA_ISIZE: u16 = 32;

// ---------------------------------------------------------------------------
// Feature flags
// ---------------------------------------------------------------------------
pub const COMPAT_DIR_PREALLOC: u32 = 0x0001;
pub const COMPAT_IMAGIC_INODES: u32 = 0x0002;
pub const COMPAT_HAS_JOURNAL: u32 = 0x0004;
pub const COMPAT_EXT_ATTR: u32 = 0x0008;
pub const COMPAT_RESIZE_INODE: u32 = 0x0010;
pub const COMPAT_DIR_INDEX: u32 = 0x0020;
pub const COMPAT_LAZY_BG: u32 = 0x0040;

pub const INCOMPAT_COMPRESSION: u32 = 0x0001;
pub const INCOMPAT_FILETYPE: u32 = 0x0002;
pub const INCOMPAT_RECOVER: u32 = 0x0004;
pub const INCOMPAT_JOURNAL_DEV: u32 = 0x0008;
pub const INCOMPAT_META_BG: u32 = 0x0010;
pub const INCOMPAT_EXTENTS: u32 = 0x0040;
pub const INCOMPAT_64BIT: u32 = 0x0080;
pub const INCOMPAT_MMP: u32 = 0x0100;
pub const INCOMPAT_FLEX_BG: u32 = 0x0200;
pub const INCOMPAT_INLINE_DATA: u32 = 0x8000;

pub const RO_COMPAT_SPARSE_SUPER: u32 = 0x0001;
pub const RO_COMPAT_LARGE_FILE: u32 = 0x0002;
pub const RO_COMPAT_BTREE_DIR: u32 = 0x0004;
pub const RO_COMPAT_HUGE_FILE: u32 = 0x0008;
pub const RO_COMPAT_GDT_CSUM: u32 = 0x0010;
pub const RO_COMPAT_DIR_NLINK: u32 = 0x0020;
pub const RO_COMPAT_EXTRA_ISIZE: u32 = 0x0040;
pub const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;

/// INCOMPAT features we can handle (anything else refuses to mount).
pub const SUPPORTED_INCOMPAT: u32 = INCOMPAT_FILETYPE;
/// RO_COMPAT features we can handle read-write (anything else: read-only).
pub const SUPPORTED_RO_COMPAT: u32 = RO_COMPAT_SPARSE_SUPER | RO_COMPAT_LARGE_FILE |
    RO_COMPAT_BTREE_DIR | RO_COMPAT_EXTRA_ISIZE;
/// COMPAT features we understand well enough to write safely.
pub const KNOWN_COMPAT: u32 = COMPAT_DIR_PREALLOC | COMPAT_IMAGIC_INODES | COMPAT_HAS_JOURNAL |
    COMPAT_EXT_ATTR | COMPAT_RESIZE_INODE | COMPAT_DIR_INDEX | COMPAT_LAZY_BG;

// Superblock s_state
pub const STATE_VALID: u16 = 1;
pub const STATE_ERROR: u16 = 2;

// ---------------------------------------------------------------------------
// Superblock field offsets
// ---------------------------------------------------------------------------
pub const sb = struct {
    pub const inodes_count = 0;
    pub const blocks_count = 4;
    pub const r_blocks_count = 8;
    pub const free_blocks_count = 12;
    pub const free_inodes_count = 16;
    pub const first_data_block = 20;
    pub const log_block_size = 24;
    pub const log_frag_size = 28;
    pub const blocks_per_group = 32;
    pub const frags_per_group = 36;
    pub const inodes_per_group = 40;
    pub const mtime = 44;
    pub const wtime = 48;
    pub const mnt_count = 52;
    pub const max_mnt_count = 54;
    pub const magic = 56;
    pub const state = 58;
    pub const errors = 60;
    pub const minor_rev_level = 62;
    pub const lastcheck = 64;
    pub const checkinterval = 68;
    pub const creator_os = 72;
    pub const rev_level = 76;
    pub const def_resuid = 80;
    pub const def_resgid = 82;
    pub const first_ino = 84;
    pub const inode_size = 88;
    pub const block_group_nr = 90;
    pub const feature_compat = 92;
    pub const feature_incompat = 96;
    pub const feature_ro_compat = 100;
    pub const uuid = 104;
    pub const volume_name = 120;
    pub const last_mounted = 136;
    pub const algo_bitmap = 200;
    pub const reserved_gdt_blocks = 206;
    pub const journal_uuid = 208;
    pub const journal_inum = 224;
    pub const last_orphan = 232;
    pub const hash_seed = 236;
    pub const def_hash_version = 252;
    pub const desc_size = 254;
    pub const default_mount_opts = 256;
    pub const mkfs_time = 264;
    pub const min_extra_isize = 348;
    pub const want_extra_isize = 350;
    pub const flags = 352;
};

// ---------------------------------------------------------------------------
// Group descriptor (32 bytes, no 64bit feature)
// ---------------------------------------------------------------------------
pub const GD_SIZE: u32 = 32;
pub const gd = struct {
    pub const block_bitmap = 0;
    pub const inode_bitmap = 4;
    pub const inode_table = 8;
    pub const free_blocks_count = 12;
    pub const free_inodes_count = 14;
    pub const used_dirs_count = 16;
    pub const flags = 18;
};

// ---------------------------------------------------------------------------
// Inode
// ---------------------------------------------------------------------------
pub const ino = struct {
    pub const mode = 0;
    pub const uid = 2;
    pub const size = 4;
    pub const atime = 8;
    pub const ctime = 12;
    pub const mtime = 16;
    pub const dtime = 20;
    pub const gid = 24;
    pub const links_count = 26;
    pub const blocks = 28;
    pub const flags = 32;
    pub const osd1 = 36;
    pub const block = 40;
    pub const generation = 100;
    pub const file_acl = 104;
    pub const size_high = 108;
    pub const faddr = 112;
    pub const blocks_hi = 116;
    pub const file_acl_high = 118;
    pub const uid_high = 120;
    pub const gid_high = 122;
    // Large inode fields (only when inode size > 128)
    pub const extra_isize = 128;
    pub const ctime_extra = 132;
    pub const mtime_extra = 136;
    pub const atime_extra = 140;
    pub const crtime = 144;
    pub const crtime_extra = 148;
};

// Inode flags
pub const FL_IMMUTABLE: u32 = 0x00000010;
pub const FL_APPEND: u32 = 0x00000020;
pub const FL_INDEX: u32 = 0x00001000;
pub const FL_HUGE_FILE: u32 = 0x00040000;
pub const FL_EXTENTS: u32 = 0x00080000;
pub const FL_INLINE_DATA: u32 = 0x10000000;

// Mode bits
pub const S_IFMT: u16 = 0o170000;
pub const S_IFSOCK: u16 = 0o140000;
pub const S_IFLNK: u16 = 0o120000;
pub const S_IFREG: u16 = 0o100000;
pub const S_IFBLK: u16 = 0o060000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IFCHR: u16 = 0o020000;
pub const S_IFIFO: u16 = 0o010000;
pub const PERM_MASK: u16 = 0o7777;

pub fn isDir(mode: u16) bool {
    return mode & S_IFMT == S_IFDIR;
}
pub fn isReg(mode: u16) bool {
    return mode & S_IFMT == S_IFREG;
}
pub fn isLnk(mode: u16) bool {
    return mode & S_IFMT == S_IFLNK;
}

// Directory entry file types (filetype feature)
pub const FT_UNKNOWN: u8 = 0;
pub const FT_REG_FILE: u8 = 1;
pub const FT_DIR: u8 = 2;
pub const FT_CHRDEV: u8 = 3;
pub const FT_BLKDEV: u8 = 4;
pub const FT_FIFO: u8 = 5;
pub const FT_SOCK: u8 = 6;
pub const FT_SYMLINK: u8 = 7;

pub fn fileTypeFromMode(mode: u16) u8 {
    return switch (mode & S_IFMT) {
        S_IFREG => FT_REG_FILE,
        S_IFDIR => FT_DIR,
        S_IFCHR => FT_CHRDEV,
        S_IFBLK => FT_BLKDEV,
        S_IFIFO => FT_FIFO,
        S_IFSOCK => FT_SOCK,
        S_IFLNK => FT_SYMLINK,
        else => FT_UNKNOWN,
    };
}

// Extended attribute block header
pub const EA_MAGIC: u32 = 0xEA020000;
pub const EA_REFCOUNT_OFFSET = 4;

// ---------------------------------------------------------------------------
// Little-endian helpers
// ---------------------------------------------------------------------------
pub inline fn get16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
pub inline fn get32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
pub inline fn put16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
pub inline fn put32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

/// With sparse_super, superblock backups live only in groups 0, 1 and powers
/// of 3, 5 and 7.
pub fn groupHasSuper(group: u32, sparse_super: bool) bool {
    if (!sparse_super) return true;
    if (group <= 1) return true;
    return isPowerOf(group, 3) or isPowerOf(group, 5) or isPowerOf(group, 7);
}

fn isPowerOf(n: u32, base: u32) bool {
    var v: u64 = base;
    while (v < n) v *= base;
    return v == n;
}

/// Decoded view of the fields of an inode we operate on. The raw on-disk
/// bytes are kept alongside so unknown fields survive a write-back.
pub const Inode = struct {
    mode: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    /// For directories only the low 32 bits are used (i_dir_acl preserved).
    size: u64 = 0,
    atime: u32 = 0,
    ctime: u32 = 0,
    mtime: u32 = 0,
    dtime: u32 = 0,
    links: u16 = 0,
    /// i_blocks, low 32 bits, in 512-byte units.
    blocks: u32 = 0,
    flags: u32 = 0,
    block: [N_BLOCKS]u32 = [_]u32{0} ** N_BLOCKS,
    generation: u32 = 0,
    file_acl: u32 = 0,

    pub fn decode(raw: []const u8) Inode {
        var i: Inode = .{};
        i.mode = get16(raw, ino.mode);
        i.uid = @as(u32, get16(raw, ino.uid)) | (@as(u32, get16(raw, ino.uid_high)) << 16);
        i.gid = @as(u32, get16(raw, ino.gid)) | (@as(u32, get16(raw, ino.gid_high)) << 16);
        i.size = get32(raw, ino.size);
        if (!isDir(i.mode)) i.size |= @as(u64, get32(raw, ino.size_high)) << 32;
        i.atime = get32(raw, ino.atime);
        i.ctime = get32(raw, ino.ctime);
        i.mtime = get32(raw, ino.mtime);
        i.dtime = get32(raw, ino.dtime);
        i.links = get16(raw, ino.links_count);
        i.blocks = get32(raw, ino.blocks);
        i.flags = get32(raw, ino.flags);
        for (0..N_BLOCKS) |k| i.block[k] = get32(raw, ino.block + 4 * k);
        i.generation = get32(raw, ino.generation);
        i.file_acl = get32(raw, ino.file_acl);
        return i;
    }

    /// Patch the known fields into `raw`, leaving everything else intact.
    pub fn encode(self: *const Inode, raw: []u8) void {
        put16(raw, ino.mode, self.mode);
        put16(raw, ino.uid, @truncate(self.uid));
        put16(raw, ino.uid_high, @truncate(self.uid >> 16));
        put16(raw, ino.gid, @truncate(self.gid));
        put16(raw, ino.gid_high, @truncate(self.gid >> 16));
        put32(raw, ino.size, @truncate(self.size));
        if (!isDir(self.mode)) put32(raw, ino.size_high, @truncate(self.size >> 32));
        put32(raw, ino.atime, self.atime);
        put32(raw, ino.ctime, self.ctime);
        put32(raw, ino.mtime, self.mtime);
        put32(raw, ino.dtime, self.dtime);
        put16(raw, ino.links_count, self.links);
        put32(raw, ino.blocks, self.blocks);
        put32(raw, ino.flags, self.flags);
        for (0..N_BLOCKS) |k| put32(raw, ino.block + 4 * k, self.block[k]);
        put32(raw, ino.generation, self.generation);
        put32(raw, ino.file_acl, self.file_acl);
    }

    /// Raw bytes of i_block (used for fast symlinks).
    pub fn blockBytes(self: *const Inode) [N_BLOCKS * 4]u8 {
        var out: [N_BLOCKS * 4]u8 = undefined;
        for (0..N_BLOCKS) |k| std.mem.writeInt(u32, out[4 * k ..][0..4], self.block[k], .little);
        return out;
    }

    pub fn setBlockBytes(self: *Inode, bytes: *const [N_BLOCKS * 4]u8) void {
        for (0..N_BLOCKS) |k| self.block[k] = std.mem.readInt(u32, bytes[4 * k ..][0..4], .little);
    }
};

test "sparse super groups" {
    const expect = std.testing.expect;
    try expect(groupHasSuper(0, true));
    try expect(groupHasSuper(1, true));
    try expect(!groupHasSuper(2, true));
    try expect(groupHasSuper(3, true));
    try expect(!groupHasSuper(4, true));
    try expect(groupHasSuper(5, true));
    try expect(groupHasSuper(7, true));
    try expect(groupHasSuper(9, true));
    try expect(groupHasSuper(25, true));
    try expect(groupHasSuper(49, true));
    try expect(groupHasSuper(27, true));
    try expect(!groupHasSuper(15, true));
    try expect(groupHasSuper(4, false));
}

test "inode encode/decode roundtrip" {
    var raw = [_]u8{0xAA} ** 256;
    var i = Inode.decode(&raw);
    i.mode = S_IFREG | 0o644;
    i.uid = 0x12345;
    i.gid = 0x6789A;
    i.size = 0x1_2345_6789;
    i.block[3] = 77;
    i.encode(&raw);
    const j = Inode.decode(&raw);
    try std.testing.expectEqual(i.uid, j.uid);
    try std.testing.expectEqual(i.gid, j.gid);
    try std.testing.expectEqual(i.size, j.size);
    try std.testing.expectEqual(@as(u32, 77), j.block[3]);
    // untouched field preserved
    try std.testing.expectEqual(@as(u8, 0xAA), raw[200]);
}
