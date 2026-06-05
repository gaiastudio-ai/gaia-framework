---
name: gaia-test-automate
description: Expand automated test coverage for a story. Use when "automate tests" or /gaia-test-automate.
argument-hint: "[story-key] [--status|--add-scenario|--scaffold]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Sub-command Routing

`/gaia-test-automate` accepts three orthogonal sub-commands in addition to its default fill-gaps mode. Each shares the same `[story-key]` argument but diverges at the routing step BEFORE Phase 1. Sub-command dispatch is the FIRST step the skill body performs after the Setup hook.

| Sub-command       | Helper script                                         | Side effects                                                                 |
|-------------------|-------------------------------------------------------|------------------------------------------------------------------------------|
| `--status`        | `scripts/subcmd-status.sh`                            | Read-only. Emits coverage map + summary line + Custom scenarios block.       |
| `--add-scenario`  | `scripts/subcmd-add-scenario.sh`                      | Allocates next `CS-NNN`; writes story TC list + `custom/test-scenarios/index.yaml`. |
| `--scaffold`      | `scripts/subcmd-scaffold.sh`                          | Generates placeholder skeletons. Review Gate is **NEVER** flipped to PASSED. |
| _default (no flag)_ | Phase 1..7 (existing flow below)                    | Plan-then-execute test generation.                                           |

### `--status` sub-command

```
usage: /gaia-test-automate {story_key} --status
```

**Arguments**
- `{story_key}` — required, e.g. `E28-S66`. Resolves the story file via the canonical `.gaia/artifacts/implementation-artifacts/{story_key}-*.md` glob (with legacy `docs/implementation-artifacts/` fallback for older projects).

**Output format (stdout)**
```
Coverage map for {story_key}
AC1   TC-001   unit          tests/unit/foo.test.ts
AC2   TC-002   integration   tests/int/bar.spec.ts
AC3   —        —             (not yet automated)

Summary: 2/3 generated (67%) | 1 pending automation

Custom scenarios:
CS-001  unit  edge case for retry  tests/unit/cs-001.test.ts
```
The "Custom scenarios" block is rendered only when the story's `## Custom Scenarios` markdown table contains `CS-NNN` rows.

### `--add-scenario` sub-command

```
usage: /gaia-test-automate {story_key} --add-scenario
```

**Arguments**
- `{story_key}` — required.
- Interactive (or flag-driven for non-interactive callers): description, tier (`unit`|`integration`|`e2e`), priority (`P0`..`P3`), expected behavior.

**Output format**
- Stdout: the allocated `CS-NNN` ID, e.g. `CS-003`.
- Side effects: row appended to the story's `## Custom Scenarios` table; entry appended to `custom/test-scenarios/index.yaml` under the `scenarios:` key.

The `CS-NNN` namespace is deliberately separate from Vera's `TC-NNN` so `/gaia-review-qa` re-runs do not collide.

**`custom/test-scenarios/index.yaml` schema.** Each entry under `scenarios:` carries the following canonical fields:

| Field          | Type    | Notes                                                                 |
|----------------|---------|-----------------------------------------------------------------------|
| `id`           | string  | `CS-NNN`, zero-padded to three digits. Allocated atomically.          |
| `story_key`    | string  | Owning story (e.g. `E72-S3`).                                          |
| `description`  | string  | Short human-readable scenario description.                             |
| `tier`         | enum    | `unit` \| `integration` \| `e2e`.                                      |
| `priority`     | enum    | `P0` \| `P1` \| `P2` \| `P3`.                                          |
| `file_path`    | string  | Path to automated test; empty until automated.                         |
| `created_date` | string  | ISO-8601 calendar date (`YYYY-MM-DD`) at append time.                  |

`/gaia-review-qa` (and the `gaia-qa-tests` skill more broadly) **MUST NOT mutate `custom/test-scenarios/index.yaml`** — the index is read-only outside the `--add-scenario` writer path. This non-mutation invariant guarantees that re-running the QA review after a developer authored custom scenarios never deletes, renumbers, or overwrites their entries. The qa-tests SKILL.md does not reference the index path; treat any future mutation as a regression.

Atomic-write guarantee: writes go through `mktemp` + `mv` so a crash mid-append never leaves the file in a partially written state. Concurrent `--add-scenario` invocations on the same index follow last-writer-wins semantics; both writes succeed atomically.

The `--status` sub-command sources the Custom scenarios block from `custom/test-scenarios/index.yaml` (filtered by `story_key`) and verifies each non-empty `file_path` against the on-disk tree — missing files render with a `(file not found)` suffix. Entries are not pruned automatically; the developer either updates `file_path` or removes the stale entry.

### `--scaffold` sub-command

```
usage: /gaia-test-automate {story_key} --scaffold
```

**Arguments**
- `{story_key}` — required.
- `--stack` — optional; canonical stack key (`ts-dev`, `python-dev`, `java-dev`, `go-dev`, `flutter-dev`, `angular-dev`). Defaults to `ts-dev`.

**Output format**
- Stdout: a `scaffold: N skeleton(s) generated for {story_key} under {dir}` line followed by the hard-invariant marker `scaffold: review gate not updated (skeleton-only output is not coverage)`.
- Side effects: one skeleton file per unmapped AC under the resolved out-dir. Each skeleton contains a stack-appropriate placeholder pattern (`test.skip`, `assert True`, `t.Skip(...)`, etc.) so the deterministic `placeholder-test-detector.sh` flags it as `low_quality_test_generated`.

