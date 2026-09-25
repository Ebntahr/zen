//! Appearance, Wallpaper and Displays.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const app_mod = @import("../app.zig");
const w = @import("../widgets.zig");
const sys = @import("../system.zig");

const App = app_mod.App;
const Ui = ui.Ui;
const Rect = ui.Rect;
const Form = w.Form;
const hashIdx = ui.ui.hashIdx;
const pad = w.pad;
const Accent = ui.theme.Accent;

// ---------------------------------------------------------------------------
// Wallpaper thumbnails (rendered once, on first use)
// ---------------------------------------------------------------------------

pub const wallpapers = [_]struct { variant: gfx.wallpaper.Variant, blurb: []const u8 }{
    .{ .variant = .tahoe_day, .blurb = "Dynamic: turns to night in Dark mode" },
    .{ .variant = .tahoe_night, .blurb = "Lake Tahoe under the stars" },
    .{ .variant = .golden_gate, .blurb = "Sunset over the Golden Gate" },
    .{ .variant = .aurora, .blurb = "Northern lights over the fjords" },
};

const thumb_w = 200;
const thumb_h = 125;

pub const Thumbs = struct {
    imgs: [wallpapers.len]?gfx.Image = [_]?gfx.Image{null} ** wallpapers.len,

    pub fn get(self: *Thumbs, a: std.mem.Allocator, i: usize) ?gfx.Canvas {
        const idx = @min(i, wallpapers.len - 1);
        if (self.imgs[idx]) |img| return img.canvas();
        var img = gfx.Image.init(a, thumb_w, thumb_h) catch return null;
        gfx.wallpaper.render(img.canvas(), a, wallpapers[idx].variant, .{ .detail = 2, .grain = 1.0 }) catch img.canvas().clear(0xFF3A4A6A);
        self.imgs[idx] = img;
        return img.canvas();
    }

    pub fn deinit(self: *Thumbs, a: std.mem.Allocator) void {
        for (&self.imgs) |*m| if (m.*) |*img| img.deinit(a);
    }
};

/// Draw an image scaled into a rounded rectangle.
pub fn roundImage(u: *Ui, img: ?gfx.Canvas, r: Rect, radius: f32) void {
    const c = img orelse {
        u.fillRound(r, radius, 0xFF6A7A9A);
        return;
    };
    const paint = gfx.Paint{ .image = gfx.ImagePattern.fit(c, gfx.RectF.init(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h))) };
    gfx.shapes.fillRoundRect(u.canvas, r, radius, &paint);
}

fn selectionRing(u: *Ui, r: Rect, radius: f32, selected: bool) void {
    if (selected) {
        u.strokeRound(r.inset(-4, -4), radius + 4, 3, u.theme.accent);
    } else {
        u.strokeRound(r, radius, 1, if (u.theme.dark) 0x26FFFFFF else 0x1F000000);
    }
}

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

/// A miniature desktop (wallpaper, menu bar and a window) in light or dark.
fn miniDesktop(app: *App, u: *Ui, r: Rect, dark: bool, accent: u32) void {
    roundImage(u, app.thumbs.get(app.allocator, if (dark and app.prefs.wallpaper == 0) 1 else app.prefs.wallpaper), r, 7);
    const old = u.pushClip(r);
    defer u.popClip(old);
    u.fillRect(Rect.init(r.x, r.y, r.w, 5), if (dark) 0x80000000 else 0xB3FFFFFF);
    const win = Rect.init(r.x + 9, r.y + 11, r.w - 20, r.h - 17);
    u.fillRound(win, 4, if (dark) 0xFF2A2A2E else 0xFFF7F7F9);
    // Sidebar + title bar.
    u.fillRect(Rect.init(win.x + 1, win.y + 1, 16, win.h - 2), if (dark) 0xFF36363B else 0xFFE4E4EA);
    const lights = [3]u32{ 0xFFFF5F57, 0xFFFEBC2E, 0xFF28C840 };
    for (lights, 0..) |col, i| u.fillCircle(@floatFromInt(win.x + 4 + @as(i32, @intCast(i)) * 4), @floatFromInt(win.y + 4), 1.3, col);
    // Content lines and an accent control.
    const lc: u32 = if (dark) 0x40FFFFFF else 0x26000000;
    u.fillRect(Rect.init(win.x + 22, win.y + 6, 18, 2), lc);
    u.fillRect(Rect.init(win.x + 22, win.y + 11, 24, 2), lc);
    u.fillRound(Rect.init(win.x + 22, win.y + 17, 14, 5), 2.5, accent);
    u.fillRound(Rect.init(win.x + 3, win.y + 9, 11, 3), 1.5, accent);
}

