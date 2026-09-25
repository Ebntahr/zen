//! Cell model shared by the terminal grid, scrollback and renderer.

const std = @import("std");

/// A cell color. `default` means "use the theme's default fg/bg".
pub const Color = union(enum) {
    default,
    /// Index into the 256-color palette (0-15 are the ANSI/bright colors).
    indexed: u8,
    rgb: [3]u8,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |i| b == .indexed and b.indexed == i,
            .rgb => |c| b == .rgb and std.mem.eql(u8, &c, &b.rgb),
        };
    }
};

/// Per-cell rendition flags. `wide` marks the first cell of a double-width
/// character; `wide_spacer` marks the cell to its right (which the renderer
/// must skip). A `wide_spacer` in the last column *without* a wide head to its
/// left is a "wrap spacer": a wide char did not fit and was moved to the next
/// line; it renders as blank and is ignored by text extraction/reflow.
pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    wide: bool = false,
    wide_spacer: bool = false,
    _pad: u6 = 0,

    pub fn eql(a: Attrs, b: Attrs) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub const blank: Cell = .{};

    pub fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
    }

    /// True if the cell shows nothing at all with default colors: used to trim
    /// trailing cells (scrollback storage, reflow, copy).
    pub fn isEmpty(c: Cell) bool {
        if (c.cp != ' ' and c.cp != 0) return false;
        if (c.bg != .default) return false;
        return !(c.attrs.inverse or c.attrs.underline or c.attrs.strike or c.attrs.wide);
    }
};

/// Length of `cells` with trailing empty cells removed.
pub fn trimmedLen(cells: []const Cell) usize {
    var n = cells.len;
    while (n > 0 and cells[n - 1].isEmpty()) n -= 1;
    // Never separate a wide character from its spacer.
    if (n > 0 and n < cells.len and cells[n - 1].attrs.wide) n += 1;
    return n;
}

test "cell defaults and equality" {
    const a: Cell = .{};
    try std.testing.expect(a.isEmpty());
    try std.testing.expect(a.eql(Cell.blank));
    const b: Cell = .{ .cp = 'x', .fg = .{ .indexed = 3 } };
    try std.testing.expect(!b.isEmpty());
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(Color.eql(.{ .rgb = .{ 1, 2, 3 } }, .{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(!Color.eql(.{ .rgb = .{ 1, 2, 3 } }, .{ .indexed = 1 }));
    const cells = [_]Cell{ b, .{}, .{ .bg = .{ .indexed = 1 } }, .{}, .{} };
    try std.testing.expectEqual(@as(usize, 3), trimmedLen(&cells));
}
