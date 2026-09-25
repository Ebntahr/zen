//! Finder's file model: locations (paths and URLs), directory listings,
//! sorting, human-readable formatting and the launch/trash/folder actions.
//!
//! A location is either a plain absolute path ("/Users/zen") or a URL
//! ("sys:proc", "sys:"). `file:` URLs are normalized to plain paths.

const std = @import("std");
const zen = @import("zen");
const abi = @import("abi");
const icons = @import("icons");

const posix = std.posix;
const linux = std.os.linux;

pub const max_path = 1024;

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

pub fn isUrl(loc: []const u8) bool {
    return zen.url.isUrl(loc);
}

/// Join a location and a child name into `out`.
pub fn join(out: []u8, loc: []const u8, name: []const u8) []const u8 {
    const sep = if (loc.len == 0 or loc[loc.len - 1] == '/' or loc[loc.len - 1] == ':') "" else "/";
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ loc, sep, name }) catch loc;
}

/// The enclosing location, or null at a root ("/" or "scheme:").
pub fn parent(loc: []const u8) ?[]const u8 {
    if (isUrl(loc)) {
        const colon = std.mem.indexOfScalar(u8, loc, ':').?;
        const path = std.mem.trimRight(u8, loc[colon + 1 ..], "/");
        if (path.len == 0) return null;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return loc[0 .. colon + 1];
        if (slash == 0) return loc[0 .. colon + 2];
        return loc[0 .. colon + 1 + slash];
    }
    const p = std.mem.trimRight(u8, loc, "/");
    if (p.len == 0) return null;
    const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return null;
    if (slash == 0) return "/";
    return p[0..slash];
}

/// Name of a location for the title bar and the "Go" history.
pub fn displayName(loc: []const u8) []const u8 {
    if (std.mem.eql(u8, loc, "/")) return "Zen HD";
    if (isUrl(loc)) {
        const colon = std.mem.indexOfScalar(u8, loc, ':').?;
        const path = std.mem.trimRight(u8, loc[colon + 1 ..], "/");
        if (path.len == 0) {
            if (std.mem.eql(u8, loc[0..colon], "sys")) return "System";
            return loc;
        }
        return std.fs.path.basename(path);
    }
    return std.fs.path.basename(loc);
}

/// Resolve user input ("~/Documents", "/etc", "sys:proc", "file:/tmp",
/// "Documents") relative to `current` into a canonical location in `out`.
pub fn resolve(out: []u8, input_raw: []const u8, current: []const u8, home: []const u8) ?[]const u8 {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    if (input.len == 0) return null;
    var tmp: [max_path]u8 = undefined;
    var path: []const u8 = input;
    if (std.mem.startsWith(u8, input, "file://")) {
        path = input[7..];
    } else if (std.mem.startsWith(u8, input, "file:")) {
        path = input[5..];
        if (path.len == 0) path = "/";
    } else if (isUrl(input)) {
        // Other schemes are passed through (collapse duplicate slashes).
        const colon = std.mem.indexOfScalar(u8, input, ':').?;
        const rest = std.mem.trim(u8, input[colon + 1 ..], "/");
        return std.fmt.bufPrint(out, "{s}:{s}", .{ input[0..colon], rest }) catch null;
    }
    if (std.mem.eql(u8, path, "~")) {
        path = home;
    } else if (std.mem.startsWith(u8, path, "~/")) {
        path = std.fmt.bufPrint(&tmp, "{s}/{s}", .{ home, path[2..] }) catch return null;
    } else if (path[0] != '/') {
        if (isUrl(current)) {
            return join(out, current, path);
        }
        path = std.fmt.bufPrint(&tmp, "{s}/{s}", .{ current, path }) catch return null;
    }
    const n = zen.url.normalize(path, out);
    return n;
}

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

pub const Kind = enum(u8) { folder, app, file, exec, link, other };

/// What icon an entry shows (also the icon cache key).
pub const IconId = packed struct(u32) {
    cat: Cat,
    variant: u8 = 0,
    _pad: u16 = 0,

    pub const Cat = enum(u8) { folder, document, app, exec, sys_folder, sys_file };
};

