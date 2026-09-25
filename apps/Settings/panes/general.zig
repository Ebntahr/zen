//! General: About, Software Update, Date & Time, Language & Region, Sharing.

const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");
const app_mod = @import("../app.zig");
const w = @import("../widgets.zig");
const sys = @import("../system.zig");

const App = app_mod.App;
const Ui = ui.Ui;
const Rect = ui.Rect;
const Form = w.Form;
const Key = abi.input.Key;
const hashId = ui.ui.hashId;
const pad = w.pad;

pub const AboutData = struct {
    loaded: bool = false,
    mem_total: ?u64 = null,
    disk: ?sys.FsStats = null,
    serial: [12]u8 = undefined,
    host_field: ui.TextState = .{},
    host_field_ready: bool = false,
    checked_buf: [48]u8 = undefined,
    checked: []const u8 = "",

    pub fn deinit(self: *AboutData, a: std.mem.Allocator) void {
        self.host_field.deinit(a);
    }
};

fn load(app: *App) void {
    const d = &app.about;
    if (d.loaded) return;
    d.loaded = true;
    d.mem_total = sys.memTotal();
    d.disk = sys.statfs("/");
    _ = sys.serialNumber(&d.serial);
}

pub fn loadSample(app: *App) void {
    const d = &app.about;
    d.loaded = true;
    d.mem_total = 2 * 1024 * 1024 * 1024;
    d.disk = .{ .total = 8_000_000_000, .free = 5_630_000_000 };
    _ = sys.serialNumber(&d.serial);
}

// ---------------------------------------------------------------------------
// Time zones
// ---------------------------------------------------------------------------

pub const Zone = struct { label: []const u8, city: []const u8, minutes: i32 };

pub const zones = [_]Zone{
    .{ .label = "UTC−10:00", .city = "Honolulu", .minutes = -600 },
    .{ .label = "UTC−08:00", .city = "Los Angeles", .minutes = -480 },
    .{ .label = "UTC−07:00", .city = "Denver", .minutes = -420 },
    .{ .label = "UTC−06:00", .city = "Chicago", .minutes = -360 },
    .{ .label = "UTC−05:00", .city = "New York", .minutes = -300 },
    .{ .label = "UTC−03:00", .city = "São Paulo", .minutes = -180 },
    .{ .label = "UTC±00:00", .city = "London", .minutes = 0 },
    .{ .label = "UTC+01:00", .city = "Paris", .minutes = 60 },
    .{ .label = "UTC+02:00", .city = "Cairo", .minutes = 120 },
    .{ .label = "UTC+03:00", .city = "Riyadh", .minutes = 180 },
    .{ .label = "UTC+04:00", .city = "Dubai", .minutes = 240 },
    .{ .label = "UTC+05:30", .city = "Mumbai", .minutes = 330 },
    .{ .label = "UTC+08:00", .city = "Singapore", .minutes = 480 },
    .{ .label = "UTC+09:00", .city = "Tokyo", .minutes = 540 },
    .{ .label = "UTC+10:00", .city = "Sydney", .minutes = 600 },
    .{ .label = "UTC+12:00", .city = "Auckland", .minutes = 720 },
};

const zone_items = blk: {
    var arr: [zones.len][]const u8 = undefined;
    for (zones, 0..) |z, i| arr[i] = z.label ++ "  " ++ z.city;
    break :blk arr;
};

pub fn zoneOffset(app: *const App) i32 {
    return zones[@min(app.prefs.tz, zones.len - 1)].minutes;
}

const regions = [_][]const u8{ "United States", "United Kingdom", "Saudi Arabia", "Egypt", "United Arab Emirates", "Germany", "Japan" };
const temperature_items = [_][]const u8{ "Celsius (°C)", "Fahrenheit (°F)" };

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

pub fn draw(app: *App, u: *Ui, f: *Form) void {
    switch (app.loc.sub) {
        .none => drawGeneral(app, u, f),
        .about => drawAbout(app, u, f),
        .software_update => drawUpdate(app, u, f),
        .date_time => drawDateTime(app, u, f),
        .language => drawLanguage(app, u, f),
        .sharing => drawSharing(app, u, f),
    }
}

