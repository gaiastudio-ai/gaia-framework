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
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file (once per session under Mode A), mirror the cat'd warning verbatim as the FIRST user-visible text of your response.

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh validator all

## Mission

You are running the canonical end-of-sprint review ceremony. The sprint enters this skill at `status: active`; on the way out it routes to one of three outcomes:

- **PASSED** → handoff to `/gaia-sprint-close` (closes the sprint cleanly).
- **FAILED** → transition to `correction`, record findings as action-items, hand off to `/gaia-correct-course story_injection` for rework.
- **UNVERIFIED** → un-reviewable-criteria bypass path (PM `AskUserQuestion` for explanation + second Val pass for justification-validation).

The verdict is **composite**: Track A (Val text-validation per the per-goal rubric) + Track B (per-stack foreground execution review) reduced via `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/compose-verdict.sh`.

> **Path disambiguation.** Throughout this SKILL.md, bare `scripts/...` references resolve to the **skill-relative** path `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/`, NOT the shared plugin root `${CLAUDE_PLUGIN_ROOT}/scripts/`. Operators hand-driving the unattended-mode pattern who resolve `scripts/` to the shared root will hit "No such file or directory" on `compose-verdict.sh`, `write-val-sentinel.sh`, and `finalize.sh` — all of which live ONLY at the skill-relative location. Every reference below uses the fully-qualified form; treat the convention as binding when authoring follow-ups.

**This skill MUST run as main-turn Mode A orchestration.** `AskUserQuestion` is invoked at three boundaries: Step 3 pre-Val dispatch confirmation, Step 4 per-goal Track B stakeholder confirmation, Step 8 PM explanation for UNVERIFIED bypass. Forked execution silently strips `AskUserQuestion`; the anti-pattern bats at `gaia-framework/plugins/gaia/tests/gaia-sprint-review-mode-a-anti-pattern.bats` FAILs CI on any `context: fork` directive or stdout-sentinel token (`<<YIELD-STOP`, `<<TURN-END`) regression.

**Track B is a stub today (`delivered: false`).** The per-stack runner replacing the stub lands in a later story.

## Operator Quickstart

Run the end-of-sprint review ceremony. Track A dispatches Val with the per-goal rubric; Track B re-runs the configured per-stack execution review (stub today, real runner soon). The two compose into a single verdict that routes the sprint to close (PASSED), correction (FAILED), or the bypass path (UNVERIFIED).

**First-time invocation.**

```
/gaia-sprint-review sprint-12
```

This validates the pre-conditions (all stories done, goals non-empty), transitions the sprint from `active` to `review`, dispatches Val + Track B, asks you for per-goal stakeholder confirmation, composes the composite verdict, and emits the routing handoff. The sprint-review artifact lands at `.gaia/artifacts/implementation-artifacts/sprint-review/sprint-review-<sprint_id>-<date>.md`.

**When to use which option.**

| Composite verdict you receive | Run next                                          |
|-------------------------------|---------------------------------------------------|
| PASSED                        | `/gaia-sprint-close <sprint-id>`                  |
| FAILED                        | `/gaia-correct-course story_injection` then re-run sprint-review |
| UNVERIFIED (bypass approved)  | `/gaia-sprint-close <sprint-id>` (carries the UNVERIFIED-bypass marker) |
| UNVERIFIED (bypass rejected)  | Same as FAILED path                               |

**Common gotchas.**

