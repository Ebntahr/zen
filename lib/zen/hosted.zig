//! Hosted Zen: Zen user space running on a Linux host.
//!
//! On Zen the kernel forwards every open/read/write/mmap on a URL to the
//! server that registered the scheme (see `abi.scheme`). Hosted, this module
//! does the same job over Unix sockets, so the real window server, launchd
//! and apps run unchanged on Linux:
//!
//!   * a server's `Server.register("window")` listens on `$ZEN_HOSTED/window`;
//!   * every open handle is one SOCK_SEQPACKET connection;
//!   * the client side (`zen.io`) sends one request message per call
//!     (open, read, write, seek, fstat, fmap) and waits for the reply,
//!     exactly like a blocking system call;
//!   * `fmap` replies carry a memfd (SCM_RIGHTS), so window buffers and the
//!     framebuffer are shared memory between processes, as on Zen.
//!
//! Hosted mode is on when the environment variable ZEN_HOSTED names the
//! socket directory. Processes should be single-threaded users of this
//! module (all Zen servers and apps are).

const std = @import("std");
const abi = @import("abi");
const shm = @import("shm.zig");

const posix = std.posix;
const linux = std.os.linux;
const sc = abi.scheme;

pub const env_var = "ZEN_HOSTED";
/// Largest payload of a single request or reply.
pub const MAX_IO: usize = 64 * 1024;

/// Client → server message header; `len` payload bytes follow (write, open)
/// or `len` is the requested size (read).
pub const Msg = extern struct {
    op: u32,
    id: u32,
    len: u32,
    flags: u32,
    arg0: u64 = 0,
    arg1: u64 = 0,
};

/// Server → client reply header; `len` data bytes follow. With `has_fd`
/// a file descriptor is attached (fmap: map it at offset `arg0`).
pub const Reply = extern struct {
    id: u32,
    has_fd: u32 = 0,
    result: i64,
    len: u32,
    reserved: u32 = 0,
    arg0: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Msg) == 32);
    std.debug.assert(@sizeOf(Reply) == 32);
}

var dir_cache: ?[]const u8 = null;
var dir_checked = false;

/// The socket directory when running hosted, else null.
pub fn dir() ?[]const u8 {
    if (!dir_checked) {
        dir_checked = true;
        if (std.posix.getenv(env_var)) |d| {
            if (d.len > 0) dir_cache = d;
        }
    }
    return dir_cache;
}

pub fn enabled() bool {
    return dir() != null;
}

/// Override the socket directory (tests, launchers).
pub fn setDir(d: ?[]const u8) void {
    dir_cache = d;
    dir_checked = true;
}

pub const Error = error{
    NotFound,
    AccessDenied,
    WouldBlock,
    BadFd,
    InvalidArgument,
    NoMemory,
    Unsupported,
    BrokenPipe,
    Io,
    // Network failures reported by netd.
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    HostUnreachable,
    AddressInUse,
};

fn errnoError(e: linux.E) Error {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .ADDRINUSE => error.AddressInUse,
        .NOENT, .NODEV, .NXIO => error.NotFound,
        .ACCES, .PERM => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFd,
        .INVAL => error.InvalidArgument,
        .NOMEM, .NOSPC => error.NoMemory,
        .NOSYS, .OPNOTSUPP => error.Unsupported,
        .PIPE => error.BrokenPipe,
        else => error.Io,
    };
}

fn resultError(result: i64) Error {
    const e: u16 = @intCast(@min(-result, 4095));
    return errnoError(@enumFromInt(e));
}

// ---------------------------------------------------------------------------
// Socket helpers
// ---------------------------------------------------------------------------

const ucred = extern struct { pid: i32, uid: u32, gid: u32 };

const CMSG_HDR = @sizeOf(usize) + 2 * @sizeOf(i32); // struct cmsghdr
const CMSG_SPACE_FD = CMSG_HDR + 8; // one int, padded to 8

fn socketPath(scheme: []const u8, out: *linux.sockaddr.un) !void {
    const d = dir() orelse return error.NotFound;
    out.* = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&out.path, 0);
    if (d.len + 1 + scheme.len >= out.path.len) return error.InvalidArgument;
    @memcpy(out.path[0..d.len], d);
    out.path[d.len] = '/';
    @memcpy(out.path[d.len + 1 ..][0..scheme.len], scheme);
}

