//! Host screenshot helper: composites a headless window buffer over a
//! wallpaper the way the window server does (blurred vibrancy backdrop for
//! translucent windows, shadow, rounded corners, rim, traffic lights and an
//! optional standard title bar).

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const ui = @import("ui");

const Color = gfx.Color;
const RectF = gfx.RectF;
const pm = ui.pm;

pub const Options = struct {
    dark: bool,
    /// Window content has meaningful alpha (vibrancy).
    translucent: bool = false,
    /// Draw a standard title bar with this title (null = full-size content).
    title: ?[]const u8 = null,
    edited: bool = false,
    /// Height of the draggable area (traffic-light centering) for full-size content windows.
    title_height: i32 = 52,
    margin_x: i32 = 70,
    margin_y: i32 = 60,
};

const TITLEBAR: i32 = 32;
const RADIUS: f32 = 14;

pub fn write(a: std.mem.Allocator, fonts: *ui.FontSet, pixels: []u32, w: i32, h: i32, o: Options, path: []const u8) !void {
    const tb: i32 = if (o.title != null) TITLEBAR else 0;
    const W: u32 = @intCast(w + 2 * o.margin_x);
    const H: u32 = @intCast(h + tb + 2 * o.margin_y);
    var img = try gfx.Image.init(a, W, H);
    defer img.deinit(a);
    const c = img.canvas();
    try gfx.wallpaper.render(c, a, if (o.dark) .tahoe_night else .tahoe_day, .{ .detail = 3 });
    var blur = try gfx.Image.fromCanvas(a, c);
    defer blur.deinit(a);
    gfx.effects.blurFast(blur.canvas(), a, blur.canvas().bounds(), 28) catch {};

    const fx: f32 = @floatFromInt(o.margin_x);
    const fy: f32 = @floatFromInt(o.margin_y);
    const frame = RectF.init(fx, fy, @floatFromInt(w), @floatFromInt(h + tb));
    const frame_i = gfx.Rect.init(o.margin_x, o.margin_y, w, h + tb);

    // Shadow.
    var mask = try gfx.ShadowMask.init(a, RADIUS, 22);
    defer mask.deinit(a);
    const sr = frame_i.offset(0, 10);
    if (mask.fits(sr)) mask.draw(c, sr, Color.rgba(0, 0, 0, if (o.dark) 150 else 95), null);

    var rr = gfx.RoundRect.smooth(frame, RADIUS);
    if (o.translucent) {
        var pat = gfx.Paint{ .image = .{ .src = blur.canvas(), .x = 0, .y = 0 } };
        c.fillRRect(rr, &pat);
        c.fillRRect(rr, pm(if (o.dark) 0x66202024 else 0x59F5F5F7));
    }
    const t = ui.Theme.get(o.dark, .blue);
    if (o.title) |title| {
        var bar = rr;
        bar.rect = RectF.init(fx, fy, frame.w, @floatFromInt(TITLEBAR));
        bar.radii.bl = 0;
        bar.radii.br = 0;
        c.fillRRect(bar, pm(if (o.dark) 0xFF2E2E31 else 0xFFF0F0F2));
        c.fillRect(gfx.Rect.init(o.margin_x, o.margin_y + TITLEBAR - 1, w, 1), pm(if (o.dark) 0xFF141416 else 0xFFD6D6DA));
        const f = fonts.face(.semibold, 13);
        const tw = f.measure(title);
        const tx = fx + @max(80, (frame.w - tw) / 2);
        const target = font.Target.init(img.pixels, W, H, W);
        _ = font.drawText(target, f, title, tx, @round(fy + (@as(f32, TITLEBAR) + f.cap_height) / 2), pm(t.label));
        rr.rect = RectF.init(fx, fy + @as(f32, TITLEBAR), frame.w, @floatFromInt(h));
        rr.radii.tl = 0;
        rr.radii.tr = 0;
    }
    // Content with rounded corners.
    const src = gfx.Canvas.init(pixels, @intCast(w), @intCast(h), @intCast(w));
    var content = gfx.Paint{ .image = .{ .src = src, .x = fx, .y = fy + @as(f32, @floatFromInt(tb)) } };
    c.fillRRect(rr, &content);

    // Rim.
    var rim = gfx.RoundRect.smooth(frame, RADIUS);
    rim.rect = frame.inset(0.5, 0.5);
    c.strokeRRect(rim, 1, pm(if (o.dark) 0x33FFFFFF else 0x1A000000));
    if (o.dark) {
        rim.rect = frame.inset(1.5, 1.5);
        c.strokeRRect(rim, 1, pm(0x14FFFFFF));
    }

    // Traffic lights.
    const cy = fy + @as(f32, @floatFromInt(@divTrunc(@min(if (o.title != null) TITLEBAR else o.title_height, 52), 2)));
    const colors = [3]u32{ 0xFFFF5F57, 0xFFFEBC2E, 0xFF28C840 };
    for (colors, 0..) |col, i| {
        const cx = fx + 20 + @as(f32, @floatFromInt(i)) * 20;
        c.fillCircle(cx, cy, 6.5, pm(col));
        c.strokeCircle(cx, cy, 6.5, 0.6, pm(0x26000000));
        if (i == 0 and o.edited) c.fillCircle(cx, cy, 2.2, pm(0x99000000));
    }
    try gfx.png.writeFile(c, path);
}
