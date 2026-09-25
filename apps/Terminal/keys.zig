//! Keyboard handling: window-server key events (Linux evdev codes, `Mods`
//! bits and layout-produced text) → Terminal commands or vt key presses.

const std = @import("std");
const abi = @import("abi");
const vt = @import("vt");

const Key = abi.input.Key;
const Mods = abi.window.Mods;

/// App-level commands (from Cmd shortcuts or the menu bar).
pub const Command = enum {
    about,
    quit,
    new_window,
    close_window,
    clear,
    copy,
    paste,
    select_all,
    bigger,
    smaller,
    default_size,
    scroll_line_up,
    scroll_line_down,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
};

/// Command for a Cmd-modified key, or null if Cmd+key has no meaning.
pub fn commandFor(code: u16, mods: u32) ?Command {
    if (mods & Mods.cmd == 0) return null;
    return switch (code) {
        Key.c => .copy,
        Key.v => .paste,
        Key.a => .select_all,
        Key.k => .clear,
        Key.n => .new_window,
        Key.w => .close_window,
        Key.q => .quit,
        Key.equal => .bigger, // Cmd+= and Cmd+Shift+= (Cmd++)
        Key.minus => .smaller,
        Key.@"0" => .default_size,
        Key.up => .scroll_line_up,
        Key.down => .scroll_line_down,
        Key.pageup => .scroll_page_up,
        Key.pagedown => .scroll_page_down,
        Key.home => .scroll_top,
        Key.end => .scroll_bottom,
        else => null,
    };
}

pub fn vtMods(mods: u32) vt.Mods {
    return .{
        .shift = mods & Mods.shift != 0,
        .alt = mods & Mods.alt != 0,
        .ctrl = mods & Mods.ctrl != 0,
        .super = mods & Mods.cmd != 0,
    };
}

/// Non-text keys identified by their evdev code.
fn specialKey(code: u16) ?vt.Key {
    return switch (code) {
        Key.enter => .enter,
        Key.kpenter => .{ .kp = .enter },
        Key.tab => .tab,
        Key.backspace => .backspace,
        Key.esc => .escape,
        Key.up => .up,
        Key.down => .down,
        Key.left => .left,
        Key.right => .right,
        Key.home => .home,
        Key.end => .end,
        Key.insert => .insert,
        Key.delete => .delete,
        Key.pageup => .page_up,
        Key.pagedown => .page_down,
        Key.f1...Key.f10 => .{ .f = @intCast(code - Key.f1 + 1) },
        Key.f11 => .{ .f = 11 },
        Key.f12 => .{ .f = 12 },
        else => null,
    };
}

/// Encode a key press for the pty into `out` (at least 64 bytes).
/// `text` is the UTF-8 the window server produced for the key (empty while
/// Ctrl or Cmd is held). Returns the bytes to send (may be empty).
pub fn encode(term: *const vt.Terminal, code: u16, mods: u32, text: []const u8, out: []u8) []const u8 {
    const m = vtMods(mods);
    if (specialKey(code)) |k| return term.encodeKey(k, m, out);

    if (mods & Mods.ctrl != 0 or text.len == 0) {
        // Ctrl combinations arrive without text: rebuild the character from
        // the US layout so ctrl-codes (Ctrl+C, Ctrl+[, Ctrl+Space...) work.
        const ch = abi.input.keyToChar(code, mods & Mods.shift != 0, false, false);
        if (ch == 0) return out[0..0];
        return term.encodeKey(.{ .char = ch }, m, out);
    }

    // Plain text, possibly several code points (dead keys / IMEs).
    var n: usize = 0;
    const view = std.unicode.Utf8View.init(text) catch return out[0..0];
    var it = view.iterator();
    var tmp: [32]u8 = undefined;
    while (it.nextCodepoint()) |cp| {
        const s = term.encodeKey(.{ .char = cp }, m, &tmp);
        if (n + s.len > out.len) break;
        @memcpy(out[n .. n + s.len], s);
        n += s.len;
    }
    return out[0..n];
}

test "key encoding" {
    const t = std.testing;
    var term = try vt.Terminal.init(t.allocator, 20, 5, 10);
    defer term.deinit();
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a", encode(&term, Key.a, 0, "a", &buf));
    try t.expectEqualStrings("A", encode(&term, Key.a, Mods.shift, "A", &buf));
    try t.expectEqualStrings("\r", encode(&term, Key.enter, 0, "\n", &buf));
    try t.expectEqualStrings("\t", encode(&term, Key.tab, 0, "\t", &buf));
    try t.expectEqualStrings("\x7f", encode(&term, Key.backspace, 0, "", &buf));
    try t.expectEqualStrings("\x03", encode(&term, Key.c, Mods.ctrl, "", &buf));
    try t.expectEqualStrings("\x1b", encode(&term, Key.esc, 0, "", &buf));
    try t.expectEqualStrings("\x1bx", encode(&term, Key.x, Mods.alt, "x", &buf));
    try t.expectEqualStrings("\x1b[A", encode(&term, Key.up, 0, "", &buf));
    try t.expectEqualStrings("\x1b[1;5D", encode(&term, Key.left, Mods.ctrl, "", &buf));
    try t.expectEqualStrings("\x1bOP", encode(&term, Key.f1, 0, "", &buf));
    try t.expectEqualStrings("\x1b[24~", encode(&term, Key.f12, 0, "", &buf));
    try t.expectEqualStrings("é", encode(&term, Key.e, 0, "é", &buf));
    term.feed("\x1b[?1h"); // application cursor keys
    try t.expectEqualStrings("\x1bOA", encode(&term, Key.up, 0, "", &buf));

    try t.expectEqual(Command.copy, commandFor(Key.c, Mods.cmd).?);
    try t.expectEqual(Command.bigger, commandFor(Key.equal, Mods.cmd | Mods.shift).?);
    try t.expect(commandFor(Key.c, Mods.ctrl) == null);
}
