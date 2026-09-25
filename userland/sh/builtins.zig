//! Shell builtin commands.
const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const exec = @import("exec.zig");
const expand = @import("expand.zig");
const jobs = @import("jobs.zig");
const signals = @import("signals.zig");
const parser = @import("parser.zig");
const arith = @import("arith.zig");
const testcmd = @import("testcmd.zig");
const printf = @import("printf.zig");
const Shell = shell.Shell;
const Error = shell.Error;
const linux = std.os.linux;

pub const Args = []const [:0]const u8;
pub const Fn = *const fn (*Shell, Args) Error!u8;

pub const Builtin = struct {
    name: []const u8,
    func: Fn,
    special: bool = false,
    synopsis: []const u8,
};

pub const table = [_]Builtin{
    .{ .name = ":", .func = b_true, .special = true, .synopsis = ": [arg ...]                 do nothing, successfully" },
    .{ .name = ".", .func = b_source, .special = true, .synopsis = ". file [arg ...]            run commands from file in this shell" },
    .{ .name = "[", .func = testcmd.b_bracket, .synopsis = "[ expr ]                    evaluate a conditional expression" },
    .{ .name = "alias", .func = b_alias, .synopsis = "alias [name[=value] ...]    define or show aliases" },
    .{ .name = "bg", .func = b_bg, .synopsis = "bg [job ...]                resume jobs in the background" },
    .{ .name = "break", .func = b_break, .special = true, .synopsis = "break [n]                   exit from a loop" },
    .{ .name = "builtin", .func = b_builtin, .synopsis = "builtin name [arg ...]      run a builtin, bypassing functions" },
    .{ .name = "cd", .func = b_cd, .synopsis = "cd [-L|-P] [dir|-]          change the working directory" },
    .{ .name = "command", .func = b_command, .synopsis = "command [-pvV] cmd [arg ...] run a command, bypassing functions" },
    .{ .name = "continue", .func = b_continue, .special = true, .synopsis = "continue [n]                resume the next loop iteration" },
    .{ .name = "declare", .func = b_declare, .synopsis = "declare [-grxfp] [name[=value] ...]  set variable attributes" },
    .{ .name = "echo", .func = b_echo, .synopsis = "echo [-neE] [arg ...]       write arguments to standard output" },
    .{ .name = "eval", .func = b_eval, .special = true, .synopsis = "eval [arg ...]              run arguments as a command" },
    .{ .name = "exec", .func = b_exec, .special = true, .synopsis = "exec [cmd [arg ...]]        replace the shell / apply redirections" },
    .{ .name = "exit", .func = b_exit, .special = true, .synopsis = "exit [n]                    exit the shell" },
    .{ .name = "export", .func = b_export, .special = true, .synopsis = "export [-np] [name[=value]] mark variables for export" },
    .{ .name = "false", .func = b_false, .synopsis = "false                       return an unsuccessful status" },
    .{ .name = "fg", .func = b_fg, .synopsis = "fg [job]                    bring a job to the foreground" },
    .{ .name = "getopts", .func = b_getopts, .synopsis = "getopts optstring name [arg] parse positional options" },
    .{ .name = "hash", .func = b_hash, .synopsis = "hash [-r] [name ...]        remember / forget command locations" },
    .{ .name = "help", .func = b_help, .synopsis = "help [name]                 show help for builtins" },
    .{ .name = "history", .func = b_history, .synopsis = "history [-c] [n]            show or clear command history" },
    .{ .name = "jobs", .func = b_jobs, .synopsis = "jobs [-lp] [job ...]        list jobs" },
    .{ .name = "kill", .func = b_kill, .synopsis = "kill [-s sig|-sig] pid|job  send a signal; kill -l lists signals" },
    .{ .name = "let", .func = b_let, .synopsis = "let expr ...                evaluate arithmetic expressions" },
    .{ .name = "local", .func = b_local, .synopsis = "local name[=value] ...      declare function-local variables" },
    .{ .name = "printf", .func = printf.b_printf, .synopsis = "printf [-v var] fmt [arg ...] formatted output" },
    .{ .name = "pwd", .func = b_pwd, .synopsis = "pwd [-L|-P]                 print the working directory" },
    .{ .name = "read", .func = b_read, .synopsis = "read [-rs] [-p prompt] [-n n] [-d delim] [name ...]  read a line" },
    .{ .name = "readonly", .func = b_readonly, .special = true, .synopsis = "readonly [-p] [name[=value]] make variables read-only" },
    .{ .name = "return", .func = b_return, .special = true, .synopsis = "return [n]                  return from a function or sourced file" },
    .{ .name = "set", .func = b_set, .special = true, .synopsis = "set [-+abCefhmnuvx] [-o opt] [--] [arg ...]  set options / positional args" },
    .{ .name = "shift", .func = b_shift, .special = true, .synopsis = "shift [n]                   shift positional parameters" },
    .{ .name = "source", .func = b_source, .synopsis = "source file [arg ...]       run commands from file in this shell" },
    .{ .name = "test", .func = testcmd.b_test, .synopsis = "test expr                   evaluate a conditional expression" },
    .{ .name = "times", .func = b_times, .special = true, .synopsis = "times                       show accumulated process times" },
    .{ .name = "trap", .func = b_trap, .special = true, .synopsis = "trap [-lp] [action sig ...] handle signals and EXIT" },
    .{ .name = "true", .func = b_true, .synopsis = "true                        return a successful status" },
    .{ .name = "type", .func = b_type, .synopsis = "type [-aptP] name ...       describe how a name would be interpreted" },
    .{ .name = "typeset", .func = b_declare, .synopsis = "typeset [-grxfp] [name[=value] ...]  same as declare" },
    .{ .name = "ulimit", .func = b_ulimit, .synopsis = "ulimit [-a]                 show resource limits" },
    .{ .name = "umask", .func = b_umask, .synopsis = "umask [-S] [mode]           show or set the file creation mask" },
    .{ .name = "unalias", .func = b_unalias, .synopsis = "unalias [-a] name ...       remove aliases" },
    .{ .name = "unset", .func = b_unset, .special = true, .synopsis = "unset [-fv] name ...        remove variables or functions" },
    .{ .name = "wait", .func = b_wait, .synopsis = "wait [pid|job ...]          wait for background jobs" },
};

const map = blk: {
    var kvs: [table.len]struct { []const u8, usize } = undefined;
    for (table, 0..) |b, i| kvs[i] = .{ b.name, i };
    break :blk std.StaticStringMap(usize).initComptime(kvs);
};

pub fn lookup(name: []const u8) ?*const Builtin {
    const i = map.get(name) orelse return null;
    return &table[i];
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn parseNum(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null;
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sortUnstable([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

fn sortedVarNames(sh: *Shell) Error![][]const u8 {
    const a = sh.scratchAlloc();
    var names: std.ArrayList([]const u8) = .empty;
    var it = sh.vars.iterator();
    while (it.next()) |e| try names.append(a, e.key_ptr.*);
    sortStrings(names.items);
    return names.items;
}

// ---------------------------------------------------------------------------
// trivial builtins
// ---------------------------------------------------------------------------

fn b_true(_: *Shell, _: Args) Error!u8 {
    return 0;
}

fn b_false(_: *Shell, _: Args) Error!u8 {
    return 1;
}

// ---------------------------------------------------------------------------
// echo
// ---------------------------------------------------------------------------

/// Process backslash escapes (echo -e, printf %b). Returns false if \c
/// was seen (stop all output).
pub fn writeEscapes(sh: *Shell, s: []const u8, octal_needs_zero: bool) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            sh.write(s[i .. i + 1]);
            continue;
        }
        i += 1;
        const e = s[i];
        switch (e) {
            'a' => sh.write("\x07"),
            'b' => sh.write("\x08"),
            'c' => return false,
            'e', 'E' => sh.write("\x1b"),
            'f' => sh.write("\x0c"),
            'n' => sh.write("\n"),
            'r' => sh.write("\r"),
            't' => sh.write("\t"),
            'v' => sh.write("\x0b"),
            '\\' => sh.write("\\"),
            '0'...'7' => {
                var v: u32 = 0;
                var k: usize = 0;
                var j = i;
                if (e == '0' and octal_needs_zero) j += 1 else if (octal_needs_zero) {
                    sh.write("\\");
                    sh.write(s[i .. i + 1]);
                    continue;
                }
                while (k < 3 and j < s.len and s[j] >= '0' and s[j] <= '7') : (k += 1) {
                    v = v * 8 + (s[j] - '0');
                    j += 1;
                }
                i = j - 1;
                const byte = [1]u8{@truncate(v)};
                sh.write(&byte);
            },
            'x' => {
                var v: u32 = 0;
                var k: usize = 0;
                var j = i + 1;
                while (k < 2 and j < s.len) : (k += 1) {
                    const d = std.fmt.charToDigit(s[j], 16) catch break;
                    v = v * 16 + d;
                    j += 1;
                }
                if (k == 0) {
                    sh.write("\\x");
                } else {
                    i = j - 1;
                    const byte = [1]u8{@truncate(v)};
                    sh.write(&byte);
                }
            },
            else => {
                sh.write("\\");
                sh.write(s[i .. i + 1]);
            },
        }
    }
    return true;
}

fn b_echo(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    var newline = true;
    var escapes = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        var ok = true;
        for (a[1..]) |c| {
            if (c != 'n' and c != 'e' and c != 'E') ok = false;
        }
        if (!ok) break;
        for (a[1..]) |c| switch (c) {
            'n' => newline = false,
            'e' => escapes = true,
            'E' => escapes = false,
            else => {},
        };
    }
    var first = true;
    while (i < argv.len) : (i += 1) {
        if (!first) sh.write(" ");
        first = false;
        if (escapes) {
            if (!writeEscapes(sh, argv[i], true)) return 0;
        } else sh.write(argv[i]);
    }
    if (newline) sh.write("\n");
    sh.flushOut();
    return if (sh.out.failed) blk: {
        sh.out.failed = false;
        break :blk 1;
    } else 0;
}

