//! virtio-gpu 2D driver: serves the `display:` scheme.
//! Usage: virtio-gpud <mmio-phys> <irq>
//!
//!   display:0          framebuffer (read → Info, mmap, write []Rect)
//!   display:0/cursor   64×64 hardware cursor (mmap, write CursorCmd)

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");
const virtio = @import("virtio");

const sc = abi.scheme;
const disp = abi.display;

// Commands
const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const CMD_UPDATE_CURSOR: u32 = 0x0300;
const CMD_MOVE_CURSOR: u32 = 0x0301;
const RESP_OK_NODATA: u32 = 0x1100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;

const FORMAT_B8G8R8A8: u32 = 1;
const FORMAT_B8G8R8X8: u32 = 2;

const FB_RESOURCE: u32 = 1;
const CURSOR_RESOURCE: u32 = 2;

const Hdr = extern struct {
    kind: u32,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    ring_idx: u8 = 0,
    padding: [3]u8 = .{ 0, 0, 0 },
};

const GpuRect = extern struct { x: u32, y: u32, w: u32, h: u32 };

const DisplayOne = extern struct { r: GpuRect, enabled: u32, flags: u32 };
const RespDisplayInfo = extern struct { hdr: Hdr, pmodes: [16]DisplayOne };

const ResourceCreate2d = extern struct { hdr: Hdr, resource_id: u32, format: u32, width: u32, height: u32 };
const SetScanout = extern struct { hdr: Hdr, r: GpuRect, scanout_id: u32, resource_id: u32 };
const ResourceFlush = extern struct { hdr: Hdr, r: GpuRect, resource_id: u32, padding: u32 = 0 };
const TransferToHost2d = extern struct { hdr: Hdr, r: GpuRect, offset: u64, resource_id: u32, padding: u32 = 0 };
const MemEntry = extern struct { addr: u64, length: u32, padding: u32 = 0 };
const AttachBacking = extern struct { hdr: Hdr, resource_id: u32, nr_entries: u32, entry: MemEntry };
const CursorPos = extern struct { scanout_id: u32, x: u32, y: u32, padding: u32 = 0 };
const UpdateCursor = extern struct { hdr: Hdr, pos: CursorPos, resource_id: u32, hot_x: u32, hot_y: u32, padding: u32 = 0 };

var dev: virtio.Device = undefined;
var ctrlq: virtio.Queue = undefined;
var cursorq: virtio.Queue = undefined;
var irq: virtio.Irq = undefined;

/// Command slots: each slot holds a request (≤ 512 B) and a response.
const SLOT = 1024;
const NSLOTS = 32;
var cmd_mem: zen.sys.DmaBuffer = undefined;

var fb: zen.sys.DmaBuffer = undefined;
var cursor_img: zen.sys.DmaBuffer = undefined;
var width: u32 = 1280;
var height: u32 = 800;

fn slotPtr(i: usize) [*]u8 {
    return cmd_mem.virt + i * SLOT;
}

fn slotPhys(i: usize) u64 {
    return cmd_mem.phys + i * SLOT;
}

/// Submit several requests (one per slot) and wait until all complete.
fn run(q: *virtio.Queue, reqs: []const []const u8, resp_len: u32) !void {
    var outstanding: usize = 0;
    for (reqs, 0..) |r, i| {
        @memcpy(slotPtr(i)[0..r.len], r);
        const bufs = [_]virtio.Queue.Buf{
            .{ .phys = slotPhys(i), .len = @intCast(r.len), .writable = false },
            .{ .phys = slotPhys(i) + 512, .len = resp_len, .writable = true },
        };
        _ = q.submit(&bufs) orelse return error.QueueFull;
        outstanding += 1;
    }
    q.kick();
    while (outstanding > 0) {
        while (q.popUsed()) |_| outstanding -= 1;
        if (outstanding == 0) break;
        const c = try irq.wait();
        _ = dev.ackInterrupt();
        irq.ack(c);
    }
    for (reqs, 0..) |_, i| {
        const resp: *const Hdr = @ptrCast(@alignCast(slotPtr(i) + 512));
        if (resp.kind != RESP_OK_NODATA and resp.kind != RESP_OK_DISPLAY_INFO) return error.GpuError;
    }
}

fn run1(q: *virtio.Queue, req: anytype, resp_len: u32) !void {
    const bytes = std.mem.asBytes(req);
    try run(q, &.{bytes}, resp_len);
}

fn queryDisplay() !void {
    const req = Hdr{ .kind = CMD_GET_DISPLAY_INFO };
    try run1(&ctrlq, &req, @sizeOf(RespDisplayInfo));
    const resp: *const RespDisplayInfo = @ptrCast(@alignCast(slotPtr(0) + 512));
    if (resp.pmodes[0].enabled != 0 and resp.pmodes[0].r.w > 0) {
        width = resp.pmodes[0].r.w;
        height = resp.pmodes[0].r.h;
    }
}

