//! Procedural icons for Zen OS: full-color app icons (Dock, Finder,
//! Launchpad) and monochrome symbols (sidebars, toolbars, Settings).
//! Everything is vector-drawn at any size with lib/gfx.

const std = @import("std");
const gfx = @import("gfx");

const Canvas = gfx.Canvas;
const Color = gfx.Color;
const Paint = gfx.Paint;
const Path = gfx.Path;
const RectF = gfx.RectF;
const RoundRect = gfx.RoundRect;
const Transform = gfx.Transform;

fn rgb(hex: u24) u32 {
    return Color.fromHex(hex);
}

fn rgba(hex: u24, a: u8) u32 {
    return Color.withAlpha(Color.fromHex(hex), a);
}

/// Sub-rectangle on a 100-unit grid.
fn u(r: RectF, x: f32, y: f32, w: f32, h: f32) RectF {
    const k = r.w / 100;
    return RectF.init(r.x + x * k, r.y + y * k, w * k, h * k);
}

fn grid(r: RectF) Transform {
    return Transform.fit(100, r);
}

/// Rounded "squircle" app tile with a vertical gradient and a glassy rim.
fn tile(c: Canvas, r: RectF, top: u32, bottom: u32) void {
    const g = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = top }, .{ .pos = 1, .color = bottom } });
    const shape = RoundRect.smooth(r, r.w * 0.2237);
    c.fillRRect(shape, &g);
    // Liquid-glass style specular rim.
    const rim = Paint.verticalGradient(r, &.{
        .{ .pos = 0, .color = Color.rgba(255, 255, 255, 150) },
        .{ .pos = 0.45, .color = Color.rgba(255, 255, 255, 18) },
        .{ .pos = 1, .color = Color.rgba(255, 255, 255, 70) },
    });
    var inner = shape;
    inner.rect = r.inset(0.5, 0.5);
    c.strokeRRect(inner, @max(1, r.w / 90), &rim);
    // Soft top sheen.
    const sheen = Paint.verticalGradient(u(r, 0, 0, 100, 50), &.{
        .{ .pos = 0, .color = Color.rgba(255, 255, 255, 46) },
        .{ .pos = 1, .color = Color.rgba(255, 255, 255, 0) },
    });
    var top_half = RoundRect.smooth(r, r.w * 0.2237);
    top_half.rect = u(r, 0, 0, 100, 50);
    top_half.radii.bl = 0;
    top_half.radii.br = 0;
    c.fillRRect(top_half, &sheen);
}

pub const AppIcon = enum {
    finder,
    terminal,
    settings,
    textedit,
    calculator,
    activity,
    trash,
    trash_full,
    launchpad,
    generic,
    zen,

    pub fn fromName(name: []const u8) AppIcon {
        const map = [_]struct { []const u8, AppIcon }{
            .{ "finder", .finder },
            .{ "terminal", .terminal },
            .{ "settings", .settings },
            .{ "textedit", .textedit },
            .{ "calculator", .calculator },
            .{ "activity", .activity },
            .{ "trash", .trash },
            .{ "launchpad", .launchpad },
            .{ "zen", .zen },
        };
        for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], name)) return m[1];
        return .generic;
    }
};

/// Draw a full-color app icon filling the square `r`.
pub fn drawApp(c: Canvas, a: std.mem.Allocator, icon: AppIcon, r: RectF) void {
    drawAppInner(c, a, icon, r) catch {};
}

