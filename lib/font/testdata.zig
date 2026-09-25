//! Test helper: loads the bundled fonts from `assets/fonts/`.
//! Tests are expected to run from the repository root (`zig test lib/font/root.zig`).

const std = @import("std");

const search_dirs = [_][]const u8{ "assets/fonts/", "../../assets/fonts/" };

/// Reads a bundled font into memory owned by `std.testing.allocator`.
/// Skips the calling test when the assets directory cannot be found.
pub fn load(name: []const u8) ![]u8 {
    for (search_dirs) |dir| {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}{s}", .{ dir, name });
        return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 16 << 20) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
}
