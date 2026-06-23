---
name: gaia-infra-design
description: Design infrastructure topology and IaC structure through collaborative discovery with the devops subagent (Soren) — architecture skill. Use when the user wants to produce an infrastructure design document covering deployment topology, environment design, IaC structure, and observability plan.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
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

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-infra-design/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh devops decision-log

## Mission

You are orchestrating the creation of an Infrastructure Design document. The infrastructure authoring is delegated to the **devops** subagent (Soren), who designs deployment topology, environment layout, IaC structure, and observability plans. You load the architecture document, validate inputs, coordinate the multi-step flow, and write the output to `.gaia/artifacts/planning-artifacts/infrastructure-design.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/3-solutioning/infrastructure-design` workflow. The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- An architecture document MUST exist at `.gaia/artifacts/planning-artifacts/architecture.md` before starting. If missing, fail fast with "Architecture doc not found at .gaia/artifacts/planning-artifacts/architecture.md — run /gaia-create-arch first."
- Every significant infrastructure decision must be recorded in the devops-sidecar memory.
- Every environment must have a defined purpose and access policy.
- Infrastructure authoring is delegated to the `devops` subagent (Soren) via native Claude Code subagent invocation — do NOT inline Soren's persona into this skill body. If the devops subagent is not available, fail with "devops subagent not available" error.
- If `.gaia/artifacts/planning-artifacts/infrastructure-design.md` already exists, warn the user: "An existing infrastructure design document was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.

## Steps

### Step 1 — Load Architecture

- Read `.gaia/artifacts/planning-artifacts/architecture.md`.
- Extract component inventory, service boundaries, data stores.
- Identify compute, storage, and networking requirements.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 1 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" topology_version="$TOPOLOGY_VERSION"`

### Step 2 — Environment Design

Delegate to the **devops** subagent (Soren) via `agents/devops` to design environments.

- Define environments: dev, staging, production (+ preview if needed).
- Specify environment parity strategy — how close staging mirrors production.
- Define access policies and promotion gates between environments.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 2 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=environments`

### Step 3 — Deployment Topology

Delegate to the **devops** subagent (Soren) via `agents/devops` to design the deployment topology.

**Topology-aware.** First read `project-config.yaml` (and the
architecture doc) to determine whether the target is cloud, on-prem/local, or
hybrid. Design to the ACTUAL topology — do NOT force cloud concepts onto a
local/on-prem project just to satisfy the checklist. The SV-07/08/10/11 gates in
`finalize.sh` accept on-prem-appropriate idioms (firewall/loopback/localhost for
networking; systemd/supervisor/pm2/replicas for scaling; Ansible/Chef/Puppet for
IaC; local-state/stateless/idempotent-convergence for state).

- Define the orchestration / process model appropriate to the topology:
  - **cloud:** Kubernetes, ECS, serverless, etc.
  - **on-prem / local:** systemd units, a process supervisor (supervisor/pm2),
    Docker Compose, or a documented single-instance posture.
- Design the load-balancing / request-routing approach (cloud LB + service mesh,
  or an on-prem reverse proxy / nginx / HAProxy, or single-host direct binding).
- Specify scaling strategy: horizontal, vertical, auto-scaling triggers (cloud)
  OR worker/replica counts, vertical-only, or single-instance (on-prem/local).
- Define networking to the topology: VPC / subnets / security groups / CDN
  (cloud) OR firewall rules / loopback / localhost binding (on-prem/local).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 3 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=topology`

### Step 4 — IaC Structure

Delegate to the **devops** subagent (Soren) via `agents/devops` to define infrastructure-as-code.

- Define Infrastructure-as-Code project structure and module design.
- Specify IaC tool and conventions (Terraform, Pulumi, CloudFormation).
- Design module boundaries matching service boundaries.
- Define state management strategy.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 4 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=iac`

### Step 5 — Observability Plan

Delegate to the **devops** subagent (Soren) via `agents/devops` to define observability.

- Define logging strategy: structured logs, log aggregation, retention.
- Define metrics: application metrics, infrastructure metrics, custom dashboards.
- Define tracing: distributed tracing, correlation IDs.
- Define alerting: SLO-based alerts, escalation policies, on-call rotation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 5 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=observability`

### Step 6 — Generate Output

- Record key decisions in devops-sidecar memory.
- Write the infrastructure design document to `.gaia/artifacts/planning-artifacts/infrastructure-design.md` with: environment matrix, deployment topology, IaC structure, observability plan, and decision rationale.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/infrastructure-design.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 6 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=output --paths .gaia/artifacts/planning-artifacts/infrastructure-design.md`

### Step 7 — Val Auto-Fix Loop

> Reuses the canonical pattern at `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/infrastructure-design.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/infrastructure-design.md`, `artifact_type = infrastructure-design`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/infrastructure-design.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch.

> Val auto-review per the canonical pattern. Val's scope here is the artifact file ONLY (`.gaia/artifacts/planning-artifacts/infrastructure-design.md`). The devops-sidecar memory writes performed in Step 6 are out of scope for Val (sibling pattern with the threat-model contract).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-infra-design 7 project_name="$PROJECT_NAME" target_environments="$TARGET_ENVIRONMENTS" iac_stack="$IAC_STACK" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/infrastructure-design.md`

