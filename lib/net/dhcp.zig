//! DHCP client (RFC 2131): DISCOVER → OFFER → REQUEST → ACK, renewal at
//! T1 (unicast) and rebinding at T2 (broadcast), and a fall back to the
//! static configuration when no server answers.
//!
//! Like the DNS resolver it performs no I/O: `poll` and `input` return an
//! `Action` for the stack to carry out (send the message in `msg`, apply a
//! lease, drop the address, or apply the static configuration).

const std = @import("std");
const wire = @import("wire.zig");
const Ip4 = wire.Ip4;
const Mac = wire.Mac;

pub const client_port: u16 = 68;
pub const server_port: u16 = 67;
const magic: u32 = 0x63825363;
const hdr_len = 236;
/// Smallest BOOTP message some servers accept.
const min_len = 300;
pub const max_len = 576;

pub const MsgType = enum(u8) { discover = 1, offer = 2, request = 3, decline = 4, ack = 5, nak = 6, release = 7, inform = 8, _ };

pub const Lease = struct {
    ip: Ip4 = Ip4.any,
    netmask: Ip4 = Ip4.any,
    gateway: Ip4 = Ip4.any,
    dns: [3]Ip4 = [_]Ip4{Ip4.any} ** 3,
    dns_count: u8 = 0,
    server: Ip4 = Ip4.any,
    /// Seconds; 0xffffffff = infinite.
    lease_s: u32 = 0,
    t1_s: u32 = 0,
    t2_s: u32 = 0,
};

pub const Message = struct {
    op: u8,
    xid: u32,
    yiaddr: Ip4,
    chaddr: Mac,
    kind: ?MsgType = null,
    /// Options, with `ip` = yiaddr.
    lease: Lease,
};

// Options
const opt_pad = 0;
const opt_subnet = 1;
const opt_router = 3;
const opt_dns = 6;
const opt_hostname = 12;
const opt_requested_ip = 50;
const opt_lease_time = 51;
const opt_msg_type = 53;
const opt_server_id = 54;
const opt_param_list = 55;
const opt_t1 = 58;
const opt_t2 = 59;
const opt_client_id = 61;
const opt_end = 255;

pub fn parse(p: []const u8) ?Message {
    if (p.len < hdr_len + 4) return null;
    if (std.mem.readInt(u32, p[hdr_len..][0..4], .big) != magic) return null;
    var m = Message{
        .op = p[0],
        .xid = std.mem.readInt(u32, p[4..8], .big),
        .yiaddr = .{ .bytes = p[16..20].* },
        .chaddr = .{ .bytes = p[28..34].* },
        .lease = .{},
    };
    m.lease.ip = m.yiaddr;
    var pos: usize = hdr_len + 4;
    while (pos < p.len) {
        const code = p[pos];
        if (code == opt_end) break;
        if (code == opt_pad) {
            pos += 1;
            continue;
        }
        if (pos + 2 > p.len) break;
        const len = p[pos + 1];
        const v = p[pos + 2 ..];
        if (v.len < len) break;
        switch (code) {
            opt_msg_type => if (len >= 1) {
                m.kind = @enumFromInt(v[0]);
            },
            opt_subnet => if (len >= 4) {
                m.lease.netmask = .{ .bytes = v[0..4].* };
            },
            opt_router => if (len >= 4) {
                m.lease.gateway = .{ .bytes = v[0..4].* };
            },
            opt_dns => {
                var i: usize = 0;
                while (i + 4 <= len and m.lease.dns_count < 3) : (i += 4) {
                    m.lease.dns[m.lease.dns_count] = .{ .bytes = v[i..][0..4].* };
                    m.lease.dns_count += 1;
                }
            },
            opt_server_id => if (len >= 4) {
                m.lease.server = .{ .bytes = v[0..4].* };
            },
            opt_lease_time => if (len >= 4) {
                m.lease.lease_s = std.mem.readInt(u32, v[0..4], .big);
            },
            opt_t1 => if (len >= 4) {
                m.lease.t1_s = std.mem.readInt(u32, v[0..4], .big);
            },
            opt_t2 => if (len >= 4) {
                m.lease.t2_s = std.mem.readInt(u32, v[0..4], .big);
            },
            else => {},
        }
        pos += 2 + len;
    }
    return m;
}

pub const BuildOptions = struct {
    kind: MsgType,
    xid: u32,
    mac: Mac,
    /// Client address (renewing/rebinding).
    ciaddr: Ip4 = Ip4.any,
    requested: ?Ip4 = null,
    server: ?Ip4 = null,
    /// Ask the server to broadcast its reply.
    broadcast: bool = true,
    hostname: []const u8 = "",
    /// Server messages only (tests).
    op: u8 = 1,
    yiaddr: Ip4 = Ip4.any,
    lease: ?Lease = null,
};

