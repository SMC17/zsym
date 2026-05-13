//! Matched-statistics pseudo-text generators.
//!
//! Anti-pareidolia track: any "found structure" claim must beat matched
//! pseudo-text. These generators produce strings with the same unigram /
//! bigram / trigram statistics as the source, but no higher-order structure.
//!
//! Parallel `*Many` variants generate N samples in parallel. Each sample
//! is seeded independently from `base_seed +% sample_idx`, so the multiset
//! of samples is fixed by `base_seed` alone, regardless of `n_threads`.

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

/// Generator selector for the `*Many` parallel variants.
pub const Generator = enum { unigram, bigram, trigram };

/// Per-thread worker context for `generateMany`.
const ManyCtx = struct {
    next_idx: std.atomic.Value(usize),
    total: usize,
    source: []const u8,
    n_chars: usize,
    base_seed: u64,
    gen: Generator,
    out: [][]u8,
    errors: []?anyerror,
    parent_alloc: Allocator,
};

fn manyWorker(ctx: *ManyCtx) void {
    while (true) {
        const idx = ctx.next_idx.fetchAdd(1, .monotonic);
        if (idx >= ctx.total) return;
        const sample_seed = ctx.base_seed +% @as(u64, idx);
        const result: anyerror![]u8 = switch (ctx.gen) {
            .unigram => unigramMatched(ctx.parent_alloc, ctx.source, ctx.n_chars, sample_seed),
            .bigram => bigramMatched(ctx.parent_alloc, ctx.source, ctx.n_chars, sample_seed),
            .trigram => trigramMatched(ctx.parent_alloc, ctx.source, ctx.n_chars, sample_seed),
        };
        if (result) |buf| {
            ctx.out[idx] = buf;
        } else |e| {
            ctx.errors[idx] = e;
        }
    }
}

/// Generate `n_samples` pseudo-text samples in parallel using `gen`. Each
/// sample is seeded from `base_seed +% sample_idx`, so the multiset of
/// samples is fixed by `base_seed` regardless of `n_threads`.
///
/// `n_threads = null` → use `std.Thread.getCpuCount()`. `n_threads = 1`
/// forces serial execution.
///
/// Caller owns the outer slice and each inner slice; free them via
/// `freeMany(alloc, samples)`.
pub fn generateMany(
    alloc: Allocator,
    source: []const u8,
    n_chars: usize,
    n_samples: usize,
    base_seed: u64,
    gen: Generator,
    n_threads: ?usize,
) ![][]u8 {
    const out = try alloc.alloc([]u8, n_samples);
    errdefer alloc.free(out);
    if (n_samples == 0) return out;

    const errors = try alloc.alloc(?anyerror, n_samples);
    defer alloc.free(errors);
    @memset(errors, null);

    const requested_threads = n_threads orelse blk: {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk cpu_count;
    };
    const t = @min(@max(requested_threads, 1), n_samples);

    if (t <= 1) {
        for (out, 0..) |*slot, i| {
            const sample_seed = base_seed +% @as(u64, i);
            slot.* = switch (gen) {
                .unigram => try unigramMatched(alloc, source, n_chars, sample_seed),
                .bigram => try bigramMatched(alloc, source, n_chars, sample_seed),
                .trigram => try trigramMatched(alloc, source, n_chars, sample_seed),
            };
        }
        return out;
    }

    var ctx: ManyCtx = .{
        .next_idx = .init(0),
        .total = n_samples,
        .source = source,
        .n_chars = n_chars,
        .base_seed = base_seed,
        .gen = gen,
        .out = out,
        .errors = errors,
        .parent_alloc = alloc,
    };

    var threads_buf: [256]std.Thread = undefined;
    const threads = threads_buf[0..t];
    var spawned: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < spawned) : (k += 1) threads[k].join();
        // Free any successfully-allocated slots.
        for (out[0..n_samples], 0..) |slot, i| {
            if (errors[i] == null and i < spawned * 2) alloc.free(slot);
        }
    }
    while (spawned < t) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, manyWorker, .{&ctx});
    }
    var k: usize = 0;
    while (k < spawned) : (k += 1) threads[k].join();

    // Surface the first error (deterministic by index).
    for (errors) |e_opt| if (e_opt) |e| {
        // Free successfully-allocated slots before bailing.
        for (out, 0..) |slot, i| if (errors[i] == null) alloc.free(slot);
        alloc.free(out);
        return e;
    };
    return out;
}

/// Free a slice returned by `generateMany`.
pub fn freeMany(alloc: Allocator, samples: [][]u8) void {
    for (samples) |s| alloc.free(s);
    alloc.free(samples);
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

test "generateMany serial==parallel element-wise" {
    // Per-sample seeding `(base_seed +% idx)` means each output slot is a
    // pure function of (gen, source, n_chars, base_seed, idx) — so we get
    // bit-exact element-wise equality between serial and parallel runs.
    const source = "the quick brown fox jumps over the lazy dog " ** 5;

    inline for (.{ Generator.unigram, Generator.bigram, Generator.trigram }) |gen| {
        const serial = try generateMany(std.testing.allocator, source, 64, 11, 99, gen, 1);
        defer freeMany(std.testing.allocator, serial);
        const parallel = try generateMany(std.testing.allocator, source, 64, 11, 99, gen, 4);
        defer freeMany(std.testing.allocator, parallel);
        try std.testing.expectEqual(@as(usize, 11), serial.len);
        try std.testing.expectEqual(@as(usize, 11), parallel.len);
        for (serial, parallel) |s, p| try std.testing.expectEqualSlices(u8, s, p);
    }
}
