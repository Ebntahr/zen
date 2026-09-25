//! Activity Monitor: processes, CPU, memory and disk activity (macOS 26
//! style). Data is sampled every two seconds by `procs.Sampler`; frames in
//! between (mouse, keyboard) only redraw.

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const gfx = @import("gfx");
const icons = @import("icons");
const zen = @import("zen");
const procs = @import("procs.zig");

const Ui = ui.Ui;
const Rect = ui.Rect;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const Flags = abi.window.Flags;
const Proc = procs.Proc;
const shapes = gfx.shapes;
const pm = ui.pm;

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

const toolbar_h: i32 = 52;
const header_h: i32 = 28;
const row_h: i32 = 24;
const panel_h: i32 = 132;
const cell_pad: i32 = 10;
const icon_px = 16;
const icon_pxf: f32 = icon_px;
const refresh_ms: i64 = 2000;

// Colors used for statistics (system red, user blue, like macOS).
const red: u32 = 0xFFFF3B30;
const red_dark: u32 = 0xFFFF453A;
const blue: u32 = 0xFF007AFF;
const blue_dark: u32 = 0xFF0A84FF;
const green: u32 = 0xFF34C759;
const yellow: u32 = 0xFFFFCC00;

pub const Tab = enum(u8) { cpu, memory, disk, system };
const tab_titles = [_][]const u8{ "CPU", "Memory", "Disk", "System" };

const SortKey = enum { name, cpu, cpu_time, threads, pid, user, memory, sandboxed, written, read, state, ppid, nice, running, vsize };

const Col = struct {
    title: []const u8,
    key: SortKey,
    /// 0 = takes the remaining width.
    width: i32,
    right: bool = true,
    /// Columns with a higher number are hidden first in narrow windows
    /// (0 = always shown).
    optional: u8 = 0,
};

const cpu_cols = [_]Col{
    .{ .title = "Process Name", .key = .name, .width = 0, .right = false },
    .{ .title = "% CPU", .key = .cpu, .width = 80 },
    .{ .title = "CPU Time", .key = .cpu_time, .width = 96, .optional = 1 },
    .{ .title = "Threads", .key = .threads, .width = 80, .optional = 2 },
    .{ .title = "PID", .key = .pid, .width = 76 },
    .{ .title = "User", .key = .user, .width = 112, .right = false },
};
const memory_cols = [_]Col{
    .{ .title = "Process Name", .key = .name, .width = 0, .right = false },
    .{ .title = "Memory", .key = .memory, .width = 100 },
    .{ .title = "Threads", .key = .threads, .width = 80, .optional = 2 },
    .{ .title = "PID", .key = .pid, .width = 76 },
    .{ .title = "User", .key = .user, .width = 112, .right = false },
    .{ .title = "Sandboxed", .key = .sandboxed, .width = 100, .right = false, .optional = 1 },
};
const disk_cols = [_]Col{
    .{ .title = "Process Name", .key = .name, .width = 0, .right = false },
    .{ .title = "Bytes Written", .key = .written, .width = 120 },
    .{ .title = "Bytes Read", .key = .read, .width = 120 },
    .{ .title = "PID", .key = .pid, .width = 76 },
    .{ .title = "User", .key = .user, .width = 112, .right = false },
};
const system_cols = [_]Col{
    .{ .title = "Process Name", .key = .name, .width = 0, .right = false },
    .{ .title = "State", .key = .state, .width = 92, .right = false, .optional = 1 },
    .{ .title = "Parent", .key = .ppid, .width = 76, .optional = 2 },
    .{ .title = "Nice", .key = .nice, .width = 64, .optional = 3 },
    .{ .title = "Running Time", .key = .running, .width = 116 },
    .{ .title = "Virtual Memory", .key = .vsize, .width = 124, .optional = 1 },
    .{ .title = "PID", .key = .pid, .width = 76 },
    .{ .title = "User", .key = .user, .width = 96, .right = false },
};

fn columns(tab: Tab) []const Col {
    return switch (tab) {
        .cpu => &cpu_cols,
        .memory => &memory_cols,
        .disk => &disk_cols,
        .system => &system_cols,
    };
}

const Sort = struct { key: SortKey, desc: bool };

fn defaultDesc(key: SortKey) bool {
    return switch (key) {
        .name, .user, .state, .sandboxed, .pid, .ppid, .nice => false,
        else => true,
    };
}

const Sheet = enum { none, quit, info };

// Menu ids.
const menu_about: u32 = 1;
const menu_quit_app: u32 = 2;
const menu_tab0: u32 = 10; // + tab index
const menu_update: u32 = 20;
const menu_inspect: u32 = 21;
const menu_quit_process: u32 = 22;
const menu_find: u32 = 30;

const search_id = "am-search";

/// Mouse state hidden from widgets underneath a sheet.
const InputState = struct {
    x: i32,
    y: i32,
    pressed: bool,
    released: bool,
    scroll: f32,

    fn save(u: *const Ui) InputState {
        return .{ .x = u.mouse_x, .y = u.mouse_y, .pressed = u.mouse_pressed, .released = u.mouse_released, .scroll = u.scroll_dy };
    }

    fn restore(self: InputState, u: *Ui) void {
        u.mouse_x = self.x;
        u.mouse_y = self.y;
        u.mouse_pressed = self.pressed;
        u.mouse_released = self.released;
        u.scroll_dy = self.scroll;
    }

    fn block(u: *Ui) void {
        u.mouse_x = -1000;
        u.mouse_y = -1000;
        u.mouse_pressed = false;
        u.mouse_released = false;
        u.scroll_dy = 0;
        u.keys_consumed = true;
    }
};

