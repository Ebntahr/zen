//! Word expansion, in POSIX order: tilde expansion, parameter expansion,
//! command substitution, arithmetic expansion, field splitting, pathname
//! expansion and quote removal.
//!
//! Expansion produces an intermediate character buffer where every byte
//! carries flags describing whether it was quoted and whether it came from
//! an unquoted expansion (and is therefore subject to field splitting).
const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const glob = @import("glob.zig");
const arith = @import("arith.zig");
const exec = @import("exec.zig");
const parser = @import("parser.zig");
const brace = @import("brace.zig");
const Shell = shell.Shell;
const Error = shell.Error;
const Allocator = std.mem.Allocator;

const Q: u8 = 1; // quoted: no splitting, no globbing
const SPLIT: u8 = 2; // unquoted expansion result: subject to field splitting
const BREAK: u8 = 4; // hard field break ("$@")
const EMPTYQ: u8 = 8; // marker: an empty quoted string was here
const SOFT: u8 = 16; // soft field break (unquoted $@ / $*)
const MARK = BREAK | EMPTYQ | SOFT;

const Buf = struct {
    a: Allocator,
    chars: std.ArrayList(u8) = .empty,
    flags: std.ArrayList(u8) = .empty,

    fn add(b: *Buf, s: []const u8, f: u8) !void {
        try b.chars.appendSlice(b.a, s);
        try b.flags.appendNTimes(b.a, f, s.len);
    }

    fn addc(b: *Buf, c: u8, f: u8) !void {
        try b.chars.append(b.a, c);
        try b.flags.append(b.a, f);
    }

    fn mark(b: *Buf, f: u8) !void {
        try b.chars.append(b.a, 0);
        try b.flags.append(b.a, f);
    }

    fn len(b: *Buf) usize {
        return b.chars.items.len;
    }
};

const Ctx = struct {
    quoted: bool = false,
    split_lits: bool = false,
    assign: bool = false,
};

fn failExpansion(sh: *Shell, comptime fmt: []const u8, args: anytype) Error {
    sh.errMsg(fmt, args);
    sh.last_status = 1;
    return error.Abort;
}

// ---------------------------------------------------------------------------
// parts
// ---------------------------------------------------------------------------

fn allAt(parts: []const ast.Part) bool {
    if (parts.len == 0) return false;
    for (parts) |p| switch (p) {
        .param => |pp| if (!(std.mem.eql(u8, pp.name, "@") and (pp.op == .none or pp.op == .substr))) return false,
        else => return false,
    };
    return true;
}

fn expandParts(sh: *Shell, b: *Buf, parts: []const ast.Part, ctx: Ctx, word_start: bool) Error!void {
    for (parts, 0..) |part, i| {
        switch (part) {
            .lit => |s| try expandLit(sh, b, s, ctx, word_start and i == 0, i + 1 == parts.len),
            .qlit => |s| {
                if (s.len == 0) try b.mark(EMPTYQ) else try b.add(s, Q);
            },
            .dq => |inner| {
                const start = b.len();
                try expandParts(sh, b, inner, .{ .quoted = true }, false);
                if (b.len() == start and !allAt(inner)) try b.mark(EMPTYQ);
            },
            .param => |p| try expandParam(sh, b, p, ctx),
            .cmdsub => |node| {
                const out = try exec.commandSubst(sh, node);
                try b.add(out, if (ctx.quoted) Q else SPLIT);
            },
            .arith => |inner| {
                const expr = try partsToString(sh, inner, .{ .quoted = true });
                const v = try arith.eval(sh, expr);
                var nb: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&nb, "{d}", .{v}) catch unreachable;
                try b.add(s, if (ctx.quoted) Q else SPLIT);
            },
        }
    }
}

