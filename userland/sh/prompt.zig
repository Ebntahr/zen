//! Prompt rendering (PS1/PS2/PS4) with bash-style backslash escapes and
//! parameter/command expansion.
//!
//! Supported escapes: \u \h \H \w \W \$ \n \r \a \e \033 \\ \[ \] \j \s \v
//! \V \t \T \A \@ \d \? \# \! and the zensh extension \z, which expands to
//! a green colour code when the last command succeeded and red otherwise.
const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const parser = @import("parser.zig");
const expand = @import("expand.zig");
const Shell = shell.Shell;

pub const default_ps1 = "\\[\\e[36m\\]\\u@\\h\\[\\e[0m\\] \\[\\e[1;34m\\]\\w\\[\\e[0m\\] \\z❯\\[\\e[0m\\] ";

var user_buf: [64]u8 = undefined;
var user: []const u8 = "";
var host_buf: [65]u8 = undefined;
var host: []const u8 = "";
pub var command_number: usize = 1;

pub fn initIdentity(sh: *Shell) void {
    const u = sh.userName(&user_buf);
    if (u.ptr != &user_buf) {
        const n = @min(u.len, user_buf.len);
        @memcpy(user_buf[0..n], u[0..n]);
        user = user_buf[0..n];
    } else user = u;
    host = sys.hostname(&host_buf);
}

fn civil(days_in: i64) struct { y: i64, m: u32, d: u32 } {
    // days since 1970-01-01 -> y/m/d (Howard Hinnant's algorithm)
    const z = days_in + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// Render the working directory with $HOME abbreviated to ~.
pub fn prettyCwd(sh: *Shell, a: std.mem.Allocator, base_only: bool) []const u8 {
    const pwd = sh.getVar("PWD") orelse blk: {
        const b = a.alloc(u8, sys.PATH_MAX) catch return "?";
        break :blk sys.getcwd(b) catch "?";
    };
    const home = sh.getVar("HOME") orelse "";
    if (home.len > 1 and std.mem.startsWith(u8, pwd, home) and (pwd.len == home.len or pwd[home.len] == '/')) {
        if (base_only and pwd.len == home.len) return "~";
        if (!base_only) return std.mem.concat(a, u8, &.{ "~", pwd[home.len..] }) catch pwd;
    }
    if (base_only) {
        if (std.mem.eql(u8, pwd, "/")) return "/";
        const t = std.mem.trimRight(u8, pwd, "/");
        if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| return t[i + 1 ..];
        return t;
    }
    return pwd;
}

pub fn render(sh: *Shell, ps: []const u8) []const u8 {
    const a = sh.scratchAlloc();
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const now = sys.now();
    const secs = now.sec;
    const day_secs: i64 = @mod(secs, 86400);
    const hh: u64 = @intCast(@divFloor(day_secs, 3600));
    const mm: u64 = @intCast(@divFloor(@mod(day_secs, 3600), 60));
    const ss: u64 = @intCast(@mod(day_secs, 60));
    while (i < ps.len) : (i += 1) {
        const c = ps[i];
        if (c != '\\' or i + 1 >= ps.len) {
            out.append(a, c) catch return ps;
            continue;
        }
        i += 1;
        const e = ps[i];
        const piece: []const u8 = switch (e) {
            'u' => user,
            'h' => host[0 .. std.mem.indexOfScalar(u8, host, '.') orelse host.len],
            'H' => host,
            'w' => prettyCwd(sh, a, false),
            'W' => prettyCwd(sh, a, true),
            '$' => if (sys.geteuid() == 0) "#" else "$",
            'n' => "\n",
            'r' => "\r",
            'a' => "\x07",
            'e' => "\x1b",
            '\\' => "\\",
            '[' => "\x01",
            ']' => "\x02",
            's' => "zensh",
            'v', 'V' => shell.version,
            'j' => std.fmt.allocPrint(a, "{d}", .{sh.jobs.list.items.len}) catch "",
            '?' => std.fmt.allocPrint(a, "{d}", .{sh.last_status}) catch "",
            '#' => std.fmt.allocPrint(a, "{d}", .{command_number}) catch "",
            '!' => std.fmt.allocPrint(a, "{d}", .{sh.hist.base + sh.hist.len() + 1}) catch "",
            't' => std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch "",
            'T' => std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ if (hh % 12 == 0) 12 else hh % 12, mm, ss }) catch "",
            'A' => std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch "",
            '@' => std.fmt.allocPrint(a, "{d:0>2}:{d:0>2} {s}", .{ if (hh % 12 == 0) 12 else hh % 12, mm, if (hh < 12) "AM" else "PM" }) catch "",
            'd' => blk: {
                const days = @divFloor(secs, 86400);
                const wd = @as(usize, @intCast(@mod(days + 4, 7)));
                const cv = civil(days);
                const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
                const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
                break :blk std.fmt.allocPrint(a, "{s} {s} {d:0>2}", .{ wdays[wd], months[cv.m - 1], cv.d }) catch "";
            },
            'z' => if (sh.last_status == 0) "\x01\x1b[1;32m\x02" else "\x01\x1b[1;31m\x02",
            '0'...'7' => blk: {
                var v: u32 = 0;
                var k: usize = 0;
                while (k < 3 and i < ps.len and ps[i] >= '0' and ps[i] <= '7') : (k += 1) {
                    v = v * 8 + (ps[i] - '0');
                    i += 1;
                }
                i -= 1;
                const byte = a.alloc(u8, 1) catch break :blk "";
                byte[0] = @truncate(v);
                break :blk byte;
            },
            else => std.fmt.allocPrint(a, "\\{c}", .{e}) catch "",
        };
        out.appendSlice(a, piece) catch return ps;
    }
    var s: []const u8 = out.items;
    if (std.mem.indexOfAny(u8, s, "$`") != null) {
        // parameter expansion / command substitution in prompts
        const parts = parser.parseHeredocText(a, sh.gpa, s) catch return s;
        const saved = sh.last_status;
        const saved_cs = sh.cmdsub_status;
        s = expand.heredocToString(sh, .{ .parts = parts }) catch s;
        sh.last_status = saved;
        sh.cmdsub_status = saved_cs;
    }
    return s;
}
