const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: diff [OPTION]... FILES
    \\Compare FILES line by line.
    \\
    \\      --normal                  output a normal diff (the default)
    \\  -q, --brief                   report only when files differ
    \\  -s, --report-identical-files  report when two files are the same
    \\  -c, -C NUM, --context[=NUM]   output NUM (default 3) lines of copied context
    \\  -u, -U NUM, --unified[=NUM]   output NUM (default 3) lines of unified context
    \\  -r, --recursive               recursively compare any subdirectories found
    \\  -N, --new-file                treat absent files as empty
    \\  -i, --ignore-case             ignore case differences in file contents
    \\  -b, --ignore-space-change     ignore changes in the amount of white space
    \\  -w, --ignore-all-space        ignore all white space
    \\  -B, --ignore-blank-lines      ignore changes where lines are all blank
    \\  -a, --text                    treat all files as text
    \\      --label LABEL             use LABEL instead of file name and timestamp
    \\
    \\FILES are 'FILE1 FILE2' or 'DIR1 DIR2' or 'DIR FILE' or 'FILE DIR'.
    \\If a FILE is '-', read standard input.
    \\Exit status is 0 if inputs are the same, 1 if different, 2 if trouble.
    \\
;

const Format = enum { normal, unified, context };

var format: Format = .normal;
var context: usize = 3;
var brief = false;
var report_same = false;
var recursive = false;
var new_file = false;
var icase = false;
var ign_space_change = false;
var ign_all_space = false;
var ign_blank = false;
var text = false;
var labels: [2]?[]const u8 = .{ null, null };
var status: u8 = 0;
var opt_string: []const u8 = "";

const File = struct {
    name: []const u8,
    data: []const u8,
    lines: [][]const u8,
    last_nl: bool,
    mtime: c.Ts,
};

fn loadFile(name: []const u8) ?File {
    var st: ?c.Stat = null;
    const data = blk: {
        if (c.eql(name, "-")) {
            st = c.sys.fstat(0) catch null;
            break :blk c.readFdAll(0) catch |e| {
                c.warn("-: {s}", .{c.strerror(e)});
                return null;
            };
        }
        st = c.sys.stat(name) catch null;
        break :blk c.readFile(name) catch |e| {
            c.warn("{s}: {s}", .{ name, c.strerror(e) });
            return null;
        };
    };
    const lines = c.splitLines(data, '\n');
    return .{
        .name = name,
        .data = data,
        .lines = lines,
        .last_nl = data.len == 0 or data[data.len - 1] == '\n',
        .mtime = if (st) |s| s.mtime else c.now(),
    };
}

fn keyOf(buf: *std.ArrayList(u8), line: []const u8) []const u8 {
    if (!icase and !ign_space_change and !ign_all_space) return line;
    buf.clearRetainingCapacity();
    var in_space = false;
    for (line) |ch_in| {
        var ch = ch_in;
        if (icase) ch = std.ascii.toLower(ch);
        const sp = ch == ' ' or ch == '\t' or ch == '\r' or ch == 11 or ch == 12;
        if (ign_all_space and sp) continue;
        if (ign_space_change and sp) {
            in_space = true;
            continue;
        }
        if (in_space) {
            buf.append(c.gpa, ' ') catch c.oom();
            in_space = false;
        }
        buf.append(c.gpa, ch) catch c.oom();
    }
    return buf.items;
}

