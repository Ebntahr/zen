//! Lexer + recursive-descent parser for the zensh command language.
//!
//! The lexer and parser are fused because shell tokenisation is context
//! sensitive: `$(...)` bodies are parsed recursively while a word is being
//! scanned, here-document bodies are read after the newline that ends the
//! line on which they were introduced, and aliases are substituted when a word
//! appears in command position.
const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, Syntax, Incomplete };

pub const AliasLookup = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

const TokKind = enum {
    word,
    io_number,
    newline,
    eof,
    and_if, // &&
    or_if, // ||
    dsemi, // ;;
    semi_and, // ;&
    dsemi_and, // ;;&
    semi, // ;
    amp, // &
    pipe, // |
    pipe_amp, // |&
    lparen,
    rparen,
    less, // <
    great, // >
    dgreat, // >>
    clobber, // >|
    lessand, // <&
    greatand, // >&
    lessgreat, // <>
    dless, // <<
    dlessdash, // <<-
    tless, // <<<
    and_great, // &>
    and_dgreat, // &>>
};

const Token = struct {
    kind: TokKind,
    start: usize,
    end: usize,
    raw: []const u8 = "",
    word: ast.Word = ast.Word.empty,
    num: i32 = -1,
};

const PendingHeredoc = struct { h: *ast.Heredoc, alloc: Allocator };
const AliasRegion = struct { name: []const u8, end: usize };

const Mode = enum { word, dq, brace, brace_dq, pat, pat_dq, heredoc, arith, substr };

fn quotedMode(m: Mode) bool {
    return switch (m) {
        .dq, .brace_dq, .pat_dq, .heredoc, .arith => true,
        else => false,
    };
}

pub fn isMeta(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', ';', '&', '|', '(', ')', '<', '>' => true,
        else => false,
    };
}

pub fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn isName(s: []const u8) bool {
    if (s.len == 0 or !isNameStart(s[0])) return false;
    for (s[1..]) |c| if (!isNameChar(c)) return false;
    return true;
}

/// Function names: POSIX names plus the characters bash also accepts.
pub fn isFuncName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| {
        if (!(isNameChar(c) or c == '-' or c == '.' or c == ':' or c == '+' or c == '@' or c >= 0x80)) return false;
    }
    return !isKeyword(s);
}

pub const keywords = [_][]const u8{
    "if", "then", "else", "elif", "fi", "do", "done", "case", "esac", "while", "until", "for", "in", "{", "}", "!", "function",
};

pub fn isKeyword(s: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, s)) return true;
    return false;
}

const Builder = struct {
    a: Allocator,
    parts: std.ArrayList(ast.Part) = .empty,
    lit: std.ArrayList(u8) = .empty,
    lit_q: bool = false,

    fn addChar(b: *Builder, c: u8, quoted: bool) !void {
        if (b.lit.items.len > 0 and b.lit_q != quoted) try b.flush();
        b.lit_q = quoted;
        try b.lit.append(b.a, c);
    }

    fn addStr(b: *Builder, s: []const u8, quoted: bool) !void {
        if (s.len == 0) {
            if (quoted) {
                try b.flush();
                try b.parts.append(b.a, .{ .qlit = "" });
            }
            return;
        }
        if (b.lit.items.len > 0 and b.lit_q != quoted) try b.flush();
        b.lit_q = quoted;
        try b.lit.appendSlice(b.a, s);
    }

    fn flush(b: *Builder) !void {
        if (b.lit.items.len == 0) return;
        const s = try b.a.dupe(u8, b.lit.items);
        b.lit.clearRetainingCapacity();
        try b.parts.append(b.a, if (b.lit_q) .{ .qlit = s } else .{ .lit = s });
    }

    fn addPart(b: *Builder, p: ast.Part) !void {
        try b.flush();
        try b.parts.append(b.a, p);
    }

    fn finish(b: *Builder) ![]const ast.Part {
        try b.flush();
        b.lit.deinit(b.a);
        return b.parts.toOwnedSlice(b.a);
    }
};

