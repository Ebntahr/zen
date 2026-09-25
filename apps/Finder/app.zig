//! Finder: the Zen OS file browser.
//!
//! Layout (macOS 26 style): a floating translucent sidebar pane on the left
//! (the traffic lights sit in its top corner), a unified toolbar with glass
//! controls over the content, an icon grid or a sortable list, and a status
//! bar. Locations are paths or URLs ("sys:proc"), so the same browser shows
//! the file system and the kernel's schemes.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const font = @import("font");
const abi = @import("abi");
const zen = @import("zen");
const icons = @import("icons");
const fs = @import("fs.zig");
const IconCache = @import("iconcache.zig").IconCache;

const Ui = ui.Ui;
const Rect = ui.Rect;
const TextState = ui.TextState;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const Flags = abi.window.Flags;
const Color = gfx.Color;
const hashId = ui.ui.hashId;
const pm = ui.pm;

// Geometry.
const SIDEBAR_W: i32 = 212;
const TOOLBAR_H: i32 = 52;
const STATUS_H: i32 = 28;
const ICON: u32 = 64;
const CELL_W: i32 = 104;
const CELL_H: i32 = 110;
const GRID_PAD: i32 = 14;
const ROW_H: i32 = 24;
const HEADER_H: i32 = 28;
const LABEL_SIZE: f32 = 12;
const LABEL_LINE: i32 = 15;
const SIDE_ROW: i32 = 28;

pub const View = enum { icons, list };

/// Host previews set this before `ui.renderOnce` to show a prepared state.
pub const PreviewOptions = struct {
    home: []const u8,
    location: []const u8,
    view: View = .icons,
    selected: ?[]const u8 = null,
    search: ?[]const u8 = null,
    sort: fs.SortKey = .name,
    ascending: bool = true,
    info: bool = false,
    goto: ?[]const u8 = null,
    alert: ?[]const u8 = null,
    rename: bool = false,
    /// Fixed "now" for dates, so previews are reproducible.
    now: ?i64 = null,
};
pub var preview_options: ?PreviewOptions = null;

pub const M = struct {
    pub const about = 1;
    pub const quit = 2;
    pub const new_folder = 10;
    pub const open = 11;
    pub const rename = 12;
    pub const get_info = 13;
    pub const trash = 14;
    pub const close = 15;
    pub const cut = 20;
    pub const copy = 21;
    pub const paste = 22;
    pub const select_all = 23;
    pub const view_icons = 30;
    pub const view_list = 31;
    pub const sort_name = 32;
    pub const sort_kind = 33;
    pub const sort_date = 34;
    pub const sort_size = 35;
    pub const hidden = 36;
    pub const back = 40;
    pub const forward = 41;
    pub const enclosing = 42;
    pub const goto = 43;
    pub const go_place = 50; // + place index
};

const Place = struct {
    label: []const u8,
    sym: icons.Symbol,
    path: []const u8,
    section: u8,
};

const Sheet = enum { none, goto, info };