**Hard invariant.** `--scaffold` MUST NEVER write `PASSED` to the Test Automation Review Gate row. Skeleton-only output is not coverage. The skill body verifies this contract by checking for the explicit `review gate not updated` marker on stdout before returning.

## Action Skill — Trigger Model

`/gaia-test-automate` is an **action skill**, not a review skill. It is **excluded from the default `/gaia-run-all-reviews` sequence** and is only triggered by:

1. **Explicit user invocation** — `/gaia-test-automate {story_key}` from the developer.
2. **`/gaia-review-qa` gap findings** — when the QA review surfaces uncovered ACs in `qa-test-cases-{story_key}.json`, the orchestrator MAY invoke `/gaia-test-automate` to fill the gap.
3. **`/gaia-review-test` failure findings** — when the Test Review fails on missing automation coverage for a P0 AC, the orchestrator MAY invoke `/gaia-test-automate` to land the missing automation.

`/gaia-run-all-reviews` MUST NOT include `/gaia-test-automate` in its default canonical sequence (Code Review, QA Tests, Security Review, Test Review, Performance Review). The five review skills are evidence-collecting; `/gaia-test-automate` is action-taking and would otherwise mutate the codebase mid-review.

### Two-phase action-skill nature

The skill executes in two phases under distinct personas resolved via `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh`:

| Phase | Persona resolution | Persona | Role |
|-------|---------------------|---------|------|
| Phase 1 — Planning | `agent-overlay.sh --skill gaia-test-automate` | Sable (test-architect) | Reads `qa-test-cases-{story_key}.json`, picks tests to write, emits the plan file with `analyzed_sources[]` + `proposed_tests[]`. |
| Phase 2 — Implementation | `agent-overlay.sh --skill gaia-review-code --stack {stack}` | Stack-developer (Cleo / Hugo / Ravi / Lena / Freya / Talia / Christy per `load-stack-persona.sh`) | Executes the approved plan via `phase2-execute.sh`: writes test files, runs the Test Execution Bridge, records evidence. |

Planning lives inside the seven Review Phases (fork-isolated analysis, read-only). Implementation runs in main context with full Write / Edit / Bash via `phase2-execute.sh`.

### `--scaffold` flag

When invoked with `--scaffold`, Phase 2 produces SCAFFOLD-ONLY output (intentional placeholder skeletons for downstream developers to flesh out). Behavior differences vs. default mode:

- Generated tests use `test.skip` / `skip "..."` placeholders.
- The mandatory `placeholder-test-detector.sh` Phase 2 gate (Step 3b) is **skipped** — scaffolds are expected to contain placeholders.
- The Review Gate Test Automation row stays **UNVERIFIED** — scaffolds NEVER flip the gate to PASSED.

