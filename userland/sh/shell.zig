//! Shell state: variables, functions, aliases, options, positional
//! parameters, traps, output helpers.
const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("sys.zig");
const mem = @import("mem.zig");
const parser = @import("parser.zig");
const jobs = @import("jobs.zig");
const signals = @import("signals.zig");
const history = @import("history.zig");
const Allocator = std.mem.Allocator;

pub const version = "1.0.0";

/// Errors that unwind the executor. `Break`, `Continue`, `Return` implement
/// control flow; `Exit` terminates the shell (status in `exit_status`);
/// `Abort` abandons the current top-level command (status in `last_status`);
/// `Interrupted` is raised on SIGINT in an interactive shell.
pub const Error = error{ OutOfMemory, Break, Continue, Return, Exit, Abort, Interrupted };

pub const Var = struct {
    value: ?[]u8 = null,
    exported: bool = false,
    readonly: bool = false,
};

pub const Function = struct {
    name: []const u8,
    body: *const ast.Node,
    src: []const u8,
};

pub const Options = struct {
    braceexpand: bool = true, // -B
    allexport: bool = false, // -a
    notify: bool = false, // -b
    noclobber: bool = false, // -C
    errexit: bool = false, // -e
    noglob: bool = false, // -f
    hashall: bool = true, // -h
    monitor: bool = false, // -m
    noexec: bool = false, // -n
    nounset: bool = false, // -u
    verbose: bool = false, // -v
    xtrace: bool = false, // -x
    pipefail: bool = false,
    ignoreeof: bool = false,
    emacs: bool = true,
    vi: bool = false,
    nolog: bool = false,
};

pub const OptInfo = struct { name: []const u8, letter: u8, field: []const u8 };
pub const option_table = [_]OptInfo{
    .{ .name = "allexport", .letter = 'a', .field = "allexport" },
    .{ .name = "braceexpand", .letter = 'B', .field = "braceexpand" },
    .{ .name = "notify", .letter = 'b', .field = "notify" },
    .{ .name = "noclobber", .letter = 'C', .field = "noclobber" },
    .{ .name = "errexit", .letter = 'e', .field = "errexit" },
    .{ .name = "noglob", .letter = 'f', .field = "noglob" },
    .{ .name = "hashall", .letter = 'h', .field = "hashall" },
    .{ .name = "monitor", .letter = 'm', .field = "monitor" },
    .{ .name = "noexec", .letter = 'n', .field = "noexec" },
    .{ .name = "nounset", .letter = 'u', .field = "nounset" },
    .{ .name = "verbose", .letter = 'v', .field = "verbose" },
    .{ .name = "xtrace", .letter = 'x', .field = "xtrace" },
    .{ .name = "pipefail", .letter = 0, .field = "pipefail" },
    .{ .name = "ignoreeof", .letter = 0, .field = "ignoreeof" },
    .{ .name = "emacs", .letter = 0, .field = "emacs" },
    .{ .name = "vi", .letter = 0, .field = "vi" },
    .{ .name = "nolog", .letter = 0, .field = "nolog" },
};

pub fn optPtr(o: *Options, field: []const u8) ?*bool {
    inline for (std.meta.fields(Options)) |f| {
        if (std.mem.eql(u8, f.name, field)) return &@field(o, f.name);
    }
    return null;
}

/// Buffered writer on a raw file descriptor (always streaming, never
/// positional, so it behaves correctly with redirections and pipes).
pub const FdWriter = struct {
    fd: i32,
    interface: std.Io.Writer,
    failed: bool = false,

    pub fn init(fd: i32, buf: []u8) FdWriter {
        return .{ .fd = fd, .interface = .{ .vtable = &vtable, .buffer = buf } };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);
        if (w.end > 0) {
            sys.writeAll(self.fd, w.buffer[0..w.end]) catch {
                self.failed = true;
                w.end = 0;
                return error.WriteFailed;
            };
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            sys.writeAll(self.fd, d) catch {
                self.failed = true;
                return error.WriteFailed;
            };
            n += d.len;
        }
        const last = data[data.len - 1];
        var k: usize = 0;
        while (k < splat) : (k += 1) {
            sys.writeAll(self.fd, last) catch {
                self.failed = true;
                return error.WriteFailed;
            };
            n += last.len;
        }
        return n;
    }

    pub fn flush(self: *FdWriter) void {
        self.interface.flush() catch {
            self.interface.end = 0;
        };
    }
};

