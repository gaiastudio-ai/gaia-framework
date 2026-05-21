---
name: gaia-review-test
description: Review test quality and identify flakiness. Use when "review tests" or /gaia-review-test (formerly /gaia-test-review).
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-test-review]
deprecated_since: sprint-37
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-review/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill (FR-DEJ-1, ADR-075). For `gaia-test-review` it means: deterministic tools (test-smell detection, flakiness retry-history analysis, fixture analysis) run first and emit a structured `analysis-results.json` artifact. The LLM then performs a test-quality semantic review **on top of** that artifact — it cannot disregard a >5% CI retry-rate finding, it cannot relabel a tool failure as APPROVE, and it cannot promote a Suggestion-tier finding into a verdict-blocker. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill pattern-matches against `gaia-code-review` (E65-S2) as the canonical reference. Per-skill specialization here = (a) the test-quality + flakiness + fixture toolkit and (b) the test-review-aligned severity rubric examples (flaky test, shared mutable fixture, hardcoded sleep, conditional-in-test, magic number). Structural plumbing — fork dispatch, cache key, parent-mediated write — is identical to E65-S2.

**Scope boundary vs S4 (`gaia-qa-tests`).** `gaia-qa-tests` (S4) answers "does coverage exist?" — does each AC have at least one test? `gaia-test-review` (S6) answers "is the existing coverage good?" — are the tests that exist free of smells, flakiness, and fixture bugs? S6 reports findings ONLY on tests that already exist; missing-coverage findings stay in S4. The two skills complement, never overlap.

**Fork context semantics (ADR-041, ADR-045, NFR-DEJ-4):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report is parent-mediated (Option A per ADR-075): the fork returns the rendered report payload to the parent context, and the parent writes the file. `Write` and `Edit` are NEVER added to the fork allowlist.

## Critical Rules

- Knowledge fragments are bundled in this skill's `knowledge/` directory (test-isolation, deterministic-testing, selector-resilience, visual-testing, test-healing) — load them JIT when referenced by a phase, never pre-load.
- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-test [story-key]".
- The story file MUST be resolvable via the shared `scripts/resolve-story-file.sh` helper (E79-S7 / FR-476) which honors the ADR-111 canonical-first contract: `.gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md` first, then legacy `docs/implementation-artifacts/{story_key}-*.md` as fallback. If the helper exits 1 (zero matches), fail with "story file not found for key {story_key}". Do NOT inline-hardcode the `docs/` glob — that breaks on `.gaia/`-canonical projects (AF-2026-05-21-4 Finding 1).
- The story MUST be in `review` status. If not, fail with "story must be in review status before test review".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence is routed through the parent context.
- Test-quality scope is bounded to (a) standard test paths per stack and (b) test-helper patterns in the File List (`*.factory.*`, `fixtures/`, `helpers/`, `conftest.py`). FULL-project scan only on explicit `--full` flag (EC-12).
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (inline, no separate script): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Determinism settings: `temperature: 0`, `model: claude-opus-4-7` (per ADR-074), `prompt_hash` recorded in the report header. Re-running with identical `analysis-results.json` MUST yield findings that match by category and severity (NFR-DEJ-2); textual variation is allowed.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in report header at Phase 6
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce findings that match by `{category, severity}` (NFR-DEJ-2). Textual message variation is allowed; category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch.

## Stack Toolkit Table

The toolkit invoked by Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match. The test-smell detector is per-stack (regex/AST patterns differ across syntaxes); the flakiness analyzer reads the stack's CI test-result format(s); the fixture analyzer is largely stack-agnostic but uses per-stack mutation idioms (e.g., `.push` for JS arrays, `.append` for Python lists):

