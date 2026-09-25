//! ext2 filesystem: mount, inode/block management and POSIX-like operations.
//!
//! Not thread-safe: callers (the file server) must serialize access.
const std = @import("std");
const format = @import("format.zig");
const device = @import("device.zig");
const cache_mod = @import("cache.zig");
const dirent = @import("dir.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const BlockDevice = device.BlockDevice;
const Cache = cache_mod.Cache;
const Buf = cache_mod.Buf;
const Inode = format.Inode;
const get16 = format.get16;
const get32 = format.get32;
const put16 = format.put16;
const put32 = format.put32;

pub const Error = errors.Error;
pub const Ino = u32;
pub const ROOT_INO: Ino = format.ROOT_INO;

pub const FileType = enum(u8) {
    unknown = 0,
    regular = 1,
    directory = 2,
    char_device = 3,
    block_device = 4,
    fifo = 5,
    socket = 6,
    symlink = 7,

    pub fn fromMode(mode: u16) FileType {
        return @enumFromInt(format.fileTypeFromMode(mode));
    }

    pub fn fromDirent(ft: u8) FileType {
        return if (ft <= 7) @enumFromInt(ft) else .unknown;
    }
};

/// Device number of a character/block special file.
pub const Dev = struct {
    major: u32 = 0,
    minor: u32 = 0,
};

pub const Stat = struct {
    ino: Ino,
    kind: FileType,
    /// Full mode including the S_IFMT type bits.
    mode: u16,
    nlink: u32,
    uid: u32,
    gid: u32,
    size: u64,
    /// Allocated space in 512-byte units (data + indirect blocks).
    blocks: u64,
    blksize: u32,
    atime: i64,
    mtime: i64,
    ctime: i64,
    rdev: Dev,
    flags: u32,
    generation: u32,
};

pub const StatFs = struct {
    block_size: u32,
    total_blocks: u64,
    free_blocks: u64,
    /// Free blocks available to unprivileged users (free - reserved).
    avail_blocks: u64,
    total_inodes: u64,
    free_inodes: u64,
    name_max: u32,
    uuid: [16]u8,
    label: [16]u8,
};

/// One directory entry produced by `DirIterator.next`.
pub const DirEntry = struct {
    ino: Ino,
    kind: FileType,
    /// Valid until the next call to `next`.
    name: []const u8,
    /// Cookie that resumes iteration right after this entry.
    cookie: u64,
};

pub const MountOptions = struct {
    read_only: bool = false,
    /// Block cache capacity in blocks.
    cache_blocks: usize = 1024,
    /// Inode cache capacity in inodes.
    inode_cache: usize = 512,
    /// Wall clock in seconds since the epoch. Without it timestamps are 0.
    now: ?*const fn () i64 = null,
    /// Directories with at least this many blocks get an in-memory hash
    /// index for O(1) lookups (0 disables).
    dir_index_min_blocks: u32 = 2,
};

pub const ParentAndName = struct {
    dir: Ino,
    /// Slice of the input path.
    name: []const u8,
};

/// A cached in-memory inode. `raw` holds the full on-disk inode so fields we
/// do not interpret are written back unchanged.
pub const CInode = struct {
    ino: Ino,
    raw: []u8,
    i: Inode,
    dirty: bool = false,
    pins: u32 = 0,
    prev: ?*CInode = null,
    next: ?*CInode = null,
    /// Last block allocated to this inode (allocation goal).
    last_alloc: u32 = 0,
    /// Directories: block where the last entry was inserted (search start).
    dir_hint: u32 = 0,
    /// Directories: blocks [0, dir_full_upto) have no room for a record of
    /// dir_full_need bytes or more (reset when an entry is removed).
    dir_full_upto: u32 = 0,
    dir_full_need: u32 = 0,
    /// Directories: optional in-memory name index.
    dindex: ?*DirIndex = null,
    /// Building the index failed (hash collision / no memory); don't retry
    /// while cached.
    dindex_failed: bool = false,
};

const BlockPath = struct {
    depth: u8,
    idx: [4]u32,
};

const Found = struct {
    ino: Ino,
    file_type: u8,
    lblk: u32,
    off: u32,
    prev_off: ?u32,
    name_hash: u64,
};

/// In-memory lookup index for a large directory: name hash -> logical
/// block holding the entry. Never written to disk (directories stay linear
/// on disk); rebuilt on demand after the inode is evicted.
const DirIndex = struct {
    map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    removals: usize = 0,

    fn remove(self: *DirIndex, h: u64) void {
        if (self.map.remove(h)) {
            self.removals += 1;
            if (self.removals > self.map.capacity() / 2) {
                self.map.rehash(std.hash_map.AutoContext(u64){});
                self.removals = 0;
            }
        }
    }
};

fn nameHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6578_7432, name);
}

const max_io_run: u32 = 256;

