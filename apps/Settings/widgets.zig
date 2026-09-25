//! Settings-specific widgets on top of GlassKit: grouped form layout,
//! cached icon tiles, macOS 26 style switches, pop-up buttons, badges and
//! a few drawing helpers.

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const icons = @import("icons");

const Ui = ui.Ui;
const Rect = ui.Rect;
const RectF = gfx.RectF;
const Theme = ui.Theme;
const Color = gfx.Color;
const pm = ui.pm;

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

pub fn contentBg(t: Theme) u32 {
    return if (t.dark) 0xFF1E1E20 else 0xFFFFFFFF;
}

pub fn groupBg(t: Theme) u32 {
    return if (t.dark) 0xFF2A2A2D else 0xFFF4F4F6;
}

pub fn groupBorder(t: Theme) u32 {
    return if (t.dark) 0x12FFFFFF else 0x0C000000;
}

/// Opaque sidebar used when "Reduce transparency" is on.
pub fn sidebarOpaque(t: Theme) u32 {
    return if (t.dark) 0xFF28282C else 0xFFE8E8ED;
}

pub fn green(t: Theme) u32 {
    return if (t.dark) 0xFF30D158 else 0xFF28A745;
}

pub fn orange(t: Theme) u32 {
    return if (t.dark) 0xFFFF9F0A else 0xFFE58600;
}

pub fn red(t: Theme) u32 {
    return if (t.dark) 0xFFFF453A else 0xFFE5342A;
}

/// Tile colors (macOS System Settings icon palette).
pub const tint = struct {
    pub const gray: u32 = 0xFF8E8E93;
    pub const dark: u32 = 0xFF3A3A3C;
    pub const blue: u32 = 0xFF0A84FF;
    pub const cyan: u32 = 0xFF32ADE6;
    pub const teal: u32 = 0xFF30B0C7;
    pub const green: u32 = 0xFF34C759;
    pub const orange: u32 = 0xFFFF9500;
    pub const red: u32 = 0xFFFF3B30;
    pub const purple: u32 = 0xFFAF52DE;
    pub const indigo: u32 = 0xFF5856D6;
    pub const pink: u32 = 0xFFFF2D55;
    pub const yellow: u32 = 0xFFFFCC00;
};

// ---------------------------------------------------------------------------
// Icon cache: everything path-based is rendered once into small images.
// ---------------------------------------------------------------------------

pub const TileGlyph = union(enum) {
    sym: icons.Symbol,
    /// Half-filled circle (Appearance).
    appearance,
    /// Sun with rays (Displays).
    sun,
    /// Letters drawn with the UI font are not cached; this is for symbols only.
    none,

    fn code(g: TileGlyph) u64 {
        return switch (g) {
            .sym => |s| @intFromEnum(s),
            .appearance => 200,
            .sun => 201,
            .none => 255,
        };
    }
};