- Not all stories `done` -- the Step 1 gate REFUSES with the canonical "N sprint stories are non-done" stderr; complete the work or roll it over first.
- `goals[]` empty -- the rubric is per-goal; run `sprint-state.sh set-goals` before invoking.
- NOT YOLO-able by design -- the three `AskUserQuestion` boundaries (Steps 3a, 4a, 8) are deliberate human-judgment gates. **Fallback:** unattended pipelines can pass `--yolo-defaults work-as-expected` to auto-answer Step 4a per-goal stakeholder confirmation with `work-as-expected` for every goal. Step 3a (pre-Val dispatch) still requires user acknowledgement under Auto Mode (the substrate-enforced halt cannot be bypassed via skill flag — see `feedback_askuserquestion_under_automode.md`). Step 8 (UNVERIFIED bypass PM explanation) likewise stays interactive; `--yolo-defaults` skips that branch by REFUSING the bypass and routing UNVERIFIED → FAILED. The fallback is documented but logged with a WARNING in the sprint-review artifact so operators see when stakeholder confirmation was elided. For full unattended automation, the recommended pattern remains: script `sprint-state.sh transition --sprint <id> --to review` + write the sprint-review artifact + dispatch sentinel directly, bypassing this skill (the manual workaround pattern).

## Critical Rules

- A sprint's `goals:` field (in `sprint-status.yaml`) MUST be non-empty before Step 3 dispatches Val.
- All stories in the sprint MUST be `status: done` before `active → review` transition fires (Step 1 pre-condition gate).
- Story-level state machine is UNCHANGED — `done` remains terminal. Sprint-level transitions (`active → review → {closed, correction}`, `correction → active`) ride the sprint-level edges.
- All `sprint-status.yaml` mutations route through `sprint-state.sh` subcommands (`set-goals`, `update-goals`, `set-review-justification`, transition). NO direct `yq -i` against `sprint-status.yaml` per boundary-write discipline.
- Val is dispatched via the **main-turn Agent tool**. The orchestrator writes the envelope sentinel via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/write-val-envelope.sh` (orchestrator-side writer), then asserts via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` before consuming the verdict.
- The dispatch sentinel is written via `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/write-val-sentinel.sh` (mirrors `${CLAUDE_PLUGIN_ROOT}/skills/gaia-add-feature/scripts/write-val-sentinel.sh` shape). `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/finalize.sh` validates the sentinel before allowing the skill to complete.
- `SPRINT_ID` MUST be exported before invoking `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/finalize.sh` so the sentinel guard can locate the dispatch sentinel.
- Action-items emitted on Step 7 FAILED path MUST use the canonical `sprint-correction` type (target_command: `/gaia-correct-course`) via the 11-type resolver at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-meeting/scripts/lib/type-target-resolver.sh`. Do NOT append YAML directly to `action-items.yaml` — that's the bypass anti-pattern documented in memory rule `feedback_action_items_writer_resolver_bypass.md`.
- The composite verdict reducer at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/compose-verdict.sh` is the SINGLE source of truth for verdict-pair → composite mapping. Do not duplicate the logic in SKILL.md prose.

## Steps

### Step 1 — Pre-Condition Gate (active → review)

- Read `sprint-status.yaml` for the provided `$SPRINT_ID`. Scan the `stories[]` array.
- If ANY story has `status != done`, REFUSE with canonical stderr `gaia-sprint-review: refuse — <N> sprint stories are non-done (<list-of-keys>); complete or roll-over via /gaia-correct-course before invoking sprint-review`. The sprint stays at `status: active`. Exit non-zero.
- If `goals:` is empty or missing, REFUSE with canonical stderr `gaia-sprint-review: refuse — no sprint goals defined; run /gaia-sprint-plan with goals first`. Exit non-zero.
- When all-stories-done AND goals[] non-empty: proceed to Step 2.

### Step 2 — Transition active → review

