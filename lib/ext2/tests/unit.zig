//! Unit tests on the in-memory block device. Every test finishes with the
//! built-in consistency checker (a subset of e2fsck).
const std = @import("std");
const ext2 = @import("../root.zig");
const format = ext2.format;

const testing = std.testing;
const Fs = ext2.Fs;
const ROOT = ext2.ROOT_INO;

fn clock() i64 {
    return 1_700_000_000;
}

const T = struct {
    md: *ext2.MemDevice,
    fs: *Fs,

    fn init(size: usize, opts: ext2.MkfsOptions) !T {
        const md = try testing.allocator.create(ext2.MemDevice);
        errdefer testing.allocator.destroy(md);
        md.* = try ext2.MemDevice.init(testing.allocator, size);
        errdefer md.deinit();
        try ext2.mkfs(testing.allocator, md.device(), opts);
        const fs = try Fs.mount(testing.allocator, md.device(), .{ .now = clock, .cache_blocks = 64, .inode_cache = 32 });
        return .{ .md = md, .fs = fs };
    }

    fn remount(self: *T) !void {
        try self.fs.unmount();
        self.fs = try Fs.mount(testing.allocator, self.md.device(), .{ .now = clock, .cache_blocks = 64, .inode_cache = 32 });
    }

    fn check(self: *T) !void {
        var buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const rep = try ext2.check(self.fs, testing.allocator, &w);
        if (rep.problems != 0) {
            std.debug.print("consistency problems ({d}):\n{s}\n", .{ rep.problems, w.buffered() });
            return error.Inconsistent;
        }
    }

    fn deinit(self: *T) void {
        self.check() catch |e| {
            std.debug.print("final check failed: {}\n", .{e});
            @panic("inconsistent filesystem");
        };
        self.fs.unmount() catch @panic("unmount failed");
        self.md.deinit();
        testing.allocator.destroy(self.md);
    }
};

fn fill(buf: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

fn readAll(fs: *Fs, ino: ext2.Ino, allocator: std.mem.Allocator) ![]u8 {
    const st = try fs.stat(ino);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    const n = try fs.read(ino, 0, buf);
    try testing.expectEqual(buf.len, n);
    return buf;
}

test "mkfs geometries mount clean" {
    const sizes = [_]u32{ 1024, 2048, 4096 };
    const isizes = [_]u32{ 128, 256 };
    for (sizes) |bs| for (isizes) |isz| {
        var t = try T.init(24 << 20, .{ .block_size = bs, .inode_size = isz, .label = "unit", .uuid_seed = 42 });
        defer t.deinit();
        try t.check();
        const sf = t.fs.statfs();
        try testing.expectEqual(bs, sf.block_size);
        try testing.expectEqualStrings("unit", sf.label[0..4]);
        const lf = try t.fs.lookup("/lost+found");
        const st = try t.fs.stat(lf);
        try testing.expectEqual(ext2.FileType.directory, st.kind);
        try testing.expectEqual(@as(u32, 2), st.nlink);
        const rs = try t.fs.stat(ROOT);
        try testing.expectEqual(@as(u32, 3), rs.nlink);
    };
    // revision 0
    var t = try T.init(8 << 20, .{ .block_size = 1024, .inode_size = 128, .revision = 0 });
    defer t.deinit();
    try testing.expect(!t.fs.has_filetype);
    const f = try t.fs.create(ROOT, "file", 0o644, 0, 0);
    _ = try t.fs.write(f, 0, "rev0");
    try testing.expectError(error.FileTooBig, t.fs.write(f, 0x8000_0000, "x"));
    var it = try t.fs.readdir(ROOT, 0);
    var seen = false;
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, "file")) {
            try testing.expectEqual(ext2.FileType.regular, e.kind);
            seen = true;
        }
    }
    try testing.expect(seen);
}