const Saved = struct { name: []u8, old: ?Var };
pub const Frame = std.ArrayList(Saved);

pub const Shell = struct {
    gpa: Allocator,
    scratch: mem.Scratch = .{},

    vars: std.StringHashMapUnmanaged(Var) = .empty,
    funcs: std.StringHashMapUnmanaged(Function) = .empty,
    aliases: std.StringHashMapUnmanaged([]u8) = .empty,
    hash: std.StringHashMapUnmanaged([]u8) = .empty,
    params: [][]u8 = &.{},
    arg0: []const u8 = "zensh",
    opts: Options = .{},

    interactive: bool = false,
    login: bool = false,
    is_subshell: bool = false,
    reading_stdin: bool = false,
    cmd_string: bool = false,
    script_name: ?[]const u8 = null,

    last_status: u8 = 0,
    exit_status: u8 = 0,
    return_status: u8 = 0,
    break_n: u32 = 0,
    cont_n: u32 = 0,
    loop_depth: u32 = 0,
    func_depth: u32 = 0,
    source_depth: u32 = 0,
    errexit_suppress: u32 = 0,
    cmdsub_status: ?u8 = null,
    last_bg_pid: ?i32 = null,
    pid: i32 = 0,
    lineno: u32 = 0,
    getopts_pos: usize = 0,
    random_state: u64 = 0,
    start_time: i64 = 0,
    in_trap: bool = false,
    /// nesting of command substitutions / eval, for the xtrace prefix
    trace_depth: u32 = 0,
    exit_warned: bool = false,

    frames: std.ArrayList(Frame) = .empty,

    traps: [signals.NSIG]?[]u8 = @splat(null),
    ignored_on_entry: [signals.NSIG]bool = @splat(false),

    jobs: jobs.Table = .{},
    tty_fd: i32 = -1,
    shell_pgid: i32 = 0,
    shell_tmodes: ?sys.termios = null,

    out: FdWriter = undefined,
    out_buf: [4096]u8 = undefined,

    hist: history.History = .{},

    pub fn init(self: *Shell, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.out = FdWriter.init(1, &self.out_buf);
        self.pid = sys.getpid();
        const t = sys.now();
        self.start_time = t.sec;
        self.random_state = @as(u64, @bitCast(@as(i64, t.nsec))) ^ @as(u64, @intCast(self.pid)) *% 0x9E3779B97F4A7C15;
    }

    pub fn scratchAlloc(self: *Shell) Allocator {
        return self.scratch.allocator();
    }

    // ------------------------------------------------------------------
    // output
    // ------------------------------------------------------------------

    pub fn print(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        self.out.interface.print(fmt, args) catch {};
    }

    pub fn write(self: *Shell, s: []const u8) void {
        self.out.interface.writeAll(s) catch {};
    }

    pub fn flushOut(self: *Shell) void {
        self.out.flush();
    }

    /// Write to stderr, unbuffered.
    pub fn errWrite(_: *Shell, s: []const u8) void {
        sys.writeAll(2, s) catch {};
    }

    pub fn errPrefix(self: *Shell, buf: []u8) []const u8 {
        if (self.interactive and self.source_depth == 0) return std.fmt.bufPrint(buf, "zensh: ", .{}) catch "";
        const nm = self.script_name orelse "zensh";
        return std.fmt.bufPrint(buf, "{s}: line {d}: ", .{ nm, self.lineno }) catch "";
    }

    /// Print "zensh: <msg>" to stderr.
    pub noinline fn errMsg(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        self.flushOut();
        var buf: [1024]u8 = undefined;
        const pre = self.errPrefix(&buf);
        const msg = std.fmt.bufPrint(buf[pre.len .. buf.len - 1], fmt, args) catch blk: {
            break :blk buf[pre.len .. buf.len - 1];
        };
        buf[pre.len + msg.len] = '\n';
        self.errWrite(buf[0 .. pre.len + msg.len + 1]);
    }

    // ------------------------------------------------------------------
    // variables
    // ------------------------------------------------------------------

    fn fmtScratch(self: *Shell, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        return std.fmt.allocPrint(self.scratchAlloc(), fmt, args) catch null;
    }

    pub fn getVar(self: *Shell, name: []const u8) ?[]const u8 {
        if (self.vars.get(name)) |v| {
            if (v.value) |val| return val;
        }
        if (name.len > 0 and name[0] <= 'Z') {
            if (std.mem.eql(u8, name, "RANDOM")) {
                self.random_state = self.random_state *% 6364136223846793005 +% 1442695040888963407;
                return self.fmtScratch("{d}", .{(self.random_state >> 33) % 32768});
            }
            if (std.mem.eql(u8, name, "LINENO")) return self.fmtScratch("{d}", .{self.lineno});
            if (std.mem.eql(u8, name, "SECONDS")) return self.fmtScratch("{d}", .{sys.now().sec - self.start_time});
        }
        return null;
    }

    pub fn isSet(self: *Shell, name: []const u8) bool {
        return self.getVar(name) != null;
    }

    fn onVarChange(self: *Shell, name: []const u8, value: ?[]const u8) void {
        if (std.mem.eql(u8, name, "PATH")) {
            self.clearHash();
        } else if (std.mem.eql(u8, name, "OPTIND")) {
            self.getopts_pos = 0;
        } else if (std.mem.eql(u8, name, "RANDOM")) {
            if (value) |v| self.random_state = std.fmt.parseInt(u64, v, 10) catch self.random_state;
        } else if (std.mem.eql(u8, name, "HISTSIZE")) {
            if (value) |v| self.hist.max = std.fmt.parseInt(usize, v, 10) catch self.hist.max;
        }
    }

    pub fn clearHash(self: *Shell) void {
        var it = self.hash.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.hash.clearRetainingCapacity();
    }

    /// Set a variable, reporting an error (and aborting) if it is readonly.
    pub fn setVar(self: *Shell, name: []const u8, value: []const u8) Error!void {
        return self.setVarFlags(name, value, .{});
    }

    pub const SetFlags = struct { exported: ?bool = null, readonly: bool = false, force: bool = false };

    pub fn setVarFlags(self: *Shell, name: []const u8, value: ?[]const u8, flags: SetFlags) Error!void {
        const gop = try self.vars.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch |e| {
                _ = self.vars.remove(name);
                return e;
            };
            gop.value_ptr.* = .{};
        } else if (gop.value_ptr.readonly and !flags.force) {
            if (value != null) {
                self.errMsg("{s}: readonly variable", .{name});
                self.last_status = 1;
                return error.Abort;
            }
        }
        const v = gop.value_ptr;
        if (value) |val| {
            const nv = try self.gpa.dupe(u8, val);
            if (v.value) |old| self.gpa.free(old);
            v.value = nv;
        }
        if (flags.exported) |e| v.exported = e;
        if (self.opts.allexport and value != null) v.exported = true;
        if (flags.readonly) v.readonly = true;
        self.onVarChange(name, value);
    }

    pub fn unsetVar(self: *Shell, name: []const u8) Error!bool {
        if (self.vars.getPtr(name)) |v| {
            if (v.readonly) {
                self.errMsg("unset: {s}: cannot unset: readonly variable", .{name});
                return false;
            }
            // If a local frame saved this variable we keep the entry so that
            // restoring works, but drop its value.
            if (v.value) |old| self.gpa.free(old);
            v.value = null;
            v.exported = false;
            if (!self.savedInFrames(name)) {
                const kv = self.vars.fetchRemove(name).?;
                self.gpa.free(kv.key);
            }
        }
        self.onVarChange(name, null);
        return true;
    }

    fn savedInFrames(self: *Shell, name: []const u8) bool {
        for (self.frames.items) |f| {
            for (f.items) |s| if (std.mem.eql(u8, s.name, name)) return true;
        }
        return false;
    }

    pub fn ifs(self: *Shell) []const u8 {
        if (self.vars.get("IFS")) |v| {
            if (v.value) |val| return val;
            return " \t\n";
        }
        return " \t\n";
    }

    /// Declare a function-local variable (dynamic scoping).
    pub fn makeLocal(self: *Shell, name: []const u8, value: ?[]const u8) Error!void {
        if (self.frames.items.len == 0) return;
        const frame = &self.frames.items[self.frames.items.len - 1];
        var already = false;
        for (frame.items) |s| {
            if (std.mem.eql(u8, s.name, name)) already = true;
        }
        if (!already) {
            const key = try self.gpa.dupe(u8, name);
            var old: ?Var = null;
            if (self.vars.getPtr(name)) |v| {
                if (v.readonly) {
                    self.gpa.free(key);
                    self.errMsg("local: {s}: readonly variable", .{name});
                    self.last_status = 1;
                    return error.Abort;
                }
                old = v.*;
                v.* = .{ .exported = v.exported };
            }
            try frame.append(self.gpa, .{ .name = key, .old = old });
            if (old == null) {
                const gop = try self.vars.getOrPut(self.gpa, name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.gpa.dupe(u8, name);
                    gop.value_ptr.* = .{};
                }
            }
        }
        if (value) |val| try self.setVar(name, val);
    }

    pub fn pushFrame(self: *Shell) Error!void {
        try self.frames.append(self.gpa, .empty);
    }

    pub fn popFrame(self: *Shell) void {
        var frame = self.frames.pop() orelse return;
        var i = frame.items.len;
        while (i > 0) {
            i -= 1;
            const s = frame.items[i];
            if (self.vars.fetchRemove(s.name)) |kv| {
                if (kv.value.value) |val| self.gpa.free(val);
                self.gpa.free(kv.key);
            }
            if (s.old) |old| {
                self.vars.put(self.gpa, s.name, old) catch {};
                self.onVarChange(s.name, old.value);
            } else {
                self.onVarChange(s.name, null);
                self.gpa.free(s.name);
            }
        }
        frame.deinit(self.gpa);
    }

    /// Build the environment for execve: NAME=value for exported variables.
    pub fn buildEnv(self: *Shell, a: Allocator) Error![*:null]?[*:0]const u8 {
        var list: std.ArrayList(?[*:0]const u8) = .empty;
        var it = self.vars.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.exported) continue;
            const val = e.value_ptr.value orelse continue;
            const s = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ e.key_ptr.*, val }, 0);
            try list.append(a, s.ptr);
        }
        try list.append(a, null);
        return @ptrCast(list.items.ptr);
    }

    // ------------------------------------------------------------------
    // positional parameters
    // ------------------------------------------------------------------

    pub fn setParams(self: *Shell, args: []const []const u8) Error!void {
        const np = try self.gpa.alloc([]u8, args.len);
        var n: usize = 0;
        errdefer {
            for (np[0..n]) |p| self.gpa.free(p);
            self.gpa.free(np);
        }
        for (args, 0..) |a, i| {
            np[i] = try self.gpa.dupe(u8, a);
            n += 1;
        }
        self.freeParams(self.params);
        self.params = np;
        self.getopts_pos = 0;
    }

    pub fn freeParams(self: *Shell, p: [][]u8) void {
        for (p) |x| self.gpa.free(x);
        if (p.len > 0) self.gpa.free(p);
    }

    pub fn flagsString(self: *Shell, buf: []u8) []const u8 {
        var n: usize = 0;
        inline for (option_table) |o| {
            if (o.letter != 0 and @field(self.opts, o.field) and o.letter != 'h') {
                buf[n] = o.letter;
                n += 1;
            }
        }
        if (self.opts.hashall) {
            buf[n] = 'h';
            n += 1;
        }
        if (self.interactive) {
            buf[n] = 'i';
            n += 1;
        }
        if (self.reading_stdin) {
            buf[n] = 's';
            n += 1;
        }
        if (self.cmd_string) {
            buf[n] = 'c';
            n += 1;
        }
        return buf[0..n];
    }

    // ------------------------------------------------------------------
    // aliases
    // ------------------------------------------------------------------

    fn aliasGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *Shell = @ptrCast(@alignCast(ctx));
        return self.aliases.get(name);
    }

    pub fn aliasLookup(self: *Shell) parser.AliasLookup {
        return .{ .ctx = self, .get = aliasGet };
    }

    pub fn setAlias(self: *Shell, name: []const u8, value: []const u8) Error!void {
        const v = try self.gpa.dupe(u8, value);
        const gop = try self.aliases.getOrPut(self.gpa, name);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = v;
    }

    pub fn removeAlias(self: *Shell, name: []const u8) bool {
        const kv = self.aliases.fetchRemove(name) orelse return false;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
        return true;
    }

    // ------------------------------------------------------------------
    // functions
    // ------------------------------------------------------------------

    pub fn defineFunction(self: *Shell, f: *const ast.FuncDef) Error!void {
        const gop = try self.funcs.getOrPut(self.gpa, f.name);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, f.name);
        gop.value_ptr.* = .{ .name = gop.key_ptr.*, .body = f.body, .src = f.src };
    }

    // ------------------------------------------------------------------
    // misc
    // ------------------------------------------------------------------

    pub fn homeDir(self: *Shell) ?[]const u8 {
        if (self.getVar("HOME")) |h| return h;
        return null;
    }

    pub fn userName(self: *Shell, buf: []u8) []const u8 {
        if (self.getVar("USER")) |u| if (u.len > 0) return u;
        if (self.getVar("LOGNAME")) |u| if (u.len > 0) return u;
        const uid = sys.geteuid();
        if (passwdLookup(self.scratchAlloc(), .{ .uid = uid })) |pw| {
            const n = @min(pw.name.len, buf.len);
            @memcpy(buf[0..n], pw.name[0..n]);
            return buf[0..n];
        }
        if (uid == 0) return "root";
        return "zen";
    }
};

