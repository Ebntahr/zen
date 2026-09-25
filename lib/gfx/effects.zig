//! Image effects: separable 3-pass box blur (≈ Gaussian), downsampled fast
//! blur for large radii, saturation / brightness adjustment, and soft drop /
//! inner shadows for rounded rectangles rendered from a cached, blurred
//! corner mask stretched as a 9-slice.

const std = @import("std");
const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const color_mod = @import("color.zig");
const shapes = @import("shapes.zig");

const Allocator = std.mem.Allocator;
const Canvas = canvas_mod.Canvas;
const Image = canvas_mod.Image;
const Rect = geom.Rect;
const Color = color_mod.Color;

/// Longest row / column `blur` can process (longer lines are clipped).
pub const max_blur_line = 4096;

// ---------------------------------------------------------------------------
// Box blur

/// Radii of three box filters whose convolution approximates a Gaussian of `sigma`.
pub fn boxRadii(sigma: f32) [3]u32 {
    if (!(sigma > 0.25)) return .{ 0, 0, 0 };
    const n: f32 = 3;
    const w_ideal = @sqrt(12 * sigma * sigma / n + 1);
    var wl: i32 = @intFromFloat(@floor(w_ideal));
    if (@mod(wl, 2) == 0) wl -= 1;
    const wlf: f32 = @floatFromInt(wl);
    const m_ideal = (12 * sigma * sigma - n * wlf * wlf - 4 * n * wlf - 3 * n) / (-4 * wlf - 4);
    const m: i32 = @intFromFloat(@round(m_ideal));
    var out: [3]u32 = undefined;
    for (&out, 0..) |*r, i| {
        const size = if (@as(i32, @intCast(i)) < m) wl else wl + 2;
        r.* = @intCast(@divTrunc(size - 1, 2));
    }
    return out;
}

/// Total support (in pixels) of the 3-pass blur for `sigma`.
pub fn blurExtent(sigma: f32) i32 {
    const r = boxRadii(sigma);
    return @intCast(r[0] + r[1] + r[2]);
}

// Pixels are split into two u64 accumulators holding (B, R) and (G, A) in
// 32-bit lanes, so a running sum needs 2 adds instead of 4.
inline fn expandRB(p: u32) u64 {
    return @as(u64, p & 0xFF) | (@as(u64, p & 0xFF0000) << 16);
}
inline fn expandAG(p: u32) u64 {
    return @as(u64, (p >> 8) & 0xFF) | (@as(u64, p >> 24) << 32);
}
inline fn packLanes(rb: u64, ag: u64, inv: u64) u32 {
    const round: u64 = 0x00080000_00080000;
    const lane: u64 = 0x000000FF_000000FF;
    const r = ((rb * inv + round) >> 20) & lane;
    const g = ((ag * inv + round) >> 20) & lane;
    return @as(u32, @truncate(r)) | (@as(u32, @truncate(r >> 32)) << 16) |
        (@as(u32, @truncate(g)) << 8) | (@as(u32, @truncate(g >> 32)) << 24);
}

/// One box-filter pass of radius `r` from `src` to `dst` (same length), edges clamped.
fn boxLine(src: []const u32, dst: []u32, r: usize) void {
    const n = src.len;
    if (r == 0 or n == 0) {
        @memcpy(dst, src);
        return;
    }
    const win: u64 = 2 * r + 1;
    const inv: u64 = ((1 << 20) + win / 2) / win;
    var rb: u64 = 0;
    var ag: u64 = 0;
    // Window centered on index 0 with clamped (repeated) edges.
    rb = expandRB(src[0]) * (r + 1);
    ag = expandAG(src[0]) * (r + 1);
    for (1..r + 1) |k| {
        const p = src[@min(k, n - 1)];
        rb += expandRB(p);
        ag += expandAG(p);
    }
    const last = src[n - 1];
    for (0..n) |i| {
        dst[i] = packLanes(rb, ag, inv);
        const add = if (i + r + 1 < n) src[i + r + 1] else last;
        const sub = src[if (i >= r) i - r else 0];
        rb = rb + expandRB(add) - expandRB(sub);
        ag = ag + expandAG(add) - expandAG(sub);
    }
}

