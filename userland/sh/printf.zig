//! The `printf` builtin.
const std = @import("std");
const shell = @import("shell.zig");
const builtins = @import("builtins.zig");
const Shell = shell.Shell;
const Error = shell.Error;
const Allocator = std.mem.Allocator;

const Out = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn put(o: *Out, s: []const u8) void {
        o.buf.appendSlice(o.a, s) catch {};
    }
    fn putc(o: *Out, c: u8) void {
        o.buf.append(o.a, c) catch {};
    }
    fn pad(o: *Out, c: u8, n: usize) void {
        o.buf.appendNTimes(o.a, c, n) catch {};
    }
};

const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    hash: bool = false,
    zero: bool = false,
    width: ?usize = null,
    prec: ?usize = null,
};

const State = struct {
    sh: *Shell,
    args: []const [:0]const u8,
    ai: usize = 0,
    status: u8 = 0,
    stop: bool = false,

    fn next(st: *State) ?[]const u8 {
        if (st.ai >= st.args.len) return null;
        st.ai += 1;
        return st.args[st.ai - 1];
    }

    fn int(st: *State) i64 {
        const s = st.next() orelse return 0;
        return parseInt(st, s);
    }

    fn float(st: *State) Float {
        const s = std.mem.trim(u8, st.next() orelse return 0, " \t\n");
        if (s.len >= 2 and (s[0] == '\'' or s[0] == '"')) return @floatFromInt(s[1]);
        return std.fmt.parseFloat(Float, s) catch {
            st.sh.errMsg("printf: {s}: invalid number", .{s});
            st.status = 1;
            return 0;
        };
    }
};

fn parseInt(st: *State, raw: []const u8) i64 {
    const s = std.mem.trim(u8, raw, " \t\n");
    if (s.len == 0) return 0;
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"')) {
        const d = std.unicode.utf8Decode(s[1..@min(s.len, 1 + (std.unicode.utf8ByteSequenceLength(s[1]) catch 1))]) catch s[1];
        return d;
    }
    var neg = false;
    var t = s;
    if (t[0] == '-' or t[0] == '+') {
        neg = t[0] == '-';
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len > 1 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len > 1 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    var v: i64 = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const d = std.fmt.charToDigit(t[i], base) catch break;
        v = v *% base +% d;
    }
    if (i < t.len or t.len == 0) {
        st.sh.errMsg("printf: {s}: invalid number", .{raw});
        st.status = 1;
    }
    return if (neg) -%v else v;
}

fn emitPadded(o: *Out, spec: Spec, body: []const u8, zero_ok: bool, prefix_len: usize) void {
    const w = spec.width orelse 0;
    if (body.len >= w) {
        o.put(body);
        return;
    }
    const n = w - body.len;
    if (spec.minus) {
        o.put(body);
        o.pad(' ', n);
    } else if (spec.zero and zero_ok) {
        o.put(body[0..prefix_len]);
        o.pad('0', n);
        o.put(body[prefix_len..]);
    } else {
        o.pad(' ', n);
        o.put(body);
    }
}

fn fmtInt(o: *Out, a: Allocator, spec: Spec, v: i64, conv: u8) void {
    var digits_buf: [72]u8 = undefined;
    const neg = v < 0 and (conv == 'd' or conv == 'i');
    const mag: u64 = if (conv == 'd' or conv == 'i') (if (neg) @as(u64, @bitCast(-%v)) else @intCast(v)) else @bitCast(v);
    const base: u8 = switch (conv) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    const n = std.fmt.printInt(&digits_buf, mag, base, if (conv == 'X') .upper else .lower, .{});
    var digits: []const u8 = digits_buf[0..n];
    if (spec.prec) |p| {
        if (p == 0 and mag == 0) digits = "";
    }
    var body: std.ArrayList(u8) = .empty;
    var prefix: usize = 0;
    if (neg) {
        body.append(a, '-') catch {};
        prefix = 1;
    } else if ((conv == 'd' or conv == 'i') and spec.plus) {
        body.append(a, '+') catch {};
        prefix = 1;
    } else if ((conv == 'd' or conv == 'i') and spec.space) {
        body.append(a, ' ') catch {};
        prefix = 1;
    }
    if (spec.hash and mag != 0) {
        if (conv == 'x') {
            body.appendSlice(a, "0x") catch {};
            prefix += 2;
        } else if (conv == 'X') {
            body.appendSlice(a, "0X") catch {};
            prefix += 2;
        } else if (conv == 'o' and (digits.len == 0 or digits[0] != '0')) {
            body.append(a, '0') catch {};
        }
    }
    if (spec.prec) |p| {
        if (digits.len < p) body.appendNTimes(a, '0', p - digits.len) catch {};
    }
    body.appendSlice(a, digits) catch {};
    emitPadded(o, spec, body.items, spec.prec == null, prefix);
}

