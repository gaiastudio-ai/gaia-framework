---
name: gaia-review-code
description: Pre-merge code review. Use when "run code review" or /gaia-review-code (formerly /gaia-code-review).
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-code-review]
deprecated_since: sprint-37
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-code-review/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill. For `gaia-code-review` it means: deterministic tools (linter, formatter, per-file rules, type checker, build verification) run first and emit a structured `analysis-results.json` artifact. The LLM then performs a semantic review **on top of** that artifact — it cannot disregard a `tsc` type error or an `eslint` crash, and it cannot relabel a tool failure as APPROVE. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill is the **canonical reference implementation** for the six review skills; the sibling review skills pattern-match against this file. Any structural decision here cascades into the sibling-review-skill migrations.

**Fork context semantics:** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report is parent-mediated: the fork returns the rendered report payload to the parent context, and the parent writes the file. `Write` and `Edit` are NEVER added to the fork allowlist.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-code [story-key]".
- The story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before code review".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence is routed through the parent context.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (inline, no separate script): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Determinism settings: `temperature: 0`, `model: claude-opus-4-7`, `prompt_hash` recorded in the report header. Re-running with identical `analysis-results.json` MUST yield findings that match by category and severity; textual variation is allowed.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in report header at Phase 6
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce findings that match by `{category, severity}`. Textual message variation is allowed; category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch.

## Stack Toolkit Table

The toolkit invoked by Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match (EC-14):

| Stack key (canonical) | File-scoped tools                         | Project-scoped tools          |
|-----------------------|-------------------------------------------|-------------------------------|
| `ts-dev`              | `eslint`, `prettier`                      | `tsc --noEmit`, `npm run build` |
| `java-dev`            | `checkstyle`, `spotless --check`          | `mvn -DskipTests compile`     |
| `python-dev`          | `ruff check`, `black --check`             | `mypy`, `python -m compileall` |
| `go-dev`              | `gofmt -l`, `golangci-lint run`           | `go vet`, `go build ./...`    |
| `flutter-dev`         | `dart format --output=none --set-exit-if-changed`, `dart analyze` | `flutter build` |
| `mobile-dev`          | `swiftlint`, `ktlint`                     | `xcodebuild build` / `gradle assemble` |
| `angular-dev`         | `eslint`, `prettier`                      | `tsc --noEmit`, `ng build`    |

The table is authoritative for Phase 3A toolkit selection. Phase 3A scope is **strict**: file-scoped (linter, formatter, per-file rules) plus project-scoped (type checker, build verification). Phase 3A does NOT invoke Semgrep, gitleaks, secret scan, dep audit (`npm audit`, `pip-audit`), or test-runner execution (`go test`, `jest`, `vitest`). Those belong to sibling review skills.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Phase 3B review applies the rubric below. Findings outside `correctness` and `readability` are out-of-scope for this skill (security → `gaia-security-review`, performance → `gaia-performance-review`, etc.).

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block.

Examples (correctness only — there is no Critical readability tier):
- Off-by-one in a loop bound that produces incorrect output for the documented happy path.
- Null-deref on a code path with no guard, reachable via a documented public API entry point.
- Resource leak (file handle, DB connection, lock) on the happy path with no `finally` / `defer` / `using`.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples (correctness + readability):
- Edge case unhandled but documented as out-of-scope (correctness).
- Undocumented invariant a future maintainer cannot verify (correctness).
- Function exceeds the team length/complexity threshold (readability).
- Misleading variable name that would surprise a future maintainer (readability).

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications.

Examples:
- Comment wording could be tightened.
- Naming could match team convention more closely.
- Consider extracting a helper for clarity.

The category+severity sets MUST match across two runs of identical inputs (determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-review-code [story-key]"
- Resolve the story file path using the canonical glob: `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. If zero matches: fail. If multiple matches: fail with "multiple story files matched key {story_key}".
- Read the resolved story file; parse YAML frontmatter to extract `status` and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`) and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch. Forward the persona payload + canonical stack name into the fork.
- **Tool prereq probe (EC-4).** For each tool listed in the stack-toolkit table row matched by the canonical stack name: probe via `command -v <tool>` first; fall back to `node_modules/.bin/<tool> --version` (TS/Angular). NEVER use `npx <tool> --version` (triggers npm install and breaks the 60s P95 budget). Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key.
- **Expected-missing-tool (case 1).** If a required toolkit binary is absent and not optional for the stack: emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. Do NOT dispatch the fork.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for code review".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling (EC-2): if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.gaia/state/review/code-review/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

