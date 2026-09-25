//! Zen OS build.
//!
//!   zig build              build user space into zig-out/sysroot (riscv64)
//!   zig build image        + signed app bundles, boot archive and ext2 disk
//!                          image: zig-out/initfs.img, zig-out/zen-disk.img
//!   zig build test         host unit tests of the libraries and servers
//!   zig build previews     render desktop previews (PNG) to zig-out/previews
//!   zig build hosted       Zen for running hosted on Linux/Docker (zig-out/hosted)
//!   zig build run-hosted   run it; the desktop appears at http://127.0.0.1:6080
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
    .{ .name = "ext2", .path = "lib/ext2/root.zig" },
    .{ .name = "ext2_host", .path = "lib/ext2/host_device.zig", .deps = &.{"ext2"} },
    .{ .name = "gfx", .path = "lib/gfx/root.zig" },
    .{ .name = "icons", .path = "lib/icons/root.zig", .deps = &.{"gfx"} },
    .{ .name = "ui", .path = "lib/ui/root.zig", .deps = &.{ "gfx", "font", "abi", "zen" } },
};

const ui_deps = &[_][]const u8{ "abi", "zen", "gfx", "font", "ui", "icons", "vt" };

const Program = struct {
    name: []const u8,
    path: []const u8,
    deps: []const []const u8 = &.{},
    /// Install directory inside the system root.
    dir: []const u8 = "bin",
    /// Also packed into the boot archive under this path.
    initfs: ?[]const u8 = null,
    /// Zen hardware drivers are not needed hosted; vncd only runs hosted.
    only: enum { both, zen, hosted } = .both,
};

/// User-space programs installed into the system image.
const programs = [_]Program{
    .{ .name = "init", .path = "servers/init/main.zig", .deps = &.{ "abi", "zen" }, .dir = "sbin", .initfs = "sbin/init" },
    .{ .name = "virtio-blkd", .path = "drivers/virtio-blk/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers", .initfs = "drivers/virtio-blkd", .only = .zen },
    .{ .name = "virtio-gpud", .path = "drivers/virtio-gpu/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers", .initfs = "drivers/virtio-gpud", .only = .zen },
    .{ .name = "virtio-inputd", .path = "drivers/virtio-input/main.zig", .deps = &.{ "abi", "zen", "virtio" }, .dir = "System/Library/Drivers", .initfs = "drivers/virtio-inputd", .only = .zen },
    .{ .name = "fsd", .path = "servers/fsd/main.zig", .deps = &.{ "abi", "zen", "ext2" }, .dir = "System/Library/Servers", .initfs = "servers/fsd", .only = .zen },
    .{ .name = "vncd", .path = "hosted/vncd/main.zig", .deps = &.{ "abi", "zen" }, .dir = "System/Library/Servers", .only = .hosted },
    .{ .name = "ptyd", .path = "servers/ptyd/main.zig", .deps = &.{ "abi", "zen" }, .dir = "System/Library/Servers" },
    .{ .name = "launchd", .path = "servers/launchd/main.zig", .deps = &.{ "abi", "zen" }, .dir = "System/Library/Servers" },
    .{ .name = "windowserver", .path = "servers/windowserver/main.zig", .deps = ui_deps, .dir = "System/Library/Servers" },
    .{ .name = "loginwindow", .path = "apps/loginwindow/main.zig", .deps = ui_deps, .dir = "System/Library/CoreServices" },
    .{ .name = "getty", .path = "userland/getty/main.zig", .deps = &.{"zen"}, .dir = "usr/sbin" },
    .{ .name = "zauth", .path = "userland/auth/main.zig", .deps = &.{"zen"}, .dir = "usr/bin" },
    .{ .name = "cc", .path = "userland/cc/main.zig", .dir = "usr/bin" },
    .{ .name = "zenfetch", .path = "userland/zenfetch/main.zig", .dir = "usr/bin" },
    .{ .name = "open", .path = "userland/open/main.zig", .deps = &.{"zen"}, .dir = "usr/bin" },
    .{ .name = "zbox", .path = "userland/zbox/main.zig", .dir = "usr/bin" },
    .{ .name = "zensh", .path = "userland/sh/main.zig", .dir = "usr/bin" },
};

const AppBundle = struct {
    /// Directory under apps/ (contains main.zig and bundle/).
    dir: []const u8,
    /// Bundle name ("Activity Monitor" → "Activity Monitor.app").
    name: []const u8,
    exe: []const u8,
    location: []const u8 = "Applications",
};

