//! The network stack: one Ethernet interface with ARP, IPv4 (plus an
//! internal loopback for 127.0.0.0/8 and the interface's own address),
//! ICMP echo, UDP, TCP, a DHCP client and a DNS stub resolver.
//!
//! The stack is OS-independent. Its owner supplies time and frames:
//!
//!     var s = try Stack.init(gpa, .{ .mac = mac, .seed = seed, .output = out, .dhcp = true }, now);
//!     s.input(frame, now);            // every received Ethernet frame
//!     s.poll(now);                    // timers, loopback; again after s.nextTimeout(now) ms
//!
//! and frames to transmit go to `Config.output` as they are produced.
//! Sockets are handles with non-blocking calls (`send`, `recv`, `ready`,
//! `tcpAccept`, `udpRecvFrom`…): they return `error.WouldBlock` instead of
//! waiting, so a server can park a client's request and answer it after a
//! later `input`/`poll`. Calls that are not given a time use the time of
//! the last `input`/`poll`.

const std = @import("std");
const wire = @import("wire.zig");
const arp = @import("arp.zig");
const dhcp = @import("dhcp.zig");
const dns = @import("dns.zig");
pub const tcp = @import("tcp.zig");
const Ring = @import("ring.zig").Ring;

pub const Ip4 = wire.Ip4;
pub const Mac = wire.Mac;

/// A socket (1-based; 0 is never a valid handle).
pub const Handle = u32;

pub const IfConfig = struct {
    ip: Ip4,
    netmask: Ip4,
    gateway: Ip4 = Ip4.any,
    dns: [3]Ip4 = [_]Ip4{Ip4.any} ** 3,
    dns_count: u8 = 0,

    pub fn dnsServers(self: *const IfConfig) []const Ip4 {
        return self.dns[0..self.dns_count];
    }
};

pub const Output = struct {
    ctx: *anyopaque,
    /// Transmit one Ethernet frame (without FCS). The slice is only valid
    /// during the call.
    send: *const fn (ctx: *anyopaque, frame: []const u8) void,
};

pub const Config = struct {
    mac: Mac,
    /// IP MTU of the link.
    mtu: u16 = 1500,
    /// Seeds initial sequence numbers, ephemeral ports and DHCP/DNS ids.
    seed: u64,
    output: Output,
    /// Static addresses: used at once without DHCP, and as the fall back
    /// when no DHCP server answers.
    static: ?IfConfig = null,
    dhcp: bool = false,
    dhcp_retry_ms: u64 = 2000,
    dhcp_fallback_after: u8 = 4,
    hostname: []const u8 = "zen",
    tcp: tcp.Config = .{},
};

pub const Error = error{
    OutOfMemory,
    AddressInUse,
    NoRoute,
    MessageTooLong,
    WouldBlock,
    BadHandle,
    NotConnected,
    ConnectionRefused,
    ConnectionReset,
    TimedOut,
    HostUnreachable,
};

pub const Ready = struct {
    /// Data (or EOF, an error, a connection to accept) can be read.
    in: bool = false,
    /// `send` would accept data.
    out: bool = false,
    /// The peer closed or the connection is gone.
    hup: bool = false,
    err: bool = false,
};

pub const Endpoint = struct { ip: Ip4, port: u16 };

pub const Datagram = struct {
    from: Ip4,
    port: u16,
    /// Full datagram length (the copy is truncated to the buffer).
    len: usize,
};

pub const PingReply = struct {
    from: Ip4,
    seq: u16,
    ttl: u8,
    len: usize,
    /// Time the reply was received.
    time: u64,
};

pub const Stats = struct {
    rx_frames: u64 = 0,
    rx_bytes: u64 = 0,
    tx_frames: u64 = 0,
    tx_bytes: u64 = 0,
    rx_dropped: u64 = 0,
};

pub const DhcpState = dhcp.State;
pub const Lease = dhcp.Lease;
pub const DnsStatus = dns.Status;

const Udp = struct {
    port: u16,
    /// Records: from (4), port (2), length (2), payload.
    queue: Ring,
};

const ping_queue = 16;

const Ping = struct {
    id: u16,
    replies: [ping_queue]PingReply = undefined,
    head: u8 = 0,
    count: u8 = 0,
};

pub const Sock = union(enum) {
    tcp: tcp.Tcb,
    udp: Udp,
    ping: Ping,
};

const max_frame = arp.max_frame;
const loop_slots = 64;
const udp_queue_bytes = 64 * 1024;

