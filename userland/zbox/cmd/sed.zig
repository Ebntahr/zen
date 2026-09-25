const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const mem = std.mem;

pub const help =
    \\Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...
    \\
    \\  -n, --quiet, --silent
    \\                 suppress automatic printing of pattern space
    \\  -e script, --expression=script
    \\                 add the script to the commands to be executed
    \\  -f script-file, --file=script-file
    \\                 add the contents of script-file to the commands to be executed
    \\  -i[SUFFIX], --in-place[=SUFFIX]
    \\                 edit files in place (makes backup if SUFFIX supplied)
    \\  -l N, --line-length=N
    \\                 specify the desired line-wrap length for the `l' command
    \\  -E, -r, --regexp-extended
    \\                 use extended regular expressions in the script
    \\  -s, --separate
    \\                 consider files as separate rather than as a single
    \\                 continuous long stream.
    \\  -u, --unbuffered
    \\                 flush output buffers more often
    \\  -z, --null-data
    \\                 separate lines by NUL characters
    \\
    \\Commands: s y a i c d D p P n N g G h H x b t T : = l q Q r R w W z F { } #
    \\Addresses: NUMBER, $, /REGEX/[I], \cREGEXc, FIRST~STEP, ADDR1,+N, ADDR1,~N,
    \\0,/REGEX/, and ! to negate.
    \\
;

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

const AddrKind = enum { none, line, last, re, step, zero, plus, tilde };
const Addr = struct { kind: AddrKind = .none, n: u64 = 0, step: u64 = 0, re: ?*rx.Regex = null };

const ReplPart = union(enum) { lit: []const u8, group: u8, case: u8 };

const Subst = struct {
    re: ?*rx.Regex = null,
    repl: []ReplPart = &.{},
    global: bool = false,
    nth: u64 = 1,
    print: u32 = 0,
    wfile: ?*Out = null,
};

const Cmd = struct {
    a1: Addr = .{},
    a2: Addr = .{},
    negate: bool = false,
    ch: u8,
    text: []const u8 = "",
    num: ?u64 = null,
    jump: usize = 0,
    label: []const u8 = "",
    subst: ?*Subst = null,
    ytab: ?*[256]u8 = null,
    wfile: ?*Out = null,
    rfile: ?*RFile = null,
    active: bool = false,
    end_line: u64 = 0,
};

pub const Out = struct {
    w: *std.Io.Writer,
    missing_nl: bool = false,
    fw: ?*std.fs.File.Writer = null,

    fn emit(o: *Out, text: []const u8, nl: bool) !void {
        if (o.missing_nl) {
            try o.w.writeByte(delim);
            o.missing_nl = false;
        }
        try o.w.writeAll(text);
        if (nl) try o.w.writeByte(delim) else o.missing_nl = true;
        if (unbuffered) try o.w.flush();
    }
};

const RFile = struct { name: []const u8, reader: ?c.LineReader = null, done: bool = false };

const Queued = union(enum) { text: []const u8, file: []const u8, line: []u8 };

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

var quiet = false;
var extended = false;
var separate = false;
var in_place = false;
var in_place_suffix: []const u8 = "";
var unbuffered = false;
var delim: u8 = '\n';
var line_len: usize = 70;
var status: u8 = 0;

var cmds: std.ArrayList(Cmd) = .empty;
var wfiles: std.ArrayList(struct { name: []const u8, out: *Out }) = .empty;
var stdout_out: Out = undefined;
var cur_out: *Out = undefined;
var last_re: ?*rx.Regex = null;

// ---------------------------------------------------------------------------
// Script parsing
// ---------------------------------------------------------------------------

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    block_stack: std.ArrayList(usize) = .empty,

    fn fail(p: *Parser, comptime msg: []const u8, args: anytype) noreturn {
        c.flush();
        var buf: [512]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, msg, args) catch msg;
        c.warn("-e expression #1, char {d}: {s}", .{ @max(p.i, 1), m });
        c.exit(1);
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }
    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }
    fn skipWsNl(p: *Parser) void {
        while (p.i < p.s.len and (std.ascii.isWhitespace(p.s[p.i]) or p.s[p.i] == ';')) p.i += 1;
    }

    fn readNum(p: *Parser) u64 {
        var n: u64 = 0;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) n = n *| 10 +| (p.s[p.i] - '0');
        return n;
    }

    /// Read a delimited section; converts "\<delim>" to "<delim>" and keeps other escapes.
    /// For regexes a newline escape "\n" is kept for the regex engine.
    fn readDelimited(p: *Parser, d: u8, is_regex: bool) ?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch == d) {
                p.i += 1;
                return out.items;
            }
            if (ch == '\\' and p.i + 1 < p.s.len) {
                const nx = p.s[p.i + 1];
                p.i += 2;
                if (nx == d) {
                    out.append(c.gpa, d) catch c.oom();
                } else if (nx == '\n' and is_regex) {
                    out.append(c.gpa, '\n') catch c.oom();
                } else {
                    out.append(c.gpa, '\\') catch c.oom();
                    out.append(c.gpa, nx) catch c.oom();
                }
                continue;
            }
            if (ch == '\n' and is_regex) return null;
            out.append(c.gpa, ch) catch c.oom();
            p.i += 1;
        }
        return null;
    }

    fn compileRe(p: *Parser, src: []const u8, icase: bool) ?*rx.Regex {
        if (src.len == 0) return null; // "last regex"
        const re = c.gpa.create(rx.Regex) catch c.oom();
        re.* = rx.Regex.compile(c.gpa, src, .{ .extended = extended, .icase = icase, .bracket_escapes = true }) catch |e| {
            if (e == error.BadPattern) p.fail("{s}", .{rx.err_msg});
            c.oom();
        };
        return re;
    }

    fn parseAddr(p: *Parser, second: bool) Addr {
        const ch = p.peek() orelse return .{};
        if (std.ascii.isDigit(ch)) {
            const n = p.readNum();
            if (p.peek() == '~' and !second) {
                p.i += 1;
                const st = p.readNum();
                return .{ .kind = .step, .n = n, .step = st };
            }
            if (n == 0 and !second) return .{ .kind = .zero };
            return .{ .kind = .line, .n = n };
        }
        if (ch == '$') {
            p.i += 1;
            return .{ .kind = .last };
        }
        if (second and (ch == '+' or ch == '~')) {
            p.i += 1;
            if (!std.ascii.isDigit(p.peek() orelse 'x')) p.fail("expected newer version of sed", .{});
            const n = p.readNum();
            return .{ .kind = if (ch == '+') .plus else .tilde, .n = n };
        }
        if (ch == '/' or ch == '\\') {
            p.i += 1;
            var d: u8 = '/';
            if (ch == '\\') {
                d = p.peek() orelse p.fail("unexpected end of file", .{});
                p.i += 1;
            }
            const src = p.readDelimited(d, true) orelse p.fail("unterminated address regex", .{});
            var icase = false;
            while (p.peek()) |f| {
                if (f == 'I') {
                    icase = true;
                    p.i += 1;
                } else if (f == 'M') {
                    p.i += 1;
                } else break;
            }
            return .{ .kind = .re, .re = p.compileRe(src, icase) };
        }
        return .{};
    }

    /// Text argument of a, i, c (GNU one-liner and classic forms).
    fn readText(p: *Parser) []const u8 {
        p.skipWs();
        var out: std.ArrayList(u8) = .empty;
        if (p.peek() == '\\') {
            p.i += 1;
            if (p.peek() == '\n') p.i += 1 else p.skipWs();
        }
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch == '\\') {
                if (p.i + 1 < p.s.len) {
                    out.append(c.gpa, p.s[p.i + 1]) catch c.oom();
                    p.i += 2;
                } else p.i += 1;
                continue;
            }
            if (ch == '\n') {
                p.i += 1;
                break;
            }
            out.append(c.gpa, ch) catch c.oom();
            p.i += 1;
        }
        return out.items;
    }

    fn readLabel(p: *Parser, semicolon_ends: bool) []const u8 {
        p.skipWs();
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != '\n' and !(semicolon_ends and p.s[p.i] == ';')) p.i += 1;
        return mem.trimRight(u8, p.s[start..p.i], " \t");
    }

    fn readFilename(p: *Parser) []const u8 {
        p.skipWs();
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
        return p.s[start..p.i];
    }

    fn parseRepl(p: *Parser, d: u8) []ReplPart {
        var parts: std.ArrayList(ReplPart) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        const flushLit = struct {
            fn f(pl: *std.ArrayList(ReplPart), l: *std.ArrayList(u8)) void {
                if (l.items.len > 0) {
                    pl.append(c.gpa, .{ .lit = l.items }) catch c.oom();
                    l.* = .empty;
                }
            }
        }.f;
        while (true) {
            if (p.i >= p.s.len) p.fail("unterminated `s' command", .{});
            const ch = p.s[p.i];
            p.i += 1;
            if (ch == d) break;
            if (ch == '&') {
                flushLit(&parts, &lit);
                parts.append(c.gpa, .{ .group = 0 }) catch c.oom();
                continue;
            }
            if (ch == '\\' and p.i < p.s.len) {
                const nx = p.s[p.i];
                p.i += 1;
                switch (nx) {
                    '0'...'9' => {
                        flushLit(&parts, &lit);
                        parts.append(c.gpa, .{ .group = nx - '0' }) catch c.oom();
                    },
                    'L', 'U', 'l', 'u', 'E' => {
                        flushLit(&parts, &lit);
                        parts.append(c.gpa, .{ .case = nx }) catch c.oom();
                    },
                    'n' => lit.append(c.gpa, '\n') catch c.oom(),
                    't' => lit.append(c.gpa, '\t') catch c.oom(),
                    'r' => lit.append(c.gpa, '\r') catch c.oom(),
                    'a' => lit.append(c.gpa, 7) catch c.oom(),
                    'f' => lit.append(c.gpa, 12) catch c.oom(),
                    'v' => lit.append(c.gpa, 11) catch c.oom(),
                    else => lit.append(c.gpa, nx) catch c.oom(),
                }
                continue;
            }
            lit.append(c.gpa, ch) catch c.oom();
        }
        flushLit(&parts, &lit);
        return parts.items;
    }

    fn getWfile(name: []const u8) *Out {
        for (wfiles.items) |wf| if (c.eql(wf.name, name)) return wf.out;
        const o = c.gpa.create(Out) catch c.oom();
        if (c.eql(name, "/dev/stdout")) {
            return &stdout_out;
        }
        const fd = c.sys.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666) catch |e| {
            c.fatalCode(4, "couldn't open file {s}: {s}", .{ name, c.strerror(e) });
        };
        const fw = c.gpa.create(std.fs.File.Writer) catch c.oom();
        const buf = c.gpa.alloc(u8, 4096) catch c.oom();
        fw.* = (std.fs.File{ .handle = fd }).writerStreaming(buf);
        o.* = .{ .w = &fw.interface, .fw = fw };
        wfiles.append(c.gpa, .{ .name = name, .out = o }) catch c.oom();
        return o;
    }

    fn parse(p: *Parser) void {
        while (true) {
            p.skipWsNl();
            if (p.i >= p.s.len) break;
            if (p.s[p.i] == '#') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
                continue;
            }
            var cmd: Cmd = .{ .ch = 0 };
            cmd.a1 = p.parseAddr(false);
            if (cmd.a1.kind != .none and p.peek() == ',') {
                p.i += 1;
                p.skipWs();
                cmd.a2 = p.parseAddr(true);
                if (cmd.a2.kind == .none) p.fail("unexpected `,'", .{});
            }
            if (cmd.a1.kind == .zero) {
                if (cmd.a2.kind != .re) p.fail("invalid usage of line address 0", .{});
                cmd.active = true;
            }
            p.skipWs();
            while (p.peek() == '!') {
                cmd.negate = true;
                p.i += 1;
                p.skipWs();
            }
            const ch = p.peek() orelse p.fail("missing command", .{});
            p.i += 1;
            cmd.ch = ch;
            switch (ch) {
                '{' => {
                    p.block_stack.append(c.gpa, cmds.items.len) catch c.oom();
                    cmds.append(c.gpa, cmd) catch c.oom();
                    continue;
                },
                '}' => {
                    if (cmd.a1.kind != .none) p.fail("}} doesn't want any addresses", .{});
                    const open = p.block_stack.pop() orelse p.fail("unexpected `}}'", .{});
                    cmds.append(c.gpa, cmd) catch c.oom();
                    cmds.items[open].jump = cmds.items.len;
                },
                '=', 'd', 'D', 'g', 'G', 'h', 'H', 'n', 'N', 'p', 'P', 'x', 'z', 'F' => cmds.append(c.gpa, cmd) catch c.oom(),
                'a', 'i', 'c' => {
                    p.skipWs();
                    if (p.i >= p.s.len) p.fail("expected \\ after `a', `c' or `i'", .{});
                    cmd.text = p.readText();
                    cmds.append(c.gpa, cmd) catch c.oom();
                    continue;
                },
                ':' => {
                    if (cmd.a1.kind != .none) p.fail(": doesn't want any addresses", .{});
                    cmd.label = p.readLabel(true);
                    if (cmd.label.len == 0) p.fail("\":\" lacks a label", .{});
                    cmds.append(c.gpa, cmd) catch c.oom();
                },
                'b', 't', 'T' => {
                    cmd.label = p.readLabel(true);
                    cmds.append(c.gpa, cmd) catch c.oom();
                },
                'r' => {
                    cmd.text = p.readFilename();
                    cmds.append(c.gpa, cmd) catch c.oom();
                    continue;
                },
                'R' => {
                    cmd.text = p.readFilename();
                    const rf = c.gpa.create(RFile) catch c.oom();
                    rf.* = .{ .name = cmd.text };
                    cmd.rfile = rf;
                    cmds.append(c.gpa, cmd) catch c.oom();
                    continue;
                },
                'w', 'W' => {
                    cmd.text = p.readFilename();
                    if (cmd.text.len == 0) p.fail("missing filename in r/R/w/W commands", .{});
                    cmd.wfile = getWfile(cmd.text);
                    cmds.append(c.gpa, cmd) catch c.oom();
                    continue;
                },
                'q', 'Q', 'l', 'L' => {
                    p.skipWs();
                    if (p.peek() != null and std.ascii.isDigit(p.peek().?)) cmd.num = p.readNum();
                    cmds.append(c.gpa, cmd) catch c.oom();
                },
                's' => {
                    const d = p.peek() orelse p.fail("unterminated `s' command", .{});
                    if (d == '\n' or d == '\\') p.fail("unterminated `s' command", .{});
                    p.i += 1;
                    const src = p.readDelimited(d, true) orelse p.fail("unterminated `s' command", .{});
                    const sub = c.gpa.create(Subst) catch c.oom();
                    sub.* = .{};
                    sub.repl = p.parseRepl(d);
                    var icase = false;
                    var have_n = false;
                    while (p.peek()) |f| {
                        switch (f) {
                            'g' => sub.global = true,
                            'p' => sub.print += 1,
                            'i', 'I' => icase = true,
                            'm', 'M' => {},
                            'e' => p.fail("the `e' command is not supported", .{}),
                            '0'...'9' => {
                                if (have_n) p.fail("multiple number options to `s' command", .{});
                                have_n = true;
                                sub.nth = p.readNum();
                                if (sub.nth == 0) p.fail("number option to `s' command may not be zero", .{});
                                continue;
                            },
                            'w' => {
                                p.i += 1;
                                const fname = p.readFilename();
                                sub.wfile = getWfile(fname);
                                break;
                            },
                            else => break,
                        }
                        p.i += 1;
                    }
                    sub.re = p.compileRe(src, icase);
                    cmd.subst = sub;
                    cmds.append(c.gpa, cmd) catch c.oom();
                },
                'y' => {
                    const d = p.peek() orelse p.fail("unterminated `y' command", .{});
                    p.i += 1;
                    const a = p.readDelimited(d, false) orelse p.fail("unterminated `y' command", .{});
                    const b = p.readDelimited(d, false) orelse p.fail("unterminated `y' command", .{});
                    const ua = unescapeY(a);
                    const ub = unescapeY(b);
                    if (ua.len != ub.len) p.fail("strings for `y' command are different lengths", .{});
                    const tab = c.gpa.create([256]u8) catch c.oom();
                    for (tab, 0..) |*t, k| t.* = @intCast(k);
                    for (ua, ub) |x, y| tab[x] = y;
                    cmd.ytab = tab;
                    cmds.append(c.gpa, cmd) catch c.oom();
                },
                else => p.fail("unknown command: `{c}'", .{ch}),
            }
            // after a command: only spaces, ';', newline, '}' or '#'
            p.skipWs();
            if (p.peek()) |nx| {
                if (nx != ';' and nx != '\n' and nx != '}' and nx != '#') p.fail("extra characters after command", .{});
            }
        }
        if (p.block_stack.items.len > 0) p.fail("unmatched `{{'", .{});
        // resolve labels
        for (cmds.items, 0..) |*cm, idx| {
            _ = idx;
            if (cm.ch == 'b' or cm.ch == 't' or cm.ch == 'T') {
                if (cm.label.len == 0) {
                    cm.jump = cmds.items.len;
                } else {
                    var found = false;
                    for (cmds.items, 0..) |other, k| {
                        if (other.ch == ':' and c.eql(other.label, cm.label)) {
                            cm.jump = k;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        c.warn("-e expression #1, char 0: can't find label for jump to `{s}'", .{cm.label});
                        c.exit(1);
                    }
                }
            }
        }
    }
};

