//! The `window:` scheme protocol spoken between apps and the window server.
//!
//! Create a window by opening a URL such as
//!     window:new?w=720&h=480&title=Notes&flags=3
//! (`x`/`y` may be given, default is centered/cascaded; `minw`/`minh` set
//! the minimum size). The returned fd is the window:
//!   * `mmap(fd)` → the window's pixel buffer: `w*h` premultiplied ARGB
//!     u32 pixels (content area only, decorations are server side).
//!   * `write(fd, commands)` → one or more `Command`s (header + body).
//!   * `read(fd, events)` → an array of fixed-size `Event`s; blocks until
//!     at least one is available (pollable with POLLIN).
//! After a `resize` event the app must mmap again (the buffer changed),
//! redraw and send a `damage` command.
//!
//! Other URLs: `window:clipboard` (read/write UTF-8 text) and
//! `window:control` (privileged session control used by loginwindow and
//! launchd).

const std = @import("std");

pub const Flags = struct {
    pub const resizable: u32 = 1 << 0;
    /// Content has meaningful alpha; translucent pixels show a blurred,
    /// saturated copy of whatever is behind the window (vibrancy).
    pub const transparent: u32 = 1 << 1;
    /// No title bar or frame.
    pub const borderless: u32 = 1 << 2;
    /// Content extends below a transparent title bar; the traffic lights
    /// float over the content (modern unified-toolbar look).
    pub const full_size_content: u32 = 1 << 3;
    pub const no_shadow: u32 = 1 << 4;
    /// Utility panel: not shown in the Dock, stays above normal windows.
    pub const panel: u32 = 1 << 5;
    /// Popup (menus, popovers, tooltips): dismissed by outside clicks.
    pub const popup: u32 = 1 << 6;
    /// Login / lock shield level. Only root may use it.
    pub const shield: u32 = 1 << 7;
    pub const hidden: u32 = 1 << 8;
    /// Force a dark title bar regardless of the system appearance.
    pub const dark: u32 = 1 << 9;
    /// Desktop level (behind all windows), e.g. Finder's desktop.
    pub const desktop: u32 = 1 << 10;
};

pub const Mods = struct {
    pub const shift: u32 = 1 << 0;
    pub const ctrl: u32 = 1 << 1;
    /// Option / Alt.
    pub const alt: u32 = 1 << 2;
    /// Command (the Super/Meta key).
    pub const cmd: u32 = 1 << 3;
    pub const caps: u32 = 1 << 4;
};

pub const Cursor = enum(u32) {
    arrow = 0,
    ibeam,
    pointer,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    move,
    crosshair,
    wait,
    not_allowed,
    hidden,
    _,
};

// ---------------------------------------------------------------------------
// Commands (app → server)
// ---------------------------------------------------------------------------

pub const CommandKind = enum(u32) {
    /// Body: `Rect`. Present the given part of the buffer.
    damage = 1,
    /// Body: UTF-8 title.
    set_title = 2,
    /// Body: `Size`. Ask for a new content size.
    resize = 3,
    /// Body: `Point`. Move the window (screen coordinates of the frame).
    move = 4,
    show = 5,
    hide = 6,
    /// Bring to front and give keyboard focus.
    activate = 7,
    minimize = 8,
    /// Toggle zoom (fill the usable screen area).
    zoom = 9,
    /// Body: u32 `Cursor`.
    set_cursor = 10,
    /// Body: serialized menu (see `MenuWriter`). Shown in the global menu
    /// bar while this app is active.
    set_menu = 11,
    /// Body: u32 flags.
    set_flags = 12,
    /// Body: `Size`.
    set_min_size = 13,
    /// Start an interactive window move (e.g. drag in a custom title area).
    begin_move = 14,
    /// Body: i32 height of the draggable title area for
    /// `full_size_content` windows.
    set_title_height = 15,
    /// Body: "title\x00body". Posts a notification banner.
    notify = 16,
    /// Body: u32 1/0. Mark the document as edited (dot in close button).
    set_edited = 17,
    _,
};

