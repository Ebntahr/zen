//! Root for cross-compilation checks: references the whole public API so
//! that every code path is analyzed and compiled for the target (e.g.
//! riscv64-freestanding-none, where the file server runs).
const std = @import("std");
const ext2 = @import("ext2");

var heap: [4 << 20]u8 = undefined;

fn clock() i64 {
    return 1_700_000_000;
}

fn run() ext2.Error!void {
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const a = fba.allocator();
    var md = try ext2.MemDevice.init(a, 2 << 20);
    try ext2.mkfs(a, md.device(), .{ .block_size = 1024, .label = "cross" });
    const fs = try ext2.Fs.mount(a, md.device(), .{ .now = clock });
    const root = ext2.ROOT_INO;
    const d = try fs.mkdir(root, "d", 0o755, 0, 0);
    const f = try fs.create(d, "f", 0o644, 0, 0);
    _ = try fs.write(f, 0, "hello");
    var buf: [16]u8 = undefined;
    _ = try fs.read(f, 0, &buf);
    try fs.truncate(f, 2);
    _ = try fs.symlink(root, "l", "d/f", 0, 0);
    _ = try fs.readlink(try fs.lookupNoFollow("/l"), &buf);
    _ = try fs.lookup("/l");
    _ = try fs.mknod(d, "n", ext2.S_IFCHR | 0o600, .{ .major = 1, .minor = 3 }, 0, 0);
    try fs.link(f, root, "hard");
    try fs.rename(root, "hard", d, "hard2");
    try fs.unlink(d, "hard2");
    try fs.chmod(f, 0o600);
    try fs.chown(f, 1, 2);
    try fs.utimes(f, 1, 2);
    _ = try fs.stat(f);
    _ = fs.statfs();
    var it = try fs.readdir(d, 0);
    while (try it.next()) |_| {}
    _ = try fs.resolveParent(root, "/d/f");
    _ = try ext2.check(fs, a, null);
    try fs.unlink(d, "n");
    try fs.sync();
    try fs.unmount();
}

export fn ext2_cross_selftest() i32 {
    run() catch |e| return -@as(i32, ext2.errno(e));
    return 0;
}
