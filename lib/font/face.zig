//! `Face`: a font instantiated at a pixel size.
//!
//! Provides pixel metrics, glyph lookup through a fallback chain, kerned
//! glyph positioning, a glyph bitmap cache with 1/4 px horizontal subpixel
//! positioning, and the text layout helpers a UI needs: measuring, word
//! wrapping, truncation with an ellipsis, and caret <-> x mapping.

const std = @import("std");
const ttf = @import("ttf.zig");
const raster = @import("raster.zig");
const utf8 = @import("utf8.zig");
const Allocator = std.mem.Allocator;
const Font = ttf.Font;
const Vec2 = raster.Vec2;

/// Number of horizontal subpixel positions a glyph is rendered at.
pub const subpixel_steps = 4;

/// Largest glyph bitmap width or height, in pixels.
const max_bitmap_dim: f32 = 2048;

/// An 8-bit coverage mask for one glyph, positioned relative to the pen.
pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    /// Offset from the integer pen x to the leftmost column.
    left: i32,
    /// Distance from the baseline up to the top row (positive = above).
    top: i32,
    /// Horizontal advance in pixels, without kerning.
    advance: f32,
    /// Row-major coverage, `width * height` bytes (0 = none, 255 = full).
    alpha: []const u8,
};

/// A glyph resolved through a face's fallback chain.
pub const Glyph = struct {
    face: *Face,
    id: u16,
};

/// Splits a pen x position into an integer pixel and a subpixel index,
/// matching how glyph bitmaps are cached.
pub fn splitSubpixel(x: f32) struct { x: i32, subpixel: u2 } {
    const fl = @floor(x);
    const q: u32 = @intFromFloat(@round((x - fl) * subpixel_steps));
    const ix: i32 = @intFromFloat(std.math.clamp(fl, -1e9, 1e9));
    if (q >= subpixel_steps) return .{ .x = ix + 1, .subpixel = 0 };
    return .{ .x = ix, .subpixel = @intCast(q) };
}

/// Piecewise-linear vertical scaling that lands the x-height and the cap
/// height on whole pixels while keeping the baseline fixed: a light,
/// vertical-only form of hinting that keeps small text crisp without
/// changing advances. Heights outside [0, cap height] use the plain scale.
const VerticalGrid = struct {
    scale: f32,
    /// Anchors in font units and their snapped pixel heights. When snapping
    /// is off (or would distort), the anchors are 0 and mapping is linear.
    x_height: f32 = 0,
    cap_height: f32 = 0,
    x_height_px: f32 = 0,
    cap_height_px: f32 = 0,

    fn init(px_size: f32, scale: f32, metrics: ttf.Metrics, enabled: bool) VerticalGrid {
        var g: VerticalGrid = .{ .scale = scale };
        const xh: f32 = @floatFromInt(metrics.x_height);
        const cap: f32 = @floatFromInt(metrics.cap_height);
        const xh_px = @round(xh * scale);
        if (!enabled or px_size > 48 or xh_px < 3) return g;
        g.x_height = xh;
        g.x_height_px = xh_px;
        g.cap_height = xh;
        g.cap_height_px = xh_px;
        const cap_px = @round(cap * scale);
        // Snap the cap height too unless rounding would collapse the gap.
        if (cap > xh and cap_px - xh_px >= 1) {
            g.cap_height = cap;
            g.cap_height_px = cap_px;
        }
        return g;
    }

    /// Maps a font-unit height (y up) to pixels (y up).
    fn map(g: VerticalGrid, y: f32) f32 {
        if (g.x_height == 0 or y <= 0) return y * g.scale;
        if (y <= g.x_height) return y * (g.x_height_px / g.x_height);
        if (y <= g.cap_height) {
            const t = (y - g.x_height) / (g.cap_height - g.x_height);
            return g.x_height_px + t * (g.cap_height_px - g.x_height_px);
        }
        return g.cap_height_px + (y - g.cap_height) * g.scale;
    }
};

pub const Options = struct {
    /// Align the x-height and cap height to whole pixels at sizes up to
    /// 48 px (vertical-only light hinting). Sharpens small text.
    snap_to_grid: bool = true,
    /// Stem darkening: thickens strokes slightly at small sizes, like
    /// desktop font smoothing does, to counter thin-looking AA text.
    darken: bool = true,
    /// Tab stops every this many space widths.
    tab_spaces: u8 = 4,
    /// Bytes of cached bitmaps after which the glyph cache is flushed.
    cache_limit: usize = 1 << 20,
};

