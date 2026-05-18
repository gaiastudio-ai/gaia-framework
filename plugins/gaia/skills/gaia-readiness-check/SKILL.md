---
name: gaia-readiness-check
description: Validate implementation readiness by checking all planning and testing artifacts for completeness, consistency, and cross-artifact contradictions — Cluster 6 architecture skill. Enforces two mandatory quality gates (traceability-matrix.md and ci-setup.md must exist) per ADR-042, then delegates readiness assessment to the architect and devops subagents.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
# Discover-Inputs Protocol (ADR-062 / FR-346 / E45-S4)
# Strategy: INDEX_GUIDED — readiness-check cross-references many large
# upstream artifacts (PRD, architecture, test plan, epics/stories,
# traceability matrix, ci-setup, threat-model, infra-design). Load each
# artifact's index (heading scan) first; fetch named sections on demand
# during cross-reference checks. Falls back to FULL_LOAD when an artifact
# lacks parseable headings.
discover_inputs: INDEX_GUIDED
discover_inputs_target: "docs/planning-artifacts/prd.md (or docs/planning-artifacts/prd/prd.md), docs/planning-artifacts/architecture.md, docs/test-artifacts/test-plan.md (or docs/test-artifacts/strategy/test-plan.md), docs/planning-artifacts/epics-and-stories.md"
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all
!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh devops decision-log

## Mission

