---
name: gaia-review-all
description: Run all 6 review workflows sequentially via subagents. Use when "run all reviews" or /gaia-review-all (formerly /gaia-run-all-reviews).
argument-hint: "[story-key] [--force]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-run-all-reviews]
deprecated_since: sprint-37
---

## Mission

You are running all 6 review workflows sequentially inline for a story. The story is resolved by `{story_key}` via the canonical glob `{story_key}-*.md` in `docs/implementation-artifacts/`. You orchestrate each review in deterministic order, update the Review Gate table after each, and report a summary of all verdicts.

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
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve. If zero matches, fail with "story file not found for key {story_key}".
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
- After each reviewer completes, update the Review Gate table via `scripts/review-gate.sh update --story {story_key} --gate "{gate_name}" --verdict {PASSED|FAILED}`.
- If a reviewer crashes (unexpected non-zero exit / malformed verdict), record FAILED for that reviewer and continue (AC-EC7).
- If `review-gate.sh` fails to update a row, log the failure and continue to the next reviewer.
- If `review-skip-check.sh` returns malformed JSON (missing `skip` or `run` keys), HALT with a parse-error message identifying the failing script — do NOT silently treat all 6 as run (AC-EC3).
- If `review-summary-gen.sh` cannot write its output (read-only filesystem / permission denied), HALT with an explicit write-failure message; story status is left untouched (AC-EC8).
- If `review-gate.sh review-gate-check` returns an exit code outside `{0, 1, 2}`, treat the result as UNVERIFIED, log a warning, and proceed (AC-EC13). Do not crash.
- This skill does NOT transition story state. State transitions are owned by the state machine, not by the runner.

## Procedure

### Step 1: Validate Input

1. Parse the story key from the first positional argument and the optional `--force` flag (Substep 2.1 prep). Reject any other flag with a usage error and exit non-zero (AC-EC2).
2. Resolve the story file via glob: `docs/implementation-artifacts/{story_key}-*.md`. If zero matches, HALT with "story not found" before invoking any helper script (AC-EC12).
3. Read the story file frontmatter and verify `status: review`.
4. Read the current Review Gate table to confirm the section exists.

### Step 2: Thin-Orchestrator Procedure

Six substeps. Substeps 2.1–2.2 run once. Substeps 2.3–2.4 partition the canonical reviewer set across the LLM (judgment) and the summary block (skipped entries) according to the JSON `{skip, run}` partition emitted by `review-skip-check.sh`.

**Substep 2.1 — Validate input (already handled in Step 1).** Story key required; `--force` optional; HALT on unknown flags or missing story.

**Substep 2.2 — Skip-check.** Run:

```bash
bash scripts/review-skip-check.sh --story {story_key} [--force]
```

The script emits a single line of JSON: `{"skip":[...],"run":[...]}`. If `--force` was passed by the user, forward it verbatim to the helper — the script owns the bypass semantics (skip becomes `[]`, run becomes the full canonical list). Parse the JSON; if it lacks either the `skip` or `run` key, HALT with a parse error naming `review-skip-check.sh` (AC-EC3).

**Substep 2.3 — Run the `run` slice (LLM judgment + gate write).** For each canonical short-name in `run` (in canonical order), perform the inline LLM review judgment for that reviewer (the per-reviewer logic blocks below) and immediately call:

```bash
bash scripts/review-gate.sh update --story {story_key} --gate "{gate_name}" --verdict {PASSED|FAILED}
```

If the LLM judgment crashes or returns a malformed verdict, write FAILED for that reviewer and proceed to the next entry in `run` — the cap-and-continue rule applies (AC-EC7).

**Substep 2.4 — Record SKIPPED entries for the `skip` slice.** For each canonical short-name in `skip`, record a "SKIPPED (already PASSED)" line for the eventual summary block. The summary script (Step 3) consumes the current gate state directly, so SKIPPED rows already at PASSED need no rewrite.

#### Per-reviewer LLM judgment blocks

For each reviewer the substep 2.3 loop visits, perform the corresponding judgment:

