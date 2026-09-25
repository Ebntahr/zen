//! Host-side demo: renders a macOS 26 style desktop with Liquid Glass to PNG.
//!
//!     zig run lib/gfx/demo.zig -- /tmp/gfx_demo.png
//!
//! Also writes light/dark scenes and every wallpaper variant to /tmp/gfx_out/.

const std = @import("std");
const gfx = @import("root.zig");

const Allocator = std.mem.Allocator;
const Canvas = gfx.Canvas;
const Image = gfx.Image;
const Color = gfx.Color;
const Rect = gfx.Rect;
const RectF = gfx.RectF;
const Paint = gfx.Paint;
const Path = gfx.Path;
const Transform = gfx.Transform;
const RoundRect = gfx.RoundRect;
const GlassStyle = gfx.GlassStyle;
const Shadow = gfx.Shadow;

const W = 1280;
const H = 800;
const out_dir = "/tmp/gfx_out";

const Theme = struct {
    is_dark: bool,
    wallpaper: gfx.wallpaper.Variant,
    window_bg: u32,
    card_bg: u32,
    text: u32,
    text2: u32,
    separator: u32,
    menu_text: u32,
    accent: u32,
    sidebar: GlassStyle,
    toolbar: GlassStyle,
    bar: GlassStyle,
    shadow_alpha: u8,

    const light: Theme = .{
        .is_dark = false,
        .wallpaper = .tahoe_day,
        .window_bg = Color.fromHex(0xF4F5F8),
        .card_bg = Color.fromHex(0xFFFFFF),
        .text = Color.rgba(29, 29, 31, 210),
        .text2 = Color.rgba(29, 29, 31, 90),
        .separator = Color.rgba(0, 0, 0, 22),
        .menu_text = Color.rgba(10, 20, 40, 200),
        .accent = Color.fromHex(0x0A84FF),
        .sidebar = GlassStyle.light,
        .toolbar = GlassStyle.light,
        .bar = GlassStyle.clear,
        .shadow_alpha = 84,
    };

    const dark: Theme = .{
        .is_dark = true,
        .wallpaper = .tahoe_night,
        .window_bg = Color.fromHex(0x1C1D22),
        .card_bg = Color.fromHex(0x2A2B31),
        .text = Color.rgba(255, 255, 255, 215),
        .text2 = Color.rgba(255, 255, 255, 95),
        .separator = Color.rgba(255, 255, 255, 24),
        .menu_text = Color.rgba(255, 255, 255, 220),
        .accent = Color.fromHex(0x0A84FF),
        .sidebar = GlassStyle.dark,
        .toolbar = GlassStyle.dark,
        .bar = GlassStyle.clear,
        .shadow_alpha = 130,
    };
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const main_out = if (args.len > 1) args[1] else "/tmp/gfx_demo.png";
    std.fs.cwd().makePath(out_dir) catch {};

    var screen = try Image.init(a, W, H);
    defer screen.deinit(a);
    const sc = screen.canvas();

    for (std.enums.values(gfx.wallpaper.Variant)) |v| {
        try gfx.wallpaper.render(sc, a, v, .{});
        var buf: [128]u8 = undefined;
        try save(sc, try std.fmt.bufPrint(&buf, out_dir ++ "/wallpaper_{s}.png", .{@tagName(v)}));
    }

    try renderScene(a, sc, Theme.dark);
    try save(sc, out_dir ++ "/demo_dark.png");
    try renderScene(a, sc, Theme.light);
    try save(sc, out_dir ++ "/demo_light.png");
    try save(sc, main_out);
}

fn save(c: Canvas, file: []const u8) !void {
    try gfx.png.writeFile(c, file);
    std.debug.print("wrote {s}\n", .{file});
}

// ---------------------------------------------------------------------------
// Scene

const Ctx = struct {
    a: Allocator,
    s: Canvas,
    th: Theme,
    /// Scratch copy of the screen used as a glass backdrop.
    bd: *Image,

    /// Blurred snapshot of what lies behind the given glass regions.
    fn backdrop(ctx: *Ctx, regions: []const Rect, radius: f32) !Canvas {
        const b = ctx.bd.canvas();
        for (regions) |r| try gfx.prepareBackdrop(b, ctx.a, ctx.s, r, radius);
        return b;
    }

    fn text(ctx: *Ctx, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        ctx.s.fillRoundRect(Rect.init(x, y, w, h), @as(f32, @floatFromInt(h)) * 0.5, color);
    }

    /// Renders a window: shadow on this canvas, then `drawFn` into an offscreen
    /// surface (local coordinates) composited through the rounded window shape.
    fn window(ctx: *Ctx, win: Rect, radius: f32, drawFn: *const fn (*Ctx, Rect) anyerror!void) !void {
        try ctx.shadowed(win, radius, ctx.th.shadow_alpha, true);
        const w: u32 = @intCast(win.w);
        const h: u32 = @intCast(win.h);
        var surf = try Image.init(ctx.a, w, h);
        defer surf.deinit(ctx.a);
        var sbd = try Image.init(ctx.a, w, h);
        defer sbd.deinit(ctx.a);
        var wc = Ctx{ .a = ctx.a, .s = surf.canvas(), .th = ctx.th, .bd = &sbd };
        wc.s.clear(ctx.th.window_bg);
        try drawFn(&wc, Rect.init(0, 0, win.w, win.h));
        const shape = RoundRect.smooth(win, radius);
        const pat = Paint{ .image = .{ .src = surf.canvas(), .x = @floatFromInt(win.x), .y = @floatFromInt(win.y) } };
        ctx.s.fillRRect(shape, &pat);
        var border = shape;
        border.rect = win.toF().inset(0.5, 0.5);
        ctx.s.strokeRRect(border, 1, if (ctx.th.is_dark) Color.rgba(255, 255, 255, 30) else Color.rgba(0, 0, 0, 18));
    }

    fn shadowed(ctx: *Ctx, r: Rect, radius: f32, alpha: u8, big: bool) !void {
        const k: f32 = if (big) 1 else 0.45;
        try ctx.s.drawShadow(ctx.a, r, radius, .{
            .color = Color.rgba(0, 0, 0, alpha),
            .blur = 26 * k,
            .offset_y = @intFromFloat(20 * k),
            .spread = -4,
        });
        try ctx.s.drawShadow(ctx.a, r, radius, .{
            .color = Color.rgba(0, 0, 0, alpha / 2),
            .blur = 3,
            .offset_y = 1,
        });
    }
};

