//! Zen OS terminal emulation core (xterm-compatible).
//!
//! Pure Zig + std, OS-independent: no rendering, no system calls; all memory
//! comes from the allocator passed to `Terminal.init`.
//!
//!   const vt = @import("vt");
//!   var term = try vt.Terminal.init(gpa, 80, 24, 10_000);
//!   defer term.deinit();
//!   term.feed(pty_output);
//!   _ = pty.write(term.takeResponse());
//!
//! See terminal.zig for the full API.

pub const cell = @import("cell.zig");
pub const parser = @import("parser.zig");
pub const screen = @import("screen.zig");
pub const terminal = @import("terminal.zig");
pub const input = @import("input.zig");
pub const palette = @import("palette.zig");
pub const wcwidth = @import("wcwidth.zig");

pub const Terminal = terminal.Terminal;
pub const Cell = cell.Cell;
pub const Color = cell.Color;
pub const Attrs = cell.Attrs;
pub const Pos = terminal.Pos;
pub const Range = terminal.Range;
pub const Cursor = terminal.Cursor;
pub const CursorStyle = terminal.CursorStyle;
pub const Modes = terminal.Modes;
pub const Pen = terminal.Pen;
pub const LineRef = terminal.LineRef;
pub const BellCallback = terminal.BellCallback;
pub const CursorSnapshot = terminal.CursorSnapshot;
pub const Charset = terminal.Charset;
pub const Parser = parser.Parser;

pub const Key = input.Key;
pub const KeypadKey = input.KeypadKey;
pub const Mods = input.Mods;
pub const KeyModes = input.KeyModes;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;
pub const MouseAction = input.MouseAction;
pub const MouseTracking = input.MouseTracking;
pub const MouseEncoding = input.MouseEncoding;
pub const encodeKey = input.encodeKey;

pub const Theme = palette.Theme;
pub const Rgb = palette.Rgb;
pub const default_palette = palette.default_palette;

pub const codepointWidth = wcwidth.codepointWidth;

test {
    _ = cell;
    _ = parser;
    _ = screen;
    _ = terminal;
    _ = input;
    _ = palette;
    _ = wcwidth;
    _ = @import("tests.zig");
}
