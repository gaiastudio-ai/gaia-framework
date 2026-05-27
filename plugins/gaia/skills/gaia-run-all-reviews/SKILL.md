---
name: gaia-review-all
description: Run all 6 review workflows sequentially via subagents. Use when "run all reviews" or /gaia-review-all (formerly /gaia-run-all-reviews).
argument-hint: "[story-key] [--force]"
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-run-all-reviews]
deprecated_since: sprint-37
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

## Mission

You are running all 6 review workflows sequentially inline for a story. The story is resolved by `{story_key}` by searching for `{story_key}-*.md` under `docs/implementation-artifacts/` — both the legacy flat layout (`docs/implementation-artifacts/{story_key}-*.md`) and the canonical nested layout (`docs/implementation-artifacts/epic-*/stories/{story_key}-*.md`) per ADR-070. You orchestrate each review in deterministic order, update the Review Gate table after each, and report a summary of all verdicts.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/run-all-reviews` workflow (brief Cluster 9, story E28-S72, ADR-042, ADR-045). Under E58 it became a **thin orchestrator** (FR-RAR-6): every mechanical step lives in a deterministic bash script, and the LLM only does per-reviewer judgment work.

**Inline orchestration:** This skill runs all 6 reviews sequentially inline within a single context. It does NOT spawn nested subagents (to avoid nesting limitations). Each review is executed in-process by loading and following the relevant reviewer skill's instructions.

**Sequential-only contract (ADR-045):** The review gate is intentionally sequential. Parallel execution would create race conditions on the Review Gate table. The canonical order is never reordered.

**Scripts-over-LLM (ADR-042):** the LLM does NOT count gate rows, write the summary file, classify the composite verdict, or render the nudge — those are deterministic and live in `review-skip-check.sh`, `review-summary-gen.sh`, `review-gate.sh review-gate-check`, and `review-nudge.sh` respectively.

### Worked Example

```text
$ /gaia-run-all-reviews E58-S6
# Step 2.2: review-skip-check.sh emits {"skip":["code-review","qa-tests","security-review","test-automate","test-review"],"run":["review-perf"]}
# Step 2.3: 1 LLM judgment fires (review-perf), gate row written PASSED
# Step 2.4: 5 SKIPPED entries recorded for the summary block
# Step 3:   review-summary-gen.sh writes the locked summary file
#           review-gate.sh review-gate-check exits 0 (COMPLETE)
#           review-nudge.sh emits the progressive nudge block

