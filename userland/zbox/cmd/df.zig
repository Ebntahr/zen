const std = @import("std");
const c = @import("../common.zig");
const stat = @import("stat.zig");
const mem = std.mem;

pub const help =
    \\Usage: df [OPTION]... [FILE]...
    \\Show information about the file system on which each FILE resides,
    \\or all file systems by default.
    \\
    \\  -a, --all             include pseudo, duplicate, inaccessible file systems
    \\  -B, --block-size=SIZE  scale sizes by SIZE before printing them
    \\  -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)
    \\  -H, --si              print sizes in powers of 1000 (e.g., 1.1G)
    \\  -i, --inodes          list inode information instead of block usage
    \\  -k                    like --block-size=1K
    \\  -l, --local           limit listing to local file systems
    \\  -P, --portability     use the POSIX output format
    \\      --total           elide all entries insignificant to available space,
    \\                          and produce a grand total
    \\  -t, --type=TYPE       limit listing to file systems of type TYPE
    \\  -T, --print-type      print file system type
    \\  -x, --exclude-type=TYPE   limit listing to file systems not of type TYPE
    \\
;

const Mount = struct { src: []const u8, target: []const u8, fstype: []const u8 };

fn unescapeMount(s: []const u8) []const u8 {
    if (mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 3 < s.len + 0 and i + 3 <= s.len - 1 + 1) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. @min(s.len, i + 4)], 8) catch {
                out.append(c.gpa, s[i]) catch c.oom();
                i += 1;
                continue;
            };
            out.append(c.gpa, v) catch c.oom();
            i += 4;
        } else {
            out.append(c.gpa, s[i]) catch c.oom();
            i += 1;
        }
    }
    return out.items;
}

fn readMounts() []Mount {
    var list: std.ArrayList(Mount) = .empty;
    const data = c.readFile("/proc/self/mounts") catch c.readFile("/proc/mounts") catch c.readFile("/etc/mtab") catch {
        list.append(c.gpa, .{ .src = "rootfs", .target = "/", .fstype = "rootfs" }) catch c.oom();
        return list.items;
    };
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = mem.tokenizeAny(u8, line, " \t");
        const src = f.next() orelse continue;
        const target = f.next() orelse continue;
        const fstype = f.next() orelse continue;
        list.append(c.gpa, .{ .src = unescapeMount(src), .target = unescapeMount(target), .fstype = fstype }) catch c.oom();
    }
    return list.items;
}

fn isDummy(fstype: []const u8) bool {
    const dummies = [_][]const u8{
        "autofs",  "proc",     "subfs",  "debugfs",  "devpts",    "fusectl",    "fuse.portal", "mqueue",
        "rpc_pipefs", "sysfs", "devfs",  "kernfs",   "ignore",    "none",       "binfmt_misc", "bpf",
        "cgroup",  "cgroup2",  "configfs", "devtmpfs", "efivarfs", "hugetlbfs", "nsfs",        "pstore",
        "securityfs", "squashfs", "tracefs", "rootfs", "selinuxfs",
    };
    for (dummies) |d| if (c.eql(d, fstype)) return true;
    return false;
}

const Row = struct { cells: [8][]const u8 };

