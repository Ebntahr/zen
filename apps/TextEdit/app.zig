//! TextEdit: a plain-text editor for Zen OS.
//!
//! TextEdit is sandboxed: it may write only inside its container ($HOME)
//! and the user's Documents folder ($ZEN_USER_HOME/Documents, granted by
//! the documents entitlement). Files opened from Finder arrive as argv[1],
//! either as a path or as a percent-encoded `file:` URL.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const abi = @import("abi");
const zen = @import("zen");
const icons = @import("icons");
const editor_mod = @import("editor.zig");
const find_mod = @import("find.zig");

const Editor = editor_mod.Editor;
const Ui = ui.Ui;
const Rect = ui.Rect;
const TextState = ui.TextState;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const Flags = abi.window.Flags;
const hashId = ui.ui.hashId;
const pm = ui.pm;

const TOOLBAR_H: i32 = 44;
const FIND_ROW_H: i32 = 38;
const max_path = 1024;
const max_file = 32 << 20;

const font_sizes = [_]f32{ 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 36, 48, 64 };

pub const PreviewOptions = struct {
    text: []const u8,
    path: ?[]const u8 = null,
    documents: ?[]const u8 = null,
    cursor: usize = 0,
    anchor: usize = 0,
    scroll_y: f32 = 0,
    mono: bool = false,
    size: f32 = 15,
    wrap: bool = true,
    dirty: bool = false,
    sheet: enum { none, save, open, confirm } = .none,
    sheet_text: []const u8 = "",
    /// Open the find bar with this query (and the replace row).
    find: ?[]const u8 = null,
    replace: ?[]const u8 = null,
};
pub var preview_options: ?PreviewOptions = null;

pub const M = struct {
    pub const about = 1;
    pub const quit = 2;
    pub const new = 10;
    pub const open = 11;
    pub const close = 12;
    pub const save = 13;
    pub const save_as = 14;
    pub const revert = 15;
    pub const undo = 20;
    pub const redo = 21;
    pub const cut = 22;
    pub const copy = 23;
    pub const paste = 24;
    pub const delete = 25;
    pub const select_all = 26;
    pub const bigger = 30;
    pub const smaller = 31;
    pub const actual = 32;
    pub const wrap = 33;
    pub const mono = 34;
    pub const find = 40;
    pub const find_replace = 41;
    pub const find_next = 42;
    pub const find_previous = 43;
    pub const find_selection = 44;
};

const Sheet = enum { none, open, save, confirm, alert };
const Pending = enum { none, close, quit, new, open, open_path };

