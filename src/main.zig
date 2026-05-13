//! symbols CLI.
//!
//! Usage:
//!     symbols baselines --json data/raw/voynich/voynich.json
//!     symbols baselines --text-file path/to/file.txt
//!     symbols bench --json PATH [--threads N]
//!     symbols version

const std = @import("std");
const Io = std.Io;
const symbols = @import("symbols");

const Args = struct {
    cmd: enum { baselines, bench, help, version } = .help,
    json_path: ?[]const u8 = null,
    text_path: ?[]const u8 = null,
    /// Thread count for parallel ops. `null` = auto (all CPUs).
    threads: ?usize = null,
};

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s, 10);
}

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    if (argv.len < 1) return a;
    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "baselines")) {
        a.cmd = .baselines;
    } else if (std.mem.eql(u8, cmd, "bench")) {
        a.cmd = .bench;
    } else if (std.mem.eql(u8, cmd, "version")) {
        a.cmd = .version;
        return a;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        a.cmd = .help;
        return a;
    } else {
        return error.UnknownCommand;
    }
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.json_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--text-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.text_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-j")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.threads = try parseUsize(argv[i]);
        }
    }
    return a;
}

fn printHelp(w: *Io.Writer) !void {
    try w.print(
        \\symbols — Zig port of decipherment-research primitives
        \\
        \\Usage:
        \\  symbols baselines --json PATH        compute baselines on a Corpus JSON
        \\  symbols baselines --text-file PATH   compute baselines on a raw text file
        \\  symbols bench [--json PATH] [--threads N]
        \\                                       benchmark threaded speedup on
        \\                                       solver / pseudo / bootstrap
        \\  symbols version                      print version
        \\
        \\Global flags:
        \\  --threads N, -j N                    worker thread count for parallel
        \\                                       ops (default: all CPUs)
        \\
        \\Build: zig build
        \\Tests: zig build test
        \\
    , .{});
}

fn readAllToOwned(alloc: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var allocating: Io.Writer.Allocating = .init(alloc);
    defer allocating.deinit();
    _ = try reader.interface.streamRemaining(&allocating.writer);
    return allocating.toOwnedSlice();
}

fn runBaselines(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, args: Args) !void {
    var text: []u8 = undefined;
    var name: []const u8 = "(unknown)";
    var owns_text = false;
    var corpus_opt: ?symbols.corpus.Corpus = null;

    if (args.json_path) |p| {
        corpus_opt = try symbols.corpus.load(alloc, io, p);
        const c = &corpus_opt.?;
        text = try c.joinedChars("\n");
        name = c.name;
    } else if (args.text_path) |p| {
        text = try readAllToOwned(alloc, io, p);
        owns_text = true;
        name = p;
    } else {
        try w.print("error: pass --json PATH or --text-file PATH\n", .{});
        return error.NoInput;
    }
    defer if (corpus_opt) |*c| {
        var m = c.*;
        m.deinit();
    };
    defer if (owns_text) alloc.free(text);

    try w.print("== baselines: {s} ==\n", .{name});
    try w.print("  length          : {d} bytes\n", .{text.len});

    var alphabet_set: std.AutoHashMap(u8, void) = .init(alloc);
    defer alphabet_set.deinit();
    for (text) |c| _ = try alphabet_set.getOrPut(c);
    try w.print("  alphabet        : {d} symbols\n", .{alphabet_set.count()});

    const bpc = try symbols.compress.gzipBitsPerByte(alloc, text);
    try w.print("  gzip bits/byte  : {d:.4}\n", .{bpc});

    const tokens = try alloc.alloc([]const u8, text.len);
    defer alloc.free(tokens);
    for (text, 0..) |_, i| tokens[i] = text[i .. i + 1];

    const h1 = try symbols.entropy.shannonEntropy(alloc, tokens);
    const h1_mm = try symbols.entropy.shannonEntropyMM(alloc, tokens);
    const h2 = try symbols.entropy.conditionalEntropy(alloc, tokens, 1);
    const h2_mm = try symbols.entropy.conditionalEntropyMM(alloc, tokens, 1);
    const h3 = try symbols.entropy.conditionalEntropy(alloc, tokens, 2);
    const h3_mm = try symbols.entropy.conditionalEntropyMM(alloc, tokens, 2);
    try w.print("  H1 (plug-in)    : {d:.4} bits\n", .{h1});
    try w.print("  H1 (MM)         : {d:.4} bits\n", .{h1_mm});
    try w.print("  H2 (plug-in)    : {d:.4} bits\n", .{h2});
    try w.print("  H2 (MM)         : {d:.4} bits\n", .{h2_mm});
    try w.print("  H3 (plug-in)    : {d:.4} bits\n", .{h3});
    try w.print("  H3 (MM)         : {d:.4} bits\n", .{h3_mm});
}

