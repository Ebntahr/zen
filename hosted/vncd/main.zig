//! vncd — display and input driver for hosted Zen.
//!
//! When Zen runs hosted on Linux there is no GPU or input device. vncd
//! takes the place of the virtio-gpu and virtio-input drivers:
//!
//!   * `display:0` — a framebuffer in shared memory (read → `Info`,
//!     mmap → pixels, write → present rectangles) and `display:0/cursor`;
//!   * `input:`    — keyboard and pointer events as evdev codes;
//!
//! and shows the screen to
//!
//!   * browsers: http://127.0.0.1:6080 serves a small web client that speaks
//!     RFB over WebSocket;
//!   * VNC viewers: RFB 3.8 on 127.0.0.1:5900.
//!
//! Settings come from the environment: ZEN_HOSTED_SIZE (1280x800),
//! ZEN_HOSTED_HTTP (6080), ZEN_HOSTED_VNC (5900, 0 = off) and
//! ZEN_HOSTED_BIND (127.0.0.1; Docker sets 0.0.0.0).

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const rfb = @import("rfb.zig");
const deflate = @import("deflate.zig");

/// Private encoding understood by the built-in web client: u32 length and
/// a raw DEFLATE stream of the rectangle's pixels (in the client's format).
pub const enc_zen_deflate: i32 = 0x5A454E01;

const posix = std.posix;
const linux = std.os.linux;
const sc = abi.scheme;
const disp = abi.display;
const inp = abi.input;
const E = linux.E;

const index_html = @embedFile("web/index.html");

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

// ---------------------------------------------------------------------------
// Screen state
// ---------------------------------------------------------------------------

var width: u32 = 1280;
var height: u32 = 800;
var fb: []u32 = &.{};
var fb_mem: []align(std.heap.page_size_min) u8 = &.{};
var cursor_mem: []align(std.heap.page_size_min) u8 = &.{};
var cursor_img: []u32 = &.{};
const CUR = disp.CURSOR_SIZE;

var cursor = struct {
    x: i32 = 0,
    y: i32 = 0,
    hot_x: u32 = 0,
    hot_y: u32 = 0,
    visible: bool = false,
    /// Bumped when the image or visibility changes.
    serial: u32 = 1,
}{};

