//! Privacy & Security: App Sandbox status, code signatures (Gatekeeper) and
//! entitlements of every installed app.
//!
//! Apps come from `launch:apps` (id\tname\tpath\ticon\tcategory), falling
//! back to scanning the application folders. Signatures are checked by
//! launchd (`verify <path>` on `launch:ctl`), one app per frame so the pane
//! stays responsive.

const std = @import("std");
const ui = @import("ui");
const zen = @import("zen");
const icons = @import("icons");
const app_mod = @import("../app.zig");
const w = @import("../widgets.zig");
const sys = @import("../system.zig");

const App = app_mod.App;
const Ui = ui.Ui;
const Rect = ui.Rect;
const Form = w.Form;
const hashIdx = ui.ui.hashIdx;
const pad = w.pad;
const Ent = zen.bundle.Ent;

pub const SigState = enum { pending, signed, unsigned, tampered, untrusted, unknown };

pub const AppRow = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    icon: icons.AppIcon,
    sandboxed: bool,
    ents: []const []const u8,
    sig: SigState = .pending,
    identity: []const u8 = "",
    approved: bool = false,
};

pub const PrivacyData = struct {
    arena: ?std.heap.ArenaAllocator = null,
    apps: []AppRow = &.{},
    allow: []const []const u8 = &.{},
    loaded: bool = false,
    next_verify: usize = 0,
    expanded: ?usize = null,

    pub fn verifyPending(self: *const PrivacyData) bool {
        return self.loaded and self.next_verify < self.apps.len;
    }

    pub fn deinit(self: *PrivacyData, a: std.mem.Allocator) void {
        _ = a;
        if (self.arena) |*ar| ar.deinit();
        self.arena = null;
    }
};

const app_dirs = [_][]const u8{ "/Applications", "/System/Applications", "/System/Applications/Utilities" };
const allow_file = "/etc/zen/gatekeeper.allow";

fn lessByName(_: void, a: AppRow, b: AppRow) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn addBundle(a: std.mem.Allocator, list: *std.ArrayList(AppRow), path: []const u8, fallback_icon: []const u8) void {
    var b = zen.bundle.load(a, path) catch {
        list.append(a, .{ .id = path, .name = std.fs.path.stem(path), .path = path, .icon = .generic, .sandboxed = false, .ents = &.{} }) catch {};
        return;
    };
    defer b.deinit();
    var ents = a.alloc([]const u8, b.entitlements.len) catch return;
    for (b.entitlements, 0..) |e, i| ents[i] = a.dupe(u8, e) catch "";
    const icon_name = if (b.info.icon.len > 0) b.info.icon else fallback_icon;
    list.append(a, .{
        .id = a.dupe(u8, b.info.id) catch "",
        .name = a.dupe(u8, b.info.name) catch "",
        .path = a.dupe(u8, path) catch "",
        .icon = icons.AppIcon.fromName(icon_name),
        .sandboxed = b.sandboxed(),
        .ents = ents,
    }) catch {};
}

fn load(app: *App) void {
    const d = &app.apps;
    d.deinit(app.allocator);
    d.arena = std.heap.ArenaAllocator.init(app.allocator);
    const a = d.arena.?.allocator();
    d.loaded = true;
    d.next_verify = 0;
    d.expanded = null;

    // Approved unsigned apps.
    var allow: std.ArrayList([]const u8) = .empty;
    if (sys.readAll(a, allow_file, 64 * 1024)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            allow.append(a, l) catch {};
        }
    }
    d.allow = allow.items;

    var list: std.ArrayList(AppRow) = .empty;
    if (sys.readAll(a, "launch:apps", 256 * 1024)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var it = std.mem.splitScalar(u8, line, '\t');
            _ = it.next() orelse continue; // id
            _ = it.next() orelse continue; // name
            const path = it.next() orelse continue;
            const icon = it.next() orelse "";
            addBundle(a, &list, path, icon);
        }
    }
    if (list.items.len == 0) {
        for (app_dirs) |dir_path| {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |e| {
                if (e.kind != .directory or !std.mem.endsWith(u8, e.name, ".app")) continue;
                const p = std.fs.path.join(a, &.{ dir_path, e.name }) catch continue;
                addBundle(a, &list, p, "");
            }
        }
    }
    std.mem.sort(AppRow, list.items, {}, lessByName);
    for (list.items) |*r| {
        for (d.allow) |p| if (std.mem.eql(u8, std.mem.trimRight(u8, p, "/"), r.path)) {
            r.approved = true;
        };
    }
    d.apps = list.items;
}