fn unescapeY(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            const ch: u8 = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => s[i],
            };
            out.append(c.gpa, ch) catch c.oom();
        } else out.append(c.gpa, s[i]) catch c.oom();
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const Line = struct {
    buf: std.ArrayList(u8) = .empty,
    nl: bool = true,
    file: usize = 0,
    valid: bool = false,
};

const Input = struct {
    files: []const []const u8,
    next_file: usize = 0,
    reader: ?c.LineReader = null,
    reader_file: usize = 0,
    fd: i32 = -1,
    pending: Line = .{},

    fn closeReader(in: *Input) void {
        if (in.reader) |*r| {
            r.deinit();
            c.closeInput(in.fd);
            in.reader = null;
        }
    }

    fn readFromCurrent(in: *Input, dst: *Line) bool {
        const r = &(in.reader orelse return false);
        const line = r.next() catch |e| {
            c.warn("read error on {s}: {s}", .{ in.files[in.reader_file], c.strerror(e) });
            status = 2;
            in.closeReader();
            return false;
        };
        if (line) |l| {
            dst.buf.clearRetainingCapacity();
            dst.buf.appendSlice(c.gpa, l) catch c.oom();
            dst.nl = r.had_delim;
            dst.file = in.reader_file;
            dst.valid = true;
            return true;
        }
        in.closeReader();
        return false;
    }

    fn readRaw(in: *Input, dst: *Line) bool {
        while (true) {
            if (in.reader == null) {
                if (in.next_file >= in.files.len) return false;
                const name = in.files[in.next_file];
                in.next_file += 1;
                if (c.eql(name, "-") and !in_place) {
                    in.fd = 0;
                } else {
                    const fd = c.sys.open(name, c.O_RDONLY, 0) catch |e| {
                        c.warn("can't read {s}: {s}", .{ name, c.strerror(e) });
                        status = 2;
                        continue;
                    };
                    if (c.sys.fstat(fd)) |st| {
                        if (st.isDir()) {
                            if (in_place) c.warn("couldn't edit {s}: not a regular file", .{name}) else c.warn("read error on {s}: Is a directory", .{name});
                            status = if (in_place) 4 else 2;
                            c.sys.close(fd);
                            continue;
                        }
                    } else |_| {}
                    in.fd = fd;
                }
                var lr = c.LineReader.init(in.fd);
                lr.delim = delim;
                in.reader = lr;
                in.reader_file = in.next_file - 1;
            }
            if (in.readFromCurrent(dst)) return true;
        }
    }

    /// Load the next line into cur. Returns null at end of input, else whether it is the last line.
    fn get(in: *Input, cur: *Line) ?bool {
        if (!in.pending.valid) {
            if (!in.readRaw(&in.pending)) return null;
        }
        std.mem.swap(Line, cur, &in.pending);
        in.pending.valid = false;
        if (separate) {
            if (in.reader != null and in.reader_file == cur.file) _ = in.readFromCurrent(&in.pending);
        } else {
            _ = in.readRaw(&in.pending);
        }
        return !in.pending.valid;
    }

    fn peekLast(in: *Input) bool {
        return !in.pending.valid;
    }
};

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

