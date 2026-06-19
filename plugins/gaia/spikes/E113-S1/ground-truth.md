# Ground Truth: PR Stack Classification

Spike: E113-S1 — Selective Test Execution Feasibility
Date: 2026-06-17

## Glob normalization reference

The project-config.yaml `stacks[gaia-plugin].paths` globs carry a `gaia-public/` prefix
that is absent from `git diff --name-only` output. `detect-affected.sh` normalizes each
glob before matching:

| Raw glob (from config)                            | Normalized prefix (used for matching) |
|---------------------------------------------------|---------------------------------------|
| `gaia-public/plugins/gaia/scripts/**`             | `plugins/gaia/scripts`                |
| `gaia-public/plugins/gaia/skills/**`              | `plugins/gaia/skills`                 |
| `gaia-public/plugins/gaia/agents/**`              | `plugins/gaia/agents`                 |
| `gaia-public/plugins/gaia/knowledge/**`           | `plugins/gaia/knowledge`              |
| `gaia-public/plugins/gaia/tests/**`               | `plugins/gaia/tests`                  |
| `gaia-public/plugins/gaia/schemas/**`             | `plugins/gaia/schemas`                |
| `gaia-public/plugins/gaia/templates/**`           | `plugins/gaia/templates`              |

**Not in glob list:** `gaia-public/plugins/gaia/config/**` — this is a coverage gap.

---

## PR #1548 (fix: harden observability reports + replace bubble sort)

| Changed file | Directory prefix | Detected stack | Correct? |
|---|---|---|---|
| `plugins/gaia/scripts/step-report.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/scripts/throughput-telemetry.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-update-index.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/brain-capstone/coverage-map.tsv` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/observability-hardening/*.jsonl` (9 files) | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/observability-hardening.bats` | `tests` | gaia-plugin | YES |

**Prototype output:** `["gaia-plugin"]`
**Manually verified output:** `["gaia-plugin"]`
**False positives:** 0  **False negatives:** 0
**Accuracy:** 14/14 files correctly classified (100%)

---

## PR #1547 (fix: harden the brain lesson layer + backfill test coverage)

| Changed file | Directory prefix | Detected stack | Correct? |
|---|---|---|---|
| `plugins/gaia/scripts/brain/gaia-unfeed.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/scripts/brain/update-brain-index.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/scripts/review-gate.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-retro/scripts/emit-brain-lessons.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-capstone.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-freshness-hooks.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-retro-lesson.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-unfeed.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/brain-update-index.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/brain-capstone/coverage-map.tsv` | `tests` | gaia-plugin | YES |

**Prototype output:** `["gaia-plugin"]`
**Manually verified output:** `["gaia-plugin"]`
**False positives:** 0  **False negatives:** 0
**Accuracy:** 10/10 files correctly classified (100%)

---

## PR #1545 (feat: pixel-diff visual regression + baseline lifecycle)

| Changed file | Directory prefix | Detected stack | Correct? |
|---|---|---|---|
| `plugins/gaia/config/project-config.schema.yaml` | `config` | — (unmatched) | **FALSE NEGATIVE** |
| `plugins/gaia/scripts/lib/resolve-artifact-path.sh` | `scripts` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/SKILL.md` | `skills` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/scripts/approve-baseline.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/scripts/capture-screenshot.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/scripts/dispatch-surface.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/scripts/pixel-diff.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/skills/gaia-test-manual/scripts/read-visual-diff-config.sh` | `skills` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/pixel-diff/baseline-*.png` (3 files) | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/pixel-diff/generate-fixtures.sh` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/fixtures/pixel-diff/screenshot-*.png` (6 files) | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/pixel-diff-ac1-capture-and-diff.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/pixel-diff-ac2-thresholds-and-masking.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/pixel-diff-ac3-baseline-approval.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/pixel-diff-ac4-no-baseline-unverified.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/pixel-diff-unit.bats` | `tests` | gaia-plugin | YES |
| `plugins/gaia/tests/test-manual-surface-api.bats` | `tests` | gaia-plugin | YES |

**Prototype output:** `["gaia-plugin"]`
**Manually verified output:** `["gaia-plugin"]`

**Stack detection verdict:** CORRECT — the PR is correctly identified as touching `gaia-plugin`.
However, the `config/` file is silently unclassified. In a multi-stack repo this would be a
false negative at the individual-file level. In this single-stack repo the stack-level result
is still correct (the PR IS touching gaia-plugin, just via other files too).

**False positives:** 0
**False negatives (file-level):** 1 (`plugins/gaia/config/project-config.schema.yaml`)
**False negatives (stack-level):** 0 — gaia-plugin was still detected via the other 23 files

---

## Coverage gaps

1. **`plugins/gaia/config/**` not in glob list** — any PR that ONLY touches `config/` files
   would return `[]` instead of `["gaia-plugin"]`. This is a real false-negative at the
   stack-detection level. Fix: add `"gaia-public/plugins/gaia/config/**"` to stacks[gaia-plugin].paths.
   This is a 1-line config change, deferred to S2.

2. **Single-stack limitation** — this repo has one stack. Cross-stack savings (the primary
   business driver) cannot be measured empirically here. Projections are extrapolations only.
