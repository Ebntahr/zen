const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: wc [OPTION]... [FILE]...
    \\Print newline, word, and byte counts for each FILE, and a total line if
    \\more than one FILE is specified.  A word is a nonempty sequence of non white
    \\space delimited by white space characters or by start or end of input.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -c, --bytes            print the byte counts
    \\  -m, --chars            print the character counts
    \\  -l, --lines            print the newline counts
    \\  -L, --max-line-length  print the maximum display width
    \\  -w, --words            print the word counts
    \\
;

const Counts = struct { lines: u64 = 0, words: u64 = 0, chars: u64 = 0, bytes: u64 = 0, maxlen: u64 = 0 };

fn countFd(fd: i32, cnt: *Counts) !void {
    var buf: [65536]u8 = undefined;
    var in_word = false;
    var col: u64 = 0;
    while (true) {
        const n = try c.sys.read(fd, &buf);
        if (n == 0) break;
        cnt.bytes += n;
        for (buf[0..n]) |ch| {
            if (ch & 0xC0 != 0x80) cnt.chars += 1;
            switch (ch) {
                '\n' => {
                    cnt.lines += 1;
                    if (col > cnt.maxlen) cnt.maxlen = col;
                    col = 0;
                    in_word = false;
                },
                ' ', '\t', '\r', 11, 12 => {
                    in_word = false;
                    if (ch == '\t') col = (col / 8 + 1) * 8 else if (ch == '\r' or ch == 12) {
                        if (col > cnt.maxlen) cnt.maxlen = col;
                        col = 0;
                    } else if (ch == ' ') col += 1;
                },
                else => {
                    if (!in_word) cnt.words += 1;
                    in_word = true;
                    if (ch >= 0x20 and ch != 0x7f and ch & 0xC0 != 0x80) col += 1;
                },
            }
        }
    }
    if (col > cnt.maxlen) cnt.maxlen = col;
}

var w_lines = false;
var w_words = false;
var w_chars = false;
var w_bytes = false;
var w_max = false;

fn printCounts(cnt: Counts, width: usize, name: ?[]const u8) !void {
    const out = c.out;
    var first = true;
    const vals = [_]struct { bool, u64 }{ .{ w_lines, cnt.lines }, .{ w_words, cnt.words }, .{ w_chars, cnt.chars }, .{ w_bytes, cnt.bytes }, .{ w_max, cnt.maxlen } };
    for (vals) |v| {
        if (!v[0]) continue;
        if (!first) try out.writeByte(' ');
        first = false;
        try c.padNum(out, v[1], width);
    }
    if (name) |n| try out.print(" {s}", .{n});
    try out.writeByte('\n');
}

pub fn main(args: c.Args) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var total_mode: []const u8 = "auto";
    var p = c.Parser.init(args, &.{
        .{ "bytes", 'c' }, .{ "chars", 'm' }, .{ "lines", 'l' }, .{ "max-line-length", 'L' }, .{ "words", 'w' },
        .{ "total", 0 },   .{ "files0-from", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => w_bytes = true,
            'm' => w_chars = true,
            'l' => w_lines = true,
            'L' => w_max = true,
            'w' => w_words = true,
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "total")) total_mode = p.arg() else if (c.eql(name, "files0-from")) {
                const data = c.readInput(p.arg()) orelse c.exit(1);
                var it = std.mem.splitScalar(u8, data, 0);
                while (it.next()) |f| if (f.len > 0) try files.append(c.gpa, f);
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (!(w_lines or w_words or w_chars or w_bytes or w_max)) {
        w_lines = true;
        w_words = true;
        w_bytes = true;
    }
    const nfields = @as(u32, @intFromBool(w_lines)) + @intFromBool(w_words) + @intFromBool(w_chars) + @intFromBool(w_bytes) + @intFromBool(w_max);
    const implicit = files.items.len == 0;
    if (implicit) try files.append(c.gpa, "-");
    // compute width like GNU
    var width: usize = 1;
    if (!(files.items.len == 1 and nfields == 1)) {
        var min_width: usize = 1;
        var total_size: u64 = 0;
        for (files.items) |f| {
            const st = (if (c.eql(f, "-")) c.sys.fstat(0) else c.sys.stat(f)) catch continue;
            if (!st.isReg()) min_width = 7 else total_size += @intCast(st.size);
        }
        width = @max(c.numLen(total_size), min_width);
    }
    var total: Counts = .{};
    var status: u8 = 0;
    var results: std.ArrayList(struct { Counts, ?[]const u8 }) = .empty;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var cnt: Counts = .{};
        countFd(fd, &cnt) catch |e| {
            c.warn("{s}: {s}", .{ f, c.strerror(e) });
            status = 1;
        };
        total.lines += cnt.lines;
        total.words += cnt.words;
        total.chars += cnt.chars;
        total.bytes += cnt.bytes;
        total.maxlen = @max(total.maxlen, cnt.maxlen);
        if (c.eql(total_mode, "only")) continue;
        try printCounts(cnt, width, if (implicit) null else f);
        _ = &results;
    }
    const show_total = if (c.eql(total_mode, "always") or c.eql(total_mode, "only")) true else if (c.eql(total_mode, "never")) false else files.items.len > 1;
    if (show_total) try printCounts(total, width, if (c.eql(total_mode, "only")) null else "total");
    return status;
}
