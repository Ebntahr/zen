const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: test EXPRESSION
    \\  or:  test
    \\  or:  [ EXPRESSION ]
    \\  or:  [ ]
    \\  or:  [ OPTION
    \\Exit with the status determined by EXPRESSION.
    \\
    \\  ( EXPRESSION )               EXPRESSION is true
    \\  ! EXPRESSION                 EXPRESSION is false
    \\  EXPRESSION1 -a EXPRESSION2   both EXPRESSION1 and EXPRESSION2 are true
    \\  EXPRESSION1 -o EXPRESSION2   either EXPRESSION1 or EXPRESSION2 is true
    \\
    \\  -n STRING            the length of STRING is nonzero
    \\  STRING               equivalent to -n STRING
    \\  -z STRING            the length of STRING is zero
    \\  STRING1 = STRING2    the strings are equal
    \\  STRING1 != STRING2   the strings are not equal
    \\  STRING1 < STRING2    STRING1 sorts before STRING2
    \\  STRING1 > STRING2    STRING1 sorts after STRING2
    \\
    \\  INTEGER1 -eq INTEGER2   INTEGER1 is equal to INTEGER2
    \\  (also -ge -gt -le -lt -ne)
    \\
    \\  FILE1 -ef FILE2   FILE1 and FILE2 have the same device and inode numbers
    \\  FILE1 -nt FILE2   FILE1 is newer (modification date) than FILE2
    \\  FILE1 -ot FILE2   FILE1 is older than FILE2
    \\
    \\  -b FILE  block special        -c FILE  character special
    \\  -d FILE  directory            -e FILE  exists
    \\  -f FILE  regular file         -g FILE  set-group-ID
    \\  -G FILE  owned by egid        -h/-L FILE  symbolic link
    \\  -k FILE  sticky bit           -N FILE  modified since last read
    \\  -O FILE  owned by euid        -p FILE  named pipe
    \\  -r FILE  readable             -s FILE  size greater than zero
    \\  -S FILE  socket               -t FD    opened on a terminal
    \\  -u FILE  set-user-ID          -w FILE  writable
    \\  -x FILE  executable
    \\
;

const TestError = error{Syntax};

var args_g: []const []const u8 = &.{};
var pos: usize = 0;

fn syntax(comptime fmt: []const u8, a: anytype) noreturn {
    c.warn(fmt, a);
    c.exit(2);
}

fn isUnary(s: []const u8) bool {
    if (s.len != 2 or s[0] != '-') return false;
    return mem.indexOfScalar(u8, "bcdefgGhLkNnOprsStuwxz", s[1]) != null;
}

fn isBinary(s: []const u8) bool {
    const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-ef", "-nt", "-ot" };
    for (ops) |o| if (c.eql(o, s)) return true;
    return false;
}

fn parseInteger(s: []const u8) i64 {
    const t = mem.trim(u8, s, " \t");
    if (c.parseInt(t)) |v| return v;
    syntax("invalid integer {f}", .{c.q(s)});
}

fn unary(op: u8, arg: []const u8) bool {
    switch (op) {
        'n' => return arg.len > 0,
        'z' => return arg.len == 0,
        't' => {
            const fd = parseInteger(arg);
            if (fd < 0 or fd > std.math.maxInt(i32)) return false;
            return c.isatty(@intCast(fd));
        },
        'h', 'L' => {
            const st = c.sys.lstat(arg) catch return false;
            return st.isLnk();
        },
        else => {},
    }
    const st = c.sys.stat(arg) catch return false;
    return switch (op) {
        'b' => st.mode & c.S_IFMT == c.S_IFBLK,
        'c' => st.mode & c.S_IFMT == c.S_IFCHR,
        'd' => st.isDir(),
        'e' => true,
        'f' => st.isReg(),
        'g' => st.mode & 0o2000 != 0,
        'G' => st.gid == c.sys.getegid(),
        'k' => st.mode & 0o1000 != 0,
        'N' => c.Ts.cmp(st.mtime, st.atime) == .gt,
        'O' => st.uid == c.sys.geteuid(),
        'p' => st.mode & c.S_IFMT == c.S_IFIFO,
        's' => st.size > 0,
        'S' => st.mode & c.S_IFMT == c.S_IFSOCK,
        'u' => st.mode & 0o4000 != 0,
        'r' => blk: {
            c.sys.access(arg, 4) catch break :blk false;
            break :blk true;
        },
        'w' => blk: {
            c.sys.access(arg, 2) catch break :blk false;
            break :blk true;
        },
        'x' => blk: {
            c.sys.access(arg, 1) catch break :blk false;
            break :blk true;
        },
        else => false,
    };
}

fn binary(a: []const u8, op: []const u8, b: []const u8) bool {
    if (c.eql(op, "=") or c.eql(op, "==")) return c.eql(a, b);
    if (c.eql(op, "!=")) return !c.eql(a, b);
    if (c.eql(op, "<")) return mem.order(u8, a, b) == .lt;
    if (c.eql(op, ">")) return mem.order(u8, a, b) == .gt;
    if (c.eql(op, "-ef")) {
        const sa = c.sys.stat(a) catch return false;
        const sb = c.sys.stat(b) catch return false;
        return sa.dev == sb.dev and sa.ino == sb.ino;
    }
    if (c.eql(op, "-nt") or c.eql(op, "-ot")) {
        const sa: ?c.Stat = c.sys.stat(a) catch null;
        const sb: ?c.Stat = c.sys.stat(b) catch null;
        if (c.eql(op, "-nt")) {
            if (sa == null) return false;
            if (sb == null) return true;
            return c.Ts.cmp(sa.?.mtime, sb.?.mtime) == .gt;
        }
        if (sb == null) return false;
        if (sa == null) return true;
        return c.Ts.cmp(sa.?.mtime, sb.?.mtime) == .lt;
    }
    const x = parseInteger(a);
    const y = parseInteger(b);
    if (c.eql(op, "-eq")) return x == y;
    if (c.eql(op, "-ne")) return x != y;
    if (c.eql(op, "-lt")) return x < y;
    if (c.eql(op, "-le")) return x <= y;
    if (c.eql(op, "-gt")) return x > y;
    if (c.eql(op, "-ge")) return x >= y;
    unreachable;
}

fn peek(k: usize) ?[]const u8 {
    return if (pos + k < args_g.len) args_g[pos + k] else null;
}

fn parseOr() bool {
    var v = parseAnd();
    while (peek(0)) |a| {
        if (!c.eql(a, "-o")) break;
        pos += 1;
        const r = parseAnd();
        v = v or r;
    }
    return v;
}

fn parseAnd() bool {
    var v = parseNot();
    while (peek(0)) |a| {
        if (!c.eql(a, "-a")) break;
        pos += 1;
        const r = parseNot();
        v = v and r;
    }
    return v;
}

fn parseNot() bool {
    if (peek(0)) |a| {
        if (c.eql(a, "!")) {
            pos += 1;
            return !parseNot();
        }
    }
    return parsePrimary();
}

fn parsePrimary() bool {
    const a = peek(0) orelse syntax("missing argument after {f}", .{c.q(if (pos > 0) args_g[pos - 1] else "")});
    // binary operator takes precedence when followed by one
    if (peek(1)) |op| {
        if (isBinary(op) and peek(2) != null) {
            pos += 3;
            return binary(a, op, args_g[pos - 1]);
        }
    }
    if (c.eql(a, "(")) {
        pos += 1;
        const v = parseOr();
        const cl = peek(0) orelse syntax("')' expected", .{});
        if (!c.eql(cl, ")")) syntax("')' expected, found {f}", .{c.q(cl)});
        pos += 1;
        return v;
    }
    if (isUnary(a)) {
        const arg = peek(1) orelse {
            // lone "-f" etc: treated as a string
            pos += 1;
            return true;
        };
        pos += 2;
        return unary(a[1], arg);
    }
    pos += 1;
    return a.len > 0;
}

fn evalN(a: []const []const u8) bool {
    switch (a.len) {
        0 => return false,
        1 => return a[0].len > 0,
        2 => {
            if (c.eql(a[0], "!")) return a[1].len == 0;
            if (a[0].len == 2 and a[0][0] == '-') {
                if (isUnary(a[0])) return unary(a[0][1], a[1]);
                syntax("{f}: unary operator expected", .{c.q(a[0])});
            }
            syntax("missing argument after {f}", .{c.q(a[1])});
        },
        3 => {
            if (isBinary(a[1])) return binary(a[0], a[1], a[2]);
            if (c.eql(a[0], "!")) return !evalN(a[1..]);
            if (c.eql(a[0], "(") and c.eql(a[2], ")")) return a[1].len > 0;
            if (c.eql(a[1], "-a")) return a[0].len > 0 and a[2].len > 0;
            if (c.eql(a[1], "-o")) return a[0].len > 0 or a[2].len > 0;
            syntax("{f}: binary operator expected", .{c.q(a[1])});
        },
        4 => {
            if (c.eql(a[0], "!")) return !evalN(a[1..]);
            if (c.eql(a[0], "(") and c.eql(a[3], ")")) return evalN(a[1..3]);
        },
        else => {},
    }
    args_g = a;
    pos = 0;
    const v = parseOr();
    if (pos < a.len) syntax("extra argument {f}", .{c.q(a[pos])});
    return v;
}

fn run(a: []const []const u8) u8 {
    return if (evalN(a)) 0 else 1;
}

pub fn main(args: c.Args) !u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |x| try list.append(c.gpa, x);
    return run(list.items);
}

pub fn mainBracket(args: c.Args) !u8 {
    if (args.len == 2) {
        if (c.eql(args[1], "--help")) c.printHelp();
        if (c.eql(args[1], "--version")) c.printVersion();
    }
    if (args.len < 2 or !c.eql(args[args.len - 1], "]")) {
        c.warn("missing ']'", .{});
        return 2;
    }
    var list: std.ArrayList([]const u8) = .empty;
    for (args[1 .. args.len - 1]) |x| try list.append(c.gpa, x);
    return run(list.items);
}