/// Blurs `rect` of `c` in place with a Gaussian-like kernel of standard deviation `radius`.
/// Samples outside the rectangle repeat its edge pixels. Uses 32 KiB of stack.
pub fn blur(c: Canvas, rect: Rect, radius: f32) void {
    const r = rect.intersect(c.bounds());
    if (r.isEmpty()) return;
    const radii = boxRadii(radius);
    if (radii[2] == 0) return;
    const w: usize = @intCast(@min(r.w, max_blur_line));
    const h: usize = @intCast(@min(r.h, max_blur_line));
    var buf_a: [max_blur_line]u32 = undefined;
    var buf_b: [max_blur_line]u32 = undefined;

    // Horizontal passes, row by row.
    for (0..h) |yi| {
        const row = c.span(r.y + @as(i32, @intCast(yi)), r.x, r.x + @as(i32, @intCast(w)));
        boxLine(row, buf_a[0..w], radii[0]);
        boxLine(buf_a[0..w], buf_b[0..w], radii[1]);
        boxLine(buf_b[0..w], row, radii[2]);
    }
    // Vertical passes, column by column.
    const stride: usize = @intCast(c.stride);
    const base = c.pixels + @as(usize, @intCast(r.y)) * stride + @as(usize, @intCast(r.x));
    for (0..w) |xi| {
        for (0..h) |yi| buf_a[yi] = base[yi * stride + xi];
        boxLine(buf_a[0..h], buf_b[0..h], radii[0]);
        boxLine(buf_b[0..h], buf_a[0..h], radii[1]);
        boxLine(buf_a[0..h], buf_b[0..h], radii[2]);
        for (0..h) |yi| base[yi * stride + xi] = buf_b[yi];
    }
}

/// Like `blur` but much cheaper for large radii: averages the region down by
/// 2-8x, blurs the small copy and scales it back up bilinearly.
pub fn blurFast(c: Canvas, allocator: Allocator, rect: Rect, radius: f32) !void {
    const r = rect.intersect(c.bounds());
    if (r.isEmpty()) return;
    const f: i32 = if (radius < 6) 1 else if (radius < 14) 2 else if (radius < 36) 4 else 8;
    if (f == 1) return blur(c, r, radius);

    const sw: u32 = @intCast(@divFloor(r.w + f - 1, f));
    const sh: u32 = @intCast(@divFloor(r.h + f - 1, f));
    var small = try Image.init(allocator, sw, sh);
    defer small.deinit(allocator);

    // Box downsample (partial blocks at the edges average what exists).
    for (0..sh) |sy| {
        for (0..sw) |sx| {
            const x0 = r.x + @as(i32, @intCast(sx)) * f;
            const y0 = r.y + @as(i32, @intCast(sy)) * f;
            const x1 = @min(x0 + f, r.right());
            const y1 = @min(y0 + f, r.bottom());
            var rb: u64 = 0;
            var ag: u64 = 0;
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                for (c.span(yy, x0, x1)) |p| {
                    rb += expandRB(p);
                    ag += expandAG(p);
                }
            }
            const count: u64 = @intCast((x1 - x0) * (y1 - y0));
            small.pixels[sy * sw + sx] = packLanes(rb, ag, ((1 << 20) + count / 2) / count);
        }
    }
    const fs: f32 = @floatFromInt(f);
    // Downsampling already contributes some blur: variance (f^2 - 1) / 12.
    const rem = @sqrt(@max(radius * radius - (fs * fs - 1) / 12.0, 0)) / fs;
    blur(small.canvas(), Rect.init(0, 0, @intCast(sw), @intCast(sh)), rem);

    // Bilinear upsample, pixel-center aligned.
    const sc = small.canvas();
    const step: i64 = @divTrunc(@as(i64, 65536), f);
    const start: i64 = @divTrunc(step, 2) - 32768;
    var yy = r.y;
    while (yy < r.bottom()) : (yy += 1) {
        const fy = start + step * (yy - r.y);
        var fx = start;
        for (c.span(yy, r.x, r.right())) |*p| {
            p.* = sc.sampleBilinear16(fx, fy);
            fx += step;
        }
    }
}

// ---------------------------------------------------------------------------
// Color adjustment

/// Scales saturation (1 = unchanged, 0 = grayscale) and brightness (1 = unchanged) of `rect`.
pub fn adjustColors(c: Canvas, rect: Rect, saturation: f32, brightness: f32) void {
    const r = rect.intersect(c.clip);
    const s: i32 = @intFromFloat(saturation * 256);
    const b: i32 = @intFromFloat(brightness * 256);
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        for (c.span(y, r.x, r.right())) |*p| p.* = adjustPixel(p.*, s, b);
    }
}

