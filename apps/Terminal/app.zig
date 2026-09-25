//! Terminal.app — the terminal view: grid layout, rendering with per-row
//! damage, keyboard/mouse input, selection, clipboard and menus.
//!
//! The emulator itself is `vt.Terminal`; this file is OS-independent (the
//! pty lives in pty.zig and the event loop in main.zig) so it can render
//! host previews and be unit-tested. It also satisfies the GlassKit app
//! contract (lib/ui/app.zig) for `ui.renderOnce`.

const std = @import("std");
const abi = @import("abi");
const ui = @import("ui");
const gfx = @import("gfx");
const font = @import("font");
const vt = @import("vt");
const profile_mod = @import("profile.zig");
const keys = @import("keys.zig");
const boxdraw = @import("boxdraw.zig");
const demo = @import("demo.zig");

const Allocator = std.mem.Allocator;
const Rect = gfx.Rect;
const Canvas = gfx.Canvas;
const Event = abi.window.Event;
const Mods = abi.window.Mods;
const Flags = abi.window.Flags;
const Key = abi.input.Key;
const Profile = profile_mod.Profile;
const rgbPm = profile_mod.rgbPm;
const Command = keys.Command;

pub const default_font_size: f32 = 13;
const min_font_size: f32 = 8;
const max_font_size: f32 = 32;
const scrollback_lines = 10_000;
/// Space between the window edge and the grid.
const pad_x: i32 = 10;
const pad_y: i32 = 6;

/// Menu item ids.
const menu_items = [_]struct { id: u32, cmd: Command }{
    .{ .id = 1, .cmd = .about },
    .{ .id = 2, .cmd = .quit },
    .{ .id = 10, .cmd = .new_window },
    .{ .id = 11, .cmd = .close_window },
    .{ .id = 12, .cmd = .clear },
    .{ .id = 20, .cmd = .copy },
    .{ .id = 21, .cmd = .paste },
    .{ .id = 22, .cmd = .select_all },
    .{ .id = 30, .cmd = .bigger },
    .{ .id = 31, .cmd = .smaller },
    .{ .id = 32, .cmd = .default_size },
};

fn menuId(cmd: Command) u32 {
    for (menu_items) |m| if (m.cmd == cmd) return m.id;
    unreachable;
}

const CursorShape = enum { block, underline, bar };

/// What the cursor looked like when last painted (to repaint its old row).
const CursorState = struct {
    row: usize,
    col: usize,
    width: usize,
    shape: CursorShape,
    focused: bool,
};

