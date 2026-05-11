---
name: gaia-review-qa
description: Generate QA test cases and review test coverage. Use when "generate QA tests" or /gaia-review-qa (formerly /gaia-qa-tests).
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-qa-tests]
deprecated_since: sprint-37
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-qa-tests/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill (FR-DEJ-1, ADR-075). For `gaia-qa-tests` it means: deterministic tools (test-discovery + AC-to-test coverage analyzer; optional branch-coverage cross-reference) run first and emit a structured `analysis-results.json` artifact. The LLM then performs a QA semantic review **on top of** that artifact — it cannot disregard a 0% AC-coverage finding, it cannot relabel a tool-failure as APPROVE, and it cannot promote a Suggestion-tier finding into a verdict-blocker. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill pattern-matches against `gaia-code-review` (E65-S2) as the canonical reference. Per-skill specialization here = (a) the QA toolkit (test-discovery + AC-coverage analyzer) and (b) the QA-aligned severity rubric examples (missing AC coverage, weak assertion, brittle selector, untested error path). Structural plumbing — fork dispatch, cache key, parent-mediated write — is identical to E65-S2.

**Fork context semantics (ADR-041, ADR-045, NFR-DEJ-4):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report is parent-mediated (Option A per ADR-075): the fork returns the rendered report payload to the parent context, and the parent writes the file. `Write` and `Edit` are NEVER added to the fork allowlist.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-qa [story-key]".
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before QA tests".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence is routed through the parent context.
- Do NOT write executable test files to the source tree (`tests/`, `spec/`, `__tests__/`, `e2e/`). Document test cases in the QA report only — test-file authoring belongs to `/gaia-test-automate`.
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

The toolkit invoked by Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match (EC-8). The AC-coverage analyzer is stack-agnostic; only the test-discovery globs vary per stack:

| Stack key (canonical) | Test-discovery globs                                                                 | Optional branch-coverage tool         |
|-----------------------|---------------------------------------------------------------------------------------|---------------------------------------|
| `ts-dev`              | `**/*.{test,spec}.{ts,tsx,js,jsx}` + `__tests__/**/*.{ts,tsx,js,jsx}`                 | `nyc` / `istanbul` (optional)         |
| `java-dev`            | `src/test/**/*Test.java`                                                              | `jacoco` (optional)                   |
| `python-dev`          | `test_*.py` + `*_test.py`                                                             | `coverage.py --branch` (optional)     |
| `go-dev`              | `*_test.go`                                                                           | `go test -cover` (optional)           |
| `flutter-dev`         | `test/**/*_test.dart`                                                                 | `flutter test --coverage` (optional)  |
| `mobile-dev`          | iOS `**/*Tests.swift`; Android `src/test/**/*Test.kt` + `src/androidTest/**/*Test.kt` | `xccov` / `jacoco` (optional)         |
| `angular-dev`         | `**/*.{spec,test}.{ts,js}` (jest convention)                                          | `jest --coverage` (optional)          |

Phase 3A scope per FR-DEJ-3 is **strict**: test-discovery + AC-to-test coverage analysis (+ optional branch-coverage cross-reference for untested-error-path findings). Phase 3A does NOT invoke linters, formatters, type checkers, or build verification — those belong to `gaia-code-review`. Phase 3A does NOT invoke Semgrep, secret scanners, or dep audits — those belong to `gaia-security-review`.

Mismatched stack name (vocabulary drift between `load-stack-persona.sh` output and the table key) → silent skip on test-discovery per FR-DEJ-4 case 3 with `skip_reason` populated.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Phase 3B review applies the rubric below. Findings are organized by QA category. Coverage targets the four highest-frequency categories: **missing AC coverage**, **weak assertion**, **brittle selector**, **untested error path**. Other QA categories (over-coverage, FR-traceability gaps, malformed AC text) seed Suggestion-tier examples below.