/// Small per-frame string arena (avoids heap allocations while drawing).
const StrBuf = struct {
    buf: [2048]u8 = undefined,
    n: usize = 0,

    fn print(self: *StrBuf, comptime fmt: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(self.buf[self.n..], fmt, args) catch return "";
        self.n += out.len;
        return out;
    }

    fn keep(self: *StrBuf, s: []const u8) []const u8 {
        if (self.n + s.len > self.buf.len) return s;
        @memcpy(self.buf[self.n .. self.n + s.len], s);
        const out = self.buf[self.n .. self.n + s.len];
        self.n += s.len;
        return out;
    }
};

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Activity Monitor",
        .width = 820,
        .height = 520,
        .min_width = 660,
        .min_height = 380,
        .flags = Flags.resizable | Flags.full_size_content,
    };

    allocator: std.mem.Allocator,
    sampler: procs.Sampler,
    tab: Tab = .cpu,
    sorts: [4]Sort = .{
        .{ .key = .cpu, .desc = true },
        .{ .key = .memory, .desc = true },
        .{ .key = .written, .desc = true },
        .{ .key = .pid, .desc = false },
    },
    /// Indices into `sampler.procs` (filtered and sorted).
    order: std.ArrayList(u32) = .empty,
    selected: ?u32 = null,
    scroll: ui.ScrollState = .{},
    search: ui.TextState = .{},
    last_refresh: i64 = 0,
    /// Previews freeze the seeded sample data.
    frozen: bool = false,

    sheet: Sheet = .none,
    sheet_pid: u32 = 0,
    sheet_error: []const u8 = "",
    sheet_icon: ?gfx.Image = null,

    app_icons: std.EnumArray(icons.AppIcon, ?gfx.Image) = .initFill(null),
    gear_icon: ?gfx.Image = null,
    menu_buf: [1024]u8 = undefined,
    /// Whether the last menu sent had the process items enabled.
    menu_sel: bool = false,
    uts: ?std.os.linux.utsname = null,

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        u.win.setTitleHeight(toolbar_h);
        var app = App{
            .allocator = allocator,
            .sampler = procs.Sampler.init(allocator),
        };
        var uts: std.os.linux.utsname = undefined;
        if (std.os.linux.uname(&uts) == 0) app.uts = uts;
        app.refreshNow();
        return app;
    }

    pub fn deinit(self: *App) void {
        self.sampler.deinit();
        self.order.deinit(self.allocator);
        self.search.deinit(self.allocator);
        if (self.sheet_icon) |*img| img.deinit(self.allocator);
        for (&self.app_icons.values) |*v| {
            if (v.*) |*img| img.deinit(self.allocator);
        }
        if (self.gear_icon) |*img| img.deinit(self.allocator);
    }

    pub fn timeoutMs(self: *App) i32 {
        if (self.frozen) return -1;
        const left = refresh_ms - (std.time.milliTimestamp() - self.last_refresh);
        return @intCast(std.math.clamp(left, 1, refresh_ms));
    }

    pub fn refreshNow(self: *App) void {
        self.sampler.refresh();
        self.last_refresh = std.time.milliTimestamp();
        self.rebuildOrder();
    }

    // ------------------------------------------------------------------
    // Menus
    // ------------------------------------------------------------------

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        const checked = abi.window.MenuItemFlags.checked;
        const disabled = abi.window.MenuItemFlags.disabled;
        mw.beginMenu("Activity Monitor");
        mw.item(menu_about, "About Activity Monitor", 0, 0, 0);
        mw.separator();
        mw.item(menu_quit_app, "Quit Activity Monitor", 'q', 0, 0);
        mw.endMenu();
        mw.beginMenu("Edit");
        mw.item(menu_find, "Find", 'f', 0, 0);
        mw.endMenu();
        mw.beginMenu("View");
        for (tab_titles, 0..) |t, i| {
            mw.item(menu_tab0 + @as(u32, @intCast(i)), t, '1' + @as(u8, @intCast(i)), 0, if (@intFromEnum(self.tab) == i) checked else 0);
        }
        mw.separator();
        mw.item(menu_update, "Update Now", 'r', 0, 0);
        mw.separator();
        self.menu_sel = self.selected != null;
        const sel: u8 = if (self.selected == null) disabled else 0;
        mw.item(menu_inspect, "Inspect Process", 'i', 0, sel);
        mw.item(menu_quit_process, "Quit Process", 'q', @intCast(Mods.cmd | Mods.alt), sel);
        mw.endMenu();
    }

    fn resendMenu(self: *App, u: *Ui) void {
        var mw = abi.window.MenuWriter{ .buf = &self.menu_buf };
        self.menu(&mw);
        u.win.setMenu(mw.bytes());
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        switch (id) {
            menu_quit_app => u.quit = true,
            menu_about => u.win.notify("Activity Monitor", "Zen OS Activity Monitor 1.0"),
            menu_update => self.refreshNow(),
            menu_inspect => if (self.selected) |pid| self.openSheet(.info, pid),
            menu_quit_process => if (self.selected) |pid| self.openSheet(.quit, pid),
            menu_find => u.focus = ui.ui.hashId(search_id),
            else => if (id >= menu_tab0 and id < menu_tab0 + 4) self.setTab(u, @enumFromInt(id - menu_tab0)),
        }
    }

    fn setTab(self: *App, u: *Ui, t: Tab) void {
        if (self.tab == t) return;
        self.tab = t;
        self.rebuildOrder();
        self.resendMenu(u);
    }

    // ------------------------------------------------------------------
    // Ordering
    // ------------------------------------------------------------------

    pub fn rebuildOrder(self: *App) void {
        self.order.clearRetainingCapacity();
        const items = self.sampler.procs.items;
        const q = std.mem.trim(u8, self.search.text(), " ");
        for (items, 0..) |*p, i| {
            if (q.len > 0 and !matches(p, q)) continue;
            self.order.append(self.allocator, @intCast(i)) catch break;
        }
        const ctx = SortCtx{ .items = items, .sort = self.sorts[@intFromEnum(self.tab)] };
        std.mem.sort(u32, self.order.items, ctx, SortCtx.lessThan);
        if (self.selected) |pid| {
            if (self.sampler.find(pid) == null) self.selected = null;
        }
    }

    const SortCtx = struct {
        items: []const Proc,
        sort: Sort,

        fn lessThan(ctx: SortCtx, ia: u32, ib: u32) bool {
            const a = &ctx.items[ia];
            const b = &ctx.items[ib];
            const ord = compare(a, b, ctx.sort.key);
            if (ord == .eq) return a.pid < b.pid;
            return if (ctx.sort.desc) ord == .gt else ord == .lt;
        }
    };

    // ------------------------------------------------------------------
    // Preview data
    // ------------------------------------------------------------------

    /// Seed realistic sample data so host previews look like a busy Zen
    /// system (the real host process table is used otherwise).
    pub fn preview(self: *App, u: *Ui) void {
        _ = u;
        self.frozen = true;
        seedSample(&self.sampler);
        self.rebuildOrder();
        self.selected = 412;
    }

    // ------------------------------------------------------------------
    // Frame
    // ------------------------------------------------------------------

    pub fn frame(self: *App, u: *Ui) void {
        if (!self.frozen and std.time.milliTimestamp() - self.last_refresh >= refresh_ms) self.refreshNow();

        const t = u.theme;
        const w = u.width();
        const h = u.height();
        u.clear(t.content_bg);

        // While a sheet is up the window underneath ignores the mouse and keys.
        const saved = InputState.save(u);
        defer saved.restore(u);
        const sheet_before = self.sheet;
        if (sheet_before != .none) {
            self.sheetKeys(u);
            InputState.block(u);
        }

        var sb = StrBuf{};
        const table = Rect.init(0, toolbar_h, w, h - toolbar_h - panel_h);
        if (self.sheet == .none and u.focus != ui.ui.hashId(search_id)) self.tableKeys(u, table);
        self.drawTable(u, table, &sb);
        self.drawPanel(u, Rect.init(0, h - panel_h, w, panel_h), &sb);
        self.drawToolbar(u, Rect.init(0, 0, w, toolbar_h));

        if (self.sheet != .none) {
            // A sheet opened during this frame (e.g. by a double-click)
            // only takes input from the next frame on.
            if (sheet_before != .none) saved.restore(u) else InputState.block(u);
            self.drawSheet(u, &sb);
        }
        // Keep "Inspect Process" / "Quit Process" enabled only with a selection.
        if ((self.selected != null) != self.menu_sel) self.resendMenu(u);
    }

    // ------------------------------------------------------------------
    // Toolbar
    // ------------------------------------------------------------------

    const ToolbarLayout = struct {
        show_title: bool,
        title_x: i32,
        group: Rect,
        stop: Rect,
        info: Rect,
        seg: Rect,
        search: Rect,
    };

    fn toolbarLayout(u: *Ui, w: i32) ToolbarLayout {
        const cy = @divTrunc(toolbar_h, 2);
        // The traffic lights occupy x < 70.
        const title_x: i32 = 86;
        const title_w: i32 = @intFromFloat(@max(u.measure("Activity Monitor", .bold, 13), u.measure("All Processes", .regular, 11)));
        const search_w: i32 = std.math.clamp(@divTrunc(w, 4), 150, 220);
        const search_x = w - 16 - search_w;
        const group_w: i32 = 80;
        var group_x = title_x + title_w + 20;
        var show_title = true;
        const seg_min: i32 = 4 * 64;
        if (search_x - 16 - (group_x + group_w + 16) < seg_min) {
            // Not enough room: drop the title like a compact toolbar.
            show_title = false;
            group_x = title_x;
        }
        const group = Rect.init(group_x, cy - 16, group_w, 32);
        // Segmented control centered in the space that is left.
        const space_l = group.x + group.w + 16;
        const space_r = search_x - 16;
        const seg_w = std.math.clamp(space_r - space_l, seg_min, 4 * 80);
        return .{
            .show_title = show_title,
            .title_x = title_x,
            .group = group,
            .stop = Rect.init(group.x + 2, group.y + 2, @divTrunc(group.w, 2) - 2, group.h - 4),
            .info = Rect.init(group.x + @divTrunc(group.w, 2), group.y + 2, @divTrunc(group.w, 2) - 2, group.h - 4),
            .seg = Rect.init(space_l + @divTrunc(space_r - space_l - seg_w, 2), cy - 16, seg_w, 32),
            .search = Rect.init(search_x, cy - 16, search_w, 32),
        };
    }

    fn drawToolbar(self: *App, u: *Ui, r: Rect) void {
        const t = u.theme;
        const cy = r.y + @divTrunc(r.h, 2);
        const l = toolbarLayout(u, r.w);
        if (l.show_title) {
            _ = u.textAt(@floatFromInt(l.title_x), @floatFromInt(cy - 1), "Activity Monitor", .bold, 13, t.label);
            _ = u.textAt(@floatFromInt(l.title_x), @floatFromInt(cy + 14), "All Processes", .regular, 11, t.secondary_label);
        }

        // [ⓧ ⓘ] glass group.
        glassCapsule(u, l.group);
        const has_sel = self.selected != null;
        if (toolbarButton(u, "am-stop", l.stop, .stop, has_sel)) {
            if (self.selected) |pid| self.openSheet(.quit, pid);
        }
        if (toolbarButton(u, "am-info", l.info, .info, has_sel)) {
            if (self.selected) |pid| self.openSheet(.info, pid);
        }

        var idx: usize = @intFromEnum(self.tab);
        if (glassSegmented(u, "am-tabs", l.seg, &tab_titles, &idx)) self.setTab(u, @enumFromInt(idx));

        self.drawSearch(u, l.search);
        // The toolbar is the window's title area (set_title_height): the
        // window server moves the window when a press there is dragged.
    }

    fn drawSearch(self: *App, u: *Ui, r: Rect) void {
        const t = u.theme;
        const id = ui.ui.hashId(search_id);
        glassCapsule(u, r);
        if (u.focus == id and u.focused) {
            shapes.strokeRoundRect(u.canvas, r.toF().inset(-1.5, -1.5), @as(f32, @floatFromInt(r.h)) / 2 + 1.5, 3, pm(ui.ui.withAlpha(t.accent, 140)));
        }
        const cx: f32 = @floatFromInt(r.x + 17);
        const cyf: f32 = @floatFromInt(r.y + @divTrunc(r.h, 2));
        const icon_col = t.secondary_label;
        shapes.strokeCircle(u.canvas, cx - 1, cyf - 1.5, 5, 1.6, pm(icon_col));
        u.line(cx + 2.8, cyf + 2.3, cx + 6, cyf + 5.5, 1.8, icon_col);

        const has_text = self.search.text().len > 0;
        const field = Rect.init(r.x + 22, r.y, r.w - 22 - (if (has_text) @as(i32, 26) else 8), r.h);
        const res = u.textField(search_id, field, &self.search, .{ .placeholder = "Search", .plain = true });
        if (u.focus == id and u.keyPressed(Key.esc)) {
            self.search.set(self.allocator, "");
            u.focus = 0;
            self.rebuildOrder();
        }
        if (res.changed) {
            self.rebuildOrder();
            self.scroll.offset = 0;
        }
        if (has_text) {
            const cr = Rect.init(r.x + r.w - 26, r.y + @divTrunc(r.h - 18, 2), 18, 18);
            const cid = ui.ui.hashId("am-search-clear");
            if (u.interact(cid, cr)) {
                self.search.set(self.allocator, "");
                self.rebuildOrder();
            }
            const ccx: f32 = @as(f32, @floatFromInt(cr.x)) + 9;
            const ccy: f32 = @as(f32, @floatFromInt(cr.y)) + 9;
            u.fillCircle(ccx, ccy, 7, t.tertiary_label);
            u.line(ccx - 2.6, ccy - 2.6, ccx + 2.6, ccy + 2.6, 1.4, t.content_bg);
            u.line(ccx + 2.6, ccy - 2.6, ccx - 2.6, ccy + 2.6, 1.4, t.content_bg);
        }
    }

    // ------------------------------------------------------------------
    // Table
    // ------------------------------------------------------------------

    /// Column rectangles for a table `total_w` wide. Optional columns are
    /// hidden (zero width) when the window is too narrow for all of them.
    fn columnRects(cols: []const Col, total_w: i32, out: []Rect, y: i32, h: i32) void {
        const min_name: i32 = 150;
        var hidden: [8]bool = [_]bool{false} ** 8;
        var fixed: i32 = 0;
        for (cols) |c| fixed += c.width;
        while (fixed + min_name + 12 > total_w) {
            var drop: ?usize = null;
            for (cols, 0..) |c, i| {
                if (c.optional > 0 and !hidden[i] and (drop == null or c.optional > cols[drop.?].optional)) drop = i;
            }
            const d = drop orelse break;
            hidden[d] = true;
            fixed -= cols[d].width;
        }
        const flex = @max(min_name, total_w - fixed - 12);
        var x: i32 = 12;
        for (cols, 0..) |c, i| {
            const cw = if (hidden[i]) 0 else if (c.width == 0) flex else c.width;
            out[i] = Rect.init(x, y, cw, h);
            x += cw;
        }
    }

    fn drawTable(self: *App, u: *Ui, r: Rect, sb: *StrBuf) void {
        const t = u.theme;
        const cols = columns(self.tab);
        var rects: [8]Rect = undefined;
        columnRects(cols, r.w, &rects, r.y, header_h);
        const sort = &self.sorts[@intFromEnum(self.tab)];

        // Header.
        const hr = Rect.init(r.x, r.y, r.w, header_h);
        var first_col = true;
        for (cols, 0..) |c, i| {
            const cr = rects[i];
            if (cr.w == 0) continue;
            const id = ui.ui.hashIdx("am-col", i + @as(usize, @intFromEnum(self.tab)) * 16);
            if (u.interact(id, cr)) {
                if (sort.key == c.key) sort.desc = !sort.desc else sort.* = .{ .key = c.key, .desc = defaultDesc(c.key) };
                self.rebuildOrder();
            }
            const active = sort.key == c.key;
            if (u.isActive(id) and u.hovering(cr)) u.fillRect(cr, t.hover);
            const label_col = if (active) t.label else t.secondary_label;
            // Room for the sort chevron right of the title.
            const chev: i32 = if (active) 14 else 0;
            const tr = Rect.init(cr.x + cell_pad, cr.y, cr.w - 2 * cell_pad - chev, cr.h);
            u.text(tr, c.title, .{ .size = 12, .weight = if (active) .semibold else .medium, .color = label_col, .@"align" = if (c.right) .right else .left });
            if (active) {
                const tw = u.measure(c.title, .semibold, 12);
                const ax: f32 = if (c.right) @floatFromInt(cr.x + cr.w - cell_pad - 4) else @as(f32, @floatFromInt(tr.x)) + @min(tw, @as(f32, @floatFromInt(tr.w))) + 9;
                const ay: f32 = @floatFromInt(cr.y + @divTrunc(cr.h, 2));
                drawChevron(u, ax, ay, sort.desc, t.secondary_label);
            }
            if (!first_col) u.fillRect(Rect.init(cr.x, cr.y + 7, 1, cr.h - 14), t.separator);
            first_col = false;
        }
        u.hline(hr.x, hr.x + hr.w, hr.y + hr.h - 1, t.separator);

        // Rows.
        const body = Rect.init(r.x, r.y + header_h, r.w, r.h - header_h);
        self.scroll.content = @floatFromInt(@as(i32, @intCast(self.order.items.len)) * row_h);
        const old = u.beginScroll(body, &self.scroll);
        const off: i32 = @intFromFloat(self.scroll.offset);
        const first: usize = @intCast(@divTrunc(off, row_h));
        const visible: usize = @intCast(@divTrunc(body.h, row_h) + 2);

        // Alternating stripes cover the whole body, even past the last row.
        var i = first;
        while (i < first + visible) : (i += 1) {
            const y = body.y + @as(i32, @intCast(i)) * row_h - off;
            if (i % 2 == 1) u.fillRect(Rect.init(body.x, y, body.w, row_h), t.alternate_row);
        }

        var clicked_row = false;
        i = first;
        while (i < @min(first + visible, self.order.items.len)) : (i += 1) {
            const p = &self.sampler.procs.items[self.order.items[i]];
            const y = body.y + @as(i32, @intCast(i)) * row_h - off;
            const rr = Rect.init(body.x, y, body.w, row_h);
            const id = ui.ui.hashIdx("am-row", p.pid);
            if (u.hovering(rr) and u.mouse_pressed) {
                self.selected = p.pid;
                clicked_row = true;
                if (u.click_count >= 2) self.openSheet(.info, p.pid);
            }
            _ = u.interact(id, rr);
            const sel = self.selected != null and self.selected.? == p.pid;
            if (sel) u.fillRound(Rect.init(rr.x + 6, rr.y, rr.w - 12, rr.h), 6, if (u.focused) t.accent else t.selection_inactive);
            const fg = if (sel and u.focused) 0xFFFFFFFF else t.label;
            const fg2 = if (sel and u.focused) 0xDDFFFFFF else t.secondary_label;
            var cells: [8]Rect = undefined;
            columnRects(cols, r.w, &cells, y, row_h);
            for (cols, 0..) |c, ci| {
                const cr = cells[ci];
                if (cr.w == 0) continue;
                if (c.key == .name) {
                    self.drawIcon(u, p.name(), cr.x + cell_pad - 2, y + @divTrunc(row_h - icon_px, 2));
                    const nr = Rect.init(cr.x + cell_pad + icon_px + 4, y, cr.w - cell_pad * 2 - icon_px - 4, row_h);
                    u.text(nr, p.name(), .{ .size = 13, .color = fg });
                    continue;
                }
                const s = cellText(sb, p, c.key, self.sampler.totals.uptime_ns);
                const dim = (c.key == .sandboxed and !p.sandboxed) or (c.key == .user and p.uid == 0);
                const tr = Rect.init(cr.x + cell_pad, y, cr.w - 2 * cell_pad, row_h);
                u.text(tr, s, .{ .size = 13, .color = if (dim) fg2 else fg, .@"align" = if (c.right) .right else .left });
            }
            sb.n = 0; // strings are drawn; reuse the buffer
        }
        if (u.mouse_pressed and u.hovering(body) and !clicked_row) self.selected = null;
        u.endScroll(body, &self.scroll, old);
        if (self.order.items.len == 0) {
            const msg = if (self.search.text().len > 0) "No Results" else "No Processes";
            u.text(Rect.init(body.x, body.y + 40, body.w, 30), msg, .{ .size = 15, .weight = .semibold, .color = t.tertiary_label, .@"align" = .center });
        }
    }

    fn tableKeys(self: *App, u: *Ui, table: Rect) void {
        if (u.keys_consumed or self.order.items.len == 0) return;
        const body_h = table.h - header_h;
        for (u.keys[0..u.key_count]) |k| {
            const cmd = k.mods & (Mods.cmd | Mods.ctrl) != 0;
            var cur: ?usize = null;
            if (self.selected) |pid| {
                for (self.order.items, 0..) |oi, n| {
                    if (self.sampler.procs.items[oi].pid == pid) cur = n;
                }
            }
            const last = self.order.items.len - 1;
            const next: ?usize = switch (k.code) {
                Key.down => if (cur) |c| @min(c + 1, last) else 0,
                Key.up => if (cur) |c| c -| 1 else last,
                Key.home => 0,
                Key.end => last,
                Key.pagedown => if (cur) |c| @min(c + @as(usize, @intCast(@divTrunc(body_h, row_h))), last) else 0,
                Key.pageup => if (cur) |c| c -| @as(usize, @intCast(@divTrunc(body_h, row_h))) else 0,
                else => null,
            };
            if (next) |n| {
                self.selected = self.sampler.procs.items[self.order.items[n]].pid;
                const top: f32 = @floatFromInt(@as(i32, @intCast(n)) * row_h);
                self.scroll.view = @floatFromInt(body_h);
                self.scroll.scrollTo(top, top + row_h);
            }
            if (k.code == Key.f and cmd) u.focus = ui.ui.hashId(search_id);
            if ((k.code == Key.i and cmd) or k.code == Key.enter) {
                if (self.selected) |pid| self.openSheet(.info, pid);
            }
        }
    }

    fn drawIcon(self: *App, u: *Ui, name: []const u8, x: i32, y: i32) void {
        const img = self.iconFor(u, name) orelse return;
        u.canvas.drawImage(img.canvas(), x, y, 255);
    }

    fn iconFor(self: *App, u: *Ui, name: []const u8) ?*gfx.Image {
        _ = u;
        if (appIconFor(name)) |ai| {
            const slot = self.app_icons.getPtr(ai);
            if (slot.* == null) {
                var img = gfx.Image.init(self.allocator, icon_px, icon_px) catch return null;
                icons.drawApp(img.canvas(), self.allocator, ai, gfx.RectF.init(0, 0, icon_pxf, icon_pxf));
                slot.* = img;
            }
            return &slot.*.?;
        }
        if (self.gear_icon == null) {
            var img = gfx.Image.init(self.allocator, icon_px, icon_px) catch return null;
            icons.drawSymbol(img.canvas(), self.allocator, .gear, gfx.RectF.init(1, 1, icon_pxf - 2, icon_pxf - 2), 0xFF8E8E93);
            self.gear_icon = img;
        }
        return &self.gear_icon.?;
    }

    // ------------------------------------------------------------------
    // Bottom panel
    // ------------------------------------------------------------------

    const Stat = struct { label: []const u8, value: []const u8, color: ?u32 = null };

    fn drawPanel(self: *App, u: *Ui, r: Rect, sb: *StrBuf) void {
        const t = u.theme;
        sb.n = 0;
        u.fillRect(r, t.window_bg);
        u.hline(r.x, r.x + r.w, r.y, t.separator);
        const tot = &self.sampler.totals;
        const s = &self.sampler;
        const inner = Rect.init(r.x + 20, r.y + 16, r.w - 40, r.h - 30);
        const third = @divTrunc(inner.w - 40, 3);
        const left = Rect.init(inner.x, inner.y, third, inner.h);
        const mid = Rect.init(inner.x + third + 20, inner.y, third, inner.h);
        const right = Rect.init(inner.x + 2 * third + 40, inner.y, third, inner.h);
        u.fillRect(Rect.init(mid.x - 10, inner.y + 4, 1, inner.h - 8), t.separator);
        u.fillRect(Rect.init(right.x - 10, inner.y + 4, 1, inner.h - 8), t.separator);
        const redc = if (t.dark) red_dark else red;
        const bluec = if (t.dark) blue_dark else blue;
        var cb: [32]u8 = undefined;

        switch (self.tab) {
            .cpu => {
                statRows(u, left, &.{
                    .{ .label = "System:", .value = sb.print("{d:.2}%", .{tot.system_pct}), .color = redc },
                    .{ .label = "User:", .value = sb.print("{d:.2}%", .{tot.user_pct}), .color = bluec },
                    .{ .label = "Idle:", .value = sb.print("{d:.2}%", .{tot.idle_pct}) },
                });
                const g = caption(u, mid, "CPU LOAD");
                graphBox(u, g);
                // Stacked: user on top of system.
                var total_hist = procs.History{};
                for (0..s.cpu_user_hist.len) |i| total_hist.push(s.cpu_user_hist.get(i) + s.cpu_system_hist.get(i));
                drawArea(u, g, &total_hist, 100, bluec);
                drawArea(u, g, &s.cpu_system_hist, 100, redc);
                statRows(u, right, &.{
                    .{ .label = "Threads:", .value = sb.keep(procs.formatCount(&cb, tot.threads)) },
                    .{ .label = "Processes:", .value = sb.keep(procs.formatCount(&cb, tot.processes)) },
                });
            },
            .memory => {
                const g = caption(u, left, "MEMORY PRESSURE");
                graphBox(u, g);
                const pr = s.mem_hist.last();
                const col: u32 = if (pr > 0.85) redc else if (pr > 0.65) yellow else green;
                drawArea(u, g, &s.mem_hist, 1, col);
                const m = tot.mem;
                if (m.valid) {
                    statRows(u, mid, &.{
                        .{ .label = "Physical Memory:", .value = sb.keep(procs.formatBytes(&cb, m.total)) },
                        .{ .label = "Memory Used:", .value = sb.keep(procs.formatBytes(&cb, m.used())) },
                        .{ .label = "Cached Files:", .value = sb.keep(procs.formatBytes(&cb, m.cached + m.buffers)) },
                        .{ .label = "Swap Used:", .value = sb.keep(procs.formatBytes(&cb, m.swap_total -| m.swap_free)) },
                    });
                    statRows(u, right, &.{
                        .{ .label = "Available:", .value = sb.keep(procs.formatBytes(&cb, m.available)) },
                        .{ .label = "Free:", .value = sb.keep(procs.formatBytes(&cb, m.free)) },
                        .{ .label = "App Memory:", .value = sb.keep(procs.formatBytes(&cb, tot.rss_total)) },
                    });
                } else {
                    statRows(u, mid, &.{
                        .{ .label = "Physical Memory:", .value = "\u{2014}" },
                        .{ .label = "App Memory:", .value = sb.keep(procs.formatBytes(&cb, tot.rss_total)) },
                    });
                }
            },
            .disk => {
                statRows(u, left, &.{
                    .{ .label = "Data read:", .value = sb.keep(procs.formatBytes(&cb, tot.disk_read)), .color = bluec },
                    .{ .label = "Data written:", .value = sb.keep(procs.formatBytes(&cb, tot.disk_write)), .color = redc },
                });
                const g = caption(u, mid, "DATA");
                graphBox(u, g);
                var peak: f32 = 64 * 1024;
                for (0..s.disk_read_hist.len) |i| peak = @max(peak, @max(s.disk_read_hist.get(i), s.disk_write_hist.get(i)));
                drawArea(u, g, &s.disk_read_hist, peak * 1.15, bluec);
                drawArea(u, g, &s.disk_write_hist, peak * 1.15, redc);
                statRows(u, right, &.{
                    .{ .label = "Data read/sec:", .value = sb.print("{s}", .{procs.formatBytes(&cb, @intFromFloat(tot.disk_read_rate))}), .color = bluec },
                    .{ .label = "Data written/sec:", .value = sb.print("{s}", .{procs.formatBytes(&cb, @intFromFloat(tot.disk_write_rate))}), .color = redc },
                });
            },
            .system => {
                const uts = if (self.uts) |*x| x else null;
                const sysname = if (uts) |x| std.mem.sliceTo(&x.sysname, 0) else "?";
                const release = if (uts) |x| std.mem.sliceTo(&x.release, 0) else "";
                const host = if (uts) |x| std.mem.sliceTo(&x.nodename, 0) else "";
                const os = if (s.on_zen) sb.print("{s} {s} \u{201C}{s}\u{201D}", .{ abi.os_name, abi.os_version, abi.os_codename }) else sb.keep(sysname);
                var sandboxed: u64 = 0;
                for (s.procs.items) |p| {
                    if (p.sandboxed) sandboxed += 1;
                }
                statRows(u, left, &.{
                    .{ .label = "System:", .value = os },
                    .{ .label = "Kernel:", .value = sb.print("{s} {s}", .{ sysname, release }) },
                    .{ .label = "Host Name:", .value = sb.keep(host) },
                });
                statRows(u, mid, &.{
                    .{ .label = "Uptime:", .value = sb.keep(procs.formatDuration(&cb, tot.uptime_ns)) },
                    .{ .label = "Processors:", .value = sb.print("{d}", .{tot.ncpu}) },
                    .{ .label = "Memory:", .value = if (tot.mem.valid) sb.keep(procs.formatBytes(&cb, tot.mem.total)) else "\u{2014}" },
                });
                statRows(u, right, &.{
                    .{ .label = "Processes:", .value = sb.keep(procs.formatCount(&cb, tot.processes)) },
                    .{ .label = "Threads:", .value = sb.keep(procs.formatCount(&cb, tot.threads)) },
                    .{ .label = "Sandboxed:", .value = sb.keep(procs.formatCount(&cb, sandboxed)) },
                });
            },
        }
    }

    // ------------------------------------------------------------------
    // Sheets
    // ------------------------------------------------------------------

    pub fn openSheet(self: *App, kind: Sheet, pid: u32) void {
        const p = self.sampler.find(pid) orelse return;
        self.sheet = kind;
        self.sheet_pid = pid;
        self.sheet_error = "";
        if (self.sheet_icon) |*img| img.deinit(self.allocator);
        self.sheet_icon = null;
        var img = gfx.Image.init(self.allocator, 64, 64) catch return;
        if (appIconFor(p.name())) |ai| {
            icons.drawApp(img.canvas(), self.allocator, ai, gfx.RectF.init(2, 2, 60, 60));
        } else {
            icons.drawApp(img.canvas(), self.allocator, .generic, gfx.RectF.init(2, 2, 60, 60));
        }
        self.sheet_icon = img;
    }

    fn closeSheet(self: *App) void {
        self.sheet = .none;
        if (self.sheet_icon) |*img| img.deinit(self.allocator);
        self.sheet_icon = null;
    }

    fn sheetKeys(self: *App, u: *Ui) void {
        for (u.keys[0..u.key_count]) |k| {
            switch (k.code) {
                Key.esc => self.closeSheet(),
                Key.enter, Key.kpenter => switch (self.sheet) {
                    .quit => self.sendSignal(std.posix.SIG.TERM),
                    .info => self.closeSheet(),
                    .none => {},
                },
                else => {},
            }
            if (self.sheet == .none) break;
        }
    }

    fn sendSignal(self: *App, sig: u8) void {
        std.posix.kill(@intCast(self.sheet_pid), sig) catch |err| {
            self.sheet_error = switch (err) {
                error.PermissionDenied => "You don\u{2019}t have permission to quit this process.",
                error.ProcessNotFound => "The process no longer exists.",
                else => "The process could not be quit.",
            };
            return;
        };
        self.closeSheet();
        // Refresh shortly so the process disappears from the list.
        self.last_refresh = std.time.milliTimestamp() - refresh_ms + 300;
    }

    fn drawSheet(self: *App, u: *Ui, sb: *StrBuf) void {
        const t = u.theme;
        const w = u.width();
        const h = u.height();
        u.fillRect(u.bounds(), if (t.dark) 0x59000000 else 0x33000000);
        const p_opt = self.sampler.find(self.sheet_pid);
        var name_buf: [64]u8 = undefined;
        const name = if (p_opt) |p| blk: {
            const n = p.name();
            @memcpy(name_buf[0..n.len], n);
            break :blk name_buf[0..n.len];
        } else "process";

        switch (self.sheet) {
            .none => {},
            .quit => {
                const pw: i32 = 340;
                const ph: i32 = 280 + @as(i32, if (self.sheet_error.len > 0) 20 else 0);
                const pr = Rect.init(@divTrunc(w - pw, 2), @max(toolbar_h + 8, @divTrunc(h - ph, 2) - 20), pw, ph);
                sheetPanel(u, pr);
                if (self.sheet_icon) |img| u.canvas.drawImage(img.canvas(), pr.x + @divTrunc(pw - 64, 2), pr.y + 20, 255);
                var y = pr.y + 92;
                u.text(Rect.init(pr.x + 16, y, pw - 32, 20), "Are you sure you want to quit this process?", .{ .size = 13, .weight = .bold, .@"align" = .center });
                y += 22;
                u.text(Rect.init(pr.x + 20, y, pw - 40, 18), sb.print("Do you really want to quit \u{201C}{s}\u{201D}?", .{name}), .{ .size = 11, .color = t.secondary_label, .@"align" = .center });
                y += 20;
                if (self.sheet_error.len > 0) {
                    u.text(Rect.init(pr.x + 16, y, pw - 32, 18), self.sheet_error, .{ .size = 11, .weight = .medium, .color = if (t.dark) red_dark else red, .@"align" = .center });
                    y += 20;
                }
                y += 12;
                const bw = pw - 40;
                if (u.button("am-quit", Rect.init(pr.x + 20, y, bw, 30), "Quit", .{ .style = .primary })) self.sendSignal(std.posix.SIG.TERM);
                y += 38;
                if (u.button("am-force", Rect.init(pr.x + 20, y, bw, 30), "Force Quit", .{})) self.sendSignal(std.posix.SIG.KILL);
                y += 38;
                if (u.button("am-cancel", Rect.init(pr.x + 20, y, bw, 30), "Cancel", .{})) self.closeSheet();
            },
            .info => {
                const p = p_opt orelse {
                    self.closeSheet();
                    return;
                };
                const pw: i32 = 420;
                const ph: i32 = 372;
                const pr = Rect.init(@divTrunc(w - pw, 2), @max(toolbar_h + 8, @divTrunc(h - ph, 2) - 10), pw, ph);
                sheetPanel(u, pr);
                if (self.sheet_icon) |img| u.canvas.drawImage(img.canvas(), pr.x + 20, pr.y + 18, 255);
                u.text(Rect.init(pr.x + 96, pr.y + 26, pw - 116, 22), p.name(), .{ .size = 17, .weight = .bold });
                u.text(Rect.init(pr.x + 96, pr.y + 50, pw - 116, 18), sb.print("Process ID {d} \u{00B7} Parent {d}", .{ p.pid, p.ppid }), .{ .size = 12, .color = t.secondary_label });
                var cb: [32]u8 = undefined;
                const up = self.sampler.totals.uptime_ns;
                const rows_ = [_]Stat{
                    .{ .label = "User", .value = sb.print("{s} ({d})", .{ p.user(), p.uid }) },
                    .{ .label = "State", .value = p.stateName() },
                    .{ .label = "% CPU", .value = sb.print("{d:.1}", .{p.cpu_pct}) },
                    .{ .label = "CPU Time", .value = sb.keep(procs.formatCpuTime(&cb, p.cpu_ns)) },
                    .{ .label = "Threads", .value = sb.print("{d}", .{p.threads}) },
                    .{ .label = "Memory", .value = sb.keep(procs.formatBytes(&cb, p.rss)) },
                    .{ .label = "Virtual Memory", .value = sb.keep(procs.formatBytes(&cb, p.vsize)) },
                    .{ .label = "Running Time", .value = if (up > p.start_ns) sb.keep(procs.formatDuration(&cb, up - p.start_ns)) else "\u{2014}" },
                    .{ .label = "Sandboxed", .value = if (p.sandboxed) "Yes" else "No" },
                };
                const box = Rect.init(pr.x + 20, pr.y + 92, pw - 40, @as(i32, rows_.len) * 24 + 8);
                u.fillRound(box, 10, if (t.dark) 0x14FFFFFF else 0x0A000000);
                for (rows_, 0..) |st, i| {
                    const y = box.y + 4 + @as(i32, @intCast(i)) * 24;
                    if (i > 0) u.hline(box.x + 12, box.x + box.w - 12, y, t.separator);
                    u.text(Rect.init(box.x + 12, y, 140, 24), st.label, .{ .size = 12, .color = t.secondary_label });
                    u.text(Rect.init(box.x + 150, y, box.w - 162, 24), st.value, .{ .size = 12, .weight = .medium, .@"align" = .right });
                }
                const by = pr.y + ph - 46;
                if (u.button("am-info-quit", Rect.init(pr.x + 20, by, 120, 30), "Quit\u{2026}", .{})) {
                    self.sheet = .quit;
                    self.sheet_error = "";
                }
                if (u.button("am-info-done", Rect.init(pr.x + pw - 120, by, 100, 30), "Done", .{ .style = .primary })) self.closeSheet();
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn matches(p: *const Proc, q: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(p.name(), q) != null) return true;
    if (std.ascii.indexOfIgnoreCase(p.user(), q) != null) return true;
    var b: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&b, "{d}", .{p.pid}) catch return false;
    return std.mem.startsWith(u8, pid, q);
}

fn cmpNum(a: anytype, b: @TypeOf(a)) std.math.Order {
    return std.math.order(a, b);
}

fn compare(a: *const Proc, b: *const Proc, key: SortKey) std.math.Order {
    return switch (key) {
        .name => std.ascii.orderIgnoreCase(a.name(), b.name()),
        .user => std.ascii.orderIgnoreCase(a.user(), b.user()),
        .cpu => cmpNum(a.cpu_pct, b.cpu_pct),
        .cpu_time => cmpNum(a.cpu_ns, b.cpu_ns),
        .threads => cmpNum(a.threads, b.threads),
        .pid => cmpNum(a.pid, b.pid),
        .memory => cmpNum(a.rss, b.rss),
        .sandboxed => cmpNum(@intFromBool(a.sandboxed), @intFromBool(b.sandboxed)),
        .written => cmpNum(a.disk_write orelse 0, b.disk_write orelse 0),
        .read => cmpNum(a.disk_read orelse 0, b.disk_read orelse 0),
        .state => cmpNum(a.state, b.state),
        .ppid => cmpNum(a.ppid, b.ppid),
        .nice => cmpNum(a.nice, b.nice),
        // Longer running = started earlier.
        .running => cmpNum(b.start_ns, a.start_ns),
        .vsize => cmpNum(a.vsize, b.vsize),
    };
}

fn cellText(sb: *StrBuf, p: *const Proc, key: SortKey, uptime_ns: u64) []const u8 {
    var b: [32]u8 = undefined;
    return switch (key) {
        .name => p.name(),
        .user => p.user(),
        .cpu => sb.print("{d:.1}", .{p.cpu_pct}),
        .cpu_time => sb.keep(procs.formatCpuTime(&b, p.cpu_ns)),
        .threads => sb.print("{d}", .{p.threads}),
        .pid => sb.print("{d}", .{p.pid}),
        .memory => sb.keep(procs.formatBytes(&b, p.rss)),
        .sandboxed => if (p.sandboxed) "Yes" else "No",
        .written => if (p.disk_write) |v| sb.keep(procs.formatBytes(&b, v)) else "\u{2014}",
        .read => if (p.disk_read) |v| sb.keep(procs.formatBytes(&b, v)) else "\u{2014}",
        .state => p.stateName(),
        .ppid => sb.print("{d}", .{p.ppid}),
        .nice => sb.print("{d}", .{p.nice}),
        .running => if (uptime_ns > p.start_ns) sb.keep(procs.formatDuration(&b, uptime_ns - p.start_ns)) else "\u{2014}",
        .vsize => sb.keep(procs.formatBytes(&b, p.vsize)),
    };
}

/// Full-color icon for well-known app process names.
fn appIconFor(name: []const u8) ?icons.AppIcon {
    if (std.ascii.indexOfIgnoreCase(name, "activity") != null) return .activity;
    if (std.ascii.eqlIgnoreCase(name, "loginwindow")) return .zen;
    const ai = icons.AppIcon.fromName(name);
    return switch (ai) {
        .generic, .trash, .trash_full, .launchpad => null,
        else => ai,
    };
}

/// Liquid-glass capsule used for toolbar controls.
fn glassCapsule(u: *Ui, r: Rect) void {
    const t = u.theme;
    const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
    u.shadow(r, radius, 8, 2, if (t.dark) 0x66000000 else 0x24000000);
    const rf = r.toF();
    const fill = gfx.Paint.verticalGradient(rf, if (t.dark) &.{
        .{ .pos = 0, .color = pm(0xFF3A3A3D) },
        .{ .pos = 1, .color = pm(0xFF2E2E31) },
    } else &.{
        .{ .pos = 0, .color = pm(0xFFFFFFFF) },
        .{ .pos = 1, .color = pm(0xFFF7F7F9) },
    });
    shapes.fillRoundRect(u.canvas, rf, radius, &fill);
    const rim = gfx.Paint.verticalGradient(rf, if (t.dark) &.{
        .{ .pos = 0, .color = pm(0x4DFFFFFF) },
        .{ .pos = 0.5, .color = pm(0x12FFFFFF) },
        .{ .pos = 1, .color = pm(0x26FFFFFF) },
    } else &.{
        .{ .pos = 0, .color = pm(0x0F000000) },
        .{ .pos = 1, .color = pm(0x1F000000) },
    });
    shapes.strokeRoundRect(u.canvas, rf.inset(0.5, 0.5), radius - 0.5, 1, &rim);
}

const ToolIcon = enum { stop, info };

fn toolbarButton(u: *Ui, id_str: []const u8, r: Rect, icon: ToolIcon, enabled: bool) bool {
    const t = u.theme;
    const id = ui.ui.hashId(id_str);
    const clicked = u.interact(id, r) and enabled;
    const radius: f32 = @as(f32, @floatFromInt(r.h)) / 2;
    if (enabled and u.isActive(id) and u.hovering(r)) {
        u.fillRound(r, radius, t.selection_inactive);
    } else if (enabled and u.hovering(r)) {
        u.fillRound(r, radius, t.hover);
    }
    const col = if (enabled) t.label else t.tertiary_label;
    const cx: f32 = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2;
    const cy: f32 = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2;
    shapes.strokeCircle(u.canvas, cx, cy, 8, 1.5, pm(col));
    switch (icon) {
        .stop => {
            u.line(cx - 3, cy - 3, cx + 3, cy + 3, 1.6, col);
            u.line(cx + 3, cy - 3, cx - 3, cy + 3, 1.6, col);
        },
        .info => {
            u.fillCircle(cx, cy - 3.6, 1.25, col);
            u.line(cx, cy - 0.8, cx, cy + 4, 1.8, col);
        },
    }
    return clicked;
}

/// Segmented control in a glass capsule (toolbar style).
fn glassSegmented(u: *Ui, id_str: []const u8, r: Rect, items: []const []const u8, selected: *usize) bool {
    const t = u.theme;
    glassCapsule(u, r);
    const n: i32 = @intCast(items.len);
    const seg_w = @divTrunc(r.w - 4, n);
    var changed = false;
    for (items, 0..) |label, i| {
        const sr = Rect.init(r.x + 2 + @as(i32, @intCast(i)) * seg_w, r.y + 2, seg_w, r.h - 4);
        const id = ui.ui.hashIdx(id_str, i);
        if (u.interact(id, sr) and selected.* != i) {
            selected.* = i;
            changed = true;
        }
        const radius: f32 = @as(f32, @floatFromInt(sr.h)) / 2;
        const sel = selected.* == i;
        if (sel) {
            u.fillRound(sr, radius, if (t.dark) 0xFF5A5A5F else 0xFFE4E4E9);
        } else if (u.isActive(id) and u.hovering(sr)) {
            u.fillRound(sr, radius, t.selection_inactive);
        } else if (u.hovering(sr)) {
            u.fillRound(sr, radius, t.hover);
        }
        u.text(sr, label, .{ .size = 13, .weight = if (sel) .semibold else .medium, .color = t.label, .@"align" = .center });
    }
    return changed;
}

fn drawChevron(u: *Ui, cx: f32, cy: f32, down: bool, color: u32) void {
    const dy: f32 = if (down) 1.8 else -1.8;
    u.line(cx - 3.5, cy - dy, cx, cy + dy, 1.4, color);
    u.line(cx, cy + dy, cx + 3.5, cy - dy, 1.4, color);
}

/// Caption above a graph; returns the area left for the graph.
fn caption(u: *Ui, r: Rect, title: []const u8) Rect {
    u.text(Rect.init(r.x, r.y - 2, r.w, 14), title, .{ .size = 10, .weight = .semibold, .color = u.theme.secondary_label, .@"align" = .center });
    return Rect.init(r.x, r.y + 16, r.w, r.h - 16);
}

fn graphBox(u: *Ui, r: Rect) void {
    const t = u.theme;
    u.fillRound(r, 6, if (t.dark) 0xFF161618 else 0xFFFFFFFF);
    // Faint grid.
    const old = u.pushClip(r);
    var gy: i32 = 1;
    while (gy < 4) : (gy += 1) u.hline(r.x, r.x + r.w, r.y + @divTrunc(r.h * gy, 4), if (t.dark) 0x10FFFFFF else 0x0D000000);
    u.popClip(old);
}

/// Filled area chart of the history, scaled so `max` fills the box.
fn drawArea(u: *Ui, r: Rect, hist: *const procs.History, max: f32, color: u32) void {
    const t = u.theme;
    const inner = Rect.init(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
    const old = u.pushClip(inner);
    defer u.popClip(old);
    const n = hist.len;
    if (n >= 1) {
        const fill = gfx.Paint.verticalGradient(inner.toF(), &.{
            .{ .pos = 0, .color = pm(ui.ui.withAlpha(color, 170)) },
            .{ .pos = 1, .color = pm(ui.ui.withAlpha(color, 70)) },
        });
        const w: f32 = @floatFromInt(inner.w);
        const hgt: f32 = @floatFromInt(inner.h);
        const bottom: f32 = @floatFromInt(inner.y + inner.h);
        // The newest sample is at the right edge; one sample per w/59 px.
        const step = w / @as(f32, @floatFromInt(procs.history_len - 1));
        const x_start = @as(f32, @floatFromInt(inner.x + inner.w)) - step * @as(f32, @floatFromInt(n - 1));
        var x: i32 = @max(inner.x, @as(i32, @intFromFloat(@floor(x_start))));
        while (x < inner.x + inner.w) : (x += 1) {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5 - x_start) / step;
            const idx = std.math.clamp(fx, 0, @as(f32, @floatFromInt(n - 1)));
            const lo: usize = @intFromFloat(@floor(idx));
            const hi = @min(lo + 1, n - 1);
            const frac = idx - @floor(idx);
            const v = hist.get(lo) * (1 - frac) + hist.get(hi) * frac;
            const vh = std.math.clamp(v / max, 0, 1) * hgt;
            const top = bottom - vh;
            const top_i: i32 = @intFromFloat(@ceil(top));
            if (top_i < inner.y + inner.h) u.canvas.fillRect(Rect.init(x, top_i, 1, inner.y + inner.h - top_i), &fill);
            // Anti-aliased top pixel.
            const cov = @as(f32, @floatFromInt(top_i)) - top;
            if (cov > 0.02 and top_i - 1 >= inner.y) u.fillRect(Rect.init(x, top_i - 1, 1, 1), ui.ui.withAlpha(color, @intFromFloat(cov * 170)));
        }
        // Outline.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const x0 = x_start + step * @as(f32, @floatFromInt(i - 1));
            const x1 = x_start + step * @as(f32, @floatFromInt(i));
            const y0 = bottom - std.math.clamp(hist.get(i - 1) / max, 0, 1) * hgt;
            const y1 = bottom - std.math.clamp(hist.get(i) / max, 0, 1) * hgt;
            u.line(x0, y0, x1, y1, 1.3, color);
        }
    }
    _ = t;
}

