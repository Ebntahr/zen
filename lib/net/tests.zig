//! Stack tests: two stacks wired together by an in-memory Ethernet link
//! (optionally lossy) with simulated time.

const std = @import("std");
const wire = @import("wire.zig");
const dhcp = @import("dhcp.zig");
const dns = @import("dns.zig");
const stack_mod = @import("stack.zig");
const Stack = stack_mod.Stack;
const IfConfig = stack_mod.IfConfig;
const Handle = stack_mod.Handle;
const Ip4 = wire.Ip4;
const Mac = wire.Mac;

const testing = std.testing;

const ip_a = Ip4.init(10, 0, 0, 2);
const ip_b = Ip4.init(10, 0, 0, 1);
const mask = Ip4.init(255, 255, 255, 0);
const mac_a = Mac{ .bytes = .{ 2, 0, 0, 0, 0, 0xa } };
const mac_b = Mac{ .bytes = .{ 2, 0, 0, 0, 0, 0xb } };

const Link = struct {
    gpa: std.mem.Allocator,
    stacks: [2]*Stack = undefined,
    ports: [2]Port = undefined,
    /// queues[i]: frames on their way to side i.
    queues: [2]std.ArrayList([]u8) = .{ .empty, .empty },
    now: u64 = 0,
    /// Simulated time limit for `tick`.
    limit: u64 = 600_000,
    loss_permille: u32 = 0,
    down: bool = false,
    dropped: u64 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5eed),

    const Port = struct { link: *Link, side: u1 };

    const Options = struct {
        a: ?IfConfig = .{ .ip = ip_a, .netmask = mask, .gateway = ip_b },
        b: ?IfConfig = .{ .ip = ip_b, .netmask = mask },
        a_dhcp: bool = false,
        tcp: stack_mod.tcp.Config = .{ .time_wait_ms = 2000 },
    };

    fn init(gpa: std.mem.Allocator, o: Options) !*Link {
        const l = try gpa.create(Link);
        l.* = .{ .gpa = gpa };
        for (0..2) |i| l.ports[i] = .{ .link = l, .side = @intCast(i) };
        l.stacks[0] = try Stack.init(gpa, .{
            .mac = mac_a,
            .seed = 1,
            .output = .{ .ctx = &l.ports[0], .send = send },
            .static = o.a,
            .dhcp = o.a_dhcp,
            .dhcp_retry_ms = 1000,
            .tcp = o.tcp,
        }, 0);
        l.stacks[1] = try Stack.init(gpa, .{
            .mac = mac_b,
            .seed = 2,
            .output = .{ .ctx = &l.ports[1], .send = send },
            .static = o.b,
            .tcp = o.tcp,
        }, 0);
        return l;
    }

    fn deinit(l: *Link) void {
        for (l.stacks) |s| s.deinit();
        for (&l.queues) |*q| {
            for (q.items) |f| l.gpa.free(f);
            q.deinit(l.gpa);
        }
        l.gpa.destroy(l);
    }

    fn send(ctx: *anyopaque, frame: []const u8) void {
        const p: *Port = @ptrCast(@alignCast(ctx));
        const l = p.link;
        if (l.down or (l.loss_permille > 0 and l.prng.random().uintLessThan(u32, 1000) < l.loss_permille)) {
            l.dropped += 1;
            return;
        }
        const copy = l.gpa.dupe(u8, frame) catch return;
        l.queues[1 - p.side].append(l.gpa, copy) catch l.gpa.free(copy);
    }

    fn a(l: *Link) *Stack {
        return l.stacks[0];
    }

    fn b(l: *Link) *Stack {
        return l.stacks[1];
    }

    /// Deliver the frames in flight and run the timers that are due.
    /// Returns true while frames or immediate work remain.
    fn settle(l: *Link) bool {
        for (0..2) |i| {
            var q = l.queues[i];
            l.queues[i] = .empty;
            defer {
                for (q.items) |f| l.gpa.free(f);
                q.deinit(l.gpa);
            }
            for (q.items) |f| l.stacks[i].input(f, l.now);
        }
        for (l.stacks) |s| s.poll(l.now);
        if (l.queues[0].items.len + l.queues[1].items.len > 0) return true;
        for (l.stacks) |s| if (s.nextTimeout(l.now) == @as(?u64, 0)) return true;
        return false;
    }

    /// Absolute time of the next timer of either stack.
    fn nextTimer(l: *Link) ?u64 {
        var next: ?u64 = null;
        for (l.stacks) |s| if (s.nextTimeout(l.now)) |t| {
            next = if (next) |n| @min(n, l.now + t) else l.now + t;
        };
        return next;
    }

    /// One step: deliver frames, or advance the clock to the next timer.
    fn tick(l: *Link) !void {
        if (l.settle()) return;
        l.now = l.nextTimer() orelse l.now + 100;
        if (l.now > l.limit) return error.SimulatedTimeout;
    }

    /// Let `ms` of simulated time pass.
    fn runFor(l: *Link, ms: u64) !void {
        const end = l.now + ms;
        while (true) {
            if (l.settle()) continue;
            const next = l.nextTimer() orelse end;
            if (next >= end) {
                l.now = end;
                _ = l.settle();
                return;
            }
            l.now = next;
        }
    }
};