fn setupFramebuffer() !void {
    fb = try zen.sys.physalloc(@as(usize, width) * height * 4);
    const create = ResourceCreate2d{ .hdr = .{ .kind = CMD_RESOURCE_CREATE_2D }, .resource_id = FB_RESOURCE, .format = FORMAT_B8G8R8X8, .width = width, .height = height };
    try run1(&ctrlq, &create, @sizeOf(Hdr));
    const attach = AttachBacking{ .hdr = .{ .kind = CMD_RESOURCE_ATTACH_BACKING }, .resource_id = FB_RESOURCE, .nr_entries = 1, .entry = .{ .addr = fb.phys, .length = @intCast(fb.len) } };
    try run1(&ctrlq, &attach, @sizeOf(Hdr));
    const scanout = SetScanout{ .hdr = .{ .kind = CMD_SET_SCANOUT }, .r = .{ .x = 0, .y = 0, .w = width, .h = height }, .scanout_id = 0, .resource_id = FB_RESOURCE };
    try run1(&ctrlq, &scanout, @sizeOf(Hdr));
}

fn setupCursor() !void {
    const n = disp.CURSOR_SIZE;
    cursor_img = try zen.sys.physalloc(@as(usize, n) * n * 4);
    const create = ResourceCreate2d{ .hdr = .{ .kind = CMD_RESOURCE_CREATE_2D }, .resource_id = CURSOR_RESOURCE, .format = FORMAT_B8G8R8A8, .width = n, .height = n };
    try run1(&ctrlq, &create, @sizeOf(Hdr));
    const attach = AttachBacking{ .hdr = .{ .kind = CMD_RESOURCE_ATTACH_BACKING }, .resource_id = CURSOR_RESOURCE, .nr_entries = 1, .entry = .{ .addr = cursor_img.phys, .length = @intCast(cursor_img.len) } };
    try run1(&ctrlq, &attach, @sizeOf(Hdr));
}

/// Copy rectangles of the framebuffer to the host and flush them.
fn present(rects: []const disp.Rect) !void {
    var reqs: [NSLOTS][]const u8 = undefined;
    var storage_t: [NSLOTS / 2]TransferToHost2d = undefined;
    var storage_f: [NSLOTS / 2]ResourceFlush = undefined;
    var i: usize = 0;
    while (i < rects.len) {
        const batch = @min(rects.len - i, NSLOTS / 2);
        var n: usize = 0;
        for (rects[i .. i + batch], 0..) |r, k| {
            const x = @min(r.x, width);
            const y = @min(r.y, height);
            const w = @min(r.w, width - x);
            const h = @min(r.h, height - y);
            const gr = GpuRect{ .x = x, .y = y, .w = w, .h = h };
            storage_t[k] = .{ .hdr = .{ .kind = CMD_TRANSFER_TO_HOST_2D }, .r = gr, .offset = (@as(u64, y) * width + x) * 4, .resource_id = FB_RESOURCE };
            reqs[n] = std.mem.asBytes(&storage_t[k]);
            n += 1;
        }
        for (rects[i .. i + batch], 0..) |_, k| {
            storage_f[k] = .{ .hdr = .{ .kind = CMD_RESOURCE_FLUSH }, .r = storage_t[k].r, .resource_id = FB_RESOURCE };
            reqs[n] = std.mem.asBytes(&storage_f[k]);
            n += 1;
        }
        try run(&ctrlq, reqs[0..n], @sizeOf(Hdr));
        i += batch;
    }
}

fn cursorCommand(cmd: disp.CursorCmd) !void {
    if (cmd.update_image != 0) {
        const n = disp.CURSOR_SIZE;
        const t = TransferToHost2d{ .hdr = .{ .kind = CMD_TRANSFER_TO_HOST_2D }, .r = .{ .x = 0, .y = 0, .w = n, .h = n }, .offset = 0, .resource_id = CURSOR_RESOURCE };
        try run1(&ctrlq, &t, @sizeOf(Hdr));
    }
    const x: u32 = @intCast(std.math.clamp(cmd.x, 0, @as(i32, @intCast(width)) - 1));
    const y: u32 = @intCast(std.math.clamp(cmd.y, 0, @as(i32, @intCast(height)) - 1));
    const uc = UpdateCursor{
        .hdr = .{ .kind = if (cmd.update_image != 0) CMD_UPDATE_CURSOR else CMD_MOVE_CURSOR },
        .pos = .{ .scanout_id = 0, .x = x, .y = y },
        .resource_id = if (cmd.visible != 0) CURSOR_RESOURCE else 0,
        .hot_x = cmd.hot_x,
        .hot_y = cmd.hot_y,
    };
    try run1(&cursorq, &uc, @sizeOf(Hdr));
}

