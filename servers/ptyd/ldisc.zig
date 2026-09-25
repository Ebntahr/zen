//! POSIX terminal line discipline (termios semantics), independent of I/O.
//!
//! Input written by the terminal emulator (master side) passes through
//! `input()`: CR/NL translation, signal characters, canonical line editing
//! and echo. Output written by programs (slave side) passes through
//! `output()`: NL → CR NL translation. The owner moves bytes between the
//! queues and the clients.

const std = @import("std");

// termios c_iflag
pub const IGNBRK: u32 = 0o1;
pub const BRKINT: u32 = 0o2;
pub const IGNPAR: u32 = 0o4;
pub const ISTRIP: u32 = 0o40;
pub const INLCR: u32 = 0o100;
pub const IGNCR: u32 = 0o200;
pub const ICRNL: u32 = 0o400;
pub const IXON: u32 = 0o2000;
pub const IMAXBEL: u32 = 0o20000;
pub const IUTF8: u32 = 0o40000;
// c_oflag
pub const OPOST: u32 = 0o1;
pub const ONLCR: u32 = 0o4;
pub const OCRNL: u32 = 0o10;
// c_cflag
pub const CS8: u32 = 0o60;
pub const CREAD: u32 = 0o200;
pub const B38400: u32 = 0o17;
// c_lflag
pub const ISIG: u32 = 0o1;
pub const ICANON: u32 = 0o2;
pub const ECHO: u32 = 0o10;
pub const ECHOE: u32 = 0o20;
pub const ECHOK: u32 = 0o40;
pub const ECHONL: u32 = 0o100;
pub const NOFLSH: u32 = 0o200;
pub const TOSTOP: u32 = 0o400;
pub const ECHOCTL: u32 = 0o1000;
pub const ECHOKE: u32 = 0o4000;
pub const IEXTEN: u32 = 0o100000;

// c_cc indices
pub const VINTR = 0;
pub const VQUIT = 1;
pub const VERASE = 2;
pub const VKILL = 3;
pub const VEOF = 4;
pub const VTIME = 5;
pub const VMIN = 6;
pub const VSTART = 8;
pub const VSTOP = 9;
pub const VSUSP = 10;
pub const VEOL = 11;
pub const VREPRINT = 12;
pub const VWERASE = 14;
pub const VLNEXT = 15;
pub const VEOL2 = 16;
pub const NCCS = 19;

/// The kernel `struct termios` used by the TCGETS/TCSETS ioctls (36 bytes).
pub const Termios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [NCCS]u8,

    pub const default = Termios{
        .iflag = ICRNL | IXON | IUTF8,
        .oflag = OPOST | ONLCR,
        .cflag = B38400 | CS8 | CREAD,
        .lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN,
        .line = 0,
        .cc = .{ 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0 },
    };
};

comptime {
    std.debug.assert(@sizeOf(Termios) == 36);
}

pub const Winsize = extern struct {
    rows: u16 = 24,
    cols: u16 = 80,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const Signal = enum(u8) { none = 0, hup = 1, int = 2, quit = 3, tstp = 20, winch = 28 };

/// Fixed-capacity byte FIFO.
pub fn Ring(comptime cap: usize) type {
    return struct {
        const Self = @This();
        data: [cap]u8 = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn free(self: *const Self) usize {
            return cap - self.len;
        }
        pub fn push(self: *Self, c: u8) bool {
            if (self.len == cap) return false;
            self.data[(self.head + self.len) % cap] = c;
            self.len += 1;
            return true;
        }
        pub fn pushSlice(self: *Self, s: []const u8) usize {
            var n: usize = 0;
            for (s) |c| {
                if (!self.push(c)) break;
                n += 1;
            }
            return n;
        }
        pub fn pop(self: *Self, out: []u8) usize {
            const n = @min(out.len, self.len);
            for (out[0..n], 0..) |*o, i| o.* = self.data[(self.head + i) % cap];
            self.head = (self.head + n) % cap;
            self.len -= n;
            return n;
        }
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }
    };
}

pub const INPUT_CAP = 4096;
pub const OUTPUT_CAP = 64 * 1024;
const MAX_LINES = 256;

