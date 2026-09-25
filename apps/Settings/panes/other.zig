//! Keyboard, Lock Screen, Storage and Developer.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const app_mod = @import("../app.zig");
const w = @import("../widgets.zig");
const sys = @import("../system.zig");
const general = @import("general.zig");

const App = app_mod.App;
const Ui = ui.Ui;
const Rect = ui.Rect;
const Form = w.Form;
const pad = w.pad;

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

const switch_items = [_][]const u8{ "Control–Space", "Option–Shift" };

/// Key caps ("⌃", "Space") right-aligned at `right_x`.
fn keycaps(u: *Ui, right_x: i32, cy: i32, keys: []const []const u8) void {
    const t = u.theme;
    var total: i32 = 0;
    for (keys) |k| total += @as(i32, @intFromFloat(@ceil(u.measure(k, .medium, 12)))) + 12 + 4;
    var x = right_x - total + 4;
    for (keys) |k| {
        const kw: i32 = @as(i32, @intFromFloat(@ceil(u.measure(k, .medium, 12)))) + 12;
        const r = Rect.init(x, cy - 11, @max(kw, 22), 22);
        u.fillRound(r, 5, if (t.dark) 0xFF3A3A3E else 0xFFFFFFFF);
        u.strokeRound(r, 5, 1, if (t.dark) 0x26FFFFFF else 0x1F000000);
        u.hline(r.x + 3, r.right() - 3, r.bottom() - 1, if (t.dark) 0x40000000 else 0x14000000);
        u.text(r, k, .{ .size = 12, .weight = .medium, .color = t.label, .@"align" = .center });
        x += @max(kw, 22) + 4;
    }
}

fn sliderRow(app: *App, u: *Ui, f: *Form, label: []const u8, id: []const u8, value: *f32, left: []const u8, right: []const u8) void {
    const t = u.theme;
    const r = f.row(58);
    u.text(Rect.init(r.x + pad, r.y, 200, r.h), label, .{});
    const sw: i32 = 240;
    const sx = r.right() - pad - sw;
    _ = u.slider(id, Rect.init(sx, r.y + 8, sw, 24), value, 0, 1);
    // Tick marks.
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        const tx = sx + 10 + @divTrunc(i * (sw - 20), 7);
        u.fillRect(Rect.init(tx, r.y + 32, 1, 4), t.tertiary_label);
    }
    u.text(Rect.init(sx, r.y + 36, 80, 16), left, .{ .size = 10.5, .color = t.secondary_label });
    u.text(Rect.init(r.right() - pad - 80, r.y + 36, 80, 16), right, .{ .size = 10.5, .color = t.secondary_label, .@"align" = .right });
    if (u.mouse_released and u.active == ui.ui.hashId(id)) app.savePrefs();
}

pub fn drawKeyboard(app: *App, u: *Ui, f: *Form) void {
    _ = f.begin(58 * 2 + 52);
    sliderRow(app, u, f, "Key repeat rate", "key-repeat", &app.prefs.key_repeat, "Slow", "Fast");
    sliderRow(app, u, f, "Delay until repeat", "key-delay", &app.prefs.key_delay, "Long", "Short");
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Keyboard navigation", "Use Tab to move focus between controls");
        if (f.toggle(r, "kbd-nav", &app.prefs.keyboard_nav)) app.savePrefs();
    }
    f.end();

    f.header("Text Input");
    _ = f.begin(52 * 2 + w.row_h);
    f.sep_inset = pad + 36;
    {
        const r = f.row(52);
        w.letterTile(u, Rect.init(r.x + pad, r.y + 14, 24, 24), "US", w.tint.blue);
        f.label2(r, r.x + pad + 36, "U.S.", "English · QWERTY");
        _ = f.value(r, "Always on");
    }
    {
        const r = f.row(52);
        w.letterTile(u, Rect.init(r.x + pad, r.y + 14, 24, 24), "ع", w.tint.green);
        f.label2(r, r.x + pad + 36, "العربية", "Arabic (PC) · right-to-left");
        if (f.toggle(r, "arabic-input", &app.prefs.arabic_input)) app.savePrefs();
    }
    f.sep_inset = pad;
    {
        const r = f.row(w.row_h);
        f.label(r, "Switch input source with");
        if (app.popupButton(u, "input-switch", r.right() - pad + 6, Form.centerY(r), &switch_items, &app.prefs.input_switch)) app.savePrefs();
    }
    f.end();
    f.note("Control–Space and Option–Shift both switch layouts; the menu bar shows the current one.");

    f.header("Keyboard Shortcuts");
    const shortcuts = [_]struct { []const u8, []const []const u8 }{
        .{ "Switch input source", &.{ "⌃", "Space" } },
        .{ "Lock Screen", &.{ "⌃", "⌘", "Q" } },
        .{ "App Switcher", &.{ "⌘", "Tab" } },
        .{ "Close window", &.{ "⌘", "W" } },
        .{ "Quit app", &.{ "⌘", "Q" } },
        .{ "Log Out", &.{ "⇧", "⌘", "Q" } },
    };
    _ = f.beginRows(shortcuts.len);
    for (shortcuts) |s| {
        const r = f.row(w.row_h);
        f.label(r, s[0]);
        keycaps(u, r.right() - pad, Form.centerY(r), s[1]);
    }
    f.end();
}

