//! Networking ABI: the URLs served by netd and the `netdev:` interface of
//! network drivers. See docs/NETWORKING.md for the full description.
//!
//! netd (`servers/netd`) serves these schemes. HOST is a dotted IPv4
//! address or a name, resolved through /etc/hosts and then DNS.
//!
//! | URL                        | open                          | read                                  | write                        |
//! |----------------------------|-------------------------------|---------------------------------------|------------------------------|
//! | `tcp:HOST:PORT`            | connect (blocks until done)   | stream bytes, 0 = peer closed         | stream bytes                 |
//! | `tcp:listen/PORT[?backlog=N]` | listen (PORT 0 = any)      | one line per new connection: `tcp:conn/ID ADDR:PORT\n` | —            |
//! | `tcp:conn/ID`              | take that accepted connection | stream                                | stream                       |
//! | `udp:HOST:PORT`            | socket with a fixed peer      | one datagram (payload)                | one datagram (payload)       |
//! | `udp:bind/PORT`            | socket bound to PORT (0 = any)| `UdpHeader` (sender) + payload        | `UdpHeader` (target) + payload |
//! | `icmp:HOST`                | echo socket for HOST          | one `Echo` per reply                  | `Echo` + payload: send one echo request |
//! | `dns:NAME`                 | resolve (blocks until done)   | one address per line                  | —                            |
//! | `net:`                     | interface status snapshot     | `key value` lines (see `status_keys`) | —                            |
//!
//! Connections opened with O_NONBLOCK return at once; the handle then
//! reports POLLOUT when connected, POLLERR|POLLHUP when the attempt failed
//! (the error is read with `ioctl_error`), and reads/writes return EAGAIN
//! instead of blocking. `fpath` on a socket returns `LOCAL REMOTE`
//! (`10.0.2.15:49152 93.184.216.34:80`), or `listen/PORT` / `bind/PORT`.
//! Binding a port below 1024 needs uid 0. An accepted connection may only
//! be opened by the listener's owner (or root) within 30 seconds.
//!
//! Network drivers serve `netdev:N` (virtio-net: `drivers/virtio-net`):
//! `read` returns exactly one Ethernet frame (without FCS; blocks, or
//! EAGAIN with O_NONBLOCK), `write` sends one frame, and reading
//! `netdev:N/info` returns a `NetdevInfo`. Both need uid 0.

const std = @import("std");

/// Largest Ethernet frame without the FCS (1500-byte MTU).
pub const max_frame = 1514;

pub const NETDEV_LINK_UP: u32 = 1;

/// Contents of `netdev:N/info`.
pub const NetdevInfo = extern struct {
    mac: [6]u8,
    /// IP MTU (payload of a frame).
    mtu: u16,
    /// NETDEV_* bits.
    flags: u32 = 0,
    rx_frames: u64 = 0,
    tx_frames: u64 = 0,
    /// Frames the device received while no buffer was free.
    rx_dropped: u64 = 0,
};

/// Framing of `udp:bind/PORT`: every read and write carries one datagram
/// preceded by this header (sender on read, destination on write).
pub const UdpHeader = extern struct {
    /// IPv4 address, network order (as written: 10.0.2.2 = {10,0,2,2}).
    addr: [4]u8,
    /// Host byte order.
    port: u16,
    reserved: u16 = 0,
};

/// Framing of `icmp:HOST`. Write: an `Echo` (only `seq` is used) followed
/// by the payload sends one echo request. Read: one `Echo` per reply.
pub const Echo = extern struct {
    seq: u16,
    ttl: u8 = 0,
    reserved: u8 = 0,
    /// Payload bytes of the reply.
    len: u16 = 0,
    reserved2: u16 = 0,
    /// Round-trip time measured by netd, in microseconds.
    rtt_us: u32 = 0,
    /// Address the reply came from.
    from: [4]u8 = .{ 0, 0, 0, 0 },
};

/// ioctl requests on netd socket handles (the kernel's BSD socket layer
/// uses them; see docs/NETWORKING.md).
/// Shut down the sending side of a TCP connection (FIN); reads go on.
pub const ioctl_shutdown: u32 = 0x5a4e0001;
/// Output: i32, the pending error as a negative errno (0 = none).
pub const ioctl_error: u32 = 0x5a4e0002;
/// Output: i32, bytes that can be read without blocking.
pub const FIONREAD: u32 = 0x541B;

/// Keys of the `net:` status text, one `key value` line each.
pub const status_keys = [_][]const u8{
    "interface", // name (eth0) and "up"/"down"/"none"
    "mac",
    "mtu",
    "config", // dhcp | static | host
    "dhcp", // DHCP client state (selecting, bound, …), lease seconds left
    "address", // A.B.C.D/prefix
    "netmask",
    "gateway",
    "dns", // space-separated servers
    "rx", // frames bytes
    "tx",
};

comptime {
    std.debug.assert(@sizeOf(NetdevInfo) == 40);
    std.debug.assert(@sizeOf(UdpHeader) == 8);
    std.debug.assert(@sizeOf(Echo) == 16);
}

pub const HostPort = struct { host: []const u8, port: u16 };

/// Split `HOST:PORT` (the port follows the last colon).
pub fn parseHostPort(s: []const u8) ?HostPort {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    if (colon == 0 or colon + 1 >= s.len) return null;
    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    return .{ .host = s[0..colon], .port = port };
}

test "host and port" {
    const hp = parseHostPort("example.com:443").?;
    try std.testing.expectEqualStrings("example.com", hp.host);
    try std.testing.expectEqual(@as(u16, 443), hp.port);
    try std.testing.expect(parseHostPort("example.com") == null);
    try std.testing.expect(parseHostPort(":80") == null);
    try std.testing.expect(parseHostPort("a:99999") == null);
}
