//! Calculator: a macOS 26–style calculator (basic and scientific modes).
//!
//! The window is always dark (like macOS), has no title bar (the traffic
//! lights float over the display) and is not resizable; ⌘1 / ⌘2 switch
//! between the basic and the wider scientific keypad.

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const gfx = @import("gfx");
const engine = @import("engine.zig");

const Ui = ui.Ui;
const Rect = ui.Rect;
const Key = abi.input.Key;
const Mods = abi.window.Mods;
const Flags = abi.window.Flags;
const shapes = gfx.shapes;
const pm = ui.pm;

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

const pad_x: i32 = 16;
const pad_bottom: i32 = 16;
const key_d: i32 = 58;
const key_gap: i32 = 12;
const cols_basic = 4;
const cols_sci = 4;
const rows = 5;

const basic_w: i32 = pad_x * 2 + cols_basic * key_d + (cols_basic - 1) * key_gap;
const sci_w: i32 = pad_x * 2 + (cols_basic + cols_sci) * key_d + (cols_basic + cols_sci - 1) * key_gap;
const win_h: i32 = 490;
/// Height of the draggable title area (sets the traffic-light position).
const title_h: i32 = 38;

// ---------------------------------------------------------------------------
// Colors (straight ARGB; the calculator is dark in both appearances)
// ---------------------------------------------------------------------------

const bg_top: u32 = 0xFF242426;
const bg_bottom: u32 = 0xFF1C1C1E;
const col_function: u32 = 0xFF5C5C5F;
const col_digit: u32 = 0xFF333336;
const col_operator: u32 = 0xFFFF9F0A;
const col_sci: u32 = 0xFF2A2A2D;
const text_white: u32 = 0xFFFFFFFF;
const text_secondary: u32 = 0x8CFFFFFF;

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

const Action = union(enum) {
    digit: u8,
    point,
    clear,
    negate,
    percent,
    op: engine.BinOp,
    equals,
    func: engine.Func,
    lparen,
    rparen,
    pi,
    euler,
    rand,
    angle,

    fn eql(a: Action, b: Action) bool {
        return std.meta.eql(a, b);
    }
};

const Kind = enum { function, digit, operator, sci };

const Glyph = enum { text, plus, minus, times, divide, equals, plus_minus };

const Button = struct {
    label: []const u8,
    action: Action,
    kind: Kind,
    col: u8,
    row: u8,
    span: u8 = 1,
    glyph: Glyph = .text,
};

const basic_keys = [_]Button{
    .{ .label = "AC", .action = .clear, .kind = .function, .col = 0, .row = 0 },
    .{ .label = "+/-", .action = .negate, .kind = .function, .col = 1, .row = 0, .glyph = .plus_minus },
    .{ .label = "%", .action = .percent, .kind = .function, .col = 2, .row = 0 },
    .{ .label = "/", .action = .{ .op = .div }, .kind = .operator, .col = 3, .row = 0, .glyph = .divide },
    .{ .label = "7", .action = .{ .digit = 7 }, .kind = .digit, .col = 0, .row = 1 },
    .{ .label = "8", .action = .{ .digit = 8 }, .kind = .digit, .col = 1, .row = 1 },
    .{ .label = "9", .action = .{ .digit = 9 }, .kind = .digit, .col = 2, .row = 1 },
    .{ .label = "*", .action = .{ .op = .mul }, .kind = .operator, .col = 3, .row = 1, .glyph = .times },
    .{ .label = "4", .action = .{ .digit = 4 }, .kind = .digit, .col = 0, .row = 2 },
    .{ .label = "5", .action = .{ .digit = 5 }, .kind = .digit, .col = 1, .row = 2 },
    .{ .label = "6", .action = .{ .digit = 6 }, .kind = .digit, .col = 2, .row = 2 },
    .{ .label = "-", .action = .{ .op = .sub }, .kind = .operator, .col = 3, .row = 2, .glyph = .minus },
    .{ .label = "1", .action = .{ .digit = 1 }, .kind = .digit, .col = 0, .row = 3 },
    .{ .label = "2", .action = .{ .digit = 2 }, .kind = .digit, .col = 1, .row = 3 },
    .{ .label = "3", .action = .{ .digit = 3 }, .kind = .digit, .col = 2, .row = 3 },
    .{ .label = "+", .action = .{ .op = .add }, .kind = .operator, .col = 3, .row = 3, .glyph = .plus },
    .{ .label = "0", .action = .{ .digit = 0 }, .kind = .digit, .col = 0, .row = 4, .span = 2 },
    .{ .label = ".", .action = .point, .kind = .digit, .col = 2, .row = 4 },
    .{ .label = "=", .action = .equals, .kind = .operator, .col = 3, .row = 4, .glyph = .equals },
};