Invoke the boundary writer:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh transition --sprint "$SPRINT_ID" --to review
```

On non-zero exit, HALT with the sprint-state.sh stderr passthrough — the transition guard refused the edge. On success, `sprint-status.yaml` records `status: review` atomically (mktemp + mv).

Export `SPRINT_ID="<sprint_id>"` to the environment so `scripts/finalize.sh` can locate the sentinel later.

### Step 3 — Track A Val Dispatch (dual-sentinel)

This is the canonical Val Bridge dispatch pattern. It mirrors `/gaia-add-feature/SKILL.md` Step 2 — the only differences are the rubric path and the sentinel slug (`sprint-review-<sprint_id>-val-dispatched.json` vs `add-feature-<feature_id>-val-dispatched.json`).

#### Step 3a — AskUserQuestion precondition (substrate halt)

Before the Agent-tool dispatch, the LLM MUST emit an `AskUserQuestion` tool call presenting the sprint goals + the rubric path. The substrate halts the turn pending user input under Auto Mode — this is the empirically-verified primitive (per `feedback_askuserquestion_under_automode.md`) that closes the auto-mode self-judgment bypass class. The user's explicit acknowledgement is what unblocks the Val dispatch below.

The AskUserQuestion call is the SOLE interactive boundary primitive at Step 3 entry.

#### Step 3b — Val dispatch + dual-sentinel

Spawn a Val subagent via the **main-turn Agent tool** with:

- `subagent_type: gaia:validator`
- `model: claude-opus-4-7` (opus pin)
- tool allowlist: `[Read, Grep, Glob, Bash, Write]`
- `artifact_path`: the literal `$SPRINT_ID` string (so caller + persona compute the same `sha256(artifact_path)` for the envelope-sentinel path)
- Rubric input: `${CLAUDE_PLUGIN_ROOT}/rubrics/base/sprint-review.json`. Val reads the rubric and applies its severity rules across 3 dimensions (story-to-goal traceability, velocity-vs-capacity fit, priority coverage) to produce per-goal PASSED/FAILED/PARTIAL verdicts.
- **Sprint shape.** The optional top-level `sprint_shape:` field on `sprint-status.yaml` (enum `thrust` (default) | `completion-pass`) modifies the `sgr-velocity-003` incidental-goal floor. The floor scales inversely with the number of goals via `floor_pct = max(0.10, 0.30 * (4 / max(4, N)))` — a 2-goal thrust sprint keeps the 30% floor; a 7-goal sweep scales to ~17%. When `sprint_shape: completion-pass` is set, the rule's severity is reduced from High to Low for below-floor goals AND the `sgr-velocity-006` advisory fires exactly once with the scaled floor and goals-below count. Toggle via `sprint-state.sh set-shape --sprint <id> --shape <thrust|completion-pass>`. The deterministic evaluator at `${CLAUDE_PLUGIN_ROOT}/scripts/rubric-evaluate.sh` is available to caller and Val for sgr-velocity-003 verdict mechanics.
- Intake: sprint-status.yaml (the sprint under review), the sprint's story files, the rubric.

Val returns the envelope `{ status, summary, artifacts, findings, next, sentinel_envelope }`. **Under the orchestrator-side writer shift, Val does NOT write the sentinel itself.** The orchestrator:

1. Parses `sentinel_envelope` from Val's return.
2. Writes the envelope sentinel via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/write-val-envelope.sh --envelope "$sentinel_envelope"` (captures the path on stdout).
3. Sources `${CLAUDE_PLUGIN_ROOT}/scripts/lib/assert-agent-envelope.sh` and invokes `assert_agent_envelope <path>` to verify forgery resistance. On non-zero exit, HALT with the canonical error `HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at <path>`.
4. Writes the dispatch sentinel via `scripts/write-val-sentinel.sh --sprint-id "$SPRINT_ID"` piped the Val envelope return on stdin. The sentinel lands at `.gaia/memory/checkpoints/sprint-review-${SPRINT_ID}-val-dispatched.json`. **Payload `.agent` field MUST be the literal string `"val"`** (the persona identifier), NOT the subagent registration name `"gaia:validator"`. The orchestrator MUST set or normalize `.agent = "val"` before piping the payload — the writer rejects any other value with `payload agent '<x>' must be 'val'`.
5. Applies the verdict-surfacing contract: display `status` + `summary` inline; HALT on CRITICAL before Track B fires; surface WARNING findings; log INFO findings.

When Val returns PASS or WARNING, capture the per-goal verdicts as Track A's composite. CRITICAL HALTS the skill — no Track B dispatch, no composite computation.

### Step 4 — Track B Execution Dispatch (STUB; the real runner ships later)

