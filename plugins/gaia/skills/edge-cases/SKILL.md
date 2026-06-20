---
name: edge-cases
description: Structured edge case analysis for M+ stories. JIT-loaded by /gaia-create-story Step 4b to enumerate boundary, error, timing, concurrency, integration, security, data, and environment scenarios for a single story's acceptance criteria. Returns a structured edge_case_results list. Non-blocking — failure degrades gracefully.
version: '1.0'
allowed-tools: [Read]
orchestration_class: light-procedural
---

# Edge Cases Skill

> Structured edge case analysis for M+ stories. Invoked as a mandatory sub-step by `/gaia-create-story` after acceptance criteria are drafted, and available as a standalone skill for any agent or workflow that needs to enumerate edge cases, error scenarios, and boundary conditions.

> **Native Claude Code conversion.** This skill is the native Claude Code port of the legacy `_gaia/dev/skills/edge-cases.md` dev skill. Section markers (`<!-- SECTION: ... -->`) are preserved verbatim so the JIT callable contract consumed by `/gaia-create-story` Step 4b remains functionally equivalent. This is a shared content skill — no agent memory sidecars are loaded.

> **Applicable to:** all 9 stack dev agents (typescript, angular, flutter, java, python, mobile, go, bash, embedded). The legacy `applicable_agents` frontmatter field is dropped.

---

<!-- SECTION: overview -->
## Overview

The edge-cases skill enumerates scenarios that are *not* the happy path — boundary conditions, error paths, timing issues, input extremes, failure modes, and concurrency hazards — and returns them as a structured list so downstream artifacts (stories, tests, reviews) can trace coverage.

This skill is JIT-loaded. It MUST NOT be pre-loaded by any workflow. Token budget for a single invocation is capped at 8K tokens including the input context and the generated output.

When invoked from `/gaia-create-story`, the skill is scoped to a single story's acceptance criteria and runs in-context — no separate workflow invocation, no sub-agent spawn.

---

<!-- SECTION: when-to-invoke -->
## When to Invoke

- `/gaia-create-story` — mandatory for stories with size M, L, or XL (the size gate at Step 4 of create-story instructions.xml enforces this). S-sized stories skip this skill to preserve token budget.
- `/gaia-edge-cases` — standalone command for ad-hoc edge case brainstorming on existing artifacts.
- Other workflows MAY load this skill when a step references `edge-cases` by name.

**Do NOT invoke** this skill for:
- Stories that are already marked `done` (edge cases should be captured during planning)
- Purely cosmetic / copy changes (no behavior to enumerate)
- S-sized stories (gate excludes them by design)

---

<!-- SECTION: input-contract -->
## Input Contract

The caller passes the following context to the skill:

| Field | Type | Required | Description |
|---|---|---|---|
| `story_key` | string | yes | e.g., `E19-S9` — used as prefix for edge case IDs |
| `story_title` | string | yes | Human-readable title |
| `story_description` | string | yes | The user story paragraph (As a / I want / so that) |
| `acceptance_criteria` | string[] | yes | List of AC strings in Given/When/Then format |
| `size` | enum | yes | One of `S`, `M`, `L`, `XL` (skill halts if `S`) |
| `architecture_excerpt` | string | no | Optional relevant ADR or architecture section |

Total input context MUST stay under ~5K tokens to leave room for the output inside the 8K budget.

---

<!-- SECTION: output-schema -->
## Output Schema

The skill returns a structured list. Each edge case is an object with exactly these fields:

```yaml
edge_case_results:
  - id: "EC-1"          # string — sequential EC-{N} numbering, unique within a single invocation
    scenario: "..."     # string — one-line description of the edge case
    input: "..."        # string — specific input / precondition that triggers it
    expected: "..."     # string — expected system behavior or output
    category: "..."     # enum — see category list below
```

**Required fields (all five MUST be present on every result):**
- `id` — `EC-{N}` format (EC-1, EC-2, ...)
- `scenario` — what the edge case is
- `input` — the triggering input, state, or precondition
- `expected` — the expected behavior
- `category` — one of the categories below

**Category enum:**
- `boundary` — min/max values, empty sets, off-by-one, buffer limits
- `error` — validation failures, exception paths, invalid inputs
- `timing` — race conditions, timeouts, retries, rate limits
- `concurrency` — parallel access, locking, idempotency
- `integration` — upstream/downstream dependency failures, contract mismatches
- `security` — authz bypass, injection, privilege escalation
- `data` — malformed data, encoding, unicode, large payloads
- `environment` — offline, degraded, platform-specific quirks

If no edge cases are identified, return an empty list and log a note — do NOT fabricate edge cases to pad the output.

Output format when returned to the caller: YAML-serializable list. The caller (e.g., `/gaia-create-story`) stores this list in the `edge_case_results` variable before writing the story file to disk.

---

<!-- SECTION: analysis-heuristics -->
## Analysis Heuristics

