//! Terminal behavior tests: feed byte sequences, assert grid/cursor state.

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

const terminal = @import("terminal.zig");
const Terminal = terminal.Terminal;
const Pos = terminal.Pos;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const input = @import("input.zig");

// ---------------------------------------------------------------------------
// Helpers

fn newTerm(cols: usize, rows: usize) !Terminal {
    return Terminal.init(testing.allocator, cols, rows, 100);
}

fn cellsText(cells: []const Cell, buf: []u8) []const u8 {
    var n: usize = 0;
    for (cells) |c| {
        if (c.attrs.wide_spacer) continue;
        n += std.unicode.utf8Encode(if (c.cp == 0) ' ' else c.cp, buf[n..]) catch unreachable;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

fn expectRow(t: *const Terminal, r: usize, expected: []const u8) !void {
    var buf: [2048]u8 = undefined;
    try expectEqualStrings(expected, cellsText(t.getRow(r), &buf));
}

fn expectScreen(t: *const Terminal, expected: []const []const u8) !void {
    try expectEqual(t.rows, expected.len);
    for (expected, 0..) |e, r| {
        var buf: [2048]u8 = undefined;
        const got = cellsText(t.getRow(r), &buf);
        if (!std.mem.eql(u8, e, got)) {
            std.debug.print("row {d}: expected \"{s}\", got \"{s}\"\n", .{ r, e, got });
            return error.TestExpectedEqual;
        }
    }
}

fn expectLine(t: *const Terminal, r: isize, expected: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const line = t.lineAt(r) orelse return error.NoSuchLine;
    try expectEqualStrings(expected, cellsText(line.cells, &buf));
}

fn expectCursor(t: *const Terminal, row: usize, col: usize) !void {
    if (t.cursor.row != row or t.cursor.col != col) {
        std.debug.print("cursor: expected ({d},{d}), got ({d},{d})\n", .{ row, col, t.cursor.row, t.cursor.col });
        return error.TestExpectedEqual;
    }
}

fn expectResponse(t: *Terminal, expected: []const u8) !void {
    try expectEqualStrings(expected, t.takeResponse());
}

/// Structural invariants that must hold after any input.
fn checkInvariants(t: *const Terminal) !void {
    try expect(t.cursor.row < t.rows);
    try expect(t.cursor.col < t.cols);
    try expect(t.scroll_top < t.rows and t.scroll_bottom < t.rows);
    try expect(t.scroll_top <= t.scroll_bottom);
    try expect(t.viewport_offset <= t.scrollback.len);
    try expect(t.scrollback.len <= t.scrollback_limit);
    for ([_]*const @import("screen.zig").Screen{ &t.primary, &t.alternate }) |s| {
        try expectEqual(t.rows, s.rows.len);
        for (s.rows) |row| {
            try expectEqual(t.cols, row.cells.len);
            for (row.cells, 0..) |c, i| {
                if (c.attrs.wide) {
                    try expect(i + 1 < row.cells.len);
                    try expect(row.cells[i + 1].attrs.wide_spacer);
                }
                if (c.attrs.wide_spacer) {
                    try expect((i > 0 and row.cells[i - 1].attrs.wide) or i + 1 == row.cells.len);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Printing, wrapping

test "print text, CR, LF" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("hello\r\nworld");
    try expectScreen(&t, &.{ "hello", "world", "" });
    try expectCursor(&t, 1, 5);
    try expectEqual(@as(u21, 'h'), t.getCell(0, 0).cp);
}

test "autowrap with pending-wrap semantics" {
    var t = try newTerm(5, 3);
    defer t.deinit();
    t.feed("abcde");
    try expectCursor(&t, 0, 4);
    try expect(t.cursor.pending_wrap);
    try expect(!t.isWrapped(0));
    t.feed("f");
    try expectScreen(&t, &.{ "abcde", "f", "" });
    try expect(t.isWrapped(0));
    try expectCursor(&t, 1, 1);
}

test "pending wrap is cleared by CR, BS, LF and cursor motion" {
    var t = try newTerm(5, 3);
    defer t.deinit();
    t.feed("abcde\rX");
    try expectRow(&t, 0, "Xbcde");
    try expectCursor(&t, 0, 1);

    t.feed("\x1b[H\x1b[2Jabcde\x08X");
    try expectRow(&t, 0, "abcXe");
    try expect(!t.cursor.pending_wrap);

    t.feed("\x1b[H\x1b[2Jabcde\x1b[DY");
    try expectRow(&t, 0, "abcYe");

    t.feed("\x1b[H\x1b[2Jabcde\nZ");
    try expectScreen(&t, &.{ "abcde", "    Z", "" });
    try expect(!t.isWrapped(0));

    // CUP to the last column does not set pending wrap.
    t.feed("\x1b[H\x1b[2J\x1b[1;5HQR");
    try expectScreen(&t, &.{ "    Q", "R", "" });
}

test "autowrap off overwrites the last column" {
    var t = try newTerm(5, 2);
    defer t.deinit();
    t.feed("\x1b[?7labcdefg");
    try expectScreen(&t, &.{ "abcdg", "" });
    try expectCursor(&t, 0, 4);
    t.feed("\x1b[?7h");
    try expect(t.modes.autowrap);
}

test "scrolling at bottom pushes lines to scrollback" {
    var t = try newTerm(5, 3);
    defer t.deinit();
    t.feed("1\r\n2\r\n3\r\n4\r\n5");
    try expectScreen(&t, &.{ "3", "4", "5" });
    try expectEqual(@as(usize, 2), t.scrollbackLen());
    try expectLine(&t, -1, "2");
    try expectLine(&t, -2, "1");
    try expect(t.lineAt(-3) == null);
}

test "scrollback ring evicts oldest lines; ED 3 clears it" {
    var t = try Terminal.init(testing.allocator, 5, 2, 3);
    defer t.deinit();
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        t.feed(try std.fmt.bufPrint(&buf, "{d}\r\n", .{i}));
    }
    try expectEqual(@as(usize, 3), t.scrollbackLen());
    try expectLine(&t, -3, "6");
    try expectLine(&t, -1, "8");
    try expectScreen(&t, &.{ "9", "" });
    t.feed("\x1b[3J");
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    try expectScreen(&t, &.{ "9", "" });
}

test "combining marks are dropped without advancing" {
    var t = try newTerm(10, 2);
    defer t.deinit();
    t.feed("e\xcc\x81x\xe2\x80\x8dy");
    try expectRow(&t, 0, "exy");
    try expectCursor(&t, 0, 3);
}

// ---------------------------------------------------------------------------
// Scroll regions

fn fillLetters(t: *Terminal) void {
    t.feed("\x1b[H\x1b[2JA\r\nB\r\nC\r\nD\r\nE");
}

test "DECSTBM: LF at bottom margin scrolls only the region" {
    var t = try newTerm(5, 5);
    defer t.deinit();
    fillLetters(&t);
    t.feed("\x1b[2;4r");
    try expectCursor(&t, 0, 0);
    t.feed("\x1b[4;1H\n");
    try expectScreen(&t, &.{ "A", "C", "D", "", "E" });
    try expectCursor(&t, 3, 0);
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    // Below the region LF moves down to the last row but never scrolls.
    t.feed("\x1b[5;1H\n\n");
    try expectCursor(&t, 4, 0);
    try expectScreen(&t, &.{ "A", "C", "D", "", "E" });
    // Invalid region is ignored.
    t.feed("\x1b[4;2r");
    try expectEqual(@as(usize, 1), t.scroll_top);
    try expectEqual(@as(usize, 3), t.scroll_bottom);
    // Reset region
    t.feed("\x1b[r");
    try expectEqual(@as(usize, 0), t.scroll_top);
    try expectEqual(@as(usize, 4), t.scroll_bottom);
}

test "IL / DL inside and outside the region" {
    var t = try newTerm(5, 5);
    defer t.deinit();
    fillLetters(&t);
    t.feed("\x1b[2;4r\x1b[3;3H\x1b[L");
    try expectScreen(&t, &.{ "A", "B", "", "C", "E" });
    try expectCursor(&t, 2, 0);
    t.feed("\x1b[2;1H\x1b[2M");
    try expectScreen(&t, &.{ "A", "C", "", "", "E" });
    // outside region: ignored
    t.feed("\x1b[5;1H\x1b[L\x1b[1;1H\x1b[M");
    try expectScreen(&t, &.{ "A", "C", "", "", "E" });
    // IL count larger than region
    t.feed("\x1b[r");
    fillLetters(&t);
    t.feed("\x1b[2;1H\x1b[99L");
    try expectScreen(&t, &.{ "A", "", "", "", "" });
    try expectEqual(@as(usize, 0), t.scrollbackLen());
}

test "SU / SD scroll the region" {
    var t = try newTerm(5, 5);
    defer t.deinit();
    fillLetters(&t);
    t.feed("\x1b[2;4r\x1b[S");
    try expectScreen(&t, &.{ "A", "C", "D", "", "E" });
    t.feed("\x1b[2T");
    try expectScreen(&t, &.{ "A", "", "", "C", "E" });
    t.feed("\x1b[r");
    fillLetters(&t);
    t.feed("\x1b[2S");
    try expectScreen(&t, &.{ "C", "D", "E", "", "" });
    try expectEqual(@as(usize, 2), t.scrollbackLen());
    try expectLine(&t, -1, "B");
}

test "RI at top margin scrolls down; NEL and IND" {
    var t = try newTerm(5, 4);
    defer t.deinit();
    t.feed("A\r\nB\r\nC\r\nD\x1b[2;3r\x1b[2;1H\x1bM");
    try expectScreen(&t, &.{ "A", "", "B", "D" });
    t.feed("\x1b[1;1H\x1bM");
    try expectScreen(&t, &.{ "A", "", "B", "D" });
    try expectCursor(&t, 0, 0);
    t.feed("\x1b[r\x1b[1;3H\x1bE");
    try expectCursor(&t, 1, 0);
    t.feed("\x1b[1;3H\x1bD");
    try expectCursor(&t, 1, 2);
}

test "origin mode makes CUP relative to the region" {
    var t = try newTerm(10, 6);
    defer t.deinit();
    t.feed("\x1b[2;5r\x1b[?6h");
    try expectCursor(&t, 1, 0);
    t.feed("\x1b[2;3HX");
    try expectCursor(&t, 2, 3);
    try expectRow(&t, 2, "  X");
    t.feed("\x1b[99;1H");
    try expectCursor(&t, 4, 0);
    t.feed("\x1b[6n");
    try expectResponse(&t, "\x1b[4;1R");
    t.feed("\x1b[?6l");
    try expectCursor(&t, 0, 0);
}

// ---------------------------------------------------------------------------
// Erase / insert / delete

test "EL variants" {
    var t = try newTerm(10, 1);
    defer t.deinit();
    t.feed("0123456789\x1b[1;6H\x1b[K");
    try expectRow(&t, 0, "01234");
    t.feed("\r0123456789\x1b[1;6H\x1b[1K");
    try expectRow(&t, 0, "      6789");
    t.feed("\x1b[2K");
    try expectRow(&t, 0, "");
    try expectCursor(&t, 0, 5);
}

test "ED variants" {
    var t = try newTerm(4, 4);
    defer t.deinit();
    t.feed("aaaa\r\nbbbb\r\ncccc\r\ndddd\x1b[2;3H\x1b[J");
    try expectScreen(&t, &.{ "aaaa", "bb", "", "" });
    t.feed("\x1b[H\x1b[2Jaaaa\r\nbbbb\r\ncccc\r\ndddd\x1b[3;2H\x1b[1J");
    try expectScreen(&t, &.{ "", "", "  cc", "dddd" });
    t.feed("\x1b[2J");
    try expectScreen(&t, &.{ "", "", "", "" });
    try expectCursor(&t, 2, 1);
}

test "erase uses the current background color (BCE)" {
    var t = try newTerm(4, 2);
    defer t.deinit();
    t.feed("\x1b[44m\x1b[2J\x1b[0m");
    try expect(t.getCell(1, 3).bg.eql(.{ .indexed = 4 }));
    t.feed("\x1b[41m\x1b[1;2H\x1b[K");
    try expect(t.getCell(0, 0).bg.eql(.{ .indexed = 4 }));
    try expect(t.getCell(0, 1).bg.eql(.{ .indexed = 1 }));
    try expect(t.getCell(0, 3).fg.eql(.default));
}

test "ICH / DCH / ECH" {
    var t = try newTerm(8, 1);
    defer t.deinit();
    t.feed("abcdef\x1b[1;2H\x1b[2@");
    try expectRow(&t, 0, "a  bcdef");
    t.feed("\x1b[@");
    try expectRow(&t, 0, "a   bcde");
    t.feed("\x1b[2K\rabcdef\x1b[1;2H\x1b[2P");
    try expectRow(&t, 0, "adef");
    t.feed("\x1b[99P");
    try expectRow(&t, 0, "a");
    t.feed("\x1b[2K\rabcdef\x1b[1;2H\x1b[2X");
    try expectRow(&t, 0, "a  def");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[1;8H\x1b[5X");
    try expectRow(&t, 0, "a  def");
}

test "insert mode (IRM) shifts text right" {
    var t = try newTerm(6, 1);
    defer t.deinit();
    t.feed("abc\r\x1b[4hXY\x1b[4l");
    try expectRow(&t, 0, "XYabc");
    t.feed("Z");
    try expectRow(&t, 0, "XYZbc");
}

// ---------------------------------------------------------------------------
// Tabs

test "tab stops: HT, HTS, TBC, CHT, CBT" {
    var t = try newTerm(20, 1);
    defer t.deinit();
    t.feed("a\tb\tc");
    try expectRow(&t, 0, "a       b       c");
    t.feed("\r\x1b[2K\x1b[1;5H\x1bH\r\tX");
    try expectCursor(&t, 0, 5);
    t.feed("\r\x1b[1;5H\x1b[g\r\t");
    try expectCursor(&t, 0, 8);
    t.feed("\r\x1b[2I");
    try expectCursor(&t, 0, 16);
    t.feed("\x1b[1;18H\x1b[Z");
    try expectCursor(&t, 0, 16);
    t.feed("\x1b[2Z");
    try expectCursor(&t, 0, 0);
    t.feed("\x1b[3g\t");
    try expectCursor(&t, 0, 19);
    t.feed("\t");
    try expectCursor(&t, 0, 19);
}

// ---------------------------------------------------------------------------
// SGR

test "SGR attributes and colors" {
    var t = try newTerm(40, 2);
    defer t.deinit();
    t.feed("\x1b[1;3;4mA\x1b[22mB\x1b[0mC");
    const a = t.getCell(0, 0);
    try expect(a.attrs.bold and a.attrs.italic and a.attrs.underline);
    const b = t.getCell(0, 1);
    try expect(!b.attrs.bold and b.attrs.italic and b.attrs.underline);
    const c = t.getCell(0, 2);
    try expect(!c.attrs.italic and !c.attrs.underline);

    t.feed("\x1b[31mR\x1b[91mB\x1b[38;5;200mC\x1b[38;2;10;20;30mD\x1b[48;5;17mE\x1b[48:2::1:2:3mF\x1b[38:5:99mG\x1b[39;49mH");
    try expect(t.getCell(0, 3).fg.eql(.{ .indexed = 1 }));
    try expect(t.getCell(0, 4).fg.eql(.{ .indexed = 9 }));
    try expect(t.getCell(0, 5).fg.eql(.{ .indexed = 200 }));
    try expect(t.getCell(0, 6).fg.eql(.{ .rgb = .{ 10, 20, 30 } }));
    try expect(t.getCell(0, 7).bg.eql(.{ .indexed = 17 }));
    try expect(t.getCell(0, 7).fg.eql(.{ .rgb = .{ 10, 20, 30 } }));
    try expect(t.getCell(0, 8).bg.eql(.{ .rgb = .{ 1, 2, 3 } }));
    try expect(t.getCell(0, 9).fg.eql(.{ .indexed = 99 }));
    try expect(t.getCell(0, 10).fg.eql(.default));
    try expect(t.getCell(0, 10).bg.eql(.default));

    // 38:2:r:g:b without colorspace, underline color consumed, curly underline
    t.feed("\x1b[38:2:7:8:9mI\x1b[0;58;2;1;2;3;1mJ\x1b[0;4:3mK\x1b[4:0mL");
    try expect(t.getCell(0, 11).fg.eql(.{ .rgb = .{ 7, 8, 9 } }));
    const j = t.getCell(0, 12);
    try expect(j.attrs.bold and j.fg.eql(.default));
    try expect(t.getCell(0, 13).attrs.underline);
    try expect(!t.getCell(0, 14).attrs.underline);

    t.feed("\x1b[0;7;8;9;5;2mM\x1b[27;28;29;25;22mN");
    const m = t.getCell(0, 15);
    try expect(m.attrs.inverse and m.attrs.hidden and m.attrs.strike and m.attrs.blink and m.attrs.dim);
    const n = t.getCell(0, 16);
    try expect(!n.attrs.inverse and !n.attrs.hidden and !n.attrs.strike and !n.attrs.blink and !n.attrs.dim);

    t.feed("\x1b[0;100;107;40;32mO\x1b[mP\x1b[38;5mQ\x1b[38;2;1mR\x1b[48;9;1mS");
    try expect(t.getCell(0, 17).bg.eql(.{ .indexed = 0 }));
    try expect(t.getCell(0, 17).fg.eql(.{ .indexed = 2 }));
    try expect(t.getCell(0, 18).bg.eql(.default));
    try expectRow(&t, 0, "ABCRBCDEFGHIJKLMNOPQRS");

    // Values > 255 are clamped; SGR with private marker is not SGR.
    t.feed("\x1b[38;2;300;0;0mT\x1b[>4;1m\x1b[0mU");
    try expect(t.getCell(0, 22).fg.eql(.{ .rgb = .{ 255, 0, 0 } }));
    try expect(t.getCell(0, 23).fg.eql(.default));
}

// ---------------------------------------------------------------------------
// Cursor save/restore, charsets

test "DECSC/DECRC save position, attributes and charset" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("\x1b[31;1m\x1b(0\x1b[2;3H\x1b7\x1b[0m\x1b(B\x1b[H\x1b8q");
    try expectCursor(&t, 1, 3);
    const c = t.getCell(1, 2);
    try expectEqual(@as(u21, 0x2500), c.cp);
    try expect(c.fg.eql(.{ .indexed = 1 }) and c.attrs.bold);
    // CSI s / CSI u
    t.feed("\x1b(B\x1b[0m\x1b[3;5H\x1b[s\x1b[H\x1b[u");
    try expectCursor(&t, 2, 4);
    // restore without save -> home, default attrs
    var t2 = try newTerm(5, 2);
    defer t2.deinit();
    t2.feed("\x1b[31m\x1b[2;2H\x1b8x");
    try expectCursor(&t2, 0, 1);
    try expect(t2.getCell(0, 0).fg.eql(.default));
}

test "DEC line drawing charset via G0 and G1 (SO/SI)" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("\x1b(0lqqk\x1b(B\r\n\x1b(0x  x\x1b(Bx");
    try expectRow(&t, 0, "┌──┐");
    try expectRow(&t, 1, "│  │x");
    t.feed("\r\n\x1b)0\x0eqj\x0fq");
    try expectRow(&t, 2, "─┘q");
    // UK set
    t.feed("\x1b[H\x1b(A#\x1b(B#");
    try expectRow(&t, 0, "£#─┐");
}

// ---------------------------------------------------------------------------
// Alternate screen

test "alt screen 1049 saves and restores cursor and content" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("$ vim\r\n\x1b[31m");
    try expectCursor(&t, 1, 0);
    t.feed("\x1b[?1049h");
    try expect(t.isAltScreen());
    try expectScreen(&t, &.{ "", "", "" });
    t.feed("\x1b[0m\x1b[Hedit\r\n\n\n\n\n");
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    t.feed("\x1b[3;3Hzz");
    t.feed("\x1b[?1049l");
    try expect(!t.isAltScreen());
    try expectScreen(&t, &.{ "$ vim", "", "" });
    try expectCursor(&t, 1, 0);
    try expect(t.cursor.pen.fg.eql(.{ .indexed = 1 }));
    // Entering again gives a clean alternate screen.
    t.feed("\x1b[?1049h");
    try expectScreen(&t, &.{ "", "", "" });
    t.feed("\x1b[?1049l");
}

test "alt screen 47 and 1047" {
    var t = try newTerm(10, 2);
    defer t.deinit();
    t.feed("main\x1b[?47h");
    try expectCursor(&t, 0, 4);
    t.feed("alt");
    try expectRow(&t, 0, "    alt");
    t.feed("\x1b[?47l");
    try expectRow(&t, 0, "main");
    t.feed("\x1b[?47h");
    try expectRow(&t, 0, "    alt");
    t.feed("\x1b[?47l\x1b[?1047h");
    try expectRow(&t, 0, "");
    t.feed("x\x1b[?1047l\x1b[?47h");
    try expectRow(&t, 0, "");
    t.feed("\x1b[?47l");
    try expectRow(&t, 0, "main");
}

// ---------------------------------------------------------------------------
// Reports

test "DSR, CPR, DA1, DA2, DECRQM, window size report" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("\x1b[5n");
    try expectResponse(&t, "\x1b[0n");
    t.feed("\x1b[3;4H\x1b[6n");
    try expectResponse(&t, "\x1b[3;4R");
    t.feed("\x1b[?6n");
    try expectResponse(&t, "\x1b[?3;4R");
    t.feed("\x1b[c\x1b[0c");
    try expectResponse(&t, "\x1b[?62;22c\x1b[?62;22c");
    t.feed("\x1b[>c");
    try expectResponse(&t, "\x1b[>1;10;0c");
    t.feed("\x1b[?2004$p\x1b[?2004h\x1b[?2004$p\x1b[?9999$p\x1b[4$p");
    try expectResponse(&t, "\x1b[?2004;2$y\x1b[?2004;1$y\x1b[?9999;0$y\x1b[4;2$y");
    t.feed("\x1b[18t\x1b[22;0t");
    try expectResponse(&t, "\x1b[8;3;10t");
    try expectResponse(&t, "");
    t.feed("\x1b[>q");
    try expect(std.mem.startsWith(u8, t.takeResponse(), "\x1bP>|zen-vt"));
}

// ---------------------------------------------------------------------------
// UTF-8 and wide characters

test "UTF-8 split across feed calls" {
    var t = try newTerm(10, 2);
    defer t.deinit();
    t.feed("\xe4");
    t.feed("\xb8");
    try expectRow(&t, 0, "");
    t.feed("\xad");
    try expectEqual(@as(u21, 0x4e2d), t.getCell(0, 0).cp);
    try expect(t.getCell(0, 0).attrs.wide);
    try expect(t.getCell(0, 1).attrs.wide_spacer);
    try expectCursor(&t, 0, 2);
    t.feed("\xf0\x9f");
    t.feed("\x98");
    t.feed("\x80a");
    try expectRow(&t, 0, "中😀a");
    try expectCursor(&t, 0, 5);
    t.feed("\xff\xc3(");
    try expectRow(&t, 0, "中😀a\u{fffd}\u{fffd}(");
    t.feed("\xc3");
    t.feed("\xa9");
    try expectRow(&t, 0, "中😀a\u{fffd}\u{fffd}(é");
}

test "wide char at line end wraps with a spacer" {
    var t = try newTerm(5, 3);
    defer t.deinit();
    t.feed("abcd中");
    try expect(t.isWrapped(0));
    try expect(t.getCell(0, 4).attrs.wide_spacer);
    try expectScreen(&t, &.{ "abcd", "中", "" });
    try expectCursor(&t, 1, 2);
    const text = try t.textInRange(testing.allocator, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 4 });
    defer testing.allocator.free(text);
    try expectEqualStrings("abcd中", text);
    // exactly fitting wide char sets pending wrap
    t.feed("\x1b[3;1Habc文");
    try expectCursor(&t, 2, 4);
    try expect(t.cursor.pending_wrap);
    try checkInvariants(&t);
}

test "overwriting half of a wide char blanks the other half" {
    var t = try newTerm(6, 1);
    defer t.deinit();
    t.feed("中文\rx");
    try expectRow(&t, 0, "x 文");
    try expect(!t.getCell(0, 1).attrs.wide_spacer);
    t.feed("\x1b[1;4Hy");
    try expectRow(&t, 0, "x  y");
    try expect(!t.getCell(0, 2).attrs.wide);
    t.feed("\r\x1b[2K中文\x1b[1;2H界");
    try expectRow(&t, 0, " 界");
    try checkInvariants(&t);
    // DCH/ICH next to wide chars
    t.feed("\r\x1b[2K中文\x1b[1;2H\x1b[P");
    try checkInvariants(&t);
    t.feed("\r\x1b[2K中文\x1b[1;4H\x1b[@");
    try checkInvariants(&t);
    t.feed("\r\x1b[2Kab中文\x1b[1;1H\x1b[@");
    try expectRow(&t, 0, " ab中");
    try checkInvariants(&t);
}

test "wide char with autowrap off stays on the line" {
    var t = try newTerm(4, 2);
    defer t.deinit();
    t.feed("\x1b[?7labc中");
    try expectRow(&t, 0, "ab中");
    try checkInvariants(&t);
}

// ---------------------------------------------------------------------------
// Misc controls

test "REP repeats the last character" {
    var t = try newTerm(10, 1);
    defer t.deinit();
    t.feed("a\x1b[3bz");
    try expectRow(&t, 0, "aaaaz");
    t.feed("\x1b(0q\x1b[2b\x1b(B");
    try expectRow(&t, 0, "aaaaz───");
}

test "CAN aborts a sequence; LNM; ESC c" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("\x1b[31\x18m");
    try expectRow(&t, 0, "m");
    try expect(t.cursor.pen.fg.eql(.default));
    t.feed("\x1b[20hab\ncd");
    try expectRow(&t, 1, "cd");
    try expectCursor(&t, 1, 2);
    t.feed("\x1b[20l\x1b[?25l\x1b[5;7r\x1bc");
    try expectScreen(&t, &.{ "", "", "" });
    try expectCursor(&t, 0, 0);
    try expect(t.cursor.visible);
    try expect(!t.modes.linefeed_newline);
}

test "DECSTR soft reset" {
    var t = try newTerm(10, 4);
    defer t.deinit();
    t.feed("hi\x1b[4h\x1b[?6h\x1b[?7l\x1b[?25l\x1b[2;3r\x1b[1;31m\x1b(0\x1b[!p");
    try expect(!t.modes.insert and !t.modes.origin and t.modes.autowrap and t.cursor.visible);
    try expectEqual(@as(usize, 0), t.scroll_top);
    try expectEqual(@as(usize, 3), t.scroll_bottom);
    try expect(t.cursor.pen.fg.eql(.default) and !t.cursor.pen.attrs.bold);
    t.feed("q");
    try expect(std.mem.indexOf(u8, "q", "q") != null);
    try expectEqual(@as(u21, 'q'), t.getCell(1, 0).cp);
    try expectRow(&t, 0, "hi");
}

test "DECALN fills the screen with E" {
    var t = try newTerm(3, 2);
    defer t.deinit();
    t.feed("\x1b[2;2r\x1b#8");
    try expectScreen(&t, &.{ "EEE", "EEE" });
    try expectCursor(&t, 0, 0);
    try expectEqual(@as(usize, 1), t.scroll_bottom);
}

test "cursor style, visibility and blink" {
    var t = try newTerm(5, 2);
    defer t.deinit();
    try expectEqual(terminal.CursorStyle.blinking_block, t.cursor.style);
    t.feed("\x1b[4 q");
    try expectEqual(terminal.CursorStyle.steady_underline, t.cursor.style);
    t.feed("\x1b[?12h");
    try expectEqual(terminal.CursorStyle.blinking_underline, t.cursor.style);
    t.feed("\x1b[6 q\x1b[?25l");
    try expectEqual(terminal.CursorStyle.steady_bar, t.cursor.style);
    try expect(!t.cursor.visible);
    t.feed("\x1b[0 q\x1b[?25h");
    try expectEqual(terminal.CursorStyle.blinking_block, t.cursor.style);
    try expect(t.cursor.visible);
}

test "cursor movement commands clamp" {
    var t = try newTerm(10, 5);
    defer t.deinit();
    t.feed("\x1b[3;3H\x1b[A");
    try expectCursor(&t, 1, 2);
    t.feed("\x1b[99A");
    try expectCursor(&t, 0, 2);
    t.feed("\x1b[99B");
    try expectCursor(&t, 4, 2);
    t.feed("\x1b[99C");
    try expectCursor(&t, 4, 9);
    t.feed("\x1b[3D");
    try expectCursor(&t, 4, 6);
    t.feed("\x1b[2F");
    try expectCursor(&t, 2, 0);
    t.feed("\x1b[E");
    try expectCursor(&t, 3, 0);
    t.feed("\x1b[5G");
    try expectCursor(&t, 3, 4);
    t.feed("\x1b[2d");
    try expectCursor(&t, 1, 4);
    t.feed("\x1b[2e\x1b[3a");
    try expectCursor(&t, 3, 7);
    t.feed("\x1b[`\x1b[0;0f");
    try expectCursor(&t, 0, 0);
    // CUU/CUD stop at margins when inside the region
    t.feed("\x1b[2;4r\x1b[3;1H\x1b[9A");
    try expectCursor(&t, 1, 0);
    t.feed("\x1b[9B");
    try expectCursor(&t, 3, 0);
}

// ---------------------------------------------------------------------------
// OSC, bell

test "OSC title, icon, cwd; hyperlinks and clipboard ignored" {
    var t = try newTerm(20, 2);
    defer t.deinit();
    t.feed("\x1b]0;My Title\x07");
    try expectEqualStrings("My Title", t.getTitle());
    try expectEqualStrings("My Title", t.getIconName());
    try expect(t.takeTitleChanged());
    try expect(!t.takeTitleChanged());
    t.feed("\x1b]2;Caf\xc3\xa9 \xe2\x80\x94 zsh\x1b\\");
    try expectEqualStrings("Café — zsh", t.getTitle());
    _ = t.takeTitleChanged();
    t.feed("\x1b]1;icon\x07");
    try expect(t.takeTitleChanged());
    try expectEqualStrings("icon", t.getIconName());
    try expectEqualStrings("Café — zsh", t.getTitle());
    t.feed("\x1b]7;file://zen/home/user/src\x07");
    try expectEqualStrings("/home/user/src", t.getCwd());
    try expectEqualStrings("file://zen/home/user/src", t.getCwdUri());
    try expect(t.cwd_changed);
    t.feed("\x1b]8;id=1;https://example.com\x07link\x1b]8;;\x07 \x1b]52;c;Zm9v\x07ok\x1b]133;A\x07\x1b]1337;foo\x07");
    try expectRow(&t, 0, "link ok");
    try expectResponse(&t, "");
    // invalid UTF-8 in title is sanitized
    t.feed("\x1b]2;a\xffb\x07");
    try expectEqualStrings("a?b", t.getTitle());
    // long title is truncated
    t.feed("\x1b]2;");
    for (0..40) |_| t.feed("0123456789");
    t.feed("\x07");
    try expectEqual(@as(usize, 256), t.getTitle().len);
}

test "OSC color queries are answered from the theme" {
    var t = try newTerm(10, 2);
    defer t.deinit();
    t.feed("\x1b]11;?\x07");
    try expectResponse(&t, "\x1b]11;rgb:1e1e/1e1e/1e1e\x07");
    t.feed("\x1b]10;?\x1b\\");
    try expectResponse(&t, "\x1b]10;rgb:e6e6/e6e6/e6e6\x1b\\");
    t.feed("\x1b]10;?;?\x07");
    try expectResponse(&t, "\x1b]10;rgb:e6e6/e6e6/e6e6\x07\x1b]11;rgb:1e1e/1e1e/1e1e\x07");
    t.theme = @import("palette.zig").Theme.light;
    t.feed("\x1b]4;1;?;300;?\x07\x1b]11;?\x07");
    try expectResponse(&t, "\x1b]4;1;rgb:c2c2/3636/2121\x07\x1b]11;rgb:ffff/ffff/ffff\x07");
    t.feed("\x1b]4;1;#ff0000\x07\x1b]104\x07\x1b]11;rgb:00/00/00\x07");
    try expectResponse(&t, "");
}

const BellCounter = struct {
    n: usize = 0,
    fn ring(ctx: ?*anyopaque) void {
        const self: *BellCounter = @ptrCast(@alignCast(ctx.?));
        self.n += 1;
    }
};

test "BEL sets flag and calls the callback" {
    var t = try newTerm(10, 2);
    defer t.deinit();
    var counter: BellCounter = .{};
    t.on_bell = .{ .ctx = &counter, .func = BellCounter.ring };
    t.feed("a\x07b\x07");
    try expect(t.takeBell());
    try expect(!t.takeBell());
    try expectEqual(@as(usize, 2), counter.n);
    try expectEqual(@as(u32, 2), t.bell_count);
    // BEL terminating an OSC is not a bell
    t.feed("\x1b]0;x\x07");
    try expect(!t.takeBell());
    try expectRow(&t, 0, "ab");
}

// ---------------------------------------------------------------------------
// Modes and input encoding through the terminal

test "mode-dependent key, mouse, focus and paste encoding" {
    var t = try newTerm(10, 5);
    defer t.deinit();
    var buf: [64]u8 = undefined;
    try expectEqualStrings("\x1b[A", t.encodeKey(.up, .{}, &buf));
    t.feed("\x1b[?1h");
    try expectEqualStrings("\x1bOA", t.encodeKey(.up, .{}, &buf));
    try expectEqualStrings("\x1b[1;5A", t.encodeKey(.up, .{ .ctrl = true }, &buf));
    t.feed("\x1b[?1l\x1b=");
    try expectEqualStrings("\x1b[A", t.encodeKey(.up, .{}, &buf));
    try expectEqualStrings("\x1bOp", t.encodeKey(.{ .kp = .k0 }, .{}, &buf));
    t.feed("\x1b>");
    try expectEqualStrings("0", t.encodeKey(.{ .kp = .k0 }, .{}, &buf));

    const ev: input.MouseEvent = .{ .action = .press, .button = .left, .row = 2, .col = 3 };
    try expectEqualStrings("", t.encodeMouse(ev, &buf));
    try expect(!t.mouseReporting());
    t.feed("\x1b[?1000h\x1b[?1006h");
    try expect(t.mouseReporting());
    try expectEqualStrings("\x1b[<0;4;3M", t.encodeMouse(ev, &buf));
    t.feed("\x1b[?1006l");
    try expectEqualStrings("\x1b[M\x20\x24\x23", t.encodeMouse(ev, &buf));
    t.feed("\x1b[?1002h");
    try expectEqual(input.MouseTracking.button_event, t.modes.mouse_tracking);
    t.feed("\x1b[?1002l");
    try expectEqualStrings("", t.encodeMouse(ev, &buf));
    t.feed("\x1b[?9h");
    try expectEqual(input.MouseTracking.x10, t.modes.mouse_tracking);
    t.feed("\x1b[?9l\x1b[?1003h\x1b[?1005h");
    try expectEqual(input.MouseTracking.any_event, t.modes.mouse_tracking);
    try expectEqual(input.MouseEncoding.utf8, t.modes.mouse_encoding);

    try expectEqualStrings("", t.encodeFocus(true, &buf));
    t.feed("\x1b[?1004h");
    try expectEqualStrings("\x1b[I", t.encodeFocus(true, &buf));
    try expectEqualStrings("\x1b[O", t.encodeFocus(false, &buf));

    const plain = try t.encodePaste(testing.allocator, "a\nb");
    defer testing.allocator.free(plain);
    try expectEqualStrings("a\rb", plain);
    t.feed("\x1b[?2004h");
    const br = try t.encodePaste(testing.allocator, "a\nb");
    defer testing.allocator.free(br);
    try expectEqualStrings("\x1b[200~a\rb\x1b[201~", br);

    t.feed("\x1b[20h");
    try expectEqualStrings("\r\n", t.encodeKey(.enter, .{}, &buf));
    t.feed("\x1b[?5h\x1b[?1007h\x1b[?2026h");
    try expect(t.modes.reverse_video and t.modes.alternate_scroll and t.modes.synchronized_output);
}

// ---------------------------------------------------------------------------
// Damage tracking and viewport

test "damage tracking: dirty rows and cursor moved" {
    var t = try newTerm(10, 4);
    defer t.deinit();
    try expect(t.isRowDirty(0));
    t.clearDamage();
    for (0..4) |r| try expect(!t.isRowDirty(r));
    try expect(!t.cursorMoved());
    t.feed("\x1b[3;1Hx");
    try expect(t.isRowDirty(2));
    try expect(!t.isRowDirty(0) and !t.isRowDirty(1) and !t.isRowDirty(3));
    try expect(t.cursorMoved());
    try expectEqual(@as(usize, 0), t.damage_cursor.row);
    t.clearDamage();
    try expect(!t.cursorMoved());
    t.feed("\x1b[?25l");
    try expect(t.cursorMoved());
    t.clearDamage();
    // scrolling dirties the whole region
    t.feed("\x1b[4;1H\n");
    for (0..4) |r| try expect(t.isRowDirty(r));
    t.clearDamage();
    t.feed("\x1b[?1049h");
    try expect(t.all_dirty);
}

test "viewport scrollback browsing" {
    var t = try newTerm(5, 3);
    defer t.deinit();
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        t.feed(try std.fmt.bufPrint(&buf, "{s}L{d}", .{ if (i == 0) "" else "\r\n", i }));
    }
    try expectEqual(@as(usize, 7), t.scrollbackLen());
    var buf: [64]u8 = undefined;
    try expectEqualStrings("L7", cellsText(t.viewportRow(0), &buf));
    t.clearDamage();
    t.scrollViewport(2);
    try expectEqual(@as(usize, 2), t.viewport_offset);
    try expect(t.isRowDirty(0));
    try expectEqualStrings("L5", cellsText(t.viewportRow(0), &buf));
    try expectEqualStrings("L6", cellsText(t.viewportRow(1), &buf));
    try expectEqualStrings("L7", cellsText(t.viewportRow(2), &buf));
    try expectEqual(@as(u21, 'L'), t.viewportCell(0, 0).cp);
    try expectEqual(@as(u21, ' '), t.viewportCell(0, 4).cp);
    try expect(t.cursorViewportPos() == null);
    try expectEqual(@as(isize, -2), t.viewportToPos(0, 0).row);
    // New output keeps the viewed history in place.
    t.clearDamage();
    t.feed("\r\nX");
    try expectEqual(@as(usize, 3), t.viewport_offset);
    try expectEqualStrings("L5", cellsText(t.viewportRow(0), &buf));
    try expectEqualStrings("L7", cellsText(t.viewportRow(2), &buf));
    try expect(t.isRowDirty(0));
    t.scrollViewport(-100);
    try expectEqual(@as(usize, 0), t.viewport_offset);
    try expectEqualStrings("X", cellsText(t.viewportRow(2), &buf));
    try expectEqual(@as(usize, 2), t.cursorViewportPos().?.row);
    t.scrollViewportToTop();
    try expectEqual(t.scrollbackLen(), t.viewport_offset);
    try expectEqualStrings("L0", cellsText(t.viewportRow(0), &buf));
    try expectEqual(@as(usize, 0), t.posToViewport(.{ .row = -8, .col = 0 }).?);
    t.scrollViewportToBottom();
    try expectEqual(@as(usize, 0), t.viewport_offset);
    // alt screen has no scrollback
    t.feed("\x1b[?1049h");
    t.scrollViewport(5);
    try expectEqual(@as(usize, 0), t.viewport_offset);
    try expectEqual(@as(usize, 0), t.scrollbackLen());
}

