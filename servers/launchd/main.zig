//! launchd — application launcher and session manager (`launch:` scheme).
//!
//! Only launchd starts GUI applications. For every launch it
//!   1. loads the bundle (Info.conf, Entitlements.conf),
//!   2. verifies the code signature against the trusted platform keys
//!      (Gatekeeper); unsigned apps need the user's explicit approval
//!      recorded in /etc/zen/gatekeeper.allow,
//!   3. creates the app's data container in the user's Library,
//!   4. converts entitlements into a kernel sandbox profile,
//!   5. spawns the executable as the session user inside the sandbox.
//!
//! Protocol (write a text command, then read the reply line):
//!   launch:apps        read → one line per installed app: id\tname\tpath\ticon\tcategory
//!   launch:running     read → one line per running app: pid\tid\tname
//!   launch:ctl         write "open <bundle-id|path> [args…]" → reply "ok <pid>" / "error <msg>"
//!                      write "session-begin <uid>" (root only)
//!                      write "session-end" (root only)
//!                      write "quit <bundle-id>"
//!                      write "verify <path>" → "ok signed <identity>" / "error …"

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");

const sc = abi.scheme;
const posix = std.posix;
const Ed25519 = std.crypto.sign.Ed25519;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

const app_dirs = [_][]const u8{ "/Applications", "/System/Applications", "/System/Applications/Utilities" };
const trust_file = "/System/Library/Security/platform.pub";
const allow_file = "/etc/zen/gatekeeper.allow";

const App = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    icon: []const u8,
    category: []const u8,
};

const Running = struct {
    pid: u32,
    id: []const u8,
    name: []const u8,
};

const Session = struct {
    uid: u32,
    gid: u32,
    name: []const u8,
    home: []const u8,
    shell: []const u8,
    groups: []u32,
};

var apps: std.ArrayList(App) = .empty;
var running: std.ArrayList(Running) = .empty;
var session: ?Session = null;
var trusted: std.ArrayList(Ed25519.PublicKey) = .empty;

const Kind = enum { apps, running, ctl };
const Handle = struct {
    kind: Kind,
    /// Reply text waiting to be read.
    reply: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
};

var handles: zen.server.HandleTable(Handle) = .{};
var srv: zen.server.Server = undefined;

fn loadTrust() void {
    const text = std.fs.cwd().readFileAlloc(gpa, trust_file, 64 * 1024) catch {
        zen.sys.logf("launchd: no platform key at {s}; only approved apps will launch", .{trust_file});
        return;
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        if (t.len == 0 or t[0] == '#') continue;
        const pk = zen.codesign.parsePublicKey(t) catch continue;
        trusted.append(gpa, pk) catch {};
    }
}

fn scanApps() void {
    apps.clearRetainingCapacity();
    for (app_dirs) |dir_path| {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory or !std.mem.endsWith(u8, e.name, ".app")) continue;
            const path = std.fs.path.join(gpa, &.{ dir_path, e.name }) catch continue;
            var b = zen.bundle.load(gpa, path) catch continue;
            defer b.deinit();
            apps.append(gpa, .{
                .id = gpa.dupe(u8, b.info.id) catch continue,
                .name = gpa.dupe(u8, b.info.name) catch continue,
                .path = path,
                .icon = gpa.dupe(u8, b.info.icon) catch "",
                .category = gpa.dupe(u8, b.info.category) catch "",
            }) catch {};
        }
    }
}

fn findApp(key: []const u8) ?App {
    for (apps.items) |a| {
        if (std.mem.eql(u8, a.id, key) or std.mem.eql(u8, a.path, key) or std.ascii.eqlIgnoreCase(a.name, key)) return a;
    }
    return null;
}

fn approvedUnsigned(path: []const u8) bool {
    const text = std.fs.cwd().readFileAlloc(gpa, allow_file, 64 * 1024) catch return false;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \r"), path)) return true;
    return false;
}

