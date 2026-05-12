---
name: gaia-sprint-plan
description: "Plan a sprint by selecting stories from the backlog, applying sizing and priority rules via the sm subagent (Nate), and committing the sprint atomically to sprint-status.yaml via sprint-state.sh. GAIA-native replacement for the legacy _gaia/lifecycle/workflows/sprint-planning/ XML engine workflow."
argument-hint: "[sprint-scope]"
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Skill]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE"
```

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-plan/scripts/setup.sh

## Mission

You are planning a sprint using the Nate (Scrum Master) persona. This skill reads the backlog from `docs/planning-artifacts/epics-and-stories.md`, classifies stories by readiness, applies sizing and priority rules, and commits the finalized sprint atomically to `sprint-status.yaml` via `sprint-state.sh` (E28-S11). The skill MUST NOT write to `sprint-status.yaml` directly -- all state mutations go through `sprint-state.sh`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/sprint-planning/` XML engine workflow (brief Cluster 8, story E28-S60). It delegates planning reasoning to the `sm` subagent and uses `sprint-state.sh` for atomic state updates per ADR-042.

## How It Works

Sprint planning scans the backlog and builds a candidate set for user selection. Stories with `priority_flag: "next-sprint"` in their frontmatter are **auto-included** in the candidate set before user interaction begins (E38-S4, FR-SPQG-3). These pre-filled stories are annotated with `[priority_flag: next-sprint]` so the user can see why they were included. The user may deselect any auto-included story -- deselection preserves the flag for the next planning run. After sprint finalization, the flag is cleared (set to `null`) on all included stories; deselected flagged stories retain their flag.

The `priority_flag` field is set only by humans (via frontmatter edit in triage, correct-course, or add-feature). This skill only reads and clears the flag -- it never writes `"next-sprint"`.

## Critical Rules

- NEVER write to `sprint-status.yaml` directly. All writes MUST go through `sprint-state.sh` (E28-S11). This is the ADR-042 contract.
- Only stories with status `ready-for-dev` and an existing individual story file are selectable for a sprint.
- Dependency blocking: a story whose `depends_on` list contains any story NOT in `done` status CANNOT be included.
- Sprint commitments respect the velocity estimate from the `sizing_map` config key, resolved via `!scripts/resolve-config.sh sizing_map` (ADR-044 §10.26.3).
- Use the sm subagent (Nate) persona for planning reasoning -- do not re-implement planning logic inline.
- NEVER auto-set `priority_flag: "next-sprint"` on any story. Only humans set this flag. The skill reads and clears it only (per `feedback_priority_flag_never_auto_set`).
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, sprint-status.yaml, epics-and-stories.md, story-index.yaml, or per-epic shards under `docs/planning-artifacts/epics/` are FORBIDDEN.

## Steps

### Step 0 -- Prior-close guard (E81-S6 / FR-451)

Before sprint scoping begins, verify the previous sprint has been closed via `/gaia-sprint-close` (E81-S5). This prevents planning a new sprint while the prior sprint's `sprint-status.yaml` still shows `status: active` — which would orphan in-flight work and bypass the close ceremony.

- Resolve the previous sprint's yaml: search `docs/implementation-artifacts/sprint-archive/` for the most recent `*-closed-*.yaml`, OR check the current `docs/implementation-artifacts/sprint-status.yaml` for `status: active` (= prior sprint not yet closed).
- If `status: active` (or `status:` field absent on a non-fresh tree), refuse with `error: previous sprint {id} not closed; run /gaia-sprint-close first` and exit non-zero.
- If user passes `--allow-stale-prior`, skip the guard with a warning: `warning: proceeding despite prior sprint {id} not closed (--allow-stale-prior)`.
- If `status: closed`, proceed to Step 1.
- **Backward-compat:** if no previous sprint yaml exists (first sprint ever — fresh project), skip the guard silently.

Reference shell idiom (the SKILL.md should invoke this check via a small helper or inline grep; both are acceptable):

