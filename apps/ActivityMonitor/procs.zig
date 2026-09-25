//! Process and system statistics for Activity Monitor.
//!
//! On Zen the process table comes from the `proc_list` / `proc_info`
//! system calls (`zen.sys`); on a Linux development host (or if those fail)
//! it is read from /proc/<pid>/{stat,status,cmdline,io}. System-wide CPU
//! and memory figures come from /proc/stat and /proc/meminfo (`sys:proc/…`
//! on Zen, with `sys:meminfo` as an alternative) and fall back to totals of
//! the per-process numbers.
//!
//! `Sampler.refresh` is meant to run every couple of seconds; it reuses its
//! buffers so steady-state refreshes do not allocate.

const std = @import("std");
const abi = @import("abi");
const zen = @import("zen");

pub const history_len = 60;

pub const Proc = struct {
    pid: u32,
    ppid: u32 = 0,
    uid: u32 = 0,
    name_buf: [48]u8 = undefined,
    name_len: u8 = 0,
    user_buf: [24]u8 = undefined,
    user_len: u8 = 0,
    /// 'R' running, 'S' sleeping, 'T' stopped, 'Z' zombie, 'I' idle.
    state: u8 = 'S',
    threads: u32 = 1,
    /// Resident memory in bytes.
    rss: u64 = 0,
    /// Virtual size in bytes.
    vsize: u64 = 0,
    /// Total CPU time in nanoseconds.
    cpu_ns: u64 = 0,
    /// Start time in nanoseconds since boot.
    start_ns: u64 = 0,
    /// CPU usage over the last interval (100 = one core).
    cpu_pct: f32 = 0,
    sandboxed: bool = false,
    nice: i32 = 0,
    /// Bytes read from / written to storage (null when unknown).
    disk_read: ?u64 = null,
    disk_write: ?u64 = null,

    pub fn name(self: *const Proc) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn user(self: *const Proc) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn setName(self: *Proc, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn setUser(self: *Proc, s: []const u8) void {
        const n = @min(s.len, self.user_buf.len);
        @memcpy(self.user_buf[0..n], s[0..n]);
        self.user_len = @intCast(n);
    }

    pub fn stateName(self: *const Proc) []const u8 {
        return switch (self.state) {
            'R' => "Running",
            'S', 'D', 'I' => "Sleeping",
            'T', 't' => "Stopped",
            'Z' => "Zombie",
            else => "Unknown",
        };
    }
};

pub const MemInfo = struct {
    total: u64 = 0,
    free: u64 = 0,
    available: u64 = 0,
    cached: u64 = 0,
    buffers: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    valid: bool = false,

    pub fn used(self: MemInfo) u64 {
        return self.total -| self.available;
    }

    /// 0..1 fraction of memory that is in use and not reclaimable.
    pub fn pressure(self: MemInfo) f32 {
        if (!self.valid or self.total == 0) return 0;
        const u: f64 = @floatFromInt(self.used());
        const t: f64 = @floatFromInt(self.total);
        return @floatCast(std.math.clamp(u / t, 0, 1));
    }
};

pub const CpuTimes = struct {
    user: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,

    fn total(self: CpuTimes) u64 {
        return self.user + self.system + self.idle;
    }
};

/// Fixed-size ring of the most recent samples (oldest first via `get`).
pub const History = struct {
    vals: [history_len]f32 = [_]f32{0} ** history_len,
    len: usize = 0,
    head: usize = 0,

    pub fn push(self: *History, v: f32) void {
        self.vals[self.head] = v;
        self.head = (self.head + 1) % history_len;
        if (self.len < history_len) self.len += 1;
    }

    /// i = 0 is the oldest retained sample.
    pub fn get(self: *const History, i: usize) f32 {
        const start = (self.head + history_len - self.len) % history_len;
        return self.vals[(start + i) % history_len];
    }

    pub fn last(self: *const History) f32 {
        if (self.len == 0) return 0;
        return self.get(self.len - 1);
    }
};

pub const Totals = struct {
    /// Percent of total CPU capacity (0..100).
    user_pct: f32 = 0,
    system_pct: f32 = 0,
    idle_pct: f32 = 100,
    processes: u32 = 0,
    threads: u32 = 0,
    ncpu: u32 = 1,
    mem: MemInfo = .{},
    disk_read: u64 = 0,
    disk_write: u64 = 0,
    /// Bytes per second over the last interval.
    disk_read_rate: f64 = 0,
    disk_write_rate: f64 = 0,
    uptime_ns: u64 = 0,
    /// Sum of resident memory (used when /proc/meminfo is unavailable).
    rss_total: u64 = 0,
};

const PrevSample = struct {
    pid: u32,
    cpu_ns: u64,
    start_ns: u64,
};

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    procs: std.ArrayList(Proc) = .empty,
    prev: std.ArrayList(PrevSample) = .empty,
    prev_time_ns: u64 = 0,
    prev_cpu: ?CpuTimes = null,
    prev_disk: ?[2]u64 = null,
    totals: Totals = .{},
    cpu_user_hist: History = .{},
    cpu_system_hist: History = .{},
    mem_hist: History = .{},
    disk_read_hist: History = .{},
    disk_write_hist: History = .{},
    users: ?zen.users.Db = null,
    on_zen: bool = false,
    pid_buf: []u32 = &.{},
    samples: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Sampler {
        var s = Sampler{ .allocator = allocator };
        s.on_zen = zen.sys.isZen();
        s.users = zen.users.Db.load(allocator, "/") catch null;
        s.totals.ncpu = @intCast(@max(1, std.Thread.getCpuCount() catch 1));
        return s;
    }

    pub fn deinit(self: *Sampler) void {
        self.procs.deinit(self.allocator);
        self.prev.deinit(self.allocator);
        if (self.users) |*u| u.deinit();
        if (self.pid_buf.len > 0) self.allocator.free(self.pid_buf);
    }

    pub fn find(self: *const Sampler, pid: u32) ?*const Proc {
        for (self.procs.items) |*p| {
            if (p.pid == pid) return p;
        }
        return null;
    }

    /// Take a new sample of every process and the system totals.
    pub fn refresh(self: *Sampler) void {
        const now = monotonicNs();
        // Remember the previous CPU times (sorted by pid).
        self.prev.clearRetainingCapacity();
        for (self.procs.items) |p| {
            self.prev.append(self.allocator, .{ .pid = p.pid, .cpu_ns = p.cpu_ns, .start_ns = p.start_ns }) catch break;
        }
        std.mem.sort(PrevSample, self.prev.items, {}, struct {
            fn lt(_: void, a: PrevSample, b: PrevSample) bool {
                return a.pid < b.pid;
            }
        }.lt);

        self.procs.clearRetainingCapacity();
        var ok = false;
        if (self.on_zen) ok = self.collectZen();
        if (!ok) self.collectProcfs();
        self.totals.uptime_ns = uptimeNs(now);

        // Per-process CPU usage from the deltas.
        const dt = if (self.prev_time_ns > 0 and now > self.prev_time_ns) now - self.prev_time_ns else 0;
        var sum_all: f64 = 0;
        var sum_root: f64 = 0;
        var threads: u32 = 0;
        var dr: u64 = 0;
        var dw: u64 = 0;
        for (self.procs.items) |*p| {
            if (dt > 0) {
                if (self.prevOf(p.pid)) |pv| {
                    if (pv.start_ns == p.start_ns and p.cpu_ns >= pv.cpu_ns) {
                        const d: f64 = @floatFromInt(p.cpu_ns - pv.cpu_ns);
                        p.cpu_pct = @floatCast(d * 100.0 / @as(f64, @floatFromInt(dt)));
                    }
                }
            }
            sum_all += p.cpu_pct;
            if (p.uid == 0) sum_root += p.cpu_pct;
            threads += p.threads;
            dr += p.disk_read orelse 0;
            dw += p.disk_write orelse 0;
            self.resolveUser(p);
        }
        self.totals.processes = @intCast(self.procs.items.len);
        self.totals.threads = threads;
        self.totals.disk_read = dr;
        self.totals.disk_write = dw;
        if (self.prev_disk) |pd| {
            if (dt > 0) {
                const secs = @as(f64, @floatFromInt(dt)) / 1e9;
                self.totals.disk_read_rate = @as(f64, @floatFromInt(dr -| pd[0])) / secs;
                self.totals.disk_write_rate = @as(f64, @floatFromInt(dw -| pd[1])) / secs;
            }
        }
        self.prev_disk = .{ dr, dw };

        // System-wide CPU split.
        const ncpu: f64 = @floatFromInt(self.totals.ncpu);
        if (readCpuTimes()) |ct| {
            if (self.prev_cpu) |pc| {
                const tot = ct.total() -| pc.total();
                if (tot > 0) {
                    const t: f64 = @floatFromInt(tot);
                    self.totals.user_pct = @floatCast(@as(f64, @floatFromInt(ct.user -| pc.user)) * 100 / t);
                    self.totals.system_pct = @floatCast(@as(f64, @floatFromInt(ct.system -| pc.system)) * 100 / t);
                }
            }
            self.prev_cpu = ct;
        } else if (dt > 0) {
            // No /proc/stat: attribute root processes to "System".
            self.totals.system_pct = @floatCast(@min(100, sum_root / ncpu));
            self.totals.user_pct = @floatCast(@min(100 - sum_root / ncpu, (sum_all - sum_root) / ncpu));
        }
        self.totals.idle_pct = @max(0, 100 - self.totals.user_pct - self.totals.system_pct);

        self.totals.mem = readMemInfo();
        var rss: u64 = 0;
        for (self.procs.items) |p| rss += p.rss;
        self.totals.rss_total = rss;

        if (self.samples > 0) {
            self.cpu_user_hist.push(self.totals.user_pct);
            self.cpu_system_hist.push(self.totals.system_pct);
            self.disk_read_hist.push(@floatCast(self.totals.disk_read_rate));
            self.disk_write_hist.push(@floatCast(self.totals.disk_write_rate));
        }
        self.mem_hist.push(self.totals.mem.pressure());
        self.prev_time_ns = now;
        self.samples += 1;
    }

    fn prevOf(self: *const Sampler, pid: u32) ?PrevSample {
        const items = self.prev.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid].pid == pid) return items[mid];
            if (items[mid].pid < pid) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn resolveUser(self: *const Sampler, p: *Proc) void {
        if (self.users) |*db| {
            if (db.userById(p.uid)) |u| {
                p.setUser(u.name);
                return;
            }
        }
        if (p.uid == 0) {
            p.setUser("root");
            return;
        }
        var b: [16]u8 = undefined;
        p.setUser(std.fmt.bufPrint(&b, "{d}", .{p.uid}) catch "?");
    }

    fn collectZen(self: *Sampler) bool {
        if (self.pid_buf.len == 0) {
            self.pid_buf = self.allocator.alloc(u32, 1024) catch return false;
        }
        const pids = zen.sys.procList(self.pid_buf) catch return false;
        for (pids) |pid| {
            const info = zen.sys.procInfo(pid) catch continue;
            var p = Proc{ .pid = info.pid };
            p.ppid = info.ppid;
            p.uid = info.uid;
            p.setName(std.mem.sliceTo(&info.name, 0));
            if (p.name_len == 0) p.setName(std.fs.path.basename(std.mem.sliceTo(&info.exe, 0)));
            p.state = switch (info.state) {
                .running => 'R',
                .sleeping => 'S',
                .stopped => 'T',
                .zombie => 'Z',
            };
            p.threads = info.threads;
            p.rss = info.rss;
            p.vsize = info.vsize;
            p.cpu_ns = info.cpu_ns;
            p.start_ns = info.start_ns;
            p.sandboxed = info.sandboxed != 0;
            p.nice = info.nice;
            self.procs.append(self.allocator, p) catch break;
        }
        return self.procs.items.len > 0;
    }

    fn collectProcfs(self: *Sampler) void {
        var dir = std.fs.cwd().openDir("/proc", .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            const pid = std.fmt.parseInt(u32, e.name, 10) catch continue;
            var p = Proc{ .pid = pid };
            if (!readProcfs(pid, &p)) continue;
            self.procs.append(self.allocator, p) catch break;
        }
    }
};