test "read/write direct, indirect, double and triple indirect, holes" {
    const a = testing.allocator;
    var t = try T.init(16 << 20, .{ .block_size = 1024 });
    defer t.deinit();
    const fs = t.fs;
    const ino = try fs.create(ROOT, "big", 0o644, 1000, 1000);
    // 5 MiB: direct + single + double indirect with 1K blocks
    const big = try a.alloc(u8, 5 << 20);
    defer a.free(big);
    fill(big, 1);
    // write in odd-sized chunks
    var off: usize = 0;
    var step: usize = 1;
    while (off < big.len) {
        const n = @min(step, big.len - off);
        try testing.expectEqual(n, try fs.write(ino, off, big[off..][0..n]));
        off += n;
        step = (step * 7 + 3) % 70000 + 1;
    }
    try t.check();
    const back = try readAll(fs, ino, a);
    defer a.free(back);
    try testing.expectEqualSlices(u8, big, back);
    // unaligned reads
    var small: [3000]u8 = undefined;
    try testing.expectEqual(small.len, try fs.read(ino, 12345, &small));
    try testing.expectEqualSlices(u8, big[12345..][0..3000], &small);

    // triple indirect via a sparse write at 70 MiB
    const sparse = try fs.create(ROOT, "sparse", 0o600, 0, 0);
    const far: u64 = 70 << 20;
    _ = try fs.write(sparse, far, "tail");
    _ = try fs.write(sparse, 5000, "mid");
    const st = try fs.stat(sparse);
    try testing.expectEqual(far + 4, st.size);
    // 2 data blocks + 1 single indirect? no: 5000 is direct (block 4); far needs
    // tind + dind + ind + data = 4 blocks -> 5 blocks of 1K = 10 sectors
    try testing.expectEqual(@as(u64, 10), st.blocks);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try fs.read(sparse, far - 4, &buf));
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00tail", &buf);
    try testing.expectEqual(@as(usize, 3), try fs.read(sparse, 5000, buf[0..3]));
    try testing.expectEqualSlices(u8, "mid", buf[0..3]);
    try testing.expectEqual(@as(usize, 4), try fs.read(sparse, 1 << 20, buf[0..4]));
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00", buf[0..4]);
    try t.check();

    // truncate everything away and check the space is returned
    const free_before = fs.statfs().free_blocks;
    try fs.truncate(sparse, 0);
    try testing.expectEqual(free_before + 5, fs.statfs().free_blocks);
    try fs.truncate(ino, 300 * 1024 + 17);
    try t.check();
    const cut = try readAll(fs, ino, a);
    defer a.free(cut);
    try testing.expectEqualSlices(u8, big[0 .. 300 * 1024 + 17], cut);
    // extending again exposes zeros, not stale data
    try fs.truncate(ino, 300 * 1024 + 1000);
    var tail: [983]u8 = undefined;
    _ = try fs.read(ino, 300 * 1024 + 17, &tail);
    try testing.expect(std.mem.allEqual(u8, &tail, 0));
    try t.remount();
    const again = try t.fs.lookup("/big");
    try testing.expectEqual(@as(u64, 300 * 1024 + 1000), (try t.fs.stat(again)).size);
}

test "large file on 4K blocks crosses into double indirect" {
    const a = testing.allocator;
    var t = try T.init(32 << 20, .{ .block_size = 4096 });
    defer t.deinit();
    const ino = try t.fs.create(ROOT, "f", 0o644, 0, 0);
    const data = try a.alloc(u8, (4 << 20) + 3 * 4096 + 5);
    defer a.free(data);
    fill(data, 7);
    try testing.expectEqual(data.len, try t.fs.write(ino, 0, data));
    try t.remount();
    const back = try readAll(t.fs, try t.fs.lookup("/f"), a);
    defer a.free(back);
    try testing.expectEqualSlices(u8, data, back);
    // > 4 GiB sparse file (large_file)
    const huge = try t.fs.create(ROOT, "huge", 0o644, 0, 0);
    _ = try t.fs.write(huge, 5 << 30, "x");
    try testing.expectEqual(@as(u64, (5 << 30) + 1), (try t.fs.stat(huge)).size);
    try t.remount();
    try testing.expectEqual(@as(u64, (5 << 30) + 1), (try t.fs.stat(try t.fs.lookup("/huge"))).size);
}

