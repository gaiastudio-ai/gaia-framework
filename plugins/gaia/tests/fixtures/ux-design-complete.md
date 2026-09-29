---
title: UX Design — E42-S7 Positive Fixture
date: 2026-04-24
product: "Helix Cross-Border Payments"
version: "0.1.0"
---

# UX Design: Helix Cross-Border Payments

## Personas

- **Dana — AP Manager (mid-market, fintech-adjacent).** Scenarios: weekly vendor payouts on
  US-to-EU corridor. Goals: hit vendor cut-offs, avoid failed payments. Tech proficiency: high.
  Accessibility needs: low-vision; relies on AA-contrast throughout the console.
- **Marco — Treasurer (enterprise, cross-border ops).** Scenarios: quarterly working-capital
  optimisation. Goals: rate-lock at initiation; visible settlement finality. Tech proficiency:
  medium. Accessibility needs: prefers keyboard shortcuts for all primary flows.
- **Opal — Operator (internal, AML exception queue).** Scenarios: triages flagged payments in
  real time. Goals: resolve exceptions with full context. Tech proficiency: expert.

Each persona traces back to a PRD user definition (see `docs/planning-artifacts/prd.md` ## User
Personas).

## Information Architecture

Sitemap and navigation structure for the Helix console.

```
/dashboard
  /payments
    /payments/initiate     — initiate a new corridor payment (FR-001)
    /payments/confirm      — confirm within the 120-second lock (FR-002)
    /payments/history      — searchable history with reconciliation export (FR-005)
  /exceptions
    /exceptions/queue      — operator AML triage console (FR-004)
  /settings
    /settings/api-keys
    /settings/webhooks     — webhook management (FR-003)
```

Content hierarchy: Dashboard is the default landing; Payments and Exceptions are the primary
top-level entries. Every page maps to at least one PRD FR ID.

## Wireframes

Text-based wireframes for the key screens. Each wireframe annotates the FR it addresses.

### 1. Initiate Payment (FR-001)

- **Layout:** two-column form (left: amount + corridor; right: locked quote summary).
- **Key components:** amount input with currency selector, corridor dropdown, idempotency-key
  display, "Get quote" primary action, "Lock quote" secondary action.
- **Interactions:** on "Get quote", a rate-locked quote renders in the right column with a
  countdown timer (120 seconds). When the lock expires, the panel transitions to the expired
  state and the primary action re-enables.

### 2. Confirm Payment (FR-002)

- **Layout:** centred confirmation card with quote summary, countdown, and two actions.
- **Key components:** quote summary table, countdown badge, "Confirm" primary button,
  "Cancel" secondary link.
- **Interactions:** confirming within the window transitions to the "Authorised" state;
  confirming after expiry shows the 409 LOCK_EXPIRED error inline.

### 3. Exception Queue (FR-004)

- **Layout:** list-detail master with a left-hand queue and a right-hand detail pane.
- **Key components:** queue row (payment ID, amount, corridor, flag reason), detail pane
  with KYC packet, "Release" and "Hold" actions.
- **Interactions:** selecting a queue row populates the detail pane; releasing transitions
  the item back to the settlement pipeline.

## Interaction Patterns

Common UI patterns used across the console.

- **Forms:** inline validation on blur, summary error banner on submit, optimistic loading
  states on non-destructive actions.
- **Form behaviors:** the Initiate Payment form uses client-side validation for amount ranges
  and server-side validation for corridor eligibility. Submission is blocked until every
  required field passes client-side validation.
- **Error states:** field-level errors render inline in red beneath the input; page-level
  errors render in a banner above the form. All error copy uses the "Problem — Fix" pattern.
- **Loading states:** skeleton placeholders for list views; spinner overlays for modal
  actions; progress badges on long-running operations.
- **Empty states:** illustrated placeholder with a one-line message and a primary CTA
  ("No exceptions to triage" / "Clear filters").
- **Modals:** focus-trapped; Escape closes; ARIA role="dialog" with aria-modal="true".
- **Notifications:** toast for success, inline banner for errors, in-app notification
  badge on the top nav.

Each interaction flow traces to a PRD user journey:

- Initiate → Confirm → Settle maps to the happy path.
- Lock expiry handling maps to the Error-path: Lock expiry.
- AML hold handling maps to the Error-path: AML hold.

## Accessibility

- **WCAG compliance target:** WCAG 2.1 AA for all primary flows.
- **Keyboard navigation:** every interactive control reachable via Tab order; skip-links on
  every page; arrow-key navigation inside the exception queue.
- **Screen reader support:** ARIA live regions for toast messages; descriptive button labels;
  status landmarks announced via role="status".
- **Color contrast:** 4.5:1 minimum for body copy; 3:1 for large text and icons.
- **Focus management:** visible focus rings on all interactive elements; focus returns to the
  triggering element after modal dismissal.

## Components

Component specifications aligned with the Helix design system.

| Component | Variants | Usage |
|-----------|----------|-------|
| Button | Primary, Secondary, Destructive, Ghost | Form actions, navigation |
| Input | Text, Number, Currency, Dropdown | Payment initiation, settings |
| Table | Default, Compact, Zebra | Payments history, exception queue |
| Badge | Neutral, Success, Warning, Error | Status indicators, countdown |
| Toast | Success, Error, Info | Post-action feedback |
| Modal | Default, Confirm, Destructive | Dialogs, confirmations |

Each component description names its anatomy, states, and the tokens it consumes.

## FR-to-Screen Mapping

| FR ID | Screen / Page | Wireframe Reference |
|-------|---------------|---------------------|
| FR-001 | Initiate Payment | Wireframe 1 |
| FR-002 | Confirm Payment | Wireframe 2 |
| FR-003 | Webhook settings | /settings/webhooks |
| FR-004 | Exception Queue | Wireframe 3 |
| FR-005 | Payments history export | /payments/history |

## Design Record Reference

- **Project reference:** proj-helix-ds-001
- **Discovered via:** created
- **Questionnaire record:** .gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md

## Open Questions

- Should the exception queue support bulk actions in v1?