/// Gatekeeper check. Returns an error message or null when allowed.
fn gatekeeper(path: []const u8, reply: *std.ArrayList(u8)) !bool {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        try reply.print(gpa, "error cannot open {s}\n", .{path});
        return false;
    };
    defer dir.close();
    if (zen.codesign.verify(gpa, dir, trusted.items)) |v| {
        gpa.free(v.identity);
        return true;
    } else |err| {
        if (approvedUnsigned(path)) return true;
        const why = switch (err) {
            error.Unsigned => "is not signed",
            error.Tampered => "has been modified or damaged",
            error.UntrustedSigner => "is signed by an unknown developer",
            else => "has an invalid signature",
        };
        zen.sys.logf("gatekeeper: blocked {s}: {s}", .{ path, why });
        try reply.print(gpa, "error gatekeeper \"{s}\" {s}\n", .{ std.fs.path.basename(path), why });
        return false;
    }
}

fn ensureDir(path: []const u8, uid: u32, gid: u32) void {
    std.fs.cwd().makePath(path) catch return;
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    const linux = std.os.linux;
    _ = linux.syscall5(.fchownat, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z.ptr), uid, gid, 0);
}

fn launch(key: []const u8, extra_args: []const []const u8, reply: *std.ArrayList(u8)) !void {
    const s = session orelse {
        try reply.appendSlice(gpa, "error no user session\n");
        return;
    };
    const app = findApp(key) orelse blk: {
        // Allow launching bundles by path that are not in the app folders.
        if (std.mem.endsWith(u8, std.mem.trimRight(u8, key, "/"), ".app")) {
            break :blk App{ .id = key, .name = std.fs.path.basename(key), .path = key, .icon = "", .category = "" };
        }
        try reply.print(gpa, "error no application named {s}\n", .{key});
        return;
    };
    // Single instance: activate instead of launching twice.
    for (running.items) |r| {
        if (std.mem.eql(u8, r.id, app.id)) {
            try reply.print(gpa, "ok {d} running\n", .{r.pid});
            return;
        }
    }
    if (!try gatekeeper(app.path, reply)) return;

    var b = try zen.bundle.load(gpa, app.path);
    defer b.deinit();
    const exe = try b.executablePath(gpa);
    defer gpa.free(exe);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var home = s.home;
    var profile: ?[]u8 = null;
    if (b.sandboxed()) {
        const container = try b.containerPath(arena, s.home);
        for ([_][]const u8{ "", "Documents", "Library", "Library/Preferences", "Library/Caches", "tmp" }) |sub| {
            ensureDir(try std.fs.path.join(arena, &.{ container, sub }), s.uid, s.gid);
        }
        profile = try b.sandboxProfile(arena, s.home);
        home = container;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, extra_args);

    var env: std.ArrayList([]const u8) = .empty;
    try env.append(arena, try std.fmt.allocPrint(arena, "HOME={s}", .{home}));
    try env.append(arena, try std.fmt.allocPrint(arena, "USER={s}", .{s.name}));
    try env.append(arena, try std.fmt.allocPrint(arena, "LOGNAME={s}", .{s.name}));
    try env.append(arena, try std.fmt.allocPrint(arena, "SHELL={s}", .{s.shell}));
    try env.append(arena, try std.fmt.allocPrint(arena, "TMPDIR={s}/tmp", .{home}));
    try env.append(arena, try std.fmt.allocPrint(arena, "ZEN_BUNDLE_ID={s}", .{b.info.id}));
    try env.append(arena, try std.fmt.allocPrint(arena, "ZEN_BUNDLE_PATH={s}", .{app.path}));
    try env.append(arena, try std.fmt.allocPrint(arena, "ZEN_USER_HOME={s}", .{s.home}));
    try env.append(arena, "PATH=/usr/local/bin:/usr/bin:/bin");
    try env.append(arena, "TERM=xterm-256color");
    try env.append(arena, "LANG=en_US.UTF-8");

    const devnull = zen.io.open("null:", .{ .ACCMODE = .RDWR }, 0) catch -1;
    defer if (devnull >= 0) zen.io.close(devnull);
    const pid = zen.sys.spawn(gpa, exe, .{
        .argv = argv.items,
        .env = env.items,
        .fds = &.{ devnull, devnull, devnull },
        .cwd = home,
        .uid = s.uid,
        .gid = s.gid,
        .groups = s.groups,
        .sandbox = profile,
        .new_session = true,
    }) catch |err| {
        try reply.print(gpa, "error spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    try running.append(gpa, .{ .pid = pid, .id = try gpa.dupe(u8, b.info.id), .name = try gpa.dupe(u8, b.info.name) });
    zen.sys.logf("launchd: launched {s} pid {d}{s}", .{ b.info.id, pid, if (profile != null) " (sandboxed)" else "" });
    notifyWindowServer("app-launched", pid, b.info.id);
    try reply.print(gpa, "ok {d}\n", .{pid});
}

// Notifications to the window server are sent from a separate thread: the
// window server may itself be waiting on launchd (Dock → "open …"), and a
// synchronous call back into it from here would deadlock.
const Notifier = struct {
    var mutex: std.Thread.Mutex = .{};
    var cond: std.Thread.Condition = .{};
    var queue: std.ArrayList([]u8) = .empty;
    var started = false;

    fn post(msg: []const u8) void {
        mutex.lock();
        defer mutex.unlock();
        if (!started) {
            started = true;
            const t = std.Thread.spawn(.{}, run, .{}) catch {
                started = false;
                return;
            };
            t.detach();
        }
        const copy = gpa.dupe(u8, msg) catch return;
        queue.append(gpa, copy) catch return gpa.free(copy);
        cond.signal();
    }

    fn run() void {
        while (true) {
            mutex.lock();
            while (queue.items.len == 0) cond.wait(&mutex);
            const msg = queue.orderedRemove(0);
            mutex.unlock();
            defer gpa.free(msg);
            const fd = zen.io.open("window:control", .{ .ACCMODE = .WRONLY }, 0) catch continue;
            defer zen.io.close(fd);
            _ = zen.io.write(fd, msg) catch {};
        }
    }
};

fn notifyWindowServer(what: []const u8, pid: u32, id: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} {d} {s}", .{ what, pid, id }) catch return;
    Notifier.post(msg);
}

fn reapChildren() void {
    while (true) {
        const r = zen.sys.reap(-1, false) orelse break;
        const pid = r.pid;
        for (running.items, 0..) |app, i| {
            if (app.pid == pid) {
                zen.sys.logf("launchd: {s} (pid {d}) exited", .{ app.id, pid });
                notifyWindowServer("app-exited", pid, app.id);
                _ = running.swapRemove(i);
                break;
            }
        }
    }
}

fn beginSession(uid: u32, reply: *std.ArrayList(u8)) !void {
    var db = try zen.users.Db.load(gpa, "/");
    defer db.deinit();
    const u = db.userById(uid) orelse {
        try reply.appendSlice(gpa, "error unknown user\n");
        return;
    };
    session = .{
        .uid = u.uid,
        .gid = u.gid,
        .name = try gpa.dupe(u8, u.name),
        .home = try gpa.dupe(u8, u.home),
        .shell = try gpa.dupe(u8, u.shell),
        .groups = try db.groupsOf(gpa, u),
    };
    scanApps();
    zen.sys.logf("launchd: session started for {s}", .{u.name});
    try reply.appendSlice(gpa, "ok\n");
}

fn endSession(reply: *std.ArrayList(u8)) !void {
    for (running.items) |app| posix.kill(@intCast(app.pid), posix.SIG.TERM) catch {};
    // Give apps a moment to save, then force quit.
    std.Thread.sleep(500 * std.time.ns_per_ms);
    for (running.items) |app| posix.kill(@intCast(app.pid), posix.SIG.KILL) catch {};
    reapChildren();
    running.clearRetainingCapacity();
    session = null;
    try reply.appendSlice(gpa, "ok\n");
}

fn command(req: sc.Request, line_raw: []const u8, reply: *std.ArrayList(u8)) !void {
    const line = std.mem.trim(u8, line_raw, " \r\n");
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |w| try words.append(gpa, w);
    if (words.items.len == 0) return;
    const cmd = words.items[0];
    if (std.mem.eql(u8, cmd, "open")) {
        if (words.items.len < 2) return reply.appendSlice(gpa, "error usage: open <app>\n");
        if (session) |s| if (req.uid != 0 and req.uid != s.uid) return reply.appendSlice(gpa, "error permission denied\n");
        return launch(words.items[1], words.items[2..], reply);
    }
    if (std.mem.eql(u8, cmd, "session-begin")) {
        if (req.uid != 0) return reply.appendSlice(gpa, "error permission denied\n");
        const uid = std.fmt.parseInt(u32, if (words.items.len > 1) words.items[1] else "", 10) catch return reply.appendSlice(gpa, "error bad uid\n");
        return beginSession(uid, reply);
    }
    if (std.mem.eql(u8, cmd, "session-end")) {
        if (req.uid != 0) return reply.appendSlice(gpa, "error permission denied\n");
        return endSession(reply);
    }
    if (std.mem.eql(u8, cmd, "quit")) {
        for (running.items) |app| {
            if (words.items.len > 1 and std.mem.eql(u8, app.id, words.items[1])) posix.kill(@intCast(app.pid), posix.SIG.TERM) catch {};
        }
        return reply.appendSlice(gpa, "ok\n");
    }
    if (std.mem.eql(u8, cmd, "rescan")) {
        scanApps();
        return reply.appendSlice(gpa, "ok\n");
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        if (words.items.len < 2) return reply.appendSlice(gpa, "error usage: verify <path>\n");
        var dir = std.fs.cwd().openDir(words.items[1], .{ .iterate = true }) catch return reply.appendSlice(gpa, "error cannot open\n");
        defer dir.close();
        const v = zen.codesign.verify(gpa, dir, trusted.items) catch |err| return reply.print(gpa, "error {s}\n", .{@errorName(err)});
        defer gpa.free(v.identity);
        return reply.print(gpa, "ok signed {s}\n", .{v.identity});
    }
    try reply.print(gpa, "error unknown command {s}\n", .{cmd});
}

fn fillListing(h: *Handle) !void {
    h.reply.clearRetainingCapacity();
    h.read_pos = 0;
    switch (h.kind) {
        .apps => for (apps.items) |a| try h.reply.print(gpa, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ a.id, a.name, a.path, a.icon, a.category }),
        .running => for (running.items) |r| try h.reply.print(gpa, "{d}\t{s}\t{s}\n", .{ r.pid, r.id, r.name }),
        .ctl => {},
    }
}

