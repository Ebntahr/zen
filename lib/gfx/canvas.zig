//! `Canvas` (a borrowed view of a pixel buffer), owned `Image`s, span
//! compositing primitives and image blits.
//!
//! All drawing is src-over compositing of premultiplied ARGB pixels and is
//! restricted to `Canvas.clip`. Higher-level operations (shapes, paths,
//! effects, glass) live in their own files but are also exposed as `Canvas`
//! methods for convenience.

const std = @import("std");
const color_mod = @import("color.zig");
const geom = @import("geom.zig");
const paint_mod = @import("paint.zig");
const shapes = @import("shapes.zig");
const path_mod = @import("path.zig");
const effects = @import("effects.zig");
const glass = @import("glass.zig");

const Color = color_mod.Color;
const Rect = geom.Rect;
const Paint = paint_mod.Paint;

/// What to fill with: a solid color or a paint (gradient). Built from the
/// `fill: anytype` argument accepted by drawing functions, which may be a
/// `u32` color, an integer literal, a `*const Paint` or a `Source`.
pub const Source = union(enum) {
    solid: u32,
    paint: *const Paint,

    pub fn from(fill: anytype) Source {
        const T = @TypeOf(fill);
        if (T == Source) return fill;
        if (T == u32 or T == comptime_int) return .{ .solid = fill };
        if (T == *const Paint or T == *Paint) {
            return switch (fill.*) {
                .solid => |c| .{ .solid = c },
                else => .{ .paint = fill },
            };
        }
        @compileError("fill must be a u32 color, *const Paint or Source, got " ++ @typeName(T));
    }

    pub fn colorAt(s: Source, x: i32, y: i32) u32 {
        return switch (s) {
            .solid => |c| c,
            .paint => |p| p.colorAt(x, y),
        };
    }
};

