//! Politis-Romano stationary bootstrap.
//!
//! Resamples a sequence by concatenating blocks of geometric length L
//! starting at uniform random positions. The block length is geometric
//! with mean `mean_block_len`, which gives the result both stationarity
//! and the bootstrap consistency needed for time-series-like data.
//!
//! Reference: Politis & Romano 1994, "The Stationary Bootstrap",
//! Journal of the American Statistical Association 89(428):1303–1313.
//!
//! See also: `symbols/baselines/stationary_bootstrap.py` (Python sibling).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sample one bootstrap replicate of `source.len` bytes by concatenating
/// blocks of geometric length with parameter `p = 1.0 / mean_block_len`.
/// Block starts are uniform random; we wrap around the source.
pub fn sample(alloc: Allocator, source: []const u8, mean_block_len: usize, seed: u64) ![]u8 {
    if (source.len == 0) return alloc.alloc(u8, 0);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();

    const out = try alloc.alloc(u8, source.len);
    const p: f64 = 1.0 / @as(f64, @floatFromInt(mean_block_len));

    var w: usize = 0;
    while (w < out.len) {
        const start = r.uintLessThan(usize, source.len);
        var i: usize = 0;
        // Place at least one char from this block; extend with Bernoulli(p) ends.
        while (w < out.len) {
            out[w] = source[(start + i) % source.len];
            w += 1;
            i += 1;
            if (r.float(f64) < p) break;
        }
    }
    return out;
}

/// Return a slice of B bootstrap replicates, each `source.len` bytes.
/// Caller owns the outer slice; each inner slice is independently allocated.
pub fn distribution(
    alloc: Allocator,
    source: []const u8,
    mean_block_len: usize,
    b: usize,
    seed: u64,
) ![][]u8 {
    const out = try alloc.alloc([]u8, b);
    errdefer alloc.free(out);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (out, 0..) |*slot, i| {
        const inner_seed = r.int(u64);
        slot.* = try sample(alloc, source, mean_block_len, inner_seed);
        _ = i;
    }
    return out;
}

test "sample preserves length" {
    const src = "abracadabra" ** 100;
    const out = try sample(std.testing.allocator, src, 50, 42);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(src.len, out.len);
}

test "sample only emits source bytes" {
    const src = "abcabcabc";
    const out = try sample(std.testing.allocator, src, 4, 7);
    defer std.testing.allocator.free(out);
    for (out) |c| {
        try std.testing.expect(c == 'a' or c == 'b' or c == 'c');
    }
}

test "sample deterministic given seed" {
    const src = "the quick brown fox " ** 20;
    const a = try sample(std.testing.allocator, src, 30, 0);
    defer std.testing.allocator.free(a);
    const b = try sample(std.testing.allocator, src, 30, 0);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "sample with mean_block_len=1 approximates unigram resample" {
    // With p=1, every block is length 1: that's i.i.d. unigram resampling.
    // The empirical char distribution should match the source within sampling noise.
    const src = "aaaaabbbbb"; // 50/50 a/b
    const out = try sample(std.testing.allocator, src, 1, 12345);
    defer std.testing.allocator.free(out);
    var a_count: usize = 0;
    for (out) |c| if (c == 'a') {
        a_count += 1;
    };
    // 5/10 = 50%; with 10 draws expect roughly 5 a's, allow [2, 8].
    try std.testing.expect(a_count >= 2 and a_count <= 8);
}

test "distribution returns B independent samples" {
    const src = "the quick brown fox " ** 50;
    const samples = try distribution(std.testing.allocator, src, 20, 5, 9);
    defer {
        for (samples) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(samples);
    }
    try std.testing.expectEqual(@as(usize, 5), samples.len);
    // At least two samples should differ.
    var any_differ = false;
    if (samples.len >= 2) {
        any_differ = !std.mem.eql(u8, samples[0], samples[1]);
    }
    try std.testing.expect(any_differ);
}