/// Scientific keys; "^" starts / ends a superscript run in labels.
const sci_keys = [_]Button{
    .{ .label = "(", .action = .lparen, .kind = .sci, .col = 0, .row = 0 },
    .{ .label = ")", .action = .rparen, .kind = .sci, .col = 1, .row = 0 },
    .{ .label = "x^2", .action = .{ .func = .square }, .kind = .sci, .col = 2, .row = 0 },
    .{ .label = "x^y", .action = .{ .op = .pow }, .kind = .sci, .col = 3, .row = 0 },
    .{ .label = "x^3", .action = .{ .func = .cube }, .kind = .sci, .col = 0, .row = 1 },
    .{ .label = "1/x", .action = .{ .func = .recip }, .kind = .sci, .col = 1, .row = 1 },
    .{ .label = "\u{221A}x", .action = .{ .func = .sqrt }, .kind = .sci, .col = 2, .row = 1 },
    .{ .label = "^y^\u{221A}x", .action = .{ .op = .root }, .kind = .sci, .col = 3, .row = 1 },
    .{ .label = "e^x", .action = .{ .func = .exp }, .kind = .sci, .col = 0, .row = 2 },
    .{ .label = "10^x", .action = .{ .func = .exp10 }, .kind = .sci, .col = 1, .row = 2 },
    .{ .label = "ln", .action = .{ .func = .ln }, .kind = .sci, .col = 2, .row = 2 },
    .{ .label = "log", .action = .{ .func = .log10 }, .kind = .sci, .col = 3, .row = 2 },
    .{ .label = "x!", .action = .{ .func = .fact }, .kind = .sci, .col = 0, .row = 3 },
    .{ .label = "sin", .action = .{ .func = .sin }, .kind = .sci, .col = 1, .row = 3 },
    .{ .label = "cos", .action = .{ .func = .cos }, .kind = .sci, .col = 2, .row = 3 },
    .{ .label = "tan", .action = .{ .func = .tan }, .kind = .sci, .col = 3, .row = 3 },
    .{ .label = "Rad", .action = .angle, .kind = .sci, .col = 0, .row = 4 },
    .{ .label = "e", .action = .euler, .kind = .sci, .col = 1, .row = 4 },
    .{ .label = "\u{03C0}", .action = .pi, .kind = .sci, .col = 2, .row = 4 },
    .{ .label = "Rand", .action = .rand, .kind = .sci, .col = 3, .row = 4 },
};

// Menu item ids.
const menu_about: u32 = 1;
const menu_quit: u32 = 2;
const menu_copy: u32 = 10;
const menu_paste: u32 = 11;
const menu_clear: u32 = 12;
const menu_basic: u32 = 20;
const menu_scientific: u32 = 21;
const menu_separators: u32 = 22;

/// How long a key flashes when typed on the keyboard.
const flash_ms: i64 = 130;

