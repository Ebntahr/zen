//! Host previews of Calculator.
//!
//!     tools/zigmod run apps/Calculator/preview.zig -O ReleaseFast -- /tmp/zen_apps
//!
//! Writes calculator_light.png / calculator_dark.png (system appearance;
//! the calculator itself is always dark, like on macOS) showing
//! "1,200 + 34.56 +" → 1,234.56 with the + key active, plus
//! calculator_long.png (auto-shrinking display) and
//! calculator_scientific.png (⌘2 layout).
const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const calc = @import("app.zig");

const App = calc.App;

const Shot = enum { basic, long, scientific };

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const dir = if (args.len > 1) args[1] else "/tmp/zen_apps";
    std.fs.cwd().makePath(dir) catch {};

    var fonts = try ui.FontSet.load(a);
    defer fonts.deinit();

    const shots = [_]struct { []const u8, Shot, bool }{
        .{ "calculator_light", .basic, false },
        .{ "calculator_dark", .basic, true },
        .{ "calculator_long", .long, true },
        .{ "calculator_scientific", .scientific, true },
    };
    for (shots) |s| {
        var win = try render(a, &fonts, s[1], s[2]);
        defer win.close();
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, s[0] });
        try gfx.png.writeFile(gfx.Canvas.init(win.pixels, @intCast(win.width), @intCast(win.height), @intCast(win.width)), path);
        std.debug.print("wrote {s}\n", .{path});
    }
}

/// Like `ui.renderOnce`, plus the window-server chrome that floats over a
/// full-size-content window (traffic lights, rounded corners).
fn render(a: std.mem.Allocator, fonts: *ui.FontSet, shot: Shot, dark: bool) !ui.Window {
    var opts = App.window;
    if (shot == .scientific) opts.width = 580;
    var win = try ui.Window.openHeadless(a, opts);
    var u = ui.Ui.init(a, &win, fonts);
    defer u.deinit();
    u.setDark(dark, null);
    var app = try App.init(a, &u);
    app.preview(&u);
    const e = &app.eng;
    switch (shot) {
        .basic => {},
        .long => {
            e.allClear();
            for ([_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1 }) |d| e.digit(d);
            e.binary(.mul);
            for ([_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }) |d| e.digit(d);
        },
        .scientific => {
            app.setScientific(&u, true);
            e.allClear();
            // sin(30) × 2^10 × → shows 512 with × active.
            for ([_]u8{ 3, 0 }) |d| e.digit(d);
            e.function(.sin);
            e.binary(.mul);
            e.digit(2);
            e.binary(.pow);
            e.digit(1);
            e.digit(0);
            e.binary(.mul);
        },
    }
    for (0..2) |_| {
        u.beginFrame(&.{});
        app.frame(&u);
        u.endFrame();
    }
    drawChrome(u.canvas);
    return win;
}

/// Traffic lights (the window server draws them at y = title height / 2)
/// and the rounded window corners.
fn drawChrome(c: gfx.Canvas) void {
    const colors = [3]u32{ 0xFFFF5F57, 0xFFFEBC2E, 0xFF28C840 };
    for (colors, 0..) |col, i| {
        const cx: f32 = 20 + @as(f32, @floatFromInt(i)) * 20;
        const cy: f32 = 19;
        c.fillCircle(cx, cy, 6.5, col);
        c.strokeCircle(cx, cy, 6.5, 0.6, ui.pm(0x26000000));
    }
    const r: f32 = 14;
    const w: i32 = @intCast(c.width);
    const h: i32 = @intCast(c.height);
    var y: i32 = 0;
    while (y < 14) : (y += 1) {
        var x: i32 = 0;
        while (x < 14) : (x += 1) {
            const dx = r - (@as(f32, @floatFromInt(x)) + 0.5);
            const dy = r - (@as(f32, @floatFromInt(y)) + 0.5);
            const d = @sqrt(dx * dx + dy * dy) - r;
            if (d <= -0.5) continue;
            const cov: u8 = @intFromFloat(std.math.clamp(0.5 - d, 0, 1) * 255);
            for ([_][2]i32{ .{ x, y }, .{ w - 1 - x, y }, .{ x, h - 1 - y }, .{ w - 1 - x, h - 1 - y } }) |p| {
                c.setPixel(p[0], p[1], gfx.Color.scaleAlpha(c.getPixel(p[0], p[1]), cov));
            }
        }
    }
}