// ---------------------------------------------------------------------------
// Selection

test "textInRange joins soft-wrapped lines and trims blanks" {
    var t = try newTerm(5, 4);
    defer t.deinit();
    t.feed("hello world\r\nab   ");
    try expectScreen(&t, &.{ "hello", " worl", "d", "ab" });
    const a = testing.allocator;
    const s1 = try t.textInRange(a, .{ .row = 0, .col = 0 }, .{ .row = 2, .col = 4 });
    defer a.free(s1);
    try expectEqualStrings("hello world", s1);
    const s2 = try t.textInRange(a, .{ .row = 3, .col = 4 }, .{ .row = 0, .col = 2 });
    defer a.free(s2);
    try expectEqualStrings("llo world\nab", s2);
    const s3 = try t.textInRange(a, .{ .row = 1, .col = 1 }, .{ .row = 1, .col = 3 });
    defer a.free(s3);
    try expectEqualStrings("wor", s3);
    // include scrollback
    t.feed("\r\nnext");
    try expectEqual(@as(usize, 1), t.scrollbackLen());
    const s4 = try t.textInRange(a, .{ .row = -1, .col = 0 }, .{ .row = 1, .col = 4 });
    defer a.free(s4);
    try expectEqualStrings("hello world", s4);
    const s5 = try t.textInRange(a, .{ .row = -50, .col = 0 }, .{ .row = 50, .col = 0 });
    defer a.free(s5);
    try expectEqualStrings("hello world\nab\nnext", s5);
}