const DirEntry = struct { name: []const u8, is_dir: bool };

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Untitled",
        .width = 700,
        .height = 520,
        .min_width = 440,
        .min_height = 260,
        .flags = Flags.resizable,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    editor: Editor,
    documents: []const u8,
    path_buf: [max_path]u8 = undefined,
    path_len: usize = 0,

    // Window state last sent to the server.
    shown_title: [128]u8 = undefined,
    shown_title_len: usize = 0,
    shown_dirty: bool = false,
    menu_flags: u32 = 0xFFFFFFFF,

    stats_version: u64 = std.math.maxInt(u64),
    words: usize = 0,
    chars: usize = 0,

    sheet: Sheet = .none,
    pending: Pending = .none,
    /// Document waiting for `.open_path` (after the save question).
    pending_path: [max_path]u8 = undefined,
    pending_path_len: usize = 0,
    field: TextState = .{},
    sheet_dir_buf: [max_path]u8 = undefined,
    sheet_dir_len: usize = 0,
    sheet_entries: std.ArrayList(DirEntry) = .empty,
    sheet_names: std.heap.ArenaAllocator,
    sheet_sel: ?usize = null,
    sheet_scroll: ui.ScrollState = .{},
    sheet_error: [200]u8 = undefined,
    sheet_error_len: usize = 0,
    alert_title: [200]u8 = undefined,
    alert_title_len: usize = 0,
    alert_body: [240]u8 = undefined,
    alert_body_len: usize = 0,
    icon_cache: std.AutoHashMapUnmanaged(u32, gfx.Image) = .empty,

    // Find bar.
    find_open: bool = false,
    find_replace: bool = false,
    find_field: TextState = .{},
    replace_field: TextState = .{},
    finder: find_mod.Find = .{},

    needs_redraw: bool = true,
    last_mx: i32 = -1,
    last_my: i32 = -1,
    last_focused: bool = true,
    last_dark: bool = false,
    last_accent: u32 = 0,
    last_w: i32 = 0,
    last_h: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        var self = App{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .editor = Editor.init(allocator),
            .documents = "",
            .sheet_names = std.heap.ArenaAllocator.init(allocator),
        };
        const a = self.arena.allocator();
        const po = preview_options;
        if (po != null and po.?.documents != null) {
            self.documents = try a.dupe(u8, po.?.documents.?);
        } else if (std.posix.getenv("ZEN_USER_HOME") orelse std.posix.getenv("HOME")) |h| {
            self.documents = try std.fmt.allocPrint(a, "{s}/Documents", .{std.mem.trimRight(u8, h, "/")});
        } else {
            self.documents = "/Documents";
        }

        if (po) |p| {
            try self.editor.setText(p.text);
            self.editor.style = .{ .mono = p.mono, .size = p.size, .wrap = p.wrap };
            if (p.path) |pp| self.setPath(pp);
            self.editor.cursor = @min(p.cursor, p.text.len);
            self.editor.anchor = @min(p.anchor, p.text.len);
            self.editor.scroll_y = p.scroll_y;
            if (p.dirty) {
                // Make the document dirty with an undoable no-op edit.
                self.editor.saved_id = std.math.maxInt(u64);
            }
            switch (p.sheet) {
                .none => {},
                .save => {
                    self.openFileSheet(u, .save);
                    self.field.set(allocator, p.sheet_text);
                },
                .open => self.openFileSheet(u, .open),
                .confirm => {
                    self.sheet = .confirm;
                    self.pending = .close;
                },
            }
            if (p.find) |q| {
                self.find_field.set(allocator, q);
                self.openFind(u, p.replace != null);
                if (p.replace) |r| self.replace_field.set(allocator, r);
                self.finder.refresh(allocator, &self.editor, q);
                _ = self.finder.step(&self.editor, true);
            }
        } else {
            var args = std.process.args();
            _ = args.next();
            if (args.next()) |arg| self.openPathArg(arg);
        }
        self.syncWindow(u);
        return self;
    }

    pub fn deinit(self: *App) void {
        self.editor.deinit();
        self.field.deinit(self.allocator);
        self.find_field.deinit(self.allocator);
        self.replace_field.deinit(self.allocator);
        self.finder.deinit(self.allocator);
        self.sheet_entries.deinit(self.allocator);
        self.sheet_names.deinit();
        var it = self.icon_cache.valueIterator();
        while (it.next()) |img| img.deinit(self.allocator);
        self.icon_cache.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Documents opened with TextEdit while it runs (Finder, `open`): the
    /// first one replaces the current document, after asking to save.
    pub fn openDocuments(self: *App, u: *Ui, paths: []const []const u8) void {
        const p = paths[0];
        self.pending_path_len = @min(p.len, self.pending_path.len);
        @memcpy(self.pending_path[0..self.pending_path_len], p[0..self.pending_path_len]);
        self.request(u, .open_path);
    }

    /// Open a document named by a path or a `file:` URL (argv[1]).
    pub fn openPathArg(self: *App, arg: []const u8) void {
        var pb: [max_path]u8 = undefined;
        const p = argToPath(arg, &pb);
        var copy: [max_path]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        self.openPath(copy[0..p.len]);
    }

    /// argv[1] → path: plain paths as-is, `file:` URLs percent-decoded.
    fn argToPath(arg: []const u8, out: []u8) []const u8 {
        var s = arg;
        if (std.mem.startsWith(u8, s, "file://")) {
            s = s[7..];
        } else if (std.mem.startsWith(u8, s, "file:")) {
            s = s[5..];
        } else return arg;
        return zen.url.decode(s, out);
    }

    fn docPath(self: *const App) ?[]const u8 {
        return if (self.path_len > 0) self.path_buf[0..self.path_len] else null;
    }

    fn setPath(self: *App, p: []const u8) void {
        self.path_len = @min(p.len, self.path_buf.len);
        std.mem.copyForwards(u8, self.path_buf[0..self.path_len], p[0..self.path_len]);
    }

    fn defaultSaveName(self: *const App) []const u8 {
        if (self.docPath()) |p| return std.fs.path.basename(p);
        return "Untitled.txt";
    }

    fn displayName(self: *const App) []const u8 {
        if (self.docPath()) |p| return std.fs.path.basename(p);
        return "Untitled";
    }

    // ------------------------------------------------------------------
    // Files
    // ------------------------------------------------------------------

    fn openPath(self: *App, p: []const u8) void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, p, max_file) catch |err| {
            if (err == error.FileNotFound) {
                // A new document at this path (like `open -a TextEdit new.txt`).
                self.editor.setText("") catch {};
                self.setPath(p);
                return;
            }
            self.showAlert("The document \u{201C}{s}\u{201D} could not be opened.", .{std.fs.path.basename(p)}, "{s}", .{errorText(err)});
            return;
        };
        defer self.allocator.free(data);
        self.editor.setText(data) catch {
            self.showAlert("The document \u{201C}{s}\u{201D} could not be opened.", .{std.fs.path.basename(p)}, "It is too large.", .{});
            return;
        };
        self.setPath(p);
        self.needs_redraw = true;
    }

    /// Write the document; returns false (with an alert) on failure.
    fn saveTo(self: *App, p: []const u8) bool {
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = self.editor.bytes() }) catch |err| {
            const why = switch (err) {
                error.AccessDenied, error.PermissionDenied => "TextEdit can only save in your Documents folder or its own container.",
                else => errorText(err),
            };
            self.showAlert("The document \u{201C}{s}\u{201D} could not be saved.", .{std.fs.path.basename(p)}, "{s}", .{why});
            return false;
        };
        self.setPath(p);
        self.editor.markSaved();
        self.needs_redraw = true;
        return true;
    }

    fn errorText(err: anyerror) []const u8 {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => "You don\u{2019}t have permission to access it.",
            error.FileNotFound => "The file doesn\u{2019}t exist.",
            error.IsDir => "It is a folder.",
            error.FileTooBig => "It is too large.",
            error.NoSpaceLeft => "The disk is full.",
            else => @errorName(err),
        };
    }

    fn showAlert(self: *App, comptime tf: []const u8, targs: anytype, comptime bf: []const u8, bargs: anytype) void {
        self.alert_title_len = (std.fmt.bufPrint(&self.alert_title, tf, targs) catch self.alert_title[0..0]).len;
        self.alert_body_len = (std.fmt.bufPrint(&self.alert_body, bf, bargs) catch self.alert_body[0..0]).len;
        self.sheet = .alert;
        self.needs_redraw = true;
    }

    /// Run `action`, first asking to save unsaved changes.
    fn request(self: *App, u: *Ui, action: Pending) void {
        if (self.editor.isDirty() and (action == .close or action == .quit or action == .new or action == .open or action == .open_path)) {
            self.pending = action;
            self.sheet = .confirm;
            self.needs_redraw = true;
            return;
        }
        self.perform(u, action);
    }

    fn perform(self: *App, u: *Ui, action: Pending) void {
        self.pending = .none;
        switch (action) {
            .none => {},
            .close, .quit => u.quit = true,
            .new => {
                self.editor.setText("") catch {};
                self.path_len = 0;
            },
            .open => self.openFileSheet(u, .open),
            .open_path => {
                var copy: [max_path]u8 = undefined;
                const n = self.pending_path_len;
                @memcpy(copy[0..n], self.pending_path[0..n]);
                self.openPathArg(copy[0..n]);
            },
        }
        self.needs_redraw = true;
    }

    fn save(self: *App, u: *Ui) void {
        if (self.docPath()) |p| {
            var pb: [max_path]u8 = undefined;
            @memcpy(pb[0..p.len], p);
            _ = self.saveTo(pb[0..p.len]);
        } else self.openFileSheet(u, .save);
    }

    // ------------------------------------------------------------------
    // Open / Save sheet
    // ------------------------------------------------------------------

    fn sheetDir(self: *const App) []const u8 {
        return self.sheet_dir_buf[0..self.sheet_dir_len];
    }

    fn setSheetDir(self: *App, d: []const u8) void {
        self.sheet_dir_len = @min(d.len, self.sheet_dir_buf.len);
        std.mem.copyForwards(u8, self.sheet_dir_buf[0..self.sheet_dir_len], d[0..self.sheet_dir_len]);
        self.loadSheetDir();
    }

    fn loadSheetDir(self: *App) void {
        self.sheet_entries.clearRetainingCapacity();
        _ = self.sheet_names.reset(.retain_capacity);
        self.sheet_sel = null;
        self.sheet_scroll = .{};
        const a = self.sheet_names.allocator();
        var dir = std.fs.cwd().openDir(self.sheetDir(), .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue;
            const name = a.dupe(u8, e.name) catch break;
            self.sheet_entries.append(self.allocator, .{ .name = name, .is_dir = e.kind == .directory }) catch break;
        }
        std.mem.sort(DirEntry, self.sheet_entries.items, {}, struct {
            fn less(_: void, x: DirEntry, y: DirEntry) bool {
                if (x.is_dir != y.is_dir) return x.is_dir;
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.less);
    }

    fn openFileSheet(self: *App, u: *Ui, kind: Sheet) void {
        self.sheet = kind;
        self.sheet_error_len = 0;
        const dir = if (self.docPath()) |p| (std.fs.path.dirname(p) orelse self.documents) else self.documents;
        var db: [max_path]u8 = undefined;
        @memcpy(db[0..dir.len], dir);
        self.setSheetDir(db[0..dir.len]);
        if (kind == .save) {
            const name = self.defaultSaveName();
            self.field.set(self.allocator, name);
            // Select the name without the extension.
            self.field.anchor = 0;
            self.field.cursor = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| (if (d > 0) d else name.len) else name.len;
        } else {
            self.field.set(self.allocator, "");
        }
        u.focus = hashId("sheet-field");
        self.needs_redraw = true;
    }

    fn sheetTarget(self: *App, out: []u8) ?[]const u8 {
        const raw = std.mem.trim(u8, self.field.text(), " \t");
        if (raw.len == 0) return null;
        var db: [max_path]u8 = undefined;
        const decoded = argToPath(raw, &db);
        if (decoded[0] == '/') return std.fmt.bufPrint(out, "{s}", .{decoded}) catch null;
        if (std.mem.startsWith(u8, decoded, "~/")) {
            const home = std.fs.path.dirname(self.documents) orelse "/";
            return std.fmt.bufPrint(out, "{s}/{s}", .{ home, decoded[2..] }) catch null;
        }
        return std.fmt.bufPrint(out, "{s}/{s}", .{ std.mem.trimRight(u8, self.sheetDir(), "/"), decoded }) catch null;
    }

    fn submitSheet(self: *App, u: *Ui) void {
        var tb: [max_path]u8 = undefined;
        const target = self.sheetTarget(&tb) orelse return;
        // A folder: browse into it.
        if (std.fs.cwd().openDir(target, .{ .iterate = true })) |d| {
            var dd = d;
            dd.close();
            self.setSheetDir(target);
            self.field.set(self.allocator, if (self.sheet == .save) self.defaultSaveName() else "");
            return;
        } else |_| {}
        if (self.sheet == .open) {
            const data_ok = std.fs.cwd().access(target, .{});
            if (data_ok) |_| {
                self.sheet = .none;
                u.focus = 0;
                self.openPath(target);
            } else |err| {
                self.sheet_error_len = (std.fmt.bufPrint(&self.sheet_error, "\u{201C}{s}\u{201D} can\u{2019}t be opened: {s}", .{ std.fs.path.basename(target), errorText(err) }) catch "").len;
            }
            return;
        }
        // Save.
        self.sheet = .none;
        u.focus = 0;
        if (self.saveTo(target)) {
            if (self.pending != .none) self.perform(u, self.pending);
        } else {
            self.pending = .none;
        }
    }

    // ------------------------------------------------------------------
    // Menus
    // ------------------------------------------------------------------

    fn menuState(self: *const App) u32 {
        var f: u32 = 0;
        if (self.editor.canUndo()) f |= 1;
        if (self.editor.canRedo()) f |= 2;
        if (self.editor.style.wrap) f |= 4;
        if (self.editor.style.mono) f |= 8;
        if (self.editor.isDirty() and self.docPath() != null) f |= 16;
        if (self.editor.hasSelection()) f |= 32;
        if (self.find_field.text().len > 0) f |= 64;
        return f;
    }

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        const chk = abi.window.MenuItemFlags.checked;
        const dis = abi.window.MenuItemFlags.disabled;
        const st = self.menuState();
        self.menu_flags = st;
        mw.beginMenu("TextEdit");
        mw.item(M.about, "About TextEdit", 0, 0, 0);
        mw.separator();
        mw.item(M.quit, "Quit TextEdit", 'q', 0, 0);
        mw.endMenu();

        mw.beginMenu("File");
        mw.item(M.new, "New", 'n', 0, 0);
        mw.item(M.open, "Open\u{2026}", 'o', 0, 0);
        mw.separator();
        mw.item(M.close, "Close", 'w', 0, 0);
        mw.item(M.save, "Save", 's', 0, 0);
        mw.item(M.save_as, "Save As\u{2026}", 'S', 0, 0);
        mw.item(M.revert, "Revert to Saved", 0, 0, if (st & 16 == 0) dis else 0);
        mw.endMenu();

        mw.beginMenu("Edit");
        mw.item(M.undo, "Undo", 'z', 0, if (st & 1 == 0) dis else 0);
        mw.item(M.redo, "Redo", 'Z', 0, if (st & 2 == 0) dis else 0);
        mw.separator();
        mw.item(M.cut, "Cut", 'x', 0, if (st & 32 == 0) dis else 0);
        mw.item(M.copy, "Copy", 'c', 0, if (st & 32 == 0) dis else 0);
        mw.item(M.paste, "Paste", 'v', 0, 0);
        mw.item(M.delete, "Delete", 0, 0, if (st & 32 == 0) dis else 0);
        mw.item(M.select_all, "Select All", 'a', 0, 0);
        mw.separator();
        mw.item(M.find, "Find\u{2026}", 'f', 0, 0);
        mw.item(M.find_replace, "Find and Replace\u{2026}", 'f', @intCast(Mods.cmd | Mods.alt), 0);
        mw.item(M.find_next, "Find Next", 'g', 0, if (st & 64 == 0) dis else 0);
        mw.item(M.find_previous, "Find Previous", 'G', 0, if (st & 64 == 0) dis else 0);
        mw.item(M.find_selection, "Use Selection for Find", 'e', 0, if (st & 32 == 0) dis else 0);
        mw.endMenu();

        mw.beginMenu("View");
        mw.item(M.bigger, "Bigger", '=', 0, 0);
        mw.item(M.smaller, "Smaller", '-', 0, 0);
        mw.item(M.actual, "Actual Size", '0', 0, 0);
        mw.separator();
        mw.item(M.wrap, "Wrap to Window", 0, 0, if (st & 4 != 0) chk else 0);
        mw.item(M.mono, "Plain Text Mono", 'm', @intCast(Mods.cmd | Mods.alt), if (st & 8 != 0) chk else 0);
        mw.endMenu();
    }

    fn refreshMenu(self: *App, u: *Ui) void {
        if (self.menuState() == self.menu_flags) return;
        var buf: [4096]u8 = undefined;
        var mw = abi.window.MenuWriter{ .buf = &buf };
        self.menu(&mw);
        u.win.setMenu(mw.bytes());
    }

    /// The find or replace field has the keyboard.
    fn findFocused(self: *const App, u: *Ui) bool {
        return self.find_open and (u.focus == hashId("find-field") or u.focus == hashId("replace-field"));
    }

    fn injectKey(u: *Ui, code: u16, mods: u32) void {
        if (u.key_count >= u.keys.len) return;
        u.keys[u.key_count] = .{ .code = code, .mods = mods, .repeat = false };
        u.key_count += 1;
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        self.needs_redraw = true;
        // With a sheet up, only editing commands for its text field apply.
        if (self.sheet != .none) {
            switch (id) {
                M.cut => injectKey(u, Key.x, Mods.cmd),
                M.copy => injectKey(u, Key.c, Mods.cmd),
                M.paste => injectKey(u, Key.v, Mods.cmd),
                M.select_all => injectKey(u, Key.a, Mods.cmd),
                else => {},
            }
            return;
        }
        // Clipboard commands go to the find bar's field when it has focus.
        if (self.findFocused(u)) {
            switch (id) {
                M.cut => return injectKey(u, Key.x, Mods.cmd),
                M.copy => return injectKey(u, Key.c, Mods.cmd),
                M.paste => return injectKey(u, Key.v, Mods.cmd),
                M.select_all => return injectKey(u, Key.a, Mods.cmd),
                else => {},
            }
        }
        const e = &self.editor;
        switch (id) {
            M.find => self.openFind(u, false),
            M.find_replace => self.openFind(u, true),
            M.find_next => self.findStep(true),
            M.find_previous => self.findStep(false),
            M.find_selection => if (e.hasSelection()) {
                const sel = e.selectedText();
                const line = sel[0 .. std.mem.indexOfScalar(u8, sel, '\n') orelse sel.len];
                self.find_field.set(self.allocator, line[0..@min(line.len, 256)]);
            },
            M.about => self.showAlert("TextEdit 1.0", .{}, "A plain-text editor for Zen OS.", .{}),
            M.quit => self.request(u, .quit),
            M.close => self.request(u, .close),
            M.new => self.request(u, .new),
            M.open => self.request(u, .open),
            M.save => self.save(u),
            M.save_as => self.openFileSheet(u, .save),
            M.revert => if (self.docPath()) |p| {
                var pb: [max_path]u8 = undefined;
                @memcpy(pb[0..p.len], p);
                self.openPath(pb[0..p.len]);
            },
            M.undo => e.undo(),
            M.redo => e.redo(),
            M.cut => e.cut(),
            M.copy => e.copy(),
            M.paste => e.paste(),
            M.delete => e.deleteBackward(.char),
            M.select_all => e.selectAll(),
            M.bigger => self.stepSize(1),
            M.smaller => self.stepSize(-1),
            M.actual => e.style.size = 15,
            M.wrap => e.style.wrap = !e.style.wrap,
            M.mono => e.style.mono = !e.style.mono,
            else => {},
        }
    }

    pub fn shouldClose(self: *App, u: *Ui) bool {
        if (self.editor.isDirty()) {
            self.request(u, .close);
            return false;
        }
        return true;
    }

    /// Logout/shutdown: ask to save unsaved changes first.
    pub fn shouldQuit(self: *App, u: *Ui) bool {
        if (self.editor.isDirty()) {
            self.request(u, .quit);
            return false;
        }
        return true;
    }

    pub fn timeoutMs(self: *App) i32 {
        return if (self.needs_redraw) 0 else -1;
    }

    fn stepSize(self: *App, dir: i32) void {
        const cur = self.editor.style.size;
        var idx: usize = 0;
        for (font_sizes, 0..) |s, i| {
            if (s <= cur + 0.01) idx = i;
        }
        if (dir > 0 and idx + 1 < font_sizes.len) idx += 1;
        if (dir < 0 and idx > 0 and font_sizes[idx] >= cur - 0.01) idx -= 1;
        self.editor.style.size = font_sizes[idx];
        self.editor.reveal = true;
        self.needs_redraw = true;
    }

    // ------------------------------------------------------------------
    // Frame
    // ------------------------------------------------------------------

    fn findBarHeight(self: *const App) i32 {
        if (!self.find_open) return 0;
        return if (self.find_replace) 2 * FIND_ROW_H else FIND_ROW_H;
    }

    fn editorArea(self: *const App, u: *Ui) Rect {
        const top = TOOLBAR_H + self.findBarHeight();
        return Rect.init(0, top, u.width(), u.height() - top);
    }

    /// Frames caused only by the pointer moving over the text need no redraw.
    fn isIdle(self: *App, u: *Ui) bool {
        if (self.needs_redraw) return false;
        if (u.key_count > 0 or u.text_len > 0 or u.mouse_pressed or u.mouse_released or u.right_pressed or u.mouse_down) return false;
        if (u.scroll_dx != 0 or u.scroll_dy != 0 or u.menu_id != null or u.resized or u.close_requested) return false;
        if (u.focused != self.last_focused or u.theme.dark != self.last_dark or u.theme.accent != self.last_accent) return false;
        if (u.width() != self.last_w or u.height() != self.last_h) return false;
        if (u.mouse_x == self.last_mx and u.mouse_y == self.last_my) return true;
        if (self.sheet != .none) return false;
        const area = self.editorArea(u);
        return area.contains(u.mouse_x, u.mouse_y) and area.contains(self.last_mx, self.last_my);
    }

    pub fn frame(self: *App, u: *Ui) void {
        if (self.isIdle(u)) {
            self.last_mx = u.mouse_x;
            self.last_my = u.mouse_y;
            u.cursor = if (self.editorArea(u).contains(u.mouse_x, u.mouse_y) and self.sheet == .none) .ibeam else u.last_cursor;
            return;
        }
        self.needs_redraw = false;
        self.last_mx = u.mouse_x;
        self.last_my = u.mouse_y;
        self.last_focused = u.focused;
        self.last_dark = u.theme.dark;
        self.last_accent = u.theme.accent;
        self.last_w = u.width();
        self.last_h = u.height();

        const t = u.theme;
        const area = self.editorArea(u);
        const e = &self.editor;
        e.ensureLayout(u, @as(f32, @floatFromInt(area.w)) - 2 * editor_mod.pad_x);

        // Input goes to the editor unless a sheet is up or the find bar
        // has the keyboard.
        const modal = self.sheet != .none;
        if (!modal) {
            if (u.mouse_pressed and area.contains(u.mouse_x, u.mouse_y)) u.focus = 0;
            const lh = e.lineHeight(u);
            const page: usize = @intFromFloat(@max(1, @floor(@as(f32, @floatFromInt(area.h)) / lh)));
            if (!self.findFocused(u) and (u.key_count > 0 or u.text_len > 0)) _ = e.handleKeys(u, page);
            e.handleMouse(u, area);
        } else {
            for (u.keys[0..u.key_count]) |k| {
                if (k.code == Key.esc) self.cancelSheet(u);
                if ((k.code == Key.enter or k.code == Key.kpenter) and (self.sheet == .confirm or self.sheet == .alert)) {
                    if (self.sheet == .alert) self.sheet = .none else self.confirmSave(u);
                }
            }
        }
        // Style may have changed via keys/menus: relayout before drawing.
        e.ensureLayout(u, @as(f32, @floatFromInt(area.w)) - 2 * editor_mod.pad_x);

        const saved = maskInput(u, modal);
        self.drawToolbar(u);
        if (self.find_open) self.drawFindBar(u, modal);
        e.ensureLayout(u, @as(f32, @floatFromInt(area.w)) - 2 * editor_mod.pad_x);
        if (self.find_open) {
            self.finder.refresh(self.allocator, e, self.find_field.text());
            e.highlights = self.finder.matches.items;
            e.highlight_current = if (self.finder.selectionIsMatch(e)) self.finder.current else null;
        } else {
            e.highlights = &.{};
            e.highlight_current = null;
        }
        const editor_focus = u.focused and !modal and !self.findFocused(u);
        const paper: u32 = if (t.dark) 0xFF1E1E20 else 0xFFFFFFFF;
        e.draw(u, area, .{
            .bg = paper,
            .text = if (t.dark) 0xFFE8E8EA else 0xFF1D1D1F,
            .selection = if (editor_focus) ui.ui.withAlpha(t.accent, if (t.dark) 0x80 else 0x4D) else (if (t.dark) @as(u32, 0xFF46464A) else 0xFFDCDCE0),
            .caret = t.accent,
            .scrollbar = if (t.dark) 0x66FFFFFF else 0x50000000,
            .find = if (t.dark) 0x66A07800 else 0x66FFE14D,
            .find_current = if (t.dark) 0xFFA07800 else 0xFFFFD60A,
        }, editor_focus);
        restoreInput(u, saved);

        switch (self.sheet) {
            .none => {},
            .open, .save => {
                u.focus = hashId("sheet-field");
                self.drawFileSheet(u);
            },
            .confirm => self.drawConfirm(u),
            .alert => self.drawAlert(u),
        }
        self.syncWindow(u);
        self.refreshMenu(u);
    }

    fn cancelSheet(self: *App, u: *Ui) void {
        self.sheet = .none;
        self.pending = .none;
        u.focus = 0;
        self.needs_redraw = true;
    }

    fn confirmSave(self: *App, u: *Ui) void {
        self.sheet = .none;
        if (self.docPath()) |p| {
            var pb: [max_path]u8 = undefined;
            @memcpy(pb[0..p.len], p);
            if (self.saveTo(pb[0..p.len])) self.perform(u, self.pending) else self.pending = .none;
        } else {
            // Untitled: choose a name first; the pending action runs after saving.
            const keep = self.pending;
            self.openFileSheet(u, .save);
            self.pending = keep;
        }
        self.needs_redraw = true;
    }

    /// Title and edited dot.
    fn syncWindow(self: *App, u: *Ui) void {
        const name = self.displayName();
        if (!std.mem.eql(u8, name, self.shown_title[0..self.shown_title_len])) {
            u.win.setTitle(name);
            self.shown_title_len = @min(name.len, self.shown_title.len);
            @memcpy(self.shown_title[0..self.shown_title_len], name[0..self.shown_title_len]);
        }
        const dirty = self.editor.isDirty();
        if (dirty != self.shown_dirty) {
            u.win.setEdited(dirty);
            self.shown_dirty = dirty;
        }
    }

    const SavedInput = struct { active: bool, mx: i32, my: i32, pressed: bool, released: bool, down: bool };

    fn maskInput(u: *Ui, on: bool) SavedInput {
        const s = SavedInput{ .active = on, .mx = u.mouse_x, .my = u.mouse_y, .pressed = u.mouse_pressed, .released = u.mouse_released, .down = u.mouse_down };
        if (on) {
            u.mouse_x = -10000;
            u.mouse_y = -10000;
            u.mouse_pressed = false;
            u.mouse_released = false;
            u.mouse_down = false;
        }
        return s;
    }

    fn restoreInput(u: *Ui, s: SavedInput) void {
        if (!s.active) return;
        u.mouse_x = s.mx;
        u.mouse_y = s.my;
        u.mouse_pressed = s.pressed;
        u.mouse_released = s.released;
        u.mouse_down = s.down;
    }

    // ------------------------------------------------------------------
    // Find bar
    // ------------------------------------------------------------------

    fn openFind(self: *App, u: *Ui, replace: bool) void {
        self.find_open = true;
        if (replace) self.find_replace = true;
        // Start from the selection, like macOS.
        const e = &self.editor;
        if (self.find_field.text().len == 0 and e.hasSelection()) {
            const sel = e.selectedText();
            if (std.mem.indexOfScalar(u8, sel, '\n') == null) self.find_field.set(self.allocator, sel[0..@min(sel.len, 256)]);
        }
        self.find_field.anchor = 0;
        self.find_field.cursor = self.find_field.text().len;
        u.focus = hashId("find-field");
        self.needs_redraw = true;
    }

    fn closeFind(self: *App, u: *Ui) void {
        self.find_open = false;
        self.find_replace = false;
        u.focus = 0;
        self.needs_redraw = true;
    }

    fn findStep(self: *App, forward: bool) void {
        const q = self.find_field.text();
        if (q.len == 0) return;
        self.finder.refresh(self.allocator, &self.editor, q);
        _ = self.finder.step(&self.editor, forward);
        self.needs_redraw = true;
    }

    fn findStatus(self: *const App, buf: []u8) []const u8 {
        if (self.find_field.text().len == 0) return "";
        const n = self.finder.matches.items.len;
        if (n == 0) return "Not found";
        if (self.finder.truncated) return std.fmt.bufPrint(buf, "{d}+ matches", .{n}) catch "";
        if (self.finder.selectionIsMatch(&self.editor)) return std.fmt.bufPrint(buf, "{d} of {d}", .{ self.finder.current.? + 1, n }) catch "";
        return std.fmt.bufPrint(buf, "{d} match{s}", .{ n, if (n == 1) "" else "es" }) catch "";
    }

    fn drawFindBar(self: *App, u: *Ui, modal: bool) void {
        const t = u.theme;
        const w = u.width();
        const y0 = TOOLBAR_H;
        const bh = self.findBarHeight();
        u.fillRect(Rect.init(0, y0, w, bh), if (t.dark) 0xFF262629 else 0xFFF7F7F9);
        u.hline(0, w, y0 + bh - 1, if (t.dark) 0xFF151517 else 0xFFDCDCE0);

        // Keys for the fields: Esc closes, Tab switches, Enter searches.
        var enter = false;
        var shift_enter = false;
        if (!modal and self.findFocused(u)) {
            for (u.keys[0..u.key_count]) |k| {
                switch (k.code) {
                    Key.esc => {
                        self.closeFind(u);
                        u.keys_consumed = true;
                        return;
                    },
                    Key.tab => if (self.find_replace) {
                        u.focus = if (u.focus == hashId("find-field")) hashId("replace-field") else hashId("find-field");
                    },
                    Key.enter, Key.kpenter => if (u.focus == hashId("find-field")) {
                        if (k.mods & Mods.shift != 0) shift_enter = true else enter = true;
                    },
                    else => {},
                }
            }
        }

        const e = &self.editor;
        const ch: i32 = 26;
        const right_w: i32 = 272;
        const fw = @max(140, w - 24 - right_w);
        // Find row: [ field ][Aa] status  ‹ ›  Done
        const fy = y0 + @divTrunc(FIND_ROW_H - ch, 2);
        const fr = Rect.init(12, fy, fw, ch);
        const res = u.textField("find-field", fr, &self.find_field, .{ .placeholder = "Find", .capsule = true });
        if (res.changed) {
            // Incremental search from the selection.
            self.finder.refresh(self.allocator, e, self.find_field.text());
            if (self.finder.current) |i| self.finder.select(e, i);
            self.needs_redraw = true;
        }
        if (enter) self.findStep(true);
        if (shift_enter) self.findStep(false);

        var x = fr.right() + 8;
        const case_r = Rect.init(x, fy, 34, ch);
        glassCapsule(u, case_r);
        if (segButton(u, "find-case", case_r.inset(2, 2), self.finder.case_sensitive)) {
            self.finder.case_sensitive = !self.finder.case_sensitive;
            self.needs_redraw = true;
        }
        u.text(case_r, "Aa", .{ .size = 12, .weight = .semibold, .@"align" = .center, .color = if (self.finder.case_sensitive) t.accent else t.label });
        x = case_r.right() + 8;

        var sb: [48]u8 = undefined;
        self.finder.refresh(self.allocator, e, self.find_field.text());
        const status = self.findStatus(&sb);
        const not_found = self.finder.matches.items.len == 0 and self.find_field.text().len > 0;
        u.text(Rect.init(x, fy, 96, ch), status, .{ .size = 12, .@"align" = .center, .color = if (not_found) @as(u32, 0xFFFF453A) else t.secondary_label });
        x += 100;

        const have = self.finder.matches.items.len > 0;
        const nav = Rect.init(x, fy, 58, ch);
        glassCapsule(u, nav);
        if (segButton(u, "find-prev", Rect.init(nav.x + 2, fy + 2, 26, ch - 4), false) and have) self.findStep(false);
        if (segButton(u, "find-next", Rect.init(nav.x + 30, fy + 2, 26, ch - 4), false) and have) self.findStep(true);
        const col = if (have) t.label else t.tertiary_label;
        const cy: f32 = @floatFromInt(fy + @divTrunc(ch, 2));
        const lx: f32 = @floatFromInt(nav.x + 16);
        u.line(lx + 2, cy - 4.5, lx - 2.5, cy, 1.6, col);
        u.line(lx - 2.5, cy, lx + 2, cy + 4.5, 1.6, col);
        const rx: f32 = @floatFromInt(nav.x + 42);
        u.line(rx - 2, cy - 4.5, rx + 2.5, cy, 1.6, col);
        u.line(rx + 2.5, cy, rx - 2, cy + 4.5, 1.6, col);
        u.fillRect(Rect.init(nav.x + 29, fy + 6, 1, ch - 12), t.separator);
        x = nav.right() + 8;

        if (u.button("find-done", Rect.init(x, fy, 56, ch), "Done", .{ .size = 12 })) {
            self.closeFind(u);
            return;
        }

        if (!self.find_replace) return;
        // Replace row: [ field ]  Replace  All
        const ry = y0 + FIND_ROW_H + @divTrunc(FIND_ROW_H - ch, 2) - 3;
        _ = u.textField("replace-field", Rect.init(12, ry, fw, ch), &self.replace_field, .{ .placeholder = "Replace", .capsule = true });
        const bx = fr.right() + 8;
        if (u.button("replace-one", Rect.init(bx, ry, 82, ch), "Replace", .{ .size = 12, .enabled = have })) {
            self.finder.replaceOne(self.allocator, e, self.find_field.text(), self.replace_field.text());
            self.needs_redraw = true;
        }
        if (u.button("replace-all", Rect.init(bx + 90, ry, 56, ch), "All", .{ .size = 12, .enabled = have })) {
            _ = self.finder.replaceAll(self.allocator, e, self.find_field.text(), self.replace_field.text());
            self.needs_redraw = true;
        }
    }

    // ------------------------------------------------------------------
    // Toolbar
    // ------------------------------------------------------------------

    fn glassCapsule(u: *Ui, r: Rect) void {
        const t = u.theme;
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        u.shadow(r, radius, 5, 1, if (t.dark) 0x55000000 else 0x1A000000);
        u.fillRound(r, radius, if (t.dark) 0xFF3A3A3D else 0xFFFFFFFF);
        u.strokeRound(r, radius, 0.8, if (t.dark) 0x22FFFFFF else 0x14000000);
    }

    fn segButton(u: *Ui, id_str: []const u8, r: Rect, on: bool) bool {
        const t = u.theme;
        const id = hashId(id_str);
        const clicked = u.interact(id, r);
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        if (on) {
            u.fillRound(r, radius, if (t.dark) 0x38FFFFFF else 0x17000000);
        } else if (u.isActive(id)) {
            u.fillRound(r, radius, if (t.dark) 0x29FFFFFF else 0x12000000);
        } else if (u.hot == id) {
            u.fillRound(r, radius, t.hover);
        }
        return clicked;
    }

    fn drawToolbar(self: *App, u: *Ui) void {
        const t = u.theme;
        const w = u.width();
        const e = &self.editor;
        u.fillRect(Rect.init(0, 0, w, TOOLBAR_H), if (t.dark) 0xFF2A2A2D else 0xFFF3F3F5);
        u.hline(0, w, TOOLBAR_H - 1, if (t.dark) 0xFF151517 else 0xFFDCDCE0);
        const y = 9;
        const h = 26;

        // Font size stepper: [ − | 15 pt | + ].
        const st = Rect.init(12, y, 122, h);
        glassCapsule(u, st);
        if (segButton(u, "size-down", Rect.init(st.x + 2, y + 2, 30, h - 4), false)) self.stepSize(-1);
        if (segButton(u, "size-up", Rect.init(st.right() - 32, y + 2, 30, h - 4), false)) self.stepSize(1);
        const cy: f32 = @floatFromInt(y + @divTrunc(h, 2));
        const mx: f32 = @floatFromInt(st.x + 17);
        u.line(mx - 4.5, cy, mx + 4.5, cy, 1.6, t.label);
        const px: f32 = @floatFromInt(st.right() - 17);
        u.line(px - 4.5, cy, px + 4.5, cy, 1.6, t.label);
        u.line(px, cy - 4.5, px, cy + 4.5, 1.6, t.label);
        var sb: [16]u8 = undefined;
        const size_s = std.fmt.bufPrint(&sb, "{d} pt", .{@as(u32, @intFromFloat(e.style.size))}) catch "";
        u.fillRect(Rect.init(st.x + 33, y + 6, 1, h - 12), t.separator);
        u.fillRect(Rect.init(st.right() - 34, y + 6, 1, h - 12), t.separator);
        u.text(Rect.init(st.x + 34, y, st.w - 68, h), size_s, .{ .size = 12, .weight = .medium, .@"align" = .center, .color = t.label });

        // Font: proportional / mono.
        const fr = Rect.init(st.right() + 10, y, 132, h);
        glassCapsule(u, fr);
        if (segButton(u, "font-inter", Rect.init(fr.x + 2, y + 2, 64, h - 4), !e.style.mono)) e.style.mono = false;
        if (segButton(u, "font-mono", Rect.init(fr.x + 66, y + 2, 64, h - 4), e.style.mono)) e.style.mono = true;
        u.text(Rect.init(fr.x + 2, y, 64, h), "Inter", .{ .size = 12, .weight = if (!e.style.mono) .semibold else .regular, .@"align" = .center, .color = t.label });
        const old = u.pushClip(Rect.init(fr.x + 66, y, 64, h));
        const mf = u.face(.mono, 12);
        const mw = mf.measure("Mono");
        _ = u.textAt(@as(f32, @floatFromInt(fr.x + 66)) + (64 - mw) / 2, @round(@as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(h)) + mf.cap_height) / 2), "Mono", .mono, 12, t.label);
        u.popClip(old);

        // Wrap toggle.
        const wr = Rect.init(fr.right() + 10, y, 84, h);
        glassCapsule(u, wr);
        const wrap_r = Rect.init(wr.x + 2, y + 2, wr.w - 4, h - 4);
        if (e.style.wrap) u.fillRound(wrap_r, @as(f32, @floatFromInt(wrap_r.h)) / 2, ui.ui.withAlpha(t.accent, if (t.dark) 0x55 else 0x2A));
        if (segButton(u, "wrap", wrap_r, false)) e.style.wrap = !e.style.wrap;
        const wc = if (e.style.wrap) t.accent else t.label;
        // Glyph: two lines with a return arrow.
        const gx: f32 = @floatFromInt(wr.x + 14);
        const gy: f32 = @floatFromInt(y + 8);
        u.line(gx, gy, gx + 12, gy, 1.5, wc);
        u.line(gx, gy + 5, gx + 12, gy + 5, 1.5, wc);
        u.line(gx + 12, gy + 5, gx + 12, gy + 9.5, 1.5, wc);
        u.line(gx + 12, gy + 9.5, gx + 5, gy + 9.5, 1.5, wc);
        u.line(gx + 5, gy + 9.5, gx + 7.5, gy + 7, 1.5, wc);
        u.line(gx + 5, gy + 9.5, gx + 7.5, gy + 12, 1.5, wc);
        u.text(Rect.init(wr.x + 32, y, wr.w - 38, h), "Wrap", .{ .size = 12, .weight = .medium, .color = wc });

        // Statistics.
        if (self.stats_version != e.version) {
            const c = e.counts();
            self.words = c.words;
            self.chars = c.chars;
            self.stats_version = e.version;
        }
        var cb: [96]u8 = undefined;
        const stats = std.fmt.bufPrint(&cb, "Words: {d}   Characters: {d}", .{ self.words, self.chars }) catch "";
        const sx = wr.right() + 12;
        if (w - 14 - sx > 60) u.text(Rect.init(sx, y, w - 14 - sx, h), stats, .{ .size = 12, .color = t.secondary_label, .@"align" = .right });
    }

    // ------------------------------------------------------------------
    // Sheets
    // ------------------------------------------------------------------

    fn sheetPanel(u: *Ui, r: Rect) void {
        const t = u.theme;
        u.fillRect(Rect.init(0, 0, u.width(), u.height()), if (t.dark) 0x38000000 else 0x1A000000);
        u.shadow(r, 16, 22, 10, if (t.dark) 0x99000000 else 0x45000000);
        u.fillRound(r, 16, if (t.dark) 0xFF2C2C2F else 0xFFFBFBFD);
        u.strokeRound(r, 16, 0.8, if (t.dark) 0x30FFFFFF else 0x1A000000);
    }

    fn cachedIcon(self: *App, kind: u8, size: u32) ?gfx.Canvas {
        const key = (@as(u32, kind) << 16) | size;
        if (self.icon_cache.get(key)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, size, size) catch return null;
        const r = gfx.RectF.init(0, 0, @floatFromInt(size), @floatFromInt(size));
        switch (kind) {
            0 => icons.drawFolder(img.canvas(), r, 0xFF55B0F4),
            1 => icons.drawDocument(img.canvas(), self.allocator, r, 0xFF6E6E78),
            else => icons.drawApp(img.canvas(), self.allocator, .textedit, r),
        }
        self.icon_cache.put(self.allocator, key, img) catch {
            img.deinit(self.allocator);
            return null;
        };
        return img.canvas();
    }

    fn drawFileSheet(self: *App, u: *Ui) void {
        const t = u.theme;
        const saving = self.sheet == .save;
        const w: i32 = @min(480, u.width() - 32);
        const h: i32 = @min(380, u.height() - 24);
        const r = Rect.init(@divTrunc(u.width() - w, 2), 10, w, h);
        sheetPanel(u, r);
        const x0 = r.x + 20;
        const iw = r.w - 40;
        u.text(Rect.init(x0, r.y + 14, iw, 22), if (saving) "Save As" else "Open", .{ .size = 13, .weight = .bold, .color = t.label });

        const res = u.textField("sheet-field", Rect.init(x0 + 64, r.y + 44, iw - 64, 28), &self.field, .{ .placeholder = if (saving) "Name" else "Name or path" });
        u.text(Rect.init(x0, r.y + 44, 58, 28), if (saving) "Name:" else "File:", .{ .size = 12, .weight = .medium, .color = t.secondary_label, .@"align" = .right });
        if (res.changed) self.sheet_error_len = 0;

        // Location crumb with an "up" button.
        const ly = r.y + 82;
        const up_r = Rect.init(x0, ly, 28, 24);
        const at_root = std.mem.eql(u8, self.sheetDir(), "/");
        if (u.button("sheet-up", up_r, "\u{2039}", .{ .style = .toolbar, .enabled = !at_root, .size = 18 })) {
            const parent = std.fs.path.dirname(self.sheetDir()) orelse "/";
            var pb: [max_path]u8 = undefined;
            @memcpy(pb[0..parent.len], parent);
            self.setSheetDir(pb[0..parent.len]);
        }
        var crumb_buf: [max_path + 16]u8 = undefined;
        const dir = self.sheetDir();
        const home = std.fs.path.dirname(self.documents) orelse "";
        const crumb = if (home.len > 1 and std.mem.startsWith(u8, dir, home))
            std.fmt.bufPrint(&crumb_buf, "~{s}", .{dir[home.len..]}) catch dir
        else
            dir;
        u.text(Rect.init(x0 + 34, ly, iw - 34, 24), crumb, .{ .size = 12, .weight = .medium, .color = t.secondary_label });

        // File list.
        const list = Rect.init(x0, ly + 30, iw, r.bottom() - 64 - (ly + 30));
        u.fillRound(list, 10, if (t.dark) 0xFF232326 else 0xFFFFFFFF);
        u.strokeRound(list, 10, 0.8, t.separator);
        const row_h: i32 = 26;
        const inner = list.inset(4, 4);
        self.sheet_scroll.content = @floatFromInt(@as(i32, @intCast(self.sheet_entries.items.len)) * row_h);
        const oldc = u.beginScroll(inner, &self.sheet_scroll);
        var open_idx: ?usize = null;
        for (self.sheet_entries.items, 0..) |de, i| {
            const ry = inner.y + @as(i32, @intCast(i)) * row_h - @as(i32, @intFromFloat(self.sheet_scroll.offset));
            if (ry + row_h < inner.y or ry > inner.bottom()) continue;
            const rr = Rect.init(inner.x, ry, inner.w, row_h);
            const is_sel = self.sheet_sel == i;
            if (u.listRow(ui.ui.hashIdx("sheet-row", i), rr, is_sel, i % 2 == 1)) {
                self.sheet_sel = i;
                if (!de.is_dir) self.field.set(self.allocator, de.name);
                if (u.click_count >= 2) open_idx = i;
            }
            if (self.cachedIcon(if (de.is_dir) 0 else 1, 18)) |img| u.canvas.drawImage(img, rr.x + 8, ry + 4, 255);
            u.text(Rect.init(rr.x + 32, ry, rr.w - 40, row_h), de.name, .{ .size = 13, .color = if (is_sel) @as(u32, 0xFFFFFFFF) else (if (de.is_dir or !saving) t.label else t.secondary_label) });
        }
        if (self.sheet_entries.items.len == 0) {
            u.text(inner, "No documents", .{ .size = 12, .color = t.tertiary_label, .@"align" = .center });
        }
        u.endScroll(inner, &self.sheet_scroll, oldc);

        if (self.sheet_error_len > 0) {
            u.text(Rect.init(x0, r.bottom() - 50, iw - 200, 28), self.sheet_error[0..self.sheet_error_len], .{ .size = 11, .color = 0xFFFF453A });
        }
        const by = r.bottom() - 46;
        const ok = u.button("sheet-ok", Rect.init(r.right() - 20 - 90, by, 90, 28), if (saving) "Save" else "Open", .{ .style = .primary, .enabled = self.field.buf.items.len > 0 });
        const cancel = u.button("sheet-cancel", Rect.init(r.right() - 20 - 190, by, 90, 28), "Cancel", .{});
        if (open_idx) |i| {
            const de = self.sheet_entries.items[i];
            if (de.is_dir) {
                var pb: [max_path]u8 = undefined;
                const sub = std.fmt.bufPrint(&pb, "{s}/{s}", .{ std.mem.trimRight(u8, self.sheetDir(), "/"), de.name }) catch return;
                self.setSheetDir(sub);
                return;
            }
            self.submitSheet(u);
            return;
        }
        if (cancel) {
            self.cancelSheet(u);
        } else if (ok or res.submitted) {
            self.submitSheet(u);
            self.needs_redraw = true;
        }
    }

    fn drawConfirm(self: *App, u: *Ui) void {
        const t = u.theme;
        const w: i32 = 400;
        const h: i32 = 178;
        const r = Rect.init(@divTrunc(u.width() - w, 2), 10, w, h);
        sheetPanel(u, r);
        if (self.cachedIcon(2, 56)) |img| u.canvas.drawImage(img, r.x + 20, r.y + 20, 255);
        var tb: [300]u8 = undefined;
        const title = std.fmt.bufPrint(&tb, "Do you want to save the changes you made to \u{201C}{s}\u{201D}?", .{self.displayName()}) catch "Save changes?";
        _ = u.paragraph(Rect.init(r.x + 92, r.y + 22, r.w - 112, 40), title, .{ .size = 13, .weight = .bold, .color = t.label });
        u.text(Rect.init(r.x + 92, r.y + 68, r.w - 112, 20), "Your changes will be lost if you don\u{2019}t save them.", .{ .size = 12, .color = t.secondary_label });
        const by = r.bottom() - 48;
        const dont = u.button("confirm-dont", Rect.init(r.x + 20, by, 104, 28), "Don\u{2019}t Save", .{});
        const cancel = u.button("confirm-cancel", Rect.init(r.right() - 20 - 190, by, 90, 28), "Cancel", .{});
        const ok = u.button("confirm-save", Rect.init(r.right() - 20 - 90, by, 90, 28), "Save", .{ .style = .primary });
        if (dont) {
            self.sheet = .none;
            self.perform(u, self.pending);
        } else if (cancel) {
            self.cancelSheet(u);
        } else if (ok) {
            self.confirmSave(u);
        }
    }

    fn drawAlert(self: *App, u: *Ui) void {
        const t = u.theme;
        const w: i32 = 380;
        const h: i32 = 150;
        const r = Rect.init(@divTrunc(u.width() - w, 2), 10, w, h);
        sheetPanel(u, r);
        if (self.cachedIcon(2, 48)) |img| u.canvas.drawImage(img, r.x + 20, r.y + 20, 255);
        _ = u.paragraph(Rect.init(r.x + 84, r.y + 20, r.w - 104, 40), self.alert_title[0..self.alert_title_len], .{ .size = 13, .weight = .bold, .color = t.label });
        _ = u.paragraph(Rect.init(r.x + 84, r.y + 60, r.w - 104, 40), self.alert_body[0..self.alert_body_len], .{ .size = 12, .color = t.secondary_label });
        if (u.button("alert-ok", Rect.init(r.right() - 20 - 90, r.bottom() - 46, 90, 28), "OK", .{ .style = .primary })) {
            self.sheet = .none;
            self.needs_redraw = true;
        }
    }
};