/// Centered hero card at the top of a pane (icon, title, description).
pub fn hero(app: *App, u: *Ui, f: *Form, glyph: w.TileGlyph, color: u32, title: []const u8, desc: []const u8) void {
    const t = u.theme;
    const text_w = @min(f.w - 80, 420);
    const desc_h = centeredHeight(u, desc, 12, text_w);
    const h: i32 = 20 + 60 + 12 + 24 + desc_h + 20;
    const r = f.begin(h);
    w.blit(u, app.icons.tile(glyph, color, 60), r.x + @divTrunc(r.w - 60, 2), r.y + 20);
    u.text(Rect.init(r.x, r.y + 92, r.w, 24), title, .{ .size = 17, .weight = .bold, .@"align" = .center });
    centeredParagraph(u, Rect.init(r.x + @divTrunc(r.w - text_w, 2), r.y + 118, text_w, desc_h), desc, 12, t.secondary_label);
    f.end();
}

pub fn centeredHeight(u: *Ui, text: []const u8, size: f32, width: i32) i32 {
    return w.paragraphHeight(u, text, .regular, size, width);
}

pub fn centeredParagraph(u: *Ui, r: Rect, text: []const u8, size: f32, color: u32) void {
    const face = u.face(.regular, size);
    var it = face.lines(text, @floatFromInt(r.w));
    var y: f32 = @floatFromInt(r.y);
    const lh = face.line_height;
    while (it.next()) |line| {
        u.text(Rect.init(r.x, @intFromFloat(y), r.w, @intFromFloat(@ceil(lh))), text[line.start..line.end], .{ .size = size, .color = color, .@"align" = .center });
        y += lh;
    }
}

/// Row with an icon tile, a label, an optional value and a chevron.
pub fn navRow(app: *App, u: *Ui, f: *Form, id_str: []const u8, glyph: w.TileGlyph, color: u32, label: []const u8, value: []const u8) bool {
    const r = f.row(w.row_h);
    const id = hashId(id_str);
    const clicked = u.interact(id, r);
    const t = u.theme;
    if (u.isActive(id) and u.hovering(r)) u.fillRound(r.inset(4, 3), 8, t.selection_inactive);
    w.blit(u, app.icons.tile(glyph, color, 22), r.x + pad, r.y + 9);
    u.text(Rect.init(r.x + pad + 32, r.y, r.w - 200, r.h), label, .{});
    const cy: f32 = @floatFromInt(Form.centerY(r));
    const chx = r.right() - pad - 4;
    w.chevron(u, @floatFromInt(chx), cy, 4.5, .right, 1.6, t.tertiary_label);
    if (value.len > 0) {
        const tw: i32 = @intFromFloat(@ceil(u.measure(value, .regular, 13)));
        u.text(Rect.init(chx - 14 - tw, r.y, tw + 2, r.h), value, .{ .color = t.secondary_label });
    }
    return clicked;
}

fn drawGeneral(app: *App, u: *Ui, f: *Form) void {
    hero(app, u, f, .{ .sym = .gear }, w.tint.gray, "General", "Manage your overall setup and preferences for Zen OS, such as software updates, language, date and time, and more.");

    _ = f.beginRows(3);
    f.sep_inset = pad + 32;
    if (navRow(app, u, f, "g-about", .{ .sym = .info }, w.tint.gray, "About", "")) app.go(.{ .pane = .general, .sub = .about });
    if (navRow(app, u, f, "g-update", .{ .sym = .download }, w.tint.gray, "Software Update", "")) app.go(.{ .pane = .general, .sub = .software_update });
    if (navRow(app, u, f, "g-storage", .{ .sym = .disk }, w.tint.gray, "Storage", "")) app.go(.{ .pane = .storage });
    f.end();

    _ = f.beginRows(2);
    f.sep_inset = pad + 32;
    if (navRow(app, u, f, "g-date", .{ .sym = .clock }, w.tint.blue, "Date & Time", "")) app.go(.{ .pane = .general, .sub = .date_time });
    if (navRow(app, u, f, "g-lang", .{ .sym = .globe }, w.tint.blue, "Language & Region", "")) app.go(.{ .pane = .general, .sub = .language });
    f.end();

    _ = f.beginRows(1);
    if (navRow(app, u, f, "g-sharing", .{ .sym = .folder }, w.tint.blue, "Sharing", app.hostname)) app.go(.{ .pane = .general, .sub = .sharing });
    f.end();
}

