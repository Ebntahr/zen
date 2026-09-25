//! PNG decoding into premultiplied 0xAARRGGBB images.
//!
//! Supports every PNG colour type (grey, RGB, palette, grey+alpha, RGBA),
//! bit depths 1–16, tRNS transparency and Adam7 interlacing. Ancillary
//! chunks other than tRNS are ignored; CRCs are not checked.

const std = @import("std");
const canvas = @import("canvas.zig");

pub const Error = error{ NotPng, Unsupported, Corrupt, TooLarge, OutOfMemory };

/// Largest accepted image (pixels): 16k × 16k.
pub const max_pixels: u64 = 16384 * 16384;

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlace: bool,

    fn channels(h: Header) u8 {
        return switch (h.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => 0,
        };
    }

    fn bitsPerPixel(h: Header) usize {
        return @as(usize, h.channels()) * h.depth;
    }

    /// Bytes per row of `w` pixels (without the filter byte).
    fn rowBytes(h: Header, w: u32) usize {
        return (@as(usize, w) * h.bitsPerPixel() + 7) / 8;
    }
};

fn premul(r: u32, g: u32, b: u32, a: u32) u32 {
    if (a == 255) return 0xFF000000 | (r << 16) | (g << 8) | b;
    if (a == 0) return 0;
    return (a << 24) | ((r * a + 127) / 255 << 16) | ((g * a + 127) / 255 << 8) | ((b * a + 127) / 255);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Undo the per-row filters of one (sub)image in place.
fn unfilter(data: []u8, rows: usize, row_bytes: usize, bpp: usize) Error!void {
    var prev: ?[]u8 = null;
    for (0..rows) |y| {
        const start = y * (row_bytes + 1);
        const kind = data[start];
        const row = data[start + 1 .. start + 1 + row_bytes];
        switch (kind) {
            0 => {},
            1 => for (bpp..row.len) |i| {
                row[i] +%= row[i - bpp];
            },
            2 => if (prev) |p| for (row, p) |*v, u| {
                v.* +%= u;
            },
            3 => for (row, 0..) |*v, i| {
                const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                const up: u16 = if (prev) |p| p[i] else 0;
                v.* +%= @intCast((left + up) / 2);
            },
            4 => for (row, 0..) |*v, i| {
                const left: u8 = if (i >= bpp) row[i - bpp] else 0;
                const up: u8 = if (prev) |p| p[i] else 0;
                const ul: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                v.* +%= paeth(left, up, ul);
            },
            else => return error.Corrupt,
        }
        prev = row;
    }
}

const Palette = struct {
    rgb: [256][3]u8 = undefined,
    alpha: [256]u8 = [_]u8{255} ** 256,
    len: usize = 0,
};

const Trns = struct { gray: ?u16 = null, rgb: ?[3]u16 = null };

/// Sample `index` of a packed row (depth < 8 or == 8/16).
fn sample(row: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[index * 2 ..][0..2], .big),
        8 => row[index],
        else => blk: {
            const bit = index * depth;
            const byte = row[bit / 8];
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :blk (byte >> shift) & mask;
        },
    };
}

/// Scale a sample to 8 bits.
fn to8(v: u16, depth: u8) u32 {
    return switch (depth) {
        16 => v >> 8,
        8 => v,
        4 => v * 17,
        2 => v * 85,
        1 => v * 255,
        else => 0,
    };
}

fn convertRow(h: Header, row: []const u8, w: u32, pal: *const Palette, trns: Trns, out: []u32, stride: usize) void {
    for (0..w) |x| {
        const px: u32 = switch (h.color) {
            0 => blk: {
                const v = sample(row, x, h.depth);
                const g = to8(v, h.depth);
                const a: u32 = if (trns.gray != null and trns.gray.? == v) 0 else 255;
                break :blk premul(g, g, g, a);
            },
            2 => blk: {
                const r = sample(row, x * 3, h.depth);
                const g = sample(row, x * 3 + 1, h.depth);
                const b = sample(row, x * 3 + 2, h.depth);
                const a: u32 = if (trns.rgb) |t| (if (t[0] == r and t[1] == g and t[2] == b) 0 else 255) else 255;
                break :blk premul(to8(r, h.depth), to8(g, h.depth), to8(b, h.depth), a);
            },
            3 => blk: {
                const i = sample(row, x, h.depth);
                if (i >= pal.len) break :blk 0;
                const c = pal.rgb[i];
                break :blk premul(c[0], c[1], c[2], pal.alpha[i]);
            },
            4 => blk: {
                const g = to8(sample(row, x * 2, h.depth), h.depth);
                break :blk premul(g, g, g, to8(sample(row, x * 2 + 1, h.depth), h.depth));
            },
            6 => premul(
                to8(sample(row, x * 4, h.depth), h.depth),
                to8(sample(row, x * 4 + 1, h.depth), h.depth),
                to8(sample(row, x * 4 + 2, h.depth), h.depth),
                to8(sample(row, x * 4 + 3, h.depth), h.depth),
            ),
            else => 0,
        };
        out[x * stride] = px;
    }
}

