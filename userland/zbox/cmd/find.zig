const std = @import("std");
const c = @import("../common.zig");
const rx = @import("../regex.zig");
const mem = std.mem;

pub const help =
    \\Usage: find [-H] [-L] [-P] [path...] [expression]
    \\
    \\Default path is the current directory; default expression is -print.
    \\Expression may consist of: operators, options, tests, and actions.
    \\
    \\Operators (decreasing precedence; -and is implicit where no others are given):
    \\      ( EXPR )   ! EXPR   -not EXPR   EXPR1 -a EXPR2   EXPR1 -and EXPR2
    \\      EXPR1 -o EXPR2   EXPR1 -or EXPR2   EXPR1 , EXPR2
    \\
    \\Positional options (always true):
    \\      -daystart -follow -regextype
    \\
    \\Normal options (always true, specified before other expressions):
    \\      -depth -maxdepth LEVELS -mindepth LEVELS -mount -noleaf -xdev
    \\
    \\Tests (N can be +N or -N or N):
    \\      -amin N -anewer FILE -atime N -cmin N -cnewer FILE -ctime N
    \\      -empty -false -gid N -group NAME -ilname PATTERN -iname PATTERN
    \\      -inum N -ipath PATTERN -iregex PATTERN -links N -lname PATTERN
    \\      -mmin N -mtime N -name PATTERN -newer FILE -nouser -nogroup
    \\      -path PATTERN -perm [-/]MODE -regex PATTERN -readable -writable
    \\      -executable -wholename PATTERN -size N[bcwkMG] -true -type [bcdpflsD]
    \\      -uid N -user NAME -xtype [bcdpfls] -samefile FILE
    \\
    \\Actions:
    \\      -delete -print0 -printf FORMAT -prune -print -quit -ls
    \\      -exec COMMAND ; -exec COMMAND {} + -ok COMMAND ;
    \\      -execdir COMMAND ; -execdir COMMAND {} + -okdir COMMAND ;
    \\
;

const Cmp = enum { lt, eq, gt };
const NumArg = struct { cmp: Cmp, n: i64 };

const Exec = struct {
    argv: []const []const u8,
    plus: bool,
    dir: bool,
    ok: bool,
    pending: std.ArrayList([]const u8) = .empty,
    pending_dir: []const u8 = "",
    pending_len: usize = 0,
};

const Node = union(enum) {
    and_: [2]*Node,
    or_: [2]*Node,
    comma: [2]*Node,
    not: *Node,
    true_,
    false_,
    name: struct { pat: []const u8, icase: bool },
    path: struct { pat: []const u8, icase: bool },
    lname: struct { pat: []const u8, icase: bool },
    regex: *rx.Regex,
    type_: struct { types: []const u8, x: bool },
    size: struct { cmp: Cmp, n: u64, unit: u64 },
    empty,
    newer: struct { t: c.Ts, which: u8 },
    time: struct { arg: NumArg, which: u8, minutes: bool },
    perm: struct { mode: u32, kind: u8 },
    user: u32,
    group: u32,
    nouser,
    nogroup,
    links: NumArg,
    inum: NumArg,
    uid: NumArg,
    gid: NumArg,
    samefile: struct { dev: u64, ino: u64 },
    access: u32,
    print,
    print0,
    printf: []const u8,
    ls,
    delete,
    prune,
    quit,
    exec: *Exec,
};

const Ctx = struct {
    path: []const u8,
    name: []const u8,
    start: []const u8,
    depth: usize,
    st: ?c.Stat = null,
    st_done: bool = false,
    prune: bool = false,

    fn stat(self: *Ctx) ?c.Stat {
        if (!self.st_done) {
            self.st_done = true;
            self.st = (if (follow_all or (follow_cmd and self.depth == 0)) (c.sys.stat(self.path) catch c.sys.lstat(self.path)) else c.sys.lstat(self.path)) catch null;
        }
        return self.st;
    }
};

