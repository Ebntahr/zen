const std = @import("std");
const c = @import("../common.zig");
const pf = @import("printf.zig");
const mem = std.mem;

pub const help =
    \\Usage: od [OPTION]... [FILE]...
    \\Write an unambiguous representation, octal bytes by default,
    \\of FILE to standard output.
    \\
    \\  -A, --address-radix=RADIX   output format for file offsets; RADIX is one
    \\                                of [doxn], for Decimal, Octal, Hex or None
    \\  -j, --skip-bytes=BYTES      skip BYTES input bytes first
    \\  -N, --read-bytes=BYTES      limit dump to BYTES input bytes
    \\  -t, --format=TYPE           select output format or formats
    \\  -v, --output-duplicates     do not use * to mark line suppression
    \\  -w[BYTES], --width[=BYTES]  output BYTES bytes per output line (default 16)
    \\
    \\Traditional format specifications:
    \\  -a  same as -t a     -b  same as -t o1    -c  same as -t c
    \\  -d  same as -t u2    -f  same as -t fF    -i  same as -t dI
    \\  -l  same as -t dL    -o  same as -t o2    -s  same as -t d2
    \\  -x  same as -t x2
    \\
    \\TYPE is made up of one or more of these specifications:
    \\  a  named character     c  printable character or backslash escape
    \\  d[SIZE]  signed decimal     f[SIZE]  floating point
    \\  o[SIZE]  octal              u[SIZE]  unsigned decimal
    \\  x[SIZE]  hexadecimal        (SIZE is 1, 2, 4 or 8; append z for ASCII)
    \\
;

const Type = struct { kind: u8, size: usize, z: bool };

fn parseType(s: []const u8, list: *std.ArrayList(Type)) void {
    var i: usize = 0;
    while (i < s.len) {
        const k = s[i];
        i += 1;
        var t: Type = .{ .kind = k, .size = 1, .z = false };
        switch (k) {
            'a', 'c' => {},
            'd', 'o', 'u', 'x', 'f' => {
                t.size = if (k == 'f') 8 else 4;
                if (i < s.len) {
                    switch (s[i]) {
                        'C' => {
                            t.size = 1;
                            i += 1;
                        },
                        'S' => {
                            t.size = 2;
                            i += 1;
                        },
                        'I' => {
                            t.size = 4;
                            i += 1;
                        },
                        'L' => {
                            t.size = 8;
                            i += 1;
                        },
                        'F' => {
                            t.size = 4;
                            i += 1;
                        },
                        'D' => {
                            t.size = 8;
                            i += 1;
                        },
                        '0'...'9' => {
                            var n: usize = 0;
                            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) n = n * 10 + (s[i] - '0');
                            if (n != 1 and n != 2 and n != 4 and n != 8) c.fatal("invalid type string {f};\nthis system doesn't provide a {d}-byte integral type", .{ c.q(s), n });
                            t.size = n;
                        },
                        else => {},
                    }
                }
            },
            else => c.fatal("invalid character '{c}' in type string {f}", .{ k, c.q(s) }),
        }
        if (i < s.len and s[i] == 'z') {
            t.z = true;
            i += 1;
        }
        list.append(c.gpa, t) catch c.oom();
    }
}

fn fieldWidth(t: Type) usize {
    return switch (t.kind) {
        'a', 'c' => 3,
        'x' => t.size * 2,
        'o' => switch (t.size) {
            1 => 3,
            2 => 6,
            4 => 11,
            else => 22,
        },
        'u' => switch (t.size) {
            1 => 3,
            2 => 5,
            4 => 10,
            else => 20,
        },
        'd' => switch (t.size) {
            1 => 4,
            2 => 6,
            4 => 11,
            else => 20,
        },
        'f' => if (t.size == 4) 14 else 23,
        else => 3,
    };
}

const names = [_][]const u8{ "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr", "so", "si", "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us", "sp" };

fn formatField(buf: []u8, t: Type, bytes: []const u8) []const u8 {
    var v: u64 = 0;
    var k: usize = t.size;
    while (k > 0) {
        k -= 1;
        v = (v << 8) | (if (k < bytes.len) bytes[k] else 0);
    }
    switch (t.kind) {
        'a' => {
            const b = bytes[0] & 0x7f;
            if (b <= 32) return names[b];
            if (b == 127) return "del";
            return c.fmtBuf(buf, "{c}", .{b});
        },
        'c' => {
            const b = bytes[0];
            return switch (b) {
                0 => "\\0",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (b >= 0x20 and b < 0x7f) c.fmtBuf(buf, "{c}", .{b}) else c.fmtBuf(buf, "{o:0>3}", .{b}),
            };
        },
        'x' => return switch (t.size) {
            1 => c.fmtBuf(buf, "{x:0>2}", .{v}),
            2 => c.fmtBuf(buf, "{x:0>4}", .{v}),
            4 => c.fmtBuf(buf, "{x:0>8}", .{v}),
            else => c.fmtBuf(buf, "{x:0>16}", .{v}),
        },
        'o' => return switch (t.size) {
            1 => c.fmtBuf(buf, "{o:0>3}", .{v}),
            2 => c.fmtBuf(buf, "{o:0>6}", .{v}),
            4 => c.fmtBuf(buf, "{o:0>11}", .{v}),
            else => c.fmtBuf(buf, "{o:0>22}", .{v}),
        },
        'u' => return c.fmtBuf(buf, "{d}", .{v}),
        'd' => {
            const sv: i64 = switch (t.size) {
                1 => @as(i8, @bitCast(@as(u8, @truncate(v)))),
                2 => @as(i16, @bitCast(@as(u16, @truncate(v)))),
                4 => @as(i32, @bitCast(@as(u32, @truncate(v)))),
                else => @bitCast(v),
            };
            return c.fmtBuf(buf, "{d}", .{sv});
        },
        'f' => {
            const f: f64 = if (t.size == 4) @as(f32, @bitCast(@as(u32, @truncate(v)))) else @bitCast(v);
            var w: std.Io.Writer = .fixed(buf);
            pf.fmtFloat(&w, .{ .conv = 'g', .prec = if (t.size == 4) 8 else 17 }, f) catch {};
            return w.buffered();
        },
        else => return "?",
    }
}

