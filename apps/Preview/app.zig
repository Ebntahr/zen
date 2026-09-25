//! Preview — the Zen image viewer.
//!
//! Opens PNG and PPM/PGM images (argv[1], Finder, `open`, or documents
//! handed over while it runs), fits them to the window, zooms (⌘+ ⌘- ⌘0
//! ⌘9, ⌘-scroll, double-click) and pans (drag, scroll, arrow keys).

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const gfx = @import("gfx");
const ui = @import("ui");
const icons = @import("icons");

const Ui = ui.Ui;
const Rect = ui.Rect;
const Flags = abi.window.Flags;
const Key = abi.input.Key;

const TOOLBAR_H = 52;
const MIN_ZOOM: f32 = 1.0 / 32.0;
const MAX_ZOOM: f32 = 32;
const max_path = 1024;

const M = struct {
    const about = 1;
    const quit = 2;
    const close = 10;
    const actual = 20;
    const zoom_in = 21;
    const zoom_out = 22;
    const fit = 23;
};

/// Decode a supported image file.
pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) !gfx.Image {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 256 << 20);
    defer allocator.free(bytes);
    if (std.mem.startsWith(u8, bytes, "\x89PNG")) return gfx.png_decode.decode(allocator, bytes);
    if (bytes.len > 2 and bytes[0] == 'P' and (bytes[1] == '6' or bytes[1] == '5')) return decodePnm(allocator, bytes);
    return error.UnsupportedFormat;
}

