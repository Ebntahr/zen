//! C/C++ compiler driver for Zen OS (multi-call: cc, c++, gcc, g++, clang,
//! clang++, ar, ranlib, ld, zig-toolchain).
//!
//! Zen ships the Zig toolchain (which contains clang, lld and musl/libc++
//! sources) under /usr/lib/zig. Because Zen implements the Linux ABI,
//! programs are built for `<cpu>-linux-musl` (riscv64 on Zen, the host's
//! CPU when Zen runs hosted) and run natively:
//!
//!     cc hello.c -o hello && ./hello
//!     c++ -O2 -std=c++20 app.cpp -o app

const std = @import("std");
const builtin = @import("builtin");

const zig_exe = "/usr/lib/zig/zig";
const target = @tagName(builtin.cpu.arch) ++ "-linux-musl";

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const name = std.fs.path.basename(argv[0]);

    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, zig_exe);

    const is_cxx = std.mem.eql(u8, name, "c++") or std.mem.eql(u8, name, "g++") or std.mem.eql(u8, name, "clang++") or std.mem.eql(u8, name, "cpp");
    const is_cc = std.mem.eql(u8, name, "cc") or std.mem.eql(u8, name, "gcc") or std.mem.eql(u8, name, "clang");
    if (is_cxx or is_cc) {
        try args.append(a, if (is_cxx) "c++" else "cc");
        var has_target = false;
        for (argv[1..]) |x| {
            if (std.mem.startsWith(u8, x, "-target") or std.mem.startsWith(u8, x, "--target")) has_target = true;
        }
        if (!has_target) {
            try args.append(a, "-target");
            try args.append(a, target);
        }
    } else if (std.mem.eql(u8, name, "ar")) {
        try args.append(a, "ar");
    } else if (std.mem.eql(u8, name, "ranlib")) {
        try args.append(a, "ranlib");
    } else if (std.mem.eql(u8, name, "ld") or std.mem.eql(u8, name, "ld.lld")) {
        try args.append(a, "ld.lld");
    } else if (std.mem.eql(u8, name, "objcopy")) {
        try args.append(a, "objcopy");
    }
    try args.appendSlice(a, argv[1..]);

    var env = try std.process.getEnvMap(a);
    if (env.get("ZIG_GLOBAL_CACHE_DIR") == null) {
        const home = env.get("HOME") orelse "/tmp";
        try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fmt.allocPrint(a, "{s}/.cache/zig", .{home}));
    }
    if (env.get("ZIG_LOCAL_CACHE_DIR") == null) {
        const home = env.get("HOME") orelse "/tmp";
        try env.put("ZIG_LOCAL_CACHE_DIR", try std.fmt.allocPrint(a, "{s}/.cache/zig", .{home}));
    }

    std.fs.cwd().access(zig_exe, .{}) catch {
        std.debug.print("{s}: the C/C++ toolchain is not installed (expected {s}).\n" ++
            "Rebuild the Zen image with -Dtoolchain=<path to riscv64 zig>.\n", .{ name, zig_exe });
        std.process.exit(127);
    };
    const err = std.process.execve(a, args.items, &env);
    std.debug.print("{s}: cannot run {s}: {s}\n", .{ name, zig_exe, @errorName(err) });
    std.process.exit(127);
}
