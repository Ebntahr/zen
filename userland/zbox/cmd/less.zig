const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const stty = @import("stty.zig");
const mem = std.mem;

pub const help =
    \\Usage: less [OPTION]... [FILE]...
    \\View FILE(s) one screen at a time (falls back to cat when stdout is not
    \\a terminal).
    \\
    \\  -N, --LINE-NUMBERS     show line numbers
    \\  -S, --chop-long-lines  chop (don't wrap) long lines
    \\  -R, --RAW-CONTROL-CHARS  pass ANSI color escape sequences through
    \\  -F, --quit-if-one-screen  exit if the whole file fits on one screen
    \\  -X, --no-init          don't use the alternate screen
    \\  -E, --QUIT-AT-EOF      exit the first time end-of-file is reached
    \\  -i, --ignore-case      ignore case in searches (unless pattern has capitals)
    \\  -I, --IGNORE-CASE      ignore case in all searches
    \\
    \\Commands:
    \\  SPACE f ^F ^V PgDn  forward one window     b ^B PgUp   backward one window
    \\  ENTER j e ^N Down   forward one line       k y ^P Up   backward one line
    \\  d ^D                forward half window    u ^U        backward half window
    \\  g < Home            go to first line       G > End     go to last line
    \\  /pattern            search forward         ?pattern    search backward
    \\  n                   repeat search          N           repeat search backward
    \\  :n :p               next / previous file   r ^L        repaint
    \\  h                   help                   q Q ZZ      quit
    \\
;
pub const help_more =
    \\Usage: more [options] <file>...
    \\A file perusal filter for CRT viewing (falls back to cat when stdout is
    \\not a terminal).
    \\
    \\Commands: SPACE (next page), ENTER (next line), b (back one page),
    \\/pattern (search), n (next match), q (quit), h (help).
    \\
;

const Doc = struct { name: []const u8, data: []const u8, lines: [][]const u8 };
const Seg = struct { line: u32, start: u32, end: u32 };

var more_mode = false;
var line_numbers = false;
var chop = false;
var raw_ctrl = false;
var quit_one_screen = false;
var no_init = false;
var quit_at_eof = false;
var icase_smart = false;
var icase_all = false;

var tty_in: i32 = 0;
var saved: ?stty.KTermios = null;
var rows: usize = 24;
var cols: usize = 80;
var docs: std.ArrayList(Doc) = .empty;
var cur_doc: usize = 0;
var segs: std.ArrayList(Seg) = .empty;
var top: usize = 0;
var hoff: usize = 0;
var search_re: ?rx.Regex = null;
var search_back = false;
var obuf: std.ArrayList(u8) = .empty;

fn restoreTerm() void {
    if (saved) |t| stty.setattr(tty_in, &t) catch {};
}

fn onSignal(_: i32) callconv(.c) void {
    restoreTerm();
    if (!no_init and !more_mode) _ = c.sys.write(1, "\x1b[?1049l") catch {};
    std.process.exit(130);
}

fn charWidth(line: []const u8, i: usize, col: usize) struct { w: usize, n: usize } {
    const ch = line[i];
    if (ch == '\t') return .{ .w = 8 - col % 8, .n = 1 };
    if (ch == 0x1b and raw_ctrl) {
        var k = i + 1;
        if (k < line.len and line[k] == '[') {
            k += 1;
            while (k < line.len and !(line[k] >= 0x40 and line[k] <= 0x7e)) k += 1;
            return .{ .w = 0, .n = @min(k + 1, line.len) - i };
        }
    }
    if (ch < 0x20 or ch == 0x7f) return .{ .w = 2, .n = 1 };
    if (ch & 0xC0 == 0x80) return .{ .w = 0, .n = 1 };
    return .{ .w = 1, .n = 1 };
}

fn numWidth() usize {
    if (!line_numbers) return 0;
    return 8;
}

fn buildSegs() void {
    segs.clearRetainingCapacity();
    const d = docs.items[cur_doc];
    const avail = if (cols > numWidth() + 1) cols - numWidth() else 1;
    for (d.lines, 0..) |line, li| {
        if (chop) {
            segs.append(c.gpa, .{ .line = @intCast(li), .start = 0, .end = @intCast(line.len) }) catch c.oom();
            continue;
        }
        var start: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const cw = charWidth(line, i, col);
            if (col + cw.w > avail and col > 0) {
                segs.append(c.gpa, .{ .line = @intCast(li), .start = @intCast(start), .end = @intCast(i) }) catch c.oom();
                start = i;
                col = 0;
                continue;
            }
            col += cw.w;
            i += cw.n;
        }
        segs.append(c.gpa, .{ .line = @intCast(li), .start = @intCast(start), .end = @intCast(line.len) }) catch c.oom();
    }
}

