//! Fill sources: solid colors, linear / radial gradients and image patterns.
//!
//! Gradients are baked into a 256-entry premultiplied lookup table and are
//! shaded with 8.8 fixed-point interpolation plus a 4x4 ordered dither between
//! adjacent LUT entries, which hides banding on large, subtle gradients.

const std = @import("std");
const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const PointF = geom.PointF;
const RectF = geom.RectF;

/// A color stop at `pos` in `[0, 1]`; `color` is premultiplied ARGB.
pub const GradientStop = struct {
    pos: f32,
    color: u32,
};

/// 4x4 Bayer matrix scaled to `[0, 255]` thresholds.
const bayer4 = [16]u8{ 8, 136, 40, 168, 200, 72, 232, 104, 56, 184, 24, 152, 248, 120, 216, 88 };

inline fn ditherThreshold(x: i32, y: i32) u32 {
    return bayer4[@as(usize, @intCast(y & 3)) * 4 + @as(usize, @intCast(x & 3))];
}

/// A baked color ramp.
pub const Gradient = struct {
    lut: [256]u32,
    is_opaque: bool,

    /// Bakes `stops` (sorted by position; at least one) into a lookup table.
    /// Interpolation happens in premultiplied space.
    pub fn init(stops: []const GradientStop) Gradient {
        std.debug.assert(stops.len > 0);
        var g: Gradient = .{ .lut = undefined, .is_opaque = true };
        var si: usize = 0;
        for (&g.lut, 0..) |*entry, i| {
            const t = @as(f32, @floatFromInt(i)) / 255.0;
            while (si + 1 < stops.len and stops[si + 1].pos < t) si += 1;
            const a = stops[si];
            const b = stops[@min(si + 1, stops.len - 1)];
            var f: f32 = 0;
            if (t <= a.pos) {
                f = 0;
            } else if (b.pos > a.pos) {
                f = std.math.clamp((t - a.pos) / (b.pos - a.pos), 0.0, 1.0);
            } else {
                f = 1;
            }
            entry.* = mixF(a.color, b.color, f);
            if (entry.* >> 24 != 255) g.is_opaque = false;
        }
        return g;
    }

    /// Color at fixed-point position `t` (`0` .. `255 * 256`) with ordered dithering.
    inline fn sample(g: *const Gradient, t: i32, x: i32, y: i32) u32 {
        const tc: u32 = @intCast(std.math.clamp(t, 0, 255 * 256));
        var idx = tc >> 8;
        if ((tc & 0xFF) > ditherThreshold(x, y) and idx < 255) idx += 1;
        return g.lut[idx];
    }
};

fn mixF(a: u32, b: u32, f: f32) u32 {
    var out: u32 = 0;
    inline for (0..4) |i| {
        const sh: u5 = @intCast(i * 8);
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(@round(ca + (cb - ca) * f));
        out |= @as(u32, @min(v, 255)) << sh;
    }
    return out;
}

/// Linear gradient along the segment `p0 -> p1` (padded beyond the ends).
pub const LinearGradient = struct {
    gradient: Gradient,
    x0: f32,
    y0: f32,
    /// Gradient of `t` per pixel in x / y.
    dx: f32,
    dy: f32,

    pub fn init(p0: PointF, p1: PointF, stops: []const GradientStop) LinearGradient {
        const vx = p1.x - p0.x;
        const vy = p1.y - p0.y;
        const len2 = @max(vx * vx + vy * vy, 1e-6);
        return .{ .gradient = Gradient.init(stops), .x0 = p0.x, .y0 = p0.y, .dx = vx / len2, .dy = vy / len2 };
    }

    /// Gradient spanning `rect` at `angle_deg` (CSS convention: 0 = bottom->top, 90 = left->right, 180 = top->bottom).
    pub fn angled(rect: RectF, angle_deg: f32, stops: []const GradientStop) LinearGradient {
        const a = angle_deg * std.math.pi / 180.0;
        const dirx = @sin(a);
        const diry = -@cos(a);
        const half = (@abs(rect.w * dirx) + @abs(rect.h * diry)) * 0.5;
        const c = rect.center();
        return init(
            .{ .x = c.x - dirx * half, .y = c.y - diry * half },
            .{ .x = c.x + dirx * half, .y = c.y + diry * half },
            stops,
        );
    }

    /// Vertical gradient from the top to the bottom of `rect`.
    pub fn vertical(rect: RectF, stops: []const GradientStop) LinearGradient {
        return init(.{ .x = rect.x, .y = rect.y }, .{ .x = rect.x, .y = rect.bottom() }, stops);
    }

    inline fn tAt(g: *const LinearGradient, x: f32, y: f32) f32 {
        return (x - g.x0) * g.dx + (y - g.y0) * g.dy;
    }
};

