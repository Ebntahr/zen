//! Host preview: render every icon to a PNG sheet.
const std = @import("std");
const gfx = @import("gfx");
const icons = @import("icons");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    const out = if (args.len > 1) args[1] else "/tmp/icons.png";
    var img = try gfx.Image.init(a, 1100, 520);
    defer img.deinit(a);
    const c = img.canvas();
    c.clear(gfx.Color.fromHex(0xECEEF3));
    const apps = std.meta.fields(icons.AppIcon);
    inline for (apps, 0..) |f, i| {
        const x: f32 = 20 + @as(f32, @floatFromInt(i % 8)) * 130;
        const y: f32 = 20 + @as(f32, @floatFromInt(i / 8)) * 130;
        icons.drawApp(c, a, @enumFromInt(f.value), gfx.RectF.init(x, y, 110, 110));
    }
    icons.drawFolder(c, gfx.RectF.init(800, 150, 110, 110), gfx.Color.fromHex(0x5AB0FF));
    icons.drawDocument(c, a, gfx.RectF.init(930, 150, 110, 110), gfx.Color.fromHex(0x0A84FF));
    const syms = std.meta.fields(icons.Symbol);
    inline for (syms, 0..) |f, i| {
        const x: f32 = 20 + @as(f32, @floatFromInt(i % 22)) * 48;
        const y: f32 = 300 + @as(f32, @floatFromInt(i / 22)) * 48;
        icons.drawSymbol(c, a, @enumFromInt(f.value), gfx.RectF.init(x, y, 28, 28), gfx.Color.fromHex(0x1C1C1E));
        icons.drawSymbol(c, a, @enumFromInt(f.value), gfx.RectF.init(x + 4, y + 110, 18, 18), gfx.Color.fromHex(0x0A84FF));
    }
    try gfx.png.writeFile(c, out);
}
