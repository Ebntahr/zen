//! Addresses, checksums and the wire formats of Ethernet II, ARP, IPv4,
//! ICMP, UDP and TCP. Everything here is pure: parsing never allocates and
//! building writes into caller-provided buffers. Multi-byte fields are big
//! endian on the wire.

const std = @import("std");

pub const Ip4 = extern struct {
    bytes: [4]u8,

    pub const any: Ip4 = .{ .bytes = .{ 0, 0, 0, 0 } };
    pub const broadcast: Ip4 = .{ .bytes = .{ 255, 255, 255, 255 } };
    pub const loopback: Ip4 = .{ .bytes = .{ 127, 0, 0, 1 } };

    pub fn init(a: u8, b: u8, c: u8, d: u8) Ip4 {
        return .{ .bytes = .{ a, b, c, d } };
    }

    pub fn fromU32(v: u32) Ip4 {
        var ip: Ip4 = undefined;
        std.mem.writeInt(u32, &ip.bytes, v, .big);
        return ip;
    }

    pub fn toU32(self: Ip4) u32 {
        return std.mem.readInt(u32, &self.bytes, .big);
    }

    pub fn eql(a: Ip4, b: Ip4) bool {
        return a.toU32() == b.toU32();
    }

    pub fn isAny(self: Ip4) bool {
        return self.toU32() == 0;
    }

    pub fn isBroadcast(self: Ip4) bool {
        return self.toU32() == 0xffff_ffff;
    }

    pub fn isLoopback(self: Ip4) bool {
        return self.bytes[0] == 127;
    }

    pub fn isMulticast(self: Ip4) bool {
        return self.bytes[0] >= 224 and self.bytes[0] < 240;
    }

    pub fn sameSubnet(a: Ip4, b: Ip4, mask: Ip4) bool {
        return a.toU32() & mask.toU32() == b.toU32() & mask.toU32();
    }

    /// Directed broadcast address of `ip`'s subnet.
    pub fn subnetBroadcast(ip: Ip4, mask: Ip4) Ip4 {
        return fromU32(ip.toU32() | ~mask.toU32());
    }

    /// Parse dotted-quad notation ("10.0.2.15").
    pub fn parse(s: []const u8) ?Ip4 {
        var ip: Ip4 = undefined;
        var it = std.mem.splitScalar(u8, s, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i == 4 or part.len == 0 or part.len > 3) return null;
            for (part) |c| if (!std.ascii.isDigit(c)) return null;
            ip.bytes[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        }
        if (i != 4) return null;
        return ip;
    }

    /// Prefix length of a netmask (255.255.255.0 → 24).
    pub fn prefixLen(mask: Ip4) u6 {
        return @intCast(@popCount(mask.toU32()));
    }

    pub fn format(self: Ip4, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}", .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] });
    }
};

pub const Mac = extern struct {
    bytes: [6]u8,

    pub const broadcast: Mac = .{ .bytes = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } };
    pub const zero: Mac = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };

    pub fn eql(a: Mac, b: Mac) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isBroadcast(self: Mac) bool {
        return self.eql(broadcast);
    }

    pub fn isMulticast(self: Mac) bool {
        return self.bytes[0] & 1 != 0;
    }

    pub fn parse(s: []const u8) ?Mac {
        var m: Mac = undefined;
        var it = std.mem.splitAny(u8, s, ":-");
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i == 6 or part.len != 2) return null;
            m.bytes[i] = std.fmt.parseInt(u8, part, 16) catch return null;
        }
        if (i != 6) return null;
        return m;
    }

    pub fn format(self: Mac, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const b = self.bytes;
        try w.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ b[0], b[1], b[2], b[3], b[4], b[5] });
    }
};

// ---------------------------------------------------------------------------
// Checksums (RFC 1071)
// ---------------------------------------------------------------------------