fn monotonicNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn uptimeNs(mono: u64) u64 {
    var buf: [128]u8 = undefined;
    if (readSmall("/proc/uptime", &buf)) |s| {
        var it = std.mem.tokenizeAny(u8, s, " \n");
        if (it.next()) |f| {
            const secs = std.fmt.parseFloat(f64, f) catch return mono;
            return @intFromFloat(secs * 1e9);
        }
    }
    // Zen's monotonic clock starts at boot.
    return mono;
}

/// Read a small file into `buf` (no allocation). Null on error. Uses raw
/// system calls so that expected failures (EACCES on another user's
/// /proc/<pid>/io, vanished processes) stay quiet.
pub fn readSmall(path: []const u8, buf: []u8) ?[]u8 {
    const linux = std.os.linux;
    var zbuf: [256]u8 = undefined;
    if (path.len >= zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const rc = linux.open(@ptrCast(&zbuf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.E.init(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.E.init(r) != .SUCCESS) return null;
        if (r == 0) break;
        n += r;
    }
    return buf[0..n];
}

const clk_tck: u64 = 100;
const ns_per_tick: u64 = std.time.ns_per_s / clk_tck;
const page_size: u64 = 4096;

/// Parse the fields of /proc/<pid>/stat that Activity Monitor needs.
pub fn parseStat(s: []const u8, p: *Proc) bool {
    const lp = std.mem.indexOfScalar(u8, s, '(') orelse return false;
    const rp = std.mem.lastIndexOfScalar(u8, s, ')') orelse return false;
    if (rp < lp) return false;
    p.setName(s[lp + 1 .. rp]);
    var it = std.mem.tokenizeScalar(u8, s[rp + 1 ..], ' ');
    var idx: usize = 3;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (it.next()) |f| : (idx += 1) {
        switch (idx) {
            3 => p.state = if (f.len > 0) f[0] else '?',
            4 => p.ppid = std.fmt.parseInt(u32, f, 10) catch 0,
            14 => utime = std.fmt.parseInt(u64, f, 10) catch 0,
            15 => stime = std.fmt.parseInt(u64, f, 10) catch 0,
            19 => p.nice = std.fmt.parseInt(i32, f, 10) catch 0,
            20 => p.threads = std.fmt.parseInt(u32, f, 10) catch 1,
            22 => p.start_ns = (std.fmt.parseInt(u64, f, 10) catch 0) * ns_per_tick,
            23 => p.vsize = std.fmt.parseInt(u64, f, 10) catch 0,
            24 => p.rss = (std.fmt.parseInt(u64, std.mem.trimRight(u8, f, "\n"), 10) catch 0) * page_size,
            else => {},
        }
        if (idx > 24) break;
    }
    p.cpu_ns = (utime + stime) * ns_per_tick;
    return true;
}

/// Real uid from /proc/<pid>/status ("Uid:\t1000\t1000\t…").
pub fn parseStatusUid(s: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Uid:")) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        const f = it.next() orelse return null;
        return std.fmt.parseInt(u32, f, 10) catch null;
    }
    return null;
}

fn readProcfs(pid: u32, p: *Proc) bool {
    var pb: [64]u8 = undefined;
    var buf: [2048]u8 = undefined;
    const stat = readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/stat", .{pid}) catch return false, &buf) orelse return false;
    if (!parseStat(stat, p)) return false;
    var sbuf: [4096]u8 = undefined;
    if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/status", .{pid}) catch return false, &sbuf)) |s| {
        if (parseStatusUid(s)) |uid| p.uid = uid;
        // Linux has no sandbox flag; seccomp filtering is the closest thing.
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Seccomp:")) {
                p.sandboxed = std.mem.indexOfAny(u8, line[8..], "12") != null;
            }
        }
    }
    // The kernel truncates comm to 15 bytes; prefer argv[0]'s basename.
    if (p.name_len >= 15) {
        var cbuf: [512]u8 = undefined;
        if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/cmdline", .{pid}) catch return true, &cbuf)) |cl| {
            const a0 = std.fs.path.basename(std.mem.sliceTo(cl, 0));
            if (a0.len > p.name_len and std.mem.startsWith(u8, a0, p.name())) p.setName(a0);
        }
    }
    var ibuf: [512]u8 = undefined;
    if (readSmall(std.fmt.bufPrint(&pb, "/proc/{d}/io", .{pid}) catch return true, &ibuf)) |io| {
        var lines = std.mem.splitScalar(u8, io, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const v = std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch continue;
            if (std.mem.eql(u8, line[0..colon], "read_bytes")) p.disk_read = v;
            if (std.mem.eql(u8, line[0..colon], "write_bytes")) p.disk_write = v;
        }
    }
    return true;
}

