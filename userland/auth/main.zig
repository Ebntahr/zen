//! zauth — account and privilege tools (multi-call binary).
//!
//!   login [user]                   text console login
//!   su [-] [user] [-c cmd]         switch user
//!   sudo [-u user] [-i|-s] cmd…    run a command as another user
//!   passwd [user]                  change a password
//!   useradd [-m] [-c name] [-G admin] [-s shell] [-p pw] user
//!   userdel [-r] user
//!
//! Installed setuid-root at /usr/bin/zauth with symlinks for each tool.

const std = @import("std");
const zen = @import("zen");
const users = zen.users;
const posix = std.posix;
const linux = std.os.linux;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

var stderr_buf: [1024]u8 = undefined;
var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
const err_out = &stderr_w.interface;
var stdout_buf: [1024]u8 = undefined;
var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
const out = &stdout_w.interface;

var prog: []const u8 = "zauth";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    err_out.print("{s}: " ++ fmt ++ "\n", .{prog} ++ args) catch {};
    err_out.flush() catch {};
    std.process.exit(1);
}

/// Open the controlling terminal for password prompts.
fn openTty() !std.fs.File {
    return std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write }) catch std.fs.File.stdin();
}

/// Prompt without echo; returns the typed line (caller frees).
fn readPassword(prompt: []const u8) ![]u8 {
    const tty = try openTty();
    _ = tty.write(prompt) catch {};
    const saved = posix.tcgetattr(tty.handle) catch null;
    if (saved) |t| {
        var raw = t;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = true;
        posix.tcsetattr(tty.handle, .FLUSH, raw) catch {};
    }
    defer if (saved) |t| posix.tcsetattr(tty.handle, .FLUSH, t) catch {};
    var line: std.ArrayList(u8) = .empty;
    var c: [1]u8 = undefined;
    while (true) {
        const n = tty.read(&c) catch 0;
        if (n == 0 or c[0] == '\n' or c[0] == '\r') break;
        try line.append(gpa, c[0]);
    }
    if (saved == null) _ = tty.write("\n") catch {};
    return line.toOwnedSlice(gpa);
}

fn readLine(prompt: []const u8) ![]u8 {
    const tty = try openTty();
    _ = tty.write(prompt) catch {};
    var line: std.ArrayList(u8) = .empty;
    var c: [1]u8 = undefined;
    while (true) {
        const n = tty.read(&c) catch 0;
        if (n == 0) {
            if (line.items.len == 0) return error.EndOfStream;
            break;
        }
        if (c[0] == '\n' or c[0] == '\r') break;
        try line.append(gpa, c[0]);
    }
    return line.toOwnedSlice(gpa);
}

fn chown(path: []const u8, uid: u32, gid: u32) void {
    const z = gpa.dupeZ(u8, path) catch return;
    _ = linux.syscall5(.fchownat, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z.ptr), uid, gid, 0);
}

fn setgroups(list: []const u32) void {
    _ = linux.syscall2(.setgroups, list.len, @intFromPtr(list.ptr));
}

/// Irrevocably become `user` (groups, gid, uid).
fn becomeUser(db: *const users.Db, user: users.User) void {
    const gs = db.groupsOf(gpa, user) catch fail("out of memory", .{});
    setgroups(gs);
    posix.setgid(user.gid) catch fail("cannot set group id", .{});
    posix.setuid(user.uid) catch fail("cannot set user id", .{});
}

fn loadDb() users.Db {
    return users.Db.load(gpa, "/") catch |e| fail("cannot read user database: {s}", .{@errorName(e)});
}

fn currentUser(db: *const users.Db) users.User {
    const uid = linux.getuid();
    return db.userById(uid) orelse fail("unknown user id {d}", .{uid});
}

fn buildEnv(user: users.User, keep: bool) ![]const [*:0]const u8 {
    var env: std.ArrayList([*:0]const u8) = .empty;
    const vars = [_]struct { []const u8, []const u8 }{
        .{ "HOME", user.home },
        .{ "USER", user.name },
        .{ "LOGNAME", user.name },
        .{ "SHELL", user.shell },
    };
    for (vars) |v| try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "{s}={s}", .{ v[0], v[1] }, 0));
    const path = if (user.uid == 0) "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" else "/usr/local/bin:/usr/bin:/bin";
    try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "PATH={s}", .{path}, 0));
    if (keep) {
        var it = (try std.process.getEnvMap(gpa)).iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, "HOME") or std.mem.eql(u8, k, "USER") or std.mem.eql(u8, k, "LOGNAME") or std.mem.eql(u8, k, "SHELL") or std.mem.eql(u8, k, "PATH")) continue;
            if (std.mem.startsWith(u8, k, "LD_")) continue;
            try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "{s}={s}", .{ k, e.value_ptr.* }, 0));
        }
    } else {
        if (posix.getenv("TERM")) |t| try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "TERM={s}", .{t}, 0));
    }
    return env.toOwnedSlice(gpa);
}

