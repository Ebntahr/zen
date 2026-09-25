//! The terminal emulator: screen state driven by the escape sequence parser.
//!
//! Usage:
//!   var term = try Terminal.init(allocator, 80, 24, 10_000);
//!   defer term.deinit();
//!   term.feed(bytes_from_pty);
//!   pty.write(term.takeResponse());           // DSR/DA/... replies
//!   for (0..term.rows) |r| if (term.isRowDirty(r)) draw(term.viewportRow(r));
//!   term.clearDamage();
//!
//! Coordinates: `Pos.row` is relative to the top of the active screen; rows
//! -1, -2, ... address the scrollback (newest first). Columns are 0-based.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attrs = cell_mod.Attrs;
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const Row = screen_mod.Row;
const Scrollback = screen_mod.Scrollback;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Csi = parser_mod.Csi;
const Esc = parser_mod.Esc;
const OscTerminator = parser_mod.OscTerminator;
const codepointWidth = @import("wcwidth.zig").codepointWidth;
const palette = @import("palette.zig");
const input = @import("input.zig");

pub const MouseTracking = input.MouseTracking;
pub const MouseEncoding = input.MouseEncoding;

pub const Charset = enum { ascii, dec_special, uk };

pub const CursorStyle = enum {
    blinking_block,
    steady_block,
    blinking_underline,
    steady_underline,
    blinking_bar,
    steady_bar,

    pub fn isBlinking(s: CursorStyle) bool {
        return switch (s) {
            .blinking_block, .blinking_underline, .blinking_bar => true,
            else => false,
        };
    }
};

/// Current SGR rendition applied to newly written cells.
pub const Pen = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    /// DECAWM "last column flag": a character was written in the last
    /// column; the next printable character wraps first.
    pending_wrap: bool = false,
    visible: bool = true,
    style: CursorStyle = .blinking_block,
    pen: Pen = .{},
};

pub const CharsetState = struct {
    g: [4]Charset = .{ .ascii, .ascii, .ascii, .ascii },
    /// Which of G0..G3 is invoked into GL (SI=0, SO=1, LS2, LS3).
    gl: u2 = 0,
    /// Single shift (SS2/SS3) for the next character.
    single_shift: ?u2 = null,
};

/// State saved by DECSC / CSI s / mode 1048 / 1049.
pub const SavedCursor = struct {
    row: usize = 0,
    col: usize = 0,
    pending_wrap: bool = false,
    pen: Pen = .{},
    origin: bool = false,
    charset: CharsetState = .{},
};

pub const Modes = struct {
    /// DECAWM (?7)
    autowrap: bool = true,
    /// DECOM (?6)
    origin: bool = false,
    /// IRM (4)
    insert: bool = false,
    /// LNM (20)
    linefeed_newline: bool = false,
    /// DECCKM (?1)
    app_cursor: bool = false,
    /// DECKPAM (ESC =) / DECKPNM (ESC >) / DECNKM (?66)
    app_keypad: bool = false,
    /// DECSCNM (?5)
    reverse_video: bool = false,
    /// ?2004
    bracketed_paste: bool = false,
    /// ?1004
    focus_events: bool = false,
    /// ?9 / ?1000 / ?1002 / ?1003
    mouse_tracking: MouseTracking = .none,
    /// ?1005 / ?1006 / ?1015
    mouse_encoding: MouseEncoding = .default,
    /// ?1007: wheel sends cursor keys on the alternate screen (app decides).
    alternate_scroll: bool = false,
    /// ?2026: the app is mid-frame; the renderer may defer repainting.
    synchronized_output: bool = false,
};

pub const Pos = struct {
    row: isize,
    col: usize,

    pub fn lessThan(a: Pos, b: Pos) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }
};

/// Inclusive range of cells.
pub const Range = struct { start: Pos, end: Pos };

pub const LineRef = struct { cells: []const Cell, wrapped: bool };

pub const BellCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const CursorSnapshot = struct {
    row: usize = 0,
    col: usize = 0,
    visible: bool = true,
    style: CursorStyle = .blinking_block,
    viewport_offset: usize = 0,
};

const max_title = 256;
const max_cwd = 1024;

/// DEC Special Graphics for 0x5f..0x7e.
const dec_special = [32]u21{
    ' ',    0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0,
    0x00b1, 0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c,
    0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534,
    0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7,
};

fn mapCharset(cs: Charset, c: u21) u21 {
    return switch (cs) {
        .ascii => c,
        .uk => if (c == '#') 0xa3 else c,
        .dec_special => if (c >= 0x5f and c <= 0x7e) dec_special[c - 0x5f] else c,
    };
}

/// If `col` holds the spacer half of a wide char, blank both halves.
/// A wrap spacer (no head to its left) is simply blanked.
fn fixLeftEdge(row: []Cell, col: usize) void {
    if (col >= row.len or !row[col].attrs.wide_spacer) return;
    if (col > 0 and row[col - 1].attrs.wide) row[col - 1] = .{ .fg = row[col - 1].fg, .bg = row[col - 1].bg };
    row[col] = .{ .fg = row[col].fg, .bg = row[col].bg };
}

/// If `col` holds the head of a wide char, blank both halves.
fn fixRightEdge(row: []Cell, col: usize) void {
    if (col >= row.len or !row[col].attrs.wide) return;
    if (col + 1 < row.len and row[col + 1].attrs.wide_spacer) row[col + 1] = .{ .fg = row[col + 1].fg, .bg = row[col + 1].bg };
    row[col] = .{ .fg = row[col].fg, .bg = row[col].bg };
}

fn breakWide(row: []Cell, col: usize) void {
    fixLeftEdge(row, col);
    fixRightEdge(row, col);
}

/// Blank wide-char halves that lost their partner (after cropping/moving
/// cells). A spacer without a head is only allowed in the last column.
fn sanitizeRow(row: []Cell) void {
    for (row, 0..) |*c, i| {
        if (c.attrs.wide and !(i + 1 < row.len and row[i + 1].attrs.wide_spacer)) {
            c.* = .{ .fg = c.fg, .bg = c.bg };
        } else if (c.attrs.wide_spacer and !(i > 0 and row[i - 1].attrs.wide) and i + 1 != row.len) {
            c.* = .{ .fg = c.fg, .bg = c.bg };
        }
    }
}

fn clamp8(v: u16) u8 {
    return @intCast(@min(v, 255));
}

/// Cursor position of the primary screen tracked through a resize.
const Track = struct { row: usize, col: usize, pending: bool };

