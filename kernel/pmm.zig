//! Physical memory manager: bitmap frame allocator with per-frame refcounts.
const std = @import("std");
const riscv = @import("riscv.zig");
const console = @import("console.zig");

const PAGE = riscv.PAGE_SIZE;

var ram_base: u64 = 0;
var frame_count: u64 = 0;
var bitmap: []u64 = &.{};
var refcounts: []u16 = &.{};
var hint: u64 = 0;
pub var free_frames: u64 = 0;
pub var total_frames: u64 = 0;

extern const __kernel_end: u8;

pub const Error = error{OutOfMemory};

fn setBit(i: u64) void {
    bitmap[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}
fn clearBit(i: u64) void {
    bitmap[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
}
fn testBit(i: u64) bool {
    return (bitmap[i / 64] >> @intCast(i % 64)) & 1 != 0;
}

/// Reserve a physical range (marks frames used).
pub fn reserve(start: u64, end: u64) void {
    if (end <= ram_base) return;
    const s = @max(start, ram_base);
    var f = (s - ram_base) / PAGE;
    const last = @min((end - ram_base + PAGE - 1) / PAGE, frame_count);
    while (f < last) : (f += 1) {
        if (!testBit(f)) {
            setBit(f);
            free_frames -= 1;
        }
        refcounts[f] = 1;
    }
}

pub fn init(mem_base: u64, mem_size: u64) void {
    ram_base = mem_base;
    frame_count = mem_size / PAGE;
    total_frames = frame_count;
    // Place the bitmap + refcount array right after the kernel image.
    const kend_pa = riscv.v2p(@intFromPtr(&__kernel_end));
    const bm_words = (frame_count + 63) / 64;
    const bm_pa = std.mem.alignForward(u64, kend_pa, PAGE);
    bitmap = @as([*]u64, @ptrFromInt(riscv.p2v(bm_pa)))[0..bm_words];
    const rc_pa = std.mem.alignForward(u64, bm_pa + bm_words * 8, PAGE);
    refcounts = @as([*]u16, @ptrFromInt(riscv.p2v(rc_pa)))[0..frame_count];
    const meta_end = std.mem.alignForward(u64, rc_pa + frame_count * 2, PAGE);
    @memset(bitmap, 0);
    @memset(refcounts, 0);
    free_frames = frame_count;
    // OpenSBI firmware + kernel image + metadata.
    reserve(mem_base, meta_end);
}

pub fn allocFrame() Error!u64 {
    return allocFrames(1);
}

/// Allocate `n` physically contiguous zeroed frames.
pub fn allocFrames(n: u64) Error!u64 {
    if (n == 0 or n > free_frames) return error.OutOfMemory;
    var tries: u64 = 0;
    var i = hint;
    while (tries < frame_count) {
        if (i + n > frame_count) {
            i = 0;
        }
        // fast skip of full words
        if (n == 1 and i % 64 == 0 and bitmap[i / 64] == ~@as(u64, 0)) {
            i += 64;
            tries += 64;
            continue;
        }
        var ok = true;
        var j: u64 = 0;
        while (j < n) : (j += 1) {
            if (testBit(i + j)) {
                ok = false;
                break;
            }
        }
        if (ok) {
            j = 0;
            while (j < n) : (j += 1) {
                setBit(i + j);
                refcounts[i + j] = 1;
            }
            free_frames -= n;
            hint = i + n;
            const pa = ram_base + i * PAGE;
            @memset(@as([*]u8, @ptrFromInt(riscv.p2v(pa)))[0 .. n * PAGE], 0);
            return pa;
        }
        i += j + 1;
        tries += j + 1;
    }
    return error.OutOfMemory;
}

fn index(pa: u64) ?u64 {
    if (pa < ram_base) return null;
    const i = (pa - ram_base) / PAGE;
    if (i >= frame_count) return null;
    return i;
}

pub fn freeFrames(pa: u64, n: u64) void {
    var k: u64 = 0;
    while (k < n) : (k += 1) unref(pa + k * PAGE);
}

pub fn freeFrame(pa: u64) void {
    unref(pa);
}

/// Increase the share count of a frame (for shared mappings).
pub fn ref(pa: u64) void {
    const i = index(pa) orelse return;
    refcounts[i] +|= 1;
}

pub fn refcount(pa: u64) u16 {
    const i = index(pa) orelse return 0;
    return refcounts[i];
}

/// Drop one reference; frees the frame when the count reaches zero.
pub fn unref(pa: u64) void {
    const i = index(pa) orelse return;
    if (refcounts[i] == 0) {
        console.print("pmm: double free of {x}\n", .{pa});
        return;
    }
    refcounts[i] -= 1;
    if (refcounts[i] == 0 and testBit(i)) {
        clearBit(i);
        free_frames += 1;
        if (i < hint) hint = i;
    }
}

pub fn isRam(pa: u64) bool {
    return index(pa) != null;
}