```bash
SS_YAML="docs/implementation-artifacts/sprint-status.yaml"
if [ -r "$SS_YAML" ]; then
  prior_status="$(grep '^status:' "$SS_YAML" | head -1 | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)"
  if [ "$prior_status" != "closed" ]; then
    prior_id="$(grep '^sprint_id:' "$SS_YAML" | head -1 | sed 's/^sprint_id:[[:space:]]*//' | tr -d '"')"
    if [ "${1:-}" != "--allow-stale-prior" ]; then
      printf 'error: previous sprint %s not closed; run /gaia-sprint-close first\n' "$prior_id" >&2
      exit 1
    fi
    printf 'warning: proceeding despite prior sprint %s not closed (--allow-stale-prior)\n' "$prior_id" >&2
  fi
fi
```

### Step 1 -- Load Epics, Stories, and Previous Retro

- Read `docs/planning-artifacts/epics-and-stories.md`.
- Parse all stories with their priorities, sizes, and dependencies.
- Resolve individual story files via the shared `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh` helper (E79-S7 / FR-476). For each story key parsed from `epics-and-stories.md`, call the helper to get the resolved path, capturing both stdout (path) and stderr (WARNINGs). The helper centralizes the E79-S4 nested-over-flat precedence rule and emits stderr `WARNING: legacy-flat path — {flat_path} (migrate via E79-S6)` for legacy-flat fallback hits, and `WARNING: legacy-flat shadow ignored — {flat_path}` when both nested and flat copies coexist (nested wins). Helper exit codes: 0 = resolved (single hit), 1 = zero matches (the story file is missing — classify as NOT SELECTABLE), 2 = multi-match ambiguity (operator must resolve). For each resolved file, read its frontmatter `status` field.
- Classify stories into selectable and non-selectable:
  - **SELECTABLE:** stories with individual files AND `status: ready-for-dev`
  - **NOT SELECTABLE (no file):** "Story {key} has no individual file -- run `/gaia-create-story {key}` first."
  - **NOT SELECTABLE (wrong status):** "Story {key} is in '{status}' status -- must be `ready-for-dev` to be selectable."
- Display the classification: selectable stories table (`Key | Title | Priority | Size | Risk | Status`) and non-selectable stories with reasons.
- **Priority-flag pre-scan (E38-S4):** run `pflag_scan_backlog` from `${CLAUDE_PLUGIN_ROOT}/scripts/priority-flag.sh` against `docs/implementation-artifacts/`. This returns all story keys whose frontmatter has `status: backlog` AND `priority_flag: "next-sprint"`. Display these as a separate section: "Auto-included by priority_flag: [list of keys]". These stories are pre-filled into the candidate set in Step 3 before user selection. If no flagged stories are found, display "priority_flag: no flagged backlog stories found" and proceed normally.
- Load most recent `retro-{sprint_id}.md` from `docs/implementation-artifacts/` if available. If retro found: extract open action items and present them as sprint constraints.

### Step 1.5 -- Action-Item Escalation Halt (E38-S2, FR-SPQG-1)

Before proceeding to sprint scoping, halt if any HIGH-priority action item has been open for two or more sprints (`escalation_count >= 2`). This forces systemic issues to resolution -- or conscious override -- before new sprint commitments are made.

**Invocation:**

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/escalation-halt.sh  # library-only; source + call
bash -c "source ${CLAUDE_PLUGIN_ROOT}/scripts/escalation-halt.sh && \
  esch_check_blocking \
    '${CLAUDE_PROJECT_ROOT}/docs/planning-artifacts/action-items.yaml' \
    '${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/sprint-status.yaml'"
