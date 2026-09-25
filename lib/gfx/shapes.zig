//! Anti-aliased analytic shapes: rounded rectangles (per-corner radii,
//! circular or continuous corners), circles, ellipses and thick lines.
//!
//! Every shape provides a signed distance function (`sdf`) and `span`, the
//! horizontal extent of the shape offset by some distance on a given row. The
//! generic rasterizers use `span` to find, per row, the run of pixels that are
//! fully covered (filled as one fast span) and evaluate the distance function
//! only for the few anti-aliased pixels at the boundary.

const std = @import("std");
const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Source = canvas_mod.Source;
const RectF = geom.RectF;
const Rect = geom.Rect;

/// Accepts a `Rect` or `RectF`.
pub fn toRectF(r: anytype) RectF {
    return switch (@TypeOf(r)) {
        RectF => r,
        Rect => r.toF(),
        else => @compileError("expected Rect or RectF"),
    };
}

/// Corner radii, clockwise from the top-left corner.
pub const Radii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    pub fn all(r: f32) Radii {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }
    pub fn top(r: f32) Radii {
        return .{ .tl = r, .tr = r };
    }
    pub fn bottom(r: f32) Radii {
        return .{ .br = r, .bl = r };
    }
};

/// A rounded rectangle.
pub const RoundRect = struct {
    rect: RectF,
    radii: Radii = .{},
    /// Continuous (squircle-like, curvature-smooth) corners as used by macOS,
    /// instead of circular arcs. The curve starts ~1.7x the radius from the corner.
    continuous: bool = false,

    /// `rect` may be a `Rect` or `RectF`.
    pub fn init(rect: anytype, radius: f32) RoundRect {
        return .{ .rect = toRectF(rect), .radii = Radii.all(radius) };
    }
    /// Same shape with continuous corners.
    pub fn smooth(rect: anytype, radius: f32) RoundRect {
        return .{ .rect = toRectF(rect), .radii = Radii.all(radius), .continuous = true };
    }
    /// Pill shape: radius is half the smaller side.
    pub fn capsule(rect: anytype) RoundRect {
        const r = toRectF(rect);
        return init(r, @min(r.w, r.h) * 0.5);
    }
};

/// Extent of a continuous corner relative to its nominal radius.
pub const continuous_extent: f32 = 1.7;

/// Result of evaluating a distance field with its gradient.
pub const DistGrad = struct {
    /// Signed distance, negative inside.
    d: f32,
    /// Unit outward normal (gradient of `d`).
    nx: f32,
    ny: f32,
};

