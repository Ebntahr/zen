//! Framework for user-space scheme servers ("everything is a URL").
//!
//!     var srv = try Server.register(gpa, "pty");
//!     while (true) {
//!         const in = try srv.receive();
//!         switch (in.req.op) {
//!             .open => try srv.reply(in.req.id, handle, ""),
//!             else => try srv.replyError(in.req.id, .NOSYS),
//!         }
//!     }
//!
//! Requests may be answered later (keep the id) — that is how blocking
//! reads and poll readiness (`fevent`) are implemented.

const std = @import("std");
const abi = @import("abi");
const sys = @import("sys.zig");
const hosted = @import("hosted.zig");
const posix = std.posix;
const linux = std.os.linux;

pub const Request = abi.scheme.Request;
pub const Response = abi.scheme.Response;
pub const Op = abi.scheme.Op;
pub const E = linux.E;

pub const Incoming = struct {
    req: Request,
    /// Payload bytes; only valid until the next `receive`.
    payload: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    buf: []align(8) u8,
    out: std.ArrayList(u8) = .empty,
    /// Hosted on Linux: the socket endpoint standing in for the kernel.
    endpoint: ?*hosted.Endpoint = null,

    pub fn register(allocator: std.mem.Allocator, name: []const u8) !Server {
        if (hosted.enabled()) {
            const ep = try hosted.Endpoint.listen(allocator, name);
            return .{ .allocator = allocator, .fd = ep.fd, .buf = &.{}, .endpoint = ep };
        }
        const fd = try sys.schemeRegister(name);
        return fromFd(allocator, fd);
    }

    pub fn fromFd(allocator: std.mem.Allocator, fd: posix.fd_t) !Server {
        const buf = try allocator.alignedAlloc(u8, .@"8", abi.scheme.RECV_BUFFER);
        return .{ .allocator = allocator, .fd = fd, .buf = buf };
    }

    pub fn deinit(self: *Server) void {
        if (self.endpoint) |ep| {
            ep.deinit();
            self.out.deinit(self.allocator);
            return;
        }
        self.allocator.free(self.buf);
        self.out.deinit(self.allocator);
        posix.close(self.fd);
    }

    /// Block until the next request arrives. (Hosted: returns
    /// error.WouldBlock when nothing is pending; poll `fd` first.)
    pub fn receive(self: *Server) !Incoming {
        if (self.endpoint) |ep| {
            const in = try ep.receive();
            return .{ .req = in.req, .payload = in.payload };
        }
        while (true) {
            const n = posix.read(self.fd, self.buf) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            };
            if (n == 0) return error.EndOfStream;
            if (n < @sizeOf(Request)) continue;
            var req: Request = undefined;
            @memcpy(std.mem.asBytes(&req), self.buf[0..@sizeOf(Request)]);
            const avail = n - @sizeOf(Request);
            const plen: usize = if (opHasPayload(req.op)) @min(avail, @as(usize, @intCast(req.len))) else 0;
            return .{ .req = req, .payload = self.buf[@sizeOf(Request) .. @sizeOf(Request) + plen] };
        }
    }

    /// Send one response with optional data.
    pub fn reply(self: *Server, id: u64, result: i64, data: []const u8) !void {
        if (self.endpoint) |ep| return ep.reply(id, result, data);
        self.out.clearRetainingCapacity();
        const hdr = Response{ .id = id, .result = result, .len = data.len };
        try self.out.appendSlice(self.allocator, std.mem.asBytes(&hdr));
        try self.out.appendSlice(self.allocator, data);
        var off: usize = 0;
        while (off < self.out.items.len) {
            off += try posix.write(self.fd, self.out.items[off..]);
        }
    }

    pub fn replyValue(self: *Server, id: u64, value: u64) !void {
        try self.reply(id, @intCast(value), "");
    }

    pub fn replyOk(self: *Server, id: u64) !void {
        try self.reply(id, 0, "");
    }

    pub fn replyError(self: *Server, id: u64, err: E) !void {
        try self.reply(id, -@as(i64, @intFromEnum(err)), "");
    }

    pub fn replyStruct(self: *Server, id: u64, value: anytype) !void {
        try self.reply(id, 0, std.mem.asBytes(value));
    }
};

/// Whether the request header is followed by payload bytes.
pub fn opHasPayload(op: Op) bool {
    return switch (op) {
        .read, .getdents, .readlink, .fstat, .fpath, .fstatfs, .close, .seek, .fsync, .ftruncate, .fmap, .funmap, .fevent, .cancel, .fchmod, .fchown => false,
        else => true,
    };
}

