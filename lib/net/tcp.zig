//! TCP (RFC 9293): connection state machine, sliding window, MSS option,
//! retransmission with RFC 6298 timers and exponential backoff, slow
//! start / congestion avoidance with fast retransmit, delayed ACKs,
//! zero-window probes, FIN/RST handling, TIME_WAIT and listen backlogs.
//!
//! Receivers keep in-order data only: an out-of-order segment is dropped
//! and answered with a duplicate ACK, which makes the sender retransmit
//! (go-back-N from the first unacknowledged byte).

const std = @import("std");
const wire = @import("wire.zig");
const Ring = @import("ring.zig").Ring;
const stack_mod = @import("stack.zig");
const Stack = stack_mod.Stack;
const Handle = stack_mod.Handle;
const Ip4 = wire.Ip4;

pub const State = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,

    /// A connection that has completed (or is completing) its handshake.
    pub fn synchronized(s: State) bool {
        return switch (s) {
            .closed, .listen, .syn_sent => false,
            else => true,
        };
    }
};

pub const Error = error{ ConnectionRefused, ConnectionReset, TimedOut, HostUnreachable };

pub const Config = struct {
    rcvbuf: usize = 64 * 1024,
    sndbuf: usize = 64 * 1024,
    rto_initial_ms: u32 = 1000,
    rto_min_ms: u32 = 200,
    rto_max_ms: u32 = 60_000,
    /// 2×MSL.
    time_wait_ms: u32 = 60_000,
    /// Orphaned FIN_WAIT_2 connections are dropped after this.
    fin_wait2_ms: u32 = 60_000,
    delayed_ack_ms: u32 = 40,
    syn_retries: u8 = 5,
    data_retries: u8 = 10,
};

/// Sequence-number comparisons (modulo 2^32).
fn lt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}
fn le(a: u32, b: u32) bool {
    return !lt(b, a);
}
fn gt(a: u32, b: u32) bool {
    return lt(b, a);
}
fn ge(a: u32, b: u32) bool {
    return !lt(a, b);
}

