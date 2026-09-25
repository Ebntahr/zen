//! Vector paths: a builder (lines, quadratic/cubic Béziers, arcs) and an
//! exact-area anti-aliasing scanline rasterizer supporting the nonzero and
//! even-odd fill rules, plus a streaming stroker (round joins, round/butt/
//! square caps).
//!
//! The rasterizer is a signed-area accumulation buffer (as in font-rs, but
//! in 16.16 fixed point): each edge deposits its signed area into cells, and a running sum per row
//! yields the area-weighted winding number of every pixel. Large paths are
//! processed in horizontal strips to bound scratch memory.

const std = @import("std");
const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");

const Allocator = std.mem.Allocator;
const PointF = geom.PointF;
const RectF = geom.RectF;
const Rect = geom.Rect;
const Canvas = canvas_mod.Canvas;
const Source = canvas_mod.Source;

pub const FillRule = enum { nonzero, even_odd };
pub const LineCap = @import("shapes.zig").LineCap;

/// 2D affine transform: `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Transform = .{};

    pub fn translate(x: f32, y: f32) Transform {
        return .{ .e = x, .f = y };
    }
    pub fn scale(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }
    /// Rotation by `rad` (clockwise on screen, since y points down).
    pub fn rotate(rad: f32) Transform {
        const s = @sin(rad);
        const co = @cos(rad);
        return .{ .a = co, .b = s, .c = -s, .d = co };
    }
    /// Maps the square `[0, size]^2` onto `rect` (handy for icons designed on a grid).
    pub fn fit(size: f32, rect: RectF) Transform {
        return scale(rect.w / size, rect.h / size).then(translate(rect.x, rect.y));
    }
    /// `self` followed by `next`.
    pub fn then(t: Transform, n: Transform) Transform {
        return .{
            .a = n.a * t.a + n.c * t.b,
            .b = n.b * t.a + n.d * t.b,
            .c = n.a * t.c + n.c * t.d,
            .d = n.b * t.c + n.d * t.d,
            .e = n.a * t.e + n.c * t.f + n.e,
            .f = n.b * t.e + n.d * t.f + n.f,
        };
    }
    pub fn apply(t: Transform, p: PointF) PointF {
        return .{ .x = t.a * p.x + t.c * p.y + t.e, .y = t.b * p.x + t.d * p.y + t.f };
    }
    /// Average linear scale factor (for stroke widths and tolerances).
    pub fn scaleFactor(t: Transform) f32 {
        return @sqrt(@abs(t.a * t.d - t.b * t.c));
    }
};

const Verb = enum(u8) { move, line, quad, cubic, close };

