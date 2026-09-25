//! Terminal.app entry point: window + pty event loop.
//!
//! Polls the window (`window:` events) and the pty master together, feeds
//! shell output into the emulator, paints only damaged rows and exits when
//! the shell does. Without a window server (a Linux development host) it
//! runs the shell headless and writes a snapshot PNG instead:
//!
//!     Terminal [out.png] ["commands\r"]

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const ui = @import("ui");
const gfx = @import("gfx");
const App = @import("app.zig").App;
const pty_mod = @import("pty.zig");

const posix = std.posix;
const Pty = pty_mod.Pty;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;

/// Longest time spent reading a burst of output before painting.
const burst_ms = 16;
/// Longest a program may hold synchronized output (?2026) before we paint.
const sync_timeout_ms = 150;

pub fn main() !void {
    const gpa = gpa_state.allocator();
    zen.sys.setName("Terminal");

    var fonts = try ui.FontSet.load(gpa);
    defer fonts.deinit();
    var win = try ui.Window.open(gpa, App.window);
    defer win.close();
    var u = ui.Ui.init(gpa, &win, &fonts);
    defer u.deinit();
    u.setDark(true, null); // "Clear Dark" until the appearance event arrives
    var app = try App.init(gpa, &u);
    defer app.deinit();

    const shell = pty_mod.loginShell();
    app.setIdentity(posix.getenv("USER") orelse "zen", shell);
    if (win.headless) return hostSnapshot(gpa, &app, &win, shell);

    var menu_buf: [2048]u8 = undefined;
    var mw = abi.window.MenuWriter{ .buf = &menu_buf };
    app.menu(&mw);
    win.setMenu(mw.bytes());
    win.setCursor(.ibeam);

    // The server sends focus and appearance right after creating the
    // window; apply them before the first paint.
    for (win.waitEvents(100)) |e| app.handleEvent(&win, e);

    var pty = startShell(gpa, &app, shell) catch |err| {
        var buf: [256]u8 = undefined;
        app.feed(std.fmt.bufPrint(&buf, "\x1b[1;31mCould not start {s}: {s}\x1b[0m\r\n", .{ shell, @errorName(err) }) catch "error\r\n");
        waitForClose(&app, &win);
        return;
    };
    defer pty.close();
    run(gpa, &app, &win, &pty);
}

fn startShell(gpa: std.mem.Allocator, app: *App, shell: []const u8) !Pty {
    var argv0_buf: [64]u8 = undefined;
    const argv0 = std.fmt.bufPrint(&argv0_buf, "-{s}", .{std.fs.path.basename(shell)}) catch "-zensh";
    const env = try pty_mod.shellEnv(gpa);
    defer gpa.free(env);
    const pty = try Pty.spawn(gpa, .{
        .path = shell,
        .argv0 = argv0,
        .env = env,
        .cwd = posix.getenv("HOME"),
        .winsize = app.winsize(),
    });
    app.grid_changed = false;
    return pty;
}

fn run(gpa: std.mem.Allocator, app: *App, win: *ui.Window, pty: *Pty) void {
    var buf: [16 * 1024]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = win.fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
    };
    var sync_deadline: i64 = 0;
    while (!app.quit) {
        // Paint what changed, unless a program is mid-frame (?2026).
        var timeout: i32 = -1;
        if (app.visible) {
            const now = std.time.milliTimestamp();
            if (app.term.modes.synchronized_output and (sync_deadline == 0 or now < sync_deadline)) {
                if (sync_deadline == 0) sync_deadline = now + sync_timeout_ms;
                timeout = @intCast(@max(0, sync_deadline - now));
            } else {
                sync_deadline = 0;
                app.render(win);
            }
        }
        win.flush();

        fds[0].revents = 0;
        fds[1].revents = 0;
        _ = posix.poll(&fds, timeout) catch continue;

        if (fds[0].revents != 0) {
            const events = win.waitEvents(0);
            // Window server gone.
            if (events.len == 0 and fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) break;
            for (events) |e| app.handleEvent(win, e);
        }
        if (fds[1].revents != 0) {
            if (!readShell(app, pty, &buf)) break; // the shell exited
        }
        flushToShell(app, pty);
        if (app.new_window) {
            app.new_window = false;
            openNewWindow(gpa);
        }
    }
}

