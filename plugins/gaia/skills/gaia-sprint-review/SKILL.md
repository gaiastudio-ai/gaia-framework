---
name: gaia-sprint-review
description: Run an end-of-sprint review — two parallel tracks (Val text-validation + per-stack execution review), composite verdict, route the sprint to /gaia-sprint-close (PASSED), /gaia-correct-course (FAILED), or UNVERIFIED-bypass.
argument-hint: '[sprint-id]'
allowed-tools: [Read, Write, Edit, Bash]
orchestration_class: heavy-procedural
yolo_steps: []
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk -F': ' '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file (once per session under Mode A), mirror the cat'd warning verbatim as the FIRST user-visible text of your response.

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/setup.sh

## Mission

You are running the canonical end-of-sprint review ceremony introduced by E93. The sprint enters this skill at `status: active`; on the way out it routes to one of three outcomes:

- **PASSED** → handoff to `/gaia-sprint-close` (closes the sprint cleanly).
- **FAILED** → transition to `correction`, record findings as action-items, hand off to `/gaia-correct-course story_injection` for rework.
- **UNVERIFIED** → AI-2026-05-16-5 criteria bypass path (PM `AskUserQuestion` for explanation + second Val pass for justification-validation).

The verdict is **composite**: Track A (Val text-validation per the AI-2026-05-16-1 rubric) + Track B (per-stack foreground execution review) reduced via `scripts/compose-verdict.sh` per NFR-070 and ADR-108 D2.

**This skill MUST run as main-turn Mode A orchestration (NFR-067, T-SGR-6 mitigation, ADR-108 D3).** `AskUserQuestion` is invoked at three boundaries: Step 3 pre-Val dispatch confirmation, Step 4 per-goal Track B stakeholder confirmation, Step 8 PM explanation for UNVERIFIED bypass. Forked execution silently strips `AskUserQuestion`; the anti-pattern bats at `gaia-public/plugins/gaia/tests/gaia-sprint-review-mode-a-anti-pattern.bats` FAILs CI on any `context: fork` directive or stdout-sentinel token (`<<YIELD-STOP`, `<<TURN-END`) regression.

**Track B is a stub in E93-S3 (`delivered: false` per E88-S2 / FR-DPD-2).** The per-stack runner replacing the stub lands in E93-S4.

## Critical Rules

- A sprint's `goals:` field (added by E93-S1 to `sprint-status.yaml`) MUST be non-empty before Step 3 dispatches Val.
- All stories in the sprint MUST be `status: done` before `active → review` transition fires (Step 1 pre-condition gate).
- Story-level state machine is UNCHANGED — `done` remains terminal. Sprint-level transitions (`active → review → {closed, correction}`, `correction → active`) ride E93-S1's new edges.
- All `sprint-status.yaml` mutations route through `sprint-state.sh` subcommands (`set-goals`, `update-goals`, `set-review-justification`, transition). NO direct `yq -i` against `sprint-status.yaml` per NFR-071 / ADR-095 boundary-write discipline.
- Val is dispatched via the **main-turn Agent tool** (ADR-093 / ADR-104). The orchestrator writes the E87 envelope sentinel via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/write-val-envelope.sh` (orchestrator-side writer per ADR-105 / AI-2026-05-13-13), then asserts via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` before consuming the verdict.
- The E83 dispatch sentinel is written via `scripts/write-val-sentinel.sh` (mirrors `/gaia-add-feature/scripts/write-val-sentinel.sh` shape). `scripts/finalize.sh` validates the sentinel before allowing the skill to complete.
- `SPRINT_ID` MUST be exported before invoking `scripts/finalize.sh` so the sentinel guard can locate the dispatch sentinel.
- Action-items emitted on Step 7 FAILED path MUST use the canonical `sprint-correction` type (target_command: `/gaia-correct-course`) via the 11-type resolver at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-meeting/scripts/lib/type-target-resolver.sh`. Do NOT append YAML directly to `action-items.yaml` — that's the bypass anti-pattern documented in memory rule `feedback_action_items_writer_resolver_bypass.md`.
- The composite verdict reducer at `scripts/compose-verdict.sh` is the SINGLE source of truth for verdict-pair → composite mapping (NFR-070). Do not duplicate the logic in SKILL.md prose.

## Steps

### Step 1 — Pre-Condition Gate (active → review)

- Read `sprint-status.yaml` for the provided `$SPRINT_ID`. Scan the `stories[]` array.
- If ANY story has `status != done`, REFUSE with canonical stderr `gaia-sprint-review: refuse — <N> sprint stories are non-done (<list-of-keys>); complete or roll-over via /gaia-correct-course before invoking sprint-review`. The sprint stays at `status: active`. Exit non-zero.
- If `goals:` is empty or missing, REFUSE with canonical stderr `gaia-sprint-review: refuse — no sprint goals defined; run /gaia-sprint-plan with goals first`. Exit non-zero.
- When all-stories-done AND goals[] non-empty: proceed to Step 2.

### Step 2 — Transition active → review

Invoke E93-S1's boundary writer:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh transition --sprint "$SPRINT_ID" --to review
```