| Stack key (canonical) | Smell-detection language patterns                     | CI test-result format(s)                          | Flakiness annotations                       |
|-----------------------|-------------------------------------------------------|---------------------------------------------------|---------------------------------------------|
| `ts-dev`              | `await sleep(...)`, `setTimeout(...)`, `if (...)`     | jest `--json` (jest JSON) OR junit XML            | `@flaky`, `it.skip`, `xit`                  |
| `java-dev`            | `Thread.sleep(...)`, `if (...)`                       | junit XML                                         | `@Flaky`, `@Disabled`                       |
| `python-dev`          | `time.sleep(...)`, `if ... in test`                   | pytest junitxml                                   | `pytest.mark.flaky`, `pytest.mark.skip`     |
| `go-dev`              | `time.Sleep(...)`, `if ... in TestXxx`                | `go test -json`                                   | `t.Skip()`, `// flaky:` comments            |
| `flutter-dev`         | `await Future.delayed(...)`, `if (...)`               | `dart test --reporter=json`                       | `@Skip()`, `@Tags(['flaky'])`               |
| `mobile-dev`          | `Thread.sleep(...)`, `XCTSkip(...)`, `if (...)`       | XCTest result bundle / Android junit XML          | `@Disabled`, `XCTSkip`, `@Ignore`           |
| `angular-dev`         | `await sleep(...)`, `setTimeout(...)`, `fakeAsync`    | jest `--json` (jest convention)                   | `xit`, `@flaky`                             |

The table is authoritative for Phase 3A toolkit selection. Phase 3A scope per FR-DEJ-3 is **strict**: test-smell detection + flakiness retry-history analysis + fixture analysis. Phase 3A does NOT invoke linters, formatters, type checkers, or build verification — those belong to `gaia-code-review`. Phase 3A does NOT invoke Semgrep or secret scanners — those belong to `gaia-security-review`. Phase 3A does NOT enumerate AC-coverage gaps — that belongs to `gaia-qa-tests` (the S4 vs S6 scope boundary).

Mismatched stack name (vocabulary drift between `load-stack-persona.sh` output and the table key) → silent skip on smell detection per FR-DEJ-4 case 3 with `skip_reason` populated.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Phase 3B review applies the rubric below. Findings are organized by test-quality category. Coverage targets the four highest-frequency categories: **flaky test** (CI retry rate), **shared mutable fixture** (test-order dependency), **hardcoded sleep** (timing-dependent assertion), **conditional-in-test** (untested branch in test body). Other test-quality categories (magic numbers, long test bodies, missing docstrings) seed Suggestion-tier examples below.

