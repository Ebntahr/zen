//! A realistic zensh session used for host previews and screenshots:
//! the default zensh prompt, `ls --color`, `cat sys:uname` and a
//! neofetch-style `zenfetch` with the Zen ensō drawn in half blocks.

const std = @import("std");

const prompt = "\x1b[36mzen@zen-os\x1b[0m \x1b[1;34m~\x1b[0m \x1b[1;32m❯\x1b[0m ";

/// zensh highlights commands green and options blue while typing.
fn command(out: *std.ArrayList(u8), a: std.mem.Allocator, cmd: []const u8, args: []const u8) !void {
    try out.appendSlice(a, prompt);
    try out.print(a, "\x1b[32m{s}\x1b[0m", .{cmd});
    if (args.len > 0) {
        const color = if (args[0] == '-') "\x1b[34m" else "";
        try out.print(a, " {s}{s}\x1b[0m", .{ color, args });
    }
    try out.appendSlice(a, "\r\n");
}

const Pixel = struct { on: bool, t: f32 };

/// The ensō: one brush stroke circling counterclockwise from about one
/// o'clock, landing thick and drying out into a thin tail that drifts
/// slightly inward, leaving a small gap at the upper right.
/// Pixels are quadrant blocks: 2x2 per cell, each ~3.9x8.5 px.
fn ensoPixel(px: usize, py: usize, w: usize, h: usize) Pixel {
    const sx: f32 = 3.9;
    const sy: f32 = 8.5;
    const x = (@as(f32, @floatFromInt(px)) + 0.5) * sx;
    const y = (@as(f32, @floatFromInt(py)) + 0.5) * sy;
    const cx = @as(f32, @floatFromInt(w)) * sx / 2;
    const cy = @as(f32, @floatFromInt(h)) * sy / 2;
    const dx = x - cx;
    const dy = cy - y;
    const d = @sqrt(dx * dx + dy * dy);
    var ang = std.math.atan2(dy, dx) * 180 / std.math.pi; // counterclockwise from +x
    if (ang < 0) ang += 360;
    const start: f32 = 68;
    const sweep: f32 = 328;
    var rel = ang - start;
    if (rel < 0) rel += 360;
    const u = rel / sweep;
    if (u > 1) return .{ .on = false, .t = 0 };
    const r_base = @min(cx, cy) * 0.78;
    const radius = r_base * (1 + 0.03 * @sin(u * std.math.pi * 2) - 0.07 * u * u);
    const tail = std.math.clamp((u - 0.70) / 0.30, 0, 1);
    const land = std.math.clamp(u / 0.08, 0, 1);
    const thick = r_base * 0.34 * (0.80 + 0.20 * @sin(u * std.math.pi)) * (1 - 0.82 * tail * tail) * (0.70 + 0.30 * land);
    return .{ .on = @abs(d - radius) <= thick / 2, .t = u };
}

fn gradient(t: f32) [3]u8 {
    const stops = [_][3]f32{
        .{ 0x64, 0xD2, 0xFF },
        .{ 0x0A, 0x84, 0xFF },
        .{ 0x7D, 0x5C, 0xF6 },
        .{ 0xBF, 0x5A, 0xF2 },
    };
    const f = std.math.clamp(t, 0, 1) * @as(f32, stops.len - 1);
    const i: usize = @min(@as(usize, @intFromFloat(f)), stops.len - 2);
    const k = f - @as(f32, @floatFromInt(i));
    var out: [3]u8 = undefined;
    for (0..3) |c| out[c] = @intFromFloat(stops[i][c] + (stops[i + 1][c] - stops[i][c]) * k);
    return out;
}

const logo_w = 26;
const logo_h = 12;

/// Quadrant block characters indexed by bits UL=1, UR=2, LL=4, LR=8.
const quadrants = [16][]const u8{ " ", "▘", "▝", "▀", "▖", "▌", "▞", "▛", "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█" };