/// Prepared rounded rectangle with clamped radii (shape interface).
pub const RRectShape = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    cx: f32,
    cy: f32,
    hw: f32,
    hh: f32,
    /// Effective corner extents: tl, tr, br, bl.
    r: [4]f32,
    continuous: bool,
    margin: f32,

    pub fn init(rr: RoundRect) RRectShape {
        const w = @max(rr.rect.w, 0);
        const h = @max(rr.rect.h, 0);
        const k: f32 = if (rr.continuous) continuous_extent else 1.0;
        var r = [4]f32{ rr.radii.tl, rr.radii.tr, rr.radii.br, rr.radii.bl };
        for (&r) |*v| v.* = @max(v.*, 0) * k;
        // Scale radii down uniformly when adjacent corners overlap (CSS rule).
        var f: f32 = 1;
        if (r[0] + r[1] > w) f = @min(f, w / (r[0] + r[1]));
        if (r[3] + r[2] > w) f = @min(f, w / (r[3] + r[2]));
        if (r[0] + r[3] > h) f = @min(f, h / (r[0] + r[3]));
        if (r[1] + r[2] > h) f = @min(f, h / (r[1] + r[2]));
        const max_r = @min(w, h) * 0.5;
        for (&r) |*v| v.* = @min(v.* * f, max_r);
        return .{
            .x0 = rr.rect.x,
            .y0 = rr.rect.y,
            .x1 = rr.rect.x + w,
            .y1 = rr.rect.y + h,
            .cx = rr.rect.x + w * 0.5,
            .cy = rr.rect.y + h * 0.5,
            .hw = w * 0.5,
            .hh = h * 0.5,
            .r = r,
            .continuous = rr.continuous,
            .margin = if (rr.continuous) 0.2 else 0.02,
        };
    }

    pub fn bounds(s: *const RRectShape) RectF {
        return .{ .x = s.x0, .y = s.y0, .w = s.x1 - s.x0, .h = s.y1 - s.y0 };
    }

    /// Horizontal inset of a corner curve of extent `r` at depth `dy` into the corner band.
    inline fn cornerInset(r: f32, dy: f32, continuous: bool) f32 {
        if (continuous) {
            const r2 = r * r;
            const d2 = dy * dy;
            return r - @sqrt(@sqrt(@max(r2 * r2 - d2 * d2, 0)));
        }
        return r - @sqrt(@max(r * r - dy * dy, 0));
    }

    pub fn span(s: *const RRectShape, y: f32, off: f32) ?[2]f32 {
        const ey0 = s.y0 - off;
        const ey1 = s.y1 + off;
        if (y < ey0 or y > ey1) return null;
        var left = s.x0 - off;
        var right = s.x1 + off;
        const lx = left;
        const rx = right;
        const rtl = @max(s.r[0] + off, 0);
        const rtr = @max(s.r[1] + off, 0);
        const rbr = @max(s.r[2] + off, 0);
        const rbl = @max(s.r[3] + off, 0);
        if (ey0 + rtl - y > 0) left = @max(left, lx + cornerInset(rtl, ey0 + rtl - y, s.continuous));
        if (y - (ey1 - rbl) > 0) left = @max(left, lx + cornerInset(rbl, y - (ey1 - rbl), s.continuous));
        if (ey0 + rtr - y > 0) right = @min(right, rx - cornerInset(rtr, ey0 + rtr - y, s.continuous));
        if (y - (ey1 - rbr) > 0) right = @min(right, rx - cornerInset(rbr, y - (ey1 - rbr), s.continuous));
        if (left >= right) return null;
        return .{ left, right };
    }

    inline fn cornerIndex(px: f32, py: f32) usize {
        return if (py < 0) (if (px < 0) 0 else 1) else (if (px < 0) 3 else 2);
    }

    pub fn sdf(s: *const RRectShape, x: f32, y: f32) f32 {
        const px = x - s.cx;
        const py = y - s.cy;
        const r = s.r[cornerIndex(px, py)];
        const qx = @abs(px) - (s.hw - r);
        const qy = @abs(py) - (s.hh - r);
        if (qx > 0 and qy > 0) {
            if (!s.continuous) return @sqrt(qx * qx + qy * qy) - r;
            const x2 = qx * qx;
            const y2 = qy * qy;
            const n = @sqrt(@sqrt(x2 * x2 + y2 * y2));
            const g = @sqrt(x2 * x2 * x2 + y2 * y2 * y2);
            if (g < 1e-9) return -r;
            return (n - r) * n * n * n / g;
        }
        return @max(qx, qy) - r;
    }

    /// Distance and outward normal (used for lighting / refraction).
    pub fn sdfGrad(s: *const RRectShape, x: f32, y: f32) DistGrad {
        const px = x - s.cx;
        const py = y - s.cy;
        const sx: f32 = if (px < 0) -1 else 1;
        const sy: f32 = if (py < 0) -1 else 1;
        const r = s.r[cornerIndex(px, py)];
        const qx = @abs(px) - (s.hw - r);
        const qy = @abs(py) - (s.hh - r);
        if (qx > 0 and qy > 0) {
            if (!s.continuous) {
                const len = @sqrt(qx * qx + qy * qy);
                return .{ .d = len - r, .nx = sx * qx / len, .ny = sy * qy / len };
            }
            const x2 = qx * qx;
            const y2 = qy * qy;
            const n = @sqrt(@sqrt(x2 * x2 + y2 * y2));
            const g = @sqrt(x2 * x2 * x2 + y2 * y2 * y2);
            if (g < 1e-9) return .{ .d = -r, .nx = 0, .ny = sy };
            return .{ .d = (n - r) * n * n * n / g, .nx = sx * x2 * qx / g, .ny = sy * y2 * qy / g };
        }
        if (qx > qy) return .{ .d = qx - r, .nx = sx, .ny = 0 };
        return .{ .d = qy - r, .nx = 0, .ny = sy };
    }
};

