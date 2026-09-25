//! netd backend for Zen: the lib/net stack on the first network driver
//! (`netdev:0`). Addresses come from DHCP, or from /etc/zen/network.conf:
//!
//!     mode      dhcp            # or: static
//!     address   10.0.2.15/24    # static address, and the DHCP fall back
//!     gateway   10.0.2.2
//!     dns       10.0.2.3 [more…]
//!
//! The defaults match QEMU's user-mode network.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const net = @import("net");
const common = @import("common.zig");

const posix = std.posix;
const Ip4 = common.Ip4;
const Conn = common.Conn;
const Error = common.Error;

const device = "netdev:0";
const config_file = "/etc/zen/network.conf";

pub const StackBackend = struct {
    gpa: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    info: abi.net.NetdevInfo = .{ .mac = .{ 0, 0, 0, 0, 0, 0 }, .mtu = 1500 },
    stack: ?*net.Stack = null,
    /// When to try opening the device again.
    retry_at: u64 = 0,
    use_dhcp: bool = true,
    static: net.IfConfig = .{
        .ip = Ip4.init(10, 0, 2, 15),
        .netmask = Ip4.init(255, 255, 255, 0),
        .gateway = Ip4.init(10, 0, 2, 2),
        .dns = .{ Ip4.init(10, 0, 2, 3), Ip4.any, Ip4.any },
        .dns_count = 1,
    },
    hostname: [64]u8 = undefined,
    hostname_len: usize = 0,
    frame: [abi.net.max_frame + 64]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, now: u64) !*StackBackend {
        const self = try gpa.create(StackBackend);
        self.* = .{ .gpa = gpa };
        self.loadConfig();
        self.openDevice(now);
        return self;
    }

    fn loadConfig(self: *StackBackend) void {
        var buf: [4096]u8 = undefined;
        if (std.fs.cwd().readFile("/etc/hostname", &buf)) |text| {
            const name = std.mem.trim(u8, text, " \t\r\n");
            self.hostname_len = @min(name.len, self.hostname.len);
            @memcpy(self.hostname[0..self.hostname_len], name[0..self.hostname_len]);
        } else |_| {}
        const text = std.fs.cwd().readFile(config_file, &buf) catch return;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
            var it = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = it.next() orelse continue;
            if (std.mem.eql(u8, key, "mode")) {
                self.use_dhcp = !std.mem.eql(u8, it.next() orelse "dhcp", "static");
            } else if (std.mem.eql(u8, key, "address")) {
                const v = it.next() orelse continue;
                const slash = std.mem.indexOfScalar(u8, v, '/');
                self.static.ip = Ip4.parse(v[0 .. slash orelse v.len]) orelse continue;
                if (slash) |s| {
                    const bits = std.fmt.parseInt(u6, v[s + 1 ..], 10) catch 24;
                    self.static.netmask = Ip4.fromU32(if (bits == 0) 0 else ~@as(u32, 0) << @intCast(32 - @as(u32, @min(bits, 32))));
                }
            } else if (std.mem.eql(u8, key, "netmask")) {
                self.static.netmask = Ip4.parse(it.next() orelse continue) orelse continue;
            } else if (std.mem.eql(u8, key, "gateway")) {
                self.static.gateway = Ip4.parse(it.next() orelse continue) orelse continue;
            } else if (std.mem.eql(u8, key, "dns")) {
                self.static.dns_count = 0;
                while (it.next()) |d| {
                    if (self.static.dns_count == 3) break;
                    self.static.dns[self.static.dns_count] = Ip4.parse(d) orelse continue;
                    self.static.dns_count += 1;
                }
            }
        }
    }

    fn openDevice(self: *StackBackend, now: u64) void {
        self.retry_at = now + 2000;
        const fd = zen.io.open(device, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch return;
        var info: abi.net.NetdevInfo = undefined;
        const got = blk: {
            const ifd = zen.io.open(device ++ "/info", .{ .ACCMODE = .RDONLY }, 0) catch break :blk 0;
            defer zen.io.close(ifd);
            break :blk zen.io.read(ifd, std.mem.asBytes(&info)) catch 0;
        };
        if (got != @sizeOf(abi.net.NetdevInfo)) {
            zen.io.close(fd);
            return;
        }
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        self.stack = net.Stack.init(self.gpa, .{
            .mac = .{ .bytes = info.mac },
            .mtu = info.mtu,
            .seed = seed,
            .output = .{ .ctx = self, .send = transmit },
            .static = self.static,
            .dhcp = self.use_dhcp,
            .hostname = self.hostname[0..self.hostname_len],
        }, now) catch {
            zen.io.close(fd);
            return;
        };
        self.fd = fd;
        self.info = info;
        zen.sys.logf("netd: {s} {f}, mtu {d}, {s}", .{ device, net.Mac{ .bytes = info.mac }, info.mtu, if (self.use_dhcp) "dhcp" else "static" });
    }

    fn transmit(ctx: *anyopaque, frame: []const u8) void {
        const self: *StackBackend = @ptrCast(@alignCast(ctx));
        const fd = self.fd orelse return;
        _ = zen.io.write(fd, frame) catch {};
    }

    fn s(self: *StackBackend) Error!*net.Stack {
        return self.stack orelse error.NoDevice;
    }

    // ---- event loop -------------------------------------------------------

    pub fn pollFds(self: *StackBackend, list: *std.ArrayList(posix.pollfd)) !void {
        if (self.fd) |fd| try list.append(self.gpa, .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 });
    }

    pub fn process(self: *StackBackend, fds: []const posix.pollfd, now: u64) void {
        const st = self.stack orelse {
            if (now >= self.retry_at) self.openDevice(now);
            return;
        };
        if (fds.len > 0 and fds[0].revents != 0) {
            // Take the frames that are waiting (bounded, so requests get a turn).
            var n: usize = 0;
            while (n < 256) : (n += 1) {
                const len = zen.io.read(self.fd.?, &self.frame) catch break;
                if (len == 0) break;
                st.input(self.frame[0..len], now);
            }
        }
        st.poll(now);
    }

    pub fn timeout(self: *StackBackend, now: u64) ?u64 {
        const st = self.stack orelse return self.retry_at -| now;
        return st.nextTimeout(now);
    }

    pub fn clearWants(self: *StackBackend) void {
        _ = self;
    }

    pub fn want(self: *StackBackend, c: Conn, events: u32) void {
        _ = self;
        _ = c;
        _ = events;
    }

    // ---- TCP ----------------------------------------------------------------

    pub fn tcpConnect(self: *StackBackend, ip: Ip4, port: u16) Error!Conn {
        return (try self.s()).tcpConnect(ip, port);
    }

    pub fn tcpListen(self: *StackBackend, port: u16, backlog: u16) Error!Conn {
        return (try self.s()).tcpListen(port, backlog);
    }

    pub fn tcpAccept(self: *StackBackend, c: Conn) Error!?Conn {
        return (try self.s()).tcpAccept(c);
    }

    pub fn tcpPhase(self: *StackBackend, c: Conn) common.TcpPhase {
        const st = self.stack orelse return .failed;
        if (st.tcpError(c) != null) return .failed;
        return switch (st.tcpState(c)) {
            .syn_sent, .syn_received => .connecting,
            .closed => .failed,
            else => .open,
        };
    }

    pub fn connError(self: *StackBackend, c: Conn) ?anyerror {
        const st = self.stack orelse return error.NoDevice;
        if (st.tcpError(c)) |e| return e;
        if (st.tcpState(c) == .closed) return error.ConnectionReset;
        return null;
    }

    pub fn send(self: *StackBackend, c: Conn, data: []const u8) Error!usize {
        return (try self.s()).send(c, data);
    }

    pub fn recv(self: *StackBackend, c: Conn, buf: []u8) Error!usize {
        return (try self.s()).recv(c, buf);
    }

    pub fn shutdown(self: *StackBackend, c: Conn) void {
        if (self.stack) |st| st.shutdown(c);
    }

    pub fn close(self: *StackBackend, c: Conn) void {
        if (self.stack) |st| st.close(c);
    }

    pub fn ready(self: *StackBackend, c: Conn) common.Ready {
        const st = self.stack orelse return .{ .err = true, .hup = true };
        return st.ready(c);
    }

    pub fn available(self: *StackBackend, c: Conn) usize {
        const st = self.stack orelse return 0;
        return st.bytesAvailable(c);
    }

    pub fn localEnd(self: *StackBackend, c: Conn) ?common.Endpoint {
        const st = self.stack orelse return null;
        return st.localEndpoint(c);
    }

    pub fn remoteEnd(self: *StackBackend, c: Conn) ?common.Endpoint {
        const st = self.stack orelse return null;
        return st.remoteEndpoint(c);
    }

    // ---- UDP ----------------------------------------------------------------

    pub fn udpOpen(self: *StackBackend, port: u16) Error!Conn {
        return (try self.s()).udpOpen(port);
    }

    pub fn udpSendTo(self: *StackBackend, c: Conn, ip: Ip4, port: u16, data: []const u8) Error!void {
        return (try self.s()).udpSendTo(c, ip, port, data);
    }

    pub fn udpRecvFrom(self: *StackBackend, c: Conn, buf: []u8) ?common.Datagram {
        const st = self.stack orelse return null;
        return st.udpRecvFrom(c, buf);
    }

    // ---- ICMP echo ------------------------------------------------------------

    pub fn pingOpen(self: *StackBackend) Error!Conn {
        return (try self.s()).pingOpen();
    }

    pub fn pingSend(self: *StackBackend, c: Conn, ip: Ip4, seq: u16, payload: []const u8) Error!void {
        return (try self.s()).pingSend(c, ip, seq, payload);
    }

    pub fn pingRecv(self: *StackBackend, c: Conn) ?common.PingReply {
        const st = self.stack orelse return null;
        const r = st.pingRecv(c) orelse return null;
        return .{ .from = r.from, .seq = r.seq, .ttl = r.ttl, .len = r.len };
    }

    // ---- DNS ----------------------------------------------------------------

    pub fn resolve(self: *StackBackend, name: []const u8) anyerror!u16 {
        return (try self.s()).resolve(name);
    }

    pub fn resolveStatus(self: *StackBackend, q: u16) common.DnsStatus {
        const st = self.stack orelse return .{ .failed = error.NoServers };
        return st.resolveStatus(q);
    }

    pub fn resolveRelease(self: *StackBackend, q: u16) void {
        if (self.stack) |st| st.resolveRelease(q);
    }

    // ---- status -----------------------------------------------------------------

    pub fn writeStatus(self: *StackBackend, w: *std.Io.Writer) !void {
        const st = self.stack orelse {
            try w.writeAll("interface none\n");
            return;
        };
        const up = self.info.flags & abi.net.NETDEV_LINK_UP != 0;
        try w.print("interface eth0 {s}\n", .{if (up) "up" else "down"});
        try w.print("mac {f}\n", .{st.mac});
        try w.print("mtu {d}\n", .{st.mtu});
        try w.print("config {s}\n", .{if (self.use_dhcp) "dhcp" else "static"});
        if (st.dhcpState()) |d| {
            if (st.dhcpLease()) |l| {
                try w.print("dhcp {s} lease {d}s server {f}\n", .{ @tagName(d), l.remaining_ms / 1000, l.lease.server });
            } else {
                try w.print("dhcp {s}\n", .{@tagName(d)});
            }
        }
        if (st.config()) |c| {
            try w.print("address {f}/{d}\n", .{ c.ip, c.netmask.prefixLen() });
            try w.print("netmask {f}\n", .{c.netmask});
            if (!c.gateway.isAny()) try w.print("gateway {f}\n", .{c.gateway});
            try w.writeAll("dns");
            for (c.dnsServers()) |d| try w.print(" {f}", .{d});
            try w.writeAll("\n");
        }
        try w.print("rx {d} {d}\n", .{ st.stats.rx_frames, st.stats.rx_bytes });
        try w.print("tx {d} {d}\n", .{ st.stats.tx_frames, st.stats.tx_bytes });
    }
};
