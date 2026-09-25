//! Zen OS build.
//!
//!   zig build            build all user-space programs into zig-out/sysroot
//!   zig build test       run host unit tests of the libraries and servers
//!
//! User space targets `riscv64-linux-none`: Zen implements the Linux
//! riscv64 system-call ABI, so programs use Zig's std directly.

const std = @import("std");

const Lib = struct {
    name: []const u8,
    path: []const u8,
    deps: []const []const u8 = &.{},
};

/// Shared libraries (Zig modules) available to programs.
const libs = [_]Lib{
    .{ .name = "abi", .path = "lib/abi/root.zig" },
    .{ .name = "zen", .path = "lib/zen/root.zig", .deps = &.{"abi"} },
    .{ .name = "virtio", .path = "lib/virtio/root.zig", .deps = &.{"zen"} },
    .{ .name = "font", .path = "lib/font/root.zig" },
    .{ .name = "vt", .path = "lib/vt/root.zig" },
};

const Program = struct {
    name: []const u8,
    path: []const u8,
    deps: []const []const u8 = &.{},
    /// Install directory inside the system root.
    dir: []const u8 = "bin",
};

/// User-space programs installed into the system image.
const programs = [_]Program{
    .{ .name = "init", .path = "servers/init/main.zig", .deps = &.{ "abi", "zen" }, .dir = "sbin" },
    .{ .name = "getty", .path = "userland/getty/main.zig", .deps = &.{"zen"}, .dir = "usr/sbin" },
    .{ .name = "ptyd", .path = "servers/ptyd/main.zig", .deps = &.{ "abi", "zen" }, .dir = "System/Library/Servers" },
    .{ .name = "virtio-blkd", .path = "drivers/virtio-blk/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers" },
    .{ .name = "virtio-gpud", .path = "drivers/virtio-gpu/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers" },
    .{ .name = "launchd", .path = "servers/launchd/main.zig", .deps = &.{ "abi", "zen" }, .dir = "System/Library/Servers" },
    .{ .name = "cc", .path = "userland/cc/main.zig", .dir = "usr/bin" },
    .{ .name = "zauth", .path = "userland/auth/main.zig", .deps = &.{"zen"}, .dir = "usr/bin" },
    .{ .name = "virtio-inputd", .path = "drivers/virtio-input/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers" },
};

/// Files with host-runnable unit tests.
const tests = [_]Lib{
    .{ .name = "abi", .path = "lib/abi/root.zig" },
    .{ .name = "zen", .path = "lib/zen/root.zig", .deps = &.{"abi"} },
    .{ .name = "ldisc", .path = "servers/ptyd/ldisc.zig" },
    .{ .name = "wm", .path = "servers/windowserver/wm.zig", .deps = &.{"abi"} },
    .{ .name = "font", .path = "lib/font/root.zig" },
    .{ .name = "vt", .path = "lib/vt/root.zig" },
};

fn makeModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) std.StringHashMap(*std.Build.Module) {
    var map = std.StringHashMap(*std.Build.Module).init(b.allocator);
    for (libs) |lib| {
        const m = b.createModule(.{
            .root_source_file = b.path(lib.path),
            .target = target,
            .optimize = optimize,
        });
        map.put(lib.name, m) catch @panic("oom");
    }
    for (libs) |lib| {
        const m = map.get(lib.name).?;
        for (lib.deps) |d| m.addImport(d, map.get(d) orelse @panic("unknown lib dependency"));
    }
    return map;
}

pub fn build(b: *std.Build) void {
    // Zen user space defaults to ReleaseSmall: the image is booted on an
    // emulated CPU where code size and speed both matter.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseSmall)") orelse .ReleaseSmall;
    const zen_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .linux,
        .abi = .none,
    });
    const host_target = b.graph.host;

    // ---- user space for Zen -------------------------------------------------
    const zen_mods = makeModules(b, zen_target, optimize);
    for (programs) |p| {
        const root = b.createModule(.{
            .root_source_file = b.path(p.path),
            .target = zen_target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        });
        for (p.deps) |d| root.addImport(d, zen_mods.get(d) orelse @panic("unknown dependency"));
        const exe = b.addExecutable(.{ .name = p.name, .root_module = root });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("sysroot/{s}", .{p.dir}) } },
        });
        b.getInstallStep().dependOn(&install.step);
    }

    // ---- host unit tests ----------------------------------------------------
    const test_step = b.step("test", "Run host unit tests");
    const host_mods = makeModules(b, host_target, .Debug);
    for (tests) |t| {
        const root = b.createModule(.{
            .root_source_file = b.path(t.path),
            .target = host_target,
            .optimize = .Debug,
        });
        for (t.deps) |d| root.addImport(d, host_mods.get(d) orelse @panic("unknown dependency"));
        const unit = b.addTest(.{ .name = t.name, .root_module = root });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