/// A view into a 32-bit premultiplied ARGB pixel buffer. Cheap to copy.
pub const Canvas = struct {
    pixels: [*]u32,
    width: i32,
    height: i32,
    /// Distance between rows, in pixels.
    stride: i32,
    /// Drawing is limited to this rectangle (always inside the bounds).
    clip: Rect,

    /// Wraps `pixels` (at least `stride * height` entries).
    pub fn init(pixels: []u32, width: u32, height: u32, stride: u32) Canvas {
        std.debug.assert(stride >= width and pixels.len >= @as(usize, stride) * height);
        const w: i32 = @intCast(width);
        const h: i32 = @intCast(height);
        return .{ .pixels = pixels.ptr, .width = w, .height = h, .stride = @intCast(stride), .clip = Rect.init(0, 0, w, h) };
    }

    pub fn bounds(c: Canvas) Rect {
        return Rect.init(0, 0, c.width, c.height);
    }

    /// A view of `r` (clipped to the bounds); coordinates in the view are relative to `r`.
    pub fn sub(c: Canvas, r: Rect) Canvas {
        const rr = r.intersect(c.bounds());
        if (rr.isEmpty()) return .{ .pixels = c.pixels, .width = 0, .height = 0, .stride = c.stride, .clip = Rect.empty };
        return .{
            .pixels = c.pixels + @as(usize, @intCast(rr.y * c.stride + rr.x)),
            .width = rr.w,
            .height = rr.h,
            .stride = c.stride,
            .clip = c.clip.intersect(rr).offset(-rr.x, -rr.y),
        };
    }

    /// The same view with its clip further restricted to `r`.
    pub fn withClip(c: Canvas, r: Rect) Canvas {
        var out = c;
        out.clip = c.clip.intersect(r);
        return out;
    }

    /// Pointer to the first pixel of row `y` (no bounds check).
    pub inline fn row(c: Canvas, y: i32) [*]u32 {
        return c.pixels + @as(usize, @intCast(y)) * @as(usize, @intCast(c.stride));
    }

    /// Pixels `[x0, x1)` of row `y` (no bounds check).
    pub inline fn span(c: Canvas, y: i32, x0: i32, x1: i32) []u32 {
        return c.row(y)[@intCast(x0)..@intCast(x1)];
    }

    /// Pixel value, or transparent outside the bounds.
    pub fn getPixel(c: Canvas, x: i32, y: i32) u32 {
        if (!c.bounds().contains(x, y)) return 0;
        return c.row(y)[@intCast(x)];
    }

    /// Stores `color` (no blending) if inside the clip.
    pub fn setPixel(c: Canvas, x: i32, y: i32, color: u32) void {
        if (c.clip.contains(x, y)) c.row(y)[@intCast(x)] = color;
    }

    /// Composites `fill` at pixel (x, y) with coverage `cov` (0..255), if inside the clip.
    pub fn blendPixel(c: Canvas, x: i32, y: i32, cov: u8, src: Source) void {
        if (cov == 0 or !c.clip.contains(x, y)) return;
        const p = &c.row(y)[@intCast(x)];
        const s = src.colorAt(x, y);
        p.* = Color.over(if (cov == 255) s else Color.mulAlpha(s, cov), p.*);
    }

    /// Sets every pixel in the clip to `color` (replace, not blend).
    pub fn clear(c: Canvas, color: u32) void {
        var y = c.clip.y;
        while (y < c.clip.bottom()) : (y += 1) @memset(c.span(y, c.clip.x, c.clip.right()), color);
    }

    /// Fills `r` with `fill` (color or `*const Paint`) using src-over.
    pub fn fillRect(c: Canvas, r: Rect, fill: anytype) void {
        const src = Source.from(fill);
        const rr = r.intersect(c.clip);
        var y = rr.y;
        while (y < rr.bottom()) : (y += 1) fillSpan(c, y, rr.x, rr.right(), 255, src);
    }

    /// Composites run `[x0, x1)` of row `y` with constant coverage. Clipped.
    pub fn fillSpan(c: Canvas, y: i32, x0_: i32, x1_: i32, cov: u8, src: Source) void {
        if (cov == 0 or y < c.clip.y or y >= c.clip.bottom()) return;
        const x0 = @max(x0_, c.clip.x);
        const x1 = @min(x1_, c.clip.right());
        if (x0 >= x1) return;
        const dst = c.span(y, x0, x1);
        switch (src) {
            .solid => |col| fillSolid(dst, col, cov),
            .paint => |p| {
                var buf: [128]u32 = undefined;
                var i: usize = 0;
                while (i < dst.len) {
                    const n: usize = @min(buf.len, dst.len - i);
                    p.shadeRow(x0 + @as(i32, @intCast(i)), y, buf[0..n]);
                    blendRun(dst[i..][0..n], buf[0..n], cov);
                    i += n;
                }
            },
        }
    }

    /// Composites run starting at `x0` on row `y` with per-pixel coverage `covs`. Clipped.
    pub fn fillMaskSpan(c: Canvas, y: i32, x0_: i32, covs_: []const u8, src: Source) void {
        if (y < c.clip.y or y >= c.clip.bottom()) return;
        var x0 = x0_;
        var covs = covs_;
        if (x0 < c.clip.x) {
            const skip: usize = @intCast(@min(c.clip.x - x0, @as(i32, @intCast(covs.len))));
            covs = covs[skip..];
            x0 += @intCast(skip);
        }
        const avail = c.clip.right() - x0;
        if (avail <= 0 or covs.len == 0) return;
        if (covs.len > avail) covs = covs[0..@intCast(avail)];
        const dst = c.span(y, x0, x0 + @as(i32, @intCast(covs.len)));
        switch (src) {
            .solid => |col| {
                const is_opaque = col >> 24 == 255;
                for (dst, covs) |*d, a| {
                    if (a == 255 and is_opaque) {
                        d.* = col;
                    } else if (a != 0) {
                        d.* = Color.over(Color.mulAlpha(col, a), d.*);
                    }
                }
            },
            .paint => |p| {
                var buf: [128]u32 = undefined;
                var i: usize = 0;
                while (i < dst.len) {
                    const n: usize = @min(buf.len, dst.len - i);
                    p.shadeRow(x0 + @as(i32, @intCast(i)), y, buf[0..n]);
                    for (dst[i..][0..n], buf[0..n], covs[i..][0..n]) |*d, s, a| {
                        if (a != 0) d.* = Color.over(if (a == 255) s else Color.mulAlpha(s, a), d.*);
                    }
                    i += n;
                }
            },
        }
    }

    /// Composites `src` (its full bounds) at (x, y), src-over.
    pub fn blit(dst: Canvas, src: Canvas, x: i32, y: i32) void {
        drawImage(dst, src, x, y, 255);
    }

    /// Composites `src` at (x, y) scaled by `opacity` (0..255).
    pub fn drawImage(dst: Canvas, src: Canvas, x: i32, y: i32, opacity: u8) void {
        if (opacity == 0) return;
        const r = Rect.init(x, y, src.width, src.height).intersect(dst.clip);
        var yy = r.y;
        while (yy < r.bottom()) : (yy += 1) {
            const d = dst.span(yy, r.x, r.right());
            const s = src.span(yy - y, r.x - x, r.right() - x);
            if (opacity == 255) {
                for (d, s) |*dp, sp| dp.* = Color.over(sp, dp.*);
            } else {
                for (d, s) |*dp, sp| dp.* = Color.over(Color.mulAlpha(sp, opacity), dp.*);
            }
        }
    }

    /// Copies `src` at (x, y) without blending. `src` and `dst` may be
    /// overlapping views of the same buffer (e.g. for scrolling).
    pub fn blitOpaque(dst: Canvas, src: Canvas, x: i32, y: i32) void {
        const r = Rect.init(x, y, src.width, src.height).intersect(dst.clip);
        if (r.isEmpty()) return;
        // Walk rows away from the overlap so no source row is overwritten early.
        const down = @intFromPtr(dst.row(r.y)) <= @intFromPtr(src.row(r.y - y));
        var i: i32 = 0;
        while (i < r.h) : (i += 1) {
            const yy = if (down) r.y + i else r.bottom() - 1 - i;
            const d = dst.span(yy, r.x, r.right());
            const s = src.span(yy - y, r.x - x, r.right() - x);
            if (@intFromPtr(d.ptr) <= @intFromPtr(s.ptr)) {
                std.mem.copyForwards(u32, d, s);
            } else {
                std.mem.copyBackwards(u32, d, s);
            }
        }
    }

    /// Composites `src` stretched to `dst_rect` with bilinear filtering.
    pub fn blitScaled(dst: Canvas, src: Canvas, dst_rect: Rect) void {
        drawImageScaled(dst, src, dst_rect, 255);
    }

    /// Bilinear scaled composite of `src` into `dst_rect` with `opacity`.
    pub fn drawImageScaled(dst: Canvas, src: Canvas, dst_rect: Rect, opacity: u8) void {
        if (dst_rect.isEmpty() or src.width <= 0 or src.height <= 0 or opacity == 0) return;
        const r = dst_rect.intersect(dst.clip);
        if (r.isEmpty()) return;
        // 16.16 source step and start (pixel-center aligned).
        const step_x: i64 = @divTrunc(@as(i64, src.width) << 16, dst_rect.w);
        const step_y: i64 = @divTrunc(@as(i64, src.height) << 16, dst_rect.h);
        const start_x: i64 = @divTrunc(step_x, 2) - 32768 + step_x * (r.x - dst_rect.x);
        var fy: i64 = @divTrunc(step_y, 2) - 32768 + step_y * (r.y - dst_rect.y);
        var yy = r.y;
        while (yy < r.bottom()) : (yy += 1) {
            const d = dst.span(yy, r.x, r.right());
            var fx = start_x;
            for (d) |*dp| {
                var s = src.sampleBilinear16(fx, fy);
                if (opacity != 255) s = Color.mulAlpha(s, opacity);
                dp.* = Color.over(s, dp.*);
                fx += step_x;
            }
            fy += step_y;
        }
    }

    /// Bilinear sample at 16.16 fixed-point coordinates, where `k << 16`
    /// addresses the center of pixel `k`. Edges are clamped.
    pub fn sampleBilinear16(c: Canvas, fx: i64, fy: i64) u32 {
        if (c.width <= 0 or c.height <= 0) return 0;
        const ix: i32 = @intCast(std.math.clamp(fx >> 16, -1, c.width));
        const iy: i32 = @intCast(std.math.clamp(fy >> 16, -1, c.height));
        const wx: u32 = @intCast(((fx & 0xFFFF) + 128) >> 8);
        const wy: u32 = @intCast(((fy & 0xFFFF) + 128) >> 8);
        const x0: usize = @intCast(std.math.clamp(ix, 0, c.width - 1));
        const x1: usize = @intCast(std.math.clamp(ix + 1, 0, c.width - 1));
        const r0 = c.row(std.math.clamp(iy, 0, c.height - 1));
        const r1 = c.row(std.math.clamp(iy + 1, 0, c.height - 1));
        return lerpPixel(lerpPixel(r0[x0], r0[x1], wx), lerpPixel(r1[x0], r1[x1], wx), wy);
    }

    /// Composites an 8-bit alpha mask (row stride `w`) at (x, y), tinted by `fill`.
    pub fn blitMask(c: Canvas, mask: []const u8, w: u32, h: u32, x: i32, y: i32, fill: anytype) void {
        const src = Source.from(fill);
        std.debug.assert(mask.len >= @as(usize, w) * h);
        for (0..h) |my| {
            c.fillMaskSpan(y + @as(i32, @intCast(my)), x, mask[my * w ..][0..w], src);
        }
    }

    // Shapes (shapes.zig)
    pub const fillRoundRect = shapes.fillRoundRect;
    pub const strokeRoundRect = shapes.strokeRoundRect;
    pub const fillRRect = shapes.fillRRect;
    pub const strokeRRect = shapes.strokeRRect;
    pub const fillCircle = shapes.fillCircle;
    pub const strokeCircle = shapes.strokeCircle;
    pub const fillEllipse = shapes.fillEllipse;
    pub const strokeEllipse = shapes.strokeEllipse;
    pub const drawLine = shapes.drawLine;
    pub const drawLineCap = shapes.drawLineCap;

    // Paths (path.zig)
    pub const fillPath = path_mod.fillPath;
    pub const strokePath = path_mod.strokePath;

    // Effects (effects.zig)
    pub const blur = effects.blur;
    pub const blurFast = effects.blurFast;
    pub const adjustColors = effects.adjustColors;
    pub const drawShadow = effects.drawShadow;
    pub const drawInnerShadow = effects.drawInnerShadow;

    // Liquid Glass (glass.zig)
    pub const drawGlass = glass.drawGlass;
    pub const drawGlassCapsule = glass.drawGlassCapsule;
    pub const drawGlassRRect = glass.drawGlassRRect;
};

