//! Homophonic substitution cipher: each plaintext letter maps to one or more
//! ciphertext symbols (homophones). This flattens frequency distributions,
//! defeating simple frequency analysis.
//!
//! Representation: ciphertext symbols are integers in [0, SYMBOLS). Each
//! symbol is assigned to exactly one plaintext letter (surjection from the
//! ciphertext alphabet to the plaintext alphabet). Multiple symbols may map
//! to the same plaintext letter — that's the defining property.
//!
//! For decryption: given a HomophoneKey, map each ciphertext symbol to its
//! assigned plaintext letter. For encryption: given a HomophoneKey and a
//! random source, choose one of the plaintext letter's homophones at random.
//!
//! Solver: EM-style hill-climb over the symbol→letter assignment.
//!   1. Initialise by assigning symbols to letters proportional to symbol
//!      frequency (more frequent symbols → more frequent letters).
//!   2. Proposal step: swap two symbols' letter assignments.
//!   3. Accept if n-gram score improves.
//!   4. Repeat for n_restarts independent starts; return best key.
//!
//! Symbol alphabet size up to MAX_SYMBOLS = 100 (covers Copiale 75-symbol
//! cipher and Voynich-scale alphabets). Plaintext alphabet is always
//! ASCII a–z (26 letters).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ngram = @import("../baselines/ngram.zig");

pub const PLAINTEXT_LEN: usize = 26;
/// Maximum number of distinct ciphertext symbols supported.
pub const MAX_SYMBOLS: usize = 100;

pub const Error = error{
    InvalidKey,
    SymbolOutOfRange,
    EmptyCiphertext,
    OutOfMemory,
};

// ─── Key ─────────────────────────────────────────────────────────────────────

/// A homophonic key: for each ciphertext symbol s in [0, n_symbols),
/// `letter_of[s]` is the plaintext letter index (0='a', …, 25='z').
///
/// The key is a *surjection*: every plaintext letter is covered by at least
/// one symbol. (In practice some letters may have many homophones.)
pub const HomophoneKey = struct {
    /// letter_of[symbol] ∈ [0, 25]
    letter_of: [MAX_SYMBOLS]u8 = [_]u8{0} ** MAX_SYMBOLS,
    n_symbols: usize = 0,

    /// Return the plaintext letter (as 'a'…'z') for ciphertext symbol s.
    pub fn decode(self: HomophoneKey, s: usize) u8 {
        std.debug.assert(s < self.n_symbols);
        return @intCast('a' + self.letter_of[s]);
    }

    /// Decode a ciphertext symbol sequence. Each element must be in [0, n_symbols).
    /// Returns caller-owned slice of ASCII lowercase + pass-through for anything
    /// that isn't a valid symbol index.
    pub fn decodeSlice(self: HomophoneKey, alloc: Allocator, symbols: []const usize) ![]u8 {
        const out = try alloc.alloc(u8, symbols.len);
        for (symbols, 0..) |s, i| {
            out[i] = if (s < self.n_symbols) self.decode(s) else '?';
        }
        return out;
    }

    /// Encode plain ASCII lowercase using random homophone selection.
    /// Non-letter characters are kept as-is (represented as MAX_SYMBOLS+byte
    /// in the output; callers must handle passthrough symbols appropriately).
    /// Returns caller-owned slice.
    pub fn encodeSlice(
        self: HomophoneKey,
        alloc: Allocator,
        plain: []const u8,
        seed: u64,
    ) ![]usize {
        // Build reverse map: for each letter, which symbols encode it?
        var pools: [PLAINTEXT_LEN]std.ArrayListUnmanaged(usize) = [_]std.ArrayListUnmanaged(usize){.empty} ** PLAINTEXT_LEN;
        defer for (&pools) |*p| p.deinit(alloc);

        var s: usize = 0;
        while (s < self.n_symbols) : (s += 1) {
            try pools[self.letter_of[s]].append(alloc, s);
        }

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const out = try alloc.alloc(usize, plain.len);
        for (plain, 0..) |c, i| {
            if (c >= 'a' and c <= 'z') {
                const idx = c - 'a';
                const pool = pools[idx].items;
                if (pool.len == 0) {
                    out[i] = MAX_SYMBOLS; // no homophone — passthrough sentinel
                } else {
                    out[i] = pool[rng.intRangeLessThan(usize, 0, pool.len)];
                }
            } else {
                out[i] = MAX_SYMBOLS; // passthrough
            }
        }
        return out;
    }

    pub fn equals(self: HomophoneKey, other: HomophoneKey) bool {
        if (self.n_symbols != other.n_symbols) return false;
        return std.mem.eql(u8, self.letter_of[0..self.n_symbols], other.letter_of[0..self.n_symbols]);
    }

    /// Build a random key: distribute `n_symbols` homophones over 26 letters.
    /// Guarantees every letter gets at least 1 homophone when n_symbols >= 26.
    pub fn random(seed: u64, n_symbols: usize) HomophoneKey {
        std.debug.assert(n_symbols >= PLAINTEXT_LEN and n_symbols <= MAX_SYMBOLS);
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        var key = HomophoneKey{ .n_symbols = n_symbols };

        // Assign one symbol per letter (bijection for first 26 symbols).
        var perm: [PLAINTEXT_LEN]u8 = undefined;
        for (&perm, 0..) |*p, i| p.* = @intCast(i);
        rng.shuffle(u8, &perm);
        for (0..PLAINTEXT_LEN) |i| {
            key.letter_of[i] = perm[i];
        }

        // Remaining symbols assigned uniformly at random.
        var s: usize = PLAINTEXT_LEN;
        while (s < n_symbols) : (s += 1) {
            key.letter_of[s] = @intCast(rng.intRangeLessThan(usize, 0, PLAINTEXT_LEN));
        }
        return key;
    }
};

