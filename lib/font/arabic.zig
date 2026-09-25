//! Arabic shaping and simplified bidirectional reordering.
//!
//! Letters are replaced by their contextual presentation forms (isolated,
//! final, initial, medial; Unicode block Arabic Presentation Forms-B), lam
//! + alef become ligatures, and right-to-left runs are reordered into
//! visual order so a left-to-right glyph renderer draws them correctly.
//! Fonts such as Noto Sans Arabic map every Presentation Forms-B code point,
//! so no GSUB processing is needed for Arabic script.

const std = @import("std");
const utf8 = @import("utf8.zig");

const Joining = enum { none, right, dual, causing, transparent };

/// Presentation forms: isolated, final, initial, medial (0 = unavailable).
const Forms = [4]u21;

fn formsOf(cp: u21) ?Forms {
    return switch (cp) {
        0x0621 => .{ 0xFE80, 0, 0, 0 },
        0x0622 => .{ 0xFE81, 0xFE82, 0, 0 },
        0x0623 => .{ 0xFE83, 0xFE84, 0, 0 },
        0x0624 => .{ 0xFE85, 0xFE86, 0, 0 },
        0x0625 => .{ 0xFE87, 0xFE88, 0, 0 },
        0x0626 => .{ 0xFE89, 0xFE8A, 0xFE8B, 0xFE8C },
        0x0627 => .{ 0xFE8D, 0xFE8E, 0, 0 },
        0x0628 => .{ 0xFE8F, 0xFE90, 0xFE91, 0xFE92 },
        0x0629 => .{ 0xFE93, 0xFE94, 0, 0 },
        0x062A => .{ 0xFE95, 0xFE96, 0xFE97, 0xFE98 },
        0x062B => .{ 0xFE99, 0xFE9A, 0xFE9B, 0xFE9C },
        0x062C => .{ 0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0 },
        0x062D => .{ 0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4 },
        0x062E => .{ 0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8 },
        0x062F => .{ 0xFEA9, 0xFEAA, 0, 0 },
        0x0630 => .{ 0xFEAB, 0xFEAC, 0, 0 },
        0x0631 => .{ 0xFEAD, 0xFEAE, 0, 0 },
        0x0632 => .{ 0xFEAF, 0xFEB0, 0, 0 },
        0x0633 => .{ 0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4 },
        0x0634 => .{ 0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8 },
        0x0635 => .{ 0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC },
        0x0636 => .{ 0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0 },
        0x0637 => .{ 0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4 },
        0x0638 => .{ 0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8 },
        0x0639 => .{ 0xFEC9, 0xFECA, 0xFECB, 0xFECC },
        0x063A => .{ 0xFECD, 0xFECE, 0xFECF, 0xFED0 },
        0x0641 => .{ 0xFED1, 0xFED2, 0xFED3, 0xFED4 },
        0x0642 => .{ 0xFED5, 0xFED6, 0xFED7, 0xFED8 },
        0x0643 => .{ 0xFED9, 0xFEDA, 0xFEDB, 0xFEDC },
        0x0644 => .{ 0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0 },
        0x0645 => .{ 0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4 },
        0x0646 => .{ 0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8 },
        0x0647 => .{ 0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC },
        0x0648 => .{ 0xFEED, 0xFEEE, 0, 0 },
        0x0649 => .{ 0xFEEF, 0xFEF0, 0, 0 },
        0x064A => .{ 0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4 },
        else => null,
    };
}

fn joining(cp: u21) Joining {
    if (cp == 0x0640) return .causing; // tatweel
    if ((cp >= 0x064B and cp <= 0x065F) or cp == 0x0670 or (cp >= 0x06D6 and cp <= 0x06ED)) return .transparent;
    const f = formsOf(cp) orelse return .none;
    if (f[2] != 0) return .dual;
    if (f[1] != 0) return .right;
    return .none;
}

fn joinsToNext(j: Joining) bool {
    return j == .dual or j == .causing;
}

fn joinsToPrev(j: Joining) bool {
    return j == .dual or j == .right or j == .causing;
}

