const std = @import("std");
const c = @import("../common.zig");
const id = @import("id.zig");

pub const help =
    \\Usage: groups [OPTION]... [USERNAME]...
    \\Print group memberships for each USERNAME or, if no USERNAME is specified, for
    \\the current process (which may differ if the groups database has changed).
    \\
;

pub fn main(args: c.Args) !u8 {
    var users: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{});
    while (p.next()) |o| switch (o) {
        .pos => |a| try users.append(c.gpa, a),
        else => p.bad(o),
    };
    const w = c.out;
    var nb: [64]u8 = undefined;
    if (users.items.len == 0) {
        for (id.currentGroups(), 0..) |g, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(c.groupName(&nb, g));
        }
        try w.writeByte('\n');
        return 0;
    }
    var status: u8 = 0;
    for (users.items) |u| {
        const ue = c.userByName(u) orelse {
            c.warn("{f}: no such user", .{c.q(u)});
            status = 1;
            continue;
        };
        try w.print("{s} :", .{u});
        for (c.userGroupList(ue.name, ue.gid)) |g| try w.print(" {s}", .{c.groupName(&nb, g)});
        try w.writeByte('\n');
    }
    return status;
}
