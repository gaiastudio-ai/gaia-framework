---
name: gaia-validate-prd
description: "DEPRECATED — Thin redirect to gaia-val-validate. Preserved for backward compatibility per ADR-045 / FR-330. Use /gaia-val-validate directly for PRD validation."
context: fork
allowed-tools: [Read, Glob, Bash, Agent]
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-validate-prd/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh validator all

## Deprecation Notice (ADR-045 / FR-330)

> **This skill is deprecated.** `validate-prd` is the legacy entry point for PRD validation. All validation logic now lives in the `gaia-val-validate` skill. Callers should prefer `/gaia-val-validate` directly going forward.
>
> This thin redirect is preserved per ADR-045 (deprecated-but-routed commands remain callable for backward compatibility) and FR-330 (deprecated-but-routed entry-point semantics). No validation logic is implemented here — the skill exists solely to forward invocations to the canonical validator.

## Mission

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/2-planning/validate-prd` workflow. The legacy workflow validated PRDs against structural, completeness, quality, and consistency standards. That logic has been consolidated into `gaia-val-validate`, which handles all artifact validation through the validator subagent (Val).

This skill acts as a backward-compatible redirect: it accepts the same invocation as the legacy workflow and forwards the PRD artifact path unchanged to `gaia-val-validate`.

## Steps

### Step 1 — Resolve PRD Artifact Path

- Locate the PRD at `docs/planning-artifacts/prd.md`.
- If the file does not exist, fail fast: "No PRD found at docs/planning-artifacts/prd.md — run /gaia-create-prd first."
- Pass the resolved PRD path through to the redirect target.

### Step 2 — Redirect to gaia-val-validate

Invoke the `gaia-val-validate` skill, forwarding the PRD artifact path unchanged:

```
/gaia-val-validate docs/planning-artifacts/prd.md
```

All validation logic — completeness checks, structural validation, quality checks, consistency checks, and report generation — is handled by `gaia-val-validate` via the validator subagent (Val, scaffolded by E28-S21). No validation steps are duplicated here.

### Step 3 — Report Result

- When `gaia-val-validate` completes, relay its output (PASS/FAIL status, findings count, report path) back to the caller without modification.
- The validation report is written by `gaia-val-validate` to its standard output path — this skill does not write its own report.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-validate-prd/scripts/finalize.sh

## Next Steps

- If validation PASSED: `/gaia-create-ux` — Create UX design specifications.
- If validation FAILED: `/gaia-edit-prd` — Edit the PRD to address validation findings.
