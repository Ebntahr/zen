//! ptyd — pseudo-terminal server providing the `pty:` scheme.
//!
//!   open("pty:ptmx")  → new terminal, returns the master side
//!   open("pty:N")     → slave side of terminal N (also /dev/pts/N)
//!
//! The master is used by terminal emulators (Terminal.app, the serial
//! getty); programs run on the slave. The line discipline lives in
//! ldisc.zig. Reads block (the request is answered later), poll()
//! readiness is reported through `fevent` requests.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const ld = @import("ldisc.zig");

const posix = std.posix;
const Server = zen.server.Server;
const E = std.os.linux.E;
const sc = abi.scheme;

// ioctl request numbers (Linux, asm-generic)
const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TCSETSW = 0x5403;
const TCSETSF = 0x5404;
const TCSBRK = 0x5409;
const TCXONC = 0x540A;
const TCFLSH = 0x540B;
const TIOCSCTTY = 0x540E;
const TIOCGPGRP = 0x540F;
const TIOCSPGRP = 0x5410;
const TIOCOUTQ = 0x5411;
const TIOCGWINSZ = 0x5413;
const TIOCSWINSZ = 0x5414;
const FIONREAD = 0x541B;
const TIOCNOTTY = 0x5422;
const TIOCGSID = 0x5429;
const TIOCGPTN = 0x80045430;
const TIOCSPTLCK = 0x40045431;

const Side = enum { master, slave };

const Pending = struct {
    id: u64,
    side: Side,
    kind: enum { read, write, fevent },
    handle: u64,
    /// read: requested length; fevent: requested events.
    arg: u64,
    /// write: data still to deliver.
    data: []u8 = &.{},
    written: usize = 0,
    /// Monotonic deadline in ns for VTIME reads (0 = none).
    deadline: u64 = 0,
};

const Pty = struct {
    index: u32,
    ldisc: ld.Ldisc = .{},
    masters: u32 = 0,
    slaves: u32 = 0,
    slave_ever_opened: bool = false,
    locked: bool = true,
    sid: i32 = 0,
    fg_pgid: i32 = 0,
};

const Handle = struct {
    pty: *Pty,
    side: Side,
    nonblock: bool,
};

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

var srv: Server = undefined;
var handles: zen.server.HandleTable(Handle) = .{};
var ptys: std.ArrayList(?*Pty) = .empty;
var pending: std.ArrayList(Pending) = .empty;
var scratch: [ld.OUTPUT_CAP]u8 = undefined;

fn nowNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn signalGroup(pty: *Pty, sig: ld.Signal) void {
    if (sig == .none) return;
    const target: i32 = if (pty.fg_pgid > 0) -pty.fg_pgid else if (pty.sid > 0) -pty.sid else return;
    posix.kill(target, @intFromEnum(sig)) catch {};
}

fn newPty() !*Pty {
    for (ptys.items, 0..) |slot, i| {
        if (slot == null) {
            const p = try gpa.create(Pty);
            p.* = .{ .index = @intCast(i) };
            ptys.items[i] = p;
            return p;
        }
    }
    const p = try gpa.create(Pty);
    p.* = .{ .index = @intCast(ptys.items.len) };
    try ptys.append(gpa, p);
    return p;
}

fn maybeFree(pty: *Pty) void {
    if (pty.masters == 0 and pty.slaves == 0) {
        ptys.items[pty.index] = null;
        gpa.destroy(pty);
    }
}

fn readiness(h: *const Handle) u32 {
    const p = h.pty;
    var ev: u32 = sc.POLLOUT;
    switch (h.side) {
        .master => {
            if (p.ldisc.masterReadable()) ev |= sc.POLLIN;
            if (p.slave_ever_opened and p.slaves == 0) ev |= sc.POLLHUP | sc.POLLIN;
        },
        .slave => {
            if (p.ldisc.slaveReadable()) ev |= sc.POLLIN;
            if (p.masters == 0) ev |= sc.POLLHUP | sc.POLLIN;
        },
    }
    return ev;
}

