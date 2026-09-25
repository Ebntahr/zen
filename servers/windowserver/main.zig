//! windowserver — compositing window server of the Zen desktop.
//!
//! Serves `window:` for apps, reads `input:`, draws into `display:0` and
//! drives the hardware cursor on `display:0/cursor`.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const gfx = @import("gfx");
const ui = @import("ui");
const wm = @import("wm.zig");
const st = @import("state.zig");
const protocol = @import("protocol.zig");
const input_mod = @import("input.zig");
const comp_mod = @import("compositor.zig");
const chrome = @import("chrome.zig");
const cursor = @import("cursor.zig");

const posix = std.posix;
const zio = zen.io;
const disp = abi.display;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

var display_fd: posix.fd_t = -1;
var cursor_fd: posix.fd_t = -1;
var cursor_img: []u32 = &.{};
var cursor_shape: abi.window.Cursor = .hidden;
var cursor_hot: cursor.Hotspot = .{ .x = 0, .y = 0 };

var state: st.State = undefined;
var comp: comp_mod.Compositor = undefined;
var proto: protocol.Protocol = undefined;

fn nowMs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn setCursor(x: i32, y: i32, shape: abi.window.Cursor) void {
    if (cursor_fd < 0) return;
    var cmd = disp.CursorCmd{ .x = x, .y = y, .visible = @intFromBool(shape != .hidden) };
    if (shape != cursor_shape) {
        cursor_shape = shape;
        cursor_hot = cursor.render(gpa, shape, cursor_img);
        cmd.update_image = 1;
    }
    cmd.hot_x = cursor_hot.x;
    cmd.hot_y = cursor_hot.y;
    _ = zio.write(cursor_fd, std.mem.asBytes(&cmd)) catch {};
}

fn postNotification(s: *st.State, title: []const u8, body: []const u8) void {
    var n = st.Notification{ .expires_ms = s.now_ms + 5000 };
    n.title_len = @min(title.len, n.title.len);
    @memcpy(n.title[0..n.title_len], title[0..n.title_len]);
    n.body_len = @min(body.len, n.body.len);
    @memcpy(n.body[0..n.body_len], body[0..n.body_len]);
    if (s.notifications.items.len >= 4) _ = s.notifications.orderedRemove(0);
    s.notifications.append(s.allocator, n) catch return;
    s.invalidate(.{ .x = s.width - 400, .y = 0, .w = 400, .h = 420 });
}

fn notifyHook(s: *st.State, pid: u32, title: []const u8, body: []const u8) void {
    _ = pid;
    postNotification(s, title, body);
}

// Apps are opened from a separate thread: launchd verifies signatures and
// then calls back into the window server ("app-launched"), so waiting for
// it here would freeze the desktop or deadlock.
const Launcher = struct {
    const Note = struct { title: []u8, body: []u8 };
    var mutex: std.Thread.Mutex = .{};
    var cond: std.Thread.Condition = .{};
    var requests: std.ArrayList([]u8) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    /// Written by the thread to wake the main loop.
    var wake: [2]posix.fd_t = .{ -1, -1 };

    fn start() void {
        wake = posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) catch return;
        const t = std.Thread.spawn(.{}, run, .{}) catch return;
        t.detach();
    }

    fn open(id: []const u8) void {
        mutex.lock();
        defer mutex.unlock();
        const copy = gpa.dupe(u8, id) catch return;
        requests.append(gpa, copy) catch return gpa.free(copy);
        cond.signal();
    }

    fn note(title: []const u8, body: []const u8) void {
        mutex.lock();
        const t = gpa.dupe(u8, title) catch "";
        const b = gpa.dupe(u8, body) catch "";
        notes.append(gpa, .{ .title = @constCast(t), .body = @constCast(b) }) catch {};
        mutex.unlock();
        _ = posix.write(wake[1], "x") catch {};
    }

    fn run() void {
        while (true) {
            mutex.lock();
            while (requests.items.len == 0) cond.wait(&mutex);
            const id = requests.orderedRemove(0);
            mutex.unlock();
            defer gpa.free(id);
            var buf: [256]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "open {s}", .{id}) catch continue;
            var reply: [256]u8 = undefined;
            const got = zio.transact("launch:ctl", cmd, &reply) catch {
                note("Cannot open application", "The launch service is not running.");
                continue;
            };
            const r = std.mem.trim(u8, got, " \r\n");
            if (std.mem.startsWith(u8, r, "error gatekeeper")) {
                note("Application blocked", r["error gatekeeper ".len..]);
            } else if (std.mem.startsWith(u8, r, "error")) {
                note("Cannot open application", r[@min(r.len, 6)..]);
            }
        }
    }

    /// Main loop: show notifications the thread produced.
    fn drain(s: *st.State) void {
        var junk: [64]u8 = undefined;
        while (true) _ = posix.read(wake[0], &junk) catch break;
        mutex.lock();
        defer mutex.unlock();
        for (notes.items) |n| {
            postNotification(s, n.title, n.body);
            gpa.free(n.title);
            gpa.free(n.body);
        }
        notes.clearRetainingCapacity();
    }
};

