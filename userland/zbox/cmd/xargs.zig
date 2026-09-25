const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: xargs [OPTION]... COMMAND [INITIAL-ARGS]...
    \\Run COMMAND with arguments INITIAL-ARGS and more arguments read from input.
    \\
    \\  -0, --null                   items are separated by a null, not whitespace;
    \\                                 disables quote and backslash processing and
    \\                                 logical EOF processing
    \\  -a, --arg-file=FILE          read arguments from FILE, not standard input
    \\  -d, --delimiter=CHARACTER    items in input stream are separated by CHARACTER,
    \\                                 not by whitespace
    \\  -E END                       set logical EOF string
    \\  -I R                         same as --replace=R
    \\  -i, --replace[=R]            replace R in INITIAL-ARGS with names read
    \\                                 from standard input, split at newlines;
    \\                                 if R is unspecified, assume {}
    \\  -L, --max-lines=MAX-LINES    use at most MAX-LINES non-blank input lines per
    \\                                 command line
    \\  -n, --max-args=MAX-ARGS      use at most MAX-ARGS arguments per command line
    \\  -o, --open-tty               Reopen stdin as /dev/tty in the child process
    \\  -p, --interactive            prompt before running commands
    \\  -r, --no-run-if-empty        if there are no arguments, then do not run COMMAND
    \\  -s, --max-chars=MAX-CHARS    limit length of command line to MAX-CHARS
    \\  -t, --verbose                print commands before executing them
    \\  -x, --exit                   exit if the size (see -s) is exceeded
    \\  -P, --max-procs=MAX-PROCS    run at most MAX-PROCS processes at a time
    \\
;

var null_sep = false;
var delim: ?u8 = null;
var eof_str: ?[]const u8 = null;
var replace: ?[]const u8 = null;
var max_lines: ?usize = null;
var max_args: ?usize = null;
var max_chars: usize = 131072;
var no_run_empty = false;
var verbose = false;
var interactive = false;
var exit_on_size = false;
var open_tty = false;
var status: u8 = 0;

const Item = struct { text: []const u8, line_end: bool };

/// Parse input into items with GNU xargs quoting rules.
fn parseItems(data: []const u8) []Item {
    var items: std.ArrayList(Item) = .empty;
    if (null_sep or delim != null) {
        const d: u8 = if (null_sep) 0 else delim.?;
        var start: usize = 0;
        while (start < data.len) {
            const e = mem.indexOfScalarPos(u8, data, start, d) orelse data.len;
            items.append(c.gpa, .{ .text = data[start..e], .line_end = true }) catch c.oom();
            start = e + 1;
        }
        return items.items;
    }
    if (replace != null) {
        // -I: each line is one item; leading blanks stripped
        var it = mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_raw| {
            const line = mem.trimLeft(u8, line_raw, " \t");
            if (line.len == 0) continue;
            if (eof_str) |e| if (c.eql(line, e)) break;
            items.append(c.gpa, .{ .text = line, .line_end = true }) catch c.oom();
        }
        return items.items;
    }
    var i: usize = 0;
    var cur: std.ArrayList(u8) = .empty;
    var have = false;
    while (i < data.len) {
        const ch = data[i];
        if (ch == ' ' or ch == '\t' or ch == '\n') {
            if (have) {
                if (eof_str) |e| if (c.eql(cur.items, e)) return items.items;
                items.append(c.gpa, .{ .text = cur.items, .line_end = ch == '\n' }) catch c.oom();
                cur = .empty;
                have = false;
            } else if (ch == '\n' and items.items.len > 0) {
                items.items[items.items.len - 1].line_end = true;
            }
            i += 1;
            continue;
        }
        if (ch == '\'' or ch == '"') {
            const e = mem.indexOfScalarPos(u8, data, i + 1, ch) orelse {
                c.fatalCode(1, "unmatched {s} quote; by default quotes are special to xargs unless you use the -0 option", .{if (ch == '"') "double" else "single"});
            };
            if (mem.indexOfScalar(u8, data[i + 1 .. e], '\n') != null) {
                c.fatalCode(1, "unmatched {s} quote; by default quotes are special to xargs unless you use the -0 option", .{if (ch == '"') "double" else "single"});
            }
            cur.appendSlice(c.gpa, data[i + 1 .. e]) catch c.oom();
            have = true;
            i = e + 1;
            continue;
        }
        if (ch == '\\' and i + 1 < data.len) {
            cur.append(c.gpa, data[i + 1]) catch c.oom();
            have = true;
            i += 2;
            continue;
        }
        cur.append(c.gpa, ch) catch c.oom();
        have = true;
        i += 1;
    }
    if (have) {
        if (eof_str) |e| if (c.eql(cur.items, e)) return items.items;
        items.append(c.gpa, .{ .text = cur.items, .line_end = true }) catch c.oom();
    }
    return items.items;
}

