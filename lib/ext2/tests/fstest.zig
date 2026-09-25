//! Host-side integration test driver. Performs operations through the ext2
//! library on a disk image while mirroring them onto a host directory, so
//! that the result can be compared with what e2fsprogs (debugfs) sees.
//!
//!   fstest ops <img> <mirror-dir>          scripted scenario
//!   fstest random <img> <mirror-dir> <seed> <ops>
//!   fstest verify <img> <host-dir>         library view == host tree
//!   fstest expect-unsupported <img>        mount must fail cleanly
//!   fstest check <img>                     built-in consistency check
const std = @import("std");
const ext2 = @import("ext2");
const host = @import("ext2_host");

const Fs = ext2.Fs;
const Ino = ext2.Ino;
const ROOT = ext2.ROOT_INO;
const Allocator = std.mem.Allocator;

fn clock() i64 {
    return std.time.timestamp();
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fstest: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Pair = struct {
    fs: *Fs,
    m: std.fs.Dir,
    a: Allocator,
    pathbuf: [4096]u8 = undefined,

    fn abs(self: *Pair, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.pathbuf, "/{s}", .{rel}) catch unreachable;
    }

    fn parent(self: *Pair, rel: []const u8) !ext2.ParentAndName {
        return self.fs.resolveParent(ROOT, self.abs(rel));
    }

    fn ino(self: *Pair, rel: []const u8) !Ino {
        return self.fs.lookupNoFollow(self.abs(rel));
    }

    fn mkdir(self: *Pair, rel: []const u8, mode: u16) !void {
        const pn = try self.parent(rel);
        _ = try self.fs.mkdir(pn.dir, pn.name, mode, 0, 0);
        try self.m.makeDir(rel);
        var d = try self.m.openDir(rel, .{ .iterate = true });
        defer d.close();
        try d.chmod(mode);
    }

    fn create(self: *Pair, rel: []const u8, mode: u16) !void {
        const pn = try self.parent(rel);
        _ = try self.fs.create(pn.dir, pn.name, mode, 0, 0);
        const f = try self.m.createFile(rel, .{ .exclusive = true });
        defer f.close();
        try f.chmod(mode);
    }

    fn write(self: *Pair, rel: []const u8, off: u64, data: []const u8) !void {
        const i = try self.ino(rel);
        const n = try self.fs.write(i, off, data);
        if (n != data.len) return error.ShortWrite;
        const f = try self.m.openFile(rel, .{ .mode = .read_write });
        defer f.close();
        try f.pwriteAll(data, off);
    }

    fn truncate(self: *Pair, rel: []const u8, size: u64) !void {
        try self.fs.truncate(try self.ino(rel), size);
        const f = try self.m.openFile(rel, .{ .mode = .read_write });
        defer f.close();
        try f.setEndPos(size);
    }

    fn unlink(self: *Pair, rel: []const u8) !void {
        const pn = try self.parent(rel);
        try self.fs.unlink(pn.dir, pn.name);
        try self.m.deleteFile(rel);
    }

    fn rmdir(self: *Pair, rel: []const u8) !void {
        const pn = try self.parent(rel);
        try self.fs.rmdir(pn.dir, pn.name);
        try self.m.deleteDir(rel);
    }

    fn rmTree(self: *Pair, rel: []const u8) !void {
        const i = try self.ino(rel);
        const st = try self.fs.stat(i);
        if (st.kind == .directory) {
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| self.a.free(n);
                names.deinit(self.a);
            }
            var it = try self.fs.readdir(i, 0);
            while (try it.next()) |e| {
                if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
                try names.append(self.a, try std.fmt.allocPrint(self.a, "{s}/{s}", .{ rel, e.name }));
            }
            for (names.items) |n| try self.rmTree(n);
            try self.rmdir(rel);
        } else try self.unlink(rel);
    }

    fn rename(self: *Pair, from: []const u8, to: []const u8) !void {
        const sp = try self.parent(from);
        const sp_dir = sp.dir;
        const sp_name = try self.a.dupe(u8, sp.name);
        defer self.a.free(sp_name);
        const dp = try self.parent(to);
        try self.fs.rename(sp_dir, sp_name, dp.dir, dp.name);
        try self.m.rename(from, to);
    }

    fn symlink(self: *Pair, target: []const u8, rel: []const u8) !void {
        const pn = try self.parent(rel);
        _ = try self.fs.symlink(pn.dir, pn.name, target, 0, 0);
        try self.m.symLink(target, rel, .{});
    }

    fn link(self: *Pair, existing: []const u8, rel: []const u8) !void {
        const i = try self.ino(existing);
        const pn = try self.parent(rel);
        try self.fs.link(i, pn.dir, pn.name);
        try std.posix.linkat(self.m.fd, existing, self.m.fd, rel, 0);
    }

    fn chmod(self: *Pair, rel: []const u8, mode: u16) !void {
        const i = try self.ino(rel);
        try self.fs.chmod(i, mode);
        const st = try self.fs.stat(i);
        if (st.kind == .directory) {
            var d = try self.m.openDir(rel, .{ .iterate = true });
            defer d.close();
            try d.chmod(mode);
        } else {
            const f = try self.m.openFile(rel, .{});
            defer f.close();
            try f.chmod(mode);
        }
    }

    fn chown(self: *Pair, rel: []const u8, uid: u32, gid: u32) !void {
        const i = try self.ino(rel);
        try self.fs.chown(i, uid, gid);
        const st = try self.fs.stat(i);
        if (st.kind == .directory) {
            var d = try self.m.openDir(rel, .{ .iterate = true });
            defer d.close();
            try d.chown(uid, gid);
        } else {
            const f = try self.m.openFile(rel, .{});
            defer f.close();
            try f.chown(uid, gid);
        }
    }

    fn exists(self: *Pair, rel: []const u8) bool {
        _ = self.ino(rel) catch return false;
        return true;
    }
};

