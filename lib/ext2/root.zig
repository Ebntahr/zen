//! ext2 filesystem library for Zen OS.
//!
//! OS-independent: all storage access goes through a `BlockDevice` and all
//! memory comes from the caller's allocator, so this runs unchanged inside
//! the user-space file server and in host tools.
//!
//! Quick start:
//! ```
//! var md = try ext2.MemDevice.init(gpa, 16 << 20);
//! try ext2.mkfs(gpa, md.device(), .{ .label = "root" });
//! const fs = try ext2.Fs.mount(gpa, md.device(), .{});
//! defer fs.unmount() catch {};
//! const ino = try fs.create(ext2.ROOT_INO, "hello", 0o644, 0, 0);
//! _ = try fs.write(ino, 0, "hi\n");
//! ```
const std = @import("std");

pub const format = @import("format.zig");
const device = @import("device.zig");
const fs_mod = @import("fs.zig");
const errors = @import("errors.zig");
const mkfs_mod = @import("mkfs.zig");
const check_mod = @import("check.zig");

pub const BlockDevice = device.BlockDevice;
pub const MemDevice = device.MemDevice;

pub const Error = errors.Error;
pub const errno = errors.errno;

pub const Fs = fs_mod.Fs;
pub const Ino = fs_mod.Ino;
pub const ROOT_INO = fs_mod.ROOT_INO;
pub const FileType = fs_mod.FileType;
pub const Dev = fs_mod.Dev;
pub const Stat = fs_mod.Stat;
pub const StatFs = fs_mod.StatFs;
pub const DirEntry = fs_mod.DirEntry;
pub const DirIterator = fs_mod.DirIterator;
pub const MountOptions = fs_mod.MountOptions;
pub const ParentAndName = fs_mod.ParentAndName;

pub const mkfs = mkfs_mod.mkfs;
pub const MkfsOptions = mkfs_mod.MkfsOptions;

pub const check = check_mod.check;
pub const CheckReport = check_mod.Report;

// Mode bits, re-exported for convenience.
pub const S_IFMT = format.S_IFMT;
pub const S_IFSOCK = format.S_IFSOCK;
pub const S_IFLNK = format.S_IFLNK;
pub const S_IFREG = format.S_IFREG;
pub const S_IFBLK = format.S_IFBLK;
pub const S_IFDIR = format.S_IFDIR;
pub const S_IFCHR = format.S_IFCHR;
pub const S_IFIFO = format.S_IFIFO;

test {
    std.testing.refAllDecls(@This());
    _ = @import("format.zig");
    _ = @import("device.zig");
    _ = @import("cache.zig");
    _ = @import("dir.zig");
    _ = @import("fs.zig");
    _ = @import("mkfs.zig");
    _ = @import("check.zig");
    _ = @import("tests/unit.zig");
}