/// Special folder symbols embossed on folder icons.
pub const FolderMark = enum(u8) { none, home, desktop, documents, downloads, applications, pictures, music, movies, library, system, trash };

/// Document styles (document icon variant).
pub const DocStyle = enum(u8) { generic, text, code, markdown, image, pdf, archive, audio, video, data, config };

pub const Entry = struct {
    name: []const u8,
    display: []const u8,
    kind: Kind,
    is_link: bool = false,
    size: u64 = 0,
    mtime: i64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    icon: IconId,
    kind_label: []const u8,
    /// Icon-view label layout, computed lazily: first line [0, l1), second
    /// line [l2, l2 + l2_len) followed by an ellipsis when `l2_ellipsis`.
    lab_ready: bool = false,
    l1: u16 = 0,
    l2: u16 = 0,
    l2_len: u16 = 0,
    l2_ellipsis: bool = false,
    two_lines: bool = false,

    pub fn isDir(self: *const Entry) bool {
        return self.kind == .folder;
    }
};

const ext_table = [_]struct { []const u8, DocStyle, []const u8 }{
    .{ "txt", .text, "Plain Text Document" },
    .{ "text", .text, "Plain Text Document" },
    .{ "log", .text, "Log File" },
    .{ "md", .markdown, "Markdown Document" },
    .{ "markdown", .markdown, "Markdown Document" },
    .{ "rtf", .text, "Rich Text Document" },
    .{ "csv", .data, "CSV Document" },
    .{ "tsv", .data, "TSV Document" },
    .{ "json", .data, "JSON Document" },
    .{ "xml", .data, "XML Document" },
    .{ "conf", .config, "Configuration File" },
    .{ "cfg", .config, "Configuration File" },
    .{ "ini", .config, "Configuration File" },
    .{ "toml", .config, "TOML Document" },
    .{ "yaml", .config, "YAML Document" },
    .{ "yml", .config, "YAML Document" },
    .{ "zig", .code, "Zig Source" },
    .{ "zon", .code, "Zig Object Notation" },
    .{ "c", .code, "C Source" },
    .{ "h", .code, "C Header" },
    .{ "cpp", .code, "C++ Source" },
    .{ "cc", .code, "C++ Source" },
    .{ "hpp", .code, "C++ Header" },
    .{ "rs", .code, "Rust Source" },
    .{ "go", .code, "Go Source" },
    .{ "py", .code, "Python Script" },
    .{ "js", .code, "JavaScript" },
    .{ "ts", .code, "TypeScript" },
    .{ "sh", .code, "Shell Script" },
    .{ "html", .code, "HTML Document" },
    .{ "css", .code, "CSS Stylesheet" },
    .{ "s", .code, "Assembly Source" },
    .{ "ld", .code, "Linker Script" },
    .{ "png", .image, "PNG Image" },
    .{ "jpg", .image, "JPEG Image" },
    .{ "jpeg", .image, "JPEG Image" },
    .{ "gif", .image, "GIF Image" },
    .{ "bmp", .image, "BMP Image" },
    .{ "svg", .image, "SVG Image" },
    .{ "heic", .image, "HEIC Image" },
    .{ "webp", .image, "WebP Image" },
    .{ "pdf", .pdf, "PDF Document" },
    .{ "zip", .archive, "ZIP Archive" },
    .{ "tar", .archive, "Tar Archive" },
    .{ "gz", .archive, "Gzip Archive" },
    .{ "xz", .archive, "XZ Archive" },
    .{ "img", .archive, "Disk Image" },
    .{ "mp3", .audio, "MP3 Audio" },
    .{ "wav", .audio, "WAVE Audio" },
    .{ "flac", .audio, "FLAC Audio" },
    .{ "m4a", .audio, "MPEG-4 Audio" },
    .{ "mp4", .video, "MPEG-4 Movie" },
    .{ "mov", .video, "QuickTime Movie" },
    .{ "mkv", .video, "Matroska Video" },
};

pub fn extension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

pub fn docStyle(name: []const u8) struct { style: DocStyle, label: []const u8 } {
    const ext = extension(name);
    if (ext.len > 0) {
        for (ext_table) |e| {
            if (std.ascii.eqlIgnoreCase(e[0], ext)) return .{ .style = e[1], .label = e[2] };
        }
        return .{ .style = .generic, .label = "Document" };
    }
    return .{ .style = .generic, .label = "Document" };
}

