---
template: 'prd'
version: 1.2.0
used_by: ['create-prd', 'brownfield']
# Brownfield frontmatter keys (Test10 F-13). On a greenfield authoring flow these
# remain as placeholders; the brownfield orchestrator (Phase 8a) overwrites them.
project_type: '{application | infrastructure | platform}'  # default: application
target_environment: '{e.g., production, staging — leave empty on greenfield}'
infra_stack: '{e.g., kubernetes, ecs, lambda — empty on application-only}'
mode: '{greenfield | brownfield}'                          # set by orchestrator
baseline_version: '{version from package.json or inferred — brownfield only}'
focus: '{full-spec | gap-filling}'                         # gap-filling = brownfield
# AF-2026-06-01-1 / Test15 F-PRD-3: explicit output_path hint so the
# brownfield consolidator + downstream consumers don't have to infer the
# canonical destination from prose. The PRD always lands at
# planning-artifacts/prd.md per ADR-127 §7.2.
output_path: '.gaia/artifacts/planning-artifacts/prd.md'
---

<!--
AF-2026-06-01-1 / Test15 F-PRD-1 — Scan-prefix → heading legend.

When the brownfield orchestrator merges Phase-3 scan findings into this
PRD's gap list, each gap row carries an `id` whose prefix tags the
source scanner. The legend below defines the canonical set so a reader
of this PRD can decode an id without grepping the consolidation script:

| Prefix    | Source scanner            | Phase |
| --------- | ------------------------- | ----- |
| DCD-      | doc-code drift            | 3     |
| HCV-      | hardcoded values          | 3     |
| ISEAM-    | integration seam          | 3     |
| RTB-      | runtime behavior          | 3     |
| SEC-      | security                  | 3     |
| CFGC-     | config contradiction      | 3     |
| DC-       | dead code                 | 3     |
| CVE-      | grype CVE                 | 3     |
| SBM-      | sbom completeness         | 3     |

(Updated by AF-31-2 / Test12 D-03; pinned here in the template so it
travels with every generated PRD.)
-->

<!--
AF-2026-06-01-1 / Test15 F-PRD-2 — Severity vocabulary anchor.

This PRD uses the **3-tier** operator-facing severity vocabulary —
`high` / `medium` / `low` — as the priority on each requirement and
gap row. Phase-3 deterministic scans produce 5-tier scan severities
(Critical / High / Medium / Low / Info) per ADR-037; those are
reconciled into the 3-tier bucket at consolidation time per the
canonical mapping:

| Scan severity | This PRD's priority |
| ------------- | ------------------- |
| Critical      | high                |
| High          | high                |
| Medium        | medium              |
| Low           | low                 |
| Info          | (dropped — logged in scan-fidelity banner only) |

Authors of this PRD should use the 3-tier vocabulary only; the 5-tier
input vocabulary belongs in the source-of-truth scan reports under
`.gaia/memory/brownfield-audit/`. Pinned here per AF-31-2 / Test12 D-04.
-->


# Product Requirements Document: {product_name}

> **Project:** {project_name}
> **Date:** {date}
> **Author:** {agent_name}
> **Status:** Draft | In Review | Approved

## 1. Overview

{Brief product overview and context. What is being built and why.}

## 2. Goals and Non-Goals

### Goals
- {Goal 1}
- {Goal 2}

### Non-Goals
- {Explicitly out of scope item 1}

## 3. User Stories

> **Priority vocabulary (MoSCoW ↔ P0–P3 mapping).** This PRD uses two priority
> notations that map 1:1 — `P0` = **Must-Have** (ship-blocking), `P1` =
> **Should-Have** (important, not blocking), `P2` = **Could-Have / Nice-to-Have**
> (desirable if capacity allows), `P3` = **Won't-Have-this-time** (explicitly
> deferred). The User Stories table below uses `P0–P3`; the §15 Requirements
> Summary uses the Must/Should/Nice labels. Keep the two consistent per row.

| ID | As a... | I want to... | So that... | Priority |
|----|---------|-------------|-----------|----------|
| US-01 | {role} | {action} | {benefit} | {P0-P3} |

## 4. Functional Requirements

### 4.1 {Feature Area}

- **FR-01:** {Requirement description}
- **FR-02:** {Requirement description}

## 5. Non-Functional Requirements

| ID | Category | Requirement | Target |
|----|----------|------------|--------|
| NFR-001 | Performance | {requirement} | {target} |
| NFR-002 | Security | {requirement} | {target} |
| NFR-003 | Accessibility | {requirement} | {target} |

## 6. User Journeys

> Document BOTH the happy path AND at least one error/exception path per journey
> (empty/loading/failure/no-data/offline states). A journey with only a happy
> path is incomplete — Sage's adversarial checklist flags missing error paths.
> Use the `Path` column (`happy` / `error`) and add one row per path.

| Journey | Path | Trigger | Steps | Outcome |
|---------|------|---------|-------|---------|
| {journey name} | happy | {what initiates it} | {primary path through the product} | {what the user achieves} |
| {journey name} | error | {what triggers the failure/edge} | {how the product detects + responds} | {recovery / fallback / surfaced error} |

## 7. Data Requirements

| Entity | Purpose | Key Attributes | Retention | PII / Sensitivity |
|--------|---------|----------------|-----------|-------------------|
| {entity} | {what role it plays} | {fields / structure} | {how long it lives} | {none / PII / regulated} |

## 8. Integration Requirements