/// Decode a PNG file into a new image (caller owns `pixels`).
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!canvas.Image {
    const sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len < sig.len or !std.mem.eql(u8, bytes[0..sig.len], sig)) return error.NotPng;
    var pos: usize = sig.len;
    var hdr: ?Header = null;
    var pal = Palette{};
    var trns = Trns{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + @as(usize, len) > bytes.len) return error.Corrupt;
        const body = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            const h = Header{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .depth = body[8],
                .color = body[9],
                .interlace = body[12] == 1,
            };
            if (h.width == 0 or h.height == 0) return error.Corrupt;
            if (@as(u64, h.width) * h.height > max_pixels) return error.TooLarge;
            if (h.channels() == 0) return error.Unsupported;
            const ok_depth = switch (h.color) {
                0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                else => h.depth == 8 or h.depth == 16,
            };
            if (!ok_depth or body[10] != 0 or body[11] != 0) return error.Unsupported;
            hdr = h;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            pal.len = @min(len / 3, 256);
            for (0..pal.len) |i| pal.rgb[i] = .{ body[i * 3], body[i * 3 + 1], body[i * 3 + 2] };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const h = hdr orelse return error.Corrupt;
            switch (h.color) {
                3 => for (body[0..@min(len, 256)], 0..) |a, i| {
                    pal.alpha[i] = a;
                },
                0 => if (len >= 2) {
                    trns.gray = std.mem.readInt(u16, body[0..2], .big);
                },
                2 => if (len >= 6) {
                    trns.rgb = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    const h = hdr orelse return error.Corrupt;
    if (h.color == 3 and pal.len == 0) return error.Corrupt;

    // Inflate the zlib stream.
    var in: std.Io.Reader = .fixed(idat.items);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var inflate: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    _ = inflate.reader.streamRemaining(&aw.writer) catch return error.Corrupt;
    const raw = aw.written();

    var img = canvas.Image.init(allocator, h.width, h.height) catch return error.OutOfMemory;
    errdefer img.deinit(allocator);
    const bpp = @max(1, h.bitsPerPixel() / 8);

    if (!h.interlace) {
        const rb = h.rowBytes(h.width);
        if (raw.len < (rb + 1) * h.height) return error.Corrupt;
        try unfilter(raw, h.height, rb, bpp);
        for (0..h.height) |y| {
            const row = raw[y * (rb + 1) + 1 ..][0..rb];
            convertRow(h, row, h.width, &pal, trns, img.pixels[y * h.width ..], 1);
        }
        return img;
    }

    // Adam7: seven passes over a sparse grid.
    const passes = [7][4]u32{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    var off: usize = 0;
    for (passes) |p| {
        if (h.width <= p[0] or h.height <= p[1]) continue;
        const pw = (h.width - p[0] + p[2] - 1) / p[2];
        const ph = (h.height - p[1] + p[3] - 1) / p[3];
        const rb = h.rowBytes(pw);
        const size = (rb + 1) * ph;
        if (off + size > raw.len) return error.Corrupt;
        const sub = raw[off..][0..size];
        off += size;
        try unfilter(sub, ph, rb, bpp);
        for (0..ph) |py| {
            const row = sub[py * (rb + 1) + 1 ..][0..rb];
            const y = p[1] + py * p[3];
            convertRow(h, row, pw, &pal, trns, img.pixels[y * h.width + p[0] ..], p[2]);
        }
    }
    return img;
}

pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) !canvas.Image {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 256 << 20);
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

test "round trip through the encoder" {
    const a = std.testing.allocator;
    const png = @import("png.zig");
    var img = try canvas.Image.init(a, 7, 5);
    defer img.deinit(a);
    for (img.pixels, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i * 0x030507));
    img.pixels[3] = 0x80400000; // premultiplied half-transparent red
    const bytes = try png.encodeAlloc(a, img.canvas());
    defer a.free(bytes);
    var back = try decode(a, bytes);
    defer back.deinit(a);
    try std.testing.expectEqual(@as(u32, 7), back.width);
    for (img.pixels, back.pixels, 0..) |want, got, i| {
        if (i == 3) {
            // Straight alpha in the file: allow rounding.
            try std.testing.expectEqual(want >> 24, got >> 24);
            try std.testing.expect(@abs(@as(i32, @intCast((want >> 16) & 0xFF)) - @as(i32, @intCast((got >> 16) & 0xFF))) <= 1);
        } else try std.testing.expectEqual(want, got);
    }
}

