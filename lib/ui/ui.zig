//! Immediate-mode GUI toolkit for Zen apps.
//!
//!     var ui = try Ui.init(gpa, &window, &fonts);
//!     while (!ui.quit) {
//!         ui.beginFrame(window.waitEvents(-1));
//!         ui.clear();
//!         if (ui.button("ok", rect, "OK", .{ .style = .primary })) …
//!         ui.endFrame();
//!     }
//!
//! Widgets are identified by string ids (hashed). Everything is redrawn
//! each frame; frames only happen when events arrive.

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const abi = @import("abi");
const client = @import("client.zig");
const theme_mod = @import("theme.zig");
const fonts_mod = @import("fonts.zig");

pub const Rect = gfx.Rect;
pub const Theme = theme_mod.Theme;
pub const Weight = fonts_mod.Weight;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const Color = gfx.Color;
const shapes = gfx.shapes;

pub const Id = u64;

pub fn hashId(s: []const u8) Id {
    return std.hash.Wyhash.hash(0x5A454E, s);
}

pub fn hashIdx(s: []const u8, i: usize) Id {
    return std.hash.Wyhash.hash(i +% 0x9E3779B97F4A7C15, s);
}

/// Straight 0xAARRGGBB → premultiplied.
pub fn pm(c: u32) u32 {
    return Color.withAlpha(c | 0xFF000000, @truncate(c >> 24));
}

pub fn withAlpha(c: u32, a: u8) u32 {
    return (c & 0x00FFFFFF) | (@as(u32, @intCast(@as(u32, a) * (c >> 24) / 255)) << 24);
}

pub const Align = enum { left, center, right };

pub const KeyPress = struct {
    code: u16,
    mods: u32,
    repeat: bool,
};

