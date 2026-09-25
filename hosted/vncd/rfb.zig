//! RFB (VNC) protocol pieces used by vncd: pixel formats, key mapping,
//! cursor encoding and WebSocket framing. No I/O here, so it is unit-tested.

const std = @import("std");

/// RFB pixel format (16 bytes on the wire).
pub const PixelFormat = struct {
    bpp: u8 = 32,
    depth: u8 = 24,
    big_endian: bool = false,
    true_color: bool = true,
    red_max: u16 = 255,
    green_max: u16 = 255,
    blue_max: u16 = 255,
    red_shift: u8 = 16,
    green_shift: u8 = 8,
    blue_shift: u8 = 0,

    /// The framebuffer's own layout (0xAARRGGBB little-endian).
    pub const native = PixelFormat{};

    pub fn encode(pf: PixelFormat, out: *[16]u8) void {
        out.* = [_]u8{0} ** 16;
        out[0] = pf.bpp;
        out[1] = pf.depth;
        out[2] = @intFromBool(pf.big_endian);
        out[3] = @intFromBool(pf.true_color);
        std.mem.writeInt(u16, out[4..6], pf.red_max, .big);
        std.mem.writeInt(u16, out[6..8], pf.green_max, .big);
        std.mem.writeInt(u16, out[8..10], pf.blue_max, .big);
        out[10] = pf.red_shift;
        out[11] = pf.green_shift;
        out[12] = pf.blue_shift;
    }

    pub fn decode(b: []const u8) PixelFormat {
        return .{
            .bpp = b[0],
            .depth = b[1],
            .big_endian = b[2] != 0,
            .true_color = b[3] != 0,
            .red_max = std.mem.readInt(u16, b[4..6], .big),
            .green_max = std.mem.readInt(u16, b[6..8], .big),
            .blue_max = std.mem.readInt(u16, b[8..10], .big),
            .red_shift = b[10],
            .green_shift = b[11],
            .blue_shift = b[12],
        };
    }

    pub fn bytesPerPixel(pf: PixelFormat) usize {
        return switch (pf.bpp) {
            8 => 1,
            16 => 2,
            else => 4,
        };
    }

    /// Supported: true colour with 8, 16 or 32 bits per pixel.
    pub fn valid(pf: PixelFormat) bool {
        return pf.true_color and (pf.bpp == 8 or pf.bpp == 16 or pf.bpp == 32) and
            pf.red_shift < 32 and pf.green_shift < 32 and pf.blue_shift < 32;
    }

    fn isNative32(pf: PixelFormat) bool {
        return pf.bpp == 32 and !pf.big_endian and pf.red_max == 255 and pf.green_max == 255 and pf.blue_max == 255 and
            pf.red_shift == 16 and pf.green_shift == 8 and pf.blue_shift == 0;
    }

    fn isRgbx32(pf: PixelFormat) bool {
        return pf.bpp == 32 and !pf.big_endian and pf.red_max == 255 and pf.green_max == 255 and pf.blue_max == 255 and
            pf.red_shift == 0 and pf.green_shift == 8 and pf.blue_shift == 16;
    }

    /// Convert one 0xAARRGGBB pixel. Unused bits of 32-bit formats are set,
    /// so RGBX clients (browsers) can use the result as opaque RGBA.
    pub fn pixel(pf: PixelFormat, argb: u32) u32 {
        const r = (argb >> 16) & 0xFF;
        const g = (argb >> 8) & 0xFF;
        const b = argb & 0xFF;
        const rv = (r * pf.red_max + 127) / 255;
        const gv = (g * pf.green_max + 127) / 255;
        const bv = (b * pf.blue_max + 127) / 255;
        var v: u32 = (@as(u32, @intCast(rv)) << @intCast(pf.red_shift)) |
            (@as(u32, @intCast(gv)) << @intCast(pf.green_shift)) |
            (@as(u32, @intCast(bv)) << @intCast(pf.blue_shift));
        if (pf.bpp == 32) {
            const used = (@as(u32, pf.red_max) << @intCast(pf.red_shift)) | (@as(u32, pf.green_max) << @intCast(pf.green_shift)) | (@as(u32, pf.blue_max) << @intCast(pf.blue_shift));
            v |= ~used;
        }
        return v;
    }

    /// Convert a row of framebuffer pixels into `out` (len * bytesPerPixel).
    pub fn convertRow(pf: PixelFormat, src: []const u32, out: []u8) void {
        if (pf.isNative32()) {
            for (src, 0..) |p, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], p | 0xFF000000, .little);
            return;
        }
        if (pf.isRgbx32()) {
            for (src, 0..) |p, i| {
                out[i * 4 + 0] = @truncate(p >> 16);
                out[i * 4 + 1] = @truncate(p >> 8);
                out[i * 4 + 2] = @truncate(p);
                out[i * 4 + 3] = 0xFF;
            }
            return;
        }
        const endian: std.builtin.Endian = if (pf.big_endian) .big else .little;
        switch (pf.bytesPerPixel()) {
            1 => for (src, 0..) |p, i| {
                out[i] = @truncate(pf.pixel(p));
            },
            2 => for (src, 0..) |p, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], @truncate(pf.pixel(p)), endian),
            else => for (src, 0..) |p, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], pf.pixel(p), endian),
        }
    }
};

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// evdev codes for US-layout keysyms (letters, digits, punctuation, and
/// the X11 function keysyms). 0 = unknown.
pub fn keysymToEvdev(ks: u32) u16 {
    const letters = [26]u16{ 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44 };
    if (ks >= 'a' and ks <= 'z') return letters[ks - 'a'];
    if (ks >= 'A' and ks <= 'Z') return letters[ks - 'A'];
    if (ks >= '1' and ks <= '9') return @intCast(ks - '1' + 2);
    return switch (ks) {
        '0', ')' => 11,
        '!' => 2,
        '@' => 3,
        '#' => 4,
        '$' => 5,
        '%' => 6,
        '^' => 7,
        '&' => 8,
        '*' => 9,
        '(' => 10,
        '-', '_' => 12,
        '=', '+' => 13,
        '[', '{' => 26,
        ']', '}' => 27,
        ';', ':' => 39,
        '\'', '"' => 40,
        '`', '~' => 41,
        '\\', '|' => 43,
        ',', '<' => 51,
        '.', '>' => 52,
        '/', '?' => 53,
        ' ' => 57,
        0xff08 => 14, // BackSpace
        0xff09 => 15, // Tab
        0xff0d => 28, // Return
        0xff1b => 1, // Escape
        0xffff => 111, // Delete
        0xff50 => 102, // Home
        0xff51 => 105, // Left
        0xff52 => 103, // Up
        0xff53 => 106, // Right
        0xff54 => 108, // Down
        0xff55 => 104, // Page_Up
        0xff56 => 109, // Page_Down
        0xff57 => 107, // End
        0xff63 => 110, // Insert
        0xff8d => 96, // KP_Enter
        0xffbe...0xffc7 => @intCast(59 + (ks - 0xffbe)), // F1..F10
        0xffc8 => 87, // F11
        0xffc9 => 88, // F12
        0xffe1 => 42, // Shift_L
        0xffe2 => 54, // Shift_R
        0xffe3 => 29, // Control_L
        0xffe4 => 97, // Control_R
        0xffe5 => 58, // Caps_Lock
        0xffe7, 0xffeb => 125, // Meta_L, Super_L → Command
        0xffe8, 0xffec => 126, // Meta_R, Super_R
        0xffe9 => 56, // Alt_L
        0xffea, 0xfe03 => 100, // Alt_R, ISO_Level3_Shift
        else => 0,
    };
}

