//! loginwindow — login, lock screen and session lifecycle (runs as root).
//!
//! Shows a full-screen shield window, authenticates users against
//! /etc/shadow, then starts the session: tells launchd (`launch:ctl`) and
//! the window server (`window:control`) and launches Finder. Afterwards it
//! waits for "lock" / "logout" / "restart" / "shutdown" messages from the
//! window server.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const ui = @import("ui");
const login_mod = @import("login.zig");

const posix = std.posix;
const zio = zen.io;
const users = zen.users;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

fn writeTo(url: []const u8, msg: []const u8) []const u8 {
    const fd = zio.open(url, .{ .ACCMODE = .RDWR }, 0) catch return "error unavailable";
    defer zio.close(fd);
    _ = zio.write(fd, msg) catch return "error write";
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    // window:control replies with nothing (a read would wait for session
    // messages), launch:ctl with a status line.
    if (std.mem.startsWith(u8, url, "window:")) return "ok";
    const n = zio.read(fd, &S.buf) catch 0;
    return std.mem.trim(u8, S.buf[0..n], " \r\n");
}

fn loadUsers(l: *login_mod.Login) void {
    var db = users.Db.load(gpa, "/") catch return;
    defer db.deinit();
    const humans = db.humanUsers(gpa) catch return;
    var list: std.ArrayList(login_mod.User) = .empty;
    for (humans) |u| {
        list.append(gpa, .{
            .name = gpa.dupe(u8, u.name) catch continue,
            .full_name = gpa.dupe(u8, if (u.gecos.len > 0) u.gecos else u.name) catch continue,
            .uid = u.uid,
        }) catch {};
    }
    l.users = list.toOwnedSlice(gpa) catch &.{};
}

fn chownPath(path: []const u8, uid: u32, gid: u32) void {
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    const linux = std.os.linux;
    _ = linux.syscall5(.fchownat, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z.ptr), uid, gid, 0);
}

