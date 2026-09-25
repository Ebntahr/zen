//! "Liquid Glass" material: a refracting, tinted, specular-lit surface.
//!
//! Per pixel inside the anti-aliased rounded rectangle the (pre-blurred)
//! backdrop is sampled with a lens-like displacement along the outline normal
//! (strongest at the rim, fading over the bevel), saturated / brightened,
//! tinted, then lit: a thin specular rim that is brightest facing the light
//! (top-left) with a fainter reflection on the opposite side, an inner glow,
//! and a vertical sheen.
//!
//! Rim effects depend only on the distance to the outline and its normal, so
//! they are computed once per row along the top / bottom edges and once per
//! column along the sides; only corner pixels evaluate the distance field
//! individually. Pixels deeper than the rim band take an integer-only path.

const std = @import("std");
const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const color_mod = @import("color.zig");
const shapes = @import("shapes.zig");
const effects = @import("effects.zig");

const Canvas = canvas_mod.Canvas;
const Color = color_mod.Color;
const Rect = geom.Rect;
const RoundRect = shapes.RoundRect;
const RRectShape = shapes.RRectShape;

/// Appearance parameters of a glass surface.
pub const GlassStyle = struct {
    /// Tint composited over the backdrop (premultiplied; its alpha is the strength).
    tint: u32 = Color.rgba(255, 255, 255, 64),
    /// Backdrop saturation and brightness multipliers.
    saturation: f32 = 1.4,
    brightness: f32 = 1.04,
    /// Maximum lens displacement at the rim and width of the refracting bevel (px).
    refraction: f32 = 9,
    bevel: f32 = 16,
    /// Chromatic dispersion of the refraction (0 = none, ~0.1 = subtle fringes).
    dispersion: f32 = 0.08,
    /// Specular rim: width (px), intensity facing the light, intensity all around,
    /// and relative intensity of the reflection on the side opposite the light.
    rim_width: f32 = 1.6,
    rim_light: f32 = 0.9,
    rim_base: f32 = 0.22,
    rim_back: f32 = 0.5,
    /// Soft inner glow along the edge: width (px) and intensity.
    glow_width: f32 = 12,
    glow: f32 = 0.08,
    /// Brightening at the top of the surface fading out towards the bottom.
    sheen: f32 = 0.05,
    /// Darkening of the inner edge on the side away from the light (depth cue).
    edge_shade: f32 = 0.0,
    /// Direction towards the light (need not be normalized); default top-left.
    light_x: f32 = -0.6,
    light_y: f32 = -0.8,
    /// Opacity of the whole surface.
    opacity: f32 = 1.0,

    /// Bright frosted glass for light appearance (windows, sidebars, popovers).
    pub const light: GlassStyle = .{};

    /// Smoky glass for dark appearance.
    pub const dark: GlassStyle = .{
        .tint = Color.rgba(18, 20, 30, 120),
        .saturation = 1.3,
        .brightness = 0.92,
        .rim_light = 0.6,
        .rim_base = 0.14,
        .rim_back = 0.55,
        .glow = 0.05,
        .sheen = 0.035,
        .edge_shade = 0.12,
    };

    /// Nearly transparent glass (dock, menu bar, controls over content).
    pub const clear: GlassStyle = .{
        .tint = Color.rgba(255, 255, 255, 18),
        .saturation = 1.2,
        .brightness = 1.03,
        .refraction = 12,
        .bevel = 20,
        .dispersion = 0.12,
        .rim_light = 1.0,
        .rim_base = 0.3,
        .glow = 0.1,
        .glow_width = 14,
        .sheen = 0.04,
    };

    /// Glass tinted with `c` (an opaque color), e.g. for accent buttons.
    pub fn tinted(c: u32) GlassStyle {
        var s = light;
        s.tint = Color.withAlpha(c, 190);
        s.saturation = 1.2;
        s.brightness = 1.0;
        s.rim_base = 0.3;
        s.glow = 0.12;
        s.sheen = 0.08;
        return s;
    }
};

