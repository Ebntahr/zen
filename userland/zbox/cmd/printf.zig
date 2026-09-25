const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: printf FORMAT [ARGUMENT]...
    \\  or:  printf OPTION
    \\Print ARGUMENT(s) according to FORMAT.
    \\
    \\FORMAT controls the output as in C printf.  Interpreted sequences are:
    \\  \"      double quote            \\      backslash
    \\  \a      alert (BEL)             \b      backspace
    \\  \c      produce no further output
    \\  \e      escape                  \f      form feed
    \\  \n      new line                \r      carriage return
    \\  \t      horizontal tab          \v      vertical tab
    \\  \NNN    byte with octal value NNN (1 to 3 digits)
    \\  \xHH    byte with hexadecimal value HH (1 to 2 digits)
    \\  \uHHHH  Unicode character with hex value HHHH (4 digits)
    \\  %%      a single %
    \\  %b      ARGUMENT as a string with '\' escapes interpreted
    \\  %q      ARGUMENT printed in a format that can be reused as shell input
    \\
    \\and all C format specifications ending with one of diouxXfeEgGcs, with
    \\ARGUMENTs converted to proper type first.  Variable widths are handled.
    \\The FORMAT is reused as necessary to consume all ARGUMENTs.
    \\
;

// ---------------------------------------------------------------------------
// Exact decimal expansion of f64 (so rounding matches glibc)
// ---------------------------------------------------------------------------

const Limbs = 40;
const Big = struct {
    l: [Limbs]u32 = [_]u32{0} ** Limbs,
    n: usize = 0, // used limbs

    fn fromU64(v: u64) Big {
        var b: Big = .{};
        b.l[0] = @truncate(v);
        b.l[1] = @truncate(v >> 32);
        b.n = 2;
        b.trim();
        return b;
    }
    fn trim(b: *Big) void {
        while (b.n > 0 and b.l[b.n - 1] == 0) b.n -= 1;
    }
    fn shl(b: *Big, bits: usize) void {
        const limbs = bits / 32;
        const r: u5 = @intCast(bits % 32);
        var i: usize = b.n + limbs + 1;
        if (i > Limbs) i = Limbs;
        while (i > 0) {
            i -= 1;
            var v: u32 = 0;
            if (i >= limbs) {
                const src = i - limbs;
                v = if (src < b.n) b.l[src] << r else 0;
                if (r != 0 and src >= 1 and src - 1 < b.n) v |= b.l[src - 1] >> @intCast(32 - @as(u6, r));
            }
            b.l[i] = v;
        }
        b.n = @min(b.n + limbs + 1, Limbs);
        b.trim();
    }
    /// Divide by small value, return remainder.
    fn divSmall(b: *Big, d: u32) u32 {
        var rem: u64 = 0;
        var i = b.n;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 32) | b.l[i];
            b.l[i] = @intCast(cur / d);
            rem = cur % d;
        }
        b.trim();
        return @intCast(rem);
    }
    fn mulSmall(b: *Big, m: u32) void {
        var carry: u64 = 0;
        for (0..b.n) |i| {
            const cur = @as(u64, b.l[i]) * m + carry;
            b.l[i] = @truncate(cur);
            carry = cur >> 32;
        }
        if (carry != 0 and b.n < Limbs) {
            b.l[b.n] = @intCast(carry);
            b.n += 1;
        }
    }
    fn isZero(b: *const Big) bool {
        return b.n == 0;
    }
    /// Extract bits >= sh (as small int, assumes < 2^32) and clear them.
    fn takeHigh(b: *Big, sh: usize) u32 {
        const li = sh / 32;
        const r: u5 = @intCast(sh % 32);
        var v: u64 = 0;
        if (li < b.n) v = b.l[li] >> r;
        if (li + 1 < b.n and r != 0) v |= @as(u64, b.l[li + 1]) << @intCast(32 - @as(u6, r));
        // clear
        if (li < Limbs) {
            if (r == 0) b.l[li] = 0 else b.l[li] &= (@as(u32, 1) << r) - 1;
            var k = li + 1;
            while (k < b.n) : (k += 1) b.l[k] = 0;
        }
        b.trim();
        return @truncate(v);
    }
};