pub const App = struct {
    pub const window: ui.client.Options = .{
        .title = "Calculator",
        .width = basic_w,
        .height = win_h,
        .min_width = basic_w,
        .min_height = win_h,
        .flags = Flags.full_size_content | Flags.dark,
    };

    allocator: std.mem.Allocator,
    eng: engine.Engine = .{},
    scientific: bool = false,
    grouping: bool = true,
    flash: ?Action = null,
    flash_until: i64 = 0,
    prng: std.Random.DefaultPrng,
    menu_buf: [1024]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, u: *Ui) !App {
        u.win.setTitleHeight(title_h);
        return .{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
        };
    }

    /// Host previews: a result with a pending operator ("1,200 + 34.56 +").
    pub fn preview(self: *App, u: *Ui) void {
        _ = u;
        for ([_]u8{ 1, 2, 0, 0 }) |d| self.eng.digit(d);
        self.eng.binary(.add);
        for ([_]u8{ 3, 4 }) |d| self.eng.digit(d);
        self.eng.point();
        for ([_]u8{ 5, 6 }) |d| self.eng.digit(d);
        self.eng.binary(.add);
    }

    pub fn menu(self: *App, mw: *abi.window.MenuWriter) void {
        const checked = abi.window.MenuItemFlags.checked;
        mw.beginMenu("Calculator");
        mw.item(menu_about, "About Calculator", 0, 0, 0);
        mw.separator();
        mw.item(menu_quit, "Quit Calculator", 'q', 0, 0);
        mw.endMenu();
        mw.beginMenu("Edit");
        mw.item(menu_copy, "Copy", 'c', 0, 0);
        mw.item(menu_paste, "Paste", 'v', 0, 0);
        mw.separator();
        mw.item(menu_clear, "Clear All", 0, 0, 0);
        mw.endMenu();
        mw.beginMenu("View");
        mw.item(menu_basic, "Basic", '1', 0, if (!self.scientific) checked else 0);
        mw.item(menu_scientific, "Scientific", '2', 0, if (self.scientific) checked else 0);
        mw.separator();
        mw.item(menu_separators, "Show Thousands Separators", 0, 0, if (self.grouping) checked else 0);
        mw.endMenu();
    }

    fn resendMenu(self: *App, u: *Ui) void {
        var mw = abi.window.MenuWriter{ .buf = &self.menu_buf };
        self.menu(&mw);
        u.win.setMenu(mw.bytes());
    }

    pub fn onMenu(self: *App, u: *Ui, id: u32) void {
        switch (id) {
            menu_quit => u.quit = true,
            menu_copy => self.copy(),
            menu_paste => self.paste(),
            menu_clear => self.eng.allClear(),
            menu_basic => self.setScientific(u, false),
            menu_scientific => self.setScientific(u, true),
            menu_separators => {
                self.grouping = !self.grouping;
                self.resendMenu(u);
            },
            menu_about => u.win.notify("Calculator", "Zen OS Calculator 1.0"),
            else => {},
        }
    }

    pub fn timeoutMs(self: *App) i32 {
        if (self.flash == null) return -1;
        const left = self.flash_until - std.time.milliTimestamp();
        return @intCast(std.math.clamp(left, 1, flash_ms));
    }

    pub fn setScientific(self: *App, u: *Ui, on: bool) void {
        if (self.scientific == on) return;
        self.scientific = on;
        self.eng.max_digits = if (on) 12 else 9;
        u.win.requestResize(if (on) sci_w else basic_w, win_h);
        self.resendMenu(u);
    }

    fn copy(self: *App) void {
        var buf: [64]u8 = undefined;
        ui.client.clipboardSet(self.eng.copyText(&buf)) catch {};
    }

    fn paste(self: *App) void {
        const text = ui.client.clipboardGet(self.allocator) catch return;
        defer self.allocator.free(text);
        _ = self.eng.paste(text);
    }

    fn perform(self: *App, a: Action) void {
        const e = &self.eng;
        switch (a) {
            .digit => |d| e.digit(d),
            .point => e.point(),
            .clear => e.clear(),
            .negate => e.negate(),
            .percent => e.percent(),
            .op => |o| e.binary(o),
            .equals => e.equals(),
            .func => |f| e.function(f),
            .lparen => e.openParen(),
            .rparen => e.closeParen(),
            .pi => e.constant(std.math.pi),
            .euler => e.constant(std.math.e),
            .rand => e.constant(self.prng.random().float(f64)),
            .angle => e.degrees = !e.degrees,
        }
    }

    fn press(self: *App, a: Action) void {
        self.perform(a);
        self.flash = a;
        self.flash_until = std.time.milliTimestamp() + flash_ms;
    }

    /// Keyboard input. Keys are handled in the order they were typed (a
    /// frame may carry several), using the US layout for the characters so
    /// digits and operators work whatever the input language.
    fn handleKeyboard(self: *App, u: *Ui) void {
        if (u.keys_consumed) return;
        for (u.keys[0..u.key_count]) |k| {
            const cmd = k.mods & (Mods.cmd | Mods.ctrl) != 0;
            const shift = k.mods & Mods.shift != 0;
            switch (k.code) {
                Key.enter, Key.kpenter => self.press(.equals),
                Key.backspace => if (cmd) self.press(.clear) else self.eng.backspace(),
                Key.esc, Key.delete => self.press(.clear),
                else => {
                    if (cmd) {
                        if (k.code == Key.c) self.copy();
                        if (k.code == Key.v) self.paste();
                        continue;
                    }
                    const ch: u8 = keypadChar(k.code) orelse @intCast(abi.input.keyToChar(k.code, shift, false, false));
                    if (self.actionForChar(ch)) |a| self.press(a);
                },
            }
        }
    }

    fn actionForChar(self: *const App, ch: u8) ?Action {
        const basic: ?Action = switch (ch) {
            '0'...'9' => .{ .digit = ch - '0' },
            '.', ',' => .point,
            '+' => .{ .op = .add },
            '-' => .{ .op = .sub },
            '*', 'x', 'X' => .{ .op = .mul },
            '/' => .{ .op = .div },
            '=' => .equals,
            '%' => .percent,
            'c', 'C' => .clear,
            'n', 'N' => .negate,
            else => null,
        };
        if (basic != null or !self.scientific) return basic;
        return switch (ch) {
            '^' => .{ .op = .pow },
            '(' => .lparen,
            ')' => .rparen,
            'p' => .pi,
            'e' => .euler,
            's' => .{ .func = .sin },
            'o' => .{ .func = .cos },
            't' => .{ .func = .tan },
            'l' => .{ .func = .ln },
            'r' => .{ .func = .sqrt },
            '!' => .{ .func = .fact },
            else => null,
        };
    }

    pub fn frame(self: *App, u: *Ui) void {
        if (self.flash != null and std.time.milliTimestamp() >= self.flash_until) self.flash = null;
        self.handleKeyboard(u);

        const w = u.width();
        const h = u.height();
        // Background: always dark, with a faint vertical gradient.
        const bg = gfx.Paint.verticalGradient(gfx.RectF.init(0, 0, @floatFromInt(w), @floatFromInt(h)), &.{
            .{ .pos = 0, .color = pm(bg_top) },
            .{ .pos = 0.35, .color = pm(bg_bottom) },
            .{ .pos = 1, .color = pm(bg_bottom) },
        });
        u.canvas.fillRect(u.canvas.clip, &bg);

        const grid_top = h - pad_bottom - rows * key_d - (rows - 1) * key_gap;
        const sci_visible = self.scientific and w >= sci_w - 4;
        const basic_x0: i32 = if (sci_visible) pad_x + cols_sci * (key_d + key_gap) else pad_x;

        // Keypad.
        var any_hot = false;
        if (sci_visible) {
            for (sci_keys, 0..) |b, i| {
                if (self.drawButton(u, b, i + 100, pad_x, grid_top)) any_hot = true;
            }
        }
        for (basic_keys, 0..) |b, i| {
            if (self.drawButton(u, b, i, basic_x0, grid_top)) any_hot = true;
        }

        // Display.
        self.drawDisplay(u, Rect.init(pad_x + 4, title_h - 4, w - 2 * pad_x - 8, grid_top - title_h - 4), sci_visible);

        // Drag the window from the display area. The window server already
        // handles presses in the title area (y < title_h) itself.
        if (u.mouse_pressed and !any_hot and u.mouse_y >= title_h and u.mouse_y < grid_top - 4) {
            u.win.beginMove();
        }
    }

    fn drawDisplay(self: *App, u: *Ui, r: Rect, sci: bool) void {
        const e = &self.eng;
        // Big result, right aligned and shrunk to fit.
        var buf: [96]u8 = undefined;
        var text = e.display(&buf);
        var nogroup: [96]u8 = undefined;
        if (!self.grouping) text = stripCommas(&nogroup, text);
        const max_size: f32 = if (sci) 56 else 52;
        const avail: f32 = @floatFromInt(r.w);
        var size = max_size;
        const tw = u.measure(text, .regular, size);
        if (tw > avail) {
            // Quantize to even sizes so only a few font faces get cached.
            size = @max(20, @floor(max_size * avail / tw / 2) * 2);
            while (size > 20 and u.measure(text, .regular, size) > avail) size -= 2;
        }
        const f = u.face(.regular, size);
        const result_base = @as(f32, @floatFromInt(r.y + r.h)) - 10;
        const rw = f.measure(text);
        _ = u.textAt(@as(f32, @floatFromInt(r.x + r.w)) - rw, @round(result_base), text, .regular, size, text_white);

        // Expression line above it.
        const expr = e.expression();
        if (expr.len > 0) {
            var eb: [256]u8 = undefined;
            const shown = if (self.grouping) expr else stripCommas(&eb, expr);
            const esize: f32 = 17;
            const ebase = @round(result_base - f.cap_height - 16);
            const ew = u.measure(shown, .regular, esize);
            if (ew <= avail) {
                _ = u.textAt(@as(f32, @floatFromInt(r.x + r.w)) - ew, ebase, shown, .regular, esize, text_secondary);
            } else {
                // Keep the end of a long expression visible: "…34.56+".
                var start: usize = 0;
                const ell = "\u{2026}";
                const ell_w = u.measure(ell, .regular, esize);
                while (start < shown.len and u.measure(shown[start..], .regular, esize) + ell_w > avail) {
                    start += 1;
                    while (start < shown.len and shown[start] & 0xC0 == 0x80) start += 1;
                }
                const tail = shown[start..];
                const x = @as(f32, @floatFromInt(r.x + r.w)) - u.measure(tail, .regular, esize);
                _ = u.textAt(x - ell_w, ebase, ell, .regular, esize, text_secondary);
                _ = u.textAt(x, ebase, tail, .regular, esize, text_secondary);
            }
        }

        // Angle mode indicator (scientific).
        if (sci and !e.degrees) {
            _ = u.textAt(@floatFromInt(r.x), @round(result_base), "Rad", .medium, 14, text_secondary);
        }
    }

    /// Draw one key; returns true when the mouse is over it.
    fn drawButton(self: *App, u: *Ui, b: Button, idx: usize, x0: i32, y0: i32) bool {
        const x = x0 + @as(i32, b.col) * (key_d + key_gap);
        const y = y0 + @as(i32, b.row) * (key_d + key_gap);
        const w = @as(i32, b.span) * key_d + (@as(i32, b.span) - 1) * key_gap;
        const r = Rect.init(x, y, w, key_d);
        const id = ui.ui.hashIdx("calc-key", idx);
        if (u.interact(id, r)) self.perform(b.action);
        const hover = u.hovering(r);
        const pressed = (u.isActive(id) and hover) or (self.flash != null and self.flash.?.eql(b.action));

        const active_op = switch (b.action) {
            .op => |o| if (self.eng.activeOp()) |a| a == o else false,
            else => false,
        };
        var fill: u32 = switch (b.kind) {
            .function => col_function,
            .digit => col_digit,
            .operator => col_operator,
            .sci => col_sci,
        };
        var fg: u32 = text_white;
        if (active_op) {
            fill = 0xFFFFFFFF;
            fg = col_operator;
        }
        if (pressed) {
            fill = switch (b.kind) {
                // Dark keys light up, bright keys darken.
                .digit, .sci => mix(fill, 0xFFFFFFFF, 0.22),
                .function, .operator => mix(fill, 0xFF000000, 0.28),
            };
        } else if (hover) {
            fill = mix(fill, 0xFFFFFFFF, 0.08);
        }

        const rf = gfx.RectF.init(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
        const radius: f32 = @as(f32, @floatFromInt(key_d)) / 2;
        shapes.fillRoundRect(u.canvas, rf, radius, pm(fill));
        // Liquid-glass sheen and specular rim.
        const sheen = gfx.Paint.verticalGradient(rf, &.{
            .{ .pos = 0, .color = pm(0x1FFFFFFF) },
            .{ .pos = 0.5, .color = pm(0x00FFFFFF) },
            .{ .pos = 1, .color = pm(0x00FFFFFF) },
        });
        shapes.fillRoundRect(u.canvas, rf, radius, &sheen);
        const rim = gfx.Paint.verticalGradient(rf, &.{
            .{ .pos = 0, .color = pm(0x66FFFFFF) },
            .{ .pos = 0.35, .color = pm(0x0DFFFFFF) },
            .{ .pos = 0.75, .color = pm(0x05FFFFFF) },
            .{ .pos = 1, .color = pm(0x2EFFFFFF) },
        });
        shapes.strokeRoundRect(u.canvas, rf.inset(0.5, 0.5), radius - 0.5, 1, &rim);

        // Label.
        const label_rect = if (b.span > 1) Rect.init(r.x, r.y, key_d, key_d) else r;
        const cx: f32 = @as(f32, @floatFromInt(label_rect.x)) + @as(f32, @floatFromInt(label_rect.w)) / 2;
        const cy: f32 = @as(f32, @floatFromInt(label_rect.y)) + @as(f32, @floatFromInt(label_rect.h)) / 2;
        switch (b.glyph) {
            .text => {
                var label = b.label;
                if (b.action == .clear) label = self.eng.clearLabel();
                if (b.action == .angle) label = if (self.eng.degrees) "Rad" else "Deg";
                const size: f32 = switch (b.kind) {
                    .digit => if (b.action == .point) 34 else 30,
                    .function => if (b.action == .percent) 26 else 24,
                    .operator => 30,
                    .sci => 18,
                };
                const weight: ui.ui.Weight = if (b.kind == .digit) .regular else .medium;
                if (b.action == .point) {
                    // A plain dot glyph sits on the baseline; draw it centered.
                    u.fillCircle(cx, cy + 1, 3.2, fg);
                } else {
                    drawLabel(u, cx, cy, label, weight, size, fg);
                }
            },
            else => drawGlyph(u, b.glyph, cx, cy, fg),
        }
        return hover;
    }
};