pub const Face = struct {
    allocator: Allocator,
    font: *Font,
    options: Options,
    /// Em size in pixels.
    size: f32,
    /// Pixels per font unit.
    scale: f32,
    grid: VerticalGrid,
    /// Distance from the baseline to the top of the line box (positive).
    ascent: f32,
    /// Distance from the baseline to the bottom of the line box (positive).
    descent: f32,
    line_gap: f32,
    /// Recommended baseline-to-baseline distance.
    line_height: f32,
    cap_height: f32,
    x_height: f32,
    tab_width: f32,
    /// Font-wide glyph bounds in pixels relative to the origin (y up).
    bounds: struct { x_min: f32, y_min: f32, x_max: f32, y_max: f32 },
    /// Face consulted for characters this font lacks (should use the same size).
    fallback: ?*Face = null,

    cache: std.AutoHashMapUnmanaged(u32, GlyphBitmap) = .empty,
    /// Owns the bitmap pixels of cached glyphs.
    arena: std.heap.ArenaAllocator,
    cache_bytes: usize = 0,
    outline: ttf.Outline = .{},
    darken_scratch: std.ArrayList(Edge) = .empty,
    rasterizer: raster.Rasterizer = .{},

    pub const InitError = error{InvalidSize};

    /// Creates a face for `font` at `px_size` pixels per em. The font must
    /// outlive the face, and the face must not move once glyph iterators or
    /// fallback links refer to it.
    pub fn init(allocator: Allocator, font: *Font, px_size: f32, options: Options) InitError!Face {
        if (!(px_size >= 1 and px_size <= 2048)) return error.InvalidSize;
        const m = font.metrics;
        const scale = px_size / @as(f32, @floatFromInt(font.units_per_em));
        const grid = VerticalGrid.init(px_size, scale, m, options.snap_to_grid);
        const fx = struct {
            fn f(v: i16, s: f32) f32 {
                return @as(f32, @floatFromInt(v)) * s;
            }
        }.f;
        const fy = struct {
            fn f(v: i16, g: VerticalGrid) f32 {
                return g.map(@floatFromInt(v));
            }
        }.f;
        var face: Face = .{
            .allocator = allocator,
            .font = font,
            .options = options,
            .size = px_size,
            .scale = scale,
            .grid = grid,
            .ascent = fx(m.ascender, scale),
            .descent = -fx(m.descender, scale),
            .line_gap = fx(m.line_gap, scale),
            .line_height = 0,
            .cap_height = fy(m.cap_height, grid),
            .x_height = fy(m.x_height, grid),
            .tab_width = 0,
            .bounds = .{
                .x_min = fx(m.x_min, scale),
                .y_min = fy(m.y_min, grid),
                .x_max = fx(m.x_max, scale),
                .y_max = fy(m.y_max, grid),
            },
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        face.line_height = face.ascent + face.descent + face.line_gap;
        face.tab_width = @as(f32, @floatFromInt(options.tab_spaces)) * face.advance(font.glyphIndex(' '));
        return face;
    }

    pub fn deinit(self: *Face) void {
        self.cache.deinit(self.allocator);
        self.arena.deinit();
        self.outline.deinit(self.allocator);
        self.darken_scratch.deinit(self.allocator);
        self.rasterizer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drops all cached glyph bitmaps.
    pub fn clearCache(self: *Face) void {
        self.cache.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.cache_bytes = 0;
    }

    /// Resolves a code point through the fallback chain. Characters no face
    /// provides map to the primary face's .notdef glyph.
    pub fn lookup(self: *Face, cp: u21) Glyph {
        var face: ?*Face = self;
        var depth: u8 = 0;
        while (face) |f| : (face = f.fallback) {
            const id = f.font.glyphIndex(cp);
            if (id != 0) return .{ .face = f, .id = id };
            depth += 1;
            if (depth == 8) break; // guard against accidental cycles
        }
        return .{ .face = self, .id = 0 };
    }

    /// Advance width of a glyph of this face in pixels.
    pub fn advance(self: *const Face, id: u16) f32 {
        return @as(f32, @floatFromInt(self.font.advanceWidth(id))) * self.scale;
    }

    /// Kerning in pixels between two resolved glyphs (0 across different faces).
    pub fn kerning(left: Glyph, right: Glyph) f32 {
        if (left.face != right.face) return 0;
        return @as(f32, @floatFromInt(left.face.font.kerning(left.id, right.id))) * left.face.scale;
    }

    /// Returns the cached coverage bitmap of glyph `id` rendered at the given
    /// 1/4 px horizontal offset, rasterizing it on first use. The returned
    /// pixels stay valid until the cache is flushed, which can happen on any
    /// later call that rasterizes a glyph.
    pub fn glyphBitmap(self: *Face, id: u16, subpixel: u2) Allocator.Error!GlyphBitmap {
        const key = @as(u32, id) << 2 | subpixel;
        if (self.cache.get(key)) |bitmap| return bitmap;
        if (self.cache_bytes > self.options.cache_limit) self.clearCache();
        const bitmap = try self.render(id, subpixel);
        try self.cache.put(self.allocator, key, bitmap);
        self.cache_bytes += bitmap.alpha.len + @sizeOf(GlyphBitmap) + 8;
        return bitmap;
    }

    /// Horizontal stroke thickening in pixels applied at this size (0 when
    /// disabled). Only x is affected so baselines and the x-height stay crisp.
    pub fn darkenAmount(self: *const Face) f32 {
        if (!self.options.darken) return 0;
        // Strongest for small text, fading out by 30 px.
        return 0.22 * std.math.clamp((30 - self.size) / 16, 0, 1);
    }

    fn render(self: *Face, id: u16, subpixel: u2) Allocator.Error!GlyphBitmap {
        var bitmap: GlyphBitmap = .{ .width = 0, .height = 0, .left = 0, .top = 0, .advance = self.advance(id), .alpha = &.{} };
        const outline = &self.outline;
        outline.clear();
        self.font.glyphOutline(self.allocator, id, outline) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return bitmap, // corrupt glyph: draw nothing
        };
        if (outline.points.items.len == 0) return bitmap;

        const darken = self.darkenAmount();
        if (darken > 0) try self.embolden(darken / self.scale, 0);

        // To pixel space (y down, origin on the baseline) and bounds.
        const dx = @as(f32, @floatFromInt(subpixel)) / subpixel_steps;
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (outline.points.items) |*p| {
            p.x = p.x * self.scale + dx;
            p.y = -self.grid.map(p.y);
            min_x = @min(min_x, p.x);
            max_x = @max(max_x, p.x);
            min_y = @min(min_y, p.y);
            max_y = @max(max_y, p.y);
        }
        // Real glyphs stay within a few ems; anything larger is corrupt data
        // and is not drawn rather than allocating a huge canvas.
        const limit = @min(self.size * 4 + 16, max_bitmap_dim);
        if (!(max_x - min_x < limit and max_y - min_y < limit and
            @abs(min_x) < 2 * limit and @abs(min_y) < 2 * limit)) return bitmap;
        const left = @floor(min_x);
        const top = @floor(min_y);
        const width: u32 = @intFromFloat(@ceil(max_x) - left);
        const height: u32 = @intFromFloat(@ceil(max_y) - top);
        if (width == 0 or height == 0) return bitmap;

        try self.rasterizer.reset(self.allocator, width, height);
        var contours = outline.contours();
        while (contours.next()) |contour| {
            emitContour(&self.rasterizer, contour, .{ .x = -left, .y = -top });
        }
        const alpha = try self.arena.allocator().alloc(u8, @as(usize, width) * height);
        self.rasterizer.resolve(alpha);

        bitmap.width = width;
        bitmap.height = height;
        bitmap.left = @intFromFloat(left);
        bitmap.top = @intFromFloat(-top);
        bitmap.alpha = alpha;
        return bitmap;
    }

    /// Grows every outer contour outward (and shrinks counters) by
    /// `amount_x / 2` and `amount_y / 2` font units per side, keeping the
    /// advance unchanged.
    fn embolden(self: *Face, amount_x: f32, amount_y: f32) Allocator.Error!void {
        const outline = &self.outline;
        // Outer contours are clockwise in TrueType (negative signed area in y-up space).
        var area: f32 = 0;
        var contours = outline.contours();
        while (contours.next()) |c| {
            var prev = c[c.len - 1];
            for (c) |p| {
                area += prev.x * p.y - p.x * prev.y;
                prev = p;
            }
        }
        if (area == 0) return;
        const sign: f32 = if (area < 0) 1 else -1;
        const half_x = amount_x / 2;
        const half_y = amount_y / 2;

        contours = outline.contours();
        while (contours.next()) |c| {
            const n = c.len;
            if (n < 3) continue;
            // Unit direction and length of every edge, from the original points.
            try self.darken_scratch.resize(self.allocator, n);
            const edges = self.darken_scratch.items;
            for (edges, 0..) |*e, i| {
                const q = c[if (i + 1 == n) 0 else i + 1];
                const dx = q.x - c[i].x;
                const dy = q.y - c[i].y;
                const len = @sqrt(dx * dx + dy * dy);
                e.* = if (len > 1e-3) .{ .x = dx / len, .y = dy / len, .len = len } else .{ .x = 0, .y = 0, .len = 0 };
            }
            for (c, 0..) |*p, i| {
                // Incoming and outgoing edges, skipping zero-length ones.
                const in = nonDegenerateEdge(edges, if (i == 0) n - 1 else i - 1, n - 1) orelse continue;
                const out = nonDegenerateEdge(edges, i, 1) orelse continue;
                const d = 1 + in.x * out.x + in.y * out.y; // 1 + cos(turn)
                if (d <= 0.0625) continue; // near-reversal: leave sharp spikes alone
                // Move along the corner bisector so that both edges shift by the
                // requested amount (a miter join), limiting the miter where edges are
                // short (FreeType's FT_Outline_EmboldenXY, minus its translation).
                const q = sign * (in.x * out.y - in.y * out.x);
                const l = @min(in.len, out.len);
                const kx = if (half_x * q <= l * d) half_x / d else l / q;
                const ky = if (half_y * q <= l * d) half_y / d else l / q;
                p.x -= sign * (in.y + out.y) * kx;
                p.y += sign * (in.x + out.x) * ky;
            }
        }
    }

    // ----------------------------------------------------------------- layout

    /// Iterates the positioned glyphs of `text`.
    pub fn glyphs(self: *Face, text: []const u8) GlyphIterator {
        return .{ .face = self, .it = utf8.Iterator.init(text) };
    }

    /// Width in pixels of the widest line of `text` ('\n' separates lines).
    pub fn measure(self: *Face, text: []const u8) f32 {
        var it = self.glyphs(text);
        var widest: f32 = 0;
        while (it.next()) |item| {
            if (item.cp == '\n') widest = @max(widest, item.x);
        }
        return @max(widest, it.pen);
    }

    /// Height in pixels of `line_count` lines of text.
    pub fn textHeight(self: *const Face, line_count: usize) f32 {
        return @as(f32, @floatFromInt(line_count)) * self.line_height;
    }

    /// Word-wrapping line iterator (see `LineIterator`).
    pub fn lines(self: *Face, text: []const u8, max_width: f32) LineIterator {
        return .{ .face = self, .text = text, .max_width = max_width };
    }

    /// Breaks `text` into lines no wider than `max_width` (where possible).
    /// Caller owns the returned slice.
    pub fn layoutLines(self: *Face, allocator: Allocator, text: []const u8, max_width: f32) Allocator.Error![]Line {
        var list: std.ArrayList(Line) = .empty;
        errdefer list.deinit(allocator);
        var it = self.lines(text, max_width);
        while (it.next()) |line| try list.append(allocator, line);
        return list.toOwnedSlice(allocator);
    }

    /// Byte index of the caret position closest to `x` (pixels from the
    /// start of `text`). Considers only the first line of `text`.
    pub fn indexAtX(self: *Face, text: []const u8, x: f32) usize {
        var it = self.glyphs(text);
        while (it.next()) |item| {
            if (item.cp == '\n') return item.start;
            if (x < item.x + item.advance * 0.5) return item.start;
        }
        return text.len;
    }

    /// Pixel x of the caret placed before byte `index` of `text` (the end of
    /// the first line if `index` lies beyond it).
    pub fn xAtIndex(self: *Face, text: []const u8, index: usize) f32 {
        var it = self.glyphs(text);
        while (it.next()) |item| {
            if (item.start >= index or item.cp == '\n') return item.x;
        }
        return it.pen;
    }

    /// Ellipsis appended by truncation: U+2026, or "..." if no face has it.
    pub fn ellipsis(self: *Face) []const u8 {
        return if (self.lookup(0x2026).id != 0) "…" else "...";
    }

    pub const Truncation = struct {
        /// Length in bytes of the prefix of the text to keep.
        len: usize,
        /// Whether an ellipsis must follow the prefix.
        ellipsis: bool,
    };

    /// Computes how to fit the first line of `text` into `max_width`,
    /// cutting at a character boundary and leaving room for an ellipsis.
    pub fn truncateLen(self: *Face, text: []const u8, max_width: f32) Truncation {
        const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const line = text[0..line_end];
        if (line_end == text.len and self.measure(line) <= max_width) return .{ .len = text.len, .ellipsis = false };
        const room = max_width - self.measure(self.ellipsis());
        var it = self.glyphs(line);
        var fit: usize = 0;
        while (it.next()) |item| {
            if (item.x + item.advance > room) break;
            fit = item.end;
        }
        while (fit > 0 and (line[fit - 1] == ' ' or line[fit - 1] == '\t')) fit -= 1;
        return .{ .len = fit, .ellipsis = true };
    }

    /// Returns `text` shortened with a trailing ellipsis so that it fits in
    /// `max_width`. Caller owns the returned memory.
    pub fn truncate(self: *Face, allocator: Allocator, text: []const u8, max_width: f32) Allocator.Error![]u8 {
        const t = self.truncateLen(text, max_width);
        const tail = if (t.ellipsis) self.ellipsis() else "";
        return std.mem.concat(allocator, u8, &.{ text[0..t.len], tail });
    }
};

const Edge = struct { x: f32, y: f32, len: f32 };

/// Returns `edges[i]`, or if it has zero length the nearest edge with a
/// length found by stepping `step` (1 = forward, n-1 = backward).
fn nonDegenerateEdge(edges: []const Edge, i: usize, step: usize) ?Edge {
    var j = i;
    for (0..edges.len) |_| {
        if (edges[j].len > 0) return edges[j];
        j = (j + step) % edges.len;
    }
    return null;
}

/// Feeds one TrueType contour (pixel space) to the rasterizer as lines and quads.
fn emitContour(r: *raster.Rasterizer, pts: []const ttf.Point, offset: Vec2) void {
    const n = pts.len;
    if (n < 2) return;
    const v = struct {
        fn f(p: ttf.Point, o: Vec2) Vec2 {
            return .{ .x = p.x + o.x, .y = p.y + o.y };
        }
    }.f;
    // Start on an on-curve point (or the implied midpoint of two off-curve points).
    var start: Vec2 = undefined;
    var rest: []const ttf.Point = undefined;
    if (pts[0].on) {
        start = v(pts[0], offset);
        rest = pts[1..];
    } else if (pts[n - 1].on) {
        start = v(pts[n - 1], offset);
        rest = pts[0 .. n - 1];
    } else {
        start = Vec2.mid(v(pts[n - 1], offset), v(pts[0], offset));
        rest = pts;
    }
    var cur = start;
    var ctrl: ?Vec2 = null;
    for (rest) |p| {
        const q = v(p, offset);
        if (p.on) {
            if (ctrl) |c| r.quad(cur, c, q) else r.line(cur, q);
            cur = q;
            ctrl = null;
        } else {
            if (ctrl) |c| {
                const m = Vec2.mid(c, q);
                r.quad(cur, c, m);
                cur = m;
            }
            ctrl = q;
        }
    }
    if (ctrl) |c| r.quad(cur, c, start) else r.line(cur, start);
}

/// Iterates characters of a text with their kerned pen positions.
/// The pen resets to 0 after each '\n', so tab stops are per line.
pub const GlyphIterator = struct {
    face: *Face,
    it: utf8.Iterator,
    /// Pen position after the last returned character.
    pen: f32 = 0,
    prev: ?Glyph = null,

    pub const Item = struct {
        /// Byte range of the character in the text.
        start: usize,
        end: usize,
        cp: u21,
        glyph: Glyph,
        /// Pen x of the glyph origin relative to the line start (kerning applied).
        x: f32,
        /// Advance of this character (tabs extend to the next stop; controls are 0).
        advance: f32,
        /// False for characters that draw nothing (controls, tabs, newlines).
        visible: bool,
    };

    pub fn next(self: *GlyphIterator) ?Item {
        const start = self.it.i;
        const cp = self.it.next() orelse return null;
        var item: Item = .{
            .start = start,
            .end = self.it.i,
            .cp = cp,
            .glyph = .{ .face = self.face, .id = 0 },
            .x = self.pen,
            .advance = 0,
            .visible = false,
        };
        switch (cp) {
            '\n' => {
                self.pen = 0;
                self.prev = null;
            },
            '\t' => {
                const tab = self.face.tab_width;
                const stop = if (tab > 0) (@floor(self.pen / tab) + 1) * tab else self.pen;
                item.advance = stop - self.pen;
                self.pen = stop;
                self.prev = null;
            },
            // Other C0/C1 controls, zero-width space and BOM take no space.
            0...8, 11...31, 0x7F...0x9F, 0x200B, 0xFEFF => self.prev = null,
            else => {
                const g = self.face.lookup(cp);
                if (self.prev) |p| self.pen += Face.kerning(p, g);
                item.glyph = g;
                item.x = self.pen;
                item.advance = g.face.advance(g.id);
                item.visible = true;
                self.pen += item.advance;
                self.prev = g;
            },
        }
        return item;
    }
};

/// A laid-out line: `text[start..end]`, `width` pixels wide. Break spaces and
/// the '\n' between one line's `end` and the next line's `start` are not drawn.
pub const Line = struct {
    start: usize,
    end: usize,
    width: f32,
};

fn isBreakAfter(cp: u21) bool {
    return switch (cp) {
        '-', 0x2010, 0x2013, 0x2014 => true, // hyphen-minus, hyphen, en and em dash
        else => false,
    };
}

/// Word-wrapping line breaker. Breaks after runs of spaces and after
/// hyphens/dashes, falls back to breaking between characters for words
/// longer than a line, and always breaks at '\n'. Spaces at a soft break
/// may hang past `max_width`. A trailing '\n' produces a final empty line,
/// like a text editor.
pub const LineIterator = struct {
    face: *Face,
    text: []const u8,
    max_width: f32,
    pos: usize = 0,
    done: bool = false,

    pub fn next(self: *LineIterator) ?Line {
        if (self.done) return null;
        const base = self.pos;
        var it = self.face.glyphs(self.text[base..]);
        // Last break opportunity: where this line would end, where the next
        // one would start (after any break spaces), and the width up to it.
        var brk: ?struct { end: usize, next: usize, width: f32 } = null;
        var in_spaces = false;
        var ink_end: f32 = 0; // pen after the last non-space character
        while (it.next()) |item| {
            const s = base + item.start;
            const e = base + item.end;
            switch (item.cp) {
                '\n' => {
                    self.pos = e;
                    return .{ .start = base, .end = s, .width = item.x };
                },
                ' ', '\t' => {
                    if (in_spaces) {
                        brk.?.next = e;
                    } else if (s > base) {
                        brk = .{ .end = s, .next = e, .width = ink_end };
                        in_spaces = true;
                    }
                    continue;
                },
                else => {},
            }
            in_spaces = false;
            if (item.x + item.advance > self.max_width and s > base) {
                if (brk) |b| {
                    self.pos = b.next;
                    return .{ .start = base, .end = b.end, .width = b.width };
                }
                // A single word wider than the line: break between characters.
                self.pos = s;
                return .{ .start = base, .end = s, .width = ink_end };
            }
            if (item.advance > 0) ink_end = item.x + item.advance;
            // Hyphens and dashes allow a break after them (UAX #14 classes BA/B2).
            if (isBreakAfter(item.cp) and s > base) brk = .{ .end = e, .next = e, .width = ink_end };
        }
        self.done = true;
        return .{ .start = base, .end = self.text.len, .width = it.pen };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testdata = @import("testdata.zig");

const TestFonts = struct {
    data: []u8,
    font: Font,

    fn init(name: []const u8) !*TestFonts {
        const self = try std.testing.allocator.create(TestFonts);
        errdefer std.testing.allocator.destroy(self);
        self.data = try testdata.load(name);
        errdefer std.testing.allocator.free(self.data);
        self.font = try Font.init(std.testing.allocator, self.data);
        return self;
    }

    fn deinit(self: *TestFonts) void {
        self.font.deinit();
        std.testing.allocator.free(self.data);
        std.testing.allocator.destroy(self);
    }
};

test "metrics and measuring with kerning" {
    const tf = try TestFonts.init("Inter-Regular.ttf");
    defer tf.deinit();
    var face = try Face.init(std.testing.allocator, &tf.font, 20.48, .{});
    defer face.deinit();
    // 20.48 px on a 2048 upem font: 1 unit = 0.01 px.
    try std.testing.expectApproxEqAbs(@as(f32, 19.84), face.ascent, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 4.94), face.descent, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 24.78), face.line_height, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 14.13), face.advance(face.lookup('A').id), 1e-3);
    // "AV" = A (1413) + kern (-140) + V (1413) units.
    try std.testing.expectApproxEqAbs(@as(f32, 26.86), face.measure("AV"), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 26.86), face.measure("A\nAV\nV"), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), face.measure(""));
    // Tabs advance to the next stop (4 spaces of 5.76 px).
    try std.testing.expectApproxEqAbs(@as(f32, 23.04), face.measure("\t"), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 23.04), face.measure("A\t"), 1e-3);
}

