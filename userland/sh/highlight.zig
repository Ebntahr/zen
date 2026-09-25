//! Lightweight syntax highlighter for the line editor. It does not need to
//! be exact: it tokenises the buffer approximately and colours command
//! words (green if the command exists, red otherwise), keywords, strings,
//! variables, redirections and comments.
const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const exec = @import("exec.zig");
const Shell = shell.Shell;
const Allocator = std.mem.Allocator;

pub const Color = enum(u8) { none, command, missing, keyword, string, comment, variable, operator, option };

pub fn sgr(c: Color) []const u8 {
    return switch (c) {
        .none => "",
        .command => "\x1b[32m",
        .missing => "\x1b[31m",
        .keyword => "\x1b[35m",
        .string => "\x1b[33m",
        .comment => "\x1b[90m",
        .variable => "\x1b[36m",
        .operator => "\x1b[1m",
        .option => "\x1b[34m",
    };
}

/// Per-line cache of command lookups (PATH searches are not free).
pub const Cache = struct {
    map: std.StringHashMapUnmanaged(bool) = .empty,

    pub fn clear(self: *Cache, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        self.map.clearRetainingCapacity();
    }
};

pub fn commandExists(sh: *Shell, cache: *Cache, gpa: Allocator, name: []const u8) bool {
    if (name.len == 0) return false;
    if (builtins.lookup(name) != null or parser.isKeyword(name)) return true;
    if (sh.funcs.contains(name) or sh.aliases.contains(name)) return true;
    if (cache.map.get(name)) |v| return v;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const found = if (std.mem.indexOfScalar(u8, name, '/') != null)
        sys.isExecutableFile(name)
    else
        exec.searchPath(sh, name, sh.getVar("PATH") orelse "/bin:/usr/bin", false) != null and
            sys.isExecutableFile(exec.searchPath(sh, name, sh.getVar("PATH") orelse "/bin:/usr/bin", false).?);
    const k = gpa.dupe(u8, name) catch return found;
    cache.map.put(gpa, k, found) catch gpa.free(k);
    return found;
}

fn isSep(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

const cmd_keywords = [_][]const u8{ "if", "then", "else", "elif", "do", "while", "until", "!", "{", "time", "function" };

/// Returns one colour per byte of `text` (caller frees).
pub fn colorize(sh: *Shell, cache: *Cache, gpa: Allocator, text: []const u8) ![]Color {
    const colors = try gpa.alloc(Color, text.len);
    @memset(colors, .none);
    var i: usize = 0;
    var cmdpos = true;
    var after_redir = false;
    var name_next = false; // word after `for` / `case` / `function`
    while (i < text.len) {
        const c = text[i];
        if (isSep(c)) {
            if (c == '\n') cmdpos = true;
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < text.len and text[i] != '\n') : (i += 1) colors[i] = .comment;
            continue;
        }
        if (c == ';' or c == '&' or c == '|' or c == '(' or c == ')') {
            colors[i] = .operator;
            cmdpos = c != ')';
            i += 1;
            continue;
        }
        if (c == '<' or c == '>') {
            while (i < text.len and (text[i] == '<' or text[i] == '>' or text[i] == '&' or text[i] == '|' or text[i] == '-')) : (i += 1) colors[i] = .operator;
            after_redir = true;
            continue;
        }
        // a word
        const start = i;
        var plain = true;
        while (i < text.len and !isSep(text[i]) and std.mem.indexOfScalar(u8, ";&|()<>", text[i]) == null) {
            const ch = text[i];
            switch (ch) {
                '\\' => {
                    plain = false;
                    i = @min(text.len, i + 2);
                },
                '\'' => {
                    plain = false;
                    const s = i;
                    i += 1;
                    while (i < text.len and text[i] != '\'') i += 1;
                    i = @min(text.len, i + 1);
                    @memset(colors[s..i], .string);
                },
                '"' => {
                    plain = false;
                    const s = i;
                    i += 1;
                    while (i < text.len and text[i] != '"') {
                        if (text[i] == '\\') i += 1;
                        i += 1;
                    }
                    i = @min(text.len, i + 1);
                    @memset(colors[s..i], .string);
                },
                '$' => {
                    plain = false;
                    const s = i;
                    i += 1;
                    if (i < text.len and (text[i] == '(' or text[i] == '{')) {
                        const open = text[i];
                        const close: u8 = if (open == '(') ')' else '}';
                        var depth: usize = 0;
                        while (i < text.len) : (i += 1) {
                            if (text[i] == open) depth += 1;
                            if (text[i] == close) {
                                depth -= 1;
                                if (depth == 0) {
                                    i += 1;
                                    break;
                                }
                            }
                        }
                    } else {
                        while (i < text.len and (parser.isNameChar(text[i]) or (i == s + 1 and std.mem.indexOfScalar(u8, "@*#?$!-", text[i]) != null))) i += 1;
                    }
                    @memset(colors[s..@min(i, text.len)], .variable);
                },
                '`' => {
                    plain = false;
                    const s = i;
                    i += 1;
                    while (i < text.len and text[i] != '`') i += 1;
                    i = @min(text.len, i + 1);
                    @memset(colors[s..i], .variable);
                },
                else => i += 1,
            }
        }
        const word = text[start..i];
        if (after_redir) {
            after_redir = false;
            continue;
        }
        if (name_next) {
            name_next = false;
            continue;
        }
        if (!cmdpos) {
            if (plain and word.len > 1 and word[0] == '-') @memset(colors[start..i], .option);
            continue;
        }
        if (plain and parser.isKeyword(word)) {
            @memset(colors[start..i], .keyword);
            cmdpos = false;
            for (cmd_keywords) |k| {
                if (std.mem.eql(u8, k, word)) cmdpos = true;
            }
            if (std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "case") or std.mem.eql(u8, word, "function")) name_next = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, word, '=')) |eq| {
            if (eq > 0 and parser.isName(word[0..eq])) {
                // assignment: stays in command position
                continue;
            }
        }
        if (plain) {
            const ok = commandExists(sh, cache, gpa, word);
            @memset(colors[start..i], if (ok) .command else .missing);
        }
        cmdpos = false;
    }
    return colors;
}
