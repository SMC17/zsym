# Changelog

All notable changes to `symbols-zig` will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### F7 methodology primitive — 2026-05-29

Added `src/methodology/residual_gap.zig`: paired residual gzip-bpc gap with
Politis-Romano stationary-bootstrap CIs (the PR-A protocol from the parent
`symbols` repo). This is the load-bearing computation behind F7
(Voynich / Linear A / Rongorongo cross-corpus residual ordering), now
reproducible in the Zig substrate.

Composes four pre-existing primitives — `compress.gzipBitsPerByte`,
`pseudo.trigramMatched`, `stationary_bootstrap.sample`, plus a linear-
interp percentile aggregator — into a single `pairedResidual(...)` call
returning the residual distribution + mean + 2.5/97.5 percentile CI.

Per-replicate seeding `(seed +% 2i, seed +% 2i+1)` makes the result a pure
function of `(source, mean_block_len, b, seed)`; matches the determinism
discipline used by the existing parallel primitives.

7 new tests cover determinism, structured-source positive-residual
sanity, CI bookkeeping, percentile interpolation, and error paths.
22 → 29 tests; `zig build && zig build test --summary all` clean.

Pending follow-up (deferred): cross-substrate numeric agreement vs the
Python sibling `scripts/bootstrap_residual_gap_stationary.py` on the
Voynich EVA character corpus, with the residual *mean* as the comparable
quantity (byte-exact pseudo differs across RNG substrates per the module
docstring).

### Tier 1 public push — 2026-05-27

Per the merchant-tier policy: Tier 1 substrate primitives become
GH-canonical public. symbols-zig qualifies — 22/22 tests pass, all
seven planned primitives ship, deterministic-parallel kernels are
covered by serial==parallel tests, and the cross-substrate JSON
contract is stable.

Concrete changes in this push:

- Replaced the 12-line syndication-mirror stub `README.md` with a full
  Tier-1-public README that **leads with the methodology framing**:
  "methodology is the artifact; findings are claims; no specific
  decipherment is being made." Cites the parent `symbols` repo as
  the research lane.
- Removed `.canonical-readme.md` (its content moved into `README.md`).
- Removed orphan `.claude/worktrees/` gitlink (no `.gitmodules` entry;
  was a phantom submodule reference).
- Added `.claude/` to `.gitignore`.
- `SECURITY.md` contact updated from a personal X handle to
  `sean@sunlitmoon.online`.
- `CONTRIBUTING.md` link to parent `symbols` repo corrected to
  `github.com/SMC17/symbols`.
- Git history filtered to strip `Co-Authored-By: Claude` trailers and
  the `.claude/` tree per the no-claude-attribution + no-claude-harness
  -in-public-history policies. The v1.0.0 tag is preserved (with the
  honesty correction it already carries) and re-pointed at the
  rewritten commit.

No code changes; substrate is identical to the pre-push HEAD.

### Honesty correction — 2026-05-21

Prior `v1.0.0` "production-grade hygiene milestone" framing (below) was a Type-I error class per the no-premature-production-claims doctrine.

Two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0, no Zig project can credibly claim API stability beyond "stable on Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a vanity claim — the language guarantees aren't there yet.
2. **No production deployment exists.** symbols-zig has zero real-traffic operation, zero soak time, zero production-incident history. The `v1.0.0` tag was described as a "production-grade hygiene milestone" — the hygiene work (LICENSE / SECURITY / CONTRIBUTING / CI) is real, but those are **shipping-process hygiene**: necessary, not sufficient, for "production-grade."

The hygiene work is real. The v1.x git tag is honored for changelog continuity. But every reader should treat this as a **pre-1.0 substrate** until both gates above close. See `STATUS.md` for the proof-vocabulary index.

Also retracted: the README §Status assertion "**v1.0.0 — stable API.** ... The 1.0 line locks the public CLI surface (`baselines`, `bench`) and the on-disk Corpus JSON contract." That's a v1.0-semver claim on a Zig-0.16 substrate, identical in shape. README will be updated to scope the stability claim to "stable-on-Zig-0.16-today; API locks await Zig 1.0."

Reuses the exact framing mast applied on 2026-05-15 (`~/mast/CHANGELOG.md` §"Honesty correction — 2026-05-15") and carreir applied on 2026-05-20 (`~/carreir/CHANGELOG.md` §"Honesty correction — 2026-05-20"). Same Type-I class, same correction, same vocabulary discipline.

### Test count verification — 2026-05-21

`zig build test --summary all` confirmed 22/22 tests pass — README claim verified, no drift detected:

```
Build Summary: 3/3 steps succeeded; 22/22 tests passed
+- run test 22 pass (22 total) 3s MaxRSS:49M
```

Unlike carreir (which had a 41 → 53 drift caught by the same audit step), symbols-zig's documented test count is current. Recorded here to close the audit-lane question raised by `~/agent-fleet/audit/calibration/CORPUS_PART_3.md` item #077.

## v1.0.0 — 2026-05-13

**[Originally framed as: "Production-grade hygiene milestone." See 2026-05-21 honesty correction above. The framing is preserved here for changelog continuity but the production-grade claim was not earned.]**

- LICENSE (AGPL-3.0), README, CONTRIBUTING, SECURITY, CI all present.
- Repo declared at v1.x milestone: existing surface stable; breaking changes bump to v2.x.
