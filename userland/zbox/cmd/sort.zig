const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: sort [OPTION]... [FILE]...
    \\Write sorted concatenation of all FILE(s) to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\Ordering options:
    \\  -b, --ignore-leading-blanks  ignore leading blanks
    \\  -d, --dictionary-order      consider only blanks and alphanumeric characters
    \\  -f, --ignore-case           fold lower case to upper case characters
    \\  -g, --general-numeric-sort  compare according to general numerical value
    \\  -i, --ignore-nonprinting    consider only printable characters
    \\  -M, --month-sort            compare (unknown) < 'JAN' < ... < 'DEC'
    \\  -h, --human-numeric-sort    compare human readable numbers (e.g., 2K 1G)
    \\  -n, --numeric-sort          compare according to string numerical value
    \\  -R, --random-sort           shuffle, but group identical keys
    \\  -r, --reverse               reverse the result of comparisons
    \\  -V, --version-sort          natural sort of (version) numbers within text
    \\
    \\Other options:
    \\  -c, --check                 check for sorted input; do not sort
    \\  -C, --check=quiet           like -c, but do not report first bad line
    \\  -k, --key=KEYDEF            sort via a key; KEYDEF gives location and type
    \\  -m, --merge                 merge already sorted files; do not sort
    \\  -o, --output=FILE           write result to FILE instead of standard output
    \\  -s, --stable                stabilize sort by disabling last-resort comparison
    \\  -t, --field-separator=SEP   use SEP instead of non-blank to blank transition
    \\  -u, --unique                output only the first of an equal run
    \\  -z, --zero-terminated       line delimiter is NUL, not newline
    \\
    \\KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a
    \\field number and C a character position in the field; both are origin 1, and
    \\the stop position defaults to the line's end.  OPTS is one or more
    \\single-letter ordering options [bdfgiMhnRrV], which override global ordering
    \\options for that key.
    \\
;

const KOpts = struct {
    b_start: bool = false,
    b_end: bool = false,
    d: bool = false,
    f: bool = false,
    g: bool = false,
    h: bool = false,
    i: bool = false,
    M: bool = false,
    n: bool = false,
    R: bool = false,
    r: bool = false,
    V: bool = false,

    fn any(o: KOpts) bool {
        return o.b_start or o.b_end or o.d or o.f or o.g or o.h or o.i or o.M or o.n or o.R or o.r or o.V;
    }
};

const Key = struct {
    sword: usize = 0, // 0-based
    schar: usize = 0, // 0-based
    eword: ?usize = null, // 0-based; null = end of line
    echar: usize = 0,
    o: KOpts = .{},
};

var keys: std.ArrayList(Key) = .empty;
var gopts: KOpts = .{};
var tab: ?u8 = null;
var stable = false;
var unique = false;
var rand_seed: u64 = 0;

