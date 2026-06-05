---
name: gaia-memory-management-cross-agent
description: Cross-agent memory extensions — cross-reference loading and shared budget monitoring. Split from memory-management to keep each skill under the 300-line limit. Companion to gaia-memory-management.
version: '1.0'
applicable_agents: [all]
sections: [cross-reference-loading, budget-monitoring]
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

<!-- Converted under the Native Execution Model. Source: _gaia/lifecycle/skills/memory-management-cross-agent.md. -->

## Mission

Provide the cross-agent memory operations that do not fit inside `gaia-memory-management` under the 300-line skill limit:

1. **Cross-reference loading** — read-only JIT access to another agent's sidecar (e.g., Val reading Theo's `decision-log.md`). Governed by the agent's `<memory-reads>` block and the `cross_references` matrix in `.gaia/memory/config.yaml`.
2. **Budget monitoring** — shared utility returning threshold status (`ok`, `warn`, `alert`, `archive_needed`, `no_budget`) used by session-save and any other memory-writing operation.

> **Companion skill:** this skill is paired with `gaia-memory-management`. Callers that need `session-load`, `session-save`, `decision-formatting`, `context-summarization`, `stale-detection`, or `deduplication` should load those sections from the companion instead. The two skills split the memory-management body only because of the 300-line skill limit — their section IDs are unique across both files and callers reference them by name, not by file.

## Critical Rules

- **Read-only cross-references.** `load_cross_ref()` MUST NEVER write. Any attempted write to a sidecar other than the current agent's own sidecar is a hard error.
- **Self-reference is invalid.** An agent declaring a `<cross-ref>` pointing at its own sidecar is a session-start validation error — not a warning.
- **JIT only.** Cross-references are loaded during workflow step execution, never at agent activation or session start.
- **Progressive downgrade is deterministic.** When budget is insufficient: `full` → `recent` → `summary` → `skip`. Every downgrade is logged to the session checkpoint.
- **Failures are soft.** Missing, empty, or malformed cross-reference targets produce a warning and continue execution — they NEVER halt a workflow.
- **Budget thresholds come from config.** Read `.gaia/memory/config.yaml` `archival` block at runtime. Never hardcode `budget_warn_at`, `budget_alert_at`, `budget_archive_at`, `token_approximation`, or `archive_subdir`.

<!-- SECTION: cross-reference-loading -->
## Cross-Reference Loading

Load another agent's sidecar files as read-only cross-references. All cross-ref loading is JIT (just-in-time) — never preloaded at session start.

### Schema: `<memory-reads>` Tag

Agent persona files declare cross-references using this XML schema inside the `<agent>` block:

```xml
<memory-reads>
  <cross-ref agent="{agent-id}" file="{file-name}" mode="{recent|full|summary}" required="{true|false}" />
</memory-reads>
```

**Attributes:**
- `agent` (required) — the agent ID whose sidecar to read (e.g., "architect", "validator")
- `file` (required) — the sidecar file to read (e.g., "decision-log", "ground-truth", "conversation-context")
- `mode` (required) — loading mode: `recent`, `full`, or `summary`
- `required` (optional, default: "true") — if "false", skip gracefully when the sidecar is absent

### Read-Only Access: `load_cross_ref()`