fn renderScene(a: Allocator, s: Canvas, th: Theme) !void {
    var bd = try Image.init(a, W, H);
    defer bd.deinit(a);
    var ctx = Ctx{ .a = a, .s = s, .th = th, .bd = &bd };

    try gfx.wallpaper.render(s, a, th.wallpaper, .{});

    // Desktop widgets.
    const clock = Rect.init(1086, 50, 170, 170);
    const media = Rect.init(1086, 236, 170, 60);
    for ([_]Rect{ clock, media }) |r| try s.drawShadow(a, r, 30, .{ .color = Color.rgba(0, 0, 0, 40), .blur = 12, .offset_y = 6, .knockout = true });
    {
        const b = try ctx.backdrop(&.{ clock, media }, 14);
        s.drawGlassRRect(RoundRect.smooth(clock, 30), b, if (th.is_dark) GlassStyle.dark else GlassStyle.light);
        s.drawGlassCapsule(media, b, GlassStyle.clear);
    }
    drawClock(&ctx, clock);
    try drawMediaControl(&ctx, media);

    const win1 = Rect.init(40, 62, 760, 512);
    const win2 = Rect.init(690, 214, 380, 424);
    try ctx.window(win1, 20, drawPhotosWindow);
    try ctx.window(win2, 20, drawShowcaseWindow);

    // Menu bar and dock share one backdrop snapshot.
    const bar = Rect.init(0, 0, W, 30);
    const dock_rect = dockRect();
    try s.drawShadow(a, dock_rect, 30, .{ .color = Color.rgba(0, 0, 0, 45), .blur = 14, .offset_y = 8, .knockout = true });
    {
        const b = try ctx.backdrop(&.{ bar, dock_rect }, 8);
        var bar_style = th.bar;
        bar_style.refraction = 3;
        bar_style.bevel = 8;
        bar_style.glow_width = 6;
        bar_style.rim_light = 0.5;
        s.drawGlass(bar, 0, b, bar_style);
        s.drawGlassRRect(RoundRect.smooth(dock_rect, 30), b, th.bar);
    }
    try drawMenuBar(&ctx, bar);
    try drawDock(&ctx, dock_rect);
}

// ---------------------------------------------------------------------------
// Menu bar

fn drawMenuBar(ctx: *Ctx, bar: Rect) !void {
    const s = ctx.s;
    const t = ctx.th.menu_text;
    const cy: f32 = @as(f32, @floatFromInt(bar.h)) * 0.5;
    // Zen ensō logo: an open brush circle.
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.arc(26, cy, 6.5, -1.2, 4.6, false);
    try s.strokePath(&p, 2.2, t, .{});
    // App name (bold) and menus.
    ctx.text(46, 11, 38, 9, t);
    var x: i32 = 100;
    for ([_]i32{ 26, 28, 30, 44, 30 }) |w| {
        ctx.text(x, 11, w, 8, Color.scaleAlpha(t, 200));
        x += w + 18;
    }
    // Status area: control center, battery, wifi, clock.
    const right = bar.right() - 14;
    ctx.text(right - 92, 11, 92, 8, t);
    // Wi-Fi: three arcs and a dot.
    const wx: f32 = @floatFromInt(right - 122);
    for ([_]f32{ 3.5, 7, 10.5 }) |r| {
        p.reset();
        try p.arc(wx, cy + 5, r, -std.math.pi * 0.75, -std.math.pi * 0.25, false);
        try s.strokePath(&p, 1.7, t, .{});
    }
    s.fillCircle(wx, cy + 5, 1.4, t);
    // Battery.
    const bx = right - 170;
    s.strokeRoundRect(RectF.init(@floatFromInt(bx), cy - 5.5, 24, 11), 3, 1.1, Color.scaleAlpha(t, 160));
    s.fillRoundRect(RectF.init(@floatFromInt(bx + 2), cy - 3.5, 16, 7), 1.5, t);
    s.fillRoundRect(RectF.init(@floatFromInt(bx + 25), cy - 2, 1.8, 4), 0.9, Color.scaleAlpha(t, 160));
    // Control center: two stacked capsules.
    const ccx = right - 200;
    s.strokeRoundRect(RectF.init(@floatFromInt(ccx), cy - 6, 16, 5.5), 2.75, 1.2, t);
    s.fillRoundRect(RectF.init(@floatFromInt(ccx), cy + 1, 16, 5.5), 2.75, t);
}

// ---------------------------------------------------------------------------
// Desktop widgets

