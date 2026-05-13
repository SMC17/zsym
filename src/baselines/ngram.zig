//! Character/glyph n-gram language model with Laplace smoothing.
//!
//! Mirrors `symbols.baselines.ngram.NGramLM` from the Python codebase. n=3
//! (trigram) is the workhorse for English substitution scoring; higher n
//! needs more data to escape sparsity.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NGramLM = struct {
    n: usize,
    alpha: f64,
    alphabet: [][]const u8,
    alphabet_size: f64,
    /// context tuple (n-1 tokens, joined by \0) → count
    ctx_counts: std.StringHashMap(u64),
    /// gram tuple (n tokens, joined by \0) → count
    gram_counts: std.StringHashMap(u64),
    arena: std.heap.ArenaAllocator,

    /// Caller must hold the returned NGramLM at a stable address before
    /// calling .fit() — the struct's arena is referenced by ctx_counts and
    /// gram_counts via internal pointers, so moving the struct after init
    /// invalidates them. Use `var lm: NGramLM = undefined; try lm.initInPlace(...);`
    /// or wrap the result in a pointer immediately.
    pub fn initInPlace(self: *NGramLM, parent_alloc: Allocator, n: usize, alphabet: []const []const u8, alpha: f64) !void {
        self.* = .{
            .n = n,
            .alpha = alpha,
            .alphabet = &.{},
            .alphabet_size = @floatFromInt(alphabet.len),
            .ctx_counts = undefined,
            .gram_counts = undefined,
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
        };
        const alloc = self.arena.allocator();
        const alpha_dup = try alloc.alloc([]const u8, alphabet.len);
        for (alphabet, 0..) |t, i| alpha_dup[i] = try alloc.dupe(u8, t);
        self.alphabet = alpha_dup;
        self.ctx_counts = std.StringHashMap(u64).init(alloc);
        self.gram_counts = std.StringHashMap(u64).init(alloc);
    }

    pub fn deinit(self: *NGramLM) void {
        self.arena.deinit();
    }

    /// Fit on a token sequence. Inserts a `"<s>"` sentinel before the start.
    pub fn fit(self: *NGramLM, tokens: []const []const u8) !void {
        const alloc = self.arena.allocator();
        const sentinel = "<s>";
        const n = self.n;
        if (n == 0) return;
        // Build padded sequence in a contiguous slice of token-slices.
        var padded: std.ArrayList([]const u8) = .empty;
        defer padded.deinit(alloc);
        try padded.appendNTimes(alloc, sentinel, n - 1);
        try padded.appendSlice(alloc, tokens);
        var i: usize = n - 1;
        while (i < padded.items.len) : (i += 1) {
            const ctx_str = try joinTokens(alloc, padded.items[i - (n - 1) .. i]);
            const gram_str = try joinTokens(alloc, padded.items[i - (n - 1) .. i + 1]);
            const cr = try self.ctx_counts.getOrPut(ctx_str);
            if (cr.found_existing) cr.value_ptr.* += 1 else cr.value_ptr.* = 1;
            const gr = try self.gram_counts.getOrPut(gram_str);
            if (gr.found_existing) gr.value_ptr.* += 1 else gr.value_ptr.* = 1;
        }
    }

    /// log_2 P(token | context). context is the last (n-1) tokens or fewer.
    /// Uses the LM's internal arena for scratch — NOT thread-safe.
    pub fn logProbToken(self: *NGramLM, context: []const []const u8, token: []const u8) !f64 {
        return self.logProbTokenWithScratch(self.arena.allocator(), context, token);
    }

    /// Thread-safe variant of `logProbToken`: scratch allocations come from
    /// `scratch` (typically a per-thread arena) instead of the LM's arena.
    /// Hashmap reads on `ctx_counts` / `gram_counts` are concurrent-safe
    /// **only after fit() has completed** — no writer may run concurrently.
    pub fn logProbTokenWithScratch(self: *NGramLM, scratch: Allocator, context: []const []const u8, token: []const u8) !f64 {
        const n = self.n;
        const take = if (context.len + 1 >= n) context.len - (n - 1) else 0;
        const ctx = context[take..];
        const ctx_str = try joinTokens(scratch, ctx);
        defer scratch.free(ctx_str);
        var pair_tokens: std.ArrayList([]const u8) = .empty;
        defer pair_tokens.deinit(scratch);
        try pair_tokens.appendSlice(scratch, ctx);
        try pair_tokens.append(scratch, token);
        const pair_str = try joinTokens(scratch, pair_tokens.items);
        defer scratch.free(pair_str);
        const num_count = self.gram_counts.get(pair_str) orelse 0;
        const denom_count = self.ctx_counts.get(ctx_str) orelse 0;
        const num: f64 = @as(f64, @floatFromInt(num_count)) + self.alpha;
        const denom: f64 = @as(f64, @floatFromInt(denom_count)) + self.alpha * @max(1.0, self.alphabet_size);
        return @log2(num / denom);
    }

    /// Total log_2 P(tokens) with Laplace smoothing over the trained alphabet.
    /// Uses the LM's internal arena for scratch — NOT thread-safe.
    pub fn logProb(self: *NGramLM, tokens: []const []const u8) !f64 {
        return self.logProbWithScratch(self.arena.allocator(), tokens);
    }

    /// Thread-safe variant of `logProb`. See `logProbTokenWithScratch`.
    pub fn logProbWithScratch(self: *NGramLM, scratch: Allocator, tokens: []const []const u8) !f64 {
        const n = self.n;
        const sentinel = "<s>";
        var padded: std.ArrayList([]const u8) = .empty;
        defer padded.deinit(scratch);
        try padded.appendNTimes(scratch, sentinel, n - 1);
        try padded.appendSlice(scratch, tokens);
        var lp: f64 = 0;
        var i: usize = n - 1;
        while (i < padded.items.len) : (i += 1) {
            const ctx = padded.items[i - (n - 1) .. i];
            lp += try self.logProbTokenWithScratch(scratch, ctx, padded.items[i]);
        }
        return lp;
    }

    pub fn bitsPerToken(self: *NGramLM, tokens: []const []const u8) !f64 {
        if (tokens.len == 0) return 0.0;
        const lp = try self.logProb(tokens);
        const n_f: f64 = @floatFromInt(tokens.len);
        return -lp / n_f;
    }
};

