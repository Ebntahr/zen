//! POSIX regular expressions (BRE and ERE with GNU extensions) for zbox.
//!
//! Patterns are parsed into an AST and compiled to a small instruction set
//! executed by a backtracking matcher. Without back-references a visited
//! bitset over (instruction, position) bounds the work to O(m*n) per search
//! (like RE2's BitState), while still finding the POSIX leftmost-longest
//! match. With back-references plain backtracking is used (with a step cap).
//!
//! Supported: literals, `.`, bracket expressions with ranges, negation and
//! [:classes:], [=x=], [.x.]; anchors ^ $; * + ? {m,n}; groups; alternation;
//! back-references \1..\9; GNU escapes \w \W \s \S \b \B \< \> \` \'.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Error = error{ OutOfMemory, BadPattern };

/// Human readable message of the last compile error (GNU wording).
pub var err_msg: []const u8 = "";

pub const Flags = struct {
    extended: bool = false,
    icase: bool = false,
    /// Accept \n, \t, \\ and \] escapes inside bracket expressions (GNU sed).
    bracket_escapes: bool = false,
    /// Wrap as whole line match (grep -x).
    whole_line: bool = false,
    /// Wrap as word match (grep -w).
    whole_word: bool = false,
    /// '.' and [^...] do not match newline.
    newline_stop: bool = false,
};

const Set = [4]u64;
fn setHas(s: *const Set, ch: u8) bool {
    return (s[ch >> 6] >> @intCast(ch & 63)) & 1 != 0;
}
fn setAdd(s: *Set, ch: u8) void {
    s[ch >> 6] |= @as(u64, 1) << @intCast(ch & 63);
}
fn setUnion(a: *Set, b: *const Set) void {
    for (0..4) |i| a[i] |= b[i];
}
const full_set: Set = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) };

pub fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

const Assert = enum { bol, eol, wordb, nwordb, wbeg, wend, bufbeg, bufend, wleft, wright };

const INF: u32 = std.math.maxInt(u32);

const Node = union(enum) {
    empty,
    lit: u8,
    any,
    set: u32,
    assert: Assert,
    backref: u16,
    group: struct { child: u32, idx: u16 },
    cat: struct { a: u32, b: u32 },
    alt: struct { a: u32, b: u32 },
    rep: struct { child: u32, min: u32, max: u32 },
};

const Inst = union(enum) {
    char: u8,
    any,
    any_nonl,
    set: u32,
    split: [2]u32,
    jmp: u32,
    save: u32,
    assert: Assert,
    backref: u32,
    mark: u32,
    check: u32,
    match,
};

pub const Span = struct { start: isize = -1, end: isize = -1 };

pub const ExecOpts = struct {
    /// Find the longest match at the leftmost position (needed for -o, s///).
    longest: bool = true,
    /// '^' does not match at position 0.
    notbol: bool = false,
};

const Frame = union(enum) {
    state: struct { pc: u32, pos: u32 },
    restore: struct { slot: u32, val: isize },
};