fn drawClock(ctx: *Ctx, r: Rect) void {
    const s = ctx.s;
    const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) * 0.5;
    const cy = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) * 0.5;
    const face: f32 = 62;
    const face_color = if (ctx.th.is_dark) Color.rgba(20, 22, 30, 150) else Color.rgba(255, 255, 255, 170);
    s.fillCircle(cx, cy, face, face_color);
    const tick = if (ctx.th.is_dark) Color.rgba(255, 255, 255, 200) else Color.rgba(20, 20, 30, 190);
    for (0..60) |i| {
        const ang = @as(f32, @floatFromInt(i)) * std.math.pi / 30.0;
        const major = i % 5 == 0;
        const r0: f32 = if (major) face - 12 else face - 7;
        const r1: f32 = face - 4;
        s.drawLine(cx + r0 * @sin(ang), cy - r0 * @cos(ang), cx + r1 * @sin(ang), cy - r1 * @cos(ang), if (major) 2.2 else 0.9, if (major) tick else Color.scaleAlpha(tick, 110));
    }
    // 10:09:32
    const hand = struct {
        fn draw(c: Canvas, x: f32, y: f32, ang: f32, len: f32, back: f32, width: f32, col: u32) void {
            c.drawLine(x - back * @sin(ang), y + back * @cos(ang), x + len * @sin(ang), y - len * @cos(ang), width, col);
        }
    }.draw;
    hand(s, cx, cy, (10.0 + 9.0 / 60.0) * std.math.pi / 6.0, 30, 0, 4.5, tick);
    hand(s, cx, cy, 9.5 * std.math.pi / 30.0, 46, 0, 3.2, tick);
    hand(s, cx, cy, 32.0 * std.math.pi / 30.0, 50, 12, 1.2, Color.fromHex(0xFF9F0A));
    s.fillCircle(cx, cy, 3.6, Color.fromHex(0xFF9F0A));
    s.fillCircle(cx, cy, 1.4, Color.white);
}

fn drawMediaControl(ctx: *Ctx, r: Rect) !void {
    const s = ctx.s;
    const t: u32 = if (ctx.th.is_dark) Color.white else Color.rgba(20, 24, 40, 220);
    const cy = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) * 0.5;
    const x0: f32 = @floatFromInt(r.x);
    // Album art thumbnail: a tiny wallpaper, drawn as a circle via an image paint.
    var art = try Image.init(ctx.a, 64, 40);
    defer art.deinit(ctx.a);
    try gfx.wallpaper.render(art.canvas(), ctx.a, .golden_gate, .{ .detail = 1 });
    const art_paint = Paint{ .image = gfx.paint.ImagePattern.cover(art.canvas(), RectF.init(x0 + 12, cy - 18, 36, 36)) };
    s.fillCircle(x0 + 30, cy, 18, &art_paint);
    // Play glyph (triangle path) and progress capsule.
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.addPolygon(&.{ .{ .x = x0 + 132, .y = cy - 8 }, .{ .x = x0 + 146, .y = cy }, .{ .x = x0 + 132, .y = cy + 8 } });
    try s.fillPath(&p, t, .{});
    ctx.text(r.x + 58, r.y + 20, 56, 8, t);
    s.fillRoundRect(RectF.init(x0 + 58, cy + 6, 60, 4), 2, Color.scaleAlpha(t, 70));
    s.fillRoundRect(RectF.init(x0 + 58, cy + 6, 26, 4), 2, t);
}

// ---------------------------------------------------------------------------
// Window 1: a photo library with a floating glass sidebar and glass toolbar

fn trafficLights(s: Canvas, x: f32, y: f32) void {
    const colors = [_]u32{ Color.fromHex(0xFF5F57), Color.fromHex(0xFEBC2E), Color.fromHex(0x28C840) };
    for (colors, 0..) |c, i| {
        const cx = x + @as(f32, @floatFromInt(i)) * 20;
        s.fillCircle(cx, y, 6.5, c);
        s.strokeCircle(cx, y, 6.25, 0.5, Color.rgba(0, 0, 0, 40));
    }
}

