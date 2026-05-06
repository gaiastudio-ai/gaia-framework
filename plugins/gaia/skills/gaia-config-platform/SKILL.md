---
name: gaia-config-platform
description: Edit the platforms section of project-config.yaml — add, remove, or list platform identifiers. Section-scoped editor that preserves YAML comments and formatting per ADR-044. Unknown identifiers warn (not error) per ADR-081 §4.2 — use when "edit platforms config" or /gaia-config-platform.
argument-hint: "<add|remove|list> [platform-id]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
---

## Mission

You are editing the `platforms` top-level section of `project-config.yaml` — a flat list of platform identifiers (`ios`, `android`, `web`, plus future entries per ADR-081 extensibility). Mobile gates downstream (rubric layer selection, device-target requirement, mobile-specific reviews) trigger off the contents of this list.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section is regenerated from the deduplicated platform set.

## Critical Rules

- Only the `platforms` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- Unknown platform identifiers (anything outside `ios | android | web`) warn but proceed — per ADR-081 §4.2 the surface is extensible at the resolver layer. Do NOT reject a kebab-case identifier just because it is not in the documented enum.
- Empty identifiers and identifiers containing characters outside the kebab-case shape (`^[a-z][a-z0-9-]*$`) MUST be rejected with exit 1.
- All add / remove operations are idempotent — `add ios` twice is one entry; `remove` of an absent id is a no-op success.
- Writes go through `config-yaml-editor.sh replace` / `insert` so the rest of the file is untouched.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing.

### Step 2 — Dispatch Subcommand

Invoke the deterministic helper:

```
${CLAUDE_PLUGIN_ROOT}/scripts/gaia-config-platform-edit.sh \
  --config <path> <add|remove|list> [<platform-id>]
```

- `add <id>` — append `<id>` to `platforms[]` if absent. Exit 1 on invalid identifier shape; warn (stderr) but proceed on unknown-but-valid identifiers.
- `remove <id>` — remove `<id>` from `platforms[]` if present. No-op success when absent.
- `list` — print the current platforms, one per line.

### Step 3 — Optional Validation Pass

After `add`, suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation, and (when the new platform is mobile) `/gaia-config-device-target set <platform> ...` to populate the corresponding `device_targets` block.

## Notes

- Documented platform identifiers (E68-S1 baseline): `web`, `ios`, `android`. ADR-081 §4.2 leaves the surface extensible.
- The eleven top-level sections of `project-config.yaml` (E68-S1): `project`, `stacks`, `platforms`, `regimes`, `ci_cd`, `environments`, `test_execution`, `tool_adapters`, `rubrics`, `compliance`, `deployment`. This skill ONLY edits `platforms`.
