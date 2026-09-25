//! Global window-server state shared by the protocol, input and render
//! modules.

const std = @import("std");
const abi = @import("abi");
const wm = @import("wm.zig");

pub const Rect = wm.Rect;

pub const Appearance = struct {
    dark: bool = false,
    accent: u8 = 0,
    wallpaper: u8 = 2, // Golden Gate
    reduce_transparency: bool = false,
    /// 24-hour clock in the menu bar.
    clock_24h: bool = true,
};

pub const SessionState = enum { login, active, locked };

pub const App = struct {
    pid: u32,
    id: [96]u8 = [_]u8{0} ** 96,
    id_len: usize = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,

    pub fn idSlice(self: *const App) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const App) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DockItem = struct {
    id: []const u8,
    name: []const u8,
    icon: []const u8,
    pinned: bool,
    running: bool = false,
    /// Screen rectangle of the icon (computed by layout).
    rect: Rect = .{},
    bounce_until_ms: u64 = 0,
};

pub const Notification = struct {
    title: [96]u8 = undefined,
    title_len: usize = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,
    app: [64]u8 = undefined,
    app_len: usize = 0,
    expires_ms: u64 = 0,
};

pub const MenuOpen = struct {
    /// Index of the open top-level menu (-1 = closed).
    index: i32 = -1,
    hover: i32 = -1,
    rect: Rect = .{},
};

pub const Switcher = struct {
    active: bool = false,
    selected: usize = 0,
};

pub const Mouse = struct {
    x: i32 = 0,
    y: i32 = 0,
    buttons: u32 = 0,
    /// Window currently under the pointer.
    hover_window: u32 = 0,
    /// Window receiving the button press (implicit grab).
    grab_window: u32 = 0,
    last_click_ms: u64 = 0,
    click_count: i32 = 0,
    cursor: abi.window.Cursor = .arrow,
};

pub const Keyboard = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    caps: bool = false,
    arabic: bool = false,

    pub fn mods(self: Keyboard) u32 {
        const M = abi.window.Mods;
        var m: u32 = 0;
        if (self.shift) m |= M.shift;
        if (self.ctrl) m |= M.ctrl;
        if (self.alt) m |= M.alt;
        if (self.meta) m |= M.cmd;
        if (self.caps) m |= M.caps;
        return m;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    width: i32,
    height: i32,
    manager: wm.Manager,
    appearance: Appearance = .{},
    session: SessionState = .login,
    session_uid: u32 = 0,
    session_user: [64]u8 = [_]u8{0} ** 64,
    session_user_len: usize = 0,
    apps: std.ArrayList(App) = .empty,
    dock: std.ArrayList(DockItem) = .empty,
    notifications: std.ArrayList(Notification) = .empty,
    menu: MenuOpen = .{},
    switcher: Switcher = .{},
    mouse: Mouse = .{},
    keys: Keyboard = .{},
    clipboard: std.ArrayList(u8) = .empty,
    /// Screen region that must be recomposited.
    dirty: Rect = .{},
    now_ms: u64 = 0,
    /// Minute shown by the menu-bar clock (redraw when it changes).
    clock_minute: i64 = -1,

    pub fn init(allocator: std.mem.Allocator, w: i32, h: i32) State {
        return .{
            .allocator = allocator,
            .width = w,
            .height = h,
            .manager = wm.Manager.init(allocator, w, h),
            .mouse = .{ .x = @divTrunc(w, 2), .y = @divTrunc(h, 2) },
        };
    }

    pub fn screen(self: *const State) Rect {
        return .{ .w = self.width, .h = self.height };
    }

    pub fn invalidate(self: *State, r: Rect) void {
        self.dirty = self.dirty.unionWith(r.intersect(self.screen()));
    }

    pub fn invalidateAll(self: *State) void {
        self.dirty = self.screen();
    }

    pub fn userName(self: *const State) []const u8 {
        return self.session_user[0..self.session_user_len];
    }

    pub fn appByPid(self: *State, pid: u32) ?*App {
        for (self.apps.items) |*a| if (a.pid == pid) return a;
        return null;
    }

    /// Display name of the app owning the focused window.
    pub fn activeAppName(self: *State) []const u8 {
        const win = self.manager.get(self.manager.focused) orelse return "Finder";
        if (self.appByPid(win.owner_pid)) |a| return a.nameSlice();
        if (win.title_len > 0) return win.titleSlice();
        return "Finder";
    }

    pub fn dark(self: *const State) bool {
        return self.appearance.dark;
    }
};