fn drawPhotosWindow(ctx: *Ctx, win: Rect) !void {
    const s = ctx.s;
    const th = ctx.th;

    // Photo grid (scrolls under the sidebar and toolbar).
    var thumbs = try makeThumbnails(ctx.a);
    defer for (&thumbs) |*t| t.deinit(ctx.a);
    const cols = 4;
    const tile_w: i32 = 170;
    const tile_h: i32 = 124;
    const gap: i32 = 8;
    const gx0 = win.x + 20;
    const gy0 = win.y + 16;
    for (0..4) |row| for (0..cols) |col| {
        const x = gx0 + @as(i32, @intCast(col)) * (tile_w + gap) + 8;
        const y = gy0 + @as(i32, @intCast(row)) * (tile_h + gap);
        const r = Rect.init(x, y, tile_w, tile_h);
        const idx = (row * cols + col) % thumbs.len;
        const paint = Paint{ .image = gfx.paint.ImagePattern.cover(thumbs[idx].canvas(), r.toF()) };
        s.fillRRect(RoundRect.smooth(r, 10), &paint);
    };

    // Floating glass sidebar and toolbar controls over the content.
    const sidebar = Rect.init(win.x + 8, win.y + 8, 220, win.h - 16);
    const seg = Rect.init(win.x + 260, win.y + 14, 168, 34);
    const search = Rect.init(win.right() - 196, win.y + 14, 180, 34);
    const add = Rect.init(win.right() - 240, win.y + 14, 34, 34);
    for ([_]Rect{ seg, search, add }) |r| try s.drawShadow(ctx.a, r, 17, .{ .color = Color.rgba(0, 0, 0, 30), .blur = 6, .offset_y = 3, .knockout = true });
    try s.drawShadow(ctx.a, sidebar, 14, .{ .color = Color.rgba(0, 0, 0, 36), .blur = 10, .offset_y = 4, .knockout = true });
    const b = try ctx.backdrop(&.{ sidebar, seg.unionWith(search).unionWith(add) }, 22);
    s.drawGlassRRect(RoundRect.smooth(sidebar, 14), b, th.sidebar);
    s.drawGlassCapsule(seg, b, th.toolbar);
    s.drawGlassCapsule(search, b, th.toolbar);
    s.drawGlassCapsule(add, b, th.toolbar);

    // Toolbar contents.
    const segf = seg.toF();
    s.fillRoundRect(RectF.init(segf.x + 3, segf.y + 3, 56, segf.h - 6), 14, if (th.is_dark) Color.rgba(255, 255, 255, 40) else Color.rgba(255, 255, 255, 200));
    ctx.text(seg.x + 16, seg.y + 13, 30, 8, th.text);
    ctx.text(seg.x + 70, seg.y + 13, 34, 8, th.text2);
    ctx.text(seg.x + 120, seg.y + 13, 34, 8, th.text2);
    const sf = search.toF();
    s.strokeCircle(sf.x + 20, sf.y + 16, 5, 1.6, th.text2);
    s.drawLine(sf.x + 23.5, sf.y + 19.5, sf.x + 27, sf.y + 23, 1.8, th.text2);
    ctx.text(search.x + 36, search.y + 13, 60, 8, th.text2);
    const af = add.toF();
    s.drawLine(af.x + 17, af.y + 11, af.x + 17, af.y + 23, 1.8, th.text);
    s.drawLine(af.x + 11, af.y + 17, af.x + 23, af.y + 17, 1.8, th.text);

    // Sidebar contents.
    trafficLights(s, @as(f32, @floatFromInt(sidebar.x)) + 20, @as(f32, @floatFromInt(sidebar.y)) + 20);
    var y = sidebar.y + 52;
    ctx.text(sidebar.x + 16, y, 54, 7, th.text2);
    y += 20;
    const icon_colors = [_]u32{ Color.fromHex(0x0A84FF), Color.fromHex(0xFF9F0A), Color.fromHex(0xFF375F), Color.fromHex(0x30D158), Color.fromHex(0xBF5AF2) };
    const widths = [_]i32{ 64, 88, 52, 76, 70 };
    for (icon_colors, widths, 0..) |ic, w, i| {
        const row = Rect.init(sidebar.x + 8, y, sidebar.w - 16, 30);
        if (i == 0) s.fillRoundRect(row, 9, Color.withAlpha(th.accent, if (th.is_dark) 90 else 46));
        s.fillRRect(RoundRect.smooth(Rect.init(row.x + 10, row.y + 7, 16, 16), 4.5), ic);
        ctx.text(row.x + 36, row.y + 11, w, 8, th.text);
        y += 32;
    }
    y += 14;
    ctx.text(sidebar.x + 16, y, 44, 7, th.text2);
    y += 20;
    for ([_]i32{ 70, 58, 92 }) |w| {
        s.strokeRoundRect(RectF.init(@floatFromInt(sidebar.x + 18), @floatFromInt(y + 7), 16, 16), 4, 1.4, th.accent);
        ctx.text(sidebar.x + 44, y + 11, w, 8, th.text);
        y += 32;
    }
    // Storage meter at the bottom of the sidebar.
    const my = sidebar.bottom() - 40;
    ctx.text(sidebar.x + 16, my, 80, 7, th.text2);
    s.fillRoundRect(Rect.init(sidebar.x + 16, my + 16, sidebar.w - 32, 6), 3, th.separator);
    const meter = Paint.linearGradient(.{ .x = @floatFromInt(sidebar.x + 16), .y = 0 }, .{ .x = @floatFromInt(sidebar.x + 140), .y = 0 }, &.{
        .{ .pos = 0, .color = Color.fromHex(0x64D2FF) },
        .{ .pos = 1, .color = th.accent },
    });
    s.fillRoundRect(Rect.init(sidebar.x + 16, my + 16, 124, 6), 3, &meter);
}