const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    fn empty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }

    fn unite(a: Rect, b: Rect) Rect {
        if (a.empty()) return b;
        if (b.empty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Clip a signed rectangle to the screen.
    fn clipped(x: i64, y: i64, w: i64, h: i64) Rect {
        const x0 = std.math.clamp(x, 0, width);
        const y0 = std.math.clamp(y, 0, height);
        const x1 = std.math.clamp(x + w, 0, width);
        const y1 = std.math.clamp(y + h, 0, height);
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }
};

fn screen() Rect {
    return .{ .w = width, .h = height };
}

fn cursorRect() Rect {
    return Rect.clipped(@as(i64, cursor.x) - cursor.hot_x, @as(i64, cursor.y) - cursor.hot_y, CUR, CUR);
}

// ---------------------------------------------------------------------------
// display: and input: schemes
// ---------------------------------------------------------------------------

const DisplayHandle = struct { cursor: bool, info_sent: bool = false };
var display_srv: zen.server.Server = undefined;
var display_handles: zen.server.HandleTable(DisplayHandle) = .{};
/// Reads waiting for a mode change (which never happens here).
var display_waiting: std.ArrayList(u64) = .empty;

var input_srv: zen.server.Server = undefined;
var input_handles: zen.server.HandleTable(void) = .{};
const PendingRead = struct { id: u64, handle: u64, len: u64 };
var input_waiting: std.ArrayList(PendingRead) = .empty;
var input_queue: std.ArrayList(inp.InputEvent) = .empty;

fn fail(srv: *zen.server.Server, id: u64, e: E) void {
    srv.replyError(id, e) catch {};
}

fn serveDisplay(in: zen.server.Incoming) void {
    const req = in.req;
    const srv = &display_srv;
    switch (req.op) {
        .open => {
            const path = std.mem.trim(u8, in.payload, "/");
            const is_cursor = std.mem.eql(u8, path, "0/cursor");
            if (!is_cursor and !std.mem.eql(u8, path, "0") and path.len != 0) return fail(srv, req.id, .NOENT);
            const id = display_handles.insert(gpa, .{ .cursor = is_cursor }) catch return fail(srv, req.id, .NOMEM);
            srv.replyValue(req.id, id) catch {};
            return;
        },
        .cancel => {
            for (display_waiting.items, 0..) |w, i| if (w == req.arg0) {
                _ = display_waiting.swapRemove(i);
                break;
            };
            return;
        },
        else => {},
    }
    const h = display_handles.get(req.handle) orelse return fail(srv, req.id, .BADF);
    switch (req.op) {
        .close => _ = display_handles.remove(gpa, req.handle),
        .read => {
            if (h.cursor) return srv.reply(req.id, 0, "") catch {};
            if (!h.info_sent) {
                h.info_sent = true;
                const info = disp.Info{ .width = width, .height = height, .stride = width * 4 };
                return srv.reply(req.id, @sizeOf(disp.Info), std.mem.asBytes(&info)) catch {};
            }
            display_waiting.append(gpa, req.id) catch fail(srv, req.id, .NOMEM);
        },
        .write => {
            if (h.cursor) {
                if (in.payload.len >= @sizeOf(disp.CursorCmd)) {
                    var cmd: disp.CursorCmd = undefined;
                    @memcpy(std.mem.asBytes(&cmd), in.payload[0..@sizeOf(disp.CursorCmd)]);
                    moveCursor(cmd);
                }
            } else {
                var off: usize = 0;
                while (off + @sizeOf(disp.Rect) <= in.payload.len) : (off += @sizeOf(disp.Rect)) {
                    var r: disp.Rect = undefined;
                    @memcpy(std.mem.asBytes(&r), in.payload[off..][0..@sizeOf(disp.Rect)]);
                    markDirty(Rect.clipped(r.x, r.y, r.w, r.h));
                }
            }
            srv.replyValue(req.id, in.payload.len) catch {};
        },
        .fmap => {
            const mem = if (h.cursor) cursor_mem else fb_mem;
            if (req.arg0 + req.arg1 > mem.len) return fail(srv, req.id, .INVAL);
            srv.reply(req.id, @intCast(@intFromPtr(mem.ptr) + req.arg0), "") catch {};
        },
        .fstat => {
            const st = sc.Stat{ .mode = sc.S_IFCHR | 0o660 };
            srv.replyStruct(req.id, &st) catch {};
        },
        else => fail(srv, req.id, .NOSYS),
    }
}

fn serveInput(in: zen.server.Incoming) void {
    const req = in.req;
    const srv = &input_srv;
    switch (req.op) {
        .open => {
            const id = input_handles.insert(gpa, {}) catch return fail(srv, req.id, .NOMEM);
            srv.replyValue(req.id, id) catch {};
            return;
        },
        .cancel => {
            for (input_waiting.items, 0..) |w, i| if (w.id == req.arg0) {
                _ = input_waiting.orderedRemove(i);
                break;
            };
            return;
        },
        else => {},
    }
    if (input_handles.get(req.handle) == null) return fail(srv, req.id, .BADF);
    switch (req.op) {
        .close => {
            _ = input_handles.remove(gpa, req.handle);
            var i: usize = 0;
            while (i < input_waiting.items.len) {
                if (input_waiting.items[i].handle == req.handle) _ = input_waiting.orderedRemove(i) else i += 1;
            }
        },
        .read => {
            if (req.len < @sizeOf(inp.InputEvent)) return fail(srv, req.id, .INVAL);
            input_waiting.append(gpa, .{ .id = req.id, .handle = req.handle, .len = req.len }) catch return fail(srv, req.id, .NOMEM);
            flushInput();
        },
        .fstat => {
            const st = sc.Stat{ .mode = sc.S_IFCHR | 0o660 };
            srv.replyStruct(req.id, &st) catch {};
        },
        else => fail(srv, req.id, .NOSYS),
    }
}

fn flushInput() void {
    while (input_waiting.items.len > 0 and input_queue.items.len > 0) {
        const w = input_waiting.orderedRemove(0);
        const max: usize = @intCast(w.len / @sizeOf(inp.InputEvent));
        const n = @min(max, input_queue.items.len);
        input_srv.reply(w.id, @intCast(n * @sizeOf(inp.InputEvent)), std.mem.sliceAsBytes(input_queue.items[0..n])) catch {};
        input_queue.replaceRange(gpa, 0, n, &.{}) catch {};
    }
    // Do not let an unread queue grow without bound.
    if (input_queue.items.len > 4096) input_queue.replaceRange(gpa, 0, input_queue.items.len - 4096, &.{}) catch {};
}

fn nowNs() u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn pushEvent(kind: u16, code: u16, value: i32) void {
    input_queue.append(gpa, .{ .time_ns = nowNs(), .kind = kind, .code = code, .value = value }) catch {};
}

fn syn() void {
    pushEvent(inp.EV_SYN, 0, 0);
    flushInput();
}

// ---------------------------------------------------------------------------
// Viewers
// ---------------------------------------------------------------------------

const State = enum { http, version, security, client_init, normal };

const Client = struct {
    fd: posix.fd_t,
    state: State,
    ws: bool = false,
    closing: bool = false,
    dead: bool = false,
    /// Bytes from the socket not yet decoded (HTTP or WebSocket frames).
    raw: std.ArrayList(u8) = .empty,
    /// Decoded RFB bytes not yet parsed.
    rin: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    out_pos: usize = 0,
    minor: u8 = 8,
    pf: rfb.PixelFormat = .native,
    enc_cursor: bool = false,
    enc_extkey: bool = false,
    enc_deflate: bool = false,
    extkey_acked: bool = false,
    want_update: bool = false,
    full: bool = false,
    req: Rect = .{},
    dirty: Rect = .{},
    cursor_sent: u32 = 0,
    buttons: u8 = 0,

    fn deinit(c: *Client) void {
        posix.close(c.fd);
        c.raw.deinit(gpa);
        c.rin.deinit(gpa);
        c.out.deinit(gpa);
    }

    fn pending(c: *const Client) usize {
        return c.out.items.len - c.out_pos;
    }
};

var clients: std.ArrayList(*Client) = .empty;

fn markDirty(r: Rect) void {
    if (r.empty()) return;
    for (clients.items) |c| c.dirty = c.dirty.unite(r);
}

fn moveCursor(cmd: disp.CursorCmd) void {
    const old = cursorRect();
    const was_visible = cursor.visible;
    cursor.x = cmd.x;
    cursor.y = cmd.y;
    cursor.hot_x = @min(cmd.hot_x, CUR - 1);
    cursor.hot_y = @min(cmd.hot_y, CUR - 1);
    cursor.visible = cmd.visible != 0;
    if (cmd.update_image != 0 or was_visible != cursor.visible) cursor.serial +%= 1;
    // Viewers without a local cursor get it drawn into the picture.
    for (clients.items) |c| {
        if (c.enc_cursor) continue;
        c.dirty = c.dirty.unite(old).unite(cursorRect());
    }
}

/// Queue bytes for a viewer (one WebSocket message when upgraded).
fn queue(c: *Client, bytes: []const u8) void {
    if (c.ws) {
        var hb: [10]u8 = undefined;
        c.out.appendSlice(gpa, rfb.wsFrameHeader(bytes.len, &hb)) catch return;
    }
    c.out.appendSlice(gpa, bytes) catch return;
}

fn queueRaw(c: *Client, bytes: []const u8) void {
    c.out.appendSlice(gpa, bytes) catch return;
}

fn flushOut(c: *Client) void {
    while (c.out_pos < c.out.items.len) {
        const n = posix.send(c.fd, c.out.items[c.out_pos..], linux.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                c.dead = true;
                return;
            },
        };
        c.out_pos += n;
    }
    c.out.clearRetainingCapacity();
    c.out_pos = 0;
    if (c.closing) c.dead = true;
}

