---
name: gaia-config-device-target
description: Edit the device_targets section of project-config.yaml — set, show, or clear per-platform device matrices (os_versions, form_factors, screen_sizes). Section-scoped editor that preserves YAML comments and formatting per ADR-044 — use when "edit device targets config" or /gaia-config-device-target.
argument-hint: "<set|show|clear> <platform> [--os-versions ...] [--form-factors ...] [--screen-sizes WxH@D,...]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Mission

You are editing the `device_targets` top-level section of `project-config.yaml`. Each entry is keyed by platform identifier (e.g., `ios`, `android`) and maps to a canonical block with:

- `os_versions` — list of free-form version strings (e.g., `"16.0"`, `"17.0"`).
- `form_factors` — list of enum entries from `phone | tablet | foldable | watch | tv`.
- `screen_sizes` — list of `{width, height, density}` objects (logical points + pixel density).

The mobile rubric layer iterates over the `screen_sizes` matrix during reviews per ADR-081 / FR-RSV2-27. Orphan entries (e.g., `device_targets.ios` when `platforms: [android]`) are rejected at this editor — `platforms[]` is the source of truth for which device-target keys are admissible.

Editing is comment-preserving per ADR-044.

## Critical Rules

- Only the `device_targets` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- `set <platform> ...` MUST reject orphan platforms — i.e. `<platform>` not present in `platforms[]` — with exit 1 and a diagnostic that points the user to `/gaia-config-platform add <platform>`.
- `set` is idempotent in the replace sense: re-running with new values REPLACES the previous block. There is no append semantics.
- Screen-size entries are parsed from `WxH@D` strings (e.g., `390x844@3.0`). Malformed entries MUST be rejected with exit 1.
- Writes go through `config-yaml-editor.sh replace` / `insert`.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing.

### Step 2 — Dispatch Subcommand

Invoke the deterministic helper:

```
${CLAUDE_PLUGIN_ROOT}/scripts/gaia-config-device-target-edit.sh \
  --config <path> <set|show|clear> <platform> \
  [--os-versions   "16.0,17.0"] \
  [--form-factors  "phone,tablet"] \
  [--screen-sizes  "390x844@3.0,1024x1366@2.0"]
```

- `set <platform> --os-versions ... --form-factors ... --screen-sizes ...` — write or replace the `device_targets.<platform>` block. All three flags are required. Orphan platforms are rejected with exit 1.
- `show <platform>` — print the current block as YAML.
- `clear <platform>` — remove the entry.

### Step 3 — Optional Validation Pass

After `set`, suggest running `/gaia-config-validate` to confirm schema conformance.

## Screen-size Format

`WxH@D` where:

- `W` = logical width in points (integer).
- `H` = logical height in points (integer).
- `D` = pixel density / scale factor (float, e.g., `2.0`, `3.0`, `2.625`).

Examples: `390x844@3.0` (iPhone 15 portrait), `1024x1366@2.0` (iPad Pro 12.9"), `412x915@2.625` (Pixel 7).

## Notes

- Per ADR-081 the schema enforces `os_versions`, `form_factors`, `screen_sizes` as required fields under `deviceTargetEntry` — partial blocks are rejected at validation time.
- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `device_targets` (a sibling top-level key per ADR-081 / project-config.schema.json).