/// A path made of subpaths. Coordinates are in user space; a `Transform` is
/// applied at fill time, so one path can be drawn at any size.
pub const Path = struct {
    allocator: Allocator,
    verbs: std.ArrayList(Verb) = .empty,
    points: std.ArrayList(PointF) = .empty,
    start: PointF = .{ .x = 0, .y = 0 },
    current: PointF = .{ .x = 0, .y = 0 },
    has_current: bool = false,
    /// Set by `close`: the next segment starts a new subpath at `start`.
    reopen: bool = false,

    pub fn init(allocator: Allocator) Path {
        return .{ .allocator = allocator };
    }

    pub fn deinit(p: *Path) void {
        p.verbs.deinit(p.allocator);
        p.points.deinit(p.allocator);
        p.* = undefined;
    }

    /// Removes all subpaths, keeping the allocated capacity.
    pub fn reset(p: *Path) void {
        p.verbs.clearRetainingCapacity();
        p.points.clearRetainingCapacity();
        p.has_current = false;
        p.reopen = false;
    }

    fn push(p: *Path, verb: Verb, pts: []const PointF) !void {
        try p.verbs.append(p.allocator, verb);
        try p.points.appendSlice(p.allocator, pts);
        if (pts.len > 0) p.current = pts[pts.len - 1];
    }

    /// Prepares for a segment: starts a subpath at `fallback` if there is no
    /// current point, or reopens one at the start of a just-closed subpath.
    fn beginSegment(p: *Path, fallback: PointF) !void {
        if (!p.has_current) return p.moveTo(fallback.x, fallback.y);
        if (p.reopen) {
            try p.push(.move, &.{p.start});
            p.reopen = false;
        }
    }

    pub fn moveTo(p: *Path, x: f32, y: f32) !void {
        const pt = PointF{ .x = x, .y = y };
        try p.push(.move, &.{pt});
        p.start = pt;
        p.has_current = true;
        p.reopen = false;
    }

    /// Line to (x, y); starts a subpath there if there is no current point.
    pub fn lineTo(p: *Path, x: f32, y: f32) !void {
        if (!p.has_current) return p.moveTo(x, y);
        try p.beginSegment(.{ .x = x, .y = y });
        try p.push(.line, &.{.{ .x = x, .y = y }});
    }

    pub fn quadTo(p: *Path, cx: f32, cy: f32, x: f32, y: f32) !void {
        try p.beginSegment(.{ .x = cx, .y = cy });
        try p.push(.quad, &.{ .{ .x = cx, .y = cy }, .{ .x = x, .y = y } });
    }

    pub fn cubicTo(p: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) !void {
        try p.beginSegment(.{ .x = c1x, .y = c1y });
        try p.push(.cubic, &.{ .{ .x = c1x, .y = c1y }, .{ .x = c2x, .y = c2y }, .{ .x = x, .y = y } });
    }

    /// Closes the current subpath with a straight line to its start; the
    /// current point becomes that start (HTML canvas semantics).
    pub fn close(p: *Path) !void {
        if (!p.has_current or p.reopen) return;
        try p.push(.close, &.{});
        p.current = p.start;
        p.reopen = true;
    }

    /// Circular arc around (cx, cy) from `start` to `end` (radians; 0 = +x,
    /// increasing clockwise on screen), like the HTML canvas `arc`. Connects
    /// to the current point with a line.
    pub fn arc(p: *Path, cx: f32, cy: f32, r: f32, start: f32, end: f32, ccw: bool) !void {
        const tau = 2.0 * std.math.pi;
        var sweep = end - start;
        if (!ccw) {
            sweep = if (sweep >= tau) tau else @mod(sweep, tau);
        } else {
            sweep = if (-sweep >= tau) -tau else -@mod(-sweep, tau);
        }
        const x0 = cx + r * @cos(start);
        const y0 = cy + r * @sin(start);
        if (p.has_current) try p.lineTo(x0, y0) else try p.moveTo(x0, y0);
        const n: usize = @intFromFloat(@max(1, @ceil(@abs(sweep) / (std.math.pi / 2.0) - 1e-4)));
        const step = sweep / @as(f32, @floatFromInt(n));
        const k = 4.0 / 3.0 * @tan(step / 4.0);
        var a = start;
        for (0..n) |_| {
            const b = a + step;
            const ca = @cos(a);
            const sa = @sin(a);
            const cb = @cos(b);
            const sb = @sin(b);
            try p.cubicTo(
                cx + r * (ca - k * sa),
                cy + r * (sa + k * ca),
                cx + r * (cb + k * sb),
                cy + r * (sb - k * cb),
                cx + r * cb,
                cy + r * sb,
            );
            a = b;
        }
    }

    /// Tangent arc of radius `r` joining the line current->p1 with p1->p2
    /// (HTML canvas `arcTo` semantics).
    pub fn arcTo(p: *Path, x1: f32, y1: f32, x2: f32, y2: f32, r: f32) !void {
        if (!p.has_current) return p.moveTo(x1, y1);
        const p0 = p.current;
        const v1 = PointF{ .x = p0.x - x1, .y = p0.y - y1 };
        const v2 = PointF{ .x = x2 - x1, .y = y2 - y1 };
        const l1 = v1.length();
        const l2 = v2.length();
        const cross = v1.x * v2.y - v1.y * v2.x;
        if (r <= 0 or l1 < 1e-6 or l2 < 1e-6 or @abs(cross) < 1e-6 * l1 * l2) return p.lineTo(x1, y1);
        const n1 = v1.scale(1 / l1);
        const n2 = v2.scale(1 / l2);
        const cos_t = std.math.clamp(n1.dot(n2), -1.0, 1.0);
        const half = std.math.acos(cos_t) * 0.5;
        const dist = r / @tan(half);
        const t1 = PointF{ .x = x1 + n1.x * dist, .y = y1 + n1.y * dist };
        const t2 = PointF{ .x = x1 + n2.x * dist, .y = y1 + n2.y * dist };
        const bis = n1.add(n2);
        const bl = bis.length();
        const cd = r / @sin(half);
        const cx = x1 + bis.x / bl * cd;
        const cy = y1 + bis.y / bl * cd;
        const a0 = std.math.atan2(t1.y - cy, t1.x - cx);
        const a1 = std.math.atan2(t2.y - cy, t2.x - cx);
        // Turning clockwise on screen (positive cross of the travel directions) sweeps clockwise.
        const turn = (x1 - p0.x) * (y2 - y1) - (y1 - p0.y) * (x2 - x1);
        try p.arc(cx, cy, r, a0, a1, turn < 0);
    }

    pub fn addRect(p: *Path, r: RectF) !void {
        try p.moveTo(r.x, r.y);
        try p.lineTo(r.right(), r.y);
        try p.lineTo(r.right(), r.bottom());
        try p.lineTo(r.x, r.bottom());
        try p.close();
    }

    /// Rounded rectangle with circular corners.
    pub fn addRoundRect(p: *Path, r: RectF, radius: f32) !void {
        const rad = @min(radius, @min(r.w, r.h) * 0.5);
        if (rad <= 0) return p.addRect(r);
        const pi = std.math.pi;
        try p.moveTo(r.x + rad, r.y);
        try p.arc(r.right() - rad, r.y + rad, rad, -pi / 2.0, 0, false);
        try p.arc(r.right() - rad, r.bottom() - rad, rad, 0, pi / 2.0, false);
        try p.arc(r.x + rad, r.bottom() - rad, rad, pi / 2.0, pi, false);
        try p.arc(r.x + rad, r.y + rad, rad, pi, 1.5 * pi, false);
        try p.close();
    }

    pub fn addCircle(p: *Path, cx: f32, cy: f32, r: f32) !void {
        return p.addEllipse(cx, cy, r, r);
    }

    pub fn addEllipse(p: *Path, cx: f32, cy: f32, rx: f32, ry: f32) !void {
        const k: f32 = 0.5522847498;
        try p.moveTo(cx + rx, cy);
        try p.cubicTo(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry);
        try p.cubicTo(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy);
        try p.cubicTo(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry);
        try p.cubicTo(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy);
        try p.close();
    }

    /// Closed polygon through `pts`.
    pub fn addPolygon(p: *Path, pts: []const PointF) !void {
        if (pts.len == 0) return;
        try p.moveTo(pts[0].x, pts[0].y);
        for (pts[1..]) |q| try p.lineTo(q.x, q.y);
        try p.close();
    }

    /// Bounds of the transformed control points (contains the whole path).
    pub fn bounds(p: *const Path, t: Transform) ?RectF {
        if (p.points.items.len == 0) return null;
        var lo = t.apply(p.points.items[0]);
        var hi = lo;
        for (p.points.items[1..]) |q| {
            const d = t.apply(q);
            lo.x = @min(lo.x, d.x);
            lo.y = @min(lo.y, d.y);
            hi.x = @max(hi.x, d.x);
            hi.y = @max(hi.y, d.y);
        }
        return .{ .x = lo.x, .y = lo.y, .w = hi.x - lo.x, .h = hi.y - lo.y };
    }

    /// Emits flattened polylines in device space to `sink`
    /// (`begin(p)`, `point(p)`, `end(closed)`).
    pub fn flatten(p: *const Path, t: Transform, tolerance: f32, sink: anytype) void {
        const pts = p.points.items;
        var i: usize = 0;
        var open = false;
        var last = PointF{ .x = 0, .y = 0 };
        for (p.verbs.items) |verb| switch (verb) {
            .move => {
                if (open) sink.end(false);
                last = t.apply(pts[i]);
                i += 1;
                sink.begin(last);
                open = true;
            },
            .line => {
                last = t.apply(pts[i]);
                i += 1;
                sink.point(last);
            },
            .quad => {
                const c1 = t.apply(pts[i]);
                const e = t.apply(pts[i + 1]);
                i += 2;
                flattenQuad(last, c1, e, tolerance, sink);
                last = e;
            },
            .cubic => {
                const c1 = t.apply(pts[i]);
                const c2 = t.apply(pts[i + 1]);
                const e = t.apply(pts[i + 2]);
                i += 3;
                flattenCubic(last, c1, c2, e, tolerance, sink);
                last = e;
            },
            .close => {
                if (open) sink.end(true);
                open = false;
            },
        };
        if (open) sink.end(false);
    }
};

