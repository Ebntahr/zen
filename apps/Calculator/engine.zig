//! Calculator arithmetic (no UI): a macOS-style basic/scientific calculator
//! state machine working on f64.
//!
//! * Binary operators respect precedence (2 + 3 × 4 = 14) using an operand /
//!   operator stack; xʸ and ʸ√x bind tighter and are right-associative.
//! * Pressing "=" again repeats the last operation (2 + 3 = = → 8).
//! * "%" divides by 100, or after + / − takes that percentage of the left
//!   operand (50 + 10 % → 5, = → 55).
//! * Division by zero and other invalid results show "Error".
//! * Results are shown with at most `max_digits` significant digits,
//!   thousands separators and scientific notation ("1.2346e15") when needed.
//!
//! The engine also keeps a one-line expression ("1,200+34.56+") for the
//! small history line above the result.

const std = @import("std");

pub const max_depth = 32;
const max_entry = 40;
const expr_cap = 192;

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    /// x to the power y.
    pow,
    /// y-th root of x.
    root,

    pub fn precedence(op: BinOp) u8 {
        return switch (op) {
            .add, .sub => 1,
            .mul, .div => 2,
            .pow, .root => 3,
        };
    }

    pub fn rightAssoc(op: BinOp) bool {
        return op == .pow or op == .root;
    }

    pub fn symbol(op: BinOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "\u{2212}",
            .mul => "\u{00D7}",
            .div => "\u{00F7}",
            .pow => "^",
            .root => "\u{221A}",
        };
    }

    pub fn apply(op: BinOp, a: f64, b: f64) f64 {
        return switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) std.math.nan(f64) else a / b,
            .pow => std.math.pow(f64, a, b),
            .root => rootOf(a, b),
        };
    }
};

fn rootOf(x: f64, y: f64) f64 {
    if (y == 0) return std.math.nan(f64);
    // Odd integer roots of negative numbers are real.
    if (x < 0) {
        const yi = @round(y);
        if (yi == y and @mod(yi, 2) == 1) return -std.math.pow(f64, -x, 1 / y);
        return std.math.nan(f64);
    }
    return std.math.pow(f64, x, 1 / y);
}

pub const Func = enum {
    sin,
    cos,
    tan,
    ln,
    log10,
    sqrt,
    cbrt,
    square,
    cube,
    exp,
    exp10,
    recip,
    fact,

    /// Text used in the expression line, e.g. "sin(30)".
    pub fn prefix(f: Func) []const u8 {
        return switch (f) {
            .sin => "sin",
            .cos => "cos",
            .tan => "tan",
            .ln => "ln",
            .log10 => "log",
            .sqrt => "\u{221A}",
            .cbrt => "\u{221B}",
            .square, .cube, .fact, .recip => "",
            .exp => "e^",
            .exp10 => "10^",
        };
    }

    pub fn suffix(f: Func) []const u8 {
        return switch (f) {
            .square => "\u{00B2}",
            .cube => "\u{00B3}",
            .fact => "!",
            .recip => "\u{207B}\u{00B9}",
            else => "",
        };
    }
};

pub const Mode = enum {
    /// The user is typing a number into `entry`.
    typing,
    /// A binary operator was just pressed; the next digit starts a new operand
    /// and another operator replaces it.
    after_op,
    /// Showing a computed value (after =, %, ±, a function, a constant…).
    result,
};

const Tok = union(enum) {
    op: BinOp,
    lparen,
};