/// Read shell output, coalescing a burst into one paint. Returns false
/// when the shell has exited.
fn readShell(app: *App, pty: *Pty, buf: []u8) bool {
    const start = std.time.milliTimestamp();
    var total: usize = 0;
    while (true) {
        const n = pty.read(buf);
        if (n == 0) return false;
        app.feed(buf[0..n]);
        flushToShell(app, pty); // answer DA/DSR queries promptly
        total += n;
        if (total >= 1 << 20 or std.time.milliTimestamp() - start >= burst_ms) return true;
        var pfd = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&pfd, 0) catch 0;
        if (ready == 0 or pfd[0].revents & posix.POLL.IN == 0) return true;
    }
}

fn flushToShell(app: *App, pty: *Pty) void {
    if (app.out.items.len > 0) {
        pty.write(app.out.items);
        app.out.clearRetainingCapacity();
    }
    if (app.grid_changed) {
        app.grid_changed = false;
        pty.setSize(app.winsize());
    }
}

/// Shell > New Window: start another Terminal process (launchd keeps apps
/// single-instance, so spawn our own executable directly).
fn openNewWindow(gpa: std.mem.Allocator) void {
    if (std.os.argv.len == 0) return;
    const exe = std.mem.span(std.os.argv[0]);
    var env: std.ArrayList([]const u8) = .empty;
    defer env.deinit(gpa);
    for (std.os.environ) |e| env.append(gpa, std.mem.span(e)) catch return;
    const devnull = posix.open("null:", .{ .ACCMODE = .RDWR }, 0) catch -1;
    defer if (devnull >= 0) posix.close(devnull);
    _ = zen.sys.spawn(gpa, exe, .{
        .argv = &.{exe},
        .env = env.items,
        .fds = &.{ devnull, devnull, devnull },
        .cwd = posix.getenv("HOME"),
        .new_session = true,
    }) catch |err| zen.sys.logf("Terminal: new window failed: {s}", .{@errorName(err)});
}

/// The shell could not start: show the error until the window is closed.
fn waitForClose(app: *App, win: *ui.Window) void {
    while (!app.quit) {
        app.render(win);
        const events = win.waitEvents(-1);
        if (events.len == 0) break;
        for (events) |e| app.handleEvent(win, e);
    }
}

/// Development host without a window server: run a few commands in the
/// real shell through the pty and save what the terminal shows.
fn hostSnapshot(gpa: std.mem.Allocator, app: *App, win: *ui.Window, shell: []const u8) !void {
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const out_path = if (args.len > 1) args[1] else "/tmp/terminal_host.png";
    const script = if (args.len > 2) args[2] else "echo \"TERM=$TERM size=$(stty size)\"; ls --color=auto /; printf '\\e[1;32mbold green\\e[0m \\e[4munderline\\e[0m \\e[7minverse\\e[0m\\n'; exit\r";
    std.debug.print("Terminal: no window server, running {s} headless -> {s}\n", .{ shell, out_path });

    var pty = try startShell(gpa, app, shell);
    defer pty.close();
    pty.write(script);
    var buf: [16 * 1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        var pfd = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&pfd, 100) catch break;
        if (ready == 0) continue;
        const n = pty.read(&buf);
        if (n == 0) break;
        app.feed(buf[0..n]);
        flushToShell(app, &pty);
    }
    app.full_redraw = true;
    app.render(win);
    try gfx.png.writeFile(gfx.Canvas.init(win.pixels, @intCast(win.width), @intCast(win.height), @intCast(win.width)), out_path);
    std.debug.print("Terminal: {s} ({d}x{d})\n", .{ app.title(), app.cols(), app.rows() });
}

test {
    _ = @import("app.zig");
    _ = pty_mod;
}