fn segmentsFor(dd: f32, tolerance: f32) usize {
    const n = @ceil(@sqrt(dd / tolerance));
    return @intFromFloat(std.math.clamp(n, 1, 200));
}

fn flattenQuad(p0: PointF, p1: PointF, p2: PointF, tol: f32, sink: anytype) void {
    const ddx = p0.x - 2 * p1.x + p2.x;
    const ddy = p0.y - 2 * p1.y + p2.y;
    const n = segmentsFor(@sqrt(ddx * ddx + ddy * ddy) * 0.25, tol);
    const inv = 1.0 / @as(f32, @floatFromInt(n));
    for (1..n + 1) |k| {
        const t = @as(f32, @floatFromInt(k)) * inv;
        const u = 1 - t;
        sink.point(.{
            .x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            .y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
        });
    }
}

fn flattenCubic(p0: PointF, p1: PointF, p2: PointF, p3: PointF, tol: f32, sink: anytype) void {
    const ax = p0.x - 2 * p1.x + p2.x;
    const ay = p0.y - 2 * p1.y + p2.y;
    const bx = p1.x - 2 * p2.x + p3.x;
    const by = p1.y - 2 * p2.y + p3.y;
    const dd = @sqrt(@max(ax * ax + ay * ay, bx * bx + by * by));
    const n = segmentsFor(dd * 0.75, tol);
    const inv = 1.0 / @as(f32, @floatFromInt(n));
    for (1..n + 1) |k| {
        const t = @as(f32, @floatFromInt(k)) * inv;
        const u = 1 - t;
        const w0 = u * u * u;
        const w1 = 3 * u * u * t;
        const w2 = 3 * u * t * t;
        const w3 = t * t * t;
        sink.point(.{
            .x = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
            .y = w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y,
        });
    }
}

