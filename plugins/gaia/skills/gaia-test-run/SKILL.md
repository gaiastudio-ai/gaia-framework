---
name: gaia-test-run
description: Manual any-environment test runner that honours `test_execution.{tier}.placement` from project-config.yaml. Use when "run tests" or /gaia-test-run. Supports targeting by --tag, --story, or --file. Action skill — emits a structured verdict and classifies infrastructure flakes.
argument-hint: "[--tier 1|2|3] [--tag NAME] [--story KEY] [--file PATH] [--json]"
allowed-tools: [Read, Bash, Grep, Glob]
orchestration_class: light-procedural
---

## Action Skill — Trigger Model

`/gaia-test-run` is an **action skill** that executes tests against the configured environment for the requested tier. It follows the three-tier contract:

- **Phase 3A — Evidence collection (scripted):** invoke the configured test runner, capture stdout/stderr, parse counts.
- **Phase 3B — LLM judgment (scripted v1):** scan failure output for infrastructure-flake patterns (timeout, ECONNREFUSED, OOM, network-error). Future versions may delegate to an LLM judgment skill.
- **Phase 3C — Verdict resolver:** emit a structured verdict object containing `{status, tier, environment, duration_ms, test_count, pass_count, fail_count, skip_count, flake_suspected, flake_reason?}`.

`/gaia-test-run` is **excluded** from `/gaia-run-all-reviews` — it is action-taking, not evidence-collecting.

## Setup

The runner reads `test_execution.tier_{1,2,3}.placement` from `project-config.yaml` via `resolve-config.sh --field`. Placement values are drawn from the canonical set: `local | ci-pre-merge | ci-post-merge | deployment | post-deploy`.

For v1, only `local` placement actually executes; all other placements emit a dry-run command (remote execution lands in the deployment-phase skills).

## Mission

You are running the project's automated test suite against the environment configured for a specific tier — without forcing the user to remember tier-to-environment mappings or hand-construct runner invocations. The skill resolves the tier, picks the right runner, applies the targeting filter (`--tag`, `--story`, or `--file`), executes (or dry-runs), and emits a deterministic verdict.

## Critical Rules

- The `test_execution` config section MUST be present. If `resolve-config.sh --field test_execution.tier_N.placement` returns empty for the requested tier, exit non-zero with the canonical error string: `test_execution section not configured in project-config.yaml. Run /gaia-config-ci or add the section manually.`
- Default tier is `tier_1` when `--tier` is omitted (AC6).
- Only `local` placement executes locally; every other placement emits a dry-run output (AC2).
- The verdict JSON MUST contain all eight required fields: `status, tier, environment, duration_ms, test_count, pass_count, fail_count, skip_count` (AC7). The `flake_suspected` flag is added when Phase 3B detects an infrastructure-flake pattern.
- Tag conventions are per-stack (Vitest `describe.tag`, pytest `@pytest.mark`, JUnit `@Tag`, Go build tags). v1 ships a generic `--tag NAME` flag forwarded to the runner; per-stack tag-filter expansion is future work.
- Never re-implement YAML parsing — `resolve-config.sh` is the canonical config reader.

## Steps

### Step 1 — Resolve placement

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field test_execution.tier_${TIER}.placement` (default `TIER=1`).
- On empty output: emit the canonical AC9 error and exit non-zero.

### Step 2 — Resolve runner

- Run `resolve-config.sh --field tools.test_runner.provider`.
- Fall back to detection by config files: `vitest.config.*` → vitest, `pyproject.toml` with pytest → pytest, `*.bats` → bats, `go.mod` → go test.
- Error if no runner can be located.

### Step 3 — Build invocation

- For `--tag NAME`: forward the runner-specific tag flag (vitest `-t`, pytest `-m`, etc.).
- For `--story KEY`: filter to filenames matching `*${KEY}*`.
- For `--file PATH`: pass the file directly to the runner.

### Step 4 — Execute or dry-run

- If placement is `local`: invoke the runner, capture output, parse via `scripts/parse-output.sh`.
- If placement is non-local: print the would-be command with a `dry-run:` prefix and a note explaining why nothing executed.

### Step 5 — Phase 3B flake detection

- Pipe failure output to `scripts/flake-detect.sh`. The script writes `flake_suspected=true|false` plus an optional reason on stdout.

### Step 6 — Emit verdict

- Compose the verdict JSON. With `--json`, emit the JSON to stdout; without `--json`, emit a human-readable summary plus a `Verdict:` JSON block.

## Finalize

The skill terminates with the runner exit code (0 = PASSED, non-zero = FAILED) so that calling skills can chain on it.