The category+severity sets MUST match across two runs of identical inputs (NFR-DEJ-2 determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical promotion is restricted to (a) primary AC coverage gaps on P0/high-priority ACs, and (b) untested error paths on user-input boundaries with deterministic branch-coverage evidence.

Examples:

- **Missing AC coverage (primary, P0)** — Story AC1 ("Given invalid email, when submit, then reject with 422") is marked priority P0 in the story frontmatter; AC-coverage analyzer finds zero tests matching by AC-ID prefix or Given/When/Then pattern. Coverage gap on a P0 AC is verdict-blocking.
- **Untested error path on user-input boundary** — Source contains `try { parseUserInput(req.body) } catch (e) { throw new ValidationError(e); }` on a documented public-API entry point; branch-coverage tool reports the catch branch as uncovered AND no test exercises ValidationError throwing. The error-path AC (e.g., "Given malformed payload, when parsed, then ValidationError is thrown") is uncovered.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples:

- **Weak assertion** — Test for AC3 ("Given valid order, when submitted, then status is `confirmed`") only contains `expect(result).toBeDefined()`. Test passes but does not verify the actual `status === 'confirmed'` post-condition. Assertion strength is a Warning regardless of coverage tier (EC-5).
- **Brittle selector** — UI E2E test uses `cy.get('.MuiButton-root.css-1xy2z')` — a CSS class tied to MUI internals that will break on the next library upgrade. Prefer ARIA-based selectors like `screen.getByRole('button', { name: /submit/i })`. Warning regardless of whether the test currently passes (EC-12).
- **Missing edge-case AC coverage** — Story has 13 edge-case ACs (AC-EC1..AC-EC13); 4 are uncovered. Per primary-vs-edge-case differential weighting, an uncovered edge-case AC is ALWAYS Warning (NEVER Critical), because edge cases are awareness markers not always testability targets (EC-9).
- **Untested error path on non-boundary code** — Internal helper has a `catch` branch that recovers gracefully; no test verifies the recovery. Warning, not Critical, when the AC priority is not P0 and the path is not on a user-input boundary.

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications.

Examples:

- **Redundant tests (over-coverage)** — Single AC has three tests that exercise the same path with cosmetic variation. Coverage analyzer reports `count=3` for that AC; coverage is per-AC (matched: yes/no, count: N) — coverage=100% means every AC has ≥1 test, NOT weighted by count. Over-coverage is a Suggestion-tier DRY opportunity (EC-11).
- **Missing FR-traceability comment** — Story frontmatter `traces_to: [FR-DEJ-3, FR-DEJ-4]` is set but no test body references those FR IDs. Phase 3B treats FR-traceability as a SEPARATE concern from AC-coverage — surfaces as Suggestion when comments are absent (EC-10).
- **Unparseable AC text** — Story AC reads "The system should be performant" — no Given/When/Then structure, no measurable threshold. AC parser reports `category: ac-quality` for that AC; the LLM may suggest a concrete rewording. Reported as "unparseable AC" rather than "uncovered AC" (EC-14).

**Context-aware classification rules (rubric-driven):**
- Primary AC gap → severity tied to AC priority (P0 → Critical; P1/P2 → Warning).
- Edge-case AC gap → ALWAYS Warning (never Critical) — edge cases are awareness, not always testability targets (EC-9).
- Untested error path → Critical when branch-coverage tool deterministically confirms an uncovered catch on a user-input boundary AC; Warning otherwise (EC-13).
- Over-coverage (test_count > 1 for a single AC) → Suggestion (EC-11).
- Cross-story tests (test names/paths attributed to a different `story_key`) → not counted as coverage, reported separately as `unattributed_tests` (EC-4).

LLM-cannot-override invariant: a deterministic 0%-coverage finding on a P0 AC cannot be downgraded by the LLM into APPROVE territory. The rubric tiers above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-review-qa [story-key]"
- Resolve the story file path using the canonical glob: `docs/implementation-artifacts/{story_key}-*.md`. If zero matches: fail. If multiple matches: fail with "multiple story files matched key {story_key}".
- Read the resolved story file; parse YAML frontmatter to extract `status`, `traces_to`, and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`) and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch (NFR-DEJ-4 preserved). Forward the persona payload + canonical stack name into the fork.
- **Tool prereq probe.** For each tool used by the resolved stack: probe via `command -v <tool>` first; fall back to `node_modules/.bin/<tool> --version` (TS/Angular). NEVER use `npx <tool> --version` (triggers npm install and breaks the NFR-DEJ-1 60s P95 budget). Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key.
- **Optional branch-coverage probe (EC-13).** Probe the stack's branch-coverage binary (`nyc`, `coverage.py`, `go test -cover`, `jacoco`, etc.). If absent, untested-error-path findings degrade from Critical-eligible to Suggestion-only — LLM cannot promote without deterministic evidence.
- **Expected-missing-tool (FR-DEJ-4 case 1).** If the test runner is absent for a stack that requires it, emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. Do NOT dispatch the fork.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for QA tests".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory per FR-DEJ-2 — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.review/gaia-qa-tests/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

**Toolkit invocation.** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1. Run test-discovery + AC-coverage analyzer per row.

1. **Test-discovery (bounded scope by default per EC-6).** Glob test files matching File List directories + their nearest test-directory ancestor (e.g., `src/foo.ts → tests/foo.test.ts` or `src/__tests__/foo.test.ts`). Full-project scan only on explicit `--full` flag. Multi-stack monorepo (EC-2) runs discovery per matching convention; `analysis-results.json:tests_discovered` is keyed by stack with separate counts. On zero discovered tests, status=`skipped` with `skip_reason: "no test files found via standard discovery globs"` (EC-8). Wall-clock cap: 30s.

2. **AC parser (markdown-aware, NOT raw regex).** Use a YAML/markdown-aware parser (`mistune`, `remark`, or robust YAML extractor) to handle backticks, code blocks, pipe characters, and asterisks (EC-7). Extract Given/When/Then text content per AC. Flag malformed ACs as `status: warning, category: ac-quality` for ACs without Given/When/Then structure (EC-14). Zero-AC story → `status: failed` with finding "No acceptance criteria found in story" (EC-3); resolver maps to REQUEST_CHANGES via precedence rule 2 (LLM-cannot-override).

3. **AC-coverage analyzer (dual-strategy matching, EC-1).** Two-pass match per AC:
   - **Primary match** — AC-ID prefix in test path or test name. Examples: `tests/E65-S4-AC1.test.ts`, `it('AC1: should reject invalid email', ...)`, `def test_AC1_rejects_invalid_email():`.
   - **Fallback match** — Given/When/Then pattern match against test description string. Example: AC text "Given invalid email, when submit, then reject" matches a test named `'should reject invalid email when submitted'`.
   - **Cross-story attribution scoping (EC-4).** Only tests with the current `story_key` in path or test name count toward coverage. Tests without explicit story_key attribution are reported separately under `unattributed_tests[]`, NOT counted as coverage.

4. **Primary vs edge-case AC differential weighting (EC-9).** Primary AC gap → severity tied to AC priority (P0 → Critical, P1/P2 → Warning). Edge-case AC gap → ALWAYS Warning (NEVER Critical).

5. **Per-AC coverage reporting (EC-11).** Report `{ac_id, matched: bool, test_count: N}` per AC. coverage=100% means all ACs matched ≥1 test (NOT weighted by count). Over-coverage (count>1) is Suggestion-tier (potential test redundancy / DRY opportunity).

6. **Optional branch coverage (EC-13).** If the branch-coverage tool from Phase 1 is present, parse its output to identify uncovered catch blocks. Cross-reference with error-path ACs: error-path AC + uncovered catch + user-input boundary → Critical-eligible; else Warning.

**Status taxonomy (FR-DEJ-4).** Each tool invocation produces exactly one of:
- `status: passed` — tool ran to completion, no findings, exit code zero.
- `status: failed` — tool ran to completion AND emitted findings (e.g., AC-coverage analyzer found a P0 AC with zero matches; AC parser found zero ACs in the story file). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — tool crashed mid-run, returned an unclassified non-zero exit code, OR exceeded its wall-clock cap. Maps to BLOCKED via precedence rule 1.
- `status: skipped` — tool not applicable; `skip_reason` populated verbatim.

**Path normalization.** Tool outputs vary in path convention. Phase 3A normalizes all `findings[].file` to repo-relative before writing `analysis-results.json` (consistent with E65-S2 / E65-S3 pattern).

**Cache plumbing (FR-DEJ-11).** Cache lives at `.review/gaia-qa-tests/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted)
  || test_file_hashes (sha256 per discovered test, sorted)
  || story_acs_hash (sha256 of canonicalized AC list — primary + edge-case)
  || tool_versions (sorted "tool:version" lines)
)
```

`story_acs_hash` is the EC-3 mitigation: story ACs are part of the deterministic input — when ACs change, coverage analysis MUST re-run. A cached `analysis-results.json` from a prior AC list returns a stale verdict if `story_acs_hash` is omitted.

Cache lookup:
1. Compute the candidate cache key from current File List + test file hashes + story_acs_hash + tool versions.
2. Look up `.review/gaia-qa-tests/{story_key}/.cache/{cache_key}.json`. On miss: run analyzer.
3. On candidate hit, **revalidate file_hashes AND test_file_hashes** against current on-disk hashes. Either input edited externally without changing other cache-key fields → treat as miss.

Cache write (same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.review/gaia-qa-tests/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic-rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow qa-tests --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow qa-tests` can detect drift later.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of per-AC coverage and discovered-tests count for log inspection.

