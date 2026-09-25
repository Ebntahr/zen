//! A multi-line plain-text editor view (GlassKit only has single-line
//! fields): wrapped layout with incremental relayout per paragraph, caret
//! and selection, mouse selection by character / word / line, keyboard
//! navigation with a sticky column, scrolling, clipboard and a coalescing
//! undo/redo history. Text is UTF-8; every caret position is a character
//! boundary.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const font = @import("font");
const abi = @import("abi");

const Ui = ui.Ui;
const Rect = ui.Rect;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const utf8 = font.utf8;
const find = @import("find.zig");

/// A visual (wrapped) line: `text[start..end]` is drawn; the next line
/// starts at `lines[i + 1].start` (after a '\n' or after break spaces).
pub const Line = struct {
    start: u32,
    end: u32,
};

/// A byte range `[a, b)`.
pub const Span = struct { a: usize, b: usize };

pub const EditKind = enum { typing, delete_back, delete_fwd, other };

const Edit = struct {
    pos: usize,
    removed: []u8,
    inserted: []u8,
    cursor_before: usize,
    anchor_before: usize,
    kind: EditKind,
    id: u64,

    fn free(self: *Edit, a: std.mem.Allocator) void {
        a.free(self.removed);
        a.free(self.inserted);
    }
};

pub const Style = struct {
    mono: bool = false,
    size: f32 = 15,
    wrap: bool = true,
};

const DragMode = enum { none, char, word, line };