/// Myers diff. Returns change marks for a (deleted) and b (inserted).
fn computeDiff(a: []const u32, b: []const u32, del: []bool, ins: []bool) void {
    // trim common prefix / suffix
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and a[pre] == b[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and a[a.len - 1 - suf] == b[b.len - 1 - suf]) suf += 1;
    const A = a[pre .. a.len - suf];
    const B = b[pre .. b.len - suf];
    const dA = del[pre .. a.len - suf];
    const iB = ins[pre .. b.len - suf];
    const n: isize = @intCast(A.len);
    const m: isize = @intCast(B.len);
    if (n == 0) {
        @memset(iB, true);
        return;
    }
    if (m == 0) {
        @memset(dA, true);
        return;
    }
    const max: usize = @intCast(n + m);
    const off: isize = @intCast(max + 1);
    var v = c.gpa.alloc(isize, 2 * max + 4) catch c.oom();
    defer c.gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| c.gpa.free(t);
        trace.deinit(c.gpa);
    }
    var d: isize = 0;
    var found = false;
    while (d <= max) : (d += 1) {
        // snapshot of v before this round (range -d..d)
        const snap = c.gpa.alloc(isize, @intCast(2 * d + 3)) catch c.oom();
        var kk: isize = -d - 1;
        while (kk <= d + 1) : (kk += 1) snap[@intCast(kk + d + 1)] = v[@intCast(kk + off)];
        trace.append(c.gpa, snap) catch c.oom();
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var x: isize = undefined;
            if (k == -d or (k != d and v[@intCast(k - 1 + off)] < v[@intCast(k + 1 + off)])) {
                x = v[@intCast(k + 1 + off)];
            } else x = v[@intCast(k - 1 + off)] + 1;
            var y = x - k;
            while (x < n and y < m and A[@intCast(x)] == B[@intCast(y)]) {
                x += 1;
                y += 1;
            }
            v[@intCast(k + off)] = x;
            if (x >= n and y >= m) {
                found = true;
                break;
            }
        }
        if (found) break;
        if (d > 30000) {
            // too expensive: give up and mark everything changed
            @memset(dA, true);
            @memset(iB, true);
            return;
        }
    }
    // backtrack
    var x = n;
    var y = m;
    var dd = d;
    while (dd > 0) : (dd -= 1) {
        const snap = trace.items[@intCast(dd)];
        const sv = struct {
            fn get(s: []isize, k: isize, dcur: isize) isize {
                return s[@intCast(k + dcur + 1)];
            }
        }.get;
        // snap holds v at the start of round dd, i.e. values from round dd-1
        const k = x - y;
        var prev_k: isize = undefined;
        if (k == -dd or (k != dd and sv(snap, k - 1, dd) < sv(snap, k + 1, dd))) prev_k = k + 1 else prev_k = k - 1;
        const prev_x = sv(snap, prev_k, dd);
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
        }
        if (x == prev_x) {
            iB[@intCast(prev_y)] = true;
        } else {
            dA[@intCast(prev_x)] = true;
        }
        x = prev_x;
        y = prev_y;
    }
}

const Change = struct { a0: usize, a1: usize, b0: usize, b1: usize };

fn buildChanges(del: []const bool, ins: []const bool) []Change {
    var list: std.ArrayList(Change) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < del.len or j < ins.len) {
        if ((i < del.len and del[i]) or (j < ins.len and ins[j])) {
            const a0 = i;
            const b0 = j;
            while (i < del.len and del[i]) i += 1;
            while (j < ins.len and ins[j]) j += 1;
            list.append(c.gpa, .{ .a0 = a0, .a1 = i, .b0 = b0, .b1 = j }) catch c.oom();
        } else {
            i += 1;
            j += 1;
        }
    }
    return list.items;
}

fn isBlankChange(ch: Change, a: *const File, b: *const File) bool {
    for (a.lines[ch.a0..ch.a1]) |l| if (mem.trim(u8, l, " \t\r").len != 0) return false;
    for (b.lines[ch.b0..ch.b1]) |l| if (mem.trim(u8, l, " \t\r").len != 0) return false;
    return true;
}

fn writeLine(w: *std.Io.Writer, prefix: []const u8, f: *const File, idx: usize) !void {
    try w.writeAll(prefix);
    try w.writeAll(f.lines[idx]);
    try w.writeByte('\n');
    if (idx + 1 == f.lines.len and !f.last_nl) try w.writeAll("\\ No newline at end of file\n");
}

fn rangeNormal(w: *std.Io.Writer, lo: usize, hi: usize) !void {
    // lo..hi 1-based inclusive
    if (hi <= lo) try w.print("{d}", .{lo}) else try w.print("{d},{d}", .{ lo, hi });
}

