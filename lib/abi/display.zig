//! `display:` scheme (GPU driver → window server).
//!
//! `open("display:0")` returns a handle for the first scanout.
//!   * `read(fd)` → `Info`. The first read returns immediately, later reads
//!     block until the mode changes (e.g. the QEMU window was resized).
//!   * `mmap(fd, 0, info.stride * info.height)` → the framebuffer
//!     (B8G8R8A8 / X8R8G8B8 little-endian u32 pixels).
//!   * `write(fd, []Rect)` → copy the given rectangles to the screen.

pub const Format = enum(u32) {
    /// u32 0xAARRGGBB / 0xXXRRGGBB in memory as B, G, R, A bytes.
    bgra8888 = 0,
    _,
};

pub const Info = extern struct {
    width: u32,
    height: u32,
    /// Bytes per row.
    stride: u32,
    format: Format = .bgra8888,
    refresh_hz: u32 = 60,
    /// UI scale factor (1 = standard, 2 = Retina-like).
    scale: u32 = 1,
    reserved: [2]u32 = .{ 0, 0 },
};

pub const Rect = extern struct { x: u32, y: u32, w: u32, h: u32 };

/// `display:0/cursor`: a 64×64 hardware cursor plane.
///   * `mmap(fd, 0, CURSOR_SIZE * CURSOR_SIZE * 4)` → cursor image
///     (straight-alpha B8G8R8A8).
///   * `write(fd, CursorCmd)` → move the cursor and/or upload the image.
pub const CURSOR_SIZE: u32 = 64;

pub const CursorCmd = extern struct {
    x: i32,
    y: i32,
    hot_x: u32 = 0,
    hot_y: u32 = 0,
    /// 1 = the image in the mapped buffer changed.
    update_image: u32 = 0,
    /// 0 hides the cursor.
    visible: u32 = 1,
};