/// QEMU "qnum" key numbers (XT set 1; extended keys are 0x80 | code)
/// to evdev codes. These are physical keys, so Zen's own layouts (US,
/// Arabic) apply exactly as with real hardware.
pub fn qnumToEvdev(q: u32) u16 {
    if (q > 0 and q < 0x80) return @intCast(q);
    return switch (q) {
        0x9c => 96, // KP Enter
        0x9d => 97, // Right Ctrl
        0xb5 => 98, // KP /
        0xb7 => 99, // Print
        0xb8 => 100, // Right Alt
        0xc7 => 102, // Home
        0xc8 => 103, // Up
        0xc9 => 104, // Page Up
        0xcb => 105, // Left
        0xcd => 106, // Right
        0xcf => 107, // End
        0xd0 => 108, // Down
        0xd1 => 109, // Page Down
        0xd2 => 110, // Insert
        0xd3 => 111, // Delete
        0xdb => 125, // Left Meta (Command)
        0xdc => 126, // Right Meta
        0xdd => 127, // Menu
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Cursor pseudo-encoding (-239)
// ---------------------------------------------------------------------------

/// Encode a straight-alpha 0xAARRGGBB cursor: pixels in `pf` followed by a
/// 1-bit mask (alpha >= 128), rows padded to whole bytes.
pub fn encodeCursor(pf: PixelFormat, img: []const u32, w: usize, h: usize, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const bpp = pf.bytesPerPixel();
    const start = out.items.len;
    try out.resize(allocator, start + w * h * bpp);
    for (0..h) |y| pf.convertRow(img[y * w ..][0..w], out.items[start + y * w * bpp ..][0 .. w * bpp]);
    const row_bytes = (w + 7) / 8;
    for (0..h) |y| {
        for (0..row_bytes) |bx| {
            var byte: u8 = 0;
            for (0..8) |bit| {
                const x = bx * 8 + bit;
                if (x < w and (img[y * w + x] >> 24) >= 128) byte |= @as(u8, 0x80) >> @intCast(bit);
            }
            try out.append(allocator, byte);
        }
    }
}

// ---------------------------------------------------------------------------
// WebSocket (RFC 6455), server side
// ---------------------------------------------------------------------------

/// Sec-WebSocket-Accept for a client key.
pub fn wsAccept(key: []const u8, out: *[28]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Header of an unmasked binary frame carrying `len` bytes.
pub fn wsFrameHeader(len: usize, out: *[10]u8) []const u8 {
    out[0] = 0x82;
    if (len < 126) {
        out[1] = @intCast(len);
        return out[0..2];
    }
    if (len <= 0xFFFF) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        return out[0..4];
    }
    out[1] = 127;
    std.mem.writeInt(u64, out[2..10], len, .big);
    return out[0..10];
}

pub const WsEvent = enum { none, close, ping };

/// Incremental decoder for masked client frames. Data payloads (text,
/// binary, continuation) are appended to `data`; control frames are
/// reported. `consumed` bytes of the input were used.
pub const WsDecoder = struct {
    pub const Result = struct { consumed: usize, event: WsEvent = .none, ping_payload: [125]u8 = undefined, ping_len: usize = 0 };

    pub fn decode(input: []const u8, data: *std.ArrayList(u8), allocator: std.mem.Allocator) !Result {
        var pos: usize = 0;
        while (true) {
            const rest = input[pos..];
            if (rest.len < 2) return .{ .consumed = pos };
            const opcode = rest[0] & 0x0F;
            const masked = rest[1] & 0x80 != 0;
            var len: u64 = rest[1] & 0x7F;
            var hdr: usize = 2;
            if (len == 126) {
                if (rest.len < 4) return .{ .consumed = pos };
                len = std.mem.readInt(u16, rest[2..4], .big);
                hdr = 4;
            } else if (len == 127) {
                if (rest.len < 10) return .{ .consumed = pos };
                len = std.mem.readInt(u64, rest[2..10], .big);
                hdr = 10;
            }
            if (len > 16 << 20) return error.FrameTooLarge;
            const mask_len: usize = if (masked) 4 else 0;
            const total = hdr + mask_len + @as(usize, @intCast(len));
            if (rest.len < total) return .{ .consumed = pos };
            const mask = rest[hdr .. hdr + mask_len];
            const payload = rest[hdr + mask_len .. total];
            pos += total;
            switch (opcode) {
                0x0, 0x1, 0x2 => {
                    const start = data.items.len;
                    try data.appendSlice(allocator, payload);
                    if (masked) for (data.items[start..], 0..) |*b, i| {
                        b.* ^= mask[i % 4];
                    };
                },
                0x8 => return .{ .consumed = pos, .event = .close },
                0x9 => {
                    var r = Result{ .consumed = pos, .event = .ping };
                    r.ping_len = @min(payload.len, r.ping_payload.len);
                    for (payload[0..r.ping_len], 0..) |b, i| r.ping_payload[i] = if (masked) b ^ mask[i % 4] else b;
                    return r;
                },
                else => {}, // pong and reserved opcodes are ignored
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pixel conversion" {
    const px = [_]u32{ 0xFF112233, 0x80AABBCC };
    var out: [8]u8 = undefined;
    PixelFormat.native.convertRow(&px, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x22, 0x11, 0xFF, 0xCC, 0xBB, 0xAA, 0xFF }, &out);
    const rgbx = PixelFormat{ .red_shift = 0, .green_shift = 8, .blue_shift = 16 };
    rgbx.convertRow(&px, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0xFF, 0xAA, 0xBB, 0xCC, 0xFF }, &out);
    const rgb565 = PixelFormat{ .bpp = 16, .depth = 16, .red_max = 31, .green_max = 63, .blue_max = 31, .red_shift = 11, .green_shift = 5, .blue_shift = 0 };
    var o16: [2]u8 = undefined;
    rgb565.convertRow(&.{0xFFFFFFFF}, &o16);
    try std.testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, &o16, .little));
    var enc: [16]u8 = undefined;
    rgb565.encode(&enc);
    const back = PixelFormat.decode(&enc);
    try std.testing.expectEqual(rgb565.green_max, back.green_max);
    try std.testing.expectEqual(rgb565.red_shift, back.red_shift);
}

test "key mapping" {
    try std.testing.expectEqual(@as(u16, 30), keysymToEvdev('a'));
    try std.testing.expectEqual(@as(u16, 30), keysymToEvdev('A'));
    try std.testing.expectEqual(@as(u16, 2), keysymToEvdev('!'));
    try std.testing.expectEqual(@as(u16, 28), keysymToEvdev(0xff0d));
    try std.testing.expectEqual(@as(u16, 125), keysymToEvdev(0xffeb));
    try std.testing.expectEqual(@as(u16, 68), keysymToEvdev(0xffc7));
    try std.testing.expectEqual(@as(u16, 30), qnumToEvdev(0x1e));
    try std.testing.expectEqual(@as(u16, 103), qnumToEvdev(0xc8));
    try std.testing.expectEqual(@as(u16, 0), qnumToEvdev(0xff));
}

test "cursor mask" {
    var img = [_]u32{0} ** (9 * 2);
    img[0] = 0xFF000000;
    img[8] = 0xFFFFFFFF;
    img[9 + 1] = 0x7F000000; // below the alpha threshold
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try encodeCursor(PixelFormat.native, &img, 9, 2, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 9 * 2 * 4 + 2 * 2), out.items.len);
    const mask = out.items[9 * 2 * 4 ..];
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x00, 0x00 }, mask);
}

test "websocket accept and frames" {
    var buf: [28]u8 = undefined;
    // RFC 6455 section 1.3 example.
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", wsAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf));
    var hb: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), wsFrameHeader(5, &hb).len);
    try std.testing.expectEqual(@as(usize, 4), wsFrameHeader(300, &hb).len);
    try std.testing.expectEqual(@as(usize, 10), wsFrameHeader(70000, &hb).len);

    // A masked binary frame "Hi" split across two reads.
    const frame = [_]u8{ 0x82, 0x82, 1, 2, 3, 4, 'H' ^ 1, 'i' ^ 2 };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const r1 = try WsDecoder.decode(frame[0..5], &data, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), r1.consumed);
    const r2 = try WsDecoder.decode(&frame, &data, std.testing.allocator);
    try std.testing.expectEqual(frame.len, r2.consumed);
    try std.testing.expectEqualStrings("Hi", data.items);
    const close = [_]u8{ 0x88, 0x80, 0, 0, 0, 0 };
    const r3 = try WsDecoder.decode(&close, &data, std.testing.allocator);
    try std.testing.expectEqual(WsEvent.close, r3.event);
}
