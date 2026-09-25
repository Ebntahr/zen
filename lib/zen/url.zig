//! URL helpers: `scheme:path?query`.

const std = @import("std");

pub const Url = struct {
    /// Empty for plain POSIX paths.
    scheme: []const u8,
    path: []const u8,
    query: []const u8,
};

/// A string is a URL when it has a scheme name (letters, digits, `-`, `_`,
/// `.`) followed by ':' before any '/'.
pub fn isUrl(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    for (s[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

pub fn parse(s: []const u8) Url {
    var scheme: []const u8 = "";
    var rest = s;
    if (isUrl(s)) {
        const colon = std.mem.indexOfScalar(u8, s, ':').?;
        scheme = s[0..colon];
        rest = s[colon + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        return .{ .scheme = scheme, .path = rest[0..q], .query = rest[q + 1 ..] };
    }
    return .{ .scheme = scheme, .path = rest, .query = "" };
}

/// Look up `key` in an `a=1&b=2` query string (raw, not decoded).
pub fn queryGet(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (std.mem.eql(u8, pair, key)) return "";
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn queryInt(comptime T: type, query: []const u8, key: []const u8, default: T) T {
    const v = queryGet(query, key) orelse return default;
    return std.fmt.parseInt(T, v, 10) catch default;
}

/// Percent-decode into `out`; returns the decoded slice.
pub fn decode(s: []const u8, out: []u8) []u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len and o < out.len) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                out[o] = s[i];
                o += 1;
                i += 1;
                continue;
            };
            out[o] = v;
            i += 3;
        } else {
            out[o] = if (s[i] == '+') ' ' else s[i];
            i += 1;
        }
        o += 1;
    }
    return out[0..o];
}

/// Percent-encode everything except unreserved characters.
pub fn encode(s: []const u8, out: []u8) []u8 {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/';
        if (unreserved) {
            if (o + 1 > out.len) break;
            out[o] = c;
            o += 1;
        } else {
            if (o + 3 > out.len) break;
            out[o] = '%';
            out[o + 1] = hex[c >> 4];
            out[o + 2] = hex[c & 15];
            o += 3;
        }
    }
    return out[0..o];
}

/// Normalize an absolute path: collapse `//`, remove `.`, resolve `..`.
pub fn normalize(path: []const u8, out: []u8) []u8 {
    var o: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            while (o > 0 and out[o - 1] != '/') o -= 1;
            if (o > 0) o -= 1;
            continue;
        }
        if (o + 1 + comp.len > out.len) break;
        out[o] = '/';
        @memcpy(out[o + 1 .. o + 1 + comp.len], comp);
        o += 1 + comp.len;
    }
    if (o == 0) {
        out[0] = '/';
        o = 1;
    }
    return out[0..o];
}

test "parse urls" {
    const u = parse("window:new?w=10&h=20");
    try std.testing.expectEqualStrings("window", u.scheme);
    try std.testing.expectEqualStrings("new", u.path);
    try std.testing.expectEqual(@as(i32, 10), queryInt(i32, u.query, "w", 0));
    try std.testing.expectEqual(@as(i32, 20), queryInt(i32, u.query, "h", 0));
    try std.testing.expect(!isUrl("/etc/passwd"));
    try std.testing.expect(!isUrl("a/b:c"));
    try std.testing.expect(isUrl("sys:proc"));
}

test "percent coding" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello World!", decode("Hello%20World%21", &buf));
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a%20b", encode("a b", &buf2));
}

test "normalize" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/a/c", normalize("/a/b/../c/./", &buf));
    try std.testing.expectEqualStrings("/", normalize("/..", &buf));
    try std.testing.expectEqualStrings("/x", normalize("//x", &buf));
}