fn appearanceCard(app: *App, u: *Ui, x: i32, y: i32, idx: usize, label: []const u8, selected: bool) bool {
    const r = Rect.init(x, y, 72, 48);
    const id = hashIdx("appearance", idx);
    const hit = Rect.init(x - 4, y - 4, 80, 76);
    const clicked = u.interact(id, hit);
    const acc: Accent = @enumFromInt(App.accentIndex(u));
    switch (idx) {
        0 => {
            miniDesktop(app, u, r, false, acc.color(false));
            const old = u.pushClip(Rect.init(r.x + @divTrunc(r.w, 2), r.y, r.w, r.h));
            miniDesktop(app, u, r, true, acc.color(true));
            u.popClip(old);
        },
        1 => miniDesktop(app, u, r, false, acc.color(false)),
        else => miniDesktop(app, u, r, true, acc.color(true)),
    }
    selectionRing(u, r, 7, selected);
    u.text(Rect.init(x - 10, y + 54, 92, 16), label, .{ .size = 11, .weight = if (selected) .semibold else .regular, .color = if (selected) u.theme.label else u.theme.secondary_label, .@"align" = .center });
    return clicked;
}

pub fn autoIsDark() bool {
    const c = sys.now(0) orelse return false;
    return c.hour >= 19 or c.hour < 7;
}

pub fn drawAppearance(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    _ = f.begin(116 + 64 + 52);
    {
        const r = f.row(116);
        f.label(r, "Appearance");
        const current: usize = switch (app.prefs.appearance) {
            .auto => 0,
            else => if (t.dark) 2 else 1,
        };
        const labels = [_][]const u8{ "Auto", "Light", "Dark" };
        var x = r.right() - pad - 3 * 72 - 2 * 18;
        for (labels, 0..) |label, i| {
            if (appearanceCard(app, u, x, r.y + 22, i, label, current == i) and current != i) {
                app.prefs.appearance = switch (i) {
                    0 => .auto,
                    1 => .light,
                    else => .dark,
                };
                const dark = if (i == 0) autoIsDark() else i == 2;
                app.applyDark(u, dark);
                app.savePrefs();
            }
            x += 72 + 18;
        }
    }
    {
        const r = f.row(64);
        f.label(r, "Accent color");
        const cur = App.accentIndex(u);
        const spacing: i32 = 26;
        const x0 = r.right() - pad - 10 - 7 * spacing;
        const cy = r.y + 24;
        for (0..8) |i| {
            const acc: Accent = @enumFromInt(i);
            const cx = x0 + @as(i32, @intCast(i)) * spacing;
            if (w.swatch(u, hashIdx("accent", i), cx, cy, acc.color(t.dark), cur == i) and cur != i) {
                u.theme.accent = acc.color(t.dark);
                _ = sys.controlf("accent {d}", .{i});
            }
        }
        const name = (@as(Accent, @enumFromInt(cur))).name();
        const sel_x = x0 + @as(i32, @intCast(cur)) * spacing;
        u.text(Rect.init(sel_x - 40, cy + 14, 80, 16), name, .{ .size = 11, .color = t.secondary_label, .@"align" = .center });
    }
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Reduce transparency", "Use opaque sidebars and menus");
        if (f.toggle(r, "reduce-transparency", &app.prefs.reduce_transparency)) {
            _ = sys.controlf("transparency {s}", .{if (app.prefs.reduce_transparency) "reduce" else "normal"});
            app.savePrefs();
        }
    }
    f.end();

    _ = f.begin(96);
    {
        const r = f.row(96);
        u.text(Rect.init(r.x + pad, r.y + 12, 200, 20), "Show scroll bars", .{});
        const opts = [_][]const u8{ "Automatically based on input", "When scrolling", "Always" };
        const x = r.right() - pad - 210;
        for (opts, 0..) |o, i| {
            if (w.radio(u, hashIdx("scrollbars", i), x, r.y + 22 + @as(i32, @intCast(i)) * 26, o, app.prefs.scroll_bars == i)) {
                app.prefs.scroll_bars = i;
                app.savePrefs();
            }
        }
    }
    f.end();
    if (app.prefs.appearance == .auto) f.note("Auto switches to Dark in the evening (19:00) and back to Light in the morning (07:00).");
}

