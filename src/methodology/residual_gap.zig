//! Paired residual gzip-bpc gap with stationary-bootstrap CIs (PR-A protocol).
//!
//! This module is the methodology-level glue behind F7 (Voynich / Linear A /
//! Rongorongo cross-corpus residual gap). It composes four pre-existing
//! primitives — `compress.gzipBitsPerByte`, `pseudo.trigramMatched`,
//! `stationary_bootstrap.sample`, and a percentile aggregator — into a single
//! computation that returns the paired residual distribution + percentile CI.
//!
//! Protocol (per Politis & Romano 1994 + PR-A pre-registration in the parent
//! `symbols` repo):
//!
//!   for i in 0 .. B-1:
//!     real_i   = stationary_bootstrap.sample(source, mean_block_len,
//!                                            seed +% (2*i + 0))
//!     pseudo_i = pseudo.trigramMatched(real_i, real_i.len,
//!                                     seed +% (2*i + 1))
//!     g_real_i   = gzipBitsPerByte(real_i)
//!     g_pseudo_i = gzipBitsPerByte(pseudo_i)
//!     residual_i = g_pseudo_i − g_real_i
//!   mean_residual = mean(residuals)
//!   ci_low, ci_high = percentile(residuals, 2.5), percentile(residuals, 97.5)
//!
//! Convention: positive residual ⇒ real text compresses *better* than the
//! trigram-matched null ⇒ structure beyond trigrams that gzip exploits.
//!
//! The per-replicate seed pair `(seed +% 2i, seed +% 2i+1)` is a pure function
//! of `(seed, i)`, so the multiset of residuals is fixed by `seed` regardless
//! of execution order. This is the same determinism discipline used elsewhere
//! in the substrate (stationary_bootstrap.distribution, pseudo.generateMany).
//!
//! `seed +% 2*i+1` (the pseudo seed) is the same seed slot used by the Python
//! `_paired_pseudo_gzip(text, seed)` helper in
//! `scripts/bootstrap_residual_gap_stationary.py`; the byte-exact pseudo
//! output still differs across substrates (Python `random.Random` vs Zig
//! `std.Random.DefaultPrng`), but the residual mean is the comparable
//! quantity, not byte-exact pseudo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const compress = @import("../baselines/compress.zig");
const pseudo = @import("../data/pseudo.zig");
const stationary_bootstrap = @import("../baselines/stationary_bootstrap.zig");

/// Full result of one PR-A run. Caller owns `residuals`, `real_gzip_bpc`, and
/// `pseudo_gzip_bpc` slices — call `deinit(alloc)` to free.
pub const ResidualResult = struct {
    /// Number of bootstrap replicates actually run.
    b: usize,
    /// Mean stationary-bootstrap block length used.
    mean_block_len: usize,
    /// gzip bits/byte of the unresampled source (the "point estimate").
    point_real_gzip: f64,
    /// Mean of per-replicate real-resample gzip bpc.
    mean_real: f64,
    /// Mean of per-replicate trigram-matched-pseudo gzip bpc.
    mean_pseudo: f64,
    /// Mean of per-replicate residual = pseudo − real.
    mean_residual: f64,
    /// Sample standard deviation (n−1 denom) of the residual distribution.
    std_residual: f64,
    /// 2.5th-percentile of the residual distribution.
    ci_low: f64,
    /// 97.5th-percentile of the residual distribution.
    ci_high: f64,
    /// Per-replicate residuals, indexed 0..b.
    residuals: []f64,
    /// Per-replicate real-resample gzip bpc.
    real_gzip_bpc: []f64,
    /// Per-replicate paired-pseudo gzip bpc.
    pseudo_gzip_bpc: []f64,

    pub fn deinit(self: *ResidualResult, alloc: Allocator) void {
        alloc.free(self.residuals);
        alloc.free(self.real_gzip_bpc);
        alloc.free(self.pseudo_gzip_bpc);
    }

    /// CI excludes zero on either side (sign-consistent endpoints).
    pub fn ciExcludesZero(self: ResidualResult) bool {
        return (self.ci_low > 0.0 and self.ci_high > 0.0) or
            (self.ci_low < 0.0 and self.ci_high < 0.0);
    }
};