fn verifyOne(d: *PrivacyData) void {
    if (!d.verifyPending()) return;
    const r = &d.apps[d.next_verify];
    d.next_verify += 1;
    var cmd_buf: [600]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "verify {s}", .{r.path}) catch return;
    var reply_buf: [512]u8 = undefined;
    const reply = sys.launchCtl(cmd, &reply_buf) orelse {
        r.sig = .unknown;
        return;
    };
    if (std.mem.startsWith(u8, reply, "ok signed")) {
        r.sig = .signed;
        const ident = std.mem.trim(u8, reply["ok signed".len..], " ");
        if (d.arena) |*ar| r.identity = ar.allocator().dupe(u8, ident) catch "";
    } else if (std.mem.indexOf(u8, reply, "Unsigned") != null) {
        r.sig = .unsigned;
    } else if (std.mem.indexOf(u8, reply, "Tampered") != null) {
        r.sig = .tampered;
    } else if (std.mem.indexOf(u8, reply, "Untrusted") != null) {
        r.sig = .untrusted;
    } else {
        r.sig = .unknown;
    }
}

pub fn loadSample(app: *App) void {
    const d = &app.apps;
    d.deinit(app.allocator);
    d.arena = std.heap.ArenaAllocator.init(app.allocator);
    d.loaded = true;
    const sandbox_docs = &[_][]const u8{ Ent.app_sandbox, Ent.documents_rw, Ent.user_selected_rw };
    const sandbox_only = &[_][]const u8{Ent.app_sandbox};
    const admin = &[_][]const u8{Ent.system_admin};
    const net = &[_][]const u8{ Ent.app_sandbox, Ent.network_client, Ent.downloads_rw };
    const rows = [_]AppRow{
        .{ .id = "com.zen.ActivityMonitor", .name = "Activity Monitor", .path = "/System/Applications/Utilities/Activity Monitor.app", .icon = .activity, .sandboxed = false, .ents = admin, .sig = .signed, .identity = "Zen OS Platform" },
        .{ .id = "com.zen.Calculator", .name = "Calculator", .path = "/Applications/Calculator.app", .icon = .calculator, .sandboxed = true, .ents = sandbox_only, .sig = .signed, .identity = "Zen OS Platform" },
        .{ .id = "com.zen.Finder", .name = "Finder", .path = "/System/Applications/Finder.app", .icon = .finder, .sandboxed = false, .ents = admin, .sig = .signed, .identity = "Zen OS Platform" },
        .{ .id = "org.example.Hello", .name = "Hello", .path = "/Applications/Hello.app", .icon = .generic, .sandboxed = true, .ents = net, .sig = .unsigned, .approved = true },
        .{ .id = "com.zen.Settings", .name = "Settings", .path = "/System/Applications/Settings.app", .icon = .settings, .sandboxed = false, .ents = admin, .sig = .signed, .identity = "Zen OS Platform" },
        .{ .id = "com.zen.Terminal", .name = "Terminal", .path = "/System/Applications/Utilities/Terminal.app", .icon = .terminal, .sandboxed = false, .ents = admin, .sig = .signed, .identity = "Zen OS Platform" },
        .{ .id = "com.zen.TextEdit", .name = "TextEdit", .path = "/Applications/TextEdit.app", .icon = .textedit, .sandboxed = true, .ents = sandbox_docs, .sig = .signed, .identity = "Zen OS Platform" },
    };
    const a = d.arena.?.allocator();
    d.apps = a.dupe(AppRow, &rows) catch &.{};
    d.allow = a.dupe([]const u8, &.{"/Applications/Hello.app"}) catch &.{};
    d.next_verify = d.apps.len;
    d.expanded = 1;
}

fn sigText(r: *const AppRow) []const u8 {
    return switch (r.sig) {
        .pending => "Checking…",
        .signed => "Signed",
        .unsigned => if (r.approved) "Unsigned · Approved" else "Unsigned",
        .tampered => "Damaged",
        .untrusted => "Unknown developer",
        .unknown => "Signature unknown",
    };
}

