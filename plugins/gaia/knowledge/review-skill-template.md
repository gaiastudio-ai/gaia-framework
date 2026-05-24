# GAIA Review Skill Template (ADR-075)

> **Consumers populated by E65-S2..S7.** This template is the canonical reference shape for the six review skills (`gaia-code-review`, `gaia-security-review`, `gaia-qa-tests`, `gaia-test-automate`, `gaia-test-review`, `gaia-performance-review`). Each consumer is a self-contained `SKILL.md`; Claude Code skills do not have a native include mechanism, so the template is a documented copy-with-stub reference. Per-skill specialization is bounded to (a) own deterministic toolkit and (b) own severity examples — every other concern (fork-write fix, divergence check, severity rubric format, determinism, JSON schema, verdict resolver, persona load, phase structure 1–7) is template-level.
>
> **Sentinel-stub rule.** Stub markers use the unique sentinel pattern `{{GAIA_REVIEW_STUB:NAME}}`. The `evidence-judgment-parity.bats` suite asserts exactly-zero unfilled `GAIA_REVIEW_STUB:` substrings in any consumer SKILL.md. Do NOT use bare `{{TOOLKIT}}` or `{{NAME}}` in template prose — those would collide with the regex. Document literal sentinel strings inside fenced code blocks if they must appear without being interpreted as stubs.

## Unifying Principle (FR-DEJ-1)

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This sentence MUST appear verbatim in every consumer SKILL.md. The parity bats suite enforces verbatim presence (`assert_unifying_principle`).

## Frontmatter Contract (FR-DEJ-10, NFR-DEJ-4)

Every consumer SKILL.md frontmatter MUST declare the read-only fork tool allowlist:

```yaml
allowed-tools: [Read, Grep, Glob, Bash]
```

`Write` and `Edit` are NEVER added to the fork. Persistence of the rendered review report is routed through the parent context (Option A, preferred) or via `review-gate.sh --report-path` (Option B). Fork no-write isolation is invariant.

## Determinism Settings (FR-DEJ-8)

Every LLM dispatch within a review skill MUST set:

```
temperature: 0
model: claude-opus-4-7        # per ADR-074
prompt_hash: sha256:<hex>     # recorded in report header
```

Two runs against unchanged `analysis-results.json` MUST produce findings that match by category and severity (NFR-DEJ-2).

## Seven-Phase Structure (FR-DEJ-2)

Consumer SKILL.md content is organized into seven canonical phases in this order:

### Phase 1 — Setup

- Resolve story file, story key, story branch.
- Invoke `plugins/gaia/scripts/load-stack-persona.sh` in the parent context — lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch (NFR-DEJ-4 preserved).
- Resolve toolkit binaries (skill-specific — see `{{GAIA_REVIEW_STUB:TOOLKIT}}` block).

### Phase 2 — Story Gate

- Run `plugins/gaia/scripts/file-list-diff-check.sh --story-file <path> --base <branch>`.
- Surface divergence Warning to the user; do NOT block. Story Gate semantics are advisory per FR-DEJ-2.
- Honor `no-file-list` / `empty-file-list` / `divergence` reasons.

### Phase 3A — Deterministic Analysis

Run the skill's deterministic toolkit and emit `analysis-results.json` to `.gaia/state/review/{family}/{story_key}/analysis-results.json`. The JSON MUST validate against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

Three-case tool availability (FR-DEJ-4):
1. **Tool present and runs to completion** → `status: passed | failed`, `findings` populated.
2. **Tool not applicable** → `status: skipped`, `skip_reason` populated.
3. **Tool errored / unrecoverable** → `status: errored`, `error_reason` populated.

Cache (FR-DEJ-11): cache key = `hash(File List contents + tool config + tool versions + resolved-config hash)`. Cache lives at `.gaia/state/review/{family}/{story_key}/.cache/` and plugs into `checkpoint.sh`.

```text
{{GAIA_REVIEW_STUB:TOOLKIT}}
# Per-skill specialization: list deterministic tools and their invocation
# commands here. Examples:
#   gaia-code-review:    eslint, prettier, tsc
#   gaia-security-review: semgrep, gitleaks
#   gaia-qa-tests:       coverage, test runner
```

### Phase 3B — LLM Semantic Review

- Read the Phase 3A artifact as evidence.
- Apply the severity rubric (see below) to produce category-organized Critical / Warning / Suggestion findings.
- Determinism settings (temperature 0, pinned opus, prompt hash) are non-negotiable.

### Phase 4 — Architecture Conformance + Design Fidelity

- Cross-check the diff against the architecture document and ADRs referenced by the story.
- For UI changes, compare against the ux-design.md and any Figma context.
- Findings produced here flow into Phase 3B's category buckets (architecture, fidelity).

### Phase 5 — Verdict

Invoke `plugins/gaia/scripts/verdict-resolver.sh --analysis-results <path> --llm-findings <path>`. The resolver applies strict first-match-wins precedence (FR-DEJ-6):

