//! Standard app runner: window, fonts, menus and the event loop.
//!
//! An app type provides:
//!   pub const window: client.Options
//!   pub fn init(allocator, *Ui) !Self
//!   pub fn frame(self: *Self, *Ui) void
//! and optionally:
//!   pub fn menu(self: *Self, *abi.window.MenuWriter) void
//!   pub fn onMenu(self: *Self, *Ui, id: u32) void
//!   pub fn shouldClose(self: *Self, *Ui) bool     (close button / Cmd-W)
//!   pub fn shouldQuit(self: *Self, *Ui) bool      (logout/shutdown; return false
//!                                                  to ask the user first, then
//!                                                  set `u.quit` when done)
//!   pub fn timeoutMs(self: *Self) i32             (periodic refresh, -1 = none)
//! Setting `u.want_frame` in `frame` requests another frame right away.
//!   pub fn deinit(self: *Self) void

const std = @import("std");
const abi = @import("abi");
const client = @import("client.zig");
const ui_mod = @import("ui.zig");
const fonts_mod = @import("fonts.zig");

pub fn run(comptime App: type) !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa_state.allocator();
    var fonts = try fonts_mod.FontSet.load(allocator);
    defer fonts.deinit();
    var win = try client.Window.open(allocator, App.window);
    defer win.close();
    var u = ui_mod.Ui.init(allocator, &win, &fonts);
    defer u.deinit();
    var app = try App.init(allocator, &u);
    defer if (@hasDecl(App, "deinit")) app.deinit();

    if (@hasDecl(App, "menu")) {
        var buf: [4096]u8 = undefined;
        var mw = abi.window.MenuWriter{ .buf = &buf };
        app.menu(&mw);
        win.setMenu(mw.bytes());
    }

    u.beginFrame(&.{});
    app.frame(&u);
    u.endFrame();

    while (!u.quit) {
        const timeout: i32 = if (u.want_frame) 0 else if (@hasDecl(App, "timeoutMs")) app.timeoutMs() else -1;
        const events = win.waitEvents(timeout);
        if (win.headless) break;
        u.beginFrame(events);
        if (u.menu_id) |id| {
            if (@hasDecl(App, "onMenu")) app.onMenu(&u, id);
        }
        if (u.close_requested) {
            u.close_requested = false;
            const close = if (@hasDecl(App, "shouldClose")) app.shouldClose(&u) else true;
            if (close) break;
        }
        if (u.quit_requested) {
            u.quit_requested = false;
            const q = if (@hasDecl(App, "shouldQuit")) app.shouldQuit(&u) else true;
            if (q) break;
        }
        if (u.quit) break;
        app.frame(&u);
        u.endFrame();
    }
}

/// Render one frame of an app into a headless window (host previews).
pub fn renderOnce(comptime App: type, allocator: std.mem.Allocator, fonts: *fonts_mod.FontSet, dark: bool, width: i32, height: i32) !client.Window {
    var opts = App.window;
    opts.width = width;
    opts.height = height;
    var win = try client.Window.openHeadless(allocator, opts);
    var u = ui_mod.Ui.init(allocator, &win, fonts);
    defer u.deinit();
    u.setDark(dark, null);
    var app = try App.init(allocator, &u);
    defer if (@hasDecl(App, "deinit")) app.deinit();
    if (@hasDecl(App, "preview")) app.preview(&u);
    u.beginFrame(&.{});
    app.frame(&u);
    u.endFrame();
    // Second frame so hover/layout-dependent state settles.
    u.beginFrame(&.{});
    app.frame(&u);
    u.endFrame();
    return win;
}