/// Compute paired residual gzip-bpc gap with stationary-bootstrap CIs.
///
/// - `source`: the corpus to test (raw bytes, character-level encoding).
/// - `mean_block_len`: geometric block length for the stationary bootstrap.
///   PR-A headline uses L = 100 for character corpora.
/// - `b`: number of bootstrap replicates. PR-A headline uses B = 200.
/// - `seed`: master seed; per-replicate seeds derived deterministically.
///
/// Returns a `ResidualResult`; caller owns its slices via `deinit`.
pub fn pairedResidual(
    alloc: Allocator,
    source: []const u8,
    mean_block_len: usize,
    b: usize,
    seed: u64,
) !ResidualResult {
    if (b == 0) return error.ZeroReplicates;
    if (mean_block_len == 0) return error.ZeroBlockLength;
    if (source.len < 3) return error.SourceTooShort;

    const residuals = try alloc.alloc(f64, b);
    errdefer alloc.free(residuals);
    const real_g = try alloc.alloc(f64, b);
    errdefer alloc.free(real_g);
    const pseudo_g = try alloc.alloc(f64, b);
    errdefer alloc.free(pseudo_g);

    var i: usize = 0;
    while (i < b) : (i += 1) {
        const real_seed: u64 = seed +% (@as(u64, i) *% 2);
        const pseu_seed: u64 = seed +% (@as(u64, i) *% 2 +% 1);

        const real_sample = try stationary_bootstrap.sample(alloc, source, mean_block_len, real_seed);
        defer alloc.free(real_sample);

        const pseu_sample = try pseudo.trigramMatched(alloc, real_sample, real_sample.len, pseu_seed);
        defer alloc.free(pseu_sample);

        const g_real = try compress.gzipBitsPerByte(alloc, real_sample);
        const g_pseu = try compress.gzipBitsPerByte(alloc, pseu_sample);

        real_g[i] = g_real;
        pseudo_g[i] = g_pseu;
        residuals[i] = g_pseu - g_real;
    }

    const point_real = try compress.gzipBitsPerByte(alloc, source);

    const mean_real = meanF64(real_g);
    const mean_pseu = meanF64(pseudo_g);
    const mean_res = meanF64(residuals);
    const std_res = stdF64(residuals, mean_res);

    // Compute percentile CI on a sorted copy so caller-visible `residuals`
    // preserves the per-replicate index order (important for audit).
    const sorted = try alloc.alloc(f64, residuals.len);
    defer alloc.free(sorted);
    @memcpy(sorted, residuals);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const ci_low = percentile(sorted, 2.5);
    const ci_high = percentile(sorted, 97.5);

    return .{
        .b = b,
        .mean_block_len = mean_block_len,
        .point_real_gzip = point_real,
        .mean_real = mean_real,
        .mean_pseudo = mean_pseu,
        .mean_residual = mean_res,
        .std_residual = std_res,
        .ci_low = ci_low,
        .ci_high = ci_high,
        .residuals = residuals,
        .real_gzip_bpc = real_g,
        .pseudo_gzip_bpc = pseudo_g,
    };
}

/// Per-thread worker context for `pairedResidualParallel`.
const ParallelCtx = struct {
    next_idx: std.atomic.Value(usize),
    total: usize,
    source: []const u8,
    mean_block_len: usize,
    base_seed: u64,
    real_g: []f64,
    pseudo_g: []f64,
    residuals: []f64,
    errors: []?anyerror,
    parent_alloc: Allocator,
};

