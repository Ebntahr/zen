//! Premultiplied-alpha ARGB colors packed in a `u32` (0xAARRGGBB).
//!
//! In little-endian memory the byte order is B, G, R, A, matching the
//! virtio-gpu `B8G8R8A8` scanout format. Every color channel is already
//! multiplied by alpha, so a valid color always has `r, g, b <= a`.

const std = @import("std");

/// A single premultiplied ARGB pixel.
pub const Pixel = u32;

/// Namespace of helpers operating on premultiplied `u32` colors.
pub const Color = struct {
    pub const transparent: u32 = 0x00000000;
    pub const black: u32 = 0xFF000000;
    pub const white: u32 = 0xFFFFFFFF;

    /// Opaque color from 8-bit channels.
    pub inline fn rgb(r: u8, g: u8, b: u8) u32 {
        return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
    }

    /// Color from straight (non-premultiplied) channels; the result is premultiplied.
    pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
        return mulAlpha(rgb(r, g, b), a); // alpha channel: 255 * a / 255 == a exactly
    }

    /// Opaque color from a `0xRRGGBB` literal.
    pub inline fn fromHex(hex: u24) u32 {
        return 0xFF000000 | @as(u32, hex);
    }

    /// Color from `0xRRGGBB` plus a straight alpha in `[0, 1]`.
    pub fn hexAlpha(hex: u24, a: f32) u32 {
        return withAlpha(fromHex(hex), unitToByte(a));
    }

    /// Color from float channels in `[0, 1]` (straight alpha).
    pub fn rgbaF(r: f32, g: f32, b: f32, a: f32) u32 {
        return rgba(unitToByte(r), unitToByte(g), unitToByte(b), unitToByte(a));
    }

    pub inline fn alpha(c: u32) u8 {
        return @truncate(c >> 24);
    }
    pub inline fn red(c: u32) u8 {
        return @truncate(c >> 16);
    }
    pub inline fn green(c: u32) u8 {
        return @truncate(c >> 8);
    }
    pub inline fn blue(c: u32) u8 {
        return @truncate(c);
    }

    /// `c` with its opacity replaced by `a`, keeping its (straight) color.
    pub fn withAlpha(c: u32, a: u8) u32 {
        return mulAlpha(toStraight(c) | 0xFF000000, a);
    }

    /// Multiplies all four channels by `a / 255` (opacity), keeping premultiplication valid.
    pub inline fn scaleAlpha(c: u32, a: u8) u32 {
        return mulAlpha(c, a);
    }

    /// Converts a premultiplied color to straight ARGB (0xAARRGGBB, not premultiplied).
    pub fn toStraight(c: u32) u32 {
        const a: u32 = c >> 24;
        if (a == 255) return c;
        if (a == 0) return 0;
        const half = a / 2;
        const r: u32 = @min(255, (((c >> 16) & 0xFF) * 255 + half) / a);
        const g: u32 = @min(255, (((c >> 8) & 0xFF) * 255 + half) / a);
        const b: u32 = @min(255, ((c & 0xFF) * 255 + half) / a);
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    /// Source-over compositing: `src + dst * (1 - src.a)`.
    pub inline fn over(src: u32, dst: u32) u32 {
        const sa = src >> 24;
        if (sa == 255) return src;
        if (sa == 0) return dst;
        return src + mulAlpha(dst, @intCast(255 - sa));
    }

    /// Linear interpolation between `a` and `b` with `t` in `[0, 255]`.
    pub inline fn lerp8(a: u32, b: u32, t: u8) u32 {
        return mulAlpha(a, 255 - t) + mulAlpha(b, t);
    }

    /// Linear interpolation between `a` and `b` with `t` in `[0, 1]`.
    pub fn lerp(a: u32, b: u32, t: f32) u32 {
        return lerp8(a, b, unitToByte(t));
    }

    /// Multiplies each channel of `c` by `a / 255` with exact rounding.
    pub inline fn mulAlpha(c: u32, a: u8) u32 {
        const m: u32 = a;
        var rb = (c & 0x00FF00FF) * m + 0x00800080;
        rb = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
        var ag = ((c >> 8) & 0x00FF00FF) * m + 0x00800080;
        ag = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
        return rb | ag;
    }

    /// Saturating per-channel add of two premultiplied colors.
    pub fn add(a: u32, b: u32) u32 {
        var out: u32 = 0;
        inline for (0..4) |i| {
            const sh: u5 = @intCast(i * 8);
            const s = ((a >> sh) & 0xFF) + ((b >> sh) & 0xFF);
            out |= @as(u32, @min(s, 255)) << sh;
        }
        return out;
    }

    /// Relative luminance approximation (0..255) of the premultiplied channels.
    pub inline fn luma(c: u32) u8 {
        const r = (c >> 16) & 0xFF;
        const g = (c >> 8) & 0xFF;
        const b = c & 0xFF;
        return @intCast((r * 77 + g * 150 + b * 29) >> 8);
    }

    /// Maps `[0, 1]` to `[0, 255]` with rounding and clamping.
    pub inline fn unitToByte(v: f32) u8 {
        const x = std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5;
        return @intFromFloat(x);
    }
};