// --- HTTP ------------------------------------------------------------------

fn header(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " "), name)) return std.mem.trim(u8, l[colon + 1 ..], " \t");
    }
    return null;
}

fn httpRespond(c: *Client, status: []const u8, ctype: []const u8, body: []const u8) void {
    var hb: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    queueRaw(c, h);
    queueRaw(c, body);
    c.closing = true;
}

fn handleHttp(c: *Client) void {
    const end = std.mem.indexOf(u8, c.raw.items, "\r\n\r\n") orelse {
        if (c.raw.items.len > 16 * 1024) c.dead = true;
        return;
    };
    const req = c.raw.items[0 .. end + 4];
    var first = std.mem.tokenizeScalar(u8, req[0 .. std.mem.indexOf(u8, req, "\r\n") orelse req.len], ' ');
    const method = first.next() orelse "";
    const path = first.next() orelse "/";
    const upgrade = header(req, "Upgrade");
    if (upgrade != null and std.ascii.eqlIgnoreCase(upgrade.?, "websocket")) {
        const key = header(req, "Sec-WebSocket-Key") orelse {
            httpRespond(c, "400 Bad Request", "text/plain", "missing key\n");
            return;
        };
        var accept_buf: [28]u8 = undefined;
        const accept = rfb.wsAccept(key, &accept_buf);
        var hb: [512]u8 = undefined;
        const proto = header(req, "Sec-WebSocket-Protocol");
        const offer_binary = proto != null and std.mem.indexOf(u8, proto.?, "binary") != null;
        const h = std.fmt.bufPrint(&hb, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n{s}\r\n", .{ accept, if (offer_binary) "Sec-WebSocket-Protocol: binary\r\n" else "" }) catch return;
        queueRaw(c, h);
        c.ws = true;
        c.raw.replaceRange(gpa, 0, end + 4, &.{}) catch {};
        startRfb(c);
        return;
    }
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        httpRespond(c, "405 Method Not Allowed", "text/plain", "");
    } else if (std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/index.html") or std.mem.startsWith(u8, path, "/?")) {
        httpRespond(c, "200 OK", "text/html; charset=utf-8", index_html);
    } else if (std.mem.eql(u8, path, "/favicon.ico")) {
        httpRespond(c, "204 No Content", "text/plain", "");
    } else {
        httpRespond(c, "404 Not Found", "text/plain", "not found\n");
    }
    c.raw.clearRetainingCapacity();
}