fn lamAlef(alef: u21) ?[2]u21 {
    return switch (alef) {
        0x0622 => .{ 0xFEF5, 0xFEF6 },
        0x0623 => .{ 0xFEF7, 0xFEF8 },
        0x0625 => .{ 0xFEF9, 0xFEFA },
        0x0627 => .{ 0xFEFB, 0xFEFC },
        else => null,
    };
}

/// True for right-to-left strong characters.
pub fn isRtl(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x08FF) or (cp >= 0xFB1D and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF);
}

fn isStrongLtr(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphabetic(@intCast(cp));
    return !isRtl(cp) and cp >= 0xC0 and cp != 0x2026 and !(cp >= 0x2000 and cp <= 0x206F);
}

fn isDigit(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 0x0660 and cp <= 0x0669) or (cp >= 0x06F0 and cp <= 0x06F9);
}

/// Quick test: does the UTF-8 text contain Arabic/Hebrew characters?
pub fn needsShaping(text: []const u8) bool {
    for (text) |b| {
        // Lead bytes of U+0590..U+08FF are 0xD6..0xE0; the presentation
        // forms use 0xEF but are already shaped.
        if (b >= 0xD6 and b <= 0xDF) return true;
    }
    return false;
}

fn mirror(cp: u21) u21 {
    return switch (cp) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        '«' => '»',
        '»' => '«',
        else => cp,
    };
}

const MAX = 512;

/// Shape and reorder one line of `text` into `out`. Returns the visual-order
/// UTF-8 text, or `text` unchanged when it needs no processing or is too long.
pub fn shapeLine(text: []const u8, out: []u8) []const u8 {
    if (!needsShaping(text)) return text;
    var cps: [MAX]u21 = undefined;
    var n: usize = 0;
    var it = utf8.Iterator.init(text);
    while (it.next()) |cp| {
        if (n == MAX or cp == '\n') return text;
        cps[n] = cp;
        n += 1;
    }

    // 1. Contextual forms (logical order).
    var shaped: [MAX]u21 = undefined;
    var m: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp = cps[i];
        const j = joining(cp);
        if (j == .none or j == .transparent or j == .causing) {
            shaped[m] = cp;
            m += 1;
            continue;
        }
        // Previous and next non-transparent characters.
        var p: ?u21 = null;
        var k = i;
        while (k > 0) {
            k -= 1;
            if (joining(cps[k]) != .transparent) {
                p = cps[k];
                break;
            }
        }
        var nx: ?usize = null;
        k = i + 1;
        while (k < n) : (k += 1) {
            if (joining(cps[k]) != .transparent) {
                nx = k;
                break;
            }
        }
        const join_prev = if (p) |pc| joinsToNext(joining(pc)) and joinsToPrev(j) else false;
        // Lam-alef ligature.
        if (cp == 0x0644 and nx != null) {
            if (lamAlef(cps[nx.?])) |lig| {
                shaped[m] = if (join_prev) lig[1] else lig[0];
                m += 1;
                // Keep marks between lam and alef, drop the alef.
                var t = i + 1;
                while (t < nx.?) : (t += 1) {
                    shaped[m] = cps[t];
                    m += 1;
                }
                i = nx.?;
                continue;
            }
        }
        const join_next = if (nx) |ni| joinsToNext(j) and joinsToPrev(joining(cps[ni])) else false;
        const f = formsOf(cp).?;
        const form: u21 = if (join_prev and join_next and f[3] != 0)
            f[3]
        else if (join_prev and f[1] != 0)
            f[1]
        else if (join_next and f[2] != 0)
            f[2]
        else
            f[0];
        shaped[m] = form;
        m += 1;
    }

    // 2. Bidi: determine paragraph direction from the first strong char.
    var rtl_para = false;
    for (shaped[0..m]) |cp| {
        if (isRtl(cp)) {
            rtl_para = true;
            break;
        }
        if (isStrongLtr(cp)) break;
    }
    // Classify characters into RTL (true) / LTR (false) levels. Neutrals
    // between two characters of the same direction take that direction,
    // otherwise the paragraph direction.
    var level: [MAX]bool = undefined;
    for (shaped[0..m], 0..) |cp, idx| {
        level[idx] = if (isRtl(cp)) true else if (isStrongLtr(cp) or isDigit(cp)) false else rtl_para;
    }
    var idx: usize = 0;
    while (idx < m) {
        const cp = shaped[idx];
        if (isRtl(cp) or isStrongLtr(cp) or isDigit(cp)) {
            idx += 1;
            continue;
        }
        // Neutral run [idx, e).
        var e = idx;
        while (e < m and !(isRtl(shaped[e]) or isStrongLtr(shaped[e]) or isDigit(shaped[e]))) e += 1;
        const before: ?bool = if (idx > 0) level[idx - 1] else null;
        const after: ?bool = if (e < m) level[e] else null;
        const lv = if (before != null and after != null and before.? == after.?) before.? else rtl_para;
        for (level[idx..e]) |*l| l.* = lv;
        idx = e;
    }

    // 3. Reorder runs into visual order.
    var visual: [MAX]u21 = undefined;
    var v: usize = 0;
    const Run = struct { start: usize, end: usize, rtl: bool };
    var runs: [MAX]Run = undefined;
    var nr: usize = 0;
    idx = 0;
    while (idx < m) {
        var e = idx + 1;
        while (e < m and level[e] == level[idx]) e += 1;
        runs[nr] = .{ .start = idx, .end = e, .rtl = level[idx] };
        nr += 1;
        idx = e;
    }
    var r: usize = 0;
    while (r < nr) : (r += 1) {
        const run = if (rtl_para) runs[nr - 1 - r] else runs[r];
        if (run.rtl) {
            var q = run.end;
            while (q > run.start) {
                q -= 1;
                visual[v] = mirror(shaped[q]);
                v += 1;
            }
        } else {
            for (shaped[run.start..run.end]) |cp| {
                visual[v] = cp;
                v += 1;
            }
        }
    }

    // 4. Encode.
    var o: usize = 0;
    for (visual[0..v]) |cp| {
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (o + len > out.len) return text;
        _ = std.unicode.utf8Encode(cp, out[o .. o + len]) catch continue;
        o += len;
    }
    return out[0..o];
}

