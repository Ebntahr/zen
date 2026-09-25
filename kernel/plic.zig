//! Platform-Level Interrupt Controller (SiFive PLIC, as on QEMU virt).
//! Only hart 0 / S-mode context (context 1) is used.
const riscv = @import("riscv.zig");

var base: u64 = 0;

const PRIORITY = 0x0000;
const PENDING = 0x1000;
const ENABLE_S_HART0 = 0x2080; // context 1 enable bits
const THRESHOLD_S_HART0 = 0x201000;
const CLAIM_S_HART0 = 0x201004;

pub const MAX_IRQ = 128;

fn reg(off: u64) *volatile u32 {
    return @ptrFromInt(base + off);
}

pub fn init(pa: u64) void {
    base = riscv.p2v(pa);
    reg(THRESHOLD_S_HART0).* = 0;
    var i: u64 = 0;
    while (i < MAX_IRQ / 32) : (i += 1) reg(ENABLE_S_HART0 + i * 4).* = 0;
}

pub fn enable(irq: u32) void {
    if (irq == 0 or irq >= MAX_IRQ) return;
    reg(PRIORITY + @as(u64, irq) * 4).* = 1;
    const word = ENABLE_S_HART0 + @as(u64, irq / 32) * 4;
    reg(word).* |= @as(u32, 1) << @intCast(irq % 32);
}

pub fn disable(irq: u32) void {
    if (irq == 0 or irq >= MAX_IRQ) return;
    const word = ENABLE_S_HART0 + @as(u64, irq / 32) * 4;
    reg(word).* &= ~(@as(u32, 1) << @intCast(irq % 32));
}

/// Claim the highest-priority pending interrupt (0 = none).
pub fn claim() u32 {
    return reg(CLAIM_S_HART0).*;
}

/// Signal completion; the source may interrupt again afterwards.
pub fn complete(irq: u32) void {
    reg(CLAIM_S_HART0).* = irq;
}