fn drawAppInner(c: Canvas, a: std.mem.Allocator, icon: AppIcon, r: RectF) !void {
    const k = r.w / 100;
    var p = Path.init(a);
    defer p.deinit();
    switch (icon) {
        .finder => {
            // Two-tone face: light left half, blue right half.
            tile(c, r, rgb(0x7DD3FF), rgb(0x1E6FF0));
            var left = RoundRect.smooth(r, r.w * 0.2237);
            left.radii.tr = 0;
            left.radii.br = 0;
            left.rect = u(r, 0, 0, 52, 100);
            const lg = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = rgb(0xF4FAFF) }, .{ .pos = 1, .color = rgb(0xCFE4FF) } });
            c.fillRRect(left, &lg);
            // Profile line dividing the halves (nose).
            try p.moveTo(52, 0);
            try p.cubicTo(50, 30, 44, 42, 42, 54);
            try p.lineTo(50, 56);
            try p.cubicTo(48, 70, 50, 86, 52, 100);
            try c.strokePath(&p, 3, rgb(0x0D2A5C), .{ .transform = grid(r) });
            // Eyes.
            c.fillRoundRect(u(r, 30, 30, 5, 16), 2.5 * k, rgb(0x0D2A5C));
            c.fillRoundRect(u(r, 66, 30, 5, 16), 2.5 * k, rgb(0x0D2A5C));
            // Smile.
            p.reset();
            try p.moveTo(26, 70);
            try p.quadTo(50, 86, 76, 68);
            try c.strokePath(&p, 3.2, rgb(0x0D2A5C), .{ .transform = grid(r), .cap = .round });
        },
        .terminal => {
            tile(c, r, rgb(0x3A3A40), rgb(0x0E0E12));
            c.fillRoundRect(u(r, 12, 14, 76, 72), 8 * k, rgb(0x121216));
            c.strokeRoundRect(u(r, 12, 14, 76, 72), 8 * k, 1, Color.rgba(255, 255, 255, 40));
            try p.moveTo(24, 38);
            try p.lineTo(38, 50);
            try p.lineTo(24, 62);
            try c.strokePath(&p, 5, rgb(0x5BF08A), .{ .transform = grid(r), .cap = .round });
            c.fillRoundRect(u(r, 44, 58, 22, 5), 2 * k, rgb(0xE8E8EE));
        },
        .settings => {
            tile(c, r, rgb(0xB8BEC8), rgb(0x6C7280));
            const cx = r.x + r.w / 2;
            const cy = r.y + r.h / 2;
            // Gear: teeth as rotated rounded rectangles around a ring.
            const teeth: usize = 12;
            for (0..teeth) |i| {
                const ang = @as(f32, @floatFromInt(i)) * std.math.tau / @as(f32, @floatFromInt(teeth));
                p.reset();
                try p.addRoundRect(RectF.init(-5, -40, 10, 14), 2.5);
                const t = Transform.rotate(ang).then(Transform.scale(k, k)).then(Transform.translate(cx, cy));
                try c.fillPath(&p, rgb(0x3E434D), .{ .transform = t });
            }
            const ring = Paint.verticalGradient(u(r, 14, 14, 72, 72), &.{ .{ .pos = 0, .color = rgb(0x5A606C) }, .{ .pos = 1, .color = rgb(0x2E323A) } });
            c.fillCircle(cx, cy, 30 * k, &ring);
            c.fillCircle(cx, cy, 22 * k, rgb(0xC9CED6));
            c.fillCircle(cx, cy, 14 * k, rgb(0x3E434D));
            c.fillCircle(cx, cy, 6 * k, rgb(0xD8DCE2));
        },
        .textedit => {
            tile(c, r, rgb(0xFAFAFA), rgb(0xDCDCE0));
            // Paper sheet.
            c.fillRoundRect(u(r, 22, 12, 56, 76), 4 * k, rgb(0xFFFFFF));
            c.strokeRoundRect(u(r, 22, 12, 56, 76), 4 * k, 1, Color.rgba(0, 0, 0, 30));
            var y: f32 = 24;
            while (y < 80) : (y += 8) {
                c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 30 * k), @intFromFloat(r.y + y * k), @intFromFloat(40 * k), @intFromFloat(@max(1, 1.6 * k))), Color.rgba(60, 60, 70, 110));
            }
            // Pen.
            p.reset();
            try p.addRoundRect(RectF.init(-4, -34, 8, 60), 3);
            const t = Transform.rotate(0.6).then(Transform.scale(k, k)).then(Transform.translate(r.x + 66 * k, r.y + 56 * k));
            try c.fillPath(&p, rgb(0xF29A2E), .{ .transform = t });
            p.reset();
            try p.addPolygon(&.{ .{ .x = -4, .y = 26 }, .{ .x = 4, .y = 26 }, .{ .x = 0, .y = 36 } });
            try c.fillPath(&p, rgb(0x2B2B30), .{ .transform = t });
        },
        .calculator => {
            tile(c, r, rgb(0x505058), rgb(0x1E1E22));
            const colors = [_]u32{ rgb(0xA5A5AB), rgb(0xA5A5AB), rgb(0xA5A5AB), rgb(0xFF9F0A), rgb(0x505058), rgb(0x505058), rgb(0x505058), rgb(0xFF9F0A), rgb(0x505058), rgb(0x505058), rgb(0x505058), rgb(0xFF9F0A) };
            for (0..12) |i| {
                const col: f32 = @floatFromInt(i % 4);
                const row: f32 = @floatFromInt(i / 4);
                const cx = r.x + (22 + col * 18.5) * k;
                const cy = r.y + (36 + row * 20) * k;
                c.fillCircle(cx, cy, 7.5 * k, colors[i]);
            }
            c.fillRoundRect(u(r, 14, 12, 72, 12), 3 * k, Color.rgba(255, 255, 255, 30));
        },
        .activity => {
            tile(c, r, rgb(0x2B2F36), rgb(0x0B0D10));
            c.fillRoundRect(u(r, 12, 16, 76, 68), 6 * k, rgb(0x0E1A12));
            // Grid.
            var gx: f32 = 12;
            while (gx < 88) : (gx += 12.7) c.drawLine(r.x + gx * k, r.y + 16 * k, r.x + gx * k, r.y + 84 * k, 0.6, Color.rgba(80, 255, 120, 40));
            try p.moveTo(14, 64);
            try p.lineTo(28, 64);
            try p.lineTo(36, 40);
            try p.lineTo(46, 76);
            try p.lineTo(56, 30);
            try p.lineTo(66, 62);
            try p.lineTo(86, 62);
            try c.strokePath(&p, 3.2, rgb(0x3CF07A), .{ .transform = grid(r), .cap = .round });
        },
        .trash, .trash_full => {
            // Translucent glass bin (no tile).
            const body = Paint.verticalGradient(u(r, 22, 22, 56, 70), &.{ .{ .pos = 0, .color = Color.rgba(235, 240, 250, 210) }, .{ .pos = 1, .color = Color.rgba(170, 180, 196, 220) } });
            p.reset();
            try p.moveTo(22, 24);
            try p.lineTo(78, 24);
            try p.lineTo(72, 90);
            try p.quadTo(71, 94, 66, 94);
            try p.lineTo(34, 94);
            try p.quadTo(29, 94, 28, 90);
            try p.close();
            try c.fillPath(&p, &body, .{ .transform = grid(r) });
            try c.strokePath(&p, 1.2, Color.rgba(255, 255, 255, 180), .{ .transform = grid(r) });
            var x: f32 = 34;
            while (x <= 66) : (x += 8) c.drawLine(r.x + x * k, r.y + 30 * k, r.x + (x + (x - 50) * 0.08) * k, r.y + 88 * k, 1, Color.rgba(120, 130, 150, 120));
            c.fillRoundRect(u(r, 18, 16, 64, 9), 4 * k, Color.rgba(220, 226, 236, 230));
            if (icon == .trash_full) {
                c.fillRoundRect(u(r, 30, 8, 30, 14), 3 * k, rgb(0xFFFFFF));
                c.fillRoundRect(u(r, 44, 4, 26, 16), 3 * k, rgb(0xDDE6F5));
            }
        },
        .launchpad => {
            tile(c, r, rgb(0x98A2B3), rgb(0x4B5566));
            const cols = [_]u32{ rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840), rgb(0x0A84FF), rgb(0xBF5AF2), rgb(0xFF9F0A), rgb(0x64D2FF), rgb(0xFF375F), rgb(0x30D158) };
            for (0..9) |i| {
                const col: f32 = @floatFromInt(i % 3);
                const row: f32 = @floatFromInt(i / 3);
                c.fillRoundRect(u(r, 20 + col * 22, 20 + row * 22, 16, 16), 4 * k, cols[i]);
            }
        },
        .zen => {
            tile(c, r, rgb(0xFFB25B), rgb(0xE8446B));
            drawZenMark(c, a, u(r, 18, 18, 64, 64), rgb(0xFFFFFF));
        },
        .generic => {
            tile(c, r, rgb(0xE6E8EE), rgb(0xB9BEC9));
            c.fillRoundRect(u(r, 28, 28, 44, 44), 10 * k, rgb(0x8A93A3));
            c.fillRoundRect(u(r, 38, 38, 24, 24), 6 * k, rgb(0xEEF1F6));
        },
    }
}