// ---------------------------------------------------------------------------
// Signed-area accumulation rasterizer

/// Fixed-point scale of accumulated coverage (1.0 == one fully covered pixel).
const cov_one: i32 = 1 << 16;

inline fn fx(v: f32) i32 {
    return @intFromFloat(@round(v * @as(f32, @floatFromInt(cov_one))));
}

const Accumulator = struct {
    cells: []i32,
    stride: usize,
    w: f32,
    h: f32,
    ox: f32,
    oy: f32,

    /// Adds the device-space edge p0 -> p1, clipped to this strip.
    fn line(a: *Accumulator, p0: PointF, p1: PointF) void {
        var x0 = p0.x - a.ox;
        var y0 = p0.y - a.oy;
        var x1 = p1.x - a.ox;
        var y1 = p1.y - a.oy;
        if (y0 == y1 or std.math.isNan(x0 + y0 + x1 + y1)) return;
        var dir: f32 = 1;
        if (y0 > y1) {
            std.mem.swap(f32, &x0, &x1);
            std.mem.swap(f32, &y0, &y1);
            dir = -1;
        }
        if (y1 <= 0 or y0 >= a.h) return;
        const dxdy = (x1 - x0) / (y1 - y0);
        if (y0 < 0) {
            x0 -= y0 * dxdy;
            y0 = 0;
        }
        if (y1 > a.h) {
            x1 -= (y1 - a.h) * dxdy;
            y1 = a.h;
        }
        // Split where the edge crosses x = 0 and x = w: parts left of the strip
        // become vertical edges at x = 0, parts right of it are irrelevant.
        var ts = [4]f32{ 0, 1, 1, 1 };
        var n: usize = 1;
        const dx = x1 - x0;
        if (dx != 0) {
            for ([2]f32{ 0, a.w }) |edge| {
                const t = (edge - x0) / dx;
                if (t > 0 and t < 1) {
                    ts[n] = t;
                    n += 1;
                }
            }
        }
        ts[n] = 1;
        if (n == 3 and ts[1] > ts[2]) std.mem.swap(f32, &ts[1], &ts[2]);
        const dy = y1 - y0;
        for (0..n) |k| {
            const ta = ts[k];
            const tb = ts[k + 1];
            if (tb <= ta) continue;
            const xm = x0 + dx * (ta + tb) * 0.5;
            if (xm >= a.w) continue;
            const ya = y0 + dy * ta;
            const yb = if (k + 1 == n) y1 else y0 + dy * tb;
            if (xm <= 0) {
                a.accumulate(0, ya, 0, yb, dir);
            } else {
                const xa = std.math.clamp(x0 + dx * ta, 0, a.w);
                const xb = std.math.clamp(x0 + dx * tb, 0, a.w);
                a.accumulate(xa, ya, xb, yb, dir);
            }
        }
    }

    /// Deposits the signed area of an edge with `y0 < y1` inside the strip.
    fn accumulate(a: *Accumulator, x0: f32, y0: f32, x1: f32, y1: f32, dir: f32) void {
        if (y1 <= y0) return;
        const dxdy = (x1 - x0) / (y1 - y0);
        var x = x0;
        var yi: usize = @intFromFloat(@floor(y0));
        const yend: usize = @intFromFloat(@min(@ceil(y1), a.h));
        while (yi < yend) : (yi += 1) {
            const row = a.cells[yi * a.stride ..][0..a.stride];
            const yf: f32 = @floatFromInt(yi);
            const dy = @min(yf + 1, y1) - @max(yf, y0);
            const xnext = std.math.clamp(x + dxdy * dy, 0, a.w);
            const d = dy * dir;
            const df = fx(d);
            const xa = @min(x, xnext);
            const xb = @max(x, xnext);
            const xa_floor = @floor(xa);
            const xai: usize = @intFromFloat(xa_floor);
            const xb_ceil = @ceil(xb);
            const xbi: usize = @intFromFloat(xb_ceil);
            // Deposits are rounded individually; the last cell takes the remainder
            // so every row segment adds exactly `df` in total.
            if (xbi <= xai + 1) {
                const v1 = fx(d * (0.5 * (x + xnext) - xa_floor));
                row[xai] += df - v1;
                row[xai + 1] += v1;
            } else {
                const s = 1.0 / (xb - xa);
                const x0f = xa - xa_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = xb - xb_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                var sum = fx(d * a0);
                row[xai] += sum;
                if (xbi == xai + 2) {
                    const v1 = fx(d * (1 - a0 - am));
                    row[xai + 1] += v1;
                    sum += v1;
                } else {
                    const a1 = s * (1.5 - x0f);
                    const v1 = fx(d * (a1 - a0));
                    row[xai + 1] += v1;
                    sum += v1;
                    const ds = fx(d * s);
                    for (row[xai + 2 .. xbi - 1]) |*cell| cell.* += ds;
                    sum += ds * @as(i32, @intCast(xbi - xai - 3));
                    const a2 = a1 + @as(f32, @floatFromInt(xbi - xai - 3)) * s;
                    const v2 = fx(d * (1 - a2 - am));
                    row[xbi - 1] += v2;
                    sum += v2;
                }
                row[xbi] += df - sum;
            }
            x = xnext;
        }
    }
};

