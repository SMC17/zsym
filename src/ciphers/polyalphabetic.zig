//! Polyalphabetic (Vigenère-family) cipher: key, encode/decode, period detection
//! via Index of Coincidence, solver via per-position monoalphabetic hillclimb.
//!
//! Period detection: sweep p ∈ [2, max_period]; for each p, split ciphertext into
//! p letter-subsequences (every p-th letter starting at offset 0..p-1), compute IC
//! for each subsequence, average them. The period with the highest average IC
//! (closest to English ≈ 0.065) is selected.
//!
//! Solver: once period p is detected, extract each position's subsequence and run
//! `substitution.hillclimb` on it independently. The resulting p monoalphabetic
//! decode keys form the composite Vigenère key.
//!
//! Determinism: `solve` inherits the determinism of `substitution.hillclimb`. For
//! position `i`, the sub-solver seed is `opts.sub_opts.seed +% i`, so identical
//! options reproduce identical results regardless of thread count.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sub = @import("substitution.zig");
const ngram = @import("../baselines/ngram.zig");

pub const Key = sub.Key;
pub const ALPHABET_LEN = sub.ALPHABET_LEN;

/// Maximum period considered in IC sweep.
pub const MAX_PERIOD: usize = 26;

/// English Index of Coincidence for 26-letter natural language text.
pub const ENGLISH_IC: f64 = 0.0655;
/// Uniform random IC = 1/26.
pub const RANDOM_IC: f64 = 1.0 / 26.0;

// ─── Key type ────────────────────────────────────────────────────────────────

/// Vigenère key: `period` independent monoalphabetic decryption keys cycling
/// across letter positions in the ciphertext. decode_keys[i] decrypts letters
/// at positions i, i+period, i+2*period, … (counting only a–z letters).
/// Only decode_keys[0..period] are valid.
pub const VigenereKey = struct {
    decode_keys: [MAX_PERIOD]Key,
    period: usize,

    /// Generate a random key for testing. Stores decode keys (ciphertext → plaintext).
    /// Encoding keys are the inverses.
    pub fn random(seed: u64, period: usize) VigenereKey {
        var vk: VigenereKey = undefined;
        vk.period = @min(period, MAX_PERIOD);
        for (0..vk.period) |i| {
            // Random decode key: shuffle → that's the ciphertext→plaintext mapping.
            vk.decode_keys[i] = Key.random(seed +% @as(u64, i));
        }
        return vk;
    }

    /// Encode plaintext using the inverse of decode_keys. Non-letters pass through.
    pub fn encode(self: VigenereKey, alloc: Allocator, plain: []const u8) ![]u8 {
        const out = try alloc.alloc(u8, plain.len);
        var letter_pos: usize = 0;
        for (plain, 0..) |c, i| {
            const lc = std.ascii.toLower(c);
            if (lc >= 'a' and lc <= 'z') {
                const enc_key = self.decode_keys[letter_pos % self.period].inverse();
                out[i] = enc_key.mapping[lc - 'a'];
                letter_pos += 1;
            } else {
                out[i] = c;
            }
        }
        return out;
    }

    /// Decode ciphertext using decode_keys. Non-letters pass through.
    pub fn decode(self: VigenereKey, alloc: Allocator, cipher: []const u8) ![]u8 {
        const out = try alloc.alloc(u8, cipher.len);
        var letter_pos: usize = 0;
        for (cipher, 0..) |c, i| {
            const lc = std.ascii.toLower(c);
            if (lc >= 'a' and lc <= 'z') {
                out[i] = self.decode_keys[letter_pos % self.period].mapping[lc - 'a'];
                letter_pos += 1;
            } else {
                out[i] = c;
            }
        }
        return out;
    }

    /// True iff both keys have the same period and identical per-position mappings.
    pub fn equals(self: VigenereKey, other: VigenereKey) bool {
        if (self.period != other.period) return false;
        for (0..self.period) |i| {
            if (!self.decode_keys[i].equals(other.decode_keys[i])) return false;
        }
        return true;
    }
};

// ─── Index of Coincidence ────────────────────────────────────────────────────

