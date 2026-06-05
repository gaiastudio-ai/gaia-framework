---
title: Product Requirements Document — E42-S6 Negative Fixture (VCP-CHK-12)
date: 2026-04-24
product: "Helix Cross-Border Payments"
version: "0.1.0"
---

# PRD: Helix Cross-Border Payments (Missing Dependency Failure Modes)

## Overview

This fixture is identical to the positive fixture except the Dependencies section
lists dependencies without failure-mode or fallback-behavior text. VCP-CHK-12
asserts the ported checklist catches this and names the violation by its V1 string.

## Goals and Non-Goals

- Goal: Sub-4-hour settlement finality for 95 percent of transactions across launch corridors.
- Non-Goal: Consumer P2P payments.

## User Stories

- As Dana, an AP manager, I want predictable settlement windows so I can hit vendor payroll cutoffs.
- As Marco, a treasurer, I want rate-lock at initiation so I can commit to cash-flow plans.

## User Personas

- Dana (AP manager), Marco (Treasurer).

## Functional Requirements

- FR-001 — Initiate payment with idempotency key, returns locked quote.
  - Acceptance Criteria: API returns a locked quote within 200 ms.
- FR-002 — Confirm payment within the 120-second rate-lock window.
  - Acceptance Criteria: Payment confirmed at the locked rate before window expiry.

## Non-Functional Requirements

- NFR-001 — API uptime 99.95 percent measured monthly.
- NFR-002 — p99 latency under 800 ms on POST /payments.

## User Journeys

- Happy path: Initiate -> Confirm -> Settle.
- Error path: Lock expiry returns 409 LOCK_EXPIRED.

## Data Requirements

- Payment records retained for 7 years per FinCEN.

## Integration Requirements

- NetSuite, SAP, QuickBooks.

## Out of Scope

- Consumer P2P payments.
- Crypto on-ramp.

## Constraints and Assumptions

- Must run on AWS; GA within 9 months.

## Success Criteria

- 30 paying customers each processing ≥ $100k per month by month 9.
- 99.95 percent API uptime.

## Dependencies

- TRP (travel-rule vendor).
- Castellum (sanctions vendor).
- Corridor partner network.
- AWS us-east-1 region.

## Milestones

- M1, M2, M3.

## Requirements Summary

| ID | Description | Priority | Status |
|----|-------------|----------|--------|
| FR-001 | Initiate payment with idempotency | Must | Proposed |
| FR-002 | Confirm within lock window | Must | Proposed |
| NFR-001 | 99.95 percent uptime | Must | Proposed |
| NFR-002 | p99 < 800 ms | Must | Proposed |

## Open Questions

- None.

## Review Findings Incorporated

Adversarial review not triggered — change type: feature.

> Auto-appended by `gaia-create-prd/scripts/finalize.sh` per AF-2026-05-24-9 / Test02 F-4. If the change type was not "feature" or an adversarial review WAS performed, this stub will be overwritten by Step 14's authored content on re-run.
