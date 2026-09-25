//! Icons rendered once per (kind, size, appearance) into small images.
//! Drawing vector icons every frame is far too slow on an emulated CPU, so
//! Finder only ever blits these cached bitmaps.

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const ui = @import("ui");
const icons = @import("icons");
const fs = @import("fs.zig");

const Color = gfx.Color;
const Paint = gfx.Paint;
const Path = gfx.Path;
const RectF = gfx.RectF;
const Transform = gfx.Transform;

fn rgb(hex: u24) u32 {
    return Color.fromHex(hex);
}

fn rgba(hex: u24, a: u8) u32 {
    return Color.withAlpha(Color.fromHex(hex), a);
}

/// Tahoe-style folder blue.
pub const folder_tint: u32 = 0xFF55B0F4;
pub const system_tint: u32 = 0xFF8F9BB0;

pub const IconCache = struct {
    allocator: std.mem.Allocator,
    fonts: *ui.FontSet,
    map: std.AutoHashMapUnmanaged(u64, gfx.Image) = .empty,
    path: Path,

    pub fn init(allocator: std.mem.Allocator, fonts: *ui.FontSet) IconCache {
        return .{ .allocator = allocator, .fonts = fonts, .path = Path.init(allocator) };
    }

    pub fn deinit(self: *IconCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |img| img.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.path.deinit();
    }

    fn key(parts: anytype) u64 {
        var h = std.hash.Wyhash.init(0x1C0);
        inline for (parts) |p| {
            const T = @TypeOf(p);
            if (T == []const u8) {
                h.update(p);
                h.update(&[_]u8{0xFF});
            } else {
                h.update(std.mem.asBytes(&p));
            }
        }
        return h.final();
    }

    /// Icon of a file entry at `size` px (square).
    pub fn entry(self: *IconCache, e: *const fs.Entry, size: u32) ?gfx.Canvas {
        var ext_buf: [8]u8 = undefined;
        const ext = if (e.icon.cat == .document) upperExt(&ext_buf, fs.extension(e.name)) else "";
        return self.get(e.icon, size, ext, e.is_link);
    }

    pub fn get(self: *IconCache, id: fs.IconId, size: u32, ext: []const u8, link: bool) ?gfx.Canvas {
        const k = key(.{ @as(u32, @bitCast(id)), size, ext, link });
        if (self.map.get(k)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, size, size) catch return null;
        const c = img.canvas();
        c.clear(0);
        const r = RectF.init(0, 0, @floatFromInt(size), @floatFromInt(size));
        self.draw(c, id, r, ext);
        if (link) drawAliasBadge(c, r);
        self.map.put(self.allocator, k, img) catch {
            img.deinit(self.allocator);
            return null;
        };
        return self.map.get(k).?.canvas();
    }

    /// A monochrome symbol tinted `color` (premultiplied).
    pub fn symbol(self: *IconCache, sym: icons.Symbol, size: u32, color: u32) ?gfx.Canvas {
        const k = key(.{ @as(u32, 0x5E), @intFromEnum(sym), size, color });
        if (self.map.get(k)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, size, size) catch return null;
        img.canvas().clear(0);
        icons.drawSymbol(img.canvas(), self.allocator, sym, RectF.init(0, 0, @floatFromInt(size), @floatFromInt(size)), color);
        self.map.put(self.allocator, k, img) catch {
            img.deinit(self.allocator);
            return null;
        };
        return self.map.get(k).?.canvas();
    }

    fn draw(self: *IconCache, c: gfx.Canvas, id: fs.IconId, r: RectF, ext: []const u8) void {
        switch (id.cat) {
            .folder => self.drawFolder(c, r, folder_tint, @enumFromInt(id.variant)),
            .sys_folder => self.drawFolder(c, r, system_tint, .none),
            .app => {
                const inset = r.w * 0.06;
                const icon: icons.AppIcon = if (id.variant < std.meta.fields(icons.AppIcon).len) @enumFromInt(id.variant) else .generic;
                if (r.w >= 32) {
                    // Soft contact shadow under the tile.
                    const sr = r.inset(inset, inset).offset(0, r.w * 0.025);
                    c.fillRoundRect(sr, sr.w * 0.2237, rgba(0x000000, 40));
                }
                icons.drawApp(c, self.allocator, icon, r.inset(inset, inset));
            },
            .exec => self.drawExec(c, r),
            .document => self.drawDocument(c, r, @enumFromInt(id.variant), ext),
            .sys_file => self.drawDocument(c, r, .config, ""),
        }
    }

    fn drawFolder(self: *IconCache, c: gfx.Canvas, r: RectF, tint: u32, mark: fs.FolderMark) void {
        const k = r.w / 100;
        if (r.w >= 32) {
            // Faint drop shadow.
            c.fillRoundRect(RectF.init(r.x + 7 * k, r.y + 24 * k, 86 * k, 64 * k), 8 * k, rgba(0x000000, 28));
        }
        icons.drawFolder(c, r, tint);
        const sym: ?icons.Symbol = switch (mark) {
            .none => null,
            .home => .house,
            .desktop => .desktop,
            .documents => .document,
            .downloads => .download,
            .applications => .apps,
            .pictures => .photo,
            .music => .music,
            .movies => .film,
            .library => .list,
            .system => .gear,
            .trash => .trash,
        };
        if (sym) |s| {
            if (r.w < 24) return;
            const ss = 30 * k;
            const sr = RectF.init(r.x + 50 * k - ss / 2, r.y + 44 * k, ss, ss);
            // Embossed: darker symbol with a light edge below.
            icons.drawSymbol(c, self.allocator, s, sr.offset(0, @max(0.5, k)), rgba(0xFFFFFF, 90));
            icons.drawSymbol(c, self.allocator, s, sr, Color.withAlpha(Color.lerp(tint, rgb(0x0B3D78), 0.55), 170));
        }
    }

    fn drawExec(self: *IconCache, c: gfx.Canvas, r: RectF) void {
        const k = r.w / 100;
        const tile = RectF.init(r.x + 12 * k, r.y + 12 * k, 76 * k, 76 * k);
        const g = Paint.verticalGradient(tile, &.{ .{ .pos = 0, .color = rgb(0x3A3A40) }, .{ .pos = 1, .color = rgb(0x111114) } });
        c.fillRoundRect(tile, 12 * k, &g);
        c.strokeRoundRect(tile.inset(0.5, 0.5), 12 * k, 1, rgba(0xFFFFFF, 40));
        if (r.w >= 32) {
            const f = self.fonts.face(.mono_bold, @max(6, 17 * k));
            const t = font.Target.init(c.pixels[0..@intCast(c.stride * c.height)], @intCast(c.width), @intCast(c.height), @intCast(c.stride));
            _ = font.drawText(t, f, "exec", r.x + 22 * k, @round(r.y + 78 * k), rgb(0x3CE06A));
        } else {
            c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 24 * k), @intFromFloat(r.y + 66 * k), @intFromFloat(30 * k), @intFromFloat(@max(1, 5 * k))), rgb(0x3CE06A));
        }
    }

    fn drawDocument(self: *IconCache, c: gfx.Canvas, r: RectF, style: fs.DocStyle, ext: []const u8) void {
        const k = r.w / 100;
        const g = Transform.fit(100, r);
        var p = &self.path;
        // Page with a folded corner.
        p.reset();
        const page = [_][2]f32{ .{ 19, 5 }, .{ 63, 5 }, .{ 83, 25 }, .{ 83, 95 }, .{ 19, 95 } };
        if (r.w >= 32) {
            // Soft shadow.
            p.moveTo(page[0][0], page[0][1] + 1.2) catch return;
            for (page[1..]) |pt| p.lineTo(pt[0], pt[1] + 1.2) catch return;
            p.close() catch return;
            c.fillPath(p, rgba(0x000000, 30), .{ .transform = g }) catch {};
            p.reset();
        }
        p.moveTo(page[0][0], page[0][1]) catch return;
        for (page[1..]) |pt| p.lineTo(pt[0], pt[1]) catch return;
        p.close() catch return;
        const pg = Paint.verticalGradient(r, &.{ .{ .pos = 0, .color = rgb(0xFFFFFF) }, .{ .pos = 1, .color = rgb(0xF4F5F8) } });
        c.fillPath(p, &pg, .{ .transform = g }) catch {};
        c.strokePath(p, @max(0.8, 1.0 / k), rgba(0x000000, 55), .{ .transform = g }) catch {};
        p.reset();
        p.moveTo(63, 5) catch return;
        p.lineTo(63, 25) catch return;
        p.lineTo(83, 25) catch return;
        p.close() catch return;
        c.fillPath(p, rgb(0xDCDFE6), .{ .transform = g }) catch {};
        c.strokePath(p, @max(0.8, 1.0 / k), rgba(0x000000, 40), .{ .transform = g }) catch {};

        // Small sizes: a few crisp, pixel-aligned text lines.
        if (r.w < 32 and style != .image and style != .audio and style != .video and style != .archive) {
            const col: u32 = switch (style) {
                .code => rgba(0x2F6FD6, 190),
                .pdf => rgba(0xD0342C, 190),
                .data => rgba(0x2E8B57, 190),
                else => rgba(0x3C3C46, 140),
            };
            const x: i32 = @intFromFloat(@round(r.x + r.w * 0.31));
            const wmax = r.w * 0.40;
            var yy: f32 = @round(r.y + r.h * 0.38);
            var i: usize = 0;
            while (yy < r.y + r.h * 0.86) : (yy += 3) {
                const ww = if (i % 3 == 2) wmax * 0.6 else wmax;
                c.fillRect(gfx.Rect.init(x, @intFromFloat(yy), @intFromFloat(@round(ww)), 1), col);
                i += 1;
            }
            return;
        }
        const line_h = @max(1.0, 2.2 * k);
        const has_label = ext.len > 0 and r.w >= 40;
        const bottom: f32 = if (has_label) 66 else 86;
        switch (style) {
            .image => {
                const pic = RectF.init(r.x + 27 * k, r.y + 32 * k, 48 * k, 34 * k);
                const sky = Paint.verticalGradient(pic, &.{ .{ .pos = 0, .color = rgb(0x5DB8FF) }, .{ .pos = 1, .color = rgb(0xBFE3FF) } });
                c.fillRoundRect(pic, 3 * k, &sky);
                p.reset();
                p.moveTo(27, 66) catch return;
                p.lineTo(40, 48) catch return;
                p.lineTo(50, 58) catch return;
                p.lineTo(60, 45) catch return;
                p.lineTo(75, 66) catch return;
                p.close() catch return;
                c.fillPath(p, rgb(0x3E9B57), .{ .transform = g }) catch {};
                c.fillCircle(r.x + 64 * k, r.y + 40 * k, 4.5 * k, rgb(0xFFD84A));
            },
            .code => {
                const rows = [_]struct { f32, f32, u32 }{
                    .{ 0, 30, rgb(0xAF52DE) },  .{ 6, 26, rgb(0x007AFF) }, .{ 6, 20, rgb(0x8E8E93) },
                    .{ 12, 22, rgb(0x34C759) }, .{ 6, 16, rgb(0xFF9500) }, .{ 0, 10, rgb(0xAF52DE) },
                };
                var y: f32 = 34;
                for (rows) |row| {
                    if (y > bottom) break;
                    fillBar(c, r.x + (28 + row[0]) * k, r.y + y * k, row[1] * k, line_h, Color.withAlpha(row[2], 200));
                    y += 6.5;
                }
            },
            .pdf => {
                var y: f32 = 34;
                while (y <= bottom) : (y += 6.5) fillBar(c, r.x + 28 * k, r.y + y * k, (if (@mod(y, 13) < 1) @as(f32, 36) else 44) * k, line_h, rgba(0x505058, 110));
                c.fillRoundRect(RectF.init(r.x + 28 * k, r.y + 34 * k, 18 * k, 14 * k), 2 * k, rgba(0xE0443A, 220));
            },
            .archive => {
                var y: f32 = 8;
                while (y < 60) : (y += 6) {
                    fillBar(c, r.x + 47 * k, r.y + y * k, 4 * k, 3 * k, rgb(0x8E8E93));
                    fillBar(c, r.x + 51 * k, r.y + (y + 3) * k, 4 * k, 3 * k, rgb(0xB0B0B6));
                }
                c.fillRoundRect(RectF.init(r.x + 45 * k, r.y + 60 * k, 12 * k, 8 * k), 2 * k, rgb(0x8E8E93));
            },
            .audio, .video => {
                const s: icons.Symbol = if (style == .audio) .music else .film;
                const sr = RectF.init(r.x + 33 * k, r.y + 30 * k, 36 * k, 36 * k);
                icons.drawSymbol(c, self.allocator, s, sr, if (style == .audio) rgb(0xFF2D55) else rgb(0x5856D6));
            },
            else => {
                const widths = [_]f32{ 46, 40, 46, 30, 44, 38, 46, 24 };
                var y: f32 = 32;
                var i: usize = 0;
                const col: u32 = switch (style) {
                    .markdown => rgba(0x3A3A48, 120),
                    .data => rgba(0x2E8B57, 130),
                    .config => rgba(0x6E6E78, 120),
                    else => rgba(0x3C3C46, 105),
                };
                while (y <= bottom) : (y += 6.5) {
                    var w = widths[i % widths.len];
                    if (style == .markdown and i == 0) {
                        fillBar(c, r.x + 28 * k, r.y + y * k, 26 * k, line_h * 1.5, rgba(0x1C1C24, 170));
                        i += 1;
                        continue;
                    }
                    if (style == .data) w = 44;
                    fillBar(c, r.x + 28 * k, r.y + y * k, w * k, line_h, col);
                    if (style == .data) {
                        c.fillRect(gfx.Rect.init(@intFromFloat(r.x + 43 * k), @intFromFloat(r.y + 30 * k), @intFromFloat(@max(1, 0.8 * k)), @intFromFloat((bottom - 26) * k)), rgba(0xFFFFFF, 255));
                    }
                    i += 1;
                }
            },
        }
        if (has_label) {
            const size = @max(7, 13.5 * k);
            const f = self.fonts.face(.bold, size);
            const tw = f.measure(ext);
            const t = font.Target.init(c.pixels[0..@intCast(c.stride * c.height)], @intCast(c.width), @intCast(c.height), @intCast(c.stride));
            const col: u32 = switch (style) {
                .code => rgb(0x2F6FD6),
                .image => rgb(0x1F8F6A),
                .pdf => rgb(0xD0342C),
                .markdown => rgb(0x4A4A58),
                .audio => rgb(0xE0244A),
                .video => rgb(0x5856D6),
                else => rgb(0x6E6E78),
            };
            _ = font.drawText(t, f, ext, @round(r.x + 51 * k - tw / 2), @round(r.y + 86 * k), col);
        }
    }
};

