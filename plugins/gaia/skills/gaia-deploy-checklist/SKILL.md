---
name: gaia-deploy-checklist
description: Pre-deployment verification checklist with quality gates enforced via validate-gate.sh. Use when "deployment checklist" or /gaia-deploy-checklist.
version: 1.0.0
agent: any
triggers:
  - deployment checklist
  - deploy checklist
  - pre-deployment check
allowed-tools: [Read, Grep, Glob, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-deploy-checklist/scripts/setup.sh

## Mission

You are generating a pre-deployment verification checklist for the project. Before generating any checklist content, you enforce three quality gates via `validate-gate.sh`: traceability matrix exists, CI pipeline is configured, and readiness report passes. Only after all gates pass do you produce the deployment checklist.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/5-deployment/deployment-checklist` workflow. It follows the canonical skill pattern established by the code-review skill.

**Write context:** This skill uses `allowed-tools: Read Grep Glob Bash Write Edit` because it writes the deployment checklist artifact to `.gaia/artifacts/planning-artifacts/`.

**Foundation script integration:** This skill invokes `validate-gate.sh` from `plugins/gaia/scripts/` for deterministic gate verification. Gate checks (traceability, CI, readiness) belong in bash scripts, not LLM prompts.

## Critical Rules

- The `validate-gate.sh` foundation script MUST be present and executable at `plugins/gaia/scripts/validate-gate.sh`. If missing or not executable, HALT with: "validate-gate.sh not found at {path}. Ensure validate-gate.sh is deployed."
- The `resolve-config.sh` foundation script MUST be present and executable. If missing, HALT with dependency error.
- All three quality gates MUST pass before generating the checklist. If any gate fails, HALT with an actionable error message identifying which specific gate failed and why.
- The traceability gate checks that `${TEST_ARTIFACTS}/traceability-matrix.md` exists and is non-empty. An empty (0-byte) file is treated as missing.
- The CI gate checks that `${TEST_ARTIFACTS}/ci-setup.md` exists OR `ci_cd.promotion_chain` resolves to a non-empty array via `!scripts/resolve-config.sh ci_cd.promotion_chain`.
- The readiness gate checks that `${PLANNING_ARTIFACTS}/readiness-report.md` exists.
- If `validate-gate.sh` returns a non-zero exit code but produces no structured error output, treat as: "Gate check failed with unknown error -- exit code {N}" and HALT.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- **`environments[].kind` shape-agnostic.** This skill is GATE-FREE on `kind` — it produces a checklist for ALL three resolved kinds (`deployable | branch-only | distribution-only`). Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-env-kind.sh` and call `gaia_resolve_env_kind <project-config.yaml> <env-id>` to read the resolved kind, then render the checklist with shape-aware verbage: the `deployable` checklist references deploy steps; the `branch-only` and `distribution-only` checklists reference publish steps per the publish-readiness mode. Single template-variable swap (`{{action_verb}}` → `"deploy"` or `"publish"`). NEVER HALT on `kind` — that gate belongs to `/gaia-deploy` + `/gaia-post-deploy` only.
- **Publish-readiness mode.** When NO env is `deployable` AND a `distribution:` block is present, the skill enters **publish-readiness mode**: the checklist sections, gate items, and artifact filename are publish-oriented instead of deploy-oriented. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-shape-detect.sh` and call `gaia_config_shape_detect <project-config.yaml>`; when the detector returns `publish-primary`, render the publish-shape checklist (gates: "credentials env vars set", "manifest version matches plugin.json", "release_workflow exists", "adapter sub-fields satisfy per-channel schema", etc.) rather than the deploy-shape checklist (gates: "rollback plan documented", "smoke endpoints defined", etc.). Detection is from the env+distribution config — NOT from a flag. When the detector returns `deploy-and-publish` (mixed shape), render both gate sets concatenated under separate headers.

## Steps

### Step 1 -- Verify Gate Script Availability

- Check that `validate-gate.sh` exists and is executable at `${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh`.
- If not found: HALT with "validate-gate.sh not found at {path}. Ensure validate-gate.sh is deployed."
- If not executable: HALT with "validate-gate.sh exists but is not executable at {path}."

### Step 2 -- Enforce Quality Gates

Run the three deployment gates via `validate-gate.sh --multi`:

```bash
validate-gate.sh --multi traceability_exists,ci_setup_exists,readiness_report_exists
```

**Gate 1 -- Traceability Matrix:**
- Verifies `${TEST_ARTIFACTS}/traceability-matrix.md` exists and is non-empty.
- On failure: "Traceability gate failed -- traceability-matrix.md not found or empty at ${TEST_ARTIFACTS}/. Run /gaia-trace to generate."

**Gate 2 -- CI Pipeline Configuration:**
- Verifies `${TEST_ARTIFACTS}/ci-setup.md` exists.
- On failure: "CI gate failed -- ci-setup.md not found at ${TEST_ARTIFACTS}/. Run /gaia-ci-setup to configure."

**Gate 3 -- Readiness Report:**
- Verifies `${PLANNING_ARTIFACTS}/readiness-report.md` exists.
- On failure: "Readiness gate failed -- readiness-report.md not found at ${PLANNING_ARTIFACTS}/. Run /gaia-readiness-check to generate."

If any gate fails:
- Parse the validate-gate.sh stderr for the specific gate failure message.
- If stderr is empty but exit code is non-zero: report "Gate check failed with unknown error -- exit code {N}".
- HALT with the actionable error message listing which specific gate failed and the remediation command.

If all gates pass: proceed to Step 3.

### Step 3 -- Load Project Context

- Read `${PLANNING_ARTIFACTS}/architecture.md` for deployment-relevant architecture decisions (infrastructure topology, deployment strategy, ADRs).
- Read `${PLANNING_ARTIFACTS}/readiness-report.md` for current readiness status.
- Read `${TEST_ARTIFACTS}/ci-setup.md` for CI/CD pipeline configuration.
- Read `${TEST_ARTIFACTS}/traceability-matrix.md` for requirements coverage status.

### Step 4 -- Generate Deployment Checklist

Generate a comprehensive deployment checklist covering all pre-deployment verification items:

**Infrastructure Readiness:**
- Server/container provisioning verified
- Load balancer configuration confirmed
- Auto-scaling policies in place
- Network security groups / firewall rules reviewed

**Database Migration Status:**
- Migration scripts tested in staging
- Rollback migration scripts verified
- Data backup completed before migration
- Schema compatibility confirmed

**Rollback Plan Reference:**
- Rollback procedure documented and tested
- Rollback trigger criteria defined
- Previous version artifact available for quick restore
- Rollback communication plan prepared

**Environment Configuration:**
- Environment variables set for target environment
- Configuration differences between staging and production documented
- Feature flags configured for gradual rollout (if applicable)
- External service endpoints verified for target environment

**Monitoring and Alerting Setup:**
- Application monitoring dashboards configured
- Alert thresholds set for key metrics (error rate, latency, throughput)
- Log aggregation configured for new deployment
- On-call rotation notified of deployment window

**Health Check Endpoints:**
- Health check endpoint responds with expected status
- Readiness probe configured for orchestrator (k8s/ECS)
- Liveness probe configured
- Dependency health checks included (database, cache, external APIs)

**DNS and CDN Readiness:**
- DNS records updated or prepared for cutover
- CDN cache invalidation plan documented
- SSL/TLS certificates valid and not expiring soon
- CORS and security headers configured

**Secrets Rotation:**
- API keys and tokens rotated for production
- Database credentials rotated
- Third-party service credentials verified
- Secrets stored in vault/secrets manager (not in code or environment files)

**Communication Plan:**
- Stakeholders notified of deployment window
- Status page updated (if applicable)
- Support team briefed on changes
- Post-deployment verification assignees identified

### Step 5 -- Write Checklist Artifact

- Write the deployment checklist to `.gaia/artifacts/planning-artifacts/deployment-checklist.md`.
- Include gate verification results at the top of the document.
- Include all checklist sections from Step 4 with project-specific details.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-deploy-checklist/scripts/finalize.sh
