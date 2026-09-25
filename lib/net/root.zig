//! lib/net: Zen's TCP/IP stack.
//!
//! An OS-independent IPv4 stack for one Ethernet interface: ARP, IPv4,
//! ICMP echo, UDP, TCP, a DHCP client and a DNS stub resolver. It does no
//! system calls: the owner passes in received frames and the current time
//! and gets frames to transmit through a callback (see `Stack`). netd runs
//! it over the virtio-net driver (`netdev:0`); the unit tests wire two
//! stacks together in memory; `tests/tap.zig` attaches it to a Linux TAP
//! device.

pub const wire = @import("wire.zig");
pub const arp = @import("arp.zig");
pub const tcp = @import("tcp.zig");
pub const dhcp = @import("dhcp.zig");
pub const dns = @import("dns.zig");
pub const Ring = @import("ring.zig").Ring;

const stack = @import("stack.zig");
pub const Stack = stack.Stack;
pub const Config = stack.Config;
pub const IfConfig = stack.IfConfig;
pub const Output = stack.Output;
pub const Handle = stack.Handle;
pub const Error = stack.Error;
pub const Ready = stack.Ready;
pub const Endpoint = stack.Endpoint;
pub const Datagram = stack.Datagram;
pub const PingReply = stack.PingReply;
pub const Stats = stack.Stats;

pub const Ip4 = wire.Ip4;
pub const Mac = wire.Mac;

test {
    _ = wire;
    _ = arp;
    _ = tcp;
    _ = dhcp;
    _ = dns;
    _ = @import("ring.zig");
    _ = stack;
    _ = @import("tests.zig");
}
