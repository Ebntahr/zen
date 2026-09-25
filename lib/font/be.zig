//! Bounds-checked big-endian readers for OpenType data.
//!
//! Every accessor returns `null` instead of reading out of bounds, so parsers
//! can turn malformed input into errors (or "no data") with `orelse`.

const std = @import("std");

pub inline fn u8At(d: []const u8, off: usize) ?u8 {
    return if (off < d.len) d[off] else null;
}

pub inline fn u16At(d: []const u8, off: usize) ?u16 {
    if (off > d.len or d.len - off < 2) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

pub inline fn i16At(d: []const u8, off: usize) ?i16 {
    if (off > d.len or d.len - off < 2) return null;
    return std.mem.readInt(i16, d[off..][0..2], .big);
}

pub inline fn u32At(d: []const u8, off: usize) ?u32 {
    if (off > d.len or d.len - off < 4) return null;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

/// Returns `d[off .. off + len]`, or null if that range is out of bounds.
pub inline fn slice(d: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > d.len or d.len - off < len) return null;
    return d[off..][0..len];
}

/// Reads a 2.14 fixed-point number as f32.
pub inline fn f2dot14At(d: []const u8, off: usize) ?f32 {
    const v = i16At(d, off) orelse return null;
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

test "bounds checks" {
    const d = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a };
    try std.testing.expectEqual(@as(?u16, 0x1234), u16At(&d, 0));
    try std.testing.expectEqual(@as(?u32, 0x3456789a), u32At(&d, 1));
    try std.testing.expectEqual(@as(?u16, null), u16At(&d, 4));
    try std.testing.expectEqual(@as(?u32, null), u32At(&d, 2));
    try std.testing.expectEqual(@as(?u16, null), u16At(&d, std.math.maxInt(usize)));
    try std.testing.expect(slice(&d, 3, 3) == null);
    try std.testing.expectEqual(@as(usize, 2), slice(&d, 3, 2).?.len);
    try std.testing.expectEqual(@as(?f32, -2.0), f2dot14At(&[_]u8{ 0x80, 0x00 }, 0));
}
