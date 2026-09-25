//! Job table: every pipeline the shell forks is tracked as a job so that
//! foreground waits, background notifications, `jobs`, `fg`, `bg`, `wait`
//! and `$!` all share the same bookkeeping.
const std = @import("std");
const sys = @import("sys.zig");
const signals = @import("signals.zig");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const ProcState = enum { running, stopped, done };

pub const Proc = struct {
    pid: i32,
    status: u32 = 0,
    state: ProcState = .running,
};

pub const Job = struct {
    id: u32,
    pgid: i32 = 0,
    procs: std.ArrayList(Proc) = .empty,
    text: []u8,
    bg: bool,
    notified: bool = false,
    /// Terminal modes saved when the job was stopped.
    tmodes: ?sys.termios = null,
    /// monotonically increasing "last touched" counter for %+ / %-.
    stamp: u64 = 0,

    pub fn state(self: *const Job) ProcState {
        var stopped = false;
        for (self.procs.items) |p| {
            if (p.state == .running) return .running;
            if (p.state == .stopped) stopped = true;
        }
        return if (stopped) .stopped else .done;
    }

    pub fn lastProc(self: *const Job) ?*Proc {
        if (self.procs.items.len == 0) return null;
        return &self.procs.items[self.procs.items.len - 1];
    }

    /// Exit status of the job (last process, or rightmost failure with
    /// pipefail).
    pub fn exitCode(self: *const Job, pipefail: bool) u8 {
        if (self.procs.items.len == 0) return 0;
        if (pipefail) {
            var i = self.procs.items.len;
            while (i > 0) {
                i -= 1;
                const c = statusCode(self.procs.items[i].status);
                if (c != 0) return c;
            }
            return 0;
        }
        return statusCode(self.procs.items[self.procs.items.len - 1].status);
    }
};

pub fn statusCode(st: u32) u8 {
    if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
    if (linux.W.IFSIGNALED(st)) return @truncate(128 + linux.W.TERMSIG(st));
    if (linux.W.IFSTOPPED(st)) return @truncate(128 + linux.W.STOPSIG(st));
    return 0;
}

pub const Table = struct {
    list: std.ArrayList(*Job) = .empty,
    counter: u64 = 0,

    pub fn create(self: *Table, gpa: Allocator, text: []const u8, bg: bool) !*Job {
        var id: u32 = 1;
        while (self.byId(id) != null) id += 1;
        const j = try gpa.create(Job);
        j.* = .{ .id = id, .text = try gpa.dupe(u8, text), .bg = bg };
        self.counter += 1;
        j.stamp = self.counter;
        try self.list.append(gpa, j);
        return j;
    }

    pub fn touch(self: *Table, j: *Job) void {
        self.counter += 1;
        j.stamp = self.counter;
    }

    pub fn remove(self: *Table, gpa: Allocator, j: *Job) void {
        for (self.list.items, 0..) |x, i| {
            if (x == j) {
                _ = self.list.orderedRemove(i);
                break;
            }
        }
        j.procs.deinit(gpa);
        gpa.free(j.text);
        gpa.destroy(j);
    }

    pub fn clear(self: *Table, gpa: Allocator) void {
        while (self.list.items.len > 0) self.remove(gpa, self.list.items[0]);
    }

    pub fn byId(self: *Table, id: u32) ?*Job {
        for (self.list.items) |j| if (j.id == id) return j;
        return null;
    }

    pub fn byPid(self: *Table, pid: i32) ?*Job {
        for (self.list.items) |j| {
            for (j.procs.items) |p| if (p.pid == pid) return j;
        }
        return null;
    }

    /// Record a wait status for `pid`. Returns the job it belongs to.
    pub fn update(self: *Table, pid: i32, status: u32) ?*Job {
        for (self.list.items) |j| {
            for (j.procs.items) |*p| {
                if (p.pid != pid) continue;
                if (linux.W.IFSTOPPED(status)) {
                    p.state = .stopped;
                    p.status = status;
                } else if (status == 0xffff) {
                    // WIFCONTINUED
                    p.state = .running;
                } else {
                    p.state = .done;
                    p.status = status;
                }
                return j;
            }
        }
        return null;
    }

    /// Reap any children that changed state, without blocking.
    pub fn reapNonBlocking(self: *Table) void {
        while (true) {
            const r = sys.wait4(-1, linux.W.NOHANG | linux.W.UNTRACED) catch return;
            if (r.pid <= 0) return;
            _ = self.update(r.pid, r.status);
        }
    }

    /// The current job (%+): most recently stopped, else most recent.
    pub fn current(self: *Table) ?*Job {
        var best: ?*Job = null;
        for (self.list.items) |j| {
            if (j.state() == .stopped) {
                if (best == null or best.?.state() != .stopped or j.stamp > best.?.stamp) best = j;
            } else if (best == null or (best.?.state() != .stopped and j.stamp > best.?.stamp)) best = j;
        }
        return best;
    }

    pub fn previous(self: *Table) ?*Job {
        const cur = self.current() orelse return null;
        var best: ?*Job = null;
        for (self.list.items) |j| {
            if (j == cur) continue;
            if (best == null or j.stamp > best.?.stamp) best = j;
        }
        return best;
    }

    /// Resolve a job spec: %n, %+, %%, %-, %string, %?string, or a pid.
    pub fn resolve(self: *Table, spec: []const u8) ?*Job {
        if (spec.len == 0) return self.current();
        if (spec[0] != '%') {
            const pid = std.fmt.parseInt(i32, spec, 10) catch return null;
            return self.byPid(pid);
        }
        const s = spec[1..];
        if (s.len == 0 or std.mem.eql(u8, s, "+") or std.mem.eql(u8, s, "%")) return self.current();
        if (std.mem.eql(u8, s, "-")) return self.previous();
        if (std.fmt.parseInt(u32, s, 10)) |n| return self.byId(n) else |_| {}
        if (s[0] == '?') {
            for (self.list.items) |j| if (std.mem.indexOf(u8, j.text, s[1..]) != null) return j;
            return null;
        }
        for (self.list.items) |j| if (std.mem.startsWith(u8, j.text, s)) return j;
        return null;
    }

    pub fn marker(self: *Table, j: *Job) u8 {
        if (self.current() == j) return '+';
        if (self.previous() == j) return '-';
        return ' ';
    }
};

/// Human readable state for `jobs` and notifications.
pub fn stateText(buf: []u8, j: *const Job) []const u8 {
    switch (j.state()) {
        .running => return "Running",
        .stopped => {
            const p = j.lastProc() orelse return "Stopped";
            var sig: u32 = linux.SIG.TSTP;
            for (j.procs.items) |pp| {
                if (pp.state == .stopped) sig = linux.W.STOPSIG(pp.status);
            }
            _ = p;
            return switch (sig) {
                linux.SIG.TTIN => "Stopped (tty input)",
                linux.SIG.TTOU => "Stopped (tty output)",
                linux.SIG.STOP => "Stopped (signal)",
                else => "Stopped",
            };
        },
        .done => {
            const p = j.lastProc() orelse return "Done";
            const st = p.status;
            if (linux.W.IFSIGNALED(st)) {
                return signals.describe(linux.W.TERMSIG(st));
            }
            const code = linux.W.EXITSTATUS(st);
            if (code == 0) return "Done";
            return std.fmt.bufPrint(buf, "Exit {d}", .{code}) catch "Exit";
        },
    }
}
