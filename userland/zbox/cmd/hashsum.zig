const std = @import("std");
const c = @import("../common.zig");
const mem = std.mem;
const crypto = std.crypto.hash;

pub const help_md5 = helpFor("md5sum", "MD5", "128");
pub const help_sha1 = helpFor("sha1sum", "SHA1", "160");
pub const help_sha256 = helpFor("sha256sum", "SHA256", "256");
pub const help_sha512 = helpFor("sha512sum", "SHA512", "512");

fn helpFor(comptime name: []const u8, comptime algo: []const u8, comptime bits: []const u8) []const u8 {
    return "Usage: " ++ name ++ " [OPTION]... [FILE]...\n" ++
        "Print or check " ++ algo ++ " (" ++ bits ++ "-bit) checksums.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n" ++
        \\  -b, --binary          read in binary mode
        \\  -c, --check           read checksums from the FILEs and check them
        \\      --tag             create a BSD-style checksum
        \\  -t, --text            read in text mode (default)
        \\  -z, --zero            end each output line with NUL, not newline,
        \\                          and disable file name escaping
        \\
        \\The following five options are useful only when verifying checksums:
        \\      --ignore-missing  don't fail or report status for missing files
        \\      --quiet           don't print OK for each successfully verified file
        \\      --status          don't output anything, status code shows success
        \\      --strict          exit non-zero for improperly formatted checksum lines
        \\  -w, --warn            warn about improperly formatted checksum lines
        \\
        ;
}

const Algo = enum { md5, sha1, sha256, sha512 };

fn algoName(a: Algo) []const u8 {
    return switch (a) {
        .md5 => "MD5",
        .sha1 => "SHA1",
        .sha256 => "SHA256",
        .sha512 => "SHA512",
    };
}

fn digestLen(a: Algo) usize {
    return switch (a) {
        .md5 => 16,
        .sha1 => 20,
        .sha256 => 32,
        .sha512 => 64,
    };
}

fn hashFd(a: Algo, fd: i32, out: []u8) !void {
    var buf: [65536]u8 = undefined;
    switch (a) {
        inline else => |alg| {
            const H = switch (alg) {
                .md5 => crypto.Md5,
                .sha1 => crypto.Sha1,
                .sha256 => crypto.sha2.Sha256,
                .sha512 => crypto.sha2.Sha512,
            };
            var h = H.init(.{});
            while (true) {
                const n = try c.sys.read(fd, &buf);
                if (n == 0) break;
                h.update(buf[0..n]);
            }
            var d: [H.digest_length]u8 = undefined;
            h.final(&d);
            @memcpy(out[0..H.digest_length], &d);
        },
    }
}

fn hexDigest(buf: []u8, d: []const u8) []const u8 {
    const hx = "0123456789abcdef";
    for (d, 0..) |b, i| {
        buf[2 * i] = hx[b >> 4];
        buf[2 * i + 1] = hx[b & 15];
    }
    return buf[0 .. 2 * d.len];
}

fn needsEscape(name: []const u8) bool {
    return mem.indexOfAny(u8, name, "\\\n\r") != null;
}

fn writeEscaped(w: *std.Io.Writer, name: []const u8) !void {
    for (name) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(ch),
    };
}

fn unescape(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            out.append(c.gpa, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                else => s[i],
            }) catch c.oom();
        } else out.append(c.gpa, s[i]) catch c.oom();
    }
    return out.items;
}

var binary = false;
var tag = false;
var zero = false;
var quiet = false;
var status_only = false;
var strict = false;
var warn_fmt = false;
var ignore_missing = false;

