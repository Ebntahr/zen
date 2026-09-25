//! `input:` scheme (virtio-input driver → window server) and key maps.
//!
//! Reading `input:` yields a stream of `InputEvent`s from every keyboard,
//! mouse and tablet. Codes are Linux evdev codes, absolute axes are
//! normalized to 0..ABS_MAX.

const std = @import("std");

pub const ABS_MAX: i32 = 32767;

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_HWHEEL: u16 = 0x06;
pub const REL_WHEEL: u16 = 0x08;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_TOUCH: u16 = 0x14a;

pub const InputEvent = extern struct {
    time_ns: u64,
    kind: u16,
    code: u16,
    value: i32,
};

comptime {
    std.debug.assert(@sizeOf(InputEvent) == 16);
}

/// Linux evdev key codes (subset used by Zen).
pub const Key = struct {
    pub const esc = 1;
    pub const @"1" = 2;
    pub const @"2" = 3;
    pub const @"3" = 4;
    pub const @"4" = 5;
    pub const @"5" = 6;
    pub const @"6" = 7;
    pub const @"7" = 8;
    pub const @"8" = 9;
    pub const @"9" = 10;
    pub const @"0" = 11;
    pub const minus = 12;
    pub const equal = 13;
    pub const backspace = 14;
    pub const tab = 15;
    pub const q = 16;
    pub const w = 17;
    pub const e = 18;
    pub const r = 19;
    pub const t = 20;
    pub const y = 21;
    pub const u = 22;
    pub const i = 23;
    pub const o = 24;
    pub const p = 25;
    pub const leftbrace = 26;
    pub const rightbrace = 27;
    pub const enter = 28;
    pub const leftctrl = 29;
    pub const a = 30;
    pub const s = 31;
    pub const d = 32;
    pub const f = 33;
    pub const g = 34;
    pub const h = 35;
    pub const j = 36;
    pub const k = 37;
    pub const l = 38;
    pub const semicolon = 39;
    pub const apostrophe = 40;
    pub const grave = 41;
    pub const leftshift = 42;
    pub const backslash = 43;
    pub const z = 44;
    pub const x = 45;
    pub const c = 46;
    pub const v = 47;
    pub const b = 48;
    pub const n = 49;
    pub const m = 50;
    pub const comma = 51;
    pub const dot = 52;
    pub const slash = 53;
    pub const rightshift = 54;
    pub const kpasterisk = 55;
    pub const leftalt = 56;
    pub const space = 57;
    pub const capslock = 58;
    pub const f1 = 59;
    pub const f2 = 60;
    pub const f3 = 61;
    pub const f4 = 62;
    pub const f5 = 63;
    pub const f6 = 64;
    pub const f7 = 65;
    pub const f8 = 66;
    pub const f9 = 67;
    pub const f10 = 68;
    pub const f11 = 87;
    pub const f12 = 88;
    pub const kpenter = 96;
    pub const rightctrl = 97;
    pub const rightalt = 100;
    pub const home = 102;
    pub const up = 103;
    pub const pageup = 104;
    pub const left = 105;
    pub const right = 106;
    pub const end = 107;
    pub const down = 108;
    pub const pagedown = 109;
    pub const insert = 110;
    pub const delete = 111;
    pub const leftmeta = 125;
    pub const rightmeta = 126;
    pub const compose = 127;
};

/// US QWERTY: evdev code → (unshifted, shifted) ASCII. 0 = no character.
pub const us_layout: [128][2]u8 = blk: {
    var t = [_][2]u8{.{ 0, 0 }} ** 128;
    const rows = [_]struct { u8, []const u8, []const u8 }{
        .{ 2, "1234567890-=", "!@#$%^&*()_+" },
        .{ 16, "qwertyuiop[]", "QWERTYUIOP{}" },
        .{ 30, "asdfghjkl;'`", "ASDFGHJKL:\"~" },
        .{ 43, "\\zxcvbnm,./", "|ZXCVBNM<>?" },
    };
    for (rows) |row| {
        for (row[1], row[2], 0..) |lo, hi, idx| {
            t[row[0] + idx] = .{ lo, hi };
        }
    }
    t[Key.space] = .{ ' ', ' ' };
    t[Key.tab] = .{ '\t', '\t' };
    t[Key.enter] = .{ '\n', '\n' };
    t[Key.kpenter] = .{ '\n', '\n' };
    t[Key.kpasterisk] = .{ '*', '*' };
    break :blk t;
};

/// Arabic (PC) layout: evdev code → (unshifted, shifted) Unicode scalar.
pub const arabic_layout: [128][2]u21 = blk: {
    var t = [_][2]u21{.{ 0, 0 }} ** 128;
    const map = [_]struct { u8, u21, u21 }{
        .{ Key.q, 'ض', 'َ' },  .{ Key.w, 'ص', 'ً' }, .{ Key.e, 'ث', 'ُ' },
        .{ Key.r, 'ق', 'ٌ' },  .{ Key.t, 'ف', '\u{FEF9}' }, .{ Key.y, 'غ', 'إ' },
        .{ Key.u, 'ع', '‘' },  .{ Key.i, 'ه', '÷' }, .{ Key.o, 'خ', '×' },
        .{ Key.p, 'ح', '؛' },  .{ Key.leftbrace, 'ج', '<' }, .{ Key.rightbrace, 'د', '>' },
        .{ Key.a, 'ش', 'ِ' },  .{ Key.s, 'س', 'ٍ' }, .{ Key.d, 'ي', ']' },
        .{ Key.f, 'ب', '[' },  .{ Key.g, 'ل', '\u{FEF7}' }, .{ Key.h, 'ا', 'أ' },
        .{ Key.j, 'ت', 'ـ' },  .{ Key.k, 'ن', '،' }, .{ Key.l, 'م', '/' },
        .{ Key.semicolon, 'ك', ':' }, .{ Key.apostrophe, 'ط', '"' },
        .{ Key.z, 'ئ', '~' },  .{ Key.x, 'ء', 'ْ' }, .{ Key.c, 'ؤ', '}' },
        .{ Key.v, 'ر', '{' },  .{ Key.b, 'ى', '\u{FEF5}' }, .{ Key.n, 'ة', 'آ' },
        .{ Key.m, 'و', '’' },  .{ Key.comma, 'ز', ',' }, .{ Key.dot, 'ظ', '.' },
        .{ Key.slash, 'ذ', '؟' }, .{ Key.grave, 'ذ', 'ّ' },
    };
    for (map) |e| t[e[0]] = .{ e[1], e[2] };
    break :blk t;
};

/// Translate a key press to a Unicode scalar for the given layout.
pub fn keyToChar(code: u16, shift: bool, caps: bool, arabic: bool) u21 {
    if (code >= 128) return 0;
    if (arabic) {
        const c = arabic_layout[code][@intFromBool(shift)];
        if (c != 0) return c;
    }
    const pair = us_layout[code];
    var ch = pair[@intFromBool(shift)];
    if (caps and std.ascii.isAlphabetic(pair[0])) {
        ch = if (shift) pair[0] else pair[1];
    }
    return ch;
}

test "us layout" {
    try std.testing.expectEqual(@as(u21, 'a'), keyToChar(Key.a, false, false, false));
    try std.testing.expectEqual(@as(u21, 'A'), keyToChar(Key.a, true, false, false));
    try std.testing.expectEqual(@as(u21, 'A'), keyToChar(Key.a, false, true, false));
    try std.testing.expectEqual(@as(u21, '!'), keyToChar(Key.@"1", true, false, false));
    try std.testing.expectEqual(@as(u21, 'ش'), keyToChar(Key.a, false, false, true));
}