pub const Dec = struct {
    digits: [1500]u8 = undefined,
    n: usize = 0,
    /// Number of digits before the decimal point (may be <= 0 after trimming).
    point: i32 = 0,
    neg: bool = false,

    pub fn init(v_in: f64) Dec {
        var d: Dec = .{};
        const bits: u64 = @bitCast(v_in);
        d.neg = bits >> 63 != 0;
        const exp_bits: i32 = @intCast((bits >> 52) & 0x7ff);
        var mant: u64 = bits & ((@as(u64, 1) << 52) - 1);
        var e: i32 = undefined;
        if (exp_bits == 0) {
            e = -1074;
        } else {
            mant |= @as(u64, 1) << 52;
            e = exp_bits - 1075;
        }
        if (mant == 0) {
            d.point = 1;
            d.digits[0] = '0';
            d.n = 1;
            return d;
        }
        // integer part
        var ip: Big = undefined;
        var frac: Big = .{};
        var sh: usize = 0;
        if (e >= 0) {
            ip = Big.fromU64(mant);
            ip.shl(@intCast(e));
        } else {
            sh = @intCast(-e);
            if (sh >= 64) ip = .{} else ip = Big.fromU64(mant >> @intCast(sh));
            const fm = if (sh >= 64) mant else mant & ((@as(u64, 1) << @intCast(sh)) - 1);
            frac = Big.fromU64(fm);
        }
        // integer digits (reverse)
        var tmp: [400]u8 = undefined;
        var tn: usize = 0;
        while (!ip.isZero()) {
            tmp[tn] = '0' + @as(u8, @intCast(ip.divSmall(10)));
            tn += 1;
        }
        var i: usize = 0;
        while (i < tn) : (i += 1) d.digits[i] = tmp[tn - 1 - i];
        d.n = tn;
        d.point = @intCast(tn);
        // fraction digits
        while (!frac.isZero() and d.n < d.digits.len) {
            frac.mulSmall(10);
            const dig = frac.takeHigh(sh);
            d.digits[d.n] = '0' + @as(u8, @intCast(dig));
            d.n += 1;
        }
        // strip leading zeros (for pure fractions), adjusting point
        var lead: usize = 0;
        while (lead < d.n and d.digits[lead] == '0') lead += 1;
        if (lead > 0 and lead < d.n) {
            mem.copyForwards(u8, d.digits[0 .. d.n - lead], d.digits[lead..d.n]);
            d.n -= lead;
            d.point -= @intCast(lead);
        }
        return d;
    }

    fn digitAt(d: *const Dec, i: i64) u8 {
        if (i < 0 or i >= d.n) return '0';
        return d.digits[@intCast(i)];
    }

    /// Round to keep `keep` significant digits (index from first digit), half-to-even.
    fn roundDigits(d: *Dec, keep_in: i64) void {
        var keep = keep_in;
        if (keep < 0) {
            // everything rounds to zero (or to one unit at position keep)
            d.n = 0;
            return;
        }
        if (keep >= d.n) return;
        const k: usize = @intCast(keep);
        const next = d.digits[k];
        var up = false;
        if (next > '5') up = true else if (next == '5') {
            var rest_nonzero = false;
            for (d.digits[k + 1 .. d.n]) |x| if (x != '0') {
                rest_nonzero = true;
                break;
            };
            if (rest_nonzero) up = true else {
                const prev = if (k > 0) d.digits[k - 1] else '0';
                up = (prev - '0') % 2 == 1;
            }
        }
        d.n = k;
        if (up) {
            var j = k;
            while (j > 0) {
                j -= 1;
                if (d.digits[j] == '9') {
                    d.digits[j] = '0';
                } else {
                    d.digits[j] += 1;
                    return;
                }
            }
            // carry out: prepend 1
            mem.copyBackwards(u8, d.digits[1 .. d.n + 1], d.digits[0..d.n]);
            d.digits[0] = '1';
            d.n += 1;
            d.point += 1;
            keep += 1;
        }
    }
};

fn isZeroDec(d: *const Dec) bool {
    for (d.digits[0..d.n]) |x| if (x != '0') return false;
    return true;
}

