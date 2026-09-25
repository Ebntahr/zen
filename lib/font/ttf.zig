//! TrueType font parsing: table directory, metrics, character mapping,
//! glyph outlines (simple and composite) and kerning (`kern` format 0 and
//! GPOS pair adjustment).
//!
//! `Font` borrows the font file bytes; they must outlive it. All table
//! accesses are bounds-checked, and malformed data produces errors (or, for
//! optional data such as kerning, is ignored) rather than crashing.

const std = @import("std");
const be = @import("be.zig");
const gpos = @import("gpos.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The data is not a well-formed TrueType font (or a glyph is corrupt).
    InvalidFont,
    /// Valid font data using features this engine does not implement
    /// (CFF outlines, font collections, no Unicode cmap).
    UnsupportedFont,
    OutOfMemory,
};

/// An outline point in font units (y up).
pub const Point = struct {
    x: f32,
    y: f32,
    /// On-curve point; off-curve points are quadratic Bézier control points.
    on: bool,
};

/// A glyph outline: TrueType-style contours of on/off-curve points.
/// Reused across glyphs to avoid per-glyph allocations.
pub const Outline = struct {
    points: std.ArrayList(Point) = .empty,
    /// One past the index of the last point of each contour.
    ends: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Outline, allocator: Allocator) void {
        self.points.deinit(allocator);
        self.ends.deinit(allocator);
    }

    pub fn clear(self: *Outline) void {
        self.points.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
    }

    /// Iterates contours as point slices.
    pub fn contours(self: *const Outline) ContourIterator {
        return .{ .outline = self };
    }

    pub const ContourIterator = struct {
        outline: *const Outline,
        index: usize = 0,

        pub fn next(it: *ContourIterator) ?[]Point {
            const ends = it.outline.ends.items;
            if (it.index >= ends.len) return null;
            const start = if (it.index == 0) 0 else ends[it.index - 1];
            it.index += 1;
            return it.outline.points.items[start..ends[it.index - 1]];
        }
    };
};

/// 2x3 affine transform: x' = a*x + c*y + e, y' = b*x + d*y + f.
const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    fn apply(t: Transform, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f };
    }

    /// Returns `outer ∘ inner` (inner applied first).
    fn then(inner: Transform, outer: Transform) Transform {
        return .{
            .a = outer.a * inner.a + outer.c * inner.b,
            .b = outer.b * inner.a + outer.d * inner.b,
            .c = outer.a * inner.c + outer.c * inner.d,
            .d = outer.b * inner.c + outer.d * inner.d,
            .e = outer.a * inner.e + outer.c * inner.f + outer.e,
            .f = outer.b * inner.e + outer.d * inner.f + outer.f,
        };
    }

    fn isMirroring(t: Transform) bool {
        return t.a * t.d - t.b * t.c < 0;
    }
};

/// A selected cmap subtable.
const Cmap = struct {
    format: u16,
    /// The subtable bytes (from its format field).
    data: []const u8,
};

