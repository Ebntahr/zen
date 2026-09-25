//! System chrome drawn by the window server: menu bar, menus, Dock, app
//! switcher and notification banners — all in the Liquid Glass material.

const std = @import("std");
const gfx = @import("gfx");
const abi = @import("abi");
const ui = @import("ui");
const icons = @import("icons");
const font = @import("font");
const wm = @import("wm.zig");
const st = @import("state.zig");
const comp_mod = @import("compositor.zig");
const spotlight = @import("spotlight.zig");
const control = @import("control.zig");

const Canvas = gfx.Canvas;
const Color = gfx.Color;
const Rect = gfx.Rect;
const RectF = gfx.RectF;
const proto = abi.window;
const pm = ui.pm;
const Compositor = comp_mod.Compositor;

pub const MenuAction = union(enum) {
    app_item: u32,
    about,
    settings,
    lock,
    logout,
    restart,
    shutdown,
    force_quit,
    toggle_appearance,
};

// ---------------------------------------------------------------------------
// Layout (recomputed while drawing, used for hit testing)
// ---------------------------------------------------------------------------

const MAX_MENUS = 12;
const MAX_ITEMS = 40;

const MenuTitle = struct { x: i32 = 0, w: i32 = 0 };

const Item = struct {
    kind: enum { item, separator } = .item,
    title: []const u8 = "",
    key: u8 = 0,
    mods: u8 = 0,
    disabled: bool = false,
    checked: bool = false,
    action: MenuAction = .about,
    y: i32 = 0,
    h: i32 = 0,
};