Invoke the stub:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/track-b-dispatch.sh --sprint "$SPRINT_ID"
```

The stub reads `sprint_review:` from `.gaia/config/project-config.yaml`, iterates the per-stack matrix, and emits a JSON array — one element per configured stack with `verdict: SKIPPED, reason: "real runner not yet shipped"`. This is the deferred-wiring contract; the story's frontmatter carries `delivered: false`.

#### Step 4a — Per-goal stakeholder confirmation (AskUserQuestion)

For each sprint goal, fire an `AskUserQuestion` at the main-turn caller level with the canonical 4-option set (expanded from 3 to 4 to capture the legitimate "let the rubric judge instead of me" intent that operators were typing in free-text):

- `works-as-expected` — stakeholder confirms the goal was met.
- `fails-goal` — stakeholder rejects the goal as not met.
- `needs-rework` — stakeholder accepts the goal partially but flags follow-up.
- `delegate-to-val` — stakeholder explicitly defers to Track A's per-goal Val rubric verdict. The recorded per-goal verdict for this case is `delegate-to-val:{val-verdict}` (e.g., `delegate-to-val:PASSED`), preserving the audit trail of the delegation. The composite-verdict reducer treats this row as PASSED-equivalent when Val's per-goal verdict was PASSED; FAILED-equivalent otherwise.

Record the per-goal response into the sprint-review artifact. **This MUST run at the main turn**, not inside the forked Track B script — `AskUserQuestion` is not exposed inside forked skill executions (memory rule `feedback_askuserquestion_forked_skill_gap.md`).

Track B's composite verdict on the stub path is `SKIPPED` (the stub returns SKIPPED per stack). A later story will replace this with the real per-stack runner — `verdict: PASSED|FAILED|UNVERIFIED` per stack, composed into Track B's composite.

### Step 5 — Compose Composite Verdict

Invoke the reducer with `--with-provenance` so that any `WARNING`/`PASS`/`CRITICAL` track verdict the reducer downcasts surfaces its pre-coercion value, then capture both lines:

```bash
REDUCER_OUT=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/compose-verdict.sh \
  --track-a "$TRACK_A_VERDICT" --track-b "$TRACK_B_VERDICT" --with-provenance)
COMPOSITE=$(printf '%s\n' "$REDUCER_OUT" | head -n1)
# original_status provenance: present ONLY when a
# track verdict was a coercible synonym; absent otherwise. Propagate it into
# the sprint-review artifact — do NOT strip it.
ORIGINAL_STATUS=$(printf '%s\n' "$REDUCER_OUT" | sed -n 's/^original_status=//p')
```

The reducer enforces these rules:

- **PASSED** iff both tracks are PASSED (Track B SKIPPED on the stub path counts as PASSED-equivalent; PARTIAL on Track A does not block).
- **FAILED** if either track is FAILED.
- **UNVERIFIED** if either track is UNVERIFIED and neither is FAILED.

Non-canonical inputs (e.g., a typo) are rejected at the script boundary with canonical stderr.

**`original_status` provenance.** When Track A or Track B emits a coercible synonym (`WARNING`, `PASS`, or `CRITICAL`), the reducer downcasts it (`WARNING`/`PASS → PASSED`, `CRITICAL → FAILED`) per the synonym-mapping path. The composite verdict is unaffected, but the pre-coercion value is telemetry-relevant — a composite `PASSED` collapses identically whether Val emitted `PASS` directly or `WARNING` with non-blocking findings. The `--with-provenance` flag appends an additive `original_status=track_a=<raw>[,track_b=<raw>]` line capturing the pre-coercion value(s); it is **absent** when no track was coerced (`original_status` is OPTIONAL, never required). When `$ORIGINAL_STATUS` is non-empty, record it in the composite-verdict section of the sprint-review artifact written in Steps 6–8 (e.g. `Composite verdict: PASSED (original_status: track_a=WARNING)`) so downstream consumers and retros can recover the pre-coercion provenance.

**Adversarial-findings aggregation.** When adversarial reviews (`/gaia-adversarial`, Sage) ran against this sprint's planning artifacts, fold their verdict/findings into the composite-verdict section. **Read the structured `.json` sidecar, not the prose** — for each `adversarial-review-<target>-<date>[-N].md` under `.gaia/artifacts/planning-artifacts/adversarial/`, resolve the structured fields through the shared reader helper (never re-inline a `.md` regex-parse):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/lib/read-adversarial-sidecar.sh \
  --md-path "<.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-*.md>"
```