/// Vertical metrics in font units (y up: descender is negative).
pub const Metrics = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    cap_height: i16,
    x_height: i16,
    /// Union of all glyph bounding boxes (from `head`).
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const Font = struct {
    allocator: Allocator,
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    metrics: Metrics,

    loca_long: bool,
    loca: []const u8,
    glyf: []const u8,
    hmtx: []const u8,
    num_hmetrics: u16,
    cmap: Cmap,
    /// `kern` format 0 pair records (6 bytes each), used when GPOS has no kerning.
    kern_pairs: []const u8,
    gpos_kern: gpos.Kerning,

    /// Glyph ids of U+0000..U+007F for fast lookups of ASCII text.
    ascii: [128]u16,
    /// Memoized kerning in font units, keyed by (left << 16 | right).
    kern_cache: std.AutoHashMapUnmanaged(u32, i16) = .empty,

    const max_kern_cache = 1 << 14;
    const max_points = 1 << 16;
    const max_components = 512;
    const max_depth = 8;

    /// Parses a TrueType (glyf-flavored sfnt) font. `data` is borrowed.
    pub fn init(allocator: Allocator, data: []const u8) Error!Font {
        const bad = error.InvalidFont;
        const version = be.u32At(data, 0) orelse return bad;
        switch (version) {
            0x00010000, 0x74727565 => {}, // 1.0, 'true'
            0x4F54544F, 0x74746366 => return error.UnsupportedFont, // 'OTTO' (CFF), 'ttcf'
            else => return bad,
        }

        const head = findTable(data, "head") orelse return bad;
        const hhea = findTable(data, "hhea") orelse return bad;
        const maxp = findTable(data, "maxp") orelse return bad;
        const hmtx = findTable(data, "hmtx") orelse return bad;
        const cmap = findTable(data, "cmap") orelse return bad;
        const loca = findTable(data, "loca") orelse return error.UnsupportedFont;
        const glyf = findTable(data, "glyf") orelse return error.UnsupportedFont;

        if (head.len < 54) return bad;
        const upem = be.u16At(head, 18).?;
        if (upem < 16 or upem > 16384) return bad;
        const loca_long = switch (be.i16At(head, 50).?) {
            0 => false,
            1 => true,
            else => return bad,
        };

        if (hhea.len < 36) return bad;
        var num_glyphs = be.u16At(maxp, 4) orelse return bad;
        // Clamp counts to what the tables can actually hold.
        const loca_entries = loca.len / @as(usize, if (loca_long) 4 else 2);
        if (loca_entries == 0) return bad;
        num_glyphs = @intCast(@min(num_glyphs, loca_entries - 1));
        const num_hmetrics: u16 = @intCast(@min(be.u16At(hhea, 34).?, hmtx.len / 4));
        if (num_glyphs == 0 or num_hmetrics == 0) return bad;

        var metrics: Metrics = .{
            .ascender = be.i16At(hhea, 4).?,
            .descender = be.i16At(hhea, 6).?,
            .line_gap = be.i16At(hhea, 8).?,
            .cap_height = 0,
            .x_height = 0,
            .x_min = be.i16At(head, 36).?,
            .y_min = be.i16At(head, 38).?,
            .x_max = be.i16At(head, 40).?,
            .y_max = be.i16At(head, 42).?,
        };
        if (findTable(data, "OS/2")) |os2| {
            // Typographic metrics are the designer's intended line spacing.
            if (os2.len >= 78) {
                const asc = be.i16At(os2, 68).?;
                const desc = be.i16At(os2, 70).?;
                if (asc > 0 and asc - @as(i32, desc) > 0) {
                    metrics.ascender = asc;
                    metrics.descender = desc;
                    metrics.line_gap = @max(0, be.i16At(os2, 72).?);
                }
            }
            if (os2.len >= 90 and be.u16At(os2, 0).? >= 2) {
                metrics.x_height = be.i16At(os2, 86).?;
                metrics.cap_height = be.i16At(os2, 88).?;
            }
        }

        var font: Font = .{
            .allocator = allocator,
            .data = data,
            .units_per_em = upem,
            .num_glyphs = num_glyphs,
            .metrics = metrics,
            .loca_long = loca_long,
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
            .num_hmetrics = num_hmetrics,
            .cmap = selectCmap(cmap) orelse return error.UnsupportedFont,
            .kern_pairs = if (findTable(data, "kern")) |k| kernPairs(k) else &.{},
            .gpos_kern = .{},
            .ascii = undefined,
        };
        for (&font.ascii, 0..) |*g, cp| g.* = font.cmapLookup(@intCast(cp));

        if (font.metrics.cap_height <= 0) font.metrics.cap_height = font.glyphTop('H') orelse @divTrunc(metrics.ascender, 10) * 7;
        if (font.metrics.x_height <= 0) font.metrics.x_height = font.glyphTop('x') orelse @divTrunc(metrics.ascender, 2);

        if (findTable(data, "GPOS")) |table| font.gpos_kern = try gpos.Kerning.init(allocator, table);
        return font;
    }

    pub fn deinit(self: *Font) void {
        self.gpos_kern.deinit(self.allocator);
        self.kern_cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// Glyph id for a code point, or 0 (.notdef) if the font lacks it.
    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        if (cp < 128) return self.ascii[cp];
        return self.cmapLookup(cp);
    }

    /// Advance width in font units.
    pub fn advanceWidth(self: *const Font, glyph: u16) u16 {
        const i: usize = @min(glyph, self.num_hmetrics - 1);
        return be.u16At(self.hmtx, i * 4).?;
    }

    /// Horizontal kerning in font units to add between `left` and `right`.
    /// Results are memoized; kerning is looked up for every glyph pair drawn.
    pub fn kerning(self: *Font, left: u16, right: u16) i16 {
        if (self.gpos_kern.isEmpty() and self.kern_pairs.len == 0) return 0;
        const key = @as(u32, left) << 16 | right;
        if (self.kern_cache.get(key)) |v| return v;
        const value = self.kerningUncached(left, right);
        if (self.kern_cache.count() >= max_kern_cache) self.kern_cache.clearRetainingCapacity();
        self.kern_cache.put(self.allocator, key, value) catch {}; // cache is optional
        return value;
    }

    fn kerningUncached(self: *const Font, left: u16, right: u16) i16 {
        // Like HarfBuzz, the legacy `kern` table is only used without GPOS kerning.
        const v: i32 = if (!self.gpos_kern.isEmpty())
            self.gpos_kern.get(left, right)
        else
            kernTableLookup(self.kern_pairs, left, right);
        return std.math.cast(i16, v) orelse 0;
    }

    /// Appends the outline of `glyph` (font units, y up) to `out`. Composite
    /// glyphs are flattened with their component transforms applied.
    /// Empty glyphs (e.g. space) append nothing.
    pub fn glyphOutline(self: *const Font, allocator: Allocator, glyph: u16, out: *Outline) Error!void {
        var budget: u32 = max_components;
        const first_point = out.points.items.len;
        const first_contour = out.ends.items.len;
        errdefer {
            out.points.shrinkRetainingCapacity(first_point);
            out.ends.shrinkRetainingCapacity(first_contour);
        }
        try self.appendGlyph(allocator, glyph, .{}, 0, &budget, out);
    }

    /// Returns the raw `glyf` record of a glyph (empty for glyphs without outline).
    fn glyphData(self: *const Font, glyph: u16) Error![]const u8 {
        if (glyph >= self.num_glyphs) return error.InvalidFont;
        const i: usize = glyph;
        const start: usize, const end: usize = if (self.loca_long)
            .{ be.u32At(self.loca, i * 4).?, be.u32At(self.loca, i * 4 + 4).? }
        else
            .{ @as(usize, be.u16At(self.loca, i * 2).?) * 2, @as(usize, be.u16At(self.loca, i * 2 + 2).?) * 2 };
        if (end < start or end > self.glyf.len) return error.InvalidFont;
        return self.glyf[start..end];
    }

    fn appendGlyph(
        self: *const Font,
        allocator: Allocator,
        glyph: u16,
        xf: Transform,
        depth: u32,
        budget: *u32,
        out: *Outline,
    ) Error!void {
        if (budget.* == 0 or depth > max_depth) return error.InvalidFont;
        budget.* -= 1;
        const g = try self.glyphData(glyph);
        if (g.len == 0) return;
        const num_contours = be.i16At(g, 0) orelse return error.InvalidFont;
        if (num_contours >= 0) {
            try appendSimple(allocator, g, @intCast(num_contours), xf, out);
        } else {
            try self.appendComposite(allocator, g, xf, depth, budget, out);
        }
    }

    fn appendComposite(
        self: *const Font,
        allocator: Allocator,
        g: []const u8,
        xf: Transform,
        depth: u32,
        budget: *u32,
        out: *Outline,
    ) Error!void {
        const ARG_WORDS = 0x0001;
        const ARGS_ARE_XY = 0x0002;
        const HAVE_SCALE = 0x0008;
        const MORE = 0x0020;
        const HAVE_XY_SCALE = 0x0040;
        const HAVE_2X2 = 0x0080;
        const SCALED_OFFSET = 0x0800;
        const UNSCALED_OFFSET = 0x1000;
        const bad = error.InvalidFont;

        const base = out.points.items.len; // point numbering for point matching
        var off: usize = 10;
        while (true) {
            const flags = be.u16At(g, off) orelse return bad;
            const component = be.u16At(g, off + 2) orelse return bad;
            off += 4;

            var arg1: i32 = undefined;
            var arg2: i32 = undefined;
            if (flags & ARG_WORDS != 0) {
                if (flags & ARGS_ARE_XY != 0) {
                    arg1 = be.i16At(g, off) orelse return bad;
                    arg2 = be.i16At(g, off + 2) orelse return bad;
                } else {
                    arg1 = be.u16At(g, off) orelse return bad;
                    arg2 = be.u16At(g, off + 2) orelse return bad;
                }
                off += 4;
            } else {
                const b1 = be.u8At(g, off) orelse return bad;
                const b2 = be.u8At(g, off + 1) orelse return bad;
                if (flags & ARGS_ARE_XY != 0) {
                    arg1 = @as(i8, @bitCast(b1));
                    arg2 = @as(i8, @bitCast(b2));
                } else {
                    arg1 = b1;
                    arg2 = b2;
                }
                off += 2;
            }

            var t: Transform = .{};
            if (flags & HAVE_SCALE != 0) {
                t.a = be.f2dot14At(g, off) orelse return bad;
                t.d = t.a;
                off += 2;
            } else if (flags & HAVE_XY_SCALE != 0) {
                t.a = be.f2dot14At(g, off) orelse return bad;
                t.d = be.f2dot14At(g, off + 2) orelse return bad;
                off += 4;
            } else if (flags & HAVE_2X2 != 0) {
                t.a = be.f2dot14At(g, off) orelse return bad;
                t.b = be.f2dot14At(g, off + 2) orelse return bad;
                t.c = be.f2dot14At(g, off + 4) orelse return bad;
                t.d = be.f2dot14At(g, off + 6) orelse return bad;
                off += 8;
            }

            if (flags & ARGS_ARE_XY != 0) {
                const dx: f32 = @floatFromInt(arg1);
                const dy: f32 = @floatFromInt(arg2);
                if (flags & SCALED_OFFSET != 0 and flags & UNSCALED_OFFSET == 0) {
                    t.e = t.a * dx + t.c * dy;
                    t.f = t.b * dx + t.d * dy;
                } else {
                    t.e = dx;
                    t.f = dy;
                }
                try self.appendGlyph(allocator, component, t.then(xf), depth + 1, budget, out);
            } else {
                // Point matching: align child point `arg2` with parent point `arg1`.
                const child_start = out.points.items.len;
                try self.appendGlyph(allocator, component, t.then(xf), depth + 1, budget, out);
                const pts = out.points.items;
                const parent_i = base + @as(usize, @intCast(arg1));
                const child_i = child_start + @as(usize, @intCast(arg2));
                if (parent_i >= child_start or child_i >= pts.len) return bad;
                const dx = pts[parent_i].x - pts[child_i].x;
                const dy = pts[parent_i].y - pts[child_i].y;
                for (pts[child_start..]) |*p| {
                    p.x += dx;
                    p.y += dy;
                }
            }
            if (flags & MORE == 0) break;
        }
    }

    /// Top of a glyph's bounding box (font units), used to estimate metrics.
    fn glyphTop(self: *const Font, cp: u21) ?i16 {
        const g = self.glyphData(self.glyphIndex(cp)) catch return null;
        const top = be.i16At(g, 8) orelse return null;
        return if (top > 0) top else null;
    }

    fn cmapLookup(self: *const Font, cp: u21) u16 {
        const gid = switch (self.cmap.format) {
            4 => cmapFormat4(self.cmap.data, cp),
            12 => cmapFormat12(self.cmap.data, cp),
            else => 0,
        };
        return if (gid < self.num_glyphs) gid else 0;
    }
};

