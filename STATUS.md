# symbols-zig status

Last touched: 2026-05-29 (Wave-6: Indus M-range PROMOTE-OK).
current_test_count: 31

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
| Paired residual gzip-bpc gap with stationary-bootstrap CIs (PR-A / F7 methodology) | `unit-tested` + parallel-replicates + `audited` cross-substrate | New module `src/methodology/residual_gap.zig` 2026-05-29; 9 tests pinned (determinism, percentile, structured-source positive residual, CI bookkeeping, error paths, serial==parallel element-wise, n_threads=1 fall-through). Parallel variant `pairedResidualParallel` ships same day. Closes the F7 methodology loop in the Zig substrate. Cross-substrate residual-mean agreement against Python `paired_residual_distribution` confirmed by `~/symbols/scripts/audit_residual_gap_parity.sh` 2026-05-29 (PROMOTE-OK at B=40 L=100 seed=0). |
| Cross-substrate numeric agreement with Python `symbols` | `audited` (single-shot; continuous CI step still pending) | `~/symbols/scripts/audit_residual_gap_parity.sh` driven by the new `symbols audit-residual` CLI 2026-05-29: Voynich EVA char corpus B=40 L=100 seed=0; Python μ=+0.3385, Zig μ=+0.3353, |Δμ|=0.0031 ≤ 3×combined-SE 0.0147; CIs overlap by +0.056 bpc. PROMOTE-OK. |
| Cross-substrate numeric agreement, Linear A | `audited` (single-shot; continuous CI step still pending) | Same harness 2026-05-29 with `--corpus data/raw/linear_a/linear_a_chars.json --replicates 40 --mean-block-len 100 --seed 0`; Python μ=+0.7448, Zig μ=+0.7388, |Δμ|=0.0060 ≤ 3×combined-SE 0.0231; CIs overlap by +0.1066 bpc. PROMOTE-OK. Corpus repacked char-level from `parse_linear_a().joined_text("\n")` (756 inscriptions, 30,449 chars) via `~/symbols/scripts/dump_corpus_chars_json.py` so `joinedChars("\n")` and `joined_text("\n")` produce byte-identical input. |
| Cross-substrate numeric agreement, Rongorongo | `audited` (single-shot; continuous CI step still pending) | Same harness 2026-05-29 with `--corpus data/raw/rongorongo/rongorongo_chars.json --replicates 40 --mean-block-len 100 --seed 0`; Python μ=+1.1291, Zig μ=+1.1075, |Δμ|=0.0217 ≤ 3×combined-SE 0.0234; CIs overlap by +0.1038 bpc. PROMOTE-OK. Corpus repacked char-level from `parse_rongorongo().joined_text("\n")` (25 tablets, 66,801 chars) via `~/symbols/scripts/dump_corpus_chars_json.py`. |
| Cross-substrate numeric agreement, Indus (M-range subset) | `audited` (single-shot; continuous CI step still pending) | Same harness 2026-05-29 with `--corpus data/raw/indus/indus_chars.json --replicates 40 --mean-block-len 100 --seed 0`; Python μ=+0.8646, Zig μ=+0.8515, |Δμ|=0.0132 ≤ 3×combined-SE 0.0616; CIs overlap by +0.3063 bpc. PROMOTE-OK. Corpus repacked char-level from `parse_indus().joined_text("\n")` (179 CISI sides, 5,014 chars, alphabet=13) via `~/symbols/scripts/dump_corpus_chars_json.py`. Upstream is `mayig/indus-valley-script-corpus` (MIT digitisation of CISI; Mohenjo-daro M-range only, not full Mahadevan 1977). No Zig code change for this wave: `audit-residual --json PATH` already accepts arbitrary Corpus JSON. |
| 10–50× speedup claim over Python | `projected` | README says "the Zig port should land in seconds" against ~7-minute Python baseline. **Forward-looking claim; benchmark harness not yet committed.** Downgraded from `unit-tested` to `projected` until a published benchmark exists. |
| `bin/symbols` CLI surface (`baselines`, `bench`, `audit-residual`) | `stable-on-Zig-0.16-today` | Will be locked when Zig 1.0 ships; today subject to Zig-substrate churn. `audit-residual` subcommand added 2026-05-29 as the Zig half of the cross-substrate parity harness. |
| On-disk Corpus JSON contract | `stable-on-Zig-0.16-today` | Same scope; Python interop relies on it |
| Mutation testing of hot-loop kernels | not started | analogous to mast's `tools/mutation-test.sh` discipline |
| EVA character-corpus Voynich integration test | `audited` (single-shot) | Cross-substrate residual-mean agreement on Voynich EVA chars driven end-to-end by `~/symbols/scripts/audit_residual_gap_parity.sh` 2026-05-29 with PROMOTE-OK verdict at B=40 L=100 seed=0. Continuously-verified CI step still pending. |

