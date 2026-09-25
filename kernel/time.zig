//! Time keeping: the RISC-V `time` CSR (monotonic), the Goldfish RTC
//! (wall clock) and the SBI timer used for preemption and sleeps.
const std = @import("std");
const riscv = @import("riscv.zig");

var timebase_hz: u64 = 10_000_000;
var boot_realtime_ns: u64 = 0;
var boot_ticks: u64 = 0;

pub const TICK_NS: u64 = 10 * std.time.ns_per_ms; // 100 Hz scheduler tick

pub fn init(timebase: u64, rtc_pa: u64) void {
    timebase_hz = if (timebase == 0) 10_000_000 else timebase;
    boot_ticks = riscv.rdtime();
    if (rtc_pa != 0) {
        // Goldfish RTC: reading TIME_LOW latches TIME_HIGH.
        const base = riscv.p2v(rtc_pa);
        const lo: u64 = @as(*volatile u32, @ptrFromInt(base + 0x00)).*;
        const hi: u64 = @as(*volatile u32, @ptrFromInt(base + 0x04)).*;
        boot_realtime_ns = (hi << 32) | lo;
    }
}

pub fn ticksToNs(t: u64) u64 {
    return @intCast(@as(u128, t) * std.time.ns_per_s / timebase_hz);
}

pub fn nsToTicks(ns: u64) u64 {
    return @intCast(@as(u128, ns) * timebase_hz / std.time.ns_per_s);
}

/// Nanoseconds since boot.
pub fn monotonicNs() u64 {
    return ticksToNs(riscv.rdtime() -% boot_ticks);
}

/// Nanoseconds since the Unix epoch.
pub fn realtimeNs() u64 {
    return boot_realtime_ns + monotonicNs();
}

/// Adjust the wall clock (clock_settime).
pub fn setRealtimeNs(ns: u64) void {
    boot_realtime_ns = ns -| monotonicNs();
}

/// Program the next timer interrupt `ns` from now.
pub fn armIn(ns: u64) void {
    riscv.sbiSetTimer(riscv.rdtime() + nsToTicks(ns));
}

/// Program the timer interrupt at an absolute monotonic time.
pub fn armAt(deadline_ns: u64) void {
    riscv.sbiSetTimer(boot_ticks + nsToTicks(deadline_ns));
}

pub fn disarm() void {
    riscv.sbiSetTimer(std.math.maxInt(u64));
}
