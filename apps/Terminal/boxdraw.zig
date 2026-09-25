//! Procedural rendering of box-drawing lines (U+2500-U+257F) and block
//! elements (U+2580-U+259F) so they fill the cell exactly and join
//! seamlessly between rows and columns, independent of the font's line
//! height. Characters not handled here (dashed and double lines, arcs,
//! diagonals) are drawn from the font.

const std = @import("std");
const gfx = @import("gfx");

const Canvas = gfx.Canvas;
const Rect = gfx.Rect;
const Color = gfx.Color;

/// Arm weights for U+2500-U+257F as "urdl" (0 none, 1 light, 2 heavy);
/// null = draw from the font.
const box_table = blk: {
    const S = ?*const [4]u8;
    var t = [_]S{null} ** 128;
    const entries = [_]struct { u21, *const [4]u8 }{
        .{ 0x2500, "0101" }, .{ 0x2501, "0202" }, .{ 0x2502, "1010" }, .{ 0x2503, "2020" },
        .{ 0x250C, "0110" }, .{ 0x250D, "0210" }, .{ 0x250E, "0120" }, .{ 0x250F, "0220" },
        .{ 0x2510, "0011" }, .{ 0x2511, "0012" }, .{ 0x2512, "0021" }, .{ 0x2513, "0022" },
        .{ 0x2514, "1100" }, .{ 0x2515, "1200" }, .{ 0x2516, "2100" }, .{ 0x2517, "2200" },
        .{ 0x2518, "1001" }, .{ 0x2519, "1002" }, .{ 0x251A, "2001" }, .{ 0x251B, "2002" },
        .{ 0x251C, "1110" }, .{ 0x251D, "1210" }, .{ 0x251E, "2110" }, .{ 0x251F, "1120" },
        .{ 0x2520, "2120" }, .{ 0x2521, "2210" }, .{ 0x2522, "1220" }, .{ 0x2523, "2220" },
        .{ 0x2524, "1011" }, .{ 0x2525, "1012" }, .{ 0x2526, "2011" }, .{ 0x2527, "1021" },
        .{ 0x2528, "2021" }, .{ 0x2529, "2012" }, .{ 0x252A, "1022" }, .{ 0x252B, "2022" },
        .{ 0x252C, "0111" }, .{ 0x252D, "0112" }, .{ 0x252E, "0211" }, .{ 0x252F, "0212" },
        .{ 0x2530, "0121" }, .{ 0x2531, "0122" }, .{ 0x2532, "0221" }, .{ 0x2533, "0222" },
        .{ 0x2534, "1101" }, .{ 0x2535, "1102" }, .{ 0x2536, "1201" }, .{ 0x2537, "1202" },
        .{ 0x2538, "2101" }, .{ 0x2539, "2102" }, .{ 0x253A, "2201" }, .{ 0x253B, "2202" },
        .{ 0x253C, "1111" }, .{ 0x253D, "1112" }, .{ 0x253E, "1211" }, .{ 0x253F, "1212" },
        .{ 0x2540, "2111" }, .{ 0x2541, "1121" }, .{ 0x2542, "2121" }, .{ 0x2543, "2112" },
        .{ 0x2544, "2211" }, .{ 0x2545, "1122" }, .{ 0x2546, "1221" }, .{ 0x2547, "2212" },
        .{ 0x2548, "1222" }, .{ 0x2549, "2122" }, .{ 0x254A, "2221" }, .{ 0x254B, "2222" },
        .{ 0x2574, "0001" }, .{ 0x2575, "1000" }, .{ 0x2576, "0100" }, .{ 0x2577, "0010" },
        .{ 0x2578, "0002" }, .{ 0x2579, "2000" }, .{ 0x257A, "0200" }, .{ 0x257B, "0020" },
        .{ 0x257C, "0201" }, .{ 0x257D, "1020" }, .{ 0x257E, "0102" }, .{ 0x257F, "2010" },
    };
    for (entries) |e| t[e[0] - 0x2500] = e[1];
    break :blk t;
};

/// True if `cp` is drawn by `draw` rather than the font.
pub fn handles(cp: u21) bool {
    if (cp >= 0x2580 and cp <= 0x259F) return true;
    if (cp >= 0x256D and cp <= 0x2570) return true;
    if (cp >= 0x2500 and cp < 0x2580) return box_table[cp - 0x2500] != null;
    return false;
}