/// Tiny built-in English-bigram synthetic corpus for `bench` when no --json is
/// given. Deterministic, kept short — replicated to reach the target size.
const SYNTHETIC_SEED_TEXT: []const u8 = "the quick brown fox jumps over the lazy dog she sells seashells by the seashore peter piper picked a peck of pickled peppers a stitch in time saves nine ";

fn synthesizeCorpus(alloc: std.mem.Allocator, target_bytes: usize) ![]u8 {
    const out = try alloc.alloc(u8, target_bytes);
    var i: usize = 0;
    while (i < target_bytes) : (i += 1) {
        out[i] = SYNTHETIC_SEED_TEXT[i % SYNTHETIC_SEED_TEXT.len];
    }
    return out;
}

fn medianNs(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

fn fmtSecs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

const BENCH_CONFIGS = [_]usize{ 1, 0 }; // 0 → all CPUs

fn runBench(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, args: Args) !void {
    // --- corpus ---
    var text: []u8 = undefined;
    var owns_text = false;
    var corpus_opt: ?symbols.corpus.Corpus = null;
    var name: []const u8 = "synthetic";

    if (args.json_path) |p| {
        corpus_opt = try symbols.corpus.load(alloc, io, p);
        const c = &corpus_opt.?;
        text = try c.joinedChars("\n");
        name = c.name;
    } else {
        text = try synthesizeCorpus(alloc, 200_000);
        owns_text = true;
    }
    defer if (corpus_opt) |*c| {
        var m = c.*;
        m.deinit();
    };
    defer if (owns_text) alloc.free(text);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    try w.print("== bench: {s} ({d} bytes, {d} CPUs detected) ==\n", .{ name, text.len, cpu_count });

    // --- shared LM for solver bench ---
    // Use a reduced char-set alphabet over a-z + space.
    const alpha = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", " " };
    var lm: symbols.ngram.NGramLM = undefined;
    try lm.initInPlace(alloc, 3, &alpha, 0.01);
    defer lm.deinit();
    // Train on a downsampled lowercased slice of the corpus to keep memory low.
    const train_max: usize = @min(text.len, 50_000);
    const train_buf = try alloc.alloc(u8, train_max);
    defer alloc.free(train_buf);
    for (text[0..train_max], 0..) |c, i| train_buf[i] = std.ascii.toLower(c);
    const train_tokens = try lm.arena.allocator().alloc([]const u8, train_buf.len);
    for (train_buf, 0..) |_, i| train_tokens[i] = train_buf[i .. i + 1];
    try lm.fit(train_tokens);

    // Prepare a short ciphertext slice for the solver — long ciphertexts
    // make a single restart very slow.
    const cipher_len: usize = @min(text.len, 2_000);
    const cipher_buf = try alloc.alloc(u8, cipher_len);
    defer alloc.free(cipher_buf);
    for (text[0..cipher_len], 0..) |c, i| cipher_buf[i] = std.ascii.toLower(c);

    const restarts: u32 = @intCast(@max(@as(usize, 8), cpu_count * 2));
    const max_iters: u64 = 800;
    const seed: u64 = 1729;
    const reps: usize = 3;

    try w.print("\n--- solver (hillclimb, restarts={d}, max_iters={d}) ---\n", .{ restarts, max_iters });
    var solver_serial_ns: u64 = 0;
    var solver_parallel_ns: u64 = 0;
    for (BENCH_CONFIGS) |cfg| {
        const t_opt: ?usize = if (cfg == 0) null else cfg;
        const t_eff: usize = t_opt orelse cpu_count;
        var times: [3]u64 = .{ 0, 0, 0 };
        for (0..reps) |rep| {
            const t0 = Io.Clock.awake.now(io).nanoseconds;
            var res = try symbols.subst.hillclimb(alloc, cipher_buf, &lm, .{
                .max_iters = max_iters,
                .restarts = restarts,
                .seed = seed,
                .initial_temperature = 0.0,
                .n_threads = t_opt,
            });
            res.deinit();
            const t1 = Io.Clock.awake.now(io).nanoseconds;
            times[rep] = @intCast(t1 - t0);
        }
        const med = medianNs(&times);
        try w.print("  threads={d:>2}  median {d:.3}s  ({d:.3}, {d:.3}, {d:.3})\n", .{
            t_eff, fmtSecs(med), fmtSecs(times[0]), fmtSecs(times[1]), fmtSecs(times[2]),
        });
        if (cfg == 1) solver_serial_ns = med else solver_parallel_ns = med;
    }
    const solver_speedup = @as(f64, @floatFromInt(solver_serial_ns)) / @as(f64, @floatFromInt(solver_parallel_ns));
    try w.print("  speedup: {d:.2}x\n", .{solver_speedup});

    // --- pseudo-text (trigram-matched, the heaviest variant) ---
    const pseudo_samples: usize = @max(@as(usize, 16), cpu_count * 2);
    const pseudo_chars: usize = @min(text.len, 5_000);
    try w.print("\n--- pseudo (trigramMatched, n_samples={d}, n_chars={d}) ---\n", .{ pseudo_samples, pseudo_chars });
    var pseudo_serial_ns: u64 = 0;
    var pseudo_parallel_ns: u64 = 0;
    for (BENCH_CONFIGS) |cfg| {
        const t_opt: ?usize = if (cfg == 0) null else cfg;
        const t_eff: usize = t_opt orelse cpu_count;
        var times: [3]u64 = .{ 0, 0, 0 };
        for (0..reps) |rep| {
            const t0 = Io.Clock.awake.now(io).nanoseconds;
            const samples = try symbols.pseudo.generateMany(alloc, text, pseudo_chars, pseudo_samples, seed, .trigram, t_opt);
            symbols.pseudo.freeMany(alloc, samples);
            const t1 = Io.Clock.awake.now(io).nanoseconds;
            times[rep] = @intCast(t1 - t0);
        }
        const med = medianNs(&times);
        try w.print("  threads={d:>2}  median {d:.3}s  ({d:.3}, {d:.3}, {d:.3})\n", .{
            t_eff, fmtSecs(med), fmtSecs(times[0]), fmtSecs(times[1]), fmtSecs(times[2]),
        });
        if (cfg == 1) pseudo_serial_ns = med else pseudo_parallel_ns = med;
    }
    const pseudo_speedup = @as(f64, @floatFromInt(pseudo_serial_ns)) / @as(f64, @floatFromInt(pseudo_parallel_ns));
    try w.print("  speedup: {d:.2}x\n", .{pseudo_speedup});

    // --- stationary bootstrap ---
    const b_replicates: usize = @max(@as(usize, 64), cpu_count * 8);
    const boot_len: usize = @min(text.len, 20_000);
    try w.print("\n--- bootstrap (stationary, B={d}, len={d}, mean_block=50) ---\n", .{ b_replicates, boot_len });
    var boot_serial_ns: u64 = 0;
    var boot_parallel_ns: u64 = 0;
    for (BENCH_CONFIGS) |cfg| {
        const t_opt: ?usize = if (cfg == 0) null else cfg;
        const t_eff: usize = t_opt orelse cpu_count;
        var times: [3]u64 = .{ 0, 0, 0 };
        for (0..reps) |rep| {
            const t0 = Io.Clock.awake.now(io).nanoseconds;
            const samples = try symbols.stationary_bootstrap.distribution(alloc, text[0..boot_len], 50, b_replicates, seed, t_opt);
            for (samples) |s| alloc.free(s);
            alloc.free(samples);
            const t1 = Io.Clock.awake.now(io).nanoseconds;
            times[rep] = @intCast(t1 - t0);
        }
        const med = medianNs(&times);
        try w.print("  threads={d:>2}  median {d:.3}s  ({d:.3}, {d:.3}, {d:.3})\n", .{
            t_eff, fmtSecs(med), fmtSecs(times[0]), fmtSecs(times[1]), fmtSecs(times[2]),
        });
        if (cfg == 1) boot_serial_ns = med else boot_parallel_ns = med;
    }
    const boot_speedup = @as(f64, @floatFromInt(boot_serial_ns)) / @as(f64, @floatFromInt(boot_parallel_ns));
    try w.print("  speedup: {d:.2}x\n", .{boot_speedup});

    try w.print("\nsummary: solver {d:.2}x | pseudo {d:.2}x | bootstrap {d:.2}x\n", .{
        solver_speedup, pseudo_speedup, boot_speedup,
    });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const user_args = if (argv.len >= 1) argv[1..] else argv;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    const args = parseArgs(user_args) catch |err| {
        try w.print("error: {s}\n", .{@errorName(err)});
        try printHelp(w);
        try w.flush();
        return err;
    };

    switch (args.cmd) {
        .help => try printHelp(w),
        .version => try w.print("symbols-zig 0.0.1\n", .{}),
        .baselines => try runBaselines(init.gpa, init.io, w, args),
        .bench => try runBench(init.gpa, init.io, w, args),
    }
    try w.flush();
}
