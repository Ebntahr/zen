//! The executor: walks the AST, forks and execs processes, runs builtins
//! and functions, and manages foreground/background jobs.
const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const builtins = @import("builtins.zig");
const jobs = @import("jobs.zig");
const signals = @import("signals.zig");
const parser = @import("parser.zig");
const redir = @import("redir.zig");
const arith = @import("arith.zig");
const glob = @import("glob.zig");
const Shell = shell.Shell;
const Error = shell.Error;
const linux = std.os.linux;

/// Maximum function nesting; lowered at startup when the stack is small.
pub var max_func_depth: u32 = 1000;

pub const Ctx = struct {
    /// We are in a forked child that exits after this node, so the final
    /// external command may be exec'd without forking.
    in_child: bool = false,
    /// Source text of the enclosing pipeline (for job messages).
    text: []const u8 = "",
};

pub const Assign = struct { name: []const u8, value: []const u8, append: bool };

pub fn argSlices(sh: *Shell, argv: []const [:0]u8) Error![]const []const u8 {
    const out = try sh.scratchAlloc().alloc([]const u8, argv.len);
    for (argv, 0..) |x, i| out[i] = x;
    return out;
}

pub fn execNode(sh: *Shell, node: *const ast.Node, ctx: Ctx) Error!u8 {
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const st: u8 = switch (node.*) {
        .simple => |*s| try execSimple(sh, s, ctx),
        .pipeline => |*p| try execPipeline(sh, p, ctx),
        .and_or => |*ao| try execAndOr(sh, ao, ctx),
        .list => |*l| try execList(sh, l, ctx),
        .subshell => |body| try execSubshell(sh, node, body, ctx),
        .group => |body| try execNode(sh, body, ctx),
        .redirected => |*r| try execRedirected(sh, r, ctx),
        .if_ => |*i| try execIf(sh, i, ctx),
        .loop => |*l| try execLoop(sh, l),
        .for_ => |*f| try execFor(sh, f),
        .case_ => |*c| try execCase(sh, c),
        .func => |*f| blk: {
            try sh.defineFunction(f);
            break :blk 0;
        },
        .arith => |*a| try execArith(sh, a),
    };
    sh.last_status = st;
    return st;
}

// ---------------------------------------------------------------------------
// traps and interrupts
// ---------------------------------------------------------------------------

/// Run pending trap actions; raise Interrupted for an untrapped SIGINT in
/// an interactive shell.
pub fn checkInterrupts(sh: *Shell) Error!void {
    if (!signals.any_pending.load(.seq_cst)) return;
    if (sh.in_trap) return;
    signals.any_pending.store(false, .seq_cst);
    var interrupted = false;
    var sig: u32 = 1;
    while (sig < signals.NSIG) : (sig += 1) {
        if (!signals.take(sig)) continue;
        if (sh.traps[sig]) |action| {
            if (action.len > 0) try runTrap(sh, action);
        } else if (sig == linux.SIG.INT and sh.interactive) {
            interrupted = true;
        }
    }
    if (interrupted) return error.Interrupted;
}

pub fn runTrap(sh: *Shell, action: []const u8) Error!void {
    const saved = sh.last_status;
    sh.in_trap = true;
    defer sh.in_trap = false;
    // copy: the trap may reset itself while running
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const act = try sh.scratchAlloc().dupe(u8, action);
    _ = runString(sh, act, .{}) catch |e| switch (e) {
        error.Exit => return e,
        error.Interrupted => return e,
        else => {},
    };
    sh.last_status = saved;
}

/// Run the EXIT trap (once). Returns the status passed to `exit` if the
/// trap action called it.
pub fn runExitTrap(sh: *Shell) ?u8 {
    const action = sh.traps[0] orelse return null;
    sh.traps[0] = null;
    defer sh.gpa.free(action);
    if (action.len == 0) return null;
    sh.in_trap = true;
    _ = runString(sh, action, .{}) catch |e| switch (e) {
        error.Exit => return sh.exit_status,
        else => {},
    };
    return null;
}

// ---------------------------------------------------------------------------
// running source text
// ---------------------------------------------------------------------------

pub const RunOpts = struct {
    line_base: u32 = 1,
    /// report syntax errors and return 2 instead of aborting
    soft_syntax: bool = false,
};

pub fn reportSyntax(sh: *Shell, p: *parser.Parser) void {
    const saved = sh.lineno;
    sh.lineno = p.err_line;
    sh.errMsg("{s}", .{p.err_msg});
    sh.lineno = saved;
}