fn statRows(u: *Ui, r: Rect, rows_: []const App.Stat) void {
    const t = u.theme;
    const line: i32 = 22;
    const total = @as(i32, @intCast(rows_.len)) * line;
    var y = r.y + @divTrunc(r.h - total, 2);
    for (rows_) |s| {
        u.text(Rect.init(r.x, y, r.w, line), s.label, .{ .size = 12, .color = t.secondary_label });
        const lw: i32 = @intFromFloat(u.measure(s.label, .regular, 12));
        u.text(Rect.init(r.x + lw + 8, y, r.w - lw - 8, line), s.value, .{ .size = 12, .weight = .semibold, .color = s.color orelse t.label, .@"align" = .right });
        y += line;
    }
}

fn sheetPanel(u: *Ui, r: Rect) void {
    const t = u.theme;
    u.shadow(r, 20, 24, 10, if (t.dark) 0x99000000 else 0x4D000000);
    u.fillRound(r, 20, if (t.dark) 0xFF2A2A2D else 0xFFF7F7F9);
    shapes.strokeRoundRect(u.canvas, r.toF().inset(0.5, 0.5), 19.5, 1, pm(if (t.dark) 0x33FFFFFF else 0x1A000000));
}

// ---------------------------------------------------------------------------
// Sample data for previews
// ---------------------------------------------------------------------------