test "directories: many entries, removal, reuse, readdir cookies" {
    const a = testing.allocator;
    var t = try T.init(16 << 20, .{ .block_size = 1024, .inode_size = 128 });
    defer t.deinit();
    const fs = t.fs;
    const d = try fs.mkdir(ROOT, "many", 0o755, 0, 0);
    var name_buf: [64]u8 = undefined;
    const count = 700;
    for (0..count) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "entry-{d}-{s}", .{ i, "x" ** 20 ++ "y" ** 10 });
        const nm = name[0 .. name.len - (i % 29)];
        _ = try fs.create(d, nm, 0o644, 0, 0);
    }
    try testing.expect((try fs.stat(d)).size > 1024 * 10);
    try testing.expectError(error.Exists, fs.create(d, "entry-5-xxxxxxxxxxxxxxxxxxxxyyyyyyyyyy"[0 .. "entry-5-xxxxxxxxxxxxxxxxxxxxyyyyyyyyyy".len - 5], 0o644, 0, 0));
    // remove every third
    for (0..count) |i| {
        if (i % 3 != 0) continue;
        const name = try std.fmt.bufPrint(&name_buf, "entry-{d}-{s}", .{ i, "x" ** 20 ++ "y" ** 10 });
        try fs.unlink(d, name[0 .. name.len - (i % 29)]);
    }
    try t.check();
    // count via readdir, resuming from cookies each time
    var cookie: u64 = 0;
    var n: usize = 0;
    var dots: usize = 0;
    while (true) {
        var it = try fs.readdir(d, cookie);
        const e = (try it.next()) orelse break;
        cookie = e.cookie;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) dots += 1 else n += 1;
        try testing.expectEqual(if (dots > 0 and n == 0) ext2.FileType.directory else e.kind, e.kind);
    }
    try testing.expectEqual(@as(usize, 2), dots);
    try testing.expectEqual(count - (count + 2) / 3, n);
    // refill: space from deleted entries gets reused
    const size_before = (try fs.stat(d)).size;
    for (0..count / 3) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "new{d}", .{i});
        _ = try fs.create(d, name, 0o644, 0, 0);
    }
    try testing.expectEqual(size_before, (try fs.stat(d)).size);
    try testing.expectError(error.NotEmpty, fs.rmdir(ROOT, "many"));
    // delete everything via readdir and rmdir
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |s| a.free(s);
        names.deinit(a);
    }
    var it = try fs.readdir(d, 0);
    while (try it.next()) |e| {
        if (e.kind == .directory) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    for (names.items) |s| try fs.unlink(d, s);
    try fs.rmdir(ROOT, "many");
    try testing.expectError(error.NotFound, fs.lookup("/many"));
    try testing.expectEqual(@as(u32, 3), (try fs.stat(ROOT)).nlink);
}

test "readdir cookie survives concurrent deletion" {
    var t = try T.init(8 << 20, .{ .block_size = 1024 });
    defer t.deinit();
    const fs = t.fs;
    var name_buf: [32]u8 = undefined;
    for (0..50) |i| _ = try fs.create(ROOT, try std.fmt.bufPrint(&name_buf, "f{d:0>3}", .{i}), 0o644, 0, 0);
    var it = try fs.readdir(ROOT, 0);
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer {
        var ki = seen.keyIterator();
        while (ki.next()) |k| testing.allocator.free(k.*);
        seen.deinit();
    }
    var k: usize = 0;
    while (try it.next()) |e| : (k += 1) {
        try seen.put(try testing.allocator.dupe(u8, e.name), {});
        if (k == 10) {
            // delete an entry we already returned and one we have not
            try fs.unlink(ROOT, "f005");
            try fs.unlink(ROOT, "f040");
            it = try fs.readdir(ROOT, e.cookie);
        }
    }
    try testing.expect(seen.contains("f049"));
    try testing.expect(!seen.contains("f040"));
}

test "rename semantics" {
    var t = try T.init(8 << 20, .{ .block_size = 2048 });
    defer t.deinit();
    const fs = t.fs;
    const a = try fs.mkdir(ROOT, "a", 0o755, 0, 0);
    const b = try fs.mkdir(ROOT, "b", 0o755, 0, 0);
    const sub = try fs.mkdir(a, "sub", 0o755, 0, 0);
    _ = try fs.mkdir(sub, "deep", 0o755, 0, 0);
    const f = try fs.create(a, "file", 0o644, 0, 0);
    _ = try fs.write(f, 0, "content");
    const g = try fs.create(b, "other", 0o644, 0, 0);
    _ = try fs.write(g, 0, "other");

    // file across directories
    try fs.rename(a, "file", b, "moved");
    try testing.expectError(error.NotFound, fs.lookup("/a/file"));
    try testing.expectEqual(f, try fs.lookup("/b/moved"));
    // replace an existing file (old one freed)
    const free_inodes = fs.statfs().free_inodes;
    try fs.rename(b, "moved", b, "other");
    try testing.expectEqual(free_inodes + 1, fs.statfs().free_inodes);
    try testing.expectEqual(f, try fs.lookup("/b/other"));
    // rename onto itself / hard link of itself is a no-op
    try fs.rename(b, "other", b, "other");
    // directory into its own subtree
    try testing.expectError(error.InvalidArgument, fs.rename(ROOT, "a", sub, "x"));
    try testing.expectError(error.InvalidArgument, fs.rename(ROOT, "a", a, "x"));
    // directory across parents updates '..' and link counts
    const a_links = (try fs.stat(a)).nlink;
    const b_links = (try fs.stat(b)).nlink;
    try fs.rename(a, "sub", b, "sub2");
    try testing.expectEqual(a_links - 1, (try fs.stat(a)).nlink);
    try testing.expectEqual(b_links + 1, (try fs.stat(b)).nlink);
    try testing.expectEqual(b, try fs.lookup("/b/sub2/.."));
    try testing.expectEqual(sub, try fs.lookup("/b/sub2/deep/.."));
    try t.check();
    // type mismatches
    try testing.expectError(error.NotDir, fs.rename(b, "sub2", b, "other"));
    try testing.expectError(error.IsDir, fs.rename(b, "other", b, "sub2"));
    // dir over non-empty dir
    const e = try fs.mkdir(ROOT, "e", 0o755, 0, 0);
    try testing.expectError(error.NotEmpty, fs.rename(ROOT, "e", b, "sub2"));
    // dir over empty dir (cross-parent)
    const empty = try fs.mkdir(a, "empty", 0o755, 0, 0);
    _ = empty;
    const root_links = (try fs.stat(ROOT)).nlink;
    try fs.rename(ROOT, "e", a, "empty");
    try testing.expectEqual(root_links - 1, (try fs.stat(ROOT)).nlink);
    try testing.expectEqual(e, try fs.lookup("/a/empty"));
    try testing.expectEqual(a, try fs.lookup("/a/empty/.."));
    try testing.expectError(error.InvalidArgument, fs.rename(ROOT, "a", ROOT, "."));
    try testing.expectError(error.NotFound, fs.rename(ROOT, "nope", ROOT, "x"));
    try t.check();
}

