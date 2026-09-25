//! Host tool: pack files into a Zen boot archive.
//! Usage: mkinitfs <out> <archive-path>=<host-file> ...

const std = @import("std");
const abi = @import("abi");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) {
        std.debug.print("usage: mkinitfs <out> <name>=<file>...\n", .{});
        std.process.exit(2);
    }
    var b = abi.initfs.Builder.init(a);
    for (args[2..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
            std.debug.print("mkinitfs: bad spec {s}\n", .{spec});
            std.process.exit(2);
        };
        const data = try std.fs.cwd().readFileAlloc(a, spec[eq + 1 ..], 256 << 20);
        const st = try std.fs.cwd().statFile(spec[eq + 1 ..]);
        try b.add(spec[0..eq], @intCast(st.mode & 0o7777), data);
    }
    const img = try b.encode();
    try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = img });
}