fn launch(s: *st.State, id: []const u8) void {
    _ = s;
    if (std.mem.eql(u8, id, "spotlight")) return;
    if (std.mem.eql(u8, id, "trash")) return Launcher.open("com.zen.Finder");
    Launcher.open(id);
}

fn screenshot(s: *st.State) void {
    if (s.session_user_len == 0) return;
    const ts = posix.clock_gettime(.REALTIME) catch return;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts.sec, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/Users/{s}/Desktop/Screenshot {d}-{d:0>2}-{d:0>2} at {d:0>2}.{d:0>2}.{d:0>2}.png", .{
        s.userName(), yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch return;
    gfx.png.writeFile(comp.fb, path) catch {
        postNotification(s, "Screenshot failed", "Could not write to the Desktop.");
        return;
    };
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    const linux = std.os.linux;
    _ = linux.syscall5(.fchownat, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z.ptr), s.session_uid, s.session_uid, 0);
    postNotification(s, "Screenshot", std.fs.path.basename(path));
}

fn sessionMessage(s: *st.State, msg: []const u8) void {
    s.control_out.appendSlice(s.allocator, msg) catch return;
    s.control_out.append(s.allocator, '\n') catch return;
    proto.flushEvents();
}

const default_dock = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "com.zen.Finder", "Finder", "finder" },
    .{ "com.zen.Terminal", "Terminal", "terminal" },
    .{ "com.zen.TextEdit", "TextEdit", "textedit" },
    .{ "com.zen.Calculator", "Calculator", "calculator" },
    .{ "com.zen.ActivityMonitor", "Activity Monitor", "activity" },
    .{ "com.zen.Settings", "Settings", "settings" },
    .{ "trash", "Trash", "trash" },
};

fn setupDock(s: *st.State) void {
    s.dock.clearRetainingCapacity();
    for (default_dock) |d| {
        s.dock.append(s.allocator, .{ .id = d[0], .name = d[1], .icon = d[2], .pinned = true }) catch {};
    }
}

fn dockSetRunning(s: *st.State, id: []const u8, running: bool) void {
    for (s.dock.items, 0..) |*d, i| {
        if (std.mem.eql(u8, d.id, id)) {
            d.running = running;
            // Unpinned apps leave the Dock when they quit.
            if (!running and !d.pinned) _ = s.dock.orderedRemove(i);
            s.invalidateAll();
            return;
        }
    }
    if (!running) return;
    // A running app that is not in the Dock: add it before the Trash.
    const owned_id = s.allocator.dupe(u8, id) catch return;
    var name: []const u8 = owned_id;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    var icon_buf: [64]u8 = undefined;
    const icon = s.allocator.dupe(u8, std.ascii.lowerString(icon_buf[0..@min(name.len, icon_buf.len)], name[0..@min(name.len, icon_buf.len)])) catch return;
    const item = st.DockItem{ .id = owned_id, .name = name, .icon = icon, .pinned = false, .running = true };
    var pos = s.dock.items.len;
    if (pos > 0 and std.mem.eql(u8, s.dock.items[pos - 1].id, "trash")) pos -= 1;
    s.dock.insert(s.allocator, pos, item) catch return;
    s.invalidateAll();
}

/// Bring the frontmost window of process `pid` forward (restoring it when
/// minimized) and optionally tell it that documents are waiting.
fn activateApp(s: *st.State, pid: u32, documents: bool) void {
    var best: ?*wm.Window = null;
    for (s.manager.order.items) |wid| {
        const w = s.manager.get(wid) orelse continue;
        if (w.owner_pid == pid and w.layer == .normal) best = w;
    }
    const win = best orelse return;
    win.minimized = false;
    win.visible = true;
    s.manager.raise(win.id);
    const prev = s.manager.focus(win.id);
    if (prev != win.id) {
        if (s.manager.get(prev)) |p| {
            p.pushEvent(.{ .kind = .focus, .a = 0 });
            s.invalidate(p.paintBounds());
        }
        win.pushEvent(.{ .kind = .focus, .a = 1 });
    }
    if (documents) win.pushEvent(.{ .kind = .open_documents });
    s.invalidate(win.paintBounds());
    s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
}

