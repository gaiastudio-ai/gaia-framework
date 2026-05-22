---
name: gaia-edit-arch
description: Edit an existing architecture document with cascade-aware downstream artifact detection, delegating architecture-authoring reasoning to the architect subagent (Theo) — Cluster 6 architecture skill. Use when the user wants to modify sections of an existing architecture while preserving consistency with epics, stories, test plans, and infrastructure design.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-arch/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all

## Mission

This skill orchestrates edits to an existing System Architecture document. Architecture authoring and reasoning is delegated to the **architect** subagent (Theo), who evaluates change impact, validates consistency, records ADRs, and produces the updated artifact. The skill loads the current architecture, coordinates the multi-step edit flow, detects cascade impacts on downstream artifacts, and writes the output to the canonical post-ADR-111 path `.gaia/artifacts/planning-artifacts/architecture.md`.

**Path resolution (AF-2026-05-21-11).** All architecture path references in this SKILL.md use the canonical post-ADR-111 location `.gaia/artifacts/planning-artifacts/architecture.md` and the shard directory `.gaia/artifacts/planning-artifacts/architecture/`. Pre-ADR-111 projects continue to work via a positive-evidence-legacy fallback at the script layer (`scripts/finalize.sh` three-tier idiom: `ARCHITECTURE_ARTIFACT` env-var override → legacy `docs/planning-artifacts/architecture.md` only when that file exists AND `.gaia/artifacts/planning-artifacts/` does NOT → canonical default). When writing the architecture document via the Write tool, target the canonical path; the pre-ADR-111 fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/edit-architecture` workflow (brief Cluster 6, story P6-S2 / E28-S46). The step ordering, cascade-aware semantics, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- An architecture document MUST already exist at `.gaia/artifacts/planning-artifacts/architecture.md` before starting. If missing, fail fast with "No architecture document found at .gaia/artifacts/planning-artifacts/architecture.md — run /gaia-create-arch first."
- Preserve existing content not being changed — edits are surgical, not wholesale rewrites. No silent drops, reorders, or modifications to unchanged sections.
- Record every significant decision as a new ADR with auto-incremented ID in the architecture document's Decision Log table.
- Add a version note documenting what changed, why, and the CR/reference after every edit session.
- Update "Review Findings Incorporated" section after adversarial review (if triggered).
- Architecture edit reasoning is delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation — do NOT inline Theo's persona into this skill body. If the architect subagent (E28-S21) is not available, fail with "architect subagent not available — install E28-S21" error.
- Cascade impact assessment on downstream artifacts (epics-and-stories.md, test-plan.md, infrastructure-design.md, traceability-matrix.md) is MANDATORY after every edit — this is the key semantic preserved from the legacy workflow.

## Steps

### Step 1 — Load Existing Architecture

- Read the current architecture document at `.gaia/artifacts/planning-artifacts/architecture.md`.
- If the file does not exist, fail fast: "No architecture document found at .gaia/artifacts/planning-artifacts/architecture.md — run /gaia-create-arch first."
- Count existing ADRs in Section 2 (Architecture Decisions) — note highest ADR ID for auto-increment.
- Identify existing Version History entries — note last version number for auto-increment.
- Display current structure summary to user: section headers, ADR count, current version.

> `!scripts/write-checkpoint.sh gaia-edit-arch 1 project_name="$PROJECT_NAME" edit_scope=load arch_version_current="$ARCH_VERSION_CURRENT"`

### Step 2 — Capture Change Scope

Delegate to the **architect** subagent (Theo) via `agents/architect` to evaluate the requested changes.

- If triggered by a change request: inherit CR ID, technical_impact, and change_description from the triggering workflow context. Skip user questions — proceed directly to scope confirmation.
- If triggered by adversarial review: load adversarial review findings as the change scope. Set driver = "adversarial-review". Skip user questions — proceed directly to scope confirmation.
- Otherwise, ask the user:
  1. What sections need to change? (List affected architecture sections)
  2. What is the change? (Describe the modification)
  3. Why is this change needed? (Driver: change request / technical discovery / adversarial finding / PRD edit cascade)
  4. Is this linked to a change request or other reference? If so, provide the CR ID or reference.

Record: sections_affected, change_description, driver, cr_id.

Classify change scope: MINOR (section update, config change) / SIGNIFICANT (new component, API change, data model change) / BREAKING (architectural shift, tech stack change).

Confirm scope of changes with user before proceeding. The architect subagent evaluates whether the requested changes are consistent with the existing architecture and flags any potential conflicts.

> `!scripts/write-checkpoint.sh gaia-edit-arch 2 project_name="$PROJECT_NAME" edit_scope="$EDIT_SCOPE" architecture_section_targeted="$ARCHITECTURE_SECTION_TARGETED" driver="$DRIVER"`

### Step 3 — Apply Targeted Edits

Delegate to the **architect** subagent (Theo) via `agents/architect` to apply the edits:

- For each affected section: present current content, propose edits, wait for user confirmation or modification.
- Preserve all unchanged sections exactly as-is — no reordering, no reformatting, no content loss.
- Validate consistency between edited sections and remaining unchanged sections.
- If edits affect component-to-requirement traceability: verify Addresses fields remain accurate.

> `!scripts/write-checkpoint.sh gaia-edit-arch 3 project_name="$PROJECT_NAME" edit_scope=apply architecture_section_targeted="$ARCHITECTURE_SECTION_TARGETED"`

### Step 4 — Record ADRs

Delegate to the **architect** subagent (Theo) via `agents/architect` to record architecture decision records:

- For each significant decision in the edit: create a new ADR entry.
- Auto-increment ADR ID from highest existing (e.g., if ADR-5 exists, new ADR is ADR-6).
- ADR template:
  ```
  ### ADR-{id}: {Decision Title}
  - **Status:** Active
  - **Context:** {Why this decision was needed}
  - **Decision:** {What was decided}
  - **Consequences:** {Trade-offs and implications}
  - **Addresses:** {FR-* / NFR-* IDs this decision addresses}
  ```
- If superseding an existing ADR: set old ADR status to "Superseded by ADR-{new_id}" and add "Supersedes: ADR-{old_id}" to the new entry.
- Auto-increment architecture version: minor bump (e.g., v1.0 -> v1.1, v1.3 -> v1.4).

> `!scripts/write-checkpoint.sh gaia-edit-arch 4 project_name="$PROJECT_NAME" edit_scope=adr adr_count="$ADR_COUNT" arch_version_new="$ARCH_VERSION_NEW"`

### Step 5 — Add Version Note

- Append a new row to the Version History table:
  `| {date} | {change summary} | {driver} | {CR ID or reference} |`
- If no Version History section exists, create one:
  ```
  ## Version History
  | Date | Change | Reason | CR/Reference |
  |------|--------|--------|-------------|
  | {date} | {change summary} | {driver} | {CR ID or reference} |
  ```

> `!scripts/write-checkpoint.sh gaia-edit-arch 5 project_name="$PROJECT_NAME" edit_scope=version arch_version_new="$ARCH_VERSION_NEW"`

### Step 6 — Save and Review Gate

- Generate a diff summary showing exactly what changed (sections modified, ADRs added/superseded, version bump).
- Write updated architecture document to `.gaia/artifacts/planning-artifacts/architecture.md` with all edits applied, new ADRs appended, version incremented, and version note added.
- Read `${CLAUDE_PLUGIN_ROOT}/knowledge/adversarial-triggers.yaml` to evaluate trigger rules. (This policy table ships inside the plugin under ADR-041's `knowledge/` convention; the legacy v1 location `_gaia/_config/adversarial-triggers.yaml` is retired and no longer used.) Determine the current `change_type`: if this workflow was invoked with a change_type context (e.g., from add-feature triage), use that value. If no context is available, infer from the change scope and driver: adversarial-finding or technical-discovery maps to "feature", change-request depends on the CR classification.
- Look up the trigger rule for `change_type` + artifact "architecture". If adversarial is false for this combination: skip adversarial review — mark "Review Findings Incorporated" as "Adversarial review not triggered — change type: {change_type} per adversarial-triggers.yaml". Proceed to Step 7.
- If adversarial is true and magnitude meets or exceeds threshold: dispatch the **`adversarial-reviewer`** subagent (Sage) via the Agent tool to critique `.gaia/artifacts/planning-artifacts/architecture.md`, focused on changed sections. The dispatch prompt MUST specify (a) the artifact path to review, (b) the changed-section anchors to focus on, and (c) the report output path `.gaia/artifacts/planning-artifacts/adversarial-review-architecture-{YYYY-MM-DD}.md` (use today's UTC date). Sage's persona at `plugins/gaia/agents/adversarial-reviewer.md` defines the review structure and architecture-specific lenses.
- When the subagent returns: verify `adversarial-review-architecture-*.md` exists in `.gaia/artifacts/planning-artifacts/`. Per ADR-063, display the returned ADR-037 envelope (status + summary + findings) to the user.
- Read findings — extract critical and high severity items.
- For each critical/high finding: incorporate into architecture document.
- Update "Review Findings Incorporated" section — append new entries with amendment date.
- Write the final architecture document.

> `!scripts/write-checkpoint.sh gaia-edit-arch 6 project_name="$PROJECT_NAME" edit_scope=save arch_version_new="$ARCH_VERSION_NEW" --paths .gaia/artifacts/planning-artifacts/architecture.md`

### Step 7 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/architecture.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/architecture.md`, `artifact_type = architecture`, `model: claude-opus-4-7`, `effort: high` (ADR-074 contract C2 — Val opus pin). [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]. **Non-opus mismatch guard (AC3):** if a test fixture or downstream override forces a non-opus model, emit the canonical WARNING `Val dispatch on non-opus model — forcing opus per ADR-074 contract C2` and force `model: claude-opus-4-7` before invoking Val.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/architecture.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Step 6 may have written the artifact twice — once initially and once again after the in-step adversarial subagent incorporated critical/high findings — but Val MUST be invoked exactly ONCE here against the FINAL post-incorporation written state of `.gaia/artifacts/planning-artifacts/architecture.md` (story E44-S5 AC8 / AC-EC4). The adversarial incorporation completes inside Step 6 BEFORE the Step 6 checkpoint emits and BEFORE Step 7 is entered, so the artifact this loop reads is always the final state.