/// Flattener sink that closes every polyline and feeds edges to an accumulator.
const FillSink = struct {
    acc: *Accumulator,
    first: PointF = .{ .x = 0, .y = 0 },
    last: PointF = .{ .x = 0, .y = 0 },

    fn begin(s: *FillSink, p: PointF) void {
        s.first = p;
        s.last = p;
    }
    fn point(s: *FillSink, p: PointF) void {
        s.acc.line(s.last, p);
        s.last = p;
    }
    fn end(s: *FillSink, closed: bool) void {
        _ = closed;
        s.acc.line(s.last, s.first);
    }
};

/// Streaming stroker: turns polylines into overlapping, consistently oriented
/// polygons (segment quads, join and cap discs) that union under nonzero fill.
const StrokeSink = struct {
    acc: *Accumulator,
    hw: f32,
    cap: LineCap,
    tolerance: f32,
    first: PointF = .{ .x = 0, .y = 0 },
    first_dir: ?PointF = null,
    prev: PointF = .{ .x = 0, .y = 0 },
    prev_dir: ?PointF = null,

    /// Emits a closed polygon, reversing it if needed so every piece winds the same way.
    fn polygon(s: *StrokeSink, pts: []const PointF) void {
        var area: f32 = 0;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p.x * q.y - q.x * p.y;
        }
        if (area > 0) {
            var i = pts.len;
            while (i > 0) : (i -= 1) s.acc.line(pts[i - 1], pts[(i + pts.len - 2) % pts.len]);
        } else {
            for (pts, 0..) |p, i| s.acc.line(p, pts[(i + 1) % pts.len]);
        }
    }

    fn disc(s: *StrokeSink, c: PointF) void {
        const r = s.hw;
        const step = 2 * std.math.acos(std.math.clamp(1 - s.tolerance / @max(r, 0.01), -1.0, 1.0));
        const n: usize = @intFromFloat(std.math.clamp(@ceil(2 * std.math.pi / @max(step, 0.01)), 8, 128));
        var prev = PointF{ .x = c.x + r, .y = c.y };
        for (1..n + 1) |k| {
            const a = -2 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            const q = PointF{ .x = c.x + r * @cos(a), .y = c.y + r * @sin(a) };
            s.acc.line(prev, q);
            prev = q;
        }
    }

    fn join(s: *StrokeSink, p: PointF, d0: PointF, d1: PointF) void {
        const cross = d0.x * d1.y - d0.y * d1.x;
        const dot = d0.x * d1.x + d0.y * d1.y;
        if (dot > 0.995) {
            // Nearly straight: a bevel wedge closes the gap.
            if (@abs(cross) < 1e-6) return;
            const sgn: f32 = if (cross > 0) -1 else 1;
            const a = PointF{ .x = p.x - d0.y * s.hw * sgn, .y = p.y + d0.x * s.hw * sgn };
            const b = PointF{ .x = p.x - d1.y * s.hw * sgn, .y = p.y + d1.x * s.hw * sgn };
            s.polygon(&.{ p, a, b });
        } else {
            s.disc(p);
        }
    }

    fn capAt(s: *StrokeSink, p: PointF, dir: PointF, at_start: bool) void {
        switch (s.cap) {
            .round => s.disc(p),
            .butt => {},
            .square => {
                const sg: f32 = if (at_start) -1 else 1;
                const e = PointF{ .x = p.x + dir.x * s.hw * sg, .y = p.y + dir.y * s.hw * sg };
                const n = PointF{ .x = -dir.y * s.hw, .y = dir.x * s.hw };
                s.polygon(&.{ p.add(n), e.add(n), e.sub(n), p.sub(n) });
            },
        }
    }

    fn begin(s: *StrokeSink, p: PointF) void {
        s.first = p;
        s.prev = p;
        s.first_dir = null;
        s.prev_dir = null;
    }

    fn point(s: *StrokeSink, p: PointF) void {
        const v = p.sub(s.prev);
        const len = v.length();
        if (len < 1e-4) return;
        const d = v.scale(1 / len);
        const n = PointF{ .x = -d.y * s.hw, .y = d.x * s.hw };
        s.polygon(&.{ s.prev.add(n), p.add(n), p.sub(n), s.prev.sub(n) });
        if (s.prev_dir) |pd| s.join(s.prev, pd, d) else s.first_dir = d;
        s.prev_dir = d;
        s.prev = p;
    }

    fn end(s: *StrokeSink, closed: bool) void {
        if (closed) {
            s.point(s.first);
            if (s.prev_dir) |pd| if (s.first_dir) |fd| s.join(s.first, pd, fd);
            return;
        }
        if (s.first_dir) |fd| {
            s.capAt(s.first, fd, true);
            s.capAt(s.prev, s.prev_dir.?, false);
        } else if (s.cap == .round) {
            s.disc(s.first); // a lone point draws a dot
        }
    }
};

