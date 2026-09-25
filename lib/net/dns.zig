//! DNS stub resolver (RFC 1035): A-record queries over UDP with retries
//! across the configured servers and a small cache (positive and negative).
//!
//! The resolver does no I/O itself. Its owner sends the datagrams it asks
//! for (`poll`) and feeds it the replies (`input`), so the same code runs
//! over the lib/net stack and over host sockets:
//!
//!     const id = try r.query("example.com", now);
//!     r.poll(now, ctx, sendFn);          // transmit / retransmit
//!     r.input(server, reply, now);       // a datagram from port 53
//!     switch (r.status(id)) { .pending => …, .done => |res| …, .failed => |e| … }
//!     r.release(id);

const std = @import("std");
const wire = @import("wire.zig");
pub const Ip4 = wire.Ip4;

pub const port: u16 = 53;
pub const max_name = 253;
pub const max_addrs = 8;
pub const max_servers = 3;
const max_queries = 16;
const cache_size = 32;
const attempts = 4;
const negative_ttl_ms: u64 = 30_000;
const min_ttl_ms: u64 = 5_000;
const max_ttl_ms: u64 = 24 * 3600 * 1000;

pub const Error = error{ NameNotFound, Timeout, NoServers, InvalidName, ServerFailure, TooManyQueries };

pub const Result = struct {
    addrs: [max_addrs]Ip4 = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Result) []const Ip4 {
        return self.addrs[0..self.count];
    }
};

pub const Status = union(enum) {
    pending,
    done: Result,
    failed: Error,
};

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub const type_a: u16 = 1;
pub const type_cname: u16 = 5;
pub const class_in: u16 = 1;

/// Build a recursive query for `name` (type A). Returns the message length.
pub fn buildQuery(buf: []u8, id: u16, name: []const u8) Error!usize {
    if (buf.len < 12 + name.len + 2 + 4) return error.InvalidName;
    std.mem.writeInt(u16, buf[0..2], id, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    @memset(buf[6..12], 0);
    var pos: usize = 12;
    pos = try encodeName(buf, pos, name);
    std.mem.writeInt(u16, buf[pos..][0..2], type_a, .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], class_in, .big);
    return pos + 4;
}

fn encodeName(buf: []u8, start: usize, name: []const u8) Error!usize {
    const trimmed = std.mem.trimRight(u8, name, ".");
    if (trimmed.len == 0 or trimmed.len > max_name) return error.InvalidName;
    var pos = start;
    var it = std.mem.splitScalar(u8, trimmed, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidName;
        for (label) |c| if (c <= ' ' or c >= 0x7f) return error.InvalidName;
        if (pos + 1 + label.len + 1 > buf.len) return error.InvalidName;
        buf[pos] = @intCast(label.len);
        @memcpy(buf[pos + 1 ..][0..label.len], label);
        pos += 1 + label.len;
    }
    buf[pos] = 0;
    return pos + 1;
}

/// Skip a (possibly compressed) name; returns the offset after it.
fn skipName(msg: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < msg.len) {
        const len = msg[pos];
        if (len == 0) return pos + 1;
        if (len & 0xc0 == 0xc0) return if (pos + 2 <= msg.len) pos + 2 else null;
        if (len & 0xc0 != 0) return null;
        pos += 1 + len;
    }
    return null;
}

pub const Reply = struct {
    id: u16,
    rcode: u4,
    result: Result,
    /// Smallest TTL of the A records, in seconds.
    ttl: u32,
};

/// Parse a response: collects the A records of the answer section (the
/// records of a CNAME chain's target are part of it).
pub fn parseReply(msg: []const u8) ?Reply {
    if (msg.len < 12) return null;
    const flags = std.mem.readInt(u16, msg[2..4], .big);
    if (flags & 0x8000 == 0) return null; // not a response
    const qd = std.mem.readInt(u16, msg[4..6], .big);
    const an = std.mem.readInt(u16, msg[6..8], .big);
    var r = Reply{ .id = std.mem.readInt(u16, msg[0..2], .big), .rcode = @truncate(flags), .result = .{}, .ttl = std.math.maxInt(u32) };
    var pos: usize = 12;
    for (0..qd) |_| {
        pos = skipName(msg, pos) orelse return null;
        pos += 4;
        if (pos > msg.len) return null;
    }
    for (0..an) |_| {
        pos = skipName(msg, pos) orelse return null;
        if (pos + 10 > msg.len) return null;
        const rtype = std.mem.readInt(u16, msg[pos..][0..2], .big);
        const class = std.mem.readInt(u16, msg[pos + 2 ..][0..2], .big);
        const ttl = std.mem.readInt(u32, msg[pos + 4 ..][0..4], .big);
        const rdlen = std.mem.readInt(u16, msg[pos + 8 ..][0..2], .big);
        pos += 10;
        if (pos + rdlen > msg.len) return null;
        if (rtype == type_a and class == class_in and rdlen == 4 and r.result.count < max_addrs) {
            r.result.addrs[r.result.count] = .{ .bytes = msg[pos..][0..4].* };
            r.result.count += 1;
            r.ttl = @min(r.ttl, ttl);
        }
        pos += rdlen;
    }
    if (r.result.count == 0) r.ttl = 0;
    return r;
}

