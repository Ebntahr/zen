const std = @import("std");
const c = @import("../common.zig");
const linux = std.os.linux;
const mem = std.mem;

pub const help =
    \\Usage: stty [-F DEVICE | --file=DEVICE] [SETTING]...
    \\  or:  stty [-F DEVICE | --file=DEVICE] [-a|--all]
    \\  or:  stty [-F DEVICE | --file=DEVICE] [-g|--save]
    \\Print or change terminal characteristics.
    \\
    \\  -a, --all          print all current settings in human-readable form
    \\  -g, --save         print all current settings in a stty-readable form
    \\  -F, --file=DEVICE  open and use the specified DEVICE instead of stdin
    \\
    \\Special settings:
    \\  size             print the number of rows and columns
    \\  rows N           tell the kernel that the terminal has N rows
    \\  cols N, columns N  tell the kernel that the terminal has N columns
    \\  speed            print the terminal speed
    \\  N                set the input and output speeds to N bauds
    \\  line N           use line discipline N
    \\  min N / time N   with -icanon, read timing parameters
    \\  intr/quit/erase/kill/eof/eol/start/stop/susp/werase/lnext CHAR
    \\
    \\Combination settings:
    \\  raw / -raw       raw mode on/off (-raw is the same as cooked)
    \\  cooked           same as -raw
    \\  cbreak / -cbreak same as -icanon / icanon
    \\  sane             reset all special characters and modes to sane values
    \\  nl / -nl         newline translation
    \\
    \\Local, input, output and control flags (prefix with - to disable):
    \\  isig icanon iexten echo echoe echok echonl noflsh tostop echoctl echoke
    \\  ignbrk brkint ignpar parmrk inpck istrip inlcr igncr icrnl ixon ixoff
    \\  ixany imaxbel iutf8 opost onlcr ocrnl onocr onlret parenb parodd cstopb
    \\  cread clocal hupcl crtscts cs5 cs6 cs7 cs8
    \\
;

pub const KTermios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [19]u8,
};

const TCGETS: u32 = 0x5401;
const TCSETSW: u32 = 0x5403;

pub fn getattr(fd: i32) c.SysError!KTermios {
    var t: KTermios = undefined;
    _ = try c.sys.ioctl(fd, TCGETS, @intFromPtr(&t));
    return t;
}
pub fn setattr(fd: i32, t: *const KTermios) c.SysError!void {
    _ = try c.sys.ioctl(fd, TCSETSW, @intFromPtr(t));
}

const Kind = enum { i, o, c_, l };
const Flag = struct { name: []const u8, kind: Kind, mask: u32, sane: ?bool, show: bool = true };

