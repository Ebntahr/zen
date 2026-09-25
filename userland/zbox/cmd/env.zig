const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]
    \\Set each NAME to VALUE in the environment and run COMMAND.
    \\
    \\  -i, --ignore-environment  start with an empty environment
    \\  -0, --null           end each output line with NUL, not newline
    \\  -u, --unset=NAME     remove variable from the environment
    \\  -C, --chdir=DIR      change working directory to DIR
    \\  -S, --split-string=S  process and split S into separate arguments;
    \\                        used to pass multiple arguments on shebang lines
    \\  -v, --debug          print verbose information for each processing step
    \\
    \\A mere - implies -i.  If no COMMAND, print the resulting environment.
    \\
;

pub fn main(args: c.Args) !u8 {
    c.usage_status = 125;
    var ignore = false;
    var eol: u8 = '\n';
    var unsets: std.ArrayList([]const u8) = .empty;
    var chdir: ?[]const u8 = null;
    var debug = false;
    var split: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{
        .{ "ignore-environment", 'i' }, .{ "null", '0' }, .{ "unset", 'u' }, .{ "chdir", 'C' }, .{ "split-string", 'S' }, .{ "debug", 'v' },
    });
    p.permute = false;
    var rest_start: ?usize = null;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'i' => ignore = true,
            '0' => eol = 0,
            'u' => try unsets.append(c.gpa, p.arg()),
            'C' => chdir = p.arg(),
            'S' => split = p.arg(),
            'v' => debug = true,
            else => p.bad(o),
        },
        .pos => |a| {
            if (c.eql(a, "-")) {
                ignore = true;
                continue;
            }
            rest_start = p.idx - 1;
            break;
        },
        else => p.bad(o),
    };
    var rest: []const [:0]const u8 = if (rest_start) |r| args[r..] else &.{};
    // environment
    var env: std.ArrayList([]const u8) = .empty;
    if (!ignore) {
        for (std.os.environ) |e| try env.append(c.gpa, mem.span(e));
    }
    for (unsets.items) |u| {
        var i: usize = 0;
        while (i < env.items.len) {
            const e = env.items[i];
            if (mem.startsWith(u8, e, u) and e.len > u.len and e[u.len] == '=') {
                _ = env.orderedRemove(i);
            } else i += 1;
        }
    }
    // NAME=VALUE assignments
    var k: usize = 0;
    while (k < rest.len) : (k += 1) {
        const a = rest[k];
        const eq = mem.indexOfScalar(u8, a, '=') orelse break;
        if (eq == 0) break;
        const name = a[0..eq];
        var i: usize = 0;
        while (i < env.items.len) {
            const e = env.items[i];
            if (mem.startsWith(u8, e, name) and e.len > name.len and e[name.len] == '=') {
                _ = env.orderedRemove(i);
            } else i += 1;
        }
        try env.append(c.gpa, a);
        if (debug) c.eprint("setenv:   {s}\n", .{a});
    }
    rest = rest[k..];
    var cmd: std.ArrayList([]const u8) = .empty;
    if (split) |s| {
        // simple split on whitespace honoring quotes
        var it = mem.tokenizeAny(u8, s, " \t\n");
        while (it.next()) |tok| {
            var t = tok;
            if (t.len >= 2 and ((t[0] == '\'' and t[t.len - 1] == '\'') or (t[0] == '"' and t[t.len - 1] == '"'))) t = t[1 .. t.len - 1];
            try cmd.append(c.gpa, t);
        }
    }
    for (rest) |a| try cmd.append(c.gpa, a);
    if (chdir) |d| {
        if (cmd.items.len == 0) c.usageErr("must specify command with --chdir (-C)", .{});
        c.sys.chdir(d) catch |e| c.fatalCode(125, "cannot change directory to {f}: {s}", .{ c.q(d), c.strerror(e) });
    }
    if (cmd.items.len == 0) {
        for (env.items) |e| try c.out.print("{s}{c}", .{ e, eol });
        return 0;
    }
    const envp = c.makeArgv(env.items);
    c.flush();
    const e = c.execvp(cmd.items, envp);
    c.warn("{f}: {s}", .{ c.q(cmd.items[0]), c.strerror(e) });
    return if (e == error.NOENT) 127 else 126;
}
