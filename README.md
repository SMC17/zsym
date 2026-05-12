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
- ⏳ substitution solver (hillclimb scored by n-gram LM)
- ⏳ stationary bootstrap (Politis-Romano)

## Build

Requires Zig 0.16.0 or newer.

```
zig build              # compile the `symbols` CLI
zig build test         # run unit tests
zig build run -- baselines --corpus voynich --json data/raw/voynich/voynich.json
```

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
