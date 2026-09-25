//! zensh — the Zen OS shell.
//!
//! Entry point: option parsing, startup files, and the three input loops
//! (command string / script file, non-interactive stdin, interactive REPL).
const std = @import("std");
const sys = @import("sys.zig");
const mem = @import("mem.zig");
const shell = @import("shell.zig");
const exec = @import("exec.zig");
const parser = @import("parser.zig");
const signals = @import("signals.zig");
const builtins = @import("builtins.zig");
const editor = @import("editor.zig");
const prompt = @import("prompt.zig");
const jobs = @import("jobs.zig");
const ast = @import("ast.zig");
const linux = std.os.linux;
const Shell = shell.Shell;

var the_shell: Shell = undefined;

fn usage() noreturn {
    sys.writeAll(2,
        \\usage: zensh [-ilsx...] [-o option] [-c command [name [arg ...]] | script [arg ...]]
        \\  -c cmd   execute cmd and exit
        \\  -i       force interactive mode
        \\  -l       login shell (read /etc/profile and ~/.profile)
        \\  -s       read commands from standard input
        \\  -e -u -x -v -f -n -a -C -m   set shell options (see `help set`)
        \\  --norc --noprofile --version --help
        \\
    ) catch {};
    sys.exit(2);
}

fn setRecursionLimit() void {
    // Each level of shell function nesting needs a few KiB of native stack.
    var rl: linux.rlimit = undefined;
    if (linux.E.init(linux.getrlimit(.STACK, &rl)) != .SUCCESS) {
        exec.max_func_depth = 256;
        return;
    }
    if (rl.cur == linux.RLIM.INFINITY) return;
    const levels = rl.cur / 4096;
    exec.max_func_depth = @intCast(std.math.clamp(levels, 16, 1000));
}

pub fn main() u8 {
    const sh = &the_shell;
    sh.init(mem.gpa);
    signals.installHook();
    setRecursionLimit();

    const argv = std.os.argv;
    var arg0: []const u8 = if (argv.len > 0) std.mem.span(argv[0]) else "zensh";
    sh.arg0 = arg0;
    if (arg0.len > 0 and arg0[0] == '-') sh.login = true;

    var cmd_mode = false;
    var force_interactive = false;
    var read_stdin = false;
    var norc = false;
    var noprofile = false;
    var i: usize = 1;
    var pending_opts: std.ArrayList(struct { name: []const u8, on: bool }) = .empty;
    while (i < argv.len) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--login")) {
                sh.login = true;
            } else if (std.mem.eql(u8, a, "--norc")) {
                norc = true;
            } else if (std.mem.eql(u8, a, "--noprofile")) {
                noprofile = true;
            } else if (std.mem.eql(u8, a, "--posix") or std.mem.eql(u8, a, "--noediting")) {} else if (std.mem.eql(u8, a, "--version")) {
                sys.writeAll(1, "zensh " ++ shell.version ++ " (Zen OS)\n") catch {};
                return 0;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
            } else {
                sys.writeAll(2, "zensh: unknown option: ") catch {};
                sys.writeAll(2, a) catch {};
                sys.writeAll(2, "\n") catch {};
                usage();
            }
            i += 1;
            continue;
        }
        if (a.len < 2 or (a[0] != '-' and a[0] != '+')) break;
        const on = a[0] == '-';
        for (a[1..]) |c| {
            switch (c) {
                'c' => cmd_mode = on,
                'i' => force_interactive = on,
                's' => read_stdin = on,
                'l' => sh.login = on,
                'o' => {
                    i += 1;
                    if (i >= argv.len) usage();
                    pending_opts.append(mem.gpa, .{ .name = std.mem.span(argv[i]), .on = on }) catch {};
                },
                else => {
                    var found = false;
                    inline for (shell.option_table) |o| {
                        if (o.letter != 0 and o.letter == c) {
                            @field(sh.opts, o.field) = on;
                            found = true;
                        }
                    }
                    if (!found) {
                        var buf: [64]u8 = undefined;
                        sys.writeAll(2, std.fmt.bufPrint(&buf, "zensh: -{c}: invalid option\n", .{c}) catch "") catch {};
                        usage();
                    }
                },
            }
        }
        i += 1;
    }
    for (pending_opts.items) |po| {
        if (!builtins.setNamed(sh, po.name, po.on)) {
            var buf: [128]u8 = undefined;
            sys.writeAll(2, std.fmt.bufPrint(&buf, "zensh: {s}: invalid option name\n", .{po.name}) catch "") catch {};
            usage();
        }
    }

    var cmd_string: ?[]const u8 = null;
    var script: ?[]const u8 = null;
    var params: []const [*:0]u8 = &.{};
    if (cmd_mode) {
        if (i >= argv.len) {
            sys.writeAll(2, "zensh: -c: option requires an argument\n") catch {};
            return 2;
        }
        cmd_string = std.mem.span(argv[i]);
        i += 1;
        if (i < argv.len) {
            arg0 = std.mem.span(argv[i]);
            sh.arg0 = arg0;
            i += 1;
        }
        params = argv[i..];
        sh.cmd_string = true;
    } else if (!read_stdin and i < argv.len) {
        script = std.mem.span(argv[i]);
        sh.arg0 = script.?;
        params = argv[i + 1 ..];
    } else {
        read_stdin = true;
        params = argv[i..];
    }
    {
        var list: std.ArrayList([]const u8) = .empty;
        for (params) |p| list.append(mem.gpa, std.mem.span(p)) catch {};
        sh.setParams(list.items) catch {};
        list.deinit(mem.gpa);
    }
    sh.reading_stdin = read_stdin;
    sh.interactive = force_interactive or (cmd_string == null and script == null and sys.isatty(0) and sys.isatty(2));
    if (script) |s| sh.script_name = s;
    if (cmd_string != null) sh.script_name = "zensh";

    initVars(sh);
    initSignals(sh);
    if (sh.interactive) initInteractive(sh);

    // startup files
    if (sh.login and !noprofile) {
        sourceIfExists(sh, "/etc/profile");
        if (sh.getVar("HOME")) |h| sourceIfExists(sh, joinTmp(sh, h, ".profile"));
    }
    if (sh.interactive and !norc) {
        if (sh.getVar("ENV")) |env| {
            sourceIfExists(sh, env);
        } else if (sh.getVar("HOME")) |h| sourceIfExists(sh, joinTmp(sh, h, ".zenshrc"));
    }

    if (cmd_string) |c| {
        const st = exec.runString(sh, c, .{}) catch |e| exec.errStatus(sh, e);
        exec.exitShell(sh, st);
    }
    if (script) |path| runScript(sh, path);
    if (sh.interactive) repl(sh);
    stdinLoop(sh);
}

