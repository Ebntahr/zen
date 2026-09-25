const std = @import("std");
const c = @import("../common.zig");
const pf = @import("printf.zig");
const linux = std.os.linux;
const mem = std.mem;

pub const help =
    \\Usage: stat [OPTION]... FILE...
    \\Display file or file system status.
    \\
    \\  -L, --dereference     follow links
    \\  -f, --file-system     display file system status instead of file status
    \\  -c  --format=FORMAT   use the specified FORMAT instead of the default;
    \\                          output a newline after each use of FORMAT
    \\      --printf=FORMAT   like --format, but interpret backslash escapes,
    \\                          and do not output a mandatory trailing newline
    \\  -t, --terse           print the information in terse form
    \\
    \\The valid format sequences for files (without --file-system):
    \\  %a   permission bits in octal       %A   permission bits, human readable
    \\  %b   number of blocks allocated     %B   the size in bytes of each block
    \\  %d   device number in decimal       %D   device number in hex
    \\  %f   raw mode in hex                %F   file type
    \\  %g   group ID of owner              %G   group name of owner
    \\  %h   number of hard links           %i   inode number
    \\  %m   mount point                    %n   file name
    \\  %N   quoted file name with dereference if symbolic link
    \\  %o   optimal I/O transfer size hint %s   total size, in bytes
    \\  %t   major device type in hex       %T   minor device type in hex
    \\  %u   user ID of owner               %U   user name of owner
    \\  %w   time of file birth             %W   time of file birth, seconds
    \\  %x   time of last access            %X   time of last access, seconds
    \\  %y   time of last data modification %Y   ..., seconds since Epoch
    \\  %z   time of last status change     %Z   ..., seconds since Epoch
    \\
    \\Valid format sequences for file systems:
    \\  %a   free blocks available to non-superuser   %b   total data blocks
    \\  %c   total file nodes      %d   free file nodes   %f   free blocks
    \\  %i   file system ID in hex %l   maximum length of filenames
    \\  %n   file name             %s   block size        %S   fundamental block size
    \\  %t   file system type in hex                      %T   file system type
    \\
;

pub const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

pub fn statfs(path: []const u8) c.SysError!Statfs {
    var b: [c.PATH_MAX]u8 = undefined;
    const pz = try c.toZ(&b, path);
    var sf: Statfs = mem.zeroes(Statfs);
    const rc = linux.syscall2(.statfs, @intFromPtr(pz), @intFromPtr(&sf));
    const e = std.posix.errno(rc);
    if (e != .SUCCESS) return c.mapErrno(e);
    return sf;
}

pub fn fsTypeName(t: i64) []const u8 {
    const v: u64 = @bitCast(t);
    return switch (v & 0xffffffff) {
        0xEF53 => "ext2/ext3",
        0x01021994 => "tmpfs",
        0x9fa0 => "proc",
        0x62656572 => "sysfs",
        0x1cd1 => "devpts",
        0x794c7630 => "overlayfs",
        0x58465342 => "xfs",
        0x9123683E => "btrfs",
        0x6969 => "nfs",
        0x4d44 => "msdos",
        0x2011BAB0 => "exfat",
        0x5346544e => "ntfs",
        0x73717368 => "squashfs",
        0x858458f6 => "ramfs",
        0x27e0eb => "cgroupfs",
        0x63677270 => "cgroup2fs",
        0x64626720 => "debugfs",
        0x01021997 => "v9fs",
        0x65735546 => "fuseblk",
        0x65735543 => "fusectl",
        0x9660 => "isofs",
        else => "UNKNOWN",
    };
}

const Info = struct {
    st: c.Stat,
    btime: ?c.Ts = null,
    name: []const u8,
    target: ?[]const u8 = null,
};

