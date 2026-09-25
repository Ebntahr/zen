//! Host previews of TextEdit.
//!
//!   tools/zigmod run apps/TextEdit/preview.zig -O ReleaseFast -- [out_dir] [WxH]
//!
//! Renders a sample document (with a selection, the caret, mono mode, the
//! Save As sheet and the unsaved-changes alert), composited over the
//! wallpaper like the window server.

const std = @import("std");
const ui = @import("ui");
const app = @import("app.zig");
const shot = @import("shot.zig");

const default_w = 700;
const default_h = 520;
const docs = "/tmp/zen_apps/sample_textedit/Documents";

const sample =
    "Zen OS \u{2014} Release Notes\n" ++
    "\n" ++
    "Zen OS is a desktop operating system for RISC\u{2011}V 64, written in Zig. It follows three ideas: a microkernel, \u{201C}everything is a URL\u{201D}, and POSIX on top. Files live at file:/Users/zen, the process table at sys:proc and apps are launched through launch:ctl.\n" ++
    "\n" ++
    "What\u{2019}s new in 0.9\n" ++
    "\t\u{2022} Finder with icon and list views, Go to Folder for any URL, and a translucent sidebar.\n" ++
    "\t\u{2022} TextEdit, a plain-text editor with undo, word count and Plain Text Mono.\n" ++
    "\t\u{2022} Liquid Glass materials throughout the desktop.\n" ++
    "\n" ++
    "Known issues: the kernel is still being written, so the system does not boot yet. \u{00DC}n\u{00EF}c\u{00F6}d\u{00E9} text \u{2014} na\u{00EF}ve caf\u{00E9}, \u{0395}\u{03BB}\u{03BB}\u{03AC}\u{03B4}\u{03B1}, \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{2014} is edited safely as UTF\u{2011}8.\n";

const code =
    \\const std = @import("std");
    \\
    \\/// Greets everything, because everything is a URL.
    \\pub fn main() !void {
    \\    const urls = [_][]const u8{ "file:/Users/zen", "sys:proc", "launch:ctl" };
    \\    for (urls) |url| {
    \\        std.debug.print("hello, {s}\n", .{url});
    \\    }
    \\}
    \\
;

fn writeDocs() !void {
    std.fs.cwd().deleteTree("/tmp/zen_apps/sample_textedit") catch {};
    try std.fs.cwd().makePath(docs ++ "/Drafts");
    try std.fs.cwd().makePath(docs ++ "/Notes");
    const files = [_][]const u8{ "Release Notes.txt", "Shopping List.txt", "hello.zig", "Ideas.md", "Meeting 2026-09-24.txt" };
    for (files) |f| {
        const p = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ docs, f });
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = sample });
    }
}

const Shot = struct { name: []const u8, dark: bool, opts: app.PreviewOptions };

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const out_dir = if (args.len > 1) args[1] else "/tmp/zen_apps";
    // Optional window size, e.g. "460x300", to check small layouts.
    var W: i32 = default_w;
    var H: i32 = default_h;
    if (args.len > 2) {
        var it = std.mem.splitScalar(u8, args[2], 'x');
        W = try std.fmt.parseInt(i32, it.next() orelse "", 10);
        H = try std.fmt.parseInt(i32, it.next() orelse "", 10);
    }
    try std.fs.cwd().makePath(out_dir);
    try writeDocs();

    var fonts = try ui.FontSet.load(gpa);
    defer fonts.deinit();

    const sel_a = std.mem.indexOf(u8, sample, "three ideas").?;
    const sel_b = std.mem.indexOf(u8, sample, ", and POSIX").?;
    const caret = std.mem.indexOf(u8, sample, "Liquid Glass").? + 6;
    const code_caret = std.mem.indexOf(u8, code, "hello, ").? + 5;
    const shots = [_]Shot{
        .{ .name = "textedit_light", .dark = false, .opts = .{ .text = sample, .path = docs ++ "/Release Notes.txt", .documents = docs, .cursor = sel_b, .anchor = sel_a } },
        .{ .name = "textedit_dark", .dark = true, .opts = .{ .text = sample, .path = docs ++ "/Release Notes.txt", .documents = docs, .cursor = caret, .anchor = caret, .dirty = true } },
        .{ .name = "textedit_mono_light", .dark = false, .opts = .{ .text = code, .path = docs ++ "/hello.zig", .documents = docs, .cursor = code_caret, .anchor = code_caret, .mono = true, .size = 14, .wrap = false } },
        .{ .name = "textedit_save_light", .dark = false, .opts = .{ .text = sample, .documents = docs, .cursor = caret, .anchor = caret, .dirty = true, .sheet = .save, .sheet_text = "Release Notes 2.txt" } },
        .{ .name = "textedit_find_light", .dark = false, .opts = .{ .text = sample, .path = docs ++ "/Release Notes.txt", .documents = docs, .find = "zen", .replace = "Zen OS" } },
        .{ .name = "textedit_find_dark", .dark = true, .opts = .{ .text = sample, .path = docs ++ "/Release Notes.txt", .documents = docs, .find = "url" } },
        .{ .name = "textedit_confirm_dark", .dark = true, .opts = .{ .text = sample, .documents = docs, .cursor = caret, .anchor = caret, .dirty = true, .sheet = .confirm } },
    };
    for (shots) |s| {
        app.preview_options = s.opts;
        var win = try ui.renderOnce(app.App, gpa, &fonts, s.dark, W, H);
        defer win.close();
        const title = if (s.opts.path) |p| std.fs.path.basename(p) else "Untitled";
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ out_dir, s.name });
        defer gpa.free(path);
        try shot.write(gpa, &fonts, win.pixels, W, H, .{ .dark = s.dark, .title = title, .edited = s.opts.dirty }, path);
        std.debug.print("wrote {s}\n", .{path});
    }
}