const flags = [_]Flag{
    // control
    .{ .name = "parenb", .kind = .c_, .mask = 0o400, .sane = false },
    .{ .name = "parodd", .kind = .c_, .mask = 0o1000, .sane = false },
    .{ .name = "cmspar", .kind = .c_, .mask = 0o10000000000, .sane = false },
    .{ .name = "hupcl", .kind = .c_, .mask = 0o2000, .sane = null },
    .{ .name = "cstopb", .kind = .c_, .mask = 0o100, .sane = false },
    .{ .name = "cread", .kind = .c_, .mask = 0o200, .sane = true },
    .{ .name = "clocal", .kind = .c_, .mask = 0o4000, .sane = null },
    .{ .name = "crtscts", .kind = .c_, .mask = 0o20000000000, .sane = null },
    // input
    .{ .name = "ignbrk", .kind = .i, .mask = 0o1, .sane = false },
    .{ .name = "brkint", .kind = .i, .mask = 0o2, .sane = true },
    .{ .name = "ignpar", .kind = .i, .mask = 0o4, .sane = false },
    .{ .name = "parmrk", .kind = .i, .mask = 0o10, .sane = false },
    .{ .name = "inpck", .kind = .i, .mask = 0o20, .sane = false },
    .{ .name = "istrip", .kind = .i, .mask = 0o40, .sane = false },
    .{ .name = "inlcr", .kind = .i, .mask = 0o100, .sane = false },
    .{ .name = "igncr", .kind = .i, .mask = 0o200, .sane = false },
    .{ .name = "icrnl", .kind = .i, .mask = 0o400, .sane = true },
    .{ .name = "ixon", .kind = .i, .mask = 0o2000, .sane = true },
    .{ .name = "ixoff", .kind = .i, .mask = 0o10000, .sane = false },
    .{ .name = "iuclc", .kind = .i, .mask = 0o1000, .sane = false },
    .{ .name = "ixany", .kind = .i, .mask = 0o4000, .sane = false },
    .{ .name = "imaxbel", .kind = .i, .mask = 0o20000, .sane = true },
    .{ .name = "iutf8", .kind = .i, .mask = 0o40000, .sane = null },
    // output
    .{ .name = "opost", .kind = .o, .mask = 0o1, .sane = true },
    .{ .name = "olcuc", .kind = .o, .mask = 0o2, .sane = false },
    .{ .name = "ocrnl", .kind = .o, .mask = 0o10, .sane = false },
    .{ .name = "onlcr", .kind = .o, .mask = 0o4, .sane = true },
    .{ .name = "onocr", .kind = .o, .mask = 0o20, .sane = false },
    .{ .name = "onlret", .kind = .o, .mask = 0o40, .sane = false },
    .{ .name = "ofill", .kind = .o, .mask = 0o100, .sane = false },
    .{ .name = "ofdel", .kind = .o, .mask = 0o200, .sane = false },
    // local
    .{ .name = "isig", .kind = .l, .mask = 0o1, .sane = true },
    .{ .name = "icanon", .kind = .l, .mask = 0o2, .sane = true },
    .{ .name = "iexten", .kind = .l, .mask = 0o100000, .sane = true },
    .{ .name = "echo", .kind = .l, .mask = 0o10, .sane = true },
    .{ .name = "echoe", .kind = .l, .mask = 0o20, .sane = true },
    .{ .name = "echok", .kind = .l, .mask = 0o40, .sane = true },
    .{ .name = "echonl", .kind = .l, .mask = 0o100, .sane = false },
    .{ .name = "noflsh", .kind = .l, .mask = 0o200, .sane = false },
    .{ .name = "xcase", .kind = .l, .mask = 0o4, .sane = false },
    .{ .name = "tostop", .kind = .l, .mask = 0o400, .sane = false },
    .{ .name = "echoprt", .kind = .l, .mask = 0o2000, .sane = false },
    .{ .name = "echoctl", .kind = .l, .mask = 0o1000, .sane = true },
    .{ .name = "echoke", .kind = .l, .mask = 0o4000, .sane = true },
    .{ .name = "flusho", .kind = .l, .mask = 0o10000, .sane = false },
    .{ .name = "extproc", .kind = .l, .mask = 0o200000, .sane = false },
};

const CC = struct { name: []const u8, idx: usize, sane: u8 };
const ccs = [_]CC{
    .{ .name = "intr", .idx = 0, .sane = 3 },     .{ .name = "quit", .idx = 1, .sane = 0x1c },
    .{ .name = "erase", .idx = 2, .sane = 0x7f }, .{ .name = "kill", .idx = 3, .sane = 0x15 },
    .{ .name = "eof", .idx = 4, .sane = 4 },      .{ .name = "eol", .idx = 11, .sane = 0 },
    .{ .name = "eol2", .idx = 16, .sane = 0 },    .{ .name = "swtch", .idx = 7, .sane = 0 },
    .{ .name = "start", .idx = 8, .sane = 0x11 }, .{ .name = "stop", .idx = 9, .sane = 0x13 },
    .{ .name = "susp", .idx = 10, .sane = 0x1a }, .{ .name = "rprnt", .idx = 12, .sane = 0x12 },
    .{ .name = "werase", .idx = 14, .sane = 0x17 }, .{ .name = "lnext", .idx = 15, .sane = 0x16 },
    .{ .name = "discard", .idx = 13, .sane = 0x0f },
};

fn field(t: *KTermios, k: Kind) *u32 {
    return switch (k) {
        .i => &t.iflag,
        .o => &t.oflag,
        .c_ => &t.cflag,
        .l => &t.lflag,
    };
}

const bauds = [_]struct { u32, u32 }{
    .{ 0, 0 },         .{ 1, 50 },          .{ 2, 75 },          .{ 3, 110 },         .{ 4, 134 },
    .{ 5, 150 },       .{ 6, 200 },         .{ 7, 300 },         .{ 8, 600 },         .{ 9, 1200 },
    .{ 10, 1800 },     .{ 11, 2400 },       .{ 12, 4800 },       .{ 13, 9600 },       .{ 14, 19200 },
    .{ 15, 38400 },    .{ 0o10001, 57600 }, .{ 0o10002, 115200 }, .{ 0o10003, 230400 }, .{ 0o10004, 460800 },
    .{ 0o10005, 500000 }, .{ 0o10006, 576000 }, .{ 0o10007, 921600 }, .{ 0o10010, 1000000 }, .{ 0o10011, 1152000 },
    .{ 0o10012, 1500000 }, .{ 0o10013, 2000000 }, .{ 0o10014, 2500000 }, .{ 0o10015, 3000000 }, .{ 0o10016, 3500000 },
    .{ 0o10017, 4000000 },
};
const CBAUD: u32 = 0o10017;

