//! Micro-benchmarks for the graphics library.
//!
//! Host:          zig run -OReleaseFast lib/gfx/bench.zig
//! RISC-V (QEMU): zig build-exe -target riscv64-linux-none -OReleaseFast lib/gfx/bench.zig && qemu-riscv64 ./bench

const std = @import("std");
const gfx = @import("root.zig");

const Color = gfx.Color;
const Rect = gfx.Rect;

const W = 1280;
const H = 800;

var out_buf: [4096]u8 = undefined;

fn report(w: *std.Io.Writer, name: []const u8, iters: u32, ns: u64) !void {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)) / 1e6;
    try w.print("{s:<40} {d:>9.3} ms\n", .{ name, per });
    try w.flush();
}

fn run(w: *std.Io.Writer, name: []const u8, iters: u32, ctx: anytype, comptime f: anytype) !void {
    var t = try std.time.Timer.start();
    for (0..iters) |_| try f(ctx);
    try report(w, name, iters, t.read());
}

const Env = struct {
    a: std.mem.Allocator,
    c: gfx.Canvas,
    bd: gfx.Canvas,
};

pub fn main() !void {
    const a = std.heap.page_allocator;
    var fw = std.fs.File.stdout().writer(&out_buf);
    const w = &fw.interface;

    var screen = try gfx.Image.init(a, W, H);
    var backdrop = try gfx.Image.init(a, W, H);
    const env = Env{ .a = a, .c = screen.canvas(), .bd = backdrop.canvas() };
    try gfx.wallpaper.render(env.bd, a, .tahoe_day, .{});
    env.c.blitOpaque(env.bd, 0, 0);

    try run(w, "clear 1280x800", 20, env, struct {
        fn f(e: Env) !void {
            e.c.clear(Color.black);
        }
    }.f);
    try run(w, "fillRect 800x600 translucent", 10, env, struct {
        fn f(e: Env) !void {
            e.c.fillRect(Rect.init(100, 100, 800, 600), Color.rgba(30, 60, 90, 128));
        }
    }.f);
    try run(w, "fillRoundRect 800x600 r20 opaque", 10, env, struct {
        fn f(e: Env) !void {
            e.c.fillRoundRect(Rect.init(100, 100, 800, 600), 20, Color.rgb(240, 240, 245));
        }
    }.f);
    try run(w, "fillRRect continuous 800x600 r20", 10, env, struct {
        fn f(e: Env) !void {
            e.c.fillRRect(gfx.RoundRect.smooth(Rect.init(100, 100, 800, 600), 20), Color.rgb(240, 240, 245));
        }
    }.f);
    try run(w, "strokeRoundRect 800x600 w2", 10, env, struct {
        fn f(e: Env) !void {
            e.c.strokeRoundRect(Rect.init(100, 100, 800, 600), 20, 2, Color.black);
        }
    }.f);
    try run(w, "fillCircle r100", 20, env, struct {
        fn f(e: Env) !void {
            e.c.fillCircle(400, 400, 100, Color.rgba(200, 30, 30, 200));
        }
    }.f);
    try run(w, "drawLine x100 (len 300, w2)", 5, env, struct {
        fn f(e: Env) !void {
            for (0..100) |i| {
                const t = @as(f32, @floatFromInt(i)) * 0.0628;
                e.c.drawLine(640, 400, 640 + 300 * @cos(t), 400 + 300 * @sin(t), 2, Color.white);
            }
        }
    }.f);
    try run(w, "linear gradient rect 800x600", 10, env, struct {
        fn f(e: Env) !void {
            const p = gfx.Paint.angledGradient(gfx.RectF.init(100, 100, 800, 600), 135, &.{
                .{ .pos = 0, .color = Color.fromHex(0xFF2D55) },
                .{ .pos = 1, .color = Color.fromHex(0x0A84FF) },
            });
            e.c.fillRect(Rect.init(100, 100, 800, 600), &p);
        }
    }.f);
    try run(w, "fillPath ellipse 600x400", 10, env, struct {
        fn f(e: Env) !void {
            var p = gfx.Path.init(e.a);
            defer p.deinit();
            try p.addEllipse(640, 400, 300, 200);
            try e.c.fillPath(&p, Color.rgba(0, 200, 100, 180), .{});
        }
    }.f);
    try run(w, "fillPath icon 56px x10", 10, env, struct {
        fn f(e: Env) !void {
            var p = gfx.Path.init(e.a);
            defer p.deinit();
            try p.addCircle(50, 50, 40);
            try p.addCircle(50, 50, 20);
            for (0..10) |i| {
                const r = gfx.RectF.init(@floatFromInt(20 + i * 60), 20, 56, 56);
                try e.c.fillPath(&p, Color.white, .{ .rule = .even_odd, .transform = gfx.Transform.fit(100, r) });
            }
        }
    }.f);
    try run(w, "blur 400x300 r10", 5, env, struct {
        fn f(e: Env) !void {
            e.c.blur(Rect.init(100, 100, 400, 300), 10);
        }
    }.f);
    try run(w, "blurFast 1280x800 r30", 3, env, struct {
        fn f(e: Env) !void {
            try e.c.blurFast(e.a, e.c.bounds(), 30);
        }
    }.f);
    try run(w, "drawShadow 800x600 blur26", 5, env, struct {
        fn f(e: Env) !void {
            try e.c.drawShadow(e.a, Rect.init(200, 100, 800, 600), 20, .{ .blur = 26, .offset_y = 20 });
        }
    }.f);
    try run(w, "drawGlass sidebar 220x500", 5, env, struct {
        fn f(e: Env) !void {
            e.c.drawGlass(Rect.init(100, 100, 220, 500), 14, e.bd, gfx.GlassStyle.light);
        }
    }.f);
    try run(w, "drawGlass window 800x600", 3, env, struct {
        fn f(e: Env) !void {
            e.c.drawGlass(Rect.init(100, 100, 800, 600), 20, e.bd, gfx.GlassStyle.light);
        }
    }.f);
    try run(w, "drawGlass menu bar 1280x30", 5, env, struct {
        fn f(e: Env) !void {
            e.c.drawGlass(Rect.init(0, 0, 1280, 30), 0, e.bd, gfx.GlassStyle.clear);
        }
    }.f);
    try run(w, "blitScaled 640x400 -> 1280x800", 3, env, struct {
        fn f(e: Env) !void {
            e.c.blitScaled(e.bd.sub(Rect.init(0, 0, 640, 400)), e.c.bounds());
        }
    }.f);
    try run(w, "wallpaper 1280x800", 2, env, struct {
        fn f(e: Env) !void {
            try gfx.wallpaper.render(e.c, e.a, .golden_gate, .{});
        }
    }.f);
    try run(w, "wallpaper 1280x800 detail=3", 2, env, struct {
        fn f(e: Env) !void {
            try gfx.wallpaper.render(e.c, e.a, .golden_gate, .{ .detail = 3 });
        }
    }.f);
    try run(w, "wallpaper 1280x800 detail=4", 2, env, struct {
        fn f(e: Env) !void {
            try gfx.wallpaper.render(e.c, e.a, .golden_gate, .{ .detail = 4 });
        }
    }.f);
    try run(w, "png encode 1280x800", 2, env, struct {
        fn f(e: Env) !void {
            var discard_buf: [4096]u8 = undefined;
            var d = std.Io.Writer.Discarding.init(&discard_buf);
            try gfx.png.encode(&d.writer, e.c);
        }
    }.f);
}