```

**Contract:**

- Reads `docs/planning-artifacts/action-items.yaml` (schema owned by E36-S2 / FR-RIM-5).
- Filter predicate: `priority == "HIGH"` AND `escalation_count >= 2` AND `status == "open"` (case-sensitive).
- **Exit 0 (proceed):** no matching items, OR all matching items have a recorded override in the current `sprint-status.yaml`.
- **Exit 1 (halt):** one or more matching items with no recorded override. Halt message on stdout lists each blocking item (`id`, `title`, `escalation_count`, `priority: HIGH`) followed by exit guidance pointing to `/gaia-action-items` or the explicit override flag. No `sprint-status.yaml` mutation and no story-selection prompt occur when the halt fires.

**Missing-file fallback (AC4):** If `action-items.yaml` is absent, empty, or contains zero action items, emit a single-line stderr warning (`NOTE: action-items.yaml not found at ... — escalation halt skipped`) and proceed. The file is NOT created here -- creation is owned by E36-S2 / FR-FITP-3 writers.

**Override path (AC3):** If the user re-invokes `/gaia-sprint-plan` with the explicit override, record it via `sprint-state.sh` and proceed:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh record-escalation-override \
  --item-ids "AI-42,AI-77" \
  --user "$(git config user.name || printf alice)" \
  --reason "Acknowledged during sprint planning — owner committed to resolution this sprint"
```

Override metadata schema (appended under `overrides:` in `sprint-status.yaml`):

```yaml
overrides:
  - date: "2026-04-22"
    user: "alice"
    override_type: escalation_halt
    overridden_item_ids:
      - "AI-42"
      - "AI-77"
    reason: "Acknowledged during sprint planning"
```

The override is **idempotent** on the dedup key `(sprint_id, sorted-unique(overridden_item_ids), override_type)` -- re-running with the same still-open items and a prior recorded override does NOT re-halt and does NOT append a duplicate entry.

**Rollback toggle:** set `GAIA_ESCALATION_HALT=off` in the environment to bypass the halt entirely (for emergency rollout if a schema regression in `action-items.yaml` appears). Default: enabled.

**Cross-refs:**

- **FR-SPQG-1** -- this step implements the halt gate.
- **FR-FITP-3** (Epic F) / **E36-S2** -- upstream writers of `action-items.yaml` (`/gaia-retro`, `/gaia-correct-course`, `/gaia-triage-findings`).
- **ADR-042** -- all `sprint-status.yaml` writes (including override recording) go through `sprint-state.sh`; this skill never writes yaml inline.
- **ADR-055** (§10.29.4) -- if E38-S1 has landed, reconciliation runs before this halt; if not, the halt still functions because it reads `action-items.yaml`, not `sprint-status.yaml`.

### Step 2 -- Sprint Scoping

- Ask: Sprint duration (1 week / 2 weeks / custom)?
- Ask: Team velocity estimate (story points)?
- Ask: Sprint number (for multi-sprint tracking)?
- Resolve the `sizing_map` key via `!scripts/resolve-config.sh sizing_map` (ADR-044 §10.26.3 — the resolver transparently merges the team-shared and machine-local layers, applying the "local overrides shared" precedence). Display the canonical point values (S/M/L/XL) before selection. <!-- Shared layer: config/project-config.yaml. Local layer: global.yaml. -->

### Step 3 -- Story Selection

- Select stories for this sprint based on priority ordering (P0 > P1 > P2) and dependency topology -- only from stories classified as SELECTABLE in Step 1.
- **Priority-flag pre-fill (E38-S4):** any story keys returned by the priority-flag pre-scan in Step 1 are pre-selected in the candidate set before user interaction. Annotate each auto-included entry with `[priority_flag: next-sprint]` so the user sees why it was pre-filled. The user may deselect any pre-filled story -- deselection preserves the flag for the next planning run (AC2).
- Ensure total size fits within velocity estimate using `sizing_map` point values.
- **Dependency blocking:** for each candidate, check its `depends_on` list. If any dependency is NOT `done`, the story CANNOT be included. Display: "BLOCKED: Story {key} depends on {dep_key} (status: {dep_status})."
- **Priority surfacing:** after selection, check for P0 stories that are `ready-for-dev` but NOT selected. If any found, warn: "WARNING: P0 stories ready but not selected:" and ask user to confirm the exclusion.
- If `docs/test-artifacts/test-plan.md` exists: apply risk levels -- buffer 20% for high-risk stories.
- **ATDD check (high-risk only):** for each high-risk story, check if `docs/test-artifacts/atdd-{story_key}.md` exists. If missing: "HIGH-RISK story {key} has no ATDD file -- run `/gaia-atdd {key}` before development."
- Present the candidate sprint to the user and capture confirmation.