fn check(a: Algo, list_file: []const u8) !u8 {
    const data = c.readInput(list_file) orelse return 1;
    const w = c.out;
    var bad_format: usize = 0;
    var failed: usize = 0;
    var missing: usize = 0;
    var ok_count: usize = 0;
    var lines = mem.splitScalar(u8, data, '\n');
    var lineno: usize = 0;
    const dl = digestLen(a) * 2;
    while (lines.next()) |raw| {
        lineno += 1;
        if (raw.len == 0) continue;
        var line = raw;
        var escaped = false;
        if (line[0] == '\\') {
            escaped = true;
            line = line[1..];
        }
        var expect: []const u8 = undefined;
        var name: []const u8 = undefined;
        const an = algoName(a);
        if (mem.startsWith(u8, line, an) and line.len > an.len + 2 and line[an.len] == ' ' and line[an.len + 1] == '(') {
            const close = mem.lastIndexOf(u8, line, ") = ") orelse {
                bad_format += 1;
                continue;
            };
            name = line[an.len + 2 .. close];
            expect = line[close + 4 ..];
        } else {
            if (line.len < dl + 2 or line[dl] != ' ' or (line[dl + 1] != ' ' and line[dl + 1] != '*')) {
                bad_format += 1;
                if (warn_fmt) c.warn("{s}: {d}: improperly formatted {s} checksum line", .{ list_file, lineno, an });
                continue;
            }
            expect = line[0..dl];
            name = line[dl + 2 ..];
        }
        if (expect.len != dl) {
            bad_format += 1;
            continue;
        }
        if (escaped) name = unescape(name);
        const fd = (if (c.eql(name, "-")) @as(i32, 0) else c.sys.open(name, c.O_RDONLY, 0)) catch |e| {
            if (ignore_missing and e == error.NOENT) continue;
            missing += 1;
            if (!status_only) {
                c.warn("{s}: {s}", .{ name, c.strerror(e) });
                try w.print("{s}: FAILED open or read\n", .{name});
            }
            continue;
        };
        var d: [64]u8 = undefined;
        hashFd(a, fd, &d) catch |e| {
            c.closeInput(fd);
            missing += 1;
            if (!status_only) {
                c.warn("{s}: {s}", .{ name, c.strerror(e) });
                try w.print("{s}: FAILED open or read\n", .{name});
            }
            continue;
        };
        c.closeInput(fd);
        var hb: [128]u8 = undefined;
        const got = hexDigest(&hb, d[0..digestLen(a)]);
        if (std.ascii.eqlIgnoreCase(got, expect)) {
            ok_count += 1;
            if (!quiet and !status_only) try w.print("{s}: OK\n", .{name});
        } else {
            failed += 1;
            if (!status_only) try w.print("{s}: FAILED\n", .{name});
        }
    }
    if (ok_count + failed + missing == 0 and bad_format > 0) {
        c.warn("{s}: no properly formatted checksum lines found", .{list_file});
        return 1;
    }
    if (!status_only) {
        if (bad_format > 0) c.warn("WARNING: {d} line{s} {s} improperly formatted", .{ bad_format, if (bad_format == 1) "" else "s", if (bad_format == 1) "is" else "are" });
        if (missing > 0) c.warn("WARNING: {d} listed file{s} could not be read", .{ missing, if (missing == 1) "" else "s" });
        if (failed > 0) c.warn("WARNING: {d} computed checksum{s} did NOT match", .{ failed, if (failed == 1) "" else "s" });
    }
    if (failed > 0 or missing > 0 or (strict and bad_format > 0)) return 1;
    return 0;
}

fn run(a: Algo, args: c.Args) !u8 {
    var do_check = false;
    var files: std.ArrayList([]const u8) = .empty;
    var p = c.Parser.init(args, &.{
        .{ "binary", 'b' }, .{ "check", 'c' }, .{ "tag", 0 }, .{ "text", 't' }, .{ "zero", 'z' }, .{ "ignore-missing", 0 },
        .{ "quiet", 0 },    .{ "status", 0 },  .{ "strict", 0 }, .{ "warn", 'w' },
    });
    while (p.next()) |o| switch (o) {
        .short => |ch| switch (ch) {
            'b' => binary = true,
            'c' => do_check = true,
            't' => binary = false,
            'z' => zero = true,
            'w' => warn_fmt = true,
            else => p.bad(o),
        },
        .long => |n| {
            if (c.eql(n, "tag")) tag = true else if (c.eql(n, "ignore-missing")) ignore_missing = true else if (c.eql(n, "quiet")) quiet = true else if (c.eql(n, "status")) status_only = true else if (c.eql(n, "strict")) strict = true else p.bad(o);
        },
        .pos => |x| try files.append(c.gpa, x),
    };
    if (files.items.len == 0) try files.append(c.gpa, "-");
    var status: u8 = 0;
    if (do_check) {
        for (files.items) |f| {
            if (try check(a, f) != 0) status = 1;
        }
        return status;
    }
    const w = c.out;
    for (files.items) |f| {
        const fd = c.openInput(f) orelse {
            status = 1;
            continue;
        };
        var d: [64]u8 = undefined;
        hashFd(a, fd, &d) catch |e| {
            c.warn("{s}: {s}", .{ f, c.strerror(e) });
            c.closeInput(fd);
            status = 1;
            continue;
        };
        c.closeInput(fd);
        var hb: [128]u8 = undefined;
        const hex = hexDigest(&hb, d[0..digestLen(a)]);
        const esc = !zero and needsEscape(f);
        if (esc) try w.writeByte('\\');
        if (tag) {
            try w.print("{s} (", .{algoName(a)});
            if (esc) try writeEscaped(w, f) else try w.writeAll(f);
            try w.print(") = {s}", .{hex});
        } else {
            try w.print("{s} {c}", .{ hex, @as(u8, if (binary) '*' else ' ') });
            if (esc) try writeEscaped(w, f) else try w.writeAll(f);
        }
        try w.writeByte(if (zero) 0 else '\n');
    }
    return status;
}

pub fn mainMd5(args: c.Args) !u8 {
    return run(.md5, args);
}
pub fn mainSha1(args: c.Args) !u8 {
    return run(.sha1, args);
}
pub fn mainSha256(args: c.Args) !u8 {
    return run(.sha256, args);
}
pub fn mainSha512(args: c.Args) !u8 {
    return run(.sha512, args);
}
