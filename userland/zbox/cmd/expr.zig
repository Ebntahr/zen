const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const mem = std.mem;

pub const help =
    \\Usage: expr EXPRESSION
    \\  or:  expr OPTION
    \\Print the value of EXPRESSION to standard output.  A blank line below
    \\separates increasing precedence groups.  EXPRESSION may be:
    \\
    \\  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2
    \\
    \\  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0
    \\
    \\  ARG1 < ARG2       ARG1 is less than ARG2
    \\  ARG1 <= ARG2      ARG1 is less than or equal to ARG2
    \\  ARG1 = ARG2       ARG1 is equal to ARG2
    \\  ARG1 != ARG2      ARG1 is unequal to ARG2
    \\  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2
    \\  ARG1 > ARG2       ARG1 is greater than ARG2
    \\
    \\  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2
    \\  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2
    \\
    \\  ARG1 * ARG2       arithmetic product of ARG1 and ARG2
    \\  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2
    \\  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2
    \\
    \\  STRING : REGEXP   anchored pattern match of REGEXP in STRING
    \\
    \\  match STRING REGEXP        same as STRING : REGEXP
    \\  substr STRING POS LENGTH   substring of STRING, POS counted from 1
    \\  index STRING CHARS         index in STRING where any CHARS is found, or 0
    \\  length STRING              length of STRING
    \\  + TOKEN                    interpret TOKEN as a string, even if it is a
    \\                               keyword like 'match' or an operator like '/'
    \\
    \\  ( EXPRESSION )             value of EXPRESSION
    \\
    \\Exit status is 0 if EXPRESSION is neither null nor 0, 1 if EXPRESSION is null
    \\or 0, 2 if EXPRESSION is syntactically invalid, and 3 if an error occurred.
    \\
;

const Val = union(enum) {
    int: i128,
    str: []const u8,
};

var toks: []const []const u8 = &.{};
var pos: usize = 0;

fn syntaxErr(comptime fmt: []const u8, a: anytype) noreturn {
    c.warn(fmt, a);
    c.exit(2);
}

fn toInt(v: Val) ?i128 {
    return switch (v) {
        .int => |i| i,
        .str => |s| blk: {
            if (s.len == 0) break :blk null;
            var t = s;
            var neg = false;
            if (t[0] == '-') {
                neg = true;
                t = t[1..];
            }
            if (t.len == 0) break :blk null;
            for (t) |ch| if (!std.ascii.isDigit(ch)) break :blk null;
            const x = std.fmt.parseInt(i128, t, 10) catch break :blk null;
            break :blk if (neg) -x else x;
        },
    };
}

fn needInt(v: Val) i128 {
    return toInt(v) orelse c.fatalCode(2, "non-integer argument", .{});
}

fn isNull(v: Val) bool {
    return switch (v) {
        .int => |i| i == 0,
        .str => |s| s.len == 0 or (toInt(v) != null and toInt(v).? == 0),
    };
}

fn toStr(v: Val) []const u8 {
    return switch (v) {
        .str => |s| s,
        .int => |i| std.fmt.allocPrint(c.gpa, "{d}", .{i}) catch c.oom(),
    };
}

fn peek() ?[]const u8 {
    return if (pos < toks.len) toks[pos] else null;
}

fn isOp(s: []const u8) bool {
    const ops = [_][]const u8{ "|", "&", "<", "<=", "=", "==", "!=", ">=", ">", "+", "-", "*", "/", "%", ":", ")" };
    for (ops) |o| if (c.eql(o, s)) return true;
    return false;
}

fn parseOr() Val {
    var l = parseAnd();
    while (peek()) |t| {
        if (!c.eql(t, "|")) break;
        pos += 1;
        const r = parseAnd();
        if (isNull(l)) {
            l = if (isNull(r)) .{ .int = 0 } else r;
        }
    }
    return l;
}

fn parseAnd() Val {
    var l = parseCmp();
    while (peek()) |t| {
        if (!c.eql(t, "&")) break;
        pos += 1;
        const r = parseCmp();
        if (isNull(l) or isNull(r)) l = .{ .int = 0 };
    }
    return l;
}

fn parseCmp() Val {
    var l = parseAdd();
    while (peek()) |t| {
        const ops = [_][]const u8{ "<", "<=", "=", "==", "!=", ">=", ">" };
        var op: ?[]const u8 = null;
        for (ops) |o| if (c.eql(o, t)) {
            op = o;
        };
        const o = op orelse break;
        pos += 1;
        const r = parseAdd();
        var ord: std.math.Order = undefined;
        const li = toInt(l);
        const ri = toInt(r);
        if (li != null and ri != null) {
            ord = std.math.order(li.?, ri.?);
        } else ord = mem.order(u8, toStr(l), toStr(r));
        const res = if (c.eql(o, "<")) ord == .lt else if (c.eql(o, "<=")) ord != .gt else if (c.eql(o, "=") or c.eql(o, "==")) ord == .eq else if (c.eql(o, "!=")) ord != .eq else if (c.eql(o, ">=")) ord != .lt else ord == .gt;
        l = .{ .int = @intFromBool(res) };
    }
    return l;
}

