//! Zen OS application binary interface shared by the kernel and user space.

pub const scheme = @import("scheme.zig");
pub const syscall = @import("syscall.zig");
pub const sandbox = @import("sandbox.zig");
pub const window = @import("window.zig");
pub const display = @import("display.zig");
pub const input = @import("input.zig");

/// Kernel name reported by uname(2).
pub const sysname = "Zen";
pub const os_name = "Zen OS";
pub const os_version = "1.0";
pub const os_codename = "Golden Gate";

test {
    _ = scheme;
    _ = syscall;
    _ = sandbox;
    _ = window;
    _ = display;
    _ = input;
}