Default mode (no `--scaffold`) generates implementation-aware tests (real imports + real assertions referencing the story's File List), runs the placeholder detector as a mandatory post-generation gate, and flips the Review Gate to PASSED only when all generated tests are clean and execute green.

### Placeholder gate

Phase 2 invokes `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/placeholder-test-detector.sh` after test generation in default mode. The detector flags:

- `expect(true)` / `expect(false)` — vacuous boolean assertions.
- `assert True` / `assert False` (Python).
- `assert_true(...)` / `assert_false(...)`.
- `test.todo(...)` / `test.skip(...)` / `it.skip(...)` / `xit(...)` / `xdescribe(...)` / `xcontext(...)` / `describe.skip(...)`.
- Empty `it(...)` / `test(...)` blocks (single-line `() => {}` callback) and empty `@test "..." {}` bats blocks.

Any hit fails Phase 2 with verdict `REQUEST_CHANGES` via `verdict-resolver.sh --action-mode` (the action-skill verdict path). The Review Gate Test Automation row MUST NOT update to PASSED in that case.

The same `review-common/placeholder-test-detector.sh` instance is referenced by `/gaia-review-test` Phase 3A — there is no duplicate copy under either skill's `scripts/` directory.

### Verdict resolver action-skill semantics

Phase 2 calls `verdict-resolver.sh --action-mode --analysis-results <path>` with a flat JSON document containing the action-skill outcome flags. Mapping:

- **APPROVE** ⇐ plan present + execution success + no placeholders + no SUT-mocking + does not break existing suite.
- **REQUEST_CHANGES** ⇐ placeholders detected OR tests mock the system under test OR generated tests break the existing suite.
- **BLOCKED** ⇐ `blocking_failure` ∈ `{plan_tamper, target_outside_allowlist, runner_unavailable, plan_drift, malformed_output}` OR plan missing OR execution did not succeed.

### Coverage-delta gate

In addition to the placeholder gate above, Phase 2 captures a coverage-delta as a verdict input. The flow is deterministic shell — no LLM judgment involved:

1. **Capture baseline coverage** — BEFORE writing generated test files, run the project's coverage command (resolved from `project-config.yaml` under `test_execution.coverage_command`) and persist its report to `${TEST_AUTOMATE_DIR}/coverage-baseline.{lcov|json}`.
2. **Capture current coverage** — AFTER writing generated tests AND after the Test Execution Bridge run completes green, re-run the same coverage command and persist its report to `${TEST_AUTOMATE_DIR}/coverage-current.{lcov|json}`.
3. **Compute delta** — invoke `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/action/coverage-delta.sh --baseline <pre> --current <post>` and persist its JSON output to `${TEST_AUTOMATE_DIR}/coverage-delta.json`.
4. **Pipe into the verdict resolver** — invoke `verdict-resolver.sh ... --coverage-delta ${TEST_AUTOMATE_DIR}/coverage-delta.json` (alongside `--action-mode` or the analysis/llm-findings pair, depending on the call site). The resolver inserts the coverage-delta rule between the LLM-Critical rule and the default APPROVE branch — `coverage_delta <= 0` yields `REQUEST_CHANGES` with a stderr diagnostic citing the regression amount or "zero coverage delta".

Verdict precedence is unchanged for the four prior rules: `errored -> BLOCKED > tool-failed-blocking -> REQUEST_CHANGES > LLM-Critical -> REQUEST_CHANGES`. Coverage-delta fires ONLY when none of the higher-priority rules has fired.

Skipped under `--scaffold` mode (scaffolds intentionally generate no real coverage). Skipped when `test_execution.coverage_command` is unset in `project-config.yaml` (graceful degrade — log to stderr and proceed without the coverage-delta input, preserving prior behavior).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-automate/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill. For `gaia-test-automate` it means: deterministic tools (test-execution toolkit — per-stack test-runner availability probe, "tests-that-would-run" inventory listing, missing-fixture / missing-mock / untestable-assertion analysis) run first and emit a structured `analysis-results.json` artifact. The LLM then performs an automation semantic review **on top of** that artifact — it cannot disregard a missing-fixture finding on a P0 AC, it cannot relabel a tool-failure as APPROVE, and it cannot promote a Suggestion-tier finding into a verdict-blocker. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill is the **plan-then-execute hybrid** of the six review skills. The seven canonical phases established by `gaia-code-review` execute INSIDE the planning phase (fork-isolated analysis). The plan-then-execute split-phase architecture is preserved verbatim — the user-approval gate, plan-tamper detection, and plan-id-keyed `review-gate.sh` invocation live AFTER the seven-phase block in a separate "Approval Gate" section. Phase 6 of this skill emits `analysis-results.json`, the review report, AND the plan file; it does NOT invoke `review-gate.sh`. `review-gate.sh` invocation is deferred to the Approval Gate section, keyed on `plan_id`, and runs only after user approval/rejection.

**Phase vocabulary disambiguation.** This SKILL.md uses unambiguous labels: "Review Phase 1" through "Review Phase 7" (the seven-phase review template) ALL execute within the planning phase (fork-isolated analysis). The execution phase is a separate downstream skill (main-context plan execution) and is OUT OF SCOPE for this skill. The seven Review Phases are bounded by the read-only fork allowlist `[Read, Grep, Glob, Bash]`; the execution phase expands to `[Read, Write, Edit, Bash, Grep, Glob]` in main context.

**Fork context semantics:** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report AND the plan file is parent-mediated (Option A): the fork returns the rendered report payload + structured plan-content payload to the parent context, and the parent writes both files. `Write` and `Edit` are NEVER added to the fork allowlist.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory (fixture-architecture, deterministic-testing, api-testing-patterns, data-factories, selector-resilience, visual-testing, pytest-patterns, jest-vitest-patterns, junit5-patterns) — load them JIT when referenced by a phase, never pre-load.
- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-test-automate [story-key]".
- The story file MUST be resolvable via the shared `scripts/resolve-story-file.sh` helper which honors the canonical-first contract: `.gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md` first, then legacy `docs/implementation-artifacts/{story_key}-*.md` as fallback. If the helper exits 1 (zero matches), fail with "story file not found for key {story_key}". Do NOT inline-hardcode the `docs/` glob — that breaks on `.gaia/`-canonical projects.
- The story MUST be in `review` status. If not, fail with "story must be in review status before test automation".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence (review report + plan file) is routed through the parent context.
- Test-execution toolkit (Review Phase 3A) is **GAP-FOCUSED ANALYSIS, NOT execution** — it identifies what tests are missing, what fixtures are needed, what mocks are required. Actual test execution belongs to the execution phase. Per-stack listing commands ONLY: `jest --listTests`, `vitest list`, `pytest --collect-only`, `go test -list`, `dart test --reporter=json`, etc.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- **Three-way verdict mapping:** APPROVE → full plan written + auto-presents at Approval Gate with verdict line; REQUEST_CHANGES → full plan written + presents with "plan changes recommended" marker; BLOCKED → SHORT-CIRCUIT before Review Phase 6 full plan-write — emit a stub/short-form plan file with `verdict: BLOCKED` in frontmatter (NO full plan body) so the user has a record of the failed run, NO `review-gate.sh` invocation, user re-runs after fixing the underlying issue.
- **Review Phase 6 does NOT invoke `review-gate.sh`.** Phase 6 emits `analysis-results.json`, the review report, AND the plan file. `review-gate.sh` invocation is deferred to the Approval Gate section, keyed on `plan_id`, and runs only after user approval or rejection. This is the single most important architectural difference this skill introduces.
- **Strict schema separation:** `analysis-results.json` (under `.gaia/state/review/test-automate/{story_key}/`) records DETERMINISTIC ANALYSIS output (test-execution-toolkit findings) ONLY. The plan file records the GENERATIVE PLAN (what tests to write, source-file SHA-256 entries) ONLY. Zero content overlap. The plan-file path is resolved via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh test-automate-plan {story_key} --write` (mirror layout): NEW canonical home `.gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{story_key}-{story_slug}/test-automate-plan.md`; legacy flat `.gaia/artifacts/test-artifacts/test-automate-plan-{story_key}.md` remains a read-only fallback during the migration window.
- **plan_id determinism canonicalization:** `plan_id` is sha256 of NORMALIZED plan contents — findings sorted by `{category, severity}`, finding message text EXCLUDED from the hash. Textual variation does NOT change `plan_id`.
- **Single source of truth for `file_hashes`:** Review Phase 3A computes `file_hashes` once; both `analysis-results.json` (cache invalidation) AND the plan file (source-file SHA-256 entries) reference the same field. Avoids divergence between two independent hash mechanisms.
- Mapping to Review Gate canonical vocabulary (inline, no separate script): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Determinism settings: `temperature: 0`, `model: claude-opus-4-7`, `prompt_hash` recorded in the report header. Re-running with identical `analysis-results.json` MUST yield findings that match by category and severity; textual variation is allowed.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in report header at Review Phase 6
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce findings that match by `{category, severity}`. Textual message variation is allowed; category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch.

`plan_id` (separate from `prompt_hash`) is sha256 of the **normalized canonical-form** of plan contents — findings sorted by `{category, severity}`, message text excluded from the hash. Two LLM runs with identical `analysis-results.json` and textually-different finding messages MUST produce identical `plan_id`.

## Stack Toolkit Table

The toolkit invoked by Review Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match. Phase 3A is **GAP-FOCUSED ANALYSIS, NOT execution**: each command is a test-discovery / listing command that produces an inventory of "tests that would run" if executed — NOT actual test runs.

| Stack key (canonical) | Test-runner availability probe                                          | "tests-that-would-run" listing command                       |
|-----------------------|--------------------------------------------------------------------------|--------------------------------------------------------------|
| `ts-dev`              | `command -v jest \|\| command -v vitest`                                 | `jest --listTests` (Jest) or `vitest list --json` (Vitest)   |
| `java-dev`            | `command -v mvn \|\| command -v gradle`                                  | JUnit dry-run (`mvn -DskipTests=true test-compile` + class scan) |
| `python-dev`          | `command -v pytest`                                                      | `pytest --collect-only -q`                                   |
| `go-dev`              | `command -v go`                                                          | `go test -list '.*' ./...`                                   |
| `flutter-dev`         | `command -v dart` AND `command -v flutter`                               | `dart test --reporter=json` (collection mode, NOT execution) |
| `mobile-dev`          | iOS `command -v xcodebuild`; Android `command -v gradle`                 | iOS `xcodebuild -showtests`; Android `gradle test --dry-run` |
| `angular-dev`         | `command -v jest`                                                        | `jest --listTests` (Angular jest convention)                 |

Phase 3A scope is **strict**: per-stack test-runner availability probe + "tests-that-would-run" inventory + missing-fixture / missing-mock / untestable-assertion analysis. Phase 3A does NOT invoke linters, formatters, type checkers, or build verification — those belong to `gaia-code-review`. Phase 3A does NOT invoke Semgrep, secret scanners, or dep audits — those belong to `gaia-security-review`. Phase 3A does NOT execute tests — actual execution is the execution phase's territory.

Mismatched stack name (vocabulary drift between `load-stack-persona.sh` output and the table key) → silent skip on toolkit invocation with `skip_reason` populated.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Review Phase 3B applies the rubric below. Findings are organized by automation category. Coverage targets the four highest-frequency categories: **missing fixture**, **untestable assertion**, **flaky-prone pattern**, **unmocked external dep**. Other categories (missing teardown, missing test-data factory, snapshot test without descriptive name, missing parameterized tests) seed Warning/Suggestion-tier examples below.

The category+severity sets MUST match across two runs of identical inputs (determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical promotion is restricted to (a) missing fixtures on P0/high-priority ACs and (b) untestable assertions referencing non-existent functions.

Examples:

- **Missing fixture for P0 AC** — Story AC1 ("Given a logged-in admin, when DELETE /users/:id, then 204 + audit-row written") is P0 in story frontmatter; the test-execution toolkit "tests-that-would-run" inventory shows a test named `it('AC1: admin deletes user', ...)` but `tests/fixtures/admin-session.json` (referenced via `loadFixture('admin-session')`) does not exist on disk. Fixture absence on a P0 AC is verdict-blocking — the test cannot run.
- **Untestable assertion (test references nonexistent function)** — Test body contains `expect(buildUserAuditRow(actor, target)).toEqual(...)` but `buildUserAuditRow` does not exist in any source file under the story's File List (and is not exported from any module the test imports). The test, if run, would crash on import — coverage is structurally broken.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples:

- **Flaky-prone pattern (timer-based wait without retry)** — Test contains `await sleep(2000); expect(eventReceived).toBe(true);` rather than `await waitFor(() => expect(eventReceived).toBe(true), { timeout: 5000, interval: 100 });`. Hard sleeps without retry are the #1 source of CI flakiness. Warning regardless of whether the test currently passes.
- **Unmocked external dep that would hit network in CI** — Test body imports `axios` directly and issues `await axios.get('https://api.example.com/...')` with no `nock`, `msw`, or jest auto-mock setup. CI without network access (or with rate-limiting) will produce non-deterministic failures. Warning when no mock is detected anywhere in the test setup.
- **Missing teardown leaving state** — Test creates a temp directory or seeds a database row in `beforeEach` but has no matching `afterEach` cleanup. Subsequent tests can fail spuriously due to leaked state. Warning regardless of pass-state.
- **Missing edge-case AC coverage for a non-P0 AC** — Edge-case AC has no test in the inventory. Per primary-vs-edge-case differential weighting, an uncovered edge-case AC is ALWAYS Warning (NEVER Critical) — edge cases are awareness markers not always testability targets.

### Suggestion

> Non-blocking. Style/convention polish; no behavior implications.

Examples:

- **Missing test-data factory** — Test body inlines a 30-line user object literal instead of using a `userFactory.build({...overrides})` pattern. Refactor opportunity reducing duplication across tests.
- **Snapshot test without descriptive name** — Test name `it('snapshot', () => { expect(component).toMatchSnapshot(); })` is unhelpful when the snapshot diff fails. Prefer `it('renders the empty-state message when items[] is []', ...)` so the failure mode is recoverable from the test name alone.
- **Missing parameterized test for table-driven scenarios** — Three near-identical tests differ only by input/expected pair. Suggest `it.each([[a,b],[c,d],[e,f]])('handles %s -> %s', (input, expected) => { ... })`. DRY opportunity, no behavior change.

**Context-aware classification rules (rubric-driven):**
- Missing fixture for P0 AC → Critical; missing fixture for non-P0 AC → Warning.
- Untestable assertion (nonexistent function reference) → Critical regardless of AC priority — the test is structurally broken.
- Flaky-prone pattern (hard sleep, racey wait) → Warning — code runs but is unreliable.
- Unmocked external network dep → Warning — runs but non-deterministic.
- Missing edge-case AC coverage → ALWAYS Warning (never Critical).
- Convention/refactor opportunities (missing factory, opaque snapshot name, parameterizable repetition) → Suggestion.

LLM-cannot-override invariant: a deterministic Phase 3A finding (e.g., test-runner BLOCKED → toolkit could not run; or `status: failed` with a P0 AC missing-fixture finding) wins over any LLM APPROVE judgment. The rubric tiers above apply to LLM tier classification — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` or `status: errored`.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable. ALL seven Review Phases execute INSIDE the planning phase (fork-isolated analysis). The Approval Gate section AFTER Review Phase 7 handles the user-approval interaction and the deferred `review-gate.sh` invocation.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-test-automate [story-key]"
- Resolve the story file path via the shared `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh {story_key}` helper. It honors the canonical-first contract: searches `.gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md` first, then falls back to legacy `docs/implementation-artifacts/{story_key}-*.md`. Exit codes: 0 = single match (stdout = path); 1 = zero matches (fail with "story file not found for key {story_key}"); 2 = multiple matches (fail with "multiple story files matched key {story_key}"). Do NOT inline-hardcode the legacy `docs/` glob.
- Read the resolved story file; parse YAML frontmatter to extract `status`, `traces_to`, and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`) and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch. Forward the persona payload + canonical stack name into the fork.
- **Tool prereq probe.** For each tool listed in the stack-toolkit table row matched by the canonical stack name: probe via `command -v <tool>` first; fall back to `node_modules/.bin/<tool> --version` (TS/Angular). NEVER use `npx <tool> --version` (triggers npm install and breaks the 60s P95 budget). Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key.
- **Test-runner availability probe.** Verify the per-stack test runner is present (e.g., `jest`, `pytest`, `go`, `dart test`). If the test runner is absent for a stack that requires it, emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. **BLOCKED short-circuits BEFORE the FULL Review Phase 6 plan write** — a stub plan file with `verdict: BLOCKED` in frontmatter IS still emitted by Phase 6 so the user has a record of the failed run; NO `review-gate.sh` invocation occurs.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for test automation".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.gaia/state/review/test-automate/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`). **Strict scope:** `analysis-results.json` records DETERMINISTIC ANALYSIS output ONLY (test-execution-toolkit findings). The plan file (written in Review Phase 6) records the GENERATIVE PLAN ONLY (what tests to write). Zero content overlap.