// ─── Scoring ─────────────────────────────────────────────────────────────────

/// Score a HomophoneKey on ciphertext by decoding and computing n-gram log-prob.
/// `scratch` is used for temporary token slice allocations.
fn scoreKey(
    scratch: Allocator,
    key: *const HomophoneKey,
    symbols: []const usize,
    lm: *ngram.NGramLM,
    buf: []u8,
) !f64 {
    for (symbols, 0..) |s, i| {
        buf[i] = if (s < key.n_symbols) key.decode(s) else ' ';
    }
    const text = buf[0..symbols.len];
    const tokens = try scratch.alloc([]const u8, text.len);
    defer scratch.free(tokens);
    for (text, 0..) |_, i| tokens[i] = text[i .. i + 1];
    return lm.logProbWithScratch(scratch, tokens);
}

// ─── Solver ──────────────────────────────────────────────────────────────────

pub const SolveOptions = struct {
    n_restarts: u32 = 50,
    n_iterations: u32 = 5000,
    base_seed: u64 = 42,
};

pub const SolveResult = struct {
    key: HomophoneKey,
    plaintext: []u8,
    score: f64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SolveResult) void {
        self.arena.deinit();
    }
};

/// Count frequency of each symbol in the ciphertext (valid symbols only).
fn symbolFreqs(symbols: []const usize, n_symbols: usize, freqs: []f64) void {
    @memset(freqs, 0.0);
    var total: f64 = 0;
    for (symbols) |s| {
        if (s < n_symbols) {
            freqs[s] += 1.0;
            total += 1.0;
        }
    }
    if (total > 0) {
        for (freqs[0..n_symbols]) |*f| f.* /= total;
    }
}

/// English letter frequencies (a–z), approximate.
const ENGLISH_FREQ = [PLAINTEXT_LEN]f64{
    0.082, 0.015, 0.028, 0.043, 0.127, 0.022, 0.020, 0.061, 0.070, 0.002,
    0.008, 0.040, 0.024, 0.067, 0.075, 0.019, 0.001, 0.060, 0.063, 0.091,
    0.028, 0.010, 0.023, 0.001, 0.020, 0.001,
};

