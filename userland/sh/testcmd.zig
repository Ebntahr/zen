//! `test` and `[` builtins (POSIX algorithm plus common extensions).
const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const Error = shell.Error;

const Fail = error{Usage};

const T = struct {
    sh: *Shell,
    args: []const []const u8,
    i: usize = 0,
    name: []const u8,

    fn fail(t: *T, comptime fmt: []const u8, a: anytype) Fail {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, a) catch "error";
        t.sh.errMsg("{s}: {s}", .{ t.name, msg });
        return error.Usage;
    }

    fn more(t: *T) bool {
        return t.i < t.args.len;
    }

    fn orExpr(t: *T) Fail!bool {
        var v = try t.andExpr();
        while (t.more() and std.mem.eql(u8, t.args[t.i], "-o")) {
            t.i += 1;
            const r = try t.andExpr();
            v = v or r;
        }
        return v;
    }

    fn andExpr(t: *T) Fail!bool {
        var v = try t.notExpr();
        while (t.more() and std.mem.eql(u8, t.args[t.i], "-a")) {
            t.i += 1;
            const r = try t.notExpr();
            v = v and r;
        }
        return v;
    }

    fn notExpr(t: *T) Fail!bool {
        if (t.more() and std.mem.eql(u8, t.args[t.i], "!") and t.i + 1 < t.args.len) {
            t.i += 1;
            return !(try t.notExpr());
        }
        return t.primary();
    }

    fn primary(t: *T) Fail!bool {
        if (!t.more()) return t.fail("argument expected", .{});
        const a = t.args[t.i];
        if (std.mem.eql(u8, a, "(") and t.i + 1 < t.args.len) {
            // could also be a binary expression "( = x" – check that first
            if (!(t.i + 2 < t.args.len and isBinary(t.args[t.i + 1]))) {
                t.i += 1;
                const v = try t.orExpr();
                if (!t.more() or !std.mem.eql(u8, t.args[t.i], ")")) return t.fail("')' expected", .{});
                t.i += 1;
                return v;
            }
        }
        if (t.i + 2 < t.args.len and isBinary(t.args[t.i + 1])) {
            const l = t.args[t.i];
            const op = t.args[t.i + 1];
            const r = t.args[t.i + 2];
            t.i += 3;
            return t.binary(l, op, r);
        }
        if (isUnary(a) and t.i + 1 < t.args.len) {
            const x = t.args[t.i + 1];
            t.i += 2;
            return t.unary(a, x);
        }
        t.i += 1;
        return a.len > 0;
    }

    fn int(t: *T, s: []const u8) Fail!i64 {
        const x = std.mem.trim(u8, s, " \t\n");
        return std.fmt.parseInt(i64, x, 10) catch t.fail("{s}: integer expression expected", .{s});
    }

    fn binary(t: *T, l: []const u8, op: []const u8, r: []const u8) Fail!bool {
        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, l, r);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, l, r);
        if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, l, r) == .lt;
        if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, l, r) == .gt;
        if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot")) {
            const a = sys.stat(l) catch null;
            const b = sys.stat(r) catch null;
            const nt = std.mem.eql(u8, op, "-nt");
            if (a == null and b == null) return false;
            if (a == null) return !nt;
            if (b == null) return nt;
            const ma = a.?.mtim;
            const mb = b.?.mtim;
            const gt = ma.sec > mb.sec or (ma.sec == mb.sec and ma.nsec > mb.nsec);
            const lt = ma.sec < mb.sec or (ma.sec == mb.sec and ma.nsec < mb.nsec);
            return if (nt) gt else lt;
        }
        if (std.mem.eql(u8, op, "-ef")) {
            const a = sys.stat(l) catch return false;
            const b = sys.stat(r) catch return false;
            return a.dev == b.dev and a.ino == b.ino;
        }
        const x = try t.int(l);
        const y = try t.int(r);
        if (std.mem.eql(u8, op, "-eq")) return x == y;
        if (std.mem.eql(u8, op, "-ne")) return x != y;
        if (std.mem.eql(u8, op, "-lt")) return x < y;
        if (std.mem.eql(u8, op, "-le")) return x <= y;
        if (std.mem.eql(u8, op, "-gt")) return x > y;
        if (std.mem.eql(u8, op, "-ge")) return x >= y;
        return t.fail("{s}: binary operator expected", .{op});
    }

    fn unary(t: *T, op: []const u8, x: []const u8) Fail!bool {
        const c = op[1];
        switch (c) {
            'n' => return x.len > 0,
            'z' => return x.len == 0,
            't' => {
                const fd = t.int(x) catch return false;
                return sys.isatty(@intCast(@max(0, @min(fd, 1 << 20))));
            },
            'h', 'L' => {
                const st = sys.lstat(x) catch return false;
                return sys.modeType(st) == sys.S.IFLNK;
            },
            'r' => return sys.access(x, sys.R_OK),
            'w' => return sys.access(x, sys.W_OK),
            'x' => return sys.access(x, sys.X_OK),
            else => {},
        }
        const st = sys.stat(x) catch return false;
        const ty = sys.modeType(st);
        return switch (c) {
            'e', 'a' => true,
            'f' => ty == sys.S.IFREG,
            'd' => ty == sys.S.IFDIR,
            'b' => ty == sys.S.IFBLK,
            'c' => ty == sys.S.IFCHR,
            'p' => ty == sys.S.IFIFO,
            'S' => ty == sys.S.IFSOCK,
            's' => st.size > 0,
            'u' => st.mode & 0o4000 != 0,
            'g' => st.mode & 0o2000 != 0,
            'k' => st.mode & 0o1000 != 0,
            'O' => st.uid == sys.geteuid(),
            'G' => st.gid == sys.getgid(),
            'N' => st.mtim.sec > st.atim.sec or (st.mtim.sec == st.atim.sec and st.mtim.nsec > st.atim.nsec),
            else => false,
        };
    }
};