/// How to rasterize a path.
pub const FillOptions = struct {
    rule: FillRule = .nonzero,
    transform: Transform = .identity,
    /// Maximum flattening error in device pixels.
    tolerance: f32 = 0.1,
};

pub const StrokeOptions = struct {
    transform: Transform = .identity,
    cap: LineCap = .round,
    tolerance: f32 = 0.1,
};

/// Upper bound of accumulation cells per strip (256 KiB of scratch).
const max_strip_cells = 64 * 1024;

const Geometry = union(enum) {
    fill: void,
    stroke: struct { hw: f32, cap: LineCap },
};

/// Rasterizes `p` inside `clip` and hands each coverage row to `out.row(y, x0, covs)`.
fn rasterize(p: *const Path, geo: Geometry, t: Transform, rule: FillRule, tolerance: f32, clip: Rect, allocator: Allocator, out: anytype) !void {
    const pad: f32 = switch (geo) {
        .fill => 1,
        .stroke => |st| st.hw * 1.5 + 1,
    };
    const bf = p.bounds(t) orelse return;
    const area = bf.inset(-pad, -pad).roundOut().intersect(clip);
    if (area.isEmpty()) return;
    const w: usize = @intCast(area.w);
    const stride = w + 2;
    const strip_h: usize = @min(@as(usize, @intCast(area.h)), @max(1, max_strip_cells / stride));
    const cells = try allocator.alloc(i32, stride * strip_h);
    defer allocator.free(cells);
    const covs = try allocator.alloc(u8, w);
    defer allocator.free(covs);
    @memset(cells, 0);

    var sy: i32 = area.y;
    while (sy < area.bottom()) {
        const h: usize = @min(strip_h, @as(usize, @intCast(area.bottom() - sy)));
        var acc = Accumulator{
            .cells = cells,
            .stride = stride,
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
            .ox = @floatFromInt(area.x),
            .oy = @floatFromInt(sy),
        };
        switch (geo) {
            .fill => {
                var sink = FillSink{ .acc = &acc };
                p.flatten(t, tolerance, &sink);
            },
            .stroke => |st| {
                var sink = StrokeSink{ .acc = &acc, .hw = st.hw, .cap = st.cap, .tolerance = tolerance };
                p.flatten(t, tolerance, &sink);
            },
        }
        for (0..h) |ry| {
            const row = cells[ry * stride ..][0..stride];
            var sum: i32 = 0;
            var any = false;
            for (covs, row[0..w]) |*cv, cell| {
                sum += cell;
                const one: u32 = cov_one;
                var v: u32 = @abs(sum);
                if (rule == .even_odd) {
                    v &= 2 * one - 1;
                    if (v > one) v = 2 * one - v;
                }
                const b: u8 = @intCast((@as(u32, @min(v, one)) * 255 + one / 2) >> 16);
                cv.* = b;
                any = any or b != 0;
            }
            @memset(row, 0);
            if (any) out.row(sy + @as(i32, @intCast(ry)), area.x, covs);
        }
        sy += @intCast(h);
    }
}