/// Solid color run with constant coverage.
fn fillSolid(dst: []u32, col: u32, cov: u8) void {
    const s = if (cov == 255) col else Color.mulAlpha(col, cov);
    const a = s >> 24;
    if (a == 255) return @memset(dst, s);
    if (s == 0) return;
    const inv: u8 = @intCast(255 - a);
    for (dst) |*d| d.* = s + Color.mulAlpha(d.*, inv);
}

/// src-over of a run of colors with constant coverage.
fn blendRun(dst: []u32, src: []const u32, cov: u8) void {
    if (cov == 255) {
        for (dst, src) |*d, s| d.* = Color.over(s, d.*);
    } else {
        for (dst, src) |*d, s| d.* = Color.over(Color.mulAlpha(s, cov), d.*);
    }
}

/// Per-channel interpolation `a + (b - a) * w / 256`, `w` in `[0, 256]`.
pub inline fn lerpPixel(a: u32, b: u32, w: u32) u32 {
    const iw = 256 - w;
    const rb = (((a & 0x00FF00FF) * iw + (b & 0x00FF00FF) * w + 0x00800080) >> 8) & 0x00FF00FF;
    const ag = (((a >> 8) & 0x00FF00FF) * iw + ((b >> 8) & 0x00FF00FF) * w + 0x00800080) & 0xFF00FF00;
    return rb | ag;
}

