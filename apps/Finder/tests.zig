//! Headless interaction tests: synthetic window events go through the real
//! `App.frame` path (keyboard navigation, history, new folder + rename,
//! trash, Go to Folder, search and list sorting).
//!
//!   tools/zigmod test apps/Finder/tests.zig

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const app = @import("app.zig");
const fs = @import("fs.zig");

const Event = abi.window.Event;
const Key = abi.input.Key;
const Mods = abi.window.Mods;

const Harness = struct {
    fonts: *ui.FontSet,
    win: *ui.Window,
    u: *ui.Ui,
    a: *app.App,

    fn init(opts: app.PreviewOptions) !Harness {
        const gpa = std.testing.allocator;
        const fonts = try gpa.create(ui.FontSet);
        fonts.* = ui.FontSet.load(gpa) catch {
            gpa.destroy(fonts);
            return error.SkipZigTest;
        };
        const win = try gpa.create(ui.Window);
        win.* = try ui.Window.openHeadless(gpa, .{ .width = 900, .height = 560 });
        const u = try gpa.create(ui.Ui);
        u.* = ui.Ui.init(gpa, win, fonts);
        app.preview_options = opts;
        const a = try gpa.create(app.App);
        a.* = try app.App.init(gpa, u);
        var h = Harness{ .fonts = fonts, .win = win, .u = u, .a = a };
        h.step(&.{});
        return h;
    }

    fn deinit(h: *Harness) void {
        const gpa = std.testing.allocator;
        h.a.deinit();
        h.u.deinit();
        h.win.close();
        h.fonts.deinit();
        gpa.destroy(h.a);
        gpa.destroy(h.u);
        gpa.destroy(h.win);
        gpa.destroy(h.fonts);
    }

    fn step(h: *Harness, events: []const Event) void {
        h.u.beginFrame(events);
        if (h.u.menu_id) |id| h.a.onMenu(h.u, id);
        h.a.frame(h.u);
        h.u.endFrame();
        var n: usize = 0;
        while (h.a.timeoutMs() == 0 and n < 4) : (n += 1) {
            h.u.beginFrame(&.{});
            h.a.frame(h.u);
            h.u.endFrame();
        }
    }

    fn key(h: *Harness, code: u16, mods: u32) void {
        h.step(&.{.{ .kind = .key_down, .a = code, .mods = mods }});
    }

    fn typeText(h: *Harness, s: []const u8) void {
        for (s) |c| {
            var e = Event{ .kind = .key_down, .a = Key.a };
            e.text[0] = c;
            h.step(&.{e});
        }
    }

    fn click(h: *Harness, x: i32, y: i32, count: i32) void {
        h.step(&.{ .{ .kind = .mouse_move, .a = x, .b = y }, .{ .kind = .mouse_down, .a = x, .b = y, .c = 1, .d = count } });
        h.step(&.{.{ .kind = .mouse_up, .a = x, .b = y, .c = 1, .d = count }});
    }

    fn menu(h: *Harness, id: u32) void {
        h.step(&.{.{ .kind = .menu, .a = @intCast(id) }});
    }

    fn loc(h: *Harness) []const u8 {
        return h.a.loc_buf[0..h.a.loc_len];
    }

    fn selectedName(h: *Harness) ?[]const u8 {
        const i = h.a.sel orelse return null;
        return h.a.listing.entries[i].name;
    }
};

