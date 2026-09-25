//! getty — offers a login prompt on a raw terminal device (e.g. `debug:`,
//! the serial console). It allocates a pty, runs `login` on the slave and
//! relays bytes between the device and the pty master, so the full line
//! discipline (echo, Ctrl-C, raw mode for editors) works on the console.
//!
//! Usage: getty <device-url> [rows cols]

const std = @import("std");
const zen = @import("zen");

const posix = std.posix;
const linux = std.os.linux;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

const TIOCGPTN = 0x80045430;
const TIOCSPTLCK = 0x40045431;
const TIOCSWINSZ = 0x5414;

pub fn main() !void {
    zen.sys.setName("getty");
    const args = try std.process.argsAlloc(gpa);
    const dev_path = if (args.len > 1) args[1] else "debug:";
    const rows: u16 = if (args.len > 3) std.fmt.parseInt(u16, args[2], 10) catch 24 else 24;
    const cols: u16 = if (args.len > 3) std.fmt.parseInt(u16, args[3], 10) catch 80 else 80;

    const dev = try posix.open(dev_path, .{ .ACCMODE = .RDWR }, 0);
    const master = try posix.open("pty:ptmx", .{ .ACCMODE = .RDWR }, 0);
    var unlock: i32 = 0;
    _ = linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));
    var n: u32 = 0;
    if (linux.ioctl(master, TIOCGPTN, @intFromPtr(&n)) != 0) return error.NoPty;
    const ws = [4]u16{ rows, cols, 0, 0 };
    _ = linux.ioctl(master, TIOCSWINSZ, @intFromPtr(&ws));

    var name_buf: [32]u8 = undefined;
    const slave_path = try std.fmt.bufPrint(&name_buf, "/dev/pts/{d}", .{n});
    const slave = try posix.open(slave_path, .{ .ACCMODE = .RDWR }, 0);

    _ = posix.write(dev, "\r\n\x1b[1mZen OS\x1b[0m — serial console\r\n\r\n") catch {};
    const login = "/usr/bin/login";
    _ = try zen.sys.spawn(gpa, login, .{
        .argv = &.{login},
        .env = &.{ "TERM=xterm-256color", "PATH=/usr/bin:/bin" },
        .fds = &.{ slave, slave, slave },
        .new_session = true,
    });
    posix.close(slave);

    var buf: [4096]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = dev, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = master, .events = posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        _ = posix.poll(&fds, -1) catch continue;
        if (fds[0].revents & posix.POLL.IN != 0) {
            const got = posix.read(dev, &buf) catch 0;
            if (got > 0) _ = posix.write(master, buf[0..got]) catch {};
        }
        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const got = posix.read(master, &buf) catch 0;
            if (got == 0) break; // login session ended
            _ = posix.write(dev, buf[0..got]) catch {};
        }
    }
}
