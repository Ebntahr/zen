//! Settings — Zen OS System Settings in the macOS 26 style.
//!
//! Layout: a translucent, inset "Liquid Glass" sidebar (search field, user
//! card, colored pane icons) with the traffic lights floating over it, and
//! an opaque content area with a toolbar (back/forward + pane title) and
//! grouped, rounded form panels that scroll under the toolbar.
//!
//! Settings are applied through text commands to `window:control`
//! (appearance, accent, wallpaper, transparency, clock) and privileged
//! helpers (`sudo -S`, `passwd --stdin`). Preferences the window server does
//! not report back are kept in ~/Library/Preferences/com.zen.Settings.conf.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const icons = @import("icons");
const abi = @import("abi");
const zen = @import("zen");
const w = @import("widgets.zig");
const sys = @import("system.zig");
const general = @import("panes/general.zig");
const look = @import("panes/look.zig");
const accounts = @import("panes/users.zig");
const privacy = @import("panes/privacy.zig");
const other = @import("panes/other.zig");

const Ui = ui.Ui;
const Rect = ui.Rect;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const pm = ui.pm;
const hashId = ui.ui.hashId;

pub const sidebar_w: i32 = 232;
pub const toolbar_h: i32 = 52;

// ---------------------------------------------------------------------------
// Panes
// ---------------------------------------------------------------------------

pub const Pane = enum { general, appearance, wallpaper, displays, keyboard, users, privacy, lock_screen, storage, developer };
pub const Sub = enum { none, about, software_update, date_time, language, sharing };

pub const PaneInfo = struct {
    pane: Pane,
    title: []const u8,
    glyph: w.TileGlyph,
    color: u32,
    keywords: []const u8,
    section: u8,
};

pub const pane_list = [_]PaneInfo{
    .{ .pane = .general, .title = "General", .glyph = .{ .sym = .gear }, .color = w.tint.gray, .keywords = "about software update date time clock language region sharing computer name hostname version", .section = 0 },
    .{ .pane = .appearance, .title = "Appearance", .glyph = .appearance, .color = 0xFF1C1C1E, .keywords = "dark light mode auto accent color transparency theme", .section = 0 },
    .{ .pane = .wallpaper, .title = "Wallpaper", .glyph = .{ .sym = .photo }, .color = w.tint.cyan, .keywords = "background desktop picture tahoe golden gate aurora", .section = 0 },
    .{ .pane = .displays, .title = "Displays", .glyph = .sun, .color = w.tint.blue, .keywords = "resolution night shift brightness monitor screen", .section = 0 },
    .{ .pane = .keyboard, .title = "Keyboard", .glyph = .{ .sym = .keyboard }, .color = w.tint.gray, .keywords = "input sources arabic layout key repeat shortcuts", .section = 1 },
    .{ .pane = .users, .title = "Users & Groups", .glyph = .{ .sym = .user_group }, .color = w.tint.blue, .keywords = "accounts password admin add user login", .section = 1 },
    .{ .pane = .privacy, .title = "Privacy & Security", .glyph = .{ .sym = .hand }, .color = w.tint.blue, .keywords = "sandbox gatekeeper signature signed entitlements apps security", .section = 1 },
    .{ .pane = .lock_screen, .title = "Lock Screen", .glyph = .{ .sym = .lock }, .color = 0xFF1C1C1E, .keywords = "password sleep screen saver login window user list", .section = 1 },
    .{ .pane = .storage, .title = "Storage", .glyph = .{ .sym = .disk }, .color = w.tint.gray, .keywords = "disk capacity space free used", .section = 2 },
    .{ .pane = .developer, .title = "Developer", .glyph = .{ .sym = .terminal }, .color = 0xFF3A3A3C, .keywords = "c c++ compiler zig toolchain sdk cc clang gcc", .section = 2 },
};

pub fn paneInfo(p: Pane) PaneInfo {
    return pane_list[@intFromEnum(p)];
}

pub fn subTitle(s: Sub) []const u8 {
    return switch (s) {
        .none => "",
        .about => "About",
        .software_update => "Software Update",
        .date_time => "Date & Time",
        .language => "Language & Region",
        .sharing => "Sharing",
    };
}

pub const Loc = struct { pane: Pane, sub: Sub = .none };

/// Pane names accepted on the command line (`Settings about`).
fn parseLoc(arg_in: []const u8) ?Loc {
    var arg = arg_in;
    if (std.mem.indexOfScalar(u8, arg, ':')) |c| arg = arg[c + 1 ..];
    const table = [_]struct { []const u8, Loc }{
        .{ "general", .{ .pane = .general } },
        .{ "about", .{ .pane = .general, .sub = .about } },
        .{ "software-update", .{ .pane = .general, .sub = .software_update } },
        .{ "softwareupdate", .{ .pane = .general, .sub = .software_update } },
        .{ "update", .{ .pane = .general, .sub = .software_update } },
        .{ "datetime", .{ .pane = .general, .sub = .date_time } },
        .{ "date-time", .{ .pane = .general, .sub = .date_time } },
        .{ "date", .{ .pane = .general, .sub = .date_time } },
        .{ "language", .{ .pane = .general, .sub = .language } },
        .{ "region", .{ .pane = .general, .sub = .language } },
        .{ "sharing", .{ .pane = .general, .sub = .sharing } },
        .{ "appearance", .{ .pane = .appearance } },
        .{ "wallpaper", .{ .pane = .wallpaper } },
        .{ "displays", .{ .pane = .displays } },
        .{ "display", .{ .pane = .displays } },
        .{ "keyboard", .{ .pane = .keyboard } },
        .{ "users", .{ .pane = .users } },
        .{ "accounts", .{ .pane = .users } },
        .{ "privacy", .{ .pane = .privacy } },
        .{ "security", .{ .pane = .privacy } },
        .{ "lock", .{ .pane = .lock_screen } },
        .{ "lockscreen", .{ .pane = .lock_screen } },
        .{ "lock-screen", .{ .pane = .lock_screen } },
        .{ "storage", .{ .pane = .storage } },
        .{ "developer", .{ .pane = .developer } },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], arg)) return e[1];
    return null;
}