pub const TextState = struct {
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    scroll: f32 = 0,

    pub fn text(self: *const TextState) []const u8 {
        return self.buf.items;
    }

    pub fn set(self: *TextState, allocator: std.mem.Allocator, s: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(allocator, s) catch {};
        self.cursor = s.len;
        self.anchor = s.len;
        self.scroll = 0;
    }

    pub fn deinit(self: *TextState, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    fn selection(self: *const TextState) struct { a: usize, b: usize } {
        return .{ .a = @min(self.cursor, self.anchor), .b = @max(self.cursor, self.anchor) };
    }

    pub fn deleteSelectionAlloc(self: *TextState, allocator: std.mem.Allocator) bool {
        const s = self.selection();
        if (s.a == s.b) return false;
        self.buf.replaceRange(allocator, s.a, s.b - s.a, "") catch {};
        self.cursor = s.a;
        self.anchor = s.a;
        return true;
    }
};

pub const ScrollState = struct {
    offset: f32 = 0,
    content: f32 = 0,
    view: f32 = 0,

    pub fn clamp(self: *ScrollState) void {
        const max = @max(0, self.content - self.view);
        self.offset = std.math.clamp(self.offset, 0, max);
    }

    pub fn scrollTo(self: *ScrollState, top: f32, bottom: f32) void {
        if (top < self.offset) self.offset = top;
        if (bottom > self.offset + self.view) self.offset = bottom - self.view;
        self.clamp();
    }
};

pub const ButtonStyle = enum { normal, primary, plain, destructive, toolbar };

pub const TextFieldResult = packed struct { changed: bool = false, submitted: bool = false };

pub const Ui = struct {
    allocator: std.mem.Allocator,
    win: *client.Window,
    fonts: *fonts_mod.FontSet,
    theme: Theme,
    accent_override: ?u32 = null,
    canvas: gfx.Canvas,

    // Input for the current frame.
    mouse_x: i32 = -1000,
    mouse_y: i32 = -1000,
    mouse_down: bool = false,
    mouse_pressed: bool = false,
    mouse_released: bool = false,
    right_pressed: bool = false,
    click_count: i32 = 0,
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    mods: u32 = 0,
    keys: [32]KeyPress = undefined,
    key_count: usize = 0,
    text_in: [256]u8 = undefined,
    text_len: usize = 0,
    menu_id: ?u32 = null,
    focused: bool = true,

    // Widget interaction state.
    hot: Id = 0,
    active: Id = 0,
    focus: Id = 0,
    /// Set by a widget that consumed the key events this frame.
    keys_consumed: bool = false,

    close_requested: bool = false,
    quit: bool = false,
    resized: bool = false,
    cursor: abi.window.Cursor = .arrow,
    last_cursor: abi.window.Cursor = .arrow,
    /// Widgets can request another frame (e.g. to settle hover state).
    want_frame: bool = false,
    shadows: std.AutoHashMapUnmanaged(u32, *gfx.ShadowMask) = .empty,

    pub fn init(allocator: std.mem.Allocator, win: *client.Window, fonts: *fonts_mod.FontSet) Ui {
        return .{
            .allocator = allocator,
            .win = win,
            .fonts = fonts,
            .theme = Theme.light(.blue),
            .canvas = canvasFor(win),
        };
    }

    pub fn deinit(self: *Ui) void {
        var it = self.shadows.valueIterator();
        while (it.next()) |m| {
            m.*.deinit(self.allocator);
            self.allocator.destroy(m.*);
        }
        self.shadows.deinit(self.allocator);
    }

    fn canvasFor(win: *client.Window) gfx.Canvas {
        return gfx.Canvas.init(win.pixels, @intCast(win.width), @intCast(win.height), @intCast(win.width));
    }

    pub fn width(self: *const Ui) i32 {
        return self.win.width;
    }

    pub fn height(self: *const Ui) i32 {
        return self.win.height;
    }

    pub fn bounds(self: *const Ui) Rect {
        return Rect.init(0, 0, self.win.width, self.win.height);
    }

    pub fn setDark(self: *Ui, dark: bool, accent: ?u32) void {
        self.theme = Theme.get(dark, .blue);
        if (accent) |a| self.theme.accent = a;
    }

    /// Process a batch of events before drawing.
    pub fn beginFrame(self: *Ui, events: []const client.Event) void {
        self.mouse_pressed = false;
        self.mouse_released = false;
        self.right_pressed = false;
        self.scroll_dx = 0;
        self.scroll_dy = 0;
        self.key_count = 0;
        self.text_len = 0;
        self.menu_id = null;
        self.keys_consumed = false;
        self.resized = false;
        self.want_frame = false;
        self.cursor = .arrow;
        for (events) |e| {
            switch (e.kind) {
                .mouse_move => {
                    self.mouse_x = e.a;
                    self.mouse_y = e.b;
                    self.mods = e.mods;
                },
                .mouse_down => {
                    self.mouse_x = e.a;
                    self.mouse_y = e.b;
                    self.mods = e.mods;
                    if (e.c == 2) {
                        self.right_pressed = true;
                    } else {
                        self.mouse_down = true;
                        self.mouse_pressed = true;
                        self.click_count = e.d;
                    }
                },
                .mouse_up => {
                    self.mouse_x = e.a;
                    self.mouse_y = e.b;
                    if (e.c != 2) {
                        self.mouse_down = false;
                        self.mouse_released = true;
                    }
                },
                .mouse_leave => {
                    if (!self.mouse_down) {
                        self.mouse_x = -1000;
                        self.mouse_y = -1000;
                    }
                },
                .scroll => {
                    self.mouse_x = e.a;
                    self.mouse_y = e.b;
                    self.scroll_dx += @floatFromInt(e.c);
                    self.scroll_dy += @floatFromInt(e.d);
                },
                .key_down => {
                    self.mods = e.mods;
                    if (self.key_count < self.keys.len) {
                        self.keys[self.key_count] = .{ .code = @intCast(e.a), .mods = e.mods, .repeat = e.b != 0 };
                        self.key_count += 1;
                    }
                    const t = e.textSlice();
                    if (t.len > 0 and self.text_len + t.len <= self.text_in.len and t[0] >= 0x20 and t[0] != 0x7f) {
                        @memcpy(self.text_in[self.text_len .. self.text_len + t.len], t);
                        self.text_len += t.len;
                    }
                },
                .key_up => self.mods = e.mods,
                .focus => self.focused = e.a != 0,
                .resize => self.resized = true,
                .close_request => self.close_requested = true,
                .quit_request => self.quit = true,
                .menu => self.menu_id = @intCast(e.a),
                .appearance => {
                    self.theme = Theme.get(e.a != 0, .blue);
                    self.theme.accent = @bitCast(e.b);
                },
                else => {},
            }
        }
        self.canvas = canvasFor(self.win);
        self.hot = 0;
        if (self.mouse_released and !self.mouse_down) {
            // `active` is cleared at the end of the frame so widgets can see the release.
        }
    }

    pub fn endFrame(self: *Ui) void {
        // Full-size-content windows: a double-click on empty title-area space
        // zooms. The server leaves this to the app so that double-clicks on
        // toolbar controls stay with the controls.
        const F = abi.window.Flags;
        if (self.mouse_pressed and self.click_count == 2 and self.hot == 0 and
            self.mouse_y >= 0 and self.mouse_y < self.win.title_height and
            self.win.flags & F.full_size_content != 0 and self.win.flags & F.resizable != 0)
        {
            self.win.zoom();
        }
        if (self.mouse_released) self.active = 0;
        if (self.mouse_pressed and self.hot == 0) self.focus = 0;
        if (self.cursor != self.last_cursor) {
            self.win.setCursor(self.cursor);
            self.last_cursor = self.cursor;
        }
        self.win.damageAll();
        self.win.flush();
    }

    // ------------------------------------------------------------------
    // Input helpers
    // ------------------------------------------------------------------

    pub fn hovering(self: *const Ui, r: Rect) bool {
        return r.contains(self.mouse_x, self.mouse_y) and self.canvas.clip.contains(self.mouse_x, self.mouse_y);
    }

    /// Standard click behaviour. Returns true when the widget was clicked.
    pub fn interact(self: *Ui, id: Id, r: Rect) bool {
        const over = self.hovering(r);
        if (over) self.hot = id;
        if (over and self.mouse_pressed) self.active = id;
        return self.active == id and self.mouse_released and over;
    }

    pub fn isActive(self: *const Ui, id: Id) bool {
        return self.active == id and self.mouse_down;
    }

    pub fn keyPressed(self: *const Ui, code: u16) bool {
        for (self.keys[0..self.key_count]) |k| if (k.code == code) return true;
        return false;
    }

    pub fn shortcut(self: *const Ui, code: u16, mods: u32) bool {
        for (self.keys[0..self.key_count]) |k| {
            if (k.code == code and (k.mods & (Mods.cmd | Mods.ctrl | Mods.alt | Mods.shift)) == mods) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Drawing primitives
    // ------------------------------------------------------------------

    pub fn clear(self: *Ui, color: u32) void {
        self.canvas.fillRect(self.canvas.clip, pm(color));
    }

    pub fn fillRect(self: *Ui, r: Rect, color: u32) void {
        self.canvas.fillRect(r, pm(color));
    }

    pub fn fillRound(self: *Ui, r: Rect, radius: f32, color: u32) void {
        shapes.fillRoundRect(self.canvas, r, radius, pm(color));
    }

    pub fn strokeRound(self: *Ui, r: Rect, radius: f32, w: f32, color: u32) void {
        shapes.strokeRoundRect(self.canvas, r, radius, w, pm(color));
    }

    pub fn fillCircle(self: *Ui, cx: f32, cy: f32, r: f32, color: u32) void {
        shapes.fillCircle(self.canvas, cx, cy, r, pm(color));
    }

    pub fn line(self: *Ui, x0: f32, y0: f32, x1: f32, y1: f32, w: f32, color: u32) void {
        shapes.drawLine(self.canvas, x0, y0, x1, y1, w, pm(color));
    }

    pub fn hline(self: *Ui, x0: i32, x1: i32, y: i32, color: u32) void {
        self.canvas.fillRect(Rect.init(x0, y, x1 - x0, 1), pm(color));
    }

    /// Soft drop shadow under a rounded rectangle (masks are cached).
    pub fn shadow(self: *Ui, r: Rect, radius_in: f32, blur: f32, dy: i32, color: u32) void {
        // The 9-slice mask needs the shape to be larger than both corners.
        const max_r: f32 = @floatFromInt(@max(0, @divFloor(@min(r.w, r.h) - 1, 2)));
        const radius = @floor(@min(radius_in, max_r));
        const key: u32 = (@as(u32, @intFromFloat(@round(radius * 2))) << 16) | @as(u32, @intFromFloat(@round(blur * 2)));
        const mask = self.shadows.get(key) orelse blk: {
            const m = self.allocator.create(gfx.ShadowMask) catch return;
            m.* = gfx.ShadowMask.init(self.allocator, radius, blur) catch {
                self.allocator.destroy(m);
                return;
            };
            self.shadows.put(self.allocator, key, m) catch {};
            break :blk m;
        };
        if (!mask.fits(r)) return;
        mask.draw(self.canvas, r.offset(0, dy), pm(color), null);
    }

    pub fn pushClip(self: *Ui, r: Rect) Rect {
        const old = self.canvas.clip;
        self.canvas.clip = self.canvas.clip.intersect(r);
        return old;
    }

    pub fn popClip(self: *Ui, old: Rect) void {
        self.canvas.clip = old;
    }

    fn target(self: *Ui) font.Target {
        var t = font.Target.init(self.win.pixels, @intCast(self.win.width), @intCast(self.win.height), @intCast(self.win.width));
        const c = self.canvas.clip;
        t.clip = .{ .x0 = c.x, .y0 = c.y, .x1 = c.x + c.w, .y1 = c.y + c.h };
        return t;
    }

    pub fn face(self: *Ui, weight: Weight, size: f32) *font.Face {
        return self.fonts.face(weight, size);
    }

    pub fn measure(self: *Ui, s: []const u8, weight: Weight, size: f32) f32 {
        return self.face(weight, size).measure(s);
    }

    pub const TextOpts = struct {
        size: f32 = 13,
        weight: Weight = .regular,
        color: ?u32 = null,
        @"align": Align = .left,
        truncate: bool = true,
    };

    /// Draw a single line of text vertically centered in `r`.
    pub fn text(self: *Ui, r: Rect, s: []const u8, o: TextOpts) void {
        const f = self.face(o.weight, o.size);
        const w = f.measure(s);
        const maxw: f32 = @floatFromInt(r.w);
        var x: f32 = @floatFromInt(r.x);
        switch (o.@"align") {
            .left => {},
            .center => x += @max(0, (maxw - w) / 2),
            .right => x += @max(0, maxw - w),
        }
        const cap = f.cap_height;
        const baseline = @as(f32, @floatFromInt(r.y)) + (@as(f32, @floatFromInt(r.h)) + cap) / 2;
        const color = pm(o.color orelse self.theme.label);
        const old = self.pushClip(r);
        defer self.popClip(old);
        if (o.truncate and w > maxw) {
            _ = font.drawTextTruncated(self.target(), f, s, x, @round(baseline), maxw, color);
        } else {
            _ = font.drawText(self.target(), f, s, x, @round(baseline), color);
        }
    }

    /// Draw text at a baseline position; returns the pen x after the text.
    pub fn textAt(self: *Ui, x: f32, baseline: f32, s: []const u8, weight: Weight, size: f32, color: u32) f32 {
        return font.drawText(self.target(), self.face(weight, size), s, x, baseline, pm(color));
    }

    /// Word-wrapped paragraph; returns the height used.
    pub fn paragraph(self: *Ui, r: Rect, s: []const u8, o: TextOpts) i32 {
        const f = self.face(o.weight, o.size);
        const n = font.drawTextWrapped(self.target(), f, s, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), pm(o.color orelse self.theme.label));
        return @intFromFloat(@ceil(@as(f32, @floatFromInt(n)) * f.line_height));
    }

    // ------------------------------------------------------------------
    // Widgets
    // ------------------------------------------------------------------

    pub const ButtonOpts = struct {
        style: ButtonStyle = .normal,
        enabled: bool = true,
        size: f32 = 13,
    };

    pub fn button(self: *Ui, id_str: []const u8, r: Rect, label: []const u8, o: ButtonOpts) bool {
        const id = hashId(id_str);
        const clicked = o.enabled and self.interact(id, r);
        const pressed = self.isActive(id) and self.hovering(r);
        const t = self.theme;
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        var fg = t.label;
        switch (o.style) {
            .primary, .destructive => {
                const base = if (o.style == .primary) t.accent else 0xFFFF3B30;
                self.shadow(r, radius, 3, 1, 0x30000000);
                self.fillRound(r, radius, if (pressed) darken(base, 30) else base);
                // Subtle top highlight.
                shapes.fillRoundRect(self.canvas, Rect.init(r.x + 1, r.y + 1, r.w - 2, @divTrunc(r.h, 2)), radius - 1, pm(0x1FFFFFFF));
                fg = 0xFFFFFFFF;
            },
            .normal => {
                self.shadow(r, radius, 2, 1, if (t.dark) 0x40000000 else 0x1F000000);
                self.fillRound(r, radius, if (pressed) t.control_pressed else t.control_bg);
                self.strokeRound(r, radius, 0.75, t.control_border);
            },
            .toolbar => {
                if (self.hovering(r) or pressed) self.fillRound(r, radius, if (pressed) t.selection_inactive else t.hover);
            },
            .plain => {
                fg = t.accent;
            },
        }
        if (!o.enabled) fg = t.tertiary_label;
        if (self.hot == id and o.enabled) self.cursor = .arrow;
        self.text(r, label, .{ .size = o.size, .weight = if (o.style == .primary) .semibold else .medium, .color = fg, .@"align" = .center });
        return clicked;
    }

    /// macOS-style switch. Returns true when toggled.
    pub fn toggle(self: *Ui, id_str: []const u8, x: i32, y: i32, value: *bool) bool {
        const r = Rect.init(x, y, 40, 24);
        const id = hashId(id_str);
        const clicked = self.interact(id, r);
        if (clicked) value.* = !value.*;
        const t = self.theme;
        const off_track: u32 = if (t.dark) 0xFF48484C else 0xFFE3E3E8;
        self.fillRound(r, 12, if (value.*) t.accent else off_track);
        const kx: f32 = if (value.*) @floatFromInt(x + 28) else @floatFromInt(x + 12);
        const ky: f32 = @floatFromInt(y + 12);
        shapes.fillCircle(self.canvas, kx, ky + 1, 10.5, pm(0x26000000));
        shapes.fillCircle(self.canvas, kx, ky, 10, pm(0xFFFFFFFF));
        return clicked;
    }

    pub fn checkbox(self: *Ui, id_str: []const u8, r: Rect, label: []const u8, value: *bool) bool {
        const id = hashId(id_str);
        const clicked = self.interact(id, r);
        if (clicked) value.* = !value.*;
        const t = self.theme;
        const box = Rect.init(r.x, r.y + @divTrunc(r.h - 16, 2), 16, 16);
        if (value.*) {
            self.fillRound(box, 4, t.accent);
            const bx: f32 = @floatFromInt(box.x);
            const by: f32 = @floatFromInt(box.y);
            self.line(bx + 4, by + 8.5, bx + 7, by + 11.5, 2, 0xFFFFFFFF);
            self.line(bx + 7, by + 11.5, bx + 12.5, by + 4.5, 2, 0xFFFFFFFF);
        } else {
            self.fillRound(box, 4, t.control_bg);
            self.strokeRound(box, 4, 1, if (t.dark) 0x40FFFFFF else 0x40000000);
        }
        self.text(Rect.init(r.x + 24, r.y, r.w - 24, r.h), label, .{});
        return clicked;
    }

    pub fn slider(self: *Ui, id_str: []const u8, r: Rect, value: *f32, min: f32, max: f32) bool {
        const id = hashId(id_str);
        _ = self.interact(id, r);
        var changed = false;
        const fw: f32 = @floatFromInt(r.w - 20);
        if (self.isActive(id)) {
            const t = std.math.clamp(@as(f32, @floatFromInt(self.mouse_x - r.x - 10)) / fw, 0, 1);
            const nv = min + t * (max - min);
            if (nv != value.*) {
                value.* = nv;
                changed = true;
            }
        }
        const t = self.theme;
        const frac = if (max > min) std.math.clamp((value.* - min) / (max - min), 0, 1) else 0;
        const cy = r.y + @divTrunc(r.h, 2);
        const track = Rect.init(r.x + 10, cy - 2, r.w - 20, 4);
        self.fillRound(track, 2, if (t.dark) 0xFF48484C else 0xFFDCDCE0);
        const filled = Rect.init(track.x, track.y, @intFromFloat(fw * frac), 4);
        self.fillRound(filled, 2, t.accent);
        const kx = @as(f32, @floatFromInt(track.x)) + fw * frac;
        shapes.fillCircle(self.canvas, kx, @as(f32, @floatFromInt(cy)) + 1, 10.5, pm(0x2A000000));
        shapes.fillCircle(self.canvas, kx, @floatFromInt(cy), 10, pm(0xFFFFFFFF));
        return changed;
    }

    pub fn segmented(self: *Ui, id_str: []const u8, r: Rect, items: []const []const u8, selected: *usize) bool {
        const t = self.theme;
        const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
        self.fillRound(r, radius, if (t.dark) 0xFF2C2C2F else 0xFFE8E8EC);
        const n: i32 = @intCast(items.len);
        if (n == 0) return false;
        const seg_w = @divTrunc(r.w - 4, n);
        var changed = false;
        for (items, 0..) |label, i| {
            const sr = Rect.init(r.x + 2 + @as(i32, @intCast(i)) * seg_w, r.y + 2, seg_w, r.h - 4);
            if (self.interact(hashIdx(id_str, i), sr) and selected.* != i) {
                selected.* = i;
                changed = true;
            }
            if (selected.* == i) {
                self.shadow(sr, radius - 2, 2, 1, 0x26000000);
                self.fillRound(sr, radius - 2, if (t.dark) 0xFF5A5A5E else 0xFFFFFFFF);
            }
            self.text(sr, label, .{ .weight = if (selected.* == i) .semibold else .medium, .@"align" = .center, .color = t.label });
        }
        return changed;
    }

    pub const FieldOpts = struct {
        placeholder: []const u8 = "",
        secure: bool = false,
        size: f32 = 13,
        /// Rounded "search"/glass look.
        capsule: bool = false,
        /// No background, border or focus ring (field drawn over glass).
        plain: bool = false,
    };

    /// Single-line text field with selection, clipboard and scrolling.
    pub fn textField(self: *Ui, id_str: []const u8, r: Rect, st: *TextState, o: FieldOpts) TextFieldResult {
        const id = hashId(id_str);
        var res = TextFieldResult{};
        const over = self.hovering(r);
        if (over) {
            self.hot = id;
            self.cursor = .ibeam;
        }
        const f = self.face(.regular, o.size);
        var display_buf: [1024]u8 = undefined;
        const shown = displayText(st, o.secure, &display_buf);
        const pad: f32 = if (o.capsule) 14 else 8;
        const inner_x = @as(f32, @floatFromInt(r.x)) + pad;
        const inner_w = @as(f32, @floatFromInt(r.w)) - 2 * pad;

        if (self.mouse_pressed and over) {
            self.focus = id;
            self.active = id;
            const idx = mapIndex(st, o.secure, f.indexAtX(shown, @as(f32, @floatFromInt(self.mouse_x)) - inner_x + st.scroll));
            if (self.click_count >= 2) {
                st.anchor = 0;
                st.cursor = st.buf.items.len;
            } else {
                st.cursor = idx;
                if (self.mods & Mods.shift == 0) st.anchor = idx;
            }
        } else if (self.active == id and self.mouse_down) {
            st.cursor = mapIndex(st, o.secure, f.indexAtX(shown, @as(f32, @floatFromInt(self.mouse_x)) - inner_x + st.scroll));
        }

        const has_focus = self.focus == id and self.focused;
        if (self.focus == id and !self.keys_consumed) {
            if (self.editKeys(st, false)) res.changed = true;
            for (self.keys[0..self.key_count]) |k| {
                if (k.code == Key.enter or k.code == Key.kpenter) res.submitted = true;
            }
            self.keys_consumed = true;
        }

        const t = self.theme;
        const radius: f32 = if (o.capsule) @as(f32, @floatFromInt(r.h)) / 2 else 7;
        if (!o.plain) {
            if (has_focus) shapes.fillRoundRect(self.canvas, Rect.init(r.x - 3, r.y - 3, r.w + 6, r.h + 6), radius + 3, pm(withAlpha(t.accent, 110)));
            self.fillRound(r, radius, t.field_bg);
            self.strokeRound(r, radius, 0.75, t.control_border);
        }

        // Keep the caret visible.
        const shown2 = displayText(st, o.secure, &display_buf);
        const caret_x = f.xAtIndex(shown2, displayIndex(st, o.secure, st.cursor));
        if (caret_x - st.scroll > inner_w) st.scroll = caret_x - inner_w;
        if (caret_x - st.scroll < 0) st.scroll = caret_x;
        if (st.scroll < 0) st.scroll = 0;

        const old = self.pushClip(Rect.init(r.x + 2, r.y, r.w - 4, r.h));
        defer self.popClip(old);
        const baseline = @round(@as(f32, @floatFromInt(r.y)) + (@as(f32, @floatFromInt(r.h)) + f.cap_height) / 2);
        const tx = inner_x - st.scroll;
        const sel = st.selection();
        if (has_focus and sel.a != sel.b) {
            const x0 = f.xAtIndex(shown2, displayIndex(st, o.secure, sel.a));
            const x1 = f.xAtIndex(shown2, displayIndex(st, o.secure, sel.b));
            self.fillRect(Rect.init(@intFromFloat(tx + x0), r.y + 4, @intFromFloat(@max(1, x1 - x0)), r.h - 8), withAlpha(t.accent, 90));
        }
        if (st.buf.items.len == 0) {
            _ = font.drawText(self.target(), f, o.placeholder, inner_x, baseline, pm(t.tertiary_label));
        } else {
            _ = font.drawText(self.target(), f, shown2, tx, baseline, pm(t.label));
        }
        if (has_focus) {
            const cx: i32 = @intFromFloat(@round(tx + caret_x));
            self.fillRect(Rect.init(cx, r.y + 5, 2, r.h - 10), t.accent);
        }
        return res;
    }

    /// Shared editing keys for single- and multi-line editors.
    pub fn editKeys(self: *Ui, st: *TextState, multiline: bool) bool {
        var changed = false;
        const a = self.allocator;
        for (self.keys[0..self.key_count]) |k| {
            const shift = k.mods & Mods.shift != 0;
            const cmd = k.mods & (Mods.cmd | Mods.ctrl) != 0;
            switch (k.code) {
                Key.left => {
                    if (!shift and st.cursor != st.anchor) {
                        st.cursor = @min(st.cursor, st.anchor);
                    } else if (cmd) {
                        st.cursor = lineStart(st.buf.items, st.cursor);
                    } else if (st.cursor > 0) {
                        st.cursor = font.utf8.prevBoundary(st.buf.items, st.cursor);
                    }
                    if (!shift) st.anchor = st.cursor;
                },
                Key.right => {
                    if (!shift and st.cursor != st.anchor) {
                        st.cursor = @max(st.cursor, st.anchor);
                    } else if (cmd) {
                        st.cursor = lineEnd(st.buf.items, st.cursor);
                    } else if (st.cursor < st.buf.items.len) {
                        st.cursor = font.utf8.nextBoundary(st.buf.items, st.cursor);
                    }
                    if (!shift) st.anchor = st.cursor;
                },
                Key.home => {
                    st.cursor = if (multiline) lineStart(st.buf.items, st.cursor) else 0;
                    if (!shift) st.anchor = st.cursor;
                },
                Key.end => {
                    st.cursor = if (multiline) lineEnd(st.buf.items, st.cursor) else st.buf.items.len;
                    if (!shift) st.anchor = st.cursor;
                },
                Key.backspace => {
                    if (!st.deleteSelectionAlloc(a)) {
                        if (st.cursor > 0) {
                            const p = font.utf8.prevBoundary(st.buf.items, st.cursor);
                            st.buf.replaceRange(a, p, st.cursor - p, "") catch {};
                            st.cursor = p;
                            st.anchor = p;
                        }
                    }
                    changed = true;
                },
                Key.delete => {
                    if (!st.deleteSelectionAlloc(a)) {
                        if (st.cursor < st.buf.items.len) {
                            const n = font.utf8.nextBoundary(st.buf.items, st.cursor);
                            st.buf.replaceRange(a, st.cursor, n - st.cursor, "") catch {};
                        }
                    }
                    changed = true;
                },
                Key.a => if (cmd) {
                    st.anchor = 0;
                    st.cursor = st.buf.items.len;
                },
                Key.c, Key.x => if (cmd) {
                    const s = st.selection();
                    if (s.b > s.a) client.clipboardSet(st.buf.items[s.a..s.b]) catch {};
                    if (k.code == Key.x and st.deleteSelectionAlloc(a)) changed = true;
                },
                Key.v => if (cmd) {
                    if (client.clipboardGet(a)) |clip| {
                        defer a.free(clip);
                        _ = st.deleteSelectionAlloc(a);
                        var clean = clip;
                        if (!multiline) {
                            if (std.mem.indexOfScalar(u8, clip, '\n')) |nl| clean = clip[0..nl];
                        }
                        st.buf.insertSlice(a, st.cursor, clean) catch {};
                        st.cursor += clean.len;
                        st.anchor = st.cursor;
                        changed = true;
                    } else |_| {}
                },
                Key.enter, Key.kpenter => if (multiline) {
                    _ = st.deleteSelectionAlloc(a);
                    st.buf.insert(a, st.cursor, '\n') catch {};
                    st.cursor += 1;
                    st.anchor = st.cursor;
                    changed = true;
                },
                Key.tab => if (multiline and !cmd) {
                    _ = st.deleteSelectionAlloc(a);
                    st.buf.insertSlice(a, st.cursor, "    ") catch {};
                    st.cursor += 4;
                    st.anchor = st.cursor;
                    changed = true;
                },
                else => {},
            }
        }
        if (self.text_len > 0 and self.mods & (Mods.cmd | Mods.ctrl) == 0) {
            _ = st.deleteSelectionAlloc(a);
            const t = self.text_in[0..self.text_len];
            const clean = if (!multiline) t else t;
            st.buf.insertSlice(a, st.cursor, clean) catch {};
            st.cursor += clean.len;
            st.anchor = st.cursor;
            changed = true;
        }
        return changed;
    }

    /// Sidebar row (Finder / Settings). Returns true when clicked.
    pub fn sidebarItem(self: *Ui, id_str: []const u8, r: Rect, label: []const u8, selected: bool, icon: ?IconFn, icon_color: u32) bool {
        const id = hashId(id_str);
        const clicked = self.interact(id, r);
        const t = self.theme;
        if (selected) {
            self.fillRound(r, 8, if (t.dark) 0x33FFFFFF else 0x1F000000);
        } else if (self.hot == id) {
            self.fillRound(r, 8, t.hover);
        }
        var tx = r.x + 10;
        if (icon) |draw| {
            draw(self, Rect.init(r.x + 8, r.y + @divTrunc(r.h - 18, 2), 18, 18), icon_color);
            tx = r.x + 34;
        }
        self.text(Rect.init(tx, r.y, r.w - (tx - r.x) - 8, r.h), label, .{ .weight = .medium, .color = t.label });
        return clicked;
    }

    /// List row background; returns true when clicked. The caller draws
    /// the row content.
    pub fn listRow(self: *Ui, id: Id, r: Rect, selected: bool, alternate: bool) bool {
        const clicked = self.interact(id, r);
        const t = self.theme;
        if (selected) {
            self.fillRound(r, 6, if (self.focused) t.accent else t.selection_inactive);
        } else if (alternate) {
            self.fillRect(r, t.alternate_row);
        }
        return clicked;
    }

    /// Rounded grouped panel (Settings style).
    pub fn group(self: *Ui, r: Rect) void {
        const t = self.theme;
        self.fillRound(r, 12, if (t.dark) 0xFF2A2A2D else 0xFFFFFFFF);
        self.strokeRound(r, 12, 0.5, t.separator);
    }

    pub fn separator(self: *Ui, x0: i32, x1: i32, y: i32) void {
        self.hline(x0, x1, y, self.theme.separator);
    }

    pub fn progress(self: *Ui, r: Rect, value: f32) void {
        const t = self.theme;
        self.fillRound(r, @as(f32, @floatFromInt(r.h)) / 2, if (t.dark) 0xFF3A3A3C else 0xFFE5E5EA);
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(r.w)) * std.math.clamp(value, 0, 1));
        if (w > 0) self.fillRound(Rect.init(r.x, r.y, @max(w, r.h), r.h), @as(f32, @floatFromInt(r.h)) / 2, t.accent);
    }

    /// Circular avatar with initials.
    pub fn avatar(self: *Ui, cx: f32, cy: f32, radius: f32, name: []const u8) void {
        const g = gfx.Paint.verticalGradient(gfx.RectF.init(cx - radius, cy - radius, radius * 2, radius * 2), &.{
            .{ .pos = 0, .color = pm(0xFFA2A2AA) },
            .{ .pos = 1, .color = pm(0xFF6E6E78) },
        });
        shapes.fillCircle(self.canvas, cx, cy, radius, &g);
        var initials: [8]u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, name, ' ');
        while (it.next()) |w| {
            if (n >= 2) break;
            initials[n] = std.ascii.toUpper(w[0]);
            n += 1;
        }
        const size = radius * 0.8;
        const f = self.face(.semibold, size);
        const w = f.measure(initials[0..n]);
        _ = font.drawText(self.target(), f, initials[0..n], cx - w / 2, @round(cy + f.cap_height / 2), pm(0xFFFFFFFF));
    }

    /// Begin a vertically scrolling region. Content coordinates are offset by
    /// `-st.offset`. Returns the previous clip for `endScroll`.
    pub fn beginScroll(self: *Ui, r: Rect, st: *ScrollState) Rect {
        st.view = @floatFromInt(r.h);
        if (self.hovering(r) and self.scroll_dy != 0) {
            st.offset += self.scroll_dy;
            self.scroll_dy = 0;
        }
        st.clamp();
        return self.pushClip(r);
    }

    pub fn endScroll(self: *Ui, r: Rect, st: *ScrollState, old: Rect) void {
        self.popClip(old);
        if (st.content <= st.view) return;
        const frac = st.view / st.content;
        const bar_h = @max(24, @as(f32, @floatFromInt(r.h)) * frac);
        const pos = (st.offset / (st.content - st.view)) * (@as(f32, @floatFromInt(r.h)) - bar_h);
        const bar = Rect.init(r.x + r.w - 8, r.y + @as(i32, @intFromFloat(pos)), 5, @intFromFloat(bar_h));
        self.fillRound(bar, 2.5, if (self.theme.dark) 0x66FFFFFF else 0x55000000);
    }
};