fn seedSample(s: *procs.Sampler) void {
    const Seed = struct { pid: u32, ppid: u32, uid: u32, name: []const u8, cpu: f32, secs: f64, threads: u32, mb: f64, sandboxed: bool, state: u8 = 'S', wr: u64 = 0, rd: u64 = 0, age_min: u64 = 30 };
    const seeds = [_]Seed{
        .{ .pid = 0, .ppid = 0, .uid = 0, .name = "kernel_task", .cpu = 6.4, .secs = 812.4, .threads = 4, .mb = 38.2, .sandboxed = false, .state = 'R', .age_min = 95 },
        .{ .pid = 1, .ppid = 0, .uid = 0, .name = "init", .cpu = 0.0, .secs = 0.8, .threads = 1, .mb = 1.1, .sandboxed = false, .age_min = 95 },
        .{ .pid = 12, .ppid = 1, .uid = 0, .name = "virtio-gpud", .cpu = 1.8, .secs = 96.1, .threads = 1, .mb = 4.2, .sandboxed = false, .rd = 0, .wr = 0, .age_min = 95 },
        .{ .pid = 13, .ppid = 1, .uid = 0, .name = "virtio-blkd", .cpu = 0.3, .secs = 12.7, .threads = 1, .mb = 2.9, .sandboxed = false, .rd = 412 << 20, .wr = 97 << 20, .age_min = 95 },
        .{ .pid = 14, .ppid = 1, .uid = 0, .name = "virtio-inputd", .cpu = 0.1, .secs = 3.2, .threads = 1, .mb = 1.6, .sandboxed = false, .age_min = 95 },
        .{ .pid = 21, .ppid = 1, .uid = 0, .name = "fsd", .cpu = 0.9, .secs = 41.6, .threads = 2, .mb = 12.4, .sandboxed = false, .rd = 388 << 20, .wr = 91 << 20, .age_min = 95 },
        .{ .pid = 22, .ppid = 1, .uid = 0, .name = "ptyd", .cpu = 0.2, .secs = 4.9, .threads = 1, .mb = 1.9, .sandboxed = false, .age_min = 95 },
        .{ .pid = 30, .ppid = 1, .uid = 0, .name = "launchd", .cpu = 0.1, .secs = 6.3, .threads = 2, .mb = 3.4, .sandboxed = false, .rd = 5 << 20, .wr = 256 << 10, .age_min = 95 },
        .{ .pid = 31, .ppid = 30, .uid = 0, .name = "windowserver", .cpu = 14.2, .secs = 1450.2, .threads = 3, .mb = 96.7, .sandboxed = false, .state = 'R', .rd = 22 << 20, .wr = 0, .age_min = 94 },
        .{ .pid = 40, .ppid = 30, .uid = 0, .name = "loginwindow", .cpu = 0.0, .secs = 2.4, .threads = 1, .mb = 18.3, .sandboxed = false, .rd = 3 << 20, .wr = 12 << 10, .age_min = 94 },
        .{ .pid = 402, .ppid = 30, .uid = 501, .name = "Finder", .cpu = 1.2, .secs = 58.3, .threads = 4, .mb = 41.8, .sandboxed = true, .rd = 64 << 20, .wr = 2 << 20, .age_min = 88 },
        .{ .pid = 412, .ppid = 30, .uid = 501, .name = "Terminal", .cpu = 3.7, .secs = 132.9, .threads = 3, .mb = 28.6, .sandboxed = true, .rd = 9 << 20, .wr = 1 << 20, .age_min = 80 },
        .{ .pid = 413, .ppid = 412, .uid = 501, .name = "zensh", .cpu = 0.0, .secs = 1.3, .threads = 1, .mb = 2.1, .sandboxed = false, .age_min = 80 },
        .{ .pid = 437, .ppid = 413, .uid = 501, .name = "cc", .cpu = 38.9, .secs = 84.6, .threads = 1, .mb = 212.4, .sandboxed = false, .state = 'R', .rd = 148 << 20, .wr = 63 << 20, .age_min = 3 },
        .{ .pid = 421, .ppid = 30, .uid = 501, .name = "TextEdit", .cpu = 0.4, .secs = 9.8, .threads = 2, .mb = 22.9, .sandboxed = true, .rd = 2 << 20, .wr = 340 << 10, .age_min = 42 },
        .{ .pid = 433, .ppid = 30, .uid = 501, .name = "Calculator", .cpu = 0.0, .secs = 0.9, .threads = 1, .mb = 9.7, .sandboxed = true, .age_min = 12 },
        .{ .pid = 440, .ppid = 30, .uid = 501, .name = "Settings", .cpu = 0.2, .secs = 3.1, .threads = 2, .mb = 19.2, .sandboxed = true, .rd = 1 << 20, .age_min = 9 },
        .{ .pid = 451, .ppid = 30, .uid = 501, .name = "Activity Monitor", .cpu = 2.6, .secs = 7.4, .threads = 1, .mb = 15.3, .sandboxed = false, .state = 'R', .age_min = 2 },
    };
    s.procs.clearRetainingCapacity();
    const up: u64 = 95 * 60 * std.time.ns_per_s;
    for (seeds) |sd| {
        var p = Proc{ .pid = sd.pid, .ppid = sd.ppid, .uid = sd.uid };
        p.setName(sd.name);
        p.setUser(if (sd.uid == 0) "root" else "zen");
        p.state = sd.state;
        p.cpu_pct = sd.cpu;
        p.cpu_ns = @intFromFloat(sd.secs * 1e9);
        p.threads = sd.threads;
        p.rss = @intFromFloat(sd.mb * 1048576);
        p.vsize = p.rss * 3 + (64 << 20);
        p.sandboxed = sd.sandboxed;
        p.disk_read = sd.rd;
        p.disk_write = sd.wr;
        p.start_ns = up - sd.age_min * 60 * std.time.ns_per_s;
        s.procs.append(s.allocator, p) catch return;
    }
    var tot = &s.totals;
    tot.ncpu = 4;
    tot.processes = seeds.len;
    tot.threads = 0;
    tot.disk_read = 0;
    tot.disk_write = 0;
    tot.rss_total = 0;
    for (s.procs.items) |p| {
        tot.threads += p.threads;
        tot.disk_read += p.disk_read.?;
        tot.disk_write += p.disk_write.?;
        tot.rss_total += p.rss;
    }
    tot.uptime_ns = up;
    tot.system_pct = 6.21;
    tot.user_pct = 11.84;
    tot.idle_pct = 100 - 6.21 - 11.84;
    tot.disk_read_rate = 1.4 * 1048576;
    tot.disk_write_rate = 0.6 * 1048576;
    tot.mem = .{ .total = 4 << 30, .free = 1210 << 20, .available = 2380 << 20, .cached = 980 << 20, .buffers = 64 << 20, .swap_total = 0, .swap_free = 0, .valid = true };
    s.cpu_user_hist = .{};
    s.cpu_system_hist = .{};
    s.mem_hist = .{};
    s.disk_read_hist = .{};
    s.disk_write_hist = .{};
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..procs.history_len) |i| {
        const x: f32 = @floatFromInt(i);
        const d = (x - 44) / 4;
        const burst: f32 = 20 * @exp(-d * d);
        s.cpu_user_hist.push(8 + 4 * @sin(x * 0.35) + rnd.float(f32) * 5 + burst);
        s.cpu_system_hist.push(4 + 2 * @sin(x * 0.2 + 1) + rnd.float(f32) * 2.5 + burst * 0.3);
        s.mem_hist.push(0.36 + 0.06 * @sin(x * 0.08) + (if (i > 38) @as(f32, 0.07) else 0) + rnd.float(f32) * 0.01);
        s.disk_read_hist.push((0.4 + rnd.float(f32) * 1.2 + (if (i > 40 and i < 48) @as(f32, 3) else 0)) * 1048576);
        s.disk_write_hist.push((0.1 + rnd.float(f32) * 0.5 + (if (i > 44 and i < 52) @as(f32, 1.8) else 0)) * 1048576);
    }
}