/// Write fixed notation with `prec` fraction digits into buf.
fn fixedStr(buf: []u8, v: f64, prec: usize) []const u8 {
    var d = Dec.init(@abs(v));
    if (isZeroDec(&d)) {
        d.n = 0;
        d.point = 1;
    }
    d.roundDigits(@as(i64, d.point) + @as(i64, @intCast(prec)));
    var n: usize = 0;
    if (d.point <= 0) {
        buf[n] = '0';
        n += 1;
    } else {
        var i: i64 = 0;
        while (i < d.point) : (i += 1) {
            buf[n] = d.digitAt(i);
            n += 1;
        }
    }
    if (prec > 0) {
        buf[n] = '.';
        n += 1;
        var i: i64 = 0;
        while (i < prec) : (i += 1) {
            buf[n] = d.digitAt(@as(i64, d.point) + i);
            n += 1;
        }
    }
    return buf[0..n];
}

/// Scientific: returns mantissa digits string "d.ddd" and exponent.
fn sciStr(buf: []u8, v: f64, prec: usize) struct { []const u8, i32 } {
    var d = Dec.init(@abs(v));
    if (isZeroDec(&d)) {
        var n: usize = 0;
        buf[0] = '0';
        n = 1;
        if (prec > 0) {
            buf[1] = '.';
            n = 2;
            @memset(buf[2 .. 2 + prec], '0');
            n += prec;
        }
        return .{ buf[0..n], 0 };
    }
    d.roundDigits(@intCast(prec + 1));
    var n: usize = 0;
    buf[0] = d.digitAt(0);
    n = 1;
    if (prec > 0) {
        buf[1] = '.';
        n = 2;
        var i: usize = 1;
        while (i <= prec) : (i += 1) {
            buf[n] = d.digitAt(@intCast(i));
            n += 1;
        }
    }
    return .{ buf[0..n], d.point - 1 };
}

// ---------------------------------------------------------------------------
// Conversion specs
// ---------------------------------------------------------------------------

pub const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    hash: bool = false,
    zero: bool = false,
    width: ?usize = null,
    prec: ?usize = null,
    conv: u8 = 's',
};

fn emitPadded(w: *std.Io.Writer, s: Spec, sign: []const u8, prefix: []const u8, body: []const u8, allow_zero: bool) !void {
    const len = sign.len + prefix.len + body.len;
    const width = s.width orelse 0;
    const padn = if (width > len) width - len else 0;
    if (s.minus) {
        try w.writeAll(sign);
        try w.writeAll(prefix);
        try w.writeAll(body);
        try w.splatByteAll(' ', padn);
    } else if (s.zero and allow_zero) {
        try w.writeAll(sign);
        try w.writeAll(prefix);
        try w.splatByteAll('0', padn);
        try w.writeAll(body);
    } else {
        try w.splatByteAll(' ', padn);
        try w.writeAll(sign);
        try w.writeAll(prefix);
        try w.writeAll(body);
    }
}

pub fn fmtSigned(w: *std.Io.Writer, s: Spec, v: i64) !void {
    const neg = v < 0;
    const mag: u64 = @abs(v);
    const sign: []const u8 = if (neg) "-" else if (s.plus) "+" else if (s.space) " " else "";
    try fmtMag(w, s, mag, sign, 10, false);
}

pub fn fmtUnsigned(w: *std.Io.Writer, s: Spec, v: u64) !void {
    switch (s.conv) {
        'o' => try fmtMag(w, s, v, "", 8, false),
        'x' => try fmtMag(w, s, v, "", 16, false),
        'X' => try fmtMag(w, s, v, "", 16, true),
        else => try fmtMag(w, s, v, "", 10, false),
    }
}

fn fmtMag(w: *std.Io.Writer, s: Spec, mag: u64, sign: []const u8, base: u8, upper: bool) !void {
    var dbuf: [80]u8 = undefined;
    var digits: []const u8 = std.fmt.bufPrint(&dbuf, "{d}", .{mag}) catch unreachable;
    if (base == 16) digits = (if (upper) std.fmt.bufPrint(&dbuf, "{X}", .{mag}) else std.fmt.bufPrint(&dbuf, "{x}", .{mag})) catch unreachable;
    if (base == 8) digits = std.fmt.bufPrint(&dbuf, "{o}", .{mag}) catch unreachable;
    var pbuf: [600]u8 = undefined;
    var body: []const u8 = digits;
    if (s.prec) |p| {
        if (p == 0 and mag == 0) {
            body = "";
        } else if (p > digits.len and p < pbuf.len) {
            @memset(pbuf[0 .. p - digits.len], '0');
            @memcpy(pbuf[p - digits.len .. p], digits);
            body = pbuf[0..p];
        }
    }
    var prefix: []const u8 = "";
    if (s.hash) {
        if (base == 8 and (body.len == 0 or body[0] != '0')) prefix = "0";
        if (base == 16 and mag != 0) prefix = if (upper) "0X" else "0x";
    }
    try emitPadded(w, s, sign, prefix, body, s.prec == null);
}