fn getInfo(path: []const u8, follow: bool) c.SysError!Info {
    var b: [c.PATH_MAX]u8 = undefined;
    const pz = try c.toZ(&b, path);
    var info: Info = .{ .st = undefined, .name = path };
    var sx: linux.Statx = mem.zeroes(linux.Statx);
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(c.AT_FDCWD, pz, flags, linux.STATX_BASIC_STATS | linux.STATX_BTIME, &sx);
    if (std.posix.errno(rc) == .SUCCESS) {
        info.st = try c.sys.fstatat(c.AT_FDCWD, path, !follow);
        if (sx.mask & linux.STATX_BTIME != 0) info.btime = .{ .sec = sx.btime.sec, .nsec = sx.btime.nsec };
    } else {
        info.st = try c.sys.fstatat(c.AT_FDCWD, path, !follow);
    }
    if (info.st.isLnk()) {
        var lb: [c.PATH_MAX]u8 = undefined;
        if (c.sys.readlink(path, &lb)) |t| info.target = c.gpa.dupe(u8, t) catch c.oom() else |_| {}
    }
    return info;
}

pub fn fileType(st: c.Stat) []const u8 {
    return switch (st.mode & c.S_IFMT) {
        c.S_IFREG => if (st.size == 0) "regular empty file" else "regular file",
        c.S_IFDIR => "directory",
        c.S_IFLNK => "symbolic link",
        c.S_IFIFO => "fifo",
        c.S_IFSOCK => "socket",
        c.S_IFCHR => "character special file",
        c.S_IFBLK => "block special file",
        else => "weird file",
    };
}

fn fmtTime(w: *std.Io.Writer, ts: ?c.Ts) !void {
    const t = ts orelse return w.writeAll("-");
    const tm = c.localtime(t.sec);
    try c.strftime(w, "%Y-%m-%d %H:%M:%S.%N %z", tm, t.nsec, t.sec);
}

fn emitField(w: *std.Io.Writer, spec: pf.Spec, s: []const u8) !void {
    var sp = spec;
    sp.conv = 's';
    try pf.fmtString(w, sp, s);
}

fn emitNum(w: *std.Io.Writer, spec: pf.Spec, v: u64) !void {
    var sp = spec;
    sp.conv = 'u';
    try pf.fmtUnsigned(w, sp, v);
}

fn mountPoint(path: []const u8) []const u8 {
    const rp = c.canonicalize(path, .all_exist, true) catch return "?";
    const st = c.sys.stat(rp) catch return "?";
    var cur: []const u8 = rp;
    while (!c.eql(cur, "/")) {
        const parent = c.dirname(cur);
        const ps = c.sys.stat(parent) catch break;
        if (ps.dev != st.dev) break;
        cur = parent;
    }
    return cur;
}