fn printNormal(w: *std.Io.Writer, changes: []const Change, a: *const File, b: *const File) !void {
    for (changes) |ch| {
        const kind: u8 = if (ch.a0 == ch.a1) 'a' else if (ch.b0 == ch.b1) 'd' else 'c';
        if (kind == 'a') try w.print("{d}", .{ch.a0}) else try rangeNormal(w, ch.a0 + 1, ch.a1);
        try w.writeByte(kind);
        if (kind == 'd') try w.print("{d}", .{ch.b0}) else try rangeNormal(w, ch.b0 + 1, ch.b1);
        try w.writeByte('\n');
        var i = ch.a0;
        while (i < ch.a1) : (i += 1) try writeLine(w, "< ", a, i);
        if (kind == 'c') try w.writeAll("---\n");
        var j = ch.b0;
        while (j < ch.b1) : (j += 1) try writeLine(w, "> ", b, j);
    }
}

fn header(w: *std.Io.Writer, mark: []const u8, f: *const File, label: ?[]const u8) !void {
    if (label) |l| {
        try w.print("{s} {s}\n", .{ mark, l });
        return;
    }
    try w.print("{s} {s}\t", .{ mark, f.name });
    const tf = if (format == .context) "%a %b %e %H:%M:%S %Y" else "%Y-%m-%d %H:%M:%S.%N %z";
    try c.strftime(w, tf, c.localtime(f.mtime.sec), f.mtime.nsec, f.mtime.sec);
    try w.writeByte('\n');
}

fn groupHunks(changes: []const Change) [][]const Change {
    var hunks: std.ArrayList([]const Change) = .empty;
    var start: usize = 0;
    var i: usize = 1;
    while (i <= changes.len) : (i += 1) {
        if (i == changes.len or changes[i].a0 - changes[i - 1].a1 > 2 * context) {
            hunks.append(c.gpa, changes[start..i]) catch c.oom();
            start = i;
        }
    }
    return hunks.items;
}

fn printUnified(w: *std.Io.Writer, changes: []const Change, a: *const File, b: *const File) !void {
    try header(w, "---", a, labels[0]);
    try header(w, "+++", b, labels[1]);
    for (groupHunks(changes)) |h| {
        const first = h[0];
        const last = h[h.len - 1];
        const a_start = first.a0 -| context;
        const a_end = @min(a.lines.len, last.a1 + context);
        const b_start = first.b0 -| context;
        const b_end = @min(b.lines.len, last.b1 + context);
        try w.writeAll("@@ -");
        try uniRange(w, a_start, a_end);
        try w.writeAll(" +");
        try uniRange(w, b_start, b_end);
        try w.writeAll(" @@\n");
        var ai = a_start;
        for (h) |ch| {
            while (ai < ch.a0) : (ai += 1) try writeLine(w, " ", a, ai);
            var i = ch.a0;
            while (i < ch.a1) : (i += 1) try writeLine(w, "-", a, i);
            var j = ch.b0;
            while (j < ch.b1) : (j += 1) try writeLine(w, "+", b, j);
            ai = ch.a1;
        }
        while (ai < a_end) : (ai += 1) try writeLine(w, " ", a, ai);
    }
}

fn uniRange(w: *std.Io.Writer, s: usize, e: usize) !void {
    const count = e - s;
    if (count == 1) {
        try w.print("{d}", .{s + 1});
    } else if (count == 0) {
        try w.print("{d},0", .{s});
    } else try w.print("{d},{d}", .{ s + 1, count });
}

fn ctxRange(w: *std.Io.Writer, s: usize, e: usize) !void {
    if (e == s) {
        try w.print("{d}", .{s});
    } else if (e - s == 1) {
        try w.print("{d}", .{e});
    } else try w.print("{d},{d}", .{ s + 1, e });
}

