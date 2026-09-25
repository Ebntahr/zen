//! Window-server modules exposed for host tools (desktop previews).
pub const wm = @import("wm.zig");
pub const state = @import("state.zig");
pub const compositor = @import("compositor.zig");
pub const chrome = @import("chrome.zig");
pub const protocol = @import("protocol.zig");
pub const cursor = @import("cursor.zig");