// ---------------------------------------------------------------------------
// Wallpaper
// ---------------------------------------------------------------------------

fn selectWallpaper(app: *App, i: usize) void {
    if (app.prefs.wallpaper == i) return;
    app.prefs.wallpaper = @intCast(i);
    _ = sys.controlf("wallpaper {d}", .{i});
    app.savePrefs();
}

pub fn drawWallpaper(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    const cur: usize = @min(app.prefs.wallpaper, wallpapers.len - 1);
    const r = f.begin(144);
    const pr = Rect.init(r.x + pad + 2, r.y + 16, 179, 112);
    roundImage(u, app.thumbs.get(app.allocator, cur), pr, 9);
    u.strokeRound(pr, 9, 1, if (t.dark) 0x26FFFFFF else 0x1A000000);
    const tx = pr.right() + 20;
    u.text(Rect.init(tx, r.y + 42, r.right() - tx - pad, 22), wallpapers[cur].variant.name(), .{ .size = 16, .weight = .bold });
    u.text(Rect.init(tx, r.y + 66, r.right() - tx - pad, 18), wallpapers[cur].blurb, .{ .color = t.secondary_label });
    u.text(Rect.init(tx, r.y + 86, r.right() - tx - pad, 18), "Procedural · rendered by Zen OS", .{ .size = 11, .color = t.tertiary_label });
    f.end();

    f.header("Zen Wallpapers");
    const cols: i32 = 4;
    const gap: i32 = 14;
    const tw = @divTrunc(f.w - (cols - 1) * gap, cols);
    const th = @divTrunc(tw * 10, 16);
    for (wallpapers, 0..) |wp, i| {
        const col: i32 = @intCast(i % @as(usize, @intCast(cols)));
        const row: i32 = @intCast(i / @as(usize, @intCast(cols)));
        const x = f.x + col * (tw + gap);
        const y = f.y + 4 + row * (th + 34);
        const tr = Rect.init(x, y, tw, th);
        if (u.interact(hashIdx("wallpaper", i), Rect.init(x, y, tw, th + 24))) selectWallpaper(app, i);
        roundImage(u, app.thumbs.get(app.allocator, i), tr, 8);
        selectionRing(u, tr, 8, cur == i);
        u.text(Rect.init(x, y + th + 7, tw, 16), wp.variant.name(), .{ .size = 11, .weight = if (cur == i) .semibold else .regular, .color = if (cur == i) t.label else t.secondary_label, .@"align" = .center });
    }
    const rows: i32 = @intCast((wallpapers.len + 3) / 4);
    f.space(rows * (th + 34) + 10);
    f.note("Wallpapers are generated procedurally for your display, so they stay sharp at every resolution.");
}

// ---------------------------------------------------------------------------
// Displays
// ---------------------------------------------------------------------------

const schedule_items = [_][]const u8{ "Off", "Sunset to Sunrise", "Custom" };
const refresh_items = [_][]const u8{ "60 Hertz", "50 Hertz" };

fn resolutionCard(u: *Ui, x: i32, y: i32, idx: usize, label: []const u8, selected: bool) bool {
    const t = u.theme;
    const r = Rect.init(x, y, 62, 42);
    const clicked = u.interact(hashIdx("resolution", idx), Rect.init(x - 6, y - 4, 74, 70));
    u.fillRound(r, 6, if (t.dark) 0xFF1C1C1E else 0xFFFFFFFF);
    selectionRing(u, r, 6, selected);
    const sizes = [_]f32{ 17, 13, 10 };
    u.text(r, "Aa", .{ .size = sizes[idx], .weight = .semibold, .color = t.secondary_label, .@"align" = .center });
    u.text(Rect.init(x - 12, y + 48, 86, 16), label, .{ .size = 11, .weight = if (selected) .semibold else .regular, .color = if (selected) t.label else t.secondary_label, .@"align" = .center });
    return clicked;
}

