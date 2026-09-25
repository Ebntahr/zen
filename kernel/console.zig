//! Kernel console: NS16550A UART (QEMU virt) + kernel log ring buffer.
const std = @import("std");
const riscv = @import("riscv.zig");

var uart_base: u64 = riscv.PHYSMAP_BASE + 0x1000_0000;

const RBR = 0; // receive buffer
const THR = 0; // transmit holding
const IER = 1; // interrupt enable
const FCR = 2; // FIFO control
const LCR = 3; // line control
const LSR = 5; // line status

inline fn reg(off: u64) *volatile u8 {
    return @ptrFromInt(uart_base + off);
}

pub fn init(base_pa: u64) void {
    uart_base = riscv.p2v(base_pa);
    reg(IER).* = 0x00;
    reg(LCR).* = 0x03; // 8N1
    reg(FCR).* = 0x07; // enable + clear FIFOs
}

/// Enable RX interrupts (called once the PLIC is ready).
pub fn enableRxInterrupt() void {
    reg(IER).* = 0x01;
}

pub fn putcRaw(c: u8) void {
    var spins: u32 = 0;
    while ((reg(LSR).* & 0x20) == 0) : (spins += 1) {
        if (spins > 1_000_000) break;
    }
    reg(THR).* = c;
}

pub fn getcRaw() ?u8 {
    if ((reg(LSR).* & 0x01) == 0) return null;
    return reg(RBR).*;
}

// ---------------------------------------------------------------------------
// Kernel log ring buffer (exposed as sys:log / dmesg)
// ---------------------------------------------------------------------------

pub const LOG_SIZE = 64 * 1024;
pub var log_buf: [LOG_SIZE]u8 = undefined;
pub var log_head: usize = 0; // total bytes ever written
/// When true, kernel messages are mirrored to the UART.
pub var echo_uart: bool = true;

fn logByte(c: u8) void {
    log_buf[log_head % LOG_SIZE] = c;
    log_head += 1;
}

pub fn write(bytes: []const u8) void {
    for (bytes) |c| {
        logByte(c);
        if (echo_uart) {
            if (c == '\n') putcRaw('\r');
            putcRaw(c);
        }
    }
}

/// Write straight to the UART without logging (used by debug: scheme).
pub fn writeUart(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n') putcRaw('\r');
        putcRaw(c);
    }
}

/// Copy the log (oldest first) into `out`, returns the number of bytes.
pub fn readLog(out: []u8) usize {
    const avail = @min(log_head, LOG_SIZE);
    const start = log_head - avail;
    const n = @min(avail, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = log_buf[(start + i) % LOG_SIZE];
    return n;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        break :blk buf[0..];
    };
    write(s);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    const time = @import("time.zig");
    const ns = time.monotonicNs();
    print("[{d:>5}.{d:0>6}] ", .{ ns / 1_000_000_000, (ns / 1000) % 1_000_000 });
    print(fmt ++ "\n", args);
}
