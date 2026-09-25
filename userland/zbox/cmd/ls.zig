const std = @import("std");
const c = @import("../common.zig");
const sortcmd = @import("sort.zig");
const mem = std.mem;

pub const help =
    \\Usage: ls [OPTION]... [FILE]...
    \\List information about the FILEs (the current directory by default).
    \\Sort entries alphabetically if none of -cftuvSUX nor --sort is specified.
    \\
    \\  -a, --all                  do not ignore entries starting with .
    \\  -A, --almost-all           do not list implied . and ..
    \\  -B, --ignore-backups       do not list implied entries ending with ~
    \\  -c                         sort by, and show, ctime
    \\  -C                         list entries by columns
    \\      --color[=WHEN]         color the output WHEN ('always', 'auto', 'never');
    \\                               default is 'auto' (color when stdout is a tty)
    \\  -d, --directory            list directories themselves, not their contents
    \\  -f                         list all entries in directory order
    \\  -F, --classify             append indicator (one of */=>@|) to entries
    \\      --full-time            like -l --time-style=full-iso
    \\  -g                         like -l, but do not list owner
    \\      --group-directories-first  group directories before files
    \\  -G, --no-group             in a long listing, don't print group names
    \\  -h, --human-readable       with -l and -s, print sizes like 1K 234M 2G etc.
    \\      --si                   likewise, but use powers of 1000 not 1024
    \\  -H, --dereference-command-line  follow symbolic links listed on the command line
    \\  -i, --inode                print the index number of each file
    \\  -I, --ignore=PATTERN       do not list implied entries matching shell PATTERN
    \\  -k, --kibibytes            default to 1024-byte blocks for file system usage
    \\  -l                         use a long listing format
    \\  -L, --dereference          show information for the file symlinks point to
    \\  -m                         fill width with a comma separated list of entries
    \\  -n, --numeric-uid-gid      like -l, but list numeric user and group IDs
    \\  -N, --literal              print entry names without quoting
    \\  -o                         like -l, but do not list group information
    \\  -p                         append / indicator to directories
    \\  -q, --hide-control-chars   print ? instead of nongraphic characters
    \\  -Q, --quote-name           enclose entry names in double quotes
    \\  -r, --reverse              reverse order while sorting
    \\  -R, --recursive            list subdirectories recursively
    \\  -s, --size                 print the allocated size of each file, in blocks
    \\  -S                         sort by file size, largest first
    \\      --sort=WORD            sort by WORD: none, size, time, version, extension
    \\      --time-style=STYLE     full-iso, long-iso, iso, locale, +FORMAT
    \\  -t                         sort by time, newest first
    \\  -T, --tabsize=COLS         assume tab stops at each COLS instead of 8
    \\  -u                         sort by, and show, access time
    \\  -U                         do not sort; list entries in directory order
    \\  -v                         natural sort of (version) numbers within text
    \\  -w, --width=COLS           set output width to COLS.  0 means no limit
    \\  -x                         list entries by lines instead of by columns
    \\  -X                         sort alphabetically by entry extension
    \\  -1                         list one file per line
    \\
    \\Exit status:
    \\ 0  if OK,
    \\ 1  if minor problems (e.g., cannot access subdirectory),
    \\ 2  if serious trouble (e.g., cannot access command-line argument).
    \\
;

const Format = enum { long, one, columns, across, commas };
const SortBy = enum { name, none, size, time, version, extension };
const TimeKind = enum { mtime, ctime, atime };
const Indicator = enum { none, slash, classify };

var fmt: Format = .one;
var sort_by: SortBy = .name;
var time_kind: TimeKind = .mtime;
var indicator: Indicator = .none;
var show_all = false;
var almost_all = false;
var ignore_backups = false;
var dir_only = false;
var recursive = false;
var reverse = false;
var human = false;
var si = false;
var show_inode = false;
var show_blocks = false;
var numeric_ids = false;
var show_owner = true;
var show_group = true;
var deref = false;
var deref_cmdline = false;
var group_dirs_first = false;
var color = false;
var quote_names = false;
var hide_ctrl = false;
var dquote = false;
var line_width: usize = 80;
var tabsize: usize = 8;
var time_style: []const u8 = "locale";
var ignore_pats: std.ArrayList([]const u8) = .empty;
var status: u8 = 0;
var now_sec: i64 = 0;
var color_started = false;

const Entry = struct {
    name: []const u8,
    path: []const u8,
    st: ?c.Stat,
    target: ?[]const u8 = null,
    target_st: ?c.Stat = null,
    // display cache
    disp: []const u8 = "",
    quoted: bool = false,
};

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