> `!scripts/write-checkpoint.sh gaia-edit-arch 7 project_name="$PROJECT_NAME" edit_scope=val-auto-review arch_version_new="$ARCH_VERSION_NEW" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/architecture.md`

### Step 8 — Cascade Impact Analysis

This is the cascade-aware behavior preserved from the legacy edit-architecture workflow — the key semantic that distinguishes editing from creation.

- Classify cascade impact on downstream artifacts:

  | Downstream Artifact    | Impact | Recommended Action |
  |------------------------|--------|--------------------|
  | Epics and Stories       | {NONE/MINOR/SIGNIFICANT} | {/gaia-add-stories or manual update} |
  | Test Plan               | {NONE/MINOR/SIGNIFICANT} | {/gaia-test-design} |
  | Infrastructure Design   | {NONE/MINOR/SIGNIFICANT} | {/gaia-infra-design or manual update} |
  | Traceability Matrix     | {NONE/MINOR/SIGNIFICANT} | {/gaia-trace} |

- For each artifact with impact > NONE: recommend the appropriate update workflow.
- Report cascade assessment to user with recommended next command(s).
- Record all architecture changes and new ADRs in Theo's memory sidecar.

> `!scripts/write-checkpoint.sh gaia-edit-arch 8 project_name="$PROJECT_NAME" edit_scope=cascade cascade_impact="$CASCADE_IMPACT"`

