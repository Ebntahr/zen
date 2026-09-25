//! The `file:` scheme service on top of the ext2 library.
//!
//! OS-independent: requests come in as `abi.scheme.Request` + payload and
//! replies go out through a `Responder`, so the whole service is unit
//! tested on the host against an in-memory disk.

const std = @import("std");
const abi = @import("abi");
const ext2 = @import("ext2");

const sc = abi.scheme;
const Request = sc.Request;
const E = std.os.linux.E;
const Ino = ext2.Ino;

pub const Responder = struct {
    ptr: *anyopaque,
    replyFn: *const fn (ptr: *anyopaque, id: u64, result: i64, data: []const u8) void,

    pub fn reply(self: Responder, id: u64, result: i64, data: []const u8) void {
        self.replyFn(self.ptr, id, result, data);
    }
    pub fn err(self: Responder, id: u64, e: E) void {
        self.reply(id, -@as(i64, @intFromEnum(e)), "");
    }
    pub fn value(self: Responder, id: u64, v: u64) void {
        self.reply(id, @intCast(v), "");
    }
};

pub const R: u3 = 4;
pub const W: u3 = 2;
pub const X: u3 = 1;

const MAX_SYMLINKS = 40;

pub const Cred = struct {
    uid: u32,
    gid: u32,
};

const Handle = struct {
    ino: Ino,
    offset: u64 = 0,
    readable: bool,
    writable: bool,
    append: bool,
    is_dir: bool,
    dir_cookie: u64 = 0,
    path: []u8,
};

pub fn toErrno(err: anyerror) E {
    return switch (err) {
        error.NotFound => .NOENT,
        error.Exists => .EXIST,
        error.NotDir => .NOTDIR,
        error.IsDir => .ISDIR,
        error.NotEmpty => .NOTEMPTY,
        error.NoSpace => .NOSPC,
        error.NameTooLong => .NAMETOOLONG,
        error.Loop => .LOOP,
        error.InvalidArgument => .INVAL,
        error.CrossDevice => .XDEV,
        error.ReadOnly => .ROFS,
        error.FileTooBig => .FBIG,
        error.TooManyLinks => .MLINK,
        error.NotPermitted => .PERM,
        error.AccessDenied => .ACCES,
        error.Busy => .BUSY,
        error.OutOfMemory => .NOMEM,
        error.BadHandle => .BADF,
        else => .IO,
    };
}

