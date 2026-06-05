# Cross-Tool Finding Deduplication Contract

The brownfield Phase 7 gap-consolidation recipe runs a deterministic dedup step
(`scripts/adapters/brownfield/dedup.sh`) over the merged SARIF produced by
the SARIF merge step. Without dedup, multiple scanners reporting the same vulnerability or the
same dead-code symbol inflate finding counts 2–4×, making the deterministic-tools
rollout noisier than the LLM heuristic it replaces (day-one trust-erosion guard).

Dedup uses **two key shapes** — one per finding class — because CVE findings carry
a stable global identifier while non-CVE findings (dead code, complexity, lint) do
not.

## CVE class

A finding is CVE-class iff its `ruleId` matches `^CVE-\d{4}-\d{4,}$`.

- **Key:** `(CVE-ID, file-path, severity)`.
- **Collision rule:** the same CVE in the same file at the same severity reported
  by multiple scanners is the SAME finding — collapse to one.
- **Tie-break / winner:** lowest `source_tool` ordinal, where
  `grype = 0`, `osv-scanner = 1`, `owasp-depcheck = 2` (unknown = 99). **Grype is
  canonical** because the SBOM is built around the Grype vulnerability database;
  OSV-Scanner is preserved only when Grype is absent, OWASP Dep-Check last.

### Worked example — CVE collision

Grype AND OSV-Scanner both report `CVE-2024-12345` in `lib/foo.go` at `HIGH`:

```
grype       CVE-2024-12345  lib/foo.go  HIGH
osv-scanner CVE-2024-12345  lib/foo.go  HIGH
```

→ one finding survives, `source_tool = grype` (ordinal 0).

## Non-CVE class

Everything not matching the CVE regex (dead-code, complexity, lint).

- **Grouping key:** `(file-path, symbol-qualifier)`.
- **Collision rule:** the same symbol in the same file flagged by multiple tools
  is the SAME finding — collapse to one.
- **Winner:** highest precision per the **precision ladder**
  (`deadcode-go = 0` > `spotbugs = 1` > `vulture = 2` > `lint = 3`; unknown = 99).

> **Key-shape note (intent vs. literal spec).** The literal text spells the
> non-CVE key as `(tool, file-path, symbol-qualifier)`. But if `tool` is part of
> the GROUPING key, the same symbol reported by two different tools never
> collides — so the precision ladder (whose entire purpose is to pick the best
> tool for the *same* symbol) could never fire, and the inflation-reduction goal
> would be unreachable for non-CVE findings. This contract therefore groups by
> `(file-path, symbol-qualifier)` and uses `tool` ONLY to select the winner via
> the precision ladder — implementing the stated GOAL rather than its
> self-contradictory literal MECHANISM. The deviation is recorded in the story
> Findings table.

### Precision ladder (non-CVE winner selection)

1. `deadcode-go` — Go Rapid Type Analysis binary verdict (zero false positives by construction).
2. `spotbugs` — JVM priority-1 / rank ≤ 4 (near-binary precision).
3. `vulture` — Python `--min-confidence 80` (confidence-graded).
4. `lint` — heuristic, last resort.

Higher-precision tool wins the tie.

### Worked example — non-CVE collision

`deadcode-go` and `vulture` both flag `internal/util/dead.go` symbol `Bar`:

```
deadcode-go  internal/util/dead.go  Bar
vulture      internal/util/dead.go  Bar
```

→ one finding survives, `source_tool = deadcode-go` (precision rank 0).

### Worked example — multi-stack dead-code, three tools, same symbol

`deadcode-go`, `spotbugs`, and `vulture` all flag `pkg/y.go` symbol `Sym`:

→ one finding survives, `source_tool = deadcode-go` (lowest precision rank wins
over `spotbugs`=1 and `vulture`=2).

## Inflation reduction

On a representative multi-tool scan the contract targets a 2–4× reduction. The
canonical fixture (`tests/fixtures/dedup-contract/inflation-8to2.json`) is
engineered so 8 raw findings (a CVE group of 4 + a non-CVE group of 4) collapse to
2 deduped findings. Single-tool scans see no reduction (no duplicates) — both
cases are normal.

## Path canonicalization

Both `file-path` values in the dedup keys MUST be repo-root-relative. The SARIF
merge step canonicalizes `artifactLocation.uri` to repo-root-relative
BEFORE dedup runs, so dedup keys on those paths verbatim.

## Empty input

If the merged SARIF is empty or has zero findings, dedup emits an empty stream and
both telemetry counters (`gap_count_before_dedup`, `gap_count_after_dedup`) are 0.
No error.

## Pipeline position

Dedup is the FIRST sub-step of the 6-step gap-consolidation recipe
(load → **dedup** → validate → rank → budget → write), AFTER the SARIF merge
PRE-step and BEFORE the Phase 4b reconciliation. Dedup-first reduces the
working set that downstream validate/rank/budget process.

## I/O paths

- **Input:** `.gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json`
  (the SARIF merge step's actual output; env-overridable via `DEDUP_INPUT`). The story seed
  referenced a stale `.gaia/memory/brownfield-audit/merged-sarif.json` path — see
  the story Findings table.
- **Output:** `.gaia/memory/brownfield-audit/deduped-findings.json`
  (env-overridable via `DEDUP_OUTPUT`; consumed by the Phase 4b reconciliation).
