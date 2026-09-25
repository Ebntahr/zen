const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: readlink [OPTION]... FILE...
    \\Print value of a symbolic link or canonical file name
    \\
    \\  -f, --canonicalize            canonicalize by following every symlink in
    \\                                every component of the given name recursively;
    \\                                all but the last component must exist
    \\  -e, --canonicalize-existing   canonicalize by following every symlink in
    \\                                every component of the given name recursively,
    \\                                all components must exist
    \\  -m, --canonicalize-missing    canonicalize by following every symlink in
    \\                                every component of the given name recursively,
    \\                                without requirements on components existence
    \\  -n, --no-newline              do not output the trailing delimiter
    \\  -q, --quiet
    \\  -s, --silent                  suppress most error messages (on by default)
    \\  -v, --verbose                 report error messages
    \\  -z, --zero                    end each output line with NUL, not newline
    \\
;

pub fn main(args: c.Args) !u8 {
    var mode: ?c.CanonMode = null;
    var no_newline = false;
    var verbose = false;
    var eol: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "canonicalize", 'f' }, .{ "canonicalize-existing", 'e' }, .{ "canonicalize-missing", 'm' },
        .{ "no-newline", 'n' },   .{ "quiet", 'q' }, .{ "silent", 's' }, .{ "verbose", 'v' }, .{ "zero", 'z' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'f' => mode = .last_may_miss,
            'e' => mode = .all_exist,
            'm' => mode = .none_exist,
            'n' => no_newline = true,
            'q', 's' => verbose = false,
            'v' => verbose = true,
            'z' => eol = 0,
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) c.missingOperand();
    if (no_newline and files.items.len > 1) {
        c.warn("ignoring --no-newline with multiple arguments", .{});
        no_newline = false;
    }
    var status: u8 = 0;
    for (files.items) |f| {
        if (mode) |m| {
            const r = c.canonicalize(f, m, true) catch |e| {
                if (verbose) c.warn("{s}: {s}", .{ f, c.strerror(e) });
                status = 1;
                continue;
            };
            try c.out.writeAll(r);
        } else {
            var buf: [c.PATH_MAX]u8 = undefined;
            const t = c.sys.readlink(f, &buf) catch |e| {
                if (verbose) c.warn("{s}: {s}", .{ f, c.strerror(e) });
                status = 1;
                continue;
            };
            try c.out.writeAll(t);
        }
        if (!no_newline) try c.out.writeByte(eol);
    }
    return status;
}