fn fillBar(c: gfx.Canvas, x: f32, y: f32, w: f32, h: f32, color: u32) void {
    c.fillRoundRect(RectF.init(x, y, w, h), h / 2, color);
}

/// Small curved arrow in the lower-left corner (aliases / symlinks).
fn drawAliasBadge(c: gfx.Canvas, r: RectF) void {
    const s = @max(7, r.w * 0.3);
    const b = RectF.init(r.x + r.w * 0.08, r.y + r.h - s - r.h * 0.04, s, s);
    c.fillRoundRect(b, s * 0.22, rgb(0xFFFFFF));
    c.strokeRoundRect(b, s * 0.22, @max(0.6, s / 18), rgba(0x000000, 90));
    const cx = b.x;
    const cy = b.y;
    c.drawLine(cx + s * 0.3, cy + s * 0.72, cx + s * 0.7, cy + s * 0.3, @max(1, s / 9), rgb(0x1C1C1E));
    c.drawLine(cx + s * 0.45, cy + s * 0.3, cx + s * 0.7, cy + s * 0.3, @max(1, s / 9), rgb(0x1C1C1E));
    c.drawLine(cx + s * 0.7, cy + s * 0.3, cx + s * 0.7, cy + s * 0.55, @max(1, s / 9), rgb(0x1C1C1E));
}

fn upperExt(buf: *[8]u8, ext: []const u8) []const u8 {
    if (ext.len == 0 or ext.len > 5) return "";
    for (ext, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return buf[0..ext.len];
}