test "palette, grey and interlaced images" {
    const a = std.testing.allocator;
    // 2x2 palette image, 1 bit per pixel, built by hand.
    const Enc = struct {
        fn chunk(list: *std.ArrayList(u8), al: std.mem.Allocator, kind: []const u8, body: []const u8) !void {
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, @intCast(body.len), .big);
            try list.appendSlice(al, &lb);
            try list.appendSlice(al, kind);
            try list.appendSlice(al, body);
            try list.appendSlice(al, &.{ 0, 0, 0, 0 }); // CRC (not checked)
        }
        fn zlibStored(al: std.mem.Allocator, raw: []const u8) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(al, &.{ 0x78, 0x01, 0x01 });
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u16, lb[0..2], @intCast(raw.len), .little);
            std.mem.writeInt(u16, lb[2..4], ~@as(u16, @intCast(raw.len)), .little);
            try out.appendSlice(al, &lb);
            try out.appendSlice(al, raw);
            var cb: [4]u8 = undefined;
            std.mem.writeInt(u32, &cb, std.hash.Adler32.hash(raw), .big);
            try out.appendSlice(al, &cb);
            return out.toOwnedSlice(al);
        }
        fn png(al: std.mem.Allocator, w: u32, h: u32, depth: u8, color: u8, interlace: u8, plte: ?[]const u8, raw: []const u8) ![]u8 {
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(al, "\x89PNG\r\n\x1a\n");
            var ih: [13]u8 = undefined;
            std.mem.writeInt(u32, ih[0..4], w, .big);
            std.mem.writeInt(u32, ih[4..8], h, .big);
            ih[8] = depth;
            ih[9] = color;
            ih[10] = 0;
            ih[11] = 0;
            ih[12] = interlace;
            try chunk(&list, al, "IHDR", &ih);
            if (plte) |p| try chunk(&list, al, "PLTE", p);
            const z = try zlibStored(al, raw);
            defer al.free(z);
            try chunk(&list, al, "IDAT", z);
            try chunk(&list, al, "IEND", "");
            return list.toOwnedSlice(al);
        }
    };
    // Palette: 0 = red, 1 = blue. Rows: "01", "10" (1 bit, filter 0).
    const p1 = try Enc.png(a, 2, 2, 1, 3, 0, &.{ 255, 0, 0, 0, 0, 255 }, &.{ 0, 0b01000000, 0, 0b10000000 });
    defer a.free(p1);
    var img1 = try decode(a, p1);
    defer img1.deinit(a);
    try std.testing.expectEqualSlices(u32, &.{ 0xFFFF0000, 0xFF0000FF, 0xFF0000FF, 0xFFFF0000 }, img1.pixels);

    // 16-bit grey, 1x2, "Up" filter on the second row.
    const p2 = try Enc.png(a, 1, 2, 16, 0, 0, null, &.{ 0, 0x80, 0x00, 2, 0x10, 0x00 });
    defer a.free(p2);
    var img2 = try decode(a, p2);
    defer img2.deinit(a);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF808080, 0xFF909090 }, img2.pixels);

    // Interlaced 3x3 8-bit grey: each pass holds its pixels in order.
    // Pass 1: (0,0); pass 4: (2,0); pass 5: (0,2),(2,2); pass 6: (1,0),(1,2);
    // pass 7: row 1 (3 pixels). Value = 10*y + x.
    const raw = [_]u8{
        0, 0, // pass 1: 1x1
        0, 2, // pass 4: 1x1 at x=2
        0, 20, 22, // pass 5: 2x1 at y=2
        0, 1, 0, 21, // pass 6: 1x2 at x=1 (rows y=0, y=2)
        0, 10, 11, 12, // pass 7: 3x1 at y=1
    };
    const p3 = try Enc.png(a, 3, 3, 8, 0, 1, null, &raw);
    defer a.free(p3);
    var img3 = try decode(a, p3);
    defer img3.deinit(a);
    for (0..3) |y| for (0..3) |x| {
        const v: u32 = @intCast(10 * y + x);
        try std.testing.expectEqual(0xFF000000 | v << 16 | v << 8 | v, img3.pixels[y * 3 + x]);
    };
    try std.testing.expectError(error.NotPng, decode(a, "GIF89a"));
}