/// Add `data` (big-endian 16-bit words) to a running ones'-complement sum.
pub fn sumBytes(sum: u32, data: []const u8) u32 {
    var s: u64 = sum;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        s += std.mem.readInt(u16, data[i..][0..2], .big);
        s += std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
        s += std.mem.readInt(u16, data[i + 4 ..][0..2], .big);
        s += std.mem.readInt(u16, data[i + 6 ..][0..2], .big);
    }
    while (i + 2 <= data.len) : (i += 2) s += std.mem.readInt(u16, data[i..][0..2], .big);
    if (i < data.len) s += @as(u32, data[i]) << 8;
    while (s >> 32 != 0) s = (s & 0xffff_ffff) + (s >> 32);
    return fold32(@intCast(s));
}

fn fold32(s: u32) u32 {
    var v = s;
    while (v >> 16 != 0) v = (v & 0xffff) + (v >> 16);
    return v;
}

pub fn finish(sum: u32) u16 {
    return ~@as(u16, @intCast(fold32(sum)));
}

pub fn checksum(data: []const u8) u16 {
    return finish(sumBytes(0, data));
}

/// Sum of the TCP/UDP pseudo header.
pub fn pseudoSum(src: Ip4, dst: Ip4, proto: u8, len: usize) u32 {
    var s: u32 = 0;
    s = sumBytes(s, &src.bytes);
    s = sumBytes(s, &dst.bytes);
    s += proto;
    s += @intCast(len);
    return fold32(s);
}

// ---------------------------------------------------------------------------
// Ethernet II
// ---------------------------------------------------------------------------

pub const eth_hlen = 14;
/// Smallest frame without the FCS; shorter frames are padded.
pub const eth_min = 60;
pub const ethertype_ip4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;

pub const Eth = struct {
    dst: Mac,
    src: Mac,
    ethertype: u16,
    payload: []const u8,

    pub fn parse(frame: []const u8) ?Eth {
        if (frame.len < eth_hlen) return null;
        return .{
            .dst = .{ .bytes = frame[0..6].* },
            .src = .{ .bytes = frame[6..12].* },
            .ethertype = std.mem.readInt(u16, frame[12..14], .big),
            .payload = frame[eth_hlen..],
        };
    }
};

pub fn writeEth(buf: []u8, dst: Mac, src: Mac, ethertype: u16) void {
    buf[0..6].* = dst.bytes;
    buf[6..12].* = src.bytes;
    std.mem.writeInt(u16, buf[12..14], ethertype, .big);
}

// ---------------------------------------------------------------------------
// ARP (RFC 826), Ethernet/IPv4 only
// ---------------------------------------------------------------------------

pub const arp_len = 28;
pub const arp_request: u16 = 1;
pub const arp_reply: u16 = 2;

pub const Arp = struct {
    op: u16,
    sha: Mac,
    spa: Ip4,
    tha: Mac,
    tpa: Ip4,

    pub fn parse(p: []const u8) ?Arp {
        if (p.len < arp_len) return null;
        if (std.mem.readInt(u16, p[0..2], .big) != 1) return null; // Ethernet
        if (std.mem.readInt(u16, p[2..4], .big) != ethertype_ip4) return null;
        if (p[4] != 6 or p[5] != 4) return null;
        return .{
            .op = std.mem.readInt(u16, p[6..8], .big),
            .sha = .{ .bytes = p[8..14].* },
            .spa = .{ .bytes = p[14..18].* },
            .tha = .{ .bytes = p[18..24].* },
            .tpa = .{ .bytes = p[24..28].* },
        };
    }

    pub fn write(self: Arp, p: []u8) void {
        std.mem.writeInt(u16, p[0..2], 1, .big);
        std.mem.writeInt(u16, p[2..4], ethertype_ip4, .big);
        p[4] = 6;
        p[5] = 4;
        std.mem.writeInt(u16, p[6..8], self.op, .big);
        p[8..14].* = self.sha.bytes;
        p[14..18].* = self.spa.bytes;
        p[18..24].* = self.tha.bytes;
        p[24..28].* = self.tpa.bytes;
    }
};

// ---------------------------------------------------------------------------
// IPv4 (RFC 791)
// ---------------------------------------------------------------------------