test "glyph bitmaps: coverage, placement and caching" {
    const tf = try TestFonts.init("Inter-Regular.ttf");
    defer tf.deinit();
    var face = try Face.init(std.testing.allocator, &tf.font, 40, .{ .darken = false, .snap_to_grid = false });
    defer face.deinit();

    // 'l' is a vertical stem from the baseline to the ascender.
    const l = try face.glyphBitmap(face.lookup('l').id, 0);
    try std.testing.expect(l.width >= 3 and l.height >= 28);
    try std.testing.expect(l.top >= 28 and l.top <= 31);
    try std.testing.expectEqual(@as(usize, l.width * l.height), l.alpha.len);
    // The middle of the stem is fully covered; the corners are empty.
    var solid: u32 = 0;
    const row = l.alpha[(l.height / 2) * l.width ..][0..l.width];
    for (row) |a| {
        if (a == 255) solid += 1;
    }
    try std.testing.expect(solid >= 2);
    try std.testing.expectEqual(@as(u8, 0), row[0] & 0x00); // row exists

    // A filled region: the period's dot at 40px is a ~3x3 px square, fully inked in the center.
    const dot = try face.glyphBitmap(face.lookup('.').id, 0);
    try std.testing.expect(dot.width >= 3 and dot.height >= 3);
    try std.testing.expectEqual(@as(u8, 255), dot.alpha[(dot.height / 2) * dot.width + dot.width / 2]);
    try std.testing.expect(dot.top >= 5 and dot.top <= 6); // sits on the baseline (height 257 units)

    // Total ink is independent of the subpixel offset (area is preserved).
    var sums: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..4) |sub| {
        const b = try face.glyphBitmap(face.lookup('o').id, @intCast(sub));
        for (b.alpha) |a| sums[sub] += a;
    }
    for (sums[1..]) |s| try std.testing.expectApproxEqRel(@as(f32, @floatFromInt(sums[0])), @as(f32, @floatFromInt(s)), 0.01);

    // Cached: same pixels come back.
    const again = try face.glyphBitmap(face.lookup('l').id, 0);
    try std.testing.expectEqual(l.alpha.ptr, again.alpha.ptr);

    // Space has no ink but an advance.
    const space = try face.glyphBitmap(face.lookup(' ').id, 0);
    try std.testing.expectEqual(@as(u32, 0), space.width);
    try std.testing.expect(space.advance > 0);
}

