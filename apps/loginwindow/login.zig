//! Login / lock screen UI (drawing and interaction; no I/O).

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const icons = @import("icons");
const abi = @import("abi");

const Rect = ui.Rect;
const Ui = ui.Ui;
const Key = abi.input.Key;
const pm = ui.pm;

pub const Mode = enum { login, locked, setup };

pub const User = struct {
    name: []const u8,
    full_name: []const u8,
    uid: u32,
};

pub const Action = union(enum) {
    none,
    /// Try to authenticate `users[index]` with the typed password.
    authenticate: usize,
    create_account,
    restart,
    shutdown,
};

pub const Login = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .login,
    users: []User = &.{},
    selected: usize = 0,
    password: ui.TextState = .{},
    error_msg: []const u8 = "",
    shake_frames: u8 = 0,
    busy: bool = false,
    background: ?gfx.Image = null,
    bg_w: i32 = 0,
    bg_h: i32 = 0,
    wallpaper: gfx.wallpaper.Variant = .golden_gate,
    // Setup assistant fields.
    full_name: ui.TextState = .{},
    account: ui.TextState = .{},
    password2: ui.TextState = .{},
    arabic: bool = false,

    pub fn init(allocator: std.mem.Allocator) Login {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Login) void {
        if (self.background) |*b| b.deinit(self.allocator);
        self.password.deinit(self.allocator);
        self.full_name.deinit(self.allocator);
        self.account.deinit(self.allocator);
        self.password2.deinit(self.allocator);
    }

    fn ensureBackground(self: *Login, w: i32, h: i32) void {
        if (self.background != null and self.bg_w == w and self.bg_h == h) return;
        if (self.background) |*b| b.deinit(self.allocator);
        var img = gfx.Image.init(self.allocator, @intCast(w), @intCast(h)) catch return;
        const c = img.canvas();
        gfx.wallpaper.render(c, self.allocator, self.wallpaper, .{ .detail = 2 }) catch c.clear(gfx.Color.fromHex(0x3A2B5A));
        // Full-resolution blur keeps the gradients smooth.
        gfx.effects.blur(c, c.bounds(), 30);
        // Slight darkening for legibility.
        c.fillRect(c.bounds(), gfx.Color.rgba(0, 0, 0, 40));
        self.background = img;
        self.bg_w = w;
        self.bg_h = h;
    }

    pub fn fail(self: *Login, msg: []const u8) void {
        self.error_msg = msg;
        self.shake_frames = 12;
        self.password.set(self.allocator, "");
        self.busy = false;
    }

    fn glassPanel(self: *Login, u: *Ui, r: Rect, radius: i32) void {
        if (self.background) |bg| {
            var style = gfx.GlassStyle.clear;
            style.tint = gfx.Color.rgba(255, 255, 255, 38);
            gfx.glass.drawGlass(u.canvas, r, radius, bg.canvas(), style);
        } else {
            u.fillRound(r, @floatFromInt(radius), 0x40FFFFFF);
        }
    }

    fn clockStrings(date_buf: []u8, time_buf: []u8) struct { date: []const u8, time: []const u8 } {
        const ts = std.posix.clock_gettime(.REALTIME) catch return .{ .date = "", .time = "" };
        const secs: u64 = @intCast(@max(ts.sec, 0));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const wdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };
        const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
        const date = std.fmt.bufPrint(date_buf, "{s}, {d} {s}", .{ wdays[day.day % 7], md.day_index + 1, months[@intFromEnum(md.month) - 1] }) catch "";
        const time = std.fmt.bufPrint(time_buf, "{d}:{d:0>2}", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
        return .{ .date = date, .time = time };
    }

    /// Draw the screen and return what the user asked for.
    pub fn frame(self: *Login, u: *Ui) Action {
        const w = u.width();
        const h = u.height();
        self.ensureBackground(w, h);
        if (self.background) |bg| u.canvas.blitOpaque(bg.canvas(), 0, 0) else u.clear(0xFF2A2140);

        const white: u32 = 0xFFFFFFFF;
        const soft: u32 = 0xCCFFFFFF;

        // Large clock (macOS 26 lock screen style).
        var db: [64]u8 = undefined;
        var tb: [16]u8 = undefined;
        const clk = clockStrings(&db, &tb);
        u.text(Rect.init(0, 70, w, 30), clk.date, .{ .size = 22, .weight = .semibold, .color = soft, .@"align" = .center });
        u.text(Rect.init(0, 100, w, 130), clk.time, .{ .size = 116, .weight = .bold, .color = 0xEEFFFFFF, .@"align" = .center });

        var action: Action = .none;
        switch (self.mode) {
            .login, .locked => action = self.drawLogin(u),
            .setup => action = self.drawSetup(u),
        }

        // Bottom controls.
        if (self.mode != .locked) {
            const labels = [_][]const u8{ "Restart", "Shut Down" };
            const syms = [_]icons.Symbol{ .arrow_up, .power };
            const bx0 = @divTrunc(w, 2) - 80;
            for (labels, 0..) |label, i| {
                const cx = bx0 + @as(i32, @intCast(i)) * 160;
                const btn = Rect.init(cx - 22, h - 116, 44, 44);
                const id = ui.ui.hashIdx("power", i);
                if (u.interact(id, btn)) action = if (i == 0) .restart else .shutdown;
                self.glassPanel(u, btn, 22);
                if (u.hot == id) u.fillRound(btn, 22, 0x26FFFFFF);
                if (i == 0) {
                    // Restart glyph: circular arrow.
                    const cxf: f32 = @floatFromInt(cx);
                    const cyf: f32 = @floatFromInt(btn.y + 22);
                    var p = gfx.Path.init(u.allocator);
                    defer p.deinit();
                    p.arc(cxf, cyf, 10, -1.2, 4.0, false) catch {};
                    u.canvas.strokePath(&p, 2.2, pm(white), .{}) catch {};
                    u.fillCircle(cxf + 10 * @cos(@as(f32, -1.2)), cyf + 10 * @sin(@as(f32, -1.2)), 2.4, white);
                } else {
                    icons.drawSymbol(u.canvas, u.allocator, syms[i], gfx.RectF.init(@floatFromInt(cx - 11), @floatFromInt(btn.y + 11), 22, 22), pm(white));
                }
                u.text(Rect.init(cx - 60, h - 64, 120, 20), label, .{ .size = 12, .weight = .medium, .color = soft, .@"align" = .center });
            }
        }
        // Keyboard layout indicator (bottom right).
        u.text(Rect.init(w - 120, h - 40, 100, 20), if (self.arabic) "العربية" else "U.S.", .{ .size = 12, .weight = .medium, .color = soft, .@"align" = .right });
        if (self.shake_frames > 0) {
            self.shake_frames -= 1;
            u.want_frame = true;
        }
        return action;
    }

    fn drawLogin(self: *Login, u: *Ui) Action {
        const w = u.width();
        const h = u.height();
        var action: Action = .none;
        if (self.users.len == 0) return .none;
        if (self.selected >= self.users.len) self.selected = 0;

        // User avatars row (only the session user when locked).
        const avatar_y = @divTrunc(h * 56, 100);
        const n: i32 = if (self.mode == .locked) 1 else @intCast(self.users.len);
        const spacing: i32 = 140;
        const x0 = @divTrunc(w, 2) - @divTrunc((n - 1) * spacing, 2);
        var i: usize = 0;
        while (i < self.users.len) : (i += 1) {
            if (self.mode == .locked and i != self.selected) continue;
            const slot: i32 = if (self.mode == .locked) 0 else @intCast(i);
            const cx = x0 + slot * spacing;
            const selected = i == self.selected;
            const radius: f32 = if (selected) 46 else 36;
            const hit = Rect.init(cx - 50, avatar_y - 50, 100, 130);
            if (u.interact(ui.ui.hashIdx("user", i), hit) and !selected) {
                self.selected = i;
                self.error_msg = "";
                self.password.set(self.allocator, "");
            }
            if (selected) u.fillCircle(@floatFromInt(cx), @floatFromInt(avatar_y), radius + 3, 0x66FFFFFF);
            u.avatar(@floatFromInt(cx), @floatFromInt(avatar_y), radius, self.users[i].full_name);
            u.text(Rect.init(cx - 70, avatar_y + @as(i32, @intFromFloat(radius)) + 10, 140, 22), self.users[i].full_name, .{ .size = 15, .weight = .semibold, .color = 0xFFFFFFFF, .@"align" = .center });
        }

        // Password field.
        var shake: i32 = 0;
        if (self.shake_frames > 0) shake = if (self.shake_frames % 2 == 0) 10 else -10;
        const fw: i32 = 260;
        const field = Rect.init(@divTrunc(w - fw, 2) + shake, avatar_y + 90, fw, 38);
        self.glassPanel(u, field, 19);
        if (self.busy) {
            u.text(field, "Logging in…", .{ .color = 0xDDFFFFFF, .@"align" = .center });
        } else {
            // Transparent text field over the glass.
            const saved = u.theme;
            u.theme.field_bg = 0x00000000;
            u.theme.control_border = 0x00000000;
            u.theme.label = 0xFFFFFFFF;
            u.theme.tertiary_label = 0xB3FFFFFF;
            u.theme.accent = 0xE6FFFFFF;
            u.focus = ui.ui.hashId("password");
            const res = u.textField("password", Rect.init(field.x, field.y, field.w - 40, field.h), &self.password, .{ .placeholder = "Enter Password", .secure = true, .capsule = true, .plain = true, .size = 14 });
            u.theme = saved;
            if (res.changed) self.error_msg = "";
            // Arrow button.
            const btn = Rect.init(field.right() - 34, field.y + 5, 28, 28);
            if (self.password.buf.items.len > 0) {
                u.fillRound(btn, 14, 0x40FFFFFF);
                icons.drawSymbol(u.canvas, u.allocator, .arrow_up, gfx.RectF.init(@floatFromInt(btn.x + 7), @floatFromInt(btn.y + 7), 14, 14), pm(0xFFFFFFFF));
            }
            if (res.submitted or u.interact(ui.ui.hashId("go"), btn)) {
                if (self.password.buf.items.len > 0 or true) {
                    self.busy = true;
                    action = .{ .authenticate = self.selected };
                }
            }
        }
        const hint: []const u8 = if (self.error_msg.len > 0) self.error_msg else if (self.mode == .locked) "Touch the keyboard to unlock" else "";
        if (hint.len > 0) u.text(Rect.init(0, field.bottom() + 14, w, 20), hint, .{ .size = 13, .weight = .medium, .color = 0xE6FFFFFF, .@"align" = .center });
        return action;
    }

    fn drawSetup(self: *Login, u: *Ui) Action {
        const w = u.width();
        const h = u.height();
        const panel = Rect.init(@divTrunc(w - 420, 2), @divTrunc(h * 36, 100), 420, 330);
        self.glassPanel(u, panel, 28);
        u.text(Rect.init(panel.x, panel.y + 22, panel.w, 30), "Create a Computer Account", .{ .size = 20, .weight = .bold, .color = 0xFFFFFFFF, .@"align" = .center });
        u.text(Rect.init(panel.x, panel.y + 52, panel.w, 20), "This account will be an administrator of this computer.", .{ .size = 12, .color = 0xCCFFFFFF, .@"align" = .center });
        const saved = u.theme;
        u.theme.field_bg = 0x33FFFFFF;
        u.theme.control_border = 0x33FFFFFF;
        u.theme.label = 0xFFFFFFFF;
        u.theme.tertiary_label = 0x99FFFFFF;
        const fx = panel.x + 40;
        const fw = panel.w - 80;
        _ = u.textField("full", Rect.init(fx, panel.y + 88, fw, 32), &self.full_name, .{ .placeholder = "Full Name" });
        _ = u.textField("acct", Rect.init(fx, panel.y + 130, fw, 32), &self.account, .{ .placeholder = "Account Name" });
        _ = u.textField("pw1", Rect.init(fx, panel.y + 172, fw, 32), &self.password, .{ .placeholder = "Password", .secure = true });
        const r4 = u.textField("pw2", Rect.init(fx, panel.y + 214, fw, 32), &self.password2, .{ .placeholder = "Verify Password", .secure = true });
        u.theme = saved;
        if (self.error_msg.len > 0) u.text(Rect.init(panel.x, panel.y + 250, panel.w, 20), self.error_msg, .{ .size = 12, .weight = .medium, .color = 0xFFFFD0D0, .@"align" = .center });
        // Suggest an account name from the full name.
        if (self.account.buf.items.len == 0 and self.full_name.buf.items.len > 0 and u.focus != ui.ui.hashId("acct")) {
            var tmp: [32]u8 = undefined;
            var n: usize = 0;
            for (self.full_name.buf.items) |ch| {
                if (n >= tmp.len) break;
                if (std.ascii.isAlphanumeric(ch)) {
                    tmp[n] = std.ascii.toLower(ch);
                    n += 1;
                }
            }
            if (n > 0) self.account.set(self.allocator, tmp[0..n]);
        }
        const go = u.button("create", Rect.init(panel.right() - 150, panel.bottom() - 52, 110, 32), "Continue", .{ .style = .primary });
        if (go or r4.submitted) {
            if (self.full_name.buf.items.len == 0 or self.account.buf.items.len == 0) {
                self.error_msg = "Please enter your name and an account name.";
            } else if (self.password.buf.items.len < 4) {
                self.error_msg = "Choose a password of at least 4 characters.";
            } else if (!std.mem.eql(u8, self.password.buf.items, self.password2.buf.items)) {
                self.error_msg = "The passwords don't match.";
            } else {
                self.busy = true;
                return .create_account;
            }
        }
        return .none;
    }

    /// Keyboard shortcuts for the login screen (layout toggle).
    pub fn handleKeys(self: *Login, u: *Ui) void {
        for (u.keys[0..u.key_count]) |k| {
            if (k.code == Key.space and k.mods & abi.window.Mods.ctrl != 0) self.arabic = !self.arabic;
        }
    }
};
