//! Encoding of keyboard, mouse, focus and paste input into the byte
//! sequences an xterm-compatible application expects on its pty.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KeypadKey = enum { k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, decimal, divide, multiply, subtract, add, enter, equal };

pub const Key = union(enum) {
    /// Text input: the already-shifted character produced by the layout
    /// (e.g. 'A' for Shift+a). Encoded as UTF-8.
    char: u21,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    /// Function key F1..F20.
    f: u8,
    /// Numeric keypad key (honors DECKPAM/DECKPNM).
    kp: KeypadKey,
};

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    _pad: u4 = 0,

    pub fn any(m: Mods) bool {
        return m.shift or m.alt or m.ctrl or m.super;
    }

    /// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl + 8*meta.
    pub fn param(m: Mods) u8 {
        var p: u8 = 1;
        if (m.shift) p += 1;
        if (m.alt) p += 2;
        if (m.ctrl) p += 4;
        if (m.super) p += 8;
        return p;
    }
};

/// Terminal modes that affect key encoding.
pub const KeyModes = struct {
    app_cursor: bool = false,
    app_keypad: bool = false,
    /// LNM: Enter sends CR LF.
    linefeed_newline: bool = false,
};

/// Bounded output buffer; writes that don't fit mark it failed.
const Out = struct {
    buf: []u8,
    len: usize = 0,
    ok: bool = true,

    fn byte(self: *Out, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        } else self.ok = false;
    }
    fn bytes(self: *Out, s: []const u8) void {
        for (s) |b| self.byte(b);
    }
    fn num(self: *Out, n: usize) void {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
        self.bytes(s);
    }
    fn utf8(self: *Out, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch {
            self.bytes("\xef\xbf\xbd");
            return;
        };
        self.bytes(tmp[0..n]);
    }
    fn result(self: *const Out) []const u8 {
        return if (self.ok) self.buf[0..self.len] else self.buf[0..0];
    }
};

/// Control code for Ctrl+`c`, following xterm, or null if none.
fn ctrlCode(c: u21) ?u8 {
    return switch (c) {
        'a'...'z' => @intCast(c - 'a' + 1),
        'A'...'Z' => @intCast(c - 'A' + 1),
        '@', ' ', '2', '`' => 0x00,
        '[', '3', '{' => 0x1b,
        '\\', '4', '|' => 0x1c,
        ']', '5', '}' => 0x1d,
        '^', '6', '~' => 0x1e,
        '_', '7', '/', '-' => 0x1f,
        '8', '?' => 0x7f,
        else => null,
    };
}

/// CSI <code> ; <mods> ~   (or CSI <code> ~ with no modifiers)
fn tilde(o: *Out, code: u8, mods: Mods) void {
    o.bytes("\x1b[");
    o.num(code);
    if (mods.any()) {
        o.byte(';');
        o.num(mods.param());
    }
    o.byte('~');
}

/// Cursor-style key: SS3 x / CSI x, or CSI 1 ; <mods> x with modifiers.
fn letterKey(o: *Out, final: u8, mods: Mods, ss3: bool) void {
    if (mods.any()) {
        o.bytes("\x1b[1;");
        o.num(mods.param());
        o.byte(final);
    } else if (ss3) {
        o.bytes("\x1bO");
        o.byte(final);
    } else {
        o.bytes("\x1b[");
        o.byte(final);
    }
}