pub const IconCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, gfx.Image) = .empty,
    /// Current appearance (set every frame).
    dark: bool = false,

    pub fn init(allocator: std.mem.Allocator) IconCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IconCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |img| img.deinit(self.allocator);
        self.map.deinit(self.allocator);
    }

    fn put(self: *IconCache, key: u64, img: gfx.Image) ?gfx.Canvas {
        var copy = img;
        self.map.put(self.allocator, key, img) catch {
            copy.deinit(self.allocator);
            return null;
        };
        return img.canvas();
    }

    /// Colored rounded-square tile with a white symbol (sidebar / row icons).
    pub fn tile(self: *IconCache, glyph: TileGlyph, color_in: u32, size: i32) ?gfx.Canvas {
        // Near-black tiles would vanish on dark backgrounds; macOS lifts them.
        const color = if (self.dark and luma(color_in) < 64) 0xFF48484C else color_in;
        const key: u64 = (1 << 60) | (glyph.code() << 40) | (@as(u64, @intCast(size)) << 32) | color;
        if (self.map.get(key)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, @intCast(size), @intCast(size)) catch return null;
        drawTile(img.canvas(), self.allocator, glyph, color, @floatFromInt(size));
        return self.put(key, img);
    }

    /// Monochrome symbol in `color` (premultiplied).
    pub fn symbol(self: *IconCache, sym: icons.Symbol, color: u32, size: i32) ?gfx.Canvas {
        const key: u64 = (2 << 60) | (@as(u64, @intFromEnum(sym)) << 40) | (@as(u64, @intCast(size)) << 32) | color;
        if (self.map.get(key)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, @intCast(size), @intCast(size)) catch return null;
        const s: f32 = @floatFromInt(size);
        icons.drawSymbol(img.canvas(), self.allocator, sym, RectF.init(0, 0, s, s), color);
        return self.put(key, img);
    }

    /// Full-color app icon.
    pub fn app(self: *IconCache, icon: icons.AppIcon, size: i32) ?gfx.Canvas {
        const key: u64 = (3 << 60) | (@as(u64, @intFromEnum(icon)) << 40) | (@as(u64, @intCast(size)) << 32);
        if (self.map.get(key)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, @intCast(size), @intCast(size)) catch return null;
        const s: f32 = @floatFromInt(size);
        icons.drawApp(img.canvas(), self.allocator, icon, RectF.init(0, 0, s, s));
        return self.put(key, img);
    }

    /// Store an externally rendered image under `key` (takes ownership).
    pub fn custom(self: *IconCache, key: u64) ?gfx.Canvas {
        if (self.map.get(key | (4 << 60))) |img| return img.canvas();
        return null;
    }

    pub fn putCustom(self: *IconCache, key: u64, img: gfx.Image) ?gfx.Canvas {
        return self.put(key | (4 << 60), img);
    }
};

fn luma(c: u32) u32 {
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    return (r * 54 + g * 183 + b * 19) >> 8;
}

fn drawTile(c: gfx.Canvas, a: std.mem.Allocator, glyph: TileGlyph, color: u32, size: f32) void {
    const r = RectF.init(0, 0, size, size);
    const top = Color.lerp(color, 0xFFFFFFFF, 0.20);
    const bottom = Color.lerp(color, 0xFF000000, 0.08);
    const paint = gfx.Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = top }, .{ .pos = 1, .color = bottom } });
    const shape = gfx.RoundRect.smooth(r, size * 0.25);
    c.fillRRect(shape, &paint);
    // Faint inner rim (Liquid Glass edge).
    var rim = shape;
    rim.rect = r.inset(0.5, 0.5);
    c.strokeRRect(rim, 1, Color.rgba(255, 255, 255, 46));
    const inset = size * 0.19;
    const sr = RectF.init(inset, inset, size - 2 * inset, size - 2 * inset);
    const white: u32 = 0xFFFFFFFF;
    switch (glyph) {
        .sym => |s| {
            icons.drawSymbol(c, a, s, sr, white);
            // Embolden thin strokes at small sizes (SF Symbols are heavier).
            if (size <= 24) icons.drawSymbol(c, a, s, sr.offset(0.35, 0.2), Color.rgba(255, 255, 255, 150));
        },
        .appearance => {
            const cx = size / 2;
            const cy = size / 2;
            const rad = size * 0.3;
            c.strokeCircle(cx, cy, rad, @max(1.2, size * 0.07), white);
            var p = gfx.Path.init(a);
            defer p.deinit();
            p.arc(cx, cy, rad, -std.math.pi / 2.0, std.math.pi / 2.0, false) catch return;
            p.close() catch return;
            c.fillPath(&p, white, .{}) catch {};
        },
        .sun => {
            const cx = size / 2;
            const cy = size / 2;
            c.fillCircle(cx, cy, size * 0.16, white);
            for (0..8) |i| {
                const ang = @as(f32, @floatFromInt(i)) * std.math.tau / 8.0;
                c.drawLine(cx + size * 0.25 * @cos(ang), cy + size * 0.25 * @sin(ang), cx + size * 0.33 * @cos(ang), cy + size * 0.33 * @sin(ang), @max(1.2, size * 0.07), white);
            }
        },
        .none => {},
    }
}

