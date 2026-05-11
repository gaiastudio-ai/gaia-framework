---
name: gaia-change-request
description: "DEPRECATED -- Thin redirect to gaia-add-feature. Preserved for backward compatibility per ADR-041 / FR-323. Use /gaia-add-feature directly."
argument-hint: "[request-text]"
allowed-tools: [Read, Glob, Bash, Skill]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-change-request/scripts/setup.sh

## Deprecation Notice (ADR-041 / FR-323)

> **This skill is deprecated.** `/gaia-change-request` is the legacy entry point for submitting change requests. All classification and cascade logic now lives in the `gaia-add-feature` skill. Callers should prefer `/gaia-add-feature` directly going forward.
>
> This thin redirect is preserved per ADR-041 (deprecated-but-routed commands remain callable for backward compatibility) and FR-323 (change-request triage and routing semantics). No change-request logic is implemented here -- the skill exists solely to forward invocations to the canonical handler.

## Mission

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/add-feature/` workflow's deprecated `change-request` entry point. The legacy workflow triaged and routed fixes, enhancements, and features through affected artifacts. That logic has been consolidated into `gaia-add-feature`, which handles all classification and cascade operations.

This skill acts as a backward-compatible redirect: it accepts the same invocation as the legacy command and forwards the user-supplied argument verbatim to `gaia-add-feature`.

## Steps

### Step 1 -- Display Deprecation Banner

Display the following deprecation notice so the user sees the redirect in the transcript:

> `/gaia-change-request` is deprecated -- forwarding to `/gaia-add-feature`.

### Step 2 -- Redirect to gaia-add-feature

Invoke the `gaia-add-feature` skill, forwarding the user-supplied argument verbatim:

```
/gaia-add-feature {argument}
```

The argument MUST be preserved exactly as the user typed it so that the classification logic in `gaia-add-feature` receives the same request text. If no argument was provided, invoke `gaia-add-feature` without an argument -- `gaia-add-feature` handles empty-argument prompts internally.

All classification (patch / enhancement / feature), cascade matrix execution, and artifact updates are handled by `gaia-add-feature`. No duplicate logic exists in this redirect skill.

### Step 3 -- Relay Result

When `gaia-add-feature` completes, relay its output (classification, cascade summary, created stories) back to the caller without modification. This skill does not write its own report.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-change-request/scripts/finalize.sh