fn sigColor(t: ui.Theme, r: *const AppRow) u32 {
    return switch (r.sig) {
        .signed => w.green(t),
        .unsigned => if (r.approved) w.orange(t) else w.red(t),
        .tampered, .untrusted => w.red(t),
        .pending, .unknown => t.tertiary_label,
    };
}

const row_h: i32 = 58;
const line_h: i32 = 22;

const ent_h: i32 = 34;

fn expandedHeight(r: *const AppRow) i32 {
    return row_h + 8 + 2 * line_h + @as(i32, @intCast(@max(1, r.ents.len))) * ent_h + 6;
}

pub fn draw(app: *App, u: *Ui, f: *Form) void {
    const d = &app.apps;
    if (!d.loaded) load(app);
    verifyOne(d);
    drawSandboxIntro(app, u, f);
    drawApps(app, u, f);
    drawGatekeeper(app, u, f);
}

fn drawSandboxIntro(app: *App, u: *Ui, f: *Form) void {
    const t = u.theme;
    const text = "Apps with the App Sandbox entitlement run in their own container (~/Library/Containers/<app id>) and can only open the files and services their entitlements allow. The kernel checks every URL a sandboxed app opens.";
    const text_w = f.w - pad * 2 - 44;
    const para_h = w.paragraphHeight(u, text, .regular, 11.5, text_w);
    const r = f.begin(38 + para_h + 14);
    w.blit(u, app.icons.tile(.{ .sym = .shield }, w.tint.blue, 30), r.x + pad, r.y + 14);
    u.text(Rect.init(r.x + pad + 44, r.y + 12, r.w - 80, 20), "App Sandbox", .{ .weight = .semibold });
    _ = u.paragraph(Rect.init(r.x + pad + 44, r.y + 36, text_w, para_h), text, .{ .size = 11.5, .color = t.secondary_label });
    f.end();
}

fn drawApps(app: *App, u: *Ui, f: *Form) void {
    const d = &app.apps;
    const t = u.theme;
    f.header("Applications");
    var total: i32 = 0;
    for (d.apps, 0..) |*r, i| total += if (d.expanded != null and d.expanded.? == i) expandedHeight(r) else row_h;
    _ = f.begin(@max(row_h, total));
    f.sep_inset = pad + 46;
    if (d.apps.len == 0) {
        const r = f.row(row_h);
        u.text(r, "No applications found", .{ .color = t.secondary_label, .@"align" = .center });
    }
    for (d.apps, 0..) |*a, i| {
        const open = d.expanded != null and d.expanded.? == i;
        const r = f.row(if (open) expandedHeight(a) else row_h);
        const head = Rect.init(r.x, r.y, r.w, row_h);
        const id = hashIdx("app-row", i);
        if (u.interact(id, head)) d.expanded = if (open) null else i;
        if (u.isActive(id) and u.hovering(head)) u.fillRound(head.inset(4, 3), 8, t.selection_inactive);
        w.blit(u, app.icons.app(a.icon, 34), r.x + pad, r.y + 12);
        const tx = r.x + pad + 46;
        u.text(Rect.init(tx, r.y + 11, r.w - 330, 18), a.name, .{ .weight = .semibold });
        u.text(Rect.init(tx, r.y + 30, r.w - 330, 16), a.id, .{ .size = 11, .color = t.secondary_label });
        // Right side: disclosure, signature, sandbox badge.
        const cy = r.y + @divTrunc(row_h, 2);
        w.chevron(u, @floatFromInt(r.right() - pad - 5), @floatFromInt(cy), 4.5, if (open) .down else .right, 1.6, t.tertiary_label);
        const sx = w.status(u, r.right() - pad - 22, cy, sigText(a), sigColor(t, a));
        _ = w.badge(u, sx - 10, cy, if (a.sandboxed) "Sandboxed" else "Not sandboxed", if (a.sandboxed) w.green(t) else w.orange(t));
        if (open) drawDetails(u, a, tx, r.y + row_h + 4, r.right() - pad);
    }
    f.end();
    f.note("Signatures are verified by launchd: Ed25519 over SHA-256 hashes of every file in the bundle. Click an app to see what it is allowed to do.");
}