var ps: std.ArrayList(u8) = .empty;
var hs: std.ArrayList(u8) = .empty;
var lineno: u64 = 0;
var is_last = false;
var cur_line: Line = .{};
var append_queue: std.ArrayList(Queued) = .empty;
var tflag = false;
var input: Input = undefined;
var quit_code: ?u8 = null;

// in-place state
var ip_file: ?usize = null;
var ip_tmp: []u8 = "";
var ip_fd: i32 = -1;
var ip_fw: std.fs.File.Writer = undefined;
var ip_buf: [8192]u8 = undefined;
var ip_out: Out = undefined;

fn beginInPlace(file_idx: usize) void {
    const name = input.files[file_idx];
    const dir = c.dirname(name);
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        var nb: [64]u8 = undefined;
        var rnd: [4]u8 = undefined;
        std.crypto.random.bytes(&rnd);
        const base = c.fmtBuf(&nb, "sed{x:0>8}", .{mem.readInt(u32, &rnd, .little)});
        ip_tmp = c.join(dir, base);
        ip_fd = c.sys.open(ip_tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600) catch |e| {
            if (e == error.EXIST) continue;
            c.fatalCode(4, "couldn't open temporary file {s}: {s}", .{ ip_tmp, c.strerror(e) });
        };
        break;
    }
    ip_fw = (std.fs.File{ .handle = ip_fd }).writerStreaming(&ip_buf);
    ip_out = .{ .w = &ip_fw.interface };
    cur_out = &ip_out;
    ip_file = file_idx;
}