### Step 4 -- Update Story Files

- For each selected story with an individual file: update the `sprint_id` field to `sprint-{N}`.
- Stories remain `ready-for-dev` -- do NOT change their status. `/gaia-dev-story` transitions them to `in-progress` when work begins.

### Step 5 -- Sprint Plan Generation

- Create the sprint plan with story assignments and execution order, ordered by dependency resolution + priority.
- Generate a Sprint Burndown Estimate table: `Day | Points Remaining | Stories Completing`.
- Include: sprint goals, selected stories (ordered), velocity target, risk assessment, and a Testing Readiness section listing ONLY high-risk stories with their ATDD file status.

### Step 6 -- Commit Sprint via sprint-state.sh

- Generate `sprint-status.yaml` content with the standardized schema:
  ```yaml
  sprint_id: "sprint-{N}"
  duration: "{duration}"
  velocity_capacity: {velocity}
  total_points: {sum}
  started: "{date}"
  end_date: "{end_date}"
  stories:
    - key: "{story-key}"
      title: "{title}"
      status: "ready-for-dev"
      points: {points}
      risk_level: "{risk}"
      assignee: null
      blocked_by: null
      updated: "{date}"
  ```
- Write `sprint-status.yaml` to `docs/implementation-artifacts/sprint-status.yaml` EXCLUSIVELY via `sprint-state.sh`:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh inject \
    --story "{story_key}" [--sprint-id "{sprint_id}"]
  ```
  Invoke once per selected story to register it in the sprint. The `inject` subcommand (E38-S10, ADR-055 §10.29) appends the story's metadata mirrored from the story file's frontmatter — the four required fields (`sprint_id`, `status`, `points`, `risk`) MUST be present in the story file before the call. `inject` is idempotent — re-running on an already-registered key is a no-op. Use `transition` only for in-sprint status changes after the entry exists. If `sprint-state.sh` exits non-zero, abort cleanly and surface the error to the user. Do NOT fall back to direct YAML writes.

### Step 6b -- Dependency Inversion Lint (E38-S3, ADR-055 §10.29.2)

- After committing the sprint, run the dependency inversion lint to detect forward-references in the selected story order:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh lint-dependencies --format json
  ```
- The lint is **read-only** and never mutates any file. It analyzes the ordered story list in `sprint-status.yaml` and each story file's `depends_on` frontmatter and AC text.
- **Detection sources:**
  - **Explicit** (high confidence): `depends_on` frontmatter field referencing a story that appears later in sprint order.
  - **Heuristic** (advisory): AC text containing trigger verbs (`uses`, `consumes`, `reads from`) co-occurring with a sprint story key within an 80-character window.
- **Exit code interpretation:**
  - `0` — clean, no inversions. Proceed to Step 7.
  - `2` — inversions detected (advisory). Present the findings table and offer choices.
  - `1` — error (missing story file, parse failure). Surface the error and halt.
- **If inversions detected (exit 2):** present a table to the user showing each inversion (dependent, dependency, source, confidence, suggested reorder). Offer two choices:
  - **Accept reorder (AC3):** apply the suggested reorder — move the dependency story before the dependent story in `sprint-status.yaml`. Other positions remain stable. No override entry is recorded. Re-run the lint after reorder to confirm clean.
  - **Override and keep original order (AC4):** record an `overrides` entry in sprint metadata with the date, user, and specific inversion pair(s) acknowledged. Format:
    ```yaml
    overrides:
      - date: "{date}"
        user: "{user_name}"
        inversions:
          - dependent: "{story_key}"
            dependency: "{dep_key}"
        reason: "Acknowledged by user during sprint planning"
    ```
    Proceed to Step 6c with the original order preserved.

### Step 6c -- Priority-Flag Clear (E38-S4, FR-SPQG-3)

