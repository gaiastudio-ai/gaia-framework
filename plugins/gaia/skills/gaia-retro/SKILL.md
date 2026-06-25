---
name: gaia-retro
description: "Facilitate a post-sprint retrospective capturing went-well, didn't-go-well, and action-items sections. Writes a retro artifact to .gaia/artifacts/implementation-artifacts/. GAIA-native replacement for the legacy retrospective XML engine workflow."
argument-hint: "[sprint-id?] [--auto-file?]"
allowed-tools: [Read, Write, Bash]
version: "1.0.0"
orchestration_class: conversational
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class conversational --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/setup.sh

## Mission

Facilitate a structured post-sprint retrospective by collecting team feedback across three sections (went well, what could improve, action items) and writing the resulting retro artifact to `.gaia/artifacts/implementation-artifacts/`. When an optional sprint-id argument is provided (e.g., `sprint-42`), use that sprint. Otherwise, resolve the current sprint from `.gaia/state/sprint-status.yaml`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/4-implementation/retrospective/` XML engine workflow. Follows the canonical SKILL.md shape.

## Critical Rules

- NEVER overwrite an existing retro artifact. If `retrospective-{sprint_id}-{date}.md` already exists, suffix a timestamp (e.g., `retrospective-{sprint_id}-{date}-{HHMM}.md`) rather than clobber.
- Retro artifacts are write-once per sprint. Once written, they are immutable records of the team discussion.
- The skill is conversational: prompt the facilitator for each section rather than auto-generating content from sprint state. Sprint data is used to seed the discussion, not replace it.
- Read sprint-status.yaml and story files as read-only context. NEVER modify sprint-status.yaml or story files during a retro.
- Action items MUST be concrete and actionable with assigned ownership — no vague aspirations.
- **YOLO posture.** `/gaia-retro` is a conversational ceremony; under YOLO it is NOT auto-completable because the went-well / could-improve / action-items inputs MUST come from the facilitator, not from the LLM (Critical Rule above). Unattended pipelines that need to close a sprint without retro discussion can pass `--yolo-defaults seed-from-metrics` to auto-populate the three sections from sprint-status.yaml metrics (velocity actual vs planned, blocked stories, carryover) — but the result is a SKELETON retro, not a substitute for the team discussion. The artifact is stamped with `auto_generated: true` in its frontmatter and the operator MUST flag the retro for the next live retro to revisit. This fallback exists only to unblock the close-the-sprint chain (sprint-close requires the retro doc); operators should treat the skeleton as a placeholder, not a record of decisions made.

## Steps

### Step 1 --- Resolve Sprint ID

If a sprint-id argument was provided, use it directly.

Otherwise, read `${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-status.yaml` and extract the current `sprint_id` from the top-level metadata.

If sprint-status.yaml is missing or unreadable, ask the user for the sprint ID.

### Step 1b --- Review Report Extraction

Extract verdicts and key findings from review artifacts for the resolved sprint. This produces a "data-driven findings" block that seeds Steps 3 and 4.

Invoke:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/review-extract.sh \
  --impl-dir "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
  --sprint-id "${sprint_id}"
```

The scanner globs `code-review-*.md`, `security-review-*.md`, `qa-tests-*.md`, and `performance-review-*.md`, filters to artifacts whose YAML frontmatter `sprint_id` matches the resolved sprint, and parses the `**Verdict:**` line from each. Malformed or truncated artifacts yield a `UNKNOWN` verdict with a `parse-warning` note (AC-EC4). When no artifacts match the current sprint, the scanner emits an explicit `no review artifacts for sprint {id}` note (AC-EC5) so prior-sprint review files do not leak into the current retro's findings.

Hold the scanner output in session memory — do NOT copy it verbatim into the final retro artifact. Surface it as context to the facilitator during Steps 3 and 4.

### Step 2 --- Load Sprint Data

Read `${CLAUDE_PROJECT_ROOT}/.gaia/state/sprint-status.yaml` to extract:
- All story keys for the resolved sprint
- Planned points and completed points
- Story statuses (done, in-progress, review, blocked, carried over)

For each story in the sprint, read its story file from `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/` to extract:
- Review Gate results (PASSED/FAILED/UNVERIFIED)
- Findings table entries
- Definition of Done status

Compute sprint metrics:
- Completion rate: done / total stories
- Velocity: delivered vs planned points
- First-pass review rate: stories that passed all reviews without rework
- Blocked stories count and list
- Carryover stories list

Present the sprint data summary to the facilitator as context before starting the discussion.

### Step 3 --- What Went Well

Present data-driven positive findings from the sprint metrics:
- Stories that passed all 6 reviews on first try
- Velocity met or exceeded plan
- Stories with no review rework
- Good dependency management (no blocks or blocks resolved quickly)

Then prompt the facilitator:

> Based on the data above, what else went well this sprint? Add items, confirm the data-driven findings, or modify them.

Collect the facilitator's input and compile the final went-well list.

### Step 4 --- What Could Improve

Present data-driven improvement areas from the sprint metrics:
- Stories that failed reviews and cycled back
- Untriaged findings still in story files
- Blocked stories and their duration
- Carryover stories not completed
- Common code review feedback patterns

Then prompt the facilitator:

> Based on the data above, what else could improve? Add items, confirm the data-driven findings, or modify them.

Collect the facilitator's input and compile the final improvements list.

### Step 5 --- Action Items (structured YAML write)

For each improvement area identified in Step 4, propose a concrete action item with:
- Description of the action
- Owner (team member or role responsible)
- Target sprint for completion
- Priority (high for recurring issues, medium for new items)

Prompt the facilitator:

> Review the proposed action items. Add, remove, or modify items. Each action item needs an owner and target sprint.

Collect the facilitator's input and compile the final action items list, then persist each item to `${CLAUDE_PROJECT_ROOT}/.gaia/state/action-items.yaml` using the shared retro writer helper. The YAML schema is authoritative. This path is the canonical action-items.yaml home, resolved via `resolve-artifact-path.sh action_items` (rung 1: `.gaia/state/action-items.yaml`, read-compat fallback: `.gaia/artifacts/planning-artifacts/action-items.yaml`). All producers and consumers now agree on the state-tier location.

Per-item payload (one YAML list element per action):

```yaml
- id: AI-{auto-inc}
  sprint_id: "{sprint_id}"
  text: "{action text}"
  classification: clarification|implementation|process|automation
  status: open
  escalation_count: 0
  created_at: "{ISO 8601 timestamp}"
  theme_hash: "sha256:{hex of lowercase(trim(text))}"
```

Invoke the shared writer once per action item:

```bash
${CLAUDE_PLUGIN_ROOT}/../../scripts/retro-sidecar-write.sh \
  --root       "${CLAUDE_PROJECT_ROOT}" \
  --sprint-id  "${sprint_id}" \
  --target     "${CLAUDE_PROJECT_ROOT}/.gaia/state/action-items.yaml" \
  --payload    "$(emit_action_item_yaml)"
```

Failure posture:

- Missing `.gaia/state/action-items.yaml` → writer seeds the file with the canonical schema header before appending (AC-EC3).
- Malformed existing YAML → writer HALTs with a line-pointer error; fix the YAML manually and re-run (AC-EC3).
- Dedup by stable `AI-{n}` ID when the prose retro already referenced an item — in-place `text` update rather than duplicate row (AC-EC8).
- `flock` on the YAML file serializes auto-increment across concurrent writers (AC-EC9).

The prose retrospective artifact written in Step 6 references each item by `AI-{n}` ID rather than duplicating text — `.gaia/state/action-items.yaml` is the source of truth.

#### Step 5b --- Optional auto-file pass (opt-in via `--auto-file`)

After Step 5 persists all action items, check the skill arguments for the literal token `--auto-file`. Default is OFF — when the flag is absent, this step is a no-op and the skill proceeds to Step 5c verbatim.

When `--auto-file` IS present:

1. For each action item appended in Step 5 with an eligible `type` value (per the design note at `.gaia/artifacts/planning-artifacts/retro-auto-file-design.md`: `feature`, `new-story`, `bug`, `enhancement`, `automation`), synthesise an `/gaia-add-feature --text "<text>"` invocation (for everything except `new-story`) or `/gaia-create-story` (for `new-story` with the operator-confirmed bucket).
2. **AC-EC7 invariant:** every invocation goes through the destination skill's classification confirmation gate (`AskUserQuestion` bucket prompt). Auto-file means "auto-spawn the gate", NOT "auto-bypass it". The operator confirms each bucket as if they had run the filing skill manually.
3. Items with ineligible `type` (`tech-debt`, `process`, `clarification`, `planning`, `investigation`, `escalation`) are skipped — they do not produce stories. The rubric is the design note's eligibility table.
4. Items written via the v1 dual-schema path (i.e., entries with `classification` rather than `type`) are NEVER auto-filed — v1 entries are read-only by `/gaia-action-items` per the dual-schema routing rules, and the same read-only invariant applies here.
5. On any per-item failure (filing skill non-zero exit, bucket-prompt cancellation, substrate gap on subagent dispatch), log the failure to the retro prose artifact's `## Auto-file outcomes` section. The retro itself proceeds — the failure is informational, not blocking.

**Substrate-driven limitation (per saved memory `feedback_askuserquestion_forked_skill_gap` + `feedback_plugin_context_fork_broken`):** the cross-skill subagent dispatch path for `/gaia-add-feature` and `/gaia-create-story` is currently lossy for interactive prompts. Until the upstream substrate gap closes (Claude Code issue #49559), the auto-file branch logs an `auto_file: substrate-deferred — no spawn` line for each eligible item and writes the synthesised `--text` payload to `.gaia/state/action-items.yaml`'s `auto_file_queued` field so a follow-up `/gaia-action-items --auto-file` invocation can drain the queue at next-sprint planning. This is a documented bridge mechanism, not silent failure.

### Step 5c --- Agent Memory Updates

After Step 5 completes, persist the sprint's lessons to each of the six canonical agent memory sidecars so the next sprint's planning and dev agents carry the institutional memory forward. Writes go through the shared retro writer helper which enforces the allowlist, idempotency, and atomic backup/verify.

Target sidecars (six fan-out, one entry per agent per sprint):

1. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/architect-sidecar/decision-log.md` — architecture-level lessons.
2. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/test-architect-sidecar/decision-log.md` — test strategy lessons.
3. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/security-sidecar/decision-log.md` — security findings.
4. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/devops-sidecar/decision-log.md` — deployment / pipeline lessons.
5. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/sm-sidecar/decision-log.md` — process lessons.
6. `${CLAUDE_PROJECT_ROOT}/.gaia/memory/pm-sidecar/decision-log.md` — stakeholder / prioritization lessons.

For each sidecar, compose a payload in the canonical decision-log format tagged with the sprint ID, then invoke:

```bash
${CLAUDE_PLUGIN_ROOT}/../../scripts/retro-sidecar-write.sh \
  --root       "${CLAUDE_PROJECT_ROOT}" \
  --sprint-id  "${sprint_id}" \
  --target     "${CLAUDE_PROJECT_ROOT}/.gaia/memory/${agent}-sidecar/decision-log.md" \
  --payload    "$(emit_lesson ${agent})"
```

Failure posture:

- Missing sidecar file → writer creates the parent dir and seeds the canonical decision-log header before appending (AC-EC2).
- Re-run for the same sprint → composite dedup key (`sprint_id + sha256(payload)`) causes the writer to return `skipped_idempotent`; sidecar is byte-identical (AC2).
- Partial fan-out failure (e.g., one sidecar is read-only) → the failing sidecar is restored from `.bak`; already-successful sidecars keep their appended entry (they are valid organizational memory); retro halts before proceeding to Step 5d (AC-EC7).
- Symlink bypass attempt → writer resolves via `realpath` before the allowlist check and rejects with `status=unauthorized` (AC-EC5).

### Step 5d --- Velocity Data Persistence

Append a velocity row to `${CLAUDE_PROJECT_ROOT}/.gaia/memory/sm-sidecar/velocity-data.md`. This runs **unconditionally** on every retro invocation — it is the velocity mandate. Idempotency key is `sprint_id` alone (one row per sprint).

Payload schema:

```
| Planned points   | {planned}   |
| Completed points | {completed} |
| Story count (done)     | {done_count}     |
| Story count (rollover) | {rollover_count} |
| Velocity %             | {pct}            |
```

Invocation:

```bash
${CLAUDE_PLUGIN_ROOT}/../../scripts/retro-sidecar-write.sh \
  --root       "${CLAUDE_PROJECT_ROOT}" \
  --sprint-id  "${sprint_id}" \
  --target     "${CLAUDE_PROJECT_ROOT}/.gaia/memory/sm-sidecar/velocity-data.md" \
  --payload    "$(emit_velocity_row)"
```

Failure posture:

- Missing sprint ID → writer exits with `status=missing_sprint_id` and a non-zero code; prior Step 5c sidecar entries are NOT rolled back (they are valid memory), but the retro halts before Step 5 / Step 7 so no partial action-items / validator state lands (AC-EC4).
- Second retro invocation for the same sprint → writer sees the existing `### Sprint {id}` row and returns `skipped_idempotent`; velocity-data.md is byte-identical (AC2).
- Missing file → writer creates and seeds with the canonical "SM Velocity Data" header before appending (AC-EC2).

### Step 5e --- Tech Debt Reflection

Read `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/tech-debt-dashboard.md` and extract a Tech Debt Reflection block for the retro artifact. This step is **read-only** — it MUST NOT modify the dashboard file.

Invoke:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
extract_tech_debt_reflection "${CLAUDE_PROJECT_ROOT}" "${sprint_id}"
```

The function extracts:
- **Debt ratio delta:** current sprint vs. prior sprint (percentage change)
- **Aging delta:** mean age of open debt items (days change)
- **Category breakdown:** architecture, code, test, documentation, process (count and delta per category)

Hold the output in session memory for inclusion in the retro artifact at Step 6.

Failure posture:

- Missing `tech-debt-dashboard.md` → renders "No tech debt data available" note and retro continues without failing (AC-EC1).
- Malformed dashboard (ratio/aging/categories unparseable) → logs a warning to retro Dev Notes, skips extraction, and writes "tech-debt reflection unavailable: {reason}" without halting (AC-EC2).
- First sprint (no prior dashboard snapshot to diff against) → ratio/aging deltas render as "baseline" markers; category breakdown uses absolute counts; no divide-by-zero (AC-EC3).
- Older-format dashboard without category breakdown → renders ratio/aging blocks and emits "category breakdown unavailable (older dashboard format)" rather than failing (AC-EC10).
- Dashboard file byte-identical after step completes (read-only contract).

### Step 5b --- Cross-Retro Pattern Detection

After action items are drafted in Step 5, scan prior retrospective files for recurring themes. Themes appearing in 2+ distinct sprints are flagged systemic, and their parent `.gaia/state/action-items.yaml` entry receives an `escalation_count` increment.

Invoke:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/cross-retro-detect.sh \
  --retros-dir     "${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts" \
  --action-items   "${CLAUDE_PROJECT_ROOT}/.gaia/state/action-items.yaml" \
  --current-sprint "${sprint_id}"
```

The scanner:

1. Globs `retrospective-*.md` under the retros dir.
2. Extracts action-item lines under `## Action Items` sections (or resolves `AI-{n}` references in `.gaia/state/action-items.yaml`).
3. Normalizes each line (`lowercase(trim(text))`) and computes `SHA-256(norm)`.
4. Flags themes seen in 2+ distinct sprint IDs as systemic.
5. For each systemic theme, delegates to `action-items-increment.sh` using `(current_sprint, theme_hash)` as the idempotency key so re-running the same retro never double-increments.

All edge paths are non-blocking (per the story's "Failure posture"):

- No prior retros → success, zero escalations (AC3 / AC-EC9).
- Missing or unreadable `.gaia/state/action-items.yaml` → warn on stderr, continue (AC-EC2).
- Orphan `AI-{n}` reference → log orphan, skip that item, continue (AC-EC6).
- Empty / zero-byte retro file → contributes zero themes (AC-EC9).
- Mixed-case or whitespace variants → normalize to the same hash (AC-EC10).
- 100+ prior retros → bounded per-file read (`MAX_BYTES=65536`) caps token usage.

> **Note (delegation):** `action-items-increment.sh` sources the canonical shared retro writer (`gaia-framework/plugins/gaia/scripts/retro-sidecar-write.sh`) for allowlist enforcement and path resolution. The CLI contract is unchanged — callers in this skill do not need to be updated.

> **Adversarial-findings input:** when adversarial reviews (`/gaia-adversarial`, Sage) ran during the sprint, their findings are eligible pattern-detection input — a finding title recurring across 2+ sprints is a systemic theme. **Read the structured `.json` sidecar, not the prose.** For each `adversarial-review-<target>-<date>[-N].md` under `.gaia/artifacts/planning-artifacts/adversarial/`, resolve the structured fields through the shared reader helper — never re-inline a `.md` regex-parse:
>
> ```bash
> ${CLAUDE_PLUGIN_ROOT}/scripts/lib/read-adversarial-sidecar.sh \
>   --md-path "<.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-*.md>"
> ```
>
> The helper **prefers** the `.json` sidecar (jq-extracted `findings[].title`, prefix `source=json`) and **falls back** to a `.md` regex-parse when the sidecar is absent (older reports, prefix `source=md`) — additive, back-compatible. Normalize each `finding=` title into the same `lowercase(trim)` + `SHA-256` theme key the scanner uses, so an adversarial finding and a manually-written retro item describing the same theme collapse to one systemic theme.

### Step 5f --- Skill Improvement Proposals

Map each retro finding from Steps 3-4 to existing shared skills by scanning `${CLAUDE_PLUGIN_ROOT}/skills/` and `${CLAUDE_PROJECT_ROOT}/custom/skills/` registries. For each matched finding, build a structured proposal object per the canonical proposal schema.

Invoke:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
build_proposal "${finding_ref}" "${target_skill}" "${rationale}" "${diff_text}"
```

**Stage 1: Proposal.** The proposal is a structured YAML object held in-session:

```yaml
proposal:
  finding_ref: "retro-{sprint_id}-finding-{n}"
  target_skill: "{skill-name}"
  target_path: "custom/skills/{skill-name}.md"
  rationale: "Sprint {N} retro found {theme} ..."
  diff: |
    + ## New Section
    + ...
```

**Stage 2: Approval.** Present each proposal to the user for interactive approval. YOLO auto-approve is explicitly out of scope. For each proposal:
- Display the target skill, rationale, and diff preview
- If `target_path` already exists with divergent content, present a merge-preview diff and require explicit overwrite confirmation (AC-EC6)
- Wait for user approval or rejection

**Stage 3: Write.** Only upon explicit user approval, delegate to the shared retro writer:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/skill-proposal.sh"
write_approved_proposal \
  "${CLAUDE_PROJECT_ROOT}" \
  "${sprint_id}" \
  "${target_skill}" \
  "custom/skills/${target_skill}.md" \
  "${rationale}" \
  "${diff_content}" \
  "${CLAUDE_PLUGIN_ROOT}/../../scripts/retro-sidecar-write.sh"
```

The function:
1. Writes `custom/skills/{skill-name}.md` with the proposed content via the shared writer
2. Registers the `skill_overrides` entry in `custom/skills/all-dev.customize.yaml` via the shared writer
3. The plugin loader reads `custom/skills/` with higher precedence than bundled skills

**Hard constraint:** Proposals MUST NOT write to `plugins/gaia/skills/` directly. The retro writer's allowlist rejects any such path with `status=unauthorized` (AC-EC8).

Failure posture:

- Finding maps to multiple existing skills → `target_skill` field is a list of candidates; user selects one at approval; non-selected candidates produce no writes (AC-EC4).
- Finding maps to NO existing skill → Step 5f yields zero proposals for that finding; retro Dev Notes record "no skill match for finding #{n}"; no error (AC-EC5).
- Pre-write validation rejects proposals whose diff is non-UTF-8 or > 100 KB with an explicit error; proposal remains in session for editing (AC-EC11).
- Missing `.customize.yaml` → writer seeds the file with canonical header before registering the `skill_overrides` entry; no error (AC-EC7).
- Proposal write path attempts `gaia-framework/plugins/gaia/skills/` bypass → shared retro writer rejects via the allowlist; retro halts with authorization error; `plugins/gaia/skills/` byte-identical (AC-EC8).
- User rejects a proposal → clear session cache; zero filesystem writes; rejection logged in retro artifact's "Proposals" section as `{finding_ref}: REJECTED` (AC4, AC-EC9).
- Concurrent retro invocations each approve targeting same file → `flock` serializes; second writer re-presents a fresh merge preview (AC-EC12).

### Step 5g --- Brain Lesson Emission

After all sidecar fan-out completes, emit each lesson learned in the
retrospective as a first-class `lesson` brain entry to
`.gaia/knowledge/brain-index.yaml`. This is **additive** — the existing
per-agent sidecar fan-out (Step 5c) is preserved unchanged. Brain lesson
emission writes to the knowledge layer so durable sprint lessons become
queryable governance knowledge rather than per-agent notes alone.

Each lesson carries a category tag from the closed set: `strategy`,
`writing-rule`, `doc-maintenance-obligation`, `anti-pattern`,
`tool-constraint`. Unknown categories are rejected.

The `expires_at` field defaults to `null` (no expiry). An explicit
sprint-specific expiry is honoured when set.

Invoke:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/emit-brain-lessons.sh \
  --sprint-id  "${sprint_id}" \
  --retro-artifact "${retro_artifact_path}" \
  --project-root "${CLAUDE_PROJECT_ROOT}" \
  --category "${category}" \
  --synopsis "${synopsis}"
```

Or in batch mode for all lessons at once, pass a `--lessons-yaml` file with a
list of `{category, synopsis}` objects.

Failure posture:

- Unknown category tag in the closed set -> emitter exits non-zero; no partial write to the manifest.
- Missing or empty path -> rejected with non-zero exit; manifest unchanged.
- Confidence out of range or missing source_type -> rejected; no partial write.
- Missing `.gaia/knowledge/` directory -> created automatically (`mkdir -p`).
- Missing brain-index.yaml -> seeded with `schema_version: 1` and `entries: []` header before appending.

### Step 6 --- Write Retro Artifact

Compose the retrospective artifact with the following sections:
- Sprint metadata (sprint_id, date, velocity, completion rate)
- What Went Well (from Step 3)
- What Could Improve (from Step 4)
- Bypasses (render between "What Went Well" and "Action items"; consume `lifecycle_list_bypasses_for_sprint "$SPRINT_ID" --format json` from `scripts/lib/lifecycle-overrides.sh` and render one `- **<skill>** — <reason> (recorded by <recorded_by> at <recorded_at>)` row per bypass. Empty state: emit the single line `No bypasses recorded for sprint-<id>.` Preserve the section heading even when empty so retro readers see a consistent template across sprints.)
- Action Items (from Step 5)
- Tech Debt Reflection (from Step 5e)
- Skill Improvement Proposals (from Step 5f — approved, rejected, and skipped proposals)

Determine the output file path:
- Default: `${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/retrospective/retrospective-{sprint_id}-{YYYY-MM-DD}.md`
- If that file already exists: use `retrospective-{sprint_id}-{YYYY-MM-DD}-{HHMM}.md` (still under the nested `retrospective/` directory) to avoid clobbering

Before writing, run `mkdir -p ${CLAUDE_PROJECT_ROOT}/.gaia/artifacts/implementation-artifacts/retrospective/` so the nested directory exists on first run.

Write the artifact to the determined path.

Report the output path to the facilitator.

### Step 7 --- Val Memory Persistence

Final step. After the retro artifact is written, persist the retro's decisions and rolling context to the validator sidecar so Val can cross-reference retro outcomes in subsequent validations. This delegation is made concrete by invoking the shared Val sidecar writer helper (`val-sidecar-write.sh`). The helper's two-file allowlist and composite-key idempotency apply uniformly. Placing the helper invocation as the FINAL step satisfies AC3 atomicity — any upstream failure short-circuits before the helper runs, so no partial sidecar entry can appear.

**Fail-closed enforcement.** This skill exports `GAIA_FINALIZE_SENTINEL_REQUIRED=1` before invoking `finalize.sh`. The finalize script asserts that `.gaia/memory/validator-sidecar/decision-log.md` was modified AFTER the run-started checkpoint marker; if not, it exits non-zero with the canonical error string `Val sidecar write missing — Step 7 must be invoked before finalize`. Mirrors the sibling fail-closed guards in `/gaia-triage-findings` and `/gaia-add-feature`.

Targets (enforced by the helper allowlist — no other paths are writable):

- `${CLAUDE_PROJECT_ROOT}/.gaia/memory/validator-sidecar/decision-log.md` — append one decision-log-formatted entry per retro (sprint-ID tagged).
- `${CLAUDE_PROJECT_ROOT}/.gaia/memory/validator-sidecar/conversation-context.md` — refresh the rolling body with a one-line summary of the current retro.

Build the decision payload as `{verdict, findings[], artifact_path}` — the `findings[]` list holds the action-item IDs produced in Step 5 sorted by id; `artifact_path` is the retro artifact written in Step 6.

Invoke the helper (a single call writes both allowlisted targets atomically under a composite dedup key):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/val-sidecar-write.sh \
  --command-name "/gaia-retro" \
  --input-id     "${sprint_id}" \
  --sprint-id    "${sprint_id}" \
  --decision-payload "$(jq -cn \
    --arg verdict       "${verdict:-recorded}" \
    --arg artifact_path "${retro_artifact_path}" \
    --argjson findings  "${action_items_json:-[]}" \
    '{verdict: $verdict, findings: $findings, artifact_path: $artifact_path}')"
```

Re-runs with identical payload yield `status=skipped_duplicate` and must be treated as success.

Failure posture:

- Missing `.gaia/memory/validator-sidecar/` directory → the shared helper creates the directory and seeds both files with canonical decision-log headers before the first append (AC-EC10).
- Degraded-mode running: if Step 5c / 5d / 5 failed earlier, Step 7 still runs so the validator sidecar records the partial-success outcome — retro mandate.
- Helper rejection or error → log a warning and continue. Memory persistence is best-effort and MUST NOT fail the skill (non-blocking).

> **Note.** This Step 7 invocation was retargeted from `retro-sidecar-write.sh` to `val-sidecar-write.sh` to realize the shared-Val-sidecar delegation. Other retro writes (action-items, skill_overrides proposals) continue to use `retro-sidecar-write.sh` — only the two validator-sidecar targets route through the shared Val helper here.

## Changelog

- **2026-05-15 — Opt-in `--auto-file` flag for retro action items.** Added Step 5b (between Step 5 and Step 5c) describing the opt-in `--auto-file` flag that walks action items at retro close and auto-spawns `/gaia-add-feature` (for `feature`/`bug`/`enhancement`/`automation` types) or `/gaia-create-story` (for `new-story`). The AC-EC7 classification confirmation gate is preserved — auto-file means "auto-spawn the gate prompt", not "auto-bypass it". Default is OFF. Eligibility rubric in `.gaia/artifacts/planning-artifacts/retro-auto-file-design.md`. Substrate-gap-deferred subagent dispatch path is documented in the same design note; full cross-skill spawn lands once the upstream Claude Code substrate fix closes (#49559).

## Refs

- `.gaia/artifacts/planning-artifacts/retro-auto-file-design.md` — design note (eligibility rubric + AC-EC7 interaction + Option-B rationale)
- Saved memory: `feedback_askuserquestion_forked_skill_gap` — substrate constraint on subagent interactive prompts
- Saved memory: `feedback_no_inline_meeting_stories` — `/gaia-meeting` precedent for routing action items via `/gaia-add-feature`
- action-items.yaml dual-schema routing

## Finalize

```bash
GAIA_FINALIZE_SENTINEL_REQUIRED=1
```

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-retro/scripts/finalize.sh

## Mode B Readiness

> **Driving teammate turns (MANDATORY under team orchestration).** Declaring
> readiness above sets up the spawn / relay / shutdown bookkeeping seams — it does
> NOT by itself drive a teammate. When `SESSION_MODE == team`, the orchestrator
> MUST drive each teammate turn per the canonical **Mode B teammate round-trip
> contract** at `knowledge/mode-b-round-trip-contract.md`: emit a real
> `SendMessage(to: <handle>)` whose message ends with the reply-routing reminder,
> let the teammate reply via `SendMessage(to: team-lead)` (one-shot re-prompt on
> idle-without-reply; never fabricate the reply), then relay the received body to
> the transcript / artifact. The bridge functions named above are bookkeeping
> only; the round-trip itself is an orchestrator-driven, main-turn loop.
>
> **No discretionary Mode A fall-through.** The team-mode round-trip is mandatory
> when the session resolves to team orchestration — "it is a small / focused /
> quick step" is NOT a license to fall back to one-shot Mode A, and a slow reply
> is the cross-turn-boundary case (wait or re-prompt once), not a fallback
> trigger. The ONLY legitimate fall-through is a real `MODE_B_FALLBACK` token
> emitted by the bridge at spawn time (substrate genuinely unavailable).

This conversational skill is Mode B-ready. Under Mode B (opt-in: persistent
teammates), participant dispatch routes through the shared dispatch library
at `scripts/lib/dispatch-teammate.sh` via the conversational bridge at
`scripts/lib/conversational-mode-b-bridge.sh`. Each participant is spawned
with `conversational_spawn_participant`, which obtains a long-lived teammate
handle, enforces the reviewer clean-room invariant, and logs dispatch
provenance. Turn output is relayed verbatim to the session transcript, so the
artifact structure (transcript and synthesis) is byte-for-byte the same as
Mode A.

When the Mode B substrate is absent — the default in this build — the shared
library degrades to Mode A foreground dispatch and emits a single
machine-parseable `MODE_B_FALLBACK` token to stderr. Existing Mode A behavior
is preserved unchanged; Mode B is attempted only when the substrate is live.

**Shutdown discipline.** Every spawned participant MUST be cleaned up at skill
completion. Wire `trap conversational_shutdown EXIT` around the participant
loop; `conversational_shutdown` delegates to `shutdown_all` in the shared
library, which sweeps every active teammate and leaves no orphaned session.
