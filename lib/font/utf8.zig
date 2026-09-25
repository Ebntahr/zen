//! Lenient UTF-8 decoding for text rendering.
//!
//! Invalid, overlong, surrogate or truncated sequences never fail: each
//! maximal invalid subpart decodes to U+FFFD (the Unicode/WHATWG
//! recommendation), so arbitrary bytes can always be drawn and every byte
//! index produced by the iterator is a valid caret position.

const std = @import("std");

/// U+FFFD REPLACEMENT CHARACTER.
pub const replacement: u21 = 0xFFFD;

pub const Decoded = struct {
    cp: u21,
    /// Number of bytes consumed (1...4).
    len: u3,
};

/// Decodes the code point at the start of `bytes` (which must be non-empty).
pub fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };

    var need: u3 = undefined;
    var cp: u21 = undefined;
    // Valid range of the second byte; later continuation bytes are 80..BF.
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    switch (b0) {
        0xC2...0xDF => {
            need = 1;
            cp = b0 & 0x1F;
        },
        0xE0...0xEF => {
            need = 2;
            cp = b0 & 0x0F;
            if (b0 == 0xE0) lo = 0xA0; // overlong
            if (b0 == 0xED) hi = 0x9F; // surrogates
        },
        0xF0...0xF4 => {
            need = 3;
            cp = b0 & 0x07;
            if (b0 == 0xF0) lo = 0x90; // overlong
            if (b0 == 0xF4) hi = 0x8F; // > U+10FFFF
        },
        else => return .{ .cp = replacement, .len = 1 },
    }

    var i: u3 = 1;
    while (i <= need) : (i += 1) {
        if (i >= bytes.len) return .{ .cp = replacement, .len = i };
        const b = bytes[i];
        if (b < lo or b > hi) return .{ .cp = replacement, .len = i };
        lo = 0x80;
        hi = 0xBF;
        cp = (cp << 6) | (b & 0x3F);
    }
    return .{ .cp = cp, .len = need + 1 };
}

/// Forward iterator over code points. `i` is the byte offset of the next
/// code point, so reading it before `next()` yields each character's index.
pub const Iterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(it: *Iterator) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const d = decode(it.bytes[it.i..]);
        it.i += d.len;
        return d.cp;
    }
};

/// Byte index of the character boundary following `index` (for caret movement).
pub fn nextBoundary(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return bytes.len;
    return index + decode(bytes[index..]).len;
}

/// Byte index of the character boundary preceding `index` (for caret movement).
/// Consistent with how `Iterator` splits invalid input.
pub fn prevBoundary(bytes: []const u8, index: usize) usize {
    const end = @min(index, bytes.len);
    if (end == 0) return 0;
    var b = end - 1;
    while (b > 0 and !isBoundary(bytes, b)) b -= 1;
    return b;
}

/// Whether forward decoding from the start of `bytes` lands on `index`
/// (`index < bytes.len`). A non-continuation byte always starts a character
/// and a lead byte spans at most 3 continuation bytes, so resynchronizing
/// from at most 3 bytes back gives the same answer as decoding from 0.
fn isBoundary(bytes: []const u8, index: usize) bool {
    var s = index;
    while (s > 0 and index - s < 3 and bytes[s] & 0xC0 == 0x80) s -= 1;
    while (s < index) s += decode(bytes[s..]).len;
    return s == index;
}

test "decode valid sequences" {
    const s = "aé€😀";
    var it = Iterator.init(s);
    try std.testing.expectEqual(@as(?u21, 'a'), it.next());
    try std.testing.expectEqual(@as(?u21, 0xE9), it.next());
    try std.testing.expectEqual(@as(?u21, 0x20AC), it.next());
    try std.testing.expectEqual(@as(?u21, 0x1F600), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "invalid bytes become U+FFFD" {
    // Lone continuation, overlong C0, truncated 3-byte sequence, surrogate, > U+10FFFF, 0xFF.
    const s = "\x80A\xC0\xAFB\xE2\x82C\xED\xA0\x80D\xF4\x90\x80\x80\xFF";
    var got: [32]u21 = undefined;
    var n: usize = 0;
    var it = Iterator.init(s);
    while (it.next()) |cp| : (n += 1) got[n] = cp;
    const r = replacement;
    const want = [_]u21{ r, 'A', r, r, 'B', r, 'C', r, r, r, 'D', r, r, r, r, r };
    try std.testing.expectEqualSlices(u21, &want, got[0..n]);
}

test "truncated sequence at end of input" {
    var it = Iterator.init("x\xF0\x9F\x98");
    try std.testing.expectEqual(@as(?u21, 'x'), it.next());
    try std.testing.expectEqual(@as(?u21, replacement), it.next());
    try std.testing.expectEqual(@as(usize, 4), it.i);
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "caret boundaries" {
    const s = "aé😀\x80b";
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 7), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 8), nextBoundary(s, 7));
    try std.testing.expectEqual(@as(usize, 8), prevBoundary(s, 9));
    try std.testing.expectEqual(@as(usize, 7), prevBoundary(s, 8));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(s, 7));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 0));
}
