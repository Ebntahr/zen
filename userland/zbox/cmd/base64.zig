const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: base64 [OPTION]... [FILE]
    \\Base64 encode or decode FILE, or standard input, to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -d, --decode          decode data
    \\  -i, --ignore-garbage  when decoding, ignore non-alphabet characters
    \\  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).
    \\                          Use 0 to disable line wrapping
    \\
;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn main(args: c.Args) !u8 {
    var decode = false;
    var ignore = false;
    var wrap: usize = 76;
    var file: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{ .{ "decode", 'd' }, .{ "ignore-garbage", 'i' }, .{ "wrap", 'w' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'd', 'D' => decode = true,
            'i' => ignore = true,
            'w' => {
                const a = p.arg();
                wrap = @intCast(c.parseUint(a) orelse c.fatal("invalid wrap size: {f}", .{c.q(a)}));
            },
            else => p.bad(o),
        },
        .pos => |a| {
            if (file != null) c.usageErr("extra operand {f}", .{c.q(a)});
            file = a;
        },
        else => p.bad(o),
    };
    const data = c.readInput(file orelse "-") orelse return 1;
    const w = c.out;
    if (!decode) {
        var col: usize = 0;
        var i: usize = 0;
        while (i < data.len) : (i += 3) {
            const n = @min(3, data.len - i);
            const b0: u32 = data[i];
            const b1: u32 = if (n > 1) data[i + 1] else 0;
            const b2: u32 = if (n > 2) data[i + 2] else 0;
            const v = (b0 << 16) | (b1 << 8) | b2;
            var q: [4]u8 = .{ alphabet[(v >> 18) & 63], alphabet[(v >> 12) & 63], alphabet[(v >> 6) & 63], alphabet[v & 63] };
            if (n < 3) q[3] = '=';
            if (n < 2) q[2] = '=';
            for (q) |ch| {
                if (wrap > 0 and col == wrap) {
                    try w.writeByte('\n');
                    col = 0;
                }
                try w.writeByte(ch);
                col += 1;
            }
        }
        if (col > 0 and wrap > 0) try w.writeByte('\n');
        return 0;
    }
    var val: u32 = 0;
    var nbits: u5 = 0;
    var pad = false;
    for (data) |ch| {
        if (ch == '\n' or ch == '\r') continue;
        if (ch == '=') {
            pad = true;
            continue;
        }
        const d: ?u32 = if (std.mem.indexOfScalar(u8, alphabet, ch)) |k| @intCast(k) else null;
        if (d == null or pad) {
            if (ignore and d == null) continue;
            c.flush();
            c.fatal("invalid input", .{});
        }
        val = (val << 6) | d.?;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            try w.writeByte(@truncate(val >> nbits));
            val &= (@as(u32, 1) << nbits) - 1;
        }
    }
    return 0;
}