### Phase 3A.1 — Project-config-driven test execution (E67-S4)

After the test-discovery / AC-coverage analyzer completes, the skill MAY run the configured test suites and capture execution evidence. This step sits between Phase 3A and Phase 3B because the resulting `execution-evidence.json` feeds the verdict-resolver alongside `analysis-results.json` (per source-report section 5.2 ordering).

**Driver script.** Phase 3A.1 is fully scripted via:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/qa-test-runner.sh \
  --story-key {story_key} \
  --workdir .review/gaia-qa-tests/{story_key} \
  --config config/project-config.yaml
```

The runner emits `.review/gaia-qa-tests/{story_key}/execution-evidence.json` validating against `plugins/gaia/schemas/execution-evidence.schema.json`.

**Tier resolution.** The runner reads `test_execution.tier_{1,2,3}.placement` from `project-config.yaml` (per FR-RSV2-11, ADR-077) and matches each tier's placement against `GAIA_EXECUTION_CONTEXT` (`local | ci_pre_merge | ci_post_merge | deployment | post_deploy`). Only tiers whose placement matches the active context run; the rest are skipped.

**Per-tier execution.** Each active tier's `command` is invoked with `timeout_seconds` enforcement (POSIX-portable; `timeout` when present, `perl` alarm fallback for macOS bash 3.2). The runner captures `exit_code`, `duration_seconds`, `pass_count`, `fail_count`, and `timeout` per suite.

**Test Execution Bridge integration (ADR-044, AC8).** When `test_execution_bridge.bridge_enabled: true`, the runner delegates execution to the configured `run_tests_path` (the bridge's `run-tests.sh` entry point) instead of invoking commands directly. The bridge's JSON response is normalized into the `suites[]` shape of `execution-evidence.json`, and `bridge_used: true` is recorded for the audit trail. When the bridge is disabled or the binary is absent, the runner falls back to direct execution.

**Graceful skip (AC7).** When `test_execution` is absent from `project-config.yaml`, the runner emits an `execution-evidence.json` with `skipped: true` and an INFO diagnostic; the verdict resolver then proceeds with AC coverage analysis only.

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the QA severity rubric to produce category-organized Critical / Warning / Suggestion findings restricted to QA scope (missing AC coverage, weak assertion, brittle selector, untested error path, over-coverage, FR-traceability gaps, malformed AC text).

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned per ADR-074)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section), AC text (primary + edge-case).

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message", "ac_ref?", "fr_ref?"}, ...] }`. The fork ALSO returns the rendered report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**Determinism contract (NFR-DEJ-2).** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

