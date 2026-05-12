//! Shannon and conditional entropy estimators.
//!
//! Plug-in is fast but biased downward by ~(K-1)/(2N ln 2). Miller-Madow
//! adds that correction. Both are exposed; new code should default to MM.
//!
//! Operates on token slices (slices of `[]const u8`). For character-level
//! corpora pre-split into single-byte tokens; for glyph-level corpora the
//! token sequence is the parsed glyph values.

const std = @import("std");
const Allocator = std.mem.Allocator;

const LN2: f64 = 0.6931471805599453;

/// Shannon entropy in bits, plug-in estimator.
pub fn shannonEntropy(alloc: Allocator, tokens: []const []const u8) !f64 {
    if (tokens.len == 0) return 0.0;
    var counts = std.StringHashMap(u64).init(alloc);
    defer counts.deinit();
    for (tokens) |t| {
        const r = try counts.getOrPut(t);
        if (r.found_existing) r.value_ptr.* += 1 else r.value_ptr.* = 1;
    }
    const n_f: f64 = @floatFromInt(tokens.len);
    var h: f64 = 0;
    var it = counts.valueIterator();
    while (it.next()) |c_ptr| {
        const c_f: f64 = @floatFromInt(c_ptr.*);
        const p = c_f / n_f;
        h -= p * @log2(p);
    }
    return h;
}

/// Miller-Madow corrected unigram Shannon entropy in bits.
pub fn shannonEntropyMM(alloc: Allocator, tokens: []const []const u8) !f64 {
    if (tokens.len == 0) return 0.0;
    var counts = std.StringHashMap(u64).init(alloc);
    defer counts.deinit();
    for (tokens) |t| {
        const r = try counts.getOrPut(t);
        if (r.found_existing) r.value_ptr.* += 1 else r.value_ptr.* = 1;
    }
    const n_f: f64 = @floatFromInt(tokens.len);
    const k: f64 = @floatFromInt(counts.count());
    var h: f64 = 0;
    var it = counts.valueIterator();
    while (it.next()) |c_ptr| {
        const c_f: f64 = @floatFromInt(c_ptr.*);
        const p = c_f / n_f;
        h -= p * @log2(p);
    }
    if (counts.count() <= 1) return h;
    return h + (k - 1.0) / (2.0 * n_f * LN2);
}

/// Conditional entropy H(X_t | X_{t-context..t-1}) in bits, plug-in.
/// context=1 → bigram conditional entropy; context=2 → trigram.
pub fn conditionalEntropy(alloc: Allocator, tokens: []const []const u8, context: usize) !f64 {
    if (context == 0) return shannonEntropy(alloc, tokens);
    if (tokens.len <= context) return 0.0;

    // Encode contexts as null-byte-joined strings.
    var ctx_counts = std.StringHashMap(u64).init(alloc);
    defer ctx_counts.deinit();
    var pair_counts = std.StringHashMap(u64).init(alloc);
    defer pair_counts.deinit();

    // Use an arena so the joined keys live as long as the maps.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var i: usize = context;
    while (i < tokens.len) : (i += 1) {
        const ctx_str = try joinTokens(a, tokens[i - context .. i]);
        const pair_str = try joinTokens(a, tokens[i - context .. i + 1]);
        const cr = try ctx_counts.getOrPut(ctx_str);
        if (cr.found_existing) cr.value_ptr.* += 1 else cr.value_ptr.* = 1;
        const pr = try pair_counts.getOrPut(pair_str);
        if (pr.found_existing) pr.value_ptr.* += 1 else pr.value_ptr.* = 1;
    }

    const total_f: f64 = @floatFromInt(tokens.len - context);
    var h: f64 = 0;
    var it = pair_counts.iterator();
    while (it.next()) |entry| {
        const pair_key = entry.key_ptr.*;
        const c_pair: f64 = @floatFromInt(entry.value_ptr.*);
        // The context prefix is everything before the final \0-separated token.
        const last_sep = std.mem.lastIndexOfScalar(u8, pair_key, 0).?;
        const ctx_key = pair_key[0..last_sep];
        const c_ctx_raw = ctx_counts.get(ctx_key) orelse 0;
        const c_ctx: f64 = @floatFromInt(c_ctx_raw);
        const p_joint = c_pair / total_f;
        h -= p_joint * @log2(c_pair / c_ctx);
    }
    return h;
}

