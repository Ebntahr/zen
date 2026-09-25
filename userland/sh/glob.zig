//! Pattern matching (fnmatch) and pathname expansion (globbing).
//!
//! Patterns use `*`, `?`, `[...]` (with `!`/`^` negation, ranges and
//! `[:class:]`), and backslash to quote the next character. A pattern
//! component of exactly `**` matches any number of directories.
const std = @import("std");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn classMatch(name: []const u8, cp: u21) ?bool {
    const c: u8 = if (cp < 128) @intCast(cp) else 0;
    const ascii = cp < 128;
    if (std.mem.eql(u8, name, "alpha")) return ascii and std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "digit")) return ascii and std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "alnum")) return ascii and std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "upper")) return ascii and std.ascii.isUpper(c);
    if (std.mem.eql(u8, name, "lower")) return ascii and std.ascii.isLower(c);
    if (std.mem.eql(u8, name, "space")) return ascii and std.ascii.isWhitespace(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "punct")) return ascii and (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ');
    if (std.mem.eql(u8, name, "print")) return ascii and std.ascii.isPrint(c);
    if (std.mem.eql(u8, name, "graph")) return ascii and std.ascii.isPrint(c) and c != ' ';
    if (std.mem.eql(u8, name, "cntrl")) return ascii and std.ascii.isControl(c);
    if (std.mem.eql(u8, name, "xdigit")) return ascii and std.ascii.isHex(c);
    return null;
}

/// Match a bracket expression starting at pat[p] == '['. Returns null when
/// the bracket is not terminated (then '[' is an ordinary character).
fn bracket(pat: []const u8, p: usize, cp: u21) ?struct { matched: bool, end: usize } {
    var i = p + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var first = true;
    var matched = false;
    while (i < pat.len) {
        const c = pat[i];
        if (c == ']' and !first) return .{ .matched = matched != negate, .end = i + 1 };
        first = false;
        if (c == '[' and i + 1 < pat.len and pat[i + 1] == ':') {
            if (std.mem.indexOfPos(u8, pat, i + 2, ":]")) |e| {
                if (classMatch(pat[i + 2 .. e], cp)) |m| {
                    if (m) matched = true;
                    i = e + 2;
                    continue;
                }
            }
        }
        if (c == '[' and i + 1 < pat.len and (pat[i + 1] == '=' or pat[i + 1] == '.')) {
            const term = [2]u8{ pat[i + 1], ']' };
            if (std.mem.indexOfPos(u8, pat, i + 2, &term)) |e| {
                const inner = pat[i + 2 .. e];
                if (inner.len > 0) {
                    const d = decode(inner, 0);
                    if (d.cp == cp) matched = true;
                }
                i = e + 2;
                continue;
            }
        }
        var lo_i = i;
        if (c == '\\' and i + 1 < pat.len) lo_i = i + 1;
        const lo = decode(pat, lo_i);
        i = lo_i + lo.len;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            var hi_i = i + 1;
            if (pat[hi_i] == '\\' and hi_i + 1 < pat.len) hi_i += 1;
            const hi = decode(pat, hi_i);
            i = hi_i + hi.len;
            if (lo.cp <= cp and cp <= hi.cp) matched = true;
        } else if (lo.cp == cp) matched = true;
    }
    return null;
}

pub const Flags = struct {
    /// A leading '.' in the string must be matched by a literal '.'.
    period: bool = false,
};

pub fn fnmatch(pat: []const u8, str: []const u8, flags: Flags) bool {
    if (flags.period and str.len > 0 and str[0] == '.') {
        const lit_dot = (pat.len > 0 and pat[0] == '.') or (pat.len > 1 and pat[0] == '\\' and pat[1] == '.');
        if (!lit_dot) return false;
    }
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (p < pat.len) {
            const c = pat[p];
            switch (c) {
                '*' => {
                    while (p < pat.len and pat[p] == '*') p += 1;
                    if (p == pat.len) return true;
                    star_p = p;
                    star_s = s;
                    continue;
                },
                '?' => if (s < str.len) {
                    s += decode(str, s).len;
                    p += 1;
                    continue;
                },
                '[' => if (s < str.len) {
                    const d = decode(str, s);
                    if (bracket(pat, p, d.cp)) |r| {
                        if (r.matched) {
                            s += d.len;
                            p = r.end;
                            continue;
                        }
                    } else if (str[s] == '[') {
                        s += 1;
                        p += 1;
                        continue;
                    }
                },
                '\\' => if (p + 1 < pat.len) {
                    if (s < str.len and str[s] == pat[p + 1]) {
                        s += 1;
                        p += 2;
                        continue;
                    }
                } else if (s < str.len and str[s] == '\\') {
                    s += 1;
                    p += 1;
                    continue;
                },
                else => if (s < str.len and str[s] == c) {
                    s += 1;
                    p += 1;
                    continue;
                },
            }
        } else if (s == str.len) return true;
        // mismatch: backtrack to the last star
        if (star_p) |sp| {
            if (star_s >= str.len) return false;
            star_s += decode(str, star_s).len;
            s = star_s;
            p = sp;
            continue;
        }
        return false;
    }
}

