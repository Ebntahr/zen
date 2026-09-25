//! A small, fast raw-DEFLATE compressor (RFC 1951) for screen updates.
//!
//! LZ77 with a hash chain over 4-byte sequences and fixed Huffman codes.
//! Screen content (flat colours, repeated pixels, rows that match the row
//! above) turns into long matches, so fixed codes are good enough and keep
//! the encoder simple. Zig 0.15's std only offers Huffman-only compression.
//! Output is a single final block that any inflater (e.g. a browser's
//! DecompressionStream("deflate-raw")) can decode.

const std = @import("std");

const window = 32768;
const hash_bits = 15;
const min_match = 4;
const max_match = 258;
/// How many earlier positions to try per match (speed/ratio trade-off).
const max_chain = 16;

pub const Compressor = struct {
    head: []i32,
    prev: []i32,

    pub fn init(allocator: std.mem.Allocator) !Compressor {
        const head = try allocator.alloc(i32, 1 << hash_bits);
        errdefer allocator.free(head);
        const prev = try allocator.alloc(i32, window);
        return .{ .head = head, .prev = prev };
    }

    pub fn deinit(c: *Compressor, allocator: std.mem.Allocator) void {
        allocator.free(c.head);
        allocator.free(c.prev);
    }

    /// Compress `input` into `out` (appended). Stateless between calls.
    pub fn compress(c: *Compressor, allocator: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
        @memset(c.head, -1);
        var bw = BitWriter{ .out = out, .allocator = allocator };
        try out.ensureUnusedCapacity(allocator, input.len / 4 + 64);
        try bw.bits(1, 1); // BFINAL
        try bw.bits(1, 2); // BTYPE = 01, fixed Huffman
        var i: usize = 0;
        while (i < input.len) {
            var best_len: usize = 0;
            var best_dist: usize = 0;
            if (i + min_match <= input.len) {
                const h = hash(input[i..][0..4]);
                var cand = c.head[h];
                var chain: usize = 0;
                const limit = @min(max_match, input.len - i);
                while (cand >= 0 and chain < max_chain) : (chain += 1) {
                    const p: usize = @intCast(cand);
                    const dist = i - p;
                    if (dist > window) break;
                    if (input[p + best_len] == input[i + best_len]) {
                        var l: usize = 0;
                        while (l < limit and input[p + l] == input[i + l]) l += 1;
                        if (l > best_len) {
                            best_len = l;
                            best_dist = dist;
                            if (l == limit) break;
                        }
                    }
                    cand = c.prev[p % window];
                }
                c.prev[i % window] = c.head[h];
                c.head[h] = @intCast(i);
            }
            if (best_len >= min_match) {
                try bw.match(best_len, best_dist);
                // Index the positions inside the match (sparsely for long
                // runs, which are cheap to find again anyway).
                const end = i + best_len;
                var j = i + 1;
                const step: usize = if (best_len > 32) 4 else 1;
                while (j < end and j + min_match <= input.len) : (j += step) {
                    const hj = hash(input[j..][0..4]);
                    c.prev[j % window] = c.head[hj];
                    c.head[hj] = @intCast(j);
                }
                i = end;
            } else {
                try bw.literal(input[i]);
                i += 1;
            }
        }
        try bw.code(256); // end of block
        try bw.flushByte();
    }

    fn hash(b: *const [4]u8) usize {
        const v = std.mem.readInt(u32, b, .little);
        return (v *% 0x9E3779B1) >> (32 - hash_bits);
    }
};

const BitWriter = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    acc: u64 = 0,
    n: u6 = 0,

    fn bits(w: *BitWriter, value: u32, count: u6) !void {
        w.acc |= @as(u64, value) << w.n;
        w.n += count;
        while (w.n >= 8) {
            try w.out.append(w.allocator, @truncate(w.acc));
            w.acc >>= 8;
            w.n -= 8;
        }
    }

    /// Huffman codes are sent most-significant bit first.
    fn huff(w: *BitWriter, code_value: u32, len: u6) !void {
        var rev: u32 = 0;
        var v = code_value;
        for (0..len) |_| {
            rev = (rev << 1) | (v & 1);
            v >>= 1;
        }
        try w.bits(rev, len);
    }

    /// A fixed-code literal/length symbol.
    fn code(w: *BitWriter, sym: u32) !void {
        if (sym < 144) return w.huff(0x30 + sym, 8);
        if (sym < 256) return w.huff(0x190 + (sym - 144), 9);
        if (sym < 280) return w.huff(sym - 256, 7);
        return w.huff(0xC0 + (sym - 280), 8);
    }

    fn literal(w: *BitWriter, b: u8) !void {
        try w.code(b);
    }

    const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const len_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    const dist_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

    fn match(w: *BitWriter, length: usize, dist: usize) !void {
        var li: usize = len_base.len - 1;
        while (len_base[li] > length) li -= 1;
        try w.code(@intCast(257 + li));
        if (len_extra[li] > 0) try w.bits(@intCast(length - len_base[li]), len_extra[li]);
        var di: usize = dist_base.len - 1;
        while (dist_base[di] > dist) di -= 1;
        try w.huff(@intCast(di), 5);
        if (dist_extra[di] > 0) try w.bits(@intCast(dist - dist_base[di]), dist_extra[di]);
    }

    fn flushByte(w: *BitWriter) !void {
        if (w.n > 0) {
            try w.out.append(w.allocator, @truncate(w.acc));
            w.acc = 0;
            w.n = 0;
        }
    }
};

fn roundTrip(input: []const u8) !usize {
    const a = std.testing.allocator;
    var c = try Compressor.init(a);
    defer c.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try c.compress(a, input, &out);
    var in: std.Io.Reader = .fixed(out.items);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var inflate: std.compress.flate.Decompress = .init(&in, .raw, &.{});
    _ = try inflate.reader.streamRemaining(&aw.writer);
    try std.testing.expectEqualSlices(u8, input, aw.written());
    return out.items.len;
}

test "round trips through std's inflater" {
    _ = try roundTrip("");
    _ = try roundTrip("a");
    _ = try roundTrip("hello hello hello hello, deflate!");
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var random: [5000]u8 = undefined;
    r.bytes(&random);
    _ = try roundTrip(&random);
    // Screen-like data: a 300x200 RGBX image with flat areas and a gradient.
    const a = std.testing.allocator;
    const px = try a.alloc(u8, 300 * 200 * 4);
    defer a.free(px);
    for (0..200) |y| for (0..300) |x| {
        const o = (y * 300 + x) * 4;
        const flat = x < 150;
        // Flat window background on the left, a vertical gradient (like
        // the wallpaper) on the right.
        px[o] = if (flat) 0xF5 else @intCast(y % 256);
        px[o + 1] = if (flat) 0xF5 else @intCast((y * 3) % 256);
        px[o + 2] = if (flat) 0xF7 else 0x80;
        px[o + 3] = 0xFF;
    };
    const n = try roundTrip(px);
    try std.testing.expect(n < px.len / 4);
    // Long runs longer than the window and matches at the maximum length.
    const run = try a.alloc(u8, 100_000);
    defer a.free(run);
    @memset(run, 7);
    try std.testing.expect(try roundTrip(run) < 1000);
}