pub const Terminal = struct {
    allocator: Allocator,
    cols: usize,
    rows: usize,

    primary: Screen,
    alternate: Screen,
    alt_active: bool = false,
    scrollback: Scrollback,
    scrollback_limit: usize,

    cursor: Cursor = .{},
    saved_primary: ?SavedCursor = null,
    saved_alt: ?SavedCursor = null,
    /// Scroll region (DECSTBM), inclusive, 0-based.
    scroll_top: usize = 0,
    scroll_bottom: usize,
    tabstops: []bool,
    modes: Modes = .{},
    charset: CharsetState = .{},
    parser: Parser = .{},
    last_printed: ?u21 = null,

    title_buf: [max_title]u8 = undefined,
    title_len: usize = 0,
    icon_buf: [max_title]u8 = undefined,
    icon_len: usize = 0,
    cwd_buf: [max_cwd]u8 = undefined,
    cwd_len: usize = 0,
    /// Set when OSC 0/1/2 changes the window title or icon (tab) name.
    /// The app clears it (see `takeTitleChanged`).
    title_changed: bool = false,
    /// Set when OSC 7 reports a new working directory. The app clears it.
    cwd_changed: bool = false,

    /// Number of BEL characters received (wrapping).
    bell_count: u32 = 0,
    bell_pending: bool = false,
    on_bell: ?BellCallback = null,

    response_buf: [1024]u8 = undefined,
    response_len: usize = 0,

    /// Per screen-row damage.
    dirty: []bool,
    /// Everything (including the viewport mapping) needs repainting.
    all_dirty: bool = true,
    damage_cursor: CursorSnapshot = .{},

    /// Lines scrolled back into history (0 = live screen at the bottom).
    viewport_offset: usize = 0,

    /// Colors reported for OSC 4/10/11/12 queries. Set by the app to match
    /// its theme.
    theme: palette.Theme = palette.Theme.dark,

    pub fn init(allocator: Allocator, cols_in: usize, rows_in: usize, scrollback_lines: usize) !Terminal {
        const cols = @max(cols_in, 1);
        const rows = @max(rows_in, 1);
        var primary = try Screen.init(allocator, cols, rows);
        errdefer primary.deinit(allocator);
        var alternate = try Screen.init(allocator, cols, rows);
        errdefer alternate.deinit(allocator);
        var sb = try Scrollback.init(allocator, scrollback_lines);
        errdefer sb.deinit(allocator);
        const tabs = try allocator.alloc(bool, cols);
        errdefer allocator.free(tabs);
        const dirty = try allocator.alloc(bool, rows);
        @memset(dirty, true);
        resetTabs(tabs, 0);
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .primary = primary,
            .alternate = alternate,
            .scrollback = sb,
            .scrollback_limit = scrollback_lines,
            .scroll_bottom = rows - 1,
            .tabstops = tabs,
            .dirty = dirty,
        };
    }

    pub fn deinit(self: *Terminal) void {
        const a = self.allocator;
        self.primary.deinit(a);
        self.alternate.deinit(a);
        self.scrollback.deinit(a);
        a.free(self.tabstops);
        a.free(self.dirty);
        self.* = undefined;
    }

    fn resetTabs(tabs: []bool, from: usize) void {
        for (tabs[from..], from..) |*t, i| t.* = i != 0 and i % 8 == 0;
    }

    // -----------------------------------------------------------------
    // Input from the pty

    const Handler = struct {
        t: *Terminal,
        pub fn print(h: Handler, cp: u21) void {
            h.t.print(cp);
        }
        pub fn printAscii(h: Handler, run: []const u8) void {
            h.t.printAscii(run);
        }
        pub fn execute(h: Handler, c: u8) void {
            h.t.execute(c);
        }
        pub fn csiDispatch(h: Handler, csi: Csi) void {
            h.t.csiDispatch(csi);
        }
        pub fn escDispatch(h: Handler, esc: Esc) void {
            h.t.escDispatch(esc);
        }
        pub fn oscDispatch(h: Handler, data: []const u8, term: OscTerminator) void {
            h.t.oscDispatch(data, term);
        }
    };

    /// Process output from the application. Never fails: allocation failures
    /// while saving scrollback just drop the line's content.
    pub fn feed(self: *Terminal, bytes: []const u8) void {
        self.parser.feed(Handler{ .t = self }, bytes);
    }

    /// Bytes the terminal wants written back to the pty (replies to DSR, DA,
    /// OSC color queries, ...). The slice is valid until the next `feed`.
    pub fn takeResponse(self: *Terminal) []const u8 {
        const out = self.response_buf[0..self.response_len];
        self.response_len = 0;
        return out;
    }

    fn respond(self: *Terminal, bytes: []const u8) void {
        if (self.response_len + bytes.len > self.response_buf.len) return;
        @memcpy(self.response_buf[self.response_len..][0..bytes.len], bytes);
        self.response_len += bytes.len;
    }

    fn respondFmt(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        var tmp: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.respond(s);
    }

    // -----------------------------------------------------------------
    // Accessors

    pub fn activeScreen(self: *Terminal) *Screen {
        return if (self.alt_active) &self.alternate else &self.primary;
    }

    fn activeScreenConst(self: *const Terminal) *const Screen {
        return if (self.alt_active) &self.alternate else &self.primary;
    }

    pub fn isAltScreen(self: *const Terminal) bool {
        return self.alt_active;
    }

    /// Cell of the active screen (ignores the viewport offset).
    pub fn getCell(self: *const Terminal, r: usize, c: usize) Cell {
        return self.activeScreenConst().rows[r].cells[c];
    }

    /// Row of the active screen (ignores the viewport offset).
    pub fn getRow(self: *const Terminal, r: usize) []const Cell {
        return self.activeScreenConst().rows[r].cells;
    }

    pub fn isWrapped(self: *const Terminal, r: usize) bool {
        return self.activeScreenConst().rows[r].wrapped;
    }

    pub fn scrollbackLen(self: *const Terminal) usize {
        return if (self.alt_active) 0 else self.scrollback.len;
    }

    pub fn getTitle(self: *const Terminal) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn getIconName(self: *const Terminal) []const u8 {
        return self.icon_buf[0..self.icon_len];
    }

    /// Raw OSC 7 URI, e.g. "file://host/home/user".
    pub fn getCwdUri(self: *const Terminal) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Path part of the OSC 7 URI (percent-escapes are left as-is).
    pub fn getCwd(self: *const Terminal) []const u8 {
        const uri = self.getCwdUri();
        const prefix = "file://";
        if (!std.mem.startsWith(u8, uri, prefix)) return uri;
        const rest = uri[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        return rest[slash..];
    }

    /// Returns and clears the title-changed flag.
    pub fn takeTitleChanged(self: *Terminal) bool {
        const v = self.title_changed;
        self.title_changed = false;
        return v;
    }

    /// Returns and clears the bell flag.
    pub fn takeBell(self: *Terminal) bool {
        const v = self.bell_pending;
        self.bell_pending = false;
        return v;
    }

    // -----------------------------------------------------------------
    // Damage tracking

    fn markDirty(self: *Terminal, r: usize) void {
        self.dirty[r] = true;
    }

    fn markRangeDirty(self: *Terminal, first: usize, last: usize) void {
        @memset(self.dirty[first .. last + 1], true);
    }

    fn markAllDirty(self: *Terminal) void {
        @memset(self.dirty, true);
        self.all_dirty = true;
    }

    /// Whether viewport row `vrow` must be repainted since `clearDamage`.
    pub fn isRowDirty(self: *const Terminal, vrow: usize) bool {
        if (self.all_dirty) return true;
        if (vrow < self.viewport_offset) return false;
        const r = vrow - self.viewport_offset;
        return r < self.rows and self.dirty[r];
    }

    fn cursorSnapshot(self: *const Terminal) CursorSnapshot {
        return .{
            .row = self.cursor.row,
            .col = self.cursor.col,
            .visible = self.cursor.visible,
            .style = self.cursor.style,
            .viewport_offset = self.viewport_offset,
        };
    }

    /// Cursor position/visibility/style changed since `clearDamage`. The old
    /// cursor location is `damage_cursor` (repaint that cell/row).
    pub fn cursorMoved(self: *const Terminal) bool {
        return !std.meta.eql(self.cursorSnapshot(), self.damage_cursor);
    }

    pub fn clearDamage(self: *Terminal) void {
        @memset(self.dirty, false);
        self.all_dirty = false;
        self.damage_cursor = self.cursorSnapshot();
    }

    // -----------------------------------------------------------------
    // Viewport (scrollback browsing)

    /// Scroll the view: positive `delta` moves up into history, negative
    /// moves back toward the live screen. No-op on the alternate screen.
    pub fn scrollViewport(self: *Terminal, delta: isize) void {
        if (self.alt_active) return;
        const max: isize = @intCast(self.scrollback.len);
        var off: isize = @intCast(self.viewport_offset);
        off = std.math.clamp(off + delta, 0, max);
        const new: usize = @intCast(off);
        if (new != self.viewport_offset) {
            self.viewport_offset = new;
            self.all_dirty = true;
        }
    }

    pub fn scrollViewportToBottom(self: *Terminal) void {
        if (self.viewport_offset != 0) {
            self.viewport_offset = 0;
            self.all_dirty = true;
        }
    }

    pub fn scrollViewportToTop(self: *Terminal) void {
        self.scrollViewport(@intCast(self.scrollback.len));
    }

    /// Cells to draw for viewport row `vrow` (0..rows). Scrollback lines may
    /// be shorter (or, after a resize, longer) than `cols`: draw
    /// min(len, cols) cells and treat the rest as blank.
    pub fn viewportRow(self: *const Terminal, vrow: usize) []const Cell {
        const line = self.lineAt(self.viewportToPos(vrow, 0).row) orelse return &.{};
        return line.cells;
    }

    pub fn viewportCell(self: *const Terminal, vrow: usize, col: usize) Cell {
        const cells = self.viewportRow(vrow);
        return if (col < cells.len) cells[col] else Cell.blank;
    }

    pub fn viewportToPos(self: *const Terminal, vrow: usize, col: usize) Pos {
        return .{ .row = @as(isize, @intCast(vrow)) - @as(isize, @intCast(self.viewport_offset)), .col = col };
    }

    /// Viewport row showing `pos`, or null if it is scrolled out of view.
    pub fn posToViewport(self: *const Terminal, pos: Pos) ?usize {
        const v = pos.row + @as(isize, @intCast(self.viewport_offset));
        if (v < 0 or v >= @as(isize, @intCast(self.rows))) return null;
        return @intCast(v);
    }

    /// Cursor location in the viewport, or null if scrolled out of view.
    pub fn cursorViewportPos(self: *const Terminal) ?struct { row: usize, col: usize } {
        const r = self.cursor.row + self.viewport_offset;
        if (r >= self.rows) return null;
        return .{ .row = r, .col = self.cursor.col };
    }

    // -----------------------------------------------------------------
    // Printing

    fn blank(self: *const Terminal) Cell {
        return .{ .bg = self.cursor.pen.bg };
    }

    fn print(self: *Terminal, cp_in: u21) void {
        var cp = cp_in;
        if (cp < 0x80) {
            const set = if (self.charset.single_shift) |ss| self.charset.g[ss] else self.charset.g[self.charset.gl];
            cp = mapCharset(set, cp);
        }
        self.charset.single_shift = null;
        const w = codepointWidth(cp);
        // Zero-width characters (combining marks, ZWJ, variation selectors)
        // are dropped: cells hold a single code point.
        if (w == 0) return;
        self.printWidth(cp, w);
        self.last_printed = cp;
    }

    /// Fast path for a run of printable ASCII (same semantics as calling
    /// `print` for each byte).
    fn printAscii(self: *Terminal, run: []const u8) void {
        if (run.len == 0) return;
        if (self.modes.insert or self.charset.single_shift != null or self.charset.g[self.charset.gl] != .ascii) {
            for (run) |b| self.print(b);
            return;
        }
        const cols = self.cols;
        const pen = self.cursor.pen;
        var i: usize = 0;
        while (i < run.len) {
            const s = self.activeScreen();
            if (self.cursor.pending_wrap) {
                if (self.modes.autowrap) {
                    s.rows[self.cursor.row].wrapped = true;
                    self.index();
                    self.cursor.col = 0;
                }
                self.cursor.pending_wrap = false;
            }
            const r = self.cursor.row;
            const c = self.cursor.col;
            const cells = s.rows[r].cells;
            const n = @min(cols - c, run.len - i);
            fixLeftEdge(cells, c);
            fixRightEdge(cells, c + n - 1);
            for (cells[c .. c + n], run[i .. i + n]) |*cell, b| {
                cell.* = .{ .cp = b, .fg = pen.fg, .bg = pen.bg, .attrs = pen.attrs };
            }
            self.markDirty(r);
            i += n;
            if (c + n >= cols) {
                self.cursor.col = cols - 1;
                if (self.modes.autowrap) {
                    self.cursor.pending_wrap = true;
                } else if (i < run.len) {
                    // Without autowrap the rest overwrites the last column.
                    cells[cols - 1].cp = run[run.len - 1];
                    i = run.len;
                }
            } else {
                self.cursor.col = c + n;
            }
        }
        self.last_printed = run[run.len - 1];
    }

    fn printWidth(self: *Terminal, cp: u21, w_in: u2) void {
        const cols = self.cols;
        const w: usize = if (w_in == 2 and cols < 2) 1 else w_in;
        const s = self.activeScreen();

        if (self.cursor.pending_wrap) {
            if (self.modes.autowrap) {
                s.rows[self.cursor.row].wrapped = true;
                self.index();
                self.cursor.col = 0;
            }
            self.cursor.pending_wrap = false;
        }

        if (w == 2 and self.cursor.col == cols - 1) {
            if (self.modes.autowrap) {
                // Not enough room: leave a wrap spacer and continue on the next line.
                const cells = s.rows[self.cursor.row].cells;
                breakWide(cells, cols - 1);
                cells[cols - 1] = .{ .attrs = .{ .wide_spacer = true } };
                s.rows[self.cursor.row].wrapped = true;
                self.markDirty(self.cursor.row);
                self.index();
                self.cursor.col = 0;
            } else {
                self.cursor.col = cols - 2;
            }
        }

        const r = self.cursor.row;
        const c = self.cursor.col;
        const cells = s.rows[r].cells;
        if (self.modes.insert) self.shiftRight(cells, c, w);

        breakWide(cells, c);
        if (w == 2) breakWide(cells, c + 1);
        const pen = self.cursor.pen;
        var attrs = pen.attrs;
        attrs.wide = w == 2;
        attrs.wide_spacer = false;
        cells[c] = .{ .cp = cp, .fg = pen.fg, .bg = pen.bg, .attrs = attrs };
        if (w == 2) {
            var sa = pen.attrs;
            sa.wide = false;
            sa.wide_spacer = true;
            cells[c + 1] = .{ .cp = ' ', .fg = pen.fg, .bg = pen.bg, .attrs = sa };
        }
        self.markDirty(r);

        if (c + w >= cols) {
            self.cursor.col = cols - 1;
            self.cursor.pending_wrap = self.modes.autowrap;
        } else {
            self.cursor.col = c + w;
        }
    }

    /// Insert `n` blank cells at `col`, shifting the rest right (ICH / IRM).
    fn shiftRight(self: *Terminal, cells: []Cell, col: usize, n_in: usize) void {
        const cols = cells.len;
        const n = @min(n_in, cols - col);
        fixLeftEdge(cells, col);
        if (n < cols - col) std.mem.copyBackwards(Cell, cells[col + n ..], cells[col .. cols - n]);
        @memset(cells[col .. col + n], self.blank());
        if (cells[cols - 1].attrs.wide) cells[cols - 1] = .{ .fg = cells[cols - 1].fg, .bg = cells[cols - 1].bg };
    }

    // -----------------------------------------------------------------
    // C0 controls

    fn execute(self: *Terminal, c: u8) void {
        switch (c) {
            0x07 => self.ringBell(),
            0x08 => { // BS
                if (self.cursor.col > 0) self.cursor.col -= 1;
                self.cursor.pending_wrap = false;
            },
            0x09 => self.tabForward(1),
            0x0a, 0x0b, 0x0c => { // LF, VT, FF
                self.index();
                if (self.modes.linefeed_newline) self.cursor.col = 0;
                self.cursor.pending_wrap = false;
            },
            0x0d => { // CR
                self.cursor.col = 0;
                self.cursor.pending_wrap = false;
            },
            0x0e => self.charset.gl = 1, // SO
            0x0f => self.charset.gl = 0, // SI
            else => {},
        }
    }

    fn ringBell(self: *Terminal) void {
        self.bell_count +%= 1;
        self.bell_pending = true;
        if (self.on_bell) |cb| cb.func(cb.ctx);
    }

    // -----------------------------------------------------------------
    // Scrolling

    /// Move down one line, scrolling the region if at its bottom margin.
    fn index(self: *Terminal) void {
        if (self.cursor.row == self.scroll_bottom) {
            self.scrollUp(self.scroll_top, self.scroll_bottom, 1, true);
        } else if (self.cursor.row + 1 < self.rows) {
            self.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *Terminal) void {
        if (self.cursor.row == self.scroll_top) {
            self.scrollDown(self.scroll_top, self.scroll_bottom, 1);
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
    }

    /// Scroll rows [top, bot] up by n. Lines leaving the top of the primary
    /// screen go to scrollback when `save` and the region starts at row 0.
    fn scrollUp(self: *Terminal, top: usize, bot: usize, n_in: usize, save: bool) void {
        const height = bot - top + 1;
        const n = @min(n_in, height);
        if (n == 0) return;
        const s = self.activeScreen();
        if (save and !self.alt_active and top == 0 and self.scrollback.cap > 0) {
            for (0..n) |i| self.scrollback.push(self.allocator, s.rows[i].cells, s.rows[i].wrapped);
            if (self.viewport_offset > 0) {
                // Keep the history the user is looking at in place.
                self.viewport_offset = @min(self.viewport_offset + n, self.scrollback.len);
                self.all_dirty = true;
            }
        }
        std.mem.rotate(Row, s.rows[top .. bot + 1], n);
        const b = self.blank();
        for (bot + 1 - n..bot + 1) |r| s.clearRow(r, b);
        if (top > 0) s.rows[top - 1].wrapped = false;
        self.markRangeDirty(top, bot);
    }

    fn scrollDown(self: *Terminal, top: usize, bot: usize, n_in: usize) void {
        const height = bot - top + 1;
        const n = @min(n_in, height);
        if (n == 0) return;
        const s = self.activeScreen();
        std.mem.rotate(Row, s.rows[top .. bot + 1], height - n);
        const b = self.blank();
        for (top..top + n) |r| s.clearRow(r, b);
        s.rows[bot].wrapped = false;
        if (top > 0) s.rows[top - 1].wrapped = false;
        self.markRangeDirty(top, bot);
    }

    // -----------------------------------------------------------------
    // Cursor movement

    fn setCursorPos(self: *Terminal, r: usize, c: usize) void {
        self.cursor.row = @min(r, self.rows - 1);
        self.cursor.col = @min(c, self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    /// CUP with 1-based, origin-relative coordinates.
    fn cursorPosition(self: *Terminal, row1: usize, col1: usize) void {
        var r = row1 -| 1;
        if (self.modes.origin) {
            r = @min(r + self.scroll_top, self.scroll_bottom);
        }
        self.setCursorPos(r, col1 -| 1);
    }

    fn cursorUp(self: *Terminal, n: usize) void {
        const lim = if (self.cursor.row >= self.scroll_top) self.scroll_top else 0;
        self.cursor.row = if (self.cursor.row >= lim + n) self.cursor.row - n else lim;
        self.cursor.pending_wrap = false;
    }

    fn cursorDown(self: *Terminal, n: usize) void {
        const lim = if (self.cursor.row <= self.scroll_bottom) self.scroll_bottom else self.rows - 1;
        self.cursor.row = @min(self.cursor.row + n, lim);
        self.cursor.pending_wrap = false;
    }

    fn cursorForward(self: *Terminal, n: usize) void {
        self.cursor.col = @min(self.cursor.col + n, self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    fn cursorBack(self: *Terminal, n: usize) void {
        self.cursor.col -|= n;
        self.cursor.pending_wrap = false;
    }

    fn tabForward(self: *Terminal, n: usize) void {
        var i: usize = 0;
        while (i < n and self.cursor.col < self.cols - 1) : (i += 1) {
            self.cursor.col += 1;
            while (self.cursor.col < self.cols - 1 and !self.tabstops[self.cursor.col]) self.cursor.col += 1;
        }
    }

    fn tabBackward(self: *Terminal, n: usize) void {
        var i: usize = 0;
        while (i < n and self.cursor.col > 0) : (i += 1) {
            self.cursor.col -= 1;
            while (self.cursor.col > 0 and !self.tabstops[self.cursor.col]) self.cursor.col -= 1;
        }
        self.cursor.pending_wrap = false;
    }

    fn saveCursor(self: *Terminal) void {
        const sc: SavedCursor = .{
            .row = self.cursor.row,
            .col = self.cursor.col,
            .pending_wrap = self.cursor.pending_wrap,
            .pen = self.cursor.pen,
            .origin = self.modes.origin,
            .charset = self.charset,
        };
        if (self.alt_active) self.saved_alt = sc else self.saved_primary = sc;
    }

    fn restoreCursor(self: *Terminal) void {
        const sc = (if (self.alt_active) self.saved_alt else self.saved_primary) orelse SavedCursor{};
        self.cursor.row = @min(sc.row, self.rows - 1);
        self.cursor.col = @min(sc.col, self.cols - 1);
        self.cursor.pending_wrap = sc.pending_wrap and self.cursor.col == self.cols - 1;
        self.cursor.pen = sc.pen;
        self.modes.origin = sc.origin;
        self.charset = sc.charset;
    }

    // -----------------------------------------------------------------
    // Editing

    fn eraseCells(self: *Terminal, r: usize, c0: usize, c1: usize) void {
        if (c0 >= c1) return;
        const cells = self.activeScreen().rows[r].cells;
        fixLeftEdge(cells, c0);
        fixRightEdge(cells, c1 - 1);
        @memset(cells[c0..c1], self.blank());
        self.markDirty(r);
    }

    fn eraseDisplay(self: *Terminal, mode: u16) void {
        const s = self.activeScreen();
        const b = self.blank();
        switch (mode) {
            0 => {
                self.eraseCells(self.cursor.row, self.cursor.col, self.cols);
                s.rows[self.cursor.row].wrapped = false;
                for (self.cursor.row + 1..self.rows) |r| s.clearRow(r, b);
                self.markRangeDirty(self.cursor.row, self.rows - 1);
            },
            1 => {
                for (0..self.cursor.row) |r| s.clearRow(r, b);
                self.eraseCells(self.cursor.row, 0, self.cursor.col + 1);
                self.markRangeDirty(0, self.cursor.row);
            },
            2 => {
                s.clear(b);
                self.markRangeDirty(0, self.rows - 1);
            },
            3 => {
                if (!self.alt_active) {
                    self.scrollback.clear(self.allocator);
                    self.viewport_offset = 0;
                    self.markAllDirty();
                }
            },
            else => return,
        }
        self.cursor.pending_wrap = false;
    }

    fn eraseLine(self: *Terminal, mode: u16) void {
        const r = self.cursor.row;
        switch (mode) {
            0 => {
                self.eraseCells(r, self.cursor.col, self.cols);
                self.activeScreen().rows[r].wrapped = false;
            },
            1 => self.eraseCells(r, 0, self.cursor.col + 1),
            2 => {
                self.eraseCells(r, 0, self.cols);
                self.activeScreen().rows[r].wrapped = false;
            },
            else => return,
        }
        self.cursor.pending_wrap = false;
    }

    fn insertChars(self: *Terminal, n: usize) void {
        const r = self.cursor.row;
        self.shiftRight(self.activeScreen().rows[r].cells, self.cursor.col, n);
        self.cursor.pending_wrap = false;
        self.markDirty(r);
    }

    fn deleteChars(self: *Terminal, n_in: usize) void {
        const r = self.cursor.row;
        const col = self.cursor.col;
        const cells = self.activeScreen().rows[r].cells;
        const cols = self.cols;
        const n = @min(n_in, cols - col);
        fixLeftEdge(cells, col);
        if (col + n < cols) fixLeftEdge(cells, col + n);
        // A wrap spacer must not move away from the last column.
        if (cells[cols - 1].attrs.wide_spacer and !(cols > 1 and cells[cols - 2].attrs.wide))
            cells[cols - 1] = .{ .fg = cells[cols - 1].fg, .bg = cells[cols - 1].bg };
        std.mem.copyForwards(Cell, cells[col .. cols - n], cells[col + n .. cols]);
        @memset(cells[cols - n .. cols], self.blank());
        self.cursor.pending_wrap = false;
        self.markDirty(r);
    }

    fn insertLines(self: *Terminal, n: usize) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollDown(self.cursor.row, self.scroll_bottom, n);
        self.cursor.col = 0;
        self.cursor.pending_wrap = false;
    }

    fn deleteLines(self: *Terminal, n: usize) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollUp(self.cursor.row, self.scroll_bottom, n, false);
        self.cursor.col = 0;
        self.cursor.pending_wrap = false;
    }

    fn setScrollRegion(self: *Terminal, top1: usize, bot1: usize) void {
        const top = top1 -| 1;
        const bot = @min(if (bot1 == 0) self.rows else bot1, self.rows) -| 1;
        if (top >= bot) return;
        self.scroll_top = top;
        self.scroll_bottom = bot;
        self.cursorPosition(1, 1);
    }

    fn decaln(self: *Terminal) void {
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        const s = self.activeScreen();
        for (0..self.rows) |r| s.clearRow(r, .{ .cp = 'E' });
        self.setCursorPos(0, 0);
        self.markAllDirty();
    }

    // -----------------------------------------------------------------
    // Screens and resets

    fn enterAltScreen(self: *Terminal, clear: bool) void {
        if (!self.alt_active) {
            self.alt_active = true;
            self.viewport_offset = 0;
        }
        if (clear) self.alternate.clear(.{ .bg = self.cursor.pen.bg });
        self.markAllDirty();
    }

    fn leaveAltScreen(self: *Terminal) void {
        if (!self.alt_active) return;
        self.alt_active = false;
        self.markAllDirty();
    }

    fn softReset(self: *Terminal) void {
        self.cursor.visible = true;
        self.cursor.pen = .{};
        self.cursor.pending_wrap = false;
        self.modes.insert = false;
        self.modes.origin = false;
        self.modes.autowrap = true;
        self.modes.app_cursor = false;
        self.modes.app_keypad = false;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.charset = .{};
        if (self.alt_active) self.saved_alt = null else self.saved_primary = null;
    }

    /// RIS: full reset (the scrollback is kept).
    pub fn fullReset(self: *Terminal) void {
        self.alt_active = false;
        self.primary.clear(.{});
        self.alternate.clear(.{});
        self.cursor = .{};
        self.saved_primary = null;
        self.saved_alt = null;
        self.modes = .{};
        self.charset = .{};
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        resetTabs(self.tabstops, 0);
        self.last_printed = null;
        self.viewport_offset = 0;
        self.markAllDirty();
    }

    /// Reset requested by the user/app (also resets the parser).
    pub fn reset(self: *Terminal) void {
        self.parser.reset();
        self.fullReset();
    }

    // -----------------------------------------------------------------
    // ESC dispatch

    fn escDispatch(self: *Terminal, esc: Esc) void {
        if (esc.intermediates.len > 1) return;
        switch (esc.intermediate()) {
            0 => switch (esc.final) {
                '7' => self.saveCursor(),
                '8' => self.restoreCursor(),
                'D' => {
                    self.index();
                    self.cursor.pending_wrap = false;
                },
                'E' => {
                    self.index();
                    self.cursor.col = 0;
                    self.cursor.pending_wrap = false;
                },
                'H' => self.tabstops[self.cursor.col] = true,
                'M' => {
                    self.reverseIndex();
                    self.cursor.pending_wrap = false;
                },
                'c' => self.fullReset(),
                '=' => self.modes.app_keypad = true,
                '>' => self.modes.app_keypad = false,
                'N' => self.charset.single_shift = 2,
                'O' => self.charset.single_shift = 3,
                'n' => self.charset.gl = 2,
                'o' => self.charset.gl = 3,
                'Z' => self.respond("\x1b[?62;22c"),
                else => {},
            },
            '(', ')', '*', '+' => {
                const idx: usize = switch (esc.intermediate()) {
                    '(' => 0,
                    ')' => 1,
                    '*' => 2,
                    else => 3,
                };
                self.charset.g[idx] = switch (esc.final) {
                    '0' => .dec_special,
                    'A' => .uk,
                    else => .ascii,
                };
            },
            '#' => if (esc.final == '8') self.decaln(),
            else => {},
        }
    }

    // -----------------------------------------------------------------
    // CSI dispatch

    fn csiDispatch(self: *Terminal, csi: Csi) void {
        if (csi.intermediates.len > 1) return;
        const n1: usize = csi.get(0, 1);
        switch (csi.intermediate()) {
            0 => {},
            ' ' => {
                if (csi.final == 'q' and csi.private == 0) self.setCursorStyle(csi.raw(0));
                return;
            },
            '!' => {
                if (csi.final == 'p' and csi.private == 0) self.softReset();
                return;
            },
            '$' => {
                if (csi.final == 'p') self.reportMode(csi);
                return;
            },
            else => return,
        }
        switch (csi.private) {
            0 => {},
            '?' => {
                switch (csi.final) {
                    'h' => self.setModes(csi, true),
                    'l' => self.setModes(csi, false),
                    'J' => self.eraseDisplay(csi.raw(0)),
                    'K' => self.eraseLine(csi.raw(0)),
                    'n' => self.deviceStatusPrivate(csi.raw(0)),
                    else => {},
                }
                return;
            },
            '>' => {
                switch (csi.final) {
                    'c' => if (csi.raw(0) == 0) self.respond("\x1b[>1;10;0c"),
                    'q' => if (csi.raw(0) == 0) self.respond("\x1bP>|zen-vt 1.0\x1b\\"),
                    else => {},
                }
                return;
            },
            else => return,
        }
        switch (csi.final) {
            '@' => self.insertChars(n1),
            'A' => self.cursorUp(n1),
            'B', 'e' => self.cursorDown(n1),
            'C', 'a' => self.cursorForward(n1),
            'D' => self.cursorBack(n1),
            'E' => {
                self.cursorDown(n1);
                self.cursor.col = 0;
            },
            'F' => {
                self.cursorUp(n1);
                self.cursor.col = 0;
            },
            'G', '`' => self.setCursorPos(self.cursor.row, n1 - 1),
            'H', 'f' => self.cursorPosition(n1, csi.get(1, 1)),
            'I' => self.tabForward(n1),
            'J' => self.eraseDisplay(csi.raw(0)),
            'K' => self.eraseLine(csi.raw(0)),
            'L' => self.insertLines(n1),
            'M' => self.deleteLines(n1),
            'P' => self.deleteChars(n1),
            'S' => if (csi.params.len <= 1) self.scrollUp(self.scroll_top, self.scroll_bottom, n1, true),
            'T' => if (csi.params.len <= 1) self.scrollDown(self.scroll_top, self.scroll_bottom, n1),
            'X' => self.eraseCells(self.cursor.row, self.cursor.col, @min(self.cursor.col + n1, self.cols)),
            'Z' => self.tabBackward(n1),
            'b' => if (self.last_printed) |cp| {
                const w = codepointWidth(cp);
                if (w > 0) {
                    const count = @min(n1, self.cols * self.rows);
                    for (0..count) |_| self.printWidth(cp, w);
                }
            },
            'c' => if (csi.raw(0) == 0) self.respond("\x1b[?62;22c"),
            'd' => {
                const col = self.cursor.col;
                self.cursorPosition(n1, 1);
                self.cursor.col = col;
            },
            'g' => switch (csi.raw(0)) {
                0 => self.tabstops[self.cursor.col] = false,
                3 => @memset(self.tabstops, false),
                else => {},
            },
            'h' => self.setModes(csi, true),
            'l' => self.setModes(csi, false),
            'm' => self.sgr(csi),
            'n' => self.deviceStatus(csi.raw(0)),
            'r' => self.setScrollRegion(csi.get(0, 1), csi.raw(1)),
            's' => if (csi.params.len == 0) self.saveCursor(),
            't' => self.windowOp(csi),
            'u' => if (csi.params.len == 0) self.restoreCursor(),
            else => {},
        }
    }

    fn setCursorStyle(self: *Terminal, n: u16) void {
        self.cursor.style = switch (n) {
            0, 1 => .blinking_block,
            2 => .steady_block,
            3 => .blinking_underline,
            4 => .steady_underline,
            5 => .blinking_bar,
            6 => .steady_bar,
            else => return,
        };
    }

    fn setCursorBlink(self: *Terminal, on: bool) void {
        self.cursor.style = switch (self.cursor.style) {
            .blinking_block, .steady_block => if (on) .blinking_block else .steady_block,
            .blinking_underline, .steady_underline => if (on) .blinking_underline else .steady_underline,
            .blinking_bar, .steady_bar => if (on) .blinking_bar else .steady_bar,
        };
    }

    fn setMouseTracking(self: *Terminal, mode: MouseTracking, on: bool) void {
        if (on) {
            self.modes.mouse_tracking = mode;
        } else if (self.modes.mouse_tracking == mode) {
            self.modes.mouse_tracking = .none;
        }
    }

    fn setMouseEncoding(self: *Terminal, enc: MouseEncoding, on: bool) void {
        if (on) {
            self.modes.mouse_encoding = enc;
        } else if (self.modes.mouse_encoding == enc) {
            self.modes.mouse_encoding = .default;
        }
    }

    fn setModes(self: *Terminal, csi: Csi, on: bool) void {
        for (csi.params) |p| {
            if (csi.private == '?') self.setPrivateMode(p, on) else self.setAnsiMode(p, on);
        }
    }

    fn setAnsiMode(self: *Terminal, p: u16, on: bool) void {
        switch (p) {
            4 => self.modes.insert = on,
            20 => self.modes.linefeed_newline = on,
            else => {},
        }
    }

    fn setPrivateMode(self: *Terminal, p: u16, on: bool) void {
        switch (p) {
            1 => self.modes.app_cursor = on,
            5 => if (self.modes.reverse_video != on) {
                self.modes.reverse_video = on;
                self.markAllDirty();
            },
            6 => {
                self.modes.origin = on;
                self.cursorPosition(1, 1);
            },
            7 => {
                self.modes.autowrap = on;
                if (!on) self.cursor.pending_wrap = false;
            },
            9 => self.setMouseTracking(.x10, on),
            12 => self.setCursorBlink(on),
            25 => self.cursor.visible = on,
            47 => if (on) self.enterAltScreen(false) else self.leaveAltScreen(),
            66 => self.modes.app_keypad = on,
            1000 => self.setMouseTracking(.normal, on),
            1002 => self.setMouseTracking(.button_event, on),
            1003 => self.setMouseTracking(.any_event, on),
            1004 => self.modes.focus_events = on,
            1005 => self.setMouseEncoding(.utf8, on),
            1006 => self.setMouseEncoding(.sgr, on),
            1007 => self.modes.alternate_scroll = on,
            1015 => self.setMouseEncoding(.urxvt, on),
            1047 => if (on) {
                self.enterAltScreen(true);
            } else {
                if (self.alt_active) self.alternate.clear(.{});
                self.leaveAltScreen();
            },
            1048 => if (on) self.saveCursor() else self.restoreCursor(),
            1049 => if (on) {
                if (!self.alt_active) self.saveCursor();
                self.enterAltScreen(true);
            } else if (self.alt_active) {
                self.leaveAltScreen();
                self.restoreCursor();
            },
            2004 => self.modes.bracketed_paste = on,
            2026 => self.modes.synchronized_output = on,
            else => {},
        }
    }

    /// 1 = set, 2 = reset, 0 = not recognized.
    fn privateModeState(self: *const Terminal, p: u16) u8 {
        const m = self.modes;
        const v: bool = switch (p) {
            1 => m.app_cursor,
            5 => m.reverse_video,
            6 => m.origin,
            7 => m.autowrap,
            9 => m.mouse_tracking == .x10,
            12 => self.cursor.style.isBlinking(),
            25 => self.cursor.visible,
            47, 1047, 1049 => self.alt_active,
            66 => m.app_keypad,
            1000 => m.mouse_tracking == .normal,
            1002 => m.mouse_tracking == .button_event,
            1003 => m.mouse_tracking == .any_event,
            1004 => m.focus_events,
            1005 => m.mouse_encoding == .utf8,
            1006 => m.mouse_encoding == .sgr,
            1007 => m.alternate_scroll,
            1015 => m.mouse_encoding == .urxvt,
            2004 => m.bracketed_paste,
            2026 => m.synchronized_output,
            else => return 0,
        };
        return if (v) 1 else 2;
    }

    /// DECRQM: CSI [?] Ps $ p  ->  CSI [?] Ps ; Pm $ y
    fn reportMode(self: *Terminal, csi: Csi) void {
        const p = csi.raw(0);
        if (csi.private == '?') {
            self.respondFmt("\x1b[?{d};{d}$y", .{ p, self.privateModeState(p) });
        } else if (csi.private == 0) {
            const state: u8 = switch (p) {
                4 => if (self.modes.insert) 1 else 2,
                20 => if (self.modes.linefeed_newline) 1 else 2,
                else => 0,
            };
            self.respondFmt("\x1b[{d};{d}$y", .{ p, state });
        }
    }

    fn cursorReportRow(self: *const Terminal) usize {
        return if (self.modes.origin) (self.cursor.row -| self.scroll_top) + 1 else self.cursor.row + 1;
    }

    fn deviceStatus(self: *Terminal, p: u16) void {
        switch (p) {
            5 => self.respond("\x1b[0n"),
            6 => self.respondFmt("\x1b[{d};{d}R", .{ self.cursorReportRow(), self.cursor.col + 1 }),
            else => {},
        }
    }

    fn deviceStatusPrivate(self: *Terminal, p: u16) void {
        switch (p) {
            6 => self.respondFmt("\x1b[?{d};{d}R", .{ self.cursorReportRow(), self.cursor.col + 1 }),
            15 => self.respond("\x1b[?13n"),
            25 => self.respond("\x1b[?20n"),
            26 => self.respond("\x1b[?27;1;0;0n"),
            else => {},
        }
    }

    fn windowOp(self: *Terminal, csi: Csi) void {
        switch (csi.raw(0)) {
            18 => self.respondFmt("\x1b[8;{d};{d}t", .{ self.rows, self.cols }),
            else => {}, // window manipulation, title stack: ignored
        }
    }

    // -----------------------------------------------------------------
    // SGR

    fn sgr(self: *Terminal, csi: Csi) void {
        const p = csi.params;
        const pen = &self.cursor.pen;
        if (p.len == 0) {
            pen.* = .{};
            return;
        }
        var i: usize = 0;
        while (i < p.len) {
            var end = i + 1;
            while (end < p.len and csi.isSub(end)) end += 1;
            var next = end;
            switch (p[i]) {
                0 => pen.* = .{},
                1 => pen.attrs.bold = true,
                2 => pen.attrs.dim = true,
                3 => pen.attrs.italic = true,
                4 => pen.attrs.underline = if (end > i + 1) p[i + 1] != 0 else true,
                5, 6 => pen.attrs.blink = true,
                7 => pen.attrs.inverse = true,
                8 => pen.attrs.hidden = true,
                9 => pen.attrs.strike = true,
                21 => pen.attrs.underline = true,
                22 => {
                    pen.attrs.bold = false;
                    pen.attrs.dim = false;
                },
                23 => pen.attrs.italic = false,
                24 => pen.attrs.underline = false,
                25 => pen.attrs.blink = false,
                27 => pen.attrs.inverse = false,
                28 => pen.attrs.hidden = false,
                29 => pen.attrs.strike = false,
                30...37 => pen.fg = .{ .indexed = @intCast(p[i] - 30) },
                38, 48, 58 => {
                    const r = extColor(csi, i, end);
                    next = r.next;
                    if (r.color) |c| switch (p[i]) {
                        38 => pen.fg = c,
                        48 => pen.bg = c,
                        else => {}, // underline color: ignored
                    };
                },
                39 => pen.fg = .default,
                40...47 => pen.bg = .{ .indexed = @intCast(p[i] - 40) },
                49 => pen.bg = .default,
                90...97 => pen.fg = .{ .indexed = @intCast(p[i] - 90 + 8) },
                100...107 => pen.bg = .{ .indexed = @intCast(p[i] - 100 + 8) },
                else => {},
            }
            i = @max(next, i + 1);
        }
    }

    const ExtColor = struct { color: ?Color, next: usize };

    /// Parse 38/48/58 extended colors in both `38;5;n` / `38;2;r;g;b` and
    /// colon `38:5:n` / `38:2:[cs]:r:g:b` forms.
    fn extColor(csi: Csi, i: usize, end: usize) ExtColor {
        const p = csi.params;
        if (end > i + 1) {
            const sub = p[i + 1 .. end];
            switch (sub[0]) {
                5 => if (sub.len >= 2) return .{ .color = .{ .indexed = clamp8(sub[1]) }, .next = end },
                2 => {
                    if (sub.len >= 5) return .{ .color = .{ .rgb = .{ clamp8(sub[2]), clamp8(sub[3]), clamp8(sub[4]) } }, .next = end };
                    if (sub.len == 4) return .{ .color = .{ .rgb = .{ clamp8(sub[1]), clamp8(sub[2]), clamp8(sub[3]) } }, .next = end };
                },
                else => {},
            }
            return .{ .color = null, .next = end };
        }
        if (i + 1 >= p.len) return .{ .color = null, .next = p.len };
        switch (p[i + 1]) {
            5 => {
                if (i + 2 < p.len) return .{ .color = .{ .indexed = clamp8(p[i + 2]) }, .next = i + 3 };
                return .{ .color = null, .next = p.len };
            },
            2 => {
                if (i + 4 < p.len) return .{ .color = .{ .rgb = .{ clamp8(p[i + 2]), clamp8(p[i + 3]), clamp8(p[i + 4]) } }, .next = i + 5 };
                return .{ .color = null, .next = p.len };
            },
            else => return .{ .color = null, .next = i + 2 },
        }
    }

    // -----------------------------------------------------------------
    // OSC

    fn oscDispatch(self: *Terminal, data: []const u8, term: OscTerminator) void {
        var i: usize = 0;
        var ps: u32 = 0;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            ps = @min(ps * 10 + (data[i] - '0'), 100000);
        }
        if (i == 0) return;
        const rest: []const u8 = if (i == data.len) "" else if (data[i] == ';') data[i + 1 ..] else return;
        switch (ps) {
            0 => {
                self.title_len = storeText(&self.title_buf, rest);
                self.icon_len = storeText(&self.icon_buf, rest);
                self.title_changed = true;
            },
            1 => {
                self.icon_len = storeText(&self.icon_buf, rest);
                self.title_changed = true;
            },
            2 => {
                self.title_len = storeText(&self.title_buf, rest);
                self.title_changed = true;
            },
            4 => self.oscPaletteQuery(rest, term),
            7 => {
                self.cwd_len = storeText(&self.cwd_buf, rest);
                self.cwd_changed = true;
            },
            10, 11, 12 => self.oscDynamicColorQuery(ps, rest, term),
            // 8 (hyperlinks), 52 (clipboard), 104/110-112 (color resets),
            // 133 (shell integration), ...: ignored.
            else => {},
        }
    }

    /// Copy text into a fixed buffer, truncating at a UTF-8 boundary and
    /// replacing bytes of invalid UTF-8 with '?'.
    fn storeText(buf: []u8, text: []const u8) usize {
        var n = @min(text.len, buf.len);
        if (n < text.len) {
            while (n > 0 and (text[n] & 0xc0) == 0x80) n -= 1;
        }
        const src = text[0..n];
        if (std.unicode.utf8ValidateSlice(src)) {
            @memcpy(buf[0..n], src);
        } else {
            for (src, 0..) |b, k| buf[k] = if (b >= 0x80) '?' else b;
        }
        return n;
    }

    fn respondColor(self: *Terminal, prefix: []const u8, rgb: palette.Rgb, term: OscTerminator) void {
        self.respondFmt("\x1b]{s};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
            prefix,                                 rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2],
            if (term == .bel) "\x07" else "\x1b\\",
        });
    }

    /// OSC 4 ; index ; ? [; index ; ? ...]  (color setting is ignored)
    fn oscPaletteQuery(self: *Terminal, rest: []const u8, term: OscTerminator) void {
        var it = std.mem.splitScalar(u8, rest, ';');
        while (it.next()) |idx_s| {
            const spec = it.next() orelse return;
            if (!std.mem.eql(u8, spec, "?")) continue;
            const idx = std.fmt.parseInt(u8, idx_s, 10) catch continue;
            var prefix: [8]u8 = undefined;
            const pre = std.fmt.bufPrint(&prefix, "4;{d}", .{idx}) catch continue;
            self.respondColor(pre, self.theme.paletteColor(idx), term);
        }
    }

    /// OSC 10/11/12 ; ? [; ? ...]  (setting is ignored)
    fn oscDynamicColorQuery(self: *Terminal, first: u32, rest: []const u8, term: OscTerminator) void {
        var it = std.mem.splitScalar(u8, rest, ';');
        var ps = first;
        while (it.next()) |spec| : (ps += 1) {
            if (ps > 12) return;
            if (!std.mem.eql(u8, spec, "?")) continue;
            const rgb = switch (ps) {
                10 => self.theme.fg,
                11 => self.theme.bg,
                else => self.theme.cursor,
            };
            var prefix: [4]u8 = undefined;
            const pre = std.fmt.bufPrint(&prefix, "{d}", .{ps}) catch return;
            self.respondColor(pre, rgb, term);
        }
    }

    // -----------------------------------------------------------------
    // Input encoding (uses current modes)

    pub fn keyModes(self: *const Terminal) input.KeyModes {
        return .{
            .app_cursor = self.modes.app_cursor,
            .app_keypad = self.modes.app_keypad,
            .linefeed_newline = self.modes.linefeed_newline,
        };
    }

    /// Encode a key press; `out` should hold at least 32 bytes.
    pub fn encodeKey(self: *const Terminal, key: input.Key, mods: input.Mods, out: []u8) []const u8 {
        return input.encodeKey(key, mods, self.keyModes(), out);
    }

    /// Encode pasted text (bracketed if mode 2004 is on). Caller frees.
    pub fn encodePaste(self: *const Terminal, allocator: Allocator, text: []const u8) ![]u8 {
        return input.encodePaste(allocator, text, self.modes.bracketed_paste);
    }

    /// Encode a mouse event per the enabled tracking mode (empty if the app
    /// did not ask for it; then the app should do selection/scrolling).
    pub fn encodeMouse(self: *const Terminal, ev: input.MouseEvent, out: []u8) []const u8 {
        return input.encodeMouse(ev, self.modes.mouse_tracking, self.modes.mouse_encoding, out);
    }

    /// Focus in/out report, only if mode 1004 is enabled.
    pub fn encodeFocus(self: *const Terminal, focused: bool, out: []u8) []const u8 {
        if (!self.modes.focus_events) return out[0..0];
        return input.encodeFocus(focused, out);
    }

    pub fn mouseReporting(self: *const Terminal) bool {
        return self.modes.mouse_tracking != .none;
    }

    // -----------------------------------------------------------------
    // Selection / text extraction

    /// Line at `r` (see `Pos`), or null when out of range.
    pub fn lineAt(self: *const Terminal, r: isize) ?LineRef {
        if (r >= 0) {
            const ur: usize = @intCast(r);
            if (ur >= self.rows) return null;
            const row = self.activeScreenConst().rows[ur];
            return .{ .cells = row.cells, .wrapped = row.wrapped };
        }
        const back: usize = @intCast(-r);
        const sb_len = self.scrollbackLen();
        if (back > sb_len) return null;
        const line = self.scrollback.get(sb_len - back);
        return .{ .cells = line.cells(), .wrapped = line.wrapped };
    }

    /// Topmost addressable row (negative when there is scrollback).
    pub fn firstRow(self: *const Terminal) isize {
        return -@as(isize, @intCast(self.scrollbackLen()));
    }

    /// Text of the inclusive range between two positions (in either order),
    /// as UTF-8. Soft-wrapped lines are joined; other line ends become '\n';
    /// trailing blanks of each line are trimmed. Caller frees.
    pub fn textInRange(self: *const Terminal, allocator: Allocator, a: Pos, b: Pos) ![]u8 {
        const start = if (b.lessThan(a)) b else a;
        const end = if (b.lessThan(a)) a else b;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var r = @max(start.row, self.firstRow());
        const last_row = @min(end.row, @as(isize, @intCast(self.rows)) - 1);
        while (r <= last_row) : (r += 1) {
            const line = self.lineAt(r) orelse continue;
            const c0 = if (r == start.row) start.col else 0;
            const c1 = if (r == end.row) @min(end.col + 1, line.cells.len) else line.cells.len;
            const line_start = out.items.len;
            var c = c0;
            while (c < c1) : (c += 1) {
                const cl = line.cells[c];
                if (cl.attrs.wide_spacer) continue;
                const cp: u21 = if (cl.cp == 0) ' ' else cl.cp;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
                try out.appendSlice(allocator, tmp[0..n]);
            }
            const continues = line.wrapped and r != end.row;
            if (!continues) {
                // Trim trailing blanks of this line.
                var len = out.items.len;
                while (len > line_start and out.items[len - 1] == ' ') len -= 1;
                out.shrinkRetainingCapacity(len);
                if (r != last_row) try out.append(allocator, '\n');
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn lineWidth(self: *const Terminal, line: LineRef) usize {
        return @max(line.cells.len, self.cols);
    }

    fn cellAtPos(self: *const Terminal, p: Pos) Cell {
        const line = self.lineAt(p.row) orelse return Cell.blank;
        return if (p.col < line.cells.len) line.cells[p.col] else Cell.blank;
    }

    fn prevPos(self: *const Terminal, p: Pos) ?Pos {
        if (p.col > 0) return .{ .row = p.row, .col = p.col - 1 };
        const prev = self.lineAt(p.row - 1) orelse return null;
        if (!prev.wrapped) return null;
        return .{ .row = p.row - 1, .col = self.lineWidth(prev) - 1 };
    }

    fn nextPos(self: *const Terminal, p: Pos) ?Pos {
        const line = self.lineAt(p.row) orelse return null;
        if (p.col + 1 < self.lineWidth(line)) return .{ .row = p.row, .col = p.col + 1 };
        if (!line.wrapped) return null;
        _ = self.lineAt(p.row + 1) orelse return null;
        return .{ .row = p.row + 1, .col = 0 };
    }

    /// Character class for double-click word selection: 0 = blank,
    /// 1 = word character, otherwise the code point itself (so runs of the
    /// same punctuation select together).
    fn charClass(cp: u21) u21 {
        if (cp == ' ' or cp == 0 or cp == '\t' or cp == 0xa0 or cp == 0x3000) return 0;
        if (cp >= 0x80) return 1;
        if (std.ascii.isAlphanumeric(@intCast(cp))) return 1;
        return switch (cp) {
            '_', '-', '.', '/', '~', '+', '\\' => 1,
            else => cp,
        };
    }

    /// Class of the character covering `p`; null for wrap spacers (skipped).
    fn classAt(self: *const Terminal, p: Pos) ?u21 {
        const c = self.cellAtPos(p);
        if (c.attrs.wide_spacer) {
            if (p.col > 0) {
                const head = self.cellAtPos(.{ .row = p.row, .col = p.col - 1 });
                if (head.attrs.wide) return charClass(head.cp);
            }
            return null;
        }
        return charClass(c.cp);
    }

    /// Range of the word (or run of blanks / identical punctuation) at the
    /// given position, following soft wraps. Null if the row is invalid.
    pub fn wordAt(self: *const Terminal, row: isize, col: usize) ?Range {
        const line = self.lineAt(row) orelse return null;
        var origin: Pos = .{ .row = row, .col = @min(col, self.lineWidth(line) - 1) };
        const oc = self.cellAtPos(origin);
        if (oc.attrs.wide_spacer and origin.col > 0 and self.cellAtPos(.{ .row = row, .col = origin.col - 1 }).attrs.wide)
            origin.col -= 1;
        const cls = self.classAt(origin) orelse 0;

        var start = origin;
        var p = origin;
        while (self.prevPos(p)) |q| {
            p = q;
            const qc = self.classAt(q) orelse continue;
            if (qc != cls) break;
            start = q;
            // Step onto the head of a wide char.
            if (self.cellAtPos(q).attrs.wide_spacer and q.col > 0) {
                start.col = q.col - 1;
                p = start;
            }
        }

        var end = origin;
        if (self.cellAtPos(end).attrs.wide) end.col += 1;
        p = end;
        while (self.nextPos(p)) |q| {
            p = q;
            const qc = self.classAt(q) orelse continue;
            if (qc != cls) break;
            end = q;
        }
        return .{ .start = start, .end = end };
    }

    // -----------------------------------------------------------------
    // Resize

    /// Resize the grid. The primary screen reflows soft-wrapped lines when
    /// the width changes and exchanges lines with the scrollback when the
    /// height changes; the alternate screen is cropped/extended. The cursor
    /// is kept on the same content, the scroll region is reset and the
    /// viewport returns to the bottom.
    pub fn resize(self: *Terminal, cols_in: usize, rows_in: usize) !void {
        const new_cols = @max(cols_in, 1);
        const new_rows = @max(rows_in, 1);
        if (new_cols == self.cols and new_rows == self.rows) return;
        const a = self.allocator;

        // Allocate everything that can fail before touching any state.
        var new_primary = try Screen.init(a, new_cols, new_rows);
        errdefer new_primary.deinit(a);
        var new_alt = try Screen.init(a, new_cols, new_rows);
        errdefer new_alt.deinit(a);
        const new_tabs = try a.alloc(bool, new_cols);
        errdefer a.free(new_tabs);
        const new_dirty = try a.alloc(bool, new_rows);
        errdefer a.free(new_dirty);
        var reflow: ?Reflow = null;
        if (new_cols != self.cols) reflow = try Reflow.init(a, self.scrollback_limit + new_rows, new_cols, self.cols);

        var track: ?Track = null;
        if (!self.alt_active) {
            track = .{ .row = self.cursor.row, .col = self.cursor.col, .pending = self.cursor.pending_wrap };
        } else if (self.saved_primary) |sp| {
            track = .{ .row = sp.row, .col = sp.col, .pending = sp.pending_wrap };
        }

        if (reflow) |*rf| {
            self.reflowPrimary(rf, &new_primary, new_rows, &track);
        } else {
            self.resizePrimaryRows(&new_primary, new_rows, &track);
        }
        copyScreenCropped(&self.alternate, &new_alt);

        self.primary.deinit(a);
        self.primary = new_primary;
        self.alternate.deinit(a);
        self.alternate = new_alt;

        @memcpy(new_tabs[0..@min(self.cols, new_cols)], self.tabstops[0..@min(self.cols, new_cols)]);
        if (new_cols > self.cols) resetTabs(new_tabs, self.cols);
        a.free(self.tabstops);
        self.tabstops = new_tabs;
        a.free(self.dirty);
        self.dirty = new_dirty;

        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;

        if (!self.alt_active) {
            if (track) |tr| {
                self.cursor.row = tr.row;
                self.cursor.col = tr.col;
                self.cursor.pending_wrap = tr.pending;
            }
        } else if (self.saved_primary) |*sp| {
            if (track) |tr| {
                sp.row = tr.row;
                sp.col = tr.col;
                sp.pending_wrap = tr.pending;
            }
        }
        self.cursor.row = @min(self.cursor.row, new_rows - 1);
        if (self.cursor.col >= new_cols) {
            self.cursor.col = new_cols - 1;
            self.cursor.pending_wrap = false;
        }
        self.cursor.pending_wrap = self.cursor.pending_wrap and self.cursor.col == new_cols - 1;
        inline for (.{ &self.saved_primary, &self.saved_alt }) |sv| {
            if (sv.*) |*s| {
                s.row = @min(s.row, new_rows - 1);
                s.col = @min(s.col, new_cols - 1);
            }
        }
        self.viewport_offset = 0;
        self.markAllDirty();
    }

    /// Height-only change of the primary screen: push rows into scrollback
    /// when shrinking (dropping blank rows below the cursor first), pull
    /// rows back when growing.
    fn resizePrimaryRows(self: *Terminal, dst: *Screen, new_rows: usize, track: *?Track) void {
        const a = self.allocator;
        const src = &self.primary;
        const old_rows = self.rows;
        if (new_rows < old_rows) {
            var content_end: usize = src.lastContentRow() orelse 0;
            if (track.*) |tr| content_end = @max(content_end, tr.row);
            const excess = old_rows - new_rows;
            const blank_below = old_rows - 1 - content_end;
            var push = excess - @min(excess, blank_below);
            if (track.*) |tr| push = @min(push, tr.row);
            for (0..push) |r| self.scrollback.push(a, src.rows[r].cells, src.rows[r].wrapped);
            for (0..new_rows) |r| copyRow(src.rows[push + r], &dst.rows[r]);
            if (track.*) |*tr| tr.row -= push;
        } else {
            const pull = @min(new_rows - old_rows, self.scrollback.len);
            var r = pull;
            while (r > 0) {
                r -= 1;
                var line = self.scrollback.popNewest().?;
                copyRow(.{ .cells = line.buf[0..line.len], .wrapped = line.wrapped }, &dst.rows[r]);
                line.free(a);
            }
            for (0..old_rows) |i| copyRow(src.rows[i], &dst.rows[pull + i]);
            if (track.*) |*tr| tr.row += pull;
        }
    }

    /// Copy cells (cropping or leaving the destination's blanks), never
    /// leaving half of a wide character at the right edge.
    fn copyRow(src: Row, dst: *Row) void {
        const n = @min(src.cells.len, dst.cells.len);
        @memcpy(dst.cells[0..n], src.cells[0..n]);
        dst.wrapped = src.wrapped and n == src.cells.len;
        if (src.cells.len != dst.cells.len) sanitizeRow(dst.cells);
    }

    fn copyScreenCropped(src: *const Screen, dst: *Screen) void {
        for (0..@min(src.rows.len, dst.rows.len)) |r| copyRow(src.rows[r], &dst.rows[r]);
    }

    fn reflowPrimary(self: *Terminal, rf: *Reflow, dst: *Screen, new_rows: usize, track: *?Track) void {
        const a = self.allocator;
        const src = &self.primary;
        var content_rows: usize = if (src.lastContentRow()) |r| r + 1 else 0;
        if (track.*) |tr| content_rows = @max(content_rows, tr.row + 1);

        // Old scrollback, oldest first (consumed as we go).
        while (self.scrollback.popOldest()) |line_in| {
            var line = line_in;
            if (rf.logical.items.len == 0 and !line.wrapped and line.len <= rf.new_cols) {
                rf.out.pushOwned(a, line); // fits as-is: move without copying
                rf.phys += 1;
                continue;
            }
            rf.addPhysical(line.buf[0..line.len], line.wrapped, null);
            line.free(a);
        }
        for (0..content_rows) |r| {
            var cursor: ?Track = null;
            if (track.*) |tr| {
                if (tr.row == r) cursor = tr;
            }
            rf.addPhysical(src.rows[r].cells, src.rows[r].wrapped, cursor);
        }
        rf.flush();

        // Choose which physical lines end up on screen.
        const total = rf.phys;
        const kept_first = total - rf.out.len;
        var top = if (total > new_rows) total - new_rows else 0;
        if (track.* != null) {
            if (rf.cursor_phys) |cp| {
                if (cp < top) top = cp;
            }
        }
        top = @max(top, kept_first);
        const on_screen = @min(total - top, new_rows);
        var drop = total - top - on_screen;
        while (drop > 0) : (drop -= 1) {
            var l = rf.out.popNewest().?;
            l.free(a);
        }
        var r = on_screen;
        while (r > 0) {
            r -= 1;
            var l = rf.out.popNewest().?;
            copyRow(.{ .cells = l.buf[0..l.len], .wrapped = l.wrapped }, &dst.rows[r]);
            l.free(a);
        }
        rf.out.shrinkTo(a, self.scrollback_limit);
        self.scrollback.deinit(a);
        self.scrollback = rf.out;
        rf.out = .{};
        rf.deinit();

        if (track.*) |*tr| {
            if (rf.cursor_phys) |cp| {
                const phys = @max(cp, top);
                tr.row = @min(phys - top, new_rows - 1);
                tr.col = @min(rf.cursor_col, rf.new_cols - 1);
                tr.pending = rf.cursor_pending;
            } else {
                tr.* = .{ .row = on_screen -| 1, .col = 0, .pending = false };
            }
        }
    }
};

/// Streaming re-wrapper used by `resize` when the width changes.
const Reflow = struct {
    allocator: Allocator,
    out: Scrollback,
    new_cols: usize,
    logical: std.ArrayList(Cell) = .empty,
    seg: std.ArrayList(Cell) = .empty,
    /// Physical lines emitted so far.
    phys: usize = 0,
    /// Cursor offset (in columns) within the pending logical line.
    cursor_off: ?usize = null,
    cursor_in_pending: bool = false,
    cursor_pending_wrap: bool = false,
    cursor_phys: ?usize = null,
    cursor_col: usize = 0,
    cursor_pending: bool = false,

    fn init(a: Allocator, out_cap: usize, new_cols: usize, old_cols: usize) !Reflow {
        var rf: Reflow = .{ .allocator = a, .out = try Scrollback.init(a, out_cap), .new_cols = new_cols };
        errdefer rf.out.deinit(a);
        try rf.seg.ensureTotalCapacity(a, new_cols + 2);
        errdefer rf.seg.deinit(a);
        try rf.logical.ensureTotalCapacity(a, @max(old_cols, new_cols) * 4);
        return rf;
    }

    fn deinit(self: *Reflow) void {
        self.out.deinit(self.allocator);
        self.logical.deinit(self.allocator);
        self.seg.deinit(self.allocator);
    }

    /// Append one old physical row to the current logical line.
    fn addPhysical(self: *Reflow, cells: []const Cell, wrapped: bool, cursor: ?Track) void {
        if (cursor) |cur| {
            self.cursor_off = self.logical.items.len + cur.col;
            self.cursor_pending_wrap = cur.pending;
        }
        for (cells, 0..) |c, i| {
            // Skip wrap spacers (a spacer with no wide head before it).
            if (c.attrs.wide_spacer and !(i > 0 and cells[i - 1].attrs.wide)) continue;
            self.logical.append(self.allocator, c) catch break;
        }
        if (!wrapped) self.flush();
    }

    /// Re-wrap and emit the pending logical line.
    fn flush(self: *Reflow) void {
        if (self.logical.items.len == 0 and self.cursor_off == null) return;
        defer {
            self.logical.clearRetainingCapacity();
            self.cursor_off = null;
        }
        const a = self.allocator;
        var n = cell_mod.trimmedLen(self.logical.items);
        if (self.cursor_off) |*o| {
            // A cursor right after the content is modelled as sitting on the
            // last cell with a pending wrap, so content that exactly fills
            // the new width does not spill an empty continuation line.
            if (!self.cursor_pending_wrap and o.* > 0 and o.* >= n) {
                o.* -= 1;
                self.cursor_pending_wrap = true;
            }
            while (self.logical.items.len < o.* + 1) {
                self.logical.append(a, Cell.blank) catch break;
            }
            n = @max(n, @min(o.* + 1, self.logical.items.len));
        }
        const cells = self.logical.items[0..n];
        const nc = self.new_cols;
        if (n == 0) {
            if (self.cursor_off != null) self.setCursor(0);
            self.out.push(a, &.{}, false);
            self.phys += 1;
            return;
        }
        var start: usize = 0;
        while (start < n) {
            self.seg.clearRetainingCapacity();
            var col: usize = 0;
            var j = start;
            while (j < n and col < nc) {
                const c = cells[j];
                if (c.attrs.wide) {
                    const has_spacer = j + 1 < n and cells[j + 1].attrs.wide_spacer;
                    const step: usize = if (has_spacer) 2 else 1;
                    if (col + 2 > nc) {
                        if (col != 0) break;
                        // Width 1 terminal: a wide char cannot fit; keep the head.
                        var h = c;
                        h.attrs.wide = false;
                        self.seg.appendAssumeCapacity(h);
                        col += 1;
                        j += step;
                        continue;
                    }
                    self.seg.appendAssumeCapacity(c);
                    var sp: Cell = if (has_spacer) cells[j + 1] else .{ .fg = c.fg, .bg = c.bg };
                    sp.attrs.wide_spacer = true;
                    self.seg.appendAssumeCapacity(sp);
                    col += 2;
                    j += step;
                } else if (c.attrs.wide_spacer) {
                    self.seg.appendAssumeCapacity(.{ .fg = c.fg, .bg = c.bg });
                    col += 1;
                    j += 1;
                } else {
                    self.seg.appendAssumeCapacity(c);
                    col += 1;
                    j += 1;
                }
            }
            const more = j < n;
            if (more and col < nc) self.seg.appendAssumeCapacity(.{ .attrs = .{ .wide_spacer = true } });
            if (self.cursor_off) |o| {
                if (o >= start and o < j) self.setCursor(o - start);
            }
            self.out.push(a, self.seg.items, more);
            self.phys += 1;
            start = j;
        }
    }

    fn setCursor(self: *Reflow, col_in: usize) void {
        var col = @min(col_in, self.new_cols - 1);
        var pending = false;
        if (self.cursor_pending_wrap) {
            // The cursor sat after the last written character.
            if (col + 1 < self.new_cols) col += 1 else pending = true;
        }
        self.cursor_phys = self.phys;
        self.cursor_col = col;
        self.cursor_pending = pending;
    }
};