/// Build a DHCP message; returns its length.
pub fn build(buf: []u8, o: BuildOptions) usize {
    @memset(buf[0..max_len], 0);
    buf[0] = o.op;
    buf[1] = 1; // Ethernet
    buf[2] = 6;
    std.mem.writeInt(u32, buf[4..8], o.xid, .big);
    if (o.broadcast) std.mem.writeInt(u16, buf[10..12], 0x8000, .big);
    buf[12..16].* = o.ciaddr.bytes;
    buf[16..20].* = o.yiaddr.bytes;
    buf[28..34].* = o.mac.bytes;
    std.mem.writeInt(u32, buf[hdr_len..][0..4], magic, .big);
    var pos: usize = hdr_len + 4;
    const put = struct {
        fn f(b: []u8, p: *usize, code: u8, data: []const u8) void {
            b[p.*] = code;
            b[p.* + 1] = @intCast(data.len);
            @memcpy(b[p.* + 2 ..][0..data.len], data);
            p.* += 2 + data.len;
        }
    }.f;
    put(buf, &pos, opt_msg_type, &.{@intFromEnum(o.kind)});
    if (o.op == 1) {
        var cid: [7]u8 = undefined;
        cid[0] = 1;
        cid[1..7].* = o.mac.bytes;
        put(buf, &pos, opt_client_id, &cid);
        if (o.requested) |r| put(buf, &pos, opt_requested_ip, &r.bytes);
        if (o.server) |s| put(buf, &pos, opt_server_id, &s.bytes);
        if (o.hostname.len > 0) put(buf, &pos, opt_hostname, o.hostname[0..@min(o.hostname.len, 63)]);
        put(buf, &pos, opt_param_list, &.{ opt_subnet, opt_router, opt_dns, 15, opt_lease_time, opt_t1, opt_t2 });
    }
    if (o.lease) |l| {
        put(buf, &pos, opt_server_id, &l.server.bytes);
        put(buf, &pos, opt_subnet, &l.netmask.bytes);
        put(buf, &pos, opt_router, &l.gateway.bytes);
        var dns: [12]u8 = undefined;
        for (l.dns[0..l.dns_count], 0..) |d, i| dns[i * 4 ..][0..4].* = d.bytes;
        if (l.dns_count > 0) put(buf, &pos, opt_dns, dns[0 .. 4 * @as(usize, l.dns_count)]);
        var t: [4]u8 = undefined;
        std.mem.writeInt(u32, &t, l.lease_s, .big);
        put(buf, &pos, opt_lease_time, &t);
    }
    buf[pos] = opt_end;
    pos += 1;
    return @max(pos, min_len);
}

pub const State = enum { idle, selecting, requesting, bound, renewing, rebinding, static };

pub const Action = union(enum) {
    none,
    /// Transmit `msg[0..len]` from port 68 to `dst` port 67. `unconfigured`:
    /// use source address 0.0.0.0 (no lease yet).
    send: struct { len: usize, dst: Ip4, unconfigured: bool },
    /// Apply this address configuration.
    bound: Lease,
    /// The lease is gone (expired or refused): remove the address.
    lost,
    /// No server answered: apply the static configuration.
    fallback,
};