fn endInPlace() void {
    const idx = ip_file orelse return;
    const name = input.files[idx];
    ip_out.w.flush() catch {};
    if (c.sys.stat(name)) |st| {
        c.sys.fchmod(ip_fd, st.mode & 0o7777) catch {};
        c.sys.fchown(ip_fd, st.uid, st.gid) catch {};
    } else |_| {}
    c.sys.close(ip_fd);
    if (in_place_suffix.len > 0) {
        var bname: []const u8 = undefined;
        if (mem.indexOfScalar(u8, in_place_suffix, '*') != null) {
            const b = mem.replaceOwned(u8, c.gpa, in_place_suffix, "*", c.basename(name)) catch c.oom();
            bname = if (mem.indexOfScalar(u8, b, '/') != null) b else c.join(c.dirname(name), b);
        } else bname = mem.concat(c.gpa, u8, &.{ name, in_place_suffix }) catch c.oom();
        c.sys.link(name, bname) catch {
            c.sys.rename(name, bname) catch {};
        };
        c.sys.unlink(bname) catch {};
        c.sys.link(name, bname) catch {};
    }
    c.sys.rename(ip_tmp, name) catch |e| c.warn("cannot rename {s}: {s}", .{ ip_tmp, c.strerror(e) });
    ip_file = null;
    cur_out = &stdout_out;
}