fn printContext(w: *std.Io.Writer, changes: []const Change, a: *const File, b: *const File) !void {
    try header(w, "***", a, labels[0]);
    try header(w, "---", b, labels[1]);
    for (groupHunks(changes)) |h| {
        const first = h[0];
        const last = h[h.len - 1];
        const a_start = first.a0 -| context;
        const a_end = @min(a.lines.len, last.a1 + context);
        const b_start = first.b0 -| context;
        const b_end = @min(b.lines.len, last.b1 + context);
        try w.writeAll("***************\n*** ");
        try ctxRange(w, a_start, a_end);
        try w.writeAll(" ****\n");
        var any_a = false;
        var any_b = false;
        for (h) |ch| {
            if (ch.a1 > ch.a0) any_a = true;
            if (ch.b1 > ch.b0) any_b = true;
        }
        if (any_a) {
            var ai = a_start;
            for (h) |ch| {
                while (ai < ch.a0) : (ai += 1) try writeLine(w, "  ", a, ai);
                const mark = if (ch.b1 > ch.b0) "! " else "- ";
                var i = ch.a0;
                while (i < ch.a1) : (i += 1) try writeLine(w, mark, a, i);
                ai = ch.a1;
            }
            while (ai < a_end) : (ai += 1) try writeLine(w, "  ", a, ai);
        }
        try w.writeAll("--- ");
        try ctxRange(w, b_start, b_end);
        try w.writeAll(" ----\n");
        if (any_b) {
            var bi = b_start;
            for (h) |ch| {
                while (bi < ch.b0) : (bi += 1) try writeLine(w, "  ", b, bi);
                const mark = if (ch.a1 > ch.a0) "! " else "+ ";
                var j = ch.b0;
                while (j < ch.b1) : (j += 1) try writeLine(w, mark, b, j);
                bi = ch.b1;
            }
            while (bi < b_end) : (bi += 1) try writeLine(w, "  ", b, bi);
        }
    }
}

fn isBinary(d: []const u8) bool {
    return mem.indexOfScalar(u8, d[0..@min(d.len, 8192)], 0) != null;
}

fn diffFiles(n1: []const u8, n2: []const u8, show_cmd: bool) !void {
    const w = c.out;
    var fa = (if (new_file and !c.eql(n1, "-") and (c.sys.stat(n1) catch null) == null) File{ .name = n1, .data = "", .lines = &.{}, .last_nl = true, .mtime = .{} } else loadFile(n1)) orelse {
        status = 2;
        return;
    };
    var fb = (if (new_file and !c.eql(n2, "-") and (c.sys.stat(n2) catch null) == null) File{ .name = n2, .data = "", .lines = &.{}, .last_nl = true, .mtime = .{} } else loadFile(n2)) orelse {
        status = 2;
        return;
    };
    if (mem.eql(u8, fa.data, fb.data)) {
        if (report_same) try w.print("Files {s} and {s} are identical\n", .{ n1, n2 });
        return;
    }
    if (!text and (isBinary(fa.data) or isBinary(fb.data))) {
        if (show_cmd and !brief) try w.print("diff {s}{s} {s}\n", .{ opt_string, n1, n2 });
        try w.print("Binary files {s} and {s} differ\n", .{ n1, n2 });
        status = @max(status, 1);
        return;
    }
    // intern lines
    var map = std.StringHashMap(u32).init(c.gpa);
    defer map.deinit();
    var kb: std.ArrayList(u8) = .empty;
    const ia = try c.gpa.alloc(u32, fa.lines.len);
    const ib = try c.gpa.alloc(u32, fb.lines.len);
    for (fa.lines, 0..) |l, k| {
        const key = try c.gpa.dupe(u8, keyOf(&kb, l));
        const r = try map.getOrPut(key);
        if (!r.found_existing) r.value_ptr.* = @intCast(map.count() - 1);
        ia[k] = r.value_ptr.*;
    }
    for (fb.lines, 0..) |l, k| {
        const key = try c.gpa.dupe(u8, keyOf(&kb, l));
        const r = try map.getOrPut(key);
        if (!r.found_existing) r.value_ptr.* = @intCast(map.count() - 1);
        ib[k] = r.value_ptr.*;
    }
    // Treat a missing final newline as a difference of the last line
    if (fa.lines.len > 0 and fb.lines.len > 0 and fa.last_nl != fb.last_nl) {
        const extra: u32 = @intCast(map.count() + 1);
        if (!fa.last_nl) ia[ia.len - 1] = extra else ib[ib.len - 1] = extra + 1;
    }
    const del = try c.gpa.alloc(bool, ia.len);
    const ins = try c.gpa.alloc(bool, ib.len);
    @memset(del, false);
    @memset(ins, false);
    computeDiff(ia, ib, del, ins);
    var changes = buildChanges(del, ins);
    if (ign_blank) {
        var kept: std.ArrayList(Change) = .empty;
        for (changes) |ch| if (!isBlankChange(ch, &fa, &fb)) try kept.append(c.gpa, ch);
        changes = kept.items;
    }
    if (changes.len == 0) {
        if (report_same) try w.print("Files {s} and {s} are identical\n", .{ n1, n2 });
        return;
    }
    status = @max(status, 1);
    if (brief) {
        try w.print("Files {s} and {s} differ\n", .{ n1, n2 });
        return;
    }
    if (show_cmd) try w.print("diff {s}{s} {s}\n", .{ opt_string, n1, n2 });
    switch (format) {
        .normal => try printNormal(w, changes, &fa, &fb),
        .unified => try printUnified(w, changes, &fa, &fb),
        .context => try printContext(w, changes, &fa, &fb),
    }
    fa = fa;
    fb = fb;
}