**Review 1 — Code Review** (gate: `Code Review`):
- Read the story file to identify all changed/created files listed in the File List section.
- For each file: read it and review for correctness, security, performance, readability, naming conventions, and test coverage.
- Produce a verdict: PASSED if no blocking issues, FAILED if blocking issues found.

**Review 2 — QA Tests** (gate: `QA Tests`):
- Read the story's acceptance criteria and test files.
- Verify test coverage against each AC. Check for missing edge cases, boundary conditions, and error scenarios.
- Produce a verdict: PASSED if coverage is adequate, FAILED if gaps found.

**Review 3 — Security Review** (gate: `Security Review`):
- Read the story file and all implementation files.
- Review for OWASP Top 10 vulnerabilities, injection risks, authentication/authorization issues, secrets exposure, and input validation.
- Produce a verdict: PASSED if no security issues, FAILED if issues found.

**Review 4 — Test Automation** (gate: `Test Automation`):
- Read the test files and verify they are automated (can run via `npm test`, `bats`, or equivalent).
- Check test structure, assertions, mocking patterns, and CI integration.
- Produce a verdict: PASSED if automation is adequate, FAILED if gaps found.

**Review 5 — Test Review** (gate: `Test Review`):
- Review test quality: check for flaky tests, proper assertions, test isolation, meaningful names, and arrange-act-assert structure.
- Produce a verdict: PASSED if test quality is adequate, FAILED if issues found.

**Review 6 — Performance Review** (gate: `Performance Review`):
- Review implementation for performance concerns: unnecessary loops, missing memoization, unbounded operations, blocking I/O, and algorithmic complexity.
- Produce a verdict: PASSED if no performance issues, FAILED if concerns found.

### Step 3: Generate Summary (deterministic three-call sequence)

> Summary file is written by script, not LLM. The LLM produces optional one-line synopses via `--synopsis-file`; everything else is deterministic.

After Substeps 2.3–2.4 finish, run the three deterministic helper scripts in fixed order:

1. **Write the summary file** via `review-summary-gen.sh`:

   ```bash
   bash scripts/review-summary-gen.sh --story {story_key} [--synopsis-file <path>]
   ```

   The script reads the current Review Gate table and writes the V1-locked schema to `docs/implementation-artifacts/{story_key}-review-summary.md`. If the script exits non-zero with a write failure (read-only filesystem / permission denied), HALT with an explicit write-failure message; story status is left untouched (AC-EC8).

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

After Step 3 emits the nudge block, the orchestrator MUST run the composite aggregator with the per-gate verdicts surfaced by the verdict-resolver runs:

```bash
bash scripts/review-common/composite-verdict-aggregator.sh \
  --code <verdict> --qa <verdict> --test <verdict> \
  --security <verdict> --perf <verdict> \
  ( --a11y <verdict> | --skip-a11y "compliance.ui_present: false" ) \
  ( --mobile <verdict> | --skip-mobile "platforms[] empty" )
```

The aggregator emits `composite=<APPROVE|REQUEST_CHANGES|BLOCKED>` and `review_gate=<PASSED|FAILED>` plus the included / skipped enumeration. The composite verdict is then evaluated against the seven-day post-flip grace window via `scripts/review-common/grace-window.sh`:

- **WARNING mode (within 7 calendar days of the flip):** the composite verdict is surfaced with a resolution recommendation; transition to `done` is still possible (NFR-RSV2-6).
- **BLOCK mode (after 7 calendar days):** if `composite ∈ {REQUEST_CHANGES, BLOCKED}`, the story cannot transition past `review`. The orchestrator HALTs the transition until either (a) the underlying gate is resolved and re-reviewed, or (b) the maintainer invokes `/gaia-correct-course` to move the story off `review` to a remediation track (E66-S3 AC8).

YOLO mode does NOT bypass composite gating (AC10) — consistent with ADR-067's CRITICAL-still-halts rule. The aggregator output is byte-identical across runs for byte-identical inputs (AC9).

#### Idempotency invariant (NFR-RAR-1, TC-RAR-17)

Re-invocation with unchanged gate state MUST produce a byte-identical summary file and nudge block. Determinism comes from the scripts. The SKILL.md just calls them in fixed order — it never inserts timestamps, randomness, or LLM-generated commentary into the summary file or the nudge block.
