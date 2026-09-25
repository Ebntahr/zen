//! fsd — ext2 file server. Serves the root file system as `file:`.
//! Usage: fsd <block-device-url> [scheme]

const std = @import("std");
const zen = @import("zen");
const ext2 = @import("ext2");
const service = @import("service.zig");

const posix = std.posix;

var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
const gpa = gpa_state.allocator();

/// Block device backed by a `disk:` handle.
const DiskDevice = struct {
    fd: posix.fd_t,
    size_bytes: u64,

    fn read(ptr: *anyopaque, offset: u64, buf: []u8) ext2.BlockDevice.Error!void {
        const self: *DiskDevice = @ptrCast(@alignCast(ptr));
        var done: usize = 0;
        while (done < buf.len) {
            const n = posix.pread(self.fd, buf[done..], offset + done) catch return error.Io;
            if (n == 0) return error.Io;
            done += n;
        }
    }

    fn write(ptr: *anyopaque, offset: u64, buf: []const u8) ext2.BlockDevice.Error!void {
        const self: *DiskDevice = @ptrCast(@alignCast(ptr));
        var done: usize = 0;
        while (done < buf.len) {
            const n = posix.pwrite(self.fd, buf[done..], offset + done) catch return error.Io;
            if (n == 0) return error.Io;
            done += n;
        }
    }

    fn flush(ptr: *anyopaque) ext2.BlockDevice.Error!void {
        const self: *DiskDevice = @ptrCast(@alignCast(ptr));
        posix.fsync(self.fd) catch return error.Io;
    }

    fn size(ptr: *anyopaque) u64 {
        const self: *DiskDevice = @ptrCast(@alignCast(ptr));
        return self.size_bytes;
    }

    const vtable = ext2.BlockDevice.VTable{ .read = read, .write = write, .flush = flush, .size = size };

    fn device(self: *DiskDevice) ext2.BlockDevice {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn wallClock() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

var srv: zen.server.Server = undefined;

fn replyFn(_: *anyopaque, id: u64, result: i64, data: []const u8) void {
    srv.reply(id, result, data) catch {};
}

pub fn main() !void {
    zen.sys.setName("fsd");
    const args = try std.process.argsAlloc(gpa);
    const dev_url = if (args.len > 1) args[1] else "disk:";
    const scheme = if (args.len > 2) args[2] else "file";

    const fd = try posix.open(dev_url, .{ .ACCMODE = .RDWR }, 0);
    const st = try posix.fstat(fd);
    var disk = DiskDevice{ .fd = fd, .size_bytes = @intCast(st.size) };

    const fs = ext2.Fs.mount(gpa, disk.device(), .{ .cache_blocks = 4096, .inode_cache = 1024, .now = wallClock }) catch |err| {
        zen.sys.logf("fsd: cannot mount {s}: {s}", .{ dev_url, @errorName(err) });
        return err;
    };
    var svc = try service.Service.init(gpa, fs);
    const s = fs.statfs();
    zen.sys.logf("fsd: mounted {s} as {s}: ({d} MiB, {d} MiB free)", .{ dev_url, scheme, s.total_blocks * s.block_size >> 20, s.free_blocks * s.block_size >> 20 });

    srv = try zen.server.Server.register(gpa, scheme);
    var dummy: u8 = 0;
    const out = service.Responder{ .ptr = &dummy, .replyFn = replyFn };
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 2000) catch 0;
        if (ready == 0) {
            // Idle: write back dirty blocks.
            svc.syncIfDirty();
            continue;
        }
        const in = srv.receive() catch continue;
        svc.handle(in.req, in.payload, out);
    }
}