/// Selection in linear cell coordinates: index = row * cols + col, where
/// `row` is a `vt.Pos` row (negative in the scrollback). Range is [a, b).
const Selection = struct {
    active: bool = false,
    a: i64 = 0,
    b: i64 = 0,
    mode: enum { char, word, line } = .char,
    /// Char mode: the anchor boundary (anchor_a == anchor_b). Word/line
    /// mode: the range of the word/line that was clicked.
    anchor_a: i64 = 0,
    anchor_b: i64 = 0,
};

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Terminal",
        .width = 720,
        .height = 460,
        .min_width = 280,
        .min_height = 140,
        .flags = Flags.resizable | Flags.transparent,
    };

    allocator: Allocator,
    fonts: *ui.FontSet,
    term: vt.Terminal,

    // Appearance.
    profile: Profile,
    dark: bool,
    accent: u32,
    opaque_bg: bool = false,
    focused: bool = true,
    /// False while the window is minimized/hidden (skip painting).
    visible: bool = true,

    // Font and grid metrics.
    font_size: f32 = default_font_size,
    face: *font.Face = undefined,
    bold_face: *font.Face = undefined,
    cell_w: f32 = 8,
    cell_h: i32 = 17,
    /// Baseline offset from the top of a cell.
    baseline: i32 = 13,
    underline_y: i32 = 15,
    strike_y: i32 = 9,
    line_w: i32 = 1,
    width: i32,
    height: i32,
    /// Left pixel edge of each column (cols + 1 entries).
    col_x: []i32 = &.{},
    /// Per-column resolved foreground (scratch for painting a row).
    fg_buf: []u32 = &.{},
    /// Rows the app needs repainted (selection, cursor, focus) on top of
    /// the emulator's own damage.
    row_dirty: []bool = &.{},
    /// Snapshot of the emulator's row damage before a feed.
    dirty_before: []bool = &.{},
    full_redraw: bool = true,
    cursor_drawn: ?CursorState = null,

    // Mouse and selection.
    sel: Selection = .{},
    selecting: bool = false,
    report_button: ?vt.MouseButton = null,
    scroll_accum: f32 = 0,

    /// Bytes to write to the pty (drained by main.zig).
    out: std.ArrayList(u8) = .empty,
    /// The grid size changed: main.zig must tell the pty (TIOCSWINSZ).
    grid_changed: bool = false,
    quit: bool = false,
    new_window: bool = false,

    user_buf: [64]u8 = undefined,
    user_len: usize = 0,
    shell_buf: [64]u8 = undefined,
    shell_len: usize = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,

    pub fn init(allocator: Allocator, u: *ui.Ui) !App {
        var self: App = .{
            .allocator = allocator,
            .fonts = u.fonts,
            .term = undefined,
            .profile = Profile.get(u.theme.dark, u.theme.accent, false),
            .dark = u.theme.dark,
            .accent = u.theme.accent,
            .width = u.win.width,
            .height = u.win.height,
        };
        self.loadFont(default_font_size);
        const g = self.gridSize(self.width, self.height);
        self.term = try vt.Terminal.init(allocator, g.cols, g.rows, scrollback_lines);
        errdefer self.term.deinit();
        self.term.theme = self.profile.vt;
        try self.allocGrid(g.cols, g.rows);
        self.setIdentity(std.posix.getenv("USER") orelse "zen", std.posix.getenv("SHELL") orelse "zensh");
        return self;
    }

    pub fn deinit(self: *App) void {
        const a = self.allocator;
        self.term.deinit();
        a.free(self.col_x);
        a.free(self.fg_buf);
        a.free(self.row_dirty);
        a.free(self.dirty_before);
        self.out.deinit(a);
    }

    /// User and shell names shown in the window title.
    pub fn setIdentity(self: *App, user: []const u8, shell_path: []const u8) void {
        const u = user[0..@min(user.len, self.user_buf.len)];
        @memcpy(self.user_buf[0..u.len], u);
        self.user_len = u.len;
        const base = std.fs.path.basename(shell_path);
        const s = base[0..@min(base.len, self.shell_buf.len)];
        @memcpy(self.shell_buf[0..s.len], s);
        self.shell_len = s.len;
    }

    pub fn cols(self: *const App) usize {
        return self.term.cols;
    }

    pub fn rows(self: *const App) usize {
        return self.term.rows;
    }

    // -----------------------------------------------------------------
    // GlassKit app contract (used by ui.renderOnce for previews)

    pub fn frame(self: *App, u: *ui.Ui) void {
        self.full_redraw = true;
        self.render(u.win);
    }

    pub fn preview(self: *App, u: *ui.Ui) void {
        _ = u;
        const session = demo.build(self.allocator) catch return;
        defer self.allocator.free(session);
        self.feed(session);
    }

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        _ = self;
        mw.beginMenu("Terminal");
        mw.item(menuId(.about), "About Terminal", 0, 0, 0);
        mw.separator();
        mw.item(menuId(.quit), "Quit Terminal", 'q', 0, 0);
        mw.endMenu();
        mw.beginMenu("Shell");
        mw.item(menuId(.new_window), "New Window", 'n', 0, 0);
        mw.separator();
        mw.item(menuId(.close_window), "Close Window", 'w', 0, 0);
        mw.separator();
        mw.item(menuId(.clear), "Clear to Start", 'k', 0, 0);
        mw.endMenu();
        mw.beginMenu("Edit");
        mw.item(menuId(.copy), "Copy", 'c', 0, 0);
        mw.item(menuId(.paste), "Paste", 'v', 0, 0);
        mw.separator();
        mw.item(menuId(.select_all), "Select All", 'a', 0, 0);
        mw.endMenu();
        mw.beginMenu("View");
        mw.item(menuId(.bigger), "Bigger", '+', 0, 0);
        mw.item(menuId(.smaller), "Smaller", '-', 0, 0);
        mw.item(menuId(.default_size), "Default Size", '0', 0, 0);
        mw.endMenu();
    }

    pub fn onMenu(self: *App, u: *ui.Ui, id: u32) void {
        self.onMenuId(u.win, id);
    }

    pub fn shouldClose(self: *App, u: *ui.Ui) bool {
        _ = self;
        _ = u;
        return true;
    }

    fn onMenuId(self: *App, win: *ui.Window, id: u32) void {
        for (menu_items) |m| {
            if (m.id == id) return self.command(win, m.cmd);
        }
    }

    // -----------------------------------------------------------------
    // Output from the shell

    /// Feed pty output into the emulator; queues any replies for the pty.
    pub fn feed(self: *App, bytes: []const u8) void {
        const sb = &self.term.scrollback;
        const len0 = sb.len;
        const head0 = sb.head;
        const alt0 = self.term.isAltScreen();
        const nd = self.term.dirty.len;
        const track = self.sel.active and !self.term.all_dirty and self.dirty_before.len >= nd;
        if (track) @memcpy(self.dirty_before[0..nd], self.term.dirty);
        self.term.feed(bytes);
        const resp = self.term.takeResponse();
        if (resp.len > 0) self.send(resp);
        if (!self.sel.active) return;

        // Keep the selection on the same text as lines scroll into history;
        // drop it when the text under it changes.
        var pushed: i64 = @as(i64, @intCast(sb.len)) - @as(i64, @intCast(len0));
        if (sb.cap > 0) pushed += @intCast((sb.head + sb.cap - head0) % sb.cap);
        if (pushed < 0 or alt0 != self.term.isAltScreen()) return self.clearSelection();
        if (pushed > 0) {
            const shift = pushed * @as(i64, @intCast(self.cols()));
            self.sel.a -= shift;
            self.sel.b -= shift;
            self.sel.anchor_a -= shift;
            self.sel.anchor_b -= shift;
            if (self.sel.b <= self.lin(self.term.firstRow(), 0)) self.clearSelection();
            return;
        }
        if (!track) return;
        for (self.term.dirty, self.dirty_before[0..nd], 0..) |now, was, r| {
            if (!now or was) continue;
            const vrow = r + self.term.viewport_offset;
            if (vrow < self.rows() and self.selectedCols(vrow) != null) return self.clearSelection();
        }
    }

    /// Queue bytes for the pty.
    pub fn send(self: *App, bytes: []const u8) void {
        self.out.appendSlice(self.allocator, bytes) catch {};
    }

    // -----------------------------------------------------------------
    // Layout

    fn loadFont(self: *App, size: f32) void {
        self.font_size = size;
        self.face = self.fonts.face(.mono, size);
        self.bold_face = self.fonts.face(.mono_bold, size);
        const f = self.face;
        self.cell_w = f.advance(f.font.glyphIndex('M'));
        if (self.cell_w < 1) self.cell_w = size * 0.6;
        const box = f.ascent + f.descent;
        self.cell_h = @max(4, @as(i32, @intFromFloat(@round(box + f.line_gap))));
        const extra = @as(f32, @floatFromInt(self.cell_h)) - box;
        self.baseline = @intFromFloat(@round(f.ascent + extra / 2));
        self.line_w = @max(1, @as(i32, @intFromFloat(@round(size / 14))));
        self.underline_y = @min(self.cell_h - self.line_w, self.baseline + @max(1, @as(i32, @intFromFloat(@round(f.descent * 0.35)))));
        self.strike_y = self.baseline - @as(i32, @intFromFloat(@round(f.x_height / 2))) - @divFloor(self.line_w, 2);
    }

    fn gridSize(self: *const App, w: i32, h: i32) struct { cols: usize, rows: usize } {
        const avail_w: f32 = @floatFromInt(@max(0, w - 2 * pad_x));
        const c: usize = @intFromFloat(@max(2, @floor(avail_w / self.cell_w)));
        const r: usize = @intCast(@max(1, @divFloor(h - 2 * pad_y, self.cell_h)));
        return .{ .cols = c, .rows = r };
    }

    /// (Re)allocate the per-column/per-row buffers for a c x r grid.
    fn allocGrid(self: *App, c: usize, r: usize) !void {
        const a = self.allocator;
        const col_x = try a.alloc(i32, c + 1);
        errdefer a.free(col_x);
        const fg_buf = try a.alloc(u32, c);
        errdefer a.free(fg_buf);
        const row_dirty = try a.alloc(bool, r);
        errdefer a.free(row_dirty);
        const dirty_before = try a.alloc(bool, r);
        a.free(self.col_x);
        a.free(self.fg_buf);
        a.free(self.row_dirty);
        a.free(self.dirty_before);
        self.col_x = col_x;
        self.fg_buf = fg_buf;
        self.row_dirty = row_dirty;
        self.dirty_before = dirty_before;
        @memset(self.row_dirty, true);
        for (self.col_x, 0..) |*x, i| x.* = pad_x + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(i)) * self.cell_w)));
    }

    /// Recompute the grid for the current window and font size.
    fn relayout(self: *App) void {
        self.full_redraw = true;
        self.cursor_drawn = null;
        const g = self.gridSize(self.width, self.height);
        // Buffers must cover the grid whether or not the resize succeeds.
        self.allocGrid(@max(g.cols, self.cols()), @max(g.rows, self.rows())) catch return;
        if (g.cols != self.cols() or g.rows != self.rows()) {
            self.clearSelection();
            self.term.resize(g.cols, g.rows) catch return;
            self.grid_changed = true;
            self.allocGrid(g.cols, g.rows) catch {};
        }
    }

    pub fn resize(self: *App, w: i32, h: i32) void {
        self.width = w;
        self.height = h;
        self.relayout();
    }

    pub fn setFontSize(self: *App, size: f32) void {
        const s = std.math.clamp(size, min_font_size, max_font_size);
        if (s == self.font_size) return;
        self.loadFont(s);
        self.relayout();
    }

    pub fn setAppearance(self: *App, dark: bool, accent: u32, reduce_transparency: bool) void {
        self.dark = dark;
        self.accent = accent;
        self.opaque_bg = reduce_transparency;
        self.profile = Profile.get(dark, accent, reduce_transparency);
        self.term.theme = self.profile.vt;
        self.full_redraw = true;
    }

    /// Grid and pixel size for the pty's TIOCSWINSZ.
    pub fn winsize(self: *const App) [4]u16 {
        return .{
            @intCast(@min(self.rows(), 0xFFFF)),
            @intCast(@min(self.cols(), 0xFFFF)),
            @intCast(std.math.clamp(self.col_x[self.cols()] - pad_x, 0, 0xFFFF)),
            @intCast(std.math.clamp(@as(i32, @intCast(self.rows())) * self.cell_h, 0, 0xFFFF)),
        };
    }

    // -----------------------------------------------------------------
    // Rendering

    fn cursorState(self: *const App) ?CursorState {
        const t = &self.term;
        if (!t.cursor.visible) return null;
        const p = t.cursorViewportPos() orelse return null;
        if (p.row >= t.rows or p.col >= t.cols) return null;
        const cell = t.viewportCell(p.row, p.col);
        return .{
            .row = p.row,
            .col = p.col,
            .width = if (cell.attrs.wide and p.col + 1 < t.cols) 2 else 1,
            .shape = switch (t.cursor.style) {
                .blinking_block, .steady_block => .block,
                .blinking_underline, .steady_underline => .underline,
                .blinking_bar, .steady_bar => .bar,
            },
            .focused = self.focused,
        };
    }

    fn markRow(self: *App, vrow: usize) void {
        if (vrow < self.row_dirty.len) self.row_dirty[vrow] = true;
    }

    /// Paint everything that changed since the last call and present it.
    pub fn render(self: *App, win: *ui.Window) void {
        if (win.width <= 0 or win.height <= 0) return;
        if (win.pixels.len < @as(usize, @intCast(win.width * win.height))) return;
        if (win.width != self.width or win.height != self.height) self.resize(win.width, win.height);
        const canvas = Canvas.init(win.pixels, @intCast(win.width), @intCast(win.height), @intCast(win.width));

        const cur = self.cursorState();
        if (!std.meta.eql(cur, self.cursor_drawn)) {
            if (self.cursor_drawn) |c| self.markRow(c.row);
            if (cur) |c| self.markRow(c.row);
        }

        const full = self.full_redraw or self.term.all_dirty;
        if (full) canvas.clear(self.profile.bg_pm);
        var band: ?usize = null;
        const n = self.rows();
        for (0..n) |vrow| {
            if (full or self.row_dirty[vrow] or self.term.isRowDirty(vrow)) {
                self.paintRow(canvas, win.pixels, vrow, cur);
                if (band == null) band = vrow;
            } else if (band) |start| {
                if (!full) self.damageRows(win, start, vrow);
                band = null;
            }
        }
        if (full) {
            win.damageAll();
        } else if (band) |start| self.damageRows(win, start, n);
        self.paintScroller(canvas, win);

        @memset(self.row_dirty, false);
        self.term.clearDamage();
        self.full_redraw = false;
        self.cursor_drawn = cur;
        self.updateTitle(win);
    }

    /// Overlay scroller shown while browsing the scrollback (every repaint
    /// of a row clears it, and viewport changes repaint everything).
    fn paintScroller(self: *App, canvas: Canvas, win: *ui.Window) void {
        const off = self.term.viewport_offset;
        const history = self.term.scrollbackLen();
        if (off == 0 or history == 0) return;
        const track_h: i32 = @as(i32, @intCast(self.rows())) * self.cell_h;
        const total: i64 = @intCast(history + self.rows());
        const thumb_h: i32 = @intCast(@max(24, @divFloor(@as(i64, track_h) * @as(i64, @intCast(self.rows())), total)));
        const pos: i64 = @intCast(history - @min(off, history));
        const thumb_y = pad_y + @as(i32, @intCast(@divFloor(@as(i64, track_h - thumb_h) * pos, @as(i64, @intCast(history)))));
        const r = Rect.init(self.width - 9, thumb_y, 6, thumb_h);
        gfx.shapes.fillRoundRect(canvas, r, 3, ui.pm(if (self.dark) 0x80FFFFFF else 0x66000000));
        win.damage(r.x, pad_y, r.w, track_h);
    }

    fn damageRows(self: *App, win: *ui.Window, first: usize, end: usize) void {
        const y0 = pad_y + @as(i32, @intCast(first)) * self.cell_h;
        win.damage(0, y0, self.width, @as(i32, @intCast(end - first)) * self.cell_h);
    }

    fn cellRect(self: *const App, col: usize, w: usize, y0: i32) Rect {
        const x0 = self.col_x[col];
        return Rect.init(x0, y0, self.col_x[@min(col + w, self.cols())] - x0, self.cell_h);
    }

    fn paintRow(self: *App, canvas: Canvas, pixels: []u32, vrow: usize, cur: ?CursorState) void {
        const y0 = pad_y + @as(i32, @intCast(vrow)) * self.cell_h;
        const c = canvas.withClip(Rect.init(0, y0, self.width, self.cell_h));
        c.clear(self.profile.bg_pm);

        const theme = &self.profile.vt;
        const ncols = self.cols();
        const cells = self.term.viewportRow(vrow);
        const n = @min(cells.len, ncols);
        const rv = self.term.modes.reverse_video;
        const bg_alpha = self.profile.bg_alpha;

        // Pass 1: cell backgrounds (and resolve foregrounds).
        var col: usize = 0;
        while (col < n) : (col += 1) {
            const cell = cells[col];
            if (cell.attrs.wide_spacer and col > 0 and cells[col - 1].attrs.wide) continue;
            const w: usize = if (cell.attrs.wide and col + 1 < ncols) 2 else 1;
            const colors = theme.resolveCell(cell, rv);
            self.fg_buf[col] = rgbPm(colors.fg, 255);
            if (!std.mem.eql(u8, &colors.bg, &theme.bg)) {
                c.withClip(self.cellRect(col, w, y0)).clear(rgbPm(colors.bg, bg_alpha));
            }
        }
        if (rv and n < ncols) {
            // Reverse video: blank cells past the stored line use the fg color.
            const x0 = self.col_x[n];
            c.withClip(Rect.init(x0, y0, self.col_x[ncols] - x0, self.cell_h)).clear(rgbPm(theme.fg, bg_alpha));
        }

        // Selection highlight.
        if (self.selectedCols(vrow)) |s| {
            const x0 = self.col_x[s[0]];
            const x1 = self.col_x[s[1]];
            c.fillRect(Rect.init(x0, y0, x1 - x0, self.cell_h), if (self.focused) self.profile.selection_pm else self.profile.selection_inactive_pm);
        }

        // Block cursor background.
        var cursor_col: ?usize = null;
        if (cur) |cs| if (cs.row == vrow) {
            cursor_col = cs.col;
            if (cs.shape == .block and cs.focused) c.withClip(self.cellRect(cs.col, cs.width, y0)).clear(self.profile.cursor_pm);
        };

        // Pass 2: glyphs and decorations.
        var target = font.Target.init(pixels, @intCast(canvas.width), @intCast(canvas.height), @intCast(canvas.stride));
        target.clip = .{ .x0 = c.clip.x, .y0 = c.clip.y, .x1 = c.clip.right(), .y1 = c.clip.bottom() };
        col = 0;
        while (col < n) : (col += 1) {
            const cell = cells[col];
            if (cell.attrs.wide_spacer) continue;
            const w: usize = if (cell.attrs.wide and col + 1 < ncols) 2 else 1;
            var fg = self.fg_buf[col];
            if (cursor_col == col and cur.?.shape == .block and cur.?.focused) fg = self.profile.cursor_text_pm;
            if (cell.attrs.hidden) continue;
            if (cell.cp != ' ' and cell.cp != 0) self.drawChar(c, target, cell.cp, col, w, y0, fg, cell.attrs.bold);
            if (cell.attrs.underline or cell.attrs.strike) {
                const r = self.cellRect(col, w, y0);
                if (cell.attrs.underline) c.fillRect(Rect.init(r.x, y0 + self.underline_y, r.w, self.line_w), fg);
                if (cell.attrs.strike) c.fillRect(Rect.init(r.x, y0 + self.strike_y, r.w, self.line_w), fg);
            }
        }

        // Cursor outlines (unfocused block, bar, underline).
        if (cur) |cs| if (cs.row == vrow) {
            const r = self.cellRect(cs.col, cs.width, y0);
            const color = if (cs.focused) self.profile.cursor_pm else self.profile.cursor_hollow_pm;
            const t: i32 = @max(1, @divFloor(self.cell_h, 9));
            switch (cs.shape) {
                .block => if (!cs.focused) {
                    c.fillRect(Rect.init(r.x, r.y, r.w, 1), color);
                    c.fillRect(Rect.init(r.x, r.bottom() - 1, r.w, 1), color);
                    c.fillRect(Rect.init(r.x, r.y + 1, 1, r.h - 2), color);
                    c.fillRect(Rect.init(r.right() - 1, r.y + 1, 1, r.h - 2), color);
                },
                .underline => c.fillRect(Rect.init(r.x, r.bottom() - t, r.w, t), color),
                .bar => c.fillRect(Rect.init(r.x, r.y, @max(2, t), r.h), color),
            }
        };
    }

    fn drawChar(self: *App, c: Canvas, target: font.Target, cp: u21, col: usize, w: usize, y0: i32, color: u32, bold: bool) void {
        if (boxdraw.handles(cp)) {
            _ = boxdraw.draw(c, cp, self.cellRect(col, w, y0), color);
            return;
        }
        const f = if (bold) self.bold_face else self.face;
        const g = f.lookup(cp);
        if (g.id == 0) {
            // No font has it (CJK, emoji...): draw a "tofu" box.
            const r = self.cellRect(col, w, y0).inset(1, 0);
            const top = y0 + self.baseline - @as(i32, @intFromFloat(@round(f.cap_height))) - 1;
            const box = Rect.init(r.x, top, r.w, y0 + self.baseline + 1 - top);
            const tc = gfx.Color.mulAlpha(color, 0xA0);
            c.fillRect(Rect.init(box.x, box.y, box.w, 1), tc);
            c.fillRect(Rect.init(box.x, box.bottom() - 1, box.w, 1), tc);
            c.fillRect(Rect.init(box.x, box.y + 1, 1, box.h - 2), tc);
            c.fillRect(Rect.init(box.right() - 1, box.y + 1, 1, box.h - 2), tc);
            return;
        }
        var x = @as(f32, @floatFromInt(pad_x)) + @as(f32, @floatFromInt(col)) * self.cell_w;
        if (g.face != f) {
            // Proportional fallback glyph: center it in its cells.
            const adv = g.face.advance(g.id);
            x += (self.cell_w * @as(f32, @floatFromInt(w)) - adv) / 2;
        }
        const pos = font.splitSubpixel(x);
        const bm = g.face.glyphBitmap(g.id, pos.subpixel) catch return;
        font.drawGlyph(target, bm, pos.x, y0 + self.baseline, color);
    }

    fn updateTitle(self: *App, win: *ui.Window) void {
        var buf: [256]u8 = undefined;
        var osc = self.term.getTitle();
        if (osc.len > 160) {
            var end: usize = 160;
            while (end > 0 and osc[end] & 0xC0 == 0x80) end -= 1; // keep UTF-8 whole
            osc = osc[0..end];
        }
        const s = if (osc.len > 0)
            std.fmt.bufPrint(&buf, "{s} — {d}×{d}", .{ osc, self.cols(), self.rows() }) catch return
        else
            std.fmt.bufPrint(&buf, "{s} — {s} — {d}×{d}", .{ self.user_buf[0..self.user_len], self.shell_buf[0..self.shell_len], self.cols(), self.rows() }) catch return;
        if (std.mem.eql(u8, s, self.title_buf[0..self.title_len])) return;
        @memcpy(self.title_buf[0..s.len], s);
        self.title_len = s.len;
        win.setTitle(s);
    }

    pub fn title(self: *const App) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    // -----------------------------------------------------------------
    // Events

    pub fn handleEvent(self: *App, win: *ui.Window, e: Event) void {
        switch (e.kind) {
            .key_down => self.keyDown(win, e),
            .mouse_down => self.mouseDown(e),
            .mouse_move => self.mouseMove(e),
            .mouse_up => self.mouseUp(e),
            .scroll => self.scrollWheel(e),
            .focus => self.setFocused(e.a != 0),
            .resize => self.resize(win.width, win.height),
            .appearance => self.setAppearance(e.a != 0, @bitCast(e.b), e.c != 0),
            .menu => self.onMenuId(win, @intCast(e.a)),
            .close_request, .quit_request => self.quit = true,
            .visibility => {
                self.visible = e.a != 0;
                if (self.visible) self.full_redraw = true;
            },
            else => {},
        }
    }

    fn setFocused(self: *App, focused: bool) void {
        if (focused == self.focused) return;
        self.focused = focused;
        self.markSelectionRows();
        var buf: [8]u8 = undefined;
        self.send(self.term.encodeFocus(focused, &buf));
    }

    pub fn command(self: *App, win: *ui.Window, cmd: Command) void {
        const page: isize = @intCast(@max(1, self.rows() - 1));
        switch (cmd) {
            .about => win.notify("Terminal", "Version 1.0 · Zen OS 1.0 Golden Gate · xterm-256color"),
            .quit, .close_window => self.quit = true,
            .new_window => self.new_window = true,
            .clear => self.clearToStart(),
            .copy => self.copySelection(),
            .paste => self.paste(),
            .select_all => self.selectAll(),
            .bigger => self.setFontSize(self.font_size + 1),
            .smaller => self.setFontSize(self.font_size - 1),
            .default_size => self.setFontSize(default_font_size),
            .scroll_line_up => self.term.scrollViewport(1),
            .scroll_line_down => self.term.scrollViewport(-1),
            .scroll_page_up => self.term.scrollViewport(page),
            .scroll_page_down => self.term.scrollViewport(-page),
            .scroll_top => self.term.scrollViewportToTop(),
            .scroll_bottom => self.term.scrollViewportToBottom(),
        }
    }

    fn keyDown(self: *App, win: *ui.Window, e: Event) void {
        const code: u16 = @intCast(e.a);
        if (keys.commandFor(code, e.mods)) |cmd| return self.command(win, cmd);
        if (e.mods & Mods.cmd != 0) return;
        switch (code) {
            Key.leftshift, Key.rightshift, Key.leftctrl, Key.rightctrl, Key.leftalt, Key.rightalt, Key.leftmeta, Key.rightmeta, Key.capslock => return,
            else => {},
        }
        var mods = e.mods;
        if (code == Key.pageup or code == Key.pagedown) {
            // Like macOS: Page Up/Down browse the scrollback; with Shift
            // they go to the program.
            if (mods & Mods.shift == 0 and !self.term.isAltScreen()) {
                return self.command(win, if (code == Key.pageup) .scroll_page_up else .scroll_page_down);
            }
            mods &= ~Mods.shift;
        }
        var buf: [128]u8 = undefined;
        const bytes = keys.encode(&self.term, code, mods, e.textSlice(), &buf);
        if (bytes.len == 0) return;
        self.send(bytes);
        self.term.scrollViewportToBottom();
    }

    // -----------------------------------------------------------------
    // Mouse

    const Hit = struct { vrow: usize, col: usize, boundary: usize };

    fn hitTest(self: *const App, x: i32, y: i32) Hit {
        const nrows: i32 = @intCast(self.rows());
        const vrow = std.math.clamp(@divFloor(y - pad_y, self.cell_h), 0, nrows - 1);
        const fx = @as(f32, @floatFromInt(x - pad_x)) / self.cell_w;
        const ncols: f32 = @floatFromInt(self.cols());
        return .{
            .vrow = @intCast(vrow),
            .col = @intFromFloat(std.math.clamp(@floor(fx), 0, ncols - 1)),
            .boundary = @intFromFloat(std.math.clamp(@round(fx), 0, ncols)),
        };
    }

    fn mouseButton(c: i32) vt.MouseButton {
        return switch (c) {
            2 => .right,
            3 => .middle,
            else => .left,
        };
    }

    /// Mouse events go to the program when it asked for them, unless Shift
    /// is held (then the terminal selects text).
    fn reportsMouse(self: *const App, mods: u32) bool {
        return self.term.mouseReporting() and mods & Mods.shift == 0;
    }

    fn reportMouse(self: *App, action: vt.MouseAction, button: vt.MouseButton, x: i32, y: i32, mods: u32) void {
        const hit = self.hitTest(x, y);
        var buf: [64]u8 = undefined;
        var m = keys.vtMods(mods);
        m.super = false;
        const s = self.term.encodeMouse(.{ .action = action, .button = button, .row = hit.vrow, .col = hit.col, .mods = m }, &buf);
        self.send(s);
    }

    fn mouseDown(self: *App, e: Event) void {
        if (self.reportsMouse(e.mods)) {
            const b = mouseButton(e.c);
            self.report_button = b;
            self.reportMouse(.press, b, e.a, e.b, e.mods);
            return;
        }
        if (e.c != 1) return;
        const hit = self.hitTest(e.a, e.b);
        const row = self.term.viewportToPos(hit.vrow, 0).row;
        self.markSelectionRows();
        if (e.d >= 3) {
            const r = self.lineRange(row);
            self.sel = .{ .active = true, .mode = .line, .a = r[0], .b = r[1], .anchor_a = r[0], .anchor_b = r[1] };
        } else if (e.d == 2) {
            const r = self.wordRange(row, hit.col);
            self.sel = .{ .active = r[0] < r[1], .mode = .word, .a = r[0], .b = r[1], .anchor_a = r[0], .anchor_b = r[1] };
        } else if (e.mods & Mods.shift != 0 and self.sel.active) {
            // Shift-click extends the selection from its far end.
            const p = self.lin(row, hit.boundary);
            const anchor = if (@abs(p - self.sel.a) > @abs(p - self.sel.b)) self.sel.a else self.sel.b;
            self.sel.mode = .char;
            self.sel.anchor_a = anchor;
            self.sel.anchor_b = anchor;
            self.extendSelection(hit, row);
        } else {
            const p = self.lin(row, hit.boundary);
            self.sel = .{ .active = false, .mode = .char, .a = p, .b = p, .anchor_a = p, .anchor_b = p };
        }
        self.selecting = true;
        self.markSelectionRows();
    }

    fn mouseMove(self: *App, e: Event) void {
        if (self.report_button) |b| {
            if (self.term.modes.mouse_tracking == .button_event or self.term.modes.mouse_tracking == .any_event)
                self.reportMouse(.motion, b, e.a, e.b, e.mods);
            return;
        }
        if (!self.selecting) {
            if (self.term.modes.mouse_tracking == .any_event and e.mods & Mods.shift == 0)
                self.reportMouse(.motion, .none, e.a, e.b, e.mods);
            return;
        }
        // Dragging past the top/bottom edge scrolls the history.
        if (e.b < pad_y) {
            self.term.scrollViewport(1);
        } else if (e.b >= pad_y + @as(i32, @intCast(self.rows())) * self.cell_h) {
            self.term.scrollViewport(-1);
        }
        const hit = self.hitTest(e.a, e.b);
        const row = self.term.viewportToPos(hit.vrow, 0).row;
        self.markSelectionRows();
        self.extendSelection(hit, row);
        self.markSelectionRows();
    }

    fn mouseUp(self: *App, e: Event) void {
        if (self.report_button) |b| {
            self.report_button = null;
            self.reportMouse(.release, b, e.a, e.b, e.mods);
            return;
        }
        self.selecting = false;
    }

    fn scrollWheel(self: *App, e: Event) void {
        self.scroll_accum += @floatFromInt(e.d);
        const step = @as(f32, @floatFromInt(self.cell_h)) * 0.75;
        const lines: i32 = @intFromFloat(@trunc(self.scroll_accum / step));
        if (lines == 0) return;
        self.scroll_accum -= @as(f32, @floatFromInt(lines)) * step;
        const count: usize = @min(@abs(lines), 20);
        if (self.reportsMouse(e.mods)) {
            for (0..count) |_| self.reportMouse(.press, if (lines < 0) .wheel_up else .wheel_down, e.a, e.b, e.mods);
        } else if (self.term.isAltScreen()) {
            // Full-screen programs (less, man, editors) get arrow keys.
            var buf: [16]u8 = undefined;
            const s = self.term.encodeKey(if (lines < 0) .up else .down, .{}, &buf);
            for (0..count) |_| self.send(s);
        } else {
            self.term.scrollViewport(-lines);
        }
    }

    // -----------------------------------------------------------------
    // Selection

    fn lin(self: *const App, row: isize, col: usize) i64 {
        return @as(i64, row) * @as(i64, @intCast(self.cols())) + @as(i64, @intCast(col));
    }

    fn posOf(self: *const App, idx: i64) vt.Pos {
        const c: i64 = @intCast(self.cols());
        return .{ .row = @intCast(@divFloor(idx, c)), .col = @intCast(@mod(idx, c)) };
    }

    /// Selected columns [c0, c1) of viewport row `vrow`, if any.
    fn selectedCols(self: *const App, vrow: usize) ?[2]usize {
        if (!self.sel.active or self.sel.a >= self.sel.b) return null;
        const row_a = self.lin(self.term.viewportToPos(vrow, 0).row, 0);
        const row_b = row_a + @as(i64, @intCast(self.cols()));
        const a = @max(self.sel.a, row_a);
        const b = @min(self.sel.b, row_b);
        if (a >= b) return null;
        return .{ @intCast(a - row_a), @intCast(b - row_a) };
    }

    fn markSelectionRows(self: *App) void {
        if (!self.sel.active) return;
        for (0..self.rows()) |vrow| {
            if (self.selectedCols(vrow) != null) self.markRow(vrow);
        }
    }

    pub fn clearSelection(self: *App) void {
        self.markSelectionRows();
        self.sel = .{};
    }

    pub fn hasSelection(self: *const App) bool {
        return self.sel.active and self.sel.a < self.sel.b;
    }

    fn wordRange(self: *const App, row: isize, col: usize) [2]i64 {
        const r = self.term.wordAt(row, col) orelse return .{ 0, 0 };
        const c = self.cols() - 1;
        const start = self.lin(r.start.row, @min(r.start.col, c));
        const end = self.lin(r.end.row, @min(r.end.col, c)) + 1;
        return .{ start, end };
    }

    /// The logical line (following soft wraps) containing `row`.
    fn lineRange(self: *const App, row: isize) [2]i64 {
        var top = row;
        while (top > self.term.firstRow()) {
            const prev = self.term.lineAt(top - 1) orelse break;
            if (!prev.wrapped) break;
            top -= 1;
        }
        var bot = row;
        const last: isize = @as(isize, @intCast(self.rows())) - 1;
        while (bot < last) {
            const l = self.term.lineAt(bot) orelse break;
            if (!l.wrapped) break;
            bot += 1;
        }
        return .{ self.lin(top, 0), self.lin(bot, 0) + @as(i64, @intCast(self.cols())) };
    }

    fn extendSelection(self: *App, hit: Hit, row: isize) void {
        var a = self.sel.anchor_a;
        var b = self.sel.anchor_b;
        switch (self.sel.mode) {
            .char => {
                const p = self.lin(row, hit.boundary);
                a = @min(a, p);
                b = @max(b, p);
            },
            .word => {
                const r = self.wordRange(row, hit.col);
                if (r[0] < r[1]) {
                    a = @min(a, r[0]);
                    b = @max(b, r[1]);
                }
            },
            .line => {
                const r = self.lineRange(row);
                a = @min(a, r[0]);
                b = @max(b, r[1]);
            },
        }
        self.sel.a = a;
        self.sel.b = b;
        self.sel.active = a < b;
    }

    pub fn selectAll(self: *App) void {
        self.markSelectionRows();
        var last: usize = self.rows() - 1;
        while (last > 0 and vt.cell.trimmedLen(self.term.getRow(last)) == 0) last -= 1;
        self.sel = .{
            .active = true,
            .mode = .char,
            .a = self.lin(self.term.firstRow(), 0),
            .b = self.lin(@intCast(last), 0) + @as(i64, @intCast(self.cols())),
        };
        self.sel.anchor_a = self.sel.a;
        self.sel.anchor_b = self.sel.a;
        self.markSelectionRows();
    }

    /// Selected text (UTF-8), or null. Caller frees.
    pub fn selectionText(self: *const App, allocator: Allocator) ?[]u8 {
        if (!self.hasSelection()) return null;
        return self.term.textInRange(allocator, self.posOf(self.sel.a), self.posOf(self.sel.b - 1)) catch null;
    }

    fn copySelection(self: *App) void {
        const text = self.selectionText(self.allocator) orelse return;
        defer self.allocator.free(text);
        ui.client.clipboardSet(text) catch {};
    }

    fn paste(self: *App) void {
        const clip = ui.client.clipboardGet(self.allocator) catch return;
        defer self.allocator.free(clip);
        self.pasteText(clip);
    }

    pub fn pasteText(self: *App, text: []const u8) void {
        if (text.len == 0) return;
        const data = self.term.encodePaste(self.allocator, text) catch return;
        defer self.allocator.free(data);
        self.send(data);
        self.term.scrollViewportToBottom();
    }

    /// Cmd+K: erase the scrollback and the screen, keeping the line with
    /// the cursor (the prompt) at the top.
    pub fn clearToStart(self: *App) void {
        self.clearSelection();
        if (self.term.isAltScreen()) {
            self.term.scrollback.clear(self.allocator);
            self.term.viewport_offset = 0;
            return;
        }
        var buf: [96]u8 = undefined;
        const r = self.term.cursor.row;
        const col = self.term.cursor.col;
        const seq = if (r > 0)
            std.fmt.bufPrint(&buf, "\x1b[{d}S\x1b[3J\x1b[2;1H\x1b[J\x1b[1;{d}H", .{ r, col + 1 }) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b[3J\x1b[2;1H\x1b[J\x1b[1;{d}H", .{col + 1}) catch return;
        // Use a fresh parser so a partial sequence from the shell is kept.
        const saved = self.term.parser;
        self.term.parser = .{};
        self.term.feed(seq);
        self.term.parser = saved;
        _ = self.term.takeResponse();
        self.full_redraw = true;
    }
};

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testApp(fonts: *ui.FontSet, win: *ui.Window) !struct { u: ui.Ui, app: App } {
    var u = ui.Ui.init(testing.allocator, win, fonts);
    u.setDark(true, null);
    const app = try App.init(testing.allocator, &u);
    return .{ .u = u, .app = app };
}

test "layout, rendering and title" {
    var fonts = ui.FontSet.load(testing.allocator) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(testing.allocator, .{ .width = 720, .height = 460 });
    defer win.close();
    var t = try testApp(&fonts, &win);
    defer t.u.deinit();
    var app = &t.app;
    defer app.deinit();
    app.setIdentity("zen", "/bin/zensh");

    try testing.expect(app.cols() >= 80);
    try testing.expect(app.rows() >= 24);
    app.feed("hello \x1b[1;31mred\x1b[0m \x1b[4munder\x1b[0m ─┼─ █▀▄\r\n");
    app.render(&win);
    try testing.expect(std.mem.startsWith(u8, app.title(), "zen — zensh — "));
    // Background is the translucent profile color; text pixels differ.
    try testing.expectEqual(app.profile.bg_pm, win.pixels[0]);
    const row_y: usize = @intCast(pad_y + app.baseline - 4);
    var lit: usize = 0;
    for (0..200) |x| {
        if (win.pixels[row_y * 720 + x] != app.profile.bg_pm) lit += 1;
    }
    try testing.expect(lit > 10);

    app.feed("\x1b]0;vim notes.txt\x07");
    app.render(&win);
    try testing.expect(std.mem.startsWith(u8, app.title(), "vim notes.txt — "));

    // Resize reflows the grid and asks for a pty size update.
    win.width = 400;
    win.height = 300;
    app.resize(400, 300);
    try testing.expect(app.grid_changed);
    try testing.expect(app.cols() < 80);
}

test "selection, word select and copy text" {
    var fonts = ui.FontSet.load(testing.allocator) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(testing.allocator, .{ .width = 720, .height = 460 });
    defer win.close();
    var t = try testApp(&fonts, &win);
    defer t.u.deinit();
    var app = &t.app;
    defer app.deinit();

    app.feed("alpha beta-gamma delta\r\nsecond line");
    const cx = struct {
        fn x(a: *const App, col: usize) i32 {
            return pad_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(col)) * a.cell_w + a.cell_w / 2));
        }
    }.x;
    const y0 = pad_y + @divFloor(app.cell_h, 2);
    // Double-click selects a word (hyphens are word characters).
    app.handleEvent(&win, .{ .kind = .mouse_down, .a = cx(app, 8), .b = y0, .c = 1, .d = 2 });
    app.handleEvent(&win, .{ .kind = .mouse_up, .a = cx(app, 8), .b = y0, .c = 1 });
    const w = app.selectionText(testing.allocator).?;
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("beta-gamma", w);

    // Drag across the line break.
    app.handleEvent(&win, .{ .kind = .mouse_down, .a = pad_x + 1, .b = y0, .c = 1, .d = 1 });
    app.handleEvent(&win, .{ .kind = .mouse_move, .a = pad_x + @as(i32, @intFromFloat(6 * app.cell_w)), .b = y0 + app.cell_h });
    app.handleEvent(&win, .{ .kind = .mouse_up, .a = 0, .b = 0, .c = 1 });
    const d = app.selectionText(testing.allocator).?;
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("alpha beta-gamma delta\nsecond", d);

    // Scrolling output keeps the selection on the same text.
    app.selectAll();
    const before = app.selectionText(testing.allocator).?;
    defer testing.allocator.free(before);
    for (0..app.rows()) |_| app.feed("\r\n");
    const after = app.selectionText(testing.allocator).?;
    defer testing.allocator.free(after);
    try testing.expect(std.mem.startsWith(u8, after, before));

    app.clearSelection();
    try testing.expect(app.selectionText(testing.allocator) == null);
}