/// The Zen logo: an ensō brush circle with a gap.
pub fn drawZenMark(c: Canvas, a: std.mem.Allocator, r: RectF, color: u32) void {
    var p = Path.init(a);
    defer p.deinit();
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const rad = r.w * 0.40;
    p.arc(cx, cy, rad, -1.2, 4.4, false) catch return;
    c.strokePath(&p, r.w * 0.11, color, .{ .cap = .round }) catch {};
    c.fillCircle(cx + rad * @cos(@as(f32, -1.2)), cy + rad * @sin(@as(f32, -1.2)), r.w * 0.075, color);
}

/// Blue folder icon (Finder).
pub fn drawFolder(c: Canvas, r: RectF, tint: u32) void {
    const k = r.w / 100;
    const back = Color.lerp(tint, rgb(0x000000), 0.12);
    c.fillRRect(.{ .rect = u(r, 6, 16, 38, 16), .radii = .{ .tl = 6 * k, .tr = 6 * k } }, back);
    c.fillRoundRect(u(r, 6, 22, 88, 64), 7 * k, back);
    const front = Paint.verticalGradient(u(r, 6, 32, 88, 54), &.{ .{ .pos = 0, .color = Color.lerp(tint, rgb(0xFFFFFF), 0.35) }, .{ .pos = 1, .color = tint } });
    c.fillRoundRect(u(r, 6, 32, 88, 54), 7 * k, &front);
    c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 8 * k), @intFromFloat(r.y + 33 * k), @intFromFloat(84 * k), @intFromFloat(@max(1, k))), Color.rgba(255, 255, 255, 110));
}