pub const Stack = struct {
    allocator: std.mem.Allocator,
    mac: Mac,
    mtu: u16,
    tcp_cfg: tcp.Config,
    output: Output,
    static: ?IfConfig,
    ifc: ?IfConfig = null,
    now: u64,
    prng: std.Random.DefaultPrng,
    ip_id: u16 = 0,
    arp: arp.Cache,
    socks: std.ArrayList(?*Sock) = .empty,
    dhcp_on: bool,
    dhcp_client: dhcp.Client,
    resolver: dns.Resolver,
    dns_port: u16,
    loop_frames: []u8,
    loop_lens: [loop_slots]u16 = undefined,
    loop_head: usize = 0,
    loop_count: usize = 0,
    stats: Stats = .{},
    /// The frame being built.
    tx: [max_frame]u8 align(4) = undefined,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, now: u64) !*Stack {
        const self = try allocator.create(Stack);
        errdefer allocator.destroy(self);
        var cache = try arp.Cache.init(allocator);
        errdefer cache.deinit(allocator);
        const loop = try allocator.alloc(u8, loop_slots * max_frame);
        errdefer allocator.free(loop);
        self.* = .{
            .allocator = allocator,
            .mac = cfg.mac,
            .mtu = @min(cfg.mtu, max_frame - wire.eth_hlen),
            .tcp_cfg = cfg.tcp,
            .output = cfg.output,
            .static = cfg.static,
            .now = now,
            .prng = std.Random.DefaultPrng.init(cfg.seed),
            .arp = cache,
            .dhcp_on = cfg.dhcp,
            .dhcp_client = dhcp.Client.init(cfg.mac, cfg.seed, cfg.hostname),
            .resolver = dns.Resolver.init(cfg.seed),
            .dns_port = 0,
            .loop_frames = loop,
        };
        self.dns_port = 49152 + self.random().uintLessThan(u16, 16384);
        if (cfg.dhcp) {
            self.dhcp_client.retry_ms = cfg.dhcp_retry_ms;
            self.dhcp_client.fallback_after = if (cfg.static != null) cfg.dhcp_fallback_after else 0;
            self.dhcp_client.start(now);
        } else if (cfg.static) |s| {
            self.configure(s);
        }
        return self;
    }

    pub fn deinit(self: *Stack) void {
        for (self.socks.items, 0..) |s, i| if (s != null) self.freeSock(@intCast(i + 1));
        self.socks.deinit(self.allocator);
        self.arp.deinit(self.allocator);
        self.allocator.free(self.loop_frames);
        self.allocator.destroy(self);
    }

    pub fn random(self: *Stack) std.Random {
        return self.prng.random();
    }

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// Set the interface address (and announce it with a gratuitous ARP).
    pub fn configure(self: *Stack, c: IfConfig) void {
        self.ifc = c;
        self.resolver.setServers(c.dnsServers());
        self.resolver.flushCache();
        self.sendArp(wire.arp_request, Mac.zero, c.ip);
    }

    pub fn unconfigure(self: *Stack) void {
        self.ifc = null;
        self.resolver.setServers(&.{});
    }

    /// The current address configuration, if any.
    pub fn config(self: *const Stack) ?IfConfig {
        return self.ifc;
    }

    /// DHCP client state, or null when DHCP is not used.
    pub fn dhcpState(self: *const Stack) ?DhcpState {
        return if (self.dhcp_on) self.dhcp_client.state else null;
    }

    /// The current DHCP lease and the milliseconds it has left.
    pub fn dhcpLease(self: *const Stack) ?struct { lease: Lease, remaining_ms: u64 } {
        const c = &self.dhcp_client;
        switch (c.state) {
            .bound, .renewing, .rebinding => {},
            else => return null,
        }
        const end = c.bound_at + @as(u64, c.lease.lease_s) * 1000;
        return .{ .lease = c.lease, .remaining_ms = end -| self.now };
    }

    fn isOurs(self: *const Stack, ip: Ip4) bool {
        const c = self.ifc orelse return false;
        return ip.eql(c.ip);
    }

    fn isBroadcastAddr(self: *const Stack, ip: Ip4) bool {
        if (ip.isBroadcast()) return true;
        const c = self.ifc orelse return false;
        return ip.eql(Ip4.subnetBroadcast(c.ip, c.netmask));
    }

    fn nextHop(self: *const Stack, dst: Ip4) Error!Ip4 {
        const c = self.ifc orelse return error.NoRoute;
        if (dst.sameSubnet(c.ip, c.netmask)) return dst;
        if (c.gateway.isAny()) return error.NoRoute;
        return c.gateway;
    }

    /// Source address for packets to `dst`.
    fn sourceFor(self: *const Stack, dst: Ip4) Error!Ip4 {
        if (dst.isLoopback()) return Ip4.loopback;
        if (self.ifc) |c| return c.ip;
        if (dst.isBroadcast()) return Ip4.any;
        return error.NoRoute;
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    /// Where transport headers and payload of the next packet go.
    pub fn l4Buffer(self: *Stack) []u8 {
        return self.tx[wire.eth_hlen + wire.ip4_hlen .. wire.eth_hlen + self.mtu];
    }

    fn emit(self: *Stack, frame: []const u8) void {
        self.stats.tx_frames += 1;
        self.stats.tx_bytes += frame.len;
        if (frame.len < wire.eth_min) {
            var pad = [_]u8{0} ** wire.eth_min;
            @memcpy(pad[0..frame.len], frame);
            return self.output.send(self.output.ctx, &pad);
        }
        self.output.send(self.output.ctx, frame);
    }

    /// Send the `l4_len` bytes at `l4Buffer()` as an IPv4 packet.
    pub fn ipSend(self: *Stack, dst: Ip4, proto: u8, l4_len: usize, src: Ip4) Error!void {
        if (wire.ip4_hlen + l4_len > self.mtu) return error.MessageTooLong;
        const frame = self.tx[0 .. wire.eth_hlen + wire.ip4_hlen + l4_len];
        self.ip_id +%= 1;
        wire.writeIp4(frame[wire.eth_hlen..], src, dst, proto, l4_len, self.ip_id, 64);
        if (dst.isLoopback() or self.isOurs(dst)) {
            wire.writeEth(frame, self.mac, self.mac, wire.ethertype_ip4);
            self.loopPush(frame);
            return;
        }
        var mac = Mac.broadcast;
        if (!self.isBroadcastAddr(dst)) {
            const hop = try self.nextHop(dst);
            mac = self.arp.lookup(hop, self.now) orelse {
                wire.writeEth(frame, Mac.zero, self.mac, wire.ethertype_ip4);
                self.arp.enqueue(hop, frame);
                if (self.arp.resolve(hop, self.now)) self.sendArp(wire.arp_request, Mac.zero, hop);
                return;
            };
        }
        wire.writeEth(frame, mac, self.mac, wire.ethertype_ip4);
        self.emit(frame);
    }

    fn sendArp(self: *Stack, op: u16, tha: Mac, tpa: Ip4) void {
        var f: [wire.eth_hlen + wire.arp_len]u8 = undefined;
        const spa = if (self.ifc) |c| c.ip else Ip4.any;
        wire.writeEth(&f, if (op == wire.arp_request) Mac.broadcast else tha, self.mac, wire.ethertype_arp);
        (wire.Arp{ .op = op, .sha = self.mac, .spa = spa, .tha = tha, .tpa = tpa }).write(f[wire.eth_hlen..]);
        self.emit(&f);
    }

    fn loopPush(self: *Stack, frame: []const u8) void {
        if (self.loop_count == loop_slots) {
            self.stats.rx_dropped += 1;
            return;
        }
        const slot = (self.loop_head + self.loop_count) % loop_slots;
        @memcpy(self.loop_frames[slot * max_frame ..][0..frame.len], frame);
        self.loop_lens[slot] = @intCast(frame.len);
        self.loop_count += 1;
    }

    fn udpSendFrom(self: *Stack, src: Ip4, sport: u16, dst: Ip4, dport: u16, data: []const u8) Error!void {
        if (wire.ip4_hlen + wire.udp_hlen + data.len > self.mtu) return error.MessageTooLong;
        const buf = self.l4Buffer();
        @memcpy(buf[wire.udp_hlen..][0..data.len], data);
        wire.writeUdp(buf, src, dst, sport, dport, data.len);
        try self.ipSend(dst, wire.proto_udp, wire.udp_hlen + data.len, src);
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    /// Process one received Ethernet frame.
    pub fn input(self: *Stack, frame: []const u8, now: u64) void {
        self.now = @max(self.now, now);
        self.stats.rx_frames += 1;
        self.stats.rx_bytes += frame.len;
        self.handleFrame(frame, false);
        self.reap();
    }

    fn handleFrame(self: *Stack, frame: []const u8, looped: bool) void {
        const eth = wire.Eth.parse(frame) orelse return self.drop();
        if (!looped and !eth.dst.eql(self.mac) and !eth.dst.isBroadcast()) return self.drop();
        switch (eth.ethertype) {
            wire.ethertype_arp => self.arpInput(eth.payload),
            wire.ethertype_ip4 => self.ipInput(eth.payload, looped),
            else => self.drop(),
        }
    }

    fn drop(self: *Stack) void {
        self.stats.rx_dropped += 1;
    }

    fn arpInput(self: *Stack, p: []const u8) void {
        const a = wire.Arp.parse(p) orelse return self.drop();
        const for_us = self.isOurs(a.tpa);
        if (self.arp.update(a.spa, a.sha, self.now, for_us)) {
            while (self.arp.takePending(a.spa)) |f| {
                f[0..6].* = a.sha.bytes;
                self.emit(f);
            }
        }
        if (a.op == wire.arp_request and for_us) self.sendArp(wire.arp_reply, a.sha, a.spa);
    }

    fn ipInput(self: *Stack, p: []const u8, looped: bool) void {
        const pkt = wire.Ip4Packet.parse(p) orelse return self.drop();
        if (pkt.fragment) return self.drop();
        if (!looped and (pkt.dst.isLoopback() or pkt.src.isLoopback())) return self.drop();
        const to_us = looped or self.isOurs(pkt.dst) or self.isBroadcastAddr(pkt.dst);
        switch (pkt.proto) {
            wire.proto_icmp => if (to_us) self.icmpInput(pkt),
            wire.proto_udp => self.udpInput(pkt, to_us),
            wire.proto_tcp => if (to_us and !self.isBroadcastAddr(pkt.dst)) self.tcpInput(pkt),
            else => self.drop(),
        }
    }

    fn icmpInput(self: *Stack, pkt: wire.Ip4Packet) void {
        const m = wire.Icmp.parse(pkt.payload) orelse return self.drop();
        switch (m.kind) {
            wire.icmp_echo_request => {
                if (self.isBroadcastAddr(pkt.dst)) return;
                if (wire.ip4_hlen + wire.icmp_hlen + m.data.len > self.mtu) return;
                const buf = self.l4Buffer();
                @memcpy(buf[wire.icmp_hlen..][0..m.data.len], m.data);
                wire.writeIcmp(buf, wire.icmp_echo_reply, 0, m.id, m.seq, m.data.len);
                self.ipSend(pkt.src, wire.proto_icmp, wire.icmp_hlen + m.data.len, pkt.dst) catch {};
            },
            wire.icmp_echo_reply => {
                for (self.socks.items) |s| {
                    const sock = s orelse continue;
                    if (sock.* != .ping or sock.ping.id != m.id) continue;
                    const pg = &sock.ping;
                    if (pg.count == ping_queue) {
                        pg.head = (pg.head + 1) % ping_queue;
                        pg.count -= 1;
                    }
                    pg.replies[(pg.head + pg.count) % ping_queue] = .{ .from = pkt.src, .seq = m.seq, .ttl = pkt.ttl, .len = m.data.len, .time = self.now };
                    pg.count += 1;
                    return;
                }
            },
            wire.icmp_unreachable => self.icmpError(m),
            else => {},
        }
    }

    /// Destination unreachable: fail connection attempts it refers to.
    fn icmpError(self: *Stack, m: wire.Icmp) void {
        const d = m.data;
        if (d.len < wire.ip4_hlen) return;
        const ihl = @as(usize, d[0] & 0xf) * 4;
        if (ihl < wire.ip4_hlen or d.len < ihl + 8 or d[9] != wire.proto_tcp) return;
        const remote = Ip4{ .bytes = d[16..20].* };
        const sport = std.mem.readInt(u16, d[ihl..][0..2], .big);
        const dport = std.mem.readInt(u16, d[ihl + 2 ..][0..2], .big);
        for (self.socks.items) |s| {
            const sock = s orelse continue;
            if (sock.* != .tcp) continue;
            const t = &sock.tcp;
            if (t.state != .syn_sent or t.local_port != sport or t.remote_port != dport or !t.remote_ip.eql(remote)) continue;
            tcp.failConnect(t, if (m.code == wire.icmp_port_unreachable or m.code == 2) error.ConnectionRefused else error.HostUnreachable);
        }
    }

    fn udpInput(self: *Stack, pkt: wire.Ip4Packet, to_us: bool) void {
        const u = wire.Udp.parse(pkt.src, pkt.dst, pkt.payload) orelse return self.drop();
        if (self.dhcp_on and u.dst_port == dhcp.client_port and u.src_port == dhcp.server_port) {
            self.dhcpAction(self.dhcp_client.input(u.payload, self.now));
            return;
        }
        if (!to_us) return self.drop();
        if (u.dst_port == self.dns_port and u.src_port == dns.port) {
            self.resolver.input(pkt.src, u.payload, self.now);
            return;
        }
        for (self.socks.items) |s| {
            const sock = s orelse continue;
            if (sock.* != .udp or sock.udp.port != u.dst_port) continue;
            const q = &sock.udp.queue;
            if (q.free() < 8 + u.payload.len) return self.drop();
            var hdr: [8]u8 = undefined;
            hdr[0..4].* = pkt.src.bytes;
            std.mem.writeInt(u16, hdr[4..6], u.src_port, .big);
            std.mem.writeInt(u16, hdr[6..8], @intCast(u.payload.len), .big);
            _ = q.write(&hdr);
            _ = q.write(u.payload);
            return;
        }
        if (self.isBroadcastAddr(pkt.dst)) return;
        // Port unreachable: quote the IP header and 8 bytes.
        const buf = self.l4Buffer();
        const quote = @min(pkt.payload.len, 8);
        @memcpy(buf[wire.icmp_hlen..][0..pkt.header.len], pkt.header);
        @memcpy(buf[wire.icmp_hlen + pkt.header.len ..][0..quote], pkt.payload[0..quote]);
        const len = pkt.header.len + quote;
        wire.writeIcmp(buf, wire.icmp_unreachable, wire.icmp_port_unreachable, 0, 0, len);
        self.ipSend(pkt.src, wire.proto_icmp, wire.icmp_hlen + len, pkt.dst) catch {};
    }

    fn tcpInput(self: *Stack, pkt: wire.Ip4Packet) void {
        const seg = wire.Tcp.parse(pkt.src, pkt.dst, pkt.payload) orelse return self.drop();
        var listener: Handle = 0;
        for (self.socks.items, 0..) |s, i| {
            const sock = s orelse continue;
            if (sock.* != .tcp) continue;
            const t = &sock.tcp;
            if (t.local_port != seg.dst_port) continue;
            if (t.state == .listen) {
                listener = @intCast(i + 1);
                continue;
            }
            if (t.state == .closed or t.remote_port != seg.src_port or !t.remote_ip.eql(pkt.src) or !t.local_ip.eql(pkt.dst)) continue;
            return tcp.input(self, t, seg);
        }
        if (listener != 0) return tcp.listenInput(self, listener, pkt.dst, pkt.src, seg);
        tcp.sendReset(self, pkt.dst, pkt.src, seg);
    }

    fn dhcpAction(self: *Stack, act: dhcp.Action) void {
        switch (act) {
            .none => {},
            .send => |m| {
                const src = if (m.unconfigured or self.ifc == null) Ip4.any else self.ifc.?.ip;
                self.udpSendFrom(src, dhcp.client_port, m.dst, dhcp.server_port, self.dhcp_client.msg[0..m.len]) catch {};
            },
            .bound => |l| self.configure(.{ .ip = l.ip, .netmask = l.netmask, .gateway = l.gateway, .dns = l.dns, .dns_count = l.dns_count }),
            .lost => self.unconfigure(),
            .fallback => if (self.static) |s| self.configure(s),
        }
    }

    fn dnsSend(ctx: *anyopaque, server: Ip4, msg: []const u8) void {
        const self: *Stack = @ptrCast(@alignCast(ctx));
        const src = self.sourceFor(server) catch return;
        self.udpSendFrom(src, self.dns_port, server, dns.port, msg) catch {};
    }

    // -----------------------------------------------------------------------
    // Timers
    // -----------------------------------------------------------------------

    /// Run timers and deliver looped-back packets.
    pub fn poll(self: *Stack, now: u64) void {
        self.now = @max(self.now, now);
        var n = self.loop_count;
        while (n > 0) : (n -= 1) {
            const slot = self.loop_head;
            // Process in place: the slot stays reserved until popped.
            self.handleFrame(self.loop_frames[slot * max_frame ..][0..self.loop_lens[slot]], true);
            self.loop_head = (self.loop_head + 1) % loop_slots;
            self.loop_count -= 1;
        }
        while (true) switch (self.arp.poll(self.now)) {
            .none => break,
            .request => |ip| self.sendArp(wire.arp_request, Mac.zero, ip),
            .failed => |ip| self.arpFailed(ip),
        };
        if (self.dhcp_on) {
            var guard: usize = 0;
            while (guard < 8) : (guard += 1) {
                const act = self.dhcp_client.poll(self.now);
                if (act == .none) break;
                self.dhcpAction(act);
            }
        }
        self.resolver.poll(self.now, self, dnsSend);
        var i: usize = 0;
        while (i < self.socks.items.len) : (i += 1) {
            const sock = self.socks.items[i] orelse continue;
            if (sock.* == .tcp) tcp.timers(self, &sock.tcp);
        }
        self.reap();
    }

    /// Milliseconds until `poll` has work to do (0 = now, null = no timers).
    pub fn nextTimeout(self: *const Stack, now: u64) ?u64 {
        if (self.loop_count > 0) return 0;
        var best: ?u64 = null;
        const consider = struct {
            fn f(b: *?u64, d: ?u64) void {
                const v = d orelse return;
                b.* = if (b.*) |x| @min(x, v) else v;
            }
        }.f;
        consider(&best, self.arp.nextDeadline());
        if (self.dhcp_on) consider(&best, self.dhcp_client.nextDeadline());
        consider(&best, self.resolver.nextDeadline());
        for (self.socks.items) |s| {
            const sock = s orelse continue;
            if (sock.* == .tcp) consider(&best, sock.tcp.nextDeadline());
        }
        const d = best orelse return null;
        return d -| now;
    }

    fn arpFailed(self: *Stack, ip: Ip4) void {
        for (self.socks.items) |s| {
            const sock = s orelse continue;
            if (sock.* != .tcp) continue;
            const t = &sock.tcp;
            if (t.state != .syn_sent) continue;
            const hop = self.nextHop(t.remote_ip) catch continue;
            if (hop.eql(ip)) tcp.failConnect(t, error.HostUnreachable);
        }
    }

    /// Free finished connections nobody holds.
    fn reap(self: *Stack) void {
        for (self.socks.items, 0..) |s, i| {
            const sock = s orelse continue;
            if (sock.* != .tcp) continue;
            const t = &sock.tcp;
            if (t.state != .closed or !(t.detached or t.parent != 0)) continue;
            const h: Handle = @intCast(i + 1);
            if (t.parent != 0) {
                if (self.tcb(t.parent)) |l| {
                    for (l.queue.items, 0..) |q, k| if (q == h) {
                        _ = l.queue.orderedRemove(k);
                        break;
                    };
                }
            }
            self.freeSock(h);
        }
    }

    // -----------------------------------------------------------------------
    // Socket table
    // -----------------------------------------------------------------------

    fn newSock(self: *Stack, value: Sock) Error!Handle {
        const sock = try self.allocator.create(Sock);
        errdefer self.allocator.destroy(sock);
        sock.* = value;
        for (self.socks.items, 0..) |s, i| if (s == null) {
            self.socks.items[i] = sock;
            return @intCast(i + 1);
        };
        try self.socks.append(self.allocator, sock);
        return @intCast(self.socks.items.len);
    }

    pub fn freeSock(self: *Stack, h: Handle) void {
        const sock = self.socks.items[h - 1] orelse return;
        switch (sock.*) {
            .tcp => |*t| t.deinit(self.allocator),
            .udp => |*u| u.queue.deinit(self.allocator),
            .ping => {},
        }
        self.allocator.destroy(sock);
        self.socks.items[h - 1] = null;
    }

    fn lookupSock(self: *Stack, h: Handle) ?*Sock {
        if (h == 0 or h > self.socks.items.len) return null;
        return self.socks.items[h - 1];
    }

    pub fn tcb(self: *Stack, h: Handle) ?*tcp.Tcb {
        const s = self.lookupSock(h) orelse return null;
        return if (s.* == .tcp) &s.tcp else null;
    }

    /// A connection block with its buffers.
    pub fn newTcb(self: *Stack) Error!Handle {
        var t = tcp.Tcb{ .rto = self.tcp_cfg.rto_initial_ms };
        try t.allocBuffers(self.allocator, self.tcp_cfg);
        errdefer t.deinit(self.allocator);
        return self.newSock(.{ .tcp = t });
    }

    fn portInUse(self: *Stack, port: u16, kind: std.meta.Tag(Sock)) bool {
        for (self.socks.items) |s| {
            const so = s orelse continue;
            switch (so.*) {
                .tcp => |*t| if (kind == .tcp and t.local_port == port) return true,
                .udp => |*u| if (kind == .udp and u.port == port) return true,
                .ping => {},
            }
        }
        return kind == .udp and port == self.dns_port;
    }

    fn ephemeralPort(self: *Stack, kind: std.meta.Tag(Sock)) Error!u16 {
        var port: u16 = 49152 + self.random().uintLessThan(u16, 16384);
        for (0..16384) |_| {
            if (!self.portInUse(port, kind)) return port;
            port = if (port == 65535) 49152 else port + 1;
        }
        return error.AddressInUse;
    }

    // -----------------------------------------------------------------------
    // TCP sockets
    // -----------------------------------------------------------------------

    /// Start connecting to `dst:port`. Watch `ready`/`tcpState` for the
    /// result; failures are reported by `tcpError`.
    pub fn tcpConnect(self: *Stack, dst: Ip4, port: u16) Error!Handle {
        const src = try self.sourceFor(dst);
        if (!dst.isLoopback() and !self.isOurs(dst)) _ = try self.nextHop(dst);
        const lport = try self.ephemeralPort(.tcp);
        const h = try self.newTcb();
        const t = self.tcb(h).?;
        t.local_ip = src;
        t.local_port = lport;
        t.remote_ip = dst;
        t.remote_port = port;
        tcp.connect(self, t);
        return h;
    }

    /// Listen on `port` (0 = pick one; see `localEndpoint`).
    pub fn tcpListen(self: *Stack, port: u16, backlog: u16) Error!Handle {
        const p = if (port == 0) try self.ephemeralPort(.tcp) else port;
        for (self.socks.items) |s| {
            const so = s orelse continue;
            if (so.* == .tcp and so.tcp.state == .listen and so.tcp.local_port == p) return error.AddressInUse;
        }
        return self.newSock(.{ .tcp = .{ .state = .listen, .local_port = p, .backlog = @max(backlog, 1) } });
    }

    /// Take an established connection from a listener, if one is waiting.
    pub fn tcpAccept(self: *Stack, h: Handle) Error!?Handle {
        const l = self.tcb(h) orelse return error.BadHandle;
        if (l.state != .listen) return error.NotConnected;
        for (l.queue.items, 0..) |c, i| {
            const t = self.tcb(c) orelse continue;
            switch (t.state) {
                .syn_received => continue,
                .closed => continue,
                else => {},
            }
            _ = l.queue.orderedRemove(i);
            t.parent = 0;
            return c;
        }
        return null;
    }

    pub fn tcpState(self: *Stack, h: Handle) tcp.State {
        const t = self.tcb(h) orelse return .closed;
        return t.state;
    }

    pub fn tcpError(self: *Stack, h: Handle) ?Error {
        const t = self.tcb(h) orelse return error.BadHandle;
        return if (t.err) |e| e else null;
    }

    /// Queue data for sending; returns the count accepted.
    pub fn send(self: *Stack, h: Handle, data: []const u8) Error!usize {
        const t = self.tcb(h) orelse return error.BadHandle;
        if (t.err) |e| return e;
        switch (t.state) {
            .syn_sent, .syn_received, .established, .close_wait => {},
            else => return error.NotConnected,
        }
        if (t.fin_requested) return error.NotConnected;
        if (data.len == 0) return 0;
        const n = t.sndbuf.write(data);
        if (n == 0) return error.WouldBlock;
        tcp.output(self, t);
        return n;
    }

    /// Read received data: 0 at end of stream, WouldBlock when none yet.
    pub fn recv(self: *Stack, h: Handle, buf: []u8) Error!usize {
        const t = self.tcb(h) orelse return error.BadHandle;
        if (t.rcvbuf.len > 0) {
            const n = t.rcvbuf.read(buf);
            // Open the window again once it has grown enough to matter.
            if (t.state.synchronized() and !t.peer_fin) {
                const edge = t.rcv_nxt +% t.rcvWindow();
                const grown = edge -% t.rcv_adv;
                if (@as(i32, @bitCast(grown)) > 0 and grown >= @min(2 * @as(u32, t.mss), @as(u32, @intCast(t.rcvbuf.capacity() / 2)))) {
                    t.ack_now = true;
                    tcp.output(self, t);
                }
            }
            return n;
        }
        if (t.peer_fin) return 0;
        if (t.err) |e| return e;
        return switch (t.state) {
            .closed, .listen => error.NotConnected,
            .time_wait, .closing, .last_ack, .close_wait => 0,
            else => error.WouldBlock,
        };
    }

    pub fn bytesAvailable(self: *Stack, h: Handle) usize {
        const t = self.tcb(h) orelse return 0;
        return t.rcvbuf.len;
    }

    /// Close the sending side (FIN after the queued data); reading goes on.
    pub fn shutdown(self: *Stack, h: Handle) void {
        const t = self.tcb(h) orelse return;
        tcp.shutdown(self, t);
    }

    /// Send a reset and drop the connection.
    pub fn abort(self: *Stack, h: Handle) void {
        const t = self.tcb(h) orelse return;
        tcp.abort(self, t);
    }

    /// Release a socket. TCP connections close gracefully in the
    /// background; listeners reset their unaccepted connections.
    pub fn close(self: *Stack, h: Handle) void {
        const s = self.lookupSock(h) orelse return;
        if (s.* != .tcp) return self.freeSock(h);
        const t = &s.tcp;
        if (t.state == .listen) {
            for (t.queue.items) |c| {
                if (self.tcb(c)) |ct| tcp.abort(self, ct);
                self.freeSock(c);
            }
            return self.freeSock(h);
        }
        t.detached = true;
        t.rcvbuf.clear();
        switch (t.state) {
            .closed, .syn_sent => return self.freeSock(h),
            .fin_wait_2 => t.linger_deadline = self.now + self.tcp_cfg.fin_wait2_ms,
            else => tcp.shutdown(self, t),
        }
        self.reap();
    }

    pub fn localEndpoint(self: *Stack, h: Handle) ?Endpoint {
        const s = self.lookupSock(h) orelse return null;
        return switch (s.*) {
            .tcp => |*t| .{ .ip = t.local_ip, .port = t.local_port },
            .udp => |*u| .{ .ip = if (self.ifc) |c| c.ip else Ip4.any, .port = u.port },
            .ping => null,
        };
    }

    pub fn remoteEndpoint(self: *Stack, h: Handle) ?Endpoint {
        const t = self.tcb(h) orelse return null;
        if (t.state == .listen) return null;
        return .{ .ip = t.remote_ip, .port = t.remote_port };
    }

    /// Readiness of any socket (for poll and deferred requests).
    pub fn ready(self: *Stack, h: Handle) Ready {
        const s = self.lookupSock(h) orelse return .{ .err = true, .hup = true };
        switch (s.*) {
            .udp => |*u| return .{ .in = u.queue.len > 0, .out = true },
            .ping => |*p| return .{ .in = p.count > 0, .out = true },
            .tcp => |*t| {
                if (t.state == .listen) {
                    for (t.queue.items) |c| {
                        const ct = self.tcb(c) orelse continue;
                        if (ct.state != .syn_received and ct.state != .closed) return .{ .in = true };
                    }
                    return .{};
                }
                const failed = t.err != null;
                const gone = failed or t.state == .closed;
                const sending = switch (t.state) {
                    .established, .close_wait => !t.fin_requested,
                    else => false,
                };
                return .{
                    .in = t.rcvbuf.len > 0 or t.peer_fin or gone,
                    .out = (sending and t.sndbuf.free() > 0) or gone,
                    .hup = t.peer_fin or gone,
                    .err = failed,
                };
            },
        }
    }

    // -----------------------------------------------------------------------
    // UDP sockets
    // -----------------------------------------------------------------------

    /// Bind a UDP socket to `port` (0 = ephemeral).
    pub fn udpOpen(self: *Stack, port: u16) Error!Handle {
        const p = if (port == 0) try self.ephemeralPort(.udp) else port;
        if (port != 0 and self.portInUse(p, .udp)) return error.AddressInUse;
        var q = try Ring.init(self.allocator, udp_queue_bytes);
        errdefer q.deinit(self.allocator);
        return self.newSock(.{ .udp = .{ .port = p, .queue = q } });
    }

    pub fn udpSendTo(self: *Stack, h: Handle, dst: Ip4, port: u16, data: []const u8) Error!void {
        const s = self.lookupSock(h) orelse return error.BadHandle;
        if (s.* != .udp) return error.BadHandle;
        const src = try self.sourceFor(dst);
        try self.udpSendFrom(src, s.udp.port, dst, port, data);
    }

    /// Take the next datagram (copied into `buf`, truncated if needed).
    pub fn udpRecvFrom(self: *Stack, h: Handle, buf: []u8) ?Datagram {
        const s = self.lookupSock(h) orelse return null;
        if (s.* != .udp) return null;
        const q = &s.udp.queue;
        if (q.len < 8) return null;
        var hdr: [8]u8 = undefined;
        _ = q.read(&hdr);
        const len = std.mem.readInt(u16, hdr[6..8], .big);
        const n = @min(len, buf.len);
        _ = q.read(buf[0..n]);
        q.discard(len - n);
        return .{ .from = .{ .bytes = hdr[0..4].* }, .port = std.mem.readInt(u16, hdr[4..6], .big), .len = len };
    }

    // -----------------------------------------------------------------------
    // ICMP echo
    // -----------------------------------------------------------------------

    pub fn pingOpen(self: *Stack) Error!Handle {
        var id = self.random().int(u16);
        while (true) : (id +%= 1) {
            const used = for (self.socks.items) |s| {
                const so = s orelse continue;
                if (so.* == .ping and so.ping.id == id) break true;
            } else false;
            if (!used) break;
        }
        return self.newSock(.{ .ping = .{ .id = id } });
    }

    pub fn pingSend(self: *Stack, h: Handle, dst: Ip4, seq: u16, payload: []const u8) Error!void {
        const s = self.lookupSock(h) orelse return error.BadHandle;
        if (s.* != .ping) return error.BadHandle;
        if (wire.ip4_hlen + wire.icmp_hlen + payload.len > self.mtu) return error.MessageTooLong;
        const src = try self.sourceFor(dst);
        const buf = self.l4Buffer();
        @memcpy(buf[wire.icmp_hlen..][0..payload.len], payload);
        wire.writeIcmp(buf, wire.icmp_echo_request, 0, s.ping.id, seq, payload.len);
        try self.ipSend(dst, wire.proto_icmp, wire.icmp_hlen + payload.len, src);
    }

    pub fn pingRecv(self: *Stack, h: Handle) ?PingReply {
        const s = self.lookupSock(h) orelse return null;
        if (s.* != .ping) return null;
        const p = &s.ping;
        if (p.count == 0) return null;
        const r = p.replies[p.head];
        p.head = (p.head + 1) % ping_queue;
        p.count -= 1;
        return r;
    }

    // -----------------------------------------------------------------------
    // DNS
    // -----------------------------------------------------------------------

    /// Start resolving a name (A records); see `resolveStatus`.
    pub fn resolve(self: *Stack, name: []const u8) dns.Error!u16 {
        const id = try self.resolver.query(name, self.now);
        self.resolver.poll(self.now, self, dnsSend);
        return id;
    }

    pub fn resolveStatus(self: *Stack, id: u16) dns.Status {
        return self.resolver.status(id);
    }

    pub fn resolveRelease(self: *Stack, id: u16) void {
        self.resolver.release(id);
    }
};
