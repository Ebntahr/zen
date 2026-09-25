//! Kernel heap: power-of-two slab allocator backed by the frame allocator.
const std = @import("std");
const riscv = @import("riscv.zig");
const pmm = @import("pmm.zig");

const PAGE = riscv.PAGE_SIZE;
const MIN_SHIFT = 4; // 16 bytes
const MAX_SHIFT = 11; // 2048 bytes
const NCLASSES = MAX_SHIFT - MIN_SHIFT + 1;

const FreeNode = struct { next: ?*FreeNode };

var free_lists: [NCLASSES]?*FreeNode = [_]?*FreeNode{null} ** NCLASSES;
pub var bytes_in_use: usize = 0;

fn classFor(len: usize, alignment: std.mem.Alignment) ?usize {
    const need = @max(len, alignment.toByteUnits(), 1 << MIN_SHIFT);
    if (need > (1 << MAX_SHIFT)) return null;
    const shift = std.math.log2_int_ceil(usize, need);
    return shift - MIN_SHIFT;
}

fn refill(class: usize) bool {
    const pa = pmm.allocFrame() catch return false;
    const base = riscv.p2v(pa);
    const size: usize = @as(usize, 1) << @intCast(class + MIN_SHIFT);
    var off: usize = 0;
    while (off + size <= PAGE) : (off += size) {
        const node: *FreeNode = @ptrFromInt(base + off);
        node.next = free_lists[class];
        free_lists[class] = node;
    }
    return true;
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (classFor(len, alignment)) |class| {
        if (free_lists[class] == null and !refill(class)) return null;
        const node = free_lists[class].?;
        free_lists[class] = node.next;
        bytes_in_use += @as(usize, 1) << @intCast(class + MIN_SHIFT);
        return @ptrCast(node);
    }
    const pages = (len + PAGE - 1) / PAGE;
    const pa = pmm.allocFrames(pages) catch return null;
    bytes_in_use += pages * PAGE;
    return @ptrFromInt(riscv.p2v(pa));
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    if (classFor(memory.len, alignment)) |class| {
        const cap: usize = @as(usize, 1) << @intCast(class + MIN_SHIFT);
        return new_len <= cap;
    }
    const pages = (memory.len + PAGE - 1) / PAGE;
    const new_pages = (new_len + PAGE - 1) / PAGE;
    if (new_pages == pages) return true;
    if (new_pages < pages and new_pages > 0) {
        const pa = riscv.v2p(@intFromPtr(memory.ptr));
        pmm.freeFrames(pa + new_pages * PAGE, pages - new_pages);
        bytes_in_use -= (pages - new_pages) * PAGE;
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ret)) return memory.ptr;
    return null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    if (classFor(memory.len, alignment)) |class| {
        const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
        node.next = free_lists[class];
        free_lists[class] = node;
        bytes_in_use -= @as(usize, 1) << @intCast(class + MIN_SHIFT);
        return;
    }
    const pages = (memory.len + PAGE - 1) / PAGE;
    pmm.freeFrames(riscv.v2p(@intFromPtr(memory.ptr)), pages);
    bytes_in_use -= pages * PAGE;
}

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub const allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &vtable };

pub fn create(comptime T: type) !*T {
    const p = try allocator.create(T);
    return p;
}

pub fn destroy(p: anytype) void {
    allocator.destroy(p);
}

pub fn dupe(s: []const u8) ![]u8 {
    return allocator.dupe(u8, s);
}