pub const Regex = struct {
    alloc: Allocator,
    insts: []Inst,
    sets: []Set,
    ngroups: usize,
    nslots: usize,
    has_backref: bool,
    icase: bool,
    first: ?Set,
    anchored: bool,
    visited: std.ArrayList(u64) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    slots: []isize,
    best: []isize,

    pub fn compile(alloc: Allocator, pattern: []const u8, flags: Flags) Error!Regex {
        return compileMulti(alloc, &.{pattern}, flags);
    }

    /// Compile several patterns as alternatives (grep -e p1 -e p2).
    pub fn compileMulti(alloc: Allocator, patterns: []const []const u8, flags: Flags) Error!Regex {
        var nodes: std.ArrayList(Node) = .empty;
        defer nodes.deinit(alloc);
        var sets: std.ArrayList(Set) = .empty;
        errdefer sets.deinit(alloc);
        var p: Parser = .{ .alloc = alloc, .pat = "", .flags = flags, .nodes = &nodes, .sets = &sets };
        var root: ?u32 = null;
        for (patterns) |pat| {
            p.pat = pat;
            p.pos = 0;
            p.group_base = p.ngroups;
            p.closed = 0;
            const r = try p.parseAlt(0);
            if (p.pos < pat.len) {
                // stray closing paren in BRE: \)
                return p.fail("Unmatched ) or \\)");
            }
            root = if (root) |x| try p.node(.{ .alt = .{ .a = x, .b = r } }) else r;
        }
        var top = root orelse try p.node(.empty);
        if (flags.whole_line) {
            const b = try p.node(.{ .assert = .bufbeg });
            const e = try p.node(.{ .assert = .bufend });
            top = try p.node(.{ .cat = .{ .a = b, .b = try p.node(.{ .cat = .{ .a = top, .b = e } }) } });
        } else if (flags.whole_word) {
            const b = try p.node(.{ .assert = .wleft });
            const e = try p.node(.{ .assert = .wright });
            top = try p.node(.{ .cat = .{ .a = b, .b = try p.node(.{ .cat = .{ .a = top, .b = e } }) } });
        }
        var comp: Compiler = .{ .alloc = alloc, .nodes = nodes.items, .flags = flags, .loop_base = 2 * (@as(u32, p.ngroups) + 1) };
        errdefer comp.insts.deinit(alloc);
        try comp.emit(.{ .save = 0 });
        try comp.gen(top);
        try comp.emit(.{ .save = 1 });
        try comp.emit(.match);
        const fs = firstSet(nodes.items, sets.items, top, flags.icase);
        const nslots = 2 * (@as(usize, p.ngroups) + 1) + comp.nloops;
        const slots = try alloc.alloc(isize, nslots);
        const best = try alloc.alloc(isize, nslots);
        return .{
            .alloc = alloc,
            .insts = try comp.insts.toOwnedSlice(alloc),
            .sets = try sets.toOwnedSlice(alloc),
            .ngroups = p.ngroups,
            .nslots = nslots,
            .has_backref = p.has_backref,
            .icase = flags.icase,
            .first = if (fs.nullable) null else fs.set,
            .anchored = startsAnchored(nodes.items, top),
            .slots = slots,
            .best = best,
        };
    }

    pub fn deinit(re: *Regex) void {
        re.alloc.free(re.insts);
        re.alloc.free(re.sets);
        re.alloc.free(re.slots);
        re.alloc.free(re.best);
        re.visited.deinit(re.alloc);
        re.stack.deinit(re.alloc);
    }

    /// Search text starting at `start`. On success fills `groups` (if given;
    /// groups[0] is the whole match) and returns true.
    pub fn exec(re: *Regex, text: []const u8, start: usize, groups: ?[]Span, opts: ExecOpts) bool {
        if (start > text.len) return false;
        const use_memo = !re.has_backref;
        if (use_memo) {
            const bits = re.insts.len * (text.len + 1);
            const words = (bits + 63) / 64;
            if (re.visited.items.len < words) {
                re.visited.resize(re.alloc, words) catch return false;
            }
            const from = (start * re.insts.len) / 64;
            @memset(re.visited.items[from..words], 0);
        }
        var s = start;
        while (s <= text.len) : (s += 1) {
            if (re.first) |*fs| {
                // skip to a plausible start byte
                while (s < text.len and !setHas(fs, text[s])) s += 1;
                if (s >= text.len) return false;
            }
            if (re.tryAt(text, s, opts, use_memo)) {
                if (groups) |g| {
                    for (g, 0..) |*sp, i| {
                        if (i <= re.ngroups) {
                            sp.* = .{ .start = re.best[2 * i], .end = re.best[2 * i + 1] };
                        } else sp.* = .{};
                    }
                }
                return true;
            }
            if (re.anchored) return false;
        }
        return false;
    }

    fn visit(re: *Regex, pc: u32, pos: usize) bool {
        const idx = pos * re.insts.len + pc;
        const w = &re.visited.items[idx >> 6];
        const bit = @as(u64, 1) << @intCast(idx & 63);
        if (w.* & bit != 0) return false;
        w.* |= bit;
        return true;
    }

    fn lower(re: *const Regex, ch: u8) u8 {
        return if (re.icase) std.ascii.toLower(ch) else ch;
    }

    fn tryAt(re: *Regex, text: []const u8, s: usize, opts: ExecOpts, memo: bool) bool {
        @memset(re.slots, -1);
        var found = false;
        var best_end: usize = 0;
        re.stack.clearRetainingCapacity();
        re.stack.append(re.alloc, .{ .state = .{ .pc = 0, .pos = @intCast(s) } }) catch return false;
        var steps: usize = 0;
        const n = text.len;
        outer: while (re.stack.pop()) |fr| {
            switch (fr) {
                .restore => |r| {
                    re.slots[r.slot] = r.val;
                    continue;
                },
                .state => {},
            }
            var pc = fr.state.pc;
            var pos: usize = fr.state.pos;
            while (true) {
                if (memo) {
                    if (!re.visit(pc, pos)) continue :outer;
                } else {
                    steps += 1;
                    if (steps > 50_000_000) break :outer;
                }
                switch (re.insts[pc]) {
                    .char => |ch| {
                        if (pos < n and re.lower(text[pos]) == ch) {
                            pc += 1;
                            pos += 1;
                        } else continue :outer;
                    },
                    .any => {
                        if (pos < n) {
                            pc += 1;
                            pos += 1;
                        } else continue :outer;
                    },
                    .any_nonl => {
                        if (pos < n and text[pos] != '\n') {
                            pc += 1;
                            pos += 1;
                        } else continue :outer;
                    },
                    .set => |si| {
                        if (pos < n and setHas(&re.sets[si], text[pos])) {
                            pc += 1;
                            pos += 1;
                        } else continue :outer;
                    },
                    .split => |t| {
                        re.stack.append(re.alloc, .{ .state = .{ .pc = t[1], .pos = @intCast(pos) } }) catch return false;
                        pc = t[0];
                    },
                    .jmp => |t| pc = t,
                    .save => |k| {
                        re.stack.append(re.alloc, .{ .restore = .{ .slot = k, .val = re.slots[k] } }) catch return false;
                        re.slots[k] = @intCast(pos);
                        pc += 1;
                    },
                    .mark => |k| {
                        if (!memo) {
                            re.stack.append(re.alloc, .{ .restore = .{ .slot = k, .val = re.slots[k] } }) catch return false;
                            re.slots[k] = @intCast(pos);
                        }
                        pc += 1;
                    },
                    .check => |k| {
                        if (!memo and re.slots[k] == @as(isize, @intCast(pos))) continue :outer;
                        pc += 1;
                    },
                    .assert => |a| {
                        if (!assertOk(a, text, pos, opts.notbol)) continue :outer;
                        pc += 1;
                    },
                    .backref => |g| {
                        const bs = re.slots[2 * g];
                        const be = re.slots[2 * g + 1];
                        if (bs < 0 or be < 0) continue :outer;
                        const sub = text[@intCast(bs)..@intCast(be)];
                        if (pos + sub.len > n) continue :outer;
                        const cand = text[pos .. pos + sub.len];
                        const eq = if (re.icase) std.ascii.eqlIgnoreCase(sub, cand) else mem.eql(u8, sub, cand);
                        if (!eq) continue :outer;
                        pos += sub.len;
                        pc += 1;
                    },
                    .match => {
                        if (!found or pos > best_end) {
                            found = true;
                            best_end = pos;
                            @memcpy(re.best, re.slots);
                            re.best[1] = @intCast(pos);
                        }
                        if (!opts.longest or pos == n) return true;
                        continue :outer;
                    },
                }
            }
        }
        return found;
    }
};