fn execv(path: []const u8, argv: []const []const u8, env: []const [*:0]const u8) noreturn {
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    for (argv) |a| args.append(gpa, (gpa.dupeZ(u8, a) catch fail("oom", .{})).ptr) catch fail("oom", .{});
    args.append(gpa, null) catch fail("oom", .{});
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    for (env) |e| envp.append(gpa, e) catch fail("oom", .{});
    envp.append(gpa, null) catch fail("oom", .{});
    const envz: [*:null]const ?[*:0]const u8 = @ptrCast(envp.items.ptr);
    const argz: [*:null]const ?[*:0]const u8 = @ptrCast(args.items.ptr);

    if (std.mem.indexOfScalar(u8, path, '/') != null) {
        const pz = gpa.dupeZ(u8, path) catch fail("oom", .{});
        const e = posix.execveZ(pz, argz, envz);
        fail("{s}: {s}", .{ path, @errorName(e) });
    }
    const e = posix.execvpeZ(argz[0].?, argz, envz);
    fail("{s}: {s}", .{ path, @errorName(e) });
}

fn loginShell(user: users.User) noreturn {
    std.posix.chdir(user.home) catch std.posix.chdir("/") catch {};
    const env = buildEnv(user, false) catch fail("oom", .{});
    const base = std.fs.path.basename(user.shell);
    const argv0 = std.fmt.allocPrint(gpa, "-{s}", .{base}) catch fail("oom", .{});
    execv(user.shell, &.{argv0}, env);
}

// ---------------------------------------------------------------------------

fn cmdLogin(args: []const []const u8) !void {
    var tries: usize = 0;
    var hostname_buf: [64]u8 = undefined;
    const host = std.fs.cwd().readFile("/etc/hostname", &hostname_buf) catch "zen";
    while (tries < 5) : (tries += 1) {
        const name = if (args.len > 0 and tries == 0) try gpa.dupe(u8, args[0]) else blk: {
            const p = try std.fmt.allocPrint(gpa, "{s} login: ", .{std.mem.trim(u8, host, " \n")});
            break :blk readLine(p) catch std.process.exit(1);
        };
        const pw = try readPassword("Password: ");
        var db = loadDb();
        if (db.userByName(name)) |u| {
            if (db.checkPassword(name, pw) catch false) {
                zen.sys.logf("login: {s} logged in", .{name});
                if (std.fs.cwd().readFileAlloc(gpa, "/etc/motd", 16 * 1024)) |motd| {
                    try out.writeAll(motd);
                    try out.flush();
                } else |_| {}
                becomeUser(&db, u);
                loginShell(u);
            }
        }
        std.Thread.sleep(1 * std.time.ns_per_s);
        try out.writeAll("Login incorrect\n\n");
        try out.flush();
        zen.sys.logf("login: failed login for {s}", .{name});
    }
    std.process.exit(1);
}

fn cmdSu(args: []const []const u8) !void {
    var login = false;
    var target: []const u8 = "root";
    var command: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-") or std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--login")) {
            login = true;
        } else if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= args.len) fail("option requires an argument -- 'c'", .{});
            command = args[i];
        } else {
            target = a;
        }
    }
    var db = loadDb();
    const me = currentUser(&db);
    const u = db.userByName(target) orelse fail("user {s} does not exist", .{target});
    if (me.uid != 0) {
        const pw = try readPassword("Password: ");
        if (!(db.checkPassword(target, pw) catch false)) {
            zen.sys.logf("su: FAILED {s} -> {s}", .{ me.name, target });
            std.Thread.sleep(2 * std.time.ns_per_s);
            fail("Authentication failure", .{});
        }
    }
    zen.sys.logf("su: {s} -> {s}", .{ me.name, target });
    becomeUser(&db, u);
    if (login) loginShell(u);
    const env = try buildEnv(u, true);
    if (command) |c| execv(u.shell, &.{ u.shell, "-c", c }, env);
    execv(u.shell, &.{u.shell}, env);
}

/// Successful sudo authentications are remembered for five minutes.
fn sudoTimestampValid(uid: u32) bool {
    const path = std.fmt.allocPrint(gpa, "/var/run/sudo/{d}", .{uid}) catch return false;
    const st = std.fs.cwd().statFile(path) catch return false;
    const now = std.time.nanoTimestamp();
    return now - st.mtime < 5 * 60 * std.time.ns_per_s;
}