/// Send `hdr ++ data`, optionally passing `pass_fd`.
fn sendMsg(fd: posix.fd_t, hdr: []const u8, data: []const u8, pass_fd: ?posix.fd_t, nonblock: bool) !void {
    var iov = [_]posix.iovec_const{
        .{ .base = hdr.ptr, .len = hdr.len },
        .{ .base = data.ptr, .len = data.len },
    };
    var cbuf: [CMSG_SPACE_FD]u8 align(8) = undefined;
    var msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = if (data.len > 0) 2 else 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (pass_fd) |pfd| {
        @memset(&cbuf, 0);
        std.mem.writeInt(usize, cbuf[0..@sizeOf(usize)], CMSG_HDR + 4, .little);
        std.mem.writeInt(i32, cbuf[@sizeOf(usize)..][0..4], linux.SOL.SOCKET, .little);
        std.mem.writeInt(i32, cbuf[@sizeOf(usize) + 4 ..][0..4], 1, .little); // SCM_RIGHTS
        std.mem.writeInt(i32, cbuf[CMSG_HDR..][0..4], pfd, .little);
        msg.control = &cbuf;
        msg.controllen = cbuf.len;
    }
    const flags: u32 = linux.MSG.NOSIGNAL | (if (nonblock) @as(u32, linux.MSG.DONTWAIT) else 0);
    while (true) {
        const rc = linux.sendmsg(fd, &msg, flags);
        switch (linux.E.init(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE, .CONNRESET, .NOTCONN => return error.BrokenPipe,
            else => |e| return errnoError(e),
        }
    }
}

const Received = struct { len: usize, fd: ?posix.fd_t };

/// Receive one message into `buf`. Returns length 0 at end of stream.
fn recvMsg(fd: posix.fd_t, buf: []u8, nonblock: bool) !Received {
    var iov = [_]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cbuf: [CMSG_SPACE_FD * 2]u8 align(8) = undefined;
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cbuf,
        .controllen = cbuf.len,
        .flags = 0,
    };
    const flags: u32 = linux.MSG.CMSG_CLOEXEC | (if (nonblock) @as(u32, linux.MSG.DONTWAIT) else 0);
    while (true) {
        const rc = linux.recvmsg(fd, &msg, flags);
        switch (linux.E.init(rc)) {
            .SUCCESS => {
                var got: ?posix.fd_t = null;
                if (msg.controllen >= CMSG_HDR + 4) {
                    const level = std.mem.readInt(i32, cbuf[@sizeOf(usize)..][0..4], .little);
                    const kind = std.mem.readInt(i32, cbuf[@sizeOf(usize) + 4 ..][0..4], .little);
                    if (level == linux.SOL.SOCKET and kind == 1) got = std.mem.readInt(i32, cbuf[CMSG_HDR..][0..4], .little);
                }
                return .{ .len = rc, .fd = got };
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET, .NOTCONN => return .{ .len = 0, .fd = null },
            else => |e| return errnoError(e),
        }
    }
}

// ---------------------------------------------------------------------------
// Client side
// ---------------------------------------------------------------------------

const Conn = struct {
    nonblock: bool,
    next_id: u32 = 1,
    /// Id of a read request sent ahead of time (poll readiness), or 0.
    armed: u32 = 0,
    /// A reply to the armed read that has arrived but was not consumed.
    stash_ready: bool = false,
    stash_result: i64 = 0,
    stash_len: usize = 0,
    stash_pos: usize = 0,
    /// Receive buffer (reply header + data).
    buf: []u8,
    /// Holds the stashed reply (buffers are swapped, not copied).
    spare: []u8,

    fn nextId(c: *Conn) u32 {
        const id = c.next_id;
        c.next_id +%= 1;
        if (c.next_id == 0) c.next_id = 1;
        return id;
    }
};

const alloc = std.heap.page_allocator;
/// Open handles by fd. The table is shared by all threads (a handle itself
/// is used by one thread at a time).
var conns: std.AutoHashMapUnmanaged(posix.fd_t, *Conn) = .empty;
var conns_mutex: std.Thread.Mutex = .{};

fn lookup(fd: posix.fd_t) ?*Conn {
    conns_mutex.lock();
    defer conns_mutex.unlock();
    return conns.get(fd);
}

pub fn isHandle(fd: posix.fd_t) bool {
    return lookup(fd) != null;
}

/// Split "scheme:rest" (the scheme must be a plain name).
pub fn splitUrl(url: []const u8) ?struct { scheme: []const u8, rest: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon == 0) return null;
    for (url[0..colon]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return null;
    }
    return .{ .scheme = url[0..colon], .rest = url[colon + 1 ..] };
}