**LLM-cannot-override (rule 2 of verdict-resolver).** A deterministic finding from Phase 3A — e.g., zero-AC story (EC-3) → `status: failed` → REQUEST_CHANGES — wins over any LLM APPROVE judgment. The rubric downgrades above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the resolver's blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

### Phase 3C — TC generation for uncovered ACs (E67-S4)

Phase 3C runs after Phase 3B's semantic review and produces TC specifications for ACs flagged uncovered by Phase 3A's coverage analyzer. The output feeds `/gaia-test-automate` as the queue of new test cases to author.

**Output.** `.review/gaia-qa-tests/{story_key}/qa-test-cases-{story_key}.json` — a JSON array of TC entries validating against `plugins/gaia/schemas/qa-test-cases.schema.json`. Each entry contains:

| Field         | Type     | Notes                                                                |
|---------------|----------|----------------------------------------------------------------------|
| `tc_id`       | string   | `TC-{story_key}-{N}` (regex `^TC-E[0-9]+-S[0-9]+-[0-9]+$`)           |
| `ac_ref`      | string   | Identifier of the AC the TC traces to (e.g., `AC1`)                  |
| `description` | string   | One-line summary                                                     |
| `given`       | string   | Given clause                                                         |
| `when`        | string   | When clause                                                          |
| `then`        | string   | Then clause                                                          |
| `type`        | enum     | `Unit` \| `Integration` \| `E2E`                                     |
| `priority`    | enum?    | Optional priority hint (`P0`/`P1`/`P2`/`P3`) inherited from the AC   |
| `tags`        | array?   | Optional free-form tags                                              |