// ---------------------------------------------------------------------------
// cd / pwd
// ---------------------------------------------------------------------------

fn physicalCwd(sh: *Shell) ?[]const u8 {
    const buf = sh.scratchAlloc().alloc(u8, sys.PATH_MAX) catch return null;
    return sys.getcwd(buf) catch null;
}

/// Compute a normalised path for `target` relative to `base` without
/// asking the kernel (fallback when getcwd is unavailable).
fn logicalPath(a: std.mem.Allocator, base: []const u8, target: []const u8) Error![]const u8 {
    const joined = if (target.len > 0 and target[0] == '/') target else try std.mem.concat(a, u8, &.{ base, "/", target });
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, joined, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, c);
    }
    var out: std.ArrayList(u8) = .empty;
    if (joined.len > 0 and joined[0] == '/') try out.append(a, '/');
    for (parts.items, 0..) |c, i| {
        if (i > 0) try out.append(a, '/');
        try out.appendSlice(a, c);
    }
    if (out.items.len == 0) try out.append(a, '/');
    return out.items;
}

fn b_cd(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, argv[i], "-L") or std.mem.eql(u8, argv[i], "-P")) continue;
        sh.errMsg("cd: {s}: invalid option", .{argv[i]});
        return 2;
    }
    if (argv.len > i + 1) {
        sh.errMsg("cd: too many arguments", .{});
        return 1;
    }
    var target: []const u8 = undefined;
    var print_dir = false;
    if (i >= argv.len) {
        target = sh.getVar("HOME") orelse {
            sh.errMsg("cd: HOME not set", .{});
            return 1;
        };
    } else if (std.mem.eql(u8, argv[i], "-")) {
        target = sh.getVar("OLDPWD") orelse {
            sh.errMsg("cd: OLDPWD not set", .{});
            return 1;
        };
        print_dir = true;
    } else target = argv[i];
    if (target.len == 0) return 0;

    const a = sh.scratchAlloc();
    var done = false;
    const relative = target[0] != '/' and !std.mem.eql(u8, target, ".") and !std.mem.eql(u8, target, "..") and
        !std.mem.startsWith(u8, target, "./") and !std.mem.startsWith(u8, target, "../");
    if (relative) {
        if (sh.getVar("CDPATH")) |cdpath| {
            var it = std.mem.splitScalar(u8, cdpath, ':');
            while (it.next()) |dir| {
                if (dir.len == 0) continue;
                const cand = try std.mem.concat(a, u8, &.{ dir, if (dir[dir.len - 1] == '/') "" else "/", target });
                if (sys.chdir(cand)) {
                    done = true;
                    print_dir = true;
                    break;
                } else |_| {}
            }
        }
    }
    if (!done) {
        sys.chdir(target) catch {
            sh.errMsg("cd: {s}: {s}", .{ target, sys.lastError() });
            return 1;
        };
    }
    const old = try a.dupe(u8, sh.getVar("PWD") orelse "");
    const new = physicalCwd(sh) orelse try logicalPath(a, old, target);
    try sh.setVar("OLDPWD", old);
    try sh.setVar("PWD", new);
    if (print_dir) sh.print("{s}\n", .{new});
    return 0;
}

fn b_pwd(sh: *Shell, argv: Args) Error!u8 {
    var physical = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-P")) physical = true else if (std.mem.eql(u8, a, "-L")) physical = false else {
            sh.errMsg("pwd: {s}: invalid option", .{a});
            return 2;
        }
    }
    if (!physical) {
        if (sh.getVar("PWD")) |p| {
            if (p.len > 0 and p[0] == '/') {
                const s1 = sys.stat(p) catch null;
                const s2 = sys.stat(".") catch null;
                if (s1 != null and s2 != null and s1.?.ino == s2.?.ino and s1.?.dev == s2.?.dev) {
                    sh.print("{s}\n", .{p});
                    return 0;
                }
            }
        }
    }
    const cwd = physicalCwd(sh) orelse {
        sh.errMsg("pwd: {s}", .{sys.lastError()});
        return 1;
    };
    sh.print("{s}\n", .{cwd});
    return 0;
}

// ---------------------------------------------------------------------------
// variables
// ---------------------------------------------------------------------------

const DeclKind = enum { export_, readonly };

fn b_export(sh: *Shell, argv: Args) Error!u8 {
    return declare(sh, argv, .export_);
}

fn b_readonly(sh: *Shell, argv: Args) Error!u8 {
    return declare(sh, argv, .readonly);
}

fn declare(sh: *Shell, argv: Args, kind: DeclKind) Error!u8 {
    const kname = if (kind == .export_) "export" else "readonly";
    var i: usize = 1;
    var unexport = false;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        for (argv[i][1..]) |c| switch (c) {
            'p', 'f' => {},
            'n' => unexport = true,
            else => {
                sh.errMsg("{s}: -{c}: invalid option", .{ kname, c });
                return 2;
            },
        };
    }
    if (i >= argv.len) {
        const names = try sortedVarNames(sh);
        for (names) |n| {
            const v = sh.vars.get(n).?;
            const show = if (kind == .export_) v.exported else v.readonly;
            if (!show) continue;
            if (v.value) |val| {
                sh.print("{s} {s}={s}\n", .{ kname, n, try shell.quote(sh.scratchAlloc(), val) });
            } else sh.print("{s} {s}\n", .{ kname, n });
        }
        return 0;
    }
    var status: u8 = 0;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        if (!parser.isName(name)) {
            sh.errMsg("{s}: `{s}': not a valid identifier", .{ kname, arg });
            status = 1;
            continue;
        }
        switch (kind) {
            .export_ => try sh.setVarFlags(name, value, .{ .exported = !unexport }),
            .readonly => try sh.setVarFlags(name, value, .{ .readonly = true }),
        }
    }
    return status;
}

fn b_unset(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    var funcs = false;
    var vars = false;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        for (argv[i][1..]) |c| switch (c) {
            'f' => funcs = true,
            'v' => vars = true,
            else => {
                sh.errMsg("unset: -{c}: invalid option", .{c});
                return 2;
            },
        };
    }
    var status: u8 = 0;
    while (i < argv.len) : (i += 1) {
        const name: []const u8 = argv[i];
        if (funcs) {
            if (sh.funcs.fetchRemove(name)) |kv| sh.gpa.free(kv.key);
            continue;
        }
        if (!parser.isName(name)) {
            sh.errMsg("unset: `{s}': not a valid identifier", .{name});
            status = 1;
            continue;
        }
        const existed = sh.vars.contains(name);
        if (!try sh.unsetVar(name)) status = 1;
        if (!existed and !vars) {
            if (sh.funcs.fetchRemove(name)) |kv| sh.gpa.free(kv.key);
        }
    }
    return status;
}

