//! "Hello Zen" — a minimal GlassKit app.
const std = @import("std");
const ui = @import("ui");
const abi = @import("abi");

pub const App = struct {
    count: u32 = 0,
    name: ui.TextState = .{},
    dark_toggle: bool = false,

    pub const window = ui.client.Options{
        .title = "Hello Zen",
        .width = 420,
        .height = 260,
        .flags = abi.window.Flags.resizable,
    };

    pub fn init(allocator: std.mem.Allocator, u: *ui.Ui) !App {
        _ = allocator;
        _ = u;
        return .{};
    }

    pub fn menu(self: *App, m: *abi.window.MenuWriter) void {
        _ = self;
        m.beginMenu("Hello Zen");
        m.item(1, "About Hello Zen", 0, 0, 0);
        m.separator();
        m.item(2, "Quit Hello Zen", 'q', 0, 0);
        m.endMenu();
    }

    pub fn onMenu(self: *App, u: *ui.Ui, id: u32) void {
        _ = self;
        if (id == 2) u.quit = true;
    }

    pub fn frame(self: *App, u: *ui.Ui) void {
        const t = u.theme;
        u.clear(t.window_bg);
        u.text(ui.Rect.init(24, 20, 372, 32), "Hello from Zen OS", .{ .size = 22, .weight = .bold });
        _ = u.textField("name", ui.Rect.init(24, 70, 240, 30), &self.name, .{ .placeholder = "Your name" });
        var buf: [96]u8 = undefined;
        const who = if (self.name.text().len > 0) self.name.text() else "world";
        const msg = std.fmt.bufPrint(&buf, "Hello, {s}! Clicked {d} times.", .{ who, self.count }) catch "";
        u.text(ui.Rect.init(24, 112, 372, 24), msg, .{ .color = t.secondary_label });
        if (u.button("click", ui.Rect.init(24, 160, 120, 32), "Click me", .{ .style = .primary })) self.count += 1;
        _ = u.toggle("toggle", 170, 164, &self.dark_toggle);
        u.text(ui.Rect.init(220, 164, 180, 24), "A switch", .{});
    }
};