/// Saturation / brightness in 8.8 fixed point on a premultiplied pixel.
pub inline fn adjustPixel(p: u32, s: i32, b: i32) u32 {
    const a: i32 = @intCast(p >> 24);
    const pr: i32 = @intCast((p >> 16) & 0xFF);
    const pg: i32 = @intCast((p >> 8) & 0xFF);
    const pb: i32 = @intCast(p & 0xFF);
    const l = (pr * 77 + pg * 150 + pb * 29) >> 8;
    const r = std.math.clamp(((l + (((pr - l) * s) >> 8)) * b) >> 8, 0, a);
    const g = std.math.clamp(((l + (((pg - l) * s) >> 8)) * b) >> 8, 0, a);
    const bl = std.math.clamp(((l + (((pb - l) * s) >> 8)) * b) >> 8, 0, a);
    return (p & 0xFF000000) | (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(bl));
}

// ---------------------------------------------------------------------------
// Shadows

/// A soft shadow cast by a rounded rectangle.
pub const Shadow = struct {
    /// Premultiplied shadow color (its alpha is the peak opacity).
    color: u32 = Color.rgba(0, 0, 0, 90),
    offset_x: i32 = 0,
    offset_y: i32 = 8,
    /// Blur radius (≈ Gaussian standard deviation).
    blur: f32 = 16,
    /// Grows (or shrinks, if negative) the shape before blurring.
    spread: i32 = 0,
    /// Do not draw the shadow underneath the casting shape itself (for translucent surfaces).
    knockout: bool = false,
};