test "stem darkening thickens small text" {
    const tf = try TestFonts.init("Inter-Regular.ttf");
    defer tf.deinit();
    var plain = try Face.init(std.testing.allocator, &tf.font, 12, .{ .darken = false });
    defer plain.deinit();
    var dark = try Face.init(std.testing.allocator, &tf.font, 12, .{ .darken = true });
    defer dark.deinit();
    const ink = struct {
        fn f(face: *Face, cp: u21) !u32 {
            const b = try face.glyphBitmap(face.lookup(cp).id, 0);
            var sum: u32 = 0;
            for (b.alpha) |a| sum += a;
            return sum;
        }
    }.f;
    for ("Hoe") |c| {
        const a = try ink(&plain, c);
        const b = try ink(&dark, c);
        try std.testing.expect(b > a and b < a + a / 3);
    }
}

test "splitSubpixel quantizes to quarter pixels" {
    try std.testing.expectEqual(@as(i32, 3), splitSubpixel(3.1).x);
    try std.testing.expectEqual(@as(u2, 0), splitSubpixel(3.1).subpixel);
    try std.testing.expectEqual(@as(u2, 1), splitSubpixel(3.2).subpixel);
    try std.testing.expectEqual(@as(u2, 3), splitSubpixel(-0.3).subpixel);
    try std.testing.expectEqual(@as(i32, -1), splitSubpixel(-0.3).x);
    try std.testing.expectEqual(@as(i32, 4), splitSubpixel(3.9).x);
    try std.testing.expectEqual(@as(u2, 0), splitSubpixel(3.9).subpixel);
}

