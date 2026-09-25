const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: dd [OPERAND]...
    \\  or:  dd OPTION
    \\Copy a file, converting and formatting according to the operands.
    \\
    \\  bs=BYTES        read and write up to BYTES bytes at a time (default: 512)
    \\  cbs=BYTES       (ignored)
    \\  conv=CONVS      convert the file as per the comma separated symbol list
    \\  count=N         copy only N input blocks
    \\  ibs=BYTES       read up to BYTES bytes at a time (default: 512)
    \\  if=FILE         read from FILE instead of stdin
    \\  iflag=FLAGS     read as per the comma separated symbol list
    \\  obs=BYTES       write BYTES bytes at a time (default: 512)
    \\  of=FILE         write to FILE instead of stdout
    \\  oflag=FLAGS     write as per the comma separated symbol list
    \\  seek=N          skip N obs-sized output blocks
    \\  skip=N          skip N ibs-sized input blocks
    \\  status=LEVEL    'none', 'noxfer' or 'progress'
    \\
    \\CONVS: notrunc noerror sync fsync fdatasync excl nocreat ucase lcase swab
    \\FLAGS: append count_bytes skip_bytes seek_bytes fullblock (others ignored)
    \\
;

fn fmtHuman(buf: []u8, n: u64, base: f64, units: []const []const u8) []const u8 {
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= base and i + 1 < units.len) : (i += 1) v /= base;
    if (v < 10) return c.fmtBuf(buf, "{d:.1} {s}", .{ v, units[i] });
    return c.fmtBuf(buf, "{d:.0} {s}", .{ v, units[i] });
}