fn isBlank(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn begfield(line: []const u8, k: Key) usize {
    var ptr: usize = 0;
    const lim = line.len;
    var sword = k.sword;
    if (tab) |t| {
        while (ptr < lim and sword > 0) : (sword -= 1) {
            while (ptr < lim and line[ptr] != t) ptr += 1;
            if (ptr < lim) ptr += 1;
        }
    } else {
        while (ptr < lim and sword > 0) : (sword -= 1) {
            while (ptr < lim and isBlank(line[ptr])) ptr += 1;
            while (ptr < lim and !isBlank(line[ptr])) ptr += 1;
        }
    }
    if (k.o.b_start) while (ptr < lim and isBlank(line[ptr])) {
        ptr += 1;
    };
    return @min(lim, ptr + k.schar);
}

fn limfield(line: []const u8, k: Key) usize {
    const lim = line.len;
    var eword = k.eword orelse return lim;
    const echar = k.echar;
    if (echar == 0) eword += 1;
    var ptr: usize = 0;
    if (tab) |t| {
        while (ptr < lim and eword > 0) {
            eword -= 1;
            while (ptr < lim and line[ptr] != t) ptr += 1;
            if (ptr < lim and (eword > 0 or echar > 0)) ptr += 1;
        }
    } else {
        while (ptr < lim and eword > 0) : (eword -= 1) {
            while (ptr < lim and isBlank(line[ptr])) ptr += 1;
            while (ptr < lim and !isBlank(line[ptr])) ptr += 1;
        }
    }
    if (echar != 0) {
        if (k.o.b_end) while (ptr < lim and isBlank(line[ptr])) {
            ptr += 1;
        };
        ptr = @min(lim, ptr + echar);
    }
    return ptr;
}

const Num = struct { neg: bool, int: []const u8, frac: []const u8 };

fn parseNum(s_in: []const u8) Num {
    var s = s_in;
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    s = s[i..];
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    var k: usize = 0;
    while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
    var int = s[0..k];
    while (int.len > 0 and int[0] == '0') int = int[1..];
    var frac: []const u8 = "";
    if (k < s.len and s[k] == '.') {
        var e = k + 1;
        while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
        frac = s[k + 1 .. e];
        while (frac.len > 0 and frac[frac.len - 1] == '0') frac = frac[0 .. frac.len - 1];
    }
    if (int.len == 0 and frac.len == 0) neg = false;
    return .{ .neg = neg, .int = int, .frac = frac };
}

fn numCompare(a: []const u8, b: []const u8) i32 {
    const x = parseNum(a);
    const y = parseNum(b);
    if (x.neg != y.neg) return if (x.neg) -1 else 1;
    var r: i32 = 0;
    if (x.int.len != y.int.len) {
        r = if (x.int.len < y.int.len) -1 else 1;
    } else {
        r = orderToInt(mem.order(u8, x.int, y.int));
        if (r == 0) r = orderToInt(mem.order(u8, x.frac, y.frac));
    }
    return if (x.neg) -r else r;
}

fn orderToInt(o: std.math.Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn scanFloat(s: []const u8) ?f64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    const start = i;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    // inf / nan
    if (s.len - i >= 3) {
        const w = s[i..@min(s.len, i + 8)];
        if (std.ascii.startsWithIgnoreCase(w, "inf") or std.ascii.startsWithIgnoreCase(w, "nan")) {
            var e = i + 3;
            if (std.ascii.startsWithIgnoreCase(s[i..], "infinity")) e = i + 8;
            return std.fmt.parseFloat(f64, s[start..e]) catch null;
        }
    }
    var digits = false;
    const hex = i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X');
    if (hex) i += 2;
    while (i < s.len and (if (hex) std.ascii.isHex(s[i]) else std.ascii.isDigit(s[i]))) : (i += 1) digits = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and (if (hex) std.ascii.isHex(s[i]) else std.ascii.isDigit(s[i]))) : (i += 1) digits = true;
    }
    if (!digits) return null;
    if (i < s.len and ((!hex and (s[i] == 'e' or s[i] == 'E')) or (hex and (s[i] == 'p' or s[i] == 'P')))) {
        var j = i + 1;
        if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
        const ds = j;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j > ds) i = j;
    }
    var t = s[start..i];
    if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    return std.fmt.parseFloat(f64, t) catch null;
}

fn generalCompare(a: []const u8, b: []const u8) i32 {
    const x = scanFloat(a);
    const y = scanFloat(b);
    if (x == null) return if (y == null) 0 else -1;
    if (y == null) return 1;
    const xv = x.?;
    const yv = y.?;
    if (xv < yv) return -1;
    if (xv > yv) return 1;
    if (xv == yv) return 0;
    if (std.math.isNan(xv) and !std.math.isNan(yv)) return -1;
    if (std.math.isNan(yv) and !std.math.isNan(xv)) return 1;
    return 0;
}

fn unitOrder(s_in: []const u8) i32 {
    var s = s_in;
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    s = s[i..];
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    var k: usize = 0;
    while (k < s.len and (std.ascii.isDigit(s[k]) or s[k] == '.')) k += 1;
    if (k >= s.len) return 0;
    const units = "KMGTPEZYRQ";
    var ord: i32 = 0;
    if (s[k] == 'k') ord = 1 else if (mem.indexOfScalar(u8, units, s[k])) |u| ord = @intCast(u + 1);
    return if (neg) -ord else ord;
}

fn humanCompare(a: []const u8, b: []const u8) i32 {
    const d = unitOrder(a) - unitOrder(b);
    if (d != 0) return if (d < 0) -1 else 1;
    return numCompare(a, b);
}

