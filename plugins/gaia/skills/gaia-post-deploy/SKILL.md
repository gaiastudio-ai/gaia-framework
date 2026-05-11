---
name: gaia-post-deploy
description: Post-deployment health and metric validation with structured pass/fail report. Use when "post-deploy verify" or /gaia-post-deploy.
version: 1.0.0
agent: any
triggers:
  - post-deploy verify
  - post-deploy
  - deployment verification
  - health check
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-post-deploy/scripts/setup.sh

## Mission

You are validating a deployment by checking service health, running smoke tests, and verifying that production metrics remain within SLO bounds. Your output is a structured pass/fail report covering every verification dimension.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/5-deployment/post-deploy-verify` workflow (Cluster 12, story E28-S94, ADR-041). It follows the canonical skill pattern established by E28-S66 (code-review) and E28-S92 (deploy-checklist).

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes the post-deployment report artifact to `docs/implementation-artifacts/`.

**Foundation script integration (ADR-042):** Health endpoint checks, error rate calculations, and metric validation are deterministic operations -- they belong in bash scripts invoked inline via `!scripts/*.sh` calls, not in LLM prose. The skill delegates all measurable checks to scripts and reserves prose for analysis, canary comparison, and report generation.

## Critical Rules

- Health checks MUST pass before declaring a deployment successful.
- Metrics MUST be within SLO bounds -- error rate, latency, and throughput all verified.
- If any critical check fails, the report MUST recommend rollback and link to `/gaia-rollback-plan`.
- The `resolve-config.sh` foundation script MUST be present and executable. If missing or not executable, HALT with: "resolve-config.sh not found at {path}. Ensure foundation scripts are deployed." (AC-EC3).
- Unreachable endpoints MUST be reported with specific error details (timeout, DNS failure, connection refused) and remediation guidance -- never silently ignored (AC-EC1).
- Error rate threshold boundary behavior: `<= threshold` passes, `> threshold` fails. This boundary rule is deterministic and documented here for consistency (AC-EC5).
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Health Checks

Verify application health endpoints respond correctly:

- Check all configured health endpoints respond within the configured timeout.
- For each endpoint, verify HTTP status code is 2xx.
- Confirm service connectivity: databases, caches, queues, external APIs.
- Check all containers/instances are running and report healthy status.

**Unreachable endpoint handling (AC-EC1):** If any endpoint is unreachable (timeout, DNS failure, connection refused), do NOT skip it. Record the specific error type, the endpoint URL, and the failure reason. Mark the endpoint as FAILED in the report with remediation guidance:
- Timeout: "Endpoint {url} timed out after {N}s. Check service is running and network routing."
- DNS failure: "Endpoint {url} DNS resolution failed. Verify DNS records and service discovery."
- Connection refused: "Endpoint {url} connection refused. Verify service is listening on expected port."

### Step 2 -- Smoke Tests

Execute critical path validation against the deployed version:

- Login flow or primary authentication path.
- Core feature happy path (the single most important user journey).
- Key API endpoints return expected response shapes and status codes.
- Static assets and CDN serving correctly (if applicable).

### Step 3 -- Metric Validation

Check production metrics against SLO bounds:

- **Error rate:** Must be at or below the configured threshold. Boundary rule: error rate `<= threshold` passes, error rate `> threshold` fails (AC-EC5). This is deterministic -- use `!scripts/*.sh` for the comparison.
- **Latency:** P50, P95, P99 must be within acceptable range compared to baseline.
- **Throughput:** Request rate should match expected levels for the deployment window.
- **Resource utilization:** CPU, memory, and disk usage within normal operating bounds.

### Step 4 -- Canary Analysis

If the deployment uses a canary strategy:

- Compare canary instance metrics against baseline (non-canary) instances.
- Evaluate statistical significance of any metric differences.
- Recommend one of: **proceed** (metrics equivalent or better), **hold** (inconclusive, extend observation), or **rollback** (statistically significant regression).

If the deployment is not a canary deployment, note "Canary analysis: N/A -- full deployment" in the report.

### Step 5 -- Generate Post-Deployment Report

Write the post-deployment report to `docs/implementation-artifacts/post-deploy-{date}.md` containing:

1. **Deployment Summary** -- version deployed, environment, timestamp, deployment method.
2. **Health Check Results** -- table of endpoints with status (PASS/FAIL), response time, and error details for failures.
3. **Smoke Test Results** -- each test with pass/fail status and any failure details.
4. **Metric Comparison** -- current vs baseline for error rate, latency (P50/P95/P99), throughput, resource utilization.
5. **Canary Analysis** -- comparison results and recommendation (if applicable).
6. **Overall Deployment Status** -- **PASS** (all checks green) or **FAIL** (any critical check failed, with rollback recommendation).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-post-deploy/scripts/finalize.sh