/// Try to complete a read; returns true when the request was answered.
fn tryRead(id: u64, h: *Handle, len: u64, timed_out: bool) !bool {
    const p = h.pty;
    const want: usize = @intCast(@min(len, scratch.len));
    switch (h.side) {
        .master => {
            if (p.ldisc.masterReadable()) {
                const n = p.ldisc.readMaster(scratch[0..want]);
                try srv.reply(id, @intCast(n), scratch[0..n]);
                return true;
            }
            if (p.slave_ever_opened and p.slaves == 0) {
                try srv.replyError(id, .IO);
                return true;
            }
        },
        .slave => {
            if (p.ldisc.slaveReadable()) {
                const n = p.ldisc.readSlave(scratch[0..want]);
                try srv.reply(id, @intCast(n), scratch[0..n]);
                return true;
            }
            if (p.masters == 0) {
                try srv.reply(id, 0, "");
                return true;
            }
            // Non-canonical VMIN=0: return immediately (or at VTIME expiry).
            if (!p.ldisc.canonical() and p.ldisc.termios.cc[ld.VMIN] == 0) {
                if (p.ldisc.termios.cc[ld.VTIME] == 0 or timed_out) {
                    try srv.reply(id, 0, "");
                    return true;
                }
            }
        },
    }
    if (h.nonblock) {
        try srv.replyError(id, .AGAIN);
        return true;
    }
    return false;
}

/// Re-examine every pending request after state changed.
fn pump() !void {
    var progress = true;
    while (progress) {
        progress = false;
        var i: usize = 0;
        while (i < pending.items.len) {
            const pr = &pending.items[i];
            const h = handles.get(pr.handle) orelse {
                if (pr.data.len > 0) gpa.free(pr.data);
                _ = pending.swapRemove(i);
                continue;
            };
            var done = false;
            switch (pr.kind) {
                .read => done = try tryRead(pr.id, h, pr.arg, pr.deadline != 0 and nowNs() >= pr.deadline),
                .fevent => {
                    const ready = readiness(h) & @as(u32, @intCast(pr.arg | sc.POLLHUP));
                    if (ready != 0) {
                        try srv.replyValue(pr.id, ready);
                        done = true;
                    }
                },
                .write => {
                    // Slave output waiting for buffer space.
                    const n = h.pty.ldisc.output(pr.data[pr.written..]);
                    pr.written += n;
                    if (n > 0) progress = true;
                    if (pr.written == pr.data.len or h.pty.masters == 0) {
                        try srv.replyValue(pr.id, pr.written);
                        done = true;
                    }
                },
            }
            if (done) {
                if (pr.data.len > 0) gpa.free(pr.data);
                _ = pending.swapRemove(i);
                progress = true;
            } else {
                i += 1;
            }
        }
    }
}

fn handleOpen(in: zen.server.Incoming) !void {
    const path = std.mem.trim(u8, in.payload, "/");
    const nonblock = in.req.flags & sc.O_NONBLOCK != 0;
    if (path.len == 0 or std.mem.eql(u8, path, "ptmx")) {
        const p = try newPty();
        p.masters = 1;
        const id = try handles.insert(gpa, .{ .pty = p, .side = .master, .nonblock = nonblock });
        return srv.replyValue(in.req.id, id);
    }
    const n = std.fmt.parseInt(u32, path, 10) catch return srv.replyError(in.req.id, .NOENT);
    if (n >= ptys.items.len or ptys.items[n] == null) return srv.replyError(in.req.id, .NOENT);
    const p = ptys.items[n].?;
    if (p.masters == 0) return srv.replyError(in.req.id, .IO);
    p.slaves += 1;
    p.slave_ever_opened = true;
    const id = try handles.insert(gpa, .{ .pty = p, .side = .slave, .nonblock = nonblock });
    try srv.replyValue(in.req.id, id);
}

