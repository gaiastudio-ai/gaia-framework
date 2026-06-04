---
name: gaia-init
description: Greenfield conversational setup — bootstraps `.gaia/config/project-config.yaml` via a discovery questionnaire (project name, project shape, stack/path mapping, platforms, compliance regimes, environments, CI platform) and generates a starter CI workflow. Use when "init a new project" or /gaia-init. Refuses to run on directories that already have a config — directs the user to /gaia-config-* or /gaia-brownfield in that case.
argument-hint: "[project-path]"
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
model: inherit
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/setup.sh

## Mission

You are running the GAIA greenfield conversational setup. The user is on a brand-new project and wants `.gaia/config/project-config.yaml` produced from a guided questionnaire — no manual YAML authoring, no copy-pasting from another project. You also generate a starter CI workflow file (and a never-clobbered `*.user-steps.yml` companion) for the user's selected CI platform.

This skill is a Claude Code native skill — the questionnaire runs as natural conversation; the deterministic checks (greenfield guard, schema validation, atomic file write, CI scaffold emission) are delegated to helper scripts under `${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/` per ADR-042 (Scripts-over-LLM).

> **Note:** The questionnaire and CRUD menu below are the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the prompt flow is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

**Greenfield-only boundary:** This skill MUST NOT modify existing configs. If the user already has `.gaia/config/project-config.yaml`, refuse and direct them to `/gaia-config-*` (E71-S3, mutation path) or `/gaia-brownfield` (E71-S2, codebase onboarding path).

## Critical Rules

- Treat credential answers as **env-var NAMES only**. Never accept, log, or write a literal credential value. The schema (`project-config.schema.json`) rejects literal-secret patterns at validation time per FR-RSV2-9 / AC11.
- Validate platform/stack consistency via `validate-platform-stack.sh` BEFORE writing the config file. A `platforms: [ios]` declaration with no iOS-capable stack must be rejected with a clear correction prompt — NEVER silently accepted.
- `generate-config.sh` performs an atomic write (temp + rename) and refuses to overwrite an existing config. Do not attempt to fall back to overwrite — that would breach AC4.
- `generate-ci-scaffold.sh` writes a per-provider workflow file plus a `*.user-steps.yml` companion. The companion is preserved byte-for-byte on regeneration (FR-RSV2-38).
- This skill MUST NOT touch `_memory/`, `_gaia/`, or any sprint-status / story files. It is a config-bootstrap skill, not a sprint or memory workflow.

## Inputs

`$ARGUMENTS` — optional `[project-path]`. Defaults to the current working directory.

## Steps

### Step 1 — Re-init guard (inline config_phase lookup)

> **E85-S3 / FR-453 / FR-460 / ADR-096 / ADR-099 — replaces the retired
> `greenfield-guard.sh` (E85-S7) with a 2-line inline state-machine
> check.** This step distinguishes three states: (1) no config → run
> Phase 0 bootstrap or full discovery; (2) config already exists with
> ANY `config_phase` value (minimal / partial / full) → refuse re-init
> with the canonical error; (3) config exists but `config_phase` is
> absent (legacy) → treat as `full` per ADR-097 absence-as-full.

**Step 1a — Detect the `--full` flag.** Parse `$ARGUMENTS` for the
`--full` token. Setting the flag bypasses the binary opener (Step 1b)
and routes directly to the full 7-question discovery flow. The flag
does NOT override the re-init guard below (AC11) — `--full` on an
existing config exits non-zero with the same canonical refusal.

**Step 1b — Re-init guard.** Run:

```bash
phase=$(yq '.config_phase // "full"' .gaia/config/project-config.yaml 2>/dev/null || echo "none")
```

- When `yq` succeeds (config exists), `phase` will be `minimal`,
  `partial`, or `full` (or `"full"` if `config_phase` is absent per
  ADR-097 absence-as-full).
- When `yq` fails (no config file), `phase` will be `"none"`, meaning
  greenfield — proceed to Step 1b binary opener.

If `phase` is NOT `"none"` (config exists), surface the canonical
stderr error and STOP:

```
error: config already exists; use /gaia-config-* to edit, or /gaia-brownfield to onboard an existing codebase
```

