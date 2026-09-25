//! Host previews of Finder.
//!
//!   tools/zigmod run apps/Finder/preview.zig -O ReleaseFast -- [out_dir]
//!
//! Builds a sample home folder under /tmp/zen_apps/sample (folders, text
//! and image files, real .app bundles with Info.conf) and renders Finder in
//! several states, composited over the wallpaper like the window server.

const std = @import("std");
const ui = @import("ui");
const app = @import("app.zig");
const shot = @import("shot.zig");

const W = 900;
const H = 560;
/// 2026-09-25 15:30 UTC: the "now" of the previews.
const NOW: i64 = 1790350200;
const root = "/tmp/zen_apps/sample";
const home = root ++ "/Users/zen";

const File = struct { path: []const u8, body: []const u8 = "", age_min: i64 = 60 };

fn writeTree(a: std.mem.Allocator) !void {
    std.fs.cwd().deleteTree(root) catch {};
    const dirs = [_][]const u8{
        "Applications",                    "System/Library",                          "etc",
        "Users/zen/Desktop",               "Users/zen/Documents/Projects/zen-os",     "Users/zen/Documents/Invoices",
        "Users/zen/Documents/Recipes",     "Users/zen/Downloads/Photos",              "Users/zen/Downloads/Projects",
        "Users/zen/Pictures/Wallpapers",   "Users/zen/Music/Playlists",               "Users/zen/Movies",
        "Users/zen/Library/Preferences",   "Users/zen/Public",
    };
    for (dirs) |d| try std.fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/{s}", .{ root, d }));

    const lorem = "Zen OS is a microkernel desktop written in Zig for RISC-V.\nEverything is a URL.\n";
    const files = [_]File{
        .{ .path = "Users/zen/Documents/Zen OS Notes.txt", .body = lorem, .age_min = 35 },
        .{ .path = "Users/zen/Documents/README.md", .body = "# Zen OS\n\n" ++ lorem, .age_min = 60 * 26 },
        .{ .path = "Users/zen/Documents/Budget 2026.csv", .body = "month,amount\njan,1200\nfeb,980\n" ** 40, .age_min = 60 * 24 * 3 },
        .{ .path = "Users/zen/Documents/Vacation.png", .body = "\x89PNG" ++ "x" ** 2_400_000, .age_min = 60 * 24 * 12 },
        .{ .path = "Users/zen/Documents/kernel.zig", .body = "const std = @import(\"std\");\n" ** 120, .age_min = 90 },
        .{ .path = "Users/zen/Documents/Quarterly Report.pdf", .body = "%PDF" ++ "y" ** 812_000, .age_min = 60 * 24 * 40 },
        .{ .path = "Users/zen/Documents/todo.txt", .body = "- ship Finder\n- ship TextEdit\n", .age_min = 5 },
        .{ .path = "Users/zen/Documents/A very long document name that needs two lines.txt", .body = lorem, .age_min = 60 * 24 * 2 },
        .{ .path = "Users/zen/Downloads/zen-os-0.9-riscv64.img", .body = "z" ** 3_100_000, .age_min = 60 * 3 },
        .{ .path = "Users/zen/Downloads/Screenshot 2026-09-21 at 10.41.22.png", .body = "\x89PNG" ++ "s" ** 640_000, .age_min = 60 * 24 * 4 },
        .{ .path = "Users/zen/Downloads/Invoice-2026-09.pdf", .body = "%PDF" ++ "i" ** 52_000, .age_min = 60 * 20 },
        .{ .path = "Users/zen/Downloads/notes.txt", .body = lorem, .age_min = 12 },
        .{ .path = "Users/zen/Downloads/backup.tar.gz", .body = "b" ** 90_000, .age_min = 60 * 24 * 9 },
        .{ .path = "Users/zen/Downloads/Ambient Loop.mp3", .body = "m" ** 4_000_000, .age_min = 60 * 24 * 6 },
        .{ .path = "Users/zen/Downloads/A very long file name that wraps onto two lines in Finder.txt", .body = lorem, .age_min = 60 * 30 },
        .{ .path = "Users/zen/Desktop/Welcome.txt", .body = lorem, .age_min = 60 * 24 },
        .{ .path = "Users/zen/.profile", .body = "export PATH=/usr/bin\n", .age_min = 60 * 24 * 100 },
    };
    for (files) |f| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f.path });
        const file = try std.fs.cwd().createFile(p, .{});
        defer file.close();
        try file.writeAll(f.body);
        const t: i128 = @as(i128, NOW - f.age_min * 60) * std.time.ns_per_s;
        try file.updateTimes(t, t);
    }
    // Application bundles with real metadata.
    const bundles = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "Applications", "Calculator", "com.zen.Calculator", "calculator" },
        .{ "Applications", "Terminal", "com.zen.Terminal", "terminal" },
        .{ "Applications", "TextEdit", "com.zen.TextEdit", "textedit" },
        .{ "Applications", "Settings", "com.zen.Settings", "settings" },
        .{ "Applications", "Activity Monitor", "com.zen.ActivityMonitor", "activity" },
        .{ "Applications", "Finder", "com.zen.Finder", "finder" },
        .{ "Users/zen/Downloads", "Calculator", "com.zen.Calculator", "calculator" },
        .{ "Users/zen/Downloads", "Terminal", "com.zen.Terminal", "terminal" },
        .{ "Users/zen/Downloads", "Zen Setup", "org.example.ZenSetup", "zen" },
    };
    for (bundles) |b| {
        const dir = try std.fmt.allocPrint(a, "{s}/{s}/{s}.app/Contents/Bin", .{ root, b[0], b[1] });
        try std.fs.cwd().makePath(dir);
        const info = try std.fmt.allocPrint(a, "{s}/{s}/{s}.app/Contents/Info.conf", .{ root, b[0], b[1] });
        const body = try std.fmt.allocPrint(a, "id = {s}\nname = {s}\nexecutable = {s}\nicon = {s}\n", .{ b[2], b[1], b[1], b[3] });
        try std.fs.cwd().writeFile(.{ .sub_path = info, .data = body });
    }
    // Folder dates.
    const dated = [_]struct { []const u8, i64 }{
        .{ "Users/zen/Documents/Projects", 60 * 5 },       .{ "Users/zen/Documents/Invoices", 60 * 24 * 8 },
        .{ "Users/zen/Documents/Recipes", 60 * 24 * 60 },  .{ "Users/zen/Downloads/Photos", 60 * 24 * 2 },
        .{ "Users/zen/Downloads/Projects", 60 * 24 * 15 }, .{ "Users/zen/Downloads/Calculator.app", 60 * 24 * 20 },
        .{ "Users/zen/Downloads/Terminal.app", 60 * 24 * 21 }, .{ "Users/zen/Downloads/Zen Setup.app", 60 * 50 },
    };
    for (dated) |d| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, d[0] });
        var dir = try std.fs.cwd().openDir(p, .{ .iterate = true });
        defer dir.close();
        const t: i128 = @as(i128, NOW - d[1] * 60) * std.time.ns_per_s;
        const f = std.fs.File{ .handle = dir.fd };
        f.updateTimes(t, t) catch {};
    }
}