fn drawAbout(app: *App, u: *Ui, f: *Form) void {
    load(app);
    const t = u.theme;
    const d = &app.about;
    f.space(12);
    const cx = f.x + @divTrunc(f.w, 2);
    w.blit(u, app.icons.app(.zen, 96), cx - 48, f.y);
    f.space(106);
    u.text(Rect.init(f.x, f.y, f.w, 32), "Zen OS", .{ .size = 26, .weight = .bold, .@"align" = .center });
    f.space(32);
    u.text(Rect.init(f.x, f.y, f.w, 18), "Version 1.0 (Golden Gate)", .{ .size = 12, .color = t.secondary_label, .@"align" = .center });
    f.space(34);

    var mem_buf: [32]u8 = undefined;
    const mem = if (d.mem_total) |m| sys.formatMemory(&mem_buf, m) else "Unknown";
    const rows = [_][2][]const u8{
        .{ "Name", app.hostname },
        .{ "Chip", "RISC-V 64 (rv64gc)" },
        .{ "Memory", mem },
        .{ "Kernel", "Zen microkernel" },
        .{ "Serial number", d.serial[0..] },
    };
    _ = f.beginRows(rows.len);
    for (rows) |row| {
        const r = f.row(w.row_h);
        f.label(r, row[0]);
        _ = f.value(r, row[1]);
    }
    f.end();

    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        f.label(r, "Display");
        _ = f.value(r, "Built-in Display, 1280 × 800");
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Storage");
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        var line: [96]u8 = undefined;
        const s = if (d.disk) |disk|
            std.fmt.bufPrint(&line, "Zen HD, {s} available of {s}", .{ sys.formatBytes(&a, disk.free), sys.formatBytes(&b, disk.total) }) catch ""
        else
            "Zen HD";
        _ = f.value(r, s);
    }
    f.end();

    u.text(Rect.init(f.x, f.y, f.w, 16), "™ and © 2026 Zen OS contributors. All rights reserved.", .{ .size = 11, .color = t.tertiary_label, .@"align" = .center });
    f.space(24);
}

fn drawUpdate(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    const r = f.begin(86);
    w.blit(u, app.icons.app(.zen, 52), r.x + pad + 2, r.y + 17);
    u.text(Rect.init(r.x + pad + 68, r.y + 22, r.w - 240, 20), "Zen OS 1.0 (Golden Gate)", .{ .weight = .semibold });
    u.fillCircle(@floatFromInt(r.x + pad + 74), @floatFromInt(r.y + 53), 6, w.green(t));
    w.checkmark(u, @floatFromInt(r.x + pad + 71), @floatFromInt(r.y + 50), 6, 1.3, 0xFFFFFFFF);
    u.text(Rect.init(r.x + pad + 86, r.y + 44, r.w - 240, 18), "Zen OS is up to date", .{ .color = t.secondary_label });
    if (w.pushButton(u, "check-now", r.right() - pad, r.y + 43, "Check Now", .normal, true)) {
        app.update_checked = true;
        if (sys.now(zoneOffset(app))) |c| {
            var tb: [16]u8 = undefined;
            app.about.checked = std.fmt.bufPrint(&app.about.checked_buf, "Today at {s}", .{sys.formatTime(&tb, c, app.prefs.clock24)}) catch "";
        } else app.about.checked = "Just now";
    }
    f.end();

    _ = f.beginRows(2);
    {
        const row = f.row(w.row_h);
        f.label(row, "Automatic updates");
        if (f.toggle(row, "auto-update", &app.prefs.auto_update)) app.savePrefs();
    }
    {
        const row = f.row(w.row_h);
        f.label(row, "Last checked");
        _ = f.value(row, if (app.about.checked.len > 0) app.about.checked else "Never");
    }
    f.end();
    f.note("Zen OS updates are delivered as signed system images. Apps you install from outside the Zen platform are not updated automatically.");
}

fn drawDateTime(app: *App, u: *Ui, f: *Form) void {
    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        f.label(r, "Set time and date automatically");
        _ = w.switchControl(u, "auto-time", r.right() - pad - 38, r.y + 9, &app.prefs.auto_time, false);
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Date and time");
        var buf: [96]u8 = undefined;
        var tb: [16]u8 = undefined;
        const s = if (sys.now(zoneOffset(app))) |c|
            std.fmt.bufPrint(&buf, "{s}, {d} {s} {d} at {s}", .{ sys.weekdays[c.weekday][0..3], c.day, sys.months[c.month - 1], c.year, sys.formatTime(&tb, c, app.prefs.clock24) }) catch ""
        else
            "Unknown";
        _ = f.value(r, s);
    }
    f.end();

    _ = f.beginRows(1);
    {
        const r = f.row(w.row_h);
        f.label2(r, r.x + pad, "24-hour time", "Show the menu bar clock as 14:05 instead of 2:05 PM");
        if (f.toggle(r, "clock24", &app.prefs.clock24)) {
            _ = sys.controlf("clock24 {s}", .{if (app.prefs.clock24) "on" else "off"});
            app.savePrefs();
        }
    }
    f.end();

    f.header("Time Zone");
    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        f.label(r, "Time zone");
        if (app.popupButton(u, "tz", r.right() - pad + 6, Form.centerY(r), &zone_items, &app.prefs.tz)) {
            _ = sys.controlf("tz {d}", .{zoneOffset(app)});
            app.savePrefs();
        }
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Closest city");
        _ = f.value(r, zones[@min(app.prefs.tz, zones.len - 1)].city);
    }
    f.end();
    f.note("The time zone is used by the menu bar clock and the lock screen.");
}