const Managed = std.math.big.int.Managed;

/// printf uses the widest float type (like C's long double on riscv64).
const Float = f128;

/// Exact decimal expansion of a positive finite double:
/// value = 0.DIGITS x 10^exp10 (no leading or trailing zeros in DIGITS).
const Dec = struct { digits: []u8, exp10: i32 };

fn exactDecimal(a: Allocator, x: Float) !Dec {
    const bits: u128 = @bitCast(x);
    const frac = bits & ((@as(u128, 1) << 112) - 1);
    const bexp: i32 = @intCast((bits >> 112) & 0x7fff);
    var m: u128 = frac;
    var e: i32 = undefined;
    if (bexp == 0) {
        e = 1 - 16383 - 112;
    } else {
        m |= @as(u128, 1) << 112;
        e = bexp - 16383 - 112;
    }
    if (m == 0) return .{ .digits = "", .exp10 = 0 };
    var big = try Managed.initSet(a, m);
    var s: []u8 = undefined;
    var point: i32 = 0;
    if (e >= 0) {
        var r = try Managed.init(a);
        try r.shiftLeft(&big, @intCast(e));
        s = try r.toString(a, 10, .lower);
    } else {
        const five = try Managed.initSet(a, 5);
        var p = try Managed.init(a);
        try p.pow(&five, @intCast(-e));
        var r = try Managed.init(a);
        try r.mul(&big, &p);
        s = try r.toString(a, 10, .lower);
        point = -e;
    }
    const exp10: i32 = @as(i32, @intCast(s.len)) - point;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    return .{ .digits = s[0..end], .exp10 = exp10 };
}

/// Round to `n` significant digits (half to even on exact ties). The result
/// has exactly `n` digits (zero padded).
fn roundDigits(a: Allocator, d: Dec, n_in: i64) !Dec {
    if (n_in < 0) return .{ .digits = "", .exp10 = d.exp10 };
    const n: usize = @intCast(n_in);
    var out = try a.alloc(u8, n);
    const have = @min(n, d.digits.len);
    @memcpy(out[0..have], d.digits[0..have]);
    @memset(out[have..], '0');
    if (d.digits.len <= n) return .{ .digits = out, .exp10 = d.exp10 };
    const rest = d.digits[n..];
    var up = false;
    if (rest[0] > '5') {
        up = true;
    } else if (rest[0] == '5') {
        var nonzero = false;
        for (rest[1..]) |c| {
            if (c != '0') nonzero = true;
        }
        up = nonzero or (n > 0 and (out[n - 1] - '0') % 2 == 1);
    }
    if (!up) return .{ .digits = out, .exp10 = d.exp10 };
    var i = n;
    while (i > 0) {
        i -= 1;
        if (out[i] == '9') {
            out[i] = '0';
        } else {
            out[i] += 1;
            return .{ .digits = out, .exp10 = d.exp10 };
        }
    }
    // carry out of the most significant digit
    const grown = try a.alloc(u8, n + 1);
    grown[0] = '1';
    @memset(grown[1..], '0');
    return .{ .digits = grown[0..@max(n, 1)], .exp10 = d.exp10 + 1 };
}