fn pattern(i: usize) u8 {
    return @truncate(i *% 131 +% (i >> 9) *% 7 +% 3);
}

test "arp resolution and ping both ways" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const pa = try l.a().pingOpen();
    try l.a().pingSend(pa, ip_b, 1, "zen-ping");
    // The first packet waits for ARP; it goes out once B answers.
    while (true) {
        if (l.a().pingRecv(pa)) |r| {
            try testing.expect(r.from.eql(ip_b));
            try testing.expectEqual(@as(u16, 1), r.seq);
            try testing.expectEqual(@as(usize, 8), r.len);
            try testing.expectEqual(@as(u8, 64), r.ttl);
            break;
        }
        try l.tick();
    }
    try testing.expect(l.a().arp.lookup(ip_b, l.now).?.eql(mac_b));
    // B learnt A from A's request.
    try testing.expect(l.b().arp.lookup(ip_a, l.now).?.eql(mac_a));
    const pb = try l.b().pingOpen();
    for (1..4) |seq| try l.b().pingSend(pb, ip_a, @intCast(seq), "x" ** 56);
    var got: usize = 0;
    while (got < 3) : (try l.tick()) {
        while (l.b().pingRecv(pb)) |r| {
            got += 1;
            try testing.expectEqual(@as(u16, @intCast(got)), r.seq);
            try testing.expectEqual(@as(usize, 56), r.len);
        }
    }
    // An unanswered ARP request gives up after three tries.
    try l.a().pingSend(pa, Ip4.init(10, 0, 0, 77), 9, "?");
    try l.runFor(5000);
    try testing.expect(l.a().pingRecv(pa) == null);
    try testing.expect(l.a().arp.nextDeadline() == null);
}

test "udp datagrams both ways" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const ua = try l.a().udpOpen(5000);
    const ub = try l.b().udpOpen(0);
    try testing.expectError(error.AddressInUse, l.a().udpOpen(5000));
    const pb = l.b().localEndpoint(ub).?.port;
    try testing.expect(pb >= 49152);
    try l.a().udpSendTo(ua, ip_b, pb, "hello from a");
    var buf: [2000]u8 = undefined;
    while (true) : (try l.tick()) {
        if (l.b().udpRecvFrom(ub, &buf)) |d| {
            try testing.expect(d.from.eql(ip_a));
            try testing.expectEqual(@as(u16, 5000), d.port);
            try testing.expectEqualStrings("hello from a", buf[0..d.len]);
            // Reply to the sender.
            try l.b().udpSendTo(ub, d.from, d.port, "hello from b");
            break;
        }
    }
    while (true) : (try l.tick()) {
        if (l.a().udpRecvFrom(ua, &buf)) |d| {
            try testing.expectEqual(pb, d.port);
            try testing.expectEqualStrings("hello from b", buf[0..d.len]);
            break;
        }
    }
    // The largest datagram that fits, and one byte more.
    const big = [_]u8{0x5a} ** 1472;
    try l.a().udpSendTo(ua, ip_b, pb, &big);
    try testing.expectError(error.MessageTooLong, l.a().udpSendTo(ua, ip_b, pb, &(big ++ [_]u8{1})));
    while (true) : (try l.tick()) {
        if (l.b().udpRecvFrom(ub, &buf)) |d| {
            try testing.expectEqual(@as(usize, 1472), d.len);
            try testing.expectEqualSlices(u8, &big, buf[0..d.len]);
            break;
        }
    }
    // A truncated read reports the full length and drops the rest.
    try l.a().udpSendTo(ua, ip_b, pb, "0123456789");
    try l.a().udpSendTo(ua, ip_b, pb, "next");
    try l.runFor(10);
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), l.b().udpRecvFrom(ub, &small).?.len);
    try testing.expectEqualStrings("0123", &small);
    try testing.expectEqualStrings("next", buf[0..l.b().udpRecvFrom(ub, &buf).?.len]);
}