/// Parse and execute source text one complete command at a time.
pub fn runString(sh: *Shell, src: []const u8, opts: RunOpts) Error!u8 {
    var p = parser.Parser.init(sh.scratchAlloc(), sh.gpa, src);
    p.aliases = sh.aliasLookup();
    p.line_base = opts.line_base;
    defer p.deinit();
    var status: u8 = 0;
    while (true) {
        const m = sh.scratch.mark();
        defer sh.scratch.release(m);
        const start = p.pos;
        const node = p.parseCompleteCommand() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                reportSyntax(sh, &p);
                sh.last_status = 2;
                if (opts.soft_syntax or sh.interactive) return 2;
                sh.exit_status = 2;
                return error.Exit;
            },
        } orelse break;
        if (sh.opts.verbose) sh.errWrite(p.src[@min(start, p.src.len)..@min(p.pos, p.src.len)]);
        if (sh.opts.noexec and !sh.interactive) continue;
        status = try execNode(sh, node, .{});
        try checkInterrupts(sh);
    }
    return status;
}

// ---------------------------------------------------------------------------
// lists
// ---------------------------------------------------------------------------

noinline fn execList(sh: *Shell, l: *const ast.List, ctx: Ctx) Error!u8 {
    var st: u8 = 0;
    for (l.items, 0..) |item, i| {
        const last = i + 1 == l.items.len;
        if (item.bg) {
            st = try execBackground(sh, item.node, item.text);
        } else {
            st = try execNode(sh, item.node, if (last) ctx else .{});
        }
        sh.last_status = st;
        try checkInterrupts(sh);
    }
    return st;
}

noinline fn execAndOr(sh: *Shell, ao: *const ast.AndOr, ctx: Ctx) Error!u8 {
    var st: u8 = blk: {
        sh.errexit_suppress += 1;
        defer sh.errexit_suppress -= 1;
        break :blk try execNode(sh, ao.first, .{});
    };
    for (ao.rest, 0..) |item, i| {
        const last = i + 1 == ao.rest.len;
        if ((item.op == .and_ and st != 0) or (item.op == .or_ and st == 0)) continue;
        try checkInterrupts(sh);
        if (!last) sh.errexit_suppress += 1;
        defer if (!last) {
            sh.errexit_suppress -= 1;
        };
        st = try execNode(sh, item.node, if (last) ctx else .{});
    }
    return st;
}

fn errexitApplies(n: *const ast.Node) bool {
    return switch (n.*) {
        .simple, .subshell, .arith => true,
        .redirected => |r| errexitApplies(r.body),
        else => false,
    };
}

fn tvMicros(tv: linux.timeval) i64 {
    return @as(i64, @intCast(tv.sec)) * 1_000_000 + @as(i64, @intCast(tv.usec));
}

fn fmtDuration(buf: []u8, us: i64) []const u8 {
    const total_ms = @divTrunc(us, 1000);
    const mins = @divTrunc(total_ms, 60_000);
    const rest = total_ms - mins * 60_000;
    return std.fmt.bufPrint(buf, "{d}m{d}.{d:0>3}s", .{ mins, @divTrunc(rest, 1000), @as(u64, @intCast(@mod(rest, 1000))) }) catch "?";
}

noinline fn execTimed(sh: *Shell, p: *const ast.Pipeline, ctx: Ctx) Error!u8 {
    var ru0: linux.rusage = undefined;
    var ru1: linux.rusage = undefined;
    var self0: linux.rusage = undefined;
    var self1: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.CHILDREN, &ru0);
    _ = linux.getrusage(linux.rusage.SELF, &self0);
    const t0 = sys.monotonic();
    var untimed = p.*;
    untimed.timed = false;
    const st = execPipeline(sh, &untimed, ctx) catch |e| {
        reportTime(sh, t0, ru0, self0);
        return e;
    };
    _ = linux.getrusage(linux.rusage.CHILDREN, &ru1);
    _ = linux.getrusage(linux.rusage.SELF, &self1);
    reportTimeWith(sh, t0, ru0, ru1, self0, self1);
    return st;
}

fn reportTime(sh: *Shell, t0: linux.timespec, ru0: linux.rusage, self0: linux.rusage) void {
    var ru1: linux.rusage = undefined;
    var self1: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.CHILDREN, &ru1);
    _ = linux.getrusage(linux.rusage.SELF, &self1);
    reportTimeWith(sh, t0, ru0, ru1, self0, self1);
}