fn expandLit(sh: *Shell, b: *Buf, s: []const u8, ctx: Ctx, at_start: bool, last_part: bool) Error!void {
    const f: u8 = if (ctx.quoted) Q else if (ctx.split_lits) SPLIT else 0;
    var i: usize = 0;
    if (!ctx.quoted and at_start and s.len > 0 and s[0] == '~') i = try tilde(sh, b, s, 0, ctx, last_part);
    while (i < s.len) {
        const c = s[i];
        if (ctx.assign and !ctx.quoted and c == ':' and i + 1 < s.len and s[i + 1] == '~') {
            try b.addc(':', f);
            i = try tilde(sh, b, s, i + 1, ctx, last_part);
            continue;
        }
        try b.addc(c, f);
        i += 1;
    }
}

/// Expand a tilde prefix starting at s[start] == '~'. Returns the index of
/// the first unconsumed character.
fn tilde(sh: *Shell, b: *Buf, s: []const u8, start: usize, ctx: Ctx, last_part: bool) Error!usize {
    var end = start + 1;
    while (end < s.len and s[end] != '/' and !(ctx.assign and s[end] == ':')) end += 1;
    if (end == s.len and !last_part) return start;
    const user = s[start + 1 .. end];
    var home: ?[]const u8 = null;
    if (user.len == 0) {
        home = sh.getVar("HOME");
        if (home == null) {
            if (shell.passwdLookup(sh.scratchAlloc(), .{ .uid = sys.getuid() })) |pw| home = pw.home;
        }
    } else if (std.mem.eql(u8, user, "+")) {
        home = sh.getVar("PWD");
    } else if (std.mem.eql(u8, user, "-")) {
        home = sh.getVar("OLDPWD");
    } else {
        if (shell.passwdLookup(sh.scratchAlloc(), .{ .name = user })) |pw| home = pw.home;
    }
    const h = home orelse return start;
    try b.add(h, Q);
    if (h.len == 0) try b.mark(EMPTYQ);
    return end;
}

// ---------------------------------------------------------------------------
// parameters
// ---------------------------------------------------------------------------

fn isSpecial(name: []const u8) bool {
    return name.len == 1 and std.mem.indexOfScalar(u8, "@*#?$!-0123456789", name[0]) != null;
}

/// Value of a parameter, or null if unset.
pub fn getParam(sh: *Shell, name: []const u8) Error!?[]const u8 {
    const a = sh.scratchAlloc();
    if (name.len > 0 and std.ascii.isDigit(name[0])) {
        const n = std.fmt.parseInt(usize, name, 10) catch return null;
        if (n == 0) return sh.arg0;
        if (n <= sh.params.len) return sh.params[n - 1];
        return null;
    }
    if (name.len == 1) {
        switch (name[0]) {
            '?' => return try std.fmt.allocPrint(a, "{d}", .{sh.last_status}),
            '$' => return try std.fmt.allocPrint(a, "{d}", .{sh.pid}),
            '!' => return if (sh.last_bg_pid) |p| try std.fmt.allocPrint(a, "{d}", .{p}) else null,
            '#' => return try std.fmt.allocPrint(a, "{d}", .{sh.params.len}),
            '-' => {
                var fb: [32]u8 = undefined;
                return try a.dupe(u8, sh.flagsString(&fb));
            },
            '@', '*' => {
                if (sh.params.len == 0) return null;
                return try joinParams(sh, a, sh.params, ' ');
            },
            else => {},
        }
    }
    return sh.getVar(name);
}

fn joinParams(sh: *Shell, a: Allocator, params: []const []const u8, sep_default: u8) Error![]const u8 {
    _ = sep_default;
    const ifs = sh.ifs();
    var out: std.ArrayList(u8) = .empty;
    for (params, 0..) |p, i| {
        if (i > 0 and ifs.len > 0) try out.append(a, ifs[0]);
        try out.appendSlice(a, p);
    }
    return out.items;
}

fn utf8Len(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of the n-th codepoint (clamped to s.len).
fn cpOffset(s: []const u8, n: usize) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) {
            if (count == n) return i;
            count += 1;
        }
    }
    return s.len;
}

