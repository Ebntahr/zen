const std = @import("std");
const c = @import("../common.zig");
const pf = @import("printf.zig");
const mem = std.mem;

pub const help =
    \\Usage: seq [OPTION]... LAST
    \\  or:  seq [OPTION]... FIRST LAST
    \\  or:  seq [OPTION]... FIRST INCREMENT LAST
    \\Print numbers from FIRST to LAST, in steps of INCREMENT.
    \\
    \\  -f, --format=FORMAT      use printf style floating-point FORMAT
    \\  -s, --separator=STRING   use STRING to separate numbers (default: \n)
    \\  -w, --equal-width        equalize width by padding with leading zeroes
    \\
;

const Operand = struct { value: f64, precision: ?usize, width: usize, int: ?i128 };

fn scanArg(arg: []const u8) Operand {
    const v = pf.parseFloatArg(arg) orelse {
        c.warn("invalid floating point argument: {f}", .{c.q(arg)});
        c.tryHelp();
        c.exit(1);
    };
    if (std.math.isNan(v)) {
        c.warn("invalid 'not-a-number' argument: {f}", .{c.q(arg)});
        c.tryHelp();
        c.exit(1);
    }
    var a = mem.trim(u8, arg, " \t\n");
    while (a.len > 0 and a[0] == '+') a = a[1..];
    var op: Operand = .{ .value = v, .precision = null, .width = 0, .int = null };
    if (mem.indexOfAny(u8, a, "xX") == null and std.math.isFinite(v)) {
        var width: i64 = @intCast(a.len);
        var prec: i64 = 0;
        if (mem.indexOfScalar(u8, a, '.')) |dp| {
            const rest = a[dp + 1 ..];
            const flen = mem.indexOfAny(u8, rest, "eE") orelse rest.len;
            prec = @intCast(flen);
            if (flen == 0) width -= 1 else if (dp == 0 or !std.ascii.isDigit(a[dp - 1])) width += 1;
        }
        if (mem.indexOfAny(u8, a, "eE")) |e| {
            const ex = std.fmt.parseInt(i64, a[e + 1 ..], 10) catch 0;
            width -= @intCast(a.len - e);
            if (ex < 0) {
                prec += -ex;
                width += -ex;
            } else {
                prec = @max(0, prec - ex);
                width += ex;
            }
        }
        op.precision = @intCast(@max(prec, 0));
        op.width = @intCast(@max(width, 0));
        if (prec == 0 and mem.indexOfAny(u8, a, ".eE") == null) {
            op.int = std.fmt.parseInt(i128, a, 10) catch null;
        }
    }
    return op;
}

fn validFormat(f: []const u8) ?pf.ParsedSpec {
    var i: usize = 0;
    var found: ?pf.ParsedSpec = null;
    while (i < f.len) : (i += 1) {
        if (f[i] != '%') continue;
        if (i + 1 < f.len and f[i + 1] == '%') {
            i += 1;
            continue;
        }
        const ps = pf.parseSpec(f, i + 1) orelse c.fatal("format {f} ends in %", .{c.q(f)});
        if (mem.indexOfScalar(u8, "aAeEfFgG", ps.spec.conv) == null) c.fatal("format {f} has unknown %{c} directive", .{ c.q(f), ps.spec.conv });
        if (found != null) c.fatal("format {f} has too many % directives", .{c.q(f)});
        found = ps;
        found.?.end = ps.end;
        found.?.width_star = false;
        i = ps.end - 1;
        // remember prefix start via end - consumed
        found.?.spec = ps.spec;
    }
    if (found == null) c.fatal("format {f} has no % directive", .{c.q(f)});
    return found;
}

fn formatNum(w: *std.Io.Writer, fmt: []const u8, v: f64) !void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                try w.writeByte('%');
                i += 2;
                continue;
            }
            const ps = pf.parseSpec(fmt, i + 1).?;
            try pf.fmtFloat(w, ps.spec, v);
            i = ps.end;
            continue;
        }
        if (fmt[i] == '\\' and i + 1 < fmt.len) {
            var tmp: [8]u8 = undefined;
            const r = c.unescapeOne(fmt[i..], &tmp, false);
            try w.writeAll(r[0]);
            i += r[1];
            continue;
        }
        try w.writeByte(fmt[i]);
        i += 1;
    }
}