| Integration | Direction | Protocol | Auth | Failure Mode |
|-------------|-----------|----------|------|--------------|
| {external system} | {inbound / outbound / both} | {REST / GraphQL / webhook / message bus} | {OAuth / API key / mTLS} | {what happens on outage} |

## 9. Out of Scope

| Exclusion | Reason |
|-----------|--------|
| {feature or integration} | {deferred / not needed / separate product} |

## 10. UX Requirements

{Key interaction patterns, wireframe references, accessibility needs.}

## 11. Constraints

- {Platform, language, integration, regulatory, or business constraint}

## 12. Success Criteria

| Metric | Definition | Target | Measurement Method |
|--------|------------|--------|--------------------|
| {KPI or outcome} | {what counts as success} | {threshold / direction} | {how it's measured post-launch} |

## 13. Dependencies

| Dependency | Type | Failure Mode | Fallback Behavior | SLA Expectation |
|------------|------|-------------|-------------------|-----------------|
| {service or system} | {API / Database / Message Queue / CDN / Auth Provider} | {What happens when it's unavailable} | {Graceful degradation / Retry / Queue / Circuit breaker / Hard fail} | {Expected uptime / latency / throughput} |

## 14. Milestones

| Milestone | Target Date | Deliverables |
|-----------|------------|-------------|
| {milestone} | {date} | {deliverables} |

## 15. Requirements Summary

| ID | Description | Priority | Status |
|----|------------|----------|--------|
| FR-001 | {description} | {Must-Have/Should-Have/Nice-to-Have} | {Draft/Approved} |
| NFR-001 | {description} | {Must-Have/Should-Have/Nice-to-Have} | {Draft/Approved} |

## 16. Open Questions

- [ ] {Unresolved question}

<!-- BROWNFIELD-ONLY-START -->

## Gap Analysis Summary

> **Severity vocabulary (Test17 D-4 / AF-2026-06-02-6 — vocab reconciled).** This
> PRD reports CRITICAL / WARNING / INFO per the canonical **3-tier** map. Prior
> revisions of this template carried a 5-tier Critical / High / Medium / Low / Info
> column header which contradicted the 3-tier note in this paragraph — both the
> note and the table now agree on the 3-tier form. The 5-into-3 mapping for
> Phase-3 deterministic scans is at `/gaia-config-severity`:
> Critical/High → CRITICAL, Medium → WARNING, Low → WARNING, Info → INFO.

| Category | CRITICAL | WARNING | INFO | Total |
|----------|----------|---------|------|-------|
| Config Contradictions | {count} | {count} | {count} | {count} |
| Dead Code & Dead State | {count} | {count} | {count} | {count} |
| Hard-Coded Business Logic | {count} | {count} | {count} | {count} |
| Security Endpoints | {count} | {count} | {count} | {count} |
| Runtime Behaviors | {count} | {count} | {count} | {count} |
| Documentation Drift | {count} | {count} | {count} | {count} |
| Integration Seams | {count} | {count} | {count} | {count} |
| Stale Claims | {count} | {count} | {count} | {count} |
| **Overall** | **{count}** | **{count}** | **{count}** | **{count}** |

## Priority Matrix (brownfield)

> **Test17 D-4 / AF-2026-06-02-6.** The orchestrator's gap-priority synthesis lands
> here. Authors fill the four-quadrant matrix with the top 6-10 brownfield gaps
> ranked by impact × effort. CRITICAL gaps SHOULD appear in the High-Impact /
> Low-Effort or High-Impact / High-Effort quadrants. WARNING gaps SHOULD appear
> in the Low-Impact / Low-Effort quadrant (quick wins) or be acknowledged in the
> deferred section. INFO gaps are auxiliary — list them in the prose only.

| Quadrant | Gaps (IDs) | Action |
|----------|------------|--------|
| High Impact / Low Effort | {gap-ids — quick wins, top of backlog} | {sprint-1 candidates} |
| High Impact / High Effort | {gap-ids — strategic, scope to epic} | {epic-level scoping} |
| Low Impact / Low Effort | {gap-ids — opportunistic} | {batch later} |
| Low Impact / High Effort | {gap-ids — deferred} | {skip unless triggered} |

## Gap Analysis by Category

### Config Contradictions (`configuration`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Dead Code & Dead State (`functional`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Hard-Coded Business Logic (`functional`, `behavioral`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Security Endpoints (`security`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Runtime Behaviors (`behavioral`, `operational`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Documentation Drift (`documentation`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Integration Seams (`data-integrity`, `operational`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Stale Claims (`stale-claim`)

Gaps the consolidation surfaced from a baseline scan that a later orchestrator step (e.g. `/gaia-ci-setup`, a follow-up code-verified review, or a freshness re-check per Test17 D-7) has since closed. Each row records the original gap-id, the surfacing scan, AND the closing action so the audit trail shows the gap was real at baseline time.

| ID | Severity | Title | Description | Evidence | Recommendation | Closed By | Confidence |
|----|----------|-------|-------------|----------|----------------|-----------|------------|
| — | — | No stale claims detected. | — | — | — | — | — |

### Verified By Legend

| Value | Description |
|-------|-------------|
| `machine-detected` | Gap found by automated scan subagent |
| `adversarial-review-detected` | Gap found during adversarial review |
| `code-verified` | Gap confirmed by code-verified review step |
| `human-reported` | Gap reported manually by a human reviewer |

<!-- BROWNFIELD-ONLY-END -->