pub const CommandHeader = extern struct {
    kind: CommandKind,
    /// Total size of the command including this header.
    size: u32,
};

pub const Rect = extern struct { x: i32, y: i32, w: i32, h: i32 };
pub const Size = extern struct { w: i32, h: i32 };
pub const Point = extern struct { x: i32, y: i32 };

/// Append a command to `out`. Returns the number of bytes written or null
/// when `out` is too small.
pub fn encodeCommand(out: []u8, kind: CommandKind, body: []const u8) ?usize {
    const total = @sizeOf(CommandHeader) + body.len;
    if (total > out.len) return null;
    const hdr = CommandHeader{ .kind = kind, .size = @intCast(total) };
    @memcpy(out[0..@sizeOf(CommandHeader)], std.mem.asBytes(&hdr));
    @memcpy(out[@sizeOf(CommandHeader)..total], body);
    return total;
}

pub const CommandIterator = struct {
    buf: []const u8,
    pos: usize = 0,

    pub const Item = struct { kind: CommandKind, body: []const u8 };

    pub fn next(self: *CommandIterator) ?Item {
        if (self.pos + @sizeOf(CommandHeader) > self.buf.len) return null;
        var hdr: CommandHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr), self.buf[self.pos..][0..@sizeOf(CommandHeader)]);
        if (hdr.size < @sizeOf(CommandHeader) or self.pos + hdr.size > self.buf.len) return null;
        const body = self.buf[self.pos + @sizeOf(CommandHeader) .. self.pos + hdr.size];
        self.pos += hdr.size;
        return .{ .kind = hdr.kind, .body = body };
    }
};

// ---------------------------------------------------------------------------
// Events (server → app)
// ---------------------------------------------------------------------------

pub const EventKind = enum(u32) {
    none = 0,
    /// a = keycode (Linux evdev), text = UTF-8 produced (may be empty).
    key_down = 1,
    key_up = 2,
    /// a, b = position in content coordinates.
    mouse_move = 3,
    /// a, b = position, c = button (1 left, 2 right, 3 middle),
    /// d = click count.
    mouse_down = 4,
    mouse_up = 5,
    /// a, b = position, c = dx, d = dy (pixels, positive = down/right).
    scroll = 6,
    mouse_enter = 7,
    mouse_leave = 8,
    /// a = 1 focused, 0 unfocused.
    focus = 9,
    /// a = new width, b = new height. Re-map the buffer.
    resize = 10,
    /// The user clicked the close button.
    close_request = 11,
    /// a = menu item id.
    menu = 12,
    /// Cmd-Q or logout: the app should save and exit.
    quit_request = 13,
    /// a = 1 dark / 0 light, b = accent colour (ARGB), c = 1 if reduce
    /// transparency is on.
    appearance = 14,
    /// a = 1 visible / 0 hidden or minimized.
    visibility = 15,
    _,
};

pub const Event = extern struct {
    kind: EventKind = .none,
    mods: u32 = 0,
    a: i32 = 0,
    b: i32 = 0,
    c: i32 = 0,
    d: i32 = 0,
    time_ms: u64 = 0,
    text: [16]u8 = [_]u8{0} ** 16,

    pub fn textSlice(self: *const Event) []const u8 {
        return std.mem.sliceTo(&self.text, 0);
    }
};

comptime {
    std.debug.assert(@sizeOf(Event) == 48);
}

// ---------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------

pub const MenuRecord = enum(u8) {
    /// Starts a top-level menu. The first one is the application menu.
    menu = 1,
    item = 2,
    separator = 3,
    end = 4,
};

pub const MenuItemFlags = struct {
    pub const disabled: u8 = 1 << 0;
    pub const checked: u8 = 1 << 1;
};