// --- RFB -------------------------------------------------------------------

fn startRfb(c: *Client) void {
    c.state = .version;
    queue(c, "RFB 003.008\n");
}

fn sendServerInit(c: *Client) void {
    const name = "Zen OS";
    var msg: [24 + name.len]u8 = undefined;
    std.mem.writeInt(u16, msg[0..2], @intCast(width), .big);
    std.mem.writeInt(u16, msg[2..4], @intCast(height), .big);
    rfb.PixelFormat.native.encode(msg[4..20]);
    std.mem.writeInt(u32, msg[20..24], name.len, .big);
    @memcpy(msg[24..], name);
    queue(c, &msg);
}

fn pointer(c: *Client, mask: u8, x: u16, y: u16) void {
    const ax: i32 = @intCast(@min(@as(u64, x) * (inp.ABS_MAX + 1) / width, inp.ABS_MAX));
    const ay: i32 = @intCast(@min(@as(u64, y) * (inp.ABS_MAX + 1) / height, inp.ABS_MAX));
    pushEvent(inp.EV_ABS, inp.ABS_X, ax);
    pushEvent(inp.EV_ABS, inp.ABS_Y, ay);
    const changed = mask ^ c.buttons;
    const buttons = [_]struct { u8, u16 }{ .{ 1, inp.BTN_LEFT }, .{ 2, inp.BTN_MIDDLE }, .{ 4, inp.BTN_RIGHT } };
    for (buttons) |b| if (changed & b[0] != 0) pushEvent(inp.EV_KEY, b[1], @intFromBool(mask & b[0] != 0));
    const pressed = changed & mask;
    if (pressed & 8 != 0) pushEvent(inp.EV_REL, inp.REL_WHEEL, 1);
    if (pressed & 16 != 0) pushEvent(inp.EV_REL, inp.REL_WHEEL, -1);
    if (pressed & 32 != 0) pushEvent(inp.EV_REL, inp.REL_HWHEEL, -1);
    if (pressed & 64 != 0) pushEvent(inp.EV_REL, inp.REL_HWHEEL, 1);
    c.buttons = mask;
    syn();
}

fn sendKey(code: u16, down: bool) void {
    if (code == 0) return;
    pushEvent(inp.EV_KEY, code, @intFromBool(down));
    syn();
}