fn reportTimeWith(sh: *Shell, t0: linux.timespec, ru0: linux.rusage, ru1: linux.rusage, self0: linux.rusage, self1: linux.rusage) void {
    const t1 = sys.monotonic();
    const real_us = (@as(i64, @intCast(t1.sec)) - @as(i64, @intCast(t0.sec))) * 1_000_000 + @divTrunc(@as(i64, @intCast(t1.nsec)) - @as(i64, @intCast(t0.nsec)), 1000);
    const user_us = tvMicros(ru1.utime) - tvMicros(ru0.utime) + tvMicros(self1.utime) - tvMicros(self0.utime);
    const sys_us = tvMicros(ru1.stime) - tvMicros(ru0.stime) + tvMicros(self1.stime) - tvMicros(self0.stime);
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    var out: [160]u8 = undefined;
    sh.flushOut();
    sh.errWrite(std.fmt.bufPrint(&out, "\nreal\t{s}\nuser\t{s}\nsys\t{s}\n", .{
        fmtDuration(&b1, real_us), fmtDuration(&b2, user_us), fmtDuration(&b3, sys_us),
    }) catch "");
}

/// Run the ERR trap (bash extension) after a failed command.
fn runErrTrap(sh: *Shell, st: u8) Error!void {
    const action = sh.traps[signals.ERR_TRAP] orelse return;
    if (action.len == 0 or sh.in_trap) return;
    sh.last_status = st;
    try runTrap(sh, action);
    sh.last_status = st;
}

noinline fn execPipeline(sh: *Shell, p: *const ast.Pipeline, ctx: Ctx) Error!u8 {
    if (p.timed) return execTimed(sh, p, ctx);
    var st: u8 = undefined;
    if (p.cmds.len == 1) {
        if (p.bang) sh.errexit_suppress += 1;
        defer if (p.bang) {
            sh.errexit_suppress -= 1;
        };
        st = try execNode(sh, p.cmds[0], .{ .in_child = ctx.in_child and !p.bang, .text = p.text });
    } else {
        st = try runPipeline(sh, p.cmds, p.text, false);
    }
    if (p.bang) return if (st == 0) 1 else 0;
    if (st != 0 and sh.errexit_suppress == 0 and (p.cmds.len > 1 or errexitApplies(p.cmds[0]))) {
        sh.last_status = st;
        try runErrTrap(sh, st);
        if (sh.opts.errexit) {
            sh.exit_status = st;
            return error.Exit;
        }
    }
    return st;
}

noinline fn execBackground(sh: *Shell, node: *const ast.Node, text: []const u8) Error!u8 {
    switch (node.*) {
        .pipeline => |p| if (!p.bang) {
            _ = try runPipeline(sh, p.cmds, text, true);
            return 0;
        },
        else => {},
    }
    const one = [_]*const ast.Node{node};
    _ = try runPipeline(sh, &one, text, true);
    return 0;
}

// ---------------------------------------------------------------------------
// processes
// ---------------------------------------------------------------------------

/// Reset signal dispositions changed by the shell to their defaults in a
/// child process.
pub fn resetSignals(sh: *Shell) void {
    const sigs = [_]u8{ linux.SIG.INT, linux.SIG.QUIT, linux.SIG.TERM, linux.SIG.TSTP, linux.SIG.TTIN, linux.SIG.TTOU, linux.SIG.WINCH };
    for (sigs) |s| {
        if (!sh.ignored_on_entry[s]) _ = sys.signal(s, .default, false);
    }
    var s: u32 = 1;
    while (s < 32) : (s += 1) {
        if (s == linux.SIG.KILL or s == linux.SIG.STOP) continue;
        if (sh.traps[s]) |t| {
            if (t.len > 0) _ = sys.signal(@intCast(s), .default, false) else _ = sys.signal(@intCast(s), .ignore, false);
        }
    }
    sys.unblockAllSignals();
}

/// Turn the current (forked) process into a non-interactive subshell.
pub fn becomeSubshell(sh: *Shell) void {
    sh.interactive = false;
    sh.opts.monitor = false;
    sh.is_subshell = true;
    sh.jobs.clear(sh.gpa);
    sh.hist.path = null;
    for (&sh.traps, 0..) |*t, i| {
        if (t.*) |a| {
            if (a.len > 0 or i == 0) {
                sh.gpa.free(a);
                t.* = null;
            }
        }
    }
    signals.clearAll();
}

pub fn childSetup(sh: *Shell, pgid: i32, fg: bool) void {
    const monitor = sh.opts.monitor;
    if (monitor) {
        const me = sys.getpid();
        const pg = if (pgid == 0) me else pgid;
        sys.setpgid(0, pg) catch {};
        if (fg and sh.tty_fd >= 0) sys.tcsetpgrp(sh.tty_fd, pg) catch {};
    }
    resetSignals(sh);
    becomeSubshell(sh);
    if (!fg and !monitor) {
        _ = sys.signal(linux.SIG.INT, .ignore, false);
        _ = sys.signal(linux.SIG.QUIT, .ignore, false);
        if (sys.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0)) |fd| {
            sys.dup2(fd, 0) catch {};
            sys.close(fd);
        } else |_| {}
    }
}