/// Files that open in TextEdit.
pub fn isTextLike(e: *const Entry) bool {
    if (e.kind != .file) return false;
    const ext = extension(e.name);
    if (ext.len == 0) return true; // README, passwd, hosts, …
    return switch (docStyle(e.name).style) {
        .text, .code, .markdown, .data, .config => true,
        else => false,
    };
}

fn folderMark(loc: []const u8, name: []const u8, home: []const u8) FolderMark {
    if (std.mem.eql(u8, loc, "/")) {
        if (std.mem.eql(u8, name, "Applications")) return .applications;
        if (std.mem.eql(u8, name, "System")) return .system;
        if (std.mem.eql(u8, name, "Users")) return .home;
        if (std.mem.eql(u8, name, "Library")) return .library;
        return .none;
    }
    if (std.mem.eql(u8, loc, "/Users")) return .home;
    if (!std.mem.eql(u8, std.mem.trimRight(u8, loc, "/"), std.mem.trimRight(u8, home, "/"))) return .none;
    const map = [_]struct { []const u8, FolderMark }{
        .{ "Desktop", .desktop },           .{ "Documents", .documents }, .{ "Downloads", .downloads },
        .{ "Applications", .applications }, .{ "Pictures", .pictures },   .{ "Music", .music },
        .{ "Movies", .movies },             .{ "Library", .library },     .{ ".Trash", .trash },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return .none;
}

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},
    /// Why the folder could not be read.
    err: ?anyerror = null,
    /// Folder modification time when it was read (for refreshing).
    dir_mtime: i64 = 0,
    hidden_count: usize = 0,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

fn statAt(dirfd: posix.fd_t, name: []const u8, follow: bool) ?linux.Stat {
    var zbuf: [max_path]u8 = undefined;
    if (name.len >= zbuf.len) return null;
    @memcpy(zbuf[0..name.len], name);
    zbuf[name.len] = 0;
    var st: linux.Stat = std.mem.zeroes(linux.Stat);
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.fstatat(dirfd, @ptrCast(&zbuf), &st, flags);
    if (posix.errno(rc) != .SUCCESS) return null;
    return st;
}

pub fn statPath(path: []const u8) ?linux.Stat {
    return statAt(posix.AT.FDCWD, path, true);
}

pub fn mtimeOf(path: []const u8) i64 {
    const st = statPath(path) orelse return 0;
    return @intCast(st.mtime().sec);
}

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;
const S_IFREG: u32 = 0o100000;

/// Read a folder. Never fails: errors are recorded in `Listing.err`.
pub fn load(gpa: std.mem.Allocator, loc: []const u8, home: []const u8, show_hidden: bool) Listing {
    var listing = Listing{ .arena = std.heap.ArenaAllocator.init(gpa) };
    const a = listing.arena.allocator();
    var list: std.ArrayList(Entry) = .empty;
    loadInto(a, &list, &listing, loc, home, show_hidden) catch |err| {
        listing.err = err;
    };
    listing.entries = list.items;
    listing.dir_mtime = mtimeOf(loc);
    return listing;
}