test "sorting and filtering" {
    var s = procs.Sampler{ .allocator = std.testing.allocator };
    defer s.deinit();
    seedSample(&s);
    const ctx = App.SortCtx{ .items = s.procs.items, .sort = .{ .key = .cpu, .desc = true } };
    var order: [32]u32 = undefined;
    for (0..s.procs.items.len) |i| order[i] = @intCast(i);
    const o = order[0..s.procs.items.len];
    std.mem.sort(u32, o, ctx, App.SortCtx.lessThan);
    try std.testing.expectEqualStrings("cc", s.procs.items[o[0]].name());
    const ctx2 = App.SortCtx{ .items = s.procs.items, .sort = .{ .key = .name, .desc = false } };
    std.mem.sort(u32, o, ctx2, App.SortCtx.lessThan);
    try std.testing.expectEqualStrings("Activity Monitor", s.procs.items[o[0]].name());
    try std.testing.expect(matches(&s.procs.items[o[0]], "monitor"));
    try std.testing.expect(!matches(&s.procs.items[o[0]], "finder"));
    try std.testing.expectEqual(icons.AppIcon.terminal, appIconFor("Terminal").?);
    try std.testing.expect(appIconFor("fsd") == null);
}

// ---------------------------------------------------------------------------
// Interaction tests (headless window, synthetic events)
// ---------------------------------------------------------------------------