fn isBoundary(s: []const u8, i: usize) bool {
    return i == 0 or i >= s.len or (s[i] & 0xC0) != 0x80;
}

fn expandParam(sh: *Shell, b: *Buf, p: *const ast.Param, ctx: Ctx) Error!void {
    const name = p.name;
    const vflag: u8 = if (ctx.quoted) Q else SPLIT;
    const is_list = std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*");

    if (is_list and p.op == .none) {
        return emitList(sh, b, sh.params, name[0] == '@', ctx);
    }
    if (is_list and p.op == .substr) {
        // positional slicing: ${@:off:len}
        const a = sh.scratchAlloc();
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(a, sh.arg0);
        for (sh.params) |x| try all.append(a, x);
        const off_s = try partsToString(sh, p.arg.?.parts, .{ .quoted = true });
        var off = try arith.eval(sh, off_s);
        const n: i64 = @intCast(all.items.len);
        if (off < 0) off += n;
        if (off < 0) off = n;
        var end: i64 = n;
        if (p.arg2) |l| {
            const ls = try partsToString(sh, l.parts, .{ .quoted = true });
            const lv = try arith.eval(sh, ls);
            if (lv < 0) return failExpansion(sh, "{s}: substring expression < 0", .{ls});
            end = @min(n, off + lv);
        }
        if (off == 0 and p.arg == null) off = 1;
        const lo: usize = @intCast(@min(off, n));
        const hi: usize = @intCast(@max(@as(i64, @intCast(lo)), end));
        return emitList(sh, b, all.items[lo..hi], name[0] == '@', ctx);
    }

    if (p.op == .bad) return failExpansion(sh, "{s}: bad substitution", .{name});
    const val = try getParam(sh, name);
    const unset_or_null = val == null or (p.colon and val.?.len == 0);

    switch (p.op) {
        .none => {
            const v = val orelse {
                if (sh.opts.nounset and !is_list) return failExpansion(sh, "{s}: parameter not set", .{name});
                return;
            };
            try b.add(v, vflag);
        },
        .length => {
            if (is_list) {
                var nb: [24]u8 = undefined;
                try b.add(std.fmt.bufPrint(&nb, "{d}", .{sh.params.len}) catch unreachable, vflag);
                return;
            }
            const v = val orelse blk: {
                if (sh.opts.nounset) return failExpansion(sh, "{s}: parameter not set", .{name});
                break :blk "";
            };
            var nb: [24]u8 = undefined;
            try b.add(std.fmt.bufPrint(&nb, "{d}", .{utf8Len(v)}) catch unreachable, vflag);
        },
        .default => {
            if (unset_or_null) {
                if (p.arg) |w| try expandParts(sh, b, w.parts, .{ .quoted = ctx.quoted, .split_lits = !ctx.quoted }, !ctx.quoted);
            } else if (is_list) {
                return emitList(sh, b, sh.params, name[0] == '@', ctx);
            } else try b.add(val.?, vflag);
        },
        .alt => {
            if (!unset_or_null) {
                if (p.arg) |w| try expandParts(sh, b, w.parts, .{ .quoted = ctx.quoted, .split_lits = !ctx.quoted }, !ctx.quoted);
            }
        },
        .assign => {
            if (unset_or_null) {
                if (isSpecial(name) or !parser.isName(name)) return failExpansion(sh, "${s}: cannot assign in this way", .{name});
                const v = if (p.arg) |w| try partsToString(sh, w.parts, .{}) else "";
                try sh.setVar(name, v);
                try b.add(v, vflag);
            } else try b.add(val.?, vflag);
        },
        .err => {
            if (unset_or_null) {
                const msg = if (p.arg) |w| try partsToString(sh, w.parts, .{}) else "";
                if (msg.len > 0) return failExpansion(sh, "{s}: {s}", .{ name, msg });
                return failExpansion(sh, "{s}: parameter null or not set", .{name});
            }
            try b.add(val.?, vflag);
        },
        .rm_prefix, .rm_prefix_long, .rm_suffix, .rm_suffix_long => {
            const v = val orelse blk: {
                if (sh.opts.nounset) return failExpansion(sh, "{s}: parameter not set", .{name});
                break :blk "";
            };
            const pat = if (p.arg) |w| try expandPattern(sh, w) else "";
            try b.add(removePattern(v, pat, p.op), vflag);
        },
        .sub, .sub_all, .sub_prefix, .sub_suffix => {
            const v = val orelse blk: {
                if (sh.opts.nounset) return failExpansion(sh, "{s}: parameter not set", .{name});
                break :blk "";
            };
            const pat = if (p.arg) |w| try expandPattern(sh, w) else "";
            const rep = if (p.arg2) |w| try partsToString(sh, w.parts, .{ .quoted = true }) else "";
            try b.add(try substitute(sh.scratchAlloc(), v, pat, rep, p.op), vflag);
        },
        .substr => {
            const v = val orelse "";
            const off_s = try partsToString(sh, p.arg.?.parts, .{ .quoted = true });
            var off = try arith.eval(sh, off_s);
            const n: i64 = @intCast(utf8Len(v));
            if (off < 0) off += n;
            if (off < 0 or off > n) return;
            var end: i64 = n;
            if (p.arg2) |l| {
                const ls = try partsToString(sh, l.parts, .{ .quoted = true });
                const lv = try arith.eval(sh, ls);
                end = if (lv < 0) n + lv else @min(n, off + lv);
                if (end < off) return failExpansion(sh, "{s}: substring expression < 0", .{ls});
            }
            const lo = cpOffset(v, @intCast(off));
            const hi = cpOffset(v, @intCast(end));
            try b.add(v[lo..hi], vflag);
        },
        .bad => unreachable,
        .upper_first, .upper_all, .lower_first, .lower_all => {
            const v = val orelse "";
            const out = try sh.scratchAlloc().dupe(u8, v);
            const upper = p.op == .upper_first or p.op == .upper_all;
            const all = p.op == .upper_all or p.op == .lower_all;
            for (out, 0..) |*c, i| {
                if (i > 0 and !all) break;
                c.* = if (upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
            }
            try b.add(out, vflag);
        },
    }
}

fn emitList(sh: *Shell, b: *Buf, params: []const []const u8, at: bool, ctx: Ctx) Error!void {
    if (ctx.quoted) {
        if (at) {
            for (params, 0..) |x, i| {
                if (i > 0) try b.mark(BREAK);
                if (x.len == 0) try b.mark(EMPTYQ) else try b.add(x, Q);
            }
        } else {
            try b.add(try joinParams(sh, sh.scratchAlloc(), params, ' '), Q);
        }
    } else {
        for (params, 0..) |x, i| {
            if (i > 0) try b.mark(SOFT);
            try b.add(x, SPLIT);
        }
    }
}

fn removePattern(v: []const u8, pat: []const u8, op: ast.ParamOp) []const u8 {
    const n = v.len;
    switch (op) {
        .rm_prefix => {
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                if (!isBoundary(v, i)) continue;
                if (glob.fnmatch(pat, v[0..i], .{})) return v[i..];
            }
        },
        .rm_prefix_long => {
            var i: usize = n + 1;
            while (i > 0) {
                i -= 1;
                if (!isBoundary(v, i)) continue;
                if (glob.fnmatch(pat, v[0..i], .{})) return v[i..];
            }
        },
        .rm_suffix => {
            var i: usize = n + 1;
            while (i > 0) {
                i -= 1;
                if (!isBoundary(v, i)) continue;
                if (glob.fnmatch(pat, v[i..], .{})) return v[0..i];
            }
        },
        .rm_suffix_long => {
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                if (!isBoundary(v, i)) continue;
                if (glob.fnmatch(pat, v[i..], .{})) return v[0..i];
            }
        },
        else => {},
    }
    return v;
}