Validate that all upstream planning, architecture, testing, and CI artifacts are complete, consistent, and free of cross-artifact contradictions before implementation begins. This skill enforces two mandatory quality gates — `traceability-matrix.md` and `ci-setup.md` must exist — and produces a machine-readable readiness report with PASS/FAIL/CONDITIONAL PASS status.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/implementation-readiness` workflow (brief Cluster 6, story P6-S4 / E28-S48). The step ordering, gate enforcement, and output path are preserved from the legacy `instructions.xml`.

## Critical Rules

- Both quality gates are **mandatory** per ADR-042 — there is no "single gate" fallback, no env-var bypass, and no flag to make either gate optional. Partial-pass is a bug.
- `traceability-matrix.md` MUST exist. Resolve via the strategy-fallback rule (ADR-072 / AF-2026-05-08-5): try `docs/test-artifacts/traceability-matrix.md` (flat); fall back to `docs/test-artifacts/strategy/traceability-matrix.md` (strategy/ placement); the gate `validate-gate.sh traceability_exists` also accepts the sharded `traceability-matrix/index.md` form per ADR-070. If missing from ALL placements, HALT with: "Gate failed: traceability-matrix.md not found at docs/test-artifacts/traceability-matrix.md, docs/test-artifacts/strategy/traceability-matrix.md, or docs/test-artifacts/traceability-matrix/index.md. Run /gaia-trace to generate the traceability matrix."
- `ci-setup.md` MUST exist at `docs/test-artifacts/ci-setup.md`. If missing, HALT with: "Gate failed: ci-setup.md not found. Run /gaia-ci-setup to configure the CI pipeline."
- Check ALL artifacts — do not stop at first failure (except for the mandatory gates which halt immediately).
- If the traceability matrix declares its own gate as BLOCKED or FAIL, the readiness report MUST NOT declare traceability_complete: true.
- Output must include a machine-readable PASS/FAIL gate report in YAML frontmatter.
- Architecture assessment is delegated to the `architect` subagent (Theo) via native Claude Code subagent invocation.
- Operational readiness assessment is delegated to the `devops` subagent (Soren) via native Claude Code subagent invocation.

## Steps

### Step 1 — Load All Artifacts

> **Loading strategy: INDEX_GUIDED per ADR-062.** Readiness-check
> cross-references up to nine large upstream artifacts — full-loading them
> all would routinely exceed 80K tokens. Heading-scan each artifact first
> (`grep -nE '^#{1,3} '`) to build a section index. The cross-reference
> checks in Steps 2-9 fetch named sections on demand (`sed -n` between
> heading anchors) — never the full body. If any artifact lacks parseable
> headings, fall back to FULL_LOAD for that file only and log the fallback
> in the checkpoint.

- Heading-scan the PRD for the requirements section index (functional and non-functional) — resolve via the sharded-fallback rule (ADR-069 / FR-396..402): try `docs/planning-artifacts/prd.md` (flat layout); fall back to `docs/planning-artifacts/prd/prd.md` (sharded layout, with shard subsections under `prd/04-functional-requirements/` and `prd/05-non-functional-requirements.md`).
- Heading-scan `docs/planning-artifacts/ux-design.md` if available for the UI-requirements section index.
- Heading-scan `docs/planning-artifacts/architecture.md` for architecture-decision and component section anchors.
- Heading-scan `docs/planning-artifacts/epics-and-stories.md` for the story-coverage section index.
- Heading-scan the traceability matrix for the requirement-coverage summary section — resolve via the strategy-fallback rule (Critical Rules above): try `docs/test-artifacts/traceability-matrix.md` (flat); fall back to `docs/test-artifacts/strategy/traceability-matrix.md` (strategy/ placement).
- Heading-scan `docs/test-artifacts/ci-setup.md` for the pipeline quality-gates summary section.
- Heading-scan the test plan if it exists for the risk-assessment section — resolve via the strategy-fallback rule (Critical Rules above): try `docs/test-artifacts/test-plan.md` (flat); fall back to `docs/test-artifacts/strategy/test-plan.md` (strategy/ placement).
- Heading-scan `docs/planning-artifacts/threat-model.md` if exists for security-requirement section anchors.
- Heading-scan `docs/planning-artifacts/infrastructure-design.md` if exists for deployment-topology section anchors.
- Note any missing artifacts immediately. Section bodies are loaded on demand by Steps 2-9 via `sed -n` between heading anchors.

> `!scripts/write-checkpoint.sh gaia-readiness-check 1 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=load`

### Step 2 — Completeness Check

- Verify each document exists and has all required sections.
- PRD: overview, personas, requirements, NFRs, journeys, data, integrations, constraints, criteria.
- Architecture: stack, system design, data, API, infrastructure.
- Epics: at least 1 epic with stories, all stories have AC.

> `!scripts/write-checkpoint.sh gaia-readiness-check 2 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=completeness`

### Step 3 — Consistency Check

- Verify stories trace to PRD requirements.
- Verify architecture covers all functional areas.
- Verify prd.md contains a "## Review Findings Incorporated" section.
- Verify architecture.md contains a "## Review Findings Incorporated" section.
- Check for terminology consistency across documents.

> `!scripts/write-checkpoint.sh gaia-readiness-check 3 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=consistency`

### Step 4 — Cross-Artifact Contradiction Check

Delegate architecture-related contradiction analysis to the **architect** subagent (Theo) via `agents/architect`:

- CHECK 1 — Architecture vs Threat Model (skip if threat-model.md does not exist).
- CHECK 2 — Architecture vs Infrastructure Design (skip if infrastructure-design.md does not exist). Delegate infrastructure topology validation to the **devops** subagent (Soren) via `agents/devops`.
- CHECK 3 — Architecture vs Stories.
- CHECK 4 — PRD NFRs vs Architecture.
- CHECK 5 — Threat Model vs Stories (skip if threat-model.md does not exist).
- CHECK 6 — Auth Strategy Alignment.

Record all contradictions in a structured list with contradiction_id, type, source_artifacts, description, authority_agent, severity (BLOCKING/WARNING), and recommended_resolution.

> `!scripts/write-checkpoint.sh gaia-readiness-check 4 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=contradictions contradiction_count="$CONTRADICTION_COUNT"`

### Step 5 — TEA Readiness

- TECHNICAL: Evaluate team expertise against chosen stack.
- ESTIMATION: Check story point estimates for completeness.
- ARCHITECTURE: Count ADRs, check for unresolved proposals.
- TESTING: Verify test strategy is defined and AC are testable.

> `!scripts/write-checkpoint.sh gaia-readiness-check 5 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=tea`

### Step 6 — Test Infrastructure Readiness

- Verify traceability-matrix.md covers all PRD requirements.
- Extract the traceability matrix's own gate decision.
- Extract the test implementation rate.
- Verify ci-setup.md defines enforced quality gates.
- Verify test-plan.md exists.

> `!scripts/write-checkpoint.sh gaia-readiness-check 6 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=test-infra`

### Step 7 — Security Readiness

- Verify security requirements are documented in PRD.
- Verify authentication/authorization is defined in architecture.
- Verify data privacy requirements are addressed.

#### Compliance scan (FR-352 / E46-S4)

Read `docs/planning-artifacts/epics-and-stories.md` once and harvest, for every story, its key, its priority (`P0..P3`), its compliance tags, and the phase classification of its owning epic. The same harvest feeds both the priority/schedule conflict detector and the compliance timeline estimator below — they share one pass.

If `epics-and-stories.md` is missing or malformed, log the WARNING `epics-and-stories.md not found — priority/schedule and compliance checks skipped` and continue to Step 8 (AC-EC2). The gate is NOT blocked solely by a missing epics file.

**Compliance keyword set (closed list).** Match case-insensitively against the story description: `GDPR`, `PCI-DSS`, `PCI DSS`, `HIPAA`. A story counts in every framework it mentions — a story citing both GDPR and HIPAA counts in both buckets. Do NOT extend the set to SOC-2, ISO-27001, CCPA, or any other framework without a matching PRD line — over-matching produces false positives and erodes trust in the gate.

**Phase classification rule.** An epic is "late-phase" if its heading or description contains any of `Post-MVP`, `Phase 2`, `Phase 3`, `Phase 4+`, `Beta-2`, `Post-Launch`, `Future`, or if its frontmatter declares `phase: post-mvp` or `phase: late`. `MVP`, `Phase 1`, `Sprint 1..n`, and untagged epics classify as `current-phase` and are NOT flagged. Ambiguous labels (`MVP+1`, `Beta`, `Phase 1.5`) classify as `unknown` and are NOT flagged — fail-safe: absence of evidence is not evidence of a conflict (AC-EC7).

##### Priority/Schedule Conflicts sub-section

For every P0 or P1 compliance story whose owning epic classifies as `late-phase`, append a WARNING row to a `## Priority/Schedule Conflicts` sub-section of the readiness report. Row columns: story key, priority, compliance framework(s) (joined with `+` when multiple), current phase. No duplicate rows for the same story key.

