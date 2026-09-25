//! Users & Groups: account list, "Add User…" and "Change Password…" sheets.
//!
//! Accounts are created with `sudo -S useradd` (the admin's password is
//! written to sudo's standard input) and passwords are changed with
//! `passwd --stdin` (current, new, new — one per line).

const std = @import("std");
const ui = @import("ui");
const zen = @import("zen");
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

pub const UserRow = struct {
    name: []const u8,
    full: []const u8,
    uid: u32,
    admin: bool,
};

pub const UsersData = struct {
    arena: ?std.heap.ArenaAllocator = null,
    list: []UserRow = &.{},
    login_items: []const []const u8 = &.{},
    loaded: bool = false,
    guest: bool = false,
    auto_login: usize = 0,

    pub fn deinit(self: *UsersData, a: std.mem.Allocator) void {
        _ = a;
        if (self.arena) |*ar| ar.deinit();
        self.arena = null;
    }
};

fn fullName(gecos: []const u8, name: []const u8) []const u8 {
    const c = std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len;
    return if (c > 0) gecos[0..c] else name;
}

fn setList(app: *App, rows: []const UserRow) void {
    const d = &app.users;
    d.deinit(app.allocator);
    d.arena = std.heap.ArenaAllocator.init(app.allocator);
    const a = d.arena.?.allocator();
    var list = a.alloc(UserRow, rows.len) catch return;
    var n: usize = 0;
    // Current user first, then by uid.
    for (rows) |r| if (r.uid == app.uid) {
        list[n] = r;
        n += 1;
    };
    var rest: std.ArrayList(UserRow) = .empty;
    for (rows) |r| if (r.uid != app.uid) rest.append(a, r) catch {};
    std.mem.sort(UserRow, rest.items, {}, struct {
        fn lt(_: void, x: UserRow, y: UserRow) bool {
            return x.uid < y.uid;
        }
    }.lt);
    for (rest.items) |r| {
        list[n] = r;
        n += 1;
    }
    for (list[0..n]) |*r| {
        r.name = a.dupe(u8, r.name) catch "";
        r.full = a.dupe(u8, r.full) catch "";
    }
    d.list = list[0..n];
    var items = a.alloc([]const u8, n + 1) catch return;
    items[0] = "Off";
    for (d.list, 0..) |r, i| items[i + 1] = r.full;
    d.login_items = items;
    if (d.auto_login > n) d.auto_login = 0;
}

fn reload(app: *App) void {
    app.users.loaded = true;
    var db = zen.users.Db.load(app.allocator, "/") catch return;
    defer db.deinit();
    const humans = db.humanUsers(app.allocator) catch return;
    defer app.allocator.free(humans);
    var rows: std.ArrayList(UserRow) = .empty;
    defer rows.deinit(app.allocator);
    for (humans) |h| rows.append(app.allocator, .{ .name = h.name, .full = fullName(h.gecos, h.name), .uid = h.uid, .admin = db.isAdmin(h) }) catch {};
    // Make sure the signed-in user is listed even with an unusual uid.
    if (db.userById(app.uid)) |me| {
        var found = false;
        for (rows.items) |r| found = found or r.uid == me.uid;
        if (!found and me.uid != 0) rows.append(app.allocator, .{ .name = me.name, .full = fullName(me.gecos, me.name), .uid = me.uid, .admin = db.isAdmin(me) }) catch {};
    }
    setList(app, rows.items);
}

pub fn loadSample(app: *App) void {
    app.users.loaded = true;
    setList(app, &.{
        .{ .name = "zen", .full = "Zen User", .uid = 501, .admin = true },
        .{ .name = "sara", .full = "Sara Ahmed", .uid = 502, .admin = false },
        .{ .name = "omar", .full = "Omar Farouk", .uid = 503, .admin = true },
    });
}

fn currentIsAdmin(app: *App) bool {
    for (app.users.list) |r| if (r.uid == app.uid) return r.admin;
    return app.uid == 0;
}

