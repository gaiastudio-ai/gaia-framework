---
name: gaia-threat-model
description: Create security threat model using STRIDE/DREAD methodology through collaborative analysis with the security subagent (Zara). Use when the user wants to produce a validated threat model document covering asset identification, STRIDE threat analysis, DREAD risk scoring, mitigation strategies, and security requirements.
context: fork
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-threat-model/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh security decision-log

## Mission

You are orchestrating the creation of a Security Threat Model document. The threat analysis and scoring is delegated to the **security** subagent (Zara), who conducts STRIDE analysis, DREAD scoring, and produces mitigation strategies. You load the architecture document, validate inputs, coordinate the multi-step flow, and write the output to the canonical path `.gaia/artifacts/planning-artifacts/threat-model.md`.

**Path resolution.** All path references in this SKILL.md use the canonical location `.gaia/artifacts/planning-artifacts/threat-model.md`. Older projects continue to work via the three-tier idiom at the script layer (`scripts/finalize.sh`: `THREAT_MODEL_ARTIFACT` env-var override → positive-evidence legacy fallback → canonical default). When writing the threat model via the Write tool, target the canonical path; the legacy fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/security-threat-model` workflow. The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- An architecture document MUST exist at `.gaia/artifacts/planning-artifacts/architecture.md` before starting. If missing, fail fast with "Architecture doc not found at .gaia/artifacts/planning-artifacts/architecture.md — run /gaia-create-arch first."
- Use STRIDE methodology for threat identification — all six categories must be evaluated for every component and data flow.
- Use DREAD scoring for risk prioritization — all five dimensions must be rated for every identified threat.
- Record all threat model decisions in security-sidecar memory.
- Threat analysis is delegated to the `security` subagent (Zara) via native Claude Code subagent invocation (`agents/security`) — do NOT inline Zara's persona into this skill body. If the security subagent is not available, fail with "security subagent not available" error.
- **Single-turn-synth carve-out.** The Zara dispatch is intentionally lightweight: it does NOT require an envelope-sentinel pattern like Val's (no equivalent of `assert_agent_envelope` after the Agent call). The justification is bounded: the threat-model artifact is a PLANNING DOCUMENT not a VERDICT (unlike Val's PASS/CRITICAL gate). If the host LLM single-turn-synthesizes Zara's persona instead of dispatching a real subagent, the resulting threat-model.md is still a usable artifact (operator can read it, refine it, dispatch /gaia-validate-prd-style review later). It is NOT load-bearing for a CRITICAL halt. **However, the host LLM MUST surface a single-line audit-trail note** at the end of the skill run: `THREAT-MODEL DISPATCH NOTE: synthesized inline (single-turn)` OR `THREAT-MODEL DISPATCH NOTE: dispatched to security subagent (real Agent-tool call)`. This makes the dispatch path auditable post-hoc without forcing the envelope-sentinel ceremony that would be premature for a planning artifact. The full envelope-sentinel pattern remains required for Val (verdict-emitting); this carve-out is scoped to threat-model only.
- If `.gaia/artifacts/planning-artifacts/threat-model.md` already exists, warn the user: "An existing threat model document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.

## Steps

### Step 1 — Load Architecture

- Read `.gaia/artifacts/planning-artifacts/architecture.md`.
- Extract system components, data flows, and trust boundaries.
- Identify external interfaces, APIs, and user-facing endpoints.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 1 project_name="$PROJECT_NAME" threat_model_scope=load stride_stage=init`

### Step 2 — Identify Assets

Delegate to the **security** subagent (Zara) via `agents/security` to catalog assets.

- Catalog valuable data and systems: user credentials, PII, financial data, API keys.
- Classify sensitivity: critical, high, medium, low.
- Map asset locations across system components.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 2 project_name="$PROJECT_NAME" threat_model_scope=assets stride_stage=assets asset_count="$ASSET_COUNT"`

### Step 3 — STRIDE Analysis

Delegate to the **security** subagent (Zara) via `agents/security` to conduct STRIDE analysis.

For each component and data flow, evaluate all six STRIDE categories:

- **Spoofing** — Can identities be faked?
- **Tampering** — Can data be modified in transit or storage?
- **Repudiation** — Can actions be denied without trace?
- **Information Disclosure** — Can data leak to unauthorized parties?
- **Denial of Service** — Can availability be disrupted?
- **Elevation of Privilege** — Can users gain unauthorized access?

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 3 project_name="$PROJECT_NAME" threat_model_scope=stride stride_stage=analysis threat_count="$THREAT_COUNT"`