fn parallelWorker(ctx: *ParallelCtx) void {
    while (true) {
        const i = ctx.next_idx.fetchAdd(1, .monotonic);
        if (i >= ctx.total) return;
        const real_seed: u64 = ctx.base_seed +% (@as(u64, i) *% 2);
        const pseu_seed: u64 = ctx.base_seed +% (@as(u64, i) *% 2 +% 1);

        const real_sample = stationary_bootstrap.sample(ctx.parent_alloc, ctx.source, ctx.mean_block_len, real_seed) catch |e| {
            ctx.errors[i] = e;
            continue;
        };
        defer ctx.parent_alloc.free(real_sample);

        const pseu_sample = pseudo.trigramMatched(ctx.parent_alloc, real_sample, real_sample.len, pseu_seed) catch |e| {
            ctx.errors[i] = e;
            continue;
        };
        defer ctx.parent_alloc.free(pseu_sample);

        const g_real = compress.gzipBitsPerByte(ctx.parent_alloc, real_sample) catch |e| {
            ctx.errors[i] = e;
            continue;
        };
        const g_pseu = compress.gzipBitsPerByte(ctx.parent_alloc, pseu_sample) catch |e| {
            ctx.errors[i] = e;
            continue;
        };

        ctx.real_g[i] = g_real;
        ctx.pseudo_g[i] = g_pseu;
        ctx.residuals[i] = g_pseu - g_real;
    }
}

/// Threaded variant of `pairedResidual`. Identical semantics (same per-replicate
/// seed derivation `(seed +% 2i, seed +% 2i+1)`), so the multiset of residuals
/// is bit-exact identical to the serial version for any thread count. Only the
/// wall-clock differs.
///
/// `n_threads = null` → use `std.Thread.getCpuCount()`. `n_threads = 1` → serial
/// path identical to `pairedResidual` semantically.
pub fn pairedResidualParallel(
    alloc: Allocator,
    source: []const u8,
    mean_block_len: usize,
    b: usize,
    seed: u64,
    n_threads: ?usize,
) !ResidualResult {
    if (b == 0) return error.ZeroReplicates;
    if (mean_block_len == 0) return error.ZeroBlockLength;
    if (source.len < 3) return error.SourceTooShort;

    const requested_threads = n_threads orelse blk: {
        const cpu_count = Thread.getCpuCount() catch 1;
        break :blk cpu_count;
    };
    const t = @min(@max(requested_threads, 1), b);
    if (t <= 1) return pairedResidual(alloc, source, mean_block_len, b, seed);

    const residuals = try alloc.alloc(f64, b);
    errdefer alloc.free(residuals);
    const real_g = try alloc.alloc(f64, b);
    errdefer alloc.free(real_g);
    const pseudo_g = try alloc.alloc(f64, b);
    errdefer alloc.free(pseudo_g);

    const errors = try alloc.alloc(?anyerror, b);
    defer alloc.free(errors);
    @memset(errors, null);

    var ctx: ParallelCtx = .{
        .next_idx = .init(0),
        .total = b,
        .source = source,
        .mean_block_len = mean_block_len,
        .base_seed = seed,
        .real_g = real_g,
        .pseudo_g = pseudo_g,
        .residuals = residuals,
        .errors = errors,
        .parent_alloc = alloc,
    };

    var threads_buf: [256]Thread = undefined;
    const threads = threads_buf[0..t];
    var spawned: usize = 0;
    while (spawned < t) : (spawned += 1) {
        threads[spawned] = try Thread.spawn(.{}, parallelWorker, .{&ctx});
    }
    var k: usize = 0;
    while (k < spawned) : (k += 1) threads[k].join();

    // Surface the first error deterministically (lowest index).
    for (errors, 0..) |e_opt, idx| if (e_opt) |e| {
        _ = idx;
        alloc.free(residuals);
        alloc.free(real_g);
        alloc.free(pseudo_g);
        return e;
    };

    const point_real = try compress.gzipBitsPerByte(alloc, source);

    const mean_real = meanF64(real_g);
    const mean_pseu = meanF64(pseudo_g);
    const mean_res = meanF64(residuals);
    const std_res = stdF64(residuals, mean_res);

    const sorted = try alloc.alloc(f64, residuals.len);
    defer alloc.free(sorted);
    @memcpy(sorted, residuals);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const ci_low = percentile(sorted, 2.5);
    const ci_high = percentile(sorted, 97.5);

    return .{
        .b = b,
        .mean_block_len = mean_block_len,
        .point_real_gzip = point_real,
        .mean_real = mean_real,
        .mean_pseudo = mean_pseu,
        .mean_residual = mean_res,
        .std_residual = std_res,
        .ci_low = ci_low,
        .ci_high = ci_high,
        .residuals = residuals,
        .real_gzip_bpc = real_g,
        .pseudo_gzip_bpc = pseudo_g,
    };
}