fn drawLanguage(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    f.header("Preferred Languages");
    const langs = [_][3][]const u8{
        .{ "English", "English (US)", "EN" },
        .{ "Arabic", "Arabic, right-to-left", "AR" },
    };
    _ = f.begin(2 * (w.row_h + 6));
    f.sep_inset = pad + 34;
    for (langs, 0..) |l, i| {
        const r = f.row(w.row_h + 6);
        const id = ui.ui.hashIdx("lang", i);
        if (u.interact(id, r) and app.prefs.language != i) {
            app.prefs.language = i;
            app.savePrefs();
        }
        w.letterTile(u, Rect.init(r.x + pad, r.y + 12, 22, 22), l[2], if (i == 0) w.tint.blue else w.tint.green);
        f.label2(r, r.x + pad + 34, l[0], if (app.prefs.language == i) "Primary" else l[1]);
        if (app.prefs.language == i) w.checkmark(u, @floatFromInt(r.right() - pad - 14), @floatFromInt(Form.centerY(r) - 6), 12, 1.8, t.accent);
    }
    f.end();
    f.note("Apps use the first language in this list that they support. Arabic text is laid out right-to-left.");

    _ = f.beginRows(4);
    {
        const r = f.row(w.row_h);
        f.label(r, "Region");
        if (app.popupButton(u, "region", r.right() - pad + 6, Form.centerY(r), &regions, &app.prefs.region)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Calendar");
        _ = f.value(r, "Gregorian");
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Temperature");
        if (app.popupButton(u, "temp", r.right() - pad + 6, Form.centerY(r), &temperature_items, &app.prefs.temperature)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Number format");
        const us_style = app.prefs.region <= 2 or app.prefs.region == 6;
        _ = f.value(r, if (us_style) "1,234,567.89" else "1.234.567,89");
    }
    f.end();

    _ = f.beginRows(1);
    {
        const r = f.row(w.row_h);
        f.label2(r, r.x + pad, "Input sources", if (app.prefs.arabic_input) "U.S., Arabic" else "U.S.");
        if (w.pushButton(u, "lang-edit", r.right() - pad, Form.centerY(r), "Edit…", .normal, true)) app.go(.{ .pane = .keyboard });
    }
    f.end();
}

fn validHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    return true;
}

fn drawSharing(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    const d = &app.about;
    if (!d.host_field_ready) {
        d.host_field.set(app.allocator, app.hostname);
        d.host_field_ready = true;
    }
    _ = f.begin(w.row_h + 8);
    {
        const r = f.row(w.row_h + 8);
        f.label(r, "Computer name");
        const changed = !std.mem.eql(u8, d.host_field.text(), app.hostname);
        const bw = w.buttonWidth(u, "Apply…");
        const field_w: i32 = 200;
        const fx = r.right() - pad - field_w - (if (changed) bw + 8 else 0);
        const res = app.field(u, "hostname", Rect.init(fx, r.y + 10, field_w, 26), &d.host_field, .{});
        if (changed) {
            if (w.pushButton(u, "host-apply", r.right() - pad, Form.centerY(r), "Apply…", .primary, validHostname(d.host_field.text())) or
                (res.submitted and validHostname(d.host_field.text())))
            {
                app.openSheet(u, .hostname);
            }
        }
    }
    f.end();
    var buf: [128]u8 = undefined;
    f.note(std.fmt.bufPrint(&buf, "Computers on your local network can access your computer at: {s}.local", .{app.hostname}) catch "");
    if (!validHostname(d.host_field.text())) {
        u.text(Rect.init(f.x + 6, f.y - 10, f.w, 16), "Use letters, digits and hyphens only.", .{ .size = 11, .color = w.red(t) });
        f.space(12);
    }

    f.header("Services");
    _ = f.begin(2 * (w.row_h + 6));
    {
        const r = f.row(w.row_h + 6);
        f.label2(r, r.x + pad, "File Sharing", "Share folders with other computers");
        if (f.toggle(r, "file-sharing", &app.prefs.file_sharing)) app.savePrefs();
    }
    {
        const r = f.row(w.row_h + 6);
        f.label2(r, r.x + pad, "Remote Login", "Allow shell access over the network");
        if (f.toggle(r, "remote-login", &app.prefs.remote_login)) app.savePrefs();
    }
    f.end();
    if (app.notice.len > 0) f.note(app.notice);
}

// ---------------------------------------------------------------------------
// Change computer name (sheet + privileged job)
// ---------------------------------------------------------------------------

pub fn drawHostnameSheet(app: *App, u: *Ui) void {
    const t = u.theme;
    const r = app.sheetPanel(u, 400, 262);
    w.blit(u, app.icons.tile(.{ .sym = .lock }, 0xFF1C1C1E, 40), r.x + 24, r.y + 22);
    u.text(Rect.init(r.x + 78, r.y + 22, r.w - 100, 20), "Change Computer Name", .{ .size = 15, .weight = .bold });
    u.text(Rect.init(r.x + 78, r.y + 42, r.w - 100, 18), "Settings is trying to modify system files.", .{ .size = 12, .color = t.secondary_label });
    const busy = app.job == .set_hostname;
    const lx = r.x + 24;
    const fx = r.x + 150;
    const fw = r.w - 174;
    u.text(Rect.init(lx, r.y + 84, 120, 26), "Computer name", .{ .color = t.secondary_label });
    const r0 = app.field(u, "sf0", Rect.init(fx, r.y + 84, fw, 26), &app.fields[0], .{});
    var label_buf: [96]u8 = undefined;
    const pw_label = std.fmt.bufPrint(&label_buf, "Password for {s}", .{app.user_name}) catch "Password";
    u.text(Rect.init(lx, r.y + 122, 126, 26), "Password", .{ .color = t.secondary_label });
    const r1 = app.field(u, "sf1", Rect.init(fx, r.y + 122, fw, 26), &app.fields[1], .{ .secure = true, .placeholder = pw_label });
    if (u.keyPressed(Key.tab)) u.focus = if (u.focus == hashId("sf0")) hashId("sf1") else hashId("sf0");
    if (app.sheet_error.len > 0) u.text(Rect.init(fx, r.y + 154, fw, 18), app.sheet_error, .{ .size = 11, .color = w.red(t) });
    if (busy) u.text(Rect.init(lx, r.bottom() - 44, 200, 26), "Changing name…", .{ .size = 12, .color = t.secondary_label });
    const ok = w.pushButton(u, "host-ok", r.right() - 24, r.bottom() - 32, "Change", .primary, !busy and app.fields[1].text().len > 0);
    const cancel = w.pushButton(u, "host-cancel", r.right() - 24 - 88, r.bottom() - 32, "Cancel", .normal, !busy);
    if (cancel or (u.keyPressed(Key.esc) and !busy)) {
        app.closeSheet(u);
        return;
    }
    if ((ok or r0.submitted or r1.submitted) and !busy) {
        const name = std.mem.trim(u8, app.fields[0].text(), " ");
        if (!validHostname(name)) {
            app.setSheetError("Use letters, digits and hyphens only.", .{});
        } else if (app.fields[1].text().len == 0) {
            app.setSheetError("Enter your password.", .{});
        } else {
            app.sheet_error = "";
            app.startJob(.set_hostname);
        }
    }
}

pub fn runHostnameJob(app: *App, u: *Ui) void {
    const name = std.mem.trim(u8, app.fields[0].text(), " ");
    var input_buf: [512]u8 = undefined;
    const input = std.fmt.bufPrint(&input_buf, "{s}\n{s}\n", .{ app.fields[1].text(), name }) catch return;
    defer @memset(&input_buf, 0);
    var err_buf: [512]u8 = undefined;
    const res = sys.run(app.allocator, &.{ "/usr/bin/sudo", "-S", "/usr/bin/tee", "/etc/hostname" }, input, &err_buf);
    if (res.code == 0) {
        app.hostname = sys.copyInto(&app.hostname_buf, name);
        app.about.host_field.set(app.allocator, name);
        app.setNotice("The computer name was changed to “{s}”.", .{name});
        app.closeSheet(u);
    } else if (res.code == 255) {
        app.setSheetError("Could not run sudo ({s}).", .{res.message});
    } else if (std.mem.indexOf(u8, res.message, "incorrect password") != null or std.mem.indexOf(u8, res.message, "Sorry") != null) {
        app.setSheetError("Incorrect password.", .{});
        app.fields[1].set(app.allocator, "");
    } else if (std.mem.indexOf(u8, res.message, "admin group") != null) {
        app.setSheetError("You need an administrator account.", .{});
    } else {
        app.setSheetError("Failed ({d}): {s}", .{ res.code, res.message });
    }
}
