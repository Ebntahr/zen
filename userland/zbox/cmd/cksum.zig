const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: cksum [FILE]...
    \\Print CRC checksum and byte counts of each FILE.
    \\
;

var table: [256]u32 = undefined;

fn initTable() void {
    for (&table, 0..) |*t, i| {
        var crc: u32 = @as(u32, @intCast(i)) << 24;
        var k: u32 = 0;
        while (k < 8) : (k += 1) crc = if (crc & 0x80000000 != 0) (crc << 1) ^ 0x04C11DB7 else crc << 1;
        t.* = crc;
    }
}

pub fn main(args: c.Args) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "algorithm", 'a' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {
                const a = p.arg();
                if (!c.eql(a, "crc")) c.fatal("only the 'crc' algorithm is supported (use md5sum/sha*sum)", .{});
            },
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    initTable();
    const implicit = files.items.len == 0;
    if (implicit) try files.append(c.gpa, "-");
    var status: u8 = 0;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var crc: u32 = 0;
        var len: u64 = 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = c.sys.read(fd, &buf) catch |e| {
                c.warn("{s}: {s}", .{ f, c.strerror(e) });
                status = 1;
                break;
            };
            if (n == 0) break;
            len += n;
            for (buf[0..n]) |b| crc = (crc << 8) ^ table[((crc >> 24) ^ b) & 0xff];
        }
        var l = len;
        while (l > 0) : (l >>= 8) crc = (crc << 8) ^ table[((crc >> 24) ^ @as(u32, @truncate(l & 0xff))) & 0xff];
        crc = ~crc;
        if (implicit) try c.out.print("{d} {d}\n", .{ crc, len }) else try c.out.print("{d} {d} {s}\n", .{ crc, len, f });
    }
    return status;
}
