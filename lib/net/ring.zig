//! A fixed-capacity byte ring buffer (TCP send/receive buffers, datagram
//! queues). The storage is allocated once; reads and writes never allocate.

const std = @import("std");

pub const Ring = struct {
    buf: []u8,
    head: usize = 0,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Ring {
        return .{ .buf = try allocator.alloc(u8, size) };
    }

    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn capacity(self: *const Ring) usize {
        return self.buf.len;
    }

    pub fn free(self: *const Ring) usize {
        return self.buf.len - self.len;
    }

    /// Append as much of `data` as fits; returns the count.
    pub fn write(self: *Ring, data: []const u8) usize {
        const n = @min(data.len, self.free());
        var tail = (self.head + self.len) % self.buf.len;
        var done: usize = 0;
        while (done < n) {
            const chunk = @min(n - done, self.buf.len - tail);
            @memcpy(self.buf[tail..][0..chunk], data[done..][0..chunk]);
            done += chunk;
            tail = (tail + chunk) % self.buf.len;
        }
        self.len += n;
        return n;
    }

    /// Copy bytes starting `offset` bytes after the head without consuming.
    pub fn peek(self: *const Ring, offset: usize, out: []u8) usize {
        if (offset >= self.len) return 0;
        const n = @min(out.len, self.len - offset);
        var pos = (self.head + offset) % self.buf.len;
        var done: usize = 0;
        while (done < n) {
            const chunk = @min(n - done, self.buf.len - pos);
            @memcpy(out[done..][0..chunk], self.buf[pos..][0..chunk]);
            done += chunk;
            pos = (pos + chunk) % self.buf.len;
        }
        return n;
    }

    pub fn discard(self: *Ring, n: usize) void {
        const k = @min(n, self.len);
        self.head = (self.head + k) % self.buf.len;
        self.len -= k;
        if (self.len == 0) self.head = 0;
    }

    /// Consume up to `out.len` bytes.
    pub fn read(self: *Ring, out: []u8) usize {
        const n = self.peek(0, out);
        self.discard(n);
        return n;
    }

    pub fn clear(self: *Ring) void {
        self.head = 0;
        self.len = 0;
    }
};

test "ring wraps around" {
    const a = std.testing.allocator;
    var r = try Ring.init(a, 8);
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), r.write("abcdef"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), r.read(out[0..4]));
    try std.testing.expectEqualStrings("abcd", out[0..4]);
    try std.testing.expectEqual(@as(usize, 6), r.write("ghijklmn"));
    try std.testing.expectEqual(@as(usize, 0), r.free());
    try std.testing.expectEqual(@as(usize, 3), r.peek(5, &out));
    try std.testing.expectEqualStrings("jkl", out[0..3]);
    try std.testing.expectEqual(@as(usize, 8), r.read(&out));
    try std.testing.expectEqualStrings("efghijkl", &out);
}
