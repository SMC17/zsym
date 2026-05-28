# Contributing to symbols-zig

This is the Zig port of the load-bearing primitives from
[`symbols`](https://github.com/SMC17/symbols) — corpus loaders, compression
baselines, entropy estimators, n-gram language models, substitution
solvers, and matched-statistics pseudo-text generators.

## Build

```
zig build              # compile the CLI
zig build test         # run unit tests
zig build run -- baselines --json data/raw/voynich.json
```

Requires Zig 0.16.0 or newer.

## Project rules

1. **Cross-tool interop is the on-disk JSON format.** Anything we read or
   write must be parseable by the Python `symbols` codebase too. If a
   format change is required, it lands in both repos in the same week.

2. **Stdlib only.** No external Zig dependencies. The Zig stdlib is large
   enough for this scope (JSON parsing, std.compress.flate for gzip,
   std.Random for seeding, std.heap.ArenaAllocator for scratch memory).

3. **Determinism is part of the API.** Every function that uses randomness
   takes an explicit `seed: u64`. Identical inputs + seed = identical
   outputs across machines.

4. **No global state.** Allocator threading is explicit. The `Io` value
   from `main()` threads to every function that touches the filesystem.

5. **Tests live next to code.** `pub fn foo(...)` gets `test "foo ..."`
   in the same file. `zig build test` runs them all.

## What to port next

Priorities, in order:

1. **Modified Kneser-Ney n-gram LM** to match `symbols/baselines/kneser_ney.py`.
   Required for solver-strength scoring.
2. **Stationary bootstrap** to match `symbols/baselines/stationary_bootstrap.py`.
   Politis-Romano with geometric block lengths.
3. **3-cycle solver moves + adaptive cooling** to bring the substitution
   solver up to the level of `symbols/ciphers/substitution_solver.py`.
4. **Higher-order pseudo (n=4, n=5)** to mirror the Python sensitivity sweep.

## Style

- One module per file. Public API at the top, private helpers at the bottom.
- Doc comments (`//!` for file, `///` for items) on every public item.
- Errors are first-class: every function that can fail returns `!T`.
  Don't silently swallow errors.
- Allocator parameter is always first. `Io` (when needed) is second.
- Naming: `camelCase` for functions, `PascalCase` for types, `snake_case`
  for locals and fields. Match the surrounding stdlib idiom.
