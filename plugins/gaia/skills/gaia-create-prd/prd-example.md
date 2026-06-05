---
template: 'prd-example'
version: 1.0.0
used_by: ['calibration-reference']
---

# PRD Example — "Focus Timer" (calibration reference)

> **This is a calibration reference, not a real PRD.** It shows the expected
> depth and shape for a small-but-complete greenfield PRD authored from
> `prd-template.md`. Trim or expand per project size. It is NOT
> consumed by any skill — it exists so first-time authors can see "done".

## 1. Overview

Focus Timer is a single-user desktop app that runs Pomodoro-style focus sessions
(25-min work / 5-min break) with a minimal always-on-top timer and a daily
session log. Goal: help solo knowledge workers protect deep-work blocks without
a heavyweight productivity suite.

## 2. Scope

In scope: timer engine, session presets, daily log, desktop notifications.
Out of scope:
- Team/multi-user features.
- Cloud sync (local-only for v1).
- Mobile clients.

## 3. User Stories

> Priority: `P0` = Must-Have, `P1` = Should-Have, `P2` = Could-Have, `P3` = Won't-this-time.

| ID | As a... | I want to... | So that... | Priority |
|----|---------|-------------|-----------|----------|
| US-01 | solo worker | start a 25/5 focus session with one click | I protect a deep-work block | P0 |
| US-02 | solo worker | be notified when a phase ends | I switch context on time | P0 |
| US-03 | solo worker | see today's completed sessions | I track my focus | P1 |
| US-04 | solo worker | customise work/break durations | the rhythm fits my style | P2 |

## 4. Functional Requirements

### 4.1 Timer Engine
- **FR-01:** The app starts a focus session of the configured work duration on user action.
- **FR-02:** On work-phase completion, the app automatically begins the break phase.
- **FR-03:** The user can pause, resume, and reset the active session.

### 4.2 Notifications & Log
- **FR-04:** The app raises a desktop notification at each phase transition.
- **FR-05:** Each completed session is appended to a local daily log with start time + duration.

## 5. Non-Functional Requirements

| ID | Category | Requirement | Target |
|----|----------|-------------|--------|
| NFR-001 | Performance | Timer drift over a 25-min phase | < 1 s |
| NFR-002 | Reliability | Session log survives an unclean app exit | no data loss on crash |
| NFR-003 | Accessibility | Timer + controls operable by keyboard and screen reader | WCAG 2.1 AA |

## 6. User Journeys

| Journey | Path | Trigger | Steps | Outcome |
|---------|------|---------|-------|---------|
| Run a focus session | happy | user clicks Start | start → work phase → break phase → logged | session recorded |
| Notification blocked | error | OS denies notification permission | detect permission denial → fall back to in-app banner → prompt to enable | user still sees phase change |

## 7. Data Requirements

| Entity | Purpose | Key Attributes | Retention | PII / Sensitivity |
|--------|---------|----------------|-----------|-------------------|
| Session | record a completed focus block | id, started_at, work_min, break_min | local, user-clearable | none |

## 8. Success Criteria

- A user can complete an uninterrupted 25/5 session end-to-end with notifications.
- The daily log accurately reflects completed sessions across an app restart.
- All controls pass a keyboard-only + screen-reader smoke test (NFR-003).

## 15. Requirements Summary

| ID | Description | Priority | Status |
|----|-------------|----------|--------|
| FR-01 | Start a focus session | Must-Have | Draft |
| FR-04 | Phase-transition notification | Must-Have | Draft |
| FR-05 | Daily session log | Should-Have | Draft |
| NFR-003 | Keyboard + screen-reader operability | Must-Have | Draft |