**Determinism + traceability rules (AC1, AC2).**
- Every entry's `ac_ref` MUST reference a real AC identifier present in the story file. No orphan TC entries.
- `tc_id` values within a single file MUST be unique (no duplicates).
- When all ACs are covered, the file is an empty JSON array (`[]`) — Phase 3C does NOT emit superfluous TCs.

**Deterministic boilerplate step (E67-S8).** Before LLM scenario authoring, the fork invokes `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/qa-tc-generator.sh --story <path> --output .review/gaia-qa-tests/{story_key}/qa-test-cases-{story_key}.json` to produce deterministic TC scaffolds (one row per AC, schema-conformant, idempotent re-runs are no-ops). The generator is the boilerplate layer — it never invokes an LLM. Output rows have `type: "Unit"` and scaffold `given/when/then` text derived 1:1 from the AC body.

**LLM-assisted scenario authoring.** After the deterministic boilerplate step, Phase 3C is LLM-assisted within the fork (Vera persona). The fork reads the uncovered-AC list from Phase 3A `analysis-results.json`, the boilerplate scaffolds emitted by `qa-tc-generator.sh`, and the story file's AC text, then refines the `given/when/then` text and may upgrade `type` to `Integration` or `E2E`. The deterministic part (schema, traceability, uniqueness, AC mapping) is enforced by `qa-tc-generator.sh` and the schema before the parent persists the file.