test "wordAt selects words, blanks and punctuation runs across wraps" {
    var t = try newTerm(20, 3);
    defer t.deinit();
    t.feed("foo bar-baz  qux==x");
    var r = t.wordAt(0, 5).?;
    try expectEqual(Pos{ .row = 0, .col = 4 }, r.start);
    try expectEqual(Pos{ .row = 0, .col = 10 }, r.end);
    r = t.wordAt(0, 11).?;
    try expectEqual(@as(usize, 11), r.start.col);
    try expectEqual(@as(usize, 12), r.end.col);
    r = t.wordAt(0, 16).?;
    try expectEqual(@as(usize, 16), r.start.col);
    try expectEqual(@as(usize, 17), r.end.col);
    r = t.wordAt(0, 0).?;
    try expectEqual(@as(usize, 0), r.start.col);
    try expectEqual(@as(usize, 2), r.end.col);
    try expect(t.wordAt(99, 0) == null);

    var w = try newTerm(5, 3);
    defer w.deinit();
    w.feed("hello world");
    r = w.wordAt(1, 2).?;
    try expectEqual(Pos{ .row = 1, .col = 1 }, r.start);
    try expectEqual(Pos{ .row = 2, .col = 0 }, r.end);
    r = w.wordAt(0, 1).?;
    try expectEqual(Pos{ .row = 0, .col = 0 }, r.start);
    try expectEqual(Pos{ .row = 0, .col = 4 }, r.end);
    const s = try w.textInRange(testing.allocator, r.start, r.end);
    defer testing.allocator.free(s);
    try expectEqualStrings("hello", s);

    var c = try newTerm(12, 1);
    defer c.deinit();
    c.feed("ab 中文字 x");
    r = c.wordAt(0, 4).?; // spacer of 中
    try expectEqual(@as(usize, 3), r.start.col);
    try expectEqual(@as(usize, 8), r.end.col);
}