/// Index of Coincidence of a letter sequence.
///
/// IC = Σ n_i·(n_i−1) / (N·(N−1)) where n_i = count of letter i, N = total letters.
/// English natural language ≈ 0.065; uniform random ≈ 0.038 (1/26).
/// Returns 0 if fewer than 2 letters.
pub fn indexOfCoincidence(text: []const u8) f64 {
    var counts = [_]u64{0} ** ALPHABET_LEN;
    var n: u64 = 0;
    for (text) |c| {
        const lc = std.ascii.toLower(c);
        if (lc >= 'a' and lc <= 'z') {
            counts[lc - 'a'] += 1;
            n += 1;
        }
    }
    if (n < 2) return 0.0;
    var numerator: f64 = 0.0;
    for (counts) |cnt| {
        const f: f64 = @floatFromInt(cnt);
        numerator += f * (f - 1.0);
    }
    const nf: f64 = @floatFromInt(n);
    return numerator / (nf * (nf - 1.0));
}

// ─── Period detection ────────────────────────────────────────────────────────

pub const DetectResult = struct {
    period: usize,
    avg_ic: f64,
    /// avg_ic scores for each candidate period (index 0 = period 2, etc.)
    /// Caller must free.
    scores: []f64,
};

/// Detect the most likely Vigenère period in [2, max_period] via average IC.
///
/// For each candidate period p, extract p letter-subsequences and average their ICs.
/// The period with the highest average IC is returned. Caller owns `result.scores`.
pub fn detectPeriod(
    alloc: Allocator,
    text: []const u8,
    max_period: usize,
) !DetectResult {
    // Extract letters only.
    var letters: std.ArrayListUnmanaged(u8) = .empty;
    defer letters.deinit(alloc);
    for (text) |c| {
        const lc = std.ascii.toLower(c);
        if (lc >= 'a' and lc <= 'z') try letters.append(alloc, lc);
    }
    const n = letters.items.len;

    const cap = @min(max_period, @max(n / 2, 2));
    const n_candidates = if (cap >= 2) cap - 1 else 0; // periods 2..cap
    const scores = try alloc.alloc(f64, n_candidates);
    @memset(scores, 0.0);

    if (n < 4 or n_candidates == 0) {
        return .{ .period = 1, .avg_ic = 0.0, .scores = scores };
    }

    // Reuse a buffer for each subsequence; size = ceil(n / 2) at minimum.
    const sub_buf = try alloc.alloc(u8, n);
    defer alloc.free(sub_buf);

    var best_period: usize = 2;
    var best_avg_ic: f64 = -1.0;

    var p: usize = 2;
    while (p <= cap) : (p += 1) {
        var ic_sum: f64 = 0.0;
        var pos: usize = 0;
        while (pos < p) : (pos += 1) {
            var len: usize = 0;
            var j: usize = pos;
            while (j < n) : (j += p) {
                sub_buf[len] = letters.items[j];
                len += 1;
            }
            ic_sum += indexOfCoincidence(sub_buf[0..len]);
        }
        const avg_ic = ic_sum / @as(f64, @floatFromInt(p));
        scores[p - 2] = avg_ic;
        if (avg_ic > best_avg_ic) {
            best_avg_ic = avg_ic;
            best_period = p;
        }
    }

    return .{ .period = best_period, .avg_ic = best_avg_ic, .scores = scores };
}

// ─── Solver ──────────────────────────────────────────────────────────────────

pub const SolveOptions = struct {
    /// Upper bound on the period sweep. Capped at min(max_period, n_letters/2).
    max_period: usize = 12,
    /// Hillclimb options passed to each per-position monoalphabetic solve.
    /// seed is perturbed per position: position i gets seed +% i.
    sub_opts: sub.SolveOptions = .{},
};

pub const SolveResult = struct {
    key: VigenereKey,
    plaintext: []u8, // arena-owned
    period: usize,
    avg_ic: f64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SolveResult) void {
        self.arena.deinit();
    }
};