/// An owned pixel buffer.
pub const Image = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    /// Allocates a transparent image.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const px = try allocator.alloc(u32, @as(usize, width) * height);
        @memset(px, 0);
        return .{ .pixels = px, .width = width, .height = height };
    }

    pub fn deinit(img: *Image, allocator: std.mem.Allocator) void {
        allocator.free(img.pixels);
        img.* = undefined;
    }

    /// Allocates a copy of `src`'s pixels.
    pub fn fromCanvas(allocator: std.mem.Allocator, src: Canvas) !Image {
        var img = try init(allocator, @intCast(src.width), @intCast(src.height));
        img.canvas().blitOpaque(src, 0, 0);
        return img;
    }

    pub fn canvas(img: Image) Canvas {
        return Canvas.init(img.pixels, img.width, img.height, img.width);
    }
};

test "canvas fillRect opaque and blended, clipping" {
    var buf: [16 * 8]u32 = undefined;
    const c = Canvas.init(&buf, 16, 8, 16);
    c.clear(Color.black);
    c.fillRect(Rect.init(-4, -4, 8, 8), Color.white);
    try std.testing.expectEqual(Color.white, buf[0]);
    try std.testing.expectEqual(Color.white, buf[3 * 16 + 3]);
    try std.testing.expectEqual(Color.black, buf[4 * 16 + 4]);
    c.fillRect(Rect.init(8, 0, 100, 100), Color.rgba(255, 255, 255, 128));
    try std.testing.expectEqual(@as(u32, 0xFF808080), buf[7 * 16 + 15]);

    const clipped = c.withClip(Rect.init(0, 0, 2, 2));
    clipped.fillRect(Rect.init(0, 0, 16, 8), Color.rgb(255, 0, 0));
    try std.testing.expectEqual(Color.rgb(255, 0, 0), buf[16 + 1]);
    try std.testing.expectEqual(Color.white, buf[2]);
}

