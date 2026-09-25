//! Find and Replace for TextEdit: the search state behind the find bar.
//!
//! Matching ignores ASCII case unless `case_sensitive` is set (Arabic and
//! most other scripts have no case). Matches never overlap and are kept
//! sorted, so the editor can draw them with a binary search per line.

const std = @import("std");
const editor_mod = @import("editor.zig");

const Editor = editor_mod.Editor;
const Span = editor_mod.Span;

/// Enough for any realistic search; beyond it the count shows "10000+".
pub const max_matches = 10000;

pub const Find = struct {
    matches: std.ArrayList(Span) = .empty,
    /// Index of the match that is selected (or would be next).
    current: ?usize = null,
    case_sensitive: bool = false,
    /// More matches exist than `max_matches`.
    truncated: bool = false,
    // What `matches` was computed for.
    seen_version: u64 = std.math.maxInt(u64),
    seen_query: std.ArrayList(u8) = .empty,
    seen_case: bool = false,

    pub fn deinit(self: *Find, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
        self.seen_query.deinit(allocator);
    }

    /// Recompute the matches if the text or the query changed. The current
    /// match becomes the first one at or after the caret.
    pub fn refresh(self: *Find, allocator: std.mem.Allocator, e: *const Editor, query: []const u8) void {
        if (self.seen_version == e.version and self.seen_case == self.case_sensitive and
            std.mem.eql(u8, self.seen_query.items, query)) return;
        self.seen_version = e.version;
        self.seen_case = self.case_sensitive;
        self.seen_query.clearRetainingCapacity();
        self.seen_query.appendSlice(allocator, query) catch {};
        self.truncated = findAll(allocator, e.bytes(), query, self.case_sensitive, &self.matches);
        self.current = self.indexFrom(e.selection().a);
    }

    /// The first match starting at or after `pos` (wrapping to the first).
    fn indexFrom(self: *const Find, pos: usize) ?usize {
        const m = self.matches.items;
        if (m.len == 0) return null;
        const i = lowerBound(m, pos);
        return if (i < m.len) i else 0;
    }

    /// Select the next (or previous) match after the selection, wrapping
    /// around. Returns false when there is none.
    pub fn step(self: *Find, e: *Editor, forward: bool) bool {
        const m = self.matches.items;
        if (m.len == 0) return false;
        const sel = e.selection();
        const i: usize = if (forward) blk: {
            // Past the selection: a match equal to it is the current one.
            const j = lowerBound(m, if (sel.a == sel.b) sel.a else sel.a + 1);
            break :blk if (j < m.len) j else 0;
        } else blk: {
            const j = lowerBound(m, sel.a);
            break :blk if (j > 0) j - 1 else m.len - 1;
        };
        self.select(e, i);
        return true;
    }

    pub fn select(self: *Find, e: *Editor, i: usize) void {
        const s = self.matches.items[i];
        e.anchor = s.a;
        e.cursor = s.b;
        e.goal_x = null;
        e.reveal = true;
        self.current = i;
    }

    /// The selection is exactly the current match.
    pub fn selectionIsMatch(self: *const Find, e: *const Editor) bool {
        const i = self.current orelse return false;
        if (i >= self.matches.items.len) return false;
        const s = self.matches.items[i];
        const sel = e.selection();
        return sel.a == s.a and sel.b == s.b;
    }

    /// Replace the selected match and select the next one. If no match is
    /// selected, just select the next one (like macOS).
    pub fn replaceOne(self: *Find, allocator: std.mem.Allocator, e: *Editor, query: []const u8, with: []const u8) void {
        if (self.selectionIsMatch(e)) {
            const s = self.matches.items[self.current.?];
            e.replace(s.a, s.b, with, .other);
            self.refresh(allocator, e, query);
        }
        _ = self.step(e, true);
    }

    /// Replace every match as a single undoable edit. Returns the count.
    pub fn replaceAll(self: *Find, allocator: std.mem.Allocator, e: *Editor, query: []const u8, with: []const u8) usize {
        self.refresh(allocator, e, query);
        var total: usize = 0;
        // Repeat while the list was truncated (each pass removes matches).
        while (self.matches.items.len > 0) {
            const m = self.matches.items;
            const first = m[0].a;
            const last = m[m.len - 1].b;
            const text = e.bytes();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            var pos = first;
            for (m) |s| {
                out.appendSlice(allocator, text[pos..s.a]) catch return total;
                out.appendSlice(allocator, with) catch return total;
                pos = s.b;
            }
            e.replace(first, last, out.items, .other);
            total += m.len;
            const more = self.truncated;
            self.refresh(allocator, e, query);
            // The replacement itself may contain the query: stop after
            // the first pass unless matches were left unreplaced.
            if (!more) break;
        }
        return total;
    }
};