pub fn fmtFloat(w: *std.Io.Writer, s: Spec, v: f64) !void {
    const neg = std.math.signbit(v);
    const sign: []const u8 = if (neg) "-" else if (s.plus) "+" else if (s.space) " " else "";
    const upper = std.ascii.isUpper(s.conv);
    if (std.math.isNan(v) or std.math.isInf(v)) {
        const body: []const u8 = if (std.math.isNan(v)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        return emitPadded(w, s, sign, "", body, false);
    }
    const av = @abs(v);
    var buf: [1600]u8 = undefined;
    switch (std.ascii.toLower(s.conv)) {
        'f' => {
            const p = @min(s.prec orelse 6, 1000);
            var body = fixedStr(&buf, av, p);
            if (s.hash and p == 0) {
                buf[body.len] = '.';
                body = buf[0 .. body.len + 1];
            }
            try emitPadded(w, s, sign, "", body, true);
        },
        'e' => {
            const p = @min(s.prec orelse 6, 1000);
            const r = sciStr(&buf, av, p);
            var n = r[0].len;
            if (s.hash and p == 0) {
                buf[n] = '.';
                n += 1;
            }
            const es = std.fmt.bufPrint(buf[n..], "{c}{c}{d:0>2}", .{ if (upper) @as(u8, 'E') else 'e', if (r[1] < 0) @as(u8, '-') else '+', @abs(r[1]) }) catch unreachable;
            try emitPadded(w, s, sign, "", buf[0 .. n + es.len], true);
        },
        'g' => {
            var p = s.prec orelse 6;
            if (p == 0) p = 1;
            p = @min(p, 1000);
            // exponent after rounding to p significant digits
            var x: i32 = 0;
            if (av != 0) {
                var tmp: [1600]u8 = undefined;
                x = sciStr(&tmp, av, p - 1)[1];
            }
            var body: []const u8 = undefined;
            var exp_part: []const u8 = "";
            var ebuf: [16]u8 = undefined;
            if (@as(i64, @intCast(p)) > x and x >= -4) {
                body = fixedStr(&buf, av, @intCast(@as(i64, @intCast(p)) - 1 - x));
            } else {
                const r = sciStr(&buf, av, p - 1);
                body = r[0];
                exp_part = std.fmt.bufPrint(&ebuf, "{c}{c}{d:0>2}", .{ if (upper) @as(u8, 'E') else 'e', if (r[1] < 0) @as(u8, '-') else '+', @abs(r[1]) }) catch unreachable;
            }
            if (!s.hash) {
                if (mem.indexOfScalar(u8, body, '.') != null) {
                    var e = body.len;
                    while (e > 0 and body[e - 1] == '0') e -= 1;
                    if (e > 0 and body[e - 1] == '.') e -= 1;
                    body = body[0..e];
                }
            } else if (mem.indexOfScalar(u8, body, '.') == null) {
                buf[body.len] = '.';
                body = buf[0 .. body.len + 1];
            }
            var all: [1700]u8 = undefined;
            @memcpy(all[0..body.len], body);
            @memcpy(all[body.len .. body.len + exp_part.len], exp_part);
            try emitPadded(w, s, sign, "", all[0 .. body.len + exp_part.len], true);
        },
        'a' => {
            // hexadecimal floating point
            const bits: u64 = @bitCast(av);
            const eb: i32 = @intCast((bits >> 52) & 0x7ff);
            var mant: u64 = bits & ((@as(u64, 1) << 52) - 1);
            var lead: u8 = '1';
            var e: i32 = eb - 1023;
            if (eb == 0) {
                if (mant == 0) {
                    lead = '0';
                    e = 0;
                } else {
                    lead = '0';
                    e = -1022;
                }
            }
            var hex: [13]u8 = undefined;
            var k: usize = 0;
            while (k < 13) : (k += 1) {
                const nib: u8 = @intCast((mant >> @intCast(48 - 4 * k)) & 0xf);
                hex[k] = if (upper) "0123456789ABCDEF"[nib] else "0123456789abcdef"[nib];
            }
            var hn: usize = 13;
            if (s.prec) |p| {
                if (p < 13) {
                    // round half-even at nibble p
                    const drop: u6 = @intCast(4 * (13 - p));
                    const rem = mant & ((@as(u64, 1) << drop) - 1);
                    const half = @as(u64, 1) << (drop - 1);
                    mant >>= drop;
                    if (rem > half or (rem == half and mant & 1 == 1)) mant += 1;
                    if (p == 0 or mant >> @intCast(4 * p) != 0) {
                        if (mant >> @intCast(4 * p) != 0) {
                            lead += 1;
                            mant &= (@as(u64, 1) << @intCast(4 * p)) - 1;
                        }
                    }
                    k = 0;
                    while (k < p) : (k += 1) {
                        const nib: u8 = @intCast((mant >> @intCast(4 * (p - 1 - k))) & 0xf);
                        hex[k] = if (upper) "0123456789ABCDEF"[nib] else "0123456789abcdef"[nib];
                    }
                }
                hn = @min(p, 13);
            } else {
                while (hn > 0 and hex[hn - 1] == '0') hn -= 1;
            }
            const body = std.fmt.bufPrint(&buf, "{c}{s}{s}{c}{c}{d}", .{ lead, if (hn > 0 or s.hash) "." else "", hex[0..hn], if (upper) @as(u8, 'P') else 'p', if (e < 0) @as(u8, '-') else '+', @abs(e) }) catch unreachable;
            try emitPadded(w, s, sign, if (upper) "0X" else "0x", body, true);
        },
        else => unreachable,
    }
}

pub fn fmtString(w: *std.Io.Writer, s: Spec, str: []const u8) !void {
    var body = str;
    if (s.prec) |p| if (p < body.len) {
        body = body[0..p];
    };
    try emitPadded(w, s, "", "", body, false);
}

/// Parse "%[flags][width][.prec]conv" starting after '%'. Returns spec and index after conv.
/// Width/precision '*' are flagged via star fields.
pub const ParsedSpec = struct { spec: Spec, end: usize, width_star: bool, prec_star: bool };

pub fn parseSpec(f: []const u8, start: usize) ?ParsedSpec {
    return parseSpecEx(f, start, true);
}

pub fn parseSpecEx(f: []const u8, start: usize, length_mods: bool) ?ParsedSpec {
    var i = start;
    var s: Spec = .{};
    while (i < f.len) : (i += 1) {
        switch (f[i]) {
            '-' => s.minus = true,
            '+' => s.plus = true,
            ' ' => s.space = true,
            '#' => s.hash = true,
            '0' => s.zero = true,
            '\'' => {},
            else => break,
        }
    }
    var ws = false;
    var ps = false;
    if (i < f.len and f[i] == '*') {
        ws = true;
        i += 1;
    } else {
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) s.width = (s.width orelse 0) *| 10 +| (f[i] - '0');
    }
    if (i < f.len and f[i] == '.') {
        i += 1;
        s.prec = 0;
        if (i < f.len and f[i] == '*') {
            ps = true;
            i += 1;
        } else {
            while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) s.prec = s.prec.? *| 10 +| (f[i] - '0');
        }
    }
    // length modifiers are accepted and ignored
    if (length_mods) while (i < f.len and mem.indexOfScalar(u8, "hlLjzt", f[i]) != null) {
        i += 1;
    };
    if (i >= f.len) return null;
    s.conv = f[i];
    return .{ .spec = s, .end = i + 1, .width_star = ws, .prec_star = ps };
}