fn loadInto(a: std.mem.Allocator, list: *std.ArrayList(Entry), listing: *Listing, loc: []const u8, home: []const u8, show_hidden: bool) !void {
    var dir = try std.fs.cwd().openDir(loc, .{ .iterate = true });
    defer dir.close();
    const system = isUrl(loc);
    var it = dir.iterate();
    var path_buf: [max_path]u8 = undefined;
    while (try it.next()) |de| {
        if (de.name.len == 0 or std.mem.eql(u8, de.name, ".") or std.mem.eql(u8, de.name, "..")) continue;
        if (de.name[0] == '.' and !show_hidden) {
            listing.hidden_count += 1;
            continue;
        }
        const name = try a.dupe(u8, de.name);
        var e = Entry{ .name = name, .display = name, .kind = .other, .icon = .{ .cat = .document }, .kind_label = "Document" };
        var is_dir = de.kind == .directory;
        if (statAt(dir.fd, de.name, false)) |st| {
            e.mode = st.mode;
            e.uid = st.uid;
            e.gid = st.gid;
            e.size = @intCast(@max(0, st.size));
            e.mtime = @intCast(st.mtime().sec);
            if (st.mode & S_IFMT == S_IFLNK) {
                e.is_link = true;
                if (statAt(dir.fd, de.name, true)) |t| {
                    is_dir = t.mode & S_IFMT == S_IFDIR;
                    if (!is_dir) e.size = @intCast(@max(0, t.size));
                } else is_dir = false;
            } else {
                is_dir = st.mode & S_IFMT == S_IFDIR;
            }
        } else if (de.kind == .sym_link) {
            e.is_link = true;
        }

        if (is_dir) {
            e.kind = .folder;
            e.kind_label = "Folder";
            e.icon = .{ .cat = if (system) .sys_folder else .folder, .variant = @intFromEnum(folderMark(loc, name, home)) };
            if (std.mem.endsWith(u8, name, ".app") and name.len > 4) {
                e.kind = .app;
                e.kind_label = "Application";
                e.display = name[0 .. name.len - 4];
                const full = join(&path_buf, loc, name);
                var icon: icons.AppIcon = .generic;
                if (zen.bundle.load(a, full)) |b| {
                    var bb = b;
                    icon = icons.AppIcon.fromName(b.info.icon);
                    if (icon == .generic and std.ascii.eqlIgnoreCase(b.info.id, "com.zen.ActivityMonitor")) icon = .activity;
                    bb.deinit();
                } else |_| {}
                e.icon = .{ .cat = .app, .variant = @intFromEnum(icon) };
            }
        } else if (system) {
            e.kind = .file;
            e.kind_label = "System File";
            e.icon = .{ .cat = .sys_file };
        } else {
            const ds = docStyle(name);
            e.kind = .file;
            e.kind_label = ds.label;
            e.icon = .{ .cat = .document, .variant = @intFromEnum(ds.style) };
            if (e.mode & 0o111 != 0 and extension(name).len == 0 and e.mode & S_IFMT == S_IFREG) {
                e.kind = .exec;
                e.kind_label = "Unix Executable File";
                e.icon = .{ .cat = .exec };
            }
        }
        if (e.is_link) {
            e.kind_label = if (is_dir) "Alias (Folder)" else "Alias";
        }
        try list.append(a, e);
    }
}

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

pub const SortKey = enum { name, date, size, kind };

/// Case-insensitive comparison with digit runs compared numerically
/// ("file2" < "file10"), like Finder.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    return naturalOrder(a, b) == .lt;
}

pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const na = std.mem.trimLeft(u8, a[i..ie], "0");
            const nb = std.mem.trimLeft(u8, b[j..je], "0");
            if (na.len != nb.len) return std.math.order(na.len, nb.len);
            const o = std.mem.order(u8, na, nb);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return std.math.order(la, lb);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