fn joinTmp(sh: *Shell, dir: []const u8, name: []const u8) []const u8 {
    return std.mem.concat(sh.scratchAlloc(), u8, &.{ dir, "/", name }) catch name;
}

fn sourceIfExists(sh: *Shell, path: []const u8) void {
    const st = sys.stat(path) catch return;
    if (!sys.isReg(st)) return;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const data = shell.readFileAlloc(sh.scratchAlloc(), path, 16 << 20) orelse return;
    const old = sh.script_name;
    sh.script_name = path;
    sh.source_depth += 1;
    defer {
        sh.source_depth -= 1;
        sh.script_name = old;
    }
    _ = exec.runString(sh, data, .{ .soft_syntax = true }) catch |e| switch (e) {
        error.Exit => exec.exitShell(sh, sh.exit_status),
        else => {},
    };
}

fn initVars(sh: *Shell) void {
    for (std.os.environ) |envp| {
        const kv = std.mem.span(envp);
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const name = kv[0..eq];
        if (!parser.isName(name)) continue;
        sh.setVarFlags(name, kv[eq + 1 ..], .{ .exported = true }) catch {};
    }
    const a = sh.scratchAlloc();
    sh.setVar("IFS", " \t\n") catch {};
    if (sh.getVar("PS2") == null) sh.setVar("PS2", "> ") catch {};
    if (sh.getVar("PS4") == null) sh.setVar("PS4", "+ ") catch {};
    sh.setVar("OPTIND", "1") catch {};
    sh.setVar("PPID", std.fmt.allocPrint(a, "{d}", .{sys.getppid()}) catch "0") catch {};
    sh.setVar("ZENSH_VERSION", shell.version) catch {};
    if (sh.getVar("PATH") == null) sh.setVarFlags("PATH", "/bin:/usr/bin:/sbin:/usr/sbin", .{ .exported = true }) catch {};
    if (sh.getVar("HOME") == null) {
        if (shell.passwdLookup(a, .{ .uid = sys.getuid() })) |pw| sh.setVar("HOME", pw.home) catch {};
    }
    // PWD: keep the inherited value if it names the current directory
    var keep = false;
    if (sh.getVar("PWD")) |p| {
        if (p.len > 0 and p[0] == '/') {
            const s1 = sys.stat(p) catch null;
            const s2 = sys.stat(".") catch null;
            keep = s1 != null and s2 != null and s1.?.ino == s2.?.ino and s1.?.dev == s2.?.dev;
        }
    }
    if (!keep) {
        const buf = a.alloc(u8, sys.PATH_MAX) catch return;
        if (sys.getcwd(buf)) |cwd| sh.setVarFlags("PWD", cwd, .{ .exported = true }) catch {} else |_| {}
    }
    const lvl = std.fmt.parseInt(i64, sh.getVar("SHLVL") orelse "0", 10) catch 0;
    sh.setVarFlags("SHLVL", std.fmt.allocPrint(a, "{d}", .{lvl + 1}) catch "1", .{ .exported = true }) catch {};
}