fn regexFor(re: ?*rx.Regex) *rx.Regex {
    if (re) |r| {
        last_re = r;
        return r;
    }
    return last_re orelse c.fatal("no previous regular expression", .{});
}

fn matchRe(re: ?*rx.Regex) bool {
    const r = regexFor(re);
    return r.exec(ps.items, 0, null, .{ .longest = false });
}

fn match1(a: Addr) bool {
    return switch (a.kind) {
        .none => true,
        .line => lineno == a.n,
        .last => is_last,
        .re => matchRe(a.re),
        .step => if (a.step == 0) lineno == a.n else (lineno >= a.n and (lineno - a.n) % a.step == 0),
        .zero => false,
        .plus, .tilde => false,
    };
}

fn selected(cmd: *Cmd) bool {
    var r: bool = undefined;
    if (cmd.a1.kind == .none) {
        r = true;
    } else if (cmd.a2.kind == .none) {
        r = match1(cmd.a1);
    } else if (cmd.active) {
        r = true;
        switch (cmd.a2.kind) {
            .line => {
                if (lineno >= cmd.a2.n) cmd.active = false;
                if (lineno > cmd.a2.n and cmd.a1.kind != .zero) r = false;
            },
            .last => if (is_last) {
                cmd.active = false;
            },
            .re => if (matchRe(cmd.a2.re)) {
                cmd.active = false;
            },
            .plus => if (lineno >= cmd.end_line) {
                cmd.active = false;
            },
            .tilde => if (cmd.a2.n == 0 or lineno % cmd.a2.n == 0) {
                cmd.active = false;
            },
            else => cmd.active = false,
        }
    } else if (match1(cmd.a1)) {
        r = true;
        cmd.active = true;
        switch (cmd.a2.kind) {
            .line => if (cmd.a2.n <= lineno) {
                cmd.active = false;
            },
            .plus => {
                cmd.end_line = lineno + cmd.a2.n;
                if (cmd.a2.n == 0) cmd.active = false;
            },
            .tilde => if (cmd.a2.n == 0 or lineno % cmd.a2.n == 0) {
                cmd.active = false;
            },
            .last => if (is_last) {
                cmd.active = false;
            },
            else => {},
        }
    } else r = false;
    return r != cmd.negate;
}