fn drawDetails(u: *Ui, a: *const AppRow, lx: i32, y0: i32, right: i32) void {
    const t = u.theme;
    var y = y0;
    const detail = [_][2][]const u8{
        .{ "Location", a.path },
        .{ "Signed by", if (a.sig == .signed) (if (a.identity.len > 0) a.identity else "Zen OS Platform") else sigText(a) },
    };
    for (detail) |dl| {
        u.text(Rect.init(lx, y, 90, line_h), dl[0], .{ .size = 12, .color = t.secondary_label });
        u.text(Rect.init(lx + 90, y, right - lx - 90, line_h), dl[1], .{ .size = 12 });
        y += line_h;
    }
    if (a.ents.len == 0) {
        u.text(Rect.init(lx, y, 90, line_h), "Entitlements", .{ .size = 12, .color = t.secondary_label });
        u.text(Rect.init(lx + 90, y, right - lx - 90, line_h), "None", .{ .size = 12, .color = t.tertiary_label });
    }
    for (a.ents, 0..) |e, k| {
        u.text(Rect.init(lx, y, 90, line_h), if (k == 0) "Entitlements" else "", .{ .size = 12, .color = t.secondary_label });
        u.fillCircle(@floatFromInt(lx + 94), @floatFromInt(y + @divTrunc(line_h, 2)), 2, t.secondary_label);
        const desc = zen.bundle.describe(e);
        u.text(Rect.init(lx + 102, y, right - lx - 102, line_h), desc, .{ .size = 12 });
        if (!std.mem.eql(u8, desc, e)) {
            const face = u.fonts.mono(10);
            const old = u.pushClip(Rect.init(lx + 102, y + line_h - 4, right - lx - 102, 16));
            _ = u.textAt(@floatFromInt(lx + 102), @round(@as(f32, @floatFromInt(y + line_h + 6)) + face.cap_height / 2), e, .mono, 10, t.tertiary_label);
            u.popClip(old);
        }
        y += ent_h;
    }
}

fn drawGatekeeper(app: *App, u: *Ui, f: *Form) void {
    const d = &app.apps;
    const t = u.theme;
    f.header("Security");
    const allow_rows: i32 = @intCast(@max(1, d.allow.len));
    _ = f.begin(w.row_h + 32 + allow_rows * 30 + 8);
    {
        const r = f.row(w.row_h);
        f.label(r, "Allow applications from");
        const x = f.value(r, "Zen platform (signed)");
        w.checkmark(u, @floatFromInt(x - 18), @floatFromInt(Form.centerY(r) - 5), 10, 1.7, t.accent);
    }
    {
        const r = f.row(32 + allow_rows * 30 + 8);
        u.text(Rect.init(r.x + pad, r.y + 8, r.w - 2 * pad, 20), "Unsigned apps you approved", .{});
        var b: [24]u8 = undefined;
        u.text(Rect.init(r.x + pad, r.y + 8, r.w - 2 * pad, 20), std.fmt.bufPrint(&b, "{d}", .{d.allow.len}) catch "", .{ .color = t.secondary_label, .@"align" = .right });
        var y = r.y + 36;
        if (d.allow.len == 0) {
            u.text(Rect.init(r.x + pad + 12, y, r.w - 40, 24), "None — only signed platform apps can open.", .{ .size = 12, .color = t.secondary_label });
        }
        for (d.allow) |p| {
            const ir = Rect.init(r.x + pad, y, r.w - 2 * pad, 26);
            u.fillRound(ir, 7, if (t.dark) 0x0FFFFFFF else 0x08000000);
            w.blit(u, app.icons.app(.generic, 18), ir.x + 6, ir.y + 4);
            u.text(Rect.init(ir.x + 32, ir.y, ir.w - 40, ir.h), std.fs.path.stem(p), .{ .size = 12, .weight = .medium });
            u.text(Rect.init(ir.x + 32, ir.y, ir.w - 44, ir.h), p, .{ .size = 11, .color = t.tertiary_label, .@"align" = .right });
            y += 30;
        }
    }
    f.end();
    f.note("Gatekeeper opens apps signed by the Zen platform. Unsigned apps open only after you approve them once; the list is kept in /etc/zen/gatekeeper.allow.");
}
