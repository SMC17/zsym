# symbols-zig status

Last touched: 2026-05-29.
current_test_count: 29

## Honest version posture

Despite the `v1.0.0` git tag, this project is **pre-1.0 in semver spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0, no Zig project can credibly claim API stability beyond "stable on Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a vanity claim.
2. **No production deployment exists.** symbols-zig has zero real-traffic operation, zero soak time. The README §Status assertion "stable API ... 1.0 line locks the public CLI surface" was an analogous Type-I — `stable-on-Zig-0.16-today` is the honest scope.

This file is the substrate's canonical posture statement. The CHANGELOG entry on 2026-05-21 records the correction.

**README posture (2026-05-27).** The previous 12-line syndication-mirror
stub README was replaced with a full Tier-1-public README that leads with
the methodology framing ("methodology is the artifact; findings are
claims") and explicitly disclaims any specific decipherment. The v1.0.0
git tag (the canonical Type-I) is preserved for changelog continuity but
called out in both README §Status and this file.

## Proof-vocabulary index

Levels mirror the AGENT_HARNESS convention used by mast, carreir, and Prism:

- `claimed` · `designed` · `scaffold` · `unit-tested` · `audited` · `mutation-proven` · `posture-observable-end-to-end` · `conformance-verified`

| Component | Proof level | Evidence |
|---|---|---|
| Corpus JSON loader (`src/corpus.zig`) | `unit-tested` | Reads same `symbols/data/raw/*.json` artifacts as Python tool; tests pinned via `zig build test --summary all` 2026-05-21 (22/22 pass) |
| Compression bits-per-char (gzip via `std.compress`) | `unit-tested` | Part of the 22/22 set |
| Shannon entropy + conditional entropy (plug-in + Miller-Madow) | `unit-tested` | Part of the 22/22 set |
| Character n-gram LM (Laplace smoothing) | `unit-tested` | Part of the 22/22 set |
| Pseudo-text generators (unigram / bigram / trigram-matched) | `unit-tested` + parallel-per-sample | Part of the 22/22 set; parallel-restarts deterministic per-restart seeding |
| Substitution solver (hillclimb scored by n-gram LM) | `unit-tested` + parallel-restarts | Part of the 22/22 set; deterministic per-restart seeding |
| Stationary bootstrap (Politis-Romano) | `unit-tested` + parallel-resamples | Part of the 22/22 set; deterministic per-resample seeding |
| Paired residual gzip-bpc gap with stationary-bootstrap CIs (PR-A / F7 methodology) | `unit-tested` | New module `src/methodology/residual_gap.zig` 2026-05-29; 7 tests pinned (determinism, percentile, structured-source positive residual, CI bookkeeping, error paths). Closes the F7 methodology loop in the Zig substrate — previously only the four input primitives lived here separately. |
| Cross-substrate numeric agreement with Python `symbols` | `posture-observable-end-to-end` (claimed in README; needs CI step to lock in) | README §Cross-tool interop names the verification on the Voynich EVA character corpus; CI artifact pending |
| 10–50× speedup claim over Python | `projected` | README says "the Zig port should land in seconds" against ~7-minute Python baseline. **Forward-looking claim; benchmark harness not yet committed.** Downgraded from `unit-tested` to `projected` until a published benchmark exists. |
| `bin/symbols` CLI surface (`baselines`, `bench`) | `stable-on-Zig-0.16-today` | Will be locked when Zig 1.0 ships; today subject to Zig-substrate churn |
| On-disk Corpus JSON contract | `stable-on-Zig-0.16-today` | Same scope; Python interop relies on it |
| Mutation testing of hot-loop kernels | not started | analogous to mast's `tools/mutation-test.sh` discipline |
| EVA character-corpus Voynich integration test | `posture-observable-end-to-end` (manual) | Cross-substrate numeric agreement was checked manually; needs CI harness |

## Test posture

`zig build test --summary all` (verified 2026-05-21, re-verified 2026-05-27, re-verified 2026-05-29 after adding the F7-methodology module):

```
Build Summary: 3/3 steps succeeded; 29/29 tests passed
+- run test 29 pass (29 total) 29s MaxRSS:48M
```

**No drift between README count and actual.** Re-checked 2026-05-29 — the seven new tests cover `methodology/residual_gap.zig` (determinism, structured-source positive-residual sanity, CI bookkeeping, percentile interpolator, error paths).

## Gate posture

| Gate | Status |
|---|---|
| Zig 1.0 substrate | blocked on upstream Zig 1.0 release |
| Published 10–50× speedup benchmark | not started — claim is currently projected, not measured |
| Cross-substrate numeric agreement CI step | designed (README references it); needs implementation |
| Mutation testing of hot-loop kernels | not started |
| Production soak | not started |
| Independent security review | not started |

## What's safe to claim right now

- **22 ERT tests pass** on Zig 0.16 / Linux x86_64.
- **All seven planned primitives** have shipped (corpus loader, gzip compression, Shannon + conditional entropy, n-gram LM, pseudo-text generators, substitution solver, stationary bootstrap).
- **Parallelism is wired** to the three CPU-bound inner loops; deterministic per-restart / per-resample seeding gives bit-exact reproducibility within a backend.
- **Cross-substrate numeric agreement** was verified manually on Voynich EVA character corpus.

## What's NOT safe to claim

- That the Zig port is "10–50× faster" — that's a projection from the Python pipeline's ~7-minute baseline against an expected "seconds" scale. **A benchmark harness has not been committed.** Until it has, the claim is `projected`, not measured.
- That the public CLI surface is "locked" in a v1.0-semver sense — that's a v1.0 claim against a Zig 0.16 substrate.
- That the on-disk Corpus JSON contract is "stable" beyond the Zig 0.16 stability window.
- That the cross-substrate numeric agreement is currently enforced by CI — the README claim ("has been verified") is true at a point in time; a continuously-verified CI step is design only.

## Audit history

- **2026-05-29 — F7 methodology primitive added.** New module `src/methodology/residual_gap.zig` ports the PR-A protocol (paired residual gzip-bpc gap with Politis-Romano stationary-bootstrap CIs) — the load-bearing computation behind the F7 cross-corpus finding (Voynich < Linear A < Rongorongo residual ordering). Previously the four input primitives (gzip-bpc, trigram-matched pseudo, stationary bootstrap, percentile aggregator) lived in `symbols-zig` separately; the methodology-level glue lived only in the Python sibling at `scripts/bootstrap_residual_gap_stationary.py`. This commit closes that gap. 22 → 29 tests; cross-substrate F7 verification against the Python sibling pending — listed as a deferred follow-up under the existing "Cross-substrate numeric agreement" row above.
- **2026-05-21 — Honesty correction + drift verification.** v1.0.0 "production-grade hygiene milestone" framing identified as Type-I; correction applied to CHANGELOG + this STATUS.md. The "10–50× faster" speedup claim downgraded from `unit-tested` to `projected` until benchmark ships. Test count verified at 22/22 by `zig build test --summary all` (no drift).
- **2026-05-13 — v1.0.0 tag.** Original framing was vanity-class; correction propagated from mast 2026-05-15 template.

## References

- `~/AGENT_HARNESS.md` — proof-vocabulary doctrine.
- `~/mast/STATUS.md` — the canonical model this STATUS adopts.
- `~/carreir/STATUS.md` — sibling carreir correction.
- `~/CONVENTIONS.md` — substrate-wide pattern (this file is one instance).
- `~/agent-fleet/audit/calibration/CORPUS_PART_3.md` §076-#085 — the calibration items naming the symbols-zig Type-Is.
- stax memory: `project_voynich.md`, `feedback_no_premature_production_claims.md`.