// ---------------------------------------------------------------------------
// printf command
// ---------------------------------------------------------------------------

var status: u8 = 0;

fn numErr(arg: []const u8, complete: bool) void {
    if (complete) {
        c.warn("{f}: expected a numeric value", .{c.q(arg)});
    } else c.warn("{f}: value not completely converted", .{c.q(arg)});
    status = 1;
}

/// Parse integer argument like GNU printf (handles 'c, 0x, 0 octal, +/-).
fn argInt(a: []const u8) i64 {
    if (a.len >= 2 and (a[0] == '\'' or a[0] == '"')) {
        // character value (first byte / code point)
        const cp = std.unicode.utf8Decode(a[1..@min(a.len, 1 + (std.unicode.utf8ByteSequenceLength(a[1]) catch 1))]) catch a[1];
        return cp;
    }
    const t = mem.trimLeft(u8, a, " \t\n");
    if (t.len == 0) {
        if (a.len != 0) numErr(a, true);
        return 0;
    }
    var i: usize = 0;
    var neg = false;
    if (t[0] == '-' or t[0] == '+') {
        neg = t[0] == '-';
        i = 1;
    }
    var base: u8 = 10;
    if (i + 1 < t.len and t[i] == '0' and (t[i + 1] == 'x' or t[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i < t.len and t[i] == '0') base = 8;
    const ds = i;
    var v: u64 = 0;
    var overflow = false;
    while (i < t.len) : (i += 1) {
        const dv = std.fmt.charToDigit(t[i], base) catch break;
        const r = @mulWithOverflow(v, base);
        const r2 = @addWithOverflow(r[0], dv);
        if (r[1] != 0 or r2[1] != 0) overflow = true;
        v = r2[0];
    }
    if (i == ds) {
        numErr(a, true);
        return 0;
    }
    if (i < t.len) numErr(a, false);
    if (overflow) {
        c.warn("{f}: Numerical result out of range", .{c.q(a)});
        status = 1;
        return if (neg) std.math.minInt(i64) else std.math.maxInt(i64);
    }
    if (neg) {
        if (v > @as(u64, std.math.maxInt(i64)) + 1) return std.math.minInt(i64);
        return @intCast(-@as(i128, v));
    }
    return @bitCast(v);
}

fn argUint(a: []const u8) u64 {
    const t = mem.trimLeft(u8, a, " \t\n");
    if (t.len > 0 and t[0] == '-') {
        const v = argInt(a);
        return @bitCast(v);
    }
    const v = argInt(a);
    return @bitCast(v);
}

pub fn parseFloatArg(a: []const u8) ?f64 {
    const t = mem.trim(u8, a, " \t\n");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

fn argFloat(a: []const u8) f64 {
    if (a.len >= 2 and (a[0] == '\'' or a[0] == '"')) return @floatFromInt(argInt(a));
    if (parseFloatArg(a)) |v| return v;
    // partial conversion: longest valid prefix
    const t = mem.trimLeft(u8, a, " \t\n");
    var k = t.len;
    while (k > 0) : (k -= 1) {
        if (std.fmt.parseFloat(f64, t[0..k])) |v| {
            numErr(a, false);
            return v;
        } else |_| {}
    }
    numErr(a, true);
    return 0;
}

/// Process %b argument; returns false if \c encountered.
fn writeB(w: *std.Io.Writer, s: []const u8) !bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try w.writeByte(s[i]);
            i += 1;
            continue;
        }
        if (s[i + 1] == 'c') return false;
        var tmp: [8]u8 = undefined;
        // %b: \0NNN or \NNN octal
        if (s[i + 1] == '0') {
            var v: u32 = 0;
            var k: usize = i + 2;
            while (k < s.len and k < i + 5 and s[k] >= '0' and s[k] <= '7') : (k += 1) v = v * 8 + (s[k] - '0');
            try w.writeByte(@truncate(v));
            i = k;
            continue;
        }
        const r = c.unescapeOne(s[i..], &tmp, false);
        try w.writeAll(r[0]);
        i += r[1];
    }
    return true;
}