const CanvasOut = struct {
    canvas: Canvas,
    src: Source,
    fn row(o: *const CanvasOut, y: i32, x0: i32, covs: []const u8) void {
        o.canvas.fillMaskSpan(y, x0, covs, o.src);
    }
};

const MaskOut = struct {
    mask: []u8,
    w: usize,
    fn row(o: *const MaskOut, y: i32, x0: i32, covs: []const u8) void {
        const start = @as(usize, @intCast(y)) * o.w + @as(usize, @intCast(x0));
        @memcpy(o.mask[start..][0..covs.len], covs);
    }
};

/// Fills `p` with `fill` (color or `*const Paint`). Scratch memory comes from the path's allocator.
pub fn fillPath(c: Canvas, p: *const Path, fill: anytype, opts: FillOptions) !void {
    const out = CanvasOut{ .canvas = c, .src = Source.from(fill) };
    try rasterize(p, .fill, opts.transform, opts.rule, opts.tolerance, c.clip, p.allocator, &out);
}

/// Strokes `p` with a line of `width` (in user units, scaled by the transform) and round joins.
pub fn strokePath(c: Canvas, p: *const Path, width: f32, fill: anytype, opts: StrokeOptions) !void {
    if (!(width > 0)) return;
    const out = CanvasOut{ .canvas = c, .src = Source.from(fill) };
    const hw = width * 0.5 * opts.transform.scaleFactor();
    try rasterize(p, .{ .stroke = .{ .hw = hw, .cap = opts.cap } }, opts.transform, .nonzero, opts.tolerance, c.clip, p.allocator, &out);
}

/// Rasterizes `p` into a caller-owned 8-bit coverage mask of `w * h` bytes (e.g. glyph caches).
pub fn fillPathMask(allocator: Allocator, p: *const Path, w: u32, h: u32, opts: FillOptions) ![]u8 {
    const mask = try allocator.alloc(u8, @as(usize, w) * h);
    errdefer allocator.free(mask);
    @memset(mask, 0);
    const out = MaskOut{ .mask = mask, .w = w };
    try rasterize(p, .fill, opts.transform, opts.rule, opts.tolerance, Rect.init(0, 0, @intCast(w), @intCast(h)), allocator, &out);
    return mask;
}

// ---------------------------------------------------------------------------
// Tests

const Color = @import("color.zig").Color;

fn coverageSum(buf: []const u32) f64 {
    var s: f64 = 0;
    for (buf) |px| s += @as(f64, @floatFromInt(px >> 24)) / 255.0;
    return s;
}

test "path fill: rect area is exact, including fractional edges" {
    const a = std.testing.allocator;
    var buf: [40 * 40]u32 = undefined;
    const c = Canvas.init(&buf, 40, 40, 40);
    c.clear(0);
    var p = Path.init(a);
    defer p.deinit();
    try p.addRect(.{ .x = 5.25, .y = 6.5, .w = 20.5, .h = 10.25 });
    try c.fillPath(&p, Color.white, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 20.5 * 10.25), coverageSum(&buf), 0.3);
    try std.testing.expectEqual(Color.white, buf[10 * 40 + 10]);
}