pub fn draw(app: *App, u: *Ui, f: *Form) void {
    if (!app.users.loaded) reload(app);
    const t = u.theme;
    const d = &app.users;

    const row_h: i32 = 56;
    const n: i32 = @intCast(d.list.len);
    _ = f.begin(@max(1, n) * row_h);
    f.sep_inset = pad + 48;
    if (d.list.len == 0) {
        const r = f.row(row_h);
        u.text(r, "No user accounts found", .{ .color = t.secondary_label, .@"align" = .center });
    }
    for (d.list, 0..) |usr, i| {
        const r = f.row(row_h);
        const cy = Form.centerY(r);
        u.avatar(@floatFromInt(r.x + pad + 18), @floatFromInt(cy), 18, usr.full);
        const x = r.x + pad + 48;
        const me = usr.uid == app.uid;
        u.text(Rect.init(x, cy - 18, r.w - 260, 18), usr.full, .{ .weight = .semibold });
        var sub_buf: [96]u8 = undefined;
        const sub = std.fmt.bufPrint(&sub_buf, "{s}{s}", .{ if (usr.admin) "Admin" else "Standard", if (me) " · Signed in" else "" }) catch "";
        u.text(Rect.init(x, cy + 1, r.w - 260, 16), sub, .{ .size = 11, .color = t.secondary_label });
        if (me) {
            if (w.pushButton(u, "change-password", r.right() - pad, cy, "Change Password…", .normal, true)) app.openSheet(u, .change_password);
        } else {
            var id_buf: [32]u8 = undefined;
            const id_s = std.fmt.bufPrint(&id_buf, "{s}", .{usr.name}) catch "";
            u.text(Rect.init(r.right() - pad - 160, r.y, 160, r.h), id_s, .{ .size = 12, .color = t.tertiary_label, .@"align" = .right });
        }
        _ = i;
    }
    f.end();

    // "Add User…" below the list, right aligned (macOS style).
    const admin = currentIsAdmin(app);
    f.y -= 6;
    if (w.pushButton(u, "add-user", f.x + f.w, f.y + 12, "Add User…", .normal, admin)) app.openSheet(u, .add_user);
    if (!admin) u.text(Rect.init(f.x + 6, f.y, f.w - 140, 24), "Only administrators can add users.", .{ .size = 11, .color = t.secondary_label });
    f.space(38);
    if (app.notice.len > 0) {
        u.text(Rect.init(f.x + 6, f.y - 8, f.w, 16), app.notice, .{ .size = 11, .color = w.green(t) });
        f.space(14);
    }

    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        u.fillCircle(@floatFromInt(r.x + pad + 11), @floatFromInt(Form.centerY(r)), 11, w.tint.gray);
        w.blit(u, app.icons.symbol(.person, 0xFFFFFFFF, 14), r.x + pad + 4, Form.centerY(r) - 7);
        f.labelAt(r, r.x + pad + 32, "Guest User");
        _ = w.switchControl(u, "guest", r.right() - pad - 38, r.y + 9, &d.guest, true);
    }
    {
        const r = f.row(w.row_h);
        f.label(r, "Automatically log in as");
        _ = app.popupButton(u, "auto-login", r.right() - pad + 6, Form.centerY(r), d.login_items, &d.auto_login);
    }
    f.end();

    f.header("Groups");
    _ = f.beginRows(2);
    {
        const r = f.row(w.row_h);
        f.label2(r, r.x + pad, "admin", "Can use sudo, install apps and change system settings");
        var count: usize = 0;
        for (d.list) |x| count += @intFromBool(x.admin);
        var b: [24]u8 = undefined;
        _ = f.value(r, std.fmt.bufPrint(&b, "{d} member{s}", .{ count, if (count == 1) "" else "s" }) catch "");
    }
    {
        const r = f.row(w.row_h);
        f.label2(r, r.x + pad, "staff", "All local users");
        var b: [24]u8 = undefined;
        _ = f.value(r, std.fmt.bufPrint(&b, "{d} member{s}", .{ d.list.len, if (d.list.len == 1) "" else "s" }) catch "");
    }
    f.end();
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

fn deriveAccount(full: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (full) |c| {
        if (n >= out.len or n >= 32) break;
        const l = std.ascii.toLower(c);
        if (std.ascii.isLower(l) or (std.ascii.isDigit(l) and n > 0)) {
            out[n] = l;
            n += 1;
        }
    }
    return out[0..n];
}