/// A blurred rounded-rectangle alpha mask drawn as a 9-slice, so one small
/// mask serves shadows of any size with the same radius and blur. Cache it.
pub const ShadowMask = struct {
    alpha: []u8,
    w: i32,
    h: i32,
    /// Blur support: the mask extends this far beyond the shape.
    pad: i32,
    mid_x: i32,
    mid_y: i32,

    /// Minimal 9-sliceable mask for corner `radius` and `blur`.
    pub fn init(allocator: Allocator, radius: f32, blur_radius: f32) !ShadowMask {
        const e = blurExtent(blur_radius);
        const ri: i32 = @intFromFloat(@ceil(@max(radius, 0)));
        const side = 2 * ri + 2 * e + 1;
        return initSized(allocator, side, side, radius, blur_radius);
    }

    /// Mask for a shape of exactly `w` x `h` (used when the shape is too small to 9-slice).
    pub fn initSized(allocator: Allocator, w: i32, h: i32, radius: f32, blur_radius: f32) !ShadowMask {
        const e = blurExtent(blur_radius);
        const mw = @max(w, 1) + 2 * e;
        const mh = @max(h, 1) + 2 * e;
        var img = try Image.init(allocator, @intCast(mw), @intCast(mh));
        defer img.deinit(allocator);
        const ic = img.canvas();
        ic.fillRoundRect(Rect.init(e, e, @max(w, 1), @max(h, 1)), radius, Color.white);
        blur(ic, ic.bounds(), blur_radius);
        const alpha = try allocator.alloc(u8, img.pixels.len);
        for (alpha, img.pixels) |*a, p| a.* = @truncate(p >> 24);
        return .{ .alpha = alpha, .w = mw, .h = mh, .pad = e, .mid_x = @divFloor(mw, 2), .mid_y = @divFloor(mh, 2) };
    }

    pub fn deinit(m: *ShadowMask, allocator: Allocator) void {
        allocator.free(m.alpha);
        m.* = undefined;
    }

    /// True if a shape of this size can be drawn by stretching the mask.
    pub fn fits(m: ShadowMask, shape: Rect) bool {
        return shape.w + 2 * m.pad >= m.w and shape.h + 2 * m.pad >= m.h;
    }

    /// Mask index for coordinate `v` of a target spanning `[t0, t1)`, or null outside.
    inline fn mapAxis(v: i32, t0: i32, t1: i32, size: i32, mid: i32) ?usize {
        if (v < t0 or v >= t1) return null;
        const i = v - t0;
        if (i < mid) return @intCast(i);
        const from_end = t1 - v; // 1 .. at the last pixel
        if (from_end < size - mid) return @intCast(size - from_end);
        return @intCast(mid);
    }

    /// Mask alpha for the shadow of `shape` at pixel (x, y).
    inline fn at(m: *const ShadowMask, t: Rect, x: i32, y: i32) u8 {
        const my = mapAxis(y, t.y, t.bottom(), m.h, m.mid_y) orelse return 0;
        const mx = mapAxis(x, t.x, t.right(), m.w, m.mid_x) orelse return 0;
        return m.alpha[my * @as(usize, @intCast(m.w)) + mx];
    }

    /// Draws the shadow of `shape` (already offset / spread) in `color`.
    /// Pixels covered by `knockout` (if given) are left untouched.
    pub fn draw(m: *const ShadowMask, c: Canvas, shape: Rect, color: u32, knockout: ?*const shapes.RRectShape) void {
        std.debug.assert(m.fits(shape));
        const t = shape.inset(-m.pad, -m.pad);
        const area = t.intersect(c.clip);
        if (area.isEmpty()) return;
        const mw: usize = @intCast(m.w);
        const src: canvas_mod.Source = .{ .solid = color };
        // Columns [mid_lo, mid_hi) all map to the stretched middle column.
        const mid_lo = t.x + m.mid_x;
        const mid_hi = t.right() - (m.w - m.mid_x - 1);
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            const my = mapAxis(y, t.y, t.bottom(), m.h, m.mid_y).?;
            const mrow = m.alpha[my * mw ..][0..mw];
            const yc = @as(f32, @floatFromInt(y)) + 0.5;
            // Knockout: [ko0, ko1) touches the shape, [in0, in1) is fully inside it.
            var ko0 = area.right();
            var ko1 = area.right();
            var in0 = area.right();
            var in1 = area.right();
            if (knockout) |ks| {
                if (ks.span(yc, 0.5 + ks.margin)) |ov| {
                    ko0 = @intFromFloat(@floor(ov[0]));
                    ko1 = @intFromFloat(@ceil(ov[1]));
                }
                if (ks.span(yc, -0.5 - ks.margin)) |iv| {
                    in0 = @intFromFloat(@ceil(iv[0] - 0.5));
                    in1 = @as(i32, @intFromFloat(@floor(iv[1] - 0.5))) + 1;
                }
            }
            // Split the row where behavior changes, then handle uniform segments.
            var cuts = [_]i32{ area.x, mid_lo, mid_hi, ko0, in0, in1, ko1, area.right() };
            for (&cuts) |*v| v.* = std.math.clamp(v.*, area.x, area.right());
            std.mem.sort(i32, &cuts, {}, std.sort.asc(i32));
            for (cuts[0 .. cuts.len - 1], cuts[1..]) |x0, x1| {
                if (x0 >= x1) continue;
                const inside = x0 >= in0 and x0 < in1;
                if (inside) continue;
                const near_shape = x0 >= ko0 and x0 < ko1;
                if (!near_shape and x0 >= mid_lo and x0 < mid_hi) {
                    c.fillSpan(y, x0, x1, mrow[@intCast(m.mid_x)], src);
                    continue;
                }
                var x = x0;
                while (x < x1) : (x += 1) {
                    var a: u32 = mrow[mapAxis(x, t.x, t.right(), m.w, m.mid_x).?];
                    if (near_shape) {
                        const d = knockout.?.sdf(@as(f32, @floatFromInt(x)) + 0.5, yc);
                        a = @intFromFloat(@as(f32, @floatFromInt(a)) * std.math.clamp(0.5 + d, 0, 1) + 0.5);
                    }
                    if (a != 0) c.blendPixel(x, y, @intCast(a), src);
                }
            }
        }
    }
};

/// Draws the soft shadow of the rounded rectangle `rect` with corner `radius`.
/// Allocates a temporary mask; keep a `ShadowMask` around to draw repeatedly.
pub fn drawShadow(c: Canvas, allocator: Allocator, rect: Rect, radius: f32, shadow: Shadow) !void {
    const shape = rect.inset(-shadow.spread, -shadow.spread).offset(shadow.offset_x, shadow.offset_y);
    if (shape.isEmpty()) return;
    const r = @max(radius + @as(f32, @floatFromInt(shadow.spread)), 0);
    var mask = try ShadowMask.init(allocator, r, shadow.blur);
    if (!mask.fits(shape)) {
        mask.deinit(allocator);
        mask = try ShadowMask.initSized(allocator, shape.w, shape.h, r, shadow.blur);
    }
    defer mask.deinit(allocator);
    const ko = shapes.RRectShape.init(shapes.RoundRect.init(rect, radius));
    mask.draw(c, shape, shadow.color, if (shadow.knockout) &ko else null);
}