var follow_all = false;
var follow_cmd = false;
var max_depth: ?usize = null;
var min_depth: usize = 0;
var depth_first = false;
var xdev = false;
var daystart = false;
var regex_ext = false;
var now: c.Ts = .{};
var status: u8 = 0;
var quit_now = false;
var execs: std.ArrayList(*Exec) = .empty;

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const P = struct {
    args: []const []const u8,
    i: usize = 0,
    has_action: bool = false,

    fn peek(p: *P) ?[]const u8 {
        return if (p.i < p.args.len) p.args[p.i] else null;
    }
    fn take(p: *P) ?[]const u8 {
        const a = p.peek() orelse return null;
        p.i += 1;
        return a;
    }
    fn need(p: *P, pred: []const u8) []const u8 {
        return p.take() orelse c.fatal("missing argument to `{s}'", .{pred});
    }
    fn node(n: Node) *Node {
        const x = c.gpa.create(Node) catch c.oom();
        x.* = n;
        return x;
    }

    fn parseExpr(p: *P) *Node {
        var left = p.parseOr();
        while (p.peek()) |a| {
            if (!c.eql(a, ",")) break;
            p.i += 1;
            const right = p.parseOr();
            left = node(.{ .comma = .{ left, right } });
        }
        return left;
    }
    fn parseOr(p: *P) *Node {
        var left = p.parseAnd();
        while (p.peek()) |a| {
            if (!(c.eql(a, "-o") or c.eql(a, "-or"))) break;
            p.i += 1;
            if (p.peek() == null) c.fatal("expected an expression after '{s}'", .{a});
            const right = p.parseAnd();
            left = node(.{ .or_ = .{ left, right } });
        }
        return left;
    }
    fn parseAnd(p: *P) *Node {
        var left = p.parseUnary() orelse c.fatal("expected an expression", .{});
        while (p.peek()) |a| {
            if (c.eql(a, "-o") or c.eql(a, "-or") or c.eql(a, ")") or c.eql(a, ",")) break;
            if (c.eql(a, "-a") or c.eql(a, "-and")) {
                p.i += 1;
            }
            const right = p.parseUnary() orelse break;
            left = node(.{ .and_ = .{ left, right } });
        }
        return left;
    }
    fn parseUnary(p: *P) ?*Node {
        const a = p.peek() orelse return null;
        if (c.eql(a, "!") or c.eql(a, "-not")) {
            p.i += 1;
            const inner = p.parseUnary() orelse c.fatal("expected an expression after '{s}'", .{a});
            return node(.{ .not = inner });
        }
        if (c.eql(a, "(")) {
            p.i += 1;
            const inner = p.parseExpr();
            if (!c.eql(p.take() orelse "", ")")) c.fatal("invalid expression; I was expecting to find a ')' somewhere but did not see one.", .{});
            return inner;
        }
        if (c.eql(a, ")")) return null;
        p.i += 1;
        return p.primary(a);
    }

    fn numArg(p: *P, pred: []const u8) NumArg {
        const s = p.need(pred);
        var cmp: Cmp = .eq;
        var t = s;
        if (t.len > 0 and t[0] == '+') {
            cmp = .gt;
            t = t[1..];
        } else if (t.len > 0 and t[0] == '-') {
            cmp = .lt;
            t = t[1..];
        }
        const n = c.parseInt(t) orelse c.fatal("invalid argument `{s}' to `{s}'", .{ s, pred });
        return .{ .cmp = cmp, .n = n };
    }

    fn fileTime(p: *P, pred: []const u8, which: u8) *Node {
        const f = p.need(pred);
        const st = (if (follow_all) c.sys.stat(f) else c.sys.lstat(f)) catch |e| c.fatal("{f}: {s}", .{ c.q(f), c.strerror(e) });
        const t = switch (which) {
            'a' => st.atime,
            'c' => st.ctime,
            else => st.mtime,
        };
        return node(.{ .newer = .{ .t = t, .which = if (c.eql(pred, "-anewer")) 'a' else if (c.eql(pred, "-cnewer")) 'c' else 'm' } });
    }

    fn primary(p: *P, a: []const u8) *Node {
        const eql = c.eql;
        if (eql(a, "-true")) return node(.true_);
        if (eql(a, "-false")) return node(.false_);
        if (eql(a, "-name") or eql(a, "-iname")) return node(.{ .name = .{ .pat = p.need(a), .icase = eql(a, "-iname") } });
        if (eql(a, "-path") or eql(a, "-wholename") or eql(a, "-ipath") or eql(a, "-iwholename")) return node(.{ .path = .{ .pat = p.need(a), .icase = a[1] == 'i' } });
        if (eql(a, "-lname") or eql(a, "-ilname")) return node(.{ .lname = .{ .pat = p.need(a), .icase = eql(a, "-ilname") } });
        if (eql(a, "-regex") or eql(a, "-iregex")) {
            const pat = p.need(a);
            const re = c.gpa.create(rx.Regex) catch c.oom();
            re.* = rx.Regex.compile(c.gpa, pat, .{ .extended = regex_ext, .icase = eql(a, "-iregex"), .whole_line = true }) catch c.fatal("{s}", .{rx.err_msg});
            return node(.{ .regex = re });
        }
        if (eql(a, "-regextype")) {
            const t = p.need(a);
            regex_ext = !(eql(t, "posix-basic") or eql(t, "ed") or eql(t, "sed") or eql(t, "grep"));
            return node(.true_);
        }
        if (eql(a, "-type") or eql(a, "-xtype")) {
            const t = p.need(a);
            var list: std.ArrayList(u8) = .empty;
            var it = mem.splitScalar(u8, t, ',');
            while (it.next()) |x| {
                if (x.len != 1 or mem.indexOfScalar(u8, "bcdpflsD", x[0]) == null) c.fatal("Unknown argument to {s}: {s}", .{ a, x });
                list.append(c.gpa, x[0]) catch c.oom();
            }
            return node(.{ .type_ = .{ .types = list.items, .x = eql(a, "-xtype") } });
        }
        if (eql(a, "-size")) {
            const s = p.need(a);
            var t = s;
            var cmp: Cmp = .eq;
            if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
                cmp = if (t[0] == '+') .gt else .lt;
                t = t[1..];
            }
            var unit: u64 = 512;
            if (t.len > 0 and !std.ascii.isDigit(t[t.len - 1])) {
                unit = switch (t[t.len - 1]) {
                    'c' => 1,
                    'w' => 2,
                    'b' => 512,
                    'k' => 1024,
                    'M' => 1024 * 1024,
                    'G' => 1024 * 1024 * 1024,
                    else => c.fatal("invalid -size type `{c}'", .{t[t.len - 1]}),
                };
                t = t[0 .. t.len - 1];
            }
            const n = c.parseUint(t) orelse c.fatal("invalid argument `{s}' to `-size'", .{s});
            return node(.{ .size = .{ .cmp = cmp, .n = n, .unit = unit } });
        }
        if (eql(a, "-empty")) return node(.empty);
        if (eql(a, "-newer")) return p.fileTime(a, 'm');
        if (eql(a, "-anewer")) return p.fileTime(a, 'm');
        if (eql(a, "-cnewer")) return p.fileTime(a, 'm');
        if (a.len == 7 and mem.startsWith(u8, a, "-newer")) {} // -newerXY not supported
        if (eql(a, "-mtime") or eql(a, "-atime") or eql(a, "-ctime")) return node(.{ .time = .{ .arg = p.numArg(a), .which = a[1], .minutes = false } });
        if (eql(a, "-mmin") or eql(a, "-amin") or eql(a, "-cmin")) return node(.{ .time = .{ .arg = p.numArg(a), .which = a[1], .minutes = true } });
        if (eql(a, "-perm")) {
            const s = p.need(a);
            var kind: u8 = '=';
            var t = s;
            if (t.len > 0 and (t[0] == '-' or t[0] == '/' or t[0] == '+')) {
                kind = if (t[0] == '+') '/' else t[0];
                t = t[1..];
            }
            const m = c.parseMode(t, 0, false, 0) orelse c.fatal("invalid mode `{s}'", .{s});
            return node(.{ .perm = .{ .mode = m & 0o7777, .kind = kind } });
        }
        if (eql(a, "-user")) {
            const u = p.need(a);
            const uid = if (c.userByName(u)) |ue| ue.uid else @as(u32, @intCast(c.parseUint(u) orelse c.fatal("{f} is not the name of a known user", .{c.q(u)})));
            return node(.{ .user = uid });
        }
        if (eql(a, "-group")) {
            const g = p.need(a);
            const gid = if (c.groupByName(g)) |ge| ge.gid else @as(u32, @intCast(c.parseUint(g) orelse c.fatal("{f} is not the name of an existing group", .{c.q(g)})));
            return node(.{ .group = gid });
        }
        if (eql(a, "-nouser")) return node(.nouser);
        if (eql(a, "-nogroup")) return node(.nogroup);
        if (eql(a, "-links")) return node(.{ .links = p.numArg(a) });
        if (eql(a, "-inum")) return node(.{ .inum = p.numArg(a) });
        if (eql(a, "-uid")) return node(.{ .uid = p.numArg(a) });
        if (eql(a, "-gid")) return node(.{ .gid = p.numArg(a) });
        if (eql(a, "-samefile")) {
            const f = p.need(a);
            const st = c.sys.stat(f) catch |e| c.fatal("{f}: {s}", .{ c.q(f), c.strerror(e) });
            return node(.{ .samefile = .{ .dev = st.dev, .ino = st.ino } });
        }
        if (eql(a, "-readable")) return node(.{ .access = 4 });
        if (eql(a, "-writable")) return node(.{ .access = 2 });
        if (eql(a, "-executable")) return node(.{ .access = 1 });
        if (eql(a, "-print")) {
            p.has_action = true;
            return node(.print);
        }
        if (eql(a, "-print0")) {
            p.has_action = true;
            return node(.print0);
        }
        if (eql(a, "-printf")) {
            p.has_action = true;
            return node(.{ .printf = p.need(a) });
        }
        if (eql(a, "-fprint") or eql(a, "-fprintf") or eql(a, "-fls")) c.fatal("{s} is not supported", .{a});
        if (eql(a, "-ls")) {
            p.has_action = true;
            return node(.ls);
        }
        if (eql(a, "-delete")) {
            p.has_action = true;
            depth_first = true;
            return node(.delete);
        }
        if (eql(a, "-prune")) return node(.prune);
        if (eql(a, "-quit")) return node(.quit);
        if (eql(a, "-exec") or eql(a, "-execdir") or eql(a, "-ok") or eql(a, "-okdir")) {
            p.has_action = true;
            var argv: std.ArrayList([]const u8) = .empty;
            var plus = false;
            while (true) {
                const x = p.take() orelse c.fatal("missing argument to `{s}'", .{a});
                if (eql(x, ";")) break;
                if (eql(x, "+") and argv.items.len > 0 and eql(argv.items[argv.items.len - 1], "{}") and !(eql(a, "-ok") or eql(a, "-okdir"))) {
                    plus = true;
                    break;
                }
                argv.append(c.gpa, x) catch c.oom();
            }
            if (argv.items.len == 0) c.fatal("missing argument to `{s}'", .{a});
            const e = c.gpa.create(Exec) catch c.oom();
            e.* = .{ .argv = argv.items, .plus = plus, .dir = mem.endsWith(u8, a, "dir"), .ok = mem.startsWith(u8, a, "-ok") };
            execs.append(c.gpa, e) catch c.oom();
            return node(.{ .exec = e });
        }
        // options (always true)
        if (eql(a, "-maxdepth") or eql(a, "-mindepth")) {
            const s = p.need(a);
            const n = c.parseUint(s) orelse c.fatal("Expected a positive decimal integer argument to {s}, but got `{s}'", .{ a, s });
            if (eql(a, "-maxdepth")) max_depth = @intCast(n) else min_depth = @intCast(n);
            return node(.true_);
        }
        if (eql(a, "-depth") or eql(a, "-d")) {
            depth_first = true;
            return node(.true_);
        }
        if (eql(a, "-xdev") or eql(a, "-mount")) {
            xdev = true;
            return node(.true_);
        }
        if (eql(a, "-follow")) {
            follow_all = true;
            return node(.true_);
        }
        if (eql(a, "-daystart")) {
            daystart = true;
            return node(.true_);
        }
        if (eql(a, "-noleaf") or eql(a, "-ignore_readdir_race") or eql(a, "-noignore_readdir_race") or eql(a, "-nowarn") or eql(a, "-warn")) return node(.true_);
        if (a.len > 0 and a[0] == '-') c.fatal("unknown predicate `{s}'", .{a});
        c.fatal("paths must precede expression: `{s}'", .{a});
    }
};

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