/// The clipboard is exchanged with the window server from a separate
/// thread: the window server itself waits on vncd (display writes), so a
/// synchronous call from the main loop could deadlock.
const Clip = struct {
    var mutex: std.Thread.Mutex = .{};
    var cond: std.Thread.Condition = .{};
    /// Text from a viewer, to put on the Zen clipboard.
    var outgoing: ?[]u8 = null;
    /// New Zen clipboard text for the viewers.
    var incoming: ?[]u8 = null;
    var viewers = std.atomic.Value(u32).init(0);
    var wake: [2]posix.fd_t = .{ -1, -1 };

    fn start() void {
        wake = posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) catch return;
        const t = std.Thread.spawn(.{}, run, .{}) catch return;
        t.detach();
    }

    fn set(text: []const u8) void {
        const copy = gpa.dupe(u8, text) catch return;
        mutex.lock();
        defer mutex.unlock();
        if (outgoing) |o| gpa.free(o);
        outgoing = copy;
        cond.signal();
    }

    fn take() ?[]u8 {
        var junk: [64]u8 = undefined;
        while (true) _ = posix.read(wake[0], &junk) catch break;
        mutex.lock();
        defer mutex.unlock();
        const t = incoming;
        incoming = null;
        return t;
    }

    fn run() void {
        var last: std.ArrayList(u8) = .empty;
        while (true) {
            mutex.lock();
            if (outgoing == null) cond.timedWait(&mutex, 700 * std.time.ns_per_ms) catch {};
            const out = outgoing;
            outgoing = null;
            mutex.unlock();
            if (out) |text| {
                defer gpa.free(text);
                writeClipboard(text, &last);
                continue;
            }
            if (viewers.load(.acquire) == 0) continue;
            const text = zen.io.readUrl(gpa, "window:clipboard", 1 << 20) catch continue;
            if (std.mem.eql(u8, text, last.items)) {
                gpa.free(text);
                continue;
            }
            last.clearRetainingCapacity();
            last.appendSlice(gpa, text) catch {};
            mutex.lock();
            if (incoming) |old| gpa.free(old);
            incoming = text;
            mutex.unlock();
            _ = posix.write(wake[1], "x") catch {};
        }
    }

    fn writeClipboard(text: []const u8, last: *std.ArrayList(u8)) void {
        // RFB text is Latin-1; the web client sends UTF-8. Convert when needed.
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        var utf8 = text;
        if (!std.unicode.utf8ValidateSlice(text)) {
            var list: std.ArrayList(u8) = .empty;
            for (text) |ch| {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &b) catch continue;
                list.appendSlice(gpa, b[0..n]) catch break;
            }
            owned = list.toOwnedSlice(gpa) catch null;
            utf8 = owned orelse return;
        }
        const fd = zen.io.open("window:clipboard", .{ .ACCMODE = .WRONLY, .TRUNC = true }, 0) catch return;
        defer zen.io.close(fd);
        zen.io.writeAll(fd, utf8) catch {};
        last.clearRetainingCapacity();
        last.appendSlice(gpa, utf8) catch {};
    }
};

/// Parse RFB messages from `c.rin`.
fn handleRfb(c: *Client) void {
    while (!c.dead) {
        const b = c.rin.items;
        const used: usize = switch (c.state) {
            .http => return,
            .version => blk: {
                if (b.len < 12) return;
                if (!std.mem.startsWith(u8, b, "RFB 003.")) {
                    c.dead = true;
                    return;
                }
                c.minor = std.fmt.parseInt(u8, b[8..11], 10) catch 3;
                if (c.minor < 7) {
                    // RFB 3.3: the server picks "None".
                    var m: [4]u8 = undefined;
                    std.mem.writeInt(u32, &m, 1, .big);
                    queue(c, &m);
                    c.state = .client_init;
                } else {
                    queue(c, &.{ 1, 1 });
                    c.state = .security;
                }
                break :blk 12;
            },
            .security => blk: {
                if (b.len < 1) return;
                if (b[0] != 1) {
                    c.dead = true;
                    return;
                }
                if (c.minor >= 8) queue(c, &.{ 0, 0, 0, 0 });
                c.state = .client_init;
                break :blk 1;
            },
            .client_init => blk: {
                if (b.len < 1) return;
                sendServerInit(c);
                c.state = .normal;
                break :blk 1;
            },
            .normal => blk: {
                if (b.len < 1) return;
                switch (b[0]) {
                    0 => { // SetPixelFormat
                        if (b.len < 20) return;
                        const pf = rfb.PixelFormat.decode(b[4..20]);
                        if (!pf.valid()) {
                            c.dead = true;
                            return;
                        }
                        c.pf = pf;
                        c.full = true;
                        c.cursor_sent = 0;
                        break :blk 20;
                    },
                    2 => { // SetEncodings
                        if (b.len < 4) return;
                        const count = std.mem.readInt(u16, b[2..4], .big);
                        const total = 4 + @as(usize, count) * 4;
                        if (b.len < total) return;
                        c.enc_cursor = false;
                        c.enc_extkey = false;
                        c.enc_deflate = false;
                        for (0..count) |i| {
                            const e = std.mem.readInt(i32, b[4 + i * 4 ..][0..4], .big);
                            if (e == -239) c.enc_cursor = true;
                            if (e == -258) c.enc_extkey = true;
                            if (e == enc_zen_deflate) c.enc_deflate = true;
                        }
                        c.cursor_sent = 0;
                        break :blk total;
                    },
                    3 => { // FramebufferUpdateRequest
                        if (b.len < 10) return;
                        const r = Rect.clipped(std.mem.readInt(u16, b[2..4], .big), std.mem.readInt(u16, b[4..6], .big), std.mem.readInt(u16, b[6..8], .big), std.mem.readInt(u16, b[8..10], .big));
                        if (b[1] == 0) c.full = true;
                        c.req = if (c.want_update) c.req.unite(r) else r;
                        c.want_update = true;
                        break :blk 10;
                    },
                    4 => { // KeyEvent
                        if (b.len < 8) return;
                        sendKey(rfb.keysymToEvdev(std.mem.readInt(u32, b[4..8], .big)), b[1] != 0);
                        break :blk 8;
                    },
                    5 => { // PointerEvent
                        if (b.len < 6) return;
                        pointer(c, b[1], std.mem.readInt(u16, b[2..4], .big), std.mem.readInt(u16, b[4..6], .big));
                        break :blk 6;
                    },
                    6 => { // ClientCutText
                        if (b.len < 8) return;
                        const len = std.mem.readInt(u32, b[4..8], .big);
                        if (len > 4 << 20) {
                            c.dead = true; // extended clipboard is not supported
                            return;
                        }
                        if (b.len < 8 + len) return;
                        Clip.set(b[8 .. 8 + len]);
                        break :blk 8 + len;
                    },
                    150 => { // EnableContinuousUpdates (not offered; ignore)
                        if (b.len < 10) return;
                        break :blk 10;
                    },
                    255 => { // QEMU client message
                        if (b.len < 2) return;
                        if (b[1] != 0) {
                            c.dead = true;
                            return;
                        }
                        if (b.len < 12) return;
                        const down = std.mem.readInt(u16, b[2..4], .big) != 0;
                        const ks = std.mem.readInt(u32, b[4..8], .big);
                        const qnum = std.mem.readInt(u32, b[8..12], .big);
                        const code = rfb.qnumToEvdev(qnum);
                        sendKey(if (code != 0) code else rfb.keysymToEvdev(ks), down);
                        break :blk 12;
                    },
                    else => {
                        c.dead = true;
                        return;
                    },
                }
            },
        };
        c.rin.replaceRange(gpa, 0, used, &.{}) catch {};
    }
}

