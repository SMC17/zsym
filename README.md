# symbols-zig

A Zig port of the load-bearing decipherment-research primitives from
[`symbols`](https://github.com/stax/symbols): corpus loaders, compression
baselines, entropy estimators, character n-gram language models, monoalphabetic
substitution solvers, and matched-statistics pseudo-text generators.

Reads the same plain-JSON corpus artifacts the Python tool writes, so you can
fetch with Python and analyze with Zig (or vice versa). Stdlib-only — no
external Zig deps.

## Why a Zig port

- **Speed**: the inner loop of the substitution solver, the conditional-entropy
  estimator, and the trigram-matched pseudo-text generator are all CPU-bound
  Python that runs 10–50× faster in Zig. The Python pipeline takes ~7 minutes
  on a 5000-char ciphertext at solver-strength settings; the Zig port should
  land in seconds.
- **Embeddability**: anything Zig can produce as a static binary, you can
  drop in a sandbox, ship to a server, or call from another language via FFI.
- **Determinism**: stdlib-only Zig with explicit RNG seeding gives bit-exact
  reproducibility across machines. The same `(commit, config, seed) → metrics`
  contract the Python codebase enforces, with stronger numeric stability.

## Status

This repo is a port-in-progress of:

- ✅ corpus JSON loader (reads `symbols/data/raw/*.json`)
- ✅ compression bits-per-char (gzip via std.compress)
- ✅ Shannon entropy + conditional entropy (plug-in + Miller-Madow)
- ✅ character n-gram LM (Laplace smoothing)
- ✅ pseudo-text generators (unigram / bigram / trigram-matched)
- ✅ substitution solver (hillclimb scored by n-gram LM, parallel restarts)
- ✅ stationary bootstrap (Politis-Romano, parallel resamples)

## Build

Requires Zig 0.16.0 or newer.

```
zig build              # compile the `symbols` CLI
zig build test         # run unit tests
zig build run -- baselines --corpus voynich --json data/raw/voynich/voynich.json
zig build run -- bench --json data/raw/voynich/voynich_chars.json
```

## Threaded speedup

The CPU-bound primitives — substitution hillclimb, matched pseudo-text
generation, and stationary bootstrap resampling — are each
embarrassingly-parallel over their outer "trial" axis (restart / sample /
replicate). Each worker is seeded deterministically as
`base_seed +% trial_idx`, so the multiset of trial outcomes is fixed by
`base_seed` alone — re-running with `n_threads = 1` vs `n_threads = N`
produces bit-exact equal results for pseudo and bootstrap, and the same best
key + same headline score for the solver.

Measurement: ReleaseFast build, `symbols bench --json voynich_chars.json`,
3 reps per config, median wall-clock reported. Hardware: 4 physical cores /
8 SMT threads. Voynich EVA char corpus (~191 KB joined).

The CPU is `intel_pstate` in active mode with EPP `performance` system-wide;
the `scaling_governor` label (`powersave` vs `performance`) is largely
cosmetic on this driver — EPP is what controls perf bias. The numbers below
were re-verified under forced `scaling_governor=performance` and matched the
quiet-system reference within noise for the solver; pseudo and bootstrap are
short enough (sub-100 ms total) that single-digit-load contention dominates
the multiplier, so treat the small-op speedups as lower bounds.

| operation                          | threads = 1 | threads = 8 | speedup |
| ---------------------------------- | ----------- | ----------- | ------- |
| solver hillclimb (16 restarts × 800 iters) | 6.61 s | 2.11 s | 3.13× |
| pseudo trigramMatched (16 samples × 5000 chars) | 0.100 s | 0.026 s | 3.88× |
| stationary bootstrap (B = 64, len = 20 000, mean\_block = 50) | 0.008 s | 0.003 s | 2.85× |

Perf-governor re-verification (load avg ~6, three full runs, median of medians):
solver 3.17×, pseudo 2.30×, bootstrap noise-dominated at 1.0×. The solver
speedup is the load-bearing claim and it's stable across governors and load
conditions. The pseudo/bootstrap multipliers are real on a quiet system but
the *measurement* is fragile at this work-per-trial size.

Notes:

- The solver scales to the number of *physical* cores rather than logical
  ones because each restart is a tight per-byte LM-scoring loop that
  saturates one core's execution units (SMT siblings contend).
- Bootstrap's speedup is limited by per-replicate `alloc.alloc(u8, N)` plus
  short kernel time — it's the small-N regime where parallel overhead bites.
  Larger `B` and longer sources will widen the gap.
- Pseudo trigramMatched builds a per-sample trigram transition table
  (Markov-2) — this is the dominant cost; the parallel speedup is close to
  the physical-core ceiling on a quiet system.
- Determinism contract: tests `hillclimb serial==parallel for same seed`,
  `generateMany serial==parallel element-wise`, and `distribution
  serial==parallel element-wise` enforce that increasing `n_threads` cannot
  change results. See `src/ciphers/substitution.zig` and friends.

## Cross-tool interop

The canonical data format is the same `Corpus` JSON the Python tool emits.
Either side can read or write; the on-disk format is the source of truth.

```
{
  "name": "voynich-eva-chars",
  "alphabet": [" ", "a", "c", "d", "e", ...],
  "meta": { ... },
  "documents": [
    { "id": "f1r", "section": "A", "meta": {...}, "glyphs": [" ", "f", "a", "c", "h", ...] }
  ]
}
```

## License

AGPL-3.0-or-later. Companion to the Python `symbols` repo.