pub const Tcb = struct {
    state: State = .closed,
    local_ip: Ip4 = Ip4.any,
    local_port: u16 = 0,
    remote_ip: Ip4 = Ip4.any,
    remote_port: u16 = 0,

    // Send side. The send buffer holds the bytes from `snd_buf_seq` on:
    // unacknowledged ones first, then unsent ones.
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    /// Highest sequence number sent (snd_nxt goes back on retransmission).
    snd_max: u32 = 0,
    snd_wnd: u32 = 0,
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    snd_buf_seq: u32 = 0,
    /// Effective send MSS.
    mss: u16 = 536,
    fin_requested: bool = false,
    fin_sent: bool = false,

    // Receive side.
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    /// Right edge of the window last advertised.
    rcv_adv: u32 = 0,
    peer_fin: bool = false,

    sndbuf: Ring = .{ .buf = &.{} },
    rcvbuf: Ring = .{ .buf = &.{} },

    // Timers (0 = off) and RTT estimation.
    rto: u32 = 1000,
    srtt: u32 = 0,
    rttvar: u32 = 0,
    has_rtt: bool = false,
    rtt_timing: bool = false,
    rtt_seq: u32 = 0,
    rtt_start: u64 = 0,
    rtx_deadline: u64 = 0,
    retries: u8 = 0,
    dack_deadline: u64 = 0,
    ack_pending: u8 = 0,
    ack_now: bool = false,
    /// TIME_WAIT expiry or the orphaned FIN_WAIT_2 limit.
    linger_deadline: u64 = 0,

    // Congestion control.
    cwnd: u32 = 0,
    ssthresh: u32 = 0xffff_ffff,
    dupacks: u8 = 0,
    in_recovery: bool = false,
    recover: u32 = 0,

    // Listening sockets: connections waiting for accept (handles).
    backlog: u16 = 0,
    queue: std.ArrayList(Handle) = .empty,
    /// For a connection not yet accepted: its listener.
    parent: Handle = 0,
    /// The user closed the handle; free when the connection is done.
    detached: bool = false,
    err: ?Error = null,

    pub fn deinit(self: *Tcb, allocator: std.mem.Allocator) void {
        if (self.sndbuf.buf.len > 0) self.sndbuf.deinit(allocator);
        if (self.rcvbuf.buf.len > 0) self.rcvbuf.deinit(allocator);
        self.queue.deinit(allocator);
    }

    pub fn allocBuffers(self: *Tcb, allocator: std.mem.Allocator, cfg: Config) !void {
        self.sndbuf = try Ring.init(allocator, cfg.sndbuf);
        errdefer self.sndbuf.deinit(allocator);
        self.rcvbuf = try Ring.init(allocator, cfg.rcvbuf);
    }

    pub fn rcvWindow(self: *const Tcb) u32 {
        return @intCast(@min(self.rcvbuf.free(), 65535));
    }

    /// Bytes written by the user but not yet sent.
    pub fn unsent(self: *const Tcb) usize {
        const off = self.snd_nxt -% self.snd_buf_seq;
        return if (off <= self.sndbuf.len) self.sndbuf.len - off else 0;
    }

    fn inWindow(self: *const Tcb, seq: u32, wnd: u32) bool {
        return le(self.rcv_nxt, seq) and lt(seq, self.rcv_nxt +% wnd);
    }

    /// RFC 9293 segment acceptability test.
    fn acceptable(self: *const Tcb, seq: u32, len: u32) bool {
        const wnd = self.rcvWindow();
        if (wnd == 0) return seq == self.rcv_nxt;
        if (len == 0) return self.inWindow(seq, wnd);
        return self.inWindow(seq, wnd) or self.inWindow(seq +% len -% 1, wnd);
    }

    pub fn nextDeadline(self: *const Tcb) ?u64 {
        var best: ?u64 = null;
        for ([_]u64{ self.rtx_deadline, self.dack_deadline, self.linger_deadline }) |d| {
            if (d != 0) best = if (best) |b| @min(b, d) else d;
        }
        return best;
    }
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn ourMss(s: *const Stack) u16 {
    return s.mtu - wire.ip4_hlen - wire.tcp_hlen;
}

/// Send one segment. `len` payload bytes come from the send buffer at
/// sequence number `seq`.
fn sendSegment(s: *Stack, t: *Tcb, seq: u32, flags: wire.TcpFlags, len: usize, with_mss: bool) void {
    var f = flags;
    // Everything but the initial SYN of an active open carries an ACK.
    if (!(f.syn and t.state == .syn_sent)) f.ack = true;
    const mss: ?u16 = if (with_mss) ourMss(s) else null;
    const hlen = wire.tcpHeaderLen(mss);
    const seg = s.l4Buffer();
    if (len > 0) _ = t.sndbuf.peek(seq -% t.snd_buf_seq, seg[hlen..][0..len]);
    const wnd = t.rcvWindow();
    var ack: u32 = 0;
    if (f.ack) {
        ack = t.rcv_nxt;
        t.rcv_adv = t.rcv_nxt +% wnd;
        t.ack_pending = 0;
        t.ack_now = false;
        t.dack_deadline = 0;
    }
    wire.writeTcp(seg, t.local_ip, t.remote_ip, t.local_port, t.remote_port, seq, ack, f, @intCast(wnd), mss, len);
    s.ipSend(t.remote_ip, wire.proto_tcp, hlen + len, t.local_ip) catch |err| switch (err) {
        error.NoRoute => if (!t.state.synchronized() and t.err == null) fail(s, t, error.HostUnreachable),
        else => {},
    };
}

fn sendAck(s: *Stack, t: *Tcb) void {
    sendSegment(s, t, t.snd_nxt, .{ .ack = true }, 0, false);
}

fn armRtx(s: *Stack, t: *Tcb) void {
    if (t.rtx_deadline == 0) t.rtx_deadline = s.now + t.rto;
}

/// Send whatever the windows allow, the FIN when due, and pending ACKs.
pub fn output(s: *Stack, t: *Tcb) void {
    switch (t.state) {
        .closed, .listen => return,
        .time_wait => {
            if (t.ack_now) sendAck(s, t);
            return;
        },
        .syn_sent, .syn_received => {
            if (t.snd_nxt == t.iss) {
                const synack = t.state == .syn_received;
                sendSegment(s, t, t.iss, .{ .syn = true, .ack = synack }, 0, true);
                if (t.state == .closed) return;
                t.snd_nxt = t.iss +% 1;
                if (gt(t.snd_nxt, t.snd_max)) t.snd_max = t.snd_nxt;
                if (!t.rtt_timing and t.retries == 0) {
                    t.rtt_timing = true;
                    t.rtt_seq = t.iss;
                    t.rtt_start = s.now;
                }
                armRtx(s, t);
            } else if (t.ack_now and t.state == .syn_received) {
                sendAck(s, t);
            }
            return;
        },
        else => {},
    }
    const can_fin = switch (t.state) {
        .established, .close_wait, .fin_wait_1, .closing, .last_ack => true,
        else => false,
    };
    var sent = false;
    while (true) {
        const off: usize = t.snd_nxt -% t.snd_buf_seq;
        const buffered = t.sndbuf.len;
        if (off > buffered) break; // only the FIN lies beyond, and it was sent
        const avail = buffered - off;
        const flight: usize = t.snd_nxt -% t.snd_una;
        const wnd: usize = @min(t.snd_wnd, t.cwnd);
        const usable = if (wnd > flight) wnd - flight else 0;
        var n = @min(@min(avail, usable), t.mss);
        // Don't send a window-limited runt while data is in flight.
        if (n < t.mss and n < avail and flight > 0) n = 0;
        const fin = t.fin_requested and can_fin and off + n == buffered;
        if (n == 0 and !fin) break;
        const seq = t.snd_nxt;
        sendSegment(s, t, seq, .{ .ack = true, .psh = n > 0 and off + n == buffered, .fin = fin }, n, false);
        t.snd_nxt +%= @intCast(n + @intFromBool(fin));
        if (gt(t.snd_nxt, t.snd_max)) {
            // New data: time one segment at a time (Karn).
            if (!t.rtt_timing) {
                t.rtt_timing = true;
                t.rtt_seq = seq;
                t.rtt_start = s.now;
            }
            t.snd_max = t.snd_nxt;
        }
        armRtx(s, t);
        sent = true;
        if (fin) {
            if (!t.fin_sent) {
                t.fin_sent = true;
                t.state = switch (t.state) {
                    .established => .fin_wait_1,
                    .close_wait => .last_ack,
                    else => t.state,
                };
            }
            break;
        }
    }
    if (!sent and t.ack_now) sendAck(s, t);
    // Zero window with data waiting: the retransmission timer probes it.
    if (t.snd_wnd == 0 and t.unsent() > 0 and t.snd_nxt == t.snd_una) armRtx(s, t);
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

fn fail(s: *Stack, t: *Tcb, err: Error) void {
    _ = s;
    t.err = err;
    enterClosed(t);
}

/// Fail a connection attempt from outside (ICMP errors, ARP failure).
pub fn failConnect(t: *Tcb, err: Error) void {
    t.err = err;
    enterClosed(t);
}

fn enterClosed(t: *Tcb) void {
    t.state = .closed;
    t.rtx_deadline = 0;
    t.dack_deadline = 0;
    t.linger_deadline = 0;
}

fn onRetransmitTimeout(s: *Stack, t: *Tcb) void {
    t.rtx_deadline = 0;
    const cfg = s.tcp_cfg;
    const synchronized = t.state.synchronized();
    // Zero-window probe: nothing in flight, the peer's window is closed.
    if (synchronized and t.snd_wnd == 0 and t.snd_nxt == t.snd_una and t.unsent() > 0) {
        const seq = t.snd_nxt;
        sendSegment(s, t, seq, .{ .ack = true }, 1, false);
        t.snd_nxt +%= 1;
        if (gt(t.snd_nxt, t.snd_max)) t.snd_max = t.snd_nxt;
        t.rto = @min(t.rto * 2, cfg.rto_max_ms);
        armRtx(s, t);
        return;
    }
    if (t.snd_una == t.snd_max and synchronized) return;
    t.retries += 1;
    const limit = if (synchronized) cfg.data_retries else cfg.syn_retries;
    if (t.retries > limit) {
        fail(s, t, error.TimedOut);
        return;
    }
    t.rto = @min(t.rto * 2, cfg.rto_max_ms);
    const flight = t.snd_max -% t.snd_una;
    t.ssthresh = @max(flight / 2, 2 * @as(u32, t.mss));
    t.cwnd = t.mss;
    t.in_recovery = false;
    t.dupacks = 0;
    t.rtt_timing = false;
    // Go back and resend from the first unacknowledged byte.
    t.snd_nxt = if (synchronized and t.state != .syn_received) t.snd_una else t.iss;
    output(s, t);
}

/// Run the connection's expired timers.
pub fn timers(s: *Stack, t: *Tcb) void {
    const now = s.now;
    if (t.dack_deadline != 0 and now >= t.dack_deadline) {
        t.dack_deadline = 0;
        t.ack_now = true;
        output(s, t);
    }
    if (t.rtx_deadline != 0 and now >= t.rtx_deadline) onRetransmitTimeout(s, t);
    if (t.linger_deadline != 0 and now >= t.linger_deadline) {
        t.linger_deadline = 0;
        if (t.state == .time_wait or t.state == .fin_wait_2) enterClosed(t);
    }
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Answer a segment that has no connection with a reset.
pub fn sendReset(s: *Stack, local: Ip4, remote: Ip4, seg: wire.Tcp) void {
    if (seg.flags.rst) return;
    const buf = s.l4Buffer();
    if (seg.flags.ack) {
        wire.writeTcp(buf, local, remote, seg.dst_port, seg.src_port, seg.ack, 0, .{ .rst = true }, 0, null, 0);
    } else {
        const len: u32 = @intCast(seg.payload.len + @intFromBool(seg.flags.syn) + @intFromBool(seg.flags.fin));
        wire.writeTcp(buf, local, remote, seg.dst_port, seg.src_port, 0, seg.seq +% len, .{ .rst = true, .ack = true }, 0, null, 0);
    }
    s.ipSend(remote, wire.proto_tcp, wire.tcp_hlen, local) catch {};
}

/// Send a reset for an open connection (abort).
pub fn abort(s: *Stack, t: *Tcb) void {
    if (t.state.synchronized() and t.state != .time_wait) {
        sendSegment(s, t, t.snd_nxt, .{ .rst = true, .ack = true }, 0, false);
    }
    enterClosed(t);
}

fn updateRtt(s: *Stack, t: *Tcb, sample: u64) void {
    const r: u32 = @intCast(@min(sample, 60_000));
    if (!t.has_rtt) {
        t.srtt = r;
        t.rttvar = r / 2;
        t.has_rtt = true;
    } else {
        const d = if (t.srtt > r) t.srtt - r else r - t.srtt;
        t.rttvar = (3 * t.rttvar + d) / 4;
        t.srtt = (7 * t.srtt + r) / 8;
    }
    t.rto = std.math.clamp(t.srtt + @max(1, 4 * t.rttvar), s.tcp_cfg.rto_min_ms, s.tcp_cfg.rto_max_ms);
}

fn setMss(s: *const Stack, t: *Tcb, peer: ?u16) void {
    t.mss = @max(64, @min(peer orelse 536, ourMss(s)));
    t.cwnd = 10 * @as(u32, t.mss);
}

/// Process the ACK field of a segment on a synchronized connection.
/// Returns false when the segment must be dropped.
fn processAck(s: *Stack, t: *Tcb, seg: wire.Tcp) bool {
    const ack = seg.ack;
    if (gt(ack, t.snd_max)) {
        // Acknowledges something never sent.
        t.ack_now = true;
        return false;
    }
    if (gt(ack, t.snd_una)) {
        const acked = ack -% t.snd_una;
        if (t.rtt_timing and gt(ack, t.rtt_seq)) {
            t.rtt_timing = false;
            updateRtt(s, t, s.now -| t.rtt_start);
        }
        if (gt(ack, t.snd_buf_seq)) {
            const data: usize = @min(ack -% t.snd_buf_seq, t.sndbuf.len);
            t.sndbuf.discard(data);
            t.snd_buf_seq +%= @intCast(data);
        }
        t.snd_una = ack;
        if (lt(t.snd_nxt, t.snd_una)) t.snd_nxt = t.snd_una;
        if (t.in_recovery and ge(ack, t.recover)) t.in_recovery = false;
        if (!t.in_recovery) {
            if (t.cwnd < t.ssthresh) {
                t.cwnd += @min(acked, t.mss);
            } else {
                t.cwnd += @max(1, @as(u32, t.mss) * t.mss / t.cwnd);
            }
        }
        t.dupacks = 0;
        t.retries = 0;
        t.rtx_deadline = if (t.snd_una == t.snd_max) 0 else s.now + t.rto;
    } else if (ack == t.snd_una and seg.payload.len == 0 and !seg.flags.fin and seg.window == t.snd_wnd and t.snd_max != t.snd_una) {
        t.dupacks +|= 1;
        if (t.dupacks == 3 and !t.in_recovery) {
            // Fast retransmit: halve the window and go back.
            const flight = t.snd_max -% t.snd_una;
            t.ssthresh = @max(flight / 2, 2 * @as(u32, t.mss));
            t.cwnd = t.ssthresh;
            t.in_recovery = true;
            t.recover = t.snd_max;
            t.rtt_timing = false;
            t.snd_nxt = t.snd_una;
        }
    }
    // Window update (RFC 9293 3.10.7.4).
    if (le(t.snd_una, ack) and (lt(t.snd_wl1, seg.seq) or (t.snd_wl1 == seg.seq and le(t.snd_wl2, ack)))) {
        if (seg.window != 0 and t.snd_wnd == 0) t.retries = 0;
        t.snd_wnd = seg.window;
        t.snd_wl1 = seg.seq;
        t.snd_wl2 = ack;
    }
    if (t.fin_sent and t.snd_una == t.snd_max) {
        // Our FIN is acknowledged.
        switch (t.state) {
            .fin_wait_1 => {
                t.state = .fin_wait_2;
                if (t.detached) t.linger_deadline = s.now + s.tcp_cfg.fin_wait2_ms;
            },
            .closing => enterTimeWait(s, t),
            .last_ack => {
                enterClosed(t);
                return false;
            },
            else => {},
        }
    }
    return true;
}

fn enterTimeWait(s: *Stack, t: *Tcb) void {
    t.state = .time_wait;
    t.rtx_deadline = 0;
    t.linger_deadline = s.now + s.tcp_cfg.time_wait_ms;
}

/// Accept in-order data and the FIN.
fn processData(s: *Stack, t: *Tcb, seg: wire.Tcp) void {
    var data = seg.payload;
    var seq = seg.seq;
    var fin = seg.flags.fin;
    const receiving = switch (t.state) {
        .established, .fin_wait_1, .fin_wait_2 => true,
        else => false,
    };
    if (!receiving) {
        // The peer already sent its FIN: answer retransmissions.
        if (fin or data.len > 0) t.ack_now = true;
        return;
    }
    if (lt(seq, t.rcv_nxt)) {
        const dup = t.rcv_nxt -% seq;
        if (dup >= data.len) {
            data = data[data.len..];
            if (fin and seq +% @as(u32, @intCast(seg.payload.len)) != t.rcv_nxt) fin = false;
        } else {
            data = data[dup..];
        }
        seq = t.rcv_nxt;
    }
    if (seq != t.rcv_nxt) {
        // Out of order: drop it and send a duplicate ACK.
        t.ack_now = true;
        return;
    }
    if (data.len > 0) {
        const n = t.rcvbuf.write(data);
        t.rcv_nxt +%= @intCast(n);
        if (t.detached) t.rcvbuf.clear();
        if (n < data.len) {
            fin = false;
            t.ack_now = true;
        }
        t.ack_pending +|= 1;
        if (t.ack_pending >= 2) {
            t.ack_now = true;
        } else if (t.dack_deadline == 0) {
            t.dack_deadline = s.now + s.tcp_cfg.delayed_ack_ms;
        }
    }
    if (fin) {
        t.peer_fin = true;
        t.rcv_nxt +%= 1;
        t.ack_now = true;
        switch (t.state) {
            .established => t.state = .close_wait,
            .fin_wait_1 => t.state = .closing,
            .fin_wait_2 => enterTimeWait(s, t),
            else => {},
        }
    }
}

/// A segment for connection `t` (not a listener).
pub fn input(s: *Stack, t: *Tcb, seg: wire.Tcp) void {
    switch (t.state) {
        .closed, .listen => return,
        .syn_sent => return synSent(s, t, seg),
        .time_wait => {
            if (seg.flags.rst) {
                enterClosed(t);
            } else if (seg.flags.fin) {
                t.ack_now = true;
                t.linger_deadline = s.now + s.tcp_cfg.time_wait_ms;
                output(s, t);
            }
            return;
        },
        else => {},
    }
    const seg_len: u32 = @intCast(seg.payload.len + @intFromBool(seg.flags.syn) + @intFromBool(seg.flags.fin));
    if (!t.acceptable(seg.seq, seg_len)) {
        if (!seg.flags.rst) {
            t.ack_now = true;
            output(s, t);
        }
        return;
    }
    if (seg.flags.rst) {
        // A passive open that is reset simply goes away.
        if (t.state == .syn_received and t.parent != 0) {
            enterClosed(t);
        } else if (t.state == .last_ack or t.state == .closing) {
            enterClosed(t);
        } else {
            fail(s, t, error.ConnectionReset);
        }
        return;
    }
    if (seg.flags.syn) {
        if (t.state == .syn_received and seg.seq == t.irs) {
            // Our SYN-ACK was lost: send it again.
            t.snd_nxt = t.iss;
            output(s, t);
        } else {
            t.ack_now = true;
            output(s, t);
        }
        return;
    }
    if (!seg.flags.ack) return;
    if (t.state == .syn_received) {
        if (!(gt(seg.ack, t.snd_una) and le(seg.ack, t.snd_max))) {
            sendReset(s, t.local_ip, t.remote_ip, seg);
            return;
        }
        t.state = .established;
        t.snd_wnd = seg.window;
        t.snd_wl1 = seg.seq;
        t.snd_wl2 = seg.ack;
    }
    if (!processAck(s, t, seg)) {
        output(s, t);
        return;
    }
    processData(s, t, seg);
    output(s, t);
}

fn synSent(s: *Stack, t: *Tcb, seg: wire.Tcp) void {
    if (seg.flags.ack and (le(seg.ack, t.iss) or gt(seg.ack, t.snd_max))) {
        sendReset(s, t.local_ip, t.remote_ip, seg);
        return;
    }
    if (seg.flags.rst) {
        if (seg.flags.ack) fail(s, t, error.ConnectionRefused);
        return;
    }
    if (!seg.flags.syn) return;
    t.irs = seg.seq;
    t.rcv_nxt = seg.seq +% 1;
    setMss(s, t, seg.mss);
    t.snd_wnd = seg.window;
    t.snd_wl1 = seg.seq;
    t.snd_wl2 = seg.ack;
    if (seg.flags.ack) {
        if (t.rtt_timing) {
            t.rtt_timing = false;
            updateRtt(s, t, s.now -| t.rtt_start);
        }
        t.snd_una = seg.ack;
        t.state = .established;
        t.retries = 0;
        t.rtx_deadline = 0;
        t.ack_now = true;
    } else {
        // Simultaneous open.
        t.state = .syn_received;
        t.snd_nxt = t.iss;
    }
    output(s, t);
}

/// A SYN for a listening socket: create the embryonic connection.
pub fn listenInput(s: *Stack, listener: Handle, local: Ip4, remote: Ip4, seg: wire.Tcp) void {
    if (seg.flags.rst) return;
    if (seg.flags.ack) {
        sendReset(s, local, remote, seg);
        return;
    }
    if (!seg.flags.syn) return;
    const l = s.tcb(listener) orelse return;
    if (l.queue.items.len >= l.backlog) return; // full: the peer retries
    const h = s.newTcb() catch return;
    const t = s.tcb(h).?;
    t.state = .syn_received;
    t.local_ip = local;
    t.local_port = seg.dst_port;
    t.remote_ip = remote;
    t.remote_port = seg.src_port;
    t.irs = seg.seq;
    t.rcv_nxt = seg.seq +% 1;
    t.iss = s.random().int(u32);
    t.snd_una = t.iss;
    t.snd_nxt = t.iss;
    t.snd_max = t.iss;
    t.snd_buf_seq = t.iss +% 1;
    t.snd_wnd = seg.window;
    t.snd_wl1 = seg.seq;
    t.rto = s.tcp_cfg.rto_initial_ms;
    setMss(s, t, seg.mss);
    t.parent = listener;
    const lp = s.tcb(listener).?;
    lp.queue.append(s.allocator, h) catch {
        s.freeSock(h);
        return;
    };
    output(s, t);
}

/// Start an active open on a fresh connection block.
pub fn connect(s: *Stack, t: *Tcb) void {
    t.state = .syn_sent;
    t.iss = s.random().int(u32);
    t.snd_una = t.iss;
    t.snd_nxt = t.iss;
    t.snd_max = t.iss;
    t.snd_buf_seq = t.iss +% 1;
    t.rto = s.tcp_cfg.rto_initial_ms;
    output(s, t);
}

/// The user closes its side: send a FIN after the queued data.
pub fn shutdown(s: *Stack, t: *Tcb) void {
    switch (t.state) {
        .syn_sent, .closed, .listen => enterClosed(t),
        .syn_received, .established, .close_wait => {
            t.fin_requested = true;
            if (t.state != .syn_received) output(s, t);
        },
        else => {},
    }
}