/// Open a URL served by a hosted scheme server.
pub fn open(url: []const u8, flags: u32) Error!posix.fd_t {
    const parts = splitUrl(url) orelse return error.InvalidArgument;
    if (parts.rest.len > MAX_IO) return error.InvalidArgument;
    var addr: linux.sockaddr.un = undefined;
    socketPath(parts.scheme, &addr) catch return error.NotFound;
    const fd = posix.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0) catch return error.Io;
    errdefer posix.close(fd);
    posix.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)) catch |err| return switch (err) {
        error.PermissionDenied, error.AccessDenied => error.AccessDenied,
        else => error.NotFound,
    };
    const c = alloc.create(Conn) catch return error.NoMemory;
    errdefer alloc.destroy(c);
    const bufs = alloc.alloc(u8, 2 * (@sizeOf(Reply) + MAX_IO)) catch return error.NoMemory;
    errdefer alloc.free(bufs);
    c.* = .{
        .nonblock = flags & sc.O_NONBLOCK != 0,
        .buf = bufs[0 .. @sizeOf(Reply) + MAX_IO],
        .spare = bufs[@sizeOf(Reply) + MAX_IO ..],
    };

    const id = c.nextId();
    const msg = Msg{ .op = @intFromEnum(sc.Op.open), .id = id, .len = @intCast(parts.rest.len), .flags = flags & ~sc.O_NONBLOCK };
    try sendMsg(fd, std.mem.asBytes(&msg), parts.rest, null, false);
    const r = try waitReply(fd, c, id, null);
    if (r.result < 0) return resultError(r.result);
    conns_mutex.lock();
    defer conns_mutex.unlock();
    conns.put(alloc, fd, c) catch return error.NoMemory;
    return fd;
}

const GotReply = struct { result: i64, len: usize, arg0: u64, fd: ?posix.fd_t };

/// Wait for the reply `id`. A reply to the armed read is stashed.
fn waitReply(fd: posix.fd_t, c: *Conn, id: u32, want_fd: ?*?posix.fd_t) Error!GotReply {
    while (true) {
        const got = try recvMsg(fd, c.buf, false);
        if (got.len == 0) return error.BrokenPipe;
        if (got.len < @sizeOf(Reply)) {
            if (got.fd) |f| posix.close(f);
            continue;
        }
        var r: Reply = undefined;
        @memcpy(std.mem.asBytes(&r), c.buf[0..@sizeOf(Reply)]);
        const dlen = @min(@as(usize, r.len), got.len - @sizeOf(Reply));
        if (r.id == id) {
            if (want_fd) |wf| wf.* = got.fd else if (got.fd) |f| posix.close(f);
            return .{ .result = r.result, .len = dlen, .arg0 = r.arg0, .fd = null };
        }
        if (got.fd) |f| posix.close(f);
        if (c.armed != 0 and r.id == c.armed) {
            // Keep the data: move it out of the way of the next receive.
            stash(c, r.result, dlen);
        }
    }
}

/// Keep the reply just received in `buf` for a later read().
fn stash(c: *Conn, result: i64, dlen: usize) void {
    const t = c.buf;
    c.buf = c.spare;
    c.spare = t;
    c.armed = 0;
    c.stash_ready = true;
    c.stash_result = result;
    c.stash_len = dlen;
    c.stash_pos = 0;
}

fn conn(fd: posix.fd_t) Error!*Conn {
    return lookup(fd) orelse error.BadFd;
}

fn consumeStash(c: *Conn, buf: []u8) Error!usize {
    if (c.stash_result < 0) {
        c.stash_ready = false;
        return resultError(c.stash_result);
    }
    const avail = c.stash_len - c.stash_pos;
    const n = @min(avail, buf.len);
    @memcpy(buf[0..n], c.spare[@sizeOf(Reply) + c.stash_pos ..][0..n]);
    c.stash_pos += n;
    if (c.stash_pos >= c.stash_len) c.stash_ready = false;
    return n;
}

