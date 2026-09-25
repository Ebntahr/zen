const std = @import("std");
const c = @import("../common.zig");

pub const help =
    \\Usage: mkdir [OPTION]... DIRECTORY...
    \\Create the DIRECTORY(ies), if they do not already exist.
    \\
    \\  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask
    \\  -p, --parents     no error if existing, make parent directories as needed,
    \\                    with their file modes unaffected by any -m option
    \\  -v, --verbose     print a message for each created directory
    \\
;

var verbose = false;

fn created(path: []const u8) void {
    if (verbose) c.out.print("mkdir: created directory {f}\n", .{c.q(path)}) catch {};
}

fn mkParents(path: []const u8, parent_mode: u32) bool {
    // create each missing ancestor
    var i: usize = 0;
    while (i < path.len) {
        const next = std.mem.indexOfScalarPos(u8, path, i + 1, '/') orelse break;
        const prefix = path[0..next];
        i = next;
        if (prefix.len == 0) continue;
        if (c.sys.mkdir(prefix, parent_mode)) {
            created(prefix);
        } else |e| {
            if (e == error.EXIST) {
                const st = c.sys.stat(prefix) catch {
                    c.warn("cannot create directory {f}: {s}", .{ c.q(prefix), c.strerror(e) });
                    return false;
                };
                if (!st.isDir()) {
                    c.warn("cannot create directory {f}: {s}", .{ c.q(path), c.strerror(error.NOTDIR) });
                    return false;
                }
                continue;
            }
            c.warn("cannot create directory {f}: {s}", .{ c.q(prefix), c.strerror(e) });
            return false;
        }
    }
    return true;
}

pub fn main(args: c.Args) !u8 {
    var parents = false;
    var mode_spec: ?[]const u8 = null;
    var dirs: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{ .{ "mode", 'm' }, .{ "parents", 'p' }, .{ "verbose", 'v' }, .{ "context", 'Z' } });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'm' => mode_spec = p.arg(),
            'p' => parents = true,
            'v' => verbose = true,
            'Z' => {},
            else => p.bad(o),
        },
        .pos => |a| try dirs.append(c.gpa, a),
        else => p.bad(o),
    };
    if (dirs.items.len == 0) c.missingOperand();
    const um = c.sys.umask(0);
    _ = c.sys.umask(um);
    var mode: u32 = 0o777 & ~um;
    if (mode_spec) |ms| {
        mode = c.parseMode(ms, 0o777, true, um) orelse c.fatal("invalid mode {f}", .{c.q(ms)});
    }
    const parent_mode = (0o777 & ~um) | 0o300;
    var status: u8 = 0;
    for (dirs.items) |d| {
        if (parents) {
            if (!mkParents(d, parent_mode)) {
                status = 1;
                continue;
            }
        }
        c.sys.mkdir(d, mode) catch |e| {
            if (parents and e == error.EXIST) {
                if (c.sys.stat(d)) |st| {
                    if (st.isDir()) continue;
                } else |_| {}
            }
            c.warn("cannot create directory {f}: {s}", .{ c.q(d), c.strerror(e) });
            status = 1;
            continue;
        };
        if (mode_spec != null) c.sys.chmod(d, mode) catch {};
        created(d);
    }
    return status;
}
