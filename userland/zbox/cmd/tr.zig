const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: tr [OPTION]... STRING1 [STRING2]
    \\Translate, squeeze, and/or delete characters from standard input,
    \\writing to standard output.  STRING1 and STRING2 specify arrays of
    \\characters ARRAY1 and ARRAY2 that control the action.
    \\
    \\  -c, -C, --complement    use the complement of ARRAY1
    \\  -d, --delete            delete characters in ARRAY1, do not translate
    \\  -s, --squeeze-repeats   replace each sequence of a repeated character
    \\                            that is listed in the last specified ARRAY,
    \\                            with a single occurrence of that character
    \\  -t, --truncate-set1     first truncate ARRAY1 to length of ARRAY2
    \\
    \\ARRAYs are specified as strings of characters.  Interpreted sequences are:
    \\  \NNN            character with octal value NNN (1 to 3 octal digits)
    \\  \\ \a \b \f \n \r \t \v   escapes
    \\  CHAR1-CHAR2     all characters from CHAR1 to CHAR2 in ascending order
    \\  [CHAR*]         in ARRAY2, copies of CHAR until length of ARRAY1
    \\  [CHAR*REPEAT]   REPEAT copies of CHAR, REPEAT octal if starting with 0
    \\  [:alnum:] [:alpha:] [:blank:] [:cntrl:] [:digit:] [:graph:] [:lower:]
    \\  [:print:] [:punct:] [:space:] [:upper:] [:xdigit:]
    \\  [=CHAR=]        all characters which are equivalent to CHAR
    \\
;

const Elem = struct { chars: []const u8, fill: bool = false };

/// Decode one (possibly escaped) character at s[i]; returns char and new index.
fn decodeChar(s: []const u8, i: usize) struct { u8, usize } {
    if (s[i] != '\\') return .{ s[i], i + 1 };
    if (i + 1 >= s.len) {
        c.warn("warning: an unescaped backslash at end of string is not portable", .{});
        return .{ '\\', i + 1 };
    }
    const ch = s[i + 1];
    switch (ch) {
        '0'...'7' => {
            var v: u32 = 0;
            var k = i + 1;
            while (k < s.len and k < i + 4 and s[k] >= '0' and s[k] <= '7') : (k += 1) v = v * 8 + (s[k] - '0');
            return .{ @truncate(v), k };
        },
        'a' => return .{ 7, i + 2 },
        'b' => return .{ 8, i + 2 },
        'f' => return .{ 12, i + 2 },
        'n' => return .{ '\n', i + 2 },
        'r' => return .{ '\r', i + 2 },
        't' => return .{ '\t', i + 2 },
        'v' => return .{ 11, i + 2 },
        else => return .{ ch, i + 2 },
    }
}

/// Expand a SET string. fill_index receives position of a [c*] element.
fn expand(s: []const u8, is_set2: bool, fill_at: *?usize, fill_char: *u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[' and i + 1 < s.len) {
            // [:class:]
            if (s[i + 1] == ':') {
                if (mem.indexOfPos(u8, s, i + 2, ":]")) |e| {
                    const name = s[i + 2 .. e];
                    var valid = false;
                    var k: u16 = 0;
                    const names = [_][]const u8{ "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "xdigit" };
                    for (names) |n| if (c.eql(n, name)) {
                        valid = true;
                    };
                    if (!valid) c.fatal("invalid character class {f}", .{c.q(name)});
                    while (k < 256) : (k += 1) {
                        if (c.classMatch(name, @intCast(k))) out.append(c.gpa, @intCast(k)) catch c.oom();
                    }
                    i = e + 2;
                    continue;
                }
            }
            if (s[i + 1] == '=') {
                if (mem.indexOfPos(u8, s, i + 2, "=]")) |e| {
                    if (e > i + 2) {
                        const d = decodeChar(s, i + 2);
                        out.append(c.gpa, d[0]) catch c.oom();
                        i = e + 2;
                        continue;
                    }
                }
            }
            // [c*n] / [c*]
            if (i + 2 < s.len) {
                const d = decodeChar(s, i + 1);
                if (d[1] < s.len and s[d[1]] == '*') {
                    if (mem.indexOfScalarPos(u8, s, d[1], ']')) |e| {
                        const num = s[d[1] + 1 .. e];
                        var ok = true;
                        for (num) |ch| if (!std.ascii.isDigit(ch)) {
                            ok = false;
                        };
                        if (ok) {
                            if (!is_set2) c.fatal("the [c*] repeat construct may not appear in string1", .{});
                            if (num.len == 0 or (c.parseUint(num) orelse 0) == 0) {
                                if (fill_at.* != null) c.fatal("only one [c*] repeat construct may appear in string2", .{});
                                fill_at.* = out.items.len;
                                fill_char.* = d[0];
                            } else {
                                const n = if (num[0] == '0') std.fmt.parseInt(u64, num, 8) catch c.fatal("invalid repeat count {f} in [c*n] construct", .{c.q(num)}) else c.parseUint(num).?;
                                out.appendNTimes(c.gpa, d[0], @intCast(n)) catch c.oom();
                            }
                            i = e + 1;
                            continue;
                        }
                    }
                }
            }
        }
        const d = decodeChar(s, i);
        // range?
        if (d[1] + 1 < s.len and s[d[1]] == '-') {
            const hi = decodeChar(s, d[1] + 1);
            if (hi[0] < d[0]) c.fatal("range-endpoints of '{c}-{c}' are in reverse collating sequence order", .{ d[0], hi[0] });
            var k: u16 = d[0];
            while (k <= hi[0]) : (k += 1) out.append(c.gpa, @intCast(k)) catch c.oom();
            i = hi[1];
            continue;
        }
        out.append(c.gpa, d[0]) catch c.oom();
        i = d[1];
    }
    return out.items;
}

