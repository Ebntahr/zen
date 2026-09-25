//! Compositing glyph coverage into 32-bit premultiplied ARGB surfaces.
//!
//! Deliberately independent of any graphics library: `Target` describes a
//! plain pixel buffer. Renderers with their own blitters can instead use
//! `Face.glyphs` + `Face.glyphBitmap` + `splitSubpixel` directly.

const std = @import("std");
const face_mod = @import("face.zig");
const Face = face_mod.Face;
const GlyphBitmap = face_mod.GlyphBitmap;
const splitSubpixel = face_mod.splitSubpixel;

/// Clip rectangle; `x1`/`y1` are exclusive.
pub const Clip = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

/// A premultiplied ARGB (0xAARRGGBB) pixel buffer to draw into.
pub const Target = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    /// Distance between rows, in pixels.
    stride: u32,
    clip: Clip,

    /// A target covering all of `pixels`, clipped to its bounds.
    pub fn init(pixels: []u32, width: u32, height: u32, stride: u32) Target {
        std.debug.assert(stride >= width and pixels.len >= @as(usize, stride) * (height -| 1) + width);
        return .{
            .pixels = pixels.ptr,
            .width = width,
            .height = height,
            .stride = stride,
            .clip = .{ .x0 = 0, .y0 = 0, .x1 = toI32(width), .y1 = toI32(height) },
        };
    }

    /// The clip rectangle intersected with the buffer bounds.
    pub fn bounds(self: Target) Clip {
        return .{
            .x0 = @max(self.clip.x0, 0),
            .y0 = @max(self.clip.y0, 0),
            .x1 = @min(self.clip.x1, toI32(self.width)),
            .y1 = @min(self.clip.y1, toI32(self.height)),
        };
    }
};

fn toI32(v: u32) i32 {
    return @intCast(@min(v, std.math.maxInt(i32)));
}

/// Converts a float coordinate to a pixel index without risking overflow.
fn pixel(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@round(v), -1e9, 1e9));
}

/// Multiplies all four 8-bit channels of `px` by `a / 255`, rounded.
inline fn scalePixel(px: u32, a: u32) u32 {
    var rb = (px & 0x00FF00FF) * a + 0x00800080;
    rb = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    var ag = ((px >> 8) & 0x00FF00FF) * a + 0x00800080;
    ag = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return rb | ag;
}

/// Coverage correction tables, one per text luminance bucket (dark to light).
/// Compositing happens in sRGB space, which makes light text on dark
/// backgrounds look thinner than dark text on light ones; lighter text gets
/// a progressively stronger gamma boost to even out perceived weight
/// (the same idea as Skia's luminance-dependent "preblend" tables).
const contrast_luts = blk: {
    @setEvalBranchQuota(100_000);
    const gammas = [_]f32{ 1.0, 0.94, 0.86, 0.78 };
    var luts: [gammas.len][256]u8 = undefined;
    for (&luts, gammas) |*lut, g| {
        for (lut, 0..) |*v, i| {
            const c = @as(f32, @floatFromInt(i)) / 255.0;
            v.* = @intFromFloat(@round(std.math.pow(f32, c, g) * 255.0));
        }
    }
    break :blk luts;
};

/// Picks the coverage correction table for a premultiplied text color.
pub fn contrastTable(color: u32) *const [256]u8 {
    const a = color >> 24;
    if (a == 0) return &contrast_luts[0];
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    const luma = (r * 54 + g * 183 + b * 19) >> 8; // Rec. 709, premultiplied
    const straight = @min(255, luma * 255 / a);
    return &contrast_luts[straight * contrast_luts.len / 256];
}

/// Source-over of premultiplied `color` at coverage `cov` onto `dst`.
pub inline fn blend(dst: u32, color: u32, cov: u8) u32 {
    const src = if (cov == 255) color else scalePixel(color, cov);
    const inv = 255 - (src >> 24);
    return if (inv == 0) src else src + scalePixel(dst, inv);
}

/// Composites a glyph mask with its origin at pixel (`x`, `baseline`),
/// applying the contrast correction for `color`.
pub fn drawGlyph(target: Target, bitmap: GlyphBitmap, x: i32, baseline: i32, color: u32) void {
    drawGlyphLut(target, bitmap, x, baseline, color, contrastTable(color));
}

fn drawGlyphLut(target: Target, bitmap: GlyphBitmap, x: i32, baseline: i32, color: u32, lut: *const [256]u8) void {
    if (bitmap.width == 0 or color >> 24 == 0) return;
    const b = target.bounds();
    const gx: i64 = @as(i64, x) + bitmap.left;
    const gy: i64 = @as(i64, baseline) - bitmap.top;
    const x0 = @max(gx, b.x0);
    const y0 = @max(gy, b.y0);
    const x1 = @min(gx + bitmap.width, b.x1);
    const y1 = @min(gy + bitmap.height, b.y1);
    if (x0 >= x1 or y0 >= y1) return;

    const w: usize = @intCast(x1 - x0);
    var y = y0;
    while (y < y1) : (y += 1) {
        const src_off: usize = @intCast((y - gy) * bitmap.width + (x0 - gx));
        const src = bitmap.alpha[src_off..][0..w];
        const dst = target.pixels[@as(usize, @intCast(y)) * target.stride + @as(usize, @intCast(x0)) ..][0..w];
        for (src, dst) |cov, *d| {
            if (cov != 0) d.* = blend(d.*, color, lut[cov]);
        }
    }
}

