//! Grid storage: a fixed-size screen of rows and the scrollback ring buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;

pub const Row = struct {
    cells: []Cell,
    /// This row was soft-wrapped: its text continues on the next row.
    wrapped: bool = false,
};

/// A screen grid. Rows are slices into one backing buffer; scrolling rotates
/// the `rows` array so no cell data is copied.
pub const Screen = struct {
    buf: []Cell,
    rows: []Row,
    cols: usize,

    pub fn init(allocator: Allocator, cols: usize, nrows: usize) !Screen {
        const buf = try allocator.alloc(Cell, cols * nrows);
        errdefer allocator.free(buf);
        const rows = try allocator.alloc(Row, nrows);
        @memset(buf, Cell.blank);
        for (rows, 0..) |*r, i| r.* = .{ .cells = buf[i * cols ..][0..cols] };
        return .{ .buf = buf, .rows = rows, .cols = cols };
    }

    pub fn deinit(self: *Screen, allocator: Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn clearRow(self: *Screen, r: usize, blank: Cell) void {
        @memset(self.rows[r].cells, blank);
        self.rows[r].wrapped = false;
    }

    pub fn clear(self: *Screen, blank: Cell) void {
        for (0..self.rows.len) |r| self.clearRow(r, blank);
    }

    /// Index of the last row that has visible content or is wrapped, or null.
    pub fn lastContentRow(self: *const Screen) ?usize {
        var r = self.rows.len;
        while (r > 0) {
            r -= 1;
            if (self.rows[r].wrapped or cell_mod.trimmedLen(self.rows[r].cells) > 0) return r;
        }
        return null;
    }
};

/// Ring buffer of lines that scrolled off the top of the primary screen.
/// Lines are stored with trailing empty cells trimmed (unless soft-wrapped),
/// so their length may differ from the current terminal width.
pub const Scrollback = struct {
    slots: []Line = &.{},
    cap: usize = 0,
    head: usize = 0,
    len: usize = 0,

    pub const Line = struct {
        buf: []Cell = &.{},
        len: usize = 0,
        wrapped: bool = false,

        pub fn cells(self: *const Line) []const Cell {
            return self.buf[0..self.len];
        }

        pub fn free(self: *Line, allocator: Allocator) void {
            if (self.buf.len > 0) allocator.free(self.buf);
            self.* = .{};
        }
    };

    pub fn init(allocator: Allocator, cap: usize) !Scrollback {
        const slots = try allocator.alloc(Line, cap);
        @memset(slots, .{});
        return .{ .slots = slots, .cap = cap };
    }

    pub fn deinit(self: *Scrollback, allocator: Allocator) void {
        for (self.slots) |*l| l.free(allocator);
        allocator.free(self.slots);
        self.* = .{};
    }

    fn slot(self: *const Scrollback, i: usize) usize {
        return (self.head + i) % self.cap;
    }

    /// Line `i`, where 0 is the oldest line.
    pub fn get(self: *const Scrollback, i: usize) *const Line {
        return &self.slots[self.slot(i)];
    }

    /// Next slot to write, evicting the oldest line when full.
    fn nextSlot(self: *Scrollback) *Line {
        if (self.len < self.cap) {
            const s = &self.slots[self.slot(self.len)];
            self.len += 1;
            return s;
        }
        const s = &self.slots[self.head];
        self.head = (self.head + 1) % self.cap;
        return s;
    }

    /// Copy a line in (trimming trailing empty cells unless `wrapped`).
    /// Allocation failure stores an empty line rather than failing.
    pub fn push(self: *Scrollback, allocator: Allocator, line_cells: []const Cell, wrapped: bool) void {
        if (self.cap == 0) return;
        const n = if (wrapped) line_cells.len else cell_mod.trimmedLen(line_cells);
        const s = self.nextSlot();
        s.wrapped = wrapped;
        if (s.buf.len < n) {
            if (s.buf.len > 0) allocator.free(s.buf);
            s.buf = allocator.alloc(Cell, n) catch {
                s.buf = &.{};
                s.len = 0;
                return;
            };
        }
        @memcpy(s.buf[0..n], line_cells[0..n]);
        s.len = n;
    }

    /// Store a line, taking ownership of its buffer.
    pub fn pushOwned(self: *Scrollback, allocator: Allocator, line: Line) void {
        if (self.cap == 0) {
            var l = line;
            l.free(allocator);
            return;
        }
        const s = self.nextSlot();
        s.free(allocator);
        s.* = line;
    }

    /// Remove the newest line, transferring ownership to the caller.
    pub fn popNewest(self: *Scrollback) ?Line {
        if (self.len == 0) return null;
        const s = &self.slots[self.slot(self.len - 1)];
        const l = s.*;
        s.* = .{};
        self.len -= 1;
        return l;
    }

    /// Remove the oldest line, transferring ownership to the caller.
    pub fn popOldest(self: *Scrollback) ?Line {
        if (self.len == 0) return null;
        const s = &self.slots[self.head];
        const l = s.*;
        s.* = .{};
        self.head = (self.head + 1) % self.cap;
        self.len -= 1;
        return l;
    }

    pub fn clear(self: *Scrollback, allocator: Allocator) void {
        for (self.slots) |*l| l.free(allocator);
        self.head = 0;
        self.len = 0;
    }

    /// Reduce the logical capacity to `new_cap` (<= slots.len), keeping the
    /// newest lines. The slot array itself is not reallocated.
    pub fn shrinkTo(self: *Scrollback, allocator: Allocator, new_cap: usize) void {
        std.debug.assert(new_cap <= self.slots.len);
        while (self.len > new_cap) {
            var l = self.popOldest().?;
            l.free(allocator);
        }
        if (self.cap > 0) std.mem.rotate(Line, self.slots[0..self.cap], self.head);
        self.head = 0;
        self.cap = new_cap;
    }
};

test "scrollback ring push/evict/pop" {
    const a = std.testing.allocator;
    var sb = try Scrollback.init(a, 3);
    defer sb.deinit(a);
    var cells: [4]Cell = .{ .{ .cp = 'a' }, .{ .cp = 'b' }, .{}, .{} };
    sb.push(a, &cells, false);
    try std.testing.expectEqual(@as(usize, 2), sb.get(0).len);
    for (0..4) |i| {
        cells[0].cp = @intCast('0' + i);
        sb.push(a, &cells, i == 3);
    }
    try std.testing.expectEqual(@as(usize, 3), sb.len);
    try std.testing.expectEqual(@as(u21, '1'), sb.get(0).cells()[0].cp);
    try std.testing.expectEqual(@as(u21, '3'), sb.get(2).cells()[0].cp);
    try std.testing.expect(sb.get(2).wrapped);
    try std.testing.expectEqual(@as(usize, 4), sb.get(2).len);
    var l = sb.popNewest().?;
    l.free(a);
    try std.testing.expectEqual(@as(usize, 2), sb.len);
    sb.shrinkTo(a, 1);
    try std.testing.expectEqual(@as(usize, 1), sb.len);
    try std.testing.expectEqual(@as(u21, '2'), sb.get(0).cells()[0].cp);
    var empty = try Scrollback.init(a, 0);
    defer empty.deinit(a);
    empty.push(a, &cells, false);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "screen init and content row" {
    const a = std.testing.allocator;
    var s = try Screen.init(a, 5, 3);
    defer s.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), s.lastContentRow());
    s.rows[1].cells[2].cp = 'x';
    try std.testing.expectEqual(@as(?usize, 1), s.lastContentRow());
    std.mem.rotate(Row, s.rows, 1);
    try std.testing.expectEqual(@as(?usize, 0), s.lastContentRow());
}
