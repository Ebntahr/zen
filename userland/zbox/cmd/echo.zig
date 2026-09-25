const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: echo [SHORT-OPTION]... [STRING]...
    \\Echo the STRING(s) to standard output.
    \\
    \\  -n             do not output the trailing newline
    \\  -e             enable interpretation of backslash escapes
    \\  -E             disable interpretation of backslash escapes (default)
    \\      --help     display this help and exit
    \\      --version  output version information and exit
    \\
    \\If -e is in effect, the following sequences are recognized:
    \\  \\  backslash      \a  alert (BEL)    \b  backspace
    \\  \c  produce no further output         \e  escape
    \\  \f  form feed      \n  new line       \r  carriage return
    \\  \t  horizontal tab \v  vertical tab
    \\  \0NNN  byte with octal value NNN (1 to 3 digits)
    \\  \xHH   byte with hexadecimal value HH (1 to 2 digits)
    \\
;

/// Write s interpreting backslash escapes; returns false if \c was seen.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try w.writeByte(s[i]);
            i += 1;
            continue;
        }
        if (s[i + 1] == 'c') return false;
        var tmp: [8]u8 = undefined;
        const r = c.unescapeOne(s[i..], &tmp, true);
        try w.writeAll(r[0]);
        i += r[1];
    }
    return true;
}

pub fn main(args: c.Args) !u8 {
    var newline = true;
    var escapes = false;
    var i: usize = 1;
    if (args.len == 2) {
        if (c.eql(args[1], "--help")) c.printHelp();
        if (c.eql(args[1], "--version")) c.printVersion();
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') break;
        var ok = true;
        for (a[1..]) |ch| if (ch != 'n' and ch != 'e' and ch != 'E') {
            ok = false;
        };
        if (!ok) break;
        for (a[1..]) |ch| switch (ch) {
            'n' => newline = false,
            'e' => escapes = true,
            'E' => escapes = false,
            else => {},
        };
    }
    const out = c.out;
    var first = true;
    while (i < args.len) : (i += 1) {
        if (!first) try out.writeByte(' ');
        first = false;
        if (escapes) {
            if (!try writeEscaped(out, args[i])) return 0;
        } else try out.writeAll(args[i]);
    }
    if (newline) try out.writeByte('\n');
    return 0;
}