// ---------------------------------------------------------------------------
// Preferences (things the window server does not report back)
// ---------------------------------------------------------------------------

pub const AppearanceMode = enum { auto, light, dark };

pub const Prefs = struct {
    appearance: AppearanceMode = .light,
    wallpaper: u8 = 2,
    reduce_transparency: bool = false,
    clock24: bool = true,
    tz: usize = 6, // UTC (index into general.zones)
    auto_time: bool = true,
    auto_update: bool = true,
    language: usize = 0,
    region: usize = 0,
    temperature: usize = 0,
    scroll_bars: usize = 0,
    night_shift: bool = false,
    night_schedule: usize = 0,
    warmth: f32 = 0.5,
    brightness: f32 = 0.75,
    auto_brightness: bool = true,
    resolution: usize = 1,
    refresh_rate: usize = 0,
    key_repeat: f32 = 0.7,
    key_delay: f32 = 0.55,
    input_switch: usize = 0,
    arabic_input: bool = true,
    keyboard_nav: bool = false,
    screen_saver: usize = 2,
    display_off: usize = 3,
    require_password: usize = 0,
    large_clock: usize = 1,
    show_user_list: bool = true,
    show_power_buttons: bool = true,
    lock_message: bool = false,
    file_sharing: bool = false,
    remote_login: bool = false,

    fn path(buf: []u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/Library/Preferences/com.zen.Settings.conf", .{home}) catch null;
    }

    pub fn load(self: *Prefs) void {
        var pbuf: [512]u8 = undefined;
        const p = path(&pbuf) orelse return;
        var buf: [4096]u8 = undefined;
        const data = sys.readSmall(p, &buf) orelse return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            inline for (std.meta.fields(Prefs)) |fld| {
                if (std.mem.eql(u8, key, fld.name)) {
                    const ptr = &@field(self, fld.name);
                    switch (fld.type) {
                        bool => ptr.* = std.mem.eql(u8, val, "on"),
                        u8, usize => ptr.* = std.fmt.parseInt(fld.type, val, 10) catch ptr.*,
                        f32 => ptr.* = std.math.clamp(std.fmt.parseFloat(f32, val) catch ptr.*, 0, 1),
                        AppearanceMode => ptr.* = std.meta.stringToEnum(AppearanceMode, val) orelse ptr.*,
                        else => {},
                    }
                }
            }
        }
    }

    pub fn save(self: *const Prefs) void {
        var pbuf: [512]u8 = undefined;
        const p = path(&pbuf) orelse return;
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const wr = fbs.writer();
        wr.writeAll("# Zen OS Settings preferences\n") catch return;
        inline for (std.meta.fields(Prefs)) |fld| {
            const v = @field(self, fld.name);
            switch (fld.type) {
                bool => wr.print("{s} = {s}\n", .{ fld.name, if (v) "on" else "off" }) catch return,
                u8, usize => wr.print("{s} = {d}\n", .{ fld.name, v }) catch return,
                f32 => wr.print("{s} = {d:.3}\n", .{ fld.name, v }) catch return,
                AppearanceMode => wr.print("{s} = {s}\n", .{ fld.name, @tagName(v) }) catch return,
                else => {},
            }
        }
        if (std.fs.path.dirname(p)) |dir| std.fs.cwd().makePath(dir) catch {};
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = fbs.getWritten() }) catch {};
    }
};

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

pub const Popup = struct {
    open: bool = false,
    id: ui.ui.Id = 0,
    items: []const []const u8 = &.{},
    target: *usize = undefined,
    rect: Rect = .{},
    hover: ?usize = null,
    changed_id: ui.ui.Id = 0,

    const item_h: i32 = 22;
};

pub const SheetKind = enum { none, add_user, change_password, hostname, about_app };

pub const Job = enum { none, add_user, change_password, set_hostname, storage_scan };

pub const MenuId = struct {
    pub const about: u32 = 1;
    pub const quit: u32 = 2;
    pub const cut: u32 = 10;
    pub const copy: u32 = 11;
    pub const paste: u32 = 12;
    pub const select_all: u32 = 13;
    pub const back: u32 = 20;
    pub const forward: u32 = 21;
    pub const find: u32 = 22;
    pub const pane: u32 = 100;
};

/// Requested state for host previews (see preview.zig).
pub const PreviewTarget = struct {
    pane: Pane,
    sub: Sub = .none,
    sheet: SheetKind = .none,
    /// Scroll the content this far down (applied once its height is known).
    scroll: f32 = 0,
};
pub var preview_target: ?PreviewTarget = null;