fn monthIndex(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    if (s.len - i < 3) return 0;
    const names = [_][]const u8{ "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };
    for (names, 0..) |n, k| {
        if (std.ascii.eqlIgnoreCase(s[i .. i + 3], n)) return @intCast(k + 1);
    }
    return 0;
}

fn verOrder(ch: ?u8) i32 {
    const x = ch orelse return 0;
    if (std.ascii.isDigit(x)) return 0;
    if (std.ascii.isAlphabetic(x)) return x;
    if (x == '~') return -1;
    return @as(i32, x) + 256;
}

pub fn verrevcmp(a: []const u8, b: []const u8) i32 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        var first_diff: i32 = 0;
        while ((i < a.len and !std.ascii.isDigit(a[i])) or (j < b.len and !std.ascii.isDigit(b[j]))) {
            const ac = verOrder(if (i < a.len) a[i] else null);
            const bc = verOrder(if (j < b.len) b[j] else null);
            if (ac != bc) return ac - bc;
            i += 1;
            j += 1;
        }
        while (i < a.len and a[i] == '0') i += 1;
        while (j < b.len and b[j] == '0') j += 1;
        while (i < a.len and j < b.len and std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            if (first_diff == 0) first_diff = @as(i32, a[i]) - @as(i32, b[j]);
            i += 1;
            j += 1;
        }
        if (i < a.len and std.ascii.isDigit(a[i])) return 1;
        if (j < b.len and std.ascii.isDigit(b[j])) return -1;
        if (first_diff != 0) return first_diff;
    }
    return 0;
}

fn versionCompare(a: []const u8, b: []const u8) i32 {
    if (mem.eql(u8, a, b)) return 0;
    const ah = a.len > 0 and a[0] == '.';
    const bh = b.len > 0 and b[0] == '.';
    if (ah and !bh) return -1;
    if (bh and !ah) return 1;
    const r = verrevcmp(a, b);
    if (r != 0) return if (r < 0) -1 else 1;
    return orderToInt(mem.order(u8, a, b));
}

fn keep(ch: u8, o: KOpts) bool {
    if (o.d and !(std.ascii.isAlphanumeric(ch) or isBlank(ch))) return false;
    if (o.i and !(ch >= 0x20 and ch < 0x7f)) return false;
    return true;
}

fn textCompare(a: []const u8, b: []const u8, o: KOpts) i32 {
    if (!o.d and !o.i and !o.f) return orderToInt(mem.order(u8, a, b));
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !keep(a[i], o)) i += 1;
        while (j < b.len and !keep(b[j], o)) j += 1;
        if (i >= a.len or j >= b.len) break;
        var x = a[i];
        var y = b[j];
        if (o.f) {
            x = std.ascii.toUpper(x);
            y = std.ascii.toUpper(y);
        }
        if (x != y) return if (x < y) -1 else 1;
        i += 1;
        j += 1;
    }
    const ra = i < a.len;
    const rb = j < b.len;
    if (ra == rb) return 0;
    return if (ra) 1 else -1;
}

fn randomHash(s: []const u8) u64 {
    return std.hash.Wyhash.hash(rand_seed, s);
}

fn keyCompare(a: []const u8, b: []const u8, k: Key) i32 {
    const as = begfield(a, k);
    const ae = @max(as, limfield(a, k));
    const bs = begfield(b, k);
    const be = @max(bs, limfield(b, k));
    const ka = a[as..ae];
    const kb = b[bs..be];
    var r: i32 = 0;
    if (k.o.n) {
        r = numCompare(ka, kb);
    } else if (k.o.g) {
        r = generalCompare(ka, kb);
    } else if (k.o.h) {
        r = humanCompare(ka, kb);
    } else if (k.o.M) {
        r = monthIndex(ka) - monthIndex(kb);
    } else if (k.o.V) {
        r = versionCompare(ka, kb);
    } else if (k.o.R) {
        const ha = randomHash(ka);
        const hb = randomHash(kb);
        r = if (ha < hb) -1 else if (ha > hb) @as(i32, 1) else textCompare(ka, kb, k.o);
    } else {
        r = textCompare(ka, kb, k.o);
    }
    return if (k.o.r) -r else r;
}

fn compareKeys(a: []const u8, b: []const u8) i32 {
    for (keys.items) |k| {
        const r = keyCompare(a, b, k);
        if (r != 0) return r;
    }
    return 0;
}