test "symlinks, lookup and loops" {
    const a = testing.allocator;
    var t = try T.init(8 << 20, .{ .block_size = 1024 });
    defer t.deinit();
    const fs = t.fs;
    const d = try fs.mkdir(ROOT, "dir", 0o755, 0, 0);
    const f = try fs.create(d, "target", 0o644, 0, 0);
    _ = try fs.write(f, 0, "data");
    _ = try fs.symlink(ROOT, "abs", "/dir/target", 0, 0);
    _ = try fs.symlink(d, "rel", "target", 0, 0);
    _ = try fs.symlink(ROOT, "dirlink", "dir", 0, 0);
    _ = try fs.symlink(ROOT, "chain", "dirlink/rel", 0, 0);
    const long_target = try a.alloc(u8, 300);
    defer a.free(long_target);
    @memset(long_target, 'a');
    for (long_target, 0..) |*c, k| {
        if (k % 50 == 49) c.* = '/';
    }
    @memcpy(long_target[0..5], "/dir/");
    long_target[long_target.len - 1] = 'z';
    const slow = try fs.symlink(ROOT, "slow", long_target, 0, 0);
    try testing.expect((try fs.stat(slow)).blocks > 0);
    const fast = try fs.lookupNoFollow("/abs");
    try testing.expectEqual(@as(u64, 0), (try fs.stat(fast)).blocks);
    try testing.expectEqual(ext2.FileType.symlink, (try fs.stat(fast)).kind);

    try testing.expectEqual(f, try fs.lookup("/abs"));
    try testing.expectEqual(f, try fs.lookup("/dir/rel"));
    try testing.expectEqual(f, try fs.lookup("/dirlink/target"));
    try testing.expectEqual(f, try fs.lookup("/chain"));
    try testing.expectEqual(d, try fs.lookup("/dirlink/"));
    try testing.expectEqual(d, try fs.lookup("/dirlink/."));
    try testing.expectEqual(ROOT, try fs.lookup("/dirlink/.."));
    try testing.expectEqual(ROOT, try fs.lookup("/../.."));
    try testing.expectError(error.NotDir, fs.lookup("/abs/x"));
    try testing.expectError(error.NotDir, fs.lookup("/dir/target/"));
    try testing.expectError(error.NotFound, fs.lookup("/slow"));
    var buf: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, long_target, try fs.readlink(slow, &buf));
    try testing.expectEqualSlices(u8, "/dir/target", try fs.readlink(fast, &buf));
    try testing.expectError(error.InvalidArgument, fs.readlink(f, &buf));

    _ = try fs.symlink(ROOT, "loop1", "loop2", 0, 0);
    _ = try fs.symlink(ROOT, "loop2", "/loop1", 0, 0);
    try testing.expectError(error.Loop, fs.lookup("/loop1"));
    _ = try fs.lookupNoFollow("/loop1");
    _ = try fs.symlink(ROOT, "self", "self/x", 0, 0);
    try testing.expectError(error.Loop, fs.lookup("/self"));
    try testing.expectError(error.NameTooLong, fs.symlink(ROOT, "toolong", "a" ** 1024, 0, 0));
    try testing.expectError(error.NameTooLong, fs.create(ROOT, "n" ** 256, 0o644, 0, 0));
    _ = try fs.create(ROOT, "n" ** 255, 0o644, 0, 0);
    try testing.expectEqual(ROOT, (try fs.resolveParent(ROOT, "/abs")).dir);
    try testing.expectEqualStrings("target", (try fs.resolveParent(ROOT, "/dirlink/target/")).name);
    try t.remount();
    try testing.expectEqual(f, try t.fs.lookup("/chain"));
    try t.fs.unlink(ROOT, "slow");
    try t.fs.unlink(ROOT, "abs");
}

