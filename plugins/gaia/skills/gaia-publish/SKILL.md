---
name: gaia-publish
description: Phase 5 action command for non-deployable (distribution-only / branch-only) projects per FR-525 + ADR-113. Runs the canonical five-step orchestrator — pre-publish gate, manifest version check, trigger publish, post-publish verify, final verdict — with no auto-retry, no auto-rollback. Use when "publish this version" or /gaia-publish.
argument-hint: "--version <semver> [--dry-run] [--skip-verify] [--strict-builtin]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are running the Phase 5 publish action for a non-deployable project. The skill mirrors `/gaia-deploy` semantics — sequential, transparent, no auto-retry, no auto-rollback — but targets `distribution.channel` adapters instead of deploy adapters. Per FR-525 / ADR-113, the orchestrator is the canonical five-step sequential flow. Per FR-524, this command is the recommended Phase 5 action for projects whose detector token is `publish-primary` or `deploy-and-publish` (see E99-S5 + `gaia-help` SKILL.md).

## Critical Rules

- The five-step order is **non-negotiable** per FR-525: (1) pre-publish gate → (2) manifest version check → (3) trigger publish → (4) post-publish verify → (5) final verdict. No reordering, no step skipping (except `--dry-run` and `--skip-verify` per the documented opt-out).
- No auto-retry. No auto-rollback. Recovery is user-initiated. A FAILED step records the failure in the assessment doc and HALTs the remaining gating steps.
- The orchestrator script at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-publish/scripts/gaia-publish.sh` is the deterministic single source of truth for the flow control + step bookkeeping. The SKILL.md prose surfaces user-facing concepts; the script enforces the contract.
- `distribution.channel`, `distribution.manifest`, `distribution.registry`, `distribution.release_workflow` are consumed via the E99-S2 schema (no re-implemented config parsing). `environments[].kind` is consumed via the E99-S1 resolver.
- The skill is gated against deployable-only projects at the routing layer (per FR-524 — `/gaia-help` recommends `/gaia-publish` only when the detector token is `publish-primary` or `deploy-and-publish`). When invoked directly on a deploy-only project, the orchestrator still runs (no gate inside the script — that gate belongs to `/gaia-help`), but the assessment doc will note the mismatch.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## CLI Flags

| Flag | Required | Description |
|---|---|---|
| `--version <semver>` | yes | The version to publish. Must match the version in `distribution.manifest` (step 2 check). Leading `v` is stripped before comparison. |
| `--dry-run` | no | Exit cleanly after step 3 with steps 4-5 SKIPPED + the "dry-run mode — verify/post-publish skipped" marker. Adapter dispatch (step 3) runs in DRY-RUN mode — no actual publish. Audit-trail records the dry-run. |
| `--skip-verify` | no | Bypass step 4 (post-publish registry probe) with a WARNING per NFR-082 opt-out. Use sparingly — the registry probe catches publish failures that would otherwise surface only when downstream consumers try to fetch. |
| `--strict-builtin` | no | Refuse custom-adapter shadows for sensitive channels per SR-82. Forces the built-in adapter even when a `.gaia/custom/adapters/publish-{channel}/` directory shadows it. E100-S8 wires the actual shadow detection. |

## Five-step orchestration (FR-525 canonical order)

### Step 1 — Pre-publish gate
Verify all required `ci_cd.promotion_chain[].ci_checks` are green on the source branch. **Real implementation lands in E100-S2.** Today this step is a PASSED stub with the `not-yet-implemented` marker so downstream bats fixtures can exercise the orchestration shape.

### Step 2 — Manifest version check
Read the path named by `distribution.manifest` (e.g., `plugin.json`, `package.json`, `pyproject.toml`, `Cargo.toml`, `pom.xml`), parse the version field, and confirm it matches the `--version` argument. Leading `v` is stripped on both sides before comparison. Mismatch is FAILED.

### Step 3 — Trigger publish
Resolve and dispatch the adapter per `distribution.channel`. **Real adapter dispatch lands in E100-S4..S8**; today this step is a PASSED stub so the orchestration is testable end-to-end with mocked channels.

Under `--dry-run`, the adapter is dispatched in DRY-RUN mode — the adapter returns the would-have-published payload without actually invoking the registry. The orchestrator then SKIPs steps 4-5.

### Step 4 — Post-publish verify (MANDATORY by default)
Invoke the adapter's `verify` action against the registry. Confirms the published artifact appears at the expected version. **Real verify + retry-window logic lands in E100-S3.** Today this step is a PASSED stub.

Bypassed under `--skip-verify` (NFR-082 opt-out) with a WARNING in the assessment doc. Bypassed under `--dry-run` (SKIPPED with the dry-run marker).

### Step 5 — Final verdict
Emit the assessment doc to `.gaia/artifacts/implementation-artifacts/assessment-publish-{channel}-{timestamp}.md` (fallback to legacy `docs/implementation-artifacts/` on pre-ADR-111 projects). The doc records per-step status + detail + the configuration snapshot. The orchestrator's exit code reflects the verdict (0 = PASSED or DRY_RUN; 1 = FAILED).

## Steps

### Step 1 — Resolve project config + arguments

- Resolve `${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo` to determine whether interactive prompts auto-confirm.
- Resolve `project-config.yaml` via the canonical `${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml` path (or `PROJECT_CONFIG` env override).
- Parse the user's `--version` + flag args. If `--version` is missing, HALT with the canonical usage message.

### Step 2 — Validate the config-shape gate (advisory)

- Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-shape-detect.sh` and call `gaia_config_shape_detect <config>`.
- When the detector returns `deploy-only` (no `distribution:` block), surface a warning: "this project has no `distribution:` block — `/gaia-publish` requires one. Run `/gaia-config-distribution add` first."
- Otherwise (publish-primary / deploy-and-publish / unknown), proceed.

### Step 3 — Dispatch the five-step orchestrator script

Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-publish/scripts/gaia-publish.sh --version <version> [flags...]`. Forward all user-supplied flags verbatim. Capture stdout (per-step progress markers + assessment-doc path) and the exit code.

### Step 4 — Surface the verdict

- Re-emit each per-step marker line from the script's stdout to the user.
- On exit 0 (PASSED or DRY_RUN): report success + the assessment-doc path.
- On exit 1 (FAILED): report which step(s) failed (from the assessment doc), point the user at the per-channel adapter's troubleshooting section, and remind them recovery is user-initiated (no auto-retry, no auto-rollback).

### Step 5 — Reconciliation hint

After a successful publish, suggest the user run `/gaia-sprint-status` to refresh the sprint dashboard with the new release marker (if the publish corresponds to a sprint deliverable).

## References

- FR-525 — `/gaia-publish` five-step canonical orchestrator.
- ADR-113 — Publish adapter contract (used by E100-S4 + downstream adapter stories).
- ADR-112 §(c) — Closed 10-channel registry consumed via `distribution.channel`.
- FR-524 — `/gaia-help` Phase 5 routing that recommends `/gaia-publish` based on the config-shape detector token.
- NFR-082 — `--skip-verify` opt-out path documentation.
- SR-82 — `--strict-builtin` defense against malicious custom-adapter shadows for sensitive channels.
- ADR-044 — Atomic file writes (assessment doc).
- ADR-067 — YOLO mode contract.
