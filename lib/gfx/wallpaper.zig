//! Procedural abstract wallpapers in the style of macOS: soft color fields,
//! large blurred color blobs and layered, lit, flowing wave sheets, with
//! gentle grain / dithering to avoid banding.
//!
//! The color field is evaluated in floating point on a coarse grid (every
//! `detail` pixels), converted to 8.8 fixed point, then bilinearly upsampled,
//! grained and dithered with integer math only. Everything that depends only on
//! x (wave curves, light modulation, blob falloff, vignette) or only on y is
//! cached per column / row.

const std = @import("std");
const canvas_mod = @import("canvas.zig");

const Allocator = std.mem.Allocator;
const Canvas = canvas_mod.Canvas;

pub const Variant = enum {
    tahoe_day,
    tahoe_night,
    golden_gate,
    aurora,

    pub fn name(v: Variant) []const u8 {
        return switch (v) {
            .tahoe_day => "Tahoe Day",
            .tahoe_night => "Tahoe Night",
            .golden_gate => "Golden Gate",
            .aurora => "Aurora",
        };
    }
};

pub const Options = struct {
    /// Grid spacing (px) of the evaluated field; 1 = every pixel (slowest).
    /// 3-4 are 2-3x faster but may stair-step along the crisp wave crests.
    detail: u32 = 2,
    /// Amplitude of the film grain in 8-bit steps (dithering alone is ~1).
    grain: f32 = 1.6,
    /// Seed for the grain pattern.
    seed: u32 = 0x5EED,
};

/// Linear-ish sRGB color with channels in [0, 1].
const Rgb = [3]f32;

fn hex(c: u24) Rgb {
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
    };
}

/// One sine term of a layer curve (amplitude in heights, cycles per width).
const Wave = struct { amp: f32, freq: f32, phase: f32 };

/// A large soft color field with Gaussian falloff (normalized coordinates).
const Blob = struct {
    x: f32,
    y: f32,
    rx: f32,
    ry: f32,
    color: Rgb,
    strength: f32,
};

/// A flowing wave layer. `sheet` fills everything below its curve (a lit,
/// translucent fold); `ribbon` is a glowing aurora curtain along the curve.
const Layer = struct {
    kind: enum { sheet, ribbon } = .sheet,
    /// Curve: base + tilt * (u - 0.5) + sum(amp * sin(2pi (freq * u + phase))).
    base: f32,
    tilt: f32 = 0,
    waves: [3]Wave = .{ .{ .amp = 0, .freq = 0, .phase = 0 }, .{ .amp = 0, .freq = 0, .phase = 0 }, .{ .amp = 0, .freq = 0, .phase = 0 } },
    /// Sheet body: color at the edge (left / right end) easing into `deep` over `depth`.
    edge: Rgb,
    edge_right: ?Rgb = null,
    deep: Rgb,
    depth: f32 = 0.2,
    opacity: f32 = 1,
    softness: f32 = 0.003,
    /// Soft light just inside the edge and a thin specular glint on it.
    sheen: f32 = 0.25,
    sheen_width: f32 = 0.05,
    glint: f32 = 0.35,
    glint_width: f32 = 0.006,
    light_color: Rgb = .{ 1, 1, 1 },
    /// Variation of the light along the crest (cycles per width, phase).
    light_freq: f32 = 1.3,
    light_phase: f32 = 0,
    /// Ambient-occlusion shadow cast above the edge.
    ao: f32 = 0.2,
    ao_width: f32 = 0.08,
    /// Ribbon falloff above / below the curve.
    up: f32 = 0.1,
    down: f32 = 0.02,
};

/// A complete wallpaper recipe: background gradient, blobs, then layers back to front.
const Spec = struct {
    top: Rgb,
    mid: Rgb,
    bottom: Rgb,
    mid_pos: f32 = 0.5,
    blobs: []const Blob,
    layers: []const Layer,
    vignette: f32 = 0.18,
    /// Color that ambient occlusion multiplies towards (tinted shadows).
    shadow: Rgb = .{ 0, 0, 0 },
};