pub fn main(args: c.Args) !u8 {
    var complement = false;
    var delete = false;
    var squeeze = false;
    var truncate = false;
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "complement", 'c' }, .{ "delete", 'd' }, .{ "squeeze-repeats", 's' }, .{ "truncate-set1", 't' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c', 'C' => complement = true,
            'd' => delete = true,
            's' => squeeze = true,
            't' => truncate = true,
            else => p.bad(o),
        },
        .pos => |a| try ops.append(c.gpa, a),
        else => p.bad(o),
    };
    const translating = !delete and ops.items.len >= 2;
    if (ops.items.len == 0) c.usageErr("missing operand", .{});
    if (!delete and !squeeze and ops.items.len < 2) {
        c.warn("missing operand after {f}", .{c.q(ops.items[0])});
        c.eprint("Two strings must be given when translating.\n", .{});
        c.tryHelp();
        c.exit(1);
    }
    if (delete and !squeeze and ops.items.len > 1) {
        c.warn("extra operand {f}", .{c.q(ops.items[1])});
        c.eprint("Only one string may be given when deleting without squeezing repeats.\n", .{});
        c.tryHelp();
        c.exit(1);
    }
    if (ops.items.len > 2) c.usageErr("extra operand {f}", .{c.q(ops.items[2])});
    var fill1: ?usize = null;
    var fc1: u8 = 0;
    var s1 = expand(ops.items[0], false, &fill1, &fc1);
    var in1 = [_]bool{false} ** 256;
    for (s1) |ch| in1[ch] = true;
    if (complement) {
        var comp: std.ArrayList(u8) = .empty;
        var k: u16 = 0;
        while (k < 256) : (k += 1) if (!in1[k]) try comp.append(c.gpa, @intCast(k));
        s1 = comp.items;
        in1 = [_]bool{false} ** 256;
        for (s1) |ch| in1[ch] = true;
    }
    var s2: []u8 = &.{};
    if (ops.items.len >= 2) {
        var fill2: ?usize = null;
        var fc2: u8 = 0;
        s2 = expand(ops.items[1], true, &fill2, &fc2);
        if (fill2) |at| {
            const need = if (s1.len > s2.len) s1.len - s2.len else 0;
            var l: std.ArrayList(u8) = .empty;
            try l.appendSlice(c.gpa, s2[0..at]);
            try l.appendNTimes(c.gpa, fc2, need);
            try l.appendSlice(c.gpa, s2[at..]);
            s2 = l.items;
        }
    }
    var map: [256]u8 = undefined;
    for (&map, 0..) |*m, k| m.* = @intCast(k);
    if (translating) {
        if (s2.len == 0 and !truncate) c.fatal("when not truncating set1, string2 must be non-empty", .{});
        var n1 = s1.len;
        if (truncate and n1 > s2.len) n1 = s2.len;
        for (s1[0..n1], 0..) |ch, k| map[ch] = s2[@min(k, s2.len - 1)];
    }
    var sq = [_]bool{false} ** 256;
    if (squeeze) {
        const set = if (translating or delete) s2 else s1;
        for (set) |ch| sq[ch] = true;
    }
    var buf: [65536]u8 = undefined;
    var obuf: [65536]u8 = undefined;
    var last: i32 = -1;
    while (true) {
        const n = try c.sys.read(0, &buf);
        if (n == 0) break;
        var on: usize = 0;
        for (buf[0..n]) |ch| {
            if (delete and in1[ch]) continue;
            const t = map[ch];
            if (squeeze and sq[t] and last == t) continue;
            obuf[on] = t;
            on += 1;
            last = t;
        }
        try c.out.writeAll(obuf[0..on]);
    }
    return 0;
}
