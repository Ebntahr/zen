const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const mem = std.mem;

pub const help =
    \\Usage: grep [OPTION]... PATTERNS [FILE]...
    \\Search for PATTERNS in each FILE.
    \\Example: grep -i 'hello world' menu.h main.c
    \\PATTERNS can contain multiple patterns separated by newlines.
    \\
    \\Pattern selection and interpretation:
    \\  -E, --extended-regexp     PATTERNS are extended regular expressions
    \\  -F, --fixed-strings       PATTERNS are strings
    \\  -G, --basic-regexp        PATTERNS are basic regular expressions
    \\  -e, --regexp=PATTERNS     use PATTERNS for matching
    \\  -f, --file=FILE           take PATTERNS from FILE
    \\  -i, --ignore-case         ignore case distinctions in patterns and data
    \\      --no-ignore-case      do not ignore case distinctions (default)
    \\  -w, --word-regexp         match only whole words
    \\  -x, --line-regexp         match only whole lines
    \\  -z, --null-data           a data line ends in 0 byte, not newline
    \\
    \\Miscellaneous:
    \\  -s, --no-messages         suppress error messages
    \\  -v, --invert-match        select non-matching lines
    \\
    \\Output control:
    \\  -m, --max-count=NUM       stop after NUM selected lines
    \\  -b, --byte-offset         print the byte offset with output lines
    \\  -n, --line-number         print line number with output lines
    \\  -H, --with-filename       print file name with output lines
    \\  -h, --no-filename         suppress the file name prefix on output
    \\      --label=LABEL         use LABEL as the standard input file name prefix
    \\  -o, --only-matching       show only nonempty parts of lines that match
    \\  -q, --quiet, --silent     suppress all normal output
    \\  -a, --text                equivalent to --binary-files=text
    \\  -I                        equivalent to --binary-files=without-match
    \\  -r, --recursive           recurse into directories
    \\  -R, --dereference-recursive  likewise, but follow all symlinks
    \\      --include=GLOB        search only files that match GLOB
    \\      --exclude=GLOB        skip files that match GLOB
    \\      --exclude-dir=GLOB    skip directories that match GLOB
    \\  -L, --files-without-match  print only names of FILEs with no selected lines
    \\  -l, --files-with-matches  print only names of FILEs with selected lines
    \\  -c, --count               print only a count of selected lines per FILE
    \\  -T, --initial-tab         make tabs line up (if needed)
    \\  -Z, --null                print 0 byte after FILE name
    \\
    \\Context control:
    \\  -B, --before-context=NUM  print NUM lines of leading context
    \\  -A, --after-context=NUM   print NUM lines of trailing context
    \\  -C, --context=NUM         print NUM lines of output context
    \\  -NUM                      same as --context=NUM
    \\      --group-separator=SEP  print SEP on line between matches with context
    \\      --no-group-separator  do not print separator for matches with context
    \\      --color[=WHEN]        use markers to highlight the matching strings;
    \\                            WHEN is 'always', 'never', or 'auto'
    \\
    \\When FILE is '-', read standard input.  With no FILE, read '.' if
    \\recursive, '-' otherwise.
    \\Exit status is 0 if any line is selected, 1 otherwise;
    \\if any error occurs and -q is not given, the exit status is 2.
    \\
;

const Mode = enum { basic, extended, fixed };
const Binary = enum { binary, text, without_match };

const Opts = struct {
    mode: Mode = .basic,
    icase: bool = false,
    invert: bool = false,
    word: bool = false,
    line: bool = false,
    count: bool = false,
    files_with: bool = false,
    files_without: bool = false,
    only: bool = false,
    quiet: bool = false,
    no_messages: bool = false,
    with_filename: ?bool = null,
    line_number: bool = false,
    byte_offset: bool = false,
    max_count: ?u64 = null,
    before: usize = 0,
    after: usize = 0,
    recursive: bool = false,
    deref: bool = false,
    color: bool = false,
    null_data: bool = false,
    null_after_name: bool = false,
    initial_tab: bool = false,
    binary: Binary = .binary,
    label: []const u8 = "(standard input)",
    group_sep: ?[]const u8 = "--",
    includes: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    exclude_dirs: std.ArrayList([]const u8) = .empty,
};

