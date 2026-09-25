//! Headless interaction tests: synthetic window events go through the real
//! `App.frame` path (keyboard, mouse selection, menus, save/close flows).
//!
//!   tools/zigmod test apps/TextEdit/tests.zig

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const app = @import("app.zig");

test {
    _ = @import("find.zig");
}

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
        win.* = try ui.Window.openHeadless(gpa, .{ .width = 700, .height = 520 });
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
        if (h.u.close_requested) {
            h.u.close_requested = false;
            if (h.a.shouldClose(h.u)) h.u.quit = true;
        }
        h.a.frame(h.u);
        h.u.endFrame();
        // Settle frames requested by state changes.
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
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepointSlice()) |cp| {
            var e = Event{ .kind = .key_down, .a = Key.a };
            @memcpy(e.text[0..cp.len], cp);
            h.step(&.{e});
        }
    }

    fn click(h: *Harness, x: i32, y: i32, count: i32, mods: u32) void {
        h.step(&.{
            .{ .kind = .mouse_move, .a = x, .b = y, .mods = mods },
            .{ .kind = .mouse_down, .a = x, .b = y, .c = 1, .d = count, .mods = mods },
        });
        h.step(&.{.{ .kind = .mouse_up, .a = x, .b = y, .c = 1, .d = count, .mods = mods }});
    }

    fn menu(h: *Harness, id: u32) void {
        h.step(&.{.{ .kind = .menu, .a = @intCast(id) }});
    }

    fn text(h: *Harness) []const u8 {
        return h.a.editor.bytes();
    }
};

fn tmpDocs(buf: []u8) ![]const u8 {
    const d = try std.fmt.bufPrint(buf, "/tmp/zen_apps/te_test_{d}", .{std.time.nanoTimestamp()});
    try std.fs.cwd().makePath(d);
    return d;
}

test "typing, editing keys, undo and redo" {
    var h = try Harness.init(.{ .text = "", .documents = "/tmp" });
    defer h.deinit();
    h.typeText("Hello wörld");
    try std.testing.expectEqualStrings("Hello wörld", h.text());
    try std.testing.expect(h.a.editor.isDirty());
    h.key(Key.backspace, 0);
    h.key(Key.backspace, 0);
    try std.testing.expectEqualStrings("Hello wör", h.text());
    h.key(Key.enter, 0);
    h.key(Key.tab, 0);
    h.typeText("x");
    try std.testing.expectEqualStrings("Hello wör\n\tx", h.text());
    // Word-wise delete and line navigation.
    h.key(Key.up, 0);
    h.key(Key.end, 0);
    h.key(Key.backspace, Mods.alt);
    try std.testing.expectEqualStrings("Hello \n\tx", h.text());
    h.menu(app.M.undo);
    try std.testing.expectEqualStrings("Hello wör\n\tx", h.text());
    h.menu(app.M.undo);
    h.menu(app.M.undo);
    h.menu(app.M.undo);
    h.menu(app.M.undo);
    try std.testing.expectEqualStrings("", h.text());
    try std.testing.expect(!h.a.editor.isDirty());
    h.menu(app.M.redo);
    try std.testing.expectEqualStrings("Hello wörld", h.text());
    // Select all + type replaces everything.
    h.menu(app.M.select_all);
    h.typeText("new");
    try std.testing.expectEqualStrings("new", h.text());
}

test "shift-selection, vertical movement keeps the column" {
    var h = try Harness.init(.{ .text = "abcdefgh\nab\nabcdefgh", .documents = "/tmp" });
    defer h.deinit();
    // Caret after "abcdef" on line 1.
    for (0..6) |_| h.key(Key.right, 0);
    h.key(Key.down, 0);
    try std.testing.expectEqual(@as(usize, 11), h.a.editor.cursor); // end of "ab"
    h.key(Key.down, 0);
    try std.testing.expectEqual(@as(usize, 18), h.a.editor.cursor); // column kept: "abcdef|gh"
    h.key(Key.left, Mods.shift);
    h.key(Key.left, Mods.shift);
    try std.testing.expectEqualStrings("ef", h.a.editor.selectedText());
    h.key(Key.home, Mods.shift);
    try std.testing.expectEqualStrings("abcdef", h.a.editor.selectedText());
}

test "mouse: click, drag, double and triple click" {
    var h = try Harness.init(.{ .text = "The quick brown fox\njumps over the lazy dog", .documents = "/tmp" });
    defer h.deinit();
    const e = &h.a.editor;
    const lh: i32 = @intFromFloat(e.lineHeight(h.u));
    const y1: i32 = 44 + 18 + @divTrunc(lh, 2); // toolbar + top padding
    const y2 = y1 + lh;
    // Double-click a word on the first line.
    const f = e.face(h.u);
    const x_quick: i32 = 28 + @as(i32, @intFromFloat(f.measure("The qu")));
    h.click(x_quick, y1, 1, 0);
    h.click(x_quick, y1, 2, 0);
    try std.testing.expectEqualStrings("quick", e.selectedText());
    // Triple-click selects the paragraph including its newline.
    h.click(x_quick, y1, 3, 0);
    try std.testing.expectEqualStrings("The quick brown fox\n", e.selectedText());
    // Drag from the start of line 2 to after "jumps".
    const x_end: i32 = 28 + @as(i32, @intFromFloat(f.measure("jumps")));
    h.step(&.{ .{ .kind = .mouse_move, .a = 29, .b = y2 }, .{ .kind = .mouse_down, .a = 29, .b = y2, .c = 1, .d = 1 } });
    h.step(&.{.{ .kind = .mouse_move, .a = x_end, .b = y2 }});
    h.step(&.{.{ .kind = .mouse_up, .a = x_end, .b = y2, .c = 1, .d = 1 }});
    try std.testing.expectEqualStrings("jumps", e.selectedText());
    // Shift-click extends.
    h.click(28 + @as(i32, @intFromFloat(f.measure("jumps over"))), y2, 1, Mods.shift);
    try std.testing.expectEqualStrings("jumps over", e.selectedText());
}