fn meanF64(xs: []const f64) f64 {
    if (xs.len == 0) return 0.0;
    var s: f64 = 0.0;
    for (xs) |x| s += x;
    return s / @as(f64, @floatFromInt(xs.len));
}

fn stdF64(xs: []const f64, mean: f64) f64 {
    if (xs.len < 2) return 0.0;
    var s: f64 = 0.0;
    for (xs) |x| {
        const d = x - mean;
        s += d * d;
    }
    return @sqrt(s / @as(f64, @floatFromInt(xs.len - 1)));
}

/// Linear-interpolation percentile over a slice that is already sorted ASC.
/// `p` is in [0, 100].
fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0.0;
    if (sorted.len == 1) return sorted[0];
    const n_f: f64 = @floatFromInt(sorted.len);
    const rank = (p / 100.0) * (n_f - 1.0);
    const lo: usize = @intFromFloat(@floor(rank));
    const hi: usize = @intFromFloat(@ceil(rank));
    if (lo == hi) return sorted[lo];
    const frac = rank - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

// -------------------------------------------------------------- tests

test "pairedResidual: deterministic given seed" {
    const src = "the quick brown fox jumps over the lazy dog " ** 50;
    var a = try pairedResidual(std.testing.allocator, src, 30, 8, 1729);
    defer a.deinit(std.testing.allocator);
    var b = try pairedResidual(std.testing.allocator, src, 30, 8, 1729);
    defer b.deinit(std.testing.allocator);

    try std.testing.expectEqual(a.b, b.b);
    try std.testing.expectEqualSlices(f64, a.residuals, b.residuals);
    try std.testing.expectEqualSlices(f64, a.real_gzip_bpc, b.real_gzip_bpc);
    try std.testing.expectEqualSlices(f64, a.pseudo_gzip_bpc, b.pseudo_gzip_bpc);
}

test "pairedResidual: different seeds produce different draws" {
    const src = "abracadabra abracadabra abracadabra " ** 100;
    var a = try pairedResidual(std.testing.allocator, src, 25, 6, 1);
    defer a.deinit(std.testing.allocator);
    var b = try pairedResidual(std.testing.allocator, src, 25, 6, 2);
    defer b.deinit(std.testing.allocator);
    // At least one residual should differ.
    var any_differ = false;
    for (a.residuals, b.residuals) |x, y| {
        if (x != y) any_differ = true;
    }
    try std.testing.expect(any_differ);
}

test "pairedResidual: structured English-like source has positive residual" {
    // Heavily structured source: real LZ77 has a lot more to exploit than a
    // Markov-2 trigram null can reproduce in a 200-char window. Expect
    // mean_residual > 0 in expectation. We use a moderate B + large
    // mean_block_len so each replicate carries enough internal structure.
    const seed_text = "the cat sat on the mat the dog ran in the park " ++
        "she sells sea shells by the sea shore peter piper picked " ++
        "a peck of pickled peppers a stitch in time saves nine ";
    // Replicate ~4× to give the trigram chain enough density.
    var buf: [seed_text.len * 8]u8 = undefined;
    var w: usize = 0;
    while (w + seed_text.len <= buf.len) : (w += seed_text.len) {
        @memcpy(buf[w .. w + seed_text.len], seed_text);
    }
    const src = buf[0..w];

    var res = try pairedResidual(std.testing.allocator, src, 80, 16, 4242);
    defer res.deinit(std.testing.allocator);

    // The point estimate of the real source should compress strictly better
    // than the mean pseudo (large structured text has long-range repeats).
    try std.testing.expect(res.mean_residual > 0.0);
    // CI bookkeeping sanity.
    try std.testing.expect(res.ci_low <= res.mean_residual);
    try std.testing.expect(res.ci_high >= res.mean_residual);
}