/// Finds a table in the sfnt table directory, validating its bounds.
fn findTable(data: []const u8, tag: *const [4]u8) ?[]const u8 {
    const num_tables = be.u16At(data, 4) orelse return null;
    for (0..num_tables) |i| {
        const rec = 12 + i * 16;
        const rec_tag = be.slice(data, rec, 4) orelse return null;
        if (!std.mem.eql(u8, rec_tag, tag)) continue;
        const off = be.u32At(data, rec + 8) orelse return null;
        const len = be.u32At(data, rec + 12) orelse return null;
        return be.slice(data, off, len);
    }
    return null;
}

/// Picks the best Unicode subtable: (3,10) > (3,1) > (0,x); formats 4 and 12 only.
fn selectCmap(cmap: []const u8) ?Cmap {
    const count = be.u16At(cmap, 2) orelse return null;
    var best: ?Cmap = null;
    var best_score: u8 = 0;
    for (0..count) |i| {
        const rec = 4 + i * 8;
        const platform = be.u16At(cmap, rec) orelse return best;
        const encoding = be.u16At(cmap, rec + 2) orelse return best;
        const off = be.u32At(cmap, rec + 4) orelse return best;
        const score: u8 = switch (platform) {
            3 => switch (encoding) {
                10 => 6,
                1 => 5,
                else => 0,
            },
            0 => switch (encoding) {
                4, 6 => 4,
                3 => 3,
                else => 2,
            },
            else => 0,
        };
        if (score <= best_score) continue;
        const sub = if (off < cmap.len) cmap[off..] else continue;
        const format = be.u16At(sub, 0) orelse continue;
        if (format != 4 and format != 12) continue;
        best = .{ .format = format, .data = sub };
        best_score = score;
    }
    return best;
}