## Test posture

`zig build test --summary all` (verified 2026-05-21, re-verified 2026-05-27, re-verified 2026-05-29 after adding the F7-methodology module + parallel-residual variant):

```
Build Summary: 3/3 steps succeeded; 31/31 tests passed
+- run test 31 pass (31 total) 55s MaxRSS:46M
```

**No drift between README count and actual.** Re-checked 2026-05-29 — the nine `methodology/residual_gap.zig` tests cover determinism, structured-source positive-residual sanity, CI bookkeeping, percentile interpolator, error paths, **plus** serial==parallel element-wise identity and `n_threads=1` fall-through (added for the cross-substrate parity audit harness).

## Gate posture

| Gate | Status |
|---|---|
| Zig 1.0 substrate | blocked on upstream Zig 1.0 release |
| Published 10–50× speedup benchmark | not started — claim is currently projected, not measured |
| Cross-substrate numeric agreement CI step | single-shot harness shipped 2026-05-29 (`~/symbols/scripts/audit_residual_gap_parity.sh`) and confirmed `audited` on Voynich EVA chars; per-commit CI wrapper still pending |
| Mutation testing of hot-loop kernels | not started |
| Production soak | not started |
| Independent security review | not started |

## What's safe to claim right now

- **31 ERT tests pass** on Zig 0.16 / Linux x86_64.
- **All seven planned primitives + the F7 methodology glue + a parallel-replicate variant** have shipped (corpus loader, gzip compression, Shannon + conditional entropy, n-gram LM, pseudo-text generators, substitution solver, stationary bootstrap, paired-residual gzip-bpc methodology).
- **Parallelism is wired** to the four CPU-bound inner loops (solver, pseudo, bootstrap, paired-residual); deterministic per-restart / per-resample / per-replicate seeding gives bit-exact reproducibility within a backend.
- **Cross-substrate numeric agreement** was audited end-to-end on Voynich EVA character corpus 2026-05-29 via `~/symbols/scripts/audit_residual_gap_parity.sh`: residual-mean Δ within 3×combined-SE; CIs overlap. PROMOTE-OK.
- **F7 PR-A methodology agrees cross-corpus** on Linear A (30,449 chars), Rongorongo (66,801 chars), and Indus M-range subset (5,014 chars) at the same B=40 L=100 seed=0 parity gate the Voynich audit used. All three PROMOTE-OK 2026-05-29.

## What's NOT safe to claim

- That the Zig port is "10–50× faster" — that's a projection from the Python pipeline's ~7-minute baseline against an expected "seconds" scale. **A benchmark harness has not been committed.** Until it has, the claim is `projected`, not measured.
- That the public CLI surface is "locked" in a v1.0-semver sense — that's a v1.0 claim against a Zig 0.16 substrate.
- That the on-disk Corpus JSON contract is "stable" beyond the Zig 0.16 stability window.
- That the cross-substrate numeric agreement is currently enforced by **continuous** CI — a single-shot harness (`~/symbols/scripts/audit_residual_gap_parity.sh`) was run by hand 2026-05-29 with PROMOTE-OK verdict; a per-commit CI wrapper has not been wired.

## Audit history