The helper **prefers** the `.json` sidecar (jq-extracted `status` + `findings[].{severity,id,title,location}`, prefix `source=json`) and **falls back** to a `.md` regex-parse when the sidecar is absent (older reports, prefix `source=md`) — additive, back-compatible. Aggregate the parsed `status=` + `finding=` lines into the sprint-review artifact (adversarial is advisory, not a gate — it informs the review narrative, it does not flip the composite verdict).

### Step 6 — PASSED Path: Handoff to /gaia-sprint-close

When `$COMPOSITE` is `PASSED`:

1. Run `mkdir -p .gaia/artifacts/implementation-artifacts/sprint-review/` so the nested directory exists on first run. Write the sprint-review artifact to `.gaia/artifacts/implementation-artifacts/sprint-review/sprint-review-${SPRINT_ID}-$(date +%Y-%m-%d).md`. Body: charter + goals[] + Track A Val verdict (with findings) + Track B per-stack output + per-goal stakeholder confirmations + composite verdict + handoff routing decision.
2. Emit the canonical handoff message to the user: `/gaia-sprint-review: composite verdict PASSED — sprint <id> ready to close; invoke /gaia-sprint-close to finalize`.

The actual `review → closed` transition is enforced by `/gaia-sprint-close` — this skill only emits the handoff. `/gaia-sprint-close` accepts the new edge AND validates the dispatch sentinel before writing `status: closed`.

#### Step 6b — Advisory: per-story step report (best-effort)

Before emitting the handoff, surface the per-story step report as a best-effort advisory. This is read-only and never blocks the review — failures are logged and swallowed.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-report.sh" \
  --events "${MEMORY_PATH:-${PROJECT_PATH:-.}/.gaia/memory}/lifecycle-events.jsonl" 2>/dev/null || true
```

The report joins per-step timing and approximate per-step token estimates into per-story tables with rollup totals, giving the operator a comprehensive view of the sprint's execution cost before the close handoff.

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

   Use type `sprint-correction` (the canonical type for sprint-review-FAILED rework). One entry per failed goal/scenario, recorded in `.gaia/artifacts/planning-artifacts/action-items.yaml`. **Invoke the resolver script — do NOT append YAML directly** (memory rule `feedback_action_items_writer_resolver_bypass.md`).

3. Write the sprint-review artifact (same template as Step 6 — with composite verdict FAILED + the recorded findings).

4. Emit the canonical handoff: `/gaia-sprint-review: composite verdict FAILED — sprint <id> transitioned to correction; invoke /gaia-correct-course story_injection to inject rework stories, then re-run /gaia-sprint-review after the injected stories reach done`.

The `review → correction` edge acceptance + `story_injection` mechanics are in `/gaia-correct-course`.

### Step 8 — UNVERIFIED Path: Bypass

When `$COMPOSITE` is `UNVERIFIED`:

1. Collect mechanical signals per the un-reviewable-criteria spec (`.gaia/artifacts/planning-artifacts/sprint-review-unverifiable-criteria.md`):
   - `primary_criterion`: one of C1 (infra-only) / C2 (docs-only / planning-only) / C3 (deferred-implementation).
   - `qualifying_story_points`: sum of points matching the primary criterion.
   - `total_story_points`: sum of all completed story points.
   - `qualifying_ratio`: must be ≥ 0.80.
   - `qualifying_stories[]`: list of (key, criterion, points) triples.

2. Fire an `AskUserQuestion` to PM (Derek) requesting the `explanation` field — 200–1000 chars. The substrate halt enforces user input.

3. Persist the `review_justification:` block via the boundary writer:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-state.sh set-review-justification --sprint "$SPRINT_ID" --file <yaml-payload>
   ```

   The payload schema: `{ primary_criterion, qualifying_story_points, total_story_points, qualifying_ratio, explanation, qualifying_stories, pm_signoff: { pm_agent, signed_at }, val_validation: { status, rationale, validated_at } }`. Schema is validated by `sprint-state.sh` boundary writer.