test "hard links, special files, attributes" {
    var t = try T.init(8 << 20, .{});
    defer t.deinit();
    const fs = t.fs;
    const f = try fs.create(ROOT, "f", 0o4755, 0, 0);
    try fs.link(f, ROOT, "g");
    const d = try fs.mkdir(ROOT, "d", 0o700, 5, 6);
    try fs.link(f, d, "h");
    try testing.expectEqual(@as(u32, 3), (try fs.stat(f)).nlink);
    try testing.expectError(error.NotPermitted, fs.link(d, ROOT, "dl"));
    try testing.expectError(error.Exists, fs.link(f, ROOT, "g"));
    try fs.unlink(ROOT, "f");
    try fs.unlink(ROOT, "g");
    try testing.expectEqual(@as(u32, 1), (try fs.stat(f)).nlink);
    _ = try fs.write(f, 0, "still here");
    try testing.expectError(error.IsDir, fs.unlink(ROOT, "d"));
    try testing.expectError(error.NotDir, fs.rmdir(d, "h"));

    const c = try fs.mknod(ROOT, "null", ext2.S_IFCHR | 0o666, .{ .major = 1, .minor = 3 }, 0, 0);
    const bdev = try fs.mknod(ROOT, "big", ext2.S_IFBLK | 0o660, .{ .major = 259, .minor = 70000 }, 0, 6);
    const fifo = try fs.mknod(ROOT, "fifo", ext2.S_IFIFO | 0o644, .{}, 0, 0);
    const sock = try fs.mknod(ROOT, "sock", ext2.S_IFSOCK | 0o644, .{}, 0, 0);
    try testing.expectEqual(ext2.Dev{ .major = 1, .minor = 3 }, (try fs.stat(c)).rdev);
    try testing.expectEqual(ext2.Dev{ .major = 259, .minor = 70000 }, (try fs.stat(bdev)).rdev);
    try testing.expectEqual(ext2.FileType.fifo, (try fs.stat(fifo)).kind);
    try testing.expectEqual(ext2.FileType.socket, (try fs.stat(sock)).kind);
    try testing.expectError(error.InvalidArgument, fs.write(fifo, 0, "x"));
    try testing.expectError(error.InvalidArgument, fs.mknod(ROOT, "bad", ext2.S_IFDIR, .{}, 0, 0));

    try fs.chmod(f, 0o2750);
    try fs.chown(f, 100_000, null);
    try fs.chown(f, null, 70_000);
    try fs.utimes(f, 1234, 5678);
    try t.remount();
    const fs2 = t.fs;
    const st = try fs2.stat(try fs2.lookup("/d/h"));
    try testing.expectEqual(ext2.S_IFREG | 0o2750, st.mode);
    try testing.expectEqual(@as(u32, 100_000), st.uid);
    try testing.expectEqual(@as(u32, 70_000), st.gid);
    try testing.expectEqual(@as(i64, 1234), st.atime);
    try testing.expectEqual(@as(i64, 5678), st.mtime);
    try testing.expectEqual(@as(i64, 1_700_000_000), st.ctime);
    try testing.expectEqual(@as(u64, 10), st.size);
    const ds = try fs2.stat(try fs2.lookup("/d"));
    try testing.expectEqual(@as(u32, 5), ds.uid);
    try testing.expectEqual(ext2.S_IFDIR | 0o700, ds.mode);
    try fs2.unlink(ROOT, "null");
    try fs2.unlink(ROOT, "big");
}