const apps = [_]AppBundle{
    .{ .dir = "Finder", .name = "Finder", .exe = "Finder", .location = "System/Applications" },
    .{ .dir = "Settings", .name = "Settings", .exe = "Settings", .location = "System/Applications" },
    .{ .dir = "Terminal", .name = "Terminal", .exe = "Terminal", .location = "System/Applications/Utilities" },
    .{ .dir = "ActivityMonitor", .name = "Activity Monitor", .exe = "ActivityMonitor", .location = "System/Applications/Utilities" },
    .{ .dir = "TextEdit", .name = "TextEdit", .exe = "TextEdit" },
    .{ .dir = "Calculator", .name = "Calculator", .exe = "Calculator" },
    .{ .dir = "Preview", .name = "Preview", .exe = "Preview" },
};

/// Files with host-runnable unit tests.
const tests = [_]Lib{
    .{ .name = "abi", .path = "lib/abi/root.zig" },
    .{ .name = "zen", .path = "lib/zen/root.zig", .deps = &.{"abi"} },
    .{ .name = "ldisc", .path = "servers/ptyd/ldisc.zig" },
    .{ .name = "wm", .path = "servers/windowserver/wm.zig", .deps = &.{"abi"} },
    .{ .name = "font", .path = "lib/font/root.zig" },
    .{ .name = "vt", .path = "lib/vt/root.zig" },
    .{ .name = "ext2", .path = "lib/ext2/root.zig" },
    .{ .name = "fsd", .path = "servers/fsd/service.zig", .deps = &.{ "abi", "ext2" } },
    .{ .name = "gfx", .path = "lib/gfx/root.zig" },
    .{ .name = "icons", .path = "lib/icons/root.zig", .deps = &.{"gfx"} },
    .{ .name = "ui", .path = "lib/ui/root.zig", .deps = &.{ "gfx", "font", "abi", "zen" } },
    .{ .name = "terminal", .path = "apps/Terminal/main.zig", .deps = ui_deps },
    .{ .name = "calculator", .path = "apps/Calculator/app.zig", .deps = ui_deps },
    .{ .name = "activity", .path = "apps/ActivityMonitor/app.zig", .deps = ui_deps },
    .{ .name = "finder", .path = "apps/Finder/tests.zig", .deps = ui_deps },
    .{ .name = "textedit", .path = "apps/TextEdit/tests.zig", .deps = ui_deps },
    .{ .name = "settings", .path = "apps/Settings/tests.zig", .deps = ui_deps },
    .{ .name = "zbox", .path = "userland/zbox/tests.zig" },
    .{ .name = "zensh", .path = "userland/sh/unit_tests.zig" },
    .{ .name = "vncd", .path = "hosted/vncd/rfb.zig" },
    .{ .name = "preview", .path = "apps/Preview/app.zig", .deps = ui_deps },
};

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn skipped(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const Mods = std.StringHashMap(*std.Build.Module);

fn makeModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Mods {
    var map = Mods.init(b.allocator);
    for (libs) |lib| {
        const m = b.createModule(.{ .root_source_file = b.path(lib.path), .target = target, .optimize = optimize });
        map.put(lib.name, m) catch @panic("oom");
    }
    for (libs) |lib| {
        const m = map.get(lib.name).?;
        for (lib.deps) |d| m.addImport(d, map.get(d) orelse @panic("unknown lib dependency"));
    }
    return map;
}

fn makeExe(
    b: *std.Build,
    mods: Mods,
    name: []const u8,
    path: []const u8,
    deps: []const []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    for (deps) |d| root.addImport(d, mods.get(d) orelse @panic("unknown dependency"));
    return b.addExecutable(.{ .name = name, .root_module = root });
}

const SystemOptions = struct {
    /// Install directory under zig-out.
    prefix: []const u8,
    hosted: bool,
    skip: []const u8,
    toolchain: ?[]const u8 = null,
    initfs_specs: ?*std.ArrayList([]const u8) = null,
    initfs_deps: ?*std.ArrayList(*std.Build.Step) = null,
};

/// Install programs, app bundles, system files and fonts into
/// zig-out/<prefix> for `target` (riscv64 for Zen, the host for hosted).
fn addSystem(
    b: *std.Build,
    step: *std.Build.Step,
    mods: Mods,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    o: SystemOptions,
) void {
    for (programs) |p| {
        if (!exists(p.path) or skipped(o.skip, p.name)) continue;
        if ((p.only == .zen and o.hosted) or (p.only == .hosted and !o.hosted)) continue;
        const e = makeExe(b, mods, p.name, p.path, p.deps, target, optimize);
        const dest = b.fmt("{s}/{s}", .{ o.prefix, p.dir });
        const inst = b.addInstallArtifact(e, .{ .dest_dir = .{ .override = .{ .custom = dest } } });
        step.dependOn(&inst.step);
        if (p.initfs) |ipath| if (o.initfs_specs) |specs| {
            specs.append(b.allocator, b.fmt("{s}={s}", .{ ipath, b.getInstallPath(.{ .custom = dest }, p.name) })) catch @panic("oom");
            o.initfs_deps.?.append(b.allocator, &inst.step) catch @panic("oom");
        };
    }
    for (apps) |app| {
        const main_path = b.fmt("apps/{s}/main.zig", .{app.dir});
        if (!exists(main_path) or skipped(o.skip, app.dir)) continue;
        const contents = b.fmt("{s}/{s}/{s}.app/Contents", .{ o.prefix, app.location, app.name });
        const e = makeExe(b, mods, app.exe, main_path, ui_deps, target, optimize);
        step.dependOn(&b.addInstallArtifact(e, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/Bin", .{contents}) } } }).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path(b.fmt("apps/{s}/bundle", .{app.dir})),
            .install_dir = .{ .custom = contents },
            .install_subdir = "",
        }).step);
    }
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("sysroot"),
        .install_dir = .{ .custom = o.prefix },
        .install_subdir = "",
        .exclude_extensions = &.{ "manifest.txt", "links.txt" },
    }).step);
    if (o.hosted) {
        // Hosted init applies ownership itself when it runs as root.
        step.dependOn(&b.addInstallFile(b.path("sysroot/manifest.txt"), b.fmt("{s}/etc/zen/manifest.txt", .{o.prefix})).step);
    }
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("assets/fonts"),
        .install_dir = .{ .custom = b.fmt("{s}/System/Library/Fonts", .{o.prefix}) },
        .install_subdir = "",
    }).step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("examples"),
        .install_dir = .{ .custom = b.fmt("{s}/usr/share/zen/examples", .{o.prefix}) },
        .install_subdir = "",
    }).step);
    if (o.toolchain) |tc| {
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = .{ .cwd_relative = tc },
            .install_dir = .{ .custom = b.fmt("{s}/usr/lib/zig", .{o.prefix}) },
            .install_subdir = "",
            .exclude_extensions = &.{ ".py", ".pyc" },
        }).step);
    }
}

