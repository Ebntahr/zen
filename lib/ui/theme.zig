//! Visual design tokens for the Zen desktop (macOS 26–inspired).
//! Colors are straight-alpha 0xAARRGGBB; the renderer premultiplies.

pub const Accent = enum(u8) {
    blue,
    purple,
    pink,
    red,
    orange,
    yellow,
    green,
    graphite,

    pub fn color(self: Accent, dark: bool) u32 {
        return switch (self) {
            .blue => if (dark) 0xFF0A84FF else 0xFF007AFF,
            .purple => if (dark) 0xFFBF5AF2 else 0xFFAF52DE,
            .pink => if (dark) 0xFFFF375F else 0xFFFF2D55,
            .red => if (dark) 0xFFFF453A else 0xFFFF3B30,
            .orange => if (dark) 0xFFFF9F0A else 0xFFFF9500,
            .yellow => if (dark) 0xFFFFD60A else 0xFFFFCC00,
            .green => if (dark) 0xFF30D158 else 0xFF34C759,
            .graphite => if (dark) 0xFF98989D else 0xFF8E8E93,
        };
    }

    pub fn name(self: Accent) []const u8 {
        return switch (self) {
            .blue => "Blue",
            .purple => "Purple",
            .pink => "Pink",
            .red => "Red",
            .orange => "Orange",
            .yellow => "Yellow",
            .green => "Green",
            .graphite => "Graphite",
        };
    }
};

pub const Theme = struct {
    dark: bool,
    accent: u32,

    window_bg: u32,
    content_bg: u32,
    /// Translucent sidebar / toolbar material (vibrancy).
    sidebar_bg: u32,
    toolbar_bg: u32,
    label: u32,
    secondary_label: u32,
    tertiary_label: u32,
    separator: u32,
    control_bg: u32,
    control_border: u32,
    control_pressed: u32,
    field_bg: u32,
    selection_inactive: u32,
    hover: u32,
    shadow: u32,
    alternate_row: u32,

    pub fn light(accent: Accent) Theme {
        return .{
            .dark = false,
            .accent = accent.color(false),
            .window_bg = 0xFFF5F5F7,
            .content_bg = 0xFFFFFFFF,
            .sidebar_bg = 0xB8EEEEF2,
            .toolbar_bg = 0xCCF7F7F9,
            .label = 0xE0000000,
            .secondary_label = 0x85000000,
            .tertiary_label = 0x45000000,
            .separator = 0x1C000000,
            .control_bg = 0xFFFFFFFF,
            .control_border = 0x26000000,
            .control_pressed = 0xFFE4E4E8,
            .field_bg = 0xFFFFFFFF,
            .selection_inactive = 0x1F000000,
            .hover = 0x0F000000,
            .shadow = 0x40000000,
            .alternate_row = 0xFFF6F6F8,
        };
    }

    pub fn darkTheme(accent: Accent) Theme {
        return .{
            .dark = true,
            .accent = accent.color(true),
            .window_bg = 0xFF1F1F22,
            .content_bg = 0xFF1C1C1E,
            .sidebar_bg = 0xB8262630,
            .toolbar_bg = 0xCC2A2A2E,
            .label = 0xEBFFFFFF,
            .secondary_label = 0x8CFFFFFF,
            .tertiary_label = 0x45FFFFFF,
            .separator = 0x24FFFFFF,
            .control_bg = 0xFF3A3A3D,
            .control_border = 0x1FFFFFFF,
            .control_pressed = 0xFF4A4A4E,
            .field_bg = 0xFF2B2B2E,
            .selection_inactive = 0x29FFFFFF,
            .hover = 0x14FFFFFF,
            .shadow = 0x80000000,
            .alternate_row = 0xFF232326,
        };
    }

    pub fn get(dark: bool, accent: Accent) Theme {
        return if (dark) darkTheme(accent) else light(accent);
    }
};

/// Metrics shared by all controls.
pub const Metrics = struct {
    pub const body_size: f32 = 13;
    pub const small_size: f32 = 11;
    pub const headline_size: f32 = 15;
    pub const title_size: f32 = 22;
    pub const large_title_size: f32 = 28;
    pub const control_height: i32 = 26;
    pub const large_control_height: i32 = 32;
    pub const corner_radius: i32 = 7;
    pub const window_radius: i32 = 16;
    pub const titlebar_height: i32 = 38;
    pub const toolbar_height: i32 = 52;
    pub const sidebar_width: i32 = 220;
    pub const row_height: i32 = 28;
    pub const spacing: i32 = 8;
    pub const padding: i32 = 16;
};

/// Traffic-light colors.
pub const traffic_close: u32 = 0xFFFF5F57;
pub const traffic_minimize: u32 = 0xFFFEBC2E;
pub const traffic_zoom: u32 = 0xFF28C840;
pub const traffic_inactive_light: u32 = 0xFFD1D1D6;
pub const traffic_inactive_dark: u32 = 0xFF4A4A4E;
