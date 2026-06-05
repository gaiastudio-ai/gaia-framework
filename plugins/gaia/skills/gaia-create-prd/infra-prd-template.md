---
template: 'infra-prd'
version: 1.0.0
used_by: ['create-prd', 'brownfield']
# Brownfield frontmatter keys. On a greenfield authoring flow these
# remain as placeholders; the brownfield orchestrator (Phase 8a) overwrites them.
project_type: 'infrastructure'
target_environment: '{e.g., production, staging, edge}'
infra_stack: '{e.g., kubernetes, ecs, lambda, terraform}'
mode: '{greenfield | brownfield}'
baseline_version: '{version from infra tag or inferred — brownfield only}'
focus: '{full-spec | gap-filling}'
---

# Infrastructure PRD: {component_name}

> **Project:** {project_name}
> **Date:** {date}
> **Author:** {agent_name}
> **Status:** Draft | In Review | Approved

## 1. Overview

{Brief infrastructure overview. What component is being provisioned / changed and why. Reference the target_environment + infra_stack from frontmatter.}

## 2. Goals and Non-Goals

### Goals
- {Infra goal 1 — e.g., zero-downtime deployment for service X}
- {Infra goal 2 — e.g., consolidate cluster autoscaling policy}

### Non-Goals
- {Explicitly out of scope — e.g., migrating service Y in the same PRD}

## 3. Operator Stories

> Infrastructure PRDs use Operator (Op-NN) stories instead of User Stories — the
> primary actor is the operator / SRE / platform engineer.

| ID | As an... | I want to... | So that... | Priority |
|----|----------|-------------|-----------|----------|
| Op-01 | {role: SRE, on-call, platform admin} | {action} | {benefit} | {P0-P3} |

## 4. Infrastructure Requirements (IR)

> IR-### IDs replace functional-requirement IDs for infra PRDs (see `/gaia-brownfield` Phase 8a ID-scheme table).

### 4.1 {Capability Area}

- **IR-01:** {Provisioning / capacity / topology requirement}
- **IR-02:** {Configuration management requirement}

## 5. Operational Requirements (OR)

> OR-### IDs cover runbook-level operational expectations.

| ID | Category | Requirement | Target |
|----|----------|------------|--------|
| OR-001 | Availability | {requirement} | {SLO target} |
| OR-002 | Disaster Recovery | {requirement} | {RPO / RTO} |
| OR-003 | Observability | {requirement} | {metrics / alerts coverage} |

## 6. Security Requirements (SR)

> SR-### IDs cover infrastructure-level security posture — IAM, network policy, key management.

| ID | Category | Requirement | Target |
|----|----------|------------|--------|
| SR-001 | Network | {policy} | {target} |
| SR-002 | IAM | {policy} | {target} |
| SR-003 | Secrets | {policy} | {target} |

## 7. Topology

> Document the network / compute / storage topology. Embed a diagram reference
> (mermaid block, ASCII tree, or path to a `.png` under `.gaia/artifacts/`).

```
{topology diagram or path reference}
```

## 8. Capacity & Cost Model

| Component | Sizing | Estimated Cost ($/mo) | Scale Trigger |
|-----------|--------|----------------------|---------------|
| {compute pool} | {node count × type} | {estimate} | {CPU% / queue depth / etc.} |

## 9. Failure Modes

| Failure | Blast Radius | Detection | Mitigation | RTO |
|---------|--------------|-----------|------------|-----|
| {failure scenario} | {scope} | {alert / monitor} | {playbook reference} | {minutes} |

## 10. Dependencies

| Dependency | Type | Provider | Failure Mode | Fallback |
|------------|------|----------|--------------|----------|
| {service} | {SaaS / managed / internal} | {vendor} | {what breaks} | {graceful degradation} |

## 11. Migration / Rollback

- **Migration steps:** {ordered, idempotent steps}
- **Rollback plan:** {how to revert, who triggers, expected duration}

## 12. Success Criteria

| Metric | Definition | Target | Measurement Method |
|--------|------------|--------|--------------------|
| {SLO / KPI} | {definition} | {threshold} | {monitor / dashboard path} |

## 13. Open Questions

- [ ] {Unresolved infra question}

<!-- BROWNFIELD-ONLY-START -->

## Gap Analysis Summary

> Severity columns include CRITICAL / WARNING / INFO per the canonical 3-tier map.
> Legacy 5-tier (Critical / High / Medium / Low) is preserved as
> user-visible buckets; WARNING / INFO map to adversarial-review and `info`-tier
> deterministic-tools findings.

| Category | Critical | High | Medium | Low | Info | Total |
|----------|----------|------|--------|-----|------|-------|
| Topology Drift | {count} | {count} | {count} | {count} | {count} | {count} |
| IAM / Network Policy Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| Observability Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| Capacity Risks | {count} | {count} | {count} | {count} | {count} | {count} |
| Disaster Recovery Gaps | {count} | {count} | {count} | {count} | {count} | {count} |
| Cost Anomalies | {count} | {count} | {count} | {count} | {count} | {count} |
| **Overall** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** | **{count}** |

## Gap Analysis by Category

### Topology Drift (`infrastructure`)

| ID | Severity | Title | Description | Evidence | Recommendation | Verified By | Confidence |
|----|----------|-------|-------------|----------|----------------|-------------|------------|
| — | — | No gaps detected in this category. | — | — | — | — | — |

### IAM / Network Policy Gaps (`security`)

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