When zero P0/P1 compliance stories trigger the rule, OMIT the `## Priority/Schedule Conflicts` sub-section entirely — no empty header, no placeholder row (AC4).

##### Compliance Timeline sub-section

Count compliance stories per framework using exactly three buckets: `GDPR`, `PCI-DSS`, `HIPAA`. Compute weeks with the deterministic formula `weeks = ceil(story_count * 1.5)` with a minimum floor of 1 week when `story_count >= 1`. When `story_count == 0`, omit that framework's row entirely.

Render a `## Compliance Timeline` sub-section as a three-column table (`Framework | Story Count | Estimated Weeks`) plus the single-line audit footnote `Estimates: weeks = ceil(story_count * 1.5), min 1 week when count >= 1.` so consumers of the report can audit the number without reading SKILL.md.

When all three buckets are zero (no compliance stories anywhere), OMIT the `## Compliance Timeline` sub-section entirely — no empty table, no `0 stories` rows (AC4, AC-EC8).

> `!scripts/write-checkpoint.sh gaia-readiness-check 7 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=security`

### Step 8 — Operational Readiness

Delegate operational readiness assessment to the **devops** subagent (Soren) via `agents/devops`:

- Rollback: Is a rollback procedure documented?
- Observability: Are logging, metrics, and alerting requirements defined?
- Release strategy: Is the deployment approach defined?

> `!scripts/write-checkpoint.sh gaia-readiness-check 8 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=operational`

### Step 9 — Brownfield Completeness Check (optional)

- Skip if `docs/planning-artifacts/brownfield-onboarding.md` does not exist.
- Verify brownfield-specific artifacts (dependency-map, nfr-assessment, api-documentation).