/// Draws UTF-8 `text` with its first baseline at `baseline_y`, starting at
/// `x`, in premultiplied ARGB `color`. '\n' starts a new line one
/// `line_height` lower. Returns the pen x after the last character.
/// Glyphs outside the clip are not rasterized; a glyph that cannot be
/// rasterized (out of memory) is skipped.
pub fn drawText(target: Target, face: *Face, text: []const u8, x: f32, baseline_y: f32, color: u32) f32 {
    var it = face.glyphs(text);
    var baseline = baseline_y;
    const b = target.bounds();
    const lut = contrastTable(color);
    while (it.next()) |item| {
        if (item.cp == '\n') baseline += face.line_height;
        if (!item.visible) continue;
        const gf = item.glyph.face;
        const pos = splitSubpixel(x + item.x);
        const by = pixel(baseline);
        // Cheap reject against the font-wide bounding box before rasterizing.
        const px: f32 = @floatFromInt(pos.x);
        const py: f32 = @floatFromInt(by);
        if (px + gf.bounds.x_max < @as(f32, @floatFromInt(b.x0)) - 1 or
            px + gf.bounds.x_min > @as(f32, @floatFromInt(b.x1)) + 1 or
            py - gf.bounds.y_max > @as(f32, @floatFromInt(b.y1)) + 1 or
            py - gf.bounds.y_min < @as(f32, @floatFromInt(b.y0)) - 1) continue;
        const bitmap = gf.glyphBitmap(item.glyph.id, pos.subpixel) catch continue;
        drawGlyphLut(target, bitmap, pos.x, by, color, lut);
    }
    return x + it.pen;
}

/// Draws the first line of `text`, truncated with an ellipsis to fit
/// `max_width`. Returns the pen x after the last character drawn.
pub fn drawTextTruncated(target: Target, face: *Face, text: []const u8, x: f32, baseline_y: f32, max_width: f32, color: u32) f32 {
    const t = face.truncateLen(text, max_width);
    const end = drawText(target, face, text[0..t.len], x, baseline_y, color);
    if (!t.ellipsis) return end;
    return drawText(target, face, face.ellipsis(), end, baseline_y, color);
}

/// Draws `text` word-wrapped to `max_width` with the top of the first line
/// box at `top_y`. Returns the number of lines drawn.
pub fn drawTextWrapped(target: Target, face: *Face, text: []const u8, x: f32, top_y: f32, max_width: f32, color: u32) usize {
    var lines = face.lines(text, max_width);
    var baseline = top_y + face.ascent;
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        _ = drawText(target, face, text[line.start..line.end], x, baseline, color);
        baseline += face.line_height;
    }
    return count;
}

/// Packs 8-bit channels into a premultiplied ARGB color.
pub fn premultiply(r: u8, g: u8, b: u8, a: u8) u32 {
    const rgb = @as(u32, r) << 16 | @as(u32, g) << 8 | b;
    return @as(u32, a) << 24 | (scalePixel(rgb, a) & 0x00FFFFFF);
}

// ---------------------------------------------------------------------------
// Tests

test "blend math" {
    const white: u32 = 0xFFFFFFFF;
    const black: u32 = 0xFF000000;
    try std.testing.expectEqual(black, blend(white, black, 255));
    try std.testing.expectEqual(white, blend(white, black, 0));
    try std.testing.expectEqual(@as(u32, 0xFF808080), blend(white, black, 127));
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), blend(black, white, 127));
    // Half-transparent red over opaque blue.
    const red50 = premultiply(255, 0, 0, 128);
    try std.testing.expectEqual(@as(u32, 0x80800000), red50);
    try std.testing.expectEqual(@as(u32, 0xFF80007F), blend(0xFF0000FF, red50, 255));
    // Onto a transparent destination the result stays premultiplied.
    try std.testing.expectEqual(@as(u32, 0x40400000), blend(0, red50, 128));
}

test "contrast tables" {
    // Dark text is composited with linear coverage; light text is boosted.
    try std.testing.expectEqual(&contrast_luts[0], contrastTable(0xFF1D1D1F));
    try std.testing.expectEqual(&contrast_luts[3], contrastTable(0xFFFFFFFF));
    try std.testing.expectEqual(&contrast_luts[3], contrastTable(0x80808080)); // 50% white
    for (contrast_luts) |lut| {
        try std.testing.expectEqual(@as(u8, 0), lut[0]);
        try std.testing.expectEqual(@as(u8, 255), lut[255]);
        for (lut[1..], lut[0..255]) |hi, lo| try std.testing.expect(hi >= lo);
    }
    try std.testing.expect(contrast_luts[3][128] > 140);
    try std.testing.expectEqual(@as(u8, 128), contrast_luts[0][128]);
}

