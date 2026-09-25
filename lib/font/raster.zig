//! Anti-aliased path rasterizer using exact signed-area coverage
//! accumulation (the technique popularized by font-rs).
//!
//! Each line segment deposits, per scanline, the signed area it covers into
//! an accumulation buffer; a running prefix sum along each row then yields
//! the exact coverage of every pixel under the nonzero fill rule (clamped
//! winding magnitude). No supersampling is involved, so edges are smooth at
//! any size and cost is proportional to edge length plus bitmap area.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    pub fn mid(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
    }
};

/// Maximum distance (px) between a flattened quadratic curve and the true curve.
pub const flatten_tolerance: f32 = 0.05;
const max_curve_segments = 64;

pub const Rasterizer = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Accumulation cells per row: two extra cells absorb spill past the right edge.
    stride: u32 = 0,
    acc: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *Rasterizer, allocator: Allocator) void {
        self.acc.deinit(allocator);
    }

    /// Prepares an empty canvas of `width` x `height` pixels (y down).
    pub fn reset(self: *Rasterizer, allocator: Allocator, width: u32, height: u32) Allocator.Error!void {
        self.width = width;
        self.height = height;
        self.stride = width + 2;
        const n = @as(usize, self.stride) * height;
        try self.acc.resize(allocator, n);
        @memset(self.acc.items, 0);
    }

    /// Adds a line segment. Coordinates are in pixels; y grows downwards.
    pub fn line(self: *Rasterizer, p0: Vec2, p1: Vec2) void {
        // Horizontal edges carry no signed area; near-horizontal ones carry a
        // negligible amount and would make the slope below blow up.
        if (@abs(p0.y - p1.y) < 1e-6) return;
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        const up = p0.y > p1.y;
        const dir: f32 = if (up) -1 else 1;
        const a = if (up) p1 else p0;
        const b = if (up) p0 else p1;
        if (b.y <= 0 or a.y >= h) return;

        const dxdy = (b.x - a.x) / (b.y - a.y);
        const y_top = @max(a.y, 0);
        const y_bot = @min(b.y, h);
        var x = a.x + (y_top - a.y) * dxdy;
        var y: usize = @intFromFloat(y_top);
        const y_end: usize = @intFromFloat(@ceil(y_bot));
        while (y < y_end) : (y += 1) {
            const row = self.acc.items[y * self.stride ..][0..self.stride];
            const fy: f32 = @floatFromInt(y);
            const dy = @min(fy + 1, y_bot) - @max(fy, y_top);
            const x_next = x + dxdy * dy;
            const d = dy * dir;
            const x0 = std.math.clamp(@min(x, x_next), 0, w);
            const x1 = std.math.clamp(@max(x, x_next), 0, w);
            x = x_next;

            const x0_floor = @floor(x0);
            const x0i: usize = @intFromFloat(x0_floor);
            const x1_ceil = @ceil(x1);
            const x1i: usize = @intFromFloat(x1_ceil);
            if (x1i <= x0i + 1) {
                // The segment stays within one pixel column on this row.
                const xmf = 0.5 * (x0 + x1) - x0_floor;
                row[x0i] += d - d * xmf;
                row[x0i + 1] += d * xmf;
            } else {
                // Spread the area over the columns the segment crosses.
                const s = 1.0 / (x1 - x0);
                const x0f = x0 - x0_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                row[x0i] += d * a0;
                if (x1i == x0i + 2) {
                    row[x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    row[x0i + 1] += d * (a1 - a0);
                    for (row[x0i + 2 .. x1i - 1]) |*cell| cell.* += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    row[x1i - 1] += d * (1 - a2 - am);
                }
                row[x1i] += d * am;
            }
        }
    }

    /// Adds a quadratic Bézier curve, flattened with a segment count chosen
    /// from its curvature so the error stays below `flatten_tolerance`.
    pub fn quad(self: *Rasterizer, p0: Vec2, p1: Vec2, p2: Vec2) void {
        // The chord of a parameter span h deviates at most |p0 - 2p1 + p2| * h² / 4.
        const ddx = p0.x - 2 * p1.x + p2.x;
        const ddy = p0.y - 2 * p1.y + p2.y;
        const dev = @sqrt(ddx * ddx + ddy * ddy);
        const n_f = @ceil(@sqrt(dev / (4 * flatten_tolerance)));
        const n: u32 = if (n_f <= 1) 1 else if (n_f >= max_curve_segments) max_curve_segments else @intFromFloat(n_f);
        var prev = p0;
        const inv_n = 1.0 / @as(f32, @floatFromInt(n));
        var i: u32 = 1;
        while (i < n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) * inv_n;
            const next = Vec2.lerp(Vec2.lerp(p0, p1, t), Vec2.lerp(p1, p2, t), t);
            self.line(prev, next);
            prev = next;
        }
        self.line(prev, p2);
    }

    /// Converts accumulated area into 8-bit coverage (`out.len == width * height`).
    pub fn resolve(self: *const Rasterizer, out: []u8) void {
        std.debug.assert(out.len == @as(usize, self.width) * self.height);
        for (0..self.height) |y| {
            const row = self.acc.items[y * self.stride ..][0..self.width];
            const dst = out[y * self.width ..][0..self.width];
            var sum: f32 = 0;
            for (row, dst) |cell, *px| {
                sum += cell;
                const cov = @min(@abs(sum), 1.0);
                px.* = @intFromFloat(cov * 255.0 + 0.5);
            }
        }
    }
};