fn speedOf(t: KTermios) u32 {
    const code = t.cflag & CBAUD;
    for (bauds) |b| if (b[0] == code) return b[1];
    return 0;
}

fn ccName(buf: []u8, v: u8) []const u8 {
    if (v == 0) return "<undef>";
    if (v == 0x7f) return "^?";
    if (v < 32) return c.fmtBuf(buf, "^{c}", .{v + 64});
    if (v >= 128) return c.fmtBuf(buf, "M-{c}", .{v - 128});
    return c.fmtBuf(buf, "{c}", .{v});
}

fn parseCC(s: []const u8) ?u8 {
    if (s.len == 1) return s[0];
    if (c.eql(s, "^-") or c.eql(s, "undef")) return 0;
    if (s.len == 2 and s[0] == '^') {
        if (s[1] == '?') return 0x7f;
        return std.ascii.toUpper(s[1]) & 0x1f;
    }
    if (c.parseUint(s)) |n| return @truncate(n);
    return null;
}

pub fn makeSane(fd: i32) c.SysError!void {
    var t = try getattr(fd);
    for (flags) |f| {
        const sv = f.sane orelse continue;
        const p = field(&t, f.kind);
        if (sv) p.* |= f.mask else p.* &= ~f.mask;
    }
    t.cflag = (t.cflag & ~@as(u32, 0o60)) | 0o60; // cs8
    for (ccs) |cc| t.cc[cc.idx] = cc.sane;
    t.cc[6] = 1; // min
    t.cc[5] = 0; // time
    try setattr(fd, &t);
}

fn setRaw(t: *KTermios, on: bool) void {
    if (on) {
        t.iflag &= ~@as(u32, 0o1 | 0o2 | 0o4 | 0o10 | 0o20 | 0o40 | 0o100 | 0o200 | 0o400 | 0o2000 | 0o10000 | 0o1000 | 0o4000 | 0o20000);
        t.oflag &= ~@as(u32, 0o1);
        t.lflag &= ~@as(u32, 0o1 | 0o2 | 0o4 | 0o100000);
        t.cflag = (t.cflag & ~@as(u32, 0o60 | 0o400)) | 0o60;
        t.cc[6] = 1;
        t.cc[5] = 0;
    } else {
        t.iflag |= 0o2 | 0o4 | 0o40 | 0o400 | 0o2000;
        t.oflag |= 0o1;
        t.lflag |= 0o1 | 0o2;
        t.cc[4] = 4;
        t.cc[11] = 0;
    }
}

fn printSettings(w: *std.Io.Writer, t: KTermios, fd: i32, all: bool) !void {
    var nb: [16]u8 = undefined;
    try w.print("speed {d} baud; ", .{speedOf(t)});
    if (all) {
        if (c.winSize(fd)) |ws| try w.print("rows {d}; columns {d}; ", .{ ws.row, ws.col });
    }
    try w.print("line = {d};\n", .{t.line});
    var tt = t;
    if (all) {
        var col: usize = 0;
        for (ccs) |cc| {
            var tmp: [32]u8 = undefined;
            const item = c.fmtBuf(&tmp, "{s} = {s};", .{ cc.name, ccName(&nb, t.cc[cc.idx]) });
            if (col > 0 and col + item.len + 1 > 80) {
                try w.writeByte('\n');
                col = 0;
            } else if (col > 0) {
                try w.writeByte(' ');
                col += 1;
            }
            try w.writeAll(item);
            col += item.len;
        }
        try w.print(" min = {d}; time = {d};\n", .{ t.cc[6], t.cc[5] });
    } else {
        var any = false;
        for (ccs) |cc| {
            if (t.cc[cc.idx] != cc.sane) {
                try w.print("{s} = {s}; ", .{ cc.name, ccName(&nb, t.cc[cc.idx]) });
                any = true;
            }
        }
        if (t.lflag & 0o2 == 0) {
            try w.print("min = {d}; time = {d};", .{ t.cc[6], t.cc[5] });
            any = true;
        }
        if (any) try w.writeByte('\n');
    }
    const kinds = [_]Kind{ .c_, .i, .o, .l };
    for (kinds) |k| {
        var line_any = false;
        var col: usize = 0;
        for (flags) |f| {
            if (f.kind != k) continue;
            const on = field(&tt, k).* & f.mask != 0;
            if (!all) {
                const sv = f.sane orelse continue;
                if (sv == on) continue;
            }
            const text = if (on) f.name else c.fmtBuf(&nb, "-{s}", .{f.name});
            if (line_any) {
                if (col + text.len + 1 > 80) {
                    try w.writeByte('\n');
                    col = 0;
                } else {
                    try w.writeByte(' ');
                    col += 1;
                }
            }
            try w.writeAll(text);
            col += text.len;
            line_any = true;
            if (k == .o and c.eql(f.name, "ofdel") and all) {
                const o = t.oflag;
                try w.print(" nl{d} cr{d} tab{d} bs{d} vt{d} ff{d}", .{ (o >> 8) & 1, (o >> 9) & 3, (o >> 11) & 3, (o >> 13) & 1, (o >> 14) & 1, (o >> 15) & 1 });
                col += 24;
            }
            if (k == .c_ and c.eql(f.name, "cmspar") and all) {
                const cs = (t.cflag & 0o60) >> 4;
                try w.print(" cs{d}", .{cs + 5});
                col += 4;
            }
        }
        if (line_any) try w.writeByte('\n');
    }
}

