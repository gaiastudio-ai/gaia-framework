---
name: gaia-atdd
description: Generate failing acceptance tests using TDD methodology from a story's acceptance criteria. Converts each AC into a Given/When/Then test skeleton following the red phase of TDD. Supports single-story invocation and argumentless batch mode that discovers high-risk stories from epics-and-stories.md.
argument-hint: "[story-key]   (omit for batch mode)"
allowed-tools: [Read, Write, Edit, Bash]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-atdd/scripts/setup.sh

## Mission

You are generating Acceptance Test-Driven Development (ATDD) artifacts for the specified story key. Each acceptance criterion from the story file is transformed into a failing test skeleton using Given/When/Then format. The output is saved to the per-story mirror path under `test-artifacts/` (AF-2026-05-30-1 / Test03 §7.3): `.gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{story_key}-{story_slug}/atdd.md`. Path resolution is delegated to `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh` (the new home matches implementation-artifacts mirror symmetry). Legacy flat `.gaia/artifacts/test-artifacts/atdd-{story_key}.md` remains a read-only fallback during the migration window.

The skill supports two invocation modes:

1. **Single-story mode** — `/gaia-atdd E1-S1` — generate ATDD for one explicit story key. This is the original legacy behavior.
2. **Batch mode** (argumentless invocation, FR-351) — `/gaia-atdd` — scan `.gaia/artifacts/planning-artifacts/epics-and-stories.md` for stories whose risk column is exactly `high`, present an `[all / select / skip]` menu, and generate ATDD artifacts for the chosen subset. When zero high-risk stories are discovered, exit gracefully with the message "No high-risk stories found — nothing to generate" (exit code 0).

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/atdd/` workflow (brief Cluster 4, story E28-S83). Batch mode and the optional Step 5b red-phase execution are restored under E46-S3 / FR-351.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- The `story-key` argument is **optional** — when present it MUST follow the `E{number}-S{number}` format (e.g., `E1-S1`, `E28-S83`). When malformed (empty string, missing epic prefix like "S83" without "E{n}-" prefix), exit with a clear validation error message naming the invalid argument.
- When a story-key is supplied and the key is not found in `.gaia/artifacts/planning-artifacts/epics-and-stories.md`, exit with error: "Story {key} not found in epics-and-stories.md" and a non-zero exit code. Do NOT fall back to batch mode (AC-EC3) — the user explicitly asked for one story.
- When no story-key is supplied, engage **batch mode** (argumentless invocation): scan `.gaia/artifacts/planning-artifacts/epics-and-stories.md` for high-risk entries via the bundled `scripts/discover-stories.sh` helper. If `epics-and-stories.md` is missing or unreadable, print "Cannot read .gaia/artifacts/planning-artifacts/epics-and-stories.md — halting" and exit non-zero (AC-EC1).
- A story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md` before proceeding. If the story file is not found for the given key, exit with error: "Story file not found for {story_key}".
- The story file MUST contain an `## Acceptance Criteria` section with at least one AC entry. If no acceptance criteria are found or the section is empty, exit gracefully with the message: "No acceptance criteria found for {story_key}" and write no ATDD artifact.
- Each acceptance criterion maps to exactly one failing test skeleton — maintain a strict 1:1 AC-to-test mapping.
- All generated tests MUST use **Given/When/Then** format for behavior specification.
- Tests are in the **red phase of TDD** — they describe expected behavior and must fail because the implementation does not exist yet. Do NOT write implementation code.
- Output MUST be written to the resolver-returned path. Resolve the write path via `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh atdd {story_key} --write` (returns `.gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{story_key}-{story_slug}/atdd.md`; the helper mkdir -p's the parent dir). On pre-AF-30-1 projects, the legacy flat `.gaia/artifacts/test-artifacts/atdd-{story_key}.md` form remains a read-only fallback. If the file already exists from a prior run, overwrite it idempotently — no duplicate content or stale remnants should remain. Existing flat artifacts are NEVER migrated implicitly; the migration helper `scripts/migrate-test-artifacts-to-per-story.sh` moves them once when invoked explicitly.
- If the generated ATDD output exceeds 10KB (e.g., a story with 20+ ACs), the size advisory fires from `finalize.sh`. The level is risk-aware (E80-S1 AC9): for `risk: high` stories the advisory logs at `[INFO]` (high-risk stories legitimately produce more content); for `medium` / `low` / unset risk it logs at `[WARNING]`. Output must remain complete with no truncation regardless of size.
- Only high-risk stories typically require ATDD. If the story risk level is not "high", proceed anyway but note in the output header that ATDD was invoked explicitly.

## Steps

### Step 1 -- Validate Input

- If a story key was provided as an argument (e.g., `/gaia-atdd E1-S1`), use it directly.
- Validate story key format: must match `E{number}-S{number}` pattern. If malformed, exit with error: "Invalid story key format: {story_key}. Expected format: E{n}-S{n}".
- When a story-key is supplied and it does not appear in `.gaia/artifacts/planning-artifacts/epics-and-stories.md`, exit with "Story {key} not found in epics-and-stories.md" and a non-zero exit code (AC-EC3). Do NOT auto-engage batch mode as a fallback.
- If no story key was provided, switch to **batch mode** (Step 1b) — do NOT exit.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-atdd 1 story_key="$STORY_KEY" test_file_path=".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md" stage=input-validated`

### Step 1b -- Batch Discovery (argumentless invocation only)

When invoked without a story-key, run batch discovery:

- Invoke `!${CLAUDE_PLUGIN_ROOT}/skills/gaia-atdd/scripts/discover-stories.sh --epics .gaia/artifacts/planning-artifacts/epics-and-stories.md --format=menu` to render the discovery menu.
- The script:
  - Halts with "Cannot read .gaia/artifacts/planning-artifacts/epics-and-stories.md — halting" and exit code 1 when the epics file is missing or unreadable (AC-EC1).
  - Filters rows where the Risk column is exactly `high` (per Dev Notes — exact-value match, not substring). Medium and low risk rows are excluded.
  - Builds a discovery result object per story `{key, title, risk, epic, ac_count}` and surfaces them as a numbered menu listing key, title, and risk.
  - Skips stories whose source file has zero acceptance criteria with a warning "Story {key} has no acceptance criteria — skipping" (AC-EC8) — `ac_count = 0` drives the skip.
- When zero high-risk stories are discovered, the script prints the canonical message **"No high-risk stories found — nothing to generate"** and exits with code 0 (AC5 / VCP-ATDD-05).
- When exactly one high-risk story is discovered, the menu collapses to `[all / skip]` — the `select` option is suppressed because there is nothing to choose among (AC-EC7).
- Otherwise, present the user with `[all / select / skip]`:
  - **all** — iterate every discovered key; generate ATDD skeletons for each (AC2 / VCP-ATDD-02).
  - **select** — prompt for a comma-separated list of 1-based indices (e.g., `1,3`). Pass the selection to `discover-stories.sh --select=1,3 --format=keys` to resolve the chosen keys. Out-of-range or non-numeric entries return a non-zero exit and the message "Invalid selection" — re-prompt the menu instead of proceeding (AC-EC6).
  - **skip** — print "Skipped — no tests generated" and exit 0.

### Step 1c -- Per-Story Iteration (batch mode)

- For each resolved key, execute Steps 2 through 5 below as a self-contained sub-invocation. Failures on one story (missing story file, empty AC section) emit a warning and continue to the next key — they do NOT abort the whole batch.
- Track a per-story result summary distinguishing **generated** (no prior artifact) from **overwritten** (prior artifact existed). Print the summary at the end of the batch.
- If the user interrupts mid-batch (Ctrl-C), the atomic-write pattern (Step 4) guarantees completed artifacts remain intact and the in-progress artifact is either fully written or absent — never partial (AC-EC9).

### Step 2 -- Load Story File

- Search `.gaia/artifacts/implementation-artifacts/` for a file matching `{story_key}-*.md`.
- If no story file is found, exit with error: "Story file not found for {story_key}".
- Read the story file and extract:
  - Story title from frontmatter
  - Risk level from frontmatter (default: "low" if absent)
  - Acceptance criteria from the `## Acceptance Criteria` section
- If the Acceptance Criteria section is missing or contains no AC entries, exit with: "No acceptance criteria found for {story_key}".

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-atdd 2 story_key="$STORY_KEY" test_file_path=".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md" ac_count="$AC_COUNT" stage=story-loaded`

### Step 3 -- Generate AC-to-Test Mapping

- Load knowledge fragment: `knowledge/api-testing-patterns.md` for schema validation and contract test patterns relevant to AC-to-test transformation
- For each acceptance criterion (AC1, AC2, AC-EC1, etc.):
  - Extract the AC identifier and description
  - Transform the AC into a Given/When/Then test skeleton
  - Name the test descriptively to reflect the AC being validated
  - **Anti-stub Then-clause (E88-S5, FR-DPD-5, ADR-107).** After the functional Given/When/Then is drafted, invoke `scripts/lib/atdd-anti-stub-emit.sh --ac-text "<ac body>"` and APPEND its output (if any) to the scenario. The helper sources `lib/dispatch-verb-match.sh` (E88-S1) and `lib/canonicalize-dispatch-verb.sh` (this story) to emit one additive Then-clause per unique dispatch primitive matched in the AC body. Non-dispatch ACs receive no clause (byte-for-byte unchanged from pre-E88-S5 behaviour). The clause shape is literal: `Then: $*_STUB env vars are unset AND a real <primitive> was logged`, with `<primitive>` ∈ {`Agent-tool spawn`, `Agent-tool dispatch`, `primitive invocation`, `wiring`, `primitive call`} per the canonicalization map.
- Build a traceability table mapping each AC to its corresponding test

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-atdd 3 story_key="$STORY_KEY" test_file_path=".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md" ac_count="$AC_COUNT" stage=mapping-generated`

### Step 4 -- Write ATDD Artifact

- Generate the ATDD document with the following structure:
  - Header: story key, title, risk level, generation date
  - AC-to-test mapping table (AC ID, AC description, test name)
  - Test skeletons in Given/When/Then format for each AC
  - Summary: total ACs, total tests, confirmation all tests are in failing/red state
- Write the artifact to `.gaia/artifacts/test-artifacts/atdd-{story_key}.md` using an **atomic write**: write to a temp path (e.g., `atdd-{story_key}.md.tmp`) first, then `mv` the temp path over the final path on success. This guarantees a Ctrl-C mid-write never leaves a corrupted file (AC-EC9 — interrupt safety).
- **Idempotency policy** — if the artifact path already exists from a prior run, overwrite it with a logged warning: "Overwriting existing ATDD artifact at {path}". The policy is `overwrite with warning` (AC-EC10, AC-EC11). In batch mode the per-story result summary distinguishes **generated** from **overwritten** so the user can audit the run.
- After writing, the size advisory is emitted by `finalize.sh` (E80-S1) — risk-aware: `[INFO]` for `risk: high`, `[WARNING]` for medium / low / unset. The skill body itself does not need to repeat the check.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-atdd 4 story_key="$STORY_KEY" test_file_path=".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md" ac_count="$AC_COUNT" batch_mode="$BATCH_MODE" stage=artifact-written --paths ".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md"`

### Step 5 -- Validation

- Verify every AC from the story has exactly one corresponding test in the output
- Verify no test references an AC that does not exist in the story
- Verify all tests use Given/When/Then format
- Verify the output file was written successfully

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-atdd 5 story_key="$STORY_KEY" test_file_path=".gaia/artifacts/test-artifacts/atdd-$STORY_KEY.md" ac_count="$AC_COUNT" stage=validated`

### Step 5b -- Optional Red-Phase Execution

After Step 5, prompt the user: **"Run generated tests now to confirm red phase? [y/N]"**

- On `n` (default), skip this step entirely.
- On `y`, invoke `!${CLAUDE_PLUGIN_ROOT}/skills/gaia-atdd/scripts/run-red-phase.sh --tests .gaia/artifacts/test-artifacts/atdd-{story_key}.md` to execute the configured Test Execution Bridge runner (ADR-026):
  - The script reads `.gaia/artifacts/test-artifacts/test-environment.yaml`. When the file is absent or `bridge_enabled: false`, it logs the warning **"Test runner not configured — skipping red-phase execution"** and exits 0 — the overall `/gaia-atdd` invocation is NOT failed (AC-EC4 non-blocking fallback).
  - When a runner is configured, the script enforces a per-test timeout (default 30s, configurable via `--timeout`). Hangs are marked `FAIL (timeout)` and the batch continues to the next test (AC-EC5).
  - The script reports a `red-phase summary: pass=N fail=M` line. All counts are expected to be fails — this is the TDD red phase, the implementation does not exist yet (AC4 / VCP-ATDD-04).
  - When any test unexpectedly PASSES during red phase, the script logs the warning "{N} test(s) unexpectedly passed during red phase — may not be testing unimplemented behavior". This is informational; the script still exits 0.

## Validation

<!--
  E42-S15 — V1→V2 5-item checklist port (FR-341, FR-359, VCP-CHK-33, VCP-CHK-34).
  Classification (5 items total — V1 verbatim, no extras):
    - Script-verifiable: 1 (SV-01) — enforced by finalize.sh.
    - LLM-checkable:     4 (LLM-01..LLM-04) — evaluated by the host LLM
      against the atdd-{story_key}.md artifact at finalize time.
  Exit code 0 when the 1 script-verifiable item PASSes; non-zero otherwise.

  V1 source: 5 items (clean). V1 → V2 mapping (1:1, no drop, no merge):
    V1 "Acceptance criteria loaded from story/PRD"        → LLM-01 (semantic)
    V1 "Each AC mapped to exactly one test"               → LLM-02 (semantic)
    V1 "Tests fail initially (red phase)"                 → LLM-03 (semantic)
    V1 "Tests are atomic and independent"                 → LLM-04 (semantic)
    V1 "Test-to-AC traceability documented"               → SV-01 (heading + table)

  Only the traceability item is mechanically observable in artifact body
  (## AC-to-Test Mapping heading + |AC*| table row); the other four are
  semantic ATDD-quality judgements that require host LLM evaluation
  against the story / PRD context.

  Invoked by `finalize.sh` at post-complete (per architecture §10.31.1).
  Validation runs BEFORE the checkpoint and lifecycle-event writes
  (observability is never suppressed by checklist outcome — story AC6).

  See .gaia/artifacts/implementation-artifacts/E42-S15-port-gaia-test-framework-atdd-ci-setup-checklists-to-v2.md.
-->

- [script-verifiable] SV-01 — Test-to-AC traceability documented
- [LLM-checkable] LLM-01 — Acceptance criteria loaded from story/PRD
- [LLM-checkable] LLM-02 — Each AC mapped to exactly one test
- [LLM-checkable] LLM-03 — Tests fail initially (red phase)
- [LLM-checkable] LLM-04 — Tests are atomic and independent

## Changelog

- **2026-05-14 — E88-S5 — Anti-stub Then-clause for dispatch-verb ACs (FR-DPD-5, ADR-107, AI-2026-05-13-7).** Added a sub-step to Step 3 (Generate AC-to-Test Mapping) that invokes `scripts/lib/atdd-anti-stub-emit.sh --ac-text "<ac body>"` after the functional Given/When/Then is drafted. The helper sources `lib/dispatch-verb-match.sh` (E88-S1) and `lib/canonicalize-dispatch-verb.sh` (this story) to emit one additive Then-clause per unique dispatch primitive matched in the AC body — clause shape: `Then: $*_STUB env vars are unset AND a real <primitive> was logged` with `<primitive>` from the canonicalization map (`Agent-tool spawn`, `Agent-tool dispatch`, `primitive invocation`, `wiring`, `primitive call`). Multi-verb ACs get dedup'd clauses (one per unique primitive). Non-dispatch ACs receive NO clause (byte-for-byte unchanged from pre-E88-S5). Closes the drift class from AI-2026-05-13-7 (E76-S10 retro headline: ATDD scenarios passing while dispatch was stub-only) at the ATDD layer; E88-S3 closes the same gap at the PR-creation layer (forbidden-sentinel scan).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-atdd/scripts/finalize.sh