/// Encode a key press into `out`. Returns the bytes to send (empty if the key
/// produces nothing or `out` is too small; 32 bytes is always enough).
pub fn encodeKey(key: Key, mods: Mods, modes: KeyModes, out: []u8) []const u8 {
    var o: Out = .{ .buf = out };
    switch (key) {
        .char => |c| {
            if (mods.alt) o.byte(0x1b);
            if (mods.ctrl) {
                if (ctrlCode(c)) |code| {
                    o.byte(code);
                    return o.result();
                }
            }
            o.utf8(c);
        },
        .enter => {
            if (mods.alt) o.byte(0x1b);
            o.byte('\r');
            if (modes.linefeed_newline) o.byte('\n');
        },
        .tab => {
            if (mods.shift) {
                o.bytes("\x1b[Z");
            } else {
                if (mods.alt) o.byte(0x1b);
                o.byte('\t');
            }
        },
        .backspace => {
            if (mods.alt) o.byte(0x1b);
            o.byte(if (mods.ctrl) 0x08 else 0x7f);
        },
        .escape => {
            if (mods.alt) o.byte(0x1b);
            o.byte(0x1b);
        },
        .up => letterKey(&o, 'A', mods, modes.app_cursor),
        .down => letterKey(&o, 'B', mods, modes.app_cursor),
        .right => letterKey(&o, 'C', mods, modes.app_cursor),
        .left => letterKey(&o, 'D', mods, modes.app_cursor),
        .home => letterKey(&o, 'H', mods, modes.app_cursor),
        .end => letterKey(&o, 'F', mods, modes.app_cursor),
        .insert => tilde(&o, 2, mods),
        .delete => tilde(&o, 3, mods),
        .page_up => tilde(&o, 5, mods),
        .page_down => tilde(&o, 6, mods),
        .f => |n| switch (n) {
            1...4 => letterKey(&o, "PQRS"[n - 1], mods, true),
            5...20 => {
                const codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34 };
                tilde(&o, codes[n - 5], mods);
            },
            else => {},
        },
        .kp => |k| {
            if (modes.app_keypad) {
                const finals = "pqrstuvwxynojmkMX";
                letterKey(&o, finals[@intFromEnum(k)], mods, true);
            } else {
                const chars = "0123456789./*-+\r=";
                const ch = chars[@intFromEnum(k)];
                if (mods.alt) o.byte(0x1b);
                o.byte(ch);
                if (k == .enter and modes.linefeed_newline) o.byte('\n');
            }
        },
    }
    return o.result();
}

// ---------------------------------------------------------------------------
// Mouse

pub const MouseTracking = enum {
    none,
    /// 9: X10 compatibility, button presses only.
    x10,
    /// 1000: presses and releases.
    normal,
    /// 1002: plus motion while a button is held.
    button_event,
    /// 1003: plus all motion.
    any_event,
};

pub const MouseEncoding = enum {
    default,
    /// 1005
    utf8,
    /// 1006
    sgr,
    /// 1015
    urxvt,
};

pub const MouseButton = enum { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right };
pub const MouseAction = enum { press, release, motion };

pub const MouseEvent = struct {
    action: MouseAction,
    button: MouseButton = .none,
    /// 0-based cell coordinates within the screen.
    row: usize,
    col: usize,
    mods: Mods = .{},
};

fn isWheel(b: MouseButton) bool {
    return @intFromEnum(b) >= @intFromEnum(MouseButton.wheel_up);
}