// ---------------------------------------------------------------------------
// Resize

test "resize: reflow soft-wrapped lines when narrowing and widening" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("abcdefghijklm");
    try expectScreen(&t, &.{ "abcdefghij", "klm", "" });
    try expectCursor(&t, 1, 3);
    try t.resize(5, 3);
    try expectScreen(&t, &.{ "abcde", "fghij", "klm" });
    try expectCursor(&t, 2, 3);
    try expect(t.isWrapped(0) and t.isWrapped(1) and !t.isWrapped(2));
    try checkInvariants(&t);
    try t.resize(10, 3);
    try expectScreen(&t, &.{ "abcdefghij", "klm", "" });
    try expectCursor(&t, 1, 3);
    t.feed("n");
    try expectRow(&t, 1, "klmn");
    try checkInvariants(&t);
}

test "resize: narrowing pushes overflow into scrollback, widening pulls it back" {
    var t = try newTerm(6, 3);
    defer t.deinit();
    t.feed("123456789\r\n$ ");
    try expectScreen(&t, &.{ "123456", "789", "$" });
    try t.resize(3, 3);
    try expectScreen(&t, &.{ "456", "789", "$" });
    try expectEqual(@as(usize, 1), t.scrollbackLen());
    try expectLine(&t, -1, "123");
    try expectCursor(&t, 2, 2);
    try t.resize(6, 3);
    try expectScreen(&t, &.{ "123456", "789", "$" });
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    try expectCursor(&t, 2, 2);
    try checkInvariants(&t);
}