var o: Opts = .{};
var re: rx.Regex = undefined;
var match_all_empty = false;
var had_error = false;
var any_selected = false;

// Colors (GNU defaults; GREP_COLORS partially honoured)
var col_ms: []const u8 = "01;31";
var col_fn: []const u8 = "35";
var col_ln: []const u8 = "32";
var col_bn: []const u8 = "32";
var col_se: []const u8 = "36";

fn parseGrepColors() void {
    const gc = c.getenv("GREP_COLORS") orelse return;
    var it = mem.splitScalar(u8, gc, ':');
    while (it.next()) |kv| {
        const eq = mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (c.eql(k, "ms") or c.eql(k, "mt")) col_ms = v;
        if (c.eql(k, "fn")) col_fn = v;
        if (c.eql(k, "ln")) col_ln = v;
        if (c.eql(k, "bn")) col_bn = v;
        if (c.eql(k, "se")) col_se = v;
    }
}

fn colored(w: *std.Io.Writer, col: []const u8, s: []const u8) !void {
    if (o.color and col.len > 0) {
        try w.print("\x1b[{s}m\x1b[K{s}\x1b[m\x1b[K", .{ col, s });
    } else try w.writeAll(s);
}

fn sepOut(w: *std.Io.Writer, sep: u8) !void {
    const s = [1]u8{sep};
    try colored(w, col_se, &s);
}

fn escapeFixed(list: *std.ArrayList(u8), p: []const u8) !void {
    for (p) |ch| {
        if (mem.indexOfScalar(u8, ".[]*^$\\", ch) != null) try list.append(c.gpa, '\\');
        try list.append(c.gpa, ch);
    }
}

const Ctx = struct {
    name: []const u8,
    show_name: bool,
    last_printed: u64 = 0, // line number of last printed line (0 = none)
    printed_any: bool = false,
};

var printed_something = false;

fn prefix(w: *std.Io.Writer, ctx: *Ctx, lineno: u64, offset: u64, sep: u8) !void {
    if (ctx.show_name) {
        try colored(w, col_fn, ctx.name);
        if (o.null_after_name) try w.writeByte(0) else try sepOut(w, sep);
    }
    if (o.line_number) {
        var b: [24]u8 = undefined;
        const s = c.fmtBuf(&b, "{d}", .{lineno});
        if (o.initial_tab and s.len < 4) try w.splatByteAll(' ', 4 - s.len);
        try colored(w, col_ln, s);
        try sepOut(w, sep);
    }
    if (o.byte_offset) {
        var b: [24]u8 = undefined;
        try colored(w, col_bn, c.fmtBuf(&b, "{d}", .{offset}));
        try sepOut(w, sep);
    }
    if (o.initial_tab and (ctx.show_name or o.line_number or o.byte_offset)) try w.writeByte('\t');
}

fn eol() u8 {
    return if (o.null_data) 0 else '\n';
}

fn printLine(w: *std.Io.Writer, ctx: *Ctx, line: []const u8, lineno: u64, offset: u64, selected: bool) !void {
    if (o.group_sep != null and (o.before > 0 or o.after > 0)) {
        if (printed_something and ctx.last_printed != 0 and lineno > ctx.last_printed + 1) {
            try colored(w, col_se, o.group_sep.?);
            try w.writeByte('\n');
        } else if (printed_something and ctx.last_printed == 0) {
            try colored(w, col_se, o.group_sep.?);
            try w.writeByte('\n');
        }
    }
    ctx.last_printed = lineno;
    printed_something = true;
    try prefix(w, ctx, lineno, offset, if (selected) ':' else '-');
    if (o.color and selected and !o.invert) {
        var pos: usize = 0;
        var g: [1]rx.Span = undefined;
        var start: usize = 0;
        while (start <= line.len and re.exec(line, start, &g, .{})) {
            const ms: usize = @intCast(g[0].start);
            const me: usize = @intCast(g[0].end);
            if (me == ms) {
                start = me + 1;
                continue;
            }
            try w.writeAll(line[pos..ms]);
            try colored(w, col_ms, line[ms..me]);
            pos = me;
            start = me;
        }
        try w.writeAll(line[pos..]);
    } else try w.writeAll(line);
    try w.writeByte(eol());
}