pub fn main(args: c.Args) !u8 {
    var all = false;
    var human = false;
    var si = false;
    var inodes = false;
    var posix_fmt = false;
    var print_type = false;
    var total = false;
    var block_size: u64 = 1024;
    var only_types: std.ArrayList([]const u8) = .empty;
    var excl_types: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "all", 'a' },        .{ "block-size", 'B' }, .{ "human-readable", 'h' }, .{ "si", 'H' },
        .{ "inodes", 'i' },     .{ "local", 'l' },      .{ "portability", 'P' },    .{ "total", 0 },
        .{ "type", 't' },       .{ "print-type", 'T' }, .{ "exclude-type", 'x' },   .{ "sync", 0 }, .{ "no-sync", 0 },
        .{ "output", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => all = true,
            'B' => {
                const a = p.arg();
                block_size = c.parseSize(a) orelse c.fatal("invalid --block-size argument {f}", .{c.q(a)});
            },
            'h' => human = true,
            'H' => si = true,
            'i' => inodes = true,
            'k' => block_size = 1024,
            'l' => {},
            'P' => posix_fmt = true,
            't' => try only_types.append(c.gpa, p.arg()),
            'T' => print_type = true,
            'x' => try excl_types.append(c.gpa, p.arg()),
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "total")) total = true else if (c.eql(n, "sync") or c.eql(n, "no-sync")) {} else if (c.eql(n, "output")) {
                _ = p.optArg();
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    const mounts = readMounts();
    var selected: std.ArrayList(Mount) = .empty;
    var status: u8 = 0;
    if (files.items.len > 0) {
        for (files.items) |f| {
            const st = c.sys.stat(f) catch |e| {
                c.warn("{s}: {s}", .{ f, c.strerror(e) });
                status = 1;
                continue;
            };
            // choose the last mount whose device matches (longest match)
            var best: ?Mount = null;
            for (mounts) |m| {
                const ms = c.sys.stat(m.target) catch continue;
                if (ms.dev == st.dev) best = m;
            }
            try selected.append(c.gpa, best orelse .{ .src = "-", .target = c.dirname(f), .fstype = "-" });
        }
    } else {
        var devs: std.ArrayList(u64) = .empty;
        for (mounts) |m| {
            if (!all and isDummy(m.fstype)) continue;
            if (only_types.items.len > 0) {
                var ok = false;
                for (only_types.items) |t| if (c.eql(t, m.fstype)) {
                    ok = true;
                };
                if (!ok) continue;
            }
            var excl = false;
            for (excl_types.items) |t| if (c.eql(t, m.fstype)) {
                excl = true;
            };
            if (excl) continue;
            const ms = c.sys.stat(m.target) catch continue;
            if (!all) {
                if (mem.indexOfScalar(u64, devs.items, ms.dev)) |k| {
                    const seen = selected.items[k];
                    const me_slash = mem.indexOfScalar(u8, m.src, '/') != null;
                    const seen_slash = mem.indexOfScalar(u8, seen.src, '/') != null;
                    if ((me_slash and !seen_slash) or seen.target.len > m.target.len or
                        (!c.eql(seen.src, m.src) and c.eql(seen.target, m.target)))
                    {
                        selected.items[k] = m;
                    }
                    continue;
                }
            }
            try devs.append(c.gpa, ms.dev);
            try selected.append(c.gpa, m);
        }
    }
    var rows: std.ArrayList([]const []const u8) = .empty;
    var right: [8]bool = .{ false, false, true, true, true, true, false, false };
    var header: std.ArrayList([]const u8) = .empty;
    try header.append(c.gpa, "Filesystem");
    if (print_type) try header.append(c.gpa, "Type");
    const size_hdr: []const u8 = if (inodes) "Inodes" else if (human or si) "Size" else if (posix_fmt) (if (block_size == 1024) "1024-blocks" else "blocks") else if (block_size == 1024) "1K-blocks" else if (block_size == 1024 * 1024) "1M-blocks" else "blocks";
    try header.append(c.gpa, size_hdr);
    try header.append(c.gpa, if (inodes) "IUsed" else "Used");
    try header.append(c.gpa, if (inodes) "IFree" else if (human or si or !posix_fmt) (if (human or si) "Avail" else "Available") else "Available");
    try header.append(c.gpa, if (inodes) "IUse%" else if (posix_fmt) "Capacity" else "Use%");
    try header.append(c.gpa, "Mounted on");
    try rows.append(c.gpa, header.items);
    var tot = [4]u64{ 0, 0, 0, 0 };
    const fmtNum = struct {
        fn f(v: u64, h: bool, s: bool, bs: u64, is_inode: bool) []const u8 {
            const buf = c.gpa.alloc(u8, 32) catch c.oom();
            if (h or s) return c.humanSize(buf, if (is_inode) v else v, s);
            return c.fmtBuf(buf, "{d}", .{(v + bs - 1) / bs});
        }
    }.f;
    for (selected.items) |m| {
        const sf = stat.statfs(m.target) catch |e| {
            if (files.items.len > 0) {
                c.warn("{s}: {s}", .{ m.target, c.strerror(e) });
                status = 1;
            }
            continue;
        };
        if (!all and files.items.len == 0 and sf.blocks == 0 and !inodes) continue;
        var row: std.ArrayList([]const u8) = .empty;
        try row.append(c.gpa, m.src);
        if (print_type) try row.append(c.gpa, m.fstype);
        const bsz: u64 = @intCast(if (sf.frsize != 0) sf.frsize else sf.bsize);
        if (inodes) {
            const used = sf.files - sf.ffree;
            try row.append(c.gpa, fmtNum(sf.files, human, si, 1, true));
            try row.append(c.gpa, fmtNum(used, human, si, 1, true));
            try row.append(c.gpa, fmtNum(sf.ffree, human, si, 1, true));
            const denom = used + sf.ffree;
            try row.append(c.gpa, if (denom == 0) "-" else try std.fmt.allocPrint(c.gpa, "{d}%", .{(used * 100 + denom - 1) / denom}));
            tot[0] += sf.files;
            tot[1] += used;
            tot[2] += sf.ffree;
        } else {
            const size = sf.blocks * bsz;
            const used = (sf.blocks - sf.bfree) * bsz;
            const avail = sf.bavail * bsz;
            try row.append(c.gpa, fmtNum(size, human, si, block_size, false));
            try row.append(c.gpa, fmtNum(used, human, si, block_size, false));
            try row.append(c.gpa, fmtNum(avail, human, si, block_size, false));
            const u = sf.blocks - sf.bfree;
            const denom = u + sf.bavail;
            try row.append(c.gpa, if (denom == 0) "-" else try std.fmt.allocPrint(c.gpa, "{d}%", .{(u * 100 + denom - 1) / denom}));
            tot[0] += size;
            tot[1] += used;
            tot[2] += avail;
        }
        try row.append(c.gpa, m.target);
        try rows.append(c.gpa, row.items);
    }
    if (total) {
        var row: std.ArrayList([]const u8) = .empty;
        try row.append(c.gpa, "total");
        if (print_type) try row.append(c.gpa, "-");
        const bs: u64 = if (inodes) 1 else block_size;
        try row.append(c.gpa, fmtNum(tot[0], human, si, bs, inodes));
        try row.append(c.gpa, fmtNum(tot[1], human, si, bs, inodes));
        try row.append(c.gpa, fmtNum(tot[2], human, si, bs, inodes));
        const denom = tot[1] + tot[2];
        try row.append(c.gpa, if (denom == 0) "-" else try std.fmt.allocPrint(c.gpa, "{d}%", .{(tot[1] * 100 + denom - 1) / denom}));
        try row.append(c.gpa, "-");
        try rows.append(c.gpa, row.items);
    }
    const ncols = header.items.len;
    if (print_type) right = .{ false, false, true, true, true, true, false, false } else right = .{ false, true, true, true, true, false, false, false };
    var widths: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const minw_notype = [_]usize{ 14, 5, 5, 5, 4, 0, 0, 0 };
    const minw_type = [_]usize{ 14, 4, 5, 5, 5, 4, 0, 0 };
    for (0..ncols) |k| widths[k] = if (print_type) minw_type[k] else minw_notype[k];
    if (posix_fmt) widths[0] = 0;
    for (rows.items) |r| for (r, 0..) |cell, k| {
        widths[k] = @max(widths[k], c.displayWidth(cell));
    };
    const w = c.out;
    for (rows.items) |r| {
        for (r, 0..) |cell, k| {
            const last = k + 1 == r.len;
            if (right[k]) {
                try c.padLeft(w, cell, widths[k]);
            } else if (last) {
                try w.writeAll(cell);
            } else try c.padRight(w, cell, widths[k]);
            if (!last) try w.writeByte(' ');
        }
        try w.writeByte('\n');
    }
    return status;
}
