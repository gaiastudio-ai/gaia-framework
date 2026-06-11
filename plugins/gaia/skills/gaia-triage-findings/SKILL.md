---
name: gaia-triage-findings
description: "Scan in-progress and completed story files for development findings and triage each into a new backlog story, an existing story, or dismiss. Produces new story files with complete frontmatter (15 required fields, status: backlog, sprint_id: null). Source story findings tables stay intact for idempotent re-triage. Done-story guard blocks ADD TO EXISTING mutations against status: done targets with an explicit override path recorded for retrospective review. GAIA-native replacement for the legacy triage-findings XML engine workflow."
argument-hint: "[story-key?] [--all] [--override-done-story --user <u> --date <d> --finding <fid> --reason <r>]"
allowed-tools: [Read, Write, Bash]
version: "1.3.0"
orchestration_class: light-procedural
yolo_steps: [3]
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/setup.sh

## Mission

Scan the active sprint's committed story files (by default) for populated Findings tables and triage each finding into actionable backlog stories. New story files are created with complete frontmatter (all 15 required fields populated, `status: backlog`, `sprint_id: null`). The source story's findings table stays intact so re-triage is idempotent-friendly (dedup by source story key + finding text if re-run).

**Scan scope.** The default scan is **sprint-scoped** — only the stories committed to the active sprint (resolved from `sprint-status.yaml`) are scanned, and findings are extracted via a deterministic frontmatter+Findings extractor that never reads full story bodies (token-budget protection). Pass `--all` for the full historical sweep across every story, or a `story-key` to scan a single story. See Step 1.

**Mandatory sprint-close prerequisite.** `/gaia-triage-findings` is a required step in the sprint-close sequence (**review → triage → retro → close**). When it runs against the active sprint, its finalize step writes a per-sprint proof-of-run sentinel (`triage-findings-{sprint_id}-completed.json`); `/gaia-sprint-close` refuses to close a sprint whose triage sentinel is absent. Run triage after `/gaia-sprint-review` and before `/gaia-retro`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/triage-findings/` XML engine workflow. Follows the scripts-over-LLM principle where applicable.

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
- **Done-Story Immutability Guard:** Before any ADD TO EXISTING mutation, MUST invoke `scripts/triage-guard.sh check <target_story>`. If the target story has `status: done`, the guard halts with guidance to route through `/gaia-create-story` (new story) or `/gaia-add-feature` (change request) — zero writes to the done story. An explicit override path exists (`--override-done-story` with user, date, finding ID, reason) that records the override in the triage report with `retro_flag: true` so `/gaia-retro` surfaces it. Done stories are immutable institutional artifacts; silent mutation merges retro-blind regressions back into closed work.
- **Reproduction Required:** Every finding suggesting a fix MUST carry a reproduction command (a runnable command + the expected failure) in its suggested-action column before it can be promoted via CREATE STORY or ADD TO EXISTING. Findings that lack a reproduction snippet MUST be classified as **DISMISS pending reproduction** with a clear "reproduction required" warning surfaced to the user. This rule traces back to the saved memory `feedback_reproduce_before_fix_stories.md` — stale triage findings have shaped fix-stories for non-existent failures. The reproduction snippet, when present, MUST be embedded into the new story's Origin section by the `/gaia-create-story` spawn (see Step 4) so future readers can re-verify the failure before re-touching the code.

## Steps

### Step 1 --- Scan for Findings

Scan story files for non-empty Findings tables. **Two deterministic helpers own
this step — the LLM does NOT glob the tree or read whole story files.**

**1a. Resolve the scan set (sprint-scoped by default).** The default scan is
the ACTIVE sprint's committed stories only — historical stories from prior
sprints have already been triaged, and re-scanning them wastes context. Resolve
the file set via:

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh \
  --impl-dir "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
  [--all]
```

The helper reads the **top-level** `sprint_id` and the **top-level `stories:`**
list from `.gaia/state/sprint-status.yaml`, gates on the top-level `status:`
lifecycle value (only `active` sprint-scopes; `closed`/`planned` emits nothing
with an informational stderr message), resolves each committed key to its file
path via `resolve-story-file.sh`, and emits one path per line.

- **`--all` flag** restores the legacy full historical sweep (every `*.md`
  under implementation-artifacts). Pass it when the operator explicitly wants
  to re-triage the whole backlog.