// ---------------------------------------------------------------------------
// Lock Screen
// ---------------------------------------------------------------------------

const saver_items = [_][]const u8{ "Never", "For 1 minute", "For 5 minutes", "For 10 minutes", "For 20 minutes", "For 1 hour" };
const password_items = [_][]const u8{ "Immediately", "After 5 seconds", "After 1 minute", "After 5 minutes", "After 1 hour" };
const clock_items = [_][]const u8{ "On Screen Saver and Lock Screen", "On Lock Screen", "Never" };

pub fn drawLockScreen(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    _ = f.beginRows(3);
    {
        const r = f.row(w.row_h);
        f.label(r, "Start Screen Saver when inactive");
        if (app.popupButton(u, "saver", r.right() - pad + 6, Form.centerY(r), &saver_items, &app.prefs.screen_saver)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Turn display off when inactive");
        if (app.popupButton(u, "display-off", r.right() - pad + 6, Form.centerY(r), &saver_items, &app.prefs.display_off)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        u.text(Rect.init(r.x + pad, r.y, r.w - 200, r.h), "Require password after screen saver begins", .{});
        if (app.popupButton(u, "require-pw", r.right() - pad + 6, Form.centerY(r), &password_items, &app.prefs.require_password)) app.savePrefs();
    }
    f.end();

    _ = f.beginRows(1);
    {
        const r = f.row(w.row_h);
        f.label(r, "Show large clock");
        if (app.popupButton(u, "large-clock", r.right() - pad + 6, Form.centerY(r), &clock_items, &app.prefs.large_clock)) app.savePrefs();
    }
    f.end();

    f.header("When Switching User");
    _ = f.begin(52 * 3);
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Show user list", "Otherwise the login window asks for a name and password");
        if (f.toggle(r, "user-list", &app.prefs.show_user_list)) app.savePrefs();
    }
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Show Restart and Shut Down buttons", "On the login window");
        if (f.toggle(r, "power-buttons", &app.prefs.show_power_buttons)) app.savePrefs();
    }
    {
        const r = f.row(52);
        f.label2(r, r.x + pad, "Show message when locked", "A short note on the lock screen");
        if (f.toggle(r, "lock-message", &app.prefs.lock_message)) app.savePrefs();
    }
    f.end();

    _ = f.begin(58);
    {
        const r = f.row(58);
        w.blit(u, app.icons.tile(.{ .sym = .lock }, 0xFF1C1C1E, 28), r.x + pad, r.y + 15);
        f.label2(r, r.x + pad + 40, "Lock your screen now", if (app.notice.len > 0) app.notice else "Your apps keep running while the screen is locked");
        if (w.pushButton(u, "lock-now", r.right() - pad, Form.centerY(r), "Lock Screen", .normal, true)) {
            app.setNotice("Press ⌃⌘Q to lock the screen", .{});
        }
    }
    f.end();
    u.text(Rect.init(f.x + 6, f.y - 8, f.w - 12, 16), "Tip: press ⌃⌘Q at any time to lock your screen.", .{ .size = 11.5, .color = t.secondary_label });
    f.space(16);
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

pub const StorageData = struct {
    loaded: bool = false,
    scanned: bool = false,
    fs: ?sys.FsStats = null,
    apps: u64 = 0,
    users: u64 = 0,
    system: u64 = 0,
};

pub fn scanStorage(app: *App) void {
    const d = &app.storage;
    var budget: usize = 20000;
    d.apps = sys.dirSize("/Applications", &budget) + sys.dirSize("/System/Applications", &budget);
    budget = 20000;
    d.users = sys.dirSize("/Users", &budget);
    if (d.fs) |fs| {
        const used = fs.total -| fs.free;
        d.system = used -| (d.apps + d.users);
    }
    d.scanned = true;
}

pub fn loadSample(app: *App) void {
    app.storage = .{
        .loaded = true,
        .scanned = true,
        .fs = .{ .total = 8_000_000_000, .free = 5_630_000_000 },
        .apps = 38_400_000,
        .users = 412_000_000,
        .system = 1_919_600_000,
    };
    app.dev = .{ .checked = true, .installed = true };
}

pub fn drawStorage(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    const d = &app.storage;
    if (!d.loaded) {
        d.loaded = true;
        d.fs = sys.statfs("/");
        app.startJob(.storage_scan);
    }
    const colors = [_]u32{ w.tint.gray, t.accent, w.tint.orange };
    const names = [_][]const u8{ "Zen OS & System Data", "Applications", "Users" };
    const sizes = [_]u64{ d.system, d.apps, d.users };

    const r = f.begin(150);
    w.blit(u, app.icons.tile(.{ .sym = .disk }, w.tint.gray, 44), r.x + pad + 2, r.y + 16);
    u.text(Rect.init(r.x + pad + 58, r.y + 18, r.w - 200, 20), "Zen HD", .{ .size = 15, .weight = .bold });
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var line: [96]u8 = undefined;
    if (d.fs) |fs| {
        const used = fs.total -| fs.free;
        u.text(Rect.init(r.x + pad + 58, r.y + 40, r.w - 200, 18), std.fmt.bufPrint(&line, "{s} of {s} used", .{ sys.formatBytes(&a, used), sys.formatBytes(&b, fs.total) }) catch "", .{ .size = 12, .color = t.secondary_label });
        _ = f.value(Rect.init(r.x, r.y + 18, r.w, 40), std.fmt.bufPrint(&line, "{s} available", .{sys.formatBytes(&a, fs.free)}) catch "");
        // Capacity bar with colored segments.
        const bar = Rect.init(r.x + pad, r.y + 78, r.w - 2 * pad, 16);
        u.fillRound(bar, 8, if (t.dark) 0xFF3A3A3D else 0xFFE3E3E8);
        const old = u.pushClip(bar);
        const total: f64 = @floatFromInt(@max(fs.total, 1));
        var x: i32 = bar.x;
        const segs = if (d.scanned) sizes else [_]u64{ used, 0, 0 };
        for (segs, 0..) |s, i| {
            const sw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(s)) / total * @as(f64, @floatFromInt(bar.w))));
            if (sw <= 0) continue;
            // Only the first segment is rounded (on the left); the free
            // space is the rounded track itself.
            var rr = gfx.RoundRect.init(Rect.init(x, bar.y, sw, bar.h), 0);
            if (x == bar.x) rr.radii = .{ .tl = 8, .bl = 8 };
            if (x + sw >= bar.right()) {
                rr.radii.tr = 8;
                rr.radii.br = 8;
            }
            u.canvas.fillRRect(rr, ui.pm(colors[i]));
            if (x > bar.x) u.fillRect(Rect.init(x, bar.y, 1, bar.h), if (t.dark) 0xFF2A2A2D else 0xFFF4F4F6);
            x += sw;
        }
        u.popClip(old);
        // Round the ends again over the segments.
        u.strokeRound(bar, 8, 1, if (t.dark) 0x1AFFFFFF else 0x14000000);
        // Legend.
        var lx = r.x + pad;
        const ly = r.y + 112;
        for (names, 0..) |n, i| {
            u.fillCircle(@floatFromInt(lx + 5), @floatFromInt(ly + 9), 4.5, colors[i]);
            const nw: i32 = @intFromFloat(@ceil(u.measure(n, .regular, 11.5)));
            u.text(Rect.init(lx + 14, ly, nw + 2, 18), n, .{ .size = 11.5, .color = t.secondary_label });
            lx += nw + 32;
        }
    } else {
        u.text(Rect.init(r.x + pad + 58, r.y + 40, r.w - 200, 18), "Capacity unavailable", .{ .size = 12, .color = t.secondary_label });
    }
    f.end();

    const rows = [_]struct { w.TileGlyph, u32, []const u8, u64 }{
        .{ .{ .sym = .apps }, w.tint.blue, "Applications", d.apps },
        .{ .{ .sym = .user_group }, w.tint.orange, "Users", d.users },
        .{ .{ .sym = .gear }, w.tint.gray, "Zen OS & System Data", d.system },
    };
    _ = f.beginRows(rows.len);
    f.sep_inset = pad + 32;
    for (rows) |row| {
        const rr = f.row(w.row_h);
        w.blit(u, app.icons.tile(row[0], row[1], 22), rr.x + pad, rr.y + 9);
        f.labelAt(rr, rr.x + pad + 32, row[2]);
        _ = f.value(rr, if (d.scanned) sys.formatBytes(&a, row[3]) else "Calculating…");
    }
    f.end();
    f.note("Sizes are estimated each time you open this pane.");
}

