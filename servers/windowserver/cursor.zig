//! Mouse cursor images for the 64×64 hardware cursor plane.

const std = @import("std");
const gfx = @import("gfx");
const abi = @import("abi");

const Color = gfx.Color;
const Path = gfx.Path;
const Cursor = abi.window.Cursor;

pub const SIZE = abi.display.CURSOR_SIZE;

pub const Hotspot = struct { x: u32, y: u32 };

fn arrow(c: gfx.Canvas, a: std.mem.Allocator) !Hotspot {
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(4, 2);
    try p.lineTo(4, 25);
    try p.lineTo(9.5, 19.5);
    try p.lineTo(13.5, 28.5);
    try p.lineTo(17, 27);
    try p.lineTo(13.2, 18.3);
    try p.lineTo(20.5, 18.3);
    try p.close();
    try c.strokePath(&p, 3.2, Color.white, .{});
    try c.fillPath(&p, Color.white, .{});
    try c.fillPath(&p, Color.fromHex(0x101012), .{ .transform = gfx.Transform.translate(-4, -2).then(gfx.Transform.scale(0.8, 0.82)).then(gfx.Transform.translate(4.9, 3.9)) });
    return .{ .x = 4, .y = 2 };
}

fn ibeam(c: gfx.Canvas, a: std.mem.Allocator) !Hotspot {
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(7, 4);
    try p.quadTo(12, 4, 12, 8);
    try p.lineTo(12, 24);
    try p.quadTo(12, 28, 7, 28);
    try p.moveTo(17, 4);
    try p.quadTo(12, 4, 12, 8);
    try p.moveTo(17, 28);
    try p.quadTo(12, 28, 12, 24);
    try c.strokePath(&p, 4, Color.white, .{});
    try c.strokePath(&p, 1.8, Color.fromHex(0x101012), .{});
    return .{ .x = 12, .y = 16 };
}

fn pointer(c: gfx.Canvas, a: std.mem.Allocator) !Hotspot {
    var p = Path.init(a);
    defer p.deinit();
    // A simplified pointing hand.
    try p.moveTo(10, 16);
    try p.lineTo(10, 4);
    try p.quadTo(10, 1.5, 12.5, 1.5);
    try p.quadTo(15, 1.5, 15, 4);
    try p.lineTo(15, 12);
    try p.lineTo(22, 13);
    try p.quadTo(26, 13.6, 26, 17);
    try p.lineTo(25, 25);
    try p.quadTo(24, 30, 19, 30);
    try p.lineTo(13, 30);
    try p.quadTo(10, 30, 8, 27);
    try p.lineTo(4, 20);
    try p.quadTo(3, 17, 6, 16.5);
    try p.close();
    try c.strokePath(&p, 3, Color.fromHex(0x101012), .{});
    try c.fillPath(&p, Color.white, .{});
    return .{ .x = 12, .y = 2 };
}

fn doubleArrow(c: gfx.Canvas, a: std.mem.Allocator, angle: f32) !Hotspot {
    var p = Path.init(a);
    defer p.deinit();
    try p.addPolygon(&.{
        .{ .x = -13, .y = 0 }, .{ .x = -6, .y = -7 }, .{ .x = -6, .y = -2.5 },
        .{ .x = 6, .y = -2.5 },  .{ .x = 6, .y = -7 },  .{ .x = 13, .y = 0 },
        .{ .x = 6, .y = 7 },     .{ .x = 6, .y = 2.5 }, .{ .x = -6, .y = 2.5 },
        .{ .x = -6, .y = 7 },
    });
    const t = gfx.Transform.rotate(angle).then(gfx.Transform.translate(16, 16));
    try c.strokePath(&p, 3, Color.white, .{ .transform = t });
    try c.fillPath(&p, Color.fromHex(0x101012), .{ .transform = t });
    return .{ .x = 16, .y = 16 };
}

fn crosshair(c: gfx.Canvas) Hotspot {
    c.drawLine(16, 4, 16, 28, 3, Color.white);
    c.drawLine(4, 16, 28, 16, 3, Color.white);
    c.drawLine(16, 4, 16, 28, 1.2, Color.fromHex(0x101012));
    c.drawLine(4, 16, 28, 16, 1.2, Color.fromHex(0x101012));
    return .{ .x = 16, .y = 16 };
}

fn wait(c: gfx.Canvas) Hotspot {
    const cols = [_]u32{ 0xFFFF3B30, 0xFFFF9500, 0xFFFFCC00, 0xFF34C759, 0xFF0A84FF, 0xFFAF52DE };
    for (cols, 0..) |col, i| {
        const a0 = @as(f32, @floatFromInt(i)) * std.math.tau / 6;
        c.fillCircle(16 + 7 * @cos(a0), 16 + 7 * @sin(a0), 5, col);
    }
    c.strokeCircle(16, 16, 12, 1.5, Color.rgba(0, 0, 0, 120));
    return .{ .x = 16, .y = 16 };
}

/// Render `shape` into a straight-alpha BGRA buffer of SIZE×SIZE pixels.
pub fn render(allocator: std.mem.Allocator, shape: Cursor, out: []u32) Hotspot {
    var img = gfx.Image.init(allocator, SIZE, SIZE) catch return .{ .x = 0, .y = 0 };
    defer img.deinit(allocator);
    const c = img.canvas();
    c.clear(0);
    const hot: Hotspot = switch (shape) {
        .ibeam => ibeam(c, allocator) catch .{ .x = 12, .y = 16 },
        .pointer => pointer(c, allocator) catch .{ .x = 12, .y = 2 },
        .resize_ew => doubleArrow(c, allocator, 0) catch .{ .x = 16, .y = 16 },
        .resize_ns => doubleArrow(c, allocator, std.math.pi / 2.0) catch .{ .x = 16, .y = 16 },
        .resize_nwse => doubleArrow(c, allocator, std.math.pi / 4.0) catch .{ .x = 16, .y = 16 },
        .resize_nesw => doubleArrow(c, allocator, -std.math.pi / 4.0) catch .{ .x = 16, .y = 16 },
        .move => doubleArrow(c, allocator, 0) catch .{ .x = 16, .y = 16 },
        .crosshair => crosshair(c),
        .wait => wait(c),
        .hidden => .{ .x = 0, .y = 0 },
        else => arrow(c, allocator) catch .{ .x = 4, .y = 2 },
    };
    for (out[0 .. SIZE * SIZE], img.pixels[0 .. SIZE * SIZE]) |*o, p| o.* = Color.toStraight(p);
    return hot;
}