fn clientInput(c: *Client) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(c.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                c.dead = true;
                return;
            },
        };
        if (n == 0) {
            c.dead = true;
            return;
        }
        c.raw.appendSlice(gpa, buf[0..n]) catch return;
        if (n < buf.len) break;
    }
    if (c.state == .http) {
        handleHttp(c);
        if (c.state == .http) return;
    }
    if (c.ws) {
        const r = rfb.WsDecoder.decode(c.raw.items, &c.rin, gpa) catch {
            c.dead = true;
            return;
        };
        c.raw.replaceRange(gpa, 0, r.consumed, &.{}) catch {};
        switch (r.event) {
            .close => {
                queueRaw(c, &.{ 0x88, 0x00 });
                c.closing = true;
                return;
            },
            .ping => {
                queueRaw(c, &.{ 0x8A, @intCast(r.ping_len) });
                queueRaw(c, r.ping_payload[0..r.ping_len]);
            },
            .none => {},
        }
    } else {
        c.rin.appendSlice(gpa, c.raw.items) catch {};
        c.raw.clearRetainingCapacity();
    }
    handleRfb(c);
}

// --- Framebuffer updates -----------------------------------------------------

/// Blend the cursor into a row copy (for viewers without a local cursor).
fn overlayCursor(row: []u32, y: u32, x0: u32) void {
    if (!cursor.visible) return;
    const cy = @as(i64, cursor.y) - cursor.hot_y;
    const cx = @as(i64, cursor.x) - cursor.hot_x;
    const iy = @as(i64, y) - cy;
    if (iy < 0 or iy >= CUR) return;
    for (row, 0..) |*p, i| {
        const ix = @as(i64, x0) + @as(i64, @intCast(i)) - cx;
        if (ix < 0 or ix >= CUR) continue;
        const s = cursor_img[@intCast(iy * CUR + ix)];
        const a = s >> 24;
        if (a == 0) continue;
        if (a == 255) {
            p.* = s;
            continue;
        }
        var out: u32 = 0xFF000000;
        inline for (.{ 0, 8, 16 }) |sh| {
            const sv = (s >> sh) & 0xFF;
            const dv = (p.* >> sh) & 0xFF;
            out |= ((sv * a + dv * (255 - a)) / 255) << sh;
        }
        p.* = out;
    }
}

fn rectHeader(msg: *std.ArrayList(u8), x: u32, y: u32, w: u32, h: u32, enc: i32) void {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], @intCast(x), .big);
    std.mem.writeInt(u16, hdr[2..4], @intCast(y), .big);
    std.mem.writeInt(u16, hdr[4..6], @intCast(w), .big);
    std.mem.writeInt(u16, hdr[6..8], @intCast(h), .big);
    std.mem.writeInt(i32, hdr[8..12], enc, .big);
    msg.appendSlice(gpa, &hdr) catch {};
}