> `!scripts/write-checkpoint.sh gaia-readiness-check 9 project_name="$PROJECT_NAME" gate_status=pending artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=brownfield`

### Step 10 — Generate Gate Report

Write the readiness report to `docs/planning-artifacts/readiness-report.md` with YAML frontmatter containing machine-readable PASS/FAIL status for each check area.

#### Self-Contradiction Sweep (FR-352 / E46-S4)

After all preceding sections (Completeness, Consistency, Cross-Artifact Contradictions, TEA, Test Infrastructure, Security with the Step 7 sub-sections, Operational, Brownfield) have been written into the in-memory report and BEFORE the file is flushed to disk, run an inline self-contradiction sweep over the assembled body. The sweep is an ACTIVE inline step — the Critical Rules bullet at the top of this skill remains as reinforcement, but the authoritative enforcement lives in this Step 10 action list. A reviewer who reads only the Critical Rules and skips the steps must still land on a passing gate only when this inline check has run.

**Pattern set (case-insensitive, scoped to the same requirement ID `FR-*`, `NFR-*`, `ADR-*` within the same report pass):**

- `{requirement} fully traced` paired with `{requirement} no test coverage`.
- `{requirement} implemented` paired with `{requirement} not implemented`.
- `{requirement} PASS` paired with `{requirement} FAIL`.
- `{requirement} requires auth` paired with `{requirement} no auth` or `{requirement} no-auth` (AC-EC5).

When the sweep finds contradictions, inject a `## Traceability Self-Contradictions` sub-section listing each conflict pair with: requirement ID, first claim text + its section anchor, second claim text + its section anchor, severity WARNING. Enumerate ALL conflict pairs found, not only the first (AC6). Use deterministic ordering — alphabetical by requirement ID, then ascending by first-appearance line number — so two consecutive runs against the same tree produce byte-identical reports.

When the sweep finds zero contradictions, OMIT the `## Traceability Self-Contradictions` sub-section entirely — symmetric with the Step 7 timeline section: no empty placeholders.

The sweep is pattern-based, not semantic. It does NOT invoke an LLM per requirement — that would be out of scope for this gate. Pattern detection is sufficient for the regression cases captured in VCP-RC-02 (Step 10).

#### Frontmatter schema additions (Subtask 4.1)

The readiness report frontmatter MUST include three new machine-readable fields produced by the Step 7 and Step 10 sub-sections above:

- `priority_schedule_conflicts_count: <int>` — count of WARNING rows emitted by the Step 7 priority/schedule scan; defaults to 0 when the sub-section is omitted.
- `compliance_timeline_present: <bool>` — `true` when a `## Compliance Timeline` sub-section was rendered; `false` when omitted.
- `self_contradictions_count: <int>` — count of contradiction pairs emitted by the Step 10 sweep; defaults to 0 when the sub-section is omitted.

Older reports that pre-date the FR-352 upgrade are read-compatible: consumers (`validate-gate.sh`, the Step 12 adversarial reviewer) MUST treat absent fields as the safe defaults above and MUST NOT FAIL on absence.

#### Gate verdict downgrade rule (Subtask 4.2)

If `self_contradictions_count > 0`, the overall gate status MUST NOT be PASS — it must be at least CONDITIONAL PASS, with each contradiction pair listed as a blocker in the report body. Priority/schedule conflicts and compliance timeline entries are informational (WARNING) and do NOT on their own downgrade PASS — this protects against an over-gating regression where a loud-but-not-broken report flips to FAIL purely because the new sections rendered.

> `!scripts/write-checkpoint.sh gaia-readiness-check 10 project_name="$PROJECT_NAME" gate_status="$GATE_STATUS" artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=report --paths docs/planning-artifacts/readiness-report.md`

### Step 11 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/planning-artifacts/readiness-report.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/planning-artifacts/readiness-report.md`, `artifact_type = readiness`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/planning-artifacts/readiness-report.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation runs against the Step 10 primary write (artifact-as-drafted). Step 13's post-adversarial re-write does NOT trigger a second Val invocation.