pub fn main(args: c.Args) !u8 {
    var fd: i32 = 0;
    var all = false;
    var save = false;
    var settings: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (c.eql(a, "--help")) c.printHelp();
        if (c.eql(a, "--version")) c.printVersion();
        if (c.eql(a, "-a") or c.eql(a, "--all")) {
            all = true;
        } else if (c.eql(a, "-g") or c.eql(a, "--save")) {
            save = true;
        } else if (c.eql(a, "-F") or c.eql(a, "--file")) {
            i += 1;
            if (i >= args.len) c.usageErr("option requires an argument -- 'F'", .{});
            fd = c.sys.open(args[i], .{ .ACCMODE = .RDWR, .NONBLOCK = true, .NOCTTY = true }, 0) catch |e| c.fatal("{s}: {s}", .{ args[i], c.strerror(e) });
        } else if (mem.startsWith(u8, a, "--file=")) {
            fd = c.sys.open(a[7..], .{ .ACCMODE = .RDWR, .NONBLOCK = true, .NOCTTY = true }, 0) catch |e| c.fatal("{s}: {s}", .{ a[7..], c.strerror(e) });
        } else if (mem.startsWith(u8, a, "-F")) {
            fd = c.sys.open(a[2..], .{ .ACCMODE = .RDWR, .NONBLOCK = true, .NOCTTY = true }, 0) catch |e| c.fatal("{s}: {s}", .{ a[2..], c.strerror(e) });
        } else try settings.append(c.gpa, a);
    }
    var t = getattr(fd) catch |e| c.fatal("'standard input': {s}", .{c.strerror(e)});
    const w = c.out;
    if (save) {
        try w.print("{x}:{x}:{x}:{x}", .{ t.iflag, t.oflag, t.cflag, t.lflag });
        for (t.cc) |x| try w.print(":{x}", .{x});
        var z: usize = t.cc.len;
        while (z < 32) : (z += 1) try w.writeAll(":0");
        try w.writeByte('\n');
        return 0;
    }
    if (settings.items.len == 0) {
        try printSettings(w, t, fd, all);
        return 0;
    }
    var changed = false;
    var k: usize = 0;
    while (k < settings.items.len) : (k += 1) {
        const s = settings.items[k];
        const nextArg = struct {
            fn f(list: []const []const u8, idx: *usize, name: []const u8) []const u8 {
                idx.* += 1;
                if (idx.* >= list.len) c.usageErr("missing argument to {f}", .{c.q(name)});
                return list[idx.*];
            }
        }.f;
        if (c.eql(s, "size")) {
            const ws = c.winSize(fd) orelse c.fatal("'standard input': unable to perform all requested operations", .{});
            try w.print("{d} {d}\n", .{ ws.row, ws.col });
            continue;
        }
        if (c.eql(s, "speed")) {
            try w.print("{d}\n", .{speedOf(t)});
            continue;
        }
        if (c.eql(s, "rows") or c.eql(s, "cols") or c.eql(s, "columns")) {
            const v = nextArg(settings.items, &k, s);
            const n = c.parseUint(v) orelse c.usageErr("invalid integer argument {f}", .{c.q(v)});
            var ws = c.winSize(fd) orelse std.posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            if (s[0] == 'r') ws.row = @intCast(n) else ws.col = @intCast(n);
            _ = c.sys.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)) catch |e| c.fatal("{s}", .{c.strerror(e)});
            continue;
        }
        if (c.eql(s, "line")) {
            t.line = @truncate(c.parseUint(nextArg(settings.items, &k, s)) orelse 0);
            changed = true;
            continue;
        }
        if (c.eql(s, "min") or c.eql(s, "time")) {
            const v = nextArg(settings.items, &k, s);
            t.cc[if (s[0] == 'm') 6 else 5] = @truncate(c.parseUint(v) orelse c.usageErr("invalid integer argument {f}", .{c.q(v)}));
            changed = true;
            continue;
        }
        if (c.eql(s, "raw") or c.eql(s, "-cooked")) {
            setRaw(&t, true);
            changed = true;
            continue;
        }
        if (c.eql(s, "-raw") or c.eql(s, "cooked")) {
            setRaw(&t, false);
            changed = true;
            continue;
        }
        if (c.eql(s, "cbreak")) {
            t.lflag &= ~@as(u32, 0o2);
            changed = true;
            continue;
        }
        if (c.eql(s, "-cbreak")) {
            t.lflag |= 0o2;
            changed = true;
            continue;
        }
        if (c.eql(s, "nl")) {
            t.iflag &= ~@as(u32, 0o400);
            t.oflag &= ~@as(u32, 0o4);
            changed = true;
            continue;
        }
        if (c.eql(s, "-nl")) {
            t.iflag |= 0o400;
            t.iflag &= ~@as(u32, 0o100 | 0o200);
            t.oflag |= 0o4;
            changed = true;
            continue;
        }
        if (c.eql(s, "sane")) {
            try setattr(fd, &t);
            makeSane(fd) catch |e| c.fatal("{s}", .{c.strerror(e)});
            t = try getattr(fd);
            continue;
        }
        if (c.eql(s, "cs5") or c.eql(s, "cs6") or c.eql(s, "cs7") or c.eql(s, "cs8")) {
            t.cflag = (t.cflag & ~@as(u32, 0o60)) | (@as(u32, s[2] - '5') << 4);
            changed = true;
            continue;
        }
        if (c.eql(s, "ispeed") or c.eql(s, "ospeed")) {
            const v = nextArg(settings.items, &k, s);
            const n = c.parseUint(v) orelse c.usageErr("invalid integer argument {f}", .{c.q(v)});
            for (bauds) |b| if (b[1] == n) {
                t.cflag = (t.cflag & ~CBAUD) | b[0];
            };
            changed = true;
            continue;
        }
        if (c.parseUint(s)) |n| {
            var ok = false;
            for (bauds) |b| if (b[1] == n) {
                t.cflag = (t.cflag & ~CBAUD) | b[0];
                ok = true;
            };
            if (!ok) c.usageErr("invalid argument {f}", .{c.q(s)});
            changed = true;
            continue;
        }
        // saved format from -g
        if (mem.count(u8, s, ":") >= 4) {
            var it = mem.splitScalar(u8, s, ':');
            var vals: [21]u32 = undefined;
            var n: usize = 0;
            while (it.next()) |x| : (n += 1) {
                if (n >= vals.len) break;
                vals[n] = std.fmt.parseInt(u32, x, 16) catch c.usageErr("invalid argument {f}", .{c.q(s)});
            }
            if (n < 4) c.usageErr("invalid argument {f}", .{c.q(s)});
            t.iflag = vals[0];
            t.oflag = vals[1];
            t.cflag = vals[2];
            t.lflag = vals[3];
            var j: usize = 4;
            while (j < n and j - 4 < t.cc.len) : (j += 1) t.cc[j - 4] = @truncate(vals[j]);
            changed = true;
            continue;
        }
        var matched = false;
        for (ccs) |cc| {
            if (c.eql(s, cc.name)) {
                const v = nextArg(settings.items, &k, s);
                t.cc[cc.idx] = parseCC(v) orelse c.usageErr("invalid integer argument {f}", .{c.q(v)});
                matched = true;
                break;
            }
        }
        if (!matched) {
            const neg = s.len > 1 and s[0] == '-';
            const name = if (neg) s[1..] else s;
            for (flags) |f| {
                if (c.eql(f.name, name)) {
                    const p = field(&t, f.kind);
                    if (neg) p.* &= ~f.mask else p.* |= f.mask;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) c.usageErr("invalid argument {f}", .{c.q(s)});
        changed = true;
    }
    if (changed) setattr(fd, &t) catch |e| c.fatal("'standard input': {s}", .{c.strerror(e)});
    return 0;
}