**Toolkit invocation.** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1. Run file-scoped tools (linter, formatter, per-file rules) against the File List. Run project-scoped tools (type checker, build verification) against the project root. Phase 3A scope is strict — see scope table above.

**Status taxonomy.** Each tool invocation produces exactly one of:
- `status: passed` — tool ran to completion, no findings, exit code zero.
- `status: failed` — tool ran to completion AND emitted findings (e.g., `tsc` exit 1/2 with type errors; `eslint` exit 1 with lint findings). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — tool crashed mid-run or returned an unclassified non-zero exit code (e.g., `eslint` exit 2 from a malformed config; `tsc` cannot find tsconfig.json). Maps to BLOCKED via precedence rule 1. Even when partial findings were emitted before the crash (EC-12), `errored` wins over partial findings.
- `status: skipped` — tool not applicable; `skip_reason` populated verbatim.

**Distinguish `failed` vs `errored` by exit-code semantics, not by exit code alone.** `eslint` exits 1 on findings (failed) and 2 on crash (errored). `tsc` 5.x exits 2 on type errors; 4.x sometimes exits 1 — both are findings (failed). The bats fixtures assert the EXACT `status` field, not the exit code (EC-6).

**Not-applicable handling (case 3, EC-7).** If the File List contains no files of the tool's target language, emit `status: skipped` with `skip_reason` matching the language verbatim:
- `tsc` skip when no `.ts`/`.tsx` files in File List: `skip_reason: "no TypeScript files in File List"` (verbatim).
- `mypy` skip when no `.py` files in File List: `skip_reason: "no Python files in File List"` (verbatim).
- The skip decision is **File-List-driven**, not project-structure-driven. A monorepo with `tsconfig.json` at the project root but a Python-only File List still skips `tsc`. The verdict is unaffected by the skip.

**Cache plumbing (EC-1, EC-3, EC-5, EC-13).** Cache lives at `.gaia/state/review/code-review/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe at directory creation).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted)
  || tool_config blob
  || tool_versions (sorted "tool:version" lines)
  || resolved_config_hash
)
```

`resolved_config_hash` is the sha256 of `eslint --print-config <file>` output for ESLint, and `tsc --showConfig` output for TypeScript — NOT the raw config file content. This is the EC-1 mitigation: extended ESLint configs (`extends: airbnb`) and shared config packages change the resolved ruleset without touching the local `.eslintrc`. Hashing the raw file would silently miss those changes.

Cache lookup:
1. Compute the candidate cache key from current File List + tool versions + resolved configs.
2. Look up `.gaia/state/review/code-review/{story_key}/.cache/{cache_key}.json`. On miss: run tools.
3. On candidate hit, **revalidate file_hashes** against current on-disk file hashes (EC-3). A file in the File List can be edited externally without changing any cache-key input — if any cached `file_hashes` entry diverges from the current on-disk hash, treat as miss. Cache key is necessary but not sufficient.

Cache write (EC-5 same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.gaia/state/review/code-review/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic-rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow code-review --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow code-review` can detect drift later.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of per-tool status and findings count for log inspection.

### Phase 3A.5 — API Design Sub-Routine

After the canonical Phase 3A toolkit (linter, formatter, type-checker, build)
has run, the orchestrator invokes the API-design sub-routine — `/gaia-review-api`
is wired into `/gaia-review-code` Phase 3A.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/code/api-design-subroutine.sh \
  --target <project-root>
```

The helper probes for API endpoints (`routes/` or `controllers/` directories,
`openapi.{yaml,yml,json}`, `swagger.{yaml,yml,json}`) under the project root
and emits a single `analysis-results.json`-shaped check fragment under the
`api_design_audit` category.

- **Conditional skip (AC3):** when no API endpoints are detected, the helper
  emits a `status:"skipped"` fragment with the verbatim
  `skip_reason: "No API endpoints detected -- skipping API audit"`. The parent
  `/gaia-review-code` review continues; the skip does NOT affect the parent
  verdict.
- **Failure isolation (AC-EC1):** a sub-routine failure is captured as a
  single `severity:"warning"` finding (`API design audit unavailable --
  {reason}`). The helper ALWAYS exits 0 on detection paths — infrastructure
  failures NEVER cascade as a parent BLOCKED verdict.
- **Evidence merging (AC4):** the parent merges the fragment into its
  `checks[]` array under the `api_design_audit` category. Severity inheritance
  follows the parent's resolved rubric (base + regime + domain +
  project), which governs final classification at verdict-resolver time.
