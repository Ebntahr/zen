//! virtio-input driver for keyboards, mice and tablets: serves `input:`.
//! Usage: virtio-inputd <phys> <irq> [<phys> <irq> ...]
//!
//! Every reader of `input:` receives every event (`abi.input.InputEvent`),
//! with absolute axes normalized to 0..ABS_MAX.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const virtio = @import("virtio");

const sc = abi.scheme;
const inp = abi.input;
const posix = std.posix;

const CFG_SELECT = 0;
const CFG_SUBSEL = 1;
const CFG_SIZE = 2;
const CFG_DATA = 8;
const CFG_ID_NAME: u8 = 0x01;
const CFG_ABS_INFO: u8 = 0x12;

const VirtioEvent = extern struct { kind: u16, code: u16, value: u32 };

const NBUF = 64;

const Dev = struct {
    dev: virtio.Device,
    q: virtio.Queue,
    irq: virtio.Irq,
    bufs: zen.sys.DmaBuffer,
    name: [64]u8 = [_]u8{0} ** 64,
    abs_min: [2]i32 = .{ 0, 0 },
    abs_max: [2]i32 = .{ inp.ABS_MAX, inp.ABS_MAX },

    fn event(self: *Dev, i: usize) *volatile VirtioEvent {
        return @ptrCast(@alignCast(self.bufs.virt + i * @sizeOf(VirtioEvent)));
    }

    fn post(self: *Dev, i: usize) void {
        const b = [_]virtio.Queue.Buf{.{ .phys = self.bufs.phys + i * @sizeOf(VirtioEvent), .len = @sizeOf(VirtioEvent), .writable = true }};
        _ = self.q.submit(&b);
    }

    fn readConfigString(self: *Dev, select: u8, subsel: u8, out: []u8) []u8 {
        self.dev.setConfig8(CFG_SELECT, select);
        self.dev.setConfig8(CFG_SUBSEL, subsel);
        const size = @min(self.dev.config8(CFG_SIZE), out.len);
        for (0..size) |k| out[k] = self.dev.config8(CFG_DATA + k);
        return out[0..size];
    }
};

/// Per-reader queue of pending events.
const Reader = struct {
    ring: [1024]inp.InputEvent = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Reader, e: inp.InputEvent) void {
        if (self.len == self.ring.len) {
            // Drop the oldest event.
            self.head = (self.head + 1) % self.ring.len;
            self.len -= 1;
        }
        self.ring[(self.head + self.len) % self.ring.len] = e;
        self.len += 1;
    }

    fn pop(self: *Reader, out: []inp.InputEvent) usize {
        const n = @min(out.len, self.len);
        for (0..n) |k| out[k] = self.ring[(self.head + k) % self.ring.len];
        self.head = (self.head + n) % self.ring.len;
        self.len -= n;
        return n;
    }
};

const Pending = struct { id: u64, handle: u64, len: u64, fevent: bool };

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();
var devices: std.ArrayList(Dev) = .empty;
var readers: zen.server.HandleTable(*Reader) = .{};
var pending: std.ArrayList(Pending) = .empty;
var srv: zen.server.Server = undefined;

fn nowNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn broadcast(e: inp.InputEvent) void {
    var it = readers.iterator();
    while (it.next()) |r| r.value.*.push(e);
}

fn normalize(d: *Dev, axis: usize, v: i32) i32 {
    const lo = d.abs_min[axis];
    const hi = d.abs_max[axis];
    if (hi <= lo) return v;
    const t = @as(i64, v - lo) * inp.ABS_MAX;
    return @intCast(std.math.clamp(@divTrunc(t, hi - lo), 0, inp.ABS_MAX));
}

fn drain(d: *Dev) void {
    while (d.q.popUsed()) |u| {
        const i: usize = u.id;
        const ve = d.event(i).*;
        var value: i32 = @bitCast(ve.value);
        if (ve.kind == inp.EV_ABS and ve.code <= inp.ABS_Y) value = normalize(d, ve.code, value);
        broadcast(.{ .time_ns = nowNs(), .kind = ve.kind, .code = ve.code, .value = value });
        d.post(i);
    }
    d.q.kick();
}

