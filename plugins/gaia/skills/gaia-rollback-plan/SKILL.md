---
name: gaia-rollback-plan
description: Create rollback trigger criteria and step-by-step rollback procedures for a release. Use when "create rollback plan" or /gaia-rollback-plan.
version: 1.0.0
agent: any
triggers:
  - create rollback plan
  - rollback plan
  - rollback procedure
  - rollback criteria
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-rollback-plan/scripts/setup.sh

## Mission

You are generating a rollback plan for a release. Your output covers rollback trigger criteria (automated and manual), a step-by-step rollback procedure, a data rollback strategy, a communication plan, and post-rollback verification steps. The plan must be executable during an incident without additional approvals.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/5-deployment/rollback-plan` workflow (Cluster 12, story E28-S94, ADR-041). It follows the canonical skill pattern established by E28-S66 (code-review) and E28-S92 (deploy-checklist).

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes the rollback plan artifact to `.gaia/artifacts/implementation-artifacts/`.

**Foundation script integration (ADR-042):** Config validation and checkpoint management are deterministic operations -- they belong in bash scripts invoked inline via `!scripts/*.sh` calls, not in LLM prose.

## Critical Rules

- The rollback plan MUST be executable without additional approvals during an incident.
- The data rollback strategy MUST be explicitly defined -- never omit it.
- A communication plan MUST be included covering engineering, stakeholders, and users.
- The `resolve-config.sh` foundation script MUST be present and executable. If missing or not executable, HALT with: "resolve-config.sh not found at {path}. Ensure foundation scripts are deployed." (AC-EC3).
- **Missing deployment state (AC-EC2):** If no prior deployment state exists (no deployment history, no checkpoint files, no previous version artifact), produce a partial rollback plan with a prominent warning: "No rollback target found -- no prior deployment state exists. This plan covers procedures but cannot specify a concrete rollback version." Do NOT halt -- produce what is possible and note the gap.
- **Malformed config (AC-EC6):** If the project config resolved via `!scripts/resolve-config.sh` is empty, malformed, or unparseable (non-zero exit from the resolver, or the required `ci_cd.promotion_chain` keys are missing), HALT with a descriptive error: "Cannot generate rollback plan: project config is malformed or empty (resolver exited {N}). Fix the config before retrying." Do NOT produce a broken rollback plan from bad config. <!-- The resolver merges the split shared/local config files per ADR-044. -->
<!-- INDIRECTION NOTE: This skill used to read `global.yaml` directly; after ADR-044 it consumes the resolver's merged output so it is transparent to the shared vs machine-local split. -->

- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Validate Project Config

- Read `${PLANNING_ARTIFACTS}/architecture.md` for deployment-relevant architecture decisions (infrastructure topology, deployment strategy, rollback mechanisms).
- Resolve project config via `!scripts/resolve-config.sh --format shell` (ADR-044 §10.26.3). Eval the output or parse the `KEY='VALUE'` pairs to determine deployment environment and CI/CD pipeline configuration. The resolver transparently merges the team-shared and machine-local layers; the skill never reads either file directly. <!-- Shared layer: .gaia/config/project-config.yaml. Local layer: global.yaml. See ADR-044 §10.26.6. -->
- If config is empty or malformed, HALT with descriptive error (AC-EC6).

### Step 2 -- Define Trigger Criteria

Define when to rollback -- both automated and manual triggers:

**Automated rollback triggers:**
- Error rate exceeds configured threshold (boundary: `> threshold` triggers rollback).
- Health check endpoint failures exceed tolerance (e.g., 3 consecutive failures).
- Critical alert fires from monitoring system.
- Canary analysis detects statistically significant regression.

**Manual rollback triggers:**
- User-reported issues at scale (support ticket spike).
- Data integrity concerns discovered post-deploy.
- Security vulnerability discovered in the deployed version.
- Business-critical functionality degraded.

**Rollback authority:** Define who has authority to initiate rollback. During an incident, the on-call engineer has unilateral authority -- no additional approval chain required.

### Step 3 -- Define Rollback Procedure

Create a step-by-step rollback execution plan:

1. **Announce rollback** -- notify the incident channel and on-call rotation.
2. **Identify rollback target** -- determine the previous stable version to rollback to. If no prior deployment state exists (AC-EC2), note the gap and skip to infrastructure-level rollback.
3. **Execute rollback mechanism** -- select the appropriate method based on deployment strategy:
   - **Redeploy previous version:** trigger CI/CD pipeline with previous version tag.
   - **Traffic shift:** route 100% of traffic back to the old version (blue-green).
   - **Feature flag:** disable the feature flag wrapping the new code path.
4. **Verify rollback success** -- run health checks against the rolled-back version.
5. **Monitor post-rollback** -- observe metrics for 30 minutes minimum post-rollback.

**Expected rollback duration:** Document the expected time for each rollback method (e.g., blue-green: < 1 minute, redeploy: 5-10 minutes, database rollback: 15-30 minutes).

### Step 4 -- Define Data Rollback Strategy

Address data changes made by the new version:

- **Database migration reversal:** Document the DOWN migration script and verify it has been tested.
- **Data fix procedures:** Specify how to handle data written by the new version that needs correction.
- **Non-reversible data:** Identify any data changes that cannot be rolled back and define a mitigation plan (e.g., data exports, manual corrections, user communication).
- **Cache invalidation:** Document which caches need to be flushed after rollback.

### Step 5 -- Define Communication Plan

Define the communication timeline for a rollback event:

- **Immediate (0-5 min):** Notify engineering team via incident channel, page on-call if not already engaged.
- **Short-term (5-15 min):** Notify stakeholders and product team, update status page if applicable.
- **Post-rollback (15-60 min):** Send incident summary to broader team, update support team with known impact, prepare user communication if user-facing impact occurred.
- **Post-mortem (24-48 hours):** Schedule post-mortem, document root cause, define re-release criteria.

Prepare communication templates for:
- Internal incident notification.
- Status page update (if applicable).
- User-facing communication (if user impact).

### Step 6 -- Generate Rollback Plan Artifact

Write the rollback plan to `.gaia/artifacts/implementation-artifacts/rollback-plan-{version}.md` containing:

1. **Rollback Trigger Criteria** -- automated and manual triggers with thresholds.
2. **Step-by-Step Rollback Procedure** -- numbered execution steps with expected duration.
3. **Data Rollback Strategy** -- migration reversal, data fix procedures, non-reversible data handling.
4. **Communication Plan** -- timeline, notification targets, templates.
5. **Post-Rollback Verification** -- health check confirmation, metric stabilization, monitoring window.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-rollback-plan/scripts/finalize.sh