- **Standalone preserved (AC5):** invoking `/gaia-review-api` directly remains
  a fully standalone path — the standalone skill resolves its own rubric and
  emits its own verdict (independent of this sub-routine wiring).

The "API Design Audit" subsection MUST appear in the Phase 6 report whenever
the sub-routine ran (skipped fragments included for transparency).

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the severity rubric to produce category-organized Critical / Warning / Suggestion findings restricted to **correctness + readability** scope only.

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section).

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message"}, ...] }`. The fork ALSO returns the rendered report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**Determinism contract (EC-11).** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **Architecture conformance.** Fork reads `.gaia/artifacts/planning-artifacts/architecture.md`. For each File List entry, verify component placement follows the documented hierarchy, dependency direction matches the architecture, and any ADRs referenced by the story exist with status Accepted. Findings under `category: architecture`.
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares design-token references in the changed code against `.gaia/artifacts/planning-artifacts/design-system/design-tokens.json` and classifies as matched / drifted / missing. Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by `verdict-resolver.sh`. The LLM never computes or overrides it.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh \
  --analysis-results .gaia/state/review/code-review/{story_key}/analysis-results.json \
  --llm-findings .gaia/state/review/code-review/{story_key}/llm-findings.json
```

The resolver applies strict first-match-wins precedence:
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

This three-line mapping is local to this section. If a future review skill diverges, extract to a shared script then (YAGNI).

### Phase 6 — Output + Gate Update

Phase 6 is the **persistence layer**. The fork CANNOT write — persistence is parent-mediated (Option A).

**Fork output.** The fork returns a rendered report payload as its conversational output. The report MUST contain:

- Header: story key, title, prompt_hash, model, temperature.
- `## Deterministic Analysis` — per-tool status table + per-tool findings list (from `analysis-results.json`).
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by category (correctness, readability, architecture, fidelity).
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation (EC-9).** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.

**Malformed-payload handling (EC-9).** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, and emits `verdict=BLOCKED` to `review-gate.sh`. Fork output untrustworthy → BLOCKED. The bats fixture covers this case explicitly.

**Parent write — resolve the path via the single-source resolver.** The basename is the locked form `code-review-{story_key}.md` — no slug, no date suffix. The DIRECTORY is resolved by the shared helper so all six review skills agree without re-implementing path logic:

```bash
REPORT_PATH="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-review-report-path.sh --key {story_key} --type code-review)"
```

This returns the NEW canonical per-story home `…/epic-{slug}/{story_key}-{slug}/reviews/code-review-{story_key}.md` (the `reviews/` dir is created) when the story is in the per-story layout, else the legacy flat `.gaia/artifacts/implementation-artifacts/code-review-{story_key}.md` (read-compat during migration). `review-summary-gen.sh`'s proof-of-execution accepts EITHER home. Write the rendered report to `$REPORT_PATH`.

**Re-run handling (EC-8).** Parent **overwrites** the existing review file on re-run (latest verdict wins). No append, no version-suffix. The `review-gate.sh` row update is the source of truth for verdict history if needed.

**Gate row update.** Parent invokes the individual gate update (single-line form): `review-gate.sh update --story "{story_key}" --gate "Code Review" --verdict "{PASSED|FAILED}"`. Equivalent multi-line form for readability:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "Code Review" \
  --verdict "{PASSED|FAILED}"
```

Mapping per Phase 5 table. Confirm exit code 0.

**Composite review gate check.** After the row update, parent invokes the composite check informationally:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
```

Capture stdout for the `Review Gate: COMPLETE|PENDING|BLOCKED` summary. Do NOT halt on non-zero exit. Sprint-status.yaml may be out of sync — surface a hint to run `/gaia-sprint-status`.

**Fork allowlist sanity.** The frontmatter `allowed-tools` MUST remain exactly `[Read, Grep, Glob, Bash]`. The `evidence-judgment-parity.bats` AC1 assertion catches any post-merge regression that adds Write or Edit (EC-10).

### Phase 7 — Finalize

- Surface the verdict to the orchestrator (mandatory verdict surfacing).
- Persist findings to the per-skill checkpoint via `checkpoint.sh write` (already invoked in Phase 3A for the cache; final state recorded via the standard `finalize.sh` hook).
- The Phase 3A artifact is cached for the next run by the `.cache/{cache_key}.json` write performed in Phase 3A.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-code-review/scripts/finalize.sh