pub const ip4_hlen = 20;
pub const proto_icmp: u8 = 1;
pub const proto_tcp: u8 = 6;
pub const proto_udp: u8 = 17;

pub const Ip4Packet = struct {
    src: Ip4,
    dst: Ip4,
    proto: u8,
    ttl: u8,
    id: u16,
    /// More-fragments flag or a non-zero fragment offset.
    fragment: bool,
    header: []const u8,
    payload: []const u8,

    /// Parse and validate (version, lengths, header checksum).
    pub fn parse(p: []const u8) ?Ip4Packet {
        if (p.len < ip4_hlen) return null;
        if (p[0] >> 4 != 4) return null;
        const ihl = @as(usize, p[0] & 0xf) * 4;
        if (ihl < ip4_hlen or ihl > p.len) return null;
        const total = std.mem.readInt(u16, p[2..4], .big);
        if (total < ihl or total > p.len) return null;
        if (checksum(p[0..ihl]) != 0) return null;
        const frag = std.mem.readInt(u16, p[6..8], .big);
        return .{
            .src = .{ .bytes = p[12..16].* },
            .dst = .{ .bytes = p[16..20].* },
            .proto = p[9],
            .ttl = p[8],
            .id = std.mem.readInt(u16, p[4..6], .big),
            .fragment = frag & 0x3fff != 0,
            .header = p[0..ihl],
            .payload = p[ihl..total],
        };
    }
};

/// Write a 20-byte IPv4 header (don't-fragment set) with its checksum.
pub fn writeIp4(buf: []u8, src: Ip4, dst: Ip4, proto: u8, payload_len: usize, id: u16, ttl: u8) void {
    const h = buf[0..ip4_hlen];
    h[0] = 0x45;
    h[1] = 0;
    std.mem.writeInt(u16, h[2..4], @intCast(ip4_hlen + payload_len), .big);
    std.mem.writeInt(u16, h[4..6], id, .big);
    std.mem.writeInt(u16, h[6..8], 0x4000, .big);
    h[8] = ttl;
    h[9] = proto;
    h[10] = 0;
    h[11] = 0;
    h[12..16].* = src.bytes;
    h[16..20].* = dst.bytes;
    std.mem.writeInt(u16, h[10..12], checksum(h), .big);
}

// ---------------------------------------------------------------------------
// ICMP (RFC 792)
// ---------------------------------------------------------------------------

pub const icmp_hlen = 8;
pub const icmp_echo_reply: u8 = 0;
pub const icmp_unreachable: u8 = 3;
pub const icmp_echo_request: u8 = 8;
pub const icmp_time_exceeded: u8 = 11;
pub const icmp_port_unreachable: u8 = 3;

pub const Icmp = struct {
    kind: u8,
    code: u8,
    /// Identifier and sequence of echo messages.
    id: u16,
    seq: u16,
    /// Echo data, or the offending IP header + 8 bytes of error messages.
    data: []const u8,

    pub fn parse(p: []const u8) ?Icmp {
        if (p.len < icmp_hlen) return null;
        if (checksum(p) != 0) return null;
        return .{
            .kind = p[0],
            .code = p[1],
            .id = std.mem.readInt(u16, p[4..6], .big),
            .seq = std.mem.readInt(u16, p[6..8], .big),
            .data = p[icmp_hlen..],
        };
    }
};

/// Write an ICMP header in front of `buf[icmp_hlen..][0..data_len]` and
/// compute the checksum over both.
pub fn writeIcmp(buf: []u8, kind: u8, code: u8, id: u16, seq: u16, data_len: usize) void {
    buf[0] = kind;
    buf[1] = code;
    buf[2] = 0;
    buf[3] = 0;
    std.mem.writeInt(u16, buf[4..6], id, .big);
    std.mem.writeInt(u16, buf[6..8], seq, .big);
    std.mem.writeInt(u16, buf[2..4], checksum(buf[0 .. icmp_hlen + data_len]), .big);
}

// ---------------------------------------------------------------------------
// UDP (RFC 768)
// ---------------------------------------------------------------------------

