//! GlassKit: the Zen OS GUI toolkit.

pub const client = @import("client.zig");
pub const theme = @import("theme.zig");
pub const fonts = @import("fonts.zig");
pub const ui = @import("ui.zig");
pub const app = @import("app.zig");
pub const run = app.run;
pub const renderOnce = app.renderOnce;

pub const Window = client.Window;
pub const Ui = ui.Ui;
pub const Rect = ui.Rect;
pub const Theme = theme.Theme;
pub const FontSet = fonts.FontSet;
pub const TextState = ui.TextState;
pub const ScrollState = ui.ScrollState;
pub const pm = ui.pm;

test {
    _ = fonts;
    _ = theme;
}