/// Process one format pass; returns number of args consumed, or null if \c stop.
fn doFormat(w: *std.Io.Writer, f: []const u8, args: []const []const u8, used_any: *bool) !?usize {
    var ai: usize = 0;
    var i: usize = 0;
    while (i < f.len) {
        const ch = f[i];
        if (ch == '\\') {
            if (i + 1 < f.len and f[i + 1] == 'c') return null;
            var tmp: [8]u8 = undefined;
            if (i + 1 < f.len and f[i + 1] == '"') {
                try w.writeByte('"');
                i += 2;
                continue;
            }
            const r = c.unescapeOne(f[i..], &tmp, false);
            try w.writeAll(r[0]);
            i += r[1];
            continue;
        }
        if (ch != '%') {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        if (i + 1 < f.len and f[i + 1] == '%') {
            try w.writeByte('%');
            i += 2;
            continue;
        }
        const ps = parseSpec(f, i + 1) orelse {
            c.fatal("{s}: invalid conversion specification", .{f[i..]});
        };
        var s = ps.spec;
        used_any.* = true;
        if (ps.width_star) {
            const a = if (ai < args.len) args[ai] else "";
            ai += 1;
            const wv = argInt(a);
            if (wv < 0) {
                s.minus = true;
                s.width = @intCast(@min(-wv, 1 << 20));
            } else s.width = @intCast(@min(wv, 1 << 20));
        }
        if (ps.prec_star) {
            const a = if (ai < args.len) args[ai] else "";
            ai += 1;
            const pv = argInt(a);
            s.prec = if (pv < 0) null else @intCast(@min(pv, 1 << 20));
        }
        const have = ai < args.len;
        const a: []const u8 = if (have) args[ai] else "";
        switch (s.conv) {
            'd', 'i' => {
                try fmtSigned(w, s, if (have) argInt(a) else 0);
                ai += 1;
            },
            'o', 'u', 'x', 'X' => {
                try fmtUnsigned(w, s, if (have) argUint(a) else 0);
                ai += 1;
            },
            'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
                try fmtFloat(w, s, if (have) argFloat(a) else 0);
                ai += 1;
            },
            'c' => {
                var b: [1]u8 = .{0};
                const body: []const u8 = if (a.len > 0) a[0..1] else if (have) &b else "";
                var s2 = s;
                s2.prec = null;
                if (!have) {
                    try emitPadded(w, s2, "", "", &b, false);
                } else try emitPadded(w, s2, "", "", body, false);
                ai += 1;
            },
            's' => {
                try fmtString(w, s, a);
                ai += 1;
            },
            'b' => {
                var tmpw: std.Io.Writer.Allocating = .init(c.gpa);
                const cont = try writeB(&tmpw.writer, a);
                try fmtString(w, s, tmpw.written());
                ai += 1;
                if (!cont) return null;
            },
            'q' => {
                var tmpw: std.Io.Writer.Allocating = .init(c.gpa);
                if (a.len == 0) try tmpw.writer.writeAll("''") else try c.writeQuoted(&tmpw.writer, a, false);
                try fmtString(w, s, tmpw.written());
                ai += 1;
            },
            else => c.fatal("{s}: invalid conversion specification", .{f[i..ps.end]}),
        }
        i = ps.end;
    }
    return ai;
}