pub const IconFn = *const fn (ui: *Ui, r: Rect, color: u32) void;

fn darken(c: u32, amount: u8) u32 {
    const r: u8 = @truncate(c >> 16);
    const g: u8 = @truncate(c >> 8);
    const b: u8 = @truncate(c);
    return (c & 0xFF000000) | (@as(u32, r -| amount) << 16) | (@as(u32, g -| amount) << 8) | (b -| amount);
}

fn lineStart(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

fn lineEnd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

/// Bullet-masked text for secure fields.
fn displayText(st: *const TextState, secure: bool, buf: []u8) []const u8 {
    if (!secure) return st.buf.items;
    const bullet = "\u{2022}";
    var n: usize = 0;
    var it = font.utf8.Iterator{ .bytes = st.buf.items };
    while (it.next()) |_| {
        if (n + bullet.len > buf.len) break;
        @memcpy(buf[n .. n + bullet.len], bullet);
        n += bullet.len;
    }
    return buf[0..n];
}

/// Byte index in the real text → byte index in the displayed text.
fn displayIndex(st: *const TextState, secure: bool, i: usize) usize {
    if (!secure) return i;
    var count: usize = 0;
    var it = font.utf8.Iterator{ .bytes = st.buf.items[0..@min(i, st.buf.items.len)] };
    while (it.next()) |_| count += 1;
    return count * 3;
}

/// Byte index in the displayed text → byte index in the real text.
fn mapIndex(st: *const TextState, secure: bool, di: usize) usize {
    if (!secure) return di;
    const chars = di / 3;
    var it = font.utf8.Iterator{ .bytes = st.buf.items };
    var n: usize = 0;
    while (n < chars) : (n += 1) {
        if (it.next() == null) break;
    }
    return it.i;
}