fn substitute(a: Allocator, v: []const u8, pat: []const u8, rep: []const u8, op: ast.ParamOp) Error![]const u8 {
    if (pat.len == 0) return v;
    const n = v.len;
    var out: std.ArrayList(u8) = .empty;
    switch (op) {
        .sub_prefix => {
            var j: usize = n + 1;
            while (j > 0) {
                j -= 1;
                if (!isBoundary(v, j)) continue;
                if (glob.fnmatch(pat, v[0..j], .{})) {
                    try out.appendSlice(a, rep);
                    try out.appendSlice(a, v[j..]);
                    return out.items;
                }
            }
            return v;
        },
        .sub_suffix => {
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                if (!isBoundary(v, i)) continue;
                if (glob.fnmatch(pat, v[i..], .{})) {
                    try out.appendSlice(a, v[0..i]);
                    try out.appendSlice(a, rep);
                    return out.items;
                }
            }
            return v;
        },
        else => {},
    }
    var i: usize = 0;
    var replaced = false;
    while (i < n) {
        if (replaced and op != .sub_all) break;
        var matched: ?usize = null;
        if (isBoundary(v, i)) {
            var j: usize = n + 1;
            while (j > i) {
                j -= 1;
                if (!isBoundary(v, j)) continue;
                if (glob.fnmatch(pat, v[i..j], .{})) {
                    matched = j;
                    break;
                }
            }
        }
        if (matched) |j| {
            if (j > i) {
                try out.appendSlice(a, rep);
                i = j;
                replaced = true;
                continue;
            }
        }
        try out.append(a, v[i]);
        i += 1;
    }
    try out.appendSlice(a, v[i..]);
    return out.items;
}