- If an optional `story-key` argument was provided, scan only that story file
  (overrides sprint-scoping).
- A closed/planned active sprint (no sprint-scoped set) means the operator
  should pass `--all` or a `story-key` — surface the helper's stderr message.

**1b. Extract findings (frontmatter + Findings only — never the body).** For
each resolved file, extract its candidates via the deterministic per-story
extractor — it reads ONLY the YAML frontmatter and the `## Findings` section,
never the full story body (token-budget protection):

```bash
!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/extract-findings.sh \
  --story-file "<resolved-path>"
```

The extractor emits pipe-delimited rows
`<story_key>|<status>|<sprint_id>|<type>|<severity>|<finding>|<action>`. The LLM
consumes these rows — it MUST NOT `Read` whole story files for the Findings
scan.

**1c. Filter + halt.** Skip findings already marked `[TRIAGED]` or
`[DISMISSED]` (the extractor already excludes `[TRIAGED]`/`[DISMISSED]` bug
rows; the LLM applies the same skip to any remaining marked rows). If no
untriaged findings are found: inform the user "No findings to triage" and stop.

### Step 1b --- Scan Completion Notes for Deferral Drift

In addition to the Findings-table scan above, walk the `### Completion Notes List` subsection of each story file looking for deferral phrases (per the taxonomy SSOT) that lack a paired Finding row. Use the canonical helper — do NOT inline the taxonomy:

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

> [!yolo]
> Step 3 honors the declarative `yolo_steps: [3]` frontmatter declaration. Under YOLO, the recommended disposition (DEFER / ADD TO EXISTING / NEW STORY / NOW) is auto-applied per finding without the per-finding `confirm or override` prompt. Subagent inheritance: `GAIA_YOLO_MODE=1` propagates to delegated `/gaia-create-story` spawns. Hard gates remain enforced in BOTH modes: Step 3a (Reproduction Required), Step 3b (Done-Story Guard), and Step 3c (action-items persistence) are NEVER bypassed — `yolo_steps` covers only Step 3 itself, never 3a/3b/3c. Data-sufficiency interactive fallback: if a finding lacks fields required by its recommendation (missing epic key, unresolvable target story, missing sprint ID for NOW), the auto-apply pauses for that finding only and surfaces the per-finding interactive fallback — no silent default. Ctrl-C recovery: the existing `[TRIAGED]` / `[DISMISSED]` markers + `(finding_id, sprint_id)` dedup key on `.gaia/state/action-items.yaml` guarantee re-run idempotency.

Detect YOLO via the canonical helper (do NOT re-implement detection inline):

```bash
if ${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo; then
  # auto-apply branch: iterate findings; for each, auto-apply the recommendation
  # below without surfacing the per-finding confirm/override prompt
  YOLO_MODE=true
else
  # interactive branch: retain the existing per-finding confirm/override flow
  # with byte-identical wording (regression guard on the confirm/override prompt)
  YOLO_MODE=false
fi
```

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

### Step 3a --- Reproduction Required Gate

Before any CREATE STORY or ADD TO EXISTING recommendation is finalized, the parser MUST inspect the finding's suggested-action column for a **reproduction command** — a runnable command (or short command sequence) that produces the failure described in the finding, plus the expected failure output.

Decision matrix:

- **Reproduction command present** in the suggested-action column: proceed with the recommendation (CREATE STORY or ADD TO EXISTING). Capture the reproduction snippet verbatim and pass it to Step 4 so the `/gaia-create-story` spawn embeds it in the new story's `## Origin` section. For ADD TO EXISTING, append the snippet to the target story's tasks alongside the finding text.
- **Reproduction command absent**: reclassify the finding as **DISMISS pending reproduction**. Surface a clear `reproduction required: finding {finding_id} cannot be promoted without a runnable reproduction snippet` warning to the user. The user MAY override interactively by supplying a snippet on the spot — that snippet is then captured and the finding routes back through the normal CREATE STORY / ADD TO EXISTING path.

Rationale: stale triage findings have repeatedly shaped fix-stories for failures that no longer reproduce. The saved memory `feedback_reproduce_before_fix_stories.md` records this anti-pattern. The Reproduction Required gate is the structural fix — triage cannot encode hallucinated failures because every promoted finding carries a reproduction snippet that the next developer can run before re-touching the code.