pub fn drawDisplays(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    // Display illustration.
    f.space(8);
    const mw: i32 = 200;
    const mh: i32 = 126;
    const mx = f.x + @divTrunc(f.w - mw, 2);
    const my = f.y;
    const bezel = Rect.init(mx, my, mw, mh);
    u.shadow(bezel, 10, 8, 3, if (t.dark) 0x60000000 else 0x30000000);
    u.fillRound(bezel, 10, 0xFF1A1A1C);
    const screen = bezel.inset(6, 6);
    roundImage(u, app.thumbs.get(app.allocator, app.prefs.wallpaper), screen, 5);
    if (app.prefs.night_shift) u.fillRound(screen, 5, ui.ui.withAlpha(0xFFFF9500, @intFromFloat(20 + app.prefs.warmth * 60)));
    // Dimming preview for the brightness slider.
    const dim: u8 = @intFromFloat((1 - app.prefs.brightness) * 150);
    if (dim > 0) u.fillRound(screen, 5, @as(u32, dim) << 24);
    u.fillRect(Rect.init(mx + @divTrunc(mw, 2) - 14, my + mh, 28, 14), if (t.dark) 0xFF4A4A4E else 0xFFC7C7CC);
    u.fillRound(Rect.init(mx + @divTrunc(mw, 2) - 38, my + mh + 12, 76, 5), 2.5, if (t.dark) 0xFF5A5A5E else 0xFFB8B8BE);
    f.space(mh + 26);
    u.text(Rect.init(f.x, f.y, f.w, 18), "Built-in Display", .{ .weight = .semibold, .@"align" = .center });
    u.text(Rect.init(f.x, f.y + 18, f.w, 16), "1280 × 800 · virtio-gpu", .{ .size = 11, .color = t.secondary_label, .@"align" = .center });
    f.space(46);

    _ = f.begin(96 + w.row_h * 2);
    {
        const r = f.row(96);
        u.text(Rect.init(r.x + pad, r.y + 12, 200, 20), "Resolution", .{});
        const labels = [_][]const u8{ "Larger Text", "Default", "More Space" };
        var x = r.right() - pad - 3 * 62 - 2 * 22;
        for (labels, 0..) |l, i| {
            if (resolutionCard(u, x, r.y + 18, i, l, app.prefs.resolution == i)) {
                app.prefs.resolution = i;
                app.savePrefs();
            }
            x += 62 + 22;
        }
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Brightness");
        const sw: i32 = 220;
        const sx = r.right() - pad - sw;
        w.blit(u, app.icons.symbol(.sun, ui.pm(t.secondary_label), 12), sx - 18, r.y + 14);
        _ = u.slider("brightness", Rect.init(sx, r.y + 8, sw, 24), &app.prefs.brightness, 0.1, 1);
        if (u.mouse_released and u.active == ui.ui.hashId("brightness")) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Automatically adjust brightness");
        if (f.toggle(r, "auto-brightness", &app.prefs.auto_brightness)) app.savePrefs();
    }
    f.end();

    _ = f.begin(52 + w.row_h * 2);
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Night Shift", "Warmer colors after dark are easier on your eyes");
        if (f.toggle(r, "night-shift", &app.prefs.night_shift)) {
            _ = sys.controlf("nightshift {s}", .{if (app.prefs.night_shift) "on" else "off"});
            app.savePrefs();
        }
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Schedule");
        if (app.popupButton(u, "night-schedule", r.right() - pad + 6, Form.centerY(r), &schedule_items, &app.prefs.night_schedule)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Color temperature");
        const lw: i32 = 64;
        const right_x = r.right() - pad - lw;
        const sw: i32 = 150;
        const sx = right_x - 6 - sw;
        u.text(Rect.init(sx - lw - 4, r.y, lw, r.h), "Less Warm", .{ .size = 11, .color = t.secondary_label, .@"align" = .right });
        _ = u.slider("warmth", Rect.init(sx, r.y + 8, sw, 24), &app.prefs.warmth, 0, 1);
        u.text(Rect.init(right_x, r.y, lw, r.h), "More Warm", .{ .size = 11, .color = t.secondary_label, .@"align" = .right });
        if (u.mouse_released and u.active == ui.ui.hashId("warmth")) app.savePrefs();
    }
    f.end();

    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        f.label(r, "Refresh rate");
        if (app.popupButton(u, "refresh", r.right() - pad + 6, Form.centerY(r), &refresh_items, &app.prefs.refresh_rate)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Color profile");
        _ = f.value(r, "sRGB IEC61966-2.1");
    }
    f.end();
}