fn cmapFormat4(t: []const u8, cp: u21) u16 {
    if (cp > 0xFFFF) return 0;
    const c: u16 = @intCast(cp);
    const seg_count = (be.u16At(t, 6) orelse return 0) / 2;
    const ends = 14;
    const starts = ends + @as(usize, seg_count) * 2 + 2;
    const deltas = starts + @as(usize, seg_count) * 2;
    const range_offsets = deltas + @as(usize, seg_count) * 2;
    // Find the first segment whose end code is >= c.
    var lo: usize = 0;
    var hi: usize = seg_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const end = be.u16At(t, ends + mid * 2) orelse return 0;
        if (end < c) lo = mid + 1 else hi = mid;
    }
    if (lo >= seg_count) return 0;
    const start = be.u16At(t, starts + lo * 2) orelse return 0;
    if (c < start) return 0;
    const delta = be.u16At(t, deltas + lo * 2) orelse return 0;
    const ro_pos = range_offsets + lo * 2;
    const range_offset = be.u16At(t, ro_pos) orelse return 0;
    if (range_offset == 0) return c +% delta;
    const g = be.u16At(t, ro_pos + range_offset + @as(usize, c - start) * 2) orelse return 0;
    return if (g == 0) 0 else g +% delta;
}

fn cmapFormat12(t: []const u8, cp: u21) u16 {
    const num_groups = be.u32At(t, 12) orelse return 0;
    var lo: usize = 0;
    var hi: usize = num_groups;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec = 16 + mid * 12;
        const start = be.u32At(t, rec) orelse return 0;
        const end = be.u32At(t, rec + 4) orelse return 0;
        if (cp < start) {
            hi = mid;
        } else if (cp > end) {
            lo = mid + 1;
        } else {
            const g = (be.u32At(t, rec + 8) orelse return 0) + (cp - start);
            return std.math.cast(u16, g) orelse 0;
        }
    }
    return 0;
}

