const c = @import("../common.zig");

pub const help =
    \\Usage: true [ignored command line arguments]
    \\Exit with a status code indicating success.
    \\
;
pub const help_false =
    \\Usage: false [ignored command line arguments]
    \\Exit with a status code indicating failure.
    \\
;

pub fn main(args: c.Args) !u8 {
    if (args.len == 2) {
        if (c.eql(args[1], "--help")) c.printHelp();
        if (c.eql(args[1], "--version")) c.printVersion();
    }
    return 0;
}

pub fn mainFalse(args: c.Args) !u8 {
    if (args.len == 2) {
        if (c.eql(args[1], "--help")) {
            try c.out.writeAll(help_false);
            c.exit(1);
        }
        if (c.eql(args[1], "--version")) {
            try c.out.print("false (zbox) {s}\n", .{c.version});
            c.exit(1);
        }
    }
    return 1;
}