/// Binary PPM (P6) and PGM (P5) with 8-bit samples.
fn decodePnm(allocator: std.mem.Allocator, bytes: []const u8) !gfx.Image {
    var fields: [3]u32 = undefined;
    var pos: usize = 2;
    var n: usize = 0;
    while (n < 3) {
        while (pos < bytes.len and (std.ascii.isWhitespace(bytes[pos]) or bytes[pos] == '#')) {
            if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else pos += 1;
        }
        const start = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        if (start == pos) return error.Corrupt;
        fields[n] = try std.fmt.parseInt(u32, bytes[start..pos], 10);
        n += 1;
    }
    pos += 1; // single whitespace before the data
    const w = fields[0];
    const h = fields[1];
    if (fields[2] != 255 or w == 0 or h == 0 or @as(u64, w) * h > gfx.png_decode.max_pixels) return error.Unsupported;
    const channels: usize = if (bytes[1] == '6') 3 else 1;
    if (bytes.len < pos + @as(usize, w) * h * channels) return error.Corrupt;
    const img = try gfx.Image.init(allocator, w, h);
    for (img.pixels, 0..) |*p, i| {
        const s = bytes[pos + i * channels ..];
        const r: u32 = s[0];
        const g: u32 = if (channels == 3) s[1] else s[0];
        const b: u32 = if (channels == 3) s[2] else s[0];
        p.* = 0xFF000000 | r << 16 | g << 8 | b;
    }
    return img;
}

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Preview",
        .width = 860,
        .height = 620,
        .min_width = 380,
        .min_height = 280,
        .flags = Flags.resizable | Flags.full_size_content,
    };

    allocator: std.mem.Allocator,
    image: ?gfx.Image = null,
    path_buf: [max_path]u8 = undefined,
    path_len: usize = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,
    /// Scale factor; `fit` recomputes it for the window.
    zoom: f32 = 1,
    fit: bool = true,
    /// Image point shown at the centre of the viewport (image pixels).
    cx: f32 = 0,
    cy: f32 = 0,
    dragging: bool = false,
    drag_x: i32 = 0,
    drag_y: i32 = 0,
    /// The image scaled for the current zoom (when zoomed out).
    scaled: ?gfx.Image = null,
    scaled_zoom: f32 = 0,
    icon_cache: ?gfx.Image = null,

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        var app = App{ .allocator = allocator };
        u.win.setTitleHeight(TOOLBAR_H);
        var args = std.process.args();
        _ = args.next();
        if (args.next()) |arg| app.open(u, arg);
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.image) |*img| img.deinit(self.allocator);
        if (self.scaled) |*img| img.deinit(self.allocator);
        if (self.icon_cache) |*img| img.deinit(self.allocator);
    }

    /// Documents opened with Preview while it runs.
    pub fn openDocuments(self: *App, u: *Ui, paths: []const []const u8) void {
        self.open(u, paths[0]);
    }

    fn path(self: *const App) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn setError(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.err_len = (std.fmt.bufPrint(&self.err_buf, fmt, args) catch self.err_buf[0..0]).len;
    }

    /// Open a path or `file:` URL.
    pub fn open(self: *App, u: *Ui, arg: []const u8) void {
        var decoded: [max_path]u8 = undefined;
        var p = arg;
        if (std.mem.startsWith(u8, p, "file://")) {
            p = zen.url.decode(p[7..], &decoded);
        } else if (std.mem.startsWith(u8, p, "file:")) {
            p = zen.url.decode(p[5..], &decoded);
        }
        self.path_len = @min(p.len, self.path_buf.len);
        std.mem.copyForwards(u8, self.path_buf[0..self.path_len], p[0..self.path_len]);
        self.err_len = 0;
        const img = loadImage(self.allocator, self.path()) catch |err| {
            self.setError("\u{201C}{s}\u{201D} could not be opened ({s}).", .{ std.fs.path.basename(self.path()), switch (err) {
                error.FileNotFound => "not found",
                error.AccessDenied => "permission denied",
                error.UnsupportedFormat, error.NotPng, error.Unsupported => "unsupported format",
                error.TooLarge => "image too large",
                else => "damaged file",
            } });
            u.win.setTitle("Preview");
            return;
        };
        if (self.image) |*old| old.deinit(self.allocator);
        self.image = img;
        self.dropScaled();
        self.fit = true;
        self.cx = @as(f32, @floatFromInt(img.width)) / 2;
        self.cy = @as(f32, @floatFromInt(img.height)) / 2;
        u.win.setTitle(std.fs.path.basename(self.path()));
        u.want_frame = true;
    }

    fn dropScaled(self: *App) void {
        if (self.scaled) |*img| img.deinit(self.allocator);
        self.scaled = null;
        self.scaled_zoom = 0;
    }

    fn viewport(u: *const Ui) Rect {
        return Rect.init(0, TOOLBAR_H, u.width(), @max(1, u.height() - TOOLBAR_H));
    }

    fn fitZoom(self: *const App, u: *const Ui) f32 {
        const img = self.image orelse return 1;
        const v = viewport(u);
        const zx = @as(f32, @floatFromInt(v.w - 40)) / @as(f32, @floatFromInt(img.width));
        const zy = @as(f32, @floatFromInt(v.h - 40)) / @as(f32, @floatFromInt(img.height));
        return std.math.clamp(@min(@min(zx, zy), 1), MIN_ZOOM, 1);
    }

    fn currentZoom(self: *const App, u: *const Ui) f32 {
        return if (self.fit) self.fitZoom(u) else self.zoom;
    }

    fn setZoom(self: *App, u: *Ui, z: f32) void {
        self.zoom = std.math.clamp(z, MIN_ZOOM, MAX_ZOOM);
        self.fit = false;
        self.clampCenter(u);
    }

    /// Keep the image on screen: centred when smaller than the viewport.
    fn clampCenter(self: *App, u: *const Ui) void {
        const img = self.image orelse return;
        const z = self.currentZoom(u);
        const v = viewport(u);
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);
        const half_w = @as(f32, @floatFromInt(v.w)) / 2 / z;
        const half_h = @as(f32, @floatFromInt(v.h)) / 2 / z;
        self.cx = if (iw <= half_w * 2) iw / 2 else std.math.clamp(self.cx, half_w, iw - half_w);
        self.cy = if (ih <= half_h * 2) ih / 2 else std.math.clamp(self.cy, half_h, ih - half_h);
    }

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        _ = self;
        mw.beginMenu("Preview");
        mw.item(M.about, "About Preview", 0, 0, 0);
        mw.separator();
        mw.item(M.quit, "Quit Preview", 'q', 0, 0);
        mw.endMenu();
        mw.beginMenu("File");
        mw.item(M.close, "Close Window", 'w', 0, 0);
        mw.endMenu();
        mw.beginMenu("View");
        mw.item(M.actual, "Actual Size", '0', 0, 0);
        mw.item(M.zoom_in, "Zoom In", '=', 0, 0);
        mw.item(M.zoom_out, "Zoom Out", '-', 0, 0);
        mw.item(M.fit, "Zoom to Fit", '9', 0, 0);
        mw.endMenu();
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        switch (id) {
            M.quit, M.close => u.quit = true,
            M.actual => self.setZoom(u, 1),
            M.zoom_in => self.setZoom(u, self.currentZoom(u) * 1.25),
            M.zoom_out => self.setZoom(u, self.currentZoom(u) / 1.25),
            M.fit => {
                self.fit = true;
                self.clampCenter(u);
            },
            M.about => u.win.notify("Preview", "Zen OS image viewer — PNG, PPM and PGM."),
            else => {},
        }
    }

    fn handleInput(self: *App, u: *Ui) void {
        const img = self.image orelse return;
        _ = img;
        const v = viewport(u);
        const cmd = abi.window.Mods.cmd;
        if (u.shortcut(Key.equal, cmd)) self.setZoom(u, self.currentZoom(u) * 1.25);
        if (u.shortcut(Key.minus, cmd)) self.setZoom(u, self.currentZoom(u) / 1.25);
        if (u.shortcut(Key.@"0", cmd)) self.setZoom(u, 1);
        if (u.shortcut(Key.@"9", cmd)) {
            self.fit = true;
            self.clampCenter(u);
        }
        const z = self.currentZoom(u);
        const step = 60 / z;
        if (u.keyPressed(Key.left)) self.cx -= step;
        if (u.keyPressed(Key.right)) self.cx += step;
        if (u.keyPressed(Key.up)) self.cy -= step;
        if (u.keyPressed(Key.down)) self.cy += step;

        const over = u.hovering(v);
        if (over and (u.scroll_dx != 0 or u.scroll_dy != 0)) {
            if (u.mods & cmd != 0) {
                // Zoom around the pointer.
                const factor: f32 = if (u.scroll_dy < 0) 1.1 else 1.0 / 1.1;
                const px = self.cx + (@as(f32, @floatFromInt(u.mouse_x - v.x)) - @as(f32, @floatFromInt(v.w)) / 2) / z;
                const py = self.cy + (@as(f32, @floatFromInt(u.mouse_y - v.y)) - @as(f32, @floatFromInt(v.h)) / 2) / z;
                self.setZoom(u, z * factor);
                const nz = self.currentZoom(u);
                self.cx = px - (@as(f32, @floatFromInt(u.mouse_x - v.x)) - @as(f32, @floatFromInt(v.w)) / 2) / nz;
                self.cy = py - (@as(f32, @floatFromInt(u.mouse_y - v.y)) - @as(f32, @floatFromInt(v.h)) / 2) / nz;
            } else {
                self.cx += u.scroll_dx / z;
                self.cy += u.scroll_dy / z;
            }
        }
        if (u.mouse_pressed and over) {
            if (u.click_count == 2) {
                if (self.fit) self.setZoom(u, 1) else self.fit = true;
            } else {
                self.dragging = true;
                self.drag_x = u.mouse_x;
                self.drag_y = u.mouse_y;
            }
        }
        if (self.dragging) {
            if (!u.mouse_down) {
                self.dragging = false;
            } else {
                self.cx -= @as(f32, @floatFromInt(u.mouse_x - self.drag_x)) / z;
                self.cy -= @as(f32, @floatFromInt(u.mouse_y - self.drag_y)) / z;
                self.drag_x = u.mouse_x;
                self.drag_y = u.mouse_y;
            }
            u.cursor = .move;
        }
        self.clampCenter(u);
    }

    fn drawChecker(u: *Ui, r: Rect) void {
        const dark = u.theme.dark;
        const a: u32 = if (dark) 0xFF2C2C2E else 0xFFFFFFFF;
        const b: u32 = if (dark) 0xFF3A3A3C else 0xFFE5E5EA;
        const cell = 8;
        var y = r.y;
        while (y < r.y + r.h) : (y += cell) {
            var x = r.x;
            while (x < r.x + r.w) : (x += cell) {
                const odd = @mod(@divFloor(x - r.x, cell) + @divFloor(y - r.y, cell), 2) == 1;
                u.fillRect(Rect.init(x, y, @min(cell, r.x + r.w - x), @min(cell, r.y + r.h - y)), if (odd) b else a);
            }
        }
    }

    fn drawImage(self: *App, u: *Ui) void {
        const img = self.image orelse return;
        const v = viewport(u);
        const z = self.currentZoom(u);
        const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(img.width)) * z));
        const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(img.height)) * z));
        const x: i32 = v.x + @divTrunc(v.w, 2) - @as(i32, @intFromFloat(@round(self.cx * z)));
        const y: i32 = v.y + @divTrunc(v.h, 2) - @as(i32, @intFromFloat(@round(self.cy * z)));
        const dst = Rect.init(x, y, @max(1, w), @max(1, h));
        const old = u.pushClip(v);
        defer u.popClip(old);
        if (w < v.w and h < v.h) u.shadow(dst, 2, 18, 6, 0x40000000);
        drawChecker(u, dst.intersect(v));
        if (@abs(z - 1) < 0.001) {
            u.canvas.drawImage(img.canvas(), x, y, 255);
        } else if (z < 1) {
            // Zoomed out: scale once, then blit (cheap for later frames).
            if (self.scaled == null or self.scaled_zoom != z) {
                self.dropScaled();
                if (gfx.Image.init(self.allocator, @intCast(@max(1, w)), @intCast(@max(1, h)))) |s| {
                    var sc = s;
                    sc.canvas().drawImageScaled(img.canvas(), Rect.init(0, 0, @max(1, w), @max(1, h)), 255);
                    self.scaled = sc;
                    self.scaled_zoom = z;
                } else |_| {}
            }
            if (self.scaled) |s| u.canvas.drawImage(s.canvas(), x, y, 255) else u.canvas.drawImageScaled(img.canvas(), dst, 255);
        } else {
            u.canvas.drawImageScaled(img.canvas(), dst, 255);
        }
    }

    fn drawToolbar(self: *App, u: *Ui) void {
        const t = u.theme;
        u.fillRect(Rect.init(0, 0, u.width(), TOOLBAR_H), t.window_bg);
        u.hline(0, u.width(), TOOLBAR_H - 1, t.separator);
        const title = if (self.path_len > 0) std.fs.path.basename(self.path()) else "Preview";
        u.text(Rect.init(86, 9, u.width() - 330, 18), title, .{ .size = 13, .weight = .semibold });
        if (self.image) |img| {
            var buf: [64]u8 = undefined;
            const z = self.currentZoom(u);
            const info = std.fmt.bufPrint(&buf, "{d} \u{00D7} {d} \u{2014} {d}%", .{ img.width, img.height, @as(u32, @intFromFloat(@round(z * 100))) }) catch "";
            u.text(Rect.init(86, 27, u.width() - 330, 16), info, .{ .size = 11, .color = t.secondary_label });
        }
        const bx = u.width() - 214;
        const enabled = self.image != null;
        if (u.button("zoom-out", Rect.init(bx, 12, 34, 28), "\u{2212}", .{ .style = .toolbar, .enabled = enabled, .size = 17 })) self.setZoom(u, self.currentZoom(u) / 1.25);
        if (u.button("zoom-in", Rect.init(bx + 38, 12, 34, 28), "+", .{ .style = .toolbar, .enabled = enabled, .size = 17 })) self.setZoom(u, self.currentZoom(u) * 1.25);
        if (u.button("actual", Rect.init(bx + 80, 12, 58, 28), "100%", .{ .style = .toolbar, .enabled = enabled })) self.setZoom(u, 1);
        if (u.button("fit", Rect.init(bx + 142, 12, 58, 28), "Fit", .{ .style = if (self.fit) .primary else .toolbar, .enabled = enabled })) {
            self.fit = true;
            self.clampCenter(u);
        }
    }

    fn drawEmpty(self: *App, u: *Ui) void {
        const v = viewport(u);
        const t = u.theme;
        const cx = v.x + @divTrunc(v.w, 2);
        const cy = v.y + @divTrunc(v.h, 2);
        if (self.icon_cache == null) {
            if (gfx.Image.init(self.allocator, 96, 96)) |img| {
                var i = img;
                icons.drawApp(i.canvas(), self.allocator, .preview, gfx.RectF.init(0, 0, 96, 96));
                self.icon_cache = i;
            } else |_| {}
        }
        if (self.icon_cache) |img| u.canvas.drawImage(img.canvas(), cx - 48, cy - 110, 255);
        const msg = if (self.err_len > 0) self.err_buf[0..self.err_len] else "Open an image from Finder, or run `open picture.png` in Terminal.";
        u.text(Rect.init(v.x + 20, cy + 2, v.w - 40, 22), if (self.err_len > 0) "Cannot open the image" else "No image", .{ .size = 17, .weight = .semibold, .@"align" = .center });
        u.text(Rect.init(v.x + 20, cy + 30, v.w - 40, 20), msg, .{ .size = 13, .color = t.secondary_label, .@"align" = .center });
    }

    pub fn frame(self: *App, u: *Ui) void {
        self.handleInput(u);
        const dark = u.theme.dark;
        u.clear(if (dark) 0xFF1C1C1E else 0xFFE9E9EC);
        if (self.image != null) self.drawImage(u) else self.drawEmpty(u);
        self.drawToolbar(u);
    }

    /// State for host previews (a generated image).
    pub fn preview(self: *App, u: *Ui) void {
        const w = 1200;
        const h = 760;
        var img = gfx.Image.init(self.allocator, w, h) catch return;
        gfx.wallpaper.render(img.canvas(), self.allocator, .golden_gate, .{ .detail = 1 }) catch {};
        self.image = img;
        const p = "Golden Gate.png";
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;
        self.cx = w / 2;
        self.cy = h / 2;
        _ = u;
    }
};

test "pnm decoding" {
    const a = std.testing.allocator;
    var img = try decodePnm(a, "P6\n# comment\n2 1\n255\n\x10\x20\x30\x40\x50\x60");
    defer img.deinit(a);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF102030, 0xFF405060 }, img.pixels);
    var grey = try decodePnm(a, "P5 1 1 255 \x80");
    defer grey.deinit(a);
    try std.testing.expectEqual(@as(u32, 0xFF808080), grey.pixels[0]);
    try std.testing.expectError(error.Unsupported, decodePnm(a, "P6 1 1 65535 \x00\x00"));
}