fn handleIoctl(in: zen.server.Incoming, h: *Handle) !void {
    const p = h.pty;
    const cmd: u32 = @truncate(in.req.arg0);
    const arg_int: i64 = if (in.payload.len >= 4) std.mem.readInt(i32, in.payload[0..4], .little) else 0;
    switch (cmd) {
        TCGETS => try srv.replyStruct(in.req.id, &p.ldisc.termios),
        TCSETS, TCSETSW, TCSETSF => {
            if (in.payload.len < @sizeOf(ld.Termios)) return srv.replyError(in.req.id, .INVAL);
            var t: ld.Termios = undefined;
            @memcpy(std.mem.asBytes(&t), in.payload[0..@sizeOf(ld.Termios)]);
            if (cmd == TCSETSF) p.ldisc.flushInput();
            p.ldisc.setTermios(t);
            try srv.replyOk(in.req.id);
        },
        TIOCGWINSZ => try srv.replyStruct(in.req.id, &p.ldisc.winsize),
        TIOCSWINSZ => {
            if (in.payload.len < @sizeOf(ld.Winsize)) return srv.replyError(in.req.id, .INVAL);
            var ws: ld.Winsize = undefined;
            @memcpy(std.mem.asBytes(&ws), in.payload[0..@sizeOf(ld.Winsize)]);
            const changed = ws.rows != p.ldisc.winsize.rows or ws.cols != p.ldisc.winsize.cols;
            p.ldisc.winsize = ws;
            if (changed) signalGroup(p, .winch);
            try srv.replyOk(in.req.id);
        },
        TIOCGPGRP => {
            const v: i32 = p.fg_pgid;
            try srv.replyStruct(in.req.id, &v);
        },
        TIOCSPGRP => {
            p.fg_pgid = @intCast(arg_int);
            try srv.replyOk(in.req.id);
        },
        TIOCGSID => {
            const v: i32 = p.sid;
            try srv.replyStruct(in.req.id, &v);
        },
        TIOCSCTTY => {
            p.sid = @intCast(in.req.pid);
            p.fg_pgid = @intCast(in.req.pid);
            try srv.replyOk(in.req.id);
        },
        TIOCNOTTY => {
            p.sid = 0;
            p.fg_pgid = 0;
            try srv.replyOk(in.req.id);
        },
        FIONREAD => {
            const v: i32 = @intCast(switch (h.side) {
                .master => p.ldisc.out.len,
                .slave => p.ldisc.slaveAvailable(),
            });
            try srv.replyStruct(in.req.id, &v);
        },
        TIOCOUTQ => {
            const v: i32 = @intCast(p.ldisc.out.len);
            try srv.replyStruct(in.req.id, &v);
        },
        TIOCGPTN => {
            if (h.side != .master) return srv.replyError(in.req.id, .NOTTY);
            const v: u32 = p.index;
            try srv.replyStruct(in.req.id, &v);
        },
        TIOCSPTLCK => {
            p.locked = arg_int != 0;
            try srv.replyOk(in.req.id);
        },
        TCFLSH => {
            switch (arg_int) {
                0 => p.ldisc.flushInput(),
                1 => p.ldisc.flushOutput(),
                else => {
                    p.ldisc.flushInput();
                    p.ldisc.flushOutput();
                },
            }
            try srv.replyOk(in.req.id);
        },
        TCSBRK, TCXONC => try srv.replyOk(in.req.id),
        else => try srv.replyError(in.req.id, .NOTTY),
    }
}