### Step 4 — DREAD Scoring

Delegate to the **security** subagent (Zara) via `agents/security` to score threats.

For each identified threat, rate 1-10 on each DREAD dimension:

- **Damage potential** — How severe is the impact?
- **Reproducibility** — How easy to reproduce?
- **Exploitability** — How much skill/effort to exploit?
- **Affected users** — What percentage of users impacted?
- **Discoverability** — How easy to find the vulnerability?

Calculate average DREAD score and assign risk level: Critical (8-10), High (6-8), Medium (4-6), Low (1-4).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 4 project_name="$PROJECT_NAME" threat_model_scope=dread stride_stage=scoring dread_scores_present=true`

### Step 5 — Mitigation Strategies

Delegate to the **security** subagent (Zara) via `agents/security` to propose mitigations.

- For each high and critical risk threat, propose specific mitigations.
- Map mitigations to implementation: code changes, configuration, infrastructure.
- Prioritize mitigations by risk reduction vs implementation effort.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 5 project_name="$PROJECT_NAME" threat_model_scope=mitigations stride_stage=mitigations mitigation_count="$MITIGATION_COUNT"`

### Step 6 — Security Requirements

Delegate to the **security** subagent (Zara) via `agents/security` to extract requirements.

- Extract security requirements from threat analysis.
- Format as SR-1, SR-2, etc. with clear acceptance criteria.
- Map requirements to architecture components they protect.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 6 project_name="$PROJECT_NAME" threat_model_scope=requirements stride_stage=requirements sr_count="$SR_COUNT"`

### Step 7 — Generate Output

- Record key decisions in security-sidecar memory.
- Write the threat model document to `.gaia/artifacts/planning-artifacts/threat-model.md` with: assets table, STRIDE analysis per component, DREAD scores, risk levels, mitigation strategies, and security requirements list.
- **Durable dispatch provenance.** The single-line dispatch
  note from the Critical Rules carve-out is emitted to stdout, which Claude Code
  collapses — so it is NOT a durable audit record on its own. Additionally write
  the provenance into the artifact's YAML frontmatter so it survives the run:
  `dispatch_provenance: "synthesized-inline"` when the host LLM single-turn-
  synthesized Zara, or `dispatch_provenance: "security-subagent"` when a real
  `Agent`-tool dispatch occurred. A downstream reviewer (or `/gaia-readiness-check`)
  can then see at-rest whether the threat-model was produced by the real persona
  or inline-synthesized, without relying on transient stdout. This does NOT
  change the carve-out (inline synthesis remains permitted for this planning
  artifact) — it makes the existing audit note durable.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/threat-model.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 7 project_name="$PROJECT_NAME" threat_model_scope=output stride_stage=complete --paths .gaia/artifacts/planning-artifacts/threat-model.md`

### Step 8 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/threat-model.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/threat-model.md`, `artifact_type = threat-model`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/threat-model.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Val auto-review per the canonical pattern. Val's scope here is the artifact file ONLY (`.gaia/artifacts/planning-artifacts/threat-model.md`). The security-sidecar memory writes performed in Step 7 are out of scope for Val.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-threat-model 8 project_name="$PROJECT_NAME" threat_model_scope=val-auto-review stride_stage=val-auto-review stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/threat-model.md`

## Validation

