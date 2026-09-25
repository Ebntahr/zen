//! Host preview: the Zen desktop with real app windows (Settings, Terminal,
//! Calculator) rendered by the apps themselves and composited by the real
//! window server compositor. Used for the README screenshots.
//! Usage: showcase <out.png> [dark]

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const ws = @import("windowserver");
const abi = @import("abi");

const W = 1440;
const H = 900;

fn addApp(
    comptime App: type,
    a: std.mem.Allocator,
    state: *ws.state.State,
    fonts: *ui.FontSet,
    dark: bool,
    pid: u32,
    name: []const u8,
    title: []const u8,
    extra_flags: u32,
    x: i32,
    y: i32,
) !void {
    var app = ws.state.App{ .pid = pid };
    @memcpy(app.name[0..name.len], name);
    app.name_len = name.len;
    try state.apps.append(a, app);
    const w = App.window.width;
    const h = App.window.height;
    var hw = try ui.renderOnce(App, a, fonts, dark, w, h);
    defer hw.close();
    const win = try state.manager.create(.{
        .pid = pid,
        .uid = 501,
        .w = w,
        .h = h,
        .x = x,
        .y = y,
        .flags = App.window.flags | extra_flags,
        .title = title,
    });
    ws.protocol.Protocol.resizeBuffer(win);
    win.title_height = hw.title_height;
    @memcpy(win.pixels, hw.pixels);
    _ = state.manager.focus(win.id);
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    const out = if (args.len > 1) args[1] else "/tmp/showcase.png";
    const dark = args.len > 2 and std.mem.eql(u8, args[2], "dark");

    var fonts = try ui.FontSet.load(a);
    const fb = try a.alloc(u32, W * H);
    var state = ws.state.State.init(a, W, H);
    state.appearance.dark = dark;
    state.session = .active;
    @memcpy(state.session_user[0..3], "zen");
    state.session_user_len = 3;
    const dock = [_]struct { []const u8, []const u8, []const u8, bool }{
        .{ "com.zen.Finder", "Finder", "finder", true },
        .{ "com.zen.Terminal", "Terminal", "terminal", true },
        .{ "com.zen.TextEdit", "TextEdit", "textedit", false },
        .{ "com.zen.Calculator", "Calculator", "calculator", true },
        .{ "com.zen.ActivityMonitor", "Activity Monitor", "activity", false },
        .{ "com.zen.Settings", "Settings", "settings", true },
        .{ "trash", "Trash", "trash", false },
    };
    for (dock) |d| try state.dock.append(a, .{ .id = d[0], .name = d[1], .icon = d[2], .pinned = true, .running = d[3] });

    var comp = try ws.compositor.Compositor.init(a, fb, W, H, &fonts);
    comp.setWallpaper(state.appearance.wallpaper, dark);

    // Back to front.
    const F = abi.window.Flags;
    try addApp(@import("settings_app").App, a, &state, &fonts, dark, 20, "Settings", "Settings", 0, 70, 64);
    try addApp(@import("calculator_app").App, a, &state, &fonts, dark, 21, "Calculator", "Calculator", 0, 1130, 96);
    // The terminal always uses its dark "Clear Dark" profile here.
    try addApp(@import("terminal_app").App, a, &state, &fonts, true, 22, "Terminal", "zen — zensh — 89×26", F.dark, 610, 330);

    state.mouse = .{ .x = 900, .y = 700 };
    _ = comp.compose(&state, gfx.Rect.init(0, 0, W, H));
    try gfx.png.writeFile(comp.fb, out);
    std.debug.print("wrote {s}\n", .{out});
}