fn pageRows() usize {
    return if (rows > 1) rows - 1 else 1;
}

fn maxTop() usize {
    return if (segs.items.len > pageRows()) segs.items.len - pageRows() else 0;
}

fn emit(s: []const u8) void {
    obuf.appendSlice(c.gpa, s) catch c.oom();
}

fn flushOut() void {
    c.sys.writeAll(1, obuf.items) catch {};
    obuf.clearRetainingCapacity();
}

fn inMatch(ranges: []const [2]usize, pos: usize) bool {
    for (ranges) |r| if (pos >= r[0] and pos < r[1]) return true;
    return false;
}

fn drawSeg(s: Seg) void {
    const d = docs.items[cur_doc];
    const line = d.lines[s.line];
    if (line_numbers) {
        var b: [32]u8 = undefined;
        if (s.start == 0) emit(c.fmtBuf(&b, "{d: >7} ", .{s.line + 1})) else emit("        ");
    }
    // search matches in this line
    var ranges: std.ArrayList([2]usize) = .empty;
    defer ranges.deinit(c.gpa);
    if (search_re) |*re| {
        var g: [1]rx.Span = undefined;
        var pos: usize = 0;
        while (pos <= line.len and re.exec(line, pos, &g, .{})) {
            const ms: usize = @intCast(g[0].start);
            const me: usize = @intCast(g[0].end);
            if (me > ms) ranges.append(c.gpa, .{ ms, me }) catch c.oom();
            pos = if (me > ms) me else ms + 1;
        }
    }
    var col: usize = 0;
    var i: usize = s.start;
    var in_hl = false;
    const avail = if (cols > numWidth()) cols - numWidth() else 1;
    var skipped: usize = 0;
    while (i < s.end) {
        const cw = charWidth(line, i, col);
        if (chop) {
            if (skipped < hoff) {
                skipped += cw.w;
                i += cw.n;
                continue;
            }
            if (col + cw.w > avail) break;
        }
        const hl = inMatch(ranges.items, i);
        if (hl != in_hl) {
            emit(if (hl) "\x1b[7m" else "\x1b[27m");
            in_hl = hl;
        }
        const ch = line[i];
        if (ch == '\t') {
            var k: usize = 0;
            while (k < cw.w) : (k += 1) emit(" ");
        } else if (cw.n > 1 or (ch == 0x1b and raw_ctrl)) {
            emit(line[i .. i + cw.n]);
        } else if (ch < 0x20 or ch == 0x7f) {
            emit("\x1b[7m^");
            const b = [1]u8{if (ch == 0x7f) '?' else ch + 64};
            emit(&b);
            emit("\x1b[27m");
        } else emit(line[i .. i + 1]);
        col += cw.w;
        i += cw.n;
    }
    if (in_hl) emit("\x1b[27m");
    if (raw_ctrl) emit("\x1b[0m");
}

fn status(msg: []const u8, reverse: bool) void {
    emit("\x1b[");
    var b: [16]u8 = undefined;
    emit(c.fmtBuf(&b, "{d}", .{rows}));
    emit(";1H\x1b[K");
    if (reverse) emit("\x1b[7m");
    emit(msg);
    if (reverse) emit("\x1b[27m");
}

fn percent() usize {
    const total = segs.items.len;
    if (total == 0) return 100;
    const bottom = @min(top + pageRows(), total);
    return bottom * 100 / total;
}

fn draw(prompt: ?[]const u8) void {
    emit("\x1b[H");
    var r: usize = 0;
    while (r < pageRows()) : (r += 1) {
        const idx = top + r;
        if (idx < segs.items.len) drawSeg(segs.items[idx]) else if (!more_mode) emit("~");
        emit("\x1b[K\r\n");
    }
    const at_end = top + pageRows() >= segs.items.len;
    if (prompt) |p| {
        status(p, false);
    } else if (more_mode) {
        var b: [64]u8 = undefined;
        status(c.fmtBuf(&b, "--More--({d}%)", .{percent()}), true);
    } else if (at_end) {
        var b: [300]u8 = undefined;
        if (docs.items.len > 1 and cur_doc + 1 < docs.items.len) {
            status(c.fmtBuf(&b, "(END) - Next: {s}", .{docs.items[cur_doc + 1].name}), true);
        } else status("(END)", true);
    } else if (top == 0) {
        var b: [300]u8 = undefined;
        if (docs.items.len > 1) {
            status(c.fmtBuf(&b, "{s} (file {d} of {d})", .{ docs.items[cur_doc].name, cur_doc + 1, docs.items.len }), true);
        } else status(docs.items[cur_doc].name, true);
    } else status(":", false);
    flushOut();
}

