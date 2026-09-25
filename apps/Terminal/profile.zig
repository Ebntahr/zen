//! Terminal color profiles: "Clear Dark" (translucent, the default) and
//! "Clear Light", chosen by the system appearance.
//!
//! The ANSI palettes follow the macOS system colors, tuned so every entry
//! stays readable on its background. Colors 16-255 come from the standard
//! xterm palette (see vt.palette).

const std = @import("std");
const vt = @import("vt");
const gfx = @import("gfx");

const Rgb = vt.Rgb;
const Color = gfx.Color;

pub const Profile = struct {
    /// Colors handed to the emulator (default fg/bg, cursor, ANSI 0-15).
    vt: vt.Theme,
    /// Opacity of the default background (and cell backgrounds).
    bg_alpha: u8,
    /// Premultiplied default background pixel.
    bg_pm: u32,
    /// Premultiplied block cursor color and the text color drawn on it.
    cursor_pm: u32,
    cursor_text_pm: u32,
    /// Hollow cursor (window not focused).
    cursor_hollow_pm: u32,
    /// Premultiplied selection overlays (focused / not focused).
    selection_pm: u32,
    selection_inactive_pm: u32,
    dark: bool,

    pub fn get(dark: bool, accent: u32, opaque_bg: bool) Profile {
        const theme = if (dark) dark_theme else light_theme;
        const bg_alpha: u8 = if (opaque_bg) 255 else if (dark) 0xE0 else 0xF0;
        const acc = accent | 0xFF000000;
        return .{
            .vt = theme,
            .bg_alpha = bg_alpha,
            .bg_pm = rgbPm(theme.bg, bg_alpha),
            .cursor_pm = rgbPm(theme.cursor, 255),
            .cursor_text_pm = rgbPm(theme.bg, 255),
            .cursor_hollow_pm = rgbPm(theme.cursor, 0xC0),
            .selection_pm = Color.withAlpha(acc, if (dark) 0x70 else 0x48),
            .selection_inactive_pm = if (dark) Color.rgba(255, 255, 255, 0x2E) else Color.rgba(0, 0, 0, 0x1F),
            .dark = dark,
        };
    }
};

/// Premultiplied pixel from an RGB triple and an opacity.
pub inline fn rgbPm(c: Rgb, a: u8) u32 {
    return Color.rgba(c[0], c[1], c[2], a);
}

pub const dark_ansi: [16]Rgb = .{
    .{ 0x3A, 0x3A, 0x3C }, // black (a visible dark gray)
    .{ 0xFF, 0x5F, 0x57 }, // red
    .{ 0x32, 0xD7, 0x4B }, // green
    .{ 0xFF, 0xD6, 0x0A }, // yellow
    .{ 0x2E, 0x94, 0xFF }, // blue
    .{ 0xC7, 0x6B, 0xF5 }, // magenta
    .{ 0x64, 0xD2, 0xFF }, // cyan
    .{ 0xC7, 0xC7, 0xCC }, // white
    .{ 0x8E, 0x8E, 0x93 }, // bright black
    .{ 0xFF, 0x80, 0x78 }, // bright red
    .{ 0x5C, 0xE6, 0x7C }, // bright green
    .{ 0xFF, 0xE6, 0x6B }, // bright yellow
    .{ 0x6C, 0xB6, 0xFF }, // bright blue
    .{ 0xDC, 0x98, 0xFF }, // bright magenta
    .{ 0x96, 0xE6, 0xFF }, // bright cyan
    .{ 0xFF, 0xFF, 0xFF }, // bright white
};

pub const light_ansi: [16]Rgb = .{
    .{ 0x1D, 0x1D, 0x1F }, // black
    .{ 0xD7, 0x1F, 0x1F }, // red
    .{ 0x1E, 0x8A, 0x3C }, // green
    .{ 0xA8, 0x6E, 0x00 }, // yellow (amber, readable on white)
    .{ 0x0B, 0x5C, 0xD6 }, // blue
    .{ 0x93, 0x3F, 0xB8 }, // magenta
    .{ 0x00, 0x7C, 0xA8 }, // cyan
    .{ 0xA8, 0xA8, 0xAD }, // white (light gray)
    .{ 0x6E, 0x6E, 0x73 }, // bright black
    .{ 0xFF, 0x3B, 0x30 }, // bright red
    .{ 0x28, 0xB4, 0x50 }, // bright green
    .{ 0xD6, 0x96, 0x00 }, // bright yellow
    .{ 0x00, 0x7A, 0xFF }, // bright blue
    .{ 0xAF, 0x52, 0xDE }, // bright magenta
    .{ 0x1C, 0xA3, 0xDB }, // bright cyan
    .{ 0xD8, 0xD8, 0xDD }, // bright white
};

pub const dark_theme: vt.Theme = .{
    .fg = .{ 0xE8, 0xE8, 0xED },
    .bg = .{ 0x1C, 0x1C, 0x1E },
    .cursor = .{ 0xD6, 0xD6, 0xDB },
    .selection_bg = .{ 0x2A, 0x4E, 0x7A },
    .ansi = dark_ansi,
};

pub const light_theme: vt.Theme = .{
    .fg = .{ 0x1D, 0x1D, 0x1F },
    .bg = .{ 0xFF, 0xFF, 0xFF },
    .cursor = .{ 0x7C, 0x7C, 0x82 },
    .selection_bg = .{ 0xB4, 0xD5, 0xFE },
    .ansi = light_ansi,
};

test "profiles" {
    const d = Profile.get(true, 0xFF0A84FF, false);
    try std.testing.expectEqual(@as(u32, 0xE0), d.bg_pm >> 24);
    const o = Profile.get(true, 0xFF0A84FF, true);
    try std.testing.expectEqual(@as(u32, 0xFF1C1C1E), o.bg_pm);
    const l = Profile.get(false, 0xFF007AFF, false);
    try std.testing.expect(!l.dark);
    try std.testing.expectEqual(@as(u32, 0xF0F0F0F0), l.bg_pm);
}