fn makeTree(buf: []u8) ![]const u8 {
    const root = try std.fmt.bufPrint(buf, "/tmp/zen_apps/finder_test_{d}", .{std.time.nanoTimestamp()});
    for ([_][]const u8{ "/Documents/Alpha", "/Documents/Beta", "/Downloads" }) |d| {
        var pb: [256]u8 = undefined;
        try std.fs.cwd().makePath(try std.fmt.bufPrint(&pb, "{s}{s}", .{ root, d }));
    }
    const files = [_]struct { []const u8, usize }{
        .{ "/Documents/notes.txt", 10 },
        .{ "/Documents/zeta.md", 3000 },
        .{ "/Documents/photo.png", 500 },
        .{ "/Documents/Alpha/inner.txt", 1 },
    };
    for (files) |f| {
        var pb: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}{s}", .{ root, f[0] });
        const file = try std.fs.cwd().createFile(p, .{});
        defer file.close();
        var i: usize = 0;
        while (i < f[1]) : (i += 1) try file.writeAll("x");
    }
    return root;
}

test "keyboard navigation and history" {
    var rb: [128]u8 = undefined;
    const root = try makeTree(&rb);
    defer std.fs.cwd().deleteTree(root) catch {};
    var db: [256]u8 = undefined;
    const docs = try std.fmt.bufPrint(&db, "{s}/Documents", .{root});
    var h = try Harness.init(.{ .home = root, .location = docs });
    defer h.deinit();
    // Name order: Alpha, Beta, notes.txt, photo.png, zeta.md.
    try std.testing.expectEqual(@as(usize, 5), h.a.order.items.len);
    h.key(Key.right, 0);
    try std.testing.expectEqualStrings("Alpha", h.selectedName().?);
    h.key(Key.right, 0);
    try std.testing.expectEqualStrings("Beta", h.selectedName().?);
    h.key(Key.left, 0);
    // Enter opens the folder.
    h.key(Key.enter, 0);
    try std.testing.expect(std.mem.endsWith(u8, h.loc(), "/Documents/Alpha"));
    // Cmd+Up goes to the parent and selects where we came from.
    h.key(Key.up, Mods.cmd);
    try std.testing.expectEqualStrings(docs, h.loc());
    try std.testing.expectEqualStrings("Alpha", h.selectedName().?);
    // Back / forward.
    h.key(Key.leftbrace, Mods.cmd);
    try std.testing.expect(std.mem.endsWith(u8, h.loc(), "/Alpha"));
    h.key(Key.rightbrace, Mods.cmd);
    try std.testing.expectEqualStrings(docs, h.loc());
    // Type-to-select.
    h.typeText("ph");
    try std.testing.expectEqualStrings("photo.png", h.selectedName().?);
    // Double-click a folder in the grid navigates.
    h.key(Key.home, 0);
    const x = 212 + 14 + 52;
    const y = 52 + 14 + 40;
    h.click(x, y, 1);
    h.click(x, y, 2);
    try std.testing.expect(std.mem.endsWith(u8, h.loc(), "/Alpha"));
}

test "new folder, inline rename, trash" {
    var rb: [128]u8 = undefined;
    const root = try makeTree(&rb);
    defer std.fs.cwd().deleteTree(root) catch {};
    var db: [256]u8 = undefined;
    const docs = try std.fmt.bufPrint(&db, "{s}/Documents", .{root});
    var h = try Harness.init(.{ .home = root, .location = docs });
    defer h.deinit();

    h.key(Key.n, Mods.cmd | Mods.shift);
    try std.testing.expect(h.a.renaming);
    try std.testing.expectEqualStrings("untitled folder", h.selectedName().?);
    // The whole name is selected: typing replaces it.
    h.typeText("Projects");
    h.key(Key.enter, 0);
    try std.testing.expect(!h.a.renaming);
    try std.testing.expectEqualStrings("Projects", h.selectedName().?);
    var pb: [256]u8 = undefined;
    try std.fs.cwd().access(try std.fmt.bufPrint(&pb, "{s}/Projects", .{docs}), .{});

    // Move it to the Trash.
    h.key(Key.backspace, Mods.cmd);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(try std.fmt.bufPrint(&pb, "{s}/Projects", .{docs}), .{}));
    try std.fs.cwd().access(try std.fmt.bufPrint(&pb, "{s}/.Trash/Projects", .{root}), .{});
    try std.testing.expectEqual(@as(usize, 5), h.a.order.items.len);

    // A second "untitled folder" gets a number.
    h.key(Key.n, Mods.cmd | Mods.shift);
    h.key(Key.enter, 0);
    h.key(Key.n, Mods.cmd | Mods.shift);
    try std.testing.expectEqualStrings("untitled folder 2", h.selectedName().?);
    h.key(Key.esc, 0);
    try std.testing.expect(!h.a.renaming);
}