fn assertOk(a: Assert, text: []const u8, pos: usize, notbol: bool) bool {
    const n = text.len;
    const before = pos > 0 and isWordChar(text[pos - 1]);
    const after = pos < n and isWordChar(text[pos]);
    return switch (a) {
        .bol => pos == 0 and !notbol,
        .eol => pos == n,
        .bufbeg => pos == 0,
        .bufend => pos == n,
        .wordb => before != after,
        .nwordb => before == after,
        .wbeg => !before and after,
        .wend => before and !after,
        .wleft => !before,
        .wright => !after,
    };
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Parser = struct {
    alloc: Allocator,
    pat: []const u8,
    pos: usize = 0,
    flags: Flags,
    nodes: *std.ArrayList(Node),
    sets: *std.ArrayList(Set),
    ngroups: u16 = 0,
    group_base: u16 = 0,
    closed: u32 = 0,
    has_backref: bool = false,

    fn fail(p: *Parser, msg: []const u8) Error {
        _ = p;
        err_msg = msg;
        return error.BadPattern;
    }

    fn node(p: *Parser, n: Node) Error!u32 {
        try p.nodes.append(p.alloc, n);
        return @intCast(p.nodes.items.len - 1);
    }

    fn cat(p: *Parser, a: ?u32, b: u32) Error!u32 {
        if (a) |x| return p.node(.{ .cat = .{ .a = x, .b = b } });
        return b;
    }

    fn peek(p: *Parser, k: usize) ?u8 {
        if (p.pos + k < p.pat.len) return p.pat[p.pos + k];
        return null;
    }

    fn ere(p: *Parser) bool {
        return p.flags.extended;
    }

    fn atAltBar(p: *Parser) bool {
        if (p.ere()) return p.peek(0) == '|';
        return p.peek(0) == '\\' and p.peek(1) == '|';
    }
    fn atClose(p: *Parser, depth: u32) bool {
        if (p.ere()) return depth > 0 and p.peek(0) == ')';
        return p.peek(0) == '\\' and p.peek(1) == ')';
    }

    fn parseAlt(p: *Parser, depth: u32) Error!u32 {
        var left = try p.parseCat(depth);
        while (p.atAltBar()) {
            p.pos += if (p.ere()) 1 else 2;
            const right = try p.parseCat(depth);
            left = try p.node(.{ .alt = .{ .a = left, .b = right } });
        }
        return left;
    }

    fn parseCat(p: *Parser, depth: u32) Error!u32 {
        var result: ?u32 = null;
        var at_start = true;
        while (p.pos < p.pat.len) {
            if (p.atAltBar() or p.atClose(depth)) break;
            const atom = (try p.parseAtom(depth, at_start)) orelse continue;
            const was_anchor = p.nodes.items[atom] == .assert and p.nodes.items[atom].assert == .bol;
            const r = try p.parsePostfix(atom);
            result = try p.cat(result, r);
            // In BRE, '*' right after a leading '^' is literal.
            at_start = was_anchor and !p.ere();
        }
        return result orelse try p.node(.empty);
    }

    fn parseInterval(p: *Parser) Error!?struct { u32, u32 } {
        // p.pos points after '{' (ERE) or '\{' (BRE)
        const save = p.pos;
        var min: ?u32 = null;
        var max: ?u32 = null;
        var have_comma = false;
        while (p.peek(0)) |ch| {
            if (!std.ascii.isDigit(ch)) break;
            min = (min orelse 0) *| 10 +| (ch - '0');
            p.pos += 1;
        }
        if (p.peek(0) == ',') {
            have_comma = true;
            p.pos += 1;
            while (p.peek(0)) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                max = (max orelse 0) *| 10 +| (ch - '0');
                p.pos += 1;
            }
        }
        const closed = if (p.ere()) p.peek(0) == '}' else (p.peek(0) == '\\' and p.peek(1) == '}');
        if (!closed or (min == null and !have_comma) or (min == null and max == null and p.ere())) {
            if (p.ere()) {
                p.pos = save;
                return null;
            }
            if (!closed) return p.fail("Unmatched \\{");
            return p.fail("Invalid content of \\{\\}");
        }
        p.pos += if (p.ere()) 1 else 2;
        const lo = min orelse 0;
        const hi = if (have_comma) (max orelse INF) else lo;
        if (hi != INF and hi < lo) return p.fail("Invalid content of \\{\\}");
        if (lo > 32767 or (hi != INF and hi > 32767)) return p.fail("Regular expression too big");
        return .{ lo, hi };
    }

    fn parsePostfix(p: *Parser, atom_in: u32) Error!u32 {
        var atom = atom_in;
        while (p.pos < p.pat.len) {
            const ch = p.pat[p.pos];
            var min: u32 = 0;
            var max: u32 = 0;
            if (ch == '*') {
                p.pos += 1;
                min = 0;
                max = INF;
            } else if (p.ere() and ch == '+') {
                p.pos += 1;
                min = 1;
                max = INF;
            } else if (p.ere() and ch == '?') {
                p.pos += 1;
                min = 0;
                max = 1;
            } else if (p.ere() and ch == '{') {
                p.pos += 1;
                const iv = (try p.parseInterval()) orelse {
                    p.pos -= 1;
                    break;
                };
                min = iv[0];
                max = iv[1];
            } else if (!p.ere() and ch == '\\' and p.peek(1) != null) {
                const nx = p.peek(1).?;
                if (nx == '+') {
                    p.pos += 2;
                    min = 1;
                    max = INF;
                } else if (nx == '?') {
                    p.pos += 2;
                    min = 0;
                    max = 1;
                } else if (nx == '{') {
                    p.pos += 2;
                    const iv = (try p.parseInterval()).?;
                    min = iv[0];
                    max = iv[1];
                } else break;
            } else break;
            atom = try p.node(.{ .rep = .{ .child = atom, .min = min, .max = max } });
        }
        return atom;
    }

    fn parseAtom(p: *Parser, depth: u32, at_start: bool) Error!?u32 {
        const ch = p.pat[p.pos];
        if (p.ere()) {
            switch (ch) {
                '(' => {
                    p.pos += 1;
                    return try p.parseGroup(depth);
                },
                ')' => {
                    // unmatched ')' at top level is literal in GNU ERE
                    p.pos += 1;
                    return try p.node(.{ .lit = ')' });
                },
                '*', '+', '?' => {
                    if (at_start) {
                        // quantifier with nothing to repeat: ignored (GNU)
                        p.pos += 1;
                        return null;
                    }
                },
                '{' => {
                    if (at_start) {
                        p.pos += 1;
                        if (try p.parseInterval()) |_| return null;
                        return try p.node(.{ .lit = '{' });
                    }
                },
                '^' => {
                    p.pos += 1;
                    return try p.node(.{ .assert = .bol });
                },
                '$' => {
                    p.pos += 1;
                    return try p.node(.{ .assert = .eol });
                },
                else => {},
            }
        } else {
            switch (ch) {
                '*' => if (at_start) {
                    p.pos += 1;
                    return try p.litNode('*');
                },
                '^' => {
                    p.pos += 1;
                    if (at_start and p.isBreStart()) return try p.node(.{ .assert = .bol });
                    return try p.litNode('^');
                },
                '$' => {
                    p.pos += 1;
                    if (p.pos == p.pat.len or (p.peek(0) == '\\' and (p.peek(1) == ')' or p.peek(1) == '|')))
                        return try p.node(.{ .assert = .eol });
                    return try p.litNode('$');
                },
                '\\' => {
                    if (p.peek(1) == '(') {
                        p.pos += 2;
                        return try p.parseGroup(depth);
                    }
                    if (p.peek(1) == '{' and at_start) {
                        p.pos += 2;
                        return try p.litNode('{');
                    }
                },
                else => {},
            }
        }
        switch (ch) {
            '.' => {
                p.pos += 1;
                return try p.node(.any);
            },
            '[' => {
                p.pos += 1;
                return try p.parseBracket();
            },
            '\\' => {
                p.pos += 1;
                return try p.parseEscape();
            },
            else => {
                p.pos += 1;
                return try p.litNode(ch);
            },
        }
    }

    /// In BRE, '^' is an anchor only at the start of the pattern or right
    /// after \( or \| (GNU).
    fn isBreStart(p: *Parser) bool {
        const i = p.pos - 1;
        if (i == 0) return true;
        if (i >= 2 and p.pat[i - 2] == '\\' and (p.pat[i - 1] == '(' or p.pat[i - 1] == '|')) return true;
        return false;
    }

    fn litNode(p: *Parser, ch: u8) Error!u32 {
        if (p.flags.icase and std.ascii.isAlphabetic(ch)) {
            return p.node(.{ .lit = std.ascii.toLower(ch) });
        }
        return p.node(.{ .lit = ch });
    }

    fn parseGroup(p: *Parser, depth: u32) Error!u32 {
        p.ngroups += 1;
        const idx = p.ngroups;
        var inner: u32 = undefined;
        if (p.ere() and p.peek(0) == ')') {
            inner = try p.node(.empty);
        } else inner = try p.parseAlt(depth + 1);
        if (p.ere()) {
            if (p.peek(0) != ')') return p.fail("Unmatched ( or \\(");
            p.pos += 1;
        } else {
            if (!(p.peek(0) == '\\' and p.peek(1) == ')')) return p.fail("Unmatched ( or \\(");
            p.pos += 2;
        }
        const local = idx - p.group_base;
        if (local < 32) p.closed |= @as(u32, 1) << @intCast(local);
        return p.node(.{ .group = .{ .child = inner, .idx = idx } });
    }

    fn addSet(p: *Parser, s: Set) Error!u32 {
        try p.sets.append(p.alloc, s);
        return @intCast(p.sets.items.len - 1);
    }

    fn classSet(name: []const u8) ?Set {
        var s: Set = .{ 0, 0, 0, 0 };
        var any = false;
        var ch: u16 = 0;
        const valid = [_][]const u8{ "alpha", "digit", "alnum", "upper", "lower", "space", "blank", "punct", "print", "graph", "cntrl", "xdigit" };
        for (valid) |v| if (mem.eql(u8, v, name)) {
            any = true;
        };
        if (!any) return null;
        while (ch < 256) : (ch += 1) {
            const b: u8 = @intCast(ch);
            if (@import("common.zig").classMatch(name, b)) setAdd(&s, b);
        }
        return s;
    }

    fn parseEscape(p: *Parser) Error!u32 {
        if (p.pos >= p.pat.len) return p.fail("Trailing backslash");
        const ch = p.pat[p.pos];
        p.pos += 1;
        switch (ch) {
            '1'...'9' => {
                const local: u32 = ch - '0';
                if (local >= 32 or p.closed & (@as(u32, 1) << @intCast(local)) == 0) return p.fail("Invalid back reference");
                p.has_backref = true;
                return p.node(.{ .backref = @intCast(p.group_base + local) });
            },
            'w', 'W', 's', 'S' => {
                var s: Set = .{ 0, 0, 0, 0 };
                var k: u16 = 0;
                while (k < 256) : (k += 1) {
                    const b: u8 = @intCast(k);
                    const in = if (ch == 'w' or ch == 'W') isWordChar(b) else std.ascii.isWhitespace(b);
                    if (in == (ch == 'w' or ch == 's')) setAdd(&s, b);
                }
                return p.node(.{ .set = try p.addSet(s) });
            },
            'b' => return p.node(.{ .assert = .wordb }),
            'B' => return p.node(.{ .assert = .nwordb }),
            '<' => return p.node(.{ .assert = .wbeg }),
            '>' => return p.node(.{ .assert = .wend }),
            '`' => return p.node(.{ .assert = .bufbeg }),
            '\'' => return p.node(.{ .assert = .bufend }),
            'n' => return p.node(.{ .lit = '\n' }),
            't' => return p.node(.{ .lit = '\t' }),
            else => return p.litNode(ch),
        }
    }

    fn parseBracket(p: *Parser) Error!u32 {
        var s: Set = .{ 0, 0, 0, 0 };
        var negate = false;
        if (p.peek(0) == '^') {
            negate = true;
            p.pos += 1;
        }
        var first = true;
        const unmatched = "Unmatched [, [^, [:, [., or [=";
        while (true) {
            if (p.pos >= p.pat.len) return p.fail(unmatched);
            var ch = p.pat[p.pos];
            if (ch == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (ch == '[' and p.peek(1) != null and (p.peek(1).? == ':' or p.peek(1).? == '.' or p.peek(1).? == '=')) {
                const kind = p.peek(1).?;
                const start = p.pos + 2;
                const term = [2]u8{ kind, ']' };
                const e = mem.indexOfPos(u8, p.pat, start, &term) orelse return p.fail(unmatched);
                const name = p.pat[start..e];
                p.pos = e + 2;
                if (kind == ':') {
                    const cs = classSet(name) orelse return p.fail("Invalid character class name");
                    setUnion(&s, &cs);
                    if (p.flags.icase and (mem.eql(u8, name, "upper") or mem.eql(u8, name, "lower"))) {
                        const a = classSet("alpha").?;
                        setUnion(&s, &a);
                    }
                    continue;
                }
                if (name.len != 1) return p.fail("Invalid collation character");
                ch = name[0];
                // may still be a range start
                try p.rangeOrSingle(&s, ch);
                continue;
            }
            p.pos += 1;
            if (ch == '\\' and p.flags.bracket_escapes and p.pos < p.pat.len) {
                const e = p.pat[p.pos];
                const tr: ?u8 = switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    ']' => ']',
                    else => null,
                };
                if (tr) |t| {
                    ch = t;
                    p.pos += 1;
                }
            }
            try p.rangeOrSingle(&s, ch);
        }
        if (p.flags.icase) {
            var k: u16 = 0;
            while (k < 256) : (k += 1) {
                const b: u8 = @intCast(k);
                if (setHas(&s, b) and std.ascii.isAlphabetic(b)) {
                    setAdd(&s, std.ascii.toLower(b));
                    setAdd(&s, std.ascii.toUpper(b));
                }
            }
        }
        if (negate) {
            for (&s) |*w| w.* = ~w.*;
            if (p.flags.newline_stop) s[0] &= ~(@as(u64, 1) << '\n');
        }
        return p.node(.{ .set = try p.addSet(s) });
    }

    fn rangeOrSingle(p: *Parser, s: *Set, lo: u8) Error!void {
        if (p.peek(0) == '-' and p.peek(1) != null and p.peek(1).? != ']') {
            p.pos += 1;
            var hi = p.pat[p.pos];
            p.pos += 1;
            if (hi == '[' and p.peek(0) == '.') {
                const e = mem.indexOfPos(u8, p.pat, p.pos + 1, ".]") orelse return p.fail("Unmatched [, [^, [:, [., or [=");
                const name = p.pat[p.pos + 1 .. e];
                if (name.len != 1) return p.fail("Invalid collation character");
                hi = name[0];
                p.pos = e + 2;
            }
            if (hi < lo) return p.fail("Invalid range end");
            var k: u16 = lo;
            while (k <= hi) : (k += 1) setAdd(s, @intCast(k));
            return;
        }
        setAdd(s, lo);
    }
};

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