/// Draws an inner shadow inside the rounded rectangle `rect`: the shape's
/// inverse, offset and blurred, clipped to the shape (with anti-aliasing).
pub fn drawInnerShadow(c: Canvas, allocator: Allocator, rect: Rect, radius: f32, shadow: Shadow) !void {
    const hole = rect.inset(shadow.spread, shadow.spread).offset(shadow.offset_x, shadow.offset_y);
    const r = @max(radius - @as(f32, @floatFromInt(shadow.spread)), 0);
    var mask: ?ShadowMask = null;
    if (!hole.isEmpty()) {
        mask = try ShadowMask.init(allocator, r, shadow.blur);
        if (!mask.?.fits(hole)) {
            mask.?.deinit(allocator);
            mask = try ShadowMask.initSized(allocator, hole.w, hole.h, r, shadow.blur);
        }
    }
    defer if (mask) |*m| m.deinit(allocator);
    const t = if (mask) |m| hole.inset(-m.pad, -m.pad) else Rect.empty;
    const shape = shapes.RRectShape.init(shapes.RoundRect.init(rect, radius));
    const area = rect.intersect(c.clip);
    const src: canvas_mod.Source = .{ .solid = shadow.color };
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = shape.span(yc, 0.5) orelse continue;
        var f0: i32 = area.right();
        var f1: i32 = area.right();
        if (shape.span(yc, -0.5 - shape.margin)) |iv| {
            f0 = @intFromFloat(@ceil(iv[0] - 0.5));
            f1 = @as(i32, @intFromFloat(@floor(iv[1] - 0.5))) + 1;
        }
        // Columns where the blurred hole is fully opaque (no inner shadow).
        var s0: i32 = area.right();
        var s1: i32 = area.right();
        if (mask) |m| {
            if (m.at(t, t.x + m.mid_x, y) == 255) {
                s0 = t.x + m.mid_x;
                s1 = t.right() - (m.w - m.mid_x - 1);
            }
        }
        var x = @max(area.x, @as(i32, @intFromFloat(@floor(outer[0]))));
        const x_end = @min(area.right(), @as(i32, @intFromFloat(@ceil(outer[1]))));
        while (x < x_end) : (x += 1) {
            if (x >= s0 and x < s1 and x >= f0 and x < f1) {
                x = @min(s1, f1) - 1;
                continue;
            }
            const hole_a: u32 = if (mask) |*m| m.at(t, x, y) else 0;
            var a: u32 = 255 - hole_a;
            if (x < f0 or x >= f1) {
                const d = shape.sdf(@as(f32, @floatFromInt(x)) + 0.5, yc);
                a = @intFromFloat(@as(f32, @floatFromInt(a)) * std.math.clamp(0.5 - d, 0, 1) + 0.5);
            }
            if (a != 0) c.blendPixel(x, y, @intCast(a), src);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

fn sumChannel(pixels: []const u32, shift: u5) u64 {
    var s: u64 = 0;
    for (pixels) |p| s += (p >> shift) & 0xFF;
    return s;
}

test "box radii approximate the requested sigma" {
    for ([_]f32{ 1, 2, 5, 10, 30 }) |sigma| {
        const r = boxRadii(sigma);
        var variance: f32 = 0;
        for (r) |ri| {
            const w: f32 = @floatFromInt(2 * ri + 1);
            variance += (w * w - 1) / 12;
        }
        try std.testing.expectApproxEqRel(sigma, @sqrt(variance), 0.2);
    }
}

test "blur preserves energy and uniform color" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 64, 64);
    defer img.deinit(a);
    const c = img.canvas();
    c.clear(Color.black);
    c.fillRect(Rect.init(28, 28, 8, 8), Color.white);
    const before = sumChannel(img.pixels, 8);
    blur(c, c.bounds(), 4);
    const after = sumChannel(img.pixels, 8);
    const diff = @as(f64, @floatFromInt(after)) - @as(f64, @floatFromInt(before));
    try std.testing.expect(@abs(diff) / @as(f64, @floatFromInt(before)) < 0.01);
    // Peak dropped, spread out, still symmetric.
    try std.testing.expect(img.pixels[32 * 64 + 32] & 0xFF < 255);
    try std.testing.expect(img.pixels[32 * 64 + 22] & 0xFF > 0);
    try std.testing.expectEqual(img.pixels[32 * 64 + 20], img.pixels[20 * 64 + 32]);
    // A uniform image stays exactly uniform (no edge darkening).
    c.clear(Color.rgb(90, 140, 200));
    blur(c, c.bounds(), 7);
    for (img.pixels) |p| try std.testing.expectEqual(Color.rgb(90, 140, 200), p);
}

