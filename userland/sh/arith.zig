//! Shell arithmetic: `$(( ))`, `(( ))`, `let`. 64-bit signed integers with
//! the full set of C operators including assignment operators, `++`/`--`,
//! `**`, the ternary operator and the comma operator.
const std = @import("std");
const shell = @import("shell.zig");
const Shell = shell.Shell;

pub const Error = shell.Error;

const Fail = error{ Syntax, DivZero, BadNumber, NegExp, Recursion, OutOfMemory, Abort };

const P = struct {
    sh: *Shell,
    s: []const u8,
    i: usize = 0,
    skip: u32 = 0,
    depth: u32,
    msg: []const u8 = "",

    fn ws(p: *P) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn peekOp(p: *P, op: []const u8) bool {
        p.ws();
        return std.mem.startsWith(u8, p.s[p.i..], op);
    }

    fn eat(p: *P, op: []const u8) bool {
        if (p.peekOp(op)) {
            p.i += op.len;
            return true;
        }
        return false;
    }

    /// eat `op` only if it is not followed by any char in `not`.
    fn eatNot(p: *P, op: []const u8, not: []const u8) bool {
        if (!p.peekOp(op)) return false;
        const n = p.i + op.len;
        if (n < p.s.len and std.mem.indexOfScalar(u8, not, p.s[n]) != null) return false;
        p.i = n;
        return true;
    }

    fn getVar(p: *P, name: []const u8) Fail!i64 {
        const v = p.sh.getVar(name) orelse {
            if (p.sh.opts.nounset and p.skip == 0) {
                p.msg = name;
                return error.Abort;
            }
            return 0;
        };
        const t = std.mem.trim(u8, v, " \t\n");
        if (t.len == 0) return 0;
        if (parseNumber(t)) |n| return n else |_| {}
        if (p.depth > 64) return error.Recursion;
        // evaluate the value as an expression (bash semantics)
        var sub = P{ .sh = p.sh, .s = t, .depth = p.depth + 1, .skip = p.skip };
        const r = try sub.full();
        return r;
    }

    fn setVar(p: *P, name: []const u8, v: i64) Fail!void {
        if (p.skip > 0) return;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
        p.sh.setVar(name, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Abort,
        };
    }

    fn full(p: *P) Fail!i64 {
        const v = try p.comma();
        p.ws();
        if (p.i < p.s.len) return error.Syntax;
        return v;
    }

    fn comma(p: *P) Fail!i64 {
        var v = try p.assign();
        while (p.eat(",")) v = try p.assign();
        return v;
    }

    fn assign(p: *P) Fail!i64 {
        p.ws();
        const save = p.i;
        if (p.i < p.s.len and (std.ascii.isAlphabetic(p.s[p.i]) or p.s[p.i] == '_')) {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
            const name = p.s[start..p.i];
            p.ws();
            const ops = [_][]const u8{ "<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=", "=" };
            for (ops) |op| {
                if (std.mem.startsWith(u8, p.s[p.i..], op)) {
                    if (op.len == 1 and p.i + 1 < p.s.len and p.s[p.i + 1] == '=') break; // '=='
                    p.i += op.len;
                    const rhs = try p.assign();
                    var v = rhs;
                    if (op.len > 1) {
                        const cur = try p.getVar(name);
                        v = try binop(p, op[0 .. op.len - 1], cur, rhs);
                    }
                    try p.setVar(name, v);
                    return v;
                }
            }
        }
        p.i = save;
        return p.ternary();
    }

    fn ternary(p: *P) Fail!i64 {
        const c = try p.logor();
        if (!p.eat("?")) return c;
        if (c == 0) p.skip += 1;
        const a = try p.assign();
        if (c == 0) p.skip -= 1;
        if (!p.eat(":")) return error.Syntax;
        if (c != 0) p.skip += 1;
        const b = try p.assign();
        if (c != 0) p.skip -= 1;
        return if (c != 0) a else b;
    }

    fn logor(p: *P) Fail!i64 {
        var v = try p.logand();
        while (p.eat("||")) {
            if (v != 0) p.skip += 1;
            const r = try p.logand();
            if (v != 0) p.skip -= 1;
            v = @intFromBool(v != 0 or r != 0);
        }
        return v;
    }

    fn logand(p: *P) Fail!i64 {
        var v = try p.bitor();
        while (p.eat("&&")) {
            if (v == 0) p.skip += 1;
            const r = try p.bitor();
            if (v == 0) p.skip -= 1;
            v = @intFromBool(v != 0 and r != 0);
        }
        return v;
    }

    fn bitor(p: *P) Fail!i64 {
        var v = try p.bitxor();
        while (p.eatNot("|", "|=")) v |= try p.bitxor();
        return v;
    }

    fn bitxor(p: *P) Fail!i64 {
        var v = try p.bitand();
        while (p.eatNot("^", "=")) v ^= try p.bitand();
        return v;
    }

    fn bitand(p: *P) Fail!i64 {
        var v = try p.equality();
        while (p.eatNot("&", "&=")) v &= try p.equality();
        return v;
    }

    fn equality(p: *P) Fail!i64 {
        var v = try p.relational();
        while (true) {
            if (p.eat("==")) {
                v = @intFromBool(v == try p.relational());
            } else if (p.eat("!=")) {
                v = @intFromBool(v != try p.relational());
            } else return v;
        }
    }

    fn relational(p: *P) Fail!i64 {
        var v = try p.shift();
        while (true) {
            if (p.eat("<=")) {
                v = @intFromBool(v <= try p.shift());
            } else if (p.eat(">=")) {
                v = @intFromBool(v >= try p.shift());
            } else if (p.eatNot("<", "<")) {
                v = @intFromBool(v < try p.shift());
            } else if (p.eatNot(">", ">")) {
                v = @intFromBool(v > try p.shift());
            } else return v;
        }
    }

    fn shift(p: *P) Fail!i64 {
        var v = try p.additive();
        while (true) {
            if (p.eatNot("<<", "=")) {
                v = try binop(p, "<<", v, try p.additive());
            } else if (p.eatNot(">>", "=")) {
                v = try binop(p, ">>", v, try p.additive());
            } else return v;
        }
    }

    fn additive(p: *P) Fail!i64 {
        var v = try p.mult();
        while (true) {
            if (p.eatNot("+", "+=")) {
                v = v +% try p.mult();
            } else if (p.eatNot("-", "-=")) {
                v = v -% try p.mult();
            } else return v;
        }
    }

    fn mult(p: *P) Fail!i64 {
        var v = try p.power();
        while (true) {
            if (p.eatNot("*", "*=")) {
                v = v *% try p.power();
            } else if (p.eatNot("/", "=")) {
                v = try binop(p, "/", v, try p.power());
            } else if (p.eatNot("%", "=")) {
                v = try binop(p, "%", v, try p.power());
            } else return v;
        }
    }

    fn power(p: *P) Fail!i64 {
        const b = try p.unary();
        if (p.eatNot("**", "=")) {
            const e = try p.power();
            return binop(p, "**", b, e);
        }
        return b;
    }

    fn unary(p: *P) Fail!i64 {
        p.ws();
        if (p.eat("++") or p.eat("--")) {
            const inc: i64 = if (p.s[p.i - 1] == '+') 1 else -1;
            p.ws();
            const name = p.ident() orelse return error.Syntax;
            const v = (try p.getVar(name)) +% inc;
            try p.setVar(name, v);
            return v;
        }
        if (p.eatNot("-", "=")) return 0 -% try p.unary();
        if (p.eatNot("+", "=")) return p.unary();
        if (p.eatNot("!", "=")) return @intFromBool((try p.unary()) == 0);
        if (p.eat("~")) return ~(try p.unary());
        return p.postfix();
    }

    fn ident(p: *P) ?[]const u8 {
        if (p.i < p.s.len and (std.ascii.isAlphabetic(p.s[p.i]) or p.s[p.i] == '_')) {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_')) p.i += 1;
            return p.s[start..p.i];
        }
        return null;
    }

    fn postfix(p: *P) Fail!i64 {
        p.ws();
        if (p.i >= p.s.len) return error.Syntax;
        const c = p.s[p.i];
        if (c == '(') {
            p.i += 1;
            const v = try p.comma();
            if (!p.eat(")")) return error.Syntax;
            return v;
        }
        if (std.ascii.isDigit(c)) {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '#' or p.s[p.i] == '_' or p.s[p.i] == '@')) p.i += 1;
            return parseNumber(p.s[start..p.i]) catch error.BadNumber;
        }
        if (p.ident()) |name| {
            if (p.peekOp("++") or p.peekOp("--")) {
                const inc: i64 = if (p.s[p.i] == '+') 1 else -1;
                p.i += 2;
                const v = try p.getVar(name);
                try p.setVar(name, v +% inc);
                return v;
            }
            return p.getVar(name);
        }
        return error.Syntax;
    }
};