test "open-unlinked files stay alive until released" {
    var t = try T.init(8 << 20, .{ .block_size = 1024 });
    defer t.deinit();
    const fs = t.fs;
    const f = try fs.create(ROOT, "tmp", 0o600, 0, 0);
    var data: [50000]u8 = undefined;
    fill(&data, 5);
    _ = try fs.write(f, 0, &data);
    const free0 = fs.statfs().free_blocks;
    try fs.retain(f);
    try fs.unlink(ROOT, "tmp");
    try testing.expectError(error.NotFound, fs.lookup("/tmp"));
    // still readable and writable through the inode number
    var back: [50000]u8 = undefined;
    try testing.expectEqual(data.len, try fs.read(f, 0, &back));
    try testing.expectEqualSlices(u8, &data, &back);
    _ = try fs.write(f, data.len, "more");
    try testing.expectEqual(@as(u32, 0), (try fs.stat(f)).nlink);
    try t.check();
    try testing.expectEqual(free0, fs.statfs().free_blocks);
    try fs.release(f);
    try testing.expectError(error.NotFound, fs.stat(f));
    try testing.expect(fs.statfs().free_blocks > free0);
    try testing.expectError(error.InvalidArgument, fs.release(f));
    // a held directory that gets removed
    const d = try fs.mkdir(ROOT, "d", 0o755, 0, 0);
    try fs.retain(d);
    try fs.rmdir(ROOT, "d");
    try testing.expectError(error.NotFound, fs.create(d, "x", 0o644, 0, 0));
    try t.check();
    // unmount releases remaining holds
    const g = try fs.create(ROOT, "g", 0o600, 0, 0);
    try fs.retain(g);
    try fs.unlink(ROOT, "g");
    try t.remount();
    try testing.expectError(error.NotFound, t.fs.stat(g));
    try testing.expectError(error.NotFound, t.fs.stat(d));
}

test "no space and read-only" {
    const a = testing.allocator;
    var t = try T.init(2 << 20, .{ .block_size = 1024, .inodes_count = 64 });
    defer t.deinit();
    const fs = t.fs;
    const buf = try a.alloc(u8, 4 << 20);
    defer a.free(buf);
    fill(buf, 3);
    const f = try fs.create(ROOT, "fill", 0o644, 0, 0);
    const n = try fs.write(f, 0, buf);
    try testing.expect(n < buf.len and n > 1 << 20);
    try testing.expectEqual(@as(u64, 0), fs.statfs().free_blocks);
    try testing.expectError(error.NoSpace, fs.write(f, n, "more"));
    try testing.expectError(error.NoSpace, fs.mkdir(ROOT, "d", 0o755, 0, 0));
    try t.check();
    const back = try readAll(fs, f, a);
    defer a.free(back);
    try testing.expectEqualSlices(u8, buf[0..n], back);
    try fs.truncate(f, 0);
    // run out of inodes
    var name_buf: [16]u8 = undefined;
    var made: usize = 0;
    while (true) : (made += 1) {
        _ = fs.create(ROOT, try std.fmt.bufPrint(&name_buf, "i{d}", .{made}), 0o644, 0, 0) catch |e| {
            try testing.expectEqual(error.NoSpace, e);
            break;
        };
    }
    try testing.expectEqual(@as(u64, 0), fs.statfs().free_inodes);
    try t.check();

    // read-only mount rejects modifications
    try fs.unmount();
    t.fs = try Fs.mount(a, t.md.device(), .{ .read_only = true });
    try testing.expectError(error.ReadOnly, t.fs.create(ROOT, "x", 0o644, 0, 0));
    try testing.expectError(error.ReadOnly, t.fs.write(f, 0, "x"));
    _ = try t.fs.stat(f);
    const writes = t.md.writes;
    try t.fs.unmount();
    try testing.expectEqual(writes, t.md.writes);
    t.fs = try Fs.mount(a, t.md.device(), .{ .now = clock });
}

test "unsupported features are refused" {
    var md = try ext2.MemDevice.init(testing.allocator, 4 << 20);
    defer md.deinit();
    try ext2.mkfs(testing.allocator, md.device(), .{ .block_size = 1024 });
    const sb = md.bytes[1024..2048];
    const incompat = format.get32(sb, format.sb.feature_incompat);
    format.put32(sb, format.sb.feature_incompat, incompat | format.INCOMPAT_EXTENTS);
    try testing.expectError(error.Unsupported, Fs.mount(testing.allocator, md.device(), .{}));
    try testing.expectError(error.Unsupported, Fs.mount(testing.allocator, md.device(), .{ .read_only = true }));
    format.put32(sb, format.sb.feature_incompat, incompat | format.INCOMPAT_RECOVER);
    try testing.expectError(error.Unsupported, Fs.mount(testing.allocator, md.device(), .{}));
    format.put32(sb, format.sb.feature_incompat, incompat);
    const ro = format.get32(sb, format.sb.feature_ro_compat);
    format.put32(sb, format.sb.feature_ro_compat, ro | format.RO_COMPAT_METADATA_CSUM);
    try testing.expectError(error.Unsupported, Fs.mount(testing.allocator, md.device(), .{}));
    const fs = try Fs.mount(testing.allocator, md.device(), .{ .read_only = true });
    try fs.unmount();
    format.put32(sb, format.sb.feature_ro_compat, ro);
    format.put16(sb, format.sb.magic, 0x1234);
    try testing.expectError(error.Corrupt, Fs.mount(testing.allocator, md.device(), .{}));
}