pub fn errStatus(sh: *Shell, e: Error) u8 {
    return switch (e) {
        error.Exit => sh.exit_status,
        error.Return => sh.return_status,
        error.Abort => sh.last_status,
        error.Interrupted => 130,
        error.Break, error.Continue => sh.last_status,
        error.OutOfMemory => blk: {
            sh.errMsg("out of memory", .{});
            break :blk 2;
        },
    };
}

pub fn exitShell(sh: *Shell, st: u8) noreturn {
    var code = st;
    sh.last_status = st;
    if (runExitTrap(sh)) |c| code = c;
    sh.flushOut();
    if (sh.interactive and sh.tty_fd >= 0) {
        if (sh.shell_tmodes) |t| sys.tcsetattr(sh.tty_fd, &t) catch {};
    }
    sys.exit(code);
}

/// Execute `node` in a forked child and exit.
pub fn childRun(sh: *Shell, node: *const ast.Node) noreturn {
    const st = execNode(sh, node, .{ .in_child = true }) catch |e| errStatus(sh, e);
    exitShell(sh, st);
}

noinline fn runPipeline(sh: *Shell, cmds: []const *const ast.Node, text: []const u8, bg: bool) Error!u8 {
    sh.flushOut();
    const job = try sh.jobs.create(sh.gpa, text, bg);
    var prev: ?i32 = null;
    for (cmds, 0..) |cmd, i| {
        const last = i + 1 == cmds.len;
        var fds: [2]i32 = .{ -1, -1 };
        if (!last) {
            fds = sys.pipe() catch {
                sh.errMsg("pipe: {s}", .{sys.lastError()});
                break;
            };
        }
        const pid = sys.fork() catch {
            sh.errMsg("fork: {s}", .{sys.lastError()});
            if (!last) {
                sys.close(fds[0]);
                sys.close(fds[1]);
            }
            break;
        };
        if (pid == 0) {
            childSetup(sh, job.pgid, !bg);
            if (prev) |r| {
                sys.dup2(r, 0) catch {};
                sys.close(r);
            }
            if (!last) {
                sys.close(fds[0]);
                sys.dup2(fds[1], 1) catch {};
                sys.close(fds[1]);
            }
            childRun(sh, cmd);
        }
        if (job.pgid == 0) job.pgid = pid;
        if (sh.opts.monitor) sys.setpgid(pid, job.pgid) catch {};
        try job.procs.append(sh.gpa, .{ .pid = pid });
        if (prev) |r| sys.close(r);
        prev = null;
        if (!last) {
            sys.close(fds[1]);
            prev = fds[0];
        }
    }
    if (prev) |r| sys.close(r);
    if (job.procs.items.len == 0) {
        sh.jobs.remove(sh.gpa, job);
        return 1;
    }
    if (bg) {
        sh.last_bg_pid = job.procs.items[job.procs.items.len - 1].pid;
        if (sh.interactive) {
            var buf: [64]u8 = undefined;
            sh.errWrite(std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job.id, sh.last_bg_pid.? }) catch "");
        }
        return 0;
    }
    return waitForeground(sh, job);
}

/// Wait for a foreground job to finish or stop, then take the terminal back.
pub noinline fn waitForeground(sh: *Shell, job: *jobs.Job) Error!u8 {
    while (job.state() == .running) {
        const r = sys.wait4(-1, linux.W.UNTRACED) catch {
            if (sys.last_errno == .INTR) continue;
            for (job.procs.items) |*p| {
                if (p.state == .running) p.state = .done;
            }
            break;
        };
        _ = sh.jobs.update(r.pid, r.status);
    }
    if (sh.opts.monitor and sh.tty_fd >= 0) {
        sys.tcsetpgrp(sh.tty_fd, sh.shell_pgid) catch {};
        if (job.state() == .stopped) job.tmodes = sys.tcgetattr(sh.tty_fd) catch null;
        if (sh.shell_tmodes) |t| sys.tcsetattr(sh.tty_fd, &t) catch {};
    }
    if (job.state() == .stopped) {
        job.bg = true;
        job.notified = true;
        sh.jobs.touch(job);
        var buf: [512]u8 = undefined;
        var sb: [32]u8 = undefined;
        sh.errWrite(std.fmt.bufPrint(&buf, "\n[{d}]+  {s:<24}{s}\n", .{ job.id, jobs.stateText(&sb, job), job.text }) catch "\n");
        return job.exitCode(false);
    }
    const code = job.exitCode(sh.opts.pipefail);
    if (job.lastProc()) |lp| {
        const st = lp.status;
        if (linux.W.IFSIGNALED(st)) {
            const sig = linux.W.TERMSIG(st);
            if (sig == linux.SIG.INT) {
                if (sh.interactive) {
                    sh.errWrite("\n");
                    signals.pending[linux.SIG.INT].store(true, .seq_cst);
                    signals.any_pending.store(true, .seq_cst);
                }
            } else if (sig != linux.SIG.PIPE) {
                var buf: [128]u8 = undefined;
                const core = (st & 0x80) != 0;
                sh.errWrite(std.fmt.bufPrint(&buf, "{s}{s}\n", .{ signals.describe(sig), if (core) " (core dumped)" else "" }) catch "\n");
            }
        }
    }
    sh.jobs.remove(sh.gpa, job);
    return code;
}

