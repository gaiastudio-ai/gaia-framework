---
template: 'platform-prd'
version: 1.0.0
used_by: ['create-prd', 'brownfield']
# Brownfield frontmatter keys (Test10 F-13). On a greenfield authoring flow these
# remain as placeholders; the brownfield orchestrator (Phase 8a) overwrites them.
project_type: 'platform'
target_environment: '{e.g., production, staging, dev}'
infra_stack: '{e.g., kubernetes + service-mesh + control-plane}'
mode: '{greenfield | brownfield}'
baseline_version: '{platform release tag — brownfield only}'
focus: '{full-spec | gap-filling}'
---

# Platform PRD: {platform_name}

> **Project:** {project_name}
> **Date:** {date}
> **Author:** {agent_name}
> **Status:** Draft | In Review | Approved
> **Closes:** Test10 F-08 — platform-prd-template.md HALT-if-missing referenced by `/gaia-brownfield` Phase 8a.

## 1. Overview

{Platform overview. A platform PRD combines application-level FR/NFR with infrastructure-level IR/OR/SR — both surface areas are in scope because a platform exposes a self-service substrate to internal consumers.}

## 2. Goals and Non-Goals

### Goals
- {Platform goal 1 — e.g., reduce onboarding time for new service teams to <1 day}
- {Platform goal 2 — e.g., enforce a paved-road CI/CD pipeline}

### Non-Goals
- {Out of scope — e.g., supporting bespoke per-team infra}

## 3. Consumer Stories

> Platform PRDs use Consumer (Cn-NN) stories — the primary actor is the internal
> developer / team-lead consuming the platform's self-service surface.

| ID | As a... | I want to... | So that... | Priority |
|----|---------|-------------|-----------|----------|
| Cn-01 | {role: app developer, team lead, SRE} | {action} | {benefit} | {P0-P3} |

## 4. Functional Requirements (FR)

> FR-### IDs cover the platform's self-service capabilities (paved-road APIs, golden paths).

### 4.1 {Capability Area}

- **FR-01:** {Requirement description}
- **FR-02:** {Requirement description}

## 5. Non-Functional Requirements (NFR)

| ID | Category | Requirement | Target |
|----|----------|------------|--------|
| NFR-001 | Performance | {requirement} | {target} |
| NFR-002 | Reliability | {requirement} | {SLO} |
| NFR-003 | Security | {requirement} | {target} |

## 6. Infrastructure Requirements (IR)

> Platform PRDs ALSO carry IR/OR/SR sections because they own the substrate.

| ID | Capability | Requirement | Target |
|----|------------|-------------|--------|
| IR-001 | Provisioning | {requirement} | {target} |
| IR-002 | Topology | {requirement} | {target} |

## 7. Operational Requirements (OR)

| ID | Category | Requirement | Target |
|----|----------|-------------|--------|
| OR-001 | Availability | {requirement} | {SLO target} |
| OR-002 | Tenant Isolation | {requirement} | {target} |
| OR-003 | Observability | {requirement} | {coverage} |

## 8. Security Requirements (SR)

| ID | Category | Requirement | Target |
|----|----------|-------------|--------|
| SR-001 | Multi-tenancy | {policy} | {target} |
| SR-002 | IAM | {policy} | {target} |
| SR-003 | Compliance | {regulatory regime} | {target} |

## 9. Self-Service Surface

| Capability | Interface | Auth | SLO |
|------------|-----------|------|-----|
| {capability} | {CLI / API / Portal} | {OAuth / mTLS} | {target} |

## 10. Tenant Model

| Tenant Tier | Isolation Level | Quota | Cost Model |
|-------------|-----------------|-------|------------|
| {tier} | {pod / namespace / cluster} | {limit} | {pricing} |

## 11. Migration / Adoption Path

- **Onboarding flow:** {steps for a new consumer team}
- **Existing-tenant migration:** {how legacy consumers adopt the new platform shape}
- **Rollback plan:** {how to revert}

## 12. Dependencies

| Dependency | Type | Provider | Failure Mode | Fallback |
|------------|------|----------|--------------|----------|
| {service} | {SaaS / managed / internal} | {vendor} | {what breaks} | {graceful degradation} |

## 13. Success Criteria

| Metric | Definition | Target | Measurement Method |
|--------|------------|--------|--------------------|
| {KPI} | {definition} | {threshold} | {dashboard / monitor} |

## 14. Open Questions

- [ ] {Unresolved platform question}

<!-- BROWNFIELD-ONLY-START -->

## Gap Analysis Summary

> Severity columns include CRITICAL / WARNING / INFO per the canonical 3-tier map
> (Test10 F-13). Legacy 5-tier (Critical / High / Medium / Low) is preserved as
> user-visible buckets.

| Category | Critical | High | Medium | Low | Info | Total |
|----------|----------|------|--------|-----|------|-------|
| Self-Service Surface Drift | {count} | {count} | {count} | {count} | {count} | {count} |
| Tenant Isolation Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| Observability Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| Topology Drift | {count} | {count} | {count} | {count} | {count} | {count} |
| Capacity Risks | {count} | {count} | {count} | {count} | {count} | {count} |
| Compliance Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| **Overall** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** |

## Gap Analysis by Category

### Self-Service Surface Drift (`platform`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Tenant Isolation Gaps (`security`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### Observability Gaps (`operational`)

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