pub fn build(b: *std.Build) void {
    // Zen user space defaults to ReleaseSmall: the image is booted on an
    // emulated CPU where code size and speed both matter.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseSmall)") orelse .ReleaseSmall;
    const toolchain = b.option([]const u8, "toolchain", "Extracted riscv64 Zig toolchain to install as /usr/lib/zig");
    const disk_mib = b.option(u32, "disk-size", "Root disk size in MiB (default 1024)") orelse 1024;
    const skip = b.option([]const u8, "skip", "Comma-separated programs/apps to leave out") orelse "";
    const zen_target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .none });
    const host_target = b.graph.host;

    const zen_mods = makeModules(b, zen_target, optimize);
    const host_mods = makeModules(b, host_target, .ReleaseFast);
    const install = b.getInstallStep();

    // ---- system root: programs, app bundles, system files ------------------------
    var initfs_specs: std.ArrayList([]const u8) = .empty;
    var initfs_deps: std.ArrayList(*std.Build.Step) = .empty;
    addSystem(b, install, zen_mods, zen_target, optimize, .{
        .prefix = "sysroot",
        .hosted = false,
        .skip = skip,
        .toolchain = toolchain,
        .initfs_specs = &initfs_specs,
        .initfs_deps = &initfs_deps,
    });

    // ---- host tools --------------------------------------------------------------
    const mkinitfs = makeExe(b, host_mods, "mkinitfs", "tools/mkinitfs.zig", &.{"abi"}, host_target, .ReleaseFast);
    const mkimage = makeExe(b, host_mods, "mkimage", "tools/mkimage.zig", &.{"zen"}, host_target, .ReleaseFast);
    const codesign = makeExe(b, host_mods, "codesign", "tools/codesign.zig", &.{"zen"}, host_target, .ReleaseFast);
    const ext2tool = makeExe(b, host_mods, "ext2tool", "lib/ext2/tools/ext2tool.zig", &.{ "ext2", "ext2_host" }, host_target, .ReleaseFast);
    const tools_step = b.step("tools", "Build the host tools (ext2tool, codesign, mkinitfs, mkimage)");
    for ([_]*std.Build.Step.Compile{ mkinitfs, mkimage, codesign, ext2tool }) |t| {
        tools_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } }).step);
    }

    // ---- image -------------------------------------------------------------------
    const image = b.step("image", "Build the boot archive and the root disk image");
    const sysroot = b.getInstallPath(.{ .custom = "sysroot" }, "");

    const prep = b.addRunArtifact(mkimage);
    prep.has_side_effects = true;
    prep.addArgs(&.{
        "--root",     sysroot,
        "--keydir",   b.pathFromRoot("keys"),
        "--manifest", b.pathFromRoot("sysroot/manifest.txt"),
        "--links",    b.pathFromRoot("sysroot/links.txt"),
        "--user",     "root:",
        "--user",     "zen:zen",
    });
    if (exists("userland/zbox/main.zig") and !skipped(skip, "zbox")) {
        // Command symlinks for the multi-call coreutils, listed by a host build.
        const zbox_host = makeExe(b, host_mods, "zbox-host", "userland/zbox/main.zig", &.{}, host_target, .ReleaseFast);
        const list = b.addRunArtifact(zbox_host);
        list.addArg("--list");
        prep.addArg("--commands");
        prep.addFileArg(list.captureStdOut());
        prep.addArgs(&.{ "--commands-into", "usr/bin:zbox" });
    }
    prep.step.dependOn(install);

    const disk_path = b.getInstallPath(.prefix, "zen-disk.img");
    const mkfs = b.addRunArtifact(ext2tool);
    mkfs.has_side_effects = true;
    mkfs.addArgs(&.{ "mkfs", disk_path, b.fmt("{d}", .{disk_mib}), "ZenHD" });
    mkfs.step.dependOn(&prep.step);
    const import = b.addRunArtifact(ext2tool);
    import.has_side_effects = true;
    import.addArgs(&.{ "import", disk_path, sysroot, "/", "--owner", "0:0", "--manifest", b.pathFromRoot("sysroot/manifest.txt") });
    import.step.dependOn(&mkfs.step);
    image.dependOn(&import.step);

    const initfs = b.addRunArtifact(mkinitfs);
    initfs.has_side_effects = true;
    initfs.addArg(b.getInstallPath(.prefix, "initfs.img"));
    initfs.addArgs(initfs_specs.items);
    for (initfs_deps.items) |d| initfs.step.dependOn(d);
    image.dependOn(&initfs.step);

    // ---- hosted: run Zen on Linux (or Docker), shown in a browser -------------------
    const hosted_arch = b.option(std.Target.Cpu.Arch, "hosted-arch", "CPU of the hosted build (default: this machine)");
    // Baseline CPU features: the result may run on another machine (Docker).
    const hosted_target = b.resolveTargetQuery(.{ .cpu_arch = hosted_arch, .cpu_model = .baseline, .os_tag = .linux, .abi = .none });
    const hosted_step = b.step("hosted", "Build Zen to run hosted on Linux or in Docker (zig-out/hosted)");
    const hosted_files = b.allocator.create(std.Build.Step) catch @panic("oom");
    hosted_files.* = std.Build.Step.init(.{ .id = .custom, .name = "hosted system root", .owner = b });
    const hosted_mods = makeModules(b, hosted_target, .ReleaseFast);
    const hosted_toolchain = b.option([]const u8, "hosted-toolchain", "Zig installation to copy into the hosted root as /usr/lib/zig (for Docker)");
    addSystem(b, hosted_files, hosted_mods, hosted_target, .ReleaseFast, .{ .prefix = "hosted/root", .hosted = true, .skip = skip, .toolchain = hosted_toolchain });
    const hosted_root = b.getInstallPath(.{ .custom = "hosted/root" }, "");
    const hprep = b.addRunArtifact(mkimage);
    hprep.has_side_effects = true;
    hprep.addArgs(&.{
        "--root",     hosted_root,
        "--keydir",   b.pathFromRoot("keys"),
        "--manifest", b.pathFromRoot("sysroot/manifest.txt"),
        "--links",    b.pathFromRoot("sysroot/links.txt"),
        "--user",     "root:",
        "--user",     "zen:zen",
    });
    if (exists("userland/zbox/main.zig") and !skipped(skip, "zbox")) {
        const zbox_host = makeExe(b, host_mods, "zbox-host", "userland/zbox/main.zig", &.{}, host_target, .ReleaseFast);
        const list = b.addRunArtifact(zbox_host);
        list.addArg("--list");
        hprep.addArg("--commands");
        hprep.addFileArg(list.captureStdOut());
        hprep.addArgs(&.{ "--commands-into", "usr/bin:zbox" });
    }
    hprep.step.dependOn(hosted_files);
    hosted_step.dependOn(&hprep.step);
    hosted_step.dependOn(&b.addInstallFile(b.path("hosted/Dockerfile"), "hosted/Dockerfile").step);
    if (host_target.result.os.tag == .linux) {
        const launcher = makeExe(b, host_mods, "zen-hosted", "tools/zen-hosted.zig", &.{}, host_target, .ReleaseFast);
        // The Zig running this build doubles as Zen's cc/c++ when hosted.
        const launcher_opts = b.addOptions();
        launcher_opts.addOption([]const u8, "zig_dir", std.fs.path.dirname(b.graph.zig_exe) orelse "/usr/lib/zig");
        launcher.root_module.addOptions("options", launcher_opts);
        hosted_step.dependOn(&b.addInstallArtifact(launcher, .{ .dest_dir = .{ .override = .{ .custom = "hosted" } } }).step);
        const run_hosted = b.step("run-hosted", "Build and run hosted Zen, then open http://127.0.0.1:6080");
        const run = b.addRunArtifact(launcher);
        run.addArgs(&.{ "--root", hosted_root });
        if (b.args) |args| run.addArgs(args);
        run.step.dependOn(hosted_step);
        run_hosted.dependOn(&run.step);
    }

    // ---- previews ----------------------------------------------------------------
    const previews = b.step("previews", "Render desktop previews (PNG) on the host");
    const ws_mod = b.createModule(.{ .root_source_file = b.path("servers/windowserver/lib.zig"), .target = host_target, .optimize = .ReleaseFast });
    for (ui_deps) |d| ws_mod.addImport(d, host_mods.get(d).?);
    const preview_tool = makeExe(b, host_mods, "desktop-preview", "tools/preview/desktop.zig", ui_deps, host_target, .ReleaseFast);
    preview_tool.root_module.addImport("windowserver", ws_mod);
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", b.getInstallPath(.prefix, "previews") });
    for ([_][]const u8{ "light", "dark" }) |mode| {
        const r = b.addRunArtifact(preview_tool);
        r.has_side_effects = true;
        r.addArg(b.getInstallPath(.prefix, b.fmt("previews/desktop-{s}.png", .{mode})));
        r.addArg(mode);
        r.step.dependOn(&mkdir.step);
        previews.dependOn(&r.step);
    }

    // Desktop with real app windows (only when those apps are built).
    const showcase_apps = [_][2][]const u8{ .{ "settings_app", "Settings" }, .{ "calculator_app", "Calculator" }, .{ "terminal_app", "Terminal" } };
    const have_showcase = for (showcase_apps) |sa| {
        if (!exists(b.fmt("apps/{s}/app.zig", .{sa[1]})) or skipped(skip, sa[1])) break false;
    } else true;
    if (have_showcase) {
        const showcase = makeExe(b, host_mods, "showcase", "tools/preview/showcase.zig", ui_deps, host_target, .ReleaseFast);
        showcase.root_module.addImport("windowserver", ws_mod);
        for (showcase_apps) |sa| {
            const m = b.createModule(.{ .root_source_file = b.path(b.fmt("apps/{s}/app.zig", .{sa[1]})), .target = host_target, .optimize = .ReleaseFast });
            for (ui_deps) |d| m.addImport(d, host_mods.get(d).?);
            showcase.root_module.addImport(sa[0], m);
        }
        for ([_][]const u8{ "light", "dark" }) |mode| {
            const r = b.addRunArtifact(showcase);
            r.has_side_effects = true;
            r.addArg(b.getInstallPath(.prefix, b.fmt("previews/showcase-{s}.png", .{mode})));
            r.addArg(mode);
            r.step.dependOn(&mkdir.step);
            previews.dependOn(&r.step);
        }
    }

    // ---- host unit tests -------------------------------------------------------------
    const test_step = b.step("test", "Run host unit tests");
    const test_mods = makeModules(b, host_target, .Debug);
    for (tests) |t| {
        const root = b.createModule(.{ .root_source_file = b.path(t.path), .target = host_target, .optimize = .Debug });
        for (t.deps) |d| root.addImport(d, test_mods.get(d) orelse @panic("unknown dependency"));
        const unit = b.addTest(.{ .name = t.name, .root_module = root });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