const FirstInfo = struct { set: Set, nullable: bool };

fn firstSet(nodes: []const Node, sets: []const Set, n: u32, icase: bool) FirstInfo {
    var r: FirstInfo = .{ .set = .{ 0, 0, 0, 0 }, .nullable = false };
    switch (nodes[n]) {
        .empty, .assert => r.nullable = true,
        .lit => |ch| {
            setAdd(&r.set, ch);
            if (icase and std.ascii.isAlphabetic(ch)) setAdd(&r.set, std.ascii.toUpper(ch));
        },
        .any => r.set = full_set,
        .set => |si| r.set = sets[si],
        .backref => {
            r.set = full_set;
            r.nullable = true;
        },
        .group => |g| return firstSet(nodes, sets, g.child, icase),
        .cat => |c| {
            const a = firstSet(nodes, sets, c.a, icase);
            r.set = a.set;
            if (a.nullable) {
                const b = firstSet(nodes, sets, c.b, icase);
                setUnion(&r.set, &b.set);
                r.nullable = b.nullable;
            }
        },
        .alt => |c| {
            const a = firstSet(nodes, sets, c.a, icase);
            const b = firstSet(nodes, sets, c.b, icase);
            r.set = a.set;
            setUnion(&r.set, &b.set);
            r.nullable = a.nullable or b.nullable;
        },
        .rep => |rp| {
            const a = firstSet(nodes, sets, rp.child, icase);
            r.set = a.set;
            r.nullable = rp.min == 0 or a.nullable;
        },
    }
    return r;
}