fn initSignals(sh: *Shell) void {
    var s: u8 = 1;
    while (s < 32) : (s += 1) {
        if (s == linux.SIG.KILL or s == linux.SIG.STOP) continue;
        if (sys.getSignal(s) == .ignore) sh.ignored_on_entry[s] = true;
    }
    // Commands run by the shell must not inherit a blocked signal mask.
    sys.unblockAllSignals();
    if (sh.interactive) {
        sh.ignored_on_entry = @splat(false);
        _ = sys.signal(linux.SIG.INT, .catch_, false);
        _ = sys.signal(linux.SIG.QUIT, .ignore, false);
        _ = sys.signal(linux.SIG.TERM, .ignore, false);
        _ = sys.signal(linux.SIG.WINCH, .catch_, false);
    }
}

fn initInteractive(sh: *Shell) void {
    // job control
    var tty: i32 = -1;
    if (sys.isatty(0)) tty = 0 else if (sys.isatty(2)) tty = 2;
    if (tty >= 0) {
        sh.tty_fd = sys.dupHigh(tty, 255) catch (sys.dupHigh(tty, 10) catch -1);
    }
    if (sh.tty_fd >= 0) {
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            const fg = sys.tcgetpgrp(sh.tty_fd) catch break;
            const pg = sys.getpgrp();
            if (fg == pg) break;
            sys.kill(-pg, linux.SIG.TTIN) catch break;
        }
        _ = sys.signal(linux.SIG.TSTP, .ignore, false);
        _ = sys.signal(linux.SIG.TTIN, .ignore, false);
        _ = sys.signal(linux.SIG.TTOU, .ignore, false);
        const me = sys.getpid();
        if (sys.getpgrp() != me) sys.setpgid(0, me) catch {};
        sh.shell_pgid = sys.getpgrp();
        if (sys.tcsetpgrp(sh.tty_fd, sh.shell_pgid)) {
            sh.opts.monitor = true;
        } else |_| {}
        sh.shell_tmodes = sys.tcgetattr(sh.tty_fd) catch null;
    }
    if (sh.getVar("PS1") == null) sh.setVar("PS1", prompt.default_ps1) catch {};
    prompt.initIdentity(sh);
    if (sh.getVar("HISTFILE") == null) {
        if (sh.getVar("HOME")) |h| sh.setVar("HISTFILE", joinTmp(sh, h, ".zensh_history")) catch {};
    }
    if (sh.getVar("HISTSIZE")) |hs| sh.hist.max = std.fmt.parseInt(usize, hs, 10) catch 1000;
    if (sh.getVar("HISTFILE")) |hf| {
        if (hf.len > 0) sh.hist.load(sh.gpa, hf);
    }
}

fn runScript(sh: *Shell, path: []const u8) noreturn {
    const data = shell.readFileAlloc(sh.gpa, path, 256 << 20) orelse {
        const e = sys.last_errno;
        var buf: [512]u8 = undefined;
        sys.writeAll(2, std.fmt.bufPrint(&buf, "zensh: {s}: {s}\n", .{ path, sys.strerror(e) }) catch "") catch {};
        sys.exit(if (e == .NOENT) 127 else 126);
    };
    const st = exec.runString(sh, data, .{}) catch |e| exec.errStatus(sh, e);
    exec.exitShell(sh, st);
}

