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
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-plan/scripts/setup.sh

## Mission

You are planning a sprint using the Nate (Scrum Master) persona. This skill reads the backlog from `.gaia/artifacts/planning-artifacts/epics-and-stories.md`, classifies stories by readiness, applies sizing and priority rules, and commits the finalized sprint atomically to `sprint-status.yaml` via `sprint-state.sh` (E28-S11). The skill MUST NOT write to `sprint-status.yaml` directly -- all state mutations go through `sprint-state.sh`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/sprint-planning/` XML engine workflow (brief Cluster 8, story E28-S60). It delegates planning reasoning to the `sm` subagent and uses `sprint-state.sh` for atomic state updates per ADR-042.

## How It Works

Sprint planning scans the backlog and builds a candidate set for user selection. Stories with `priority_flag: "next-sprint"` in their frontmatter are **auto-included** in the candidate set before user interaction begins (E38-S4, FR-SPQG-3). These pre-filled stories are annotated with `[priority_flag: next-sprint]` so the user can see why they were included. The user may deselect any auto-included story -- deselection preserves the flag for the next planning run. After sprint finalization, the flag is cleared (set to `null`) on all included stories; deselected flagged stories retain their flag.

The `priority_flag` field is set only by humans (via frontmatter edit in triage, correct-course, or add-feature). This skill only reads and clears the flag -- it never writes `"next-sprint"`.

## Critical Rules

- NEVER write to `sprint-status.yaml` directly. All writes MUST go through `sprint-state.sh` (E28-S11). This is the ADR-042 contract.
- **Backlog selection from epics-and-stories.md (E107-S2 / ADR-128, FR-558).** Stories are selectable directly from the BACKLOG — the epics-and-stories.md roster columns — WITHOUT requiring a pre-materialized `ready-for-dev` story file. This inverts the prior "ready-for-dev + existing file" precondition that caused the Test02 F-9 silent-bypass (a planner had to run `/gaia-create-story` 40 times before sprint-plan would touch the stories). The dependency lint and capacity assessment read from the roster columns (`Depends on` / `Blocks` / `Size` / `Points` / `Risk`), not story files. JIT materialization of the selected stories happens after planning (E107-S3, `/gaia-create-story --for-sprint`). When a project DOES have materialized `ready-for-dev` files, they remain selectable too (backward-compat): `resolve-story-file.sh` resolution is still reachable for the files-present path.
- **Column-sourced dependency lint (E107-S2).** Run `${CLAUDE_PLUGIN_ROOT}/scripts/backlog-select-lint.sh --epics <epics-and-stories.md> --candidates "<co-selected keys>" --done "<done keys>"` to validate the candidate set's dependencies from the roster `Depends on` column. A candidate HARD-BLOCKS when a hard-dep target is neither `done` nor co-selected in this sprint (cross-sprint dependency hard-block, AC3); soft-deps (`; soft on …`) and parenthetical annotations never block. The caller derives `--done` from closed-sprint history (sprint-archive yamls / epic-block status) and `--candidates` from the selection set — the lint is pure and reads only the columns. Capacity uses E106-S3's agent-native check (`sm-capacity-check.sh`: depth + coherence + telemetry-gated wall-clock), NOT the points-vs-velocity heuristic.
- **Commit as `planned` (E107-S1).** A finalized selection is committed as a `status: planned` sprint via `sprint-state.sh` (init seeds `planned`; E107-S4 layers the planned→active readiness gate) — NOT `active`. The legacy `total_points <= velocity` gate is no longer the capacity criterion.
- Sprint commitments respect the velocity estimate from the `sizing_map` config key, resolved via `!scripts/resolve-config.sh sizing_map` (ADR-044 §10.26.3).
- Use the sm subagent (Nate) persona for planning reasoning -- do not re-implement planning logic inline.
- NEVER auto-set `priority_flag: "next-sprint"` on any story. Only humans set this flag. The skill reads and clears it only (per `feedback_priority_flag_never_auto_set`).
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, sprint-status.yaml, epics-and-stories.md, story-index.yaml, or per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` are FORBIDDEN.

## Steps

### Step 0 -- Prior-close guard (E81-S6 / FR-451)

Before sprint scoping begins, verify the previous sprint has been closed via `/gaia-sprint-close` (E81-S5). This prevents planning a new sprint while the prior sprint's `sprint-status.yaml` still shows `status: active` — which would orphan in-flight work and bypass the close ceremony.