**Toolkit invocation.** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1.

1. **"Tests-that-would-run" inventory (per-stack listing, NOT execution).** Run the listing command for the resolved stack (e.g., `jest --listTests`, `pytest --collect-only -q`, `go test -list '.*' ./...`, `dart test --reporter=json`). Record the inventory under `analysis-results.json:tests_discovered` keyed by stack. Wall-clock cap: 30s.

2. **Missing-fixture analysis.** For each test in the inventory, parse references to fixture files (e.g., `loadFixture('foo')`, `fixtures/foo.json`, `@fixtures/foo`). Verify each referenced path exists on disk. Missing fixture on a test mapped to a P0 AC → `category: fixture, severity: critical`; missing fixture on a non-P0-mapped test → `category: fixture, severity: warning`.

3. **Untestable-assertion analysis.** For each test in the inventory, extract symbol references in `expect(...)` / `assert(...)` calls. Cross-reference each symbol against (a) the story's File List source files and (b) the test's import statements. Symbols not found in either path → `category: untestable, severity: critical`. The test would crash on import — coverage is structurally broken.

4. **Missing-mock analysis.** For each test, scan import statements for known network-/IO-bound libraries (`axios`, `requests`, `http.Client`, etc.). Cross-reference with mock-setup blocks (`jest.mock`, `nock`, `mocker.patch`, `httptest.Server`). External-dep imported with no matching mock setup → `category: mocking, severity: warning`.