fn readKey() ?[]const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    const n = c.sys.read(tty_in, S.buf[0..1]) catch return null;
    if (n == 0) return null;
    if (S.buf[0] != 0x1b) return S.buf[0..1];
    // escape sequence: read the rest if available (VMIN=1, so use a short poll)
    var pfd = [1]std.posix.pollfd{.{ .fd = tty_in, .events = std.posix.POLL.IN, .revents = 0 }};
    var len: usize = 1;
    while (len < S.buf.len) {
        const pr = std.posix.poll(&pfd, 30) catch 0;
        if (pr == 0) break;
        const k = c.sys.read(tty_in, S.buf[len .. len + 1]) catch break;
        if (k == 0) break;
        len += 1;
        const last = S.buf[len - 1];
        if (len >= 3 and ((last >= 'A' and last <= 'Z') or last == '~')) break;
        if (len == 2 and last != '[' and last != 'O') break;
    }
    return S.buf[0..len];
}

fn readLine(prompt: []const u8) ?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        emit("\x1b[");
        var b: [16]u8 = undefined;
        emit(c.fmtBuf(&b, "{d}", .{rows}));
        emit(";1H\x1b[K");
        emit(prompt);
        emit(line.items);
        flushOut();
        const k = readKey() orelse return null;
        if (k.len != 1) continue;
        switch (k[0]) {
            '\r', '\n' => return line.items,
            0x1b, 3, 7 => return null,
            0x7f, 8 => {
                if (line.items.len == 0) return null;
                _ = line.pop();
            },
            0x15 => line.clearRetainingCapacity(),
            else => if (k[0] >= 0x20) line.append(c.gpa, k[0]) catch c.oom(),
        }
    }
}

fn hasUpper(s: []const u8) bool {
    for (s) |ch| if (std.ascii.isUpper(ch)) return true;
    return false;
}

fn doSearch(backward: bool, from_next: bool) bool {
    var re = &(search_re orelse return false);
    const d = docs.items[cur_doc];
    if (segs.items.len == 0) return false;
    const cur_line: usize = segs.items[@min(top, segs.items.len - 1)].line;
    var li: isize = @intCast(cur_line);
    const step: isize = if (backward) -1 else 1;
    if (from_next or true) li += step;
    while (li >= 0 and li < d.lines.len) : (li += step) {
        if (re.exec(d.lines[@intCast(li)], 0, null, .{ .longest = false })) {
            // move top to first segment of that line
            for (segs.items, 0..) |s, k| if (s.line == li) {
                top = @min(k, maxTop());
                if (top != k and more_mode) top = k;
                return true;
            };
        }
    }
    return false;
}

fn loadDoc(name: []const u8, fd: i32) !void {
    const data = c.readFdAll(fd) catch |e| {
        c.warn("{s}: {s}", .{ name, c.strerror(e) });
        return;
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < data.len) {
        const e = mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
        var l = data[start..e];
        if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
        try lines.append(c.gpa, l);
        start = e + 1;
    }
    try docs.append(c.gpa, .{ .name = name, .data = data, .lines = lines.items });
}

fn catFallback(files: []const []const u8) !u8 {
    var status_code: u8 = 0;
    for (files) |f| {
        const fd = c.openInput(f) orelse {
            status_code = 1;
            continue;
        };
        defer c.closeInput(fd);
        if (files.len > 1 and more_mode) try c.out.print("::::::::::::::\n{s}\n::::::::::::::\n", .{f});
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = c.sys.read(fd, &buf) catch break;
            if (n == 0) break;
            try c.out.writeAll(buf[0..n]);
        }
    }
    return status_code;
}