/// Adds white light with strength `k` (0..255) using a screen blend.
inline fn screen(c: u32, k: u32) u32 {
    if (k == 0) return c;
    const a = c >> 24;
    const inv = (a * 0x010101) - (c & 0x00FFFFFF);
    return c + Color.mulAlpha(inv, @intCast(@min(k, 255)));
}

/// Scales RGB by `k / 256` (k <= 256).
inline fn darken(c: u32, k: u32) u32 {
    const rb = (((c & 0x00FF00FF) * k) >> 8) & 0x00FF00FF;
    const g = (((c & 0x0000FF00) * k) >> 8) & 0x0000FF00;
    return (c & 0xFF000000) | rb | g;
}

inline fn toFixed16(v: f32) i32 {
    return @intFromFloat(v * 65536.0);
}

/// Everything about a rim pixel that depends only on its distance to the
/// outline and the outline normal. Computed per pixel in corners, once per
/// row along the top / bottom edges and once per column along the sides.
const Profile = struct {
    /// Anti-aliased coverage times opacity.
    cov: u8 = 0,
    /// Screen-light strength (0..255) and darkening multiplier (256 = none).
    light: u32 = 0,
    dark: u32 = 256,
    /// Refraction sample offset and red/blue dispersion offset (16.16 px).
    ox: i32 = 0,
    oy: i32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    refract: bool = false,
    disperse: bool = false,
};

/// Largest rim band (px) served by the per-column side tables.
const max_band_px = 64;