pub fn main(args: c.Args) !u8 {
    var start: usize = 1;
    if (args.len >= 2) {
        if (c.eql(args[1], "--help")) c.printHelp();
        if (c.eql(args[1], "--version")) c.printVersion();
        if (c.eql(args[1], "--")) start = 2;
    }
    if (args.len <= start) c.usageErr("missing operand", .{});
    const f = args[start];
    var rest: []const []const u8 = args[start + 1 ..];
    const w = c.out;
    while (true) {
        var used_any = false;
        const consumed = (try doFormat(w, f, rest, &used_any)) orelse break;
        if (!used_any or consumed == 0) {
            if (rest.len > 0 and !used_any) c.warn("warning: ignoring excess arguments, starting with {f}", .{c.q(rest[0])});
            break;
        }
        if (consumed >= rest.len) break;
        rest = rest[consumed..];
    }
    return status;
}

test "printf float formatting" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try fmtFloat(&w, .{ .conv = 'f', .prec = 2 }, 2.675);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'f', .prec = 0 }, 2.5);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'g' }, 0.0001);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'g' }, 123456789.0);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'e', .prec = 3 }, 12345.678);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'f' }, 1e20);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'g' }, 100000.0);
    try w.writeByte(' ');
    try fmtFloat(&w, .{ .conv = 'a' }, 1.0);
    try std.testing.expectEqualStrings("2.67 2 0.0001 1.23457e+08 1.235e+04 100000000000000000000.000000 100000 0x1p+0", w.buffered());
}

test "printf integer formatting" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try fmtSigned(&w, .{ .conv = 'd', .width = 5, .zero = true }, -42);
    try w.writeByte('|');
    try fmtUnsigned(&w, .{ .conv = 'x', .hash = true }, 255);
    try w.writeByte('|');
    try fmtSigned(&w, .{ .conv = 'd', .minus = true, .width = 4 }, 7);
    try w.writeByte('|');
    try fmtSigned(&w, .{ .conv = 'd', .prec = 3, .plus = true }, 5);
    try w.writeByte('|');
    try fmtUnsigned(&w, .{ .conv = 'o', .hash = true }, 8);
    try std.testing.expectEqualStrings("-0042|0xff|7   |+005|010", w.buffered());
}