fn formRow(app: *App, u: *Ui, r: Rect, y: i32, label: []const u8, idx: usize, secure: bool, placeholder: []const u8) ui.ui.TextFieldResult {
    const t = u.theme;
    u.text(Rect.init(r.x + 20, y, 120, 26), label, .{ .color = t.secondary_label, .@"align" = .right });
    var id_buf: [8]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "sf{d}", .{idx}) catch "sf";
    return app.field(u, id, Rect.init(r.x + 152, y, r.w - 176, 26), &app.fields[idx], .{ .secure = secure, .placeholder = placeholder });
}

fn cycleFocus(u: *Ui, count: usize) void {
    if (!u.keyPressed(Key.tab)) return;
    var ids: [6]ui.ui.Id = undefined;
    for (0..count) |i| {
        var b: [8]u8 = undefined;
        ids[i] = hashId(std.fmt.bufPrint(&b, "sf{d}", .{i}) catch "sf");
    }
    var next: usize = 0;
    for (ids[0..count], 0..) |id, i| {
        if (u.focus == id) next = (i + 1) % count;
    }
    u.focus = ids[next];
}

pub fn drawSheet(app: *App, u: *Ui) void {
    switch (app.sheet) {
        .add_user => drawAddUser(app, u),
        .change_password => drawChangePassword(app, u),
        else => {},
    }
}

fn drawAddUser(app: *App, u: *Ui) void {
    const t = u.theme;
    const r = app.sheetPanel(u, 440, 404);
    const busy = app.job == .add_user;
    w.blit(u, app.icons.tile(.{ .sym = .person }, w.tint.blue, 40), r.x + 24, r.y + 22);
    u.text(Rect.init(r.x + 78, r.y + 22, r.w - 100, 20), "New Account", .{ .size = 15, .weight = .bold });
    u.text(Rect.init(r.x + 78, r.y + 42, r.w - 100, 18), "The account gets a home folder in /Users.", .{ .size = 12, .color = t.secondary_label });

    var y = r.y + 80;
    const r0 = formRow(app, u, r, y, "Full Name", 0, false, "Sara Ahmed");
    y += 36;
    const r1 = formRow(app, u, r, y, "Account Name", 1, false, "sara");
    if (r1.changed) app.account_edited = true;
    if (r0.changed and !app.account_edited) {
        var b: [32]u8 = undefined;
        app.fields[1].set(app.allocator, deriveAccount(app.fields[0].text(), &b));
    }
    y += 36;
    const r2 = formRow(app, u, r, y, "Password", 2, true, "Required");
    y += 36;
    const r3 = formRow(app, u, r, y, "Verify", 3, true, "Retype password");
    y += 40;
    u.text(Rect.init(r.x + 152, y, r.w - 230, 22), "Administrator", .{});
    _ = w.switchControl(u, "sheet-admin", r.right() - 24 - 38, y, &app.sheet_admin, !busy);
    u.text(Rect.init(r.x + 152, y + 20, r.w - 230, 16), "Can manage users and system settings", .{ .size = 11, .color = t.secondary_label });
    y += 48;
    w.separator(u, r.x + 20, r.right() - 20, y);
    y += 12;
    var label_buf: [96]u8 = undefined;
    const pw_label = std.fmt.bufPrint(&label_buf, "Password for {s}", .{app.user_name}) catch "Your password";
    const r4 = formRow(app, u, r, y, "Your Password", 4, true, pw_label);
    y += 32;
    cycleFocus(u, 5);

    if (app.sheet_error.len > 0) {
        u.text(Rect.init(r.x + 152, y, r.w - 176, 18), app.sheet_error, .{ .size = 11, .color = w.red(t) });
    }
    if (busy) u.text(Rect.init(r.x + 24, r.bottom() - 44, 200, 26), "Creating account…", .{ .size = 12, .color = t.secondary_label });
    const ok = w.pushButton(u, "add-ok", r.right() - 24, r.bottom() - 32, "Create User", .primary, !busy);
    const cancel = w.pushButton(u, "add-cancel", r.right() - 24 - 120, r.bottom() - 32, "Cancel", .normal, !busy);
    if (cancel or (u.keyPressed(Key.esc) and !busy)) {
        app.closeSheet(u);
        return;
    }
    const submit = ok or r0.submitted or r1.submitted or r2.submitted or r3.submitted or r4.submitted;
    if (!submit or busy) return;
    const full = std.mem.trim(u8, app.fields[0].text(), " ");
    const name = std.mem.trim(u8, app.fields[1].text(), " ");
    if (full.len == 0) return app.setSheetError("Enter the person’s full name.", .{});
    if (!zen.users.validName(name)) return app.setSheetError("Account names use lowercase letters, digits, “-” and “_”.", .{});
    for (app.users.list) |x| if (std.mem.eql(u8, x.name, name)) return app.setSheetError("An account named “{s}” already exists.", .{name});
    if (app.fields[2].text().len < 4) return app.setSheetError("The password must be at least 4 characters.", .{});
    if (!std.mem.eql(u8, app.fields[2].text(), app.fields[3].text())) return app.setSheetError("The passwords don’t match.", .{});
    if (app.fields[4].text().len == 0) return app.setSheetError("Enter your password to allow this.", .{});
    if (std.mem.indexOfAny(u8, full, ":\n") != null) return app.setSheetError("The full name can’t contain “:”.", .{});
    app.sheet_error = "";
    app.startJob(.add_user);
}