test "drawGlyph clips to target and clip rect" {
    var pixels = [_]u32{0} ** (8 * 6);
    var target = Target.init(&pixels, 8, 6, 8);
    target.clip = .{ .x0 = 1, .y0 = 0, .x1 = 7, .y1 = 5 };
    const alpha = [_]u8{255} ** 16;
    const bmp: GlyphBitmap = .{ .width = 4, .height = 4, .left = -1, .top = 2, .advance = 4, .alpha = &alpha };
    // Origin at (0, 1): the mask covers x -1..2, y -1..2, clipped to x 1..2, y 0..2.
    drawGlyph(target, bmp, 0, 1, 0xFF112233);
    for (0..6) |y| for (0..8) |x| {
        const inside = x >= 1 and x <= 2 and y <= 2;
        try std.testing.expectEqual(@as(u32, if (inside) 0xFF112233 else 0), pixels[y * 8 + x]);
    };
    // Far outside: nothing happens (and nothing overflows).
    drawGlyph(target, bmp, std.math.maxInt(i32), std.math.minInt(i32), 0xFFFFFFFF);
}

test "drawText renders kerned text into a buffer" {
    const testdata = @import("testdata.zig");
    const Font = @import("ttf.zig").Font;
    const a = std.testing.allocator;
    const data = try testdata.load("Inter-Regular.ttf");
    defer a.free(data);
    var font = try Font.init(a, data);
    defer font.deinit();
    var face = try Face.init(a, &font, 16, .{});
    defer face.deinit();

    const w = 120;
    const h = 60;
    var pixels = [_]u32{0xFFFFFFFF} ** (w * h);
    const target = Target.init(&pixels, w, h, w);
    const end = drawText(target, &face, "AVA Hi\nsecond", 2, 20, 0xFF000000);
    try std.testing.expectApproxEqAbs(2 + face.measure("second"), end, 1e-3);

    // Ink appears only within the text's extent on each line.
    var ink_rows: [h]bool = undefined;
    var max_x: usize = 0; // rightmost ink of the first line
    for (0..h) |y| {
        ink_rows[y] = false;
        for (0..w) |x| if (pixels[y * w + x] != 0xFFFFFFFF) {
            ink_rows[y] = true;
            if (y < 26) max_x = @max(max_x, x);
        };
    }
    try std.testing.expect(ink_rows[15] and ink_rows[38]); // cap region of both lines
    try std.testing.expect(!ink_rows[0] and !ink_rows[h - 1]);
    try std.testing.expect(@as(f32, @floatFromInt(max_x)) <= 2 + face.measure("AVA Hi") + 1);

    // Clipping away everything leaves the buffer untouched.
    @memset(&pixels, 0xFFFFFFFF);
    var clipped = target;
    clipped.clip = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    _ = drawText(clipped, &face, "clipped", 2, 20, 0xFF000000);
    for (pixels) |p| try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), p);

    // Truncated drawing stays within the requested width.
    _ = drawTextTruncated(target, &face, "A rather long label", 0, 20, 60, 0xFF000000);
    for (0..h) |y| for (61..w) |x| try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[y * w + x]);
}

test "corrupt fonts never crash the render path" {
    const testdata = @import("testdata.zig");
    const Font = @import("ttf.zig").Font;
    const a = std.testing.allocator;
    const data = try testdata.load("JetBrainsMono-Regular.ttf");
    defer a.free(data);
    const copy = try a.dupe(u8, data);
    defer a.free(copy);

    var pixels = [_]u32{0} ** (64 * 32);
    const target = Target.init(&pixels, 64, 32, 64);
    var prng = std.Random.DefaultPrng.init(0xf0e1);
    const random = prng.random();
    for (0..60) |round| {
        @memcpy(copy, data);
        // Alternate between damaging the headers/tables and the glyph data.
        const span = if (round % 2 == 0) @min(copy.len, 4096) else copy.len;
        for (0..if (round % 2 == 0) 24 else 400) |_| copy[random.uintLessThan(usize, span)] = random.int(u8);
        var font = Font.init(a, copy) catch continue;
        defer font.deinit();
        var face = Face.init(a, &font, 7 + @as(f32, @floatFromInt(round % 5)) * 9, .{}) catch continue;
        defer face.deinit();
        _ = drawText(target, &face, "Ag{}0@é—\u{FFFD}\xff", 1, 20, 0xFF000000);
        _ = face.measure("The quick brown fox");
        a.free(try face.layoutLines(a, "lorem ipsum dolor sit amet", 20));
        for (0..40) |_| _ = try face.glyphBitmap(random.int(u16), random.int(u2));
    }
}