5. **`file_hashes` SINGLE SOURCE OF TRUTH.** Compute `sha256` for every File List entry once. Store under `analysis-results.json:file_hashes` (sorted by path). The Review Phase 6 plan file's `analyzed_sources[]` array references the SAME `file_hashes` field — both consumers read from this single source. Cache invalidation (Phase 3A) and source-drift detection (the execution phase) operate on the same hash set.

**Status taxonomy.** Each tool invocation produces exactly one of:
- `status: passed` — toolkit ran to completion, no findings, exit code zero.
- `status: failed` — toolkit ran to completion AND emitted blocking findings (e.g., missing fixture on a P0 AC; untestable assertion). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — test runner crashed mid-probe, returned an unclassified non-zero exit code, OR exceeded its wall-clock cap. Maps to BLOCKED via precedence rule 1.
- `status: skipped` — toolkit not applicable (e.g., no test files found via standard discovery globs); `skip_reason` populated verbatim.

**Path normalization.** Toolkit outputs vary in path convention. Phase 3A normalizes all `findings[].file` to repo-relative before writing `analysis-results.json`.

**Cache plumbing.** Cache lives at `.gaia/state/review/test-automate/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted) — SINGLE SOURCE OF TRUTH (AC-EC6)
  || tests-discovered inventory hash (sha256 of sorted test paths)
  || tool_versions (sorted "tool:version" lines)
  || test-runner config blob (jest.config.*, pytest.ini, go.mod, etc.)
)
```

