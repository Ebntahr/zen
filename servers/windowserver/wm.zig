//! Window management logic (no rendering): stacking order, focus,
//! geometry, hit testing, interactive move/resize, zoom and minimize.

const std = @import("std");
const abi = @import("abi");
const proto = abi.window;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.right(), b.right()) - x0, .h = @max(a.bottom(), b.bottom()) - y0 };
    }
    pub fn inflate(r: Rect, d: i32) Rect {
        return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
    }
    pub fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }
};

/// Height of the server-drawn title bar.
pub const TITLEBAR: i32 = 32;
/// Space reserved for the menu bar at the top of the screen.
pub const MENUBAR: i32 = 30;
/// Space reserved for the Dock at the bottom of the screen.
pub const DOCK_RESERVE: i32 = 84;
/// Corner radius of window frames.
pub const RADIUS: i32 = 14;
/// Invisible grab border for resizing.
pub const RESIZE_BORDER: i32 = 6;
/// Shadow extent around a window (for damage computation).
pub const SHADOW_EXTENT: i32 = 48;

pub const Layer = enum(u8) { desktop = 0, normal = 1, panel = 2, popup = 3, shield = 4 };

pub const Edge = packed struct(u4) { left: bool = false, right: bool = false, top: bool = false, bottom: bool = false };

pub const Hit = union(enum) {
    none,
    content: struct { x: i32, y: i32 },
    titlebar,
    close,
    minimize,
    zoom,
    resize: Edge,
};

pub const EVENT_QUEUE = 256;

