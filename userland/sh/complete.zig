//! Tab completion: commands (builtins, keywords, functions, aliases and
//! executables on PATH), file paths and variable names.
const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const Candidate = struct {
    /// Unescaped completion text for the whole word.
    text: []const u8,
    /// What to show in a listing.
    display: []const u8,
    is_dir: bool = false,
    is_exec: bool = false,
};

pub const Result = struct {
    start: usize,
    candidates: []Candidate,
    add_space: bool = true,
    /// insert text without escaping
    raw: bool = false,
};

const special = " \t\n\\'\"`$&;|()<>*?[]#!{}";

pub fn escape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, special, c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

pub fn unescape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var q: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (q != 0) {
            if (c == q) {
                q = 0;
                continue;
            }
            try out.append(a, c);
            continue;
        }
        if (c == '\'' or c == '"') {
            q = c;
            continue;
        }
        if (c == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(a, s[i]);
            continue;
        }
        try out.append(a, c);
    }
    return out.items;
}

fn lessThan(_: void, x: Candidate, y: Candidate) bool {
    return std.mem.order(u8, x.text, y.text) == .lt;
}

const cmd_before = [_][]const u8{ "then", "else", "do", "if", "elif", "while", "until", "!", "{", "time", "exec", "command", "builtin", "sudo", "nohup", "env" };

fn isBreak(line: []const u8, i: usize) bool {
    const c = line[i];
    if (std.mem.indexOfScalar(u8, " \t\n;|&()<>`", c) == null) return false;
    return !(i > 0 and line[i - 1] == '\\');
}