> Test Notes: VCP-VAL-04 (`docs/test-artifacts/test-plan.md §11.46.3`) covers this wire-in.

> `!scripts/write-checkpoint.sh gaia-readiness-check 11 project_name="$PROJECT_NAME" gate_status="$GATE_STATUS" artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=val-auto-review --paths docs/planning-artifacts/readiness-report.md`

### Step 12 — Adversarial Review

Invoke an adversarial review of the readiness report for critical scrutiny.

> `!scripts/write-checkpoint.sh gaia-readiness-check 12 project_name="$PROJECT_NAME" gate_status="$GATE_STATUS" artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=adversarial`

### Step 13 — Incorporate Adversarial Findings

Update the readiness report with adversarial review findings. If any Critical findings exist, set status to FAIL.

> `!scripts/write-checkpoint.sh gaia-readiness-check 13 project_name="$PROJECT_NAME" gate_status="$GATE_STATUS" artifacts_inspected_count="$ARTIFACTS_INSPECTED_COUNT" stage=incorporate --paths docs/planning-artifacts/readiness-report.md`

## Validation

<!--
  E42-S13 — V1→V2 65-item checklist port (FR-341, FR-359, VCP-CHK-25, VCP-CHK-26).
  Classification (65 items total — the highest-count skill in E42):
    - Script-verifiable: 25 (SV-01..SV-25) — enforced by finalize.sh.
    - LLM-checkable:     40 (LLM-01..LLM-40) — evaluated by the host LLM
      against the readiness-report.md artifact at finalize time.
  Exit code 0 when all 25 script-verifiable items PASS; non-zero otherwise.

  V1 source: _gaia/lifecycle/workflows/3-solutioning/implementation-readiness/
  (the V1 command `/gaia-readiness-check` is implemented by the
  `implementation-readiness` workflow — the directory is NOT literally named
  `readiness-check/`). The V1 `checklist.md` ships 52 explicit bullets across
  nine V1 categories (Artifacts, Consistency, Cross-Artifact Contradictions,
  TEA Readiness, Test Infrastructure, Security, Operational Readiness,
  Brownfield Completeness, Report, Output Verification). The story 65-item
  count is authoritative per docs/v1-v2-command-gap-analysis.md §14; the
  remaining 13 items are reconciled from V1 instructions.xml step outputs
  (story Task 1.3) and the V1 per-category step details:
    - per-artifact presence of each upstream file on disk
    - cross-artifact coherence (FR→story, NFR→test, ADR→component,
      epic→story, high-risk→ATDD, terminology consistency)
    - cascade-resolution (contradictions authority/resolution pairs,
      Pending Cascades "Resolved" column populated, no orphan edit
      propagations)
    - traceability (orphan requirements / orphan test cases flagged,
      implementation rate meets gate threshold, CI enforced gates)
    - sizing (numeric points, oversize split plans, ADR resolution
      state, adversarial findings incorporated, testable AC,
      quantified NFR, epic total vs capacity)
    - gate verdict (security / compliance / rollback / observability /
      release strategy / narrative coherence).

  V1 category coverage mapping (65 items):
    Artifact Presence           — SV-01..SV-05, LLM-01..LLM-05        (10)
    Cross-Artifact Coherence    — SV-06..SV-08, LLM-06..LLM-15        (13)
    Cascade Resolution          — SV-09..SV-11, LLM-16..LLM-23        (11)
    Traceability                — SV-12..SV-14, LLM-24..LLM-27        (7)
    Sizing & Velocity           — SV-15..SV-17, LLM-28..LLM-34        (10)
    Gate Verdict                — SV-18..SV-25, LLM-35..LLM-40        (14)
    Total                                                              65

  The VCP-CHK-26 anchor is SV-20 — "status field present in YAML
  frontmatter (PASS/FAIL/CONDITIONAL)". This is the V1 phrase anchor for
  "PASS/FAIL status clear" verbatim and MUST appear in violation output
  when the gate-verdict item fails (story AC2).

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5, AC-EC6).

  LLM-checkable contract: each item carries a 30-second per-item
  wall-clock timeout (AC-EC7). If the LLM evaluator returns a malformed
  verdict (no explicit PASS/FAIL), the item is treated as FAIL with
  actionable guidance and evaluation continues with the next item
  (AC-EC4). Timeouts and malformed verdicts MUST NOT cause the skill
  to deadlock.

  See docs/implementation-artifacts/E42-S13-port-gaia-readiness-check-65-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 [category: artifact presence] — Readiness report artifact exists
