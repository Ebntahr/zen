//! Spotlight (Cmd-Space): a glass search field that finds and launches apps.

const std = @import("std");
const gfx = @import("gfx");
const abi = @import("abi");
const ui = @import("ui");
const icons = @import("icons");
const font = @import("font");
const st = @import("state.zig");
const comp_mod = @import("compositor.zig");

const Rect = gfx.Rect;
const Color = gfx.Color;
const Key = abi.input.Key;
const pm = ui.pm;

const FIELD_W: i32 = 640;
const FIELD_H: i32 = 54;
const ROW_H: i32 = 44;
const MAX_RESULTS = 7;

fn fieldRect(state: *const st.State) Rect {
    return Rect.init(@divTrunc(state.width - FIELD_W, 2), @divTrunc(state.height, 5), FIELD_W, FIELD_H);
}

/// Area covered by Spotlight (field + results), for invalidation.
pub fn bounds(state: *const st.State) Rect {
    const f = fieldRect(state);
    return Rect.init(f.x, f.y, f.w, FIELD_H + 12 + MAX_RESULTS * ROW_H + 16);
}

fn invalidate(state: *st.State) void {
    state.invalidate(comp_mod.fromG(bounds(state).inset(-40, -40)));
}

/// Load launchable apps from `launch:apps` (id\tname\tpath\ticon\tcategory).
fn loadApps(state: *st.State) void {
    const sp = &state.spotlight;
    sp.items.clearRetainingCapacity();
    sp.text.clearRetainingCapacity();
    const zio = @import("zen").io;
    const fd = zio.open("launch:apps", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer zio.close(fd);
    var buf: [16 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = zio.read(fd, buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    sp.text.appendSlice(state.allocator, buf[0..n]) catch return;
    var lines = std.mem.splitScalar(u8, sp.text.items, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = f.next() orelse continue;
        const name = f.next() orelse continue;
        const path = f.next() orelse "";
        const icon = f.next() orelse "";
        if (id.len == 0) continue;
        sp.items.append(state.allocator, .{ .id = id, .name = name, .icon = icon, .path = path }) catch {};
    }
}

pub fn open(state: *st.State) void {
    loadApps(state);
    state.spotlight.active = true;
    state.spotlight.query_len = 0;
    state.spotlight.selected = 0;
    invalidate(state);
}

pub fn close(state: *st.State) void {
    invalidate(state);
    state.spotlight.active = false;
}

fn score(name: []const u8, q: []const u8) ?u32 {
    if (q.len == 0) return 1;
    if (q.len > name.len) return null;
    if (std.ascii.startsWithIgnoreCase(name, q)) return 3;
    if (std.ascii.indexOfIgnoreCase(name, q) != null) return 2;
    return null;
}

/// Current matches (best first).
fn results(state: *st.State, out: *[MAX_RESULTS]st.SpotlightItem) usize {
    const q = state.spotlight.querySlice();
    var n: usize = 0;
    var best: u32 = 3;
    while (best >= 1) : (best -= 1) {
        for (state.spotlight.items.items) |it| {
            if (n >= MAX_RESULTS) return n;
            if (score(it.name, q) == best) {
                out[n] = it;
                n += 1;
            }
        }
    }
    return n;
}

/// Handle a key while Spotlight is open. Returns an app id to launch.
pub fn key(state: *st.State, code: u16, text: []const u8, value: i32) ?[]const u8 {
    if (value == 0) return null;
    const sp = &state.spotlight;
    var res: [MAX_RESULTS]st.SpotlightItem = undefined;
    const count = results(state, &res);
    switch (code) {
        Key.esc => {
            close(state);
            return null;
        },
        Key.enter, Key.kpenter => {
            if (count == 0) return null;
            const id = res[@min(sp.selected, count - 1)].id;
            close(state);
            return id;
        },
        Key.down => {
            if (count > 0) sp.selected = @min(sp.selected + 1, count - 1);
        },
        Key.up => {
            if (sp.selected > 0) sp.selected -= 1;
        },
        Key.backspace => {
            if (sp.query_len > 0) {
                var i = sp.query_len - 1;
                while (i > 0 and (sp.query[i] & 0xC0) == 0x80) i -= 1;
                sp.query_len = i;
            }
            sp.selected = 0;
        },
        else => {
            if (text.len > 0 and sp.query_len + text.len <= sp.query.len) {
                @memcpy(sp.query[sp.query_len .. sp.query_len + text.len], text);
                sp.query_len += text.len;
                sp.selected = 0;
            }
        },
    }
    invalidate(state);
    return null;
}

/// Mouse click while open: returns an app id when a result was clicked.
pub fn click(state: *st.State, x: i32, y: i32) ?[]const u8 {
    if (!bounds(state).contains(x, y)) {
        close(state);
        return null;
    }
    var res: [MAX_RESULTS]st.SpotlightItem = undefined;
    const count = results(state, &res);
    const f = fieldRect(state);
    const top = f.bottom() + 12 + 8;
    if (y >= top) {
        const i: usize = @intCast(@divTrunc(y - top, ROW_H));
        if (i < count) {
            close(state);
            return res[i].id;
        }
    }
    return null;
}

pub fn draw(c: *comp_mod.Compositor, state: *st.State, dirty: Rect) void {
    if (!state.spotlight.active) return;
    const dark = state.dark();
    const f = fieldRect(state);
    const canvas = c.fb.withClip(dirty);
    var res: [MAX_RESULTS]st.SpotlightItem = undefined;
    const count = results(state, &res);

    // Search field.
    if (c.shadow_focused.fits(f)) c.shadow_focused.draw(canvas, f.offset(0, 10), Color.rgba(0, 0, 0, 70), null);
    var style = gfx.GlassStyle.light;
    style.tint = if (dark) Color.rgba(34, 34, 40, 185) else Color.rgba(248, 248, 252, 175);
    const bd = c.prepareBackdrop(f.inset(-32, -32), 18);
    gfx.glass.drawGlass(canvas, f, @divTrunc(FIELD_H, 2), bd, style);
    const fg: u32 = if (dark) 0xF2FFFFFF else 0xE6000000;
    const sub: u32 = if (dark) 0x8CFFFFFF else 0x80000000;
    icons.drawSymbol(canvas, c.allocator, .magnifier, gfx.RectF.init(@floatFromInt(f.x + 20), @floatFromInt(f.y + 15), 24, 24), pm(sub));
    var t = font.Target.init(c.fb.pixels[0..@intCast(c.width * c.height)], @intCast(c.width), @intCast(c.height), @intCast(c.width));
    const cl = dirty.intersect(f.inset(56, 0));
    t.clip = .{ .x0 = cl.x, .y0 = cl.y, .x1 = cl.right(), .y1 = cl.bottom() };
    const face = c.fonts.face(.regular, 24);
    const baseline = @as(f32, @floatFromInt(f.y)) + (@as(f32, @floatFromInt(FIELD_H)) + face.cap_height) / 2;
    const q = state.spotlight.querySlice();
    if (q.len == 0) {
        _ = font.drawText(t, face, "Spotlight Search", @floatFromInt(f.x + 58), @round(baseline), pm(sub));
    } else {
        const end = font.drawText(t, face, q, @floatFromInt(f.x + 58), @round(baseline), pm(fg));
        canvas.fillRect(Rect.init(@as(i32, @intFromFloat(end)) + 2, f.y + 14, 2, FIELD_H - 28), pm(ui.Theme.get(dark, .blue).accent));
    }
    if (count == 0 or q.len == 0) return;

    // Results panel.
    const panel = Rect.init(f.x, f.bottom() + 12, f.w, @as(i32, @intCast(count)) * ROW_H + 16);
    if (c.shadow_focused.fits(panel)) c.shadow_focused.draw(canvas, panel.offset(0, 10), Color.rgba(0, 0, 0, 60), null);
    const bd2 = c.prepareBackdrop(panel.inset(-32, -32), 18);
    gfx.glass.drawGlass(canvas, panel, 22, bd2, style);
    for (res[0..count], 0..) |it, i| {
        const row = Rect.init(panel.x + 8, panel.y + 8 + @as(i32, @intCast(i)) * ROW_H, panel.w - 16, ROW_H);
        const sel = i == state.spotlight.selected;
        if (sel) canvas.fillRoundRect(row, 10, pm(ui.Theme.get(dark, .blue).accent));
        if (c.appIcon(if (it.icon.len > 0) it.icon else "generic", 32)) |img| canvas.drawImage(img, row.x + 8, row.y + 6, 255);
        var tt = t;
        const rc = dirty.intersect(row);
        tt.clip = .{ .x0 = rc.x, .y0 = rc.y, .x1 = rc.right(), .y1 = rc.bottom() };
        const rf = c.fonts.face(.medium, 15);
        _ = font.drawText(tt, rf, it.name, @floatFromInt(row.x + 52), @floatFromInt(row.y + 28), pm(if (sel) 0xFFFFFFFF else fg));
        const kind = "Application";
        const kf = c.fonts.face(.regular, 12);
        const kw = kf.measure(kind);
        _ = font.drawText(tt, kf, kind, @as(f32, @floatFromInt(row.right() - 14)) - kw, @floatFromInt(row.y + 27), pm(if (sel) 0xCCFFFFFF else sub));
    }
}