fn run(argv: []const []const u8) bool {
    if (verbose or interactive) {
        for (argv, 0..) |a, k| c.eprint("{s}{s}", .{ if (k > 0) " " else "", a });
        if (interactive) {
            c.eprint(" ?...", .{});
            // read answer from the terminal
            const fd = c.sys.open("/dev/tty", c.O_RDONLY, 0) catch -1;
            var ok = false;
            if (fd >= 0) {
                var b: [64]u8 = undefined;
                const n = c.sys.read(fd, &b) catch 0;
                ok = n > 0 and (b[0] == 'y' or b[0] == 'Y');
                c.sys.close(fd);
            }
            if (!ok) return true;
        } else c.eprint("\n", .{});
    }
    c.flush();
    const pid = c.sys.fork() catch |e| {
        c.warn("cannot fork: {s}", .{c.strerror(e)});
        status = 125;
        return false;
    };
    if (pid == 0) {
        // child: stdin from /dev/null (or tty with -o)
        const in = c.sys.open(if (open_tty) "/dev/tty" else "/dev/null", c.O_RDONLY, 0) catch -1;
        if (in >= 0) c.sys.dup2(in, 0) catch {};
        const e = c.execvp(argv, c.envp());
        c.warn("{s}: {s}", .{ argv[0], c.strerror(e) });
        std.process.exit(if (e == error.NOENT) 127 else 126);
    }
    const r = c.sys.wait(pid, 0) catch return false;
    const st = r.status;
    if (st & 0x7f != 0) {
        c.warn("{s}: terminated by signal {d}", .{ argv[0], st & 0x7f });
        status = 125;
        return false;
    }
    const code = (st >> 8) & 0xff;
    if (code == 255) {
        c.warn("{s}: exited with status 255; aborting", .{argv[0]});
        status = 124;
        return false;
    }
    if (code == 127) {
        status = 127;
        return false;
    }
    if (code == 126) {
        status = 126;
        return false;
    }
    if (code != 0) status = 123;
    return true;
}

pub fn main(args: c.Args) !u8 {
    var arg_file: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{
        .{ "null", '0' },         .{ "arg-file", 'a' },  .{ "delimiter", 'd' },      .{ "eof", 'e' },
        .{ "replace", 'i' },      .{ "max-lines", 'l' }, .{ "max-args", 'n' },       .{ "open-tty", 'o' },
        .{ "interactive", 'p' },  .{ "no-run-if-empty", 'r' }, .{ "max-chars", 's' }, .{ "verbose", 't' },
        .{ "exit", 'x' },         .{ "max-procs", 'P' }, .{ "show-limits", 0 },
    });
    p.permute = false;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            '0' => null_sep = true,
            'a' => arg_file = p.arg(),
            'd' => {
                const d = p.arg();
                if (d.len == 1) {
                    delim = d[0];
                } else if (d.len >= 2 and d[0] == '\\') {
                    var tmp: [8]u8 = undefined;
                    delim = c.unescapeOne(d, &tmp, false)[0][0];
                } else c.fatal("invalid input delimiter specification {s}: the delimiter must be either a single character or an escape sequence starting with \\.", .{d});
            },
            'E' => eof_str = p.arg(),
            'e' => eof_str = p.optArg(),
            'I' => {
                replace = p.arg();
                max_lines = 1;
                exit_on_size = true;
            },
            'i' => {
                replace = p.optArg() orelse "{}";
                max_lines = 1;
            },
            'L' => {
                max_lines = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid number for -L option", .{}));
                max_args = null;
            },
            'l' => max_lines = if (p.optArg()) |v| @intCast(c.parseUint(v) orelse 1) else 1,
            'n' => {
                const a = p.arg();
                max_args = @intCast(c.parseUint(a) orelse c.fatal("invalid number \"{s}\" for -n option", .{a}));
                if (max_args.? == 0) c.fatal("value 0 for -n option should be >= 1", .{});
            },
            'o' => open_tty = true,
            'p' => {
                interactive = true;
                verbose = true;
            },
            'r' => no_run_empty = true,
            's' => max_chars = @intCast(c.parseUint(p.arg()) orelse c.fatal("invalid number for -s option", .{})),
            't' => verbose = true,
            'x' => exit_on_size = true,
            'P' => _ = p.arg(),
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "show-limits")) {} else p.bad(o);
        },
        .pos => |a| {
            p.idx -= 1;
            _ = a;
            break;
        },
    };
    var cmd: []const []const u8 = p.rest();
    if (cmd.len == 0) cmd = &.{"echo"};
    const data = blk: {
        if (arg_file) |af| break :blk c.readInput(af) orelse return 1;
        break :blk c.readFdAll(0) catch |e| c.fatal("read error: {s}", .{c.strerror(e)});
    };
    const items = parseItems(data);
    if (replace) |r| {
        for (items) |it| {
            var argv: std.ArrayList([]const u8) = .empty;
            for (cmd) |a| {
                if (mem.indexOf(u8, a, r) != null) {
                    try argv.append(c.gpa, try mem.replaceOwned(u8, c.gpa, a, r, it.text));
                } else try argv.append(c.gpa, a);
            }
            if (!run(argv.items)) return status;
        }
        return status;
    }
    if (items.len == 0) {
        if (no_run_empty) return 0;
        _ = run(cmd);
        return status;
    }
    var base_len: usize = 0;
    for (cmd) |a| base_len += a.len + 1;
    var idx: usize = 0;
    while (idx < items.len) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(c.gpa, cmd);
        var len = base_len;
        var nargs: usize = 0;
        var nlines: usize = 0;
        while (idx < items.len) {
            const it = items[idx];
            if (max_args) |m| if (nargs >= m) break;
            if (len + it.text.len + 1 > max_chars and nargs > 0) {
                if (exit_on_size) c.fatal("argument line too long", .{});
                break;
            }
            try argv.append(c.gpa, it.text);
            len += it.text.len + 1;
            nargs += 1;
            idx += 1;
            if (it.line_end) {
                nlines += 1;
                if (max_lines) |m| if (nlines >= m) break;
            }
        }
        if (!run(argv.items)) return status;
    }
    return status;
}
