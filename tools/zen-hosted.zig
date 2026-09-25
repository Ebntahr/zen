//! zen-hosted — run Zen OS hosted on Linux, without Docker.
//!
//!   zen-hosted [--root DIR] [--size WxH] [--http PORT] [--vnc PORT] [--bind ADDR]
//!
//! Enters a private mount namespace (and, for ordinary users, a user
//! namespace that maps the user to root), makes the host's /dev and /proc
//! visible inside the Zen system root, changes root into it and becomes
//! Zen's init. The desktop is then served at http://127.0.0.1:6080.
//! Ctrl-C shuts Zen down.

const std = @import("std");
const options = @import("options");
const linux = std.os.linux;
const posix = std.posix;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zen-hosted: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn check(rc: usize, what: []const u8) void {
    const e = linux.E.init(rc);
    if (e != .SUCCESS) die("{s} failed: {s}", .{ what, @tagName(e) });
}

fn writeFile(path: []const u8, data: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch return false;
    defer f.close();
    f.writeAll(data) catch return false;
    return true;
}

fn bindMount(src: [:0]const u8, dst: [:0]const u8) void {
    std.fs.cwd().makePath(dst) catch {};
    check(linux.mount(src, dst, null, linux.MS.BIND | linux.MS.REC, 0), dst);
}

const usage =
    \\usage: zen-hosted [--root DIR] [--size WxH] [--http PORT] [--vnc PORT] [--bind ADDR]
    \\
    \\  --root DIR    the hosted system root (default: root/ next to this program)
    \\  --size WxH    screen size (default 1280x800)
    \\  --http PORT   web client port (default 6080)
    \\  --vnc PORT    VNC port, 0 to disable (default 5900)
    \\  --bind ADDR   listen address (default 127.0.0.1)
    \\  --toolchain DIR  Zig installation to use as /usr/lib/zig (cc, c++);
    \\                   default: the Zig that built Zen, if present
    \\
