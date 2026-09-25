//! Host previews of Activity Monitor.
//!
//!     tools/zigmod run apps/ActivityMonitor/preview.zig -O ReleaseFast -- /tmp/zen_apps
//!
//! Writes activity_{cpu,memory}_{light,dark}.png with seeded sample data
//! (`App.preview`), plus activity_disk_dark.png, activity_system_light.png,
//! activity_quit_light.png / activity_info_dark.png (sheets) and
//! activity_live_light.png rendered from the host's real /proc.
const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const am = @import("app.zig");

const App = am.App;

const Shot = struct {
    name: []const u8,
    tab: am.Tab,
    dark: bool,
    sheet: enum { none, quit, info } = .none,
    live: bool = false,
    w: i32 = App.window.width,
    h: i32 = App.window.height,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const dir = if (args.len > 1) args[1] else "/tmp/zen_apps";
    std.fs.cwd().makePath(dir) catch {};

    var fonts = try ui.FontSet.load(a);
    defer fonts.deinit();

    const shots = [_]Shot{
        .{ .name = "activity_cpu_light", .tab = .cpu, .dark = false },
        .{ .name = "activity_cpu_dark", .tab = .cpu, .dark = true },
        .{ .name = "activity_memory_light", .tab = .memory, .dark = false },
        .{ .name = "activity_memory_dark", .tab = .memory, .dark = true },
        .{ .name = "activity_disk_dark", .tab = .disk, .dark = true },
        .{ .name = "activity_system_light", .tab = .system, .dark = false },
        .{ .name = "activity_quit_light", .tab = .cpu, .dark = false, .sheet = .quit },
        .{ .name = "activity_info_dark", .tab = .memory, .dark = true, .sheet = .info },
        .{ .name = "activity_live_light", .tab = .cpu, .dark = false, .live = true },
        .{ .name = "activity_compact_dark", .tab = .system, .dark = true, .w = App.window.min_width, .h = 420 },
    };
    for (shots) |shot| {
        var win = try render(a, &fonts, shot);
        defer win.close();
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ dir, shot.name });
        try gfx.png.writeFile(gfx.Canvas.init(win.pixels, @intCast(win.width), @intCast(win.height), @intCast(win.width)), path);
        std.debug.print("wrote {s}\n", .{path});
    }
}

fn render(a: std.mem.Allocator, fonts: *ui.FontSet, shot: Shot) !ui.Window {
    var opts = App.window;
    opts.width = shot.w;
    opts.height = shot.h;
    var win = try ui.Window.openHeadless(a, opts);
    var u = ui.Ui.init(a, &win, fonts);
    defer u.deinit();
    u.setDark(shot.dark, null);
    var app = try App.init(a, &u);
    defer app.deinit();
    if (shot.live) {
        // Two samples 300 ms apart so %CPU has a delta.
        std.Thread.sleep(300 * std.time.ns_per_ms);
        app.refreshNow();
        app.frozen = true;
    } else {
        app.preview(&u);
    }
    var mw_buf: [1024]u8 = undefined;
    var mw = @import("abi").window.MenuWriter{ .buf = &mw_buf };
    app.menu(&mw);
    app.tab = shot.tab;
    app.rebuildOrder();
    switch (shot.sheet) {
        .none => {},
        .quit => app.openSheet(.quit, 412),
        .info => {
            app.selected = 433;
            app.openSheet(.info, 433);
        },
    }
    // Hover over a row and the first toolbar button like a real session.
    u.mouse_x = 300;
    u.mouse_y = 150;
    for (0..2) |_| {
        u.beginFrame(&.{});
        app.frame(&u);
        u.endFrame();
    }
    drawChrome(u.canvas, shot.dark);
    return win;
}

/// Traffic lights and rounded corners, as the window server draws them.
fn drawChrome(c: gfx.Canvas, dark: bool) void {
    _ = dark;
    const colors = [3]u32{ 0xFFFF5F57, 0xFFFEBC2E, 0xFF28C840 };
    for (colors, 0..) |col, i| {
        const cx: f32 = 20 + @as(f32, @floatFromInt(i)) * 20;
        const cy: f32 = 26;
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