On non-zero exit, HALT with the sprint-state.sh stderr passthrough — the transition guard refused the edge. On success, `sprint-status.yaml` records `status: review` atomically (mktemp + mv).

Export `SPRINT_ID="<sprint_id>"` to the environment so `scripts/finalize.sh` can locate the sentinel later.

### Step 3 — Track A Val Dispatch (E83 + E87 dual-sentinel)

This is the canonical Val Bridge dispatch pattern (per ADR-093 / ADR-104 / ADR-105). It mirrors `/gaia-add-feature/SKILL.md` Step 2 — the only differences are the rubric path and the sentinel slug (`sprint-review-<sprint_id>-val-dispatched.json` vs `add-feature-<feature_id>-val-dispatched.json`).

#### Step 3a — AskUserQuestion precondition (substrate halt)

Before the Agent-tool dispatch, the LLM MUST emit an `AskUserQuestion` tool call presenting the sprint goals + the rubric path. The substrate halts the turn pending user input under Auto Mode — this is the empirically-verified primitive (per `feedback_askuserquestion_under_automode.md`) that closes the auto-mode self-judgment bypass class. The user's explicit acknowledgement is what unblocks the Val dispatch below.

The AskUserQuestion call is the SOLE interactive boundary primitive at Step 3 entry.

#### Step 3b — Val dispatch + dual-sentinel

Spawn a Val subagent via the **main-turn Agent tool** with:

- `subagent_type: gaia:validator`
- `model: claude-opus-4-7` (ADR-074 C2 opus pin)
- tool allowlist: `[Read, Grep, Glob, Bash, Write]`
- `artifact_path`: the literal `$SPRINT_ID` string (so caller + persona compute the same `sha256(artifact_path)` for the envelope-sentinel path)
- Rubric input: `${CLAUDE_PLUGIN_ROOT}/rubrics/base/sprint-review.json` (the AI-2026-05-16-1 deliverable). Val reads the rubric and applies its severity rules across 3 dimensions (story-to-goal traceability, velocity-vs-capacity fit, PRD priority coverage) to produce per-goal PASSED/FAILED/PARTIAL verdicts.
- **Sprint shape (E93-S6).** The optional top-level `sprint_shape:` field on `sprint-status.yaml` (enum `thrust` (default) | `completion-pass`) modifies the `sgr-velocity-003` incidental-goal floor. The floor scales inversely with the number of goals via `floor_pct = max(0.10, 0.30 * (4 / max(4, N)))` — a 2-goal thrust sprint keeps the 30% floor; a 7-goal sweep scales to ~17%. When `sprint_shape: completion-pass` is set, the rule's severity is reduced from High to Low for below-floor goals AND the `sgr-velocity-006` advisory fires exactly once with the scaled floor and goals-below count. Toggle via `sprint-state.sh set-shape --sprint <id> --shape <thrust|completion-pass>`. The deterministic evaluator at `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-evaluate.sh` is available to caller and Val for sgr-velocity-003 verdict mechanics.
- Intake: sprint-status.yaml (the sprint under review), the sprint's story files, the rubric.

Val returns the ADR-037 envelope `{ status, summary, artifacts, findings, next, sentinel_envelope }`. **Per ADR-105 / AI-2026-05-13-13 (orchestrator-side writer shift), Val does NOT write the sentinel itself.** The orchestrator:

1. Parses `sentinel_envelope` from Val's return.
2. Writes the E87 envelope sentinel via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/write-val-envelope.sh --envelope "$sentinel_envelope"` (captures the path on stdout).
3. Sources `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invokes `assert_agent_envelope <path>` to verify forgery resistance (NFR-064). On non-zero exit, HALT with the canonical error `HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at <path>`.
4. Writes the E83 dispatch sentinel via `scripts/write-val-sentinel.sh --sprint-id "$SPRINT_ID"` piped the Val ADR-037 return on stdin. The sentinel lands at `_memory/checkpoints/sprint-review-${SPRINT_ID}-val-dispatched.json`.
5. Applies the ADR-063 verdict-surfacing contract: display `status` + `summary` inline; HALT on CRITICAL before Track B fires; surface WARNING findings; log INFO findings.