/// Report finished / stopped background jobs.
pub fn notifyJobs(sh: *Shell) void {
    sh.jobs.reapNonBlocking();
    var idx: usize = 0;
    while (idx < sh.jobs.list.items.len) {
        const j = sh.jobs.list.items[idx];
        const st = j.state();
        if (j.bg and st == .done) {
            if (sh.interactive) {
                var buf: [512]u8 = undefined;
                var sb: [32]u8 = undefined;
                sh.errWrite(std.fmt.bufPrint(&buf, "[{d}]{c}  {s:<24}{s}\n", .{ j.id, sh.jobs.marker(j), jobs.stateText(&sb, j), j.text }) catch "");
                sh.jobs.remove(sh.gpa, j);
                continue;
            }
            // non-interactive shells keep finished jobs for `wait`, but
            // don't let the table grow without bound
            if (sh.jobs.list.items.len > 256) {
                sh.jobs.remove(sh.gpa, j);
                continue;
            }
        } else if (j.bg and st == .stopped and !j.notified and sh.interactive) {
            var buf: [512]u8 = undefined;
            var sb: [32]u8 = undefined;
            sh.errWrite(std.fmt.bufPrint(&buf, "[{d}]{c}  {s:<24}{s}\n", .{ j.id, sh.jobs.marker(j), jobs.stateText(&sb, j), j.text }) catch "");
            j.notified = true;
        }
        idx += 1;
    }
}

/// Execute parsed top-level commands; handles control-flow errors.
fn runNodes(sh: *Shell, nodes: []const *ast.Node) void {
    for (nodes) |n| {
        const st = exec.execNode(sh, n, .{}) catch |e| switch (e) {
            error.Exit => exec.exitShell(sh, sh.exit_status),
            error.Interrupted => {
                sh.last_status = 130;
                return;
            },
            error.Abort => {
                if (!sh.interactive) exec.exitShell(sh, sh.last_status);
                return;
            },
            else => exec.errStatus(sh, e),
        };
        sh.last_status = st;
        exec.checkInterrupts(sh) catch |e| switch (e) {
            error.Exit => exec.exitShell(sh, sh.exit_status),
            error.Interrupted => {
                sh.last_status = 130;
                return;
            },
            else => {},
        };
        if (!sh.interactive) notifyJobs(sh);
    }
}

const ParseResult = union(enum) { ok: []const *ast.Node, incomplete, syntax };

fn parseBuffer(sh: *Shell, src: []const u8, more: bool) ParseResult {
    var p = parser.Parser.init(sh.scratchAlloc(), sh.gpa, src);
    p.aliases = sh.aliasLookup();
    p.more_input = more;
    defer p.deinit();
    var nodes: std.ArrayList(*ast.Node) = .empty;
    while (true) {
        const n = p.parseCompleteCommand() catch |e| switch (e) {
            error.Incomplete => return .incomplete,
            error.OutOfMemory => {
                sh.errMsg("out of memory", .{});
                return .syntax;
            },
            error.Syntax => {
                exec.reportSyntax(sh, &p);
                return .syntax;
            },
        } orelse break;
        nodes.append(sh.scratchAlloc(), n) catch return .syntax;
    }
    return .{ .ok = nodes.items };
}

/// Line reader for non-interactive standard input. Reads exactly one line
/// at a time so commands that read stdin see the rest of the input.
const LineReader = struct {
    fd: i32,
    seekable: bool,

    fn init(fd: i32) LineReader {
        var seekable = false;
        if (sys.fstat(fd)) |st| {
            seekable = sys.isReg(st) and (sys.lseek(fd, 0, 1) catch -1) >= 0;
        } else |_| {}
        return .{ .fd = fd, .seekable = seekable };
    }

    /// Append one line (including '\n') to `out`. Returns false at EOF.
    fn readLine(self: *LineReader, a: std.mem.Allocator, out: *std.ArrayList(u8)) bool {
        var got = false;
        if (self.seekable) {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = sys.read(self.fd, &buf) catch return got;
                if (n == 0) return got;
                got = true;
                if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl| {
                    out.appendSlice(a, buf[0 .. nl + 1]) catch return false;
                    const back: i64 = @intCast(n - nl - 1);
                    if (back > 0) _ = sys.lseek(self.fd, -back, 1) catch {};
                    return true;
                }
                out.appendSlice(a, buf[0..n]) catch return false;
            }
        }
        var b: [1]u8 = undefined;
        while (true) {
            const n = sys.read(self.fd, &b) catch return got;
            if (n == 0) return got;
            got = true;
            out.append(a, b[0]) catch return false;
            if (b[0] == '\n') return true;
        }
    }
};