**LLM-cannot-override invariant.** Phase 3C cannot suppress an uncovered-AC finding by silently dropping a TC entry — the schema requires every uncovered AC to have at least one TC.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **QA architecture conformance.** Fork reads `docs/planning-artifacts/architecture.md` and (when present) `docs/planning-artifacts/test-plan.md`. For each test discovered, verify it follows the documented test pyramid (unit / integration / e2e ratios) and lives under the architecture-mandated test directory. Findings under `category: architecture`.
- **FR-traceability check.** When story frontmatter `traces_to: [FR-...]` is set, fork searches discovered test bodies for FR ID references (comments or test descriptions). Missing FR-traceability surfaces as a Suggestion-tier finding (EC-10).
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares E2E selectors in the discovered tests against `docs/planning-artifacts/design-system/design-tokens.json` and the Figma component manifest. Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by `verdict-resolver.sh`. The LLM never computes or overrides it.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh \
  --analysis-results .review/gaia-qa-tests/{story_key}/analysis-results.json \
  --llm-findings .review/gaia-qa-tests/{story_key}/llm-findings.json \
  [--execution-evidence .review/gaia-qa-tests/{story_key}/execution-evidence.json]
```

The resolver applies strict first-match-wins precedence (FR-DEJ-6, extended by E67-S4 AC9):
1. Any check `status: errored` → **BLOCKED**.
1b. Any required-tier suite with `timeout: true` in `execution-evidence.json` → **BLOCKED**.
2a. Any required-tier suite with non-zero `exit_code` (and not a timeout) in `execution-evidence.json` → **REQUEST_CHANGES**.
2. Any check `status: failed` with blocking finding → **REQUEST_CHANGES**. *The LLM cannot override this — rule 2 wins over rule 4 (LLM APPROVE) every time.*
3. Any LLM finding `severity: Critical` → **REQUEST_CHANGES**.
4. Otherwise → **APPROVE**.

When `--execution-evidence` is omitted, rules 1b and 2a are skipped and pre-S4 four-rule behavior is preserved (backward compat).

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
- `## Deterministic Analysis` — per-tool status table + per-AC coverage table + per-tool findings list (from `analysis-results.json`).
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by QA category (`coverage`, `assertion`, `selector`, `error-path`, `traceability`, `ac-quality`, `architecture`, `fidelity`, `integrity`).
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation.** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.

**Malformed-payload handling.** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, and emits `verdict=BLOCKED` to `review-gate.sh`. Fork output untrustworthy → BLOCKED. The bats fixture covers this case explicitly (mirrors E65-S2 EC-9).

**Parent write to FR-402 locked path.** The parent context writes the rendered report to `docs/implementation-artifacts/qa-tests-E<NN>-S<NNN>.md` per FR-402 naming convention. The path is **locked**: `qa-tests-{story_key}.md` — no slug, no date suffix.

**Phase 3C TC artifact persistence.** When Phase 3C produced uncovered-AC TCs, the parent ALSO writes the rendered TC array to `.review/gaia-qa-tests/{story_key}/qa-test-cases-{story_key}.json` (validating against `plugins/gaia/schemas/qa-test-cases.schema.json`). Empty arrays are omitted. The TC file is consumed downstream by `/gaia-test-automate`.

**Phase 3A.1 evidence artifact.** When Phase 3A.1 ran, `.review/gaia-qa-tests/{story_key}/execution-evidence.json` is already present (written by `qa-test-runner.sh`). The parent does not duplicate the write; the file is referenced by the verdict-resolver invocation in Phase 5.

**Re-run handling.** Parent **overwrites** the existing review file on re-run (latest verdict wins). No append, no version-suffix. The `review-gate.sh` row update is the source of truth for verdict history if needed.

**Gate row update.** Parent invokes the individual gate update (single-line form): `review-gate.sh update --story "{story_key}" --gate "QA Tests" --verdict "{PASSED|FAILED}"`. Equivalent multi-line form for readability:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "QA Tests" \
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
- FR-402 — Locked review-file naming convention (`qa-tests-{story_key}.md`).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-qa-tests/scripts/finalize.sh