fn fillRandom(buf: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

fn openImage(path: []const u8, dev: *host.FileDevice, read_only: bool) *Fs {
    dev.* = host.FileDevice.open(path, read_only) catch |e| die("open {s}: {s}", .{ path, @errorName(e) });
    return Fs.mount(std.heap.page_allocator, dev.device(), .{
        .read_only = read_only,
        .now = clock,
        .cache_blocks = 256, // small on purpose: exercise eviction
        .inode_cache = 64,
    }) catch |e| die("mount {s}: {s}", .{ path, @errorName(e) });
}

fn internalCheck(fs: *Fs) void {
    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const rep = ext2.check(fs, std.heap.page_allocator, &w) catch |e| die("check: {s}", .{@errorName(e)});
    if (rep.problems != 0) die("internal check found {d} problems:\n{s}", .{ rep.problems, w.buffered() });
}

// ---------------------------------------------------------------------------

fn scenario(p: *Pair) !void {
    const a = p.a;
    const fs = p.fs;
    const bs = fs.statfs().block_size;
    const big = try a.alloc(u8, (5 << 20) + 1234);
    defer a.free(big);
    fillRandom(big, 1);

    try p.mkdir("zt", 0o755);
    try p.create("zt/small.txt", 0o644);
    try p.write("zt/small.txt", 0, "hello world\n");
    try p.create("zt/empty", 0o600);

    // Large file (double indirect for every block size), written in pieces.
    try p.create("zt/big.bin", 0o644);
    var off: usize = 0;
    var step: usize = 4096 * 3 + 17;
    while (off < big.len) {
        const n = @min(step, big.len - off);
        try p.write("zt/big.bin", off, big[off..][0..n]);
        off += n;
        step = step * 2 + 1;
    }
    // Sparse file.
    try p.create("zt/sparse.bin", 0o644);
    try p.write("zt/sparse.bin", 0, "start");
    try p.write("zt/sparse.bin", (1 << 20) + 5, "middle");
    try p.write("zt/sparse.bin", 10 << 20, "end");
    try p.write("zt/sparse.bin", 3 * bs - 2, "straddle");
    // Triple indirect (sparse).
    try p.create("zt/triple.bin", 0o644);
    const triple_off: u64 = if (bs == 1024) 70 << 20 else if (bs == 2048) (600 << 20) else (5 << 30);
    const large_ok = fs.rev >= 1;
    if (large_ok or triple_off < 0x7fff_ffff) {
        try p.write("zt/triple.bin", triple_off, "far away");
        try p.write("zt/triple.bin", 100, "near");
    }

    // Many directory entries with varying name lengths.
    try p.mkdir("zt/many", 0o755);
    var name_buf: [300]u8 = undefined;
    const count = 800;
    for (0..count) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "zt/many/file-{d:0>4}-{s}", .{ i, "abcdefghijklmnopqrstuvwxyz0123456789"[0 .. i % 37] });
        try p.create(name, 0o644);
        if (i % 5 == 0) try p.write(name, 0, name);
    }
    for (0..count) |i| {
        if (i % 3 != 0) continue;
        const name = try std.fmt.bufPrint(&name_buf, "zt/many/file-{d:0>4}-{s}", .{ i, "abcdefghijklmnopqrstuvwxyz0123456789"[0 .. i % 37] });
        try p.unlink(name);
    }
    for (0..120) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "zt/many/n{d}", .{i});
        try p.create(name, 0o640);
    }

    // Nested directories, renames across directories.
    try p.mkdir("zt/a", 0o755);
    try p.mkdir("zt/a/b", 0o750);
    try p.mkdir("zt/a/b/c", 0o755);
    try p.mkdir("zt/a/b/c/d", 0o700);
    try p.create("zt/a/b/c/d/leaf", 0o644);
    try p.write("zt/a/b/c/d/leaf", 0, "leaf data\n");
    try p.create("zt/a/b/file", 0o644);
    try p.write("zt/a/b/file", 0, big[0..70000]);
    try p.rename("zt/small.txt", "zt/a/b/renamed.txt");
    try p.create("zt/x1", 0o644);
    try p.write("zt/x1", 0, "x1 wins");
    try p.create("zt/x2", 0o644);
    try p.write("zt/x2", 0, "x2 loses, longer content");
    try p.rename("zt/x1", "zt/x2");
    try p.rename("zt/a/b/c", "zt/moved_c");
    try p.mkdir("zt/empty_dir", 0o755);
    try p.rename("zt/a/b", "zt/empty_dir");
    try p.mkdir("zt/a/gone", 0o755);
    try p.rmdir("zt/a/gone");
    try p.rename("zt/many/n5", "zt/a/n5_moved");
    try p.rename("zt/moved_c/d/leaf", "zt/moved_c/leaf2");

    // Symlinks: fast, slow, absolute, dangling, through a symlinked dir.
    try p.symlink("big.bin", "zt/link_fast");
    var long_target: [200]u8 = undefined;
    for (&long_target, 0..) |*c, i| c.* = if (i % 40 == 39) '/' else 'a' + @as(u8, @intCast(i % 26));
    try p.symlink(&long_target, "zt/link_slow");
    try p.symlink("/zt/moved_c", "zt/link_abs");
    try p.symlink("does/not/exist", "zt/link_dangling");
    if (try fs.lookup("/zt/link_abs/leaf2") != try p.ino("zt/moved_c/leaf2")) return error.SymlinkResolution;
    if (try fs.lookup("/zt/link_fast") != try p.ino("zt/big.bin")) return error.SymlinkResolution;

    // Hard links.
    try p.link("zt/big.bin", "zt/a/big_hardlink");
    try p.link("zt/x2", "zt/x2_link");
    try p.unlink("zt/x2");

    // Truncation: shrink, to zero, extend with hole.
    try p.truncate("zt/big.bin", (3 << 20) + 123);
    try p.create("zt/trunc", 0o644);
    try p.write("zt/trunc", 0, big[0..300000]);
    try p.truncate("zt/trunc", 0);
    try p.write("zt/trunc", 5000, "after hole");
    try p.truncate("zt/trunc", 1 << 20);
    try p.truncate("zt/sparse.bin", (1 << 20) + 8);

    // Attributes.
    // (chown before chmod: the host kernel clears setuid on chown)
    try p.chown("zt/a/big_hardlink", 1234, 5678);
    try p.chmod("zt/a/big_hardlink", 0o4755);
    try p.chown("zt/moved_c", 100000, 70000);
    try p.chmod("zt/empty_dir", 0o2775);

    // Special files (not mirrored: debugfs rdump skips them; the test
    // script checks them with debugfs stat).
    const zt = try p.ino("zt");
    _ = try fs.mknod(zt, "null", ext2.S_IFCHR | 0o666, .{ .major = 1, .minor = 3 }, 0, 0);
    _ = try fs.mknod(zt, "bigdev", ext2.S_IFBLK | 0o660, .{ .major = 259, .minor = 300 }, 0, 6);
    _ = try fs.mknod(zt, "fifo", ext2.S_IFIFO | 0o644, .{}, 0, 0);

    // Error paths.
    if (fs.rmdir(zt, "many")) |_| return error.ExpectedNotEmpty else |e| if (e != error.NotEmpty) return e;
    if (fs.rename(ROOT, "zt", try p.ino("zt/a"), "loop")) |_| return error.ExpectedInvalid else |e| if (e != error.InvalidArgument) return e;
    if (fs.lookup("/zt/link_dangling")) |_| return error.ExpectedNotFound else |e| if (e != error.NotFound) return e;

    // Modify pre-existing content (populated by mke2fs -d) if present.
    if (p.exists("pre")) {
        const hello = try fs.stat(try p.ino("pre/hello.txt"));
        try p.write("pre/hello.txt", hello.size, "appended by zen\n");
        try p.write("pre/data.bin", 1000, big[0..50000]);
        try p.rename("pre/sub", "zt/sub_moved");
        try p.unlink("pre/link");
        if (p.exists("pre/huge.bin")) try p.truncate("pre/huge.bin", (1 << 20) + 5);
        if (p.exists("pre/bigdir")) {
            for (0..600) |i| {
                if (i % 4 != 0) continue;
                const name = try std.fmt.bufPrint(&name_buf, "pre/bigdir/f{d:0>4}", .{i});
                try p.unlink(name);
            }
            for (0..60) |i| {
                const name = try std.fmt.bufPrint(&name_buf, "pre/bigdir/added-by-zen-with-a-rather-long-name-{d}", .{i});
                try p.create(name, 0o644);
                try p.write(name, 0, name);
            }
            try p.mkdir("pre/bigdir/newsub", 0o755);
        }
        if (p.exists("pre/tree")) try p.rmTree("pre/tree");
    }
}

