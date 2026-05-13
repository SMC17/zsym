//! Monoalphabetic substitution cipher: key, encode/decode, hillclimb solver.
//!
//! Targets ASCII lowercase a–z. Non-letters pass through.
//!
//! The hillclimb solver supports parallel restarts via `SolveOptions.n_threads`.
//! Each restart is a fully independent local search seeded from
//! `base_seed +% restart_idx`, so re-running with the same `seed` reproduces
//! the same multiset of restart outcomes (and therefore the same best key)
//! regardless of `n_threads`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ngram = @import("../baselines/ngram.zig");

pub const ALPHABET_LEN: usize = 26;

pub const Key = struct {
    /// mapping[i] = ciphertext byte that the i-th plaintext letter maps to,
    /// where i = byte - 'a'. Identity by default.
    mapping: [ALPHABET_LEN]u8,

    pub fn identity() Key {
        var m: [ALPHABET_LEN]u8 = undefined;
        for (&m, 0..) |*c, i| c.* = @intCast('a' + i);
        return .{ .mapping = m };
    }

    pub fn random(seed: u64) Key {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var k = Key.identity();
        r.shuffle(u8, &k.mapping);
        return k;
    }

    pub fn encode(self: Key, alloc: Allocator, plain: []const u8) ![]u8 {
        const out = try alloc.alloc(u8, plain.len);
        for (plain, 0..) |c, i| {
            if (c >= 'a' and c <= 'z') {
                out[i] = self.mapping[c - 'a'];
            } else {
                out[i] = c;
            }
        }
        return out;
    }

    pub fn inverse(self: Key) Key {
        var inv = Key.identity();
        for (self.mapping, 0..) |c, i| {
            if (c >= 'a' and c <= 'z') inv.mapping[c - 'a'] = @intCast('a' + i);
        }
        return inv;
    }

    pub fn decode(self: Key, alloc: Allocator, cipher: []const u8) ![]u8 {
        const inv = self.inverse();
        return inv.encode(alloc, cipher);
    }

    pub fn equals(self: Key, other: Key) bool {
        return std.mem.eql(u8, &self.mapping, &other.mapping);
    }

    pub fn swap(self: *Key, i: usize, j: usize) void {
        std.mem.swap(u8, &self.mapping[i], &self.mapping[j]);
    }
};

pub const SolveResult = struct {
    decode_key: Key,         // cipher → plain map (decryption key)
    plaintext: []u8,         // arena-owned
    score: f64,
    iterations: u64,
    accepted: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SolveResult) void {
        self.arena.deinit();
    }
};

pub const SolveOptions = struct {
    max_iters: u64 = 20000,
    restarts: u32 = 5,
    seed: u64 = 0,
    initial_temperature: f64 = 0.0,
    /// Number of worker threads to spread restarts across. `null` → use
    /// `std.Thread.getCpuCount()`. Pass `1` to force serial execution.
    n_threads: ?usize = null,
};

/// Per-restart outcome captured by each worker. Heap-free; the best plaintext
/// for the winning restart is recomputed in the parent arena at the end.
const RestartOutcome = struct {
    key: Key,
    score: f64,
    accepted: u64,
};

/// Run a single hillclimb restart with a private RNG seeded from
/// `(base_seed, restart_idx)`. Allocations come from `worker_alloc`
/// (typically a per-thread arena that is reset between restarts inside
/// the same worker, or owns the lifetime of one call). Reads on `lm`
/// are safe under the no-concurrent-writer contract documented on
/// `NGramLM.logProbWithScratch`.
fn runRestart(
    worker_alloc: Allocator,
    ct: []const u8,
    lm: *ngram.NGramLM,
    opts: SolveOptions,
    restart_idx: u32,
) !RestartOutcome {
    var prng = std.Random.DefaultPrng.init(opts.seed +% restart_idx);
    const r = prng.random();

    var current_key = Key.random(opts.seed +% restart_idx);
    const current_pt = try worker_alloc.alloc(u8, ct.len);
    decodeInPlace(current_key, ct, current_pt);
    var current_score = try scoreTextWithScratch(worker_alloc, lm, current_pt);
    var accepted: u64 = 0;
    var temp = opts.initial_temperature;

    const new_pt = try worker_alloc.alloc(u8, ct.len);

    var it: u64 = 0;
    while (it < opts.max_iters) : (it += 1) {
        const i = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
        var j = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
        while (j == i) j = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
        current_key.swap(i, j);
        decodeInPlace(current_key, ct, new_pt);
        const new_score = try scoreTextWithScratch(worker_alloc, lm, new_pt);

        const delta = new_score - current_score;
        var accept = delta > 0;
        if (!accept and temp > 0) {
            const p_accept = @exp(@min(delta / @max(temp, 1e-9), 0.0));
            accept = r.float(f64) < p_accept;
        }
        if (accept) {
            @memcpy(current_pt, new_pt);
            current_score = new_score;
            accepted += 1;
        } else {
            current_key.swap(i, j);
        }
        if (temp > 0) temp *= 0.9995;
    }

    return .{
        .key = current_key,
        .score = current_score,
        .accepted = accepted,
    };
}