test "pairedResidual: CI bookkeeping (low <= high)" {
    const src = "abcdefghijklmnopqrstuvwxyz " ** 50;
    var res = try pairedResidual(std.testing.allocator, src, 20, 12, 7);
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.ci_low <= res.ci_high);
    try std.testing.expectEqual(@as(usize, 12), res.residuals.len);
}

test "pairedResidual: ciExcludesZero accessor" {
    const src = "aaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbb " ** 100;
    var res = try pairedResidual(std.testing.allocator, src, 40, 10, 99);
    defer res.deinit(std.testing.allocator);
    // Self-consistency: the accessor matches the endpoints.
    const expected = (res.ci_low > 0.0 and res.ci_high > 0.0) or
        (res.ci_low < 0.0 and res.ci_high < 0.0);
    try std.testing.expectEqual(expected, res.ciExcludesZero());
}

test "percentile: known values on a sorted vector" {
    // [0, 1, 2, 3, 4]: p=0 → 0, p=50 → 2, p=100 → 4, p=25 → 1.0
    const sorted = [_]f64{ 0.0, 1.0, 2.0, 3.0, 4.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), percentile(&sorted, 0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), percentile(&sorted, 50.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), percentile(&sorted, 100.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), percentile(&sorted, 25.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), percentile(&sorted, 75.0), 1e-9);
}

test "pairedResidualParallel: element-wise identical to serial under same seed" {
    // The per-replicate seed derivation `(seed +% 2i, seed +% 2i+1)` is pure
    // in (seed, i), so any thread count must produce the exact same multiset
    // of residuals indexed by replicate position. We verify element-wise
    // equality, which is the strongest form of determinism.
    const src = "the quick brown fox jumps over the lazy dog " ** 30;
    var serial = try pairedResidual(std.testing.allocator, src, 40, 8, 4242);
    defer serial.deinit(std.testing.allocator);
    var par = try pairedResidualParallel(std.testing.allocator, src, 40, 8, 4242, 4);
    defer par.deinit(std.testing.allocator);

    try std.testing.expectEqual(serial.b, par.b);
    try std.testing.expectEqualSlices(f64, serial.residuals, par.residuals);
    try std.testing.expectEqualSlices(f64, serial.real_gzip_bpc, par.real_gzip_bpc);
    try std.testing.expectEqualSlices(f64, serial.pseudo_gzip_bpc, par.pseudo_gzip_bpc);
    try std.testing.expectEqual(serial.mean_residual, par.mean_residual);
    try std.testing.expectEqual(serial.ci_low, par.ci_low);
    try std.testing.expectEqual(serial.ci_high, par.ci_high);
}

test "pairedResidualParallel: n_threads=1 falls through to serial" {
    const src = "abracadabra abracadabra " ** 50;
    var par = try pairedResidualParallel(std.testing.allocator, src, 25, 4, 7, 1);
    defer par.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), par.residuals.len);
}

test "pairedResidual: error on zero replicates / zero block / tiny source" {
    const src = "the quick brown fox " ** 5;
    try std.testing.expectError(
        error.ZeroReplicates,
        pairedResidual(std.testing.allocator, src, 10, 0, 0),
    );
    try std.testing.expectError(
        error.ZeroBlockLength,
        pairedResidual(std.testing.allocator, src, 0, 4, 0),
    );
    const tiny: []const u8 = "ab";
    try std.testing.expectError(
        error.SourceTooShort,
        pairedResidual(std.testing.allocator, tiny, 5, 4, 0),
    );
}