/// Circle shape.
pub const CircleShape = struct {
    cx: f32,
    cy: f32,
    r: f32,
    margin: f32 = 0.02,

    pub fn bounds(s: *const CircleShape) RectF {
        return .{ .x = s.cx - s.r, .y = s.cy - s.r, .w = 2 * s.r, .h = 2 * s.r };
    }
    pub fn span(s: *const CircleShape, y: f32, off: f32) ?[2]f32 {
        const rr = s.r + off;
        const dy = y - s.cy;
        if (rr <= 0 or @abs(dy) > rr) return null;
        const hw = @sqrt(rr * rr - dy * dy);
        return .{ s.cx - hw, s.cx + hw };
    }
    pub fn sdf(s: *const CircleShape, x: f32, y: f32) f32 {
        const dx = x - s.cx;
        const dy = y - s.cy;
        return @sqrt(dx * dx + dy * dy) - s.r;
    }
};

/// Axis-aligned ellipse (approximate distance field, exact on the axes).
pub const EllipseShape = struct {
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    margin: f32 = 0.35,

    pub fn bounds(s: *const EllipseShape) RectF {
        return .{ .x = s.cx - s.rx, .y = s.cy - s.ry, .w = 2 * s.rx, .h = 2 * s.ry };
    }
    pub fn span(s: *const EllipseShape, y: f32, off: f32) ?[2]f32 {
        const a = s.rx + off;
        const b = s.ry + off;
        const dy = y - s.cy;
        if (a <= 0 or b <= 0 or @abs(dy) > b) return null;
        const t = dy / b;
        const hw = a * @sqrt(@max(1 - t * t, 0));
        return .{ s.cx - hw, s.cx + hw };
    }
    pub fn sdf(s: *const EllipseShape, x: f32, y: f32) f32 {
        const px = x - s.cx;
        const py = y - s.cy;
        const ux = px / s.rx;
        const uy = py / s.ry;
        const k0 = @sqrt(ux * ux + uy * uy);
        const vx = ux / s.rx;
        const vy = uy / s.ry;
        const k1 = @sqrt(vx * vx + vy * vy);
        if (k1 < 1e-9) return -@min(s.rx, s.ry);
        return k0 * (k0 - 1) / k1;
    }
};

/// Line cap style for thick lines.
pub const LineCap = enum { round, butt, square };

