const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: mktemp [OPTION]... [TEMPLATE]
    \\Create a temporary file or directory, safely, and print its name.
    \\TEMPLATE must contain at least 3 consecutive 'X's in last component.
    \\If TEMPLATE is not specified, use tmp.XXXXXXXXXX, and --tmpdir is implied.
    \\
    \\  -d, --directory     create a directory, not a file
    \\  -u, --dry-run       do not create anything; merely print a name (unsafe)
    \\  -q, --quiet         suppress diagnostics about file/dir-creation failure
    \\      --suffix=SUFF   append SUFF to TEMPLATE
    \\  -p DIR, --tmpdir[=DIR]  interpret TEMPLATE relative to DIR; if DIR is not
    \\                        specified, use $TMPDIR if set, else /tmp
    \\  -t                  interpret TEMPLATE as a single file name component,
    \\                        relative to a directory: $TMPDIR, if set; else the
    \\                        directory specified via -p; else /tmp [deprecated]
    \\
;

pub fn main(args: c.Args) !u8 {
    var dir = false;
    var dry = false;
    var quiet = false;
    var suffix: []const u8 = "";
    var tmpdir: ?[]const u8 = null;
    var use_tmpdir = false;
    var t_flag = false;
    var template: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{ .{ "directory", 'd' }, .{ "dry-run", 'u' }, .{ "quiet", 'q' }, .{ "suffix", 0 }, .{ "tmpdir", 0 } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'd' => dir = true,
            'u' => dry = true,
            'q' => quiet = true,
            'p' => {
                tmpdir = p.arg();
                use_tmpdir = true;
            },
            't' => t_flag = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "suffix")) suffix = p.arg() else if (c.eql(n, "tmpdir")) {
                use_tmpdir = true;
                tmpdir = p.optArg();
            } else p.bad(o);
        },
        .pos => |a| {
            if (template != null) c.usageErr("too many templates", .{});
            template = a;
        },
    };
    if (template == null) {
        template = "tmp.XXXXXXXXXX";
        use_tmpdir = true;
    }
    var tmpl: []const u8 = template.?;
    if (use_tmpdir or t_flag) {
        if (use_tmpdir and mem.indexOfScalar(u8, tmpl, '/') != null) c.fatal("invalid template, {f}, contains directory separator", .{c.q(tmpl)});
        const base = if (t_flag) (c.getenv("TMPDIR") orelse tmpdir orelse "/tmp") else (tmpdir orelse c.getenv("TMPDIR") orelse "/tmp");
        tmpl = c.join(if (base.len == 0) "/tmp" else base, tmpl);
    }
    // count trailing X's (before suffix)
    var xs: usize = 0;
    var end = tmpl.len;
    if (suffix.len == 0) {
        // suffix may be implied: X's must be at the end of last component
    }
    while (end > 0 and tmpl[end - 1] == 'X') : (end -= 1) xs += 1;
    if (xs < 3) c.fatal("too few X's in template {f}", .{c.q(template.?)});
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        var name = try c.gpa.alloc(u8, tmpl.len + suffix.len);
        @memcpy(name[0..tmpl.len], tmpl);
        @memcpy(name[tmpl.len..], suffix);
        var rnd: [64]u8 = undefined;
        std.crypto.random.bytes(&rnd);
        for (0..xs) |k| name[end + k] = chars[rnd[k % rnd.len] % chars.len];
        if (dry) {
            if (c.sys.lstat(name)) |_| continue else |_| {}
            try c.out.print("{s}\n", .{name});
            return 0;
        }
        if (dir) {
            c.sys.mkdir(name, 0o700) catch |e| {
                if (e == error.EXIST) continue;
                if (!quiet) c.warn("failed to create directory via template {f}: {s}", .{ c.q(tmpl), c.strerror(e) });
                return 1;
            };
        } else {
            const fd = c.sys.open(name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600) catch |e| {
                if (e == error.EXIST) continue;
                if (!quiet) c.warn("failed to create file via template {f}: {s}", .{ c.q(tmpl), c.strerror(e) });
                return 1;
            };
            c.sys.close(fd);
        }
        try c.out.print("{s}\n", .{name});
        return 0;
    }
    if (!quiet) c.warn("failed to create file via template {f}: File exists", .{c.q(tmpl)});
    return 1;
}