const InfoData = struct {
    owner: [64]u8 = undefined,
    owner_len: usize = 0,
    group: [64]u8 = undefined,
    group_len: usize = 0,
};

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Finder",
        .width = 900,
        .height = 560,
        .min_width = 560,
        .min_height = 340,
        .flags = Flags.full_size_content | Flags.resizable | Flags.transparent,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    home: []const u8,
    places: [12]Place = undefined,
    place_count: usize = 0,

    loc_buf: [fs.max_path]u8 = undefined,
    loc_len: usize = 0,
    back: std.ArrayList([]u8) = .empty,
    fwd: std.ArrayList([]u8) = .empty,

    listing: fs.Listing,
    order: std.ArrayList(u32) = .empty,
    sel: ?u32 = null,
    view: View = .icons,
    sort_key: fs.SortKey = .name,
    sort_asc: bool = true,
    show_hidden: bool = false,
    free: ?u64 = null,
    now: i64 = 0,
    fixed_now: ?i64 = null,

    search: TextState = .{},
    scroll: ui.ScrollState = .{},
    side_scroll: ui.ScrollState = .{},
    cache: IconCache,
    side_img: ?gfx.Image = null,
    side_key: u64 = 0,
    cols: i32 = 1,
    ensure_visible: bool = false,
    /// Incremented whenever the listing is replaced.
    generation: u32 = 0,

    alert_buf: [320]u8 = undefined,
    alert_len: usize = 0,
    sheet: Sheet = .none,
    goto_field: TextState = .{},
    goto_error: bool = false,
    info: InfoData = .{},
    renaming: bool = false,
    rename_field: TextState = .{},
    rename_name: [256]u8 = undefined,
    rename_name_len: usize = 0,

    type_buf: [32]u8 = undefined,
    type_len: usize = 0,
    type_time: i64 = 0,

    // Idle-frame detection (frames without input are skipped).
    needs_redraw: bool = true,
    last_mx: i32 = -1,
    last_my: i32 = -1,
    last_focused: bool = true,
    last_dark: bool = false,
    last_accent: u32 = 0,
    last_w: i32 = 0,
    last_h: i32 = 0,
    last_poll: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        var self = App{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .home = "/",
            .listing = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
            .cache = IconCache.init(allocator, u.fonts),
        };
        const a = self.arena.allocator();
        const po = preview_options;
        if (po) |p| {
            self.home = try a.dupe(u8, p.home);
        } else if (std.posix.getenv("ZEN_USER_HOME") orelse std.posix.getenv("HOME")) |h| {
            if (h.len > 0) self.home = try a.dupe(u8, std.mem.trimRight(u8, h, "/"));
            if (self.home.len == 0) self.home = "/";
        }
        try self.buildPlaces();
        u.win.setTitleHeight(TOOLBAR_H);

        var start: []const u8 = self.home;
        var sb: [fs.max_path]u8 = undefined;
        if (po) |p| {
            start = p.location;
            self.view = p.view;
            self.sort_key = p.sort;
            self.sort_asc = p.ascending;
            self.fixed_now = p.now;
        } else {
            var args = std.process.args();
            _ = args.next();
            if (args.next()) |arg| {
                if (fs.resolve(&sb, arg, self.home, self.home)) |r| start = r;
            }
        }
        self.setLocation(start);
        self.reload(u);
        u.win.setTitle(fs.displayName(self.loc()));

        if (po) |p| {
            if (p.search) |s| {
                self.search.set(allocator, s);
                self.refilter();
            }
            if (p.selected) |name| self.selectName(name);
            if (p.alert) |msg| self.setAlert("{s}", .{msg});
            if (p.info) self.openInfo();
            if (p.goto) |g| {
                self.sheet = .goto;
                self.goto_field.set(allocator, g);
                u.focus = hashId("goto");
            }
            if (p.rename) self.beginRename(u);
        }
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.back.items) |s| self.allocator.free(s);
        for (self.fwd.items) |s| self.allocator.free(s);
        self.back.deinit(self.allocator);
        self.fwd.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.listing.deinit();
        self.search.deinit(self.allocator);
        self.goto_field.deinit(self.allocator);
        self.rename_field.deinit(self.allocator);
        if (self.side_img) |*img| img.deinit(self.allocator);
        self.cache.deinit();
        self.arena.deinit();
    }

    fn buildPlaces(self: *App) !void {
        const a = self.arena.allocator();
        const favs = [_]struct { []const u8, icons.Symbol, ?[]const u8 }{
            .{ "Home", .house, null },
            .{ "Desktop", .desktop, "Desktop" },
            .{ "Documents", .document, "Documents" },
            .{ "Downloads", .download, "Downloads" },
            .{ "Applications", .apps, "/Applications" },
            .{ "Pictures", .photo, "Pictures" },
            .{ "Music", .music, "Music" },
            .{ "Movies", .film, "Movies" },
        };
        for (favs) |f| {
            const path = if (f[2]) |sub|
                (if (sub[0] == '/') sub else try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimRight(u8, self.home, "/"), sub }))
            else
                self.home;
            self.places[self.place_count] = .{ .label = if (f[2] == null) std.fs.path.basename(self.home) else f[0], .sym = f[1], .path = path, .section = 0 };
            if (self.places[self.place_count].label.len == 0) self.places[self.place_count].label = "Home";
            self.place_count += 1;
        }
        self.places[self.place_count] = .{ .label = "Zen HD", .sym = .disk, .path = "/", .section = 1 };
        self.place_count += 1;
        self.places[self.place_count] = .{ .label = "System", .sym = .cpu, .path = "sys:", .section = 1 };
        self.place_count += 1;
    }

    // ------------------------------------------------------------------
    // Location & listing
    // ------------------------------------------------------------------

    fn loc(self: *const App) []const u8 {
        return self.loc_buf[0..self.loc_len];
    }

    fn setLocation(self: *App, l: []const u8) void {
        const n = @min(l.len, self.loc_buf.len);
        std.mem.copyForwards(u8, self.loc_buf[0..n], l[0..n]);
        self.loc_len = n;
    }

    fn reload(self: *App, u: *Ui) void {
        _ = u;
        var keep: [256]u8 = undefined;
        var keep_len: usize = 0;
        if (self.sel) |i| {
            const name = self.listing.entries[i].name;
            keep_len = @min(name.len, keep.len);
            @memcpy(keep[0..keep_len], name[0..keep_len]);
        }
        self.listing.deinit();
        self.listing = fs.load(self.allocator, self.loc(), self.home, self.show_hidden);
        self.generation +%= 1;
        self.free = if (fs.isUrl(self.loc())) null else fs.freeBytes(self.loc());
        self.now = self.fixed_now orelse std.time.timestamp();
        self.last_poll = std.time.milliTimestamp();
        self.sel = null;
        self.refilter();
        // Keep the selection across refreshes without scrolling to it.
        if (keep_len > 0) self.selectNameEx(keep[0..keep_len], false);
        self.needs_redraw = true;
    }

    fn refilter(self: *App) void {
        self.order.clearRetainingCapacity();
        const q = std.mem.trim(u8, self.search.text(), " ");
        for (self.listing.entries, 0..) |e, i| {
            if (q.len > 0 and std.ascii.indexOfIgnoreCase(e.display, q) == null) continue;
            self.order.append(self.allocator, @intCast(i)) catch break;
        }
        std.mem.sort(u32, self.order.items, fs.SortCtx{ .entries = self.listing.entries, .key = self.sort_key, .ascending = self.sort_asc }, fs.SortCtx.less);
        if (self.sel) |s| {
            if (std.mem.indexOfScalar(u32, self.order.items, s) == null) self.sel = null;
        }
        self.needs_redraw = true;
    }

    fn selectName(self: *App, name: []const u8) void {
        self.selectNameEx(name, true);
    }

    fn selectNameEx(self: *App, name: []const u8, reveal: bool) void {
        for (self.order.items) |i| {
            if (std.mem.eql(u8, self.listing.entries[i].name, name)) {
                self.sel = i;
                if (reveal) self.ensure_visible = true;
                return;
            }
        }
    }

    fn navigate(self: *App, u: *Ui, target: []const u8, record: bool) void {
        if (std.mem.eql(u8, target, self.loc())) return;
        if (record) {
            if (self.allocator.dupe(u8, self.loc())) |copy| {
                self.back.append(self.allocator, copy) catch self.allocator.free(copy);
            } else |_| {}
            for (self.fwd.items) |s| self.allocator.free(s);
            self.fwd.clearRetainingCapacity();
        }
        // Remember where we came from to select it in the parent.
        var from: [256]u8 = undefined;
        var from_len: usize = 0;
        if (fs.parent(self.loc())) |p| {
            if (std.mem.eql(u8, p, target)) {
                const base = std.fs.path.basename(self.loc());
                from_len = @min(base.len, from.len);
                @memcpy(from[0..from_len], base[0..from_len]);
            }
        }
        self.setLocation(target);
        self.sel = null;
        self.search.set(self.allocator, "");
        self.cancelRename();
        self.scroll = .{};
        self.reload(u);
        if (from_len > 0) self.selectName(from[0..from_len]);
        u.win.setTitle(fs.displayName(self.loc()));
        // Back/Forward/New Folder availability changed.
        self.refreshMenu(u);
    }

    fn goBack(self: *App, u: *Ui) void {
        const prev = self.back.pop() orelse return;
        defer self.allocator.free(prev);
        if (self.allocator.dupe(u8, self.loc())) |copy| {
            self.fwd.append(self.allocator, copy) catch self.allocator.free(copy);
        } else |_| {}
        self.navigate(u, prev, false);
    }

    fn goForward(self: *App, u: *Ui) void {
        const next = self.fwd.pop() orelse return;
        defer self.allocator.free(next);
        if (self.allocator.dupe(u8, self.loc())) |copy| {
            self.back.append(self.allocator, copy) catch self.allocator.free(copy);
        } else |_| {}
        self.navigate(u, next, false);
    }

    fn goParent(self: *App, u: *Ui) void {
        const p = fs.parent(self.loc()) orelse return;
        var buf: [fs.max_path]u8 = undefined;
        @memcpy(buf[0..p.len], p);
        self.navigate(u, buf[0..p.len], true);
    }

    fn setAlert(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.alert_buf, fmt, args) catch self.alert_buf[0..];
        self.alert_len = s.len;
        self.needs_redraw = true;
    }

    fn selected(self: *App) ?*fs.Entry {
        const i = self.sel orelse return null;
        return &self.listing.entries[i];
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    fn openSelected(self: *App, u: *Ui) void {
        const e = self.selected() orelse return;
        self.openEntry(u, e);
    }

    fn openEntry(self: *App, u: *Ui, e: *fs.Entry) void {
        var pb: [fs.max_path]u8 = undefined;
        const full = fs.join(&pb, self.loc(), e.name);
        switch (e.kind) {
            .folder => {
                var copy: [fs.max_path]u8 = undefined;
                @memcpy(copy[0..full.len], full);
                self.navigate(u, copy[0..full.len], true);
            },
            .app => self.launchApp(full, e.display),
            .file, .exec, .link, .other => {
                if (fs.isTextLike(e)) {
                    self.openInTextEdit(full, e.display);
                } else {
                    self.setAlert("There is no application set to open the document \u{201C}{s}\u{201D}.", .{e.display});
                }
            },
        }
    }

    fn launchApp(self: *App, full: []const u8, name: []const u8) void {
        var cmd: [fs.max_path + 16]u8 = undefined;
        var key: []const u8 = full;
        var id_buf: [128]u8 = undefined;
        if (std.mem.indexOfScalar(u8, full, ' ') != null) {
            // launchd splits its command on spaces: use the bundle id instead.
            if (zen.bundle.load(self.allocator, full)) |b| {
                var bb = b;
                defer bb.deinit();
                const n = @min(b.info.id.len, id_buf.len);
                @memcpy(id_buf[0..n], b.info.id[0..n]);
                key = id_buf[0..n];
            } else |_| {}
        }
        const line = std.fmt.bufPrint(&cmd, "open {s}\n", .{key}) catch return;
        var reply_buf: [512]u8 = undefined;
        const reply = fs.launchCtl(line, &reply_buf) catch |err| {
            self.setAlert("\u{201C}{s}\u{201D} can\u{2019}t be opened: the launch service is not available ({s}).", .{ name, @errorName(err) });
            return;
        };
        if (std.mem.startsWith(u8, reply, "ok")) return;
        const msg = if (std.mem.startsWith(u8, reply, "error ")) reply[6..] else reply;
        self.setAlert("\u{201C}{s}\u{201D} can\u{2019}t be opened: {s}.", .{ name, msg });
    }

    fn openInTextEdit(self: *App, full: []const u8, name: []const u8) void {
        // launchd splits its command on spaces, so a path containing one
        // travels as a percent-encoded file: URL (TextEdit decodes it).
        var enc: [fs.max_path * 3]u8 = undefined;
        var cmd: [fs.max_path * 3 + 48]u8 = undefined;
        const arg_is_url = fs.isUrl(full);
        const needs_url = !arg_is_url and std.mem.indexOfAny(u8, full, " \t%") != null;
        const line = if (needs_url)
            std.fmt.bufPrint(&cmd, "open com.zen.TextEdit file:{s}\n", .{zen.url.encode(full, &enc)}) catch return
        else
            std.fmt.bufPrint(&cmd, "open com.zen.TextEdit {s}\n", .{full}) catch return;
        var reply_buf: [512]u8 = undefined;
        const reply = fs.launchCtl(line, &reply_buf) catch |err| {
            self.setAlert("\u{201C}{s}\u{201D} can\u{2019}t be opened: the launch service is not available ({s}).", .{ name, @errorName(err) });
            return;
        };
        if (std.mem.startsWith(u8, reply, "ok")) {
            // Powerbox: the user chose this file, so the sandboxed editor may use it.
            var it = std.mem.tokenizeScalar(u8, reply, ' ');
            _ = it.next();
            if (it.next()) |pid_s| {
                if (std.fmt.parseInt(u32, pid_s, 10)) |pid| {
                    var ub: [fs.max_path + 8]u8 = undefined;
                    const url = if (arg_is_url) full else (std.fmt.bufPrint(&ub, "file:{s}", .{full}) catch full);
                    zen.sys.sandboxGrant(pid, url, abi.sandbox.READ | abi.sandbox.WRITE) catch {};
                } else |_| {}
            }
            return;
        }
        const msg = if (std.mem.startsWith(u8, reply, "error ")) reply[6..] else reply;
        self.setAlert("\u{201C}{s}\u{201D} can\u{2019}t be opened: {s}.", .{ name, msg });
    }

    fn newFolder(self: *App, u: *Ui) void {
        if (fs.isUrl(self.loc())) {
            self.setAlert("You can\u{2019}t create a folder in \u{201C}{s}\u{201D}.", .{fs.displayName(self.loc())});
            return;
        }
        var nb: [256]u8 = undefined;
        const name = fs.newFolder(&nb, self.loc()) catch |err| {
            self.setAlert("The folder couldn\u{2019}t be created ({s}).", .{@errorName(err)});
            return;
        };
        self.search.set(self.allocator, "");
        self.reload(u);
        self.selectName(name);
        self.beginRename(u);
    }

    fn beginRename(self: *App, u: *Ui) void {
        const e = self.selected() orelse return;
        if (fs.isUrl(self.loc())) return;
        self.renaming = true;
        self.rename_name_len = @min(e.name.len, self.rename_name.len);
        @memcpy(self.rename_name[0..self.rename_name_len], e.name[0..self.rename_name_len]);
        self.rename_field.set(self.allocator, e.name);
        // Select the name without its extension, like Finder.
        const ext = fs.extension(e.name);
        self.rename_field.anchor = 0;
        self.rename_field.cursor = if (ext.len > 0 and e.kind != .folder) e.name.len - ext.len - 1 else e.name.len;
        u.focus = hashId("rename");
        self.ensure_visible = true;
        self.needs_redraw = true;
    }

    fn cancelRename(self: *App) void {
        self.renaming = false;
        self.needs_redraw = true;
    }

    fn commitRename(self: *App, u: *Ui) void {
        if (!self.renaming) return;
        self.renaming = false;
        const old = self.rename_name[0..self.rename_name_len];
        const new = std.mem.trim(u8, self.rename_field.text(), " ");
        if (new.len == 0 or std.mem.eql(u8, old, new)) return;
        var newb: [256]u8 = undefined;
        const n = @min(new.len, newb.len);
        @memcpy(newb[0..n], new[0..n]);
        fs.rename(self.loc(), old, newb[0..n]) catch |err| {
            const why = switch (err) {
                error.PathAlreadyExists => "that name is already taken",
                error.InvalidName => "the name is not valid",
                error.AccessDenied, error.PermissionDenied => "you don\u{2019}t have permission",
                else => @errorName(err),
            };
            self.setAlert("\u{201C}{s}\u{201D} couldn\u{2019}t be renamed: {s}.", .{ old, why });
            return;
        };
        self.sel = null;
        self.reload(u);
        self.selectName(newb[0..n]);
    }

    /// A click on another item ends a rename; keep that item selected.
    fn commitRenameThenSelect(self: *App, u: *Ui, idx: u32) void {
        var nb: [256]u8 = undefined;
        const name = self.listing.entries[idx].name;
        const n = @min(name.len, nb.len);
        @memcpy(nb[0..n], name[0..n]);
        self.commitRename(u);
        self.selectName(nb[0..n]);
    }

    fn trashSelected(self: *App, u: *Ui) void {
        const e = self.selected() orelse return;
        if (fs.isUrl(self.loc())) {
            self.setAlert("Items in \u{201C}{s}\u{201D} can\u{2019}t be moved to the Trash.", .{fs.displayName(self.loc())});
            return;
        }
        // Select the next item afterwards.
        const pos = std.mem.indexOfScalar(u32, self.order.items, self.sel.?) orelse 0;
        var name_buf: [256]u8 = undefined;
        const nl = @min(e.name.len, name_buf.len);
        @memcpy(name_buf[0..nl], e.name[0..nl]);
        fs.moveToTrash(self.loc(), name_buf[0..nl], self.home) catch |err| {
            const why = switch (err) {
                error.AlreadyInTrash => "it is already in the Trash",
                error.AccessDenied, error.PermissionDenied => "you don\u{2019}t have permission",
                else => @errorName(err),
            };
            self.setAlert("\u{201C}{s}\u{201D} couldn\u{2019}t be moved to the Trash: {s}.", .{ name_buf[0..nl], why });
            return;
        };
        self.sel = null;
        self.reload(u);
        if (self.order.items.len > 0) {
            self.sel = self.order.items[@min(pos, self.order.items.len - 1)];
            self.ensure_visible = true;
        }
    }

    fn openInfo(self: *App) void {
        self.sheet = .info;
        self.info = .{};
        var uid: u32 = 0;
        var gid: u32 = 0;
        if (self.selected()) |e| {
            uid = e.uid;
            gid = e.gid;
        } else if (fs.statPath(self.loc())) |st| {
            uid = st.uid;
            gid = st.gid;
        }
        var db_ok = false;
        if (zen.users.Db.load(self.allocator, "/")) |db_in| {
            var db = db_in;
            defer db.deinit();
            db_ok = true;
            const un = if (db.userById(uid)) |usr| usr.name else "";
            const gn = if (db.groupById(gid)) |g| g.name else "";
            const os_ = if (un.len > 0) std.fmt.bufPrint(&self.info.owner, "{s} (uid {d})", .{ un, uid }) else std.fmt.bufPrint(&self.info.owner, "uid {d}", .{uid});
            self.info.owner_len = (os_ catch "").len;
            const gs_ = if (gn.len > 0) std.fmt.bufPrint(&self.info.group, "{s} (gid {d})", .{ gn, gid }) else std.fmt.bufPrint(&self.info.group, "gid {d}", .{gid});
            self.info.group_len = (gs_ catch "").len;
        } else |_| {}
        if (!db_ok) {
            self.info.owner_len = (std.fmt.bufPrint(&self.info.owner, "uid {d}", .{uid}) catch "").len;
            self.info.group_len = (std.fmt.bufPrint(&self.info.group, "gid {d}", .{gid}) catch "").len;
        }
        self.needs_redraw = true;
    }

    fn openGoto(self: *App, u: *Ui) void {
        self.sheet = .goto;
        self.goto_error = false;
        self.goto_field.set(self.allocator, self.loc());
        self.goto_field.anchor = 0;
        u.focus = hashId("goto");
        self.needs_redraw = true;
    }

    fn submitGoto(self: *App, u: *Ui) void {
        var rb: [fs.max_path]u8 = undefined;
        const target = fs.resolve(&rb, self.goto_field.text(), self.loc(), self.home) orelse {
            self.goto_error = true;
            return;
        };
        // Only accept locations that can be listed.
        var dir = std.fs.cwd().openDir(target, .{ .iterate = true }) catch {
            self.goto_error = true;
            return;
        };
        dir.close();
        self.sheet = .none;
        u.focus = 0;
        var copy: [fs.max_path]u8 = undefined;
        @memcpy(copy[0..target.len], target);
        self.navigate(u, copy[0..target.len], true);
    }

    fn setView(self: *App, u: *Ui, v: View) void {
        if (self.view == v) return;
        self.view = v;
        self.scroll = .{};
        self.ensure_visible = true;
        self.needs_redraw = true;
        self.refreshMenu(u);
    }

    fn setSort(self: *App, u: *Ui, k: fs.SortKey, toggle: bool) void {
        if (self.sort_key == k and toggle) {
            self.sort_asc = !self.sort_asc;
        } else if (self.sort_key != k) {
            self.sort_key = k;
            self.sort_asc = k == .name or k == .kind;
        }
        self.refilter();
        self.ensure_visible = true;
        self.refreshMenu(u);
    }

    fn moveSelection(self: *App, delta: i32) void {
        const n: i32 = @intCast(self.order.items.len);
        if (n == 0) return;
        var pos: i32 = -1;
        if (self.sel) |s| {
            if (std.mem.indexOfScalar(u32, self.order.items, s)) |p| pos = @intCast(p);
        }
        var next: i32 = undefined;
        if (pos < 0) {
            next = if (delta > 0) 0 else n - 1;
        } else {
            next = pos + delta;
            if (next < 0 or next >= n) {
                // Grid: stay put when moving off an edge vertically.
                if (@abs(delta) > 1) return;
                next = std.math.clamp(next, 0, n - 1);
            }
        }
        self.sel = self.order.items[@intCast(next)];
        self.ensure_visible = true;
        self.needs_redraw = true;
    }

    fn typeSelect(self: *App, text: []const u8) void {
        const now = std.time.milliTimestamp();
        if (now - self.type_time > 1000) self.type_len = 0;
        self.type_time = now;
        const n = @min(text.len, self.type_buf.len - self.type_len);
        @memcpy(self.type_buf[self.type_len .. self.type_len + n], text[0..n]);
        self.type_len += n;
        const prefix = self.type_buf[0..self.type_len];
        // First entry (in display order) at or after the prefix.
        var best: ?u32 = null;
        for (self.order.items) |i| {
            const d = self.listing.entries[i].display;
            if (d.len >= prefix.len and std.ascii.eqlIgnoreCase(d[0..prefix.len], prefix)) {
                best = i;
                break;
            }
        }
        if (best) |b| {
            self.sel = b;
            self.ensure_visible = true;
            self.needs_redraw = true;
        }
    }

    // ------------------------------------------------------------------
    // Menus
    // ------------------------------------------------------------------

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        const chk = abi.window.MenuItemFlags.checked;
        const dis = abi.window.MenuItemFlags.disabled;
        const url = fs.isUrl(self.loc());
        mw.beginMenu("Finder");
        mw.item(M.about, "About Finder", 0, 0, 0);
        mw.separator();
        mw.item(M.quit, "Quit Finder", 'q', 0, 0);
        mw.endMenu();

        mw.beginMenu("File");
        mw.item(M.new_folder, "New Folder", 'N', 0, if (url) dis else 0);
        mw.item(M.open, "Open", 'o', 0, 0);
        mw.separator();
        mw.item(M.get_info, "Get Info", 'i', 0, 0);
        mw.item(M.rename, "Rename", 0, 0, if (url) dis else 0);
        mw.separator();
        mw.item(M.trash, "Move to Trash  \u{2318}\u{232B}", 0, 0, if (url) dis else 0);
        mw.separator();
        mw.item(M.close, "Close Window", 'w', 0, 0);
        mw.endMenu();

        mw.beginMenu("Edit");
        mw.item(M.cut, "Cut", 'x', 0, 0);
        mw.item(M.copy, "Copy", 'c', 0, 0);
        mw.item(M.paste, "Paste", 'v', 0, 0);
        mw.item(M.select_all, "Select All", 'a', 0, 0);
        mw.endMenu();

        mw.beginMenu("View");
        mw.item(M.view_icons, "as Icons", '1', 0, if (self.view == .icons) chk else 0);
        mw.item(M.view_list, "as List", '2', 0, if (self.view == .list) chk else 0);
        mw.separator();
        mw.item(M.sort_name, "Sort by Name", 0, 0, if (self.sort_key == .name) chk else 0);
        mw.item(M.sort_kind, "Sort by Kind", 0, 0, if (self.sort_key == .kind) chk else 0);
        mw.item(M.sort_date, "Sort by Date Modified", 0, 0, if (self.sort_key == .date) chk else 0);
        mw.item(M.sort_size, "Sort by Size", 0, 0, if (self.sort_key == .size) chk else 0);
        mw.separator();
        mw.item(M.hidden, "Show Hidden Files", '.', @intCast(Mods.cmd | Mods.shift), if (self.show_hidden) chk else 0);
        mw.endMenu();

        mw.beginMenu("Go");
        mw.item(M.back, "Back", '[', 0, if (self.back.items.len == 0) dis else 0);
        mw.item(M.forward, "Forward", ']', 0, if (self.fwd.items.len == 0) dis else 0);
        mw.item(M.enclosing, "Enclosing Folder  \u{2318}\u{2191}", 0, 0, if (fs.parent(self.loc()) == null) dis else 0);
        mw.separator();
        const KeyDef = struct { ch: u8, mods: u8 };
        const keys = [_]KeyDef{ .{ .ch = 'H', .mods = 0 }, .{ .ch = 'D', .mods = 0 }, .{ .ch = 'O', .mods = 0 }, .{ .ch = 'l', .mods = @intCast(Mods.cmd | Mods.alt) }, .{ .ch = 'A', .mods = 0 }, .{ .ch = 0, .mods = 0 }, .{ .ch = 0, .mods = 0 }, .{ .ch = 0, .mods = 0 }, .{ .ch = 'C', .mods = 0 }, .{ .ch = 0, .mods = 0 } };
        for (self.places[0..self.place_count], 0..) |p, i| {
            const k: KeyDef = if (i < keys.len) keys[i] else .{ .ch = 0, .mods = 0 };
            const title = if (i == 0) "Home" else p.label;
            mw.item(@intCast(M.go_place + i), title, k.ch, k.mods, 0);
        }
        mw.separator();
        mw.item(M.goto, "Go to Folder\u{2026}", 'G', 0, 0);
        mw.endMenu();
    }

    fn refreshMenu(self: *App, u: *Ui) void {
        var buf: [4096]u8 = undefined;
        var mw = abi.window.MenuWriter{ .buf = &buf };
        self.menu(&mw);
        u.win.setMenu(mw.bytes());
    }

    fn injectKey(u: *Ui, code: u16, mods: u32) void {
        if (u.key_count >= u.keys.len) return;
        u.keys[u.key_count] = .{ .code = code, .mods = mods, .repeat = false };
        u.key_count += 1;
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        self.needs_redraw = true;
        switch (id) {
            M.about => self.setAlert("Finder 1.0 \u{2014} Zen OS. Everything is a URL: try Go \u{203A} Go to Folder with sys:proc.", .{}),
            M.quit, M.close => u.quit = true,
            M.new_folder => self.newFolder(u),
            M.open => self.openSelected(u),
            M.rename => self.beginRename(u),
            M.get_info => if (self.sheet == .info) {
                self.sheet = .none;
            } else self.openInfo(),
            M.trash => self.trashSelected(u),
            M.cut => injectKey(u, Key.x, Mods.cmd),
            M.copy => injectKey(u, Key.c, Mods.cmd),
            M.paste => injectKey(u, Key.v, Mods.cmd),
            M.select_all => injectKey(u, Key.a, Mods.cmd),
            M.view_icons => self.setView(u, .icons),
            M.view_list => self.setView(u, .list),
            M.sort_name => self.setSort(u, .name, false),
            M.sort_kind => self.setSort(u, .kind, false),
            M.sort_date => self.setSort(u, .date, false),
            M.sort_size => self.setSort(u, .size, false),
            M.hidden => {
                self.show_hidden = !self.show_hidden;
                self.reload(u);
                self.refreshMenu(u);
            },
            M.back => self.goBack(u),
            M.forward => self.goForward(u),
            M.enclosing => self.goParent(u),
            M.goto => self.openGoto(u),
            else => if (id >= M.go_place and id < M.go_place + self.place_count) {
                const p = self.places[@intCast(id - M.go_place)].path;
                self.navigate(u, p, true);
            },
        }
    }

    pub fn shouldClose(self: *App, u: *Ui) bool {
        _ = self;
        _ = u;
        return true;
    }

    pub fn timeoutMs(self: *App) i32 {
        if (self.needs_redraw) return 0;
        return 2000;
    }

    // ------------------------------------------------------------------
    // Frame
    // ------------------------------------------------------------------

    fn isIdle(self: *App, u: *Ui) bool {
        if (self.needs_redraw) return false;
        if (u.key_count > 0 or u.text_len > 0 or u.mouse_pressed or u.mouse_released or u.right_pressed) return false;
        if (u.scroll_dx != 0 or u.scroll_dy != 0 or u.menu_id != null or u.resized) return false;
        if (u.focused != self.last_focused or u.theme.dark != self.last_dark or u.theme.accent != self.last_accent) return false;
        if (u.width() != self.last_w or u.height() != self.last_h) return false;
        if (u.mouse_x == self.last_mx and u.mouse_y == self.last_my) return true;
        // Pointer motion over the files (no hover effects there) needs no redraw.
        if (u.mouse_down or self.sheet != .none) return false;
        const top = TOOLBAR_H + (if (self.alert_len > 0) @as(i32, 44) else 0) + HEADER_H + 2;
        const files = Rect.init(SIDEBAR_W, top, u.width() - SIDEBAR_W - 14, u.height() - STATUS_H - top);
        return files.contains(u.mouse_x, u.mouse_y) and files.contains(self.last_mx, self.last_my);
    }

    /// Refresh the listing when the folder changed on disk.
    fn pollChanges(self: *App, u: *Ui) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll < 1500) return;
        self.last_poll = now;
        if (self.renaming or self.sheet != .none) return;
        if (fs.isUrl(self.loc())) {
            self.reload(u);
            return;
        }
        const m = fs.mtimeOf(self.loc());
        if (m != self.listing.dir_mtime) self.reload(u);
    }

    pub fn frame(self: *App, u: *Ui) void {
        if (self.isIdle(u)) {
            self.last_mx = u.mouse_x;
            self.last_my = u.mouse_y;
            self.pollChanges(u);
            if (!self.needs_redraw) {
                u.cursor = u.last_cursor;
                return;
            }
        }
        self.needs_redraw = false;
        self.last_mx = u.mouse_x;
        self.last_my = u.mouse_y;
        self.last_focused = u.focused;
        self.last_dark = u.theme.dark;
        self.last_accent = u.theme.accent;
        self.last_w = u.width();
        self.last_h = u.height();

        // A click outside the rename field commits the rename.
        if (self.renaming and u.focus != hashId("rename")) self.commitRename(u);

        self.handleKeys(u);

        const t = u.theme;
        const w = u.width();
        const h = u.height();
        u.canvas.clear(0);
        self.drawSidebarBackground(u);
        u.fillRect(Rect.init(SIDEBAR_W, 0, w - SIDEBAR_W, h), t.content_bg);

        // While a sheet is up, the window behind it ignores the mouse.
        const saved = maskInput(u, self.sheet != .none);
        self.drawSidebar(u);
        var top = TOOLBAR_H;
        self.drawToolbar(u);
        if (self.alert_len > 0) top = self.drawAlert(u, top);
        const main = Rect.init(SIDEBAR_W, top, w - SIDEBAR_W, h - STATUS_H - top);
        if (self.listing.err) |err| {
            self.drawError(u, main, err);
        } else switch (self.view) {
            .icons => self.drawGrid(u, main),
            .list => self.drawList(u, main),
        }
        self.drawStatus(u);
        restoreInput(u, saved);

        switch (self.sheet) {
            .none => {},
            .goto => {
                u.focus = hashId("goto");
                self.drawGotoSheet(u);
            },
            .info => self.drawInfo(u),
        }

        // Unified title area: presses on empty toolbar space move the window
        // (the toolkit zooms on a double-click there).
        if (u.mouse_pressed and u.hot == 0 and u.mouse_y < TOOLBAR_H and self.sheet == .none and u.click_count < 2) {
            u.win.beginMove();
        }
    }

    const SavedInput = struct { active: bool, mx: i32, my: i32, pressed: bool, released: bool, sdy: f32 };

    fn maskInput(u: *Ui, on: bool) SavedInput {
        const s = SavedInput{ .active = on, .mx = u.mouse_x, .my = u.mouse_y, .pressed = u.mouse_pressed, .released = u.mouse_released, .sdy = u.scroll_dy };
        if (on) {
            u.mouse_x = -10000;
            u.mouse_y = -10000;
            u.mouse_pressed = false;
            u.mouse_released = false;
            u.scroll_dy = 0;
        }
        return s;
    }

    fn restoreInput(u: *Ui, s: SavedInput) void {
        if (!s.active) return;
        u.mouse_x = s.mx;
        u.mouse_y = s.my;
        u.mouse_pressed = s.pressed;
        u.mouse_released = s.released;
        u.scroll_dy = s.sdy;
    }

    fn handleKeys(self: *App, u: *Ui) void {
        const search_id = hashId("search");
        const text_focus = u.focus != 0 and (u.focus == search_id or u.focus == hashId("rename") or u.focus == hashId("goto"));
        for (u.keys[0..u.key_count]) |k| {
            const cmd = k.mods & Mods.cmd != 0;
            const shift = k.mods & Mods.shift != 0;
            // Sheet keys.
            if (self.sheet == .info) {
                if (k.code == Key.esc or k.code == Key.enter or (cmd and k.code == Key.i)) {
                    self.sheet = .none;
                    self.needs_redraw = true;
                }
                continue;
            }
            if (self.sheet == .goto) {
                if (k.code == Key.esc) {
                    self.sheet = .none;
                    u.focus = 0;
                    self.needs_redraw = true;
                }
                continue;
            }
            if (u.focus == hashId("rename")) {
                if (k.code == Key.esc) {
                    self.cancelRename();
                    u.focus = 0;
                }
                continue;
            }
            if (u.focus == search_id) {
                if (k.code == Key.esc) {
                    self.search.set(self.allocator, "");
                    self.refilter();
                    u.focus = 0;
                } else if (k.code == Key.down or k.code == Key.tab) {
                    u.focus = 0;
                    self.moveSelection(1);
                }
                continue;
            }
            if (text_focus) continue;
            const step: i32 = if (self.view == .icons) self.cols else 1;
            switch (k.code) {
                Key.up => if (cmd) self.goParent(u) else self.moveSelection(-step),
                Key.down => if (cmd) self.openSelected(u) else self.moveSelection(step),
                Key.left => if (self.view == .icons) self.moveSelection(-1),
                Key.right => if (self.view == .icons) self.moveSelection(1),
                Key.home => {
                    self.sel = null;
                    self.moveSelection(1);
                },
                Key.end => {
                    self.sel = null;
                    self.moveSelection(-1);
                },
                Key.enter, Key.kpenter => self.openSelected(u),
                Key.f2 => self.beginRename(u),
                Key.backspace, Key.delete => if (cmd) self.trashSelected(u),
                Key.leftbrace => if (cmd) self.goBack(u),
                Key.rightbrace => if (cmd) self.goForward(u),
                Key.n => if (cmd and shift) self.newFolder(u),
                Key.g => if (cmd and shift) self.openGoto(u),
                Key.i => if (cmd) self.openInfo(),
                Key.f => if (cmd) {
                    u.focus = search_id;
                    self.search.anchor = 0;
                    self.search.cursor = self.search.buf.items.len;
                },
                Key.@"1" => if (cmd) self.setView(u, .icons),
                Key.@"2" => if (cmd) self.setView(u, .list),
                Key.esc => {
                    if (self.alert_len > 0) self.alert_len = 0 else if (self.search.buf.items.len > 0) {
                        self.search.set(self.allocator, "");
                        self.refilter();
                    } else self.sel = null;
                },
                else => {},
            }
            self.needs_redraw = true;
        }
        if (!text_focus and self.sheet == .none and u.text_len > 0 and u.mods & (Mods.cmd | Mods.ctrl) == 0) {
            const txt = u.text_in[0..u.text_len];
            if (!(txt.len == 1 and txt[0] == ' ')) self.typeSelect(txt);
        }
        if (text_focus or self.sheet != .none) return;
        u.keys_consumed = true;
    }

    // ------------------------------------------------------------------
    // Sidebar
    // ------------------------------------------------------------------

    fn sidebarPanel(u: *Ui) gfx.RectF {
        return gfx.RectF.init(8, 8, @floatFromInt(SIDEBAR_W - 16), @floatFromInt(u.height() - 16));
    }

    /// The sidebar column (panel + margins) is cached: the panel is a
    /// translucent material (vibrancy), the margins are opaque window
    /// background, and anti-aliased corners blend between the two.
    fn drawSidebarBackground(self: *App, u: *Ui) void {
        const t = u.theme;
        const h = u.height();
        const k = (@as(u64, @intCast(h)) << 32) ^ (@as(u64, t.content_bg) << 1) ^ t.sidebar_bg;
        if (self.side_img == null or self.side_key != k) {
            if (self.side_img) |*img| img.deinit(self.allocator);
            self.side_img = null;
            var img = gfx.Image.init(self.allocator, @intCast(SIDEBAR_W), @intCast(h)) catch return;
            const c = img.canvas();
            const outside = pm(t.content_bg);
            const inside = pm(t.sidebar_bg);
            const panel = sidebarPanel(u);
            const shape = gfx.shapes.RRectShape.init(gfx.RoundRect.smooth(panel, 12));
            var y: i32 = 0;
            while (y < h) : (y += 1) {
                const row = c.span(y, 0, SIDEBAR_W);
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const band = fy < panel.y + 24 or fy > panel.y + panel.h - 24;
                for (row, 0..) |*px, x| {
                    const fx = @as(f32, @floatFromInt(x)) + 0.5;
                    if (!band and fx > panel.x + 2 and fx < panel.x + panel.w - 2) {
                        px.* = inside;
                        continue;
                    }
                    const d = shape.sdf(fx, fy);
                    const cov = std.math.clamp(0.5 - d, 0, 1);
                    px.* = if (cov >= 1) inside else if (cov <= 0) outside else Color.lerp(outside, inside, cov);
                }
            }
            // Glass rim: light top edge, faint outline.
            var rim = gfx.RoundRect.smooth(panel.inset(0.5, 0.5), 12);
            c.strokeRRect(rim, 1, pm(if (t.dark) 0x2EFFFFFF else 0x14000000));
            rim.rect = panel.inset(1.5, 1.5);
            c.strokeRRect(rim, 1, pm(if (t.dark) 0x10FFFFFF else 0x66FFFFFF));
            self.side_img = img;
            self.side_key = k;
        }
        u.canvas.blitOpaque(self.side_img.?.canvas(), 0, 0);
    }

    fn drawSidebar(self: *App, u: *Ui) void {
        const t = u.theme;
        const panel = sidebarPanel(u);
        const area = Rect.init(@intFromFloat(panel.x), TOOLBAR_H - 2, @intFromFloat(panel.w), u.height() - TOOLBAR_H - 10);
        self.side_scroll.content = @floatFromInt(2 * 30 + @as(i32, @intCast(self.place_count)) * SIDE_ROW + 16);
        const old = u.beginScroll(area, &self.side_scroll);
        var y = area.y - @as(i32, @intFromFloat(self.side_scroll.offset));
        var section: u8 = 255;
        for (self.places[0..self.place_count], 0..) |p, i| {
            if (p.section != section) {
                section = p.section;
                if (section == 1) y += 8;
                u.text(Rect.init(area.x + 12, y, area.w - 24, 24), if (section == 0) "Favorites" else "Locations", .{ .size = 11, .weight = .semibold, .color = t.secondary_label });
                y += 24;
            }
            const r = Rect.init(area.x + 8, y, area.w - 16, SIDE_ROW);
            const id = ui.ui.hashIdx("place", i);
            const clicked = u.interact(id, r);
            const is_sel = std.mem.eql(u8, p.path, self.loc());
            if (is_sel) {
                u.fillRound(r, 8, if (t.dark) 0x2EFFFFFF else 0x17000000);
            } else if (u.hot == id) {
                u.fillRound(r, 8, t.hover);
            }
            if (self.cache.symbol(p.sym, 16, pm(t.accent))) |img| {
                u.canvas.drawImage(img, r.x + 9, r.y + @divTrunc(r.h - 16, 2), 255);
            }
            u.text(Rect.init(r.x + 34, r.y, r.w - 40, r.h), p.label, .{ .size = 13, .weight = if (is_sel) .medium else .regular, .color = t.label });
            if (clicked) self.navigate(u, p.path, true);
            y += SIDE_ROW;
        }
        u.popClip(old);
    }

    // ------------------------------------------------------------------
    // Toolbar
    // ------------------------------------------------------------------

    fn glassCapsule(u: *Ui, r: Rect) void {
        const t = u.theme;
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        u.shadow(r, radius, 8, 2, if (t.dark) 0x66000000 else 0x1E000000);
        u.fillRound(r, radius, if (t.dark) 0xFF2C2C2F else 0xFFFFFFFF);
        u.strokeRound(r, radius, 0.8, if (t.dark) 0x24FFFFFF else 0x12000000);
    }

    fn toolbarSegment(self: *App, u: *Ui, id_str: []const u8, r: Rect, sym: icons.Symbol, enabled: bool, on: bool) bool {
        const t = u.theme;
        const id = hashId(id_str);
        const clicked = enabled and u.interact(id, r);
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        if (on) {
            u.fillRound(r, radius, if (t.dark) 0x33FFFFFF else 0x17000000);
        } else if (enabled and u.isActive(id)) {
            u.fillRound(r, radius, if (t.dark) 0x29FFFFFF else 0x14000000);
        } else if (enabled and u.hot == id) {
            u.fillRound(r, radius, t.hover);
        }
        const col = if (enabled) t.label else t.tertiary_label;
        const s: i32 = if (sym == .chevron_left or sym == .chevron_right) 14 else 16;
        if (self.cache.symbol(sym, @intCast(s), pm(col))) |img| {
            u.canvas.drawImage(img, r.x + @divTrunc(r.w - s, 2), r.y + @divTrunc(r.h - s, 2), 255);
        }
        return clicked;
    }

    fn drawToolbar(self: *App, u: *Ui) void {
        const t = u.theme;
        const w = u.width();
        const x0 = SIDEBAR_W + 10;
        // Back / forward.
        const nav = Rect.init(x0, 10, 76, 32);
        glassCapsule(u, nav);
        if (self.toolbarSegment(u, "back", Rect.init(nav.x + 3, nav.y + 3, 34, 26), .chevron_left, self.back.items.len > 0, false)) self.goBack(u);
        if (self.toolbarSegment(u, "fwd", Rect.init(nav.x + 39, nav.y + 3, 34, 26), .chevron_right, self.fwd.items.len > 0, false)) self.goForward(u);

        // Search field and view switcher on the right.
        const search_w: i32 = if (w - SIDEBAR_W > 600) 200 else 150;
        const sr = Rect.init(w - 12 - search_w, 10, search_w, 32);
        const vs = Rect.init(sr.x - 10 - 80, 10, 80, 32);
        glassCapsule(u, vs);
        if (self.toolbarSegment(u, "view-icons", Rect.init(vs.x + 3, vs.y + 3, 36, 26), .grid, true, self.view == .icons)) self.setView(u, .icons);
        if (self.toolbarSegment(u, "view-list", Rect.init(vs.x + 41, vs.y + 3, 36, 26), .list, true, self.view == .list)) self.setView(u, .list);

        const search_id = hashId("search");
        const focused = u.focus == search_id and u.focused;
        if (focused) u.fillRound(Rect.init(sr.x - 3, sr.y - 3, sr.w + 6, sr.h + 6), 19, ui.ui.withAlpha(t.accent, 90));
        glassCapsule(u, sr);
        if (self.cache.symbol(.magnifier, 14, pm(t.secondary_label))) |img| u.canvas.drawImage(img, sr.x + 12, sr.y + 9, 255);
        const has_text = self.search.buf.items.len > 0;
        const field = Rect.init(sr.x + 22, sr.y + 2, sr.w - 22 - (if (has_text) @as(i32, 24) else 8), sr.h - 4);
        const res = u.textField("search", field, &self.search, .{ .placeholder = "Search", .plain = true });
        if (res.changed) {
            self.refilter();
            self.scroll = .{};
        }
        if (has_text) {
            const cr = Rect.init(sr.right() - 26, sr.y + 8, 16, 16);
            const cid = hashId("search-clear");
            u.fillCircle(@floatFromInt(cr.x + 8), @floatFromInt(cr.y + 8), 7, if (u.hot == cid) t.secondary_label else t.tertiary_label);
            const cx: f32 = @floatFromInt(cr.x + 8);
            const cy: f32 = @floatFromInt(cr.y + 8);
            u.line(cx - 2.5, cy - 2.5, cx + 2.5, cy + 2.5, 1.4, t.content_bg);
            u.line(cx + 2.5, cy - 2.5, cx - 2.5, cy + 2.5, 1.4, t.content_bg);
            if (u.interact(cid, cr)) {
                self.search.set(self.allocator, "");
                self.refilter();
            }
        }

        // Folder title.
        const title_x = nav.right() + 14;
        const title_w = vs.x - 12 - title_x;
        if (title_w > 20) u.text(Rect.init(title_x, 10, title_w, 32), fs.displayName(self.loc()), .{ .size = 15, .weight = .bold, .color = t.label });
    }

    fn drawAlert(self: *App, u: *Ui, top: i32) i32 {
        const t = u.theme;
        const r = Rect.init(SIDEBAR_W + 12, top + 2, u.width() - SIDEBAR_W - 24, 36);
        u.fillRound(r, 10, if (t.dark) 0xFF3A3122 else 0xFFFFF6E5);
        u.strokeRound(r, 10, 0.8, if (t.dark) 0x40FFB340 else 0x40E08A00);
        // Warning triangle.
        const cx: f32 = @floatFromInt(r.x + 20);
        const cy: f32 = @floatFromInt(r.y + 18);
        u.line(cx, cy - 7, cx - 8, cy + 6, 2.2, 0xFFFF9F0A);
        u.line(cx, cy - 7, cx + 8, cy + 6, 2.2, 0xFFFF9F0A);
        u.line(cx - 8, cy + 6, cx + 8, cy + 6, 2.2, 0xFFFF9F0A);
        u.line(cx, cy - 2, cx, cy + 1.5, 1.8, 0xFFFF9F0A);
        u.fillCircle(cx, cy + 4, 1, 0xFFFF9F0A);
        u.text(Rect.init(r.x + 38, r.y, r.w - 38 - 70, r.h), self.alert_buf[0..self.alert_len], .{ .size = 12, .color = t.label });
        if (u.button("alert-ok", Rect.init(r.right() - 62, r.y + 6, 52, 24), "OK", .{ .size = 12 })) {
            self.alert_len = 0;
            self.needs_redraw = true;
        }
        return r.bottom() + 4;
    }

    // ------------------------------------------------------------------
    // Icon view
    // ------------------------------------------------------------------

    fn layoutLabel(u: *Ui, e: *fs.Entry, max_w: f32) void {
        if (e.lab_ready) return;
        e.lab_ready = true;
        const f = u.face(.regular, LABEL_SIZE);
        const name = e.display;
        var lines = f.lines(name, max_w);
        const first = lines.next() orelse return;
        e.l1 = @intCast(@min(first.end, 65535));
        if (lines.next()) |second| {
            e.two_lines = true;
            const rest = name[second.start..];
            const tr = f.truncateLen(rest, max_w);
            e.l2 = @intCast(second.start);
            e.l2_len = @intCast(tr.len);
            e.l2_ellipsis = tr.ellipsis;
        } else {
            e.two_lines = false;
        }
    }

    fn cellRect(self: *App, area: Rect, pos: usize, cell_w: i32) Rect {
        const col: i32 = @intCast(@as(i32, @intCast(pos)) - @divTrunc(@as(i32, @intCast(pos)), self.cols) * self.cols);
        const row: i32 = @divTrunc(@as(i32, @intCast(pos)), self.cols);
        return Rect.init(area.x + GRID_PAD + col * cell_w, area.y + GRID_PAD + row * CELL_H - @as(i32, @intFromFloat(self.scroll.offset)), cell_w, CELL_H);
    }

    fn drawGrid(self: *App, u: *Ui, area: Rect) void {
        const t = u.theme;
        const inner_w = area.w - 2 * GRID_PAD;
        self.cols = @max(1, @divTrunc(inner_w, CELL_W));
        const cell_w = @divTrunc(inner_w, self.cols);
        const n = self.order.items.len;
        const rows: i32 = @intCast((n + @as(usize, @intCast(self.cols)) - 1) / @as(usize, @intCast(self.cols)));
        self.scroll.content = @floatFromInt(rows * CELL_H + 2 * GRID_PAD);
        self.scroll.view = @floatFromInt(area.h);
        if (self.ensure_visible) {
            self.ensure_visible = false;
            if (self.sel) |s| if (std.mem.indexOfScalar(u32, self.order.items, s)) |pos| {
                const row: i32 = @divTrunc(@as(i32, @intCast(pos)), self.cols);
                self.scroll.scrollTo(@floatFromInt(row * CELL_H), @floatFromInt(row * CELL_H + CELL_H + 2 * GRID_PAD));
            };
        }
        const old = u.beginScroll(area, &self.scroll);

        // Mouse: select / open.
        if (u.mouse_pressed and u.hovering(area)) {
            var hit: ?u32 = null;
            for (self.order.items, 0..) |idx, pos| {
                const cell = self.cellRect(area, pos, cell_w);
                if (!cell.contains(u.mouse_x, u.mouse_y)) continue;
                const icon_r = Rect.init(cell.x + @divTrunc(cell_w - @as(i32, ICON), 2) - 4, cell.y + 4, @as(i32, ICON) + 8, @as(i32, ICON) + 6);
                const lab_r = Rect.init(cell.x + 2, icon_r.bottom(), cell_w - 4, 2 * LABEL_LINE + 6);
                if (icon_r.contains(u.mouse_x, u.mouse_y) or lab_r.contains(u.mouse_x, u.mouse_y)) hit = idx;
                break;
            }
            const gen = self.generation;
            if (hit) |idx| {
                if (self.renaming and self.sel != idx) self.commitRenameThenSelect(u, idx);
                if (gen == self.generation) {
                    self.sel = idx;
                    if (u.click_count >= 2) self.openEntry(u, &self.listing.entries[idx]);
                }
            } else {
                self.sel = null;
            }
            if (gen != self.generation) {
                // The folder changed under us: draw it next frame.
                u.endScroll(area, &self.scroll, old);
                self.needs_redraw = true;
                return;
            }
        }

        const first_row: i32 = @max(0, @divTrunc(@as(i32, @intFromFloat(self.scroll.offset)) - GRID_PAD, CELL_H));
        const last_row: i32 = @divTrunc(@as(i32, @intFromFloat(self.scroll.offset)) + area.h, CELL_H) + 1;
        const start: usize = @intCast(@min(@as(i32, @intCast(n)), first_row * self.cols));
        const end: usize = @intCast(@min(@as(i32, @intCast(n)), (last_row + 1) * self.cols));
        const lab_face = u.face(.regular, LABEL_SIZE);
        const lab_w: f32 = @floatFromInt(CELL_W - 10);
        for (self.order.items[start..end], start..) |idx, pos| {
            const e = &self.listing.entries[idx];
            const cell = self.cellRect(area, pos, cell_w);
            const is_sel = self.sel == idx;
            const ix = cell.x + @divTrunc(cell_w - @as(i32, ICON), 2);
            const iy = cell.y + 6;
            if (is_sel) u.fillRound(Rect.init(ix - 5, iy - 5, @as(i32, ICON) + 10, @as(i32, ICON) + 10), 8, if (t.dark) 0x29FFFFFF else 0x14000000);
            if (self.cache.entry(e, ICON)) |img| u.canvas.drawImage(img, ix, iy, 255);

            // Label: up to two centered lines.
            const ly = iy + @as(i32, ICON) + 7;
            if (is_sel and self.renaming) {
                const fw: i32 = std.math.clamp(@as(i32, @intFromFloat(lab_face.measure(self.rename_field.text()))) + 22, 60, cell_w - 4);
                self.drawRenameField(u, Rect.init(cell.x + @divTrunc(cell_w - fw, 2), ly - 2, fw, 20));
                continue;
            }
            layoutLabel(u, e, lab_w);
            var l2buf: [300]u8 = undefined;
            const line1 = e.display[0..e.l1];
            var line2: []const u8 = "";
            if (e.two_lines) {
                const body = e.display[e.l2 .. e.l2 + e.l2_len];
                line2 = if (e.l2_ellipsis) (std.fmt.bufPrint(&l2buf, "{s}\u{2026}", .{body}) catch body) else body;
            }
            const fg = if (is_sel and u.focused) @as(u32, 0xFFFFFFFF) else t.label;
            if (is_sel) {
                const bg = if (u.focused) t.accent else (if (t.dark) @as(u32, 0xFF4A4A4E) else 0xFFD8D8DC);
                const w1: i32 = @intFromFloat(@ceil(lab_face.measure(line1)));
                u.fillRound(Rect.init(cell.x + @divTrunc(cell_w - w1, 2) - 5, ly - 1, w1 + 10, LABEL_LINE + 2), 4, bg);
                if (line2.len > 0) {
                    const w2: i32 = @intFromFloat(@ceil(lab_face.measure(line2)));
                    u.fillRound(Rect.init(cell.x + @divTrunc(cell_w - w2, 2) - 5, ly + LABEL_LINE - 1, w2 + 10, LABEL_LINE + 2), 4, bg);
                }
            }
            u.text(Rect.init(cell.x + 2, ly, cell_w - 4, LABEL_LINE), line1, .{ .size = LABEL_SIZE, .color = fg, .@"align" = .center, .truncate = false });
            if (line2.len > 0) u.text(Rect.init(cell.x + 2, ly + LABEL_LINE, cell_w - 4, LABEL_LINE), line2, .{ .size = LABEL_SIZE, .color = fg, .@"align" = .center, .truncate = false });
        }
        scrollEdge(u, area, self.scroll.offset);
        u.endScroll(area, &self.scroll, old);
        if (n == 0) self.drawEmpty(u, area);
    }

    /// Scroll-edge effect: content fades out under the toolbar / header.
    fn scrollEdge(u: *Ui, area: Rect, offset: f32) void {
        if (offset <= 0) return;
        const bg = u.theme.content_bg;
        const g = gfx.Paint.verticalGradient(gfx.RectF.init(@floatFromInt(area.x), @floatFromInt(area.y), @floatFromInt(area.w), 16), &.{
            .{ .pos = 0, .color = pm(bg) },
            .{ .pos = 1, .color = pm(bg & 0x00FFFFFF) },
        });
        u.canvas.fillRect(Rect.init(area.x, area.y, area.w - 12, 16), &g);
    }

    fn drawRenameField(self: *App, u: *Ui, r: Rect) void {
        const res = u.textField("rename", r, &self.rename_field, .{ .size = LABEL_SIZE });
        if (res.submitted) {
            self.commitRename(u);
            u.focus = 0;
        }
    }

    fn drawEmpty(self: *App, u: *Ui, area: Rect) void {
        if (self.search.buf.items.len > 0) {
            u.text(Rect.init(area.x, area.y + @divTrunc(area.h, 2) - 12, area.w, 24), "No Results", .{ .size = 15, .weight = .semibold, .color = u.theme.tertiary_label, .@"align" = .center });
        }
    }

    fn drawError(self: *App, u: *Ui, area: Rect, err: anyerror) void {
        const t = u.theme;
        const cy = area.y + @divTrunc(area.h, 2);
        if (self.cache.symbol(if (err == error.AccessDenied or err == error.PermissionDenied) .lock else .folder, 40, pm(t.tertiary_label))) |img| {
            u.canvas.drawImage(img, area.x + @divTrunc(area.w - 40, 2), cy - 64, 255);
        }
        var buf: [300]u8 = undefined;
        const msg = switch (err) {
            error.AccessDenied, error.PermissionDenied => std.fmt.bufPrint(&buf, "You don\u{2019}t have permission to see the contents of \u{201C}{s}\u{201D}.", .{fs.displayName(self.loc())}),
            error.FileNotFound => std.fmt.bufPrint(&buf, "The folder \u{201C}{s}\u{201D} can\u{2019}t be found.", .{fs.displayName(self.loc())}),
            error.NotDir => std.fmt.bufPrint(&buf, "\u{201C}{s}\u{201D} is not a folder.", .{fs.displayName(self.loc())}),
            else => std.fmt.bufPrint(&buf, "The folder \u{201C}{s}\u{201D} can\u{2019}t be opened ({s}).", .{ fs.displayName(self.loc()), @errorName(err) }),
        } catch "The folder can\u{2019}t be opened.";
        u.text(Rect.init(area.x + 20, cy - 12, area.w - 40, 24), msg, .{ .size = 13, .weight = .medium, .color = t.secondary_label, .@"align" = .center });
    }

    // ------------------------------------------------------------------
    // List view
    // ------------------------------------------------------------------

    const Columns = struct { name_x: i32, name_w: i32, date_x: i32, date_w: i32, size_x: i32, size_w: i32, kind_x: i32, kind_w: i32 };

    fn columns(area: Rect) Columns {
        const x0 = area.x + 16;
        const right = area.right() - 16;
        var kind_w: i32 = 150;
        var date_w: i32 = 190;
        const size_w: i32 = 84;
        var avail = right - x0;
        if (avail - kind_w - date_w - size_w < 180) kind_w = @max(0, avail - date_w - size_w - 180);
        if (kind_w < 80) {
            kind_w = 0;
            if (avail - date_w - size_w < 180) date_w = @max(120, avail - size_w - 180);
        }
        avail = right - x0;
        const name_w = avail - kind_w - date_w - size_w;
        return .{
            .name_x = x0,
            .name_w = name_w,
            .date_x = x0 + name_w,
            .date_w = date_w,
            .size_x = x0 + name_w + date_w,
            .size_w = size_w,
            .kind_x = x0 + name_w + date_w + size_w,
            .kind_w = kind_w,
        };
    }

    fn headerCell(self: *App, u: *Ui, id_str: []const u8, r: Rect, label: []const u8, key: fs.SortKey, al: ui.ui.Align) void {
        if (r.w <= 0) return;
        const t = u.theme;
        const id = hashId(id_str);
        if (u.interact(id, r)) self.setSort(u, key, true);
        if (u.hot == id) u.fillRound(r.inset(-4, 3), 6, t.hover);
        const active = self.sort_key == key;
        const text_r = Rect.init(r.x + 4, r.y, r.w - 22, r.h);
        u.text(text_r, label, .{ .size = 12, .weight = if (active) .semibold else .medium, .color = if (active) t.label else t.secondary_label, .@"align" = al });
        if (active) {
            // Sort direction chevron.
            const tw: i32 = @intFromFloat(u.measure(label, .semibold, 12));
            const cx: f32 = @floatFromInt(if (al == .right) r.right() - 10 else @min(r.x + 4 + tw + 10, r.right() - 10));
            const cy: f32 = @floatFromInt(r.y + @divTrunc(r.h, 2));
            const d: f32 = if (self.sort_asc) -1 else 1;
            u.line(cx - 3.5, cy - 1.5 * d, cx, cy + 1.5 * d, 1.5, t.secondary_label);
            u.line(cx, cy + 1.5 * d, cx + 3.5, cy - 1.5 * d, 1.5, t.secondary_label);
        }
    }

    fn drawList(self: *App, u: *Ui, area: Rect) void {
        const t = u.theme;
        const cols = columns(area);
        // Header.
        const hy = area.y;
        self.headerCell(u, "h-name", Rect.init(cols.name_x, hy, cols.name_w - 8, HEADER_H), "Name", .name, .left);
        self.headerCell(u, "h-date", Rect.init(cols.date_x, hy, cols.date_w - 8, HEADER_H), "Date Modified", .date, .left);
        self.headerCell(u, "h-size", Rect.init(cols.size_x, hy, cols.size_w - 8, HEADER_H), "Size", .size, .right);
        self.headerCell(u, "h-kind", Rect.init(cols.kind_x, hy, cols.kind_w - 4, HEADER_H), "Kind", .kind, .left);
        u.hline(area.x + 12, area.right() - 12, hy + HEADER_H - 1, t.separator);

        const body = Rect.init(area.x, hy + HEADER_H, area.w, area.h - HEADER_H);
        const n = self.order.items.len;
        self.scroll.content = @floatFromInt(@as(i32, @intCast(n)) * ROW_H + 12);
        self.scroll.view = @floatFromInt(body.h);
        if (self.ensure_visible) {
            self.ensure_visible = false;
            if (self.sel) |s| if (std.mem.indexOfScalar(u32, self.order.items, s)) |pos| {
                const top: f32 = @floatFromInt(@as(i32, @intCast(pos)) * ROW_H);
                self.scroll.scrollTo(top, top + @as(f32, ROW_H) + 12);
            };
        }
        const old = u.beginScroll(body, &self.scroll);
        const off: i32 = @intFromFloat(self.scroll.offset);
        const y0 = body.y + 6 - off;

        if (u.mouse_pressed and u.hovering(body)) {
            const rel = u.mouse_y - y0;
            const row = if (rel >= 0) @divTrunc(rel, ROW_H) else -1;
            const gen = self.generation;
            if (row >= 0 and row < @as(i32, @intCast(n))) {
                const idx = self.order.items[@intCast(row)];
                if (self.renaming and self.sel != idx) self.commitRenameThenSelect(u, idx);
                if (gen == self.generation) {
                    self.sel = idx;
                    if (u.click_count >= 2) self.openEntry(u, &self.listing.entries[idx]);
                }
            } else self.sel = null;
            if (gen != self.generation) {
                u.endScroll(body, &self.scroll, old);
                self.needs_redraw = true;
                return;
            }
        }

        const first: usize = @intCast(std.math.clamp(@divTrunc(off - 6, ROW_H), 0, @as(i32, @intCast(n))));
        const last: usize = @intCast(std.math.clamp(@divTrunc(off + body.h, ROW_H) + 2, 0, @as(i32, @intCast(n))));
        var sbuf: [64]u8 = undefined;
        var dbuf: [64]u8 = undefined;
        // Alternating stripes fill the visible area even below the last row.
        var stripe: usize = first;
        while (true) : (stripe += 1) {
            const ry = y0 + @as(i32, @intCast(stripe)) * ROW_H;
            if (ry > body.bottom()) break;
            if (stripe % 2 == 1) u.fillRound(Rect.init(area.x + 8, ry, area.w - 16, ROW_H), 6, t.alternate_row);
        }
        for (self.order.items[first..last], first..) |idx, row| {
            const e = &self.listing.entries[idx];
            const ry = y0 + @as(i32, @intCast(row)) * ROW_H;
            const rr = Rect.init(area.x + 8, ry, area.w - 16, ROW_H);
            const is_sel = self.sel == idx;
            if (is_sel) u.fillRound(rr, 6, if (u.focused) t.accent else (if (t.dark) @as(u32, 0xFF46464A) else 0xFFDCDCE0));
            const fg = if (is_sel and u.focused) @as(u32, 0xFFFFFFFF) else t.label;
            const fg2 = if (is_sel and u.focused) @as(u32, 0xE6FFFFFF) else t.secondary_label;
            if (self.cache.entry(e, 18)) |img| u.canvas.drawImage(img, cols.name_x, ry + 3, 255);
            if (is_sel and self.renaming) {
                self.drawRenameField(u, Rect.init(cols.name_x + 22, ry + 1, cols.name_w - 30, ROW_H - 2));
            } else {
                u.text(Rect.init(cols.name_x + 24, ry, cols.name_w - 32, ROW_H), e.display, .{ .size = 13, .color = fg });
            }
            u.text(Rect.init(cols.date_x + 4, ry, cols.date_w - 12, ROW_H), fs.formatDate(&dbuf, e.mtime, self.now), .{ .size = 12, .color = fg2 });
            const size_s = if (e.kind == .folder or e.kind == .app) "--" else fs.formatSize(&sbuf, e.size);
            u.text(Rect.init(cols.size_x, ry, cols.size_w - 12, ROW_H), size_s, .{ .size = 12, .color = fg2, .@"align" = .right });
            if (cols.kind_w > 0) u.text(Rect.init(cols.kind_x + 4, ry, cols.kind_w - 8, ROW_H), e.kind_label, .{ .size = 12, .color = fg2 });
        }
        scrollEdge(u, body, self.scroll.offset);
        u.endScroll(body, &self.scroll, old);
        if (n == 0) self.drawEmpty(u, body);
    }

    // ------------------------------------------------------------------
    // Status bar
    // ------------------------------------------------------------------

    fn drawStatus(self: *App, u: *Ui) void {
        const t = u.theme;
        const r = Rect.init(SIDEBAR_W, u.height() - STATUS_H, u.width() - SIDEBAR_W, STATUS_H);
        u.hline(r.x, r.right(), r.y, t.separator);
        var buf: [160]u8 = undefined;
        var fb: [32]u8 = undefined;
        const n = self.order.items.len;
        const noun = if (n == 1) "item" else "items";
        const free_s: ?[]const u8 = if (self.free) |f| blk: {
            const gb = @as(f64, @floatFromInt(f)) / 1e9;
            break :blk if (gb >= 10) (std.fmt.bufPrint(&fb, "{d:.0} GB", .{gb}) catch "") else if (gb >= 1) (std.fmt.bufPrint(&fb, "{d:.1} GB", .{gb}) catch "") else fs.formatSize(&fb, f);
        } else null;
        const s = if (self.sel != null)
            (if (free_s) |fs_| std.fmt.bufPrint(&buf, "1 of {d} selected, {s} available", .{ n, fs_ }) else std.fmt.bufPrint(&buf, "1 of {d} selected", .{n}))
        else if (free_s) |fs_|
            std.fmt.bufPrint(&buf, "{d} {s}, {s} available", .{ n, noun, fs_ })
        else
            std.fmt.bufPrint(&buf, "{d} {s}", .{ n, noun });
        u.text(r, s catch "", .{ .size = 11, .weight = .medium, .color = t.secondary_label, .@"align" = .center });
    }

    // ------------------------------------------------------------------
    // Sheets
    // ------------------------------------------------------------------

    fn sheetPanel(u: *Ui, r: Rect) void {
        const t = u.theme;
        u.fillRect(Rect.init(0, 0, u.width(), u.height()), if (t.dark) 0x33000000 else 0x14000000);
        u.shadow(r, 16, 22, 10, if (t.dark) 0x99000000 else 0x40000000);
        u.fillRound(r, 16, if (t.dark) 0xFF2B2B2E else 0xFFFBFBFD);
        u.strokeRound(r, 16, 0.8, if (t.dark) 0x30FFFFFF else 0x1A000000);
    }

    fn drawGotoSheet(self: *App, u: *Ui) void {
        const t = u.theme;
        const w: i32 = 440;
        const h: i32 = 168;
        const x = @max(10, @min(SIDEBAR_W + @divTrunc(u.width() - SIDEBAR_W - w, 2), u.width() - w - 10));
        const r = Rect.init(x, 40, w, h);
        sheetPanel(u, r);
        u.text(Rect.init(r.x + 20, r.y + 16, r.w - 40, 20), "Go to Folder", .{ .size = 13, .weight = .bold, .color = t.label });
        const res = u.textField("goto", Rect.init(r.x + 20, r.y + 46, r.w - 40, 28), &self.goto_field, .{ .placeholder = "Path or URL" });
        if (res.changed) self.goto_error = false;
        const hint = if (self.goto_error) "The folder can\u{2019}t be found." else "A path such as /etc or ~/Documents, or a URL such as sys:proc.";
        u.text(Rect.init(r.x + 22, r.y + 80, r.w - 44, 18), hint, .{ .size = 11, .color = if (self.goto_error) @as(u32, 0xFFFF453A) else t.secondary_label });
        const by = r.bottom() - 46;
        const go = u.button("goto-go", Rect.init(r.right() - 20 - 90, by, 90, 28), "Go", .{ .style = .primary });
        const cancel = u.button("goto-cancel", Rect.init(r.right() - 20 - 90 - 10 - 90, by, 90, 28), "Cancel", .{});
        if (cancel) {
            self.sheet = .none;
            u.focus = 0;
            self.needs_redraw = true;
        } else if (go or res.submitted) {
            self.submitGoto(u);
            self.needs_redraw = true;
        }
    }

    fn drawInfo(self: *App, u: *Ui) void {
        const t = u.theme;
        const w: i32 = 320;
        const h: i32 = @min(382, u.height() - 20);
        const x = @max(10, @min(SIDEBAR_W + @divTrunc(u.width() - SIDEBAR_W - w, 2), u.width() - w - 10));
        const r = Rect.init(x, @max(10, @divTrunc(u.height() - h, 2)), w, h);
        sheetPanel(u, r);
        var name: []const u8 = fs.displayName(self.loc());
        var kind: []const u8 = "Folder";
        var size_s: []const u8 = "--";
        var mode: u32 = 0;
        var mtime: i64 = 0;
        var is_link = false;
        var ekind: fs.Kind = .folder;
        var sb: [64]u8 = undefined;
        var where_buf: [fs.max_path]u8 = undefined;
        var where: []const u8 = fs.parent(self.loc()) orelse "--";
        const entry = self.selected();
        if (entry) |e| {
            name = e.display;
            kind = e.kind_label;
            mode = e.mode;
            mtime = e.mtime;
            is_link = e.is_link;
            ekind = e.kind;
            if (e.kind != .folder) size_s = fs.formatBytesLong(&sb, e.size);
            where = std.fmt.bufPrint(&where_buf, "{s}", .{self.loc()}) catch self.loc();
        } else if (fs.statPath(self.loc())) |st| {
            mode = st.mode;
            mtime = @intCast(st.mtime().sec);
        }
        // Icon + name.
        const icon_y = r.y + 22;
        if (entry) |e| {
            if (self.cache.entry(e, ICON)) |img| u.canvas.drawImage(img, r.x + 20, icon_y, 255);
        } else if (self.cache.get(.{ .cat = if (fs.isUrl(self.loc())) .sys_folder else .folder }, ICON, "", false)) |img| {
            u.canvas.drawImage(img, r.x + 20, icon_y, 255);
        }
        u.text(Rect.init(r.x + 96, icon_y + 10, r.w - 112, 22), name, .{ .size = 15, .weight = .bold, .color = t.label });
        u.text(Rect.init(r.x + 96, icon_y + 34, r.w - 112, 18), kind, .{ .size = 12, .color = t.secondary_label });
        u.hline(r.x + 20, r.right() - 20, icon_y + ICON + 14, t.separator);

        var pbuf: [10]u8 = undefined;
        var dbuf: [64]u8 = undefined;
        const rows = [_]struct { []const u8, []const u8 }{
            .{ "Kind:", kind },
            .{ "Size:", size_s },
            .{ "Where:", where },
            .{ "Modified:", fs.formatDate(&dbuf, mtime, self.now) },
            .{ "Permissions:", fs.permString(&pbuf, mode, ekind, is_link) },
            .{ "Owner:", self.info.owner[0..self.info.owner_len] },
            .{ "Group:", self.info.group[0..self.info.group_len] },
        };
        var y = icon_y + @as(i32, ICON) + 26;
        // Tighten the rows when the window is short.
        const room = r.bottom() - 56 - y;
        const row_h: i32 = std.math.clamp(@divTrunc(room, @as(i32, rows.len)), 17, 26);
        for (rows) |row| {
            u.text(Rect.init(r.x + 16, y, 96, 22), row[0], .{ .size = 12, .weight = .medium, .color = t.secondary_label, .@"align" = .right });
            const mono = std.mem.eql(u8, row[0], "Permissions:");
            if (mono) {
                u.text(Rect.init(r.x + 120, y, r.w - 136, 22), row[1], .{ .size = 12, .weight = .mono, .color = t.label });
            } else {
                u.text(Rect.init(r.x + 120, y, r.w - 136, 22), row[1], .{ .size = 12, .color = t.label });
            }
            y += row_h;
        }
        if (u.button("info-done", Rect.init(r.right() - 20 - 90, r.bottom() - 46, 90, 28), "Done", .{ .style = .primary })) {
            self.sheet = .none;
            self.needs_redraw = true;
        }
    }
};
