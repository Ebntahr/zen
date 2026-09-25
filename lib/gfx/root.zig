//! Zen OS 2D graphics library.
//!
//! Pixels are premultiplied ARGB `u32` (0xAARRGGBB, B,G,R,A in memory).
//! Draw through a `Canvas` view; see the individual modules for details.

const std = @import("std");

pub const color = @import("color.zig");
pub const geom = @import("geom.zig");
pub const paint = @import("paint.zig");
pub const canvas = @import("canvas.zig");
pub const shapes = @import("shapes.zig");
pub const path = @import("path.zig");
pub const effects = @import("effects.zig");
pub const glass = @import("glass.zig");
pub const png = @import("png.zig");
/// PNG decoding (`decode`, `decodeFile`).
pub const png_decode = @import("png_decode.zig");
pub const wallpaper = @import("wallpaper.zig");

pub const Color = color.Color;
pub const Pixel = color.Pixel;

pub const Point = geom.Point;
pub const PointF = geom.PointF;
pub const Rect = geom.Rect;
pub const RectF = geom.RectF;

pub const Paint = paint.Paint;
pub const GradientStop = paint.GradientStop;
pub const Gradient = paint.Gradient;
pub const LinearGradient = paint.LinearGradient;
pub const RadialGradient = paint.RadialGradient;
pub const ImagePattern = paint.ImagePattern;

pub const Canvas = canvas.Canvas;
pub const Image = canvas.Image;
pub const Source = canvas.Source;

pub const Radii = shapes.Radii;
pub const RoundRect = shapes.RoundRect;
pub const LineCap = shapes.LineCap;

pub const Path = path.Path;
pub const Transform = path.Transform;
pub const FillRule = path.FillRule;
pub const FillOptions = path.FillOptions;
pub const StrokeOptions = path.StrokeOptions;
pub const fillPathMask = path.fillPathMask;

pub const Shadow = effects.Shadow;
pub const ShadowMask = effects.ShadowMask;

pub const GlassStyle = glass.GlassStyle;
pub const prepareBackdrop = glass.prepareBackdrop;

test {
    _ = png_decode;
    std.testing.refAllDecls(@This());
    _ = color;
    _ = geom;
    _ = paint;
    _ = canvas;
    _ = shapes;
    _ = path;
    _ = effects;
    _ = glass;
    _ = png;
    _ = wallpaper;
}