/// Connect A to B's listener on `port` and return (client, server).
fn connectPair(l: *Link, port: u16) ![2]Handle {
    const lh = try l.b().tcpListen(port, 4);
    const c = try l.a().tcpConnect(ip_b, port);
    while (true) : (try l.tick()) {
        if (try l.b().tcpAccept(lh)) |srv| {
            while (l.a().tcpState(c) != .established) try l.tick();
            l.b().close(lh);
            return .{ c, srv };
        }
    }
}

/// Move `total` bytes each way at the same time and check every byte.
fn transfer(l: *Link, c: Handle, s: Handle, total: usize) !void {
    var sent = [2]usize{ 0, 0 };
    var recvd = [2]usize{ 0, 0 };
    const ends = [2]Handle{ c, s };
    const stacks = [2]*Stack{ l.a(), l.b() };
    var buf: [8192]u8 = undefined;
    var chunk: [4096]u8 = undefined;
    while (recvd[0] < total or recvd[1] < total) {
        for (0..2) |i| {
            while (sent[i] < total) {
                const n = @min(chunk.len, total - sent[i]);
                for (0..n) |k| chunk[k] = pattern(sent[i] + k + i);
                const w = stacks[i].send(ends[i], chunk[0..n]) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                sent[i] += w;
            }
            while (true) {
                const n = stacks[i].recv(ends[i], &buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                try testing.expect(n > 0);
                // Side i receives what the other side (1 - i) sent.
                for (buf[0..n], 0..) |byte, k| try testing.expectEqual(pattern(recvd[i] + k + (1 - i)), byte);
                recvd[i] += n;
            }
        }
        try l.tick();
    }
}

test "tcp handshake, 1 MiB each way over a lossy link, and close" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const pair = try connectPair(l, 80);
    const c = pair[0];
    const s = pair[1];
    try testing.expectEqual(@as(u16, 80), l.a().remoteEndpoint(c).?.port);
    try testing.expect(l.b().remoteEndpoint(s).?.ip.eql(ip_a));
    try testing.expectEqual(@as(u16, 1460), l.a().tcb(c).?.mss);
    l.loss_permille = 30;
    try transfer(l, c, s, 1 << 20);
    try testing.expect(l.dropped > 50);
    l.loss_permille = 0;
    // A closes first: B sees EOF, then closes too.
    l.a().shutdown(c);
    var buf: [16]u8 = undefined;
    while (true) : (try l.tick()) {
        const n = l.b().recv(s, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        try testing.expectEqual(@as(usize, 0), n);
        break;
    }
    try testing.expectEqual(stack_mod.tcp.State.close_wait, l.b().tcpState(s));
    try testing.expect(l.b().ready(s).hup);
    while (l.a().tcpState(c) == .fin_wait_1) try l.tick();
    try testing.expectEqual(stack_mod.tcp.State.fin_wait_2, l.a().tcpState(c));
    // B can still send after A's FIN (half close).
    _ = try l.b().send(s, "bye");
    l.b().close(s);
    while (l.a().tcpState(c) != .time_wait) try l.tick();
    const entered = l.now;
    const expiry = l.a().tcb(c).?.linger_deadline;
    const n = try l.a().recv(c, &buf);
    try testing.expectEqualStrings("bye", buf[0..n]);
    try testing.expectEqual(@as(usize, 0), try l.a().recv(c, &buf));
    // B's side is gone; A leaves TIME_WAIT after 2 MSL (2 s here).
    try testing.expect(expiry >= entered and expiry <= entered + 2000);
    try testing.expectEqual(stack_mod.tcp.State.time_wait, l.a().tcpState(c));
    try l.runFor(expiry - l.now + 1);
    try testing.expectEqual(stack_mod.tcp.State.closed, l.a().tcpState(c));
    l.a().close(c);
    for (l.b().socks.items) |sock| try testing.expect(sock == null);
    for (l.a().socks.items) |sock| try testing.expect(sock == null);
}

test "tcp reset for a closed port and for aborts" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const c = try l.a().tcpConnect(ip_b, 81);
    while (l.a().tcpError(c) == null) try l.tick();
    try testing.expectEqual(@as(?stack_mod.Error, error.ConnectionRefused), l.a().tcpError(c));
    try testing.expect(l.a().ready(c).err);
    try testing.expectError(error.ConnectionRefused, l.a().send(c, "x"));
    l.a().close(c);

    const pair = try connectPair(l, 82);
    l.b().abort(pair[1]);
    while (l.a().tcpError(pair[0]) == null) try l.tick();
    try testing.expectEqual(@as(?stack_mod.Error, error.ConnectionReset), l.a().tcpError(pair[0]));
    var buf: [4]u8 = undefined;
    try testing.expectError(error.ConnectionReset, l.a().recv(pair[0], &buf));
    l.a().close(pair[0]);
    l.b().close(pair[1]);
}