fn b_local(sh: *Shell, argv: Args) Error!u8 {
    if (sh.func_depth == 0) {
        sh.errMsg("local: can only be used in a function", .{});
        return 1;
    }
    var status: u8 = 0;
    for (argv[1..]) |arg_z| {
        const arg: []const u8 = arg_z;
        if (arg.len > 0 and arg[0] == '-') continue;
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        if (!parser.isName(name)) {
            sh.errMsg("local: `{s}': not a valid identifier", .{arg});
            status = 1;
            continue;
        }
        try sh.makeLocal(name, value);
    }
    return status;
}

fn b_declare(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    var exported = false;
    var unexport = false;
    var readonly = false;
    var global = false;
    var print = false;
    var funcs = false;
    while (i < argv.len and argv[i].len > 1 and (argv[i][0] == '-' or argv[i][0] == '+')) : (i += 1) {
        const on = argv[i][0] == '-';
        for (argv[i][1..]) |c| switch (c) {
            'x' => {
                if (on) exported = true else unexport = true;
            },
            'r' => readonly = on,
            'g' => global = true,
            'p' => print = true,
            'f', 'F' => funcs = true,
            'i', 'l', 'u', 't', 'a', 'A', 'n' => {},
            else => {
                sh.errMsg("{s}: -{c}: invalid option", .{ argv[0], c });
                return 2;
            },
        };
    }
    const a = sh.scratchAlloc();
    if (funcs) {
        var names: std.ArrayList([]const u8) = .empty;
        var it = sh.funcs.iterator();
        while (it.next()) |e| try names.append(a, e.key_ptr.*);
        sortStrings(names.items);
        for (names.items) |n| {
            if (i < argv.len) {
                var want = false;
                for (argv[i..]) |x| {
                    if (std.mem.eql(u8, x, n)) want = true;
                }
                if (!want) continue;
            }
            if (argv[0].len > 0 and std.mem.indexOfScalar(u8, argv[1], 'F') != null) {
                sh.print("declare -f {s}\n", .{n});
            } else sh.print("{s}\n", .{sh.funcs.get(n).?.src});
        }
        return 0;
    }
    if (i >= argv.len or print) {
        const names = try sortedVarNames(sh);
        for (names) |n| {
            if (print and i < argv.len) {
                var want = false;
                for (argv[i..]) |x| {
                    if (std.mem.eql(u8, x, n)) want = true;
                }
                if (!want) continue;
            }
            const v = sh.vars.get(n).?;
            if ((exported and !v.exported) or (readonly and !v.readonly)) continue;
            var flags: [4]u8 = undefined;
            var nf: usize = 0;
            if (v.exported) {
                flags[nf] = 'x';
                nf += 1;
            }
            if (v.readonly) {
                flags[nf] = 'r';
                nf += 1;
            }
            const fl = if (nf == 0) "--" else try std.mem.concat(a, u8, &.{ "-", flags[0..nf] });
            if (v.value) |val| {
                sh.print("declare {s} {s}={s}\n", .{ fl, n, try shell.quote(a, val) });
            } else sh.print("declare {s} {s}\n", .{ fl, n });
        }
        return 0;
    }
    var status: u8 = 0;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        if (!parser.isName(name)) {
            sh.errMsg("{s}: `{s}': not a valid identifier", .{ argv[0], arg });
            status = 1;
            continue;
        }
        if (sh.func_depth > 0 and !global) try sh.makeLocal(name, value) else if (value) |v| try sh.setVar(name, v);
        if (exported or unexport or readonly) {
            try sh.setVarFlags(name, null, .{ .exported = if (exported) true else if (unexport) false else null, .readonly = readonly });
        }
    }
    return status;
}

fn setLetter(sh: *Shell, c: u8, on: bool) bool {
    inline for (shell.option_table) |o| {
        if (o.letter != 0 and o.letter == c) {
            @field(sh.opts, o.field) = on;
            return true;
        }
    }
    return false;
}

pub fn setNamed(sh: *Shell, name: []const u8, on: bool) bool {
    inline for (shell.option_table) |o| {
        if (std.mem.eql(u8, o.name, name)) {
            @field(sh.opts, o.field) = on;
            if (std.mem.eql(u8, o.name, "vi") and on) sh.opts.emacs = false;
            if (std.mem.eql(u8, o.name, "emacs") and on) sh.opts.vi = false;
            return true;
        }
    }
    return false;
}

fn b_set(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len == 1) {
        const names = try sortedVarNames(sh);
        for (names) |n| {
            const v = sh.vars.get(n).?;
            if (v.value) |val| sh.print("{s}={s}\n", .{ n, try shell.quote(sh.scratchAlloc(), val) });
        }
        return 0;
    }
    var i: usize = 1;
    while (i < argv.len) {
        const a: []const u8 = argv[i];
        if (a.len == 0 or (a[0] != '-' and a[0] != '+')) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            try sh.setParams(try exec.argSlices(sh, @ptrCast(argv[i..])));
            return 0;
        }
        if (std.mem.eql(u8, a, "-") or std.mem.eql(u8, a, "+")) {
            sh.opts.xtrace = false;
            sh.opts.verbose = false;
            i += 1;
            break;
        }
        const on = a[0] == '-';
        for (a[1..]) |c| {
            if (c == 'o') {
                i += 1;
                if (i >= argv.len) {
                    inline for (shell.option_table) |o| {
                        const v = @field(sh.opts, o.field);
                        if (on) {
                            sh.print("{s:<15}\t{s}\n", .{ o.name, if (v) "on" else "off" });
                        } else sh.print("set {s}o {s}\n", .{ if (v) "-" else "+", o.name });
                    }
                    return 0;
                }
                if (!setNamed(sh, argv[i], on)) {
                    sh.errMsg("set: {s}: invalid option name", .{argv[i]});
                    return 2;
                }
            } else if (!setLetter(sh, c, on)) {
                sh.errMsg("set: {c}{c}: invalid option", .{ a[0], c });
                return 2;
            }
        }
        i += 1;
    }
    if (i < argv.len) try sh.setParams(try exec.argSlices(sh, @ptrCast(argv[i..])));
    return 0;
}

fn b_shift(sh: *Shell, argv: Args) Error!u8 {
    var n: i64 = 1;
    if (argv.len > 1) n = parseNum(argv[1]) orelse {
        sh.errMsg("shift: {s}: numeric argument required", .{argv[1]});
        return 1;
    };
    if (n < 0 or n > sh.params.len) {
        sh.errMsg("shift: {d}: shift count out of range", .{n});
        return 1;
    }
    const k: usize = @intCast(n);
    const rest = sh.params[k..];
    const copy = try sh.scratchAlloc().alloc([]const u8, rest.len);
    for (rest, 0..) |p, i| copy[i] = try sh.scratchAlloc().dupe(u8, p);
    try sh.setParams(copy);
    return 0;
}

// ---------------------------------------------------------------------------
// control flow
// ---------------------------------------------------------------------------

fn b_exit(sh: *Shell, argv: Args) Error!u8 {
    var code: u8 = sh.last_status;
    if (argv.len > 1) {
        if (parseNum(argv[1])) |n| {
            code = @truncate(@as(u64, @bitCast(n)));
        } else {
            sh.errMsg("exit: {s}: numeric argument required", .{argv[1]});
            code = 2;
        }
    }
    if (sh.interactive and !sh.exit_warned) {
        for (sh.jobs.list.items) |j| {
            if (j.state() == .stopped) {
                sh.errWrite("There are stopped jobs.\n");
                sh.exit_warned = true;
                return 1;
            }
        }
    }
    sh.exit_status = code;
    return error.Exit;
}

fn b_return(sh: *Shell, argv: Args) Error!u8 {
    if (sh.func_depth == 0 and sh.source_depth == 0) {
        sh.errMsg("return: can only `return' from a function or sourced script", .{});
        return 1;
    }
    var code: u8 = sh.last_status;
    if (argv.len > 1) {
        if (parseNum(argv[1])) |n| {
            code = @truncate(@as(u64, @bitCast(n)));
        } else {
            sh.errMsg("return: {s}: numeric argument required", .{argv[1]});
            code = 2;
        }
    }
    sh.return_status = code;
    return error.Return;
}

fn loopCount(sh: *Shell, argv: Args, name: []const u8) ?u32 {
    if (argv.len < 2) return 1;
    const n = parseNum(argv[1]) orelse {
        sh.errMsg("{s}: {s}: numeric argument required", .{ name, argv[1] });
        return null;
    };
    if (n < 1) {
        sh.errMsg("{s}: {d}: loop count out of range", .{ name, n });
        return null;
    }
    return @intCast(@min(n, 1 << 30));
}

