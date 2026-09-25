//! System fonts: Inter for the interface, JetBrains Mono for code.
//! Fonts are loaded from /System/Library/Fonts on Zen, or from
//! $ZEN_FONT_DIR / ./assets/fonts on a development host.

const std = @import("std");
const font = @import("font");

pub const Weight = enum(u3) { regular = 0, medium = 1, semibold = 2, bold = 3, mono = 4, mono_bold = 5 };

const files = [_][]const u8{
    "Inter-Regular.ttf",
    "Inter-Medium.ttf",
    "Inter-SemiBold.ttf",
    "Inter-Bold.ttf",
    "JetBrainsMono-Regular.ttf",
    "JetBrainsMono-Bold.ttf",
    // Arabic fallbacks (indices 6..8): regular, semibold, bold.
    "NotoSansArabic-Regular.ttf",
    "NotoSansArabic-SemiBold.ttf",
    "NotoSansArabic-Bold.ttf",
};

const search_dirs = [_][]const u8{ "/System/Library/Fonts", "assets/fonts", "../assets/fonts" };

pub const FontSet = struct {
    allocator: std.mem.Allocator,
    data: [files.len]?[]u8 = [_]?[]u8{null} ** files.len,
    fonts: [files.len]?*font.Font = [_]?*font.Font{null} ** files.len,
    faces: std.AutoHashMapUnmanaged(u32, *font.Face) = .empty,

    pub fn load(allocator: std.mem.Allocator) !FontSet {
        var set = FontSet{ .allocator = allocator };
        errdefer set.deinit();
        const env_dir = std.posix.getenv("ZEN_FONT_DIR");
        for (files, 0..) |name, i| {
            var loaded = false;
            if (env_dir) |d| loaded = set.tryLoad(i, d, name);
            for (search_dirs) |d| {
                if (loaded) break;
                loaded = set.tryLoad(i, d, name);
            }
        }
        if (set.fonts[0] == null) return error.FontNotFound;
        return set;
    }

    fn tryLoad(self: *FontSet, i: usize, dir: []const u8, name: []const u8) bool {
        const path = std.fs.path.join(self.allocator, &.{ dir, name }) catch return false;
        defer self.allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, path, 16 << 20) catch return false;
        const f = self.allocator.create(font.Font) catch {
            self.allocator.free(bytes);
            return false;
        };
        f.* = font.Font.init(self.allocator, bytes) catch {
            self.allocator.destroy(f);
            self.allocator.free(bytes);
            return false;
        };
        self.data[i] = bytes;
        self.fonts[i] = f;
        return true;
    }

    pub fn deinit(self: *FontSet) void {
        var it = self.faces.valueIterator();
        while (it.next()) |f| {
            f.*.deinit();
            self.allocator.destroy(f.*);
        }
        self.faces.deinit(self.allocator);
        for (self.fonts, self.data) |f, d| {
            if (f) |ff| {
                ff.deinit();
                self.allocator.destroy(ff);
            }
            if (d) |dd| self.allocator.free(dd);
        }
    }

    /// A face for `weight` at `size` pixels (cached).
    pub fn face(self: *FontSet, weight: Weight, size: f32) *font.Face {
        var idx: usize = @intFromEnum(weight);
        if (self.fonts[idx] == null) idx = if (idx >= 4) 0 else 0;
        const q: u32 = @intFromFloat(@max(1, @round(size * 4)));
        const key: u32 = (@as(u32, @intCast(idx)) << 24) | q;
        if (self.faces.get(key)) |f| return f;
        const f = self.allocator.create(font.Face) catch @panic("out of memory");
        f.* = font.Face.init(self.allocator, self.fonts[idx].?, @as(f32, @floatFromInt(q)) / 4, .{}) catch @panic("bad font size");
        // Mono faces fall back to Inter for symbols; Inter falls back to
        // Noto Sans Arabic for Arabic script.
        if ((idx == 4 or idx == 5) and self.fonts[0] != null) {
            f.fallback = self.face(.regular, size);
        } else if (idx < 4) {
            const ar: usize = switch (idx) {
                0, 1 => 6,
                2 => 7,
                else => 8,
            };
            f.fallback = self.rawFace(ar, size);
        }
        self.faces.put(self.allocator, key, f) catch @panic("out of memory");
        return f;
    }

    /// A face for font file `idx` without fallbacks (null if not loaded).
    fn rawFace(self: *FontSet, idx: usize, size: f32) ?*font.Face {
        const ff = self.fonts[idx] orelse return null;
        const q: u32 = @intFromFloat(@max(1, @round(size * 4)));
        const key: u32 = (@as(u32, @intCast(idx)) << 24) | q;
        if (self.faces.get(key)) |f| return f;
        const f = self.allocator.create(font.Face) catch return null;
        f.* = font.Face.init(self.allocator, ff, @as(f32, @floatFromInt(q)) / 4, .{}) catch {
            self.allocator.destroy(f);
            return null;
        };
        self.faces.put(self.allocator, key, f) catch return null;
        return f;
    }

    pub fn ui(self: *FontSet, size: f32) *font.Face {
        return self.face(.regular, size);
    }

    pub fn mono(self: *FontSet, size: f32) *font.Face {
        return self.face(.mono, size);
    }
};

test "load fonts from the repository" {
    var set = FontSet.load(std.testing.allocator) catch return error.SkipZigTest;
    defer set.deinit();
    const f = set.face(.semibold, 13);
    try std.testing.expect(f.measure("Hello") > 20);
    try std.testing.expect(set.face(.semibold, 13) == f);
    try std.testing.expect(set.mono(12).measure("abc") > 10);
}
