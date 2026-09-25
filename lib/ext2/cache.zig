//! Write-back LRU block cache.
//!
//! Buffers are pinned while in use (`get`/`getZeroed` pin, `release` unpins);
//! only unpinned buffers are evicted. Dirty buffers are written when evicted
//! or on `flush`, which writes all dirty blocks in ascending block order and
//! coalesces runs of adjacent blocks into single device writes.
const std = @import("std");
const BlockDevice = @import("device.zig").BlockDevice;
const Allocator = std.mem.Allocator;

pub const CacheError = error{ Io, OutOfMemory };

pub const Buf = struct {
    blk: u32,
    data: []u8,
    dirty: bool = false,
    pins: u32 = 0,
    prev: ?*Buf = null,
    next: ?*Buf = null,
};

pub const Cache = struct {
    allocator: Allocator,
    dev: BlockDevice,
    bs: u32,
    capacity: usize,
    map: std.AutoHashMapUnmanaged(u32, *Buf) = .empty,
    /// Most recently used.
    head: ?*Buf = null,
    /// Least recently used.
    tail: ?*Buf = null,
    count: usize = 0,
    dirty_count: usize = 0,
    /// Recycled buffers (linked through `next`).
    spare: ?*Buf = null,
    scratch: []u8 = &.{},
    /// Removals since the last rehash (the std hash map leaves tombstones
    /// that make lookups of absent keys slow until rehashed).
    removals: usize = 0,

    // statistics
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    const max_coalesce = 64;

    pub fn init(allocator: Allocator, dev: BlockDevice, bs: u32, capacity: usize) Cache {
        return .{ .allocator = allocator, .dev = dev, .bs = bs, .capacity = @max(capacity, 16) };
    }

    /// Frees all memory. Dirty buffers are dropped; call `flush` first.
    pub fn deinit(self: *Cache) void {
        var it = self.head;
        while (it) |b| {
            it = b.next;
            self.destroyBuf(b);
        }
        var sp = self.spare;
        while (sp) |b| {
            sp = b.next;
            self.destroyBuf(b);
        }
        self.map.deinit(self.allocator);
        if (self.scratch.len != 0) self.allocator.free(self.scratch);
        self.* = undefined;
    }

    fn destroyBuf(self: *Cache, b: *Buf) void {
        self.allocator.free(b.data);
        self.allocator.destroy(b);
    }

    fn unlinkLru(self: *Cache, b: *Buf) void {
        if (b.prev) |p| p.next = b.next else self.head = b.next;
        if (b.next) |n| n.prev = b.prev else self.tail = b.prev;
        b.prev = null;
        b.next = null;
    }

    fn pushFront(self: *Cache, b: *Buf) void {
        b.prev = null;
        b.next = self.head;
        if (self.head) |h| h.prev = b;
        self.head = b;
        if (self.tail == null) self.tail = b;
    }

    fn touch(self: *Cache, b: *Buf) void {
        if (self.head == b) return;
        self.unlinkLru(b);
        self.pushFront(b);
    }

    /// Returns the cached buffer for `blk` if present (not pinned).
    pub fn peek(self: *Cache, blk: u32) ?*Buf {
        return self.map.get(blk);
    }

    /// Returns a pinned buffer holding the contents of `blk`.
    pub fn get(self: *Cache, blk: u32) CacheError!*Buf {
        if (self.map.get(blk)) |b| {
            self.hits += 1;
            b.pins += 1;
            self.touch(b);
            return b;
        }
        self.misses += 1;
        const b = try self.newBuf(blk);
        self.dev.read(@as(u64, blk) * self.bs, b.data) catch {
            b.pins = 0;
            self.removeBuf(b);
            return error.Io;
        };
        return b;
    }

    /// Returns a pinned, zero-filled, dirty buffer for `blk` without reading
    /// the device (for freshly allocated blocks).
    pub fn getZeroed(self: *Cache, blk: u32) CacheError!*Buf {
        const b = if (self.map.get(blk)) |existing| blk: {
            existing.pins += 1;
            self.touch(existing);
            break :blk existing;
        } else try self.newBuf(blk);
        @memset(b.data, 0);
        self.markDirty(b);
        return b;
    }

    pub fn release(self: *Cache, b: *Buf) void {
        _ = self;
        std.debug.assert(b.pins > 0);
        b.pins -= 1;
    }

    pub fn markDirty(self: *Cache, b: *Buf) void {
        if (!b.dirty) {
            b.dirty = true;
            self.dirty_count += 1;
        }
    }

    /// Forget a block (it was freed): its contents no longer matter.
    pub fn discard(self: *Cache, blk: u32) void {
        const b = self.map.get(blk) orelse return;
        if (b.dirty) {
            b.dirty = false;
            self.dirty_count -= 1;
        }
        if (b.pins == 0) self.removeBuf(b);
    }

    fn newBuf(self: *Cache, blk: u32) CacheError!*Buf {
        if (self.count >= self.capacity) try self.evictOne();
        const b: *Buf = if (self.spare) |s| blk: {
            self.spare = s.next;
            break :blk s;
        } else blk: {
            const nb = try self.allocator.create(Buf);
            errdefer self.allocator.destroy(nb);
            const data = try self.allocator.alloc(u8, self.bs);
            nb.* = .{ .blk = blk, .data = data };
            break :blk nb;
        };
        b.* = .{ .blk = blk, .data = b.data, .pins = 1 };
        self.map.put(self.allocator, blk, b) catch {
            b.next = self.spare;
            self.spare = b;
            return error.OutOfMemory;
        };
        self.pushFront(b);
        self.count += 1;
        return b;
    }

    fn removeBuf(self: *Cache, b: *Buf) void {
        std.debug.assert(b.pins == 0);
        if (b.dirty) {
            b.dirty = false;
            self.dirty_count -= 1;
        }
        _ = self.map.remove(b.blk);
        self.removals += 1;
        if (self.removals > self.map.capacity() / 2) {
            self.map.rehash(std.hash_map.AutoContext(u32){});
            self.removals = 0;
        }
        self.unlinkLru(b);
        self.count -= 1;
        b.next = self.spare;
        self.spare = b;
    }

    fn evictOne(self: *Cache) CacheError!void {
        var it = self.tail;
        while (it) |b| : (it = b.prev) {
            if (b.pins != 0) continue;
            if (b.dirty) {
                // Write the victim together with any dirty neighbours that
                // directly follow it, which keeps metadata writes sequential.
                try self.writeRunFrom(b);
            }
            self.evictions += 1;
            self.removeBuf(b);
            return;
        }
        // Everything pinned: allow the cache to grow temporarily.
    }

    fn writeRunFrom(self: *Cache, first: *Buf) CacheError!void {
        var run: [max_coalesce]*Buf = undefined;
        var n: usize = 0;
        run[n] = first;
        n += 1;
        while (n < max_coalesce) {
            const nb = self.map.get(first.blk +% @as(u32, @intCast(n))) orelse break;
            // Pinned buffers may be mid-modification; leave them alone.
            if (!nb.dirty or nb.pins != 0) break;
            run[n] = nb;
            n += 1;
        }
        try self.writeRun(run[0..n]);
    }

    fn writeRun(self: *Cache, run: []const *Buf) CacheError!void {
        const bs = self.bs;
        if (run.len == 1) {
            self.dev.write(@as(u64, run[0].blk) * bs, run[0].data) catch return error.Io;
        } else {
            if (self.scratch.len == 0) self.scratch = try self.allocator.alloc(u8, max_coalesce * @as(usize, bs));
            for (run, 0..) |b, k| @memcpy(self.scratch[k * bs ..][0..bs], b.data);
            self.dev.write(@as(u64, run[0].blk) * bs, self.scratch[0 .. run.len * bs]) catch return error.Io;
        }
        for (run) |b| {
            if (b.dirty) {
                b.dirty = false;
                self.dirty_count -= 1;
            }
        }
    }

    fn lessThan(_: void, a: *Buf, b: *Buf) bool {
        return a.blk < b.blk;
    }

    /// Write every dirty buffer to the device (ascending block order).
    pub fn flush(self: *Cache) CacheError!void {
        if (self.dirty_count == 0) return;
        var list: std.ArrayList(*Buf) = .empty;
        defer list.deinit(self.allocator);
        try list.ensureTotalCapacity(self.allocator, self.dirty_count);
        var it = self.head;
        while (it) |b| : (it = b.next) {
            if (b.dirty) list.appendAssumeCapacity(b);
        }
        std.mem.sort(*Buf, list.items, {}, lessThan);
        var i: usize = 0;
        const items = list.items;
        while (i < items.len) {
            var j = i + 1;
            while (j < items.len and j - i < max_coalesce and items[j].blk == items[j - 1].blk + 1) j += 1;
            try self.writeRun(items[i..j]);
            i = j;
        }
    }
};

test "cache basic get/evict/flush" {
    const MemDevice = @import("device.zig").MemDevice;
    var md = try MemDevice.init(std.testing.allocator, 1024 * 64);
    defer md.deinit();
    var c = Cache.init(std.testing.allocator, md.device(), 1024, 16);
    defer c.deinit();
    // write 40 blocks through the cache (forces evictions)
    for (0..40) |i| {
        const b = try c.getZeroed(@intCast(i));
        b.data[0] = @intCast(i + 1);
        c.release(b);
    }
    try c.flush();
    try std.testing.expectEqual(@as(usize, 0), c.dirty_count);
    for (0..40) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), md.bytes[i * 1024]);
        const b = try c.get(@intCast(i));
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), b.data[0]);
        c.release(b);
    }
    c.discard(39);
    try std.testing.expect(c.peek(39) == null);
}
