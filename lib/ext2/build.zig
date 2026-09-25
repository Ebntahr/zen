//! Standalone build for the ext2 library, its host tool and tests.
//!
//!   zig build              build zig-out/bin/ext2tool and fstest
//!   zig build test         run unit tests (in-memory device)
//!   zig build cross        compile library + tests for riscv64-linux-none
//!                          and riscv64-freestanding-none
//!   tests/run.sh           host integration tests (mke2fs/debugfs/e2fsck)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ext2 = b.addModule("ext2", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host = b.addModule("ext2_host", .{
        .root_source_file = b.path("host_device.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ext2", .module = ext2 }},
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "ext2", .module = ext2 },
        .{ .name = "ext2_host", .module = host },
    };

    const tool = b.addExecutable(.{
        .name = "ext2tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ext2tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(tool);

    const fstest = b.addExecutable(.{
        .name = "fstest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fstest.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(fstest);

    const unit = b.addTest(.{ .root_module = ext2 });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit.step);

    // Cross-compilation checks (compile only).
    const cross_step = b.step("cross", "Compile the library and its tests for riscv64");
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .none },
        .{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none },
    };
    for (cross_targets) |q| {
        const t = b.resolveTargetQuery(q);
        const lib = b.addLibrary(.{
            .name = "ext2",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/cross_root.zig"),
                .target = t,
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "ext2", .module = b.createModule(.{
                    .root_source_file = b.path("root.zig"),
                    .target = t,
                    .optimize = .ReleaseSmall,
                }) }},
            }),
        });
        cross_step.dependOn(&lib.step);
        if (q.os_tag == .linux) {
            const t_mod = b.createModule(.{
                .root_source_file = b.path("root.zig"),
                .target = t,
                .optimize = optimize,
            });
            const cross_test = b.addTest(.{ .root_module = t_mod });
            cross_step.dependOn(&cross_test.step);
        }
    }
}
