---
template: 'prd'
version: 1.0.0
used_by: ['create-prd']
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

| Journey | Trigger | Steps | Outcome |
|---------|---------|-------|---------|
| {journey name} | {what initiates it} | {primary path through the product} | {what the user achieves} |

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

| Category | Critical | High | Medium | Low | Total |
|----------|----------|------|--------|-----|-------|
| Config Contradictions | {count} | {count} | {count} | {count} | {count} |
| Dead Code & Dead State | {count} | {count} | {count} | {count} | {count} |
| Hard-Coded Business Logic | {count} | {count} | {count} | {count} | {count} |
| Security Endpoints | {count} | {count} | {count} | {count} | {count} |
| Runtime Behaviors | {count} | {count} | {count} | {count} | {count} |
| Documentation Drift | {count} | {count} | {count} | {count} | {count} |
| Integration Seams | {count} | {count} | {count} | {count} | {count} |
| **Overall** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** |

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
