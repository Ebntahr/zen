//! Host preview: render the Zen desktop with the real compositor into a PNG.
//! Usage: desktop <out.png> [dark]

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const ws = @import("windowserver");
const abi = @import("abi");

const W = 1280;
const H = 800;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    const out = if (args.len > 1) args[1] else "/tmp/desktop.png";
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
        .{ "com.zen.Calculator", "Calculator", "calculator", false },
        .{ "com.zen.ActivityMonitor", "Activity Monitor", "activity", false },
        .{ "com.zen.Settings", "Settings", "settings", true },
        .{ "trash", "Trash", "trash", false },
    };
    for (dock) |d| try state.dock.append(a, .{ .id = d[0], .name = d[1], .icon = d[2], .pinned = true, .running = d[3] });

    var comp = try ws.compositor.Compositor.init(a, fb, W, H, &fonts);
    comp.setWallpaper(state.appearance.wallpaper, dark);

    // Two sample windows drawn with the toolkit.
    const specs = [_]struct { []const u8, i32, i32, i32, i32 }{
        .{ "Documents", 120, 110, 640, 420 },
        .{ "Welcome to Zen OS", 560, 260, 520, 340 },
    };
    for (specs) |sp| {
        const win = try state.manager.create(.{ .pid = 10, .uid = 501, .w = sp[3], .h = sp[4], .x = sp[1], .y = sp[2], .flags = abi.window.Flags.resizable, .title = sp[0] });
        ws.protocol.Protocol.resizeBuffer(win);
        var hw = try ui.Window.openHeadless(a, .{ .width = sp[3], .height = sp[4] });
        var u = ui.Ui.init(a, &hw, &fonts);
        u.setDark(dark, null);
        u.beginFrame(&.{});
        u.clear(u.theme.content_bg);
        u.text(ui.Rect.init(24, 20, 400, 30), sp[0], .{ .size = 22, .weight = .bold });
        _ = u.paragraph(ui.Rect.init(24, 64, sp[3] - 48, 200), "Zen OS is a microkernel desktop written in Zig for RISC-V. Everything is a URL: file:/Users/zen, sys:proc, display:0.", .{ .color = u.theme.secondary_label });
        _ = u.button("ok", ui.Rect.init(sp[3] - 124, sp[4] - 52, 100, 30), "Continue", .{ .style = .primary });
        _ = u.button("cancel", ui.Rect.init(sp[3] - 234, sp[4] - 52, 100, 30), "Cancel", .{});
        var on = true;
        _ = u.toggle("t", 24, 140, &on);
        u.text(ui.Rect.init(76, 140, 300, 24), "Liquid Glass effects", .{});
        @memcpy(win.pixels, hw.pixels);
        _ = state.manager.focus(win.id);
    }
    if (args.len > 3 and std.mem.eql(u8, args[3], "spotlight")) {
        const items = [_]ws.state.SpotlightItem{
            .{ .id = "com.zen.Terminal", .name = "Terminal", .icon = "terminal", .path = "" },
            .{ .id = "com.zen.TextEdit", .name = "TextEdit", .icon = "textedit", .path = "" },
            .{ .id = "com.zen.Settings", .name = "Settings", .icon = "settings", .path = "" },
        };
        for (items) |it| try state.spotlight.items.append(a, it);
        state.spotlight.active = true;
        @memcpy(state.spotlight.query[0..2], "te");
        state.spotlight.query_len = 2;
    }
    if (args.len > 3 and std.mem.eql(u8, args[3], "control")) ws.control.open = true;
    state.mouse = .{ .x = 700, .y = 740 };
    ws.chrome.dockHover(&state, 700, 740);
    _ = comp.compose(&state, gfx.Rect.init(0, 0, W, H));
    try gfx.png.writeFile(comp.fb, out);
    std.debug.print("wrote {s}\n", .{out});
}