/// Precomputed integer / float parameters for one draw call.
const Ctx = struct {
    shape: RRectShape,
    backdrop: Canvas,
    style: GlassStyle,
    sat: i32,
    bright: i32,
    lx: f32,
    ly: f32,
    band: f32,
    opacity: u32,

    fn init(shape: RRectShape, backdrop: Canvas, style: GlassStyle) Ctx {
        const ll = @sqrt(style.light_x * style.light_x + style.light_y * style.light_y);
        return .{
            .shape = shape,
            .backdrop = backdrop,
            .style = style,
            .sat = @intFromFloat(style.saturation * 256),
            .bright = @intFromFloat(style.brightness * 256),
            .lx = style.light_x / @max(ll, 1e-6),
            .ly = style.light_y / @max(ll, 1e-6),
            .band = @max(style.bevel, @max(style.glow_width, style.rim_width * 4)) + 1,
            .opacity = Color.unitToByte(style.opacity),
        };
    }

    /// Backdrop color adjusted and tinted (no lighting).
    inline fn base(ctx: *const Ctx, p: u32) u32 {
        return Color.over(ctx.style.tint, effects.adjustPixel(p, ctx.sat, ctx.bright));
    }

    /// Refraction and lighting for signed distance `d` and outward normal (nx, ny).
    fn profile(ctx: *const Ctx, d: f32, nx: f32, ny: f32) Profile {
        const s = &ctx.style;
        const cov = std.math.clamp(0.5 - d, 0, 1);
        if (cov <= 0) return .{};
        var pr = Profile{ .cov = @intCast((@as(u32, Color.unitToByte(cov)) * ctx.opacity + 127) / 255) };
        const depth = @max(-d, 0);

        // Lens refraction: sample further inside near the rim.
        const t = 1 - depth / s.bevel;
        if (t > 0 and s.refraction > 0) {
            const disp = s.refraction * t * t;
            pr.ox = toFixed16(-nx * disp);
            pr.oy = toFixed16(-ny * disp);
            pr.refract = disp > 1.0 / 64.0;
            if (s.dispersion > 0 and disp > 0.75) {
                const k = disp * s.dispersion;
                pr.dx = toFixed16(-nx * k);
                pr.dy = toFixed16(-ny * k);
                pr.disperse = true;
            }
        }

        // Specular rim (brightest facing the light, fainter on the opposite
        // side) plus a soft inner glow.
        const ndl = nx * ctx.lx + ny * ctx.ly;
        const front = @max(ndl, 0);
        const back = @max(-ndl, 0);
        const facing = s.rim_base + s.rim_light * (front * front + s.rim_back * back * back);
        const r1 = @max(1 - depth / s.rim_width, 0);
        const r2 = @max(1 - depth / (s.rim_width * 4), 0);
        const rim = (r1 * r1 + 0.3 * r2 * r2) * facing;
        const gl = @max(1 - depth / s.glow_width, 0);
        const glow = s.glow * gl * gl * (0.6 + 0.4 * front);
        pr.light = Color.unitToByte(rim + glow);
        if (s.edge_shade > 0) {
            const amt = std.math.clamp(s.edge_shade * gl * gl * back, 0, 1);
            pr.dark = @intFromFloat((1 - amt) * 256);
        }
        return pr;
    }

    /// Glass color of pixel (x, y) for a rim profile.
    inline fn apply(ctx: *const Ctx, x: i32, y: i32, pr: *const Profile, sheen: u32) u32 {
        var p: u32 = undefined;
        if (pr.refract) {
            const sx = (@as(i64, x) << 16) + pr.ox;
            const sy = (@as(i64, y) << 16) + pr.oy;
            p = ctx.backdrop.sampleBilinear16(sx, sy);
            if (pr.disperse) {
                const r = ctx.backdrop.sampleBilinear16(sx + pr.dx, sy + pr.dy);
                const b = ctx.backdrop.sampleBilinear16(sx - pr.dx, sy - pr.dy);
                p = (p & 0xFF00FF00) | (r & 0x00FF0000) | (b & 0x000000FF);
            }
        } else {
            p = ctx.backdrop.getPixel(x, y);
        }
        var c = ctx.base(p);
        if (pr.dark < 256) c = darken(c, pr.dark);
        return screen(screen(c, sheen), pr.light);
    }

    /// General per-pixel profile from the distance field (used in corners).
    fn cornerProfile(ctx: *const Ctx, x: i32, y: i32) Profile {
        const g = ctx.shape.sdfGrad(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
        return ctx.profile(g.d, g.nx, g.ny);
    }
};

inline fn floorI(v: f32) i32 {
    return @intFromFloat(@floor(v));
}
inline fn ceilI(v: f32) i32 {
    return @intFromFloat(@ceil(v));
}

/// Writes into `backdrop` (same coordinate space as `src`) a blurred copy of
/// the part of `src` behind `rect`, ready for `drawGlass`. The blur runs in a
/// temporary buffer with a margin of context, and only `rect` (plus a pixel
/// of slack) is written back, so calls for overlapping regions compose safely.
pub fn prepareBackdrop(backdrop: Canvas, allocator: std.mem.Allocator, src: Canvas, rect: Rect, blur_radius: f32) !void {
    const margin: i32 = @as(i32, @intFromFloat(@ceil(@max(blur_radius, 0) * 2))) + 2;
    const outer = rect.inset(-margin, -margin).intersect(src.bounds());
    const inner = rect.inset(-2, -2).intersect(outer).intersect(backdrop.bounds());
    if (inner.isEmpty()) return;
    var tmp = try canvas_mod.Image.init(allocator, @intCast(outer.w), @intCast(outer.h));
    defer tmp.deinit(allocator);
    const tc = tmp.canvas();
    tc.blitOpaque(src.sub(outer), 0, 0);
    try tc.blurFast(allocator, tc.bounds(), blur_radius);
    backdrop.withClip(inner).blitOpaque(tc, outer.x, outer.y);
}

/// Draws a glass rounded rectangle. `backdrop` is a (typically blurred) copy
/// of what lies behind, in the same coordinate space as `dst`.
pub fn drawGlass(dst: Canvas, rect: Rect, radius: i32, backdrop: Canvas, style: GlassStyle) void {
    drawGlassRRect(dst, RoundRect.init(rect, @floatFromInt(radius)), backdrop, style);
}

/// Draws a pill-shaped glass surface (radius = half the smaller side).
pub fn drawGlassCapsule(dst: Canvas, rect: Rect, backdrop: Canvas, style: GlassStyle) void {
    drawGlassRRect(dst, RoundRect.capsule(rect), backdrop, style);
}

/// Draws glass in any rounded-rectangle shape (per-corner radii, continuous corners).
pub fn drawGlassRRect(dst: Canvas, rr: RoundRect, backdrop: Canvas, style: GlassStyle) void {
    const shape = RRectShape.init(rr);
    const ctx = Ctx.init(shape, backdrop, style);
    const area = shape.bounds().inset(-1, -1).roundOut().intersect(dst.clip);
    if (area.isEmpty() or ctx.opacity == 0) return;

    // Rim profiles of the straight left / right edges, indexed by column.
    const band_px: i32 = ceilI(ctx.band) + 2;
    const tables = band_px <= max_band_px;
    var left: [max_band_px]Profile = undefined;
    var right: [max_band_px]Profile = undefined;
    const lx0 = floorI(shape.x0) - 1;
    const rx1 = ceilI(shape.x1) + 1;
    if (tables) for (0..@intCast(band_px)) |i| {
        const k: i32 = @intCast(i);
        left[i] = ctx.profile(shape.x0 - (@as(f32, @floatFromInt(lx0 + k)) + 0.5), -1, 0);
        right[i] = ctx.profile(@as(f32, @floatFromInt(rx1 - 1 - k)) + 0.5 - shape.x1, 1, 0);
    };

    const h = @max(shape.y1 - shape.y0, 1);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = shape.span(yc, 0.5 + shape.margin) orelse continue;
        const x0 = std.math.clamp(floorI(outer[0]), area.x, area.right());
        const x1 = std.math.clamp(ceilI(outer[1]), x0, area.right());
        // Interior run: deeper than every refraction / lighting effect.
        var f0 = x1;
        var f1 = x1;
        if (shape.span(yc, -ctx.band)) |iv| {
            f0 = std.math.clamp(ceilI(iv[0] - 0.5), x0, x1);
            f1 = std.math.clamp(floorI(iv[1] - 0.5) + 1, f0, x1);
        }
        const vt = std.math.clamp(1 - (yc - shape.y0) / h, 0, 1);
        const sheen: u32 = @intFromFloat(style.sheen * vt * vt * 255);

        // Straight run along the top or bottom edge: one profile for the row.
        const dt = yc - shape.y0;
        const db = shape.y1 - yc;
        const top = dt <= db;
        const dy_min = @min(dt, db);
        var h0 = x1;
        var h1 = x1;
        var hprof: Profile = .{};
        if (dy_min < ctx.band) {
            const lo = shape.x0 + @max(if (top) shape.r[0] else shape.r[3], dy_min);
            const hi = shape.x1 - @max(if (top) shape.r[1] else shape.r[2], dy_min);
            if (lo < hi) {
                h0 = std.math.clamp(ceilI(lo - 0.5), x0, x1);
                h1 = std.math.clamp(floorI(hi - 0.5) + 1, h0, x1);
                hprof = ctx.profile(-dy_min, 0, if (top) -1 else 1);
            }
        }
        // Side tables apply on rows clear of the corners and the top/bottom bands.
        const sides = tables and f0 < f1 and dy_min >= ctx.band;
        const left_ok = sides and yc >= shape.y0 + shape.r[0] and yc <= shape.y1 - shape.r[3];
        const right_ok = sides and yc >= shape.y0 + shape.r[1] and yc <= shape.y1 - shape.r[2];

        const row = dst.row(y);
        const brow = if (y >= 0 and y < backdrop.height) backdrop.row(y) else null;
        var x = x0;
        while (x < x1) {
            if (x == f0 and f0 < f1) {
                // Interior: adjust + tint + sheen, straight from the backdrop.
                while (x < f1) : (x += 1) {
                    const bp = if (brow != null and x >= 0 and x < backdrop.width) brow.?[@intCast(x)] else backdrop.getPixel(x, y);
                    const c = screen(ctx.base(bp), sheen);
                    const d = &row[@intCast(x)];
                    d.* = if (ctx.opacity == 255) c else Color.lerp8(d.*, c, @intCast(ctx.opacity));
                }
                continue;
            }
            if (x == h0 and h0 < h1) {
                if (hprof.cov != 0) {
                    while (x < h1) : (x += 1) {
                        const d = &row[@intCast(x)];
                        d.* = Color.lerp8(d.*, ctx.apply(x, y, &hprof, sheen), hprof.cov);
                    }
                }
                x = h1;
                continue;
            }
            const li = x - lx0;
            const ri = rx1 - 1 - x;
            const pr = if (left_ok and x < f0 and li >= 0 and li < band_px)
                left[@intCast(li)]
            else if (right_ok and x >= f1 and ri >= 0 and ri < band_px)
                right[@intCast(ri)]
            else
                ctx.cornerProfile(x, y);
            if (pr.cov != 0) {
                const d = &row[@intCast(x)];
                d.* = Color.lerp8(d.*, ctx.apply(x, y, &pr, sheen), pr.cov);
            }
            x += 1;
        }
    }
}