/// Encode a mouse event for the active tracking mode/encoding. Returns an
/// empty slice when the event must not be reported.
pub fn encodeMouse(ev: MouseEvent, tracking: MouseTracking, encoding: MouseEncoding, out: []u8) []const u8 {
    var o: Out = .{ .buf = out };
    switch (tracking) {
        .none => return o.buf[0..0],
        .x10 => if (ev.action != .press or isWheel(ev.button) or ev.button == .none) return o.buf[0..0],
        .normal => if (ev.action == .motion) return o.buf[0..0],
        .button_event => if (ev.action == .motion and ev.button == .none) return o.buf[0..0],
        .any_event => {},
    }
    if (ev.action == .release and isWheel(ev.button)) return o.buf[0..0];

    var code: usize = switch (ev.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
    };
    if (ev.action == .release and encoding != .sgr) code = 3;
    if (ev.action == .motion) code += 32;
    if (tracking != .x10) {
        if (ev.mods.shift) code += 4;
        if (ev.mods.alt) code += 8;
        if (ev.mods.ctrl) code += 16;
    }
    const x = ev.col + 1;
    const y = ev.row + 1;
    switch (encoding) {
        .sgr => {
            o.bytes("\x1b[<");
            o.num(code);
            o.byte(';');
            o.num(x);
            o.byte(';');
            o.num(y);
            o.byte(if (ev.action == .release) 'm' else 'M');
        },
        .urxvt => {
            o.bytes("\x1b[");
            o.num(code + 32);
            o.byte(';');
            o.num(x);
            o.byte(';');
            o.num(y);
            o.byte('M');
        },
        .utf8 => {
            if (x + 32 > 0x7ff or y + 32 > 0x7ff) return o.buf[0..0];
            o.bytes("\x1b[M");
            o.utf8(@intCast(code + 32));
            o.utf8(@intCast(x + 32));
            o.utf8(@intCast(y + 32));
        },
        .default => {
            if (x + 32 > 255 or y + 32 > 255) return o.buf[0..0];
            o.bytes("\x1b[M");
            o.byte(@intCast(code + 32));
            o.byte(@intCast(x + 32));
            o.byte(@intCast(y + 32));
        },
    }
    return o.result();
}

/// Focus in/out report (mode 1004): CSI I / CSI O.
pub fn encodeFocus(focused: bool, out: []u8) []const u8 {
    var o: Out = .{ .buf = out };
    o.bytes(if (focused) "\x1b[I" else "\x1b[O");
    return o.result();
}

/// Prepare clipboard text for sending to the pty. Newlines (LF, CRLF) become
/// CR like a typed Enter. In bracketed mode the text is wrapped in
/// ESC[200~ ... ESC[201~ and any embedded ESC bytes are removed so the paste
/// cannot terminate the bracket early. Caller owns the returned slice.
pub fn encodePaste(allocator: Allocator, text: []const u8, bracketed: bool) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, text.len + 12);
    if (bracketed) list.appendSliceAssumeCapacity("\x1b[200~");
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        switch (b) {
            '\r' => {
                try list.append(allocator, '\r');
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            },
            '\n' => try list.append(allocator, '\r'),
            0x1b => if (!bracketed) try list.append(allocator, b),
            else => try list.append(allocator, b),
        }
    }
    if (bracketed) try list.appendSlice(allocator, "\x1b[201~");
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests

const t = std.testing;

fn expectKey(expected: []const u8, key: Key, mods: Mods, modes: KeyModes) !void {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings(expected, encodeKey(key, mods, modes, &buf));
}

test "encodeKey: text, ctrl, alt" {
    const n: KeyModes = .{};
    try expectKey("a", .{ .char = 'a' }, .{}, n);
    try expectKey("A", .{ .char = 'A' }, .{ .shift = true }, n);
    try expectKey("\xc3\xa9", .{ .char = 0xe9 }, .{}, n);
    try expectKey("\xf0\x9f\x98\x80", .{ .char = 0x1f600 }, .{}, n);
    try expectKey("\x03", .{ .char = 'c' }, .{ .ctrl = true }, n);
    try expectKey("\x01", .{ .char = 'A' }, .{ .ctrl = true, .shift = true }, n);
    try expectKey("\x1a", .{ .char = 'z' }, .{ .ctrl = true }, n);
    try expectKey("\x00", .{ .char = ' ' }, .{ .ctrl = true }, n);
    try expectKey("\x00", .{ .char = '@' }, .{ .ctrl = true }, n);
    try expectKey("\x1b", .{ .char = '[' }, .{ .ctrl = true }, n);
    try expectKey("\x1c", .{ .char = '\\' }, .{ .ctrl = true }, n);
    try expectKey("\x1d", .{ .char = ']' }, .{ .ctrl = true }, n);
    try expectKey("\x1e", .{ .char = '^' }, .{ .ctrl = true }, n);
    try expectKey("\x1f", .{ .char = '_' }, .{ .ctrl = true }, n);
    try expectKey("\x7f", .{ .char = '?' }, .{ .ctrl = true }, n);
    try expectKey("1", .{ .char = '1' }, .{ .ctrl = true }, n);
    try expectKey("\x1bx", .{ .char = 'x' }, .{ .alt = true }, n);
    try expectKey("\x1b\x18", .{ .char = 'x' }, .{ .alt = true, .ctrl = true }, n);
}

