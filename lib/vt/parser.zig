//! DEC/ANSI escape sequence parser after Paul Williams' state machine
//! (https://vt100.net/emu/dec_ansi_parser), adapted for a UTF-8 terminal:
//!
//! * In the ground state, bytes >= 0x80 are decoded as UTF-8 (incrementally,
//!   so sequences may be split across `feed` calls). Invalid or truncated
//!   sequences produce U+FFFD (WHATWG "maximal subpart" semantics). Raw C1
//!   bytes (0x80-0x9F) are therefore never interpreted as controls.
//! * CSI parameters support ':' sub-parameters (e.g. `38:2::r:g:b`).
//! * OSC strings are collected (UTF-8 intact) up to `max_osc` bytes and
//!   terminated by BEL or ST; DCS/SOS/PM/APC payloads are consumed and ignored.
//!
//! The parser is independent of the terminal: `feed` drives any handler type
//! that provides:
//!   print(cp: u21) void
//!   printAscii(run: []const u8) void      (optional: runs of 0x20-0x7e)
//!   execute(c0: u8) void
//!   csiDispatch(csi: Csi) void
//!   escDispatch(esc: Esc) void
//!   oscDispatch(data: []const u8, terminator: OscTerminator) void

const std = @import("std");

pub const max_params = 32;
pub const max_intermediates = 2;
pub const max_osc = 4096;

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
};

pub const Csi = struct {
    /// Parameter values; an omitted parameter reads as 0.
    params: []const u16,
    /// Bit i set: params[i] was introduced by ':' (sub-parameter of the
    /// preceding parameter) rather than ';'.
    colon_mask: u32 = 0,
    /// Private marker from `<=>?` (0 if none).
    private: u8 = 0,
    intermediates: []const u8 = &.{},
    final: u8,

    /// Parameter `i`, or `default` if absent or zero.
    pub fn get(self: Csi, i: usize, default: u16) u16 {
        if (i < self.params.len and self.params[i] != 0) return self.params[i];
        return default;
    }

    /// Raw parameter value (0 if absent).
    pub fn raw(self: Csi, i: usize) u16 {
        return if (i < self.params.len) self.params[i] else 0;
    }

    pub fn isSub(self: Csi, i: usize) bool {
        return i < 32 and (self.colon_mask >> @intCast(i)) & 1 == 1;
    }

    pub fn intermediate(self: Csi) u8 {
        return if (self.intermediates.len > 0) self.intermediates[0] else 0;
    }
};

pub const Esc = struct {
    intermediates: []const u8,
    final: u8,

    pub fn intermediate(self: Esc) u8 {
        return if (self.intermediates.len > 0) self.intermediates[0] else 0;
    }
};

pub const OscTerminator = enum { bel, st };