Per AC11 `--full` on an existing config triggers this same refusal —
`--full` does not override the re-init guard. The error text deliberately
omits `--full` to avoid steering users toward an option that won't work.
(AF-2026-05-21-3 polish — replaced the historical "use --full to
reinitialize" guidance with the canonical /gaia-config-* / /gaia-brownfield
recovery paths.)

### Step 1b — Binary opener (Phase 0 vs full discovery)

> **E85-S3 / FR-454 — the binary opener.** Presented ONLY when the
> re-init guard above passed (greenfield project) AND the `--full`
> flag was NOT set. When `--full` was set in Step 1a, skip this step
> entirely and proceed directly to Step 2's full 7-question flow.

Ask the user this single question:

```
Quick setup (5 fields) or full setup (7 questions)?
[q] Quick setup (recommended for new projects)
[f] Full setup (all config sections now)
```

Routing:

- **`[q]` or empty answer** → Phase 0 minimal flow. The answer-bundle
  collects only `project_name` and `primary_platform` (with the
  existing Step 2.2 alias normalization arm applied — AC9). Default
  `project_kind = application` (AC7); `version = 0.1.0`; `framework_version`
  resolved from the plugin manifest by `generate-config.sh` (AC8); set
  `config_phase = minimal` and `schema_version = "2.0.0"`. Skip Step
  2.2-Step 2.7 (the full discovery questionnaire) and proceed to Step
  3 (validate) with `phase=minimal`.

  **Plugin-kind detection in Phase 0 (AF-2026-05-21-9).** Step 2.2's
  alias normalization arm targets the `project_shape` field; Phase 0
  captures `primary_platform` instead. The Phase 0 bundle MUST bridge
  the two: when the user's `primary_platform` answer alias-normalizes
  to one of `{claude-plugin, plugin, claude-code-plugin}` (the same
  alias set documented at Step 2.2 for option 8, case-insensitive),
  set BOTH `project_shape = "claude-code-plugin"` AND
  `project_kind = "claude-code-plugin"` in the bundle. This is the
  ONLY Phase 0 deviation from AC7's default `project_kind = application`
  — all other AC7 defaults (`version = 0.1.0`, `framework_version`
  resolution, `config_phase = minimal`) remain unchanged. The
  `project_shape` field drives `generate-config.sh`'s upgrade gate
  (post-AF-21-9 the gate fires in both `minimal` and `full` phases);
  the `project_kind` field defends against any future bundle path that
  reads the schema-required key directly without going through the
  shape-driven upgrade.
- **`[f]`** → existing 7-question flow. Proceed to Step 2 unchanged
  with `phase=full`.

**Non-interactive / YOLO default:** when no TTY is available (CI,
batch invocation, `ASSUME_YES=true`), default to `[q]` (Phase 0) —
consistent with the E85 minimal-by-default direction. The `--full`
flag remains the explicit opt-in for full discovery in batch.

When invoking `generate-config.sh` at Step 4, pass `--phase minimal`
or `--phase full` to match the resolved `phase` value.

### Step 2 — Discovery questionnaire

Ask the user the following question set, in order. Capture answers into a JSON answer-bundle (no scratchpad files — keep the bundle in conversation memory until Step 4).