/// Thick line segment: a capsule (round caps) or an oriented box (butt/square caps).
pub const SegmentShape = struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    /// Half the line width.
    r: f32,
    round: bool,
    margin: f32 = 0.02,
    // Derived: unit direction and length.
    ux: f32 = 1,
    uy: f32 = 0,
    len: f32 = 0,

    pub fn init(ax: f32, ay: f32, bx: f32, by: f32, width: f32, cap: LineCap) SegmentShape {
        var s: SegmentShape = .{ .ax = ax, .ay = ay, .bx = bx, .by = by, .r = width * 0.5, .round = cap == .round };
        const dx = bx - ax;
        const dy = by - ay;
        s.len = @sqrt(dx * dx + dy * dy);
        if (s.len > 1e-6) {
            s.ux = dx / s.len;
            s.uy = dy / s.len;
        }
        if (cap == .square) {
            s.ax -= s.ux * s.r;
            s.ay -= s.uy * s.r;
            s.bx += s.ux * s.r;
            s.by += s.uy * s.r;
            s.len += 2 * s.r;
        }
        return s;
    }

    pub fn bounds(s: *const SegmentShape) RectF {
        const x0 = @min(s.ax, s.bx) - s.r;
        const y0 = @min(s.ay, s.by) - s.r;
        return .{ .x = x0, .y = y0, .w = @max(s.ax, s.bx) + s.r - x0, .h = @max(s.ay, s.by) + s.r - y0 };
    }

    /// Interval of x where `lo <= k * x + c <= hi` (`inv_k` = 1 / k), intersected with `acc`.
    inline fn clampLinear(acc: [2]f32, k: f32, inv_k: f32, c: f32, lo: f32, hi: f32) ?[2]f32 {
        if (@abs(k) < 1e-6) {
            if (c < lo or c > hi) return null;
            return acc;
        }
        var a = (lo - c) * inv_k;
        var b = (hi - c) * inv_k;
        if (a > b) std.mem.swap(f32, &a, &b);
        const out = [2]f32{ @max(acc[0], a), @min(acc[1], b) };
        if (out[0] > out[1]) return null;
        return out;
    }

    pub fn span(s: *const SegmentShape, y: f32, off: f32) ?[2]f32 {
        const rr = s.r + off;
        if (rr <= 0) return null;
        const inf = std.math.inf(f32);
        const dy = y - s.ay;
        const inv_ux = if (@abs(s.ux) < 1e-6) 0 else 1 / s.ux;
        const inv_uy = if (@abs(s.uy) < 1e-6) 0 else 1 / s.uy;
        // Band: 0 <= (p-a).u <= len and |(p-a).n| <= rr, with n = (-uy, ux).
        const along_lo: f32 = if (s.round) 0 else -off;
        const along_hi: f32 = if (s.round) s.len else s.len + off;
        var out: ?[2]f32 = null;
        if (clampLinear(.{ -inf, inf }, s.ux, inv_ux, -s.ax * s.ux + dy * s.uy, along_lo, along_hi)) |band| {
            out = clampLinear(band, -s.uy, -inv_uy, s.ax * s.uy + dy * s.ux, -rr, rr);
        }
        if (s.round) {
            inline for (.{ .{ s.ax, s.ay }, .{ s.bx, s.by } }) |p| {
                const ddy = y - p[1];
                if (@abs(ddy) <= rr) {
                    const hw = @sqrt(rr * rr - ddy * ddy);
                    const iv = [2]f32{ p[0] - hw, p[0] + hw };
                    out = if (out) |o| .{ @min(o[0], iv[0]), @max(o[1], iv[1]) } else iv;
                }
            }
        }
        return out;
    }

    pub fn sdf(s: *const SegmentShape, x: f32, y: f32) f32 {
        const px = x - s.ax;
        const py = y - s.ay;
        const along = px * s.ux + py * s.uy;
        const across = @abs(-px * s.uy + py * s.ux);
        if (s.round) {
            // Perpendicular distance along the body; a sqrt only near the caps.
            if (along >= 0 and along <= s.len) return across - s.r;
            const t = std.math.clamp(along, 0, s.len);
            const dx = px - s.ux * t;
            const dy = py - s.uy * t;
            return @sqrt(dx * dx + dy * dy) - s.r;
        }
        const qx = @abs(along - s.len * 0.5) - s.len * 0.5;
        const qy = across - s.r;
        if (qx > 0 and qy > 0) return @sqrt(qx * qx + qy * qy);
        return @max(qx, qy);
    }
};

// ---------------------------------------------------------------------------
// Generic rasterizers

inline fn floorI(v: f32) i32 {
    return @intFromFloat(@floor(std.math.clamp(v, -1e7, 1e7)));
}
inline fn ceilI(v: f32) i32 {
    return @intFromFloat(@ceil(std.math.clamp(v, -1e7, 1e7)));
}
inline fn toCov(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255.0 + 0.5);
}