fn binop(p: *P, op: []const u8, a: i64, b: i64) Fail!i64 {
    switch (op[0]) {
        '+' => return a +% b,
        '-' => return a -% b,
        '*' => {
            if (op.len == 2) {
                if (b < 0) {
                    if (p.skip > 0) return 0;
                    return error.NegExp;
                }
                var r: i64 = 1;
                var e = b;
                var base = a;
                while (e > 0) : (e >>= 1) {
                    if (e & 1 == 1) r *%= base;
                    base *%= base;
                }
                return r;
            }
            return a *% b;
        },
        '/', '%' => {
            if (b == 0) {
                if (p.skip > 0) return 0;
                return error.DivZero;
            }
            if (a == std.math.minInt(i64) and b == -1) return if (op[0] == '/') a else 0;
            return if (op[0] == '/') @divTrunc(a, b) else @rem(a, b);
        },
        '<' => return a << @intCast(@as(u64, @bitCast(b)) & 63),
        '>' => return a >> @intCast(@as(u64, @bitCast(b)) & 63),
        '&' => return a & b,
        '^' => return a ^ b,
        '|' => return a | b,
        else => return error.Syntax,
    }
}

/// Parse an integer constant: decimal, 0x hex, 0 octal, base#digits.
pub fn parseNumber(s: []const u8) !i64 {
    if (s.len == 0) return error.BadNumber;
    var neg = false;
    var t = s;
    if (t[0] == '-' or t[0] == '+') {
        neg = t[0] == '-';
        t = t[1..];
        if (t.len == 0) return error.BadNumber;
    }
    var base: u8 = 10;
    if (std.mem.indexOfScalar(u8, t, '#')) |h| {
        base = std.fmt.parseInt(u8, t[0..h], 10) catch return error.BadNumber;
        if (base < 2 or base > 64) return error.BadNumber;
        t = t[h + 1 ..];
    } else if (t.len > 1 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        base = 16;
        t = t[2..];
    } else if (t.len > 1 and t[0] == '0') {
        base = 8;
        t = t[1..];
    }
    if (t.len == 0) return error.BadNumber;
    var v: i64 = 0;
    for (t) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => if (base <= 36) c - 'a' + 10 else c - 'a' + 10,
            'A'...'Z' => if (base <= 36) c - 'A' + 10 else c - 'A' + 36,
            '@' => 62,
            '_' => 63,
            else => return error.BadNumber,
        };
        if (d >= base) return error.BadNumber;
        v = v *% base +% d;
    }
    return if (neg) -%v else v;
}

/// Evaluate an arithmetic expression. Errors are reported on stderr and
/// turned into `error.Abort` with status 1 (the command is aborted).
pub fn eval(sh: *Shell, expr: []const u8) Error!i64 {
    const t = std.mem.trim(u8, expr, " \t\n");
    if (t.len == 0) return 0;
    var p = P{ .sh = sh, .s = t, .depth = 0 };
    return p.full() catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DivZero => sh.errMsg("{s}: division by 0", .{t}),
            error.NegExp => sh.errMsg("{s}: exponent less than 0", .{t}),
            error.BadNumber => sh.errMsg("{s}: value too great for base", .{t}),
            error.Recursion => sh.errMsg("{s}: expression recursion level exceeded", .{t}),
            error.Abort => if (p.msg.len > 0) sh.errMsg("{s}: unbound variable", .{p.msg}),
            error.Syntax => {
                const rest = if (p.i < t.len) t[p.i..] else "";
                sh.errMsg("{s}: syntax error in expression (error token is \"{s}\")", .{ t, rest });
            },
        }
        sh.last_status = if (e == error.Abort and p.msg.len == 0) sh.last_status else 1;
        return error.Abort;
    };
}
