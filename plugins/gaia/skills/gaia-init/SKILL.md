---
name: gaia-init
description: Greenfield conversational setup — bootstraps `config/project-config.yaml` via a discovery questionnaire (project name, project shape, stack/path mapping, platforms, compliance regimes, environments, CI platform) and generates a starter CI workflow. Use when "init a new project" or /gaia-init. Refuses to run on directories that already have a config — directs the user to /gaia-config-* or /gaia-brownfield in that case.
argument-hint: "[project-path]"
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
model: inherit
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/setup.sh

## Mission

You are running the GAIA greenfield conversational setup. The user is on a brand-new project and wants `config/project-config.yaml` produced from a guided questionnaire — no manual YAML authoring, no copy-pasting from another project. You also generate a starter CI workflow file (and a never-clobbered `*.user-steps.yml` companion) for the user's selected CI platform.

This skill is a Claude Code native skill — the questionnaire runs as natural conversation; the deterministic checks (greenfield guard, schema validation, atomic file write, CI scaffold emission) are delegated to helper scripts under `${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/` per ADR-042 (Scripts-over-LLM).

**Greenfield-only boundary:** This skill MUST NOT modify existing configs. If the user already has `config/project-config.yaml`, refuse and direct them to `/gaia-config-*` (E71-S3, mutation path) or `/gaia-brownfield` (E71-S2, codebase onboarding path).

## Critical Rules

- Run `greenfield-guard.sh` BEFORE any questionnaire output. If it exits non-zero, surface its stderr message verbatim and STOP — do not proceed to discovery.
- Treat credential answers as **env-var NAMES only**. Never accept, log, or write a literal credential value. The schema (`project-config.schema.json`) rejects literal-secret patterns at validation time per FR-RSV2-9 / AC11.
- Validate platform/stack consistency via `validate-platform-stack.sh` BEFORE writing the config file. A `platforms: [ios]` declaration with no iOS-capable stack must be rejected with a clear correction prompt — NEVER silently accepted.
- `generate-config.sh` performs an atomic write (temp + rename) and refuses to overwrite an existing config. Do not attempt to fall back to overwrite — that would breach AC4.
- `generate-ci-scaffold.sh` writes a per-provider workflow file plus a `*.user-steps.yml` companion. The companion is preserved byte-for-byte on regeneration (FR-RSV2-38).
- This skill MUST NOT touch `_memory/`, `_gaia/`, or any sprint-status / story files. It is a config-bootstrap skill, not a sprint or memory workflow.

## Inputs

`$ARGUMENTS` — optional `[project-path]`. Defaults to the current working directory.

## Steps

### Step 1 — Greenfield guard

Run:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/greenfield-guard.sh --path "$PROJECT_PATH"
```

Exit code 1 → surface the message and HALT. Exit code 0 → proceed.

### Step 2 — Discovery questionnaire

Ask the user the following question set, in order. Capture answers into a JSON answer-bundle (no scratchpad files — keep the bundle in conversation memory until Step 4).

1. **Project name.** Required. Used in the generated header and `--name` flag.
2. **Project shape.** Single-select:
   - `single backend`
   - `microservices`
   - `mobile only`
   - `mobile+backend`
   - `microservices+mobile`
3. **Stacks (iterative).** For each service in the project, capture: `name`, `language` (e.g., `node`, `python`, `java`, `swift`, `kotlin`, `react-native`, `flutter`, `objective-c`), `paths` (one or more globs / directory paths). Loop until the user is done — minimum one stack.
4. **Compliance regimes.** Multi-select from: `gdpr`, `hipaa`, `pci-dss`, `sox`, `ccpa`, `soc2`, `iso-27001`, `wcag-2.1-aa`, `wcag-2.1-aaa`. Optional.
5. **`ui_present`.** Boolean. Drives downstream a11y rubric layer selection.
6. **Environments (iterative).** For each environment (none is OK): `name` (e.g., `staging`, `production`), `url`, `auth_type`, and the **NAME** of the env var holding the credential (e.g., `STAGING_TOKEN`). Never accept or echo a literal secret.
7. **CI/CD platform.** Single-select from: `github-actions`, `gitlab-ci`, `circleci`, `jenkins`, `azure-pipelines`, `bitbucket-pipelines`, `none`.

**Step 2a — Mobile-specific follow-ups (conditional).** Trigger only when project shape is one of `mobile only`, `mobile+backend`, `microservices+mobile`:

- iOS: ship to iOS y/n. If yes, ask minimum iOS version (e.g., `17.0`) and bundle ID (e.g., `com.example.app`). Add `ios` to `platforms[]`.
- Android: ship to Android y/n. If yes, ask minimum SDK, target SDK, package name. Add `android` to `platforms[]`.

The mobile answers populate `device_targets` in the answer-bundle.

### Step 3 — Validate the answer-bundle

Render the assembled JSON bundle to the user for review. Then run the platform-stack consistency check:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/validate-platform-stack.sh <bundle-as-yaml>
```

If it returns non-zero, surface the error message and re-prompt the user to either remove the offending platform OR add a capable stack — do NOT proceed to file write until the bundle validates.

### Step 4 — Generate `config/project-config.yaml`

Pipe the JSON bundle to `generate-config.sh`:

```
echo "$BUNDLE_JSON" | ${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/generate-config.sh \
  --path "$PROJECT_PATH" --name "$PROJECT_NAME"
```

Then validate the freshly-written file against the schema:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/validate-against-schema.sh \
  "$PROJECT_PATH/config/project-config.yaml"
```

If validation fails, surface the validator output, delete the just-written file (revert to greenfield state), and re-prompt the user for the offending field.

### Step 5 — Generate CI scaffold

If the selected CI platform is anything other than `none`:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/generate-ci-scaffold.sh \
  --path "$PROJECT_PATH" --provider "$CI_PROVIDER"
```

This writes the per-provider workflow file plus the `*.user-steps.yml` companion (preserved on regeneration). For provider `none`, skip this step.

### Step 6 — Render Next Steps

Render the following to the user, replacing the placeholder with the concrete file list:

```
✓ Generated:
  - config/project-config.yaml
  - <CI workflow path>
  - <CI user-steps companion path>

Reminders:
  - Set the credential env vars referenced in `environments.*.credentials.*`
    in your CI provider's secret store (e.g., GitHub Actions Secrets).
  - Re-running /gaia-init on this directory will refuse — use /gaia-config-show
    or /gaia-config-validate (E71-S3) to inspect or edit, or /gaia-brownfield
    to onboard an existing codebase.

Next steps:
  - Run /gaia-product-brief to define product vision.
  - Or run /gaia-brownfield if the codebase already exists and you want
    GAIA to scan it.
```

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/finalize.sh
