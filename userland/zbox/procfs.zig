//! /proc helpers shared by ps, pidof, killall, uptime and free.
const std = @import("std");
const c = @import("common.zig");
const mem = std.mem;

pub const Proc = struct {
    pid: i32,
    ppid: i32 = 0,
    comm: []const u8 = "",
    state: u8 = '?',
    uid: u32 = 0,
    tty_nr: u32 = 0,
    utime: u64 = 0,
    stime: u64 = 0,
    starttime: u64 = 0,
    vsize: u64 = 0,
    rss_pages: u64 = 0,
    nice: i64 = 0,
    nthreads: u64 = 1,
    pgrp: i32 = 0,
    session: i32 = 0,
    tpgid: i32 = -1,
    flags: u64 = 0,
    priority: i64 = 20,
    vm_rss_kb: ?u64 = null,
    vm_lck_kb: u64 = 0,
    cmdline: []const u8 = "", // NUL separated
    exe: []const u8 = "",
};

pub fn listPids() []i32 {
    var list: std.ArrayList(i32) = .empty;
    const d = c.Dir.open("/proc") catch return list.items;
    defer d.close();
    while (d.next() catch null) |e| {
        const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
        list.append(c.gpa, pid) catch c.oom();
    }
    std.sort.insertion(i32, list.items, {}, std.sort.asc(i32));
    return list.items;
}

pub fn read(pid: i32) ?Proc {
    var p: Proc = .{ .pid = pid };
    var pb: [64]u8 = undefined;
    var buf: [4096]u8 = undefined;
    const stat = c.readSmall(c.fmtBuf(&pb, "/proc/{d}/stat", .{pid}), &buf);
    var have_stat = false;
    if (stat) |s| {
        const lp = mem.indexOfScalar(u8, s, '(');
        const rp = mem.lastIndexOfScalar(u8, s, ')');
        if (lp != null and rp != null and rp.? > lp.?) {
            p.comm = c.gpa.dupe(u8, s[lp.? + 1 .. rp.?]) catch c.oom();
            var it = mem.tokenizeScalar(u8, s[rp.? + 1 ..], ' ');
            var idx: usize = 3;
            while (it.next()) |f| : (idx += 1) {
                switch (idx) {
                    3 => p.state = if (f.len > 0) f[0] else '?',
                    4 => p.ppid = std.fmt.parseInt(i32, f, 10) catch 0,
                    5 => p.pgrp = std.fmt.parseInt(i32, f, 10) catch 0,
                    6 => p.session = std.fmt.parseInt(i32, f, 10) catch 0,
                    7 => p.tty_nr = @truncate(@as(u64, @bitCast(std.fmt.parseInt(i64, f, 10) catch 0))),
                    8 => p.tpgid = std.fmt.parseInt(i32, f, 10) catch -1,
                    9 => p.flags = c.parseUint(f) orelse 0,
                    18 => p.priority = c.parseInt(f) orelse 20,
                    14 => p.utime = c.parseUint(f) orelse 0,
                    15 => p.stime = c.parseUint(f) orelse 0,
                    19 => p.nice = c.parseInt(f) orelse 0,
                    20 => p.nthreads = c.parseUint(f) orelse 1,
                    22 => p.starttime = c.parseUint(f) orelse 0,
                    23 => p.vsize = c.parseUint(f) orelse 0,
                    24 => p.rss_pages = c.parseUint(f) orelse 0,
                    else => {},
                }
            }
            have_stat = true;
        }
    }
    var sbuf: [8192]u8 = undefined;
    if (c.readSmall(c.fmtBuf(&pb, "/proc/{d}/status", .{pid}), &sbuf)) |s| {
        var lines = mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[0..colon];
            const val = mem.trim(u8, line[colon + 1 ..], " \t");
            if (c.eql(key, "Uid")) {
                var it = mem.tokenizeAny(u8, val, " \t");
                _ = it.next();
                if (it.next()) |eu| p.uid = @intCast(c.parseUint(eu) orelse 0);
            } else if (!have_stat and c.eql(key, "Name")) {
                p.comm = c.gpa.dupe(u8, val) catch c.oom();
            } else if (!have_stat and c.eql(key, "State")) {
                p.state = if (val.len > 0) val[0] else '?';
            } else if (!have_stat and c.eql(key, "PPid")) {
                p.ppid = std.fmt.parseInt(i32, val, 10) catch 0;
            } else if (c.eql(key, "VmLck")) {
                p.vm_lck_kb = c.parseUint(mem.trimRight(u8, mem.trimRight(u8, val, "kB"), " ")) orelse 0;
            } else if (c.eql(key, "VmRSS")) {
                const kb = c.parseUint(mem.trimRight(u8, mem.trimRight(u8, val, "kB"), " ")) orelse 0;
                p.vm_rss_kb = kb;
                if (!have_stat) p.rss_pages = kb / 4;
            } else if (!have_stat and c.eql(key, "VmSize")) {
                const kb = c.parseUint(mem.trimRight(u8, mem.trimRight(u8, val, "kB"), " ")) orelse 0;
                p.vsize = kb * 1024;
            }
        }
    } else if (!have_stat) return null;
    var cbuf: [8192]u8 = undefined;
    if (c.readSmall(c.fmtBuf(&pb, "/proc/{d}/cmdline", .{pid}), &cbuf)) |cl| {
        var s = cl;
        while (s.len > 0 and s[s.len - 1] == 0) s = s[0 .. s.len - 1];
        p.cmdline = c.gpa.dupe(u8, s) catch c.oom();
    }
    return p;
}