/// Returns the pair records of the first horizontal format-0 `kern` subtable.
fn kernPairs(kern: []const u8) []const u8 {
    // Only the Microsoft (version 0) header is supported.
    if (be.u16At(kern, 0) != 0) return &.{};
    const n_tables = be.u16At(kern, 2) orelse return &.{};
    var off: usize = 4;
    for (0..n_tables) |_| {
        const len = be.u16At(kern, off + 2) orelse return &.{};
        const coverage = be.u16At(kern, off + 4) orelse return &.{};
        // Format 0, horizontal, not minimum/cross-stream values.
        if (coverage >> 8 == 0 and coverage & 0x7 == 0x1) {
            const n_pairs = be.u16At(kern, off + 6) orelse return &.{};
            const pairs = off + 14;
            if (pairs > kern.len) return &.{};
            // The u16 length field overflows in big tables; trust nPairs within bounds.
            const avail = (kern.len - pairs) / 6;
            return kern[pairs..][0 .. @min(n_pairs, avail) * 6];
        }
        if (len < 6) return &.{};
        off += len;
    }
    return &.{};
}

fn kernTableLookup(pairs: []const u8, left: u16, right: u16) i32 {
    const key = @as(u32, left) << 16 | right;
    var lo: usize = 0;
    var hi: usize = pairs.len / 6;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const k = be.u32At(pairs, mid * 6).?;
        if (k == key) return be.i16At(pairs, mid * 6 + 4).?;
        if (k < key) lo = mid + 1 else hi = mid;
    }
    return 0;
}