pub const pad_x: f32 = 28;
pub const pad_top: f32 = 18;
pub const pad_bottom: f32 = 40;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    /// Sticky x for vertical movement.
    goal_x: ?f32 = null,

    style: Style = .{},
    lines: std.ArrayList(Line) = .empty,
    layout_width: f32 = -1,
    layout_style: Style = .{},
    layout_valid: bool = false,
    max_line_w: f32 = 0,
    /// Face of the current layout (set by `ensureLayout`).
    cur_face: ?*font.Face = null,

    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    reveal: bool = false,

    undo_stack: std.ArrayList(Edit) = .empty,
    redo_stack: std.ArrayList(Edit) = .empty,
    next_id: u64 = 1,
    /// Break coalescing of the next edit into the previous one.
    group_break: bool = true,
    /// Id of the undo-stack top when the document was saved.
    saved_id: u64 = 0,
    /// Bumped on every change (for cached statistics).
    version: u64 = 0,

    drag: DragMode = .none,
    drag_a: usize = 0,
    drag_b: usize = 0,

    /// Find matches to highlight (sorted, disjoint) and the current one.
    highlights: []const Span = &.{},
    highlight_current: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.clearHistory();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    fn clearHistory(self: *Editor) void {
        for (self.undo_stack.items) |*e| e.free(self.allocator);
        for (self.redo_stack.items) |*e| e.free(self.allocator);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    /// Replace the whole document (no undo), e.g. after opening a file.
    pub fn setText(self: *Editor, s: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, s);
        self.clearHistory();
        self.cursor = 0;
        self.anchor = 0;
        self.goal_x = null;
        self.scroll_y = 0;
        self.scroll_x = 0;
        self.layout_valid = false;
        self.group_break = true;
        self.saved_id = 0;
        self.version +%= 1;
    }

    pub fn bytes(self: *const Editor) []const u8 {
        return self.text.items;
    }

    pub fn stateId(self: *const Editor) u64 {
        return if (self.undo_stack.items.len > 0) self.undo_stack.items[self.undo_stack.items.len - 1].id else 0;
    }

    pub fn isDirty(self: *const Editor) bool {
        return self.stateId() != self.saved_id;
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_id = self.stateId();
        self.group_break = true;
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn selection(self: *const Editor) Span {
        return .{ .a = @min(self.cursor, self.anchor), .b = @max(self.cursor, self.anchor) };
    }

    pub fn hasSelection(self: *const Editor) bool {
        return self.cursor != self.anchor;
    }

    pub fn selectedText(self: *const Editor) []const u8 {
        const s = self.selection();
        return self.text.items[s.a..s.b];
    }

    // ------------------------------------------------------------------
    // Editing
    // ------------------------------------------------------------------

    /// Replace `[a, b)` with `s` as one undoable edit and put the caret after it.
    pub fn replace(self: *Editor, a: usize, b: usize, s: []const u8, kind: EditKind) void {
        if (a == b and s.len == 0) return;
        const al = self.allocator;
        const removed = al.dupe(u8, self.text.items[a..b]) catch return;
        const inserted = al.dupe(u8, s) catch {
            al.free(removed);
            return;
        };
        const cb = self.cursor;
        const ab = self.anchor;
        self.rawReplace(a, b, s) catch {
            al.free(removed);
            al.free(inserted);
            return;
        };
        self.cursor = a + s.len;
        self.anchor = self.cursor;
        self.goal_x = null;
        for (self.redo_stack.items) |*e| e.free(al);
        self.redo_stack.clearRetainingCapacity();

        // Coalesce typing and repeated deletes into one undo step.
        if (!self.group_break and self.undo_stack.items.len > 0) {
            const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (kind == .typing and top.kind == .typing and removed.len == 0 and top.pos + top.inserted.len == a) {
                if (al.realloc(top.inserted, top.inserted.len + inserted.len)) |grown| {
                    const old_len = grown.len - inserted.len;
                    @memcpy(grown[old_len..], inserted);
                    top.inserted = grown;
                    top.id = self.nextId();
                    al.free(removed);
                    al.free(inserted);
                    self.group_break = s.len > 0 and s[s.len - 1] == '\n';
                    return;
                } else |_| {}
            } else if (kind == .delete_back and top.kind == .delete_back and s.len == 0 and top.inserted.len == 0 and b == top.pos) {
                const joined = std.mem.concat(al, u8, &.{ removed, top.removed }) catch null;
                if (joined) |j| {
                    al.free(top.removed);
                    top.removed = j;
                    top.pos = a;
                    top.id = self.nextId();
                    al.free(removed);
                    al.free(inserted);
                    return;
                }
            } else if (kind == .delete_fwd and top.kind == .delete_fwd and s.len == 0 and top.inserted.len == 0 and a == top.pos) {
                const joined = std.mem.concat(al, u8, &.{ top.removed, removed }) catch null;
                if (joined) |j| {
                    al.free(top.removed);
                    top.removed = j;
                    top.id = self.nextId();
                    al.free(removed);
                    al.free(inserted);
                    return;
                }
            }
        }
        self.undo_stack.append(al, .{
            .pos = a,
            .removed = removed,
            .inserted = inserted,
            .cursor_before = cb,
            .anchor_before = ab,
            .kind = kind,
            .id = self.nextId(),
        }) catch {
            al.free(removed);
            al.free(inserted);
        };
        self.group_break = kind == .other or (s.len > 0 and s[s.len - 1] == '\n');
    }

    fn nextId(self: *Editor) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Replace bytes and update the layout incrementally.
    fn rawReplace(self: *Editor, a: usize, b: usize, s: []const u8) !void {
        const old = self.text.items;
        // Affected paragraphs in the old text.
        const ps = paraStart(old, a);
        const pe_old = paraEnd(old, b);
        try self.text.replaceRange(self.allocator, a, b - a, s);
        self.version +%= 1;
        if (!self.layout_valid) return;
        const delta: isize = @as(isize, @intCast(s.len)) - @as(isize, @intCast(b - a));
        const pe_new: usize = @intCast(@as(isize, @intCast(pe_old)) + delta);
        // Visual lines [first_li, end_li) cover the old paragraphs.
        const first_li = self.lineIndexOf(ps);
        var end_li = first_li;
        while (end_li < self.lines.items.len and self.lines.items[end_li].start <= pe_old) end_li += 1;
        var fresh: std.ArrayList(Line) = .empty;
        defer fresh.deinit(self.allocator);
        try self.layoutRange(&fresh, ps, pe_new);
        try self.lines.replaceRange(self.allocator, first_li, end_li - first_li, fresh.items);
        for (self.lines.items[first_li + fresh.items.len ..]) |*l| {
            l.start = @intCast(@as(isize, l.start) + delta);
            l.end = @intCast(@as(isize, l.end) + delta);
        }
    }

    pub fn insertText(self: *Editor, s: []const u8, kind: EditKind) void {
        const sel = self.selection();
        self.replace(sel.a, sel.b, s, if (sel.a != sel.b) .other else kind);
        self.reveal = true;
    }

    pub fn deleteBackward(self: *Editor, unit: Unit) void {
        const sel = self.selection();
        if (sel.a != sel.b) {
            self.replace(sel.a, sel.b, "", .other);
        } else if (self.cursor > 0) {
            const p = self.moveBy(self.cursor, unit, false);
            self.replace(p, self.cursor, "", .delete_back);
        }
        self.reveal = true;
    }

    pub fn deleteForward(self: *Editor, unit: Unit) void {
        const sel = self.selection();
        if (sel.a != sel.b) {
            self.replace(sel.a, sel.b, "", .other);
        } else if (self.cursor < self.text.items.len) {
            const n = self.moveBy(self.cursor, unit, true);
            const at = self.cursor;
            self.replace(at, n, "", .delete_fwd);
            self.cursor = at;
            self.anchor = at;
        }
        self.reveal = true;
    }

    pub fn undo(self: *Editor) void {
        var e = self.undo_stack.pop() orelse return;
        self.rawReplace(e.pos, e.pos + e.inserted.len, e.removed) catch {
            self.undo_stack.append(self.allocator, e) catch e.free(self.allocator);
            return;
        };
        self.cursor = e.cursor_before;
        self.anchor = e.anchor_before;
        if (self.cursor > self.text.items.len or self.anchor > self.text.items.len) {
            self.cursor = e.pos + e.removed.len;
            self.anchor = e.pos;
        }
        self.redo_stack.append(self.allocator, e) catch e.free(self.allocator);
        self.group_break = true;
        self.goal_x = null;
        self.reveal = true;
    }

    pub fn redo(self: *Editor) void {
        var e = self.redo_stack.pop() orelse return;
        self.rawReplace(e.pos, e.pos + e.removed.len, e.inserted) catch {
            self.redo_stack.append(self.allocator, e) catch e.free(self.allocator);
            return;
        };
        self.cursor = e.pos + e.inserted.len;
        self.anchor = self.cursor;
        self.undo_stack.append(self.allocator, e) catch e.free(self.allocator);
        self.group_break = true;
        self.goal_x = null;
        self.reveal = true;
    }

    pub fn selectAll(self: *Editor) void {
        self.anchor = 0;
        self.cursor = self.text.items.len;
        self.group_break = true;
    }

    pub fn copy(self: *Editor) void {
        if (!self.hasSelection()) return;
        ui.client.clipboardSet(self.selectedText()) catch {};
    }

    pub fn cut(self: *Editor) void {
        if (!self.hasSelection()) return;
        self.copy();
        const s = self.selection();
        self.replace(s.a, s.b, "", .other);
        self.reveal = true;
    }

    pub fn paste(self: *Editor) void {
        const clip = ui.client.clipboardGet(self.allocator) catch return;
        defer self.allocator.free(clip);
        // Normalize line endings.
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.allocator);
        var i: usize = 0;
        while (i < clip.len) : (i += 1) {
            if (clip[i] == '\r') {
                clean.append(self.allocator, '\n') catch return;
                if (i + 1 < clip.len and clip[i + 1] == '\n') i += 1;
            } else clean.append(self.allocator, clip[i]) catch return;
        }
        self.insertText(clean.items, .other);
        self.group_break = true;
    }

    // ------------------------------------------------------------------
    // Movement
    // ------------------------------------------------------------------

    pub const Unit = enum { char, word, line_edge };

    fn classOf(s: []const u8, i: usize) u8 {
        const c = s[i];
        if (c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_' or c == '\'') return 1;
        if (c == ' ' or c == '\t') return 0;
        if (c == '\n') return 3;
        return 2;
    }

    /// Next/previous position by unit (logical, not visual).
    fn moveBy(self: *Editor, pos: usize, unit: Unit, forward: bool) usize {
        const s = self.text.items;
        switch (unit) {
            .char => return if (forward) utf8.nextBoundary(s, pos) else utf8.prevBoundary(s, pos),
            .word => {
                var p = pos;
                if (forward) {
                    while (p < s.len and classOf(s, p) != 1) p = utf8.nextBoundary(s, p);
                    while (p < s.len and classOf(s, p) == 1) p = utf8.nextBoundary(s, p);
                } else {
                    while (p > 0 and classOf(s, utf8.prevBoundary(s, p)) != 1) p = utf8.prevBoundary(s, p);
                    while (p > 0 and classOf(s, utf8.prevBoundary(s, p)) == 1) p = utf8.prevBoundary(s, p);
                }
                return p;
            },
            .line_edge => {
                const li = self.lineIndexOf(pos);
                const l = self.lines.items[li];
                return if (forward) self.lineEndPos(li) else l.start;
            },
        }
    }

    /// Caret position at the end of visual line `li` (before its break).
    fn lineEndPos(self: *const Editor, li: usize) usize {
        const l = self.lines.items[li];
        if (li + 1 < self.lines.items.len) {
            const next = self.lines.items[li + 1].start;
            // Soft wrap: stay before the hanging spaces' last character so
            // the caret remains on this line.
            if (next > l.end and self.text.items[next - 1] != '\n') return @max(l.end, utf8.prevBoundary(self.text.items, next));
        }
        return l.end;
    }

    /// Word (or whitespace / punctuation run) around `pos`.
    pub fn wordAt(self: *const Editor, pos: usize) Span {
        const s = self.text.items;
        if (s.len == 0) return .{ .a = 0, .b = 0 };
        var p = @min(pos, s.len);
        if (p == s.len or s[p] == '\n') {
            if (p == 0) return .{ .a = 0, .b = 0 };
            p = utf8.prevBoundary(s, p);
            if (s[p] == '\n') return .{ .a = pos, .b = pos };
        }
        const cls = classOf(s, p);
        var a = p;
        while (a > 0) {
            const q = utf8.prevBoundary(s, a);
            if (classOf(s, q) != cls) break;
            a = q;
        }
        var b = utf8.nextBoundary(s, p);
        while (b < s.len and classOf(s, b) == cls) b = utf8.nextBoundary(s, b);
        return .{ .a = a, .b = b };
    }

    /// Paragraph ("line" for triple-click) around `pos`, including its newline.
    pub fn paragraphAt(self: *const Editor, pos: usize) Span {
        const s = self.text.items;
        const a = paraStart(s, pos);
        var b = paraEnd(s, pos);
        if (b < s.len) b += 1;
        return .{ .a = a, .b = b };
    }

    pub fn moveCaret(self: *Editor, pos: usize, extend: bool) void {
        self.cursor = @min(pos, self.text.items.len);
        if (!extend) self.anchor = self.cursor;
        self.group_break = true;
        self.reveal = true;
    }

    // ------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------

    pub fn face(self: *const Editor, u: *Ui) *font.Face {
        return u.face(if (self.style.mono) .mono else .regular, self.style.size);
    }

    pub fn lineHeight(self: *const Editor, u: *Ui) f32 {
        return @round(self.face(u).line_height * (if (self.style.mono) @as(f32, 1.15) else 1.12));
    }

    fn layoutRange(self: *Editor, out: *std.ArrayList(Line), ps: usize, pe: usize) !void {
        const s = self.text.items;
        const f = self.cur_face.?;
        var p = ps;
        while (true) {
            const e = if (std.mem.indexOfScalarPos(u8, s[0..pe], p, '\n')) |nl| nl else pe;
            if (self.layout_style.wrap and self.layout_width > 0) {
                var it = f.lines(s[p..e], self.layout_width);
                while (it.next()) |l| {
                    try out.append(self.allocator, .{ .start = @intCast(p + l.start), .end = @intCast(p + l.end) });
                    if (l.width > self.max_line_w) self.max_line_w = l.width;
                }
            } else {
                try out.append(self.allocator, .{ .start = @intCast(p), .end = @intCast(e) });
                const w = f.measure(s[p..e]);
                if (w > self.max_line_w) self.max_line_w = w;
            }
            if (e >= pe) break;
            p = e + 1;
        }
    }

    /// (Re)layout when the width or style changed.
    pub fn ensureLayout(self: *Editor, u: *Ui, width: f32) void {
        const f = self.face(u);
        self.cur_face = f;
        const w = if (self.style.wrap) width else -1;
        if (self.layout_valid and self.layout_width == w and std.meta.eql(self.layout_style, self.style)) return;
        self.layout_width = w;
        self.layout_style = self.style;
        self.lines.clearRetainingCapacity();
        self.max_line_w = 0;
        self.layoutRange(&self.lines, 0, self.text.items.len) catch {};
        self.layout_valid = true;
    }

    /// Index of the visual line containing caret position `pos`.
    pub fn lineIndexOf(self: *const Editor, pos: usize) usize {
        const ls = self.lines.items;
        if (ls.len == 0) return 0;
        var lo: usize = 0;
        var hi: usize = ls.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (ls[mid].start <= pos) lo = mid else hi = mid;
        }
        return lo;
    }

    fn xOf(self: *Editor, li: usize, pos: usize) f32 {
        const l = self.lines.items[li];
        const end = @max(@min(pos, self.text.items.len), l.start);
        return self.cur_face.?.measure(self.text.items[l.start..end]);
    }

    fn posAtX(self: *Editor, li: usize, x: f32) usize {
        const l = self.lines.items[li];
        const idx = l.start + self.cur_face.?.indexAtX(self.text.items[l.start..l.end], x);
        return @min(idx, self.lineEndPos(li));
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    pub fn counts(self: *const Editor) struct { words: usize, chars: usize } {
        var words: usize = 0;
        var chars: usize = 0;
        var in_word = false;
        for (self.text.items) |c| {
            if (c & 0xC0 != 0x80) chars += 1;
            const space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
            if (!space and !in_word) words += 1;
            in_word = !space;
        }
        return .{ .words = words, .chars = chars };
    }

    // ------------------------------------------------------------------
    // Input + drawing
    // ------------------------------------------------------------------

    pub const Colors = struct {
        bg: u32,
        text: u32,
        selection: u32,
        caret: u32,
        scrollbar: u32,
        find: u32 = 0,
        find_current: u32 = 0,
    };

    /// Handle keyboard input. Returns true when something changed.
    pub fn handleKeys(self: *Editor, u: *Ui, page_lines: usize) bool {
        var any = false;
        for (u.keys[0..u.key_count]) |k| {
            const shift = k.mods & Mods.shift != 0;
            const cmd = k.mods & (Mods.cmd | Mods.ctrl) != 0;
            const alt = k.mods & Mods.alt != 0;
            any = true;
            switch (k.code) {
                Key.left, Key.right => {
                    const fwd = k.code == Key.right;
                    if (!shift and self.hasSelection() and !cmd and !alt) {
                        const s = self.selection();
                        self.moveCaret(if (fwd) s.b else s.a, false);
                    } else {
                        const unit: Unit = if (cmd) .line_edge else if (alt) .word else .char;
                        self.moveCaret(self.moveBy(self.cursor, unit, fwd), shift);
                    }
                    self.goal_x = null;
                },
                Key.up, Key.down => {
                    if (cmd) {
                        self.moveCaret(if (k.code == Key.down) self.text.items.len else 0, shift);
                        self.goal_x = null;
                    } else self.moveVertical(if (k.code == Key.down) 1 else -1, shift);
                },
                Key.pageup, Key.pagedown => {
                    const n: isize = @intCast(@max(1, page_lines -| 1));
                    self.moveVertical(if (k.code == Key.pagedown) n else -n, shift);
                    const lh = self.lineHeight(u);
                    self.scroll_y += (if (k.code == Key.pagedown) lh else -lh) * @as(f32, @floatFromInt(n));
                },
                Key.home, Key.end => {
                    if (cmd) {
                        self.moveCaret(if (k.code == Key.end) self.text.items.len else 0, shift);
                    } else {
                        self.moveCaret(self.moveBy(self.cursor, .line_edge, k.code == Key.end), shift);
                    }
                    self.goal_x = null;
                },
                Key.backspace => self.deleteBackward(if (cmd) .line_edge else if (alt) .word else .char),
                Key.delete => self.deleteForward(if (cmd) .line_edge else if (alt) .word else .char),
                Key.enter, Key.kpenter => if (!cmd) self.insertText("\n", .typing),
                Key.tab => if (!cmd) self.insertText("\t", .typing),
                Key.a => if (cmd) self.selectAll(),
                Key.c => if (cmd) self.copy(),
                Key.x => if (cmd) self.cut(),
                Key.v => if (cmd) self.paste(),
                Key.z => if (cmd) {
                    if (shift) self.redo() else self.undo();
                },
                else => any = cmd or any,
            }
        }
        if (u.text_len > 0 and u.mods & (Mods.cmd | Mods.ctrl) == 0) {
            const t = u.text_in[0..u.text_len];
            // Tabs and newlines arrive as keys above.
            if (!(t.len == 1 and (t[0] == '\t' or t[0] == '\n'))) {
                self.insertText(t, .typing);
                any = true;
            }
        }
        u.keys_consumed = true;
        return any;
    }

    fn moveVertical(self: *Editor, delta: isize, extend: bool) void {
        if (self.lines.items.len == 0) return;
        if (!extend and self.hasSelection()) {
            const s = self.selection();
            self.cursor = if (delta > 0) s.b else s.a;
        }
        const li = self.lineIndexOf(self.cursor);
        const x = self.goal_x orelse self.xOf(li, self.cursor);
        const target = @as(isize, @intCast(li)) + delta;
        var pos: usize = undefined;
        if (target < 0) {
            pos = 0;
        } else if (target >= @as(isize, @intCast(self.lines.items.len))) {
            pos = self.text.items.len;
        } else {
            pos = self.posAtX(@intCast(target), x);
        }
        self.moveCaret(pos, extend);
        self.goal_x = x;
    }

    /// Caret position under a point in view coordinates.
    fn hitTest(self: *Editor, u: *Ui, area: Rect, mx: i32, my: i32) usize {
        if (self.lines.items.len == 0) return 0;
        const lh = self.lineHeight(u);
        const y = @as(f32, @floatFromInt(my - area.y)) + self.scroll_y - pad_top;
        if (y < 0) return 0;
        const li_f = @floor(y / lh);
        if (li_f >= @as(f32, @floatFromInt(self.lines.items.len))) return self.text.items.len;
        const li: usize = @intFromFloat(li_f);
        const x = @as(f32, @floatFromInt(mx - area.x)) - pad_x + self.scroll_x;
        return self.posAtX(li, x);
    }

    pub fn contentHeight(self: *const Editor, u: *Ui) f32 {
        return @as(f32, @floatFromInt(@max(1, self.lines.items.len))) * self.lineHeight(u) + pad_top + pad_bottom;
    }

    /// Mouse interaction; call before `draw`.
    pub fn handleMouse(self: *Editor, u: *Ui, area: Rect) void {
        const over = u.hovering(area);
        if (over) u.cursor = .ibeam;
        if (over and u.scroll_dy != 0) {
            self.scroll_y += u.scroll_dy;
            u.scroll_dy = 0;
        }
        if (over and u.scroll_dx != 0 and !self.style.wrap) {
            self.scroll_x += u.scroll_dx;
            u.scroll_dx = 0;
        }
        if (u.mouse_pressed and over) {
            const pos = self.hitTest(u, area, u.mouse_x, u.mouse_y);
            self.group_break = true;
            self.goal_x = null;
            if (u.click_count >= 3) {
                const p = self.paragraphAt(pos);
                self.drag = .line;
                self.drag_a = p.a;
                self.drag_b = p.b;
                self.anchor = p.a;
                self.cursor = p.b;
            } else if (u.click_count == 2) {
                const w = self.wordAt(pos);
                self.drag = .word;
                self.drag_a = w.a;
                self.drag_b = w.b;
                self.anchor = w.a;
                self.cursor = w.b;
            } else {
                self.drag = .char;
                self.cursor = pos;
                if (u.mods & Mods.shift == 0) self.anchor = pos;
            }
        } else if (self.drag != .none and u.mouse_down) {
            // Auto-scroll while dragging past the edges.
            if (u.mouse_y < area.y) self.scroll_y -= @floatFromInt(@min(40, area.y - u.mouse_y));
            if (u.mouse_y > area.bottom()) self.scroll_y += @floatFromInt(@min(40, u.mouse_y - area.bottom()));
            const pos = self.hitTest(u, area, u.mouse_x, u.mouse_y);
            switch (self.drag) {
                .char => self.cursor = pos,
                .word, .line => {
                    const r = if (self.drag == .word) self.wordAt(pos) else self.paragraphAt(pos);
                    if (pos < self.drag_a) {
                        self.anchor = self.drag_b;
                        self.cursor = r.a;
                    } else {
                        self.anchor = self.drag_a;
                        self.cursor = @max(r.b, self.drag_b);
                    }
                },
                .none => {},
            }
        }
        if (u.mouse_released or !u.mouse_down) self.drag = .none;
    }

    pub fn clampScroll(self: *Editor, u: *Ui, area: Rect) void {
        const max_y = @max(0, self.contentHeight(u) - @as(f32, @floatFromInt(area.h)));
        self.scroll_y = std.math.clamp(self.scroll_y, 0, max_y);
        if (self.style.wrap) {
            self.scroll_x = 0;
        } else {
            const view_w = @as(f32, @floatFromInt(area.w)) - 2 * pad_x;
            self.scroll_x = std.math.clamp(self.scroll_x, 0, @max(0, self.max_line_w + 4 - view_w));
        }
    }

    /// Scroll so the caret is visible.
    fn revealCaret(self: *Editor, u: *Ui, area: Rect) void {
        const lh = self.lineHeight(u);
        const li = self.lineIndexOf(self.cursor);
        const top = @as(f32, @floatFromInt(li)) * lh + pad_top;
        const h: f32 = @floatFromInt(area.h);
        if (top - 8 < self.scroll_y) self.scroll_y = top - 8;
        if (top + lh + 12 > self.scroll_y + h) self.scroll_y = top + lh + 12 - h;
        if (!self.style.wrap and self.lines.items.len > 0) {
            const x = self.xOf(li, self.cursor);
            const view_w = @as(f32, @floatFromInt(area.w)) - 2 * pad_x;
            if (x < self.scroll_x) self.scroll_x = @max(0, x - 40);
            if (x > self.scroll_x + view_w - 4) self.scroll_x = x - view_w + 40;
        }
    }

    pub fn draw(self: *Editor, u: *Ui, area: Rect, colors: Colors, focused: bool) void {
        const f = self.cur_face.?;
        const lh = self.lineHeight(u);
        if (self.reveal) {
            self.reveal = false;
            self.revealCaret(u, area);
        }
        self.clampScroll(u, area);
        u.fillRect(area, colors.bg);
        const old = u.pushClip(area);
        defer u.popClip(old);

        var sel = self.selection();
        // The current find match is shown in its own colour instead.
        if (self.highlight_current) |ci| {
            if (ci < self.highlights.len and self.highlights[ci].a == sel.a and self.highlights[ci].b == sel.b) sel.b = sel.a;
        }
        const x0 = @as(f32, @floatFromInt(area.x)) + pad_x - self.scroll_x;
        const n = self.lines.items.len;
        const first: usize = @intFromFloat(@max(0, @floor((self.scroll_y - pad_top) / lh)));
        const ascent_off = @round((lh - f.line_height) / 2 + f.ascent);
        var li = @min(first, n);
        const space_w = f.measure(" ");
        while (li < n) : (li += 1) {
            const l = self.lines.items[li];
            const top = @as(f32, @floatFromInt(area.y)) + pad_top + @as(f32, @floatFromInt(li)) * lh - self.scroll_y;
            if (top > @as(f32, @floatFromInt(area.bottom()))) break;
            const line_text = self.text.items[l.start..l.end];
            // Selection background.
            const next_start: usize = if (li + 1 < n) self.lines.items[li + 1].start else self.text.items.len;
            // Find matches.
            if (self.highlights.len > 0) {
                const hs = find.overlapping(self.highlights, l.start, @max(l.end, next_start));
                const base = @intFromPtr(self.highlights.ptr);
                for (hs) |*h| {
                    const idx = (@intFromPtr(h) - base) / @sizeOf(Span);
                    const a = @max(h.a, l.start);
                    const b = @min(h.b, l.end);
                    if (b <= a) continue;
                    const xa = f.measure(self.text.items[l.start..a]);
                    const xb = f.measure(self.text.items[l.start..b]);
                    const r = Rect.init(@intFromFloat(@floor(x0 + xa - 1)), @intFromFloat(@floor(top + 1)), @intFromFloat(@ceil(xb - xa + 2)), @intFromFloat(lh - 2));
                    u.fillRound(r, 3, if (self.highlight_current == idx) colors.find_current else colors.find);
                }
            }
            if (sel.a != sel.b and sel.a < @max(next_start, l.end + 1) and sel.b > l.start) {
                const a = @max(sel.a, l.start);
                const b = @min(sel.b, @max(l.end, next_start));
                var xa = f.measure(self.text.items[l.start..@min(a, l.end)]);
                if (a > l.end) xa = f.measure(line_text);
                var xb = f.measure(self.text.items[l.start..@min(b, l.end)]);
                // The line break itself is selected: extend a bit (like macOS).
                if (sel.b > l.end and next_start > l.end) xb = @max(xb, f.measure(line_text) + space_w);
                if (xb > xa) {
                    const r = Rect.init(@intFromFloat(@floor(x0 + xa)), @intFromFloat(@floor(top)), @intFromFloat(@ceil(xb - xa)), @intFromFloat(lh));
                    u.fillRect(r, colors.selection);
                }
            }
            if (line_text.len > 0) _ = u.textAt(x0, @round(top + ascent_off), line_text, if (self.style.mono) .mono else .regular, self.style.size, colors.text);
        }

        // Caret.
        if (focused and sel.a == sel.b and n > 0) {
            const cl = self.lineIndexOf(self.cursor);
            const top = @as(f32, @floatFromInt(area.y)) + pad_top + @as(f32, @floatFromInt(cl)) * lh - self.scroll_y;
            const cx = x0 + self.xOf(cl, self.cursor);
            const ch = @round(f.ascent + f.descent) + 2;
            u.fillRect(Rect.init(@intFromFloat(@round(cx)), @intFromFloat(@round(top + (lh - ch) / 2)), 2, @intFromFloat(ch)), colors.caret);
        }

        // Overlay scroll bar.
        const content = self.contentHeight(u);
        const view: f32 = @floatFromInt(area.h);
        if (content > view + 1) {
            const bar_h = @max(28, view * view / content);
            const pos = (self.scroll_y / (content - view)) * (view - bar_h - 8);
            u.fillRound(Rect.init(area.right() - 9, area.y + 4 + @as(i32, @intFromFloat(pos)), 5, @intFromFloat(bar_h)), 2.5, colors.scrollbar);
        }
    }
};

