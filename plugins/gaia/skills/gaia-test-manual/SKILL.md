---
name: gaia-test-manual
description: Agent-driven manual verification — exercises a target as a real user would and produces a run record with observed-vs-expected evidence. Disambiguated from /gaia-test-run (automated machine suite).
argument-hint: "<target>"
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/setup.sh

## Mission

Dispatch the manual-tester agent (Reese) to exercise a target — a skill, script, workflow step, or user-facing feature — as a human operator would. The agent runs commands, observes output, compares expected vs. actual behavior, and produces a structured run-record with per-step evidence. The parent skill persists the evidence artifacts (run-record.md and exit-code.log) and enforces the proof-of-execution gate.

## Disambiguation

This skill (`/gaia-test-manual`) and `/gaia-test-run` serve different purposes:

- **`/gaia-test-manual`** — Agent-as-user manual verification. Reese exercises the target the way a human tester would: running commands interactively, observing output, checking visual or behavioral expectations that automated suites cannot cover. Produces a run-record (steps table with observed-vs-expected) and an exit-code log. Best for exploratory testing, smoke testing, UX verification, and validating behaviors that resist automation.

- **`/gaia-test-run`** — Automated machine test suite execution. Runs the project's existing automated tests (unit, integration, e2e) via the configured test runner (jest, pytest, bats, etc.) and reports structured pass/fail results. Best for regression testing, CI gates, and coverage measurement.

Use `/gaia-test-manual` when you need a human-style walkthrough with evidence. Use `/gaia-test-run` when you need to execute the automated test suite.

## Critical Rules

- A target argument MUST be provided. If missing, fail fast with "usage: /gaia-test-manual <target>".
- The manual-tester agent runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify source files. Evidence persistence is parent-mediated.
- Proof-of-execution gate: if the agent verdict is `PASSED` but either `run-record.md` or `exit-code.log` is missing or empty, the verdict MUST be downgraded to `UNVERIFIED`. This gate is enforced by `write-evidence.sh --verify`.
- Evidence files land under the canonical evidence directory resolved by `resolve-artifact-path.sh manual_test --slug <target-slug>`.
- Sprint-status.yaml is NEVER written by this skill.

## Steps

### Step 1 — Resolve target and evidence path

Resolve the target argument to a concrete testable entity (script path, skill name, feature description). Derive a slug from the target for the evidence directory path. Use `resolve-artifact-path.sh manual_test --slug <slug>` to determine the canonical evidence location.

### Step 2 — Dispatch the manual-tester agent

Dispatch the `manual-tester` agent (Reese) via the Agent tool with `context: fork`. Pass the target description and any relevant context (acceptance criteria, usage examples, expected behaviors). The agent runs commands, observes output, and returns a structured run-record payload.

### Step 3 — Persist evidence artifacts

Receive the agent's run-record payload. Invoke `write-evidence.sh <evidence-dir> <verdict>` with the run-record content piped via stdin. The script writes `run-record.md` and `exit-code.log` to the evidence directory.

### Step 4 — Enforce proof-of-execution gate

Invoke `write-evidence.sh <evidence-dir> <verdict> --verify` to validate that both evidence files exist and are non-empty. If the verdict is `PASSED` but evidence is missing or empty, the script downgrades to `UNVERIFIED` and exits non-zero.

### Step 5 — Surface verdict and findings

Report the final verdict to the user. Surface any `WARNING` or `CRITICAL` findings from the run-record. Suppress `INFO` findings from the user-visible transcript (they remain in the evidence files).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-manual/scripts/finalize.sh