fn drawChangePassword(app: *App, u: *Ui) void {
    const t = u.theme;
    const r = app.sheetPanel(u, 420, 256);
    const busy = app.job == .change_password;
    u.avatar(@floatFromInt(r.x + 44), @floatFromInt(r.y + 42), 20, app.full_name);
    u.text(Rect.init(r.x + 78, r.y + 22, r.w - 100, 20), "Change Password", .{ .size = 15, .weight = .bold });
    var sub_buf: [128]u8 = undefined;
    u.text(Rect.init(r.x + 78, r.y + 42, r.w - 100, 18), std.fmt.bufPrint(&sub_buf, "for {s} ({s})", .{ app.full_name, app.user_name }) catch "", .{ .size = 12, .color = t.secondary_label });
    var y = r.y + 84;
    const r0 = formRow(app, u, r, y, "Old Password", 0, true, "Current password");
    y += 36;
    const r1 = formRow(app, u, r, y, "New Password", 1, true, "At least 4 characters");
    y += 36;
    const r2 = formRow(app, u, r, y, "Verify", 2, true, "Retype new password");
    y += 34;
    cycleFocus(u, 3);
    if (app.sheet_error.len > 0) u.text(Rect.init(r.x + 152, y, r.w - 176, 18), app.sheet_error, .{ .size = 11, .color = w.red(t) });
    if (busy) u.text(Rect.init(r.x + 24, r.bottom() - 44, 200, 26), "Changing password…", .{ .size = 12, .color = t.secondary_label });
    const ok = w.pushButton(u, "pw-ok", r.right() - 24, r.bottom() - 32, "Change Password", .primary, !busy);
    const cancel = w.pushButton(u, "pw-cancel", r.right() - 24 - 150, r.bottom() - 32, "Cancel", .normal, !busy);
    if (cancel or (u.keyPressed(Key.esc) and !busy)) {
        app.closeSheet(u);
        return;
    }
    if (!(ok or r0.submitted or r1.submitted or r2.submitted) or busy) return;
    if (app.fields[0].text().len == 0) return app.setSheetError("Enter your current password.", .{});
    if (app.fields[1].text().len < 4) return app.setSheetError("The new password must be at least 4 characters.", .{});
    if (!std.mem.eql(u8, app.fields[1].text(), app.fields[2].text())) return app.setSheetError("The new passwords don’t match.", .{});
    if (std.mem.indexOfScalar(u8, app.fields[1].text(), '\n') != null) return app.setSheetError("Invalid password.", .{});
    app.sheet_error = "";
    app.startJob(.change_password);
}