/// Look `name` up in the text of an /etc/hosts file.
pub fn lookupHosts(text: []const u8, name: []const u8) ?Ip4 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const addr = Ip4.parse(it.next() orelse continue) orelse continue;
        while (it.next()) |alias| {
            if (std.ascii.eqlIgnoreCase(alias, name)) return addr;
        }
    }
    return null;
}

/// Name servers from the text of a resolv.conf file.
pub fn parseResolvConf(text: []const u8, out: []Ip4) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = it.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const ip = Ip4.parse(it.next() orelse continue) orelse continue;
        if (n < out.len) {
            out[n] = ip;
            n += 1;
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Resolver
// ---------------------------------------------------------------------------

const Name = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,

    fn set(self: *Name, s: []const u8) void {
        self.len = @intCast(s.len);
        for (s, 0..) |c, i| self.buf[i] = std.ascii.toLower(c);
    }

    fn eql(self: *const Name, s: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.buf[0..self.len], s);
    }

    fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

const Query = struct {
    state: enum { free, pending, done, failed } = .free,
    name: Name = .{},
    txid: u16 = 0,
    attempt: u8 = 0,
    /// Next (re)transmission; 0 = send now.
    deadline: u64 = 0,
    sent: bool = false,
    result: Result = .{},
    err: Error = error.Timeout,
};

const CacheEntry = struct {
    name: Name = .{},
    result: Result = .{},
    /// 0 = unused.
    expires: u64 = 0,
};

pub const SendFn = *const fn (ctx: *anyopaque, server: Ip4, msg: []const u8) void;

