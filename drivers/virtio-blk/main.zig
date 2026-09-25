//! virtio-blk driver: serves a disk as the `disk:` scheme (or a scheme
//! named on the command line). Usage: virtio-blkd <mmio-phys> <irq> [name]
//!
//! Byte-addressed reads and writes of any size and alignment are supported;
//! unaligned edges use read-modify-write through the DMA bounce buffer.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const virtio = @import("virtio");

const sc = abi.scheme;
const posix = std.posix;

const SECTOR: u64 = 512;
const CHUNK: usize = 128 * 1024;

const T_IN: u32 = 0;
const T_OUT: u32 = 1;
const T_FLUSH: u32 = 4;

const F_RO: u6 = 5;
const F_FLUSH: u6 = 9;

const ReqHeader = extern struct { kind: u32, reserved: u32, sector: u64 };

var dev: virtio.Device = undefined;
var queue: virtio.Queue = undefined;
var irq: virtio.Irq = undefined;
var dma: zen.sys.DmaBuffer = undefined;
var capacity_bytes: u64 = 0;
var read_only = false;
var has_flush = false;

// DMA layout: [0..16) header, [16] status, [4096..4096+CHUNK) data.
const HDR_OFF = 0;
const STATUS_OFF = 16;
const DATA_OFF = 4096;

fn dataBuf() []u8 {
    return dma.virt[DATA_OFF .. DATA_OFF + CHUNK];
}

/// Transfer `count` sectors between the device and the data buffer.
fn transfer(kind: u32, sector: u64, count: usize) !void {
    const hdr: *volatile ReqHeader = @ptrCast(@alignCast(dma.virt + HDR_OFF));
    hdr.* = .{ .kind = kind, .reserved = 0, .sector = sector };
    dma.virt[STATUS_OFF] = 0xff;
    var bufs: [3]virtio.Queue.Buf = undefined;
    var n: usize = 0;
    bufs[n] = .{ .phys = dma.phys + HDR_OFF, .len = @sizeOf(ReqHeader), .writable = false };
    n += 1;
    if (count > 0) {
        bufs[n] = .{ .phys = dma.phys + DATA_OFF, .len = @intCast(count * SECTOR), .writable = kind == T_IN };
        n += 1;
    }
    bufs[n] = .{ .phys = dma.phys + STATUS_OFF, .len = 1, .writable = true };
    n += 1;
    _ = queue.submit(bufs[0..n]) orelse return error.QueueFull;
    queue.kick();
    while (true) {
        if (queue.popUsed()) |_| break;
        const c = try irq.wait();
        _ = dev.ackInterrupt();
        irq.ack(c);
    }
    if (dma.virt[STATUS_OFF] != 0) return error.DeviceError;
}

fn readAt(offset: u64, out: []u8) !usize {
    if (offset >= capacity_bytes) return 0;
    const len = @min(out.len, capacity_bytes - offset);
    var done: usize = 0;
    while (done < len) {
        const pos = offset + done;
        const first_sector = pos / SECTOR;
        const skip: usize = @intCast(pos % SECTOR);
        const want = @min(len - done, CHUNK - skip);
        const sectors = (skip + want + SECTOR - 1) / SECTOR;
        try transfer(T_IN, first_sector, sectors);
        @memcpy(out[done .. done + want], dataBuf()[skip .. skip + want]);
        done += want;
    }
    return done;
}

fn writeAt(offset: u64, data: []const u8) !usize {
    if (read_only) return error.ReadOnly;
    if (offset >= capacity_bytes) return error.NoSpace;
    const len = @min(data.len, capacity_bytes - offset);
    var done: usize = 0;
    while (done < len) {
        const pos = offset + done;
        const first_sector = pos / SECTOR;
        const skip: usize = @intCast(pos % SECTOR);
        const want = @min(len - done, CHUNK - skip);
        const sectors = (skip + want + SECTOR - 1) / SECTOR;
        const tail = sectors * SECTOR - (skip + want);
        // Preserve partial sectors at either end.
        if (skip != 0 or tail != 0) {
            if (sectors == 1) {
                try transfer(T_IN, first_sector, 1);
            } else {
                var save: [SECTOR]u8 = undefined;
                if (skip != 0) {
                    try transfer(T_IN, first_sector, 1);
                    @memcpy(&save, dataBuf()[0..SECTOR]);
                }
                if (tail != 0) {
                    try transfer(T_IN, first_sector + sectors - 1, 1);
                    const last_off = (sectors - 1) * SECTOR;
                    @memcpy(dataBuf()[last_off .. last_off + SECTOR], dataBuf()[0..SECTOR]);
                }
                if (skip != 0) @memcpy(dataBuf()[0..SECTOR], &save);
            }
        }
        @memcpy(dataBuf()[skip .. skip + want], data[done .. done + want]);
        try transfer(T_OUT, first_sector, sectors);
        done += want;
    }
    return done;
}