pub const Parser = struct {
    state: State = .ground,

    params: [max_params]u16 = [_]u16{0} ** max_params,
    param_idx: usize = 0,
    have_params: bool = false,
    params_overflow: bool = false,
    colon_mask: u32 = 0,
    private: u8 = 0,
    inter: [max_intermediates]u8 = undefined,
    inter_len: usize = 0,
    inter_overflow: bool = false,

    osc: [max_osc]u8 = undefined,
    osc_len: usize = 0,

    // Incremental UTF-8 decoder (WHATWG algorithm).
    u_cp: u21 = 0,
    u_need: u8 = 0,
    u_seen: u8 = 0,
    u_lo: u8 = 0x80,
    u_hi: u8 = 0xbf,

    pub fn reset(self: *Parser) void {
        self.state = .ground;
        self.clearSeq();
        self.resetUtf8();
    }

    pub fn feed(self: *Parser, handler: anytype, bytes: []const u8) void {
        const H = @TypeOf(handler);
        const T = switch (@typeInfo(H)) {
            .pointer => |ptr| ptr.child,
            else => H,
        };
        var i: usize = 0;
        while (i < bytes.len) {
            // Fast path: runs of printable ASCII in the ground state. Handlers
            // may implement `printAscii(run)` to take a whole run at once.
            if (self.state == .ground and self.u_need == 0) {
                var j = i;
                while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] < 0x7f) j += 1;
                if (j > i) {
                    if (@hasDecl(T, "printAscii")) {
                        handler.printAscii(bytes[i..j]);
                    } else {
                        for (bytes[i..j]) |b| handler.print(b);
                    }
                    i = j;
                    continue;
                }
            }
            self.advance(handler, bytes[i]);
            i += 1;
        }
    }

    fn clearSeq(self: *Parser) void {
        @memset(&self.params, 0);
        self.param_idx = 0;
        self.have_params = false;
        self.params_overflow = false;
        self.colon_mask = 0;
        self.private = 0;
        self.inter_len = 0;
        self.inter_overflow = false;
    }

    fn resetUtf8(self: *Parser) void {
        self.u_cp = 0;
        self.u_need = 0;
        self.u_seen = 0;
        self.u_lo = 0x80;
        self.u_hi = 0xbf;
    }

    fn collect(self: *Parser, b: u8) void {
        if (self.inter_len < max_intermediates) {
            self.inter[self.inter_len] = b;
            self.inter_len += 1;
        } else self.inter_overflow = true;
    }

    fn param(self: *Parser, b: u8) void {
        self.have_params = true;
        switch (b) {
            '0'...'9' => {
                if (self.params_overflow) return;
                const p = &self.params[self.param_idx];
                const v: u32 = @as(u32, p.*) * 10 + (b - '0');
                p.* = @intCast(@min(v, 65535));
            },
            ';', ':' => {
                if (self.param_idx + 1 >= max_params) {
                    self.params_overflow = true;
                    return;
                }
                self.param_idx += 1;
                self.params[self.param_idx] = 0;
                if (b == ':') self.colon_mask |= @as(u32, 1) << @intCast(self.param_idx);
            },
            else => {},
        }
    }

    fn csi(self: *Parser, final: u8) Csi {
        const n: usize = if (self.have_params) self.param_idx + 1 else 0;
        return .{
            .params = self.params[0..n],
            .colon_mask = self.colon_mask,
            .private = self.private,
            .intermediates = self.inter[0..self.inter_len],
            .final = final,
        };
    }

    fn isExecutable(b: u8) bool {
        return b < 0x18 or b == 0x19 or (b >= 0x1c and b < 0x20);
    }

    fn enter(self: *Parser, s: State) void {
        switch (s) {
            .escape, .csi_entry, .dcs_entry => self.clearSeq(),
            .osc_string => self.osc_len = 0,
            else => {},
        }
        self.state = s;
    }

    fn dispatchOsc(self: *Parser, handler: anytype, term: OscTerminator) void {
        handler.oscDispatch(self.osc[0..self.osc_len], term);
        self.osc_len = 0;
    }

    /// Process one byte.
    pub fn advance(self: *Parser, handler: anytype, byte: u8) void {
        const b = byte;
        // Loop only to re-process a byte that interrupted a UTF-8 sequence
        // or an escape sequence.
        while (true) {
            // "Anywhere" transitions.
            if (b == 0x1b) {
                switch (self.state) {
                    .osc_string => self.dispatchOsc(handler, .st),
                    .ground => if (self.u_need != 0) {
                        self.resetUtf8();
                        handler.print(0xfffd);
                    },
                    else => {},
                }
                self.enter(.escape);
                return;
            }
            if (b == 0x18 or b == 0x1a) { // CAN, SUB
                if (self.state == .ground and self.u_need != 0) {
                    self.resetUtf8();
                    handler.print(0xfffd);
                }
                self.state = .ground;
                return;
            }

            switch (self.state) {
                .ground => {
                    if (self.u_need != 0 or b >= 0x80) {
                        if (self.utf8(handler, b)) return;
                        continue; // reprocess b
                    }
                    if (b < 0x20) {
                        handler.execute(b);
                    } else if (b < 0x7f) {
                        handler.print(b);
                    }
                    return;
                },
                .escape => {
                    if (b >= 0x80) {
                        self.state = .ground;
                        continue;
                    }
                    switch (b) {
                        0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                        0x20...0x2f => {
                            self.collect(b);
                            self.state = .escape_intermediate;
                        },
                        'P' => self.enter(.dcs_entry),
                        '[' => self.enter(.csi_entry),
                        ']' => self.enter(.osc_string),
                        'X', '^', '_' => self.state = .sos_pm_apc_string,
                        0x7f => {},
                        else => {
                            self.state = .ground;
                            handler.escDispatch(.{ .intermediates = self.inter[0..self.inter_len], .final = b });
                        },
                    }
                    return;
                },
                .escape_intermediate => {
                    if (b >= 0x80) {
                        self.state = .ground;
                        continue;
                    }
                    switch (b) {
                        0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(b),
                        0x20...0x2f => self.collect(b),
                        0x7f => {},
                        else => {
                            self.state = .ground;
                            if (!self.inter_overflow)
                                handler.escDispatch(.{ .intermediates = self.inter[0..self.inter_len], .final = b });
                        },
                    }
                    return;
                },
                .csi_entry, .csi_param, .csi_intermediate, .csi_ignore => {
                    if (b >= 0x80) {
                        self.state = .ground;
                        continue;
                    }
                    self.csiByte(handler, b);
                    return;
                },
                .dcs_entry, .dcs_param, .dcs_intermediate => {
                    switch (b) {
                        0x20...0x2f => {
                            self.collect(b);
                            self.state = .dcs_intermediate;
                        },
                        0x30...0x39, ';', ':' => {
                            if (self.state == .dcs_intermediate) {
                                self.state = .dcs_ignore;
                            } else {
                                self.param(b);
                                self.state = .dcs_param;
                            }
                        },
                        0x3c...0x3f => {
                            if (self.state == .dcs_entry) {
                                self.private = b;
                                self.state = .dcs_param;
                            } else self.state = .dcs_ignore;
                        },
                        0x40...0x7e => self.state = .dcs_passthrough,
                        else => {},
                    }
                    return;
                },
                .dcs_passthrough, .dcs_ignore, .sos_pm_apc_string => return,
                .osc_string => {
                    if (b == 0x07) {
                        self.dispatchOsc(handler, .bel);
                        self.state = .ground;
                    } else if (b >= 0x20) {
                        if (self.osc_len < max_osc) {
                            self.osc[self.osc_len] = b;
                            self.osc_len += 1;
                        }
                    }
                    return;
                },
            }
        }
    }

    fn csiByte(self: *Parser, handler: anytype, b: u8) void {
        if (isExecutable(b)) {
            handler.execute(b);
            return;
        }
        if (b == 0x7f) return;
        switch (self.state) {
            .csi_entry => switch (b) {
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                0x30...0x3b => {
                    self.param(b);
                    self.state = .csi_param;
                },
                0x3c...0x3f => {
                    self.private = b;
                    self.state = .csi_param;
                },
                else => self.dispatchCsi(handler, b),
            },
            .csi_param => switch (b) {
                0x30...0x3b => self.param(b),
                0x3c...0x3f => self.state = .csi_ignore,
                0x20...0x2f => {
                    self.collect(b);
                    self.state = .csi_intermediate;
                },
                else => self.dispatchCsi(handler, b),
            },
            .csi_intermediate => switch (b) {
                0x20...0x2f => self.collect(b),
                0x30...0x3f => self.state = .csi_ignore,
                else => self.dispatchCsi(handler, b),
            },
            .csi_ignore => if (b >= 0x40) {
                self.state = .ground;
            },
            else => unreachable,
        }
    }

    fn dispatchCsi(self: *Parser, handler: anytype, final: u8) void {
        self.state = .ground;
        if (self.inter_overflow) return;
        handler.csiDispatch(self.csi(final));
    }

    /// Feed one byte to the UTF-8 decoder. Returns false if the byte was not
    /// consumed and must be re-processed (after a U+FFFD was emitted).
    fn utf8(self: *Parser, handler: anytype, b: u8) bool {
        if (self.u_need == 0) {
            switch (b) {
                0xc2...0xdf => {
                    self.u_need = 1;
                    self.u_cp = b & 0x1f;
                },
                0xe0...0xef => {
                    if (b == 0xe0) self.u_lo = 0xa0;
                    if (b == 0xed) self.u_hi = 0x9f;
                    self.u_need = 2;
                    self.u_cp = b & 0x0f;
                },
                0xf0...0xf4 => {
                    if (b == 0xf0) self.u_lo = 0x90;
                    if (b == 0xf4) self.u_hi = 0x8f;
                    self.u_need = 3;
                    self.u_cp = b & 0x07;
                },
                else => handler.print(0xfffd),
            }
            return true;
        }
        if (b < self.u_lo or b > self.u_hi) {
            self.resetUtf8();
            handler.print(0xfffd);
            return false;
        }
        self.u_lo = 0x80;
        self.u_hi = 0xbf;
        self.u_cp = (self.u_cp << 6) | @as(u21, b & 0x3f);
        self.u_seen += 1;
        if (self.u_seen == self.u_need) {
            const cp = self.u_cp;
            self.resetUtf8();
            handler.print(cp);
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests

const Recorder = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn w(self: *Recorder, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }
    fn out(self: *const Recorder) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn print(self: *Recorder, cp: u21) void {
        if (cp < 0x80) self.w("{c}", .{@as(u8, @intCast(cp))}) else self.w("<U+{X}>", .{cp});
    }
    pub fn execute(self: *Recorder, c: u8) void {
        self.w("<x{X:0>2}>", .{c});
    }
    pub fn csiDispatch(self: *Recorder, c: Csi) void {
        self.w("<CSI", .{});
        if (c.private != 0) self.w("{c}", .{c.private});
        for (c.params, 0..) |p, i| {
            if (i > 0) self.w("{s}", .{if (c.isSub(i)) ":" else ";"});
            self.w("{d}", .{p});
        }
        self.w("|{s}{c}>", .{ c.intermediates, c.final });
    }
    pub fn escDispatch(self: *Recorder, e: Esc) void {
        self.w("<ESC{s}{c}>", .{ e.intermediates, e.final });
    }
    pub fn oscDispatch(self: *Recorder, data: []const u8, t: OscTerminator) void {
        self.w("<OSC {s} {s}>", .{ data, @tagName(t) });
    }
};

fn expectParse(input: []const u8, expected: []const u8) !void {
    var p: Parser = .{};
    var r: Recorder = .{};
    p.feed(&r, input);
    try std.testing.expectEqualStrings(expected, r.out());
}

test "parser: text and controls" {
    try expectParse("ab\r\nc\x07", "ab<x0D><x0A>c<x07>");
}

test "parser: csi params, private, intermediates" {
    try expectParse("\x1b[1;2H", "<CSI1;2|H>");
    try expectParse("\x1b[H", "<CSI|H>");
    try expectParse("\x1b[;5H", "<CSI0;5|H>");
    try expectParse("\x1b[?1049h", "<CSI?1049|h>");
    try expectParse("\x1b[2 q", "<CSI2| q>");
    try expectParse("\x1b[!p", "<CSI|!p>");
    try expectParse("\x1b[>c", "<CSI>|c>");
    try expectParse("\x1b[38:2::10:20:30m", "<CSI38:2:0:10:20:30|m>");
    try expectParse("\x1b[99999A", "<CSI65535|A>");
    // private marker after params -> ignored sequence
    try expectParse("\x1b[1?hX", "X");
    // C0 inside CSI is executed
    try expectParse("\x1b[1\n;2H", "<x0A><CSI1;2|H>");
    // ESC cancels a CSI
    try expectParse("\x1b[1;\x1b[3A", "<CSI3|A>");
}

test "parser: esc sequences" {
    try expectParse("\x1b7\x1b8\x1b(0\x1b#8\x1bc", "<ESC7><ESC8><ESC(0><ESC#8><ESCc>");
}

test "parser: osc with BEL and ST, dcs ignored" {
    try expectParse("\x1b]0;hi there\x07x", "<OSC 0;hi there bel>x");
    try expectParse("\x1b]2;t\xc3\xa9\x1b\\y", "<OSC 2;t\xc3\xa9 st><ESC\\>y");
    try expectParse("\x1bPq#0;1;2~-\x1b\\z", "<ESC\\>z");
    try expectParse("\x1b_apc stuff\x1b\\z", "<ESC\\>z");
}

test "parser: utf8 incl. split feeds and invalid bytes" {
    var p: Parser = .{};
    var r: Recorder = .{};
    const s = "\xe4\xb8\xad"; // U+4E2D
    p.feed(&r, s[0..1]);
    p.feed(&r, s[1..2]);
    p.feed(&r, s[2..3]);
    p.feed(&r, "\xf0\x9f");
    p.feed(&r, "\x98\x80");
    try std.testing.expectEqualStrings("<U+4E2D><U+1F600>", r.out());

    try expectParse("a\xffb", "a<U+FFFD>b");
    try expectParse("\xc3(", "<U+FFFD>(");
    try expectParse("\xe4\xb8\x1b[A", "<U+FFFD><CSI|A>");
    try expectParse("\xed\xa0\x80", "<U+FFFD><U+FFFD><U+FFFD>"); // surrogate
    try expectParse("\xc0\xaf", "<U+FFFD><U+FFFD>"); // overlong
    try expectParse("\x80", "<U+FFFD>");
}

test "parser: too many params and intermediates are safe" {
    var buf: [400]u8 = undefined;
    var n: usize = 0;
    buf[n] = 0x1b;
    buf[n + 1] = '[';
    n += 2;
    for (0..100) |_| {
        buf[n] = '1';
        buf[n + 1] = ';';
        n += 2;
    }
    buf[n] = 'm';
    n += 1;
    var p: Parser = .{};
    var r: Recorder = .{};
    p.feed(&r, buf[0..n]);
    try std.testing.expect(std.mem.startsWith(u8, r.out(), "<CSI1;1;1"));
    try expectParse("\x1b[1$$$px", "x");
}

test "parser: oversized osc is truncated" {
    var p: Parser = .{};
    var r: Recorder = .{};
    p.feed(&r, "\x1b]2;");
    var big: [5000]u8 = undefined;
    @memset(&big, 'a');
    p.feed(&r, &big);
    p.feed(&r, "\x07");
    try std.testing.expectEqual(State.ground, p.state);
    try std.testing.expectEqual(@as(usize, 0), p.osc_len);
}