pub fn complete(sh: *Shell, a: Allocator, line: []const u8, pos: usize) !Result {
    var start = pos;
    while (start > 0 and !isBreak(line, start - 1)) start -= 1;
    const word = line[start..pos];

    // command position?
    var j = start;
    while (j > 0 and (line[j - 1] == ' ' or line[j - 1] == '\t')) j -= 1;
    var cmdpos = j == 0 or std.mem.indexOfScalar(u8, ";|&(`\n", line[j - 1]) != null;
    if (!cmdpos) {
        var ws = j;
        while (ws > 0 and !isBreak(line, ws - 1)) ws -= 1;
        const prev = line[ws..j];
        for (cmd_before) |k| {
            if (std.mem.eql(u8, k, prev)) cmdpos = true;
        }
    }

    var list: std.ArrayList(Candidate) = .empty;
    if (word.len > 0 and word[0] == '$') {
        const brace = word.len > 1 and word[1] == '{';
        const prefix = word[if (brace) 2 else 1..];
        var it = sh.vars.iterator();
        while (it.next()) |e| {
            const n = e.key_ptr.*;
            if (!std.mem.startsWith(u8, n, prefix)) continue;
            const text = try std.mem.concat(a, u8, &.{ if (brace) "${" else "$", n, if (brace) "}" else "" });
            try list.append(a, .{ .text = text, .display = n });
        }
        std.mem.sortUnstable(Candidate, list.items, {}, lessThan);
        return .{ .start = start, .candidates = list.items, .raw = true };
    }

    const uw = try unescape(a, word);
    if (cmdpos and std.mem.indexOfScalar(u8, uw, '/') == null and (uw.len == 0 or uw[0] != '~')) {
        if (uw.len == 0) return .{ .start = start, .candidates = &.{} };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const add = struct {
            fn f(al: Allocator, l: *std.ArrayList(Candidate), s: *std.StringHashMapUnmanaged(void), name: []const u8, exe: bool) !void {
                if (s.contains(name)) return;
                const n = try al.dupe(u8, name);
                try s.put(al, n, {});
                try l.append(al, .{ .text = n, .display = n, .is_exec = exe });
            }
        }.f;
        for (builtins.table) |b| {
            if (std.mem.startsWith(u8, b.name, uw)) try add(a, &list, &seen, b.name, false);
        }
        for (parser.keywords) |k| {
            if (std.mem.startsWith(u8, k, uw)) try add(a, &list, &seen, k, false);
        }
        var fit = sh.funcs.iterator();
        while (fit.next()) |e| {
            if (std.mem.startsWith(u8, e.key_ptr.*, uw)) try add(a, &list, &seen, e.key_ptr.*, false);
        }
        var ait = sh.aliases.iterator();
        while (ait.next()) |e| {
            if (std.mem.startsWith(u8, e.key_ptr.*, uw)) try add(a, &list, &seen, e.key_ptr.*, false);
        }
        const path = sh.getVar("PATH") orelse "/bin:/usr/bin";
        var pit = std.mem.splitScalar(u8, path, ':');
        while (pit.next()) |dir| {
            const d = if (dir.len == 0) "." else dir;
            var di = sys.DirIter.open(d) catch continue;
            defer di.close();
            while (di.next()) |e| {
                if (!std.mem.startsWith(u8, e.name, uw)) continue;
                if (seen.contains(e.name)) continue;
                const full = try std.mem.concat(a, u8, &.{ d, "/", e.name });
                if (!sys.isExecutableFile(full)) continue;
                try add(a, &list, &seen, e.name, true);
            }
        }
        std.mem.sortUnstable(Candidate, list.items, {}, lessThan);
        return .{ .start = start, .candidates = list.items };
    }

    // file names
    var dir_part: []const u8 = "";
    var base = uw;
    if (std.mem.lastIndexOfScalar(u8, uw, '/')) |sl| {
        dir_part = uw[0 .. sl + 1];
        base = uw[sl + 1 ..];
    }
    var list_dir: []const u8 = if (dir_part.len == 0) "." else dir_part;
    if (dir_part.len > 0 and dir_part[0] == '~') {
        const slash = std.mem.indexOfScalar(u8, dir_part, '/') orelse dir_part.len;
        const user = dir_part[1..slash];
        var home: ?[]const u8 = null;
        if (user.len == 0) home = sh.getVar("HOME") else if (shell.passwdLookup(a, .{ .name = user })) |pw| home = pw.home;
        if (home) |h| list_dir = try std.mem.concat(a, u8, &.{ h, dir_part[slash..] });
    } else if (dir_part.len == 0 and uw.len > 0 and uw[0] == '~') {
        // ~user completion
        const prefix = uw[1..];
        const data = shell.readFileAlloc(a, "/etc/passwd", 1 << 20) orelse "";
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            const n = l[0 .. std.mem.indexOfScalar(u8, l, ':') orelse continue];
            if (!std.mem.startsWith(u8, n, prefix)) continue;
            const t = try std.mem.concat(a, u8, &.{ "~", n, "/" });
            try list.append(a, .{ .text = t, .display = t, .is_dir = true });
        }
        std.mem.sortUnstable(Candidate, list.items, {}, lessThan);
        return .{ .start = start, .candidates = list.items };
    }
    var it = sys.DirIter.open(list_dir) catch return .{ .start = start, .candidates = &.{} };
    defer it.close();
    while (it.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, base)) continue;
        if (e.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const full = try std.mem.concat(a, u8, &.{ list_dir, if (list_dir[list_dir.len - 1] == '/') "" else "/", e.name });
        const is_dir = sys.isDir(full);
        const is_exec = !is_dir and sys.isExecutableFile(full);
        if (cmdpos and !is_dir and !is_exec) continue;
        const text = try std.mem.concat(a, u8, &.{ dir_part, e.name, if (is_dir) "/" else "" });
        const disp = try std.mem.concat(a, u8, &.{ e.name, if (is_dir) "/" else "" });
        try list.append(a, .{ .text = text, .display = disp, .is_dir = is_dir, .is_exec = is_exec });
    }
    std.mem.sortUnstable(Candidate, list.items, {}, lessThan);
    return .{ .start = start, .candidates = list.items };
}