fn b_break(sh: *Shell, argv: Args) Error!u8 {
    const n = loopCount(sh, argv, "break") orelse return 1;
    if (sh.loop_depth == 0) {
        sh.errMsg("break: only meaningful in a `for', `while', or `until' loop", .{});
        return 0;
    }
    sh.break_n = @min(n, sh.loop_depth);
    return error.Break;
}

fn b_continue(sh: *Shell, argv: Args) Error!u8 {
    const n = loopCount(sh, argv, "continue") orelse return 1;
    if (sh.loop_depth == 0) {
        sh.errMsg("continue: only meaningful in a `for', `while', or `until' loop", .{});
        return 0;
    }
    sh.cont_n = @min(n, sh.loop_depth);
    return error.Continue;
}

// ---------------------------------------------------------------------------
// source / eval / exec
// ---------------------------------------------------------------------------

fn b_source(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) {
        sh.errMsg("{s}: filename argument required", .{argv[0]});
        return 2;
    }
    const name: []const u8 = argv[1];
    var path: []const u8 = name;
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        var found = false;
        if (sh.getVar("PATH")) |p| {
            var it = std.mem.splitScalar(u8, p, ':');
            while (it.next()) |dir| {
                const cand = if (dir.len == 0) name else try std.mem.concat(sh.scratchAlloc(), u8, &.{ dir, "/", name });
                const st = sys.stat(cand) catch continue;
                if (!sys.isReg(st)) continue;
                path = cand;
                found = true;
                break;
            }
        }
        if (!found) path = name;
    }
    const data = shell.readFileAlloc(sh.scratchAlloc(), path, 64 << 20) orelse {
        sh.errMsg("{s}: {s}", .{ name, sys.lastError() });
        return 1;
    };
    var old_params: ?[][]u8 = null;
    if (argv.len > 2) {
        old_params = sh.params;
        sh.params = &.{};
        try sh.setParams(try exec.argSlices(sh, @ptrCast(argv[2..])));
    }
    defer if (old_params) |op| {
        sh.freeParams(sh.params);
        sh.params = op;
    };
    const old_name = sh.script_name;
    const old_line = sh.lineno;
    sh.script_name = path;
    sh.source_depth += 1;
    defer {
        sh.source_depth -= 1;
        sh.script_name = old_name;
        sh.lineno = old_line;
    }
    return exec.runString(sh, data, .{ .soft_syntax = true }) catch |e| switch (e) {
        error.Return => sh.return_status,
        else => return e,
    };
}

fn b_eval(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) return 0;
    const a = sh.scratchAlloc();
    var src: std.ArrayList(u8) = .empty;
    for (argv[1..], 0..) |x, i| {
        if (i > 0) try src.append(a, ' ');
        try src.appendSlice(a, x);
    }
    sh.trace_depth += 1;
    defer sh.trace_depth -= 1;
    return exec.runString(sh, src.items, .{ .soft_syntax = true, .line_base = sh.lineno });
}

fn b_exec(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len) return 0;
    const name: []const u8 = argv[i];
    const path = exec.findCommand(sh, name) orelse {
        sh.errMsg("exec: {s}: not found", .{name});
        if (!sh.interactive) {
            sh.exit_status = 127;
            return error.Exit;
        }
        return 127;
    };
    sh.flushOut();
    if (sh.interactive and sh.tty_fd >= 0) {
        if (sh.shell_tmodes) |t| sys.tcsetattr(sh.tty_fd, &t) catch {};
    }
    exec.resetSignals(sh);
    exec.execCommand(sh, path, @ptrCast(argv[i..]), &.{}, &.{});
}

// ---------------------------------------------------------------------------
// aliases
// ---------------------------------------------------------------------------

fn b_alias(sh: *Shell, argv: Args) Error!u8 {
    const a = sh.scratchAlloc();
    var args = argv[1..];
    if (args.len > 0 and std.mem.eql(u8, args[0], "-p")) args = args[1..];
    if (args.len == 0) {
        var names: std.ArrayList([]const u8) = .empty;
        var it = sh.aliases.iterator();
        while (it.next()) |e| try names.append(a, e.key_ptr.*);
        sortStrings(names.items);
        for (names.items) |n| sh.print("{s}={s}\n", .{ n, try quoteAlways(a, sh.aliases.get(n).?) });
        return 0;
    }
    var status: u8 = 0;
    for (args) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            if (eq == 0) {
                sh.errMsg("alias: `{s}': invalid alias name", .{arg});
                status = 1;
                continue;
            }
            try sh.setAlias(arg[0..eq], arg[eq + 1 ..]);
        } else if (sh.aliases.get(arg)) |v| {
            sh.print("{s}={s}\n", .{ arg, try quoteAlways(a, v) });
        } else {
            sh.errMsg("alias: {s}: not found", .{arg});
            status = 1;
        }
    }
    return status;
}

fn quoteAlways(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}

fn b_unalias(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) {
        sh.errMsg("unalias: usage: unalias [-a] name [name ...]", .{});
        return 2;
    }
    if (std.mem.eql(u8, argv[1], "-a")) {
        var it = sh.aliases.iterator();
        while (it.next()) |e| {
            sh.gpa.free(e.key_ptr.*);
            sh.gpa.free(e.value_ptr.*);
        }
        sh.aliases.clearRetainingCapacity();
        return 0;
    }
    var status: u8 = 0;
    for (argv[1..]) |n| {
        if (!sh.removeAlias(n)) {
            sh.errMsg("unalias: {s}: not found", .{n});
            status = 1;
        }
    }
    return status;
}

// ---------------------------------------------------------------------------
// history
// ---------------------------------------------------------------------------

fn b_history(sh: *Shell, argv: Args) Error!u8 {
    var count: usize = sh.hist.len();
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-c")) {
            sh.hist.clear(sh.gpa);
            return 0;
        }
        const n = parseNum(a) orelse {
            sh.errMsg("history: {s}: numeric argument required", .{a});
            return 2;
        };
        count = @intCast(@max(0, @min(n, @as(i64, @intCast(sh.hist.len())))));
    }
    const total = sh.hist.len();
    var i = total - count;
    while (i < total) : (i += 1) {
        const e = sh.hist.get(i);
        sh.print("{d:>5}  ", .{sh.hist.base + i + 1});
        // show multi-line entries indented
        var it = std.mem.splitScalar(u8, e, '\n');
        var first = true;
        while (it.next()) |l| {
            if (!first) sh.write("\n       ");
            first = false;
            sh.write(l);
        }
        sh.write("\n");
    }
    return 0;
}

// ---------------------------------------------------------------------------
// type / command / hash / builtin
// ---------------------------------------------------------------------------

const Kind = enum { alias, keyword, function, builtin, file, none };

fn describe(sh: *Shell, name: []const u8, mode: u8, all: bool, no_alias_fn: bool) Error!bool {
    // mode: 'v' (command -v), 'V'/'d' (type default), 't', 'p', 'P'
    var found = false;
    if (!no_alias_fn and mode != 'P') {
        if (sh.aliases.get(name)) |v| {
            found = true;
            switch (mode) {
                'v' => sh.print("alias {s}={s}\n", .{ name, try shell.quote(sh.scratchAlloc(), v) }),
                't' => sh.print("alias\n", .{}),
                'p' => {},
                else => sh.print("{s} is aliased to `{s}'\n", .{ name, v }),
            }
            if (!all) return true;
        }
    }
    if (mode != 'P' and parser.isKeyword(name)) {
        found = true;
        switch (mode) {
            'v' => sh.print("{s}\n", .{name}),
            't' => sh.print("keyword\n", .{}),
            'p' => {},
            else => sh.print("{s} is a shell keyword\n", .{name}),
        }
        if (!all) return true;
    }
    if (!no_alias_fn and mode != 'P') {
        if (sh.funcs.get(name)) |f| {
            found = true;
            switch (mode) {
                'v' => sh.print("{s}\n", .{name}),
                't' => sh.print("function\n", .{}),
                'p' => {},
                else => sh.print("{s} is a function\n{s}\n", .{ name, f.src }),
            }
            if (!all) return true;
        }
    }
    if (mode != 'P') {
        if (lookup(name)) |b| {
            found = true;
            switch (mode) {
                'v' => sh.print("{s}\n", .{name}),
                't' => sh.print("builtin\n", .{}),
                'p' => {},
                else => sh.print("{s} is a {s}shell builtin\n", .{ name, if (b.special) "special " else "" }),
            }
            if (!all) return true;
        }
    }
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null)
        (if (sys.isExecutableFile(name)) name else null)
    else
        exec.searchPath(sh, name, sh.getVar("PATH") orelse "/bin:/usr/bin", false);
    if (path) |p| {
        if (std.mem.indexOfScalar(u8, name, '/') == null and !sys.isExecutableFile(p)) return found;
        found = true;
        switch (mode) {
            'v', 'p', 'P' => sh.print("{s}\n", .{p}),
            't' => sh.print("file\n", .{}),
            else => {
                if (sh.hash.get(name) != null) {
                    sh.print("{s} is hashed ({s})\n", .{ name, p });
                } else sh.print("{s} is {s}\n", .{ name, p });
            },
        }
    }
    return found;
}