pub const Ldisc = struct {
    termios: Termios = Termios.default,
    winsize: Winsize = .{},
    /// Input ready for the slave reader.
    cooked: Ring(INPUT_CAP) = .{},
    /// Canonical mode: length of each committed line in `cooked`
    /// (0 = an end-of-file mark).
    lines: [MAX_LINES]u32 = undefined,
    line_head: usize = 0,
    line_count: usize = 0,
    /// Canonical mode line being edited.
    edit: [INPUT_CAP]u8 = undefined,
    edit_len: usize = 0,
    /// Output ready for the master reader (program output + echo).
    out: Ring(OUTPUT_CAP) = .{},
    lnext: bool = false,

    pub fn canonical(self: *const Ldisc) bool {
        return self.termios.lflag & ICANON != 0;
    }

    fn echoOn(self: *const Ldisc) bool {
        return self.termios.lflag & ECHO != 0;
    }

    /// Bytes the slave can read right now (or an EOF mark is pending).
    pub fn slaveReadable(self: *const Ldisc) bool {
        if (self.canonical()) return self.line_count > 0;
        return self.cooked.len > 0;
    }

    pub fn slaveAvailable(self: *const Ldisc) usize {
        if (self.canonical()) {
            if (self.line_count == 0) return 0;
            return self.lines[self.line_head];
        }
        return self.cooked.len;
    }

    pub fn masterReadable(self: *const Ldisc) bool {
        return self.out.len > 0;
    }

    /// Emit echo output (with output processing).
    fn echoBytes(self: *Ldisc, s: []const u8) void {
        _ = self.output(s);
    }

    fn echoChar(self: *Ldisc, c: u8) void {
        if (!self.echoOn()) {
            if (c == '\n' and self.termios.lflag & ECHONL != 0 and self.canonical()) self.echoBytes("\n");
            return;
        }
        if (self.termios.lflag & ECHOCTL != 0 and c < 0x20 and c != '\n' and c != '\t') {
            self.echoBytes(&.{ '^', c + 0x40 });
        } else if (c == 0x7f and self.termios.lflag & ECHOCTL != 0) {
            self.echoBytes("^?");
        } else {
            self.echoBytes(&.{c});
        }
    }

    fn commitLine(self: *Ldisc, include_eol: bool, eol: u8) void {
        if (self.line_count == MAX_LINES) return;
        var n: usize = 0;
        n += self.cooked.pushSlice(self.edit[0..self.edit_len]);
        if (include_eol and self.cooked.push(eol)) n += 1;
        self.lines[(self.line_head + self.line_count) % MAX_LINES] = @intCast(n);
        self.line_count += 1;
        self.edit_len = 0;
    }

    fn eraseOne(self: *Ldisc) void {
        if (self.edit_len == 0) return;
        // Remove one UTF-8 character.
        var n: usize = 1;
        while (n < self.edit_len and (self.edit[self.edit_len - n] & 0xC0) == 0x80) n += 1;
        const was_ctrl = self.edit[self.edit_len - n] < 0x20;
        self.edit_len -= n;
        if (self.echoOn() and self.termios.lflag & ECHOE != 0) {
            self.echoBytes("\x08 \x08");
            if (was_ctrl and self.termios.lflag & ECHOCTL != 0) self.echoBytes("\x08 \x08");
        }
    }

    /// Process bytes typed on the keyboard (written to the master).
    /// Returns the signal to deliver to the foreground process group.
    pub fn input(self: *Ldisc, bytes: []const u8) Signal {
        var sig: Signal = .none;
        const t = &self.termios;
        for (bytes) |raw| {
            var c = raw;
            if (t.iflag & ISTRIP != 0) c &= 0x7f;
            if (self.lnext) {
                self.lnext = false;
                self.addChar(c);
                continue;
            }
            if (c == '\r') {
                if (t.iflag & IGNCR != 0) continue;
                if (t.iflag & ICRNL != 0) c = '\n';
            } else if (c == '\n' and t.iflag & INLCR != 0) {
                c = '\r';
            }
            if (t.lflag & ISIG != 0) {
                const s: Signal = if (c == t.cc[VINTR] and c != 0) .int else if (c == t.cc[VQUIT] and c != 0) .quit else if (c == t.cc[VSUSP] and c != 0) .tstp else .none;
                if (s != .none) {
                    if (t.lflag & NOFLSH == 0) {
                        self.edit_len = 0;
                        self.cooked.clear();
                        self.line_count = 0;
                    }
                    self.echoChar(c);
                    sig = s;
                    continue;
                }
            }
            if (t.lflag & IEXTEN != 0 and c == t.cc[VLNEXT] and c != 0 and self.canonical()) {
                self.lnext = true;
                continue;
            }
            if (self.canonical()) {
                if (c == t.cc[VERASE] or c == 0x08) {
                    self.eraseOne();
                    continue;
                }
                if (c == t.cc[VWERASE] and t.lflag & IEXTEN != 0) {
                    while (self.edit_len > 0 and self.edit[self.edit_len - 1] == ' ') self.eraseOne();
                    while (self.edit_len > 0 and self.edit[self.edit_len - 1] != ' ') self.eraseOne();
                    continue;
                }
                if (c == t.cc[VKILL]) {
                    while (self.edit_len > 0) self.eraseOne();
                    continue;
                }
                if (c == t.cc[VEOF]) {
                    self.commitLine(false, 0);
                    continue;
                }
                if (c == t.cc[VREPRINT] and t.lflag & IEXTEN != 0) {
                    self.echoBytes("^R\n");
                    self.echoBytes(self.edit[0..self.edit_len]);
                    continue;
                }
                if (c == '\n' or (c == t.cc[VEOL] and c != 0) or (c == t.cc[VEOL2] and c != 0)) {
                    self.echoChar(c);
                    self.commitLine(true, c);
                    continue;
                }
            }
            self.addChar(c);
        }
        return sig;
    }

    fn addChar(self: *Ldisc, c: u8) void {
        if (self.canonical()) {
            if (self.edit_len < self.edit.len - 1) {
                self.edit[self.edit_len] = c;
                self.edit_len += 1;
                self.echoChar(c);
            }
        } else {
            if (self.cooked.push(c)) self.echoChar(c);
        }
    }

    /// Read input for the slave. Returns 0 for an EOF mark in canonical mode.
    pub fn readSlave(self: *Ldisc, buf: []u8) usize {
        if (!self.canonical()) return self.cooked.pop(buf);
        if (self.line_count == 0) return 0;
        const avail = self.lines[self.line_head];
        const n = self.cooked.pop(buf[0..@min(buf.len, avail)]);
        if (n == avail) {
            self.line_head = (self.line_head + 1) % MAX_LINES;
            self.line_count -= 1;
        } else {
            self.lines[self.line_head] = @intCast(avail - n);
        }
        return n;
    }

    /// Program output (written to the slave). Returns bytes consumed.
    pub fn output(self: *Ldisc, bytes: []const u8) usize {
        const t = &self.termios;
        const post = t.oflag & OPOST != 0;
        var n: usize = 0;
        for (bytes) |c| {
            if (post and c == '\n' and t.oflag & ONLCR != 0) {
                if (self.out.free() < 2) break;
                _ = self.out.push('\r');
                _ = self.out.push('\n');
            } else if (post and c == '\r' and t.oflag & OCRNL != 0) {
                if (!self.out.push('\n')) break;
            } else {
                if (!self.out.push(c)) break;
            }
            n += 1;
        }
        return n;
    }

    pub fn readMaster(self: *Ldisc, buf: []u8) usize {
        return self.out.pop(buf);
    }

    /// Switching out of canonical mode makes a partially edited line
    /// available immediately.
    pub fn setTermios(self: *Ldisc, t: Termios) void {
        const was_canon = self.canonical();
        self.termios = t;
        if (was_canon and !self.canonical()) {
            _ = self.cooked.pushSlice(self.edit[0..self.edit_len]);
            self.edit_len = 0;
            self.line_count = 0;
        } else if (!was_canon and self.canonical()) {
            self.line_count = 0;
            if (self.cooked.len > 0) {
                self.lines[self.line_head] = @intCast(self.cooked.len);
                self.line_count = 1;
            }
        }
    }

    pub fn flushInput(self: *Ldisc) void {
        self.cooked.clear();
        self.edit_len = 0;
        self.line_count = 0;
    }

    pub fn flushOutput(self: *Ldisc) void {
        self.out.clear();
    }
};