When Val returns PASS or WARNING, capture the per-goal verdicts as Track A's composite. CRITICAL HALTS the skill — no Track B dispatch, no composite computation.

### Step 4 — Track B Execution Dispatch (E93-S3 STUB; E93-S4 ships the real runner)

Invoke the stub:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/track-b-dispatch.sh --sprint "$SPRINT_ID"
```

The stub reads `sprint_review:` from `config/project-config.yaml` (E93-S2 deliverable), iterates the per-stack matrix, and emits a JSON array — one element per configured stack with `verdict: SKIPPED, reason: "E93-S4 not yet shipped"`. This is the E88-S2 / FR-DPD-2 deferred-wiring contract; the story's frontmatter carries `delivered: false`.

#### Step 4a — Per-goal stakeholder confirmation (AskUserQuestion)

For each sprint goal, fire an `AskUserQuestion` at the main-turn caller level with the canonical 3-option set:

- `works-as-expected` — stakeholder confirms the goal was met.
- `fails-goal` — stakeholder rejects the goal as not met.
- `needs-rework` — stakeholder accepts the goal partially but flags follow-up.

Record the per-goal response into the sprint-review artifact. **This MUST run at the main turn**, not inside the forked Track B script — `AskUserQuestion` is not exposed inside forked skill executions (memory rule `feedback_askuserquestion_forked_skill_gap.md`).

Track B's composite verdict for E93-S3 is `SKIPPED` (the stub returns SKIPPED per stack). E93-S4 will replace this with the real per-stack runner — `verdict: PASSED|FAILED|UNVERIFIED` per stack, composed into Track B's composite.

### Step 5 — Compose Composite Verdict

Invoke the reducer:

```bash
COMPOSITE=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/compose-verdict.sh \
  --track-a "$TRACK_A_VERDICT" --track-b "$TRACK_B_VERDICT")
```

The reducer enforces NFR-070 / ADR-108 D2 rules:

- **PASSED** iff both tracks are PASSED (Track B SKIPPED on the E93-S3 stub path counts as PASSED-equivalent; PARTIAL on Track A does not block per FR-489 AC6).
- **FAILED** if either track is FAILED.
- **UNVERIFIED** if either track is UNVERIFIED and neither is FAILED.

Non-canonical inputs (e.g., a typo) are rejected at the script boundary with canonical stderr per ADR-074 C3.

### Step 6 — PASSED Path: Handoff to /gaia-sprint-close

When `$COMPOSITE` is `PASSED`:

1. Write the sprint-review artifact to `.gaia/artifacts/implementation-artifacts/sprint-review-${SPRINT_ID}-$(date +%Y-%m-%d).md`. Body: charter + goals[] + Track A Val verdict (with findings) + Track B per-stack output + per-goal stakeholder confirmations + composite verdict + handoff routing decision.
2. Emit the canonical handoff message to the user: `/gaia-sprint-review: composite verdict PASSED — sprint <id> ready to close; invoke /gaia-sprint-close to finalize`.

The actual `review → closed` transition is enforced by `/gaia-sprint-close` (E93-S5 scope) — this skill only emits the handoff. `/gaia-sprint-close` accepts the new edge AND validates the dispatch sentinel before writing `status: closed`.

### Step 7 — FAILED Path: correction + action-items + /gaia-correct-course

When `$COMPOSITE` is `FAILED`:

1. Transition the sprint:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh transition --sprint "$SPRINT_ID" --to correction
   ```

