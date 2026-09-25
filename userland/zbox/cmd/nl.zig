const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const mem = std.mem;

pub const help =
    \\Usage: nl [OPTION]... [FILE]...
    \\Write each FILE to standard output, with line numbers added.
    \\
    \\  -b, --body-numbering=STYLE      use STYLE for numbering body lines
    \\  -d, --section-delimiter=CC      use CC for logical page delimiters
    \\  -f, --footer-numbering=STYLE    use STYLE for numbering footer lines
    \\  -h, --header-numbering=STYLE    use STYLE for numbering header lines
    \\  -i, --line-increment=NUMBER     line number increment at each line
    \\  -n, --number-format=FORMAT      insert line numbers according to FORMAT
    \\  -p, --no-renumber               do not reset line numbers for each section
    \\  -s, --number-separator=STRING   add STRING after (possible) line number
    \\  -v, --starting-line-number=NUMBER  first line number for each section
    \\  -w, --number-width=NUMBER       use NUMBER columns for line numbers
    \\
    \\STYLE is one of: a (all lines), t (nonempty lines), n (no lines),
    \\pBRE (lines matching the basic regular expression BRE).
    \\FORMAT is one of: ln (left justified), rn (right justified), rz (zeros).
    \\
;

const Style = struct { kind: u8, re: ?rx.Regex = null };

fn parseStyle(s: []const u8) Style {
    if (s.len == 0) c.fatal("invalid numbering style: ''", .{});
    switch (s[0]) {
        'a', 't', 'n' => if (s.len == 1) return .{ .kind = s[0] },
        'p' => {
            const re = rx.Regex.compile(c.gpa, s[1..], .{}) catch c.fatal("{s}", .{rx.err_msg});
            return .{ .kind = 'p', .re = re };
        },
        else => {},
    }
    c.fatal("invalid numbering style: {f}", .{c.q(s)});
}

pub fn main(args: c.Args) !u8 {
    var body = Style{ .kind = 't' };
    var header = Style{ .kind = 'n' };
    var footer = Style{ .kind = 'n' };
    var incr: i64 = 1;
    var fmt: []const u8 = "rn";
    var renumber = true;
    var sep: []const u8 = "\t";
    var start: i64 = 1;
    var width: usize = 6;
    var delim: []const u8 = "\\:";
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "body-numbering", 'b' },       .{ "section-delimiter", 'd' }, .{ "footer-numbering", 'f' },
        .{ "header-numbering", 'h' },     .{ "line-increment", 'i' },    .{ "number-format", 'n' },
        .{ "no-renumber", 'p' },          .{ "number-separator", 's' },  .{ "starting-line-number", 'v' },
        .{ "number-width", 'w' },         .{ "join-blank-lines", 'l' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => body = parseStyle(p.arg()),
            'h' => header = parseStyle(p.arg()),
            'f' => footer = parseStyle(p.arg()),
            'd' => delim = p.arg(),
            'i' => incr = c.parseInt(p.arg()) orelse c.fatal("invalid line number increment", .{}),
            'n' => {
                fmt = p.arg();
                if (!(c.eql(fmt, "ln") or c.eql(fmt, "rn") or c.eql(fmt, "rz"))) c.fatal("invalid line numbering format: {f}", .{c.q(fmt)});
            },
            'p' => renumber = false,
            's' => sep = p.arg(),
            'v' => start = c.parseInt(p.arg()) orelse c.fatal("invalid starting line number", .{}),
            'w' => width = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid line number field width", .{})),
            'l' => _ = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var num = start;
    var section: u8 = 'b';
    const w = c.out;
    var status: u8 = 0;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        defer c.closeInput(fd);
        var r = c.LineReader.init(fd);
        defer r.deinit();
        while (try r.next()) |line| {
            // section delimiters
            if (delim.len > 0 and line.len > 0 and line.len % delim.len == 0 and line.len / delim.len <= 3) {
                var all = true;
                var k: usize = 0;
                while (k < line.len) : (k += delim.len) if (!mem.eql(u8, line[k .. k + delim.len], delim)) {
                    all = false;
                };
                if (all) {
                    section = switch (line.len / delim.len) {
                        3 => 'h',
                        2 => 'b',
                        else => 'f',
                    };
                    if (section == 'h' and renumber) num = start;
                    try w.writeByte('\n');
                    continue;
                }
            }
            const st = switch (section) {
                'h' => &header,
                'f' => &footer,
                else => &body,
            };
            const numbered = switch (st.kind) {
                'a' => true,
                't' => line.len > 0,
                'p' => st.re.?.exec(line, 0, null, .{ .longest = false }),
                else => false,
            };
            if (numbered) {
                var b: [32]u8 = undefined;
                const s = c.fmtBuf(&b, "{d}", .{num});
                if (c.eql(fmt, "ln")) {
                    try c.padRight(w, s, width);
                } else if (c.eql(fmt, "rz")) {
                    if (num < 0) {
                        try w.writeByte('-');
                        const digits = s[1..];
                        if (digits.len + 1 < width) try w.splatByteAll('0', width - digits.len - 1);
                        try w.writeAll(digits);
                    } else {
                        if (s.len < width) try w.splatByteAll('0', width - s.len);
                        try w.writeAll(s);
                    }
                } else try c.padLeft(w, s, width);
                try w.writeAll(sep);
                num += incr;
            } else {
                try w.splatByteAll(' ', width + sep.len);
            }
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    return status;
}
