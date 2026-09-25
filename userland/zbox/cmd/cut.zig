const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: cut OPTION... [FILE]...
    \\Print selected parts of lines from each FILE to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -b, --bytes=LIST        select only these bytes
    \\  -c, --characters=LIST   select only these characters
    \\  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter
    \\  -f, --fields=LIST       select only these fields;  also print any line
    \\                            that contains no delimiter character, unless
    \\                            the -s option is specified
    \\  -n                      (ignored)
    \\      --complement        complement the set of selected bytes, characters
    \\                            or fields
    \\  -s, --only-delimited    do not print lines not containing delimiters
    \\      --output-delimiter=STRING  use STRING as the output delimiter
    \\                            the default is to use the input delimiter
    \\  -z, --zero-terminated   line delimiter is NUL, not newline
    \\
    \\Each LIST is made up of one range, or many ranges separated by commas.
    \\Each range is one of: N, N-, N-M, -M
    \\
;

const Range = struct { lo: u64, hi: u64 };
var ranges: std.ArrayList(Range) = .empty;
var complement = false;

fn parseList(s: []const u8) void {
    var it = mem.tokenizeAny(u8, s, ", ");
    while (it.next()) |part| {
        var r: Range = .{ .lo = 1, .hi = std.math.maxInt(u64) };
        if (mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = part[0..dash];
            const b = part[dash + 1 ..];
            if (a.len == 0 and b.len == 0) c.fatal("invalid range with no endpoint: -", .{});
            if (a.len > 0) r.lo = c.parseUint(a) orelse c.fatal("invalid field value {f}", .{c.q(a)});
            if (b.len > 0) r.hi = c.parseUint(b) orelse c.fatal("invalid field value {f}", .{c.q(b)});
            if (r.lo == 0) c.fatal("fields and positions are numbered from 1", .{});
            if (r.hi < r.lo) c.fatal("invalid decreasing range", .{});
        } else {
            const n = c.parseUint(part) orelse c.fatal("invalid field value {f}", .{c.q(part)});
            if (n == 0) c.fatal("fields and positions are numbered from 1", .{});
            r = .{ .lo = n, .hi = n };
        }
        ranges.append(c.gpa, r) catch c.oom();
    }
    if (ranges.items.len == 0) c.fatal("missing list of fields", .{});
}

fn selected(i: u64) bool {
    var in = false;
    for (ranges.items) |r| if (i >= r.lo and i <= r.hi) {
        in = true;
        break;
    };
    return in != complement;
}

pub fn main(args: c.Args) !u8 {
    var mode: u8 = 0;
    var delim: u8 = '\t';
    var only_delim = false;
    var out_delim: ?[]const u8 = null;
    var eol: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "bytes", 'b' },      .{ "characters", 'c' }, .{ "delimiter", 'd' },       .{ "fields", 'f' },
        .{ "complement", 0 },   .{ "only-delimited", 's' }, .{ "output-delimiter", 0 }, .{ "zero-terminated", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b', 'c', 'f' => {
                if (mode != 0) c.usageErr("only one list may be specified", .{});
                mode = ch;
                parseList(p.arg());
            },
            'd' => {
                const d = p.arg();
                if (d.len > 1) c.usageErr("the delimiter must be a single character", .{});
                delim = if (d.len == 0) 0 else d[0];
            },
            's' => only_delim = true,
            'n' => {},
            'z' => eol = 0,
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "complement")) complement = true else if (c.eql(name, "output-delimiter")) out_delim = p.arg() else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (mode == 0) c.usageErr("you must specify a list of bytes, characters, or fields", .{});
    if (mode != 'f' and only_delim) c.usageErr("suppressing non-delimited lines makes sense\n\tonly when operating on fields", .{});
    if (files.items.len == 0) try files.append(c.gpa, "-");
    const w = c.out;
    const od: []const u8 = out_delim orelse &[1]u8{delim};
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
        while (try r.next()) |line| {
            if (mode == 'f') {
                if (mem.indexOfScalar(u8, line, delim) == null) {
                    if (!only_delim) {
                        try w.writeAll(line);
                        try w.writeByte(eol);
                    }
                    continue;
                }
                var it = mem.splitScalar(u8, line, delim);
                var idx: u64 = 1;
                var first = true;
                while (it.next()) |field| : (idx += 1) {
                    if (!selected(idx)) continue;
                    if (!first) try w.writeAll(od);
                    first = false;
                    try w.writeAll(field);
                }
            } else {
                // bytes / characters (GNU treats -c like -b)
                var in_run = false;
                var any = false;
                for (line, 1..) |ch, idx| {
                    if (selected(idx)) {
                        if (out_delim != null and !in_run and any) try w.writeAll(od);
                        try w.writeByte(ch);
                        in_run = true;
                        any = true;
                    } else in_run = false;
                }
            }
            try w.writeByte(eol);
        }
    }
    return status;
}
