//! Visual check for the font engine: renders text samples (all bundled
//! faces, many sizes, light and dark backgrounds, kerning, wrapping,
//! truncation and code) to a PNG.
//!
//! Run from the repository root (the tool imports the library as a module):
//!
//!     zig run --dep font -Mroot=lib/font/tools/render_test.zig \
//!         -Mfont=lib/font/root.zig -- /tmp/font_out/text.png

const std = @import("std");
const font = @import("font");

const fonts_dir = "assets/fonts/";
const font_files = [_][]const u8{
    "Inter-Regular.ttf",
    "Inter-Medium.ttf",
    "Inter-SemiBold.ttf",
    "Inter-Bold.ttf",
    "JetBrainsMono-Regular.ttf",
    "JetBrainsMono-Bold.ttf",
};
const font_names = [_][]const u8{
    "Inter Regular",
    "Inter Medium",
    "Inter SemiBold",
    "Inter Bold",
    "JetBrains Mono Regular",
    "JetBrains Mono Bold",
};
const inter_regular = 0;
const inter_medium = 1;
const inter_semibold = 2;
const mono_regular = 4;
const mono_bold = 5;

const small_sizes = [_]f32{ 11, 12, 13, 15, 17 };
const sample = "The quick brown fox jumps over the lazy dog. 0123456789 AVAWAY Tokyo Typography " ++
    "(“quotes”, ‘it’s’) — !?@#$%&*[]{}<>/\\|~ …";
const kerning_sample = "AVAWAY Tokyo Typography";
const intl_sample = "Äpfel · Ölçü · Ñandú · Øresund · Łódź · Straße · ĲSSEL · Ελληνικά · Кириллица · № 42 · €19,99 · ½ ≠ ¼";

const code_sample =
    \\const std = @import("std");
    \\
    \\/// Sums a slice of integers. 0O 1lI| {}[]() => != <= ->
    \\pub fn sum(values: []const i64) i64 {
    \\    var total: i64 = 0;
    \\    for (values) |v| total += v; // "strings" and 'chars'
    \\    return total;
    \\}
++ "\n\t// tab-indented comment";

const paragraph = "Zen OS renders text with a pure-Zig TrueType engine: exact-area anti-aliasing, " ++
    "quarter-pixel positioning and GPOS kerning. This paragraph is word-wrapped to the box, " ++
    "breaking after hyphens in well-known compound-words, and a word longer than the box like " ++
    "Donaudampfschifffahrtsgesellschaftskapitänsmützenabzeichen falls back to character breaks.\n" ++
    "A hard line break starts a new paragraph.";

const ink = 0xFF1D1D1F; // label color on light backgrounds
const ink_secondary = 0xFF6E6E73;
const ink_light = 0xFFFFFFFF;
const ink_light_secondary = 0xFFAEAEB2;

/// Loaded fonts plus lazily created faces, each at a stable address.
const Library = struct {
    allocator: std.mem.Allocator,
    data: [font_files.len][]u8,
    fonts: [font_files.len]font.Font,
    faces: std.ArrayList(*font.Face) = .empty,

    fn init(self: *Library, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator, .data = undefined, .fonts = undefined };
        for (font_files, 0..) |name, i| {
            var buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ fonts_dir, name });
            self.data[i] = std.fs.cwd().readFileAlloc(allocator, path, 16 << 20) catch |err| {
                std.debug.print("cannot read {s}: {s} (run from the repository root)\n", .{ path, @errorName(err) });
                return err;
            };
            self.fonts[i] = try font.Font.init(allocator, self.data[i]);
        }
    }

    fn deinit(self: *Library) void {
        for (self.faces.items) |f| {
            f.deinit();
            self.allocator.destroy(f);
        }
        self.faces.deinit(self.allocator);
        for (&self.fonts, self.data) |*f, d| {
            f.deinit();
            self.allocator.free(d);
        }
    }

    fn face(self: *Library, index: usize, size: f32) !*font.Face {
        for (self.faces.items) |f| {
            if (f.font == &self.fonts[index] and f.size == size) return f;
        }
        const f = try self.allocator.create(font.Face);
        errdefer self.allocator.destroy(f);
        f.* = try font.Face.init(self.allocator, &self.fonts[index], size, .{});
        // Monospace text falls back to Inter for characters Mono lacks.
        if (index >= mono_regular) f.fallback = try self.face(inter_regular, size);
        try self.faces.append(self.allocator, f);
        return f;
    }
};

