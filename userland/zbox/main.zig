//! zbox: a BusyBox-style multi-call binary with GNU compatible core utilities
//! for Zen OS. Dispatches on basename(argv[0]) or `zbox <cmd> args...`.
const std = @import("std");
const c = @import("common.zig");

pub const std_options: std.Options = .{
    // Behave like C programs: die on SIGPIPE (and let exec'd children inherit
    // the default disposition).
    .keep_sigpipe = true,
    .enable_segfault_handler = false,
};

const MainFn = *const fn (c.Args) anyerror!u8;
const Cmd = struct { name: []const u8, run: MainFn, help: []const u8 };

fn cmd(comptime name: []const u8, comptime M: type) Cmd {
    return .{ .name = name, .run = M.main, .help = M.help };
}
fn cmdAs(comptime name: []const u8, comptime f: MainFn, comptime help: []const u8) Cmd {
    return .{ .name = name, .run = f, .help = help };
}

const hashsum = @import("cmd/hashsum.zig");
const reboot = @import("cmd/reboot.zig");
const test_cmd = @import("cmd/test.zig");
const less = @import("cmd/less.zig");
const chown = @import("cmd/chown.zig");
const who = @import("cmd/who.zig");
const clear = @import("cmd/clear.zig");
const truefalse = @import("cmd/true.zig");

pub const commands = [_]Cmd{
    cmd("arch", @import("cmd/arch.zig")),
    cmd("base64", @import("cmd/base64.zig")),
    cmd("basename", @import("cmd/basename.zig")),
    cmd("cat", @import("cmd/cat.zig")),
    cmdAs("chgrp", chown.mainChgrp, chown.help_chgrp),
    cmd("chmod", @import("cmd/chmod.zig")),
    cmd("chown", chown),
    cmd("cksum", @import("cmd/cksum.zig")),
    cmd("clear", clear),
    cmd("cmp", @import("cmd/cmp.zig")),
    cmd("column", @import("cmd/column.zig")),
    cmd("comm", @import("cmd/comm.zig")),
    cmd("cp", @import("cmd/cp.zig")),
    cmd("cut", @import("cmd/cut.zig")),
    cmd("date", @import("cmd/date.zig")),
    cmd("dd", @import("cmd/dd.zig")),
    cmd("df", @import("cmd/df.zig")),
    cmd("diff", @import("cmd/diff.zig")),
    cmd("dirname", @import("cmd/dirname.zig")),
    cmd("dmesg", @import("cmd/dmesg.zig")),
    cmd("du", @import("cmd/du.zig")),
    cmd("echo", @import("cmd/echo.zig")),
    cmd("env", @import("cmd/env.zig")),
    cmd("expr", @import("cmd/expr.zig")),
    cmd("factor", @import("cmd/factor.zig")),
    cmdAs("false", truefalse.mainFalse, truefalse.help_false),
    cmd("find", @import("cmd/find.zig")),
    cmd("fold", @import("cmd/fold.zig")),
    cmd("free", @import("cmd/free.zig")),
    cmd("getconf", @import("cmd/getconf.zig")),
    cmd("grep", @import("cmd/grep.zig")),
    cmdAs("egrep", @import("cmd/grep.zig").mainEgrep, @import("cmd/grep.zig").help),
    cmdAs("fgrep", @import("cmd/grep.zig").mainFgrep, @import("cmd/grep.zig").help),
    cmd("groups", @import("cmd/groups.zig")),
    cmdAs("halt", reboot.mainHalt, reboot.help_halt),
    cmd("head", @import("cmd/head.zig")),
    cmd("hexdump", @import("cmd/hexdump.zig")),
    cmd("hostname", @import("cmd/hostname.zig")),
    cmd("id", @import("cmd/id.zig")),
    cmd("install", @import("cmd/install.zig")),
    cmd("kill", @import("cmd/kill.zig")),
    cmd("killall", @import("cmd/killall.zig")),
    cmd("less", less),
    cmd("link", @import("cmd/link.zig")),
    cmd("ln", @import("cmd/ln.zig")),
    cmd("logname", @import("cmd/logname.zig")),
    cmd("ls", @import("cmd/ls.zig")),
    cmdAs("md5sum", hashsum.mainMd5, hashsum.help_md5),
    cmd("mkdir", @import("cmd/mkdir.zig")),
    cmd("mktemp", @import("cmd/mktemp.zig")),
    cmdAs("more", less.mainMore, less.help_more),
    cmd("mv", @import("cmd/mv.zig")),
    cmd("nice", @import("cmd/nice.zig")),
    cmd("nl", @import("cmd/nl.zig")),
    cmd("nohup", @import("cmd/nohup.zig")),
    cmd("nproc", @import("cmd/nproc.zig")),
    cmd("od", @import("cmd/od.zig")),
    cmd("paste", @import("cmd/paste.zig")),
    cmd("pidof", @import("cmd/pidof.zig")),
    cmdAs("poweroff", reboot.mainPoweroff, reboot.help_poweroff),
    cmd("printenv", @import("cmd/printenv.zig")),
    cmd("printf", @import("cmd/printf.zig")),
    cmd("ps", @import("cmd/ps.zig")),
    cmd("pwd", @import("cmd/pwd.zig")),
    cmd("readlink", @import("cmd/readlink.zig")),
    cmd("realpath", @import("cmd/realpath.zig")),
    cmd("reboot", reboot),
    cmdAs("reset", clear.mainReset, clear.help_reset),
    cmd("rev", @import("cmd/rev.zig")),
    cmd("rm", @import("cmd/rm.zig")),
    cmd("rmdir", @import("cmd/rmdir.zig")),
    cmd("sed", @import("cmd/sed.zig")),
    cmd("seq", @import("cmd/seq.zig")),
    cmdAs("sha1sum", hashsum.mainSha1, hashsum.help_sha1),
    cmdAs("sha256sum", hashsum.mainSha256, hashsum.help_sha256),
    cmdAs("sha512sum", hashsum.mainSha512, hashsum.help_sha512),
    cmd("sleep", @import("cmd/sleep.zig")),
    cmd("sort", @import("cmd/sort.zig")),
    cmd("split", @import("cmd/split.zig")),
    cmd("stat", @import("cmd/stat.zig")),
    cmd("strings", @import("cmd/strings.zig")),
    cmd("stty", @import("cmd/stty.zig")),
    cmd("sync", @import("cmd/sync.zig")),
    cmd("tac", @import("cmd/tac.zig")),
    cmd("tail", @import("cmd/tail.zig")),
    cmd("tee", @import("cmd/tee.zig")),
    cmd("test", test_cmd),
    cmdAs("[", test_cmd.mainBracket, test_cmd.help),
    cmd("timeout", @import("cmd/timeout.zig")),
    cmd("touch", @import("cmd/touch.zig")),
    cmd("tr", @import("cmd/tr.zig")),
    cmd("tree", @import("cmd/tree.zig")),
    cmd("true", truefalse),
    cmd("truncate", @import("cmd/truncate.zig")),
    cmd("tty", @import("cmd/tty.zig")),
    cmd("uname", @import("cmd/uname.zig")),
    cmd("uniq", @import("cmd/uniq.zig")),
    cmd("unlink", @import("cmd/unlink.zig")),
    cmd("uptime", @import("cmd/uptime.zig")),
    cmdAs("users", who.mainUsers, who.help_users),
    cmd("wc", @import("cmd/wc.zig")),
    cmd("which", @import("cmd/which.zig")),
    cmd("who", who),
    cmd("whoami", @import("cmd/whoami.zig")),
    cmd("xargs", @import("cmd/xargs.zig")),
    cmd("xxd", @import("cmd/xxd.zig")),
    cmd("yes", @import("cmd/yes.zig")),
};