/// Record layout: kind u8, flags u8, key u8, mods u8, id u32, len u16,
/// title[len].
pub const MenuWriter = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn put(self: *MenuWriter, kind: MenuRecord, flags: u8, key: u8, mods: u8, id: u32, title: []const u8) void {
        const need = 10 + title.len;
        if (self.len + need > self.buf.len) {
            self.overflow = true;
            return;
        }
        const b = self.buf[self.len..];
        b[0] = @intFromEnum(kind);
        b[1] = flags;
        b[2] = key;
        b[3] = mods;
        std.mem.writeInt(u32, b[4..8], id, .little);
        std.mem.writeInt(u16, b[8..10], @intCast(title.len), .little);
        @memcpy(b[10 .. 10 + title.len], title);
        self.len += need;
    }

    pub fn beginMenu(self: *MenuWriter, title: []const u8) void {
        self.put(.menu, 0, 0, 0, 0, title);
    }
    /// `key` is the shortcut character (0 = none); `mods` uses `Mods` bits
    /// (truncated to u8), Cmd is implied when key != 0 and mods == 0.
    pub fn item(self: *MenuWriter, id: u32, title: []const u8, key: u8, mods: u8, flags: u8) void {
        self.put(.item, flags, key, mods, id, title);
    }
    pub fn separator(self: *MenuWriter) void {
        self.put(.separator, 0, 0, 0, 0, "");
    }
    pub fn endMenu(self: *MenuWriter) void {
        self.put(.end, 0, 0, 0, 0, "");
    }
    pub fn bytes(self: *const MenuWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const MenuEntry = struct {
    kind: MenuRecord,
    flags: u8,
    key: u8,
    mods: u8,
    id: u32,
    title: []const u8,
};

pub const MenuReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *MenuReader) ?MenuEntry {
        if (self.pos + 10 > self.buf.len) return null;
        const b = self.buf[self.pos..];
        const len = std.mem.readInt(u16, b[8..10], .little);
        if (self.pos + 10 + len > self.buf.len) return null;
        self.pos += 10 + len;
        return .{
            .kind = @enumFromInt(b[0]),
            .flags = b[1],
            .key = b[2],
            .mods = b[3],
            .id = std.mem.readInt(u32, b[4..8], .little),
            .title = b[10 .. 10 + len],
        };
    }
};

// ---------------------------------------------------------------------------
// Control channel (`window:control`, root only)
// ---------------------------------------------------------------------------

/// Text commands written to `window:control`, one per write:
///   "session-begin <uid> <username>"   show the desktop for this user
///   "session-end"                      back to the login window
///   "lock" / "unlock"
///   "app-launched <pid> <bundle-id>"   (from launchd, for the Dock)
///   "app-exited <pid>"
///   "appearance dark|light"
///   "wallpaper <name>"
pub const control_path = "control";

test "command roundtrip" {
    var buf: [128]u8 = undefined;
    const r = Rect{ .x = 1, .y = 2, .w = 3, .h = 4 };
    var n = encodeCommand(&buf, .damage, std.mem.asBytes(&r)).?;
    n += encodeCommand(buf[n..], .set_title, "Hello").?;
    var it = CommandIterator{ .buf = buf[0..n] };
    const a = it.next().?;
    try std.testing.expectEqual(CommandKind.damage, a.kind);
    try std.testing.expectEqual(@as(usize, 16), a.body.len);
    const b = it.next().?;
    try std.testing.expectEqualStrings("Hello", b.body);
    try std.testing.expect(it.next() == null);
}

test "menu roundtrip" {
    var buf: [256]u8 = undefined;
    var w = MenuWriter{ .buf = &buf };
    w.beginMenu("TextEdit");
    w.item(1, "Quit TextEdit", 'q', 0, 0);
    w.endMenu();
    var r = MenuReader{ .buf = w.bytes() };
    try std.testing.expectEqual(MenuRecord.menu, r.next().?.kind);
    const it = r.next().?;
    try std.testing.expectEqualStrings("Quit TextEdit", it.title);
    try std.testing.expectEqual(@as(u8, 'q'), it.key);
    try std.testing.expectEqual(MenuRecord.end, r.next().?.kind);
}