/// Generic document icon with a folded corner and optional extension label.
pub fn drawDocument(c: Canvas, a: std.mem.Allocator, r: RectF, accent: u32) void {
    var p = Path.init(a);
    defer p.deinit();
    const g = grid(r);
    p.moveTo(18, 6) catch return;
    p.lineTo(64, 6) catch return;
    p.lineTo(84, 26) catch return;
    p.lineTo(84, 94) catch return;
    p.lineTo(18, 94) catch return;
    p.close() catch return;
    c.fillPath(&p, rgb(0xFFFFFF), .{ .transform = g }) catch {};
    c.strokePath(&p, 1, Color.rgba(0, 0, 0, 60), .{ .transform = g }) catch {};
    p.reset();
    p.moveTo(64, 6) catch return;
    p.lineTo(64, 26) catch return;
    p.lineTo(84, 26) catch return;
    p.close() catch return;
    c.fillPath(&p, rgb(0xE4E6EC), .{ .transform = g }) catch {};
    const k = r.w / 100;
    var y: f32 = 40;
    while (y < 84) : (y += 8) {
        c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 28 * k), @intFromFloat(r.y + y * k), @intFromFloat(46 * k), @intFromFloat(@max(1, 1.5 * k))), Color.withAlpha(accent, 120));
    }
}

// ---------------------------------------------------------------------------
// Monochrome symbols (SF-Symbols-like), stroke based, drawn in `r`.
// ---------------------------------------------------------------------------

pub const Symbol = enum {
    folder,
    document,
    house,
    desktop,
    download,
    music,
    photo,
    film,
    trash,
    gear,
    person,
    lock,
    magnifier,
    info,
    power,
    chevron_left,
    chevron_right,
    plus,
    xmark,
    checkmark,
    wifi,
    keyboard,
    paintbrush,
    hand,
    shield,
    cpu,
    memory,
    apps,
    display,
    bell,
    clock,
    globe,
    terminal,
    sidebar,
    list,
    grid,
    arrow_up,
    arrow_down,
    disk,
    user_group,
    battery,
    moon,
    sun,
};

pub fn drawSymbol(c: Canvas, a: std.mem.Allocator, sym: Symbol, r: RectF, color: u32) void {
    drawSymbolInner(c, a, sym, r, color) catch {};
}

