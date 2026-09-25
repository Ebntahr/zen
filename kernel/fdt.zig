//! Minimal flattened device tree parser (enough for QEMU `virt`).
const std = @import("std");
const riscv = @import("riscv.zig");

pub const Device = struct {
    compat: [48]u8 = [_]u8{0} ** 48,
    compat_len: usize = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    base: u64 = 0,
    size: u64 = 0,
    irq: u32 = 0,

    pub fn compatible(self: *const Device) []const u8 {
        return self.compat[0..self.compat_len];
    }
    pub fn nodeName(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Info = struct {
    mem_base: u64 = 0x8000_0000,
    mem_size: u64 = 128 << 20,
    initrd_start: u64 = 0,
    initrd_end: u64 = 0,
    timebase: u64 = 10_000_000,
    plic_base: u64 = 0x0c00_0000,
    uart_base: u64 = 0x1000_0000,
    uart_irq: u32 = 10,
    rtc_base: u64 = 0,
    bootargs: [256]u8 = [_]u8{0} ** 256,
    bootargs_len: usize = 0,
    rng_seed: [64]u8 = [_]u8{0} ** 64,
    rng_seed_len: usize = 0,
    devices: [64]Device = undefined,
    device_count: usize = 0,
    dtb_pa: u64 = 0,
    dtb_size: u64 = 0,
};

pub var info: Info = .{};

const FDT_BEGIN_NODE = 1;
const FDT_END_NODE = 2;
const FDT_PROP = 3;
const FDT_NOP = 4;
const FDT_END = 9;

fn be32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

fn be64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .big);
}

fn readCells(p: [*]const u8, len: u32) u64 {
    if (len >= 8) return be64(p);
    if (len >= 4) return be32(p);
    return 0;
}

const Node = struct {
    name: []const u8 = "",
    compat: []const u8 = "",
    device_type: []const u8 = "",
    reg_base: u64 = 0,
    reg_size: u64 = 0,
    has_reg: bool = false,
    irq: u32 = 0,
};

pub fn parse(dtb_pa: u64) void {
    const base: [*]const u8 = @ptrFromInt(riscv.p2v(dtb_pa));
    if (be32(base) != 0xd00dfeed) return;
    info.dtb_pa = dtb_pa;
    info.dtb_size = be32(base + 4);
    const off_struct = be32(base + 8);
    const off_strings = be32(base + 12);
    var p: [*]const u8 = base + off_struct;
    const strings: [*]const u8 = base + off_strings;

    var stack: [16]Node = undefined;
    var depth: usize = 0;

    while (true) {
        const tok = be32(p);
        p += 4;
        switch (tok) {
            FDT_BEGIN_NODE => {
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(p)), 0);
                p += (name.len + 1 + 3) & ~@as(usize, 3);
                if (depth < stack.len) stack[depth] = .{ .name = name };
                depth += 1;
            },
            FDT_END_NODE => {
                if (depth == 0) break;
                depth -= 1;
                if (depth < stack.len) finishNode(&stack[depth], depth);
            },
            FDT_PROP => {
                const len = be32(p);
                const nameoff = be32(p + 4);
                p += 8;
                const val = p;
                p += (len + 3) & ~@as(u32, 3);
                if (depth == 0 or depth > stack.len) continue;
                const pname = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(strings + nameoff)), 0);
                const node = &stack[depth - 1];
                if (std.mem.eql(u8, pname, "compatible")) {
                    node.compat = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(val)), 0);
                } else if (std.mem.eql(u8, pname, "device_type")) {
                    node.device_type = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(val)), 0);
                } else if (std.mem.eql(u8, pname, "reg") and len >= 16) {
                    node.reg_base = be64(val);
                    node.reg_size = be64(val + 8);
                    node.has_reg = true;
                } else if (std.mem.eql(u8, pname, "interrupts") and len >= 4) {
                    node.irq = be32(val);
                } else if (std.mem.eql(u8, pname, "linux,initrd-start")) {
                    info.initrd_start = readCells(val, len);
                } else if (std.mem.eql(u8, pname, "linux,initrd-end")) {
                    info.initrd_end = readCells(val, len);
                } else if (std.mem.eql(u8, pname, "timebase-frequency")) {
                    info.timebase = readCells(val, len);
                } else if (std.mem.eql(u8, pname, "bootargs")) {
                    const n = @min(len, info.bootargs.len);
                    @memcpy(info.bootargs[0..n], val[0..n]);
                    info.bootargs_len = std.mem.indexOfScalar(u8, info.bootargs[0..n], 0) orelse n;
                } else if (std.mem.eql(u8, pname, "rng-seed")) {
                    const n = @min(len, info.rng_seed.len);
                    @memcpy(info.rng_seed[0..n], val[0..n]);
                    info.rng_seed_len = n;
                }
            },
            FDT_NOP => {},
            else => break,
        }
    }
}

fn finishNode(node: *Node, depth: usize) void {
    _ = depth;
    const c = node.compat;
    if (std.mem.eql(u8, node.device_type, "memory") and node.has_reg) {
        info.mem_base = node.reg_base;
        info.mem_size = node.reg_size;
        return;
    }
    if (!node.has_reg) return;
    if (std.mem.startsWith(u8, c, "sifive,plic") or std.mem.startsWith(u8, c, "riscv,plic")) {
        info.plic_base = node.reg_base;
    } else if (std.mem.eql(u8, c, "ns16550a")) {
        info.uart_base = node.reg_base;
        info.uart_irq = node.irq;
    } else if (std.mem.eql(u8, c, "google,goldfish-rtc")) {
        info.rtc_base = node.reg_base;
    }
    if (c.len == 0) return;
    if (info.device_count >= info.devices.len) return;
    var d = Device{ .base = node.reg_base, .size = node.reg_size, .irq = node.irq };
    d.compat_len = @min(c.len, d.compat.len);
    @memcpy(d.compat[0..d.compat_len], c[0..d.compat_len]);
    d.name_len = @min(node.name.len, d.name.len);
    @memcpy(d.name[0..d.name_len], node.name[0..d.name_len]);
    info.devices[info.device_count] = d;
    info.device_count += 1;
}
