---
name: gaia-post-deploy
description: "DEPRECATED — This skill has been renamed to /gaia-deploy-post (category-first naming). Preserved as a thin one-sprint deprecation redirect."
argument-hint: ""
allowed-tools: [Read, Bash, Skill]
deprecated_aliases: [gaia-post-deploy]
deprecated_since: sprint-63
replaced_by: [gaia-deploy-post]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Deprecation Notice

> **This skill has been renamed.** `/gaia-post-deploy` is now `/gaia-deploy-post` to follow category-first naming (`gaia-deploy-*`) consistent with the rest of the deploy/release skill family (`gaia-deploy`, `gaia-deploy-checklist`, `gaia-release`, `gaia-release-plan`).
>
> The full capability — health checks, smoke tests, metric validation, canary analysis, and post-deployment report generation — is unchanged and lives at `/gaia-deploy-post`. This stub exists for one sprint to redirect callers; it will be removed after sprint-64.

## Mission

This skill is a thin deprecation redirect. It exists only to surface the rename notice and point callers at the canonical replacement:

- To run post-deployment verification -> run **`/gaia-deploy-post`**.

## Steps

> **Note:** This redirect performs no writes. The full post-deploy verification skill lives at `plugins/gaia/skills/gaia-deploy-post/`.

### Step 1 -- Display Deprecation Banner

Display:

```
/gaia-post-deploy has been renamed to /gaia-deploy-post (category-first naming).
Run /gaia-deploy-post for post-deployment health and metric validation.
```

### Step 2 -- Offer the Replacement

If the user confirms they want post-deploy verification, dispatch `/gaia-deploy-post` via the Skill tool. Otherwise stop.