/// Small "photos": wallpaper crops and gradient art.
fn makeThumbnails(a: Allocator) ![6]Image {
    var out: [6]Image = undefined;
    const variants = [_]gfx.wallpaper.Variant{ .golden_gate, .aurora, .tahoe_night, .tahoe_day };
    for (variants, 0..) |v, i| {
        out[i] = try Image.init(a, 200, 140);
        try gfx.wallpaper.render(out[i].canvas(), a, v, .{ .detail = 1 });
    }
    // Two abstract gradient "photos".
    for (4..6) |i| {
        out[i] = try Image.init(a, 200, 140);
        const c = out[i].canvas();
        const bg = Paint.angledGradient(RectF.init(0, 0, 200, 140), if (i == 4) 135 else 200, if (i == 4) &[_]gfx.GradientStop{
            .{ .pos = 0, .color = Color.fromHex(0xFFD60A) },
            .{ .pos = 0.5, .color = Color.fromHex(0xFF6B3D) },
            .{ .pos = 1, .color = Color.fromHex(0xC2185B) },
        } else &[_]gfx.GradientStop{
            .{ .pos = 0, .color = Color.fromHex(0x30D5C8) },
            .{ .pos = 1, .color = Color.fromHex(0x2F3DA8) },
        });
        c.fillRect(c.bounds(), &bg);
        const orb = Paint.radialGradient(.{ .x = 70, .y = 55 }, 60, &.{
            .{ .pos = 0, .color = Color.rgba(255, 255, 255, 190) },
            .{ .pos = 1, .color = 0 },
        });
        c.fillCircle(80, 62, 60, &orb);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Window 2: one card per drawing primitive

fn drawShowcaseWindow(ctx: *Ctx, win: Rect) !void {
    const s = ctx.s;
    const th = ctx.th;
    trafficLights(s, @as(f32, @floatFromInt(win.x)) + 22, @as(f32, @floatFromInt(win.y)) + 22);
    ctx.text(win.x + @divTrunc(win.w, 2) - 40, win.y + 18, 80, 9, th.text);

    const cw: i32 = 172;
    const ch: i32 = 100;
    const x0 = win.x + 12;
    const y0 = win.y + 46;
    var cards: [6]Rect = undefined;
    for (0..6) |i| {
        const col: i32 = @intCast(i % 2);
        const row: i32 = @intCast(i / 2);
        cards[i] = Rect.init(x0 + col * (cw + 12), y0 + row * (ch + 10), cw, ch);
        s.fillRRect(RoundRect.smooth(cards[i], 14), th.card_bg);
    }
    try cardGradients(ctx, cards[0]);
    cardShapes(ctx, cards[1]);
    cardLines(ctx, cards[2]);
    try cardPaths(ctx, cards[3]);
    try cardChart(ctx, cards[4]);
    try cardImages(ctx, cards[5]);

    // Glass buttons floating over the bottom of the content.
    const btn = Rect.init(win.x + 20, win.bottom() - 52, 150, 38);
    const toggle = Rect.init(win.right() - 96, win.bottom() - 50, 72, 34);
    for ([_]Rect{ btn, toggle }) |r| try s.drawShadow(ctx.a, r, 19, .{ .color = Color.rgba(0, 0, 0, 40), .blur = 6, .offset_y = 3, .knockout = true });
    const b = try ctx.backdrop(&.{btn.unionWith(toggle)}, 10);
    s.drawGlassCapsule(btn, b, GlassStyle.tinted(th.accent));
    ctx.text(btn.x + 40, btn.y + 15, 70, 9, Color.white);
    s.drawGlassCapsule(toggle, b, GlassStyle.tinted(Color.fromHex(0x30D158)));
    // An inset text field: inner shadow on a rounded well.
    const field = Rect.init(btn.right() + 14, btn.y + 3, toggle.x - btn.right() - 28, 32);
    s.fillRoundRect(field, 10, th.card_bg);
    try s.drawInnerShadow(ctx.a, field, 10, .{ .color = Color.rgba(0, 0, 0, if (th.is_dark) 150 else 70), .blur = 3, .offset_y = 2 });
    ctx.text(field.x + 12, field.y + 12, 44, 8, th.text2);
    const knob = Rect.init(toggle.right() - 46, toggle.y + 3, 43, toggle.h - 6);
    try s.drawShadow(ctx.a, knob, 14, .{ .color = Color.rgba(0, 0, 0, 50), .blur = 2, .offset_y = 1 });
    s.fillRoundRect(knob, 14, Color.white);
}

fn cardGradients(ctx: *Ctx, r: Rect) !void {
    const s = ctx.s;
    const f = r.toF();
    const sq = RectF.init(f.x + 14, f.y + 14, 72, 72);
    const lin = Paint.angledGradient(sq, 135, &.{
        .{ .pos = 0, .color = Color.fromHex(0xFF2D55) },
        .{ .pos = 0.5, .color = Color.fromHex(0xFF9F0A) },
        .{ .pos = 1, .color = Color.fromHex(0xFFD60A) },
    });
    s.fillRRect(RoundRect.smooth(sq, 16), &lin);
    const orb = Paint.radialGradient(.{ .x = f.x + 116, .y = f.y + 38 }, 44, &.{
        .{ .pos = 0, .color = Color.fromHex(0xE0F4FF) },
        .{ .pos = 0.35, .color = Color.fromHex(0x5AC8FA) },
        .{ .pos = 0.8, .color = Color.fromHex(0x3634A3) },
        .{ .pos = 1, .color = Color.fromHex(0x1C1A5E) },
    });
    s.fillCircle(f.x + 128, f.y + 50, 32, &orb);
}

fn cardShapes(ctx: *Ctx, r: Rect) void {
    const s = ctx.s;
    const f = r.toF();
    s.fillCircle(f.x + 34, f.y + 34, 18, Color.fromHex(0x0A84FF));
    s.strokeCircle(f.x + 34, f.y + 34, 22, 2.5, Color.withAlpha(Color.fromHex(0x0A84FF), 110));
    s.fillEllipse(f.x + 110, f.y + 32, 40, 16, Color.fromHex(0xFF9F0A));
    s.strokeEllipse(f.x + 110, f.y + 32, 40, 16, 1.5, Color.fromHex(0xC93400));
    s.strokeRoundRect(RectF.init(f.x + 16.5, f.y + 64.5, 60, 22), 11, 2, Color.fromHex(0x30D158));
    s.fillRRect(.{ .rect = RectF.init(f.x + 90, f.y + 62, 66, 26), .radii = .{ .tl = 13, .br = 13, .tr = 3, .bl = 3 } }, Color.fromHex(0xBF5AF2));
}

fn cardLines(ctx: *Ctx, r: Rect) void {
    const s = ctx.s;
    const f = r.toF();
    const ox = f.x + 16;
    const oy = f.y + f.h - 14;
    for (0..9) |i| {
        const t = @as(f32, @floatFromInt(i)) / 8.0;
        const ang = -std.math.pi * 0.5 * t;
        const len: f32 = 74;
        const col = Color.lerp(Color.fromHex(0xFF375F), Color.fromHex(0x5E5CE6), t);
        s.drawLine(ox, oy, ox + len * @cos(ang), oy + len * @sin(ang), 0.75 + t * 3, col);
    }
    for ([_]gfx.LineCap{ .butt, .round, .square }, 0..) |cap, i| {
        const y = f.y + 26 + @as(f32, @floatFromInt(i)) * 24;
        s.drawLineCap(f.x + 112, y, f.x + 152, y, 8, cap, ctx.th.text);
        s.drawLine(f.x + 112, y, f.x + 152, y, 1, Color.fromHex(0xFF375F));
    }
}

fn starPath(p: *Path, cx: f32, cy: f32, r_out: f32) !void {
    for (0..5) |i| {
        const ang = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i * 2 % 5)) * 2 * std.math.pi / 5.0;
        const x = cx + r_out * @cos(ang);
        const y = cy + r_out * @sin(ang);
        if (i == 0) try p.moveTo(x, y) else try p.lineTo(x, y);
    }
    try p.close();
}

