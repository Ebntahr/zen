//! Kernel CSPRNG (ChaCha20-based) for getrandom(2), AT_RANDOM and the
//! `rand:` scheme. Seeded from the device-tree rng-seed, timer jitter and
//! anything user space writes to `rand:`.
const std = @import("std");
const riscv = @import("riscv.zig");

const Csprng = std.Random.ChaCha;

var rng: Csprng = undefined;
var seeded = false;

pub fn init(dt_seed: []const u8) void {
    var seed: [Csprng.secret_seed_length]u8 = [_]u8{0} ** Csprng.secret_seed_length;
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(dt_seed);
    // Timer jitter from a short busy loop.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const t = riscv.rdtime();
        h.update(std.mem.asBytes(&t));
    }
    h.final(&seed);
    rng = Csprng.init(seed);
    seeded = true;
}

pub fn bytes(out: []u8) void {
    if (!seeded) init("");
    rng.fill(out);
}

pub fn int(comptime T: type) T {
    var b: [@sizeOf(T)]u8 = undefined;
    bytes(&b);
    return std.mem.readInt(T, &b, .little);
}

/// Mix additional entropy (e.g. from a virtio-rng driver).
pub fn addEntropy(data: []const u8) void {
    rng.addEntropy(data);
}