/// Draw `cp` into the cell `cell` with premultiplied `color`. Returns false
/// (drawing nothing) for characters the font should render.
pub fn draw(c: Canvas, cp: u21, cell: Rect, color: u32) bool {
    if (cp >= 0x2580 and cp <= 0x259F) {
        drawBlock(c, cp, cell, color);
        return true;
    }
    if (cp >= 0x256D and cp <= 0x2570) {
        drawArc(c, cp, cell, color);
        return true;
    }
    if (cp >= 0x2500 and cp < 0x2580) {
        const arms = box_table[cp - 0x2500] orelse return false;
        drawLines(c, arms, cell, color);
        return true;
    }
    return false;
}

fn part(len: i32, num: i32, den: i32) i32 {
    return @divFloor(len * num + @divFloor(den, 2), den);
}

fn drawBlock(c: Canvas, cp: u21, r: Rect, color: u32) void {
    const w = r.w;
    const h = r.h;
    switch (cp) {
        0x2580 => c.fillRect(Rect.init(r.x, r.y, w, part(h, 1, 2)), color),
        0x2581...0x2587 => {
            const n: i32 = @intCast(cp - 0x2580);
            const bh = part(h, n, 8);
            c.fillRect(Rect.init(r.x, r.bottom() - bh, w, bh), color);
        },
        0x2588 => c.fillRect(r, color),
        0x2589...0x258F => {
            const n: i32 = @intCast(0x2590 - cp);
            c.fillRect(Rect.init(r.x, r.y, part(w, n, 8), h), color);
        },
        0x2590 => {
            const half = part(w, 1, 2);
            c.fillRect(Rect.init(r.x + half, r.y, w - half, h), color);
        },
        0x2591, 0x2592, 0x2593 => {
            const levels = [_]u8{ 64, 128, 192 };
            c.fillRect(r, Color.mulAlpha(color, levels[cp - 0x2591]));
        },
        0x2594 => c.fillRect(Rect.init(r.x, r.y, w, @max(1, part(h, 1, 8))), color),
        0x2595 => {
            const bw = @max(1, part(w, 1, 8));
            c.fillRect(Rect.init(r.right() - bw, r.y, bw, h), color);
        },
        0x2596...0x259F => {
            // Quadrant bits: 1 upper left, 2 upper right, 4 lower left, 8 lower right.
            const quads = [_]u4{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
            const q = quads[cp - 0x2596];
            const hw = part(w, 1, 2);
            const hh = part(h, 1, 2);
            if (q & 1 != 0) c.fillRect(Rect.init(r.x, r.y, hw, hh), color);
            if (q & 2 != 0) c.fillRect(Rect.init(r.x + hw, r.y, w - hw, hh), color);
            if (q & 4 != 0) c.fillRect(Rect.init(r.x, r.y + hh, hw, h - hh), color);
            if (q & 8 != 0) c.fillRect(Rect.init(r.x + hw, r.y + hh, w - hw, h - hh), color);
        },
        else => {},
    }
}

fn lightWidth(r: Rect) i32 {
    return @max(1, @divFloor(r.w + 4, 9));
}

/// Rounded corners ╭ ╮ ╯ ╰: a quarter circle (anti-aliased) joining the
/// centre lines of the two arms, plus the straight rest of the vertical arm.
fn drawArc(c: Canvas, cp: u21, r: Rect, color: u32) void {
    const t = lightWidth(r);
    const lx = r.x + @divFloor(r.w - t, 2); // left edge of the vertical line
    const ly = r.y + @divFloor(r.h - t, 2); // top edge of the horizontal line
    const xc = @as(f32, @floatFromInt(lx)) + @as(f32, @floatFromInt(t)) / 2;
    const yc = @as(f32, @floatFromInt(ly)) + @as(f32, @floatFromInt(t)) / 2;
    const right = cp == 0x256D or cp == 0x2570; // arm goes right (else left)
    const down = cp == 0x256D or cp == 0x256E; // arm goes down (else up)
    const radius = if (right) @as(f32, @floatFromInt(r.right())) - xc else xc - @as(f32, @floatFromInt(r.x));
    const ax = if (right) xc + radius else xc - radius;
    const ay = if (down) yc + radius else yc - radius;
    // Straight part of the vertical arm.
    const ay_i: i32 = @intFromFloat(@round(ay));
    if (down) {
        c.fillRect(Rect.init(lx, ay_i, t, r.bottom() - ay_i), color);
    } else {
        c.fillRect(Rect.init(lx, r.y, t, ay_i - r.y), color);
    }
    // The arc, in the quadrant between the arc centre and the cell centre.
    const half = @as(f32, @floatFromInt(t)) / 2;
    const x0: i32 = if (right) r.x else @intFromFloat(@floor(ax));
    const x1: i32 = if (right) @intFromFloat(@ceil(ax)) else r.right();
    const y0: i32 = if (down) @intFromFloat(@floor(yc - half - 1)) else @intFromFloat(@floor(ay));
    const y1: i32 = if (down) @intFromFloat(@ceil(ay)) else @intFromFloat(@ceil(yc + half + 1));
    const src = gfx.Source{ .solid = color };
    var y = @max(y0, r.y);
    while (y < @min(y1, r.bottom())) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            if ((right and px > ax) or (!right and px < ax)) continue;
            if ((down and py > ay) or (!down and py < ay)) continue;
            const d = @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
            const cov = std.math.clamp(half + 0.5 - @abs(d - radius), 0, 1);
            if (cov > 0) c.blendPixel(x, y, @intFromFloat(@round(cov * 255)), src);
        }
    }
}

