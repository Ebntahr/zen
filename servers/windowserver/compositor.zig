//! Compositor: draws the desktop into the framebuffer for a damaged region.
//!
//! Order: wallpaper → windows (bottom to top, with shadows, title bars and
//! rounded corners) → system chrome (menu bar, Dock, menus, switcher,
//! notifications, drawn by chrome.zig) → shield windows (login/lock).

const std = @import("std");
const gfx = @import("gfx");
const abi = @import("abi");
const ui = @import("ui");
const icons = @import("icons");
const font = @import("font");
const wm = @import("wm.zig");
const st = @import("state.zig");
const chrome = @import("chrome.zig");

const Canvas = gfx.Canvas;
const Color = gfx.Color;
const Rect = gfx.Rect;
const RectF = gfx.RectF;
const proto = abi.window;
const pm = ui.pm;

pub fn toG(r: wm.Rect) Rect {
    return Rect.init(r.x, r.y, r.w, r.h);
}

pub fn fromG(r: Rect) wm.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    fb: Canvas,
    width: i32,
    height: i32,
    wallpaper: gfx.Image,
    wallpaper_blur: gfx.Image,
    /// Screen-sized scratch buffer holding blurred backdrops for glass.
    backdrop: gfx.Image,
    shadow_focused: gfx.ShadowMask,
    shadow_normal: gfx.ShadowMask,
    shadow_popup: gfx.ShadowMask,
    fonts: *ui.FontSet,
    icon_cache: std.StringHashMapUnmanaged(gfx.Image) = .empty,
    /// The region of the compose in progress (glass is clipped to it).
    composing: Rect = Rect.init(0, 0, 0, 0),
    wallpaper_variant: u8 = 255,
    wallpaper_dark: bool = false,
    /// The wallpaper behind the menu bar is dark: use light menu bar text
    /// even in light mode (as macOS does).
    menubar_on_dark: bool = false,

    pub fn init(allocator: std.mem.Allocator, fb_pixels: []u32, w: i32, h: i32, fonts: *ui.FontSet) !Compositor {
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        return .{
            .allocator = allocator,
            .fb = Canvas.init(fb_pixels, uw, uh, uw),
            .width = w,
            .height = h,
            .wallpaper = try gfx.Image.init(allocator, uw, uh),
            .wallpaper_blur = try gfx.Image.init(allocator, uw, uh),
            .backdrop = try gfx.Image.init(allocator, uw, uh),
            .shadow_focused = try gfx.ShadowMask.init(allocator, wm.RADIUS, 22),
            .shadow_normal = try gfx.ShadowMask.init(allocator, wm.RADIUS, 14),
            .shadow_popup = try gfx.ShadowMask.init(allocator, 10, 12),
            .fonts = fonts,
        };
    }

    /// (Re)render the wallpaper and its blurred copy.
    pub fn setWallpaper(self: *Compositor, variant: u8, dark: bool) void {
        if (variant == self.wallpaper_variant and dark == self.wallpaper_dark) return;
        self.wallpaper_variant = variant;
        self.wallpaper_dark = dark;
        const v: gfx.wallpaper.Variant = switch (variant) {
            0 => if (dark) .tahoe_night else .tahoe_day,
            1 => .tahoe_night,
            3 => .aurora,
            else => .golden_gate,
        };
        var path_buf: [128]u8 = undefined;
        const cache = std.fmt.bufPrint(&path_buf, "/var/cache/zen/wallpaper-{s}-{d}x{d}.raw", .{ @tagName(v), self.width, self.height }) catch "";
        defer self.updateMenubarTone();
        if (loadCache(cache, self.wallpaper.pixels, self.wallpaper_blur.pixels)) return;
        const wc = self.wallpaper.canvas();
        gfx.wallpaper.render(wc, self.allocator, v, .{ .detail = 2 }) catch wc.clear(Color.fromHex(0x2C3E66));
        const bc = self.wallpaper_blur.canvas();
        bc.blitOpaque(wc, 0, 0);
        gfx.effects.blurFast(bc, self.allocator, bc.bounds(), 28) catch {};
        saveCache(cache, self.wallpaper.pixels, self.wallpaper_blur.pixels);
    }

    /// Average luminance of the blurred wallpaper under the menu bar.
    fn updateMenubarTone(self: *Compositor) void {
        const w: usize = @intCast(self.width);
        const rows: usize = @intCast(@min(self.height, wm.MENUBAR));
        var sum: u64 = 0;
        var n: u64 = 0;
        var y: usize = 0;
        while (y < rows) : (y += 4) {
            var x: usize = 0;
            while (x < w) : (x += 8) {
                const p = self.wallpaper_blur.pixels[y * w + x];
                const r = (p >> 16) & 0xFF;
                const g = (p >> 8) & 0xFF;
                const b = p & 0xFF;
                sum += (r * 54 + g * 183 + b * 19) >> 8;
                n += 1;
            }
        }
        self.menubar_on_dark = n > 0 and sum / n < 118;
    }

    /// Cached wallpaper: the sharp image followed by the blurred one.
    fn loadCache(path: []const u8, sharp: []u32, blurred: []u32) bool {
        if (path.len == 0) return false;
        const f = std.fs.cwd().openFile(path, .{}) catch return false;
        defer f.close();
        const a = std.mem.sliceAsBytes(sharp);
        const b = std.mem.sliceAsBytes(blurred);
        const n1 = f.readAll(a) catch return false;
        const n2 = f.readAll(b) catch return false;
        return n1 == a.len and n2 == b.len;
    }

    fn saveCache(path: []const u8, sharp: []const u32, blurred: []const u32) void {
        if (path.len == 0) return;
        std.fs.cwd().makePath("/var/cache/zen") catch return;
        const f = std.fs.cwd().createFile(path, .{}) catch return;
        defer f.close();
        f.writeAll(std.mem.sliceAsBytes(sharp)) catch return;
        f.writeAll(std.mem.sliceAsBytes(blurred)) catch return;
    }

    fn shadowFor(self: *Compositor, win: *const wm.Window, focused: bool) *const gfx.ShadowMask {
        if (win.layer == .popup) return &self.shadow_popup;
        return if (focused) &self.shadow_focused else &self.shadow_normal;
    }

    /// Blit window content inside a rounded frame with anti-aliased corners.
    fn blitRounded(dst: Canvas, src_px: []const u32, src_w: i32, src_h: i32, at: Rect, shape: *const gfx.shapes.RRectShape, opaque_content: bool) void {
        const area = at.intersect(dst.clip);
        if (area.isEmpty()) return;
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            const sy = y - at.y;
            if (sy < 0 or sy >= src_h) continue;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const sp = shape.span(fy, 0) orelse continue;
            // Inner fully covered pixels and fractional edges.
            const xl = sp[0];
            const xr = sp[1];
            const x_in0: i32 = @max(area.x, @as(i32, @intFromFloat(@ceil(xl))));
            const x_in1: i32 = @min(area.right(), @as(i32, @intFromFloat(@floor(xr))));
            const src_row = src_px[@intCast(sy * src_w)..][0..@intCast(src_w)];
            const drow = dst.row(y);
            if (x_in1 > x_in0) {
                const s0: usize = @intCast(x_in0 - at.x);
                const s1: usize = @intCast(x_in1 - at.x);
                const d = drow[@intCast(x_in0)..@intCast(x_in1)];
                if (opaque_content) {
                    @memcpy(d, src_row[s0..s1]);
                } else {
                    for (d, src_row[s0..s1]) |*o, s| o.* = Color.over(s, o.*);
                }
            }
            // Left edge pixel.
            const lx: i32 = @intFromFloat(@floor(xl));
            if (lx >= area.x and lx < area.right() and lx < x_in0) {
                const cov: u8 = @intFromFloat(@min(255, (@as(f32, @floatFromInt(lx + 1)) - xl) * 255));
                const s = src_row[@intCast(lx - at.x)];
                drow[@intCast(lx)] = Color.over(Color.scaleAlpha(s, cov), drow[@intCast(lx)]);
            }
            const rx: i32 = @intFromFloat(@floor(xr));
            if (rx >= area.x and rx < area.right() and rx >= x_in1 and rx - at.x < src_w) {
                const cov: u8 = @intFromFloat(@min(255, (xr - @as(f32, @floatFromInt(rx))) * 255));
                const s = src_row[@intCast(rx - at.x)];
                drow[@intCast(rx)] = Color.over(Color.scaleAlpha(s, cov), drow[@intCast(rx)]);
            }
        }
    }

    fn drawTrafficLights(self: *Compositor, state: *st.State, win: *const wm.Window, focused: bool) void {
        const c = self.fb;
        const t = ui.theme;
        const hover_group = blk: {
            const l0 = win.trafficLight(0);
            const l2 = win.trafficLight(2);
            break :blk state.mouse.x >= l0.x - 10 and state.mouse.x <= l2.x + 10 and state.mouse.y >= l0.y - 10 and state.mouse.y <= l0.y + 10;
        };
        const colors = [3]u32{ t.traffic_close, t.traffic_minimize, t.traffic_zoom };
        for (0..3) |i| {
            const p = win.trafficLight(i);
            const cx: f32 = @floatFromInt(p.x);
            const cy: f32 = @floatFromInt(p.y);
            const active = focused or hover_group;
            const fill = if (active) colors[i] else if (state.dark() or win.flags & proto.Flags.dark != 0) t.traffic_inactive_dark else t.traffic_inactive_light;
            c.fillCircle(cx, cy, 6.5, pm(fill));
            c.strokeCircle(cx, cy, 6.5, 0.6, pm(0x26000000));
            if (hover_group) {
                const g = pm(0xA0000000);
                switch (i) {
                    0 => {
                        c.drawLine(cx - 2.6, cy - 2.6, cx + 2.6, cy + 2.6, 1.3, g);
                        c.drawLine(cx + 2.6, cy - 2.6, cx - 2.6, cy + 2.6, 1.3, g);
                    },
                    1 => c.drawLine(cx - 3, cy, cx + 3, cy, 1.4, g),
                    else => {
                        c.drawLine(cx - 3, cy, cx + 3, cy, 1.3, g);
                        c.drawLine(cx, cy - 3, cx, cy + 3, 1.3, g);
                    },
                }
            } else if (i == 0 and win.edited and active) {
                c.fillCircle(cx, cy, 2.2, pm(0x99000000));
            }
        }
    }

    fn drawWindow(self: *Compositor, state: *st.State, win: *wm.Window, dirty: Rect) void {
        const focused = state.manager.focused == win.id;
        const frame = toG(win.frame());
        const c = self.fb.withClip(dirty);
        // Windows may force dark chrome (Calculator, dark terminal profiles).
        const dark = state.dark() or win.flags & proto.Flags.dark != 0;
        const is_chrome_less = win.flags & (proto.Flags.borderless | proto.Flags.shield | proto.Flags.desktop) != 0;
        const radius: f32 = if (win.layer == .popup) 10 else if (is_chrome_less) 0 else wm.RADIUS;

        // Shadow.
        if (win.flags & proto.Flags.no_shadow == 0 and win.layer != .shield and win.layer != .desktop) {
            const mask = self.shadowFor(win, focused);
            const alpha: u8 = if (win.layer == .popup) 70 else if (focused) (if (dark) 150 else 95) else (if (dark) 110 else 60);
            const sr = frame.offset(0, if (focused) 10 else 5);
            if (mask.fits(sr)) mask.draw(c, sr, Color.rgba(0, 0, 0, alpha), null);
        }

        var rr = gfx.RoundRect.smooth(frame, radius);
        const shape = gfx.shapes.RRectShape.init(rr);
        const t = ui.Theme.get(dark, .blue);

        // Vibrancy backdrop for translucent windows: blurred wallpaper.
        const translucent = win.flags & proto.Flags.transparent != 0;
        if (translucent and !state.appearance.reduce_transparency) {
            var pat = gfx.Paint{ .image = .{ .src = self.wallpaper_blur.canvas(), .x = 0, .y = 0 } };
            pat.image.opacity = 255;
            c.fillRRect(rr, &pat);
            c.fillRRect(rr, pm(if (dark) 0x66202024 else 0x59F5F5F7));
        }

        // Title bar.
        if (win.hasTitlebar()) {
            var tb = rr;
            tb.rect = RectF.init(@floatFromInt(frame.x), @floatFromInt(frame.y), @floatFromInt(frame.w), wm.TITLEBAR);
            tb.radii.bl = 0;
            tb.radii.br = 0;
            const tb_color: u32 = if (dark) (if (focused) 0xFF2E2E31 else 0xFF262628) else (if (focused) 0xFFF0F0F2 else 0xFFF7F7F8);
            c.fillRRect(tb, pm(tb_color));
            c.fillRect(Rect.init(frame.x, frame.y + wm.TITLEBAR - 1, frame.w, 1), pm(if (dark) 0xFF141416 else 0xFFD6D6DA));
            const title = win.titleSlice();
            if (title.len > 0) {
                const f = self.fonts.face(.semibold, 13);
                const tw = f.measure(title);
                const max_w: f32 = @floatFromInt(frame.w - 160);
                const x = @as(f32, @floatFromInt(frame.x)) + @max(80, (@as(f32, @floatFromInt(frame.w)) - @min(tw, max_w)) / 2);
                const baseline = @round(@as(f32, @floatFromInt(frame.y)) + (@as(f32, wm.TITLEBAR) + f.cap_height) / 2);
                var target = font.Target.init(self.fb.pixels[0..@intCast(self.width * self.height)], @intCast(self.width), @intCast(self.height), @intCast(self.width));
                const cl = c.clip.intersect(Rect.init(frame.x + 70, frame.y, frame.w - 80, wm.TITLEBAR));
                target.clip = .{ .x0 = cl.x, .y0 = cl.y, .x1 = cl.right(), .y1 = cl.bottom() };
                _ = font.drawTextTruncated(target, f, title, x, baseline, max_w, pm(if (focused) t.label else t.tertiary_label));
            }
            rr.rect = RectF.init(@floatFromInt(frame.x), @floatFromInt(frame.y + wm.TITLEBAR), @floatFromInt(frame.w), @floatFromInt(frame.h - wm.TITLEBAR));
            rr.radii.tl = 0;
            rr.radii.tr = 0;
        }

        // Content.
        const content_shape = gfx.shapes.RRectShape.init(rr);
        if (win.pixels.len > 0) {
            const at = toG(win.content);
            const opaque_content = !translucent and win.layer != .popup and win.flags & proto.Flags.borderless == 0;
            blitRounded(c, win.pixels, win.buf_w, win.buf_h, Rect.init(at.x, at.y, @min(at.w, win.buf_w), @min(at.h, win.buf_h)), &content_shape, opaque_content);
        }

        // Rim light around the frame (glass edge).
        if (!is_chrome_less) {
            var rim = gfx.RoundRect.smooth(frame, radius);
            rim.rect = rim.rect.inset(0.5, 0.5);
            c.strokeRRect(rim, 1, pm(if (dark) 0x33FFFFFF else 0x1A000000));
            if (dark) {
                var inner = rim;
                inner.rect = rim.rect.inset(1, 1);
                c.strokeRRect(inner, 1, pm(0x14FFFFFF));
            }
        }
        if (win.hasControls() and !is_chrome_less) self.drawTrafficLights(state, win, focused);
        _ = shape;
    }

    /// Copy `r` of the framebuffer into the backdrop buffer and blur it.
    pub fn prepareBackdrop(self: *Compositor, r: Rect, radius: f32) Canvas {
        const b = self.backdrop.canvas();
        const area = r.intersect(b.bounds());
        if (area.isEmpty()) return b;
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            @memcpy(b.span(y, area.x, area.right()), self.fb.span(y, area.x, area.right()));
        }
        gfx.effects.blurFast(b, self.allocator, area, radius) catch gfx.effects.blur(b, area, radius / 3);
        return b;
    }

    /// Cached rendering of an app icon at a size.
    pub fn appIcon(self: *Compositor, name: []const u8, size: i32) ?Canvas {
        var key_buf: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}@{d}", .{ name, size }) catch return null;
        if (self.icon_cache.get(key)) |img| return img.canvas();
        var img = gfx.Image.init(self.allocator, @intCast(size), @intCast(size)) catch return null;
        img.canvas().clear(0);
        const pad: f32 = @as(f32, @floatFromInt(size)) * 0.04;
        const s: f32 = @floatFromInt(size);
        icons.drawApp(img.canvas(), self.allocator, icons.AppIcon.fromName(name), RectF.init(pad, pad, s - 2 * pad, s - 2 * pad));
        const owned_key = self.allocator.dupe(u8, key) catch return null;
        self.icon_cache.put(self.allocator, owned_key, img) catch return null;
        return img.canvas();
    }

    /// Composite everything intersecting `dirty` into the framebuffer.
    /// Returns the region actually redrawn (dirty may grow to cover glass).
    pub fn compose(self: *Compositor, state: *st.State, dirty_in: Rect) Rect {
        var dirty = dirty_in.intersect(self.fb.bounds());
        if (dirty.isEmpty()) return dirty;
        dirty = chrome.expandDirty(state, dirty);
        self.composing = dirty;
        const c = self.fb.withClip(dirty);

        // 1. Wallpaper.
        c.blitOpaque(self.wallpaper.canvas().sub(dirty), dirty.x, dirty.y);

        // 2. Windows below the shield level.
        const m = &state.manager;
        for (m.order.items) |id| {
            const win = m.get(id) orelse continue;
            if (!win.visible or win.minimized or win.layer == .shield) continue;
            if (!toG(win.paintBounds()).intersects(dirty)) continue;
            self.drawWindow(state, win, dirty);
        }

        // 3. System chrome.
        chrome.draw(self, state, dirty);

        // 4. Shield windows (login / lock screen) cover everything.
        for (m.order.items) |id| {
            const win = m.get(id) orelse continue;
            if (!win.visible or win.layer != .shield) continue;
            self.drawWindow(state, win, dirty);
        }
        return dirty;
    }
};
