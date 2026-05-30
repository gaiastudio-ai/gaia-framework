---
template: 'prd'
version: 1.1.0
used_by: ['create-prd', 'brownfield']
# Brownfield frontmatter keys (Test10 F-13). On a greenfield authoring flow these
# remain as placeholders; the brownfield orchestrator (Phase 8a) overwrites them.
project_type: '{application | infrastructure | platform}'  # default: application
target_environment: '{e.g., production, staging — leave empty on greenfield}'
infra_stack: '{e.g., kubernetes, ecs, lambda — empty on application-only}'
mode: '{greenfield | brownfield}'                          # set by orchestrator
baseline_version: '{version from package.json or inferred — brownfield only}'
focus: '{full-spec | gap-filling}'                         # gap-filling = brownfield
---

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

> **Severity vocabulary (Test10 F-13).** This PRD reports CRITICAL / WARNING / INFO
> per the canonical 3-tier map (5-into-3, see `/gaia-config-severity`). The legacy
> 5-tier (Critical / High / Medium / Low) is preserved here as the user-visible
> bucket labels; the WARNING / INFO columns map to the Sage adversarial reviewer
> output and the `info`-tier findings emitted by deterministic-tools scans.

| Category | Critical | High | Medium | Low | Info | Total |
|----------|----------|------|--------|-----|------|-------|
| Config Contradictions | {count} | {count} | {count} | {count} | {count} | {count} |
| Dead Code & Dead State | {count} | {count} | {count} | {count} | {count} | {count} |
| Hard-Coded Business Logic | {count} | {count} | {count} | {count} | {count} | {count} |
| Security Endpoints | {count} | {count} | {count} | {count} | {count} | {count} |
| Runtime Behaviors | {count} | {count} | {count} | {count} | {count} | {count} |
| Documentation Drift | {count} | {count} | {count} | {count} | {count} | {count} |
| Integration Seams | {count} | {count} | {count} | {count} | {count} | {count} |
| **Overall** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** |

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

### Verified By Legend

| Value | Description |
|-------|-------------|
| `machine-detected` | Gap found by automated scan subagent |
| `adversarial-review-detected` | Gap found during adversarial review |
| `code-verified` | Gap confirmed by code-verified review step |
| `human-reported` | Gap reported manually by a human reviewer |

<!-- BROWNFIELD-ONLY-END -->
