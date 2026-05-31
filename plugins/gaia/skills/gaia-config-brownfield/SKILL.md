---
name: gaia-config-brownfield
description: Edit the brownfield section of project-config.yaml — set, show, or clear deterministic-tools knobs (deterministic_tools, tools.runner, grype_enabled, scanner_tier). Section-scoped editor that preserves YAML comments and formatting per ADR-044. Use when "edit brownfield config" or /gaia-config-brownfield.
argument-hint: "<set|show|clear> [key] [value]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Mission

You are editing the `brownfield:` top-level section of `.gaia/config/project-config.yaml`. The brownfield block controls the deterministic-tools suite consumed by `/gaia-brownfield` and `/gaia-doctor` (Test10 §7 Component 4 / Test10 F-06). Closes the gap that the deterministic-tools suite was hand-edit-only.

Editing is comment-preserving per ADR-044: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section is regenerated from the merged answer set.

## Critical Rules

- Only the `brownfield` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- Supported keys (enums enforced):
  - `brownfield.deterministic_tools` — `true` | `false`
  - `brownfield.tools.runner` — `docker` | `native`
  - `brownfield.tools.image` — OCI image reference (string), e.g. `ghcr.io/gaiastudio-ai/gaia-tools:0.1.1-2026-05-31` (AF-2026-05-31-2 / Test13 F-06)
  - `brownfield.grype_enabled` — `true` | `false`
  - `brownfield.scanner_tier` — `0` | `1` | `2` | `auto`
- Reject unknown keys and out-of-enum values with exit 1.
- All set / clear operations are idempotent — setting the same value twice is a no-op success; clearing an absent key is a no-op success.
- Writes go through `config-yaml-editor.sh replace` / `insert` so the rest of the file is untouched.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`). HALT if missing — point the user at `/gaia-init`.

### Step 2 — Dispatch Subcommand

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration (ADR-093). The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

#### Step 2a — Print current state first (every invocation)

The first user-visible line of output for every invocation MUST surface the **current state** of the `brownfield:` block resolved from `.gaia/config/project-config.yaml`. Read via `yq` and render as:

```
current brownfield:
  deterministic_tools: <true|false|unset>
  tools.runner:        <docker|native|unset>
  tools.image:         <image-ref|unset>
  grype_enabled:       <true|false|unset>
  scanner_tier:        <0|1|2|auto|unset>
```

This applies uniformly to `set`, `show`, `clear`, and the no-subcommand case below — there is no invocation that skips the preamble.

#### Step 2b — Handle the no-subcommand case

When the skill is invoked with **no subcommand** (just `/gaia-config-brownfield`), after printing the current-state preamble, print a usage block that includes:

- The canonical subcommand list: `set`, `show`, `clear`.
- The supported keys + enums (see Critical Rules).

Then exit 0 (usage display is success, not error).

#### Step 2c — Dispatch to `set`

```
${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> brownfield > /tmp/brownfield-current.yaml
```

Read the current section, merge the requested `<key> <value>` (validating against the enum table above), and write the new block back via:

```
${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh replace <path> brownfield /tmp/brownfield-new.yaml
```

If the `brownfield:` section does not yet exist, use `insert` instead of `replace`.

After flipping `brownfield.deterministic_tools` to `true`, instruct the operator to immediately run `/gaia-doctor` to verify the host has the deterministic-tools chain installed (Test10 §7 Component 4 / F-06). Render:

```
deterministic_tools=true requires the deterministic-tools chain on $PATH.
Run /gaia-doctor now to confirm — Tier 0 (LLM-only) and Tier 1 (pure-pip)
hosts will fail-fast on Tier 2 invocations otherwise.

Alternative: set brownfield.tools.runner = docker to dispatch Tier 2
tools through the bundled gaia-tools OCI image. Operators then need only
Docker on the host (no brew/pip/npm/Go/Java toolchains). Pull the image
once: `/gaia-doctor --install`. See AF-2026-05-30-3 / Test10 §7 C2.
```

After flipping `brownfield.tools.runner` to `docker`, render an additional reminder:

```
tools.runner=docker — Tier 2 adapters now dispatch through the bundled
gaia-tools OCI image (AF-2026-05-30-3 / Test10 §7 Component 2).
  Image:      ghcr.io/gaiastudio-ai/gaia-tools:<pinned>
  Pull once:  /gaia-doctor --install
The image bundles grype + syft + osv-scanner + spotbugs + vulture +
pip-audit + cyclonedx-bom + cdxgen + yamllint + yq, all pinned. Findings
become reproducible: identical image tag → identical scanner versions +
vuln-DB snapshot across machines and CI.
```

#### Step 2d — Dispatch to `show`

`show` simply re-prints the current-state preamble from Step 2a. Useful for scripted inspection.

#### Step 2e — Dispatch to `clear`

`clear <key>` removes the key from the `brownfield:` section (preserves siblings). `clear` with no key removes the entire `brownfield:` section. Idempotent — clearing an absent key is a no-op success.

### Step 3 — Optional Validation Pass

After `set`, suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- See `schemas/project-config.schema.json` `.properties.brownfield` for the authoritative shape.
- Related skills: `/gaia-brownfield` (consumer), `/gaia-doctor` (validates the chain installed), `/gaia-config-validate` (schema validation).
- Closes Test10 F-06 — the deterministic-tools suite is no longer hand-edit-only.