pub const Engine = struct {
    /// Significant digits shown (9 in basic mode like macOS).
    max_digits: u8 = 9,
    /// Trigonometry in degrees (default) or radians.
    degrees: bool = true,

    vals: [max_depth]f64 = undefined,
    nv: usize = 0,
    ops: [max_depth]Tok = undefined,
    no: usize = 0,
    /// Position in `expr` of each open parenthesis.
    paren_pos: [max_depth]usize = undefined,

    /// Current operand / displayed value.
    cur: f64 = 0,
    entry: [max_entry]u8 = undefined,
    entry_len: usize = 0,
    mode: Mode = .result,
    after_equals: bool = false,
    err: bool = false,

    last_op: ?BinOp = null,
    last_rhs: f64 = 0,

    expr: [expr_cap]u8 = undefined,
    expr_len: usize = 0,
    /// The text of the current operand is already in `expr` (after %, a
    /// function or a closing parenthesis).
    operand_in_expr: bool = false,
    /// Start of the current operand's text in `expr`.
    operand_start: usize = 0,
    operand_group: bool = false,

    pub fn init(max_digits: u8) Engine {
        return .{ .max_digits = max_digits };
    }

    // ------------------------------------------------------------------
    // Queries
    // ------------------------------------------------------------------

    /// Text of the main display.
    pub fn display(self: *const Engine, buf: []u8) []const u8 {
        if (self.err) return "Error";
        if (self.mode == .typing) return groupEntry(buf, self.entry[0..self.entry_len]);
        return formatNumber(buf, self.cur, self.max_digits, true);
    }

    /// Plain value for the clipboard (no thousands separators).
    pub fn copyText(self: *const Engine, buf: []u8) []const u8 {
        if (self.err) return "Error";
        if (self.mode == .typing) {
            const e = self.entry[0..self.entry_len];
            if (e.len > 0 and e[e.len - 1] == '.') return e[0 .. e.len - 1];
            return e;
        }
        return formatNumber(buf, self.cur, self.max_digits, false);
    }

    /// The small expression line ("1,200+34.56+").
    pub fn expression(self: *const Engine) []const u8 {
        return self.expr[0..self.expr_len];
    }

    /// Operator to highlight on the keypad.
    pub fn activeOp(self: *const Engine) ?BinOp {
        if (self.err or self.mode != .after_op or self.no == 0) return null;
        return switch (self.ops[self.no - 1]) {
            .op => |o| o,
            .lparen => null,
        };
    }

    /// "C" while a number is being typed, "AC" otherwise.
    pub fn clearLabel(self: *const Engine) []const u8 {
        return if (self.mode == .typing and !self.err) "C" else "AC";
    }

    pub fn openParens(self: *const Engine) usize {
        var n: usize = 0;
        for (self.ops[0..self.no]) |t| {
            if (t == .lparen) n += 1;
        }
        return n;
    }

    pub fn value(self: *const Engine) f64 {
        return self.cur;
    }

    // ------------------------------------------------------------------
    // Keys
    // ------------------------------------------------------------------

    pub fn allClear(self: *Engine) void {
        const md = self.max_digits;
        const deg = self.degrees;
        self.* = .{ .max_digits = md, .degrees = deg };
    }

    /// The AC / C key.
    pub fn clear(self: *Engine) void {
        if (self.mode == .typing and !self.err) {
            self.cur = 0;
            self.entry_len = 0;
            self.truncateExpr(self.operand_start);
            self.operand_in_expr = false;
            const pending = self.no > 0 and self.ops[self.no - 1] == .op;
            self.mode = if (pending) .after_op else .result;
            return;
        }
        self.allClear();
    }

    pub fn digit(self: *Engine, d: u8) void {
        std.debug.assert(d <= 9);
        self.beginEntry();
        const e = self.entry[0..self.entry_len];
        if (countDigits(e) >= self.max_digits) return;
        // Replace a lone leading zero.
        if (std.mem.eql(u8, e, "0") or std.mem.eql(u8, e, "-0")) {
            self.entry_len -= 1;
        }
        self.appendEntry('0' + d);
        self.cur = parseEntry(self.entry[0..self.entry_len]);
    }

    pub fn point(self: *Engine) void {
        self.beginEntry();
        const e = self.entry[0..self.entry_len];
        if (std.mem.indexOfScalar(u8, e, '.') != null) return;
        if (countDigits(e) >= self.max_digits) return;
        if (e.len == 0 or std.mem.eql(u8, e, "-")) self.appendEntry('0');
        self.appendEntry('.');
    }

    pub fn backspace(self: *Engine) void {
        if (self.err) {
            self.allClear();
            return;
        }
        if (self.mode != .typing) return;
        if (self.entry_len > 0) self.entry_len -= 1;
        const e = self.entry[0..self.entry_len];
        if (e.len == 0 or std.mem.eql(u8, e, "-")) {
            self.entry_len = 0;
            self.appendEntry('0');
        }
        self.cur = parseEntry(self.entry[0..self.entry_len]);
    }

    /// ± key.
    pub fn negate(self: *Engine) void {
        if (self.err) return;
        switch (self.mode) {
            .typing => {
                if (self.entry_len > 0 and self.entry[0] == '-') {
                    std.mem.copyForwards(u8, self.entry[0 .. self.entry_len - 1], self.entry[1..self.entry_len]);
                    self.entry_len -= 1;
                } else if (self.entry_len < max_entry) {
                    std.mem.copyBackwards(u8, self.entry[1 .. self.entry_len + 1], self.entry[0..self.entry_len]);
                    self.entry[0] = '-';
                    self.entry_len += 1;
                }
                self.cur = parseEntry(self.entry[0..self.entry_len]);
            },
            .after_op => {
                // Start typing a negative number.
                self.beginEntry();
                self.entry_len = 0;
                self.appendEntry('-');
                self.appendEntry('0');
                self.cur = -0.0;
            },
            .result => {
                self.cur = -self.cur;
                if (self.operand_in_expr) {
                    var tmp: [expr_cap]u8 = undefined;
                    const src = self.operandExpr();
                    const inner = tmp[0..src.len];
                    @memcpy(inner, src);
                    self.truncateExpr(self.operand_start);
                    self.appendExpr("\u{2212}(");
                    self.appendExpr(inner);
                    self.appendExpr(")");
                }
            },
        }
    }

    pub fn percent(self: *Engine) void {
        if (self.err) return;
        if (self.after_equals) {
            // Applies to the result: start a new expression from it.
            self.expr_len = 0;
            self.operand_start = 0;
            self.operand_in_expr = false;
        }
        const x = self.cur;
        var base: ?f64 = null;
        if (self.no > 0 and self.nv > 0) {
            switch (self.ops[self.no - 1]) {
                .op => |o| if (o == .add or o == .sub) {
                    base = self.vals[self.nv - 1];
                },
                .lparen => {},
            }
        }
        self.captureOperandText();
        self.appendExpr("%");
        self.cur = if (base) |b| b * x / 100 else x / 100;
        self.finishValue();
    }

    pub fn binary(self: *Engine, op: BinOp) void {
        if (self.err) return;
        if (self.mode == .after_op and self.no > 0 and self.ops[self.no - 1] == .op) {
            // Change the pending operator.
            const old = self.ops[self.no - 1].op;
            // Re-reduce in case the new operator has lower precedence
            // (2 × + → the product is evaluated now).
            self.no -= 1;
            self.truncateExpr(self.expr_len - old.symbol().len);
            self.reduceFor(op);
            if (self.err) return;
            self.pushOp(op);
            return;
        }
        if (self.after_equals) {
            self.expr_len = 0;
            self.operand_start = 0;
            self.operand_in_expr = false;
            self.after_equals = false;
        }
        self.captureOperandText();
        self.pushVal(self.cur);
        self.reduceFor(op);
        if (self.err) return;
        self.pushOp(op);
    }

    pub fn equals(self: *Engine) void {
        if (self.err) return;
        if (self.after_equals) {
            // Repeat the last operation.
            const op = self.last_op orelse return;
            self.expr_len = 0;
            self.appendNumber(self.cur);
            self.appendExpr(op.symbol());
            self.appendNumber(self.last_rhs);
            self.cur = op.apply(self.cur, self.last_rhs);
            self.checkResult();
            return;
        }
        if (self.no == 0) {
            // Nothing pending: just commit the number.
            if (self.mode == .typing) {
                self.captureOperandText();
                self.mode = .result;
            }
            self.after_equals = true;
            return;
        }
        const rhs = self.cur;
        self.captureOperandText();
        // Close open parentheses implicitly.
        var close_count: usize = 0;
        for (self.ops[0..self.no]) |t| {
            if (t == .lparen) close_count += 1;
        }
        for (0..close_count) |_| self.appendExpr(")");
        // Remember the innermost pending operator for "= =".
        var i = self.no;
        while (i > 0) {
            i -= 1;
            switch (self.ops[i]) {
                .op => |o| {
                    self.last_op = o;
                    self.last_rhs = rhs;
                    break;
                },
                .lparen => {},
            }
        }
        self.pushVal(rhs);
        while (self.no > 0) {
            switch (self.ops[self.no - 1]) {
                .lparen => self.no -= 1,
                .op => self.reduceOne(),
            }
            if (self.err) return;
        }
        self.cur = if (self.nv > 0) self.vals[self.nv - 1] else rhs;
        self.nv = 0;
        self.mode = .result;
        self.after_equals = true;
        self.operand_in_expr = false;
        self.checkResult();
    }

    pub fn openParen(self: *Engine) void {
        if (self.err) return;
        if (self.after_equals) self.resetKeepingNothing();
        if (self.mode == .typing or (self.mode == .result and self.operand_in_expr)) {
            // "2(" means 2 × (.
            self.binary(.mul);
        }
        if (self.no >= max_depth) return;
        self.paren_pos[self.no] = self.expr_len;
        self.ops[self.no] = .lparen;
        self.no += 1;
        self.appendExpr("(");
        self.cur = 0;
        self.mode = .after_op;
        self.operand_start = self.expr_len;
        self.operand_in_expr = false;
    }

    pub fn closeParen(self: *Engine) void {
        if (self.err) return;
        if (self.openParens() == 0) return;
        self.captureOperandText();
        self.pushVal(self.cur);
        while (self.no > 0 and self.ops[self.no - 1] != .lparen) {
            self.reduceOne();
            if (self.err) return;
        }
        if (self.no == 0) return;
        self.no -= 1;
        const start = self.paren_pos[self.no];
        self.appendExpr(")");
        self.cur = self.popVal();
        self.mode = .result;
        self.operand_start = start;
        self.operand_in_expr = true;
        self.operand_group = true;
        self.checkResult();
    }

    pub fn function(self: *Engine, f: Func) void {
        if (self.err) return;
        if (self.after_equals) {
            self.expr_len = 0;
            self.operand_start = 0;
            self.operand_in_expr = false;
            self.after_equals = false;
            self.last_op = null;
        }
        const x = self.cur;
        // Build "f(operand)" in place of the operand text.
        var tmp: [expr_cap]u8 = undefined;
        var inner: []const u8 = undefined;
        var group = false;
        if (self.operand_in_expr) {
            const src = self.operandExpr();
            @memcpy(tmp[0..src.len], src);
            inner = tmp[0..src.len];
            group = self.operand_group;
        } else {
            var nb: [64]u8 = undefined;
            const s = self.operandText(&nb);
            @memcpy(tmp[0..s.len], s);
            inner = tmp[0..s.len];
        }
        self.truncateExpr(self.operand_start);
        const pre = f.prefix();
        const suf = f.suffix();
        const simple = isSimpleNumber(inner);
        const named = pre.len > 0 and std.ascii.isAlphabetic(pre[pre.len - 1]);
        self.appendExpr(pre);
        const wrap = !group and (named or !simple);
        if (wrap) self.appendExpr("(");
        self.appendExpr(inner);
        if (wrap) self.appendExpr(")");
        self.appendExpr(suf);
        self.operand_in_expr = true;
        self.operand_group = false;
        self.cur = self.evalFunc(f, x);
        self.mode = .result;
        self.checkResult();
    }

    pub fn constant(self: *Engine, v: f64) void {
        if (self.err) self.allClear();
        if (self.after_equals) self.resetKeepingNothing();
        if (self.mode == .result and self.operand_in_expr) {
            self.truncateExpr(self.operand_start);
            self.operand_in_expr = false;
        }
        self.cur = v;
        self.mode = .result;
    }

    /// Paste a number ("1,234.5", " -42 "); returns false when the text is
    /// not a number.
    pub fn paste(self: *Engine, text: []const u8) bool {
        var clean: [max_entry]u8 = undefined;
        var n: usize = 0;
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return false;
        for (t) |c| {
            switch (c) {
                ',', ' ', '_', '\'' => continue,
                else => {},
            }
            if (n >= clean.len) return false;
            clean[n] = if (c == 'E') 'e' else c;
            n += 1;
        }
        const s = clean[0..n];
        const v = std.fmt.parseFloat(f64, s) catch return false;
        if (!std.math.isFinite(v)) return false;
        const plain = blk: {
            for (s, 0..) |c, i| {
                if (std.ascii.isDigit(c) or c == '.' or (c == '-' and i == 0)) continue;
                break :blk false;
            }
            break :blk true;
        };
        if (self.err) self.allClear();
        self.beginEntry();
        if (plain and countDigits(s) <= self.max_digits and std.mem.count(u8, s, ".") <= 1) {
            self.entry_len = 0;
            for (s) |c| self.appendEntry(c);
            if (self.entry_len > 0 and (self.entry[0] == '.' or (self.entry[0] == '-' and self.entry_len > 1 and self.entry[1] == '.'))) {
                // ".5" → "0.5"
                const neg = self.entry[0] == '-';
                const at: usize = if (neg) 1 else 0;
                std.mem.copyBackwards(u8, self.entry[at + 1 .. self.entry_len + 1], self.entry[at..self.entry_len]);
                self.entry[at] = '0';
                self.entry_len += 1;
            }
            self.cur = parseEntry(self.entry[0..self.entry_len]);
        } else {
            self.entry_len = 0;
            self.cur = v;
            self.mode = .result;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    fn resetKeepingNothing(self: *Engine) void {
        const md = self.max_digits;
        const deg = self.degrees;
        self.* = .{ .max_digits = md, .degrees = deg };
    }

    /// Prepare `entry` for a new digit.
    fn beginEntry(self: *Engine) void {
        if (self.err) self.allClear();
        if (self.mode == .typing) return;
        if (self.after_equals) self.resetKeepingNothing();
        if (self.mode == .result and self.operand_in_expr) {
            // A new number replaces e.g. "10%" or "sin(30)".
            self.truncateExpr(self.operand_start);
        }
        self.operand_start = self.expr_len;
        self.operand_in_expr = false;
        self.operand_group = false;
        self.entry_len = 0;
        self.mode = .typing;
        self.cur = 0;
    }

    /// Text of the current operand in the expression.
    fn operandExpr(self: *const Engine) []const u8 {
        return self.expr[@min(self.operand_start, self.expr_len)..self.expr_len];
    }

    fn appendEntry(self: *Engine, c: u8) void {
        if (self.entry_len >= max_entry) return;
        self.entry[self.entry_len] = c;
        self.entry_len += 1;
    }

    /// Text for the current operand as it should appear in the expression.
    fn operandText(self: *const Engine, buf: []u8) []const u8 {
        if (self.mode == .typing) {
            var e = self.entry[0..self.entry_len];
            if (e.len > 0 and e[e.len - 1] == '.') e = e[0 .. e.len - 1];
            const g = groupEntry(buf, e);
            if (g.len > 0 and g[0] == '-') {
                // Use a real minus sign.
                var tmp: [64]u8 = undefined;
                const rest = g[1..];
                const out = std.fmt.bufPrint(&tmp, "\u{2212}{s}", .{rest}) catch return g;
                @memcpy(buf[0..out.len], out);
                return buf[0..out.len];
            }
            return g;
        }
        return formatExprNumber(buf, self.cur, self.max_digits);
    }

    /// Append the current operand to the expression unless it is already there.
    fn captureOperandText(self: *Engine) void {
        if (self.operand_in_expr) return;
        self.operand_start = self.expr_len;
        var nb: [64]u8 = undefined;
        self.appendExpr(self.operandText(&nb));
        self.operand_in_expr = true;
        self.operand_group = false;
    }

    fn appendNumber(self: *Engine, v: f64) void {
        var nb: [64]u8 = undefined;
        self.appendExpr(formatExprNumber(&nb, v, self.max_digits));
    }

    fn appendExpr(self: *Engine, s: []const u8) void {
        const n = @min(s.len, expr_cap - self.expr_len);
        @memcpy(self.expr[self.expr_len .. self.expr_len + n], s[0..n]);
        self.expr_len += n;
    }

    fn truncateExpr(self: *Engine, len: usize) void {
        self.expr_len = @min(self.expr_len, len);
    }

    fn pushVal(self: *Engine, v: f64) void {
        if (self.nv >= max_depth) {
            self.setError();
            return;
        }
        self.vals[self.nv] = v;
        self.nv += 1;
    }

    fn popVal(self: *Engine) f64 {
        if (self.nv == 0) return 0;
        self.nv -= 1;
        return self.vals[self.nv];
    }

    fn pushOp(self: *Engine, op: BinOp) void {
        if (self.no >= max_depth) {
            self.setError();
            return;
        }
        self.ops[self.no] = .{ .op = op };
        self.no += 1;
        self.appendExpr(op.symbol());
        // Show the value that the operator applies to.
        self.cur = if (self.nv > 0) self.vals[self.nv - 1] else 0;
        self.mode = .after_op;
        self.after_equals = false;
        self.operand_start = self.expr_len;
        self.operand_in_expr = false;
        self.operand_group = false;
    }

    /// Evaluate pending operators that bind at least as tightly as `op`.
    fn reduceFor(self: *Engine, op: BinOp) void {
        while (self.no > 0) {
            const top = switch (self.ops[self.no - 1]) {
                .op => |o| o,
                .lparen => break,
            };
            const p_top = top.precedence();
            const p_new = op.precedence();
            if (p_top > p_new or (p_top == p_new and !op.rightAssoc())) {
                self.reduceOne();
                if (self.err) return;
            } else break;
        }
    }

    fn reduceOne(self: *Engine) void {
        if (self.no == 0 or self.nv < 2) {
            if (self.no > 0) self.no -= 1;
            return;
        }
        const op = self.ops[self.no - 1].op;
        self.no -= 1;
        const b = self.popVal();
        const a = self.popVal();
        const r = op.apply(a, b);
        if (!std.math.isFinite(r)) {
            self.setError();
            return;
        }
        self.pushVal(r);
    }

    fn evalFunc(self: *const Engine, f: Func, x: f64) f64 {
        const to_rad: f64 = if (self.degrees) std.math.pi / 180.0 else 1;
        return switch (f) {
            .sin, .cos, .tan => trig(f, x, self.degrees, to_rad),
            .ln => if (x <= 0) std.math.nan(f64) else @log(x),
            .log10 => if (x <= 0) std.math.nan(f64) else std.math.log10(x),
            .sqrt => if (x < 0) std.math.nan(f64) else @sqrt(x),
            .cbrt => std.math.cbrt(x),
            .square => x * x,
            .cube => x * x * x,
            .exp => @exp(x),
            .exp10 => std.math.pow(f64, 10, x),
            .recip => if (x == 0) std.math.nan(f64) else 1 / x,
            .fact => factorial(x),
        };
    }

    fn finishValue(self: *Engine) void {
        self.mode = .result;
        self.after_equals = false;
        self.checkResult();
    }

    fn checkResult(self: *Engine) void {
        if (!std.math.isFinite(self.cur)) {
            self.setError();
            return;
        }
        if (self.cur == 0) self.cur = 0; // no "-0"
    }

    fn setError(self: *Engine) void {
        self.err = true;
        self.nv = 0;
        self.no = 0;
        self.mode = .result;
        self.after_equals = false;
    }
};

fn trig(f: Func, x: f64, degrees: bool, to_rad: f64) f64 {
    if (degrees) {
        // Exact values at multiples of 90°.
        const m = @mod(x, 360.0);
        if (@mod(m, 90.0) == 0) {
            const q: u32 = @intFromFloat(m / 90.0);
            return switch (f) {
                .sin => ([_]f64{ 0, 1, 0, -1 })[q],
                .cos => ([_]f64{ 1, 0, -1, 0 })[q],
                .tan => if (q % 2 == 1) std.math.nan(f64) else 0,
                else => unreachable,
            };
        }
    }
    const r = x * to_rad;
    const v = switch (f) {
        .sin => @sin(r),
        .cos => @cos(r),
        .tan => @tan(r),
        else => unreachable,
    };
    // Snap rounding noise (sin π → 1.2e-16).
    if (@abs(v) < 1e-14) return 0;
    if (f == .tan and @abs(v) > 1e15) return std.math.nan(f64);
    return v;
}

fn factorial(x: f64) f64 {
    if (x < 0 or x > 170) return std.math.nan(f64);
    if (x == @floor(x)) {
        var r: f64 = 1;
        var i: f64 = 2;
        while (i <= x) : (i += 1) r *= i;
        return r;
    }
    return std.math.gamma(f64, x + 1);
}

fn countDigits(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (std.ascii.isDigit(c)) n += 1;
    }
    return n;
}

fn parseEntry(e: []const u8) f64 {
    var s = e;
    if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    if (s.len == 0 or std.mem.eql(u8, s, "-")) return 0;
    return std.fmt.parseFloat(f64, s) catch 0;
}

fn isSimpleNumber(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isDigit(c) or c == '.' or c == ',')) return false;
    }
    return s.len > 0;
}