pub const Resolver = struct {
    servers: [max_servers]Ip4 = undefined,
    nservers: u8 = 0,
    queries: [max_queries]Query = [_]Query{.{}} ** max_queries,
    cache: [cache_size]CacheEntry = [_]CacheEntry{.{}} ** cache_size,
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Resolver {
        return .{ .prng = std.Random.DefaultPrng.init(seed ^ 0xd15c0) };
    }

    pub fn setServers(self: *Resolver, servers: []const Ip4) void {
        self.nservers = @intCast(@min(servers.len, max_servers));
        @memcpy(self.servers[0..self.nservers], servers[0..self.nservers]);
    }

    pub fn flushCache(self: *Resolver) void {
        for (&self.cache) |*e| e.expires = 0;
    }

    /// Start resolving `name`. Dotted quads and cached names complete at
    /// once. Returns an id for `status` and `release`.
    pub fn query(self: *Resolver, name: []const u8, now: u64) Error!u16 {
        const trimmed = std.mem.trimRight(u8, name, ".");
        if (trimmed.len == 0 or trimmed.len > max_name) return error.InvalidName;
        const slot = for (&self.queries, 0..) |*q, i| {
            if (q.state == .free) break i;
        } else return error.TooManyQueries;
        const q = &self.queries[slot];
        q.* = .{};
        q.name.set(trimmed);
        if (Ip4.parse(trimmed)) |ip| {
            q.state = .done;
            q.result.addrs[0] = ip;
            q.result.count = 1;
            return @intCast(slot);
        }
        for (&self.cache) |*e| {
            if (e.expires > now and e.name.eql(trimmed)) {
                if (e.result.count == 0) {
                    q.state = .failed;
                    q.err = error.NameNotFound;
                } else {
                    q.state = .done;
                    q.result = e.result;
                }
                return @intCast(slot);
            }
        }
        var probe: [max_name + 18]u8 = undefined;
        _ = buildQuery(&probe, 0, trimmed) catch return error.InvalidName;
        if (self.nservers == 0) {
            q.state = .failed;
            q.err = error.NoServers;
            return @intCast(slot);
        }
        q.state = .pending;
        q.txid = self.prng.random().int(u16);
        q.deadline = 0;
        return @intCast(slot);
    }

    pub fn status(self: *const Resolver, id: u16) Status {
        const q = &self.queries[id];
        return switch (q.state) {
            .free, .pending => .pending,
            .done => .{ .done = q.result },
            .failed => .{ .failed = q.err },
        };
    }

    pub fn release(self: *Resolver, id: u16) void {
        self.queries[id].state = .free;
    }

    pub fn hasPending(self: *const Resolver) bool {
        for (&self.queries) |*q| if (q.state == .pending) return true;
        return false;
    }

    /// Earliest time `poll` has work to do.
    pub fn nextDeadline(self: *const Resolver) ?u64 {
        var best: ?u64 = null;
        for (&self.queries) |*q| {
            if (q.state != .pending) continue;
            best = if (best) |b| @min(b, q.deadline) else q.deadline;
        }
        return best;
    }

    fn timeoutFor(attempt: u8) u64 {
        return 1000 * @as(u64, attempt + 1);
    }

    /// Transmit new queries and retransmit timed-out ones.
    pub fn poll(self: *Resolver, now: u64, ctx: *anyopaque, send: SendFn) void {
        for (&self.queries) |*q| {
            if (q.state != .pending or q.deadline > now) continue;
            if (q.sent) q.attempt += 1;
            if (q.attempt >= attempts or self.nservers == 0) {
                q.state = .failed;
                q.err = if (self.nservers == 0) error.NoServers else error.Timeout;
                continue;
            }
            var msg: [max_name + 18]u8 = undefined;
            const len = buildQuery(&msg, q.txid, q.name.slice()) catch {
                q.state = .failed;
                q.err = error.InvalidName;
                continue;
            };
            q.sent = true;
            q.deadline = now + timeoutFor(q.attempt);
            send(ctx, self.servers[q.attempt % self.nservers], msg[0..len]);
        }
    }

    /// A datagram from a name server's port 53.
    pub fn input(self: *Resolver, from: Ip4, msg: []const u8, now: u64) void {
        const r = parseReply(msg) orelse return;
        for (&self.queries) |*q| {
            if (q.state != .pending or !q.sent or q.txid != r.id) continue;
            // Only accept the answer from a server we asked.
            const known = for (self.servers[0..self.nservers]) |s| {
                if (s.eql(from)) break true;
            } else false;
            if (!known) return;
            switch (r.rcode) {
                0 => {
                    if (r.result.count == 0) {
                        q.state = .failed;
                        q.err = error.NameNotFound;
                        self.remember(q.name.slice(), .{}, now + negative_ttl_ms);
                    } else {
                        q.state = .done;
                        q.result = r.result;
                        const ttl = std.math.clamp(@as(u64, r.ttl) * 1000, min_ttl_ms, max_ttl_ms);
                        self.remember(q.name.slice(), r.result, now + ttl);
                    }
                },
                3 => {
                    q.state = .failed;
                    q.err = error.NameNotFound;
                    self.remember(q.name.slice(), .{}, now + negative_ttl_ms);
                },
                else => {
                    // Server failure or refusal: try the next server now.
                    q.deadline = now;
                    if (q.attempt + 1 >= attempts) {
                        q.state = .failed;
                        q.err = error.ServerFailure;
                    }
                },
            }
            return;
        }
    }

    fn remember(self: *Resolver, name: []const u8, result: Result, expires: u64) void {
        var victim = &self.cache[0];
        for (&self.cache) |*e| {
            if (e.expires != 0 and e.name.eql(name)) {
                victim = e;
                break;
            }
            if (e.expires < victim.expires) victim = e;
        }
        victim.name.set(name);
        victim.result = result;
        victim.expires = expires;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Build a reply to `query_msg` with the given A records (test helper,
/// also used by the scripted responder in tests.zig).
pub fn buildReply(buf: []u8, query_msg: []const u8, rcode: u4, addrs: []const Ip4, ttl: u32) usize {
    const qend = (skipName(query_msg, 12) orelse return 0) + 4;
    @memcpy(buf[0..qend], query_msg[0..qend]);
    std.mem.writeInt(u16, buf[2..4], 0x8180 | @as(u16, rcode), .big);
    std.mem.writeInt(u16, buf[6..8], @intCast(addrs.len), .big);
    var pos = qend;
    for (addrs) |a| {
        buf[pos] = 0xc0;
        buf[pos + 1] = 12;
        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], type_a, .big);
        std.mem.writeInt(u16, buf[pos + 4 ..][0..2], class_in, .big);
        std.mem.writeInt(u32, buf[pos + 6 ..][0..4], ttl, .big);
        std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 4, .big);
        buf[pos + 12 ..][0..4].* = a.bytes;
        pos += 16;
    }
    return pos;
}