pub const udp_hlen = 8;

pub const Udp = struct {
    src_port: u16,
    dst_port: u16,
    payload: []const u8,

    /// Parse and verify the checksum (0 = not computed).
    pub fn parse(src: Ip4, dst: Ip4, p: []const u8) ?Udp {
        if (p.len < udp_hlen) return null;
        const len = std.mem.readInt(u16, p[4..6], .big);
        if (len < udp_hlen or len > p.len) return null;
        const sum = std.mem.readInt(u16, p[6..8], .big);
        if (sum != 0 and finish(sumBytes(pseudoSum(src, dst, proto_udp, len), p[0..len])) != 0) return null;
        return .{
            .src_port = std.mem.readInt(u16, p[0..2], .big),
            .dst_port = std.mem.readInt(u16, p[2..4], .big),
            .payload = p[udp_hlen..len],
        };
    }
};

/// Write a UDP header in front of `buf[udp_hlen..][0..payload_len]`.
pub fn writeUdp(buf: []u8, src: Ip4, dst: Ip4, sport: u16, dport: u16, payload_len: usize) void {
    const len = udp_hlen + payload_len;
    std.mem.writeInt(u16, buf[0..2], sport, .big);
    std.mem.writeInt(u16, buf[2..4], dport, .big);
    std.mem.writeInt(u16, buf[4..6], @intCast(len), .big);
    buf[6] = 0;
    buf[7] = 0;
    var sum = finish(sumBytes(pseudoSum(src, dst, proto_udp, len), buf[0..len]));
    if (sum == 0) sum = 0xffff;
    std.mem.writeInt(u16, buf[6..8], sum, .big);
}

// ---------------------------------------------------------------------------
// TCP (RFC 9293)
// ---------------------------------------------------------------------------

pub const tcp_hlen = 20;

pub const TcpFlags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
};

pub const Tcp = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: TcpFlags,
    window: u16,
    /// Maximum segment size option (SYN segments), if present.
    mss: ?u16,
    payload: []const u8,

    /// Parse and verify the checksum.
    pub fn parse(src: Ip4, dst: Ip4, p: []const u8) ?Tcp {
        if (p.len < tcp_hlen) return null;
        const off = @as(usize, p[12] >> 4) * 4;
        if (off < tcp_hlen or off > p.len) return null;
        if (finish(sumBytes(pseudoSum(src, dst, proto_tcp, p.len), p)) != 0) return null;
        var mss: ?u16 = null;
        var opts = p[tcp_hlen..off];
        while (opts.len > 0) {
            const kind = opts[0];
            if (kind == 0) break;
            if (kind == 1) {
                opts = opts[1..];
                continue;
            }
            if (opts.len < 2 or opts[1] < 2 or opts[1] > opts.len) break;
            if (kind == 2 and opts[1] == 4) mss = std.mem.readInt(u16, opts[2..4], .big);
            opts = opts[opts[1]..];
        }
        return .{
            .src_port = std.mem.readInt(u16, p[0..2], .big),
            .dst_port = std.mem.readInt(u16, p[2..4], .big),
            .seq = std.mem.readInt(u32, p[4..8], .big),
            .ack = std.mem.readInt(u32, p[8..12], .big),
            .flags = @bitCast(p[13]),
            .window = std.mem.readInt(u16, p[14..16], .big),
            .mss = mss,
            .payload = p[off..],
        };
    }
};

