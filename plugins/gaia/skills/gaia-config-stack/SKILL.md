---
name: gaia-config-stack
description: Edit the stacks section of project-config.yaml — section-scoped editor that preserves YAML comments and formatting. Use when "edit stacks config" or /gaia-config-stack.
argument-hint: "[--add|--remove|--edit|--reorder] [stack-name]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are editing the `stacks` top-level section of `project-config.yaml`. The skill is one of eight `/gaia-config-*` editors. The `stacks` section is an ordered list of stack-path rules for multi-service repos — review skills resolve the active stack by walking entries in declaration order and matching against the changed-file list.

Each stack entry carries three required fields (`name`, `language`, `paths`) plus four OPTIONAL multi-stack monorepo partitioning fields: `path`, `excludes`, `cross_refs`, and `ignore_nested_manifests`. All four are additive with safe defaults — pre-existing single-stack configs validate byte-compatible (zero-regression invariant).

Editing is comment-preserving: pre-existing comments and formatting OUTSIDE the edited section are preserved byte-for-byte; the edited section's content follows the existing indentation style detected from the file.

## Critical Rules

- Only the `stacks` section may be modified. All other sections, all comments, and all formatting outside the edited section MUST be preserved byte-for-byte.
- The comment-preserving YAML editor lives in `plugins/gaia/scripts/config-yaml-editor.sh`. Do NOT round-trip the file through a generic YAML serializer.
- Each stack entry MUST have `name`, `language`, and `paths`. Reject entries missing any required field.
- The four optional fields (`path`, `excludes`, `cross_refs`, `ignore_nested_manifests`) are additive — never required. `clear` resets each to its schema default (`null` for `path`, `[]` for `excludes`/`cross_refs`, `true` for `ignore_nested_manifests`).
- `cross_refs` entries MUST each name an existing stack in the same `stacks[]` list. JSON Schema cannot express this cross-property constraint, so this skill (and `/gaia-config-validate`) enforce it as a post-write validation pass — reject a `set cross_refs` whose values do not all resolve to a declared stack `name`.
- Stack `name` values MUST be unique within the list.
- Stack declaration order is significant — it drives the first-match resolution rule. Reorder operations MUST surface this in the confirmation prompt.
- Edits MUST go through the diff-preview confirmation gate — never write without an explicit user confirm response.
- If the `stacks` section is missing (absent from the file), the skill MUST inform the user and offer to scaffold a default section, OR abort.

## Steps

### Step 1 — Locate project-config.yaml

- Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (fallback `config/project-config.yaml`).
- HALT if missing.

### Step 2 — Extract the stacks Section

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> stacks`.
- Exit 2 (missing / absent section): offer scaffold-or-abort. Default scaffold:
  ```yaml
  stacks:
    - name: app
      language: typescript
      paths: ["src/**"]
  ```

### Step 3 — Present CRUD Menu

> **Note:** The CRUD menu below is the LLM-driven interaction pattern under Claude Code main-turn orchestration. The deterministic helpers under `plugins/gaia/scripts/` are the actual write primitives; the menu is performed by the LLM orchestrator from this SKILL.md, not by a TUI.

- Render the current stacks list as a numbered table (position, name, language, paths).
- Operation menu: `[a]` add, `[r]` remove, `[e]` edit, `[o]` reorder, `[v]` view, `[x]` exit.

### Step 4 — Apply Operation

- Add: prompt for name, language, paths (glob list). Optionally capture the four optional fields (`path`, `excludes`, `cross_refs`, `ignore_nested_manifests`); omit any the user does not set.
- Remove: prompt for name, confirm.
- Edit: prompt for name, then field-by-field updates — including the four optional fields via set/show/clear (see Step 4a).
- Reorder: prompt for new order; warn that position 0 changes the first-match resolution.

### Step 4a — Optional-field set / show / clear

Standard set/show/clear CRUD semantics per the config-skill canon, applied per stack entry. All four operations route through the comment-preserving editor — NEVER a generic YAML round-trip.

| Field | `set` accepts | `show` | `clear` resets to |
|-------|---------------|--------|-------------------|
| `path` | a single directory string (the stack ROOT; coarse partitioning anchor — distinct from `paths` glob list) | current value or `(unset)` | `null` (field removed) |
| `excludes` | a glob list; `/gaia-init` seeds the secret patterns `.env`, `.env.*`, `secrets/`, `*.pem`, `*.key` | current list | `[]` |
| `cross_refs` | a stack-name list; every value MUST already exist in `stacks[]` (post-write referential check) | current list | `[]` |
| `ignore_nested_manifests` | a boolean (`true`/`false`) | current value | `true` |

- `set` requires a value; `show` is read-only; `clear` resets to the schema default above.
- After a `set cross_refs`, run the referential-integrity pass: every entry must resolve to a declared stack `name`; if any does not, reject and surface the offending value (`cross_refs: [nonexistent-stack]` → flagged by `/gaia-config-validate`).

### Step 5 — Diff Preview + Confirmation Gate

- Generate a unified diff via `diff -u` (same format as `git diff --no-index`).
- Prompt: "Apply this edit? [y/n]". HALT without writing on `n` — file remains byte-identical to its pre-edit state.

### Step 6 — Write Back

- On `y`: write the new section to a temp file and invoke `config-yaml-editor.sh replace <path> stacks <temp-file>`.

### Step 7 — Optional Validation Pass

- Suggest running `/gaia-config-validate` to confirm the modified file still passes schema validation.

## Notes

- Stack declaration order is the resolution order. Surface this in any reorder confirmation so the user is aware before applying.
- See `schemas/project-config.schema.json` `.properties` for the full top-level section list (42 properties in schema v2.0.0). This skill ONLY edits `stacks`.
- The four optional fields are written through `config-yaml-editor.sh` like every other `stacks` mutation — comments and formatting outside the edited section are preserved byte-for-byte. Do NOT use a bare `yq -i` round-trip.

### The four multi-stack fields — semantics + worked examples

- **`path`** (string, default null) — the stack ROOT directory. A coarse partitioning anchor: the deterministic-tools orchestrator scopes adapter dispatch to this subtree first, then applies `paths` globs within it. Distinct from `paths` — `paths` is the in-stack glob list; `path` is the single root.
- **`excludes`** (glob list, default `[]`) — patterns removed from this stack's file set before scanning. Seeded by `/gaia-init` with the secret patterns.
- **`cross_refs`** (stack-name list, default `[]`) — the allowlist of other stacks this stack may reference; consumed by the cross-stack WARNING emission. Each value must name a declared stack.
- **`ignore_nested_manifests`** (boolean, default true) — when true, manifest auto-detection under `path` is suppressed so a monorepo subtree is not re-detected as its own stack.

**Worked example 1 — single-stack (zero-regression).** No new fields; validates exactly as before:

```yaml
stacks:
  - name: monolith
    language: python
    paths: ["**/*.py"]
```

**Worked example 2 — 3-stack monorepo (all four fields).**

```yaml
stacks:
  - name: api
    language: go
    paths: ["services/api/**"]
    path: services/api
    excludes: [".env", "secrets/"]
    cross_refs: ["shared"]
    ignore_nested_manifests: true
  - name: web
    language: typescript
    paths: ["apps/web/**"]
    path: apps/web
    cross_refs: ["shared", "api"]
  - name: shared
    language: typescript
    paths: ["packages/shared/**"]
    path: packages/shared
```

**Worked example 3 — multi-language service with secret excludes only.**

```yaml
stacks:
  - name: ml
    language: python
    paths: ["ml/**"]
    path: ml
    excludes: [".env.*", "*.pem", "*.key"]
```