fn serve(in: zen.server.Incoming) !void {
    const req = in.req;
    switch (req.op) {
        .open => {
            const path = std.mem.trim(u8, in.payload, "/");
            const kind: Kind = if (std.mem.eql(u8, path, "apps")) .apps else if (std.mem.eql(u8, path, "running")) .running else if (path.len == 0 or std.mem.eql(u8, path, "ctl")) .ctl else return srv.replyError(req.id, .NOENT);
            const id = try handles.insert(gpa, .{ .kind = kind });
            const h = handles.get(id).?;
            try fillListing(h);
            return srv.replyValue(req.id, id);
        },
        .cancel => return,
        else => {},
    }
    const h = handles.get(req.handle) orelse return srv.replyError(req.id, .BADF);
    switch (req.op) {
        .close => {
            h.reply.deinit(gpa);
            _ = handles.remove(gpa, req.handle);
        },
        .read => {
            const rest = h.reply.items[h.read_pos..];
            const n: usize = @intCast(@min(rest.len, req.len));
            h.read_pos += n;
            try srv.reply(req.id, @intCast(n), rest[0..n]);
        },
        .write => {
            if (h.kind != .ctl) return srv.replyError(req.id, .BADF);
            h.reply.clearRetainingCapacity();
            h.read_pos = 0;
            reapChildren();
            try command(req, in.payload, &h.reply);
            try srv.replyValue(req.id, in.payload.len);
        },
        .fstat => {
            const st = sc.Stat{ .mode = sc.S_IFCHR | 0o666, .size = @intCast(h.reply.items.len) };
            try srv.replyStruct(req.id, &st);
        },
        .seek => {
            if (req.arg0 == 0 and req.arg1 == 0) {
                reapChildren();
                try fillListing(h);
            }
            try srv.replyValue(req.id, 0);
        },
        .fevent => try srv.replyValue(req.id, sc.POLLIN | sc.POLLOUT),
        else => try srv.replyError(req.id, .NOSYS),
    }
}

pub fn main() !void {
    zen.sys.setName("launchd");
    loadTrust();
    scanApps();
    srv = try zen.server.Server.register(gpa, "launch");
    zen.sys.logf("launchd: {d} apps, {d} trusted keys", .{ apps.items.len, trusted.items.len });
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, 1000) catch 0;
        reapChildren();
        if (fds[0].revents == 0) continue;
        const in = srv.receive() catch continue;
        serve(in) catch |err| srv.replyError(in.req.id, zen.server.errnoFor(err)) catch {};
    }
}