// ---------------------------------------------------------------------------

fn randomOps(p: *Pair, seed: u64, nops: usize) !void {
    const a = p.a;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const buf = try a.alloc(u8, 3 << 20);
    defer a.free(buf);
    var files: std.ArrayList([]u8) = .empty;
    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| a.free(f);
        for (dirs.items) |d| a.free(d);
        files.deinit(a);
        dirs.deinit(a);
    }
    try p.mkdir("rnd", 0o755);
    try dirs.append(a, try a.dupe(u8, "rnd"));
    var counter: usize = 0;
    for (0..nops) |step| {
        counter += 1;
        const op = rnd.uintLessThan(u32, 100);
        const dir = dirs.items[rnd.uintLessThan(usize, dirs.items.len)];
        const name = try std.fmt.allocPrint(a, "{s}/e{d}{s}", .{ dir, counter, "_long_name_padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"[0..rnd.uintLessThan(usize, 50)] });
        var keep_name = false;
        defer if (!keep_name) a.free(name);
        if (op < 30) {
            try p.create(name, 0o644);
            const len = if (rnd.uintLessThan(u8, 8) == 0) rnd.uintLessThan(usize, buf.len) else rnd.uintLessThan(usize, 20000);
            fillRandom(buf[0..len], step);
            if (len > 0) try p.write(name, 0, buf[0..len]);
            try files.append(a, name);
            keep_name = true;
        } else if (op < 40) {
            try p.mkdir(name, 0o755);
            try dirs.append(a, name);
            keep_name = true;
        } else if (op < 55 and files.items.len > 0) {
            const f = files.items[rnd.uintLessThan(usize, files.items.len)];
            const off = rnd.uintLessThan(u64, 4 << 20);
            const len = rnd.uintLessThan(usize, 100000);
            fillRandom(buf[0..len], step * 7);
            if (len > 0) try p.write(f, off, buf[0..len]);
        } else if (op < 63 and files.items.len > 0) {
            const f = files.items[rnd.uintLessThan(usize, files.items.len)];
            try p.truncate(f, rnd.uintLessThan(u64, 3 << 20));
        } else if (op < 75 and files.items.len > 0) {
            const k = rnd.uintLessThan(usize, files.items.len);
            try p.unlink(files.items[k]);
            a.free(files.swapRemove(k));
        } else if (op < 85 and files.items.len > 0) {
            const k = rnd.uintLessThan(usize, files.items.len);
            try p.rename(files.items[k], name);
            a.free(files.items[k]);
            files.items[k] = name;
            keep_name = true;
        } else if (op < 92) {
            var target: [300]u8 = undefined;
            const len = 1 + rnd.uintLessThan(usize, if (rnd.boolean()) 40 else 299);
            for (target[0..len]) |*c| c.* = "abc./xyz"[rnd.uintLessThan(usize, 8)];
            try p.symlink(target[0..len], name);
        } else if (op < 96 and dirs.items.len > 1) {
            // remove a leaf directory if it is empty
            const k = 1 + rnd.uintLessThan(usize, dirs.items.len - 1);
            const d = dirs.items[k];
            const pn = try p.parent(d);
            if (p.fs.rmdir(pn.dir, pn.name)) |_| {
                try p.m.deleteDir(d);
                a.free(dirs.swapRemove(k));
            } else |e| if (e != error.NotEmpty) return e;
        } else if (files.items.len > 0) {
            const f = files.items[rnd.uintLessThan(usize, files.items.len)];
            try p.link(f, name);
        }
    }
}