/// Decodes a simple glyph's contours into `out`, applying `xf`.
fn appendSimple(allocator: Allocator, g: []const u8, num_contours: usize, xf: Transform, out: *Outline) Error!void {
    const bad = error.InvalidFont;
    const ON_CURVE = 0x01;
    const X_SHORT = 0x02;
    const Y_SHORT = 0x04;
    const REPEAT = 0x08;
    const X_SAME_OR_POS = 0x10;
    const Y_SAME_OR_POS = 0x20;

    if (num_contours == 0) return;
    const ends_off = 10;
    const ins_len = be.u16At(g, ends_off + num_contours * 2) orelse return bad;
    const flags_off = ends_off + num_contours * 2 + 2 + @as(usize, ins_len);
    const num_points = @as(usize, be.u16At(g, ends_off + (num_contours - 1) * 2) orelse return bad) + 1;
    if (out.points.items.len + num_points > Font.max_points) return bad;

    // Pass 1: walk the flags to find where the x and y coordinate arrays start.
    var off = flags_off;
    var x_len: usize = 0;
    {
        var i: usize = 0;
        while (i < num_points) {
            const flag = be.u8At(g, off) orelse return bad;
            off += 1;
            var run: usize = 1;
            if (flag & REPEAT != 0) {
                run += be.u8At(g, off) orelse return bad;
                off += 1;
            }
            if (i + run > num_points) return bad;
            i += run;
            if (flag & X_SHORT != 0) {
                x_len += run;
            } else if (flag & X_SAME_OR_POS == 0) {
                x_len += 2 * run;
            }
        }
    }
    var x_off = off;
    var y_off = off + x_len;

    // Pass 2: decode flags again together with the coordinates.
    const first = out.points.items.len;
    const first_contour = out.ends.items.len;
    try out.points.ensureUnusedCapacity(allocator, num_points);
    try out.ends.ensureUnusedCapacity(allocator, num_contours);
    var x: i32 = 0;
    var y: i32 = 0;
    off = flags_off;
    var i: usize = 0;
    while (i < num_points) {
        const flag = g[off];
        off += 1;
        var run: usize = 1;
        if (flag & REPEAT != 0) {
            run += g[off];
            off += 1;
        }
        for (0..run) |_| {
            if (flag & X_SHORT != 0) {
                const dx = be.u8At(g, x_off) orelse return bad;
                x += if (flag & X_SAME_OR_POS != 0) @as(i32, dx) else -@as(i32, dx);
                x_off += 1;
            } else if (flag & X_SAME_OR_POS == 0) {
                x += be.i16At(g, x_off) orelse return bad;
                x_off += 2;
            }
            if (flag & Y_SHORT != 0) {
                const dy = be.u8At(g, y_off) orelse return bad;
                y += if (flag & Y_SAME_OR_POS != 0) @as(i32, dy) else -@as(i32, dy);
                y_off += 1;
            } else if (flag & Y_SAME_OR_POS == 0) {
                y += be.i16At(g, y_off) orelse return bad;
                y_off += 2;
            }
            const p = xf.apply(@floatFromInt(x), @floatFromInt(y));
            out.points.appendAssumeCapacity(.{ .x = p[0], .y = p[1], .on = flag & ON_CURVE != 0 });
        }
        i += run;
    }

    var prev_end: usize = 0;
    for (0..num_contours) |c| {
        const end = @as(usize, be.u16At(g, ends_off + c * 2).?) + 1;
        if (end < prev_end or end > num_points) return bad;
        if (end > prev_end) out.ends.appendAssumeCapacity(@intCast(first + end));
        prev_end = end;
    }

    // Mirrored components reverse winding; restore it so that outer contours
    // keep a consistent orientation (needed for emboldening).
    if (xf.isMirroring()) {
        var start = first;
        for (out.ends.items[first_contour..]) |end| {
            std.mem.reverse(Point, out.points.items[start..end]);
            start = end;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

const testdata = @import("testdata.zig");

test "Inter: tables, metrics and cmap" {
    const data = try testdata.load("Inter-Regular.ttf");
    defer std.testing.allocator.free(data);
    var font = try Font.init(std.testing.allocator, data);
    defer font.deinit();

    try std.testing.expectEqual(@as(u16, 2048), font.units_per_em);
    try std.testing.expectEqual(@as(u16, 2926), font.num_glyphs);
    try std.testing.expectEqual(@as(i16, 1984), font.metrics.ascender);
    try std.testing.expectEqual(@as(i16, -494), font.metrics.descender);
    try std.testing.expectEqual(@as(i16, 1490), font.metrics.cap_height);
    try std.testing.expectEqual(@as(i16, 1118), font.metrics.x_height);
    try std.testing.expectEqual(@as(u16, 12), font.cmap.format); // (3,10) preferred

    // Glyph ids and advances cross-checked with fontTools.
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 456), font.glyphIndex('V'));
    try std.testing.expectEqual(@as(u16, 6), font.glyphIndex(0xC1)); // Á
    try std.testing.expectEqual(@as(u16, 1501), font.glyphIndex(0x2026)); // …
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex(0x10FFFF));
    try std.testing.expectEqual(@as(u16, 1413), font.advanceWidth(font.glyphIndex('A')));
    try std.testing.expectEqual(@as(u16, 576), font.advanceWidth(font.glyphIndex(' ')));
    try std.testing.expectEqual(@as(u16, 2018), font.advanceWidth(font.glyphIndex('W')));
    // The format 4 subtable must agree with format 12 for BMP characters.
    const fmt4 = Cmap{
        .format = 4,
        .data = blk: {
            const cmap = findTable(data, "cmap").?;
            // Encoding record 2 is (3,1) format 4.
            break :blk cmap[be.u32At(cmap, 4 + 2 * 8 + 4).?..];
        },
    };
    try std.testing.expectEqual(@as(u16, 4), be.u16At(fmt4.data, 0).?);
    for ([_]u21{ 'A', 'z', '0', ' ', 0xE9, 0x2026, 0x20AC }) |cp| {
        try std.testing.expectEqual(font.glyphIndex(cp), cmapFormat4(fmt4.data, cp));
    }
}

