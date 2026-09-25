const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: paste [OPTION]... [FILE]...
    \\Write lines consisting of the sequentially corresponding lines from
    \\each FILE, separated by TABs, to standard output.
    \\
    \\  -d, --delimiters=LIST   reuse characters from LIST instead of TABs
    \\  -s, --serial            paste one file at a time instead of in parallel
    \\  -z, --zero-terminated   line delimiter is NUL, not newline
    \\
;

fn parseDelims(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            const ch: u8 = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                '\\' => '\\',
                '0' => 0xff, // marker for empty
                else => s[i],
            };
            out.append(c.gpa, ch) catch c.oom();
        } else out.append(c.gpa, s[i]) catch c.oom();
    }
    return out.items;
}

fn putDelim(w: *std.Io.Writer, d: u8) !void {
    if (d != 0xff) try w.writeByte(d);
}

pub fn main(args: c.Args) !u8 {
    var delims: []const u8 = "\t";
    var serial = false;
    var eol: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "delimiters", 'd' }, .{ "serial", 's' }, .{ "zero-terminated", 'z' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'd' => delims = parseDelims(p.arg()),
            's' => serial = true,
            'z' => eol = 0,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    if (delims.len == 0) delims = "\xff";
    const w = c.out;
    if (serial) {
        var status: u8 = 0;
        for (files.items) |f| {
            const fd = c.openInput(f) orelse {
                status = 1;
                continue;
            };
            defer c.closeInput(fd);
            var r = c.LineReader.init(fd);
            defer r.deinit();
            r.delim = eol;
            var k: usize = 0;
            var first = true;
            while (try r.next()) |line| {
                if (!first) {
                    try putDelim(w, delims[k % delims.len]);
                    k += 1;
                }
                first = false;
                try w.writeAll(line);
            }
            try w.writeByte(eol);
        }
        return status;
    }
    var readers: std.ArrayList(?c.LineReader) = .empty;
    var fds: std.ArrayList(i32) = .empty;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse c.exit(1);
        try fds.append(c.gpa, fd);
        var r = c.LineReader.init(fd);
        r.delim = eol;
        try readers.append(c.gpa, r);
    }
    // stdin used multiple times shares one reader
    while (true) {
        var any = false;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(c.gpa);
        for (readers.items, 0..) |*ro, i| {
            if (i > 0) {
                const d = delims[(i - 1) % delims.len];
                if (d != 0xff) try line_buf.append(c.gpa, d);
            }
            var rr: *c.LineReader = undefined;
            // find shared stdin reader
            var idx = i;
            if (fds.items[i] == 0) {
                for (fds.items, 0..) |fd, j| if (fd == 0) {
                    idx = j;
                    break;
                };
            }
            if (readers.items[idx]) |*x| rr = x else continue;
            _ = ro;
            if (try rr.next()) |line| {
                any = true;
                try line_buf.appendSlice(c.gpa, line);
            }
        }
        if (!any) break;
        try w.writeAll(line_buf.items);
        try w.writeByte(eol);
    }
    return 0;
}