fn run(args: c.Args) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "LINE-NUMBERS", 'N' }, .{ "chop-long-lines", 'S' }, .{ "RAW-CONTROL-CHARS", 'R' }, .{ "quit-if-one-screen", 'F' },
        .{ "no-init", 'X' }, .{ "QUIT-AT-EOF", 'E' }, .{ "ignore-case", 'i' }, .{ "IGNORE-CASE", 'I' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'N' => line_numbers = true,
            'S' => chop = true,
            'R', 'r' => raw_ctrl = true,
            'F' => quit_one_screen = true,
            'X' => no_init = true,
            'E', 'e' => quit_at_eof = true,
            'i' => icase_smart = true,
            'I' => icase_all = true,
            'd', 'l', 'f', 'p', 'c', 's', 'u', 'M', 'm', 'q', 'Q', 'K' => {},
            else => p.bad(o),
        },
        .pos => |a| try files.append(c.gpa, a),
        else => p.bad(o),
    };
    if (files.items.len == 0) {
        if (c.isatty(0)) {
            c.warn("missing filename (\"{s} --help\" for help)", .{c.prog});
            return 1;
        }
        try files.append(c.gpa, "-");
    }
    if (!c.isatty(1)) return catFallback(files.items);
    // keyboard
    tty_in = c.sys.open("/dev/tty", c.O_RDONLY, 0) catch blk: {
        if (c.isatty(0)) break :blk 0;
        if (c.isatty(2)) break :blk 2;
        return catFallback(files.items);
    };
    for (files.items) |f| {
        const fd = c.openInput(f) orelse continue;
        defer c.closeInput(fd);
        if (c.sys.fstat(fd)) |st| {
            if (st.isDir()) {
                c.warn("{s} is a directory", .{f});
                continue;
            }
        } else |_| {}
        try loadDoc(if (c.eql(f, "-")) "(standard input)" else f, fd);
    }
    if (docs.items.len == 0) return 1;
    if (c.winSize(1)) |ws| {
        if (ws.row > 1) rows = ws.row;
        if (ws.col > 1) cols = ws.col;
    }
    buildSegs();
    if ((more_mode or quit_one_screen) and segs.items.len <= pageRows() and docs.items.len == 1) {
        c.flush();
        return catFallback(files.items);
    }
    // raw mode
    const t0 = stty.getattr(tty_in) catch return catFallback(files.items);
    saved = t0;
    var t = t0;
    t.lflag &= ~@as(u32, 0o2 | 0o10); // -icanon -echo
    t.cc[6] = 1;
    t.cc[5] = 0;
    stty.setattr(tty_in, &t) catch {};
    c.setSignal(2, onSignal, false);
    c.setSignal(15, onSignal, false);
    defer restoreTerm();
    const use_alt = !no_init and !more_mode;
    if (use_alt) emit("\x1b[?1049h");
    emit("\x1b[H\x1b[2J");
    var count: ?usize = null;
    var msg: ?[]const u8 = null;
    var last_key_z = false;
    main_loop: while (true) {
        if (more_mode and top + pageRows() >= segs.items.len) {
            // last page: show it and leave (like more(1))
            draw("");
            if (cur_doc + 1 < docs.items.len) {
                cur_doc += 1;
                buildSegs();
                top = 0;
                continue;
            }
            break;
        }
        draw(msg);
        msg = null;
        const k = readKey() orelse break;
        const n = count orelse 0;
        const has_count = count != null;
        if (k.len == 1 and std.ascii.isDigit(k[0])) {
            count = (count orelse 0) * 10 + (k[0] - '0');
            continue;
        }
        count = null;
        const page = pageRows();
        var key: u8 = if (k.len == 1) k[0] else 0;
        if (k.len >= 3) {
            key = switch (k[k.len - 1]) {
                'A' => 'k',
                'B' => 'j',
                'H' => 'g',
                'F' => 'G',
                '~' => if (k.len >= 4 and k[2] == '5') 'b' else if (k.len >= 4 and k[2] == '6') ' ' else if (k.len >= 4 and (k[2] == '1' or k[2] == '7')) 'g' else if (k.len >= 4 and (k[2] == '4' or k[2] == '8')) 'G' else 0,
                'C' => 'R',
                'D' => 'L',
                else => 0,
            };
        }
        if (key != 'Z') last_key_z = false;
        switch (key) {
            'q', 'Q' => break :main_loop,
            'Z' => {
                if (last_key_z) break :main_loop;
                last_key_z = true;
            },
            ' ', 'f', 6, 22 => {
                const amt = if (has_count) n else page;
                if (top >= maxTop()) {
                    if (quit_at_eof) break :main_loop;
                    if (more_mode) top = segs.items.len;
                } else top = @min(top + amt, if (more_mode) segs.items.len else maxTop());
            },
            'z' => top = @min(top + (if (has_count) n else page), maxTop()),
            'b', 2, 'w' => top -|= if (has_count) n else page,
            '\r', '\n', 'j', 'e', 14, 5 => {
                if (more_mode) {
                    top = @min(top + (if (has_count) n else 1), segs.items.len);
                } else top = @min(top + (if (has_count) n else 1), maxTop());
            },
            'k', 'y', 16, 25 => top -|= if (has_count) n else 1,
            'd', 4 => top = @min(top + (if (has_count) n else page / 2), maxTop()),
            'u', 21 => top -|= if (has_count) n else page / 2,
            'g', '<' => top = if (has_count and n > 0) blk: {
                for (segs.items, 0..) |s, idx| if (s.line + 1 >= n) break :blk @min(idx, maxTop());
                break :blk maxTop();
            } else 0,
            'G', '>' => top = if (has_count and n > 0) blk: {
                for (segs.items, 0..) |s, idx| if (s.line + 1 >= n) break :blk @min(idx, maxTop());
                break :blk maxTop();
            } else maxTop(),
            'R' => if (chop) {
                hoff += cols / 2;
            },
            'L' => if (chop) {
                hoff -|= cols / 2;
            },
            'r', 12 => emit("\x1b[H\x1b[2J"),
            '/', '?' => {
                const pat = readLine(if (key == '/') "/" else "?") orelse continue;
                if (pat.len > 0) {
                    const ic = icase_all or (icase_smart and !hasUpper(pat));
                    if (search_re) |*old| old.deinit();
                    search_re = rx.Regex.compile(c.gpa, pat, .{ .extended = true, .icase = ic }) catch {
                        search_re = null;
                        msg = "Invalid pattern  (press RETURN)";
                        continue;
                    };
                }
                search_back = key == '?';
                if (!doSearch(search_back, false)) msg = "Pattern not found  (press RETURN)";
            },
            'n' => if (!doSearch(search_back, true)) {
                msg = "Pattern not found  (press RETURN)";
            },
            'N' => if (!doSearch(!search_back, true)) {
                msg = "Pattern not found  (press RETURN)";
            },
            ':' => {
                const cmd = readLine(":") orelse continue;
                if (c.eql(cmd, "n") and cur_doc + 1 < docs.items.len) {
                    cur_doc += 1;
                    buildSegs();
                    top = 0;
                } else if (c.eql(cmd, "p") and cur_doc > 0) {
                    cur_doc -= 1;
                    buildSegs();
                    top = 0;
                } else if (c.eql(cmd, "q")) break :main_loop;
            },
            '=' => {
                var b: [256]u8 = undefined;
                const d = docs.items[cur_doc];
                const line_no = if (segs.items.len > 0) segs.items[@min(top, segs.items.len - 1)].line + 1 else 0;
                msg = c.fmtBuf(&b, "{s} line {d}/{d} byte {d} {d}%", .{ d.name, line_no, d.lines.len, d.data.len, percent() });
                msg = c.gpa.dupe(u8, msg.?) catch c.oom();
            },
            'h', 'H' => {
                emit("\x1b[H\x1b[2J");
                var it = mem.splitScalar(u8, if (more_mode) help_more else help, '\n');
                while (it.next()) |l| {
                    emit(l);
                    emit("\x1b[K\r\n");
                }
                status("Press any key to continue", true);
                flushOut();
                _ = readKey();
                emit("\x1b[H\x1b[2J");
            },
            else => {},
        }
        if (c.winSize(1)) |ws| {
            const nr: usize = if (ws.row > 1) ws.row else rows;
            const nc: usize = if (ws.col > 1) ws.col else cols;
            if (nr != rows or nc != cols) {
                rows = nr;
                cols = nc;
                buildSegs();
                top = @min(top, maxTop());
                emit("\x1b[H\x1b[2J");
            }
        }
    }
    status("", false);
    if (use_alt) emit("\x1b[?1049l") else emit("\r\x1b[K");
    flushOut();
    return 0;
}

pub fn main(args: c.Args) !u8 {
    more_mode = false;
    return run(args);
}

pub fn mainMore(args: c.Args) !u8 {
    more_mode = true;
    return run(args);
}
