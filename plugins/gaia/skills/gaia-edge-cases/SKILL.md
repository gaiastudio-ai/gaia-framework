---
name: gaia-edge-cases
description: Walk every branching path and boundary condition in the target to find unhandled edge cases. Method-driven, not attitude-driven — orthogonal to the cynical adversarial review (gaia-adversarial). Reports ONLY unhandled cases with concrete examples. Use when "find edge cases" or /gaia-edge-cases.
argument-hint: "[target — document, code, API spec, or user flow]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: light-procedural
---

## Mission

You are performing a **method-driven edge-case hunt** on the target. You exhaustively map every decision point and boundary condition, trace each one, and report only the unhandled cases with concrete triggering examples. Skip cases that are already covered — the output is a gap list, not a full coverage catalogue.

**Scope note — two hunters.** This skill (`gaia-edge-cases`) is the **method-driven hunter** — exhaustive boundary tracing. Its sibling `gaia-adversarial` is the **attitude-driven hunter** that attacks from skepticism. Run both for the widest coverage.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-edge-case-hunter.xml` task (52 lines). The legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` rather than re-prosed per skill.

## Critical Rules

- **Method-driven, not attitude-driven — orthogonal to adversarial review.** The method is exhaustive branch + boundary enumeration. Do not substitute skepticism for method.
- **Exhaustively trace every decision point and boundary.** If/else, switch/case, loops, state transitions, input validation, concurrency, error handling, timeouts, data type limits — every one.
- **Report ONLY unhandled cases — skip cases that are already covered.** The output is a gap list. Covered cases are noise.
- **Include concrete examples for each edge case found.** A finding without a trigger example is not acceptable. The reader must be able to reproduce the case.

## Inputs

- `$ARGUMENTS`: optional target (document, code path, API spec, or named user flow). If omitted, ask the user inline: "Which document, code, or flow should I walk for edge cases?"

## Steps

### Step 1 — Load Target

- If `$ARGUMENTS` is non-empty, resolve it as the target. Otherwise ask the user inline for the document, code, design, or flow to analyse (preserves the legacy Step 1 "Ask user for the document/code/design to analyze" behavior — AC-EC4).
- Read the entire target. For code paths, walk the directory and read relevant files.
- Identify the type: requirements, code, API spec, user flow, state machine, etc. This shapes the set of decision points to enumerate.

### Step 2 — Map Decision Points

Identify every branching path, comprehensively:

- **If/else conditions and their inverses** — for every `if` branch, confirm the `else` (including the implicit `else`) is handled.
- **Switch/case branches and missing default** — every switch must have a default or exhaustiveness guarantee.
- **Input validation boundaries** — min, max, zero, negative, null, empty, whitespace-only, non-ASCII, emoji, very long strings.
- **State transitions and invalid state combinations** — every state pair (s_i, s_j) where the transition is undefined or invalid.
- **Concurrent access scenarios** — two callers, race conditions, TOCTOU, lost updates, read-during-write.
- **Error handling paths and cascading failures** — partial failures, retry storms, fallback-of-a-fallback, error swallowing.
- **Timeout and retry boundaries** — exact timeout, just-below, just-above; retry count exhausted; backoff overflow.
- **Data type boundaries** — numeric overflow / underflow, floating-point precision, integer wraparound, Unicode normalization, date / timezone edges (leap seconds, DST, Feb 29).

### Step 3 — Trace Boundaries

For each boundary mapped above, test all of these:

- The **exact boundary value** (e.g., `length == max`).
- **One above and one below** (`max + 1`, `max - 1`).
- **Null / empty / missing input**.
- **Maximum possible input** (largest string, deepest nesting, longest list).
- **Special characters or malformed data** (quote injection, control chars, mismatched brackets, invalid UTF-8).

For each traced case, decide: is the target's handling correct? If yes, skip (per the critical rule — do not report covered cases). If no, record the unhandled case with a concrete example.

### Step 4 — Generate Report

Invoke the shared foundation script to emit the deterministic artifact header:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template edge-case-report --workflow gaia-edge-cases
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# Edge Case Report — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task — AC4):

```
{planning_artifacts}/edge-case-report-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`edge-case-report-{date}-2.md`, ...).

The report contains:

- **Summary** — `N edge cases found, M critical`.
- **Findings table** — columns: location (file:line or section), boundary type (if/else / switch / input / state / concurrency / error / timeout / data-type), unhandled case description, concrete example (inputs that trigger the case), severity (critical / high / medium / low).
- **Specific trigger scenarios** — for each finding, a reproducible trigger script, input payload, or step sequence.

If the target is empty or resolves to no files (AC-EC6), exit with `No review target resolved` and do NOT write an empty report file — mirrors the legacy task's behavior.

## References

- Source: `_gaia/core/tasks/review-edge-case-hunter.xml` (legacy 52-line task body).