/// Coverage of a stroke of half-width `hw` at signed distance `d` from the outline.
inline fn strokeCov(d: f32, hw: f32) f32 {
    const a = @abs(d);
    return @min(0.5, a + hw) - @max(-0.5, a - hw);
}

fn edgeRun(c: Canvas, shape: anytype, y: i32, x0: i32, x1: i32, src: Source, comptime stroke: bool, hw: f32) void {
    const yc = @as(f32, @floatFromInt(y)) + 0.5;
    var x = x0;
    while (x < x1) : (x += 1) {
        const d = shape.sdf(@as(f32, @floatFromInt(x)) + 0.5, yc);
        const cov = toCov(if (stroke) strokeCov(d, hw) else 0.5 - d);
        if (cov != 0) c.blendPixel(x, y, cov, src);
    }
}

/// Pixel range whose centers lie inside the interval (conservative "fully inside").
inline fn centersIn(iv: [2]f32) [2]i32 {
    return .{ ceilI(iv[0] - 0.5), floorI(iv[1] - 0.5) + 1 };
}

/// Fills any shape implementing `bounds`, `span`, `sdf` and `margin`.
pub fn fillShape(c: Canvas, shape: anytype, src: Source) void {
    const b = shape.bounds().inset(-1, -1).roundOut().intersect(c.clip);
    if (b.isEmpty()) return;
    const m = shape.margin;
    var y = b.y;
    while (y < b.bottom()) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = shape.span(yc, 0.5 + m) orelse continue;
        const x0 = std.math.clamp(floorI(outer[0]), b.x, b.right());
        const x1 = std.math.clamp(ceilI(outer[1]), x0, b.right());
        var f0 = x1;
        var f1 = x1;
        if (shape.span(yc, -0.5 - m)) |inner| {
            const f = centersIn(inner);
            f0 = std.math.clamp(f[0], x0, x1);
            f1 = std.math.clamp(f[1], f0, x1);
        }
        edgeRun(c, shape, y, x0, f0, src, false, 0);
        c.fillSpan(y, f0, f1, 255, src);
        edgeRun(c, shape, y, f1, x1, src, false, 0);
    }
}

/// Strokes the outline of any shape with a band of `width` centered on it.
pub fn strokeShape(c: Canvas, shape: anytype, width: f32, src: Source) void {
    if (!(width > 0)) return;
    const hw = width * 0.5;
    const b = shape.bounds().inset(-hw - 1, -hw - 1).roundOut().intersect(c.clip);
    if (b.isEmpty()) return;
    const m = shape.margin;
    var y = b.y;
    while (y < b.bottom()) : (y += 1) {
        const yc = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = shape.span(yc, hw + 0.5 + m) orelse continue;
        const x0 = std.math.clamp(floorI(outer[0]), b.x, b.right());
        const x1 = std.math.clamp(ceilI(outer[1]), x0, b.right());
        // Boundaries of: edge | full | edge | hole | edge | full | edge.
        var p = [8]i32{ x0, x0, x0, x0, x0, x1, x1, x1 };
        const full = shape.span(yc, hw - 0.5 - m);
        const inner = shape.span(yc, -hw + 0.5 + m);
        const hole = shape.span(yc, -hw - 0.5 - m);
        if (full) |fa| {
            const a = centersIn(fa);
            if (inner) |ib| {
                p[1] = a[0];
                p[2] = ceilI(ib[0] - 0.5);
                p[5] = floorI(ib[1] - 0.5) + 1;
                p[6] = a[1];
            } else {
                p[1] = a[0];
                p[2] = a[1];
                p[5] = a[1];
                p[6] = a[1];
            }
        }
        if (hole) |h| {
            const hc = centersIn(h);
            p[3] = hc[0];
            p[4] = hc[1];
        } else {
            p[3] = p[2];
            p[4] = p[2];
        }
        for (1..8) |i| p[i] = std.math.clamp(p[i], p[i - 1], x1);
        edgeRun(c, shape, y, p[0], p[1], src, true, hw);
        c.fillSpan(y, p[1], p[2], 255, src);
        edgeRun(c, shape, y, p[2], p[3], src, true, hw);
        edgeRun(c, shape, y, p[4], p[5], src, true, hw);
        c.fillSpan(y, p[5], p[6], 255, src);
        edgeRun(c, shape, y, p[6], p[7], src, true, hw);
    }
}