pub const Parser = struct {
    /// Allocator for AST nodes. Switched to `persist` while parsing a
    /// function body so that function definitions outlive the command.
    alloc: Allocator,
    /// Long-lived allocator (parser bookkeeping, function bodies).
    persist: Allocator,
    src: []const u8,
    pos: usize = 0,
    peeked: ?Token = null,
    pending: std.ArrayList(PendingHeredoc) = .empty,
    aliases: ?AliasLookup = null,
    alias_regions: std.ArrayList(AliasRegion) = .empty,
    /// Source position following the text of an alias whose value ended
    /// in a blank: the word starting there is also checked for aliases.
    alias_blank_end: ?usize = null,
    /// More input can be appended (interactive / line-at-a-time source):
    /// reaching EOF inside a construct yields error.Incomplete.
    more_input: bool = false,
    err_msg: []const u8 = "",
    err_line: u32 = 0,
    err_buf: [256]u8 = undefined,
    line_base: u32 = 1,
    lc_pos: usize = 0,
    lc_line: u32 = 0,
    depth: u32 = 0,

    pub fn init(alloc: Allocator, persist: Allocator, src: []const u8) Parser {
        return .{ .alloc = alloc, .persist = persist, .src = src };
    }

    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.persist);
        for (self.alias_regions.items) |r| self.persist.free(r.name);
        self.alias_regions.deinit(self.persist);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    fn at(self: *Parser, i: usize) u8 {
        return if (i < self.src.len) self.src[i] else 0;
    }

    pub fn lineAt(self: *Parser, p: usize) u32 {
        const pos = @min(p, self.src.len);
        if (pos < self.lc_pos) {
            self.lc_pos = 0;
            self.lc_line = 0;
        }
        self.lc_line += @intCast(std.mem.count(u8, self.src[self.lc_pos..pos], "\n"));
        self.lc_pos = pos;
        return self.line_base + self.lc_line;
    }

    fn setErr(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        self.err_msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch "syntax error";
    }

    fn incomplete(self: *Parser) Error {
        if (self.more_input) return error.Incomplete;
        self.err_line = self.lineAt(self.pos);
        self.setErr("syntax error: unexpected end of file", .{});
        return error.Syntax;
    }

    fn syntax(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.err_line = self.lineAt(self.pos);
        self.setErr(fmt, args);
        return error.Syntax;
    }

    fn unexpected(self: *Parser, t: Token) Error {
        if (t.kind == .eof) return self.incomplete();
        self.err_line = self.lineAt(t.start);
        const txt = if (t.kind == .newline) "newline" else self.src[t.start..@min(t.end, self.src.len)];
        self.setErr("syntax error near unexpected token `{s}'", .{txt});
        return error.Syntax;
    }

    fn newNode(self: *Parser, n: ast.Node) !*ast.Node {
        const p = try self.alloc.create(ast.Node);
        p.* = n;
        return p;
    }

    fn textOf(self: *Parser, start: usize, end: usize) ![]const u8 {
        const s = @min(start, self.src.len);
        const e = @min(@max(end, s), self.src.len);
        return self.alloc.dupe(u8, std.mem.trim(u8, self.src[s..e], " \t\n;&"));
    }

    // ------------------------------------------------------------------
    // lexer
    // ------------------------------------------------------------------

    fn skipBlanks(self: *Parser) Error!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else if (c == '\\' and self.at(self.pos + 1) == '\n') {
                self.pos += 2;
                if (self.pos >= self.src.len and self.more_input) return error.Incomplete;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn peek(self: *Parser) Error!*Token {
        if (self.peeked == null) self.peeked = try self.lex();
        return &self.peeked.?;
    }

    fn advance(self: *Parser) Error!Token {
        const t = (try self.peek()).*;
        self.peeked = null;
        if (t.kind == .newline) try self.readHeredocs();
        return t;
    }

    fn lex(self: *Parser) Error!Token {
        try self.skipBlanks();
        const start = self.pos;
        if (start >= self.src.len) return .{ .kind = .eof, .start = start, .end = start };
        const c = self.src[start];
        const c1 = self.at(start + 1);
        const c2 = self.at(start + 2);
        var kind: TokKind = undefined;
        var len: usize = 1;
        switch (c) {
            '\n' => kind = .newline,
            '&' => {
                if (c1 == '&') {
                    kind = .and_if;
                    len = 2;
                } else if (c1 == '>') {
                    if (c2 == '>') {
                        kind = .and_dgreat;
                        len = 3;
                    } else {
                        kind = .and_great;
                        len = 2;
                    }
                } else kind = .amp;
            },
            '|' => {
                if (c1 == '|') {
                    kind = .or_if;
                    len = 2;
                } else if (c1 == '&') {
                    kind = .pipe_amp;
                    len = 2;
                } else kind = .pipe;
            },
            ';' => {
                if (c1 == ';') {
                    if (c2 == '&') {
                        kind = .dsemi_and;
                        len = 3;
                    } else {
                        kind = .dsemi;
                        len = 2;
                    }
                } else if (c1 == '&') {
                    kind = .semi_and;
                    len = 2;
                } else kind = .semi;
            },
            '(' => kind = .lparen,
            ')' => kind = .rparen,
            '<' => {
                if (c1 == '<') {
                    if (c2 == '<') {
                        kind = .tless;
                        len = 3;
                    } else if (c2 == '-') {
                        kind = .dlessdash;
                        len = 3;
                    } else {
                        kind = .dless;
                        len = 2;
                    }
                } else if (c1 == '&') {
                    kind = .lessand;
                    len = 2;
                } else if (c1 == '>') {
                    kind = .lessgreat;
                    len = 2;
                } else kind = .less;
            },
            '>' => {
                if (c1 == '>') {
                    kind = .dgreat;
                    len = 2;
                } else if (c1 == '&') {
                    kind = .greatand;
                    len = 2;
                } else if (c1 == '|') {
                    kind = .clobber;
                    len = 2;
                } else kind = .great;
            },
            '0'...'9' => {
                var e = start;
                while (e < self.src.len and std.ascii.isDigit(self.src[e])) e += 1;
                const n = self.at(e);
                if ((n == '<' or n == '>') and e - start <= 4) {
                    self.pos = e;
                    const num = std.fmt.parseInt(i32, self.src[start..e], 10) catch 0;
                    return .{ .kind = .io_number, .start = start, .end = e, .num = num, .raw = self.src[start..e] };
                }
                return self.lexWord();
            },
            else => return self.lexWord(),
        }
        self.pos = start + len;
        return .{ .kind = kind, .start = start, .end = self.pos, .raw = self.src[start..self.pos] };
    }

    fn lexWord(self: *Parser) Error!Token {
        const start = self.pos;
        var b = Builder{ .a = self.alloc };
        try self.parseParts(&b, .word);
        const parts = try b.finish();
        return .{ .kind = .word, .start = start, .end = self.pos, .raw = self.src[start..self.pos], .word = .{ .parts = parts } };
    }

    fn parseParts(self: *Parser, b: *Builder, mode: Mode) Error!void {
        const quoted = quotedMode(mode);
        var depth: u32 = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (mode) {
                .word => if (isMeta(c)) return,
                .dq => if (c == '"') return,
                .brace, .brace_dq => if (c == '}' and depth == 0) return,
                .pat, .pat_dq => if (c == '}' or c == '/') return,
                .substr => if (c == '}' or c == ':') return,
                .arith => if (c == ')' and depth == 0) return,
                .heredoc => {},
            }
            switch (c) {
                '\\' => {
                    if (self.pos + 1 >= self.src.len) {
                        try b.addChar('\\', true);
                        self.pos += 1;
                        continue;
                    }
                    const n = self.src[self.pos + 1];
                    if (n == '\n') {
                        self.pos += 2;
                        if (self.pos >= self.src.len and self.more_input) return error.Incomplete;
                        continue;
                    }
                    const special = switch (mode) {
                        .dq, .arith => n == '$' or n == '`' or n == '"' or n == '\\',
                        .brace_dq, .pat_dq => n == '$' or n == '`' or n == '"' or n == '\\' or n == '}' or n == '/',
                        .heredoc => n == '$' or n == '`' or n == '\\',
                        else => true,
                    };
                    if (special) {
                        try b.addChar(n, true);
                        self.pos += 2;
                    } else {
                        try b.addChar('\\', true);
                        self.pos += 1;
                    }
                },
                '\'' => {
                    if (quoted) {
                        try b.addChar(c, true);
                        self.pos += 1;
                        continue;
                    }
                    const end = std.mem.indexOfScalarPos(u8, self.src, self.pos + 1, '\'') orelse {
                        self.pos = self.src.len;
                        return self.incomplete();
                    };
                    try b.addStr(self.src[self.pos + 1 .. end], true);
                    self.pos = end + 1;
                },
                '"' => {
                    if (mode == .heredoc) {
                        try b.addChar(c, true);
                        self.pos += 1;
                        continue;
                    }
                    self.pos += 1;
                    var inner = Builder{ .a = self.alloc };
                    try self.parseParts(&inner, .dq);
                    if (self.pos >= self.src.len) return self.incomplete();
                    self.pos += 1; // closing quote
                    try b.addPart(.{ .dq = try inner.finish() });
                },
                '$' => try self.parseDollar(b, mode),
                '`' => try self.parseBackquote(b, mode),
                '(' => {
                    if (mode == .arith) depth += 1;
                    try b.addChar(c, quoted);
                    self.pos += 1;
                },
                ')' => {
                    if (mode == .arith) depth -= 1;
                    try b.addChar(c, quoted);
                    self.pos += 1;
                },
                '{' => {
                    if (mode == .brace) depth += 1;
                    try b.addChar(c, quoted);
                    self.pos += 1;
                },
                '}' => {
                    if (mode == .brace and depth > 0) depth -= 1;
                    try b.addChar(c, quoted);
                    self.pos += 1;
                },
                else => {
                    try b.addChar(c, quoted);
                    self.pos += 1;
                },
            }
        }
        switch (mode) {
            .word, .heredoc => return,
            else => return self.incomplete(),
        }
    }

    fn readParamName(self: *Parser) ?[]const u8 {
        const start = self.pos;
        const c = self.at(self.pos);
        if (isNameStart(c)) {
            while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
        } else if (std.ascii.isDigit(c)) {
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        } else if (c != 0 and std.mem.indexOfScalar(u8, "@*#?$!-", c) != null) {
            self.pos += 1;
        } else return null;
        return self.src[start..self.pos];
    }

    fn parseDollar(self: *Parser, b: *Builder, mode: Mode) Error!void {
        const in_dq = quotedMode(mode);
        self.pos += 1; // '$'
        if (self.pos >= self.src.len) {
            try b.addChar('$', in_dq);
            return;
        }
        const c = self.src[self.pos];
        switch (c) {
            '{' => return self.parseBraceParam(b, in_dq),
            '(' => {
                if (self.at(self.pos + 1) == '(') {
                    if (try self.tryArith(b)) return;
                }
                return self.parseCmdSubst(b);
            },
            '\'' => {
                if (in_dq) {
                    try b.addChar('$', true);
                    return;
                }
                return self.parseAnsiC(b);
            },
            '"' => {
                if (in_dq) try b.addChar('$', true);
                // $"..." (locale translation) is treated as "..."
                return;
            },
            else => {
                if (isNameStart(c)) {
                    const start = self.pos;
                    while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
                    const name = try self.alloc.dupe(u8, self.src[start..self.pos]);
                    const p = try self.alloc.create(ast.Param);
                    p.* = .{ .name = name };
                    try b.addPart(.{ .param = p });
                } else if (std.ascii.isDigit(c) or std.mem.indexOfScalar(u8, "@*#?$!-", c) != null) {
                    self.pos += 1;
                    const p = try self.alloc.create(ast.Param);
                    p.* = .{ .name = try self.alloc.dupe(u8, self.src[self.pos - 1 .. self.pos]) };
                    try b.addPart(.{ .param = p });
                } else {
                    try b.addChar('$', in_dq);
                }
            },
        }
    }

    /// Skip an unsupported ${...} expression up to its closing brace and
    /// record it so that the error is reported when (and if) it is expanded.
    noinline fn badSubst(self: *Parser, b: *Builder, start: usize) Error!void {
        var depth: usize = 1;
        var i = start + 2;
        while (i < self.src.len) : (i += 1) {
            switch (self.src[i]) {
                '\\' => i += 1,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                '\n' => break,
                else => {},
            }
        }
        if (i >= self.src.len or self.src[i] != '}') {
            if (i >= self.src.len) return self.incomplete();
            return self.syntax("bad substitution", .{});
        }
        self.pos = i + 1;
        const pp = try self.alloc.create(ast.Param);
        pp.* = .{ .name = try self.alloc.dupe(u8, self.src[start..self.pos]), .op = .bad };
        try b.addPart(.{ .param = pp });
    }

    noinline fn parseBraceParam(self: *Parser, b: *Builder, in_dq: bool) Error!void {
        const dollar = self.pos - 1;
        self.pos += 1; // '{'
        var p = ast.Param{ .name = "" };
        const argmode: Mode = if (in_dq) .brace_dq else .brace;
        if (self.at(self.pos) == '#') {
            const nx = self.at(self.pos + 1);
            if (nx == '}') {
                p.name = "#";
                self.pos += 1;
            } else if (isNameStart(nx) or std.ascii.isDigit(nx) or (nx != 0 and std.mem.indexOfScalar(u8, "@*#?$!", nx) != null)) {
                self.pos += 1;
                const save = self.pos;
                const nm = self.readParamName() orelse return self.badSubst(b, dollar);
                if (self.at(self.pos) == '}') {
                    p.name = nm;
                    p.op = .length;
                } else {
                    // ${#...op} where '#' is the parameter itself
                    self.pos = save;
                    p.name = "#";
                }
            } else {
                p.name = "#";
                self.pos += 1;
            }
        } else {
            p.name = self.readParamName() orelse {
                if (self.pos >= self.src.len) return self.incomplete();
                return self.badSubst(b, dollar);
            };
        }
        p.name = try self.alloc.dupe(u8, p.name);
        if (p.op == .none) {
            const c = self.at(self.pos);
            switch (c) {
                '}' => {},
                ':', '-', '=', '+', '?' => {
                    var oc = c;
                    if (c == ':') {
                        const n = self.at(self.pos + 1);
                        if (n == '-' or n == '=' or n == '+' or n == '?') {
                            p.colon = true;
                            self.pos += 1;
                            oc = n;
                        } else {
                            // substring ${x:off[:len]}
                            self.pos += 1;
                            p.op = .substr;
                            var ob = Builder{ .a = self.alloc };
                            try self.parseParts(&ob, .substr);
                            p.arg = .{ .parts = try ob.finish() };
                            if (self.at(self.pos) == ':') {
                                self.pos += 1;
                                var lb = Builder{ .a = self.alloc };
                                try self.parseParts(&lb, .substr);
                                p.arg2 = .{ .parts = try lb.finish() };
                            }
                        }
                    }
                    if (p.op == .none) {
                        p.op = switch (oc) {
                            '-' => .default,
                            '=' => .assign,
                            '+' => .alt,
                            else => .err,
                        };
                        self.pos += 1;
                        var ab = Builder{ .a = self.alloc };
                        try self.parseParts(&ab, argmode);
                        p.arg = .{ .parts = try ab.finish() };
                    }
                },
                '#', '%' => {
                    const long = self.at(self.pos + 1) == c;
                    p.op = if (c == '#') (if (long) .rm_prefix_long else .rm_prefix) else (if (long) .rm_suffix_long else .rm_suffix);
                    self.pos += if (long) 2 else 1;
                    // the pattern is not quoted by enclosing double quotes
                    var ab = Builder{ .a = self.alloc };
                    try self.parseParts(&ab, .brace);
                    p.arg = .{ .parts = try ab.finish() };
                },
                '/' => {
                    self.pos += 1;
                    p.op = .sub;
                    switch (self.at(self.pos)) {
                        '/' => {
                            p.op = .sub_all;
                            self.pos += 1;
                        },
                        '#' => {
                            p.op = .sub_prefix;
                            self.pos += 1;
                        },
                        '%' => {
                            p.op = .sub_suffix;
                            self.pos += 1;
                        },
                        else => {},
                    }
                    var pb = Builder{ .a = self.alloc };
                    try self.parseParts(&pb, .pat);
                    p.arg = .{ .parts = try pb.finish() };
                    if (self.at(self.pos) == '/') {
                        self.pos += 1;
                        var rb = Builder{ .a = self.alloc };
                        try self.parseParts(&rb, argmode);
                        p.arg2 = .{ .parts = try rb.finish() };
                    }
                },
                '^', ',' => {
                    const dbl = self.at(self.pos + 1) == c;
                    p.op = if (c == '^') (if (dbl) .upper_all else .upper_first) else (if (dbl) .lower_all else .lower_first);
                    self.pos += if (dbl) 2 else 1;
                },
                0 => return self.incomplete(),
                else => return self.badSubst(b, dollar),
            }
        }
        if (self.pos >= self.src.len) return self.incomplete();
        if (self.src[self.pos] != '}') return self.badSubst(b, dollar);
        self.pos += 1;
        const pp = try self.alloc.create(ast.Param);
        pp.* = p;
        try b.addPart(.{ .param = pp });
    }

    noinline fn tryArith(self: *Parser, b: *Builder) Error!bool {
        const save = self.pos;
        self.pos += 2; // "(("
        var inner = Builder{ .a = self.alloc };
        try self.parseParts(&inner, .arith);
        if (self.at(self.pos) == ')' and self.at(self.pos + 1) == ')') {
            self.pos += 2;
            try b.addPart(.{ .arith = try inner.finish() });
            return true;
        }
        self.pos = save;
        return false;
    }

    noinline fn parseCmdSubst(self: *Parser, b: *Builder) Error!void {
        self.pos += 1; // '('
        const saved_pending = self.pending;
        self.pending = .empty;
        const saved_peek = self.peeked;
        self.peeked = null;
        const saved_alias_next = self.alias_blank_end;
        self.alias_blank_end = null;
        self.depth += 1;
        if (self.depth > 120) return self.syntax("nesting too deep", .{});
        defer self.depth -= 1;

        var body: *ast.Node = undefined;
        const t = try self.peek();
        if (t.kind == .rparen) {
            body = try self.newNode(.{ .list = .{ .items = &.{} } });
        } else {
            body = try self.parseCompoundList();
        }
        const e = try self.peek();
        if (e.kind != .rparen) return self.unexpected(e.*);
        self.peeked = null;
        // restore outer state; keep any here-docs still pending from inside
        var inner_pending = self.pending;
        self.pending = saved_pending;
        try self.pending.appendSlice(self.persist, inner_pending.items);
        inner_pending.deinit(self.persist);
        self.peeked = saved_peek;
        self.alias_blank_end = saved_alias_next;
        try b.addPart(.{ .cmdsub = body });
    }

    noinline fn parseBackquote(self: *Parser, b: *Builder, mode: Mode) Error!void {
        const in_dq = quotedMode(mode);
        self.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.incomplete();
            const c = self.src[self.pos];
            if (c == '`') {
                self.pos += 1;
                break;
            }
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const n = self.src[self.pos + 1];
                if (n == '$' or n == '`' or n == '\\' or (in_dq and n == '"')) {
                    try buf.append(self.alloc, n);
                    self.pos += 2;
                    continue;
                }
                if (n == '\n') {
                    self.pos += 2;
                    continue;
                }
            }
            try buf.append(self.alloc, c);
            self.pos += 1;
        }
        var sp = Parser.init(self.alloc, self.persist, buf.items);
        sp.aliases = self.aliases;
        sp.line_base = self.lineAt(self.pos);
        sp.depth = self.depth + 1;
        defer sp.deinit();
        const node = sp.parseProgram() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.err_line = sp.err_line;
            self.setErr("{s}", .{sp.err_msg});
            return error.Syntax;
        };
        try b.addPart(.{ .cmdsub = node });
    }

    noinline fn parseAnsiC(self: *Parser, b: *Builder) Error!void {
        self.pos += 1; // '\''
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return self.incomplete();
            const c = self.src[self.pos];
            if (c == '\'') {
                self.pos += 1;
                break;
            }
            if (c != '\\' or self.pos + 1 >= self.src.len) {
                try out.append(self.alloc, c);
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            const e = self.src[self.pos];
            self.pos += 1;
            switch (e) {
                'n' => try out.append(self.alloc, '\n'),
                't' => try out.append(self.alloc, '\t'),
                'r' => try out.append(self.alloc, '\r'),
                'a' => try out.append(self.alloc, 7),
                'b' => try out.append(self.alloc, 8),
                'e', 'E' => try out.append(self.alloc, 27),
                'f' => try out.append(self.alloc, 12),
                'v' => try out.append(self.alloc, 11),
                '\\', '\'', '"', '?' => try out.append(self.alloc, e),
                'c' => {
                    const x = self.at(self.pos);
                    if (x != 0) {
                        self.pos += 1;
                        try out.append(self.alloc, std.ascii.toUpper(x) ^ 0x40);
                    }
                },
                '0'...'7' => {
                    var v: u32 = e - '0';
                    var k: usize = 0;
                    while (k < 2) : (k += 1) {
                        const d = self.at(self.pos);
                        if (d < '0' or d > '7') break;
                        v = v * 8 + (d - '0');
                        self.pos += 1;
                    }
                    try out.append(self.alloc, @truncate(v));
                },
                'x', 'u', 'U' => {
                    const maxd: usize = if (e == 'x') 2 else if (e == 'u') 4 else 8;
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < maxd) : (k += 1) {
                        const d = std.fmt.charToDigit(self.at(self.pos), 16) catch break;
                        v = v * 16 + d;
                        self.pos += 1;
                    }
                    if (k == 0) {
                        try out.append(self.alloc, '\\');
                        try out.append(self.alloc, e);
                    } else if (e == 'x') {
                        try out.append(self.alloc, @truncate(v));
                    } else {
                        var ub: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(@min(v, 0x10FFFF)), &ub) catch 0;
                        try out.appendSlice(self.alloc, ub[0..n]);
                    }
                },
                else => {
                    try out.append(self.alloc, '\\');
                    try out.append(self.alloc, e);
                },
            }
        }
        try b.addStr(out.items, true);
    }

    // ------------------------------------------------------------------
    // here-documents
    // ------------------------------------------------------------------

    noinline fn readHeredocs(self: *Parser) Error!void {
        if (self.pending.items.len == 0) return;
        var list = self.pending;
        self.pending = .empty;
        defer list.deinit(self.persist);
        for (list.items) |ph| {
            var body: std.ArrayList(u8) = .empty;
            var found = false;
            while (self.pos < self.src.len) {
                const nl = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n');
                const line_end = nl orelse self.src.len;
                var line = self.src[self.pos..line_end];
                const next = if (nl) |n| n + 1 else self.src.len;
                if (ph.h.strip_tabs) line = std.mem.trimLeft(u8, line, "\t");
                if (std.mem.eql(u8, line, ph.h.delim)) {
                    self.pos = next;
                    found = true;
                    break;
                }
                try body.appendSlice(ph.alloc, line);
                try body.append(ph.alloc, '\n');
                self.pos = next;
            }
            if (!found and self.more_input) return error.Incomplete;
            if (ph.h.expand) {
                var sp = Parser.init(ph.alloc, self.persist, body.items);
                sp.aliases = self.aliases;
                sp.depth = self.depth + 1;
                defer sp.deinit();
                var bb = Builder{ .a = ph.alloc };
                sp.parseParts(&bb, .heredoc) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    self.err_line = self.lineAt(self.pos);
                    self.setErr("{s}", .{sp.err_msg});
                    return error.Syntax;
                };
                ph.h.body = .{ .parts = try bb.finish() };
            } else {
                const parts = try ph.alloc.alloc(ast.Part, 1);
                parts[0] = .{ .qlit = body.items };
                ph.h.body = .{ .parts = parts };
            }
        }
    }

    /// Remove quotes from a here-document delimiter word.
    fn heredocDelim(self: *Parser, raw: []const u8, quoted: *bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        quoted.* = false;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            switch (c) {
                '\\' => {
                    quoted.* = true;
                    if (i + 1 < raw.len) {
                        i += 1;
                        try out.append(self.alloc, raw[i]);
                    }
                },
                '\'' => {
                    quoted.* = true;
                    i += 1;
                    while (i < raw.len and raw[i] != '\'') : (i += 1) try out.append(self.alloc, raw[i]);
                },
                '"' => {
                    quoted.* = true;
                    i += 1;
                    while (i < raw.len and raw[i] != '"') : (i += 1) {
                        if (raw[i] == '\\' and i + 1 < raw.len and std.mem.indexOfScalar(u8, "$`\"\\", raw[i + 1]) != null) i += 1;
                        try out.append(self.alloc, raw[i]);
                    }
                },
                else => try out.append(self.alloc, c),
            }
        }
        return out.toOwnedSlice(self.alloc);
    }

    // ------------------------------------------------------------------
    // aliases
    // ------------------------------------------------------------------

    fn aliasCheck(self: *Parser) Error!void {
        const lookup = self.aliases orelse return;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const t = (try self.peek()).*;
            if (t.kind != .word) return;
            const name = t.word.plainLit() orelse return;
            if (!std.mem.eql(u8, name, t.raw)) return;
            var i: usize = 0;
            while (i < self.alias_regions.items.len) {
                if (self.alias_regions.items[i].end <= t.start) {
                    self.persist.free(self.alias_regions.items[i].name);
                    _ = self.alias_regions.orderedRemove(i);
                } else i += 1;
            }
            for (self.alias_regions.items) |r| if (std.mem.eql(u8, r.name, name)) return;
            const value = lookup.get(lookup.ctx, name) orelse return;
            const old_len = t.end - t.start;
            const nb = try self.persist.alloc(u8, self.src.len - old_len + value.len);
            @memcpy(nb[0..t.start], self.src[0..t.start]);
            @memcpy(nb[t.start..][0..value.len], value);
            @memcpy(nb[t.start + value.len ..], self.src[t.end..]);
            for (self.alias_regions.items) |*r| {
                r.end = r.end + value.len - old_len;
            }
            if (self.alias_blank_end) |e| {
                if (e > t.start) self.alias_blank_end = e + value.len - old_len;
            }
            try self.alias_regions.append(self.persist, .{ .name = try self.persist.dupe(u8, name), .end = t.start + value.len });
            self.src = nb;
            self.pos = t.start;
            self.peeked = null;
            self.lc_pos = 0;
            self.lc_line = 0;
            if (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) {
                const e = t.start + value.len;
                if (self.alias_blank_end == null or self.alias_blank_end.? < e) self.alias_blank_end = e;
            }
        }
    }

    // ------------------------------------------------------------------
    // grammar
    // ------------------------------------------------------------------

    fn kwOf(t: *const Token) ?[]const u8 {
        if (t.kind != .word) return null;
        const s = t.word.plainLit() orelse return null;
        if (!std.mem.eql(u8, s, t.raw)) return null;
        if (isKeyword(s)) return s;
        return null;
    }

    fn isKw(t: *const Token, k: []const u8) bool {
        const s = kwOf(t) orelse return false;
        return std.mem.eql(u8, s, k);
    }

    fn isListEnd(t: *const Token) bool {
        switch (t.kind) {
            .eof, .rparen, .dsemi, .semi_and, .dsemi_and => return true,
            .word => {
                const k = kwOf(t) orelse return false;
                const ends = [_][]const u8{ "then", "else", "elif", "fi", "do", "done", "esac", "}" };
                for (ends) |e| if (std.mem.eql(u8, e, k)) return true;
                return false;
            },
            else => return false,
        }
    }

    fn isRedirTok(t: *const Token) bool {
        return switch (t.kind) {
            .io_number, .less, .great, .dgreat, .clobber, .lessand, .greatand, .lessgreat, .dless, .dlessdash, .tless, .and_great, .and_dgreat => true,
            else => false,
        };
    }

    fn skipNewlines(self: *Parser) Error!void {
        while ((try self.peek()).kind == .newline) _ = try self.advance();
    }

    fn expectKw(self: *Parser, k: []const u8) Error!void {
        const t = try self.peek();
        if (!isKw(t, k)) return self.unexpected(t.*);
        _ = try self.advance();
    }

    /// Parse one complete command (a list terminated by a newline).
    /// Returns null at end of input.
    pub fn parseCompleteCommand(self: *Parser) Error!?*ast.Node {
        try self.skipNewlines();
        const t = try self.peek();
        if (t.kind == .eof) {
            try self.readHeredocs();
            return null;
        }
        const node = try self.parseTopList();
        const t2 = try self.peek();
        switch (t2.kind) {
            .newline => _ = try self.advance(),
            .eof => try self.readHeredocs(),
            else => return self.unexpected(t2.*),
        }
        return node;
    }

    /// Parse all of the input into a single list node.
    pub fn parseProgram(self: *Parser) Error!*ast.Node {
        var items: std.ArrayList(ast.ListItem) = .empty;
        const a = self.alloc;
        while (try self.parseCompleteCommand()) |n| {
            switch (n.*) {
                .list => |l| try items.appendSlice(a, l.items),
                else => try items.append(a, .{ .node = n, .bg = false, .text = "" }),
            }
        }
        return self.newNode(.{ .list = .{ .items = try items.toOwnedSlice(a) } });
    }

    fn mkList(self: *Parser, items: *std.ArrayList(ast.ListItem), a: Allocator) Error!*ast.Node {
        if (items.items.len == 1 and !items.items[0].bg) return @constCast(items.items[0].node);
        return self.newNode(.{ .list = .{ .items = try items.toOwnedSlice(a) } });
    }

    fn parseTopList(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        var items: std.ArrayList(ast.ListItem) = .empty;
        while (true) {
            const start = (try self.peek()).start;
            const node = try self.parseAndOr();
            const t = try self.peek();
            const end = t.start;
            var sep = false;
            var bg = false;
            if (t.kind == .semi or t.kind == .amp) {
                sep = true;
                bg = t.kind == .amp;
                _ = try self.advance();
            }
            try items.append(a, .{ .node = node, .bg = bg, .text = if (bg) try self.textOf(start, end) else "" });
            if (!sep) break;
            const t3 = try self.peek();
            if (t3.kind == .newline or t3.kind == .eof) break;
        }
        return self.mkList(&items, a);
    }

    fn parseCompoundList(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        try self.skipNewlines();
        var items: std.ArrayList(ast.ListItem) = .empty;
        while (true) {
            const t = try self.peek();
            if (isListEnd(t)) break;
            const start = t.start;
            const node = try self.parseAndOr();
            const t2 = try self.peek();
            const end = t2.start;
            var sep = false;
            var bg = false;
            switch (t2.kind) {
                .semi, .newline => sep = true,
                .amp => {
                    sep = true;
                    bg = true;
                },
                else => {},
            }
            if (sep) _ = try self.advance();
            try items.append(a, .{ .node = node, .bg = bg, .text = if (bg) try self.textOf(start, end) else "" });
            if (!sep) break;
            try self.skipNewlines();
        }
        if (items.items.len == 0) {
            const t = try self.peek();
            return self.unexpected(t.*);
        }
        return self.mkList(&items, a);
    }

    fn parseAndOr(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        const first = try self.parsePipeline();
        var rest: std.ArrayList(ast.AndOrItem) = .empty;
        while (true) {
            const t = try self.peek();
            const op: ast.AndOrOp = switch (t.kind) {
                .and_if => .and_,
                .or_if => .or_,
                else => break,
            };
            _ = try self.advance();
            try self.skipNewlines();
            try rest.append(a, .{ .op = op, .node = try self.parsePipeline() });
        }
        if (rest.items.len == 0) return first;
        return self.newNode(.{ .and_or = .{ .first = first, .rest = try rest.toOwnedSlice(a) } });
    }

    fn parsePipeline(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        try self.aliasCheck();
        var bang = false;
        var timed = false;
        const t0 = try self.peek();
        const start = t0.start;
        if (t0.kind == .word and std.mem.eql(u8, t0.raw, "time") and t0.word.plainLit() != null) {
            _ = try self.advance();
            timed = true;
            try self.aliasCheck();
        }
        if (isKw(try self.peek(), "!")) {
            _ = try self.advance();
            bang = true;
        }
        if (timed) {
            // `time` alone (or followed by a terminator) times nothing
            const nt = try self.peek();
            if (nt.kind != .word and nt.kind != .lparen and !isRedirTok(nt)) {
                const empty = try self.newNode(.{ .list = .{ .items = &.{} } });
                const one = try a.alloc(*const ast.Node, 1);
                one[0] = empty;
                return self.newNode(.{ .pipeline = .{ .cmds = one, .bang = bang, .timed = true, .text = "time" } });
            }
        }
        var cmds: std.ArrayList(*const ast.Node) = .empty;
        try cmds.append(a, try self.parseCommand());
        while (true) {
            const t = try self.peek();
            if (t.kind != .pipe and t.kind != .pipe_amp) break;
            const both = t.kind == .pipe_amp;
            _ = try self.advance();
            if (both) {
                // cmd |& next  ==  cmd 2>&1 | next
                const prev = cmds.items[cmds.items.len - 1];
                const rs = try a.alloc(ast.Redir, 1);
                const tp = try a.alloc(ast.Part, 1);
                tp[0] = .{ .lit = "1" };
                rs[0] = .{ .fd = 2, .op = .dup_out, .target = .{ .parts = tp } };
                cmds.items[cmds.items.len - 1] = try self.newNode(.{ .redirected = .{ .body = prev, .redirs = rs } });
            }
            try self.skipNewlines();
            try cmds.append(a, try self.parseCommand());
        }
        const end = (try self.peek()).start;
        return self.newNode(.{ .pipeline = .{ .cmds = try cmds.toOwnedSlice(a), .bang = bang, .timed = timed, .text = try self.textOf(start, end) } });
    }

    fn parseCommand(self: *Parser) Error!*ast.Node {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 120) return self.syntax("nesting too deep", .{});
        try self.aliasCheck();
        const t = try self.peek();
        var node: *ast.Node = undefined;
        if (t.kind == .word) {
            if (kwOf(t)) |k| {
                if (std.mem.eql(u8, k, "if")) {
                    node = try self.parseIf();
                } else if (std.mem.eql(u8, k, "while") or std.mem.eql(u8, k, "until")) {
                    node = try self.parseLoop();
                } else if (std.mem.eql(u8, k, "for")) {
                    node = try self.parseFor();
                } else if (std.mem.eql(u8, k, "case")) {
                    node = try self.parseCase();
                } else if (std.mem.eql(u8, k, "{")) {
                    _ = try self.advance();
                    const body = try self.parseCompoundList();
                    try self.expectKw("}");
                    node = try self.newNode(.{ .group = body });
                } else if (std.mem.eql(u8, k, "function")) {
                    return self.parseFunctionKw();
                } else if (std.mem.eql(u8, k, "in")) {
                    return self.parseSimple();
                } else {
                    return self.unexpected(t.*);
                }
            } else return self.parseSimple();
        } else if (t.kind == .lparen) {
            node = try self.parseSubshellOrArith();
        } else if (isRedirTok(t)) {
            return self.parseSimple();
        } else return self.unexpected(t.*);
        return self.parseTrailingRedirs(node);
    }

    fn parseTrailingRedirs(self: *Parser, node: *ast.Node) Error!*ast.Node {
        const a = self.alloc;
        var redirs: std.ArrayList(ast.Redir) = .empty;
        while (isRedirTok(try self.peek())) try redirs.append(a, try self.parseRedir());
        if (redirs.items.len == 0) return node;
        return self.newNode(.{ .redirected = .{ .body = node, .redirs = try redirs.toOwnedSlice(a) } });
    }

    fn parseSubshellOrArith(self: *Parser) Error!*ast.Node {
        const t = (try self.peek()).*;
        if (self.at(t.end) == '(') {
            // (( arithmetic command ))
            const save_pos = self.pos;
            self.peeked = null;
            self.pos = t.end + 1;
            var inner = Builder{ .a = self.alloc };
            const ok = blk: {
                self.parseParts(&inner, .arith) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk false,
                };
                break :blk self.at(self.pos) == ')' and self.at(self.pos + 1) == ')';
            };
            if (ok) {
                self.pos += 2;
                return self.newNode(.{ .arith = .{ .expr = .{ .parts = try inner.finish() }, .line = self.lineAt(t.start) } });
            }
            self.pos = save_pos;
            self.peeked = t;
        }
        _ = try self.advance(); // '('
        const body = try self.parseCompoundList();
        const e = try self.peek();
        if (e.kind != .rparen) return self.unexpected(e.*);
        _ = try self.advance();
        return self.newNode(.{ .subshell = body });
    }

    fn parseIf(self: *Parser) Error!*ast.Node {
        _ = try self.advance(); // if / elif
        const cond = try self.parseCompoundList();
        try self.expectKw("then");
        const then = try self.parseCompoundList();
        const t = try self.peek();
        var else_: ?*const ast.Node = null;
        if (isKw(t, "elif")) {
            else_ = try self.parseIf();
            return self.newNode(.{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } });
        } else if (isKw(t, "else")) {
            _ = try self.advance();
            else_ = try self.parseCompoundList();
        }
        try self.expectKw("fi");
        return self.newNode(.{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } });
    }

    fn parseLoop(self: *Parser) Error!*ast.Node {
        const t = try self.advance();
        const until = std.mem.eql(u8, t.raw, "until");
        const cond = try self.parseCompoundList();
        try self.expectKw("do");
        const body = try self.parseCompoundList();
        try self.expectKw("done");
        return self.newNode(.{ .loop = .{ .cond = cond, .body = body, .until = until } });
    }

    fn parseFor(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        _ = try self.advance(); // for
        const nt = try self.peek();
        if (nt.kind != .word) return self.unexpected(nt.*);
        const name_raw = nt.raw;
        if (!isName(name_raw)) {
            self.err_line = self.lineAt(nt.start);
            self.setErr("`{s}': not a valid identifier", .{name_raw});
            return error.Syntax;
        }
        const name = try a.dupe(u8, name_raw);
        _ = try self.advance();
        try self.skipNewlines();
        var words: ?[]const ast.Word = null;
        const t = try self.peek();
        if (isKw(t, "in")) {
            _ = try self.advance();
            var list: std.ArrayList(ast.Word) = .empty;
            while (true) {
                const w = try self.peek();
                if (w.kind != .word) break;
                try list.append(a, (try self.advance()).word);
            }
            const s = try self.peek();
            if (s.kind == .semi or s.kind == .newline) {
                _ = try self.advance();
            } else if (!isKw(s, "do")) return self.unexpected(s.*);
            words = try list.toOwnedSlice(a);
        } else if (t.kind == .semi) {
            _ = try self.advance();
        }
        try self.skipNewlines();
        try self.expectKw("do");
        const body = try self.parseCompoundList();
        try self.expectKw("done");
        return self.newNode(.{ .for_ = .{ .name = name, .words = words, .body = body } });
    }

    fn parseCase(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        _ = try self.advance(); // case
        const wt = try self.peek();
        if (wt.kind != .word) return self.unexpected(wt.*);
        const word = (try self.advance()).word;
        try self.skipNewlines();
        try self.expectKw("in");
        try self.skipNewlines();
        var items: std.ArrayList(ast.CaseItem) = .empty;
        while (true) {
            const t = try self.peek();
            if (isKw(t, "esac")) {
                _ = try self.advance();
                break;
            }
            if (t.kind == .eof) return self.incomplete();
            if (t.kind == .lparen) _ = try self.advance();
            var pats: std.ArrayList(ast.Word) = .empty;
            while (true) {
                const pt = try self.peek();
                if (pt.kind != .word) return self.unexpected(pt.*);
                try pats.append(a, (try self.advance()).word);
                const sep = try self.peek();
                if (sep.kind == .pipe) {
                    _ = try self.advance();
                    continue;
                }
                if (sep.kind == .rparen) {
                    _ = try self.advance();
                    break;
                }
                return self.unexpected(sep.*);
            }
            try self.skipNewlines();
            var body: ?*const ast.Node = null;
            const bt = try self.peek();
            if (!(bt.kind == .dsemi or bt.kind == .semi_and or bt.kind == .dsemi_and or isKw(bt, "esac"))) {
                body = try self.parseCompoundList();
            }
            const et = try self.peek();
            var term: ast.CaseTerm = .brk;
            switch (et.kind) {
                .dsemi => _ = try self.advance(),
                .semi_and => {
                    term = .fallthrough;
                    _ = try self.advance();
                },
                .dsemi_and => {
                    term = .cont;
                    _ = try self.advance();
                },
                else => if (!isKw(et, "esac")) return self.unexpected(et.*),
            }
            try items.append(a, .{ .pats = try pats.toOwnedSlice(a), .body = body, .term = term });
            try self.skipNewlines();
        }
        return self.newNode(.{ .case_ = .{ .word = word, .items = try items.toOwnedSlice(a) } });
    }

    fn parseFuncBody(self: *Parser, name: []const u8, start: usize) Error!*ast.Node {
        const saved = self.alloc;
        self.alloc = self.persist;
        defer self.alloc = saved;
        try self.skipNewlines();
        const t = try self.peek();
        const k = kwOf(t);
        const compound = t.kind == .lparen or (k != null and (std.mem.eql(u8, k.?, "{") or std.mem.eql(u8, k.?, "if") or
            std.mem.eql(u8, k.?, "while") or std.mem.eql(u8, k.?, "until") or std.mem.eql(u8, k.?, "for") or
            std.mem.eql(u8, k.?, "case")));
        if (!compound) return self.unexpected(t.*);
        const body = try self.parseCommand();
        const end = @min(self.pos, self.src.len);
        const src_end = if (self.peeked) |p| @min(p.start, end) else end;
        const text = try self.persist.dupe(u8, std.mem.trim(u8, self.src[start..src_end], " \t\n"));
        self.alloc = saved;
        return self.newNode(.{ .func = .{ .name = try self.persist.dupe(u8, name), .body = body, .src = text } });
    }

    fn parseFuncDef(self: *Parser, name: []const u8, start: usize) Error!*ast.Node {
        _ = try self.advance(); // '('
        const t = try self.peek();
        if (t.kind != .rparen) return self.unexpected(t.*);
        _ = try self.advance();
        return self.parseFuncBody(name, start);
    }

    fn parseFunctionKw(self: *Parser) Error!*ast.Node {
        const kt = try self.advance(); // function
        const nt = try self.peek();
        if (nt.kind != .word) return self.unexpected(nt.*);
        const name = try self.alloc.dupe(u8, nt.raw);
        _ = try self.advance();
        const p = try self.peek();
        if (p.kind == .lparen) {
            _ = try self.advance();
            const r = try self.peek();
            if (r.kind != .rparen) return self.unexpected(r.*);
            _ = try self.advance();
        }
        return self.parseFuncBody(name, kt.start);
    }

    fn asAssignment(self: *Parser, t: *const Token) Error!?ast.Assign {
        if (t.word.parts.len == 0) return null;
        const first = switch (t.word.parts[0]) {
            .lit => |s| s,
            else => return null,
        };
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
        var name_end = eq;
        var append = false;
        if (eq > 0 and first[eq - 1] == '+') {
            name_end = eq - 1;
            append = true;
        }
        const name = first[0..name_end];
        if (!isName(name)) return null;
        const a = self.alloc;
        var parts: std.ArrayList(ast.Part) = .empty;
        if (eq + 1 < first.len) try parts.append(a, .{ .lit = first[eq + 1 ..] });
        try parts.appendSlice(a, t.word.parts[1..]);
        return .{ .name = name, .value = .{ .parts = try parts.toOwnedSlice(a) }, .append = append };
    }

    fn parseSimple(self: *Parser) Error!*ast.Node {
        const a = self.alloc;
        var assigns: std.ArrayList(ast.Assign) = .empty;
        var words: std.ArrayList(ast.Word) = .empty;
        var redirs: std.ArrayList(ast.Redir) = .empty;
        const line = self.lineAt((try self.peek()).start);
        defer self.alias_blank_end = null;
        while (true) {
            if (words.items.len == 0) {
                try self.aliasCheck();
            } else if (self.alias_blank_end) |e| {
                const pt = try self.peek();
                if (pt.start >= e) {
                    self.alias_blank_end = null;
                    try self.aliasCheck();
                }
            }
            const t = try self.peek();
            if (isRedirTok(t)) {
                try redirs.append(a, try self.parseRedir());
                continue;
            }
            if (t.kind != .word) break;
            if (words.items.len == 0) {
                if (try self.asAssignment(t)) |as| {
                    _ = try self.advance();
                    try assigns.append(a, as);
                    continue;
                }
            }
            const tok = try self.advance();
            if (words.items.len == 0 and assigns.items.len == 0 and redirs.items.len == 0) {
                const t2 = try self.peek();
                if (t2.kind == .lparen and isFuncName(tok.raw) and tok.word.plainLit() != null) {
                    return self.parseFuncDef(tok.raw, tok.start);
                }
            }
            try words.append(a, tok.word);
        }
        if (words.items.len == 0 and assigns.items.len == 0 and redirs.items.len == 0) {
            const t = try self.peek();
            return self.unexpected(t.*);
        }
        return self.newNode(.{ .simple = .{
            .assigns = try assigns.toOwnedSlice(a),
            .words = try words.toOwnedSlice(a),
            .redirs = try redirs.toOwnedSlice(a),
            .line = line,
        } });
    }

    fn parseRedir(self: *Parser) Error!ast.Redir {
        var fd: i32 = -1;
        var t = try self.advance();
        if (t.kind == .io_number) {
            fd = t.num;
            t = try self.advance();
        }
        const op: ast.RedirOp = switch (t.kind) {
            .less => .in,
            .great => .out,
            .dgreat => .append,
            .clobber => .clobber,
            .lessgreat => .rdwr,
            .lessand => .dup_in,
            .greatand => .dup_out,
            .dless, .dlessdash => .heredoc,
            .tless => .herestring,
            .and_great => .out_err,
            .and_dgreat => .append_err,
            else => return self.unexpected(t),
        };
        const strip = t.kind == .dlessdash;
        const w = try self.peek();
        if (w.kind != .word) return self.unexpected(w.*);
        const wt = try self.advance();
        var r = ast.Redir{ .fd = fd, .op = op, .target = wt.word };
        if (op == .heredoc) {
            var quoted = false;
            const delim = try self.heredocDelim(wt.raw, &quoted);
            const h = try self.alloc.create(ast.Heredoc);
            h.* = .{ .delim = delim, .strip_tabs = strip, .expand = !quoted };
            r.here = h;
            try self.pending.append(self.persist, .{ .h = h, .alloc = self.alloc });
        }
        return r;
    }
};

/// Parse the body of an expanding here-document / prompt string: `$`, `` ` ``
/// and backslash are special, quotes are literal.
pub fn parseHeredocText(alloc: Allocator, persist: Allocator, text: []const u8) Error![]const ast.Part {
    var sp = Parser.init(alloc, persist, text);
    defer sp.deinit();
    var b = Builder{ .a = alloc };
    try sp.parseParts(&b, .heredoc);
    return b.finish();
}

/// Parse a string as a single word (used for arithmetic sub-expressions etc.)
pub fn parseWordText(alloc: Allocator, persist: Allocator, text: []const u8) Error![]const ast.Part {
    var sp = Parser.init(alloc, persist, text);
    defer sp.deinit();
    var b = Builder{ .a = alloc };
    try sp.parseParts(&b, .dq);
    return b.finish();
}