/// $(...) and `...`: run `node` in a child and capture its standard output.
pub noinline fn commandSubst(sh: *Shell, node: *const ast.Node) Error![]const u8 {
    sh.flushOut();
    const fds = sys.pipe() catch {
        sh.errMsg("pipe: {s}", .{sys.lastError()});
        return "";
    };
    const pid = sys.fork() catch {
        sys.close(fds[0]);
        sys.close(fds[1]);
        sh.errMsg("fork: {s}", .{sys.lastError()});
        return "";
    };
    if (pid == 0) {
        sys.close(fds[0]);
        sys.dup2(fds[1], 1) catch sys.exit(1);
        sys.close(fds[1]);
        resetSignals(sh);
        becomeSubshell(sh);
        _ = sys.signal(linux.SIG.TSTP, .ignore, false);
        _ = sys.signal(linux.SIG.TTOU, .ignore, false);
        _ = sys.signal(linux.SIG.TTIN, .ignore, false);
        sh.trace_depth += 1;
        childRun(sh, node);
    }
    sys.close(fds[1]);
    const a = sh.scratchAlloc();
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        try out.ensureUnusedCapacity(a, 1024);
        const dest = out.unusedCapacitySlice();
        const n = sys.read(fds[0], dest) catch break;
        if (n == 0) break;
        // drop NUL bytes (they cannot be represented in shell strings)
        var w = out.items.len;
        for (dest[0..n]) |c| {
            if (c != 0) {
                out.items.ptr[w] = c;
                w += 1;
            }
        }
        out.items.len = w;
    }
    sys.close(fds[0]);
    var status: u32 = 0;
    while (true) {
        const r = sys.wait4(pid, 0) catch {
            if (sys.last_errno == .INTR) continue;
            break;
        };
        status = r.status;
        break;
    }
    const code = jobs.statusCode(status);
    sh.cmdsub_status = code;
    sh.last_status = code;
    var s = out.items;
    while (s.len > 0 and s[s.len - 1] == '\n') s.len -= 1;
    return s;
}

noinline fn execSubshell(sh: *Shell, node: *const ast.Node, body: *const ast.Node, ctx: Ctx) Error!u8 {
    if (ctx.in_child) return execNode(sh, body, ctx);
    const one = [_]*const ast.Node{node};
    return runPipeline(sh, &one, if (ctx.text.len > 0) ctx.text else "( ... )", false);
}

noinline fn execRedirected(sh: *Shell, r: *const ast.Redirected, ctx: Ctx) Error!u8 {
    if (ctx.in_child) {
        if (!try redir.apply(sh, r.redirs, null)) return 1;
        return execNode(sh, r.body, ctx);
    }
    var saved = redir.Saved{};
    defer redir.restore(sh, &saved);
    if (!try redir.apply(sh, r.redirs, &saved)) return 1;
    return execNode(sh, r.body, ctx);
}

// ---------------------------------------------------------------------------
// compound commands
// ---------------------------------------------------------------------------

noinline fn execIf(sh: *Shell, i: *const ast.If, ctx: Ctx) Error!u8 {
    const c = blk: {
        sh.errexit_suppress += 1;
        defer sh.errexit_suppress -= 1;
        break :blk try execNode(sh, i.cond, .{});
    };
    if (c == 0) return execNode(sh, i.then, ctx);
    if (i.else_) |e| return execNode(sh, e, ctx);
    return 0;
}

const LoopAction = enum { none, brk, cont };

fn loopControl(sh: *Shell, e: Error) Error!LoopAction {
    switch (e) {
        error.Break => {
            if (sh.break_n > 1) {
                sh.break_n -= 1;
                return e;
            }
            return .brk;
        },
        error.Continue => {
            if (sh.cont_n > 1) {
                sh.cont_n -= 1;
                return e;
            }
            return .cont;
        },
        else => return e,
    }
}