fn isUnary(s: []const u8) bool {
    if (s.len != 2 or s[0] != '-') return false;
    return std.mem.indexOfScalar(u8, "abcdefghknprstuwxzLOGSN", s[1]) != null;
}

fn isBinary(s: []const u8) bool {
    const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef", "-a", "-o" };
    for (ops) |o| if (std.mem.eql(u8, o, s)) return true;
    return false;
}

fn evalArgs(t: *T) Fail!bool {
    const a = t.args;
    switch (a.len) {
        0 => return false,
        1 => return a[0].len > 0,
        2 => {
            if (std.mem.eql(u8, a[0], "!")) return a[1].len == 0;
            if (isUnary(a[0])) return t.unary(a[0], a[1]);
            return t.fail("{s}: unary operator expected", .{a[0]});
        },
        3 => {
            if (isBinary(a[1])) {
                if (std.mem.eql(u8, a[1], "-a")) return a[0].len > 0 and a[2].len > 0;
                if (std.mem.eql(u8, a[1], "-o")) return a[0].len > 0 or a[2].len > 0;
                return t.binary(a[0], a[1], a[2]);
            }
            if (std.mem.eql(u8, a[0], "!")) {
                var sub = T{ .sh = t.sh, .args = a[1..], .name = t.name };
                return !(try evalArgs(&sub));
            }
            if (std.mem.eql(u8, a[0], "(") and std.mem.eql(u8, a[2], ")")) return a[1].len > 0;
        },
        4 => {
            if (std.mem.eql(u8, a[0], "!")) {
                var sub = T{ .sh = t.sh, .args = a[1..], .name = t.name };
                return !(try evalArgs(&sub));
            }
            if (std.mem.eql(u8, a[0], "(") and std.mem.eql(u8, a[3], ")")) {
                var sub = T{ .sh = t.sh, .args = a[1..3], .name = t.name };
                return evalArgs(&sub);
            }
        },
        else => {},
    }
    const v = try t.orExpr();
    if (t.more()) return t.fail("{s}: too many arguments", .{t.args[t.i]});
    return v;
}

pub fn run(sh: *Shell, name: []const u8, args: []const [:0]const u8) Error!u8 {
    const a = sh.scratchAlloc();
    const list = try a.alloc([]const u8, args.len);
    for (args, 0..) |x, i| list[i] = x;
    var t = T{ .sh = sh, .args = list, .name = name };
    const r = evalArgs(&t) catch return 2;
    return if (r) 0 else 1;
}

pub fn b_test(sh: *Shell, argv: []const [:0]const u8) Error!u8 {
    return run(sh, "test", argv[1..]);
}

pub fn b_bracket(sh: *Shell, argv: []const [:0]const u8) Error!u8 {
    if (argv.len < 2 or !std.mem.eql(u8, argv[argv.len - 1], "]")) {
        sh.errMsg("[: missing `]'", .{});
        return 2;
    }
    return run(sh, "[", argv[1 .. argv.len - 1]);
}