fn lineMatches(line: []const u8) bool {
    if (match_all_empty) return true;
    return re.exec(line, 0, null, .{ .longest = false });
}

const Held = struct { text: []u8, lineno: u64, offset: u64 };

/// Returns number of selected lines.
fn grepFd(fd: i32, ctx: *Ctx) !u64 {
    var r = c.LineReader.init(fd);
    defer r.deinit();
    r.delim = eol();
    const w = c.out;
    var count: u64 = 0;
    var lineno: u64 = 0;
    var offset: u64 = 0;
    var after_left: usize = 0;
    var ring: std.ArrayList(Held) = .empty;
    defer {
        for (ring.items) |h| c.gpa.free(h.text);
        ring.deinit(c.gpa);
    }
    var binary = false;
    var checked_binary = o.binary == .text;
    const list_mode = o.files_with or o.files_without or o.count or o.quiet;
    while (true) {
        const line = r.next() catch |e| {
            if (!o.no_messages) c.warn("{s}: {s}", .{ ctx.name, c.strerror(e) });
            had_error = true;
            break;
        } orelse break;
        if (!checked_binary) {
            checked_binary = true;
            if (mem.indexOfScalar(u8, r.buf[0..r.end], if (o.null_data) '\n' else 0) != null and !o.null_data) binary = true;
            if (o.null_data) binary = false;
            if (binary and o.binary == .without_match) return 0;
        }
        lineno += 1;
        const line_off = offset;
        offset += line.len + @intFromBool(r.had_delim);
        const m = lineMatches(line) != o.invert;
        if (m) {
            count += 1;
            any_selected = true;
            if (o.quiet) c.exit(0);
            if (list_mode) {
                if (o.files_with or o.files_without) break;
                if (o.max_count) |mc| if (count >= mc) break;
                continue;
            }
            if (binary) {
                c.flush();
                c.eprint("{s}: {s}: binary file matches\n", .{ c.prog, ctx.name });
                return count;
            }
            // flush before-context
            for (ring.items) |h| {
                try printLine(w, ctx, h.text, h.lineno, h.offset, false);
                c.gpa.free(h.text);
            }
            ring.clearRetainingCapacity();
            if (o.only) {
                if (!o.invert) {
                    var g: [1]rx.Span = undefined;
                    var start: usize = 0;
                    while (start <= line.len and re.exec(line, start, &g, .{})) {
                        const ms: usize = @intCast(g[0].start);
                        const me: usize = @intCast(g[0].end);
                        if (me == ms) {
                            start = me + 1;
                            continue;
                        }
                        try prefix(w, ctx, lineno, line_off + ms, ':');
                        try colored(w, col_ms, line[ms..me]);
                        try w.writeByte(eol());
                        start = me;
                    }
                }
            } else try printLine(w, ctx, line, lineno, line_off, true);
            after_left = o.after;
            if (o.max_count) |mc| if (count >= mc) {
                // print trailing context then stop
                while (after_left > 0) : (after_left -= 1) {
                    const l2 = (r.next() catch null) orelse break;
                    lineno += 1;
                    if (!o.only) try printLine(w, ctx, l2, lineno, offset, false);
                    offset += l2.len + @intFromBool(r.had_delim);
                }
                break;
            };
        } else if (!list_mode and !binary) {
            if (after_left > 0) {
                after_left -= 1;
                if (!o.only) try printLine(w, ctx, line, lineno, line_off, false);
            } else if (o.before > 0) {
                if (ring.items.len == o.before) {
                    c.gpa.free(ring.items[0].text);
                    _ = ring.orderedRemove(0);
                }
                try ring.append(c.gpa, .{ .text = try c.gpa.dupe(u8, line), .lineno = lineno, .offset = line_off });
            }
        }
    }
    return count;
}