noinline fn execLoop(sh: *Shell, l: *const ast.Loop) Error!u8 {
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var st: u8 = 0;
    while (true) {
        try checkInterrupts(sh);
        const c = blk: {
            sh.errexit_suppress += 1;
            defer sh.errexit_suppress -= 1;
            break :blk execNode(sh, l.cond, .{}) catch |e| switch (try loopControl(sh, e)) {
                .brk => {
                    st = 0;
                    break;
                },
                .cont => continue,
                .none => unreachable,
            };
        };
        if ((c == 0) == l.until) break;
        st = execNode(sh, l.body, .{}) catch |e| switch (try loopControl(sh, e)) {
            .brk => {
                st = 0;
                break;
            },
            .cont => {
                st = 0;
                continue;
            },
            .none => unreachable,
        };
    }
    return st;
}

noinline fn execFor(sh: *Shell, f: *const ast.For) Error!u8 {
    const a = sh.scratchAlloc();
    var items: []const []const u8 = undefined;
    if (f.words) |w| {
        const list = try expand.expandWords(sh, w);
        const tmp = try a.alloc([]const u8, list.len);
        for (list, 0..) |x, i| tmp[i] = x;
        items = tmp;
    } else {
        const tmp = try a.alloc([]const u8, sh.params.len);
        for (sh.params, 0..) |x, i| tmp[i] = try a.dupe(u8, x);
        items = tmp;
    }
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var st: u8 = 0;
    for (items) |it| {
        try checkInterrupts(sh);
        try sh.setVar(f.name, it);
        st = execNode(sh, f.body, .{}) catch |e| switch (try loopControl(sh, e)) {
            .brk => {
                st = 0;
                break;
            },
            .cont => {
                st = 0;
                continue;
            },
            .none => unreachable,
        };
    }
    return st;
}