/// Aggregate CPU times from the "cpu " line of /proc/stat.
pub fn parseCpuTimes(s: []const u8) ?CpuTimes {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
        var v: [8]u64 = [_]u64{0} ** 8;
        var i: usize = 0;
        while (it.next()) |f| : (i += 1) {
            if (i >= v.len) break;
            v[i] = std.fmt.parseInt(u64, f, 10) catch 0;
        }
        // user nice system idle iowait irq softirq steal
        return .{
            .user = v[0] + v[1],
            .system = v[2] + v[5] + v[6] + v[7],
            .idle = v[3] + v[4],
        };
    }
    return null;
}

fn readCpuTimes() ?CpuTimes {
    var buf: [4096]u8 = undefined;
    const s = readSmall("/proc/stat", &buf) orelse readSmall("sys:proc/stat", &buf) orelse return null;
    return parseCpuTimes(s);
}

/// Parse /proc/meminfo ("MemTotal:  16481980 kB").
pub fn parseMemInfo(s: []const u8) MemInfo {
    var m = MemInfo{};
    var have_avail = false;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const num = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
        const unit = it.next() orelse "";
        const bytes = if (std.ascii.eqlIgnoreCase(unit, "kB")) num * 1024 else if (std.ascii.eqlIgnoreCase(unit, "MB")) num << 20 else num;
        if (std.mem.eql(u8, key, "MemTotal")) {
            m.total = bytes;
            m.valid = true;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            m.free = bytes;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            m.available = bytes;
            have_avail = true;
        } else if (std.mem.eql(u8, key, "Cached")) {
            m.cached = bytes;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            m.buffers = bytes;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            m.swap_total = bytes;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            m.swap_free = bytes;
        }
    }
    if (!have_avail) m.available = m.free + m.cached + m.buffers;
    return m;
}

