//! Consistency checker (a small subset of e2fsck, read-only).
//!
//! Verifies block ownership (no duplicates, no out-of-range pointers),
//! i_blocks accounting, directory structure ("." / "..", record layout,
//! file types), link counts, block/inode bitmaps (incl. padding bits) and the
//! free/used-dirs counters in the group descriptors and superblock. It works
//! on the live mounted state (through the caches), so it can run at any time.
const std = @import("std");
const format = @import("format.zig");
const fs_mod = @import("fs.zig");
const dirent = @import("dir.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const Fs = fs_mod.Fs;
const Error = errors.Error;
const get32 = format.get32;

pub const Report = struct {
    problems: u32 = 0,
    inodes_used: u32 = 0,
    directories: u32 = 0,
    blocks_used: u64 = 0,
};

const Ctx = struct {
    fs: *Fs,
    out: ?*std.Io.Writer,
    rep: Report = .{},
    used: std.DynamicBitSetUnmanaged,
    // per-inode walk state
    count: u64 = 0,
    max_lblk: i64 = -1,
    mapped: ?*std.DynamicBitSetUnmanaged = null,
    ino: u32 = 0,

    fn problem(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        self.rep.problems += 1;
        if (self.out) |w| {
            if (self.rep.problems <= 100) {
                w.print(fmt ++ "\n", args) catch {};
            }
        }
    }

    fn mark(self: *Ctx, blk: u32, what: []const u8) void {
        if (blk < self.fs.first_data_block or blk >= self.fs.blocks_count) {
            self.problem("inode {d}: {s} block {d} out of range", .{ self.ino, what, blk });
            return;
        }
        if (self.used.isSet(blk)) {
            self.problem("inode {d}: {s} block {d} multiply claimed", .{ self.ino, what, blk });
            return;
        }
        self.used.set(blk);
    }

    fn walk(self: *Ctx, blk: u32, level: u32, lbase: u64) Error!void {
        if (blk < self.fs.first_data_block or blk >= self.fs.blocks_count) {
            self.problem("inode {d}: block pointer {d} out of range", .{ self.ino, blk });
            return;
        }
        self.mark(blk, if (level == 0) "data" else "indirect");
        self.count += 1;
        if (level == 0) {
            if (@as(i64, @intCast(lbase)) > self.max_lblk) self.max_lblk = @intCast(lbase);
            if (self.mapped) |m| {
                if (lbase < m.bit_length) m.set(@intCast(lbase));
            }
            return;
        }
        const fs = self.fs;
        const b = try fs.getBlock(blk);
        defer fs.cache.release(b);
        var span: u64 = 1;
        for (1..level) |_| span *= fs.ptrs;
        var k: u32 = 0;
        while (k < fs.ptrs) : (k += 1) {
            const child = get32(b.data, k * 4);
            if (child != 0) try self.walk(child, level - 1, lbase + k * span);
        }
    }
};

/// Check the mounted filesystem. Problems are counted in the report and,
/// when `out` is given, described there (first 100).
pub fn check(fs: *Fs, allocator: Allocator, out: ?*std.Io.Writer) Error!Report {
    var ctx: Ctx = .{
        .fs = fs,
        .out = out,
        .used = try std.DynamicBitSetUnmanaged.initEmpty(allocator, fs.blocks_count),
    };
    defer ctx.used.deinit(allocator);
    const ninodes = fs.inodes_count;
    const links_found = try allocator.alloc(u32, ninodes + 1);
    defer allocator.free(links_found);
    @memset(links_found, 0);
    const parent_of = try allocator.alloc(u32, ninodes + 1);
    defer allocator.free(parent_of);
    @memset(parent_of, 0);
    const dotdot = try allocator.alloc(u32, ninodes + 1);
    defer allocator.free(dotdot);
    @memset(dotdot, 0);
    var in_use = try std.DynamicBitSetUnmanaged.initEmpty(allocator, ninodes + 1);
    defer in_use.deinit(allocator);
    var is_dir = try std.DynamicBitSetUnmanaged.initEmpty(allocator, ninodes + 1);
    defer is_dir.deinit(allocator);

    // 1. Static metadata.
    const resize_inode = fs.compat & format.COMPAT_RESIZE_INODE != 0;
    const reserved_gdt: u32 = if (fs.rev >= 1) format.get16(&fs.sbraw, format.sb.reserved_gdt_blocks) else 0;
    var g: u32 = 0;
    while (g < fs.groups) : (g += 1) {
        const start = fs.groupFirstBlock(g);
        if (format.groupHasSuper(g, fs.sparse_super)) {
            ctx.mark(start, "superblock");
            var k: u32 = 0;
            while (k < fs.gdt_blocks) : (k += 1) ctx.mark(start + 1 + k, "gdt");
            if (!resize_inode) {
                k = 0;
                while (k < reserved_gdt) : (k += 1) ctx.mark(start + 1 + fs.gdt_blocks + k, "reserved gdt");
            }
        }
        ctx.mark(fs.gdBlockBitmap(g), "block bitmap");
        ctx.mark(fs.gdInodeBitmap(g), "inode bitmap");
        var k: u32 = 0;
        while (k < fs.inode_table_blocks) : (k += 1) ctx.mark(fs.gdInodeTable(g) + k, "inode table");
    }

    // 2. Inodes and their blocks.
    var ino: u32 = 1;
    while (ino <= ninodes) : (ino += 1) {
        const ci = try fs.iget(ino);
        defer fs.iput(ci);
        const i = &ci.i;
        const reserved = ino < fs.first_ino and ino != format.ROOT_INO;
        // Inodes held open after their last unlink are still in use.
        const live = if (reserved) i.mode != 0 else (i.mode != 0 and (i.links > 0 or fs.holds.contains(ino)));
        if (!live) {
            if (ino == format.ROOT_INO) ctx.problem("root inode not in use", .{});
            continue;
        }
        in_use.set(ino);
        ctx.ino = ino;
        if (!reserved) {
            ctx.rep.inodes_used += 1;
            if (i.dtime != 0) ctx.problem("inode {d}: in use but dtime set", .{ino});
        }
        const dir = format.isDir(i.mode);
        if (dir) {
            is_dir.set(ino);
            ctx.rep.directories += 1;
        }
        ctx.count = 0;
        ctx.max_lblk = -1;
        var mapped: std.DynamicBitSetUnmanaged = .{};
        defer if (mapped.bit_length != 0) mapped.deinit(allocator);
        if (dir) {
            const nb: usize = @intCast((i.size & 0xFFFF_FFFF) / fs.bs);
            mapped = try std.DynamicBitSetUnmanaged.initEmpty(allocator, nb);
            ctx.mapped = &mapped;
        } else ctx.mapped = null;
        if (fs.hasBlockMap(i)) {
            for (0..format.NDIR_BLOCKS) |k| {
                if (i.block[k] != 0) try ctx.walk(i.block[k], 0, k);
            }
            var base: u64 = format.NDIR_BLOCKS;
            var cover: u64 = fs.ptrs;
            for (1..4) |level| {
                const blk = i.block[format.NDIR_BLOCKS - 1 + level];
                if (blk != 0) try ctx.walk(blk, @intCast(level), base);
                base += cover;
                cover *= fs.ptrs;
            }
        }
        ctx.mapped = null;
        if (i.file_acl != 0) {
            ctx.count += 1;
            // EA blocks may be shared between inodes.
            if (i.file_acl >= fs.first_data_block and i.file_acl < fs.blocks_count) ctx.used.set(i.file_acl);
        }
        if (reserved) continue;
        if (@as(u64, i.blocks) != ctx.count * fs.spb)
            ctx.problem("inode {d}: i_blocks is {d}, counted {d}", .{ ino, i.blocks, ctx.count * fs.spb });
        switch (i.mode & format.S_IFMT) {
            format.S_IFREG => {
                const nblk = std.math.divCeil(u64, i.size, fs.bs) catch unreachable;
                if (ctx.max_lblk >= 0 and @as(u64, @intCast(ctx.max_lblk)) >= nblk)
                    ctx.problem("inode {d}: block {d} past EOF (size {d})", .{ ino, ctx.max_lblk, i.size });
            },
            format.S_IFDIR => {
                if (i.size % fs.bs != 0 or i.size == 0) ctx.problem("dir {d}: bad size {d}", .{ ino, i.size });
                if (mapped.count() != mapped.bit_length) ctx.problem("dir {d}: has holes", .{ino});
                if (ctx.max_lblk >= 0 and @as(u64, @intCast(ctx.max_lblk)) >= mapped.bit_length)
                    ctx.problem("dir {d}: blocks past size", .{ino});
            },
            format.S_IFLNK => {
                if (fs.hasBlockMap(i)) {
                    if (i.size >= fs.bs or ctx.count - @intFromBool(i.file_acl != 0) != 1)
                        ctx.problem("symlink {d}: bad slow symlink", .{ino});
                } else {
                    const bytes = i.blockBytes();
                    const len = std.mem.indexOfScalar(u8, &bytes, 0) orelse bytes.len;
                    if (i.size >= bytes.len or len != i.size) ctx.problem("symlink {d}: bad fast symlink", .{ino});
                }
            },
            else => {},
        }
    }

    // 3. Directory contents.
    ino = 1;
    while (ino <= ninodes) : (ino += 1) {
        if (!is_dir.isSet(ino)) continue;
        if (ino < fs.first_ino and ino != format.ROOT_INO) continue;
        const ci = try fs.iget(ino);
        defer fs.iput(ci);
        // A removed directory that is still held open references nothing.
        if (ci.i.links == 0) continue;
        const nb: u32 = @intCast((ci.i.size & 0xFFFF_FFFF) / fs.bs);
        var lblk: u32 = 0;
        var entry_no: u32 = 0;
        while (lblk < nb) : (lblk += 1) {
            const pblk = try fs.bmap(ci, lblk);
            if (pblk == 0) continue;
            const b = try fs.getBlock(pblk);
            defer fs.cache.release(b);
            dirent.validate(b.data, fs.has_filetype) catch {
                ctx.problem("dir {d}: corrupt block {d}", .{ ino, lblk });
                continue;
            };
            var off: u32 = 0;
            while (off < fs.bs) {
                const e = try dirent.parse(b.data, off, fs.has_filetype);
                off += e.rec_len;
                const slot = if (lblk == 0) entry_no else 2;
                if (lblk == 0) entry_no += 1;
                if (slot < 2) {
                    const want: []const u8 = if (slot == 0) "." else "..";
                    if (!std.mem.eql(u8, e.name, want) or e.inode == 0) {
                        ctx.problem("dir {d}: missing '{s}' entry", .{ ino, want });
                    } else if (slot == 0) {
                        if (e.inode != ino) ctx.problem("dir {d}: '.' points to {d}", .{ ino, e.inode });
                        if (e.rec_len > 24) ctx.problem("dir {d}: '.' entry is big", .{ino});
                    } else {
                        dotdot[ino] = e.inode;
                    }
                }
                if (e.inode == 0) continue;
                if (e.inode > ninodes) {
                    ctx.problem("dir {d}: entry '{s}' has bad inode {d}", .{ ino, e.name, e.inode });
                    continue;
                }
                const named_dot = std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..");
                if (named_dot and slot >= 2) ctx.problem("dir {d}: stray '{s}' entry", .{ ino, e.name });
                if (std.mem.indexOfAny(u8, e.name, "/\x00") != null) ctx.problem("dir {d}: bad name", .{ino});
                if (!in_use.isSet(e.inode) or (e.inode < fs.first_ino and e.inode != format.ROOT_INO)) {
                    ctx.problem("dir {d}: entry '{s}' points to unused inode {d}", .{ ino, e.name, e.inode });
                    continue;
                }
                links_found[e.inode] += 1;
                if (fs.has_filetype) {
                    const ti = try fs.iget(e.inode);
                    const want = format.fileTypeFromMode(ti.i.mode);
                    fs.iput(ti);
                    if (want != e.file_type) ctx.problem("dir {d}: entry '{s}' has file type {d}, want {d}", .{ ino, e.name, e.file_type, want });
                } else if (e.file_type != 0) ctx.problem("dir {d}: file type set without feature", .{ino});
                if (!named_dot and is_dir.isSet(e.inode)) {
                    if (parent_of[e.inode] != 0) ctx.problem("dir {d}: directory {d} has multiple parents", .{ ino, e.inode });
                    parent_of[e.inode] = ino;
                }
            }
        }
        if (entry_no < 2) ctx.problem("dir {d}: missing '.'/'..'", .{ino});
    }

    // 4. Link counts and parent pointers.
    ino = 1;
    while (ino <= ninodes) : (ino += 1) {
        if (!in_use.isSet(ino)) continue;
        if (ino < fs.first_ino and ino != format.ROOT_INO) continue;
        const ci = try fs.iget(ino);
        const links = ci.i.links;
        fs.iput(ci);
        if (links != links_found[ino]) ctx.problem("inode {d}: link count {d}, counted {d}", .{ ino, links, links_found[ino] });
        if (is_dir.isSet(ino) and links > 0) {
            const want_parent = if (ino == format.ROOT_INO) format.ROOT_INO else parent_of[ino];
            if (want_parent == 0) {
                ctx.problem("dir {d}: unreachable", .{ino});
            } else if (dotdot[ino] != want_parent) {
                ctx.problem("dir {d}: '..' is {d}, parent is {d}", .{ ino, dotdot[ino], want_parent });
            }
        }
    }

    // 5. Bitmaps and counters.
    var total_free_blocks: u64 = 0;
    var total_free_inodes: u64 = 0;
    g = 0;
    while (g < fs.groups) : (g += 1) {
        {
            const b = try fs.getBlock(fs.gdBlockBitmap(g));
            defer fs.cache.release(b);
            const n = fs.blocksInGroup(g);
            var free: u32 = 0;
            var bit: u32 = 0;
            while (bit < fs.bs * 8) : (bit += 1) {
                const set = b.data[bit >> 3] & (@as(u8, 1) << @intCast(bit & 7)) != 0;
                if (bit >= n) {
                    if (!set) {
                        ctx.problem("group {d}: block bitmap padding not set", .{g});
                        break;
                    }
                    continue;
                }
                const blk = fs.groupFirstBlock(g) + bit;
                const want = ctx.used.isSet(blk);
                if (set != want) ctx.problem("block {d}: bitmap says {s}, actually {s}", .{ blk, if (set) "used" else "free", if (want) "used" else "free" });
                if (!set) free += 1;
                if (want) ctx.rep.blocks_used += 1;
            }
            if (free != fs.gdFreeBlocks(g)) ctx.problem("group {d}: free blocks {d}, counted {d}", .{ g, fs.gdFreeBlocks(g), free });
            total_free_blocks += free;
        }
        {
            const b = try fs.getBlock(fs.gdInodeBitmap(g));
            defer fs.cache.release(b);
            var free: u32 = 0;
            var dirs: u32 = 0;
            var bit: u32 = 0;
            while (bit < fs.inodes_per_group) : (bit += 1) {
                const set = b.data[bit >> 3] & (@as(u8, 1) << @intCast(bit & 7)) != 0;
                const n = g * fs.inodes_per_group + bit + 1;
                const want = n < fs.first_ino or in_use.isSet(n);
                if (set != want) ctx.problem("inode {d}: bitmap says {s}, actually {s}", .{ n, if (set) "used" else "free", if (want) "used" else "free" });
                if (!set) free += 1;
                if (in_use.isSet(n) and is_dir.isSet(n)) dirs += 1;
            }
            if (free != fs.gdFreeInodes(g)) ctx.problem("group {d}: free inodes {d}, counted {d}", .{ g, fs.gdFreeInodes(g), free });
            if (dirs != fs.gdUsedDirs(g)) ctx.problem("group {d}: used dirs {d}, counted {d}", .{ g, fs.gdUsedDirs(g), dirs });
            total_free_inodes += free;
        }
    }
    if (total_free_blocks != fs.sbFreeBlocks()) ctx.problem("superblock: free blocks {d}, counted {d}", .{ fs.sbFreeBlocks(), total_free_blocks });
    if (total_free_inodes != fs.sbFreeInodes()) ctx.problem("superblock: free inodes {d}, counted {d}", .{ fs.sbFreeInodes(), total_free_inodes });
    return ctx.rep;
}