fn fileFormat(w: *std.Io.Writer, f: []const u8, info: Info) !void {
    const st = info.st;
    var i: usize = 0;
    var nb: [64]u8 = undefined;
    while (i < f.len) {
        const ch = f[i];
        if (ch != '%' or i + 1 >= f.len) {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        if (f[i + 1] == '%') {
            try w.writeByte('%');
            i += 2;
            continue;
        }
        const ps = pf.parseSpecEx(f, i + 1, false) orelse {
            try w.writeAll(f[i..]);
            break;
        };
        var spec = ps.spec;
        var conv = spec.conv;
        var end = ps.end;
        var hl: u8 = 0;
        if ((conv == 'H' or conv == 'L') and end < f.len and mem.indexOfScalar(u8, "dr", f[end]) != null) {
            hl = conv;
            conv = f[end];
            end += 1;
        }
        switch (conv) {
            'a' => {
                spec.conv = 'o';
                try pf.fmtUnsigned(w, spec, st.mode & 0o7777);
            },
            'A' => try emitField(w, spec, &c.modeString(st.mode)),
            'b' => try emitNum(w, spec, @intCast(@max(st.blocks, 0))),
            'B' => try emitNum(w, spec, 512),
            'd' => {
                if (hl == 'H') try emitNum(w, spec, c.devMajor(st.dev)) else if (hl == 'L') try emitNum(w, spec, c.devMinor(st.dev)) else try emitNum(w, spec, st.dev);
            },
            'D' => {
                spec.conv = 'x';
                try pf.fmtUnsigned(w, spec, st.dev);
            },
            'f' => {
                spec.conv = 'x';
                try pf.fmtUnsigned(w, spec, st.mode);
            },
            'F' => try emitField(w, spec, fileType(st)),
            'g' => try emitNum(w, spec, st.gid),
            'G' => try emitField(w, spec, c.groupName(&nb, st.gid)),
            'h' => try emitNum(w, spec, st.nlink),
            'i' => try emitNum(w, spec, st.ino),
            'm' => try emitField(w, spec, mountPoint(info.name)),
            'n' => try emitField(w, spec, info.name),
            'N' => {
                if (info.target) |t| {
                    var tmp: std.Io.Writer.Allocating = .init(c.gpa);
                    try tmp.writer.print("{f} -> {f}", .{ c.q(info.name), c.q(t) });
                    try emitField(w, spec, tmp.written());
                } else {
                    var tmp: std.Io.Writer.Allocating = .init(c.gpa);
                    try c.writeQuoted(&tmp.writer, info.name, true);
                    try emitField(w, spec, tmp.written());
                }
            },
            'o' => try emitNum(w, spec, @intCast(@max(st.blksize, 0))),
            's' => try emitNum(w, spec, @intCast(@max(st.size, 0))),
            'r' => {
                if (hl == 'H') try emitNum(w, spec, c.devMajor(st.rdev)) else if (hl == 'L') try emitNum(w, spec, c.devMinor(st.rdev)) else try emitNum(w, spec, st.rdev);
            },
            't' => {
                spec.conv = 'x';
                try pf.fmtUnsigned(w, spec, c.devMajor(st.rdev));
            },
            'T' => {
                spec.conv = 'x';
                try pf.fmtUnsigned(w, spec, c.devMinor(st.rdev));
            },
            'u' => try emitNum(w, spec, st.uid),
            'U' => try emitField(w, spec, c.userName(&nb, st.uid)),
            'w', 'x', 'y', 'z' => {
                var tmp: std.Io.Writer.Allocating = .init(c.gpa);
                const ts: ?c.Ts = switch (conv) {
                    'w' => info.btime,
                    'x' => st.atime,
                    'y' => st.mtime,
                    else => st.ctime,
                };
                try fmtTime(&tmp.writer, ts);
                try emitField(w, spec, tmp.written());
            },
            'W', 'X', 'Y', 'Z' => {
                const ts: ?c.Ts = switch (conv) {
                    'W' => info.btime,
                    'X' => st.atime,
                    'Y' => st.mtime,
                    else => st.ctime,
                };
                if (ts) |t| {
                    spec.conv = 'd';
                    try pf.fmtSigned(w, spec, t.sec);
                } else try emitField(w, spec, "0");
            },
            else => {
                try w.writeAll(f[i..end]);
            },
        }
        i = end;
    }
}

fn fsFormat(w: *std.Io.Writer, f: []const u8, name: []const u8, sf: Statfs) !void {
    var i: usize = 0;
    while (i < f.len) {
        const ch = f[i];
        if (ch != '%' or i + 1 >= f.len) {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        if (f[i + 1] == '%') {
            try w.writeByte('%');
            i += 2;
            continue;
        }
        const ps = pf.parseSpecEx(f, i + 1, false) orelse break;
        var spec = ps.spec;
        switch (spec.conv) {
            'a' => try emitNum(w, spec, sf.bavail),
            'b' => try emitNum(w, spec, sf.blocks),
            'c' => try emitNum(w, spec, sf.files),
            'd' => try emitNum(w, spec, sf.ffree),
            'f' => try emitNum(w, spec, sf.bfree),
            'i' => {
                var b: [32]u8 = undefined;
                const id = (@as(u64, @as(u32, @bitCast(sf.fsid[0]))) << 32) | @as(u32, @bitCast(sf.fsid[1]));
                try emitField(w, spec, c.fmtBuf(&b, "{x}", .{id}));
            },
            'l' => try emitNum(w, spec, @intCast(sf.namelen)),
            'n' => try emitField(w, spec, name),
            's' => try emitNum(w, spec, @intCast(sf.bsize)),
            'S' => try emitNum(w, spec, @intCast(if (sf.frsize != 0) sf.frsize else sf.bsize)),
            't' => {
                spec.conv = 'x';
                try pf.fmtUnsigned(w, spec, @as(u64, @bitCast(sf.type)) & 0xffffffff);
            },
            'T' => try emitField(w, spec, fsTypeName(sf.type)),
            else => try w.writeAll(f[i..ps.end]),
        }
        i = ps.end;
    }
}

fn unescape(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            var tmp: [8]u8 = undefined;
            const r = c.unescapeOne(s[i..], &tmp, false);
            out.appendSlice(c.gpa, r[0]) catch c.oom();
            i += r[1];
        } else {
            out.append(c.gpa, s[i]) catch c.oom();
            i += 1;
        }
    }
    return out.items;
}