test "device write failure surfaces as Io" {
    var t = try T.init(4 << 20, .{ .block_size = 1024 });
    defer t.deinit();
    const f = try t.fs.create(ROOT, "x", 0o644, 0, 0);
    var big: [8192]u8 = undefined;
    fill(&big, 9);
    t.md.fail_writes = true;
    try testing.expectError(error.Io, t.fs.write(f, 0, &big));
    try testing.expectError(error.Io, t.fs.sync());
    t.md.fail_writes = false;
    try t.fs.sync();
}

// ---------------------------------------------------------------------------
// Randomized operations against an in-memory model.
// ---------------------------------------------------------------------------

const Model = struct {
    const Node = struct {
        kind: enum { file, dir, link },
        data: std.ArrayList(u8) = .empty,
    };
    a: std.mem.Allocator,
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,

    fn deinit(self: *Model) void {
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            self.a.free(e.key_ptr.*);
            e.value_ptr.data.deinit(self.a);
        }
        self.nodes.deinit(self.a);
    }

    fn put(self: *Model, path: []const u8, node: Node) !void {
        try self.nodes.put(self.a, try self.a.dupe(u8, path), node);
    }

    fn remove(self: *Model, path: []const u8) void {
        const kv = self.nodes.fetchSwapRemove(path).?;
        self.a.free(kv.key);
        var n = kv.value;
        n.data.deinit(self.a);
    }

    fn hasChildren(self: *Model, path: []const u8) bool {
        for (self.nodes.keys()) |k| {
            if (k.len > path.len and std.mem.startsWith(u8, k, path) and k[path.len] == '/') return true;
        }
        return false;
    }

    fn pick(self: *Model, rnd: std.Random, kind: ?@TypeOf(@as(Node, undefined).kind)) ?[]const u8 {
        const keys = self.nodes.keys();
        if (keys.len == 0) return null;
        var tries: usize = 0;
        while (tries < 20) : (tries += 1) {
            const k = keys[rnd.uintLessThan(usize, keys.len)];
            if (kind == null or self.nodes.get(k).?.kind == kind.?) return k;
        }
        return null;
    }
};

fn verifyModel(fs: *Fs, m: *Model, a: std.mem.Allocator) !void {
    var it = m.nodes.iterator();
    while (it.next()) |e| {
        const ino = try fs.lookupNoFollow(e.key_ptr.*);
        const st = try fs.stat(ino);
        switch (e.value_ptr.kind) {
            .dir => try testing.expectEqual(ext2.FileType.directory, st.kind),
            .link => {
                var buf: [4096]u8 = undefined;
                try testing.expectEqualSlices(u8, e.value_ptr.data.items, try fs.readlink(ino, &buf));
            },
            .file => {
                try testing.expectEqual(@as(u64, e.value_ptr.data.items.len), st.size);
                const back = try readAll(fs, ino, a);
                defer a.free(back);
                try testing.expectEqualSlices(u8, e.value_ptr.data.items, back);
            },
        }
    }
}