test "tcp retransmits with backoff and times out" {
    const l = try Link.init(testing.allocator, .{ .tcp = .{ .time_wait_ms = 2000, .data_retries = 6 } });
    defer l.deinit();
    const pair = try connectPair(l, 83);
    const c = pair[0];
    const s = pair[1];
    // Link down for a few seconds: the data gets through afterwards.
    l.down = true;
    _ = try l.a().send(c, "survives an outage");
    try l.runFor(3000);
    try testing.expect(l.a().tcb(c).?.retries >= 2);
    try testing.expect(l.a().tcb(c).?.rto >= 800);
    l.down = false;
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < 18) : (try l.tick()) {
        got += l.b().recv(s, buf[got..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
    }
    try testing.expectEqualStrings("survives an outage", buf[0..got]);
    try l.runFor(100);
    try testing.expectEqual(@as(u8, 0), l.a().tcb(c).?.retries);
    // Down for good: the connection times out.
    l.down = true;
    _ = try l.a().send(c, "lost");
    const start = l.now;
    while (l.a().tcpError(c) == null) try l.tick();
    try testing.expectEqual(@as(?stack_mod.Error, error.TimedOut), l.a().tcpError(c));
    // Six doublings from at least 200 ms.
    try testing.expect(l.now - start >= 200 * (2 + 4 + 8 + 16 + 32 + 64) / 2);
    l.a().close(c);
    l.b().abort(s);
    l.b().close(s);
}

test "tcp zero window: the sender waits and probes" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const pair = try connectPair(l, 84);
    const c = pair[0];
    const s = pair[1];
    const total: usize = 200 * 1024;
    var sent: usize = 0;
    var chunk: [4096]u8 = undefined;
    // B does not read: A fills B's window and its own buffer.
    for (0..2000) |_| {
        while (sent < total) {
            const n = @min(chunk.len, total - sent);
            for (0..n) |k| chunk[k] = pattern(sent + k);
            sent += l.a().send(c, chunk[0..n]) catch break;
        }
        try l.tick();
        if (l.a().tcb(c).?.snd_wnd == 0 and l.a().tcb(c).?.sndbuf.free() == 0) break;
    }
    try testing.expectEqual(@as(u32, 0), l.a().tcb(c).?.snd_wnd);
    try testing.expect(!l.a().ready(c).out);
    try l.runFor(10_000); // probes go unanswered with data
    try testing.expectEqual(@as(usize, 0), l.b().tcb(s).?.rcvbuf.free());
    // Now B reads everything.
    var recvd: usize = 0;
    var buf: [8192]u8 = undefined;
    while (recvd < total) {
        while (sent < total) {
            const n = @min(chunk.len, total - sent);
            for (0..n) |k| chunk[k] = pattern(sent + k);
            sent += l.a().send(c, chunk[0..n]) catch break;
        }
        const n = l.b().recv(s, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        for (buf[0..n], 0..) |byte, k| try testing.expectEqual(pattern(recvd + k), byte);
        recvd += n;
        try l.tick();
    }
    l.a().close(c);
    l.b().close(s);
}

test "tcp listen backlog" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const lh = try l.b().tcpListen(85, 1);
    try testing.expectError(error.AddressInUse, l.b().tcpListen(85, 1));
    const c1 = try l.a().tcpConnect(ip_b, 85);
    const c2 = try l.a().tcpConnect(ip_b, 85);
    try l.runFor(500);
    // One slot: the first connection is established, the second SYN dropped.
    try testing.expectEqual(stack_mod.tcp.State.established, l.a().tcpState(c1));
    try testing.expectEqual(stack_mod.tcp.State.syn_sent, l.a().tcpState(c2));
    try testing.expect(l.b().ready(lh).in);
    const s1 = (try l.b().tcpAccept(lh)).?;
    try testing.expect(try l.b().tcpAccept(lh) == null);
    // The retransmitted SYN finds room now.
    while (l.a().tcpState(c2) != .established) try l.tick();
    const s2 = (try l.b().tcpAccept(lh)).?;
    try testing.expect(s1 != s2);
    try testing.expect(l.b().remoteEndpoint(s1).?.port != l.b().remoteEndpoint(s2).?.port);
    // Closing the listener leaves accepted connections alone.
    l.b().close(lh);
    _ = try l.a().send(c2, "still here");
    var buf: [32]u8 = undefined;
    while (true) : (try l.tick()) {
        const n = l.b().recv(s2, &buf) catch continue;
        try testing.expectEqualStrings("still here", buf[0..n]);
        break;
    }
    for ([_]Handle{ c1, c2 }) |h| l.a().close(h);
    for ([_]Handle{ s1, s2 }) |h| l.b().close(h);
}

