//! Zen OS font engine: a pure-Zig TrueType parser, anti-aliased rasterizer,
//! glyph cache and text layout helpers.
//!
//! Typical use:
//!
//!     var inter = try font.Font.init(allocator, @embedFile("Inter-Regular.ttf"));
//!     var body = try font.Face.init(allocator, &inter, 13, .{});
//!     _ = font.drawText(target, &body, "Hello, world", 10, 10 + body.ascent, 0xFF1D1D1F);
//!
//! * `Font` parses a TrueType file (borrowed bytes): cmap, metrics, glyph
//!   outlines, `kern` and GPOS kerning.
//! * `Face` is a font at a pixel size: metrics, glyph bitmap cache (1/4 px
//!   subpixel positioning), measuring, wrapping, truncation, caret mapping,
//!   and an optional fallback face for missing characters.
//! * `drawText` and friends composite into a premultiplied ARGB `Target`;
//!   other renderers can use `Face.glyphs` + `Face.glyphBitmap` instead.

const std = @import("std");

pub const ttf = @import("ttf.zig");
pub const utf8 = @import("utf8.zig");
pub const raster = @import("raster.zig");
const face = @import("face.zig");
const draw = @import("draw.zig");

pub const Font = ttf.Font;
pub const Error = ttf.Error;
pub const Metrics = ttf.Metrics;

pub const Face = face.Face;
pub const Options = face.Options;
pub const Glyph = face.Glyph;
pub const GlyphBitmap = face.GlyphBitmap;
pub const GlyphIterator = face.GlyphIterator;
pub const Line = face.Line;
pub const LineIterator = face.LineIterator;
pub const splitSubpixel = face.splitSubpixel;
pub const subpixel_steps = face.subpixel_steps;

pub const Target = draw.Target;
pub const Clip = draw.Clip;
pub const drawText = draw.drawText;
pub const drawTextTruncated = draw.drawTextTruncated;
pub const drawTextWrapped = draw.drawTextWrapped;
pub const drawGlyph = draw.drawGlyph;
pub const blend = draw.blend;
pub const contrastTable = draw.contrastTable;
pub const premultiply = draw.premultiply;

test {
    std.testing.refAllDecls(@This());
    _ = @import("be.zig");
    _ = @import("gpos.zig");
    _ = face;
    _ = draw;
}