fn flushAppends() !void {
    for (append_queue.items) |q| switch (q) {
        .text => |t| try cur_out.emit(t, true),
        .line => |l| try cur_out.emit(l, true),
        .file => |f| {
            const fd = c.sys.open(f, c.O_RDONLY, 0) catch continue;
            defer c.sys.close(fd);
            const data = c.readFdAll(fd) catch continue;
            if (data.len > 0) {
                if (cur_out.missing_nl) {
                    try cur_out.w.writeByte(delim);
                    cur_out.missing_nl = false;
                }
                try cur_out.w.writeAll(data);
            }
        },
    };
    append_queue.clearRetainingCapacity();
}

fn listLine(o: *Out, width_in: usize) !void {
    const w = o.w;
    if (o.missing_nl) {
        try w.writeByte(delim);
        o.missing_nl = false;
    }
    const width = if (width_in <= 1) 0 else width_in;
    var col: usize = 0;
    for (ps.items) |ch| {
        var b: [8]u8 = undefined;
        const rep: []const u8 = switch (ch) {
            '\\' => "\\\\",
            7 => "\\a",
            8 => "\\b",
            12 => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            11 => "\\v",
            else => if (ch >= 0x20 and ch < 0x7f) blk: {
                b[0] = ch;
                break :blk b[0..1];
            } else c.fmtBuf(&b, "\\{o:0>3}", .{ch}),
        };
        if (width > 0 and col + rep.len > width - 1) {
            try w.writeAll("\\\n");
            col = 0;
        }
        try w.writeAll(rep);
        col += rep.len;
    }
    try w.writeAll("$\n");
}

fn appendRepl(dst: *std.ArrayList(u8), parts: []const ReplPart, text: []const u8, g: []const rx.Span) !void {
    var mode: u8 = 0; // 'L' or 'U' or 0
    var one: u8 = 0; // 'l' or 'u' or 0
    for (parts) |part| {
        var s: []const u8 = undefined;
        switch (part) {
            .case => |cs| {
                switch (cs) {
                    'L', 'U' => {
                        mode = cs;
                        one = 0;
                    },
                    'E' => {
                        mode = 0;
                        one = 0;
                    },
                    else => one = cs,
                }
                continue;
            },
            .lit => |l| s = l,
            .group => |k| {
                if (k >= g.len or g[k].start < 0) continue;
                s = text[@intCast(g[k].start)..@intCast(g[k].end)];
            },
        }
        for (s) |ch_in| {
            var ch = ch_in;
            if (mode == 'L') ch = std.ascii.toLower(ch) else if (mode == 'U') ch = std.ascii.toUpper(ch);
            if (one != 0) {
                ch = if (one == 'l') std.ascii.toLower(ch) else std.ascii.toUpper(ch);
                one = 0;
            }
            try dst.append(c.gpa, ch);
        }
    }
}

fn substitute(sub: *Subst) !bool {
    const re = regexFor(sub.re);
    var groups: [10]rx.Span = undefined;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(c.gpa);
    const text = ps.items;
    var pos: usize = 0;
    var count: u64 = 0;
    var did = false;
    var prev_end: ?usize = null;
    while (pos <= text.len) {
        if (!re.exec(text, pos, &groups, .{})) break;
        const ms: usize = @intCast(groups[0].start);
        const me: usize = @intCast(groups[0].end);
        if (ms == me and prev_end != null and ms == prev_end.?) {
            // empty match right after previous match: skip one char
            if (ms < text.len) try result.append(c.gpa, text[ms]);
            pos = ms + 1;
            prev_end = null;
            continue;
        }
        count += 1;
        try result.appendSlice(c.gpa, text[pos..ms]);
        if (count >= sub.nth) {
            try appendRepl(&result, sub.repl, text, &groups);
            did = true;
        } else try result.appendSlice(c.gpa, text[ms..me]);
        prev_end = me;
        if (ms == me) {
            if (ms < text.len) try result.append(c.gpa, text[ms]);
            pos = ms + 1;
        } else pos = me;
        if (did and !sub.global) break;
    }
    if (!did) return false;
    if (pos < text.len) try result.appendSlice(c.gpa, text[pos..]);
    ps.clearRetainingCapacity();
    try ps.appendSlice(c.gpa, result.items);
    return true;
}