fn b_type(sh: *Shell, argv: Args) Error!u8 {
    var mode: u8 = 'V';
    var all = false;
    var i: usize = 1;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        for (argv[i][1..]) |c| switch (c) {
            'a' => all = true,
            't' => mode = 't',
            'p' => mode = 'p',
            'P' => mode = 'P',
            'f' => {},
            else => {
                sh.errMsg("type: -{c}: invalid option", .{c});
                return 2;
            },
        };
    }
    var status: u8 = 0;
    while (i < argv.len) : (i += 1) {
        if (!try describe(sh, argv[i], mode, all, false)) {
            if (mode != 't' and mode != 'p') sh.errMsg("type: {s}: not found", .{argv[i]});
            status = 1;
        }
    }
    return status;
}

fn b_command(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    var mode: u8 = 0;
    var default_path = false;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        for (argv[i][1..]) |c| switch (c) {
            'v' => mode = 'v',
            'V' => mode = 'V',
            'p' => default_path = true,
            else => {
                sh.errMsg("command: -{c}: invalid option", .{c});
                return 2;
            },
        };
    }
    if (i >= argv.len) return 0;
    if (mode != 0) {
        var status: u8 = 0;
        while (i < argv.len) : (i += 1) {
            if (!try describe(sh, argv[i], mode, false, false)) {
                if (mode == 'V') sh.errMsg("command: {s}: not found", .{argv[i]});
                status = 1;
            }
        }
        return status;
    }
    const rest: []const [:0]u8 = @ptrCast(argv[i..]);
    if (lookup(rest[0])) |b| {
        const st = try b.func(sh, argv[i..]);
        sh.flushOut();
        return st;
    }
    if (default_path and std.mem.indexOfScalar(u8, rest[0], '/') == null) {
        const p = exec.searchPath(sh, rest[0], "/bin:/usr/bin:/sbin:/usr/sbin", false) orelse {
            sh.errMsg("{s}: command not found", .{rest[0]});
            return 127;
        };
        const nargv = try sh.scratchAlloc().dupe([:0]u8, rest);
        nargv[0] = try sh.scratchAlloc().dupeZ(u8, p);
        return exec.runExternalPublic(sh, nargv);
    }
    return exec.runExternalPublic(sh, rest);
}

fn b_builtin(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) return 0;
    const b = lookup(argv[1]) orelse {
        sh.errMsg("builtin: {s}: not a shell builtin", .{argv[1]});
        return 1;
    };
    const st = try b.func(sh, argv[1..]);
    sh.flushOut();
    return st;
}

fn b_hash(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "-r")) {
        sh.clearHash();
        return 0;
    }
    if (argv.len == 1) {
        const a = sh.scratchAlloc();
        var names: std.ArrayList([]const u8) = .empty;
        var it = sh.hash.iterator();
        while (it.next()) |e| try names.append(a, e.key_ptr.*);
        if (names.items.len == 0) {
            sh.print("hash: hash table empty\n", .{});
            return 0;
        }
        sortStrings(names.items);
        for (names.items) |n| sh.print("{s}\n", .{sh.hash.get(n).?});
        return 0;
    }
    var status: u8 = 0;
    for (argv[1..]) |n| {
        if (lookup(n) != null) continue;
        if (exec.findCommand(sh, n) == null) {
            sh.errMsg("hash: {s}: not found", .{n});
            status = 1;
        }
    }
    return status;
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

fn b_help(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len > 1) {
        var status: u8 = 1;
        for (argv[1..]) |n| {
            for (table) |b| {
                if (glob_match(n, b.name)) {
                    sh.print("{s}\n", .{b.synopsis});
                    status = 0;
                }
            }
        }
        if (status != 0) sh.errMsg("help: no help topics match `{s}'", .{argv[1]});
        return status;
    }
    sh.print(
        \\zensh {s} - the Zen OS shell
        \\
        \\Builtin commands:
        \\
    , .{shell.version});
    for (table) |b| sh.print("  {s}\n", .{b.synopsis});
    sh.print(
        \\
        \\Line editing: Ctrl-A/E home/end, Ctrl-B/F or arrows move, Alt-B/F word
        \\motion, Ctrl-K/U/W kill, Ctrl-Y yank, Ctrl-L clear, Ctrl-R history search,
        \\Up/Down prefix history search, Tab completion, Right arrow accepts the
        \\grey autosuggestion.  Prompt escapes: \u \h \H \w \W \$ \n \t \j \? \e \z.
        \\
    , .{});
    return 0;
}

fn glob_match(pat: []const u8, s: []const u8) bool {
    return @import("glob.zig").fnmatch(pat, s, .{});
}

// ---------------------------------------------------------------------------
// jobs
// ---------------------------------------------------------------------------

fn printJob(sh: *Shell, j: *jobs.Job, long: bool, pids_only: bool) void {
    if (pids_only) {
        sh.print("{d}\n", .{j.pgid});
        return;
    }
    var sb: [32]u8 = undefined;
    const st = jobs.stateText(&sb, j);
    const amp = if (j.state() == .running) " &" else "";
    if (long) {
        sh.print("[{d}]{c} {d} {s:<24}{s}{s}\n", .{ j.id, sh.jobs.marker(j), j.pgid, st, j.text, amp });
    } else {
        sh.print("[{d}]{c}  {s:<24}{s}{s}\n", .{ j.id, sh.jobs.marker(j), st, j.text, amp });
    }
}

fn b_jobs(sh: *Shell, argv: Args) Error!u8 {
    var long = false;
    var pids = false;
    var i: usize = 1;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        for (argv[i][1..]) |c| switch (c) {
            'l' => long = true,
            'p' => pids = true,
            else => {},
        };
    }
    sh.jobs.reapNonBlocking();
    var status: u8 = 0;
    if (i < argv.len) {
        while (i < argv.len) : (i += 1) {
            const j = sh.jobs.resolve(argv[i]) orelse {
                sh.errMsg("jobs: {s}: no such job", .{argv[i]});
                status = 1;
                continue;
            };
            printJob(sh, j, long, pids);
        }
        return status;
    }
    var k: usize = 0;
    while (k < sh.jobs.list.items.len) : (k += 1) {
        const j = sh.jobs.list.items[k];
        if (!j.bg) continue;
        printJob(sh, j, long, pids);
    }
    // done jobs have now been reported
    var idx: usize = 0;
    while (idx < sh.jobs.list.items.len) {
        const j = sh.jobs.list.items[idx];
        if (j.bg and j.state() == .done) {
            sh.jobs.remove(sh.gpa, j);
        } else idx += 1;
    }
    return 0;
}

fn continueJob(j: *jobs.Job) void {
    for (j.procs.items) |*p| {
        if (p.state == .stopped) p.state = .running;
    }
    if (j.pgid > 0) {
        sys.kill(-j.pgid, linux.SIG.CONT) catch {
            for (j.procs.items) |p| sys.kill(p.pid, linux.SIG.CONT) catch {};
        };
    }
}

fn b_fg(sh: *Shell, argv: Args) Error!u8 {
    if (!sh.opts.monitor) {
        sh.errMsg("fg: no job control", .{});
        return 1;
    }
    const spec: []const u8 = if (argv.len > 1) argv[1] else "";
    const j = sh.jobs.resolve(spec) orelse {
        sh.errMsg("fg: {s}: no such job", .{if (spec.len > 0) spec else "current"});
        return 1;
    };
    sh.print("{s}\n", .{j.text});
    sh.flushOut();
    j.bg = false;
    j.notified = false;
    sh.jobs.touch(j);
    if (sh.tty_fd >= 0) {
        if (j.tmodes) |t| sys.tcsetattr(sh.tty_fd, &t) catch {};
        sys.tcsetpgrp(sh.tty_fd, j.pgid) catch {};
    }
    continueJob(j);
    return exec.waitForeground(sh, j);
}