- Resolve the previous sprint's yaml: search `.gaia/artifacts/implementation-artifacts/sprint-archive/` for the most recent `*-closed-*.yaml`, OR check the current `.gaia/state/sprint-status.yaml` for `status: active` (= prior sprint not yet closed).
- If `status: active` (or `status:` field absent on a non-fresh tree), refuse with `error: previous sprint {id} not closed; run /gaia-sprint-close first` and exit non-zero.
- If user passes `--allow-stale-prior`, skip the guard with a warning: `warning: proceeding despite prior sprint {id} not closed (--allow-stale-prior)`.
- If `status: closed`, proceed to Step 1.
- **Backward-compat:** if no previous sprint yaml exists (first sprint ever — fresh project), skip the guard silently.

Reference shell idiom (the SKILL.md should invoke this check via a small helper or inline grep; both are acceptable):

```bash
SS_YAML=".gaia/state/sprint-status.yaml"
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

- Read `.gaia/artifacts/planning-artifacts/epics-and-stories.md`.
- Parse all stories with their priorities, sizes, and dependencies.
- Resolve individual story files via the shared `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-story-file.sh` helper (E79-S7 / FR-476). For each story key parsed from `epics-and-stories.md`, call the helper to get the resolved path, capturing both stdout (path) and stderr (WARNINGs). The helper centralizes the E79-S4 nested-over-flat precedence rule: it walks `.gaia/artifacts/implementation-artifacts/epic-*/stories/{key}-*.md` recursively as the canonical layer (the recursive idiom `find "${IMPLEMENTATION_ARTIFACTS}" -path '*/stories/*.md' -type f -print0` is encapsulated inside the helper — bash globs do NOT recurse, so any non-recursive `for f in .gaia/artifacts/implementation-artifacts/*.md` loop would silently miss every nested story), and falls back to the legacy-flat layout `.gaia/artifacts/implementation-artifacts/{key}-*.md` with stderr `WARNING: legacy-flat path — {flat_path} (migrate via E79-S6)`. **Precedence rule (E79-S4):** if a story file exists at BOTH layers for the same `{key}`, the nested file wins and the flat sibling is logged as `WARNING: legacy-flat shadow ignored — {flat_path}` (deterministic — no glob-ordering dependence). Helper exit codes: 0 = resolved (single hit), 1 = zero matches (the story file is missing — classify as NOT SELECTABLE), 2 = multi-match ambiguity (operator must resolve). For each resolved file, read its frontmatter `status` field.
- Classify stories into selectable and non-selectable. **E107-S2 / ADR-128 — backlog selection:** a backlog story (a row in epics-and-stories.md, status `backlog`, with NO individual file yet) is SELECTABLE directly from the roster; it does NOT require pre-materialization. JIT materialization (`/gaia-create-story --for-sprint`, E107-S3) runs AFTER planning. The `resolve-story-file.sh` resolution above still applies for the files-present (already-materialized) path — both are selectable:
  - **SELECTABLE (backlog, JIT):** a roster row in epics-and-stories.md with no file yet — materialized after planning (E107-S3). No `/gaia-create-story` precondition.
  - **SELECTABLE (materialized):** stories with individual files AND `status: ready-for-dev` (backward-compat, files-present path).
  - **NOT SELECTABLE (wrong status):** a materialized story in a non-`ready-for-dev`/non-`backlog` status (e.g. in-progress/review/done) is not re-selectable: "Story {key} is in '{status}' status -- not selectable."
  - Dependency selectability is enforced by the column-sourced lint (`backlog-select-lint.sh`, see Critical Rules) — a candidate whose hard dep is neither done nor co-selected is HARD-BLOCKED.
- Display the classification: selectable stories table (`Key | Title | Priority | Size | Risk | Status`) and non-selectable stories with reasons.
- **Priority-flag pre-scan (E38-S4):** run `pflag_scan_backlog` from `${CLAUDE_PLUGIN_ROOT}/scripts/priority-flag.sh` against `.gaia/artifacts/implementation-artifacts/`. This returns all story keys whose frontmatter has `status: backlog` AND `priority_flag: "next-sprint"`. Display these as a separate section: "Auto-included by priority_flag: [list of keys]". These stories are pre-filled into the candidate set in Step 3 before user selection. If no flagged stories are found, display "priority_flag: no flagged backlog stories found" and proceed normally.
- **Hotfix active-sprint inject (E40-S3, ADR-109 §D3):** run `pflag_scan_active_hotfix` from `${CLAUDE_PLUGIN_ROOT}/scripts/priority-flag.sh` against `.gaia/artifacts/implementation-artifacts/`. This returns all story keys with `priority_flag: "hotfix"` regardless of current status (backlog | in-progress | ready-for-dev). For each match, invoke `bash ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh inject --story <key>` (ADR-095 sanctioned boundary writer) to add the story to the ACTIVE sprint. Emit one WARNING log line per injection: `WARNING: hotfix story <key> injected into active sprint via priority_flag: "hotfix" (ADR-109 §D3)`. Per ADR-109 §D4: hotfix stories MUST still pass the full `/gaia-run-all-reviews` including NFR-073 wire-verification — a hotfix is faster to PLAN, NOT faster to TEST. `sprint-state.sh inject` is idempotent under lock — re-runs are no-ops via the existing `yaml_has_story_key` check. The capacity-exceeded case does NOT block hotfix injection (ADR-109 §D3 — hotfix is a sanctioned bypass of normal sprint capacity).
- Load most recent `retro-{sprint_id}.md` from `.gaia/artifacts/implementation-artifacts/` if available. If retro found: extract open action items and present them as sprint constraints.

### Step 1.5 -- Action-Item Escalation Halt (E38-S2, FR-SPQG-1)

Before proceeding to sprint scoping, halt if any HIGH-priority action item has been open for two or more sprints (`escalation_count >= 2`). This forces systemic issues to resolution -- or conscious override -- before new sprint commitments are made.

**Invocation:**

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/escalation-halt.sh  # library-only; source + call
bash -c "source ${CLAUDE_PLUGIN_ROOT}/scripts/escalation-halt.sh && \
  esch_check_blocking \
    '${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/action-items.yaml' \
    '${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-status.yaml'"
```

**Contract:**

- Reads `.gaia/artifacts/planning-artifacts/action-items.yaml` (schema owned by E36-S2 / FR-RIM-5).
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
- Resolve the `sizing_map` key via `!scripts/resolve-config.sh sizing_map` (ADR-044 §10.26.3 — the resolver transparently merges the team-shared and machine-local layers, applying the "local overrides shared" precedence). Display the canonical point values (S/M/L/XL) before selection. <!-- Shared layer: .gaia/config/project-config.yaml. Local layer: global.yaml. -->

### Step 3 -- Story Selection

- Select stories for this sprint based on priority ordering (P0 > P1 > P2) and dependency topology -- only from stories classified as SELECTABLE in Step 1.
- **Priority-flag pre-fill (E38-S4):** any story keys returned by the priority-flag pre-scan in Step 1 are pre-selected in the candidate set before user interaction. Annotate each auto-included entry with `[priority_flag: next-sprint]` so the user sees why it was pre-filled. The user may deselect any pre-filled story -- deselection preserves the flag for the next planning run (AC2).
- **Agent-native capacity check (E106-S3, ADR-128, FR-552).** The "is this sprint too big" gate is evaluated on three agent-native measures — NOT the human points-per-duration heuristic (which false-flagged the 73-point sprint-53 sweep). Run `${CLAUDE_PLUGIN_ROOT}/scripts/sm-capacity-check.sh --stories-file <candidate-set>` (one `KEY|DEPS|POINTS` line per candidate) and read its verdict: (1) dependency critical-path **depth** (longest serial chain over `depends_on`), (2) context-coherence **ceiling** (distinct story count the agent can carry before quality degrades / forced compaction), and (3) telemetry-gated measured agent **wall-clock** (E106-S1 median minutes/story × story count) vs a configured agent-session budget. A sprint is "too big" only when one of these three measures is exceeded. Cold start (no closed-sprint telemetry) uses depth + coherence only, with no fabricated constant (NFR-90). Story `points` are RETAINED as the relative complexity/risk signal (review rigor, Val scrutiny, sizing display) — but `total_points <= velocity` is NO LONGER the capacity gate.
- **Dependency blocking:** for each candidate, check its `depends_on` list. If any dependency is NOT `done`, the story CANNOT be included. Display: "BLOCKED: Story {key} depends on {dep_key} (status: {dep_status})."
- **Priority surfacing:** after selection, check for P0 stories that are `ready-for-dev` but NOT selected. If any found, warn: "WARNING: P0 stories ready but not selected:" and ask user to confirm the exclusion.
- Resolve the test-plan via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): try `.gaia/artifacts/test-artifacts/test-plan.md` (flat); fall back to `.gaia/artifacts/test-artifacts/strategy/test-plan.md` (strategy/ placement). If the resolved file exists: apply risk levels -- buffer 20% for high-risk stories.
- **ATDD check (high-risk only):** for each high-risk story, check if an ATDD file exists at the resolver-returned path (`bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-test-artifact-per-story.sh atdd {story_key} --existing-only` — accepts the new per-story `test-artifacts/epic-{epic_slug}/stories/{key}-{slug}/atdd.md` home and the legacy flat `test-artifacts/atdd-{story_key}.md` fallback per AF-2026-05-30-1 / Test03 §7.3). If the resolver exits 1 (no rung exists): "HIGH-RISK story {key} has no ATDD file -- run `/gaia-atdd {key}` before development."
- Present the candidate sprint to the user and capture confirmation.

### Step 4 -- Update Story Files

- For each selected story with an individual file, set the `sprint_id` field to `sprint-{N}` via one of the **two sanctioned helpers** (Test05 F-034, AF-2026-05-30-4 F-15 — do NOT hand-edit the frontmatter):

  ```bash
  # Standalone helper (Test05 F-034 vintage):
  ${CLAUDE_PLUGIN_ROOT}/scripts/set-story-sprint.sh {story_key} --sprint sprint-{N}

  # Unified verb on sprint-state.sh (AF-2026-05-30-4 F-15 — closes the
  # chicken-and-egg gap where `inject` refused a pre-materialized backlog
  # story whose sprint_id was still `null`):
  ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh set-story-sprint --story {story_key} --sprint sprint-{N}
  ```

  Both writers rewrite only the `sprint_id:` scalar under a per-story flock (atomic tmp+mv; insert when absent). They are functionally interchangeable — the `sprint-state.sh set-story-sprint` form is the canonical surface for new callers because it keeps every sprint-binding mutation inside the same script that owns `inject`, while the standalone `set-story-sprint.sh` remains as a stable lower-level primitive. Either form is the field that `sprint-state.sh inject`'s drift guard reads, so it MUST be set before the inject/commit step. Clear it with `--sprint null` (standalone) or use `sprint-state.sh rollover --from sprint-{N} --keys {story_key}` to move between sprints.
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
  # Test10 F-30 — start_date / end_date / capacity_points are REQUIRED for the
  # dashboard (otherwise it renders N/A). Seed them at sprint-plan time;
  # sprint-state.sh `init` preserves them.
  start_date: "{start_date YYYY-MM-DD}"
  end_date: "{end_date YYYY-MM-DD}"
  capacity_points: {capacity_points integer — usually equal to velocity_capacity}
  started: "{date}"
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
- Write `sprint-status.yaml` to `.gaia/state/sprint-status.yaml` EXCLUSIVELY via `sprint-state.sh`:
  ```bash
  # F-7 (AF-2026-05-26-3): for the FIRST-EVER sprint on a fresh project there
  # is no sprint-status.yaml yet, and `inject` halts with "sprint-status.yaml
  # is missing or empty". Bootstrap it via `init` FIRST — but only when the
  # yaml is absent: `init` refuses to overwrite an existing yaml (exits
  # non-zero), so guard the call on absence rather than swallowing its error
  # (swallowing would violate the "abort on non-zero" contract below).
  SPRINT_YAML=".gaia/state/sprint-status.yaml"
  # AF-2026-05-31-1 / Test12 F-15: forward the planning-time date + capacity
  # values to `init` so the burndown dashboard renders concrete Duration /
  # Dates / Capacity rows instead of `N/A`. Each flag is optional — when an
  # operator omits a value the `init` shape stays byte-identical to the
  # pre-AF-31-1 seed (zero-regression on existing bats fixtures). The
  # `{start_date}`, `{end_date}`, `{capacity_points}` placeholders are the
  # SAME values the SKILL.md yaml stub above documents, so the dashboard
  # and the sprint yaml never disagree.
  [ -e "$SPRINT_YAML" ] || \
    ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh init \
      --sprint-id "{sprint_id}" \
      --start-date "{start_date YYYY-MM-DD}" \
      --end-date "{end_date YYYY-MM-DD}" \
      --capacity-points "{capacity_points integer}"

  ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh inject \
    --story "{story_key}" [--sprint-id "{sprint_id}"]
  ```
  Invoke `init` once (guarded on yaml absence), then `inject` once per selected story to register it in the sprint. The `init` subcommand (AF-2026-05-22-9 Bug-8) seeds the canonical shape (`sprint_id`/`state: active`/`total_points: 0`/`goals: []`/`items: []`). The `inject` subcommand (E38-S10, ADR-055 §10.29) appends the story's metadata mirrored from the story file's frontmatter — the four required fields (`sprint_id`, `status`, `points`, `risk`) MUST be present in the story file before the call. `inject` is idempotent — re-running on an already-registered key is a no-op. Use `transition` only for in-sprint status changes after the entry exists. If `sprint-state.sh` exits non-zero, abort cleanly and surface the error to the user. Do NOT fall back to direct YAML writes.

### Step 6a -- Sprint Goal Routing (E93-S5, FR-486, FR-495, ADR-108)

After Step 6 commits the sprint to `sprint-status.yaml`, present the 3-lane goal router to the user so the sprint carries an explicit `goals[]` list (consumed downstream by `/gaia-sprint-review` Track A Val rubric scoring). The auto-suggested goals are the union of selected stories' acceptance-criteria headlines.

This step is gated on the sprint having at least one selected story — if zero stories were selected at Step 3, skip the goal router silently (preserves the AC6 backward-compat invariant from E93-S5).

The router presents `AskUserQuestion` at main-turn with the canonical 3-lane menu (per NFR-067 main-turn-only invariant):

- `user-direct` — the user edits the suggested goals inline via a follow-up `AskUserQuestion` (free-form) and the result persists via `sprint-state.sh set-goals --sprint <id> --goals "<g1|g2|...>"` (per E93-S1 boundary writer; never direct `yq -i`). **F-10 (AF-2026-05-26-3):** `--goals` is PIPE-DELIMITED, not JSON — `cmd_set_goals` parses it with `IFS='|'`. Pass `"Goal one|Goal two|Goal three"`, not a JSON array.
- `pm-route` — dispatch Val via the **main-turn Agent tool** (per ADR-093 / ADR-104) with the AI-1 sprint-review rubric at `gaia-public/plugins/gaia/rubrics/base/sprint-review.json` to score the suggested goals against the selected stories' ACs. Display Val's verdict + findings inline, then present a follow-up `AskUserQuestion` directed at the USER (NOT the PM) for the final accept — this preserves the **PM-cannot-self-approve** invariant from ADR-104. On user accept: `sprint-state.sh set-goals`. The PM may DRAFT but the USER ratifies.
- `yolo` — dispatch Val identically to the pm-route lane. On Val PASSED: auto-accept and persist via `sprint-state.sh set-goals`. On Val FAILED: HALT with the findings list — YOLO MUST NOT bypass a FAILED verdict per ADR-067.

Traceability: FR-486, FR-495, AC1 of E93-S5, ADR-108 §D1.

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

- Run `mkdir -p .gaia/artifacts/implementation-artifacts/sprint-plan/` so the nested directory exists on first run (ADR-119).
- Write the sprint plan document to `.gaia/artifacts/implementation-artifacts/sprint-plan/{sprint_id}-plan.md`.
- The document includes all sections from Step 5.

### Step 8 -- Val Validation (optional)

- If the Val subagent is available: invoke Val to validate the sprint plan. Val verifies:
  - All selected story keys exist as story files with status `ready-for-dev`
  - Dependency ordering is correct
  - Points sum is recorded (relative-complexity signal) and the agent-native capacity check (`sm-capacity-check.sh`: depth + coherence + telemetry-gated wall-clock) did not flag the batch — the legacy `total <= velocity` points-gate is NOT the capacity criterion (E106-S3, ADR-128)
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
    --arg artifact_path ".gaia/artifacts/implementation-artifacts/sprint-plan/${sprint_id}-plan.md" \
    --argjson findings  "${findings_json:-[]}" \
    '{verdict: $verdict, findings: $findings, artifact_path: $artifact_path}')"
```

The helper enforces the two-file allowlist (NFR-VSP-2) and idempotency by composite `(command_name, input_id, decision_hash)` key (FR-VSP-2) — re-runs with identical payload yield `status=skipped_duplicate` and must be treated as success.

Failure posture: if the helper rejects or errors, log a warning and continue — memory persistence is best-effort and MUST NOT fail the skill.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-plan/scripts/finalize.sh