const ColorKey = enum { no, fi, di, ln, pi, so, bd, cd, mi, @"or", ex, su, sg, st, ow, tw };
var colors = std.EnumArray(ColorKey, ?[]const u8).init(.{
    .no = null,
    .fi = null,
    .di = "01;34",
    .ln = "01;36",
    .pi = "33",
    .so = "01;35",
    .bd = "01;33",
    .cd = "01;33",
    .mi = null,
    .@"or" = null,
    .ex = "01;32",
    .su = "37;41",
    .sg = "30;43",
    .st = "37;44",
    .ow = "34;42",
    .tw = "30;42",
});
var ext_colors: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
var ln_target = false;

fn parseLsColors() void {
    const env = c.getenv("LS_COLORS") orelse return;
    var it = mem.splitScalar(u8, env, ':');
    while (it.next()) |kv| {
        const eq = mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (k.len > 1 and k[0] == '*') {
            ext_colors.append(c.gpa, .{ k[1..], v }) catch c.oom();
            continue;
        }
        if (c.eql(k, "ln") and c.eql(v, "target")) {
            ln_target = true;
            continue;
        }
        inline for (std.meta.fields(ColorKey)) |f| {
            if (c.eql(k, f.name)) colors.set(@enumFromInt(f.value), if (v.len == 0 or c.eql(v, "0") or c.eql(v, "00")) null else v);
        }
    }
}

fn colorFor(e: *const Entry, st_opt: ?c.Stat, is_target: bool) ?[]const u8 {
    const st = st_opt orelse return if (is_target) colors.get(.mi) else (colors.get(.mi) orelse colors.get(.fi));
    const m = st.mode;
    switch (m & c.S_IFMT) {
        c.S_IFDIR => {
            if (m & 0o1000 != 0 and m & 0o002 != 0) return colors.get(.tw);
            if (m & 0o002 != 0) return colors.get(.ow);
            if (m & 0o1000 != 0) return colors.get(.st);
            return colors.get(.di);
        },
        c.S_IFLNK => {
            if (!is_target and e.target_st == null) return colors.get(.@"or") orelse colors.get(.ln);
            if (ln_target) return colorFor(e, e.target_st, true);
            return colors.get(.ln);
        },
        c.S_IFIFO => return colors.get(.pi),
        c.S_IFSOCK => return colors.get(.so),
        c.S_IFBLK => return colors.get(.bd),
        c.S_IFCHR => return colors.get(.cd),
        else => {},
    }
    if (m & 0o4000 != 0) if (colors.get(.su)) |x| return x;
    if (m & 0o2000 != 0) if (colors.get(.sg)) |x| return x;
    if (m & 0o111 != 0) if (colors.get(.ex)) |x| return x;
    const name = if (is_target) (e.target orelse e.name) else e.name;
    for (ext_colors.items) |ec| {
        if (name.len >= ec[0].len and std.ascii.eqlIgnoreCase(name[name.len - ec[0].len ..], ec[0])) return ec[1];
    }
    return colors.get(.fi);
}

fn writeColored(w: *std.Io.Writer, col: ?[]const u8, text: []const u8) !void {
    if (color) {
        if (col) |cc| {
            if (!color_started) {
                try w.writeAll("\x1b[0m");
                color_started = true;
            }
            try w.print("\x1b[{s}m", .{cc});
            try w.writeAll(text);
            try w.writeAll("\x1b[0m");
            return;
        }
    }
    try w.writeAll(text);
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

fn makeDisplay(name: []const u8) struct { []const u8, bool } {
    if (dquote) {
        var a: std.Io.Writer.Allocating = .init(c.gpa);
        a.writer.writeByte('"') catch c.oom();
        for (name) |ch| {
            if (ch == '"' or ch == '\\') a.writer.writeByte('\\') catch c.oom();
            a.writer.writeByte(ch) catch c.oom();
        }
        a.writer.writeByte('"') catch c.oom();
        return .{ a.written(), false };
    }
    if (quote_names and needsLsQuote(name)) {
        var a: std.Io.Writer.Allocating = .init(c.gpa);
        c.writeQuoted(&a.writer, name, true) catch c.oom();
        return .{ a.written(), true };
    }
    if (hide_ctrl) {
        var has = false;
        for (name) |ch| if (ch < 0x20 or ch == 0x7f) {
            has = true;
        };
        if (has) {
            const d = c.gpa.dupe(u8, name) catch c.oom();
            for (d) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
                ch.* = '?';
            };
            return .{ d, false };
        }
    }
    return .{ name, false };
}

fn needsLsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch >= 0x80) continue;
        if (mem.indexOfScalar(u8, "%+,-./:=@_^", ch) != null) continue;
        return true;
    }
    if (s[0] == '~' or s[0] == '#') return true;
    return false;
}

