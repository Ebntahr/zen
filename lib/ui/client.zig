//! Connection between an app and the window server (`window:` scheme).
//!
//! A `Window` owns a pixel buffer shared with the window server. On hosts
//! without a window server (development machines) the window runs
//! "headless": the buffer is ordinary memory and no events arrive, which
//! lets apps render previews/screenshots in tests.

const std = @import("std");
const abi = @import("abi");
const posix = std.posix;
const zio = @import("zen").io;
const proto = abi.window;

pub const Event = proto.Event;
pub const Flags = proto.Flags;
pub const Mods = proto.Mods;
pub const Cursor = proto.Cursor;

pub const Options = struct {
    title: []const u8 = "",
    width: i32 = 640,
    height: i32 = 480,
    x: ?i32 = null,
    y: ?i32 = null,
    min_width: i32 = 200,
    min_height: i32 = 120,
    flags: u32 = proto.Flags.resizable,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    /// -1 when headless.
    fd: posix.fd_t,
    width: i32,
    height: i32,
    pixels: []align(4096) u32,
    headless: bool,
    /// Creation flags (abi.window.Flags).
    flags: u32 = 0,
    /// Height of the title area of a full-size-content window.
    title_height: i32 = 32,
    cmd_buf: std.ArrayList(u8) = .empty,
    events: [64]Event = undefined,

    pub fn open(allocator: std.mem.Allocator, opts: Options) !Window {
        var url_buf: [1024]u8 = undefined;
        var enc_buf: [512]u8 = undefined;
        const title = @import("zen").url.encode(opts.title, &enc_buf);
        var fbs = std.io.fixedBufferStream(&url_buf);
        const w = fbs.writer();
        try w.print("window:new?w={d}&h={d}&minw={d}&minh={d}&flags={d}&title={s}", .{ opts.width, opts.height, opts.min_width, opts.min_height, opts.flags, title });
        if (opts.x) |x| try w.print("&x={d}", .{x});
        if (opts.y) |y| try w.print("&y={d}", .{y});

        const fd = zio.open(fbs.getWritten(), .{ .ACCMODE = .RDWR }, 0) catch {
            return openHeadless(allocator, opts);
        };
        var win = Window{
            .allocator = allocator,
            .fd = fd,
            .width = opts.width,
            .height = opts.height,
            .pixels = &.{},
            .headless = false,
            .flags = opts.flags,
        };
        try win.mapBuffer();
        return win;
    }

    pub fn openHeadless(allocator: std.mem.Allocator, opts: Options) !Window {
        const n: usize = @intCast(opts.width * opts.height);
        const pixels = try allocator.alignedAlloc(u32, .fromByteUnits(4096), n);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .fd = -1,
            .width = opts.width,
            .height = opts.height,
            .pixels = pixels,
            .headless = true,
            .flags = opts.flags,
        };
    }

    fn mapBuffer(self: *Window) !void {
        const len: usize = @intCast(self.width * self.height * 4);
        const mapped = try zio.mmap(self.fd, std.mem.alignForward(usize, len, 4096), posix.PROT.READ | posix.PROT.WRITE, 0);
        const words: [*]align(4096) u32 = @ptrCast(@alignCast(mapped.ptr));
        self.pixels = words[0..@intCast(self.width * self.height)];
    }

    fn unmapBuffer(self: *Window) void {
        if (self.pixels.len == 0) return;
        if (self.headless) {
            self.allocator.free(self.pixels);
        } else {
            const bytes: [*]align(4096) u8 = @ptrCast(self.pixels.ptr);
            posix.munmap(bytes[0..std.mem.alignForward(usize, self.pixels.len * 4, 4096)]);
        }
        self.pixels = &.{};
    }

    pub fn close(self: *Window) void {
        self.unmapBuffer();
        if (!self.headless) zio.close(self.fd);
        self.cmd_buf.deinit(self.allocator);
    }

    /// Queue a command; commands are sent by `flush`.
    pub fn command(self: *Window, kind: proto.CommandKind, body: []const u8) void {
        if (self.headless) return;
        const hdr = proto.CommandHeader{ .kind = kind, .size = @intCast(@sizeOf(proto.CommandHeader) + body.len) };
        self.cmd_buf.appendSlice(self.allocator, std.mem.asBytes(&hdr)) catch return;
        self.cmd_buf.appendSlice(self.allocator, body) catch return;
    }

    pub fn flush(self: *Window) void {
        if (self.headless or self.cmd_buf.items.len == 0) return;
        var off: usize = 0;
        while (off < self.cmd_buf.items.len) {
            off += zio.write(self.fd, self.cmd_buf.items[off..]) catch break;
        }
        self.cmd_buf.clearRetainingCapacity();
    }

    /// Present a changed region of the buffer.
    pub fn damage(self: *Window, x: i32, y: i32, w: i32, h: i32) void {
        const r = proto.Rect{ .x = x, .y = y, .w = w, .h = h };
        self.command(.damage, std.mem.asBytes(&r));
    }

    pub fn damageAll(self: *Window) void {
        self.damage(0, 0, self.width, self.height);
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        self.command(.set_title, title);
    }

    pub fn setCursor(self: *Window, c: Cursor) void {
        const v: u32 = @intFromEnum(c);
        self.command(.set_cursor, std.mem.asBytes(&v));
    }

    pub fn setMenu(self: *Window, menu: []const u8) void {
        self.command(.set_menu, menu);
    }

    pub fn setTitleHeight(self: *Window, h: i32) void {
        self.title_height = h;
        self.command(.set_title_height, std.mem.asBytes(&h));
    }

    pub fn setEdited(self: *Window, edited: bool) void {
        const v: u32 = @intFromBool(edited);
        self.command(.set_edited, std.mem.asBytes(&v));
    }

    pub fn requestResize(self: *Window, w: i32, h: i32) void {
        const s = proto.Size{ .w = w, .h = h };
        self.command(.resize, std.mem.asBytes(&s));
    }

    /// Toggle between the user size and the zoomed (screen-filling) size.
    pub fn zoom(self: *Window) void {
        self.command(.zoom, "");
    }

    pub fn beginMove(self: *Window) void {
        self.command(.begin_move, "");
    }

    pub fn notify(self: *Window, title: []const u8, body: []const u8) void {
        var buf: [512]u8 = undefined;
        const n = @min(title.len, 200);
        const m = @min(body.len, 300);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        @memcpy(buf[n + 1 .. n + 1 + m], body[0..m]);
        self.command(.notify, buf[0 .. n + 1 + m]);
    }

    /// Wait for events (blocking unless `timeout_ms` >= 0). Handles resize
    /// events internally by remapping the buffer before returning them.
    pub fn waitEvents(self: *Window, timeout_ms: i32) []Event {
        if (self.headless) return self.events[0..0];
        self.flush();
        if (timeout_ms >= 0) {
            var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            const n = zio.poll(&fds, timeout_ms) catch 0;
            if (n == 0) return self.events[0..0];
        }
        const bytes = std.mem.sliceAsBytes(&self.events);
        const got = zio.read(self.fd, bytes) catch return self.events[0..0];
        const count = got / @sizeOf(Event);
        for (self.events[0..count]) |e| {
            if (e.kind == .resize and (e.a != self.width or e.b != self.height)) {
                self.unmapBuffer();
                self.width = e.a;
                self.height = e.b;
                self.mapBuffer() catch {};
            }
        }
        return self.events[0..count];
    }

    /// Current state of the system appearance, from an `appearance` event.
    pub fn pollFd(self: *const Window) posix.fd_t {
        return self.fd;
    }
};

/// Read the clipboard (UTF-8). Caller frees.
pub fn clipboardGet(allocator: std.mem.Allocator) ![]u8 {
    return zio.readUrl(allocator, "window:clipboard", 16 << 20);
}

pub fn clipboardSet(text: []const u8) !void {
    const fd = try zio.open("window:clipboard", .{ .ACCMODE = .WRONLY, .TRUNC = true }, 0);
    defer zio.close(fd);
    try zio.writeAll(fd, text);
}