/// Operator symbols drawn as vectors (SF Symbols–like, rounded caps).
fn drawGlyph(u: *Ui, g: Glyph, cx: f32, cy: f32, color: u32) void {
    const s: f32 = 10.5; // half extent
    const lw: f32 = 2.8;
    switch (g) {
        .plus => {
            u.line(cx - s, cy, cx + s, cy, lw, color);
            u.line(cx, cy - s, cx, cy + s, lw, color);
        },
        .minus => u.line(cx - s, cy, cx + s, cy, lw, color),
        .times => {
            const d = s * 0.78;
            u.line(cx - d, cy - d, cx + d, cy + d, lw, color);
            u.line(cx + d, cy - d, cx - d, cy + d, lw, color);
        },
        .divide => {
            u.line(cx - s, cy, cx + s, cy, lw, color);
            u.fillCircle(cx, cy - 7, 2.1, color);
            u.fillCircle(cx, cy + 7, 2.1, color);
        },
        .equals => {
            u.line(cx - s, cy - 4.5, cx + s, cy - 4.5, lw, color);
            u.line(cx - s, cy + 4.5, cx + s, cy + 4.5, lw, color);
        },
        .plus_minus => {
            const w: f32 = 2.2;
            // Small "+" top-left, "/" and "−" bottom-right.
            u.line(cx - 10, cy - 5, cx - 2, cy - 5, w, color);
            u.line(cx - 6, cy - 9, cx - 6, cy - 1, w, color);
            u.line(cx + 5, cy - 10, cx - 5, cy + 10, 1.8, color);
            u.line(cx + 2, cy + 5, cx + 10, cy + 5, w, color);
        },
        .text => {},
    }
}

