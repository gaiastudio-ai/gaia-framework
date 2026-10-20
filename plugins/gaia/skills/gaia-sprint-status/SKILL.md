---
name: gaia-sprint-status
description: "Display the current sprint status dashboard. Delegates rendering to the sprint-status-dashboard.sh formatter script, which reads the sprint-progress cache (with a fallback to sprint-status.yaml) and produces a deterministic plain-text dashboard with Tasks, Gates, phase grouping, and a warning header."
allowed-tools: [Bash, Read]
version: "1.1.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-status/scripts/setup.sh

## Mission

Display the current sprint status by invoking the deterministic `sprint-status-dashboard.sh` formatter script. This skill is read-only with respect to `sprint-status.yaml` — it NEVER writes to or modifies the sprint status file under any code path, per CLAUDE.md Sprint-Status Write Safety.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/sprint-status/` XML engine workflow. Nearly all work is delegated to the bash formatter script (scripts-over-LLM).

## Critical Rules

- This skill is strictly read-only with respect to story files — NEVER modifies frontmatter or body content.
- The skill MAY write to `sprint-status.yaml` but only indirectly through the `sprint-state.sh reconcile` call in Step 2. Reconcile is the single authorized writer, and its edits are always derivative corrections pulled from authoritative story-file frontmatter.
- All dashboard rendering is performed by `sprint-status-dashboard.sh` — do NOT implement formatting logic in the LLM layer.
- If the formatter script exits non-zero, surface the error message to the user and stop. Do NOT attempt to render the dashboard manually.

## Steps

### Step 0 — Resolve Sprint Argument

When the user passes `--sprint <sprint-id>`, forward it to the dashboard script. Without `--sprint`, call the dashboard's no-argument mode -- do NOT default to the bound sprint and do NOT refuse. Overview rendering and bound-sprint highlighting are handled by the dashboard itself.

### Step 1 — Run Dashboard Formatter

Run the sprint-status-dashboard.sh formatter script. When `--sprint` was provided, pass it through:

```bash
# Without --sprint (no-argument mode):
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-status-dashboard.sh"
# With --sprint <sprint-id>:
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-status-dashboard.sh" --sprint "<sprint-id>"
```

The formatter uses a cache-first data model: it reads from the sprint-progress cache and renders an enhanced table with Tasks and Gates columns, phase grouping, and a warning header. When the cache is unavailable (jq absent, cache missing, snapshot failure), it falls back to the original four-column table from sprint-status.yaml.

If the script exits 0, present its stdout output to the user verbatim — do not reformat, filter, or enhance the dashboard output. The script produces the canonical dashboard rendering. When the current sprint contains at least one story with a high risk level (read from the cache `stories[].risk_level` field on the cache path, or from story-file frontmatter `risk:` on the fallback path), the dashboard appends a "Recommended mitigations for HIGH-risk stories" block listing every entry from the bundled mitigation catalog.

When no active sprint exists (cache reports the sprint as null or closed), the script prints "No active sprint" and exits 0. The stranded-ready advisory still runs independently after this line. This is not an error — suggest `/gaia-sprint-plan` to create a new sprint.

If the script exits non-zero, display the error output and inform the user:
- Exit 1 with "not found": `sprint-status.yaml` does not exist (fallback path only). Suggest running `/gaia-sprint-plan` first.
- Exit 1 with "malformed": the YAML file is corrupt. Suggest running `/gaia-sprint-status` after fixing the file.

### Step 2 — Reconcile Sprint Status (Post-Dashboard)

After the dashboard renders successfully, invoke `sprint-state.sh reconcile` to detect and auto-correct drift between authoritative story-file frontmatter and the derivative `sprint-status.yaml` cache.

```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" reconcile --sprint-id "${sprint_id}"
```

When `--sprint` was not provided, pass the session-bound sprint id (read from the binding file or the active sprint). When no sprint is identifiable, omit `--sprint-id` — reconcile defaults to the single-sprint file.

Invocation order rationale: reconcile runs AFTER the dashboard so the user always sees the current (possibly drifted) view first, then receives an auditable summary of any corrections applied. This ordering makes drift visible rather than silently masked.

Surface the reconcile output verbatim to the user — do NOT swallow errors or filter the per-story `RECONCILE:` lines and the trailing `RECONCILE SUMMARY:` line. Exit-code handling:

- Exit 0: either no drift was detected (ideal steady state) or drift was auto-corrected. Mention the summary line to the user so they know which stories were updated.
- Exit 1: reconcile encountered an error (missing story file, malformed frontmatter, write failure, read-only yaml). Do NOT suppress this — surface the error so the user can investigate. The dashboard has already rendered, so the workflow can complete even if reconcile surfaces an error.
- Exit 2: only returned when reconcile is invoked with `--dry-run` (this skill never uses dry-run). If seen, treat as a bug.

Feature-flag escape hatch: a future rollout toggle may gate this call. If `GAIA_DISABLE_RECONCILE=1` is set in the environment, skip Step 2 entirely so a frontmatter-parse regression can be isolated without reverting the wiring.

### Sprint auto-close detection

On the cache path, the dashboard renders an advisory banner when `readiness.sprint_close` is true in the cache and the rule-d entry is present in `action_needed[]`. The banner uses `totals.done_stories`, `totals.total_stories`, and `sprint.end_date` from the cache — no call to `sprint-state.sh detect-auto-close` is made on the cache path.

On the fallback path (no cache), detection is delegated to `sprint-state.sh detect-auto-close` (single-line JSON contract on stdout, empty when the condition is not met, always exits 0) so other consumers (`/gaia-retro`, `/gaia-sprint-plan`) can reuse the same probe.

**Subcommand contract (fallback path only):**

```bash
PROJECT_PATH="${CLAUDE_PROJECT_ROOT}" "${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh" detect-auto-close
# stdout when triggered (single line):
# {"sprint_id":"sprint-N","done":3,"total":3,"status":"active","end_date":"2026-05-14"}
# stdout when not triggered: empty
# exit code: 0 (always — advisory, never blocking)
```

**Advisory-only — never mutates `sprint-status.yaml`.** The detect path is strictly read-only. The boundary write (flipping `status: closed` and seeding the next sprint) remains a manual operator action — `sprint-state.sh` rejects self-transitions and cannot seed new sprints per `.gaia/memory/feedback_sprint_boundary_yaml_write.md`. Auto-flipping would create false confidence that the next sprint had also been scaffolded. The right ergonomic improvement is **signal, not action**.

### Stranded ready stories

The dashboard appends a `Stranded ready stories` section below the active-sprint table when one or more story files match ALL of the following criteria:

- `status: ready-for-dev` in story-file frontmatter, AND
- `sprint_id: null` in story-file frontmatter, AND
- the MOST-RECENT entry for the story key in `.gaia/memory/validator-sidecar/decision-log.md` resolves to `PASSED`.

The verdict lookup is a union over three heading patterns:

- `### [DATE] Story Validation: <key>` (written by `/gaia-validate-story`)
- `### [DATE] Story Validation (re-run): <key>` (re-runs of the same)
- `### [DATE] /gaia-<command>: <key>` (e.g., `/gaia-create-story` via `val-sidecar-write.sh`)

