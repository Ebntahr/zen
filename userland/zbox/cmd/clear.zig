const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: clear [-x]
    \\Clear the terminal screen.
    \\
    \\  -x    do not try to clear the scrollback buffer
    \\
;
pub const help_reset =
    \\Usage: reset
    \\Reset the terminal: restore sane terminal modes and clear the screen.
    \\
;

pub fn main(args: c.Args) !u8 {
    var keep_scrollback = false;
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'x' => keep_scrollback = true,
            'T', 'V' => {},
            else => p.bad(o),
        },
        else => p.bad(o),
    };
    try c.out.writeAll("\x1b[H\x1b[2J");
    if (!keep_scrollback) try c.out.writeAll("\x1b[3J");
    return 0;
}

pub fn mainReset(args: c.Args) !u8 {
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        else => {},
    };
    const stty = @import("stty.zig");
    stty.makeSane(0) catch {};
    // RIS (full reset), then clear screen
    try c.out.writeAll("\x1bc\x1b[!p\x1b[?3;4l\x1b[4l\x1b>\x1b[?1049l\x1b[?25h\x1b[0m\x1b[H\x1b[2J");
    return 0;
}