var row_tmp: std.ArrayList(u32) = .empty;

fn maybeUpdate(c: *Client) void {
    if (c.state != .normal or !c.want_update or c.pending() > 0) return;
    var region: Rect = .{};
    if (c.full) region = c.req else region = c.dirty.intersect(c.req);
    const send_cursor = c.enc_cursor and c.cursor_sent != cursor.serial;
    const send_extkey = c.enc_extkey and !c.extkey_acked;
    var nrects: u16 = 0;
    if (!region.empty()) nrects += 1;
    if (send_cursor) nrects += 1;
    if (send_extkey) nrects += 1;
    if (nrects == 0) return;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const bpp = c.pf.bytesPerPixel();
    msg.ensureTotalCapacity(gpa, 16 + @as(usize, region.w) * region.h * bpp + 64 * 64 * 5) catch return;
    msg.appendSlice(gpa, &.{ 0, 0 }) catch return;
    var nb: [2]u8 = undefined;
    std.mem.writeInt(u16, &nb, nrects, .big);
    msg.appendSlice(gpa, &nb) catch return;

    if (send_extkey) {
        rectHeader(&msg, 0, 0, 0, 0, -258);
        c.extkey_acked = true;
    }
    if (send_cursor) {
        if (cursor.visible) {
            rectHeader(&msg, cursor.hot_x, cursor.hot_y, CUR, CUR, -239);
            rfb.encodeCursor(c.pf, cursor_img, CUR, CUR, &msg, gpa) catch {};
        } else {
            rectHeader(&msg, 0, 0, 0, 0, -239);
        }
        c.cursor_sent = cursor.serial;
    }
    if (!region.empty()) {
        const hdr_at = msg.items.len;
        rectHeader(&msg, region.x, region.y, region.w, region.h, 0);
        const start = msg.items.len;
        const row_bytes = @as(usize, region.w) * bpp;
        msg.resize(gpa, start + row_bytes * region.h) catch return;
        row_tmp.resize(gpa, region.w) catch return;
        const soft_cursor = !c.enc_cursor and cursor.visible;
        for (0..region.h) |i| {
            const y = region.y + @as(u32, @intCast(i));
            var src: []const u32 = fb[@as(usize, y) * width + region.x ..][0..region.w];
            if (soft_cursor) {
                @memcpy(row_tmp.items, src);
                overlayCursor(row_tmp.items, y, region.x);
                src = row_tmp.items;
            }
            c.pf.convertRow(src, msg.items[start + i * row_bytes ..][0..row_bytes]);
        }
        // Compress for viewers that asked for it, when it pays off.
        if (c.enc_deflate and row_bytes * region.h >= 1024) compressRect(&msg, hdr_at, start);
    }
    queue(c, msg.items);
    c.want_update = false;
    c.full = false;
    c.dirty = .{};
}

var compressor: ?deflate.Compressor = null;
var packed_buf: std.ArrayList(u8) = .empty;

/// Replace the raw pixels at msg[start..] with the private deflate encoding
/// (keeping raw when compression does not help).
fn compressRect(msg: *std.ArrayList(u8), hdr_at: usize, start: usize) void {
    if (compressor == null) compressor = deflate.Compressor.init(gpa) catch return;
    const raw = msg.items[start..];
    packed_buf.clearRetainingCapacity();
    compressor.?.compress(gpa, raw, &packed_buf) catch return;
    if (packed_buf.items.len + 4 >= raw.len - raw.len / 10) return;
    std.mem.writeInt(i32, msg.items[hdr_at + 8 ..][0..4], enc_zen_deflate, .big);
    msg.shrinkRetainingCapacity(start);
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, @intCast(packed_buf.items.len), .big);
    // The raw pixels were larger, so the capacity is already there.
    msg.appendSliceAssumeCapacity(&lb);
    msg.appendSliceAssumeCapacity(packed_buf.items);
}

/// Forward new Zen clipboard text (from the Clip thread) to the viewers.
fn forwardClipboard() void {
    const text = Clip.take() orelse return;
    defer gpa.free(text);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    msg.appendSlice(gpa, &.{ 3, 0, 0, 0 }) catch return;
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, @intCast(text.len), .big);
    msg.appendSlice(gpa, &lb) catch return;
    msg.appendSlice(gpa, text) catch return;
    for (clients.items) |c| if (c.state == .normal) queue(c, msg.items);
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

fn envInt(name: []const u8, default: u16) u16 {
    const v = posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, v, 10) catch default;
}

fn listenTcp(bind: []const u8, port: u16) !posix.fd_t {
    const addr = try std.net.Address.parseIp(bind, port);
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 16);
    return fd;
}

