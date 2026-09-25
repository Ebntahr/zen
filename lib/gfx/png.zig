//! Minimal streaming PNG encoder: 8-bit RGBA, zlib with stored (uncompressed)
//! deflate blocks. Pixels are un-premultiplied on the fly. Intended for
//! screenshots and host-side previews; no allocation is needed.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const Color = @import("color.zig").Color;

const Canvas = canvas_mod.Canvas;
const Writer = std.Io.Writer;
const Crc32 = std.hash.Crc32;
const Adler32 = std.hash.Adler32;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
const max_stored_block = 65535;

fn writeChunk(w: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    var crc = Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Writes the IDAT payload: a zlib stream of stored blocks, CRC'd as it goes.
const IdatStream = struct {
    out: *Writer,
    crc: Crc32,
    adler: Adler32 = .{},
    block_left: usize = 0,
    total_left: usize,

    fn emit(s: *IdatStream, bytes: []const u8) Writer.Error!void {
        s.crc.update(bytes);
        try s.out.writeAll(bytes);
    }

    /// Appends uncompressed bytes, starting new stored blocks as needed.
    fn write(s: *IdatStream, bytes: []const u8) Writer.Error!void {
        var b = bytes;
        while (b.len > 0) {
            if (s.block_left == 0) {
                const len: u16 = @intCast(@min(s.total_left, max_stored_block));
                const final: u8 = @intFromBool(len == s.total_left);
                const n = ~len;
                try s.emit(&.{ final, @truncate(len), @truncate(len >> 8), @truncate(n), @truncate(n >> 8) });
                s.block_left = len;
            }
            const n = @min(b.len, s.block_left);
            s.adler.update(b[0..n]);
            try s.emit(b[0..n]);
            b = b[n..];
            s.block_left -= n;
            s.total_left -= n;
        }
    }
};

/// Encodes the full bounds of `c` as a PNG image to `w`.
pub fn encode(w: *Writer, c: Canvas) Writer.Error!void {
    const width: u32 = @intCast(c.width);
    const height: u32 = @intCast(c.height);
    try w.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(w, "IHDR", &ihdr);

    const raw_len: usize = @as(usize, height) * (1 + 4 * @as(usize, width));
    const blocks = @max(1, (raw_len + max_stored_block - 1) / max_stored_block);
    const zlib_len = 2 + raw_len + 5 * blocks + 4;
    try w.writeInt(u32, @intCast(zlib_len), .big);
    var s = IdatStream{ .out = w, .crc = Crc32.init(), .total_left = raw_len };
    s.crc.update("IDAT");
    try w.writeAll("IDAT");
    try s.emit(&.{ 0x78, 0x01 }); // zlib header: deflate, 32K window, no preset dict

    var buf: [4096]u8 = undefined;
    for (0..height) |y| {
        try s.write(&.{0}); // filter: none
        const row = c.row(@intCast(y));
        var x: usize = 0;
        while (x < width) {
            const n: usize = @min(width - x, buf.len / 4);
            for (0..n) |i| {
                const p = Color.toStraight(row[x + i]);
                buf[i * 4 + 0] = @truncate(p >> 16);
                buf[i * 4 + 1] = @truncate(p >> 8);
                buf[i * 4 + 2] = @truncate(p);
                buf[i * 4 + 3] = @truncate(p >> 24);
            }
            try s.write(buf[0 .. n * 4]);
            x += n;
        }
    }
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, s.adler.adler, .big);
    try s.emit(&adler_be);
    try w.writeInt(u32, s.crc.final(), .big);

    try writeChunk(w, "IEND", &.{});
}

/// Encodes `c` into a newly allocated buffer.
pub fn encodeAlloc(allocator: std.mem.Allocator, c: Canvas) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    try encode(&aw.writer, c);
    return aw.toOwnedSlice();
}

/// Writes `c` as a PNG file at `path` (relative to the current directory).
pub fn writeFile(c: Canvas, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    try encode(&fw.interface, c);
    try fw.interface.flush();
}

test "png structure, CRCs and stored zlib payload" {
    const a = std.testing.allocator;
    var px = [_]u32{ Color.rgb(255, 0, 0), Color.rgba(0, 0, 255, 128) };
    const c = Canvas.init(&px, 2, 1, 2);
    const bytes = try encodeAlloc(a, c);
    defer a.free(bytes);

    try std.testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    // IHDR
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, bytes[8..12], .big));
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    const ihdr_crc = std.mem.readInt(u32, bytes[29..33], .big);
    try std.testing.expectEqual(Crc32.hash(bytes[12..29]), ihdr_crc);
    // IDAT
    const idat_len = std.mem.readInt(u32, bytes[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", bytes[37..41]);
    const idat = bytes[41..][0..idat_len];
    const idat_crc = std.mem.readInt(u32, bytes[41 + idat_len ..][0..4], .big);
    try std.testing.expectEqual(Crc32.hash(bytes[37 .. 41 + idat_len]), idat_crc);
    // zlib header, one final stored block of 9 bytes, then Adler-32.
    try std.testing.expectEqual(@as(u8, 0x78), idat[0]);
    try std.testing.expectEqual(@as(u16, 0), (@as(u16, idat[0]) << 8 | idat[1]) % 31);
    try std.testing.expectEqual(@as(u8, 1), idat[2]);
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, idat[3..5], .little));
    try std.testing.expectEqual(@as(u16, 0xFFFF - 9), std.mem.readInt(u16, idat[5..7], .little));
    const raw = idat[7..16];
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 0, 255, 128 }, raw);
    try std.testing.expectEqual(Adler32.hash(raw), std.mem.readInt(u32, idat[16..20], .big));
    // IEND with its well-known CRC.
    const iend = bytes[41 + idat_len + 4 ..];
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82 }, iend);
}

test "png of a 1x1 RGBA image has the canonical IHDR CRC" {
    var px = [_]u32{0};
    const c = Canvas.init(&px, 1, 1, 1);
    var buf: [128]u8 = undefined;
    var w = Writer.fixed(&buf);
    try encode(&w, c);
    try std.testing.expectEqual(@as(u32, 0x1F15C489), std.mem.readInt(u32, buf[29..33], .big));
}

test "png splits large images into multiple stored blocks" {
    const a = std.testing.allocator;
    var img = try canvas_mod.Image.init(a, 200, 100);
    defer img.deinit(a);
    const bytes = try encodeAlloc(a, img.canvas());
    defer a.free(bytes);
    const raw_len = 100 * (1 + 800);
    const blocks = (raw_len + 65534) / 65535;
    try std.testing.expectEqual(@as(u32, @intCast(2 + raw_len + 5 * blocks + 4)), std.mem.readInt(u32, bytes[33..37], .big));
}