test "resize: height changes exchange lines with scrollback" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("one\r\ntwo\r\nthree");
    try t.resize(10, 2);
    try expectScreen(&t, &.{ "two", "three" });
    try expectLine(&t, -1, "one");
    try expectCursor(&t, 1, 5);
    try t.resize(10, 4);
    try expectScreen(&t, &.{ "one", "two", "three", "" });
    try expectCursor(&t, 2, 5);
    try expectEqual(@as(usize, 0), t.scrollbackLen());

    // blank rows below the cursor are dropped first
    var u = try newTerm(10, 5);
    defer u.deinit();
    u.feed("hi");
    try u.resize(10, 2);
    try expectScreen(&u, &.{ "hi", "" });
    try expectEqual(@as(usize, 0), u.scrollbackLen());
    try expectCursor(&u, 0, 2);

    // cursor near the top stays visible; content below it is cut
    var v = try newTerm(4, 4);
    defer v.deinit();
    v.feed("a\r\nb\r\nc\r\nd\x1b[1;1H");
    try v.resize(4, 2);
    try expectScreen(&v, &.{ "a", "b" });
    try expectCursor(&v, 0, 0);
    try checkInvariants(&v);
}

test "resize: wide characters reflow without splitting" {
    var t = try newTerm(6, 3);
    defer t.deinit();
    t.feed("ab中文");
    try expectCursor(&t, 0, 5);
    try expect(t.cursor.pending_wrap);
    try t.resize(5, 3);
    try expectScreen(&t, &.{ "ab中", "文", "" });
    try expect(t.getCell(0, 4).attrs.wide_spacer);
    try expect(t.isWrapped(0));
    try expectCursor(&t, 1, 2);
    try checkInvariants(&t);
    const s = try t.textInRange(testing.allocator, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 4 });
    defer testing.allocator.free(s);
    try expectEqualStrings("ab中文", s);
    const s2 = try t.textInRange(testing.allocator, .{ .row = 0, .col = 0 }, .{ .row = 2, .col = 4 });
    defer testing.allocator.free(s2);
    try expectEqualStrings("ab中文\n", s2);
    try t.resize(1, 3);
    try checkInvariants(&t);
    try t.resize(8, 3);
    try expectRow(&t, 0, "ab中文");
    try checkInvariants(&t);
}

