//! Standalone build for zensh.
//!
//!   zig build                          # riscv64-linux-none (Zen OS), ReleaseSmall
//!   zig build -Dtarget=native          # host build (for testing)
//!   zig build test                     # unit tests (host)
//!   zig build run -Dtarget=native -- -c 'echo hi'
//!
//! Equivalent single commands:
//!   zig build-exe main.zig -target riscv64-linux-none -O ReleaseSmall --name zensh
//!   zig build-exe main.zig --name zensh
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .none },
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall)") orelse .ReleaseSmall;

    const exe = b.addExecutable(.{
        .name = "zensh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zensh").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests on the host");
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("unit_tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