### Step 3b --- Done-Story Guard (ADD TO EXISTING only)

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
  --report "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/triage-report.md" \
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

**Non-mutation invariant:** on the guard-fired path (no override), zero writes to the target story file, zero writes to `sprint-status.yaml`, zero writes to `.gaia/state/action-items.yaml` (action-items writes land in Step 3c below).

### Step 3c --- Record Action Items for NOW Classifications

For every finding classified as **NOW** (inject into current sprint), persist a structured action-items entry so retrospectives, `/gaia-action-items` resolution, and `/gaia-sprint-plan` escalation halts have a complete record. This write is independent of the CREATE STORY / ADD TO EXISTING routing -- a finding classified NOW always produces exactly one action-items entry.

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
  --target "${CLAUDE_PROJECT_ROOT}/.gaia/state/action-items.yaml" \
  --sprint-id "{current_sprint_id}" \
  --classification "{mapped_classification}" \
  --text "{finding_summary}" \
  --ref-key "finding_id" \
  --ref-value "{finding_id}"
```

The writer handles:
- **Bootstrap:** creates `.gaia/state/action-items.yaml` with the canonical action-items schema header if the file does not exist.
- **Auto-increment:** computes the next `AI-{n}` id from existing entries.
- **Idempotency:** dedup key is `(finding_id, sprint_id)` -- re-running the same triage does not duplicate.
- **Schema compliance:** entry fields match the canonical action-items schema exactly (`id`, `sprint_id`, `text`, `classification`, `status: open`, `escalation_count: 0`, `created_at`, `theme_hash`, `finding_id`).

### Step 4 --- Create Backlog Stories (Skill-to-Skill Delegation)

Story creation is delegated to `/gaia-create-story` via subagent spawn. This replaces all inline story-creation logic -- delegation is authoritative. The spawned `/gaia-create-story` produces the full elaboration (AC, tasks, test scenarios) and records provenance in the frontmatter.

For each CREATE STORY decision:

1. Determine the correct epic from the source story's `epic` field.
2. Scan `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/planning-artifacts/epics-and-stories.md` and `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/` for all existing stories in that epic.
3. Find the highest story number and assign the next sequential key.
4. Update `epics-and-stories.md` with the new story entry under the correct epic.

5. **Pre-spawn validation:** validate `origin_ref` (the finding ID) using `spawn-guard.sh`:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" validate-ref "${finding_id}"
```
If validation fails (empty, null, shell-unsafe characters), halt with guidance. Do not spawn the subagent.

6. **Collision check:** verify no story file already exists at the canonical path:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" check-collision "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" "${new_story_key}"
```
If collision detected, halt with guidance to delete or rename before retry. Do not spawn the subagent.

7. **Spawn `/gaia-create-story`:** invoke as a subagent with origin context AND the reproduction snippet captured at Step 3a (when present):
```
/gaia-create-story {new_story_key} with origin="triage-findings" origin_ref="{finding_id}" reproduction="{reproduction_snippet}"
```
The spawned `/gaia-create-story` populates the story frontmatter with `origin: "triage-findings"` and `origin_ref: "{finding_id}"`, embeds the reproduction snippet verbatim into the new story's `## Origin` section (under a "Reproduction" subsection or fenced code block), and produces the full elaboration (AC, tasks, test scenarios). When the reproduction argument is empty (Step 3a override path with user-supplied snippet not provided), the finding cannot reach this step — Step 3a routes it to DISMISS pending reproduction. The parent MUST NOT duplicate elaboration logic -- delegation is authoritative.

8. **Post-spawn verification:** after the subagent completes, verify the story file exists and frontmatter is correct:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" verify "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/${new_story_key}-*.md" "triage-findings" "${finding_id}"
```
If verification fails (schema drift in `origin`/`origin_ref`), halt with actionable guidance.

9. **On subagent failure** (timeout, context overflow, crash): halt with actionable guidance (failure reason, retry instructions). Clean up any partial file:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn-guard.sh" cleanup "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/${new_story_key}-*.md"
```
No partial story stubs may persist on disk after a failed spawn.

#### Main-turn direct-write fallback

The spawn pathway above (steps 5-9) is the **default**, and **spawn is still the default** — DO NOT route around it preemptively. Use the fallback ONLY when one of two trigger conditions holds:

1. The spawn dispatch returns a malformed result (no story file created on disk, frontmatter incomplete, post-spawn `spawn-guard.sh verify` exits non-zero), OR
2. The operator confirms the broken-fork condition explicitly (e.g., the `Agent` tool reports as missing from the forked-skill allowlist).

The canonical trigger references are saved-memory rule `feedback_plugin_context_fork_broken.md` and Claude Code substrate issue #49559 (open on 2.1.138). Without one of these triggers, the fallback MUST NOT fire.

When the fallback IS triggered, the operator authors the story file in the main turn via the `Write` tool directly. Because `spawn-guard.sh verify` and `spawn-guard.sh cleanup` cannot run on a directly-written file (the spawn-completion contract they expect never happens), the operator MUST run the following three **inline validation-equivalent checks** before the file is considered created:

**Inline check 1 — canonical-filename validation.** The story file basename MUST match the canonical regex:

```
^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$
```

(epic-story key prefix, lowercase-hyphen slug, `.md` extension — the same shape `validate-canonical-filename.sh` enforces by computing `{key}-{slugify(title)}.md`). Run the on-disk validator as a cross-check when feasible:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-story/scripts/validate-canonical-filename.sh" --file "${story_file}"
```

**Inline check 2 — frontmatter required-fields check.** Every directly-written story MUST have all of these frontmatter fields present and non-empty (except where listed as nullable):

- Non-nullable: `template`, `version`, `used_by`, `key`, `title`, `epic`, `status`, `priority`, `size`, `points`, `risk`, `origin`, `origin_ref`, `date`, `author`
- Nullable: `sprint_id`, `priority_flag`
- Array (may be empty): `depends_on`, `blocks`, `traces_to`

**Inline check 3 — dedup check.** The new story `key` MUST NOT already appear in `.gaia/artifacts/planning-artifacts/epics-and-stories.md`:

```bash
grep -qE "(### Story ${new_story_key}:|^\\| ${new_story_key} \\|)" .gaia/artifacts/planning-artifacts/epics-and-stories.md && echo "DUPLICATE — aborting fallback"
```

Per saved-memory rule `feedback_triage_check_existing_stories.md`, three duplicate stories were created and retired in sprint-40 triage when this check was skipped.

**Audit-trail fields (AC3).** Stories authored via the fallback MUST carry these two frontmatter fields so post-hoc inspection can trace which stories bypassed `spawn-guard.sh`:

```yaml
spawn_fallback: "direct-write"
spawn_fallback_reason: "substrate-issue-49559"   # or "agent-tool-missing-from-fork", etc.
```

The `spawn_fallback_reason` value MUST name the specific trigger condition (substrate issue number, missing-tool name, malformed-spawn observation). This field stays on the story permanently — it is not removed once substrate issue #49559 is upstream-fixed.

### Step 5 --- Mark Findings as Triaged

In each source story's Findings table, append triage markers to processed findings. **The TRIAGED marker is a single source of truth** — its exact byte form is owned by `scripts/triaged-marker.sh` (`triaged_marker {key}` → `[TRIAGED -> {key}]`, ASCII `->`). The Step 5b tech-debt phase READS this same marker via `triaged_match_regex`; the glyph MUST be byte-identical between writer and reader (a Unicode-arrow drift silently breaks target validation — see Step 5b).

- CREATE STORY: append `[TRIAGED -> {new_story_key}]` to the Finding column (canonical ASCII `->` form — `triaged_marker {new_story_key}`)
- ADD TO EXISTING: append `[TRIAGED -> {existing_story_key}]` to the Finding column (`triaged_marker {existing_story_key}`)
- DISMISS: append `[DISMISSED]` to the Finding column

### Step 5b --- Tech-Debt Phase (rolling debt ledger)

After findings are triaged and marked (Step 5), run the **tech-debt phase** — the capability merged in from the retired `/gaia-tech-debt-review` skill. It aggregates, classifies, scores, and ages the project's technical debt into a rolling `tech-debt-dashboard.md`. The phase is non-interactive (no prompts) and writes a dashboard, mirroring the legacy auto-output contract.

**5b.1 — Scan debt candidates (reuse the S4 extractor — no second scanner).** For each story in the scan set (sprint-scoped by default, `--all` for the full sweep), extract candidates via the SAME `scripts/extract-findings.sh` used in Step 1 — the merged phase introduces NO new scanner. Read ONLY frontmatter + `## Findings` (token-budget mandate, inherited from the extractor).