test "resize: pending wrap at the new edge is preserved" {
    var t = try newTerm(4, 2);
    defer t.deinit();
    t.feed("abcd");
    try t.resize(8, 2);
    try expectCursor(&t, 0, 4);
    try expect(!t.cursor.pending_wrap);
    t.feed("e");
    try expectRow(&t, 0, "abcde");
    try t.resize(5, 2);
    try expectCursor(&t, 0, 4);
    try expect(t.cursor.pending_wrap);
    t.feed("f");
    try expectScreen(&t, &.{ "abcde", "f" });
}

test "resize: alternate screen is cropped and primary is reflowed underneath" {
    var t = try newTerm(8, 3);
    defer t.deinit();
    t.feed("abcdefghij\r\n$ ");
    t.feed("\x1b[?1049h\x1b[Hfull row\x1b[3;1Hbottom");
    try t.resize(4, 2);
    try expect(t.isAltScreen());
    try expectScreen(&t, &.{ "full", "" });
    try expectCursor(&t, 1, 3);
    try checkInvariants(&t);
    t.feed("\x1b[?1049l");
    try expectScreen(&t, &.{ "ij", "$" });
    try expectCursor(&t, 1, 2);
    try expectEqual(@as(usize, 2), t.scrollbackLen());
    try checkInvariants(&t);
}