fn cmpNum(a: NumArg, v: i64) bool {
    return switch (a.cmp) {
        .lt => v < a.n,
        .eq => v == a.n,
        .gt => v > a.n,
    };
}

fn typeChar(mode: u32) u8 {
    return switch (mode & c.S_IFMT) {
        c.S_IFDIR => 'd',
        c.S_IFREG => 'f',
        c.S_IFLNK => 'l',
        c.S_IFIFO => 'p',
        c.S_IFSOCK => 's',
        c.S_IFCHR => 'c',
        c.S_IFBLK => 'b',
        else => 'U',
    };
}

fn isEmpty(ctx: *Ctx) bool {
    const st = ctx.stat() orelse return false;
    if (st.isReg()) return st.size == 0;
    if (st.isDir()) {
        const d = c.Dir.open(ctx.path) catch return false;
        defer d.close();
        return (d.next() catch null) == null;
    }
    return false;
}

fn eval(n: *Node, ctx: *Ctx) bool {
    switch (n.*) {
        .and_ => |x| return eval(x[0], ctx) and eval(x[1], ctx),
        .or_ => |x| return eval(x[0], ctx) or eval(x[1], ctx),
        .comma => |x| {
            _ = eval(x[0], ctx);
            return eval(x[1], ctx);
        },
        .not => |x| return !eval(x, ctx),
        .true_ => return true,
        .false_ => return false,
        .name => |x| {
            var name = ctx.name;
            // find matches "/" for the root dir name
            if (name.len == 0) name = ctx.path;
            return c.fnmatch(x.pat, name, .{ .icase = x.icase });
        },
        .path => |x| return c.fnmatch(x.pat, ctx.path, .{ .icase = x.icase }),
        .lname => |x| {
            const st = c.sys.lstat(ctx.path) catch return false;
            if (!st.isLnk()) return false;
            var b: [c.PATH_MAX]u8 = undefined;
            const t = c.sys.readlink(ctx.path, &b) catch return false;
            return c.fnmatch(x.pat, t, .{ .icase = x.icase });
        },
        .regex => |re| return re.exec(ctx.path, 0, null, .{ .longest = false }),
        .type_ => |x| {
            var st: c.Stat = undefined;
            if (x.x) {
                // -xtype: check type of the target (or the link itself with -L)
                st = (if (follow_all) c.sys.lstat(ctx.path) else c.sys.stat(ctx.path)) catch (c.sys.lstat(ctx.path) catch return false);
            } else st = ctx.stat() orelse return false;
            const t = typeChar(st.mode);
            for (x.types) |want| if (want == t) return true;
            return false;
        },
        .size => |x| {
            const st = ctx.stat() orelse return false;
            const sz: u64 = @intCast(@max(st.size, 0));
            const units = (sz + x.unit - 1) / x.unit;
            return switch (x.cmp) {
                .lt => units < x.n,
                .eq => units == x.n,
                .gt => units > x.n,
            };
        },
        .empty => return isEmpty(ctx),
        .newer => |x| {
            const st = ctx.stat() orelse return false;
            const t = switch (x.which) {
                'a' => st.atime,
                'c' => st.ctime,
                else => st.mtime,
            };
            return c.Ts.cmp(t, x.t) == .gt;
        },
        .time => |x| {
            const st = ctx.stat() orelse return false;
            const t = switch (x.which) {
                'a' => st.atime,
                'c' => st.ctime,
                else => st.mtime,
            };
            var ref = now.sec;
            if (daystart) {
                const tm = c.localtime(now.sec);
                ref = now.sec - (@as(i64, tm.hour) * 3600 + @as(i64, tm.min) * 60 + tm.sec) + 86400;
            }
            const age = ref - t.sec;
            const unit: i64 = if (x.minutes) 60 else 86400;
            if (x.minutes) {
                // GNU rounds up for -mmin comparisons
                const mins = @divFloor(age + unit - 1, unit);
                return cmpNum(x.arg, mins);
            }
            return cmpNum(x.arg, @divFloor(age, unit));
        },
        .perm => |x| {
            const st = ctx.stat() orelse return false;
            const m = st.mode & 0o7777;
            return switch (x.kind) {
                '-' => m & x.mode == x.mode,
                '/' => x.mode == 0 or m & x.mode != 0,
                else => m == x.mode,
            };
        },
        .user => |uid| return if (ctx.stat()) |st| st.uid == uid else false,
        .group => |gid| return if (ctx.stat()) |st| st.gid == gid else false,
        .nouser => return if (ctx.stat()) |st| c.userByUid(st.uid) == null else false,
        .nogroup => return if (ctx.stat()) |st| c.groupByGid(st.gid) == null else false,
        .links => |a| return if (ctx.stat()) |st| cmpNum(a, @intCast(st.nlink)) else false,
        .inum => |a| return if (ctx.stat()) |st| cmpNum(a, @intCast(st.ino)) else false,
        .uid => |a| return if (ctx.stat()) |st| cmpNum(a, st.uid) else false,
        .gid => |a| return if (ctx.stat()) |st| cmpNum(a, st.gid) else false,
        .samefile => |x| return if (ctx.stat()) |st| st.dev == x.dev and st.ino == x.ino else false,
        .access => |m| {
            c.sys.access(ctx.path, m) catch return false;
            return true;
        },
        .print => {
            c.out.print("{s}\n", .{ctx.path}) catch c.writeFailed();
            return true;
        },
        .print0 => {
            c.out.print("{s}\x00", .{ctx.path}) catch c.writeFailed();
            return true;
        },
        .printf => |f| {
            doPrintf(f, ctx) catch c.writeFailed();
            return true;
        },
        .ls => {
            doLs(ctx) catch c.writeFailed();
            return true;
        },
        .delete => {
            const st = c.sys.lstat(ctx.path) catch return false;
            if (c.eql(ctx.path, ".")) return true;
            const r = if (st.isDir()) c.sys.rmdir(ctx.path) else c.sys.unlink(ctx.path);
            r catch |e| {
                c.warn("cannot delete {f}: {s}", .{ c.q(ctx.path), c.strerror(e) });
                status = 1;
                return false;
            };
            return true;
        },
        .prune => {
            ctx.prune = true;
            return true;
        },
        .quit => {
            quit_now = true;
            return true;
        },
        .exec => |e| return doExec(e, ctx),
    }
}

