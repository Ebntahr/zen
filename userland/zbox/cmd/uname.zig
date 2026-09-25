const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;

pub const help =
    \\Usage: uname [OPTION]...
    \\Print certain system information.  With no OPTION, same as -s.
    \\
    \\  -a, --all                print all information, in the following order,
    \\                             except omit -p and -i if unknown:
    \\  -s, --kernel-name        print the kernel name
    \\  -n, --nodename           print the network node hostname
    \\  -r, --kernel-release     print the kernel release
    \\  -v, --kernel-version     print the kernel version
    \\  -m, --machine            print the machine hardware name
    \\  -p, --processor          print the processor type (non-portable)
    \\  -i, --hardware-platform  print the hardware platform (non-portable)
    \\  -o, --operating-system   print the operating system
    \\
;

var uts: std.os.linux.utsname = undefined;
var uts_done = false;

pub fn utsname() *const std.os.linux.utsname {
    if (!uts_done) {
        uts_done = true;
        if (std.posix.errno(std.os.linux.uname(&uts)) != .SUCCESS) {
            uts = mem.zeroes(std.os.linux.utsname);
            @memcpy(uts.sysname[0..3], "Zen");
        }
    }
    return &uts;
}

pub fn field(f: anytype) []const u8 {
    return mem.sliceTo(f, 0);
}

pub fn osName(sys: []const u8) []const u8 {
    if (c.eql(sys, "Linux")) return "GNU/Linux";
    return sys;
}

pub fn main(args: c.Args) !u8 {
    var flags: u8 = 0;
    const S = 1;
    const N = 2;
    const R = 4;
    const V = 8;
    const M = 16;
    const P = 32;
    const I = 64;
    const O = 128;
    var p = c.Parser.init(args, &.{
        .{ "all", 'a' },          .{ "kernel-name", 's' },       .{ "nodename", 'n' },  .{ "kernel-release", 'r' },
        .{ "kernel-version", 'v' }, .{ "machine", 'm' },         .{ "processor", 'p' }, .{ "hardware-platform", 'i' },
        .{ "operating-system", 'o' },
    });
    var all = false;
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'a' => all = true,
            's' => flags |= S,
            'n' => flags |= N,
            'r' => flags |= R,
            'v' => flags |= V,
            'm' => flags |= M,
            'p' => flags |= P,
            'i' => flags |= I,
            'o' => flags |= O,
            else => p.bad(o),
        },
        .pos => |a| c.usageErr("extra operand {f}", .{c.q(a)}),
        else => p.bad(o),
    };
    if (all) flags |= S | N | R | V | M | O;
    if (flags == 0) flags = S;
    const u = utsname();
    var parts: std.ArrayList([]const u8) = .empty;
    if (flags & S != 0) try parts.append(c.gpa, field(&u.sysname));
    if (flags & N != 0) try parts.append(c.gpa, field(&u.nodename));
    if (flags & R != 0) try parts.append(c.gpa, field(&u.release));
    if (flags & V != 0) try parts.append(c.gpa, field(&u.version));
    if (flags & M != 0) try parts.append(c.gpa, field(&u.machine));
    if (flags & P != 0 and !all) try parts.append(c.gpa, "unknown");
    if (flags & I != 0 and !all) try parts.append(c.gpa, "unknown");
    if (flags & O != 0) try parts.append(c.gpa, osName(field(&u.sysname)));
    for (parts.items, 0..) |pt, i| {
        if (i > 0) try c.out.writeByte(' ');
        try c.out.writeAll(pt);
    }
    try c.out.writeByte('\n');
    return 0;
}