test "query encoding and reply parsing" {
    var q: [300]u8 = undefined;
    const n = try buildQuery(&q, 0x1234, "www.example.com.");
    try std.testing.expectEqualSlices(u8, "\x03www\x07example\x03com\x00", q[12 .. n - 4]);
    var bad: [300]u8 = undefined;
    try std.testing.expectError(error.InvalidName, buildQuery(&bad, 1, "a..b"));
    var r: [512]u8 = undefined;
    const addrs = [_]Ip4{ Ip4.init(93, 184, 216, 34), Ip4.init(1, 2, 3, 4) };
    const rn = buildReply(&r, q[0..n], 0, &addrs, 300);
    const reply = parseReply(r[0..rn]).?;
    try std.testing.expectEqual(@as(u16, 0x1234), reply.id);
    try std.testing.expectEqual(@as(u8, 2), reply.result.count);
    try std.testing.expect(reply.result.addrs[1].eql(addrs[1]));
    try std.testing.expectEqual(@as(u32, 300), reply.ttl);
}

test "hosts and resolv.conf" {
    const hosts = "127.0.0.1\tlocalhost zen.local # me\n# 1.2.3.4 nope\n10.0.2.2 gateway\n";
    try std.testing.expect(lookupHosts(hosts, "localhost").?.eql(Ip4.loopback));
    try std.testing.expect(lookupHosts(hosts, "GATEWAY").?.eql(Ip4.init(10, 0, 2, 2)));
    try std.testing.expect(lookupHosts(hosts, "nope") == null);
    var servers: [3]Ip4 = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseResolvConf("nameserver 8.8.8.8\noptions x\nnameserver 1.1.1.1\n", &servers));
    try std.testing.expect(servers[1].eql(Ip4.init(1, 1, 1, 1)));
}

test "resolver retries, caches and fails over" {
    const Sent = struct {
        list: [8]struct { server: Ip4, msg: [300]u8, len: usize } = undefined,
        n: usize = 0,
        fn send(ctx: *anyopaque, server: Ip4, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.list[self.n] = .{ .server = server, .msg = undefined, .len = msg.len };
            @memcpy(self.list[self.n].msg[0..msg.len], msg);
            self.n += 1;
        }
    };
    var sent = Sent{};
    var r = Resolver.init(1);
    const s1 = Ip4.init(10, 0, 0, 1);
    const s2 = Ip4.init(10, 0, 0, 2);
    r.setServers(&.{ s1, s2 });
    const id = try r.query("zen.example", 0);
    r.poll(0, &sent, Sent.send);
    try std.testing.expectEqual(@as(usize, 1), sent.n);
    try std.testing.expect(sent.list[0].server.eql(s1));
    // No answer: the retry goes to the second server.
    r.poll(999, &sent, Sent.send);
    try std.testing.expectEqual(@as(usize, 1), sent.n);
    r.poll(1000, &sent, Sent.send);
    try std.testing.expectEqual(@as(usize, 2), sent.n);
    try std.testing.expect(sent.list[1].server.eql(s2));
    var reply: [512]u8 = undefined;
    const addr = Ip4.init(192, 0, 2, 7);
    const len = buildReply(&reply, sent.list[1].msg[0..sent.list[1].len], 0, &.{addr}, 60);
    // A reply from an unknown host is ignored.
    r.input(Ip4.init(6, 6, 6, 6), reply[0..len], 1001);
    try std.testing.expect(r.status(id) == .pending);
    r.input(s2, reply[0..len], 1001);
    try std.testing.expect(r.status(id).done.addrs[0].eql(addr));
    r.release(id);
    // Cached now.
    const id2 = try r.query("ZEN.example.", 2000);
    try std.testing.expect(r.status(id2).done.addrs[0].eql(addr));
    r.release(id2);
    // Dotted quads need no server.
    const id3 = try r.query("1.2.3.4", 0);
    try std.testing.expect(r.status(id3).done.addrs[0].eql(Ip4.init(1, 2, 3, 4)));
    // NXDOMAIN is cached negatively; timeouts fail after all attempts.
    const id4 = try r.query("missing.example", 3000);
    r.poll(3000, &sent, Sent.send);
    const nx = buildReply(&reply, sent.list[sent.n - 1].msg[0..sent.list[sent.n - 1].len], 3, &.{}, 0);
    r.input(s1, reply[0..nx], 3001);
    try std.testing.expectEqual(Status{ .failed = error.NameNotFound }, r.status(id4));
    const id5 = try r.query("slow.example", 5000);
    var t: u64 = 5000;
    while (r.status(id5) == .pending) : (t += 500) r.poll(t, &sent, Sent.send);
    try std.testing.expectEqual(Status{ .failed = error.Timeout }, r.status(id5));
}