fn decodeAll(s: []const u8, buf: []u21) []u21 {
    var n: usize = 0;
    var it = utf8.Iterator.init(s);
    while (it.next()) |cp| {
        buf[n] = cp;
        n += 1;
    }
    return buf[0..n];
}

test "latin text is untouched" {
    var buf: [64]u8 = undefined;
    const s = "Hello, world";
    try std.testing.expect(shapeLine(s, &buf).ptr == s.ptr);
}

test "contextual forms and rtl order" {
    var buf: [128]u8 = undefined;
    // "بيت" (beh yeh teh): initial beh, medial yeh, final teh, reversed.
    const out = shapeLine("بيت", &buf);
    var cps: [8]u21 = undefined;
    const v = decodeAll(out, &cps);
    try std.testing.expectEqualSlices(u21, &.{ 0xFE96, 0xFEF4, 0xFE91 }, v);
}

test "lam alef ligature" {
    var buf: [64]u8 = undefined;
    var cps: [8]u21 = undefined;
    // "لا" → isolated lam-alef.
    try std.testing.expectEqualSlices(u21, &.{0xFEFB}, decodeAll(shapeLine("لا", &buf), &cps));
    // "سلام": seen initial, lam-alef final, meem isolated → visual reversed.
    try std.testing.expectEqualSlices(u21, &.{ 0xFEE1, 0xFEFC, 0xFEB3 }, decodeAll(shapeLine("سلام", &buf), &cps));
}

test "mixed direction keeps latin runs in order" {
    var buf: [128]u8 = undefined;
    var cps: [32]u21 = undefined;
    // RTL paragraph: "نظام Zen" → visual "Zen" first then the Arabic reversed.
    const v = decodeAll(shapeLine("نظام Zen", &buf), &cps);
    try std.testing.expectEqual(@as(u21, 'Z'), v[0]);
    try std.testing.expectEqual(@as(u21, 'e'), v[1]);
    try std.testing.expectEqual(@as(u21, 'n'), v[2]);
    try std.testing.expectEqual(@as(u21, ' '), v[3]);
}
