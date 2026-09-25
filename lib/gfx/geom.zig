//! Integer and float geometry primitives.

const std = @import("std");

/// Integer point.
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn init(x: i32, y: i32) Point {
        return .{ .x = x, .y = y };
    }
    pub fn toF(p: Point) PointF {
        return .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
    }
};

/// Float point / 2D vector.
pub const PointF = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) PointF {
        return .{ .x = x, .y = y };
    }
    pub fn add(a: PointF, b: PointF) PointF {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: PointF, b: PointF) PointF {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: PointF, s: f32) PointF {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: PointF, b: PointF) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn length(a: PointF) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
    pub fn lerp(a: PointF, b: PointF, t: f32) PointF {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

/// Integer rectangle; `w`/`h` <= 0 means empty. Covers `[x, x+w) x [y, y+h)`.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub const empty: Rect = .{};

    pub fn init(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// Rectangle spanning `[x0, x1) x [y0, y1)`.
    pub fn fromCorners(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    /// Intersection; returns `Rect.empty` when the rectangles do not overlap.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return empty;
        return fromCorners(x0, y0, x1, y1);
    }

    /// Smallest rectangle containing both; empty inputs are ignored.
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return fromCorners(
            @min(a.x, b.x),
            @min(a.y, b.y),
            @max(a.right(), b.right()),
            @max(a.bottom(), b.bottom()),
        );
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }
    pub fn containsPoint(r: Rect, p: Point) bool {
        return r.contains(p.x, p.y);
    }
    pub fn containsRect(r: Rect, o: Rect) bool {
        return o.isEmpty() or (o.x >= r.x and o.y >= r.y and o.right() <= r.right() and o.bottom() <= r.bottom());
    }
    pub fn intersects(a: Rect, b: Rect) bool {
        return !a.intersect(b).isEmpty();
    }

    /// Shrinks by `dx` on the left/right and `dy` on top/bottom (negative grows).
    pub fn inset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w - 2 * dx, .h = r.h - 2 * dy };
    }
    pub fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
    pub fn center(r: Rect) Point {
        return .{ .x = r.x + @divFloor(r.w, 2), .y = r.y + @divFloor(r.h, 2) };
    }
    pub fn toF(r: Rect) RectF {
        return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
    }
};

/// Float rectangle.
pub const RectF = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) RectF {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
    pub fn right(r: RectF) f32 {
        return r.x + r.w;
    }
    pub fn bottom(r: RectF) f32 {
        return r.y + r.h;
    }
    pub fn isEmpty(r: RectF) bool {
        return !(r.w > 0 and r.h > 0);
    }
    pub fn center(r: RectF) PointF {
        return .{ .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 };
    }
    pub fn inset(r: RectF, dx: f32, dy: f32) RectF {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w - 2 * dx, .h = r.h - 2 * dy };
    }
    pub fn offset(r: RectF, dx: f32, dy: f32) RectF {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
    pub fn contains(r: RectF, x: f32, y: f32) bool {
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }
    pub fn intersect(a: RectF, b: RectF) RectF {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    /// Smallest integer rectangle containing this one.
    pub fn roundOut(r: RectF) Rect {
        const x0: i32 = @intFromFloat(@floor(r.x));
        const y0: i32 = @intFromFloat(@floor(r.y));
        const x1: i32 = @intFromFloat(@ceil(r.right()));
        const y1: i32 = @intFromFloat(@ceil(r.bottom()));
        return Rect.fromCorners(x0, y0, x1, y1);
    }
};

test "rect intersect/union/contains" {
    const a = Rect.init(0, 0, 10, 10);
    const b = Rect.init(5, 5, 10, 10);
    try std.testing.expect(a.intersect(b).eql(Rect.init(5, 5, 5, 5)));
    try std.testing.expect(a.unionWith(b).eql(Rect.init(0, 0, 15, 15)));
    try std.testing.expect(a.intersect(Rect.init(20, 20, 5, 5)).isEmpty());
    try std.testing.expect(a.unionWith(Rect.empty).eql(a));
    try std.testing.expect(a.contains(0, 0) and a.contains(9, 9) and !a.contains(10, 5));
    try std.testing.expect(a.containsRect(Rect.init(2, 2, 8, 8)) and !a.containsRect(b));
    try std.testing.expect(a.inset(2, 3).eql(Rect.init(2, 3, 6, 4)));
    try std.testing.expect(a.inset(-1, -1).eql(Rect.init(-1, -1, 12, 12)));
    try std.testing.expect(a.offset(3, -2).eql(Rect.init(3, -2, 10, 10)));
    try std.testing.expect(Rect.init(0, 0, 0, 5).isEmpty());
    try std.testing.expect(RectF.init(0.5, 0.25, 2, 2).roundOut().eql(Rect.init(0, 0, 3, 3)));
}