The category+severity sets MUST match across two runs of identical inputs (NFR-DEJ-2 determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical promotion is restricted to deterministic, high-confidence test-quality regressions — flakiness with CI evidence, fixture bugs that cause cross-test interference.

Examples:

- **Flaky test (>5% CI retry rate)** — Test `tests/checkout.spec.ts::places order` is retried in 8 of the last 100 CI runs (8% retry rate, above the 5% Critical threshold). Genuine flakiness, not env-induced — the test depends on a non-mocked HTTP call. Verdict-blocking until either the source of nondeterminism is fixed or the test is quarantined.
- **Shared mutable fixture without setup/teardown reset** — Tests `users.spec.ts` and `roles.spec.ts` both import the same module-level `userStore` array and append to it via `.push()`. No `beforeEach` reset. Test A leaks state into test B; running them in different orders produces different outcomes. Critical because the bug is non-local and silent.
- **Singleton-mutable-state with no reset** — Tests import a logger module that holds `logger.level = 'info'` as a module-level variable. Some tests mutate it to `'debug'` for assertions. No `afterEach` reset. Subsequent tests inherit the mutated state. Critical test-order dependency.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples:

- **Hardcoded sleep in production-path test** — Test contains `await sleep(100)` to wait for an async event. Flaky-prone pattern: the 100ms is empirical, not deterministic. Warning regardless of whether the test currently passes (alignment with E65-S2 EC-12). Excluded: debug-only test files (path matches `*.debug.*` or annotated `@debug`) where sleep is acceptable for manual reproduction.
- **Conditional-in-test outside parameterized pattern** — Test body contains `if (env === 'ci') { expect.toBe(...) } else { expect.toBe(...) }`. Branch logic in a test body conceals coverage — one branch is silently never exercised on a given environment. Warning. Excluded: parameterized-test patterns (`it.each`, `parametrize`, table-driven) where the conditional is part of the test-data structure (downgraded to Suggestion).
- **Long test body 2-5x stack threshold** — Stack threshold is 50 LOC for unit tests; this test is 180 LOC. Warning at 2-5x; Suggestion at 1-2x; Critical only at >5x (per ADR / story EC-6 thresholds).
- **Intermittent flakiness 1-5% retry rate** — Test retried 3 times in 100 runs. Below the Critical threshold but above the Suggestion floor. Warrants investigation but not yet a blocker.

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications.

Examples:

- **Magic number without named constant** — Test contains `expect(result.length).toBe(42)`. The `42` should be a named constant (`EXPECTED_USER_COUNT = 42`) for clarity. Suggestion-tier — readability improvement, no behavior change.
- **Long test body 1-2x threshold** — Test is 70 LOC vs 50 LOC threshold. Mild — surface as a refactor suggestion (extract setup helpers).
- **Rare retry rate <1%** — Test retried once in 200 runs. Possibly environment, possibly genuine flakiness — surface as a Suggestion to investigate, not a Warning.
- **Missing fixture-name docstring** — Pytest fixture `def user_with_admin_role():` has no docstring. Suggest adding one for future maintainers.

**Context-aware classification rules (rubric-driven):**
- Flaky test severity tied to retry rate: >5% Critical; 1-5% Warning; <1% Suggestion (EC-9).
- Shared mutable fixture severity: no reset → Critical; reset present in `beforeEach`/`setUp` → downgrade to Warning (EC-10).
- Hardcoded sleep in test path matching `*.debug.*` or `@debug` annotation → Suggestion (EC-8).
- Hardcoded sleep in test name containing `debounce`, `throttle`, or `timing` → Suggestion (legitimate-use downgrade, EC-3).
- Conditional-in-test inside parameterized pattern (it.each, parametrize, table-driven) → Suggestion (EC-7).
- Read-only fixture access (no `.push`, `.delete`, `.set`, no assignment to fixture variable) → not flagged at all (EC-4).
- Per-(file, line, smell-type) findings: no per-file dedup; LLM aggregates per-file when ≥2 Warning+ findings to surface "this test has multiple quality issues" summary (EC-13).

LLM-cannot-override invariant: a deterministic >5% retry-rate finding from CI history cannot be downgraded by the LLM into APPROVE territory. The rubric tiers above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-review-test [story-key]"
- Resolve the story file path via the shared `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh {story_key}` helper (E79-S7 / FR-476). It honors the ADR-111 canonical-first contract: searches `.gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md` first, then falls back to legacy `docs/implementation-artifacts/{story_key}-*.md`. Exit codes: 0 = single match resolved (stdout = path); 1 = zero matches (fail with "story file not found for key {story_key}"); 2 = multiple matches ambiguity (fail with "multiple story files matched key {story_key}"). Do NOT inline-hardcode the legacy `docs/` glob — see AF-2026-05-21-4 Finding 1.
- Read the resolved story file; parse YAML frontmatter to extract `status` and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`) and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch (NFR-DEJ-4 preserved). Forward the persona payload + canonical stack name into the fork.
- **Tool prereq probe.** For each parser in the stack-toolkit row matched by the canonical stack name (junit-xml parser, jest JSON parser, go-test-json parser, pytest junitxml parser, dart test JSON parser): probe via `command -v <tool>` first. Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key.
- **CI-history token probe (EC-14).** For the resolved CI provider (GitHub Actions / CircleCI / Jenkins): probe for the required environment variable (`GITHUB_TOKEN`, `CIRCLE_TOKEN`, `JENKINS_TOKEN`). On missing token, mark CI history fetch as unavailable in `tool_versions` and fall back to the static flakiness signal source (annotation scan). Never crash on missing token.
- **Three-tier flakiness signal source.** Preferred source: parse CI test-result XML/JSON for retry counts. Fallback: source-level annotations (`@flaky`, `@retry`, `pytest.mark.flaky`). Skip: neither available — emit `status: skipped` with `skip_reason: "no flakiness signal source available (no CI history, no flakiness annotations)"`.
- **Expected-missing-tool (FR-DEJ-4 case 1).** If a required parser binary is absent and not optional for the stack: emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. Do NOT dispatch the fork.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for test review".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory per FR-DEJ-2 — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.review/gaia-test-review/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

**Toolkit invocation.** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1. Phase 3A runs four deterministic analyzers in sequence — driven by the canonical helper `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/phase3a-test-review.sh` (E67-S1, FR-RSV2-1/2). The helper invokes `smell-detector.sh`, `flakiness-analyzer.sh`, `fixture-analyzer.sh`, and `tag-conformance-detector.sh --stack <stack>` (and propagates `--strict` when `GAIA_TEST_TAGGING_STRICT=1` is set per E72-S4 / FR-RSV2-42) and merges their `checks[]` fragments into a single canonical `analysis-results.json` document validating against `plugins/gaia/schemas/analysis-results.schema.json`. Cumulative wall-clock budget per NFR-RSV2-2: ≤90s P95 on a typical story (<500 LOC diff).

**Placeholder-test detection (E67-S2 / FR-RSV2-2 cross-reference).** The shared `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/placeholder-test-detector.sh` script is the **single instance** referenced by both `/gaia-test-automate` (Phase 2 post-generation gate) and `/gaia-review-test` (Phase 3A scanner). The detector flags `expect(true)` / `expect(false)` / `assert True` / `assert False` / `assert_true(...)` / `assert_false(...)` / `test.todo` / `test.skip` / `it.skip` / `xit` / `xdescribe` / `xcontext` / `describe.skip` and empty `it`/`test`/`@test` blocks, emitting structured findings of the form `low_quality_test_generated|<file>:<line>|<pattern>` on stdout. Findings surface as Phase 3A `category: placeholder, severity: critical` entries (untestable assertion equivalent) — they cannot be overridden by the LLM Phase 3B judgment. There is no duplicate copy of the script under `plugins/gaia/skills/gaia-test-review/scripts/` or `plugins/gaia/skills/gaia-test-automate/scripts/` — both skills source the same `review-common/placeholder-test-detector.sh` instance.

**Tag-conformance detection (E72-S4 / FR-RSV2-42).** `tag-conformance-detector.sh` checks each test file for at least one tag declaration using the canonical mechanism for its stack. Standalone use is supported via `--files <glob>` and `--strict` flags (AC10). When `--stack` is omitted the detector auto-classifies each file by extension and routes it to the correct per-stack matcher — useful for monorepos where a single invocation covers multiple stacks (AC9). Per-stack detection patterns are summarized below:

| Stack            | Detection pattern                                                |
| ---------------- | ---------------------------------------------------------------- |
| `ts-dev`         | `describe.each` / `it.each` / tagged `it()` / front-matter `tags:` |
| `angular-dev`    | same as `ts-dev`                                                 |
| `java-dev`       | `@Tag("…")` annotation on class or method                        |
| `python-dev`     | `@pytest.mark.<name>` decorator                                  |
| `go-dev`         | `//go:build <tag>` directive in first 10 lines of the file       |
| `flutter-dev`    | `@Tags(['…'])` annotation                                        |
| `mobile-dev`     | Maestro front-matter `tags:` (YAML) or `@Tag("…")` (Kotlin/Java) |

**Severity mode.** Findings emit at `info` (Suggestion) by default — they surface in `analysis-results.json` but DO NOT escalate Phase 3A verdicts. Strict mode upgrades severity to `warning` (factored into the LLM Phase 3B judgment but still non-blocking). Strict-mode resolution precedence (highest first): CLI `--strict` flag → `GAIA_TEST_TAGGING_STRICT=1` env override → `test_tagging.strict: true` in `config/project-config.yaml` → default false. `phase3a-test-review.sh` propagates `GAIA_TEST_TAGGING_STRICT` to `tag-conformance-detector.sh` so a single env toggle flips the project-wide tagging regime.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/phase3a-test-review.sh \
  --story-key "{story_key}" \
  --stack "<canonical-stack>" \
  --max-lines 500 \
  --file-list <(printf '%s\n' "${file_list[@]}")
```

The four scanners cover the analyzers below (1–3 plus the new tag-conformance scanner that complements smell/flakiness/fixture coverage):

1. **Test-smell detection (per-stack regex/AST).** Scope is bounded by default per EC-12: (a) standard test paths per stack — `**/*.{test,spec}.{ts,tsx}` for ts-dev, `test_*.py + *_test.py` for python-dev, etc.; (b) test-helper patterns in the File List — `*.factory.*`, `*Factory.{js,ts,py}`, `fixtures/`, `helpers/`, `conftest.py` (EC-11). FULL-project scan only on explicit `--full` flag. Smell categories per stack: hardcoded sleeps, conditional-in-test (excluding parameterized patterns — EC-7), magic numbers, long tests (per-stack threshold per EC-6: default 50 LOC body / 5s unit / 30s integration / 60s e2e), ignored assertions. Wall-clock cap: 30s for smell detection alone.

2. **Flakiness retry-history analysis (three-tier signal source).** Preferred: parse the stack's CI test-result format(s) for retry counts.
   - `ts-dev` / `angular-dev`: jest `--json` output (`numFailingTests`, `retried` fields) OR junit XML (`<failure>` + `<rerunFailure>` elements).
   - `java-dev`: junit XML (`<testcase>` with `<rerunFailure>` or `<flakyFailure>` elements).
   - `python-dev`: pytest junitxml (`<testcase>` with `flaky` marker reruns).
   - `go-dev`: `go test -json` (`Action: "rerun"` events).
   - `flutter-dev`: `dart test --reporter=json` (test events with `result: "flaky"`).
   - `mobile-dev`: XCTest result bundle (`xccov`) or Android junit XML.
   Fallback: static-source flakiness annotations (`@flaky`, `@retry`, `pytest.mark.flaky`) when CI history unavailable (EC-2). Skip: when neither source is available — `status: skipped`, `skip_reason: "no flakiness signal source available (no CI history, no flakiness annotations)"`.

   Flakiness threshold: default >5% retry rate = Critical, 1-5% = Warning, <1% = Suggestion (EC-9). Threshold is per-stack overridable via `.gaia-config`.

3. **Fixture analysis (mutable-vs-readonly + setup/teardown reset).** Scan for shared mutable fixtures:
   - Detect mutation methods: `.push`, `.delete`, `.set`, `Object.assign`, `.append`, `.update`, assignment to fixture variable, `Object.defineProperty` un-freeze (EC-4).
   - Read-only access alone (e.g., `const userId = TEST_USERS[0].id`) is NOT flagged.
   - Detect singleton-mutable-state: module-level mutable variables imported by multiple tests (EC-10).
   - Cross-reference with `beforeEach` / `setUp` / `afterEach` / `tearDown` for reset coverage. Reset present → downgrade Critical to Warning. Reset absent → Critical.

**Per-(file, line, smell-type) findings.** Each distinct (file, line, smell-type) tuple is a separate finding — no per-file dedup (EC-13). The LLM in Phase 3B aggregates per-file when ≥2 Warning+ findings.

**Status taxonomy (FR-DEJ-4).** Each tool invocation produces exactly one of:
- `status: passed` — tool ran to completion, no findings, exit code zero.
- `status: failed` — tool ran to completion AND emitted findings (e.g., flakiness analyzer found a >5% retry-rate test; fixture analyzer found a shared mutable fixture without reset). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — tool crashed mid-run, returned an unclassified non-zero exit code, OR exceeded its wall-clock cap. Maps to BLOCKED via precedence rule 1.
- `status: skipped` — tool not applicable; `skip_reason` populated verbatim.

**Path normalization.** Tool outputs vary in path convention. Phase 3A normalizes all `findings[].file` to repo-relative before writing `analysis-results.json` (consistent with E65-S2 / S3 / S4 pattern).

**Cache plumbing (FR-DEJ-11).** Cache lives at `.review/gaia-test-review/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted)
  || test_file_hashes (sha256 per discovered test file, sorted)
  || tool_versions (sorted "tool:version" lines)
  || test_runner_config_hash
  || ci_history_fingerprint
)
```

`ci_history_fingerprint` is the sha256 of the last-N retry-rate snapshot (when CI history is available). This is the EC-2 mitigation: when retry rates change in CI, the cache key changes and Phase 3A re-runs even though source files are unchanged. When CI history is unavailable, this field is the constant string `"unavailable"` so the cache remains stable across runs.

Cache lookup:
1. Compute the candidate cache key from current File List + tool versions + ci_history_fingerprint.
2. Look up `.review/gaia-test-review/{story_key}/.cache/{cache_key}.json`. On miss: run analyzer.
3. On candidate hit, **revalidate file_hashes AND test_file_hashes** against current on-disk hashes. Either input edited externally without changing other cache-key fields → treat as miss.

Cache write (same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.review/gaia-test-review/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic-rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow test-review --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow test-review` can detect drift later.

**Per-test budget.** Per-test budget ≤500ms wall-clock; cumulative ≤60s NFR-DEJ-1 budget.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of per-tool status and findings count for log inspection.

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the test-quality severity rubric to produce category-organized Critical / Warning / Suggestion findings restricted to test-quality scope (flaky test, shared mutable fixture, hardcoded sleep, conditional-in-test, magic number, long test body, missing docstring).

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned per ADR-074)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section).

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message", "smell_type?", "retry_rate?"}, ...] }`. The fork ALSO returns the rendered report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**Determinism contract (NFR-DEJ-2).** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

**Context-aware downgrade rules (rubric-driven).** Apply during Phase 3B classification:
- Smell finding in debug-only test paths (matching `*.debug.*` or annotated `@debug`) → downgrade to Suggestion (EC-8).
- Parameterized-test conditional (it.each, parametrize, table-driven) → downgrade to Suggestion (EC-7).
- Read-only fixture access → not flagged at all (EC-4).
- Legitimate-use sleep (test name contains `debounce`, `throttle`, `timing`) → downgrade to Suggestion (EC-3).

**Multi-smell file aggregation.** When a single test file has ≥2 Warning+ findings, the LLM section surfaces a "this test has multiple quality issues" summary alongside the per-finding entries (EC-13).

**LLM-cannot-override (rule 2 of verdict-resolver).** A deterministic >5% CI retry-rate finding from Phase 3A — `status: failed` → REQUEST_CHANGES — wins over any LLM APPROVE judgment. The rubric downgrades above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the resolver's blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **Test-architecture conformance.** Fork reads `docs/planning-artifacts/architecture.md` and (when present) `docs/planning-artifacts/test-plan.md`. For each test discovered, verify it follows the documented test pyramid (unit / integration / e2e ratios) and lives under the architecture-mandated test directory. Findings under `category: architecture`.
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares E2E selectors used in the discovered tests against `docs/planning-artifacts/design-system/design-tokens.json` and the Figma component manifest — brittle CSS-class selectors against MUI internals are a fidelity concern as well as a brittle-selector smell. Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by `verdict-resolver.sh`. The LLM never computes or overrides it.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh \
  --analysis-results .review/gaia-test-review/{story_key}/analysis-results.json \
  --llm-findings .review/gaia-test-review/{story_key}/llm-findings.json
```

The resolver applies strict first-match-wins precedence (FR-DEJ-6):
1. Any check `status: errored` → **BLOCKED**.
2. Any check `status: failed` with blocking finding → **REQUEST_CHANGES**. *The LLM cannot override this — rule 2 wins over rule 4 (LLM APPROVE) every time.*
3. Any LLM finding `severity: Critical` → **REQUEST_CHANGES**.
4. Otherwise → **APPROVE**.

Stdout is exactly one of `APPROVE | REQUEST_CHANGES | BLOCKED`. **Mapping to Review Gate canonical vocabulary is inline (no separate `verdict-normalizer.sh`):**

| Resolver output  | Review Gate verdict |
|------------------|---------------------|
| APPROVE          | PASSED              |
| REQUEST_CHANGES  | FAILED              |
| BLOCKED          | FAILED              |

This three-line mapping is local to this section per PRD §4.37. If a future review skill diverges, extract to a shared script then (YAGNI).

### Phase 6 — Output + Gate Update

Phase 6 is the **persistence layer**. The fork CANNOT write — persistence is parent-mediated (Option A per ADR-075).

**Fork output.** The fork returns a rendered report payload as its conversational output. The report MUST contain:

- Header: story key, title, prompt_hash, model, temperature.
- `## Deterministic Analysis` — per-tool status table + per-file smell counts + flakiness retry-rate table + per-tool findings list (from `analysis-results.json`).
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by test-quality category (`flaky`, `fixture`, `sleep`, `conditional`, `magic-number`, `long-test`, `architecture`, `fidelity`, `integrity`).
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation.** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.

**Malformed-payload handling.** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, and emits `verdict=BLOCKED` to `review-gate.sh`. Fork output untrustworthy → BLOCKED. The bats fixture covers this case explicitly (mirrors E65-S2 EC-9).

**Parent write to FR-402 locked path.** The parent context writes the rendered report to `docs/implementation-artifacts/test-review-E<NN>-S<NNN>.md` per FR-402 naming convention. The path is **locked**: `test-review-{story_key}.md` — no slug, no date suffix.

**Re-run handling.** Parent **overwrites** the existing review file on re-run (latest verdict wins). No append, no version-suffix. The `review-gate.sh` row update is the source of truth for verdict history if needed.

**Gate row update.** Parent invokes the individual gate update (single-line form): `review-gate.sh update --story "{story_key}" --gate "Test Review" --verdict "{PASSED|FAILED}"`. Equivalent multi-line form for readability:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "Test Review" \
  --verdict "{PASSED|FAILED}"
```

Mapping per Phase 5 table. Confirm exit code 0.

**Composite review gate check.** After the row update, parent invokes the composite check informationally:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
```

Capture stdout for the `Review Gate: COMPLETE|PENDING|BLOCKED` summary (per ADR-054). Do NOT halt on non-zero exit. Sprint-status.yaml may be out of sync — surface a hint to run `/gaia-sprint-status`.

**Fork allowlist sanity.** The frontmatter `allowed-tools` MUST remain exactly `[Read, Grep, Glob, Bash]`. The `evidence-judgment-parity.bats` AC1 assertion catches any post-merge regression that adds Write or Edit.

### Phase 7 — Finalize

- Surface the verdict to the orchestrator per ADR-063 (mandatory verdict surfacing).
- Persist findings to the per-skill checkpoint via `checkpoint.sh write` (already invoked in Phase 3A for the cache; final state recorded via the standard `finalize.sh` hook).
- The Phase 3A artifact is cached for the next run by the `.cache/{cache_key}.json` write performed in Phase 3A.

## References

- ADR-037 — Structured subagent return schema `{status, summary, artifacts, findings, next}`.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations.
- ADR-045 — Review Gate via Sequential `context: fork` Subagents.
- ADR-054 — Composite Review Gate.
- ADR-063 — Subagent Dispatch Contract — Mandatory Verdict Surfacing.
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior.
- ADR-074 — Frontmatter Model Pin for Determinism.
- ADR-075 — Review-Skill Evidence/Judgment Split.
- FR-DEJ-1..12, NFR-DEJ-1..4 — Evidence/Judgment functional and non-functional requirements (PRD §4.37).
- FR-402 — Locked review-file naming convention (`test-review-{story_key}.md`).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-review/scripts/finalize.sh
