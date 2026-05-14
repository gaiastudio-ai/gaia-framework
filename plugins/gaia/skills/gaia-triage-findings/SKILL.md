---
name: gaia-triage-findings
description: "Scan in-progress and completed story files for development findings and triage each into a new backlog story, an existing story, or dismiss. Produces new story files with complete frontmatter (15 required fields, status: backlog, sprint_id: null). Source story findings tables stay intact for idempotent re-triage. Done-story guard (FR-FITP-1) blocks ADD TO EXISTING mutations against status: done targets with an explicit override path recorded for retrospective review. GAIA-native replacement for the legacy triage-findings XML engine workflow."
argument-hint: "[story-key?] [--override-done-story --user <u> --date <d> --finding <fid> --reason <r>]"
allowed-tools: [Read, Write, Bash]
version: "1.2.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/setup.sh

## Mission

Scan story files in `docs/implementation-artifacts/` for populated Findings tables and triage each finding into actionable backlog stories. New story files are created with complete frontmatter (all 15 required fields populated, `status: backlog`, `sprint_id: null`). The source story's findings table stays intact so re-triage is idempotent-friendly (dedup by source story key + finding text if re-run).

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/triage-findings/` XML engine workflow (brief Cluster 8, story E28-S63). Follows ADR-042 (scripts-over-LLM) where applicable.

## Critical Rules

- Every finding MUST be triaged -- none may be left unprocessed.
- New stories created from findings MUST have `status: backlog` and `sprint_id: null`.
- The source story findings table MUST never be mutated or deleted. Triage markers (`[TRIAGED]`, `[DISMISSED]`) are appended to the finding text -- the original finding row stays intact.
- Do not modify the source story file beyond appending triage markers to the Findings table.
- New story keys MUST use the next sequential number in the epic -- scan existing stories to determine the last key. NEVER reuse an existing key.
- New triaged stories MUST NOT be added to `sprint-status.yaml` -- they are backlog items assigned to sprints via `/gaia-sprint-plan` or injected via `/gaia-correct-course`.
- New stories MUST be appended to `epics-and-stories.md` under the correct epic.
- New backlog story files MUST use the canonical filename format `{story_key}-{story_title_slug}.md`.
- All 15 required frontmatter fields must be populated: `template`, `version`, `used_by`, `key`, `title`, `epic`, `status`, `priority`, `size`, `points`, `risk`, `sprint_id`, `date`, `author`, and at minimum one of `depends_on`/`blocks`/`traces_to` (can be empty arrays).
- **Done-Story Immutability Guard (FR-FITP-1):** Before any ADD TO EXISTING mutation, MUST invoke `scripts/triage-guard.sh check <target_story>`. If the target story has `status: done`, the guard halts with guidance to route through `/gaia-create-story` (new story) or `/gaia-add-feature` (change request) — zero writes to the done story. An explicit override path exists (`--override-done-story` with user, date, finding ID, reason) that records the override in the triage report with `retro_flag: true` so `/gaia-retro` surfaces it. Done stories are immutable institutional artifacts; silent mutation merges retro-blind regressions back into closed work.
- **Reproduction Required (E28-S223):** Every finding suggesting a fix MUST carry a reproduction command (a runnable command + the expected failure) in its suggested-action column before it can be promoted via CREATE STORY or ADD TO EXISTING. Findings that lack a reproduction snippet MUST be classified as **DISMISS pending reproduction** with a clear "reproduction required" warning surfaced to the user. This rule traces back to the saved memory `feedback_reproduce_before_fix_stories.md` — stale triage findings have shaped fix-stories for non-existent failures (E28-S211 finding F2, attempted fix in E28-S214). The reproduction snippet, when present, MUST be embedded into the new story's Origin section by the `/gaia-create-story` spawn (see Step 4) so future readers can re-verify the failure before re-touching the code.

## Steps

### Step 1 --- Scan for Findings

Scan story files in `${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/` for non-empty Findings tables.

1. Read all `.md` files matching `E*-S*-*.md` in the implementation artifacts directory.
2. For each file, look for the `## Findings` section and parse the markdown table.
3. Skip findings already marked as `[TRIAGED]` or `[DISMISSED]`.
4. If an optional `story-key` argument was provided, scan only that story file.
5. If no untriaged findings are found: inform user "No findings to triage" and stop.

Collect all findings from ALL story files regardless of status -- scan every `.md` file that has a non-empty Findings table. This ensures triage catches findings from stories in any status.

### Step 1b --- Scan Completion Notes for Deferral Drift (E88-S4, FR-DPD-4)

Refs: ADR-107 (closed-list taxonomies SSOT), AI-2026-05-13-6.

In addition to the Findings-table scan above, walk the `### Completion Notes List` subsection of each story file looking for deferral phrases (per E88-S1 taxonomy SSOT) that lack a paired Finding row. Use the canonical helper — do NOT inline the taxonomy:

```bash
for story_file in $story_files; do
  bash $PLUGIN/scripts/lib/completion-notes-deferral-scan.sh --story-file "$story_file" \
    | while IFS=$'\t' read -r phrase_kv paired_kv fid_kv; do
        # Parse `phrase=<>\tpaired=<>\tfinding_id=<>`
        phrase="${phrase_kv#phrase=}"
        paired="${paired_kv#paired=}"
        finding_id="${fid_kv#finding_id=}"
        if [ "$paired" = "false" ]; then
          emit_triage_candidate \
            --source "completion-notes-deferral-scan" \
            --story-key "$(basename "$story_file" | sed 's/-.*//')" \
            --phrase "$phrase"
        fi
      done
done
```

The triage output schema gains a `source` column with values `findings-table` (the Step 1 default) or `completion-notes-deferral-scan` (Step 1b). Existing consumers parsing by row/column ignore extra columns — the change is purely additive.

### Step 2 --- Present Findings

Group findings by severity (critical first, then high, medium, low).

For each finding, show:
- Source story key
- Type (bug, tech-debt, enhancement, missing-setup, documentation)
- Severity (critical, high, medium, low)
- Description
- Suggested action

### Step 3 --- Triage Each Finding

For each finding, generate a triage recommendation based on:

- **Severity:** CRITICAL or HIGH findings -> recommend CREATE STORY
- **Type:** `bug` and `tech-debt` -> recommend CREATE STORY; `enhancement` -> consider ADD TO EXISTING
- **Scope:** If the finding is closely related to an existing backlog story -> recommend ADD TO EXISTING
- **Relevance:** If the finding is no longer applicable -> recommend DISMISS

For each CREATE STORY recommendation, also recommend timing:
- **CRITICAL** -> **NOW**: Inject into current sprint via `/gaia-correct-course`
- **HIGH** -> **NEXT SPRINT**: Flag as P0 for `/gaia-sprint-plan`
- **MEDIUM** -> **BACKLOG**: Standard priority P1
- **LOW** -> **BACKLOG**: Standard priority P2

Present recommendations and let the user confirm or override each decision:
- **CREATE STORY** -- generate a new backlog story file
- **ADD TO EXISTING** -- append finding to an existing story's tasks
- **DISMISS** -- finding is not actionable or already resolved

### Step 3a --- Reproduction Required Gate (E28-S223)

Before any CREATE STORY or ADD TO EXISTING recommendation is finalized, the parser MUST inspect the finding's suggested-action column for a **reproduction command** — a runnable command (or short command sequence) that produces the failure described in the finding, plus the expected failure output.

Decision matrix:

- **Reproduction command present** in the suggested-action column: proceed with the recommendation (CREATE STORY or ADD TO EXISTING). Capture the reproduction snippet verbatim and pass it to Step 4 so the `/gaia-create-story` spawn embeds it in the new story's `## Origin` section. For ADD TO EXISTING, append the snippet to the target story's tasks alongside the finding text.
- **Reproduction command absent**: reclassify the finding as **DISMISS pending reproduction**. Surface a clear `reproduction required: finding {finding_id} cannot be promoted without a runnable reproduction snippet` warning to the user. The user MAY override interactively by supplying a snippet on the spot — that snippet is then captured and the finding routes back through the normal CREATE STORY / ADD TO EXISTING path.

Rationale: stale triage findings have repeatedly shaped fix-stories for failures that no longer reproduce (E28-S211 finding F2, attempted fix in E28-S214). The saved memory `feedback_reproduce_before_fix_stories.md` records this anti-pattern. The Reproduction Required gate is the structural fix — triage cannot encode hallucinated failures because every promoted finding carries a reproduction snippet that the next developer can run before re-touching the code.

### Step 3b --- Done-Story Guard (ADD TO EXISTING only, FR-FITP-1)

For every finding classified as **ADD TO EXISTING**, BEFORE any mutation of the target story, invoke the done-story guard:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/triage-guard.sh check "${target_story_file}"
```

Interpret the exit code:

- **Exit 0** — target status is `in-progress`, `review`, `ready-for-dev`, `validating`, or `backlog`. Proceed with the ADD TO EXISTING mutation (append finding to the target story's tasks).
- **Exit 2** — target is `status: done`. The guard emits halt guidance on stdout (story key, sprint ID, retrospective linkage, sanctioned redirects). Present the guidance to the user. Do NOT mutate the target story. Two sanctioned paths:
  - **Recommended:** re-classify the finding as CREATE STORY (routes through `/gaia-create-story` with `origin: triage-findings`).
  - **Change request:** open `/gaia-add-feature` if the finding implies a spec-level amendment.
- **Exit 1** — error reading the target story file. Surface the stderr and halt the classification pathway for that finding.

**Override path (rare, audited):** If the user explicitly requests the override, re-invoke the guard with all override arguments:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/triage-guard.sh check \
  --override \
  --user "${USER}" \
  --date "$(date -u +%Y-%m-%d)" \
  --finding "${finding_id}" \
  --reason "${user_supplied_reason}" \
  --report "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/triage-report.md" \
  "${target_story_file}"
```

The guard exits 0 and appends an override record to the triage report under a `## Done-Story Guard Overrides` section:

```yaml
- user: "<user>"
  date: "<YYYY-MM-DD>"
  finding_id: "<finding_id>"
  target_story_key: "<E*-S*>"
  reason: "<free-text>"
  retro_flag: true
```

`retro_flag: true` ensures `/gaia-retro` surfaces the override for retrospective review. Proceed with the ADD TO EXISTING mutation only after the guard exits 0.

**Non-mutation invariant:** on the guard-fired path (no override), zero writes to the target story file, zero writes to `sprint-status.yaml`, zero writes to `action-items.yaml` (action-items writes land in Step 3c below).

### Step 3c --- Record Action Items for NOW Classifications (E39-S3, FR-FITP-3)

For every finding classified as **NOW** (inject into current sprint), persist a structured action-items entry so retrospectives, `/gaia-action-items` resolution, and `/gaia-sprint-plan` escalation halts (E38-S2) have a complete record. This write is independent of the CREATE STORY / ADD TO EXISTING routing -- a finding classified NOW always produces exactly one action-items entry.

1. Source the action-items writer:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/action-items-write.sh"
```

2. Map the finding type to the classification enum:
   - `bug` -> `bug`
   - `task` -> `task`
   - `research` -> `research`
   - Any other finding type -> **HALT** with: `"Unknown finding type '{type}'. Expected: bug, task, research. Cannot map to action-items classification."` Do NOT silently default -- the mapping is explicit by design.

3. Invoke the writer:
```bash
aiw_write \
  --target "${CLAUDE_PROJECT_ROOT}/docs/planning-artifacts/action-items.yaml" \
  --sprint-id "{current_sprint_id}" \
  --classification "{mapped_classification}" \
  --text "{finding_summary}" \
  --ref-key "finding_id" \
  --ref-value "{finding_id}"
```

The writer handles:
- **Bootstrap:** creates `action-items.yaml` with the architecture §10.28.6 schema header if the file does not exist.
- **Auto-increment:** computes the next `AI-{n}` id from existing entries.
- **Idempotency:** dedup key is `(finding_id, sprint_id)` -- re-running the same triage does not duplicate.
- **Schema compliance:** entry fields match architecture §10.28.6 exactly (`id`, `sprint_id`, `text`, `classification`, `status: open`, `escalation_count: 0`, `created_at`, `theme_hash`, `finding_id`).

### Step 4 --- Create Backlog Stories (Skill-to-Skill Delegation, FR-FITP-2)

Story creation is delegated to `/gaia-create-story` via subagent spawn. This replaces all inline story-creation logic -- delegation is authoritative. The spawned `/gaia-create-story` produces the full elaboration (AC, tasks, test scenarios) and records provenance in the frontmatter.

For each CREATE STORY decision:

1. Determine the correct epic from the source story's `epic` field.
2. Scan `${CLAUDE_PROJECT_ROOT}/docs/planning-artifacts/epics-and-stories.md` and `${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/` for all existing stories in that epic.
3. Find the highest story number and assign the next sequential key.
4. Update `epics-and-stories.md` with the new story entry under the correct epic.

5. **Pre-spawn validation:** validate `origin_ref` (the finding ID) using `spawn-guard.sh`:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" validate-ref "${finding_id}"
```
If validation fails (empty, null, shell-unsafe characters), halt with guidance. Do not spawn the subagent.

6. **Collision check:** verify no story file already exists at the canonical path:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" check-collision "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts" "${new_story_key}"
```
If collision detected, halt with guidance to delete or rename before retry. Do not spawn the subagent.

7. **Spawn `/gaia-create-story`:** invoke as a subagent with origin context AND the reproduction snippet captured at Step 3a (when present):
```
/gaia-create-story {new_story_key} with origin="triage-findings" origin_ref="{finding_id}" reproduction="{reproduction_snippet}"
```
The spawned `/gaia-create-story` populates the story frontmatter with `origin: "triage-findings"` and `origin_ref: "{finding_id}"`, embeds the reproduction snippet verbatim into the new story's `## Origin` section (under a "Reproduction" subsection or fenced code block), and produces the full elaboration (AC, tasks, test scenarios). When the reproduction argument is empty (Step 3a override path with user-supplied snippet not provided), the finding cannot reach this step — Step 3a routes it to DISMISS pending reproduction. The parent MUST NOT duplicate elaboration logic -- delegation is authoritative.

8. **Post-spawn verification:** after the subagent completes, verify the story file exists and frontmatter is correct:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" verify "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/${new_story_key}-*.md" "triage-findings" "${finding_id}"
```
If verification fails (schema drift in `origin`/`origin_ref`), halt with actionable guidance referencing NFR-FITP-1.

9. **On subagent failure** (timeout, context overflow, crash): halt with actionable guidance (failure reason, retry instructions). Clean up any partial file:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" cleanup "${CLAUDE_PROJECT_ROOT}/docs/implementation-artifacts/${new_story_key}-*.md"
```
No partial story stubs may persist on disk after a failed spawn.

### Step 5 --- Mark Findings as Triaged

In each source story's Findings table, append triage markers to processed findings:

- CREATE STORY: append `[TRIAGED -> {new_story_key}]` to the Finding column
- ADD TO EXISTING: append `[TRIAGED -> {existing_story_key}]` to the Finding column
- DISMISS: append `[DISMISSED]` to the Finding column

### Step 6 --- Summary and Recommendations

Present the triage summary:
- Total findings processed
- Stories created (with keys and priorities)
- Items added to existing stories
- Items dismissed

Confirm: "epics-and-stories.md updated with {N} new stories under their respective epics."

If any stories were marked as NOW (inject into current sprint):
- Suggest running `/gaia-correct-course` to inject them.

If any stories were marked as NEXT SPRINT (P0):
- Note they will be prioritized in `/gaia-sprint-plan`.

### Step 7 — Persist to Val Sidecar (E34-S2)

Final step. Delegates Val-decision persistence to the shared Val sidecar writer helper (`val-sidecar-write.sh`, E34-S1, architecture §10.10). Placing this last satisfies AC3 atomicity — any upstream failure (spawn-guard rejection, `/gaia-create-story` subagent failure, findings-table write error) short-circuits before the helper runs, so no partial sidecar entry can appear.

Derive a deterministic `triage_session_id` of the form `triage-YYYY-MM-DD-<seq>`. The `<seq>` counter is a zero-padded monotonic index per day, computed by scanning existing triage markers in the current session's source stories:

```bash
today="$(date -u +%Y-%m-%d)"
seq="$(printf '%03d' "$(( $(ls docs/implementation-artifacts/ 2>/dev/null | grep -c "^triage-${today}-" || echo 0) + 1 ))")"
triage_session_id="triage-${today}-${seq}"
```

If no triage-artifact naming scheme is in use yet, `seq` defaults to `001`. This identifier is documented in the triage artifact header so downstream consumers can correlate the sidecar entry back to the source findings.

Build the decision payload as `{verdict, findings[], artifact_path}` — the `findings[]` list holds the triaged finding IDs (CREATE STORY / ADD TO EXISTING / DISMISS decisions) sorted by id.

Invoke the helper:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/val-sidecar-write.sh \
  --command-name "/gaia-triage-findings" \
  --input-id     "${triage_session_id}" \
  --sprint-id    "${sprint_id:-N/A}" \
  --decision-payload "$(jq -cn \
    --arg verdict       "${verdict:-recorded}" \
    --arg artifact_path "${triage_artifact_path}" \
    --argjson findings  "${findings_json:-[]}" \
    '{verdict: $verdict, findings: $findings, artifact_path: $artifact_path}')"
```

The helper enforces the two-file allowlist (NFR-VSP-2) and idempotency by composite `(command_name, input_id, decision_hash)` key (FR-VSP-2) — re-runs with identical payload yield `status=skipped_duplicate` and must be treated as success.

Failure posture: if the helper rejects or errors, log a warning and continue — memory persistence is best-effort and MUST NOT fail the skill.

## Changelog

- **2026-05-14 — E88-S4 — Completion Notes deferral-drift scanner (FR-DPD-4, ADR-107, AI-2026-05-13-6).** Added Step 1b that walks each story's `### Completion Notes List` via `lib/completion-notes-deferral-scan.sh` (which wraps `lib/deferral-phrase-match.sh` per E88-S1) and emits unmatched-deferral records as triage candidates. Triage output schema gains a new `source` column with values `findings-table` (the Step 1 default) or `completion-notes-deferral-scan` (Step 1b). Purely additive — existing consumers parsing by row/column ignore extra columns. Closes the drift class from AI-2026-05-13-6 at the triage end (the Val end is covered by gaia-validation-patterns' new pattern).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/finalize.sh