/// Sample content for sheet previews.
pub fn previewSheet(app: *App, kind: app_mod.SheetKind) void {
    switch (kind) {
        .add_user => {
            app.fields[0].set(app.allocator, "Sara Ahmed");
            app.fields[1].set(app.allocator, "sara");
            app.fields[2].set(app.allocator, "secret");
            app.fields[3].set(app.allocator, "secret");
            app.sheet_admin = true;
        },
        .change_password => {
            app.fields[0].set(app.allocator, "zen");
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

pub fn runJob(app: *App, u: *Ui, job: app_mod.Job) void {
    var err_buf: [1024]u8 = undefined;
    switch (job) {
        .add_user => {
            const full = std.mem.trim(u8, app.fields[0].text(), " ");
            const name = std.mem.trim(u8, app.fields[1].text(), " ");
            var argv_buf: [12][]const u8 = undefined;
            var n: usize = 0;
            for ([_][]const u8{ "/usr/bin/sudo", "-S", "/usr/sbin/useradd", "-m", "-c", full }) |a| {
                argv_buf[n] = a;
                n += 1;
            }
            if (app.sheet_admin) {
                argv_buf[n] = "-G";
                argv_buf[n + 1] = "admin";
                n += 2;
            }
            argv_buf[n] = "-p";
            argv_buf[n + 1] = app.fields[2].text();
            argv_buf[n + 2] = name;
            n += 3;
            var input_buf: [256]u8 = undefined;
            defer @memset(&input_buf, 0);
            const input = std.fmt.bufPrint(&input_buf, "{s}\n", .{app.fields[4].text()}) catch return;
            const res = sys.run(app.allocator, argv_buf[0..n], input, &err_buf);
            if (res.code == 0) {
                app.setNotice("Created the account “{s}”.", .{name});
                app.users.loaded = false;
                app.closeSheet(u);
                return;
            }
            const m = res.message;
            if (res.code == 255) {
                app.setSheetError("Could not run sudo ({s}).", .{m});
            } else if (std.mem.indexOf(u8, m, "incorrect password") != null or std.mem.indexOf(u8, m, "Sorry") != null) {
                app.setSheetError("Your password is incorrect.", .{});
                app.fields[4].set(app.allocator, "");
            } else if (std.mem.indexOf(u8, m, "admin group") != null) {
                app.setSheetError("Only administrators can add users.", .{});
            } else if (std.mem.indexOf(u8, m, "already exists") != null) {
                app.setSheetError("An account named “{s}” already exists.", .{name});
            } else if (std.mem.indexOf(u8, m, "invalid user name") != null) {
                app.setSheetError("“{s}” is not a valid account name.", .{name});
            } else {
                app.setSheetError("useradd failed (exit {d}): {s}", .{ res.code, m });
            }
        },
        .change_password => {
            var input_buf: [512]u8 = undefined;
            defer @memset(&input_buf, 0);
            const input = std.fmt.bufPrint(&input_buf, "{s}\n{s}\n{s}\n", .{ app.fields[0].text(), app.fields[1].text(), app.fields[2].text() }) catch return;
            const res = sys.run(app.allocator, &.{ "/usr/bin/passwd", "--stdin" }, input, &err_buf);
            if (res.code == 0) {
                app.setNotice("Your password was changed.", .{});
                app.closeSheet(u);
                return;
            }
            const m = res.message;
            if (res.code == 255) {
                app.setSheetError("Could not run passwd ({s}).", .{m});
            } else if (std.mem.indexOf(u8, m, "Authentication") != null) {
                app.setSheetError("Your old password is incorrect.", .{});
                app.fields[0].set(app.allocator, "");
            } else if (std.mem.indexOf(u8, m, "do not match") != null) {
                app.setSheetError("The new passwords don’t match.", .{});
            } else if (std.mem.indexOf(u8, m, "too short") != null) {
                app.setSheetError("The new password is too short.", .{});
            } else {
                app.setSheetError("passwd failed (exit {d}): {s}", .{ res.code, m });
            }
        },
        else => {},
    }
}

test "account names derived from full names" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("saraahmed", deriveAccount("Sara Ahmed", &b));
    try std.testing.expectEqualStrings("omar2", deriveAccount("2 Omar 2", &b));
}