fn b_bg(sh: *Shell, argv: Args) Error!u8 {
    if (!sh.opts.monitor) {
        sh.errMsg("bg: no job control", .{});
        return 1;
    }
    const specs: []const []const u8 = if (argv.len > 1) try exec.argSlices(sh, @ptrCast(argv[1..])) else &.{""};
    var status: u8 = 0;
    for (specs) |spec| {
        const j = sh.jobs.resolve(spec) orelse {
            sh.errMsg("bg: {s}: no such job", .{if (spec.len > 0) spec else "current"});
            status = 1;
            continue;
        };
        if (j.state() == .running) {
            sh.errMsg("bg: job {d} already in background", .{j.id});
            continue;
        }
        j.bg = true;
        j.notified = false;
        continueJob(j);
        sh.print("[{d}]{c} {s} &\n", .{ j.id, sh.jobs.marker(j), j.text });
    }
    return status;
}

/// Block until the given job (or process) is no longer running. Returns a
/// signal number if interrupted by a trapped signal.
fn waitFor(sh: *Shell, done: *const fn (*Shell, ?*jobs.Job, i32) bool, j: ?*jobs.Job, pid: i32) ?u32 {
    while (!done(sh, j, pid)) {
        const r = sys.wait4(-1, 0) catch {
            if (sys.last_errno == .INTR) {
                var s: u32 = 1;
                while (s < signals.NSIG) : (s += 1) {
                    if (signals.isPending(s) and (sh.traps[s] != null or (s == linux.SIG.INT and sh.interactive))) return s;
                }
                continue;
            }
            // no more children: mark everything done
            for (sh.jobs.list.items) |jj| {
                for (jj.procs.items) |*p| {
                    if (p.state != .done) p.state = .done;
                }
            }
            return null;
        };
        _ = sh.jobs.update(r.pid, r.status);
    }
    return null;
}

fn allDone(sh: *Shell, _: ?*jobs.Job, _: i32) bool {
    for (sh.jobs.list.items) |j| {
        if (j.state() == .running) return false;
    }
    return true;
}

fn jobDone(_: *Shell, j: ?*jobs.Job, pid: i32) bool {
    const job = j orelse return true;
    if (pid > 0) {
        for (job.procs.items) |p| if (p.pid == pid) return p.state != .running;
        return true;
    }
    return job.state() != .running;
}

fn b_wait(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) {
        if (waitFor(sh, allDone, null, 0)) |sig| return @truncate(128 + sig);
        var idx: usize = 0;
        while (idx < sh.jobs.list.items.len) {
            const j = sh.jobs.list.items[idx];
            if (j.state() == .done) sh.jobs.remove(sh.gpa, j) else idx += 1;
        }
        return 0;
    }
    var status: u8 = 0;
    for (argv[1..]) |spec| {
        const is_pid = spec.len > 0 and spec[0] != '%';
        const pid: i32 = if (is_pid) (std.fmt.parseInt(i32, spec, 10) catch {
            sh.errMsg("wait: `{s}': not a pid or valid job spec", .{spec});
            status = 2;
            continue;
        }) else 0;
        const j = sh.jobs.resolve(spec) orelse {
            if (is_pid) {
                sh.errMsg("wait: pid {d} is not a child of this shell", .{pid});
            } else sh.errMsg("wait: {s}: no such job", .{spec});
            status = 127;
            continue;
        };
        if (waitFor(sh, jobDone, j, pid)) |sig| return @truncate(128 + sig);
        if (is_pid) {
            for (j.procs.items) |p| {
                if (p.pid == pid) status = jobs.statusCode(p.status);
            }
        } else status = j.exitCode(sh.opts.pipefail);
        if (j.state() == .done) sh.jobs.remove(sh.gpa, j);
    }
    return status;
}

fn b_kill(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    var sig: u32 = linux.SIG.TERM;
    if (argv.len < 2) {
        sh.errMsg("kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]", .{});
        return 2;
    }
    const first: []const u8 = argv[1];
    if (std.mem.eql(u8, first, "-l") or std.mem.eql(u8, first, "-L")) {
        if (argv.len > 2) {
            var status: u8 = 0;
            for (argv[2..]) |a| {
                if (parseNum(a)) |n| {
                    const s: u32 = @intCast(if (n > 128) n - 128 else @max(n, 0));
                    if (s > 0 and s < signals.names.len) sh.print("{s}\n", .{signals.name(s)}) else {
                        sh.errMsg("kill: {s}: invalid signal specification", .{a});
                        status = 1;
                    }
                } else if (signals.parse(a)) |s| {
                    sh.print("{d}\n", .{s});
                } else {
                    sh.errMsg("kill: {s}: invalid signal specification", .{a});
                    status = 1;
                }
            }
            return status;
        }
        var s: u32 = 1;
        while (s < signals.names.len) : (s += 1) {
            sh.print("{d:>2}) SIG{s:<10}", .{ s, signals.name(s) });
            if (s % 4 == 0) sh.write("\n");
        }
        sh.write("\n");
        return 0;
    }
    if (std.mem.eql(u8, first, "-s") or std.mem.eql(u8, first, "-n")) {
        if (argv.len < 3) {
            sh.errMsg("kill: {s}: option requires an argument", .{first});
            return 2;
        }
        sig = signals.parse(argv[2]) orelse {
            sh.errMsg("kill: {s}: invalid signal specification", .{argv[2]});
            return 1;
        };
        i = 3;
    } else if (first.len > 1 and first[0] == '-' and !std.mem.eql(u8, first, "--")) {
        sig = signals.parse(first[1..]) orelse {
            sh.errMsg("kill: {s}: invalid signal specification", .{first[1..]});
            return 1;
        };
        i = 2;
    }
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    var status: u8 = 0;
    while (i < argv.len) : (i += 1) {
        const t: []const u8 = argv[i];
        if (t.len > 0 and t[0] == '%') {
            const j = sh.jobs.resolve(t) orelse {
                sh.errMsg("kill: {s}: no such job", .{t});
                status = 1;
                continue;
            };
            if (sh.opts.monitor and j.pgid > 0) {
                sys.kill(-j.pgid, sig) catch {
                    sh.errMsg("kill: {s}: {s}", .{ t, sys.lastError() });
                    status = 1;
                };
            } else {
                for (j.procs.items) |p| sys.kill(p.pid, sig) catch {};
            }
            if (sig == linux.SIG.KILL or sig == linux.SIG.TERM or sig == linux.SIG.HUP) {
                if (j.state() == .stopped and sh.opts.monitor) sys.kill(-j.pgid, linux.SIG.CONT) catch {};
            }
            continue;
        }
        const pid = std.fmt.parseInt(i32, t, 10) catch {
            sh.errMsg("kill: {s}: arguments must be process or job IDs", .{t});
            status = 1;
            continue;
        };
        sys.kill(pid, sig) catch {
            sh.errMsg("kill: ({d}) - {s}", .{ pid, sys.lastError() });
            status = 1;
        };
    }
    return status;
}

// ---------------------------------------------------------------------------
// read
// ---------------------------------------------------------------------------