test "Inter: GPOS kerning" {
    const data = try testdata.load("Inter-Regular.ttf");
    defer std.testing.allocator.free(data);
    var font = try Font.init(std.testing.allocator, data);
    defer font.deinit();
    try std.testing.expect(!font.gpos_kern.isEmpty());

    const g = struct {
        fn k(f: *Font, a: u21, b: u21) i16 {
            return f.kerning(f.glyphIndex(a), f.glyphIndex(b));
        }
    };
    // Reference values from HarfBuzz (hb-shape with/without the kern feature).
    try std.testing.expectEqual(@as(i16, -140), g.k(&font, 'A', 'V'));
    try std.testing.expectEqual(@as(i16, -140), g.k(&font, 'V', 'A'));
    try std.testing.expectEqual(@as(i16, -116), g.k(&font, 'A', 'W'));
    try std.testing.expectEqual(@as(i16, -160), g.k(&font, 'T', 'o'));
    try std.testing.expectEqual(@as(i16, -197), g.k(&font, 'L', 'T'));
    try std.testing.expectEqual(@as(i16, -69), g.k(&font, 'T', '.'));
    try std.testing.expectEqual(@as(i16, -128), g.k(&font, 'r', '.'));
    try std.testing.expectEqual(@as(i16, -30), g.k(&font, 'a', 'v'));
    try std.testing.expectEqual(@as(i16, 0), g.k(&font, '1', '1'));
    try std.testing.expectEqual(@as(i16, 0), g.k(&font, '.', '.'));
    // Cached value is stable.
    try std.testing.expectEqual(@as(i16, -140), g.k(&font, 'A', 'V'));

    const bold_data = try testdata.load("Inter-Bold.ttf");
    defer std.testing.allocator.free(bold_data);
    var bold = try Font.init(std.testing.allocator, bold_data);
    defer bold.deinit();
    try std.testing.expectEqual(@as(i16, -162), g.k(&bold, 'A', 'V'));
    try std.testing.expectEqual(@as(i16, 17), g.k(&bold, 'f', 'i'));
}

