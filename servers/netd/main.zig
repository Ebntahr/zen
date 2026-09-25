//! netd — the network server. Serves `tcp:`, `udp:`, `icmp:`, `dns:` and
//! `net:` (URL formats: lib/abi/net.zig, docs/NETWORKING.md).
//!
//! On Zen it runs the lib/net TCP/IP stack on the first network driver
//! (`netdev:0`); hosted on Linux the same URLs are served with host
//! sockets. Blocking operations (connect, resolve, read, a write to a full
//! send buffer, accept, poll) park the request and answer it when the
//! socket is ready, so one thread serves every client.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const net = @import("net");
const common = @import("common.zig");
const StackBackend = @import("stack_backend.zig").StackBackend;
const HostBackend = @import("host_backend.zig").HostBackend;

const sc = abi.scheme;
const posix = std.posix;
const linux = std.os.linux;
const Ip4 = common.Ip4;
const Conn = common.Conn;
const E = linux.E;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

/// Unclaimed accepted connections are closed after this.
const park_ms: u64 = 30_000;
const schemes = [_][]const u8{ "tcp", "udp", "icmp", "dns", "net" };

const Kind = enum { tcp, listener, udp, icmp, text };

const Phase = enum { resolving, connecting, open, failed };

const Handle = struct {
    kind: Kind,
    scheme: u8,
    uid: u32,
    nonblock: bool = false,
    phase: Phase = .open,
    conn: Conn = 0,
    has_conn: bool = false,
    err: ?anyerror = null,
    /// Name resolution in progress (tcp/udp/icmp/dns).
    query: ?u16 = null,
    peer: Ip4 = Ip4.any,
    port: u16 = 0,
    /// udp: a fixed peer (udp:HOST:PORT) instead of framed datagrams.
    connected: bool = false,
    /// dns: and net: text, and its read position.
    text: []u8 = &.{},
    pos: usize = 0,
    /// icmp: send times (µs) by sequence number.
    sent_us: [64]u64 = [_]u64{0} ** 64,
    sent_seq: [64]u16 = [_]u16{0} ** 64,
};

const Pending = struct {
    id: u64,
    handle: u64,
    op: enum { open, read, write, fevent },
    len: u64 = 0,
    events: u32 = 0,
    positioned: bool = false,
    offset: u64 = 0,
    data: []u8 = &.{},
};

const Parked = struct {
    id: u32,
    conn: Conn,
    uid: u32,
    deadline: u64,
};