test "keys, paste and commands produce pty bytes" {
    var fonts = ui.FontSet.load(testing.allocator) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(testing.allocator, .{ .width = 720, .height = 460 });
    defer win.close();
    var t = try testApp(&fonts, &win);
    defer t.u.deinit();
    var app = &t.app;
    defer app.deinit();

    var ev: Event = .{ .kind = .key_down, .a = Key.l };
    ev.text[0] = 'l';
    app.handleEvent(&win, ev);
    app.handleEvent(&win, .{ .kind = .key_down, .a = Key.c, .mods = Mods.ctrl });
    app.handleEvent(&win, .{ .kind = .key_down, .a = Key.leftshift, .mods = Mods.shift });
    try testing.expectEqualStrings("l\x03", app.out.items);
    app.out.clearRetainingCapacity();

    app.feed("\x1b[?2004h");
    app.pasteText("echo hi\nls");
    try testing.expectEqualStrings("\x1b[200~echo hi\rls\x1b[201~", app.out.items);
    app.out.clearRetainingCapacity();

    // Device status report replies are queued for the pty.
    app.feed("\x1b[6n");
    try testing.expectEqualStrings("\x1b[1;1R", app.out.items);
    app.out.clearRetainingCapacity();

    // Cmd+= grows the font and shrinks the grid.
    const cols0 = app.cols();
    app.handleEvent(&win, .{ .kind = .key_down, .a = Key.equal, .mods = Mods.cmd });
    try testing.expect(app.cols() < cols0);
    app.handleEvent(&win, .{ .kind = .menu, .a = @intCast(menuId(.default_size)) });
    try testing.expectEqual(cols0, app.cols());

    // Cmd+K keeps the prompt line only.
    for (0..40) |i| {
        var b: [32]u8 = undefined;
        app.feed(std.fmt.bufPrint(&b, "line {d}\r\n", .{i}) catch unreachable);
    }
    app.feed("prompt$ ");
    app.handleEvent(&win, .{ .kind = .key_down, .a = Key.k, .mods = Mods.cmd });
    try testing.expectEqual(@as(usize, 0), app.term.scrollbackLen());
    try testing.expectEqual(@as(usize, 0), app.term.cursor.row);
    try testing.expectEqual(@as(u21, 'p'), app.term.getCell(0, 0).cp);
    try testing.expectEqual(@as(u21, ' '), app.term.getCell(1, 0).cp);

    app.handleEvent(&win, .{ .kind = .close_request });
    try testing.expect(app.quit);
}

test {
    _ = keys;
    _ = boxdraw;
    _ = profile_mod;
    _ = demo;
}