/// Blit a cached icon at (x, y).
pub fn blit(u: *Ui, img: ?gfx.Canvas, x: i32, y: i32) void {
    if (img) |c| u.canvas.blit(c, x, y);
}

/// Letter tile ("US", "AR") drawn directly.
pub fn letterTile(u: *Ui, r: Rect, text: []const u8, color: u32) void {
    u.fillRound(r, @as(f32, @floatFromInt(r.w)) * 0.25, color);
    u.text(r, text, .{ .size = @as(f32, @floatFromInt(r.h)) * 0.42, .weight = .bold, .color = 0xFFFFFFFF, .@"align" = .center });
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

/// Replace (not blend) the pixels of a rounded rectangle with `color`
/// (premultiplied), anti-aliasing the corners against what is already there.
/// Used to punch the translucent sidebar out of the opaque window.
pub fn replaceRound(c: gfx.Canvas, r: Rect, radius: i32, color: u32) void {
    const rad: f32 = @floatFromInt(radius);
    var y = @max(r.y, c.clip.y);
    const y1 = @min(r.bottom(), c.clip.bottom());
    const x0 = @max(r.x, c.clip.x);
    const x1 = @min(r.right(), c.clip.right());
    if (x0 >= x1) return;
    while (y < y1) : (y += 1) {
        const row = c.span(y, x0, x1);
        const dy = @min(y - r.y, r.bottom() - 1 - y);
        if (dy >= radius) {
            @memset(row, color);
            continue;
        }
        const oy = rad - (@as(f32, @floatFromInt(dy)) + 0.5);
        for (row, 0..) |*p, i| {
            const x = x0 + @as(i32, @intCast(i));
            const dx = @min(x - r.x, r.right() - 1 - x);
            if (dx >= radius) {
                p.* = color;
                continue;
            }
            const ox = rad - (@as(f32, @floatFromInt(dx)) + 0.5);
            const cov = std.math.clamp(rad - @sqrt(ox * ox + oy * oy) + 0.5, 0, 1);
            p.* = Color.lerp8(p.*, color, @intFromFloat(cov * 255 + 0.5));
        }
    }
}

pub fn groupBox(u: *Ui, r: Rect) void {
    u.fillRound(r, 12, groupBg(u.theme));
    u.strokeRound(r, 12, 1, groupBorder(u.theme));
}

pub fn separator(u: *Ui, x0: i32, x1: i32, y: i32) void {
    u.hline(x0, x1, y, if (u.theme.dark) 0x1AFFFFFF else 0x14000000);
}

pub const Dir = enum { left, right, up, down };

/// Thin chevron centered at (cx, cy); `s` is the half-size.
pub fn chevron(u: *Ui, cx: f32, cy: f32, s: f32, dir: Dir, width: f32, color: u32) void {
    switch (dir) {
        .right => {
            u.line(cx - s * 0.5, cy - s, cx + s * 0.5, cy, width, color);
            u.line(cx + s * 0.5, cy, cx - s * 0.5, cy + s, width, color);
        },
        .left => {
            u.line(cx + s * 0.5, cy - s, cx - s * 0.5, cy, width, color);
            u.line(cx - s * 0.5, cy, cx + s * 0.5, cy + s, width, color);
        },
        .down => {
            u.line(cx - s, cy - s * 0.5, cx, cy + s * 0.5, width, color);
            u.line(cx, cy + s * 0.5, cx + s, cy - s * 0.5, width, color);
        },
        .up => {
            u.line(cx - s, cy + s * 0.5, cx, cy - s * 0.5, width, color);
            u.line(cx, cy - s * 0.5, cx + s, cy + s * 0.5, width, color);
        },
    }
}

pub fn checkmark(u: *Ui, x: f32, y: f32, s: f32, width: f32, color: u32) void {
    u.line(x, y + s * 0.55, x + s * 0.36, y + s * 0.9, width, color);
    u.line(x + s * 0.36, y + s * 0.9, x + s, y + s * 0.1, width, color);
}

/// Height of a wrapped paragraph.
pub fn paragraphHeight(u: *Ui, text: []const u8, weight: ui.ui.Weight, size: f32, width: i32) i32 {
    const f = u.face(weight, size);
    var it = f.lines(text, @floatFromInt(width));
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return @intFromFloat(@ceil(@as(f32, @floatFromInt(n)) * f.line_height));
}

/// Small capsule label ("Sandboxed", "Admin").
pub fn badge(u: *Ui, right_x: i32, cy: i32, text: []const u8, color: u32) i32 {
    const tw: i32 = @intFromFloat(@ceil(u.measure(text, .semibold, 11)));
    const r = Rect.init(right_x - tw - 16, cy - 10, tw + 16, 20);
    u.fillRound(r, 10, ui.ui.withAlpha(color, 38));
    u.text(r, text, .{ .size = 11, .weight = .semibold, .color = color, .@"align" = .center });
    return r.x;
}

/// Status dot + text, right aligned; returns the left edge.
pub fn status(u: *Ui, right_x: i32, cy: i32, text: []const u8, color: u32) i32 {
    const tw: i32 = @intFromFloat(@ceil(u.measure(text, .regular, 13)));
    const x = right_x - tw;
    u.text(Rect.init(x, cy - 10, tw + 2, 20), text, .{ .color = u.theme.secondary_label });
    u.fillCircle(@floatFromInt(x - 9), @floatFromInt(cy), 4, color);
    return x - 16;
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

/// macOS 26 style switch (smaller than the toolkit's iOS-sized toggle).
pub fn switchControl(u: *Ui, id_str: []const u8, x: i32, y: i32, value: *bool, enabled: bool) bool {
    const r = Rect.init(x, y, 38, 22);
    const id = ui.ui.hashId(id_str);
    const clicked = enabled and u.interact(id, r);
    if (clicked) value.* = !value.*;
    const t = u.theme;
    const off_track: u32 = if (t.dark) 0xFF4A4A4E else 0xFFE1E1E6;
    var track = if (value.*) t.accent else off_track;
    if (!enabled) track = ui.ui.withAlpha(track, 110);
    u.fillRound(r, 11, track);
    if (!value.* and !t.dark) u.strokeRound(r, 11, 0.75, 0x0F000000);
    const kx: f32 = @floatFromInt(if (value.*) x + 27 else x + 11);
    const ky: f32 = @floatFromInt(y + 11);
    u.fillCircle(kx, ky + 0.8, 9.6, 0x2E000000);
    u.fillCircle(kx, ky, 9, if (enabled) 0xFFFFFFFF else 0xFFF2F2F2);
    return clicked;
}

/// Borderless pop-up button (value text + up/down chevrons), right aligned
/// at `right_x`. Returns the clickable rect; `clicked` reports a press.
pub fn popupButton(u: *Ui, id: ui.ui.Id, right_x: i32, cy: i32, text: []const u8, enabled: bool) struct { rect: Rect, clicked: bool } {
    const tw: i32 = @intFromFloat(@ceil(u.measure(text, .regular, 13)));
    const r = Rect.init(right_x - tw - 30, cy - 12, tw + 30, 24);
    const clicked = enabled and u.interact(id, r);
    const t = u.theme;
    if (enabled and (u.hot == id or u.isActive(id))) u.fillRound(r, 7, if (u.isActive(id)) t.selection_inactive else t.hover);
    const fg = if (enabled) t.label else t.tertiary_label;
    u.text(Rect.init(r.x + 8, r.y, tw + 2, r.h), text, .{ .color = fg });
    const ax: f32 = @floatFromInt(r.right() - 11);
    const ay: f32 = @floatFromInt(cy);
    const cc = if (enabled) t.secondary_label else t.tertiary_label;
    chevron(u, ax, ay - 3.5, 2.8, .up, 1.3, cc);
    chevron(u, ax, ay + 3.5, 2.8, .down, 1.3, cc);
    return .{ .rect = r, .clicked = clicked };
}

/// Push button sized to its label, right aligned at `right_x`.
pub fn pushButton(u: *Ui, id_str: []const u8, right_x: i32, cy: i32, label: []const u8, style: ui.ui.ButtonStyle, enabled: bool) bool {
    const tw: i32 = @intFromFloat(@ceil(u.measure(label, if (style == .primary) .semibold else .medium, 13)));
    const w = @max(tw + 28, 72);
    return u.button(id_str, Rect.init(right_x - w, cy - 12, w, 24), label, .{ .style = style, .enabled = enabled });
}

pub fn buttonWidth(u: *Ui, label: []const u8) i32 {
    const tw: i32 = @intFromFloat(@ceil(u.measure(label, .medium, 13)));
    return @max(tw + 28, 72);
}

/// Accent color swatch; returns true when clicked.
pub fn swatch(u: *Ui, id: ui.ui.Id, cx: i32, cy: i32, color: u32, selected: bool) bool {
    const r = Rect.init(cx - 10, cy - 10, 20, 20);
    const clicked = u.interact(id, r);
    const fx: f32 = @floatFromInt(cx);
    const fy: f32 = @floatFromInt(cy);
    if (selected) u.fillCircle(fx, fy, 10.5, ui.ui.withAlpha(color, 90));
    u.fillCircle(fx, fy, 8, color);
    u.strokeRound(Rect.init(cx - 8, cy - 8, 16, 16), 8, 0.75, 0x26000000);
    if (selected) u.fillCircle(fx, fy, 3, 0xFFFFFFFF);
    return clicked;
}

/// Radio button with a label; returns true when clicked.
pub fn radio(u: *Ui, id: ui.ui.Id, x: i32, cy: i32, label: []const u8, selected: bool) bool {
    const tw: i32 = @intFromFloat(@ceil(u.measure(label, .regular, 13)));
    const r = Rect.init(x, cy - 10, tw + 26, 20);
    const clicked = u.interact(id, r);
    const t = u.theme;
    const fx: f32 = @floatFromInt(x + 8);
    const fy: f32 = @floatFromInt(cy);
    if (selected) {
        u.fillCircle(fx, fy, 8, t.accent);
        u.fillCircle(fx, fy, 3, 0xFFFFFFFF);
    } else {
        u.fillCircle(fx, fy, 8, if (t.dark) 0xFF3A3A3D else 0xFFFFFFFF);
        u.strokeRound(Rect.init(x, cy - 8, 16, 16), 8, 1, if (t.dark) 0x33FFFFFF else 0x33000000);
    }
    u.text(Rect.init(x + 24, cy - 10, tw + 2, 20), label, .{});
    return clicked;
}

/// Code block (monospace lines, "$ " prompts dimmed) in a rounded box.
pub fn codeBlock(u: *Ui, r: Rect, lines: []const []const u8) void {
    const t = u.theme;
    u.fillRound(r, 8, if (t.dark) 0xFF161618 else 0xFFFFFFFF);
    u.strokeRound(r, 8, 1, groupBorder(t));
    const f = u.fonts.mono(12);
    var y: f32 = @floatFromInt(r.y + 10);
    for (lines) |line| {
        const base = y + f.cap_height + 3;
        var x: f32 = @floatFromInt(r.x + 12);
        if (std.mem.startsWith(u8, line, "$ ")) {
            x = u.textAt(x, @round(base), "$ ", .mono, 12, t.tertiary_label);
            _ = u.textAt(x, @round(base), line[2..], .mono, 12, t.label);
        } else if (std.mem.startsWith(u8, line, "# ")) {
            _ = u.textAt(x, @round(base), line, .mono, 12, t.secondary_label);
        } else {
            _ = u.textAt(x, @round(base), line, .mono, 12, t.label);
        }
        y += 19;
    }
}

// ---------------------------------------------------------------------------
// Grouped form layout (System Settings style)
// ---------------------------------------------------------------------------

pub const pad: i32 = 14;
pub const row_h: i32 = 40;

pub const Form = struct {
    u: *Ui,
    x: i32,
    w: i32,
    y: i32,
    start_y: i32,
    // Current group.
    g_bottom: i32 = 0,
    ry: i32 = 0,
    rows: u32 = 0,
    /// Left inset of row separators (larger when rows have icons).
    sep_inset: i32 = pad,

    pub fn init(u: *Ui, x: i32, w: i32, y: i32) Form {
        return .{ .u = u, .x = x, .w = w, .y = y, .start_y = y };
    }

    pub fn height(f: *const Form) i32 {
        return f.y - f.start_y;
    }

    pub fn space(f: *Form, h: i32) void {
        f.y += h;
    }

    /// Section heading above a group.
    pub fn header(f: *Form, text: []const u8) void {
        f.u.text(Rect.init(f.x + 6, f.y, f.w - 12, 20), text, .{ .weight = .semibold, .size = 13 });
        f.y += 26;
    }

    /// Secondary explanatory text (below or between groups).
    pub fn note(f: *Form, text: []const u8) void {
        const h = paragraphHeight(f.u, text, .regular, 11.5, f.w - 12);
        _ = f.u.paragraph(Rect.init(f.x + 6, f.y, f.w - 12, h), text, .{ .size = 11.5, .color = f.u.theme.secondary_label });
        f.y += h + 14;
    }

    /// Start a group box of the given total height.
    pub fn begin(f: *Form, total: i32) Rect {
        const r = Rect.init(f.x, f.y, f.w, total);
        groupBox(f.u, r);
        f.g_bottom = f.y + total;
        f.ry = f.y;
        f.rows = 0;
        return r;
    }

    pub fn beginRows(f: *Form, n: i32) Rect {
        return f.begin(n * row_h);
    }

    /// Next row of the current group (draws the separator above it).
    pub fn row(f: *Form, h: i32) Rect {
        if (f.rows > 0) separator(f.u, f.x + f.sep_inset, f.x + f.w - pad, f.ry);
        const r = Rect.init(f.x, f.ry, f.w, h);
        f.ry += h;
        f.rows += 1;
        return r;
    }

    pub fn end(f: *Form) void {
        f.y = f.g_bottom + 16;
        f.sep_inset = pad;
    }

    // Row content helpers ----------------------------------------------------

    pub fn label(f: *Form, r: Rect, text: []const u8) void {
        f.u.text(Rect.init(r.x + pad, r.y, @divTrunc(r.w * 3, 5), r.h), text, .{});
    }

    pub fn labelAt(f: *Form, r: Rect, x: i32, text: []const u8) void {
        f.u.text(Rect.init(x, r.y, r.right() - x - pad, r.h), text, .{});
    }

    /// Label with a secondary line below it.
    pub fn label2(f: *Form, r: Rect, x: i32, text: []const u8, sub: []const u8) void {
        const cy = r.y + @divTrunc(r.h, 2);
        const w = r.right() - x - pad;
        f.u.text(Rect.init(x, cy - 17, w, 18), text, .{});
        f.u.text(Rect.init(x, cy + 1, w, 16), sub, .{ .size = 11, .color = f.u.theme.secondary_label });
    }

    /// Right-aligned secondary value; returns its left edge.
    pub fn value(f: *Form, r: Rect, text: []const u8) i32 {
        const tw: i32 = @intFromFloat(@ceil(f.u.measure(text, .regular, 13)));
        const x = r.right() - pad - tw;
        f.u.text(Rect.init(x, r.y, tw + 2, r.h), text, .{ .color = f.u.theme.secondary_label });
        return x;
    }

    pub fn toggle(f: *Form, r: Rect, id: []const u8, v: *bool) bool {
        return switchControl(f.u, id, r.right() - pad - 38, r.y + @divTrunc(r.h - 22, 2), v, true);
    }

    pub fn centerY(r: Rect) i32 {
        return r.y + @divTrunc(r.h, 2);
    }
};

test "replaceRound keeps corners anti-aliased" {
    var px: [20 * 20]u32 = [_]u32{0xFFFFFFFF} ** (20 * 20);
    const c = gfx.Canvas.init(&px, 20, 20, 20);
    replaceRound(c, Rect.init(0, 0, 20, 20), 8, 0x80000000);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[0]);
    try std.testing.expectEqual(@as(u32, 0x80000000), px[10 * 20 + 10]);
}
