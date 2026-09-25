const std = @import("std");
const c = @import("../common.zig");
const uname = @import("uname.zig");
const mem = std.mem;

pub const help =
    \\Usage: hostname [-s|-f|-d|-i] [NAME]
    \\       hostname -F FILE
    \\Show or set the system's host name.
    \\
    \\  -s, --short       short host name
    \\  -f, --fqdn, --long  long host name (FQDN)
    \\  -d, --domain      DNS domain name
    \\  -i, --ip-address  addresses for the host name
    \\  -F, --file FILE   read host name from FILE
    \\
;

pub fn main(args: c.Args) !u8 {
    var short = false;
    var domain = false;
    var ip = false;
    var file: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var p = c.Parser.init(args, &.{
        .{ "short", 's' }, .{ "fqdn", 'f' }, .{ "long", 'f' }, .{ "domain", 'd' }, .{ "ip-address", 'i' }, .{ "file", 'F' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            's' => short = true,
            'f', 'A', 'a' => {},
            'd' => domain = true,
            'i', 'I' => ip = true,
            'F' => file = p.arg(),
            else => p.bad(o),
        },
        .pos => |a| name = a,
        else => p.bad(o),
    };
    if (file) |f| {
        const data = c.readInput(f) orelse return 1;
        var it = mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const t = mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            name = t;
            break;
        }
    }
    if (name) |n| {
        const rc = std.os.linux.syscall2(.sethostname, @intFromPtr(n.ptr), n.len);
        const e = std.posix.errno(rc);
        if (e != .SUCCESS) c.fatal("you must be root to change the host name", .{});
        return 0;
    }
    const u = uname.utsname();
    const host = uname.field(&u.nodename);
    if (ip) {
        // no resolver: report loopback for our own name
        try c.out.writeAll("127.0.1.1\n");
        return 0;
    }
    if (domain) {
        if (mem.indexOfScalar(u8, host, '.')) |d| try c.out.print("{s}\n", .{host[d + 1 ..]}) else try c.out.writeAll("\n");
        return 0;
    }
    if (short) {
        const d = mem.indexOfScalar(u8, host, '.') orelse host.len;
        try c.out.print("{s}\n", .{host[0..d]});
        return 0;
    }
    try c.out.print("{s}\n", .{host});
    return 0;
}