1. Any check `errored` → **BLOCKED**.
2. Any tool `failed-blocking` → **REQUEST_CHANGES**. *The LLM cannot override this.*
3. Any LLM finding `Critical` → **REQUEST_CHANGES**.
4. Otherwise → **APPROVE**.

Resolver stdout is exactly one of `APPROVE | REQUEST_CHANGES | BLOCKED`. The LLM MUST NOT compute or override the verdict.

### Phase 6 — Output + Gate Update

- Render the report at `.gaia/artifacts/implementation-artifacts/{story_key}-review.md` (or per FR-402 naming convention) with two top-level sections:
  - **Deterministic Analysis** — per-tool status table + findings.
  - **LLM Semantic Review** — Critical / Warning / Suggestion organized by category.
  - Final line: `**Verdict: APPROVE | REQUEST_CHANGES | BLOCKED**`.
- Persistence: parent context writes the file (Option A) OR pass via `review-gate.sh --report-path` (Option B). Fork allowlist stays read-only.
- Update the Review Gate row via `review-gate.sh update --story <key> --gate "<Gate Name>" --verdict PASSED|FAILED`. Translation: `BLOCKED` → `FAILED`, `REQUEST_CHANGES` → `FAILED`, `APPROVE` → `PASSED`.

### Phase 7 — Finalize

- Surface the verdict back to the orchestrator per ADR-063 (mandatory verdict surfacing).
- Persist findings to the per-skill checkpoint via `checkpoint.sh`.
- Cache the Phase 3A artifact for the next run.

## Severity Rubric Format (FR-DEJ-7)

Each consumer MUST publish a per-tier severity rubric with **at least two concrete examples per tier** so two runs converge. Format below; per-skill content fills the stub.

### Critical

> Blocking; produces `REQUEST_CHANGES` if the deterministic resolver did not already block.

Generic examples (correctness):
- Off-by-one in a loop bound that produces incorrect output for the documented happy path.
- Null-deref on a code path with no guard, reachable via a documented public API entry point.

```text
{{GAIA_REVIEW_STUB:SEVERITY_EXAMPLES}}
# Per-skill specialization: at least two concrete Critical examples,
# at least two Warning examples, at least two Suggestion examples,
# scoped to this skill's review category.
```

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Generic examples (correctness + readability):
- Edge case unhandled but documented as out-of-scope.
- Function exceeds the team length/complexity threshold and would benefit from extraction.
- Misleading variable name that would surprise a future maintainer.

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications.

Generic examples:
- Comment wording could be tightened.
- Naming could match team convention more closely.
- Consider extracting a helper for clarity.

## `.gaia/state/review/` Concurrency Requirement (S2 Implementation Note)

S1 ships the schema, resolver, and divergence/persona scripts. The `.gaia/state/review/{family}/{story_key}/` directory itself is consumed in S2 (cache plumbing per FR-DEJ-11). When S2 wires the cache:

- Concurrent invocations of any review skill on the same story key (rare, but possible in CI matrix runs) MUST coordinate via `flock` on a per-story lockfile, OR use a per-PID temp directory + atomic rename.
- Cache reads MUST be a single `cat` (atomic on most filesystems for sub-page writes). Cache writes MUST be `tmpfile + rename`.
- Two parallel review-skill invocations on the same story MUST NOT corrupt each other's `analysis-results.json`.

S1 documents this requirement; S2 implements it. Consumers landing in S2..S7 inherit the documented contract.

## Parity Suite (FR-DEJ-12)

`evidence-judgment-parity.bats` enforces no-drift across the six review skills. The empty-loop SKIP-with-message protocol is mandatory for the zero-consumer state (S1 ships, S2 not yet merged) — the suite MUST NOT silently pass with zero assertions. As each consumer migrates, append its SKILL.md path to the `REVIEW_SKILLS` array.

Five assertion helpers are template-level:

1. `assert_allowed_tools_allowlist` — frontmatter `allowed-tools: [Read, Grep, Glob, Bash]`.
2. `assert_unifying_principle` — exact-string match of the unifying principle.
3. `assert_seven_phase_headers` — Setup → Story Gate → 3A → 3B → Architecture Conformance → Verdict → Output → Finalize.
4. `assert_persona_load_hook_present` — `load-stack-persona.sh` referenced.
5. `assert_verdict_resolver_invocation` — `verdict-resolver.sh` referenced.

Plus the stub-marker hygiene check: zero unfilled `GAIA_REVIEW_STUB:` substrings in any consumer.

## Out-of-Scope Reminders

- The skill MUST NOT compute the verdict in natural language. The verdict is `verdict-resolver.sh`'s output, full stop.
- The skill MUST NOT add `Write` or `Edit` to the fork allowlist.
- The skill MUST NOT relax `temperature: 0` or unpin the model.
- Sibling-skill toolkit selection (semgrep configs, perf harnesses, dep audit tools) belongs to each respective story — not this template.

# Consumers: populated by E65-S2..S7
