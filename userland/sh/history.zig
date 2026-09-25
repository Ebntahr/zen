//! Command history with persistence in ~/.zensh_history.
//! Multi-line entries are stored with each embedded newline written as a
//! backslash-newline pair.
const std = @import("std");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const History = struct {
    items: std.ArrayList([]u8) = .empty,
    max: usize = 1000,
    file_max: usize = 2000,
    /// number of entries dropped from the front (for numbering)
    base: usize = 0,
    path: ?[]u8 = null,

    pub fn add(self: *History, gpa: Allocator, line_in: []const u8) void {
        const line = std.mem.trimRight(u8, line_in, "\n");
        if (line.len == 0) return;
        if (line[0] == ' ') return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], line)) return;
        const copy = gpa.dupe(u8, line) catch return;
        self.items.append(gpa, copy) catch {
            gpa.free(copy);
            return;
        };
        self.trim(gpa);
        if (self.path) |p| appendToFile(p, line);
    }

    fn trim(self: *History, gpa: Allocator) void {
        while (self.items.items.len > self.max and self.items.items.len > 0) {
            gpa.free(self.items.orderedRemove(0));
            self.base += 1;
        }
    }

    pub fn clear(self: *History, gpa: Allocator) void {
        for (self.items.items) |s| gpa.free(s);
        self.items.clearRetainingCapacity();
        self.base = 0;
    }

    pub fn load(self: *History, gpa: Allocator, path: []const u8) void {
        self.path = gpa.dupe(u8, path) catch return;
        const fd = sys.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
        defer sys.close(fd);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = sys.read(fd, &buf) catch break;
            if (n == 0) break;
            data.appendSlice(gpa, buf[0..n]) catch break;
        }
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(gpa);
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, data.items, '\n');
        while (lines.next()) |l| {
            if (l.len > 0 and l[l.len - 1] == '\\') {
                entry.appendSlice(gpa, l[0 .. l.len - 1]) catch break;
                entry.append(gpa, '\n') catch break;
                continue;
            }
            entry.appendSlice(gpa, l) catch break;
            if (entry.items.len > 0) {
                const copy = gpa.dupe(u8, entry.items) catch break;
                self.items.append(gpa, copy) catch break;
                count += 1;
            }
            entry.clearRetainingCapacity();
        }
        // keep only the newest entries in memory; rewrite the file if it
        // grew too large
        if (count > self.file_max) self.rewrite(gpa);
        self.trim(gpa);
    }

    fn rewrite(self: *History, gpa: Allocator) void {
        const p = self.path orelse return;
        const start = if (self.items.items.len > self.file_max) self.items.items.len - self.file_max else 0;
        const fd = sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600) catch return;
        defer sys.close(fd);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (self.items.items[start..]) |e| {
            encode(gpa, &out, e) catch return;
        }
        sys.writeAll(fd, out.items) catch {};
    }

    pub fn get(self: *History, i: usize) []const u8 {
        return self.items.items[i];
    }

    pub fn len(self: *History) usize {
        return self.items.items.len;
    }
};

fn encode(gpa: Allocator, out: *std.ArrayList(u8), e: []const u8) !void {
    for (e) |c| {
        if (c == '\n') {
            try out.appendSlice(gpa, "\\\n");
        } else try out.append(gpa, c);
    }
    try out.append(gpa, '\n');
}

fn appendToFile(path: []const u8, line: []const u8) void {
    const fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600) catch return;
    defer sys.close(fd);
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var out: std.ArrayList(u8) = .empty;
    encode(fba.allocator(), &out, line) catch {
        // too long for the stack buffer: write piecewise
        var it = std.mem.splitScalar(u8, line, '\n');
        var first = true;
        while (it.next()) |part| {
            if (!first) sys.writeAll(fd, "\\\n") catch return;
            first = false;
            sys.writeAll(fd, part) catch return;
        }
        sys.writeAll(fd, "\n") catch {};
        return;
    };
    sys.writeAll(fd, out.items) catch {};
}