pub fn main(args: c.Args) !u8 {
    var fmt: ?[]const u8 = null;
    var sep: []const u8 = "\n";
    var equal = false;
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "format", 'f' }, .{ "separator", 's' }, .{ "equal-width", 'w' } });
    p.neg_numbers = true;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'f' => fmt = p.arg(),
            's' => sep = p.arg(),
            'w' => equal = true,
            else => p.bad(o),
        },
        .pos => |a| try ops.append(c.gpa, a),
        else => p.bad(o),
    };
    if (ops.items.len == 0) c.usageErr("missing operand", .{});
    if (ops.items.len > 3) c.usageErr("extra operand {f}", .{c.q(ops.items[3])});
    if (fmt != null and equal) c.usageErr("format string may not be specified when printing equal width strings", .{});
    var first: Operand = .{ .value = 1, .precision = 0, .width = 1, .int = 1 };
    var step: Operand = .{ .value = 1, .precision = 0, .width = 1, .int = 1 };
    var last: Operand = undefined;
    switch (ops.items.len) {
        1 => last = scanArg(ops.items[0]),
        2 => {
            first = scanArg(ops.items[0]);
            last = scanArg(ops.items[1]);
        },
        else => {
            first = scanArg(ops.items[0]);
            step = scanArg(ops.items[1]);
            last = scanArg(ops.items[2]);
            if (step.value == 0) {
                c.warn("invalid Zero increment value: {f}", .{c.q(ops.items[1])});
                c.tryHelp();
                c.exit(1);
            }
        },
    }
    if (fmt) |f| _ = validFormat(f);
    const w = c.out;
    // integer fast path
    if (fmt == null and first.int != null and step.int != null and last.int != null) {
        const a = first.int.?;
        const s = step.int.?;
        const b = last.int.?;
        var width: usize = 0;
        if (equal) width = @max(first.width, last.width);
        var x = a;
        var firstp = true;
        while ((s > 0 and x <= b) or (s < 0 and x >= b)) : (x += s) {
            if (!firstp) try w.writeAll(sep);
            firstp = false;
            var buf: [64]u8 = undefined;
            const str = c.fmtBuf(&buf, "{d}", .{x});
            if (equal) {
                const neg = x < 0;
                const digits = if (neg) str[1..] else str;
                if (neg) try w.writeByte('-');
                const len = digits.len + @intFromBool(neg);
                if (len < width) try w.splatByteAll('0', width - len);
                try w.writeAll(digits);
            } else try w.writeAll(str);
        }
        if (!firstp) try w.writeByte('\n');
        return 0;
    }
    var fbuf: [64]u8 = undefined;
    const format: []const u8 = fmt orelse blk: {
        const prec: ?usize = if (first.precision != null and step.precision != null) @max(first.precision.?, step.precision.?) else null;
        if (prec != null and last.precision != null) {
            if (equal) {
                const pr = prec.?;
                var fw: i64 = @as(i64, @intCast(first.width)) + @as(i64, @intCast(pr)) - @as(i64, @intCast(first.precision.?));
                var lw: i64 = @as(i64, @intCast(last.width)) + @as(i64, @intCast(pr)) - @as(i64, @intCast(last.precision.?));
                if (last.precision.? > 0 and pr == 0) lw -= 1;
                if (last.precision.? == 0 and pr > 0) lw += 1;
                if (first.precision.? == 0 and pr > 0) fw += 1;
                break :blk c.fmtBuf(&fbuf, "%0{d}.{d}f", .{ @max(fw, lw), pr });
            }
            break :blk c.fmtBuf(&fbuf, "%.{d}f", .{prec.?});
        }
        break :blk "%g";
    };
    var i: u64 = 0;
    var firstp = true;
    var prev_str: std.ArrayList(u8) = .empty;
    while (true) : (i += 1) {
        const x = first.value + @as(f64, @floatFromInt(i)) * step.value;
        var tmp: std.Io.Writer.Allocating = .init(c.gpa);
        defer tmp.deinit();
        if ((step.value > 0 and x > last.value) or (step.value < 0 and x < last.value)) {
            // print LAST if x prints the same as LAST (rounding) and differs from previous
            var lt: std.Io.Writer.Allocating = .init(c.gpa);
            defer lt.deinit();
            try formatNum(&tmp.writer, format, x);
            try formatNum(&lt.writer, format, last.value);
            if (i > 0 and mem.eql(u8, tmp.written(), lt.written()) and !mem.eql(u8, tmp.written(), prev_str.items)) {
                if (!firstp) try w.writeAll(sep);
                firstp = false;
                try w.writeAll(tmp.written());
            }
            break;
        }
        try formatNum(&tmp.writer, format, x);
        if (!firstp) try w.writeAll(sep);
        firstp = false;
        try w.writeAll(tmp.written());
        prev_str.clearRetainingCapacity();
        try prev_str.appendSlice(c.gpa, tmp.written());
    }
    if (!firstp) try w.writeByte('\n');
    return 0;
}