fn readMemInfo() MemInfo {
    var buf: [8192]u8 = undefined;
    const s = readSmall("/proc/meminfo", &buf) orelse readSmall("sys:meminfo", &buf) orelse return .{};
    return parseMemInfo(s);
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/// "784 KB", "86.2 MB", "1.12 GB" (1024-based like Activity Monitor).
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
    if (bytes < 1 << 20) return std.fmt.bufPrint(buf, "{d} KB", .{@as(u64, @intFromFloat(@round(b / 1024)))}) catch "";
    if (bytes < 1 << 30) {
        const mb = b / (1 << 20);
        if (mb >= 100) return std.fmt.bufPrint(buf, "{d:.0} MB", .{mb}) catch "";
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:.2} GB", .{b / (1 << 30)}) catch "";
}

/// CPU time as "m:ss.cc" or "h:mm:ss".
pub fn formatCpuTime(buf: []u8, ns: u64) []const u8 {
    const cs = ns / (std.time.ns_per_ms * 10);
    const secs = cs / 100;
    const h = secs / 3600;
    const m = (secs / 60) % 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>2}", .{ m, s, cs % 100 }) catch "";
}

/// Elapsed time as "3d 4h", "2h 05m", "12m 30s", "45s".
pub fn formatDuration(buf: []u8, ns: u64) []const u8 {
    const secs = ns / std.time.ns_per_s;
    const d = secs / 86400;
    const h = (secs / 3600) % 24;
    const m = (secs / 60) % 60;
    const s = secs % 60;
    if (d > 0) return std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, h }) catch "";
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ h, m }) catch "";
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, s }) catch "";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "";
}