fn formatFixed(a: Allocator, x: Float, prec: usize, keep_point: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const d = try exactDecimal(a, x);
    const r = if (d.digits.len == 0) d else try roundDigits(a, d, @as(i64, d.exp10) + @as(i64, @intCast(prec)));
    var digits = r.digits;
    var e = r.exp10;
    if (digits.len == 0) e = 0;
    if (e > 0) {
        const ue: usize = @intCast(e);
        if (digits.len >= ue) {
            try out.appendSlice(a, digits[0..ue]);
            digits = digits[ue..];
        } else {
            try out.appendSlice(a, digits);
            try out.appendNTimes(a, '0', ue - digits.len);
            digits = "";
        }
    } else try out.append(a, '0');
    if (prec > 0 or keep_point) try out.append(a, '.');
    var frac: std.ArrayList(u8) = .empty;
    if (e < 0) try frac.appendNTimes(a, '0', @intCast(-e));
    try frac.appendSlice(a, digits);
    if (frac.items.len < prec) try frac.appendNTimes(a, '0', prec - frac.items.len);
    try out.appendSlice(a, frac.items[0..prec]);
    return out.items;
}

fn formatSci(a: Allocator, x: Float, prec: usize, upper: bool, keep_point: bool) !struct { text: []const u8, exp: i32 } {
    var out: std.ArrayList(u8) = .empty;
    var digits: []const u8 = undefined;
    var exp: i32 = 0;
    const d = try exactDecimal(a, x);
    if (d.digits.len == 0) {
        const z = try a.alloc(u8, prec + 1);
        @memset(z, '0');
        digits = z;
    } else {
        const r = try roundDigits(a, d, @intCast(prec + 1));
        digits = r.digits;
        exp = r.exp10 - 1;
    }
    try out.append(a, digits[0]);
    if (prec > 0 or keep_point) try out.append(a, '.');
    try out.appendSlice(a, digits[1..]);
    try out.append(a, if (upper) 'E' else 'e');
    try out.append(a, if (exp < 0) '-' else '+');
    const ae: u32 = @intCast(if (exp < 0) -exp else exp);
    if (ae < 10) try out.append(a, '0');
    try out.print(a, "{d}", .{ae});
    return .{ .text = out.items, .exp = exp };
}

fn stripZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var e = s.len;
    while (e > 0 and s[e - 1] == '0') e -= 1;
    if (e > 0 and s[e - 1] == '.') e -= 1;
    return s[0..e];
}