test "blurFast preserves uniform color and roughly preserves energy" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 128, 96);
    defer img.deinit(a);
    const c = img.canvas();
    c.clear(Color.rgb(10, 20, 30));
    try blurFast(c, a, c.bounds(), 20);
    for (img.pixels) |p| try std.testing.expectEqual(Color.rgb(10, 20, 30), p);
    c.clear(Color.black);
    c.fillRect(Rect.init(40, 30, 48, 36), Color.white);
    const before = sumChannel(img.pixels, 0);
    try blurFast(c, a, c.bounds(), 16);
    const after = sumChannel(img.pixels, 0);
    const rel = @abs(@as(f64, @floatFromInt(after)) - @as(f64, @floatFromInt(before))) / @as(f64, @floatFromInt(before));
    try std.testing.expect(rel < 0.03);
}

test "adjustColors: saturation 0 is gray, identity is exact" {
    var px = [_]u32{ Color.rgb(200, 50, 10), Color.rgba(255, 0, 0, 128) };
    const c = Canvas.init(&px, 2, 1, 2);
    c.adjustColors(c.bounds(), 1, 1);
    try std.testing.expectEqual(Color.rgb(200, 50, 10), px[0]);
    c.adjustColors(c.bounds(), 0, 1);
    try std.testing.expectEqual(Color.red(px[0]), Color.green(px[0]));
    try std.testing.expectEqual(Color.green(px[0]), Color.blue(px[0]));
    try std.testing.expect(Color.red(px[1]) <= Color.alpha(px[1]));
}

test "shadow: 9-slice matches exact mask and knockout leaves the shape" {
    const a = std.testing.allocator;
    var img1 = try Image.init(a, 200, 160);
    defer img1.deinit(a);
    var img2 = try Image.init(a, 200, 160);
    defer img2.deinit(a);
    const shape = Rect.init(40, 30, 120, 90);
    const color = Color.rgba(0, 0, 0, 200);
    // 9-slice path.
    var m1 = try ShadowMask.init(a, 12, 6);
    defer m1.deinit(a);
    try std.testing.expect(m1.fits(shape));
    m1.draw(img1.canvas(), shape, color, null);
    // Exact full-size mask.
    var m2 = try ShadowMask.initSized(a, shape.w, shape.h, 12, 6);
    defer m2.deinit(a);
    m2.draw(img2.canvas(), shape, color, null);
    for (img1.pixels, img2.pixels) |p, q| {
        try std.testing.expect(@abs(@as(i32, @intCast(p >> 24)) - @as(i32, @intCast(q >> 24))) <= 2);
    }
    // Knockout keeps the inside of the shape untouched.
    var img3 = try Image.init(a, 200, 160);
    defer img3.deinit(a);
    try drawShadow(img3.canvas(), a, shape, 12, .{ .color = color, .blur = 6, .offset_y = 4, .knockout = true });
    try std.testing.expectEqual(@as(u32, 0), img3.pixels[70 * 200 + 100]);
    try std.testing.expect(img3.pixels[(30 + 90 + 4) * 200 + 100] >> 24 > 0);
    // Inner shadow darkens only inside, most at the top edge for a downward offset.
    var img4 = try Image.init(a, 200, 160);
    defer img4.deinit(a);
    try drawInnerShadow(img4.canvas(), a, shape, 12, .{ .color = color, .blur = 4, .offset_y = 4 });
    try std.testing.expectEqual(@as(u32, 0), img4.pixels[20 * 200 + 100]);
    try std.testing.expect(img4.pixels[31 * 200 + 100] >> 24 > img4.pixels[118 * 200 + 100] >> 24);
    try std.testing.expectEqual(@as(u32, 0), img4.pixels[75 * 200 + 100]);
}
