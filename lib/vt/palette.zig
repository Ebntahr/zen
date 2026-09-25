//! 256-color xterm palette and helpers to resolve cell colors to RGB for a
//! given theme (so the app can offer light and dark appearances).

const std = @import("std");
const cell_mod = @import("cell.zig");
const Color = cell_mod.Color;
const Cell = cell_mod.Cell;

pub const Rgb = [3]u8;

/// The classic xterm 16 ANSI colors.
pub const xterm_ansi: [16]Rgb = .{
    .{ 0x00, 0x00, 0x00 }, .{ 0xcd, 0x00, 0x00 }, .{ 0x00, 0xcd, 0x00 }, .{ 0xcd, 0xcd, 0x00 },
    .{ 0x00, 0x00, 0xee }, .{ 0xcd, 0x00, 0xcd }, .{ 0x00, 0xcd, 0xcd }, .{ 0xe5, 0xe5, 0xe5 },
    .{ 0x7f, 0x7f, 0x7f }, .{ 0xff, 0x00, 0x00 }, .{ 0x00, 0xff, 0x00 }, .{ 0xff, 0xff, 0x00 },
    .{ 0x5c, 0x5c, 0xff }, .{ 0xff, 0x00, 0xff }, .{ 0x00, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
};

/// The macOS Terminal.app 16 ANSI colors.
pub const macos_ansi: [16]Rgb = .{
    .{ 0, 0, 0 },       .{ 194, 54, 33 },  .{ 37, 188, 36 },  .{ 173, 173, 39 },
    .{ 73, 46, 225 },   .{ 211, 56, 211 }, .{ 51, 187, 200 }, .{ 203, 204, 205 },
    .{ 129, 131, 131 }, .{ 252, 57, 31 },  .{ 49, 231, 34 },  .{ 234, 236, 35 },
    .{ 88, 51, 255 },   .{ 249, 53, 248 }, .{ 20, 240, 240 }, .{ 233, 235, 235 },
};

/// Default xterm 256-color palette: 16 ANSI, 6x6x6 cube, 24 grays.
pub const default_palette: [256]Rgb = blk: {
    var p: [256]Rgb = undefined;
    for (0..16) |i| p[i] = xterm_ansi[i];
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    for (0..216) |i| {
        p[16 + i] = .{ levels[i / 36], levels[(i / 6) % 6], levels[i % 6] };
    }
    for (0..24) |i| {
        const v: u8 = @intCast(8 + i * 10);
        p[232 + i] = .{ v, v, v };
    }
    break :blk p;
};

pub const Theme = struct {
    fg: Rgb,
    bg: Rgb,
    cursor: Rgb,
    selection_bg: Rgb,
    /// Colors 0-15. Colors 16-255 always come from `default_palette`.
    ansi: [16]Rgb,
    /// Render bold text in colors 0-7 using the bright variants 8-15.
    bold_is_bright: bool = false,

    pub const dark: Theme = .{
        .fg = .{ 0xe6, 0xe6, 0xe6 },
        .bg = .{ 0x1e, 0x1e, 0x1e },
        .cursor = .{ 0xc7, 0xc7, 0xc7 },
        .selection_bg = .{ 0x3f, 0x63, 0x8b },
        .ansi = macos_ansi,
    };

    pub const light: Theme = .{
        .fg = .{ 0x00, 0x00, 0x00 },
        .bg = .{ 0xff, 0xff, 0xff },
        .cursor = .{ 0x7f, 0x7f, 0x7f },
        .selection_bg = .{ 0xb4, 0xd5, 0xfe },
        .ansi = macos_ansi,
    };

    pub fn paletteColor(self: *const Theme, index: u8) Rgb {
        return if (index < 16) self.ansi[index] else default_palette[index];
    }

    /// Resolve a color; `is_fg` picks which default to use for `.default`.
    pub fn resolve(self: *const Theme, color: Color, is_fg: bool) Rgb {
        return switch (color) {
            .default => if (is_fg) self.fg else self.bg,
            .indexed => |i| self.paletteColor(i),
            .rgb => |c| c,
        };
    }

    /// Final colors to paint a cell with, applying bold-as-bright, dim,
    /// inverse, hidden and screen-wide reverse video (DECSCNM).
    pub fn resolveCell(self: *const Theme, c: Cell, reverse_video: bool) CellColors {
        var fg_color = c.fg;
        if (self.bold_is_bright and c.attrs.bold) {
            if (fg_color == .indexed and fg_color.indexed < 8) fg_color = .{ .indexed = fg_color.indexed + 8 };
        }
        var fg = self.resolve(fg_color, true);
        var bg = self.resolve(c.bg, false);
        if (reverse_video) {
            if (c.fg == .default) fg = self.bg;
            if (c.bg == .default) bg = self.fg;
        }
        if (c.attrs.dim) fg = blend(fg, bg, 1, 2);
        if (c.attrs.inverse) std.mem.swap(Rgb, &fg, &bg);
        if (c.attrs.hidden) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }
};

pub const CellColors = struct { fg: Rgb, bg: Rgb };

/// Mix `a` toward `b` by num/den.
pub fn blend(a: Rgb, b: Rgb, num: u16, den: u16) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| {
        const av: u32 = a[i];
        const bv: u32 = b[i];
        out[i] = @intCast((av * (den - num) + bv * num) / den);
    }
    return out;
}

test "palette cube and grays" {
    const t = std.testing;
    try t.expectEqual(Rgb{ 0, 0, 0 }, default_palette[16]);
    try t.expectEqual(Rgb{ 255, 255, 255 }, default_palette[231]);
    try t.expectEqual(Rgb{ 255, 0, 0 }, default_palette[196]);
    try t.expectEqual(Rgb{ 0, 95, 135 }, default_palette[24]);
    try t.expectEqual(Rgb{ 8, 8, 8 }, default_palette[232]);
    try t.expectEqual(Rgb{ 238, 238, 238 }, default_palette[255]);
    try t.expectEqual(Rgb{ 0xcd, 0, 0 }, default_palette[1]);
}

test "theme resolve" {
    const t = std.testing;
    const th = Theme.light;
    try t.expectEqual(th.fg, th.resolve(.default, true));
    try t.expectEqual(th.bg, th.resolve(.default, false));
    try t.expectEqual(Rgb{ 1, 2, 3 }, th.resolve(.{ .rgb = .{ 1, 2, 3 } }, true));
    try t.expectEqual(macos_ansi[1], th.resolve(.{ .indexed = 1 }, true));
    try t.expectEqual(default_palette[100], th.resolve(.{ .indexed = 100 }, false));

    var c: Cell = .{ .cp = 'x', .fg = .{ .indexed = 1 } };
    c.attrs.inverse = true;
    const r = th.resolveCell(c, false);
    try t.expectEqual(th.bg, r.fg);
    try t.expectEqual(macos_ansi[1], r.bg);

    const rv = Theme.dark.resolveCell(.{ .cp = 'x' }, true);
    try t.expectEqual(Theme.dark.bg, rv.fg);
    try t.expectEqual(Theme.dark.fg, rv.bg);

    var bb = Theme.dark;
    bb.bold_is_bright = true;
    var bc: Cell = .{ .cp = 'x', .fg = .{ .indexed = 2 } };
    bc.attrs.bold = true;
    try t.expectEqual(macos_ansi[10], bb.resolveCell(bc, false).fg);

    var hc: Cell = .{ .cp = 'x', .bg = .{ .indexed = 4 } };
    hc.attrs.hidden = true;
    const hr = th.resolveCell(hc, false);
    try t.expectEqual(hr.bg, hr.fg);
}
