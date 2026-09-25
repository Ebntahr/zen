//! Render the app headless to a PNG: tools/zigmod run examples/zig-app/preview.zig -- out.png
const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    var fonts = try ui.FontSet.load(a);
    const win = try ui.renderOnce(App, a, &fonts, false, App.window.width, App.window.height);
    const w: u32 = @intCast(win.width);
    try gfx.png.writeFile(gfx.Canvas.init(win.pixels, w, @intCast(win.height), w), if (args.len > 1) args[1] else "/tmp/hello-zen.png");
}