/// Shared work-stealing context for parallel hillclimb. Workers grab the next
/// restart index via an atomic counter; results land in `outcomes[idx]` so the
/// reduction is order-independent.
const WorkerCtx = struct {
    next_idx: std.atomic.Value(u32),
    total: u32,
    ct: []const u8,
    lm: *ngram.NGramLM,
    opts: SolveOptions,
    outcomes: []RestartOutcome,
    errors: []?anyerror,
    parent_alloc: Allocator,
};

fn workerMain(ctx: *WorkerCtx, worker_idx: usize) void {
    _ = worker_idx;
    var arena = std.heap.ArenaAllocator.init(ctx.parent_alloc);
    defer arena.deinit();
    while (true) {
        const idx = ctx.next_idx.fetchAdd(1, .monotonic);
        if (idx >= ctx.total) return;
        // Reset the arena between restarts so memory doesn't grow without bound.
        _ = arena.reset(.retain_capacity);
        const outcome = runRestart(arena.allocator(), ctx.ct, ctx.lm, ctx.opts, idx) catch |e| {
            ctx.errors[idx] = e;
            continue;
        };
        ctx.outcomes[idx] = outcome;
    }
}

/// Hillclimb / simulated-annealing substitution solver scored by an n-gram LM.
/// Mirrors `symbols.ciphers.substitution_solver.hillclimb_substitution`.
///
/// Determinism: identical `opts.seed` reproduces the same multiset of restart
/// outcomes (and therefore the same best key + score) regardless of
/// `opts.n_threads`. Each restart is seeded independently as
/// `opts.seed +% restart_idx`.
pub fn hillclimb(
    parent_alloc: Allocator,
    ciphertext: []const u8,
    lm: *ngram.NGramLM,
    opts: SolveOptions,
) !SolveResult {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Lowercase the ciphertext into the arena.
    const ct = try alloc.alloc(u8, ciphertext.len);
    for (ciphertext, 0..) |c, i| ct[i] = std.ascii.toLower(c);

    if (opts.restarts == 0) {
        // Degenerate case: return the identity decoding.
        const pt = try alloc.alloc(u8, ct.len);
        @memcpy(pt, ct);
        return .{
            .decode_key = Key.identity(),
            .plaintext = pt,
            .score = -std.math.inf(f64),
            .iterations = 0,
            .accepted = 0,
            .arena = arena,
        };
    }

    const requested_threads = opts.n_threads orelse blk: {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk cpu_count;
    };
    const n_threads = @min(@max(requested_threads, 1), opts.restarts);

    const outcomes = try alloc.alloc(RestartOutcome, opts.restarts);
    const errors = try alloc.alloc(?anyerror, opts.restarts);
    @memset(errors, null);

    if (n_threads <= 1) {
        // Serial path.
        var i: u32 = 0;
        while (i < opts.restarts) : (i += 1) {
            outcomes[i] = try runRestart(alloc, ct, lm, opts, i);
        }
    } else {
        var ctx: WorkerCtx = .{
            .next_idx = .init(0),
            .total = opts.restarts,
            .ct = ct,
            .lm = lm,
            .opts = opts,
            .outcomes = outcomes,
            .errors = errors,
            .parent_alloc = parent_alloc,
        };
        const threads = try alloc.alloc(std.Thread, n_threads);
        var spawned: usize = 0;
        defer {
            var k: usize = 0;
            while (k < spawned) : (k += 1) threads[k].join();
        }
        while (spawned < n_threads) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{ &ctx, spawned });
        }
        // Joined in defer above. Once we leave this block, all workers are done.
    }

    // After threads have joined, surface the first error (deterministic by index).
    for (errors) |e_opt| if (e_opt) |e| return e;

    // Reduce best by restart_idx tie-break for determinism across thread counts.
    var best_idx: u32 = 0;
    var best_score: f64 = outcomes[0].score;
    var i: u32 = 1;
    while (i < opts.restarts) : (i += 1) {
        if (outcomes[i].score > best_score) {
            best_score = outcomes[i].score;
            best_idx = i;
        }
    }

    const best_key = outcomes[best_idx].key;
    const best_accepted = outcomes[best_idx].accepted;

    const best_pt = try alloc.alloc(u8, ct.len);
    decodeInPlace(best_key, ct, best_pt);

    return .{
        .decode_key = best_key,
        .plaintext = best_pt,
        .score = best_score,
        .iterations = opts.max_iters,
        .accepted = best_accepted,
        .arena = arena,
    };
}