pub fn main(args: c.Args) !u8 {
    var ifile: ?[]const u8 = null;
    var ofile: ?[]const u8 = null;
    var ibs: u64 = 512;
    var obs: u64 = 512;
    var count: ?u64 = null;
    var skip: u64 = 0;
    var seek: u64 = 0;
    var notrunc = false;
    var noerror = false;
    var sync_pad = false;
    var fsync = false;
    var excl = false;
    var nocreat = false;
    var ucase = false;
    var lcase = false;
    var swab = false;
    var append = false;
    var count_bytes = false;
    var skip_bytes = false;
    var seek_bytes = false;
    var fullblock = false;
    var status_level: []const u8 = "default";
    for (args[1..]) |a| {
        if (c.eql(a, "--help")) c.printHelp();
        if (c.eql(a, "--version")) c.printVersion();
        const eq = mem.indexOfScalar(u8, a, '=') orelse c.usageErr("unrecognized operand {f}", .{c.q(a)});
        const k = a[0..eq];
        const v = a[eq + 1 ..];
        const num = struct {
            fn f(s: []const u8) u64 {
                // support NxM products
                var total: u64 = 1;
                var it = mem.splitScalar(u8, s, 'x');
                while (it.next()) |part| total *= c.parseSize(part) orelse c.fatal("invalid number: {f}", .{c.q(s)});
                return total;
            }
        }.f;
        if (c.eql(k, "if")) ifile = v else if (c.eql(k, "of")) ofile = v else if (c.eql(k, "bs")) {
            ibs = num(v);
            obs = ibs;
        } else if (c.eql(k, "ibs")) ibs = num(v) else if (c.eql(k, "obs")) obs = num(v) else if (c.eql(k, "count")) count = num(v) else if (c.eql(k, "skip") or c.eql(k, "iseek")) skip = num(v) else if (c.eql(k, "seek") or c.eql(k, "oseek")) seek = num(v) else if (c.eql(k, "cbs")) {} else if (c.eql(k, "status")) status_level = v else if (c.eql(k, "conv") or c.eql(k, "iflag") or c.eql(k, "oflag")) {
            var it = mem.splitScalar(u8, v, ',');
            while (it.next()) |f| {
                if (c.eql(f, "notrunc")) notrunc = true else if (c.eql(f, "noerror")) noerror = true else if (c.eql(f, "sync")) {
                    if (c.eql(k, "conv")) sync_pad = true;
                } else if (c.eql(f, "fsync") or c.eql(f, "fdatasync") or c.eql(f, "dsync")) fsync = true else if (c.eql(f, "excl")) excl = true else if (c.eql(f, "nocreat")) nocreat = true else if (c.eql(f, "ucase")) ucase = true else if (c.eql(f, "lcase")) lcase = true else if (c.eql(f, "swab")) swab = true else if (c.eql(f, "append")) append = true else if (c.eql(f, "count_bytes")) count_bytes = true else if (c.eql(f, "skip_bytes")) skip_bytes = true else if (c.eql(f, "seek_bytes")) seek_bytes = true else if (c.eql(f, "fullblock")) fullblock = true else if (c.eql(f, "direct") or c.eql(f, "nonblock") or c.eql(f, "noatime") or c.eql(f, "nocache") or c.eql(f, "binary") or c.eql(f, "text") or c.eql(f, "noctty") or c.eql(f, "nofollow")) {} else c.fatal("invalid {s} {f}", .{ if (c.eql(k, "conv")) "conversion" else "input flag", c.q(f) });
            }
        } else c.usageErr("unrecognized operand {f}", .{c.q(a)});
    }
    if (ibs == 0 or obs == 0) c.fatal("invalid number: '0'", .{});
    const in_fd: i32 = if (ifile) |f| c.sys.open(f, c.O_RDONLY, 0) catch |e| c.fatal("failed to open {f}: {s}", .{ c.q(f), c.strerror(e) }) else 0;
    var out_fd: i32 = 1;
    if (ofile) |f| {
        out_fd = c.sys.open(f, .{ .ACCMODE = .WRONLY, .CREAT = !nocreat, .EXCL = excl, .TRUNC = !notrunc and seek == 0 and !append, .APPEND = append, .CLOEXEC = true }, 0o666) catch |e| c.fatal("failed to open {f}: {s}", .{ c.q(f), c.strerror(e) });
        if (!notrunc and seek > 0 and !append) {
            const off = if (seek_bytes) seek else seek * obs;
            c.sys.ftruncate(out_fd, off) catch {};
        }
    }
    c.flush();
    // skip input
    const skip_off = if (skip_bytes) skip else skip * ibs;
    if (skip_off > 0) {
        if (c.sys.lseek(in_fd, @intCast(skip_off), 0)) |_| {} else |_| {
            var left = skip_off;
            var tmp: [65536]u8 = undefined;
            while (left > 0) {
                const n = c.sys.read(in_fd, tmp[0..@intCast(@min(left, tmp.len))]) catch break;
                if (n == 0) break;
                left -= n;
            }
        }
    }
    const seek_off = if (seek_bytes) seek else seek * obs;
    if (seek_off > 0) _ = c.sys.lseek(out_fd, @intCast(seek_off), 0) catch {};
    const start = c.monoNs();
    const buf = try c.gpa.alloc(u8, @intCast(@max(ibs, obs)));
    var full_in: u64 = 0;
    var part_in: u64 = 0;
    var full_out: u64 = 0;
    var part_out: u64 = 0;
    var total: u64 = 0;
    var status: u8 = 0;
    var remaining_bytes: ?u64 = if (count != null and count_bytes) count.? else null;
    var blocks: u64 = 0;
    var pending: std.ArrayList(u8) = .empty;
    while (true) {
        if (count) |cn| if (!count_bytes and blocks >= cn) break;
        if (remaining_bytes) |rb| if (rb == 0) break;
        var want: usize = @intCast(ibs);
        if (remaining_bytes) |rb| want = @intCast(@min(rb, ibs));
        var n: usize = 0;
        while (n < want) {
            const k = c.sys.read(in_fd, buf[n..want]) catch |e| {
                c.warn("error reading {f}: {s}", .{ c.q(ifile orelse "standard input"), c.strerror(e) });
                status = 1;
                if (noerror) break;
                c.exit(1);
            };
            if (k == 0) break;
            n += k;
            if (!fullblock) break;
        }
        if (n == 0) break;
        blocks += 1;
        if (n == want and want == ibs) full_in += 1 else part_in += 1;
        if (remaining_bytes) |*rb| rb.* -= n;
        var chunk = buf[0..n];
        if (sync_pad and n < ibs) {
            @memset(buf[n..@intCast(ibs)], 0);
            chunk = buf[0..@intCast(ibs)];
        }
        if (swab) {
            var i: usize = 0;
            while (i + 1 < chunk.len) : (i += 2) mem.swap(u8, &chunk[i], &chunk[i + 1]);
        }
        if (ucase) for (chunk) |*ch| {
            ch.* = std.ascii.toUpper(ch.*);
        };
        if (lcase) for (chunk) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        };
        try pending.appendSlice(c.gpa, chunk);
        while (pending.items.len >= obs) {
            c.sys.writeAll(out_fd, pending.items[0..@intCast(obs)]) catch |e| c.fatal("error writing {f}: {s}", .{ c.q(ofile orelse "standard output"), c.strerror(e) });
            full_out += 1;
            total += obs;
            const rest = pending.items.len - @as(usize, @intCast(obs));
            mem.copyForwards(u8, pending.items[0..rest], pending.items[@intCast(obs)..]);
            pending.shrinkRetainingCapacity(rest);
        }
    }
    if (pending.items.len > 0) {
        c.sys.writeAll(out_fd, pending.items) catch |e| c.fatal("error writing {f}: {s}", .{ c.q(ofile orelse "standard output"), c.strerror(e) });
        part_out += 1;
        total += pending.items.len;
    }
    if (fsync) c.sys.fsync(out_fd) catch {};
    if (!c.eql(status_level, "none")) {
        c.eprint("{d}+{d} records in\n{d}+{d} records out\n", .{ full_in, part_in, full_out, part_out });
        if (!c.eql(status_level, "noxfer")) {
            const secs = @as(f64, @floatFromInt(c.monoNs() - start)) / 1e9;
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            var b3: [32]u8 = undefined;
            const si_units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB" };
            const iec_units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
            const rate = if (secs > 0) @as(f64, @floatFromInt(total)) / secs else 0;
            const rate_s = fmtHuman(&b3, @intFromFloat(rate), 1000, &si_units);
            if (total >= 1000) {
                const si_s = fmtHuman(&b1, total, 1000, &si_units);
                const iec_s = fmtHuman(&b2, total, 1024, &iec_units);
                if (total >= 1024) {
                    c.eprint("{d} bytes ({s}, {s}) copied, {d:.6} s, {s}/s\n", .{ total, si_s, iec_s, secs, rate_s });
                } else c.eprint("{d} bytes ({s}) copied, {d:.6} s, {s}/s\n", .{ total, si_s, secs, rate_s });
            } else c.eprint("{d} byte{s} copied, {d:.6} s, {s}/s\n", .{ total, if (total == 1) "" else "s", secs, rate_s });
        }
    }
    return status;
}