pub const Fs = struct {
    allocator: Allocator,
    dev: BlockDevice,
    read_only: bool,
    now_fn: ?*const fn () i64,

    sbraw: [format.SUPERBLOCK_SIZE]u8,
    sb_dirty: bool = false,
    orig_state: u16,

    bs: u32,
    inode_size: u32,
    inodes_per_group: u32,
    blocks_per_group: u32,
    groups: u32,
    first_data_block: u32,
    blocks_count: u32,
    inodes_count: u32,
    first_ino: u32,
    rev: u32,
    compat: u32,
    incompat: u32,
    ro_compat: u32,
    has_filetype: bool,
    sparse_super: bool,
    ptrs: u32,
    spb: u32,
    inode_table_blocks: u32,
    max_size: u64,

    gdt: []u8,
    gdt_blocks: u32,
    gdt_dirty: bool = false,
    /// Per group: all block bitmap bits below this index are in use.
    bb_hint: []u32,
    /// Per group: all inode bitmap bits below this index are in use.
    ib_hint: []u32,

    cache: Cache,

    imap: std.AutoHashMapUnmanaged(Ino, *CInode) = .empty,
    ihead: ?*CInode = null,
    itail: ?*CInode = null,
    icount: usize = 0,
    icap: usize,
    ispare: ?*CInode = null,
    iremovals: usize = 0,
    dir_index_min_blocks: u32,

    next_generation: u32,

    /// Inodes kept alive by `retain` (open files): ino -> count.
    holds: std.AutoHashMapUnmanaged(Ino, u32) = .empty,

    // -----------------------------------------------------------------------
    // Mount / unmount
    // -----------------------------------------------------------------------

    /// Mount the ext2 filesystem on `dev`. The returned object is heap
    /// allocated with `allocator`; release it with `unmount` (or `deinit`
    /// to drop it without writing anything).
    pub fn mount(allocator: Allocator, dev: BlockDevice, options: MountOptions) Error!*Fs {
        var sbraw: [format.SUPERBLOCK_SIZE]u8 = undefined;
        if (dev.size() < format.SUPERBLOCK_OFFSET + format.SUPERBLOCK_SIZE) return error.Corrupt;
        try dev.read(format.SUPERBLOCK_OFFSET, &sbraw);
        if (get16(&sbraw, format.sb.magic) != format.MAGIC) return error.Corrupt;

        const rev = get32(&sbraw, format.sb.rev_level);
        if (rev > format.DYNAMIC_REV) return error.Unsupported;
        const log_bs = get32(&sbraw, format.sb.log_block_size);
        if (log_bs > 6) return error.Corrupt;
        const bs: u32 = @as(u32, 1024) << @intCast(log_bs);

        var inode_size: u32 = format.GOOD_OLD_INODE_SIZE;
        var first_ino: u32 = format.GOOD_OLD_FIRST_INO;
        var compat: u32 = 0;
        var incompat: u32 = 0;
        var ro_compat: u32 = 0;
        if (rev >= format.DYNAMIC_REV) {
            inode_size = get16(&sbraw, format.sb.inode_size);
            first_ino = get32(&sbraw, format.sb.first_ino);
            compat = get32(&sbraw, format.sb.feature_compat);
            incompat = get32(&sbraw, format.sb.feature_incompat);
            ro_compat = get32(&sbraw, format.sb.feature_ro_compat);
        }
        if (inode_size < 128 or inode_size > bs or !std.math.isPowerOfTwo(inode_size)) return error.Corrupt;
        if (first_ino <= format.ROOT_INO) return error.Corrupt;

        if (incompat & ~format.SUPPORTED_INCOMPAT != 0) return error.Unsupported;
        const read_only = options.read_only;
        if (!read_only) {
            if (ro_compat & ~format.SUPPORTED_RO_COMPAT != 0) return error.Unsupported;
            // A (clean) ext3 journal is left untouched; refuse writes if it
            // comes with compat features we do not know.
            if (compat & format.COMPAT_HAS_JOURNAL != 0 and compat & ~format.KNOWN_COMPAT != 0)
                return error.Unsupported;
        }

        const blocks_count = get32(&sbraw, format.sb.blocks_count);
        const inodes_count = get32(&sbraw, format.sb.inodes_count);
        const bpg = get32(&sbraw, format.sb.blocks_per_group);
        const ipg = get32(&sbraw, format.sb.inodes_per_group);
        const fdb = get32(&sbraw, format.sb.first_data_block);
        if (bpg == 0 or bpg > bs * 8 or ipg == 0 or ipg > bs * 8) return error.Corrupt;
        if (fdb >= blocks_count or blocks_count == 0) return error.Corrupt;
        if (@as(u64, blocks_count) * bs > dev.size()) return error.Corrupt;
        const groups: u32 = @intCast(std.math.divCeil(u64, blocks_count - fdb, bpg) catch unreachable);
        if (@as(u64, ipg) * groups < inodes_count or inodes_count < first_ino) return error.Corrupt;
        const inode_table_blocks: u32 = @intCast(std.math.divCeil(u64, @as(u64, ipg) * inode_size, bs) catch unreachable);

        const gdt_blocks: u32 = @intCast(std.math.divCeil(u64, @as(u64, groups) * format.GD_SIZE, bs) catch unreachable);
        const gdt = try allocator.alloc(u8, @as(usize, gdt_blocks) * bs);
        errdefer allocator.free(gdt);
        try dev.read(@as(u64, fdb + 1) * bs, gdt);

        for (0..groups) |g| {
            const o = g * format.GD_SIZE;
            const bb = get32(gdt, o + format.gd.block_bitmap);
            const ib = get32(gdt, o + format.gd.inode_bitmap);
            const it = get32(gdt, o + format.gd.inode_table);
            if (bb < fdb or bb >= blocks_count or ib < fdb or ib >= blocks_count) return error.Corrupt;
            if (it < fdb or @as(u64, it) + inode_table_blocks > blocks_count) return error.Corrupt;
        }

        const bb_hint = try allocator.alloc(u32, groups);
        errdefer allocator.free(bb_hint);
        @memset(bb_hint, 0);
        const ib_hint = try allocator.alloc(u32, groups);
        errdefer allocator.free(ib_hint);
        @memset(ib_hint, 0);

        const self = try allocator.create(Fs);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .dev = dev,
            .read_only = read_only,
            .now_fn = options.now,
            .sbraw = sbraw,
            .orig_state = get16(&sbraw, format.sb.state),
            .bs = bs,
            .inode_size = inode_size,
            .inodes_per_group = ipg,
            .blocks_per_group = bpg,
            .groups = groups,
            .first_data_block = fdb,
            .blocks_count = blocks_count,
            .inodes_count = inodes_count,
            .first_ino = first_ino,
            .rev = rev,
            .compat = compat,
            .incompat = incompat,
            .ro_compat = ro_compat,
            .has_filetype = incompat & format.INCOMPAT_FILETYPE != 0,
            .sparse_super = ro_compat & format.RO_COMPAT_SPARSE_SUPER != 0,
            .ptrs = bs / 4,
            .spb = bs / 512,
            .inode_table_blocks = inode_table_blocks,
            .max_size = 0,
            .gdt = gdt,
            .gdt_blocks = gdt_blocks,
            .bb_hint = bb_hint,
            .ib_hint = ib_hint,
            .cache = Cache.init(allocator, dev, bs, options.cache_blocks),
            .icap = @max(options.inode_cache, 16),
            .dir_index_min_blocks = options.dir_index_min_blocks,
            .next_generation = get32(&sbraw, format.sb.wtime) ^ get32(&sbraw, format.sb.uuid),
        };
        self.max_size = self.computeMaxSize();

        if (!read_only) {
            // Mark the filesystem as in use (not cleanly unmounted).
            const st = get16(&self.sbraw, format.sb.state);
            put16(&self.sbraw, format.sb.state, st & ~format.STATE_VALID);
            put16(&self.sbraw, format.sb.mnt_count, get16(&self.sbraw, format.sb.mnt_count) +% 1);
            put32(&self.sbraw, format.sb.mtime, self.now());
            put32(&self.sbraw, format.sb.wtime, self.now());
            self.writeSuper() catch |e| {
                self.cache.deinit();
                return e;
            };
            dev.flush() catch {
                self.cache.deinit();
                return error.Io;
            };
        }
        return self;
    }

    /// Flush everything, mark the filesystem clean and free all memory.
    /// Memory is released even if writing fails.
    pub fn unmount(self: *Fs) Error!void {
        defer self.deinit();
        if (self.read_only) return;
        try self.releaseAll();
        try self.sync();
        put16(&self.sbraw, format.sb.state, self.orig_state);
        put32(&self.sbraw, format.sb.wtime, self.now());
        try self.writeSuper();
        try self.dev.flush();
    }

    /// Free all memory without writing anything back.
    pub fn deinit(self: *Fs) void {
        const allocator = self.allocator;
        var it = self.ihead;
        while (it) |ci| {
            it = ci.next;
            self.dropIndex(ci);
            allocator.free(ci.raw);
            allocator.destroy(ci);
        }
        var sp = self.ispare;
        while (sp) |ci| {
            sp = ci.next;
            allocator.free(ci.raw);
            allocator.destroy(ci);
        }
        self.imap.deinit(allocator);
        self.holds.deinit(allocator);
        self.cache.deinit();
        allocator.free(self.gdt);
        allocator.free(self.bb_hint);
        allocator.free(self.ib_hint);
        allocator.destroy(self);
    }

    /// Write all cached state (inodes, blocks, group descriptors,
    /// superblock) to the device and flush it.
    pub fn sync(self: *Fs) Error!void {
        if (self.read_only) return;
        try self.iflushAll();
        try self.cache.flush();
        if (self.gdt_dirty) {
            try self.dev.write(@as(u64, self.first_data_block + 1) * self.bs, self.gdt);
            self.gdt_dirty = false;
        }
        if (self.sb_dirty) {
            put32(&self.sbraw, format.sb.wtime, self.now());
            try self.writeSuper();
        }
        try self.dev.flush();
    }

    fn writeSuper(self: *Fs) Error!void {
        try self.dev.write(format.SUPERBLOCK_OFFSET, &self.sbraw);
        self.sb_dirty = false;
    }

    fn computeMaxSize(self: *Fs) u64 {
        // Mirrors Linux ext2_max_size(): limited by the block tree and by
        // i_blocks (32 bits of 512-byte sectors).
        const bits: u6 = @intCast(std.math.log2_int(u32, self.bs));
        const ppb: u64 = @as(u64, 1) << (bits - 2);
        var res: u64 = format.NDIR_BLOCKS;
        var upper: u64 = (@as(u64, 1) << 32) - 1;
        upper >>= (bits - 9);
        res += ppb + ppb * ppb + ppb * ppb * ppb;
        var meta: u64 = 1 + (1 + ppb) + (1 + ppb + ppb * ppb);
        if (res + meta > upper) {
            res = upper;
            var u = upper - format.NDIR_BLOCKS;
            meta = 1;
            u -= ppb;
            if (u < ppb * ppb) {
                meta += 1 + (std.math.divCeil(u64, u, ppb) catch unreachable);
            } else {
                meta += 1 + ppb;
                u -= ppb * ppb;
                meta += 1 + (std.math.divCeil(u64, u, ppb) catch unreachable) +
                    (std.math.divCeil(u64, u, ppb * ppb) catch unreachable);
            }
            res -= meta;
        }
        var max = res << bits;
        if (self.rev == format.GOOD_OLD_REV) max = @min(max, 0x7FFF_FFFF);
        return max;
    }

    pub fn now(self: *Fs) u32 {
        const f = self.now_fn orelse return 0;
        const t = f();
        if (t <= 0) return 0;
        return @truncate(@as(u64, @intCast(t)));
    }

    fn checkWritable(self: *Fs) Error!void {
        if (self.read_only) return error.ReadOnly;
    }

    // -----------------------------------------------------------------------
    // Superblock / group descriptor accessors
    // -----------------------------------------------------------------------

    pub fn sbFreeBlocks(self: *const Fs) u32 {
        return get32(&self.sbraw, format.sb.free_blocks_count);
    }
    pub fn sbFreeInodes(self: *const Fs) u32 {
        return get32(&self.sbraw, format.sb.free_inodes_count);
    }
    fn sbAdd(self: *Fs, off: usize, delta: i32) void {
        const v: i64 = @as(i64, get32(&self.sbraw, off)) + delta;
        put32(&self.sbraw, off, @intCast(std.math.clamp(v, 0, std.math.maxInt(u32))));
        self.sb_dirty = true;
    }

    pub fn gdBlockBitmap(self: *const Fs, g: u32) u32 {
        return get32(self.gdt, g * format.GD_SIZE + format.gd.block_bitmap);
    }
    pub fn gdInodeBitmap(self: *const Fs, g: u32) u32 {
        return get32(self.gdt, g * format.GD_SIZE + format.gd.inode_bitmap);
    }
    pub fn gdInodeTable(self: *const Fs, g: u32) u32 {
        return get32(self.gdt, g * format.GD_SIZE + format.gd.inode_table);
    }
    pub fn gdFreeBlocks(self: *const Fs, g: u32) u16 {
        return get16(self.gdt, g * format.GD_SIZE + format.gd.free_blocks_count);
    }
    pub fn gdFreeInodes(self: *const Fs, g: u32) u16 {
        return get16(self.gdt, g * format.GD_SIZE + format.gd.free_inodes_count);
    }
    pub fn gdUsedDirs(self: *const Fs, g: u32) u16 {
        return get16(self.gdt, g * format.GD_SIZE + format.gd.used_dirs_count);
    }
    fn gdAdd(self: *Fs, g: u32, field: usize, delta: i32) void {
        const off = g * format.GD_SIZE + field;
        const v: i32 = @as(i32, get16(self.gdt, off)) + delta;
        put16(self.gdt, off, @intCast(std.math.clamp(v, 0, 0xFFFF)));
        self.gdt_dirty = true;
    }

    /// Number of blocks covered by group `g`.
    pub fn blocksInGroup(self: *const Fs, g: u32) u32 {
        if (g + 1 == self.groups) return self.blocks_count - self.first_data_block - g * self.blocks_per_group;
        return self.blocks_per_group;
    }

    pub fn groupFirstBlock(self: *const Fs, g: u32) u32 {
        return self.first_data_block + g * self.blocks_per_group;
    }

    pub fn getBlock(self: *Fs, blk: u32) Error!*Buf {
        if (blk >= self.blocks_count) return error.Corrupt;
        return self.cache.get(blk);
    }

    // -----------------------------------------------------------------------
    // Inode cache
    // -----------------------------------------------------------------------

    fn iunlink(self: *Fs, ci: *CInode) void {
        if (ci.prev) |p| p.next = ci.next else self.ihead = ci.next;
        if (ci.next) |n| n.prev = ci.prev else self.itail = ci.prev;
        ci.prev = null;
        ci.next = null;
    }

    fn ipushFront(self: *Fs, ci: *CInode) void {
        ci.prev = null;
        ci.next = self.ihead;
        if (self.ihead) |h| h.prev = ci;
        self.ihead = ci;
        if (self.itail == null) self.itail = ci;
    }

    const InodeLoc = struct { blk: u32, off: u32 };

    fn inodeLoc(self: *const Fs, ino: Ino) InodeLoc {
        const idx = ino - 1;
        const g = idx / self.inodes_per_group;
        const byte = @as(u64, idx % self.inodes_per_group) * self.inode_size;
        return .{
            .blk = self.gdInodeTable(g) + @as(u32, @intCast(byte / self.bs)),
            .off = @intCast(byte % self.bs),
        };
    }

    /// Get a pinned cached inode (any state). Pair with `iput`.
    pub fn iget(self: *Fs, ino: Ino) Error!*CInode {
        if (ino == 0 or ino > self.inodes_count) return error.NotFound;
        if (self.imap.get(ino)) |ci| {
            ci.pins += 1;
            if (self.ihead != ci) {
                self.iunlink(ci);
                self.ipushFront(ci);
            }
            return ci;
        }
        if (self.icount >= self.icap) try self.ievictOne();
        const ci: *CInode = if (self.ispare) |s| blk: {
            self.ispare = s.next;
            break :blk s;
        } else blk: {
            const n = try self.allocator.create(CInode);
            errdefer self.allocator.destroy(n);
            const raw = try self.allocator.alloc(u8, self.inode_size);
            n.* = .{ .ino = 0, .raw = raw, .i = .{} };
            break :blk n;
        };
        const loc = self.inodeLoc(ino);
        const b = self.getBlock(loc.blk) catch |e| {
            ci.next = self.ispare;
            self.ispare = ci;
            return e;
        };
        @memcpy(ci.raw, b.data[loc.off..][0..self.inode_size]);
        self.cache.release(b);
        ci.* = .{ .ino = ino, .raw = ci.raw, .i = Inode.decode(ci.raw), .pins = 1 };
        self.imap.put(self.allocator, ino, ci) catch {
            ci.next = self.ispare;
            self.ispare = ci;
            return error.OutOfMemory;
        };
        self.ipushFront(ci);
        self.icount += 1;
        return ci;
    }

    /// Like `iget` but fails with NotFound for unused inodes.
    pub fn igetLive(self: *Fs, ino: Ino) Error!*CInode {
        const ci = try self.iget(ino);
        if (ci.i.mode == 0 or (ci.i.links == 0 and ino != ROOT_INO and !self.holds.contains(ino))) {
            self.iput(ci);
            return error.NotFound;
        }
        return ci;
    }

    pub fn iput(self: *Fs, ci: *CInode) void {
        _ = self;
        std.debug.assert(ci.pins > 0);
        ci.pins -= 1;
    }

    fn iwrite(self: *Fs, ci: *CInode) Error!void {
        ci.i.encode(ci.raw);
        const loc = self.inodeLoc(ci.ino);
        const b = try self.getBlock(loc.blk);
        defer self.cache.release(b);
        @memcpy(b.data[loc.off..][0..self.inode_size], ci.raw);
        self.cache.markDirty(b);
        ci.dirty = false;
    }

    fn ievictOne(self: *Fs) Error!void {
        var it = self.itail;
        while (it) |ci| : (it = ci.prev) {
            if (ci.pins != 0) continue;
            if (ci.dirty) try self.iwrite(ci);
            self.dropIndex(ci);
            _ = self.imap.remove(ci.ino);
            self.iremovals += 1;
            if (self.iremovals > self.imap.capacity() / 2) {
                self.imap.rehash(std.hash_map.AutoContext(Ino){});
                self.iremovals = 0;
            }
            self.iunlink(ci);
            self.icount -= 1;
            ci.next = self.ispare;
            self.ispare = ci;
            return;
        }
    }

    fn iflushAll(self: *Fs) Error!void {
        var it = self.ihead;
        while (it) |ci| : (it = ci.next) {
            if (ci.dirty) try self.iwrite(ci);
        }
    }

    // -----------------------------------------------------------------------
    // Bitmaps and allocation
    // -----------------------------------------------------------------------

    fn testBit(bm: []const u8, bit: u32) bool {
        return bm[bit >> 3] & (@as(u8, 1) << @intCast(bit & 7)) != 0;
    }
    fn setBit(bm: []u8, bit: u32) void {
        bm[bit >> 3] |= @as(u8, 1) << @intCast(bit & 7);
    }
    fn clearBit(bm: []u8, bit: u32) void {
        bm[bit >> 3] &= ~(@as(u8, 1) << @intCast(bit & 7));
    }

    /// First clear bit in [from, to).
    pub fn findZero(bm: []const u8, from: u32, to: u32) ?u32 {
        var i = from;
        while (i < to) {
            if (i & 63 == 0 and i + 64 <= to) {
                if (std.mem.readInt(u64, bm[i >> 3 ..][0..8], .little) == std.math.maxInt(u64)) {
                    i += 64;
                    continue;
                }
            }
            if (i & 7 == 0 and i + 8 <= to and bm[i >> 3] == 0xFF) {
                i += 8;
                continue;
            }
            if (!testBit(bm, i)) return i;
            i += 1;
        }
        return null;
    }

    fn allocBlock(self: *Fs, goal_in: u32) Error!u32 {
        if (self.sbFreeBlocks() == 0) return error.NoSpace;
        const fdb = self.first_data_block;
        const goal = if (goal_in >= fdb and goal_in < self.blocks_count) goal_in else fdb;
        const g0 = (goal - fdb) / self.blocks_per_group;
        var i: u32 = 0;
        while (i < self.groups) : (i += 1) {
            const g = (g0 + i) % self.groups;
            if (self.gdFreeBlocks(g) == 0) continue;
            const nbits = self.blocksInGroup(g);
            const b = try self.getBlock(self.gdBlockBitmap(g));
            defer self.cache.release(b);
            var found: ?u32 = null;
            const hint = @min(self.bb_hint[g], nbits);
            if (i == 0) {
                const start = (goal - fdb) - g * self.blocks_per_group;
                found = findZero(b.data, @max(start, hint), nbits);
                if (found != null and start <= hint) self.bb_hint[g] = found.? + 1;
                if (found == null and hint < start) {
                    found = findZero(b.data, hint, start);
                    if (found) |x| self.bb_hint[g] = x + 1;
                }
            } else {
                found = findZero(b.data, hint, nbits);
                if (found) |x| self.bb_hint[g] = x + 1;
            }
            if (found) |bit| {
                setBit(b.data, bit);
                self.cache.markDirty(b);
                self.gdAdd(g, format.gd.free_blocks_count, -1);
                self.sbAdd(format.sb.free_blocks_count, -1);
                return self.groupFirstBlock(g) + bit;
            }
            self.bb_hint[g] = nbits;
        }
        return error.NoSpace;
    }

    fn freeBlock(self: *Fs, blk: u32) Error!void {
        const fdb = self.first_data_block;
        if (blk < fdb or blk >= self.blocks_count) return error.Corrupt;
        const g = (blk - fdb) / self.blocks_per_group;
        const bit = (blk - fdb) % self.blocks_per_group;
        {
            const b = try self.getBlock(self.gdBlockBitmap(g));
            defer self.cache.release(b);
            if (!testBit(b.data, bit)) return error.Corrupt;
            clearBit(b.data, bit);
            self.cache.markDirty(b);
        }
        if (bit < self.bb_hint[g]) self.bb_hint[g] = bit;
        self.gdAdd(g, format.gd.free_blocks_count, 1);
        self.sbAdd(format.sb.free_blocks_count, 1);
        self.cache.discard(blk);
    }

    fn takeInodeInGroup(self: *Fs, g: u32, is_dir: bool) Error!?Ino {
        if (self.gdFreeInodes(g) == 0) return null;
        const b = try self.getBlock(self.gdInodeBitmap(g));
        defer self.cache.release(b);
        const base = g * self.inodes_per_group;
        var start: u32 = @min(self.ib_hint[g], self.inodes_per_group);
        if (base + 1 < self.first_ino) start = @max(start, @min(self.first_ino - 1 - base, self.inodes_per_group));
        const bit = findZero(b.data, start, self.inodes_per_group) orelse {
            self.ib_hint[g] = self.inodes_per_group;
            return null;
        };
        self.ib_hint[g] = bit + 1;
        const ino = base + bit + 1;
        if (ino > self.inodes_count) return null;
        setBit(b.data, bit);
        self.cache.markDirty(b);
        self.gdAdd(g, format.gd.free_inodes_count, -1);
        if (is_dir) self.gdAdd(g, format.gd.used_dirs_count, 1);
        self.sbAdd(format.sb.free_inodes_count, -1);
        return ino;
    }

    fn allocInode(self: *Fs, parent: Ino, is_dir: bool) Error!Ino {
        if (self.sbFreeInodes() == 0) return error.NoSpace;
        const ng = self.groups;
        const pg = (parent - 1) / self.inodes_per_group;
        if (is_dir) {
            // Spread directories: among groups with an above-average number
            // of free inodes, prefer the one with the most free blocks.
            const avg = self.sbFreeInodes() / ng;
            var best: ?u32 = null;
            var best_free: u32 = 0;
            var k: u32 = 0;
            while (k < ng) : (k += 1) {
                const g = (pg + k) % ng;
                const fi = self.gdFreeInodes(g);
                if (fi == 0 or fi < avg) continue;
                const fb = self.gdFreeBlocks(g);
                if (best == null or fb > best_free) {
                    best = g;
                    best_free = fb;
                }
            }
            if (best) |g| {
                if (try self.takeInodeInGroup(g, true)) |ino| return ino;
            }
        } else {
            // Files: parent's group, then quadratic probing, then linear.
            if (self.gdFreeBlocks(pg) > 0) {
                if (try self.takeInodeInGroup(pg, false)) |ino| return ino;
            }
            var j: u32 = 1;
            while (j < ng) : (j <<= 1) {
                const g = (pg + j) % ng;
                if (self.gdFreeBlocks(g) == 0) continue;
                if (try self.takeInodeInGroup(g, false)) |ino| return ino;
            }
        }
        var k: u32 = 0;
        while (k < ng) : (k += 1) {
            if (try self.takeInodeInGroup((pg + k) % ng, is_dir)) |ino| return ino;
        }
        return error.NoSpace;
    }

    fn freeInodeBit(self: *Fs, ino: Ino, was_dir: bool) Error!void {
        const g = (ino - 1) / self.inodes_per_group;
        const bit = (ino - 1) % self.inodes_per_group;
        const b = try self.getBlock(self.gdInodeBitmap(g));
        defer self.cache.release(b);
        if (!testBit(b.data, bit)) return error.Corrupt;
        clearBit(b.data, bit);
        self.cache.markDirty(b);
        if (bit < self.ib_hint[g]) self.ib_hint[g] = bit;
        self.gdAdd(g, format.gd.free_inodes_count, 1);
        if (was_dir) self.gdAdd(g, format.gd.used_dirs_count, -1);
        self.sbAdd(format.sb.free_inodes_count, 1);
    }

    /// Allocate and initialize a fresh inode. Returned pinned.
    fn newInode(self: *Fs, parent: Ino, mode: u16, uid: u32, gid: u32) Error!*CInode {
        const ino = try self.allocInode(parent, format.isDir(mode));
        errdefer self.freeInodeBit(ino, format.isDir(mode)) catch {};
        const ci = try self.iget(ino);
        const t = self.now();
        @memset(ci.raw, 0);
        if (self.inode_size > format.GOOD_OLD_INODE_SIZE) {
            const extra: u16 = @intCast(@min(format.DEFAULT_EXTRA_ISIZE, self.inode_size - format.GOOD_OLD_INODE_SIZE));
            put16(ci.raw, format.ino.extra_isize, extra);
            if (extra >= format.ino.crtime + 4 - format.GOOD_OLD_INODE_SIZE) put32(ci.raw, format.ino.crtime, t);
        }
        self.next_generation +%= 1;
        ci.i = .{
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .atime = t,
            .ctime = t,
            .mtime = t,
            .links = 1,
            .generation = self.next_generation,
        };
        ci.last_alloc = 0;
        ci.dir_hint = 0;
        ci.dir_full_upto = 0;
        self.dropIndex(ci);
        ci.dindex_failed = false;
        ci.dirty = true;
        return ci;
    }

    // -----------------------------------------------------------------------
    // Block mapping
    // -----------------------------------------------------------------------

    fn blockPath(self: *const Fs, lblk: u64) Error!BlockPath {
        const p: u64 = self.ptrs;
        var l = lblk;
        if (l < format.NDIR_BLOCKS) return .{ .depth = 0, .idx = .{ @intCast(l), 0, 0, 0 } };
        l -= format.NDIR_BLOCKS;
        if (l < p) return .{ .depth = 1, .idx = .{ format.IND_BLOCK, @intCast(l), 0, 0 } };
        l -= p;
        if (l < p * p) return .{ .depth = 2, .idx = .{ format.DIND_BLOCK, @intCast(l / p), @intCast(l % p), 0 } };
        l -= p * p;
        if (l < p * p * p) return .{ .depth = 3, .idx = .{
            format.TIND_BLOCK,
            @intCast(l / (p * p)),
            @intCast((l / p) % p),
            @intCast(l % p),
        } };
        return error.FileTooBig;
    }

    fn checkDataBlock(self: *const Fs, blk: u32) Error!u32 {
        if (blk != 0 and (blk < self.first_data_block or blk >= self.blocks_count)) return error.Corrupt;
        return blk;
    }

    /// Physical block for logical block `lblk`, 0 for a hole.
    pub fn bmap(self: *Fs, ci: *CInode, lblk: u64) Error!u32 {
        const path = self.blockPath(lblk) catch return 0;
        var blk = try self.checkDataBlock(ci.i.block[path.idx[0]]);
        var level: u8 = 1;
        while (level <= path.depth) : (level += 1) {
            if (blk == 0) return 0;
            const b = try self.getBlock(blk);
            defer self.cache.release(b);
            blk = try self.checkDataBlock(get32(b.data, path.idx[level] * 4));
        }
        return blk;
    }

    fn allocGoal(self: *Fs, ci: *CInode, lblk: u64) u32 {
        if (ci.last_alloc != 0) return ci.last_alloc +% 1;
        if (lblk > 0) {
            const prev = self.bmap(ci, lblk - 1) catch 0;
            if (prev != 0) return prev + 1;
        }
        const g = (ci.ino - 1) / self.inodes_per_group;
        return self.groupFirstBlock(g);
    }

    fn allocFor(self: *Fs, ci: *CInode, goal: u32) Error!u32 {
        if (@as(u64, ci.i.blocks) + self.spb > std.math.maxInt(u32)) return error.FileTooBig;
        const blk = try self.allocBlock(goal);
        ci.i.blocks += self.spb;
        ci.last_alloc = blk;
        ci.dirty = true;
        return blk;
    }

    /// Map `lblk`, allocating the data block and any missing indirect
    /// blocks. `fresh` reports whether the data block was newly allocated
    /// (its contents are then undefined and must be fully initialized).
    fn bmapAlloc(self: *Fs, ci: *CInode, lblk: u64, fresh: *bool) Error!u32 {
        const path = try self.blockPath(lblk);
        fresh.* = false;
        var goal = self.allocGoal(ci, lblk);
        var blk = try self.checkDataBlock(ci.i.block[path.idx[0]]);
        if (blk == 0) {
            blk = try self.allocFor(ci, goal);
            ci.i.block[path.idx[0]] = blk;
            ci.dirty = true;
            if (path.depth == 0) {
                fresh.* = true;
                return blk;
            }
            const nb = try self.cache.getZeroed(blk);
            self.cache.release(nb);
            goal = blk + 1;
        }
        var level: u8 = 1;
        while (level <= path.depth) : (level += 1) {
            const b = try self.getBlock(blk);
            defer self.cache.release(b);
            var child = try self.checkDataBlock(get32(b.data, path.idx[level] * 4));
            if (child == 0) {
                child = try self.allocFor(ci, goal);
                put32(b.data, path.idx[level] * 4, child);
                self.cache.markDirty(b);
                if (level == path.depth) {
                    fresh.* = true;
                } else {
                    const nb = try self.cache.getZeroed(child);
                    self.cache.release(nb);
                }
                goal = child + 1;
            }
            blk = child;
        }
        return blk;
    }

    fn freeData(self: *Fs, ci: *CInode, blk: u32) Error!void {
        try self.freeBlock(blk);
        ci.i.blocks -|= self.spb;
        ci.dirty = true;
    }

    fn freeSubtree(self: *Fs, ci: *CInode, blk: u32, level: u32) Error!void {
        if (level > 0) {
            const b = try self.getBlock(blk);
            var k: u32 = 0;
            while (k < self.ptrs) : (k += 1) {
                const child = get32(b.data, k * 4);
                if (child == 0) continue;
                self.freeSubtree(ci, child, level - 1) catch |e| {
                    self.cache.release(b);
                    return e;
                };
            }
            self.cache.release(b);
        }
        try self.freeData(ci, blk);
    }

    fn truncTree(self: *Fs, ci: *CInode, slot: *u32, level: u32, base: u64, cover: u64, keep: u64) Error!void {
        if (slot.* == 0) return;
        if (keep >= base + cover) return;
        if (keep <= base) {
            try self.freeSubtree(ci, slot.*, level);
            slot.* = 0;
            ci.dirty = true;
            return;
        }
        const child_cover = cover / self.ptrs;
        const b = try self.getBlock(slot.*);
        var released = false;
        defer if (!released) self.cache.release(b);
        var k: u32 = @intCast((keep - base) / child_cover);
        while (k < self.ptrs) : (k += 1) {
            var child = get32(b.data, k * 4);
            if (child == 0) continue;
            try self.truncTree(ci, &child, level - 1, base + k * child_cover, child_cover, keep);
            put32(b.data, k * 4, child);
            self.cache.markDirty(b);
        }
        if (std.mem.allEqual(u8, b.data, 0)) {
            self.cache.release(b);
            released = true;
            try self.freeData(ci, slot.*);
            slot.* = 0;
            ci.dirty = true;
        }
    }

    /// Free every data/indirect block at logical index >= keep.
    fn freeBlocksFrom(self: *Fs, ci: *CInode, keep: u64) Error!void {
        var k: usize = @intCast(@min(keep, format.NDIR_BLOCKS));
        while (k < format.NDIR_BLOCKS) : (k += 1) {
            if (ci.i.block[k] != 0) {
                try self.freeData(ci, ci.i.block[k]);
                ci.i.block[k] = 0;
            }
        }
        var base: u64 = format.NDIR_BLOCKS;
        var cover: u64 = self.ptrs;
        var level: u32 = 1;
        while (level <= 3) : (level += 1) {
            try self.truncTree(ci, &ci.i.block[format.NDIR_BLOCKS - 1 + level], level, base, cover, keep);
            base += cover;
            cover *= self.ptrs;
        }
        ci.dirty = true;
    }

    fn eaBlocks(self: *const Fs, i: *const Inode) u32 {
        return if (i.file_acl != 0) self.spb else 0;
    }

    pub fn isFastSymlink(self: *const Fs, i: *const Inode) bool {
        return format.isLnk(i.mode) and i.blocks -| self.eaBlocks(i) == 0;
    }

    /// Whether i_block holds a block map (as opposed to device numbers or
    /// an inline symlink target).
    pub fn hasBlockMap(self: *const Fs, i: *const Inode) bool {
        return switch (i.mode & format.S_IFMT) {
            format.S_IFREG, format.S_IFDIR => true,
            format.S_IFLNK => !self.isFastSymlink(i),
            else => false,
        };
    }

    fn releaseEaBlock(self: *Fs, ci: *CInode) Error!void {
        const blk = ci.i.file_acl;
        ci.i.file_acl = 0;
        ci.dirty = true;
        if (blk < self.first_data_block or blk >= self.blocks_count) return;
        ci.i.blocks -|= self.spb;
        const b = try self.getBlock(blk);
        if (get32(b.data, 0) != format.EA_MAGIC) {
            self.cache.release(b);
            return;
        }
        const refs = get32(b.data, format.EA_REFCOUNT_OFFSET);
        if (refs <= 1) {
            self.cache.release(b);
            try self.freeBlock(blk);
        } else {
            put32(b.data, format.EA_REFCOUNT_OFFSET, refs - 1);
            self.cache.markDirty(b);
            self.cache.release(b);
        }
    }

    /// Release all storage of an inode whose link count dropped to zero.
    fn destroyInode(self: *Fs, ci: *CInode) Error!void {
        const was_dir = format.isDir(ci.i.mode);
        self.dropIndex(ci);
        if (ci.i.flags & (format.FL_EXTENTS | format.FL_INLINE_DATA) != 0) return error.Unsupported;
        if (self.hasBlockMap(&ci.i)) try self.freeBlocksFrom(ci, 0);
        if (ci.i.file_acl != 0) try self.releaseEaBlock(ci);
        ci.i.links = 0;
        ci.i.size = 0;
        ci.i.blocks = 0;
        ci.i.block = [_]u32{0} ** format.N_BLOCKS;
        ci.i.dtime = self.now();
        ci.dirty = true;
        try self.freeInodeBit(ci.ino, was_dir);
    }

    /// The last link of `ci` is gone: free it now, or on the final
    /// `release` if it is still held open.
    fn dropInode(self: *Fs, ci: *CInode) Error!void {
        if (self.holds.contains(ci.ino)) return;
        try self.destroyInode(ci);
    }

    /// Keep inode `ino` alive while it is in use (e.g. an open file): if
    /// its last link is removed meanwhile, its data stays readable and
    /// writable and its storage is freed on the matching final `release`.
    pub fn retain(self: *Fs, ino: Ino) Error!void {
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        const gop = try self.holds.getOrPut(self.allocator, ino);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    /// Drop a hold taken with `retain`.
    pub fn release(self: *Fs, ino: Ino) Error!void {
        const count = self.holds.getPtr(ino) orelse return error.InvalidArgument;
        count.* -= 1;
        if (count.* != 0) return;
        _ = self.holds.remove(ino);
        if (self.read_only) return;
        const ci = try self.iget(ino);
        defer self.iput(ci);
        if (ci.i.links == 0 and ci.i.mode != 0 and ino != ROOT_INO) try self.destroyInode(ci);
    }

    /// Release every hold (done at unmount).
    fn releaseAll(self: *Fs) Error!void {
        while (self.holds.count() > 0) {
            var it = self.holds.iterator();
            const e = it.next().?;
            e.value_ptr.* = 1;
            try self.release(e.key_ptr.*);
        }
    }

    fn ensureLargeFile(self: *Fs, size: u64) Error!void {
        if (size <= 0x7FFF_FFFF) return;
        if (self.ro_compat & format.RO_COMPAT_LARGE_FILE != 0) return;
        if (self.rev == format.GOOD_OLD_REV) return error.FileTooBig;
        self.ro_compat |= format.RO_COMPAT_LARGE_FILE;
        put32(&self.sbraw, format.sb.feature_ro_compat, self.ro_compat);
        self.sb_dirty = true;
    }

    /// Change the size of a regular file, freeing blocks past the end and
    /// zeroing the tail of the last partial block.
    fn setSize(self: *Fs, ci: *CInode, new_size: u64) Error!void {
        const bs = self.bs;
        const old = ci.i.size;
        if (new_size < old) {
            const keep = std.math.divCeil(u64, new_size, bs) catch unreachable;
            try self.freeBlocksFrom(ci, keep);
            if (new_size % bs != 0) try self.zeroTail(ci, new_size);
        } else if (new_size > old and old % bs != 0) {
            try self.zeroTail(ci, old);
        }
        try self.ensureLargeFile(new_size);
        ci.i.size = new_size;
        ci.dirty = true;
    }

    fn zeroTail(self: *Fs, ci: *CInode, pos: u64) Error!void {
        const pblk = try self.bmap(ci, pos / self.bs);
        if (pblk == 0) return;
        const b = try self.getBlock(pblk);
        defer self.cache.release(b);
        const off: usize = @intCast(pos % self.bs);
        if (!std.mem.allEqual(u8, b.data[off..], 0)) {
            @memset(b.data[off..], 0);
            self.cache.markDirty(b);
        }
    }

    // -----------------------------------------------------------------------
    // Directory primitives
    // -----------------------------------------------------------------------

    fn dirBlocks(self: *const Fs, dci: *const CInode) u32 {
        return @intCast((dci.i.size & 0xFFFF_FFFF) / self.bs);
    }

    fn dropIndex(self: *Fs, ci: *CInode) void {
        if (ci.dindex) |d| {
            d.map.deinit(self.allocator);
            self.allocator.destroy(d);
            ci.dindex = null;
        }
    }

    /// Build the in-memory name index of a large directory (best effort).
    fn buildIndex(self: *Fs, dci: *CInode) Error!void {
        const d = try self.allocator.create(DirIndex);
        d.* = .{};
        var ok = false;
        defer if (!ok) {
            d.map.deinit(self.allocator);
            self.allocator.destroy(d);
            dci.dindex_failed = true;
        };
        const n = self.dirBlocks(dci);
        var lblk: u32 = 0;
        while (lblk < n) : (lblk += 1) {
            const pblk = try self.bmap(dci, lblk);
            if (pblk == 0) continue;
            const b = try self.getBlock(pblk);
            defer self.cache.release(b);
            var off: u32 = 0;
            while (off < self.bs) {
                const e = try dirent.parse(b.data, off, self.has_filetype);
                off += e.rec_len;
                if (e.inode == 0) continue;
                const gop = try d.map.getOrPut(self.allocator, nameHash(e.name));
                if (gop.found_existing) return; // collision (or duplicate): stay linear
                gop.value_ptr.* = lblk;
            }
        }
        ok = true;
        dci.dindex = d;
    }

    fn dirFindInBlock(self: *Fs, dci: *CInode, lblk: u32, name: []const u8, h: u64) Error!?Found {
        const pblk = try self.bmap(dci, lblk);
        if (pblk == 0) return null;
        const b = try self.getBlock(pblk);
        defer self.cache.release(b);
        var off: u32 = 0;
        var prev: ?u32 = null;
        while (off < self.bs) {
            const e = try dirent.parse(b.data, off, self.has_filetype);
            if (e.inode != 0 and e.name_len == name.len and std.mem.eql(u8, e.name, name)) {
                if (e.inode > self.inodes_count) return error.Corrupt;
                return .{ .ino = e.inode, .file_type = e.file_type, .lblk = lblk, .off = off, .prev_off = prev, .name_hash = h };
            }
            prev = off;
            off += e.rec_len;
        }
        return null;
    }

    fn dirFind(self: *Fs, dci: *CInode, name: []const u8) Error!?Found {
        const n = self.dirBlocks(dci);
        const h = nameHash(name);
        if (dci.dindex == null and !dci.dindex_failed and self.dir_index_min_blocks != 0 and n >= self.dir_index_min_blocks) {
            self.buildIndex(dci) catch |e| switch (e) {
                error.OutOfMemory => {},
                else => return e,
            };
        }
        if (dci.dindex) |d| {
            const lblk = d.map.get(h) orelse return null;
            if (try self.dirFindInBlock(dci, lblk, name, h)) |f| return f;
            self.dropIndex(dci); // stale: fall back to a linear scan
        }
        var lblk: u32 = 0;
        while (lblk < n) : (lblk += 1) {
            if (try self.dirFindInBlock(dci, lblk, name, h)) |f| return f;
        }
        return null;
    }

    fn indexAdd(self: *Fs, dci: *CInode, name: []const u8, lblk: u32) void {
        const d = dci.dindex orelse return;
        const gop = d.map.getOrPut(self.allocator, nameHash(name)) catch {
            self.dropIndex(dci);
            return;
        };
        if (gop.found_existing) {
            self.dropIndex(dci);
            dci.dindex_failed = true;
            return;
        }
        gop.value_ptr.* = lblk;
    }

    fn touchDir(self: *Fs, dci: *CInode) void {
        const t = self.now();
        dci.i.mtime = t;
        dci.i.ctime = t;
        // We maintain directories linearly; any htree index is now stale.
        dci.i.flags &= ~format.FL_INDEX;
        dci.dirty = true;
    }

    fn dtype(self: *const Fs, mode: u16) u8 {
        return if (self.has_filetype) format.fileTypeFromMode(mode) else 0;
    }

    fn dirAdd(self: *Fs, dci: *CInode, name: []const u8, ino: Ino, mode: u16) Error!void {
        const ft = self.dtype(mode);
        const n = self.dirBlocks(dci);
        const need = dirent.recLen(name.len);
        // Leading blocks known to be too full for this record are skipped;
        // the rest is searched starting at the block of the previous
        // insertion, wrapping around.
        const skip = if (dci.dir_full_upto != 0 and need >= dci.dir_full_need) @min(dci.dir_full_upto, n) else 0;
        const span = n - skip;
        const start = if (dci.dir_hint >= skip and dci.dir_hint < n) dci.dir_hint - skip else 0;
        var k: u32 = 0;
        while (k < span) : (k += 1) {
            const lblk = skip + (start + k) % span;
            const pblk = try self.bmap(dci, lblk);
            if (pblk == 0) continue;
            const b = try self.getBlock(pblk);
            defer self.cache.release(b);
            if (try dirent.insert(b.data, name, ino, ft, self.has_filetype)) {
                self.cache.markDirty(b);
                self.touchDir(dci);
                dci.dir_hint = lblk;
                self.indexAdd(dci, name, lblk);
                return;
            }
        }
        // No existing block has room for `need` bytes.
        // (when skip > 0, need >= dir_full_need, so this only widens the claim)
        dci.dir_full_need = need;
        dci.dir_full_upto = n;
        if (dci.i.size + self.bs > std.math.maxInt(u32)) return error.NoSpace;
        var fresh = false;
        const pblk = try self.bmapAlloc(dci, n, &fresh);
        const b = try self.cache.getZeroed(pblk);
        defer self.cache.release(b);
        dirent.initEmpty(b.data);
        _ = try dirent.insert(b.data, name, ino, ft, self.has_filetype);
        self.cache.markDirty(b);
        dci.i.size += self.bs;
        dci.dir_hint = n;
        self.touchDir(dci);
        self.indexAdd(dci, name, n);
    }

    fn dirRemove(self: *Fs, dci: *CInode, f: Found) Error!void {
        const pblk = try self.bmap(dci, f.lblk);
        if (pblk == 0) return error.Corrupt;
        const b = try self.getBlock(pblk);
        defer self.cache.release(b);
        try dirent.remove(b.data, f.off, f.prev_off, self.has_filetype);
        self.cache.markDirty(b);
        self.touchDir(dci);
        dci.dir_full_upto = 0;
        if (dci.dindex) |d| d.remove(f.name_hash);
    }

    fn dirSetEntry(self: *Fs, dci: *CInode, f: Found, ino: Ino, mode: u16, touch: bool) Error!void {
        const pblk = try self.bmap(dci, f.lblk);
        if (pblk == 0) return error.Corrupt;
        const b = try self.getBlock(pblk);
        defer self.cache.release(b);
        dirent.setInode(b.data, f.off, ino, self.dtype(mode), self.has_filetype);
        self.cache.markDirty(b);
        if (touch) self.touchDir(dci);
    }

    fn dirIsEmpty(self: *Fs, dci: *CInode) Error!bool {
        const n = self.dirBlocks(dci);
        var lblk: u32 = 0;
        while (lblk < n) : (lblk += 1) {
            const pblk = try self.bmap(dci, lblk);
            if (pblk == 0) continue;
            const b = try self.getBlock(pblk);
            defer self.cache.release(b);
            var off: u32 = 0;
            while (off < self.bs) {
                const e = try dirent.parse(b.data, off, self.has_filetype);
                if (e.inode != 0 and !isDotOrDotDot(e.name)) return false;
                off += e.rec_len;
            }
        }
        return true;
    }

    fn isDotOrDotDot(name: []const u8) bool {
        return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
    }

    fn validateName(name: []const u8) Error!void {
        if (name.len == 0) return error.InvalidArgument;
        if (name.len > format.NAME_MAX) return error.NameTooLong;
        if (std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidArgument;
    }

    fn validateNewName(name: []const u8) Error!void {
        try validateName(name);
        if (isDotOrDotDot(name)) return error.Exists;
    }

    fn getDirLive(self: *Fs, ino: Ino) Error!*CInode {
        const ci = try self.igetLive(ino);
        if (!format.isDir(ci.i.mode)) {
            self.iput(ci);
            return error.NotDir;
        }
        if (ci.i.links == 0) {
            // removed directory still held open
            self.iput(ci);
            return error.NotFound;
        }
        return ci;
    }

    // -----------------------------------------------------------------------
    // Lookup and path resolution
    // -----------------------------------------------------------------------

    /// Look up a single name in a directory (no symlink following).
    pub fn lookupChild(self: *Fs, dir_ino: Ino, name: []const u8) Error!Ino {
        if (name.len == 0) return error.NotFound;
        if (name.len > format.NAME_MAX) return error.NameTooLong;
        const dci = try self.getDirLive(dir_ino);
        defer self.iput(dci);
        const f = (try self.dirFind(dci, name)) orelse return error.NotFound;
        return f.ino;
    }

    /// Resolve an absolute path, following all symlinks.
    pub fn lookup(self: *Fs, path: []const u8) Error!Ino {
        return self.resolve(ROOT_INO, path, true);
    }

    /// Resolve an absolute path without following a final symlink (lstat).
    pub fn lookupNoFollow(self: *Fs, path: []const u8) Error!Ino {
        return self.resolve(ROOT_INO, path, false);
    }

    /// Resolve `path` relative to directory `start` (absolute paths start at
    /// the root). Symlinks in intermediate components are always followed;
    /// the last component is followed if `follow_last` or if the path ends
    /// with a slash. At most 40 symlinks are followed.
    pub fn resolve(self: *Fs, start: Ino, path: []const u8, follow_last: bool) Error!Ino {
        if (path.len == 0) return error.NotFound;
        var owned: ?[]u8 = null;
        defer if (owned) |o| self.allocator.free(o);
        var p: []const u8 = path;
        var cur: Ino = if (path[0] == '/') ROOT_INO else start;
        var hops: u32 = 0;
        var i: usize = 0;
        var link_buf: [format.PATH_MAX]u8 = undefined;
        {
            // make sure the start is a live directory
            const d = try self.getDirLive(cur);
            self.iput(d);
        }
        while (true) {
            while (i < p.len and p[i] == '/') i += 1;
            if (i >= p.len) return cur;
            var j = i;
            while (j < p.len and p[j] != '/') j += 1;
            const comp = p[i..j];
            var k = j;
            while (k < p.len and p[k] == '/') k += 1;
            const is_last = k >= p.len;
            const trailing_slash = j < p.len;
            i = j;
            if (comp.len > format.NAME_MAX) return error.NameTooLong;
            if (std.mem.eql(u8, comp, ".")) continue;

            const child = try self.lookupChild(cur, comp);
            const cci = try self.igetLive(child);
            const mode = cci.i.mode;
            if (format.isLnk(mode) and (!is_last or follow_last or trailing_slash)) {
                hops += 1;
                if (hops > format.MAX_SYMLINK_HOPS) {
                    self.iput(cci);
                    return error.Loop;
                }
                const target = self.readlinkInode(cci, &link_buf) catch |e| {
                    self.iput(cci);
                    return e;
                };
                self.iput(cci);
                if (target.len == 0) return error.NotFound;
                const rest = p[i..];
                const new_len = target.len + rest.len;
                if (new_len > 4 * format.PATH_MAX) return error.NameTooLong;
                const np = try self.allocator.alloc(u8, new_len);
                @memcpy(np[0..target.len], target);
                @memcpy(np[target.len..], rest);
                if (owned) |o| self.allocator.free(o);
                owned = np;
                p = np;
                i = 0;
                if (target[0] == '/') cur = ROOT_INO;
                continue;
            }
            self.iput(cci);
            if (!is_last or trailing_slash) {
                if (!format.isDir(mode)) return error.NotDir;
            }
            if (is_last) return child;
            cur = child;
        }
    }

    /// Split `path` into its parent directory (resolved, following
    /// symlinks) and final component name. Fails with InvalidArgument for
    /// paths without a final component (such as "/").
    pub fn resolveParent(self: *Fs, start: Ino, path: []const u8) Error!ParentAndName {
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;
        if (end == 0) return error.InvalidArgument;
        var s = end;
        while (s > 0 and path[s - 1] != '/') s -= 1;
        const name = path[s..end];
        if (name.len > format.NAME_MAX) return error.NameTooLong;
        const dir_part = path[0..s];
        const dir = if (dir_part.len == 0) blk: {
            const d = try self.getDirLive(start);
            self.iput(d);
            break :blk start;
        } else try self.resolve(start, dir_part, true);
        const d = try self.getDirLive(dir);
        self.iput(d);
        return .{ .dir = dir, .name = name };
    }

    // -----------------------------------------------------------------------
    // Public inode operations
    // -----------------------------------------------------------------------

    pub fn stat(self: *Fs, ino: Ino) Error!Stat {
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        const i = &ci.i;
        var blocks: u64 = i.blocks;
        if (self.ro_compat & format.RO_COMPAT_HUGE_FILE != 0) {
            blocks |= @as(u64, get16(ci.raw, format.ino.blocks_hi)) << 32;
            if (i.flags & format.FL_HUGE_FILE != 0) blocks *= self.spb;
        }
        var rdev: Dev = .{};
        const fmt_bits = i.mode & format.S_IFMT;
        if (fmt_bits == format.S_IFCHR or fmt_bits == format.S_IFBLK) rdev = decodeDev(i);
        return .{
            .ino = ino,
            .kind = FileType.fromMode(i.mode),
            .mode = i.mode,
            .nlink = i.links,
            .uid = i.uid,
            .gid = i.gid,
            .size = if (format.isDir(i.mode)) i.size & 0xFFFF_FFFF else i.size,
            .blocks = blocks,
            .blksize = self.bs,
            .atime = @as(i32, @bitCast(i.atime)),
            .mtime = @as(i32, @bitCast(i.mtime)),
            .ctime = @as(i32, @bitCast(i.ctime)),
            .rdev = rdev,
            .flags = i.flags,
            .generation = i.generation,
        };
    }

    fn decodeDev(i: *const Inode) Dev {
        if (i.block[0] != 0) {
            const v = i.block[0];
            return .{ .major = (v >> 8) & 0xFF, .minor = v & 0xFF };
        }
        const v = i.block[1];
        return .{ .major = (v & 0xFFF00) >> 8, .minor = (v & 0xFF) | ((v >> 12) & 0xFFF00) };
    }

    fn encodeDev(i: *Inode, dev: Dev) void {
        if (dev.major < 256 and dev.minor < 256) {
            i.block[0] = (dev.major << 8) | dev.minor;
            i.block[1] = 0;
        } else {
            i.block[0] = 0;
            i.block[1] = (dev.minor & 0xFF) | ((dev.major & 0xFFF) << 8) | ((dev.minor & ~@as(u32, 0xFF)) << 12);
            i.block[2] = 0;
        }
    }

    pub fn statfs(self: *Fs) StatFs {
        var label: [16]u8 = undefined;
        @memcpy(&label, self.sbraw[format.sb.volume_name..][0..16]);
        var uuid: [16]u8 = undefined;
        @memcpy(&uuid, self.sbraw[format.sb.uuid..][0..16]);
        const free = self.sbFreeBlocks();
        const reserved = get32(&self.sbraw, format.sb.r_blocks_count);
        return .{
            .block_size = self.bs,
            .total_blocks = self.blocks_count,
            .free_blocks = free,
            .avail_blocks = free -| reserved,
            .total_inodes = self.inodes_count,
            .free_inodes = self.sbFreeInodes(),
            .name_max = format.NAME_MAX,
            .uuid = uuid,
            .label = label,
        };
    }

    /// Read up to `buf.len` bytes at `offset`. Returns the number of bytes
    /// read (0 at or past end of file). Holes read as zeros.
    pub fn read(self: *Fs, ino: Ino, offset: u64, buf: []u8) Error!usize {
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        switch (ci.i.mode & format.S_IFMT) {
            format.S_IFREG => {},
            format.S_IFDIR => return error.IsDir,
            else => return error.InvalidArgument,
        }
        if (ci.i.flags & (format.FL_EXTENTS | format.FL_INLINE_DATA) != 0) return error.Unsupported;
        const size = ci.i.size;
        if (offset >= size or buf.len == 0) return 0;
        const len: usize = @intCast(@min(@as(u64, buf.len), size - offset));
        const bs = self.bs;
        var done: usize = 0;
        var run_pblk: u32 = 0;
        var run_len: u32 = 0;
        var run_start: usize = 0;
        while (done < len) {
            const pos = offset + done;
            const lblk = pos / bs;
            const boff: usize = @intCast(pos % bs);
            const n = @min(bs - boff, len - done);
            const pblk = try self.bmap(ci, lblk);
            if (n == bs and pblk != 0 and self.cache.peek(pblk) == null) {
                if (run_len > 0 and pblk == run_pblk + run_len and run_start + run_len * bs == done and run_len < max_io_run) {
                    run_len += 1;
                } else {
                    if (run_len > 0) try self.dev.read(@as(u64, run_pblk) * bs, buf[run_start..][0 .. run_len * bs]);
                    run_pblk = pblk;
                    run_len = 1;
                    run_start = done;
                }
            } else if (pblk == 0) {
                @memset(buf[done..][0..n], 0);
            } else {
                const b = try self.getBlock(pblk);
                defer self.cache.release(b);
                @memcpy(buf[done..][0..n], b.data[boff..][0..n]);
            }
            done += n;
        }
        if (run_len > 0) try self.dev.read(@as(u64, run_pblk) * bs, buf[run_start..][0 .. run_len * bs]);
        return len;
    }

    /// Write `data` at `offset`, allocating blocks as needed and growing
    /// the file. Returns the number of bytes written (short only if the
    /// filesystem fills up part-way).
    pub fn write(self: *Fs, ino: Ino, offset: u64, data: []const u8) Error!usize {
        try self.checkWritable();
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        switch (ci.i.mode & format.S_IFMT) {
            format.S_IFREG => {},
            format.S_IFDIR => return error.IsDir,
            else => return error.InvalidArgument,
        }
        if (ci.i.flags & (format.FL_EXTENTS | format.FL_INLINE_DATA) != 0) return error.Unsupported;
        if (data.len == 0) return 0;
        const end = std.math.add(u64, offset, data.len) catch return error.FileTooBig;
        if (end > self.max_size) return error.FileTooBig;
        try self.ensureLargeFile(end);
        // Bytes between the old EOF and `offset` must read back as zeros.
        if (offset > ci.i.size and ci.i.size % self.bs != 0) try self.zeroTail(ci, ci.i.size);

        const bs = self.bs;
        var done: usize = 0;
        var run_pblk: u32 = 0;
        var run_len: u32 = 0;
        var run_start: usize = 0;
        var failure: ?Error = null;
        while (done < data.len) {
            const pos = offset + done;
            const lblk = pos / bs;
            const boff: usize = @intCast(pos % bs);
            const n = @min(bs - boff, data.len - done);
            var fresh = false;
            const pblk = self.bmapAlloc(ci, lblk, &fresh) catch |e| {
                failure = e;
                break;
            };
            if (n == bs) {
                if (self.cache.peek(pblk)) |cb| {
                    @memcpy(cb.data, data[done..][0..bs]);
                    self.cache.markDirty(cb);
                } else if (run_len > 0 and pblk == run_pblk + run_len and run_start + run_len * bs == done and run_len < max_io_run) {
                    run_len += 1;
                } else {
                    if (run_len > 0) {
                        self.dev.write(@as(u64, run_pblk) * bs, data[run_start..][0 .. run_len * bs]) catch {
                            failure = error.Io;
                            done = run_start;
                            run_len = 0;
                            break;
                        };
                    }
                    run_pblk = pblk;
                    run_len = 1;
                    run_start = done;
                }
            } else {
                const b = (if (fresh) self.cache.getZeroed(pblk) else self.getBlock(pblk)) catch |e| {
                    failure = e;
                    break;
                };
                defer self.cache.release(b);
                @memcpy(b.data[boff..][0..n], data[done..][0..n]);
                self.cache.markDirty(b);
            }
            done += n;
        }
        if (run_len > 0) {
            self.dev.write(@as(u64, run_pblk) * bs, data[run_start..][0 .. run_len * bs]) catch {
                failure = error.Io;
                done = run_start;
            };
        }
        if (done > 0) {
            if (offset + done > ci.i.size) ci.i.size = offset + done;
            const t = self.now();
            ci.i.mtime = t;
            ci.i.ctime = t;
            ci.dirty = true;
        }
        if (failure) |e| {
            // Give back blocks allocated past the (possibly unchanged) EOF.
            const keep = std.math.divCeil(u64, ci.i.size, bs) catch unreachable;
            self.freeBlocksFrom(ci, keep) catch {};
            if (done == 0 or e != error.NoSpace) return e;
        }
        return done;
    }

    /// Set the size of a regular file (shrinking frees blocks; growing
    /// creates a hole).
    pub fn truncate(self: *Fs, ino: Ino, size: u64) Error!void {
        try self.checkWritable();
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        switch (ci.i.mode & format.S_IFMT) {
            format.S_IFREG => {},
            format.S_IFDIR => return error.IsDir,
            else => return error.InvalidArgument,
        }
        if (ci.i.flags & (format.FL_EXTENTS | format.FL_INLINE_DATA) != 0) return error.Unsupported;
        if (size > self.max_size) return error.FileTooBig;
        if (size != ci.i.size) try self.setSize(ci, size);
        const t = self.now();
        ci.i.mtime = t;
        ci.i.ctime = t;
        ci.dirty = true;
    }

    const NodeData = union(enum) {
        none,
        dir,
        symlink: []const u8,
        dev: Dev,
    };

    fn makeNode(self: *Fs, parent: Ino, name: []const u8, mode: u16, uid: u32, gid: u32, data: NodeData) Error!Ino {
        try self.checkWritable();
        try validateNewName(name);
        const pci = try self.getDirLive(parent);
        defer self.iput(pci);
        if (try self.dirFind(pci, name) != null) return error.Exists;
        const is_dir = format.isDir(mode);
        if (is_dir and pci.i.links >= format.LINK_MAX) return error.TooManyLinks;

        const ci = try self.newInode(parent, mode, uid, gid);
        defer self.iput(ci);
        errdefer self.destroyInode(ci) catch {};

        switch (data) {
            .none => {},
            .dir => {
                ci.i.links = 2;
                var fresh = false;
                const blk = try self.bmapAlloc(ci, 0, &fresh);
                const b = try self.cache.getZeroed(blk);
                dirent.initDirBlock(b.data, ci.ino, parent, self.has_filetype);
                self.cache.markDirty(b);
                self.cache.release(b);
                ci.i.size = self.bs;
            },
            .symlink => |target| {
                if (target.len <= format.FAST_SYMLINK_MAX) {
                    var bytes = [_]u8{0} ** (format.N_BLOCKS * 4);
                    @memcpy(bytes[0..target.len], target);
                    ci.i.setBlockBytes(&bytes);
                } else {
                    var fresh = false;
                    const blk = try self.bmapAlloc(ci, 0, &fresh);
                    const b = try self.cache.getZeroed(blk);
                    @memcpy(b.data[0..target.len], target);
                    self.cache.markDirty(b);
                    self.cache.release(b);
                }
                ci.i.size = target.len;
            },
            .dev => |d| encodeDev(&ci.i, d),
        }
        ci.dirty = true;

        try self.dirAdd(pci, name, ci.ino, mode);
        if (is_dir) {
            pci.i.links += 1;
            pci.dirty = true;
        }
        return ci.ino;
    }

    /// Create a regular file (fails with Exists if `name` exists).
    pub fn create(self: *Fs, parent: Ino, name: []const u8, mode: u16, uid: u32, gid: u32) Error!Ino {
        return self.makeNode(parent, name, format.S_IFREG | (mode & format.PERM_MASK), uid, gid, .none);
    }

    pub fn mkdir(self: *Fs, parent: Ino, name: []const u8, mode: u16, uid: u32, gid: u32) Error!Ino {
        return self.makeNode(parent, name, format.S_IFDIR | (mode & format.PERM_MASK), uid, gid, .dir);
    }

    /// Create a special file. `mode` must include the file type bits
    /// (S_IFCHR, S_IFBLK, S_IFIFO, S_IFSOCK or S_IFREG).
    pub fn mknod(self: *Fs, parent: Ino, name: []const u8, mode: u16, rdev: Dev, uid: u32, gid: u32) Error!Ino {
        const perm = mode & format.PERM_MASK;
        return switch (mode & format.S_IFMT) {
            format.S_IFCHR, format.S_IFBLK => self.makeNode(parent, name, mode, uid, gid, .{ .dev = rdev }),
            format.S_IFIFO, format.S_IFSOCK => self.makeNode(parent, name, mode, uid, gid, .none),
            0, format.S_IFREG => self.makeNode(parent, name, format.S_IFREG | perm, uid, gid, .none),
            else => error.InvalidArgument,
        };
    }

    pub fn symlink(self: *Fs, parent: Ino, name: []const u8, target: []const u8, uid: u32, gid: u32) Error!Ino {
        if (target.len == 0) return error.NotFound;
        if (target.len >= @min(self.bs, format.PATH_MAX)) return error.NameTooLong;
        if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidArgument;
        return self.makeNode(parent, name, format.S_IFLNK | 0o777, uid, gid, .{ .symlink = target });
    }

    fn readlinkInode(self: *Fs, ci: *CInode, buf: []u8) Error![]u8 {
        if (!format.isLnk(ci.i.mode)) return error.InvalidArgument;
        const size = ci.i.size;
        if (size >= format.PATH_MAX or size > self.bs) return error.Corrupt;
        const n: usize = @intCast(@min(size, buf.len));
        if (self.isFastSymlink(&ci.i)) {
            if (size > format.N_BLOCKS * 4) return error.Corrupt;
            const bytes = ci.i.blockBytes();
            @memcpy(buf[0..n], bytes[0..n]);
        } else {
            const pblk = try self.bmap(ci, 0);
            if (pblk == 0) return error.Corrupt;
            const b = try self.getBlock(pblk);
            defer self.cache.release(b);
            @memcpy(buf[0..n], b.data[0..n]);
        }
        return buf[0..n];
    }

    /// Read a symlink target into `buf` (truncated if `buf` is too small).
    pub fn readlink(self: *Fs, ino: Ino, buf: []u8) Error![]u8 {
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        return self.readlinkInode(ci, buf);
    }

    /// Create a hard link `new_parent/new_name` to `ino`.
    pub fn link(self: *Fs, ino: Ino, new_parent: Ino, new_name: []const u8) Error!void {
        try self.checkWritable();
        try validateNewName(new_name);
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        if (format.isDir(ci.i.mode)) return error.NotPermitted;
        if (ci.i.links >= format.LINK_MAX) return error.TooManyLinks;
        const pci = try self.getDirLive(new_parent);
        defer self.iput(pci);
        if (try self.dirFind(pci, new_name) != null) return error.Exists;
        try self.dirAdd(pci, new_name, ino, ci.i.mode);
        ci.i.links += 1;
        ci.i.ctime = self.now();
        ci.dirty = true;
    }

    /// Remove a non-directory entry; the inode is freed when its last link
    /// goes away.
    pub fn unlink(self: *Fs, parent: Ino, name: []const u8) Error!void {
        try self.checkWritable();
        try validateName(name);
        if (isDotOrDotDot(name)) return error.IsDir;
        const pci = try self.getDirLive(parent);
        defer self.iput(pci);
        const f = (try self.dirFind(pci, name)) orelse return error.NotFound;
        const ci = try self.igetLive(f.ino);
        defer self.iput(ci);
        if (format.isDir(ci.i.mode)) return error.IsDir;
        try self.dirRemove(pci, f);
        ci.i.links -|= 1;
        ci.i.ctime = self.now();
        ci.dirty = true;
        if (ci.i.links == 0) try self.dropInode(ci);
    }

    /// Remove an empty directory.
    pub fn rmdir(self: *Fs, parent: Ino, name: []const u8) Error!void {
        try self.checkWritable();
        try validateName(name);
        if (std.mem.eql(u8, name, ".")) return error.InvalidArgument;
        if (std.mem.eql(u8, name, "..")) return error.NotEmpty;
        const pci = try self.getDirLive(parent);
        defer self.iput(pci);
        const f = (try self.dirFind(pci, name)) orelse return error.NotFound;
        const ci = try self.igetLive(f.ino);
        defer self.iput(ci);
        if (!format.isDir(ci.i.mode)) return error.NotDir;
        if (f.ino == ROOT_INO) return error.Busy;
        if (!try self.dirIsEmpty(ci)) return error.NotEmpty;
        try self.dirRemove(pci, f);
        pci.i.links -|= 1;
        pci.dirty = true;
        ci.i.links = 0;
        ci.i.ctime = self.now();
        ci.dirty = true;
        try self.dropInode(ci);
    }

    /// Parent directory of a directory (via its ".." entry).
    fn parentOf(self: *Fs, dci: *CInode) Error!Ino {
        const f = (try self.dirFind(dci, "..")) orelse return error.Corrupt;
        return f.ino;
    }

    /// InvalidArgument if `dir` is `ancestor` or lies below it.
    fn checkNotAncestor(self: *Fs, ancestor: Ino, dir: Ino) Error!void {
        var cur = dir;
        var depth: u32 = 0;
        while (true) {
            if (cur == ancestor) return error.InvalidArgument;
            if (cur == ROOT_INO) return;
            depth += 1;
            if (depth > 65536) return error.Corrupt;
            const ci = try self.getDirLive(cur);
            defer self.iput(ci);
            cur = try self.parentOf(ci);
        }
    }

    /// Rename `old_parent/old_name` to `new_parent/new_name`, atomically
    /// replacing an existing target (a directory may only replace an empty
    /// directory; a non-directory only a non-directory).
    pub fn rename(self: *Fs, old_parent: Ino, old_name: []const u8, new_parent: Ino, new_name: []const u8) Error!void {
        try self.checkWritable();
        try validateName(old_name);
        try validateName(new_name);
        if (isDotOrDotDot(old_name) or isDotOrDotDot(new_name)) return error.InvalidArgument;
        const opci = try self.getDirLive(old_parent);
        defer self.iput(opci);
        const npci = try self.getDirLive(new_parent);
        defer self.iput(npci);

        const sf = (try self.dirFind(opci, old_name)) orelse return error.NotFound;
        const sci = try self.igetLive(sf.ino);
        defer self.iput(sci);
        const src_is_dir = format.isDir(sci.i.mode);

        const df = try self.dirFind(npci, new_name);
        var dci: ?*CInode = null;
        defer if (dci) |d| self.iput(d);
        if (df) |f| {
            if (f.ino == sf.ino) return; // same inode: nothing to do
            dci = try self.igetLive(f.ino);
            const dst_is_dir = format.isDir(dci.?.i.mode);
            if (src_is_dir) {
                if (!dst_is_dir) return error.NotDir;
                if (!try self.dirIsEmpty(dci.?)) return error.NotEmpty;
            } else if (dst_is_dir) return error.IsDir;
        }

        const moving_dir = src_is_dir and old_parent != new_parent;
        if (moving_dir) {
            try self.checkNotAncestor(sf.ino, new_parent);
            if (df == null and npci.i.links >= format.LINK_MAX) return error.TooManyLinks;
        }

        // 1. Make the new name point at the source inode.
        if (df) |f| {
            try self.dirSetEntry(npci, f, sf.ino, sci.i.mode, true);
        } else {
            try self.dirAdd(npci, new_name, sf.ino, sci.i.mode);
        }
        // 2. Remove the old name (the directory may have changed shape).
        const sf2 = (try self.dirFind(opci, old_name)) orelse return error.Corrupt;
        try self.dirRemove(opci, sf2);
        // 3. A moved directory gets a new "..".
        if (moving_dir) {
            const dd = (try self.dirFind(sci, "..")) orelse return error.Corrupt;
            try self.dirSetEntry(sci, dd, new_parent, format.S_IFDIR, false);
            opci.i.links -|= 1;
            opci.dirty = true;
            npci.i.links += 1;
            npci.dirty = true;
        }
        // 4. Drop the replaced target.
        if (dci) |d| {
            if (format.isDir(d.i.mode)) {
                npci.i.links -|= 1;
                npci.dirty = true;
                d.i.links = 0;
                d.dirty = true;
                try self.dropInode(d);
            } else {
                d.i.links -|= 1;
                d.i.ctime = self.now();
                d.dirty = true;
                if (d.i.links == 0) try self.dropInode(d);
            }
        }
        sci.i.ctime = self.now();
        sci.dirty = true;
    }

    /// Change permission bits (the file type is preserved).
    pub fn chmod(self: *Fs, ino: Ino, mode: u16) Error!void {
        try self.checkWritable();
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        ci.i.mode = (ci.i.mode & format.S_IFMT) | (mode & format.PERM_MASK);
        ci.i.ctime = self.now();
        ci.dirty = true;
    }

    /// Change owner and/or group (null leaves the value unchanged).
    pub fn chown(self: *Fs, ino: Ino, uid: ?u32, gid: ?u32) Error!void {
        try self.checkWritable();
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        if (uid) |u| ci.i.uid = u;
        if (gid) |g| ci.i.gid = g;
        ci.i.ctime = self.now();
        ci.dirty = true;
    }

    /// Set access and/or modification time (seconds since the epoch).
    pub fn utimes(self: *Fs, ino: Ino, atime: ?i64, mtime: ?i64) Error!void {
        try self.checkWritable();
        const ci = try self.igetLive(ino);
        defer self.iput(ci);
        if (atime) |t| ci.i.atime = @truncate(@as(u64, @bitCast(t)));
        if (mtime) |t| ci.i.mtime = @truncate(@as(u64, @bitCast(t)));
        ci.i.ctime = self.now();
        ci.dirty = true;
    }

    /// Iterate directory `dir` starting at `cookie` (0 = beginning; resume
    /// with the `cookie` of the last entry returned).
    pub fn readdir(self: *Fs, dir: Ino, cookie: u64) Error!DirIterator {
        const d = try self.getDirLive(dir);
        self.iput(d);
        return .{ .fs = self, .ino = dir, .pos = cookie };
    }
};

pub const DirIterator = struct {
    fs: *Fs,
    ino: Ino,
    pos: u64,
    name_buf: [format.NAME_MAX]u8 = undefined,

    /// Next entry ("." and ".." included) or null at the end.
    pub fn next(self: *DirIterator) Error!?DirEntry {
        const fs = self.fs;
        const ci = try fs.getDirLive(self.ino);
        defer fs.iput(ci);
        const size = ci.i.size & 0xFFFF_FFFF;
        const bs = fs.bs;
        while (self.pos < size) {
            const lblk = self.pos / bs;
            const start: u64 = self.pos % bs;
            const pblk = try fs.bmap(ci, lblk);
            if (pblk == 0) {
                self.pos = (lblk + 1) * bs;
                continue;
            }
            const b = try fs.getBlock(pblk);
            defer fs.cache.release(b);
            var off: u32 = 0;
            while (off < bs) {
                const e = try dirent.parse(b.data, off, fs.has_filetype);
                const next_off = off + e.rec_len;
                if (off >= start and e.inode != 0) {
                    self.pos = lblk * bs + next_off;
                    @memcpy(self.name_buf[0..e.name.len], e.name);
                    var kind = FileType.fromDirent(e.file_type);
                    if (!fs.has_filetype or kind == .unknown) {
                        if (fs.iget(e.inode)) |ei| {
                            kind = FileType.fromMode(ei.i.mode);
                            fs.iput(ei);
                        } else |_| {}
                    }
                    return .{
                        .ino = e.inode,
                        .kind = kind,
                        .name = self.name_buf[0..e.name.len],
                        .cookie = self.pos,
                    };
                }
                off = next_off;
            }
            self.pos = (lblk + 1) * bs;
        }
        return null;
    }

    /// Cookie for resuming after the last returned entry.
    pub fn cookie(self: *const DirIterator) u64 {
        return self.pos;
    }
};
