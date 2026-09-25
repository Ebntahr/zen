//! zenfetch — system information with the Zen ensō logo.

const std = @import("std");

const logo = [_][]const u8{
    "        .=+*#%%%%#*+=.     ",
    "     .+%%%%%%%%%%%%%%%%*   ",
    "   .*%%%%*=:.    .:=*%%%*. ",
    "  =%%%%-              -%%: ",
    " +%%%*                  .  ",
    ".%%%%.                     ",
    "=%%%#                      ",
    "+%%%*                   .  ",
    "=%%%#                  +%= ",
    ".%%%%:                =%%% ",
    " +%%%%-             .*%%%+ ",
    "  =%%%%%+-.     .:=#%%%%=  ",
    "   .+%%%%%%%%%%%%%%%%%+.   ",
    "      :=*#%%%%%%%#*=:      ",
};

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch null;
}

fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, key)) {
            return std.mem.trim(u8, l[key.len..], " \t:=\"");
        }
    }
    return null;
}

fn meminfoKb(text: []const u8, key: []const u8) u64 {
    const v = field(text, key) orelse return 0;
    var it = std.mem.tokenizeScalar(u8, v, ' ');
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    var uts: std.posix.utsname = undefined;
    uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    const machine = std.mem.sliceTo(&uts.machine, 0);
    const host = std.mem.sliceTo(&uts.nodename, 0);
    const user = std.posix.getenv("USER") orelse "zen";

    const os_release = readFile(a, "/etc/zen-release") orelse readFile(a, "/etc/os-release") orelse "";
    const pretty = field(os_release, "PRETTY_NAME") orelse "Zen OS";
    const shell = std.fs.path.basename(std.posix.getenv("SHELL") orelse "/bin/zensh");
    const term = std.posix.getenv("TERM_PROGRAM") orelse std.posix.getenv("TERM") orelse "Terminal";

    var uptime_s: u64 = 0;
    if (readFile(a, "/proc/uptime")) |u| {
        var it = std.mem.tokenizeAny(u8, u, " .");
        uptime_s = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    }
    var mem_total: u64 = 0;
    var mem_used: u64 = 0;
    if (readFile(a, "/proc/meminfo")) |m| {
        mem_total = meminfoKb(m, "MemTotal");
        const avail = meminfoKb(m, "MemAvailable");
        mem_used = mem_total -| avail;
    }
    var cpus: usize = 1;
    if (readFile(a, "/proc/cpuinfo")) |c| {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, c, '\n');
        while (lines.next()) |l| if (std.mem.startsWith(u8, l, "processor")) {
            n += 1;
        };
        if (n > 0) cpus = n;
    }

    var info: std.ArrayList([]const u8) = .empty;
    try info.append(a, try std.fmt.allocPrint(a, "\x1b[1;36m{s}\x1b[0m@\x1b[1;36m{s}\x1b[0m", .{ user, host }));
    try info.append(a, "\x1b[2m-----------------\x1b[0m");
    const rows = [_]struct { []const u8, []const u8 }{
        .{ "OS", try std.fmt.allocPrint(a, "{s} {s}", .{ pretty, machine }) },
        .{ "Kernel", try std.fmt.allocPrint(a, "{s} {s}", .{ sysname, release }) },
        .{ "Uptime", try std.fmt.allocPrint(a, "{d} h, {d} min", .{ uptime_s / 3600, (uptime_s / 60) % 60 }) },
        .{ "Shell", shell },
        .{ "DE", "Zen Desktop (Liquid Glass)" },
        .{ "Terminal", term },
        .{ "CPU", try std.fmt.allocPrint(a, "{s} ({d})", .{ if (std.mem.startsWith(u8, machine, "riscv")) "RISC-V RV64GC" else machine, cpus }) },
        .{ "Memory", try std.fmt.allocPrint(a, "{d} MiB / {d} MiB", .{ mem_used / 1024, mem_total / 1024 }) },
    };
    for (rows) |r| try info.append(a, try std.fmt.allocPrint(a, "\x1b[1;34m{s}\x1b[0m: {s}", .{ r[0], r[1] }));
    try info.append(a, "");
    try info.append(a, "\x1b[40m   \x1b[41m   \x1b[42m   \x1b[43m   \x1b[44m   \x1b[45m   \x1b[46m   \x1b[47m   \x1b[0m");
    try info.append(a, "\x1b[100m   \x1b[101m   \x1b[102m   \x1b[103m   \x1b[104m   \x1b[105m   \x1b[106m   \x1b[107m   \x1b[0m");

    const n = @max(logo.len, info.items.len);
    for (0..n) |i| {
        // Gradient from blue to purple down the logo.
        const color: []const u8 = if (i < 5) "\x1b[38;5;39m" else if (i < 10) "\x1b[38;5;63m" else "\x1b[38;5;135m";
        if (i < logo.len) try out.print("{s}{s}\x1b[0m  ", .{ color, logo[i] }) else try out.print("{s}  ", .{" " ** 28});
        if (i < info.items.len) try out.writeAll(info.items[i]);
        try out.writeAll("\n");
    }
    try out.flush();
}