test "path fill: circle area, nonzero vs even-odd, clipping" {
    const a = std.testing.allocator;
    var buf: [64 * 64]u32 = undefined;
    const c = Canvas.init(&buf, 64, 64, 64);
    var p = Path.init(a);
    defer p.deinit();
    try p.addCircle(32, 32, 20);
    try p.addCircle(32, 32, 10);
    c.clear(0);
    try c.fillPath(&p, Color.white, .{ .rule = .nonzero });
    try std.testing.expectApproxEqRel(std.math.pi * 400.0, coverageSum(&buf), 0.01);
    c.clear(0);
    try c.fillPath(&p, Color.white, .{ .rule = .even_odd });
    try std.testing.expectApproxEqRel(std.math.pi * 300.0, coverageSum(&buf), 0.01);
    try std.testing.expectEqual(@as(u32, 0), buf[32 * 64 + 32]);
    // Partially off-canvas path: only the visible quarter is drawn.
    c.clear(0);
    p.reset();
    try p.addRect(.{ .x = -10, .y = -10, .w = 20, .h = 20 });
    try c.fillPath(&p, Color.white, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 100), coverageSum(&buf), 0.1);
}

test "path fill: strips give the same result as a single pass" {
    const a = std.testing.allocator;
    const w = 700;
    const h = 200;
    const buf = try a.alloc(u32, w * h);
    defer a.free(buf);
    const c = Canvas.init(buf, w, h, w);
    c.clear(0);
    var p = Path.init(a);
    defer p.deinit();
    try p.addEllipse(350, 100, 340, 95);
    try c.fillPath(&p, Color.white, .{});
    try std.testing.expectApproxEqRel(std.math.pi * 340.0 * 95.0, coverageSum(buf), 0.005);
}

test "stroke path: polyline with joins has no gaps" {
    const a = std.testing.allocator;
    var buf: [64 * 64]u32 = undefined;
    const c = Canvas.init(&buf, 64, 64, 64);
    c.clear(0);
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(10, 10);
    try p.lineTo(50, 10);
    try p.lineTo(50, 50);
    try c.strokePath(&p, 4, Color.white, .{ .cap = .butt });
    // Two 40x4 bars sharing a rounded corner join.
    const expected = 40.0 * 4 * 2 - 4 + std.math.pi; // overlap square replaced by quarter disc + square
    try std.testing.expectApproxEqAbs(@as(f64, expected), coverageSum(&buf), 3.0);
    try std.testing.expectEqual(Color.white, buf[10 * 64 + 50]); // corner pixel fully covered
    try std.testing.expectEqual(Color.white, buf[30 * 64 + 50]);
}

test "transform composition" {
    const r = Transform.rotate(std.math.pi / 2.0);
    const q = r.apply(.{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), q.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), q.y, 1e-6);
    const t = Transform.scale(2, 3).then(Transform.translate(10, 20));
    try std.testing.expectEqual(PointF{ .x = 12, .y = 23 }, t.apply(.{ .x = 1, .y = 1 }));
    const f = Transform.fit(100, .{ .x = 5, .y = 7, .w = 50, .h = 50 });
    try std.testing.expectEqual(PointF{ .x = 55, .y = 57 }, f.apply(.{ .x = 100, .y = 100 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f.scaleFactor(), 1e-6);
}

test "segments after close continue from the subpath start" {
    const a = std.testing.allocator;
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(0, 0);
    try p.lineTo(10, 0);
    try p.lineTo(10, 10);
    try p.close();
    try p.lineTo(0, 10); // new subpath (0,0) -> (0,10)
    try p.close();
    try std.testing.expectEqualSlices(Verb, &.{ .move, .line, .line, .close, .move, .line, .close }, p.verbs.items);
    try std.testing.expectEqual(PointF{ .x = 0, .y = 0 }, p.points.items[3]);
}

test "arc and arcTo produce round geometry" {
    const a = std.testing.allocator;
    var buf: [64 * 64]u32 = undefined;
    const c = Canvas.init(&buf, 64, 64, 64);
    c.clear(0);
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(32, 32);
    try p.arc(32, 32, 20, 0, std.math.pi / 2.0, false);
    try p.close();
    try c.fillPath(&p, Color.white, .{});
    try std.testing.expectApproxEqRel(std.math.pi * 100.0, coverageSum(&buf), 0.01);
    try std.testing.expect(buf[40 * 64 + 40] == Color.white); // bottom-right quadrant
    try std.testing.expect(buf[24 * 64 + 40] == 0);

    p.reset();
    try p.moveTo(10, 10);
    try p.arcTo(50, 10, 50, 50, 10);
    try p.lineTo(50, 50);
    try std.testing.expect(p.bounds(.identity).?.right() <= 50.01);
    const m = try fillPathMask(a, &p, 64, 64, .{});
    defer a.free(m);
    try std.testing.expectEqual(@as(u8, 0), m[12 * 64 + 48]); // corner cut by the arc
}