$ /gaia-run-all-reviews E58-S6 --force
# Step 2.2: review-skip-check.sh --force emits {"skip":[],"run":["code-review","qa-tests","security-review","test-automate","test-review","review-perf"]}
# Step 2.3: all 6 LLM judgments fire; gate rows rewritten
# Summary block: zero SKIPPED entries; six verdicts.
```

A summary block with 5 SKIPPED + 1 ran reads (excerpt):

```text
- Code Review        SKIPPED (already PASSED)
- QA Tests           SKIPPED (already PASSED)
- Security Review    SKIPPED (already PASSED)
- Test Automation    SKIPPED (already PASSED)
- Test Review        SKIPPED (already PASSED)
- Performance Review PASSED — see report
```

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-run-all-reviews [story-key] [--force]".
- The story file MUST exist under `docs/implementation-artifacts/`. Resolve by searching both the legacy flat layout (`docs/implementation-artifacts/{story_key}-*.md`) and the canonical nested layout (`docs/implementation-artifacts/epic-*/stories/{story_key}-*.md`) per ADR-070; prefer the first lexicographic match. If zero matches across both layouts, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before running reviews".
- The `--force` flag is the ONLY supported flag. Any other flag (e.g., `--frce`) MUST be rejected with a usage error and a non-zero exit (AC-EC2).
- Reviews MUST run in this exact canonical order — never reordered, never parallel:
  1. Code Review (gaia-code-review) — gate "Code Review", short-name `code-review`
  2. QA Tests (gaia-qa-tests) — gate "QA Tests", short-name `qa-tests`
  3. Security Review (gaia-security-review) — gate "Security Review", short-name `security-review`
  4. Test Automation (gaia-test-automate) — gate "Test Automation", short-name `test-automate`
  5. Test Review (gaia-test-review) — gate "Test Review", short-name `test-review`
  6. Performance Review (gaia-review-perf) — gate "Performance Review", short-name `review-perf`
- **Action-skill exclusion (E67-S2 / AC6 / source-report SS 5.8 / SS 11).** `/gaia-test-automate` is an **action skill, not a review skill**. The "Test Automation" judgment in slot #4 above is a review (read test files, judge automation adequacy) and MUST NOT invoke `/gaia-test-automate` itself — generation is action-taking and would mutate the codebase mid-review. `/gaia-test-automate` is **triggered on demand** by:
  - explicit user invocation (`/gaia-test-automate {story_key}`),
  - `/gaia-review-qa` gap findings (uncovered ACs in `qa-test-cases-{story_key}.json`),
  - `/gaia-review-test` failure findings on missing automation coverage for a P0 AC.
  When triggered, `/gaia-test-automate` runs in its own context with the two-phase persona wiring (Phase 1 Sable, Phase 2 stack-developer per `agent-overlay.sh`).
- **Never short-circuit on failure.** If a reviewer returns FAILED, record the verdict and continue to the next reviewer. The entire purpose is to surface ALL issues in one pass.
- After each reviewer completes, update the Review Gate table via `${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update --story {story_key} --gate "{gate_name}" --verdict {PASSED|FAILED}` (per AF-2026-05-24-14 / Test02 F-16: use the absolute plugin scripts path; this skill has no `scripts/` subdirectory — the scripts live in the global `plugins/gaia/scripts/` resolved via `${CLAUDE_PLUGIN_ROOT}`).
- If a reviewer crashes (unexpected non-zero exit / malformed verdict), record FAILED for that reviewer and continue (AC-EC7).
- If `review-gate.sh` fails to update a row, log the failure and continue to the next reviewer.
- If `review-skip-check.sh` returns malformed JSON (missing `skip` or `run` keys), HALT with a parse-error message identifying the failing script — do NOT silently treat all 6 as run (AC-EC3).
- If `review-summary-gen.sh` cannot write its output (read-only filesystem / permission denied), HALT with an explicit write-failure message; story status is left untouched (AC-EC8).
- If `review-gate.sh review-gate-check` returns an exit code outside `{0, 1, 2}`, treat the result as UNVERIFIED, log a warning, and proceed (AC-EC13). Do not crash.
- This skill does NOT transition story state. State transitions are owned by the state machine, not by the runner.

## Procedure

### Step 1: Validate Input

1. Parse the story key from the first positional argument and the optional `--force` flag (Substep 2.1 prep). Reject any other flag with a usage error and exit non-zero (AC-EC2).
2. Resolve the story file by searching both layouts in order: first the legacy flat path `docs/implementation-artifacts/{story_key}-*.md`, then the canonical nested path `docs/implementation-artifacts/epic-*/stories/{story_key}-*.md` (per ADR-070). Prefer the first lexicographic match. If zero matches across both layouts, HALT with "story not found" before invoking any helper script (AC-EC12).
3. Read the story file frontmatter and verify `status: review`.
4. Read the current Review Gate table to confirm the section exists.

### Step 2: Thin-Orchestrator Procedure

Six substeps. Substeps 2.1–2.2 run once. Substeps 2.3–2.4 partition the canonical reviewer set across the LLM (judgment) and the summary block (skipped entries) according to the JSON `{skip, run}` partition emitted by `review-skip-check.sh`.

**Substep 2.1 — Validate input (already handled in Step 1).** Story key required; `--force` optional; HALT on unknown flags or missing story.

**Substep 2.2 — Skip-check.** Run:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-skip-check.sh --story {story_key} [--force]
```

(AF-2026-05-24-14 / Test02 F-16: use the absolute `${CLAUDE_PLUGIN_ROOT}/scripts/` prefix — this skill's directory contains only `SKILL.md`, no `scripts/` subdirectory. Bare `scripts/review-skip-check.sh` invocations fail with "No such file or directory".)

The script emits a single line of JSON: `{"skip":[...],"run":[...]}`. If `--force` was passed by the user, forward it verbatim to the helper — the script owns the bypass semantics (skip becomes `[]`, run becomes the full canonical list). Parse the JSON; if it lacks either the `skip` or `run` key, HALT with a parse error naming `review-skip-check.sh` (AC-EC3).

**Substep 2.3 — Run the `run` slice (Skill dispatch + report assertion + gate write).** For each canonical short-name in `run` (in canonical order), **dispatch the corresponding per-review skill via the Skill tool** (NEVER inline-judge — see AF-2026-05-20-1). After the skill returns, **assert the per-review report file exists on disk** before writing the verdict. The verdict write itself uses the proof-of-execution contract added by AF-2026-05-20-1:

```bash
bash scripts/review-gate.sh update --story {story_key} \
  --gate "{gate_name}" --verdict {PASSED|FAILED} \
  --report <absolute-path-to-per-review-report> \
  [--execution-evidence <absolute-path-to-execution-evidence.json>]
```

For test-execution gates (`QA Tests`, `Test Automation`, `Test Review`), `--execution-evidence` is REQUIRED in addition to `--report` — the gate will refuse the verdict otherwise. The dispatched skill is responsible for producing both files; the orchestrator only asserts their existence.

Skill-dispatch contract:

```
For each short_name in run:
  1. Invoke via the Skill tool:
       Skill({skill: "gaia:<short-name-mapped-to-canonical-skill>", args: "{story_key}"})
     Canonical short-name → skill mapping (AF-2026-05-24-14 / Test02 F-20: one canonical name per skill — the `(or …)` hedging was removed; the listed name is authoritative; deprecated_aliases live on the skill's own frontmatter):
       code-review     → gaia:gaia-code-review
       qa-tests        → gaia:gaia-review-qa
       security-review → gaia:gaia-review-security
       test-automate   → gaia:gaia-test-automate
       test-review     → gaia:gaia-review-test
       review-perf     → gaia:gaia-review-perf

  2. After the skill returns, derive the expected report path from the
     CANONICAL_REPORT_RELPATHS table (the same table review-summary-gen.sh
     uses). Assert `[ -f "$report_path" ]` — if the report file is absent,
     HALT with an explicit message naming the gate, the expected path, and
     directing the operator to re-dispatch the review skill. Do NOT write
     a PASSED verdict for a gate with no on-disk report.

  3. Read the verdict from the skill's emitted report (the per-review
     skill's contract emits a "Verdict: PASSED|FAILED" line in the report
     body — orchestrators MUST parse the actual report rather than
     self-judge).

  4. Write the verdict via review-gate.sh update with --report (and
     --execution-evidence for test-execution gates).

  5. If the skill dispatch itself fails (skill not installed, subagent
     errors before returning), record a FAILED verdict with
     --report-missing-reason "dispatch-failed: <reason>" so the audit
     trail captures the failure mode. The cap-and-continue rule (AC-EC7)
     still applies — proceed to the next entry in run.
```

**The "Per-reviewer LLM judgment blocks" pattern from the legacy SKILL.md is RETIRED under AF-2026-05-20-1.** Inline self-judgment by the orchestrator is forbidden; the per-review skills are the single source of verdicts. If a per-review skill is missing or broken, that is a defect to file — NOT a license for the orchestrator to substitute its own judgment.

**Substep 2.4 — Record SKIPPED entries for the `skip` slice.** For each canonical short-name in `skip`, record a "SKIPPED (already PASSED)" line for the eventual summary block. The summary script (Step 3) consumes the current gate state directly, so SKIPPED rows already at PASSED need no rewrite.

#### Per-reviewer skill-dispatch reference table

**This table is THE single source of truth for review-report paths (E105-S4 / ADR-127 §7.4 / Test02 #2).** `review-summary-gen.sh` (proof-of-execution), `review-skip-check.sh`, `review-gate.sh`, and the six per-review skills all resolve report paths from this table — there is NO divergent per-skill hardcoded path. The path column gives the read-side resolution contract.

**Per-story `reviews/` home (E105-S1 layout).** The NEW canonical home for each review report is the per-story `reviews/` subdir: `…/epic-E{N}-{slug}/E{N}-S{M}-{slug}/reviews/<type>-{key}.md` (FR-402 type-FIRST basenames, identical to the flat form). The flat `implementation-artifacts/<type>-{key}.md` path shown in the table below is the read-side fallback during the migration window — `review-summary-gen.sh`'s proof-of-execution check accepts a report at EITHER home (it greps `*/{key}-*/reviews/<basename>` when the flat path is absent), so a report written to the per-story `reviews/` dir is never flagged MISSING.

Each row names the canonical short-name, the skill to dispatch, the canonical gate name written to the Review Gate, the expected report file path, and whether `--execution-evidence` is required.

| Short-name        | Dispatch                       | Gate name             | Report path                                                        | Execution evidence? |
|-------------------|--------------------------------|-----------------------|--------------------------------------------------------------------|---------------------|
| `code-review`     | `gaia:gaia-code-review`        | `Code Review`         | `.gaia/artifacts/implementation-artifacts/code-review-{key}.md`               | No                  |
| `qa-tests`        | `gaia:gaia-qa-tests`           | `QA Tests`            | `.gaia/artifacts/implementation-artifacts/qa-tests-{key}.md`                  | **Yes**             |
| `security-review` | `gaia:gaia-review-security`    | `Security Review`     | `.gaia/artifacts/implementation-artifacts/security-review-{key}.md`           | No                  |
| `test-automate`   | `gaia:gaia-test-automate`      | `Test Automation`     | `.gaia/artifacts/implementation-artifacts/test-automate-review-{key}.md`      | **Yes**             |
| `test-review`     | `gaia:gaia-test-review`        | `Test Review`         | `.gaia/artifacts/implementation-artifacts/test-review-{key}.md`               | **Yes**             |
| `review-perf`     | `gaia:gaia-review-perf`        | `Performance Review`  | `.gaia/artifacts/implementation-artifacts/performance-review-{key}.md`        | No                  |

> **F-28 (AF-2026-05-26-6) — type-first naming reconciliation.** These paths were
> corrected to the FR-402 type-prefix-FIRST convention (`<type>-{key}.md` under
> `implementation-artifacts/`) that the six per-review skills actually write to
> (verified on disk: `code-review-E100-S1.md`, `qa-tests-E100-S1.md`,
> `test-automate-review-E100-S1.md`, `test-review-E100-S1.md`, etc.). The prior
> reversed `{key}-<type>.md` form — and the stray `test-artifacts/` directory on
> the test-aligned rows — disagreed with FR-402, made `review-summary-gen.sh`'s
> proof-of-execution check flag every report MISSING, and risked the
> `check-deps.sh` `{key}-*.md` glob collision documented in
> `feedback_review_report_filename_collision`. The per-review SKILL.md write
> paths were already FR-402-correct and are deliberately UNCHANGED.

Under the `.gaia/` consolidation (ADR-111), the prefix `docs/` may resolve to `.gaia/artifacts/` — the report paths are constructed via `${GAIA_ARTIFACTS_DIR}` per `gaia-paths.sh`. Both layouts are accepted by `review-gate.sh --report`.

### Step 3: Generate Summary (deterministic three-call sequence)

> Summary file is written by script, not LLM. The LLM produces optional one-line synopses via `--synopsis-file`; everything else is deterministic.

After Substeps 2.3–2.4 finish, run the three deterministic helper scripts in fixed order:

1. **Write the summary file** via `review-summary-gen.sh`:

   ```bash
   bash scripts/review-summary-gen.sh --story {story_key} [--synopsis-file <path>]
   ```

   The script reads the current Review Gate table and writes the V1-locked schema to `.gaia/artifacts/implementation-artifacts/{story_key}-review-summary.md`. If the script exits non-zero with a write failure (read-only filesystem / permission denied), HALT with an explicit write-failure message; story status is left untouched (AC-EC8).

2. **Compute the composite verdict** via `review-gate.sh review-gate-check` and use its **exit code** as the single source of truth (ADR-054):

   ```bash
   bash scripts/review-gate.sh review-gate-check --story {story_key}
   ```

   - exit 0 → COMPLETE (all six PASSED)
   - exit 1 → BLOCKED (any FAILED — FAILED dominates over PENDING) (AC-EC14)
   - exit 2 → PENDING (any UNVERIFIED, no FAILED)
   - any other exit code → treat as UNVERIFIED, log a warning, do not crash (AC-EC13)

   The LLM MUST NOT recompute the verdict by counting rows — the exit code is the contract.

3. **Emit the progressive nudge block** via `review-nudge.sh` and surface its stdout to the user:

   ```bash
   bash scripts/review-nudge.sh --story {story_key}
   ```

   The nudge block branches on the composite outcome (ALL PASSED → COMPLETE; N FAILED → BLOCKED with a "Blocking gates" list; N UNVERIFIED → PENDING with a "Pending gates" list).

### Step 4: Composite Verdict GATING (ADR-082 — E66-S3)

> Per ADR-082, the composite verdict is **GATING**, not informational. The deterministic shell aggregator at `scripts/review-common/composite-verdict-aggregator.sh` consumes per-gate verdicts (APPROVE | REQUEST_CHANGES | BLOCKED produced by ADR-077's verdict-resolver.sh path) and emits a composite verdict mapped to the Review Gate vocabulary (PASSED | FAILED). The aggregation path is 100% shell — no LLM (NFR-RSV2-12) — and is invariant under YOLO mode (ADR-067).

After Step 3 emits the nudge block, the orchestrator MUST run the composite aggregator with the per-gate verdicts surfaced by the verdict-resolver runs.

**E69-S4 — Conditional-skip evaluation (FR-RSV2-44, ADR-082).** Before invoking the aggregator, the orchestrator runs the deterministic conditional-trigger evaluator to decide whether the conditional gates (a11y, mobile) are included or skipped. The evaluator reads `compliance.ui_present` and `platforms[]` from the resolved project-config and emits drop-in argv fragments that the orchestrator forwards verbatim into the aggregator call:

```bash
bash scripts/review-common/conditional-trigger-eval.sh
# stdout (when ui_present=false and platforms excludes mobile):
#   a11y=skipped
#   a11y_reason=compliance.ui_present: false
#   mobile=skipped
#   mobile_reason=platforms[] excludes mobile
#   --skip-a11y "compliance.ui_present: false"
#   --skip-mobile "platforms[] excludes mobile"
```

The orchestrator then composes the aggregator invocation:

```bash
bash scripts/review-common/composite-verdict-aggregator.sh \
  --code <verdict> --qa <verdict> --test <verdict> \
  --security <verdict> --perf <verdict> \
  ( --a11y <verdict> | --skip-a11y "compliance.ui_present: false" ) \
  ( --mobile <verdict> | --skip-mobile "platforms[] empty" )
```

**Skip-rule semantics (E69-S4 / AC6 / AC7 / AC8):** Skipped conditional gates appear in the aggregator's `skipped=` enumeration with their skip reason. They contribute neutrally to the precedence chain — only included gates' verdicts count toward `BLOCKED > REQUEST_CHANGES > APPROVE`. The composite report enumerates included gates (with verdict) and skipped gates (with reason) so reviewers can see at a glance which gates fired.

**Degenerate-case safety net (E69-S4 / AC-EC3):** Should every gate end up skipped (a configuration-error scenario where all gates are conditional and no condition is met), the orchestrator passes `--allow-zero-included` along with `--skip-<gate>` flags for the always-on gates as well. The aggregator emits a `WARNING: No review gates included` line and `composite=APPROVE`. This is a configuration-error safety net — never a normal flow — and the WARNING is the explicit signal that project-config needs review.

The aggregator emits `composite=<APPROVE|REQUEST_CHANGES|BLOCKED>` and `review_gate=<PASSED|FAILED>` plus the included / skipped enumeration. The composite verdict is then evaluated against the seven-day post-flip grace window via `scripts/review-common/grace-window.sh`:

- **WARNING mode (within 7 calendar days of the flip):** the composite verdict is surfaced with a resolution recommendation; transition to `done` is still possible (NFR-RSV2-6).
- **BLOCK mode (after 7 calendar days):** if `composite ∈ {REQUEST_CHANGES, BLOCKED}`, the story cannot transition past `review`. The orchestrator HALTs the transition until either (a) the underlying gate is resolved and re-reviewed, or (b) the maintainer invokes `/gaia-correct-course` to move the story off `review` to a remediation track (E66-S3 AC8).

YOLO mode does NOT bypass composite gating (AC10) — consistent with ADR-067's CRITICAL-still-halts rule. The aggregator output is byte-identical across runs for byte-identical inputs (AC9).

#### Idempotency invariant (NFR-RAR-1, TC-RAR-17)

Re-invocation with unchanged gate state MUST produce a byte-identical summary file and nudge block. Determinism comes from the scripts. The SKILL.md just calls them in fixed order — it never inserts timestamps, randomness, or LLM-generated commentary into the summary file or the nudge block.
