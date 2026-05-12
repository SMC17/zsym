//! Monoalphabetic substitution cipher: key, encode/decode, hillclimb solver.
//!
//! Targets ASCII lowercase a–z. Non-letters pass through.

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
};

/// Hillclimb / simulated-annealing substitution solver scored by an n-gram LM.
/// Mirrors `symbols.ciphers.substitution_solver.hillclimb_substitution`.
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

    var prng = std.Random.DefaultPrng.init(opts.seed);
    const r = prng.random();

    var best_key: Key = Key.identity();
    const best_pt: []u8 = try alloc.alloc(u8, ct.len);
    @memcpy(best_pt, ct);
    var best_score: f64 = -std.math.inf(f64);
    var best_iters: u64 = 0;
    var best_accepted: u64 = 0;

    var restart: u32 = 0;
    while (restart < opts.restarts) : (restart += 1) {
        var current_key = Key.random(opts.seed +% restart);
        // Decode current ciphertext under current_key (as decryption key).
        const current_pt = try alloc.alloc(u8, ct.len);
        decodeInPlace(current_key, ct, current_pt);
        var current_score = try scoreText(alloc, lm, current_pt);
        var accepted: u64 = 0;
        var temp = opts.initial_temperature;

        var it: u64 = 0;
        while (it < opts.max_iters) : (it += 1) {
            const i = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
            var j = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
            while (j == i) j = r.intRangeLessThan(usize, 0, ALPHABET_LEN);
            current_key.swap(i, j);
            // Re-decode and re-score. (For 5–10× speedup, swap only affected bytes.)
            const new_pt = try alloc.alloc(u8, ct.len);
            decodeInPlace(current_key, ct, new_pt);
            const new_score = try scoreText(alloc, lm, new_pt);

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

        if (current_score > best_score) {
            best_score = current_score;
            best_key = current_key;
            @memcpy(best_pt, current_pt);
            best_iters = opts.max_iters;
            best_accepted = accepted;
        }
    }

    return .{
        .decode_key = best_key,
        .plaintext = best_pt,
        .score = best_score,
        .iterations = best_iters,
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

fn scoreText(alloc: Allocator, lm: *ngram.NGramLM, text: []const u8) !f64 {
    // Tokenize as single-byte slices into a scratch buffer.
    const tokens = try alloc.alloc([]const u8, text.len);
    defer alloc.free(tokens);
    for (text, 0..) |_, i| tokens[i] = text[i .. i + 1];
    return lm.logProb(tokens);
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