// ---------------------------------------------------------------------------
// Developer
// ---------------------------------------------------------------------------

pub const DevData = struct {
    checked: bool = false,
    installed: bool = false,
};

const zig_path = "/usr/lib/zig/zig";

const zen_lines = [_][]const u8{
    "$ cc hello.c -o hello",
    "$ c++ -O2 hello.cpp -o hello-cpp",
    "$ ./hello",
};
const host_lines = [_][]const u8{
    "# On your development machine (Zig 0.15):",
    "$ zig cc -target riscv64-linux-musl -static hello.c -o hello",
    "$ zig c++ -target riscv64-linux-musl -static hello.cpp -o hello",
};

fn copyLines(lines: []const []const u8) void {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.startsWith(u8, l, "# ")) continue;
        const s = if (std.mem.startsWith(u8, l, "$ ")) l[2..] else l;
        if (n + s.len + 1 > buf.len) break;
        @memcpy(buf[n .. n + s.len], s);
        n += s.len;
        buf[n] = '\n';
        n += 1;
    }
    ui.client.clipboardSet(buf[0..n]) catch {};
}

pub fn drawDeveloper(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    if (!app.dev.checked) {
        app.dev.checked = true;
        app.dev.installed = sys.exists(zig_path);
    }
    general.hero(app, u, f, .{ .sym = .terminal }, 0xFF3A3A3C, "Developer", "Build and run C, C++ and Zig programs directly on Zen OS with the bundled RISC-V toolchain.");

    _ = f.begin(52 + w.row_h * 3);
    {
        const r = f.row(52);
        w.blit(u, app.icons.tile(.{ .sym = .cpu }, w.tint.indigo, 26), r.x + pad, r.y + 13);
        f.label2(r, r.x + pad + 38, "C/C++ toolchain", zig_path);
        _ = w.status(u, r.right() - pad, Form.centerY(r), if (app.dev.installed) "Installed" else "Not installed", if (app.dev.installed) w.green(t) else w.orange(t));
    }
    const tools = [_][2][]const u8{
        .{ "cc, gcc, clang", "C compiler · C17 · musl libc" },
        .{ "c++, g++, clang++", "C++ compiler · libc++" },
        .{ "Target", "riscv64-linux-musl (static)" },
    };
    for (tools) |tl| {
        const r = f.row(w.row_h);
        const face = u.fonts.mono(12);
        const base: f32 = @floatFromInt(r.y + @divTrunc(r.h + @as(i32, @intFromFloat(face.cap_height)), 2));
        _ = u.textAt(@floatFromInt(r.x + pad), @round(base), tl[0], .mono, 12, t.label);
        _ = f.value(r, tl[1]);
    }
    f.end();
    if (!app.dev.installed) f.note("The toolchain is not in this image. Rebuild the disk image with the riscv64 Zig toolchain under /usr/lib/zig to compile on Zen.");

    f.header("Build on Zen");
    {
        const h: i32 = 20 + @as(i32, zen_lines.len) * 19;
        w.codeBlock(u, Rect.init(f.x, f.y, f.w, h), &zen_lines);
        if (w.pushButton(u, "copy-zen", f.x + f.w - 10, f.y + 18, "Copy", .normal, true)) copyLines(&zen_lines);
        f.space(h + 16);
    }
    f.header("Build on Another Computer");
    {
        const h: i32 = 20 + @as(i32, host_lines.len) * 19;
        w.codeBlock(u, Rect.init(f.x, f.y, f.w, h), &host_lines);
        f.space(h + 16);
    }
    f.note("Copy the binary into your home folder (or the disk image) and run it from Terminal. More examples are in examples/ in the Zen OS source tree.");
}