test "fallback chain and .notdef" {
    const inter = try TestFonts.init("Inter-Regular.ttf");
    defer inter.deinit();
    const mono = try TestFonts.init("JetBrainsMono-Regular.ttf");
    defer mono.deinit();
    var primary = try Face.init(std.testing.allocator, &mono.font, 14, .{});
    defer primary.deinit();
    var fallback = try Face.init(std.testing.allocator, &inter.font, 14, .{});
    defer fallback.deinit();

    // U+0132 (Ĳ) is in Inter but not in JetBrains Mono.
    try std.testing.expectEqual(@as(u16, 0), mono.font.glyphIndex(0x0132));
    try std.testing.expect(inter.font.glyphIndex(0x0132) != 0);
    try std.testing.expectEqual(&primary, primary.lookup('a').face);
    try std.testing.expectEqual(@as(u16, 0), primary.lookup(0x0132).id);
    primary.fallback = &fallback;
    try std.testing.expectEqual(&fallback, primary.lookup(0x0132).face);
    try std.testing.expectEqual(&primary, primary.lookup('a').face);
    // Missing everywhere: primary .notdef, which still has an advance.
    const missing = primary.lookup(0x10FFFD);
    try std.testing.expectEqual(&primary, missing.face);
    try std.testing.expectEqual(@as(u16, 0), missing.id);
    try std.testing.expect(primary.measure("\u{10FFFD}") > 0);
    // Invalid UTF-8 becomes U+FFFD, which neither font has: drawn as .notdef.
    try std.testing.expectApproxEqAbs(primary.measure("\u{10FFFD}"), primary.measure("\xff"), 1e-4);
}