### Step 9 — Re-shard touched documents (E53-S244, ADR-070)

Editing the architecture monolith MUST be followed by a re-shard so the per-section shards under `.gaia/artifacts/planning-artifacts/architecture/` stay aligned with the monolith. This step honours the monolith-vs-shard sync contract in ADR-070 (extended in E53-S243) — it is not optional unless the user passes `--monolith-only` for an explicit atomic same-PR edit.

- If `$ARGUMENTS` contains `--monolith-only`: skip this step entirely. The user takes responsibility for re-running `/gaia-shard-doc` (or merging shards back to the monolith) before commit. Record `reshard: skipped (--monolith-only)` in the cascade summary.
- Otherwise, invoke `/gaia-shard-doc .gaia/artifacts/planning-artifacts/architecture.md` (or the canonical monolith path resolved at runtime). The skill writes to `.gaia/artifacts/planning-artifacts/architecture/` — `01-*.md`, `02-*.md`, ... up to the highest-numbered section.
- After the re-shard returns, run `${CLAUDE_PLUGIN_ROOT}/scripts/check-monolith-shard-sync.sh` against the project root. The check is advisory (always exits 0). If it emits any `WARNING` lines naming `architecture.md`, surface those WARNINGs to the user — they indicate the re-shard did not converge and the user must investigate before commit.
- Record `reshard: invoked (gaia-shard-doc)` in the cascade summary so the audit trail captures the invocation.

This step runs in YOLO mode automatically — re-sharding is deterministic per ADR-042 and needs no user prompt. It is purely additive: skills that did not previously include this step continue to function for backwards compatibility (AC8 of E53-S244).

> `!scripts/write-checkpoint.sh gaia-edit-arch 9 project_name="$PROJECT_NAME" edit_scope=reshard reshard_outcome="$RESHARD_OUTCOME"`

## Validation