pub const Window = struct {
    id: u32,
    owner_pid: u32,
    owner_uid: u32,
    flags: u32,
    layer: Layer,
    /// Content rectangle in screen coordinates.
    content: Rect,
    min_w: i32 = 120,
    min_h: i32 = 60,
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,
    title_height: i32 = TITLEBAR,
    visible: bool = true,
    minimized: bool = false,
    zoomed: bool = false,
    restore: Rect = .{},
    edited: bool = false,
    cursor: proto.Cursor = .arrow,
    /// Shared pixel buffer (w*h premultiplied ARGB).
    pixels: []align(4096) u32 = &.{},
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    /// Bundle id of the owning app (from launchd), for Dock grouping.
    app_id: [96]u8 = [_]u8{0} ** 96,
    app_id_len: usize = 0,
    menu: std.ArrayList(u8) = .empty,
    events: [EVENT_QUEUE]proto.Event = undefined,
    ev_head: usize = 0,
    ev_len: usize = 0,
    /// Content-relative damage since the last composite.
    damage: Rect = .{},

    pub fn titleSlice(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setTitle(self: *Window, t: []const u8) void {
        self.title_len = @min(t.len, self.title.len);
        @memcpy(self.title[0..self.title_len], t[0..self.title_len]);
    }

    pub fn appId(self: *const Window) []const u8 {
        return self.app_id[0..self.app_id_len];
    }

    pub fn hasTitlebar(self: *const Window) bool {
        return self.flags & (proto.Flags.borderless | proto.Flags.popup | proto.Flags.shield | proto.Flags.desktop) == 0 and
            self.flags & proto.Flags.full_size_content == 0;
    }

    pub fn hasControls(self: *const Window) bool {
        return self.flags & (proto.Flags.borderless | proto.Flags.popup | proto.Flags.shield | proto.Flags.desktop) == 0;
    }

    /// Full frame (title bar + content) in screen coordinates.
    pub fn frame(self: *const Window) Rect {
        if (self.hasTitlebar()) {
            return .{ .x = self.content.x, .y = self.content.y - TITLEBAR, .w = self.content.w, .h = self.content.h + TITLEBAR };
        }
        return self.content;
    }

    /// Area affected when the window is drawn (frame + shadow).
    pub fn paintBounds(self: *const Window) Rect {
        if (self.flags & proto.Flags.no_shadow != 0) return self.frame();
        return self.frame().inflate(SHADOW_EXTENT);
    }

    /// Height of the draggable title area measured from the frame top.
    pub fn titleArea(self: *const Window) i32 {
        if (self.hasTitlebar()) return TITLEBAR;
        return self.title_height;
    }

    /// Center of traffic light `i` (0 close, 1 minimize, 2 zoom).
    pub fn trafficLight(self: *const Window, i: usize) struct { x: i32, y: i32 } {
        const f = self.frame();
        const cy = f.y + @divTrunc(@min(self.titleArea(), 52), 2);
        return .{ .x = f.x + 20 + @as(i32, @intCast(i)) * 20, .y = cy };
    }

    pub fn resizable(self: *const Window) bool {
        return self.flags & proto.Flags.resizable != 0 and self.layer == .normal;
    }

    pub fn pushEvent(self: *Window, e: proto.Event) void {
        // Coalesce consecutive mouse moves.
        if (e.kind == .mouse_move and self.ev_len > 0) {
            const last = &self.events[(self.ev_head + self.ev_len - 1) % EVENT_QUEUE];
            if (last.kind == .mouse_move) {
                last.* = e;
                return;
            }
        }
        if (self.ev_len == EVENT_QUEUE) {
            self.ev_head = (self.ev_head + 1) % EVENT_QUEUE;
            self.ev_len -= 1;
        }
        self.events[(self.ev_head + self.ev_len) % EVENT_QUEUE] = e;
        self.ev_len += 1;
    }

    pub fn popEvents(self: *Window, out: []proto.Event) usize {
        const n = @min(out.len, self.ev_len);
        for (0..n) |i| out[i] = self.events[(self.ev_head + i) % EVENT_QUEUE];
        self.ev_head = (self.ev_head + n) % EVENT_QUEUE;
        self.ev_len -= n;
        return n;
    }

    pub fn addDamage(self: *Window, r: Rect) void {
        const clipped = r.intersect(.{ .w = self.content.w, .h = self.content.h });
        self.damage = self.damage.unionWith(clipped);
    }

    /// Hit test a screen point against this window.
    pub fn hitTest(self: *const Window, px: i32, py: i32) Hit {
        const f = self.frame();
        const grab = if (self.resizable() and !self.zoomed) f.inflate(RESIZE_BORDER) else f;
        if (!grab.contains(px, py)) return .none;
        if (self.resizable() and !self.zoomed) {
            var e = Edge{};
            // Corners get a larger grab area.
            const corner = RADIUS;
            if (px < f.x + (if (py < f.y + corner or py >= f.bottom() - corner) corner else 0) and px < f.x + RESIZE_BORDER or px < f.x) e.left = true;
            if (px >= f.right() - RESIZE_BORDER and !f.contains(px - RESIZE_BORDER - 1, py) or px >= f.right()) e.right = true;
            if (py < f.y) e.top = true;
            if (py >= f.bottom() - RESIZE_BORDER and !f.contains(px, py - RESIZE_BORDER - 1) or py >= f.bottom()) e.bottom = true;
            if (px < f.x or px >= f.right() or py < f.y or py >= f.bottom()) {
                if (px < f.x) e.left = true;
                if (px >= f.right()) e.right = true;
                if (py >= f.bottom()) e.bottom = true;
                return .{ .resize = e };
            }
            if (e.bottom and (e.left or e.right)) return .{ .resize = e };
        }
        if (self.hasControls()) {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const c = self.trafficLight(i);
                const dx = px - c.x;
                const dy = py - c.y;
                if (dx * dx + dy * dy <= 8 * 8) {
                    return switch (i) {
                        0 => .close,
                        1 => .minimize,
                        else => .zoom,
                    };
                }
            }
        }
        if (self.hasTitlebar() and py < self.content.y) return .titlebar;
        const lx = px - self.content.x;
        const ly = py - self.content.y;
        return .{ .content = .{ .x = lx, .y = ly } };
    }
};

pub const DragKind = enum { none, move, resize };