// ---------------------------------------------------------------------------
// public entry points
// ---------------------------------------------------------------------------

fn toStringNoSplit(b: *Buf) []u8 {
    var w: usize = 0;
    const chars = b.chars.items;
    const flags = b.flags.items;
    for (chars, flags) |c, f| {
        if (f & (BREAK | SOFT) != 0) {
            chars[w] = ' ';
            w += 1;
        } else if (f & EMPTYQ == 0) {
            chars[w] = c;
            w += 1;
        }
    }
    return chars[0..w];
}

/// Expand parts into a single string without field splitting or globbing.
pub fn partsToString(sh: *Shell, parts: []const ast.Part, ctx: Ctx) Error![]u8 {
    var b = Buf{ .a = sh.scratchAlloc() };
    try expandParts(sh, &b, parts, ctx, !ctx.quoted);
    return toStringNoSplit(&b);
}

/// Expand a word to a single string (assignments, redirection targets,
/// case words, here-strings).
pub fn wordToString(sh: *Shell, w: ast.Word, assign: bool) Error![]const u8 {
    if (w.plainLit()) |s| {
        if (s.len == 0 or (s[0] != '~' and (!assign or std.mem.indexOf(u8, s, ":~") == null))) return s;
    }
    var b = Buf{ .a = sh.scratchAlloc() };
    try expandParts(sh, &b, w.parts, .{ .assign = assign }, true);
    return toStringNoSplit(&b);
}

/// Expand a here-document body.
pub fn heredocToString(sh: *Shell, w: ast.Word) Error![]const u8 {
    if (w.parts.len == 1) switch (w.parts[0]) {
        .qlit => |s| return s,
        else => {},
    };
    var b = Buf{ .a = sh.scratchAlloc() };
    try expandParts(sh, &b, w.parts, .{ .quoted = true }, false);
    return toStringNoSplit(&b);
}

fn isGlobSpecial(c: u8) bool {
    return c == '*' or c == '?' or c == '[' or c == ']' or c == '\\';
}