test "encodeKey: editing keys" {
    const n: KeyModes = .{};
    try expectKey("\r", .enter, .{}, n);
    try expectKey("\r\n", .enter, .{}, .{ .linefeed_newline = true });
    try expectKey("\x1b\r", .enter, .{ .alt = true }, n);
    try expectKey("\t", .tab, .{}, n);
    try expectKey("\x1b[Z", .tab, .{ .shift = true }, n);
    try expectKey("\x7f", .backspace, .{}, n);
    try expectKey("\x08", .backspace, .{ .ctrl = true }, n);
    try expectKey("\x1b\x7f", .backspace, .{ .alt = true }, n);
    try expectKey("\x1b", .escape, .{}, n);
}

test "encodeKey: cursor keys normal/application/modified" {
    const n: KeyModes = .{};
    const app: KeyModes = .{ .app_cursor = true };
    try expectKey("\x1b[A", .up, .{}, n);
    try expectKey("\x1b[B", .down, .{}, n);
    try expectKey("\x1b[C", .right, .{}, n);
    try expectKey("\x1b[D", .left, .{}, n);
    try expectKey("\x1bOA", .up, .{}, app);
    try expectKey("\x1bOD", .left, .{}, app);
    try expectKey("\x1b[H", .home, .{}, n);
    try expectKey("\x1b[F", .end, .{}, n);
    try expectKey("\x1bOH", .home, .{}, app);
    try expectKey("\x1b[1;5C", .right, .{ .ctrl = true }, n);
    try expectKey("\x1b[1;5C", .right, .{ .ctrl = true }, app);
    try expectKey("\x1b[1;2A", .up, .{ .shift = true }, n);
    try expectKey("\x1b[1;3D", .left, .{ .alt = true }, n);
    try expectKey("\x1b[1;6B", .down, .{ .ctrl = true, .shift = true }, n);
    try expectKey("\x1b[1;2H", .home, .{ .shift = true }, n);
}

test "encodeKey: tilde keys and function keys" {
    const n: KeyModes = .{};
    try expectKey("\x1b[2~", .insert, .{}, n);
    try expectKey("\x1b[3~", .delete, .{}, n);
    try expectKey("\x1b[5~", .page_up, .{}, n);
    try expectKey("\x1b[6~", .page_down, .{}, n);
    try expectKey("\x1b[3;5~", .delete, .{ .ctrl = true }, n);
    try expectKey("\x1b[5;2~", .page_up, .{ .shift = true }, n);
    try expectKey("\x1bOP", .{ .f = 1 }, .{}, n);
    try expectKey("\x1bOQ", .{ .f = 2 }, .{}, n);
    try expectKey("\x1bOR", .{ .f = 3 }, .{}, n);
    try expectKey("\x1bOS", .{ .f = 4 }, .{}, n);
    try expectKey("\x1b[1;2P", .{ .f = 1 }, .{ .shift = true }, n);
    try expectKey("\x1b[15~", .{ .f = 5 }, .{}, n);
    try expectKey("\x1b[17~", .{ .f = 6 }, .{}, n);
    try expectKey("\x1b[18~", .{ .f = 7 }, .{}, n);
    try expectKey("\x1b[19~", .{ .f = 8 }, .{}, n);
    try expectKey("\x1b[20~", .{ .f = 9 }, .{}, n);
    try expectKey("\x1b[21~", .{ .f = 10 }, .{}, n);
    try expectKey("\x1b[23~", .{ .f = 11 }, .{}, n);
    try expectKey("\x1b[24~", .{ .f = 12 }, .{}, n);
    try expectKey("\x1b[24;5~", .{ .f = 12 }, .{ .ctrl = true }, n);
    try expectKey("", .{ .f = 0 }, .{}, n);
}