4. Dispatch a second Val subagent for justification-validation (same dual-sentinel scheme as Step 3, but with the `review_justification:` payload as the validation artifact, NOT the rubric). Val validates that the criterion claims hold against ground truth (e.g., for C2, that no executable test surface exists).

5. On Val PASSED: emit the canonical handoff `/gaia-sprint-review: composite verdict UNVERIFIED — bypass APPROVED by PM + Val; invoke /gaia-sprint-close to finalize with the UNVERIFIED-bypass marker`. `/gaia-sprint-close` accepts the `review → closed` edge with the UNVERIFIED-bypass marker.

6. On Val FAILED: revert to the FAILED verdict path (Step 7) — record the justification-validation findings as action-items + transition to `correction`.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-sprint-review/scripts/finalize.sh

## References

- **Sprint-level state machine + agent-assisted sprint review architecture** — sprint-level transitions (`active → review → {closed, correction}`, `correction → active`) define each step of this skill.
- **Orchestrator-as-bridge** — main-turn Agent dispatch.
- **Val Bridge** — main-turn Agent dispatch + envelope-assert.
- **Orchestrator-side sentinel writer** — writer shift; Val returns `sentinel_envelope`, orchestrator writes via `lib/write-val-envelope.sh`.
- **Sanctioned boundary writes** via `sprint-state.sh` (no direct `yq -i` against `sprint-status.yaml`).
- **action-items.yaml canonical registry** + 11-type resolver.
- **No silent fallback in scripts.**
- **YOLO mode contract** — this skill has `yolo_steps: []` — sprint review is an interactive ceremony only, NOT YOLO-able. This is a deliberate design choice, not an oversight. The three `AskUserQuestion` boundaries (Step 3 pre-Val dispatch, Step 4 per-goal stakeholder confirmation, Step 8 UNVERIFIED bypass explanation) require human judgment that cannot be safely auto-answered. CI / unattended pipelines that need sprint-review automation should script the boundary writes directly via `sprint-state.sh transition --sprint <id> --to review` + write the sprint-review artifact + Val sentinel + invoke `finalize.sh` (matching the manual workaround pattern). A future enhancement may add a `--yolo-defaults works-as-expected` flag if stakeholder-confirmation auto-resolution becomes desirable.
- **Main-turn Mode A invariant** — AskUserQuestion reachability.
- **Foreground-mode invariant** — Track B enforced headed by the real runner.
- **Composite verdict reduction rule** — compose-verdict.sh single source of truth.
- **Boundary-write compliance** for goals[] + review_justification.
- **Mode A bypass mitigation** — anti-pattern bats check.
- **Val rubric** at `rubrics/base/sprint-review.json`.
- **Un-reviewable criteria spec** at `.gaia/artifacts/planning-artifacts/sprint-review-unverifiable-criteria.md`.
- **sprint-state.sh boundary writers** — `set-goals`, `update-goals`, `set-review-justification`, sprint-level transitions.
- **`sprint_review:` config section** + `/gaia-config-sprint-review` editor.
- **Track B per-stack execution runner** (deferred) — replaces the current stub.
- **Deferred edges** — `/gaia-sprint-plan` 3-lane goal approval + `/gaia-correct-course` review→correction edge + `/gaia-sprint-close` review→closed edge.
- **Memory rule `feedback_action_items_writer_resolver_bypass.md`**: action-items.yaml writes MUST route through the resolver script.
- **Memory rule `feedback_askuserquestion_forked_skill_gap.md`**: AskUserQuestion is not exposed inside forked skill executions.
