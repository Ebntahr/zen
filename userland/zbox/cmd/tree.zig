const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\usage: tree [-adfFhiprsDC] [-L level] [-P pattern] [-I pattern] [--noreport]
    \\       [--dirsfirst] [--charset=ascii] [--] [directory ...]
    \\  -a            All files are listed.
    \\  -d            List directories only.
    \\  -f            Print the full path prefix for each file.
    \\  -F            Appends '/', '=', '*', '@', '|' or '>' as per ls -F.
    \\  -i            Don't print indentation lines.
    \\  -L level      Descend only level directories deep.
    \\  -P pattern    List only those files that match the pattern given.
    \\  -I pattern    Do not list files that match the given pattern.
    \\  -p            Print the protections for each file.
    \\  -s            Print the size in bytes of each file.
    \\  -h            Print the size in a more human readable way.
    \\  -D            Print the date of last modification.
    \\  -r            Sort files in reverse alphanumeric order.
    \\  -t            Sort files by last modification time.
    \\  -C            Turn colorization on always.
    \\  -n            Turn colorization off always.
    \\  --noreport    Turn off file/directory count at end of tree listing.
    \\  --dirsfirst   List directories before files.
    \\  --charset=X   Use charset X (ascii for plain ASCII lines).
    \\
;

var show_all = false;
var dirs_only = false;
var full_path = false;
var classify = false;
var no_indent = false;
var max_level: ?u64 = null;
var match_pat: ?[]const u8 = null;
var ignore_pat: ?[]const u8 = null;
var show_perms = false;
var show_size = false;
var human = false;
var show_date = false;
var reverse = false;
var by_time = false;
var color = false;
var dirs_first = false;
var ascii = false;
var ndirs: u64 = 0;
var nfiles: u64 = 0;

const Ent = struct { name: []const u8, path: []const u8, st: ?c.Stat, target_st: ?c.Stat };

fn lessThan(_: void, a: Ent, b: Ent) bool {
    if (dirs_first) {
        const ad = isDirEnt(a);
        const bd = isDirEnt(b);
        if (ad != bd) return ad;
    }
    var r: bool = undefined;
    if (by_time) {
        const at = if (a.st) |s| s.mtime else c.Ts{};
        const bt = if (b.st) |s| s.mtime else c.Ts{};
        r = c.Ts.cmp(at, bt) == .gt;
        if (c.Ts.cmp(at, bt) == .eq) r = mem.order(u8, a.name, b.name) == .lt;
    } else r = mem.order(u8, a.name, b.name) == .lt;
    return if (reverse) !r else r;
}

fn isDirEnt(e: Ent) bool {
    const s = e.st orelse return false;
    if (s.isDir()) return true;
    return false;
}

fn colorOf(st: c.Stat) ?[]const u8 {
    return switch (st.mode & c.S_IFMT) {
        c.S_IFDIR => "01;34",
        c.S_IFLNK => "01;36",
        c.S_IFIFO => "33",
        c.S_IFSOCK => "01;35",
        c.S_IFCHR, c.S_IFBLK => "01;33",
        else => if (st.mode & 0o111 != 0) "01;32" else null,
    };
}

fn printEntry(w: *std.Io.Writer, e: Ent) !void {
    if (show_perms or show_size or show_date) {
        try w.writeByte('[');
        var first = true;
        if (show_perms) {
            if (e.st) |s| try w.writeAll(&c.modeString(s.mode));
            first = false;
        }
        if (show_size) {
            if (!first) try w.writeByte(' ');
            var b: [32]u8 = undefined;
            const sz: u64 = if (e.st) |s| @intCast(@max(s.size, 0)) else 0;
            const str = if (human) c.humanSize(&b, sz, false) else c.fmtBuf(&b, "{d}", .{sz});
            try c.padLeft(w, str, if (human) 4 else 11);
            first = false;
        }
        if (show_date) {
            if (!first) try w.writeByte(' ');
            if (e.st) |s| try c.strftime(w, "%b %e %H:%M", c.localtime(s.mtime.sec), 0, s.mtime.sec);
        }
        try w.writeAll("]  ");
    }
    const name = if (full_path) e.path else e.name;
    const col: ?[]const u8 = if (color and e.st != null) colorOf(e.st.?) else null;
    if (col) |cc| {
        try w.print("\x1b[{s}m{s}\x1b[0m", .{ cc, name });
    } else try w.writeAll(name);
    if (e.st) |s| {
        if (s.isLnk()) {
            var lb: [c.PATH_MAX]u8 = undefined;
            if (c.sys.readlink(e.path, &lb)) |t| try w.print(" -> {s}", .{t}) else |_| {}
        }
        if (classify) {
            const ch: ?u8 = switch (s.mode & c.S_IFMT) {
                c.S_IFDIR => '/',
                c.S_IFLNK => if (e.target_st == null) null else '@',
                c.S_IFIFO => '|',
                c.S_IFSOCK => '=',
                else => if (s.mode & 0o111 != 0) '*' else null,
            };
            if (ch) |x| try w.writeByte(x);
        }
    }
    try w.writeByte('\n');
}