/// Draw a label centered at (cx, cy); "^…^" runs are superscripts.
fn drawLabel(u: *Ui, cx: f32, cy: f32, label: []const u8, weight: ui.ui.Weight, size: f32, color: u32) void {
    const sup_size = @round(size * 0.62);
    // Measure.
    var total: f32 = 0;
    var it = std.mem.splitScalar(u8, label, '^');
    var sup = false;
    while (it.next()) |seg| : (sup = !sup) {
        if (seg.len == 0) continue;
        total += u.measure(seg, weight, if (sup) sup_size else size);
    }
    const f = u.face(weight, size);
    const baseline = @round(cy + f.cap_height / 2);
    var x = @round(cx - total / 2);
    it = std.mem.splitScalar(u8, label, '^');
    sup = false;
    while (it.next()) |seg| : (sup = !sup) {
        if (seg.len == 0) continue;
        if (sup) {
            x = u.textAt(x + 0.5, @round(baseline - size * 0.42), seg, weight, sup_size, color);
        } else {
            x = u.textAt(x, baseline, seg, weight, size, color);
        }
    }
}

fn stripCommas(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == ',') continue;
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Numeric keypad (evdev codes) → character.
fn keypadChar(code: u16) ?u8 {
    return switch (code) {
        71 => '7',
        72 => '8',
        73 => '9',
        74 => '-',
        75 => '4',
        76 => '5',
        77 => '6',
        78 => '+',
        79 => '1',
        80 => '2',
        81 => '3',
        82 => '0',
        83 => '.',
        98 => '/',
        Key.kpasterisk => '*',
        else => null,
    };
}

