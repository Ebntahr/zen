//! netd backend for hosted Zen: the same URLs served with the host's
//! sockets (all non-blocking, driven by netd's poll loop). Names are
//! resolved by lib/net's DNS resolver over a host UDP socket; the name
//! servers come from $ZEN_HOSTED_DNS (set by zen-hosted from the host's
//! resolv.conf) or /etc/resolv.conf. Pings use an unprivileged ICMP
//! datagram socket, or a raw socket when that is not allowed (root).

const std = @import("std");
const net = @import("net");
const common = @import("common.zig");

const posix = std.posix;
const linux = std.os.linux;
const Ip4 = common.Ip4;
const Conn = common.Conn;
const Error = common.Error;

const Kind = enum { tcp, listener, udp, icmp };

const Sock = struct {
    fd: posix.fd_t,
    kind: Kind,
    connecting: bool = false,
    err: ?Error = null,
    /// poll events wanted in the next loop iteration.
    want: u32 = 0,
    /// icmp: raw socket (we see the IP header and must match the id).
    raw: bool = false,
    icmp_id: u16 = 0,
};

fn mapErr(e: linux.E) Error {
    return switch (e) {
        .AGAIN, .INPROGRESS, .INTR, .ALREADY => error.WouldBlock,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET, .CONNABORTED => error.ConnectionReset,
        .TIMEDOUT => error.TimedOut,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH, .NETDOWN => error.NetworkUnreachable,
        .ADDRINUSE => error.AddressInUse,
        .MSGSIZE => error.MessageTooLong,
        .NOTCONN, .PIPE => error.NotConnected,
        .ACCES, .PERM => error.AccessDenied,
        .INVAL => error.InvalidArgument,
        .NOMEM, .NOBUFS, .MFILE, .NFILE => error.OutOfMemory,
        .BADF => error.BadHandle,
        else => error.Unexpected,
    };
}

fn sys(rc: usize) Error!usize {
    return switch (linux.E.init(rc)) {
        .SUCCESS => rc,
        else => |e| mapErr(e),
    };
}

fn sockaddr(ip: Ip4, port: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip.bytes) };
}

fn fromSockaddr(sa: linux.sockaddr.in) common.Endpoint {
    return .{ .ip = .{ .bytes = @bitCast(sa.addr) }, .port = std.mem.bigToNative(u16, sa.port) };
}

const IP_TTL = 2;
const IP_RECVTTL = 12;
const SIOCGIFFLAGS = 0x8913;
const SIOCGIFADDR = 0x8915;
const SIOCGIFNETMASK = 0x891b;
const SIOCGIFMTU = 0x8921;
const SIOCGIFHWADDR = 0x8927;

const Ifreq = extern struct {
    name: [16]u8,
    u: extern union {
        addr: linux.sockaddr,
        flags: i16,
        mtu: i32,
        pad: [24]u8,
    },
};

