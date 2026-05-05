# `review-common/` — Shared Library for GAIA Review-System v2

> **Story:** E66-S1 — Foundation for the twelve verdict-producing skills.
> **Decision:** ADR-077 (Three-Tier Review Pipeline) — extends ADR-075.
> **Stability:** Stable public API. All review skills under E66/E67/E68/E69 wire through this library.

## Purpose

`review-common/` is the **single shared foundation** for the twelve verdict-producing skills introduced by ADR-077:

- six review skills: `gaia-code-review`, `gaia-review-qa`, `gaia-review-test`, `gaia-test-automate`, `gaia-review-security`, `gaia-review-perf`
- one conditional pre-merge gate: `gaia-review-mobile`
- one design-validation skill: `gaia-validate-design-a11y`
- five deployment-phase action skills: `gaia-test-e2e`, `gaia-test-perf`, `gaia-test-dast`, `gaia-test-a11y`, `gaia-deploy`
- two mobile/device skills: `gaia-test-mobile-e2e`, `gaia-test-device-matrix`

By centralizing `(skill, stack) -> (agent-id, sidecar-path)` resolution and the strict-precedence verdict resolver, the twelve skills converge on a single contract — eliminating the ad-hoc evidence pipelines that ADR-075 / ADR-077 were created to retire.

## Public API

### `agent-overlay.sh`

Resolves the canonical `(agent-id, sidecar-path)` pair for a verdict-producing skill per the ADR-077 wiring table. Runs in the **parent context** before fork dispatch — fork tool allowlist `[Read, Grep, Glob, Bash]` stays intact (NFR-RSV2-5).

**Entry points:**
```
agent-overlay.sh --skill <skill-name> [--stack <canonical-stack>]
agent-overlay.sh --help
```

**Arguments:**

| Flag | Required | Description |
|---|---|---|
| `--skill <name>` | yes | One of the 15 ADR-077 wiring-table skill variants (see Wiring Table below). |
| `--stack <stack>` | only for `--skill gaia-review-code` | Canonical stack name. One of: `ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`. |
| `--help` | no | Print usage and exit 0. |

**Output contract (stdout, single line, no `jq` dependency):**

```
{"agent_id":"<id>","sidecar_path":"<path>"}
```

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success — JSON emitted on stdout. |
| `1` | Caller error — unknown skill, missing required flag, invalid stack, or missing `--stack` for `gaia-review-code`. Diagnostic on stderr. |

**Wiring table (ADR-077 §7613–§7627):**

| Skill | Agent | Stack-conditional? |
|---|---|---|
| `gaia-review-code` | stack-specific reviewer | yes — `--stack` required |
| `gaia-review-qa` | `vera` | no |
| `gaia-review-test` | `sable` | no |
| `gaia-test-automate` | `sable` | no |
| `gaia-review-security` | `zara` | no |
| `gaia-review-perf` | `juno` | no |
| `gaia-review-mobile` | `talia` | no |
| `gaia-validate-design-a11y` | `christy` | no |
| `gaia-test-e2e` / `-perf` / `-dast` / `-a11y` (post-deploy) | `sable` | no |
| `gaia-test-mobile-e2e` / `-device-matrix` | `talia` | no |
| `gaia-deploy` | `soren` | no |

**Sidecar convention:** `_memory/<agent-id>-sidecar.md`.

**Examples:**

```bash
# Resolve the QA reviewer for any project.
agent-overlay.sh --skill gaia-review-qa
# -> {"agent_id":"vera","sidecar_path":"_memory/vera-sidecar.md"}

# Resolve the code reviewer for a TypeScript project.
agent-overlay.sh --skill gaia-review-code --stack ts-dev
# -> {"agent_id":"ts-dev","sidecar_path":"_memory/ts-dev-sidecar.md"}

# Unknown skill — exit 1, diagnostic on stderr.
agent-overlay.sh --skill gaia-not-real
# stderr: agent-overlay.sh: unknown skill: 'gaia-not-real' (not in ADR-077 wiring table)
```

### `verdict-resolver.sh`