2. For each failed goal/scenario surfaced by Track A or Track B, emit an action-item entry via the canonical 11-type resolver:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/gaia-meeting/scripts/lib/type-target-resolver.sh sprint-correction
   # → /gaia-correct-course
   ```

   Use type `sprint-correction` (the canonical type for sprint-review-FAILED rework per ADR-086 / FR-MTG-20). One entry per failed goal/scenario, recorded in `.gaia/artifacts/planning-artifacts/action-items.yaml`. **Invoke the resolver script — do NOT append YAML directly** (memory rule `feedback_action_items_writer_resolver_bypass.md`).

3. Write the sprint-review artifact (same template as Step 6 — with composite verdict FAILED + the recorded findings).

4. Emit the canonical handoff: `/gaia-sprint-review: composite verdict FAILED — sprint <id> transitioned to correction; invoke /gaia-correct-course story_injection to inject rework stories, then re-run /gaia-sprint-review after the injected stories reach done`.

The `review → correction` edge acceptance + `story_injection` mechanics are in `/gaia-correct-course` (E93-S5 scope).

### Step 8 — UNVERIFIED Path: AI-2026-05-16-5 Bypass

When `$COMPOSITE` is `UNVERIFIED`:

1. Collect mechanical signals per AI-2026-05-16-5 (`.gaia/artifacts/planning-artifacts/sprint-review-unverifiable-criteria.md`):
   - `primary_criterion`: one of C1 (infra-only) / C2 (docs-only / planning-only) / C3 (deferred-implementation).
   - `qualifying_story_points`: sum of points matching the primary criterion.
   - `total_story_points`: sum of all completed story points.
   - `qualifying_ratio`: must be ≥ 0.80.
   - `qualifying_stories[]`: list of (key, criterion, points) triples.

2. Fire an `AskUserQuestion` to PM (Derek) requesting the `explanation` field — 200–1000 chars. The substrate halt enforces user input.

3. Persist the `review_justification:` block via the E93-S1 boundary writer:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh set-review-justification --sprint "$SPRINT_ID" --file <yaml-payload>
   ```

   The payload schema: `{ primary_criterion, qualifying_story_points, total_story_points, qualifying_ratio, explanation, qualifying_stories, pm_signoff: { pm_agent, signed_at }, val_validation: { status, rationale, validated_at } }`. Schema is validated by `sprint-state.sh` boundary writer.

4. Dispatch a second Val subagent for justification-validation (same dual-sentinel scheme as Step 3, but with the `review_justification:` payload as the validation artifact, NOT the rubric). Val validates that the criterion claims hold against ground truth (e.g., for C2, that no executable test surface exists).

5. On Val PASSED: emit the canonical handoff `/gaia-sprint-review: composite verdict UNVERIFIED — bypass APPROVED by PM + Val; invoke /gaia-sprint-close to finalize with the UNVERIFIED-bypass marker`. `/gaia-sprint-close` (E93-S5 scope) accepts the `review → closed` edge with the UNVERIFIED-bypass marker.

6. On Val FAILED: revert to the FAILED verdict path (Step 7) — record the justification-validation findings as action-items + transition to `correction`.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/finalize.sh

## References

- **ADR-108** (Proposed): sprint-level state machine + agent-assisted sprint review architecture (D1–D7 defining each step of this skill).
- **ADR-093**: orchestrator-as-bridge (main-turn Agent dispatch).
- **ADR-104**: Val Bridge — main-turn Agent dispatch + envelope-assert.
- **ADR-105**: orchestrator-side sentinel writer (writer shift; Val returns `sentinel_envelope`, orchestrator writes via `lib/write-val-envelope.sh`).
- **ADR-095**: sanctioned boundary writes via `sprint-state.sh` (no direct `yq -i` against `sprint-status.yaml`).
- **ADR-086**: action-items.yaml canonical registry + 11-type resolver.
- **ADR-074 C3**: no silent fallback in scripts.
- **ADR-067**: YOLO mode contract (this skill has `yolo_steps: []` — sprint review is an interactive ceremony only, NOT YOLO-able).
- **FR-488..FR-495**: the 8-step orchestration FRs.
- **NFR-067**: main-turn Mode A invariant (AskUserQuestion reachability).
- **NFR-069**: foreground-mode invariant (Track B enforced headed in E93-S4).
- **NFR-070**: composite verdict reduction rule (compose-verdict.sh single source of truth).
- **NFR-071**: boundary-write compliance for goals[] + review_justification.
- **T-SGR-6**: Mode A bypass mitigation (anti-pattern bats check).
- **AI-2026-05-16-1**: Val rubric at `rubrics/base/sprint-review.json`.
- **AI-2026-05-16-5**: un-reviewable criteria spec at `.gaia/artifacts/planning-artifacts/sprint-review-unverifiable-criteria.md`.
- **E93-S1**: sprint-state.sh boundary writers (`set-goals`, `update-goals`, `set-review-justification`, sprint-level transitions).
- **E93-S2**: `sprint_review:` config section + `/gaia-config-sprint-review` editor.
- **E93-S4** (deferred): Track B per-stack execution runner replacing the E93-S3 stub.
- **E93-S5** (deferred): `/gaia-sprint-plan` 3-lane goal approval + `/gaia-correct-course` review→correction edge + `/gaia-sprint-close` review→closed edge.
- **Memory rule `feedback_action_items_writer_resolver_bypass.md`**: action-items.yaml writes MUST route through the resolver script.
- **Memory rule `feedback_askuserquestion_forked_skill_gap.md`**: AskUserQuestion is not exposed inside forked skill executions.