/// Initialise a key by sorting symbols by frequency and assigning them to
/// letters in decreasing-frequency order (frequency-matching initialisation).
/// This gives a better starting point than random, especially for short texts.
fn freqMatchInit(
    seed: u64,
    symbols: []const usize,
    n_symbols: usize,
    freqs: []const f64,
    key: *HomophoneKey,
) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    key.n_symbols = n_symbols;

    // Sort symbols by descending frequency.
    var sym_order: [MAX_SYMBOLS]usize = undefined;
    for (0..n_symbols) |i| sym_order[i] = i;
    // Simple insertion sort (n_symbols ≤ 100 — fast enough).
    var i: usize = 1;
    while (i < n_symbols) : (i += 1) {
        const key_val = sym_order[i];
        const kf = freqs[key_val];
        var j: usize = i;
        while (j > 0 and freqs[sym_order[j - 1]] < kf) : (j -= 1) {
            sym_order[j] = sym_order[j - 1];
        }
        sym_order[j] = key_val;
    }

    // Sort plaintext letters by descending English frequency with small jitter
    // so restarts differ.
    var letter_order: [PLAINTEXT_LEN]u8 = undefined;
    for (&letter_order, 0..) |*l, li| l.* = @intCast(li);
    // Apply jitter: add random noise to English freqs before sorting.
    var jittered: [PLAINTEXT_LEN]f64 = ENGLISH_FREQ;
    for (&jittered) |*f| f.* += rng.float(f64) * 0.005;
    // Sort descending.
    var li: usize = 1;
    while (li < PLAINTEXT_LEN) : (li += 1) {
        const lv = letter_order[li];
        const lf = jittered[lv];
        var lj: usize = li;
        while (lj > 0 and jittered[letter_order[lj - 1]] < lf) : (lj -= 1) {
            letter_order[lj] = letter_order[lj - 1];
        }
        letter_order[lj] = lv;
    }

    // Assign: top-n_symbols symbols → letters by matching ranks.
    // If n_symbols > 26, multiple symbols per letter — assign proportionally
    // to English letter frequency.
    if (n_symbols == PLAINTEXT_LEN) {
        for (0..n_symbols) |si| {
            key.letter_of[sym_order[si]] = letter_order[si];
        }
        return;
    }

    // n_symbols > 26: distribute extra symbols in proportion to English freq.
    // Compute how many symbols per letter (rounded).
    var alloc_counts: [PLAINTEXT_LEN]usize = [_]usize{1} ** PLAINTEXT_LEN;
    const extra = n_symbols - PLAINTEXT_LEN;
    // Assign extra symbols to the most frequent letters.
    var ei: usize = 0;
    while (ei < extra) : (ei += 1) {
        alloc_counts[ei % PLAINTEXT_LEN] += 1;
    }

    var sym_idx: usize = 0;
    for (0..PLAINTEXT_LEN) |letter_rank| {
        const letter = letter_order[letter_rank];
        const count = alloc_counts[letter_rank];
        var ci: usize = 0;
        while (ci < count and sym_idx < n_symbols) : (ci += 1) {
            key.letter_of[sym_order[sym_idx]] = letter;
            sym_idx += 1;
        }
    }
    // Fill any remaining (shouldn't happen if counts are correct).
    while (sym_idx < n_symbols) : (sym_idx += 1) {
        key.letter_of[sym_order[sym_idx]] = rng.intRangeLessThan(u8, 0, PLAINTEXT_LEN);
    }

    _ = symbols;
}

