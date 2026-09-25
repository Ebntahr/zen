const std = @import("std");
const c = @import("../common.zig");
const nproc = @import("nproc.zig");

pub const help =
    \\Usage: getconf [-a] | [-v SPEC] VARIABLE [PATHNAME]
    \\Get configuration values.
    \\
    \\  -a       print all known variables and their values
    \\
;

fn value(name: []const u8, path: ?[]const u8) ?[]const u8 {
    var buf = c.gpa.alloc(u8, 32) catch c.oom();
    _ = path;
    const fixed = [_]struct { []const u8, []const u8 }{
        .{ "ARG_MAX", "2097152" },          .{ "CHILD_MAX", "unlimited" },     .{ "CLK_TCK", "100" },
        .{ "HOST_NAME_MAX", "64" },         .{ "LOGIN_NAME_MAX", "256" },      .{ "NGROUPS_MAX", "65536" },
        .{ "OPEN_MAX", "1024" },            .{ "PAGESIZE", "4096" },           .{ "PAGE_SIZE", "4096" },
        .{ "LINE_MAX", "2048" },            .{ "NAME_MAX", "255" },            .{ "PATH_MAX", "4096" },
        .{ "PIPE_BUF", "4096" },            .{ "LONG_BIT", "64" },             .{ "WORD_BIT", "32" },
        .{ "INT_MAX", "2147483647" },       .{ "INT_MIN", "-2147483648" },     .{ "UINT_MAX", "4294967295" },
        .{ "LONG_MAX", "9223372036854775807" }, .{ "LONG_MIN", "-9223372036854775808" }, .{ "ULONG_MAX", "18446744073709551615" },
        .{ "CHAR_BIT", "8" },               .{ "CHAR_MAX", "127" },            .{ "SCHAR_MAX", "127" },
        .{ "SHRT_MAX", "32767" },           .{ "SSIZE_MAX", "9223372036854775807" }, .{ "_POSIX_VERSION", "200809" },
        .{ "_POSIX2_VERSION", "200809" },   .{ "POSIX_VERSION", "200809" },    .{ "POSIX2_VERSION", "200809" },
        .{ "BC_BASE_MAX", "99" },           .{ "BC_DIM_MAX", "2048" },         .{ "BC_SCALE_MAX", "99" },
        .{ "BC_STRING_MAX", "1000" },       .{ "COLL_WEIGHTS_MAX", "255" },    .{ "EXPR_NEST_MAX", "32" },
        .{ "RE_DUP_MAX", "32767" },         .{ "STREAM_MAX", "16" },           .{ "TZNAME_MAX", "6" },
        .{ "SYMLOOP_MAX", "40" },           .{ "IOV_MAX", "1024" },            .{ "LINK_MAX", "65000" },
        .{ "MAX_CANON", "255" },            .{ "MAX_INPUT", "255" },           .{ "_POSIX_THREADS", "200809" },
        .{ "GNU_LIBC_VERSION", "zbox" },    .{ "LFS_CFLAGS", "" },             .{ "LFS_LDFLAGS", "" },
    };
    for (fixed) |f| if (c.eql(f[0], name)) return f[1];
    if (c.eql(name, "_NPROCESSORS_ONLN") or c.eql(name, "NPROCESSORS_ONLN")) return c.fmtBuf(buf, "{d}", .{nproc.onlineCpus()});
    if (c.eql(name, "_NPROCESSORS_CONF") or c.eql(name, "NPROCESSORS_CONF")) return c.fmtBuf(buf, "{d}", .{nproc.allCpus()});
    if (c.eql(name, "_PHYS_PAGES") or c.eql(name, "_AVPHYS_PAGES")) {
        const pr = @import("../procfs.zig");
        const m = pr.memInfo() orelse return "0";
        return c.fmtBuf(buf, "{d}", .{(if (c.eql(name, "_PHYS_PAGES")) m.total else m.available orelse m.free) / 4});
    }
    if (c.eql(name, "PATH")) return "/bin:/usr/bin";
    buf = buf;
    return null;
}

pub fn main(args: c.Args) !u8 {
    var all = false;
    var ops: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{.{ "all", 'a' }});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => all = true,
            'v' => _ = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try ops.append(c.gpa, a),
        else => p.bad(o),
    };
    if (all) {
        const names = [_][]const u8{ "ARG_MAX", "CHILD_MAX", "CLK_TCK", "HOST_NAME_MAX", "LINE_MAX", "LOGIN_NAME_MAX", "LONG_BIT", "NAME_MAX", "NGROUPS_MAX", "OPEN_MAX", "PAGESIZE", "PAGE_SIZE", "PATH_MAX", "PIPE_BUF", "_NPROCESSORS_CONF", "_NPROCESSORS_ONLN", "_PHYS_PAGES", "_POSIX_VERSION" };
        for (names) |n| {
            try c.padRight(c.out, n, 34);
            try c.out.print("{s}\n", .{value(n, null).?});
        }
        return 0;
    }
    if (ops.items.len == 0) c.usageErr("missing operand", .{});
    const v = value(ops.items[0], if (ops.items.len > 1) ops.items[1] else null) orelse {
        c.warn("Unrecognized variable `{s}'", .{ops.items[0]});
        return 2;
    };
    try c.out.print("{s}\n", .{v});
    return 0;
}