// ---------------------------------------------------------------------------
// Public drawing API (also available as `Canvas` methods)

/// Fills a rounded rectangle (`rect`: `Rect` or `RectF`) with circular corners.
pub fn fillRoundRect(c: Canvas, rect: anytype, radius: f32, fill: anytype) void {
    fillRRect(c, RoundRect.init(rect, radius), fill);
}

/// Strokes a rounded rectangle outline; the band of `width` is centered on the outline.
pub fn strokeRoundRect(c: Canvas, rect: anytype, radius: f32, width: f32, fill: anytype) void {
    strokeRRect(c, RoundRect.init(rect, radius), width, fill);
}

/// Fills a general rounded rectangle (per-corner radii, optional continuous corners).
pub fn fillRRect(c: Canvas, rr: RoundRect, fill: anytype) void {
    const s = RRectShape.init(rr);
    fillShape(c, &s, Source.from(fill));
}

/// Strokes a general rounded rectangle.
pub fn strokeRRect(c: Canvas, rr: RoundRect, width: f32, fill: anytype) void {
    const s = RRectShape.init(rr);
    strokeShape(c, &s, width, Source.from(fill));
}

pub fn fillCircle(c: Canvas, cx: f32, cy: f32, r: f32, fill: anytype) void {
    const s = CircleShape{ .cx = cx, .cy = cy, .r = r };
    fillShape(c, &s, Source.from(fill));
}

pub fn strokeCircle(c: Canvas, cx: f32, cy: f32, r: f32, width: f32, fill: anytype) void {
    const s = CircleShape{ .cx = cx, .cy = cy, .r = r };
    strokeShape(c, &s, width, Source.from(fill));
}

pub fn fillEllipse(c: Canvas, cx: f32, cy: f32, rx: f32, ry: f32, fill: anytype) void {
    const s = EllipseShape{ .cx = cx, .cy = cy, .rx = rx, .ry = ry };
    fillShape(c, &s, Source.from(fill));
}

pub fn strokeEllipse(c: Canvas, cx: f32, cy: f32, rx: f32, ry: f32, width: f32, fill: anytype) void {
    const s = EllipseShape{ .cx = cx, .cy = cy, .rx = rx, .ry = ry };
    strokeShape(c, &s, width, Source.from(fill));
}

/// Anti-aliased line of `width` with round caps.
pub fn drawLine(c: Canvas, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, fill: anytype) void {
    drawLineCap(c, x0, y0, x1, y1, width, .round, fill);
}

/// Anti-aliased line of `width` with the given cap style.
pub fn drawLineCap(c: Canvas, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, cap: LineCap, fill: anytype) void {
    if (!(width > 0)) return;
    const s = SegmentShape.init(x0, y0, x1, y1, width, cap);
    fillShape(c, &s, Source.from(fill));
}

// ---------------------------------------------------------------------------
// Tests

const Color = @import("color.zig").Color;

fn testCanvas(buf: []u32, w: u32, h: u32) Canvas {
    const c = Canvas.init(buf, w, h, w);
    c.clear(0);
    return c;
}

fn alphaSum(buf: []const u32) f64 {
    var s: f64 = 0;
    for (buf) |p| s += @as(f64, @floatFromInt(p >> 24)) / 255.0;
    return s;
}