Re-export wrapper around `../verdict-resolver.sh` (the canonical script created under E65-S1, parameterized by E66-S1 to accept any skill's `analysis-results.json` per FR-RSV2-3).

**Entry points:**
```
verdict-resolver.sh [--skill <name>] --analysis-results <path> --llm-findings <path>
verdict-resolver.sh --help
```

**Arguments:**

| Flag | Required | Description |
|---|---|---|
| `--skill <name>` | no | Producing skill name. Logged in stderr provenance only — does NOT alter precedence. |
| `--analysis-results <path>` (alias `--analysis`) | yes | Phase 3A `analysis-results.json` path. |
| `--llm-findings <path>` | yes | Phase 3B LLM findings JSON path. |
| `--help` | no | Print usage and exit 0. |

**Output contract (stdout):** exactly one of `APPROVE` | `REQUEST_CHANGES` | `BLOCKED`.

**Strict verdict precedence (ADR-075, unchanged):**

1. Any `check.status == "errored"` → `BLOCKED`
2. Any `check.status == "failed"` with blocking finding → `REQUEST_CHANGES`
3. Any LLM finding `severity == "Critical"` → `REQUEST_CHANGES`
4. Otherwise → `APPROVE`

First-match-wins. The LLM cannot override a deterministic tool failure — this is the ADR-075 LLM-cannot-override invariant (FR-DEJ-6), preserved unchanged under ADR-077.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success — verdict emitted on stdout. |
| `1` | Caller error — missing/unknown flag. |

(Malformed `analysis-results.json` produces `BLOCKED` on stdout with the error on stderr — verdict is data, not exit code, per ADR-042.)

### `composite-verdict-aggregator.sh` (E66-S3, ADR-082)

Deterministic shell aggregator that consumes per-gate verdicts produced by the verdict-resolver runs (one per review skill) and emits a composite verdict mapped to the canonical Review Gate vocabulary. Pure shell — no LLM (NFR-RSV2-12). Invariant under YOLO mode (ADR-067).

**Entry points:**
```
composite-verdict-aggregator.sh \
  --code <verdict> --qa <verdict> --test <verdict> \
  --security <verdict> --perf <verdict> \
  ( --a11y <verdict> | --skip-a11y "<reason>" ) \
  ( --mobile <verdict> | --skip-mobile "<reason>" )
composite-verdict-aggregator.sh --help
```

**Output (stdout, multi-line):**

```
composite=<APPROVE|REQUEST_CHANGES|BLOCKED>
review_gate=<PASSED|FAILED>
included=<comma-separated gate short-names in canonical order>
skipped=<comma-separated gate short-names | "" when none>
gate=<name> verdict=<verdict>      (one line per included gate)
<name> skipped — <reason>          (one line per skipped gate)
```

**Precedence (first-match-wins, ADR-082):** any included gate `BLOCKED` → `BLOCKED`; otherwise any included gate `REQUEST_CHANGES` → `REQUEST_CHANGES`; otherwise `APPROVE`. Mapping to the Review Gate vocabulary follows ADR-075: `APPROVE → PASSED`, `REQUEST_CHANGES → FAILED`, `BLOCKED → FAILED`.

### `grace-window.sh` (E66-S3, ADR-082)

Compares a GATING-flip activation timestamp to "now" and emits the gating mode: `WARNING` during the seven-day grace window, `BLOCK` after.

**Entry points:**
```
grace-window.sh --flip-timestamp <epoch> [--now <epoch>]
grace-window.sh --help
```

**Output:**

```
mode=<WARNING|BLOCK>
days_elapsed=<int>
days_remaining=<int>           (0 when mode=BLOCK)
recommendation=<text>          (only when mode=WARNING)
```

The optional `--now` flag injects a synthetic clock for testing; default is `date -u +%s`. The seven-day boundary is exact (≥7×86400 seconds elapsed → BLOCK).

### `gating-flip-guard.sh` (E66-S3, ADR-082)

Two operations enveloping the GATING-flip deployment:

```
gating-flip-guard.sh --check-boundary --sprint-status <yaml>
gating-flip-guard.sh --scan --impl-dir <dir>
```

`--check-boundary` refuses the flip if any story in the active `sprint-status.yaml` has `status: in-progress` (sprint-boundary semantics, AC4). `--scan` enumerates `status: review` stories whose Review Gate has any non-`PASSED` row (one-time pre-flip scan, AC5).

**Exit codes:** 0 success; 1 caller error or mid-sprint refusal.

## Determinism (NFR-RSV2-1)

Both scripts are pure deterministic shell — no LLM reasoning, no network, no jitter. They produce byte-identical output for byte-identical input. The verdict resolver's precedence logic is first-match-wins; `agent-overlay.sh` is a static `case/esac` over the wiring table.

## Fork-Isolation (NFR-RSV2-5 / NFR-048)

These scripts are invoked in the **parent context** before the fork dispatch. They do NOT run inside the fork. The fork tool allowlist remains `[Read, Grep, Glob, Bash]` for all twelve verdict-producing skills.

## POSIX Discipline

Both scripts follow the GAIA shell-script standard:

- `#!/usr/bin/env bash`
- `set -euo pipefail`
- `LC_ALL=C` for collation determinism
- macOS `/bin/bash` 3.2 compatible (no associative arrays, no `${var^^}`-style expansions)
- No `jq` dependency for `agent-overlay.sh` output (uses `printf` to emit JSON)

## Tests

- `plugins/gaia/tests/agent-overlay.bats` — 15 skill variants + 7 stacks + error cases
- `plugins/gaia/tests/verdict-resolver-parameterized.bats` — `--skill` parameterization across non-code-review skills + four precedence rules under the parameterized form
- `plugins/gaia/tests/verdict-resolver.bats` — legacy backward-compat coverage (omitting `--skill`)
- `plugins/gaia/tests/evidence-judgment-parity.bats` — drift-prevention parity suite (consumers added per E66-S2..S5, E67..E69)
- `plugins/gaia/tests/composite-verdict-aggregator.bats` — E66-S3 aggregator tests (AC1, AC2, AC3, AC9, AC10)
- `plugins/gaia/tests/grace-window.bats` — E66-S3 grace-window tests (AC6, AC7)
- `plugins/gaia/tests/gating-flip-guard.bats` — E66-S3 deployment-guard tests (AC4, AC5)

## References

- ADR-082: Composite Verdict GATING Migration (E66-S3 anchor)
- ADR-077: Three-Tier Review Pipeline (extends ADR-075)
- ADR-075: Review Skill Evidence/Judgment Split
- ADR-074: Determinism (opus pin, temperature 0)
- ADR-067: YOLO CRITICAL still halts (composite gating not bypassed by YOLO)
- ADR-054: Composite Review Gate Check (read semantics extended by E66-S3)
- ADR-045: Fork-Context Isolation
- ADR-042: Scripts-over-LLM
- NFR-048: No-Write Fork
- FR-RSV2-1, FR-RSV2-3, FR-RSV2-4, FR-RSV2-43, FR-RSV2-44
- NFR-RSV2-1, NFR-RSV2-5, NFR-RSV2-6, NFR-RSV2-12