/// Integer with thousands separators.
pub fn formatCount(buf: []u8, v: u64) []const u8 {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return "";
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

test "parse /proc/<pid>/stat" {
    var p = Proc{ .pid = 42 };
    const line = "42 (Web Content (x)) S 1 42 42 0 -1 4194560 2442 0 0 0 150 50 0 0 20 5 8 0 3500 24313856 1175 18446744073709551615 1 1 0 0\n";
    try std.testing.expect(parseStat(line, &p));
    try std.testing.expectEqualStrings("Web Content (x)", p.name());
    try std.testing.expectEqual(@as(u8, 'S'), p.state);
    try std.testing.expectEqual(@as(u32, 1), p.ppid);
    try std.testing.expectEqual(@as(u64, 200 * ns_per_tick), p.cpu_ns);
    try std.testing.expectEqual(@as(i32, 5), p.nice);
    try std.testing.expectEqual(@as(u32, 8), p.threads);
    try std.testing.expectEqual(@as(u64, 3500 * ns_per_tick), p.start_ns);
    try std.testing.expectEqual(@as(u64, 24313856), p.vsize);
    try std.testing.expectEqual(@as(u64, 1175 * 4096), p.rss);
}

test "parse status, stat and meminfo" {
    try std.testing.expectEqual(@as(?u32, 501), parseStatusUid("Name:\tzsh\nUid:\t501\t501\t501\t501\nGid:\t20\n"));
    const ct = parseCpuTimes("cpu  100 5 50 1000 10 1 2 3 0 0\ncpu0 1 2 3 4\n").?;
    try std.testing.expectEqual(@as(u64, 105), ct.user);
    try std.testing.expectEqual(@as(u64, 56), ct.system);
    try std.testing.expectEqual(@as(u64, 1010), ct.idle);
    const m = parseMemInfo("MemTotal:       16000 kB\nMemFree:  4000 kB\nMemAvailable:   8000 kB\nCached: 2000 kB\n");
    try std.testing.expect(m.valid);
    try std.testing.expectEqual(@as(u64, 16000 * 1024), m.total);
    try std.testing.expectEqual(@as(u64, 8000 * 1024), m.used());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m.pressure(), 0.001);
}