test "resize: resets scroll region, clamps, handles extremes" {
    var t = try newTerm(10, 10);
    defer t.deinit();
    t.feed("\x1b[2;8r\x1b[10;10Hx\x1b[3;3H\x1b7");
    try t.resize(5, 5);
    try expectEqual(@as(usize, 0), t.scroll_top);
    try expectEqual(@as(usize, 4), t.scroll_bottom);
    try checkInvariants(&t);
    try t.resize(1, 1);
    try checkInvariants(&t);
    t.feed("中文hello\r\n\x1b[5;5H\x1b[?1049hab\x1b[?1049l");
    try checkInvariants(&t);
    try t.resize(0, 0);
    try expectEqual(@as(usize, 1), t.cols);
    try t.resize(200, 60);
    try checkInvariants(&t);
    t.feed("\x1b8x");
    try checkInvariants(&t);
    // tab stops extend into new columns
    t.feed("\x1b[H\x1b[3g\r");
    try t.resize(20, 2);
    t.feed("\x1b[H\t");
    try expectCursor(&t, 0, 19);
}

test "resize with scrollback limit 0 and without content" {
    var t = try Terminal.init(testing.allocator, 4, 2, 0);
    defer t.deinit();
    t.feed("abcdefgh\r\nij");
    try t.resize(2, 2);
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    try checkInvariants(&t);
    try t.resize(6, 3);
    try checkInvariants(&t);
    var e = try newTerm(3, 3);
    defer e.deinit();
    try e.resize(7, 1);
    try e.resize(2, 9);
    try checkInvariants(&e);
}

test "resize survives allocation failure without corrupting state" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var t = try Terminal.init(fa.allocator(), 10, 4, 50);
    defer t.deinit();
    t.feed("some text that wraps around\r\nprompt$ ");
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        fa.fail_index = fa.alloc_index + i;
        t.resize(7, 3) catch {
            try expectEqual(@as(usize, 10), t.cols);
            try checkInvariants(&t);
            continue;
        };
        try checkInvariants(&t);
        break;
    }
    fa.fail_index = std.math.maxInt(usize);
    try t.resize(7, 3);
    try checkInvariants(&t);
}

// ---------------------------------------------------------------------------
// Replays of realistic output

test "replay: ls --color output and a prompt" {
    var t = try newTerm(40, 5);
    defer t.deinit();
    t.feed("user@zen:~$ ls --color=auto\r\n");
    t.feed("\x1b[0m\x1b[01;34mbin\x1b[0m  \x1b[01;34mboot\x1b[0m  \x1b[01;36mlib64\x1b[0m  \x1b[01;32mrun.sh\x1b[0m  notes.txt\r\n" ++
        "\x1b[01;31marchive.tar.gz\x1b[0m  \x1b[30;42mtmp\x1b[0m  \x1b[38;5;208mdata.json\x1b[0m\r\n");
    t.feed("\x1b]0;user@zen: ~\x07user@zen:~$ ");
    try expectScreen(&t, &.{
        "user@zen:~$ ls --color=auto",
        "bin  boot  lib64  run.sh  notes.txt",
        "archive.tar.gz  tmp  data.json",
        "user@zen:~$",
        "",
    });
    try expectCursor(&t, 3, 12);
    const bin = t.getCell(1, 0);
    try expect(bin.attrs.bold and bin.fg.eql(.{ .indexed = 4 }));
    try expect(t.getCell(1, 3).fg.eql(.default));
    try expect(t.getCell(1, 11).fg.eql(.{ .indexed = 6 }));
    try expect(t.getCell(1, 18).fg.eql(.{ .indexed = 2 }));
    try expect(!t.getCell(1, 26).attrs.bold);
    try expect(t.getCell(2, 0).fg.eql(.{ .indexed = 1 }));
    const tmp = t.getCell(2, 16);
    try expect(tmp.fg.eql(.{ .indexed = 0 }) and tmp.bg.eql(.{ .indexed = 2 }));
    try expect(t.getCell(2, 21).fg.eql(.{ .indexed = 208 }));
    try expectEqualStrings("user@zen: ~", t.getTitle());
    try checkInvariants(&t);
}

test "replay: full-screen editor session on the alternate screen" {
    var t = try newTerm(24, 6);
    defer t.deinit();
    t.feed("$ vi main.c\r\n");
    // startup: alt screen, app cursor keys, keypad, clear, hide cursor
    t.feed("\x1b[?1049h\x1b[22;0;0t\x1b[?1h\x1b=\x1b[H\x1b[2J\x1b[?25l");
    t.feed("\x1b[1;1H#include <stdio.h>\x1b[K" ++
        "\x1b[2;1Hint main(void) {\x1b[K" ++
        "\x1b[3;1H  return 0;\x1b[K" ++
        "\x1b[4;1H}\x1b[K" ++
        "\x1b[5;1H\x1b[94m~\x1b[0m\x1b[K" ++
        "\x1b[6;1H\x1b[7m\"main.c\" 4L, 52B\x1b[0m\x1b[6;19H1,1\x1b[1;1H\x1b[?25h");
    try expect(t.isAltScreen());
    try expect(t.modes.app_cursor and t.modes.app_keypad);
    try expectScreen(&t, &.{
        "#include <stdio.h>",
        "int main(void) {",
        "  return 0;",
        "}",
        "~",
        "\"main.c\" 4L, 52B  1,1",
    });
    try expect(t.getCell(5, 0).attrs.inverse);
    try expect(t.getCell(4, 0).fg.eql(.{ .indexed = 12 }));
    var kb: [16]u8 = undefined;
    try expectEqualStrings("\x1bOB", t.encodeKey(.down, .{}, &kb));

    // scroll the text area (rows 1-5) by one line and draw a new last line
    t.feed("\x1b[1;5r\x1b[1;1H\x1b[M\x1b[r\x1b[5;1H  printf(\"hi\\n\");\x1b[K");
    // edit in place: insert chars and delete a line
    t.feed("\x1b[3;3H\x1b[4@XXXX\x1b[6;1H\x1b[K-- INSERT --");
    try expectScreen(&t, &.{
        "int main(void) {",
        "  return 0;",
        "} XXXX",
        "~",
        "  printf(\"hi\\n\");",
        "-- INSERT --",
    });
    try expectEqual(@as(usize, 0), t.scrollbackLen());
    // quit
    t.feed("\x1b[?1l\x1b>\x1b[?1049l");
    try expect(!t.isAltScreen());
    try expect(!t.modes.app_cursor and !t.modes.app_keypad);
    try expectScreen(&t, &.{ "$ vi main.c", "", "", "", "", "" });
    try expectCursor(&t, 1, 0);
    try checkInvariants(&t);
}

test "replay: top-like periodic redraw with erase to end of line/screen" {
    var t = try newTerm(30, 4);
    defer t.deinit();
    const frames = [_][]const u8{
        "\x1b[H\x1b[1mtop - 10:00:01 up 1 day\x1b[m\x1b[K\r\nTasks: 120 total\x1b[K\r\n\x1b[7m  PID USER  %CPU\x1b[m\x1b[K\r\n    1 root   0.3\x1b[K\x1b[J",
        "\x1b[H\x1b[1mtop - 10:00:04 up 1 day\x1b[m\x1b[K\r\nTasks: 99 total\x1b[K\r\n\x1b[7m  PID USER  %CPU\x1b[m\x1b[K\r\n   42 zen   12.5\x1b[K\x1b[J",
    };
    for (frames) |f| t.feed(f);
    try expectScreen(&t, &.{ "top - 10:00:04 up 1 day", "Tasks: 99 total", "  PID USER  %CPU", "   42 zen   12.5" });
    try expect(t.getCell(0, 0).attrs.bold);
    try expect(!t.getCell(1, 0).attrs.bold);
    try expect(t.getCell(2, 0).attrs.inverse);
    try expectEqual(@as(usize, 0), t.scrollbackLen());
}