fn logoRow(out: *std.ArrayList(u8), a: std.mem.Allocator, row: usize) !void {
    for (0..logo_w) |col| {
        var bits: usize = 0;
        var t_sum: f32 = 0;
        var count: f32 = 0;
        for (0..4) |q| {
            const p = ensoPixel(col * 2 + q % 2, row * 2 + q / 2, logo_w * 2, logo_h * 2);
            if (p.on) {
                bits |= @as(usize, 1) << @intCast(q);
                t_sum += p.t;
                count += 1;
            }
        }
        if (bits == 0) {
            try out.append(a, ' ');
            continue;
        }
        const c = gradient(t_sum / count);
        try out.print(a, "\x1b[38;2;{d};{d};{d}m{s}", .{ c[0], c[1], c[2], quadrants[bits] });
    }
    try out.appendSlice(a, "\x1b[0m");
}

/// Build the session transcript (pty output). Caller frees.
pub fn build(a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    try out.appendSlice(a, "\x1b]0;zen@zen-os: ~\x07");
    try out.appendSlice(a, "Last login: Thu Sep 25 09:41:07 on pty:0\r\n");

    try command(&out, a, "ls", "--color");
    const d = "\x1b[01;34m";
    const x = "\x1b[01;32m";
    const r = "\x1b[0m";
    try out.print(a, "{s}Applications{s}  {s}Documents{s}  {s}Library{s}  {s}Music{s}     {s}Public{s}     {s}zen-install{s}\r\n", .{ d, r, d, r, d, r, d, r, d, r, x, r });
    try out.print(a, "{s}Desktop{s}       {s}Downloads{s}  {s}Movies{s}   {s}Pictures{s}  hello.zig\r\n", .{ d, r, d, r, d, r, d, r });

    try command(&out, a, "cat", "sys:uname");
    try out.appendSlice(a, "Zen zen-os 1.0 Golden Gate riscv64\r\n");

    try command(&out, a, "zenfetch", "");
    const k = "\x1b[1;34m"; // key color
    const info = [_][]const u8{
        "\x1b[1;36mzen\x1b[0m@\x1b[1;36mzen-os\x1b[0m",
        "----------",
        k ++ "OS" ++ r ++ ": Zen OS 1.0 Golden Gate riscv64",
        k ++ "Host" ++ r ++ ": QEMU RISC-V virt",
        k ++ "Kernel" ++ r ++ ": Zen microkernel",
        k ++ "Uptime" ++ r ++ ": 2 hours, 14 mins",
        k ++ "Packages" ++ r ++ ": 58 (zbox)",
        k ++ "Shell" ++ r ++ ": zensh",
        k ++ "Resolution" ++ r ++ ": 1280x800",
        k ++ "DE" ++ r ++ ": Zen Desktop (Liquid Glass)",
        k ++ "Terminal" ++ r ++ ": Terminal",
        k ++ "CPU" ++ r ++ ": RISC-V rv64gc (4) @ 1.0GHz",
        k ++ "Memory" ++ r ++ ": 318MiB / 2048MiB",
        "",
        "", // palette rows are generated below
        "",
    };
    const logo_top = 1; // vertically center the logo against the info
    for (info, 0..) |line, i| {
        try out.appendSlice(a, " ");
        if (i >= logo_top and i < logo_top + logo_h) {
            try logoRow(&out, a, i - logo_top);
        } else {
            try out.appendNTimes(a, ' ', logo_w);
        }
        try out.appendSlice(a, "   ");
        if (i == info.len - 2 or i == info.len - 1) {
            const base: u8 = if (i == info.len - 2) 30 else 90;
            for (0..8) |c| try out.print(a, "\x1b[{d}m███", .{base + c});
            try out.appendSlice(a, r);
        } else {
            try out.appendSlice(a, line);
        }
        try out.appendSlice(a, "\r\n");
    }
    try out.appendSlice(a, "\r\n");
    try out.appendSlice(a, prompt);
    return out.toOwnedSlice(a);
}

test "demo session builds" {
    const s = try build(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Zen OS 1.0 Golden Gate riscv64") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "█") != null);
}