fn controlHook(s: *st.State, uid: u32, line: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return;
    const root = uid == 0;
    if (std.mem.eql(u8, cmd, "session-begin") and root) {
        const uid_s = it.next() orelse return;
        const name = it.next() orelse "";
        s.session_uid = std.fmt.parseInt(u32, uid_s, 10) catch return;
        s.session_user_len = @min(name.len, s.session_user.len);
        @memcpy(s.session_user[0..s.session_user_len], name[0..s.session_user_len]);
        s.session = .active;
        setupDock(s);
        s.invalidateAll();
    } else if (std.mem.eql(u8, cmd, "session-end") and root) {
        s.session = .login;
        s.session_user_len = 0;
        s.apps.clearRetainingCapacity();
        s.invalidateAll();
    } else if (std.mem.eql(u8, cmd, "lock") and root) {
        s.session = .locked;
        s.invalidateAll();
    } else if (std.mem.eql(u8, cmd, "unlock") and root) {
        s.session = .active;
        s.invalidateAll();
    } else if ((std.mem.eql(u8, cmd, "app-activate") or std.mem.eql(u8, cmd, "app-open")) and root) {
        // launchd: a running app was opened again (with documents).
        const pid = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
        activateApp(s, pid, std.mem.eql(u8, cmd, "app-open"));
    } else if (std.mem.eql(u8, cmd, "app-launched") and root) {
        const pid = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
        const id = it.next() orelse return;
        var app = st.App{ .pid = pid };
        app.id_len = @min(id.len, app.id.len);
        @memcpy(app.id[0..app.id_len], id[0..app.id_len]);
        var name: []const u8 = id;
        for (s.dock.items) |d| if (std.mem.eql(u8, d.id, id)) {
            name = d.name;
        };
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
        app.name_len = @min(name.len, app.name.len);
        @memcpy(app.name[0..app.name_len], name[0..app.name_len]);
        s.apps.append(s.allocator, app) catch return;
        dockSetRunning(s, id, true);
    } else if (std.mem.eql(u8, cmd, "app-exited") and root) {
        const pid = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
        const id = it.next() orelse "";
        for (s.apps.items, 0..) |a, i| {
            if (a.pid == pid) {
                _ = s.apps.swapRemove(i);
                break;
            }
        }
        proto.reapProcess(pid);
        dockSetRunning(s, id, false);
    } else if (std.mem.eql(u8, cmd, "appearance") and (root or uid == s.session_uid)) {
        const v = it.next() orelse return;
        s.appearance.dark = std.mem.eql(u8, v, "dark");
        chrome.broadcastAppearance(s);
    } else if (std.mem.eql(u8, cmd, "accent") and (root or uid == s.session_uid)) {
        s.appearance.accent = std.fmt.parseInt(u8, it.next() orelse return, 10) catch return;
        chrome.broadcastAppearance(s);
    } else if (std.mem.eql(u8, cmd, "wallpaper") and (root or uid == s.session_uid)) {
        s.appearance.wallpaper = std.fmt.parseInt(u8, it.next() orelse return, 10) catch return;
        s.appearance_serial +%= 1;
        s.invalidateAll();
    } else if (std.mem.eql(u8, cmd, "transparency") and (root or uid == s.session_uid)) {
        s.appearance.reduce_transparency = std.mem.eql(u8, it.next() orelse "", "reduce");
        chrome.broadcastAppearance(s);
    } else if (std.mem.eql(u8, cmd, "clock24") and (root or uid == s.session_uid)) {
        s.appearance.clock_24h = std.mem.eql(u8, it.next() orelse "", "on");
        s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
    } else if (std.mem.eql(u8, cmd, "tz") and (root or uid == s.session_uid)) {
        // Local time offset from UTC in minutes (UTC-12:00 … UTC+14:00).
        const v = std.fmt.parseInt(i32, it.next() orelse return, 10) catch return;
        s.appearance.tz_offset_min = std.math.clamp(v, -720, 840);
        s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
    } else if (std.mem.eql(u8, cmd, "notify")) {
        const rest = it.rest();
        postNotification(s, "Zen OS", rest);
    }
}

fn present(r: gfx.Rect) void {
    const dr = disp.Rect{ .x = @intCast(r.x), .y = @intCast(r.y), .w = @intCast(r.w), .h = @intCast(r.h) };
    _ = zio.write(display_fd, std.mem.asBytes(&dr)) catch {};
}