fn lowerBound(m: []const Span, pos: usize) usize {
    var lo: usize = 0;
    var hi: usize = m.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (m[mid].a < pos) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// All non-overlapping matches of `query` in `text`. Returns true if the
/// list stopped at `max_matches`.
pub fn findAll(allocator: std.mem.Allocator, text: []const u8, query: []const u8, case_sensitive: bool, out: *std.ArrayList(Span)) bool {
    out.clearRetainingCapacity();
    if (query.len == 0 or query.len > text.len) return false;
    var i: usize = 0;
    const last = text.len - query.len;
    const first = query[0];
    const first_lower = std.ascii.toLower(first);
    while (i <= last) {
        const c = text[i];
        const hit = if (case_sensitive) c == first else std.ascii.toLower(c) == first_lower;
        if (hit and eqlAt(text[i..][0..query.len], query, case_sensitive)) {
            if (out.items.len >= max_matches) return true;
            out.append(allocator, .{ .a = i, .b = i + query.len }) catch return true;
            i += query.len;
        } else i += 1;
    }
    return false;
}

fn eqlAt(a: []const u8, b: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.eql(u8, a, b);
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Matches overlapping `[a, b)`, for drawing one line.
pub fn overlapping(m: []const Span, a: usize, b: usize) []const Span {
    // Matches are sorted and disjoint, so their ends are sorted too.
    var lo: usize = 0;
    var hi: usize = m.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (m[mid].b <= a) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < m.len and m[end].a < b) end += 1;
    return m[lo..end];
}

test "find all, case and overlap" {
    const a = std.testing.allocator;
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(a);
    _ = findAll(a, "Zen zen ZEN zeN", "zen", false, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    _ = findAll(a, "Zen zen ZEN zeN", "zen", true, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(usize, 4), out.items[0].a);
    // Non-overlapping: "aaaa" has two matches of "aa".
    _ = findAll(a, "aaaa", "aa", false, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // UTF-8 (Arabic) matches byte for byte.
    _ = findAll(a, "مرحبا يا عالم، مرحبا", "مرحبا", false, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    _ = findAll(a, "short", "longer than text", false, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    const m = [_]Span{ .{ .a = 0, .b = 3 }, .{ .a = 10, .b = 13 }, .{ .a = 20, .b = 23 } };
    try std.testing.expectEqual(@as(usize, 1), overlapping(&m, 5, 12).len);
    try std.testing.expectEqual(@as(usize, 2), overlapping(&m, 2, 11).len);
    try std.testing.expectEqual(@as(usize, 0), overlapping(&m, 14, 19).len);
}

test "step, replace and replace all" {
    const a = std.testing.allocator;
    var e = Editor.init(a);
    defer e.deinit();
    try e.setText("one fish two fish red fish");
    var f = Find{};
    defer f.deinit(a);
    f.refresh(a, &e, "fish");
    try std.testing.expectEqual(@as(usize, 3), f.matches.items.len);
    try std.testing.expect(f.step(&e, true));
    try std.testing.expectEqualStrings("fish", e.selectedText());
    try std.testing.expectEqual(@as(usize, 4), e.selection().a);
    try std.testing.expect(f.step(&e, true));
    try std.testing.expectEqual(@as(usize, 13), e.selection().a);
    try std.testing.expect(f.step(&e, false));
    try std.testing.expectEqual(@as(usize, 4), e.selection().a);
    // Previous from the first wraps to the last.
    try std.testing.expect(f.step(&e, false));
    try std.testing.expectEqual(@as(usize, 22), e.selection().a);

    // Replace the selected match; the next one gets selected.
    e.anchor = 4;
    e.cursor = 8;
    f.refresh(a, &e, "fish");
    f.current = 0;
    f.replaceOne(a, &e, "fish", "cat");
    try std.testing.expectEqualStrings("one cat two fish red fish", e.bytes());
    try std.testing.expectEqual(@as(usize, 12), e.selection().a);

    // Replace all is one undo step, and the replacement may contain the query.
    try std.testing.expectEqual(@as(usize, 2), f.replaceAll(a, &e, "fish", "big fish"));
    try std.testing.expectEqualStrings("one cat two big fish red big fish", e.bytes());
    e.undo();
    try std.testing.expectEqualStrings("one cat two fish red fish", e.bytes());
    f.refresh(a, &e, "FISH");
    try std.testing.expectEqual(@as(usize, 2), f.matches.items.len);
    f.case_sensitive = true;
    f.refresh(a, &e, "FISH");
    try std.testing.expectEqual(@as(usize, 0), f.matches.items.len);
    try std.testing.expect(!f.step(&e, true));
}