1. **Project name.** Required. Used in the generated header and `--name` flag.
2. **Project shape.** Single-select. The eight canonical options below are the
   visible Step 2.2 menu — the order is canonical (do not reorder for
   taxonomic preference). Display labels for `web-app` and `fullstack`
   surface the platform mental model on the menu itself; the schema-level
   project_kind axis is intentionally NOT amended in this step (see boundary
   note below):

   - `single-backend` (option 1)
   - `microservices` (option 2)
   - `web-app` "Web app (frontend + backend)" (option 3)
   - `mobile-only` (option 4)
   - `mobile+backend` (option 5)
   - `fullstack` "Web + mobile + backend" (option 6)
   - `microservices+mobile` (option 7)
   - `claude-code-plugin (aliases: claude-plugin, plugin)` (option 8) —
     Claude Code plugin (FR-411). Seeds
     `project_kind: claude-code-plugin` in `project-config.yaml`, references the
     `claude-code-plugin` stack file (E77-S2 / FR-404), and seeds plugin-specific
     `tool_adapters:` defaults (`shellcheck`, `bats`, `markdownlint`, `yamllint`).
     Skip the iterative `stacks` and `platforms` follow-ups for this option —
     the plugin stack is single-shape. A 9th option for multi-plugin
     distribution is deliberately out of scope for E77 and is NOT offered.

   **Alias normalization (case-insensitive).** The discovery loop normalizes
   the user's typed answer BEFORE the answer-bundle is passed to
   `generate-config.sh`. Lowercase the typed answer and match against the
   alias set `{claude-plugin, plugin, claude-code-plugin}`; on any match,
   write the canonical literal `claude-code-plugin` into the answer-bundle.
   The match is case-insensitive — `claude-plugin`, `Plugin`, and
   `CLAUDE-PLUGIN` all normalize to `claude-code-plugin`. Pseudocode:

   ```
   typed_lower = lower(typed_answer)
   if typed_lower in {"claude-plugin", "plugin", "claude-code-plugin"}:
       bundle.project_shape = "claude-code-plugin"
   ```

   `generate-config.sh` is byte-identical to the pre-change version — its
   `is_plugin_shape == "claude-code-plugin"` gate compares the canonical
   literal exactly as before. The normalization arm is SKILL.md-side; no
   helper-script signature changes.

   **Schema boundary (deferred to AI-2026-05-08-3).** The visible labels
   `web-app`, `fullstack`, and `mobile-only` are SKILL.md display labels for
   discoverability only — the schema-level decision (whether to graduate
   them to canonical `project_kind` enum values vs. reuse-with-flags
   against the existing canonical set) is explicitly out of scope here and
   is the subject of the schema follow-up tracked as `AI-2026-05-08-3` in
   `.gaia/artifacts/planning-artifacts/action-items.yaml`. No change to
   `config/project-config.schema.json` is made in this step. The downstream
   stack-loop and platform-loop semantics for `web-app` and `fullstack`
   (whether `fullstack` auto-prompts the mobile follow-ups in Step 2a;
   whether `web-app` defaults `platforms: [web]`) are likewise deferred to
   the schema follow-up — Step 2a's mobile-trigger predicate below is
   unchanged in this step.
3. **Stacks (iterative).** For each service in the project, capture: `name`, `language` (e.g., `node`, `python`, `java`, `swift`, `kotlin`, `react-native`, `flutter`, `objective-c`), `paths` (one or more globs / directory paths). Loop until the user is done — minimum one stack. **Skip this step entirely when project shape is `claude-code-plugin`** — the plugin stack file is referenced verbatim and there are no per-service stacks to enumerate.

   **Multi-stack `path` prompt (E85-S14 / FR-546 / ADR-126).** When more than one stack is detected or declared — i.e. `len(stacks) > 1` (the stack-discovery step found ≥2 ecosystem manifests and the user confirmed ≥2 stacks, OR the user explicitly entered ≥2 stack names) — add a per-stack `path` prompt, asked once per stack: "Root directory for stack `<name>`? (the coarse partitioning anchor; distinct from `paths`)." Record each answer as that entry's `path`. **When exactly one stack is present (single-stack repo), SKIP the `path` prompt entirely** — zero net friction for the common case. `path` is optional; an empty answer leaves it unset.

   **SR-87 default `excludes[]` (E85-S14 / AC4).** When populating a new stack's `excludes`, offer the canonical secret-file patterns as default-on candidates: `.env`, `.env.*`, `secrets/`, `*.pem`, `*.key`. The user can accept all, accept a subset, or override completely. These reduce the chance of credentials leaking into deterministic-tool scans. `cross_refs` defaults to `[]` and `ignore_nested_manifests` defaults to `true`; neither is prompted at init — both are tunable later via `/gaia-config-stack`.