test "line breaking" {
    const tf = try TestFonts.init("JetBrainsMono-Regular.ttf");
    defer tf.deinit();
    // Monospace at 10 px: every character advances exactly 6 px.
    var face = try Face.init(std.testing.allocator, &tf.font, 10, .{});
    defer face.deinit();
    const a = std.testing.allocator;

    const expectLines = struct {
        fn f(fc: *Face, text: []const u8, width: f32, want: []const []const u8) !void {
            const got = try fc.layoutLines(std.testing.allocator, text, width);
            defer std.testing.allocator.free(got);
            errdefer for (got) |l| std.debug.print("line: '{s}'\n", .{text[l.start..l.end]});
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try std.testing.expectEqualStrings(w, text[g.start..g.end]);
        }
    }.f;

    // Word wrap at spaces; the break spaces are dropped.
    try expectLines(&face, "hello brave new world", 66, &.{ "hello brave", "new world" });
    // Leading indentation is kept; spaces at a soft break may hang past the edge.
    try expectLines(&face, "  ab     cd  ", 30, &.{ "  ab", "cd  " });
    // Hard newlines, including an empty line and a trailing newline.
    try expectLines(&face, "ab\n\ncd\n", 100, &.{ "ab", "", "cd", "" });
    // Long words break between characters.
    try expectLines(&face, "abcdefghij", 24, &.{ "abcd", "efgh", "ij" });
    try expectLines(&face, "x abcdefghij", 24, &.{ "x", "abcd", "efgh", "ij" });
    // A line always holds at least one character.
    try expectLines(&face, "abc", 1, &.{ "a", "b", "c" });
    try expectLines(&face, "", 100, &.{""});
    // Multi-byte characters are never split.
    try expectLines(&face, "ééé", 12, &.{ "éé", "é" });
    // Breaks after hyphens and dashes, keeping the hyphen on the first line.
    try expectLines(&face, "well-known fact", 36, &.{ "well-", "known", "fact" });
    try expectLines(&face, "a—b", 12, &.{ "a—", "b" });
    try expectLines(&face, "-abc", 12, &.{ "-a", "bc" });

    const lines_ = try face.layoutLines(a, "hello brave new world", 66);
    defer a.free(lines_);
    try std.testing.expectApproxEqAbs(@as(f32, 66), lines_[0].width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 54), lines_[1].width, 1e-3);
}