pub const Drag = struct {
    kind: DragKind = .none,
    window: u32 = 0,
    edge: Edge = .{},
    start_x: i32 = 0,
    start_y: i32 = 0,
    start_rect: Rect = .{},
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    screen: Rect,
    windows: std.ArrayList(*Window) = .empty,
    /// Window ids from bottom to top.
    order: std.ArrayList(u32) = .empty,
    focused: u32 = 0,
    next_id: u32 = 1,
    drag: Drag = .{},
    cascade: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, screen_w: i32, screen_h: i32) Manager {
        return .{ .allocator = allocator, .screen = .{ .w = screen_w, .h = screen_h } };
    }

    pub fn deinit(self: *Manager) void {
        for (self.windows.items) |w| {
            w.menu.deinit(self.allocator);
            self.allocator.destroy(w);
        }
        self.windows.deinit(self.allocator);
        self.order.deinit(self.allocator);
    }

    /// Area available to normal windows (below the menu bar, above the Dock).
    pub fn workArea(self: *const Manager) Rect {
        return .{ .x = 0, .y = MENUBAR, .w = self.screen.w, .h = self.screen.h - MENUBAR - DOCK_RESERVE };
    }

    pub fn get(self: *const Manager, id: u32) ?*Window {
        for (self.windows.items) |w| if (w.id == id) return w;
        return null;
    }

    pub const CreateOptions = struct {
        pid: u32,
        uid: u32,
        w: i32,
        h: i32,
        x: ?i32 = null,
        y: ?i32 = null,
        flags: u32 = 0,
        min_w: i32 = 120,
        min_h: i32 = 60,
        title: []const u8 = "",
    };

    pub fn create(self: *Manager, o: CreateOptions) !*Window {
        const win = try self.allocator.create(Window);
        const layer: Layer = if (o.flags & proto.Flags.shield != 0)
            .shield
        else if (o.flags & proto.Flags.popup != 0)
            .popup
        else if (o.flags & proto.Flags.desktop != 0)
            .desktop
        else if (o.flags & proto.Flags.panel != 0)
            .panel
        else
            .normal;
        const w = std.math.clamp(o.w, 1, 8192);
        const h = std.math.clamp(o.h, 1, 8192);
        win.* = .{
            .id = self.next_id,
            .owner_pid = o.pid,
            .owner_uid = o.uid,
            .flags = o.flags,
            .layer = layer,
            .content = .{ .w = w, .h = h },
            .min_w = @max(o.min_w, 40),
            .min_h = @max(o.min_h, 20),
            .visible = o.flags & proto.Flags.hidden == 0,
        };
        self.next_id += 1;
        win.setTitle(o.title);
        self.place(win, o.x, o.y);
        try self.windows.append(self.allocator, win);
        try self.order.append(self.allocator, win.id);
        self.sortLayers();
        return win;
    }

    /// Initial placement: explicit, full-screen for shields, otherwise
    /// centered with a cascade offset.
    fn place(self: *Manager, win: *Window, x: ?i32, y: ?i32) void {
        if (win.layer == .shield or win.layer == .desktop) {
            win.content = .{ .x = 0, .y = 0, .w = win.content.w, .h = win.content.h };
            return;
        }
        const wa = self.workArea();
        const tb: i32 = if (win.hasTitlebar()) TITLEBAR else 0;
        if (x != null and y != null) {
            win.content.x = x.?;
            win.content.y = y.? + tb;
            return;
        }
        const cx = wa.x + @divTrunc(wa.w - win.content.w, 2) + self.cascade;
        const cy = wa.y + @divTrunc(wa.h - win.content.h - tb, 3) + self.cascade;
        self.cascade = @mod(self.cascade + 28, 28 * 6);
        win.content.x = @max(wa.x, cx);
        win.content.y = @max(wa.y, cy) + tb;
    }

    fn sortLayers(self: *Manager) void {
        // Stable insertion sort by layer keeps relative order within layers.
        const ids = self.order.items;
        var i: usize = 1;
        while (i < ids.len) : (i += 1) {
            const cur = ids[i];
            const cl = @intFromEnum(self.get(cur).?.layer);
            var j = i;
            while (j > 0 and @intFromEnum(self.get(ids[j - 1]).?.layer) > cl) : (j -= 1) ids[j] = ids[j - 1];
            ids[j] = cur;
        }
    }

    pub fn destroy(self: *Manager, id: u32) void {
        for (self.order.items, 0..) |oid, i| {
            if (oid == id) {
                _ = self.order.orderedRemove(i);
                break;
            }
        }
        for (self.windows.items, 0..) |w, i| {
            if (w.id == id) {
                w.menu.deinit(self.allocator);
                self.allocator.destroy(w);
                _ = self.windows.swapRemove(i);
                break;
            }
        }
        if (self.drag.window == id) self.drag = .{};
        if (self.focused == id) {
            self.focused = 0;
            self.focusTopmost();
        }
    }

    /// Raise a window to the top of its layer.
    pub fn raise(self: *Manager, id: u32) void {
        for (self.order.items, 0..) |oid, i| {
            if (oid == id) {
                _ = self.order.orderedRemove(i);
                self.order.append(self.allocator, id) catch {};
                break;
            }
        }
        self.sortLayers();
    }

    /// Focus a window; returns the previously focused id.
    pub fn focus(self: *Manager, id: u32) u32 {
        const prev = self.focused;
        self.focused = id;
        return prev;
    }

    pub fn focusTopmost(self: *Manager) void {
        var i = self.order.items.len;
        while (i > 0) {
            i -= 1;
            const w = self.get(self.order.items[i]).?;
            if (w.visible and !w.minimized and (w.layer == .normal or w.layer == .shield)) {
                self.focused = w.id;
                return;
            }
        }
        self.focused = 0;
    }

    /// Topmost visible window under a screen point.
    pub fn windowAt(self: *const Manager, px: i32, py: i32) ?*Window {
        var i = self.order.items.len;
        while (i > 0) {
            i -= 1;
            const w = self.get(self.order.items[i]).?;
            if (!w.visible or w.minimized) continue;
            if (w.hitTest(px, py) != .none) return w;
        }
        return null;
    }

    pub fn beginDrag(self: *Manager, win: *Window, kind: DragKind, edge: Edge, px: i32, py: i32) void {
        self.drag = .{ .kind = kind, .window = win.id, .edge = edge, .start_x = px, .start_y = py, .start_rect = win.content };
    }

    /// Update an interactive move/resize. Returns the window whose geometry
    /// changed and whether its size changed.
    pub fn updateDrag(self: *Manager, px: i32, py: i32) ?struct { win: *Window, resized: bool, old_bounds: Rect } {
        if (self.drag.kind == .none) return null;
        const win = self.get(self.drag.window) orelse {
            self.drag = .{};
            return null;
        };
        const old = win.paintBounds();
        const dx = px - self.drag.start_x;
        const dy = py - self.drag.start_y;
        const s = self.drag.start_rect;
        switch (self.drag.kind) {
            .move => {
                win.content.x = s.x + dx;
                // Keep the title bar reachable below the menu bar.
                win.content.y = @max(s.y + dy, MENUBAR + (if (win.hasTitlebar()) TITLEBAR else 0));
                win.zoomed = false;
                return .{ .win = win, .resized = false, .old_bounds = old };
            },
            .resize => {
                var r = s;
                const e = self.drag.edge;
                if (e.right) r.w = @max(win.min_w, s.w + dx);
                if (e.bottom) r.h = @max(win.min_h, s.h + dy);
                if (e.left) {
                    const nw = @max(win.min_w, s.w - dx);
                    r.x = s.x + s.w - nw;
                    r.w = nw;
                }
                if (e.top) {
                    const nh = @max(win.min_h, s.h - dy);
                    r.y = s.y + s.h - nh;
                    r.h = nh;
                }
                const resized = r.w != win.content.w or r.h != win.content.h;
                win.content = r;
                return .{ .win = win, .resized = resized, .old_bounds = old };
            },
            .none => return null,
        }
    }

    pub fn endDrag(self: *Manager) void {
        self.drag = .{};
    }

    /// Toggle zoom: fill the work area or restore the previous frame.
    pub fn toggleZoom(self: *Manager, win: *Window) void {
        if (win.zoomed) {
            win.content = win.restore;
            win.zoomed = false;
            return;
        }
        win.restore = win.content;
        const wa = self.workArea().inflate(-6);
        const tb: i32 = if (win.hasTitlebar()) TITLEBAR else 0;
        win.content = .{ .x = wa.x, .y = wa.y + tb, .w = wa.w, .h = wa.h - tb };
        win.zoomed = true;
    }

    /// Windows belonging to an app, bottom to top.
    pub fn windowsOf(self: *const Manager, pid: u32, out: []*Window) usize {
        var n: usize = 0;
        for (self.order.items) |id| {
            const w = self.get(id).?;
            if (w.owner_pid == pid and n < out.len) {
                out[n] = w;
                n += 1;
            }
        }
        return n;
    }
};