const Layout = struct {
    titles: [MAX_MENUS]MenuTitle = [_]MenuTitle{.{}} ** MAX_MENUS,
    title_count: usize = 0,
    dock: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dock_hover: i32 = -1,
    panel: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    items: [MAX_ITEMS]Item = undefined,
    item_count: usize = 0,
    switcher: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

var layout: Layout = .{};

pub const DOCK_ICON: i32 = 54;
const DOCK_GAP: i32 = 10;
const DOCK_PAD: i32 = 10;
const DOCK_BOTTOM: i32 = 8;

fn session(state: *const st.State) bool {
    return state.session == .active;
}

// ---------------------------------------------------------------------------
// Text helper
// ---------------------------------------------------------------------------

fn target(c: *Compositor, clip: Rect) font.Target {
    var t = font.Target.init(c.fb.pixels[0..@intCast(c.width * c.height)], @intCast(c.width), @intCast(c.height), @intCast(c.width));
    const cl = clip.intersect(c.fb.clip);
    t.clip = .{ .x0 = cl.x, .y0 = cl.y, .x1 = cl.right(), .y1 = cl.bottom() };
    return t;
}

fn drawText(c: *Compositor, clip: Rect, x: f32, baseline: f32, s: []const u8, weight: ui.fonts.Weight, size: f32, color: u32) f32 {
    return font.drawText(target(c, clip), c.fonts.face(weight, size), s, x, baseline, pm(color));
}

fn measure(c: *Compositor, s: []const u8, weight: ui.fonts.Weight, size: f32) f32 {
    return c.fonts.face(weight, size).measure(s);
}

// ---------------------------------------------------------------------------
// Menu model
// ---------------------------------------------------------------------------

fn appMenuBlob(state: *st.State) []const u8 {
    const win = state.manager.get(state.manager.focused) orelse return "";
    return win.menu.items;
}

/// Titles of the top-level menus: 0 = Zen menu, 1 = app menu, 2.. = app menus.
fn menuTitles(state: *st.State, out: *[MAX_MENUS][]const u8) usize {
    out[0] = "";
    out[1] = state.activeAppName();
    var n: usize = 2;
    var r = proto.MenuReader{ .buf = appMenuBlob(state) };
    var first = true;
    while (r.next()) |e| {
        if (e.kind != .menu) continue;
        if (first) {
            first = false; // the application menu (title = app name)
            continue;
        }
        if (n < MAX_MENUS) {
            out[n] = e.title;
            n += 1;
        }
    }
    return n;
}

fn addItem(title: []const u8, key: u8, mods: u8, action: MenuAction) void {
    if (layout.item_count >= MAX_ITEMS) return;
    layout.items[layout.item_count] = .{ .title = title, .key = key, .mods = mods, .action = action };
    layout.item_count += 1;
}

fn addSeparator() void {
    if (layout.item_count >= MAX_ITEMS) return;
    layout.items[layout.item_count] = .{ .kind = .separator };
    layout.item_count += 1;
}

var about_buf: [96]u8 = undefined;
var hide_buf: [96]u8 = undefined;
var quit_buf: [96]u8 = undefined;
var logout_buf: [96]u8 = undefined;

/// Fill `layout.items` for the open menu.
fn buildItems(state: *st.State) void {
    layout.item_count = 0;
    const idx = state.menu.index;
    if (idx == 0) {
        addItem("About Zen OS", 0, 0, .about);
        addSeparator();
        addItem("System Settings…", ',', 0, .settings);
        addItem(if (state.appearance.dark) "Light Appearance" else "Dark Appearance", 0, 0, .toggle_appearance);
        addSeparator();
        addItem("Force Quit…", 0, 0, .force_quit);
        addSeparator();
        addItem("Restart…", 0, 0, .restart);
        addItem("Shut Down…", 0, 0, .shutdown);
        addSeparator();
        addItem("Lock Screen", 'q', @intCast(proto.Mods.cmd | proto.Mods.ctrl), .lock);
        const lo = std.fmt.bufPrint(&logout_buf, "Log Out {s}…", .{state.userName()}) catch "Log Out…";
        addItem(lo, 'Q', @intCast(proto.Mods.cmd | proto.Mods.shift), .logout);
        return;
    }
    // Application-provided menus.
    var r = proto.MenuReader{ .buf = appMenuBlob(state) };
    var menu_no: i32 = 0;
    var inside = false;
    var any = false;
    while (r.next()) |e| {
        switch (e.kind) {
            .menu => {
                menu_no += 1;
                inside = menu_no == idx;
            },
            .end => inside = false,
            .separator => if (inside) addSeparator(),
            .item => if (inside) {
                any = true;
                addItem(e.title, e.key, e.mods, .{ .app_item = e.id });
                layout.items[layout.item_count - 1].disabled = e.flags & proto.MenuItemFlags.disabled != 0;
                layout.items[layout.item_count - 1].checked = e.flags & proto.MenuItemFlags.checked != 0;
            },
        }
    }
    if (idx == 1 and !any) {
        const name = state.activeAppName();
        addItem(std.fmt.bufPrint(&about_buf, "About {s}", .{name}) catch "About", 0, 0, .about);
        addSeparator();
        addItem(std.fmt.bufPrint(&hide_buf, "Hide {s}", .{name}) catch "Hide", 'h', 0, .force_quit);
        layout.item_count -= 1; // hide handled by the shortcut
        addItem(std.fmt.bufPrint(&quit_buf, "Quit {s}", .{name}) catch "Quit", 'q', 0, .force_quit);
    }
}

// ---------------------------------------------------------------------------
// Hit testing API used by input.zig
// ---------------------------------------------------------------------------

pub fn menubarContains(state: *const st.State, x: i32, y: i32) bool {
    _ = x;
    return session(state) and y >= 0 and y < wm.MENUBAR;
}

pub fn menuPanelContains(state: *const st.State, x: i32, y: i32) bool {
    return state.menu.index >= 0 and layout.panel.contains(x, y);
}

pub fn overChrome(state: *const st.State, x: i32, y: i32) bool {
    if (!session(state)) return false;
    if (control.open and control.rect(state).contains(x, y)) return true;
    if (y < wm.MENUBAR) return true;
    if (layout.dock.contains(x, y)) return true;
    if (state.menu.index >= 0 and layout.panel.contains(x, y)) return true;
    return false;
}

fn titleAt(x: i32) i32 {
    for (layout.titles[0..layout.title_count], 0..) |t, i| {
        if (x >= t.x - 8 and x < t.x + t.w + 8) return @intCast(i);
    }
    return -1;
}

pub fn menubarClick(state: *st.State, x: i32, y: i32) void {
    _ = y;
    const i = titleAt(x);
    if (i < 0 or i == state.menu.index) {
        closeMenu(state);
        return;
    }
    openMenu(state, i);
}

fn invalidateMenu(state: *st.State) void {
    state.invalidate(.{ .w = state.width, .h = wm.MENUBAR });
    state.invalidate(comp_mod.fromG(layout.panel.inset(-30, -30)));
}

fn openMenu(state: *st.State, i: i32) void {
    invalidateMenu(state);
    state.menu.index = i;
    state.menu.hover = -1;
    buildItems(state);
    layout.panel = Rect.init(0, 0, 0, 0);
    // Panel geometry is finalized during drawing; invalidate generously.
    state.invalidate(.{ .x = 0, .y = 0, .w = state.width, .h = wm.MENUBAR + 20 + @as(i32, @intCast(layout.item_count)) * 24 });
}

pub fn closeMenu(state: *st.State) void {
    invalidateMenu(state);
    state.menu.index = -1;
    state.menu.hover = -1;
}

pub fn menuHover(state: *st.State, x: i32, y: i32) void {
    if (y < wm.MENUBAR) {
        const i = titleAt(x);
        if (i >= 0 and i != state.menu.index) openMenu(state, i);
        return;
    }
    var hover: i32 = -1;
    if (layout.panel.contains(x, y)) {
        for (layout.items[0..layout.item_count], 0..) |it, i| {
            if (it.kind == .item and !it.disabled and y >= it.y and y < it.y + it.h) hover = @intCast(i);
        }
    }
    if (hover != state.menu.hover) {
        state.menu.hover = hover;
        state.invalidate(comp_mod.fromG(layout.panel.inset(-2, -2)));
    }
}

pub fn menuActivate(state: *st.State) ?MenuAction {
    const h = state.menu.hover;
    const action: ?MenuAction = if (h >= 0 and h < layout.item_count) layout.items[@intCast(h)].action else null;
    closeMenu(state);
    return action;
}

var flash_until: u64 = 0;

pub fn flashMenuTitle(state: *st.State, id: u32) void {
    _ = id;
    flash_until = state.now_ms + 150;
    state.invalidate(.{ .w = state.width, .h = wm.MENUBAR });
}

pub fn dockHover(state: *st.State, x: i32, y: i32) void {
    var hover: i32 = -1;
    if (layout.dock.contains(x, y)) {
        for (state.dock.items, 0..) |item, i| {
            if (comp_mod.toG(item.rect).inset(-DOCK_GAP / 2, -DOCK_PAD).contains(x, y)) hover = @intCast(i);
        }
    }
    if (hover != layout.dock_hover) {
        layout.dock_hover = hover;
        state.invalidate(comp_mod.fromG(layout.dock.inset(-40, -60)));
    }
}

pub fn dockClick(state: *st.State, x: i32, y: i32) ?[]const u8 {
    if (!layout.dock.contains(x, y)) return null;
    for (state.dock.items) |*item| {
        if (comp_mod.toG(item.rect).inset(-DOCK_GAP / 2, -DOCK_PAD).contains(x, y)) {
            item.bounce_until_ms = state.now_ms + 600;
            return item.id;
        }
    }
    return null;
}

pub fn broadcastAppearance(state: *st.State) void {
    const theme = ui.theme;
    const acc: theme.Accent = @enumFromInt(@min(state.appearance.accent, 7));
    for (state.manager.windows.items) |w| {
        w.pushEvent(.{ .kind = .appearance, .a = @intFromBool(state.appearance.dark), .b = @bitCast(acc.color(state.appearance.dark)), .c = @intFromBool(state.appearance.reduce_transparency) });
    }
    state.appearance_serial +%= 1;
    state.invalidateAll();
}

// ---------------------------------------------------------------------------
// App switcher (Cmd-Tab)
// ---------------------------------------------------------------------------

const MAX_SWITCH = 16;
var switch_ids: [MAX_SWITCH][]const u8 = undefined;
var switch_count: usize = 0;

fn collectSwitcher(state: *st.State) void {
    switch_count = 0;
    var i = state.manager.order.items.len;
    while (i > 0) {
        i -= 1;
        const w = state.manager.get(state.manager.order.items[i]) orelse continue;
        if (w.layer != .normal or w.app_id_len == 0) continue;
        const id = w.appId();
        var dup = false;
        for (switch_ids[0..switch_count]) |s| {
            if (std.mem.eql(u8, s, id)) dup = true;
        }
        if (!dup and switch_count < MAX_SWITCH) {
            switch_ids[switch_count] = id;
            switch_count += 1;
        }
    }
}

pub fn switcherStep(state: *st.State, backwards: bool) void {
    if (!state.switcher.active) {
        collectSwitcher(state);
        if (switch_count == 0) return;
        state.switcher.active = true;
        state.switcher.selected = if (switch_count > 1) 1 else 0;
    } else if (switch_count > 0) {
        if (backwards) {
            state.switcher.selected = (state.switcher.selected + switch_count - 1) % switch_count;
        } else {
            state.switcher.selected = (state.switcher.selected + 1) % switch_count;
        }
    }
    state.invalidate(comp_mod.fromG(layout.switcher.inset(-40, -40)));
    state.invalidate(comp_mod.fromG(switcherRect(state).inset(-40, -40)));
}

pub fn switcherCommit(state: *st.State) ?[]const u8 {
    if (!state.switcher.active) return null;
    state.switcher.active = false;
    state.invalidate(comp_mod.fromG(layout.switcher.inset(-40, -40)));
    if (state.switcher.selected < switch_count) return switch_ids[state.switcher.selected];
    return null;
}

pub fn switcherCancel(state: *st.State) void {
    state.switcher.active = false;
    state.invalidate(comp_mod.fromG(layout.switcher.inset(-40, -40)));
}

fn switcherRect(state: *const st.State) Rect {
    const n: i32 = @intCast(@max(switch_count, 1));
    const w = n * 112 + 32;
    const h: i32 = 150;
    return Rect.init(@divTrunc(state.width - w, 2), @divTrunc(state.height - h, 2), w, h);
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn dockRect(state: *const st.State) Rect {
    const n: i32 = @intCast(state.dock.items.len);
    var w = n * DOCK_ICON + @max(n - 1, 0) * DOCK_GAP + 2 * DOCK_PAD;
    // Separator before trailing unpinned/trash items.
    w += 14;
    const h = DOCK_ICON + 2 * DOCK_PAD;
    return Rect.init(@divTrunc(state.width - w, 2), state.height - h - DOCK_BOTTOM, w, h);
}

fn menubarRect(state: *const st.State) Rect {
    return Rect.init(0, 0, state.width, wm.MENUBAR);
}

/// Grow a dirty rectangle to cover whole glass elements it touches (their
/// refraction samples beyond the damaged pixels).
pub fn expandDirty(state: *const st.State, d: Rect) Rect {
    var out = d;
    if (!session(state)) return out;
    const elements = [_]Rect{
        menubarRect(state),
        dockRect(state).inset(-4, -4),
        if (state.menu.index >= 0) layout.panel.inset(-4, -4) else Rect.init(0, 0, 0, 0),
        if (state.switcher.active) switcherRect(state).inset(-4, -4) else Rect.init(0, 0, 0, 0),
        if (state.spotlight.active) spotlight.bounds(state).inset(-4, -4) else Rect.init(0, 0, 0, 0),
        if (control.open) control.rect(state).inset(-4, -4) else Rect.init(0, 0, 0, 0),
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (elements) |e| {
            if (e.isEmpty()) continue;
            if (out.intersects(e) and !out.containsRect(e)) {
                out = out.unionWith(e);
                changed = true;
            }
        }
    }
    return out;
}

/// Draw a glass panel, clipped to the region being composed (content
/// drawn over it is clipped the same way, so it must not paint outside).
fn glass(c: *Compositor, r: Rect, radius: f32, style: gfx.GlassStyle, dark: bool) void {
    const blur_pad: i32 = 32;
    const bd = c.prepareBackdrop(r.inset(-blur_pad, -blur_pad), 18);
    var s = style;
    if (dark) {
        s.tint = Color.rgba(28, 28, 34, 120);
        s.brightness = 0.9;
    }
    gfx.glass.drawGlass(c.fb.withClip(c.composing), r, @intFromFloat(radius), bd, s);
}

fn drawMenuBar(c: *Compositor, state: *st.State, dirty: Rect) void {
    const bar = menubarRect(state);
    if (!bar.intersects(dirty)) {
        // Titles still need layout for hit testing.
    }
    const dark = state.dark();
    // A subtle frosted strip; the macOS 26 menu bar is almost transparent.
    var style = gfx.GlassStyle.clear;
    style.refraction = 3;
    style.bevel = 6;
    style.rim_light = 0.25;
    style.rim_base = 0.05;
    style.tint = if (dark or c.menubar_on_dark) Color.rgba(0, 0, 0, 40) else Color.rgba(255, 255, 255, 50);
    const bd = c.prepareBackdrop(bar.inset(0, -24), 24);
    gfx.glass.drawGlass(c.fb.withClip(bar.intersect(c.composing)), bar.inset(-20, 0).offset(0, -10), 0, bd, style);

    const text_color: u32 = if (dark or c.menubar_on_dark) 0xF2FFFFFF else 0xE6000000;
    const baseline: f32 = 20;
    // Zen menu (logo).
    const logo = Rect.init(14, 7, 16, 16);
    icons.drawZenMark(c.fb.withClip(dirty), c.allocator, RectF.init(@floatFromInt(logo.x), @floatFromInt(logo.y), 16, 16), pm(text_color));
    layout.titles[0] = .{ .x = 12, .w = 20 };

    var titles: [MAX_MENUS][]const u8 = undefined;
    const n = menuTitles(state, &titles);
    var x: f32 = 46;
    layout.title_count = n;
    for (titles[1..n], 1..) |t, i| {
        const weight: ui.fonts.Weight = if (i == 1) .bold else .medium;
        const w = measure(c, t, weight, 13);
        const xi: i32 = @intFromFloat(x);
        layout.titles[i] = .{ .x = xi, .w = @intFromFloat(@ceil(w)) };
        if (state.menu.index == @as(i32, @intCast(i))) {
            c.fb.withClip(dirty).fillRoundRect(Rect.init(xi - 8, 4, @as(i32, @intFromFloat(w)) + 16, wm.MENUBAR - 8), 6, pm(if (dark) 0x33FFFFFF else 0x26000000));
        }
        _ = drawText(c, dirty, x, baseline, t, weight, 13, text_color);
        x += w + 22;
    }
    if (state.menu.index == 0) {
        c.fb.withClip(dirty).fillRoundRect(Rect.init(6, 4, 32, wm.MENUBAR - 8), 6, pm(if (dark) 0x33FFFFFF else 0x26000000));
        icons.drawZenMark(c.fb.withClip(dirty), c.allocator, RectF.init(@floatFromInt(logo.x), @floatFromInt(logo.y), 16, 16), pm(text_color));
    }

    // Right side: keyboard layout, user, clock.
    var clock_buf: [48]u8 = undefined;
    const clock = clockText(state, &clock_buf);
    const cw = measure(c, clock, .medium, 13);
    var rx = @as(f32, @floatFromInt(state.width)) - 16 - cw;
    _ = drawText(c, dirty, rx, baseline, clock, .medium, 13, text_color);
    const kb: []const u8 = if (state.keys.arabic) "ع" else "EN";
    const kw = measure(c, kb, .semibold, 11);
    rx -= kw + 26;
    c.fb.withClip(dirty).strokeRoundRect(Rect.init(@as(i32, @intFromFloat(rx)) - 5, 7, @as(i32, @intFromFloat(kw)) + 10, 16), 4, 1.2, pm(text_color));
    _ = drawText(c, dirty, rx, 19.5, kb, .semibold, 11, text_color);
    const user = state.userName();
    if (user.len > 0) {
        const uw = measure(c, user, .medium, 13);
        rx -= uw + 22;
        icons.drawSymbol(c.fb.withClip(dirty), c.allocator, .person, RectF.init(rx - 18, 8, 14, 14), pm(text_color));
        _ = drawText(c, dirty, rx, baseline, user, .medium, 13, text_color);
    }
}

fn clockText(state: *st.State, buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "";
    const secs: i64 = ts.sec + @as(i64, state.appearance.tz_offset_min) * 60;
    state.clock_minute = @divFloor(secs, 60);
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const wday_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const wday = wday_names[@intCast(@mod(days, 7))];
    const hour: i64 = @divFloor(rem, 3600);
    const minute: i64 = @divFloor(@mod(rem, 3600), 60);
    if (state.appearance.clock_24h) {
        return std.fmt.bufPrint(buf, "{s} {d} {s}  {d:0>2}:{d:0>2}", .{ wday, md.day_index + 1, month_names[@intFromEnum(md.month) - 1], @as(u64, @intCast(hour)), @as(u64, @intCast(minute)) }) catch "";
    }
    const h12 = if (@mod(hour, 12) == 0) 12 else @mod(hour, 12);
    return std.fmt.bufPrint(buf, "{s} {d} {s}  {d}:{d:0>2} {s}", .{ wday, md.day_index + 1, month_names[@intFromEnum(md.month) - 1], @as(u64, @intCast(h12)), @as(u64, @intCast(minute)), if (hour < 12) "AM" else "PM" }) catch "";
}

fn shortcutText(item: Item, buf: []u8) []const u8 {
    if (item.key == 0) return "";
    var n: usize = 0;
    var mods: u32 = item.mods;
    if (mods == 0) mods = proto.Mods.cmd;
    if (std.ascii.isUpper(item.key)) mods |= proto.Mods.shift;
    const parts = [_]struct { u32, []const u8 }{
        .{ proto.Mods.ctrl, "⌃" },
        .{ proto.Mods.alt, "⌥" },
        .{ proto.Mods.shift, "⇧" },
        .{ proto.Mods.cmd, "⌘" },
    };
    for (parts) |p| {
        if (mods & p[0] != 0) {
            @memcpy(buf[n .. n + p[1].len], p[1]);
            n += p[1].len;
        }
    }
    buf[n] = std.ascii.toUpper(item.key);
    return buf[0 .. n + 1];
}

fn drawMenuPanel(c: *Compositor, state: *st.State, dirty: Rect) void {
    if (state.menu.index < 0) return;
    const idx: usize = @intCast(state.menu.index);
    if (idx >= layout.title_count) return;
    buildItems(state);
    // Size the panel.
    var width: f32 = 220;
    var h: i32 = 12;
    for (layout.items[0..layout.item_count]) |*it| {
        if (it.kind == .separator) {
            it.h = 11;
        } else {
            it.h = 24;
            var sb: [32]u8 = undefined;
            const w = measure(c, it.title, .regular, 13) + measure(c, shortcutText(it.*, &sb), .regular, 13) + 80;
            width = @max(width, w);
        }
        h += it.h;
    }
    const tx = layout.titles[idx].x;
    var px: i32 = tx - 10;
    if (px + @as(i32, @intFromFloat(width)) > state.width - 8) px = state.width - 8 - @as(i32, @intFromFloat(width));
    layout.panel = Rect.init(@max(px, 6), wm.MENUBAR + 4, @intFromFloat(width), h);
    const panel = layout.panel;
    if (!panel.inset(-30, -30).intersects(dirty)) return;
    const dark = state.dark();
    if (c.shadow_popup.fits(panel)) c.shadow_popup.draw(c.fb.withClip(dirty), panel.offset(0, 8), Color.rgba(0, 0, 0, 70), null);
    var style = gfx.GlassStyle.light;
    style.tint = if (dark) Color.rgba(40, 40, 46, 200) else Color.rgba(250, 250, 252, 200);
    style.refraction = 5;
    style.bevel = 10;
    glass(c, panel, 12, style, false);

    var y = panel.y + 6;
    const t = ui.Theme.get(dark, .blue);
    for (layout.items[0..layout.item_count], 0..) |*it, i| {
        it.y = y;
        if (it.kind == .separator) {
            c.fb.withClip(dirty).fillRect(Rect.init(panel.x + 12, y + 5, panel.w - 24, 1), pm(t.separator));
        } else {
            const hovered = state.menu.hover == @as(i32, @intCast(i));
            if (hovered) c.fb.withClip(dirty).fillRoundRect(Rect.init(panel.x + 5, y, panel.w - 10, it.h), 6, pm(t.accent));
            const col: u32 = if (it.disabled) t.tertiary_label else if (hovered) 0xFFFFFFFF else t.label;
            const bl: f32 = @floatFromInt(y + 16);
            if (it.checked) _ = drawText(c, dirty, @floatFromInt(panel.x + 10), bl, "✓", .semibold, 12, col);
            _ = drawText(c, dirty, @floatFromInt(panel.x + 26), bl, it.title, .regular, 13, col);
            var sb: [32]u8 = undefined;
            const sc_text = shortcutText(it.*, &sb);
            if (sc_text.len > 0) {
                const sw = measure(c, sc_text, .regular, 13);
                _ = drawText(c, dirty, @as(f32, @floatFromInt(panel.right() - 14)) - sw, bl, sc_text, .regular, 13, if (hovered) 0xDDFFFFFF else t.secondary_label);
            }
        }
        y += it.h;
    }
}

fn drawDock(c: *Compositor, state: *st.State, dirty: Rect) void {
    const dock = dockRect(state);
    layout.dock = dock;
    if (!dock.inset(-40, -70).intersects(dirty)) {
        // Nothing to draw; still lay out the item rects for hit testing.
        var lx = dock.x + DOCK_PAD;
        for (state.dock.items) |*item| {
            if (std.mem.eql(u8, item.id, "trash")) lx += 14;
            item.rect = .{ .x = lx, .y = dock.y + DOCK_PAD, .w = DOCK_ICON, .h = DOCK_ICON };
            lx += DOCK_ICON + DOCK_GAP;
        }
        return;
    }
    const dark = state.dark();
    // Shadow under the floating dock.
    if (c.shadow_normal.fits(dock)) c.shadow_normal.draw(c.fb.withClip(dirty), dock.offset(0, 6), Color.rgba(0, 0, 0, 50), null);
    glass(c, dock, 24, gfx.GlassStyle.clear, dark);

    var x = dock.x + DOCK_PAD;
    const y = dock.y + DOCK_PAD;
    for (state.dock.items, 0..) |*item, i| {
        if (std.mem.eql(u8, item.id, "trash")) {
            // Separator before the trash.
            c.fb.withClip(dirty).fillRect(Rect.init(x + 1, dock.y + 14, 1, dock.h - 28), pm(if (dark) 0x40FFFFFF else 0x33000000));
            x += 14;
        }
        var iy = y;
        if (item.bounce_until_ms > state.now_ms) {
            const tleft: f32 = @floatFromInt(item.bounce_until_ms - state.now_ms);
            iy -= @intFromFloat(@abs(@sin(tleft / 600 * std.math.pi * 2)) * 14);
        }
        item.rect = .{ .x = x, .y = y, .w = DOCK_ICON, .h = DOCK_ICON };
        if (c.appIcon(item.icon, DOCK_ICON)) |img| c.fb.withClip(dirty).drawImage(img, x, iy, 255);
        if (item.running) {
            c.fb.withClip(dirty).fillCircle(@as(f32, @floatFromInt(x)) + DOCK_ICON / 2, @floatFromInt(dock.bottom() - 5), 2.2, pm(if (dark) 0xDDFFFFFF else 0xB0000000));
        }
        if (layout.dock_hover == @as(i32, @intCast(i))) {
            // Tooltip.
            const tw: i32 = @intFromFloat(measure(c, item.name, .medium, 13));
            const tip = Rect.init(x + DOCK_ICON / 2 - @divTrunc(tw, 2) - 12, dock.y - 38, tw + 24, 26);
            var style = gfx.GlassStyle.light;
            style.tint = if (dark) Color.rgba(40, 40, 46, 190) else Color.rgba(250, 250, 252, 190);
            style.refraction = 3;
            style.bevel = 6;
            glass(c, tip, 13, style, false);
            _ = drawText(c, dirty, @floatFromInt(tip.x + 12), @floatFromInt(tip.y + 18), item.name, .medium, 13, if (dark) 0xF2FFFFFF else 0xE6000000);
        }
        x += DOCK_ICON + DOCK_GAP;
    }
}

fn drawSwitcher(c: *Compositor, state: *st.State, dirty: Rect) void {
    if (!state.switcher.active or switch_count == 0) return;
    const r = switcherRect(state);
    layout.switcher = r;
    const dark = state.dark();
    if (c.shadow_focused.fits(r)) c.shadow_focused.draw(c.fb.withClip(dirty), r.offset(0, 10), Color.rgba(0, 0, 0, 80), null);
    var style = gfx.GlassStyle.light;
    style.tint = if (dark) Color.rgba(30, 30, 36, 170) else Color.rgba(245, 245, 250, 150);
    glass(c, r, 28, style, false);
    var x = r.x + 16;
    for (switch_ids[0..switch_count], 0..) |id, i| {
        const cell = Rect.init(x, r.y + 14, 112, 112);
        if (i == state.switcher.selected) c.fb.withClip(dirty).fillRoundRect(cell.inset(4, 4), 18, pm(if (dark) 0x40FFFFFF else 0x26000000));
        var icon_name: []const u8 = "generic";
        var name: []const u8 = id;
        for (state.dock.items) |d| {
            if (std.mem.eql(u8, d.id, id)) {
                icon_name = d.icon;
                name = d.name;
            }
        }
        if (c.appIcon(icon_name, 88)) |img| c.fb.withClip(dirty).drawImage(img, x + 12, r.y + 26, 255);
        if (i == state.switcher.selected) {
            const w = measure(c, name, .medium, 13);
            _ = drawText(c, dirty, @as(f32, @floatFromInt(x + 56)) - w / 2, @floatFromInt(r.bottom() - 12), name, .medium, 13, if (dark) 0xF2FFFFFF else 0xE6000000);
        }
        x += 112;
    }
}

fn drawNotifications(c: *Compositor, state: *st.State, dirty: Rect) void {
    var y: i32 = wm.MENUBAR + 10;
    const dark = state.dark();
    for (state.notifications.items) |*n| {
        const r = Rect.init(state.width - 372, y, 360, 74);
        y += 84;
        if (!r.inset(-30, -30).intersects(dirty)) continue;
        if (c.shadow_popup.fits(r)) c.shadow_popup.draw(c.fb.withClip(dirty), r.offset(0, 6), Color.rgba(0, 0, 0, 60), null);
        var style = gfx.GlassStyle.light;
        style.tint = if (dark) Color.rgba(36, 36, 42, 190) else Color.rgba(250, 250, 252, 170);
        glass(c, r, 22, style, false);
        if (c.appIcon("generic", 40)) |img| c.fb.withClip(dirty).drawImage(img, r.x + 14, r.y + 17, 255);
        const fg: u32 = if (dark) 0xF2FFFFFF else 0xE6000000;
        const sub: u32 = if (dark) 0x99FFFFFF else 0x8C000000;
        const clip = Rect.init(r.x + 64, r.y, r.w - 76, r.h);
        _ = drawText(c, clip, @floatFromInt(r.x + 64), @floatFromInt(r.y + 29), n.title[0..n.title_len], .semibold, 13, fg);
        _ = drawText(c, clip, @floatFromInt(r.x + 64), @floatFromInt(r.y + 50), n.body[0..n.body_len], .regular, 13, sub);
        _ = drawText(c, clip, @floatFromInt(r.right() - 44), @floatFromInt(r.y + 29), "now", .regular, 11, sub);
    }
}

/// Draw all chrome intersecting `dirty` (called by the compositor after
/// windows and before shields).
pub fn draw(c: *Compositor, state: *st.State, dirty: Rect) void {
    if (!session(state)) return;
    const bar = menubarRect(state);
    if (bar.intersects(dirty)) drawMenuBar(c, state, dirty);
    drawDock(c, state, dirty);
    drawNotifications(c, state, dirty);
    drawMenuPanel(c, state, dirty);
    drawSwitcher(c, state, dirty);
    spotlight.draw(c, state, dirty);
    control.draw(c, state, dirty);
}