fn b_read(sh: *Shell, argv: Args) Error!u8 {
    var raw = false;
    var silent = false;
    var prompt: ?[]const u8 = null;
    var nchars: ?usize = null;
    var delim: u8 = '\n';
    var fd: i32 = 0;
    var timeout_ms: ?i32 = null;
    var i: usize = 1;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        const opt: []const u8 = argv[i];
        if (std.mem.eql(u8, opt, "--")) {
            i += 1;
            break;
        }
        var k: usize = 1;
        while (k < opt.len) : (k += 1) {
            const c = opt[k];
            switch (c) {
                'r' => raw = true,
                's' => silent = true,
                'p', 'n', 'd', 'u', 't', 'N' => {
                    var val: []const u8 = opt[k + 1 ..];
                    if (val.len == 0) {
                        i += 1;
                        if (i >= argv.len) {
                            sh.errMsg("read: -{c}: option requires an argument", .{c});
                            return 2;
                        }
                        val = argv[i];
                    }
                    switch (c) {
                        'p' => prompt = val,
                        'n', 'N' => nchars = @intCast(@max(0, parseNum(val) orelse {
                            sh.errMsg("read: {s}: invalid number", .{val});
                            return 2;
                        })),
                        'd' => delim = if (val.len > 0) val[0] else 0,
                        'u' => fd = @intCast(parseNum(val) orelse 0),
                        't' => {
                            const secs = std.fmt.parseFloat(f64, val) catch {
                                sh.errMsg("read: {s}: invalid timeout specification", .{val});
                                return 2;
                            };
                            timeout_ms = @intFromFloat(@min(secs * 1000.0, 2147483647.0));
                        },
                        else => {},
                    }
                    k = opt.len;
                },
                else => {
                    sh.errMsg("read: -{c}: invalid option", .{c});
                    return 2;
                },
            }
        }
    }
    const names: []const [:0]const u8 = argv[i..];
    for (names) |n| {
        if (!parser.isName(n)) {
            sh.errMsg("read: `{s}': not a valid identifier", .{n});
            return 2;
        }
    }
    const tty = sys.isatty(fd);
    if (prompt) |p| {
        if (tty) sh.errWrite(p);
    }
    var saved_tio: ?sys.termios = null;
    if (tty and (silent or nchars != null)) {
        if (sys.tcgetattr(fd)) |t| {
            saved_tio = t;
            var nt = t;
            if (silent) nt.lflag.ECHO = false;
            if (nchars != null) {
                nt.lflag.ICANON = false;
                nt.cc[@intFromEnum(linux.V.MIN)] = 1;
                nt.cc[@intFromEnum(linux.V.TIME)] = 0;
            }
            sys.tcsetattr(fd, &nt) catch {};
        } else |_| {}
    }
    defer if (saved_tio) |t| {
        sys.tcsetattr(fd, &t) catch {};
        if (silent) sh.errWrite("\n");
    };

    const a = sh.scratchAlloc();
    var line: std.ArrayList(u8) = .empty;
    var esc: std.ArrayList(bool) = .empty;
    var got_delim = false;
    var count: usize = 0;
    while (true) {
        if (nchars) |n| if (count >= n) {
            got_delim = true;
            break;
        };
        var b: [1]u8 = undefined;
        if (timeout_ms) |t| {
            if (!sys.pollIn(fd, t)) {
                // timed out: assign what we have, status > 128
                const partial = line.items;
                if (names.len == 0) try sh.setVar("REPLY", partial) else try sh.setVar(names[0], partial);
                return 142;
            }
        }
        const n = sys.readIntr(fd, &b) catch {
            if (sys.last_errno == .INTR) {
                if (signals.any_pending.load(.seq_cst)) {
                    var s: u32 = 1;
                    while (s < signals.NSIG) : (s += 1) {
                        if (signals.isPending(s) and (sh.traps[s] != null or (s == linux.SIG.INT and sh.interactive))) {
                            try exec.checkInterrupts(sh);
                            return @truncate(128 + s);
                        }
                    }
                }
                continue;
            }
            break;
        };
        if (n == 0) break;
        const c = b[0];
        if (c == delim) {
            got_delim = true;
            break;
        }
        if (!raw and c == '\\') {
            const n2 = sys.read(fd, &b) catch break;
            if (n2 == 0) break;
            if (b[0] == '\n') continue;
            try line.append(a, b[0]);
            try esc.append(a, true);
            count += 1;
            continue;
        }
        try line.append(a, c);
        try esc.append(a, false);
        count += 1;
    }
    const status: u8 = if (got_delim) 0 else 1;
    if (names.len == 0) {
        try sh.setVar("REPLY", line.items);
        return status;
    }
    // IFS splitting, honouring escaped characters
    const ifs = sh.ifs();
    const s = line.items;
    const e = esc.items;
    const isIfs = struct {
        fn f(set: []const u8, str: []const u8, escv: []const bool, idx: usize) bool {
            return !escv[idx] and std.mem.indexOfScalar(u8, set, str[idx]) != null;
        }
    }.f;
    const isWs = struct {
        fn f(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n';
        }
    }.f;
    var p: usize = 0;
    while (p < s.len and isIfs(ifs, s, e, p) and isWs(s[p])) p += 1;
    for (names, 0..) |name, ni| {
        if (ni + 1 == names.len) {
            var end = s.len;
            while (end > p and isIfs(ifs, s, e, end - 1) and isWs(s[end - 1])) end -= 1;
            // a single trailing non-whitespace delimiter is removed too
            if (end > p and isIfs(ifs, s, e, end - 1) and !isWs(s[end - 1])) {
                var only_one = true;
                var q = p;
                while (q < end - 1) : (q += 1) {
                    if (isIfs(ifs, s, e, q) and !isWs(s[q])) only_one = false;
                }
                if (only_one) {
                    end -= 1;
                    while (end > p and isIfs(ifs, s, e, end - 1) and isWs(s[end - 1])) end -= 1;
                }
            }
            try sh.setVar(name, s[@min(p, end)..end]);
            break;
        }
        const start = p;
        while (p < s.len and !isIfs(ifs, s, e, p)) p += 1;
        try sh.setVar(name, s[start..p]);
        if (p < s.len) {
            var ws = isWs(s[p]);
            p += 1;
            while (p < s.len and isIfs(ifs, s, e, p)) {
                if (!isWs(s[p])) {
                    if (ws) {
                        ws = false;
                        p += 1;
                    } else break;
                } else p += 1;
            }
        }
    }
    return status;
}

// ---------------------------------------------------------------------------
// trap
// ---------------------------------------------------------------------------

/// Disposition the shell itself wants for `sig` when no trap is set.
pub fn defaultDisposition(sh: *Shell, sig: u32) sys.Handler {
    if (sh.ignored_on_entry[sig]) return .ignore;
    if (sh.interactive) {
        switch (sig) {
            linux.SIG.INT => return .catch_,
            linux.SIG.QUIT, linux.SIG.TERM, linux.SIG.TSTP, linux.SIG.TTIN, linux.SIG.TTOU => return if (sh.opts.monitor or sig == linux.SIG.QUIT or sig == linux.SIG.TERM) .ignore else .default,
            else => {},
        }
    }
    return .default;
}

fn setTrap(sh: *Shell, sig: u32, action: ?[]const u8) Error!void {
    if (sig != 0 and sig < 32 and sh.ignored_on_entry[sig] and !sh.interactive) return;
    if (sh.traps[sig]) |old| sh.gpa.free(old);
    sh.traps[sig] = if (action) |act| try sh.gpa.dupe(u8, act) else null;
    if (sig == 0 or sig >= 32) return;
    if (sig == linux.SIG.KILL or sig == linux.SIG.STOP) return;
    const s: u8 = @intCast(sig);
    if (action) |act| {
        if (act.len == 0) _ = sys.signal(s, .ignore, false) else _ = sys.signal(s, .catch_, false);
    } else {
        _ = sys.signal(s, defaultDisposition(sh, sig), false);
    }
}

fn printTrap(sh: *Shell, sig: u32) Error!void {
    const act = sh.traps[sig] orelse return;
    sh.print("trap -- {s} {s}\n", .{ try shell.quote(sh.scratchAlloc(), act), signals.name(sig) });
}

fn b_trap(sh: *Shell, argv: Args) Error!u8 {
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len or std.mem.eql(u8, argv[i], "-p")) {
        if (i < argv.len and i + 1 < argv.len) {
            for (argv[i + 1 ..]) |spec| {
                if (signals.parse(spec)) |s| try printTrap(sh, s);
            }
            return 0;
        }
        var s: u32 = 0;
        while (s < signals.NSIG) : (s += 1) try printTrap(sh, s);
        return 0;
    }
    if (std.mem.eql(u8, argv[i], "-l")) {
        var s: u32 = 1;
        while (s < signals.names.len) : (s += 1) {
            sh.print("{d:>2}) SIG{s:<10}", .{ s, signals.name(s) });
            if (s % 4 == 0) sh.write("\n");
        }
        sh.write("\n");
        return 0;
    }
    var action: ?[]const u8 = argv[i];
    var specs = argv[i + 1 ..];
    // `trap SIG ...` (first operand is a signal number) resets
    if (specs.len == 0) {
        specs = argv[i..];
        action = null;
    } else if (std.mem.eql(u8, argv[i], "-")) {
        action = null;
    } else if (parseNum(argv[i]) != null and signals.parse(argv[i]) != null) {
        specs = argv[i..];
        action = null;
    }
    var status: u8 = 0;
    for (specs) |spec| {
        const s = signals.parse(spec) orelse {
            sh.errMsg("trap: {s}: invalid signal specification", .{spec});
            status = 1;
            continue;
        };
        try setTrap(sh, s, action);
    }
    return status;
}