fn spec(v: Variant) Spec {
    return switch (v) {
        inline else => |tag| comptime specFor(tag),
    };
}

fn waves3(a0: f32, f0: f32, p0: f32, a1: f32, f1: f32, p1: f32, a2: f32, f2: f32, p2: f32) [3]Wave {
    return .{ .{ .amp = a0, .freq = f0, .phase = p0 }, .{ .amp = a1, .freq = f1, .phase = p1 }, .{ .amp = a2, .freq = f2, .phase = p2 } };
}

fn specFor(comptime v: Variant) Spec {
    return switch (v) {
        .tahoe_day => .{
            .top = hex(0xBFE2FA),
            .mid = hex(0x62B0EE),
            .bottom = hex(0x1D5CC6),
            .mid_pos = 0.46,
            .blobs = &.{
                .{ .x = 0.8, .y = 0.02, .rx = 0.34, .ry = 0.22, .color = hex(0xFFFFFF), .strength = 0.5 },
                .{ .x = 0.04, .y = 0.5, .rx = 0.4, .ry = 0.35, .color = hex(0x30CDD2), .strength = 0.5 },
                .{ .x = 0.45, .y = 0.28, .rx = 0.3, .ry = 0.2, .color = hex(0xA3B3FF), .strength = 0.35 },
                .{ .x = 0.96, .y = 0.92, .rx = 0.45, .ry = 0.35, .color = hex(0x1449B8), .strength = 0.55 },
            },
            .layers = &.{
                .{ .base = 0.52, .tilt = -0.36, .waves = waves3(0.07, 0.55, 0.05, 0.02, 1.3, 0.6, 0.006, 2.7, 0.2), .edge = hex(0xF2FBFF), .edge_right = hex(0xD9EEFF), .deep = hex(0x80C0F2), .depth = 0.25, .opacity = 0.5, .sheen = 0.3, .glint = 0.35, .light_phase = 0.1, .ao = 0.18 },
                .{ .base = 0.66, .tilt = -0.3, .waves = waves3(0.09, 0.5, 0.3, 0.025, 1.2, 0.1, 0.006, 3.1, 0.7), .edge = hex(0xB5F0F0), .edge_right = hex(0xC2E1FF), .deep = hex(0x2E8ADF), .depth = 0.22, .opacity = 0.85, .sheen = 0.35, .glint = 0.45, .light_phase = 0.45, .ao = 0.25 },
                .{ .base = 0.8, .tilt = -0.18, .waves = waves3(0.07, 0.6, 0.62, 0.02, 1.5, 0.35, 0.005, 3.3, 0.5), .edge = hex(0x7ED2F2), .edge_right = hex(0x8CB6FF), .deep = hex(0x1850BE), .depth = 0.18, .opacity = 0.95, .sheen = 0.35, .glint = 0.5, .light_phase = 0.8, .ao = 0.3 },
                .{ .base = 0.93, .tilt = -0.1, .waves = waves3(0.035, 0.7, 0.2, 0.012, 1.9, 0.8, 0.004, 3.9, 0.1), .edge = hex(0x3C8DE2), .deep = hex(0x0C3690), .depth = 0.12, .opacity = 1.0, .sheen = 0.25, .glint = 0.35, .light_phase = 0.3, .ao = 0.3 },
            },
            .vignette = 0.1,
            .shadow = hex(0x2A5CB8),
        },
        .tahoe_night => .{
            .top = hex(0x050920),
            .mid = hex(0x131A5E),
            .bottom = hex(0x1A1048),
            .mid_pos = 0.5,
            .blobs = &.{
                .{ .x = 0.12, .y = 0.3, .rx = 0.4, .ry = 0.35, .color = hex(0x2A44E0), .strength = 0.5 },
                .{ .x = 0.88, .y = 0.62, .rx = 0.45, .ry = 0.4, .color = hex(0x8A2FD0), .strength = 0.5 },
                .{ .x = 0.6, .y = 0.12, .rx = 0.35, .ry = 0.25, .color = hex(0x1B2A96), .strength = 0.45 },
            },
            .layers = &.{
                .{ .base = 0.48, .tilt = -0.34, .waves = waves3(0.07, 0.55, 0.05, 0.02, 1.3, 0.6, 0.006, 2.7, 0.2), .edge = hex(0x6A7CFF), .edge_right = hex(0xA46BFF), .deep = hex(0x1A2070), .depth = 0.22, .opacity = 0.55, .sheen = 0.3, .glint = 0.45, .light_color = hex(0xAFC0FF), .light_phase = 0.1, .ao = 0.3 },
                .{ .base = 0.63, .tilt = -0.3, .waves = waves3(0.09, 0.5, 0.3, 0.025, 1.2, 0.1, 0.006, 3.1, 0.7), .edge = hex(0x4E5EF0), .edge_right = hex(0x9150F0), .deep = hex(0x12145A), .depth = 0.2, .opacity = 0.8, .sheen = 0.3, .glint = 0.5, .light_color = hex(0xC4B4FF), .light_phase = 0.45, .ao = 0.35 },
                .{ .base = 0.79, .tilt = -0.2, .waves = waves3(0.07, 0.6, 0.62, 0.02, 1.5, 0.35, 0.005, 3.3, 0.5), .edge = hex(0x3444C8), .edge_right = hex(0x6B34C8), .deep = hex(0x0A0C3A), .depth = 0.16, .opacity = 0.92, .sheen = 0.28, .glint = 0.5, .light_color = hex(0x9DB0FF), .light_phase = 0.8, .ao = 0.4 },
                .{ .base = 0.93, .tilt = -0.1, .waves = waves3(0.035, 0.7, 0.2, 0.012, 1.9, 0.8, 0.004, 3.9, 0.1), .edge = hex(0x252C92), .deep = hex(0x060726), .depth = 0.1, .opacity = 1.0, .sheen = 0.2, .glint = 0.4, .light_color = hex(0xB09CFF), .light_phase = 0.3, .ao = 0.4 },
            },
            .vignette = 0.3,
        },
        .golden_gate => .{
            .top = hex(0x172061),
            .mid = hex(0xD2467C),
            .bottom = hex(0xFFA04A),
            .mid_pos = 0.46,
            .blobs = &.{
                .{ .x = 0.72, .y = 0.58, .rx = 0.35, .ry = 0.22, .color = hex(0xFFD27A), .strength = 0.75 },
                .{ .x = 0.18, .y = 0.15, .rx = 0.5, .ry = 0.35, .color = hex(0x252B86), .strength = 0.55 },
                .{ .x = 0.3, .y = 0.45, .rx = 0.35, .ry = 0.22, .color = hex(0xB23284), .strength = 0.45 },
            },
            .layers = &.{
                .{ .base = 0.6, .tilt = 0.26, .waves = waves3(0.06, 0.55, 0.15, 0.02, 1.4, 0.7, 0.006, 3.0, 0.4), .edge = hex(0xFFC98A), .edge_right = hex(0xFF8FA8), .deep = hex(0xC03A74), .depth = 0.25, .opacity = 0.6, .sheen = 0.35, .glint = 0.4, .light_color = hex(0xFFE9C8), .light_phase = 0.2, .ao = 0.14 },
                .{ .base = 0.72, .tilt = 0.28, .waves = waves3(0.08, 0.5, 0.45, 0.022, 1.25, 0.2, 0.006, 3.4, 0.8), .edge = hex(0xFF9A63), .edge_right = hex(0xEE5A92), .deep = hex(0x6A2272), .depth = 0.22, .opacity = 0.85, .sheen = 0.35, .glint = 0.45, .light_color = hex(0xFFD9A8), .light_phase = 0.55, .ao = 0.22 },
                .{ .base = 0.84, .tilt = 0.2, .waves = waves3(0.06, 0.6, 0.8, 0.02, 1.5, 0.35, 0.005, 3.1, 0.6), .edge = hex(0xE55A86), .edge_right = hex(0xB83E90), .deep = hex(0x2B1762), .depth = 0.18, .opacity = 0.95, .sheen = 0.3, .glint = 0.4, .light_color = hex(0xFFC4D2), .light_phase = 0.9, .ao = 0.28 },
                .{ .base = 0.95, .tilt = 0.1, .waves = waves3(0.03, 0.75, 0.3, 0.01, 2.0, 0.6, 0.004, 4.2, 0.1), .edge = hex(0x7E2F90), .deep = hex(0x121043), .depth = 0.1, .opacity = 1.0, .sheen = 0.2, .glint = 0.3, .light_color = hex(0xFFA8C8), .light_phase = 0.4, .ao = 0.3 },
            },
            .vignette = 0.2,
        },
        .aurora => .{
            .top = hex(0x02060F),
            .mid = hex(0x071A2B),
            .bottom = hex(0x0A1628),
            .mid_pos = 0.55,
            .blobs = &.{
                .{ .x = 0.35, .y = 0.55, .rx = 0.5, .ry = 0.25, .color = hex(0x0C5446), .strength = 0.45 },
                .{ .x = 0.85, .y = 0.2, .rx = 0.4, .ry = 0.3, .color = hex(0x33196A), .strength = 0.5 },
            },
            .layers = &.{
                .{ .kind = .ribbon, .base = 0.36, .tilt = 0.1, .waves = waves3(0.06, 0.8, 0.2, 0.02, 1.9, 0.6, 0.008, 4.1, 0.3), .edge = hex(0x8A6CFF), .deep = hex(0xC86BFF), .opacity = 0.5, .up = 0.24, .down = 0.02 },
                .{ .kind = .ribbon, .base = 0.52, .tilt = -0.16, .waves = waves3(0.09, 0.6, 0.55, 0.03, 1.7, 0.1, 0.01, 3.9, 0.7), .edge = hex(0x3CF5A8), .deep = hex(0x7C6BFF), .opacity = 0.95, .up = 0.36, .down = 0.022 },
                .{ .kind = .ribbon, .base = 0.44, .tilt = 0.04, .waves = waves3(0.05, 1.1, 0.85, 0.02, 2.5, 0.4, 0.008, 5.1, 0.1), .edge = hex(0x6BE8FF), .deep = hex(0x3CF5A8), .opacity = 0.35, .up = 0.16, .down = 0.018 },
                .{ .base = 0.64, .tilt = 0.1, .waves = waves3(0.03, 1.3, 0.1, 0.015, 2.9, 0.5, 0.005, 6.1, 0.3), .edge = hex(0x0E2A36), .deep = hex(0x071522), .depth = 0.15, .opacity = 0.75, .sheen = 0.1, .glint = 0.25, .light_color = hex(0x3CF5A8), .ao = 0.2 },
                .{ .base = 0.8, .tilt = -0.08, .waves = waves3(0.04, 0.8, 0.3, 0.02, 1.9, 0.7, 0.006, 3.8, 0.2), .edge = hex(0x17404F), .deep = hex(0x050B16), .depth = 0.15, .opacity = 0.97, .sheen = 0.2, .glint = 0.45, .light_color = hex(0x6FF5C4), .ao = 0.35 },
                .{ .base = 0.91, .tilt = 0.06, .waves = waves3(0.03, 1.1, 0.6, 0.012, 2.4, 0.1, 0.004, 4.5, 0.5), .edge = hex(0x122C40), .deep = hex(0x03060D), .depth = 0.1, .opacity = 1.0, .sheen = 0.15, .glint = 0.4, .light_color = hex(0x9C7BFF), .light_phase = 0.5, .ao = 0.4 },
            },
            .vignette = 0.3,
        },
    };
}

