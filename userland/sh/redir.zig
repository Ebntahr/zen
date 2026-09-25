//! I/O redirections.
const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const Shell = shell.Shell;
const Error = shell.Error;

pub const save_base: i32 = 10;

/// File descriptors saved while a builtin / function / compound command
/// runs with redirections, restored afterwards.
pub const Saved = struct {
    items: [16]Entry = undefined,
    n: usize = 0,

    const Entry = struct { fd: i32, saved: i32 };
};

fn saveFd(saved: ?*Saved, fd: i32) void {
    const s = saved orelse return;
    for (s.items[0..s.n]) |e| if (e.fd == fd) return;
    if (s.n == s.items.len) return;
    const copy = sys.dupHigh(fd, save_base) catch -1;
    s.items[s.n] = .{ .fd = fd, .saved = copy };
    s.n += 1;
}

pub noinline fn restore(sh: *Shell, saved: *Saved) void {
    if (saved.n == 0) return;
    sh.flushOut();
    var i = saved.n;
    while (i > 0) {
        i -= 1;
        const e = saved.items[i];
        if (e.saved >= 0) {
            sys.dup2(e.saved, e.fd) catch {};
            sys.close(e.saved);
        } else sys.close(e.fd);
    }
    saved.n = 0;
}

fn moveFd(nfd: i32, fd: i32) !void {
    if (nfd == fd) {
        try sys.dup2(nfd, fd); // clears close-on-exec
        return;
    }
    defer sys.close(nfd);
    try sys.dup2(nfd, fd);
}

/// Create a readable descriptor that yields `content` (here-documents).
fn contentFd(sh: *Shell, content: []const u8) ?i32 {
    const fds = sys.pipe() catch {
        sh.errMsg("pipe: {s}", .{sys.lastError()});
        return null;
    };
    if (content.len <= 512) {
        sys.writeAll(fds[1], content) catch {};
        sys.close(fds[1]);
        return fds[0];
    }
    sh.flushOut();
    const pid = sys.fork() catch {
        sys.close(fds[0]);
        sys.close(fds[1]);
        sh.errMsg("fork: {s}", .{sys.lastError()});
        return null;
    };
    if (pid == 0) {
        sys.close(fds[0]);
        _ = sys.signal(std.os.linux.SIG.PIPE, .default, false);
        sys.writeAll(fds[1], content) catch {};
        sys.exit(0);
    }
    sys.close(fds[1]);
    return fds[0];
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Apply redirections. Returns false (after printing a message) if one
/// failed. When `saved` is non-null the previous descriptors are saved so
/// they can be restored.
pub noinline fn apply(sh: *Shell, redirs: []const ast.Redir, saved: ?*Saved) Error!bool {
    for (redirs) |*r| {
        if (!try applyOne(sh, r, saved)) return false;
    }
    return true;
}

fn openFile(sh: *Shell, path: []const u8, flags: sys.O, fd: i32, also_stderr: bool, saved: ?*Saved) bool {
    if (path.len == 0) {
        sh.errMsg(": No such file or directory", .{});
        return false;
    }
    saveFd(saved, fd);
    if (also_stderr) saveFd(saved, 2);
    const nfd = sys.open(path, flags, 0o666) catch {
        sh.errMsg("{s}: {s}", .{ path, sys.lastError() });
        return false;
    };
    if (also_stderr) {
        sys.dup2(nfd, 2) catch {};
    }
    moveFd(nfd, fd) catch {
        sh.errMsg("{d}: {s}", .{ fd, sys.lastError() });
        return false;
    };
    return true;
}

fn applyOne(sh: *Shell, r: *const ast.Redir, saved: ?*Saved) Error!bool {
    const default_fd: i32 = switch (r.op) {
        .in, .rdwr, .dup_in, .heredoc, .herestring => 0,
        else => 1,
    };
    const fd = if (r.fd >= 0) r.fd else default_fd;
    switch (r.op) {
        .in => {
            const path = try expand.wordToString(sh, r.target, false);
            return openFile(sh, path, .{ .ACCMODE = .RDONLY }, fd, false, saved);
        },
        .out, .clobber => {
            const path = try expand.wordToString(sh, r.target, false);
            var flags: sys.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
            if (r.op == .out and sh.opts.noclobber) {
                if (sys.stat(path)) |st| {
                    if (sys.isReg(st)) {
                        sh.errMsg("{s}: cannot overwrite existing file", .{path});
                        return false;
                    }
                    flags.TRUNC = false;
                } else |_| {
                    flags.EXCL = true;
                }
            }
            return openFile(sh, path, flags, fd, false, saved);
        },
        .append => {
            const path = try expand.wordToString(sh, r.target, false);
            return openFile(sh, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, fd, false, saved);
        },
        .rdwr => {
            const path = try expand.wordToString(sh, r.target, false);
            return openFile(sh, path, .{ .ACCMODE = .RDWR, .CREAT = true }, fd, false, saved);
        },
        .out_err, .append_err => {
            const path = try expand.wordToString(sh, r.target, false);
            const flags: sys.O = if (r.op == .out_err)
                .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }
            else
                .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
            return openFile(sh, path, flags, 1, true, saved);
        },
        .dup_in, .dup_out => {
            const t = try expand.wordToString(sh, r.target, false);
            if (std.mem.eql(u8, t, "-")) {
                saveFd(saved, fd);
                sys.close(fd);
                return true;
            }
            var num = t;
            var move = false;
            if (num.len > 1 and num[num.len - 1] == '-') {
                num = num[0 .. num.len - 1];
                move = true;
            }
            if (allDigits(num)) {
                const src = std.fmt.parseInt(i32, num, 10) catch {
                    sh.errMsg("{s}: Bad file descriptor", .{t});
                    return false;
                };
                if (!sys.isValidFd(src)) {
                    sh.errMsg("{d}: Bad file descriptor", .{src});
                    return false;
                }
                if (src == fd) return true;
                saveFd(saved, fd);
                sys.dup2(src, fd) catch {
                    sh.errMsg("{d}: {s}", .{ fd, sys.lastError() });
                    return false;
                };
                if (move) {
                    saveFd(saved, src);
                    sys.close(src);
                }
                return true;
            }
            if (r.op == .dup_out and r.fd < 0) {
                return openFile(sh, t, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 1, true, saved);
            }
            sh.errMsg("{s}: ambiguous redirect", .{t});
            return false;
        },
        .heredoc, .herestring => {
            var content: []const u8 = undefined;
            if (r.op == .heredoc) {
                content = try expand.heredocToString(sh, r.here.?.body);
            } else {
                const w = try expand.wordToString(sh, r.target, false);
                content = try std.mem.concat(sh.scratchAlloc(), u8, &.{ w, "\n" });
            }
            saveFd(saved, fd);
            const nfd = contentFd(sh, content) orelse return false;
            moveFd(nfd, fd) catch {
                sh.errMsg("{d}: {s}", .{ fd, sys.lastError() });
                return false;
            };
            return true;
        },
    }
}