fn parseAdd() Val {
    var l = parseMul();
    while (peek()) |t| {
        if (!(c.eql(t, "+") or c.eql(t, "-"))) break;
        pos += 1;
        const r = parseMul();
        const a = needInt(l);
        const b = needInt(r);
        const res = if (t[0] == '+') @addWithOverflow(a, b) else @subWithOverflow(a, b);
        if (res[1] != 0) c.fatalCode(2, "result out of range", .{});
        l = .{ .int = res[0] };
    }
    return l;
}

fn parseMul() Val {
    var l = parseMatch();
    while (peek()) |t| {
        if (!(c.eql(t, "*") or c.eql(t, "/") or c.eql(t, "%"))) break;
        pos += 1;
        const r = parseMatch();
        const a = needInt(l);
        const b = needInt(r);
        if (t[0] != '*' and b == 0) c.fatalCode(2, "division by zero", .{});
        l = .{ .int = switch (t[0]) {
            '*' => blk: {
                const m = @mulWithOverflow(a, b);
                if (m[1] != 0) c.fatalCode(2, "result out of range", .{});
                break :blk m[0];
            },
            '/' => @divTrunc(a, b),
            else => @rem(a, b),
        } };
    }
    return l;
}

fn doMatch(s: []const u8, pat: []const u8) Val {
    var re = rx.Regex.compile(c.gpa, pat, .{}) catch c.fatalCode(2, "{s}", .{rx.err_msg});
    var g: [10]rx.Span = undefined;
    // anchored at start: try only position 0
    const ok = re.exec(s, 0, &g, .{}) and g[0].start == 0;
    if (re.ngroups > 0) {
        if (!ok or g[1].start < 0) return .{ .str = "" };
        return .{ .str = s[@intCast(g[1].start)..@intCast(g[1].end)] };
    }
    if (!ok) return .{ .int = 0 };
    // count characters (UTF-8 code points)
    return .{ .int = @intCast(c.displayWidth(s[0..@intCast(g[0].end)])) };
}

fn parseMatch() Val {
    var l = parsePrimary();
    while (peek()) |t| {
        if (!c.eql(t, ":")) break;
        pos += 1;
        const r = parsePrimary();
        l = doMatch(toStr(l), toStr(r));
    }
    return l;
}

fn nextArg(after: []const u8) []const u8 {
    const t = peek() orelse syntaxErr("syntax error: missing argument after {f}", .{c.q(after)});
    pos += 1;
    return t;
}

fn parsePrimary() Val {
    const t = peek() orelse syntaxErr("syntax error: missing argument after {f}", .{c.q(if (pos > 0) toks[pos - 1] else "")});
    pos += 1;
    if (c.eql(t, "(")) {
        const v = parseOr();
        const cl = peek() orelse syntaxErr("syntax error: expecting ')' after {f}", .{c.q(toks[pos - 1])});
        if (!c.eql(cl, ")")) syntaxErr("syntax error: expecting ')' instead of {f}", .{c.q(cl)});
        pos += 1;
        return v;
    }
    if (c.eql(t, "+")) return .{ .str = nextArg(t) };
    if (c.eql(t, "length")) {
        const s = toStr(parsePrimaryArg(t));
        return .{ .int = @intCast(c.displayWidth(s)) };
    }
    if (c.eql(t, "match")) {
        const s = toStr(parsePrimaryArg(t));
        const p = toStr(parsePrimaryArg(t));
        return doMatch(s, p);
    }
    if (c.eql(t, "substr")) {
        const s = toStr(parsePrimaryArg(t));
        const p = toInt(parsePrimaryArg(t));
        const l = toInt(parsePrimaryArg(t));
        if (p == null or l == null) return .{ .str = "" };
        if (p.? < 1 or l.? < 1 or p.? > s.len) return .{ .str = "" };
        const start: usize = @intCast(p.? - 1);
        const end: usize = @intCast(@min(@as(i128, @intCast(s.len)), p.? - 1 + l.?));
        return .{ .str = s[start..end] };
    }
    if (c.eql(t, "index")) {
        const s = toStr(parsePrimaryArg(t));
        const chars = toStr(parsePrimaryArg(t));
        for (s, 0..) |ch, i| if (mem.indexOfScalar(u8, chars, ch) != null) return .{ .int = @intCast(i + 1) };
        return .{ .int = 0 };
    }
    if (isOp(t) and !(c.eql(t, "-") and false)) {
        if (pos - 1 == 0 and toks.len == 1) return .{ .str = t };
        syntaxErr("syntax error: unexpected argument {f}", .{c.q(t)});
    }
    return .{ .str = t };
}

fn parsePrimaryArg(after: []const u8) Val {
    if (peek() == null) syntaxErr("syntax error: missing argument after {f}", .{c.q(after)});
    return parsePrimary();
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 1;
    if (args.len == 2) {
        if (c.eql(args[1], "--help")) c.printHelp();
        if (c.eql(args[1], "--version")) c.printVersion();
    }
    if (args.len > 1 and c.eql(args[1], "--")) start = 2;
    for (args[start..]) |a| try list.append(c.gpa, a);
    if (list.items.len == 0) c.usageErr("missing operand", .{});
    toks = list.items;
    pos = 0;
    const v = parseOr();
    if (pos < toks.len) syntaxErr("syntax error: unexpected argument {f}", .{c.q(toks[pos])});
    try c.out.print("{s}\n", .{toStr(v)});
    return if (isNull(v)) 1 else 0;
}
