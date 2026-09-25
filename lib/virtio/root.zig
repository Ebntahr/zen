//! Virtio (MMIO transport, version 2) for user-space drivers.
//!
//! Drivers map the device registers with `physmap`, allocate queues in DMA
//! memory with `physalloc`, and wait for interrupts on an `irq:N` handle.

const std = @import("std");
const zen = @import("zen");

pub const MAGIC: u32 = 0x74726976; // "virt"

pub const DeviceId = enum(u32) {
    net = 1,
    block = 2,
    console = 3,
    rng = 4,
    gpu = 16,
    input = 18,
    _,
};

// Register offsets
const MAGIC_VALUE = 0x000;
const VERSION = 0x004;
const DEVICE_ID = 0x008;
const DEVICE_FEATURES = 0x010;
const DEVICE_FEATURES_SEL = 0x014;
const DRIVER_FEATURES = 0x020;
const DRIVER_FEATURES_SEL = 0x024;
const QUEUE_SEL = 0x030;
const QUEUE_NUM_MAX = 0x034;
const QUEUE_NUM = 0x038;
const QUEUE_READY = 0x044;
const QUEUE_NOTIFY = 0x050;
const INTERRUPT_STATUS = 0x060;
const INTERRUPT_ACK = 0x064;
const STATUS = 0x070;
const QUEUE_DESC_LOW = 0x080;
const QUEUE_DESC_HIGH = 0x084;
const QUEUE_DRIVER_LOW = 0x090;
const QUEUE_DRIVER_HIGH = 0x094;
const QUEUE_DEVICE_LOW = 0x0a0;
const QUEUE_DEVICE_HIGH = 0x0a4;
const CONFIG_GENERATION = 0x0fc;
pub const CONFIG = 0x100;

// Status bits
pub const S_ACKNOWLEDGE: u32 = 1;
pub const S_DRIVER: u32 = 2;
pub const S_DRIVER_OK: u32 = 4;
pub const S_FEATURES_OK: u32 = 8;
pub const S_FAILED: u32 = 128;

pub const F_VERSION_1: u6 = 32;

pub const Error = error{ NotVirtio, UnsupportedVersion, WrongDevice, FeaturesRejected, QueueUnavailable, Timeout } || zen.sys.Error;