/// Blend two straight ARGB colors (opaque result).
fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0xFF000000;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(@round(ca + (cb - ca) * t));
        out |= v << sh;
    }
    return out;
}

test "window metrics" {
    try std.testing.expectEqual(@as(i32, 300), basic_w);
    try std.testing.expect(sci_w > basic_w);
}

// ---------------------------------------------------------------------------
// Interaction tests (headless window, synthetic events)
// ---------------------------------------------------------------------------

const Event = abi.window.Event;

fn testStep(app: *App, u: *Ui, events: []const Event) void {
    u.beginFrame(events);
    app.frame(u);
    u.endFrame();
}

/// Key events for ASCII text (US layout), all delivered in one frame.
fn typeText(app: *App, u: *Ui, s: []const u8) void {
    var evs: [32]Event = undefined;
    for (s, 0..) |c, i| {
        var code: u16 = 0;
        var shift = false;
        for (abi.input.us_layout, 0..) |pair, kc| {
            if (pair[0] == c) {
                code = @intCast(kc);
                break;
            }
            if (pair[1] == c) {
                code = @intCast(kc);
                shift = true;
                break;
            }
        }
        evs[i] = .{ .kind = .key_down, .a = code, .mods = if (shift) Mods.shift else 0 };
        evs[i].text[0] = c;
    }
    testStep(app, u, evs[0..s.len]);
}