<!--
  V1→V2 25-item checklist port.
  Classification (25 items total):
    - Script-verifiable: 15 (SV-01..SV-15) — enforced by finalize.sh.
    - LLM-checkable:     10 (LLM-01..LLM-10) — evaluated by the host LLM
      against the threat-model.md artifact at finalize time.
  Exit code 0 when all 15 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at
  _gaia/lifecycle/workflows/3-solutioning/security-threat-model/checklist.md
  ships 12 explicit bullets across six V1 categories (Assets, STRIDE
  Analysis, DREAD Scoring, Mitigations, Security Requirements, Output
  Verification). The 25-item count is authoritative; the remaining 13
  items are reconciled from V1 instructions.xml step outputs:
    - per-component STRIDE enumeration (all six categories)
    - per-threat DREAD enumeration (all five dimensions D/R/E/A/D)
    - per-threat mitigation mapping for High/Critical severity
    - SR-\d+ identifier per security requirement
    - acceptance criteria per SR-
    - sidecar decision write reference
    - structural shape requirements of the output file (non-empty,
      output path correct, section headings present).

  V1 category coverage mapping (25 items):
    Assets               — SV-03, SV-04, LLM-04, LLM-07                  (4)
    STRIDE Analysis      — SV-06, SV-07, LLM-01, LLM-05, LLM-10          (5)
    DREAD Scoring        — SV-08, SV-09, SV-10, LLM-03                   (4)
    Mitigations          — SV-11, SV-12, LLM-02, LLM-08                  (4)
    Security Requirements— SV-13, SV-14, LLM-06, LLM-09                  (4)
    Output Verification  — SV-01, SV-02, SV-05, SV-15                    (4)
    Total                                                                 25

  The anchor is SV-07 — "All six STRIDE categories evaluated
  per component". This is the V1 phrase verbatim and MUST appear in
  violation output when a component is missing a STRIDE category.

  Invoked by `finalize.sh` at post-complete. Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome).
-->

- [script-verifiable] SV-01 — Output file saved to .gaia/artifacts/planning-artifacts/threat-model.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Assets section present (## Assets heading)
- [script-verifiable] SV-04 — Assets table declares a Sensitivity column
- [script-verifiable] SV-05 — Asset locations mapped to components (Component column present in Assets table)
- [script-verifiable] SV-06 — STRIDE Analysis section present (## STRIDE Analysis heading)
- [script-verifiable] SV-07 — All six STRIDE categories evaluated per component (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)
- [script-verifiable] SV-08 — DREAD Scoring section present (## DREAD Scoring heading)
- [script-verifiable] SV-09 — Each threat scored on all 5 DREAD dimensions (D/R/E/A/D columns populated)
- [script-verifiable] SV-10 — Risk levels restricted to Critical/High/Medium/Low
- [script-verifiable] SV-11 — Mitigations section present (## Mitigations heading)
- [script-verifiable] SV-12 — High and critical threats have mitigations (every High/Critical threat appears in Mitigations)
- [script-verifiable] SV-13 — Security Requirements section present (## Security Requirements heading)
- [script-verifiable] SV-14 — Each requirement has acceptance criteria (SR-\d+ identifiers with AC bullets)
- [script-verifiable] SV-15 — Decisions recorded in security-sidecar (sidecar reference present)
- [LLM-checkable] LLM-01 — Threats are specific and actionable, not generic
- [LLM-checkable] LLM-02 — Mitigations are specific and implementable
- [LLM-checkable] LLM-03 — Risk levels align coherently with DREAD scores
- [LLM-checkable] LLM-04 — Asset locations mapped to components correctly
- [LLM-checkable] LLM-05 — STRIDE coverage is meaningful per component (not boilerplate)
- [LLM-checkable] LLM-06 — Acceptance criteria per SR- are testable
- [LLM-checkable] LLM-07 — Asset sensitivity classifications are accurate (critical/high/medium/low)
- [LLM-checkable] LLM-08 — Mitigation prioritization reflects risk reduction vs implementation effort
- [LLM-checkable] LLM-09 — Security requirements map back to architecture components they protect
- [LLM-checkable] LLM-10 — No critical threats are missing from STRIDE coverage (completeness judgment)

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-threat-model/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-infra-design` — design the infrastructure topology and IaC with the threat model in scope.

## References

- Schema: `gaia-public/plugins/gaia/schemas/threat-model.schema.json` (JSON Schema draft-2020-12) — the structural contract for the `threat-model` artifact this skill produces. Validated by `/gaia-val-validate` (artifact_type `threat-model`) via the shared `scripts/lib/validate-artifact-schema.sh` helper.
- Corpus instance: `.gaia/artifacts/planning-artifacts/threat-model.md` — the on-disk exemplar the schema is grounded in (nine canonical H2 sections + STRIDE/DREAD methodology).
- Validator: `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md` — `artifact_type` enum already carries `threat-model` at position 5; the backing schema is added with NO enum change.
- Shared validator lib: `gaia-public/plugins/gaia/scripts/lib/validate-artifact-schema.sh` — backend-cascade JSON-schema validator (ajv → python3+jsonschema → graceful SKIP).
