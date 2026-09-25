//! Memory management for zensh.
//!
//! * `gpa`     – a small single-threaded size-class allocator (free lists on top
//!               of the page allocator) used for all persistent shell state.
//! * `scratch` – a mark/release bump allocator used for transient data
//!               (parse trees of the command being run, expansion results).
//!               Callers take a `mark()` before work and `release()` it after,
//!               in strict stack order.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const page = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Size-class allocator
// ---------------------------------------------------------------------------

const min_shift = 4; // 16 bytes
const max_shift = 12; // 4096 bytes
const n_classes = max_shift - min_shift + 1;
const slab_size = 64 * 1024;

const FreeNode = struct { next: ?*FreeNode };

var free_lists: [n_classes]?*FreeNode = @splat(null);
var slab_cur: usize = 0;
var slab_end: usize = 0;

fn classOf(len: usize, alignment: Alignment) ?usize {
    const need = @max(len, alignment.toByteUnits(), @as(usize, 1) << min_shift);
    if (need > (@as(usize, 1) << max_shift)) return null;
    const shift = std.math.log2_int_ceil(usize, need);
    return shift - min_shift;
}

fn gpaAlloc(_: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const cls = classOf(len, alignment) orelse return page.rawAlloc(len, alignment, ra);
    if (free_lists[cls]) |node| {
        free_lists[cls] = node.next;
        return @ptrCast(node);
    }
    const size = @as(usize, 1) << @intCast(cls + min_shift);
    var start = std.mem.alignForward(usize, slab_cur, size);
    if (slab_cur == 0 or start + size > slab_end) {
        const slab = page.alloc(u8, slab_size) catch return null;
        slab_cur = @intFromPtr(slab.ptr);
        slab_end = slab_cur + slab.len;
        start = std.mem.alignForward(usize, slab_cur, size);
    }
    slab_cur = start + size;
    return @ptrFromInt(start);
}

fn gpaResize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old == null and new == null) return page.rawResize(memory, alignment, new_len, ra);
    if (old == null or new == null) return false;
    return old.? == new.?;
}

fn gpaRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old == null and new == null) return page.rawRemap(memory, alignment, new_len, ra);
    if (gpaResize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
    return null;
}

fn gpaFree(_: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
    const cls = classOf(memory.len, alignment) orelse return page.rawFree(memory, alignment, ra);
    const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
    node.next = free_lists[cls];
    free_lists[cls] = node;
}

pub const gpa: Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = gpaAlloc, .resize = gpaResize, .remap = gpaRemap, .free = gpaFree },
};

// ---------------------------------------------------------------------------
// Scratch (mark/release) allocator
// ---------------------------------------------------------------------------

pub const Scratch = struct {
    chunks: [48]?[]u8 = @splat(null),
    cur: usize = 0,
    off: usize = 0,

    pub const Mark = struct { cur: usize, off: usize };

    pub fn mark(self: *Scratch) Mark {
        return .{ .cur = self.cur, .off = self.off };
    }

    pub fn release(self: *Scratch, m: Mark) void {
        self.cur = m.cur;
        self.off = m.off;
    }

    pub fn allocator(self: *Scratch) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = sAlloc, .resize = sResize, .remap = sRemap, .free = sFree } };
    }

    fn chunkSize(i: usize) usize {
        const base: usize = 256 * 1024;
        return base << @intCast(@min(i, 12));
    }

    fn sAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        const a = alignment.toByteUnits();
        while (true) {
            if (self.chunks[self.cur]) |chunk| {
                const base = @intFromPtr(chunk.ptr);
                const start = std.mem.alignForward(usize, base + self.off, a);
                if (start + len <= base + chunk.len) {
                    self.off = start + len - base;
                    return @ptrFromInt(start);
                }
                // move to next chunk
                if (self.cur + 1 >= self.chunks.len) return null;
                self.cur += 1;
                self.off = 0;
                if (self.chunks[self.cur]) |next| {
                    if (next.len < len + a) {
                        page.free(next);
                        self.chunks[self.cur] = null;
                    }
                }
            }
            if (self.chunks[self.cur] == null) {
                const size = @max(chunkSize(self.cur), std.mem.alignForward(usize, len + a, 4096));
                self.chunks[self.cur] = page.alloc(u8, size) catch return null;
                self.off = 0;
            }
        }
    }

    fn isLast(self: *Scratch, memory: []u8) bool {
        const chunk = self.chunks[self.cur] orelse return false;
        return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(chunk.ptr) + self.off;
    }

    fn sResize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            if (self.isLast(memory)) self.off -= memory.len - new_len;
            return true;
        }
        if (!self.isLast(memory)) return false;
        const chunk = self.chunks[self.cur].?;
        const end = @intFromPtr(memory.ptr) + new_len;
        if (end > @intFromPtr(chunk.ptr) + chunk.len) return false;
        self.off = end - @intFromPtr(chunk.ptr);
        return true;
    }

    fn sRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if (sResize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
        return null;
    }

    fn sFree(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (self.isLast(memory)) self.off -= memory.len;
    }
};