;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);

    var root: ?[]const u8 = null;
    var toolchain: ?[]const u8 = null;
    var env = std.StringArrayHashMap([]const u8).init(a);
    try env.put("ZEN_HOSTED_SIZE", "1280x800");
    try env.put("ZEN_HOSTED_HTTP", "6080");
    try env.put("ZEN_HOSTED_VNC", "5900");
    try env.put("ZEN_HOSTED_BIND", "127.0.0.1");
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const opt = args[i];
        if (std.mem.eql(u8, opt, "-h") or std.mem.eql(u8, opt, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (i + 1 >= args.len) die("{s} needs a value\n{s}", .{ opt, usage });
        const val = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, opt, "--root")) root = val else if (std.mem.eql(u8, opt, "--toolchain")) toolchain = val else if (std.mem.eql(u8, opt, "--size")) try env.put("ZEN_HOSTED_SIZE", val) else if (std.mem.eql(u8, opt, "--http")) try env.put("ZEN_HOSTED_HTTP", val) else if (std.mem.eql(u8, opt, "--vnc")) try env.put("ZEN_HOSTED_VNC", val) else if (std.mem.eql(u8, opt, "--bind")) try env.put("ZEN_HOSTED_BIND", val) else die("unknown option {s}\n{s}", .{ opt, usage });
    }
    const root_path = root orelse blk: {
        const self_dir = try std.fs.selfExeDirPathAlloc(a);
        break :blk try std.fs.path.join(a, &.{ self_dir, "root" });
    };
    const root_abs = std.fs.cwd().realpathAlloc(a, root_path) catch die("no Zen system root at {s} (run `zig build hosted` first)", .{root_path});
    std.fs.cwd().access(try std.fs.path.join(a, &.{ root_abs, "sbin/init" }), .{}) catch die("{s} has no sbin/init (run `zig build hosted`)", .{root_abs});

    // Namespaces: ordinary users become root inside a user namespace.
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (uid != 0) {
        const rc = linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWUTS);
        if (linux.E.init(rc) != .SUCCESS) die(
            \\cannot create a user namespace ({s}).
            \\  Some systems (e.g. Ubuntu 24.04) restrict them. Run with sudo, or use Docker:
            \\    docker build -t zen-os zig-out/hosted && docker run --rm --hostname zen-os -p 127.0.0.1:6080:6080 zen-os
        , .{@tagName(linux.E.init(rc))});
        _ = writeFile("/proc/self/setgroups", "deny");
        var buf: [64]u8 = undefined;
        if (!writeFile("/proc/self/uid_map", try std.fmt.bufPrint(&buf, "0 {d} 1", .{uid}))) die("cannot write uid_map", .{});
        if (!writeFile("/proc/self/gid_map", try std.fmt.bufPrint(&buf, "0 {d} 1", .{gid}))) die("cannot write gid_map", .{});
    } else {
        check(linux.unshare(linux.CLONE.NEWNS | linux.CLONE.NEWUTS), "unshare");
    }
    // Zen's own host name (a private UTS namespace leaves the host's alone).
    var host_buf: [64]u8 = undefined;
    const host_path = try std.fs.path.join(a, &.{ root_abs, "etc/hostname" });
    if (std.fs.cwd().readFile(host_path, &host_buf)) |text| {
        const name = std.mem.trim(u8, text, " \r\n");
        if (name.len > 0) _ = linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len);
    } else |_| {}
    // Keep our mounts to ourselves.
    const rc = linux.mount("none", "/", null, linux.MS.REC | linux.MS.PRIVATE, 0);
    if (linux.E.init(rc) != .SUCCESS) die(
        \\cannot set up mounts ({s}). Run with sudo, or use Docker (see zig-out/hosted/Dockerfile).
    , .{@tagName(linux.E.init(rc))});

    const rootz = try a.dupeZ(u8, root_abs);
    bindMount("/dev", try std.fmt.allocPrintSentinel(a, "{s}/dev", .{root_abs}, 0));
    bindMount("/proc", try std.fmt.allocPrintSentinel(a, "{s}/proc", .{root_abs}, 0));
    // The C/C++ toolchain (cc, c++): a Zig installation at /usr/lib/zig,
    // unless the system root already contains one.
    const zig_in_root = try std.fs.path.join(a, &.{ root_abs, "usr/lib/zig/zig" });
    const have_zig = if (std.fs.cwd().access(zig_in_root, .{})) true else |_| false;
    if (!have_zig) {
        const tc = toolchain orelse options.zig_dir;
        const tc_zig = try std.fs.path.join(a, &.{ tc, "zig" });
        if (std.fs.cwd().access(tc_zig, .{})) {
            const tcz = try a.dupeZ(u8, tc);
            const dst = try std.fmt.allocPrintSentinel(a, "{s}/usr/lib/zig", .{root_abs}, 0);
            std.fs.cwd().makePath(dst) catch {};
            if (linux.E.init(linux.mount(tcz, dst, null, linux.MS.BIND | linux.MS.REC, 0)) == .SUCCESS) {
                _ = linux.mount("none", dst, null, linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY | linux.MS.REC, 0);
            }
        } else |_| if (toolchain != null) die("no zig executable in {s}", .{tc});
    }
    check(linux.chroot(rootz), "chroot");
    check(linux.chdir("/"), "chdir");
    std.fs.cwd().makePath("run/zen") catch {};

    // Zen's init takes over this process; it stops everything on Ctrl-C.
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    try envp.append(a, "ZEN_HOSTED=/run/zen");
    for (env.keys(), env.values()) |k, v| try envp.append(a, (try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, v }, 0)).ptr);
    for ([_][:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "TERM=xterm-256color", "LANG=en_US.UTF-8" }) |e| try envp.append(a, e.ptr);
    try envp.append(a, null);
    const argv = [_:null]?[*:0]const u8{"/sbin/init"};
    const port = env.get("ZEN_HOSTED_HTTP").?;
    std.debug.print("zen-hosted: starting Zen OS — open http://127.0.0.1:{s} (user zen, password zen). Ctrl-C stops it.\n", .{port});
    const err = linux.execve("/sbin/init", &argv, @ptrCast(envp.items.ptr));
    die("cannot start /sbin/init: {s}", .{@tagName(linux.E.init(err))});
}