fn drawLines(c: Canvas, arms: *const [4]u8, r: Rect, color: u32) void {
    const light = lightWidth(r);
    const heavy: i32 = light * 2;
    var t: [4]i32 = undefined; // up, right, down, left
    for (arms, 0..) |ch, i| t[i] = switch (ch) {
        '1' => light,
        '2' => heavy,
        else => 0,
    };
    // Thickest crossing line, so arms overlap cleanly at the junction.
    const vmax = @max(t[0], t[2]);
    const hmax = @max(t[1], t[3]);
    const cx2 = r.x * 2 + r.w; // doubled centre coordinates
    const cy2 = r.y * 2 + r.h;
    // Horizontal arms reach across the vertical line (or to the centre).
    for ([_]usize{ 3, 1 }) |i| {
        const th = t[i];
        if (th == 0) continue;
        const y = @divFloor(cy2 - th, 2);
        const span = if (vmax > 0) vmax else th;
        const jx0 = @divFloor(cx2 - span, 2);
        if (i == 3) {
            c.fillRect(Rect.init(r.x, y, jx0 + span - r.x, th), color);
        } else {
            c.fillRect(Rect.init(jx0, y, r.right() - jx0, th), color);
        }
    }
    // Vertical arms.
    for ([_]usize{ 0, 2 }) |i| {
        const th = t[i];
        if (th == 0) continue;
        const x = @divFloor(cx2 - th, 2);
        const span = if (hmax > 0) hmax else th;
        const jy0 = @divFloor(cy2 - span, 2);
        if (i == 0) {
            c.fillRect(Rect.init(x, r.y, th, jy0 + span - r.y), color);
        } else {
            c.fillRect(Rect.init(x, jy0, th, r.bottom() - jy0), color);
        }
    }
}

test "box drawing coverage" {
    try std.testing.expect(handles(0x2500));
    try std.testing.expect(handles(0x2588));
    try std.testing.expect(!handles(0x2550)); // double lines use the font
    try std.testing.expect(!handles('a'));

    var px = [_]u32{0} ** (8 * 16);
    const c = Canvas.init(&px, 8, 16, 8);
    try std.testing.expect(draw(c, 0x2588, Rect.init(0, 0, 8, 16), 0xFFFFFFFF));
    for (px) |p| try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), p);

    @memset(&px, 0);
    try std.testing.expect(draw(c, 0x2500, Rect.init(0, 0, 8, 16), 0xFFFFFFFF));
    // A full-width horizontal line through the middle row(s).
    var lit_rows: usize = 0;
    for (0..16) |y| {
        if (px[y * 8] != 0) {
            lit_rows += 1;
            for (0..8) |x| try std.testing.expect(px[y * 8 + x] != 0);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), lit_rows);

    @memset(&px, 0);
    try std.testing.expect(draw(c, 0x250C, Rect.init(0, 0, 8, 16), 0xFFFFFFFF));
    try std.testing.expect(px[0] == 0); // top-left corner stays empty
    try std.testing.expect(px[15 * 8 + 4] != 0 or px[15 * 8 + 3] != 0); // down arm reaches the bottom
}