// ---------------------------------------------------------------------------
// umask / ulimit / times
// ---------------------------------------------------------------------------

fn b_umask(sh: *Shell, argv: Args) Error!u8 {
    var symbolic = false;
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "-S")) {
        symbolic = true;
        i += 1;
    }
    const cur = sys.umask(0o022);
    _ = sys.umask(cur);
    if (i >= argv.len) {
        if (symbolic) {
            const perm = ~cur & 0o777;
            var buf: [32]u8 = undefined;
            var n: usize = 0;
            const who = "ugo";
            for (who, 0..) |w, k| {
                const shift: u5 = @intCast(6 - 3 * k);
                const bits = (perm >> shift) & 7;
                if (k > 0) {
                    buf[n] = ',';
                    n += 1;
                }
                buf[n] = w;
                buf[n + 1] = '=';
                n += 2;
                if (bits & 4 != 0) {
                    buf[n] = 'r';
                    n += 1;
                }
                if (bits & 2 != 0) {
                    buf[n] = 'w';
                    n += 1;
                }
                if (bits & 1 != 0) {
                    buf[n] = 'x';
                    n += 1;
                }
            }
            sh.print("{s}\n", .{buf[0..n]});
        } else sh.print("{o:0>4}\n", .{cur});
        return 0;
    }
    const m: []const u8 = argv[i];
    if (m.len > 0 and std.ascii.isDigit(m[0])) {
        const v = std.fmt.parseInt(u32, m, 8) catch {
            sh.errMsg("umask: {s}: octal number out of range", .{m});
            return 1;
        };
        _ = sys.umask(v & 0o777);
        return 0;
    }
    // symbolic: [ugoa]*[=+-][rwx]*,...
    var perm: u32 = ~cur & 0o777;
    var clauses = std.mem.splitScalar(u8, m, ',');
    while (clauses.next()) |cl| {
        var k: usize = 0;
        var who: u32 = 0;
        while (k < cl.len and std.mem.indexOfScalar(u8, "ugoa", cl[k]) != null) : (k += 1) {
            who |= switch (cl[k]) {
                'u' => 0o700,
                'g' => 0o070,
                'o' => 0o007,
                else => 0o777,
            };
        }
        if (who == 0) who = 0o777;
        if (k >= cl.len or std.mem.indexOfScalar(u8, "=+-", cl[k]) == null) {
            sh.errMsg("umask: {s}: invalid symbolic mode", .{m});
            return 1;
        }
        const op = cl[k];
        k += 1;
        var bits: u32 = 0;
        while (k < cl.len) : (k += 1) {
            bits |= switch (cl[k]) {
                'r' => 0o444,
                'w' => 0o222,
                'x' => 0o111,
                else => {
                    sh.errMsg("umask: {s}: invalid symbolic mode", .{m});
                    return 1;
                },
            };
        }
        bits &= who;
        switch (op) {
            '=' => perm = (perm & ~who) | bits,
            '+' => perm |= bits,
            else => perm &= ~bits,
        }
    }
    _ = sys.umask(~perm & 0o777);
    return 0;
}

fn b_ulimit(sh: *Shell, argv: Args) Error!u8 {
    _ = argv;
    sh.print("unlimited\n", .{});
    return 0;
}

fn b_times(sh: *Shell, _: Args) Error!u8 {
    var self: linux.rusage = undefined;
    var kids: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &self);
    _ = linux.getrusage(linux.rusage.CHILDREN, &kids);
    const P = struct {
        fn t(sh2: *Shell, tv: linux.timeval) void {
            const s: i64 = @intCast(tv.sec);
            const ms: i64 = @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
            sh2.print("{d}m{d}.{d:0>3}s", .{ @divTrunc(s, 60), @mod(s, 60), @as(u64, @intCast(ms)) });
        }
    };
    P.t(sh, self.utime);
    sh.write(" ");
    P.t(sh, self.stime);
    sh.write("\n");
    P.t(sh, kids.utime);
    sh.write(" ");
    P.t(sh, kids.stime);
    sh.write("\n");
    return 0;
}

// ---------------------------------------------------------------------------
// getopts / let
// ---------------------------------------------------------------------------

fn getoptsErr(sh: *Shell, msg: []const u8, c: u8) void {
    sh.flushOut();
    var buf: [512]u8 = undefined;
    sh.errWrite(std.fmt.bufPrint(&buf, "{s}: {s} -- {c}\n", .{ sh.arg0, msg, c }) catch "");
}

fn b_getopts(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 3) {
        sh.errMsg("getopts: usage: getopts optstring name [arg ...]", .{});
        return 2;
    }
    const optstring: []const u8 = argv[1];
    const varname: []const u8 = argv[2];
    const args: []const []const u8 = if (argv.len > 3) try exec.argSlices(sh, @ptrCast(argv[3..])) else blk: {
        const tmp = try sh.scratchAlloc().alloc([]const u8, sh.params.len);
        for (sh.params, 0..) |p, k| tmp[k] = p;
        break :blk tmp;
    };
    const silent = optstring.len > 0 and optstring[0] == ':';
    var optind: usize = @intCast(@max(1, parseNum(sh.getVar("OPTIND") orelse "1") orelse 1));
    var pos = sh.getopts_pos;
    if (pos == 0) pos = 1;

    const setInd = struct {
        fn f(s: *Shell, ind: usize, p: usize) Error!void {
            var nb: [24]u8 = undefined;
            try s.setVar("OPTIND", std.fmt.bufPrint(&nb, "{d}", .{ind}) catch unreachable);
            s.getopts_pos = p;
        }
    }.f;

    if (optind > args.len) {
        try sh.setVar(varname, "?");
        _ = try sh.unsetVar("OPTARG");
        try setInd(sh, optind, 0);
        return 1;
    }
    const arg = args[optind - 1];
    if (pos == 1) {
        if (arg.len < 2 or arg[0] != '-') {
            try sh.setVar(varname, "?");
            try setInd(sh, optind, 0);
            return 1;
        }
        if (std.mem.eql(u8, arg, "--")) {
            try sh.setVar(varname, "?");
            try setInd(sh, optind + 1, 0);
            return 1;
        }
    }
    if (pos >= arg.len) {
        optind += 1;
        pos = 1;
        try setInd(sh, optind, 0);
        return b_getopts(sh, argv);
    }
    const c = arg[pos];
    const cs = [1]u8{c};
    const idx = if (c == ':') null else std.mem.indexOfScalar(u8, optstring, c);
    pos += 1;
    var next_ind = optind;
    var next_pos = pos;
    if (pos >= arg.len) {
        next_ind += 1;
        next_pos = 0;
    }
    if (idx == null) {
        try sh.setVar(varname, "?");
        if (silent) {
            try sh.setVar("OPTARG", &cs);
        } else {
            _ = try sh.unsetVar("OPTARG");
            getoptsErr(sh, "illegal option", c);
        }
        try setInd(sh, next_ind, next_pos);
        return 0;
    }
    const needs_arg = idx.? + 1 < optstring.len and optstring[idx.? + 1] == ':';
    if (needs_arg) {
        if (pos < arg.len) {
            try sh.setVar("OPTARG", arg[pos..]);
            next_ind = optind + 1;
        } else if (optind < args.len) {
            try sh.setVar("OPTARG", args[optind]);
            next_ind = optind + 2;
        } else {
            if (silent) {
                try sh.setVar(varname, ":");
                try sh.setVar("OPTARG", &cs);
            } else {
                try sh.setVar(varname, "?");
                _ = try sh.unsetVar("OPTARG");
                getoptsErr(sh, "option requires an argument", c);
            }
            try setInd(sh, optind + 1, 0);
            return 0;
        }
        next_pos = 0;
    } else {
        _ = try sh.unsetVar("OPTARG");
    }
    try sh.setVar(varname, &cs);
    try setInd(sh, next_ind, next_pos);
    return 0;
}

fn b_let(sh: *Shell, argv: Args) Error!u8 {
    if (argv.len < 2) {
        sh.errMsg("let: expression expected", .{});
        return 1;
    }
    var v: i64 = 0;
    for (argv[1..]) |e| v = try arith.eval(sh, e);
    return if (v != 0) 0 else 1;
}