fn indicatorChar(e: *const Entry) ?u8 {
    if (indicator == .none) return null;
    const st = e.st orelse return null;
    const m = st.mode;
    switch (m & c.S_IFMT) {
        c.S_IFDIR => return '/',
        else => {},
    }
    if (indicator == .slash) return null;
    return switch (m & c.S_IFMT) {
        c.S_IFLNK => if (fmt == .long) null else '@',
        c.S_IFIFO => '|',
        c.S_IFSOCK => '=',
        c.S_IFREG => if (m & 0o111 != 0) '*' else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

fn entTime(st: ?c.Stat) c.Ts {
    const s = st orelse return .{};
    return switch (time_kind) {
        .mtime => s.mtime,
        .ctime => s.ctime,
        .atime => s.atime,
    };
}

fn extOf(name: []const u8) []const u8 {
    if (mem.lastIndexOfScalar(u8, name, '.')) |i| {
        if (i > 0) return name[i..];
    }
    return "";
}

fn cmpEntries(_: void, a: Entry, b: Entry) bool {
    if (group_dirs_first) {
        const ad = if (a.st) |s| s.isDir() or (a.target_st != null and a.target_st.?.isDir()) else false;
        const bd = if (b.st) |s| s.isDir() or (b.target_st != null and b.target_st.?.isDir()) else false;
        if (ad != bd) return ad;
    }
    var r: i32 = 0;
    switch (sort_by) {
        .name, .none => {},
        .size => {
            const as_: i64 = if (a.st) |s| s.size else 0;
            const bs: i64 = if (b.st) |s| s.size else 0;
            if (as_ != bs) r = if (as_ > bs) -1 else 1;
        },
        .time => {
            const o = c.Ts.cmp(entTime(a.st), entTime(b.st));
            r = switch (o) {
                .gt => -1,
                .lt => 1,
                .eq => 0,
            };
        },
        .version => r = sortcmd.verrevcmp(a.name, b.name),
        .extension => r = switch (mem.order(u8, extOf(a.name), extOf(b.name))) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        },
    }
    if (r == 0) r = switch (mem.order(u8, a.name, b.name)) {
        .lt => -1,
        .gt => 1,
        .eq => 0,
    };
    return if (reverse) r > 0 else r < 0;
}

fn sortEntries(list: []Entry) void {
    if (sort_by == .none) {
        if (reverse) mem.reverse(Entry, list);
        return;
    }
    std.sort.heap(Entry, list, {}, cmpEntries);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn blocksOf(st: ?c.Stat) u64 {
    const s = st orelse return 0;
    return @intCast(@max(s.blocks, 0));
}

fn fmtBlocks(buf: []u8, blocks512: u64) []const u8 {
    if (human or si) return c.humanSize(buf, blocks512 * 512, si);
    return c.fmtBuf(buf, "{d}", .{(blocks512 + 1) / 2});
}

fn nameWidth(e: *const Entry) usize {
    var n = c.displayWidth(e.disp);
    if (indicatorChar(e) != null) n += 1;
    return n;
}

fn prefixWidth(entries: []const Entry) struct { inode: usize, blocks: usize } {
    var iw: usize = 0;
    var bw: usize = 0;
    for (entries) |*e| {
        if (show_inode) iw = @max(iw, c.numLen(if (e.st) |s| s.ino else 0));
        if (show_blocks) {
            var b: [32]u8 = undefined;
            bw = @max(bw, fmtBlocks(&b, blocksOf(e.st)).len);
        }
    }
    return .{ .inode = iw, .blocks = bw };
}

fn writePrefix(w: *std.Io.Writer, e: *const Entry, pw: anytype) !void {
    if (show_inode) {
        if (e.st) |s| try c.padNum(w, s.ino, pw.inode) else try c.padLeft(w, "?", pw.inode);
        try w.writeByte(' ');
    }
    if (show_blocks) {
        var b: [32]u8 = undefined;
        try c.padLeft(w, if (e.st != null) fmtBlocks(&b, blocksOf(e.st)) else "?", pw.blocks);
        try w.writeByte(' ');
    }
}

fn writeName(w: *std.Io.Writer, e: *const Entry, pad_quote: bool) !void {
    if (pad_quote and !e.quoted) try w.writeByte(' ');
    try writeColored(w, if (color) colorFor(e, e.st, false) else null, e.disp);
    if (fmt == .long and e.st != null and e.st.?.isLnk()) {
        if (e.target) |t| {
            try w.writeAll(" -> ");
            const td = makeDisplay(t)[0];
            if (color) {
                try writeColored(w, if (e.target_st != null) colorFor(e, e.target_st, true) else colors.get(.mi), td);
            } else try w.writeAll(td);
            if (indicator == .classify and e.target_st != null) {
                const fake: Entry = .{ .name = t, .path = t, .st = e.target_st };
                if (indicatorChar(&fake)) |ch| try w.writeByte(ch);
            }
        }
    }
    if (indicatorChar(e)) |ch| try w.writeByte(ch);
}

fn indent(w: *std.Io.Writer, from_in: usize, to: usize) !void {
    var from = from_in;
    while (from < to) {
        if (tabsize != 0 and to / tabsize > (from + 1) / tabsize) {
            try w.writeByte('\t');
            from += tabsize - from % tabsize;
        } else {
            try w.writeByte(' ');
            from += 1;
        }
    }
}

fn printColumns(w: *std.Io.Writer, entries: []const Entry, by_columns: bool) !void {
    const n = entries.len;
    if (n == 0) return;
    const pw = prefixWidth(entries);
    const any_quoted = blk: {
        for (entries) |e| if (e.quoted) break :blk true;
        break :blk false;
    };
    var lens = try c.gpa.alloc(usize, n);
    defer c.gpa.free(lens);
    for (entries, 0..) |*e, i| {
        var l = nameWidth(e);
        if (show_inode) l += pw.inode + 1;
        if (show_blocks) l += pw.blocks + 1;
        if (any_quoted and !e.quoted) l += 1;
        lens[i] = l;
    }
    const lw = if (line_width == 0) std.math.maxInt(usize) / 4 else line_width;
    var max_cols = @max(@as(usize, 1), lw / 3);
    if (max_cols > n) max_cols = n;
    // column_info[i] for i+1 columns
    var valid = try c.gpa.alloc(bool, max_cols);
    var line_len = try c.gpa.alloc(usize, max_cols);
    var col_arr = try c.gpa.alloc([]usize, max_cols);
    for (0..max_cols) |i| {
        valid[i] = true;
        line_len[i] = (i + 1) * 3;
        col_arr[i] = try c.gpa.alloc(usize, i + 1);
        @memset(col_arr[i], 3);
    }
    for (0..n) |f| {
        const name_len = lens[f];
        for (0..max_cols) |i| {
            if (!valid[i]) continue;
            const idx = if (by_columns) f / ((n + i) / (i + 1)) else f % (i + 1);
            const real = name_len + (if (idx == i) @as(usize, 0) else 2);
            if (col_arr[i][idx] < real) {
                line_len[i] += real - col_arr[i][idx];
                col_arr[i][idx] = real;
                valid[i] = line_len[i] < lw;
            }
        }
    }
    var cols = max_cols;
    while (cols > 1) : (cols -= 1) if (valid[cols - 1]) break;
    const widths = col_arr[cols - 1];
    if (by_columns) {
        const rows = n / cols + @intFromBool(n % cols != 0);
        for (0..rows) |row| {
            var col: usize = 0;
            var f = row;
            var pos: usize = 0;
            while (true) {
                try writePrefix(w, &entries[f], pw);
                try writeName(w, &entries[f], any_quoted);
                const nl = lens[f];
                const maxw = widths[col];
                col += 1;
                f += rows;
                if (f >= n) break;
                try indent(w, pos + nl, pos + maxw);
                pos += maxw;
            }
            try w.writeByte('\n');
        }
    } else {
        var pos: usize = 0;
        for (0..n) |f| {
            const col = f % cols;
            if (col == 0 and f != 0) {
                try w.writeByte('\n');
                pos = 0;
            }
            try writePrefix(w, &entries[f], pw);
            try writeName(w, &entries[f], any_quoted);
            if (col + 1 < cols and f + 1 < n) {
                try indent(w, pos + lens[f], pos + widths[col]);
                pos += widths[col];
            }
        }
        try w.writeByte('\n');
    }
}

fn printCommas(w: *std.Io.Writer, entries: []const Entry) !void {
    const pw = prefixWidth(entries);
    var pos: usize = 0;
    const lw = if (line_width == 0) std.math.maxInt(usize) / 4 else line_width;
    for (entries, 0..) |*e, i| {
        var l = nameWidth(e);
        if (show_inode) l += pw.inode + 1;
        if (show_blocks) l += pw.blocks + 1;
        if (i > 0) {
            if (!(pos + l + 2 < lw)) {
                try w.writeAll(",\n");
                pos = 0;
            } else {
                try w.writeAll(", ");
                pos += 2;
            }
        }
        try writePrefix(w, e, pw);
        try writeName(w, e, false);
        pos += l;
    }
    if (entries.len > 0) try w.writeByte('\n');
}

fn formatTime(buf: []u8, ts: c.Ts) []const u8 {
    const tm = c.localtime(ts.sec);
    var w: std.Io.Writer = .fixed(buf);
    var style = time_style;
    if (mem.startsWith(u8, style, "posix-")) style = style[6..];
    if (c.eql(style, "full-iso")) {
        c.strftime(&w, "%Y-%m-%d %H:%M:%S.%N %z", tm, ts.nsec, ts.sec) catch {};
    } else if (c.eql(style, "long-iso")) {
        c.strftime(&w, "%Y-%m-%d %H:%M", tm, ts.nsec, ts.sec) catch {};
    } else if (c.eql(style, "iso")) {
        const recent = now_sec - ts.sec < 15778476 and ts.sec <= now_sec + 60;
        c.strftime(&w, if (recent) "%m-%d %H:%M" else "%Y-%m-%d ", tm, ts.nsec, ts.sec) catch {};
    } else if (style.len > 0 and style[0] == '+') {
        var f = style[1..];
        if (mem.indexOfScalar(u8, f, '\n')) |nl| {
            const recent = now_sec - ts.sec < 15778476 and ts.sec <= now_sec + 60;
            f = if (recent) f[nl + 1 ..] else f[0..nl];
        }
        c.strftime(&w, f, tm, ts.nsec, ts.sec) catch {};
    } else {
        const recent = now_sec - ts.sec < 15778476 and ts.sec <= now_sec + 60;
        c.strftime(&w, if (recent) "%b %e %H:%M" else "%b %e  %Y", tm, ts.nsec, ts.sec) catch {};
    }
    return w.buffered();
}

fn printLong(w: *std.Io.Writer, entries: []const Entry) !void {
    var wl: usize = 0;
    var wu: usize = 0;
    var wg: usize = 0;
    var ws: usize = 0;
    var wmaj: usize = 0;
    var wmin: usize = 0;
    const pw = prefixWidth(entries);
    const any_quoted = blk: {
        for (entries) |e| if (e.quoted) break :blk true;
        break :blk false;
    };
    var nb: [64]u8 = undefined;
    for (entries) |*e| {
        const st = e.st orelse continue;
        wl = @max(wl, c.numLen(st.nlink));
        if (show_owner) wu = @max(wu, (if (numeric_ids) c.fmtBuf(&nb, "{d}", .{st.uid}) else c.userName(&nb, st.uid)).len);
        if (show_group) wg = @max(wg, (if (numeric_ids) c.fmtBuf(&nb, "{d}", .{st.gid}) else c.groupName(&nb, st.gid)).len);
        const fmtc = st.mode & c.S_IFMT;
        if (fmtc == c.S_IFCHR or fmtc == c.S_IFBLK) {
            wmaj = @max(wmaj, c.numLen(c.devMajor(st.rdev)));
            wmin = @max(wmin, c.numLen(c.devMinor(st.rdev)));
        } else {
            ws = @max(ws, (if (human or si) c.humanSize(&nb, @intCast(st.size), si) else c.fmtBuf(&nb, "{d}", .{st.size})).len);
        }
    }
    if (wmaj > 0) ws = @max(ws, wmaj + 2 + wmin);
    var wd: usize = 1;
    for (entries) |*e| {
        const st = e.st orelse continue;
        var tb: [128]u8 = undefined;
        wd = @max(wd, formatTime(&tb, entTime(st)).len);
    }
    for (entries) |*e| {
        try writePrefix(w, e, pw);
        const st = e.st orelse {
            // unknown: GNU prints ?'s
            try w.writeAll(if (e.target != null) "l?????????" else "??????????");
            try w.writeByte(' ');
            try c.padLeft(w, "?", wl);
            try w.writeByte(' ');
            if (show_owner) {
                try c.padRight(w, "?", wu);
                try w.writeByte(' ');
            }
            if (show_group) {
                try c.padRight(w, "?", wg);
                try w.writeByte(' ');
            }
            try c.padLeft(w, "?", ws);
            try w.writeByte(' ');
            try c.padLeft(w, "?", wd);
            try w.writeByte(' ');
            try writeName(w, e, any_quoted);
            try w.writeByte('\n');
            continue;
        };
        const ms = c.modeString(st.mode);
        try w.writeAll(&ms);
        try w.writeByte(' ');
        try c.padNum(w, st.nlink, wl);
        try w.writeByte(' ');
        if (show_owner) {
            try c.padRight(w, if (numeric_ids) c.fmtBuf(&nb, "{d}", .{st.uid}) else c.userName(&nb, st.uid), wu);
            try w.writeByte(' ');
        }
        if (show_group) {
            try c.padRight(w, if (numeric_ids) c.fmtBuf(&nb, "{d}", .{st.gid}) else c.groupName(&nb, st.gid), wg);
            try w.writeByte(' ');
        }
        const fmtc = st.mode & c.S_IFMT;
        if (fmtc == c.S_IFCHR or fmtc == c.S_IFBLK) {
            var b1: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            const maj = c.fmtBuf(&b1, "{d}", .{c.devMajor(st.rdev)});
            const min = c.fmtBuf(&b2, "{d}", .{c.devMinor(st.rdev)});
            const total = @max(ws, wmaj + 2 + wmin);
            const pad = total - (wmaj + 2 + wmin);
            try w.splatByteAll(' ', pad);
            try c.padLeft(w, maj, wmaj);
            try w.writeAll(", ");
            try c.padLeft(w, min, wmin);
        } else {
            try c.padLeft(w, if (human or si) c.humanSize(&nb, @intCast(st.size), si) else c.fmtBuf(&nb, "{d}", .{st.size}), ws);
        }
        try w.writeByte(' ');
        var tb: [128]u8 = undefined;
        try w.writeAll(formatTime(&tb, entTime(st)));
        try w.writeByte(' ');
        try writeName(w, e, any_quoted);
        try w.writeByte('\n');
    }
}

fn printEntries(w: *std.Io.Writer, entries: []Entry) !void {
    for (entries) |*e| {
        const d = makeDisplay(e.name);
        e.disp = d[0];
        e.quoted = d[1];
    }
    switch (fmt) {
        .long => try printLong(w, entries),
        .one => {
            const pw = prefixWidth(entries);
            const any_quoted = blk: {
                for (entries) |e| if (e.quoted) break :blk true;
                break :blk false;
            };
            for (entries) |*e| {
                try writePrefix(w, e, pw);
                try writeName(w, e, any_quoted);
                try w.writeByte('\n');
            }
        },
        .columns => try printColumns(w, entries, true),
        .across => try printColumns(w, entries, false),
        .commas => try printCommas(w, entries),
    }
}

// ---------------------------------------------------------------------------
// Gathering
// ---------------------------------------------------------------------------

fn makeEntry(name: []const u8, path: []const u8, follow: bool) ?Entry {
    var e: Entry = .{ .name = name, .path = path, .st = null };
    const st = (if (follow) c.sys.stat(path) else c.sys.lstat(path)) catch {
        return null;
    };
    e.st = st;
    if (st.isLnk()) {
        e.target = readTarget(path);
        e.target_st = c.sys.stat(path) catch null;
    }
    return e;
}

fn readTarget(path: []const u8) ?[]const u8 {
    var buf: [c.PATH_MAX]u8 = undefined;
    const t = c.sys.readlink(path, &buf) catch return null;
    return c.gpa.dupe(u8, t) catch c.oom();
}

fn ignored(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and !show_all and !almost_all) return true;
    if (ignore_backups and name.len > 0 and name[name.len - 1] == '~') return true;
    if (!show_all) for (ignore_pats.items) |pat| if (c.fnmatch(pat, name, .{ .period = false })) return true;
    return false;
}

fn listDir(w: *std.Io.Writer, path: []const u8, print_header: bool, first: *bool) !void {
    const d = c.Dir.open(path) catch |e| {
        c.warn("cannot open directory {f}: {s}", .{ c.q(path), c.strerror(e) });
        status = if (status == 0) 1 else status;
        if (!first.*) {} else first.* = false;
        return;
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| {
            if (!c.eql(e.name, ".") and !c.eql(e.name, "..")) c.gpa.free(e.name);
            c.gpa.free(e.path);
            if (e.target) |t| c.gpa.free(t);
        }
        entries.deinit(c.gpa);
    }
    if (show_all) {
        for ([_][]const u8{ ".", ".." }) |dn| {
            if (makeEntry(dn, c.join(path, dn), deref)) |e| try entries.append(c.gpa, e);
        }
    }
    while (true) {
        const de = d.next() catch |e| {
            c.warn("reading directory {f}: {s}", .{ c.q(path), c.strerror(e) });
            status = 1;
            break;
        } orelse break;
        if (ignored(de.name)) continue;
        const name = try c.gpa.dupe(u8, de.name);
        const full = c.join(path, name);
        if (makeEntry(name, full, deref)) |e| {
            try entries.append(c.gpa, e);
        } else if (deref and fmt != .long and makeEntry(name, full, false) != null) {
            try entries.append(c.gpa, makeEntry(name, full, false).?);
        } else {
            // stat failed (dangling link with -L, permission...): still list name
            const err = if (deref) (if (c.sys.stat(full)) |_| error.ACCES else |x| x) else (if (c.sys.lstat(full)) |_| error.ACCES else |x| x);
            const shown = if (c.eql(path, ".")) name else full;
            c.warn("cannot access {f}: {s}", .{ c.q(shown), c.strerror(err) });
            var ne: Entry = .{ .name = name, .path = full, .st = null };
            if (c.sys.lstat(full)) |lst| {
                if (lst.isLnk()) ne.target = readTarget(full);
            } else |_| {}
            try entries.append(c.gpa, ne);
            status = 1;
        }
    }
    d.close();
    sortEntries(entries.items);
    if (print_header) {
        if (!first.*) try w.writeByte('\n');
        const hd = makeDisplay(path);
        try w.print("{s}:\n", .{hd[0]});
    }
    first.* = false;
    if (fmt == .long or show_blocks) {
        var total: u64 = 0;
        for (entries.items) |e| total += blocksOf(e.st);
        var b: [32]u8 = undefined;
        try w.print("total {s}\n", .{fmtBlocks(&b, total)});
    }
    try printEntries(w, entries.items);
    if (recursive) {
        for (entries.items) |e| {
            const st = e.st orelse continue;
            if (!st.isDir()) continue;
            if (c.eql(e.name, ".") or c.eql(e.name, "..")) continue;
            try listDir(w, e.path, true, first);
        }
    }
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 2;
    const tty = c.isatty(1);
    fmt = if (tty) .columns else .one;
    quote_names = tty;
    hide_ctrl = tty;
    line_width = if (tty) c.termWidth() else 80;
    if (!tty) if (c.getenv("COLUMNS")) |cols| if (c.parseUint(cols)) |n| {
        line_width = @intCast(n);
    };
    var color_when: []const u8 = "auto";
    var files: std.ArrayList([]const u8) = .empty;
    var explicit_fmt = false;
    var p = c.Parser.init(args, &.{
        .{ "all", 'a' },               .{ "almost-all", 'A' },         .{ "ignore-backups", 'B' },
        .{ "color", 0 },               .{ "directory", 'd' },
        .{ "classify", 'F' },          .{ "full-time", 0 },            .{ "group-directories-first", 0 },
        .{ "no-group", 'G' },          .{ "human-readable", 'h' },     .{ "si", 0 },
        .{ "dereference-command-line", 'H' }, .{ "inode", 'i' },       .{ "ignore", 'I' },
        .{ "kibibytes", 'k' },         .{ "dereference", 'L' },        .{ "numeric-uid-gid", 'n' },
        .{ "literal", 'N' },           .{ "hide-control-chars", 'q' }, .{ "quote-name", 'Q' },
        .{ "reverse", 'r' },           .{ "recursive", 'R' },          .{ "size", 's' },
        .{ "sort", 0 },                .{ "time-style", 0 },           .{ "tabsize", 'T' },
        .{ "width", 'w' },             .{ "format", 0 },               .{ "time", 0 },
        .{ "indicator-style", 0 },     .{ "show-control-chars", 0 },   .{ "hide", 0 },
        .{ "file-type", 0 },           .{ "quoting-style", 0 },        .{ "escape", 'b' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => {
                show_all = true;
                almost_all = false;
            },
            'A' => {
                almost_all = true;
                show_all = false;
            },
            'B' => ignore_backups = true,
            'c' => {
                time_kind = .ctime;
            },
            'C' => {
                fmt = .columns;
                explicit_fmt = true;
            },
            'd' => dir_only = true,
            'f' => {
                show_all = true;
                sort_by = .none;
                color_when = "never";
            },
            'F' => indicator = .classify,
            'g' => {
                fmt = .long;
                show_owner = false;
            },
            'G' => show_group = false,
            'h' => human = true,
            'H' => deref_cmdline = true,
            'i' => show_inode = true,
            'I' => try ignore_pats.append(c.gpa, p.arg()),
            'k' => {},
            'l' => fmt = .long,
            'L' => deref = true,
            'm' => fmt = .commas,
            'n' => {
                fmt = .long;
                numeric_ids = true;
            },
            'N' => {
                quote_names = false;
                hide_ctrl = false;
            },
            'o' => {
                fmt = .long;
                show_group = false;
            },
            'p' => indicator = .slash,
            'q' => hide_ctrl = true,
            'Q' => dquote = true,
            'b' => quote_names = true,
            'r' => reverse = true,
            'R' => recursive = true,
            's' => show_blocks = true,
            'S' => sort_by = .size,
            't' => sort_by = .time,
            'T' => tabsize = @intCast(c.parseUint(p.arg()) orelse c.usageErr("invalid tab size", .{})),
            'u' => time_kind = .atime,
            'U' => sort_by = .none,
            'v' => sort_by = .version,
            'w' => {
                const a = p.arg();
                line_width = @intCast(c.parseUint(a) orelse c.fatalCode(2, "invalid line width: {f}", .{c.q(a)}));
            },
            'x' => {
                fmt = .across;
                explicit_fmt = true;
            },
            'X' => sort_by = .extension,
            '1' => fmt = .one,
            'Z' => {},
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "color") or c.eql(name, "colour")) {
                color_when = p.optArg() orelse "always";
            } else if (c.eql(name, "full-time")) {
                fmt = .long;
                time_style = "full-iso";
            } else if (c.eql(name, "group-directories-first")) {
                group_dirs_first = true;
            } else if (c.eql(name, "si")) {
                si = true;
            } else if (c.eql(name, "sort")) {
                const v = p.arg();
                if (c.eql(v, "none")) sort_by = .none else if (c.eql(v, "size")) sort_by = .size else if (c.eql(v, "time")) sort_by = .time else if (c.eql(v, "version")) sort_by = .version else if (c.eql(v, "extension")) sort_by = .extension else if (c.eql(v, "name")) sort_by = .name else c.usageErr("invalid argument {f} for '--sort'", .{c.q(v)});
            } else if (c.eql(name, "time-style")) {
                time_style = p.arg();
            } else if (c.eql(name, "format")) {
                const v = p.arg();
                if (c.eql(v, "long") or c.eql(v, "verbose")) fmt = .long else if (c.eql(v, "single-column")) fmt = .one else if (c.eql(v, "vertical")) fmt = .columns else if (c.eql(v, "across") or c.eql(v, "horizontal")) fmt = .across else if (c.eql(v, "commas")) fmt = .commas else c.usageErr("invalid argument {f} for '--format'", .{c.q(v)});
            } else if (c.eql(name, "time")) {
                const v = p.arg();
                if (c.eql(v, "atime") or c.eql(v, "access") or c.eql(v, "use")) time_kind = .atime else if (c.eql(v, "ctime") or c.eql(v, "status")) time_kind = .ctime else time_kind = .mtime;
            } else if (c.eql(name, "indicator-style")) {
                const v = p.arg();
                if (c.eql(v, "none")) indicator = .none else if (c.eql(v, "slash")) indicator = .slash else indicator = .classify;
            } else if (c.eql(name, "file-type")) {
                indicator = .classify;
            } else if (c.eql(name, "show-control-chars")) {
                hide_ctrl = false;
            } else if (c.eql(name, "hide")) {
                try ignore_pats.append(c.gpa, p.arg());
            } else if (c.eql(name, "quoting-style")) {
                const v = p.arg();
                quote_names = !(c.eql(v, "literal"));
                dquote = c.eql(v, "c") or c.eql(v, "escape");
            } else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    // -c/-u only change sorting when not in long format or with -t
    if ((time_kind != .mtime) and fmt != .long and sort_by == .name) sort_by = .time;
    if (c.eql(color_when, "always") or c.eql(color_when, "yes") or c.eql(color_when, "force")) {
        color = true;
    } else if (c.eql(color_when, "auto") or c.eql(color_when, "tty") or c.eql(color_when, "if-tty")) {
        color = tty and !c.eql(c.getenv("TERM") orelse "", "dumb");
    } else if (c.eql(color_when, "never") or c.eql(color_when, "no") or c.eql(color_when, "none")) {
        color = false;
    } else c.usageErr("invalid argument {f} for '--color'", .{c.q(color_when)});
    if (color) {
        parseLsColors();
        tabsize = 0;
    }
    now_sec = c.now().sec;
    const w = c.out;
    const implicit = files.items.len == 0;
    if (implicit) try files.append(c.gpa, ".");
    var file_entries: std.ArrayList(Entry) = .empty;
    var dir_entries: std.ArrayList(Entry) = .empty;
    const follow_cmd = deref or deref_cmdline or (!dir_only and fmt != .long and indicator != .classify);
    for (files.items) |f| {
        var e = makeEntry(f, f, deref or deref_cmdline) orelse {
            const err = if (deref or deref_cmdline) (if (c.sys.stat(f)) |_| error.ACCES else |x| x) else (if (c.sys.lstat(f)) |_| error.ACCES else |x| x);
            c.warn("cannot access {f}: {s}", .{ c.q(f), c.strerror(err) });
            status = 2;
            continue;
        };
        const st = e.st.?;
        var is_dir = st.isDir();
        if (!is_dir and st.isLnk() and follow_cmd and e.target_st != null and e.target_st.?.isDir()) {
            is_dir = true;
            e.st = e.target_st;
        }
        if (is_dir and !dir_only) try dir_entries.append(c.gpa, e) else try file_entries.append(c.gpa, e);
    }
    sortEntries(file_entries.items);
    sortEntries(dir_entries.items);
    var first = true;
    if (file_entries.items.len > 0) {
        try printEntries(w, file_entries.items);
        first = false;
    }
    const multiple = files.items.len > 1 or recursive;
    for (dir_entries.items) |e| {
        try listDir(w, e.path, multiple and !(implicit and !recursive), &first);
    }
    return status;
}