test "truncation and caret mapping" {
    const tf = try TestFonts.init("JetBrainsMono-Regular.ttf");
    defer tf.deinit();
    var face = try Face.init(std.testing.allocator, &tf.font, 10, .{});
    defer face.deinit();
    const a = std.testing.allocator;

    const fits = try face.truncate(a, "short", 30);
    defer a.free(fits);
    try std.testing.expectEqualStrings("short", fits);
    const cut = try face.truncate(a, "a long title", 36);
    defer a.free(cut);
    try std.testing.expectEqualStrings("a lon…", cut);
    try std.testing.expect(face.measure(cut) <= 36);
    // Trailing spaces before the ellipsis are trimmed.
    const trimmed = try face.truncate(a, "ab   cdefgh", 30);
    defer a.free(trimmed);
    try std.testing.expectEqualStrings("ab…", trimmed);
    // Only the first line is kept.
    const first = try face.truncate(a, "one\ntwo", 100);
    defer a.free(first);
    try std.testing.expectEqualStrings("one…", first);
    try std.testing.expectEqual(Face.Truncation{ .len = 0, .ellipsis = true }, face.truncateLen("abc", 2));

    // Caret mapping snaps to the nearest character boundary.
    try std.testing.expectEqual(@as(usize, 0), face.indexAtX("abc", -5));
    try std.testing.expectEqual(@as(usize, 0), face.indexAtX("abc", 2.9));
    try std.testing.expectEqual(@as(usize, 1), face.indexAtX("abc", 3.1));
    try std.testing.expectEqual(@as(usize, 3), face.indexAtX("abc", 100));
    try std.testing.expectEqual(@as(usize, 1), face.indexAtX("aéb", 8.9));
    try std.testing.expectEqual(@as(usize, 3), face.indexAtX("aéb", 9.1)); // after 'é' (2 bytes)
    try std.testing.expectEqual(@as(usize, 2), face.indexAtX("ab\ncd", 50));
    try std.testing.expectEqual(@as(f32, 0), face.xAtIndex("abc", 0));
    try std.testing.expectEqual(@as(f32, 12), face.xAtIndex("abc", 2));
    try std.testing.expectEqual(@as(f32, 18), face.xAtIndex("abc", 99));
    try std.testing.expectEqual(@as(f32, 12), face.xAtIndex("aéb", 3));
    for (0..4) |i| {
        try std.testing.expectEqual(i, face.indexAtX("abc", face.xAtIndex("abc", i)));
    }
}

test "caret mapping follows kerning" {
    const tf = try TestFonts.init("Inter-Regular.ttf");
    defer tf.deinit();
    var face = try Face.init(std.testing.allocator, &tf.font, 20.48, .{});
    defer face.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 12.73), face.xAtIndex("AV", 1), 1e-3);
    try std.testing.expectEqual(@as(usize, 1), face.indexAtX("AV", 13));
}