fn acceptClients(lfd: posix.fd_t, http: bool) void {
    while (true) {
        const fd = posix.accept(lfd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return;
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        const c = gpa.create(Client) catch {
            posix.close(fd);
            return;
        };
        c.* = .{ .fd = fd, .state = if (http) .http else .version };
        if (!http) startRfb(c);
        c.dirty = screen();
        clients.append(gpa, c) catch {
            c.deinit();
            gpa.destroy(c);
            return;
        };
    }
}

pub fn main() !void {
    zen.sys.setName("vncd");
    if (posix.getenv("ZEN_HOSTED_SIZE")) |s| {
        if (std.mem.indexOfScalar(u8, s, 'x')) |x| {
            width = std.math.clamp(std.fmt.parseInt(u32, s[0..x], 10) catch width, 640, 4096);
            height = std.math.clamp(std.fmt.parseInt(u32, s[x + 1 ..], 10) catch height, 480, 4096);
        }
    }
    fb_mem = try zen.shm.allocate(@as(usize, width) * height * 4);
    fb = @as([*]u32, @ptrCast(fb_mem.ptr))[0 .. @as(usize, width) * height];
    @memset(fb, 0xFF101014);
    cursor_mem = try zen.shm.allocate(CUR * CUR * 4);
    cursor_img = @as([*]u32, @ptrCast(cursor_mem.ptr))[0 .. CUR * CUR];

    const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &ign, null);

    const bind = posix.getenv("ZEN_HOSTED_BIND") orelse "127.0.0.1";
    const http_port = envInt("ZEN_HOSTED_HTTP", 6080);
    const vnc_port = envInt("ZEN_HOSTED_VNC", 5900);
    const http_fd: posix.fd_t = if (http_port != 0) listenTcp(bind, http_port) catch |err| blk: {
        zen.sys.logf("vncd: cannot listen on {s}:{d}: {s}", .{ bind, http_port, @errorName(err) });
        break :blk -1;
    } else -1;
    const vnc_fd: posix.fd_t = if (vnc_port != 0) listenTcp(bind, vnc_port) catch |err| blk: {
        zen.sys.logf("vncd: cannot listen on {s}:{d}: {s}", .{ bind, vnc_port, @errorName(err) });
        break :blk -1;
    } else -1;

    display_srv = try zen.server.Server.register(gpa, "display");
    input_srv = try zen.server.Server.register(gpa, "input");
    zen.sys.logf("vncd: {d}x{d} — open http://{s}:{d} in a browser{s}", .{ width, height, if (std.mem.eql(u8, bind, "0.0.0.0")) "localhost" else bind, http_port, if (vnc_fd >= 0) " (or a VNC viewer)" else "" });

    Clip.start();
    const fixed = 5;
    var pfds: std.ArrayList(posix.pollfd) = .empty;
    while (true) {
        pfds.clearRetainingCapacity();
        try pfds.append(gpa, .{ .fd = display_srv.fd, .events = posix.POLL.IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = input_srv.fd, .events = posix.POLL.IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = http_fd, .events = posix.POLL.IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = vnc_fd, .events = posix.POLL.IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = Clip.wake[0], .events = posix.POLL.IN, .revents = 0 });
        for (clients.items) |c| {
            const out: i16 = if (c.pending() > 0) posix.POLL.OUT else 0;
            try pfds.append(gpa, .{ .fd = c.fd, .events = posix.POLL.IN | out, .revents = 0 });
        }
        _ = posix.poll(pfds.items, 250) catch 0;

        while (display_srv.receive()) |in| serveDisplay(in) else |_| {}
        while (input_srv.receive()) |in| serveInput(in) else |_| {}
        if (pfds.items[2].revents != 0) acceptClients(http_fd, true);
        if (pfds.items[3].revents != 0) acceptClients(vnc_fd, false);

        const n_old = pfds.items.len - fixed;
        for (clients.items[0..@min(n_old, clients.items.len)], 0..) |c, i| {
            const re = pfds.items[fixed + i].revents;
            if (re & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) clientInput(c);
        }
        if (pfds.items[4].revents != 0) forwardClipboard();
        var viewing: u32 = 0;
        for (clients.items) |c| {
            if (c.state == .normal) viewing += 1;
        }
        Clip.viewers.store(viewing, .release);
        var i: usize = 0;
        while (i < clients.items.len) {
            const c = clients.items[i];
            if (!c.dead) {
                maybeUpdate(c);
                flushOut(c);
            }
            if (c.dead) {
                c.deinit();
                gpa.destroy(c);
                _ = clients.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
}