noinline fn execCase(sh: *Shell, c: *const ast.Case) Error!u8 {
    const word = try expand.wordToString(sh, c.word, false);
    var st: u8 = 0;
    var fall = false;
    for (c.items) |item| {
        var matched = fall;
        if (!matched) {
            for (item.pats) |pw| {
                const pat = try expand.expandPattern(sh, pw);
                if (glob.fnmatch(pat, word, .{})) {
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) continue;
        st = if (item.body) |b| try execNode(sh, b, .{}) else 0;
        switch (item.term) {
            .brk => return st,
            .fallthrough => fall = true,
            .cont => fall = false,
        }
    }
    return st;
}

noinline fn execArith(sh: *Shell, a: *const ast.ArithCmd) Error!u8 {
    sh.lineno = a.line;
    const expr = try expand.partsToString(sh, a.expr.parts, .{ .quoted = true });
    if (sh.opts.xtrace) {
        var buf: [512]u8 = undefined;
        sh.errWrite(std.fmt.bufPrint(&buf, "{s}(( {s} ))\n", .{ sh.getVar("PS4") orelse "+ ", expr }) catch "");
    }
    const v = try arith.eval(sh, expr);
    return if (v != 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// simple commands
// ---------------------------------------------------------------------------

fn assignVar(sh: *Shell, as: Assign) Error!void {
    if (as.append) {
        const old = sh.getVar(as.name) orelse "";
        const v = try std.mem.concat(sh.scratchAlloc(), u8, &.{ old, as.value });
        return sh.setVar(as.name, v);
    }
    return sh.setVar(as.name, as.value);
}

noinline fn xtrace(sh: *Shell, assigns: []const Assign, argv: []const [:0]u8) void {
    const a = sh.scratchAlloc();
    var line: std.ArrayList(u8) = .empty;
    const ps4 = sh.getVar("PS4") orelse "+ ";
    if (ps4.len > 0) line.appendNTimes(a, ps4[0], sh.trace_depth) catch return;
    line.appendSlice(a, ps4) catch return;
    var first = true;
    for (assigns) |as| {
        if (!first) line.append(a, ' ') catch return;
        first = false;
        line.appendSlice(a, as.name) catch return;
        line.append(a, '=') catch return;
        line.appendSlice(a, shell.quote(a, as.value) catch return) catch return;
    }
    for (argv) |w| {
        if (!first) line.append(a, ' ') catch return;
        first = false;
        line.appendSlice(a, shell.quote(a, w) catch return) catch return;
    }
    line.append(a, '\n') catch return;
    sh.flushOut();
    sh.errWrite(line.items);
}

noinline fn execSimple(sh: *Shell, s: *const ast.Simple, ctx: Ctx) Error!u8 {
    sh.lineno = s.line;
    sh.cmdsub_status = null;
    const argv = if (expand.isDeclUtility(s.words))
        try expand.expandDeclWords(sh, s.words)
    else
        try expand.expandWords(sh, s.words);
    const a = sh.scratchAlloc();
    const assigns = try a.alloc(Assign, s.assigns.len);
    for (s.assigns, 0..) |as, i| {
        assigns[i] = .{ .name = as.name, .value = try expand.wordToString(sh, as.value, true), .append = as.append };
    }
    if (sh.opts.xtrace and (argv.len > 0 or assigns.len > 0)) xtrace(sh, assigns, argv);

    if (argv.len == 0) {
        for (assigns) |as| try assignVar(sh, as);
        var st: u8 = sh.cmdsub_status orelse 0;
        if (s.redirs.len > 0) {
            var saved = redir.Saved{};
            const ok = redir.apply(sh, s.redirs, &saved) catch |e| {
                redir.restore(sh, &saved);
                return e;
            };
            redir.restore(sh, &saved);
            if (!ok) st = 1;
        }
        return st;
    }

    const name: []const u8 = argv[0];
    const bi = builtins.lookup(name);
    if (bi) |b| {
        if (b.special) {
            for (assigns) |as| try assignVar(sh, as);
            return runBuiltin(sh, b, argv, s.redirs);
        }
    }
    if (sh.funcs.get(name)) |f| return runFunction(sh, f, argv, assigns, s.redirs);
    if (bi) |b| {
        var pushed = false;
        if (assigns.len > 0) {
            try pushTemp(sh, assigns);
            pushed = true;
        }
        defer if (pushed) sh.popFrame();
        return runBuiltin(sh, b, argv, s.redirs);
    }
    return runExternal(sh, argv, assigns, s.redirs, ctx);
}

fn pushTemp(sh: *Shell, assigns: []const Assign) Error!void {
    try sh.pushFrame();
    for (assigns) |as| {
        var v = as.value;
        if (as.append) v = try std.mem.concat(sh.scratchAlloc(), u8, &.{ sh.getVar(as.name) orelse "", as.value });
        try sh.makeLocal(as.name, v);
        try sh.setVarFlags(as.name, null, .{ .exported = true });
    }
}

pub noinline fn runBuiltin(sh: *Shell, b: *const builtins.Builtin, argv: []const [:0]u8, redirs: []const ast.Redir) Error!u8 {
    if (std.mem.eql(u8, b.name, "exec")) {
        // redirections of `exec` are permanent
        if (!try redir.apply(sh, redirs, null)) {
            if (!sh.interactive) {
                sh.exit_status = 1;
                return error.Exit;
            }
            return 1;
        }
        return b.func(sh, argv);
    }
    var saved = redir.Saved{};
    defer redir.restore(sh, &saved);
    if (!try redir.apply(sh, redirs, &saved)) return 1;
    defer sh.flushOut();
    return b.func(sh, argv);
}

pub noinline fn runFunction(sh: *Shell, f: shell.Function, argv: []const [:0]u8, assigns: []const Assign, redirs: []const ast.Redir) Error!u8 {
    if (sh.func_depth >= max_func_depth) {
        sh.errMsg("{s}: maximum function nesting level exceeded ({d})", .{ f.name, max_func_depth });
        sh.last_status = 1;
        return error.Abort;
    }
    var saved = redir.Saved{};
    defer redir.restore(sh, &saved);
    if (!try redir.apply(sh, redirs, &saved)) return 1;
    var tmp = false;
    if (assigns.len > 0) {
        try pushTemp(sh, assigns);
        tmp = true;
    }
    defer if (tmp) sh.popFrame();

    const old_params = sh.params;
    const old_getopts = sh.getopts_pos;
    const old_loop = sh.loop_depth;
    sh.params = &.{};
    sh.setParams(try argSlices(sh, argv[1..])) catch |e| {
        sh.params = old_params;
        return e;
    };
    sh.loop_depth = 0;
    sh.func_depth += 1;
    try sh.pushFrame();
    defer {
        sh.popFrame();
        sh.func_depth -= 1;
        sh.loop_depth = old_loop;
        sh.freeParams(sh.params);
        sh.params = old_params;
        sh.getopts_pos = old_getopts;
    }
    return execNode(sh, f.body, .{}) catch |e| switch (e) {
        error.Return => sh.return_status,
        else => return e,
    };
}

/// Search PATH for an executable. Returns the path (owned by the hash
/// table) or null.
pub fn findCommand(sh: *Shell, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    if (sh.hash.get(name)) |p| {
        if (sys.isExecutableFile(p)) return p;
        if (sh.hash.fetchRemove(name)) |kv| {
            sh.gpa.free(kv.key);
            sh.gpa.free(kv.value);
        }
    }
    const path = sh.getVar("PATH") orelse "/bin:/usr/bin";
    return searchPath(sh, name, path, true);
}

pub fn searchPath(sh: *Shell, name: []const u8, path: []const u8, cache: bool) ?[]const u8 {
    const a = sh.scratchAlloc();
    var fallback: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = if (dir.len == 0) name else (std.mem.concat(a, u8, &.{ dir, if (dir[dir.len - 1] == '/') "" else "/", name }) catch return null);
        const st = sys.stat(full) catch continue;
        if (!sys.isReg(st)) continue;
        if (!sys.access(full, sys.X_OK)) {
            if (fallback == null) fallback = full;
            continue;
        }
        if (cache and sh.opts.hashall) {
            const k = sh.gpa.dupe(u8, name) catch return full;
            const v = sh.gpa.dupe(u8, full) catch {
                sh.gpa.free(k);
                return full;
            };
            sh.hash.put(sh.gpa, k, v) catch {
                sh.gpa.free(k);
                sh.gpa.free(v);
                return full;
            };
            return v;
        }
        return full;
    }
    return fallback;
}

noinline fn runExternal(sh: *Shell, argv: []const [:0]u8, assigns: []const Assign, redirs: []const ast.Redir, ctx: Ctx) Error!u8 {
    const name: []const u8 = argv[0];
    const path = findCommand(sh, name) orelse {
        var saved = redir.Saved{};
        defer redir.restore(sh, &saved);
        if (!try redir.apply(sh, redirs, &saved)) return 127;
        sh.errMsg("{s}: command not found", .{name});
        return 127;
    };
    if (ctx.in_child and sh.traps[0] == null) execCommand(sh, path, argv, assigns, redirs);
    sh.flushOut();
    const job = try sh.jobs.create(sh.gpa, if (ctx.text.len > 0) ctx.text else name, false);
    const pid = sys.fork() catch {
        sh.errMsg("fork: {s}", .{sys.lastError()});
        sh.jobs.remove(sh.gpa, job);
        return 126;
    };
    if (pid == 0) {
        childSetup(sh, 0, true);
        execCommand(sh, path, argv, assigns, redirs);
    }
    job.pgid = pid;
    if (sh.opts.monitor) sys.setpgid(pid, pid) catch {};
    try job.procs.append(sh.gpa, .{ .pid = pid });
    return waitForeground(sh, job);
}

/// Replace the current process with `path`. Never returns.
pub fn execCommand(sh: *Shell, path: []const u8, argv: []const [:0]u8, assigns: []const Assign, redirs: []const ast.Redir) noreturn {
    if (!(redir.apply(sh, redirs, null) catch false)) sys.exit(1);
    for (assigns) |as| sh.setVarFlags(as.name, as.value, .{ .exported = true, .force = true }) catch {};
    const a = sh.scratchAlloc();
    const envp = sh.buildEnv(a) catch sys.exit(126);
    const av = a.alloc(?[*:0]const u8, argv.len + 1) catch sys.exit(126);
    for (argv, 0..) |x, i| av[i] = x.ptr;
    av[argv.len] = null;
    const pathz = a.dupeZ(u8, path) catch sys.exit(126);
    const e = sys.execve(pathz, @ptrCast(av.ptr), envp);
    switch (e) {
        .NOEXEC => runScriptChild(sh, path, argv),
        .NOENT => {
            sh.errMsg("{s}: {s}", .{ path, sys.strerror(e) });
            sys.exit(127);
        },
        .ACCES => {
            if (sys.isDir(path)) {
                sh.errMsg("{s}: Is a directory", .{path});
            } else sh.errMsg("{s}: Permission denied", .{path});
            sys.exit(126);
        },
        else => {
            sh.errMsg("{s}: {s}", .{ path, sys.strerror(e) });
            sys.exit(126);
        },
    }
}

/// A file without a recognised executable format is run as a shell script
/// by a fresh (forked) shell.
fn runScriptChild(sh: *Shell, path: []const u8, argv: []const [:0]u8) noreturn {
    const data = shell.readFileAlloc(sh.gpa, path, 64 << 20) orelse {
        sh.errMsg("{s}: {s}", .{ path, sys.lastError() });
        sys.exit(126);
    };
    // looks binary? refuse like other shells do
    const probe = data[0..@min(data.len, 256)];
    if (std.mem.indexOfScalar(u8, probe, 0) != null) {
        sh.errMsg("{s}: cannot execute binary file", .{path});
        sys.exit(126);
    }
    var fit = sh.funcs.iterator();
    while (fit.next()) |e| sh.gpa.free(e.key_ptr.*);
    sh.funcs.clearRetainingCapacity();
    sh.arg0 = path;
    sh.setParams(argSlices(sh, argv[1..]) catch &.{}) catch {};
    sh.script_name = path;
    sh.func_depth = 0;
    sh.loop_depth = 0;
    sh.source_depth = 0;
    sh.errexit_suppress = 0;
    const st = runString(sh, data, .{}) catch |e| errStatus(sh, e);
    exitShell(sh, st);
}

/// Fork/exec a command found on PATH (used by `command`).
pub noinline fn runExternalPublic(sh: *Shell, argv: []const [:0]u8) Error!u8 {
    return runExternal(sh, argv, &.{}, &.{}, .{});
}