test "loopback tcp inside one stack" {
    const l = try Link.init(testing.allocator, .{});
    defer l.deinit();
    const s = l.a();
    const lh = try s.tcpListen(7, 2);
    const c = try s.tcpConnect(Ip4.loopback, 7);
    var srv: Handle = 0;
    while (srv == 0) : (try l.tick()) srv = (try s.tcpAccept(lh)) orelse 0;
    _ = try s.send(c, "echo me");
    var buf: [16]u8 = undefined;
    while (true) : (try l.tick()) {
        const n = s.recv(srv, &buf) catch continue;
        try testing.expectEqualStrings("echo me", buf[0..n]);
        break;
    }
    // Our own address loops back too, and nothing went on the wire.
    const on_wire = l.b().stats.rx_frames;
    const p = try s.pingOpen();
    try s.pingSend(p, ip_a, 1, "self");
    try l.runFor(10);
    try testing.expect(s.pingRecv(p).?.from.eql(ip_a));
    try testing.expectEqual(on_wire, l.b().stats.rx_frames);
    s.close(c);
    s.close(srv);
    s.close(lh);
}

/// A scripted DHCP server on B's UDP port 67.
const DhcpServer = struct {
    sock: Handle,
    lease: dhcp.Lease,
    requests: usize = 0,
    nak: bool = false,

    fn serve(self: *DhcpServer, l: *Link) !void {
        var buf: [dhcp.max_len]u8 = undefined;
        while (l.b().udpRecvFrom(self.sock, &buf)) |d| {
            const m = dhcp.parse(buf[0..d.len]) orelse continue;
            const reply: dhcp.MsgType = switch (m.kind orelse continue) {
                .discover => .offer,
                .request => blk: {
                    self.requests += 1;
                    break :blk if (self.nak) .nak else .ack;
                },
                else => continue,
            };
            var out: [dhcp.max_len]u8 = undefined;
            const n = dhcp.build(&out, .{ .op = 2, .kind = reply, .xid = m.xid, .mac = m.chaddr, .yiaddr = self.lease.ip, .lease = self.lease });
            try l.b().udpSendTo(self.sock, Ip4.broadcast, dhcp.client_port, out[0..n]);
        }
    }
};