fn walk(w: *std.Io.Writer, path: []const u8, prefix: *std.ArrayList(u8), level: u64) !void {
    if (max_level) |ml| if (level >= ml) return;
    const names = c.readDirNames(path) catch return;
    defer c.freeNames(names);
    var ents: std.ArrayList(Ent) = .empty;
    defer {
        for (ents.items) |e| c.gpa.free(e.path);
        ents.deinit(c.gpa);
    }
    for (names) |n| {
        if (!show_all and n.len > 0 and n[0] == '.') continue;
        const full = c.join(path, n);
        const st: ?c.Stat = c.sys.lstat(full) catch null;
        const tst: ?c.Stat = c.sys.stat(full) catch null;
        const is_dir = st != null and st.?.isDir();
        const keep = !(dirs_only and !is_dir) and
            !(if (ignore_pat) |ip| c.fnmatch(ip, n, .{}) else false) and
            !(if (match_pat) |mp| !is_dir and !c.fnmatch(mp, n, .{}) else false);
        if (!keep) {
            c.gpa.free(full);
            continue;
        }
        try ents.append(c.gpa, .{ .name = n, .path = full, .st = st, .target_st = tst });
    }
    std.sort.heap(Ent, ents.items, {}, lessThan);
    const tee = if (ascii) "|-- " else "├── ";
    const ell = if (ascii) "`-- " else "└── ";
    const bar = if (ascii) "|   " else "│   ";
    for (ents.items, 0..) |e, i| {
        const last = i + 1 == ents.items.len;
        if (!no_indent) {
            try w.writeAll(prefix.items);
            try w.writeAll(if (last) ell else tee);
        }
        try printEntry(w, e);
        const is_dir = e.st != null and e.st.?.isDir();
        if (is_dir) {
            ndirs += 1;
            const save = prefix.items.len;
            try prefix.appendSlice(c.gpa, if (last) "    " else bar);
            try walk(w, e.path, prefix, level + 1);
            prefix.shrinkRetainingCapacity(save);
        } else nfiles += 1;
    }
}

pub fn main(args: c.Args) !u8 {
    var noreport = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "noreport", 0 }, .{ "dirsfirst", 0 }, .{ "charset", 0 } });
    color = c.isatty(1);
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => show_all = true,
            'd' => dirs_only = true,
            'f' => full_path = true,
            'F' => classify = true,
            'i' => no_indent = true,
            'L' => {
                const a = p.arg();
                max_level = c.parseUint(a) orelse c.fatal("Invalid level, must be greater than 0.", .{});
                if (max_level.? == 0) c.fatal("Invalid level, must be greater than 0.", .{});
            },
            'P' => match_pat = p.arg(),
            'I' => ignore_pat = p.arg(),
            'p' => show_perms = true,
            's' => show_size = true,
            'h' => {
                human = true;
                show_size = true;
            },
            'D' => show_date = true,
            'r' => reverse = true,
            't' => by_time = true,
            'C' => color = true,
            'n' => color = false,
            'A' => ascii = false,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "noreport")) noreport = true else if (c.eql(n, "dirsfirst")) dirs_first = true else if (c.eql(n, "charset")) {
                const v = p.arg();
                ascii = std.ascii.eqlIgnoreCase(v, "ascii");
            } else p.bad(o);
        },
        .pos => |a| try dirs.append(c.gpa, a),
    };
    if (dirs.items.len == 0) try dirs.append(c.gpa, ".");
    const w = c.out;
    var status: u8 = 0;
    for (dirs.items) |d| {
        const st = c.sys.stat(d) catch {
            try w.print("{s}  [error opening dir]\n", .{d});
            status = 2;
            continue;
        };
        if (color and st.isDir()) try w.print("\x1b[01;34m{s}\x1b[0m\n", .{d}) else try w.print("{s}\n", .{d});
        if (!st.isDir()) {
            nfiles += 1;
            continue;
        }
        var prefix: std.ArrayList(u8) = .empty;
        try walk(w, d, &prefix, 0);
    }
    if (!noreport) {
        try w.print("\n{d} director{s}", .{ ndirs, if (ndirs == 1) "y" else "ies" });
        if (!dirs_only) try w.print(", {d} file{s}", .{ nfiles, if (nfiles == 1) "" else "s" });
        try w.writeByte('\n');
    }
    return status;
}