const Handle = struct { offset: u64 };

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();
var handles: zen.server.HandleTable(Handle) = .{};
var srv: zen.server.Server = undefined;
var io_buf: []u8 = &.{};

fn serve(in: zen.server.Incoming) !void {
    const req = in.req;
    switch (req.op) {
        .open => {
            const id = try handles.insert(gpa, .{ .offset = 0 });
            return srv.replyValue(req.id, id);
        },
        .stat, .lstat => {
            var st = sc.Stat{ .mode = sc.S_IFBLK | 0o660, .size = @intCast(capacity_bytes), .blksize = 512 };
            st.blocks = @intCast(capacity_bytes / 512);
            return srv.replyStruct(req.id, &st);
        },
        .cancel => return,
        else => {},
    }
    const h = handles.get(req.handle) orelse return srv.replyError(req.id, .BADF);
    switch (req.op) {
        .close => _ = handles.remove(gpa, req.handle),
        .read => {
            const off = if (req.arg1 == 1) req.arg0 else h.offset;
            const want: usize = @intCast(@min(req.len, io_buf.len));
            const n = readAt(off, io_buf[0..want]) catch return srv.replyError(req.id, .IO);
            if (req.arg1 != 1) h.offset += n;
            try srv.reply(req.id, @intCast(n), io_buf[0..n]);
        },
        .write => {
            const off = if (req.arg1 == 1) req.arg0 else h.offset;
            const n = writeAt(off, in.payload) catch |err| return srv.replyError(req.id, zen.server.errnoFor(err));
            if (req.arg1 != 1) h.offset += n;
            try srv.replyValue(req.id, n);
        },
        .seek => {
            const off: i64 = @bitCast(req.arg0);
            const base: i64 = switch (req.arg1) {
                0 => 0,
                1 => @intCast(h.offset),
                2 => @intCast(capacity_bytes),
                else => return srv.replyError(req.id, .INVAL),
            };
            if (base + off < 0) return srv.replyError(req.id, .INVAL);
            h.offset = @intCast(base + off);
            try srv.replyValue(req.id, h.offset);
        },
        .fstat => {
            var st = sc.Stat{ .mode = sc.S_IFBLK | 0o660, .size = @intCast(capacity_bytes), .blksize = 512 };
            st.blocks = @intCast(capacity_bytes / 512);
            try srv.replyStruct(req.id, &st);
        },
        .fsync => {
            if (has_flush) transfer(T_FLUSH, 0, 0) catch return srv.replyError(req.id, .IO);
            try srv.replyOk(req.id);
        },
        .ioctl => {
            const BLKGETSIZE64 = 0x80081272;
            const BLKSSZGET = 0x1268;
            switch (@as(u32, @truncate(req.arg0))) {
                BLKGETSIZE64 => try srv.replyStruct(req.id, &capacity_bytes),
                BLKSSZGET => {
                    const v: i32 = 512;
                    try srv.replyStruct(req.id, &v);
                },
                else => try srv.replyError(req.id, .NOTTY),
            }
        },
        .fevent => try srv.replyValue(req.id, sc.POLLIN | sc.POLLOUT),
        .fpath => try srv.reply(req.id, 0, ""),
        else => try srv.replyError(req.id, .NOSYS),
    }
}

pub fn main() !void {
    zen.sys.setName("virtio-blkd");
    const args = try std.process.argsAlloc(gpa);
    const loc = virtio.parseArgs(args) orelse {
        zen.sys.logf("virtio-blkd: usage: virtio-blkd <phys> <irq> [scheme]", .{});
        return error.InvalidArgument;
    };
    const scheme_name: []const u8 = if (args.len > 3) args[3] else "disk";

    dev = try virtio.Device.open(loc.phys, .block);
    const features = try dev.init((@as(u64, 1) << F_RO) | (@as(u64, 1) << F_FLUSH));
    read_only = features & (@as(u64, 1) << F_RO) != 0;
    has_flush = features & (@as(u64, 1) << F_FLUSH) != 0;
    capacity_bytes = dev.config64(0) * SECTOR;
    queue = try virtio.Queue.init(dev, 0, 64);
    dma = try zen.sys.physalloc(DATA_OFF + CHUNK);
    irq = try virtio.Irq.open(loc.irq);
    dev.driverOk();
    io_buf = try gpa.alloc(u8, 1024 * 1024);

    srv = try zen.server.Server.register(gpa, scheme_name);
    zen.sys.logf("virtio-blkd: {s}: {d} MiB{s}", .{ scheme_name, capacity_bytes >> 20, if (read_only) " (read-only)" else "" });
    while (true) {
        const in = srv.receive() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        serve(in) catch |err| {
            srv.replyError(in.req.id, zen.server.errnoFor(err)) catch {};
        };
    }
}
