//! Host previews of Settings: renders panes in light and dark mode and
//! composites the window over a blurred wallpaper the way the window server
//! does for translucent windows (so the glass sidebar looks right).
//!
//!   tools/zigmod run apps/Settings/preview.zig -O ReleaseFast -- [out_dir] [name-filter]
//!
//! Writes <out_dir>/settings_<pane>_<light|dark>.png (default /tmp/zen_apps).

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const settings = @import("app.zig");

/// Where the window sits on a 1280×800 desktop (for the backdrop crop).
const win_x = 220;
const win_y = 60;

const Shot = struct {
    name: []const u8,
    target: settings.PreviewTarget,
    w: i32 = 780,
    h: i32 = 560,
};

const shots = [_]Shot{
    .{ .name = "about", .target = .{ .pane = .general, .sub = .about } },
    .{ .name = "general", .target = .{ .pane = .general } },
    .{ .name = "update", .target = .{ .pane = .general, .sub = .software_update } },
    .{ .name = "datetime", .target = .{ .pane = .general, .sub = .date_time } },
    .{ .name = "language", .target = .{ .pane = .general, .sub = .language } },
    .{ .name = "sharing", .target = .{ .pane = .general, .sub = .sharing } },
    .{ .name = "appearance", .target = .{ .pane = .appearance } },
    .{ .name = "wallpaper", .target = .{ .pane = .wallpaper } },
    .{ .name = "displays", .target = .{ .pane = .displays } },
    .{ .name = "keyboard", .target = .{ .pane = .keyboard } },
    .{ .name = "users", .target = .{ .pane = .users } },
    .{ .name = "adduser", .target = .{ .pane = .users, .sheet = .add_user } },
    .{ .name = "password", .target = .{ .pane = .users, .sheet = .change_password } },
    .{ .name = "privacy", .target = .{ .pane = .privacy } },
    .{ .name = "lock", .target = .{ .pane = .lock_screen } },
    .{ .name = "storage", .target = .{ .pane = .storage } },
    .{ .name = "developer", .target = .{ .pane = .developer } },
    // Lower parts of long panes, and a larger window.
    .{ .name = "scrolled-privacy", .target = .{ .pane = .privacy, .scroll = 1000 } },
    .{ .name = "scrolled-developer", .target = .{ .pane = .developer, .scroll = 1000 } },
    .{ .name = "scrolled-displays", .target = .{ .pane = .displays, .scroll = 1000 } },
    .{ .name = "scrolled-keyboard", .target = .{ .pane = .keyboard, .scroll = 1000 } },
    .{ .name = "scrolled-about", .target = .{ .pane = .general, .sub = .about, .scroll = 1000 } },
    .{ .name = "large-appearance", .target = .{ .pane = .appearance }, .w = 1040, .h = 700 },
};

fn backdrop(a: std.mem.Allocator, desk: *const gfx.Image, dark: bool, w: i32, h: i32) !gfx.Image {
    var img = try gfx.Image.init(a, @intCast(w), @intCast(h));
    const c = img.canvas();
    c.blitOpaque(desk.canvas().sub(gfx.Rect.init(win_x, win_y, w, h)), 0, 0);
    // Vibrancy tint applied by the compositor under translucent windows.
    c.fillRect(c.bounds(), ui.pm(if (dark) 0x66202024 else 0x59F5F5F7));
    return img;
}

fn compose(a: std.mem.Allocator, win: *ui.Window, back: *const gfx.Image) !gfx.Image {
    const w = win.width;
    const h = win.height;
    var flat = try gfx.Image.init(a, @intCast(w), @intCast(h));
    defer flat.deinit(a);
    const fc = flat.canvas();
    fc.blitOpaque(back.canvas(), 0, 0);
    fc.blit(gfx.Canvas.init(win.pixels, @intCast(w), @intCast(h), @intCast(w)), 0, 0);
    // Traffic lights float over the sidebar (drawn by the window server).
    const colors = [3]u32{ ui.theme.traffic_close, ui.theme.traffic_minimize, ui.theme.traffic_zoom };
    for (colors, 0..) |col, i| {
        const cx: f32 = @floatFromInt(20 + i * 20);
        fc.fillCircle(cx, 26, 6.5, ui.pm(col));
        fc.strokeCircle(cx, 26, 6.5, 0.6, ui.pm(0x26000000));
    }
    // Rounded window corners.
    var out = try gfx.Image.init(a, @intCast(w), @intCast(h));
    const paint = gfx.Paint{ .image = .{ .src = fc, .x = 0, .y = 0 } };
    out.canvas().fillRoundRect(gfx.Rect.init(0, 0, w, h), 14, &paint);
    out.canvas().strokeRoundRect(gfx.Rect.init(0, 0, w, h), 14, 1, ui.pm(0x33000000));
    return out;
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const out_dir = if (args.len > 1) args[1] else "/tmp/zen_apps";
    const filter: ?[]const u8 = if (args.len > 2) args[2] else null;
    try std.fs.cwd().makePath(out_dir);

    var fonts = try ui.FontSet.load(a);
    defer fonts.deinit();

    // Blurred desktop wallpaper (what the compositor samples for vibrancy).
    var desk = try gfx.Image.init(a, 1280, 800);
    defer desk.deinit(a);
    try gfx.wallpaper.render(desk.canvas(), a, .golden_gate, .{});
    try gfx.effects.blurFast(desk.canvas(), a, desk.canvas().bounds(), 28);

    for ([_]bool{ false, true }) |dark| {
        for (shots) |s| {
            if (filter) |fl| if (std.mem.indexOf(u8, s.name, fl) == null) continue;
            var back = try backdrop(a, &desk, dark, s.w, s.h);
            defer back.deinit(a);
            settings.preview_target = s.target;
            var win = try ui.renderOnce(settings.App, a, &fonts, dark, s.w, s.h);
            defer win.close();
            var img = try compose(a, &win, &back);
            defer img.deinit(a);
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/settings_{s}_{s}.png", .{ out_dir, s.name, if (dark) "dark" else "light" });
            try gfx.png.writeFile(img.canvas(), path);
            std.debug.print("wrote {s}\n", .{path});
        }
    }
}