fn answerPending() !void {
    var i: usize = 0;
    while (i < pending.items.len) {
        const p = pending.items[i];
        const r = (readers.get(p.handle) orelse {
            _ = pending.swapRemove(i);
            continue;
        }).*;
        if (r.len == 0) {
            i += 1;
            continue;
        }
        if (p.fevent) {
            try srv.replyValue(p.id, sc.POLLIN);
        } else {
            var buf: [128]inp.InputEvent = undefined;
            const max = @min(buf.len, p.len / @sizeOf(inp.InputEvent));
            const n = r.pop(buf[0..max]);
            try srv.reply(p.id, @intCast(n * @sizeOf(inp.InputEvent)), std.mem.sliceAsBytes(buf[0..n]));
        }
        _ = pending.swapRemove(i);
    }
}

fn serve(in: zen.server.Incoming) !void {
    const req = in.req;
    switch (req.op) {
        .open => {
            if (req.uid != 0) return srv.replyError(req.id, .ACCES);
            const r = try gpa.create(Reader);
            r.* = .{};
            const id = try readers.insert(gpa, r);
            return srv.replyValue(req.id, id);
        },
        .cancel => {
            for (pending.items, 0..) |p, i| {
                if (p.id == req.arg0) {
                    _ = pending.swapRemove(i);
                    break;
                }
            }
            return;
        },
        else => {},
    }
    const r = (readers.get(req.handle) orelse return srv.replyError(req.id, .BADF)).*;
    switch (req.op) {
        .close => {
            _ = readers.remove(gpa, req.handle);
            gpa.destroy(r);
        },
        .read => {
            if (req.len < @sizeOf(inp.InputEvent)) return srv.replyError(req.id, .INVAL);
            try pending.append(gpa, .{ .id = req.id, .handle = req.handle, .len = req.len, .fevent = false });
            try answerPending();
        },
        .fevent => {
            try pending.append(gpa, .{ .id = req.id, .handle = req.handle, .len = 0, .fevent = true });
            try answerPending();
        },
        .fstat => {
            const st = sc.Stat{ .mode = sc.S_IFCHR | 0o600 };
            try srv.replyStruct(req.id, &st);
        },
        else => try srv.replyError(req.id, .NOSYS),
    }
}

pub fn main() !void {
    zen.sys.setName("virtio-inputd");
    const args = try std.process.argsAlloc(gpa);
    var a: usize = 1;
    while (a + 1 < args.len) : (a += 2) {
        const phys = std.fmt.parseInt(u64, args[a], 0) catch continue;
        const irqn = std.fmt.parseInt(u32, args[a + 1], 0) catch continue;
        const vdev = virtio.Device.open(phys, .input) catch |err| {
            zen.sys.logf("virtio-inputd: {x}: {s}", .{ phys, @errorName(err) });
            continue;
        };
        _ = try vdev.init(0);
        var d = Dev{
            .dev = vdev,
            .q = try virtio.Queue.init(vdev, 0, NBUF),
            .irq = try virtio.Irq.open(irqn),
            .bufs = try zen.sys.physalloc(NBUF * @sizeOf(VirtioEvent)),
        };
        _ = d.readConfigString(CFG_ID_NAME, 0, &d.name);
        for (0..2) |axis| {
            var info: [20]u8 = undefined;
            const s = d.readConfigString(CFG_ABS_INFO, @intCast(axis), &info);
            if (s.len >= 8) {
                d.abs_min[axis] = std.mem.readInt(i32, s[0..4], .little);
                d.abs_max[axis] = std.mem.readInt(i32, s[4..8], .little);
            }
        }
        vdev.driverOk();
        for (0..d.q.size) |i| d.post(i);
        d.q.kick();
        zen.sys.logf("virtio-inputd: {s}", .{std.mem.sliceTo(&d.name, 0)});
        try devices.append(gpa, d);
    }
    if (devices.items.len == 0) return error.NoDevices;

    srv = try zen.server.Server.register(gpa, "input");
    var fds = try gpa.alloc(posix.pollfd, devices.items.len + 1);
    while (true) {
        fds[0] = .{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 };
        for (devices.items, 0..) |d, i| fds[i + 1] = .{ .fd = d.irq.fd, .events = posix.POLL.IN, .revents = 0 };
        _ = posix.poll(fds, -1) catch continue;
        for (devices.items, 0..) |*d, i| {
            if (fds[i + 1].revents == 0) continue;
            const c = d.irq.wait() catch continue;
            _ = d.dev.ackInterrupt();
            drain(d);
            d.irq.ack(c);
        }
        if (fds[0].revents != 0) {
            const in = srv.receive() catch continue;
            serve(in) catch |err| srv.replyError(in.req.id, zen.server.errnoFor(err)) catch {};
        }
        try answerPending();
    }
}
