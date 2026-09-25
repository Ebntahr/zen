//! Control Center: a Liquid Glass panel opened from the menu-bar clock.

const std = @import("std");
const gfx = @import("gfx");
const abi = @import("abi");
const ui = @import("ui");
const icons = @import("icons");
const font = @import("font");
const wm = @import("wm.zig");
const st = @import("state.zig");
const comp_mod = @import("compositor.zig");

const Rect = gfx.Rect;
const RectF = gfx.RectF;
const Color = gfx.Color;
const pm = ui.pm;

pub var open: bool = false;
pub var brightness: f32 = 0.8;
pub var volume: f32 = 0.6;

const W: i32 = 320;
const H: i32 = 286;

pub fn rect(state: *const st.State) Rect {
    return Rect.init(state.width - W - 10, wm.MENUBAR + 6, W, H);
}

/// The clickable menu-bar area that toggles the panel (the clock).
pub fn triggerRect(state: *const st.State) Rect {
    return Rect.init(state.width - 190, 0, 190, wm.MENUBAR);
}

fn invalidate(state: *st.State) void {
    state.invalidate(comp_mod.fromG(rect(state).inset(-40, -40)));
    state.invalidate(.{ .x = state.width - 200, .y = 0, .w = 200, .h = wm.MENUBAR });
}

pub fn toggle(state: *st.State) void {
    open = !open;
    invalidate(state);
}

pub fn close(state: *st.State) void {
    if (!open) return;
    open = false;
    invalidate(state);
}

pub const Action = enum { none, dark_mode, keyboard, settings, lock };

const Tile = struct { r: Rect, action: Action };

fn tiles(state: *const st.State) [4]Tile {
    const p = rect(state);
    const x0 = p.x + 14;
    const y0 = p.y + 14;
    const tw = @divTrunc(W - 28 - 10, 2);
    return .{
        .{ .r = Rect.init(x0, y0, tw, 64), .action = .dark_mode },
        .{ .r = Rect.init(x0 + tw + 10, y0, tw, 64), .action = .keyboard },
        .{ .r = Rect.init(x0, p.bottom() - 58, tw, 44), .action = .settings },
        .{ .r = Rect.init(x0 + tw + 10, p.bottom() - 58, tw, 44), .action = .lock },
    };
}

fn sliderRect(state: *const st.State, i: usize) Rect {
    const p = rect(state);
    return Rect.init(p.x + 14, p.y + 92 + @as(i32, @intCast(i)) * 62, W - 28, 50);
}

/// Mouse press inside the panel (or on a slider while dragging).
pub fn press(state: *st.State, x: i32, y: i32) Action {
    for (tiles(state)) |t| {
        if (t.r.contains(x, y)) {
            invalidate(state);
            return t.action;
        }
    }
    drag(state, x, y);
    return .none;
}

pub fn drag(state: *st.State, x: i32, y: i32) void {
    for (0..2) |i| {
        const r = sliderRect(state, i);
        if (!r.inset(0, -6).contains(x, y)) continue;
        const track = Rect.init(r.x + 12, r.y + 24, r.w - 24, 16);
        const v = std.math.clamp(@as(f32, @floatFromInt(x - track.x)) / @as(f32, @floatFromInt(track.w)), 0, 1);
        if (i == 0) brightness = v else volume = v;
        invalidate(state);
    }
}

fn label(c: *comp_mod.Compositor, clip: Rect, x: i32, baseline: i32, s: []const u8, weight: ui.fonts.Weight, size: f32, color: u32) void {
    var t = font.Target.init(c.fb.pixels[0..@intCast(c.width * c.height)], @intCast(c.width), @intCast(c.height), @intCast(c.width));
    const cl = clip.intersect(c.fb.clip);
    t.clip = .{ .x0 = cl.x, .y0 = cl.y, .x1 = cl.right(), .y1 = cl.bottom() };
    _ = font.drawText(t, c.fonts.face(weight, size), s, @floatFromInt(x), @floatFromInt(baseline), pm(color));
}