pub fn main(args: c.Args) !u8 {
    var radix: u8 = 'o';
    var skip: u64 = 0;
    var limit: ?u64 = null;
    var verbose = false;
    var width: usize = 16;
    var types: std.ArrayList(Type) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "address-radix", 'A' }, .{ "skip-bytes", 'j' }, .{ "read-bytes", 'N' }, .{ "format", 't' },
        .{ "output-duplicates", 'v' }, .{ "width", 'w' }, .{ "endian", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'A' => {
                const a = p.arg();
                if (a.len != 1 or mem.indexOfScalar(u8, "doxn", a[0]) == null) c.fatal("invalid output address radix '{s}'; it must be one character from [doxn]", .{a});
                radix = a[0];
            },
            'j' => skip = c.parseSize(p.arg()) orelse c.fatal("invalid skip", .{}),
            'N' => limit = c.parseSize(p.arg()) orelse c.fatal("invalid count", .{}),
            't' => parseType(p.arg(), &types),
            'v' => verbose = true,
            'w' => width = if (p.optArg()) |a| @intCast(c.parseUint(a) orelse c.fatal("invalid width", .{})) else 32,
            'a' => parseType("a", &types),
            'b' => parseType("o1", &types),
            'c' => parseType("c", &types),
            'd' => parseType("u2", &types),
            'f' => parseType("f4", &types),
            'i' => parseType("d4", &types),
            'l' => parseType("d8", &types),
            'o' => parseType("o2", &types),
            's' => parseType("d2", &types),
            'x' => parseType("x2", &types),
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "endian")) _ = p.arg() else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (types.items.len == 0) parseType("o2", &types);
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var data: std.ArrayList(u8) = .empty;
    for (files.items) |f| {
        const d = c.readInput(f) orelse return 1;
        try data.appendSlice(c.gpa, d);
    }
    var bytes = data.items[@min(skip, data.items.len)..];
    if (limit) |l| if (l < bytes.len) {
        bytes = bytes[0..@intCast(l)];
    };
    // GNU od column layout: all specs share the same block width
    var block_width: usize = 0;
    for (types.items) |t| block_width = @max(block_width, (fieldWidth(t) + 1) * (width / t.size));
    const w = c.out;
    const addr = struct {
        fn f(wr: *std.Io.Writer, r: u8, v: u64) !void {
            switch (r) {
                'o' => try wr.print("{o:0>7}", .{v}),
                'd' => try wr.print("{d:0>7}", .{v}),
                'x' => try wr.print("{x:0>6}", .{v}),
                else => {},
            }
        }
    }.f;
    var off: usize = 0;
    var prev: ?[]const u8 = null;
    var starred = false;
    while (off < bytes.len) : (off += width) {
        const line = bytes[off..@min(off + width, bytes.len)];
        if (!verbose and prev != null and line.len == width and mem.eql(u8, prev.?, line)) {
            if (!starred) try w.writeAll("*\n");
            starred = true;
            continue;
        }
        starred = false;
        prev = line;
        for (types.items, 0..) |t, ti| {
            if (ti == 0) try addr(w, radix, skip + off) else if (radix != 'n') try w.splatByteAll(' ', if (radix == 'x') 6 else 7);
            const fw = fieldWidth(t);
            const nfields = width / t.size;
            const pad = block_width - fw * nfields;
            var pad_rem = pad;
            var fi: usize = nfields;
            var i: usize = 0;
            while (i < line.len) : (i += t.size) {
                const next_pad = pad * (fi - 1) / nfields;
                const adj = pad_rem - next_pad + fw;
                var fb: [64]u8 = undefined;
                const s = formatField(&fb, t, line[i..@min(i + t.size, line.len)]);
                try c.padLeft(w, s, adj);
                pad_rem = next_pad;
                fi -= 1;
            }
            if (t.z) {
                const blank_fields = (width - line.len) / t.size;
                try w.splatByteAll(' ', blank_fields * (fw + 1));
                try w.writeAll("  >");
                for (line) |b| try w.writeByte(if (b >= 0x20 and b < 0x7f) b else '.');
                try w.writeByte('<');
            }
            try w.writeByte('\n');
        }
    }
    if (radix != 'n') {
        try addr(w, radix, skip + bytes.len);
        try w.writeByte('\n');
    }
    return 0;
}
