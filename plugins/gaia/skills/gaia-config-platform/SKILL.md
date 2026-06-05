---
name: gaia-config-platform
description: Edit the platforms section of project-config.yaml — add, remove, or list platform identifiers. Section-scoped editor that preserves YAML comments and formatting. Unknown identifiers warn (not error) — use when "edit platforms config" or /gaia-config-platform.
argument-hint: "<add|remove|list> [platform-id]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Mission

You are editing the `platforms` top-level section of `project-config.yaml` — a flat list of platform identifiers (`ios`, `android`, `web`, plus future extensibility entries). Mobile gates downstream (rubric layer selection, device-target requirement, mobile-specific reviews) trigger off the contents of this list.

Editing is comment-preserving: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section is regenerated from the deduplicated platform set.

## Critical Rules

- Only the `platforms` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- Unknown platform identifiers (anything outside `ios | android | web`) warn but proceed — the surface is extensible at the resolver layer. Do NOT reject a kebab-case identifier just because it is not in the documented enum.
- Empty identifiers and identifiers containing characters outside the kebab-case shape (`^[a-z][a-z0-9-]*$`) MUST be rejected with exit 1.
- All add / remove operations are idempotent — `add ios` twice is one entry; `remove` of an absent id is a no-op success.
- Writes go through `config-yaml-editor.sh replace` / `insert` so the rest of the file is untouched.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing.

### Step 2 — Dispatch Subcommand

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration. The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

#### Step 2a — Print current state first (every invocation)

The first user-visible line of output for every invocation MUST surface the **current state** of `platforms[]` resolved from `.gaia/config/project-config.yaml`. Read the array using the same `yq` path the helper uses for `list`, and render it as:

```
current platforms[]: [<comma-separated-or-empty>]
```

This applies uniformly to `add`, `remove`, `list`, and the no-subcommand case below — there is no invocation that skips the preamble.

#### Step 2b — Handle the no-subcommand case

When the skill is invoked with **no subcommand** (just `/gaia-config-platform`), after printing the current-state preamble, print a usage block that includes:

- The canonical subcommand list: `add`, `remove`, `list`.
- The documented baseline menu: `web | ios | android`.
- The kebab-case extensibility note: any identifier matching `^[a-z][a-z0-9-]*$` is also accepted.

Then exit 0 (usage display is success, not error).

#### Step 2c — Handle the no-arg `add` case

When the user runs `add` with **no `<platform-id>` argument**, after the current-state preamble:

- Enumerate the documented baseline menu: `web | ios | android`.
- Print the kebab-case extensibility note: any identifier matching `^[a-z][a-z0-9-]*$` is also accepted.
- Re-prompt the user for an identifier — DO NOT exit non-zero. The empty argument is a discoverability hint, not a validation failure.

Once an identifier is supplied, fall through to Step 2d.

#### Step 2d — Dispatch to the helper

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

- Documented platform identifiers (baseline): `web`, `ios`, `android`. The surface is left extensible.
- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (40 properties in schema v2.0.0). This skill ONLY edits `platforms`.
