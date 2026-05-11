---
name: gaia-infra-design
description: Design infrastructure topology and IaC structure through collaborative discovery with the devops subagent (Soren) — Cluster 6 architecture skill. Use when the user wants to produce an infrastructure design document covering deployment topology, environment design, IaC structure, and observability plan.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
orchestration_class: heavy-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-infra-design/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh devops decision-log

## Mission

You are orchestrating the creation of an Infrastructure Design document. The infrastructure authoring is delegated to the **devops** subagent (Soren), who designs deployment topology, environment layout, IaC structure, and observability plans. You load the architecture document, validate inputs, coordinate the multi-step flow, and write the output to `docs/planning-artifacts/infrastructure-design.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/infrastructure-design` workflow (brief Cluster 6, story P6-S5 / E28-S49). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- An architecture document MUST exist at `docs/planning-artifacts/architecture.md` before starting. If missing, fail fast with "Architecture doc not found at docs/planning-artifacts/architecture.md — run /gaia-create-arch first."
- Every significant infrastructure decision must be recorded in the devops-sidecar memory.
- Every environment must have a defined purpose and access policy.
- Infrastructure authoring is delegated to the `devops` subagent (Soren) via native Claude Code subagent invocation — do NOT inline Soren's persona into this skill body. If the devops subagent (E28-S21) is not available, fail with "devops subagent not available — install E28-S21" error.
- If `docs/planning-artifacts/infrastructure-design.md` already exists, warn the user: "An existing infrastructure design document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.

## Steps

### Step 1 — Load Architecture

- Read `docs/planning-artifacts/architecture.md`.
- Extract component inventory, service boundaries, data stores.
- Identify compute, storage, and networking requirements.

> `!scripts/write-checkpoint.sh gaia-infra-design 1 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" topology_version="$TOPOLOGY_VERSION"`

### Step 2 — Environment Design

Delegate to the **devops** subagent (Soren) via `agents/devops` to design environments.

- Define environments: dev, staging, production (+ preview if needed).
- Specify environment parity strategy — how close staging mirrors production.
- Define access policies and promotion gates between environments.

> `!scripts/write-checkpoint.sh gaia-infra-design 2 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=environments`

### Step 3 — Deployment Topology

Delegate to the **devops** subagent (Soren) via `agents/devops` to design the deployment topology.

- Define container orchestration strategy (Kubernetes, ECS, serverless, etc.).
- Design service mesh and load balancing approach.
- Specify scaling strategy: horizontal, vertical, auto-scaling triggers.
- Define networking: VPC, subnets, security groups, CDN.

> `!scripts/write-checkpoint.sh gaia-infra-design 3 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=topology`

### Step 4 — IaC Structure

Delegate to the **devops** subagent (Soren) via `agents/devops` to define infrastructure-as-code.

- Define Infrastructure-as-Code project structure and module design.
- Specify IaC tool and conventions (Terraform, Pulumi, CloudFormation).
- Design module boundaries matching service boundaries.
- Define state management strategy.

> `!scripts/write-checkpoint.sh gaia-infra-design 4 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=iac`

### Step 5 — Observability Plan

Delegate to the **devops** subagent (Soren) via `agents/devops` to define observability.

- Define logging strategy: structured logs, log aggregation, retention.
- Define metrics: application metrics, infrastructure metrics, custom dashboards.
- Define tracing: distributed tracing, correlation IDs.
- Define alerting: SLO-based alerts, escalation policies, on-call rotation.

> `!scripts/write-checkpoint.sh gaia-infra-design 5 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=observability`

### Step 6 — Generate Output

- Record key decisions in devops-sidecar memory.
- Write the infrastructure design document to `docs/planning-artifacts/infrastructure-design.md` with: environment matrix, deployment topology, IaC structure, observability plan, and decision rationale.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/planning-artifacts/infrastructure-design.md`

> `!scripts/write-checkpoint.sh gaia-infra-design 6 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=output --paths docs/planning-artifacts/infrastructure-design.md`

### Step 7 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `docs/planning-artifacts/infrastructure-design.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = docs/planning-artifacts/infrastructure-design.md`, `artifact_type = infrastructure-design`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `docs/planning-artifacts/infrastructure-design.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Per story E44-S5 Task 6.2, Val's scope here is the artifact file ONLY (`docs/planning-artifacts/infrastructure-design.md`). The devops-sidecar memory writes performed in Step 6 are out of scope for Val per the E44-S1 contract (sibling pattern with threat-model AC-EC10).