/// Radial (optionally elliptical) gradient: `t = 0` at the center, `1` at the radius.
pub const RadialGradient = struct {
    gradient: Gradient,
    cx: f32,
    cy: f32,
    inv_rx: f32,
    inv_ry: f32,

    pub fn init(center: PointF, radius: f32, stops: []const GradientStop) RadialGradient {
        return elliptical(center, radius, radius, stops);
    }

    pub fn elliptical(center: PointF, rx: f32, ry: f32, stops: []const GradientStop) RadialGradient {
        return .{
            .gradient = Gradient.init(stops),
            .cx = center.x,
            .cy = center.y,
            .inv_rx = 1.0 / @max(rx, 1e-3),
            .inv_ry = 1.0 / @max(ry, 1e-3),
        };
    }

    inline fn tAt(g: *const RadialGradient, x: f32, y: f32) f32 {
        const u = (x - g.cx) * g.inv_rx;
        const v = (y - g.cy) * g.inv_ry;
        return @sqrt(u * u + v * v);
    }
};

/// An image used as a fill (bilinear, edges clamped), e.g. for rounded thumbnails.
pub const ImagePattern = struct {
    src: Canvas,
    /// Destination position of the source's top-left corner.
    x: f32,
    y: f32,
    /// Source pixels per destination pixel.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    opacity: u8 = 255,

    /// Stretches `src` over `rect`.
    pub fn fit(src: Canvas, rect: RectF) ImagePattern {
        return .{
            .src = src,
            .x = rect.x,
            .y = rect.y,
            .scale_x = @as(f32, @floatFromInt(src.width)) / rect.w,
            .scale_y = @as(f32, @floatFromInt(src.height)) / rect.h,
        };
    }

    /// Scales `src` uniformly to cover `rect` (cropping the overflow), centered.
    pub fn cover(src: Canvas, rect: RectF) ImagePattern {
        const sw: f32 = @floatFromInt(src.width);
        const sh: f32 = @floatFromInt(src.height);
        const k = @min(sw / rect.w, sh / rect.h);
        return .{
            .src = src,
            .x = rect.x + (rect.w - sw / k) * 0.5,
            .y = rect.y + (rect.h - sh / k) * 0.5,
            .scale_x = k,
            .scale_y = k,
        };
    }

    inline fn fixedX(p: *const ImagePattern, x: i32) i64 {
        return @intFromFloat(((@as(f32, @floatFromInt(x)) + 0.5 - p.x) * p.scale_x - 0.5) * 65536.0);
    }
    inline fn fixedY(p: *const ImagePattern, y: i32) i64 {
        return @intFromFloat(((@as(f32, @floatFromInt(y)) + 0.5 - p.y) * p.scale_y - 0.5) * 65536.0);
    }
};