fn testRaster(width: u32, height: u32, path: []const Vec2, out: []u8) !void {
    var r: Rasterizer = .{};
    defer r.deinit(std.testing.allocator);
    try r.reset(std.testing.allocator, width, height);
    for (path, 0..) |p, i| r.line(p, path[(i + 1) % path.len]);
    r.resolve(out);
}

test "filled square has full coverage inside and none outside" {
    var out: [8 * 8]u8 = undefined;
    // Pixel-aligned square from (2,2) to (6,6), both windings.
    const cw = [_]Vec2{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 6 }, .{ .x = 2, .y = 6 } };
    const ccw = [_]Vec2{ cw[0], cw[3], cw[2], cw[1] };
    for ([_][]const Vec2{ &cw, &ccw }) |path| {
        try testRaster(8, 8, path, &out);
        for (0..8) |y| for (0..8) |x| {
            const inside = x >= 2 and x < 6 and y >= 2 and y < 6;
            try std.testing.expectEqual(@as(u8, if (inside) 255 else 0), out[y * 8 + x]);
        };
    }
}

test "partial coverage is proportional to area" {
    var out: [4 * 4]u8 = undefined;
    // Square offset by half a pixel: edge pixels are half covered, corners a quarter.
    const sq = [_]Vec2{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 3.5, .y = 0.5 }, .{ .x = 3.5, .y = 3.5 }, .{ .x = 0.5, .y = 3.5 } };
    try testRaster(4, 4, &sq, &out);
    try std.testing.expectEqual(@as(u8, 64), out[0]);
    try std.testing.expectEqual(@as(u8, 128), out[1]);
    try std.testing.expectEqual(@as(u8, 255), out[5]);
    try std.testing.expectEqual(@as(u8, 128), out[4 * 2 + 3]);

    // A triangle covering exactly half of a 4x4 square along its diagonal.
    const tri = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    try testRaster(4, 4, &tri, &out);
    var total: u32 = 0;
    for (out) |v| total += v;
    try std.testing.expectApproxEqAbs(@as(f32, 8 * 255), @as(f32, @floatFromInt(total)), 8);
    try std.testing.expectEqual(@as(u8, 128), out[0]); // diagonal pixels are half covered
    try std.testing.expectEqual(@as(u8, 255), out[3 * 4]);
}

test "curves stay within tolerance and out-of-bounds input is clipped" {
    var r: Rasterizer = .{};
    defer r.deinit(std.testing.allocator);
    try r.reset(std.testing.allocator, 16, 16);
    // A circle-ish shape from four quads, plus wild coordinates that must be clipped safely.
    const c = Vec2{ .x = 8, .y = 8 };
    const rad: f32 = 6;
    const pts = [_]Vec2{ .{ .x = c.x + rad, .y = c.y }, .{ .x = c.x, .y = c.y + rad }, .{ .x = c.x - rad, .y = c.y }, .{ .x = c.x, .y = c.y - rad } };
    for (0..4) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % 4];
        r.quad(a, .{ .x = a.x + b.x - c.x, .y = a.y + b.y - c.y }, b);
    }
    r.line(.{ .x = -100, .y = -50 }, .{ .x = 300, .y = 90 });
    r.line(.{ .x = 300, .y = 90 }, .{ .x = -100, .y = -50 });
    var out: [16 * 16]u8 = undefined;
    r.resolve(&out);
    try std.testing.expectEqual(@as(u8, 255), out[8 * 16 + 8]);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[15 * 16 + 15]);
}