pub const Passwd = struct { name: []const u8, uid: u32, home: []const u8, shell: []const u8 };

pub fn passwdLookup(a: Allocator, key: union(enum) { name: []const u8, uid: u32 }) ?Passwd {
    const data = readFileAlloc(a, "/etc/passwd", 1 << 20) orelse return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next();
        const uid_s = f.next() orelse continue;
        _ = f.next();
        _ = f.next();
        const home = f.next() orelse continue;
        const sh = f.next() orelse "";
        const uid = std.fmt.parseInt(u32, uid_s, 10) catch continue;
        const match = switch (key) {
            .name => |n| std.mem.eql(u8, n, name),
            .uid => |u| u == uid,
        };
        if (match) return .{ .name = name, .uid = uid, .home = home, .shell = sh };
    }
    return null;
}

pub fn readFileAlloc(a: Allocator, path: []const u8, max: usize) ?[]u8 {
    const fd = sys.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer sys.close(fd);
    return readAllFd(a, fd, max) catch null;
}

pub fn readAllFd(a: Allocator, fd: i32, max: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    while (list.items.len < max) {
        try list.ensureUnusedCapacity(a, 4096);
        const dest = list.unusedCapacitySlice();
        const n = sys.read(fd, dest) catch |e| {
            if (list.items.len > 0) break;
            return e;
        };
        if (n == 0) break;
        list.items.len += n;
    }
    return list.items;
}

/// Quote a string for re-input to the shell (used by set, alias, export -p,
/// xtrace). Returns the string unchanged if no quoting is needed.
pub fn quote(a: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "''";
    var safe = true;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-./:=@%+,^", c) != null or c >= 0x80)) {
            safe = false;
            break;
        }
    }
    if (safe) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\\''");
        } else try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}