fn keyCenter(u: *Ui, col: i32, row: i32) [2]i32 {
    const grid_top = u.height() - pad_bottom - rows * key_d - (rows - 1) * key_gap;
    return .{ pad_x + col * (key_d + key_gap) + @divTrunc(key_d, 2), grid_top + row * (key_d + key_gap) + @divTrunc(key_d, 2) };
}

fn clickKey(app: *App, u: *Ui, col: i32, row: i32) void {
    const p = keyCenter(u, col, row);
    testStep(app, u, &.{
        .{ .kind = .mouse_move, .a = p[0], .b = p[1] },
        .{ .kind = .mouse_down, .a = p[0], .b = p[1], .c = 1, .d = 1 },
        .{ .kind = .mouse_up, .a = p[0], .b = p[1], .c = 1 },
    });
}

fn expectShown(app: *const App, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(want, app.eng.display(&buf));
}

test "keyboard and mouse input" {
    const a = std.testing.allocator;
    var fonts = ui.FontSet.load(a) catch return error.SkipZigTest;
    defer fonts.deinit();
    var win = try ui.Window.openHeadless(a, App.window);
    defer win.close();
    var u = Ui.init(a, &win, &fonts);
    defer u.deinit();
    var app = try App.init(a, &u);
    testStep(&app, &u, &.{});

    typeText(&app, &u, "12+3*4");
    try expectShown(&app, "4");
    // Several keys in one frame keep their order.
    typeText(&app, &u, "=");
    try expectShown(&app, "24");
    typeText(&app, &u, "1+1=");
    try expectShown(&app, "2");
    typeText(&app, &u, "12+3*4");
    testStep(&app, &u, &.{.{ .kind = .key_down, .a = Key.enter }});
    try expectShown(&app, "24");
    try std.testing.expect(app.flash != null);

    // Mouse: 7 × 6 =
    clickKey(&app, &u, 0, 1);
    try expectShown(&app, "7");
    clickKey(&app, &u, 3, 1);
    try std.testing.expectEqual(engine.BinOp.mul, app.eng.activeOp().?);
    clickKey(&app, &u, 2, 2);
    clickKey(&app, &u, 3, 4);
    try expectShown(&app, "42");

    // Backspace and Esc.
    typeText(&app, &u, "123");
    testStep(&app, &u, &.{.{ .kind = .key_down, .a = Key.backspace }});
    try expectShown(&app, "12");
    testStep(&app, &u, &.{.{ .kind = .key_down, .a = Key.esc }});
    try expectShown(&app, "0");

    // AC/C key and the wide 0 key (click its right half).
    typeText(&app, &u, "5");
    clickKey(&app, &u, 0, 0);
    try expectShown(&app, "0");
    clickKey(&app, &u, 1, 4);
    typeText(&app, &u, "%");
    try expectShown(&app, "0");

    // Scientific mode lays out the extra keys to the left.
    app.setScientific(&u, true);
    try std.testing.expectEqual(@as(u8, 12), app.eng.max_digits);
}
