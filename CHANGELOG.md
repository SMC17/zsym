# Changelog

All notable changes to `symbols-zig` will be documented here. Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