fn replaceBraces(arg: []const u8, path: []const u8) []const u8 {
    if (mem.indexOf(u8, arg, "{}") == null) return arg;
    return mem.replaceOwned(u8, c.gpa, arg, "{}", path) catch c.oom();
}

fn runArgv(argv: []const []const u8, dir: ?[]const u8) u8 {
    c.flush();
    const pid = c.sys.fork() catch |e| {
        c.warn("cannot fork: {s}", .{c.strerror(e)});
        return 1;
    };
    if (pid == 0) {
        if (dir) |d| c.sys.chdir(d) catch |e| {
            c.warn("{f}: {s}", .{ c.q(d), c.strerror(e) });
            std.process.exit(1);
        };
        const e = c.execvp(argv, c.envp());
        c.warn("{f}: {s}", .{ c.q(argv[0]), c.strerror(e) });
        std.process.exit(if (e == error.NOENT) 127 else 126);
    }
    const r = c.sys.wait(pid, 0) catch return 1;
    return c.statusCode(r.status);
}

fn flushExec(e: *Exec) void {
    if (e.pending.items.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    for (e.argv[0 .. e.argv.len - 1]) |a| argv.append(c.gpa, a) catch c.oom();
    argv.appendSlice(c.gpa, e.pending.items) catch c.oom();
    const rc = runArgv(argv.items, if (e.dir) e.pending_dir else null);
    if (rc != 0) status = 1;
    e.pending.clearRetainingCapacity();
    e.pending_len = 0;
}

fn doExec(e: *Exec, ctx: *Ctx) bool {
    const dir_path = if (e.dir) c.dirname(ctx.path) else "";
    const target = if (e.dir) (std.fmt.allocPrint(c.gpa, "./{s}", .{if (ctx.name.len > 0) ctx.name else ctx.path}) catch c.oom()) else ctx.path;
    if (e.plus) {
        if (e.dir and e.pending.items.len > 0 and !c.eql(e.pending_dir, dir_path)) flushExec(e);
        e.pending_dir = dir_path;
        e.pending.append(c.gpa, c.gpa.dupe(u8, target) catch c.oom()) catch c.oom();
        e.pending_len += target.len + 1;
        if (e.pending_len > 100_000 or e.pending.items.len >= 4096) flushExec(e);
        return true;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    for (e.argv) |a| argv.append(c.gpa, replaceBraces(a, target)) catch c.oom();
    if (e.ok) {
        c.eprint("< {s} ... {s} > ? ", .{ argv.items[0], target });
        if (!c.yesno()) return false;
    }
    return runArgv(argv.items, if (e.dir) dir_path else null) == 0;
}

fn doLs(ctx: *Ctx) !void {
    const st = ctx.stat() orelse return;
    const w = c.out;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const blocks: u64 = (@as(u64, @intCast(@max(st.blocks, 0))) + 1) / 2;
    try w.print("{d: >9} {d: >6} {s} {d: >3} ", .{ st.ino, blocks, &c.modeString(st.mode), st.nlink });
    try c.padRight(w, c.userName(&b1, st.uid), 8);
    try w.writeByte(' ');
    try c.padRight(w, c.groupName(&b2, st.gid), 8);
    try w.writeByte(' ');
    const fmtc = st.mode & c.S_IFMT;
    if (fmtc == c.S_IFCHR or fmtc == c.S_IFBLK) {
        try w.print("{d: >3}, {d: >3} ", .{ c.devMajor(st.rdev), c.devMinor(st.rdev) });
    } else try w.print("{d: >8} ", .{st.size});
    const recent = now.sec - st.mtime.sec < 15778476 and st.mtime.sec <= now.sec;
    try c.strftime(w, if (recent) "%b %e %H:%M" else "%b %e  %Y", c.localtime(st.mtime.sec), 0, st.mtime.sec);
    try w.print(" {s}", .{ctx.path});
    if (st.isLnk()) {
        var lb: [c.PATH_MAX]u8 = undefined;
        if (c.sys.readlink(ctx.path, &lb)) |t| try w.print(" -> {s}", .{t}) else |_| {}
    }
    try w.writeByte('\n');
}

fn doPrintf(f: []const u8, ctx: *Ctx) !void {
    const pf = @import("printf.zig");
    const w = c.out;
    var i: usize = 0;
    while (i < f.len) {
        const ch = f[i];
        if (ch == '\\' and i + 1 < f.len) {
            if (f[i + 1] == 'c') return;
            var tmp: [8]u8 = undefined;
            const r = c.unescapeOne(f[i..], &tmp, false);
            try w.writeAll(r[0]);
            i += r[1];
            continue;
        }
        if (ch != '%' or i + 1 >= f.len) {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        if (f[i + 1] == '%') {
            try w.writeByte('%');
            i += 2;
            continue;
        }
        const ps = pf.parseSpecEx(f, i + 1, false) orelse {
            try w.writeAll(f[i..]);
            return;
        };
        var spec = ps.spec;
        var end = ps.end;
        const conv = spec.conv;
        var buf: std.Io.Writer.Allocating = .init(c.gpa);
        defer buf.deinit();
        const bw = &buf.writer;
        const st = ctx.stat();
        var nb: [32]u8 = undefined;
        switch (conv) {
            'p' => try bw.writeAll(ctx.path),
            'f' => try bw.writeAll(if (ctx.name.len > 0) ctx.name else ctx.path),
            'h' => {
                const d = if (mem.lastIndexOfScalar(u8, ctx.path, '/')) |k| (if (k == 0) "/" else ctx.path[0..k]) else ".";
                try bw.writeAll(d);
            },
            'P' => {
                var rel = ctx.path[@min(ctx.start.len, ctx.path.len)..];
                if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
                try bw.writeAll(rel);
            },
            'H' => try bw.writeAll(ctx.start),
            'd' => try bw.print("{d}", .{ctx.depth}),
            's' => try bw.print("{d}", .{if (st) |s| s.size else 0}),
            'k' => try bw.print("{d}", .{if (st) |s| @divFloor(s.blocks + 1, 2) else 0}),
            'b' => try bw.print("{d}", .{if (st) |s| s.blocks else 0}),
            'm' => try bw.print("{o}", .{if (st) |s| s.mode & 0o7777 else 0}),
            'M' => if (st) |s| try bw.writeAll(&c.modeString(s.mode)),
            'u' => if (st) |s| try bw.writeAll(c.userName(&nb, s.uid)),
            'g' => if (st) |s| try bw.writeAll(c.groupName(&nb, s.gid)),
            'U' => try bw.print("{d}", .{if (st) |s| s.uid else 0}),
            'G' => try bw.print("{d}", .{if (st) |s| s.gid else 0}),
            'i' => try bw.print("{d}", .{if (st) |s| s.ino else 0}),
            'n' => try bw.print("{d}", .{if (st) |s| s.nlink else 0}),
            'y' => if (st) |s| try bw.writeByte(typeChar(s.mode)),
            'Y' => {
                const ts: ?c.Stat = c.sys.stat(ctx.path) catch null;
                if (ts) |s| try bw.writeByte(typeChar(s.mode)) else try bw.writeByte('N');
            },
            'l' => if (st) |s| if (s.isLnk()) {
                var lb: [c.PATH_MAX]u8 = undefined;
                if (c.sys.readlink(ctx.path, &lb)) |t| try bw.writeAll(t) else |_| {}
            },
            'a', 'c', 't' => if (st) |s| {
                const t = switch (conv) {
                    'a' => s.atime,
                    'c' => s.ctime,
                    else => s.mtime,
                };
                try c.strftime(bw, "%a %b %e %H:%M:%S.%N0 %Y", c.localtime(t.sec), t.nsec, t.sec);
            },
            'A', 'C', 'T' => {
                if (end < f.len) {
                    const k = f[end];
                    end += 1;
                    if (st) |s| {
                        const t = switch (conv) {
                            'A' => s.atime,
                            'C' => s.ctime,
                            else => s.mtime,
                        };
                        if (k == '@') {
                            try bw.print("{d}.{d:0>9}0", .{ t.sec, @as(u64, @intCast(t.nsec)) });
                        } else {
                            const fmt2 = [2]u8{ '%', k };
                            try c.strftime(bw, &fmt2, c.localtime(t.sec), t.nsec, t.sec);
                        }
                    }
                }
            },
            else => {
                try w.writeAll(f[i..end]);
                i = end;
                continue;
            },
        }
        spec.conv = 's';
        try pf.fmtString(w, spec, buf.written());
        i = end;
    }
}

// ---------------------------------------------------------------------------
// Traversal
// ---------------------------------------------------------------------------

fn visit(expr: *Node, path: []const u8, name: []const u8, start: []const u8, depth: usize, root_dev: u64) void {
    if (quit_now) return;
    var ctx: Ctx = .{ .path = path, .name = name, .start = start, .depth = depth };
    const st = ctx.stat() orelse {
        const e = if (c.sys.lstat(path)) |_| error.ACCES else |x| x;
        c.warn("{f}: {s}", .{ c.q(path), c.strerror(e) });
        status = 1;
        return;
    };
    const in_range = depth >= min_depth;
    if (!depth_first and in_range) _ = eval(expr, &ctx);
    if (quit_now) return;
    const is_dir = st.isDir();
    if (is_dir and !ctx.prune and (max_depth == null or depth < max_depth.?)) {
        if (!(xdev and root_dev != 0 and st.dev != root_dev)) {
            const names = c.readDirNames(path) catch |e| blk: {
                c.warn("{f}: {s}", .{ c.q(path), c.strerror(e) });
                status = 1;
                break :blk &[_][]const u8{};
            };
            c.sortStrings(@constCast(names));
            defer if (names.len > 0) c.freeNames(@constCast(names));
            for (names) |n| {
                const full = c.join(path, n);
                defer c.gpa.free(full);
                visit(expr, full, n, start, depth + 1, if (root_dev == 0) st.dev else root_dev);
                if (quit_now) return;
            }
        }
    }
    if (depth_first and in_range) _ = eval(expr, &ctx);
}

pub fn main(args: c.Args) !u8 {
    var i: usize = 1;
    // leading options -H -L -P -O -D
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (c.eql(a, "--help")) c.printHelp();
        if (c.eql(a, "--version")) c.printVersion();
        if (c.eql(a, "--")) {
            i += 1;
            break;
        }
        if (c.eql(a, "-H")) {
            follow_cmd = true;
        } else if (c.eql(a, "-L")) {
            follow_all = true;
        } else if (c.eql(a, "-P")) {
            follow_all = false;
            follow_cmd = false;
        } else break;
    }
    var paths: std.ArrayList([]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((a.len > 1 and a[0] == '-') or c.eql(a, "!") or c.eql(a, "(")) break;
        try paths.append(c.gpa, a);
    }
    if (paths.items.len == 0) try paths.append(c.gpa, ".");
    now = c.now();
    var p: P = .{ .args = args[i..] };
    var expr: *Node = undefined;
    if (p.args.len == 0) {
        expr = P.node(.print);
    } else {
        expr = p.parseExpr();
        if (p.i < p.args.len) {
            const a = p.args[p.i];
            if (c.eql(a, ")")) c.fatal("invalid expression; you have too many ')'", .{});
            c.fatal("paths must precede expression: `{s}'", .{a});
        }
        if (!p.has_action) expr = P.node(.{ .and_ = .{ expr, P.node(.print) } });
    }
    for (paths.items) |path| {
        if (quit_now) break;
        visit(expr, path, c.basename(path), path, 0, 0);
    }
    for (execs.items) |e| if (e.plus) flushExec(e);
    return status;
}