test "dhcp: discover, request, renew, nak and fall back" {
    const static = IfConfig{ .ip = Ip4.init(10, 0, 0, 200), .netmask = mask };
    const l = try Link.init(testing.allocator, .{ .a = static, .a_dhcp = true });
    defer l.deinit();
    try testing.expect(l.a().config() == null);
    var srv = DhcpServer{
        .sock = try l.b().udpOpen(dhcp.server_port),
        .lease = .{
            .ip = Ip4.init(10, 0, 0, 50),
            .netmask = mask,
            .gateway = ip_b,
            .dns = .{ ip_b, Ip4.any, Ip4.any },
            .dns_count = 1,
            .server = ip_b,
            .lease_s = 100,
        },
    };
    while (l.a().config() == null) {
        try srv.serve(l);
        try l.tick();
    }
    const c = l.a().config().?;
    try testing.expect(c.ip.eql(srv.lease.ip));
    try testing.expect(c.gateway.eql(ip_b));
    try testing.expect(c.dns[0].eql(ip_b));
    try testing.expectEqual(dhcp.State.bound, l.a().dhcpState().?);
    try testing.expectEqual(@as(usize, 1), srv.requests);
    // T1 = 50 s: a unicast renewal.
    const bound_at = l.a().dhcp_client.bound_at;
    while (srv.requests < 2 or l.a().dhcpState().? != .bound) {
        try srv.serve(l);
        try l.tick();
    }
    try testing.expect(l.now >= bound_at + 50_000);
    try testing.expect(l.a().dhcp_client.bound_at > bound_at);
    try testing.expect(l.a().config().?.ip.eql(srv.lease.ip));
    // A NAK at the next renewal takes the address away; the client starts over.
    srv.nak = true;
    while (l.a().config() != null) {
        try srv.serve(l);
        try l.tick();
    }
    try testing.expectEqual(dhcp.State.selecting, l.a().dhcpState().?);
    srv.nak = false;
    while (l.a().config() == null) {
        try srv.serve(l);
        try l.tick();
    }
    try testing.expect(l.a().config().?.ip.eql(srv.lease.ip));

    // Without a server the client falls back to the static address.
    const l2 = try Link.init(testing.allocator, .{ .a = static, .a_dhcp = true });
    defer l2.deinit();
    while (l2.a().config() == null) try l2.tick();
    try testing.expect(l2.a().config().?.ip.eql(static.ip));
    try testing.expectEqual(dhcp.State.static, l2.a().dhcpState().?);
    try testing.expect(l2.now >= 1000 + 2000 + 4000);
}

test "dns: query, retry, cache and NXDOMAIN against a scripted responder" {
    const l = try Link.init(testing.allocator, .{ .a = .{ .ip = ip_a, .netmask = mask, .dns = .{ ip_b, Ip4.any, Ip4.any }, .dns_count = 1 } });
    defer l.deinit();
    const ns = try l.b().udpOpen(dns.port);
    const answer = Ip4.init(192, 0, 2, 80);
    var queries: usize = 0;
    const q = try l.a().resolve("www.zen.test");
    var buf: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    while (l.a().resolveStatus(q) == .pending) : (try l.tick()) {
        while (l.b().udpRecvFrom(ns, &buf)) |d| {
            queries += 1;
            // Ignore the first query: the resolver must retry.
            if (queries == 1) continue;
            const n = dns.buildReply(&out, buf[0..d.len], 0, &.{answer}, 300);
            try l.b().udpSendTo(ns, d.from, d.port, out[0..n]);
        }
    }
    try testing.expectEqual(@as(usize, 2), queries);
    try testing.expect(l.a().resolveStatus(q).done.addrs[0].eql(answer));
    l.a().resolveRelease(q);
    // Cached: no traffic.
    const q2 = try l.a().resolve("WWW.zen.test");
    try testing.expect(l.a().resolveStatus(q2).done.addrs[0].eql(answer));
    l.a().resolveRelease(q2);
    const q3 = try l.a().resolve("nowhere.zen.test");
    while (l.a().resolveStatus(q3) == .pending) : (try l.tick()) {
        while (l.b().udpRecvFrom(ns, &buf)) |d| {
            const n = dns.buildReply(&out, buf[0..d.len], 3, &.{}, 0);
            try l.b().udpSendTo(ns, d.from, d.port, out[0..n]);
        }
    }
    try testing.expectEqual(dns.Status{ .failed = error.NameNotFound }, l.a().resolveStatus(q3));
    l.a().resolveRelease(q3);
}