const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    fn target(self: Canvas) font.Target {
        return font.Target.init(self.pixels, self.width, self.height, self.width);
    }

    fn fill(self: Canvas, x0: u32, y0: u32, x1: u32, y1: u32, color: u32) void {
        for (y0..@min(y1, self.height)) |y| @memset(self.pixels[y * self.width + x0 .. y * self.width + @min(x1, self.width)], color);
    }

    /// Diagonal two-color gradient, like a dark desktop wallpaper.
    fn gradient(self: Canvas, y0: u32, y1: u32, a: [3]f32, b: [3]f32) void {
        const span: f32 = @floatFromInt(self.width + (y1 - y0));
        for (y0..y1) |y| for (0..self.width) |x| {
            const t = @as(f32, @floatFromInt(x + (y - y0))) / span;
            var c: u32 = 0xFF000000;
            for (0..3) |i| {
                const v = a[i] + (b[i] - a[i]) * t;
                c |= @as(u32, @intFromFloat(v)) << @intCast(16 - 8 * i);
            }
            self.pixels[y * self.width + x] = c;
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const out_path = if (args.len > 1) args[1] else "/tmp/font_out/text.png";

    var lib: Library = undefined;
    try lib.init(allocator);
    defer lib.deinit();

    const width = 1500;
    const height = 3000;
    const canvas: Canvas = .{ .pixels = try allocator.alloc(u32, width * height), .width = width, .height = height };
    defer allocator.free(canvas.pixels);
    canvas.fill(0, 0, width, height, 0xFFFFFFFF);
    const target = canvas.target();

    var timer = try std.time.Timer.start();
    var y: f32 = 20;

    // ---- Light section: every face at every size.
    const title = try lib.face(inter_semibold, 24);
    y += title.ascent;
    _ = font.drawText(target, title, "Zen OS font engine — Inter & JetBrains Mono", 24, y, ink);
    y += title.descent + 12;

    for (font_names, 0..) |name, fi| {
        const caption = try lib.face(inter_medium, 11);
        y += caption.ascent + 6;
        _ = font.drawText(target, caption, name, 24, y, ink_secondary);
        y += caption.descent + 2;
        for (small_sizes) |size| {
            const f = try lib.face(fi, size);
            y += @round(f.ascent);
            var label: [16]u8 = undefined;
            _ = font.drawText(target, caption, try std.fmt.bufPrint(&label, "{d}px", .{size}), 24, y, ink_secondary);
            _ = font.drawText(target, f, sample, 64, y, ink);
            y += @round(f.descent + f.line_gap);
        }
        {
            const f = try lib.face(fi, 15);
            y += @round(f.ascent);
            _ = font.drawText(target, f, intl_sample, 64, y, ink);
            y += @round(f.descent + f.line_gap);
        }
        const big = [_]f32{ 24, 36, 64 };
        var x: f32 = 64;
        const row_top = y;
        var row_bottom = y;
        for (big) |size| {
            const f = try lib.face(fi, size);
            const text = if (size == 64) "AVAWAY Tokyo" else if (size == 36) kerning_sample else "Typography 0123456789 ?!&";
            const base = row_top + (try lib.face(fi, 64)).ascent;
            x = font.drawText(target, f, text, x, base, ink) + 24;
            row_bottom = @max(row_bottom, base + f.descent);
        }
        y = row_bottom + 4;
    }

    // ---- Kerning on/off, wrapping, truncation, code.
    y += 16;
    {
        const f = try lib.face(inter_regular, 36);
        const caption = try lib.face(inter_medium, 11);
        y += f.ascent;
        _ = font.drawText(target, caption, "kerned", 24, y - 12, ink_secondary);
        _ = font.drawText(target, f, kerning_sample, 80, y, ink);
        _ = font.drawText(target, caption, "unkerned", 760, y - 12, ink_secondary);
        var x: f32 = 820;
        var it = font.utf8.Iterator.init(kerning_sample);
        var start: usize = 0;
        while (it.next()) |_| : (start = it.i) {
            x = font.drawText(target, f, kerning_sample[start..it.i], x, y, ink);
        }
        y += f.descent + 16;
    }
    {
        const f = try lib.face(inter_regular, 13);
        const box_w: f32 = 360;
        const wrapped = try f.layoutLines(allocator, paragraph, box_w);
        defer allocator.free(wrapped);
        const box_h = @as(f32, @floatFromInt(wrapped.len)) * f.line_height;
        canvas.fill(24, @intFromFloat(y), 24 + @as(u32, @intFromFloat(box_w)) + 16, @intFromFloat(y + box_h + 16), 0xFFF2F2F7);
        _ = font.drawTextWrapped(target, f, paragraph, 32, y + 8, box_w, ink);
        // Truncated labels next to the box.
        const widths = [_]f32{ 400, 260, 180, 120, 60 };
        var ty = y + 8 + f.ascent;
        for (widths) |w| {
            canvas.fill(440, @intFromFloat(ty - f.ascent), 440 + @as(u32, @intFromFloat(w)), @intFromFloat(ty + f.descent), 0xFFE5F0FF);
            _ = font.drawTextTruncated(target, f, "Quarterly Report — Final Draft (v3).pdf", 440, ty, w, ink);
            ty += f.line_height + 4;
        }
        // Code on the right.
        const mono = try lib.face(mono_regular, 13);
        _ = font.drawText(target, mono, code_sample, 880, y + 8 + mono.ascent, ink);
        const code_lines: f32 = @floatFromInt(std.mem.count(u8, code_sample, "\n") + 1);
        y += @max(box_h, code_lines * mono.line_height) + 32;
    }

    // ---- Dark section: white text on a gradient.
    const dark_top: u32 = @intFromFloat(y);
    canvas.gradient(dark_top, height, .{ 28, 30, 58 }, .{ 70, 32, 70 });
    y += 24;
    for ([_]usize{ inter_regular, inter_medium, inter_semibold, 3 }) |fi| {
        const caption = try lib.face(inter_medium, 11);
        y += caption.ascent;
        _ = font.drawText(target, caption, font_names[fi], 24, y, ink_light_secondary);
        y += caption.descent + 2;
        for (small_sizes) |size| {
            const f = try lib.face(fi, size);
            y += @round(f.ascent);
            _ = font.drawText(target, f, sample, 64, y, ink_light);
            y += @round(f.descent + f.line_gap);
        }
        y += 8;
    }
    {
        const f24 = try lib.face(inter_semibold, 24);
        const f36 = try lib.face(inter_regular, 36);
        y += f36.ascent;
        const x = font.drawText(target, f36, kerning_sample, 24, y, ink_light);
        _ = font.drawText(target, f24, "Liquid Glass · 0123456789", x + 32, y, ink_light_secondary);
        y += f36.descent + 16;

        const mono = try lib.face(mono_regular, 13);
        const mono_b = try lib.face(mono_bold, 13);
        const end = font.drawText(target, mono_b, "$ ", 24, y + mono.ascent, 0xFF64D2FF);
        _ = font.drawText(target, mono, "zig build run -Dtarget=riscv64-freestanding  # ok ✓ → λ", end, y + mono.ascent, ink_light);
        _ = font.drawText(target, mono, code_sample, 24, y + mono.ascent + 2 * mono.line_height, 0xFFE5E5EA);
        y += 11 * mono.line_height;
    }

    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / 1e6;
    var cached: usize = 0;
    for (lib.faces.items) |f| cached += f.cache.count();
    std.debug.print("rendered {d} glyph bitmaps across {d} faces in {d:.1} ms; content height {d}\n", .{ cached, lib.faces.items.len, elapsed_ms, @as(u32, @intFromFloat(y)) });

    const used_height: u32 = @min(height, @as(u32, @intFromFloat(y)) + 16);
    try writePng(allocator, out_path, canvas.pixels[0 .. width * used_height], width, used_height);
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out_path, width, used_height });
}