test "formatting helpers" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 bytes", formatBytes(&b, 512));
    try std.testing.expectEqualStrings("784 KB", formatBytes(&b, 784 * 1024));
    try std.testing.expectEqualStrings("86.2 MB", formatBytes(&b, 86 * 1048576 + 200 * 1024));
    try std.testing.expectEqualStrings("1.50 GB", formatBytes(&b, 3 << 29));
    try std.testing.expectEqualStrings("1:05.25", formatCpuTime(&b, 65_250_000_000));
    try std.testing.expectEqualStrings("2:03:04", formatCpuTime(&b, (2 * 3600 + 3 * 60 + 4) * std.time.ns_per_s));
    try std.testing.expectEqualStrings("2h 05m", formatDuration(&b, (2 * 3600 + 5 * 60) * std.time.ns_per_s));
    try std.testing.expectEqualStrings("1,234,567", formatCount(&b, 1234567));
    try std.testing.expectEqualStrings("12", formatCount(&b, 12));
}

test "history ring" {
    var h = History{};
    for (0..history_len + 5) |i| h.push(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, history_len), h.len);
    try std.testing.expectEqual(@as(f32, 5), h.get(0));
    try std.testing.expectEqual(@as(f32, history_len + 4), h.last());
}

test "sampler reads the host process table" {
    var s = Sampler.init(std.testing.allocator);
    defer s.deinit();
    s.refresh();
    s.refresh();
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expect(s.procs.items.len > 0);
        try std.testing.expect(s.find(@intCast(std.os.linux.getpid())) != null);
    }
}
