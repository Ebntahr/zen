//! `window:` scheme request handling.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const wm = @import("wm.zig");
const st = @import("state.zig");

const posix = std.posix;
const sc = abi.scheme;
const proto = abi.window;
const E = std.os.linux.E;

pub const HandleKind = enum { window, clipboard, control };

pub const Handle = struct {
    kind: HandleKind,
    window: u32 = 0,
    uid: u32 = 0,
    pid: u32 = 0,
    nonblock: bool = false,
    /// Clipboard: bytes written since open (replace on close).
    staged: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
};

const Pending = struct { id: u64, handle: u64, len: u64, fevent: bool };

pub const Protocol = struct {
    allocator: std.mem.Allocator,
    state: *st.State,
    srv: zen.server.Server,
    handles: zen.server.HandleTable(Handle) = .{},
    pending: std.ArrayList(Pending) = .empty,
    /// Hook: called for control commands the protocol does not handle.
    control_hook: *const fn (state: *st.State, uid: u32, line: []const u8) void,
    /// Hook: posts a notification banner.
    notify_hook: *const fn (state: *st.State, pid: u32, title: []const u8, body: []const u8) void,

    fn reply(self: *Protocol, id: u64, result: i64, data: []const u8) void {
        self.srv.reply(id, result, data) catch {};
    }

    fn fail(self: *Protocol, id: u64, e: E) void {
        self.srv.replyError(id, e) catch {};
    }

    fn allocBuffer(w: i32, h: i32) ![]align(4096) u32 {
        const bytes = std.mem.alignForward(usize, @as(usize, @intCast(w * h)) * 4, 4096);
        const mem = try posix.mmap(null, bytes, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .POPULATE = true }, -1, 0);
        const words: [*]align(4096) u32 = @ptrCast(@alignCast(mem.ptr));
        return words[0..@intCast(w * h)];
    }

    fn freeBuffer(pixels: []align(4096) u32) void {
        if (pixels.len == 0) return;
        const bytes: [*]align(4096) u8 = @ptrCast(pixels.ptr);
        posix.munmap(bytes[0..std.mem.alignForward(usize, pixels.len * 4, 4096)]);
    }

    /// (Re)allocate a window's buffer for its current content size.
    pub fn resizeBuffer(win: *wm.Window) void {
        if (win.buf_w == win.content.w and win.buf_h == win.content.h and win.pixels.len > 0) return;
        const fresh = allocBuffer(win.content.w, win.content.h) catch return;
        // Keep the old contents visible (top-left aligned) until the app redraws.
        const cw = @min(win.buf_w, win.content.w);
        const ch = @min(win.buf_h, win.content.h);
        var y: i32 = 0;
        while (y < ch) : (y += 1) {
            const src = win.pixels[@intCast(y * win.buf_w)..][0..@intCast(cw)];
            const dst = fresh[@intCast(y * win.content.w)..][0..@intCast(cw)];
            @memcpy(dst, src);
        }
        freeBuffer(win.pixels);
        win.pixels = fresh;
        win.buf_w = win.content.w;
        win.buf_h = win.content.h;
    }

    pub fn destroyWindow(self: *Protocol, id: u32) void {
        const win = self.state.manager.get(id) orelse return;
        self.state.invalidate(win.paintBounds());
        freeBuffer(win.pixels);
        self.state.manager.destroy(id);
        if (self.state.manager.focused != 0) {
            if (self.state.manager.get(self.state.manager.focused)) |f| {
                f.pushEvent(.{ .kind = .focus, .a = 1 });
                self.state.invalidate(f.paintBounds());
            }
        }
    }

    fn openWindow(self: *Protocol, in: zen.server.Incoming, query: []const u8) void {
        const req = in.req;
        const q = zen.url;
        const flags = q.queryInt(u32, query, "flags", proto.Flags.resizable);
        if (flags & (proto.Flags.shield | proto.Flags.desktop) != 0 and req.uid != 0) return self.fail(req.id, .ACCES);
        var title_buf: [256]u8 = undefined;
        const title = q.decode(q.queryGet(query, "title") orelse "", &title_buf);
        const has_x = q.queryGet(query, "x") != null and q.queryGet(query, "y") != null;
        var w = q.queryInt(i32, query, "w", 640);
        var h = q.queryInt(i32, query, "h", 480);
        if (flags & proto.Flags.shield != 0) {
            w = self.state.width;
            h = self.state.height;
        }
        const win = self.state.manager.create(.{
            .pid = req.pid,
            .uid = req.uid,
            .w = w,
            .h = h,
            .x = if (has_x) q.queryInt(i32, query, "x", 0) else null,
            .y = if (has_x) q.queryInt(i32, query, "y", 0) else null,
            .flags = flags,
            .min_w = q.queryInt(i32, query, "minw", 120),
            .min_h = q.queryInt(i32, query, "minh", 60),
            .title = title,
        }) catch return self.fail(req.id, .NOMEM);
        resizeBuffer(win);
        if (win.pixels.len == 0) {
            self.state.manager.destroy(win.id);
            return self.fail(req.id, .NOMEM);
        }
        if (self.state.appByPid(req.pid)) |app| {
            win.app_id_len = app.id_len;
            @memcpy(win.app_id[0..app.id_len], app.id[0..app.id_len]);
        }
        const hid = self.handles.insert(self.allocator, .{
            .kind = .window,
            .window = win.id,
            .uid = req.uid,
            .pid = req.pid,
            .nonblock = req.flags & sc.O_NONBLOCK != 0,
        }) catch return self.fail(req.id, .NOMEM);
        // New windows get focus unless they are popups.
        if (win.visible and win.layer != .popup and win.layer != .desktop) {
            const prev = self.state.manager.focus(win.id);
            if (self.state.manager.get(prev)) |p| {
                p.pushEvent(.{ .kind = .focus, .a = 0 });
                self.state.invalidate(p.paintBounds());
            }
            win.pushEvent(.{ .kind = .focus, .a = 1 });
        }
        win.pushEvent(.{ .kind = .appearance, .a = @intFromBool(self.state.appearance.dark), .b = @bitCast(themeAccent(self.state)), .c = @intFromBool(self.state.appearance.reduce_transparency) });
        self.state.invalidate(win.paintBounds());
        self.reply(req.id, @intCast(hid), "");
    }

    pub fn themeAccent(state: *const st.State) u32 {
        const theme = @import("ui").theme;
        const acc: theme.Accent = @enumFromInt(@min(state.appearance.accent, 7));
        return acc.color(state.appearance.dark);
    }

    fn handleOpen(self: *Protocol, in: zen.server.Incoming) void {
        const req = in.req;
        const u = zen.url.parse(in.payload);
        const path = std.mem.trim(u8, u.path, "/");
        if (std.mem.eql(u8, path, "new") or path.len == 0) return self.openWindow(in, u.query);
        const kind: HandleKind = if (std.mem.eql(u8, path, "clipboard"))
            .clipboard
        else if (std.mem.eql(u8, path, "control"))
            .control
        else
            return self.fail(req.id, .NOENT);
        var h = Handle{ .kind = kind, .uid = req.uid, .pid = req.pid };
        if (kind == .clipboard and req.flags & sc.O_TRUNC != 0) h.staged = .empty;
        const id = self.handles.insert(self.allocator, h) catch return self.fail(req.id, .NOMEM);
        self.reply(req.id, @intCast(id), "");
    }

    fn handleCommands(self: *Protocol, win: *wm.Window, data: []const u8) void {
        var it = proto.CommandIterator{ .buf = data };
        const s = self.state;
        while (it.next()) |cmd| {
            switch (cmd.kind) {
                .damage => {
                    if (cmd.body.len < @sizeOf(proto.Rect)) continue;
                    var r: proto.Rect = undefined;
                    @memcpy(std.mem.asBytes(&r), cmd.body[0..@sizeOf(proto.Rect)]);
                    const local = wm.Rect{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
                    win.addDamage(local);
                    s.invalidate(local.offset(win.content.x, win.content.y).inflate(1));
                },
                .set_title => {
                    win.setTitle(cmd.body);
                    s.invalidate(win.frame());
                    s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
                },
                .resize => {
                    if (cmd.body.len < @sizeOf(proto.Size)) continue;
                    var sz: proto.Size = undefined;
                    @memcpy(std.mem.asBytes(&sz), cmd.body[0..@sizeOf(proto.Size)]);
                    s.invalidate(win.paintBounds());
                    win.content.w = std.math.clamp(sz.w, win.min_w, 8192);
                    win.content.h = std.math.clamp(sz.h, win.min_h, 8192);
                    resizeBuffer(win);
                    win.pushEvent(.{ .kind = .resize, .a = win.content.w, .b = win.content.h });
                    s.invalidate(win.paintBounds());
                },
                .move => {
                    if (cmd.body.len < @sizeOf(proto.Point)) continue;
                    var p: proto.Point = undefined;
                    @memcpy(std.mem.asBytes(&p), cmd.body[0..@sizeOf(proto.Point)]);
                    s.invalidate(win.paintBounds());
                    const tb: i32 = if (win.hasTitlebar()) wm.TITLEBAR else 0;
                    win.content.x = p.x;
                    win.content.y = p.y + tb;
                    s.invalidate(win.paintBounds());
                },
                .show => {
                    win.visible = true;
                    win.minimized = false;
                    s.invalidate(win.paintBounds());
                },
                .hide => {
                    win.visible = false;
                    s.invalidate(win.paintBounds());
                    if (s.manager.focused == win.id) s.manager.focusTopmost();
                },
                .activate => {
                    win.visible = true;
                    win.minimized = false;
                    s.manager.raise(win.id);
                    const prev = s.manager.focus(win.id);
                    if (prev != win.id) {
                        if (s.manager.get(prev)) |p| {
                            p.pushEvent(.{ .kind = .focus, .a = 0 });
                            s.invalidate(p.paintBounds());
                        }
                        win.pushEvent(.{ .kind = .focus, .a = 1 });
                    }
                    s.invalidate(win.paintBounds());
                    s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
                },
                .minimize => {
                    win.minimized = true;
                    s.invalidate(win.paintBounds());
                    if (s.manager.focused == win.id) s.manager.focusTopmost();
                },
                .zoom => {
                    s.invalidate(win.paintBounds());
                    s.manager.toggleZoom(win);
                    resizeBuffer(win);
                    win.pushEvent(.{ .kind = .resize, .a = win.content.w, .b = win.content.h });
                    s.invalidate(win.paintBounds());
                },
                .set_cursor => {
                    if (cmd.body.len >= 4) win.cursor = @enumFromInt(std.mem.readInt(u32, cmd.body[0..4], .little));
                },
                .set_menu => {
                    win.menu.clearRetainingCapacity();
                    win.menu.appendSlice(self.allocator, cmd.body) catch {};
                    s.invalidate(.{ .w = s.width, .h = wm.MENUBAR });
                },
                .set_flags => {
                    if (cmd.body.len >= 4) {
                        s.invalidate(win.paintBounds());
                        const keep = proto.Flags.shield | proto.Flags.desktop;
                        win.flags = (win.flags & keep) | (std.mem.readInt(u32, cmd.body[0..4], .little) & ~keep);
                        s.invalidate(win.paintBounds());
                    }
                },
                .set_min_size => {
                    if (cmd.body.len >= 8) {
                        win.min_w = @max(40, std.mem.readInt(i32, cmd.body[0..4], .little));
                        win.min_h = @max(20, std.mem.readInt(i32, cmd.body[4..8], .little));
                    }
                },
                .begin_move => {
                    s.manager.beginDrag(win, .move, .{}, s.mouse.x, s.mouse.y);
                },
                .set_title_height => {
                    if (cmd.body.len >= 4) win.title_height = std.math.clamp(std.mem.readInt(i32, cmd.body[0..4], .little), 0, 120);
                },
                .notify => {
                    const pair = zen.server.splitPair(cmd.body) orelse continue;
                    self.notify_hook(s, win.owner_pid, pair.a, pair.b);
                },
                .set_edited => {
                    if (cmd.body.len >= 4) {
                        win.edited = std.mem.readInt(u32, cmd.body[0..4], .little) != 0;
                        s.invalidate(win.frame());
                    }
                },
                _ => {},
            }
        }
    }

    /// Answer pending reads/fevents that can now be satisfied.
    pub fn flushEvents(self: *Protocol) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            const h = self.handles.get(p.handle) orelse {
                _ = self.pending.swapRemove(i);
                continue;
            };
            if (h.kind == .control) {
                const data = self.state.control_out.items;
                if (data.len == 0) {
                    i += 1;
                    continue;
                }
                if (p.fevent) {
                    self.reply(p.id, sc.POLLIN, "");
                } else {
                    const n: usize = @intCast(@min(data.len, p.len));
                    self.reply(p.id, @intCast(n), data[0..n]);
                    self.state.control_out.replaceRange(self.allocator, 0, n, "") catch {};
                }
                _ = self.pending.swapRemove(i);
                continue;
            }
            const win = self.state.manager.get(h.window) orelse {
                // Window gone: wake the reader with EOF.
                self.reply(p.id, 0, "");
                _ = self.pending.swapRemove(i);
                continue;
            };
            if (win.ev_len == 0) {
                i += 1;
                continue;
            }
            if (p.fevent) {
                self.reply(p.id, sc.POLLIN, "");
            } else {
                var evs: [64]proto.Event = undefined;
                const max = @min(evs.len, p.len / @sizeOf(proto.Event));
                const n = win.popEvents(evs[0..max]);
                self.reply(p.id, @intCast(n * @sizeOf(proto.Event)), std.mem.sliceAsBytes(evs[0..n]));
            }
            _ = self.pending.swapRemove(i);
        }
    }

    pub fn handle(self: *Protocol, in: zen.server.Incoming) void {
        const req = in.req;
        switch (req.op) {
            .open => return self.handleOpen(in),
            .cancel => {
                for (self.pending.items, 0..) |p, i| {
                    if (p.id == req.arg0) {
                        _ = self.pending.swapRemove(i);
                        break;
                    }
                }
                return;
            },
            else => {},
        }
        const h = self.handles.get(req.handle) orelse return self.fail(req.id, .BADF);
        switch (req.op) {
            .close => {
                switch (h.kind) {
                    .window => self.destroyWindow(h.window),
                    .clipboard => {
                        if (h.staged.items.len > 0) {
                            self.state.clipboard.clearRetainingCapacity();
                            self.state.clipboard.appendSlice(self.allocator, h.staged.items) catch {};
                        }
                        h.staged.deinit(self.allocator);
                    },
                    .control => {},
                }
                _ = self.handles.remove(self.allocator, req.handle);
            },
            .read => switch (h.kind) {
                .window => {
                    if (req.len < @sizeOf(proto.Event)) return self.fail(req.id, .INVAL);
                    const win = self.state.manager.get(h.window) orelse return self.reply(req.id, 0, "");
                    if (win.ev_len == 0 and h.nonblock) return self.fail(req.id, .AGAIN);
                    self.pending.append(self.allocator, .{ .id = req.id, .handle = req.handle, .len = req.len, .fevent = false }) catch return self.fail(req.id, .NOMEM);
                    self.flushEvents();
                },
                .clipboard => {
                    const data = self.state.clipboard.items;
                    const rest = data[@min(h.read_pos, data.len)..];
                    const n: usize = @intCast(@min(rest.len, req.len));
                    h.read_pos += n;
                    self.reply(req.id, @intCast(n), rest[0..n]);
                },
                .control => {
                    if (h.uid != 0) return self.reply(req.id, 0, "");
                    self.pending.append(self.allocator, .{ .id = req.id, .handle = req.handle, .len = req.len, .fevent = false }) catch return self.fail(req.id, .NOMEM);
                    self.flushEvents();
                },
            },
            .write => switch (h.kind) {
                .window => {
                    const win = self.state.manager.get(h.window) orelse return self.fail(req.id, .PIPE);
                    self.handleCommands(win, in.payload);
                    self.reply(req.id, @intCast(in.payload.len), "");
                    self.flushEvents();
                },
                .clipboard => {
                    h.staged.appendSlice(self.allocator, in.payload) catch return self.fail(req.id, .NOMEM);
                    self.reply(req.id, @intCast(in.payload.len), "");
                },
                .control => {
                    self.control_hook(self.state, h.uid, std.mem.trim(u8, in.payload, " \r\n"));
                    self.reply(req.id, @intCast(in.payload.len), "");
                    self.flushEvents();
                },
            },
            .fmap => {
                if (h.kind != .window) return self.fail(req.id, .NODEV);
                const win = self.state.manager.get(h.window) orelse return self.fail(req.id, .NODEV);
                const bytes = std.mem.alignForward(usize, win.pixels.len * 4, 4096);
                if (req.arg0 + req.arg1 > bytes) return self.fail(req.id, .INVAL);
                self.reply(req.id, @intCast(@intFromPtr(win.pixels.ptr) + req.arg0), "");
            },
            .funmap => {},
            .fevent => {
                if (h.kind == .clipboard) return self.reply(req.id, sc.POLLIN | sc.POLLOUT, "");
                self.pending.append(self.allocator, .{ .id = req.id, .handle = req.handle, .len = 0, .fevent = true }) catch return self.fail(req.id, .NOMEM);
                self.flushEvents();
            },
            .fstat => {
                const stat = sc.Stat{ .mode = sc.S_IFCHR | 0o666 };
                self.srv.replyStruct(req.id, &stat) catch {};
            },
            .fpath => {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{h.window}) catch "";
                self.reply(req.id, @intCast(s.len), s);
            },
            else => self.fail(req.id, .NOSYS),
        }
    }

    /// Destroy windows whose owning process has exited.
    pub fn reapProcess(self: *Protocol, pid: u32) void {
        var it = self.handles.iterator();
        while (it.next()) |e| {
            if (e.value.pid == pid and e.value.kind == .window) self.destroyWindow(e.value.window);
        }
    }
};
