//! Interactive line editor: emacs key bindings, history with prefix search,
//! incremental reverse search, fish-style autosuggestions, tab completion,
//! syntax highlighting and correct handling of wrapped lines.
const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const complete = @import("complete.zig");
const highlight = @import("highlight.zig");
const linux = std.os.linux;
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// display width helpers
// ---------------------------------------------------------------------------

pub fn wcwidth(cp: u21) usize {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x1ab0 and cp <= 0x1aff) or (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or (cp >= 0xfe20 and cp <= 0xfe2f) or cp == 0x200b or cp == 0x200c or
        cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

pub const Pos = struct { row: usize = 0, col: usize = 0 };

/// Advance a simulated cursor over `text` as the terminal would render it.
/// Escape sequences and \x01..\x02 regions have zero width; other control
/// characters are shown as ^X (width 2) by the renderer.
pub fn advance(p: *Pos, text: []const u8, cols: usize) void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            p.row += 1;
            p.col = 0;
            i += 1;
            continue;
        }
        if (c == 0x01) {
            while (i < text.len and text[i] != 0x02) i += 1;
            i += 1;
            continue;
        }
        if (c == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                i += 1;
            } else if (i < text.len and text[i] == ']') {
                while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) i += 1;
                i += if (i < text.len and text[i] == 0x1b) 2 else 1;
            } else i += 1;
            continue;
        }
        var w: usize = 0;
        var len: usize = 1;
        if (c < 0x20 or c == 0x7f) {
            w = 2;
        } else {
            const d = decode(text, i);
            len = d.len;
            w = wcwidth(d.cp);
        }
        if (w > 0 and p.col + w > cols) {
            p.row += 1;
            p.col = 0;
        }
        p.col += w;
        i += len;
    }
}

pub fn visibleWidth(text: []const u8) usize {
    var p = Pos{};
    advance(&p, text, std.math.maxInt(usize) / 2);
    return p.col;
}

// ---------------------------------------------------------------------------
// keys
// ---------------------------------------------------------------------------

const Special = enum { up, down, left, right, home, end, delete, insert, pgup, pgdn, ctrl_left, ctrl_right, shift_tab, paste_start, paste_end, unknown };

const Key = union(enum) {
    text: [4]u8, // UTF-8 bytes; length in text_len
    ctrl: u8,
    alt: u8,
    special: Special,
};

