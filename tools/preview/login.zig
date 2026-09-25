//! Host preview of the login screen.
const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");
const login = @import("login");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const a = gpa_state.allocator();
    const args = try std.process.argsAlloc(a);
    const out = if (args.len > 1) args[1] else "/tmp/login.png";
    const mode: login.Mode = if (args.len > 2 and std.mem.eql(u8, args[2], "setup")) .setup else .login;
    var fonts = try ui.FontSet.load(a);
    var win = try ui.Window.openHeadless(a, .{ .width = 1280, .height = 800 });
    var u = ui.Ui.init(a, &win, &fonts);
    u.setDark(true, null);
    var l = login.Login.init(a);
    var users = [_]login.User{
        .{ .name = "zen", .full_name = "Zen User", .uid = 501 },
        .{ .name = "sara", .full_name = "Sara Ahmed", .uid = 502 },
    };
    l.users = &users;
    l.mode = mode;
    if (mode == .login) l.password.set(a, "secret");
    u.focus = ui.ui.hashId("password");
    u.beginFrame(&.{});
    _ = l.frame(&u);
    u.endFrame();
    try gfx.png.writeFile(u.canvas, out);
}