const Kind = enum { framebuffer, cursor };
const Handle = struct { kind: Kind, info_sent: bool = false };

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();
var handles: zen.server.HandleTable(Handle) = .{};
var srv: zen.server.Server = undefined;

fn info() disp.Info {
    return .{ .width = width, .height = height, .stride = width * 4 };
}

fn serve(in: zen.server.Incoming) !void {
    const req = in.req;
    switch (req.op) {
        .open => {
            if (req.uid != 0) return srv.replyError(req.id, .ACCES);
            const path = std.mem.trim(u8, in.payload, "/");
            const kind: Kind = if (std.mem.eql(u8, path, "0/cursor") or std.mem.eql(u8, path, "cursor"))
                .cursor
            else if (path.len == 0 or std.mem.eql(u8, path, "0"))
                .framebuffer
            else
                return srv.replyError(req.id, .NOENT);
            const id = try handles.insert(gpa, .{ .kind = kind });
            return srv.replyValue(req.id, id);
        },
        .cancel => return,
        else => {},
    }
    const h = handles.get(req.handle) orelse return srv.replyError(req.id, .BADF);
    switch (req.op) {
        .close => _ = handles.remove(gpa, req.handle),
        .read => {
            // Mode changes are not reported yet: later reads never complete.
            if (h.info_sent) return;
            h.info_sent = true;
            const i = info();
            try srv.reply(req.id, @sizeOf(disp.Info), std.mem.asBytes(&i));
        },
        .write => switch (h.kind) {
            .framebuffer => {
                const count = in.payload.len / @sizeOf(disp.Rect);
                const rects: []align(1) const disp.Rect = std.mem.bytesAsSlice(disp.Rect, in.payload[0 .. count * @sizeOf(disp.Rect)]);
                var local: [64]disp.Rect = undefined;
                var done: usize = 0;
                while (done < rects.len) {
                    const n = @min(rects.len - done, local.len);
                    for (0..n) |k| local[k] = rects[done + k];
                    present(local[0..n]) catch return srv.replyError(req.id, .IO);
                    done += n;
                }
                try srv.replyValue(req.id, in.payload.len);
            },
            .cursor => {
                if (in.payload.len < @sizeOf(disp.CursorCmd)) return srv.replyError(req.id, .INVAL);
                var cmd: disp.CursorCmd = undefined;
                @memcpy(std.mem.asBytes(&cmd), in.payload[0..@sizeOf(disp.CursorCmd)]);
                cursorCommand(cmd) catch return srv.replyError(req.id, .IO);
                try srv.replyValue(req.id, in.payload.len);
            },
        },
        .fmap => {
            const buf = switch (h.kind) {
                .framebuffer => fb,
                .cursor => cursor_img,
            };
            if (req.arg0 + req.arg1 > std.mem.alignForward(usize, buf.len, 4096)) return srv.replyError(req.id, .INVAL);
            try srv.replyValue(req.id, @intFromPtr(buf.virt) + req.arg0);
        },
        .funmap => {},
        .fstat => {
            const st = sc.Stat{ .mode = sc.S_IFCHR | 0o600, .size = @intCast(fb.len) };
            try srv.replyStruct(req.id, &st);
        },
        .fevent => {
            var ev: u32 = sc.POLLOUT;
            if (!h.info_sent) ev |= sc.POLLIN;
            if (ev & @as(u32, @truncate(req.arg0)) != 0) try srv.replyValue(req.id, ev);
        },
        .fpath => try srv.reply(req.id, 1, "0"),
        else => try srv.replyError(req.id, .NOSYS),
    }
}

pub fn main() !void {
    zen.sys.setName("virtio-gpud");
    const args = try std.process.argsAlloc(gpa);
    const loc = virtio.parseArgs(args) orelse return error.InvalidArgument;

    dev = try virtio.Device.open(loc.phys, .gpu);
    _ = try dev.init(0);
    ctrlq = try virtio.Queue.init(dev, 0, 64);
    cursorq = try virtio.Queue.init(dev, 1, 16);
    cmd_mem = try zen.sys.physalloc(SLOT * NSLOTS);
    irq = try virtio.Irq.open(loc.irq);
    dev.driverOk();

    try queryDisplay();
    try setupFramebuffer();
    try setupCursor();
    // Start with a dark screen.
    @memset(@as([*]u32, @ptrCast(@alignCast(fb.virt)))[0 .. @as(usize, width) * height], 0xff101018);
    try present(&.{.{ .x = 0, .y = 0, .w = width, .h = height }});

    srv = try zen.server.Server.register(gpa, "display");
    zen.sys.logf("virtio-gpud: display:0 {d}x{d}", .{ width, height });
    while (true) {
        const in = srv.receive() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        serve(in) catch |err| {
            srv.replyError(in.req.id, zen.server.errnoFor(err)) catch {};
        };
    }
}
