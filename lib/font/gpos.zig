//! GPOS pair-adjustment kerning.
//!
//! Collects the lookups referenced by every `kern` feature (type 2 PairPos,
//! formats 1 and 2, including type 9 extension lookups that wrap them) and
//! answers "how much should the advance of `left` change when followed by
//! `right`". Lookups are applied in LookupList order and their results summed;
//! within one lookup the first subtable that matches wins, mirroring HarfBuzz.
//!
//! Only the X advance of the first glyph is used, which is how horizontal
//! kerning is expressed in practice. Device tables and mark skipping are
//! ignored. Malformed data never fails: it simply yields no kerning.

const std = @import("std");
const be = @import("be.zig");
const Allocator = std.mem.Allocator;

pub const Kerning = struct {
    /// The whole GPOS table; subtable offsets are relative to its start.
    table: []const u8 = &.{},
    /// Absolute offsets (into `table`) of PairPos subtables, grouped by lookup.
    subtables: []u32 = &.{},
    /// Exclusive end index into `subtables` for each lookup, in application order.
    lookup_ends: []u32 = &.{},

    /// Parses the kerning lookups of a GPOS table. Malformed tables yield an
    /// empty `Kerning`; only allocation failure is reported.
    pub fn init(allocator: Allocator, table: []const u8) Allocator.Error!Kerning {
        return parse(allocator, table) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidFont => .{},
        };
    }

    pub fn deinit(self: *Kerning, allocator: Allocator) void {
        allocator.free(self.subtables);
        allocator.free(self.lookup_ends);
        self.* = .{};
    }

    pub fn isEmpty(self: Kerning) bool {
        return self.lookup_ends.len == 0;
    }

    /// Kerning adjustment in font units for the glyph pair (left, right).
    pub fn get(self: Kerning, left: u16, right: u16) i32 {
        var total: i32 = 0;
        var start: usize = 0;
        for (self.lookup_ends) |end| {
            for (self.subtables[start..end]) |off| {
                if (pairValue(self.table, off, left, right)) |v| {
                    total += v;
                    break;
                }
            }
            start = end;
        }
        return total;
    }
};

const ParseError = error{ InvalidFont, OutOfMemory };

fn parse(allocator: Allocator, t: []const u8) ParseError!Kerning {
    const bad = error.InvalidFont;
    if ((be.u16At(t, 0) orelse return bad) != 1) return bad;
    const feature_list: usize = be.u16At(t, 6) orelse return bad;
    const lookup_list: usize = be.u16At(t, 8) orelse return bad;
    const lookup_count = be.u16At(t, lookup_list) orelse return bad;

    // Union of lookup indices referenced by all `kern` features.
    var wanted: std.ArrayList(u16) = .empty;
    defer wanted.deinit(allocator);
    const feature_count = be.u16At(t, feature_list) orelse return bad;
    for (0..feature_count) |i| {
        const rec = feature_list + 2 + i * 6;
        const tag = be.slice(t, rec, 4) orelse return bad;
        if (!std.mem.eql(u8, tag, "kern")) continue;
        const feature = feature_list + (be.u16At(t, rec + 4) orelse return bad);
        const count = be.u16At(t, feature + 2) orelse return bad;
        for (0..count) |j| {
            const index = be.u16At(t, feature + 4 + j * 2) orelse return bad;
            if (index < lookup_count) try wanted.append(allocator, index);
        }
    }
    std.mem.sortUnstable(u16, wanted.items, {}, std.sort.asc(u16));

    var subtables: std.ArrayList(u32) = .empty;
    errdefer subtables.deinit(allocator);
    var lookup_ends: std.ArrayList(u32) = .empty;
    errdefer lookup_ends.deinit(allocator);

    var prev: ?u16 = null;
    for (wanted.items) |index| {
        if (prev == index) continue; // deduplicate
        prev = index;
        const lookup = lookup_list + (be.u16At(t, lookup_list + 2 + @as(usize, index) * 2) orelse return bad);
        const kind = be.u16At(t, lookup) orelse return bad;
        const count = be.u16At(t, lookup + 4) orelse return bad;
        const before = subtables.items.len;
        for (0..count) |j| {
            var sub: usize = lookup + (be.u16At(t, lookup + 6 + j * 2) orelse return bad);
            switch (kind) {
                2 => {},
                9 => {
                    // ExtensionPosFormat1 { format, extensionLookupType, extensionOffset32 }
                    if (be.u16At(t, sub) != 1 or be.u16At(t, sub + 2) != 2) continue;
                    sub += be.u32At(t, sub + 4) orelse return bad;
                },
                else => break,
            }
            if (sub >= t.len) continue;
            try subtables.append(allocator, @intCast(sub));
        }
        if (subtables.items.len > before) try lookup_ends.append(allocator, @intCast(subtables.items.len));
    }

    return .{
        .table = t,
        .subtables = try subtables.toOwnedSlice(allocator),
        .lookup_ends = try lookup_ends.toOwnedSlice(allocator),
    };
}