/// Writes opaque ARGB pixels as an 8-bit RGB PNG using stored (uncompressed)
/// deflate blocks.
fn writePng(allocator: std.mem.Allocator, path: []const u8, pixels: []const u32, width: u32, height: u32) !void {
    // Raw scanlines: filter type 0 followed by RGB triples.
    const row_len = 1 + width * 3;
    const raw = try allocator.alloc(u8, row_len * height);
    defer allocator.free(raw);
    for (0..height) |y| {
        const row = raw[y * row_len ..][0..row_len];
        row[0] = 0;
        for (pixels[y * width ..][0..width], 0..) |p, x| {
            row[1 + x * 3 ..][0..3].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
        }
    }

    // zlib stream with stored blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(allocator);
    try z.appendSlice(allocator, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (true) {
        const n = @min(raw.len - off, 65535);
        const final = off + n == raw.len;
        try z.append(allocator, @intFromBool(final));
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, hdr[2..4], ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(allocator, &hdr);
        try z.appendSlice(allocator, raw[off..][0..n]);
        off += n;
        if (final) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(allocator, &adler);

    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(allocator);
    try png.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 }; // 8-bit RGB, deflate, no filter/interlace
    try appendChunk(allocator, &png, "IHDR", &ihdr);
    try appendChunk(allocator, &png, "IDAT", z.items);
    try appendChunk(allocator, &png, "IEND", "");

    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = png.items });
}

fn appendChunk(allocator: std.mem.Allocator, png: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(data.len), .big);
    try png.appendSlice(allocator, &buf);
    try png.appendSlice(allocator, kind);
    try png.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    std.mem.writeInt(u32, &buf, crc.final(), .big);
    try png.appendSlice(allocator, &buf);
}