/// Expand a word into a pattern: quoted characters are escaped with '\'.
pub fn expandPattern(sh: *Shell, w: ast.Word) Error![]const u8 {
    if (w.plainLit()) |s| {
        if (s.len == 0 or s[0] != '~') return s;
    }
    var b = Buf{ .a = sh.scratchAlloc() };
    try expandParts(sh, &b, w.parts, .{}, true);
    var out: std.ArrayList(u8) = .empty;
    const a = sh.scratchAlloc();
    for (b.chars.items, b.flags.items) |c, f| {
        if (f & (BREAK | SOFT) != 0) {
            try out.append(a, ' ');
        } else if (f & EMPTYQ != 0) {
            continue;
        } else if (f & Q != 0 and isGlobSpecial(c)) {
            try out.append(a, '\\');
            try out.append(a, c);
        } else try out.append(a, c);
    }
    return out.items;
}

fn inSet(set: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, set, c) != null;
}

fn isIfsWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Full expansion of a list of words into argv strings (NUL terminated).
pub fn expandWords(sh: *Shell, words_in: []const ast.Word) Error![][:0]u8 {
    const a = sh.scratchAlloc();
    var out: std.ArrayList([:0]u8) = .empty;
    var words = words_in;
    if (sh.opts.braceexpand) {
        for (words_in) |w| {
            if (brace.mayExpand(w)) {
                var list: std.ArrayList(ast.Word) = .empty;
                for (words_in) |x| {
                    if (brace.mayExpand(x)) {
                        try list.appendSlice(a, try brace.expand(a, x));
                    } else try list.append(a, x);
                }
                words = list.items;
                break;
            }
        }
    }
    for (words) |w| {
        if (w.plainLit()) |s| {
            if (s.len > 0 and s[0] != '~' and (sh.opts.noglob or !glob.hasMeta(s))) {
                try out.append(a, try a.dupeZ(u8, s));
                continue;
            }
        }
        var b = Buf{ .a = a };
        try expandParts(sh, &b, w.parts, .{}, true);
        try splitFields(sh, &b, &out);
    }
    return out.items;
}

fn isAssignmentWord(w: ast.Word) bool {
    if (w.parts.len == 0) return false;
    const first = switch (w.parts[0]) {
        .lit => |x| x,
        else => return false,
    };
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return false;
    var name = first[0..eq];
    if (name.len > 0 and name[name.len - 1] == '+') name = name[0 .. name.len - 1];
    return parser.isName(name);
}

/// Is this simple command a declaration utility (export, readonly, local,
/// declare, typeset) whose NAME=value operands are expanded like
/// assignments (no field splitting or globbing)?
pub fn isDeclUtility(words: []const ast.Word) bool {
    if (words.len < 2) return false;
    const name = words[0].plainLit() orelse return false;
    const decl = [_][]const u8{ "export", "readonly", "local", "declare", "typeset" };
    for (decl) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

pub fn expandDeclWords(sh: *Shell, words: []const ast.Word) Error![][:0]u8 {
    const a = sh.scratchAlloc();
    var out: std.ArrayList([:0]u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0 and isAssignmentWord(w)) {
            // split "NAME=" off so the value gets assignment treatment
            const first = w.parts[0].lit;
            const eq = std.mem.indexOfScalar(u8, first, '=').?;
            var vparts: std.ArrayList(ast.Part) = .empty;
            if (eq + 1 < first.len) try vparts.append(a, .{ .lit = first[eq + 1 ..] });
            try vparts.appendSlice(a, w.parts[1..]);
            const val = try wordToString(sh, .{ .parts = vparts.items }, true);
            try out.append(a, try std.mem.concatWithSentinel(a, u8, &.{ first[0 .. eq + 1], val }, 0));
        } else {
            const one = [1]ast.Word{w};
            try out.appendSlice(a, try expandWords(sh, &one));
        }
    }
    return out.items;
}

