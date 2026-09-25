//! open — open files, folders and apps from the shell, like on macOS.
//!
//!   open FILE...            with the default app (TextEdit, Preview, Finder)
//!   open -a APP [FILE...]   with APP (name, bundle id or .app path)
//!   open -R FILE            reveal FILE in Finder
//!   open X.app              launch an app bundle
//!
//! Requests go to launchd (`launch:ctl`).

const std = @import("std");
const zen = @import("zen");

const usage =
    \\usage: open [-a app] [-R] file...
    \\  open notes.txt           open with the default app
    \\  open -a TextEdit x.txt   open with a specific app
    \\  open -R photo.png        show in Finder
    \\  open /Applications/Calculator.app
    \\
;

fn defaultApp(path: []const u8) ?[]const u8 {
    const stat = std.fs.cwd().statFile(path) catch return null;
    if (std.mem.endsWith(u8, std.mem.trimRight(u8, path, "/"), ".app")) return "";
    if (stat.kind == .directory) return "com.zen.Finder";
    const ext = std.fs.path.extension(path);
    const images = [_][]const u8{ ".png", ".ppm", ".pgm" };
    for (images) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "com.zen.Preview";
    return "com.zen.TextEdit";
}

fn quote(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    try out.append(a, '"');
    for (arg) |ch| {
        if (ch == '"' or ch == '\\') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '"');
}

fn send(a: std.mem.Allocator, line: []const u8) !bool {
    var reply: [512]u8 = undefined;
    const got = zen.io.transact("launch:ctl", line, &reply) catch |err| {
        std.debug.print("open: the launch service is not available ({s})\n", .{@errorName(err)});
        return false;
    };
    _ = a;
    const r = std.mem.trim(u8, got, " \r\n");
    if (std.mem.startsWith(u8, r, "ok")) return true;
    std.debug.print("open: {s}\n", .{if (std.mem.startsWith(u8, r, "error ")) r[6..] else r});
    return false;
}

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    var app: ?[]const u8 = null;
    var reveal = false;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}", .{usage});
                return 2;
            }
            app = args[i];
        } else if (std.mem.eql(u8, arg, "-R")) {
            reveal = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else try files.append(a, arg);
    }
    if (files.items.len == 0 and app == null) {
        std.debug.print("{s}", .{usage});
        return 2;
    }

    var status: u8 = 0;
    if (files.items.len == 0) {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(a, "open ");
        try quote(&line, a, app.?);
        return if (try send(a, line.items)) 0 else 1;
    }
    for (files.items) |f| {
        const abs = std.fs.cwd().realpathAlloc(a, f) catch {
            std.debug.print("open: {s}: no such file or directory\n", .{f});
            status = 1;
            continue;
        };
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(a, "open ");
        if (reveal) {
            try line.appendSlice(a, "com.zen.Finder ");
            try quote(&line, a, std.fs.path.dirname(abs) orelse "/");
        } else if (app) |name| {
            try quote(&line, a, name);
            try line.append(a, ' ');
            try quote(&line, a, abs);
        } else {
            const target = defaultApp(abs) orelse "com.zen.TextEdit";
            if (target.len == 0) {
                try quote(&line, a, abs); // an app bundle
            } else {
                try line.appendSlice(a, target);
                try line.append(a, ' ');
                try quote(&line, a, abs);
            }
        }
        if (!try send(a, line.items)) status = 1;
    }
    return status;
}
