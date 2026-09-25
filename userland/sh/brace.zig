//! Brace expansion (bash/zsh style): `a{b,c}d`, nested braces and
//! sequences `{1..5}`, `{a..e}`, `{0..10..2}`. It is applied to command words
//! before any other expansion; only unquoted braces are active.
const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

const Item = union(enum) {
    char: u8,
    part: ast.Part,
};

/// Quick test: does the word contain an unquoted '{'?
pub fn mayExpand(w: ast.Word) bool {
    for (w.parts) |p| switch (p) {
        .lit => |s| if (std.mem.indexOfScalar(u8, s, '{') != null) return true,
        else => {},
    };
    return false;
}

fn flatten(a: Allocator, w: ast.Word) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    for (w.parts) |p| switch (p) {
        .lit => |s| for (s) |c| try items.append(a, .{ .char = c }),
        else => try items.append(a, .{ .part = p }),
    };
    return items.items;
}

fn isChar(it: Item, c: u8) bool {
    return switch (it) {
        .char => |x| x == c,
        else => false,
    };
}

fn toWord(a: Allocator, items: []const Item) !ast.Word {
    var parts: std.ArrayList(ast.Part) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    for (items) |it| switch (it) {
        .char => |c| try lit.append(a, c),
        .part => |p| {
            if (lit.items.len > 0) {
                try parts.append(a, .{ .lit = lit.items });
                lit = .empty;
            }
            try parts.append(a, p);
        },
    };
    if (lit.items.len > 0) try parts.append(a, .{ .lit = lit.items });
    return .{ .parts = parts.items };
}

/// Find a brace group starting at or after `from`: returns open/close
/// indices and whether it is a list (has a top-level comma) or sequence.
fn findGroup(items: []const Item, from: usize) ?struct { open: usize, close: usize } {
    var i = from;
    while (i < items.len) : (i += 1) {
        if (!isChar(items[i], '{')) continue;
        var depth: usize = 0;
        var comma = false;
        var j = i;
        while (j < items.len) : (j += 1) {
            if (isChar(items[j], '{')) depth += 1;
            if (isChar(items[j], '}')) {
                depth -= 1;
                if (depth == 0) break;
            }
            if (depth == 1 and isChar(items[j], ',')) comma = true;
        }
        if (j >= items.len) return null;
        if (comma or seqBounds(items[i + 1 .. j]) != null) return .{ .open = i, .close = j };
    }
    return null;
}

const Seq = struct { start: i64, end: i64, step: i64, alpha: bool, width: usize };

fn seqBounds(items: []const Item) ?Seq {
    var buf: [64]u8 = undefined;
    if (items.len >= buf.len) return null;
    for (items, 0..) |it, k| switch (it) {
        .char => |c| buf[k] = c,
        else => return null,
    };
    const s = buf[0..items.len];
    const d1 = std.mem.indexOf(u8, s, "..") orelse return null;
    const a = s[0..d1];
    var rest = s[d1 + 2 ..];
    var step_s: ?[]const u8 = null;
    if (std.mem.indexOf(u8, rest, "..")) |d2| {
        step_s = rest[d2 + 2 ..];
        rest = rest[0..d2];
    }
    const b = rest;
    var step: i64 = 1;
    if (step_s) |ss| step = std.fmt.parseInt(i64, ss, 10) catch return null;
    if (step == 0) step = 1;
    if (step < 0) step = -step;
    if (a.len == 1 and b.len == 1 and std.ascii.isAlphabetic(a[0]) and std.ascii.isAlphabetic(b[0])) {
        return .{ .start = a[0], .end = b[0], .step = step, .alpha = true, .width = 0 };
    }
    const x = std.fmt.parseInt(i64, a, 10) catch return null;
    const y = std.fmt.parseInt(i64, b, 10) catch return null;
    var width: usize = 0;
    const za = a.len > 1 and (a[0] == '0' or (a[0] == '-' and a[1] == '0'));
    const zb = b.len > 1 and (b[0] == '0' or (b[0] == '-' and b[1] == '0'));
    if (za or zb) width = @max(a.len, b.len);
    return .{ .start = x, .end = y, .step = step, .alpha = false, .width = width };
}

fn expandItems(a: Allocator, items: []const Item, out: *std.ArrayList([]const Item), depth: u32) !void {
    if (depth > 64 or out.items.len > 100_000) {
        try out.append(a, items);
        return;
    }
    const g = findGroup(items, 0) orelse {
        try out.append(a, items);
        return;
    };
    const prefix = items[0..g.open];
    const suffix = items[g.close + 1 ..];
    const inner = items[g.open + 1 .. g.close];
    var alts: std.ArrayList([]const Item) = .empty;
    if (seqBounds(inner)) |sq| {
        var v = sq.start;
        const up = sq.end >= sq.start;
        var count: usize = 0;
        while ((up and v <= sq.end) or (!up and v >= sq.end)) : (v = if (up) v + sq.step else v - sq.step) {
            count += 1;
            if (count > 100_000) break;
            var nb: [32]u8 = undefined;
            var txt: []const u8 = undefined;
            if (sq.alpha) {
                nb[0] = @intCast(v);
                txt = nb[0..1];
            } else if (sq.width > 0) {
                const neg = v < 0;
                const mag: u64 = @intCast(if (neg) -v else v);
                const digits = std.fmt.bufPrint(nb[1..], "{d}", .{mag}) catch unreachable;
                var t: std.ArrayList(u8) = .empty;
                if (neg) try t.append(a, '-');
                const w = if (neg) sq.width - 1 else sq.width;
                if (digits.len < w) try t.appendNTimes(a, '0', w - digits.len);
                try t.appendSlice(a, digits);
                txt = t.items;
            } else {
                txt = std.fmt.bufPrint(&nb, "{d}", .{v}) catch unreachable;
            }
            const alt = try a.alloc(Item, txt.len);
            for (txt, 0..) |c, k| alt[k] = .{ .char = c };
            try alts.append(a, alt);
        }
    } else {
        var start: usize = 0;
        var d: usize = 0;
        for (inner, 0..) |it, k| {
            if (isChar(it, '{')) d += 1;
            if (isChar(it, '}')) d -= 1;
            if (d == 0 and isChar(it, ',')) {
                try alts.append(a, inner[start..k]);
                start = k + 1;
            }
        }
        try alts.append(a, inner[start..]);
    }
    for (alts.items) |alt| {
        const combined = try std.mem.concat(a, Item, &.{ prefix, alt, suffix });
        try expandItems(a, combined, out, depth + 1);
    }
}

/// Expand braces in `w`; returns the resulting words (at least one).
pub fn expand(a: Allocator, w: ast.Word) ![]ast.Word {
    const items = try flatten(a, w);
    var outs: std.ArrayList([]const Item) = .empty;
    try expandItems(a, items, &outs, 0);
    const words = try a.alloc(ast.Word, outs.items.len);
    for (outs.items, 0..) |o, i| words[i] = try toWord(a, o);
    return words;
}