pub const Device = struct {
    base: [*]volatile u8,
    id: DeviceId,

    pub fn read32(self: Device, off: usize) u32 {
        const p: *volatile u32 = @ptrCast(@alignCast(self.base + off));
        return p.*;
    }

    pub fn write32(self: Device, off: usize, v: u32) void {
        const p: *volatile u32 = @ptrCast(@alignCast(self.base + off));
        p.* = v;
    }

    pub fn config8(self: Device, off: usize) u8 {
        return (self.base + CONFIG + off)[0];
    }

    pub fn setConfig8(self: Device, off: usize, v: u8) void {
        (self.base + CONFIG + off)[0] = v;
    }

    pub fn config32(self: Device, off: usize) u32 {
        return self.read32(CONFIG + off);
    }

    pub fn config64(self: Device, off: usize) u64 {
        while (true) {
            const gen = self.read32(CONFIG_GENERATION);
            const lo: u64 = self.read32(CONFIG + off);
            const hi: u64 = self.read32(CONFIG + off + 4);
            if (gen == self.read32(CONFIG_GENERATION)) return lo | (hi << 32);
        }
    }

    /// Map the device and validate its identity.
    pub fn open(phys: u64, expected: DeviceId) Error!Device {
        const base = try zen.sys.physmap(phys, 0x1000);
        const dev = Device{ .base = base, .id = @enumFromInt(0) };
        if (dev.read32(MAGIC_VALUE) != MAGIC) return error.NotVirtio;
        if (dev.read32(VERSION) != 2) return error.UnsupportedVersion;
        const id: DeviceId = @enumFromInt(dev.read32(DEVICE_ID));
        if (id != expected) return error.WrongDevice;
        return .{ .base = base, .id = id };
    }

    /// Reset and negotiate features. `wanted` are device-specific feature
    /// bits (0..63); VIRTIO_F_VERSION_1 is always requested.
    pub fn init(self: Device, wanted: u64) Error!u64 {
        self.write32(STATUS, 0);
        self.write32(STATUS, S_ACKNOWLEDGE);
        self.write32(STATUS, S_ACKNOWLEDGE | S_DRIVER);
        self.write32(DEVICE_FEATURES_SEL, 0);
        const lo: u64 = self.read32(DEVICE_FEATURES);
        self.write32(DEVICE_FEATURES_SEL, 1);
        const hi: u64 = self.read32(DEVICE_FEATURES);
        const offered = lo | (hi << 32);
        const accept = offered & (wanted | (@as(u64, 1) << F_VERSION_1));
        self.write32(DRIVER_FEATURES_SEL, 0);
        self.write32(DRIVER_FEATURES, @truncate(accept));
        self.write32(DRIVER_FEATURES_SEL, 1);
        self.write32(DRIVER_FEATURES, @truncate(accept >> 32));
        self.write32(STATUS, S_ACKNOWLEDGE | S_DRIVER | S_FEATURES_OK);
        if (self.read32(STATUS) & S_FEATURES_OK == 0) {
            self.write32(STATUS, S_FAILED);
            return error.FeaturesRejected;
        }
        return accept;
    }

    pub fn driverOk(self: Device) void {
        self.write32(STATUS, S_ACKNOWLEDGE | S_DRIVER | S_FEATURES_OK | S_DRIVER_OK);
    }

    /// Read and acknowledge the interrupt status.
    pub fn ackInterrupt(self: Device) u32 {
        const st = self.read32(INTERRUPT_STATUS);
        if (st != 0) self.write32(INTERRUPT_ACK, st);
        return st;
    }

    pub fn notify(self: Device, queue: u16) void {
        self.write32(QUEUE_NOTIFY, queue);
    }
};

pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const DESC_F_NEXT: u16 = 1;
pub const DESC_F_WRITE: u16 = 2;

pub const UsedElem = extern struct { id: u32, len: u32 };

