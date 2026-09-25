//! Interaction tests: drive the real Settings app headless with synthetic
//! window events (clicks, typing, menus) and check the resulting state.
//!
//!   tools/zigmod test apps/Settings/tests.zig

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const settings = @import("app.zig");

const Event = abi.window.Event;
const Key = abi.input.Key;

const Harness = struct {
    a: std.mem.Allocator,
    fonts: *ui.FontSet,
    win: *ui.Window,
    u: *ui.Ui,
    app: *settings.App,

    fn init(a: std.mem.Allocator) !Harness {
        const fonts = try a.create(ui.FontSet);
        errdefer a.destroy(fonts);
        fonts.* = ui.FontSet.load(a) catch return error.SkipZigTest;
        const win = try a.create(ui.Window);
        win.* = try ui.Window.openHeadless(a, settings.App.window);
        const u = try a.create(ui.Ui);
        u.* = ui.Ui.init(a, win, fonts);
        const app = try a.create(settings.App);
        app.* = try settings.App.init(a, u);
        app.preview(u); // sample data, General › About
        var h = Harness{ .a = a, .fonts = fonts, .win = win, .u = u, .app = app };
        h.frame(&.{});
        return h;
    }

    fn deinit(h: *Harness) void {
        h.app.deinit();
        h.u.deinit();
        h.win.close();
        h.fonts.deinit();
        h.a.destroy(h.app);
        h.a.destroy(h.u);
        h.a.destroy(h.win);
        h.a.destroy(h.fonts);
    }

    fn frame(h: *Harness, events: []const Event) void {
        h.u.beginFrame(events);
        if (h.u.menu_id) |id| h.app.onMenu(h.u, id);
        h.app.frame(h.u);
        h.u.endFrame();
    }

    fn click(h: *Harness, x: i32, y: i32) void {
        h.frame(&.{.{ .kind = .mouse_move, .a = x, .b = y }});
        h.frame(&.{.{ .kind = .mouse_down, .a = x, .b = y, .c = 1, .d = 1 }});
        h.frame(&.{.{ .kind = .mouse_up, .a = x, .b = y, .c = 1, .d = 1 }});
    }

    fn key(h: *Harness, code: u16, text: []const u8) void {
        var e = Event{ .kind = .key_down, .a = code };
        @memcpy(e.text[0..text.len], text);
        h.frame(&.{e});
    }

    fn typeText(h: *Harness, s: []const u8) void {
        for (s) |c| h.key(0, &.{c});
    }

    fn menu(h: *Harness, id: u32) void {
        h.frame(&.{.{ .kind = .menu, .a = @intCast(id) }});
    }
};

// Sidebar geometry (see App.drawSidebar): rows start below the user card.
fn sidebarRowY(index: usize, section_gaps: i32) i32 {
    return 138 + @as(i32, @intCast(index)) * 30 + section_gaps * 10 + 15;
}

test "sidebar, toolbar and menu navigation" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    const app = h.app;
    try std.testing.expectEqual(settings.Sub.about, app.loc.sub);

    h.click(100, sidebarRowY(1, 0)); // Appearance
    try std.testing.expectEqual(settings.Pane.appearance, app.loc.pane);
    h.click(100, sidebarRowY(5, 1)); // Users & Groups
    try std.testing.expectEqual(settings.Pane.users, app.loc.pane);

    // Back / forward in the toolbar capsule.
    h.click(settings.sidebar_w + 26, 26);
    try std.testing.expectEqual(settings.Pane.appearance, app.loc.pane);
    h.click(settings.sidebar_w + 58, 26);
    try std.testing.expectEqual(settings.Pane.users, app.loc.pane);

    // View menu (⌘3 = Wallpaper) and Back.
    h.menu(settings.MenuId.pane + 2);
    try std.testing.expectEqual(settings.Pane.wallpaper, app.loc.pane);
    h.menu(settings.MenuId.back);
    try std.testing.expectEqual(settings.Pane.users, app.loc.pane);

    // Arrow keys move through the sidebar when no field has focus.
    h.key(Key.down, "");
    try std.testing.expectEqual(settings.Pane.privacy, app.loc.pane);
}

