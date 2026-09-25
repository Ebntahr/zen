//! Host tool: write an /etc/shadow with Argon2id password hashes.
//! Usage: mkshadow <out> <user>:<password> ...   (empty password = locked)

const std = @import("std");
const zen = @import("zen");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) {
        std.debug.print("usage: mkshadow <out> <user>:<password>...\n", .{});
        std.process.exit(2);
    }
    var out: std.ArrayList(u8) = .empty;
    for (args[2..]) |spec| {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse {
            std.debug.print("mkshadow: bad spec {s}\n", .{spec});
            std.process.exit(2);
        };
        const name = spec[0..colon];
        const pw = spec[colon + 1 ..];
        const hash = if (pw.len == 0) "!" else try zen.users.hashPassword(a, pw);
        try out.print(a, "{s}:{s}:19000:0:99999:7:::\n", .{ name, hash });
    }
    const f = try std.fs.cwd().createFile(args[1], .{ .mode = 0o600 });
    defer f.close();
    try f.writeAll(out.items);
}