/// Write a TCP header (plus an MSS option when `mss` is set) in front of
/// the payload, which must already be at `buf[headerLen(mss)..]`.
pub fn writeTcp(buf: []u8, src: Ip4, dst: Ip4, sport: u16, dport: u16, seq: u32, ack: u32, flags: TcpFlags, window: u16, mss: ?u16, payload_len: usize) void {
    const hlen = tcpHeaderLen(mss);
    std.mem.writeInt(u16, buf[0..2], sport, .big);
    std.mem.writeInt(u16, buf[2..4], dport, .big);
    std.mem.writeInt(u32, buf[4..8], seq, .big);
    std.mem.writeInt(u32, buf[8..12], ack, .big);
    buf[12] = @intCast((hlen / 4) << 4);
    buf[13] = @bitCast(flags);
    std.mem.writeInt(u16, buf[14..16], window, .big);
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = 0;
    buf[19] = 0;
    if (mss) |m| {
        buf[20] = 2;
        buf[21] = 4;
        std.mem.writeInt(u16, buf[22..24], m, .big);
    }
    const len = hlen + payload_len;
    std.mem.writeInt(u16, buf[16..18], finish(sumBytes(pseudoSum(src, dst, proto_tcp, len), buf[0..len])), .big);
}

pub fn tcpHeaderLen(mss: ?u16) usize {
    return if (mss != null) tcp_hlen + 4 else tcp_hlen;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "address parsing and formatting" {
    const ip = Ip4.parse("10.0.2.15").?;
    try std.testing.expectEqual(@as(u32, 0x0a00020f), ip.toU32());
    try std.testing.expect(Ip4.parse("10.0.2") == null);
    try std.testing.expect(Ip4.parse("10.0.2.256") == null);
    try std.testing.expect(Ip4.parse("10.0.2.1.1") == null);
    try std.testing.expect(Ip4.parse("a.b.c.d") == null);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.2.15", try std.fmt.bufPrint(&buf, "{f}", .{ip}));
    const mac = Mac.parse("52:54:00:12:34:56").?;
    try std.testing.expectEqualStrings("52:54:00:12:34:56", try std.fmt.bufPrint(&buf, "{f}", .{mac}));
    try std.testing.expectEqual(@as(u6, 24), Ip4.init(255, 255, 255, 0).prefixLen());
    try std.testing.expect(Ip4.subnetBroadcast(ip, Ip4.init(255, 255, 255, 0)).eql(Ip4.init(10, 0, 2, 255)));
}

test "checksum (RFC 1071 example)" {
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0x220d), checksum(&data));
    // Odd length and a buffer longer than the unrolled loop.
    var big: [37]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    var slow: u32 = 0;
    var i: usize = 0;
    while (i + 1 < big.len) : (i += 2) slow += @as(u32, big[i]) << 8 | big[i + 1];
    slow += @as(u32, big[big.len - 1]) << 8;
    try std.testing.expectEqual(finish(slow), checksum(&big));
}

test "ip/udp/tcp round trips" {
    var buf: [128]u8 = undefined;
    const a = Ip4.init(10, 0, 0, 1);
    const b = Ip4.init(10, 0, 0, 2);
    @memcpy(buf[ip4_hlen + udp_hlen ..][0..5], "hello");
    writeUdp(buf[ip4_hlen..], a, b, 1234, 53, 5);
    writeIp4(&buf, a, b, proto_udp, udp_hlen + 5, 7, 64);
    const ip = Ip4Packet.parse(buf[0 .. ip4_hlen + udp_hlen + 5]).?;
    try std.testing.expect(ip.src.eql(a) and ip.dst.eql(b));
    try std.testing.expectEqual(proto_udp, ip.proto);
    const u = Udp.parse(ip.src, ip.dst, ip.payload).?;
    try std.testing.expectEqual(@as(u16, 53), u.dst_port);
    try std.testing.expectEqualStrings("hello", u.payload);
    // A flipped bit fails the checksum.
    buf[ip4_hlen + udp_hlen] ^= 1;
    try std.testing.expect(Udp.parse(a, b, ip.payload) == null);

    @memcpy(buf[24..27], "abc");
    writeTcp(&buf, a, b, 80, 5000, 100, 200, .{ .syn = true, .ack = true }, 4096, 1460, 3);
    const t = Tcp.parse(a, b, buf[0..27]).?;
    try std.testing.expectEqual(@as(?u16, 1460), t.mss);
    try std.testing.expect(t.flags.syn and t.flags.ack and !t.flags.fin);
    try std.testing.expectEqual(@as(u32, 100), t.seq);
    try std.testing.expectEqualStrings("abc", t.payload);
}