Cross-references are loaded through `load_cross_ref()`, which is a **read-only** path — separate from `load_own()` (the agent's own sidecar, which supports read/write).

**Parameters:**
- `sidecar_path` — absolute path to the **target** agent's sidecar directory (e.g., `.gaia/memory/architect-sidecar/`)
- `file_name` — which file to read (e.g., "decision-log.md", "ground-truth.md")
- `mode` — loading mode: `recent`, `full`, or `summary`
- `budget_remaining` — remaining token budget for cross-references

**Write-Guard:**
Any attempt to write to a sidecar that is not the current agent's own sidecar MUST raise a **hard error** (not a warning). The write-guard blocks all write operations through `load_cross_ref()`. Only `load_own()` permits writes, and only to the agent's own sidecar directory.

**Procedure:**
1. Validate the target sidecar path is NOT the current agent's own sidecar (self-reference guard)
2. Check budget_remaining BEFORE loading — if insufficient, apply progressive downgrade
3. Read the target file from disk (read-only — no file creation, no modification)
4. Apply mode filtering (see Loading Modes below)
5. Calculate token estimate: character count / 4 (using `token_approximation` from `.gaia/memory/config.yaml`)
6. Return filtered content as read-only data with token estimate for caller budget deduction

### Loading Modes

**`recent` mode** — Load entries from the last 2 sprints only:
- Parse decision-log entries using the canonical decision-log format
- Filter by Sprint field: keep entries where sprint matches current sprint or previous sprint
- If sprint metadata is absent from entries, fall back to date-based filtering (last 30 days)
- Approximate token cost: character count / 4

**`full` mode** — Load the entire file content:
- Read full file, respect budget cap
- If file exceeds budget_remaining: truncate oldest entries first (keep most recent)
- Approximate token cost: character count / 4

**`summary` mode** — Load section headers only:
- Parse the file for markdown headers (lines starting with `#`, `##`, `###`)
- Stop at section boundaries — do not load body content
- Minimal token cost

### JIT Loading

Cross-references are loaded **just-in-time** during workflow step execution — NOT at agent activation or session start. Loading is triggered only when a workflow step explicitly requires cross-agent context.

**Trigger:** The workflow engine checks `<memory-reads>` declarations and loads cross-references only when the current step's execution context requires cross-agent data. No cross-references are preloaded eagerly.

### Budget Enforcement

**Pre-load budget check:** Before each cross-reference load, calculate:
- Tokens already consumed by own sidecar
- Tokens already consumed by previously loaded cross-references
- Estimated tokens for the next cross-reference (based on mode and file size)

**Per-agent `cross_ref_budget_cap`:** Some agents have a `cross_ref_budget_cap` in `.gaia/memory/config.yaml` (e.g., validator: 0.5). This caps cross-reference token consumption at that fraction of the agent's session budget. If loading would exceed the cap, halt loading and downgrade remaining cross-refs progressively.

**Progressive downgrade chain:** When budget is insufficient for the requested mode:
1. `full` → downgrade to `recent`
2. `recent` → downgrade to `summary`
3. `summary` → downgrade to `skip` (do not load, log warning)

Log every downgrade as a warning in the session checkpoint:
`"Cross-ref downgraded: {agent}/{file} from {original_mode} to {new_mode} — budget {used}/{total}"`

**Val's 50% cross-ref budget cap:**
Val (validator) has a `cross_ref_budget_cap` of 0.5 in `.gaia/memory/config.yaml`, meaning cross-references may consume at most 50% of Val's 300K session budget (= 150K tokens max for cross-refs). Val's load priority order: architect, pm, sm. If the 150K cap is hit mid-load, remaining cross-references are downgraded progressively.

**Tier budget ceilings:**
- Tier 1 agents: 300K session budget (own sidecar + cross-refs combined)
- Tier 2 agents: 100K session budget (own sidecar + cross-refs combined)
- Tier 3 agents: no explicit budget enforcement

### Graceful Error Handling

**Missing sidecar directory or file:**
- If the target sidecar directory does not exist: log a warning ("Cross-ref skipped: {agent} sidecar directory not found"), skip this cross-reference, and continue workflow execution without error
- If the target file within the sidecar does not exist: log a warning ("Cross-ref skipped: {agent}/{file} not found"), skip, continue

**Empty sidecar directory:**
- If the target sidecar directory exists but contains no files: return empty result gracefully with no error — matching the contract of the `session-load` section

**Malformed or corrupt sidecar files:**
- If the target file exists but cannot be parsed (malformed markdown, corrupt content, unparseable entries): log a warning ("Cross-ref skipped: {agent}/{file} is malformed"), skip this cross-reference, and continue
- Never halt the workflow due to a cross-reference loading failure

**Absent optional cross-references:**
- If `<cross-ref required="false">` and the target is absent: skip silently (no warning)
- If `<cross-ref required="true">` (default) and the target is absent: log warning but still continue

**Agent not in cross-reference matrix:**
- If the calling agent has no entry in `.gaia/memory/config.yaml` `cross_references`, return empty result with no error

### Consistency Validation

At session start, validate that agent persona `<memory-reads>` declarations are consistent with `.gaia/memory/config.yaml` cross_references matrix:

1. Parse the agent's `<memory-reads>` block from the persona file
2. Load the agent's entry from `.gaia/memory/config.yaml` → `cross_references.{agent_id}.reads_from`
3. Compare: every entry in config.yaml should have a matching `<cross-ref>` in the persona file
4. If mismatch found: produce a **warning** (not an error) — `.gaia/memory/config.yaml` is the authoritative source

**Self-reference guard:**
If an agent's `<memory-reads>` declares a `<cross-ref>` where the `agent` attribute matches the current agent's own ID, reject it with a validation error at session start. An agent must not reference its own sidecar as a cross-reference — own-sidecar access is through `load_own()`.

### Checkpoint Provenance

After loading cross-references, record in the session checkpoint:
- Which cross-references were loaded (agent, file, mode)
- File checksums (`shasum -a 256`) of each loaded cross-reference file
- Any downgrades or skips that occurred
- Total tokens consumed by cross-references

This enables `/gaia-resume` to detect stale cross-references when resuming a session.
<!-- END SECTION -->

<!-- SECTION: budget-monitoring -->
## Budget Monitoring

Shared utility for checking token budget usage against tier-defined thresholds. Used by `session-save` and other memory operations to determine when archival is needed.

### Parameters

- `sidecar_path` — absolute path to the agent's sidecar directory
- `tier_budget` — session token budget for this agent's tier (from `.gaia/memory/config.yaml`). If null or absent, the agent is untiered.
- `current_usage` — current token count (own sidecar files + cross-refs loaded in this session)
- `projected_addition` — token count of content about to be written/loaded

### Threshold Definitions (config-driven)

All thresholds are read from `.gaia/memory/config.yaml` `archival` block at runtime. Never hardcode these values.

- `budget_warn_at` — fraction of budget at which a warning is returned (e.g., 0.8 = 80%)
- `budget_alert_at` — fraction of budget at which an alert is returned (e.g., 0.9 = 90%)
- `budget_archive_at` — fraction of budget at which archival is triggered (e.g., 1.0 = 100%)
- `token_approximation` — characters per token for size estimation (e.g., 4)
- `archive_subdir` — subdirectory name within sidecar for archived entries (e.g., "archive")

### Procedure

1. Read `.gaia/memory/config.yaml` archival block to get threshold values
2. Calculate `projected_total = current_usage + projected_addition`
3. Calculate `usage_ratio = projected_total / tier_budget`
4. Return threshold status:
   - `usage_ratio < budget_warn_at` → status: `ok` (no action needed)
   - `usage_ratio >= budget_warn_at AND < budget_alert_at` → status: `warn` ("approaching budget limit")
   - `usage_ratio >= budget_alert_at AND < budget_archive_at` → status: `alert` ("near budget limit")
   - `usage_ratio >= budget_archive_at` → status: `archive_needed` ("budget exceeded, archival required")

### Archival Protocol

When status is `archive_needed`:
1. Identify the oldest N entries in `decision-log.md` that would free sufficient tokens
2. Move those entries to `{sidecar_path}/{archive_subdir}/` (e.g., `.gaia/memory/architect-sidecar/archive/`)
3. Create the archive subdirectory if it does not exist (`mkdir -p`)
4. Use atomic read-modify-write pattern: read full file, remove archived entries, write full file back
5. Re-check budget after archival — if still over budget, archive more entries (up to 3 iterations)
6. Archive subdirectory is gitignored — archived entries are historical, not version-controlled

### Token Estimation

Token count is approximated using the `token_approximation` value from `.gaia/memory/config.yaml` (default: 4 chars per token). No tokenizer library is used — this aligns with the zero-runtime-dependencies principle.

Formula: `tokens = character_count / token_approximation`

### Running Session Total

Track cumulative token usage across the session:
- Own sidecar files loaded via `session-load`
- Cross-references loaded via `cross-reference-loading`
- New entries being written via `session-save`

The combined total is checked against the tier budget ceiling.

### Untiered Agent Handling

If `tier_budget` is null, absent, or the agent has no tier assignment in `.gaia/memory/config.yaml` (applies to 9 untiered agents: analyst, data-engineer, performance, ux-designer, brainstorming-coach, design-thinking-coach, innovation-strategist, presentation-designer, problem-solver):
- Skip all budget enforcement — no threshold checks, no archival trigger
- Return status: `no_budget` with no error
- This is a no-op: the caller proceeds without any budget constraint
- Never raise an error for untiered agents

### Return Value

```yaml
status: ok | warn | alert | archive_needed | no_budget
usage_ratio: 0.75          # current usage as fraction of budget (null if no_budget)
tokens_used: 225000        # current token count (null if no_budget)
tokens_budget: 300000      # tier budget ceiling (null if no_budget)
tokens_projected: 230000   # projected total after addition (null if no_budget)
message: "Budget at 75% — no action needed"
```
<!-- END SECTION -->