- After sprint finalization (sprint-status.yaml committed), iterate the set of stories that landed in the sprint.
- For each included story, use `pflag_read` from `${CLAUDE_PLUGIN_ROOT}/scripts/priority-flag.sh` to check if `priority_flag` is `"next-sprint"`.
- For each included story with `priority_flag: "next-sprint"`, call `pflag_clear` to rewrite the frontmatter to `priority_flag: null`. This is a line-targeted rewrite that preserves all other frontmatter fields byte-for-byte.
- **Deselection preservation (AC2):** stories that were flagged but deselected (excluded from the sprint) are NOT cleared. Their `priority_flag: "next-sprint"` persists so the next planning run auto-includes them again.
- **Failure isolation:** if `pflag_clear` fails on one story (permission error, malformed frontmatter), log a warning and continue clearing the remaining stories. Do NOT abort the sprint-plan run.
- After all clears, call `pflag_record_cleared` from the same script to append a `priority_flag_cleared:` block to `sprint-status.yaml` listing the cleared story keys. If no stories were cleared, record an empty array.
- Emit a summary line: `"priority_flag cleared on {N} included stories; {M} deselected flagged stories retained their flag."`

### Step 7 -- Save Sprint Plan Document

- Write the sprint plan document to `docs/implementation-artifacts/{sprint_id}-plan.md`.
- The document includes all sections from Step 5.

### Step 8 -- Val Validation (optional)

- If the Val subagent is available: invoke Val to validate the sprint plan. Val verifies:
  - All selected story keys exist as story files with status `ready-for-dev`
  - Dependency ordering is correct
  - Points math is correct (total <= velocity)
  - No duplicate story keys
- If Val returns findings: auto-fix and re-validate.
- If Val fails or is unavailable: log warning and continue -- validation is non-blocking for sprint planning.

### Step 9 -- NFR-048 Token Footprint Measurement

- Record the skill's token footprint for NFR-048 tracking. This measurement becomes input to the aggregate reporting under E28-S65.
- Log: skill name, step count, approximate token usage vs. the legacy XML engine invocation.

### Step 10 -- Report

- Display the finalized sprint summary: sprint ID, duration, velocity, stories selected, total points, capacity utilization.
- Suggest next step: `/gaia-dev-story {first_story_key}` to begin the first story.

### Step 11 — Persist to Val Sidecar (E34-S2)

Final step. Delegates Val-decision persistence to the shared Val sidecar writer helper (`val-sidecar-write.sh`, E34-S1, architecture §10.10). Placing this last satisfies AC3 atomicity — any upstream failure (sprint-state transition, dependency-inversion lint error, Val validation failure in Step 8) short-circuits before the helper runs, so no partial sidecar entry can appear.

Read `sprint_id` via the shared `sprint-state.sh` foundation script — never parse `sprint-status.yaml` directly (project hard rule):

```bash
sprint_id="$(${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh current-sprint --field sprint_id 2>/dev/null || echo 'N/A')"
```

Build the decision payload as `{verdict, findings[], artifact_path}` using the Step 8 Val verdict (or `verdict: "skipped"` if Val was unavailable) and the sprint-plan artifact path from Step 7.

Invoke the helper:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/val-sidecar-write.sh \
  --command-name "/gaia-sprint-plan" \
  --input-id     "${sprint_id}" \
  --sprint-id    "${sprint_id}" \
  --decision-payload "$(jq -cn \
    --arg verdict       "${verdict:-skipped}" \
    --arg artifact_path "docs/implementation-artifacts/${sprint_id}-plan.md" \
    --argjson findings  "${findings_json:-[]}" \
    '{verdict: $verdict, findings: $findings, artifact_path: $artifact_path}')"
```

The helper enforces the two-file allowlist (NFR-VSP-2) and idempotency by composite `(command_name, input_id, decision_hash)` key (FR-VSP-2) — re-runs with identical payload yield `status=skipped_duplicate` and must be treated as success.

Failure posture: if the helper rejects or errors, log a warning and continue — memory persistence is best-effort and MUST NOT fail the skill.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-plan/scripts/finalize.sh