fn handle(in: zen.server.Incoming) !void {
    const req = in.req;
    switch (req.op) {
        .open => return handleOpen(in),
        .stat, .lstat => {
            const path = std.mem.trim(u8, in.payload, "/");
            var st = sc.Stat{ .mode = sc.S_IFCHR | 0o620, .rdev = (136 << 8) };
            if (path.len == 0 or std.mem.eql(u8, path, "ptmx")) {
                st.mode = sc.S_IFCHR | 0o666;
                st.rdev = (5 << 8) | 2;
            } else {
                const n = std.fmt.parseInt(u32, path, 10) catch return srv.replyError(req.id, .NOENT);
                if (n >= ptys.items.len or ptys.items[n] == null) return srv.replyError(req.id, .NOENT);
                st.rdev |= n;
                st.ino = n + 3;
            }
            return srv.replyStruct(req.id, &st);
        },
        .getdents => return srv.replyError(req.id, .NOTDIR),
        .cancel => {
            for (pending.items, 0..) |pr, i| {
                if (pr.id == req.arg0) {
                    if (pr.data.len > 0) gpa.free(pr.data);
                    _ = pending.swapRemove(i);
                    break;
                }
            }
            return;
        },
        else => {},
    }

    const h = handles.get(req.handle) orelse return srv.replyError(req.id, .BADF);
    const p = h.pty;
    switch (req.op) {
        .close => {
            const side = h.side;
            _ = handles.remove(gpa, req.handle);
            switch (side) {
                .master => {
                    p.masters -= 1;
                    if (p.masters == 0) signalGroup(p, .hup);
                },
                .slave => p.slaves -= 1,
            }
            try pump();
            maybeFree(p);
        },
        .read => {
            if (!try tryRead(req.id, h, req.len, false)) {
                var deadline: u64 = 0;
                const vtime = p.ldisc.termios.cc[ld.VTIME];
                if (h.side == .slave and !p.ldisc.canonical() and vtime > 0)
                    deadline = nowNs() + @as(u64, vtime) * 100 * std.time.ns_per_ms;
                try pending.append(gpa, .{ .id = req.id, .side = h.side, .kind = .read, .handle = req.handle, .arg = req.len, .deadline = deadline });
            }
        },
        .write => {
            switch (h.side) {
                .master => {
                    const sig = p.ldisc.input(in.payload);
                    signalGroup(p, sig);
                    try srv.replyValue(req.id, in.payload.len);
                },
                .slave => {
                    if (p.masters == 0) return srv.replyError(req.id, .IO);
                    const n = p.ldisc.output(in.payload);
                    if (n == in.payload.len or n > 0 or h.nonblock) {
                        if (n == 0) return srv.replyError(req.id, .AGAIN);
                        try srv.replyValue(req.id, n);
                    } else {
                        const copy = try gpa.dupe(u8, in.payload);
                        try pending.append(gpa, .{ .id = req.id, .side = .slave, .kind = .write, .handle = req.handle, .arg = 0, .data = copy });
                    }
                },
            }
            try pump();
        },
        .fevent => {
            const ready = readiness(h) & @as(u32, @intCast(req.arg0 | sc.POLLHUP));
            if (ready != 0) return srv.replyValue(req.id, ready);
            try pending.append(gpa, .{ .id = req.id, .side = h.side, .kind = .fevent, .handle = req.handle, .arg = req.arg0 });
        },
        .ioctl => {
            try handleIoctl(in, h);
            try pump();
        },
        .fstat => {
            var st = sc.Stat{ .mode = sc.S_IFCHR | 0o620, .rdev = (136 << 8) | p.index, .ino = p.index + 3 };
            if (h.side == .master) {
                st.mode = sc.S_IFCHR | 0o666;
                st.rdev = (5 << 8) | 2;
            }
            try srv.replyStruct(req.id, &st);
        },
        .fpath => {
            var buf: [32]u8 = undefined;
            const s = switch (h.side) {
                .master => "ptmx",
                .slave => std.fmt.bufPrint(&buf, "{d}", .{p.index}) catch "?",
            };
            try srv.reply(req.id, @intCast(s.len), s);
        },
        .dup => {
            // dup(master, "slave") opens the peer (like TIOCGPTPEER).
            if (std.mem.eql(u8, in.payload, "slave")) {
                p.slaves += 1;
                p.slave_ever_opened = true;
                const id = try handles.insert(gpa, .{ .pty = p, .side = .slave, .nonblock = false });
                return srv.replyValue(req.id, id);
            }
            switch (h.side) {
                .master => p.masters += 1,
                .slave => p.slaves += 1,
            }
            const id = try handles.insert(gpa, h.*);
            try srv.replyValue(req.id, id);
        },
        .fsync, .ftruncate, .fchmod, .fchown, .futimens => try srv.replyOk(req.id),
        .seek => try srv.replyError(req.id, .SPIPE),
        else => try srv.replyError(req.id, .NOSYS),
    }
}

fn nextTimeoutMs() i32 {
    var nearest: u64 = 0;
    for (pending.items) |pr| {
        if (pr.deadline != 0 and (nearest == 0 or pr.deadline < nearest)) nearest = pr.deadline;
    }
    if (nearest == 0) return -1;
    const now = nowNs();
    if (nearest <= now) return 0;
    return @intCast(@min((nearest - now) / std.time.ns_per_ms + 1, 60_000));
}

pub fn main() !void {
    zen.sys.setName("ptyd");
    srv = Server.register(gpa, "pty") catch |err| {
        zen.sys.logf("ptyd: cannot register scheme: {s}", .{@errorName(err)});
        return err;
    };
    zen.sys.logf("ptyd: serving pty:", .{});
    while (true) {
        const timeout = nextTimeoutMs();
        if (timeout >= 0) {
            var fds = [_]posix.pollfd{.{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&fds, timeout) catch 0;
            if (fds[0].revents == 0) {
                try pump();
                continue;
            }
        }
        const in = srv.receive() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        handle(in) catch |err| {
            zen.sys.logf("ptyd: request {d} failed: {s}", .{ in.req.id, @errorName(err) });
            srv.replyError(in.req.id, zen.server.errnoFor(err)) catch {};
        };
    }
}
