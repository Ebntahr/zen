//! Unit tests for the self-contained pieces of zensh (run with
//! `zig test unit_tests.zig` or `zig build test`). The shell as a whole is
//! tested by tests/run.sh.
const std = @import("std");
const glob = @import("glob.zig");
const arith = @import("arith.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const brace = @import("brace.zig");
const editor = @import("editor.zig");

test {
    _ = glob;
}

test "arith.parseNumber" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 255), try arith.parseNumber("0xff"));
    try t.expectEqual(@as(i64, 8), try arith.parseNumber("010"));
    try t.expectEqual(@as(i64, 5), try arith.parseNumber("2#101"));
    try t.expectEqual(@as(i64, -42), try arith.parseNumber("-42"));
    try t.expectError(error.BadNumber, arith.parseNumber("08"));
}

fn parseOne(a: std.mem.Allocator, src: []const u8) !*ast.Node {
    var p = parser.Parser.init(a, a, src);
    defer p.deinit();
    return (try p.parseCompleteCommand()).?;
}

test "parser: pipelines, and-or lists and compound commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try parseOne(a, "a | b && ! c || d\n");
    try std.testing.expect(n.* == .and_or);
    try std.testing.expectEqual(@as(usize, 2), n.and_or.rest.len);
    const f = try parseOne(a, "for x in 1 2; do echo $x; done\n");
    try std.testing.expect(f.* == .pipeline);
    try std.testing.expect(f.pipeline.cmds[0].* == .for_);
    const c = try parseOne(a, "case $v in a|b) x ;; (*) y ;; esac\n");
    try std.testing.expectEqual(@as(usize, 2), c.pipeline.cmds[0].case_.items.len);
}

test "parser: incomplete input is reported for continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "if true; then\n", "echo \"abc\n", "cat <<EOF\nx\n", "a &&\n", "f() {\n" }) |src| {
        var p = parser.Parser.init(a, a, src);
        defer p.deinit();
        p.more_input = true;
        try std.testing.expectError(error.Incomplete, p.parseCompleteCommand());
    }
}

test "parser: syntax errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "fi\n", "echo ;;\n", "( )\n", "if true; then fi\n" }) |src| {
        var p = parser.Parser.init(a, a, src);
        defer p.deinit();
        try std.testing.expectError(error.Syntax, p.parseCompleteCommand());
    }
}

test "brace expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = [_]ast.Part{.{ .lit = "a{b,c}d{1..2}" }};
    const words = try brace.expand(a, .{ .parts = &parts });
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("abd1", words[0].parts[0].lit);
    try std.testing.expectEqualStrings("acd2", words[3].parts[0].lit);
}

test "display width" {
    try std.testing.expectEqual(@as(usize, 3), editor.visibleWidth("\x1b[1;32m❯\x1b[0m ab"[0..]) - 1);
    try std.testing.expectEqual(@as(usize, 2), editor.visibleWidth("\x01\x1b[31m\x02ab"));
    try std.testing.expectEqual(@as(usize, 4), editor.visibleWidth("日本"));
}
