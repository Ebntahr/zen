const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: truncate OPTION... FILE...
    \\Shrink or extend the size of each FILE to the specified size
    \\
    \\A FILE argument that does not exist is created.
    \\
    \\  -c, --no-create        do not create any files
    \\  -o, --io-blocks        treat SIZE as number of IO blocks instead of bytes
    \\  -r, --reference=RFILE  base size on RFILE
    \\  -s, --size=SIZE        set or adjust the file size by SIZE bytes
    \\
    \\SIZE may also be prefixed by one of the following modifying characters:
    \\'+' extend by, '-' reduce by, '<' at most, '>' at least,
    \\'/' round down to multiple of, '%' round up to multiple of.
    \\
;

pub fn main(args: c.Args) !u8 {
    var no_create = false;
    var io_blocks = false;
    var ref_size: ?u64 = null;
    var size_spec: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "no-create", 'c' }, .{ "io-blocks", 'o' }, .{ "reference", 'r' }, .{ "size", 's' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'c' => no_create = true,
            'o' => io_blocks = true,
            'r' => {
                const r = p.arg();
                const st = c.sys.stat(r) catch |e| c.fatal("cannot stat {f}: {s}", .{ c.q(r), c.strerror(e) });
                ref_size = @intCast(st.size);
            },
            's' => size_spec = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (size_spec == null and ref_size == null) c.usageErr("you must specify either '--size' or '--reference'", .{});
    if (files.items.len == 0) c.usageErr("missing file operand", .{});
    var op: u8 = '=';
    var amount: u64 = 0;
    if (size_spec) |s_in| {
        var s = s_in;
        if (s.len > 0 and std.mem.indexOfScalar(u8, "+-<>/%", s[0]) != null) {
            op = s[0];
            s = s[1..];
        }
        amount = c.parseSize(s) orelse c.fatal("Invalid number: {f}", .{c.q(s_in)});
    }
    var status: u8 = 0;
    for (files.items) |f| {
        const fd = c.sys.open(f, .{ .ACCMODE = .WRONLY, .CREAT = !no_create, .NONBLOCK = true, .CLOEXEC = true }, 0o666) catch |e| {
            if (no_create and e == error.NOENT) continue;
            c.warn("cannot open {f} for writing: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
            continue;
        };
        defer c.sys.close(fd);
        const st = c.sys.fstat(fd) catch |e| {
            c.warn("cannot fstat {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
            continue;
        };
        var amt = amount;
        if (io_blocks) amt *= @intCast(@max(st.blksize, 1));
        const cur: u64 = ref_size orelse @intCast(st.size);
        const new: u64 = switch (op) {
            '+' => cur + amt,
            '-' => if (amt > cur) 0 else cur - amt,
            '<' => @min(cur, amt),
            '>' => @max(cur, amt),
            '/' => if (amt == 0) c.fatal("division by zero", .{}) else (cur / amt) * amt,
            '%' => if (amt == 0) c.fatal("division by zero", .{}) else ((cur + amt - 1) / amt) * amt,
            else => if (size_spec == null) cur else amt,
        };
        c.sys.ftruncate(fd, new) catch |e| {
            c.warn("failed to truncate {f} at {d} bytes: {s}", .{ c.q(f), new, c.strerror(e) });
            status = 1;
        };
    }
    return status;
}