test "sub-view addresses the right pixels" {
    var buf: [10 * 10]u32 = [_]u32{0} ** 100;
    const c = Canvas.init(&buf, 10, 10, 10);
    const s = c.sub(Rect.init(3, 4, 5, 5));
    try std.testing.expectEqual(@as(i32, 5), s.width);
    s.fillRect(Rect.init(0, 0, 1, 1), Color.white);
    s.fillRect(Rect.init(4, 4, 10, 10), Color.white);
    try std.testing.expectEqual(Color.white, buf[4 * 10 + 3]);
    try std.testing.expectEqual(Color.white, buf[8 * 10 + 7]);
    try std.testing.expectEqual(@as(u32, 0), buf[9 * 10 + 8]);
}

test "blit, blitScaled and blitMask" {
    const a = std.testing.allocator;
    var src = try Image.init(a, 4, 4);
    defer src.deinit(a);
    src.canvas().clear(Color.rgb(200, 100, 50));
    var dst = try Image.init(a, 8, 8);
    defer dst.deinit(a);
    const dc = dst.canvas();
    dc.clear(Color.black);
    dc.blit(src.canvas(), 6, 6);
    try std.testing.expectEqual(Color.rgb(200, 100, 50), dst.pixels[7 * 8 + 7]);
    try std.testing.expectEqual(Color.black, dst.pixels[5 * 8 + 5]);
    // Scaling a uniform image reproduces the color exactly.
    dc.clear(Color.black);
    dc.blitScaled(src.canvas(), Rect.init(0, 0, 8, 8));
    for (dst.pixels) |p| try std.testing.expectEqual(Color.rgb(200, 100, 50), p);
    // Mask: 0 leaves dst, 255 writes color, 128 blends halfway.
    dc.clear(Color.black);
    const mask = [_]u8{ 0, 128, 255 };
    dc.blitMask(&mask, 3, 1, 0, 0, Color.white);
    try std.testing.expectEqual(Color.black, dst.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF808080), dst.pixels[1]);
    try std.testing.expectEqual(Color.white, dst.pixels[2]);
}

test "blitOpaque handles overlapping views (scrolling)" {
    var buf: [6 * 6]u32 = undefined;
    for (&buf, 0..) |*p, i| p.* = @intCast(i);
    const c = Canvas.init(&buf, 6, 6, 6);
    // Scroll the bottom 5 rows up by one, and the right 5 columns left by one.
    c.blitOpaque(c.sub(Rect.init(0, 1, 6, 5)), 0, 0);
    for (0..5) |yy| for (0..6) |xx| try std.testing.expectEqual(@as(u32, @intCast((yy + 1) * 6 + xx)), buf[yy * 6 + xx]);
    var buf2: [6 * 6]u32 = undefined;
    for (&buf2, 0..) |*p, i| p.* = @intCast(i);
    const c2 = Canvas.init(&buf2, 6, 6, 6);
    c2.blitOpaque(c2.sub(Rect.init(0, 0, 5, 6)), 1, 0); // shift right by one
    for (0..6) |yy| for (1..6) |xx| try std.testing.expectEqual(@as(u32, @intCast(yy * 6 + xx - 1)), buf2[yy * 6 + xx]);
}

test "lerpPixel endpoints" {
    try std.testing.expectEqual(@as(u32, 0x11223344), lerpPixel(0x11223344, 0xFFFFFFFF, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), lerpPixel(0x11223344, 0xFFFFFFFF, 256));
}