fn fmtFloat(o: *Out, a: Allocator, spec: Spec, v_in: Float, conv: u8) void {
    var v = v_in;
    const upper = std.ascii.isUpper(conv);
    var body: std.ArrayList(u8) = .empty;
    var prefix: usize = 0;
    if (std.math.signbit(v) and !std.math.isNan(v)) {
        body.append(a, '-') catch {};
        v = -v;
        prefix = 1;
    } else if (spec.plus) {
        body.append(a, '+') catch {};
        prefix = 1;
    } else if (spec.space) {
        body.append(a, ' ') catch {};
        prefix = 1;
    }
    if (std.math.isInf(v) or std.math.isNan(v)) {
        const t = if (std.math.isNan(v)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        body.appendSlice(a, t) catch {};
        emitPadded(o, spec, body.items, false, prefix);
        return;
    }
    const prec = spec.prec orelse 6;
    var text: []const u8 = "";
    switch (std.ascii.toLower(conv)) {
        'f' => text = formatFixed(a, v, prec, spec.hash) catch "?",
        'e' => text = (formatSci(a, v, prec, upper, spec.hash) catch return).text,
        else => {
            // %g: choose %e or %f style by the decimal exponent
            const p: usize = if (prec == 0) 1 else prec;
            const sci = formatSci(a, v, p - 1, upper, spec.hash) catch return;
            const x = sci.exp;
            if (@as(i64, @intCast(p)) > x and x >= -4) {
                const fp: usize = @intCast(@as(i64, @intCast(p)) - 1 - x);
                text = formatFixed(a, v, fp, spec.hash) catch "?";
                if (!spec.hash) text = stripZeros(text);
            } else {
                text = sci.text;
                if (!spec.hash) {
                    if (std.mem.indexOfAny(u8, text, "eE")) |e| {
                        const mant = stripZeros(text[0..e]);
                        text = std.mem.concat(a, u8, &.{ mant, text[e..] }) catch text;
                    }
                }
            }
        },
    }
    body.appendSlice(a, text) catch {};
    emitPadded(o, spec, body.items, true, prefix);
}

fn bashQuote(a: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "''";
    var ctrl = false;
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) ctrl = true;
    }
    var out: std.ArrayList(u8) = .empty;
    if (ctrl) {
        try out.appendSlice(a, "$'");
        for (s) |c| {
            switch (c) {
                '\n' => try out.appendSlice(a, "\\n"),
                '\t' => try out.appendSlice(a, "\\t"),
                '\r' => try out.appendSlice(a, "\\r"),
                0x1b => try out.appendSlice(a, "\\E"),
                '\'' => try out.appendSlice(a, "\\'"),
                '\\' => try out.appendSlice(a, "\\\\"),
                else => if (c < 0x20 or c == 0x7f) try out.print(a, "\\{o:0>3}", .{c}) else try out.append(a, c),
            }
        }
        try out.append(a, '\'');
        return out.items;
    }
    for (s, 0..) |c, i| {
        const special = std.mem.indexOfScalar(u8, " \t\n\\'\"`$&;|()<>*?[]!{},^", c) != null or
            (i == 0 and (c == '~' or c == '#'));
        if (special) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

/// Process %b style escapes into `o`. Returns false on \c.
fn bEscapes(o: *Out, s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            o.putc(c);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => o.putc(7),
            'b' => o.putc(8),
            'c' => return false,
            'e', 'E' => o.putc(27),
            'f' => o.putc(12),
            'n' => o.putc('\n'),
            'r' => o.putc('\r'),
            't' => o.putc('\t'),
            'v' => o.putc(11),
            '\\' => o.putc('\\'),
            '0'...'7' => {
                var j = i;
                if (s[j] == '0') j += 1;
                var v: u32 = 0;
                var k: usize = 0;
                while (k < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') : (k += 1) {
                    v = v * 8 + (s[j] - '0');
                    j += 1;
                }
                i = j - 1;
                o.putc(@truncate(v));
            },
            'x' => {
                var j = i + 1;
                var v: u32 = 0;
                var k: usize = 0;
                while (k < 2 and j < s.len) : (k += 1) {
                    const d = std.fmt.charToDigit(s[j], 16) catch break;
                    v = v * 16 + d;
                    j += 1;
                }
                if (k == 0) {
                    o.put("\\x");
                } else {
                    i = j - 1;
                    o.putc(@truncate(v));
                }
            },
            else => {
                o.putc('\\');
                o.putc(s[i]);
            },
        }
    }
    return true;
}