fn diffDirs(d1: []const u8, d2: []const u8) !void {
    const w = c.out;
    const n1 = c.readDirNames(d1) catch |e| {
        c.warn("{s}: {s}", .{ d1, c.strerror(e) });
        status = 2;
        return;
    };
    const n2 = c.readDirNames(d2) catch |e| {
        c.warn("{s}: {s}", .{ d2, c.strerror(e) });
        status = 2;
        return;
    };
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(c.gpa, n1);
    for (n2) |x| {
        var dup = false;
        for (n1) |y| if (c.eql(x, y)) {
            dup = true;
        };
        if (!dup) try all.append(c.gpa, x);
    }
    c.sortStrings(all.items);
    for (all.items) |name| {
        const p1 = c.join(d1, name);
        const p2 = c.join(d2, name);
        const s1: ?c.Stat = c.sys.stat(p1) catch null;
        const s2: ?c.Stat = c.sys.stat(p2) catch null;
        if (s1 == null or s2 == null) {
            if (new_file) {
                if ((s1 != null and s1.?.isDir()) or (s2 != null and s2.?.isDir())) {
                    if (recursive) {
                        // treat missing dir as empty
                        try w.print("Only in {s}: {s}\n", .{ if (s1 == null) d2 else d1, name });
                        status = @max(status, 1);
                    }
                    continue;
                }
                try diffFiles(p1, p2, true);
                continue;
            }
            try w.print("Only in {s}: {s}\n", .{ if (s1 == null) d2 else d1, name });
            status = @max(status, 1);
            continue;
        }
        const dir1 = s1.?.isDir();
        const dir2 = s2.?.isDir();
        if (dir1 and dir2) {
            if (recursive) try diffDirs(p1, p2) else try w.print("Common subdirectories: {s} and {s}\n", .{ p1, p2 });
        } else if (dir1 != dir2) {
            try w.print("File {s} is a {s} while file {s} is a {s}\n", .{ p1, if (dir1) "directory" else "regular file", p2, if (dir2) "directory" else "regular file" });
            status = @max(status, 1);
        } else try diffFiles(p1, p2, true);
    }
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    var files: std.ArrayList([]const u8) = .empty;
    var opts: std.ArrayList(u8) = .empty;
    var nlabels: usize = 0;
    var p = c.Parser.init(args, &.{
        .{ "normal", 0 },        .{ "brief", 'q' },            .{ "report-identical-files", 's' }, .{ "context", 0 },
        .{ "unified", 0 },       .{ "recursive", 'r' },        .{ "new-file", 'N' },    .{ "ignore-case", 'i' },
        .{ "ignore-space-change", 'b' }, .{ "ignore-all-space", 'w' }, .{ "ignore-blank-lines", 'B' }, .{ "text", 'a' },
        .{ "label", 0 },         .{ "color", 0 },              .{ "strip-trailing-cr", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| {
            switch (ch) {
                'q' => brief = true,
                's' => report_same = true,
                'c' => format = .context,
                'C' => {
                    format = .context;
                    context = @intCast(c.parseUint(p.arg()) orelse c.usageErr("invalid context length", .{}));
                },
                'u' => format = .unified,
                'U' => {
                    format = .unified;
                    context = @intCast(c.parseUint(p.arg()) orelse c.usageErr("invalid context length", .{}));
                },
                'r' => recursive = true,
                'N' => new_file = true,
                'i' => icase = true,
                'b' => ign_space_change = true,
                'w' => ign_all_space = true,
                'B' => ign_blank = true,
                'a' => text = true,
                'L' => {
                    if (nlabels < 2) labels[nlabels] = p.arg() else _ = p.arg();
                    nlabels += 1;
                    continue;
                },
                'd', 'H', 't', 'T', 'p' => {},
                else => p.bad(o),
            }
            if (std.ascii.isAlphabetic(ch)) {
                try opts.append(c.gpa, '-');
                try opts.append(c.gpa, ch);
                if (ch == 'U' or ch == 'C') try opts.print(c.gpa, " {d}", .{context});
                try opts.append(c.gpa, ' ');
            }
        },
        .long => |n| {
            if (c.eql(n, "normal")) format = .normal else if (c.eql(n, "context")) {
                format = .context;
                if (p.optArg()) |v| context = @intCast(c.parseUint(v) orelse c.usageErr("invalid context length", .{}));
            } else if (c.eql(n, "unified")) {
                format = .unified;
                if (p.optArg()) |v| context = @intCast(c.parseUint(v) orelse c.usageErr("invalid context length", .{}));
            } else if (c.eql(n, "label")) {
                if (nlabels < 2) labels[nlabels] = p.arg() else _ = p.arg();
                nlabels += 1;
            } else if (c.eql(n, "color")) {
                _ = p.optArg();
            } else if (c.eql(n, "strip-trailing-cr")) {} else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    // reproduce the original option words for "diff OPTIONS a b" headers
    opts.clearRetainingCapacity();
    for (args[1..]) |a| {
        var is_operand = false;
        for (files.items) |f| if (f.ptr == a.ptr) {
            is_operand = true;
        };
        if (is_operand) continue;
        try opts.appendSlice(c.gpa, a);
        try opts.append(c.gpa, ' ');
    }
    opt_string = opts.items;
    if (files.items.len < 2) {
        if (files.items.len == 0) c.usageErr("missing operand after 'diff'", .{});
        c.usageErr("missing operand after {f}", .{c.q(files.items[0])});
    }
    if (files.items.len > 2) c.usageErr("extra operand {f}", .{c.q(files.items[2])});
    var f1 = files.items[0];
    var f2 = files.items[1];
    const s1: ?c.Stat = if (c.eql(f1, "-")) null else c.sys.stat(f1) catch |e| blk: {
        if (!new_file) {
            c.warn("{s}: {s}", .{ f1, c.strerror(e) });
            return 2;
        }
        break :blk null;
    };
    const s2: ?c.Stat = if (c.eql(f2, "-")) null else c.sys.stat(f2) catch |e| blk: {
        if (!new_file) {
            c.warn("{s}: {s}", .{ f2, c.strerror(e) });
            return 2;
        }
        break :blk null;
    };
    const d1 = s1 != null and s1.?.isDir();
    const d2 = s2 != null and s2.?.isDir();
    if (d1 and d2) {
        try diffDirs(f1, f2);
    } else {
        if (d1) f1 = c.join(f1, c.basename(f2));
        if (d2) f2 = c.join(f2, c.basename(f1));
        try diffFiles(f1, f2, false);
    }
    return status;
}