/// True if the pattern contains unescaped glob metacharacters.
pub fn hasMeta(pat: []const u8) bool {
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => i += 1,
            '*', '?' => return true,
            '[' => if (std.mem.indexOfScalarPos(u8, pat, i + 1, ']') != null) return true,
            else => {},
        }
    }
    return false;
}

pub fn unescape(a: Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\' and i + 1 < pat.len) i += 1;
        try out.append(a, pat[i]);
    }
    return out.toOwnedSlice(a);
}

fn join(a: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return a.dupe(u8, name);
    if (dir[dir.len - 1] == '/') return std.mem.concat(a, u8, &.{ dir, name });
    return std.mem.concat(a, u8, &.{ dir, "/", name });
}

fn isDirEntry(a: Allocator, dir: []const u8, e: sys.DirEntry) bool {
    switch (e.kind) {
        .dir => return true,
        .link, .unknown => {
            const full = join(a, dir, e.name) catch return false;
            return sys.isDir(full);
        },
        else => return false,
    }
}

fn listDir(a: Allocator, dir: []const u8, pat: []const u8, need_dir: bool, out: *std.ArrayList([]u8)) !void {
    var it = sys.DirIter.open(dir) catch return;
    defer it.close();
    while (it.next()) |e| {
        if (!fnmatch(pat, e.name, .{ .period = true })) continue;
        if (need_dir and !isDirEntry(a, dir, e)) continue;
        try out.append(a, try join(a, dir, e.name));
    }
}

fn walkAll(a: Allocator, dir: []const u8, out: *std.ArrayList([]u8), depth: u32) !void {
    if (depth > 32) return;
    var it = sys.DirIter.open(dir) catch return;
    defer it.close();
    var subdirs: std.ArrayList([]u8) = .empty;
    while (it.next()) |e| {
        if (e.name.len > 0 and e.name[0] == '.') continue;
        if (e.kind != .dir and !(e.kind == .unknown and isDirEntry(a, dir, e))) continue;
        try subdirs.append(a, try join(a, dir, e.name));
    }
    for (subdirs.items) |full| {
        try out.append(a, full);
        try walkAll(a, full, out, depth + 1);
    }
}

fn lessThan(_: void, x: []u8, y: []u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Expand a glob pattern into a sorted list of paths. Returns an empty list
/// if nothing matches.
pub fn glob(a: Allocator, pattern: []const u8) ![][]u8 {
    var cur: std.ArrayList([]u8) = .empty;
    var rest = pattern;
    if (rest.len > 0 and rest[0] == '/') {
        var i: usize = 0;
        while (i < rest.len and rest[i] == '/') i += 1;
        try cur.append(a, try a.dupe(u8, rest[0..i]));
        rest = rest[i..];
    } else {
        try cur.append(a, try a.dupe(u8, ""));
    }
    const trailing_slash = rest.len > 0 and rest[rest.len - 1] == '/';
    var comps: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |c| try comps.append(a, c);

    for (comps.items, 0..) |comp, ci| {
        const last = ci + 1 == comps.items.len;
        var next: std.ArrayList([]u8) = .empty;
        if (std.mem.eql(u8, comp, "**")) {
            for (cur.items) |dir| {
                if (!last) try next.append(a, dir);
                var sub: std.ArrayList([]u8) = .empty;
                try walkAll(a, dir, &sub, 0);
                if (last) {
                    // '**' as the last component matches files too
                    try listDir(a, dir, "*", false, &next);
                    for (sub.items) |sd| try listDir(a, sd, "*", false, &next);
                } else try next.appendSlice(a, sub.items);
            }
        } else if (!hasMeta(comp)) {
            const lit = try unescape(a, comp);
            for (cur.items) |dir| {
                const p = try join(a, dir, lit);
                if (last) {
                    if (!sys.exists(p)) continue;
                }
                try next.append(a, p);
            }
        } else {
            for (cur.items) |dir| try listDir(a, dir, comp, !last or trailing_slash, &next);
        }
        cur = next;
        if (cur.items.len == 0) break;
    }
    if (comps.items.len == 0) return &.{};
    if (trailing_slash) {
        for (cur.items) |*p| p.* = try std.mem.concat(a, u8, &.{ p.*, "/" });
    }
    std.mem.sortUnstable([]u8, cur.items, {}, lessThan);
    return cur.items;
}

test "fnmatch" {
    const t = std.testing;
    try t.expect(fnmatch("*.zig", "main.zig", .{}));
    try t.expect(!fnmatch("*.zig", "main.zi", .{}));
    try t.expect(fnmatch("a?c", "abc", .{}));
    try t.expect(fnmatch("[a-c]x", "bx", .{}));
    try t.expect(!fnmatch("[!a-c]x", "bx", .{}));
    try t.expect(fnmatch("[[:digit:]]*", "1abc", .{}));
    try t.expect(fnmatch("\\*", "*", .{}));
    try t.expect(!fnmatch("\\*", "a", .{}));
    try t.expect(!fnmatch("*", ".hidden", .{ .period = true }));
    try t.expect(fnmatch(".*", ".hidden", .{ .period = true }));
    try t.expect(fnmatch("*a*b*c", "xxaxxbxxc", .{}));
    try t.expect(fnmatch("", "", .{}));
    try t.expect(!fnmatch("", "a", .{}));
    try t.expect(fnmatch("[]]", "]", .{}));
}