fn sudoTouch(uid: u32) void {
    std.fs.cwd().makePath("/var/run/sudo") catch return;
    const path = std.fmt.allocPrint(gpa, "/var/run/sudo/{d}", .{uid}) catch return;
    const f = std.fs.cwd().createFile(path, .{ .mode = 0o600 }) catch return;
    f.close();
}

fn cmdSudo(args: []const []const u8) !void {
    var target: []const u8 = "root";
    var i: usize = 0;
    var shell = false;
    var login = false;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-u")) {
            i += 1;
            if (i >= args.len) fail("option requires an argument -- 'u'", .{});
            target = args[i];
        } else if (std.mem.eql(u8, a, "-s")) {
            shell = true;
        } else if (std.mem.eql(u8, a, "-i")) {
            login = true;
        } else if (std.mem.eql(u8, a, "-k")) {
            const path = try std.fmt.allocPrint(gpa, "/var/run/sudo/{d}", .{linux.getuid()});
            std.fs.cwd().deleteFile(path) catch {};
            return;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else {
            fail("unknown option {s}", .{a});
        }
    }
    const cmd = args[i..];
    if (cmd.len == 0 and !shell and !login) fail("usage: sudo [-u user] [-i|-s] command", .{});
    if (linux.geteuid() != 0) fail("must be setuid root", .{});

    var db = loadDb();
    const me = currentUser(&db);
    if (me.uid != 0) {
        if (!db.isAdmin(me)) {
            zen.sys.logf("sudo: {s} is not in the sudoers (admin) group", .{me.name});
            fail("{s} is not in the admin group. This incident will be reported.", .{me.name});
        }
        if (!sudoTimestampValid(me.uid)) {
            var ok = false;
            var attempt: usize = 0;
            while (attempt < 3 and !ok) : (attempt += 1) {
                const prompt = try std.fmt.allocPrint(gpa, "[sudo] password for {s}: ", .{me.name});
                const pw = try readPassword(prompt);
                ok = db.checkPassword(me.name, pw) catch false;
                if (!ok) {
                    try err_out.writeAll("Sorry, try again.\n");
                    try err_out.flush();
                }
            }
            if (!ok) {
                zen.sys.logf("sudo: {s}: 3 incorrect password attempts", .{me.name});
                fail("3 incorrect password attempts", .{});
            }
        }
        sudoTouch(me.uid);
    }
    const u = db.userByName(target) orelse fail("unknown user {s}", .{target});
    const joined = try std.mem.join(gpa, " ", cmd);
    zen.sys.logf("sudo: {s} : USER={s} ; COMMAND={s}", .{ me.name, target, joined });
    becomeUser(&db, u);
    if (login) loginShell(u);
    var env = std.ArrayList([*:0]const u8).fromOwnedSlice(@constCast(try buildEnv(u, true)));
    try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "SUDO_USER={s}", .{me.name}, 0));
    try env.append(gpa, try std.fmt.allocPrintSentinel(gpa, "SUDO_UID={d}", .{me.uid}, 0));
    if (cmd.len == 0) execv(u.shell, &.{u.shell}, env.items);
    execv(cmd[0], cmd, env.items);
}

fn cmdPasswd(args: []const []const u8) !void {
    var db = loadDb();
    const me = currentUser(&db);
    const target = if (args.len > 0) args[0] else me.name;
    if (db.userByName(target) == null) fail("user '{s}' does not exist", .{target});
    if (me.uid != 0 and !std.mem.eql(u8, target, me.name)) fail("You may not view or modify password information for {s}.", .{target});
    try out.print("Changing password for {s}.\n", .{target});
    try out.flush();
    if (me.uid != 0) {
        const cur = try readPassword("Current password: ");
        if (!(db.checkPassword(target, cur) catch false)) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            fail("Authentication token manipulation error", .{});
        }
    }
    const a = try readPassword("New password: ");
    const b = try readPassword("Retype new password: ");
    if (!std.mem.eql(u8, a, b)) fail("Sorry, passwords do not match.", .{});
    if (a.len < 4) fail("The password is too short (minimum 4 characters).", .{});
    try db.setPassword(target, a);
    zen.sys.logf("passwd: password changed for {s}", .{target});
    try out.writeAll("passwd: password updated successfully\n");
    try out.flush();
}

fn copyTree(src: []const u8, dst: []const u8, uid: u32, gid: u32) void {
    var sdir = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer sdir.close();
    std.fs.cwd().makePath(dst) catch return;
    chown(dst, uid, gid);
    var it = sdir.iterate();
    while (it.next() catch null) |e| {
        const s = std.fs.path.join(gpa, &.{ src, e.name }) catch return;
        const d = std.fs.path.join(gpa, &.{ dst, e.name }) catch return;
        switch (e.kind) {
            .directory => copyTree(s, d, uid, gid),
            .file => {
                std.fs.cwd().copyFile(s, std.fs.cwd(), d, .{}) catch continue;
                chown(d, uid, gid);
            },
            else => {},
        }
    }
}

