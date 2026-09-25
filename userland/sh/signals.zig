//! Signal names, descriptions and the async-signal-safe pending flags used by
//! traps and interactive interrupt handling.
const std = @import("std");
const sys = @import("sys.zig");

pub const NSIG = 65;

pub const names = [_][]const u8{
    "EXIT", "HUP",  "INT",  "QUIT", "ILL",    "TRAP", "ABRT", "BUS",  "FPE",   "KILL", "USR1",
    "SEGV", "USR2", "PIPE", "ALRM", "TERM",   "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN",
    "TTOU", "URG",  "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO",   "PWR",   "SYS",
};

pub fn name(sig: u32) []const u8 {
    if (sig < names.len) return names[sig];
    return "?";
}

/// Parse a signal specification: number, NAME, SIGNAME (case-insensitive).
pub fn parse(spec: []const u8) ?u32 {
    if (spec.len == 0) return null;
    if (std.fmt.parseInt(u32, spec, 10)) |n| {
        if (n < NSIG) return n;
        return null;
    } else |_| {}
    var buf: [16]u8 = undefined;
    if (spec.len > buf.len) return null;
    const up = std.ascii.upperString(&buf, spec);
    const s = if (std.mem.startsWith(u8, up, "SIG")) up[3..] else up;
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @intCast(i);
    if (std.mem.eql(u8, s, "IOT")) return 6;
    if (std.mem.eql(u8, s, "CLD")) return 17;
    if (std.mem.eql(u8, s, "POLL")) return 29;
    if (std.mem.eql(u8, s, "ERR")) return ERR_TRAP;
    if (std.mem.eql(u8, s, "DEBUG")) return null;
    return null;
}

/// Pseudo-signal number used for the ERR trap.
pub const ERR_TRAP: u32 = 64;

pub fn describe(sig: u32) []const u8 {
    return switch (sig) {
        1 => "Hangup",
        2 => "Interrupt",
        3 => "Quit",
        4 => "Illegal instruction",
        5 => "Trace/breakpoint trap",
        6 => "Aborted",
        7 => "Bus error",
        8 => "Floating point exception",
        9 => "Killed",
        10 => "User defined signal 1",
        11 => "Segmentation fault",
        12 => "User defined signal 2",
        13 => "Broken pipe",
        14 => "Alarm clock",
        15 => "Terminated",
        16 => "Stack fault",
        17 => "Child exited",
        18 => "Continued",
        19 => "Stopped (signal)",
        20 => "Stopped",
        21 => "Stopped (tty input)",
        22 => "Stopped (tty output)",
        23 => "Urgent I/O condition",
        24 => "CPU time limit exceeded",
        25 => "File size limit exceeded",
        26 => "Virtual timer expired",
        27 => "Profiling timer expired",
        28 => "Window changed",
        29 => "I/O possible",
        30 => "Power failure",
        31 => "Bad system call",
        else => "Unknown signal",
    };
}

// ---------------------------------------------------------------------------
// pending flags (set from the signal handler)
// ---------------------------------------------------------------------------

pub var pending: [NSIG]std.atomic.Value(bool) = init: {
    var a: [NSIG]std.atomic.Value(bool) = undefined;
    for (&a) |*v| v.* = std.atomic.Value(bool).init(false);
    break :init a;
};
pub var any_pending = std.atomic.Value(bool).init(false);

fn handler(sig: i32) callconv(.c) void {
    if (sig > 0 and sig < NSIG) {
        pending[@intCast(sig)].store(true, .seq_cst);
        any_pending.store(true, .seq_cst);
    }
}

pub fn installHook() void {
    sys.signal_hook = &handler;
}

pub fn take(sig: u32) bool {
    return pending[sig].swap(false, .seq_cst);
}

pub fn isPending(sig: u32) bool {
    return pending[sig].load(.seq_cst);
}

pub fn clearAll() void {
    for (&pending) |*p| p.store(false, .seq_cst);
    any_pending.store(false, .seq_cst);
}