<!--
  E42-S9 — V1→V2 25-item checklist port (FR-341, FR-359, VCP-CHK-17, VCP-CHK-18).
  Classification (25 items total):
    - Script-verifiable: 17 (SV-01..SV-17) — enforced by finalize.sh.
    - LLM-checkable:      8 (LLM-01..LLM-08) — evaluated by the host LLM
      against the edited architecture artifact at finalize time.
  Exit code 0 when all 17 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at _gaia/lifecycle/workflows/3-solutioning/edit-architecture/
  checklist.md carried 14 bulleted items across six V1 categories
  (Edit Quality, ADR Quality, Version History, Review Gate, Cascade
  Assessment, Output Verification). The story 25-item count is
  authoritative per docs/v1-v2-command-gap-analysis.md §4; the 14 V1
  bullets are expanded to 25 by reconciling items dropped from V1
  checklist.md but preserved in V1 instructions.xml step outputs
  (per story Task 1.3):
    - envelope items (SV-01, SV-02: output file saved, non-empty)
    - structural Decision Log checks (SV-08 table, SV-10 ADR rows populated)
    - cascade-row coverage (SV-15 all four canonical downstream artifacts)
    - cascade classification populated (SV-16)
    - sidecar memory write referenced (SV-17, per V1 step 7)
    - semantic LLM items (LLM-01..LLM-08: requested changes applied,
      preservation, consistency, ADR rationale, cascade plausibility,
      adversarial review status, findings traceability, next-step
      communication).

  V1 category coverage mapping (25 items):
    Edit Quality         — SV-01, SV-02, SV-03, SV-04, LLM-01, LLM-02, LLM-03  (7)
    ADR Quality          — SV-07, SV-08, SV-09, SV-10, SV-11, SV-12, LLM-04    (7)
    Version History      — SV-05, SV-06                                        (2)
    Review Gate          — SV-13, LLM-06, LLM-07                               (3)
    Cascade Assessment   — SV-14, SV-15, SV-16, LLM-05                         (4)
    Output Verification  — SV-17, LLM-08                                        (2)
    Total                                                                      25

  The VCP-CHK-18 anchor is SV-05/SV-06 — "Version History" section
  and table-row presence. This is the V1 phrase verbatim and MUST
  appear in violation output when the Version History section is
  missing or empty (AC2).

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).

  See .gaia/artifacts/implementation-artifacts/E42-S9-port-gaia-edit-arch-25-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to .gaia/artifacts/planning-artifacts/architecture.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Unchanged sections preserved (System Overview still present)
- [script-verifiable] SV-04 — Architecture version incremented (version marker present)
- [script-verifiable] SV-05 — Version History section present
- [script-verifiable] SV-06 — Version History table has a version note row
- [script-verifiable] SV-07 — Architecture Decisions section present (Decision Log)
- [script-verifiable] SV-08 — Decision Log table present with markdown table structure
- [script-verifiable] SV-09 — New ADR(s) created (Decision Log table has at least one ADR row)
- [script-verifiable] SV-10 — Each ADR has context, decision, consequences (ADR-N rows populated)
- [script-verifiable] SV-11 — Addresses field maps to FR/NFR IDs (FR-### identifier referenced)
- [script-verifiable] SV-12 — Superseded ADRs marked with status update
- [script-verifiable] SV-13 — Review Findings Incorporated section present
- [script-verifiable] SV-14 — Cascade Assessment section present (Pending Cascades retained)
- [script-verifiable] SV-15 — Cascade impact classified for all four downstream artifacts
- [script-verifiable] SV-16 — Cascade classification populated (NONE/MINOR/SIGNIFICANT)
- [script-verifiable] SV-17 — Changes recorded in architect-sidecar memory (sidecar reference present)
- [LLM-checkable] LLM-01 — Requested changes applied correctly (edit matches the change request)
- [LLM-checkable] LLM-02 — Unchanged sections preserved exactly (no silent drops or reorders)
- [LLM-checkable] LLM-03 — Consistency maintained across sections (no contradictions introduced)
- [LLM-checkable] LLM-04 — Each new ADR has context, decision, consequences with sound rationale
- [LLM-checkable] LLM-05 — Cascade impact classifications are plausible for the scope of change
- [LLM-checkable] LLM-06 — Adversarial review completed OR explicitly skipped for minor edits
- [LLM-checkable] LLM-07 — Review Findings Incorporated traceable (before/after mapping clear if review ran)
- [LLM-checkable] LLM-08 — Next steps communicated to user appropriately for the cascade outcome

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-edit-arch/scripts/finalize.sh

## Next Steps

- If cascade NONE: no further action required.
- If cascade MINOR: update affected artifacts with targeted edits.
- If cascade SIGNIFICANT: `/gaia-add-stories` to create new stories for added scope, `/gaia-test-design` to update test coverage, `/gaia-trace` to refresh traceability matrix.
