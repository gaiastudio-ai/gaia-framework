---
template: 'ux-design'
version: 1.0.0
used_by: ['greenfield-ux']
---

# UX Design: {product_name}

> **Project:** {project_name}
> **Date:** {date}
> **Author:** {agent_name}
> **Mode:** Greenfield — designed from the PRD

## 1. UX Overview

{One-paragraph summary of the product's user experience goals, the primary
audience, and the design principles guiding this work.}

## 2. Personas

| Persona | Role / Context | Goals | Pain Points | Tech Comfort |
|---------|----------------|-------|-------------|--------------|
| {name} | {who they are, when they show up} | {what they want to accomplish} | {what frustrates them today} | {low / medium / high} |

## 3. Information Architecture

{Describe the top-level structure — primary navigation, content hierarchy, and
how major areas relate. A simple tree or list is fine.}

- {Area 1}
  - {Sub-area}
- {Area 2}

## 4. User Flows

> Document BOTH the happy path and at least one error/edge path per flow
> (empty / loading / error / no-data / offline). Mirrors the PRD §6 journeys.

| Flow | Path | Entry | Steps | Outcome |
|------|------|-------|-------|---------|
| {flow name} | happy | {entry point} | {primary steps} | {success state} |
| {flow name} | error | {edge / failure trigger} | {detection + response} | {recovery / surfaced error} |

## 5. Wireframe Descriptions

### 5.1 {Screen Name}

- **Purpose:** {what this screen is for}
- **Key elements:** {primary components, top to bottom}
- **States:** default, loading, empty, error (describe each)
- **Primary actions:** {what the user can do}

## 6. Interaction Patterns

### Forms
{Validation timing (inline / on-submit), error messaging, required-field
affordances, save/autosave behaviour.}

### Modals & Dialogs
{When modals are used vs inline, focus trapping, dismissal, confirmation
patterns for destructive actions.}

### Notifications & Feedback
{Toasts vs banners vs inline; success / warning / error treatments; loading
and progress indicators.}

## 7. Accessibility

> Plan WCAG 2.1 AA at design time — do not defer to implementation.

- **Keyboard navigation:** {tab order, focus management, shortcuts}
- **Screen reader:** {landmark structure, labels, live regions}
- **Color & contrast:** {minimum contrast targets, non-colour cues}
- **Motion & timing:** {reduced-motion support, no time-limited content}
- **Touch targets:** {minimum sizes, spacing for mobile}

## 8. Design System / Component Reuse

{Which existing design-system components/patterns to reuse vs build custom, and
why. Note any new components this design introduces.}

## 9. Figma Integration

{If a Figma MCP server is connected, link the relevant frames/components here
and note the file key. If Figma is NOT available, state "No Figma source —
text-only UX design" and keep this section as the single source of truth for the
visual intent so downstream stories are not blocked.}

## 10. Open Questions

- {Unresolved UX decision needing stakeholder/PM input}