fn sendRead(fd: posix.fd_t, c: *Conn, len: usize) Error!u32 {
    const id = c.nextId();
    const msg = Msg{ .op = @intFromEnum(sc.Op.read), .id = id, .len = @intCast(@min(len, MAX_IO)), .flags = 0 };
    try sendMsg(fd, std.mem.asBytes(&msg), "", null, false);
    return id;
}

/// Send a read ahead of time so poll() reports readiness when data arrives.
pub fn armRead(fd: posix.fd_t) void {
    const c = lookup(fd) orelse return;
    if (c.armed != 0 or c.stash_ready) return;
    c.armed = sendRead(fd, c, MAX_IO) catch return;
}

/// A reply is already buffered (poll must report the fd readable).
pub fn hasBuffered(fd: posix.fd_t) bool {
    const c = lookup(fd) orelse return false;
    return c.stash_ready;
}

pub fn read(fd: posix.fd_t, buf: []u8) Error!usize {
    const c = try conn(fd);
    if (c.stash_ready) return consumeStash(c, buf);
    if (c.armed == 0) {
        if (c.nonblock) {
            c.armed = try sendRead(fd, c, MAX_IO);
        } else {
            const id = try sendRead(fd, c, buf.len);
            const r = try waitReply(fd, c, id, null);
            if (r.result < 0) return resultError(r.result);
            const n = @min(r.len, buf.len);
            @memcpy(buf[0..n], c.buf[@sizeOf(Reply)..][0..n]);
            return n;
        }
    }
    // A read is armed: take its reply.
    while (true) {
        const got = try recvMsg(fd, c.buf, c.nonblock);
        if (got.len == 0) return 0;
        if (got.fd) |f| posix.close(f);
        if (got.len < @sizeOf(Reply)) continue;
        var r: Reply = undefined;
        @memcpy(std.mem.asBytes(&r), c.buf[0..@sizeOf(Reply)]);
        if (r.id != c.armed) continue;
        stash(c, r.result, @min(@as(usize, r.len), got.len - @sizeOf(Reply)));
        return consumeStash(c, buf);
    }
}

/// Generic request without a data payload in the reply beyond `out`.
fn call(fd: posix.fd_t, op: sc.Op, payload: []const u8, arg0: u64, arg1: u64, out: []u8, want_fd: ?*?posix.fd_t) Error!GotReply {
    const c = try conn(fd);
    const id = c.nextId();
    const msg = Msg{ .op = @intFromEnum(op), .id = id, .len = @intCast(if (op == .read) out.len else payload.len), .flags = 0, .arg0 = arg0, .arg1 = arg1 };
    try sendMsg(fd, std.mem.asBytes(&msg), payload, null, false);
    const r = try waitReply(fd, c, id, want_fd);
    const n = @min(r.len, out.len);
    @memcpy(out[0..n], c.buf[@sizeOf(Reply)..][0..n]);
    return .{ .result = r.result, .len = n, .arg0 = r.arg0, .fd = null };
}

pub fn write(fd: posix.fd_t, data: []const u8) Error!usize {
    const chunk = data[0..@min(data.len, MAX_IO)];
    const r = try call(fd, .write, chunk, 0, 0, &.{}, null);
    if (r.result < 0) return resultError(r.result);
    return @intCast(r.result);
}

pub fn seek(fd: posix.fd_t, offset: i64, whence: u32) Error!u64 {
    const r = try call(fd, .seek, "", @bitCast(offset), whence, &.{}, null);
    if (r.result < 0) return resultError(r.result);
    // A rewind invalidates a read sent ahead of time.
    if (lookup(fd)) |c| c.stash_ready = false;
    return @intCast(r.result);
}

pub fn fstat(fd: posix.fd_t) Error!sc.Stat {
    var st: sc.Stat = .{};
    const r = try call(fd, .fstat, "", 0, 0, std.mem.asBytes(&st), null);
    if (r.result < 0) return resultError(r.result);
    return st;
}

