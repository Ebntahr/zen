const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: realpath [OPTION]... FILE...
    \\Print the resolved absolute file name;
    \\all but the last component must exist
    \\
    \\  -e, --canonicalize-existing  all components of the path must exist
    \\  -m, --canonicalize-missing   no path components need exist or be a directory
    \\  -L, --logical                resolve '..' components before symlinks
    \\  -P, --physical               resolve symlinks as encountered (default)
    \\  -q, --quiet                  suppress most error messages
    \\  -s, --strip, --no-symlinks   don't expand symlinks
    \\      --relative-to=DIR        print the resolved path relative to DIR
    \\      --relative-base=DIR      print absolute paths unless paths below DIR
    \\  -z, --zero                   end each output line with NUL, not newline
    \\
;

fn relative(path: []const u8, base: []const u8) []const u8 {
    var ti = mem.tokenizeScalar(u8, path, '/');
    var bi = mem.tokenizeScalar(u8, base, '/');
    var tc: std.ArrayList([]const u8) = .empty;
    var bc: std.ArrayList([]const u8) = .empty;
    while (ti.next()) |x| tc.append(c.gpa, x) catch c.oom();
    while (bi.next()) |x| bc.append(c.gpa, x) catch c.oom();
    var k: usize = 0;
    while (k < tc.items.len and k < bc.items.len and c.eql(tc.items[k], bc.items[k])) k += 1;
    var out: std.ArrayList(u8) = .empty;
    var i = k;
    while (i < bc.items.len) : (i += 1) {
        if (out.items.len > 0) out.append(c.gpa, '/') catch c.oom();
        out.appendSlice(c.gpa, "..") catch c.oom();
    }
    for (tc.items[k..]) |comp| {
        if (out.items.len > 0) out.append(c.gpa, '/') catch c.oom();
        out.appendSlice(c.gpa, comp) catch c.oom();
    }
    if (out.items.len == 0) return ".";
    return out.items;
}

pub fn main(args: c.Args) !u8 {
    var mode: c.CanonMode = .last_may_miss;
    var quiet = false;
    var strip = false;
    var eol: u8 = '\n';
    var rel_to: ?[]const u8 = null;
    var rel_base: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "canonicalize-existing", 'e' }, .{ "canonicalize-missing", 'm' }, .{ "logical", 'L' }, .{ "physical", 'P' },
        .{ "quiet", 'q' }, .{ "strip", 's' }, .{ "no-symlinks", 's' }, .{ "relative-to", 0 }, .{ "relative-base", 0 }, .{ "zero", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'e' => mode = .all_exist,
            'm' => mode = .none_exist,
            'L', 'P' => {},
            'q' => quiet = true,
            's' => strip = true,
            'z' => eol = 0,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "relative-to")) rel_to = p.arg() else if (c.eql(n, "relative-base")) rel_base = p.arg() else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len == 0) c.missingOperand();
    const rt = if (rel_to) |r| c.canonicalize(r, mode, !strip) catch |e| c.fatal("{s}: {s}", .{ r, c.strerror(e) }) else null;
    const rb = if (rel_base) |r| c.canonicalize(r, mode, !strip) catch |e| c.fatal("{s}: {s}", .{ r, c.strerror(e) }) else null;
    var status: u8 = 0;
    for (files.items) |f| {
        const r = c.canonicalize(f, mode, !strip) catch |e| {
            if (!quiet) c.warn("{s}: {s}", .{ f, c.strerror(e) });
            status = 1;
            continue;
        };
        var shown: []const u8 = r;
        if (rt) |base| {
            if (rb == null or (mem.startsWith(u8, r, rb.?) and mem.startsWith(u8, base, rb.?))) shown = relative(r, base);
        } else if (rb) |base| {
            if (c.eql(r, base) or (mem.startsWith(u8, r, base) and (base.len == 1 or r[base.len] == '/'))) shown = relative(r, base);
        }
        try c.out.writeAll(shown);
        try c.out.writeByte(eol);
    }
    return status;
}