fn readAllMaster(l: *Ldisc, buf: []u8) []u8 {
    return buf[0..l.readMaster(buf)];
}

test "canonical line editing and echo" {
    var l = Ldisc{};
    try std.testing.expectEqual(Signal.none, l.input("helo\x7flo\r"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("helo\x08 \x08lo\r\n", readAllMaster(&l, &buf));
    try std.testing.expect(l.slaveReadable());
    const n = l.readSlave(&buf);
    try std.testing.expectEqualStrings("hello\n", buf[0..n]);
    try std.testing.expect(!l.slaveReadable());
}

test "ctrl-c raises SIGINT and flushes" {
    var l = Ldisc{};
    try std.testing.expectEqual(Signal.int, l.input("abc\x03"));
    try std.testing.expect(!l.slaveReadable());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc^C", readAllMaster(&l, &buf));
}

test "eof on empty line" {
    var l = Ldisc{};
    _ = l.input("\x04");
    try std.testing.expect(l.slaveReadable());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), l.readSlave(&buf));
    try std.testing.expect(!l.slaveReadable());
}

test "raw mode passes bytes through" {
    var l = Ldisc{};
    var t = Termios.default;
    t.lflag &= ~(ICANON | ECHO | ISIG);
    t.iflag &= ~ICRNL;
    l.setTermios(t);
    try std.testing.expectEqual(Signal.none, l.input("a\x03\r"));
    var buf: [8]u8 = undefined;
    const n = l.readSlave(&buf);
    try std.testing.expectEqualStrings("a\x03\r", buf[0..n]);
    try std.testing.expect(!l.masterReadable());
}

test "output onlcr" {
    var l = Ldisc{};
    _ = l.output("a\nb");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a\r\nb", readAllMaster(&l, &buf));
}

test "partial canonical reads" {
    var l = Ldisc{};
    _ = l.input("abcdef\n");
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), l.readSlave(&buf));
    try std.testing.expectEqualStrings("abc", &buf);
    try std.testing.expectEqual(@as(usize, 3), l.readSlave(&buf));
    try std.testing.expectEqualStrings("def", &buf);
    try std.testing.expectEqual(@as(usize, 1), l.readSlave(&buf));
    try std.testing.expect(!l.slaveReadable());
}