fn joinTokens(alloc: Allocator, tokens: []const []const u8) ![]u8 {
    if (tokens.len == 0) return alloc.alloc(u8, 0);
    var total: usize = 0;
    for (tokens) |t| total += t.len;
    total += tokens.len - 1;
    var buf = try alloc.alloc(u8, total);
    var w: usize = 0;
    for (tokens, 0..) |t, i| {
        @memcpy(buf[w .. w + t.len], t);
        w += t.len;
        if (i + 1 < tokens.len) {
            buf[w] = 0;
            w += 1;
        }
    }
    return buf;
}

fn charTokens(alloc: Allocator, s: []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, s.len);
    for (s, 0..) |_, i| out[i] = s[i .. i + 1];
    return out;
}

test "ngram trains and scores" {
    const alpha = [_][]const u8{ "a", "b", "c", " ", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
    var lm: NGramLM = undefined;
    try lm.initInPlace(std.testing.allocator, 3, &alpha, 0.01);
    defer lm.deinit();
    const train_str = "the quick brown fox jumps over the lazy dog " ** 50;
    const train_tokens = try charTokens(lm.arena.allocator(), train_str);
    try lm.fit(train_tokens);

    const a_in = try charTokens(lm.arena.allocator(), "the quick");
    const a_out = try charTokens(lm.arena.allocator(), "zzzzzzzzz");
    const bpg_in = try lm.bitsPerToken(a_in);
    const bpg_out = try lm.bitsPerToken(a_out);
    try std.testing.expect(bpg_in < bpg_out);
}