fn paraStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

fn paraEnd(s: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, s, @min(i, s.len), '\n') orelse s.len;
}

test "undo coalescing and relayout" {
    var fonts = ui.FontSet.load(std.testing.allocator) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer win.close();
    var u = ui.Ui.init(std.testing.allocator, &win, &fonts);
    defer u.deinit();
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.setText("hello world\nsecond line");
    e.ensureLayout(&u, 1000);
    try std.testing.expectEqual(@as(usize, 2), e.lines.items.len);
    e.moveCaret(5, false);
    e.insertText(",", .typing);
    e.insertText(" big", .typing);
    try std.testing.expectEqualStrings("hello, big world\nsecond line", e.bytes());
    try std.testing.expect(e.isDirty());
    e.undo();
    try std.testing.expectEqualStrings("hello world\nsecond line", e.bytes());
    try std.testing.expect(!e.isDirty());
    e.redo();
    try std.testing.expectEqualStrings("hello, big world\nsecond line", e.bytes());
    // Join lines by deleting the newline: layout follows.
    e.moveCaret(17, false);
    e.deleteBackward(.char);
    try std.testing.expectEqualStrings("hello, big worldsecond line", e.bytes());
    try std.testing.expectEqual(@as(usize, 1), e.lines.items.len);
    e.insertText("\n\n", .typing);
    try std.testing.expectEqual(@as(usize, 3), e.lines.items.len);
    try std.testing.expectEqual(@as(u32, 18), e.lines.items[2].start);
    // Wrapped layout.
    e.ensureLayout(&u, 60);
    try std.testing.expect(e.lines.items.len > 3);
    const w = e.wordAt(2);
    try std.testing.expectEqualStrings("hello", e.bytes()[w.a..w.b]);
    // UTF-8: moving over a multi-byte character.
    try e.setText("añb");
    e.ensureLayout(&u, 1000);
    e.moveCaret(1, false);
    e.moveCaret(e.moveBy(1, .char, true), false);
    try std.testing.expectEqual(@as(usize, 3), e.cursor);
    const cnt = e.counts();
    try std.testing.expectEqual(@as(usize, 3), cnt.chars);
}
