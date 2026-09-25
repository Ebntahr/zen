const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: du [OPTION]... [FILE]...
    \\Summarize device usage of the set of FILEs, recursively for directories.
    \\
    \\  -0, --null            end each output line with NUL, not newline
    \\  -a, --all             write counts for all files, not just directories
    \\      --apparent-size   print apparent sizes rather than device usage
    \\  -B, --block-size=SIZE  scale sizes by SIZE before printing them
    \\  -b, --bytes           equivalent to '--apparent-size --block-size=1'
    \\  -c, --total           produce a grand total
    \\  -d, --max-depth=N     print the total for a directory (or file, with --all)
    \\                          only if it is N or fewer levels below the command
    \\                          line argument;  --max-depth=0 is the same as
    \\                          --summarize
    \\  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)
    \\      --si              like -h, but use powers of 1000 not 1024
    \\  -k                    like --block-size=1K
    \\  -L, --dereference     dereference all symbolic links
    \\  -m                    like --block-size=1M
    \\  -s, --summarize       display only a total for each argument
    \\  -S, --separate-dirs   for directories do not include size of subdirectories
    \\  -x, --one-file-system    skip directories on different file systems
    \\      --exclude=PATTERN  exclude files that match PATTERN
    \\
;

var all = false;
var apparent = false;
var block_size: u64 = 1024;
var human = false;
var si = false;
var max_depth: ?u64 = null;
var deref = false;
var separate = false;
var one_fs = false;
var eol: u8 = '\n';
var excludes: std.ArrayList([]const u8) = .empty;
var seen: std.AutoHashMap(u128, void) = undefined;
var status: u8 = 0;

fn sizeOf(st: c.Stat) u64 {
    if (apparent) return if (st.isDir()) 0 else @intCast(@max(st.size, 0));
    return @as(u64, @intCast(@max(st.blocks, 0))) * 512;
}

fn printSize(bytes: u64, path: []const u8) !void {
    var b: [32]u8 = undefined;
    const s = if (human or si) c.humanSize(&b, bytes, si) else c.fmtBuf(&b, "{d}", .{(bytes + block_size - 1) / block_size});
    try c.out.print("{s}\t{s}{c}", .{ s, path, eol });
}

fn excluded(path: []const u8) bool {
    for (excludes.items) |pat| {
        if (c.fnmatch(pat, c.basename(path), .{}) or c.fnmatch(pat, path, .{})) return true;
    }
    return false;
}

/// Returns size in bytes of the tree at path.
fn walk(path: []const u8, depth: u64, root_dev: u64, top: bool) !u64 {
    const st = (if (deref or top) c.sys.stat(path) else c.sys.lstat(path)) catch |e| blk: {
        if (top) if (c.sys.lstat(path)) |ls| break :blk ls else |_| {};
        c.warn("cannot access {f}: {s}", .{ c.q(path), c.strerror(e) });
        status = 1;
        return 0;
    };
    if (!top and excluded(path)) return 0;
    if (st.nlink > 1 or st.isDir()) {
        const key = (@as(u128, st.dev) << 64) | st.ino;
        const r = try seen.getOrPut(key);
        if (r.found_existing) return 0;
    }
    var total = sizeOf(st);
    if (st.isDir()) {
        if (one_fs and root_dev != 0 and st.dev != root_dev) return 0;
        const names = c.readDirNames(path) catch |e| {
            c.warn("cannot read directory {f}: {s}", .{ c.q(path), c.strerror(e) });
            status = 1;
            if (max_depth == null or depth <= max_depth.?) try printSize(total, path);
            return total;
        };
        c.sortStrings(names);
        var sub_total: u64 = 0;
        for (names) |n| {
            const full = c.join(path, n);
            const s = try walk(full, depth + 1, if (root_dev == 0) st.dev else root_dev, false);
            const child_st = c.sys.lstat(full) catch null;
            if (separate and child_st != null and child_st.?.isDir()) continue;
            sub_total += s;
        }
        total += sub_total;
        if (max_depth == null or depth <= max_depth.?) try printSize(total, path);
    } else if ((all or top) and (max_depth == null or depth <= max_depth.?)) {
        try printSize(total, path);
    }
    return total;
}

pub fn main(args: c.Args) !u8 {
    var total_flag = false;
    var summarize = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "null", '0' },        .{ "all", 'a' },            .{ "apparent-size", 0 }, .{ "block-size", 'B' },
        .{ "bytes", 'b' },       .{ "total", 'c' },          .{ "max-depth", 'd' },   .{ "human-readable", 'h' },
        .{ "si", 0 },            .{ "dereference", 'L' },    .{ "summarize", 's' },   .{ "separate-dirs", 'S' },
        .{ "one-file-system", 'x' }, .{ "exclude", 0 },      .{ "count-links", 'l' }, .{ "inodes", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            '0' => eol = 0,
            'a' => all = true,
            'B' => {
                const a = p.arg();
                block_size = c.parseSize(a) orelse c.fatal("invalid --block-size argument {f}", .{c.q(a)});
                if (block_size == 0) block_size = 1;
            },
            'b' => {
                apparent = true;
                block_size = 1;
            },
            'c' => total_flag = true,
            'd' => {
                const a = p.arg();
                max_depth = c.parseUint(a) orelse c.fatal("invalid maximum depth {f}", .{c.q(a)});
            },
            'h' => human = true,
            'k' => block_size = 1024,
            'm' => block_size = 1024 * 1024,
            'L' => deref = true,
            'H', 'D', 'P', 'l' => {},
            's' => summarize = true,
            'S' => separate = true,
            'x' => one_fs = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "apparent-size")) apparent = true else if (c.eql(n, "si")) si = true else if (c.eql(n, "exclude")) try excludes.append(c.gpa, p.arg()) else if (c.eql(n, "inodes")) {} else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (summarize) {
        if (max_depth != null and max_depth.? != 0) {
            c.warn("warning: summarizing conflicts with --max-depth={d}", .{max_depth.?});
            c.tryHelp();
            c.exit(1);
        }
        max_depth = 0;
    }
    if (summarize and all) c.usageErr("cannot both summarize and show all entries", .{});
    seen = std.AutoHashMap(u128, void).init(c.gpa);
    if (files.items.len == 0) try files.append(c.gpa, ".");
    var grand: u64 = 0;
    for (files.items) |f| grand += try walk(f, 0, 0, true);
    if (total_flag) try printSize(grand, "total");
    return status;
}