#### Hydrate project-config.yaml

> **Run order — strict.** Runs ONLY AFTER Step 7 (Val Auto-Fix Loop) has completed
> and `.gaia/artifacts/planning-artifacts/infrastructure-design.md` is the validated final
> artifact. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-hydration.sh`, then
> build two `mktemp` YAML fragment files from the devops-subagent output — one
> with `environments:` payload (environment matrix from Step 2) and one with
> `ci_cd:` payload (promotion chain + workflows from Step 4 / Step 3) — and call
> `config_hydrate_section environments <file>` followed by
> `config_hydrate_section ci_cd <file>` (the helper's second arg is
> a file path, not a literal string). `rm -f` both fragment files after the
> calls return.

> **Idempotency contract.** When `config_phase` is already `partial`,
> both calls are state-machine no-ops — the helper does NOT advance
> `config_phase` (audit comments and section content may be rewritten by the
> editor replace path, but the phase enum remains `partial`). **AC3 invariant:** `partial` does NOT auto-advance to
> `full` even when all four allowlisted sections (`stacks`, `platforms`,
> `environments`, `ci_cd`) are now populated. The `partial → full` transition
> requires explicit user intent via `/gaia-init --full` or all sections
> manually present before init; hydration triggers never write
> `config_phase: full` (reserved for `validate-project-config.sh`). When `config_phase` is `minimal`, the helper writes the
> section and advances `config_phase` to `partial` monotonically. When
> `config_phase` is already `full`, both calls are no-ops.

> **Non-blocking error policy.** Capture `$?` from each call. The helper already
> logs `config-hydration: WARN/CRITICAL ...` to stderr for any failure (rc=0 ok,
> rc=1 generic, rc=2 allowlist, rc=3 lock timeout); a non-zero rc does NOT HALT
> the workflow — `infrastructure-design.md` has already been written and is the
> primary artifact. The flock helper coordinates with the sibling
> `/gaia-create-arch` trigger which hydrates `stacks` and
> `platforms`; concurrent runs are serialized by the shared
> `config/.config-hydration.lock`. The hydration trigger is purely
> a SKILL.md finalize-step addition; no devops subagent or infrastructure
> design document format changes.

## Validation

<!--
  V1→V2 25-item checklist port.
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

  The checklist anchor is SV-11 — "State management strategy specified".
  This is the V1 phrase verbatim and MUST appear in violation output
  when the state-management item fails (story AC2).

  Invoked by `finalize.sh` at post-complete. Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).
-->

- [script-verifiable] SV-01 — Output file saved to .gaia/artifacts/planning-artifacts/infrastructure-design.md
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

## References

- Schema: `gaia-public/plugins/gaia/schemas/infrastructure-design.schema.json` (JSON Schema draft-2020-12) — the structural contract for the `infrastructure-design` artifact this skill produces. Validated by `/gaia-val-validate` (artifact_type `infrastructure-design`) via the shared `scripts/lib/validate-artifact-schema.sh` helper.
- Corpus instance: `.gaia/artifacts/planning-artifacts/assessments/infrastructure-design.md` — the on-disk exemplar the schema is grounded in (eleven canonical H2 sections + YAML frontmatter).
- Validator: `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md` — `artifact_type` enum now carries `infrastructure-design`.
- Shared validator lib: `gaia-public/plugins/gaia/scripts/lib/validate-artifact-schema.sh` — backend-cascade JSON-schema validator (ajv → python3+jsonschema → graceful SKIP).

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

This skill is ready to run under Mode B (persistent teammates). When the team
lead routes this skill through Mode B, the infrastructure-design subagent (gaia:devops) runs as a
persistent teammate instead of a foreground subagent. The output shape is
identical between modes — only the dispatch seam differs.

- **Bridge library.** Mode B routing for this skill goes through the shared
  bridge `scripts/lib/research-mode-b-bridge.sh`, which itself routes through
  the shared dispatch library `scripts/lib/dispatch-teammate.sh`.
- **Spawn seam.** `research_spawn_subagent "gaia:devops" "gaia-infra-design"` runs the
  working teammate and returns its handle. Each working turn is relayed to the
  team lead verbatim via `research_relay_turn`, preserving transcript parity
  with the Mode A subagent path.
- **Shutdown seam.** `research_shutdown` runs at skill exit, routing through
  `shutdown_all` so no teammate pane is left orphaned.
- **Mode A fallback.** When the Mode B substrate is absent, the bridge degrades
  to a foreground Mode A path and surfaces a single `MODE_B_FALLBACK` token, so
  the skill keeps working with no change to its authored output.