Verdict body recognition: JSON-style `verdict":"PASSED"` (canonical, written by `val-sidecar-write.sh`), prose `verdict: PASSED`, or the legacy `**Status:** recorded` convention. FAILED or UNVERIFIED entries dominate within a block; stories whose most-recent entry is FAILED or UNVERIFIED are excluded from the section.

**Recency rule.** The decision log appends newest entries AT THE TOP, so the first matching heading in document order is the most-recent. A story whose log has an older PASSED followed by a newer FAILED is EXCLUDED — recency wins.

**Read-only invariant.** The detection path is strictly read-only: no story file, no `sprint-status.yaml` entry, and no `priority_flag` is mutated. Per `feedback_priority_flag_never_auto_set.md`, the framework never auto-injects stranded stories into the active sprint and never sets `priority_flag: "next-sprint"`. The dashboard signal alone is the ergonomic improvement — the operator decides.

**Suppression.** If no story matches the criteria, the entire section (header + hint line) is suppressed — no empty-list placeholder is rendered.

**Operator's decision path.**

- To inject a stranded story into the active sprint immediately, run `/gaia-correct-course` (operator-driven sprint scope change).
- To let the next sprint pick it up, take no action — `/gaia-sprint-plan` will see the story in the backlog candidates and decide sequencing.

The hint line printed below the stranded list spells out both paths verbatim so the operator can copy the slash command.

### Step 3 — Suggest Next Actions

Based on the dashboard output, suggest relevant next actions:

- If stories are in `ready-for-dev`: suggest `/gaia-dev-story {story_key}` for the highest-priority story.
- If stories are in `review`: suggest `/gaia-run-all-reviews {story_key}` for stories awaiting review.
- If stories are `blocked`: note the blocking dependency.
- If all stories are `done`: suggest `/gaia-retro` for a sprint retrospective.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-status/scripts/finalize.sh