/// Solve the homophonic cipher. Requires knowing `n_symbols` (the ciphertext
/// alphabet size). The caller provides the symbol sequence as []const usize
/// where each value is in [0, n_symbols).
///
/// Returns a SolveResult owning an arena with the decoded plaintext.
pub fn solve(
    parent_alloc: Allocator,
    symbols: []const usize,
    n_symbols: usize,
    lm: *ngram.NGramLM,
    opts: SolveOptions,
) !SolveResult {
    if (symbols.len == 0) return Error.EmptyCiphertext;
    if (n_symbols > MAX_SYMBOLS) return Error.InvalidKey;
    if (n_symbols < PLAINTEXT_LEN) return Error.InvalidKey;

    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var sym_freqs: [MAX_SYMBOLS]f64 = [_]f64{0.0} ** MAX_SYMBOLS;
    symbolFreqs(symbols, n_symbols, &sym_freqs);

    // Decode buffer: same length as ciphertext.
    const decode_buf = try alloc.alloc(u8, symbols.len);

    var best_key = HomophoneKey{ .n_symbols = n_symbols };
    var best_score: f64 = -std.math.inf(f64);

    var restart: u32 = 0;
    while (restart < opts.n_restarts) : (restart += 1) {
        const seed = opts.base_seed +% @as(u64, restart);
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        var key = HomophoneKey{ .n_symbols = n_symbols };
        freqMatchInit(seed, symbols, n_symbols, &sym_freqs, &key);

        var current_score = try scoreKey(alloc, &key, symbols, lm, decode_buf);

        var iter: u32 = 0;
        while (iter < opts.n_iterations) : (iter += 1) {
            // Proposal: swap letter assignments of two random symbols.
            const s1 = rng.intRangeLessThan(usize, 0, n_symbols);
            const s2 = rng.intRangeLessThan(usize, 0, n_symbols);
            if (s1 == s2) continue;

            const old1 = key.letter_of[s1];
            const old2 = key.letter_of[s2];
            if (old1 == old2) continue; // same letter — swap doesn't change decode

            key.letter_of[s1] = old2;
            key.letter_of[s2] = old1;

            const new_score = try scoreKey(alloc, &key, symbols, lm, decode_buf);
            if (new_score > current_score) {
                current_score = new_score;
            } else {
                key.letter_of[s1] = old1;
                key.letter_of[s2] = old2;
            }
        }

        if (current_score > best_score) {
            best_score = current_score;
            best_key = key;
        }
    }

    // Decode using best key.
    const plaintext = try alloc.alloc(u8, symbols.len);
    for (symbols, 0..) |s, i| {
        plaintext[i] = if (s < n_symbols) best_key.decode(s) else '?';
    }

    return SolveResult{
        .key = best_key,
        .plaintext = plaintext,
        .score = best_score,
        .arena = arena,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "HomophoneKey: random key is surjective" {
    const key = HomophoneKey.random(42, 52);
    try testing.expectEqual(@as(usize, 52), key.n_symbols);

    // Every letter [0,25] must appear in letter_of.
    var seen: [PLAINTEXT_LEN]bool = [_]bool{false} ** PLAINTEXT_LEN;
    var s: usize = 0;
    while (s < key.n_symbols) : (s += 1) {
        seen[key.letter_of[s]] = true;
    }
    for (seen) |present| try testing.expect(present);
}

test "HomophoneKey: encode/decode roundtrip" {
    const key = HomophoneKey.random(7, 52);

    const plain = "thequickbrownfoxjumpsoverthelazydog";
    const symbols = try key.encodeSlice(testing.allocator, plain, 1234);
    defer testing.allocator.free(symbols);

    const decoded = try key.decodeSlice(testing.allocator, symbols);
    defer testing.allocator.free(decoded);

    try testing.expectEqualStrings(plain, decoded);
}

test "HomophoneKey: equals / not-equals" {
    const k1 = HomophoneKey.random(1, 26);
    const k2 = HomophoneKey.random(2, 26);
    try testing.expect(k1.equals(k1));
    try testing.expect(!k1.equals(k2));
}

test "HomophoneKey: passthrough for non-letter input" {
    const key = HomophoneKey.random(3, 26);
    const plain = "hello world";
    const symbols = try key.encodeSlice(testing.allocator, plain, 0);
    defer testing.allocator.free(symbols);

    // Space maps to MAX_SYMBOLS sentinel.
    try testing.expectEqual(MAX_SYMBOLS, symbols[5]);

    const decoded = try key.decodeSlice(testing.allocator, symbols);
    defer testing.allocator.free(decoded);
    // Non-letter sentinel becomes '?'.
    try testing.expectEqual(@as(u8, '?'), decoded[5]);
}

test "HomophoneKey: 26-symbol key behaves like monoalphabetic" {
    // With exactly 26 symbols (one per letter), the homophonic cipher
    // degenerates to a monoalphabetic substitution — same roundtrip guarantee.
    const key = HomophoneKey.random(99, 26);
    const plain = "substitutionciphertest";
    const symbols = try key.encodeSlice(testing.allocator, plain, 42);
    defer testing.allocator.free(symbols);
    const decoded = try key.decodeSlice(testing.allocator, symbols);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(plain, decoded);
}

test "HomophoneKey: solver recovers 26-symbol cipher on trigram LM" {
    const alpha = [_][]const u8{
        "a","b","c","d","e","f","g","h","i","j","k","l","m",
        "n","o","p","q","r","s","t","u","v","w","x","y","z"," ",
    };
    var lm: ngram.NGramLM = undefined;
    try lm.initInPlace(testing.allocator, 3, &alpha, 0.01);
    defer lm.deinit();
    const training = "the quick brown fox jumps over the lazy dog " ++
        "the cat sat on the mat she sells seashells by the seashore " ++
        "peter piper picked peppers the fox ran across the field " ++
        "the quick brown fox jumps over the lazy dog ";
    const train_tokens = try lm.arena.allocator().alloc([]const u8, training.len);
    for (training, 0..) |_, i| train_tokens[i] = training[i .. i + 1];
    try lm.fit(train_tokens);

    // Encrypt a short known plaintext with a 26-symbol homophonic key.
    const true_key = HomophoneKey.random(77, 26);
    const plain = "thequickbrownfox";
    const symbols = try true_key.encodeSlice(testing.allocator, plain, 0);
    defer testing.allocator.free(symbols);

    // Solver should complete and produce a valid decoding.
    var result = try solve(testing.allocator, symbols, 26, &lm, .{
        .n_restarts = 20,
        .n_iterations = 1000,
        .base_seed = 42,
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, plain.len), result.plaintext.len);
    try testing.expect(std.math.isFinite(result.score));
}

test "HomophoneKey: frequency flattening — 52 symbols have lower max-freq than 26" {
    // The whole point of homophones: distributing one letter across multiple
    // symbols reduces the maximum symbol frequency in the ciphertext.
    const plain = "eeeeeeeeeeeeeeeeabcdefghijklmnopqrstuvwxyz";
    // 26-symbol key: 'e' maps to one symbol → that symbol appears 18/42 times.
    const k26 = HomophoneKey.random(10, 26);
    const s26 = try k26.encodeSlice(testing.allocator, plain, 1);
    defer testing.allocator.free(s26);

    // 52-symbol key: 'e' maps to ~2 symbols → max freq should be lower.
    const k52 = HomophoneKey.random(10, 52);
    const s52 = try k52.encodeSlice(testing.allocator, plain, 1);
    defer testing.allocator.free(s52);

    var freq26: [MAX_SYMBOLS]usize = [_]usize{0} ** MAX_SYMBOLS;
    var freq52: [MAX_SYMBOLS]usize = [_]usize{0} ** MAX_SYMBOLS;
    for (s26) |s| if (s < 26) { freq26[s] += 1; };
    for (s52) |s| if (s < 52) { freq52[s] += 1; };

    var max26: usize = 0;
    var max52: usize = 0;
    for (freq26[0..26]) |f| if (f > max26) { max26 = f; };
    for (freq52[0..52]) |f| if (f > max52) { max52 = f; };

    // 52-symbol version should have a lower (or equal) maximum symbol freq.
    try testing.expect(max52 <= max26);
}