- **2026-05-29: Cross-corpus parity extension (Indus M-range subset).** `~/symbols/scripts/audit_residual_gap_parity.sh` re-driven against `data/raw/indus/indus_chars.json` (179 CISI sides, 5,014 chars, alphabet=13), the char-level repack of the MIT-licensed `mayig/indus-valley-script-corpus` JSON digitisation of the Mohenjo-daro M-range CISI subset. Identical B=40 L=100 seed=0 parameters to Voynich/Linear A/Rongorongo. Python μ=+0.8646 vs Zig μ=+0.8515, |Δμ|=0.0132 ≤ 3×combined-SE=0.0616; CIs overlap +0.3063 bpc. PROMOTE-OK at the same tolerance gate the prior three corpora passed. No Zig code change for this wave: `audit-residual --json PATH` already accepts arbitrary Corpus JSON. Scope honesty: this is the publicly digitised CISI M-range subset, not the full Mahadevan 1977 concordance and not the full CISI; coverage row is named accordingly. Report at `~/symbols/experiments/results/audit_residual_gap_parity_indus.json`.
- **2026-05-29: Cross-corpus parity extension (Linear A + Rongorongo).** `~/symbols/scripts/audit_residual_gap_parity.sh` re-driven against `data/raw/linear_a/linear_a_chars.json` and `data/raw/rongorongo/rongorongo_chars.json` (both char-level repacks produced by `~/symbols/scripts/dump_corpus_chars_json.py` so `joinedChars("\n")` and Python `joined_text("\n")` read byte-identical input even though the upstream Corpora are token-like). Identical B=40 L=100 seed=0 parameters to the Voynich Wave-3 run. Linear A: Python μ=+0.7448 vs Zig μ=+0.7388, |Δμ|=0.0060 ≤ 3×combined-SE=0.0231; CIs overlap +0.1066 bpc. Rongorongo: Python μ=+1.1291 vs Zig μ=+1.1075, |Δμ|=0.0217 ≤ 3×combined-SE=0.0234; CIs overlap +0.1038 bpc. Both PROMOTE-OK at the same tolerance gate Voynich passed. No Zig code change, the audit-residual CLI already accepts arbitrary Corpus JSON via `--json PATH`, which is why the harness was named extensible at port time. Reports at `~/symbols/experiments/results/audit_residual_gap_parity_{linear_a,rongorongo}.json`.
- **2026-05-29 — Parallel residual variant + cross-substrate parity audit PROMOTE-OK.** Added `pairedResidualParallel(..., n_threads)` to `src/methodology/residual_gap.zig` — same per-replicate seed derivation as the serial path, so the output is element-wise identical for any thread count (locked by a serial==parallel test). Drops 8-replicate wallclock on the Voynich corpus from ~240s serial to ~44s on 8 CPUs. Wired the variant to a new `symbols audit-residual` CLI subcommand that emits a single-line JSON record. The Python sibling `~/symbols/scripts/audit_residual_gap_parity.sh` consumes this CLI as the Zig half of the parity audit: at B=40 L=100 seed=0, Python μ=+0.3385 vs Zig μ=+0.3353; Δμ=0.0031 well under tolerance 3×combined-SE=0.0147; CIs overlap by +0.056 bpc → PROMOTE-OK. Cross-substrate-agreement row advanced from `posture-observable-end-to-end (claimed)` to `audited` (single-shot). 29 → 31 tests.
- **2026-05-29 — F7 methodology primitive added.** New module `src/methodology/residual_gap.zig` ports the PR-A protocol (paired residual gzip-bpc gap with Politis-Romano stationary-bootstrap CIs) — the load-bearing computation behind the F7 cross-corpus finding (Voynich < Linear A < Rongorongo residual ordering). Previously the four input primitives (gzip-bpc, trigram-matched pseudo, stationary bootstrap, percentile aggregator) lived in `symbols-zig` separately; the methodology-level glue lived only in the Python sibling at `scripts/bootstrap_residual_gap_stationary.py`. This commit closes that gap. 22 → 29 tests.
- **2026-05-21 — Honesty correction + drift verification.** v1.0.0 "production-grade hygiene milestone" framing identified as Type-I; correction applied to CHANGELOG + this STATUS.md. The "10–50× faster" speedup claim downgraded from `unit-tested` to `projected` until benchmark ships. Test count verified at 22/22 by `zig build test --summary all` (no drift).
- **2026-05-13 — v1.0.0 tag.** Original framing was vanity-class; correction propagated from mast 2026-05-15 template.

## References

- `~/AGENT_HARNESS.md` — proof-vocabulary doctrine.
- `~/mast/STATUS.md` — the canonical model this STATUS adopts.
- `~/carreir/STATUS.md` — sibling carreir correction.
- `~/CONVENTIONS.md` — substrate-wide pattern (this file is one instance).
- `~/agent-fleet/audit/calibration/CORPUS_PART_3.md` §076-#085 — the calibration items naming the symbols-zig Type-Is.
- stax memory: `project_voynich.md`, `feedback_no_premature_production_claims.md`.