/// A fill source. Pass by pointer: gradients carry a 1 KiB lookup table.
pub const Paint = union(enum) {
    solid: u32,
    linear: LinearGradient,
    radial: RadialGradient,
    image: ImagePattern,

    pub fn linearGradient(p0: PointF, p1: PointF, stops: []const GradientStop) Paint {
        return .{ .linear = LinearGradient.init(p0, p1, stops) };
    }
    pub fn angledGradient(rect: RectF, angle_deg: f32, stops: []const GradientStop) Paint {
        return .{ .linear = LinearGradient.angled(rect, angle_deg, stops) };
    }
    pub fn verticalGradient(rect: RectF, stops: []const GradientStop) Paint {
        return .{ .linear = LinearGradient.vertical(rect, stops) };
    }
    pub fn radialGradient(center: PointF, radius: f32, stops: []const GradientStop) Paint {
        return .{ .radial = RadialGradient.init(center, radius, stops) };
    }

    /// True when every produced color is fully opaque.
    pub fn isOpaque(p: *const Paint) bool {
        return switch (p.*) {
            .solid => |c| c >> 24 == 255,
            .linear => |*g| g.gradient.is_opaque,
            .radial => |*g| g.gradient.is_opaque,
            .image => false,
        };
    }

    /// Color of the pixel at integer coordinates (sampled at the pixel center).
    pub fn colorAt(p: *const Paint, x: i32, y: i32) u32 {
        const fx = @as(f32, @floatFromInt(x)) + 0.5;
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        return switch (p.*) {
            .solid => |c| c,
            .linear => |*g| g.gradient.sample(toFixed(g.tAt(fx, fy)), x, y),
            .radial => |*g| g.gradient.sample(toFixed(g.tAt(fx, fy)), x, y),
            .image => |*im| Color.mulAlpha(im.src.sampleBilinear16(im.fixedX(x), im.fixedY(y)), im.opacity),
        };
    }

    /// Writes the colors of pixels `x .. x + out.len` on row `y` into `out`.
    pub fn shadeRow(p: *const Paint, x: i32, y: i32, out: []u32) void {
        switch (p.*) {
            .solid => |c| @memset(out, c),
            .linear => |*g| {
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const t0 = g.tAt(@as(f32, @floatFromInt(x)) + 0.5, fy);
                // 16.16 fixed point in LUT units, stepped incrementally along the row.
                const scale = 255.0 * 65536.0;
                var t: i64 = @intFromFloat(std.math.clamp(t0, -1e6, 1e6) * scale);
                const dt: i64 = @intFromFloat(std.math.clamp(g.dx, -1e3, 1e3) * scale);
                for (out, 0..) |*o, i| {
                    const tc: i32 = @intCast(std.math.clamp(t >> 8, -65536, 2 * 65536));
                    o.* = g.gradient.sample(tc, x + @as(i32, @intCast(i)), y);
                    t += dt;
                }
            },
            .radial => |*g| {
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                var fx = @as(f32, @floatFromInt(x)) + 0.5;
                for (out, 0..) |*o, i| {
                    o.* = g.gradient.sample(toFixed(g.tAt(fx, fy)), x + @as(i32, @intCast(i)), y);
                    fx += 1;
                }
            },
            .image => |*im| {
                var sx = im.fixedX(x);
                const sy = im.fixedY(y);
                const step: i64 = @intFromFloat(im.scale_x * 65536.0);
                for (out) |*o| {
                    o.* = im.src.sampleBilinear16(sx, sy);
                    sx += step;
                }
                if (im.opacity != 255) for (out) |*o| {
                    o.* = Color.mulAlpha(o.*, im.opacity);
                };
            },
        }
    }
};

/// Maps `t` in `[0, 1]` to 8.8 fixed point LUT units, clamped to a safe range.
inline fn toFixed(t: f32) i32 {
    return @intFromFloat(std.math.clamp(t, -1.0, 2.0) * (255.0 * 256.0));
}

test "gradient endpoints and midpoint" {
    const stops = [_]GradientStop{
        .{ .pos = 0, .color = 0xFF000000 },
        .{ .pos = 1, .color = 0xFFFFFFFF },
    };
    const g = Gradient.init(&stops);
    try std.testing.expectEqual(@as(u32, 0xFF000000), g.lut[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), g.lut[255]);
    try std.testing.expectEqual(@as(u32, 0xFF808080), g.lut[128]);
    try std.testing.expect(g.is_opaque);

    var p = Paint.linearGradient(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, &stops);
    var row: [100]u32 = undefined;
    p.shadeRow(0, 0, &row);
    try std.testing.expect(row[0] & 0xFF < 8);
    try std.testing.expect(row[99] & 0xFF > 248);
    // Monotonic within dithering tolerance.
    for (1..row.len) |i| try std.testing.expect(@as(i32, @intCast(row[i] & 0xFF)) + 2 >= @as(i32, @intCast(row[i - 1] & 0xFF)));
    try std.testing.expectEqual(p.colorAt(50, 7) & 0xFF, p.colorAt(50, 7) & 0xFF);

    var px = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    const img = Paint{ .image = ImagePattern.fit(Canvas.init(&px, 2, 1, 2), .{ .w = 20, .h = 10 }) };
    try std.testing.expectEqual(@as(u32, 0xFF000000), img.colorAt(0, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), img.colorAt(19, 5));
    var irow: [20]u32 = undefined;
    img.shadeRow(0, 3, &irow);
    try std.testing.expectEqual(img.colorAt(9, 3), irow[9]);

    const r = Paint.radialGradient(.{ .x = 0, .y = 0 }, 10, &stops);
    try std.testing.expect(r.colorAt(0, 0) & 0xFF < 24);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), r.colorAt(20, 0));
}
