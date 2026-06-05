---
template: 'architecture'
version: 1.0.0
used_by: ['create-architecture']
---

# Architecture Document: {product_name}

> **Project:** {project_name}
> **Date:** {date}
> **Author:** {agent_name}

## 1. System Overview

{High-level description of the system and its purpose.}

## 2. Architecture Decisions

| ID | Decision | Rationale | Status |
|----|----------|-----------|--------|
| ADR-NNN | {decision} | {why} | Accepted |

## 3. System Components

### 3.1 {Component Name}

- **Responsibility:** {what it does}
- **Technology:** {stack/framework}
- **Interfaces:** {APIs or protocols exposed}

## 4. Data Architecture

### Data Model

{Key entities and their relationships.}

### Data Flow

{How data moves through the system.}

## 5. Integration Points

| System | Protocol | Direction | Purpose |
|--------|----------|-----------|---------|
| {system} | {REST/gRPC/etc} | {in/out/both} | {purpose} |

## 6. Infrastructure

{Deployment topology, environments, scaling approach.}

## 7. Security Architecture

{Authentication, authorization, data protection approach.}

## 8. Cross-Cutting Concerns

- **Logging:** {approach}
- **Monitoring:** {approach}
- **Error handling:** {approach}

## 9. Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|-----------|
| {risk} | {H/M/L} | {H/M/L} | {mitigation} |
