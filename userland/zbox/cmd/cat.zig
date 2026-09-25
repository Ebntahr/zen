const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: cat [OPTION]... [FILE]...
    \\Concatenate FILE(s) to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -A, --show-all           equivalent to -vET
    \\  -b, --number-nonblank    number nonempty output lines, overrides -n
    \\  -e                       equivalent to -vE
    \\  -E, --show-ends          display $ at end of each line
    \\  -n, --number             number all output lines
    \\  -s, --squeeze-blank      suppress repeated empty output lines
    \\  -t                       equivalent to -vT
    \\  -T, --show-tabs          display TAB characters as ^I
    \\  -u                       (ignored)
    \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
    \\
;

const Opts = struct {
    number: bool = false,
    nonblank: bool = false,
    ends: bool = false,
    tabs: bool = false,
    nonprint: bool = false,
    squeeze: bool = false,
};

var line_no: u64 = 0;
var prev_blank = false;
var at_line_start = true;

fn catRaw(fd: i32, name: []const u8) bool {
    c.flush();
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.sys.read(fd, &buf) catch |e| {
            c.warn("{f}: {s}", .{ c.qf(name), c.strerror(e) });
            return false;
        };
        if (n == 0) return true;
        c.sys.writeAll(1, buf[0..n]) catch |e| {
            if (e == error.PIPE) c.exit(1);
            c.fatal("write error: {s}", .{c.strerror(e)});
        };
    }
}

fn writeVis(w: *std.Io.Writer, s: []const u8, o: Opts) !void {
    for (s) |ch_in| {
        var ch = ch_in;
        if (ch == '\t') {
            if (o.tabs) try w.writeAll("^I") else try w.writeByte('\t');
            continue;
        }
        if (!o.nonprint) {
            try w.writeByte(ch);
            continue;
        }
        if (ch >= 128) {
            try w.writeAll("M-");
            ch -= 128;
        }
        if (ch < 32) {
            try w.writeByte('^');
            try w.writeByte(ch + 64);
        } else if (ch == 127) {
            try w.writeAll("^?");
        } else try w.writeByte(ch);
    }
}

fn catOpts(fd: i32, name: []const u8, o: Opts) !bool {
    var r = c.LineReader.init(fd);
    defer r.deinit();
    const w = c.out;
    while (true) {
        const line = r.next() catch |e| {
            c.warn("{f}: {s}", .{ c.qf(name), c.strerror(e) });
            return false;
        } orelse break;
        const blank = line.len == 0 and r.had_delim;
        if (at_line_start) {
            if (o.squeeze and blank and prev_blank) continue;
            prev_blank = blank;
            if ((o.number and !o.nonblank) or (o.nonblank and !blank)) {
                line_no += 1;
                var b: [24]u8 = undefined;
                try c.padLeft(w, c.fmtBuf(&b, "{d}", .{line_no}), 6);
                try w.writeByte('\t');
            }
        }
        try writeVis(w, line, o);
        if (r.had_delim) {
            if (o.ends) try w.writeByte('$');
            try w.writeByte('\n');
            at_line_start = true;
        } else at_line_start = false;
    }
    return true;
}

pub fn main(args: c.Args) !u8 {
    var o: Opts = .{};
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "show-all", 'A' },      .{ "number-nonblank", 'b' }, .{ "show-ends", 'E' },
        .{ "number", 'n' },        .{ "squeeze-blank", 's' },   .{ "show-tabs", 'T' },
        .{ "show-nonprinting", 'v' },
    });
    while (p.next()) |opt| switch (opt) {
        .short => |ch| switch (ch) {
            'A' => {
                o.nonprint = true;
                o.ends = true;
                o.tabs = true;
            },
            'b' => {
                o.nonblank = true;
                o.number = true;
            },
            'e' => {
                o.nonprint = true;
                o.ends = true;
            },
            'E' => o.ends = true,
            'n' => o.number = true,
            's' => o.squeeze = true,
            't' => {
                o.nonprint = true;
                o.tabs = true;
            },
            'T' => o.tabs = true,
            'u' => {},
            'v' => o.nonprint = true,
            else => p.bad(opt),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(opt),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    const plain = !(o.number or o.ends or o.tabs or o.nonprint or o.squeeze);
    var status: u8 = 0;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        const ok = if (plain) catRaw(fd, f) else try catOpts(fd, f, o);
        if (!ok) status = 1;
    }
    return status;
}