fn Netd(comptime B: type) type {
    return struct {
        const Self = @This();

        be: *B,
        srv: zen.server.Server,
        handles: zen.server.HandleTable(Handle) = .{},
        pending: std.ArrayList(Pending) = .empty,
        parked: std.ArrayList(Parked) = .empty,
        next_park: u32 = 1,
        now: u64 = 0,
        io: [abi.scheme.MAX_PAYLOAD]u8 = undefined,

        // ---- helpers ----------------------------------------------------------

        fn reply(self: *Self, id: u64, result: i64, data: []const u8) void {
            self.srv.reply(id, result, data) catch {};
        }

        fn fail(self: *Self, id: u64, err: anyerror) void {
            self.srv.replyError(id, common.errnoFor(err)) catch {};
        }

        fn failErrno(self: *Self, id: u64, e: E) void {
            self.srv.replyError(id, e) catch {};
        }

        fn defer_(self: *Self, p: Pending) void {
            self.pending.append(gpa, p) catch self.failErrno(p.id, .NOMEM);
        }

        fn dropPending(self: *Self, i: usize) void {
            const p = self.pending.orderedRemove(i);
            if (p.data.len > 0) gpa.free(p.data);
        }

        /// Resolve HOST: dotted quad, /etc/hosts, then DNS (async).
        fn startResolve(self: *Self, h: *Handle, host: []const u8) !void {
            if (Ip4.parse(host)) |ip| {
                h.peer = ip;
                return;
            }
            var buf: [8192]u8 = undefined;
            if (std.fs.cwd().readFile("/etc/hosts", &buf)) |text| {
                if (net.dns.lookupHosts(text, host)) |ip| {
                    h.peer = ip;
                    return;
                }
            } else |_| {}
            h.query = try self.be.resolve(host);
            h.phase = .resolving;
        }

        /// Addresses of a finished dns: lookup, or the error.
        fn resolved(self: *Self, h: *Handle) ?anyerror!net.dns.Result {
            const q = h.query orelse return null;
            return switch (self.be.resolveStatus(q)) {
                .pending => null,
                .done => |r| blk: {
                    self.be.resolveRelease(q);
                    h.query = null;
                    break :blk r;
                },
                .failed => |e| blk: {
                    self.be.resolveRelease(q);
                    h.query = null;
                    break :blk e;
                },
            };
        }

        /// Create the backend socket once the peer address is known.
        fn activate(self: *Self, h: *Handle) !void {
            switch (h.kind) {
                .tcp => {
                    h.conn = try self.be.tcpConnect(h.peer, h.port);
                    h.has_conn = true;
                    h.phase = .connecting;
                },
                .udp => {
                    h.conn = try self.be.udpOpen(0);
                    h.has_conn = true;
                    h.phase = .open;
                },
                .icmp => {
                    h.conn = try self.be.pingOpen();
                    h.has_conn = true;
                    h.phase = .open;
                },
                else => h.phase = .open,
            }
        }

        /// Drive a handle's resolution and connection. Returns true when
        /// its state changed.
        fn advance(self: *Self, h: *Handle) bool {
            switch (h.phase) {
                .resolving => {
                    const res = self.resolved(h) orelse return false;
                    const r = res catch |err| {
                        h.phase = .failed;
                        h.err = err;
                        return true;
                    };
                    if (h.kind == .text) {
                        var w: std.Io.Writer.Allocating = .init(gpa);
                        for (r.slice()) |a| w.writer.print("{f}\n", .{a}) catch {};
                        h.text = w.toOwnedSlice() catch &.{};
                        h.phase = .open;
                        return true;
                    }
                    h.peer = r.addrs[0];
                    self.activate(h) catch |err| {
                        h.phase = .failed;
                        h.err = err;
                    };
                    return true;
                },
                .connecting => {
                    switch (self.be.tcpPhase(h.conn)) {
                        .connecting => return false,
                        .open => h.phase = .open,
                        .failed => {
                            h.phase = .failed;
                            h.err = self.be.connError(h.conn) orelse error.ConnectionRefused;
                        },
                    }
                    return true;
                },
                else => return false,
            }
        }

        fn readyMask(self: *Self, h: *Handle) u32 {
            switch (h.phase) {
                .resolving, .connecting => return 0,
                .failed => return sc.POLLERR | sc.POLLHUP | sc.POLLIN | sc.POLLOUT,
                .open => {},
            }
            if (h.kind == .text) return sc.POLLIN;
            const r = self.be.ready(h.conn);
            var m: u32 = 0;
            if (r.in) m |= sc.POLLIN;
            if (r.out and h.kind != .listener) m |= sc.POLLOUT;
            if (r.hup) m |= sc.POLLHUP;
            if (r.err) m |= sc.POLLERR;
            return m;
        }

        // ---- open ---------------------------------------------------------------

        fn open(self: *Self, req: sc.Request, path_raw: []const u8, scheme: u8) void {
            const u = zen.url.parse(path_raw);
            const path = u.path;
            const nonblock = req.flags & sc.O_NONBLOCK != 0;
            var h = Handle{ .kind = .text, .scheme = scheme, .uid = req.uid, .nonblock = nonblock };
            const name = schemes[scheme];
            if (std.mem.eql(u8, name, "net")) {
                if (path.len != 0 and !std.mem.eql(u8, path, "status")) return self.failErrno(req.id, .NOENT);
                var w: std.Io.Writer.Allocating = .init(gpa);
                self.be.writeStatus(&w.writer) catch {};
                h.text = w.toOwnedSlice() catch return self.failErrno(req.id, .NOMEM);
                return self.finishOpen(req.id, h);
            }
            if (std.mem.eql(u8, name, "dns")) {
                if (path.len == 0) return self.failErrno(req.id, .NOENT);
                self.startResolve(&h, path) catch |err| return self.fail(req.id, err);
                if (h.phase == .open) h.text = std.fmt.allocPrint(gpa, "{f}\n", .{h.peer}) catch return self.failErrno(req.id, .NOMEM);
                return self.finishOpen(req.id, h);
            }
            if (std.mem.eql(u8, name, "tcp")) {
                if (std.mem.startsWith(u8, path, "listen/")) {
                    const port = std.fmt.parseInt(u16, path["listen/".len..], 10) catch return self.failErrno(req.id, .INVAL);
                    if (port != 0 and port < 1024 and req.uid != 0) return self.failErrno(req.id, .ACCES);
                    const backlog = zen.url.queryInt(u16, u.query, "backlog", 16);
                    h.kind = .listener;
                    h.conn = self.be.tcpListen(port, backlog) catch |err| return self.fail(req.id, err);
                    h.has_conn = true;
                    return self.finishOpen(req.id, h);
                }
                if (std.mem.startsWith(u8, path, "conn/")) {
                    const id = std.fmt.parseInt(u32, path["conn/".len..], 10) catch return self.failErrno(req.id, .NOENT);
                    for (self.parked.items, 0..) |p, i| {
                        if (p.id != id) continue;
                        if (p.uid != req.uid and req.uid != 0) return self.failErrno(req.id, .ACCES);
                        _ = self.parked.swapRemove(i);
                        h.kind = .tcp;
                        h.conn = p.conn;
                        h.has_conn = true;
                        return self.finishOpen(req.id, h);
                    }
                    return self.failErrno(req.id, .NOENT);
                }
                const hp = abi.net.parseHostPort(path) orelse return self.failErrno(req.id, .INVAL);
                h.kind = .tcp;
                h.port = hp.port;
                self.startResolve(&h, hp.host) catch |err| return self.fail(req.id, err);
                if (h.phase == .open) self.activate(&h) catch |err| return self.fail(req.id, err);
                return self.finishOpen(req.id, h);
            }
            if (std.mem.eql(u8, name, "udp")) {
                h.kind = .udp;
                if (std.mem.startsWith(u8, path, "bind/")) {
                    const port = std.fmt.parseInt(u16, path["bind/".len..], 10) catch return self.failErrno(req.id, .INVAL);
                    if (port != 0 and port < 1024 and req.uid != 0) return self.failErrno(req.id, .ACCES);
                    h.conn = self.be.udpOpen(port) catch |err| return self.fail(req.id, err);
                    h.has_conn = true;
                    return self.finishOpen(req.id, h);
                }
                const hp = abi.net.parseHostPort(path) orelse return self.failErrno(req.id, .INVAL);
                h.connected = true;
                h.port = hp.port;
                self.startResolve(&h, hp.host) catch |err| return self.fail(req.id, err);
                if (h.phase == .open) self.activate(&h) catch |err| return self.fail(req.id, err);
                return self.finishOpen(req.id, h);
            }
            if (std.mem.eql(u8, name, "icmp")) {
                if (path.len == 0) return self.failErrno(req.id, .NOENT);
                h.kind = .icmp;
                self.startResolve(&h, path) catch |err| return self.fail(req.id, err);
                if (h.phase == .open) self.activate(&h) catch |err| return self.fail(req.id, err);
                return self.finishOpen(req.id, h);
            }
            self.failErrno(req.id, .NOENT);
        }

        /// Register the handle; answer now, or when it is connected.
        fn finishOpen(self: *Self, id: u64, h: Handle) void {
            const hid = self.handles.insert(gpa, h) catch return self.failErrno(id, .NOMEM);
            const hp = self.handles.get(hid).?;
            _ = self.advance(hp);
            if (hp.phase == .open or (hp.nonblock and hp.kind == .tcp and hp.phase != .failed)) {
                return self.reply(id, @intCast(hid), "");
            }
            if (hp.phase == .failed) {
                const err = hp.err orelse error.Unexpected;
                self.release(hid);
                return self.fail(id, err);
            }
            self.defer_(.{ .id = id, .handle = hid, .op = .open });
        }

        fn release(self: *Self, hid: u64) void {
            var h = self.handles.remove(gpa, hid) orelse return;
            if (h.query) |q| self.be.resolveRelease(q);
            if (h.has_conn) self.be.close(h.conn);
            if (h.text.len > 0) gpa.free(h.text);
            h.text = &.{};
        }

        // ---- read / write ---------------------------------------------------------

        const Outcome = union(enum) { wait, done };

        /// Try to complete a read. `.wait` = not ready yet.
        fn tryRead(self: *Self, id: u64, h: *Handle, len_req: u64, positioned: bool, offset: u64) Outcome {
            const len: usize = @intCast(@min(len_req, self.io.len));
            switch (h.phase) {
                .resolving, .connecting => return .wait,
                .failed => {
                    self.fail(id, h.err orelse error.ConnectionReset);
                    return .done;
                },
                .open => {},
            }
            switch (h.kind) {
                .text => {
                    const pos: usize = if (positioned) @intCast(@min(offset, h.text.len)) else h.pos;
                    const n = @min(len, h.text.len - pos);
                    if (!positioned) h.pos += n;
                    self.reply(id, @intCast(n), h.text[pos..][0..n]);
                },
                .tcp => {
                    const n = self.be.recv(h.conn, self.io[0..len]) catch |err| switch (err) {
                        error.WouldBlock => return .wait,
                        else => {
                            self.fail(id, err);
                            return .done;
                        },
                    };
                    self.reply(id, @intCast(n), self.io[0..n]);
                },
                .listener => {
                    const c = (self.be.tcpAccept(h.conn) catch |err| {
                        self.fail(id, err);
                        return .done;
                    }) orelse return .wait;
                    const pid = self.next_park;
                    self.next_park +%= 1;
                    if (self.next_park == 0) self.next_park = 1;
                    self.parked.append(gpa, .{ .id = pid, .conn = c, .uid = h.uid, .deadline = self.now + park_ms }) catch {
                        self.be.close(c);
                        self.failErrno(id, .NOMEM);
                        return .done;
                    };
                    const r = self.be.remoteEnd(c) orelse common.Endpoint{ .ip = Ip4.any, .port = 0 };
                    const line = std.fmt.bufPrint(&self.io, "tcp:conn/{d} {f}:{d}\n", .{ pid, r.ip, r.port }) catch unreachable;
                    const n = @min(line.len, len);
                    self.reply(id, @intCast(n), line[0..n]);
                },
                .udp => {
                    const hdr = @sizeOf(abi.net.UdpHeader);
                    if (!h.connected and len < hdr) {
                        self.failErrno(id, .INVAL);
                        return .done;
                    }
                    const body = if (h.connected) self.io[0..len] else self.io[hdr..len];
                    while (true) {
                        const d = self.be.udpRecvFrom(h.conn, body) orelse return .wait;
                        if (h.connected) {
                            if (!d.from.eql(h.peer) or d.port != h.port) continue;
                            const n = @min(d.len, body.len);
                            self.reply(id, @intCast(n), body[0..n]);
                        } else {
                            const uh = abi.net.UdpHeader{ .addr = d.from.bytes, .port = d.port };
                            @memcpy(self.io[0..hdr], std.mem.asBytes(&uh));
                            const n = hdr + @min(d.len, body.len);
                            self.reply(id, @intCast(n), self.io[0..n]);
                        }
                        return .done;
                    }
                },
                .icmp => {
                    if (len < @sizeOf(abi.net.Echo)) {
                        self.failErrno(id, .INVAL);
                        return .done;
                    }
                    while (true) {
                        const r = self.be.pingRecv(h.conn) orelse return .wait;
                        if (!r.from.eql(h.peer)) continue;
                        const slot = r.seq % h.sent_us.len;
                        const rtt: u64 = if (h.sent_seq[slot] == r.seq and h.sent_us[slot] != 0) common.nowUs() -| h.sent_us[slot] else 0;
                        const e = abi.net.Echo{
                            .seq = r.seq,
                            .ttl = r.ttl,
                            .len = @intCast(@min(r.len, 0xffff)),
                            .rtt_us = @intCast(@min(rtt, std.math.maxInt(u32))),
                            .from = r.from.bytes,
                        };
                        self.reply(id, @sizeOf(abi.net.Echo), std.mem.asBytes(&e));
                        return .done;
                    }
                },
            }
            return .done;
        }

        fn tryWrite(self: *Self, id: u64, h: *Handle, data: []const u8) Outcome {
            switch (h.phase) {
                .resolving, .connecting => return .wait,
                .failed => {
                    self.fail(id, h.err orelse error.ConnectionReset);
                    return .done;
                },
                .open => {},
            }
            switch (h.kind) {
                .tcp => {
                    const n = self.be.send(h.conn, data) catch |err| switch (err) {
                        error.WouldBlock => return .wait,
                        else => {
                            self.fail(id, err);
                            return .done;
                        },
                    };
                    self.reply(id, @intCast(n), "");
                },
                .udp => {
                    var dst = h.peer;
                    var port = h.port;
                    var body = data;
                    if (!h.connected) {
                        const hdr = @sizeOf(abi.net.UdpHeader);
                        if (data.len < hdr) {
                            self.failErrno(id, .INVAL);
                            return .done;
                        }
                        var uh: abi.net.UdpHeader = undefined;
                        @memcpy(std.mem.asBytes(&uh), data[0..hdr]);
                        dst = .{ .bytes = uh.addr };
                        port = uh.port;
                        body = data[hdr..];
                    }
                    self.be.udpSendTo(h.conn, dst, port, body) catch |err| {
                        self.fail(id, err);
                        return .done;
                    };
                    self.reply(id, @intCast(data.len), "");
                },
                .icmp => {
                    const hdr = @sizeOf(abi.net.Echo);
                    if (data.len < hdr) {
                        self.failErrno(id, .INVAL);
                        return .done;
                    }
                    var e: abi.net.Echo = undefined;
                    @memcpy(std.mem.asBytes(&e), data[0..hdr]);
                    const slot = e.seq % h.sent_us.len;
                    h.sent_seq[slot] = e.seq;
                    h.sent_us[slot] = common.nowUs();
                    self.be.pingSend(h.conn, h.peer, e.seq, data[hdr..]) catch |err| {
                        self.fail(id, err);
                        return .done;
                    };
                    self.reply(id, @intCast(data.len), "");
                },
                else => self.failErrno(id, .BADF),
            }
            return .done;
        }

        // ---- requests ---------------------------------------------------------------

        fn fpath(self: *Self, h: *Handle, out: []u8) []const u8 {
            return switch (h.kind) {
                .listener => std.fmt.bufPrint(out, "listen/{d}", .{if (self.be.localEnd(h.conn)) |e| e.port else 0}) catch "",
                .udp => if (h.connected and h.phase == .open)
                    std.fmt.bufPrint(out, "{f}:{d} {f}:{d}", .{ (self.be.localEnd(h.conn) orelse common.Endpoint{ .ip = Ip4.any, .port = 0 }).ip, (self.be.localEnd(h.conn) orelse common.Endpoint{ .ip = Ip4.any, .port = 0 }).port, h.peer, h.port }) catch ""
                else
                    std.fmt.bufPrint(out, "bind/{d}", .{if (h.has_conn) (if (self.be.localEnd(h.conn)) |e| e.port else 0) else 0}) catch "",
                .tcp => blk: {
                    if (h.phase != .open) break :blk std.fmt.bufPrint(out, "{f}:{d}", .{ h.peer, h.port }) catch "";
                    const l = self.be.localEnd(h.conn) orelse common.Endpoint{ .ip = Ip4.any, .port = 0 };
                    const r = self.be.remoteEnd(h.conn) orelse common.Endpoint{ .ip = h.peer, .port = h.port };
                    break :blk std.fmt.bufPrint(out, "{f}:{d} {f}:{d}", .{ l.ip, l.port, r.ip, r.port }) catch "";
                },
                .icmp => std.fmt.bufPrint(out, "{f}", .{h.peer}) catch "",
                .text => "",
            };
        }

        fn serve(self: *Self, in: zen.server.Incoming) void {
            const req = in.req;
            switch (req.op) {
                .open => return self.open(req, in.payload, self.scheme_of(req)),
                .cancel => {
                    for (self.pending.items, 0..) |p, i| if (p.id == req.arg0) {
                        // A cancelled open still created a handle: drop it.
                        if (p.op == .open) self.release(p.handle);
                        self.dropPending(i);
                        break;
                    };
                    return;
                },
                .stat, .lstat => {
                    const st = sc.Stat{ .mode = sc.S_IFSOCK | 0o666 };
                    return self.srv.replyStruct(req.id, &st) catch {};
                },
                else => {},
            }
            const h = self.handles.get(req.handle) orelse return self.failErrno(req.id, .BADF);
            switch (req.op) {
                .close => {
                    var i: usize = 0;
                    while (i < self.pending.items.len) {
                        if (self.pending.items[i].handle == req.handle) self.dropPending(i) else i += 1;
                    }
                    self.release(req.handle);
                },
                .read => {
                    const positioned = req.arg1 == 1;
                    if (self.tryRead(req.id, h, req.len, positioned, req.arg0) == .wait) {
                        if (h.nonblock) return self.failErrno(req.id, .AGAIN);
                        self.defer_(.{ .id = req.id, .handle = req.handle, .op = .read, .len = req.len, .positioned = positioned, .offset = req.arg0 });
                    }
                },
                .write => {
                    if (self.tryWrite(req.id, h, in.payload) == .wait) {
                        if (h.nonblock) return self.failErrno(req.id, .AGAIN);
                        const copy = gpa.dupe(u8, in.payload) catch return self.failErrno(req.id, .NOMEM);
                        self.defer_(.{ .id = req.id, .handle = req.handle, .op = .write, .data = copy });
                    }
                },
                .fevent => {
                    const want: u32 = @truncate(req.arg0);
                    const m = self.readyMask(h) & (want | sc.POLLERR | sc.POLLHUP);
                    if (m != 0) return self.reply(req.id, m, "");
                    self.defer_(.{ .id = req.id, .handle = req.handle, .op = .fevent, .events = want });
                },
                .fstat => {
                    var st = sc.Stat{ .mode = sc.S_IFSOCK | 0o666, .uid = h.uid };
                    if (h.kind == .text) {
                        st.mode = sc.S_IFREG | 0o444;
                        st.size = @intCast(h.text.len);
                    }
                    self.srv.replyStruct(req.id, &st) catch {};
                },
                .fpath => {
                    var buf: [128]u8 = undefined;
                    self.reply(req.id, 0, self.fpath(h, &buf));
                },
                .ioctl => {
                    const code: u32 = @truncate(req.arg0);
                    var v: i32 = 0;
                    switch (code) {
                        abi.net.FIONREAD => v = switch (h.kind) {
                            .tcp => if (h.phase == .open) @intCast(@min(self.be.available(h.conn), std.math.maxInt(i32))) else 0,
                            .text => @intCast(h.text.len - h.pos),
                            else => 0,
                        },
                        abi.net.ioctl_shutdown => {
                            if (h.kind != .tcp or h.phase != .open) return self.failErrno(req.id, .NOTCONN);
                            self.be.shutdown(h.conn);
                            return self.reply(req.id, 0, "");
                        },
                        abi.net.ioctl_error => {
                            if (h.phase == .failed) v = -@as(i32, @intFromEnum(common.errnoFor(h.err orelse error.ConnectionReset)));
                            if (h.phase == .open and h.has_conn and h.kind == .tcp) {
                                if (self.be.connError(h.conn)) |e| v = -@as(i32, @intFromEnum(common.errnoFor(e)));
                            }
                        },
                        else => return self.failErrno(req.id, .NOTTY),
                    }
                    self.reply(req.id, 0, std.mem.asBytes(&v)[0..@min(4, req.arg1)]);
                },
                .seek => {
                    if (h.kind != .text) return self.failErrno(req.id, .SPIPE);
                    const off: i64 = @bitCast(req.arg0);
                    const base: i64 = switch (req.arg1) {
                        0 => 0,
                        1 => @intCast(h.pos),
                        2 => @intCast(h.text.len),
                        else => return self.failErrno(req.id, .INVAL),
                    };
                    if (base + off < 0) return self.failErrno(req.id, .INVAL);
                    h.pos = @intCast(@min(base + off, @as(i64, @intCast(h.text.len))));
                    self.reply(req.id, @intCast(h.pos), "");
                },
                else => self.failErrno(req.id, .NOSYS),
            }
        }

        /// Which of our schemes a request came in on (hosted: one server
        /// per scheme; see main).
        fn scheme_of(self: *Self, req: sc.Request) u8 {
            _ = self;
            return @intCast(req.arg2);
        }

        /// Retry parked requests after the sockets changed.
        fn service(self: *Self) void {
            var it = self.handles.iterator();
            while (it.next()) |e| _ = self.advance(e.value);
            var i: usize = 0;
            while (i < self.pending.items.len) {
                const p = self.pending.items[i];
                const h = self.handles.get(p.handle) orelse {
                    self.dropPending(i);
                    continue;
                };
                const done = switch (p.op) {
                    .open => blk: {
                        if (h.phase == .open or h.phase == .failed) {
                            if (h.phase == .open) {
                                self.reply(p.id, @intCast(p.handle), "");
                            } else {
                                const err = h.err orelse error.Unexpected;
                                self.release(p.handle);
                                self.fail(p.id, err);
                            }
                            break :blk true;
                        }
                        break :blk false;
                    },
                    .read => self.tryRead(p.id, h, p.len, p.positioned, p.offset) == .done,
                    .write => self.tryWrite(p.id, h, p.data) == .done,
                    .fevent => blk: {
                        const m = self.readyMask(h) & (p.events | sc.POLLERR | sc.POLLHUP);
                        if (m == 0) break :blk false;
                        self.reply(p.id, m, "");
                        break :blk true;
                    },
                };
                if (done) self.dropPending(i) else i += 1;
            }
            // Accepted connections nobody opened in time.
            var k: usize = 0;
            while (k < self.parked.items.len) {
                if (self.parked.items[k].deadline <= self.now) {
                    self.be.close(self.parked.items[k].conn);
                    _ = self.parked.swapRemove(k);
                } else k += 1;
            }
        }

        /// Tell the host backend which sockets to watch.
        fn setWants(self: *Self) void {
            self.be.clearWants();
            for (self.pending.items) |p| {
                const h = self.handles.get(p.handle) orelse continue;
                if (!h.has_conn) continue;
                var ev: u32 = switch (p.op) {
                    .open => sc.POLLOUT,
                    .read => sc.POLLIN,
                    .write => sc.POLLOUT,
                    .fevent => p.events,
                };
                if (h.phase == .connecting) ev |= sc.POLLOUT;
                self.be.want(h.conn, ev);
            }
            var it = self.handles.iterator();
            while (it.next()) |e| if (e.value.phase == .connecting) self.be.want(e.value.conn, sc.POLLOUT);
        }
    };
}