fn find(name: []const u8) ?*const Cmd {
    for (&commands) |*e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

const zbox_help =
    \\Usage: zbox [COMMAND [ARGS]...]
    \\   or: COMMAND [ARGS]...   (via a symlink named COMMAND pointing to zbox)
    \\
    \\zbox is a multi-call binary providing GNU compatible core utilities.
    \\
    \\  --list            list available commands
    \\  --install DIR     create symlinks DIR/COMMAND -> zbox for every command
    \\  --help            display this help and exit
    \\
    \\Run 'zbox COMMAND --help' for help on a specific command.
    \\
;

fn run(e: *const Cmd, args: c.Args) noreturn {
    c.prog = e.name;
    c.help_text = e.help;
    const rc = e.run(args) catch |err| handleError(err);
    c.exit(rc);
}

fn handleError(err: anyerror) noreturn {
    switch (err) {
        error.WriteFailed => c.writeFailed(),
        error.OutOfMemory, error.NOMEM => c.fatal("memory exhausted", .{}),
        else => c.fatal("{s}", .{c.strerror(err)}),
    }
}

fn selfPath(buf: []u8) []const u8 {
    if (c.sys.readlink("/proc/self/exe", buf)) |p| return p else |_| {}
    return "zbox";
}

fn install(dir: []const u8) u8 {
    var pbuf: [c.PATH_MAX]u8 = undefined;
    var target: []const u8 = selfPath(&pbuf);
    if (target.len == 0 or target[0] != '/') {
        // Fall back to argv[0] resolved against cwd.
        const a0 = std.mem.span(std.os.argv[0]);
        target = a0;
    }
    var status: u8 = 0;
    for (commands) |e| {
        const link = c.join(dir, e.name);
        c.sys.unlink(link) catch {};
        c.sys.symlink(target, link) catch |err| {
            c.warn("cannot create symlink {f}: {s}", .{ c.q(link), c.strerror(err) });
            status = 1;
        };
    }
    return status;
}

pub fn main() u8 {
    c.initIo();
    const raw = std.os.argv;
    const args = c.gpa.alloc([:0]const u8, raw.len) catch return 1;
    for (raw, 0..) |a, i| args[i] = std.mem.span(a);
    if (args.len == 0) return 1;
    const base = c.basename(args[0]);
    if (find(base)) |e| run(e, args);

    // Invoked as zbox (or under an unknown name).
    c.prog = "zbox";
    c.help_text = zbox_help;
    if (args.len < 2) {
        c.out.writeAll(zbox_help) catch {};
        c.exit(1);
    }
    const sub = args[1];
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) c.printHelp();
    if (std.mem.eql(u8, sub, "--version")) c.printVersion();
    if (std.mem.eql(u8, sub, "--list") or std.mem.eql(u8, sub, "-l")) {
        for (commands) |e| c.out.print("{s}\n", .{e.name}) catch {};
        c.exit(0);
    }
    if (std.mem.eql(u8, sub, "--install")) {
        if (args.len < 3) c.usageErr("--install requires a directory", .{});
        c.exit(install(args[2]));
    }
    if (find(c.basename(sub))) |e| run(e, args[1..]);
    c.warn("applet not found: {s}", .{sub});
    c.exit(127);
}