fn compare(a: []const u8, b: []const u8) i32 {
    const r = compareKeys(a, b);
    if (r != 0 or stable or unique) return r;
    const lr = orderToInt(mem.order(u8, a, b));
    return if (gopts.r) -lr else lr;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return compare(a, b) < 0;
}

fn setOrdering(s: []const u8, o: *KOpts, start: bool) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            'b' => if (start) {
                o.b_start = true;
            } else {
                o.b_end = true;
            },
            'd' => o.d = true,
            'f' => o.f = true,
            'g' => o.g = true,
            'h' => o.h = true,
            'i' => o.i = true,
            'M' => o.M = true,
            'n' => o.n = true,
            'R' => o.R = true,
            'r' => o.r = true,
            'V' => o.V = true,
            else => return i,
        }
    }
    return i;
}

fn badKey(spec: []const u8, why: []const u8) noreturn {
    c.fatalCode(2, "invalid field specification {f}: {s}", .{ c.q(spec), why });
}

fn parseKey(spec: []const u8) Key {
    var k: Key = .{};
    var i: usize = 0;
    const readNum = struct {
        fn f(s: []const u8, idx: *usize) ?usize {
            const st = idx.*;
            while (idx.* < s.len and std.ascii.isDigit(s[idx.*])) idx.* += 1;
            if (idx.* == st) return null;
            return std.fmt.parseInt(usize, s[st..idx.*], 10) catch std.math.maxInt(usize);
        }
    }.f;
    const sw = readNum(spec, &i) orelse badKey(spec, "invalid number at field start");
    if (sw == 0) badKey(spec, "field number is zero");
    k.sword = sw - 1;
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        const sc = readNum(spec, &i) orelse badKey(spec, "invalid number after '.'");
        if (sc == 0) badKey(spec, "character offset is zero");
        k.schar = sc - 1;
    }
    var o: KOpts = .{};
    i += setOrdering(spec[i..], &o, true);
    if (i < spec.len and spec[i] == ',') {
        i += 1;
        const ew = readNum(spec, &i) orelse badKey(spec, "invalid number after ','");
        if (ew == 0) badKey(spec, "field number is zero");
        k.eword = ew - 1;
        if (i < spec.len and spec[i] == '.') {
            i += 1;
            k.echar = readNum(spec, &i) orelse badKey(spec, "invalid number after '.'");
        }
        i += setOrdering(spec[i..], &o, false);
    }
    if (i < spec.len) badKey(spec, "stray character in field spec");
    k.o = o;
    return k;
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    var files: std.ArrayList([]const u8) = .empty;
    var check: ?bool = null; // true = report, false = quiet
    var output: ?[]const u8 = null;
    var delim: u8 = '\n';
    var p = c.Parser.init(args, &.{
        .{ "ignore-leading-blanks", 'b' }, .{ "dictionary-order", 'd' }, .{ "ignore-case", 'f' },
        .{ "general-numeric-sort", 'g' },  .{ "ignore-nonprinting", 'i' }, .{ "month-sort", 'M' },
        .{ "human-numeric-sort", 'h' },    .{ "numeric-sort", 'n' },     .{ "random-sort", 'R' },
        .{ "reverse", 'r' },               .{ "version-sort", 'V' },     .{ "check", 0 },
        .{ "key", 'k' },                   .{ "merge", 'm' },            .{ "output", 'o' },
        .{ "stable", 's' },                .{ "field-separator", 't' },  .{ "unique", 'u' },
        .{ "zero-terminated", 'z' },       .{ "buffer-size", 'S' },      .{ "temporary-directory", 'T' },
        .{ "parallel", 0 },                .{ "sort", 0 },               .{ "random-source", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => {
                gopts.b_start = true;
                gopts.b_end = true;
            },
            'd' => gopts.d = true,
            'f' => gopts.f = true,
            'g' => gopts.g = true,
            'i' => gopts.i = true,
            'M' => gopts.M = true,
            'h' => gopts.h = true,
            'n' => gopts.n = true,
            'R' => gopts.R = true,
            'r' => gopts.r = true,
            'V' => gopts.V = true,
            'c' => check = true,
            'C' => check = false,
            'k' => try keys.append(c.gpa, parseKey(p.arg())),
            'm' => {},
            'o' => output = p.arg(),
            's' => stable = true,
            't' => {
                const a = p.arg();
                if (a.len == 0) c.fatalCode(2, "empty tab", .{});
                if (c.eql(a, "\\0")) {
                    tab = 0;
                } else if (a.len > 1) {
                    c.fatalCode(2, "multi-character tab {f}", .{c.q(a)});
                } else tab = a[0];
            },
            'u' => unique = true,
            'z' => delim = 0,
            'S', 'T' => _ = p.arg(),
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "check")) {
                const v = p.optArg() orelse "diagnose-first";
                check = !(c.eql(v, "quiet") or c.eql(v, "silent"));
            } else if (c.eql(name, "parallel") or c.eql(name, "random-source")) {
                _ = p.arg();
            } else if (c.eql(name, "sort")) {
                const v = p.arg();
                if (c.eql(v, "numeric")) gopts.n = true else if (c.eql(v, "general-numeric")) gopts.g = true else if (c.eql(v, "human-numeric")) gopts.h = true else if (c.eql(v, "month")) gopts.M = true else if (c.eql(v, "random")) gopts.R = true else if (c.eql(v, "version")) gopts.V = true else c.usageErr("invalid argument {f} for '--sort'", .{c.q(v)});
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (gopts.R) {
        var b: [8]u8 = undefined;
        std.crypto.random.bytes(&b);
        rand_seed = mem.readInt(u64, &b, .little);
    }
    // keys without options inherit global options
    for (keys.items) |*k| {
        if (!k.o.any()) k.o = gopts;
    }
    if (keys.items.len == 0) {
        try keys.append(c.gpa, .{ .sword = 0, .schar = 0, .eword = null, .o = gopts });
    }
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var lines: std.ArrayList([]const u8) = .empty;
    for (files.items) |f| {
        const data = blk: {
            const fd = if (c.eql(f, "-")) @as(i32, 0) else c.sys.open(f, c.O_RDONLY, 0) catch |e| {
                c.fatalCode(2, "cannot read: {s}: {s}", .{ f, c.strerror(e) });
            };
            defer c.closeInput(fd);
            break :blk c.readFdAll(fd) catch |e| c.fatalCode(2, "read failed: {s}: {s}", .{ f, c.strerror(e) });
        };
        for (c.splitLines(data, delim)) |l| try lines.append(c.gpa, l);
        if (check != null) {
            // check mode: only the first file is considered
            var i: usize = 1;
            while (i < lines.items.len) : (i += 1) {
                const r = compare(lines.items[i - 1], lines.items[i]);
                if (r > 0 or (unique and r == 0)) {
                    if (check.?) {
                        c.flush();
                        c.eprint("{s}: {s}:{d}: disorder: {s}\n", .{ c.prog, f, i + 1, lines.items[i] });
                    }
                    return 1;
                }
            }
            return 0;
        }
    }
    mem.sort([]const u8, lines.items, {}, lessThan);
    var w = c.out;
    var ofw: std.fs.File.Writer = undefined;
    var obuf: [16384]u8 = undefined;
    if (output) |o| {
        if (!c.eql(o, "-")) {
            const fd = c.sys.open(o, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666) catch |e| {
                c.fatalCode(2, "open failed: {s}: {s}", .{ o, c.strerror(e) });
            };
            ofw = (std.fs.File{ .handle = fd }).writerStreaming(&obuf);
            w = &ofw.interface;
        }
    }
    var prev: ?[]const u8 = null;
    for (lines.items) |l| {
        if (unique) {
            if (prev) |pv| if (compare(pv, l) == 0) continue;
            prev = l;
        }
        try w.writeAll(l);
        try w.writeByte(delim);
    }
    try w.flush();
    return 0;
}

test "sort compare helpers" {
    try std.testing.expect(numCompare("10", "9") > 0);
    try std.testing.expect(numCompare("-10", "9") < 0);
    try std.testing.expect(numCompare("-10", "-9") < 0);
    try std.testing.expect(numCompare("1.5", "1.25") > 0);
    try std.testing.expect(numCompare("abc", "0") == 0);
    try std.testing.expect(humanCompare("2K", "1M") < 0);
    try std.testing.expect(humanCompare("10K", "9K") > 0);
    try std.testing.expect(versionCompare("file-1.10", "file-1.9") > 0);
    try std.testing.expect(versionCompare("a2", "a10") < 0);
    try std.testing.expect(generalCompare("1e3", "999") > 0);
}