// ---------------------------------------------------------------------------
// The app
// ---------------------------------------------------------------------------

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Settings",
        .width = 780,
        .height = 560,
        .min_width = 740,
        .min_height = 440,
        .flags = abi.window.Flags.full_size_content | abi.window.Flags.resizable | abi.window.Flags.transparent,
    };

    allocator: std.mem.Allocator,
    loc: Loc = .{ .pane = .general },
    history: [32]Loc = undefined,
    hist_len: usize = 1,
    hist_pos: usize = 0,
    scroll: ui.ScrollState = .{},
    side_scroll: ui.ScrollState = .{},
    search: ui.TextState = .{},
    icons: w.IconCache,
    prefs: Prefs = .{},
    headless: bool = false,
    menu_dirty: bool = false,

    // Identity.
    uid: u32 = 0,
    user_name_buf: [64]u8 = undefined,
    user_name: []const u8 = "",
    full_name_buf: [128]u8 = undefined,
    full_name: []const u8 = "",
    hostname_buf: [64]u8 = undefined,
    hostname: []const u8 = "",

    // Overlays and modal state.
    popup: Popup = .{},
    sheet: SheetKind = .none,
    fields: [6]ui.TextState = [_]ui.TextState{.{}} ** 6,
    sheet_admin: bool = false,
    account_edited: bool = false,
    sheet_error_buf: [200]u8 = undefined,
    sheet_error: []const u8 = "",
    job: Job = .none,
    last_auto: ?bool = null,
    edit_target: ?*ui.TextState = null,
    edit_secure: bool = false,
    notice_buf: [160]u8 = undefined,
    notice: []const u8 = "",
    pending_scroll: f32 = 0,

    // Pane data.
    about: general.AboutData = .{},
    update_checked: bool = false,
    thumbs: look.Thumbs = .{},
    users: accounts.UsersData = .{},
    apps: privacy.PrivacyData = .{},
    storage: other.StorageData = .{},
    dev: other.DevData = .{},

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        var self = App{ .allocator = allocator, .icons = w.IconCache.init(allocator) };
        self.headless = u.win.headless;
        self.history[0] = self.loc;
        if (!self.headless) self.prefs.load();
        self.loadIdentity();
        self.hostname = sys.hostname(&self.hostname_buf);
        // Title bar area for the floating traffic lights / window dragging.
        u.win.setTitleHeight(toolbar_h);
        // `Settings <pane>` (launchd passes extra arguments).
        var it = std.process.args();
        _ = it.next();
        while (it.next()) |arg| {
            if (parseLoc(arg)) |l| {
                self.loc = l;
                self.history[0] = l;
            }
        }
        return self;
    }

    pub fn deinit(self: *App) void {
        self.icons.deinit();
        self.search.deinit(self.allocator);
        for (&self.fields) |*f| f.deinit(self.allocator);
        self.thumbs.deinit(self.allocator);
        self.about.deinit(self.allocator);
        self.users.deinit(self.allocator);
        self.apps.deinit(self.allocator);
    }

    fn loadIdentity(self: *App) void {
        self.uid = std.os.linux.getuid();
        var db = zen.users.Db.load(self.allocator, "/") catch {
            self.user_name = sys.copyInto(&self.user_name_buf, "zen");
            self.full_name = sys.copyInto(&self.full_name_buf, "Zen User");
            return;
        };
        defer db.deinit();
        if (db.userById(self.uid)) |me| {
            self.user_name = sys.copyInto(&self.user_name_buf, me.name);
            const full = if (me.gecos.len > 0) blk: {
                // GECOS may carry extra comma-separated fields.
                const c = std.mem.indexOfScalar(u8, me.gecos, ',') orelse me.gecos.len;
                break :blk me.gecos[0..c];
            } else me.name;
            self.full_name = sys.copyInto(&self.full_name_buf, full);
        } else {
            self.user_name = sys.copyInto(&self.user_name_buf, "zen");
            self.full_name = sys.copyInto(&self.full_name_buf, "Zen User");
        }
    }

    pub fn setIdentity(self: *App, name: []const u8, full: []const u8, uid: u32) void {
        self.user_name = sys.copyInto(&self.user_name_buf, name);
        self.full_name = sys.copyInto(&self.full_name_buf, full);
        self.uid = uid;
    }

    pub fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.notice = std.fmt.bufPrint(&self.notice_buf, fmt, args) catch "";
    }

    pub fn setSheetError(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.sheet_error = std.fmt.bufPrint(&self.sheet_error_buf, fmt, args) catch "Error";
    }

    /// Persist preferences (not in host previews).
    pub fn savePrefs(self: *App) void {
        if (!self.headless) self.prefs.save();
    }

    // ------------------------------------------------------------------
    // Navigation
    // ------------------------------------------------------------------

    pub fn go(self: *App, loc: Loc) void {
        if (self.loc.pane == loc.pane and self.loc.sub == loc.sub) return;
        self.popup.open = false;
        self.hist_pos = @min(self.hist_pos + 1, self.history.len - 1);
        self.history[self.hist_pos] = loc;
        self.hist_len = self.hist_pos + 1;
        self.loc = loc;
        self.scroll.offset = 0;
        self.notice = "";
        self.menu_dirty = true;
    }

    pub fn back(self: *App) void {
        if (self.hist_pos == 0) return;
        self.hist_pos -= 1;
        self.loc = self.history[self.hist_pos];
        self.scroll.offset = 0;
        self.menu_dirty = true;
    }

    pub fn forward(self: *App) void {
        if (self.hist_pos + 1 >= self.hist_len) return;
        self.hist_pos += 1;
        self.loc = self.history[self.hist_pos];
        self.scroll.offset = 0;
        self.menu_dirty = true;
    }

    // ------------------------------------------------------------------
    // Theme helpers
    // ------------------------------------------------------------------

    pub fn accentIndex(u: *const Ui) usize {
        for (0..8) |i| {
            const a: ui.theme.Accent = @enumFromInt(i);
            if (a.color(u.theme.dark) == u.theme.accent) return i;
        }
        return 0;
    }

    /// Apply dark/light immediately to this window and tell the server.
    pub fn applyDark(self: *App, u: *Ui, dark: bool) void {
        _ = self;
        const acc: ui.theme.Accent = @enumFromInt(accentIndex(u));
        u.setDark(dark, acc.color(dark));
        _ = sys.controlf("appearance {s}", .{if (dark) "dark" else "light"});
    }

    // ------------------------------------------------------------------
    // Menus
    // ------------------------------------------------------------------

    pub fn menu(self: *App, m: *abi.window.MenuWriter) void {
        const checked = abi.window.MenuItemFlags.checked;
        const disabled = abi.window.MenuItemFlags.disabled;
        m.beginMenu("Settings");
        m.item(MenuId.about, "About Settings", 0, 0, 0);
        m.separator();
        m.item(MenuId.quit, "Quit Settings", 'q', 0, 0);
        m.endMenu();
        m.beginMenu("Edit");
        m.item(MenuId.cut, "Cut", 'x', 0, 0);
        m.item(MenuId.copy, "Copy", 'c', 0, 0);
        m.item(MenuId.paste, "Paste", 'v', 0, 0);
        m.item(MenuId.select_all, "Select All", 'a', 0, 0);
        m.endMenu();
        m.beginMenu("View");
        m.item(MenuId.back, "Back", '[', 0, if (self.hist_pos == 0) disabled else 0);
        m.item(MenuId.forward, "Forward", ']', 0, if (self.hist_pos + 1 >= self.hist_len) disabled else 0);
        m.separator();
        for (pane_list, 0..) |p, i| {
            const key: u8 = if (i < 9) @intCast('1' + i) else 0;
            m.item(MenuId.pane + @as(u32, @intCast(i)), p.title, key, 0, if (self.loc.pane == p.pane) checked else 0);
        }
        m.separator();
        m.item(MenuId.find, "Search Settings", 'f', 0, 0);
        m.endMenu();
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        switch (id) {
            MenuId.about => self.openSheet(u, .about_app),
            MenuId.quit => u.quit = true,
            MenuId.cut, MenuId.copy, MenuId.paste, MenuId.select_all => self.editOp(id),
            MenuId.back => self.back(),
            MenuId.forward => self.forward(),
            MenuId.find => u.focus = hashId("search"),
            else => if (id >= MenuId.pane and id < MenuId.pane + pane_list.len) {
                if (self.sheet == .none) self.go(.{ .pane = pane_list[id - MenuId.pane].pane });
            },
        }
    }

    fn editOp(self: *App, id: u32) void {
        const st = self.edit_target orelse return;
        const a = @min(st.cursor, st.anchor);
        const b = @max(st.cursor, st.anchor);
        switch (id) {
            MenuId.copy, MenuId.cut => {
                if (b > a and !self.edit_secure) ui.client.clipboardSet(st.buf.items[a..b]) catch {};
                if (id == MenuId.cut and b > a and !self.edit_secure) _ = st.deleteSelectionAlloc(self.allocator);
            },
            MenuId.paste => {
                const clip = ui.client.clipboardGet(self.allocator) catch return;
                defer self.allocator.free(clip);
                const line = if (std.mem.indexOfScalar(u8, clip, '\n')) |nl| clip[0..nl] else clip;
                _ = st.deleteSelectionAlloc(self.allocator);
                st.buf.insertSlice(self.allocator, st.cursor, line) catch return;
                st.cursor += line.len;
                st.anchor = st.cursor;
            },
            MenuId.select_all => {
                st.anchor = 0;
                st.cursor = st.buf.items.len;
            },
            else => {},
        }
    }

    pub fn timeoutMs(self: *App) i32 {
        if (self.job != .none) return 0;
        if (self.loc.pane == .privacy and self.apps.verifyPending()) return 0;
        if (self.loc.pane == .general and self.loc.sub == .date_time) return 1000;
        return -1;
    }

    // ------------------------------------------------------------------
    // Text fields with Edit-menu support
    // ------------------------------------------------------------------

    pub fn field(self: *App, u: *Ui, id: []const u8, r: Rect, st: *ui.TextState, opts: Ui.FieldOpts) ui.ui.TextFieldResult {
        const res = u.textField(id, r, st, opts);
        if (u.focus == hashId(id)) {
            self.edit_target = st;
            self.edit_secure = opts.secure;
        }
        return res;
    }

    // ------------------------------------------------------------------
    // Pop-up menus
    // ------------------------------------------------------------------

    /// Pop-up button right-aligned at `right_x`; returns true when the user
    /// picked a different item from its menu.
    pub fn popupButton(self: *App, u: *Ui, id_str: []const u8, right_x: i32, cy: i32, items: []const []const u8, value: *usize) bool {
        if (items.len == 0) return false;
        const id = hashId(id_str);
        const cur = items[@min(value.*, items.len - 1)];
        const b = w.popupButton(u, id, right_x, cy, cur, true);
        if (b.clicked) self.openPopup(u, id, b.rect, items, value);
        if (self.popup.changed_id == id) {
            self.popup.changed_id = 0;
            return true;
        }
        return false;
    }

    fn openPopup(self: *App, u: *Ui, id: ui.ui.Id, anchor: Rect, items: []const []const u8, value: *usize) void {
        var mw: f32 = 0;
        for (items) |it| mw = @max(mw, u.measure(it, .regular, 13));
        const width: i32 = @as(i32, @intFromFloat(@ceil(mw))) + 48;
        const n: i32 = @intCast(items.len);
        const height = n * Popup.item_h + 10;
        const sel: i32 = @intCast(@min(value.*, items.len - 1));
        var x = anchor.x - 18;
        var y = anchor.y + @divTrunc(anchor.h, 2) - (5 + sel * Popup.item_h + @divTrunc(Popup.item_h, 2));
        x = std.math.clamp(x, 4, @max(4, u.width() - width - 4));
        y = std.math.clamp(y, 4, @max(4, u.height() - height - 4));
        self.popup = .{ .open = true, .id = id, .items = items, .target = value, .rect = Rect.init(x, y, width, height) };
    }

    /// Handle clicks for an open pop-up menu before anything else sees them.
    fn popupInput(self: *App, u: *Ui) void {
        const p = &self.popup;
        if (!p.open) return;
        const inner = p.rect.inset(5, 5);
        p.hover = null;
        if (inner.contains(u.mouse_x, u.mouse_y)) {
            p.hover = @intCast(@divTrunc(u.mouse_y - inner.y, Popup.item_h));
            if (p.hover.? >= p.items.len) p.hover = null;
        }
        if (u.mouse_released) {
            if (p.hover) |i| {
                if (p.target.* != i) {
                    p.target.* = i;
                    p.changed_id = p.id;
                }
                p.open = false;
            }
        } else if (u.mouse_pressed and !p.rect.contains(u.mouse_x, u.mouse_y)) {
            p.open = false;
        }
        if (u.keyPressed(Key.esc)) p.open = false;
        if (p.open) {
            u.key_count = 0;
            u.keys_consumed = true;
        }
        // The press/release belonged to the menu.
        u.mouse_pressed = false;
        u.mouse_released = false;
    }

    fn drawPopup(self: *App, u: *Ui) void {
        const p = &self.popup;
        if (!p.open) return;
        const t = u.theme;
        const r = p.rect;
        u.shadow(r, 10, 14, 6, if (t.dark) 0x80000000 else 0x38000000);
        u.fillRound(r, 10, if (t.dark) 0xF22C2C30 else 0xF5F6F6F8);
        u.strokeRound(r, 10, 1, if (t.dark) 0x26FFFFFF else 0x1A000000);
        for (p.items, 0..) |item, i| {
            const ir = Rect.init(r.x + 5, r.y + 5 + @as(i32, @intCast(i)) * Popup.item_h, r.w - 10, Popup.item_h);
            const hovered = p.hover != null and p.hover.? == i;
            if (hovered) u.fillRound(ir, 6, t.accent);
            const fg: u32 = if (hovered) 0xFFFFFFFF else t.label;
            if (p.target.* == i) w.checkmark(u, @floatFromInt(ir.x + 7), @floatFromInt(ir.y + 7), 9, 1.6, fg);
            u.text(Rect.init(ir.x + 24, ir.y, ir.w - 30, ir.h), item, .{ .color = fg });
        }
    }

    // ------------------------------------------------------------------
    // Sheets
    // ------------------------------------------------------------------

    pub fn openSheet(self: *App, u: *Ui, kind: SheetKind) void {
        self.sheet = kind;
        self.popup.open = false;
        self.sheet_error = "";
        self.sheet_admin = false;
        self.account_edited = false;
        for (&self.fields) |*f| f.set(self.allocator, "");
        if (kind == .hostname) self.fields[0].set(self.allocator, self.about.host_field.text());
        u.focus = if (kind == .hostname) hashId("sf1") else hashId("sf0");
    }

    pub fn closeSheet(self: *App, u: *Ui) void {
        self.sheet = .none;
        self.sheet_error = "";
        // Do not keep passwords in memory longer than needed.
        for (&self.fields) |*f| {
            @memset(f.buf.items, 0);
            f.set(self.allocator, "");
        }
        u.focus = 0;
    }

    /// Dimmed backdrop + centered sheet panel of the given size.
    pub fn sheetPanel(self: *App, u: *Ui, width: i32, height: i32) Rect {
        _ = self;
        const t = u.theme;
        u.fillRect(u.bounds(), if (t.dark) 0x66000000 else 0x33000000);
        const x = @divTrunc(u.width() - width, 2) + @divTrunc(sidebar_w, 3);
        const y = @max(toolbar_h - 8, @divTrunc(u.height() - height, 3));
        const r = Rect.init(@max(12, x), y, width, height);
        u.shadow(r, 18, 22, 10, if (t.dark) 0xA0000000 else 0x50000000);
        u.fillRound(r, 18, if (t.dark) 0xFF2B2B2F else 0xFFF8F8FA);
        u.strokeRound(r, 18, 1, if (t.dark) 0x26FFFFFF else 0x12000000);
        return r;
    }

    fn drawSheet(self: *App, u: *Ui) void {
        switch (self.sheet) {
            .none => {},
            .add_user, .change_password => accounts.drawSheet(self, u),
            .hostname => general.drawHostnameSheet(self, u),
            .about_app => self.drawAboutSheet(u),
        }
    }

    fn drawAboutSheet(self: *App, u: *Ui) void {
        const r = self.sheetPanel(u, 300, 250);
        const t = u.theme;
        w.blit(u, self.icons.app(.settings, 72), r.x + @divTrunc(r.w - 72, 2), r.y + 24);
        u.text(Rect.init(r.x, r.y + 108, r.w, 24), "Settings", .{ .size = 17, .weight = .bold, .@"align" = .center });
        u.text(Rect.init(r.x, r.y + 134, r.w, 18), "Version 1.0", .{ .size = 12, .color = t.secondary_label, .@"align" = .center });
        u.text(Rect.init(r.x, r.y + 156, r.w, 18), "© 2026 Zen OS contributors", .{ .size = 11, .color = t.tertiary_label, .@"align" = .center });
        if (u.button("about-ok", Rect.init(r.x + @divTrunc(r.w - 90, 2), r.bottom() - 48, 90, 26), "OK", .{ .style = .primary }) or
            u.keyPressed(Key.enter) or u.keyPressed(Key.esc))
        {
            self.closeSheet(u);
        }
    }

    // ------------------------------------------------------------------
    // Jobs (run on the frame after they are requested so the UI can first
    // show a "working" state)
    // ------------------------------------------------------------------

    pub fn startJob(self: *App, job: Job) void {
        self.job = job;
    }

    fn runJob(self: *App, u: *Ui) void {
        // Jobs requested during the previous frame, which already showed
        // their "working…" state.
        const job = self.job;
        if (job == .none) return;
        self.job = .none;
        switch (job) {
            .none => {},
            .add_user, .change_password => accounts.runJob(self, u, job),
            .set_hostname => general.runHostnameJob(self, u),
            .storage_scan => other.scanStorage(self),
        }
    }

    // ------------------------------------------------------------------
    // Frame
    // ------------------------------------------------------------------

    pub fn frame(self: *App, u: *Ui) void {
        self.runJob(u);
        self.icons.dark = u.theme.dark;
        self.autoAppearance(u);
        const before = self.loc;
        const sheet_before = self.sheet;
        self.drawPass(u, true);
        if (before.pane != self.loc.pane or before.sub != self.loc.sub or sheet_before != self.sheet) {
            // Navigation (or a sheet) happened mid-frame: redraw right away
            // so the new state shows without waiting for another event.
            _ = suppressInput(u);
            u.keys_consumed = true;
            self.drawPass(u, false);
        }
        self.popup.changed_id = 0;
        if (self.menu_dirty) {
            self.menu_dirty = false;
            var buf: [4096]u8 = undefined;
            var mw = abi.window.MenuWriter{ .buf = &buf };
            self.menu(&mw);
            u.win.setMenu(mw.bytes());
        }
    }

    fn drawPass(self: *App, u: *Ui, interactive: bool) void {
        self.edit_target = null;
        const modal = self.sheet != .none;
        if (interactive) self.popupInput(u);
        var saved: SavedInput = .{};
        if (modal) saved = suppressInput(u);
        if (interactive and !modal and !self.popup.open) self.globalKeys(u);

        u.clear(w.contentBg(u.theme));
        self.drawContent(u);
        self.drawSidebar(u);

        // Dragging the window by its toolbar / the top of the sidebar.
        if (interactive and !modal and !self.popup.open and u.mouse_pressed and u.hot == 0 and u.mouse_y < toolbar_h) {
            if (u.click_count >= 2) u.win.command(.zoom, "") else u.win.beginMove();
        }

        if (modal) {
            restoreInput(u, saved);
            self.drawSheet(u);
        }
        self.drawPopup(u);
    }

    /// "Auto" appearance: follow the time of day (checked whenever a frame
    /// is drawn; only acts when the computed mode changes).
    fn autoAppearance(self: *App, u: *Ui) void {
        if (self.prefs.appearance != .auto or self.headless) return;
        const dark = look.autoIsDark();
        if (self.last_auto != null and self.last_auto.? == dark) return;
        self.last_auto = dark;
        if (u.theme.dark != dark) self.applyDark(u, dark);
    }

    fn globalKeys(self: *App, u: *Ui) void {
        // Only when no text field has keyboard focus.
        if (u.focus != 0) return;
        // Arrow keys move through the sidebar like a source list.
        var dir: i32 = 0;
        if (u.keyPressed(Key.up)) dir = -1;
        if (u.keyPressed(Key.down)) dir = 1;
        if (dir != 0) {
            var i: i32 = @intCast(@intFromEnum(self.loc.pane));
            i = std.math.clamp(i + dir, 0, @as(i32, pane_list.len) - 1);
            self.go(.{ .pane = @enumFromInt(@as(usize, @intCast(i))) });
        }
        if (u.keyPressed(Key.esc) and self.loc.sub != .none) self.go(.{ .pane = self.loc.pane });
    }

    // ------------------------------------------------------------------
    // Sidebar
    // ------------------------------------------------------------------

    fn matches(self: *App, p: PaneInfo) bool {
        const q = std.mem.trim(u8, self.search.text(), " ");
        if (q.len == 0) return true;
        return std.ascii.indexOfIgnoreCase(p.title, q) != null or std.ascii.indexOfIgnoreCase(p.keywords, q) != null;
    }

    fn drawSidebar(self: *App, u: *Ui) void {
        const t = u.theme;
        const panel = Rect.init(8, 8, sidebar_w - 16, u.height() - 16);
        const fill = if (self.prefs.reduce_transparency) w.sidebarOpaque(t) else t.sidebar_bg;
        w.replaceRound(u.canvas, panel, 14, pm(fill));
        u.strokeRound(panel, 14, 1, if (t.dark) 0x1FFFFFFF else 0x12000000);
        // Specular top edge of the glass.
        u.hline(panel.x + 14, panel.right() - 14, panel.y + 1, if (t.dark) 0x14FFFFFF else 0x66FFFFFF);

        // Search field.
        const sr = Rect.init(panel.x + 10, 48, panel.w - 20, 28);
        const search_id = hashId("search");
        const focused = u.focus == search_id and u.focused;
        if (focused) u.fillRound(sr.inset(-3, -3), 17, ui.ui.withAlpha(t.accent, 90));
        u.fillRound(sr, 14, if (t.dark) 0x1FFFFFFF else (if (focused) 0xFFFFFFFF else 0x12000000));
        w.blit(u, self.icons.symbol(.magnifier, pm(t.secondary_label), 13), sr.x + 10, sr.y + 8);
        const res = self.field(u, "search", Rect.init(sr.x + 22, sr.y, sr.w - 44, sr.h), &self.search, .{ .placeholder = "Search", .plain = true });
        if (self.search.text().len > 0) {
            const cx: f32 = @floatFromInt(sr.right() - 14);
            const cy: f32 = @floatFromInt(sr.y + 14);
            const cr = Rect.init(sr.right() - 22, sr.y + 6, 16, 16);
            if (u.interact(hashId("search-clear"), cr)) self.search.set(self.allocator, "");
            u.fillCircle(cx, cy, 7, t.tertiary_label);
            u.line(cx - 2.5, cy - 2.5, cx + 2.5, cy + 2.5, 1.4, w.contentBg(t));
            u.line(cx + 2.5, cy - 2.5, cx - 2.5, cy + 2.5, 1.4, w.contentBg(t));
        }
        if (res.submitted) {
            for (pane_list) |p| if (self.matches(p)) {
                self.go(.{ .pane = p.pane });
                break;
            };
        }
        if (focused and u.keyPressed(Key.esc)) {
            self.search.set(self.allocator, "");
            u.focus = 0;
        }

        // Scrollable list below the search field.
        const list = Rect.init(panel.x, sr.bottom() + 8, panel.w, panel.bottom() - sr.bottom() - 10);
        const old = u.beginScroll(list, &self.side_scroll);
        var y = list.y - @as(i32, @intFromFloat(self.side_scroll.offset));
        const x = panel.x + 8;
        const rw = panel.w - 16;

        // User card.
        const card = Rect.init(x, y, rw, 46);
        const card_id = hashId("user-card");
        if (u.interact(card_id, card)) self.go(.{ .pane = .users });
        if (u.hot == card_id) u.fillRound(card, 9, t.hover);
        u.avatar(@floatFromInt(card.x + 22), @floatFromInt(card.y + 23), 17, self.full_name);
        u.text(Rect.init(card.x + 48, card.y + 6, card.w - 52, 18), self.full_name, .{ .weight = .semibold });
        u.text(Rect.init(card.x + 48, card.y + 24, card.w - 52, 16), "Zen Account", .{ .size = 11, .color = t.secondary_label });
        y += 54;

        var last_section: ?u8 = null;
        var shown: usize = 0;
        for (pane_list) |p| {
            if (!self.matches(p)) continue;
            if (last_section) |s| {
                if (s != p.section) y += 10;
            }
            last_section = p.section;
            shown += 1;
            const r = Rect.init(x, y, rw, 30);
            const id = ui.ui.hashIdx("pane", @intFromEnum(p.pane));
            if (u.interact(id, r)) {
                self.go(.{ .pane = p.pane });
                u.focus = 0;
            }
            const selected = self.loc.pane == p.pane;
            if (selected) {
                u.fillRound(r, 8, if (u.focused) t.accent else (if (t.dark) 0x38FFFFFF else 0x1C000000));
            } else if (u.isActive(id)) {
                u.fillRound(r, 8, t.selection_inactive);
            }
            w.blit(u, self.icons.tile(p.glyph, p.color, 20), r.x + 6, r.y + 5);
            const fg = if (selected and u.focused) 0xFFFFFFFF else t.label;
            u.text(Rect.init(r.x + 34, r.y, r.w - 40, r.h), p.title, .{ .color = fg });
            y += 30;
        }
        if (shown == 0) {
            u.text(Rect.init(x, y + 10, rw, 20), "No Results", .{ .color = t.secondary_label, .@"align" = .center });
            y += 40;
        }
        self.side_scroll.content = @floatFromInt(y + @as(i32, @intFromFloat(self.side_scroll.offset)) - list.y + 8);
        endScroll(u, list, &self.side_scroll, old);
    }

    // ------------------------------------------------------------------
    // Content
    // ------------------------------------------------------------------

    fn drawContent(self: *App, u: *Ui) void {
        const t = u.theme;
        const x0 = sidebar_w;
        const cw = u.width() - x0;
        const view = Rect.init(x0, toolbar_h, cw, u.height() - toolbar_h);
        if (self.pending_scroll > 0 and self.scroll.content > 0) {
            self.scroll.offset = self.pending_scroll;
            self.pending_scroll = 0;
        }
        const old = u.beginScroll(view, &self.scroll);
        const max_w: i32 = 620;
        const margin = @max(20, @divTrunc(cw - max_w, 2));
        const top = toolbar_h + 4 - @as(i32, @intFromFloat(self.scroll.offset));
        var f = w.Form.init(u, x0 + margin, cw - 2 * margin, top);
        switch (self.loc.pane) {
            .general => general.draw(self, u, &f),
            .appearance => look.drawAppearance(self, u, &f),
            .wallpaper => look.drawWallpaper(self, u, &f),
            .displays => look.drawDisplays(self, u, &f),
            .keyboard => other.drawKeyboard(self, u, &f),
            .users => accounts.draw(self, u, &f),
            .privacy => privacy.draw(self, u, &f),
            .lock_screen => other.drawLockScreen(self, u, &f),
            .storage => other.drawStorage(self, u, &f),
            .developer => other.drawDeveloper(self, u, &f),
        }
        self.scroll.content = @floatFromInt(f.height() + 12);
        endScroll(u, view, &self.scroll, old);

        // Toolbar (content scrolls under it).
        const bar = Rect.init(x0, 0, cw, toolbar_h);
        u.fillRect(bar, w.contentBg(t));
        if (self.scroll.offset > 0.5) {
            // Soft scroll-edge effect instead of a hard line.
            const bg = w.contentBg(t) & 0x00FFFFFF;
            var i: i32 = 0;
            while (i < 10) : (i += 1) {
                const a: u32 = @intCast(@divTrunc((10 - i) * 200, 10));
                u.fillRect(Rect.init(x0, toolbar_h + i, cw, 1), bg | (a << 24));
            }
            u.hline(x0, x0 + cw, toolbar_h - 1, if (t.dark) 0x14FFFFFF else 0x0D000000);
        }
        self.drawToolbar(u, bar);
    }

    fn drawToolbar(self: *App, u: *Ui, bar: Rect) void {
        const t = u.theme;
        // Back / forward capsule.
        const cap = Rect.init(bar.x + 14, 12, 64, 28);
        u.shadow(cap, 14, 4, 1, if (t.dark) 0x50000000 else 0x1A000000);
        u.fillRound(cap, 14, if (t.dark) 0xFF2C2C2F else 0xFFFFFFFF);
        u.strokeRound(cap, 14, 1, if (t.dark) 0x1FFFFFFF else 0x14000000);
        const can_back = self.hist_pos > 0;
        const can_fwd = self.hist_pos + 1 < self.hist_len;
        const br = Rect.init(cap.x, cap.y, 32, cap.h);
        const fr = Rect.init(cap.x + 32, cap.y, 32, cap.h);
        const bid = hashId("nav-back");
        const fid = hashId("nav-fwd");
        if (can_back and u.interact(bid, br)) self.back();
        if (can_fwd and u.interact(fid, fr)) self.forward();
        if (can_back and u.isActive(bid)) u.fillRound(br.inset(2, 2), 12, t.selection_inactive);
        if (can_fwd and u.isActive(fid)) u.fillRound(fr.inset(2, 2), 12, t.selection_inactive);
        const cy: f32 = @floatFromInt(cap.y + 14);
        w.chevron(u, @floatFromInt(br.x + 17), cy, 5, .left, 1.8, if (can_back) t.label else t.tertiary_label);
        w.chevron(u, @floatFromInt(fr.x + 15), cy, 5, .right, 1.8, if (can_fwd) t.label else t.tertiary_label);
        const title = if (self.loc.sub != .none) subTitle(self.loc.sub) else paneInfo(self.loc.pane).title;
        u.text(Rect.init(cap.right() + 14, 0, bar.right() - cap.right() - 28, toolbar_h), title, .{ .size = 15, .weight = .bold });
    }

    // ------------------------------------------------------------------
    // Host previews
    // ------------------------------------------------------------------

    pub fn preview(self: *App, u: *Ui) void {
        const target = preview_target orelse PreviewTarget{ .pane = .general, .sub = .about };
        self.setIdentity("zen", "Zen User", 501);
        self.hostname = sys.copyInto(&self.hostname_buf, "zen-os");
        general.loadSample(self);
        accounts.loadSample(self);
        privacy.loadSample(self);
        other.loadSample(self);
        self.loc = .{ .pane = target.pane, .sub = target.sub };
        self.history[0] = .{ .pane = .general };
        self.history[1] = self.loc;
        const root = target.pane == .general and target.sub == .none;
        self.hist_len = if (root) 1 else 2;
        self.hist_pos = if (root) 0 else 1;
        self.pending_scroll = target.scroll;
        if (target.sheet != .none) {
            self.openSheet(u, target.sheet);
            accounts.previewSheet(self, target.sheet);
        }
    }
};