/// Miller-Madow corrected conditional entropy in bits.
/// Per-context correction summed: H_MM(X|Y) = H_plugin + Σ_y (K_y - 1) / (2 N_total ln 2)
pub fn conditionalEntropyMM(alloc: Allocator, tokens: []const []const u8, context: usize) !f64 {
    if (context == 0) return shannonEntropyMM(alloc, tokens);
    if (tokens.len <= context) return 0.0;

    var ctx_unique = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    defer {
        var it = ctx_unique.valueIterator();
        while (it.next()) |s_ptr| s_ptr.*.deinit();
        ctx_unique.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var i: usize = context;
    while (i < tokens.len) : (i += 1) {
        const ctx_str = try joinTokens(a, tokens[i - context .. i]);
        const gop = try ctx_unique.getOrPut(ctx_str);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(alloc);
        const tok = tokens[i];
        // Dedupe per context using the same arena keys.
        const tok_key = try a.dupe(u8, tok);
        _ = try gop.value_ptr.*.getOrPut(tok_key);
    }

    var sum_k_minus_one: f64 = 0;
    var it = ctx_unique.valueIterator();
    while (it.next()) |s_ptr| {
        const k_y_f: f64 = @floatFromInt(s_ptr.*.count());
        if (k_y_f >= 1.0) sum_k_minus_one += (k_y_f - 1.0);
    }
    const total_f: f64 = @floatFromInt(tokens.len - context);
    const h_plugin = try conditionalEntropy(alloc, tokens, context);
    return h_plugin + sum_k_minus_one / (2.0 * total_f * LN2);
}

fn joinTokens(alloc: Allocator, tokens: []const []const u8) ![]u8 {
    if (tokens.len == 0) return alloc.alloc(u8, 0);
    var total: usize = 0;
    for (tokens) |t| total += t.len;
    total += tokens.len - 1; // separators only (no trailing)
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

// Internal helper: build a slice of single-byte token slices over a string.
fn charTokensSlice(alloc: Allocator, s: []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, s.len);
    for (s, 0..) |_, i| out[i] = s[i .. i + 1];
    return out;
}

test "uniform entropy" {
    const s = "abcdabcd" ** 100;
    const tokens = try charTokensSlice(std.testing.allocator, s);
    defer std.testing.allocator.free(tokens);
    const h = try shannonEntropy(std.testing.allocator, tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), h, 0.001);
}

test "single-char entropy is zero" {
    const tokens = try charTokensSlice(std.testing.allocator, "aaaa");
    defer std.testing.allocator.free(tokens);
    const h = try shannonEntropy(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(f64, 0.0), h);
}

test "conditional entropy lower than unconditional on structured" {
    const s = "abcabcabcabc" ** 100;
    const tokens = try charTokensSlice(std.testing.allocator, s);
    defer std.testing.allocator.free(tokens);
    const h1 = try shannonEntropy(std.testing.allocator, tokens);
    const h2 = try conditionalEntropy(std.testing.allocator, tokens, 1);
    try std.testing.expect(h1 > h2 + 0.5);
}

test "miller-madow shifts upward" {
    const tokens = try charTokensSlice(std.testing.allocator, "abcabc");
    defer std.testing.allocator.free(tokens);
    const h_plugin = try shannonEntropy(std.testing.allocator, tokens);
    const h_mm = try shannonEntropyMM(std.testing.allocator, tokens);
    try std.testing.expect(h_mm > h_plugin);
}