/// Exact `round(x / 255)` for `x` in `[0, 65535]`.
pub inline fn div255(x: u32) u32 {
    return (x + 128 + ((x + 128) >> 8)) >> 8;
}

test "div255 is exact" {
    var x: u32 = 0;
    while (x <= 255 * 255) : (x += 1) {
        const expected: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(x)) / 255.0));
        try std.testing.expectEqual(expected, div255(x));
    }
}

test "rgba premultiplies and toStraight inverts" {
    const c = Color.rgba(200, 100, 50, 128);
    try std.testing.expectEqual(@as(u8, 128), Color.alpha(c));
    try std.testing.expectEqual(@as(u8, 100), Color.red(c));
    try std.testing.expectEqual(@as(u8, 50), Color.green(c));
    try std.testing.expectEqual(@as(u8, 25), Color.blue(c));
    const s = Color.toStraight(c);
    try std.testing.expect(@abs(@as(i32, Color.red(s)) - 200) <= 1);
    try std.testing.expect(@abs(@as(i32, Color.green(s)) - 100) <= 1);
    try std.testing.expect(@abs(@as(i32, Color.blue(s)) - 50) <= 2);
    try std.testing.expectEqual(@as(u32, 0), Color.rgba(255, 255, 255, 0));
    try std.testing.expectEqual(Color.fromHex(0x123456), Color.rgb(0x12, 0x34, 0x56));
}

test "over: identities and exactness" {
    const red = Color.rgb(255, 0, 0);
    const blue = Color.rgb(0, 0, 255);
    try std.testing.expectEqual(red, Color.over(red, blue));
    try std.testing.expectEqual(blue, Color.over(Color.transparent, blue));
    // 50% white over opaque black gives mid gray, opaque.
    const half_white = Color.rgba(255, 255, 255, 128);
    const g = Color.over(half_white, Color.black);
    try std.testing.expectEqual(@as(u8, 255), Color.alpha(g));
    try std.testing.expectEqual(@as(u8, 128), Color.red(g));
    // Translucent over transparent keeps the source.
    try std.testing.expectEqual(half_white, Color.over(half_white, 0));
    // Premultiplication invariant holds for random blends.
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    for (0..2000) |_| {
        const s = Color.rgba(rnd.int(u8), rnd.int(u8), rnd.int(u8), rnd.int(u8));
        const d = Color.rgba(rnd.int(u8), rnd.int(u8), rnd.int(u8), rnd.int(u8));
        const o = Color.over(s, d);
        const a = Color.alpha(o);
        try std.testing.expect(Color.red(o) <= a and Color.green(o) <= a and Color.blue(o) <= a);
        try std.testing.expect(a >= Color.alpha(s) and a >= Color.alpha(d));
    }
}

test "lerp, scaleAlpha, withAlpha" {
    const a = Color.rgb(0, 0, 0);
    const b = Color.rgb(255, 255, 255);
    try std.testing.expectEqual(a, Color.lerp8(a, b, 0));
    try std.testing.expectEqual(b, Color.lerp8(a, b, 255));
    try std.testing.expectEqual(@as(u8, 128), Color.red(Color.lerp(a, b, 0.5)));
    try std.testing.expectEqual(@as(u32, 0x80808080), Color.scaleAlpha(Color.white, 128));
    const c = Color.withAlpha(Color.rgb(255, 0, 0), 51);
    try std.testing.expectEqual(@as(u32, 0x33330000), c);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), Color.withAlpha(c, 255));
    try std.testing.expectEqual(@as(u32, 0xFFFF8000), Color.add(0xFFFF4000, 0x00804000));
}
