pub fn main() !void {
    try @import("ui").run(@import("app.zig").App);
}
