//! ARP cache (RFC 826) with a queue for packets waiting on resolution.
//!
//! Entries are resolved or incomplete. An incomplete entry is re-requested
//! every second; after `max_requests` unanswered requests its queued
//! packets are dropped and the address is reported unreachable.

const std = @import("std");
const wire = @import("wire.zig");
const Ip4 = wire.Ip4;
const Mac = wire.Mac;

pub const entries_max = 32;
pub const pending_max = 16;
pub const max_frame = 1514;
const lifetime_ms: u64 = 5 * 60 * 1000;
const retry_ms: u64 = 1000;
pub const max_requests = 3;

pub const Entry = struct {
    state: enum { free, incomplete, resolved } = .free,
    ip: Ip4 = Ip4.any,
    mac: Mac = Mac.zero,
    /// resolved: expiry time; incomplete: time of the next request.
    deadline: u64 = 0,
    requests: u8 = 0,
};

const Pending = struct {
    used: bool = false,
    hop: Ip4 = Ip4.any,
    len: u16 = 0,
    seq: u64 = 0,
};

pub const Cache = struct {
    entries: [entries_max]Entry = [_]Entry{.{}} ** entries_max,
    pending: [pending_max]Pending = [_]Pending{.{}} ** pending_max,
    /// Frame storage for `pending` (pending_max × max_frame).
    frames: []u8,
    seq: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Cache {
        return .{ .frames = try allocator.alloc(u8, pending_max * max_frame) };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
    }

    fn find(self: *Cache, ip: Ip4) ?*Entry {
        for (&self.entries) |*e| {
            if (e.state != .free and e.ip.eql(ip)) return e;
        }
        return null;
    }

    /// The hardware address of `ip`, if known and fresh.
    pub fn lookup(self: *Cache, ip: Ip4, now: u64) ?Mac {
        const e = self.find(ip) orelse return null;
        if (e.state != .resolved) return null;
        if (now >= e.deadline) {
            e.state = .incomplete;
            e.requests = 0;
            e.deadline = now;
            return null;
        }
        return e.mac;
    }

    /// Record `ip` → `mac`. Existing entries are always refreshed; a new
    /// entry is only created when `create` (the packet was addressed to us).
    /// Returns true when the entry was incomplete (queued packets can go).
    pub fn update(self: *Cache, ip: Ip4, mac: Mac, now: u64, create: bool) bool {
        if (ip.isAny()) return false;
        if (self.find(ip)) |e| {
            const was = e.state == .incomplete;
            e.state = .resolved;
            e.mac = mac;
            e.deadline = now + lifetime_ms;
            return was;
        }
        if (!create) return false;
        const e = self.victim();
        e.* = .{ .state = .resolved, .ip = ip, .mac = mac, .deadline = now + lifetime_ms };
        return false;
    }

    fn victim(self: *Cache) *Entry {
        var best = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.state == .free) return e;
            // Prefer the resolved entry closest to expiry.
            if (e.state == .resolved and (best.state != .resolved or e.deadline < best.deadline)) best = e;
        }
        return best;
    }

    /// Make sure `ip` is being resolved. Returns true when a request
    /// should be sent now.
    pub fn resolve(self: *Cache, ip: Ip4, now: u64) bool {
        if (self.find(ip)) |e| {
            if (e.state == .resolved) return false;
            if (e.requests == 0) {
                e.requests = 1;
                e.deadline = now + retry_ms;
                return true;
            }
            return false;
        }
        const e = self.victim();
        self.dropPending(e.ip);
        e.* = .{ .state = .incomplete, .ip = ip, .requests = 1, .deadline = now + retry_ms };
        return true;
    }

    /// Queue a frame (Ethernet destination still to be filled in) until
    /// `hop` resolves. The oldest queued frame makes room when full.
    pub fn enqueue(self: *Cache, hop: Ip4, frame: []const u8) void {
        if (frame.len > max_frame) return;
        var slot: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.pending, 0..) |*p, i| {
            if (!p.used) {
                slot = i;
                break;
            }
            if (p.seq < oldest) {
                oldest = p.seq;
                slot = i;
            }
        }
        self.seq += 1;
        self.pending[slot] = .{ .used = true, .hop = hop, .len = @intCast(frame.len), .seq = self.seq };
        @memcpy(self.frames[slot * max_frame ..][0..frame.len], frame);
    }

    /// Take the oldest frame queued for `hop` (null when none are left).
    /// The slice stays valid until the next `enqueue`.
    pub fn takePending(self: *Cache, hop: Ip4) ?[]u8 {
        var best: ?usize = null;
        for (&self.pending, 0..) |*p, i| {
            if (!p.used or !p.hop.eql(hop)) continue;
            if (best == null or p.seq < self.pending[best.?].seq) best = i;
        }
        const i = best orelse return null;
        self.pending[i].used = false;
        return self.frames[i * max_frame ..][0..self.pending[i].len];
    }

    fn dropPending(self: *Cache, hop: Ip4) void {
        for (&self.pending) |*p| {
            if (p.used and p.hop.eql(hop)) p.used = false;
        }
    }

    pub const Due = union(enum) {
        none,
        /// Send another request for this address.
        request: Ip4,
        /// Resolution failed; its queued packets were dropped.
        failed: Ip4,
    };

    /// Next due retransmission or failure (call until `.none`).
    pub fn poll(self: *Cache, now: u64) Due {
        for (&self.entries) |*e| {
            if (e.state != .incomplete or e.requests == 0 or now < e.deadline) continue;
            if (e.requests >= max_requests) {
                const ip = e.ip;
                self.dropPending(ip);
                e.* = .{};
                return .{ .failed = ip };
            }
            e.requests += 1;
            e.deadline = now + retry_ms;
            return .{ .request = e.ip };
        }
        return .none;
    }

    pub fn nextDeadline(self: *const Cache) ?u64 {
        var best: ?u64 = null;
        for (&self.entries) |*e| {
            if (e.state != .incomplete or e.requests == 0) continue;
            best = if (best) |b| @min(b, e.deadline) else e.deadline;
        }
        return best;
    }
};

test "arp cache resolves, queues and fails" {
    const a = std.testing.allocator;
    var c = try Cache.init(a);
    defer c.deinit(a);
    const ip = Ip4.init(10, 0, 0, 2);
    const mac = Mac.parse("02:00:00:00:00:02").?;
    try std.testing.expect(c.lookup(ip, 0) == null);
    try std.testing.expect(c.resolve(ip, 0));
    try std.testing.expect(!c.resolve(ip, 10));
    c.enqueue(ip, "frame-1");
    c.enqueue(ip, "frame-2");
    try std.testing.expect(c.update(ip, mac, 20, false));
    try std.testing.expect(c.lookup(ip, 30).?.eql(mac));
    try std.testing.expectEqualStrings("frame-1", c.takePending(ip).?);
    try std.testing.expectEqualStrings("frame-2", c.takePending(ip).?);
    try std.testing.expect(c.takePending(ip) == null);

    const gone = Ip4.init(10, 0, 0, 9);
    _ = c.resolve(gone, 0);
    c.enqueue(gone, "lost");
    try std.testing.expectEqual(Cache.Due{ .request = gone }, c.poll(1000));
    try std.testing.expectEqual(Cache.Due.none, c.poll(1500));
    try std.testing.expectEqual(Cache.Due{ .request = gone }, c.poll(2000));
    try std.testing.expectEqual(Cache.Due{ .failed = gone }, c.poll(3000));
    try std.testing.expect(c.takePending(gone) == null);
}
