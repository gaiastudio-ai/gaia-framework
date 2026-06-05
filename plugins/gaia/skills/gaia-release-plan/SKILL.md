---
name: gaia-release-plan
description: Create staged rollout and release strategy with environment progression, rollback criteria, and success metrics. Use when "create release plan" or /gaia-release-plan.
version: 1.0.0
agent: any
triggers:
  - create release plan
  - release plan
  - release strategy
  - staged rollout
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-release-plan/scripts/setup.sh

## Mission

You are generating a staged rollout and release strategy for the project. Your output is a comprehensive release plan that covers scope, deployment strategy, staged rollout percentages with observation windows, rollback criteria, success metrics, and a communication plan.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/5-deployment/release-plan` workflow. It follows the canonical skill pattern established by the code-review skill.

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes the release plan artifact to `.gaia/artifacts/implementation-artifacts/`.

**Foundation script integration:** This skill invokes `setup.sh` and `finalize.sh` from `plugins/gaia/skills/gaia-release-plan/scripts/` for config resolution and checkpoint management. Deterministic operations belong in bash scripts, not LLM prompts.

## Critical Rules

- Every release MUST have a defined deployment strategy.
- Staged rollout percentages MUST be explicit with observation windows between stages.
- Rollback criteria and abort criteria MUST be defined for each rollout stage.
- Success metrics MUST be measurable and defined per environment.
- A communication plan MUST be included covering stakeholders, changelog, and release notes.
- The output MUST follow semantic versioning for the version number assignment.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Define Release Scope

- Read `${PLANNING_ARTIFACTS}/architecture.md` for deployment-relevant architecture decisions, infrastructure topology, and ADRs.
- Read the current sprint status and completed stories to determine what is included in this release.
- Define what is included: stories, features, bug fixes, and breaking changes.
- Assign a version number following semantic versioning (semver) conventions:
  - MAJOR for breaking changes
  - MINOR for new features (backward compatible)
  - PATCH for bug fixes
- Identify release dependencies and ordering constraints between components.

### Step 2 -- Select Deployment Strategy

- Select the deployment strategy based on the project's risk profile and infrastructure:
  - **Blue-green:** Zero-downtime with instant rollback capability. Best for stateless services with load balancer support.
  - **Canary:** Gradual traffic shift to new version. Best for high-traffic services where early detection matters.
  - **Rolling:** Sequential instance replacement. Best for stateful services or resource-constrained environments.
  - **Big-bang:** All-at-once replacement. Best for low-risk changes or environments without advanced routing.
- Justify the strategy choice based on risk profile and available infrastructure.
- Define success criteria for each deployment phase.

### Step 3 -- Plan Staged Rollout

Define the environment progression with explicit percentage targets and observation windows:

**Stage 1 -- Canary (1%):**
- Deploy to 1% of traffic or a single canary instance.
- Observation window: 15-30 minutes minimum.
- Metrics to monitor: error rate, latency p50/p95/p99, CPU/memory usage.
- Abort criteria: error rate > 1% above baseline, latency p99 > 2x baseline.
- Rollback trigger: any critical alert fires during observation window.

**Stage 2 -- Early Adopters (10%):**
- Expand to 10% of traffic.
- Observation window: 1-2 hours.
- Metrics to monitor: error rate, latency, throughput, business metrics (conversion, engagement).
- Abort criteria: error rate > 0.5% above baseline, degraded business metrics.
- Rollback trigger: sustained metric degradation beyond thresholds.

**Stage 3 -- Broad Rollout (50%):**
- Expand to 50% of traffic.
- Observation window: 2-4 hours.
- Metrics to monitor: all previous plus resource utilization trends, queue depths.
- Abort criteria: any metric regression compared to the control group.
- Rollback trigger: cumulative error budget consumed or user-facing incidents reported.

**Stage 4 -- Full Rollout (100%):**
- Expand to 100% of traffic.
- Observation window: 24 hours post-rollout.
- Metrics to monitor: full production monitoring dashboard.
- Success criteria: all metrics within acceptable range for 24 hours.
- Halt and rollback if critical issues emerge within the observation window.

### Step 4 -- Define Rollback Criteria

Establish clear rollback trigger conditions for the entire release:

- **Automatic rollback triggers:** error rate exceeds threshold, health check failures, critical alert fires.
- **Manual rollback triggers:** user-reported issues at scale, data integrity concerns, security vulnerability discovered.
- **Rollback procedure:** document the exact steps to revert (infrastructure commands, database rollback scripts, cache invalidation).
- **Rollback success metrics:** confirm rolled-back version is healthy, verify no data loss, validate all dependent services recovered.
- **Post-rollback action items:** root cause analysis, fix timeline, re-release criteria.

### Step 5 -- Define Success Metrics

Define measurable success metrics per environment:

- **Technical metrics:** error rate, latency (p50, p95, p99), throughput, CPU/memory utilization, disk I/O.
- **Business metrics:** conversion rate, user engagement, transaction success rate, revenue impact.
- **Operational metrics:** deployment duration, time-to-rollback capability, incident count during rollout.
- **Comparison baseline:** metrics from the previous release or current production version.

### Step 6 -- Communication Plan

- Define stakeholder notification timeline (pre-deploy, during deploy, post-deploy).
- Prepare changelog and release notes summarizing all changes.
- Plan user-facing communications if applicable (feature announcements, migration guides).
- Notify on-call and support teams of the deployment window.
- Identify post-deployment verification assignees.

### Step 7 -- Generate Release Plan Artifact

Write the release plan to `.gaia/artifacts/implementation-artifacts/release-plan-{version}.md` containing:

1. **Release Scope** -- version number, included stories/features/fixes, breaking changes, dependencies.
2. **Deployment Strategy** -- selected strategy with justification.
3. **Staged Rollout Schedule** -- environment progression (1% -> 10% -> 50% -> 100%) with observation windows, metrics, and abort criteria per stage.
4. **Rollback Criteria** -- automatic and manual triggers, rollback procedure, success metrics for rollback.
5. **Success Metrics** -- technical, business, and operational metrics with baselines.
6. **Communication Plan** -- stakeholder timeline, changelog, user communications.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-release-plan/scripts/finalize.sh
