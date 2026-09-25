//! Pseudo-terminal and login shell.
//!
//! On Zen the master comes from `pty:ptmx` (ptyd) and the shell is started
//! with `zen.sys.spawn` in a new session on the slave (`/dev/pts/N`); the
//! shell makes it its controlling terminal. On a Linux development host the
//! same code uses `/dev/ptmx` and fork + execve.

const std = @import("std");
const zen = @import("zen");

const posix = std.posix;
const linux = std.os.linux;

const TIOCSCTTY = 0x540E;
const TIOCSWINSZ = 0x5414;
const TIOCGPTN = 0x80045430;
const TIOCSPTLCK = 0x40045431;

pub const Options = struct {
    /// Executable path, e.g. /bin/zensh.
    path: []const u8,
    /// argv[0], e.g. "-zensh" for a login shell.
    argv0: []const u8,
    env: []const []const u8,
    cwd: ?[]const u8 = null,
    /// rows, cols, xpixel, ypixel
    winsize: [4]u16,
};

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    on_zen: bool,

    pub fn spawn(allocator: std.mem.Allocator, opts: Options) !Pty {
        const on_zen = zen.sys.isZen();
        const master = try posix.open(if (on_zen) "pty:ptmx" else "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        errdefer posix.close(master);
        var unlock: i32 = 0;
        _ = linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));
        var n: u32 = 0;
        if (linux.ioctl(master, TIOCGPTN, @intFromPtr(&n)) != 0) return error.NoPty;
        var self = Pty{ .master = master, .pid = 0, .on_zen = on_zen };
        self.setSize(opts.winsize);

        var name_buf: [32]u8 = undefined;
        const slave_path = try std.fmt.bufPrint(&name_buf, "/dev/pts/{d}", .{n});
        if (on_zen) {
            const slave = try posix.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
            // Our copy must be closed so reads report EIO when the shell exits.
            defer posix.close(slave);
            const pid = try zen.sys.spawn(allocator, opts.path, .{
                .argv = &.{opts.argv0},
                .env = opts.env,
                .fds = &.{ slave, slave, slave },
                .cwd = opts.cwd,
                .new_session = true,
            });
            self.pid = @intCast(pid);
        } else {
            self.pid = try forkExec(allocator, slave_path, opts);
        }
        return self;
    }

    /// Linux host fallback: fork, make the slave the controlling tty, exec.
    fn forkExec(allocator: std.mem.Allocator, slave_path: []const u8, opts: Options) !posix.pid_t {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path = try a.dupeZ(u8, opts.path);
        const slave = try a.dupeZ(u8, slave_path);
        const cwd = if (opts.cwd) |c| try a.dupeZ(u8, c) else null;
        const argv = try a.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = try a.dupeZ(u8, opts.argv0);
        const envp = try a.allocSentinel(?[*:0]const u8, opts.env.len, null);
        for (opts.env, 0..) |e, i| envp[i] = try a.dupeZ(u8, e);

        const pid = try posix.fork();
        if (pid != 0) return pid;
        // Child: no allocation from here on.
        _ = linux.setsid();
        const fd = posix.openZ(slave, .{ .ACCMODE = .RDWR }, 0) catch linux.exit(127);
        _ = linux.ioctl(fd, TIOCSCTTY, 0);
        for (0..3) |i| posix.dup2(fd, @intCast(i)) catch linux.exit(127);
        if (fd > 2) posix.close(fd);
        if (cwd) |c| posix.chdirZ(c) catch {};
        posix.execveZ(path, argv, envp) catch {};
        linux.exit(127);
    }

    pub fn setSize(self: *Pty, ws: [4]u16) void {
        _ = linux.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// Read shell output (blocking). Returns 0 once the shell has exited
    /// (EOF, or EIO after the last slave closed).
    pub fn read(self: *Pty, buf: []u8) usize {
        return posix.read(self.master, buf) catch 0;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            off += posix.write(self.master, bytes[off..]) catch return;
        }
    }

    /// Close the master (the shell's session gets SIGHUP) and reap it.
    pub fn close(self: *Pty) void {
        posix.close(self.master);
        if (!self.on_zen and self.pid > 0) {
            posix.kill(self.pid, posix.SIG.HUP) catch {};
            _ = zen.sys.reap(@intCast(self.pid), false);
        }
    }
};

/// The user's login shell: $SHELL, else /bin/zensh; on a development host
/// fall back to bash or sh when zensh is not installed.
pub fn loginShell() []const u8 {
    const candidates = [_]?[]const u8{ posix.getenv("SHELL"), "/bin/zensh", "/bin/bash", "/bin/sh" };
    for (candidates) |c| {
        const p = c orelse continue;
        if (p.len == 0) continue;
        posix.access(p, posix.X_OK) catch continue;
        return p;
    }
    return "/bin/zensh";
}

/// Environment for the shell: ours, with the terminal variables replaced.
/// Caller frees the slice (the strings are borrowed or static).
pub fn shellEnv(allocator: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    const ours = [_][]const u8{ "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Zen_Terminal", "TERM_PROGRAM_VERSION=1.0" };
    for (std.os.environ) |e| {
        const s = std.mem.span(e);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        const name = s[0..eq];
        if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "COLORTERM") or
            std.mem.startsWith(u8, name, "TERM_PROGRAM") or std.mem.startsWith(u8, name, "ZEN_BUNDLE_")) continue;
        try list.append(allocator, s);
    }
    try list.appendSlice(allocator, &ours);
    if (posix.getenv("LANG") == null) try list.append(allocator, "LANG=en_US.UTF-8");
    return list.toOwnedSlice(allocator);
}

test "shell on a pty (Linux development host)" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux or zen.sys.isZen()) return error.SkipZigTest;
    posix.access("/bin/sh", posix.X_OK) catch return error.SkipZigTest;
    const a = std.testing.allocator;
    var pty = Pty.spawn(a, .{ .path = "/bin/sh", .argv0 = "sh", .env = &.{"PATH=/usr/bin:/bin"}, .winsize = .{ 24, 80, 0, 0 } }) catch return error.SkipZigTest;
    defer pty.close();
    pty.write("stty size; exit\n");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(a);
    var buf: [1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        var pfd = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&pfd, 100) == 0) continue;
        const n = pty.read(&buf);
        if (n == 0) break;
        try got.appendSlice(a, buf[0..n]);
    }
    try std.testing.expect(std.mem.indexOf(u8, got.items, "24 80") != null);
}