fn reportFile(ctx: *Ctx, count: u64) !void {
    const w = c.out;
    if (o.count) {
        if (ctx.show_name) {
            try colored(w, col_fn, ctx.name);
            if (o.null_after_name) try w.writeByte(0) else try sepOut(w, ':');
        }
        try w.print("{d}\n", .{count});
    }
    if (o.files_with and count > 0) {
        try colored(w, col_fn, ctx.name);
        try w.writeByte(if (o.null_after_name) 0 else '\n');
    }
    if (o.files_without and count == 0) {
        try colored(w, col_fn, ctx.name);
        try w.writeByte(if (o.null_after_name) 0 else '\n');
    }
}

fn grepPath(path: []const u8, show_name: bool, top: bool) !void {
    if (c.eql(path, "-") and top) {
        var ctx: Ctx = .{ .name = o.label, .show_name = show_name };
        const n = try grepFd(0, &ctx);
        try reportFile(&ctx, n);
        return;
    }
    const st = (if (o.deref or top) c.sys.stat(path) else c.sys.lstat(path)) catch |e| {
        if (!o.no_messages) c.warn("{s}: {s}", .{ path, c.strerror(e) });
        had_error = true;
        return;
    };
    if (st.isLnk()) return; // symlinks skipped during -r recursion
    if (st.isDir()) {
        if (!o.recursive) {
            if (!o.no_messages) c.warn("{s}: Is a directory", .{path});
            had_error = true;
            return;
        }
        if (!top) {
            for (o.exclude_dirs.items) |g| if (c.fnmatch(g, c.basename(path), .{})) return;
        }
        const names = c.readDirNames(path) catch |e| {
            if (!o.no_messages) c.warn("{s}: {s}", .{ path, c.strerror(e) });
            had_error = true;
            return;
        };
        c.sortStrings(names);
        for (names) |n| {
            const full = c.join(path, n);
            defer c.gpa.free(full);
            try grepPath(full, show_name, false);
        }
        return;
    }
    if (!top or o.recursive) {
        const base = c.basename(path);
        if (o.includes.items.len > 0) {
            var ok = false;
            for (o.includes.items) |g| if (c.fnmatch(g, base, .{})) {
                ok = true;
            };
            if (!ok) return;
        }
        for (o.excludes.items) |g| if (c.fnmatch(g, base, .{})) return;
    }
    const fd = c.sys.open(path, c.O_RDONLY, 0) catch |e| {
        if (!o.no_messages) c.warn("{s}: {s}", .{ path, c.strerror(e) });
        had_error = true;
        return;
    };
    defer c.sys.close(fd);
    var ctx: Ctx = .{ .name = path, .show_name = show_name };
    const n = try grepFd(fd, &ctx);
    try reportFile(&ctx, n);
}

fn addPatterns(list: *std.ArrayList([]const u8), s: []const u8) !void {
    var it = mem.splitScalar(u8, s, '\n');
    while (it.next()) |p| try list.append(c.gpa, p);
}

pub fn mainEgrep(args: c.Args) !u8 {
    o.mode = .extended;
    return run(args, true);
}
pub fn mainFgrep(args: c.Args) !u8 {
    o.mode = .fixed;
    return run(args, true);
}
pub fn main(args: c.Args) !u8 {
    return run(args, false);
}

