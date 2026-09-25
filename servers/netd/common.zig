//! Types shared by netd and its two backends (the lib/net stack on a
//! network driver, and host sockets when Zen runs hosted on Linux).

const std = @import("std");
const net = @import("net");
const linux = std.os.linux;

pub const Ip4 = net.Ip4;
pub const Ready = net.Ready;
pub const Endpoint = net.Endpoint;
pub const Datagram = net.Datagram;
pub const DnsStatus = net.dns.Status;

/// A backend socket.
pub const Conn = u32;

pub const Error = error{
    ConnectionRefused,
    ConnectionReset,
    TimedOut,
    HostUnreachable,
    NetworkUnreachable,
    AddressInUse,
    WouldBlock,
    MessageTooLong,
    NotConnected,
    BadHandle,
    OutOfMemory,
    AccessDenied,
    InvalidArgument,
    NoDevice,
    Unexpected,
};

pub const PingReply = struct {
    from: Ip4,
    seq: u16,
    ttl: u8,
    len: usize,
};

pub const TcpPhase = enum { connecting, open, failed };

/// Map a backend or stack error to the errno of the reply.
pub fn errnoFor(err: anyerror) linux.E {
    return switch (err) {
        error.ConnectionRefused => .CONNREFUSED,
        error.ConnectionReset, error.ConnectionResetByPeer => .CONNRESET,
        error.TimedOut, error.ConnectionTimedOut, error.Timeout => .TIMEDOUT,
        error.HostUnreachable => .HOSTUNREACH,
        error.NetworkUnreachable, error.NoRoute, error.NoDevice, error.NoServers => .NETUNREACH,
        error.AddressInUse => .ADDRINUSE,
        error.WouldBlock => .AGAIN,
        error.MessageTooLong => .MSGSIZE,
        error.NotConnected, error.BrokenPipe => .PIPE,
        error.BadHandle => .BADF,
        error.OutOfMemory, error.TooManyQueries, error.SystemResources => .NOMEM,
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.InvalidArgument, error.InvalidName => .INVAL,
        error.NameNotFound => .NOENT,
        error.ServerFailure => .AGAIN,
        else => .IO,
    };
}

pub fn nowMs() u64 {
    return nowUs() / 1000;
}

pub fn nowUs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}
