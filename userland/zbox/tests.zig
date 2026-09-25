//! Unit test root: `zig test userland/zbox/tests.zig`
const std = @import("std");

test {
    _ = @import("common.zig");
    _ = @import("cmd/printf.zig");
    _ = @import("regex.zig");
    _ = @import("cmd/sed.zig");
    _ = @import("cmd/grep.zig");
}