test "encodeKey: keypad and small buffers" {
    try expectKey("5", .{ .kp = .k5 }, .{}, .{});
    try expectKey("\x1bOu", .{ .kp = .k5 }, .{}, .{ .app_keypad = true });
    try expectKey("\x1bOM", .{ .kp = .enter }, .{}, .{ .app_keypad = true });
    try expectKey("\r", .{ .kp = .enter }, .{}, .{});
    var tiny: [2]u8 = undefined;
    try t.expectEqualStrings("", encodeKey(.up, .{}, .{}, &tiny));
}

test "encodeMouse" {
    var buf: [32]u8 = undefined;
    const press: MouseEvent = .{ .action = .press, .button = .left, .row = 4, .col = 9 };
    try t.expectEqualStrings("", encodeMouse(press, .none, .default, &buf));
    try t.expectEqualStrings("\x1b[M\x20\x2a\x25", encodeMouse(press, .normal, .default, &buf));
    try t.expectEqualStrings("\x1b[<0;10;5M", encodeMouse(press, .normal, .sgr, &buf));
    const rel: MouseEvent = .{ .action = .release, .button = .left, .row = 4, .col = 9 };
    try t.expectEqualStrings("\x1b[<0;10;5m", encodeMouse(rel, .normal, .sgr, &buf));
    try t.expectEqualStrings("\x1b[M\x23\x2a\x25", encodeMouse(rel, .normal, .default, &buf));
    try t.expectEqualStrings("", encodeMouse(rel, .x10, .default, &buf));
    const mv: MouseEvent = .{ .action = .motion, .button = .left, .row = 0, .col = 0 };
    try t.expectEqualStrings("", encodeMouse(mv, .normal, .sgr, &buf));
    try t.expectEqualStrings("\x1b[<32;1;1M", encodeMouse(mv, .button_event, .sgr, &buf));
    const hover: MouseEvent = .{ .action = .motion, .row = 0, .col = 0 };
    try t.expectEqualStrings("", encodeMouse(hover, .button_event, .sgr, &buf));
    try t.expectEqualStrings("\x1b[<35;1;1M", encodeMouse(hover, .any_event, .sgr, &buf));
    const wheel: MouseEvent = .{ .action = .press, .button = .wheel_down, .row = 1, .col = 1, .mods = .{ .ctrl = true } };
    try t.expectEqualStrings("\x1b[<81;2;2M", encodeMouse(wheel, .normal, .sgr, &buf));
    const far: MouseEvent = .{ .action = .press, .button = .left, .row = 0, .col = 300 };
    try t.expectEqualStrings("", encodeMouse(far, .normal, .default, &buf));
    try t.expectEqualStrings("\x1b[M \xc5\x8d!", encodeMouse(far, .normal, .utf8, &buf));
    try t.expectEqualStrings("\x1b[32;301;1M", encodeMouse(far, .normal, .urxvt, &buf));
}

test "encodePaste" {
    const a = t.allocator;
    const plain = try encodePaste(a, "ls\n-la\r\nx", false);
    defer a.free(plain);
    try t.expectEqualStrings("ls\r-la\rx", plain);
    const br = try encodePaste(a, "echo hi\x1b[201~rm\n", true);
    defer a.free(br);
    try t.expectEqualStrings("\x1b[200~echo hi[201~rm\r\x1b[201~", br);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("\x1b[I", encodeFocus(true, &buf));
    try t.expectEqualStrings("\x1b[O", encodeFocus(false, &buf));
}