test "filled circle area matches pi r^2 and is symmetric" {
    var buf: [64 * 64]u32 = undefined;
    const c = testCanvas(&buf, 64, 64);
    c.fillCircle(32, 32, 20, Color.white);
    const area = alphaSum(&buf);
    try std.testing.expectApproxEqRel(std.math.pi * 400.0, area, 0.01);
    try std.testing.expectEqual(Color.white, buf[32 * 64 + 32]);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    // Mirror symmetry of the AA edge.
    for (0..64) |y| for (0..32) |x| {
        try std.testing.expectEqual(buf[y * 64 + x], buf[y * 64 + 63 - x]);
    };
}

test "round rect coverage: area, interior and corners" {
    var buf: [80 * 60]u32 = undefined;
    const c = testCanvas(&buf, 80, 60);
    const r: f32 = 10;
    c.fillRoundRect(Rect.init(10, 10, 60, 40), r, Color.white);
    const expected = 60.0 * 40.0 - (4.0 - std.math.pi) * r * r;
    try std.testing.expectApproxEqRel(expected, alphaSum(&buf), 0.01);
    try std.testing.expectEqual(Color.white, buf[30 * 80 + 40]);
    try std.testing.expectEqual(Color.white, buf[10 * 80 + 40]); // top edge row, integer aligned
    try std.testing.expectEqual(@as(u32, 0), buf[9 * 80 + 40]);
    try std.testing.expectEqual(@as(u32, 0), buf[10 * 80 + 10]); // outside the corner arc
    // Continuous corners cover a similar but distinct area.
    const c2 = testCanvas(&buf, 80, 60);
    c2.fillRRect(RoundRect.smooth(Rect.init(10, 10, 60, 40), r), Color.white);
    const a2 = alphaSum(&buf);
    try std.testing.expect(a2 < 60.0 * 40.0 and a2 > expected - 60);
}

test "stroke round rect covers perimeter * width" {
    var buf: [100 * 100]u32 = undefined;
    const c = testCanvas(&buf, 100, 100);
    c.strokeRoundRect(Rect.init(20, 20, 60, 60), 0, 2, Color.white);
    // Square ring of outer side 62, inner side 58.
    try std.testing.expectApproxEqRel(62.0 * 62.0 - 58.0 * 58.0, alphaSum(&buf), 0.01);
    try std.testing.expectEqual(@as(u32, 0), buf[50 * 100 + 50]);
    const c2 = testCanvas(&buf, 100, 100);
    c2.strokeCircle(50, 50, 30, 3, Color.white);
    try std.testing.expectApproxEqRel(2 * std.math.pi * 30.0 * 3.0, alphaSum(&buf), 0.01);
    const c3 = testCanvas(&buf, 100, 100);
    c3.strokeCircle(50, 50, 30, 0.5, Color.white);
    try std.testing.expectApproxEqRel(2 * std.math.pi * 30.0 * 0.5, alphaSum(&buf), 0.03);
}

test "lines and ellipses" {
    var buf: [100 * 100]u32 = undefined;
    const c = testCanvas(&buf, 100, 100);
    c.drawLineCap(10, 50, 90, 50, 4, .butt, Color.white);
    try std.testing.expectApproxEqRel(80.0 * 4.0, alphaSum(&buf), 0.01);
    const c2 = testCanvas(&buf, 100, 100);
    c2.drawLine(10, 10, 80, 70, 3, Color.white);
    const len = @sqrt(70.0 * 70.0 + 60.0 * 60.0);
    try std.testing.expectApproxEqRel(len * 3.0 + std.math.pi * 2.25, alphaSum(&buf), 0.02);
    const c3 = testCanvas(&buf, 100, 100);
    c3.fillEllipse(50, 50, 40, 20, Color.white);
    try std.testing.expectApproxEqRel(std.math.pi * 40.0 * 20.0, alphaSum(&buf), 0.01);
}