/// Expand words into fields without pathname expansion (used by `for`
/// when globbing is off, and by `read`-like consumers).
fn splitFields(sh: *Shell, b: *Buf, out: *std.ArrayList([:0]u8)) Error!void {
    const ifs = sh.ifs();
    const chars = b.chars.items;
    const flags = b.flags.items;
    const n = chars.len;
    var cur_start: usize = 0;
    var cur_has = false;
    var i: usize = 0;
    while (i < n) {
        const f = flags[i];
        const c = chars[i];
        if (f & BREAK != 0) {
            try emitField(sh, b, cur_start, i, out);
            cur_start = i + 1;
            cur_has = false;
            i += 1;
            continue;
        }
        if (f & SOFT != 0) {
            if (cur_has) try emitField(sh, b, cur_start, i, out);
            cur_start = i + 1;
            cur_has = false;
            i += 1;
            continue;
        }
        if (f & EMPTYQ != 0) {
            cur_has = true;
            i += 1;
            continue;
        }
        if (f & SPLIT != 0 and inSet(ifs, c)) {
            var ws = isIfsWs(c);
            if (!cur_has and ws) {
                i += 1;
                cur_start = i;
                continue;
            }
            try emitField(sh, b, cur_start, i, out);
            i += 1;
            while (i < n and flags[i] & SPLIT != 0 and inSet(ifs, chars[i])) {
                if (!isIfsWs(chars[i])) {
                    if (ws) {
                        ws = false;
                        i += 1;
                    } else break;
                } else i += 1;
            }
            cur_start = i;
            cur_has = false;
            continue;
        }
        cur_has = true;
        i += 1;
    }
    if (cur_has) try emitField(sh, b, cur_start, n, out);
}

fn emitField(sh: *Shell, b: *Buf, start: usize, end: usize, out: *std.ArrayList([:0]u8)) Error!void {
    const a = sh.scratchAlloc();
    const chars = b.chars.items[start..end];
    const flags = b.flags.items[start..end];
    var need_glob = false;
    if (!sh.opts.noglob) {
        var open_bracket = false;
        for (chars, flags) |c, f| {
            if (f & (Q | MARK) != 0) continue;
            if (c == '*' or c == '?' or (c == ']' and open_bracket)) {
                need_glob = true;
                break;
            }
            if (c == '[') open_bracket = true;
        }
    }
    var lit: std.ArrayList(u8) = .empty;
    for (chars, flags) |c, f| {
        if (f & MARK == 0) try lit.append(a, c);
    }
    if (need_glob) {
        var pat: std.ArrayList(u8) = .empty;
        for (chars, flags) |c, f| {
            if (f & MARK != 0) continue;
            if (f & Q != 0 and isGlobSpecial(c)) try pat.append(a, '\\');
            try pat.append(a, c);
        }
        const matches = glob.glob(a, pat.items) catch &.{};
        if (matches.len > 0) {
            for (matches) |m| try out.append(a, try a.dupeZ(u8, m));
            return;
        }
    }
    try out.append(a, try a.dupeZ(u8, lit.items));
}

/// Split a string by IFS (used by `read`).  `escaped[i]` marks characters
/// that must not be treated as delimiters.
pub fn ifsSplit(a: Allocator, ifs: []const u8, s: []const u8, maxfields: usize) Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len and isIfsWs(s[i]) and inSet(ifs, s[i])) i += 1;
    while (i < s.len) {
        if (maxfields > 0 and out.items.len + 1 == maxfields) {
            // last field: rest of line minus trailing IFS whitespace
            var e = s.len;
            while (e > i and isIfsWs(s[e - 1]) and inSet(ifs, s[e - 1])) e -= 1;
            try out.append(a, s[i..e]);
            return out.items;
        }
        const start = i;
        while (i < s.len and !inSet(ifs, s[i])) i += 1;
        try out.append(a, s[start..i]);
        if (i >= s.len) break;
        var ws = isIfsWs(s[i]);
        i += 1;
        while (i < s.len and inSet(ifs, s[i])) {
            if (!isIfsWs(s[i])) {
                if (ws) {
                    ws = false;
                    i += 1;
                } else break;
            } else i += 1;
        }
    }
    return out.items;
}