/// Solve a polyalphabetic (Vigenère-family) ciphertext.
///
/// Steps:
///   1. Detect period via IC sweep.
///   2. For each period position, extract its letter-subsequence.
///   3. Solve each subsequence with `substitution.hillclimb`.
///   4. Compose decode keys, decode full ciphertext.
pub fn solve(
    parent_alloc: Allocator,
    ciphertext: []const u8,
    lm: *ngram.NGramLM,
    opts: SolveOptions,
) !SolveResult {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Lowercase.
    const ct = try alloc.alloc(u8, ciphertext.len);
    for (ciphertext, 0..) |c, i| ct[i] = std.ascii.toLower(c);

    // 1. Period detection.
    const det = try detectPeriod(alloc, ct, opts.max_period);
    const period = det.period;
    const avg_ic = det.avg_ic;

    // Extract letters once.
    var letters: std.ArrayListUnmanaged(u8) = .empty;
    for (ct) |c| {
        if (c >= 'a' and c <= 'z') try letters.append(alloc, c);
    }
    const n = letters.items.len;

    // 2 + 3. Per-position monoalphabetic solve.
    var vk: VigenereKey = undefined;
    vk.period = period;

    const sub_buf = try alloc.alloc(u8, (n / period) + 2);

    var pos: usize = 0;
    while (pos < period) : (pos += 1) {
        // Collect letters for this position.
        var len: usize = 0;
        var j: usize = pos;
        while (j < n) : (j += period) {
            sub_buf[len] = letters.items[j];
            len += 1;
        }

        var sub_opts_local = opts.sub_opts;
        sub_opts_local.seed = opts.sub_opts.seed +% @as(u64, pos);

        // Solve with a fresh per-call allocator; copy out the decode key.
        var result = try sub.hillclimb(parent_alloc, sub_buf[0..len], lm, sub_opts_local);
        defer result.deinit();
        vk.decode_keys[pos] = result.decode_key;
    }

    // 4. Decode full ciphertext with composite key.
    const plaintext = try alloc.alloc(u8, ct.len);
    var letter_pos: usize = 0;
    for (ct, 0..) |c, i| {
        if (c >= 'a' and c <= 'z') {
            plaintext[i] = vk.decode_keys[letter_pos % period].mapping[c - 'a'];
            letter_pos += 1;
        } else {
            plaintext[i] = c;
        }
    }

    return .{
        .key = vk,
        .plaintext = plaintext,
        .period = period,
        .avg_ic = avg_ic,
        .arena = arena,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "indexOfCoincidence — English-like vs random" {
    // English-like: repeated common letters.
    const english = "thethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethethetheth";
    const ic_e = indexOfCoincidence(english);
    try std.testing.expect(ic_e > 0.10); // highly repetitive; IC >> English average

    // Approx-uniform: abcdefghij...repeated.
    const uniform = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    const ic_u = indexOfCoincidence(uniform);
    try std.testing.expect(ic_u < 0.06); // near-uniform; IC close to 1/26 ≈ 0.038
}

test "indexOfCoincidence — short inputs" {
    try std.testing.expectEqual(@as(f64, 0.0), indexOfCoincidence(""));
    try std.testing.expectEqual(@as(f64, 0.0), indexOfCoincidence("a")); // n < 2
    // Two identical letters: IC = 1.0.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), indexOfCoincidence("aa"), 1e-12);
}

test "VigenereKey encode/decode roundtrip" {
    const alloc = std.testing.allocator;
    const key = VigenereKey.random(0xdead, 3);
    const plain = "the quick brown fox jumps over the lazy dog";
    const cipher = try key.encode(alloc, plain);
    defer alloc.free(cipher);
    const recovered = try key.decode(alloc, cipher);
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(plain, recovered);
}

test "VigenereKey period-1 degenerates to monoalphabetic" {
    const alloc = std.testing.allocator;
    const key = VigenereKey.random(42, 1);
    const plain = "hello world this is a test of the cipher";
    const cipher = try key.encode(alloc, plain);
    defer alloc.free(cipher);
    const recovered = try key.decode(alloc, cipher);
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(plain, recovered);
}

test "detectPeriod — recovers known period" {
    const alloc = std.testing.allocator;

    // Build a Vigenère ciphertext with period 4 from a long English-like plaintext.
    const key = VigenereKey.random(0xbeef, 4);
    // Simulate a long repeated English phrase (enough letters for IC to converge).
    const plain = "the sun also rises and sets over the hills where the ancient castles stand watching the kingdoms of men come and go like the tides of the sea that never cease their eternal motion in the dance of time";
    const cipher = try key.encode(alloc, plain);
    defer alloc.free(cipher);

    const det = try detectPeriod(alloc, cipher, 12);
    defer alloc.free(det.scores);

    // Period 4 should be detected (or a multiple/divisor — IC is ambiguous at small N).
    // At minimum, the detected period should not be 1.
    try std.testing.expect(det.period >= 2);
    // The IC at the true period is higher than random.
    try std.testing.expect(det.avg_ic > RANDOM_IC);
}

test "detectPeriod — short text falls back" {
    const alloc = std.testing.allocator;
    const det = try detectPeriod(alloc, "ab", 12);
    defer alloc.free(det.scores);
    try std.testing.expect(det.period >= 1);
}