- [script-verifiable] SV-02 [category: artifact presence] — Readiness report artifact is non-empty
- [script-verifiable] SV-03 [category: artifact presence] — Referenced PRD file exists on disk (if referenced)
- [script-verifiable] SV-04 [category: artifact presence] — Referenced architecture file exists on disk (if referenced)
- [script-verifiable] SV-05 [category: artifact presence] — Referenced test-plan file exists on disk (if referenced)
- [script-verifiable] SV-06 [category: cross-artifact coherence] — Completeness section present (## Completeness heading)
- [script-verifiable] SV-07 [category: cross-artifact coherence] — Consistency section present (## Consistency heading)
- [script-verifiable] SV-08 [category: cross-artifact coherence] — Cross-Artifact Contradictions section present
- [script-verifiable] SV-09 [category: cascade resolution] — Pending Cascades section present if cascades tracked
- [script-verifiable] SV-10 [category: cascade resolution] — All Pending Cascades rows have Resolved column populated
- [script-verifiable] SV-11 [category: cascade resolution] — Contradictions table present in report body
- [script-verifiable] SV-12 [category: traceability] — Traceability matrix referenced (traceability-matrix.md mentioned)
- [script-verifiable] SV-13 [category: traceability] — Traceability complete field present in YAML frontmatter
- [script-verifiable] SV-14 [category: traceability] — Test implementation rate recorded
- [script-verifiable] SV-15 [category: sizing] — TEA Readiness section present (## TEA Readiness heading)
- [script-verifiable] SV-16 [category: sizing] — Estimation criteria referenced (points or story sizing mentioned)
- [script-verifiable] SV-17 [category: sizing] — Architecture ADR review recorded (ADR keyword present)
- [script-verifiable] SV-18 [category: gate verdict] — YAML frontmatter present (--- fenced block at top of file)
- [script-verifiable] SV-19 [category: gate verdict] — date field present in YAML frontmatter
- [script-verifiable] SV-20 [category: gate verdict] — status field present in YAML frontmatter (PASS/FAIL/CONDITIONAL)
- [script-verifiable] SV-21 [category: gate verdict] — checks_passed aggregate field present in YAML frontmatter
- [script-verifiable] SV-22 [category: gate verdict] — critical_blockers count field present in YAML frontmatter
- [script-verifiable] SV-23 [category: gate verdict] — contradictions_found count field present in YAML frontmatter
- [script-verifiable] SV-24 [category: gate verdict] — PASS/FAIL verdict emitted in report body or frontmatter
- [script-verifiable] SV-25 [category: gate verdict] — Output Verification section present (## Output Verification heading or equivalent)
- [LLM-checkable] LLM-01 [category: artifact presence] — UX design exists and is complete (when declared)
- [LLM-checkable] LLM-02 [category: artifact presence] — Epics/stories artifact is complete with AC on every story
- [LLM-checkable] LLM-03 [category: artifact presence] — Threat model artifact is complete (when declared)
- [LLM-checkable] LLM-04 [category: artifact presence] — Infrastructure design artifact is complete (when declared)
- [LLM-checkable] LLM-05 [category: artifact presence] — Traceability matrix covers every PRD requirement (deep)
- [LLM-checkable] LLM-06 [category: cross-artifact coherence] — Every PRD functional requirement is covered by at least one story
- [LLM-checkable] LLM-07 [category: cross-artifact coherence] — Every PRD NFR has at least one test case
- [LLM-checkable] LLM-08 [category: cross-artifact coherence] — Architecture components cover every functional area in the PRD
- [LLM-checkable] LLM-09 [category: cross-artifact coherence] — Every ADR is referenced by at least one component
- [LLM-checkable] LLM-10 [category: cross-artifact coherence] — Every epic contains at least one story
- [LLM-checkable] LLM-11 [category: cross-artifact coherence] — Every high-risk story carries ATDD coverage
- [LLM-checkable] LLM-12 [category: cross-artifact coherence] — prd.md contains a "Review Findings Incorporated" section with substantive content
- [LLM-checkable] LLM-13 [category: cross-artifact coherence] — architecture.md contains a "Review Findings Incorporated" section with substantive content
- [LLM-checkable] LLM-14 [category: cross-artifact coherence] — Terminology is consistent across PRD, architecture, and test-plan
- [LLM-checkable] LLM-15 [category: cross-artifact coherence] — Story component references resolve to architecture component inventory
- [LLM-checkable] LLM-16 [category: cascade resolution] — Architecture vs threat model — security requirements aligned (when threat-model.md exists)
- [LLM-checkable] LLM-17 [category: cascade resolution] — Architecture vs infrastructure design — topology aligned (when infrastructure-design.md exists)
- [LLM-checkable] LLM-18 [category: cascade resolution] — PRD NFR targets vs architecture design decisions — coherent
- [LLM-checkable] LLM-19 [category: cascade resolution] — Auth strategy aligned across PRD, architecture, and threat model
- [LLM-checkable] LLM-20 [category: cascade resolution] — Critical/high security requirements covered by story ACs (when threat-model.md exists)
- [LLM-checkable] LLM-21 [category: cascade resolution] — All BLOCKING contradictions listed in blocking_issues
- [LLM-checkable] LLM-22 [category: cascade resolution] — Every recorded contradiction has authority_agent assigned and recommended_resolution populated
- [LLM-checkable] LLM-23 [category: cascade resolution] — No unresolved edit-propagation rows outstanding in the Pending Cascades table
- [LLM-checkable] LLM-24 [category: traceability] — Orphan requirements flagged (FRs/NFRs with no story coverage)
- [LLM-checkable] LLM-25 [category: traceability] — Orphan test cases flagged (tests with no FR/NFR anchor)
- [LLM-checkable] LLM-26 [category: traceability] — Test implementation rate meets the gate threshold declared in traceability-matrix.md
- [LLM-checkable] LLM-27 [category: traceability] — CI enforced quality gates (not advisory-only) confirmed in ci-setup.md
- [LLM-checkable] LLM-28 [category: sizing] — All stories use numeric points (not just T-shirt sizes)
- [LLM-checkable] LLM-29 [category: sizing] — No oversized stories (>13 pts) without a split plan recorded
- [LLM-checkable] LLM-30 [category: sizing] — All ADRs resolved (none left in "Proposed" state)
- [LLM-checkable] LLM-31 [category: sizing] — Adversarial findings incorporated into architecture
- [LLM-checkable] LLM-32 [category: sizing] — Acceptance criteria are testable (every AC has a verifiable condition)
- [LLM-checkable] LLM-33 [category: sizing] — NFR targets are quantified (thresholds, units)
- [LLM-checkable] LLM-34 [category: sizing] — Epic totals reconcile to sprint capacity / velocity data
- [LLM-checkable] LLM-35 [category: gate verdict] — Security requirements documented in PRD are sufficient for the declared stack
- [LLM-checkable] LLM-36 [category: gate verdict] — Compliance timeline estimated when GDPR/PCI-DSS/HIPAA applies
- [LLM-checkable] LLM-37 [category: gate verdict] — Rollback procedure documented and feasible for the declared topology
- [LLM-checkable] LLM-38 [category: gate verdict] — Observability stack (logging, metrics, alerting) defined end-to-end
- [LLM-checkable] LLM-39 [category: gate verdict] — Release strategy defined and infrastructure supports it (canary/blue-green/rolling)
- [LLM-checkable] LLM-40 [category: gate verdict] — Overall readiness verdict narrative is well-reasoned given the category-level verdicts

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/finalize.sh