fn cmdUseradd(args: []const []const u8) !void {
    if (linux.geteuid() != 0) fail("Permission denied (run with sudo)", .{});
    var make_home = false;
    var full: []const u8 = "";
    var admin = false;
    var shell_path: []const u8 = "/bin/zensh";
    var password: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-m")) {
            make_home = true;
        } else if (std.mem.eql(u8, a, "-c") and i + 1 < args.len) {
            i += 1;
            full = args[i];
        } else if (std.mem.eql(u8, a, "-G") and i + 1 < args.len) {
            i += 1;
            admin = std.mem.indexOf(u8, args[i], "admin") != null or std.mem.indexOf(u8, args[i], "wheel") != null;
        } else if (std.mem.eql(u8, a, "-s") and i + 1 < args.len) {
            i += 1;
            shell_path = args[i];
        } else if (std.mem.eql(u8, a, "-p") and i + 1 < args.len) {
            i += 1;
            password = args[i];
        } else {
            name = a;
        }
    }
    const n = name orelse fail("usage: useradd [-m] [-c full name] [-G admin] [-s shell] [-p password] name", .{});
    const pw = password orelse try readPassword("New password: ");
    var db = loadDb();
    const uid = db.addUser(.{ .name = n, .full_name = if (full.len > 0) full else n, .password = pw, .admin = admin, .shell = shell_path }) catch |e| switch (e) {
        error.AlreadyExists => fail("user '{s}' already exists", .{n}),
        error.InvalidEntry => fail("invalid user name '{s}'", .{n}),
        else => return e,
    };
    if (make_home) {
        const home = try std.fmt.allocPrint(gpa, "/Users/{s}", .{n});
        copyTree("/etc/skel", home, uid, uid);
        for ([_][]const u8{ "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library", "Library/Containers", "Library/Preferences" }) |sub| {
            const p = try std.fs.path.join(gpa, &.{ home, sub });
            std.fs.cwd().makePath(p) catch {};
            chown(p, uid, uid);
        }
        chown(home, uid, uid);
    }
    zen.sys.logf("useradd: new user {s} uid={d}{s}", .{ n, uid, if (admin) " (admin)" else "" });
}

fn removeLines(path: []const u8, name: []const u8) !void {
    const data = try std.fs.cwd().readFileAlloc(gpa, path, 4 << 20);
    var buf: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse l.len;
        if (std.mem.eql(u8, l[0..colon], name)) continue;
        try buf.appendSlice(gpa, l);
        try buf.append(gpa, '\n');
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
}

fn cmdUserdel(args: []const []const u8) !void {
    if (linux.geteuid() != 0) fail("Permission denied (run with sudo)", .{});
    var remove_home = false;
    var name: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-r")) remove_home = true else name = a;
    }
    const n = name orelse fail("usage: userdel [-r] name", .{});
    var db = loadDb();
    const u = db.userByName(n) orelse fail("user '{s}' does not exist", .{n});
    if (u.uid == 0) fail("refusing to delete root", .{});
    try removeLines("/etc/passwd", n);
    try removeLines("/etc/shadow", n);
    try removeLines("/etc/group", n);
    if (remove_home) std.fs.cwd().deleteTree(u.home) catch {};
    zen.sys.logf("userdel: removed {s}", .{n});
}

pub fn main() !void {
    const argv = try std.process.argsAlloc(gpa);
    var name = std.fs.path.basename(argv[0]);
    if (name.len > 0 and name[0] == '-') name = name[1..];
    var args: []const []const u8 = argv[1..];
    if (std.mem.eql(u8, name, "zauth")) {
        if (args.len == 0) fail("usage: zauth <login|su|sudo|passwd|useradd|userdel> ...", .{});
        name = args[0];
        args = args[1..];
    }
    prog = name;
    const tools = .{
        .{ "login", cmdLogin },
        .{ "su", cmdSu },
        .{ "sudo", cmdSudo },
        .{ "passwd", cmdPasswd },
        .{ "useradd", cmdUseradd },
        .{ "userdel", cmdUserdel },
    };
    inline for (tools) |t| {
        if (std.mem.eql(u8, name, t[0])) {
            t[1](args) catch |e| fail("{s}", .{@errorName(e)});
            out.flush() catch {};
            return;
        }
    }
    fail("unknown tool", .{});
}
