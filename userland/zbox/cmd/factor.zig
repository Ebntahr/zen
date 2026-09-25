const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: factor [OPTION] [NUMBER]...
    \\Print the prime factors of each specified integer NUMBER.  If none
    \\are specified on the command line, read them from standard input.
    \\
    \\  -h, --exponents   print repeated factors in form p^e unless e is 1
    \\
;

fn mulmod(a: u64, b: u64, m: u64) u64 {
    return @intCast((@as(u128, a) * b) % m);
}

fn powmod(b_in: u64, e_in: u64, m: u64) u64 {
    var r: u64 = 1;
    var b = b_in % m;
    var e = e_in;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = mulmod(r, b, m);
        b = mulmod(b, b, m);
    }
    return r;
}

fn isPrime(n: u64) bool {
    if (n < 2) return false;
    const small = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (small) |p| {
        if (n % p == 0) return n == p;
    }
    var d = n - 1;
    var s: u32 = 0;
    while (d % 2 == 0) : (d /= 2) s += 1;
    outer: for (small) |a| {
        var x = powmod(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var r: u32 = 1;
        while (r < s) : (r += 1) {
            x = mulmod(x, x, n);
            if (x == n - 1) continue :outer;
        }
        return false;
    }
    return true;
}

fn rho(n: u64) u64 {
    if (n % 2 == 0) return 2;
    var cc: u64 = 1;
    while (true) : (cc += 1) {
        var x: u64 = 2;
        var y: u64 = 2;
        var d: u64 = 1;
        while (d == 1) {
            x = (mulmod(x, x, n) + cc) % n;
            y = (mulmod(y, y, n) + cc) % n;
            y = (mulmod(y, y, n) + cc) % n;
            d = std.math.gcd(if (x > y) x - y else y - x, n);
        }
        if (d != n) return d;
    }
}

fn factorize(n: u64, out: *std.ArrayList(u64)) void {
    if (n == 1) return;
    if (isPrime(n)) {
        out.append(c.gpa, n) catch c.oom();
        return;
    }
    // trial division for small factors first
    var m = n;
    const primes = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47 };
    for (primes) |p| {
        while (m % p == 0) {
            out.append(c.gpa, p) catch c.oom();
            m /= p;
        }
    }
    if (m == 1) return;
    if (isPrime(m)) {
        out.append(c.gpa, m) catch c.oom();
        return;
    }
    const d = rho(m);
    factorize(d, out);
    factorize(m / d, out);
}

var exponents = false;

fn doOne(s: []const u8) !bool {
    const t = mem.trim(u8, s, " \t\n");
    const n = std.fmt.parseInt(u64, if (t.len > 0 and t[0] == '+') t[1..] else t, 10) catch {
        c.warn("{f} is not a valid positive integer", .{c.q(s)});
        return false;
    };
    var fs: std.ArrayList(u64) = .empty;
    defer fs.deinit(c.gpa);
    factorize(n, &fs);
    std.sort.insertion(u64, fs.items, {}, std.sort.asc(u64));
    try c.out.print("{d}:", .{n});
    var i: usize = 0;
    while (i < fs.items.len) {
        var j = i;
        while (j < fs.items.len and fs.items[j] == fs.items[i]) j += 1;
        if (exponents and j - i > 1) {
            try c.out.print(" {d}^{d}", .{ fs.items[i], j - i });
        } else {
            var k = i;
            while (k < j) : (k += 1) try c.out.print(" {d}", .{fs.items[k]});
        }
        i = j;
    }
    try c.out.writeByte('\n');
    return true;
}

pub fn main(args: c.Args) !u8 {
    var nums: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "exponents", 'h' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'h' => exponents = true,
            else => p.bad(o),
        },
        .pos => |a| try nums.append(c.gpa, a),
        else => p.bad(o),
    };
    var status: u8 = 0;
    if (nums.items.len == 0) {
        var r = c.LineReader.init(0);
        while (r.nextw()) |line| {
            var it = mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |tok| if (!try doOne(tok)) {
                status = 1;
            };
        }
        return status;
    }
    for (nums.items) |n| if (!try doOne(n)) {
        status = 1;
    };
    return status;
}