pub const Editor = struct {
    sh: *Shell,
    in_fd: i32 = 0,
    out_fd: i32 = 2,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    killbuf: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    orig: ?sys.termios = null,
    cols: usize = 80,
    cur_row: usize = 0,
    end_row: usize = 0,
    prompt: []const u8 = "",
    // history navigation
    hist_idx: usize = 0,
    hist_prefix: std.ArrayList(u8) = .empty,
    saved_line: std.ArrayList(u8) = .empty,
    // autosuggestion (slice into history, valid until the next refresh)
    suggestion: []const u8 = "",
    last_tab: bool = false,
    interrupted: bool = false,
    pending_key: ?Key = null,
    key_len: usize = 0,
    cmd_cache: highlight.Cache = .{},
    paste: bool = false,
    last_kill: bool = false,
    this_kill: bool = false,
    wrapped_end: bool = false,

    pub fn init(sh: *Shell) Editor {
        return .{ .sh = sh };
    }

    fn gpa(self: *Editor) Allocator {
        return self.sh.gpa;
    }

    // ------------------------------------------------------------------
    // terminal
    // ------------------------------------------------------------------

    fn enableRaw(self: *Editor) bool {
        const t = sys.tcgetattr(self.in_fd) catch return false;
        self.orig = t;
        var r = t;
        r.iflag.BRKINT = false;
        r.iflag.ICRNL = false;
        r.iflag.INPCK = false;
        r.iflag.ISTRIP = false;
        r.iflag.IXON = false;
        r.lflag.ECHO = false;
        r.lflag.ICANON = false;
        r.lflag.IEXTEN = false;
        r.lflag.ISIG = false;
        r.cc[@intFromEnum(linux.V.MIN)] = 1;
        r.cc[@intFromEnum(linux.V.TIME)] = 0;
        sys.tcsetattr(self.in_fd, &r) catch return false;
        // bracketed paste on
        sys.writeAll(self.out_fd, "\x1b[?2004h") catch {};
        return true;
    }

    fn disableRaw(self: *Editor) void {
        sys.writeAll(self.out_fd, "\x1b[?2004l") catch {};
        if (self.orig) |t| sys.tcsetattr(self.in_fd, &t) catch {};
    }

    fn updateCols(self: *Editor) void {
        if (sys.winsize(self.out_fd)) |ws| {
            self.cols = ws.col;
        } else if (sys.winsize(self.in_fd)) |ws| {
            self.cols = ws.col;
        } else {
            self.cols = 80;
            if (self.sh.getVar("COLUMNS")) |c| self.cols = std.fmt.parseInt(usize, c, 10) catch 80;
        }
        if (self.cols == 0) self.cols = 80;
    }

    fn readByte(self: *Editor) ?u8 {
        var b: [1]u8 = undefined;
        while (true) {
            const n = sys.readIntr(self.in_fd, &b) catch {
                if (sys.last_errno == .INTR) {
                    // window resize: redraw
                    if (@import("signals.zig").take(linux.SIG.WINCH)) {
                        self.updateCols();
                        self.refresh();
                    }
                    continue;
                }
                return null;
            };
            if (n == 0) return null;
            return b[0];
        }
    }

    noinline fn readKey(self: *Editor) ?Key {
        const b = self.readByte() orelse return null;
        if (b == 0x1b) {
            if (!sys.pollIn(self.in_fd, 50)) return .{ .ctrl = 0x1b };
            const b2 = self.readByte() orelse return .{ .ctrl = 0x1b };
            if (b2 == '[') {
                var params: [16]u8 = undefined;
                var np: usize = 0;
                var fin: u8 = 0;
                while (true) {
                    const x = self.readByte() orelse return null;
                    if (x >= 0x40 and x <= 0x7e) {
                        fin = x;
                        break;
                    }
                    if (np < params.len) {
                        params[np] = x;
                        np += 1;
                    }
                }
                const p = params[0..np];
                const mod_ctrl = std.mem.endsWith(u8, p, ";5") or std.mem.endsWith(u8, p, ";3");
                return .{ .special = switch (fin) {
                    'A' => .up,
                    'B' => .down,
                    'C' => if (mod_ctrl) .ctrl_right else .right,
                    'D' => if (mod_ctrl) .ctrl_left else .left,
                    'H' => .home,
                    'F' => .end,
                    'Z' => .shift_tab,
                    '~' => blk: {
                        const n = std.fmt.parseInt(u32, p[0 .. std.mem.indexOfScalar(u8, p, ';') orelse p.len], 10) catch 0;
                        break :blk switch (n) {
                            1, 7 => .home,
                            4, 8 => .end,
                            3 => .delete,
                            2 => .insert,
                            5 => .pgup,
                            6 => .pgdn,
                            200 => .paste_start,
                            201 => .paste_end,
                            else => .unknown,
                        };
                    },
                    else => .unknown,
                } };
            }
            if (b2 == 'O') {
                const b3 = self.readByte() orelse return null;
                return .{ .special = switch (b3) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => .unknown,
                } };
            }
            return .{ .alt = b2 };
        }
        if (b < 0x20 or b == 0x7f) return .{ .ctrl = b };
        var k = Key{ .text = undefined };
        k.text[0] = b;
        var len: usize = 1;
        if (b >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
            while (len < n) : (len += 1) {
                k.text[len] = self.readByte() orelse break;
            }
        }
        self.key_len = len;
        return k;
    }

    // ------------------------------------------------------------------
    // rendering
    // ------------------------------------------------------------------

    fn emit(self: *Editor, s: []const u8) void {
        self.out.appendSlice(self.gpa(), s) catch {};
    }

    fn emitf(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        self.out.print(self.gpa(), fmt, args) catch {};
    }

    fn flush(self: *Editor) void {
        sys.writeAll(self.out_fd, self.out.items) catch {};
        self.out.clearRetainingCapacity();
    }

    fn computeSuggestion(self: *Editor) void {
        self.suggestion = "";
        if (self.buf.items.len == 0 or self.pos != self.buf.items.len) return;
        if (std.mem.indexOfScalar(u8, self.buf.items, '\n') != null) return;
        const h = &self.sh.hist;
        var i = h.len();
        while (i > 0) {
            i -= 1;
            const e = h.get(i);
            if (e.len > self.buf.items.len and std.mem.startsWith(u8, e, self.buf.items)) {
                const rest = e[self.buf.items.len..];
                const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                self.suggestion = rest[0..nl];
                return;
            }
        }
    }

    /// Emit the buffer with syntax highlighting.
    noinline fn emitBuffer(self: *Editor) void {
        const text = self.buf.items;
        const colors = highlight.colorize(self.sh, &self.cmd_cache, self.gpa(), text) catch null;
        defer if (colors) |c| self.gpa().free(c);
        var cur: highlight.Color = .none;
        var i: usize = 0;
        while (i < text.len) {
            const col: highlight.Color = if (colors) |c| c[i] else .none;
            if (col != cur) {
                self.emit("\x1b[0m");
                self.emit(highlight.sgr(col));
                cur = col;
            }
            const c = text[i];
            if (c == '\n') {
                self.emit("\r\n");
                i += 1;
                continue;
            }
            if (c < 0x20 or c == 0x7f) {
                const pair = [2]u8{ '^', if (c == 0x7f) '?' else c + 0x40 };
                self.emit(&pair);
                i += 1;
                continue;
            }
            const d = decode(text, i);
            self.emit(text[i .. i + d.len]);
            i += d.len;
        }
        if (cur != .none) self.emit("\x1b[0m");
    }

    fn promptText(self: *Editor) []const u8 {
        return self.prompt;
    }

    fn emitPrompt(self: *Editor) void {
        // strip the \x01 \x02 non-printing markers
        for (self.prompt) |c| {
            if (c == 0x01 or c == 0x02) continue;
            self.out.append(self.gpa(), c) catch {};
        }
    }

    noinline fn refreshWith(self: *Editor, show_suggestion: bool) void {
        self.updateCols();
        const cols = self.cols;
        if (self.cur_row > 0) self.emitf("\x1b[{d}A", .{self.cur_row});
        self.emit("\r\x1b[J");
        self.emitPrompt();
        self.emitBuffer();
        if (show_suggestion) self.computeSuggestion() else self.suggestion = "";
        if (self.suggestion.len > 0) {
            self.emit("\x1b[90m");
            self.emit(self.suggestion);
            self.emit("\x1b[0m");
        }
        var end = Pos{};
        advance(&end, self.prompt, cols);
        advance(&end, self.buf.items, cols);
        advance(&end, self.suggestion, cols);
        self.wrapped_end = false;
        if (end.col >= cols) {
            self.emit("\r\n");
            end.row += 1;
            end.col = 0;
            self.wrapped_end = true;
        }
        var cur = Pos{};
        advance(&cur, self.prompt, cols);
        advance(&cur, self.buf.items[0..self.pos], cols);
        if (cur.col >= cols) {
            cur.row += 1;
            cur.col = 0;
        }
        if (end.row > cur.row) self.emitf("\x1b[{d}A", .{end.row - cur.row});
        self.emit("\r");
        if (cur.col > 0) self.emitf("\x1b[{d}C", .{cur.col});
        self.cur_row = cur.row;
        self.end_row = end.row;
        self.flush();
    }

    pub fn refresh(self: *Editor) void {
        self.refreshWith(true);
    }

    /// Move the cursor below the current input (before printing output).
    noinline fn moveToEnd(self: *Editor) void {
        self.pos = self.buf.items.len;
        self.refreshWith(false);
        // if the input exactly filled the last row we are already at the
        // start of a fresh line
        if (!self.wrapped_end) self.emit("\r\n");
        self.flush();
        self.cur_row = 0;
        self.end_row = 0;
    }

    // ------------------------------------------------------------------
    // editing primitives
    // ------------------------------------------------------------------

    fn prevChar(self: *Editor, p: usize) usize {
        var i = p;
        if (i == 0) return 0;
        i -= 1;
        while (i > 0 and (self.buf.items[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    fn nextChar(self: *Editor, p: usize) usize {
        const s = self.buf.items;
        if (p >= s.len) return s.len;
        const n = std.unicode.utf8ByteSequenceLength(s[p]) catch 1;
        return @min(s.len, p + n);
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    fn wordLeft(self: *Editor, p: usize) usize {
        const s = self.buf.items;
        var i = p;
        while (i > 0 and !isWordChar(s[i - 1])) i -= 1;
        while (i > 0 and isWordChar(s[i - 1])) i -= 1;
        return i;
    }

    fn wordRight(self: *Editor, p: usize) usize {
        const s = self.buf.items;
        var i = p;
        while (i < s.len and !isWordChar(s[i])) i += 1;
        while (i < s.len and isWordChar(s[i])) i += 1;
        return i;
    }

    fn insert(self: *Editor, text: []const u8) void {
        self.buf.insertSlice(self.gpa(), self.pos, text) catch return;
        self.pos += text.len;
    }

    /// Kill text into the kill buffer. Consecutive kills accumulate
    /// (backward kills are prepended, forward kills appended).
    fn killRange(self: *Editor, a: usize, b: usize, backward: bool) void {
        self.this_kill = true;
        if (a >= b) return;
        if (!self.last_kill) self.killbuf.clearRetainingCapacity();
        if (backward) {
            self.killbuf.insertSlice(self.gpa(), 0, self.buf.items[a..b]) catch {};
        } else {
            self.killbuf.appendSlice(self.gpa(), self.buf.items[a..b]) catch {};
        }
        self.buf.replaceRange(self.gpa(), a, b - a, &.{}) catch {};
        self.pos = a;
    }

    fn setLine(self: *Editor, s: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.gpa(), s) catch {};
        self.pos = self.buf.items.len;
    }

    // ------------------------------------------------------------------
    // history
    // ------------------------------------------------------------------

    noinline fn historyMove(self: *Editor, up: bool) void {
        const h = &self.sh.hist;
        if (self.hist_idx == h.len()) {
            // entering history: remember the current line and use it as
            // the search prefix
            self.saved_line.clearRetainingCapacity();
            self.saved_line.appendSlice(self.gpa(), self.buf.items) catch {};
            self.hist_prefix.clearRetainingCapacity();
            self.hist_prefix.appendSlice(self.gpa(), self.buf.items) catch {};
        }
        const prefix = self.hist_prefix.items;
        var i = self.hist_idx;
        if (up) {
            while (i > 0) {
                i -= 1;
                const e = h.get(i);
                if (std.mem.startsWith(u8, e, prefix) and !std.mem.eql(u8, e, self.buf.items)) {
                    self.hist_idx = i;
                    self.setLine(e);
                    return;
                }
            }
            sys.writeAll(self.out_fd, "\x07") catch {};
        } else {
            while (i < h.len()) {
                i += 1;
                if (i == h.len()) {
                    self.hist_idx = i;
                    self.setLine(self.saved_line.items);
                    return;
                }
                const e = h.get(i);
                if (std.mem.startsWith(u8, e, prefix) and !std.mem.eql(u8, e, self.buf.items)) {
                    self.hist_idx = i;
                    self.setLine(e);
                    return;
                }
            }
        }
    }

    /// Ctrl-R incremental reverse search. Returns the key that ended the
    /// search (to be processed normally), or null when the line was
    /// accepted with Enter (then `accepted` is set).
    noinline fn reverseSearch(self: *Editor, accepted: *bool) ?Key {
        const h = &self.sh.hist;
        const a = self.gpa();
        var query: std.ArrayList(u8) = .empty;
        defer query.deinit(a);
        var orig: std.ArrayList(u8) = .empty;
        defer orig.deinit(a);
        orig.appendSlice(a, self.buf.items) catch {};
        const orig_pos = self.pos;
        const saved_prompt = self.prompt;
        defer self.prompt = saved_prompt;
        var idx: usize = h.len();
        var failed = false;
        var pbuf: std.ArrayList(u8) = .empty;
        defer pbuf.deinit(a);
        while (true) {
            pbuf.clearRetainingCapacity();
            pbuf.print(a, "({s}reverse-i-search)`{s}': ", .{ if (failed) "failed " else "", query.items }) catch {};
            self.prompt = pbuf.items;
            self.refreshWith(false);
            const k = self.readKey() orelse return null;
            switch (k) {
                .ctrl => |c| switch (c) {
                    0x12 => { // Ctrl-R: next match
                        if (query.items.len == 0) continue;
                        var i = idx;
                        failed = true;
                        while (i > 0) {
                            i -= 1;
                            if (std.mem.indexOf(u8, h.get(i), query.items)) |off| {
                                idx = i;
                                self.setLine(h.get(i));
                                self.pos = off;
                                failed = false;
                                break;
                            }
                        }
                        continue;
                    },
                    0x7f, 0x08 => {
                        if (query.items.len > 0) query.items.len -= 1;
                        idx = h.len();
                        failed = false;
                        if (query.items.len == 0) {
                            self.setLine(orig.items);
                            continue;
                        }
                        self.searchFrom(query.items, &idx, &failed);
                        continue;
                    },
                    0x07, 0x03 => { // Ctrl-G / Ctrl-C: cancel
                        self.setLine(orig.items);
                        self.pos = orig_pos;
                        return .{ .special = .unknown };
                    },
                    '\r', '\n' => {
                        accepted.* = true;
                        return null;
                    },
                    else => return k,
                },
                .text => |t| {
                    query.appendSlice(a, t[0..self.key_len]) catch {};
                    idx = @min(idx + 1, h.len());
                    self.searchFrom(query.items, &idx, &failed);
                },
                else => return k,
            }
        }
    }

    fn searchFrom(self: *Editor, q: []const u8, idx: *usize, failed: *bool) void {
        const h = &self.sh.hist;
        var i = idx.*;
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, h.get(i), q)) |off| {
                idx.* = i;
                self.setLine(h.get(i));
                self.pos = off;
                failed.* = false;
                return;
            }
        }
        failed.* = true;
    }

    // ------------------------------------------------------------------
    // completion
    // ------------------------------------------------------------------

    noinline fn doComplete(self: *Editor) void {
        const a = self.sh.scratchAlloc();
        const m = self.sh.scratch.mark();
        defer self.sh.scratch.release(m);
        const res = complete.complete(self.sh, a, self.buf.items, self.pos) catch return;
        if (res.candidates.len == 0) {
            sys.writeAll(self.out_fd, "\x07") catch {};
            return;
        }
        const word = self.buf.items[res.start..self.pos];
        if (res.candidates.len == 1) {
            const c = res.candidates[0];
            var ins: std.ArrayList(u8) = .empty;
            ins.appendSlice(a, if (res.raw) c.text else (complete.escape(a, c.text) catch c.text)) catch return;
            if (!c.is_dir and res.add_space) ins.append(a, ' ') catch {};
            self.replaceWord(res.start, ins.items);
            return;
        }
        // longest common prefix
        var lcp: []const u8 = res.candidates[0].text;
        for (res.candidates[1..]) |c| {
            var n: usize = 0;
            while (n < lcp.len and n < c.text.len and lcp[n] == c.text[n]) n += 1;
            lcp = lcp[0..n];
        }
        const unesc = complete.unescape(a, word) catch word;
        if (lcp.len > unesc.len) {
            self.replaceWord(res.start, if (res.raw) lcp else (complete.escape(a, lcp) catch lcp));
            return;
        }
        // show candidates
        self.listCandidates(res.candidates);
    }

    fn replaceWord(self: *Editor, start: usize, text: []const u8) void {
        self.buf.replaceRange(self.gpa(), start, self.pos - start, text) catch return;
        self.pos = start + text.len;
    }

    noinline fn listCandidates(self: *Editor, cands: []const complete.Candidate) void {
        self.moveToEnd();
        if (cands.len > 200) {
            var q: [64]u8 = undefined;
            sys.writeAll(self.out_fd, std.fmt.bufPrint(&q, "Display all {d} possibilities? (y or n)", .{cands.len}) catch "") catch {};
            const k = self.readKey();
            sys.writeAll(self.out_fd, "\r\n") catch {};
            const yes = if (k) |kk| switch (kk) {
                .text => |t| t[0] == 'y' or t[0] == 'Y' or t[0] == ' ',
                else => false,
            } else false;
            if (!yes) {
                self.refresh();
                return;
            }
        }
        var maxw: usize = 0;
        for (cands) |c| maxw = @max(maxw, visibleWidth(c.display) + 2);
        self.updateCols();
        const ncols = @max(1, self.cols / @max(1, maxw));
        const nrows = (cands.len + ncols - 1) / ncols;
        var r: usize = 0;
        while (r < nrows) : (r += 1) {
            var c: usize = 0;
            while (c < ncols) : (c += 1) {
                const idx = c * nrows + r;
                if (idx >= cands.len) break;
                const cand = cands[idx];
                if (cand.is_dir) self.emit("\x1b[1;34m") else if (cand.is_exec) self.emit("\x1b[32m");
                self.emit(cand.display);
                if (cand.is_dir or cand.is_exec) self.emit("\x1b[0m");
                const w = visibleWidth(cand.display);
                const last_col = c + 1 == ncols or (c + 1) * nrows + r >= cands.len;
                if (!last_col) {
                    var k: usize = w;
                    while (k < maxw) : (k += 1) self.emit(" ");
                }
            }
            self.emit("\r\n");
        }
        self.flush();
        self.cur_row = 0;
        self.refresh();
    }

    // ------------------------------------------------------------------
    // main loop
    // ------------------------------------------------------------------

    noinline fn plainReadLine(self: *Editor) ?[]const u8 {
        self.buf.clearRetainingCapacity();
        sys.writeAll(self.out_fd, self.prompt) catch {};
        var got = false;
        while (true) {
            var b: [1]u8 = undefined;
            const n = sys.read(self.in_fd, &b) catch return if (got) self.buf.items else null;
            if (n == 0) return if (got) self.buf.items else null;
            got = true;
            if (b[0] == '\n') return self.buf.items;
            self.buf.append(self.gpa(), b[0]) catch {};
        }
    }

    /// Read a line with editing. Returns null on EOF (Ctrl-D on an empty
    /// line). The result is valid until the next call.
    pub fn readLine(self: *Editor, prompt_text: []const u8) ?[]const u8 {
        self.interrupted = false;
        self.prompt = prompt_text;
        self.cmd_cache.clear(self.gpa());
        if (!sys.isatty(self.in_fd)) return self.plainReadLine();
        if (!self.enableRaw()) return self.plainReadLine();
        defer self.disableRaw();
        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.cur_row = 0;
        self.hist_idx = self.sh.hist.len();
        self.last_tab = false;
        self.refresh();
        var pending: ?Key = null;
        while (true) {
            const key = pending orelse (self.readKey() orelse {
                if (self.buf.items.len == 0) {
                    sys.writeAll(self.out_fd, "\r\n") catch {};
                    return null;
                }
                self.moveToEnd();
                return self.buf.items;
            });
            pending = null;
            const was_tab = self.last_tab;
            self.last_tab = false;
            self.last_kill = self.this_kill;
            self.this_kill = false;
            switch (key) {
                .text => |t| {
                    self.insert(t[0..self.key_len]);
                },
                .alt => |c| switch (c) {
                    'b', 'B' => self.pos = self.wordLeft(self.pos),
                    'f', 'F' => {
                        if (self.pos == self.buf.items.len and self.suggestion.len > 0) {
                            // accept one word of the suggestion
                            var n: usize = 0;
                            const s = self.suggestion;
                            while (n < s.len and !isWordChar(s[n])) n += 1;
                            while (n < s.len and isWordChar(s[n])) n += 1;
                            const piece = self.sh.gpa.dupe(u8, s[0..n]) catch "";
                            defer self.sh.gpa.free(piece);
                            self.insert(piece);
                        } else self.pos = self.wordRight(self.pos);
                    },
                    'd', 'D' => self.killRange(self.pos, self.wordRight(self.pos), false),
                    0x7f, 0x08 => {
                        const s = self.wordLeft(self.pos);
                        self.killRange(s, self.pos, true);
                    },
                    '.', '_' => {
                        // insert last argument of the previous command
                        const h = &self.sh.hist;
                        if (h.len() > 0) {
                            const e = std.mem.trimRight(u8, h.get(h.len() - 1), " \t\n");
                            var st = e.len;
                            while (st > 0 and e[st - 1] != ' ' and e[st - 1] != '\t') st -= 1;
                            const arg = self.sh.gpa.dupe(u8, e[st..]) catch "";
                            defer self.sh.gpa.free(arg);
                            self.insert(arg);
                        }
                    },
                    'u', 'U', 'l', 'L', 'c', 'C' => {
                        const s = self.pos;
                        const e = self.wordRight(s);
                        var first = true;
                        for (self.buf.items[s..e]) |*ch| {
                            if (!isWordChar(ch.*)) continue;
                            ch.* = switch (c) {
                                'u', 'U' => std.ascii.toUpper(ch.*),
                                'l', 'L' => std.ascii.toLower(ch.*),
                                else => if (first) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*),
                            };
                            first = false;
                        }
                        self.pos = e;
                    },
                    else => {},
                },
                .special => |s| switch (s) {
                    .left => self.pos = self.prevChar(self.pos),
                    .right => {
                        if (self.pos == self.buf.items.len and self.suggestion.len > 0) {
                            const sug = self.sh.gpa.dupe(u8, self.suggestion) catch "";
                            defer self.sh.gpa.free(sug);
                            self.insert(sug);
                        } else self.pos = self.nextChar(self.pos);
                    },
                    .home => self.pos = 0,
                    .end => {
                        if (self.pos == self.buf.items.len and self.suggestion.len > 0) {
                            const sug = self.sh.gpa.dupe(u8, self.suggestion) catch "";
                            defer self.sh.gpa.free(sug);
                            self.insert(sug);
                        } else self.pos = self.buf.items.len;
                    },
                    .ctrl_left => self.pos = self.wordLeft(self.pos),
                    .ctrl_right => self.pos = self.wordRight(self.pos),
                    .delete => {
                        if (self.pos < self.buf.items.len) {
                            const e = self.nextChar(self.pos);
                            self.buf.replaceRange(self.gpa(), self.pos, e - self.pos, &.{}) catch {};
                        }
                    },
                    .up => self.historyMove(true),
                    .down => self.historyMove(false),
                    .pgup => {
                        if (self.sh.hist.len() > 0) {
                            self.hist_idx = 0;
                            self.setLine(self.sh.hist.get(0));
                        }
                    },
                    .pgdn => {
                        self.hist_idx = self.sh.hist.len();
                        self.setLine(self.saved_line.items);
                    },
                    .paste_start => self.paste = true,
                    .paste_end => self.paste = false,
                    else => {},
                },
                .ctrl => |c| switch (c) {
                    '\r', '\n' => {
                        if (self.paste) {
                            self.insert("\n");
                        } else {
                            self.moveToEnd();
                            return self.buf.items;
                        }
                    },
                    0x01 => self.pos = 0, // ^A
                    0x05 => { // ^E
                        if (self.pos == self.buf.items.len and self.suggestion.len > 0) {
                            const sug = self.sh.gpa.dupe(u8, self.suggestion) catch "";
                            defer self.sh.gpa.free(sug);
                            self.insert(sug);
                        } else self.pos = self.buf.items.len;
                    },
                    0x02 => self.pos = self.prevChar(self.pos), // ^B
                    0x06 => { // ^F
                        if (self.pos == self.buf.items.len and self.suggestion.len > 0) {
                            const sug = self.sh.gpa.dupe(u8, self.suggestion) catch "";
                            defer self.sh.gpa.free(sug);
                            self.insert(sug);
                        } else self.pos = self.nextChar(self.pos);
                    },
                    0x7f, 0x08 => { // backspace
                        if (self.pos > 0) {
                            const p = self.prevChar(self.pos);
                            self.buf.replaceRange(self.gpa(), p, self.pos - p, &.{}) catch {};
                            self.pos = p;
                        }
                    },
                    0x04 => { // ^D
                        if (self.buf.items.len == 0) {
                            self.suggestion = "";
                            sys.writeAll(self.out_fd, "\r\n") catch {};
                            return null;
                        }
                        if (self.pos < self.buf.items.len) {
                            const e = self.nextChar(self.pos);
                            self.buf.replaceRange(self.gpa(), self.pos, e - self.pos, &.{}) catch {};
                        }
                    },
                    0x03 => { // ^C
                        self.pos = self.buf.items.len;
                        self.refreshWith(false);
                        sys.writeAll(self.out_fd, "^C\r\n") catch {};
                        self.cur_row = 0;
                        self.buf.clearRetainingCapacity();
                        self.pos = 0;
                        self.interrupted = true;
                        return self.buf.items;
                    },
                    0x0b => self.killRange(self.pos, self.buf.items.len, false), // ^K
                    0x15 => self.killRange(0, self.pos, true), // ^U
                    0x17 => { // ^W: kill whitespace-delimited word
                        var s = self.pos;
                        while (s > 0 and (self.buf.items[s - 1] == ' ' or self.buf.items[s - 1] == '\t')) s -= 1;
                        while (s > 0 and self.buf.items[s - 1] != ' ' and self.buf.items[s - 1] != '\t') s -= 1;
                        self.killRange(s, self.pos, true);
                    },
                    0x19 => { // ^Y
                        const k = self.sh.gpa.dupe(u8, self.killbuf.items) catch "";
                        defer self.sh.gpa.free(k);
                        self.insert(k);
                    },
                    0x14 => { // ^T transpose
                        if (self.pos > 0 and self.buf.items.len >= 2) {
                            var p = self.pos;
                            if (p == self.buf.items.len) p -= 1;
                            if (p > 0) {
                                const t = self.buf.items[p - 1];
                                self.buf.items[p - 1] = self.buf.items[p];
                                self.buf.items[p] = t;
                                self.pos = @min(p + 1, self.buf.items.len);
                            }
                        }
                    },
                    0x0c => { // ^L
                        sys.writeAll(self.out_fd, "\x1b[H\x1b[2J") catch {};
                        self.cur_row = 0;
                    },
                    0x10 => self.historyMove(true), // ^P
                    0x0e => self.historyMove(false), // ^N
                    0x12 => { // ^R
                        var accepted = false;
                        const k = self.reverseSearch(&accepted);
                        if (accepted) {
                            self.moveToEnd();
                            return self.buf.items;
                        }
                        if (k) |kk| {
                            switch (kk) {
                                .special => |sp| if (sp == .unknown) {} else {
                                    pending = kk;
                                },
                                else => pending = kk,
                            }
                        } else if (!accepted) {
                            // EOF during search
                            return null;
                        }
                    },
                    0x09 => { // Tab
                        _ = was_tab;
                        self.doComplete();
                        self.last_tab = true;
                    },
                    0x16 => { // ^V: literal next
                        if (self.readByte()) |b| {
                            const one = [1]u8{b};
                            self.insert(&one);
                        }
                    },
                    0x07 => {}, // ^G
                    0x1b => {}, // lone ESC
                    else => {},
                },
            }
            self.refresh();
        }
    }
};