Cache lookup:
1. Compute the candidate cache key from current File List + file_hashes + tests-discovered hash + tool versions + runner config.
2. Look up `.gaia/state/review/test-automate/{story_key}/.cache/{cache_key}.json`. On miss: run toolkit.
3. On candidate hit, **revalidate file_hashes** against current on-disk hashes. A File List entry edited externally without changing other cache-key fields → treat as miss.

Cache write (same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.gaia/state/review/test-automate/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic-rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow test-automate --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow test-automate` can detect drift later.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of toolkit findings (per-test fixture/mock/assertion status) for log inspection.

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the automation severity rubric to produce category-organized Critical / Warning / Suggestion findings restricted to automation scope (missing fixture, untestable assertion, flaky-prone pattern, unmocked external dep, missing teardown, missing factory, opaque snapshot name, missing parameterized test).

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section), AC text (primary + edge-case).

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message", "ac_ref?", "fr_ref?"}, ...] }` PLUS a structured plan-content payload (used by Review Phase 6 to write the plan file). The fork ALSO returns the rendered review-report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**Determinism contract.** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**plan_id determinism canonicalization.** The `plan_id` recorded in the plan-content payload is sha256 of NORMALIZED plan contents — findings sorted by `{category, severity}`, message text EXCLUDED from the hash. Two LLM runs with identical `analysis-results.json` and textually-different finding messages MUST produce identical `plan_id`. The bats fixture `plan-id-determinism/` covers this case.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

**LLM-cannot-override (rule 2 of verdict-resolver).** A deterministic finding from Phase 3A — e.g., missing fixture on P0 AC → `status: failed` → REQUEST_CHANGES — wins over any LLM APPROVE judgment.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **Test architecture conformance.** Fork reads `.gaia/artifacts/planning-artifacts/architecture.md` and (when present) `.gaia/artifacts/planning-artifacts/test-plan.md`. For each test in the inventory, verify it follows the documented test pyramid (unit / integration / e2e ratios) and lives under the architecture-mandated test directory. Findings under `category: architecture`.
- **FR-traceability check.** When story frontmatter `traces_to: [FR-...]` is set, fork searches discovered test bodies for FR ID references (comments or test descriptions). Missing FR-traceability surfaces as a Suggestion-tier finding.
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares E2E selectors in the discovered tests against `.gaia/artifacts/planning-artifacts/design-system/design-tokens.json` and the Figma component manifest. Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by `verdict-resolver.sh`. The LLM never computes or overrides it.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh \
  --analysis-results .gaia/state/review/test-automate/{story_key}/analysis-results.json \
  --llm-findings .gaia/state/review/test-automate/{story_key}/llm-findings.json
```

The resolver applies strict first-match-wins precedence:
1. Any check `status: errored` → **BLOCKED**.
2. Any check `status: failed` with blocking finding → **REQUEST_CHANGES**. *The LLM cannot override this — rule 2 wins over rule 4 (LLM APPROVE) every time.*
3. Any LLM finding `severity: Critical` → **REQUEST_CHANGES**.
4. Otherwise → **APPROVE**.

Stdout is exactly one of `APPROVE | REQUEST_CHANGES | BLOCKED`. **Three-way mapping:**

| Resolver output  | Review Gate verdict | Plan-file behavior                                                  |
|------------------|---------------------|------------------------------------------------------------------------------|
| APPROVE          | PASSED              | Full plan written; auto-presents at Approval Gate with verdict line          |
| REQUEST_CHANGES  | FAILED              | Full plan written; presents at Approval Gate with "plan changes recommended" marker |
| BLOCKED          | FAILED              | **SHORT-CIRCUIT** — stub plan with `verdict: BLOCKED` in frontmatter; NO full plan body; NO `review-gate.sh` invocation; user re-runs after fixing the underlying issue |

The Review-Gate-vocabulary mapping (APPROVE→PASSED, REQUEST_CHANGES→FAILED, BLOCKED→FAILED) is local to this section. If a future review skill diverges, extract to a shared script then (YAGNI).

### Phase 6 — Output

Phase 6 is the **persistence layer**. The fork CANNOT write — persistence is parent-mediated (Option A). Phase 6 emits THREE artifacts: `analysis-results.json` (already written in Phase 3A), the review report, AND the plan file. **Phase 6 does NOT invoke `review-gate.sh` — that invocation is deferred to the Approval Gate section, keyed on `plan_id`, and only runs after user approval/rejection.**

**Fork output.** The fork returns:
- A rendered review-report payload as its conversational output.
- A structured plan-content payload (plan schema) for the parent to write atomically to the plan file.

**Rendered review report MUST contain:**
- Header: story key, title, prompt_hash, model, temperature.
- `## Deterministic Analysis` — per-tool status table + tests-discovered inventory + per-tool findings list (from `analysis-results.json`).
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by automation category (`fixture`, `untestable`, `mocking`, `flakiness`, `teardown`, `factory`, `snapshot`, `parameterization`, `architecture`, `fidelity`, `integrity`).
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation.** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.
- Plan-content payload contains a parseable `plan_id` and `analyzed_sources[]` referencing the shared `file_hashes`.

**Malformed-payload handling.** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, sets the plan file's frontmatter `verdict: BLOCKED`, and short-circuits — the Approval Gate is NOT entered. Fork output untrustworthy → BLOCKED.

**Parent write — review report, single-source path resolver.** The basename is the locked form `test-automate-review-{story_key}.md` (no slug, no date suffix). Resolve the directory via the shared helper:

```bash
REPORT_PATH="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-review-report-path.sh --key {story_key} --type test-automate-review)"
```

Returns the per-story `…/epic-{slug}/{story_key}-{slug}/reviews/test-automate-review-{story_key}.md` (`reviews/` created) when the story is in the new layout, else the legacy flat `.gaia/artifacts/implementation-artifacts/test-automate-review-{story_key}.md`. Written REGARDLESS of approval outcome.

**Parent write — plan file.** Resolve the write path via `PLAN_PATH=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh test-automate-plan {story_key} --write)` — this returns the new canonical per-story home `.gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{story_key}-{story_slug}/test-automate-plan.md` and `mkdir -p`s the parent directory. The parent writes the structured plan-content payload atomically (per-PID temp file + `mv` rename) to `$PLAN_PATH`. Written REGARDLESS of approval outcome. The plan file frontmatter contains `plan_id`, `analyzed_sources[]` (referencing the SAME `file_hashes` from `analysis-results.json`), and an empty `approval` block awaiting the Approval Gate. Legacy flat `.gaia/artifacts/test-artifacts/test-automate-plan-{story_key}.md` remains a read-only fallback during the migration window.

**File-naming coexistence.** Two distinct artifacts share the `test-automate-` prefix. They live in different directories with non-overlapping schemas:

| File path                                                       | Schema      | Domain                                  | When written       |
|------------------------------------------------------------------|-------------|------------------------------------------|--------------------|
| `.gaia/artifacts/implementation-artifacts/test-automate-review-{story_key}.md` | review-report      | Review report (verdict + LLM findings)  | Phase 6 (parent)   |
| `.gaia/artifacts/test-artifacts/epic-{epic_slug}/stories/{story_key}-{story_slug}/test-automate-plan.md` (legacy flat `.gaia/artifacts/test-artifacts/test-automate-plan-{story_key}.md` accepted on read) | plan-schema | Generative plan (source SHA-256 + plan body) | Phase 6 (parent)   |
| `.gaia/state/review/test-automate/{story_key}/analysis-results.json`   | analysis-results    | Deterministic toolkit findings only     | Phase 3A (parent)  |

**BLOCKED short-circuit.** If verdict is BLOCKED (resolver rule 1 fired), Phase 6 emits a **stub/short-form plan file** with `verdict: BLOCKED` in frontmatter, an empty plan body, and `analyzed_sources: []`. NO full plan body is written. The review report IS still written so the user has a record of the failed run. NO `review-gate.sh` invocation. The Approval Gate section is NOT entered — Phase 7 finalizes and the skill exits.

**Re-run handling.** Parent **overwrites** the existing review file and plan file on re-run (latest verdict / plan_id wins). No append, no version-suffix.

**Re-confirm fork allowlist.** The frontmatter `allowed-tools` MUST remain exactly `[Read, Grep, Glob, Bash]`. The `evidence-judgment-parity.bats` assertion catches any post-merge regression that adds Write or Edit.

**NO `review-gate.sh` invocation in Phase 6.** Critical departure from the canonical review reference. `review-gate.sh` is invoked ONLY in the Approval Gate section below, keyed on `plan_id`, and only after user approval/rejection. The bats fixture `phase-6-no-review-gate-invocation/` asserts `review-gate.sh` is NOT called during Phase 6.

### Phase 7 — Finalize

- Surface the verdict to the orchestrator (mandatory verdict surfacing).
- Persist findings to the per-skill checkpoint via `checkpoint.sh write` (already invoked in Phase 3A for the cache; final state recorded via the standard `finalize.sh` hook).
- The Phase 3A artifact is cached for the next run by the `.cache/{cache_key}.json` write performed in Phase 3A.
- If verdict is BLOCKED (Phase 6 short-circuited the plan write), exit cleanly here — the Approval Gate section is NOT entered.
- If verdict is APPROVE or REQUEST_CHANGES, proceed to the Approval Gate section below.

## Approval Gate

This section preserves the existing plan-then-execute split-phase contract verbatim. The seven Review Phases above all execute INSIDE the planning phase (fork-isolated analysis); this section handles the user-approval interaction at the boundary between the planning phase and the execution phase (main-context plan execution — out of scope for this skill).

The Approval Gate runs in the **parent (main) context** — NOT in the fork. The fork's `analysis-results.json` and the parent-written plan file (Phase 6 outputs) are the inputs.

**Pre-conditions:**
- The plan file MUST exist at the path returned by `bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh test-automate-plan {story_key} --existing-only` (emitted by Phase 6). The resolver returns the new per-story home if present, else the legacy flat `.gaia/artifacts/test-artifacts/test-automate-plan-{story_key}.md` if present, else exit 1 with no stdout (indicating Phase 6 didn't produce a plan — Approval Gate is NOT entered).
- The story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`.
- The verdict from Phase 5 MUST be APPROVE or REQUEST_CHANGES (BLOCKED short-circuited at Phase 6 — Approval Gate is NOT entered).

### Step 1 — Read and validate plan file

- Read the plan file emitted by Phase 6. Parse YAML frontmatter to extract `plan_id`.
- If the plan file is missing or the story file is missing, HALT: "Cannot proceed with approval gate — plan file or story file not found. Re-run Review Phase 1." Do NOT write any ledger record.
- If the frontmatter is malformed (cannot extract `plan_id`), HALT: "plan_tamper_detected — cannot parse plan_id from plan file frontmatter. Re-run Review Phase 1."

### Step 2 — Present plan for approval

- Display the plan contents: narrative body and `proposed_tests[]` summary (test file paths, test case names, mapped acceptance criteria).
- If the verdict was REQUEST_CHANGES, prepend a "plan changes recommended" marker to the presentation header.
- Record the `plan_id` value at presentation time for tamper detection.

### Step 3 — Collect verdict

- In **normal mode**: prompt the user:
  ```
  [a] Approve (PASSED) | [r] Reject (FAILED) | [x] Abort
  ```
- In **YOLO mode**: auto-approve path:
  1. Load tier-directory allowlist by invoking `test-env-allowlist.sh --test-env .gaia/artifacts/test-artifacts/test-environment.yaml`.
  2. If `test-environment.yaml` is missing: pause for explicit user approval. Log: "allowlist source absent — cannot auto-approve."
  3. For each `proposed_tests[].test_file` path in the plan, check whether it falls within any allowlisted tier directory (prefix match after path normalization).
  4. If ALL proposed test paths are within the allowlist: auto-approve. Set verdict = PASSED.
  5. If ANY proposed test path is outside the allowlist: pause for explicit user approval even in YOLO. Log which path(s) are outside scope.

### Step 4 — Plan-tamper detection

- Immediately before recording the verdict, re-read the plan file and extract the current on-disk `plan_id`.
- If the on-disk `plan_id` differs from the value recorded at presentation time (Step 2), HALT: "plan_tamper_detected — plan_id changed between presentation and verdict. The on-disk plan was overwritten (possibly by a concurrent invocation). Re-run Review Phase 1." `review-gate.sh` MUST NOT be invoked when tamper detected.
- If the `plan_id` matches, proceed to record the verdict against the on-disk `plan_id`.

### Step 5 — Record verdict

- On **PASSED** (user approves or YOLO auto-approves):
  1. Invoke: `${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update --story {story_key} --gate test-automate-plan --verdict PASSED --plan-id {plan_id}`
  2. Patch the plan file's YAML frontmatter `approval` block:
     - Set `approval.verdict` to `"PASSED"`
     - Set `approval.verdict_plan_id` to `{plan_id}`
  3. Use atomic write (per-PID temp file + `mv` rename) for the plan file patch (concurrency safety).
  4. Post-write verification: re-read the plan file and confirm `approval.verdict` = PASSED and `approval.verdict_plan_id` = `{plan_id}`. If divergence, HALT with message pointing at the tamper-detection contract.
  5. Report: "Plan approved. Verdict PASSED recorded for plan_id={plan_id}. Ready for execution-phase execution."
  6. Invoke the composite review-gate-check informationally:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
     ```
     Capture stdout and include the Review Gate table and summary line (`Review Gate: COMPLETE|PENDING|BLOCKED`). Do NOT halt on non-zero exit codes. Log the result and continue regardless of exit code.

- On **FAILED** (user rejects):
  1. Invoke: `${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update --story {story_key} --gate test-automate-plan --verdict FAILED --plan-id {plan_id}`
  2. Patch the plan file's `approval.verdict` to `"FAILED"`.
  3. Report: "Plan rejected. Verdict FAILED recorded. The execution phase will NOT be invoked. Re-run /gaia-test-automate to generate a new plan."
  4. Exit cleanly. Do NOT invoke the execution phase.

- On **Abort**:
  1. Exit cleanly without recording any verdict. Do NOT invoke the execution phase.

### Step 6 — Concurrency safety

- Per-PID temp dir + atomic rename for plan-file writes — concurrent invocations on the same story do not corrupt the plan file; last-writer-wins.
- `review-gate.sh` ledger is keyed by `(story_key, gate_name, plan_id)` — concurrent stories never collide. Same-story concurrent runs: `plan_id` from latest writer wins; tamper detection at Step 4 catches the older invocation (HALT).

### Step 7 — Handoff to the execution phase

- After Step 5 records a successful approval, the execution phase is invoked by a separate skill (OUT OF SCOPE for this skill).
- The execution phase expands the tool surface to `[Read, Write, Edit, Bash, Grep, Glob]` in main context and executes the approved plan (test-file synthesis, bridge execution, evidence emission). Triple-source verification (plan frontmatter + plan-id self-check + ledger lookup) gates execution-phase entry.
- This skill does NOT invoke the execution phase directly — it is a separate downstream skill activation.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-automate/scripts/finalize.sh
