//! Host preview of Terminal.app: renders the demo zensh session in the dark
//! ("Clear Dark") and light profiles.
//!
//!   tools/zigmod run apps/Terminal/preview.zig -O ReleaseFast            → /tmp/zen_apps/terminal_{dark,light}.png
//!   tools/zigmod run apps/Terminal/preview.zig -O ReleaseFast -- x.png   → x.png (dark) and x_light.png
//!
//! The window is translucent, so each image shows the content composited
//! the way the window server does it (over the blurred wallpaper and the
//! vibrancy tint); `*_raw.png` files keep the window's own alpha.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const App = @import("app.zig").App;

const W = 720;
const H = 460;
/// Where the window content sits on a 1280x800 screen.
const screen_w = 1280;
const screen_h = 800;
const win_x = 280;
const win_y = 150;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    var dark_path: []const u8 = "/tmp/zen_apps/terminal_dark.png";
    var light_path: []const u8 = "/tmp/zen_apps/terminal_light.png";
    if (args.len > 1) {
        const p = args[1];
        if (std.mem.endsWith(u8, p, ".png")) {
            dark_path = p;
            light_path = try std.fmt.allocPrint(a, "{s}_light.png", .{p[0 .. p.len - 4]});
        } else {
            dark_path = try std.fs.path.join(a, &.{ p, "terminal_dark.png" });
            light_path = try std.fs.path.join(a, &.{ p, "terminal_light.png" });
        }
    }

    var fonts = try ui.FontSet.load(a);
    defer fonts.deinit();

    for ([_]bool{ true, false }) |dark| {
        const path = if (dark) dark_path else light_path;
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};

        var win = try ui.renderOnce(App, a, &fonts, dark, W, H);
        defer win.close();
        const content = gfx.Canvas.init(win.pixels, W, H, W);

        const raw_path = try std.fmt.allocPrint(a, "{s}_raw.png", .{path[0 .. path.len - 4]});
        defer a.free(raw_path);
        try gfx.png.writeFile(content, raw_path);

        // Vibrancy backdrop: blurred wallpaper + material tint, as drawn by
        // the window server's compositor for `transparent` windows.
        var wall = try gfx.Image.init(a, screen_w, screen_h);
        defer wall.deinit(a);
        try gfx.wallpaper.render(wall.canvas(), a, if (dark) .tahoe_night else .tahoe_day, .{ .detail = 3 });
        const wc = wall.canvas();
        try gfx.effects.blurFast(wc, a, wc.bounds(), 28);

        var out = try gfx.Image.init(a, W, H);
        defer out.deinit(a);
        const oc = out.canvas();
        oc.blitOpaque(wc.sub(gfx.Rect.init(win_x, win_y, W, H)), 0, 0);
        oc.fillRect(oc.bounds(), ui.pm(if (dark) 0x66202024 else 0x59F5F5F7));
        oc.drawImage(content, 0, 0, 255);
        try gfx.png.writeFile(oc, path);
        std.debug.print("wrote {s} (+ {s})\n", .{ path, raw_path });
    }
}