4. **Compliance regimes.** Multi-select from: `gdpr`, `hipaa`, `pci-dss`, `sox`, `ccpa`, `soc2`, `iso-27001`, `wcag-2.1-aa`, `wcag-2.1-aaa`. Optional.
5. **`ui_present`.** Boolean. Drives downstream a11y rubric layer selection. **AF-2026-05-31-2 / Test13 F-05c (LOW): the answer MUST be encoded into the answer-bundle as `compliance.ui_present` (a key on the compliance object) — NOT as a top-level scalar. When the operator answers `false` AND declares no compliance regimes, emit `compliance: {"ui_present": false}` so `generate-config.sh` round-trips the answer instead of dropping it (the prior `if compliance:` truthy-check still passes on a `{ui_present: false}` payload).**
6. **Environments (iterative).** For each environment: `name` (e.g., `staging`, `production`), `url`, `auth_type`, and the **NAME** of the env var holding the credential (e.g., `STAGING_TOKEN`). Never accept or echo a literal secret. **Environment count by config_phase (Test05 F-002):** in `config_phase=full` the schema REQUIRES a non-empty `environments` block — declare **at least one** environment. Declining all in full mode causes `generate-config.sh` to seed a default `local` (`http://localhost`) on your behalf and emit a NOTICE; that auto-seed is a safety fallback, not the intended path. For `minimal`/`partial` phases, zero environments is fine. Prompt accordingly — only say "none is OK" when NOT in full mode.
7. **CI/CD platform.** Single-select from: `github-actions`, `gitlab-ci`, `circleci`, `jenkins`, `azure-pipelines`, `bitbucket-pipelines`, `none`.

   **Answer-bundle shape (AF-2026-05-30-4 D-01).** The answer-bundle MUST encode this answer as an **object** keyed `ci_platform: {"provider": "<value>"}` — NOT as a scalar string. `generate-config.sh` expects `ci_platform.get('provider')`; a bare scalar (`ci_platform: "github-actions"`) crashes the embedded Python with `'str' object has no attribute 'get'`. Canonical bundle entry for the GitHub Actions selection:

   ```json
   {
     "ci_platform": { "provider": "github-actions" }
   }
   ```

   For `none`, omit the key entirely OR emit `{"provider": "none"}` — both forms cause the CI-scaffold step to skip cleanly. The object shape is the same convention used by the `environments` block.

**Step 2a — Mobile-specific follow-ups (conditional).** Trigger only when project shape is one of `mobile-only`, `mobile+backend`, `microservices+mobile`. The trigger predicate is unchanged by E71-S6 — `web-app` and `fullstack` do NOT auto-trigger Step 2a in this story; that decision is deferred to `AI-2026-05-08-3`. Per E74-S11 / ADR-081 the `device_targets[<platform>]` block is canonical and MUST contain `os_versions`, `form_factors`, and `screen_sizes` — collect each field explicitly:

- iOS: ship to iOS y/n. If yes, ask:
  - `os_versions` — comma-separated list (e.g., `16.0,17.0`).
  - `form_factors` — multi-select from `phone | tablet | foldable | watch | tv` (default `phone,tablet`).
  - `screen_sizes` — comma-separated `WxH@D` triples (default `390x844@3.0,1024x1366@2.0`).
  - Add `ios` to `platforms[]` and write the canonical block under `device_targets.ios`.
- Android: ship to Android y/n. If yes, ask the same three fields with Android-appropriate defaults:
  - `os_versions` (e.g., `13,14`).
  - `form_factors` (default `phone,tablet`).
  - `screen_sizes` (default `412x915@2.625,800x1280@2.0`).
  - Add `android` to `platforms[]` and write the canonical block under `device_targets.android`.

The mobile answers populate the canonical `device_targets` block. When the user declines mobile entirely, omit `platforms` and `device_targets` from the answer-bundle (and from the generated config).

**Step 2b — Headless / web platform vocabulary (informational).** The platform vocabulary the schema recognizes is broader than just `ios` / `android` / `web`: a single-backend, microservices, CLI, library, or any other headless project shape canonically uses **`server`** (the `backend` token is accepted as an alias by `validate-platform-stack.sh` per AF-2026-05-31-1 / Test12 F-02 + F-03). Step 2a only collects iOS/Android explicitly because those carry device-target side-data; `web` and `server`/`backend` are auto-derived from the project_shape + `ui_present` answers by `generate-config.sh` and do NOT require their own follow-up questions. The full enum recognized by the schema and the validator is therefore: `ios | android | web | server` (with `backend` accepted as a `server` alias on the input side).

