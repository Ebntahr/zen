//! RISC-V 64 architecture helpers: CSRs, SBI calls, barriers.

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_SHIFT: u6 = 12;

/// Virtual address where all physical memory is mapped (Sv39 upper half).
pub const PHYSMAP_BASE: u64 = 0xFFFF_FFC0_0000_0000;
/// Size of the physmap window (64 GiB, gigapages).
pub const PHYSMAP_SIZE: u64 = 64 << 30;
/// Kernel image virtual/physical base.
pub const KERNEL_VMA: u64 = 0xFFFF_FFFF_8020_0000;
pub const KERNEL_PHYS: u64 = 0x8020_0000;
pub const KERNEL_OFFSET: u64 = KERNEL_VMA - KERNEL_PHYS;

pub inline fn p2v(pa: u64) u64 {
    return pa + PHYSMAP_BASE;
}

pub inline fn v2p(va: u64) u64 {
    if (va >= KERNEL_VMA - 0x20_0000) return va - KERNEL_OFFSET;
    return va - PHYSMAP_BASE;
}

pub inline fn ptr(comptime T: type, pa: u64) *T {
    return @ptrFromInt(p2v(pa));
}

// ---------------------------------------------------------------------------
// CSR access
// ---------------------------------------------------------------------------

pub inline fn csrRead(comptime name: []const u8) u64 {
    return asm volatile ("csrr %[r], " ++ name
        : [r] "=r" (-> u64),
    );
}

pub inline fn csrWrite(comptime name: []const u8, v: u64) void {
    asm volatile ("csrw " ++ name ++ ", %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn csrSet(comptime name: []const u8, v: u64) void {
    asm volatile ("csrs " ++ name ++ ", %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn csrClear(comptime name: []const u8, v: u64) void {
    asm volatile ("csrc " ++ name ++ ", %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn sfenceVma() void {
    asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
}

pub inline fn sfenceVmaAddr(va: u64) void {
    asm volatile ("sfence.vma %[va], zero"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}

pub inline fn fence() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

pub inline fn fenceI() void {
    asm volatile ("fence.i" ::: .{ .memory = true });
}

pub inline fn rdtime() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn wfi() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

// sstatus bits
pub const SSTATUS_SIE: u64 = 1 << 1;
pub const SSTATUS_SPIE: u64 = 1 << 5;
pub const SSTATUS_SPP: u64 = 1 << 8;
pub const SSTATUS_FS_MASK: u64 = 3 << 13;
pub const SSTATUS_FS_OFF: u64 = 0 << 13;
pub const SSTATUS_FS_INITIAL: u64 = 1 << 13;
pub const SSTATUS_FS_CLEAN: u64 = 2 << 13;
pub const SSTATUS_FS_DIRTY: u64 = 3 << 13;
pub const SSTATUS_SUM: u64 = 1 << 18;
pub const SSTATUS_MXR: u64 = 1 << 19;

// sie bits
pub const SIE_SSIE: u64 = 1 << 1;
pub const SIE_STIE: u64 = 1 << 5;
pub const SIE_SEIE: u64 = 1 << 9;

pub inline fn interruptsOff() void {
    csrClear("sstatus", SSTATUS_SIE);
}

pub inline fn interruptsOn() void {
    csrSet("sstatus", SSTATUS_SIE);
}

// ---------------------------------------------------------------------------
// SBI (Supervisor Binary Interface)
// ---------------------------------------------------------------------------

pub const SbiRet = struct { err: i64, val: u64 };

pub fn sbiCall(ext: u64, fid: u64, a0: u64, a1: u64, a2: u64) SbiRet {
    var err: i64 = undefined;
    var val: u64 = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
          [val] "={x11}" (val),
        : [ext] "{x17}" (ext),
          [fid] "{x16}" (fid),
          [a0] "{x10}" (a0),
          [a1] "{x11}" (a1),
          [a2] "{x12}" (a2),
        : .{ .memory = true });
    return .{ .err = err, .val = val };
}

pub const SBI_EXT_TIME: u64 = 0x54494D45;
pub const SBI_EXT_SRST: u64 = 0x53525354;
pub const SBI_EXT_BASE: u64 = 0x10;

pub fn sbiSetTimer(stime: u64) void {
    _ = sbiCall(SBI_EXT_TIME, 0, stime, 0, 0);
}

pub fn sbiLegacyPutchar(c: u8) void {
    _ = sbiCall(0x01, 0, c, 0, 0);
}

pub fn sbiShutdown() noreturn {
    _ = sbiCall(SBI_EXT_SRST, 0, 0, 0, 0); // shutdown, no reason
    _ = sbiCall(0x08, 0, 0, 0, 0); // legacy shutdown
    while (true) wfi();
}

pub fn sbiReboot() noreturn {
    _ = sbiCall(SBI_EXT_SRST, 0, 1, 0, 0); // cold reboot
    while (true) wfi();
}