/// Map `len` bytes of the resource at `offset` (shared memory).
pub fn mmap(fd: posix.fd_t, len: usize, prot: u32, offset: u64) Error![]align(std.heap.page_size_min) u8 {
    var mfd: ?posix.fd_t = null;
    const r = try call(fd, .fmap, "", offset, len, &.{}, &mfd);
    if (r.result < 0) {
        if (mfd) |f| posix.close(f);
        return resultError(r.result);
    }
    const f = mfd orelse return error.Unsupported;
    defer posix.close(f);
    return posix.mmap(null, len, prot, .{ .TYPE = .SHARED }, f, r.arg0) catch error.NoMemory;
}

pub fn close(fd: posix.fd_t) void {
    conns_mutex.lock();
    const removed = conns.fetchRemove(fd);
    conns_mutex.unlock();
    if (removed) |kv| {
        const c = kv.value;
        // The two halves were allocated together.
        const base = @min(@intFromPtr(c.buf.ptr), @intFromPtr(c.spare.ptr));
        alloc.free(@as([*]u8, @ptrFromInt(base))[0 .. 2 * (@sizeOf(Reply) + MAX_IO)]);
        alloc.destroy(c);
    }
    posix.close(fd);
}

// ---------------------------------------------------------------------------
// Server side
// ---------------------------------------------------------------------------

pub const Incoming = struct {
    req: sc.Request,
    payload: []const u8,
};