### Step 3 — Validate the answer-bundle

Render the assembled JSON bundle to the user for review. Then run the platform-stack consistency check.

**AF-2026-05-31-3 / Test14 F-01:** the validator takes a YAML FILE PATH, not inline YAML content. Write the answer-bundle to a tempfile first, then pass the path:

```bash
# Materialise the answer bundle as YAML at a tempfile path.
_bundle_path="$(mktemp -t gaia-init-bundle.XXXXXX.yaml)"
printf '%s\n' "$bundle_yaml" > "$_bundle_path"

# The validator wants `<config.yaml>` (a path), NOT the YAML text itself.
# Passing inline content fails with exit 2 "cannot read".
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/validate-platform-stack.sh "$_bundle_path"
_rc=$?

rm -f "$_bundle_path"
# (the validator is read-only; we delete after the check to avoid leaking
# the temp file when the validation later loops)
```

If it returns non-zero, surface the error message and re-prompt the user to either remove the offending platform OR add a capable stack — do NOT proceed to file write until the bundle validates.

### Step 4 — Generate `.gaia/config/project-config.yaml`

Pipe the JSON bundle to `generate-config.sh`:

```
echo "$BUNDLE_JSON" | ${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/generate-config.sh \
  --path "$PROJECT_PATH" --name "$PROJECT_NAME"
```

Then validate the freshly-written file against the schema:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/validate-against-schema.sh \
  "$PROJECT_PATH/.gaia/config/project-config.yaml"
```

If validation fails, surface the validator output, delete the just-written file (revert to greenfield state), and re-prompt the user for the offending field.

### Step 5 — Generate CI scaffold

If the selected CI platform is anything other than `none`:

```
${CLAUDE_PLUGIN_ROOT}/skills/gaia-init/scripts/generate-ci-scaffold.sh \
  --path "$PROJECT_PATH" --provider "$CI_PROVIDER"
```

This writes the per-provider workflow file plus the `*.user-steps.yml` companion (preserved on regeneration). For provider `none`, skip this step.

### Step 5b — Install test-environment.yaml.example template (E17-S30)

Materialize the Test Execution Bridge manifest example into the user project so `/gaia-bridge-enable` Step 4 option [b] has a real source path to copy from. The helper preserves a user-customized file byte-identical on re-run.

```
${CLAUDE_PLUGIN_ROOT}/scripts/install-test-environment-example.sh \
  --target "$PROJECT_PATH"
```

Exit codes:
- `0` — success (copied on fresh install, or target preserved on re-run)
- `1` — plugin source template missing (plugin corruption; reinstall via marketplace)
- `2` — usage error

This step is the V2 plugin port of the legacy V1 install path (`Gaia-framework/gaia-install.sh` `cmd_init` / `cmd_update`) retired by ADR-049. Traces: E17-S30, FR-201, ADR-028.

### Step 5c — Install project CLAUDE.md

Materialize the project-root `CLAUDE.md` from the plugin template. This is the file that tells Claude Code the project is a GAIA project — the runtime tree (`.gaia/`), how to start (`/gaia`, `/gaia-help`, `/gaia-dev-story`), the hard rules, and the upstream bug-report policy. Without it, a freshly-initialized project has no GAIA context loaded into Claude Code sessions. The helper preserves a user's existing `CLAUDE.md` byte-identical on re-run (copy-if-absent — never clobber).

```
${CLAUDE_PLUGIN_ROOT}/scripts/install-claude-md.sh \
  --target "$PROJECT_PATH"
```

Exit codes:
- `0` — success (copied on fresh install, or target `CLAUDE.md` preserved on re-run)
- `1` — plugin source template missing (plugin corruption; reinstall via marketplace)
- `2` — usage error

### Step 6 — Render Next Steps

Render the following to the user, replacing the placeholder with the concrete file list:

```
✓ Generated:
  - .gaia/config/project-config.yaml
  - <CI workflow path>
  - <CI user-steps companion path>
  - .gaia/config/test-environment.yaml.example
  - CLAUDE.md (project-root; copied from template or preserved if present)
  - .gitignore (project-root; seeded or GAIA block appended — Test05 F-055)

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