/// One scheme server per scheme name; requests are tagged with the
/// scheme's index in `Request.arg2` before they reach `serve`.
fn run(comptime B: type, be: *B, servers: []zen.server.Server) noreturn {
    const N = Netd(B);
    const self = gpa.create(N) catch @panic("oom");
    self.* = .{ .be = be, .srv = undefined };
    var pfds: std.ArrayList(posix.pollfd) = .empty;
    while (true) {
        self.now = common.nowMs();
        self.setWants();
        pfds.clearRetainingCapacity();
        for (servers) |s| pfds.append(gpa, .{ .fd = s.fd, .events = posix.POLL.IN, .revents = 0 }) catch {};
        be.pollFds(&pfds) catch {};
        var timeout: i32 = 1000;
        if (be.timeout(self.now)) |t| timeout = @intCast(@min(t, 1000));
        if (self.pending.items.len > 0 or self.parked.items.len > 0) timeout = @min(timeout, 250);
        _ = posix.poll(pfds.items, timeout) catch 0;
        self.now = common.nowMs();

        for (servers, 0..) |*s, idx| {
            if (pfds.items[idx].revents == 0) continue;
            var budget: usize = 64;
            while (budget > 0) : (budget -= 1) {
                var in = s.receive() catch break;
                in.req.arg2 = idx;
                self.srv = s.*;
                self.serve(in);
                s.* = self.srv;
                if (!zen.sys.isHosted()) {
                    // One request per read on Zen: look again without waiting.
                    var one = [_]posix.pollfd{.{ .fd = s.fd, .events = posix.POLL.IN, .revents = 0 }};
                    if ((posix.poll(&one, 0) catch 0) == 0) break;
                }
            }
        }
        be.process(pfds.items[servers.len..], self.now);
        self.srv = servers[0];
        // Replies to parked requests go to the scheme they came from.
        serviceAll(N, self, servers);
    }
}