test "search filters panes and Enter opens the first match" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    h.click(100, 62); // search field
    h.typeText("night");
    h.key(Key.enter, "");
    try std.testing.expectEqual(settings.Pane.displays, h.app.loc.pane);
    try std.testing.expectEqualStrings("night", h.app.search.text());
}

test "General rows navigate into sub-panes" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    h.app.go(.{ .pane = .general });
    h.frame(&.{});
    try std.testing.expectEqual(settings.Sub.none, h.app.loc.sub);
    // The first navigation row below the hero card is "About": scan down
    // the content column until a click lands on it.
    var y: i32 = settings.toolbar_h + 4;
    while (y < 420 and h.app.loc.sub == .none) : (y += 10) h.click(500, y);
    try std.testing.expectEqual(settings.Sub.about, h.app.loc.sub);
    // Escape (no focused field) returns to General.
    h.key(Key.esc, "");
    try std.testing.expectEqual(settings.Sub.none, h.app.loc.sub);
}

test "pop-up menu picks a time zone" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    h.app.go(.{ .pane = .general, .sub = .date_time });
    h.frame(&.{});
    // Layout: two groups (80 + 40) and a header, then the time zone row.
    const cy: i32 = settings.toolbar_h + 4 + 80 + 16 + 40 + 16 + 26 + 20;
    h.click(730, cy);
    try std.testing.expect(h.app.popup.open);
    const r = h.app.popup.rect;
    h.click(r.x + 40, r.y + 5 + 9 * 22 + 11); // "UTC+03:00 Riyadh"
    try std.testing.expect(!h.app.popup.open);
    try std.testing.expectEqual(@as(usize, 9), h.app.prefs.tz);
    // Clicking outside closes an open menu without selecting.
    h.click(730, cy);
    try std.testing.expect(h.app.popup.open);
    h.click(300, 500);
    try std.testing.expect(!h.app.popup.open);
    try std.testing.expectEqual(@as(usize, 9), h.app.prefs.tz);
}

test "add user sheet: typing, derived account name, tab and escape" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    h.app.go(.{ .pane = .users });
    h.frame(&.{});
    h.app.openSheet(h.u, .add_user);
    h.frame(&.{});
    h.typeText("Sara Ahmed");
    try std.testing.expectEqualStrings("Sara Ahmed", h.app.fields[0].text());
    try std.testing.expectEqualStrings("saraahmed", h.app.fields[1].text());
    h.key(Key.tab, "");
    h.key(Key.backspace, "");
    try std.testing.expectEqualStrings("saraahme", h.app.fields[1].text());
    h.key(Key.tab, "");
    h.typeText("pw");
    try std.testing.expectEqualStrings("pw", h.app.fields[2].text());
    // Submitting with mismatched/short passwords reports an error, no job.
    h.key(Key.enter, "");
    try std.testing.expect(h.app.sheet_error.len > 0);
    try std.testing.expectEqual(settings.Job.none, h.app.job);
    h.key(Key.esc, "");
    try std.testing.expectEqual(settings.SheetKind.none, h.app.sheet);
    try std.testing.expectEqualStrings("", h.app.fields[2].text());
}

test "appearance and accent choices update the theme" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    h.app.go(.{ .pane = .appearance });
    h.frame(&.{});
    try std.testing.expect(!h.u.theme.dark);
    // Dark card is the rightmost of the three thumbnails in the first row.
    h.click(760 - 14 - 36, 56 + 22 + 24);
    try std.testing.expect(h.u.theme.dark);
    try std.testing.expectEqual(settings.AppearanceMode.dark, h.app.prefs.appearance);
    // Purple accent swatch (second of eight).
    const x0: i32 = 760 - 14 - 10 - 7 * 26;
    h.click(x0 + 26, 56 + 116 + 24);
    try std.testing.expectEqual(@as(usize, 1), settings.App.accentIndex(h.u));
}