/// A split virtqueue living in one DMA allocation.
pub const Queue = struct {
    dev: Device,
    index: u16,
    size: u16,
    desc: [*]volatile Desc,
    avail_flags: *volatile u16,
    avail_idx: *volatile u16,
    avail_ring: [*]volatile u16,
    used_idx: *volatile u16,
    used_ring: [*]volatile UsedElem,
    last_used: u16 = 0,
    free_head: u16 = 0,
    num_free: u16,
    next_free: [256]u16 = undefined,

    pub fn init(dev: Device, index: u16, want_size: u16) Error!Queue {
        dev.write32(QUEUE_SEL, index);
        if (dev.read32(QUEUE_READY) != 0) return error.QueueUnavailable;
        const max = dev.read32(QUEUE_NUM_MAX);
        if (max == 0) return error.QueueUnavailable;
        const size: u16 = @intCast(@min(@min(max, want_size), 256));

        const desc_bytes = @as(usize, size) * 16;
        const avail_bytes = 6 + 2 * @as(usize, size);
        const used_off = std.mem.alignForward(usize, desc_bytes + avail_bytes, 4);
        const used_bytes = 6 + 8 * @as(usize, size);
        const total = std.mem.alignForward(usize, used_off + used_bytes, 4096);
        const mem = try zen.sys.physalloc(total);

        dev.write32(QUEUE_NUM, size);
        const desc_pa = mem.phys;
        const avail_pa = mem.phys + desc_bytes;
        const used_pa = mem.phys + used_off;
        dev.write32(QUEUE_DESC_LOW, @truncate(desc_pa));
        dev.write32(QUEUE_DESC_HIGH, @truncate(desc_pa >> 32));
        dev.write32(QUEUE_DRIVER_LOW, @truncate(avail_pa));
        dev.write32(QUEUE_DRIVER_HIGH, @truncate(avail_pa >> 32));
        dev.write32(QUEUE_DEVICE_LOW, @truncate(used_pa));
        dev.write32(QUEUE_DEVICE_HIGH, @truncate(used_pa >> 32));
        dev.write32(QUEUE_READY, 1);

        const base = mem.virt;
        var q = Queue{
            .dev = dev,
            .index = index,
            .size = size,
            .desc = @ptrCast(@alignCast(base)),
            .avail_flags = @ptrCast(@alignCast(base + desc_bytes)),
            .avail_idx = @ptrCast(@alignCast(base + desc_bytes + 2)),
            .avail_ring = @ptrCast(@alignCast(base + desc_bytes + 4)),
            .used_idx = @ptrCast(@alignCast(base + used_off + 2)),
            .used_ring = @ptrCast(@alignCast(base + used_off + 4)),
            .num_free = size,
        };
        var i: u16 = 0;
        while (i < size) : (i += 1) q.next_free[i] = i + 1;
        return q;
    }

    pub const Buf = struct {
        phys: u64,
        len: u32,
        /// Device writes into this buffer.
        writable: bool,
    };

    /// Queue a descriptor chain. Returns the head index (the token that
    /// comes back in the used ring) or null if the queue is full.
    pub fn submit(self: *Queue, bufs: []const Buf) ?u16 {
        if (bufs.len == 0 or bufs.len > self.num_free) return null;
        const head = self.free_head;
        var idx = head;
        for (bufs, 0..) |b, i| {
            const d = &self.desc[idx];
            d.addr = b.phys;
            d.len = b.len;
            var flags: u16 = if (b.writable) DESC_F_WRITE else 0;
            const nxt = self.next_free[idx];
            if (i + 1 < bufs.len) {
                flags |= DESC_F_NEXT;
                d.next = nxt;
            } else {
                d.next = 0;
            }
            d.flags = flags;
            idx = nxt;
        }
        self.free_head = idx;
        self.num_free -= @intCast(bufs.len);
        const slot = self.avail_idx.* % self.size;
        self.avail_ring[slot] = head;
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
        self.avail_idx.* +%= 1;
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
        return head;
    }

    pub fn kick(self: *Queue) void {
        self.dev.notify(self.index);
    }

    /// Pop one completed chain; frees its descriptors.
    pub fn popUsed(self: *Queue) ?UsedElem {
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
        if (self.last_used == self.used_idx.*) return null;
        const e = self.used_ring[self.last_used % self.size];
        self.last_used +%= 1;
        // Return the chain to the free list.
        var idx: u16 = @intCast(e.id);
        while (true) {
            const d = self.desc[idx];
            self.num_free += 1;
            if (d.flags & DESC_F_NEXT == 0) {
                self.next_free[idx] = self.free_head;
                break;
            }
            self.next_free[idx] = d.next;
            idx = d.next;
        }
        self.free_head = @intCast(e.id);
        return .{ .id = e.id, .len = e.len };
    }
};

/// An `irq:N` handle: read blocks until the interrupt fires, write acks it.
pub const Irq = struct {
    fd: std.posix.fd_t,

    pub fn open(n: u32) !Irq {
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "irq:{d}", .{n});
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDWR }, 0);
        return .{ .fd = fd };
    }

    /// Block until at least one interrupt; returns the count.
    pub fn wait(self: Irq) !u64 {
        var count: u64 = 0;
        _ = try std.posix.read(self.fd, std.mem.asBytes(&count));
        return count;
    }

    /// Acknowledge (complete) the interrupt so it can fire again.
    pub fn ack(self: Irq, count: u64) void {
        _ = std.posix.write(self.fd, std.mem.asBytes(&count)) catch {};
    }
};

/// Parse driver arguments "0x10001000" "1" → (phys, irq).
pub fn parseArgs(args: []const [:0]const u8) ?struct { phys: u64, irq: u32 } {
    if (args.len < 3) return null;
    const phys = std.fmt.parseInt(u64, args[1], 0) catch return null;
    const irq = std.fmt.parseInt(u32, args[2], 0) catch return null;
    return .{ .phys = phys, .irq = irq };
}