/// argv[0] basename from cmdline, or comm.
pub fn progName(p: Proc) []const u8 {
    if (p.cmdline.len > 0) {
        const a0 = mem.sliceTo(p.cmdline, 0);
        const b = c.basename(a0);
        if (b.len > 0) return b;
    }
    return p.comm;
}

pub fn ttyName(buf: []u8, tty_nr: u32) []const u8 {
    if (tty_nr == 0) return "?";
    const major = (tty_nr >> 8) & 0xfff;
    const minor = (tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00);
    return switch (major) {
        136...143 => c.fmtBuf(buf, "pts/{d}", .{minor + (major - 136) * 256}),
        4 => if (minor < 64) c.fmtBuf(buf, "tty{d}", .{minor}) else c.fmtBuf(buf, "ttyS{d}", .{minor - 64}),
        5 => if (minor == 0) "tty" else if (minor == 1) "console" else "?",
        204 => c.fmtBuf(buf, "ttyAMA{d}", .{minor - 64}),
        229 => c.fmtBuf(buf, "hvc{d}", .{minor}),
        else => c.fmtBuf(buf, "{d},{d}", .{ major, minor }),
    };
}

pub fn uptimeSecs() f64 {
    var buf: [128]u8 = undefined;
    const s = c.readSmall("/proc/uptime", &buf) orelse return 0;
    var it = mem.tokenizeAny(u8, s, " \n");
    const f = it.next() orelse return 0;
    return std.fmt.parseFloat(f64, f) catch 0;
}

pub const MemInfo = struct {
    total: u64 = 0,
    free: u64 = 0,
    available: ?u64 = null,
    buffers: u64 = 0,
    cached: u64 = 0,
    sreclaimable: u64 = 0,
    shmem: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
};

pub fn memInfo() ?MemInfo {
    var buf: [8192]u8 = undefined;
    const s = c.readSmall("/proc/meminfo", &buf) orelse return null;
    var m: MemInfo = .{};
    var lines = mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var it = mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const v = c.parseUint(it.next() orelse continue) orelse continue;
        if (c.eql(key, "MemTotal")) m.total = v else if (c.eql(key, "MemFree")) m.free = v else if (c.eql(key, "MemAvailable")) m.available = v else if (c.eql(key, "Buffers")) m.buffers = v else if (c.eql(key, "Cached")) m.cached = v else if (c.eql(key, "SReclaimable")) m.sreclaimable = v else if (c.eql(key, "Shmem")) m.shmem = v else if (c.eql(key, "SwapTotal")) m.swap_total = v else if (c.eql(key, "SwapFree")) m.swap_free = v;
    }
    return m;
}

pub fn findByName(name: []const u8, exact_comm_only: bool) []i32 {
    var out: std.ArrayList(i32) = .empty;
    for (listPids()) |pid| {
        const p = read(pid) orelse continue;
        if (c.eql(p.comm, name) or (!exact_comm_only and c.eql(progName(p), name))) {
            out.append(c.gpa, pid) catch c.oom();
        } else if (p.cmdline.len > 0 and !exact_comm_only) {
            // scripts: "sh script" -> match script basename
            const a0 = mem.sliceTo(p.cmdline, 0);
            if (c.eql(a0, name)) out.append(c.gpa, pid) catch c.oom();
        }
    }
    return out.items;
}