const Shot = struct {
    name: []const u8,
    dark: bool,
    opts: app.PreviewOptions,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try std.process.argsAlloc(a);
    const out_dir = if (args.len > 1) args[1] else "/tmp/zen_apps";
    try std.fs.cwd().makePath(out_dir);
    try writeTree(a);

    var fonts = try ui.FontSet.load(gpa);
    defer fonts.deinit();

    const downloads = home ++ "/Downloads";
    const documents = home ++ "/Documents";
    const shots = [_]Shot{
        .{ .name = "finder_icons_light", .dark = false, .opts = .{ .home = home, .location = downloads, .selected = "Terminal.app", .now = NOW } },
        .{ .name = "finder_icons_dark", .dark = true, .opts = .{ .home = home, .location = downloads, .selected = "Screenshot 2026-09-21 at 10.41.22.png", .now = NOW } },
        .{ .name = "finder_list_light", .dark = false, .opts = .{ .home = home, .location = documents, .view = .list, .selected = "kernel.zig", .now = NOW } },
        .{ .name = "finder_list_dark", .dark = true, .opts = .{ .home = home, .location = documents, .view = .list, .sort = .date, .ascending = false, .selected = "todo.txt", .now = NOW } },
        .{ .name = "finder_home_light", .dark = false, .opts = .{ .home = home, .location = home, .now = NOW } },
        .{ .name = "finder_apps_dark", .dark = true, .opts = .{ .home = home, .location = root ++ "/Applications", .selected = "TextEdit.app", .now = NOW } },
        .{ .name = "finder_search_light", .dark = false, .opts = .{ .home = home, .location = downloads, .search = "png", .now = NOW } },
        .{ .name = "finder_goto_light", .dark = false, .opts = .{ .home = home, .location = documents, .goto = "sys:proc", .now = NOW } },
        .{ .name = "finder_info_dark", .dark = true, .opts = .{ .home = home, .location = documents, .selected = "Budget 2026.csv", .info = true, .now = NOW } },
        .{ .name = "finder_rename_light", .dark = false, .opts = .{ .home = home, .location = documents, .selected = "Recipes", .rename = true, .alert = "\u{201C}Setup.app\u{201D} can\u{2019}t be opened: gatekeeper \u{201C}Setup.app\u{201D} is not signed.", .now = NOW } },
    };
    for (shots) |s| {
        app.preview_options = s.opts;
        var win = try ui.renderOnce(app.App, gpa, &fonts, s.dark, W, H);
        defer win.close();
        const path = try std.fmt.allocPrint(a, "{s}/{s}.png", .{ out_dir, s.name });
        try shot.write(gpa, &fonts, win.pixels, W, H, .{ .dark = s.dark, .translucent = true }, path);
        std.debug.print("wrote {s}\n", .{path});
    }
}