pub const SortCtx = struct {
    entries: []const Entry,
    key: SortKey,
    ascending: bool,

    pub fn less(ctx: SortCtx, ia: u32, ib: u32) bool {
        const a = &ctx.entries[ia];
        const b = &ctx.entries[ib];
        const o: std.math.Order = switch (ctx.key) {
            .name => naturalOrder(a.display, b.display),
            .date => std.math.order(a.mtime, b.mtime),
            .size => blk: {
                // Folders have no size: keep them together at the small end.
                const sa: u64 = if (a.kind == .folder) 0 else a.size + 1;
                const sb: u64 = if (b.kind == .folder) 0 else b.size + 1;
                break :blk std.math.order(sa, sb);
            },
            .kind => std.mem.order(u8, a.kind_label, b.kind_label),
        };
        const final = if (o == .eq) naturalOrder(a.display, b.display) else o;
        return if (ctx.ascending or o == .eq) final == .lt else final == .gt;
    }
};

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/// Finder-style sizes (decimal units): "Zero bytes", "812 bytes", "4 KB", "1.2 MB".
pub fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size == 0) return "Zero bytes";
    if (size < 1000) return std.fmt.bufPrint(buf, "{d} bytes", .{size}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(size);
    var u: usize = 0;
    v /= 1000;
    while (v >= 999.95 and u + 1 < units.len) : (u += 1) v /= 1000;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} KB", .{@as(u64, @intFromFloat(@round(v)))}) catch "";
    if (v >= 100) return std.fmt.bufPrint(buf, "{d} {s}", .{ @as(u64, @intFromFloat(@round(v))), units[u] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
}

pub fn formatBytesLong(buf: []u8, size: u64) []const u8 {
    var sb: [32]u8 = undefined;
    const short = formatSize(&sb, size);
    if (size < 1000) return std.fmt.bufPrint(buf, "{s}", .{short}) catch "";
    var digits: [32]u8 = undefined;
    const d = groupDigits(&digits, size);
    return std.fmt.bufPrint(buf, "{s} ({s} bytes)", .{ short, d }) catch "";
}

fn groupDigits(buf: []u8, v: u64) []const u8 {
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

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const DayTime = struct { day: i64, year: u16, month: u8, mday: u8, hour: u8, minute: u8 };

pub fn splitTime(t: i64) DayTime {
    const secs: u64 = @intCast(@max(0, t));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .day = @intCast(ed.day),
        .year = yd.year,
        .month = @intFromEnum(md.month),
        .mday = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
    };
}

/// "Today at 2:05 PM", "Yesterday at 9:41 AM", "Sep 21, 2026 at 10:02 AM".
pub fn formatDate(buf: []u8, t: i64, now: i64) []const u8 {
    if (t <= 0) return "--";
    const d = splitTime(t);
    const n = splitTime(now);
    const h12: u8 = if (d.hour % 12 == 0) 12 else d.hour % 12;
    const ampm = if (d.hour < 12) "AM" else "PM";
    if (d.day == n.day) return std.fmt.bufPrint(buf, "Today at {d}:{d:0>2} {s}", .{ h12, d.minute, ampm }) catch "";
    if (d.day + 1 == n.day) return std.fmt.bufPrint(buf, "Yesterday at {d}:{d:0>2} {s}", .{ h12, d.minute, ampm }) catch "";
    return std.fmt.bufPrint(buf, "{s} {d}, {d} at {d}:{d:0>2} {s}", .{ month_names[d.month - 1], d.mday, d.year, h12, d.minute, ampm }) catch "";
}

/// "drwxr-xr-x".
pub fn permString(buf: *[10]u8, mode: u32, kind: Kind, is_link: bool) []const u8 {
    buf[0] = if (is_link) 'l' else if (kind == .folder or kind == .app) 'd' else '-';
    const bits = "rwxrwxrwx";
    for (0..9) |i| {
        const mask: u32 = @as(u32, 1) << @intCast(8 - i);
        buf[1 + i] = if (mode & mask != 0) bits[i] else '-';
    }
    return buf[0..];
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Free space of the volume holding `path` (statfs), in bytes.
pub fn freeBytes(path: []const u8) ?u64 {
    var zbuf: [max_path]u8 = undefined;
    if (path.len >= zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    var st: abi.scheme.Statfs = .{};
    const rc = linux.syscall2(.statfs, @intFromPtr(&zbuf), @intFromPtr(&st));
    if (posix.errno(rc) != .SUCCESS) return null;
    if (st.bsize <= 0) return null;
    return st.bavail * @as(u64, @intCast(st.bsize));
}

/// Send a command to launchd (`launch:ctl`) and return its reply line.
pub fn launchCtl(cmd: []const u8, reply: []u8) ![]const u8 {
    const fd = posix.open("launch:ctl", .{ .ACCMODE = .RDWR }, 0) catch return error.LaunchServiceUnavailable;
    defer posix.close(fd);
    var off: usize = 0;
    while (off < cmd.len) off += try posix.write(fd, cmd[off..]);
    var n: usize = 0;
    while (n < reply.len) {
        const got = posix.read(fd, reply[n..]) catch break;
        if (got == 0) break;
        n += got;
        if (std.mem.indexOfScalar(u8, reply[0..n], '\n') != null) break;
    }
    return std.mem.trim(u8, reply[0..n], " \r\n");
}

/// A name in `dir` that does not exist yet: "base", "base 2", "base 3"…
pub fn uniqueName(out: []u8, dir: []const u8, base: []const u8) []const u8 {
    var pb: [max_path]u8 = undefined;
    const stem_end = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| (if (d == 0) base.len else d) else base.len;
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const name = if (i == 1)
            std.fmt.bufPrint(out, "{s}", .{base}) catch return base
        else
            std.fmt.bufPrint(out, "{s} {d}{s}", .{ base[0..stem_end], i, base[stem_end..] }) catch return base;
        const full = join(&pb, dir, name);
        if (statAt(posix.AT.FDCWD, full, false) == null) return name;
    }
    return base;
}

/// Create "untitled folder" (or "untitled folder N") in `dir`; returns its name.
pub fn newFolder(out: []u8, dir: []const u8) ![]const u8 {
    const name = uniqueName(out, dir, "untitled folder");
    var pb: [max_path]u8 = undefined;
    try std.fs.cwd().makeDir(join(&pb, dir, name));
    return name;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    return true;
}

pub fn rename(dir: []const u8, old: []const u8, new: []const u8) !void {
    if (!validName(new)) return error.InvalidName;
    if (std.mem.eql(u8, old, new)) return;
    var a: [max_path]u8 = undefined;
    var b: [max_path]u8 = undefined;
    const dst = join(&b, dir, new);
    if (statAt(posix.AT.FDCWD, dst, false) != null) return error.PathAlreadyExists;
    try std.fs.cwd().rename(join(&a, dir, old), dst);
}

/// Move `dir/name` into `home/.Trash` (renaming on conflicts).
pub fn moveToTrash(dir: []const u8, name: []const u8, home: []const u8) !void {
    var tb: [max_path]u8 = undefined;
    const trash = std.fmt.bufPrint(&tb, "{s}/.Trash", .{std.mem.trimRight(u8, home, "/")}) catch return error.NameTooLong;
    if (std.mem.startsWith(u8, dir, trash)) return error.AlreadyInTrash;
    std.fs.cwd().makePath(trash) catch {};
    var nb: [256]u8 = undefined;
    const target = uniqueName(&nb, trash, name);
    var a: [max_path]u8 = undefined;
    var b: [max_path]u8 = undefined;
    try std.fs.cwd().rename(join(&a, dir, name), join(&b, trash, target));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "locations" {
    try std.testing.expectEqualStrings("/Users", parent("/Users/zen").?);
    try std.testing.expectEqualStrings("/", parent("/Users").?);
    try std.testing.expect(parent("/") == null);
    try std.testing.expectEqualStrings("sys:", parent("sys:proc").?);
    try std.testing.expectEqualStrings("sys:proc", parent("sys:proc/12").?);
    try std.testing.expect(parent("sys:") == null);
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("sys:proc", join(&b, "sys:", "proc"));
    try std.testing.expectEqualStrings("/etc", join(&b, "/", "etc"));
    try std.testing.expectEqualStrings("/a/b", join(&b, "/a", "b"));
    try std.testing.expectEqualStrings("/Users/zen/Documents", resolve(&b, "~/Documents", "/", "/Users/zen").?);
    try std.testing.expectEqualStrings("/etc", resolve(&b, "file:/etc/", "/", "/Users/zen").?);
    try std.testing.expectEqualStrings("sys:proc", resolve(&b, "sys:proc", "/", "/Users/zen").?);
    try std.testing.expectEqualStrings("/Users", resolve(&b, "..", "/Users/zen", "/Users/zen").?);
    try std.testing.expectEqualStrings("System", displayName("sys:"));
    try std.testing.expectEqualStrings("Zen HD", displayName("/"));
}

test "natural order and formatting" {
    try std.testing.expect(naturalLess("file2", "file10"));
    try std.testing.expect(naturalLess("apple", "Banana"));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("4 KB", formatSize(&b, 4096));
    try std.testing.expectEqualStrings("1.2 MB", formatSize(&b, 1_200_000));
    try std.testing.expectEqualStrings("812 bytes", formatSize(&b, 812));
    var p: [10]u8 = undefined;
    try std.testing.expectEqualStrings("drwxr-xr-x", permString(&p, 0o40755, .folder, false));
}