test "go to folder, search, list sorting" {
    var rb: [128]u8 = undefined;
    const root = try makeTree(&rb);
    defer std.fs.cwd().deleteTree(root) catch {};
    var h = try Harness.init(.{ .home = root, .location = root });
    defer h.deinit();

    // Go to Folder with a ~ path.
    h.key(Key.g, Mods.cmd | Mods.shift);
    try std.testing.expect(h.a.sheet == .goto);
    h.step(&.{.{ .kind = .key_down, .a = Key.a, .mods = Mods.cmd }});
    h.typeText("~/Documents");
    h.key(Key.enter, 0);
    try std.testing.expect(h.a.sheet == .none);
    try std.testing.expect(std.mem.endsWith(u8, h.loc(), "/Documents"));

    // A missing folder keeps the sheet open with an error.
    h.key(Key.g, Mods.cmd | Mods.shift);
    h.step(&.{.{ .kind = .key_down, .a = Key.a, .mods = Mods.cmd }});
    h.typeText("/does/not/exist");
    h.key(Key.enter, 0);
    try std.testing.expect(h.a.sheet == .goto and h.a.goto_error);
    h.key(Key.esc, 0);
    try std.testing.expect(h.a.sheet == .none);

    // Search filters the folder.
    h.key(Key.f, Mods.cmd);
    h.typeText("TXT");
    try std.testing.expectEqual(@as(usize, 1), h.a.order.items.len);
    h.key(Key.esc, 0);
    try std.testing.expectEqual(@as(usize, 5), h.a.order.items.len);

    // List view: click the Size header twice → descending by size.
    h.menu(app.M.view_list);
    try std.testing.expect(h.a.view == .list);
    const size_x = 900 - 16 - 150 - 84 + 40;
    h.click(size_x, 52 + 14, 1);
    try std.testing.expect(h.a.sort_key == .size and !h.a.sort_asc);
    const first = h.a.listing.entries[h.a.order.items[0]];
    try std.testing.expectEqualStrings("zeta.md", first.name);

    // Get Info opens and closes.
    h.key(Key.i, Mods.cmd);
    try std.testing.expect(h.a.sheet == .info);
    h.key(Key.esc, 0);
    try std.testing.expect(h.a.sheet == .none);
}

test "opening documents without a launch service shows an alert" {
    var rb: [128]u8 = undefined;
    const root = try makeTree(&rb);
    defer std.fs.cwd().deleteTree(root) catch {};
    var db: [256]u8 = undefined;
    const docs = try std.fmt.bufPrint(&db, "{s}/Documents", .{root});
    var h = try Harness.init(.{ .home = root, .location = docs, .selected = "notes.txt" });
    defer h.deinit();
    h.key(Key.down, Mods.cmd);
    try std.testing.expect(h.a.alert_len > 0);
    h.key(Key.esc, 0);
    try std.testing.expectEqual(@as(usize, 0), h.a.alert_len);
    // Images open in Preview (launchd is not running in the test, so the
    // attempt ends in an alert about the launch service).
    h.typeText("photo");
    h.key(Key.enter, 0);
    try std.testing.expect(std.mem.indexOf(u8, h.a.alert_buf[0..h.a.alert_len], "launch service") != null);
}

test "launchd argument quoting" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"/a b/c\\\"d\"", fs.quoteArg(&buf, "/a b/c\"d"));
}

test {
    _ = fs;
}