pub fn draw(c: *comp_mod.Compositor, state: *st.State, dirty: Rect) void {
    if (!open) return;
    const p = rect(state);
    if (!p.inset(-40, -40).intersects(dirty)) return;
    const dark = state.dark();
    const canvas = c.fb.withClip(dirty);
    const t = ui.Theme.get(dark, @enumFromInt(@min(state.appearance.accent, 7)));
    if (c.shadow_focused.fits(p)) c.shadow_focused.draw(canvas, p.offset(0, 10), Color.rgba(0, 0, 0, 70), null);
    var style = gfx.GlassStyle.light;
    style.tint = if (dark) Color.rgba(34, 34, 40, 170) else Color.rgba(248, 248, 252, 150);
    const bd = c.prepareBackdrop(p.inset(-32, -32), 18);
    gfx.glass.drawGlass(canvas, p, 26, bd, style);

    const fg: u32 = if (dark) 0xF2FFFFFF else 0xE6000000;
    const sub: u32 = if (dark) 0x99FFFFFF else 0x8C000000;
    const module_bg: u32 = if (dark) 0x33FFFFFF else 0x66FFFFFF;
    for (tiles(state)) |tile| {
        canvas.fillRoundRect(tile.r, 16, pm(module_bg));
        const cx = tile.r.x + 26;
        const cy = tile.r.y + @divTrunc(tile.r.h, 2);
        const on = switch (tile.action) {
            .dark_mode => dark,
            .keyboard => state.keys.arabic,
            else => false,
        };
        if (tile.r.h > 50) {
            canvas.fillCircle(@floatFromInt(cx), @floatFromInt(cy), 16, pm(if (on) t.accent else (if (dark) 0x40FFFFFF else 0x1F000000)));
        }
        const icon_color: u32 = if (on) 0xFFFFFFFF else fg;
        const sym: icons.Symbol = switch (tile.action) {
            .dark_mode => if (dark) .moon else .sun,
            .keyboard => .keyboard,
            .settings => .gear,
            .lock => .lock,
            .none => .info,
        };
        icons.drawSymbol(canvas, c.allocator, sym, RectF.init(@floatFromInt(cx - 10), @floatFromInt(cy - 10), 20, 20), pm(icon_color));
        const title: []const u8 = switch (tile.action) {
            .dark_mode => "Dark Mode",
            .keyboard => if (state.keys.arabic) "العربية" else "U.S.",
            .settings => "Settings",
            .lock => "Lock Screen",
            .none => "",
        };
        const detail: []const u8 = switch (tile.action) {
            .dark_mode => if (dark) "On" else "Off",
            .keyboard => "Input Source",
            else => "",
        };
        if (detail.len > 0) {
            label(c, dirty.intersect(tile.r), cx + 24, cy - 2, title, .semibold, 13, fg);
            label(c, dirty.intersect(tile.r), cx + 24, cy + 14, detail, .regular, 11, sub);
        } else {
            label(c, dirty.intersect(tile.r), cx + 18, cy + 5, title, .semibold, 13, fg);
        }
    }
    const names = [_][]const u8{ "Display", "Sound" };
    const vals = [_]f32{ brightness, volume };
    const syms = [_]icons.Symbol{ .sun, .music };
    for (0..2) |i| {
        const r = sliderRect(state, i);
        canvas.fillRoundRect(r, 16, pm(module_bg));
        label(c, dirty.intersect(r), r.x + 12, r.y + 17, names[i], .semibold, 12, fg);
        const track = Rect.init(r.x + 12, r.y + 24, r.w - 24, 18);
        canvas.fillRoundRect(track, 9, pm(if (dark) 0x33FFFFFF else 0x1F000000));
        const fw: i32 = @max(18, @as(i32, @intFromFloat(@as(f32, @floatFromInt(track.w)) * vals[i])));
        canvas.fillRoundRect(Rect.init(track.x, track.y, fw, track.h), 9, pm(0xFFFFFFFF));
        icons.drawSymbol(canvas, c.allocator, syms[i], RectF.init(@floatFromInt(track.x + 4), @floatFromInt(track.y + 3), 12, 12), pm(0xFF7A7A80));
    }
}