const Event = abi.window.Event;

fn testStep(app: *App, u: *Ui, events: []const Event) void {
    u.beginFrame(events);
    app.frame(u);
    u.endFrame();
}

fn click(app: *App, u: *Ui, r: Rect, count: i32) void {
    const x = r.x + @divTrunc(r.w, 2);
    const y = r.y + @divTrunc(r.h, 2);
    testStep(app, u, &.{
        .{ .kind = .mouse_move, .a = x, .b = y },
        .{ .kind = .mouse_down, .a = x, .b = y, .c = 1, .d = count },
        .{ .kind = .mouse_up, .a = x, .b = y, .c = 1 },
    });
}

fn keyEvent(code: u16) Event {
    return .{ .kind = .key_down, .a = code };
}

test "toolbar, table and sheet interaction" {
    const a = std.testing.allocator;
    var fonts = ui.FontSet.load(a) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(a, App.window);
    defer win.close();
    var u = Ui.init(a, &win, &fonts);
    defer u.deinit();
    var app = try App.init(a, &u);
    defer app.deinit();
    app.preview(&u);
    testStep(&app, &u, &.{});

    // Segmented control → Memory tab.
    const l = App.toolbarLayout(&u, u.width());
    const seg_w = @divTrunc(l.seg.w - 4, 4);
    click(&app, &u, Rect.init(l.seg.x + 2 + seg_w, l.seg.y + 2, seg_w, l.seg.h - 4), 1);
    try std.testing.expectEqual(Tab.memory, app.tab);
    try std.testing.expectEqualStrings("cc", app.sampler.procs.items[app.order.items[0]].name());

    // Header click sorts by PID ascending, a second click descending.
    var rects: [8]Rect = undefined;
    App.columnRects(columns(.memory), u.width(), &rects, toolbar_h, header_h);
    click(&app, &u, rects[3], 1);
    try std.testing.expectEqual(SortKey.pid, app.sorts[1].key);
    try std.testing.expectEqual(@as(u32, 0), app.sampler.procs.items[app.order.items[0]].pid);
    click(&app, &u, rects[3], 1);
    try std.testing.expect(app.sorts[1].desc);
    try std.testing.expectEqual(@as(u32, 451), app.sampler.procs.items[app.order.items[0]].pid);

    // Clicking the first row selects it; arrow keys move the selection.
    click(&app, &u, Rect.init(200, toolbar_h + header_h, 100, row_h), 1);
    try std.testing.expectEqual(@as(?u32, 451), app.selected);
    testStep(&app, &u, &.{keyEvent(Key.down)});
    try std.testing.expectEqual(@as(?u32, 440), app.selected);

    // Stop button opens the confirmation sheet; Esc cancels it.
    click(&app, &u, l.stop, 1);
    try std.testing.expectEqual(Sheet.quit, app.sheet);
    try std.testing.expectEqual(@as(u32, 440), app.sheet_pid);
    // Clicks on the table are ignored while the sheet is up.
    click(&app, &u, Rect.init(200, toolbar_h + header_h, 100, row_h), 1);
    try std.testing.expectEqual(@as(?u32, 440), app.selected);
    testStep(&app, &u, &.{keyEvent(Key.esc)});
    try std.testing.expectEqual(Sheet.none, app.sheet);

    // Double-click opens the inspector without triggering its buttons.
    click(&app, &u, Rect.init(200, toolbar_h + header_h + row_h, 100, row_h), 2);
    try std.testing.expectEqual(Sheet.info, app.sheet);
    testStep(&app, &u, &.{});
    try std.testing.expectEqual(Sheet.info, app.sheet);
    testStep(&app, &u, &.{keyEvent(Key.enter)});
    try std.testing.expectEqual(Sheet.none, app.sheet);

    // Typing in the search field filters the list.
    click(&app, &u, l.search, 1);
    var ev = Event{ .kind = .key_down, .a = Key.f };
    @memcpy(ev.text[0..3], "fin");
    testStep(&app, &u, &.{ev});
    try std.testing.expectEqual(@as(usize, 1), app.order.items.len);
    try std.testing.expectEqualStrings("Finder", app.sampler.procs.items[app.order.items[0]].name());
    testStep(&app, &u, &.{keyEvent(Key.esc)});
    try std.testing.expectEqual(app.sampler.procs.items.len, app.order.items.len);
}