fn startsAnchored(nodes: []const Node, n: u32) bool {
    return switch (nodes[n]) {
        .assert => |a| a == .bol or a == .bufbeg,
        .group => |g| startsAnchored(nodes, g.child),
        .cat => |c| startsAnchored(nodes, c.a),
        .alt => |c| startsAnchored(nodes, c.a) and startsAnchored(nodes, c.b),
        else => false,
    };
}

fn nullable(nodes: []const Node, n: u32) bool {
    return switch (nodes[n]) {
        .empty, .assert, .backref => true,
        .lit, .any, .set => false,
        .group => |g| nullable(nodes, g.child),
        .cat => |c| nullable(nodes, c.a) and nullable(nodes, c.b),
        .alt => |c| nullable(nodes, c.a) or nullable(nodes, c.b),
        .rep => |r| r.min == 0 or nullable(nodes, r.child),
    };
}

// ---------------------------------------------------------------------------
// Compiler
// ---------------------------------------------------------------------------

const Compiler = struct {
    alloc: Allocator,
    nodes: []const Node,
    flags: Flags,
    insts: std.ArrayList(Inst) = .empty,
    loop_base: u32,
    nloops: u32 = 0,

    fn emit(c: *Compiler, i: Inst) Error!void {
        if (c.insts.items.len > 200_000) {
            err_msg = "Regular expression too big";
            return error.BadPattern;
        }
        try c.insts.append(c.alloc, i);
    }
    fn pc(c: *Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn gen(c: *Compiler, n: u32) Error!void {
        switch (c.nodes[n]) {
            .empty => {},
            .lit => |ch| try c.emit(.{ .char = ch }),
            .any => try c.emit(if (c.flags.newline_stop) .any_nonl else .any),
            .set => |s| try c.emit(.{ .set = s }),
            .assert => |a| try c.emit(.{ .assert = a }),
            .backref => |g| try c.emit(.{ .backref = g }),
            .group => |g| {
                try c.emit(.{ .save = 2 * @as(u32, g.idx) });
                try c.gen(g.child);
                try c.emit(.{ .save = 2 * @as(u32, g.idx) + 1 });
            },
            .cat => |x| {
                try c.gen(x.a);
                try c.gen(x.b);
            },
            .alt => |x| {
                const sp = c.pc();
                try c.emit(.{ .split = .{ sp + 1, 0 } });
                try c.gen(x.a);
                const j = c.pc();
                try c.emit(.{ .jmp = 0 });
                c.insts.items[sp].split[1] = c.pc();
                try c.gen(x.b);
                c.insts.items[j].jmp = c.pc();
            },
            .rep => |r| {
                var k: u32 = 0;
                while (k < r.min) : (k += 1) try c.gen(r.child);
                const can_empty = nullable(c.nodes, r.child);
                if (r.max == INF) {
                    const slot = c.loop_base + c.nloops;
                    if (can_empty) c.nloops += 1;
                    const l = c.pc();
                    try c.emit(.{ .split = .{ l + 1, 0 } });
                    if (can_empty) try c.emit(.{ .mark = slot });
                    try c.gen(r.child);
                    if (can_empty) try c.emit(.{ .check = slot });
                    try c.emit(.{ .jmp = l });
                    c.insts.items[l].split[1] = c.pc();
                } else {
                    var fixups: std.ArrayList(u32) = .empty;
                    defer fixups.deinit(c.alloc);
                    k = r.min;
                    while (k < r.max) : (k += 1) {
                        const sp = c.pc();
                        try fixups.append(c.alloc, sp);
                        try c.emit(.{ .split = .{ sp + 1, 0 } });
                        try c.gen(r.child);
                    }
                    const end = c.pc();
                    for (fixups.items) |f| c.insts.items[f].split[1] = end;
                }
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testMatch(pat: []const u8, flags: Flags, text: []const u8) !?[2]isize {
    var re = try Regex.compile(std.testing.allocator, pat, flags);
    defer re.deinit();
    var g: [10]Span = undefined;
    if (!re.exec(text, 0, &g, .{})) return null;
    return .{ g[0].start, g[0].end };
}

fn expectMatch(pat: []const u8, flags: Flags, text: []const u8, s: isize, e: isize) !void {
    const r = try testMatch(pat, flags, text);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(s, r.?[0]);
    try std.testing.expectEqual(e, r.?[1]);
}

test "regex basics BRE" {
    const B: Flags = .{};
    try expectMatch("abc", B, "xxabcxx", 2, 5);
    try expectMatch("a.c", B, "abc", 0, 3);
    try expectMatch("a*", B, "aaab", 0, 3);
    try expectMatch("^ab", B, "abab", 0, 2);
    try std.testing.expect((try testMatch("^b", B, "ab")) == null);
    try expectMatch("b$", B, "abb", 2, 3);
    try expectMatch("a\\{2,3\\}", B, "aaaa", 0, 3);
    try expectMatch("\\(ab\\)*c", B, "ababc", 0, 5);
    try expectMatch("\\(a\\)\\1", B, "xaa", 1, 3);
    try expectMatch("a\\|b", B, "b", 0, 1);
    try expectMatch("a+", B, "a+", 0, 2);
    try expectMatch("*a", B, "x*a", 1, 3);
    try expectMatch("a\\+", B, "caaa", 1, 4);
    try expectMatch("[[:digit:]]\\+", B, "ab123c", 2, 5);
    try expectMatch("[^a-c]", B, "abcd", 3, 4);
    try expectMatch("[]a]", B, "x]", 1, 2);
    try expectMatch("x$y", B, "x$y", 0, 3);
}

test "regex ERE" {
    const E: Flags = .{ .extended = true };
    try expectMatch("a|ab", E, "abcd", 0, 2); // leftmost-longest
    try expectMatch("(a|ab)(c|bcd)", E, "abcd", 0, 4);
    try expectMatch("a+b?", E, "caab", 1, 4);
    try expectMatch("x{2}", E, "xxx", 0, 2);
    try expectMatch("a{,2}b", E, "aaab", 1, 4);
    try expectMatch("(foo|bar)+", E, "foobarfoo!", 0, 9);
    try expectMatch("\\bfoo\\b", E, "a foo b", 2, 5);
    try expectMatch("\\<b", E, "ab b", 3, 4);
    try expectMatch("a{x", E, "a{x", 0, 3);
    try expectMatch("(a*)*b", E, "aab", 0, 3);
    try expectMatch("(a*)+$", E, "aa", 0, 2);
    try expectMatch("()x", E, "x", 0, 1);
    try expectMatch("\\w+", E, "  hello_1 ", 2, 9);
    try expectMatch("(.)\\1", E, "abccd", 2, 4);
}

test "regex icase and wrappers" {
    try expectMatch("hello", .{ .icase = true }, "say HeLLo", 4, 9);
    try expectMatch("[a-c]+", .{ .icase = true, .extended = true }, "xABCx", 1, 4);
    try std.testing.expect((try testMatch("foo", .{ .whole_word = true }, "foobar")) == null);
    try expectMatch("foo", .{ .whole_word = true }, "a foo", 2, 5);
    try std.testing.expect((try testMatch("foo", .{ .whole_line = true }, "foo ")) == null);
    try expectMatch("a|b", .{ .whole_line = true, .extended = true }, "b", 0, 1);
}

test "regex errors" {
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "\\(a", .{}));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "[a", .{}));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "a\\{2", .{}));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "\\1", .{}));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "(a", .{ .extended = true }));
    try std.testing.expectError(error.BadPattern, Regex.compile(std.testing.allocator, "[z-a]", .{}));
}

test "regex captures" {
    var re = try Regex.compile(std.testing.allocator, "\\([a-z]*\\)=\\([0-9]*\\)", .{});
    defer re.deinit();
    var g: [3]Span = undefined;
    try std.testing.expect(re.exec("  key=42;", 0, &g, .{}));
    try std.testing.expectEqual(@as(isize, 2), g[1].start);
    try std.testing.expectEqual(@as(isize, 5), g[1].end);
    try std.testing.expectEqual(@as(isize, 6), g[2].start);
    try std.testing.expectEqual(@as(isize, 8), g[2].end);
}