/// Returns the X-advance adjustment if this PairPos subtable applies to the pair.
fn pairValue(t: []const u8, off: usize, left: u16, right: u16) ?i32 {
    const format = be.u16At(t, off) orelse return null;
    const coverage = off + (be.u16At(t, off + 2) orelse return null);
    const vf1 = be.u16At(t, off + 4) orelse return null;
    const vf2 = be.u16At(t, off + 6) orelse return null;
    const size1 = valueRecordSize(vf1);
    const size2 = valueRecordSize(vf2);
    const cov_index = coverageIndex(t, coverage, left) orelse return null;

    switch (format) {
        1 => {
            const set_count = be.u16At(t, off + 8) orelse return null;
            if (cov_index >= set_count) return null;
            const set = off + (be.u16At(t, off + 10 + @as(usize, cov_index) * 2) orelse return null);
            const record_size = 2 + size1 + size2;
            // PairValueRecords are sorted by second glyph: binary search.
            var lo: usize = 0;
            var hi: usize = be.u16At(t, set) orelse return null;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = set + 2 + mid * record_size;
                const second = be.u16At(t, rec) orelse return null;
                if (second == right) return xAdvance(t, vf1, rec + 2);
                if (second < right) lo = mid + 1 else hi = mid;
            }
            return null;
        },
        2 => {
            const class2 = classOf(t, off + (be.u16At(t, off + 10) orelse return null), right);
            // Like HarfBuzz, class 0 of the second glyph does not match, so a later
            // subtable of the same lookup may still apply.
            if (class2 == 0) return null;
            const class1 = classOf(t, off + (be.u16At(t, off + 8) orelse return null), left);
            const class1_count = be.u16At(t, off + 12) orelse return null;
            const class2_count = be.u16At(t, off + 14) orelse return null;
            if (class1 >= class1_count or class2 >= class2_count) return null;
            const index = @as(usize, class1) * class2_count + class2;
            return xAdvance(t, vf1, off + 16 + index * (size1 + size2));
        },
        else => return null,
    }
}

fn valueRecordSize(format: u16) usize {
    return 2 * @as(usize, @popCount(format & 0xFF));
}

fn xAdvance(t: []const u8, format: u16, rec: usize) ?i32 {
    if (format & 0x4 == 0) return 0;
    // XAdvance follows the optional XPlacement and YPlacement fields.
    const skip = 2 * @as(usize, @popCount(format & 0x3));
    return be.i16At(t, rec + skip) orelse null;
}

/// Index of `glyph` in a Coverage table, or null if not covered.
pub fn coverageIndex(t: []const u8, off: usize, glyph: u16) ?u16 {
    const format = be.u16At(t, off) orelse return null;
    const count = be.u16At(t, off + 2) orelse return null;
    var lo: usize = 0;
    var hi: usize = count;
    switch (format) {
        1 => while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const g = be.u16At(t, off + 4 + mid * 2) orelse return null;
            if (g == glyph) return @intCast(mid);
            if (g < glyph) lo = mid + 1 else hi = mid;
        },
        2 => while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = off + 4 + mid * 6;
            const start = be.u16At(t, rec) orelse return null;
            const end = be.u16At(t, rec + 2) orelse return null;
            if (glyph < start) {
                hi = mid;
            } else if (glyph > end) {
                lo = mid + 1;
            } else {
                const base = be.u16At(t, rec + 4) orelse return null;
                return std.math.add(u16, base, glyph - start) catch null;
            }
        },
        else => {},
    }
    return null;
}

/// Class of `glyph` in a ClassDef table (0 when unassigned or malformed).
pub fn classOf(t: []const u8, off: usize, glyph: u16) u16 {
    const format = be.u16At(t, off) orelse return 0;
    switch (format) {
        1 => {
            const start = be.u16At(t, off + 2) orelse return 0;
            const count = be.u16At(t, off + 4) orelse return 0;
            if (glyph < start or glyph - start >= count) return 0;
            return be.u16At(t, off + 6 + @as(usize, glyph - start) * 2) orelse 0;
        },
        2 => {
            var lo: usize = 0;
            var hi: usize = be.u16At(t, off + 2) orelse return 0;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = off + 4 + mid * 6;
                const start = be.u16At(t, rec) orelse return 0;
                const end = be.u16At(t, rec + 2) orelse return 0;
                if (glyph < start) {
                    hi = mid;
                } else if (glyph > end) {
                    lo = mid + 1;
                } else {
                    return be.u16At(t, rec + 4) orelse 0;
                }
            }
            return 0;
        },
        else => return 0,
    }
}

test "coverage and class definitions" {
    // Coverage format 1: glyphs 3, 7, 9.
    const cov1 = [_]u8{ 0, 1, 0, 3, 0, 3, 0, 7, 0, 9 };
    try std.testing.expectEqual(@as(?u16, 1), coverageIndex(&cov1, 0, 7));
    try std.testing.expectEqual(@as(?u16, null), coverageIndex(&cov1, 0, 8));
    // Coverage format 2: 10..20 -> 0.., 30..31 -> 11..
    const cov2 = [_]u8{ 0, 2, 0, 2, 0, 10, 0, 20, 0, 0, 0, 30, 0, 31, 0, 11 };
    try std.testing.expectEqual(@as(?u16, 5), coverageIndex(&cov2, 0, 15));
    try std.testing.expectEqual(@as(?u16, 12), coverageIndex(&cov2, 0, 31));
    try std.testing.expectEqual(@as(?u16, null), coverageIndex(&cov2, 0, 25));
    // ClassDef format 2: 5..6 -> class 4.
    const cd2 = [_]u8{ 0, 2, 0, 1, 0, 5, 0, 6, 0, 4 };
    try std.testing.expectEqual(@as(u16, 4), classOf(&cd2, 0, 6));
    try std.testing.expectEqual(@as(u16, 0), classOf(&cd2, 0, 7));
    // Truncated tables never read out of bounds.
    try std.testing.expectEqual(@as(?u16, null), coverageIndex(cov2[0..9], 0, 15));
    try std.testing.expectEqual(@as(u16, 0), classOf(cd2[0..7], 0, 6));
}

test "malformed GPOS yields no kerning" {
    var k = try Kerning.init(std.testing.allocator, &[_]u8{ 0, 1, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff });
    defer k.deinit(std.testing.allocator);
    try std.testing.expect(k.isEmpty());
    try std.testing.expectEqual(@as(i32, 0), k.get(1, 2));
}