/// Map a Zig error from a backend to an errno for the response.
pub fn errnoFor(err: anyerror) E {
    return switch (err) {
        error.NotFound, error.FileNotFound => .NOENT,
        error.Exists, error.PathAlreadyExists, error.AlreadyExists => .EXIST,
        error.NotDir, error.NotDirectory => .NOTDIR,
        error.IsDir, error.IsDirectory => .ISDIR,
        error.NotEmpty, error.DirNotEmpty => .NOTEMPTY,
        error.NoSpace, error.NoSpaceLeft => .NOSPC,
        error.NameTooLong => .NAMETOOLONG,
        error.Loop, error.SymLinkLoop => .LOOP,
        error.InvalidArgument => .INVAL,
        error.CrossDevice => .XDEV,
        error.ReadOnly, error.ReadOnlyFileSystem => .ROFS,
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.OutOfMemory => .NOMEM,
        error.WouldBlock => .AGAIN,
        error.BadHandle => .BADF,
        error.NotSupported => .OPNOTSUPP,
        error.Busy => .BUSY,
        else => .IO,
    };
}

/// A table of server-side handles with id reuse. Ids start at 1.
pub fn HandleTable(comptime T: type) type {
    return struct {
        const Self = @This();
        slots: std.ArrayList(?T) = .empty,
        free: std.ArrayList(u64) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.free.deinit(allocator);
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, value: T) !u64 {
            if (self.free.pop()) |id| {
                self.slots.items[id - 1] = value;
                return id;
            }
            try self.slots.append(allocator, value);
            return self.slots.items.len;
        }

        pub fn get(self: *Self, id: u64) ?*T {
            if (id == 0 or id > self.slots.items.len) return null;
            if (self.slots.items[id - 1]) |*v| return v;
            return null;
        }

        pub fn remove(self: *Self, allocator: std.mem.Allocator, id: u64) ?T {
            if (id == 0 or id > self.slots.items.len) return null;
            const v = self.slots.items[id - 1] orelse return null;
            self.slots.items[id - 1] = null;
            self.free.append(allocator, id) catch {};
            return v;
        }

        pub const Iterator = struct {
            table: *Self,
            i: usize = 0,
            pub fn next(it: *Iterator) ?struct { id: u64, value: *T } {
                while (it.i < it.table.slots.items.len) {
                    const idx = it.i;
                    it.i += 1;
                    if (it.table.slots.items[idx]) |*v| return .{ .id = idx + 1, .value = v };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self };
        }
    };
}

/// Split a request payload of the form "a\x00b".
pub fn splitPair(payload: []const u8) ?struct { a: []const u8, b: []const u8 } {
    const i = std.mem.indexOfScalar(u8, payload, 0) orelse return null;
    return .{ .a = payload[0..i], .b = std.mem.sliceTo(payload[i + 1 ..], 0) };
}

test "handle table" {
    const a = std.testing.allocator;
    var t: HandleTable(u32) = .{};
    defer t.deinit(a);
    const x = try t.insert(a, 10);
    const y = try t.insert(a, 20);
    try std.testing.expectEqual(@as(u64, 1), x);
    try std.testing.expectEqual(@as(u64, 2), y);
    try std.testing.expectEqual(@as(u32, 20), t.get(y).?.*);
    _ = t.remove(a, x);
    try std.testing.expect(t.get(x) == null);
    const z = try t.insert(a, 30);
    try std.testing.expectEqual(x, z);
}

test "server roundtrip over a pipe" {
    const a = std.testing.allocator;
    const fds = try posix.pipe();
    var srv = try Server.fromFd(a, fds[0]);
    defer srv.deinit();
    defer posix.close(fds[1]);
    const req = Request{ .id = 7, .op = .open, .flags = 0, .pid = 1, .uid = 0, .gid = 0, .caller_flags = 0, .handle = 0, .arg0 = 0, .arg1 = 0, .arg2 = 0, .len = 4 };
    var msg: [@sizeOf(Request) + 4]u8 = undefined;
    @memcpy(msg[0..@sizeOf(Request)], std.mem.asBytes(&req));
    @memcpy(msg[@sizeOf(Request)..], "/tmp");
    _ = try posix.write(fds[1], &msg);
    const in = try srv.receive();
    try std.testing.expectEqual(@as(u64, 7), in.req.id);
    try std.testing.expectEqualStrings("/tmp", in.payload);
}