// ---------------------------------------------------------------------------

fn verifyTree(fs: *Fs, a: Allocator, hdir: std.fs.Dir, ino: Ino, path: []const u8, errors: *usize, skip_special: bool) !void {
    // Everything in the image must exist on the host and match.
    var seen = std.StringHashMap(void).init(a);
    defer {
        var ki = seen.keyIterator();
        while (ki.next()) |k| a.free(k.*);
        seen.deinit();
    }
    var it = try fs.readdir(ino, 0);
    var names: std.ArrayList(struct { name: []u8, ino: Ino }) = .empty;
    defer {
        for (names.items) |n| a.free(n.name);
        names.deinit(a);
    }
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        try names.append(a, .{ .name = try a.dupe(u8, e.name), .ino = e.ino });
    }
    for (names.items) |n| {
        try seen.put(try a.dupe(u8, n.name), {});
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, n.name });
        defer a.free(full);
        const st = try fs.stat(n.ino);
        const hst = std.posix.fstatat(hdir.fd, n.name, std.posix.AT.SYMLINK_NOFOLLOW) catch {
            if (std.mem.eql(u8, full, "/lost+found")) continue;
            // Special files are not mirrored by the ops/random commands.
            if (skip_special and st.kind != .regular and st.kind != .directory and st.kind != .symlink) continue;
            std.debug.print("MISSING on host: {s}\n", .{full});
            errors.* += 1;
            continue;
        };
        if (hst.mode & 0o170000 != st.mode & 0o170000) {
            std.debug.print("TYPE mismatch: {s}\n", .{full});
            errors.* += 1;
            continue;
        }
        if (st.kind != .symlink and (hst.mode & 0o7777) != (st.mode & 0o7777)) {
            std.debug.print("MODE mismatch: {s}: host {o} image {o}\n", .{ full, hst.mode & 0o7777, st.mode & 0o7777 });
            errors.* += 1;
        }
        switch (st.kind) {
            .directory => {
                var sub = try hdir.openDir(n.name, .{ .iterate = true });
                defer sub.close();
                try verifyTree(fs, a, sub, n.ino, full, errors, skip_special);
            },
            .symlink => {
                var b1: [4096]u8 = undefined;
                var b2: [4096]u8 = undefined;
                const t1 = try fs.readlink(n.ino, &b1);
                const t2 = try hdir.readLink(n.name, &b2);
                if (!std.mem.eql(u8, t1, t2)) {
                    std.debug.print("SYMLINK mismatch: {s}: '{s}' vs '{s}'\n", .{ full, t1, t2 });
                    errors.* += 1;
                }
            },
            .regular => {
                if (st.size != @as(u64, @intCast(hst.size))) {
                    std.debug.print("SIZE mismatch: {s}: host {d} image {d}\n", .{ full, hst.size, st.size });
                    errors.* += 1;
                    continue;
                }
                const f = try hdir.openFile(n.name, .{});
                defer f.close();
                const b1 = try a.alloc(u8, 1 << 20);
                defer a.free(b1);
                const b2 = try a.alloc(u8, 1 << 20);
                defer a.free(b2);
                var off: u64 = 0;
                while (off < st.size) {
                    const n1 = try fs.read(n.ino, off, b1);
                    const n2 = try f.preadAll(b2[0..n1], off);
                    if (n1 == 0 or n1 != n2 or !std.mem.eql(u8, b1[0..n1], b2[0..n1])) {
                        std.debug.print("CONTENT mismatch: {s} near offset {d}\n", .{ full, off });
                        errors.* += 1;
                        break;
                    }
                    off += n1;
                }
            },
            .char_device, .block_device => {
                const maj: u32 = @intCast(((hst.rdev >> 8) & 0xfff) | ((hst.rdev >> 32) & 0xfffff000));
                const min: u32 = @intCast((hst.rdev & 0xff) | ((hst.rdev >> 12) & 0xffffff00));
                if (maj != st.rdev.major or min != st.rdev.minor) {
                    std.debug.print("RDEV mismatch: {s}\n", .{full});
                    errors.* += 1;
                }
            },
            else => {},
        }
    }
    // Everything on the host must exist in the image.
    var hit = hdir.iterate();
    while (try hit.next()) |e| {
        if (!seen.contains(e.name)) {
            std.debug.print("MISSING in image: {s}/{s}\n", .{ path, e.name });
            errors.* += 1;
        }
    }
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 3) die("usage: fstest ops|random|verify|expect-unsupported|check <img> ...", .{});
    const cmd = argv[1];
    const img = argv[2];
    var dev: host.FileDevice = undefined;
    if (std.mem.eql(u8, cmd, "expect-unsupported")) {
        dev = try host.FileDevice.open(img, false);
        for ([_]bool{ false, true }) |ro| {
            if (Fs.mount(a, dev.device(), .{ .read_only = ro })) |fs| {
                fs.deinit();
                die("mount (read_only={}) unexpectedly succeeded", .{ro});
            } else |e| if (e != error.Unsupported) die("expected Unsupported, got {s}", .{@errorName(e)});
        }
        std.debug.print("mount refused with error.Unsupported (ok)\n", .{});
        return;
    }
    if (std.mem.eql(u8, cmd, "expect-readonly")) {
        // Unknown RO_COMPAT features: read-write refused, read-only allowed.
        dev = try host.FileDevice.open(img, false);
        if (Fs.mount(a, dev.device(), .{})) |fs| {
            fs.deinit();
            die("read-write mount unexpectedly succeeded", .{});
        } else |e| if (e != error.Unsupported) die("expected Unsupported, got {s}", .{@errorName(e)});
        const fs = Fs.mount(a, dev.device(), .{ .read_only = true }) catch |e| die("read-only mount failed: {s}", .{@errorName(e)});
        defer fs.deinit();
        var it = try fs.readdir(ROOT, 0);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        if (n < 3) die("root directory looks wrong ({d} entries)", .{n});
        if (fs.create(ROOT, "x", 0o644, 0, 0)) |_| die("create on read-only mount succeeded", .{}) else |e| if (e != error.ReadOnly) return e;
        std.debug.print("read-write refused, read-only works (ok)\n", .{});
        return;
    }
    if (std.mem.eql(u8, cmd, "check")) {
        const fs = openImage(img, &dev, true);
        internalCheck(fs);
        fs.deinit();
        return;
    }
    if (argv.len < 4) die("missing directory argument", .{});
    var hdir = std.fs.cwd().openDir(argv[3], .{ .iterate = true }) catch |e| die("open {s}: {s}", .{ argv[3], @errorName(e) });
    defer hdir.close();
    if (std.mem.eql(u8, cmd, "verify")) {
        const fs = openImage(img, &dev, true);
        var errors: usize = 0;
        try verifyTree(fs, a, hdir, ROOT, "", &errors, false);
        internalCheck(fs);
        fs.deinit();
        if (errors != 0) die("verify: {d} differences", .{errors});
        std.debug.print("verify: image matches {s}\n", .{argv[3]});
        return;
    }
    const fs = openImage(img, &dev, false);
    var pair: Pair = .{ .fs = fs, .m = hdir, .a = a };
    if (std.mem.eql(u8, cmd, "ops")) {
        scenario(&pair) catch |e| {
            if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
            die("scenario failed: {s}", .{@errorName(e)});
        };
    } else if (std.mem.eql(u8, cmd, "random")) {
        if (argv.len < 6) die("usage: fstest random <img> <dir> <seed> <ops>", .{});
        const seed = try std.fmt.parseInt(u64, argv[4], 10);
        const nops = try std.fmt.parseInt(usize, argv[5], 10);
        randomOps(&pair, seed, nops) catch |e| {
            if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
            die("random ops failed: {s}", .{@errorName(e)});
        };
    } else die("unknown command {s}", .{cmd});
    internalCheck(fs);
    fs.unmount() catch |e| die("unmount: {s}", .{@errorName(e)});
    // Re-mount and verify our own view against the mirror as well.
    const fs2 = openImage(img, &dev, true);
    var errors: usize = 0;
    try verifyTree(fs2, a, hdir, ROOT, "", &errors, true);
    fs2.deinit();
    if (errors != 0) die("post-{s} verify: {d} differences", .{ cmd, errors });
}