pub const HostBackend = struct {
    gpa: std.mem.Allocator,
    socks: std.ArrayList(?Sock) = .empty,
    resolver: net.dns.Resolver,
    dns_fd: posix.fd_t,
    now: u64 = 0,
    buf: [65536 + 64]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, now: u64) !*HostBackend {
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        const fd: posix.fd_t = @intCast(try sys(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)));
        const self = try gpa.create(HostBackend);
        self.* = .{ .gpa = gpa, .resolver = net.dns.Resolver.init(seed), .dns_fd = fd, .now = now };
        var servers: [3]Ip4 = undefined;
        self.resolver.setServers(servers[0..nameServers(&servers)]);
        return self;
    }

    /// $ZEN_HOSTED_DNS ("8.8.8.8 1.1.1.1" or comma-separated), else resolv.conf.
    fn nameServers(out: *[3]Ip4) usize {
        if (posix.getenv("ZEN_HOSTED_DNS")) |list| {
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, list, ", ");
            while (it.next()) |a| {
                if (n == out.len) break;
                out[n] = Ip4.parse(a) orelse continue;
                n += 1;
            }
            if (n > 0) return n;
        }
        var buf: [4096]u8 = undefined;
        const text = std.fs.cwd().readFile("/etc/resolv.conf", &buf) catch return 0;
        return net.dns.parseResolvConf(text, out);
    }

    fn add(self: *HostBackend, s: Sock) Error!Conn {
        for (self.socks.items, 0..) |slot, i| if (slot == null) {
            self.socks.items[i] = s;
            return @intCast(i + 1);
        };
        self.socks.append(self.gpa, s) catch return error.OutOfMemory;
        return @intCast(self.socks.items.len);
    }

    fn get(self: *HostBackend, c: Conn) ?*Sock {
        if (c == 0 or c > self.socks.items.len) return null;
        if (self.socks.items[c - 1]) |*s| return s;
        return null;
    }

    fn newSocket(kind: u32, proto: u32) Error!posix.fd_t {
        return @intCast(try sys(linux.socket(linux.AF.INET, kind | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, proto)));
    }

    fn setInt(fd: posix.fd_t, level: i32, opt: u32, v: i32) void {
        _ = linux.setsockopt(fd, level, opt, std.mem.asBytes(&v), @sizeOf(i32));
    }

    // ---- event loop -------------------------------------------------------

    pub fn pollFds(self: *HostBackend, list: *std.ArrayList(posix.pollfd)) !void {
        try list.append(self.gpa, .{ .fd = self.dns_fd, .events = posix.POLL.IN, .revents = 0 });
        for (self.socks.items) |slot| {
            const s = slot orelse continue;
            if (s.want == 0) continue;
            try list.append(self.gpa, .{ .fd = s.fd, .events = @intCast(s.want), .revents = 0 });
        }
    }

    fn dnsSend(ctx: *anyopaque, server: Ip4, msg: []const u8) void {
        const self: *HostBackend = @ptrCast(@alignCast(ctx));
        var sa = sockaddr(server, net.dns.port);
        _ = linux.sendto(self.dns_fd, msg.ptr, msg.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    }

    pub fn process(self: *HostBackend, fds: []const posix.pollfd, now: u64) void {
        self.now = now;
        if (fds.len > 0 and fds[0].revents != 0) {
            while (true) {
                var sa: linux.sockaddr.in = undefined;
                var len: posix.socklen_t = @sizeOf(linux.sockaddr.in);
                const n = sys(linux.recvfrom(self.dns_fd, &self.buf, self.buf.len, 0, @ptrCast(&sa), &len)) catch break;
                const from = fromSockaddr(sa);
                if (from.port == net.dns.port) self.resolver.input(from.ip, self.buf[0..n], now);
            }
        }
        self.resolver.poll(now, self, dnsSend);
    }

    pub fn timeout(self: *HostBackend, now: u64) ?u64 {
        const d = self.resolver.nextDeadline() orelse return null;
        return d -| now;
    }

    pub fn clearWants(self: *HostBackend) void {
        for (self.socks.items) |*slot| if (slot.*) |*s| {
            s.want = 0;
        };
    }

    pub fn want(self: *HostBackend, c: Conn, events: u32) void {
        const s = self.get(c) orelse return;
        s.want |= events;
    }

    /// Current poll events of one socket (without waiting).
    fn probe(s: *Sock) u32 {
        var p = [_]posix.pollfd{.{ .fd = s.fd, .events = posix.POLL.IN | posix.POLL.OUT, .revents = 0 }};
        _ = linux.poll(&p, 1, 0);
        return @intCast(@as(u16, @bitCast(p[0].revents)));
    }

    /// Finish a pending connect when the socket says so.
    fn checkConnect(s: *Sock) void {
        if (!s.connecting) return;
        const ev = probe(s);
        if (ev & (posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP) == 0) return;
        var code: i32 = 0;
        var len: posix.socklen_t = @sizeOf(i32);
        _ = linux.getsockopt(s.fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&code), &len);
        s.connecting = false;
        if (code != 0) s.err = mapErr(@enumFromInt(code));
    }

    // ---- TCP ----------------------------------------------------------------

    pub fn tcpConnect(self: *HostBackend, ip: Ip4, port: u16) Error!Conn {
        const fd = try newSocket(linux.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        setInt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
        var sa = sockaddr(ip, port);
        var connecting = false;
        _ = sys(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) catch |err| switch (err) {
            error.WouldBlock => connecting = true,
            else => return err,
        };
        return self.add(.{ .fd = fd, .kind = .tcp, .connecting = connecting });
    }

    pub fn tcpListen(self: *HostBackend, port: u16, backlog: u16) Error!Conn {
        const fd = try newSocket(linux.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        setInt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        var sa = sockaddr(Ip4.any, port);
        _ = try sys(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
        _ = try sys(linux.listen(fd, @max(backlog, 1)));
        return self.add(.{ .fd = fd, .kind = .listener });
    }

    pub fn tcpAccept(self: *HostBackend, c: Conn) Error!?Conn {
        const s = self.get(c) orelse return error.BadHandle;
        const rc = sys(linux.accept4(s.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC)) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionReset => return null,
            else => return err,
        };
        const fd: posix.fd_t = @intCast(rc);
        setInt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
        return self.add(.{ .fd = fd, .kind = .tcp }) catch |err| {
            posix.close(fd);
            return err;
        };
    }

    pub fn tcpPhase(self: *HostBackend, c: Conn) common.TcpPhase {
        const s = self.get(c) orelse return .failed;
        checkConnect(s);
        if (s.err != null) return .failed;
        return if (s.connecting) .connecting else .open;
    }

    pub fn connError(self: *HostBackend, c: Conn) ?anyerror {
        const s = self.get(c) orelse return error.BadHandle;
        return s.err;
    }

    pub fn send(self: *HostBackend, c: Conn, data: []const u8) Error!usize {
        const s = self.get(c) orelse return error.BadHandle;
        if (s.err) |e| return e;
        return sys(linux.sendto(s.fd, data.ptr, data.len, linux.MSG.NOSIGNAL, null, 0));
    }

    pub fn recv(self: *HostBackend, c: Conn, buf: []u8) Error!usize {
        const s = self.get(c) orelse return error.BadHandle;
        if (s.err) |e| return e;
        return sys(linux.recvfrom(s.fd, buf.ptr, buf.len, 0, null, null)) catch |err| {
            if (err != error.WouldBlock) s.err = err;
            return err;
        };
    }

    pub fn shutdown(self: *HostBackend, c: Conn) void {
        const s = self.get(c) orelse return;
        _ = linux.shutdown(s.fd, linux.SHUT.WR);
    }

    pub fn close(self: *HostBackend, c: Conn) void {
        const s = self.get(c) orelse return;
        posix.close(s.fd);
        self.socks.items[c - 1] = null;
    }

    pub fn ready(self: *HostBackend, c: Conn) common.Ready {
        const s = self.get(c) orelse return .{ .err = true, .hup = true };
        checkConnect(s);
        if (s.err != null) return .{ .in = true, .out = true, .hup = true, .err = true };
        if (s.connecting) return .{};
        const ev = probe(s);
        return .{
            .in = ev & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0,
            .out = ev & posix.POLL.OUT != 0 and s.kind != .listener,
            .hup = ev & posix.POLL.HUP != 0,
            .err = ev & posix.POLL.ERR != 0,
        };
    }

    pub fn available(self: *HostBackend, c: Conn) usize {
        const s = self.get(c) orelse return 0;
        var n: i32 = 0;
        _ = linux.ioctl(s.fd, linux.T.FIONREAD, @intFromPtr(&n));
        return @intCast(@max(n, 0));
    }

    pub fn localEnd(self: *HostBackend, c: Conn) ?common.Endpoint {
        const s = self.get(c) orelse return null;
        var sa: linux.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = sys(linux.getsockname(s.fd, @ptrCast(&sa), &len)) catch return null;
        return fromSockaddr(sa);
    }

    pub fn remoteEnd(self: *HostBackend, c: Conn) ?common.Endpoint {
        const s = self.get(c) orelse return null;
        var sa: linux.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = sys(linux.getpeername(s.fd, @ptrCast(&sa), &len)) catch return null;
        return fromSockaddr(sa);
    }

    // ---- UDP ----------------------------------------------------------------

    pub fn udpOpen(self: *HostBackend, port: u16) Error!Conn {
        const fd = try newSocket(linux.SOCK.DGRAM, 0);
        errdefer posix.close(fd);
        setInt(fd, linux.SOL.SOCKET, linux.SO.BROADCAST, 1);
        var sa = sockaddr(Ip4.any, port);
        _ = try sys(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
        return self.add(.{ .fd = fd, .kind = .udp });
    }

    pub fn udpSendTo(self: *HostBackend, c: Conn, ip: Ip4, port: u16, data: []const u8) Error!void {
        const s = self.get(c) orelse return error.BadHandle;
        var sa = sockaddr(ip, port);
        _ = sys(linux.sendto(s.fd, data.ptr, data.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) catch |err| switch (err) {
            // A datagram that cannot be queued now is lost, as on the wire.
            error.WouldBlock => {},
            else => return err,
        };
    }

    pub fn udpRecvFrom(self: *HostBackend, c: Conn, buf: []u8) ?common.Datagram {
        const s = self.get(c) orelse return null;
        while (true) {
            var sa: linux.sockaddr.in = undefined;
            var len: posix.socklen_t = @sizeOf(linux.sockaddr.in);
            const n = sys(linux.recvfrom(s.fd, buf.ptr, buf.len, linux.MSG.TRUNC, @ptrCast(&sa), &len)) catch |err| switch (err) {
                // An ICMP error for an earlier datagram: skip it.
                error.ConnectionRefused, error.HostUnreachable, error.NetworkUnreachable => continue,
                else => return null,
            };
            const from = fromSockaddr(sa);
            return .{ .from = from.ip, .port = from.port, .len = n };
        }
    }

    // ---- ICMP echo ------------------------------------------------------------

    pub fn pingOpen(self: *HostBackend) Error!Conn {
        if (newSocket(linux.SOCK.DGRAM, linux.IPPROTO.ICMP)) |fd| {
            setInt(fd, linux.IPPROTO.IP, IP_RECVTTL, 1);
            return self.add(.{ .fd = fd, .kind = .icmp }) catch |err| {
                posix.close(fd);
                return err;
            };
        } else |_| {}
        const fd = try newSocket(linux.SOCK.RAW, linux.IPPROTO.ICMP);
        var id: u16 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&id));
        return self.add(.{ .fd = fd, .kind = .icmp, .raw = true, .icmp_id = id }) catch |err| {
            posix.close(fd);
            return err;
        };
    }

    pub fn pingSend(self: *HostBackend, c: Conn, ip: Ip4, seq: u16, payload: []const u8) Error!void {
        const s = self.get(c) orelse return error.BadHandle;
        if (payload.len > 65000) return error.MessageTooLong;
        const msg = self.buf[0 .. net.wire.icmp_hlen + payload.len];
        @memcpy(msg[net.wire.icmp_hlen..], payload);
        net.wire.writeIcmp(msg, net.wire.icmp_echo_request, 0, s.icmp_id, seq, payload.len);
        var sa = sockaddr(ip, 0);
        _ = try sys(linux.sendto(s.fd, msg.ptr, msg.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    }

    pub fn pingRecv(self: *HostBackend, c: Conn) ?common.PingReply {
        const s = self.get(c) orelse return null;
        while (true) {
            var sa: linux.sockaddr.in = undefined;
            var iov = [_]posix.iovec{.{ .base = &self.buf, .len = self.buf.len }};
            var cbuf: [64]u8 align(8) = undefined;
            var msg = linux.msghdr{
                .name = @ptrCast(&sa),
                .namelen = @sizeOf(linux.sockaddr.in),
                .iov = &iov,
                .iovlen = 1,
                .control = &cbuf,
                .controllen = cbuf.len,
                .flags = 0,
            };
            const n = sys(linux.recvmsg(s.fd, &msg, 0)) catch return null;
            var data = self.buf[0..n];
            var ttl: u8 = 0;
            if (s.raw) {
                // Raw sockets see every ICMP message, IP header included.
                const ip = net.wire.Ip4Packet.parse(data) orelse continue;
                ttl = ip.ttl;
                data = @constCast(ip.payload);
            } else {
                ttl = cmsgTtl(cbuf[0..@min(msg.controllen, cbuf.len)]);
            }
            if (data.len < net.wire.icmp_hlen or data[0] != net.wire.icmp_echo_reply) continue;
            const id = std.mem.readInt(u16, data[4..6], .big);
            if (s.raw and id != s.icmp_id) continue;
            return .{
                .from = fromSockaddr(sa).ip,
                .seq = std.mem.readInt(u16, data[6..8], .big),
                .ttl = ttl,
                .len = data.len - net.wire.icmp_hlen,
            };
        }
    }

    /// The IP_TTL control message of a received datagram.
    fn cmsgTtl(c: []const u8) u8 {
        const hdr = @sizeOf(usize) + 8;
        var pos: usize = 0;
        while (pos + hdr <= c.len) {
            const len = std.mem.readInt(usize, c[pos..][0..@sizeOf(usize)], .little);
            const level = std.mem.readInt(i32, c[pos + @sizeOf(usize) ..][0..4], .little);
            const kind = std.mem.readInt(i32, c[pos + @sizeOf(usize) + 4 ..][0..4], .little);
            if (len < hdr) break;
            if (level == linux.IPPROTO.IP and kind == IP_TTL and pos + hdr + 4 <= c.len) {
                return @intCast(std.math.clamp(std.mem.readInt(i32, c[pos + hdr ..][0..4], .little), 0, 255));
            }
            pos += std.mem.alignForward(usize, len, @sizeOf(usize));
        }
        return 0;
    }

    // ---- DNS ----------------------------------------------------------------

    pub fn resolve(self: *HostBackend, name: []const u8) anyerror!u16 {
        const id = try self.resolver.query(name, self.now);
        self.resolver.poll(self.now, self, dnsSend);
        return id;
    }

    pub fn resolveStatus(self: *HostBackend, q: u16) common.DnsStatus {
        return self.resolver.status(q);
    }

    pub fn resolveRelease(self: *HostBackend, q: u16) void {
        self.resolver.release(q);
    }

    // ---- status -----------------------------------------------------------------

    /// The interface of the default route (else the first one that is not
    /// loopback) and the gateway, from /proc/net/route.
    fn primary(name: *[16]u8, gateway: *Ip4) usize {
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        gateway.* = Ip4.any;
        if (std.fs.cwd().readFile("/proc/net/route", &buf)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            _ = lines.next();
            while (lines.next()) |l| {
                var it = std.mem.tokenizeAny(u8, l, " \t");
                const ifname = it.next() orelse continue;
                const dest = it.next() orelse continue;
                const gw = it.next() orelse continue;
                if (!std.mem.eql(u8, dest, "00000000")) continue;
                len = @min(ifname.len, 15);
                @memcpy(name[0..len], ifname[0..len]);
                const g = std.fmt.parseInt(u32, gw, 16) catch 0;
                gateway.* = .{ .bytes = @bitCast(g) };
                return len;
            }
        } else |_| {}
        if (std.fs.cwd().readFile("/proc/net/dev", &buf)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |l| {
                const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
                const ifname = std.mem.trim(u8, l[0..colon], " ");
                if (ifname.len == 0 or std.mem.eql(u8, ifname, "lo") or std.mem.indexOfScalar(u8, ifname, '|') != null) continue;
                len = @min(ifname.len, 15);
                @memcpy(name[0..len], ifname[0..len]);
                return len;
            }
        } else |_| {}
        return 0;
    }

    fn ifreq(fd: posix.fd_t, name: []const u8, req: u32) ?Ifreq {
        var r: Ifreq = std.mem.zeroes(Ifreq);
        @memcpy(r.name[0..name.len], name);
        if (linux.E.init(linux.ioctl(fd, req, @intFromPtr(&r))) != .SUCCESS) return null;
        return r;
    }

    fn ifAddr(r: Ifreq) Ip4 {
        return .{ .bytes = r.u.addr.data[2..6].* };
    }

    /// rx/tx frames and bytes of an interface from /proc/net/dev.
    fn counters(name: []const u8) ?[4]u64 {
        var buf: [8192]u8 = undefined;
        const text = std.fs.cwd().readFile("/proc/net/dev", &buf) catch return null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, l[0..colon], " "), name)) continue;
            var it = std.mem.tokenizeScalar(u8, l[colon + 1 ..], ' ');
            var v: [16]u64 = undefined;
            var i: usize = 0;
            while (it.next()) |f| : (i += 1) {
                if (i == v.len) break;
                v[i] = std.fmt.parseInt(u64, f, 10) catch 0;
            }
            if (i < 10) return null;
            return .{ v[1], v[0], v[9], v[8] };
        }
        return null;
    }

    pub fn writeStatus(self: *HostBackend, w: *std.Io.Writer) !void {
        var name_buf: [16]u8 = undefined;
        var gateway: Ip4 = undefined;
        const nlen = primary(&name_buf, &gateway);
        if (nlen == 0) {
            try w.writeAll("interface none\n");
            return;
        }
        const name = name_buf[0..nlen];
        const fd = newSocket(linux.SOCK.DGRAM, 0) catch return;
        defer posix.close(fd);
        const flags: u16 = if (ifreq(fd, name, SIOCGIFFLAGS)) |r| @bitCast(r.u.flags) else 0;
        try w.print("interface {s} {s}\n", .{ name, if (flags & 1 != 0) "up" else "down" });
        if (ifreq(fd, name, SIOCGIFHWADDR)) |r| try w.print("mac {f}\n", .{net.Mac{ .bytes = r.u.addr.data[0..6].* }});
        if (ifreq(fd, name, SIOCGIFMTU)) |r| try w.print("mtu {d}\n", .{r.u.mtu});
        try w.writeAll("config host\n");
        if (ifreq(fd, name, SIOCGIFADDR)) |r| {
            const mask = if (ifreq(fd, name, SIOCGIFNETMASK)) |m| ifAddr(m) else Ip4.init(255, 255, 255, 0);
            try w.print("address {f}/{d}\n", .{ ifAddr(r), mask.prefixLen() });
            try w.print("netmask {f}\n", .{mask});
        }
        if (!gateway.isAny()) try w.print("gateway {f}\n", .{gateway});
        try w.writeAll("dns");
        for (self.resolver.servers[0..self.resolver.nservers]) |d| try w.print(" {f}", .{d});
        try w.writeAll("\n");
        if (counters(name)) |c| {
            try w.print("rx {d} {d}\n", .{ c[0], c[1] });
            try w.print("tx {d} {d}\n", .{ c[2], c[3] });
        }
    }
};