fn drawSymbolInner(c: Canvas, a: std.mem.Allocator, sym: Symbol, r: RectF, color: u32) !void {
    var p = Path.init(a);
    defer p.deinit();
    const g = grid(r);
    const k = r.w / 100;
    const sw: f32 = 8; // stroke width in grid units
    const stroke = gfx.StrokeOptions{ .transform = g, .cap = .round };
    switch (sym) {
        .folder => {
            try p.moveTo(10, 30);
            try p.lineTo(10, 80);
            try p.lineTo(90, 80);
            try p.lineTo(90, 36);
            try p.lineTo(48, 36);
            try p.lineTo(40, 26);
            try p.lineTo(14, 26);
            try p.close();
            try c.strokePath(&p, sw, color, stroke);
        },
        .document => {
            try p.moveTo(24, 10);
            try p.lineTo(60, 10);
            try p.lineTo(78, 28);
            try p.lineTo(78, 90);
            try p.lineTo(24, 90);
            try p.close();
            try p.moveTo(58, 12);
            try p.lineTo(58, 30);
            try p.lineTo(76, 30);
            try c.strokePath(&p, sw, color, stroke);
        },
        .house => {
            try p.moveTo(12, 48);
            try p.lineTo(50, 14);
            try p.lineTo(88, 48);
            try p.moveTo(22, 40);
            try p.lineTo(22, 86);
            try p.lineTo(78, 86);
            try p.lineTo(78, 40);
            try p.moveTo(42, 86);
            try p.lineTo(42, 62);
            try p.lineTo(58, 62);
            try p.lineTo(58, 86);
            try c.strokePath(&p, sw, color, stroke);
        },
        .desktop, .display => {
            try p.addRoundRect(RectF.init(10, 16, 80, 54), 8);
            try c.strokePath(&p, sw, color, stroke);
            p.reset();
            try p.moveTo(36, 86);
            try p.lineTo(64, 86);
            try p.moveTo(50, 70);
            try p.lineTo(50, 86);
            try c.strokePath(&p, sw, color, stroke);
        },
        .download, .arrow_down => {
            try p.moveTo(50, 12);
            try p.lineTo(50, 66);
            try p.moveTo(28, 46);
            try p.lineTo(50, 68);
            try p.lineTo(72, 46);
            if (sym == .download) {
                try p.moveTo(16, 70);
                try p.lineTo(16, 88);
                try p.lineTo(84, 88);
                try p.lineTo(84, 70);
            }
            try c.strokePath(&p, sw, color, stroke);
        },
        .arrow_up => {
            try p.moveTo(50, 88);
            try p.lineTo(50, 14);
            try p.moveTo(26, 38);
            try p.lineTo(50, 14);
            try p.lineTo(74, 38);
            try c.strokePath(&p, sw, color, stroke);
        },
        .music => {
            try p.moveTo(38, 74);
            try p.lineTo(38, 20);
            try p.lineTo(80, 12);
            try p.lineTo(80, 66);
            try c.strokePath(&p, sw, color, stroke);
            c.fillEllipse(r.x + 28 * k, r.y + 76 * k, 12 * k, 10 * k, color);
            c.fillEllipse(r.x + 70 * k, r.y + 68 * k, 12 * k, 10 * k, color);
        },
        .photo => {
            try p.addRoundRect(RectF.init(10, 18, 80, 64), 10);
            try c.strokePath(&p, sw, color, stroke);
            p.reset();
            try p.moveTo(14, 74);
            try p.lineTo(38, 48);
            try p.lineTo(56, 66);
            try p.lineTo(68, 54);
            try p.lineTo(86, 74);
            try c.strokePath(&p, sw, color, stroke);
            c.fillCircle(r.x + 66 * k, r.y + 36 * k, 7 * k, color);
        },
        .film => {
            try p.addRoundRect(RectF.init(14, 12, 72, 76), 8);
            try p.moveTo(30, 12);
            try p.lineTo(30, 88);
            try p.moveTo(70, 12);
            try p.lineTo(70, 88);
            try p.moveTo(14, 50);
            try p.lineTo(86, 50);
            try c.strokePath(&p, sw, color, stroke);
        },
        .trash => {
            try p.moveTo(14, 24);
            try p.lineTo(86, 24);
            try p.moveTo(38, 24);
            try p.lineTo(40, 12);
            try p.lineTo(60, 12);
            try p.lineTo(62, 24);
            try p.moveTo(22, 24);
            try p.lineTo(28, 90);
            try p.lineTo(72, 90);
            try p.lineTo(78, 24);
            try p.moveTo(42, 40);
            try p.lineTo(42, 74);
            try p.moveTo(58, 40);
            try p.lineTo(58, 74);
            try c.strokePath(&p, sw, color, stroke);
        },
        .gear => {
            const cx = r.x + r.w / 2;
            const cy = r.y + r.h / 2;
            for (0..8) |i| {
                const ang = @as(f32, @floatFromInt(i)) * std.math.tau / 8.0;
                p.reset();
                try p.addRoundRect(RectF.init(-8, -46, 16, 20), 4);
                const t = Transform.rotate(ang).then(Transform.scale(k, k)).then(Transform.translate(cx, cy));
                try c.fillPath(&p, color, .{ .transform = t });
            }
            c.strokeCircle(cx, cy, 26 * k, sw * k, color);
            c.strokeCircle(cx, cy, 9 * k, sw * k * 0.9, color);
        },
        .person => {
            c.strokeCircle(r.x + 50 * k, r.y + 32 * k, 18 * k, sw * k, color);
            try p.moveTo(16, 90);
            try p.cubicTo(18, 64, 34, 58, 50, 58);
            try p.cubicTo(66, 58, 82, 64, 84, 90);
            try c.strokePath(&p, sw, color, stroke);
        },
        .user_group => {
            c.strokeCircle(r.x + 38 * k, r.y + 36 * k, 14 * k, sw * k, color);
            c.strokeCircle(r.x + 70 * k, r.y + 40 * k, 11 * k, sw * k * 0.9, color);
            try p.moveTo(10, 88);
            try p.cubicTo(12, 66, 24, 60, 38, 60);
            try p.cubicTo(52, 60, 64, 66, 66, 88);
            try p.moveTo(68, 62);
            try p.cubicTo(82, 62, 90, 70, 92, 86);
            try c.strokePath(&p, sw, color, stroke);
        },
        .lock => {
            try p.addRoundRect(RectF.init(20, 44, 60, 46), 8);
            try c.fillPath(&p, color, .{ .transform = g });
            p.reset();
            try p.moveTo(32, 46);
            try p.lineTo(32, 32);
            try p.cubicTo(32, 8, 68, 8, 68, 32);
            try p.lineTo(68, 46);
            try c.strokePath(&p, sw, color, stroke);
        },
        .magnifier => {
            c.strokeCircle(r.x + 42 * k, r.y + 42 * k, 26 * k, sw * k, color);
            try p.moveTo(62, 62);
            try p.lineTo(86, 86);
            try c.strokePath(&p, sw * 1.2, color, stroke);
        },
        .info => {
            c.strokeCircle(r.x + 50 * k, r.y + 50 * k, 40 * k, sw * k * 0.8, color);
            c.fillCircle(r.x + 50 * k, r.y + 30 * k, 5.5 * k, color);
            try p.moveTo(50, 44);
            try p.lineTo(50, 72);
            try c.strokePath(&p, sw, color, stroke);
        },
        .power => {
            try p.arc(50, 54, 32, -1.05, 4.19, false);
            try p.moveTo(50, 10);
            try p.lineTo(50, 46);
            try c.strokePath(&p, sw, color, stroke);
        },
        .chevron_left => {
            try p.moveTo(64, 16);
            try p.lineTo(30, 50);
            try p.lineTo(64, 84);
            try c.strokePath(&p, sw * 1.2, color, stroke);
        },
        .chevron_right => {
            try p.moveTo(36, 16);
            try p.lineTo(70, 50);
            try p.lineTo(36, 84);
            try c.strokePath(&p, sw * 1.2, color, stroke);
        },
        .plus => {
            try p.moveTo(50, 16);
            try p.lineTo(50, 84);
            try p.moveTo(16, 50);
            try p.lineTo(84, 50);
            try c.strokePath(&p, sw * 1.2, color, stroke);
        },
        .xmark => {
            try p.moveTo(22, 22);
            try p.lineTo(78, 78);
            try p.moveTo(78, 22);
            try p.lineTo(22, 78);
            try c.strokePath(&p, sw * 1.2, color, stroke);
        },
        .checkmark => {
            try p.moveTo(16, 52);
            try p.lineTo(40, 76);
            try p.lineTo(84, 24);
            try c.strokePath(&p, sw * 1.3, color, stroke);
        },
        .wifi => {
            try p.arc(50, 80, 62, -2.36, -0.785, false);
            try p.moveTo(50 + 42 * @cos(@as(f32, -2.36)), 80 + 42 * @sin(@as(f32, -2.36)));
            try p.arc(50, 80, 42, -2.36, -0.785, false);
            try p.moveTo(50 + 22 * @cos(@as(f32, -2.36)), 80 + 22 * @sin(@as(f32, -2.36)));
            try p.arc(50, 80, 22, -2.36, -0.785, false);
            try c.strokePath(&p, sw, color, stroke);
            c.fillCircle(r.x + 50 * k, r.y + 80 * k, 6 * k, color);
        },
        .keyboard => {
            try p.addRoundRect(RectF.init(6, 24, 88, 54), 9);
            try c.strokePath(&p, sw, color, stroke);
            var row: f32 = 0;
            while (row < 2) : (row += 1) {
                var col: f32 = 0;
                while (col < 6) : (col += 1) c.fillRect(gfx.Rect.init(@intFromFloat(r.x + (18 + col * 12) * k), @intFromFloat(r.y + (36 + row * 12) * k), @intFromFloat(@max(1, 6 * k)), @intFromFloat(@max(1, 6 * k))), color);
            }
            c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 30 * k), @intFromFloat(r.y + 62 * k), @intFromFloat(40 * k), @intFromFloat(@max(1, 5 * k))), color);
        },
        .paintbrush => {
            try p.moveTo(84, 14);
            try p.lineTo(44, 58);
            try c.strokePath(&p, sw * 1.2, color, stroke);
            p.reset();
            try p.moveTo(40, 56);
            try p.cubicTo(28, 56, 22, 66, 22, 76);
            try p.cubicTo(22, 84, 16, 88, 12, 88);
            try p.cubicTo(34, 94, 50, 82, 48, 64);
            try p.close();
            try c.fillPath(&p, color, .{ .transform = g });
        },
        .hand => {
            try p.moveTo(30, 60);
            try p.lineTo(30, 26);
            try p.moveTo(42, 50);
            try p.lineTo(42, 16);
            try p.moveTo(54, 50);
            try p.lineTo(54, 18);
            try p.moveTo(66, 54);
            try p.lineTo(66, 28);
            try p.moveTo(30, 60);
            try p.cubicTo(24, 54, 16, 56, 18, 64);
            try p.lineTo(34, 86);
            try p.lineTo(62, 88);
            try p.cubicTo(70, 80, 66, 64, 66, 54);
            try c.strokePath(&p, sw, color, stroke);
        },
        .shield => {
            try p.moveTo(50, 8);
            try p.lineTo(84, 20);
            try p.cubicTo(84, 58, 72, 80, 50, 92);
            try p.cubicTo(28, 80, 16, 58, 16, 20);
            try p.close();
            try c.strokePath(&p, sw, color, stroke);
        },
        .cpu, .memory => {
            try p.addRoundRect(RectF.init(24, 24, 52, 52), 6);
            try c.strokePath(&p, sw, color, stroke);
            p.reset();
            var i: f32 = 0;
            while (i < 3) : (i += 1) {
                const o = 36 + i * 14;
                try p.moveTo(o, 10);
                try p.lineTo(o, 22);
                try p.moveTo(o, 78);
                try p.lineTo(o, 90);
                if (sym == .cpu) {
                    try p.moveTo(10, o);
                    try p.lineTo(22, o);
                    try p.moveTo(78, o);
                    try p.lineTo(90, o);
                }
            }
            try c.strokePath(&p, sw * 0.8, color, stroke);
        },
        .apps, .grid => {
            var row: f32 = 0;
            while (row < 3) : (row += 1) {
                var col: f32 = 0;
                while (col < 3) : (col += 1) c.fillRoundRect(u(r, 12 + col * 28, 12 + row * 28, 20, 20), 5 * k, color);
            }
        },
        .bell => {
            try p.moveTo(22, 72);
            try p.lineTo(78, 72);
            try p.cubicTo(70, 62, 72, 50, 72, 42);
            try p.cubicTo(72, 24, 62, 14, 50, 14);
            try p.cubicTo(38, 14, 28, 24, 28, 42);
            try p.cubicTo(28, 50, 30, 62, 22, 72);
            try p.close();
            try c.strokePath(&p, sw, color, stroke);
            c.fillEllipse(r.x + 50 * k, r.y + 84 * k, 9 * k, 6 * k, color);
        },
        .clock => {
            c.strokeCircle(r.x + 50 * k, r.y + 50 * k, 38 * k, sw * k, color);
            try p.moveTo(50, 26);
            try p.lineTo(50, 50);
            try p.lineTo(66, 60);
            try c.strokePath(&p, sw, color, stroke);
        },
        .globe => {
            c.strokeCircle(r.x + 50 * k, r.y + 50 * k, 38 * k, sw * k * 0.8, color);
            c.strokeEllipse(r.x + 50 * k, r.y + 50 * k, 16 * k, 38 * k, sw * k * 0.7, color);
            try p.moveTo(12, 50);
            try p.lineTo(88, 50);
            try p.moveTo(18, 32);
            try p.lineTo(82, 32);
            try p.moveTo(18, 68);
            try p.lineTo(82, 68);
            try c.strokePath(&p, sw * 0.7, color, stroke);
        },
        .terminal => {
            try p.addRoundRect(RectF.init(8, 16, 84, 68), 10);
            try c.strokePath(&p, sw, color, stroke);
            p.reset();
            try p.moveTo(24, 38);
            try p.lineTo(38, 50);
            try p.lineTo(24, 62);
            try p.moveTo(46, 64);
            try p.lineTo(66, 64);
            try c.strokePath(&p, sw, color, stroke);
        },
        .sidebar => {
            try p.addRoundRect(RectF.init(8, 16, 84, 68), 10);
            try p.moveTo(38, 16);
            try p.lineTo(38, 84);
            try c.strokePath(&p, sw, color, stroke);
        },
        .list => {
            var i: f32 = 0;
            while (i < 3) : (i += 1) {
                const y = 24 + i * 26;
                c.fillCircle(r.x + 16 * k, r.y + y * k, 6 * k, color);
                try p.moveTo(32, y);
                try p.lineTo(90, y);
            }
            try c.strokePath(&p, sw, color, stroke);
        },
        .disk => {
            try p.addRoundRect(RectF.init(8, 30, 84, 40), 10);
            try c.strokePath(&p, sw, color, stroke);
            c.fillCircle(r.x + 76 * k, r.y + 50 * k, 5 * k, color);
        },
        .battery => {
            try p.addRoundRect(RectF.init(6, 30, 80, 40), 10);
            try c.strokePath(&p, sw * 0.8, color, stroke);
            c.fillRoundRect(u(r, 14, 38, 56, 24), 4 * k, color);
            c.fillRoundRect(u(r, 88, 42, 7, 16), 3 * k, color);
        },
        .moon => {
            try p.arc(50, 50, 38, 0.9, 5.4, false);
            try p.cubicTo(58, 30, 58, 72, 74, 80);
            try p.close();
            try c.fillPath(&p, color, .{ .transform = g });
        },
        .sun => {
            c.fillCircle(r.x + 50 * k, r.y + 50 * k, 20 * k, color);
            for (0..8) |i| {
                const ang = @as(f32, @floatFromInt(i)) * std.math.tau / 8.0;
                try p.moveTo(50 + 32 * @cos(ang), 50 + 32 * @sin(ang));
                try p.lineTo(50 + 44 * @cos(ang), 50 + 44 * @sin(ang));
            }
            try c.strokePath(&p, sw, color, stroke);
        },
    }
}

test "draw every icon without crashing" {
    const a = std.testing.allocator;
    var img = try gfx.Image.init(a, 128, 128);
    defer img.deinit(a);
    const c = img.canvas();
    inline for (std.meta.fields(AppIcon)) |f| {
        drawApp(c, a, @enumFromInt(f.value), RectF.init(8, 8, 112, 112));
    }
    inline for (std.meta.fields(Symbol)) |f| {
        drawSymbol(c, a, @enumFromInt(f.value), RectF.init(4, 4, 20, 20), Color.black);
    }
    drawFolder(c, RectF.init(0, 0, 64, 64), Color.fromHex(0x5AB0FF));
    drawDocument(c, a, RectF.init(0, 0, 64, 64), Color.fromHex(0x0A84FF));
}