fn run(args: c.Args, preset: bool) !u8 {
    _ = preset;
    c.usage_status = 2;
    var patterns: std.ArrayList([]const u8) = .empty;
    var have_e = false;
    var files: std.ArrayList([]const u8) = .empty;
    var color_when: []const u8 = "never";
    var p = c.Parser.init(args, &.{
        .{ "extended-regexp", 'E' }, .{ "fixed-strings", 'F' },     .{ "basic-regexp", 'G' },
        .{ "perl-regexp", 'P' },     .{ "regexp", 'e' },            .{ "file", 'f' },
        .{ "ignore-case", 'i' },     .{ "no-ignore-case", 0 },      .{ "word-regexp", 'w' },
        .{ "line-regexp", 'x' },     .{ "null-data", 'z' },         .{ "no-messages", 's' },
        .{ "invert-match", 'v' },    .{ "max-count", 'm' },         .{ "byte-offset", 'b' },
        .{ "line-number", 'n' },     .{ "with-filename", 'H' },     .{ "no-filename", 'h' },
        .{ "label", 0 },             .{ "only-matching", 'o' },     .{ "quiet", 'q' },
        .{ "silent", 'q' },          .{ "text", 'a' },              .{ "binary-files", 0 },
        .{ "recursive", 'r' },       .{ "dereference-recursive", 'R' }, .{ "include", 0 },
        .{ "exclude", 0 },           .{ "exclude-dir", 0 },         .{ "files-without-match", 'L' },
        .{ "files-with-matches", 'l' }, .{ "count", 'c' },         .{ "initial-tab", 'T' },
        .{ "null", 'Z' },            .{ "before-context", 'B' },    .{ "after-context", 'A' },
        .{ "context", 'C' },         .{ "color", 0 },               .{ "colour", 0 },
        .{ "group-separator", 0 },   .{ "no-group-separator", 0 },  .{ "line-buffered", 0 },
        .{ "devices", 'D' },         .{ "directories", 'd' },
    });
    var ctx_digits: ?usize = null;
    while (p.next()) |opt| switch (opt) {
        .short => |ch| {
            if (std.ascii.isDigit(ch)) {
                ctx_digits = (ctx_digits orelse 0) * 10 + (ch - '0');
                o.before = ctx_digits.?;
                o.after = ctx_digits.?;
                continue;
            }
            ctx_digits = null;
            switch (ch) {
                'E' => o.mode = .extended,
                'F' => o.mode = .fixed,
                'G' => o.mode = .basic,
                'P' => c.usageErr("Perl matching not supported in this build", .{}),
                'e' => {
                    try addPatterns(&patterns, p.arg());
                    have_e = true;
                },
                'f' => {
                    const fname = p.arg();
                    const data = c.readInput(fname) orelse c.exit(2);
                    var d: []const u8 = data;
                    if (d.len > 0 and d[d.len - 1] == '\n') d = d[0 .. d.len - 1];
                    if (data.len > 0) try addPatterns(&patterns, d);
                    have_e = true;
                },
                'i', 'y' => o.icase = true,
                'w' => o.word = true,
                'x' => o.line = true,
                'z' => o.null_data = true,
                's' => o.no_messages = true,
                'v' => o.invert = true,
                'm' => o.max_count = c.parseUint(p.arg()) orelse c.usageErr("invalid max count", .{}),
                'b' => o.byte_offset = true,
                'n' => o.line_number = true,
                'H' => o.with_filename = true,
                'h' => o.with_filename = false,
                'o' => o.only = true,
                'q' => o.quiet = true,
                'a' => o.binary = .text,
                'I' => o.binary = .without_match,
                'r' => o.recursive = true,
                'R' => {
                    o.recursive = true;
                    o.deref = true;
                },
                'L' => {
                    o.files_without = true;
                    o.files_with = false;
                },
                'l' => {
                    o.files_with = true;
                    o.files_without = false;
                },
                'c' => o.count = true,
                'T' => o.initial_tab = true,
                'Z' => o.null_after_name = true,
                'A' => o.after = c.parseUint(p.arg()) orelse c.usageErr("invalid context length argument", .{}),
                'B' => o.before = c.parseUint(p.arg()) orelse c.usageErr("invalid context length argument", .{}),
                'C' => {
                    const n = c.parseUint(p.arg()) orelse c.usageErr("invalid context length argument", .{});
                    o.before = n;
                    o.after = n;
                },
                'U', 'u' => {},
                'D', 'd' => {
                    const v = p.arg();
                    if (ch == 'd' and c.eql(v, "recurse")) o.recursive = true;
                },
                else => p.bad(opt),
            }
        },
        .long => |name| {
            if (c.eql(name, "no-ignore-case")) o.icase = false else if (c.eql(name, "label")) o.label = p.arg() else if (c.eql(name, "binary-files")) {
                const v = p.arg();
                if (c.eql(v, "text")) o.binary = .text else if (c.eql(v, "without-match")) o.binary = .without_match else if (c.eql(v, "binary")) o.binary = .binary else c.usageErr("unknown binary-files type", .{});
            } else if (c.eql(name, "include")) try o.includes.append(c.gpa, p.arg()) else if (c.eql(name, "exclude")) try o.excludes.append(c.gpa, p.arg()) else if (c.eql(name, "exclude-dir")) try o.exclude_dirs.append(c.gpa, p.arg()) else if (c.eql(name, "color") or c.eql(name, "colour")) {
                color_when = p.optArg() orelse "auto";
            } else if (c.eql(name, "group-separator")) o.group_sep = p.arg() else if (c.eql(name, "no-group-separator")) o.group_sep = null else if (c.eql(name, "line-buffered")) {} else p.bad(opt);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (c.eql(color_when, "always") or c.eql(color_when, "yes") or c.eql(color_when, "force")) {
        o.color = true;
    } else if (c.eql(color_when, "auto") or c.eql(color_when, "tty") or c.eql(color_when, "if-tty")) {
        o.color = c.isatty(1) and !c.eql(c.getenv("TERM") orelse "dumb", "dumb");
    } else if (c.eql(color_when, "never") or c.eql(color_when, "no") or c.eql(color_when, "none")) {
        o.color = false;
    } else c.usageErr("invalid argument {f} for '--color'", .{c.q(color_when)});
    if (o.color) parseGrepColors();

    if (!have_e) {
        if (files.items.len == 0) {
            c.warn("no pattern given", .{});
            c.tryHelp();
            c.exit(2);
        }
        try addPatterns(&patterns, files.orderedRemove(0));
    }
    // Build regex
    var srcs: std.ArrayList([]const u8) = .empty;
    for (patterns.items) |pat| {
        if (o.mode == .fixed) {
            var l: std.ArrayList(u8) = .empty;
            try escapeFixed(&l, pat);
            try srcs.append(c.gpa, l.items);
        } else try srcs.append(c.gpa, pat);
    }
    if (patterns.items.len == 0) {
        // -f /dev/null: matches nothing
        match_all_empty = false;
        re = rx.Regex.compile(c.gpa, "\\(x\\)\\1\\`", .{}) catch unreachable;
    } else {
        re = rx.Regex.compileMulti(c.gpa, srcs.items, .{
            .extended = o.mode == .extended,
            .icase = o.icase,
            .whole_line = o.line,
            .whole_word = o.word,
        }) catch |e| {
            if (e == error.BadPattern) c.fatalCode(2, "{s}", .{rx.err_msg});
            return e;
        };
    }
    const implicit_dot = files.items.len == 0 and o.recursive;
    if (files.items.len == 0 and !o.recursive) try files.append(c.gpa, "-");
    const show_name = o.with_filename orelse (files.items.len > 1 or o.recursive);
    if (implicit_dot) {
        const names = c.readDirNames(".") catch |e| c.fatalCode(2, ".: {s}", .{c.strerror(e)});
        c.sortStrings(names);
        for (names) |n| try grepPath(n, show_name, false);
    } else for (files.items) |f| try grepPath(f, show_name, true);
    c.flush();
    if (had_error and !(o.quiet and any_selected)) return 2;
    return if (any_selected) 0 else 1;
}