/// A hosted scheme endpoint. `fd` (an epoll fd) becomes readable when
/// requests may be pending; `receive` never blocks.
pub const Endpoint = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    listen_fd: posix.fd_t,
    path: [108]u8 = undefined,
    path_len: usize = 0,
    clients: std.ArrayList(?Client) = .empty,
    queue: std.ArrayList(Queued) = .empty,
    inflight: std.AutoHashMapUnmanaged(u64, Inflight) = .empty,
    next_req: u64 = 1,
    rbuf: []u8,
    /// Payload of the request most recently returned by `receive`.
    current: []u8 = &.{},

    const Client = struct {
        fd: posix.fd_t,
        gen: u32,
        pid: u32,
        uid: u32,
        gid: u32,
        handle: u64 = 0,
        opened: bool = false,
        /// Reads waiting for a reply from the server (request ids).
        reads: std.ArrayList(u64) = .empty,
        outbox: std.ArrayList(Out) = .empty,
    };

    const Out = struct { bytes: []u8, pass_fd: ?posix.fd_t };

    const Queued = struct { req: sc.Request, payload: []u8 };

    const Inflight = struct { slot: u32, gen: u32, client_id: u32, op: sc.Op };

    var gen_counter: u32 = 1;

    pub fn listen(allocator: std.mem.Allocator, scheme: []const u8) !*Endpoint {
        var addr: linux.sockaddr.un = undefined;
        try socketPath(scheme, &addr);
        const path = std.mem.sliceTo(&addr.path, 0);
        posix.unlink(path) catch {};
        const lfd = try posix.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        errdefer posix.close(lfd);
        try posix.bind(lfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        // Every local user may connect; servers check the caller's ids.
        posix.fchmodat(posix.AT.FDCWD, path, 0o777, 0) catch {};
        try posix.listen(lfd, 64);
        const efd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        errdefer posix.close(efd);
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = std.math.maxInt(u64) } };
        try posix.epoll_ctl(efd, linux.EPOLL.CTL_ADD, lfd, &ev);
        const self = try allocator.create(Endpoint);
        self.* = .{ .allocator = allocator, .fd = efd, .listen_fd = lfd, .rbuf = try allocator.alloc(u8, @sizeOf(Msg) + MAX_IO) };
        @memcpy(self.path[0..path.len], path);
        self.path_len = path.len;
        return self;
    }

    pub fn deinit(self: *Endpoint) void {
        for (self.clients.items) |*slot| if (slot.*) |*cl| self.dropClient(cl);
        self.clients.deinit(self.allocator);
        for (self.queue.items) |q| self.allocator.free(q.payload);
        self.queue.deinit(self.allocator);
        self.inflight.deinit(self.allocator);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.current);
        posix.close(self.listen_fd);
        posix.close(self.fd);
        posix.unlink(self.path[0..self.path_len]) catch {};
        self.allocator.destroy(self);
    }

    fn dropClient(self: *Endpoint, cl: *Client) void {
        posix.close(cl.fd);
        for (cl.outbox.items) |o| {
            self.allocator.free(o.bytes);
            if (o.pass_fd) |f| posix.close(f);
        }
        cl.outbox.deinit(self.allocator);
        cl.reads.deinit(self.allocator);
    }

    fn enqueue(self: *Endpoint, req: sc.Request, payload: []const u8) !void {
        try self.queue.append(self.allocator, .{ .req = req, .payload = try self.allocator.dupe(u8, payload) });
    }

    fn baseRequest(cl: *const Client, op: sc.Op) sc.Request {
        return .{
            .id = 0,
            .op = op,
            .flags = 0,
            .pid = cl.pid,
            .uid = cl.uid,
            .gid = cl.gid,
            .caller_flags = 0,
            .handle = cl.handle,
            .arg0 = 0,
            .arg1 = 0,
            .arg2 = 0,
            .len = 0,
        };
    }

    fn accept(self: *Endpoint) void {
        while (true) {
            const cfd = posix.accept(self.listen_fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK) catch return;
            var cred: ucred = .{ .pid = 0, .uid = 65534, .gid = 65534 };
            var clen: posix.socklen_t = @sizeOf(ucred);
            _ = linux.getsockopt(cfd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &clen);
            const slot = self.freeSlot() catch {
                posix.close(cfd);
                return;
            };
            gen_counter +%= 1;
            self.clients.items[slot] = .{ .fd = cfd, .gen = gen_counter, .pid = @intCast(@max(cred.pid, 0)), .uid = cred.uid, .gid = cred.gid };
            var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = slot } };
            posix.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, cfd, &ev) catch {
                self.dropClient(&self.clients.items[slot].?);
                self.clients.items[slot] = null;
            };
        }
    }

    fn freeSlot(self: *Endpoint) !usize {
        for (self.clients.items, 0..) |c, i| if (c == null) return i;
        try self.clients.append(self.allocator, null);
        return self.clients.items.len - 1;
    }

    /// The client hung up: cancel its outstanding reads and close its handle.
    fn hangup(self: *Endpoint, slot: usize) void {
        if (self.clients.items[slot] == null) return;
        const cl = &self.clients.items[slot].?;
        for (cl.reads.items) |rid| {
            var req = baseRequest(cl, .cancel);
            req.id = self.newId();
            req.arg0 = rid;
            self.enqueue(req, "") catch {};
        }
        if (cl.opened) {
            var req = baseRequest(cl, .close);
            req.id = self.newId();
            self.enqueue(req, "") catch {};
        }
        posix.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, cl.fd, null) catch {};
        self.dropClient(cl);
        self.clients.items[slot] = null;
    }

    fn newId(self: *Endpoint) u64 {
        const id = self.next_req;
        self.next_req += 1;
        return id;
    }

    fn replyDirect(self: *Endpoint, cl: *Client, client_id: u32, result: i64) void {
        const r = Reply{ .id = client_id, .result = result, .len = 0 };
        self.send(cl, std.mem.asBytes(&r), "", null);
    }

    fn clientMessage(self: *Endpoint, slot: usize) void {
        var budget: usize = 32;
        while (budget > 0) : (budget -= 1) {
            if (self.clients.items[slot] == null) return;
            const cl = &self.clients.items[slot].?;
            const got = recvMsg(cl.fd, self.rbuf, true) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.hangup(slot),
            };
            if (got.fd) |f| posix.close(f);
            if (got.len == 0) return self.hangup(slot);
            if (got.len < @sizeOf(Msg)) continue;
            var m: Msg = undefined;
            @memcpy(std.mem.asBytes(&m), self.rbuf[0..@sizeOf(Msg)]);
            const op: sc.Op = @enumFromInt(m.op);
            const payload = self.rbuf[@sizeOf(Msg)..got.len];
            if (op != .open and !cl.opened) {
                self.replyDirect(cl, m.id, -@as(i64, @intFromEnum(linux.E.BADF)));
                continue;
            }
            var req = baseRequest(cl, op);
            req.id = self.newId();
            req.flags = m.flags;
            req.arg0 = m.arg0;
            req.arg1 = m.arg1;
            switch (op) {
                .read, .getdents, .readlink => req.len = @min(m.len, MAX_IO),
                .open, .write, .ioctl => req.len = payload.len,
                .fmap => req.flags = linux.PROT.READ | linux.PROT.WRITE,
                .seek, .fstat, .fsync, .ftruncate, .fpath, .fstatfs => {},
                else => {
                    self.replyDirect(cl, m.id, -@as(i64, @intFromEnum(linux.E.NOSYS)));
                    continue;
                },
            }
            if (op == .open and cl.opened) {
                self.replyDirect(cl, m.id, -@as(i64, @intFromEnum(linux.E.INVAL)));
                continue;
            }
            self.inflight.put(self.allocator, req.id, .{ .slot = @intCast(slot), .gen = cl.gen, .client_id = m.id, .op = op }) catch continue;
            if (op == .read) cl.reads.append(self.allocator, req.id) catch {};
            const body: []const u8 = switch (op) {
                .open, .write, .ioctl => payload,
                else => "",
            };
            self.enqueue(req, body) catch {
                _ = self.inflight.remove(req.id);
            };
        }
    }

    fn flushOutbox(self: *Endpoint, cl: *Client) void {
        while (cl.outbox.items.len > 0) {
            const o = cl.outbox.items[0];
            sendMsg(cl.fd, o.bytes, "", o.pass_fd, true) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {},
            };
            self.allocator.free(o.bytes);
            if (o.pass_fd) |f| posix.close(f);
            _ = cl.outbox.orderedRemove(0);
        }
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = self.slotOf(cl) } };
        posix.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, cl.fd, &ev) catch {};
    }

    fn slotOf(self: *Endpoint, cl: *Client) u64 {
        for (self.clients.items, 0..) |*s, i| if (s.*) |*c| if (c == cl) return i;
        return 0;
    }

    /// Send a reply now, or queue it when the client's socket is full.
    fn send(self: *Endpoint, cl: *Client, hdr: []const u8, data: []const u8, pass_fd: ?posix.fd_t) void {
        if (cl.outbox.items.len == 0) {
            if (sendMsg(cl.fd, hdr, data, pass_fd, true)) {
                if (pass_fd) |f| posix.close(f);
                return;
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => {
                    if (pass_fd) |f| posix.close(f);
                    return;
                },
            }
        }
        const bytes = self.allocator.alloc(u8, hdr.len + data.len) catch return;
        @memcpy(bytes[0..hdr.len], hdr);
        @memcpy(bytes[hdr.len..], data);
        cl.outbox.append(self.allocator, .{ .bytes = bytes, .pass_fd = pass_fd }) catch return;
        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.OUT, .data = .{ .u64 = self.slotOf(cl) } };
        posix.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, cl.fd, &ev) catch {};
    }

    fn poll(self: *Endpoint) void {
        var events: [32]linux.epoll_event = undefined;
        const n = posix.epoll_wait(self.fd, &events, 0);
        for (events[0..n]) |ev| {
            if (ev.data.u64 == std.math.maxInt(u64)) {
                self.accept();
                continue;
            }
            const slot: usize = @intCast(ev.data.u64);
            if (slot >= self.clients.items.len) continue;
            if (ev.events & linux.EPOLL.OUT != 0) {
                if (self.clients.items[slot]) |*cl| self.flushOutbox(cl);
            }
            if (ev.events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR) != 0) {
                self.clientMessage(slot);
            }
        }
    }

    /// Next request, or error.WouldBlock when none is pending.
    pub fn receive(self: *Endpoint) !Incoming {
        if (self.queue.items.len == 0) self.poll();
        if (self.queue.items.len == 0) return error.WouldBlock;
        const q = self.queue.orderedRemove(0);
        self.allocator.free(self.current);
        self.current = q.payload;
        return .{ .req = q.req, .payload = q.payload };
    }

    /// Deliver the server's response to request `id`.
    pub fn reply(self: *Endpoint, id: u64, result: i64, data: []const u8) void {
        const inf = self.inflight.fetchRemove(id) orelse return;
        const info = inf.value;
        const cl: *Client = blk: {
            if (info.slot < self.clients.items.len) {
                if (self.clients.items[info.slot]) |*c| {
                    if (c.gen == info.gen) break :blk c;
                }
            }
            // The client is gone. A handle opened for it must be closed.
            if (info.op == .open and result > 0) {
                const req = sc.Request{ .id = self.newId(), .op = .close, .flags = 0, .pid = 0, .uid = 0, .gid = 0, .caller_flags = 0, .handle = @intCast(result), .arg0 = 0, .arg1 = 0, .arg2 = 0, .len = 0 };
                self.enqueue(req, "") catch {};
            }
            return;
        };
        if (info.op == .read) {
            for (cl.reads.items, 0..) |rid, i| if (rid == id) {
                _ = cl.reads.swapRemove(i);
                break;
            };
        }
        if (info.op == .open and result >= 0) {
            cl.handle = @intCast(result);
            cl.opened = true;
        }
        var r = Reply{ .id = info.client_id, .result = result, .len = @intCast(@min(data.len, MAX_IO)) };
        if (info.op == .fmap and result >= 0) {
            const region = shm.lookup(@intCast(result)) orelse {
                r.result = -@as(i64, @intFromEnum(linux.E.NODEV));
                return self.send(cl, std.mem.asBytes(&r), "", null);
            };
            const dup = posix.dup(region.fd) catch {
                r.result = -@as(i64, @intFromEnum(linux.E.MFILE));
                return self.send(cl, std.mem.asBytes(&r), "", null);
            };
            r.result = 0;
            r.has_fd = 1;
            r.arg0 = region.offset;
            return self.send(cl, std.mem.asBytes(&r), "", dup);
        }
        self.send(cl, std.mem.asBytes(&r), data[0..r.len], null);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hosted request/response roundtrip" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = try tmp.dir.realpath(".", &path_buf);
    setDir(d);
    defer setDir(null);

    var ep = try Endpoint.listen(a, "echo");
    defer ep.deinit();

    // The client blocks on replies, so run the server in a thread.
    const Server = struct {
        fn run(e: *Endpoint) void {
            var handles: u64 = 0;
            var last_write: [64]u8 = undefined;
            var last_len: usize = 0;
            var done = false;
            while (!done) {
                var fds = [_]posix.pollfd{.{ .fd = e.fd, .events = posix.POLL.IN, .revents = 0 }};
                _ = posix.poll(&fds, 100) catch {};
                while (e.receive()) |in| {
                    switch (in.req.op) {
                        .open => {
                            if (std.mem.eql(u8, in.payload, "missing")) {
                                e.reply(in.req.id, -@as(i64, @intFromEnum(linux.E.NOENT)), "");
                            } else {
                                handles += 1;
                                e.reply(in.req.id, @intCast(handles), "");
                            }
                        },
                        .write => {
                            last_len = @min(in.payload.len, last_write.len);
                            @memcpy(last_write[0..last_len], in.payload[0..last_len]);
                            e.reply(in.req.id, @intCast(in.payload.len), "");
                        },
                        .read => e.reply(in.req.id, @intCast(last_len), last_write[0..last_len]),
                        .close => done = true,
                        else => e.reply(in.req.id, -@as(i64, @intFromEnum(linux.E.NOSYS)), ""),
                    }
                } else |_| {}
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Server.run, .{ep});

    try std.testing.expectError(error.NotFound, open("echo:missing", sc.O_RDWR));
    try std.testing.expectError(error.NotFound, open("nothere:x", sc.O_RDWR));
    const fd = try open("echo:thing", sc.O_RDWR);
    try std.testing.expect(isHandle(fd));
    try std.testing.expectEqual(@as(usize, 5), try write(fd, "hello"));
    var buf: [16]u8 = undefined;
    const n = try read(fd, &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    // A read sent ahead of time (poll) is answered and then consumed.
    armRead(fd);
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try posix.poll(&pfd, 2000) == 1);
    const m = try read(fd, &buf);
    try std.testing.expectEqualStrings("hello", buf[0..m]);
    try std.testing.expectError(error.Unsupported, fstat(fd));
    close(fd);
    t.join();
}

test "url splitting" {
    const u = splitUrl("window:new?w=1").?;
    try std.testing.expectEqualStrings("window", u.scheme);
    try std.testing.expectEqualStrings("new?w=1", u.rest);
    try std.testing.expect(splitUrl("/etc/passwd") == null);
    try std.testing.expect(splitUrl("a b:c") == null);
}