pub fn main() !void {
    zen.sys.setName("windowserver");

    // Display.
    display_fd = try zio.open("display:0", .{ .ACCMODE = .RDWR }, 0);
    var info: disp.Info = undefined;
    _ = try zio.read(display_fd, std.mem.asBytes(&info));
    const fb_bytes = std.mem.alignForward(usize, @as(usize, info.stride) * info.height, 4096);
    const fb_mem = try zio.mmap(display_fd, fb_bytes, posix.PROT.READ | posix.PROT.WRITE, 0);
    const fb_px: [*]u32 = @ptrCast(@alignCast(fb_mem.ptr));
    const w: i32 = @intCast(info.width);
    const h: i32 = @intCast(info.height);

    // Hardware cursor.
    cursor_fd = zio.open("display:0/cursor", .{ .ACCMODE = .RDWR }, 0) catch -1;
    if (cursor_fd >= 0) {
        const cbytes = std.mem.alignForward(usize, cursor.SIZE * cursor.SIZE * 4, 4096);
        const cm = try zio.mmap(cursor_fd, cbytes, posix.PROT.READ | posix.PROT.WRITE, 0);
        cursor_img = @as([*]u32, @ptrCast(@alignCast(cm.ptr)))[0 .. cursor.SIZE * cursor.SIZE];
    }

    var fonts = try ui.FontSet.load(gpa);
    state = st.State.init(gpa, w, h);
    comp = try comp_mod.Compositor.init(gpa, fb_px[0..@intCast(w * h)], w, h, &fonts);
    comp.setWallpaper(state.appearance.wallpaper, state.appearance.dark);

    proto = .{
        .allocator = gpa,
        .state = &state,
        .srv = try zen.server.Server.register(gpa, "window"),
        .control_hook = controlHook,
        .notify_hook = notifyHook,
    };
    var in = input_mod.Input{
        .state = &state,
        .proto = &proto,
        .actions = .{ .set_cursor = setCursor, .launch = launch, .session = sessionMessage, .screenshot = screenshot },
    };
    const input_fd = zio.open("input:", .{ .ACCMODE = .RDONLY }, 0) catch -1;
    Launcher.start();

    zen.sys.logf("windowserver: {d}x{d}", .{ w, h });
    state.invalidateAll();
    setCursor(state.mouse.x, state.mouse.y, .arrow);

    var ev_buf: [128]abi.input.InputEvent = undefined;
    var last_serial = state.appearance_serial;
    while (true) {
        state.now_ms = nowMs();
        // Wake up for the clock, notification expiry and animations.
        var timeout: i32 = 1000;
        for (state.dock.items) |d| if (d.bounce_until_ms > state.now_ms) {
            timeout = 16;
        };
        var fds = [_]posix.pollfd{
            .{ .fd = proto.srv.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = Launcher.wake[0], .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = input_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const nfds: usize = if (input_fd >= 0) 3 else 2;
        _ = zio.poll(fds[0..nfds], timeout) catch 0;
        state.now_ms = nowMs();
        if (fds[1].revents & posix.POLL.IN != 0) Launcher.drain(&state);

        if (nfds > 2 and fds[2].revents & posix.POLL.IN != 0) {
            const n = zio.read(input_fd, std.mem.sliceAsBytes(&ev_buf)) catch 0;
            in.feed(ev_buf[0 .. n / @sizeOf(abi.input.InputEvent)]);
        }
        if (fds[0].revents & posix.POLL.IN != 0) {
            // Drain a batch of requests before compositing.
            var batch: usize = 0;
            while (batch < 64) : (batch += 1) {
                const req = proto.srv.receive() catch break;
                proto.handle(req);
                var more = [_]posix.pollfd{.{ .fd = proto.srv.fd, .events = posix.POLL.IN, .revents = 0 }};
                if ((posix.poll(&more, 0) catch 0) == 0) break;
            }
        }
        in.flushResize();
        proto.flushEvents();

        // Clock and notification housekeeping.
        const ts = posix.clock_gettime(.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
        if (@divFloor(ts.sec + @as(i64, state.appearance.tz_offset_min) * 60, 60) != state.clock_minute) {
            state.invalidate(.{ .x = state.width - 360, .y = 0, .w = 360, .h = wm.MENUBAR });
        }
        var i: usize = 0;
        while (i < state.notifications.items.len) {
            if (state.notifications.items[i].expires_ms <= state.now_ms) {
                _ = state.notifications.orderedRemove(i);
                state.invalidate(.{ .x = state.width - 400, .y = 0, .w = 400, .h = 420 });
            } else i += 1;
        }
        for (state.dock.items) |d| if (d.bounce_until_ms + 40 > state.now_ms) {
            state.invalidate(comp_mod.fromG(comp_mod.toG(d.rect).inset(-4, -24)));
        };

        if (state.appearance_serial != last_serial) {
            last_serial = state.appearance_serial;
            comp.setWallpaper(state.appearance.wallpaper, state.appearance.dark);
            state.invalidateAll();
        }
        if (!state.dirty.isEmpty()) {
            const drawn = comp.compose(&state, comp_mod.toG(state.dirty));
            state.dirty = .{};
            present(drawn);
        }
    }
}