test "glass covers its shape only and keeps the interior close to the tinted backdrop" {
    const a = std.testing.allocator;
    var bd = try canvas_mod.Image.init(a, 120, 80);
    defer bd.deinit(a);
    bd.canvas().clear(Color.rgb(40, 90, 160));
    var img = try canvas_mod.Image.init(a, 120, 80);
    defer img.deinit(a);
    const c = img.canvas();
    c.clear(Color.rgb(40, 90, 160));
    var style = GlassStyle.light;
    style.sheen = 0;
    drawGlass(c, Rect.init(10, 10, 100, 60), 20, bd.canvas(), style);
    // Outside untouched.
    try std.testing.expectEqual(Color.rgb(40, 90, 160), img.pixels[2 * 120 + 2]);
    try std.testing.expectEqual(Color.rgb(40, 90, 160), img.pixels[11 * 120 + 11]);
    // Center equals the adjusted + tinted backdrop.
    const ctx = Ctx.init(RRectShape.init(RoundRect.init(Rect.init(10, 10, 100, 60), 20)), bd.canvas(), style);
    try std.testing.expectEqual(ctx.base(Color.rgb(40, 90, 160)), img.pixels[40 * 120 + 60]);
    // The row / column fast paths agree with the general per-pixel evaluation.
    var img2 = try canvas_mod.Image.init(a, 120, 80);
    defer img2.deinit(a);
    img2.canvas().clear(Color.rgb(40, 90, 160));
    for (0..80) |yy| for (0..120) |xx| {
        const x: i32 = @intCast(xx);
        const y: i32 = @intCast(yy);
        const pr = ctx.cornerProfile(x, y);
        if (pr.cov == 0) continue;
        const d = &img2.pixels[yy * 120 + xx];
        d.* = Color.lerp8(d.*, ctx.apply(x, y, &pr, 0), pr.cov);
    };
    for (img.pixels, img2.pixels) |p, q| {
        inline for (0..4) |ch| {
            const sh: u5 = ch * 8;
            const dp: i32 = @intCast((p >> sh) & 0xFF);
            const dq: i32 = @intCast((q >> sh) & 0xFF);
            try std.testing.expect(@abs(dp - dq) <= 2);
        }
    }
    // Rim facing the light (top edge) is brighter than the interior.
    try std.testing.expect(Color.luma(img.pixels[10 * 120 + 60]) > Color.luma(img.pixels[40 * 120 + 60]));
    for (img.pixels) |p| try std.testing.expectEqual(@as(u32, 255), p >> 24);
}