test "outlines: simple, composite and transformed components" {
    const allocator = std.testing.allocator;
    const data = try testdata.load("Inter-Regular.ttf");
    defer allocator.free(data);
    var font = try Font.init(allocator, data);
    defer font.deinit();

    var outline: Outline = .{};
    defer outline.deinit(allocator);

    // 'H' is a simple glyph with one contour spanning its bbox (180,0)-(1342,1490).
    try font.glyphOutline(allocator, font.glyphIndex('H'), &outline);
    try std.testing.expectEqual(@as(usize, 1), outline.ends.items.len);
    var min_x: f32 = 1e9;
    var max_y: f32 = -1e9;
    for (outline.points.items) |p| {
        min_x = @min(min_x, p.x);
        max_y = @max(max_y, p.y);
    }
    try std.testing.expectEqual(@as(f32, 180), min_x);
    try std.testing.expectEqual(@as(f32, 1490), max_y);

    // 'i' is a composite (dotless i + dot accent): two contours.
    outline.clear();
    try font.glyphOutline(allocator, font.glyphIndex('i'), &outline);
    try std.testing.expectEqual(@as(usize, 2), outline.ends.items.len);

    // Space has no outline.
    outline.clear();
    try font.glyphOutline(allocator, font.glyphIndex(' '), &outline);
    try std.testing.expectEqual(@as(usize, 0), outline.points.items.len);

    // JetBrains Mono's quoteleft is the comma rotated by 180° via a 2x2 transform.
    const mono_data = try testdata.load("JetBrainsMono-Regular.ttf");
    defer allocator.free(mono_data);
    var mono = try Font.init(allocator, mono_data);
    defer mono.deinit();
    try std.testing.expectEqual(@as(u16, 4), mono.cmap.format); // only (3,1) format 4
    var comma: Outline = .{};
    defer comma.deinit(allocator);
    outline.clear();
    try mono.glyphOutline(allocator, mono.glyphIndex(','), &comma);
    try mono.glyphOutline(allocator, mono.glyphIndex(0x2018), &outline);
    try std.testing.expectEqual(comma.points.items.len, outline.points.items.len);
    var comma_max: f32 = -1e9;
    var quote_min: f32 = 1e9;
    for (comma.points.items) |p| comma_max = @max(comma_max, p.y);
    for (outline.points.items) |p| quote_min = @min(quote_min, p.y);
    // Rotated shape sits high above the baseline where the comma hangs below it.
    try std.testing.expect(quote_min > comma_max);
}

test "malformed fonts return errors instead of crashing" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidFont, Font.init(allocator, ""));
    try std.testing.expectError(error.InvalidFont, Font.init(allocator, "\x00\x01\x00\x00\xff\xff"));
    try std.testing.expectError(error.UnsupportedFont, Font.init(allocator, "OTTO\x00\x00"));

    const data = try testdata.load("Inter-Regular.ttf");
    defer allocator.free(data);

    // Every truncation of the font must either parse or fail cleanly.
    var len: usize = 0;
    while (len < data.len) : (len += data.len / 97 + 1) {
        var font = Font.init(allocator, data[0..len]) catch continue;
        font.deinit();
    }

    // Corrupt bytes throughout the file and exercise all lookups on the result.
    const copy = try allocator.dupe(u8, data);
    defer allocator.free(copy);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var outline: Outline = .{};
    defer outline.deinit(allocator);
    for (0..40) |_| {
        @memcpy(copy, data);
        for (0..200) |_| copy[random.uintLessThan(usize, copy.len)] = random.int(u8);
        var font = Font.init(allocator, copy) catch continue;
        defer font.deinit();
        for ("AVWay.,!?0ïé") |c| {
            const g = font.glyphIndex(c);
            _ = font.advanceWidth(g);
            _ = font.kerning(g, font.glyphIndex('V'));
            outline.clear();
            font.glyphOutline(allocator, g, &outline) catch {};
        }
        for (0..50) |_| {
            outline.clear();
            font.glyphOutline(allocator, random.int(u16), &outline) catch {};
        }
    }
}