fn readNext(cur: *Line) ?bool {
    const r = input.get(cur) orelse return null;
    if (cur.file != (ip_file orelse std.math.maxInt(usize)) and in_place) {
        endInPlace();
        beginInPlace(cur.file);
        lineno = 0;
    } else if (separate and lineno > 0 and cur.file != cur_file_idx) {
        lineno = 0;
    }
    cur_file_idx = cur.file;
    lineno += 1;
    return r;
}
var cur_file_idx: usize = 0;

fn endCycleOutput() !void {
    if (!quiet) try cur_out.emit(ps.items, cur_line.nl);
    try flushAppends();
}

fn runScript() !void {
    var restart_without_read = false;
    cycle: while (true) {
        if (!restart_without_read) {
            is_last = readNext(&cur_line) orelse break;
            ps.clearRetainingCapacity();
            try ps.appendSlice(c.gpa, cur_line.buf.items);
            tflag = false;
        }
        restart_without_read = false;
        var pc: usize = 0;
        while (pc < cmds.items.len) {
            const cmd = &cmds.items[pc];
            if (cmd.ch == '}' or cmd.ch == ':') {
                pc += 1;
                continue;
            }
            if (!selected(cmd)) {
                pc = if (cmd.ch == '{') cmd.jump else pc + 1;
                continue;
            }
            pc += 1;
            switch (cmd.ch) {
                '{' => {},
                '=' => {
                    var b: [24]u8 = undefined;
                    try cur_out.emit(c.fmtBuf(&b, "{d}", .{lineno}), true);
                },
                'a' => try append_queue.append(c.gpa, .{ .text = cmd.text }),
                'i' => try cur_out.emit(cmd.text, true),
                'c' => {
                    if (cmd.a2.kind == .none or !cmd.active or cmd.negate) try cur_out.emit(cmd.text, true);
                    try flushAppends();
                    continue :cycle;
                },
                'd' => {
                    try flushAppends();
                    continue :cycle;
                },
                'D' => {
                    if (mem.indexOfScalar(u8, ps.items, '\n')) |nl| {
                        const rest_len = ps.items.len - nl - 1;
                        mem.copyForwards(u8, ps.items[0..rest_len], ps.items[nl + 1 ..]);
                        ps.shrinkRetainingCapacity(rest_len);
                        try flushAppends();
                        restart_without_read = true;
                        continue :cycle;
                    }
                    try flushAppends();
                    continue :cycle;
                },
                'g' => {
                    ps.clearRetainingCapacity();
                    try ps.appendSlice(c.gpa, hs.items);
                },
                'G' => {
                    try ps.append(c.gpa, '\n');
                    try ps.appendSlice(c.gpa, hs.items);
                },
                'h' => {
                    hs.clearRetainingCapacity();
                    try hs.appendSlice(c.gpa, ps.items);
                },
                'H' => {
                    try hs.append(c.gpa, '\n');
                    try hs.appendSlice(c.gpa, ps.items);
                },
                'x' => mem.swap(std.ArrayList(u8), &ps, &hs),
                'l' => try listLine(cur_out, cmd.num orelse line_len),
                'n' => {
                    if (input.peekLast() and is_last) {
                        // no next line: end like normal (autoprint) and quit
                        if (!quiet) try cur_out.emit(ps.items, cur_line.nl);
                        try flushAppends();
                        return;
                    }
                    if (!quiet) try cur_out.emit(ps.items, cur_line.nl);
                    try flushAppends();
                    is_last = readNext(&cur_line) orelse return;
                    ps.clearRetainingCapacity();
                    try ps.appendSlice(c.gpa, cur_line.buf.items);
                },
                'N' => {
                    if (is_last) {
                        if (!quiet) try cur_out.emit(ps.items, cur_line.nl);
                        try flushAppends();
                        return;
                    }
                    try flushAppends();
                    is_last = readNext(&cur_line) orelse return;
                    try ps.append(c.gpa, '\n');
                    try ps.appendSlice(c.gpa, cur_line.buf.items);
                },
                'p' => try cur_out.emit(ps.items, true),
                'P' => {
                    const e = mem.indexOfScalar(u8, ps.items, '\n') orelse ps.items.len;
                    try cur_out.emit(ps.items[0..e], true);
                },
                'q' => {
                    try endCycleOutput();
                    quit_code = @intCast(@min(cmd.num orelse 0, 255));
                    return;
                },
                'Q' => {
                    quit_code = @intCast(@min(cmd.num orelse 0, 255));
                    return;
                },
                'r' => try append_queue.append(c.gpa, .{ .file = cmd.text }),
                'R' => {
                    const rf = cmd.rfile.?;
                    if (!rf.done) {
                        if (rf.reader == null) {
                            if (c.sys.open(rf.name, c.O_RDONLY, 0)) |fd| {
                                rf.reader = c.LineReader.init(fd);
                            } else |_| rf.done = true;
                        }
                        if (rf.reader) |*r| {
                            if (r.next() catch null) |l| {
                                try append_queue.append(c.gpa, .{ .line = try c.gpa.dupe(u8, l) });
                            } else rf.done = true;
                        }
                    }
                },
                's' => {
                    const sub = cmd.subst.?;
                    if (try substitute(sub)) {
                        tflag = true;
                        var k: u32 = 0;
                        while (k < sub.print) : (k += 1) try cur_out.emit(ps.items, true);
                        if (sub.wfile) |wf| try wf.emit(ps.items, true);
                    }
                },
                't' => if (tflag) {
                    tflag = false;
                    pc = cmd.jump;
                },
                'T' => {
                    if (!tflag) pc = cmd.jump else tflag = false;
                },
                'b' => pc = cmd.jump,
                'w' => try cmd.wfile.?.emit(ps.items, true),
                'W' => {
                    const e = mem.indexOfScalar(u8, ps.items, '\n') orelse ps.items.len;
                    try cmd.wfile.?.emit(ps.items[0..e], true);
                },
                'y' => {
                    const tab = cmd.ytab.?;
                    for (ps.items) |*ch| ch.* = tab[ch.*];
                },
                'z' => ps.clearRetainingCapacity(),
                'F' => {
                    const f = input.files[cur_line.file];
                    try cur_out.emit(f, true);
                },
                else => {},
            }
        }
        try endCycleOutput();
    }
}