pub const Client = struct {
    mac: Mac,
    state: State = .idle,
    xid: u32 = 0,
    /// Transmissions in the current state.
    attempt: u8 = 0,
    /// DISCOVERs sent since the last lease.
    discovers: u8 = 0,
    deadline: u64 = 0,
    lease: Lease = .{},
    offer: Lease = .{},
    bound_at: u64 = 0,
    prng: std.Random.DefaultPrng,
    hostname: [64]u8 = undefined,
    hostname_len: u8 = 0,
    /// First retransmission interval; doubles up to 8× (RFC 2131: 4 s).
    retry_ms: u64 = 2000,
    /// Give up and fall back to the static configuration after this many
    /// DISCOVERs (0 = keep trying forever).
    fallback_after: u8 = 4,
    msg: [max_len]u8 = undefined,

    pub fn init(mac: Mac, seed: u64, hostname: []const u8) Client {
        var c = Client{ .mac = mac, .prng = std.Random.DefaultPrng.init(seed ^ 0xd4c9) };
        c.hostname_len = @intCast(@min(hostname.len, c.hostname.len));
        @memcpy(c.hostname[0..c.hostname_len], hostname[0..c.hostname_len]);
        return c;
    }

    pub fn start(self: *Client, now: u64) void {
        self.state = .selecting;
        self.attempt = 0;
        self.discovers = 0;
        self.deadline = now;
        self.xid = self.prng.random().int(u32);
    }

    pub fn active(self: *const Client) bool {
        return self.state != .idle and self.state != .static;
    }

    pub fn nextDeadline(self: *const Client) ?u64 {
        return if (self.active()) self.deadline else null;
    }

    fn interval(self: *const Client) u64 {
        return self.retry_ms << @intCast(@min(self.attempt, 3));
    }

    fn secondsAfter(self: *const Client, s: u64) u64 {
        return self.bound_at + s * 1000;
    }

    fn t1At(self: *const Client) u64 {
        const l = self.lease;
        return self.secondsAfter(if (l.t1_s != 0) l.t1_s else l.lease_s / 2);
    }

    fn t2At(self: *const Client) u64 {
        const l = self.lease;
        return self.secondsAfter(if (l.t2_s != 0) l.t2_s else @as(u64, l.lease_s) * 7 / 8);
    }

    fn expiresAt(self: *const Client) u64 {
        return self.secondsAfter(self.lease.lease_s);
    }

    fn infinite(self: *const Client) bool {
        return self.lease.lease_s == 0xffff_ffff;
    }

    fn send(self: *Client, kind: MsgType, dst: Ip4, unconfigured: bool) Action {
        const renew = self.state == .renewing or self.state == .rebinding;
        const len = build(&self.msg, .{
            .kind = kind,
            .xid = self.xid,
            .mac = self.mac,
            .ciaddr = if (renew) self.lease.ip else Ip4.any,
            .requested = if (self.state == .requesting) self.offer.ip else null,
            .server = if (self.state == .requesting) self.offer.server else null,
            .broadcast = !renew,
            .hostname = self.hostname[0..self.hostname_len],
        });
        return .{ .send = .{ .len = len, .dst = dst, .unconfigured = unconfigured } };
    }

    /// Run timers. Call until it returns `.none`.
    pub fn poll(self: *Client, now: u64) Action {
        if (!self.active() or now < self.deadline) return .none;
        switch (self.state) {
            .selecting => {
                if (self.fallback_after != 0 and self.discovers >= self.fallback_after) {
                    self.state = .static;
                    return .fallback;
                }
                self.discovers +|= 1;
                self.deadline = now + self.interval();
                self.attempt +|= 1;
                return self.send(.discover, Ip4.broadcast, true);
            },
            .requesting => {
                if (self.attempt >= 3) {
                    self.state = .selecting;
                    self.attempt = 0;
                    self.deadline = now;
                    return .none;
                }
                self.deadline = now + self.interval();
                self.attempt += 1;
                return self.send(.request, Ip4.broadcast, true);
            },
            .bound, .renewing => {
                if (now >= self.t2At()) {
                    self.state = .rebinding;
                    self.deadline = now;
                    return .none;
                }
                self.state = .renewing;
                self.deadline = now + @max((self.t2At() - now) / 2, 1000);
                self.deadline = @min(self.deadline, self.t2At());
                return self.send(.request, self.lease.server, false);
            },
            .rebinding => {
                if (now >= self.expiresAt()) {
                    self.start(now);
                    return .lost;
                }
                self.deadline = @min(now + @max((self.expiresAt() - now) / 2, 1000), self.expiresAt());
                return self.send(.request, Ip4.broadcast, false);
            },
            .idle, .static => return .none,
        }
    }

    /// A datagram received on port 68.
    pub fn input(self: *Client, payload: []const u8, now: u64) Action {
        const m = parse(payload) orelse return .none;
        if (m.op != 2 or m.xid != self.xid or !m.chaddr.eql(self.mac)) return .none;
        const kind = m.kind orelse return .none;
        switch (self.state) {
            .selecting => if (kind == .offer and !m.yiaddr.isAny()) {
                self.offer = m.lease;
                self.state = .requesting;
                self.attempt = 0;
                self.deadline = now;
                return self.poll(now);
            },
            .requesting, .renewing, .rebinding => switch (kind) {
                .ack => {
                    var l = m.lease;
                    if (l.server.isAny()) l.server = self.offer.server;
                    if (l.lease_s == 0) l.lease_s = 3600;
                    if (l.netmask.isAny()) l.netmask = Ip4.init(255, 255, 255, 0);
                    self.lease = l;
                    self.state = .bound;
                    self.bound_at = now;
                    self.attempt = 0;
                    self.discovers = 0;
                    self.deadline = if (self.infinite()) std.math.maxInt(u64) else self.t1At();
                    return .{ .bound = l };
                },
                .nak => {
                    const had = self.state != .requesting;
                    self.start(now);
                    return if (had) .lost else .none;
                },
                else => {},
            },
            else => {},
        }
        return .none;
    }
};

test "dhcp message round trip" {
    var buf: [max_len]u8 = undefined;
    const mac = Mac.parse("52:54:00:12:34:56").?;
    const lease = Lease{
        .ip = Ip4.init(10, 0, 2, 15),
        .netmask = Ip4.init(255, 255, 255, 0),
        .gateway = Ip4.init(10, 0, 2, 2),
        .dns = .{ Ip4.init(10, 0, 2, 3), Ip4.any, Ip4.any },
        .dns_count = 1,
        .server = Ip4.init(10, 0, 2, 2),
        .lease_s = 86400,
    };
    const n = build(&buf, .{ .kind = .ack, .xid = 42, .mac = mac, .op = 2, .yiaddr = lease.ip, .lease = lease });
    try std.testing.expect(n >= 300);
    const m = parse(buf[0..n]).?;
    try std.testing.expectEqual(MsgType.ack, m.kind.?);
    try std.testing.expect(m.lease.ip.eql(lease.ip));
    try std.testing.expect(m.lease.gateway.eql(lease.gateway));
    try std.testing.expect(m.lease.dns[0].eql(lease.dns[0]));
    try std.testing.expectEqual(@as(u32, 86400), m.lease.lease_s);
}