fn createAccount(l: *login_mod.Login) bool {
    var db = users.Db.load(gpa, "/") catch return false;
    defer db.deinit();
    const name = l.account.buf.items;
    const uid = db.addUser(.{
        .name = name,
        .full_name = l.full_name.buf.items,
        .password = l.password.buf.items,
        .admin = true,
    }) catch |err| {
        l.busy = false;
        l.error_msg = switch (err) {
            error.AlreadyExists => "That account name is already taken.",
            error.InvalidEntry => "Account names use lowercase letters and digits.",
            else => "Could not create the account.",
        };
        return false;
    };
    const home = std.fmt.allocPrint(gpa, "/Users/{s}", .{name}) catch return false;
    for ([_][]const u8{ "", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library", "Library/Containers", "Library/Preferences" }) |sub| {
        const p = std.fs.path.join(gpa, &.{ home, sub }) catch continue;
        std.fs.cwd().makePath(p) catch {};
        chownPath(p, uid, uid);
    }
    zen.sys.logf("loginwindow: created account {s} (uid {d})", .{ name, uid });
    return true;
}

const Session = struct { uid: u32, name: []const u8 };

fn beginSession(u: login_mod.User) void {
    var buf: [128]u8 = undefined;
    _ = writeTo("launch:ctl", std.fmt.bufPrint(&buf, "session-begin {d}", .{u.uid}) catch return);
    _ = writeTo("window:control", std.fmt.bufPrint(&buf, "session-begin {d} {s}", .{ u.uid, u.name }) catch return);
    _ = writeTo("launch:ctl", "open com.zen.Finder");
    zen.sys.logf("loginwindow: session started for {s}", .{u.name});
}

fn endSession() void {
    _ = writeTo("launch:ctl", "session-end");
    _ = writeTo("window:control", "session-end");
}

pub fn main() !void {
    zen.sys.setName("loginwindow");
    var fonts = try ui.FontSet.load(gpa);
    var win = try ui.Window.open(gpa, .{ .title = "Login", .width = 1280, .height = 800, .flags = abi.window.Flags.shield });
    var u = ui.Ui.init(gpa, &win, &fonts);
    u.setDark(true, null);
    var l = login_mod.Login.init(gpa);
    loadUsers(&l);
    l.mode = if (l.users.len == 0) .setup else .login;

    const control = zio.open("window:control", .{ .ACCMODE = .RDWR }, 0) catch -1;
    var session: ?Session = null;
    var shown = true;

    var first = true;
    while (true) {
        var events: []ui.client.Event = &.{};
        if (!first) {
            var fds = [_]posix.pollfd{
                .{ .fd = win.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = control, .events = posix.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = if (u.want_frame) 30 else if (shown) 15_000 else -1;
            _ = zio.poll(fds[0..if (control >= 0) 2 else 1], timeout) catch 0;
            if (fds[0].revents & posix.POLL.IN != 0) events = win.waitEvents(0);
            if (control >= 0 and fds[1].revents & posix.POLL.IN != 0) {
                var buf: [256]u8 = undefined;
                const n = zio.read(control, &buf) catch 0;
                var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
                while (lines.next()) |msg| {
                    if (std.mem.eql(u8, msg, "lock") and session != null) {
                        l.mode = .locked;
                        _ = writeTo("window:control", "lock");
                        win.command(.show, "");
                        win.command(.activate, "");
                        shown = true;
                    } else if (std.mem.eql(u8, msg, "logout") or std.mem.eql(u8, msg, "restart") or std.mem.eql(u8, msg, "shutdown")) {
                        if (session != null) endSession();
                        session = null;
                        loadUsers(&l);
                        l.mode = if (l.users.len == 0) .setup else .login;
                        l.password.set(gpa, "");
                        win.command(.show, "");
                        win.command(.activate, "");
                        shown = true;
                        if (std.mem.eql(u8, msg, "restart")) zen.sys.reboot() catch {};
                        if (std.mem.eql(u8, msg, "shutdown")) zen.sys.powerOff() catch {};
                    }
                }
            }
        }
        first = false;
        if (!shown) continue;

        u.beginFrame(events);
        l.handleKeys(&u);
        const action = l.frame(&u);
        u.endFrame();

        switch (action) {
            .none => {},
            .authenticate => |idx| {
                // Paint "Logging in…" before the (slow) password hash.
                u.beginFrame(&.{});
                _ = l.frame(&u);
                u.endFrame();
                const user = l.users[idx];
                var db = users.Db.load(gpa, "/") catch {
                    l.fail("The user database is unavailable.");
                    continue;
                };
                defer db.deinit();
                const ok = db.checkPassword(user.name, l.password.buf.items) catch false;
                if (!ok) {
                    zen.sys.logf("loginwindow: failed login for {s}", .{user.name});
                    l.fail("Incorrect password");
                    continue;
                }
                l.busy = false;
                l.password.set(gpa, "");
                if (l.mode == .locked) {
                    _ = writeTo("window:control", "unlock");
                } else {
                    beginSession(user);
                    session = .{ .uid = user.uid, .name = user.name };
                }
                win.command(.hide, "");
                win.flush();
                shown = false;
            },
            .create_account => {
                u.beginFrame(&.{});
                _ = l.frame(&u);
                u.endFrame();
                if (createAccount(&l)) {
                    loadUsers(&l);
                    l.mode = .login;
                    l.busy = false;
                    // Log straight into the new account.
                    for (l.users, 0..) |usr, i| {
                        if (std.mem.eql(u8, usr.name, l.account.buf.items)) {
                            l.selected = i;
                            beginSession(usr);
                            session = .{ .uid = usr.uid, .name = usr.name };
                            win.command(.hide, "");
                            win.flush();
                            shown = false;
                        }
                    }
                }
            },
            .restart => zen.sys.reboot() catch {},
            .shutdown => zen.sys.powerOff() catch {},
        }
    }
}