pub fn main(args: c.Args) !u8 {
    c.usage_status = 1;
    var script: std.ArrayList(u8) = .empty;
    var have_script = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "quiet", 'n' },       .{ "silent", 'n' },    .{ "expression", 'e' },   .{ "file", 'f' },
        .{ "in-place", 'i' },    .{ "line-length", 'l' }, .{ "regexp-extended", 'E' }, .{ "separate", 's' },
        .{ "unbuffered", 'u' },  .{ "null-data", 'z' }, .{ "posix", 0 },          .{ "debug", 0 },
        .{ "sandbox", 0 },       .{ "follow-symlinks", 0 },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'n' => quiet = true,
            'e' => {
                if (have_script) try script.append(c.gpa, '\n');
                try script.appendSlice(c.gpa, p.arg());
                have_script = true;
            },
            'f' => {
                const f = p.arg();
                const data = c.readInput(f) orelse c.exit(1);
                if (have_script) try script.append(c.gpa, '\n');
                var d: []const u8 = data;
                if (d.len > 0 and d[d.len - 1] == '\n') d = d[0 .. d.len - 1];
                try script.appendSlice(c.gpa, d);
                have_script = true;
            },
            'i' => {
                in_place = true;
                separate = true;
                if (p.optArg()) |s| in_place_suffix = s;
            },
            'l' => line_len = c.parseUint(p.arg()) orelse c.usageErr("invalid line length", .{}),
            'E', 'r' => extended = true,
            's' => separate = true,
            'u' => unbuffered = true,
            'z' => delim = 0,
            else => p.bad(o),
        },
        .long => |name| {
            if (c.eql(name, "posix") or c.eql(name, "debug") or c.eql(name, "sandbox") or c.eql(name, "follow-symlinks")) {} else p.bad(o);
        },
        .pos => |a| try files.append(c.gpa, a),
    };
    if (!have_script) {
        if (files.items.len == 0) {
            c.eprint("Usage: sed [OPTION]... {{script-only-if-no-other-script}} [input-file]...\n\n", .{});
            c.exit(1);
        }
        try script.appendSlice(c.gpa, files.orderedRemove(0));
    }
    if (mem.startsWith(u8, script.items, "#n") and (script.items.len == 2 or script.items[2] == '\n')) quiet = true;
    stdout_out = .{ .w = c.out };
    cur_out = &stdout_out;
    var parser: Parser = .{ .s = script.items };
    parser.parse();
    if (files.items.len == 0) {
        if (in_place) c.fatal("no input files", .{});
        try files.append(c.gpa, "-");
    }
    input = .{ .files = files.items };
    try runScript();
    if (in_place) endInPlace();
    try stdout_out.w.flush();
    for (wfiles.items) |wf| wf.out.w.flush() catch {};
    if (quit_code) |q| return q;
    return status;
}

test "sed substitute basics" {
    // exercised through the command tests in tests/run.sh; parser smoke test here
    extended = false;
    cmds = .empty;
    var parser: Parser = .{ .s = "s/a\\(b\\)/[\\1&]/g;2,$!d" };
    parser.parse();
    try std.testing.expectEqual(@as(usize, 2), cmds.items.len);
    try std.testing.expect(cmds.items[0].subst.?.global);
    try std.testing.expectEqual(@as(usize, 4), cmds.items[0].subst.?.repl.len);
    try std.testing.expect(cmds.items[1].negate);
    try std.testing.expectEqual(AddrKind.last, cmds.items[1].a2.kind);
    ps = .empty;
    try ps.appendSlice(c.gpa, "xabyab");
    try std.testing.expect(try substitute(cmds.items[0].subst.?));
    try std.testing.expectEqualStrings("x[bab]y[bab]", ps.items);
}