fn cardPaths(ctx: *Ctx, r: Rect) !void {
    const s = ctx.s;
    const f = r.toF();
    var p = Path.init(ctx.a);
    defer p.deinit();
    // Pentagram: even-odd leaves the center empty, nonzero fills it.
    try starPath(&p, f.x + 36, f.y + 52, 30);
    try s.fillPath(&p, Color.fromHex(0xFFD60A), .{ .rule = .even_odd });
    try s.strokePath(&p, 1.2, Color.fromHex(0xC98A00), .{});
    p.reset();
    try starPath(&p, f.x + 96, f.y + 52, 30);
    try s.fillPath(&p, Color.fromHex(0xFF9F0A), .{ .rule = .nonzero });
    // Heart from cubic Béziers, designed on a 100-unit grid.
    p.reset();
    try p.moveTo(50, 88);
    try p.cubicTo(20, 66, 4, 48, 8, 30);
    try p.cubicTo(12, 12, 38, 6, 50, 26);
    try p.cubicTo(62, 6, 88, 12, 92, 30);
    try p.cubicTo(96, 48, 80, 66, 50, 88);
    try p.close();
    const heart = RectF.init(f.x + 130, f.y + 34, 36, 36);
    const hp = Paint.angledGradient(heart, 180, &.{
        .{ .pos = 0, .color = Color.fromHex(0xFF6482) },
        .{ .pos = 1, .color = Color.fromHex(0xD70015) },
    });
    try s.fillPath(&p, &hp, .{ .transform = Transform.fit(100, heart) });
}

fn cardChart(ctx: *Ctx, r: Rect) !void {
    const s = ctx.s;
    const f = r.toF();
    const vals = [_]f32{ 0.3, 0.45, 0.38, 0.62, 0.55, 0.78, 0.7, 0.9 };
    const x0 = f.x + 14;
    const w = f.w - 28;
    const base = f.y + f.h - 14;
    const hgt = f.h - 30;
    const pt = struct {
        fn at(i: usize, xs: f32, ws: f32, b: f32, h: f32, v: []const f32) gfx.PointF {
            return .{ .x = xs + ws * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(v.len - 1)), .y = b - h * v[i] };
        }
    }.at;
    var line = Path.init(ctx.a);
    defer line.deinit();
    var area = Path.init(ctx.a);
    defer area.deinit();
    for ([_]*Path{ &line, &area }) |path| {
        const p0 = pt(0, x0, w, base, hgt, &vals);
        try path.moveTo(p0.x, p0.y);
        for (1..vals.len) |i| {
            const a = pt(i - 1, x0, w, base, hgt, &vals);
            const b = pt(i, x0, w, base, hgt, &vals);
            const mx = (a.x + b.x) * 0.5;
            try path.cubicTo(mx, a.y, mx, b.y, b.x, b.y);
        }
    }
    try area.lineTo(x0 + w, base);
    try area.lineTo(x0, base);
    try area.close();
    const fill = Paint.verticalGradient(RectF.init(0, f.y + 10, 1, f.h - 20), &.{
        .{ .pos = 0, .color = Color.withAlpha(Color.fromHex(0x30D158), 140) },
        .{ .pos = 1, .color = Color.withAlpha(Color.fromHex(0x30D158), 0) },
    });
    for (1..4) |i| {
        const gy = base - hgt * @as(f32, @floatFromInt(i)) / 4.0;
        s.drawLine(x0, gy, x0 + w, gy, 1, ctx.th.separator);
    }
    try s.fillPath(&area, &fill, .{});
    try s.strokePath(&line, 2.2, Color.fromHex(0x30D158), .{});
    for (0..vals.len) |i| {
        const q = pt(i, x0, w, base, hgt, &vals);
        s.fillCircle(q.x, q.y, 3.2, ctx.th.card_bg);
        s.strokeCircle(q.x, q.y, 3.2, 1.6, Color.fromHex(0x30D158));
    }
}

fn cardImages(ctx: *Ctx, r: Rect) !void {
    const s = ctx.s;
    const a = ctx.a;
    // A small image drawn scaled (bilinear) and again with 50% opacity.
    var img = try Image.init(a, 48, 32);
    defer img.deinit(a);
    try gfx.wallpaper.render(img.canvas(), a, .aurora, .{ .detail = 1 });
    const cr = s.withClip(r.inset(2, 2));
    cr.blitScaled(img.canvas(), Rect.init(r.x + 12, r.y + 12, 72, 48));
    s.drawImage(img.canvas(), r.x + 96, r.y + 12, 128);
    // Blur + desaturate a colorful strip.
    const strip = Rect.init(r.x + 12, r.y + 68, 72, 20);
    const colors = [_]u32{ Color.fromHex(0xFF375F), Color.fromHex(0xFF9F0A), Color.fromHex(0xFFD60A), Color.fromHex(0x30D158), Color.fromHex(0x0A84FF), Color.fromHex(0xBF5AF2) };
    for (colors, 0..) |c, i| s.fillRect(Rect.init(strip.x + @as(i32, @intCast(i)) * 12, strip.y, 12, strip.h), c);
    s.blur(Rect.init(strip.x + 36, strip.y, 36, strip.h), 3);
    s.adjustColors(Rect.init(strip.x, strip.y, 18, strip.h), 0.1, 1.0);
    // A glyph rasterized to an alpha mask once, then blitted tinted (text-style).
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(4, 4);
    try p.lineTo(28, 4);
    try p.lineTo(28, 9);
    try p.lineTo(12, 23);
    try p.lineTo(28, 23);
    try p.lineTo(28, 28);
    try p.lineTo(4, 28);
    try p.lineTo(4, 23);
    try p.lineTo(20, 9);
    try p.lineTo(4, 9);
    try p.close();
    const mask = try gfx.fillPathMask(a, &p, 32, 32, .{ .transform = Transform.scale(0.8, 0.8).then(Transform.translate(2.5, 2.5)) });
    defer a.free(mask);
    s.blitMask(mask, 32, 32, r.x + 100, r.y + 58, ctx.th.accent);
    s.blitMask(mask, 32, 32, r.x + 128, r.y + 58, Color.fromHex(0xFF375F));
}

