//! Matched-statistics pseudo-text generators.
//!
//! Anti-pareidolia track: any "found structure" claim must beat matched
//! pseudo-text. These generators produce strings with the same unigram /
//! bigram / trigram statistics as the source, but no higher-order structure.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sample n_chars from the source's unigram distribution.
pub fn unigramMatched(alloc: Allocator, source: []const u8, n_chars: usize, seed: u64) ![]u8 {
    if (source.len == 0) return alloc.alloc(u8, 0);
    var counts: [256]u64 = @splat(0);
    for (source) |c| counts[c] += 1;
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var cdf: [256]u64 = undefined;
    var total: u64 = 0;
    for (counts, 0..) |c, i| {
        total += c;
        cdf[i] = total;
    }
    const out = try alloc.alloc(u8, n_chars);
    for (out) |*ch| {
        const pick = r.intRangeLessThan(u64, 0, total);
        // Linear scan is fine for a 256-bucket CDF.
        var idx: usize = 0;
        while (idx < 256 and cdf[idx] <= pick) : (idx += 1) {}
        ch.* = @intCast(idx);
    }
    return out;
}

/// Sample n_chars from the empirical bigram transition matrix.
pub fn bigramMatched(alloc: Allocator, source: []const u8, n_chars: usize, seed: u64) ![]u8 {
    if (source.len < 2) return alloc.alloc(u8, 0);
    // trans[a] is a length-256 count vector of successors of byte a.
    var trans: [256][256]u64 = @splat(@splat(0));
    var prev: u8 = source[0];
    for (source[1..]) |c| {
        trans[prev][c] += 1;
        prev = c;
    }
    // Stationary distribution for restart: just unigram counts.
    var unigram: [256]u64 = @splat(0);
    for (source) |c| unigram[c] += 1;
    var unigram_total: u64 = 0;
    for (unigram) |c| unigram_total += c;

    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();

    var out = try alloc.alloc(u8, n_chars);
    if (n_chars == 0) return out;
    // First char from unigram.
    out[0] = sampleFromCounts(r, &unigram, unigram_total);
    var i: usize = 1;
    while (i < n_chars) : (i += 1) {
        const row = &trans[out[i - 1]];
        var row_total: u64 = 0;
        for (row) |c| row_total += c;
        if (row_total == 0) {
            out[i] = sampleFromCounts(r, &unigram, unigram_total);
        } else {
            out[i] = sampleFromCounts(r, row, row_total);
        }
    }
    return out;
}

/// Sample n_chars from the empirical trigram (Markov-2) transition table.
pub fn trigramMatched(alloc: Allocator, source: []const u8, n_chars: usize, seed: u64) ![]u8 {
    if (source.len < 3) return alloc.alloc(u8, 0);
    // 16-bit prefix key (a << 8 | b) → 256-vector of successors.
    var trans = std.AutoHashMap(u16, [256]u64).init(alloc);
    defer trans.deinit();
    var a: u8 = source[0];
    var b: u8 = source[1];
    for (source[2..]) |c| {
        const key: u16 = (@as(u16, a) << 8) | @as(u16, b);
        const gop = try trans.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = @splat(0);
        gop.value_ptr.*[c] += 1;
        a = b;
        b = c;
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var out = try alloc.alloc(u8, n_chars);
    if (n_chars == 0) return out;

    // Seed first two chars from a random bigram.
    var unigram: [256]u64 = @splat(0);
    for (source) |c| unigram[c] += 1;
    var unigram_total: u64 = 0;
    for (unigram) |c| unigram_total += c;
    out[0] = sampleFromCounts(r, &unigram, unigram_total);
    if (n_chars == 1) return out;
    out[1] = sampleFromCounts(r, &unigram, unigram_total);

    var i: usize = 2;
    while (i < n_chars) : (i += 1) {
        const key: u16 = (@as(u16, out[i - 2]) << 8) | @as(u16, out[i - 1]);
        const entry = trans.get(key);
        if (entry) |row| {
            var row_total: u64 = 0;
            for (row) |c| row_total += c;
            if (row_total == 0) {
                out[i] = sampleFromCounts(r, &unigram, unigram_total);
            } else {
                out[i] = sampleFromCounts(r, &row, row_total);
            }
        } else {
            out[i] = sampleFromCounts(r, &unigram, unigram_total);
        }
    }
    return out;
}

fn sampleFromCounts(r: std.Random, counts: *const [256]u64, total: u64) u8 {
    const pick = r.intRangeLessThan(u64, 0, total);
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        acc += counts[i];
        if (pick < acc) return @intCast(i);
    }
    return 255;
}

test "unigram_matched preserves length and alphabet" {
    const source = "abcabcabcabcabc";
    const out = try unigramMatched(std.testing.allocator, source, 200, 42);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 200), out.len);
    for (out) |c| {
        try std.testing.expect(c == 'a' or c == 'b' or c == 'c');
    }
}

test "bigram_matched deterministic given seed" {
    const source = "abracadabrabracadabra";
    const a = try bigramMatched(std.testing.allocator, source, 100, 7);
    defer std.testing.allocator.free(a);
    const b = try bigramMatched(std.testing.allocator, source, 100, 7);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "trigram_matched preserves length" {
    const source = "the quick brown fox jumps over the lazy dog " ** 10;
    const out = try trigramMatched(std.testing.allocator, source, 500, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 500), out.len);
}