/// Insert thousands separators into a typed number ("-1234.50" → "-1,234.50").
pub fn groupEntry(buf: []u8, e: []const u8) []const u8 {
    if (e.len == 0) return "0";
    var n: usize = 0;
    var s = e;
    if (s[0] == '-') {
        buf[n] = '-';
        n += 1;
        s = s[1..];
    }
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    const int_part = s[0..dot];
    for (int_part, 0..) |c, i| {
        if (i > 0 and (int_part.len - i) % 3 == 0) {
            if (n >= buf.len) break;
            buf[n] = ',';
            n += 1;
        }
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    for (s[dot..]) |c| {
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

const Decimal = struct {
    digits: [32]u8 = undefined,
    n: usize = 0,
    /// Decimal exponent of the first digit.
    exp: i32 = 0,
};

/// Round `x` (> 0) to `sig` significant digits.
fn toDecimal(x: f64, sig: usize) Decimal {
    var tmp: [64]u8 = undefined;
    var d = Decimal{};
    const s = std.fmt.float.render(&tmp, x, .{ .mode = .scientific, .precision = @max(sig, 1) - 1 }) catch return d;
    const e_at = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
    for (s[0..e_at]) |c| {
        if (std.ascii.isDigit(c) and d.n < d.digits.len) {
            d.digits[d.n] = c;
            d.n += 1;
        }
    }
    if (e_at < s.len) d.exp = std.fmt.parseInt(i32, s[e_at + 1 ..], 10) catch 0;
    while (d.n > 1 and d.digits[d.n - 1] == '0') d.n -= 1;
    return d;
}

/// Mantissa digits used in scientific notation ("1.2346e15").
const sci_digits = 5;

/// Format a value for display: at most `max_digits` significant digits,
/// optional thousands separators, scientific notation when it does not fit.
pub fn formatNumber(buf: []u8, v: f64, max_digits: u8, grouping: bool) []const u8 {
    if (!std.math.isFinite(v)) return "Error";
    if (v == 0) return "0";
    const neg = v < 0;
    const ax = @abs(v);
    const md: i32 = max_digits;
    var d = toDecimal(ax, max_digits);
    var sci = false;
    if (d.exp >= md) {
        sci = true;
    } else if (d.exp < -7) {
        sci = true;
    } else if (d.exp < 0) {
        // The leading "0." does not count as a significant digit.
        const avail = md + d.exp + 1;
        if (avail <= 0) {
            sci = true;
        } else if (d.n > @as(usize, @intCast(avail))) {
            if (avail < 5) sci = true else d = toDecimal(ax, @intCast(avail));
        }
    }
    var w = Out{ .buf = buf };
    if (neg) w.put('-');
    if (sci) {
        d = toDecimal(ax, sci_digits);
        w.put(d.digits[0]);
        if (d.n > 1) {
            w.put('.');
            w.puts(d.digits[1..d.n]);
        }
        w.put('e');
        var eb: [16]u8 = undefined;
        w.puts(std.fmt.bufPrint(&eb, "{d}", .{d.exp}) catch "");
        return w.slice();
    }
    if (d.exp >= 0) {
        const int_len: usize = @intCast(d.exp + 1);
        var i: usize = 0;
        while (i < int_len) : (i += 1) {
            if (grouping and i > 0 and (int_len - i) % 3 == 0) w.put(',');
            w.put(if (i < d.n) d.digits[i] else '0');
        }
        if (d.n > int_len) {
            w.put('.');
            w.puts(d.digits[int_len..d.n]);
        }
    } else {
        w.puts("0.");
        var z: i32 = 0;
        while (z < -d.exp - 1) : (z += 1) w.put('0');
        w.puts(d.digits[0..d.n]);
    }
    return w.slice();
}

/// Number formatting for the expression line (real minus sign).
fn formatExprNumber(buf: []u8, v: f64, max_digits: u8) []const u8 {
    var tmp: [64]u8 = undefined;
    const s = formatNumber(&tmp, v, max_digits, true);
    if (s.len > 0 and s[0] == '-') {
        const out = std.fmt.bufPrint(buf, "\u{2212}{s}", .{s[1..]}) catch return s;
        return out;
    }
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

const Out = struct {
    buf: []u8,
    n: usize = 0,
    fn put(self: *Out, c: u8) void {
        if (self.n < self.buf.len) {
            self.buf[self.n] = c;
            self.n += 1;
        }
    }
    fn puts(self: *Out, s: []const u8) void {
        for (s) |c| self.put(c);
    }
    fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.n];
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

/// Feed a key sequence: digits, ".", "+-*/^", "=", "%", "n" (±), "c" (C/AC),
/// "b" (backspace), "(" and ")".
fn keys(e: *Engine, seq: []const u8) void {
    for (seq) |c| {
        switch (c) {
            '0'...'9' => e.digit(c - '0'),
            '.' => e.point(),
            '+' => e.binary(.add),
            '-' => e.binary(.sub),
            '*' => e.binary(.mul),
            '/' => e.binary(.div),
            '^' => e.binary(.pow),
            '=' => e.equals(),
            '%' => e.percent(),
            'n' => e.negate(),
            'c' => e.clear(),
            'b' => e.backspace(),
            '(' => e.openParen(),
            ')' => e.closeParen(),
            ' ' => {},
            else => unreachable,
        }
    }
}

fn expectDisplay(e: *const Engine, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, e.display(&buf));
}

fn expectFmt(v: f64, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(want, formatNumber(&buf, v, 9, true));
}

test "precedence: 2 + 3 × 4 = 14" {
    var e = Engine{};
    keys(&e, "2+3*");
    try expectDisplay(&e, "3");
    keys(&e, "4=");
    try expectDisplay(&e, "14");
}

test "left-to-right for equal precedence and intermediate results" {
    var e = Engine{};
    keys(&e, "2*3+");
    try expectDisplay(&e, "6");
    keys(&e, "4=");
    try expectDisplay(&e, "10");
    e.allClear();
    keys(&e, "10-4-3=");
    try expectDisplay(&e, "3");
    e.allClear();
    keys(&e, "100/5/2=");
    try expectDisplay(&e, "10");
    e.allClear();
    keys(&e, "1+2*3-4/2=");
    try expectDisplay(&e, "5");
}

test "repeated equals repeats the last operation" {
    var e = Engine{};
    keys(&e, "2+3=");
    try expectDisplay(&e, "5");
    keys(&e, "=");
    try expectDisplay(&e, "8");
    keys(&e, "=");
    try expectDisplay(&e, "11");
    e.allClear();
    keys(&e, "10-2==");
    try expectDisplay(&e, "6");
    e.allClear();
    keys(&e, "2+3*4==");
    try expectDisplay(&e, "56");
}

test "operator with no second operand uses the display" {
    var e = Engine{};
    keys(&e, "2+=");
    try expectDisplay(&e, "4");
    e.allClear();
    keys(&e, "5*=");
    try expectDisplay(&e, "25");
}

test "changing the pending operator" {
    var e = Engine{};
    keys(&e, "5+*2=");
    try expectDisplay(&e, "10");
    try testing.expectEqualStrings("5\u{00D7}2", e.expression());
    e.allClear();
    keys(&e, "2+3*+");
    try expectDisplay(&e, "5");
}

test "percent semantics" {
    var e = Engine{};
    keys(&e, "50+10%");
    try expectDisplay(&e, "5");
    keys(&e, "=");
    try expectDisplay(&e, "55");
    e.allClear();
    keys(&e, "200-10%=");
    try expectDisplay(&e, "180");
    e.allClear();
    keys(&e, "50*10%");
    try expectDisplay(&e, "0.1");
    keys(&e, "=");
    try expectDisplay(&e, "5");
    e.allClear();
    keys(&e, "25%");
    try expectDisplay(&e, "0.25");
}

test "sign toggle" {
    var e = Engine{};
    keys(&e, "5n");
    try expectDisplay(&e, "-5");
    keys(&e, "3");
    try expectDisplay(&e, "-53");
    keys(&e, "n");
    try expectDisplay(&e, "53");
    e.allClear();
    keys(&e, "4+5=n");
    try expectDisplay(&e, "-9");
    keys(&e, "+1=");
    try expectDisplay(&e, "-8");
    e.allClear();
    keys(&e, "7-n2=");
    try expectDisplay(&e, "9");
}

test "division by zero shows Error, digits recover" {
    var e = Engine{};
    keys(&e, "5/0=");
    try expectDisplay(&e, "Error");
    try testing.expectEqualStrings("AC", e.clearLabel());
    keys(&e, "+");
    try expectDisplay(&e, "Error");
    keys(&e, "7");
    try expectDisplay(&e, "7");
    keys(&e, "+1=");
    try expectDisplay(&e, "8");
}

test "clear entry keeps the pending operation" {
    var e = Engine{};
    keys(&e, "5+3");
    try testing.expectEqualStrings("C", e.clearLabel());
    keys(&e, "c");
    try expectDisplay(&e, "0");
    try testing.expectEqualStrings("AC", e.clearLabel());
    try testing.expectEqual(BinOp.add, e.activeOp().?);
    keys(&e, "4=");
    try expectDisplay(&e, "9");
    keys(&e, "c");
    try expectDisplay(&e, "0");
    try testing.expectEqual(@as(usize, 0), e.expression().len);
}

test "typing, digit limit and backspace" {
    var e = Engine{};
    keys(&e, "1234.50");
    try expectDisplay(&e, "1,234.50");
    e.allClear();
    keys(&e, "1234567890");
    try expectDisplay(&e, "123,456,789");
    e.allClear();
    keys(&e, "123b");
    try expectDisplay(&e, "12");
    keys(&e, "bb");
    try expectDisplay(&e, "0");
    keys(&e, "..5");
    try expectDisplay(&e, "0.5");
    e.allClear();
    keys(&e, "000");
    try expectDisplay(&e, "0");
}

test "formatting" {
    try expectFmt(1234567.89, "1,234,567.89");
    try expectFmt(0.1 + 0.2, "0.3");
    try expectFmt(1.0 / 3.0, "0.333333333");
    try expectFmt(2.0 / 3.0, "0.666666667");
    try expectFmt(100, "100");
    try expectFmt(1.5, "1.5");
    try expectFmt(-1234.5, "-1,234.5");
    try expectFmt(999999999, "999,999,999");
    try expectFmt(1e9, "1e9");
    try expectFmt(1234567890123456, "1.2346e15");
    try expectFmt(1e-10, "1e-10");
    try expectFmt(1.5e-8, "1.5e-8");
    try expectFmt(0.000123456789, "0.000123457");
    try expectFmt(1.23456e-6, "1.2346e-6");
    try expectFmt(0.0000001, "0.0000001");
    try expectFmt(0.00012, "0.00012");
    try expectFmt(-0.0, "0");
    try expectFmt(std.math.inf(f64), "Error");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1234567.89", formatNumber(&buf, 1234567.89, 9, false));
}

test "results are rounded to nine significant digits" {
    var e = Engine{};
    keys(&e, "1/3*3=");
    try expectDisplay(&e, "1");
    e.allClear();
    keys(&e, "99999999*99999999=");
    try expectDisplay(&e, "1e16");
}

test "parentheses and powers" {
    var e = Engine{};
    keys(&e, "(2+3)*4=");
    try expectDisplay(&e, "20");
    e.allClear();
    keys(&e, "2*(3+4)=");
    try expectDisplay(&e, "14");
    e.allClear();
    keys(&e, "2*(3+4");
    keys(&e, "=");
    try expectDisplay(&e, "14");
    e.allClear();
    keys(&e, "2^3=");
    try expectDisplay(&e, "8");
    e.allClear();
    keys(&e, "2^3^2=");
    try expectDisplay(&e, "512");
    e.allClear();
    keys(&e, "2*3^2=");
    try expectDisplay(&e, "18");
    e.allClear();
    e.digit(2);
    e.openParen();
    keys(&e, "3)=");
    try expectDisplay(&e, "6");
}

test "scientific functions" {
    var e = Engine{};
    keys(&e, "30");
    e.function(.sin);
    try expectDisplay(&e, "0.5");
    try testing.expectEqualStrings("sin(30)", e.expression());
    e.allClear();
    keys(&e, "180");
    e.function(.sin);
    try expectDisplay(&e, "0");
    e.allClear();
    keys(&e, "90");
    e.function(.tan);
    try expectDisplay(&e, "Error");
    e.allClear();
    keys(&e, "2");
    e.function(.sqrt);
    try expectDisplay(&e, "1.41421356");
    e.allClear();
    keys(&e, "5");
    e.function(.fact);
    try expectDisplay(&e, "120");
    try testing.expectEqualStrings("5!", e.expression());
    e.allClear();
    keys(&e, "100");
    e.function(.log10);
    try expectDisplay(&e, "2");
    e.allClear();
    e.constant(std.math.pi);
    try expectDisplay(&e, "3.14159265");
    e.allClear();
    e.degrees = false;
    e.constant(std.math.pi);
    e.function(.sin);
    try expectDisplay(&e, "0");
    e.allClear();
    keys(&e, "27");
    e.binary(.root);
    keys(&e, "3=");
    try expectDisplay(&e, "3");
    e.allClear();
    keys(&e, "1+4");
    e.function(.sqrt);
    keys(&e, "=");
    try expectDisplay(&e, "3");
    try testing.expectEqualStrings("1+\u{221A}4", e.expression());
}

test "expression line" {
    var e = Engine{};
    keys(&e, "1200+34.56+");
    try testing.expectEqualStrings("1,200+34.56+", e.expression());
    try expectDisplay(&e, "1,234.56");
    try testing.expectEqual(BinOp.add, e.activeOp().?);
    keys(&e, "1=");
    try testing.expectEqualStrings("1,200+34.56+1", e.expression());
    try expectDisplay(&e, "1,235.56");
    keys(&e, "*2");
    try testing.expectEqualStrings("1,235.56\u{00D7}", e.expression());
    keys(&e, "=");
    try expectDisplay(&e, "2,471.12");
    keys(&e, "5");
    try testing.expectEqualStrings("", e.expression());
    e.allClear();
    keys(&e, "50+10%=");
    try testing.expectEqualStrings("50+10%", e.expression());
    keys(&e, "%");
    try expectDisplay(&e, "0.55");
    try testing.expectEqualStrings("55%", e.expression());
    keys(&e, "n");
    try expectDisplay(&e, "-0.55");
    try testing.expectEqualStrings("\u{2212}(55%)", e.expression());
}

test "paste and copy" {
    var e = Engine{};
    try testing.expect(e.paste("1,234.5"));
    try expectDisplay(&e, "1,234.5");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1234.5", e.copyText(&buf));
    keys(&e, "*2=");
    try expectDisplay(&e, "2,469");
    try testing.expectEqualStrings("2469", e.copyText(&buf));
    try testing.expect(!e.paste("hello"));
    try testing.expect(e.paste(" .5 "));
    try expectDisplay(&e, "0.5");
    try testing.expect(e.paste("1e20"));
    try expectDisplay(&e, "1e20");
}

test "random key sequences keep the engine consistent" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    const all_keys = "0123456789.+-*/^=%ncb()";
    const funcs = std.enums.values(Func);
    var buf: [64]u8 = undefined;
    for (0..200) |_| {
        var e = Engine{ .max_digits = if (rnd.boolean()) 9 else 12 };
        for (0..300) |_| {
            if (rnd.uintLessThan(u8, 10) == 0) {
                e.function(funcs[rnd.uintLessThan(usize, funcs.len)]);
            } else if (rnd.uintLessThan(u8, 40) == 0) {
                _ = e.paste("-12,345.678");
            } else if (rnd.uintLessThan(u8, 40) == 0) {
                e.constant(std.math.pi);
            } else {
                keys(&e, all_keys[rnd.uintLessThan(usize, all_keys.len)..][0..1]);
            }
            const d = e.display(&buf);
            try testing.expect(d.len > 0 and d.len <= 40);
            try testing.expect(e.expr_len <= expr_cap);
            try testing.expect(e.nv <= max_depth and e.no <= max_depth);
            if (!e.err) try testing.expect(std.math.isFinite(e.cur));
        }
    }
}