/// Overlay scroll bar that only appears while the pointer is over the view
/// (macOS "automatically based on input").
fn endScroll(u: *Ui, r: Rect, st: *ui.ScrollState, old: Rect) void {
    u.popClip(old);
    st.clamp();
    if (st.content <= st.view or !u.hovering(r)) return;
    const frac = st.view / st.content;
    const bar_h = @max(28, @as(f32, @floatFromInt(r.h - 8)) * frac);
    const pos = (st.offset / (st.content - st.view)) * (@as(f32, @floatFromInt(r.h - 8)) - bar_h);
    const bar = Rect.init(r.right() - 9, r.y + 4 + @as(i32, @intFromFloat(pos)), 6, @intFromFloat(bar_h));
    u.fillRound(bar, 3, if (u.theme.dark) 0x73FFFFFF else 0x59000000);
}

// ---------------------------------------------------------------------------
// Modal input suppression
// ---------------------------------------------------------------------------

pub const SavedInput = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    pressed: bool = false,
    released: bool = false,
    scroll_dy: f32 = 0,
    key_count: usize = 0,
    text_len: usize = 0,
};

fn suppressInput(u: *Ui) SavedInput {
    const s = SavedInput{
        .mouse_x = u.mouse_x,
        .mouse_y = u.mouse_y,
        .pressed = u.mouse_pressed,
        .released = u.mouse_released,
        .scroll_dy = u.scroll_dy,
        .key_count = u.key_count,
        .text_len = u.text_len,
    };
    u.mouse_x = -1000;
    u.mouse_y = -1000;
    u.mouse_pressed = false;
    u.mouse_released = false;
    u.scroll_dy = 0;
    u.key_count = 0;
    u.text_len = 0;
    return s;
}

fn restoreInput(u: *Ui, s: SavedInput) void {
    u.mouse_x = s.mouse_x;
    u.mouse_y = s.mouse_y;
    u.mouse_pressed = s.pressed;
    u.mouse_released = s.released;
    u.scroll_dy = s.scroll_dy;
    u.key_count = s.key_count;
    u.text_len = s.text_len;
    u.keys_consumed = false;
}

test "command-line pane names" {
    try std.testing.expectEqual(Pane.general, parseLoc("about").?.pane);
    try std.testing.expectEqual(Sub.about, parseLoc("about").?.sub);
    try std.testing.expectEqual(Pane.privacy, parseLoc("x-settings:security").?.pane);
    try std.testing.expect(parseLoc("/tmp/out.png") == null);
    for (pane_list, 0..) |p, i| try std.testing.expectEqual(i, @intFromEnum(p.pane));
}

test {
    _ = w;
    _ = sys;
    _ = general;
    _ = look;
    _ = accounts;
    _ = privacy;
    _ = other;
}