test "save, dirty state and close confirmation" {
    var db: [128]u8 = undefined;
    const docs = try tmpDocs(&db);
    defer std.fs.cwd().deleteTree(docs) catch {};
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/note.txt", .{docs});
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "draft" });

    var h = try Harness.init(.{ .text = "draft", .path = path, .documents = docs });
    defer h.deinit();
    h.key(Key.end, Mods.cmd);
    h.typeText(" two");
    try std.testing.expect(h.a.editor.isDirty());
    h.menu(app.M.save);
    try std.testing.expect(!h.a.editor.isDirty());
    const saved = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("draft two", saved);

    // Unsaved changes: closing asks first; Cancel keeps the window.
    h.typeText("!");
    h.step(&.{.{ .kind = .close_request }});
    try std.testing.expect(!h.u.quit);
    h.key(Key.esc, 0);
    try std.testing.expect(!h.u.quit);
    // Close again, then "Save" from the sheet (Enter) saves and quits.
    h.step(&.{.{ .kind = .close_request }});
    h.key(Key.enter, 0);
    try std.testing.expect(h.u.quit);
    const saved2 = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(saved2);
    try std.testing.expectEqualStrings("draft two!", saved2);
}

test "save as an untitled document via the sheet" {
    var db: [128]u8 = undefined;
    const docs = try tmpDocs(&db);
    defer std.fs.cwd().deleteTree(docs) catch {};
    var h = try Harness.init(.{ .text = "", .documents = docs });
    defer h.deinit();
    h.typeText("hello");
    h.menu(app.M.save);
    // The sheet proposes "Untitled.txt" with the stem selected: type a name.
    h.typeText("greeting");
    h.key(Key.enter, 0);
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/greeting.txt", .{docs});
    const data = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello", data);
    try std.testing.expect(!h.a.editor.isDirty());

    // New → Open the file again through the sheet by typing its name.
    h.menu(app.M.new);
    try std.testing.expectEqualStrings("", h.text());
    h.menu(app.M.open);
    h.typeText("greeting.txt");
    h.key(Key.enter, 0);
    try std.testing.expectEqualStrings("hello", h.text());
}

test "file: URLs from Finder are decoded" {
    var db: [128]u8 = undefined;
    const docs = try tmpDocs(&db);
    defer std.fs.cwd().deleteTree(docs) catch {};
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/My Notes.txt", .{docs});
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "spaces ok" });
    var h = try Harness.init(.{ .text = "", .documents = docs });
    defer h.deinit();
    var ub: [300]u8 = undefined;
    var eb: [300]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "file:{s}", .{@import("zen").url.encode(path, &eb)});
    try std.testing.expect(std.mem.indexOf(u8, url, "%20") != null);
    h.a.openPathArg(url);
    try std.testing.expectEqualStrings("spaces ok", h.text());
}

test "find bar: incremental search, next, replace all, escape" {
    var h = try Harness.init(.{ .text = "red fish, blue fish\nFish tales", .documents = "/tmp" });
    defer h.deinit();
    const a = h.a;
    h.menu(app.M.find);
    try std.testing.expect(a.find_open);
    h.typeText("fish");
    // Typing selects the first match after the caret.
    try std.testing.expectEqual(@as(usize, 3), a.finder.matches.items.len);
    try std.testing.expectEqualStrings("fish", a.editor.selectedText());
    try std.testing.expectEqual(@as(usize, 4), a.editor.selection().a);
    // The typed text went to the field, not the document.
    try std.testing.expectEqualStrings("red fish, blue fish\nFish tales", h.text());
    h.key(Key.enter, 0);
    try std.testing.expectEqual(@as(usize, 15), a.editor.selection().a);
    h.key(Key.enter, Mods.shift);
    try std.testing.expectEqual(@as(usize, 4), a.editor.selection().a);
    h.menu(app.M.find_next);
    h.menu(app.M.find_next);
    try std.testing.expectEqualStrings("Fish", a.editor.selectedText());

    // Find and Replace: Tab moves to the replace field.
    h.menu(app.M.find_replace);
    try std.testing.expect(a.find_replace);
    h.key(Key.tab, 0);
    h.typeText("cat");
    try std.testing.expectEqualStrings("cat", a.replace_field.text());
    _ = a.finder.replaceAll(std.testing.allocator, &a.editor, a.find_field.text(), a.replace_field.text());
    try std.testing.expectEqualStrings("red cat, blue cat\ncat tales", h.text());
    h.menu(app.M.undo);
    try std.testing.expectEqualStrings("red fish, blue fish\nFish tales", h.text());

    // Escape closes the bar and gives the keyboard back to the document.
    h.step(&.{});
    h.a.find_replace = false;
    h.menu(app.M.find);
    h.key(Key.esc, 0);
    try std.testing.expect(!a.find_open);
    h.typeText("!");
    try std.testing.expect(std.mem.indexOfScalar(u8, h.text(), '!') != null);
}