test "replay: shell line editing across a wrap (readline style)" {
    var t = try newTerm(10, 3);
    defer t.deinit();
    t.feed("$ echo abcdefghij");
    try expectScreen(&t, &.{ "$ echo abc", "defghij", "" });
    // backspace x3 with erase
    t.feed("\x08\x1b[K\x08\x1b[K\x08\x1b[K");
    try expectRow(&t, 1, "defg");
    // move to start of line across the wrap and redraw
    t.feed("\r\x1b[A\x1b[2C\x1b[K" ++ "ECHO abcdefg\x1b[K");
    try expectScreen(&t, &.{ "$ ECHO abc", "defg", "" });
    t.feed("\r\n");
    try expectCursor(&t, 2, 0);
    try checkInvariants(&t);
}

// ---------------------------------------------------------------------------
// Robustness

const Rng = struct {
    s: u64,
    fn next(self: *Rng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }
    fn below(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }
};

test "fuzz: random escape-heavy input keeps invariants" {
    var t = try Terminal.init(testing.allocator, 20, 8, 30);
    defer t.deinit();
    var rng: Rng = .{ .s = 0x9e3779b97f4a7c15 };
    const pieces = [_][]const u8{
        "\x1b[",       "\x1b]",       "\x1b",     "\x1bP",    ";",          "?",        "1",       "2",       "5",      "9",
        "m",           "H",           "J",        "K",        "L",          "M",        "@",       "P",       "X",      "r",
        "h",           "l",           "\r\n",     "\n",       "\t",         "\x08",     "中",     "😀",    "é",     "\xcc\x81",
        "\x1b(0",      "\x1b(B",      "\x0e",     "\x0f",     "\x1b7",      "\x1b8",    "\x1bM",   "\x1bD",   "\x1b#8", "\x07",
        "\x1b[?1049h", "\x1b[?1049l", "\x1b[?7l", "\x1b[?7h", "\x1b[?6h",   "\x1b[?6l", "\x1b[4h", "\x1b[4l", "b",      "\x1b\\",
        "abc",         "\xe4\xb8",    "\xff",     "\x18",     "38;2;1;2;3", "S",        "T",       "Z",       "I",      "\x1b[!p",
        "\x1b[2 q",    "\x1bc",       "@",        "d",        "G",          "\x1b[3J",  "3",       "0",       ":",      "\x1b[6n",
    };
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const p = pieces[rng.below(pieces.len)];
        t.feed(p);
        if (rng.below(64) == 0) {
            var buf: [1]u8 = .{@intCast(rng.below(256))};
            t.feed(&buf);
        }
        if (rng.below(1500) == 0) {
            try t.resize(1 + rng.below(40), 1 + rng.below(12));
        }
        if (rng.below(500) == 0) {
            t.scrollViewport(@as(isize, @intCast(rng.below(20))) - 10);
            _ = t.viewportRow(rng.below(t.rows));
            const r = t.wordAt(@as(isize, @intCast(rng.below(t.rows))), rng.below(t.cols));
            if (r) |rr| {
                const s = try t.textInRange(testing.allocator, rr.start, rr.end);
                testing.allocator.free(s);
            }
            const all = try t.textInRange(testing.allocator, .{ .row = t.firstRow(), .col = 0 }, .{ .row = @intCast(t.rows - 1), .col = t.cols - 1 });
            testing.allocator.free(all);
        }
        _ = t.takeResponse();
        if (i % 97 == 0) try checkInvariants(&t);
    }
    try checkInvariants(&t);
}

test "fuzz: purely random bytes" {
    var t = try Terminal.init(testing.allocator, 13, 5, 10);
    defer t.deinit();
    var rng: Rng = .{ .s = 12345 };
    var buf: [256]u8 = undefined;
    for (0..400) |_| {
        for (&buf) |*b| b.* = @intCast(rng.below(256));
        t.feed(&buf);
        _ = t.takeResponse();
        try checkInvariants(&t);
    }
}

fn expectSameState(a: *const Terminal, b: *const Terminal) !void {
    try expectEqual(a.cursor.row, b.cursor.row);
    try expectEqual(a.cursor.col, b.cursor.col);
    try expectEqual(a.cursor.pending_wrap, b.cursor.pending_wrap);
    try expectEqual(a.alt_active, b.alt_active);
    try expectEqual(a.scrollback.len, b.scrollback.len);
    for (0..a.rows) |r| {
        try expectEqual(a.isWrapped(r), b.isWrapped(r));
        for (a.getRow(r), b.getRow(r)) |x, y| try expect(x.eql(y));
    }
    var i: isize = -1;
    while (a.lineAt(i)) |la| : (i -= 1) {
        const lb = b.lineAt(i).?;
        try expectEqual(la.cells.len, lb.cells.len);
        for (la.cells, lb.cells) |x, y| try expect(x.eql(y));
    }
}

test "feeding whole buffers or byte-by-byte gives identical results" {
    const pieces = [_][]const u8{
        "hello ",         "world",     "\r\n",    "\x1b[31m",    "\x1b[1;4m",   "中文",  "é",     "😀",
        "\x1b[?7l",       "\x1b[?7h",  "\x1b[4h", "\x1b[4l",     "\x1b(0lqk",   "\x1b(B",  "\t",     "\x08",
        "\x1b[2;5H",      "\x1b[K",    "\x1b[3@", "\x1b[2P",     "\x1b[L",      "\x1b[M",  "\x1bM",  "\x1b]0;title\x07",
        "abcdefghijklmn", "\x1b[3;7r", "\x1b[r",  "\x1b[?1049h", "\x1b[?1049l", "\x1b[5b", "\x1b[J", "\x1b[38:2::1:2:3m",
        "\xe4\xb8",       "\xad",      "\xff",    "\x1b7",       "\x1b8",       "\x0e",    "\x0f",   "\x1b)0",
    };
    var rng: Rng = .{ .s = 0xdeadbeefcafe };
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);
    for (0..3000) |_| try stream.appendSlice(testing.allocator, pieces[rng.below(pieces.len)]);

    var whole = try Terminal.init(testing.allocator, 17, 7, 40);
    defer whole.deinit();
    var bytewise = try Terminal.init(testing.allocator, 17, 7, 40);
    defer bytewise.deinit();
    var chunked = try Terminal.init(testing.allocator, 17, 7, 40);
    defer chunked.deinit();
    whole.feed(stream.items);
    for (stream.items) |byte| bytewise.feed(&.{byte});
    var i: usize = 0;
    while (i < stream.items.len) {
        const n = @min(1 + rng.below(13), stream.items.len - i);
        chunked.feed(stream.items[i .. i + n]);
        i += n;
    }
    try expectSameState(&whole, &bytewise);
    try expectSameState(&whole, &chunked);
    try checkInvariants(&whole);
}

test "large output: scrolling many lines is bounded by the scrollback limit" {
    var t = try Terminal.init(testing.allocator, 80, 24, 1000);
    defer t.deinit();
    var buf: [100]u8 = undefined;
    for (0..5000) |i| {
        t.feed(try std.fmt.bufPrint(&buf, "line {d} \x1b[32mgreen\x1b[0m some more text to fill\r\n", .{i}));
    }
    try expectEqual(@as(usize, 1000), t.scrollbackLen());
    try expectRow(&t, 22, "line 4999 green some more text to fill");
    try expectRow(&t, 23, "");
    try expectLine(&t, -1, "line 4976 green some more text to fill");
    try expectLine(&t, -1000, "line 3977 green some more text to fill");
    try t.resize(40, 20);
    try checkInvariants(&t);
    try expectEqual(@as(usize, 1000), t.scrollbackLen());
    try t.resize(100, 30);
    try checkInvariants(&t);
}