Use these prompts to drive enumeration — one or two results per heuristic is typical, not all will apply:

1. **Boundary sweep** — for every numeric input, what happens at 0, 1, max, max+1, negative, and fractional? For every collection, what happens empty and full?
2. **Input extremes** — what about empty strings, very long strings, unicode, null, missing fields, extra fields, wrong types?
3. **State transitions** — can the operation be invoked in an unexpected state? What if it is called twice? What if it is called while another operation is in flight?
4. **Failure paths** — what upstream dependencies can fail? What happens on timeout, 5xx, partial response, network partition?
5. **Security angles** — can a lower-privileged user trigger it? Can input be injected into a downstream query/command?
6. **Time and clock** — what happens across DST transitions, leap seconds, at midnight, with negative clock skew?
7. **Resource limits** — what happens under memory pressure, slow disk, saturated queues?
8. **Idempotency** — is the operation safe to retry? What if the same request arrives twice with the same id?

---

<!-- SECTION: token-budget -->
## Token Budget

The skill invocation MUST stay under 8K tokens total. Guidance:

- Input context: <= 5K tokens (story, ACs, optional architecture excerpt)
- Output: <= 3K tokens (typically 5-15 edge cases)
- If the caller supplies an input that would exceed 5K, the skill truncates the `architecture_excerpt` first, then the `story_description`, and finally caps the number of ACs considered (with a warning)
- If the generated output would exceed 3K tokens, the skill truncates the list to the highest-priority edge cases (boundary + error + security first) and logs a warning to Dev Notes: "Edge case output truncated at 3K tokens — N results dropped"

The caller is responsible for checking the total token count before persisting the output. When running inside `/gaia-create-story`, token usage is logged to Dev Notes whenever it exceeds 80% of the 8K budget.

---

<!-- SECTION: failure-handling -->
## Failure and Timeout Handling

This skill is **non-blocking**. Callers MUST treat skill failure as a warning, never as a hard error.

| Failure mode | Caller behavior |
|---|---|
| Skill file not found | Log warning "Edge case skill not loaded — continuing without edge cases", set `edge_case_results = []`, proceed |
| Skill invocation timeout (> 30s wall clock) | Log warning "Edge case analysis timed out — continuing without edge cases", set `edge_case_results = []`, proceed |
| Malformed output (missing required fields) | Log warning "Edge case output schema invalid — continuing without edge cases", set `edge_case_results = []`, proceed |
| Token budget exceeded | Truncate output with warning (see Token Budget section), still return partial results |
| Empty result (no edge cases found) | Log note "No edge cases identified for {story_key}", set `edge_case_results = []`, proceed normally — this is a valid outcome, NOT a failure |

Under no circumstance should an edge-case failure block story creation. The story is written to disk with whatever `edge_case_results` is available, plus a Dev Notes entry describing any degradation.

---

<!-- SECTION: usage-example -->
## Usage Example

Input (from `/gaia-create-story` context):

```yaml
story_key: "E19-S9"
story_title: "Edge Case Mandatory Sub-Step"
size: "M"
acceptance_criteria:
  - "Given a story of size M, when create-story runs, then edge-cases is invoked"
  - "Given the skill times out, when it fails, then story creation continues with a warning"
```

Output:

```yaml
edge_case_results:
  - id: "EC-1"
    scenario: "Story size missing from frontmatter"
    input: "size field is null or absent"
    expected: "Default to skip (treat as S), log warning"
    category: "error"
  - id: "EC-2"
    scenario: "Skill file deleted between registry load and invocation"
    input: "SKILL.md missing from plugins/gaia/skills/edge-cases/"
    expected: "Caller logs warning, sets edge_case_results=[], continues"
    category: "error"
  - id: "EC-3"
    scenario: "Input context exceeds 5K tokens"
    input: "Very large architecture_excerpt"
    expected: "Truncate architecture_excerpt first, warn, proceed"
    category: "boundary"
  - id: "EC-4"
    scenario: "Two simultaneous invocations for the same story"
    input: "Parallel runs of /gaia-create-story E19-S9"
    expected: "Each invocation is independent; no shared state"
    category: "concurrency"
```

---

<!-- SECTION: notes -->
## Notes

- The `edge_case_results` output is captured in the caller's runtime state as a named variable before the story file is written. The create-story workflow stores these results in the story's Dev Notes or Test Scenarios section.
- This skill does NOT modify files on disk. Callers persist the output.
- The skill is stack-agnostic — it works for typescript, angular, flutter, java, python, mobile, go, bash, and embedded stories.
- See also: `plugins/gaia/skills/gaia-edge-cases/SKILL.md` — the separate standalone `/gaia-edge-cases` slash-command skill (method-driven hunter). This skill (the JIT dev library) is distinct from that command-invoked skill.
- Legacy source: `_gaia/dev/skills/edge-cases.md` — retained in the running framework tree per CLAUDE.md (framework vs product separation).