fn serviceAll(comptime N: type, self: *N, servers: []zen.server.Server) void {
    // All replies are routed by request id on Zen (one kernel), but hosted
    // each scheme has its own endpoint: answer through the right one.
    for (servers, 0..) |*s, idx| {
        self.srv = s.*;
        // Temporarily hide the requests of other schemes.
        var i: usize = 0;
        var saved: std.ArrayList(Pending) = .empty;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            const h = self.handles.get(p.handle);
            if (h != null and h.?.scheme != idx) {
                saved.append(gpa, self.pending.orderedRemove(i)) catch {
                    i += 1;
                };
                continue;
            }
            i += 1;
        }
        self.service();
        self.pending.appendSlice(gpa, saved.items) catch {};
        saved.deinit(gpa);
        s.* = self.srv;
    }
}

pub fn main() !void {
    zen.sys.setName("netd");
    const now = common.nowMs();
    var servers: [schemes.len]zen.server.Server = undefined;
    for (schemes, 0..) |name, i| {
        servers[i] = zen.server.Server.register(gpa, name) catch |err| {
            zen.sys.logf("netd: cannot register {s}: {s}", .{ name, @errorName(err) });
            return err;
        };
    }
    if (zen.sys.isHosted()) {
        const be = try HostBackend.init(gpa, now);
        zen.sys.logf("netd: serving {s} with the host's network", .{"tcp: udp: icmp: dns: net:"});
        run(HostBackend, be, &servers);
    }
    const be = try StackBackend.init(gpa, now);
    run(StackBackend, be, &servers);
}