inline fn mix3(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

inline fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Smooth compact bump: 1 at 0, 0 at |t| >= 1 (cheap Gaussian stand-in).
inline fn bump(t: f32) f32 {
    const a = @abs(t);
    if (a >= 1) return 0;
    const q = 1 - a * a;
    return q * q * q;
}

/// Screen-blends `light` scaled by `k` onto `c`.
inline fn screen3(c: Rgb, light: Rgb, k: f32) Rgb {
    return .{ c[0] + (1 - c[0]) * light[0] * k, c[1] + (1 - c[1]) * light[1] * k, c[2] + (1 - c[2]) * light[2] * k };
}

const max_layers = 8;
const max_blobs = 8;

/// Layer constants derived once per render (reciprocals avoid per-sample divisions).
const Prepared = struct {
    inv_ao: f32,
    inv_soft2: f32,
    depth_k: f32,
    inv_sheen: f32,
    inv_glint: f32,
    inv_up: f32,
    inv_down: f32,

    /// `cell` is the grid spacing in normalized height units: features are kept
    /// at least ~2 cells wide so a coarse grid softens edges instead of aliasing.
    fn init(l: Layer, cell: f32) Prepared {
        return .{
            .inv_ao = 1 / l.ao_width,
            .inv_soft2 = 1 / (2 * @max(l.softness, cell)),
            .depth_k = l.depth * 0.35,
            .inv_sheen = 1 / l.sheen_width,
            .inv_glint = 1 / @max(l.glint_width, 2 * cell),
            .inv_up = 1 / l.up,
            .inv_down = 1 / @max(l.down, 2 * cell),
        };
    }
};

/// Fixed-point color: 8.8 per channel.
const Fx3 = [3]i32;

/// Field evaluator with everything that depends only on x cached per column.
const Field = struct {
    s: Spec,
    prep: [max_layers]Prepared,
    /// Per column: curve height, light modulation (sheets) or ray pattern
    /// (ribbons), and the sheet edge color, per layer.
    curve: [][max_layers]f32,
    modul: [][max_layers]f32,
    edge: [][max_layers]Rgb,
    /// Per column: horizontal blob falloff and vignette term.
    blob_x: [][max_blobs]f32,
    vig_x: []f32,
    aspect: f32,

    fn init(allocator: Allocator, s: Spec, cols: usize, step: f32, width: f32, height: f32) !Field {
        std.debug.assert(s.layers.len <= max_layers and s.blobs.len <= max_blobs);
        var f = Field{
            .s = s,
            .prep = undefined,
            .curve = try allocator.alloc([max_layers]f32, cols),
            .modul = try allocator.alloc([max_layers]f32, cols),
            .edge = try allocator.alloc([max_layers]Rgb, cols),
            .blob_x = try allocator.alloc([max_blobs]f32, cols),
            .vig_x = try allocator.alloc(f32, cols),
            .aspect = width / height,
        };
        for (s.layers, 0..) |l, k| f.prep[k] = Prepared.init(l, step / height);
        const tau = 2 * std.math.pi;
        const norm = 0.25 * f.aspect * f.aspect + 0.25;
        for (0..cols) |i| {
            const u = (@as(f32, @floatFromInt(i)) * step) / width;
            for (s.layers, 0..) |l, k| {
                var y = l.base + l.tilt * (u - 0.5);
                for (l.waves) |w| y += w.amp * @sin(tau * (w.freq * u + w.phase));
                f.curve[i][k] = y;
                f.edge[i][k] = if (l.edge_right) |er| mix3(l.edge, er, u) else l.edge;
                f.modul[i][k] = switch (l.kind) {
                    // Light catches parts of the crest.
                    .sheet => 0.5 + 0.5 * @sin(tau * (l.light_freq * u + l.light_phase)),
                    // Incommensurate sines give an irregular ray pattern.
                    .ribbon => blk: {
                        const ph = @as(f32, @floatFromInt(k)) * 0.37;
                        const r = 0.5 * @sin(tau * (13.3 * u + ph)) + 0.3 * @sin(tau * (29.1 * u + 2.1 * ph)) + 0.2 * @sin(tau * (47.7 * u + 0.4));
                        break :blk std.math.clamp(0.5 + 0.6 * r, 0, 1);
                    },
                };
            }
            for (s.blobs, 0..) |b, k| {
                const dx = (u - b.x) / b.rx;
                f.blob_x[i][k] = @exp(-dx * dx * 2);
            }
            const du = (u - 0.5) * f.aspect;
            f.vig_x[i] = du * du / norm;
        }
        return f;
    }

    fn deinit(f: *Field, allocator: Allocator) void {
        allocator.free(f.curve);
        allocator.free(f.modul);
        allocator.free(f.edge);
        allocator.free(f.blob_x);
        allocator.free(f.vig_x);
    }

    /// Evaluates one row of the field at normalized height `v` into 8.8 fixed point.
    fn row(f: *const Field, v: f32, out: []Fx3) void {
        const s = &f.s;
        const bg = if (v < s.mid_pos)
            mix3(s.top, s.mid, smoothstep(0, s.mid_pos, v))
        else
            mix3(s.mid, s.bottom, smoothstep(s.mid_pos, 1, v));
        var blob_y: [max_blobs]f32 = undefined;
        for (s.blobs, 0..) |b, k| {
            const dy = (v - b.y) / b.ry;
            blob_y[k] = @exp(-dy * dy * 2) * b.strength;
        }
        const dv = v - 0.5;
        const vig_y = dv * dv / (0.25 * f.aspect * f.aspect + 0.25);
        for (out, 0..) |*o, i| {
            var c = bg;
            for (s.blobs, 0..) |b, k| {
                const wgt = f.blob_x[i][k] * blob_y[k];
                if (wgt > 1.0 / 1024.0) c = mix3(c, b.color, @min(wgt, 1));
            }
            for (s.layers, 0..) |*l, k| {
                const pr = &f.prep[k];
                const d = v - f.curve[i][k];
                const m = f.modul[i][k];
                switch (l.kind) {
                    .sheet => {
                        if (d < 0 and l.ao > 0) {
                            const occ = l.ao * bump(-d * pr.inv_ao);
                            c = .{ c[0] * (1 - occ + occ * s.shadow[0]), c[1] * (1 - occ + occ * s.shadow[1]), c[2] * (1 - occ + occ * s.shadow[2]) };
                        }
                        const t = std.math.clamp(d * pr.inv_soft2 + 0.5, 0, 1);
                        const a = t * t * (3 - 2 * t) * l.opacity;
                        if (a > 0) {
                            const dd = @max(d, 0);
                            c = mix3(c, mix3(f.edge[i][k], l.deep, dd / (dd + pr.depth_k)), a);
                            const lit = l.sheen * (0.35 + 0.65 * m) * bump(d * pr.inv_sheen) +
                                l.glint * m * m * bump((d - l.softness) * pr.inv_glint);
                            if (lit > 0) c = screen3(c, l.light_color, lit * a);
                        }
                    },
                    .ribbon => {
                        // Aurora curtain: bright lower hem, irregular rays fading upwards
                        // while shifting from `edge` to `deep` (the upper color).
                        if (d < 0) {
                            const t = -d * pr.inv_up;
                            if (t < 1) {
                                const q = 1 - t;
                                const ray = 1 - @min(t * 2.5, 1) * (1 - m);
                                c = screen3(c, mix3(l.edge, l.deep, @min(t * 1.4, 1)), q * q * ray * l.opacity);
                            }
                        } else {
                            c = screen3(c, l.edge, bump(d * pr.inv_down) * l.opacity);
                        }
                    },
                }
            }
            const vig = 1 - s.vignette * (f.vig_x[i] + vig_y);
            inline for (0..3) |ch| o.*[ch] = @intFromFloat(std.math.clamp(c[ch] * vig, 0, 1) * (255.0 * 256.0));
        }
    }
};

/// Integer hash for grain.
inline fn hash(x: u32, y: u32, seed: u32) u32 {
    var h = x *% 0x8DA6B343 +% y *% 0xD8163841 +% seed *% 0xCB1AB31F;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return h;
}

/// Renders `variant` over the whole canvas (opaque; the clip is ignored).
pub fn render(c: Canvas, allocator: Allocator, variant: Variant, opts: Options) !void {
    if (c.width <= 0 or c.height <= 0) return;
    const s = spec(variant);
    const step: usize = std.math.clamp(opts.detail, 1, 16);
    const w: usize = @intCast(c.width);
    const h: usize = @intCast(c.height);
    const cols = w / step + 2;
    const stepf: f32 = @floatFromInt(step);
    const hf: f32 = @floatFromInt(h);
    var field = try Field.init(allocator, s, cols, stepf, @floatFromInt(w), hf);
    defer field.deinit(allocator);

    // Two coarse rows bracketing the current output row, plus their vertical blend.
    const rows = try allocator.alloc(Fx3, cols * 3);
    defer allocator.free(rows);
    var r0 = rows[0..cols];
    var r1 = rows[cols .. 2 * cols];
    const vrow = rows[2 * cols ..];
    var have: usize = 0; // index of the coarse row stored in r0
    field.row(0, r0);
    field.row(stepf / hf, r1);

    const grain_q: i32 = @intFromFloat(std.math.clamp(opts.grain, 0, 16) * 256);
    for (0..h) |y| {
        const gy = y / step;
        while (have < gy) {
            std.mem.swap([]Fx3, &r0, &r1);
            have += 1;
            field.row(@as(f32, @floatFromInt((have + 1) * step)) / hf, r1);
        }
        // Everything below is integer: vertical blend per coarse column, then
        // horizontal blend, grain / dither and quantization per pixel.
        const wy: i32 = @intCast((y - gy * step) * 256 / step);
        for (vrow, r0, r1) |*vp, a, b| {
            inline for (0..3) |ch| vp[ch] = a[ch] + (((b[ch] - a[ch]) * wy) >> 8);
        }
        const out = c.row(@intCast(y));
        var x: usize = 0;
        var gx: usize = 0;
        while (x < w) : (gx += 1) {
            const a = vrow[gx];
            const b = vrow[gx + 1];
            var j: usize = 0;
            while (j < step and x < w) : ({
                j += 1;
                x += 1;
            }) {
                const wx: i32 = @intCast(j * 256 / step);
                const hsh = hash(@intCast(x), @intCast(y), opts.seed);
                const tri: i32 = @as(i32, @intCast(hsh & 0xFF)) + @as(i32, @intCast((hsh >> 8) & 0xFF)) - 255;
                const noise = ((tri * grain_q) >> 8) + 128;
                var px: u32 = 0xFF000000;
                inline for (0..3) |ch| {
                    const v = a[ch] + (((b[ch] - a[ch]) * wx) >> 8) + noise;
                    const q: u32 = @intCast(std.math.clamp(v >> 8, 0, 255));
                    px |= q << (16 - ch * 8);
                }
                out[x] = px;
            }
        }
    }
}

test "wallpapers render opaque, varied images" {
    const a = std.testing.allocator;
    var img = try canvas_mod.Image.init(a, 96, 60);
    defer img.deinit(a);
    for (std.enums.values(Variant)) |v| {
        try render(img.canvas(), a, v, .{});
        var lo: u32 = 255;
        var hi: u32 = 0;
        for (img.pixels) |p| {
            try std.testing.expectEqual(@as(u32, 0xFF), p >> 24);
            const l = @import("color.zig").Color.luma(p);
            lo = @min(lo, l);
            hi = @max(hi, l);
        }
        try std.testing.expect(hi - lo > 20);
    }
}