**5b.2 — Validate triage targets (byte-identical marker read).** For every finding marked `[TRIAGED -> {target_key}]`, look up the target story's status by sourcing `scripts/triaged-marker.sh` and matching with `triaged_match_regex` (the SAME literal Step 5 wrote — this is the byte-equality contract, tested by the marker bats). Classify each target:
- target `done` → **STALE TARGET** (debt likely added after implementation — needs re-triage).
- target file missing / not a valid story key → **UNASSIGNED**.
- target in backlog / validating / ready-for-dev → **QUEUED**; in-progress → **IN PROGRESS**; in review → **IN REVIEW**.
- For every STALE TARGET, check the filesystem — if the referenced file/pattern no longer exists, mark **RESOLVED** and exclude from classification/scoring.

**5b.3 — Merge duplicates, then assign stable TD-{N} IDs.** Merge findings with the same root cause (same file/pattern + issue type) into one item with a source list `E{a}-S{b}, E{c}-S{d}` and tag `(merged from N findings)`. Merge BEFORE ID assignment. Then assign stable `TD-{N}` IDs via `scripts/td-id-assign.sh --dashboard {dashboard_path} --count {n}` — IDs persist across runs (read the previous dashboard's TD-{N} tokens; assign new IDs only to genuinely new items; NEVER renumber).

**5b.4 — Classify + score + age.** Classify each item DESIGN / CODE / TEST / INFRASTRUCTURE. Score by Impact + Risk − Effort. Compute aging against the current sprint.

**5b.5 — Emit the rolling dashboard.** Read the previous `tech-debt-dashboard.md` (if any) for the trend comparison, then write the merged result with a trend section (current totals vs previous). The dashboard is read-only output — no confirmation prompt.

**5b.6 — Action items route through the canonical writer (AC3).** Any action items the tech-debt phase produces MUST be written via the SAME canonical action-items writer the triage phase uses (`scripts/action-items-write.sh` → `aiw_write`, target `.gaia/state/action-items.yaml`). Do NOT inline-append to `planning-artifacts/action-items.yaml` (the legacy tech-debt-review path) — one authoritative tracker is used by both phases.

This phase replaces the standalone `/gaia-tech-debt-review` command; the slash command is retired to a deprecation redirect (see that skill's deprecation note). `/gaia-retro` continues to read `tech-debt-dashboard.md` unchanged.

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

### Step 7 — Persist to Val Sidecar

Final step. Delegates Val-decision persistence to the shared Val sidecar writer helper (`val-sidecar-write.sh`). Placing this last satisfies atomicity — any upstream failure (spawn-guard rejection, `/gaia-create-story` subagent failure, findings-table write error) short-circuits before the helper runs, so no partial sidecar entry can appear.

**Fail-closed enforcement.** This skill exports `GAIA_FINALIZE_SENTINEL_REQUIRED=1` before invoking `finalize.sh`. The finalize script asserts that `.gaia/memory/validator-sidecar/decision-log.md` was modified AFTER the run-started checkpoint marker; if not, it exits non-zero with the canonical error string `Val sidecar write missing — Step 7 must be invoked before finalize`. This mirrors the `gaia-add-feature/scripts/finalize.sh:51-82` fail-closed pattern — operators who skip Step 7 under heavy substrate load now see a hard halt at finalize instead of a silent skip.

Derive a deterministic `triage_session_id` of the form `triage-YYYY-MM-DD-<seq>`. The `<seq>` counter is a zero-padded monotonic index per day, computed by scanning existing triage markers in the current session's source stories:

```bash
today="$(date -u +%Y-%m-%d)"
seq="$(printf '%03d' "$(( $(ls .gaia/artifacts/implementation-artifacts/ 2>/dev/null | grep -c "^triage-${today}-" || echo 0) + 1 ))")"
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

The helper enforces the two-file allowlist and idempotency by composite `(command_name, input_id, decision_hash)` key — re-runs with identical payload yield `status=skipped_duplicate` and must be treated as success.

Failure posture: if the helper rejects or errors, log a warning and continue — memory persistence is best-effort and MUST NOT fail the skill.

## Changelog

- **2026-06-10 — Tech-debt phase merged in + canonical TRIAGED marker.** Added Step 5b (Tech-Debt Phase): the rolling `tech-debt-dashboard.md` capability — TD-{N} stable-ID ledger, DESIGN/CODE/TEST/INFRASTRUCTURE classification, Impact+Risk−Effort scoring, sprint-aging, STALE TARGET / UNASSIGNED / RESOLVED detection, duplicate merge, trend comparison — is merged in from the now-retired standalone `/gaia-tech-debt-review` command. The phase reuses the per-story `extract-findings.sh` (no second scanner) and `td-id-assign.sh` (copied into this skill's `scripts/`). The TRIAGED marker glyph is now a single source of truth in `scripts/triaged-marker.sh`: the canonical form is ASCII `[TRIAGED -> {key}]` (the form triage has always written); the merged tech-debt reader is aligned to it via `triaged_match_regex`, closing a Unicode-arrow-vs-ASCII glyph mismatch that would have silently matched zero triage targets. A bats test asserts writer/reader byte-equality. Action items from the tech-debt phase route through the canonical `action-items-write.sh` (`.gaia/state/action-items.yaml`), not the legacy inline append. `/gaia-retro` continues to read the dashboard unchanged.

- **2026-06-10 — Sprint-scoped default scan + deterministic Findings extractor.** Step 1 rewired: the default triage scan is now the active sprint's committed stories (resolved via `scripts/resolve-sprint-stories.sh` from `sprint-status.yaml`), with `--all` restoring the full historical sweep. Findings are extracted via `scripts/extract-findings.sh` (frontmatter + `## Findings` only — never the full story body), restoring the token-budget protection the skill previously lacked. The LLM no longer globs the implementation-artifacts tree or reads whole story files.

- **2026-05-15 — Fail-closed Val-sidecar sentinel in finalize.sh.** Step 7 prose updated to note that the skill exports `GAIA_FINALIZE_SENTINEL_REQUIRED=1` before invoking `finalize.sh`; the script asserts `_memory/validator-sidecar/decision-log.md` was modified AFTER the run-started checkpoint marker, and exits non-zero with the canonical error string `Val sidecar write missing — Step 7 must be invoked before finalize` when the assertion fails. Mirrors `gaia-add-feature/scripts/finalize.sh:51-82` fail-closed pattern. Sibling fix mirrored in `/gaia-retro`. Backward-compat preserved: legacy fixtures without the env var get the prior unconditional behavior.

- **2026-05-15 — Main-turn direct-write fallback.** Added the "Main-turn direct-write fallback" subsection inside Step 4 documenting the sanctioned escape hatch when `/gaia-create-story` spawn fails due to the broken `context:fork` substrate issue (Claude Code #49559 + saved-memory rule `feedback_plugin_context_fork_broken.md`). The subsection specifies three inline validation-equivalent checks (canonical-filename regex `^E[0-9]+-S[0-9]+-[a-z0-9-]+\.md$`, frontmatter required-fields enumeration, dedup grep against `epics-and-stories.md`) that stand in for the unrunnable `spawn-guard.sh verify/cleanup`, and mandates two audit-trail frontmatter fields (`spawn_fallback: "direct-write"` + `spawn_fallback_reason: "<trigger>"`) so post-hoc inspection can trace which stories bypassed the spawn-guard. The fallback subsection is also mirrored in `gaia-correct-course/SKILL.md`. Spawn is still the default — fallback is gated on explicit trigger conditions, not preemptive use.

- **2026-05-14 — Completion Notes deferral-drift scanner.** Added Step 1b that walks each story's `### Completion Notes List` via `lib/completion-notes-deferral-scan.sh` (which wraps `lib/deferral-phrase-match.sh`) and emits unmatched-deferral records as triage candidates. Triage output schema gains a new `source` column with values `findings-table` (the Step 1 default) or `completion-notes-deferral-scan` (Step 1b). Purely additive — existing consumers parsing by row/column ignore extra columns. Closes the deferral-drift class at the triage end (the Val end is covered by gaia-validation-patterns' new pattern).

## Finalize

```bash
GAIA_FINALIZE_SENTINEL_REQUIRED=1
```

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/finalize.sh