pub fn main(args: c.Args) !u8 {
    var follow = false;
    var fs = false;
    var terse = false;
    var format: ?[]const u8 = null;
    var add_nl = true;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "dereference", 'L' }, .{ "file-system", 'f' }, .{ "format", 'c' }, .{ "printf", 0 }, .{ "terse", 't' }, .{ "cached", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'L' => follow = true,
            'f' => fs = true,
            'c' => format = p.arg(),
            't' => terse = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "printf")) {
                format = unescape(p.arg());
                add_nl = false;
            } else if (c.eql(n, "cached")) {
                _ = p.arg();
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (files.items.len == 0) c.missingOperand();
    const w = c.out;
    var status: u8 = 0;
    for (files.items) |f| {
        if (fs) {
            const sf = statfs(f) catch |e| {
                c.warn("cannot read file system information for {f}: {s}", .{ c.q(f), c.strerror(e) });
                status = 1;
                continue;
            };
            const fmt = format orelse if (terse) "%n %i %l %t %s %S %b %f %a %c %d\n" else
                \\  File: "%n"
                \\    ID: %-8i Namelen: %-7l Type: %T
                \\Block size: %-10s Fundamental block size: %S
                \\Blocks: Total: %-10b Free: %-10f Available: %a
                \\Inodes: Total: %-10c Free: %d
                \\
            ;
            try fsFormat(w, fmt, f, sf);
            if (format != null and add_nl) try w.writeByte('\n');
            continue;
        }
        const info = (if (c.eql(f, "-")) blk: {
            const st = c.sys.fstat(0) catch |e| break :blk e;
            break :blk Info{ .st = st, .name = "-" };
        } else getInfo(f, follow)) catch |e| {
            c.warn("cannot statx {f}: {s}", .{ c.q(f), c.strerror(e) });
            status = 1;
            continue;
        };
        if (format) |fmt| {
            try fileFormat(w, fmt, info);
            if (add_nl) try w.writeByte('\n');
            continue;
        }
        if (terse) {
            try fileFormat(w, "%n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o\n", info);
            continue;
        }
        const st = info.st;
        const is_dev = (st.mode & c.S_IFMT) == c.S_IFCHR or (st.mode & c.S_IFMT) == c.S_IFBLK;
        try w.writeAll("  File: ");
        try w.writeAll(info.name);
        if (info.target) |t| try w.print(" -> {s}", .{t});
        try w.writeByte('\n');
        try fileFormat(w, "  Size: %-10s\tBlocks: %-10b IO Block: %-6o %F\n", info);
        if (is_dev) {
            try fileFormat(w, "Device: %Hd,%Ld\tInode: %-11i Links: %-5h Device type: %Hr,%Lr\n", info);
        } else try fileFormat(w, "Device: %Hd,%Ld\tInode: %-11i Links: %h\n", info);
        try fileFormat(w, "Access: (%04a/%10.10A)  Uid: (%5u/%8U)   Gid: (%5g/%8G)\n", info);
        try fileFormat(w, "Access: %x\nModify: %y\nChange: %z\n Birth: %w\n", info);
    }
    return status;
}