fn randomOps(bs: u32, isz: u32, seed: u64, ops: usize) !void {
    const a = testing.allocator;
    var t = try T.init(24 << 20, .{ .block_size = bs, .inode_size = isz, .uuid_seed = seed });
    defer t.deinit();
    var m: Model = .{ .a = a };
    defer m.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var scratch = try a.alloc(u8, 600 * 1024);
    defer a.free(scratch);
    var path_buf: [512]u8 = undefined;
    var path_buf2: [512]u8 = undefined;
    var counter: usize = 0;

    for (0..ops) |step| {
        const fs = t.fs;
        const op = rnd.uintLessThan(u32, 100);
        counter += 1;
        // choose a parent directory
        const parent_path: []const u8 = if (rnd.boolean()) "" else (m.pick(rnd, .dir) orelse "");
        const parent = if (parent_path.len == 0) ROOT else try fs.lookup(parent_path);
        const name = try std.fmt.bufPrint(&path_buf2, "n{d}_{s}", .{ counter, "abcdefghijklmnopqrstuvwxyz"[0..rnd.uintLessThan(usize, 26)] });
        const full = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent_path, name });
        if (op < 25) {
            // create file with content
            const ino = try fs.create(parent, name, 0o644, 0, 0);
            const len = rnd.uintLessThan(usize, if (rnd.uintLessThan(u8, 10) == 0) scratch.len else 5000);
            fill(scratch[0..len], step);
            try testing.expectEqual(len, try fs.write(ino, 0, scratch[0..len]));
            var node: Model.Node = .{ .kind = .file };
            try node.data.appendSlice(a, scratch[0..len]);
            try m.put(full, node);
        } else if (op < 35) {
            _ = try fs.mkdir(parent, name, 0o755, 0, 0);
            try m.put(full, .{ .kind = .dir });
        } else if (op < 50) {
            // overwrite / extend at a random offset
            const p = m.pick(rnd, .file) orelse continue;
            const node = m.nodes.getPtr(p).?;
            const ino = try fs.lookup(p);
            const off = rnd.uintLessThan(usize, node.data.items.len + 3000);
            const len = rnd.uintLessThan(usize, 9000);
            fill(scratch[0..len], step * 31);
            try testing.expectEqual(len, try fs.write(ino, off, scratch[0..len]));
            if (off + len > node.data.items.len) {
                const old = node.data.items.len;
                try node.data.resize(a, off + len);
                if (off > old) @memset(node.data.items[old..off], 0);
            }
            @memcpy(node.data.items[off..][0..len], scratch[0..len]);
        } else if (op < 58) {
            const p = m.pick(rnd, .file) orelse continue;
            const node = m.nodes.getPtr(p).?;
            const ino = try fs.lookup(p);
            const new_len = rnd.uintLessThan(usize, node.data.items.len + 20000);
            try fs.truncate(ino, new_len);
            const old = node.data.items.len;
            try node.data.resize(a, new_len);
            if (new_len > old) @memset(node.data.items[old..], 0);
        } else if (op < 68) {
            const p = m.pick(rnd, .file) orelse (m.pick(rnd, .link) orelse continue);
            const pn = try fs.resolveParent(ROOT, p);
            try fs.unlink(pn.dir, pn.name);
            m.remove(p);
        } else if (op < 73) {
            const p = m.pick(rnd, .dir) orelse continue;
            const pn = try fs.resolveParent(ROOT, p);
            if (m.hasChildren(p)) {
                try testing.expectError(error.NotEmpty, fs.rmdir(pn.dir, pn.name));
            } else {
                try fs.rmdir(pn.dir, pn.name);
                m.remove(p);
            }
        } else if (op < 85) {
            // rename a file or an (empty or not) directory
            const p = m.pick(rnd, null) orelse continue;
            const kind = m.nodes.get(p).?.kind;
            if (kind == .dir and std.mem.startsWith(u8, full, p) and full.len > p.len and full[p.len] == '/') {
                const pn = try fs.resolveParent(ROOT, p);
                try testing.expectError(error.InvalidArgument, fs.rename(pn.dir, pn.name, parent, name));
                continue;
            }
            const pn = try fs.resolveParent(ROOT, p);
            try fs.rename(pn.dir, pn.name, parent, name);
            // move the node and all descendants in the model
            const old_prefix = try a.dupe(u8, p);
            defer a.free(old_prefix);
            var moves: std.ArrayList([]const u8) = .empty;
            defer moves.deinit(a);
            for (m.nodes.keys()) |k| {
                if (std.mem.eql(u8, k, old_prefix) or (k.len > old_prefix.len and std.mem.startsWith(u8, k, old_prefix) and k[old_prefix.len] == '/'))
                    try moves.append(a, k);
            }
            for (moves.items) |k| {
                const kv = m.nodes.fetchSwapRemove(k).?;
                const new_key = try std.mem.concat(a, u8, &.{ full, kv.key[old_prefix.len..] });
                a.free(kv.key);
                try m.nodes.put(a, new_key, kv.value);
            }
        } else if (op < 95) {
            const len = 1 + rnd.uintLessThan(usize, if (rnd.boolean()) 50 else 900);
            const target = scratch[0..len];
            for (target) |*c| c.* = "abcdef/._"[rnd.uintLessThan(usize, 9)];
            _ = try fs.symlink(parent, name, target, 0, 0);
            var node: Model.Node = .{ .kind = .link };
            try node.data.appendSlice(a, target);
            try m.put(full, node);
        } else {
            try t.check();
            if (rnd.boolean()) try t.remount() else try t.fs.sync();
        }
    }
    try verifyModel(t.fs, &m, a);
    try t.check();
    try t.remount();
    try verifyModel(t.fs, &m, a);
    scratch = scratch;
}

test "random operations 1K/128" {
    try randomOps(1024, 128, 1, 600);
}
test "random operations 2K/256" {
    try randomOps(2048, 256, 2, 600);
}
test "random operations 4K/256" {
    try randomOps(4096, 256, 3, 600);
}