fn decodeInPlace(decode_key: Key, ct: []const u8, out: []u8) void {
    for (ct, 0..) |c, i| {
        if (c >= 'a' and c <= 'z') {
            out[i] = decode_key.mapping[c - 'a'];
        } else {
            out[i] = c;
        }
    }
}

fn scoreTextWithScratch(scratch: Allocator, lm: *ngram.NGramLM, text: []const u8) !f64 {
    const tokens = try scratch.alloc([]const u8, text.len);
    defer scratch.free(tokens);
    for (text, 0..) |_, i| tokens[i] = text[i .. i + 1];
    return lm.logProbWithScratch(scratch, tokens);
}

test "key roundtrip" {
    const k = Key.random(42);
    const plain = "the quick brown fox";
    const cipher = try k.encode(std.testing.allocator, plain);
    defer std.testing.allocator.free(cipher);
    const back = try k.decode(std.testing.allocator, cipher);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(plain, back);
}

test "hillclimb improves over random key" {
    const alpha = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", " " };
    var lm: ngram.NGramLM = undefined;
    try lm.initInPlace(std.testing.allocator, 3, &alpha, 0.01);
    defer lm.deinit();
    const training = "the quick brown fox jumps over the lazy dog she sells seashells by the seashore peter piper picked a peck of pickled peppers " ** 50;
    const train_tokens = try lm.arena.allocator().alloc([]const u8, training.len);
    for (training, 0..) |_, i| train_tokens[i] = training[i .. i + 1];
    try lm.fit(train_tokens);

    const plain = "the quick brown fox jumps over the lazy dog " ** 10;
    const true_key = Key.random(1);
    const cipher = try true_key.encode(std.testing.allocator, plain);
    defer std.testing.allocator.free(cipher);

    var res = try hillclimb(std.testing.allocator, cipher, &lm, .{
        .max_iters = 1000,
        .restarts = 2,
        .seed = 7,
        .initial_temperature = 1.0,
    });
    defer res.deinit();

    // Score the raw ciphertext.
    const cipher_tokens = try std.testing.allocator.alloc([]const u8, cipher.len);
    defer std.testing.allocator.free(cipher_tokens);
    for (cipher, 0..) |_, i| cipher_tokens[i] = cipher[i .. i + 1];
    const cipher_score = try lm.logProb(cipher_tokens);

    try std.testing.expect(res.score > cipher_score);
}

test "hillclimb serial==parallel for same seed" {
    // Determinism invariant: same seed → same best key + same score whether
    // the restarts ran in 1 thread or N. Each restart's RNG is seeded from
    // `seed +% restart_idx`, so the multiset of restart outcomes is fixed
    // by seed alone.
    const alpha = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", " " };
    var lm: ngram.NGramLM = undefined;
    try lm.initInPlace(std.testing.allocator, 3, &alpha, 0.01);
    defer lm.deinit();
    const training = "the quick brown fox jumps over the lazy dog she sells seashells by the seashore " ** 30;
    const train_tokens = try lm.arena.allocator().alloc([]const u8, training.len);
    for (training, 0..) |_, i| train_tokens[i] = training[i .. i + 1];
    try lm.fit(train_tokens);

    const plain = "the quick brown fox jumps over the lazy dog " ** 5;
    const true_key = Key.random(3);
    const cipher = try true_key.encode(std.testing.allocator, plain);
    defer std.testing.allocator.free(cipher);

    var serial = try hillclimb(std.testing.allocator, cipher, &lm, .{
        .max_iters = 300,
        .restarts = 6,
        .seed = 11,
        .initial_temperature = 0.5,
        .n_threads = 1,
    });
    defer serial.deinit();
    var parallel = try hillclimb(std.testing.allocator, cipher, &lm, .{
        .max_iters = 300,
        .restarts = 6,
        .seed = 11,
        .initial_temperature = 0.5,
        .n_threads = 4,
    });
    defer parallel.deinit();

    try std.testing.expectEqual(serial.score, parallel.score);
    try std.testing.expect(serial.decode_key.equals(parallel.decode_key));
}
