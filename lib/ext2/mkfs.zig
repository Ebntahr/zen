//! Create a fresh ext2 filesystem (revision 1, sparse_super, filetype,
//! large_file) with a root directory and lost+found.
const std = @import("std");
const format = @import("format.zig");
const device = @import("device.zig");
const dirent = @import("dir.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const BlockDevice = device.BlockDevice;
const Error = errors.Error;
const put16 = format.put16;
const put32 = format.put32;

pub const MkfsOptions = struct {
    /// 1024, 2048 or 4096.
    block_size: u32 = 4096,
    /// 128 or 256 (any power of two between 128 and the block size works).
    inode_size: u32 = 256,
    /// Bytes of space per inode; 0 selects 4096 below 512 MiB, 8192 below
    /// 4 GiB and 16384 above (root images hold many small files).
    inode_ratio: u32 = 0,
    /// Explicit number of inodes (overrides `inode_ratio`; rounded up).
    inodes_count: u32 = 0,
    /// Filesystem size in blocks; 0 uses the whole device.
    blocks_count: u64 = 0,
    /// Percentage of blocks reserved for the super-user.
    reserved_percent: u8 = 5,
    /// Volume label (at most 16 bytes).
    label: []const u8 = "",
    /// Seed for the filesystem UUID and directory hash seed.
    uuid_seed: u64 = 0,
    /// Creation time in seconds since the epoch.
    timestamp: u32 = 0,
    root_uid: u32 = 0,
    root_gid: u32 = 0,
    /// The device already reads as zeros (e.g. a new sparse file), so
    /// inode tables need not be cleared.
    device_zeroed: bool = false,
    /// 1 (dynamic, default) or 0 (original ext2: 128-byte inodes, no
    /// features, superblock backups in every group).
    revision: u32 = 1,
};

pub const Layout = struct {
    block_size: u32,
    blocks_count: u32,
    first_data_block: u32,
    blocks_per_group: u32,
    groups: u32,
    inodes_per_group: u32,
    inode_table_blocks: u32,
    gdt_blocks: u32,
    lost_found_blocks: u32,
    sparse: bool,

    pub fn blocksInGroup(self: Layout, g: u32) u32 {
        if (g + 1 == self.groups) return self.blocks_count - self.first_data_block - g * self.blocks_per_group;
        return self.blocks_per_group;
    }

    pub fn groupStart(self: Layout, g: u32) u32 {
        return self.first_data_block + g * self.blocks_per_group;
    }

    /// Blocks used by metadata at the start of group g.
    pub fn overhead(self: Layout, g: u32) u32 {
        const sb: u32 = if (format.groupHasSuper(g, self.sparse)) 1 + self.gdt_blocks else 0;
        return sb + 2 + self.inode_table_blocks;
    }
};

pub fn computeLayout(dev_size: u64, opts: MkfsOptions) Error!Layout {
    const bs = opts.block_size;
    if (bs != 1024 and bs != 2048 and bs != 4096) return error.InvalidArgument;
    const isz = opts.inode_size;
    if (isz < 128 or isz > bs or !std.math.isPowerOfTwo(isz)) return error.InvalidArgument;
    if (opts.revision > 1 or (opts.revision == 0 and isz != 128)) return error.InvalidArgument;
    var blocks: u64 = if (opts.blocks_count != 0) opts.blocks_count else dev_size / bs;
    if (blocks * bs > dev_size) return error.InvalidArgument;
    blocks = @min(blocks, 0xFFFF_FFFF);
    const fdb: u32 = if (bs == 1024) 1 else 0;
    const bpg: u32 = bs * 8;
    const ratio: u64 = if (opts.inode_ratio != 0)
        @max(opts.inode_ratio, 1024)
    else if (blocks * bs < 512 << 20)
        4096
    else if (blocks * bs < 4 << 30)
        8192
    else
        16384;
    const lf_blocks: u32 = @min(@max(2, 16384 / bs), format.NDIR_BLOCKS);

    var blocks_count: u32 = @intCast(blocks);
    while (true) {
        if (blocks_count <= fdb + 16) return error.NoSpace;
        const groups: u32 = @intCast(std.math.divCeil(u64, blocks_count - fdb, bpg) catch unreachable);
        var total_inodes: u64 = if (opts.inodes_count != 0) opts.inodes_count else @as(u64, blocks_count) * bs / ratio;
        total_inodes = @max(total_inodes, 16);
        var ipg: u64 = std.math.divCeil(u64, total_inodes, groups) catch unreachable;
        ipg = @max(ipg, 16);
        const ipb = bs / isz;
        const alignment: u64 = @max(8, ipb);
        ipg = std.mem.alignForward(u64, ipg, alignment);
        ipg = @min(ipg, @as(u64, bs) * 8);
        if (ipg * groups > 0xFFFF_FFFF) return error.InvalidArgument;
        const layout: Layout = .{
            .block_size = bs,
            .blocks_count = blocks_count,
            .first_data_block = fdb,
            .blocks_per_group = bpg,
            .groups = groups,
            .inodes_per_group = @intCast(ipg),
            .inode_table_blocks = @intCast(ipg * isz / bs),
            .gdt_blocks = @intCast(std.math.divCeil(u64, @as(u64, groups) * format.GD_SIZE, bs) catch unreachable),
            .lost_found_blocks = lf_blocks,
            .sparse = opts.revision >= 1,
        };
        const last = groups - 1;
        const last_size = layout.blocksInGroup(last);
        const need = layout.overhead(last) + if (groups == 1) 1 + lf_blocks + 16 else 50;
        if (last_size < need) {
            if (groups == 1) return error.NoSpace;
            // Drop a too-small trailing group (like mke2fs).
            blocks_count -= last_size;
            continue;
        }
        return layout;
    }
}

fn setBitRange(bm: []u8, from: u32, to: u32) void {
    var i = from;
    while (i < to) : (i += 1) bm[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
}

fn initInode(raw: []u8, isz: u32, mode: u16, uid: u32, gid: u32, t: u32, links: u16, size: u32, blocks: []const u32, spb: u32) void {
    @memset(raw, 0);
    var i: format.Inode = .{
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .size = size,
        .atime = t,
        .ctime = t,
        .mtime = t,
        .links = links,
        .blocks = @intCast(blocks.len * spb),
    };
    for (blocks, 0..) |b, k| i.block[k] = b;
    i.encode(raw);
    if (isz > format.GOOD_OLD_INODE_SIZE) {
        put16(raw, format.ino.extra_isize, format.DEFAULT_EXTRA_ISIZE);
        put32(raw, format.ino.crtime, t);
    }
}

/// Format `dev` as ext2.
pub fn mkfs(allocator: Allocator, dev: BlockDevice, opts: MkfsOptions) Error!void {
    if (opts.label.len > 16) return error.NameTooLong;
    const L = try computeLayout(dev.size(), opts);
    const bs = L.block_size;
    const isz = opts.inode_size;
    const spb = bs / 512;
    const t = opts.timestamp;
    const first_ino = format.GOOD_OLD_FIRST_INO;

    const blockbuf = try allocator.alloc(u8, bs);
    defer allocator.free(blockbuf);
    const gdt = try allocator.alloc(u8, @as(usize, L.gdt_blocks) * bs);
    defer allocator.free(gdt);
    @memset(gdt, 0);

    // Group 0 data: root directory block, then lost+found blocks.
    const g0_data = L.groupStart(0) + L.overhead(0);
    const root_blk = g0_data;
    const lf_first = root_blk + 1;

    var free_blocks_total: u64 = 0;
    var zero_chunk: []u8 = &.{};
    defer if (zero_chunk.len != 0) allocator.free(zero_chunk);

    var g: u32 = 0;
    while (g < L.groups) : (g += 1) {
        const start = L.groupStart(g);
        const n = L.blocksInGroup(g);
        var pos = start;
        if (format.groupHasSuper(g, L.sparse)) pos += 1 + L.gdt_blocks;
        const bb = pos;
        const ib = pos + 1;
        const it = pos + 2;
        var used = L.overhead(g);
        if (g == 0) used += 1 + L.lost_found_blocks;
        const free = n - used;
        free_blocks_total += free;
        const free_inodes = L.inodes_per_group - (if (g == 0) first_ino else 0);

        const o = g * format.GD_SIZE;
        put32(gdt, o + format.gd.block_bitmap, bb);
        put32(gdt, o + format.gd.inode_bitmap, ib);
        put32(gdt, o + format.gd.inode_table, it);
        put16(gdt, o + format.gd.free_blocks_count, @intCast(free));
        put16(gdt, o + format.gd.free_inodes_count, @intCast(free_inodes));
        put16(gdt, o + format.gd.used_dirs_count, if (g == 0) 2 else 0);

        // Block bitmap: metadata (+ root/lost+found data in group 0) and the
        // padding past the end of the group.
        @memset(blockbuf, 0);
        setBitRange(blockbuf, 0, used);
        setBitRange(blockbuf, n, bs * 8);
        try dev.write(@as(u64, bb) * bs, blockbuf);

        // Inode bitmap: reserved inodes 1..11 in group 0, padding bits.
        @memset(blockbuf, 0);
        if (g == 0) setBitRange(blockbuf, 0, first_ino);
        setBitRange(blockbuf, L.inodes_per_group, bs * 8);
        try dev.write(@as(u64, ib) * bs, blockbuf);

        if (!opts.device_zeroed) {
            if (zero_chunk.len == 0) {
                zero_chunk = try allocator.alloc(u8, 64 * @as(usize, bs));
                @memset(zero_chunk, 0);
            }
            var done: u32 = 0;
            while (done < L.inode_table_blocks) {
                const k = @min(64, L.inode_table_blocks - done);
                try dev.write(@as(u64, it + done) * bs, zero_chunk[0 .. k * bs]);
                done += k;
            }
        }
    }

    // Superblock.
    var sb = [_]u8{0} ** format.SUPERBLOCK_SIZE;
    const inodes_count = L.inodes_per_group * L.groups;
    put32(&sb, format.sb.inodes_count, inodes_count);
    put32(&sb, format.sb.blocks_count, L.blocks_count);
    put32(&sb, format.sb.r_blocks_count, @intCast(@as(u64, L.blocks_count) * opts.reserved_percent / 100));
    put32(&sb, format.sb.free_blocks_count, @intCast(free_blocks_total));
    put32(&sb, format.sb.free_inodes_count, inodes_count - first_ino);
    put32(&sb, format.sb.first_data_block, L.first_data_block);
    const log_bs: u32 = std.math.log2_int(u32, bs) - 10;
    put32(&sb, format.sb.log_block_size, log_bs);
    put32(&sb, format.sb.log_frag_size, log_bs);
    put32(&sb, format.sb.blocks_per_group, L.blocks_per_group);
    put32(&sb, format.sb.frags_per_group, L.blocks_per_group);
    put32(&sb, format.sb.inodes_per_group, L.inodes_per_group);
    put32(&sb, format.sb.wtime, t);
    put16(&sb, format.sb.max_mnt_count, 0xFFFF);
    put16(&sb, format.sb.magic, format.MAGIC);
    put16(&sb, format.sb.state, format.STATE_VALID);
    put16(&sb, format.sb.errors, 1);
    put32(&sb, format.sb.lastcheck, t);
    const rev1 = opts.revision >= 1;
    put32(&sb, format.sb.rev_level, opts.revision);
    if (rev1) {
        put32(&sb, format.sb.first_ino, first_ino);
        put16(&sb, format.sb.inode_size, @intCast(isz));
        put32(&sb, format.sb.feature_compat, 0);
        put32(&sb, format.sb.feature_incompat, format.INCOMPAT_FILETYPE);
        put32(&sb, format.sb.feature_ro_compat, format.RO_COMPAT_SPARSE_SUPER | format.RO_COMPAT_LARGE_FILE);
    }
    var prng = std.Random.DefaultPrng.init(opts.uuid_seed ^ 0x9E37_79B9_7F4A_7C15);
    const rnd = prng.random();
    var uuid: [16]u8 = undefined;
    rnd.bytes(&uuid);
    uuid[6] = (uuid[6] & 0x0F) | 0x40;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;
    @memcpy(sb[format.sb.uuid..][0..16], &uuid);
    @memcpy(sb[format.sb.volume_name..][0..opts.label.len], opts.label);
    var seed: [16]u8 = undefined;
    rnd.bytes(&seed);
    seed[6] = (seed[6] & 0x0F) | 0x40;
    seed[8] = (seed[8] & 0x3F) | 0x80;
    @memcpy(sb[format.sb.hash_seed..][0..16], &seed);
    sb[format.sb.def_hash_version] = 1; // half_md4
    put32(&sb, format.sb.mkfs_time, t);
    if (isz > format.GOOD_OLD_INODE_SIZE) {
        put16(&sb, format.sb.min_extra_isize, format.DEFAULT_EXTRA_ISIZE);
        put16(&sb, format.sb.want_extra_isize, format.DEFAULT_EXTRA_ISIZE);
    }

    // Primary and backup superblocks + group descriptor tables.
    g = 0;
    while (g < L.groups) : (g += 1) {
        if (!format.groupHasSuper(g, L.sparse)) continue;
        if (rev1) put16(&sb, format.sb.block_group_nr, @intCast(g));
        const start = L.groupStart(g);
        @memset(blockbuf, 0);
        if (g == 0) {
            if (bs == 1024) {
                try dev.write(0, blockbuf); // boot block
                @memcpy(blockbuf[0..1024], &sb);
                try dev.write(1024, blockbuf);
            } else {
                @memcpy(blockbuf[1024..2048], &sb);
                try dev.write(0, blockbuf);
            }
        } else {
            @memcpy(blockbuf[0..1024], &sb);
            try dev.write(@as(u64, start) * bs, blockbuf);
        }
        try dev.write(@as(u64, start + 1) * bs, gdt);
    }

    // Root directory and lost+found contents.
    dirent.initDirBlock(blockbuf, format.ROOT_INO, format.ROOT_INO, rev1);
    _ = dirent.insert(blockbuf, "lost+found", first_ino, if (rev1) format.FT_DIR else 0, rev1) catch unreachable;
    try dev.write(@as(u64, root_blk) * bs, blockbuf);
    var k: u32 = 0;
    while (k < L.lost_found_blocks) : (k += 1) {
        if (k == 0) dirent.initDirBlock(blockbuf, first_ino, format.ROOT_INO, rev1) else dirent.initEmpty(blockbuf);
        try dev.write(@as(u64, lf_first + k) * bs, blockbuf);
    }

    // Inode table head of group 0 (inodes 1..11).
    const it0 = get32(gdt, format.gd.inode_table);
    const head_blocks: u32 = @intCast(std.math.divCeil(u64, @as(u64, first_ino) * isz, bs) catch unreachable);
    const itbuf = try allocator.alloc(u8, @as(usize, head_blocks) * bs);
    defer allocator.free(itbuf);
    @memset(itbuf, 0);
    const root_raw = itbuf[(format.ROOT_INO - 1) * isz ..][0..isz];
    initInode(root_raw, isz, format.S_IFDIR | 0o755, opts.root_uid, opts.root_gid, t, 3, bs, &.{root_blk}, spb);
    var lf_list: [format.NDIR_BLOCKS]u32 = undefined;
    for (0..L.lost_found_blocks) |j| lf_list[j] = lf_first + @as(u32, @intCast(j));
    const lf_raw = itbuf[(first_ino - 1) * isz ..][0..isz];
    initInode(lf_raw, isz, format.S_IFDIR | 0o700, opts.root_uid, opts.root_gid, t, 2, L.lost_found_blocks * bs, lf_list[0..L.lost_found_blocks], spb);
    try dev.write(@as(u64, it0) * bs, itbuf);

    try dev.flush();
}

const get32 = format.get32;