pub const Service = struct {
    allocator: std.mem.Allocator,
    fs: *ext2.Fs,
    handles: std.AutoHashMapUnmanaged(u64, Handle) = .empty,
    next_handle: u64 = 1,
    dirty: bool = false,
    /// Supplementary group cache (from /etc/passwd + /etc/group).
    groups: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    groups_mtime: i64 = -1,
    scratch: []u8,

    pub fn init(allocator: std.mem.Allocator, fs: *ext2.Fs) !Service {
        return .{ .allocator = allocator, .fs = fs, .scratch = try allocator.alloc(u8, 1 << 20) };
    }

    pub fn deinit(self: *Service) void {
        var it = self.handles.valueIterator();
        while (it.next()) |h| self.allocator.free(h.path);
        self.handles.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.allocator.free(self.scratch);
    }

    // ------------------------------------------------------------------
    // Credentials and permissions
    // ------------------------------------------------------------------

    fn readWholeFile(self: *Service, path: []const u8) ?[]u8 {
        const ino = self.fs.lookup(path) catch return null;
        const st = self.fs.stat(ino) catch return null;
        if (st.size > 1 << 20) return null;
        const buf = self.allocator.alloc(u8, @intCast(st.size)) catch return null;
        const n = self.fs.read(ino, 0, buf) catch {
            self.allocator.free(buf);
            return null;
        };
        return buf[0..n];
    }

    /// Refresh the (uid, gid) membership cache when /etc/group changes.
    fn refreshGroups(self: *Service) void {
        const ino = self.fs.lookup("/etc/group") catch return;
        const st = self.fs.stat(ino) catch return;
        if (st.mtime == self.groups_mtime) return;
        self.groups_mtime = st.mtime;
        self.groups.clearRetainingCapacity();
        const passwd = self.readWholeFile("/etc/passwd") orelse return;
        defer self.allocator.free(passwd);
        const group = self.readWholeFile("/etc/group") orelse return;
        defer self.allocator.free(group);
        var glines = std.mem.splitScalar(u8, group, '\n');
        while (glines.next()) |gl| {
            var gf = std.mem.splitScalar(u8, gl, ':');
            _ = gf.next() orelse continue;
            _ = gf.next() orelse continue;
            const gid = std.fmt.parseInt(u32, gf.next() orelse continue, 10) catch continue;
            var members = std.mem.splitScalar(u8, gf.next() orelse "", ',');
            while (members.next()) |m| {
                if (m.len == 0) continue;
                var plines = std.mem.splitScalar(u8, passwd, '\n');
                while (plines.next()) |pl| {
                    var pf = std.mem.splitScalar(u8, pl, ':');
                    const name = pf.next() orelse continue;
                    if (!std.mem.eql(u8, name, m)) continue;
                    _ = pf.next();
                    const uid = std.fmt.parseInt(u32, pf.next() orelse continue, 10) catch continue;
                    self.groups.put(self.allocator, (@as(u64, uid) << 32) | gid, true) catch {};
                }
            }
        }
    }

    fn inGroup(self: *Service, c: Cred, gid: u32) bool {
        if (c.gid == gid) return true;
        return self.groups.contains((@as(u64, c.uid) << 32) | gid);
    }

    fn allowed(self: *Service, c: Cred, st: ext2.Stat, want: u3) bool {
        if (c.uid == 0) {
            // Root may execute only if someone may execute.
            if (want & X != 0 and st.kind != .directory and st.mode & 0o111 == 0) return false;
            return true;
        }
        const bits: u3 = if (st.uid == c.uid)
            @truncate(st.mode >> 6)
        else if (self.inGroup(c, st.gid))
            @truncate(st.mode >> 3)
        else
            @truncate(st.mode);
        return bits & want == want;
    }

    fn check(self: *Service, c: Cred, ino: Ino, want: u3) !ext2.Stat {
        const st = try self.fs.stat(ino);
        if (!self.allowed(c, st, want)) return error.AccessDenied;
        return st;
    }

    // ------------------------------------------------------------------
    // Path resolution with search-permission checks and symlinks
    // ------------------------------------------------------------------

    const Walk = struct { parent: Ino, ino: ?Ino, name: []const u8 };

    /// Resolve `path`. When the final component is missing, `ino` is null
    /// and `parent`/`name` say where it would be created.
    fn walk(self: *Service, c: Cred, path: []const u8, follow_last: bool, buf: *[4096]u8) !Walk {
        var hops: usize = 0;
        var cur_path: []const u8 = path;
        var dir: Ino = ext2.ROOT_INO;
        outer: while (true) {
            var it = std.mem.tokenizeScalar(u8, cur_path, '/');
            if (cur_path.len > 0 and cur_path[0] == '/') dir = ext2.ROOT_INO;
            var comp = it.next() orelse return .{ .parent = dir, .ino = dir, .name = "" };
            while (true) {
                const next = it.next();
                const st_dir = try self.fs.stat(dir);
                if (st_dir.kind != .directory) return error.NotDir;
                if (!self.allowed(c, st_dir, X)) return error.AccessDenied;
                if (comp.len > 255) return error.NameTooLong;
                const child = self.fs.lookupChild(dir, comp) catch |e| switch (e) {
                    error.NotFound => {
                        if (next != null) return error.NotFound;
                        return .{ .parent = dir, .ino = null, .name = comp };
                    },
                    else => return e,
                };
                const st = try self.fs.stat(child);
                if (st.kind == .symlink and (next != null or follow_last)) {
                    hops += 1;
                    if (hops > MAX_SYMLINKS) return error.Loop;
                    var tbuf: [4096]u8 = undefined;
                    const target = try self.fs.readlink(child, &tbuf);
                    // New path = target + "/" + the components not yet walked.
                    var tmp: [4096]u8 = undefined;
                    var n: usize = 0;
                    const parts = [_][]const u8{ target, if (next) |nx| nx else "", it.rest() };
                    for (parts, 0..) |part, pi| {
                        if (part.len == 0) continue;
                        if (pi > 0 and n > 0) {
                            if (n + 1 > tmp.len) return error.NameTooLong;
                            tmp[n] = '/';
                            n += 1;
                        }
                        if (n + part.len > tmp.len) return error.NameTooLong;
                        @memcpy(tmp[n .. n + part.len], part);
                        n += part.len;
                    }
                    // `cur_path` may point into `buf`, so build in `tmp` first.
                    @memcpy(buf[0..n], tmp[0..n]);
                    cur_path = buf[0..n];
                    if (target.len > 0 and target[0] == '/') dir = ext2.ROOT_INO;
                    continue :outer;
                }
                if (next) |nx| {
                    dir = child;
                    comp = nx;
                } else {
                    return .{ .parent = dir, .ino = child, .name = comp };
                }
            }
        }
    }

    fn resolveExisting(self: *Service, c: Cred, path: []const u8, follow: bool) !Ino {
        var buf: [4096]u8 = undefined;
        const w = try self.walk(c, path, follow, &buf);
        return w.ino orelse error.NotFound;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn toStat(st: ext2.Stat) sc.Stat {
        return .{
            .dev = 0x801,
            .ino = st.ino,
            .mode = st.mode,
            .nlink = st.nlink,
            .uid = st.uid,
            .gid = st.gid,
            .rdev = (@as(u64, st.rdev.major) << 8) | (st.rdev.minor & 0xff) | ((@as(u64, st.rdev.minor) & ~@as(u64, 0xff)) << 12),
            .size = @intCast(st.size),
            .blksize = @intCast(st.blksize),
            .blocks = @intCast(st.blocks),
            .atime_sec = st.atime,
            .mtime_sec = st.mtime,
            .ctime_sec = st.ctime,
        };
    }

    fn dtype(k: ext2.FileType) u8 {
        return switch (k) {
            .regular => sc.DT_REG,
            .directory => sc.DT_DIR,
            .char_device => sc.DT_CHR,
            .block_device => sc.DT_BLK,
            .fifo => sc.DT_FIFO,
            .socket => sc.DT_SOCK,
            .symlink => sc.DT_LNK,
            .unknown => sc.DT_UNKNOWN,
        };
    }

    fn cred(req: Request) Cred {
        return .{ .uid = req.uid, .gid = req.gid };
    }

    /// Sticky directories: only the owner of the file or directory (or
    /// root) may remove or rename entries.
    fn stickyOk(self: *Service, c: Cred, parent: Ino, child: Ino) !void {
        if (c.uid == 0) return;
        const pst = try self.fs.stat(parent);
        if (pst.mode & sc.S_ISVTX == 0) return;
        const cst = try self.fs.stat(child);
        if (cst.uid != c.uid and pst.uid != c.uid) return error.NotPermitted;
    }

    // ------------------------------------------------------------------
    // Request dispatch
    // ------------------------------------------------------------------

    pub fn handle(self: *Service, req: Request, payload: []const u8, out: Responder) void {
        self.handleInner(req, payload, out) catch |e| out.err(req.id, toErrno(e));
    }

    fn handleInner(self: *Service, req: Request, payload: []const u8, out: Responder) !void {
        const c = cred(req);
        self.refreshGroups();
        switch (req.op) {
            .open => return self.open(req, payload, out),
            .stat, .lstat => {
                const ino = try self.resolveExisting(c, payload, req.op == .stat);
                const st = toStat(try self.fs.stat(ino));
                return out.reply(req.id, 0, std.mem.asBytes(&st));
            },
            .access => {
                const ino = try self.resolveExisting(c, payload, true);
                const want: u3 = @truncate(req.arg0);
                if (want != 0) _ = try self.check(c, ino, want);
                return out.value(req.id, 0);
            },
            .mkdir => {
                var buf: [4096]u8 = undefined;
                const w = try self.walk(c, payload, false, &buf);
                if (w.ino != null) return error.Exists;
                _ = try self.check(c, w.parent, W | X);
                _ = try self.fs.mkdir(w.parent, w.name, @intCast(req.arg0 & 0o7777), c.uid, self.newGid(c, w.parent));
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .mknod => {
                var buf: [4096]u8 = undefined;
                const w = try self.walk(c, payload, false, &buf);
                if (w.ino != null) return error.Exists;
                _ = try self.check(c, w.parent, W | X);
                const mode: u16 = @intCast(req.arg0 & 0xffff);
                const kind = mode & sc.S_IFMT;
                if ((kind == sc.S_IFCHR or kind == sc.S_IFBLK) and c.uid != 0) return error.NotPermitted;
                const rdev = ext2.Dev{ .major = @intCast((req.arg1 >> 8) & 0xfff), .minor = @intCast(req.arg1 & 0xff) };
                _ = try self.fs.mknod(w.parent, w.name, mode, rdev, c.uid, self.newGid(c, w.parent));
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .unlink, .rmdir => {
                var buf: [4096]u8 = undefined;
                const w = try self.walk(c, payload, false, &buf);
                const ino = w.ino orelse return error.NotFound;
                _ = try self.check(c, w.parent, W | X);
                try self.stickyOk(c, w.parent, ino);
                if (req.op == .unlink) try self.fs.unlink(w.parent, w.name) else try self.fs.rmdir(w.parent, w.name);
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .rename => {
                const pair = splitPair(payload) orelse return error.InvalidArgument;
                var b1: [4096]u8 = undefined;
                var b2: [4096]u8 = undefined;
                const a = try self.walk(c, pair.a, false, &b1);
                const src = a.ino orelse return error.NotFound;
                const b = try self.walk(c, pair.b, false, &b2);
                _ = try self.check(c, a.parent, W | X);
                _ = try self.check(c, b.parent, W | X);
                try self.stickyOk(c, a.parent, src);
                if (b.ino) |dst| try self.stickyOk(c, b.parent, dst);
                try self.fs.rename(a.parent, a.name, b.parent, b.name);
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .symlink => {
                const pair = splitPair(payload) orelse return error.InvalidArgument;
                var buf: [4096]u8 = undefined;
                const w = try self.walk(c, pair.b, false, &buf);
                if (w.ino != null) return error.Exists;
                _ = try self.check(c, w.parent, W | X);
                _ = try self.fs.symlink(w.parent, w.name, pair.a, c.uid, self.newGid(c, w.parent));
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .link => {
                const pair = splitPair(payload) orelse return error.InvalidArgument;
                const src = try self.resolveExisting(c, pair.a, false);
                var buf: [4096]u8 = undefined;
                const w = try self.walk(c, pair.b, false, &buf);
                if (w.ino != null) return error.Exists;
                _ = try self.check(c, w.parent, W | X);
                try self.fs.link(src, w.parent, w.name);
                self.dirty = true;
                return out.value(req.id, 0);
            },
            .readlink => {
                const ino = try self.resolveExisting(c, payload, false);
                var buf: [4096]u8 = undefined;
                const t = try self.fs.readlink(ino, &buf);
                const n = @min(t.len, @as(usize, @intCast(@max(req.arg0, 1))));
                return out.reply(req.id, @intCast(t.len), t[0..@min(n, t.len)]);
            },
            .chmod => {
                const ino = try self.resolveExisting(c, payload, true);
                return self.chmodIno(req, ino, out);
            },
            .chown => {
                const ino = try self.resolveExisting(c, payload, req.flags & 1 == 0);
                return self.chownIno(req, ino, out);
            },
            .utimens => {
                if (payload.len < 32) return error.InvalidArgument;
                const ino = try self.resolveExisting(c, payload[32..], req.flags & 1 == 0);
                return self.utimensIno(req, ino, payload[0..32], out);
            },
            .statfs => return self.statfs(req, out),
            .cancel => return,
            else => {},
        }

        const h = self.handles.getPtr(req.handle) orelse return error.BadHandle;
        switch (req.op) {
            .close => {
                self.allocator.free(h.path);
                _ = self.handles.remove(req.handle);
            },
            .dup => {
                const copy = Handle{
                    .ino = h.ino,
                    .offset = h.offset,
                    .readable = h.readable,
                    .writable = h.writable,
                    .append = h.append,
                    .is_dir = h.is_dir,
                    .dir_cookie = h.dir_cookie,
                    .path = try self.allocator.dupe(u8, h.path),
                };
                const id = self.next_handle;
                self.next_handle += 1;
                try self.handles.put(self.allocator, id, copy);
                out.value(req.id, id);
            },
            .read => {
                if (h.is_dir) return error.IsDir;
                if (!h.readable) return error.BadHandle;
                const want: usize = @intCast(@min(req.len, self.scratch.len));
                const off = if (req.arg1 == 1) req.arg0 else h.offset;
                const n = try self.fs.read(h.ino, off, self.scratch[0..want]);
                if (req.arg1 != 1) h.offset += n;
                out.reply(req.id, @intCast(n), self.scratch[0..n]);
            },
            .write => {
                if (h.is_dir) return error.IsDir;
                if (!h.writable) return error.BadHandle;
                var off = if (req.arg1 == 1) req.arg0 else h.offset;
                if (h.append and req.arg1 != 1) off = (try self.fs.stat(h.ino)).size;
                const n = try self.fs.write(h.ino, off, payload);
                if (req.arg1 != 1) h.offset = off + n;
                self.dirty = true;
                out.value(req.id, n);
            },
            .seek => {
                const off: i64 = @bitCast(req.arg0);
                const base: i64 = switch (req.arg1) {
                    0 => 0,
                    1 => @intCast(h.offset),
                    2 => @intCast((try self.fs.stat(h.ino)).size),
                    3, 4 => @intCast(h.offset), // SEEK_DATA / SEEK_HOLE approximations
                    else => return error.InvalidArgument,
                };
                if (base + off < 0) return error.InvalidArgument;
                h.offset = @intCast(base + off);
                if (h.is_dir and h.offset == 0) h.dir_cookie = 0;
                out.value(req.id, h.offset);
            },
            .fstat => {
                const st = toStat(try self.fs.stat(h.ino));
                out.reply(req.id, 0, std.mem.asBytes(&st));
            },
            .fsync => {
                try self.fs.sync();
                self.dirty = false;
                out.value(req.id, 0);
            },
            .ftruncate => {
                if (!h.writable) return error.InvalidArgument;
                try self.fs.truncate(h.ino, req.arg0);
                self.dirty = true;
                out.value(req.id, 0);
            },
            .getdents => {
                if (!h.is_dir) return error.NotDir;
                var it = try self.fs.readdir(h.ino, h.dir_cookie);
                const cap: usize = @intCast(@min(req.len, self.scratch.len));
                var pos: usize = 0;
                while (try it.next()) |e| {
                    const np = sc.putDirent(self.scratch[0..cap], pos, e.ino, @intCast(e.cookie), dtype(e.kind), e.name) orelse break;
                    pos = np;
                    h.dir_cookie = e.cookie;
                }
                if (pos == 0 and cap < 280) return error.InvalidArgument;
                out.reply(req.id, @intCast(pos), self.scratch[0..pos]);
            },
            .fchmod => try self.chmodIno(req, h.ino, out),
            .fchown => try self.chownIno(req, h.ino, out),
            .futimens => {
                if (payload.len < 32) return error.InvalidArgument;
                try self.utimensIno(req, h.ino, payload[0..32], out);
            },
            .fstatfs => try self.statfs(req, out),
            .fpath => out.reply(req.id, @intCast(h.path.len), h.path),
            .fevent => out.value(req.id, sc.POLLIN | sc.POLLOUT),
            .fmap => out.err(req.id, .NODEV),
            .ioctl => out.err(req.id, .NOTTY),
            else => out.err(req.id, .NOSYS),
        }
    }

    /// New files inherit the directory's group when it is setgid.
    fn newGid(self: *Service, c: Cred, parent: Ino) u32 {
        const pst = self.fs.stat(parent) catch return c.gid;
        return if (pst.mode & sc.S_ISGID != 0) pst.gid else c.gid;
    }

    fn open(self: *Service, req: Request, path: []const u8, out: Responder) !void {
        const c = cred(req);
        const flags: u32 = req.flags;
        const acc = flags & sc.O_ACCMODE;
        var buf: [4096]u8 = undefined;
        const w = try self.walk(c, path, flags & sc.O_NOFOLLOW == 0, &buf);
        var ino: Ino = undefined;
        if (w.ino) |existing| {
            if (flags & sc.O_CREAT != 0 and flags & sc.O_EXCL != 0) return error.Exists;
            ino = existing;
        } else {
            if (flags & sc.O_CREAT == 0) return error.NotFound;
            _ = try self.check(c, w.parent, W | X);
            ino = try self.fs.create(w.parent, w.name, @intCast((req.arg0 & 0o7777) | sc.S_IFREG), c.uid, self.newGid(c, w.parent));
            self.dirty = true;
        }
        const st = try self.fs.stat(ino);
        if (st.kind == .symlink and flags & sc.O_NOFOLLOW != 0 and flags & sc.O_PATH == 0) return error.Loop;
        const is_dir = st.kind == .directory;
        if (flags & sc.O_DIRECTORY != 0 and !is_dir) return error.NotDir;
        if (is_dir and acc != sc.O_RDONLY) return error.IsDir;
        const path_only = flags & sc.O_PATH != 0;
        if (!path_only and w.ino != null) {
            var want: u3 = 0;
            if (acc == sc.O_RDONLY or acc == sc.O_RDWR) want |= R;
            if (acc == sc.O_WRONLY or acc == sc.O_RDWR or flags & sc.O_TRUNC != 0) want |= W;
            if (want != 0 and !self.allowed(c, st, want)) return error.AccessDenied;
        }
        if (!path_only and flags & sc.O_TRUNC != 0 and !is_dir and acc != sc.O_RDONLY and st.size > 0) {
            try self.fs.truncate(ino, 0);
            self.dirty = true;
        }
        const id = self.next_handle;
        self.next_handle += 1;
        try self.handles.put(self.allocator, id, .{
            .ino = ino,
            .readable = !path_only and (acc == sc.O_RDONLY or acc == sc.O_RDWR),
            .writable = !path_only and (acc == sc.O_WRONLY or acc == sc.O_RDWR),
            .append = flags & sc.O_APPEND != 0,
            .is_dir = is_dir,
            .path = try self.allocator.dupe(u8, path),
        });
        out.value(req.id, id);
    }

    fn chmodIno(self: *Service, req: Request, ino: Ino, out: Responder) !void {
        const st = try self.fs.stat(ino);
        if (req.uid != 0 and req.uid != st.uid) return error.NotPermitted;
        var mode: u16 = @intCast(req.arg0 & 0o7777);
        // Non-root users may not set setgid on files of other groups.
        if (req.uid != 0 and !self.inGroup(cred(req), st.gid)) mode &= ~@as(u16, sc.S_ISGID);
        try self.fs.chmod(ino, mode);
        self.dirty = true;
        out.value(req.id, 0);
    }

    fn chownIno(self: *Service, req: Request, ino: Ino, out: Responder) !void {
        const st = try self.fs.stat(ino);
        const new_uid: ?u32 = if (req.arg0 == 0xffffffff or @as(i64, @bitCast(req.arg0)) == -1) null else @intCast(req.arg0 & 0xffffffff);
        const new_gid: ?u32 = if (req.arg1 == 0xffffffff or @as(i64, @bitCast(req.arg1)) == -1) null else @intCast(req.arg1 & 0xffffffff);
        if (req.uid != 0) {
            if (new_uid != null and new_uid.? != st.uid) return error.NotPermitted;
            if (st.uid != req.uid) return error.NotPermitted;
            if (new_gid) |g| if (!self.inGroup(cred(req), g)) return error.NotPermitted;
        }
        try self.fs.chown(ino, new_uid, new_gid);
        // Changing ownership clears setuid/setgid.
        if (st.kind == .regular and st.mode & (sc.S_ISUID | sc.S_ISGID) != 0 and req.uid != 0) {
            try self.fs.chmod(ino, st.mode & 0o777);
        }
        self.dirty = true;
        out.value(req.id, 0);
    }

    fn utimensIno(self: *Service, req: Request, ino: Ino, times: []const u8, out: Responder) !void {
        const st = try self.fs.stat(ino);
        const UTIME_NOW: i64 = (1 << 30) - 1;
        const UTIME_OMIT: i64 = (1 << 30) - 2;
        const a_sec = std.mem.readInt(i64, times[0..8], .little);
        const a_nsec = std.mem.readInt(i64, times[8..16], .little);
        const m_sec = std.mem.readInt(i64, times[16..24], .little);
        const m_nsec = std.mem.readInt(i64, times[24..32], .little);
        const setting_explicit = (a_nsec != UTIME_NOW and a_nsec != UTIME_OMIT) or (m_nsec != UTIME_NOW and m_nsec != UTIME_OMIT);
        if (req.uid != 0 and req.uid != st.uid) {
            if (setting_explicit or !self.allowed(cred(req), st, W)) return error.AccessDenied;
        }
        const now = self.fs.now();
        const atime: ?i64 = if (a_nsec == UTIME_OMIT) null else if (a_nsec == UTIME_NOW) now else a_sec;
        const mtime: ?i64 = if (m_nsec == UTIME_OMIT) null else if (m_nsec == UTIME_NOW) now else m_sec;
        try self.fs.utimes(ino, atime, mtime);
        self.dirty = true;
        out.value(req.id, 0);
    }

    fn statfs(self: *Service, req: Request, out: Responder) !void {
        const s = self.fs.statfs();
        const r = sc.Statfs{
            .type = 0xEF53,
            .bsize = s.block_size,
            .blocks = s.total_blocks,
            .bfree = s.free_blocks,
            .bavail = s.avail_blocks,
            .files = s.total_inodes,
            .ffree = s.free_inodes,
            .namelen = s.name_max,
            .frsize = s.block_size,
        };
        out.reply(req.id, 0, std.mem.asBytes(&r));
    }

    /// Write back dirty metadata and data.
    pub fn syncIfDirty(self: *Service) void {
        if (!self.dirty) return;
        self.fs.sync() catch return;
        self.dirty = false;
    }
};

fn splitPair(payload: []const u8) ?struct { a: []const u8, b: []const u8 } {
    const i = std.mem.indexOfScalar(u8, payload, 0) orelse return null;
    return .{ .a = payload[0..i], .b = std.mem.sliceTo(payload[i + 1 ..], 0) };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const Capture = struct {
    result: i64 = 0,
    data: [8192]u8 = undefined,
    len: usize = 0,

    fn replyFn(ptr: *anyopaque, id: u64, result: i64, data: []const u8) void {
        _ = id;
        const self: *Capture = @ptrCast(@alignCast(ptr));
        self.result = result;
        self.len = @min(data.len, self.data.len);
        @memcpy(self.data[0..self.len], data[0..self.len]);
    }

    fn responder(self: *Capture) Responder {
        return .{ .ptr = self, .replyFn = replyFn };
    }
};

const TestEnv = struct {
    md: ext2.MemDevice,
    fs: *ext2.Fs,
    svc: Service,
    cap: Capture = .{},
    next_id: u64 = 1,

    fn init(a: std.mem.Allocator) !*TestEnv {
        const env = try a.create(TestEnv);
        env.md = try ext2.MemDevice.init(a, 8 << 20);
        try ext2.mkfs(a, env.md.device(), .{ .label = "test" });
        env.fs = try ext2.Fs.mount(a, env.md.device(), .{});
        env.svc = try Service.init(a, env.fs);
        env.cap = .{};
        env.next_id = 1;
        return env;
    }

    fn deinit(env: *TestEnv, a: std.mem.Allocator) void {
        env.svc.deinit();
        env.fs.unmount() catch {};
        env.md.deinit();
        a.destroy(env);
    }

    fn call(env: *TestEnv, op: sc.Op, uid: u32, handle_: u64, flags: u32, arg0: u64, arg1: u64, payload: []const u8) i64 {
        const req = Request{ .id = env.next_id, .op = op, .flags = flags, .pid = 2, .uid = uid, .gid = uid, .caller_flags = 0, .handle = handle_, .arg0 = arg0, .arg1 = arg1, .arg2 = 0, .len = if (op == .read or op == .getdents) 4096 else payload.len };
        env.next_id += 1;
        env.svc.handle(req, payload, env.cap.responder());
        return env.cap.result;
    }
};

test "create, write, read, stat, getdents" {
    const a = std.testing.allocator;
    const env = try TestEnv.init(a);
    defer env.deinit(a);

    try std.testing.expectEqual(@as(i64, 0), env.call(.mkdir, 0, 0, 0, 0o755, 0, "/home"));
    const h = env.call(.open, 0, 0, sc.O_CREAT | sc.O_RDWR, 0o644, 0, "/home/hello.txt");
    try std.testing.expect(h > 0);
    try std.testing.expectEqual(@as(i64, 6), env.call(.write, 0, @intCast(h), 0, 0, 0, "hello\n"));
    try std.testing.expectEqual(@as(i64, 0), env.call(.seek, 0, @intCast(h), 0, 0, 0, ""));
    try std.testing.expectEqual(@as(i64, 6), env.call(.read, 0, @intCast(h), 0, 0, 0, ""));
    try std.testing.expectEqualStrings("hello\n", env.cap.data[0..env.cap.len]);
    _ = env.call(.close, 0, @intCast(h), 0, 0, 0, "");

    try std.testing.expectEqual(@as(i64, 0), env.call(.stat, 0, 0, 0, 0, 0, "/home/hello.txt"));
    var st: sc.Stat = undefined;
    @memcpy(std.mem.asBytes(&st), env.cap.data[0..@sizeOf(sc.Stat)]);
    try std.testing.expectEqual(@as(i64, 6), st.size);
    try std.testing.expectEqual(sc.S_IFREG | 0o644, st.mode);

    const d = env.call(.open, 0, 0, sc.O_RDONLY | sc.O_DIRECTORY, 0, 0, "/home");
    try std.testing.expect(d > 0);
    const n = env.call(.getdents, 0, @intCast(d), 0, 0, 0, "");
    try std.testing.expect(n > 0);
    var it = sc.DirentIterator{ .buf = env.cap.data[0..@intCast(n)] };
    var found = false;
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.name, "hello.txt")) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(i64, 0), env.call(.getdents, 0, @intCast(d), 0, 0, 0, ""));
}

test "permissions" {
    const a = std.testing.allocator;
    const env = try TestEnv.init(a);
    defer env.deinit(a);

    _ = env.call(.mkdir, 0, 0, 0, 0o700, 0, "/private");
    const E_ACCES = -@as(i64, @intFromEnum(E.ACCES));
    try std.testing.expectEqual(E_ACCES, env.call(.open, 501, 0, sc.O_CREAT | sc.O_WRONLY, 0o644, 0, "/private/x"));
    try std.testing.expectEqual(E_ACCES, env.call(.mkdir, 501, 0, 0, 0o755, 0, "/userdir"));

    // A world-writable sticky directory like /tmp.
    _ = env.call(.mkdir, 0, 0, 0, 0o777, 0, "/tmp");
    _ = env.call(.chmod, 0, 0, 0, 0o1777, 0, "/tmp");
    const h = env.call(.open, 501, 0, sc.O_CREAT | sc.O_WRONLY, 0o644, 0, "/tmp/mine");
    try std.testing.expect(h > 0);
    _ = env.call(.close, 501, @intCast(h), 0, 0, 0, "");
    const E_PERM = -@as(i64, @intFromEnum(E.PERM));
    try std.testing.expectEqual(E_PERM, env.call(.unlink, 502, 0, 0, 0, 0, "/tmp/mine"));
    try std.testing.expectEqual(@as(i64, 0), env.call(.unlink, 501, 0, 0, 0, 0, "/tmp/mine"));

    // Only root may chown.
    _ = env.call(.open, 0, 0, sc.O_CREAT | sc.O_WRONLY, 0o644, 0, "/rootfile");
    try std.testing.expectEqual(E_PERM, env.call(.chown, 501, 0, 0, 501, 501, "/rootfile"));
    try std.testing.expectEqual(@as(i64, 0), env.call(.chown, 0, 0, 0, 501, 501, "/rootfile"));
    try std.testing.expectEqual(@as(i64, 0), env.call(.chmod, 501, 0, 0, 0o600, 0, "/rootfile"));
}

test "symlinks and rename" {
    const a = std.testing.allocator;
    const env = try TestEnv.init(a);
    defer env.deinit(a);
    _ = env.call(.mkdir, 0, 0, 0, 0o755, 0, "/usr");
    _ = env.call(.mkdir, 0, 0, 0, 0o755, 0, "/usr/bin");
    const h = env.call(.open, 0, 0, sc.O_CREAT | sc.O_WRONLY, 0o755, 0, "/usr/bin/zbox");
    _ = env.call(.write, 0, @intCast(h), 0, 0, 0, "binary");
    _ = env.call(.close, 0, @intCast(h), 0, 0, 0, "");
    try std.testing.expectEqual(@as(i64, 0), env.call(.symlink, 0, 0, 0, 0, 0, "/usr/bin\x00/bin"));
    try std.testing.expectEqual(@as(i64, 0), env.call(.symlink, 0, 0, 0, 0, 0, "zbox\x00/usr/bin/ls"));
    const r = env.call(.open, 0, 0, sc.O_RDONLY, 0, 0, "/bin/ls");
    try std.testing.expect(r > 0);
    try std.testing.expectEqual(@as(i64, 6), env.call(.read, 0, @intCast(r), 0, 0, 0, ""));
    try std.testing.expectEqual(@as(i64, 4), env.call(.readlink, 0, 0, 0, 4096, 0, "/usr/bin/ls"));
    try std.testing.expectEqualStrings("zbox", env.cap.data[0..env.cap.len]);
    try std.testing.expectEqual(@as(i64, 0), env.call(.rename, 0, 0, 0, 0, 0, "/usr/bin/zbox\x00/usr/bin/busybox"));
    try std.testing.expectEqual(-@as(i64, @intFromEnum(E.NOENT)), env.call(.open, 0, 0, sc.O_RDONLY, 0, 0, "/bin/ls"));
}