// ---------------------------------------------------------------------------
// Dock

const icon_size = 56;
const icon_gap = 10;
const icon_count = 9;

fn dockRect() Rect {
    const w = icon_count * icon_size + (icon_count - 1) * icon_gap + 21 + icon_size + 2 * 12;
    return Rect.init(@divTrunc(W - w, 2), H - 12 - 76, w, 76);
}

const IconFn = *const fn (ctx: *Ctx, r: RectF) anyerror!void;

fn drawDock(ctx: *Ctx, dock: Rect) !void {
    const s = ctx.s;
    const icons = [_]IconFn{ iconFiles, iconCompass, iconMessages, iconMail, iconMusic, iconPhotos, iconNotes, iconSettings, iconTerminal };
    const running = [_]bool{ true, true, false, true, true, false, false, true, true };
    var mask = try gfx.ShadowMask.init(ctx.a, 12.5, 3);
    defer mask.deinit(ctx.a);
    var x = dock.x + 12;
    const y = dock.y + 10;
    for (icons, running) |icon, run| {
        const r = Rect.init(x, y, icon_size, icon_size);
        mask.draw(s, r.offset(0, 2), Color.rgba(0, 0, 0, 60), null);
        try icon(ctx, r.toF());
        if (run) s.fillCircle(@as(f32, @floatFromInt(x)) + icon_size / 2, @floatFromInt(dock.bottom() - 5), 2, ctx.th.menu_text);
        x += icon_size + icon_gap;
    }
    // Separator and trash.
    s.fillRect(Rect.init(x, dock.y + 16, 1, dock.h - 32), Color.rgba(255, 255, 255, 90));
    x += 11;
    const tr = Rect.init(x, y, icon_size, icon_size);
    mask.draw(s, tr.offset(0, 2), Color.rgba(0, 0, 0, 40), null);
    try iconTrash(ctx, tr.toF());
}

/// Icon base: continuous-corner square with a vertical gradient and a soft rim.
fn iconBase(ctx: *Ctx, r: RectF, top: u32, bottom: u32) void {
    const g = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = top }, .{ .pos = 1, .color = bottom } });
    const shape = RoundRect.smooth(r, r.w * 0.2237);
    ctx.s.fillRRect(shape, &g);
    const rim = Paint.verticalGradient(r, &.{
        .{ .pos = 0, .color = Color.rgba(255, 255, 255, 120) },
        .{ .pos = 0.5, .color = Color.rgba(255, 255, 255, 20) },
        .{ .pos = 1, .color = Color.rgba(255, 255, 255, 60) },
    });
    var inner = shape;
    inner.rect = r.inset(0.5, 0.5);
    ctx.s.strokeRRect(inner, 1, &rim);
}

/// Maps a 100-unit design grid onto the icon.
fn grid(r: RectF) Transform {
    return Transform.fit(100, r);
}

fn u(r: RectF, x: f32, y: f32, w: f32, h: f32) RectF {
    const k = r.w / 100;
    return RectF.init(r.x + x * k, r.y + y * k, w * k, h * k);
}

fn iconFiles(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0x6AD0FF), Color.fromHex(0x1672F3));
    const s = ctx.s;
    const k = r.w / 100;
    s.fillRRect(.{ .rect = u(r, 20, 26, 30, 14), .radii = .{ .tl = 5 * k, .tr = 5 * k } }, Color.rgba(255, 255, 255, 170));
    s.fillRoundRect(u(r, 20, 32, 60, 42), 6 * k, Color.rgba(255, 255, 255, 170));
    const front = Paint.verticalGradient(u(r, 20, 40, 60, 34), &.{ .{ .pos = 0, .color = Color.white }, .{ .pos = 1, .color = Color.fromHex(0xDDEEFF) } });
    s.fillRoundRect(u(r, 20, 40, 60, 34), 6 * k, &front);
}

fn iconCompass(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0xFFFFFF), Color.fromHex(0xD9DEE6));
    const s = ctx.s;
    const c = r.center();
    const k = r.w / 100;
    const dial = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = Color.fromHex(0x28C6FF) }, .{ .pos = 1, .color = Color.fromHex(0x1450F0) } });
    s.fillCircle(c.x, c.y, 38 * k, &dial);
    for (0..24) |i| {
        const ang = @as(f32, @floatFromInt(i)) * std.math.pi / 12.0;
        const r0: f32 = if (i % 6 == 0) 29 else 33;
        s.drawLine(c.x + r0 * k * @cos(ang), c.y + r0 * k * @sin(ang), c.x + 36 * k * @cos(ang), c.y + 36 * k * @sin(ang), 0.8, Color.rgba(255, 255, 255, 200));
    }
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.addPolygon(&.{ .{ .x = 0, .y = -30 }, .{ .x = 6, .y = 0 }, .{ .x = -6, .y = 0 } });
    const t = Transform.rotate(std.math.pi / 4.0).then(Transform.scale(k, k)).then(Transform.translate(c.x, c.y));
    try s.fillPath(&p, Color.fromHex(0xFF3B30), .{ .transform = t });
    p.reset();
    try p.addPolygon(&.{ .{ .x = 0, .y = 30 }, .{ .x = -6, .y = 0 }, .{ .x = 6, .y = 0 } });
    try s.fillPath(&p, Color.white, .{ .transform = t });
}