fn stdinLoop(sh: *Shell) noreturn {
    var reader = LineReader.init(0);
    var buf: std.ArrayList(u8) = .empty;
    while (true) {
        buf.clearRetainingCapacity();
        if (!reader.readLine(sh.gpa, &buf)) exec.exitShell(sh, sh.last_status);
        while (true) {
            const m = sh.scratch.mark();
            defer sh.scratch.release(m);
            switch (parseBuffer(sh, buf.items, true)) {
                .incomplete => {
                    if (reader.readLine(sh.gpa, &buf)) continue;
                    // EOF inside a construct: report it
                    _ = parseBuffer(sh, buf.items, false);
                    exec.exitShell(sh, 2);
                },
                .syntax => exec.exitShell(sh, 2),
                .ok => |nodes| {
                    if (sh.opts.verbose) sh.errWrite(buf.items);
                    if (!sh.opts.noexec) runNodes(sh, nodes);
                },
            }
            break;
        }
    }
}

fn repl(sh: *Shell) noreturn {
    var ed = editor.Editor.init(sh);
    var buf: std.ArrayList(u8) = .empty;
    while (true) {
        notifyJobs(sh);
        exec.checkInterrupts(sh) catch |e| switch (e) {
            error.Exit => exec.exitShell(sh, sh.exit_status),
            else => {},
        };
        buf.clearRetainingCapacity();
        if (sh.getVar("PROMPT_COMMAND")) |pc| {
            if (pc.len > 0) {
                const saved = sh.last_status;
                const mp = sh.scratch.mark();
                const copy = sh.scratchAlloc().dupe(u8, pc) catch "";
                _ = exec.runString(sh, copy, .{ .soft_syntax = true }) catch |e| switch (e) {
                    error.Exit => exec.exitShell(sh, sh.exit_status),
                    else => {},
                };
                sh.scratch.release(mp);
                sh.last_status = saved;
            }
        }
        const m0 = sh.scratch.mark();
        const ps1 = prompt.render(sh, sh.getVar("PS1") orelse "$ ");
        const line = ed.readLine(ps1) orelse {
            sh.scratch.release(m0);
            if (sh.opts.ignoreeof) {
                sh.errWrite("Use \"exit\" to leave the shell.\n");
                continue;
            }
            if (!sh.exit_warned) {
                var stopped = false;
                for (sh.jobs.list.items) |j| {
                    if (j.state() == .stopped) stopped = true;
                }
                if (stopped) {
                    sh.errWrite("There are stopped jobs.\n");
                    sh.exit_warned = true;
                    continue;
                }
            }
            sh.errWrite("exit\n");
            exec.exitShell(sh, sh.last_status);
        };
        sh.scratch.release(m0);
        if (ed.interrupted) {
            sh.last_status = 130;
            continue;
        }
        buf.appendSlice(sh.gpa, line) catch continue;
        buf.append(sh.gpa, '\n') catch continue;
        while (true) {
            const m = sh.scratch.mark();
            defer sh.scratch.release(m);
            switch (parseBuffer(sh, buf.items, true)) {
                .incomplete => {
                    const ps2 = prompt.render(sh, sh.getVar("PS2") orelse "> ");
                    const more = ed.readLine(ps2) orelse {
                        _ = parseBuffer(sh, buf.items, false);
                        sh.last_status = 2;
                        break;
                    };
                    if (ed.interrupted) {
                        sh.last_status = 130;
                        break;
                    }
                    buf.appendSlice(sh.gpa, more) catch break;
                    buf.append(sh.gpa, '\n') catch break;
                    continue;
                },
                .syntax => {
                    sh.hist.add(sh.gpa, buf.items);
                    sh.last_status = 2;
                },
                .ok => |nodes| {
                    sh.hist.add(sh.gpa, buf.items);
                    if (nodes.len > 0) prompt.command_number += 1;
                    runNodes(sh, nodes);
                },
            }
            break;
        }
    }
}