> `!scripts/write-checkpoint.sh gaia-infra-design 7 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=val-auto-review --paths docs/planning-artifacts/infrastructure-design.md`

## Validation

<!--
  E42-S12 — V1→V2 25-item checklist port (FR-341, FR-359, VCP-CHK-23, VCP-CHK-24).
  Classification (25 items total):
    - Script-verifiable: 15 (SV-01..SV-15) — enforced by finalize.sh.
    - LLM-checkable:     10 (LLM-01..LLM-10) — evaluated by the host LLM
      against the infrastructure-design.md artifact at finalize time.
  Exit code 0 when all 15 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at
  _gaia/lifecycle/workflows/3-solutioning/infrastructure-design/checklist.md
  ships 13 explicit bullets across five V1 categories (Environments,
  Deployment, IaC, Observability, Output Verification). The story 25-item
  count is authoritative per docs/v1-v2-command-gap-analysis.md §11; the
  remaining 12 items are reconciled from V1 instructions.xml step outputs
  (story Task 1.3):
    - per-environment access policy and promotion gates
    - dev / staging / production triad declared
    - auto-scaling triggers and networking detail (VPC/subnets/CDN)
    - IaC tool named with rationale, module-to-service-boundary alignment
    - state management strategy
    - distributed tracing / correlation IDs
    - alerting, escalation, and on-call specifics
    - structural shape requirements of the output file (non-empty,
      output path correct, section headings present)
    - sidecar decision write reference.

  V1 category coverage mapping (25 items):
    Environments         — SV-03, SV-04, SV-05, LLM-01, LLM-02           (5)
    Deployment           — SV-06, SV-07, SV-08, LLM-03, LLM-04           (5)
    IaC                  — SV-09, SV-10, SV-11, LLM-05, LLM-10           (5)
    Observability        — SV-12, SV-13, SV-14, LLM-06, LLM-07, LLM-08   (6)
    Output Verification  — SV-01, SV-02, SV-15, LLM-09                   (4)
    Total                                                                 25

  The VCP-CHK-24 anchor is SV-11 — "State management strategy specified".
  This is the V1 phrase verbatim and MUST appear in violation output
  when the state-management item fails (story AC2).

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).

  See docs/implementation-artifacts/E42-S12-port-gaia-infra-design-25-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file saved to docs/planning-artifacts/infrastructure-design.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Environments section present (## Environments heading)
- [script-verifiable] SV-04 — Environments include dev, staging, and production
- [script-verifiable] SV-05 — Environment parity strategy specified (parity keyword present)
- [script-verifiable] SV-06 — Deployment section present (## Deployment heading)
- [script-verifiable] SV-07 — Load balancing and scaling approach specified (auto-scaling / load balancing keyword present)
- [script-verifiable] SV-08 — Networking design documented (VPC / subnet / CDN / security-group keyword present)
- [script-verifiable] SV-09 — IaC section present (## IaC heading)
- [script-verifiable] SV-10 — IaC tool named (Terraform / Pulumi / CloudFormation / CDK / Bicep / OpenTofu / Ansible)
- [script-verifiable] SV-11 — State management strategy specified (state-management / remote-state / state-locking keyword present)
- [script-verifiable] SV-12 — Observability section present (## Observability heading)
- [script-verifiable] SV-13 — Alerting and escalation policies specified (alerting / escalation / on-call keyword present)
- [script-verifiable] SV-14 — Distributed tracing / correlation IDs planned (tracing / correlation-id keyword present)
- [script-verifiable] SV-15 — Decisions recorded in devops-sidecar (sidecar reference present)
- [LLM-checkable] LLM-01 — Every environment has a defined purpose and access policy
- [LLM-checkable] LLM-02 — Environment parity strategy is coherent for the architecture
- [LLM-checkable] LLM-03 — Container/compute strategy matches workload characteristics
- [LLM-checkable] LLM-04 — Load balancing and scaling approach is technically sound
- [LLM-checkable] LLM-05 — IaC module structure aligns with service boundaries
- [LLM-checkable] LLM-06 — Logging strategy covers retention and aggregation for declared services
- [LLM-checkable] LLM-07 — Metrics and dashboards cover the declared services
- [LLM-checkable] LLM-08 — Alerting thresholds and escalation policies are realistic
- [LLM-checkable] LLM-09 — Promotion gates between environments are defined and sensible
- [LLM-checkable] LLM-10 — Infrastructure decisions traceable to architecture components they serve

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-infra-design/scripts/finalize.sh

## Next Steps

- **Primary:** `/gaia-trace` — regenerate the requirements-to-tests traceability matrix once infra is designed.