/// Run the format once. Returns true if at least one argument was consumed.
fn runFormat(st: *State, o: *Out, fmt: []const u8) bool {
    const a = st.sh.scratchAlloc();
    const start_ai = st.ai;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '\\') {
            if (i + 1 >= fmt.len) {
                o.putc('\\');
                i += 1;
                continue;
            }
            const e = fmt[i + 1];
            switch (e) {
                'a' => o.putc(7),
                'b' => o.putc(8),
                'c' => {
                    st.stop = true;
                    return false;
                },
                'e', 'E' => o.putc(27),
                'f' => o.putc(12),
                'n' => o.putc('\n'),
                'r' => o.putc('\r'),
                't' => o.putc('\t'),
                'v' => o.putc(11),
                '\\' => o.putc('\\'),
                '"' => o.putc('"'),
                '\'' => o.putc('\''),
                '0'...'7' => {
                    var j = i + 1;
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < 3 and j < fmt.len and fmt[j] >= '0' and fmt[j] <= '7') : (k += 1) {
                        v = v * 8 + (fmt[j] - '0');
                        j += 1;
                    }
                    o.putc(@truncate(v));
                    i = j;
                    continue;
                },
                'x' => {
                    var j = i + 2;
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < 2 and j < fmt.len) : (k += 1) {
                        const d = std.fmt.charToDigit(fmt[j], 16) catch break;
                        v = v * 16 + d;
                        j += 1;
                    }
                    if (k == 0) o.put("\\x") else o.putc(@truncate(v));
                    i = j;
                    continue;
                },
                else => {
                    o.putc('\\');
                    o.putc(e);
                },
            }
            i += 2;
            continue;
        }
        if (c != '%') {
            o.putc(c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) {
            o.putc('%');
            break;
        }
        if (fmt[i] == '%') {
            o.putc('%');
            i += 1;
            continue;
        }
        var spec = Spec{};
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.minus = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.hash = true,
                '0' => spec.zero = true,
                '\'' => {},
                else => break,
            }
        }
        if (i < fmt.len and fmt[i] == '*') {
            const w = st.int();
            if (w < 0) {
                spec.minus = true;
                spec.width = @intCast(-w);
            } else spec.width = @intCast(w);
            i += 1;
        } else {
            var w: usize = 0;
            var any = false;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                w = w * 10 + (fmt[i] - '0');
                any = true;
            }
            if (any) spec.width = w;
        }
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                const p = st.int();
                spec.prec = if (p < 0) null else @intCast(p);
                i += 1;
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                spec.prec = p;
            }
        }
        while (i < fmt.len and std.mem.indexOfScalar(u8, "hlLjzt", fmt[i]) != null) i += 1;
        if (i >= fmt.len) {
            st.sh.errMsg("printf: `%': missing format character", .{});
            st.status = 1;
            break;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            's' => {
                var s: []const u8 = st.next() orelse "";
                if (spec.prec) |p| s = s[0..@min(p, s.len)];
                emitPadded(o, spec, s, false, 0);
            },
            'b' => {
                var tmp = Out{ .a = a };
                const cont = bEscapes(&tmp, st.next() orelse "");
                var s: []const u8 = tmp.buf.items;
                if (spec.prec) |p| s = s[0..@min(p, s.len)];
                emitPadded(o, spec, s, false, 0);
                if (!cont) {
                    st.stop = true;
                    return false;
                }
            },
            'q' => {
                const s = bashQuote(a, st.next() orelse "") catch "";
                emitPadded(o, spec, s, false, 0);
            },
            'c' => {
                const s = st.next() orelse "";
                const n = if (s.len == 0) 0 else (std.unicode.utf8ByteSequenceLength(s[0]) catch 1);
                emitPadded(o, spec, s[0..@min(n, s.len)], false, 0);
            },
            'd', 'i', 'o', 'u', 'x', 'X' => fmtInt(o, a, spec, st.int(), conv),
            'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => fmtFloat(o, a, spec, st.float(), if (conv == 'a') 'e' else if (conv == 'A') 'E' else conv),
            else => {
                st.sh.errMsg("printf: `{c}': invalid format character", .{conv});
                st.status = 1;
                st.stop = true;
                return false;
            },
        }
    }
    return st.ai > start_ai;
}

pub fn b_printf(sh: *Shell, argv: builtins.Args) Error!u8 {
    var i: usize = 1;
    var var_name: ?[]const u8 = null;
    if (i < argv.len and std.mem.eql(u8, argv[i], "-v")) {
        if (i + 1 >= argv.len) {
            sh.errMsg("printf: -v: option requires an argument", .{});
            return 2;
        }
        var_name = argv[i + 1];
        i += 2;
    }
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len) {
        sh.errMsg("printf: usage: printf [-v var] format [arguments]", .{});
        return 2;
    }
    const fmt: []const u8 = argv[i];
    var st = State{ .sh = sh, .args = argv[i + 1 ..] };
    var o = Out{ .a = sh.scratchAlloc() };
    while (true) {
        const consumed = runFormat(&st, &o, fmt);
        if (st.stop or !consumed or st.ai >= st.args.len) break;
    }
    if (var_name) |vn| {
        try sh.setVar(vn, o.buf.items);
    } else {
        sh.write(o.buf.items);
        sh.flushOut();
    }
    return st.status;
}