fn iconMessages(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0x6BF77F), Color.fromHex(0x0DBE31));
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.addEllipse(50, 47, 32, 25);
    try p.moveTo(26, 60);
    try p.quadTo(26, 74, 16, 80);
    try p.quadTo(34, 80, 42, 68);
    try p.close();
    try ctx.s.fillPath(&p, Color.white, .{ .transform = grid(r) });
}

fn iconMail(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0x4FC3FF), Color.fromHex(0x1569F0));
    const s = ctx.s;
    const k = r.w / 100;
    s.fillRoundRect(u(r, 18, 28, 64, 44), 6 * k, Color.white);
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.moveTo(20, 31);
    try p.lineTo(50, 54);
    try p.lineTo(80, 31);
    try s.strokePath(&p, 3.5, Color.fromHex(0x3A8DF8), .{ .transform = grid(r) });
}

fn iconMusic(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0xFF6680), Color.fromHex(0xF5213D));
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.addEllipse(34, 70, 10, 8);
    try p.addEllipse(66, 64, 10, 8);
    try p.addRect(.{ .x = 40.5, .y = 26, .w = 4.5, .h = 44 });
    try p.addRect(.{ .x = 72.5, .y = 20, .w = 4.5, .h = 44 });
    try p.moveTo(40.5, 26);
    try p.lineTo(77, 18);
    try p.lineTo(77, 28);
    try p.lineTo(40.5, 36);
    try p.close();
    try ctx.s.fillPath(&p, Color.white, .{ .transform = grid(r) });
}

fn iconPhotos(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0xFFFFFF), Color.fromHex(0xEEF0F4));
    const petals = [_]u32{ 0xFF9F0A, 0xFFD60A, 0x8BD650, 0x30C7BE, 0x0A84FF, 0x7D5CF6, 0xE0409F, 0xFF453A };
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.addEllipse(0, -17, 10, 17);
    const c = r.center();
    const k = r.w / 100;
    for (petals, 0..) |col, i| {
        const t = Transform.rotate(@as(f32, @floatFromInt(i)) * std.math.pi / 4.0).then(Transform.scale(k, k)).then(Transform.translate(c.x, c.y));
        try ctx.s.fillPath(&p, Color.withAlpha(Color.fromHex(@intCast(col)), 200), .{ .transform = t });
    }
}

fn iconNotes(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0xFFFFFF), Color.fromHex(0xF2F2F2));
    const s = ctx.s;
    const k = r.w / 100;
    const band = Paint.verticalGradient(u(r, 0, 0, 100, 26), &.{ .{ .pos = 0, .color = Color.fromHex(0xFFE066) }, .{ .pos = 1, .color = Color.fromHex(0xFFC300) } });
    s.fillRRect(.{ .rect = u(r, 0, 0, 100, 26), .radii = .{ .tl = 22.37 * k, .tr = 22.37 * k }, .continuous = true }, &band);
    for (0..4) |i| {
        const y = r.y + (40 + @as(f32, @floatFromInt(i)) * 13) * k;
        s.drawLine(r.x + 14 * k, y, r.x + 86 * k, y, 1, Color.fromHex(0xD0D0D0));
    }
}

fn iconSettings(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0xB8BDC6), Color.fromHex(0x6B7079));
    var p = Path.init(ctx.a);
    defer p.deinit();
    const teeth = 12;
    for (0..teeth * 4) |i| {
        const ang = @as(f32, @floatFromInt(i)) * 2 * std.math.pi / (teeth * 4);
        const rad: f32 = if ((i + 1) % 4 < 2) 36 else 29;
        const x = 50 + rad * @cos(ang);
        const y = 50 + rad * @sin(ang);
        if (i == 0) try p.moveTo(x, y) else try p.lineTo(x, y);
    }
    try p.close();
    try p.addCircle(50, 50, 15);
    const g = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = Color.fromHex(0xF4F5F7) }, .{ .pos = 1, .color = Color.fromHex(0xC9CDD4) } });
    try ctx.s.fillPath(&p, &g, .{ .transform = grid(r), .rule = .even_odd });
    const k = r.w / 100;
    const c = r.center();
    ctx.s.strokeCircle(c.x, c.y, 22 * k, 1.2, Color.rgba(255, 255, 255, 180));
}

fn iconTerminal(ctx: *Ctx, r: RectF) !void {
    iconBase(ctx, r, Color.fromHex(0x3A3F47), Color.fromHex(0x121417));
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.moveTo(24, 34);
    try p.lineTo(40, 48);
    try p.lineTo(24, 62);
    try ctx.s.strokePath(&p, 6, Color.fromHex(0x4CE37E), .{ .transform = grid(r) });
    const k = r.w / 100;
    ctx.s.drawLineCap(r.x + 48 * k, r.y + 64 * k, r.x + 72 * k, r.y + 64 * k, 6 * k, .butt, Color.fromHex(0x4CE37E));
}

fn iconTrash(ctx: *Ctx, r: RectF) !void {
    const s = ctx.s;
    const shape = RoundRect.smooth(r, r.w * 0.2237);
    s.fillRRect(shape, Color.rgba(255, 255, 255, 60));
    s.strokeRRect(shape, 1, Color.rgba(255, 255, 255, 140));
    const k = r.w / 100;
    const col = Color.rgba(255, 255, 255, 230);
    s.fillRoundRect(u(r, 26, 26, 48, 6), 3 * k, col);
    s.fillRoundRect(u(r, 42, 20, 16, 8), 3 * k, col);
    var p = Path.init(ctx.a);
    defer p.deinit();
    try p.moveTo(30, 36);
    try p.lineTo(34, 80);
    try p.lineTo(66, 80);
    try p.lineTo(70, 36);
    try s.strokePath(&p, 4, col, .{ .transform = grid(r) });
    for ([_]f32{ 42, 50, 58 }) |x| s.drawLine(r.x + x * k, r.y + 44 * k, r.x + x * k, r.y + 72 * k, 2.2, col);
}