test "create, stack and focus" {
    const a = std.testing.allocator;
    var m = Manager.init(a, 1280, 800);
    defer m.deinit();
    const w1 = try m.create(.{ .pid = 10, .uid = 501, .w = 400, .h = 300, .flags = proto.Flags.resizable, .title = "One" });
    const w2 = try m.create(.{ .pid = 11, .uid = 501, .w = 400, .h = 300, .flags = proto.Flags.resizable, .title = "Two" });
    const shield = try m.create(.{ .pid = 1, .uid = 0, .w = 1280, .h = 800, .flags = proto.Flags.shield });
    try std.testing.expectEqual(shield.id, m.order.items[m.order.items.len - 1]);
    m.raise(w1.id);
    // The shield stays on top even after raising a normal window.
    try std.testing.expectEqual(shield.id, m.order.items[2]);
    try std.testing.expectEqual(w1.id, m.order.items[1]);
    m.destroy(shield.id);
    m.focusTopmost();
    try std.testing.expectEqual(w1.id, m.focused);
    _ = w2;
}

test "hit testing" {
    const a = std.testing.allocator;
    var m = Manager.init(a, 1280, 800);
    defer m.deinit();
    const w = try m.create(.{ .pid = 10, .uid = 501, .w = 400, .h = 300, .x = 100, .y = 100, .flags = proto.Flags.resizable });
    const f = w.frame();
    try std.testing.expectEqual(@as(i32, 100), f.y);
    try std.testing.expectEqual(Hit.close, w.hitTest(f.x + 20, f.y + 16));
    try std.testing.expectEqual(Hit.titlebar, w.hitTest(f.x + 200, f.y + 10));
    switch (w.hitTest(f.x + 50, f.y + 100)) {
        .content => |c| {
            try std.testing.expectEqual(@as(i32, 50), c.x);
            try std.testing.expectEqual(@as(i32, 100 - TITLEBAR), c.y);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(w.hitTest(f.right() + 3, f.y + 100) == .resize);
    try std.testing.expect(w.hitTest(f.x - 20, f.y) == .none);
}

test "drag move and resize" {
    const a = std.testing.allocator;
    var m = Manager.init(a, 1280, 800);
    defer m.deinit();
    const w = try m.create(.{ .pid = 10, .uid = 501, .w = 400, .h = 300, .x = 100, .y = 100, .flags = proto.Flags.resizable, .min_w = 200, .min_h = 100 });
    m.beginDrag(w, .move, .{}, 150, 110);
    _ = m.updateDrag(200, 150).?;
    try std.testing.expectEqual(@as(i32, 150), w.content.x);
    m.endDrag();
    m.beginDrag(w, .resize, .{ .right = true, .bottom = true }, 0, 0);
    const r = m.updateDrag(-500, 50).?;
    try std.testing.expect(r.resized);
    try std.testing.expectEqual(@as(i32, 200), w.content.w);
    try std.testing.expectEqual(@as(i32, 350), w.content.h);
    m.toggleZoom(w);
    try std.testing.expect(w.zoomed);
    m.toggleZoom(w);
    try std.testing.expectEqual(@as(i32, 200), w.content.w);
}
